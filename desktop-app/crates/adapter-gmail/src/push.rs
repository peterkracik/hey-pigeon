//! Device registration against the optional iOS push relay (relay/).
//!
//! The relay authenticates the phone with the Google access token the app
//! already holds for the mailbox — so this lives next to the token cache
//! rather than in the Swift shell, and the token never crosses the FFI.
//! What goes over the wire: the device token, the APNs environment it was
//! issued for, and the bearer token. What comes back: the Pub/Sub topic the
//! relay listens on, which the engine then hands to `users.watch`.

use heypigeon_core::domain::AccountId;
use heypigeon_core::ports::MailError;
use serde::Deserialize;

use crate::GmailProvider;

/// Response of `POST {relay}/` on success.
#[derive(Deserialize)]
pub(crate) struct WireRegistration {
    /// Fully-qualified Pub/Sub topic, `projects/<id>/topics/gmail-push`.
    pub topic: String,
}

/// What the relay says of itself (`GET {relay}/`, relay/README.md): the
/// topic to watch and where its read-status half answers.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct RelayInfo {
    #[serde(default)]
    pub topic: String,
    /// The `opens` function's address (the pixel's own domain); None when
    /// this relay has no read status, or not yet.
    #[serde(default, rename = "opensUrl")]
    pub opens_url: Option<String>,
}

impl GmailProvider {
    /// Ask the relay where its halves are. Writes nothing there: no device
    /// token is sent, so a Mac (which has none) and a phone with push off
    /// can ask. Authenticated like a registration, with this account's
    /// access token.
    pub async fn relay_info(
        &self,
        account_id: &AccountId,
        relay_url: &str,
    ) -> Result<RelayInfo, MailError> {
        let token = self.access_token(account_id).await?;
        let resp = self
            .relay_http
            .get(relay_endpoint(relay_url))
            .bearer_auth(token)
            .send()
            .await
            .map_err(|e| MailError::Network(e.to_string()))?;
        Self::check(resp)
            .await?
            .json()
            .await
            .map_err(|e| MailError::Provider(format!("relay: {e}")))
    }

    /// Register (or refresh) a device token with the relay for this account.
    /// `environment` is `"sandbox"` for Xcode builds, `"production"` for
    /// TestFlight / App Store — APNs tokens are only valid on the side
    /// they were issued for. Returns the topic to watch.
    pub async fn register_push_device(
        &self,
        account_id: &AccountId,
        relay_url: &str,
        device_token: &str,
        environment: &str,
    ) -> Result<String, MailError> {
        let token = self.access_token(account_id).await?;
        let body = serde_json::json!({
            "deviceToken": device_token,
            "platform": "ios",
            "environment": environment,
        });
        let resp = self
            .relay_http
            .post(relay_endpoint(relay_url))
            .bearer_auth(token)
            .json(&body)
            .send()
            .await
            .map_err(|e| MailError::Network(e.to_string()))?;
        let reg: WireRegistration = Self::check(resp)
            .await?
            .json()
            .await
            .map_err(|e| MailError::Provider(format!("relay: {e}")))?;
        Ok(reg.topic)
    }

    /// Remove a device token from the relay for this account.
    pub async fn unregister_push_device(
        &self,
        account_id: &AccountId,
        relay_url: &str,
        device_token: &str,
    ) -> Result<(), MailError> {
        let token = self.access_token(account_id).await?;
        let body = serde_json::json!({ "deviceToken": device_token });
        let resp = self
            .relay_http
            .delete(relay_endpoint(relay_url))
            .bearer_auth(token)
            .json(&body)
            .send()
            .await
            .map_err(|e| MailError::Network(e.to_string()))?;
        Self::check(resp).await.map(|_| ())
    }
}

/// The relay URL as the user pasted it, normalised to one trailing slash
/// (Cloud Run function URLs come without one).
pub(crate) fn relay_endpoint(relay_url: &str) -> String {
    format!("{}/", relay_url.trim().trim_end_matches('/'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registration_response_carries_topic() {
        let json = serde_json::json!({ "topic": "projects/heypigeon/topics/gmail-push" });
        let reg: WireRegistration = serde_json::from_value(json).unwrap();
        assert_eq!(reg.topic, "projects/heypigeon/topics/gmail-push");
    }

    /// The relay's answer to `GET`: with read status, without it (`null`),
    /// and from a relay older than read status (no such field).
    #[test]
    fn relay_info_reads_the_opens_url_or_its_absence() {
        let topic = "projects/heypigeon/topics/gmail-push";
        let with: RelayInfo = serde_json::from_value(
            serde_json::json!({ "topic": topic, "opensUrl": "https://o.heypigeon.app" }),
        )
        .unwrap();
        assert_eq!(with.topic, topic);
        assert_eq!(with.opens_url.as_deref(), Some("https://o.heypigeon.app"));
        for json in [
            serde_json::json!({ "topic": topic, "opensUrl": null }),
            serde_json::json!({ "topic": topic }),
        ] {
            let without: RelayInfo = serde_json::from_value(json).unwrap();
            assert_eq!(without.opens_url, None);
        }
    }

    #[test]
    fn relay_endpoint_normalises_slashes() {
        assert_eq!(
            relay_endpoint("https://register-token-abc-ew.a.run.app"),
            "https://register-token-abc-ew.a.run.app/"
        );
        assert_eq!(
            relay_endpoint(" https://x.example/// "),
            "https://x.example/"
        );
    }
}
