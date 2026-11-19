//! Read status against the relay's `opens` function (relay/README.md,
//! docs/specs/read-status.md R20).
//!
//! Like device registration (push.rs), the relay knows the caller by the
//! Google access token the app already holds for the mailbox, so these
//! calls live next to the token cache and the token never crosses the FFI.
//! What goes over the wire: the bearer token and the random tokens of
//! tracked messages. Never a message, a subject, a recipient or an id.
//!
//! Nothing here is called for an account whose read status is off: the
//! core decides that (`heypigeon_core::readstatus`), this only carries.

use std::collections::HashMap;
use std::time::Duration;

use heypigeon_core::domain::{AccountId, OpenEvent, OpenLabel};
use heypigeon_core::ports::MailError;
use serde::Deserialize;

use crate::GmailProvider;

/// A send waits for the registration, so it does not wait long: past this
/// the message goes out untracked.
const REGISTER_TIMEOUT: Duration = Duration::from_secs(8);
const TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Deserialize)]
struct WireRegistered {
    #[serde(rename = "pixelUrl")]
    pixel_url: String,
}

#[derive(Deserialize)]
pub(crate) struct WireEvent {
    label: String,
    at: i64,
}

/// The one pixel address that may go into a message for `token`: on the
/// host the relay named as its own, with exactly this token. Anything
/// else in a relay's answer is refused — a message must not be sent
/// pointing somewhere this build was not told about.
pub(crate) fn expected_pixel_url(opens_url: &str, token: &str) -> String {
    format!("{}/o/{token}.gif", opens_url.trim_end_matches('/'))
}

/// The relay's answer to a query, as events: only for tokens that were
/// asked about, and only labels this build knows.
pub(crate) fn events_from(
    answer: HashMap<String, Vec<WireEvent>>,
    asked: &[String],
) -> HashMap<String, Vec<OpenEvent>> {
    answer
        .into_iter()
        .filter(|(token, _)| asked.contains(token))
        .map(|(token, events)| {
            let events = events
                .into_iter()
                .filter_map(|e| {
                    OpenLabel::parse(&e.label).map(|label| OpenEvent { label, at: e.at })
                })
                .collect();
            (token, events)
        })
        .collect()
}

/// A relay address as the provider keeps it: https, no trailing slash;
/// None for anything else.
pub(crate) fn normalised(url: Option<String>) -> Option<String> {
    url.map(|u| u.trim().trim_end_matches('/').to_string())
        .filter(|u| u.starts_with("https://"))
}

impl GmailProvider {
    /// Tell the provider where the relay's `opens` function answers (the
    /// engine does, from what the relay reported); None for no read status.
    pub fn set_opens_url(&self, url: Option<String>) {
        *self.opens_url.lock().unwrap() = normalised(url);
    }

    fn opens_base(&self) -> Result<String, MailError> {
        self.opens_url
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| MailError::Provider("read status: no relay".into()))
    }

    pub(crate) async fn opens_register(
        &self,
        account_id: &AccountId,
        token: &str,
    ) -> Result<String, MailError> {
        let base = self.opens_base()?;
        let bearer = self.access_token(account_id).await?;
        let resp = self
            .http
            .post(format!("{base}/v1/tokens"))
            .timeout(REGISTER_TIMEOUT)
            .bearer_auth(bearer)
            .json(&serde_json::json!({ "token": token }))
            .send()
            .await
            .map_err(|_| MailError::Network("relay unreachable".into()))?;
        let registered: WireRegistered = Self::check(resp)
            .await?
            .json()
            .await
            .map_err(|_| MailError::Provider("relay: unreadable answer".into()))?;
        if registered.pixel_url != expected_pixel_url(&base, token) {
            return Err(MailError::Provider(
                "relay: the pixel is not on its own host".into(),
            ));
        }
        Ok(registered.pixel_url)
    }

    pub(crate) async fn opens_query(
        &self,
        account_id: &AccountId,
        tokens: &[String],
    ) -> Result<HashMap<String, Vec<OpenEvent>>, MailError> {
        let base = self.opens_base()?;
        let bearer = self.access_token(account_id).await?;
        let resp = self
            .http
            .post(format!("{base}/v1/opens"))
            .timeout(TIMEOUT)
            .bearer_auth(bearer)
            .json(&serde_json::json!({ "tokens": tokens }))
            .send()
            .await
            .map_err(|_| MailError::Network("relay unreachable".into()))?;
        let answer: HashMap<String, Vec<WireEvent>> = Self::check(resp)
            .await?
            .json()
            .await
            .map_err(|_| MailError::Provider("relay: unreadable answer".into()))?;
        Ok(events_from(answer, tokens))
    }

    pub(crate) async fn opens_delete(&self, account_id: &AccountId) -> Result<(), MailError> {
        let base = self.opens_base()?;
        let bearer = self.access_token(account_id).await?;
        let resp = self
            .http
            .delete(format!("{base}/v1/tokens"))
            .timeout(TIMEOUT)
            .bearer_auth(bearer)
            .send()
            .await
            .map_err(|_| MailError::Network("relay unreachable".into()))?;
        Self::check(resp).await.map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKEN: &str = "0123456789abcdef0123456789abcdef";

    #[test]
    fn the_pixel_is_on_the_relays_own_host_with_this_token() {
        assert_eq!(
            expected_pixel_url("https://o.heypigeon.app", TOKEN),
            format!("https://o.heypigeon.app/o/{TOKEN}.gif")
        );
        assert_eq!(
            expected_pixel_url("https://o.heypigeon.app/", TOKEN),
            format!("https://o.heypigeon.app/o/{TOKEN}.gif")
        );
        // What a relay might answer instead, and is refused for: another
        // host, a run.app address, another token, plain http, a query.
        let expected = expected_pixel_url("https://o.heypigeon.app", TOKEN);
        for other in [
            format!("https://evil.example/o/{TOKEN}.gif"),
            format!("https://opens-abc-ew.a.run.app/o/{TOKEN}.gif"),
            "https://o.heypigeon.app/o/ffffffffffffffffffffffffffffffff.gif".to_string(),
            format!("http://o.heypigeon.app/o/{TOKEN}.gif"),
            format!("https://o.heypigeon.app/o/{TOKEN}.gif?u=1"),
            format!("https://o.heypigeon.app.evil.example/o/{TOKEN}.gif"),
        ] {
            assert_ne!(other, expected);
        }
    }

    #[test]
    fn only_an_https_relay_address_is_kept() {
        assert_eq!(normalised(None), None);
        assert_eq!(normalised(Some("http://plain.example".into())), None);
        assert_eq!(normalised(Some("o.heypigeon.app".into())), None);
        assert_eq!(
            normalised(Some(" https://o.heypigeon.app/ ".into())).as_deref(),
            Some("https://o.heypigeon.app")
        );
    }

    /// The query's answer: only what was asked about, only labels this
    /// build knows — an unknown one is dropped, never read as an open.
    #[test]
    fn a_query_answer_is_read_strictly() {
        let asked = vec![TOKEN.to_string(), "b".repeat(32)];
        let answer: HashMap<String, Vec<WireEvent>> = serde_json::from_value(serde_json::json!({
            TOKEN: [
                { "label": "hidden", "at": 10 },
                { "label": "opened", "at": 20 },
                { "label": "clicked", "at": 30 },
            ],
            "b".repeat(32): [],
            "c".repeat(32): [{ "label": "opened", "at": 5 }],
        }))
        .unwrap();
        let events = events_from(answer, &asked);
        assert_eq!(events.len(), 2);
        assert_eq!(
            events[TOKEN],
            vec![
                OpenEvent {
                    label: OpenLabel::Hidden,
                    at: 10
                },
                OpenEvent {
                    label: OpenLabel::Opened,
                    at: 20
                },
            ]
        );
        assert!(events[&"b".repeat(32)].is_empty());
    }
}
