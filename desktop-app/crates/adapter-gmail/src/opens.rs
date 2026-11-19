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
                .take(MAX_EVENTS_PER_TOKEN)
                .filter_map(|e| {
                    OpenLabel::parse(&e.label).map(|label| OpenEvent { label, at: e.at })
                })
                .collect();
            (token, events)
        })
        .collect()
}

/// A relay address as the provider keeps it: an https origin and
/// nothing more (`readstatus::opens_origin`); None for anything else.
pub(crate) fn normalised(url: Option<String>) -> Option<String> {
    url.as_deref()
        .and_then(heypigeon_core::readstatus::opens_origin)
}

/// The most a query's answer may weigh: 100 tokens of 50 events each fit
/// many times over. A relay that sends more is not read.
const MAX_ANSWER_BYTES: usize = 512 * 1024;
/// Events kept per token from one answer — the relay's own limit (25 for
/// each of its two labels). What a relay sends beyond it is dropped.
pub(crate) const MAX_EVENTS_PER_TOKEN: usize = 50;

/// The body of an answer, read no further than `max` bytes.
async fn bounded_body(mut resp: reqwest::Response, max: usize) -> Result<Vec<u8>, MailError> {
    let too_big = || MailError::Provider("relay: the answer is too large".into());
    if resp.content_length().is_some_and(|n| n > max as u64) {
        return Err(too_big());
    }
    let mut body = Vec::new();
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|_| MailError::Network("relay unreachable".into()))?
    {
        if body.len() + chunk.len() > max {
            return Err(too_big());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

impl GmailProvider {
    /// Tell the provider where the relay's `opens` function answers (the
    /// engine does, from what the relay reported); None for no read status.
    pub fn set_opens_url(&self, url: Option<String>) {
        *self.opens_url.lock().unwrap() = normalised(url);
    }

    /// Whether the provider knows where the relay's `opens` function is.
    pub fn has_opens_url(&self) -> bool {
        self.opens_url.lock().unwrap().is_some()
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
            .relay_http
            .post(format!("{base}/v1/tokens"))
            .timeout(REGISTER_TIMEOUT)
            .bearer_auth(bearer)
            .json(&serde_json::json!({ "token": token }))
            .send()
            .await
            .map_err(|_| MailError::Network("relay unreachable".into()))?;
        let body = bounded_body(Self::check(resp).await?, 4096).await?;
        let registered: WireRegistered = serde_json::from_slice(&body)
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
            .relay_http
            .post(format!("{base}/v1/opens"))
            .timeout(TIMEOUT)
            .bearer_auth(bearer)
            .json(&serde_json::json!({ "tokens": tokens }))
            .send()
            .await
            .map_err(|_| MailError::Network("relay unreachable".into()))?;
        let body = bounded_body(Self::check(resp).await?, MAX_ANSWER_BYTES).await?;
        let answer: HashMap<String, Vec<WireEvent>> = serde_json::from_slice(&body)
            .map_err(|_| MailError::Provider("relay: unreadable answer".into()))?;
        Ok(events_from(answer, tokens))
    }

    pub(crate) async fn opens_delete(&self, account_id: &AccountId) -> Result<(), MailError> {
        let base = self.opens_base()?;
        let bearer = self.access_token(account_id).await?;
        let resp = self
            .relay_http
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

    /// The relay names its own address, and it goes into mail: only an
    /// https origin is kept — nothing that could be markup, a path, a
    /// user or another scheme.
    #[test]
    fn only_an_https_origin_is_kept_as_the_relays_address() {
        assert_eq!(normalised(None), None);
        for kept in [
            (" https://o.heypigeon.app/ ", "https://o.heypigeon.app"),
            ("HTTPS://O.HeyPigeon.App", "https://o.heypigeon.app"),
            ("https://relay.example:8443", "https://relay.example:8443"),
        ] {
            assert_eq!(
                normalised(Some(kept.0.into())).as_deref(),
                Some(kept.1),
                "{}",
                kept.0
            );
        }
        for refused in [
            "http://plain.example",
            "o.heypigeon.app",
            "https://",
            "https://x\" onerror=\"alert(1)",
            "https://x\"><script>alert(1)</script>",
            "https://o.heypigeon.app/path",
            "https://o.heypigeon.app/?q=1",
            "https://o.heypigeon.app#f",
            "https://user:pw@o.heypigeon.app",
            "https://user@o.heypigeon.app",
            "https://o.heypigeon.app:port",
            "https://o.heypigeon.app:",
            "https://o.hey pigeon.app",
            "https://o.heypigeon.app\n.evil.example",
            "https://[::1]",
            "https://.evil.example",
            "https://a..b",
            "javascript:alert(1)",
            "https://o.heypigeon.app<",
        ] {
            assert_eq!(normalised(Some(refused.into())), None, "{refused}");
        }
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

        // A relay that sends more events for a token than it can hold is
        // read up to that many.
        let flood: Vec<serde_json::Value> = (0..500)
            .map(|at| serde_json::json!({ "label": "opened", "at": at }))
            .collect();
        let answer: HashMap<String, Vec<WireEvent>> =
            serde_json::from_value(serde_json::json!({ TOKEN: flood })).unwrap();
        assert_eq!(
            events_from(answer, &asked)[TOKEN].len(),
            MAX_EVENTS_PER_TOKEN
        );
    }
}
