//! Gmail REST adapter: implements `MailProvider` over the Gmail v1 API.
//! Only this crate speaks Gmail's wire format — the core sees domain types.

pub mod oauth;

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use heypigeon_core::domain::*;
use heypigeon_core::ports::{MailError, MailProvider, SecretStore, ThreadPage};
use serde::Deserialize;
use tokio::sync::Mutex;

use oauth::{ClientConfig, TokenSet};

const API: &str = "https://gmail.googleapis.com/gmail/v1/users/me";
/// threads.get concurrency during backfill (quota-friendly, still fast).
const FETCH_CONCURRENCY: usize = 10;

pub fn refresh_token_key(account_id: &str) -> String {
    format!("oauth.refresh.{account_id}")
}

struct CachedToken {
    access_token: String,
    expires_at: Instant,
}

pub struct GmailProvider {
    http: reqwest::Client,
    client: ClientConfig,
    secrets: Arc<dyn SecretStore + Send + Sync>,
    tokens: Mutex<HashMap<AccountId, CachedToken>>,
}

impl GmailProvider {
    pub fn new(client: ClientConfig, secrets: Arc<dyn SecretStore + Send + Sync>) -> Self {
        Self {
            http: reqwest::Client::new(),
            client,
            secrets,
            tokens: Mutex::new(HashMap::new()),
        }
    }

    /// Store the refresh token from a fresh OAuth authorization and prime the
    /// access-token cache.
    pub async fn install_tokens(
        &self,
        account_id: &AccountId,
        tokens: &TokenSet,
    ) -> Result<(), MailError> {
        if let Some(rt) = &tokens.refresh_token {
            self.secrets
                .set(&refresh_token_key(account_id), rt)
                .map_err(|e| MailError::Provider(e.to_string()))?;
        }
        self.tokens.lock().await.insert(
            account_id.clone(),
            CachedToken {
                access_token: tokens.access_token.clone(),
                expires_at: Instant::now() + Duration::from_secs(tokens.expires_in.saturating_sub(60)),
            },
        );
        Ok(())
    }

    async fn access_token(&self, account_id: &AccountId) -> Result<String, MailError> {
        let mut cache = self.tokens.lock().await;
        if let Some(t) = cache.get(account_id) {
            if t.expires_at > Instant::now() {
                return Ok(t.access_token.clone());
            }
        }
        let refresh_token = self
            .secrets
            .get(&refresh_token_key(account_id))
            .map_err(|e| MailError::Provider(e.to_string()))?
            .ok_or(MailError::AuthExpired)?;
        let tokens = oauth::refresh(&self.client, &refresh_token)
            .await
            .map_err(|_| MailError::AuthExpired)?;
        let access = tokens.access_token.clone();
        cache.insert(
            account_id.clone(),
            CachedToken {
                access_token: access.clone(),
                expires_at: Instant::now() + Duration::from_secs(tokens.expires_in.saturating_sub(60)),
            },
        );
        Ok(access)
    }

    async fn get_json<T: serde::de::DeserializeOwned>(
        &self,
        account_id: &AccountId,
        url: &str,
    ) -> Result<T, MailError> {
        let token = self.access_token(account_id).await?;
        let resp = self
            .http
            .get(url)
            .bearer_auth(token)
            .send()
            .await
            .map_err(|e| MailError::Network(e.to_string()))?;
        Self::check(resp).await?.json::<T>().await.map_err(|e| MailError::Provider(e.to_string()))
    }

    async fn post_json(
        &self,
        account_id: &AccountId,
        url: &str,
        body: &serde_json::Value,
    ) -> Result<(), MailError> {
        let token = self.access_token(account_id).await?;
        let resp = self
            .http
            .post(url)
            .bearer_auth(token)
            .json(body)
            .send()
            .await
            .map_err(|e| MailError::Network(e.to_string()))?;
        Self::check(resp).await.map(|_| ())
    }

    async fn check(resp: reqwest::Response) -> Result<reqwest::Response, MailError> {
        let status = resp.status();
        if status.is_success() {
            return Ok(resp);
        }
        let retry_after = resp
            .headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse().ok());
        let body = resp.text().await.unwrap_or_default();
        Err(match status.as_u16() {
            401 => MailError::AuthExpired,
            429 => MailError::RateLimited { retry_after_secs: retry_after },
            _ => MailError::Provider(format!("{status}: {body}")),
        })
    }
}

// ---------------------------------------------------------------- wire types

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireProfile {
    email_address: String,
    history_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireThreadsList {
    #[serde(default)]
    threads: Vec<WireThreadRef>,
    next_page_token: Option<String>,
}

#[derive(Deserialize)]
struct WireThreadRef {
    id: String,
}

#[derive(Deserialize)]
struct WireThread {
    id: String,
    #[serde(default)]
    messages: Vec<WireMessage>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireMessage {
    id: String,
    #[serde(default)]
    label_ids: Vec<String>,
    #[serde(default)]
    snippet: String,
    #[serde(default)]
    internal_date: String,
    payload: Option<WirePart>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WirePart {
    #[serde(default)]
    mime_type: String,
    #[serde(default)]
    headers: Vec<WireHeader>,
    body: Option<WireBody>,
    #[serde(default)]
    parts: Vec<WirePart>,
}

#[derive(Deserialize)]
struct WireHeader {
    name: String,
    value: String,
}

#[derive(Deserialize)]
struct WireBody {
    data: Option<String>,
}

// ------------------------------------------------------------------ mapping

fn header<'a>(part: &'a WirePart, name: &str) -> Option<&'a str> {
    part.headers
        .iter()
        .find(|h| h.name.eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str())
}

/// Gmail's `snippet` is HTML-entity-encoded (&#39;, &lt;, &amp;…). Decode the
/// named + numeric forms that actually occur; anything unknown passes through.
fn decode_entities(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let Some(end) = rest[..rest.len().min(10)].find(';') else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let entity = &rest[1..end];
        let decoded = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "nbsp" => Some('\u{a0}'),
            _ => entity
                .strip_prefix('#')
                .and_then(|n| {
                    n.strip_prefix('x')
                        .or_else(|| n.strip_prefix('X'))
                        .map_or_else(|| n.parse::<u32>().ok(), |h| u32::from_str_radix(h, 16).ok())
                })
                .and_then(char::from_u32),
        };
        match decoded {
            Some(c) => {
                out.push(c);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// "Priya Nair <priya@acme.co>" → "Priya Nair" (falls back to the address).
fn display_name(from: &str) -> String {
    let name = from.split('<').next().unwrap_or("").trim().trim_matches('"');
    if name.is_empty() { from.trim().to_string() } else { name.to_string() }
}

/// "Priya Nair <priya@acme.co>" → "priya@acme.co".
fn bare_addr(from: &str) -> String {
    from.split('<')
        .nth(1)
        .and_then(|s| s.split('>').next())
        .unwrap_or(from)
        .trim()
        .to_string()
}

fn decode_body(data: &str) -> Option<String> {
    base64::engine::general_purpose::URL_SAFE
        .decode(data)
        .ok()
        .and_then(|b| String::from_utf8(b).ok())
}

/// Depth-first search for the first part matching `mime`.
fn find_part<'a>(part: &'a WirePart, mime: &str) -> Option<&'a WirePart> {
    if part.mime_type == mime {
        return Some(part);
    }
    part.parts.iter().find_map(|p| find_part(p, mime))
}

fn to_message(account_id: &AccountId, thread_id: &str, w: &WireMessage) -> Message {
    let payload = w.payload.as_ref();
    let from_addr = payload.and_then(|p| header(p, "From")).unwrap_or("").to_string();
    let to_addrs = payload
        .and_then(|p| header(p, "To"))
        .map(|v| v.split(',').map(|s| s.trim().to_string()).collect())
        .unwrap_or_default();
    let body_of = |mime: &str| {
        payload
            .and_then(|p| find_part(p, mime))
            .and_then(|p| p.body.as_ref())
            .and_then(|b| b.data.as_deref())
            .and_then(decode_body)
    };
    // Single-part messages carry the body on the payload itself.
    let direct_body = || {
        payload
            .and_then(|p| p.body.as_ref())
            .and_then(|b| b.data.as_deref())
            .and_then(decode_body)
    };
    let body_html = body_of("text/html").or_else(|| {
        payload.filter(|p| p.mime_type == "text/html").and_then(|_| direct_body())
    });
    let body_text = body_of("text/plain").or_else(|| {
        payload.filter(|p| p.mime_type == "text/plain").and_then(|_| direct_body())
    });
    Message {
        id: w.id.clone(),
        thread_id: thread_id.to_string(),
        account_id: account_id.clone(),
        from_addr,
        to_addrs,
        date: w.internal_date.parse().unwrap_or(0),
        snippet: decode_entities(&w.snippet),
        body_html,
        body_text,
        label_ids: w.label_ids.clone(),
        is_read: !w.label_ids.iter().any(|l| l == "UNREAD"),
    }
}

fn to_thread(account_id: &AccountId, wire: &WireThread) -> (Thread, Vec<Message>) {
    let messages: Vec<Message> = wire.messages.iter().map(|m| to_message(account_id, &wire.id, m)).collect();
    let last = messages.last();
    let subject = wire
        .messages
        .first()
        .and_then(|m| m.payload.as_ref())
        .and_then(|p| header(p, "Subject"))
        .unwrap_or("(no subject)")
        .to_string();
    let thread = Thread {
        id: wire.id.clone(),
        account_id: account_id.clone(),
        subject,
        snippet: last.map(|m| m.snippet.clone()).unwrap_or_default(),
        last_msg_at: messages.iter().map(|m| m.date).max().unwrap_or(0),
        is_read: messages.iter().all(|m| m.is_read),
        is_inbox: messages.iter().any(|m| m.label_ids.iter().any(|l| l == "INBOX")),
        is_archived: false,
        msg_count: messages.len() as i64,
        from_summary: last.map(|m| display_name(&m.from_addr)).unwrap_or_default(),
        last_from_addr: last.map(|m| bare_addr(&m.from_addr)).unwrap_or_default(),
    };
    (thread, messages)
}

/// RFC 2047 encoded-word for header values; plain ASCII passes through.
fn encode_header(value: &str) -> String {
    if value.is_ascii() {
        value.to_string()
    } else {
        format!("=?UTF-8?B?{}?=", base64::engine::general_purpose::STANDARD.encode(value))
    }
}

/// Minimal RFC 2822 text/plain message. Gmail fills in From/Date/Message-ID.
fn build_mime(to: &[String], cc: &[String], bcc: &[String], subject: &str, body: &str) -> String {
    let mut mime = String::new();
    mime.push_str(&format!("To: {}\r\n", to.join(", ")));
    if !cc.is_empty() {
        mime.push_str(&format!("Cc: {}\r\n", cc.join(", ")));
    }
    if !bcc.is_empty() {
        mime.push_str(&format!("Bcc: {}\r\n", bcc.join(", ")));
    }
    mime.push_str(&format!("Subject: {}\r\n", encode_header(subject)));
    mime.push_str("MIME-Version: 1.0\r\n");
    mime.push_str("Content-Type: text/plain; charset=UTF-8\r\n");
    mime.push_str("Content-Transfer-Encoding: base64\r\n\r\n");
    // base64 body sidesteps line-length and bare-CRLF pitfalls entirely.
    mime.push_str(&base64::engine::general_purpose::STANDARD.encode(body));
    mime.push_str("\r\n");
    mime
}

// ----------------------------------------------------------------- provider

impl MailProvider for GmailProvider {
    async fn profile(&self, account_id: &AccountId) -> Result<Profile, MailError> {
        let p: WireProfile = self.get_json(account_id, &format!("{API}/profile")).await?;
        Ok(Profile { email: p.email_address, history_id: p.history_id })
    }

    async fn list_recent(
        &self,
        account_id: &AccountId,
        window_days: u32,
        page_token: Option<String>,
    ) -> Result<ThreadPage, MailError> {
        let mut url = url::Url::parse(&format!("{API}/threads")).expect("static url");
        url.query_pairs_mut()
            .append_pair("labelIds", "INBOX")
            .append_pair("q", &format!("newer_than:{window_days}d"))
            .append_pair("maxResults", "100");
        if let Some(t) = &page_token {
            url.query_pairs_mut().append_pair("pageToken", t);
        }
        let list: WireThreadsList = self.get_json(account_id, url.as_str()).await?;

        // Backfill list rendering needs metadata only (DESIGN.md tiering).
        // Bounded fan-out per chunk keeps Gmail quota happy.
        let urls: Vec<String> = list
            .threads
            .iter()
            .map(|t| {
                format!(
                    "{API}/threads/{}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject",
                    t.id
                )
            })
            .collect();
        let mut threads = Vec::with_capacity(urls.len());
        for chunk in urls.chunks(FETCH_CONCURRENCY) {
            let futs: Vec<_> = chunk
                .iter()
                .map(|url| async move {
                    let wire: WireThread = self.get_json(account_id, url).await?;
                    Ok::<_, MailError>(to_thread(account_id, &wire))
                })
                .collect();
            threads.extend(futures::future::try_join_all(futs).await?);
        }

        Ok(ThreadPage { threads, next_page_token: list.next_page_token })
    }

    async fn fetch_bodies(
        &self,
        account_id: &AccountId,
        thread_id: &ThreadId,
    ) -> Result<Vec<Message>, MailError> {
        let wire: WireThread = self
            .get_json(account_id, &format!("{API}/threads/{thread_id}?format=full"))
            .await?;
        Ok(to_thread(account_id, &wire).1)
    }

    async fn apply(&self, account_id: &AccountId, mutation: &Mutation) -> Result<(), MailError> {
        if let Mutation::Send { to, cc, bcc, subject, body_text, reply_to_thread } = mutation {
            let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
                .encode(build_mime(to, cc, bcc, subject, body_text));
            let mut payload = serde_json::json!({ "raw": raw });
            if let Some(tid) = reply_to_thread {
                payload["threadId"] = serde_json::json!(tid);
            }
            return self
                .post_json(account_id, &format!("{API}/messages/send"), &payload)
                .await;
        }
        let (thread_id, body) = match mutation {
            Mutation::Archive { thread_id } => {
                (thread_id, serde_json::json!({ "removeLabelIds": ["INBOX"] }))
            }
            Mutation::MarkRead { thread_id, read } => {
                let key = if *read { "removeLabelIds" } else { "addLabelIds" };
                (thread_id, serde_json::json!({ key: ["UNREAD"] }))
            }
            Mutation::Trash { thread_id } => {
                return self
                    .post_json(
                        account_id,
                        &format!("{API}/threads/{thread_id}/trash"),
                        &serde_json::json!({}),
                    )
                    .await;
            }
            Mutation::Send { .. } => unreachable!("handled above"),
        };
        self.post_json(account_id, &format!("{API}/threads/{thread_id}/modify"), &body)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mime_message_shape() {
        let mime = build_mime(
            &["a@x.com".to_string()],
            &["c@x.com".to_string()],
            &[],
            "Héllo",
            "body text",
        );
        assert!(mime.starts_with("To: a@x.com\r\n"));
        assert!(mime.contains("Cc: c@x.com\r\n"));
        assert!(!mime.contains("Bcc:"));
        assert!(mime.contains("Subject: =?UTF-8?B?SMOpbGxv?=\r\n"));
        assert!(mime.contains("Content-Type: text/plain; charset=UTF-8\r\n"));
        // body is the last base64 chunk
        let b64 = mime.rsplit("\r\n\r\n").next().unwrap().trim();
        let decoded = base64::engine::general_purpose::STANDARD.decode(b64).unwrap();
        assert_eq!(String::from_utf8(decoded).unwrap(), "body text");
    }

    #[test]
    fn ascii_subject_not_encoded() {
        let mime = build_mime(&["a@x.com".to_string()], &[], &[], "Plain subject", "b");
        assert!(mime.contains("Subject: Plain subject\r\n"));
    }

    #[test]
    fn entities_are_decoded() {
        assert_eq!(decode_entities("Su&#39;s card &lt;a&gt; &amp; more"), "Su's card <a> & more");
        assert_eq!(decode_entities("caf&#xE9; &nbsp;ok"), "café \u{a0}ok");
        assert_eq!(decode_entities("5 & 6 &unknown; &#zz;"), "5 & 6 &unknown; &#zz;");
        assert_eq!(decode_entities("no entities"), "no entities");
    }

    #[test]
    fn display_name_variants() {
        assert_eq!(display_name("Priya Nair <p@acme.co>"), "Priya Nair");
        assert_eq!(display_name("\"Nair, Priya\" <p@acme.co>"), "Nair, Priya");
        assert_eq!(display_name("p@acme.co"), "p@acme.co");
    }

    #[test]
    fn bare_addr_variants() {
        assert_eq!(bare_addr("Priya Nair <p@acme.co>"), "p@acme.co");
        assert_eq!(bare_addr("p@acme.co"), "p@acme.co");
        assert_eq!(bare_addr("<p@acme.co>"), "p@acme.co");
    }

    #[test]
    fn wire_thread_maps_to_domain() {
        let json = serde_json::json!({
            "id": "t1",
            "messages": [{
                "id": "m1",
                "labelIds": ["INBOX", "UNREAD"],
                "snippet": "Hello there",
                "internalDate": "1756600000000",
                "payload": {
                    "mimeType": "multipart/alternative",
                    "headers": [
                        {"name": "From", "value": "Priya Nair <p@acme.co>"},
                        {"name": "To", "value": "me@example.com"},
                        {"name": "Subject", "value": "Q3 plan"}
                    ],
                    "parts": [
                        {"mimeType": "text/plain", "headers": [], "body": {"data": "SGVsbG8gdGhlcmU="}},
                        {"mimeType": "text/html", "headers": [], "body": {"data": "PGI-SGk8L2I-"}}
                    ]
                }
            }]
        });
        let wire: WireThread = serde_json::from_value(json).unwrap();
        let (thread, messages) = to_thread(&"acc".to_string(), &wire);

        assert_eq!(thread.subject, "Q3 plan");
        assert_eq!(thread.from_summary, "Priya Nair");
        assert!(!thread.is_read);
        assert!(thread.is_inbox);
        assert_eq!(thread.last_msg_at, 1_756_600_000_000);
        assert_eq!(messages[0].body_text.as_deref(), Some("Hello there"));
        assert_eq!(messages[0].body_html.as_deref(), Some("<b>Hi</b>"));
        assert_eq!(messages[0].to_addrs, vec!["me@example.com"]);
    }
}
