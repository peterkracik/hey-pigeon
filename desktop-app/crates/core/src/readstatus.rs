//! Read status: what became of a message the user sent
//! (docs/specs/read-status.md).
//!
//! The local half (R1–R4): **Sent**, **Not delivered** and **Replied** are
//! read from the stored thread alone — the headers the list tier already
//! keeps, no body, no network, no setting.
//!
//! The relay's half (R11–R23), for an account whose read status is on:
//! **Opened** and **Hidden** come from what the relay recorded of the
//! message's pixel. This module decides whether a message leaves tracked
//! (`prepare_send`), keeps its token, asks the relay about the tokens it
//! holds (`poll`), finds the tokens of mail sent from the user's other
//! devices (`catch_up_threads`, `remember_tokens`), and has the relay
//! forget a mailbox when the user turns the setting off (`request_delete`,
//! `flush_delete`). For an account with the setting off none of it makes a
//! request — except the one delete that turning it off asks for.
//!
//! The precedence is this module's: a reply, then a bounce, then an open,
//! then "delivered to a device that hides opens", then plain Sent.
//!
//! Nothing here logs a token, an address or a pixel URL.

use std::collections::HashMap;

use crate::domain::{
    AccountId, Message, MessageId, Mutation, OpenEvent, OpenLabel, OpenToken, ThreadId,
};
use crate::ports::{MailError, MailProvider, Store, StoreError};
use crate::sanitize;
use crate::sync::bare_addr;

/// The status of one sent message. Ordered by precedence, lowest first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ReadState {
    /// Gmail accepted the message.
    Sent,
    /// Its pixel was fetched by Apple's mail privacy proxy: delivered to a
    /// device that hides opens. Never shown or counted as opened.
    Hidden,
    /// Its pixel was fetched by a mail client or Gmail's image proxy.
    Opened,
    /// A bounce followed it in its thread.
    NotDelivered,
    /// Someone answered in its thread. That implies it was read and
    /// overrides everything else.
    Replied,
}

/// A sent message's status and when it came about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReadStatus {
    pub state: ReadState,
    /// Epoch ms of the reply or the bounce (the first one after the
    /// message), or of the newest open / hidden fetch; None for `Sent`,
    /// whose time is the message's own.
    pub at: Option<i64>,
}

fn has_label(m: &Message, label: &str) -> bool {
    m.label_ids.iter().any(|l| l == label)
}

/// A message the user sent: Gmail filed it under SENT (mail from a
/// send-as alias included) and it is not a draft still waiting.
pub fn is_sent(m: &Message) -> bool {
    has_label(m, "SENT") && !has_label(m, "DRAFT")
}

/// A delivery failure notice (R3): mail that is not the user's, from
/// `mailer-daemon@…` or `postmaster@…` in any letter case. Told from the
/// From header alone, which every tier stores.
pub fn is_bounce(m: &Message) -> bool {
    if has_label(m, "SENT") || has_label(m, "DRAFT") {
        return false;
    }
    let addr = bare_addr(&m.from_addr);
    let local = addr.split('@').next().unwrap_or_default();
    local.eq_ignore_ascii_case("mailer-daemon") || local.eq_ignore_ascii_case("postmaster")
}

/// A reply (R4): someone else's mail in the thread that is not a bounce.
fn is_reply(m: &Message) -> bool {
    !has_label(m, "SENT") && !has_label(m, "DRAFT") && !is_bounce(m)
}

/// The status of `sent` among the messages of its thread; None when
/// `sent` is not a message the user sent. Only messages newer than it
/// count: mail it was itself an answer to says nothing about it.
pub fn status(sent: &Message, thread: &[Message]) -> Option<ReadStatus> {
    status_with(sent, thread, &[])
}

/// `status`, with what the relay reported of the message's pixel.
pub fn status_with(sent: &Message, thread: &[Message], events: &[OpenEvent]) -> Option<ReadStatus> {
    if !is_sent(sent) {
        return None;
    }
    let newest = |label: OpenLabel| {
        events
            .iter()
            .filter(|e| e.label == label)
            .map(|e| e.at)
            .max()
    };
    let after = || {
        thread
            .iter()
            .filter(|m| m.id != sent.id && m.date > sent.date)
    };
    let first = |pred: fn(&Message) -> bool| after().filter(|m| pred(m)).map(|m| m.date).min();
    let (state, at) = if let Some(at) = first(is_reply) {
        (ReadState::Replied, Some(at))
    } else if let Some(at) = first(is_bounce) {
        (ReadState::NotDelivered, Some(at))
    } else if let Some(at) = newest(OpenLabel::Opened) {
        (ReadState::Opened, Some(at))
    } else if let Some(at) = newest(OpenLabel::Hidden) {
        (ReadState::Hidden, Some(at))
    } else {
        (ReadState::Sent, None)
    };
    Some(ReadStatus { state, at })
}

/// `status` for every message of a thread, in the thread's order.
pub fn statuses(thread: &[Message]) -> Vec<Option<ReadStatus>> {
    statuses_with(thread, &HashMap::new())
}

/// `statuses`, with the stored events of the thread's tracked messages
/// (`Store::open_events_for_thread`).
pub fn statuses_with(
    thread: &[Message],
    events: &HashMap<MessageId, Vec<OpenEvent>>,
) -> Vec<Option<ReadStatus>> {
    thread
        .iter()
        .map(|m| status_with(m, thread, events.get(&m.id).map_or(&[], Vec::as_slice)))
        .collect()
}

// ---------------------------------------------------------------- sending

/// The relay forgets a token this long after it was registered (R22).
pub const TOKEN_TTL_MS: i64 = 30 * 24 * 3_600_000;

/// A fresh token: 128 random bits as 32 hex digits. None when the system
/// has no randomness to give — the message then goes untracked.
pub fn new_token() -> Option<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).ok()?;
    Some(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// Give a queued send its token, once (R16): made when the message is
/// queued and kept in the outbox row, so a retry carries the same one. A
/// send the user did not ask to track, or anything else, is left alone.
pub fn with_token(mut mutation: Mutation) -> Mutation {
    if let Mutation::Send {
        track_opens,
        open_token,
        ..
    } = &mut mutation
    {
        if !*track_opens {
            *open_token = None;
        } else if open_token.is_none() {
            *open_token = new_token();
            // No token, no tracking: say so on the row itself.
            *track_opens = open_token.is_some();
        }
    }
    mutation
}

/// Where a relay's `opens` function may live, as this app accepts it:
/// `https://host` or `https://host:port`, the host made of letters,
/// digits, dots and hyphens — and nothing else. No path, no query, no
/// user, no other scheme. Lowercase, no trailing slash. None for
/// anything else.
///
/// The relay names this address itself, and it ends up inside the HTML of
/// mail the user sends: whatever is not exactly an origin could be markup
/// (`https://x" onerror="…`) or point somewhere this build never agreed
/// to. So it is parsed here, once, by every place that takes it in.
pub fn opens_origin(url: &str) -> Option<String> {
    let url = url.trim();
    let scheme = url.get(..8)?;
    if !scheme.eq_ignore_ascii_case("https://") {
        return None;
    }
    let rest = &url[8..];
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    let (host, port) = match rest.rsplit_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (rest, None),
    };
    let host_ok = !host.is_empty()
        && host.len() <= 253
        && host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
        && !host.starts_with(['.', '-'])
        && !host.ends_with(['.', '-'])
        && !host.contains("..");
    let port_ok =
        port.is_none_or(|p| !p.is_empty() && p.len() <= 5 && p.bytes().all(|b| b.is_ascii_digit()));
    if !host_ok || !port_ok {
        return None;
    }
    let host = host.to_ascii_lowercase();
    Some(match port {
        Some(port) => format!("https://{host}:{port}"),
        None => format!("https://{host}"),
    })
}

/// Whether `url` is exactly `token`'s pixel on an acceptable origin:
/// `<origin>/o/<token>.gif`, nothing before, nothing after.
pub fn is_pixel_url_for(url: &str, token: &str) -> bool {
    let token_ok = token.len() == sanitize::OWN_PIXEL_TOKEN_DIGITS
        && token
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase());
    let Some(origin) = url.strip_suffix(&format!(
        "{}{token}{}",
        sanitize::OWN_PIXEL_PATH_PREFIX,
        sanitize::OWN_PIXEL_SUFFIX
    )) else {
        return false;
    };
    token_ok && opens_origin(origin).as_deref() == Some(origin)
}

/// The pixel, as it goes into a message (R17). The address is checked
/// before it gets here (`is_pixel_url_for`) and escaped all the same: an
/// attribute value is never written as it was received.
fn pixel_tag(pixel_url: &str) -> String {
    let mut src = String::with_capacity(pixel_url.len());
    for c in pixel_url.chars() {
        match c {
            '&' => src.push_str("&amp;"),
            '"' => src.push_str("&quot;"),
            '<' => src.push_str("&lt;"),
            '>' => src.push_str("&gt;"),
            c => src.push(c),
        }
    }
    format!(r#"<img src="{src}" width="1" height="1" alt="">"#)
}

/// A plain-text body as an HTML part: the text escaped, its line breaks
/// kept. A tracked message without an HTML part gets one, so the pixel
/// has somewhere to be (R17); the plain part itself goes out unchanged.
pub fn text_as_html(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 32);
    out.push_str("<div>");
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '\r' => {}
            '\n' => out.push_str("<br>\n"),
            c => out.push(c),
        }
    }
    out.push_str("</div>");
    out
}

/// The HTML part of a tracked message: its own (or one made from the
/// text), without any pixel it may have picked up, and with this one as
/// the last thing in it — inside the `<body>` when there is one.
pub fn html_with_pixel(body_text: &str, body_html: Option<&str>, pixel_url: &str) -> String {
    let html = match body_html {
        Some(html) => sanitize::without_own_pixels(html).into_owned(),
        None => text_as_html(body_text),
    };
    let tag = pixel_tag(pixel_url);
    match html.to_ascii_lowercase().rfind("</body") {
        Some(at) => format!("{}{tag}{}", &html[..at], &html[at..]),
        None => html + &tag,
    }
}

/// What `prepare_send` decided for one outbox row.
#[derive(Debug, Default)]
pub struct Prepared {
    /// The mutation to hand to the provider in place of the queued one;
    /// None when the queued one goes out as it is.
    pub outgoing: Option<Mutation>,
    /// The token the message carries, when it goes out tracked.
    pub tracked: Option<String>,
}

/// The flush rule (R16): how a queued mutation leaves the outbox.
///
/// A send goes out **tracked** only when, now, all of these hold: the user
/// sent it with "Read status" on (and it has its token), the account's
/// read status is on, and the relay registered the token and answered
/// with a pixel URL that is this token's. Then, and only then, the pixel
/// is added. In every other case — the setting turned off since (here or
/// on another device), no relay, the relay down, at its limit (429) or
/// without a pixel host (503), an answer that is not this token's pixel —
/// the message goes out on time, **untracked**, and nothing is kept.
/// Mail is never held back for the relay.
///
/// The relay is asked only for an account with read status on (R11).
/// Either way the HTML leaves without any pixel of the app's shape it did
/// not just get: a quoted one is never sent on.
pub async fn prepare_send<M: MailProvider, S: Store>(
    provider: &M,
    store: &S,
    account_id: &AccountId,
    mutation: &Mutation,
) -> Prepared {
    let Mutation::Send {
        body_text,
        body_html,
        track_opens,
        open_token,
        ..
    } = mutation
    else {
        return Prepared::default();
    };
    let mut pixel: Option<(String, String)> = None;
    if let (true, Some(token)) = (*track_opens, open_token.as_deref()) {
        if account_tracks(store, account_id) {
            match provider.register_open_token(account_id, token).await {
                Ok(url) if is_pixel_url_for(&url, token) => {
                    pixel = Some((token.to_string(), url));
                }
                Ok(_) => log::warn!(
                    "read status: the relay's answer was not this message's pixel; sent untracked"
                ),
                Err(e) => log::info!("read status: not registered, sent untracked ({})", kind(&e)),
            }
        }
    }
    let html = match (&pixel, body_html.as_deref()) {
        (Some((_, url)), html) => Some(html_with_pixel(body_text, html, url)),
        (None, Some(html)) => match sanitize::without_own_pixels(html) {
            std::borrow::Cow::Owned(cleaned) => Some(cleaned),
            std::borrow::Cow::Borrowed(_) => None,
        },
        (None, None) => None,
    };
    let Some(html) = html else {
        return Prepared::default();
    };
    let mut outgoing = mutation.clone();
    if let Mutation::Send { body_html, .. } = &mut outgoing {
        *body_html = Some(html);
    }
    Prepared {
        outgoing: Some(outgoing),
        tracked: pixel.map(|(token, _)| token),
    }
}

/// An error's kind, for a log line: never its text, which may quote a URL.
fn kind(e: &MailError) -> &'static str {
    match e {
        MailError::AuthExpired => "auth",
        MailError::RateLimited { .. } => "rate limited",
        MailError::HistoryExpired => "history",
        MailError::Network(_) => "network",
        MailError::Provider(_) => "refused",
    }
}

/// Whether the account's read status is on. Any doubt is "off".
fn account_tracks<S: Store>(store: &S, account_id: &AccountId) -> bool {
    store
        .list_accounts()
        .ok()
        .and_then(|all| all.into_iter().find(|a| &a.id == account_id))
        .is_some_and(|a| a.read_status)
}

/// Keep the token of a message that just went out tracked. The sent
/// message's own id is not known yet: it is filled in when the message is
/// seen with its pixel (`remember_tokens`).
pub fn remember_sent<S: Store>(
    store: &S,
    account_id: &AccountId,
    token: &str,
    thread_id: Option<&ThreadId>,
    now: i64,
) -> Result<(), StoreError> {
    store.open_token_put(&OpenToken {
        token: token.to_string(),
        account_id: account_id.clone(),
        message_id: None,
        thread_id: thread_id.cloned(),
        sent_at: now,
        expires_at: now + TOKEN_TTL_MS,
        polled_at: None,
    })
}

/// Keep the tokens a full fetch read from the user's own sent messages
/// (R19): how a device learns the token of a message sent from another
/// one, and how the sending device learns which message its token became.
/// Returns how many messages carried one.
pub fn remember_tokens<S: Store>(store: &S, messages: &[Message]) -> Result<usize, StoreError> {
    let mut kept = 0;
    for m in messages {
        let Some(token) = m.open_token.as_deref() else {
            continue;
        };
        if !is_sent(m) {
            continue;
        }
        store.open_token_put(&OpenToken {
            token: token.to_string(),
            account_id: m.account_id.clone(),
            message_id: Some(m.id.clone()),
            thread_id: Some(m.thread_id.clone()),
            sent_at: m.date,
            expires_at: m.date + TOKEN_TTL_MS,
            polled_at: None,
        })?;
        kept += 1;
    }
    Ok(kept)
}

// ---------------------------------------------------------------- polling

/// Tokens one query may name (the relay's limit).
pub const POLL_BATCH: usize = 100;

/// How long to leave a token alone after asking about it, by its age: a
/// message is opened in its first hours or, mostly, not for days. Asking
/// about every token on every sync round (the Mac's is every 30 seconds)
/// would be a hundred document reads at the relay each time, for nothing.
pub fn poll_interval_ms(age_ms: i64) -> i64 {
    const MINUTE: i64 = 60_000;
    const HOUR: i64 = 60 * MINUTE;
    match age_ms {
        a if a < HOUR => 0,
        a if a < 24 * HOUR => 5 * MINUTE,
        a if a < 7 * 24 * HOUR => 30 * MINUTE,
        _ => 3 * HOUR,
    }
}

fn poll_due(token: &OpenToken, now: i64) -> bool {
    match token.polled_at {
        None => true,
        // A stamp from the future (the clock was set back) is no stamp.
        Some(at) if at > now => true,
        Some(at) => now - at >= poll_interval_ms(now - token.sent_at),
    }
}

/// Ask the relay about the account's tokens that are due and keep what it
/// says (R23). Nothing is asked for an account with read status off, for
/// a token past its 30 days, or when no token is due. Returns how many
/// events were new. A failure changes nothing; the next round asks again.
pub async fn poll<M: MailProvider, S: Store>(
    provider: &M,
    store: &S,
    account_id: &AccountId,
    now: i64,
) -> Result<usize, StoreError> {
    if !account_tracks(store, account_id) {
        return Ok(0);
    }
    let mut due: Vec<OpenToken> = store
        .open_tokens_live(account_id, now)?
        .into_iter()
        .filter(|t| poll_due(t, now))
        .collect();
    // Longest unasked first, so more than a batch still gets its turn.
    due.sort_by_key(|t| t.polled_at.unwrap_or(i64::MIN));
    due.truncate(POLL_BATCH);
    if due.is_empty() {
        return Ok(0);
    }
    let tokens: Vec<String> = due.into_iter().map(|t| t.token).collect();
    let answer = match provider.query_opens(account_id, &tokens).await {
        Ok(answer) => answer,
        Err(e) => {
            log::info!("read status: the relay was not asked ({})", kind(&e));
            return Ok(0);
        }
    };
    let mut added = 0;
    for token in &tokens {
        let events = answer.get(token).map_or(&[][..], Vec::as_slice);
        added += store.open_events_add(token, events, now)?;
    }
    Ok(added)
}

/// How many threads one sync round may fetch to look for tokens (R19).
pub const CATCH_UP_BATCH: u32 = 3;

/// Threads to fetch in full this round: the user's own sent mail of the
/// last 30 days whose body this device has not read, a few at a time, and
/// only for an account with read status on.
pub fn catch_up_threads<S: Store>(
    store: &S,
    account_id: &AccountId,
    now: i64,
) -> Result<Vec<ThreadId>, StoreError> {
    if !account_tracks(store, account_id) {
        return Ok(Vec::new());
    }
    store.sent_threads_without_bodies(account_id, now - TOKEN_TTL_MS, CATCH_UP_BATCH)
}

// ------------------------------------------------------------- off switch

/// sync_meta: the relay still has to be told to forget this mailbox.
pub const META_DELETE_PENDING: &str = "opens.delete_pending";

/// The relay is to delete the mailbox's tokens: the user turned read
/// status off **on this device** (R12), or this device learned "off" and
/// had itself registered tokens after that decision (R13,
/// `delete_if_sent_after`). Recorded, so it survives being offline;
/// `flush_delete` sends it. `opens_url` is where the relay's `opens`
/// function was when the request was made ("" when not known): kept with
/// the request, so the delete can still be sent if the app forgets the
/// address meanwhile (`pending_delete_url`).
pub fn request_delete<S: Store>(
    store: &S,
    account_id: &AccountId,
    opens_url: &str,
) -> Result<(), StoreError> {
    let hint = opens_origin(opens_url).unwrap_or_else(|| "1".to_string());
    store.sync_meta_set(account_id, META_DELETE_PENDING, &hint)
}

/// The address a pending delete was recorded with, when it had one.
pub fn pending_delete_url<S: Store>(
    store: &S,
    account_id: &AccountId,
) -> Result<Option<String>, StoreError> {
    Ok(store
        .sync_meta_get(account_id, META_DELETE_PENDING)?
        .and_then(|v| opens_origin(&v)))
}

/// Whether a delete is waiting to be sent for the account.
pub fn delete_pending<S: Store>(store: &S, account_id: &AccountId) -> Result<bool, StoreError> {
    Ok(store
        .sync_meta_get(account_id, META_DELETE_PENDING)?
        .is_some_and(|v| !v.is_empty()))
}

/// This device just learned through sync that read status was turned off
/// on another one at `decided_at` (R13). Ordinarily it sends nothing: the
/// device that flipped the switch deletes. But a device that had not
/// heard yet may have sent a tracked message after the decision — a token
/// the other device's delete came too early for, which the relay would
/// go on counting for 30 days. If this device holds such a token, it asks
/// for the delete too (asking twice is harmless). Returns whether it did.
pub fn delete_if_sent_after<S: Store>(
    store: &S,
    account_id: &AccountId,
    decided_at: i64,
    now: i64,
) -> Result<bool, StoreError> {
    let late = store
        .open_tokens_live(account_id, now)?
        .iter()
        .any(|t| t.sent_at > decided_at);
    if late {
        request_delete(store, account_id, "")?;
    }
    Ok(late)
}

/// The account is leaving this device: one attempt to have the relay
/// forget the mailbox, when there is anything it could hold — read status
/// is on, or a delete is pending. No retry: the caller is about to forget
/// the account. Returns whether the relay was asked and answered.
pub async fn forget_mailbox<M: MailProvider, S: Store>(
    provider: &M,
    store: &S,
    account_id: &AccountId,
) -> bool {
    let pending = delete_pending(store, account_id).unwrap_or(false);
    if !pending && !account_tracks(store, account_id) {
        return false;
    }
    match provider.delete_open_tokens(account_id).await {
        Ok(()) => {
            let _ = cancel_delete(store, account_id);
            true
        }
        Err(e) => {
            log::info!(
                "read status: the relay could not be told to forget a mailbox ({})",
                kind(&e)
            );
            false
        }
    }
}

/// The user turned it back on before the delete went out: there is
/// nothing to forget any more.
pub fn cancel_delete<S: Store>(store: &S, account_id: &AccountId) -> Result<(), StoreError> {
    store.sync_meta_set(account_id, META_DELETE_PENDING, "")
}

/// Send a pending delete (R12). The one request an account with read
/// status off makes — and only while one is pending. Kept pending until
/// the relay has answered; asking twice is harmless there. An account
/// turned on again in the meantime (on another device) cancels it.
/// Returns whether the relay was asked and answered.
pub async fn flush_delete<M: MailProvider, S: Store>(
    provider: &M,
    store: &S,
    account_id: &AccountId,
) -> Result<bool, StoreError> {
    if !delete_pending(store, account_id)? {
        return Ok(false);
    }
    if account_tracks(store, account_id) {
        cancel_delete(store, account_id)?;
        return Ok(false);
    }
    match provider.delete_open_tokens(account_id).await {
        Ok(()) => {
            cancel_delete(store, account_id)?;
            Ok(true)
        }
        Err(e) => {
            log::info!("read status: delete not sent yet ({})", kind(&e));
            Ok(false)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(id: &str, from: &str, date: i64, labels: &[&str]) -> Message {
        Message {
            id: id.into(),
            thread_id: "t".into(),
            from_addr: from.into(),
            date,
            label_ids: labels.iter().map(|l| l.to_string()).collect(),
            ..Default::default()
        }
    }

    fn sent(id: &str, date: i64) -> Message {
        msg(id, "Me <me@example.com>", date, &["SENT"])
    }

    fn state_of(thread: &[Message], id: &str) -> Option<ReadStatus> {
        let m = thread.iter().find(|m| m.id == id).unwrap();
        status(m, thread)
    }

    /// R2: the local statuses come from the stored headers alone — this
    /// module takes messages and nothing else: no store, no provider, no
    /// setting to ask.
    #[test]
    fn local_statuses_need_no_relay_and_no_setting() {
        let thread = [sent("s", 10)];
        assert_eq!(
            statuses(&thread),
            vec![Some(ReadStatus {
                state: ReadState::Sent,
                at: None
            })]
        );
    }

    #[test]
    fn only_sent_mail_has_a_status() {
        let thread = [
            msg("in", "Ana <ana@acme.test>", 5, &["INBOX"]),
            sent("s", 10),
            msg("d", "me@example.com", 20, &["DRAFT"]),
            // Gmail files a draft being sent under both for a moment.
            msg("sd", "me@example.com", 30, &["SENT", "DRAFT"]),
        ];
        assert_eq!(state_of(&thread, "in"), None);
        assert_eq!(state_of(&thread, "d"), None);
        assert_eq!(state_of(&thread, "sd"), None);
        // The user's own draft after it is not a reply.
        assert_eq!(state_of(&thread, "s").unwrap().state, ReadState::Sent);
    }

    /// R4.
    #[test]
    fn reply_after_send_is_replied() {
        let thread = [
            msg("before", "Ana <ana@acme.test>", 5, &["INBOX"]),
            sent("s", 10),
            msg("r1", "Ana <ana@acme.test>", 30, &["INBOX"]),
            msg("r2", "Ben <ben@acme.test>", 20, &[]),
        ];
        assert_eq!(
            state_of(&thread, "s"),
            Some(ReadStatus {
                state: ReadState::Replied,
                at: Some(20)
            })
        );
        // Mail older than the message is what it answered, not a reply
        // to it; and the user's own follow-up is not one either.
        let thread = [
            msg("before", "Ana <ana@acme.test>", 5, &["INBOX"]),
            sent("s", 10),
            sent("s2", 15),
        ];
        assert_eq!(state_of(&thread, "s").unwrap().state, ReadState::Sent);
    }

    /// R3: a bounce is its own state and never passes for an answer.
    #[test]
    fn bounce_is_not_a_reply() {
        for from in [
            "Mail Delivery Subsystem <mailer-daemon@googlemail.com>",
            "MAILER-DAEMON@example.org",
            "Postmaster <postmaster@outlook.com>",
        ] {
            let thread = [sent("s", 10), msg("b", from, 12, &["INBOX"])];
            assert_eq!(
                state_of(&thread, "s"),
                Some(ReadStatus {
                    state: ReadState::NotDelivered,
                    at: Some(12)
                }),
                "{from}"
            );
        }
        // Not a bounce: the name alone, a longer local part, a bounce
        // that came before the message.
        let thread = [
            msg("old", "mailer-daemon@googlemail.com", 5, &["INBOX"]),
            sent("s", 10),
        ];
        assert_eq!(state_of(&thread, "s").unwrap().state, ReadState::Sent);
        assert!(!is_bounce(&msg(
            "x",
            "Mailer-Daemon <ana@acme.test>",
            1,
            &[]
        )));
        assert!(!is_bounce(&msg("x", "postmaster-team@acme.test", 1, &[])));
        // The user writing from a postmaster address is the user.
        assert!(!is_bounce(&msg(
            "x",
            "postmaster@example.com",
            1,
            &["SENT"]
        )));
    }

    /// R1: a reply outranks a bounce, a bounce outranks Sent — whatever
    /// order they arrived in.
    #[test]
    fn status_precedence_reply_beats_bounce_beats_sent() {
        assert!(ReadState::Replied > ReadState::NotDelivered);
        assert!(ReadState::NotDelivered > ReadState::Sent);
        let bounce = msg("b", "mailer-daemon@googlemail.com", 12, &["INBOX"]);
        let reply = msg("r", "Ana <ana@acme.test>", 40, &["INBOX"]);
        for thread in [
            [sent("s", 10), bounce.clone(), reply.clone()],
            [sent("s", 10), reply.clone(), bounce.clone()],
        ] {
            assert_eq!(
                state_of(&thread, "s"),
                Some(ReadStatus {
                    state: ReadState::Replied,
                    at: Some(40)
                })
            );
        }
    }

    // ------------------------------------------------ the relay's half

    use crate::devsync;
    use crate::fakes::{
        sample_account, FakeProvider, MemStore, MemTransport, OpensCall, FAKE_PIXEL_HOST,
    };
    use crate::outbox;
    use std::sync::Arc;

    const ACC: &str = "a1";
    const NOW: i64 = 1_800_000_000_000;
    const HOUR: i64 = 3_600_000;

    fn acc() -> AccountId {
        ACC.to_string()
    }

    /// A store with one account, read status on or off, and a relay.
    fn fixture(read_status: bool) -> (FakeProvider, MemStore) {
        let store = MemStore::with_device_id("dev-a");
        let mut account = sample_account(ACC);
        account.read_status = read_status;
        store.upsert_account(&account).unwrap();
        (FakeProvider::with_sample_data(ACC, 0, 10), store)
    }

    fn send(track: bool, html: Option<&str>) -> Mutation {
        Mutation::Send {
            to: vec!["ana@acme.test".into()],
            cc: vec![],
            bcc: vec![],
            subject: "Thursday".into(),
            body_text: "See you <Thursday> & bring it.\nP.".into(),
            body_html: html.map(Into::into),
            attachments: vec![],
            reply_to_thread: None,
            from_addr: None,
            in_reply_to: None,
            references: None,
            track_opens: track,
            open_token: None,
        }
    }

    /// The token the outbox row carries.
    fn queued_token(store: &MemStore) -> Option<String> {
        match &store.outbox_list(10).unwrap()[0].mutation {
            Mutation::Send { open_token, .. } => open_token.clone(),
            _ => None,
        }
    }

    /// The HTML part of the one message the provider was given.
    fn sent_html(provider: &FakeProvider) -> Option<String> {
        let applied = provider.applied_mutations();
        assert_eq!(applied.len(), 1, "one message sent");
        match &applied[0].1 {
            Mutation::Send { body_html, .. } => body_html.clone(),
            other => panic!("not a send: {other:?}"),
        }
    }

    fn calls(provider: &FakeProvider) -> Vec<OpensCall> {
        provider.opens_calls.lock().unwrap().clone()
    }

    /// R1 in full: a reply, then a bounce, then an open, then "hidden",
    /// then plain Sent — whatever else is there.
    #[test]
    fn status_precedence_reply_beats_bounce_beats_open_beats_hidden() {
        assert!(ReadState::Replied > ReadState::NotDelivered);
        assert!(ReadState::NotDelivered > ReadState::Opened);
        assert!(ReadState::Opened > ReadState::Hidden);
        assert!(ReadState::Hidden > ReadState::Sent);
        let opened = |at| OpenEvent {
            label: OpenLabel::Opened,
            at,
        };
        let hidden = |at| OpenEvent {
            label: OpenLabel::Hidden,
            at,
        };
        let alone = [sent("s", 10)];
        let state = |thread: &[Message], events: &[OpenEvent]| {
            status_with(&thread[0], thread, events).unwrap()
        };
        assert_eq!(state(&alone, &[]).state, ReadState::Sent);
        // Hidden is its own state and never passes for opened.
        assert_eq!(
            state(&alone, &[hidden(20), hidden(30)]),
            ReadStatus {
                state: ReadState::Hidden,
                at: Some(30)
            }
        );
        // An open outranks it, whichever came last; its time is the newest open.
        for events in [
            vec![hidden(20), opened(40), opened(25)],
            vec![opened(25), opened(40), hidden(90)],
        ] {
            assert_eq!(
                state(&alone, &events),
                ReadStatus {
                    state: ReadState::Opened,
                    at: Some(40)
                }
            );
        }
        // Not delivered outranks opened (one recipient bounced, another read).
        let bounced = [
            sent("s", 10),
            msg("b", "mailer-daemon@googlemail.com", 12, &["INBOX"]),
        ];
        assert_eq!(
            state(&bounced, &[opened(40)]).state,
            ReadState::NotDelivered
        );
        // A reply outranks everything.
        let replied = [
            sent("s", 10),
            msg("b", "mailer-daemon@googlemail.com", 12, &["INBOX"]),
            msg("r", "Ana <ana@acme.test>", 50, &["INBOX"]),
        ];
        assert_eq!(
            state(&replied, &[opened(40), hidden(20)]),
            ReadStatus {
                state: ReadState::Replied,
                at: Some(50)
            }
        );
        // Events say nothing of a message that is not the user's sent mail.
        let theirs = msg("in", "Ana <ana@acme.test>", 5, &["INBOX"]);
        assert_eq!(status_with(&theirs, &[theirs.clone()], &[opened(9)]), None);
        // By message, over a thread.
        let thread = [sent("s1", 10), sent("s2", 20)];
        let events = HashMap::from([("s2".to_string(), vec![opened(30)])]);
        let all = statuses_with(&thread, &events);
        assert_eq!(all[0].unwrap().state, ReadState::Sent);
        assert_eq!(all[1].unwrap().state, ReadState::Opened);
    }

    /// R16: the token is made when the message is queued, once, and only
    /// for a message the user sent with read status on.
    #[test]
    fn a_tracked_send_gets_its_token_when_it_is_queued() {
        let (_, store) = fixture(true);
        outbox::enqueue(&store, &acc(), send(true, None)).unwrap();
        let token = queued_token(&store).expect("a token on the row");
        assert_eq!(token.len(), 32);
        assert!(token
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()));
        // Kept as it is when the row passes through again.
        let again = with_token(store.outbox_list(10).unwrap()[0].mutation.clone());
        assert!(matches!(again, Mutation::Send { open_token: Some(t), .. } if t == token));
        // Two messages, two tokens.
        assert_ne!(new_token(), new_token());

        let (_, store) = fixture(true);
        outbox::enqueue(&store, &acc(), send(false, None)).unwrap();
        assert_eq!(queued_token(&store), None);
        // A token on an untracked send is dropped, not sent along.
        let stray = with_token(Mutation::Send {
            to: vec![],
            cc: vec![],
            bcc: vec![],
            subject: String::new(),
            body_text: String::new(),
            body_html: None,
            attachments: vec![],
            reply_to_thread: None,
            from_addr: None,
            in_reply_to: None,
            references: None,
            track_opens: false,
            open_token: Some("0".repeat(32)),
        });
        assert!(matches!(
            stray,
            Mutation::Send {
                open_token: None,
                ..
            }
        ));
        // The token is not in what a log line would print.
        let row = format!("{:?}", store.outbox_list(10).unwrap());
        let (_, tracked) = fixture(true);
        outbox::enqueue(&tracked, &acc(), send(true, None)).unwrap();
        let token = queued_token(&tracked).unwrap();
        assert!(!format!("{:?}", tracked.outbox_list(10).unwrap()).contains(&token));
        assert!(!row.contains("open_token"));
    }

    /// R16, R17: the user's choice, the account's setting and the relay's
    /// answer all hold — the message goes out with its pixel, the relay
    /// was asked once, and the token is kept.
    #[tokio::test]
    async fn flush_tracks_only_when_choice_and_setting_and_relay() {
        let (provider, store) = fixture(true);
        outbox::enqueue(&store, &acc(), send(true, Some("<p>See you Thursday.</p>"))).unwrap();
        let token = queued_token(&store).unwrap();
        assert_eq!(outbox::drain(&provider, &store, 10).await.unwrap(), (1, 0));
        let pixel =
            format!(r#"<img src="{FAKE_PIXEL_HOST}/o/{token}.gif" width="1" height="1" alt="">"#);
        assert_eq!(
            sent_html(&provider).as_deref(),
            Some(format!("<p>See you Thursday.</p>{pixel}").as_str())
        );
        assert_eq!(
            calls(&provider),
            vec![OpensCall::Register(acc(), token.clone())]
        );
        let kept = store.open_tokens_live(&acc(), now_plus(0)).unwrap();
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].token, token);
        assert_eq!(kept[0].expires_at - kept[0].sent_at, TOKEN_TTL_MS);
        assert_eq!(kept[0].message_id, None);

        // The user's choice was off: nothing is asked, nothing is added.
        let (provider, store) = fixture(true);
        outbox::enqueue(&store, &acc(), send(false, Some("<p>Hi</p>"))).unwrap();
        outbox::drain(&provider, &store, 10).await.unwrap();
        assert_eq!(sent_html(&provider).as_deref(), Some("<p>Hi</p>"));
        assert!(calls(&provider).is_empty());
        assert!(store.open_tokens_live(&acc(), 0).unwrap().is_empty());
    }

    fn now_plus(ms: i64) -> i64 {
        crate::domain::now_ms() + ms
    }

    /// R16: what counts is the setting when the message leaves, not when
    /// Send was pressed. Turned off in between — here, or on another
    /// device — it goes out untracked and the relay hears nothing.
    #[tokio::test]
    async fn setting_off_before_flush_sends_untracked() {
        let (provider, store) = fixture(true);
        outbox::enqueue(&store, &acc(), send(true, Some("<p>Hi</p>"))).unwrap();
        assert!(queued_token(&store).is_some());
        let mut account = sample_account(ACC);
        account.read_status = false;
        store.upsert_account(&account).unwrap();
        assert_eq!(outbox::drain(&provider, &store, 10).await.unwrap(), (1, 0));
        assert_eq!(sent_html(&provider).as_deref(), Some("<p>Hi</p>"));
        assert!(calls(&provider).is_empty());
        assert!(store.open_tokens_live(&acc(), 0).unwrap().is_empty());
    }

    /// R16: whatever goes wrong with the relay — down, refusing, at its
    /// limit, without a pixel host, or answering with something that is
    /// not this message's pixel — the mail goes out on time, without one.
    #[tokio::test]
    async fn failed_registration_sends_without_pixel() {
        let failures: [fn() -> MailError; 4] = [
            || MailError::Network("relay unreachable".into()),
            || MailError::Provider("503 read status is not set up on this relay".into()),
            || MailError::RateLimited {
                retry_after_secs: None,
            },
            || MailError::AuthExpired,
        ];
        for fail in failures {
            let (provider, store) = fixture(true);
            *provider.opens_failure.lock().unwrap() = Some(fail);
            outbox::enqueue(&store, &acc(), send(true, Some("<p>Hi</p>"))).unwrap();
            assert_eq!(outbox::drain(&provider, &store, 10).await.unwrap(), (1, 0));
            assert_eq!(sent_html(&provider).as_deref(), Some("<p>Hi</p>"));
            assert!(store.open_tokens_live(&acc(), 0).unwrap().is_empty());
            assert!(
                store.outbox_list(10).unwrap().is_empty(),
                "sent, not parked"
            );
        }
        let token_of_another = "f".repeat(32);
        for wrong in [
            format!("https://o.example.test/o/{token_of_another}.gif"),
            "https://o.example.test/pixel.gif".to_string(),
            String::new(),
            "http://o.example.test/o/TOKEN.gif".to_string(),
        ] {
            let (provider, store) = fixture(true);
            outbox::enqueue(&store, &acc(), send(true, None)).unwrap();
            let wrong = wrong.replace("TOKEN", &queued_token(&store).unwrap());
            *provider.opens_pixel_override.lock().unwrap() = Some(wrong.clone());
            outbox::drain(&provider, &store, 10).await.unwrap();
            // A plain-text message stays plain text when it is not tracked.
            assert_eq!(sent_html(&provider), None, "{wrong}");
            assert!(store.open_tokens_live(&acc(), 0).unwrap().is_empty());
        }
    }

    /// R16: a send that has to be tried again carries the token it had.
    #[tokio::test]
    async fn retry_reuses_token() {
        let (provider, store) = fixture(true);
        outbox::enqueue(&store, &acc(), send(true, Some("<p>Hi</p>"))).unwrap();
        let token = queued_token(&store).unwrap();
        provider.fail_applies(true);
        assert_eq!(outbox::drain(&provider, &store, 10).await.unwrap(), (0, 1));
        // Not sent: nothing kept yet, and the row is as it was — no pixel in it.
        assert!(store.open_tokens_live(&acc(), 0).unwrap().is_empty());
        assert_eq!(queued_token(&store).as_deref(), Some(token.as_str()));
        let row = serde_json::to_string(&store.outbox_list(10).unwrap()[0].mutation).unwrap();
        assert!(!row.contains("/o/") && !row.contains(".gif"));
        provider.fail_applies(false);
        assert_eq!(outbox::drain(&provider, &store, 10).await.unwrap(), (1, 0));
        assert_eq!(
            calls(&provider),
            vec![
                OpensCall::Register(acc(), token.clone()),
                OpensCall::Register(acc(), token.clone())
            ]
        );
        let html = sent_html(&provider).unwrap();
        assert_eq!(html.matches("<img").count(), 1);
        assert_eq!(sanitize::own_pixel_token(&html), Some(token));
    }

    /// R17: the pixel is the last thing in the HTML part, inside the body
    /// when the part is a whole document, and a message is never given two.
    #[test]
    fn pixel_is_last_in_html() {
        let url = "https://o.example.test/o/0123456789abcdef0123456789abcdef.gif";
        let tag = format!(r#"<img src="{url}" width="1" height="1" alt="">"#);
        assert_eq!(
            html_with_pixel("x", Some("<p>Hi</p>"), url),
            format!("<p>Hi</p>{tag}")
        );
        assert_eq!(
            html_with_pixel("x", Some("<html><body><p>Hi</p></BODY></html>"), url),
            format!("<html><body><p>Hi</p>{tag}</BODY></html>")
        );
        // Whatever the part was assembled from — a quote of the user's own
        // tracked message, a pixel from an earlier try — one pixel leaves.
        let older = r#"<img src="https://o.example.test/o/ffffffffffffffffffffffffffffffff.gif" width="1" height="1" alt="">"#;
        let quoting = format!("<p>Again</p><blockquote>See you.{older}</blockquote>{tag}");
        let out = html_with_pixel("x", Some(&quoting), url);
        assert_eq!(
            out,
            format!("<p>Again</p><blockquote>See you.</blockquote>{tag}")
        );
        assert_eq!(out.matches("/o/").count(), 1);
    }

    /// R17: a tracked message with no HTML part gets one made from its
    /// text; the text part goes out as it was written.
    #[tokio::test]
    async fn plain_only_message_gets_html_part() {
        assert_eq!(
            text_as_html("a <b> & c\r\nnext\n\nlast"),
            "<div>a &lt;b&gt; &amp; c<br>\nnext<br>\n<br>\nlast</div>"
        );
        let (provider, store) = fixture(true);
        outbox::enqueue(&store, &acc(), send(true, None)).unwrap();
        let token = queued_token(&store).unwrap();
        outbox::drain(&provider, &store, 10).await.unwrap();
        let applied = provider.applied_mutations();
        let Mutation::Send {
            body_text,
            body_html,
            ..
        } = &applied[0].1
        else {
            panic!("not a send");
        };
        assert_eq!(body_text, "See you <Thursday> & bring it.\nP.");
        assert_eq!(
            body_html.as_deref().unwrap(),
            format!(
                "<div>See you &lt;Thursday&gt; &amp; bring it.<br>\nP.</div><img src=\"{FAKE_PIXEL_HOST}/o/{token}.gif\" width=\"1\" height=\"1\" alt=\"\">"
            )
        );
    }

    /// A draft saved to Gmail never contains a pixel, and saving one asks
    /// the relay nothing: only a sent message is tracked.
    #[tokio::test]
    async fn draft_never_carries_pixel() {
        let (provider, store) = fixture(true);
        let draft = Mutation::SaveDraft {
            key: "k1".into(),
            to: vec!["ana@acme.test".into()],
            cc: vec![],
            bcc: vec![],
            subject: "Thursday".into(),
            body_text: "See you".into(),
            body_html: Some("<p>See you</p>".into()),
            attachments: vec![],
            reply_to_thread: None,
            from_addr: None,
            in_reply_to: None,
            references: None,
        };
        outbox::enqueue(&store, &acc(), draft.clone()).unwrap();
        outbox::drain(&provider, &store, 10).await.unwrap();
        assert_eq!(provider.applied_mutations()[0].1, draft);
        assert!(calls(&provider).is_empty());
        assert!(store.open_tokens_live(&acc(), 0).unwrap().is_empty());
    }

    /// A reply or forward never sends on a pixel it quotes — the user's
    /// own from the message being answered — tracked or not; a tracked
    /// one leaves with exactly its own.
    #[tokio::test]
    async fn a_quoted_pixel_is_never_sent_on() {
        let quoted = "<p>Thanks</p><blockquote>See you.<img src=\"https://o.heypigeon.app/o/ffffffffffffffffffffffffffffffff.gif\" width=\"1\" height=\"1\" alt=\"\"></blockquote>";
        // Untracked (the setting is off): the quote's pixel is taken out
        // and the relay is not asked.
        let (provider, store) = fixture(false);
        outbox::enqueue(&store, &acc(), send(false, Some(quoted))).unwrap();
        outbox::drain(&provider, &store, 10).await.unwrap();
        assert_eq!(
            sent_html(&provider).as_deref(),
            Some("<p>Thanks</p><blockquote>See you.</blockquote>")
        );
        assert!(calls(&provider).is_empty());
        // Tracked: its own pixel, and only that one.
        let (provider, store) = fixture(true);
        outbox::enqueue(&store, &acc(), send(true, Some(quoted))).unwrap();
        let token = queued_token(&store).unwrap();
        outbox::drain(&provider, &store, 10).await.unwrap();
        let html = sent_html(&provider).unwrap();
        assert_eq!(html.matches("<img").count(), 1);
        assert!(!html.contains("ffffffff"));
        assert_eq!(sanitize::own_pixel_token(&html), Some(token));
    }

    /// The requirement behind R11, as one test: for an account with read
    /// status off, nothing contacts the relay — not a send the user asked
    /// to track, not a sync round's poll or catch-up, and not after the
    /// setting was turned off on another device and learned through sync.
    #[tokio::test]
    async fn setting_off_makes_no_opens_request() {
        // Off from the start.
        let (provider, store) = fixture(false);
        outbox::enqueue(&store, &acc(), send(true, Some("<p>Hi</p>"))).unwrap();
        outbox::drain(&provider, &store, 10).await.unwrap();
        assert_eq!(poll(&provider, &store, &acc(), NOW).await.unwrap(), 0);
        assert!(catch_up_threads(&store, &acc(), NOW).unwrap().is_empty());
        assert!(!flush_delete(&provider, &store, &acc()).await.unwrap());
        assert!(calls(&provider).is_empty(), "{:?}", calls(&provider));
        assert_eq!(sent_html(&provider).as_deref(), Some("<p>Hi</p>"));

        // On, with a tracked message out and a token to ask about …
        let remote = Arc::new(MemTransport::default());
        let (provider, a) = fixture(true);
        devsync::record_read_status(&a, &acc(), true).unwrap();
        devsync::sync_account(&*remote, &a, &acc()).await.unwrap();
        outbox::enqueue(&a, &acc(), send(true, Some("<p>One</p>"))).unwrap();
        outbox::drain(&provider, &a, 10).await.unwrap();
        assert_eq!(calls(&provider).len(), 1);
        provider.opens_calls.lock().unwrap().clear();

        // … then turned off on device B, which A learns through sync.
        let b = MemStore::with_device_id("dev-b");
        b.upsert_account(&sample_account(ACC)).unwrap();
        devsync::sync_account(&*remote, &b, &acc()).await.unwrap();
        assert!(b.list_accounts().unwrap()[0].read_status);
        let mut off = b.list_accounts().unwrap().remove(0);
        off.read_status = false;
        b.upsert_account(&off).unwrap();
        devsync::record_read_status(&b, &acc(), false).unwrap();
        devsync::sync_account(&*remote, &b, &acc()).await.unwrap();
        devsync::sync_account(&*remote, &a, &acc()).await.unwrap();
        assert!(!a.list_accounts().unwrap()[0].read_status);

        // A: a message queued before it learned, a sync round's worth of
        // read status, a later round — and not one request, the delete
        // included (R13: the device that flipped the switch owns it).
        outbox::enqueue(&a, &acc(), send(true, Some("<p>Two</p>"))).unwrap();
        outbox::drain(&provider, &a, 10).await.unwrap();
        for at in [now_plus(0), now_plus(2 * HOUR), now_plus(48 * HOUR)] {
            assert!(!flush_delete(&provider, &a, &acc()).await.unwrap());
            assert_eq!(poll(&provider, &a, &acc(), at).await.unwrap(), 0);
            assert!(catch_up_threads(&a, &acc(), at).unwrap().is_empty());
        }
        assert!(calls(&provider).is_empty(), "{:?}", calls(&provider));
        let applied = provider.applied_mutations();
        assert!(
            matches!(&applied[1].1, Mutation::Send { body_html: Some(h), .. } if h == "<p>Two</p>")
        );
        // What it had stored stays (R11); it only stops changing.
        assert_eq!(a.open_tokens_live(&acc(), now_plus(0)).unwrap().len(), 1);
    }

    /// R12: turning it off on this device asks the relay to forget the
    /// mailbox — once it can be reached, and once.
    #[tokio::test]
    async fn turning_off_deletes_once_and_retries_until_sent() {
        let (provider, store) = fixture(false);
        // Nothing pending: nothing asked.
        assert!(!flush_delete(&provider, &store, &acc()).await.unwrap());
        assert!(calls(&provider).is_empty());

        request_delete(&store, &acc(), "").unwrap();
        *provider.opens_failure.lock().unwrap() =
            Some(|| MailError::Network("relay unreachable".into()));
        assert!(!flush_delete(&provider, &store, &acc()).await.unwrap());
        assert!(!flush_delete(&provider, &store, &acc()).await.unwrap());
        *provider.opens_failure.lock().unwrap() = None;
        assert!(flush_delete(&provider, &store, &acc()).await.unwrap());
        assert!(!flush_delete(&provider, &store, &acc()).await.unwrap());
        assert_eq!(
            calls(&provider),
            vec![
                OpensCall::Delete(acc()),
                OpensCall::Delete(acc()),
                OpensCall::Delete(acc())
            ],
            "two that failed, one that went through, none after"
        );
        // While off, the delete is the only thing ever asked.
        assert_eq!(poll(&provider, &store, &acc(), NOW).await.unwrap(), 0);
        assert_eq!(calls(&provider).len(), 3);
    }

    /// S3: a device that had not heard of "off" yet and sent a tracked
    /// message after the decision asks for the delete too when it learns
    /// — the first device's delete came too early for that token. A
    /// device whose tokens are all older than the decision still sends
    /// nothing (that is `setting_off_makes_no_opens_request`).
    #[tokio::test]
    async fn a_token_sent_after_off_is_deleted_by_the_device_that_sent_it() {
        let remote = Arc::new(MemTransport::default());
        let (provider, a) = fixture(true);
        devsync::record_read_status(&a, &acc(), true).unwrap();
        devsync::sync_account(&*remote, &a, &acc()).await.unwrap();

        // B turns it off (and deletes at the relay, not shown here).
        let b = MemStore::with_device_id("dev-b");
        b.upsert_account(&sample_account(ACC)).unwrap();
        devsync::sync_account(&*remote, &b, &acc()).await.unwrap();
        let mut off = b.list_accounts().unwrap().remove(0);
        off.read_status = false;
        b.upsert_account(&off).unwrap();
        devsync::record_read_status(&b, &acc(), false).unwrap();
        devsync::sync_account(&*remote, &b, &acc()).await.unwrap();

        // A has not synced yet and sends a tracked message: a new token
        // at the relay, registered after B's delete.
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        outbox::enqueue(&a, &acc(), send(true, Some("<p>Late</p>"))).unwrap();
        outbox::drain(&provider, &a, 10).await.unwrap();
        assert_eq!(calls(&provider).len(), 1);
        assert!(!delete_pending(&a, &acc()).unwrap());

        // A learns "off": it holds a token younger than the decision.
        devsync::sync_account(&*remote, &a, &acc()).await.unwrap();
        assert!(!a.list_accounts().unwrap()[0].read_status);
        assert!(delete_pending(&a, &acc()).unwrap());
        assert!(flush_delete(&provider, &a, &acc()).await.unwrap());
        assert_eq!(calls(&provider).last(), Some(&OpensCall::Delete(acc())));
        // Once: nothing more is asked afterwards.
        let before = calls(&provider).len();
        assert!(!flush_delete(&provider, &a, &acc()).await.unwrap());
        assert_eq!(
            poll(&provider, &a, &acc(), now_plus(HOUR)).await.unwrap(),
            0
        );
        assert_eq!(calls(&provider).len(), before);

        // The rule on its own: only a token sent after the decision counts.
        let (_, store) = fixture(false);
        store
            .open_token_put(&token("old", NOW - HOUR, None))
            .unwrap();
        assert!(!delete_if_sent_after(&store, &acc(), NOW, NOW).unwrap());
        assert!(!delete_pending(&store, &acc()).unwrap());
        store.open_token_put(&token("late", NOW + 1, None)).unwrap();
        assert!(delete_if_sent_after(&store, &acc(), NOW, NOW + 2).unwrap());
        assert!(delete_pending(&store, &acc()).unwrap());
    }

    /// B1: an account leaving the device has the relay forget its mailbox
    /// in one attempt — when read status is on for it or a delete is still
    /// pending; an account that never used it asks nothing. A relay that
    /// cannot be reached, or an account that is signed out, is not
    /// retried here: the caller goes on to remove the account.
    #[tokio::test]
    async fn an_account_that_leaves_has_the_relay_forget_it() {
        // Read status on.
        let (provider, store) = fixture(true);
        assert!(forget_mailbox(&provider, &store, &acc()).await);
        assert_eq!(calls(&provider), vec![OpensCall::Delete(acc())]);
        // Off, with a delete that never went out.
        let (provider, store) = fixture(false);
        request_delete(&store, &acc(), "https://o.example.test").unwrap();
        assert_eq!(
            pending_delete_url(&store, &acc()).unwrap().as_deref(),
            Some("https://o.example.test")
        );
        assert!(forget_mailbox(&provider, &store, &acc()).await);
        assert!(!delete_pending(&store, &acc()).unwrap());
        assert_eq!(calls(&provider), vec![OpensCall::Delete(acc())]);
        // Never used: nothing asked.
        let (provider, store) = fixture(false);
        assert!(!forget_mailbox(&provider, &store, &acc()).await);
        assert!(calls(&provider).is_empty());
        // Signed out, or the relay down: one attempt, no retry, and the
        // request is still there for whoever can send it later.
        for fail in [(|| MailError::AuthExpired) as fn() -> MailError, || {
            MailError::Network("relay unreachable".into())
        }] {
            let (provider, store) = fixture(false);
            request_delete(&store, &acc(), "").unwrap();
            *provider.opens_failure.lock().unwrap() = Some(fail);
            assert!(!forget_mailbox(&provider, &store, &acc()).await);
            assert_eq!(calls(&provider).len(), 1);
            assert!(delete_pending(&store, &acc()).unwrap());
            // A signed-out account's pending delete stays pending across
            // sync rounds, and goes out once it can.
            assert!(!flush_delete(&provider, &store, &acc()).await.unwrap());
            *provider.opens_failure.lock().unwrap() = None;
            assert!(flush_delete(&provider, &store, &acc()).await.unwrap());
        }
        // A recorded address that is not an origin is not kept as one.
        let (_, store) = fixture(false);
        request_delete(&store, &acc(), r#"https://x" onerror="alert(1)"#).unwrap();
        assert!(delete_pending(&store, &acc()).unwrap());
        assert_eq!(pending_delete_url(&store, &acc()).unwrap(), None);
    }

    /// Two accounts in one round, one with read status on and one with it
    /// off: only the first one's tokens are ever named, and only it sends
    /// tracked mail.
    #[tokio::test]
    async fn two_accounts_one_on_one_off() {
        let (provider, store) = fixture(true);
        let other: AccountId = "a2".into();
        store.upsert_account(&sample_account("a2")).unwrap();
        // Both hold a token (the second from before it was turned off).
        store
            .open_token_put(&token("mine", NOW - 60_000, None))
            .unwrap();
        let mut theirs = token("theirs", NOW - 60_000, None);
        theirs.account_id = other.clone();
        store.open_token_put(&theirs).unwrap();
        for account in [acc(), other.clone()] {
            outbox::enqueue(&store, &account, send(true, Some("<p>Hi</p>"))).unwrap();
        }
        outbox::drain(&provider, &store, 10).await.unwrap();
        for account in [acc(), other.clone()] {
            flush_delete(&provider, &store, &account).await.unwrap();
            poll(&provider, &store, &account, NOW).await.unwrap();
            catch_up_threads(&store, &account, NOW).unwrap();
        }
        let all = calls(&provider);
        assert!(
            all.iter().all(|c| match c {
                OpensCall::Register(a, _) | OpensCall::Delete(a) => a == ACC,
                OpensCall::Query(a, tokens) => a == ACC && !tokens.contains(&"theirs".to_string()),
            }),
            "{all:?}"
        );
        assert!(all.iter().any(|c| matches!(c, OpensCall::Register(..))));
        assert!(all.iter().any(|c| matches!(c, OpensCall::Query(..))));
        let applied = provider.applied_mutations();
        let html_of = |account: &str| {
            applied
                .iter()
                .find(|(a, _)| a == account)
                .and_then(|(_, m)| match m {
                    Mutation::Send { body_html, .. } => body_html.clone(),
                    _ => None,
                })
                .unwrap()
        };
        assert!(html_of(ACC).contains("/o/"));
        assert_eq!(html_of("a2"), "<p>Hi</p>");
    }

    /// S5: the address the relay names goes into mail, so it is an https
    /// origin or nothing; a pixel URL is this token's on such an origin
    /// or it is refused; and the tag escapes what it is given regardless.
    #[tokio::test]
    async fn a_relay_cannot_put_markup_into_mail() {
        assert_eq!(
            opens_origin(" https://O.HeyPigeon.app/ ").as_deref(),
            Some("https://o.heypigeon.app")
        );
        assert_eq!(
            opens_origin("https://relay.example:8443").as_deref(),
            Some("https://relay.example:8443")
        );
        for bad in [
            "",
            "https://",
            "http://o.heypigeon.app",
            r#"https://x" onerror="alert(1)"#,
            r#"https://x"><script>alert(1)</script>"#,
            "https://o.heypigeon.app/path",
            "https://o.heypigeon.app?q",
            "https://user@o.heypigeon.app",
            "https://o.heypigeon.app:99999999",
            "https://o.heypigeon.app:",
            "https://o.hey pigeon.app",
            "https://-x.example",
            "https://x..example",
            "https://é.example",
        ] {
            assert_eq!(opens_origin(bad), None, "{bad}");
        }
        let token = "0123456789abcdef0123456789abcdef";
        assert!(is_pixel_url_for(
            &format!("https://o.heypigeon.app/o/{token}.gif"),
            token
        ));
        assert!(is_pixel_url_for(
            &format!("https://relay.example:8443/o/{token}.gif"),
            token
        ));
        for bad in [
            format!(r#"https://x" onerror="alert(1)/o/{token}.gif"#),
            format!(r#"https://x"><img src=x onerror=alert(1)>/o/{token}.gif"#),
            format!("https://o.heypigeon.app/a/o/{token}.gif"),
            format!(r#"https://o.heypigeon.app/o/{token}.gif?x="y"#),
            format!("http://o.heypigeon.app/o/{token}.gif"),
            format!("https://O.heypigeon.app/o/{token}.gif"),
            format!("https://o.heypigeon.app/o/{}.gif", token.to_uppercase()),
            format!("https://user@o.heypigeon.app/o/{token}.gif"),
        ] {
            assert!(!is_pixel_url_for(&bad, token), "{bad}");
        }
        assert!(!is_pixel_url_for(
            "https://o.heypigeon.app/o/short.gif",
            "short"
        ));
        // Whatever reaches the tag is escaped.
        assert_eq!(
            pixel_tag(r#"https://x" onerror="a<b>&c"#),
            r#"<img src="https://x&quot; onerror=&quot;a&lt;b&gt;&amp;c" width="1" height="1" alt="">"#
        );
        // End to end: a relay that answers with markup gets no pixel into
        // the message at all.
        let (provider, store) = fixture(true);
        outbox::enqueue(&store, &acc(), send(true, Some("<p>Hi</p>"))).unwrap();
        let queued = queued_token(&store).unwrap();
        *provider.opens_pixel_override.lock().unwrap() =
            Some(format!(r#"https://x" onerror="alert(1)/o/{queued}.gif"#));
        outbox::drain(&provider, &store, 10).await.unwrap();
        assert_eq!(sent_html(&provider).as_deref(), Some("<p>Hi</p>"));
        assert!(store.open_tokens_live(&acc(), 0).unwrap().is_empty());
    }

    /// S1: mail sent without a composer — an unsubscribe request, an
    /// invitation's answer, a saved draft sent by a Shortcut — arrives
    /// with the choice off. It is not tracked whatever the account's
    /// setting, asks the relay nothing, and a plain-text one stays plain
    /// text: no HTML part is made for it.
    #[tokio::test]
    async fn mail_sent_without_the_composers_choice_is_not_tracked() {
        let (provider, store) = fixture(true);
        outbox::enqueue(&store, &acc(), send(false, None)).unwrap();
        assert_eq!(queued_token(&store), None);
        outbox::drain(&provider, &store, 10).await.unwrap();
        let applied = provider.applied_mutations();
        let Mutation::Send {
            body_text,
            body_html,
            ..
        } = &applied[0].1
        else {
            panic!("not a send");
        };
        assert_eq!(body_html, &None);
        assert_eq!(body_text, "See you <Thursday> & bring it.\nP.");
        assert!(calls(&provider).is_empty());
        // And a queued row an older build wrote (no such fields) is the same.
        let old: Mutation = serde_json::from_str(
            r#"{"kind":"send","to":["sam@x.com"],"subject":"s","body_text":"b"}"#,
        )
        .unwrap();
        assert!(matches!(
            old,
            Mutation::Send {
                track_opens: false,
                open_token: None,
                ..
            }
        ));
    }

    /// Turned on again before the delete went out — here, or on another
    /// device: there is nothing to forget, and the new tokens stay.
    #[tokio::test]
    async fn turning_on_again_cancels_a_pending_delete() {
        let (provider, store) = fixture(false);
        request_delete(&store, &acc(), "").unwrap();
        cancel_delete(&store, &acc()).unwrap();
        assert!(!flush_delete(&provider, &store, &acc()).await.unwrap());

        request_delete(&store, &acc(), "").unwrap();
        let mut on = sample_account(ACC);
        on.read_status = true;
        store.upsert_account(&on).unwrap();
        assert!(!flush_delete(&provider, &store, &acc()).await.unwrap());
        // And it stays cancelled when the setting goes off through sync later.
        let mut off = on.clone();
        off.read_status = false;
        store.upsert_account(&off).unwrap();
        assert!(!flush_delete(&provider, &store, &acc()).await.unwrap());
        assert!(calls(&provider).is_empty());
    }

    fn token(t: &str, sent_at: i64, polled_at: Option<i64>) -> OpenToken {
        OpenToken {
            token: t.into(),
            account_id: acc(),
            message_id: Some(format!("m-{t}")),
            thread_id: Some("th".into()),
            sent_at,
            expires_at: sent_at + TOKEN_TTL_MS,
            polled_at,
        }
    }

    /// R23: the relay is asked about live, due tokens of an account with
    /// read status on, and what it says is kept once.
    #[tokio::test]
    async fn poll_skips_off_accounts_and_expired_tokens() {
        let (provider, store) = fixture(true);
        // Nothing to ask about: no request at all.
        assert_eq!(poll(&provider, &store, &acc(), NOW).await.unwrap(), 0);
        assert!(calls(&provider).is_empty());

        store
            .open_token_put(&token("fresh", NOW - 10 * 60_000, None))
            .unwrap();
        store
            .open_token_put(&token("gone", NOW - TOKEN_TTL_MS - 1, None))
            .unwrap();
        // Another account's token is never named in this account's query.
        let mut other = token("theirs", NOW - 60_000, None);
        other.account_id = "a2".into();
        store.open_token_put(&other).unwrap();
        let opened = OpenEvent {
            label: OpenLabel::Opened,
            at: NOW - 60_000,
        };
        let hidden = OpenEvent {
            label: OpenLabel::Hidden,
            at: NOW - 120_000,
        };
        provider
            .opens_events
            .lock()
            .unwrap()
            .insert("fresh".into(), vec![hidden, opened]);
        assert_eq!(poll(&provider, &store, &acc(), NOW).await.unwrap(), 2);
        assert_eq!(
            calls(&provider),
            vec![OpensCall::Query(acc(), vec!["fresh".into()])]
        );
        assert_eq!(
            store.open_events_for_thread(&"th".to_string()).unwrap()["m-fresh"],
            vec![hidden, opened]
        );
        // The same answer again: nothing new.
        assert_eq!(poll(&provider, &store, &acc(), NOW + 1).await.unwrap(), 0);
        assert_eq!(
            store.open_events_for_thread(&"th".to_string()).unwrap()["m-fresh"].len(),
            2
        );

        // A relay that fails changes nothing and is asked again next time.
        *provider.opens_failure.lock().unwrap() = Some(|| MailError::Network("down".into()));
        assert_eq!(poll(&provider, &store, &acc(), NOW + 2).await.unwrap(), 0);
        *provider.opens_failure.lock().unwrap() = None;
        let before = calls(&provider).len();
        poll(&provider, &store, &acc(), NOW + 3).await.unwrap();
        assert_eq!(calls(&provider).len(), before + 1);
    }

    /// A token is asked about often while it is new and seldom when old,
    /// and never more than a batch at a time.
    #[tokio::test]
    async fn poll_asks_by_age_and_in_batches() {
        const MIN: i64 = 60_000;
        assert_eq!(poll_interval_ms(0), 0);
        assert_eq!(poll_interval_ms(HOUR - 1), 0);
        assert_eq!(poll_interval_ms(HOUR), 5 * MIN);
        assert_eq!(poll_interval_ms(24 * HOUR), 30 * MIN);
        assert_eq!(poll_interval_ms(7 * 24 * HOUR), 3 * HOUR);
        assert!(poll_due(&token("t", NOW - 10 * MIN, None), NOW));
        assert!(poll_due(&token("t", NOW - 10 * MIN, Some(NOW - 1)), NOW));
        assert!(!poll_due(
            &token("t", NOW - 2 * HOUR, Some(NOW - 4 * MIN)),
            NOW
        ));
        assert!(poll_due(
            &token("t", NOW - 2 * HOUR, Some(NOW - 5 * MIN)),
            NOW
        ));
        assert!(!poll_due(
            &token("t", NOW - 20 * 24 * HOUR, Some(NOW - 2 * HOUR)),
            NOW
        ));
        assert!(poll_due(
            &token("t", NOW - 20 * 24 * HOUR, Some(NOW - 3 * HOUR)),
            NOW
        ));
        assert!(poll_due(&token("t", NOW - 2 * HOUR, Some(NOW + HOUR)), NOW));

        let (provider, store) = fixture(true);
        // A week-old message asked about a minute ago is left alone …
        store
            .open_token_put(&token("old", NOW - 8 * 24 * HOUR, Some(NOW - MIN)))
            .unwrap();
        assert_eq!(poll(&provider, &store, &acc(), NOW).await.unwrap(), 0);
        assert!(calls(&provider).is_empty());
        // … and more tokens than a query takes get their turn over rounds.
        for i in 0..(POLL_BATCH + 20) {
            store
                .open_token_put(&token(&format!("t{i:03}"), NOW - 10 * MIN, None))
                .unwrap();
        }
        poll(&provider, &store, &acc(), NOW).await.unwrap();
        let OpensCall::Query(_, first) = calls(&provider)[0].clone() else {
            panic!("not a query");
        };
        assert_eq!(first.len(), POLL_BATCH);
        // Next round: the ones not asked about yet go first.
        poll(&provider, &store, &acc(), NOW + MIN).await.unwrap();
        let OpensCall::Query(_, second) = calls(&provider)[1].clone() else {
            panic!("not a query");
        };
        assert_eq!(second.len(), POLL_BATCH);
        assert!(second[..20].iter().all(|t| !first.contains(t)));
        assert!(second[20..].iter().all(|t| first.contains(t)));
    }

    /// R19: the token of a message sent from another device is read from
    /// the message, kept beside it, and found again by its thread; the
    /// sending device's own token gains its message the same way.
    #[tokio::test]
    async fn tokens_are_kept_from_fetched_sent_mail() {
        let (_, store) = fixture(true);
        let mut from_other_device = sent("m1", NOW - HOUR);
        from_other_device.account_id = acc();
        from_other_device.open_token = Some("aa".repeat(16));
        let mut quoted_in_a_reply = msg("m2", "Ana <ana@acme.test>", NOW, &["INBOX"]);
        quoted_in_a_reply.open_token = Some("bb".repeat(16));
        let untracked = sent("m3", NOW);
        assert_eq!(
            remember_tokens(
                &store,
                &[from_other_device.clone(), quoted_in_a_reply, untracked]
            )
            .unwrap(),
            1
        );
        let kept = store.open_tokens_live(&acc(), NOW).unwrap();
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].message_id.as_deref(), Some("m1"));
        assert_eq!(kept[0].thread_id.as_deref(), Some("t"));
        assert_eq!(kept[0].expires_at, NOW - HOUR + TOKEN_TTL_MS);

        // The sending device: the token is kept at send time without a
        // message, and gains it when the sent message is fetched.
        let (_, store) = fixture(true);
        remember_sent(&store, &acc(), &"aa".repeat(16), None, NOW - HOUR - 5).unwrap();
        remember_tokens(&store, &[from_other_device]).unwrap();
        let kept = store.open_tokens_live(&acc(), NOW).unwrap();
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].message_id.as_deref(), Some("m1"));
        assert_eq!(kept[0].sent_at, NOW - HOUR - 5);
    }

    /// R19: the catch-up is a few threads a round, of the last 30 days,
    /// and only for an account with read status on.
    #[test]
    fn catch_up_is_bounded() {
        let (_, store) = fixture(true);
        for i in 0..10 {
            let mut m = sent(&format!("m{i}"), NOW - i * HOUR);
            m.account_id = acc();
            m.thread_id = format!("t{i}");
            store.upsert_message(&m).unwrap();
        }
        let mut old = sent("old", NOW - TOKEN_TTL_MS - HOUR);
        old.account_id = acc();
        old.thread_id = "t-old".into();
        store.upsert_message(&old).unwrap();
        let mut read = sent("read", NOW);
        read.account_id = acc();
        read.thread_id = "t-read".into();
        read.body_fetched = true;
        store.upsert_message(&read).unwrap();
        assert_eq!(
            catch_up_threads(&store, &acc(), NOW).unwrap(),
            ["t0", "t1", "t2"]
        );
        assert_eq!(CATCH_UP_BATCH, 3);

        let mut off = sample_account(ACC);
        off.read_status = false;
        store.upsert_account(&off).unwrap();
        assert!(catch_up_threads(&store, &acc(), NOW).unwrap().is_empty());
    }

    /// A provider with no relay (the default) tracks nothing and holds
    /// nothing back.
    #[tokio::test]
    async fn a_provider_without_read_status_sends_untracked() {
        struct NoRelay(FakeProvider);
        impl crate::ports::MailProvider for NoRelay {
            fn profile(
                &self,
                a: &AccountId,
            ) -> impl std::future::Future<Output = Result<crate::domain::Profile, MailError>> + Send
            {
                self.0.profile(a)
            }
            fn list_recent(
                &self,
                a: &AccountId,
                d: u32,
                p: Option<String>,
            ) -> impl std::future::Future<Output = Result<crate::ports::ThreadPage, MailError>> + Send
            {
                self.0.list_recent(a, d, p)
            }
            fn list_before(
                &self,
                a: &AccountId,
                b: i64,
                p: Option<String>,
            ) -> impl std::future::Future<Output = Result<crate::ports::ThreadPage, MailError>> + Send
            {
                self.0.list_before(a, b, p)
            }
            fn list_history(
                &self,
                a: &AccountId,
                s: &str,
                p: Option<String>,
            ) -> impl std::future::Future<Output = Result<crate::ports::HistoryPage, MailError>> + Send
            {
                self.0.list_history(a, s, p)
            }
            fn fetch_bodies(
                &self,
                a: &AccountId,
                t: &ThreadId,
            ) -> impl std::future::Future<Output = Result<(bool, Vec<Message>), MailError>> + Send
            {
                self.0.fetch_bodies(a, t)
            }
            fn apply(
                &self,
                a: &AccountId,
                m: &Mutation,
            ) -> impl std::future::Future<Output = Result<(), MailError>> + Send {
                self.0.apply(a, m)
            }
        }
        let (fake, store) = fixture(true);
        let provider = NoRelay(fake);
        outbox::enqueue(&store, &acc(), send(true, Some("<p>Hi</p>"))).unwrap();
        assert_eq!(outbox::drain(&provider, &store, 10).await.unwrap(), (1, 0));
        assert_eq!(sent_html(&provider.0).as_deref(), Some("<p>Hi</p>"));
        assert!(calls(&provider.0).is_empty());
    }

    /// Each sent message has its own status: a reply answers what came
    /// before it, not the message the user wrote afterwards.
    #[test]
    fn each_sent_message_is_judged_by_what_followed_it() {
        let thread = [
            sent("s1", 10),
            msg("r", "Ana <ana@acme.test>", 20, &["INBOX"]),
            sent("s2", 30),
        ];
        let all = statuses(&thread);
        assert_eq!(all[0].unwrap().state, ReadState::Replied);
        assert_eq!(all[1], None);
        assert_eq!(all[2].unwrap().state, ReadState::Sent);
    }
}
