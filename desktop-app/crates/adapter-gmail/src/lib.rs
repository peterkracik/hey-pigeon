//! Gmail REST adapter: implements `MailProvider` over the Gmail v1 API.
//! Only this crate speaks Gmail's wire format — the core sees domain types.

pub mod drive;
pub mod oauth;
pub mod push;

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use heypigeon_core::domain::*;
use heypigeon_core::ports::{
    HistoryChange, HistoryPage, MailError, MailProvider, SecretStore, ThreadPage, WatchState,
};
use serde::Deserialize;
use tokio::sync::Mutex;

use oauth::{ClientConfig, TokenSet};

const API: &str = "https://gmail.googleapis.com/gmail/v1/users/me";
const UPLOAD_API: &str = "https://gmail.googleapis.com/upload/gmail/v1/users/me";
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
    /// (account, sender-email) → contact photo URL; negative results cached too.
    photo_cache: Mutex<HashMap<(AccountId, String), Option<String>>>,
    /// Accounts whose People-API search cache was warmed this session.
    photo_warmed: Mutex<std::collections::HashSet<AccountId>>,
    /// (account, composer draft key) → Gmail draft id, so repeated saves
    /// update one draft without waiting on Gmail's search index.
    draft_ids: Mutex<HashMap<(AccountId, String), String>>,
}

impl GmailProvider {
    pub fn new(client: ClientConfig, secrets: Arc<dyn SecretStore + Send + Sync>) -> Self {
        Self {
            http: reqwest::Client::new(),
            client,
            secrets,
            tokens: Mutex::new(HashMap::new()),
            photo_cache: Mutex::new(HashMap::new()),
            photo_warmed: Mutex::new(std::collections::HashSet::new()),
            draft_ids: Mutex::new(HashMap::new()),
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
                expires_at: Instant::now()
                    + Duration::from_secs(tokens.expires_in.saturating_sub(60)),
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
        // Only a rejected grant means the account is disconnected. A
        // transport failure (offline, DNS) must stay `Network`: the app
        // tells the user to re-connect on `AuthExpired`, and a flaky
        // connection must never trigger that.
        let tokens = oauth::refresh(&self.client, &refresh_token)
            .await
            .map_err(|e| match e {
                oauth::OauthError::Token(body) => {
                    log::warn!("token refresh for {account_id} rejected: {body}");
                    MailError::AuthExpired
                }
                oauth::OauthError::Http(e) if e.is_decode() => MailError::Provider(e.to_string()),
                other => MailError::Network(other.to_string()),
            })?;
        let access = tokens.access_token.clone();
        cache.insert(
            account_id.clone(),
            CachedToken {
                access_token: access.clone(),
                expires_at: Instant::now()
                    + Duration::from_secs(tokens.expires_in.saturating_sub(60)),
            },
        );
        Ok(access)
    }

    /// Contact photo for a sender via the People API (contacts +
    /// otherContacts — people you've corresponded with). None for strangers.
    pub async fn contact_photo(&self, account_id: &AccountId, email: &str) -> Option<String> {
        let key = (account_id.clone(), email.to_lowercase());
        if let Some(cached) = self.photo_cache.lock().await.get(&key) {
            return cached.clone();
        }
        // People API search caches need one warmup request per session.
        if self.photo_warmed.lock().await.insert(account_id.clone()) {
            let _ = self
                .get_json::<serde_json::Value>(
                    account_id,
                    "https://people.googleapis.com/v1/people:searchContacts?query=&readMask=photos",
                )
                .await;
            let _ = self
                .get_json::<serde_json::Value>(
                    account_id,
                    "https://people.googleapis.com/v1/otherContacts:search?query=&readMask=photos",
                )
                .await;
        }
        let query = urlencode(email);
        let mut found: Option<String> = None;
        for endpoint in [
            format!("https://people.googleapis.com/v1/people:searchContacts?query={query}&readMask=photos,emailAddresses&pageSize=3"),
            format!("https://people.googleapis.com/v1/otherContacts:search?query={query}&readMask=photos,emailAddresses&pageSize=3"),
        ] {
            if found.is_some() {
                break;
            }
            if let Ok(resp) = self.get_json::<WirePeopleSearch>(account_id, &endpoint).await {
                found = resp
                    .results
                    .unwrap_or_default()
                    .into_iter()
                    .filter_map(|r| r.person)
                    .flat_map(|p| p.photos.unwrap_or_default())
                    .find(|p| !p.default.unwrap_or(false) && p.url.is_some())
                    .and_then(|p| p.url);
            }
        }
        self.photo_cache.lock().await.insert(key, found.clone());
        found
    }

    /// Google profile photo for the signed-in user (userinfo.profile scope).
    /// Absent photo or a failed call is not an error worth surfacing.
    pub async fn fetch_profile_photo(&self, account_id: &AccountId) -> Option<String> {
        #[derive(Deserialize)]
        struct UserInfo {
            picture: Option<String>,
        }
        let info: UserInfo = self
            .get_json(
                account_id,
                "https://openidconnect.googleapis.com/v1/userinfo",
            )
            .await
            .ok()?;
        info.picture
    }

    /// One page of `threads.list` for a search query, every thread
    /// fetched at the metadata tier — the shape both backfill walks share.
    async fn list_query(
        &self,
        account_id: &AccountId,
        q: &str,
        page_token: Option<String>,
    ) -> Result<ThreadPage, MailError> {
        let mut url = url::Url::parse(&format!("{API}/threads")).expect("static url");
        // No labelIds filter: the backfill covers the whole corpus
        // (SENT/DRAFT/STARRED/user labels), and includeSpamTrash pulls the
        // Spam + Trash folders — threads.list excludes them by default.
        url.query_pairs_mut()
            .append_pair("q", q)
            .append_pair("includeSpamTrash", "true")
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

        Ok(ThreadPage {
            threads,
            next_page_token: list.next_page_token,
        })
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
        Self::check(resp)
            .await?
            .json::<T>()
            .await
            .map_err(|e| MailError::Provider(e.to_string()))
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

    /// `post_json` for the few endpoints whose response body matters
    /// (`users.watch` returns the lease it created).
    async fn post_json_returning<T: serde::de::DeserializeOwned>(
        &self,
        account_id: &AccountId,
        url: &str,
        body: &serde_json::Value,
    ) -> Result<T, MailError> {
        let token = self.access_token(account_id).await?;
        let resp = self
            .http
            .post(url)
            .bearer_auth(token)
            .json(body)
            .send()
            .await
            .map_err(|e| MailError::Network(e.to_string()))?;
        Self::check(resp)
            .await?
            .json::<T>()
            .await
            .map_err(|e| MailError::Provider(e.to_string()))
    }

    /// Media upload: multipart/related with JSON metadata + a raw rfc822
    /// message. Required for sends with attachments (35 MB cap; the plain
    /// JSON endpoint only takes small payloads).
    async fn post_upload_rfc822(
        &self,
        account_id: &AccountId,
        metadata: &serde_json::Value,
        rfc822: &str,
    ) -> Result<(), MailError> {
        self.upload_rfc822(
            account_id,
            reqwest::Method::POST,
            &format!("{UPLOAD_API}/messages/send?uploadType=multipart"),
            metadata,
            rfc822,
        )
        .await
        .map(|_| ())
    }

    /// Multipart/related upload to any media endpoint (send, drafts),
    /// returning the response body.
    async fn upload_rfc822(
        &self,
        account_id: &AccountId,
        method: reqwest::Method,
        url: &str,
        metadata: &serde_json::Value,
        rfc822: &str,
    ) -> Result<serde_json::Value, MailError> {
        // '-' is not in the base64 alphabet and the inner MIME uses distinct
        // boundary strings, so this outer boundary cannot be forged.
        const B: &str = "hp_rel_7MA4YWxkTrZu0gW";
        let token = self.access_token(account_id).await?;
        let body = format!(
            "--{B}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{metadata}\r\n--{B}\r\nContent-Type: message/rfc822\r\n\r\n{rfc822}\r\n--{B}--\r\n"
        );
        let resp = self
            .http
            .request(method, url)
            .bearer_auth(token)
            .header(
                "Content-Type",
                format!("multipart/related; boundary=\"{B}\""),
            )
            .body(body)
            .send()
            .await
            .map_err(|e| MailError::Network(e.to_string()))?;
        Self::check(resp)
            .await?
            .json()
            .await
            .map_err(|e| MailError::Provider(e.to_string()))
    }

    /// The Gmail draft saved under a composer key: the id cached from an
    /// earlier save, else a search on the Message-ID the draft carries
    /// (after a restart).
    async fn find_draft(
        &self,
        account_id: &AccountId,
        key: &str,
    ) -> Result<Option<String>, MailError> {
        let cache_key = (account_id.clone(), key.to_string());
        if let Some(id) = self.draft_ids.lock().await.get(&cache_key) {
            return Ok(Some(id.clone()));
        }
        let mut url = url::Url::parse(&format!("{API}/drafts")).expect("static url");
        url.query_pairs_mut()
            .append_pair("q", &format!("rfc822msgid:{}", draft_message_id(key)))
            .append_pair("maxResults", "1");
        let list: serde_json::Value = self.get_json(account_id, url.as_str()).await?;
        if let Some(id) = list["drafts"][0]["id"].as_str() {
            return Ok(Some(id.to_string()));
        }
        // A draft reopened from the Drafts folder is keyed by its Gmail
        // message id until the first save stamps the composer Message-ID.
        if !is_gmail_message_id(key) {
            return Ok(None);
        }
        let list: WireDraftList = self
            .get_json(account_id, &format!("{API}/drafts?maxResults=500"))
            .await?;
        Ok(list
            .drafts
            .into_iter()
            .find(|d| d.message.id == key)
            .map(|d| d.id))
    }

    /// drafts.create / drafts.update with the composer's current content.
    async fn save_draft(
        &self,
        account_id: &AccountId,
        key: &str,
        rfc822: &str,
        reply_to_thread: Option<&ThreadId>,
    ) -> Result<(), MailError> {
        let existing = self.find_draft(account_id, key).await?;
        let mut message = serde_json::json!({});
        if let Some(tid) = reply_to_thread {
            message["threadId"] = serde_json::json!(tid);
        }
        let (method, url) = match &existing {
            Some(id) => (
                reqwest::Method::PUT,
                format!("{UPLOAD_API}/drafts/{id}?uploadType=multipart"),
            ),
            None => (
                reqwest::Method::POST,
                format!("{UPLOAD_API}/drafts?uploadType=multipart"),
            ),
        };
        let meta = serde_json::json!({ "message": message });
        let saved = match self
            .upload_rfc822(account_id, method, &url, &meta, rfc822)
            .await
        {
            // Deleted elsewhere (e.g. in Gmail) since the last save: start over.
            Err(e) if existing.is_some() && is_not_found(&e) => {
                self.draft_ids
                    .lock()
                    .await
                    .remove(&(account_id.clone(), key.to_string()));
                let url = format!("{UPLOAD_API}/drafts?uploadType=multipart");
                self.upload_rfc822(account_id, reqwest::Method::POST, &url, &meta, rfc822)
                    .await?
            }
            r => r?,
        };
        if let Some(id) = saved["id"].as_str() {
            self.draft_ids
                .lock()
                .await
                .insert((account_id.clone(), key.to_string()), id.to_string());
        }
        Ok(())
    }

    async fn delete_draft(&self, account_id: &AccountId, key: &str) -> Result<(), MailError> {
        let Some(id) = self.find_draft(account_id, key).await? else {
            return Ok(());
        };
        match self.delete(account_id, &format!("{API}/drafts/{id}")).await {
            Err(e) if !is_not_found(&e) => return Err(e),
            _ => {}
        }
        self.draft_ids
            .lock()
            .await
            .remove(&(account_id.clone(), key.to_string()));
        Ok(())
    }

    async fn patch_json(
        &self,
        account_id: &AccountId,
        url: &str,
        body: &serde_json::Value,
    ) -> Result<(), MailError> {
        let token = self.access_token(account_id).await?;
        let resp = self
            .http
            .patch(url)
            .bearer_auth(token)
            .json(body)
            .send()
            .await
            .map_err(|e| MailError::Network(e.to_string()))?;
        Self::check(resp).await.map(|_| ())
    }

    async fn delete(&self, account_id: &AccountId, url: &str) -> Result<(), MailError> {
        let token = self.access_token(account_id).await?;
        let resp = self
            .http
            .delete(url)
            .bearer_auth(token)
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
            429 => MailError::RateLimited {
                retry_after_secs: retry_after,
            },
            // 404 stays a plain provider error — `HistoryExpired` is scoped to
            // the history checkpoint (ports.rs); `list_history` maps it there.
            _ => MailError::Provider(format!("{status}: {body}")),
        })
    }
}

/// Did `check` see an HTTP 404? (`Display` for a 404 status starts with
/// "404", so the Provider payload does too.)
fn is_not_found(e: &MailError) -> bool {
    matches!(e, MailError::Provider(s) if s.starts_with("404"))
}

pub(crate) fn urlencode(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

/// Next delta checkpoint after applying a history page: the newest history
/// record actually returned. The top-level `historyId` is the mailbox's
/// *current* id, which can run ahead of records that haven't surfaced yet —
/// checkpointing it would skip those records; use it only for an empty feed.
fn history_checkpoint(list: &WireHistoryList, start_history_id: &str) -> String {
    list.history
        .iter()
        .filter_map(|h| h.id.as_ref().and_then(|s| s.parse::<u64>().ok()))
        .max()
        .map(|id| id.to_string())
        .unwrap_or_else(|| {
            list.history_id
                .clone()
                .unwrap_or_else(|| start_history_id.to_string())
        })
}

// ---------------------------------------------------------------- wire types

#[derive(Deserialize)]
struct WirePeopleSearch {
    results: Option<Vec<WirePeopleResult>>,
}

#[derive(Deserialize)]
struct WirePeopleResult {
    person: Option<WirePerson>,
}

#[derive(Deserialize)]
struct WirePerson {
    photos: Option<Vec<WirePhoto>>,
}

#[derive(Deserialize)]
struct WirePhoto {
    url: Option<String>,
    default: Option<bool>,
}

#[derive(Deserialize)]
struct WireLabelsList {
    #[serde(default)]
    labels: Vec<WireLabel>,
}

#[derive(Deserialize)]
struct WireLabel {
    id: String,
    name: String,
    #[serde(rename = "type", default)]
    label_type: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireProfile {
    email_address: String,
    history_id: String,
}

/// `users.watch` response. Both fields arrive as strings (`expiration` is
/// epoch milliseconds), unlike the Pub/Sub message, where `historyId` is
/// a number — the relay handles that side.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireWatch {
    history_id: String,
    expiration: String,
}

impl WireWatch {
    fn into_state(self) -> Result<WatchState, MailError> {
        let expiration_ms = self.expiration.parse::<i64>().map_err(|_| {
            MailError::Provider(format!("watch: bad expiration {:?}", self.expiration))
        })?;
        Ok(WatchState {
            history_id: self.history_id,
            expiration_ms,
        })
    }
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
#[serde(rename_all = "camelCase")]
struct WireHistoryList {
    #[serde(default)]
    history: Vec<WireHistory>,
    next_page_token: Option<String>,
    history_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireHistory {
    /// The history record's own id — the delta checkpoint source.
    id: Option<String>,
    #[serde(default)]
    messages_added: Vec<WireHistoryMessage>,
    #[serde(default)]
    messages_deleted: Vec<WireHistoryMessage>,
    #[serde(default)]
    labels_added: Vec<WireHistoryLabels>,
    #[serde(default)]
    labels_removed: Vec<WireHistoryLabels>,
}

#[derive(Deserialize)]
struct WireHistoryMessage {
    message: WireMessageRef,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireHistoryLabels {
    message: WireMessageRef,
    #[serde(default)]
    label_ids: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireMessageRef {
    id: String,
    thread_id: String,
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
    /// Non-empty on an attachment part (Gmail sets it on the part carrying
    /// the file, empty on inline text/html body parts).
    #[serde(default)]
    filename: String,
}

#[derive(Deserialize)]
struct WireHeader {
    name: String,
    value: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireBody {
    data: Option<String>,
    /// Set on an attachment part whose bytes are fetched separately
    /// (`messages.attachments.get`); small ones carry `data` inline.
    #[serde(default)]
    attachment_id: Option<String>,
    /// Bytes of the part, as Gmail counts them (0 when absent).
    #[serde(default)]
    size: i64,
}

#[derive(Deserialize)]
struct WireDraftList {
    #[serde(default)]
    drafts: Vec<WireDraftRef>,
}

#[derive(Deserialize)]
struct WireDraftRef {
    id: String,
    message: WireDraftMessage,
}

#[derive(Deserialize)]
struct WireDraftMessage {
    id: String,
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
        // Byte-wise scan: ';' is ASCII, so the position is a char boundary
        // even when multibyte text sits inside the 10-byte lookahead window
        // (slicing at byte 10 panicked mid-char on snippets like "&… vý…").
        let Some(end) = rest.bytes().take(10).position(|b| b == b';') else {
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
                        .map_or_else(
                            || n.parse::<u32>().ok(),
                            |h| u32::from_str_radix(h, 16).ok(),
                        )
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

/// Lossy on purpose: a legacy-charset body (ISO-8859-2 Slovak mail, say)
/// is better shown with a few replacement characters than dropped — a
/// `None` here falls back to the one-line snippet for good, since the
/// thread's bodies are never refetched once any message has one.
fn decode_body(data: &str) -> Option<String> {
    base64::engine::general_purpose::URL_SAFE
        .decode(data)
        .ok()
        .map(|b| String::from_utf8_lossy(&b).into_owned())
}

/// Depth-first search for the first part matching `mime`.
fn find_part<'a>(part: &'a WirePart, mime: &str) -> Option<&'a WirePart> {
    if part.mime_type == mime {
        return Some(part);
    }
    part.parts.iter().find_map(|p| find_part(p, mime))
}

/// True if this part or any descendant is an attachment (non-empty filename).
fn part_has_attachment(part: &WirePart) -> bool {
    !part.filename.is_empty() || part.parts.iter().any(part_has_attachment)
}

fn to_message(account_id: &AccountId, thread_id: &str, w: &WireMessage) -> Message {
    let payload = w.payload.as_ref();
    let from_addr = payload
        .and_then(|p| header(p, "From"))
        .unwrap_or("")
        .to_string();
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
        payload
            .filter(|p| p.mime_type == "text/html")
            .and_then(|_| direct_body())
    });
    let body_text = body_of("text/plain").or_else(|| {
        payload
            .filter(|p| p.mime_type == "text/plain")
            .and_then(|_| direct_body())
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
    let messages: Vec<Message> = wire
        .messages
        .iter()
        .map(|m| to_message(account_id, &wire.id, m))
        .collect();
    let last = messages.last();
    let subject = wire
        .messages
        .first()
        .and_then(|m| m.payload.as_ref())
        .and_then(|p| header(p, "Subject"))
        .unwrap_or("(no subject)")
        .to_string();
    let labels = heypigeon_core::sync::thread_labels_union(&messages);
    // The row names the other party, never the user's own reply. Account ids
    // are the account's email address, which is what the SENT/From check needs.
    let sender = heypigeon_core::sync::list_sender(&messages, account_id);
    let thread = Thread {
        id: wire.id.clone(),
        account_id: account_id.clone(),
        subject,
        snippet: last.map(|m| m.snippet.clone()).unwrap_or_default(),
        last_msg_at: messages.iter().map(|m| m.date).max().unwrap_or(0),
        is_read: messages.iter().all(|m| m.is_read),
        is_inbox: labels.iter().any(|l| l == "INBOX"),
        // Archive semantics live in core (sync::derive_is_archived): not in
        // the inbox, not trash/spam/draft, and not sent-only.
        is_archived: heypigeon_core::sync::derive_is_archived(&labels, &messages),
        msg_count: messages.len() as i64,
        from_summary: sender.name,
        last_from_addr: sender.addr,
        // Local-only metadata — the wire never carries a schedule.
        scheduled_at: None,
        needs_reply: false,
        follow_up_since: None,
        labels,
        has_attachment: wire
            .messages
            .iter()
            .any(|m| m.payload.as_ref().is_some_and(part_has_attachment)),
        // Local-only metadata — the wire never carries Jev triage results.
        priority: None,
        triage_label_ids: Vec::new(),
    };
    (thread, messages)
}

/// Request body for `users.labels.patch` — rename only, visibility fields
/// stay untouched (PATCH semantics: omitted fields are left as-is).
fn label_patch_body(new_name: &str) -> serde_json::Value {
    serde_json::json!({ "name": new_name })
}

/// RFC 2047 encoded-word for header values; plain ASCII passes through.
fn encode_header(value: &str) -> String {
    if value.is_ascii() {
        value.to_string()
    } else {
        format!(
            "=?UTF-8?B?{}?=",
            base64::engine::general_purpose::STANDARD.encode(value)
        )
    }
}

/// Minimal RFC 2822 message. Gmail fills in From/Date/Message-ID. With an
/// HTML body: multipart/alternative (plain part first, html preferred).
/// With attachments: multipart/mixed wrapping the body plus one part each.
fn build_mime(
    to: &[String],
    cc: &[String],
    bcc: &[String],
    subject: &str,
    body: &str,
    body_html: Option<&str>,
    attachments: &[OutAttachment],
) -> String {
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
    // base64 bodies sidestep line-length and bare-CRLF pitfalls entirely
    // (and '-' is outside the base64 alphabet, so a part can never fake a
    // boundary line).
    let b64 = |s: &str| base64::engine::general_purpose::STANDARD.encode(s);
    // Body block: headers + content, without the top-level message headers.
    let body_block = match body_html {
        None => format!(
            "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n{}\r\n",
            b64(body)
        ),
        Some(html) => {
            const ALT: &str = "hp.alt.7MA4YWxkTrZu0gW";
            let mut s = format!("Content-Type: multipart/alternative; boundary=\"{ALT}\"\r\n\r\n");
            for (ctype, part) in [("text/plain", body), ("text/html", html)] {
                s.push_str(&format!("--{ALT}\r\nContent-Type: {ctype}; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n{}\r\n", b64(part)));
            }
            s.push_str(&format!("--{ALT}--\r\n"));
            s
        }
    };
    if attachments.is_empty() {
        mime.push_str(&body_block);
        return mime;
    }
    const MIX: &str = "hp.mix.7MA4YWxkTrZu0gW";
    mime.push_str(&format!(
        "Content-Type: multipart/mixed; boundary=\"{MIX}\"\r\n\r\n"
    ));
    mime.push_str(&format!("--{MIX}\r\n"));
    mime.push_str(&body_block);
    for a in attachments {
        // ponytail: quoted UTF-8 filename, no RFC 2231 encoding — modern
        // clients tolerate it; add encoding if a client mangles names.
        let name: String = a
            .filename
            .chars()
            .filter(|c| !matches!(c, '"' | '\r' | '\n'))
            .collect();
        let ctype = if a.mime_type.is_empty() {
            "application/octet-stream"
        } else {
            &a.mime_type
        };
        mime.push_str(&format!("--{MIX}\r\n"));
        mime.push_str(&format!("Content-Type: {ctype}; name=\"{name}\"\r\n"));
        mime.push_str(&format!(
            "Content-Disposition: attachment; filename=\"{name}\"\r\n"
        ));
        mime.push_str("Content-Transfer-Encoding: base64\r\n\r\n");
        mime.push_str(&a.data_b64);
        mime.push_str("\r\n");
    }
    mime.push_str(&format!("--{MIX}--\r\n"));
    mime
}

// ----------------------------------------------------------------- provider

impl MailProvider for GmailProvider {
    async fn profile(&self, account_id: &AccountId) -> Result<Profile, MailError> {
        let p: WireProfile = self.get_json(account_id, &format!("{API}/profile")).await?;
        Ok(Profile {
            email: p.email_address,
            history_id: p.history_id,
        })
    }

    async fn list_recent(
        &self,
        account_id: &AccountId,
        window_days: u32,
        page_token: Option<String>,
    ) -> Result<ThreadPage, MailError> {
        self.list_query(
            account_id,
            &format!("newer_than:{window_days}d"),
            page_token,
        )
        .await
    }

    async fn list_before(
        &self,
        account_id: &AccountId,
        before_ms: i64,
        page_token: Option<String>,
    ) -> Result<ThreadPage, MailError> {
        // `before:` takes epoch seconds as well as dates.
        self.list_query(
            account_id,
            &format!("before:{}", before_ms / 1000),
            page_token,
        )
        .await
    }

    async fn list_labels(&self, account_id: &AccountId) -> Result<Vec<Label>, MailError> {
        let list: WireLabelsList = self.get_json(account_id, &format!("{API}/labels")).await?;
        // User-created labels only — system labels (INBOX, SENT, CATEGORY_*…)
        // are folders, not sidebar labels.
        Ok(list
            .labels
            .into_iter()
            .filter(|l| l.label_type == "user")
            .map(|l| Label {
                account_id: account_id.clone(),
                id: l.id,
                name: l.name,
            })
            .collect())
    }

    async fn update_label(
        &self,
        account_id: &AccountId,
        label_id: &str,
        new_name: &str,
    ) -> Result<(), MailError> {
        self.patch_json(
            account_id,
            &format!("{API}/labels/{label_id}"),
            &label_patch_body(new_name),
        )
        .await
    }

    async fn delete_label(&self, account_id: &AccountId, label_id: &str) -> Result<(), MailError> {
        self.delete(account_id, &format!("{API}/labels/{label_id}"))
            .await
    }

    async fn list_history(
        &self,
        account_id: &AccountId,
        start_history_id: &str,
        page_token: Option<String>,
    ) -> Result<HistoryPage, MailError> {
        let mut url = url::Url::parse(&format!("{API}/history")).expect("static url");
        url.query_pairs_mut()
            .append_pair("startHistoryId", start_history_id)
            .append_pair("maxResults", "100");
        if let Some(t) = &page_token {
            url.query_pairs_mut().append_pair("pageToken", t);
        }
        // Gmail 404s an expired/too-old startHistoryId — the one place a 404
        // means "resync from scratch".
        let list: WireHistoryList = self.get_json(account_id, url.as_str()).await.map_err(|e| {
            if is_not_found(&e) {
                MailError::HistoryExpired
            } else {
                e
            }
        })?;

        let mut changes = Vec::new();
        let mut added_threads: Vec<String> = Vec::new();
        for h in &list.history {
            for m in &h.messages_added {
                if !added_threads.contains(&m.message.thread_id) {
                    added_threads.push(m.message.thread_id.clone());
                }
            }
            for m in &h.messages_deleted {
                changes.push(HistoryChange::MessageDeleted {
                    thread_id: m.message.thread_id.clone(),
                    message_id: m.message.id.clone(),
                });
            }
            for l in &h.labels_added {
                changes.push(HistoryChange::LabelsAdded {
                    thread_id: l.message.thread_id.clone(),
                    message_id: l.message.id.clone(),
                    labels: l.label_ids.clone(),
                });
            }
            for l in &h.labels_removed {
                changes.push(HistoryChange::LabelsRemoved {
                    thread_id: l.message.thread_id.clone(),
                    message_id: l.message.id.clone(),
                    labels: l.label_ids.clone(),
                });
            }
        }

        // New mail: refetch the whole thread at the metadata tier (the feed
        // carries no headers) — same shape as backfill, bodies stay lazy.
        for chunk in added_threads.chunks(FETCH_CONCURRENCY) {
            let futs: Vec<_> = chunk
                .iter()
                .map(|tid| async move {
                    let url = format!(
                        "{API}/threads/{tid}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject"
                    );
                    match self.get_json::<WireThread>(account_id, &url).await {
                        Ok(wire) => Ok(Some(to_thread(account_id, &wire))),
                        // 404: thread vanished again since the feed entry.
                        Err(e) if is_not_found(&e) => Ok(None),
                        Err(e) => Err(e),
                    }
                })
                .collect();
            for (thread, messages) in futures::future::try_join_all(futs)
                .await?
                .into_iter()
                .flatten()
            {
                changes.push(HistoryChange::MessageAdded { thread, messages });
            }
        }

        let latest_history_id = history_checkpoint(&list, start_history_id);
        Ok(HistoryPage {
            changes,
            next_page_token: list.next_page_token,
            latest_history_id,
        })
    }

    async fn fetch_bodies(
        &self,
        account_id: &AccountId,
        thread_id: &ThreadId,
    ) -> Result<(bool, Vec<Message>), MailError> {
        let wire: WireThread = self
            .get_json(
                account_id,
                &format!("{API}/threads/{thread_id}?format=full"),
            )
            .await?;
        let (thread, messages) = to_thread(account_id, &wire);
        Ok((thread.has_attachment, messages))
    }

    async fn get_draft(
        &self,
        account_id: &AccountId,
        message_id: &MessageId,
    ) -> Result<DraftContent, MailError> {
        let wire: WireMessage = self
            .get_json(
                account_id,
                &format!("{API}/messages/{message_id}?format=full"),
            )
            .await?;
        let mut draft = to_draft(&wire);
        let mut pending = Vec::new();
        if let Some(p) = wire.payload.as_ref() {
            collect_attachments(p, &mut pending);
        }
        for (filename, mime_type, body) in pending {
            let data = match (body.data.as_deref(), body.attachment_id.as_deref()) {
                (Some(d), _) => d.to_string(),
                (None, Some(aid)) => {
                    let a: WireBody = self
                        .get_json(
                            account_id,
                            &format!("{API}/messages/{message_id}/attachments/{aid}"),
                        )
                        .await?;
                    a.data.unwrap_or_default()
                }
                (None, None) => continue,
            };
            let Some(bytes) = decode_b64url(&data) else {
                continue;
            };
            draft.attachments.push(OutAttachment {
                filename,
                mime_type,
                data_b64: base64::engine::general_purpose::STANDARD.encode(bytes),
            });
        }
        Ok(draft)
    }

    async fn list_attachments(
        &self,
        account_id: &AccountId,
        thread_id: &ThreadId,
    ) -> Result<Vec<AttachmentRef>, MailError> {
        let wire: WireThread = self
            .get_json(
                account_id,
                &format!("{API}/threads/{thread_id}?format=full"),
            )
            .await?;
        Ok(thread_attachments(&wire))
    }

    /// The part's bytes: `messages.attachments.get` for a real attachment
    /// id, the message itself for an `inline:<n>` part (Gmail embeds small
    /// parts in the message payload instead of giving them an id).
    async fn fetch_attachment(
        &self,
        account_id: &AccountId,
        attachment: &AttachmentRef,
    ) -> Result<Vec<u8>, MailError> {
        let message_id = &attachment.message_id;
        let data = if let Some(n) = attachment.attachment_id.strip_prefix("inline:") {
            let index: usize = n
                .parse()
                .map_err(|_| MailError::Provider("bad inline attachment id".into()))?;
            let wire: WireMessage = self
                .get_json(
                    account_id,
                    &format!("{API}/messages/{message_id}?format=full"),
                )
                .await?;
            let mut parts = Vec::new();
            if let Some(p) = wire.payload.as_ref() {
                collect_attachments(p, &mut parts);
            }
            parts
                .get(index)
                .and_then(|(_, _, body)| body.data.clone())
                .ok_or_else(|| MailError::Provider("attachment part is gone".into()))?
        } else {
            let aid = &attachment.attachment_id;
            let body: WireBody = self
                .get_json(
                    account_id,
                    &format!("{API}/messages/{message_id}/attachments/{aid}"),
                )
                .await?;
            body.data.unwrap_or_default()
        };
        decode_b64url(&data).ok_or_else(|| MailError::Provider("attachment is not base64".into()))
    }

    async fn apply(&self, account_id: &AccountId, mutation: &Mutation) -> Result<(), MailError> {
        if let Mutation::Send {
            to,
            cc,
            bcc,
            subject,
            body_text,
            body_html,
            attachments,
            reply_to_thread,
        } = mutation
        {
            let mime = build_mime(
                to,
                cc,
                bcc,
                subject,
                body_text,
                body_html.as_deref(),
                attachments,
            );
            if attachments.is_empty() {
                let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(mime);
                let mut payload = serde_json::json!({ "raw": raw });
                if let Some(tid) = reply_to_thread {
                    payload["threadId"] = serde_json::json!(tid);
                }
                return self
                    .post_json(account_id, &format!("{API}/messages/send"), &payload)
                    .await;
            }
            // With attachments the message can be many MB — the plain JSON
            // endpoint is for small payloads; use the media upload endpoint
            // (multipart/related: JSON metadata + raw rfc822, 35 MB cap).
            let mut meta = serde_json::json!({});
            if let Some(tid) = reply_to_thread {
                meta["threadId"] = serde_json::json!(tid);
            }
            return self.post_upload_rfc822(account_id, &meta, &mime).await;
        }
        if let Mutation::SaveDraft {
            key,
            to,
            cc,
            bcc,
            subject,
            body_text,
            body_html,
            attachments,
            reply_to_thread,
        } = mutation
        {
            let mut mime = format!("Message-ID: {}\r\n", draft_message_id(key));
            mime.push_str(&build_mime(
                to,
                cc,
                bcc,
                subject,
                body_text,
                body_html.as_deref(),
                attachments,
            ));
            return self
                .save_draft(account_id, key, &mime, reply_to_thread.as_ref())
                .await;
        }
        if let Mutation::DeleteDraft { key } = mutation {
            return self.delete_draft(account_id, key).await;
        }
        if let Mutation::Trash { thread_id } = mutation {
            return self
                .post_json(
                    account_id,
                    &format!("{API}/threads/{thread_id}/trash"),
                    &serde_json::json!({}),
                )
                .await;
        }
        let (thread_id, body) =
            modify_body(mutation).expect("Send/Trash/drafts handled above; rest are label flips");
        self.post_json(
            account_id,
            &format!("{API}/threads/{thread_id}/modify"),
            &body,
        )
        .await
    }

    /// `users.watch`: Gmail publishes `{emailAddress, historyId}` to the
    /// Pub/Sub topic on every INBOX change for up to 7 days. Needs only the
    /// `gmail.modify` scope the grant already has; the topic must let
    /// `gmail-api-push@system.gserviceaccount.com` publish (terraform/).
    async fn watch(&self, account_id: &AccountId, topic: &str) -> Result<WatchState, MailError> {
        let body = serde_json::json!({
            "topicName": topic,
            "labelIds": ["INBOX"],
            "labelFilterBehavior": "INCLUDE",
        });
        let wire: WireWatch = self
            .post_json_returning(account_id, &format!("{API}/watch"), &body)
            .await?;
        wire.into_state()
    }

    /// `users.stop`: end the lease early (push turned off, account removed).
    async fn stop_watch(&self, account_id: &AccountId) -> Result<(), MailError> {
        self.post_json(account_id, &format!("{API}/stop"), &serde_json::json!({}))
            .await
    }
}

/// A Gmail message id (hex, no dashes) rather than a composer UUID key.
fn is_gmail_message_id(key: &str) -> bool {
    !key.is_empty() && key.chars().all(|c| c.is_ascii_hexdigit())
}

/// Base64url as Gmail sends it, padded or not.
fn decode_b64url(data: &str) -> Option<Vec<u8>> {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(data.trim_end_matches('='))
        .ok()
}

/// Bare addresses from an address-list header: `"Doe, Jane" <jane@x.com>,
/// bob@y.com` → `["jane@x.com", "bob@y.com"]`. Commas inside quotes or
/// angle brackets do not split.
fn header_addresses(value: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let (mut cur, mut quoted, mut angle) = (String::new(), false, false);
    for c in value.chars() {
        match c {
            '"' => quoted = !quoted,
            '<' if !quoted => angle = true,
            '>' if !quoted => angle = false,
            ',' if !quoted && !angle => {
                parts.push(std::mem::take(&mut cur));
                continue;
            }
            _ => {}
        }
        cur.push(c);
    }
    parts.push(cur);
    parts
        .iter()
        .filter_map(|p| {
            let p = p.trim();
            let addr = match (p.rfind('<'), p.rfind('>')) {
                (Some(a), Some(b)) if a < b => &p[a + 1..b],
                _ => p,
            };
            let addr = addr.trim();
            (!addr.is_empty()).then(|| addr.to_string())
        })
        .collect()
}

/// Headers and bodies of a draft message (attachments are fetched by the caller).
fn to_draft(w: &WireMessage) -> DraftContent {
    let payload = w.payload.as_ref();
    let list = |name: &str| {
        payload
            .and_then(|p| header(p, name))
            .map(header_addresses)
            .unwrap_or_default()
    };
    let m = to_message(&String::new(), "", w);
    DraftContent {
        message_id: w.id.clone(),
        to: list("To"),
        cc: list("Cc"),
        bcc: list("Bcc"),
        subject: payload
            .and_then(|p| header(p, "Subject"))
            .unwrap_or("")
            .to_string(),
        body_text: m.body_text,
        body_html: m.body_html,
        attachments: Vec::new(),
    }
}

/// Attachment parts (non-empty filename), depth first: filename, mime, body.
fn collect_attachments<'a>(part: &'a WirePart, out: &mut Vec<(String, String, &'a WireBody)>) {
    if !part.filename.is_empty() {
        if let Some(b) = part.body.as_ref() {
            out.push((part.filename.clone(), part.mime_type.clone(), b));
        }
    }
    for p in &part.parts {
        collect_attachments(p, out);
    }
}

/// Every attachment part of a thread, message by message, in the order the
/// parts tree lists them. A part Gmail embedded (no `attachmentId`) gets
/// `inline:<n>`, its index among the message's attachment parts, so
/// `fetch_attachment` can find it again in the message payload.
fn thread_attachments(wire: &WireThread) -> Vec<AttachmentRef> {
    let mut out = Vec::new();
    for m in &wire.messages {
        let mut parts = Vec::new();
        if let Some(p) = m.payload.as_ref() {
            collect_attachments(p, &mut parts);
        }
        for (index, (filename, mime_type, body)) in parts.into_iter().enumerate() {
            out.push(AttachmentRef {
                message_id: m.id.clone(),
                attachment_id: body
                    .attachment_id
                    .clone()
                    .unwrap_or_else(|| format!("inline:{index}")),
                filename,
                mime_type: if mime_type.is_empty() {
                    "application/octet-stream".to_string()
                } else {
                    mime_type
                },
                size: body.size,
            });
        }
    }
    out
}

/// Message-ID a saved draft carries, so it can be found again by its
/// composer key (`rfc822msgid:` search) after the id cache is gone.
fn draft_message_id(key: &str) -> String {
    let key: String = key
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
        .collect();
    format!("<draft-{key}@heypigeon.app>")
}

/// `threads.modify` request body for the label-flip mutations. `None` for
/// Send/Trash/drafts, which use dedicated endpoints.
fn modify_body(mutation: &Mutation) -> Option<(&ThreadId, serde_json::Value)> {
    Some(match mutation {
        Mutation::Archive { thread_id } => (
            thread_id,
            serde_json::json!({ "removeLabelIds": ["INBOX"] }),
        ),
        Mutation::Unarchive { thread_id } => {
            (thread_id, serde_json::json!({ "addLabelIds": ["INBOX"] }))
        }
        Mutation::MarkRead { thread_id, read } => {
            let key = if *read {
                "removeLabelIds"
            } else {
                "addLabelIds"
            };
            (thread_id, serde_json::json!({ key: ["UNREAD"] }))
        }
        // Star is sugar over a STARRED label flip (mirrors MarkRead).
        Mutation::Star { thread_id, starred } => {
            let key = if *starred {
                "addLabelIds"
            } else {
                "removeLabelIds"
            };
            (thread_id, serde_json::json!({ key: ["STARRED"] }))
        }
        Mutation::ModifyLabel {
            thread_id,
            label_id,
            add,
        } => {
            let key = if *add {
                "addLabelIds"
            } else {
                "removeLabelIds"
            };
            (thread_id, serde_json::json!({ key: [label_id] }))
        }
        Mutation::Trash { .. }
        | Mutation::Send { .. }
        | Mutation::SaveDraft { .. }
        | Mutation::DeleteDraft { .. } => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_addresses_keep_quoted_commas_and_strip_names() {
        assert_eq!(
            header_addresses("\"Doe, Jane\" <Jane@x.com>, bob@y.com ,, Ann <a@z.org>"),
            vec!["Jane@x.com", "bob@y.com", "a@z.org"]
        );
        assert!(header_addresses("").is_empty());
    }

    #[test]
    fn gmail_message_ids_are_told_apart_from_composer_keys() {
        assert!(is_gmail_message_id("18c2f0a9b7d41e3f"));
        assert!(!is_gmail_message_id("6F9619FF-8B86-D011-B42D-00C04FC964FF"));
        assert!(!is_gmail_message_id(""));
    }

    #[test]
    fn draft_parses_recipients_subject_body_and_attachment_parts() {
        let b64 = |s: &str| base64::engine::general_purpose::URL_SAFE.encode(s);
        let wire: WireMessage = serde_json::from_value(serde_json::json!({
            "id": "abc123",
            "labelIds": ["DRAFT"],
            "payload": {
                "mimeType": "multipart/mixed",
                "headers": [
                    {"name": "To", "value": "\"Doe, Jane\" <jane@x.com>"},
                    {"name": "Cc", "value": "c@x.com"},
                    {"name": "Bcc", "value": "b@x.com"},
                    {"name": "Subject", "value": "Plan"}
                ],
                "parts": [
                    {"mimeType": "text/plain", "body": {"data": b64("hello")}},
                    {"mimeType": "application/pdf", "filename": "a.pdf",
                     "body": {"attachmentId": "att1"}}
                ]
            }
        }))
        .unwrap();
        let d = to_draft(&wire);
        assert_eq!(d.message_id, "abc123");
        assert_eq!(d.to, vec!["jane@x.com"]);
        assert_eq!(d.cc, vec!["c@x.com"]);
        assert_eq!(d.bcc, vec!["b@x.com"]);
        assert_eq!(d.subject, "Plan");
        assert_eq!(d.body_text.as_deref(), Some("hello"));
        let mut parts = Vec::new();
        collect_attachments(wire.payload.as_ref().unwrap(), &mut parts);
        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0].0, "a.pdf");
        assert_eq!(parts[0].2.attachment_id.as_deref(), Some("att1"));
        assert_eq!(decode_b64url(&b64("x?y")).unwrap(), b"x?y");
    }

    #[test]
    fn draft_message_id_is_stable_and_header_safe() {
        assert_eq!(
            draft_message_id("6F9619FF-8B86-D011"),
            "<draft-6F9619FF-8B86-D011@heypigeon.app>"
        );
        assert_eq!(
            draft_message_id("a>\r\nBcc: x"),
            "<draft-aBccx@heypigeon.app>"
        );
    }

    #[test]
    fn decode_body_keeps_non_utf8_bodies() {
        let b64 = |b: &[u8]| base64::engine::general_purpose::URL_SAFE.encode(b);
        assert_eq!(
            decode_body(&b64("Ahoj,\n\nďakujem".as_bytes())).as_deref(),
            Some("Ahoj,\n\nďakujem")
        );
        // ISO-8859-2 "ď" is a lone 0xEF byte: not UTF-8, but the body (and
        // its line breaks) must survive instead of collapsing to the snippet.
        let latin2 = decode_body(&b64(b"Ahoj,\n\n\xEFakujem")).unwrap();
        assert_eq!(latin2, "Ahoj,\n\n\u{FFFD}akujem");
        assert!(decode_body("not*base64!").is_none());
    }

    #[test]
    fn mime_message_shape() {
        let mime = build_mime(
            &["a@x.com".to_string()],
            &["c@x.com".to_string()],
            &[],
            "Héllo",
            "body text",
            None,
            &[],
        );
        assert!(mime.starts_with("To: a@x.com\r\n"));
        assert!(mime.contains("Cc: c@x.com\r\n"));
        assert!(!mime.contains("Bcc:"));
        assert!(mime.contains("Subject: =?UTF-8?B?SMOpbGxv?=\r\n"));
        assert!(mime.contains("Content-Type: text/plain; charset=UTF-8\r\n"));
        // body is the last base64 chunk
        let b64 = mime.rsplit("\r\n\r\n").next().unwrap().trim();
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .unwrap();
        assert_eq!(String::from_utf8(decoded).unwrap(), "body text");
    }

    #[test]
    fn mime_multipart_alternative_with_html() {
        let mime = build_mime(
            &["a@x.com".to_string()],
            &[],
            &[],
            "Hi",
            "plain body",
            Some("<b>rich</b> body"),
            &[],
        );
        assert!(mime.contains("Content-Type: multipart/alternative; boundary="));
        assert!(mime.contains("Content-Type: text/plain; charset=UTF-8\r\n"));
        assert!(mime.contains("Content-Type: text/html; charset=UTF-8\r\n"));
        // both parts decode back
        let dec = |needle: &str| {
            let start = mime.find(needle).unwrap();
            let b64 = mime[start..]
                .split("\r\n\r\n")
                .nth(1)
                .unwrap()
                .split("\r\n")
                .next()
                .unwrap();
            String::from_utf8(
                base64::engine::general_purpose::STANDARD
                    .decode(b64)
                    .unwrap(),
            )
            .unwrap()
        };
        assert_eq!(dec("text/plain"), "plain body");
        assert_eq!(dec("text/html"), "<b>rich</b> body");
        assert!(mime.trim_end().ends_with("--"));
    }

    #[test]
    fn mime_multipart_mixed_with_attachment() {
        let att = OutAttachment {
            filename: "re\"port.pdf".to_string(),
            mime_type: "application/pdf".to_string(),
            data_b64: base64::engine::general_purpose::STANDARD.encode("PDFBYTES"),
        };
        let mime = build_mime(
            &["a@x.com".to_string()],
            &[],
            &[],
            "Hi",
            "plain body",
            Some("<b>rich</b>"),
            std::slice::from_ref(&att),
        );
        // mixed wraps alternative; attachment part carries sanitized name.
        assert!(mime.contains("Content-Type: multipart/mixed; boundary="));
        assert!(mime.contains("Content-Type: multipart/alternative; boundary="));
        assert!(mime.contains("Content-Disposition: attachment; filename=\"report.pdf\""));
        assert!(mime.contains(&att.data_b64));
        assert!(mime.trim_end().ends_with("--"));

        // No html, no attachments → still a bare text/plain message.
        let plain = build_mime(&["a@x.com".to_string()], &[], &[], "Hi", "b", None, &[]);
        assert!(plain.contains("Content-Type: text/plain"));
        assert!(!plain.contains("multipart"));
    }

    #[test]
    fn star_and_modify_label_wire_bodies() {
        let star = |on: bool| Mutation::Star {
            thread_id: "t1".to_string(),
            starred: on,
        };
        let starred = star(true);
        let (tid, body) = modify_body(&starred).unwrap();
        assert_eq!(tid, "t1");
        assert_eq!(body, serde_json::json!({ "addLabelIds": ["STARRED"] }));
        assert_eq!(
            modify_body(&star(false)).unwrap().1,
            serde_json::json!({ "removeLabelIds": ["STARRED"] })
        );
        let flip = |add: bool| Mutation::ModifyLabel {
            thread_id: "t1".to_string(),
            label_id: "Label_7".to_string(),
            add,
        };
        assert_eq!(
            modify_body(&flip(true)).unwrap().1,
            serde_json::json!({ "addLabelIds": ["Label_7"] })
        );
        assert_eq!(
            modify_body(&flip(false)).unwrap().1,
            serde_json::json!({ "removeLabelIds": ["Label_7"] })
        );
        // Trash/Send use dedicated endpoints, never threads.modify
        assert!(modify_body(&Mutation::Trash {
            thread_id: "t1".to_string()
        })
        .is_none());
    }

    #[test]
    fn ascii_subject_not_encoded() {
        let mime = build_mime(
            &["a@x.com".to_string()],
            &[],
            &[],
            "Plain subject",
            "b",
            None,
            &[],
        );
        assert!(mime.contains("Subject: Plain subject\r\n"));
    }

    #[test]
    fn entities_are_decoded() {
        assert_eq!(
            decode_entities("Su&#39;s card &lt;a&gt; &amp; more"),
            "Su's card <a> & more"
        );
        assert_eq!(decode_entities("caf&#xE9; &nbsp;ok"), "café \u{a0}ok");
        assert_eq!(
            decode_entities("5 & 6 &unknown; &#zz;"),
            "5 & 6 &unknown; &#zz;"
        );
        assert_eq!(decode_entities("no entities"), "no entities");
        // multibyte char inside the 10-byte lookahead window must not panic
        assert_eq!(
            decode_entities("výhodná & príležitosť"),
            "výhodná & príležitosť"
        );
        assert_eq!(decode_entities("&abýcdéf;x"), "&abýcdéf;x");
    }

    #[test]
    fn wire_history_list_maps_fields() {
        let json = serde_json::json!({
            "history": [
                {"id": "1001", "messagesAdded": [{"message": {"id": "m1", "threadId": "t1"}}]},
                {"id": "1002", "labelsRemoved": [
                    {"message": {"id": "m1", "threadId": "t1"}, "labelIds": ["INBOX"]}
                ]}
            ],
            "nextPageToken": "tok",
            "historyId": "1010"
        });
        let list: WireHistoryList = serde_json::from_value(json).unwrap();
        assert_eq!(list.history.len(), 2);
        assert_eq!(list.history[0].id.as_deref(), Some("1001"));
        assert_eq!(list.history[0].messages_added[0].message.thread_id, "t1");
        assert_eq!(list.history[1].labels_removed[0].label_ids, vec!["INBOX"]);
        assert_eq!(list.next_page_token.as_deref(), Some("tok"));
        // checkpoint = newest record id, NOT the (possibly ahead) top-level id
        assert_eq!(history_checkpoint(&list, "999"), "1002");
    }

    #[test]
    fn wire_watch_maps_fields() {
        let json = serde_json::json!({ "historyId": "24680", "expiration": "1761234567890" });
        let wire: WireWatch = serde_json::from_value(json).unwrap();
        let state = wire.into_state().unwrap();
        assert_eq!(state.history_id, "24680");
        assert_eq!(state.expiration_ms, 1_761_234_567_890);
    }

    #[test]
    fn wire_watch_rejects_bad_expiration() {
        let json = serde_json::json!({ "historyId": "1", "expiration": "soon" });
        let wire: WireWatch = serde_json::from_value(json).unwrap();
        assert!(matches!(wire.into_state(), Err(MailError::Provider(_))));
    }

    #[test]
    fn history_checkpoint_empty_feed_uses_top_level_id() {
        let empty: WireHistoryList =
            serde_json::from_value(serde_json::json!({ "historyId": "1010" })).unwrap();
        assert_eq!(history_checkpoint(&empty, "999"), "1010");
        let none: WireHistoryList = serde_json::from_value(serde_json::json!({})).unwrap();
        assert_eq!(history_checkpoint(&none, "999"), "999");
    }

    /// A thread the user replied to keeps naming the other party in the
    /// list, and the avatar address follows suit.
    #[test]
    fn wire_thread_names_other_party_after_own_reply() {
        let wire_msg = |id: &str, from: &str, to: &str, date: &str, labels: &[&str]| {
            serde_json::json!({
                "id": id,
                "labelIds": labels,
                "snippet": "",
                "internalDate": date,
                "payload": {
                    "mimeType": "text/plain",
                    "headers": [
                        {"name": "From", "value": from},
                        {"name": "To", "value": to},
                        {"name": "Subject", "value": "Q3 plan"}
                    ],
                    "body": {"data": "SGk="}
                }
            })
        };
        let json = serde_json::json!({
            "id": "t1",
            "messages": [
                wire_msg("m1", "Priya Nair <p@acme.co>", "me@example.com", "1", &["INBOX"]),
                wire_msg("m2", "Me <me@example.com>", "Priya Nair <p@acme.co>", "2", &["SENT"]),
            ]
        });
        let wire: WireThread = serde_json::from_value(json).unwrap();
        let (thread, _) = to_thread(&"me@example.com".to_string(), &wire);
        assert_eq!(thread.from_summary, "Priya Nair");
        assert_eq!(thread.last_from_addr, "p@acme.co");
        assert_eq!(
            thread.last_msg_at, 2,
            "timestamp still follows the newest message"
        );
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
        assert_eq!(thread.labels, vec!["INBOX", "UNREAD"]);
        assert!(!thread.is_archived, "inbox mail is not archived");
        assert!(
            !thread.has_attachment,
            "plain text/html parts carry no filename"
        );
    }

    #[test]
    fn wire_thread_detects_nested_attachment() {
        let json = serde_json::json!({
            "id": "t1",
            "messages": [{
                "id": "m1",
                "labelIds": ["INBOX"],
                "snippet": "see attached",
                "internalDate": "1756600000000",
                "payload": {
                    "mimeType": "multipart/mixed",
                    "headers": [],
                    "parts": [
                        {
                            "mimeType": "multipart/alternative",
                            "headers": [],
                            "parts": [
                                {"mimeType": "text/plain", "headers": [], "body": {"data": "aGk"}}
                            ]
                        },
                        {
                            "mimeType": "application/pdf",
                            "filename": "report.pdf",
                            "headers": [],
                            "body": {"attachmentId": "a1"}
                        }
                    ]
                }
            }]
        });
        let wire: WireThread = serde_json::from_value(json).unwrap();
        let (thread, _) = to_thread(&"acc".to_string(), &wire);
        assert!(
            thread.has_attachment,
            "attachment part nested under multipart/mixed"
        );
    }

    #[test]
    fn wire_thread_lists_attachments_with_inline_fallback_ids() {
        let json = serde_json::json!({
            "id": "t1",
            "messages": [{
                "id": "m1",
                "labelIds": ["INBOX"],
                "internalDate": "1756600000000",
                "payload": {
                    "mimeType": "multipart/mixed",
                    "headers": [],
                    "parts": [
                        {"mimeType": "text/plain", "headers": [], "body": {"data": "aGk"}},
                        {"mimeType": "application/pdf", "filename": "report.pdf", "headers": [],
                         "body": {"attachmentId": "a1", "size": 4096}},
                        {"mimeType": "", "filename": "tiny.txt", "headers": [],
                         "body": {"data": "aGk", "size": 2}}
                    ]
                }
            }, {
                "id": "m2",
                "labelIds": ["INBOX"],
                "internalDate": "1756600001000",
                "payload": {
                    "mimeType": "image/png",
                    "filename": "photo.png",
                    "headers": [],
                    "body": {"attachmentId": "a2", "size": 100}
                }
            }]
        });
        let wire: WireThread = serde_json::from_value(json).unwrap();
        let list = thread_attachments(&wire);
        assert_eq!(list.len(), 3);
        assert_eq!(
            (
                list[0].message_id.as_str(),
                list[0].attachment_id.as_str(),
                list[0].filename.as_str(),
                list[0].mime_type.as_str(),
                list[0].size
            ),
            ("m1", "a1", "report.pdf", "application/pdf", 4096)
        );
        // An embedded part has no id: it is the second attachment part of m1.
        assert_eq!(list[1].attachment_id, "inline:1");
        assert_eq!(list[1].mime_type, "application/octet-stream");
        assert_eq!(
            (list[2].message_id.as_str(), list[2].filename.as_str()),
            ("m2", "photo.png")
        );
    }

    #[test]
    fn wire_thread_derives_folder_state() {
        let msg = |id: &str, labels: &[&str]| {
            serde_json::json!({
                "id": id,
                "labelIds": labels,
                "snippet": "s",
                "internalDate": "1756600000000",
                "payload": { "mimeType": "text/plain", "headers": [
                    {"name": "From", "value": "me@example.com"},
                    {"name": "Subject", "value": "S"}
                ]}
            })
        };
        // sent-only: belongs to Sent, NOT Archive
        let wire: WireThread = serde_json::from_value(
            serde_json::json!({ "id": "t1", "messages": [msg("m1", &["SENT"])] }),
        )
        .unwrap();
        let (t, _) = to_thread(&"acc".to_string(), &wire);
        assert_eq!(t.labels, vec!["SENT"]);
        assert!(!t.is_inbox && !t.is_archived);

        // received + archived elsewhere: no INBOX, has a non-SENT message
        let wire: WireThread = serde_json::from_value(serde_json::json!({
            "id": "t2", "messages": [msg("m1", &["SENT"]), msg("m2", &["IMPORTANT"])]
        }))
        .unwrap();
        let (t, _) = to_thread(&"acc".to_string(), &wire);
        assert!(t.is_archived, "archived reply-thread shows in Archive");
        assert_eq!(t.labels, vec!["SENT", "IMPORTANT"]);

        // trashed: Trash folder, never Archive
        let wire: WireThread = serde_json::from_value(
            serde_json::json!({ "id": "t3", "messages": [msg("m1", &["TRASH"])] }),
        )
        .unwrap();
        let (t, _) = to_thread(&"acc".to_string(), &wire);
        assert!(!t.is_inbox && !t.is_archived);
    }

    #[test]
    fn label_patch_body_renames_only() {
        let body = label_patch_body("Recéipts");
        assert_eq!(body, serde_json::json!({ "name": "Recéipts" }));
        // PATCH must not touch visibility/color — only `name` is sent.
        assert_eq!(body.as_object().unwrap().len(), 1);
    }

    #[test]
    fn wire_label_parses_patch_response() {
        // labels.patch echoes the updated label; the same WireLabel shape
        // (used by labels.list) must parse it.
        let json = serde_json::json!({
            "id": "Label_7", "name": "Renamed", "type": "user",
            "messageListVisibility": "show", "labelListVisibility": "labelShow"
        });
        let l: WireLabel = serde_json::from_value(json).unwrap();
        assert_eq!(l.id, "Label_7");
        assert_eq!(l.name, "Renamed");
        assert_eq!(l.label_type, "user");
    }

    #[test]
    fn wire_labels_filter_user_type() {
        let json = serde_json::json!({ "labels": [
            {"id": "INBOX", "name": "INBOX", "type": "system"},
            {"id": "CATEGORY_SOCIAL", "name": "CATEGORY_SOCIAL", "type": "system"},
            {"id": "Label_7", "name": "Receipts", "type": "user"}
        ]});
        let list: WireLabelsList = serde_json::from_value(json).unwrap();
        let user: Vec<_> = list
            .labels
            .into_iter()
            .filter(|l| l.label_type == "user")
            .collect();
        assert_eq!(user.len(), 1);
        assert_eq!(user[0].id, "Label_7");
        assert_eq!(user[0].name, "Receipts");
    }
}
