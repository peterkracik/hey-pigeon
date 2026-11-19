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

/// The pixel, as it goes into a message (R17).
fn pixel_tag(pixel_url: &str) -> String {
    format!(r#"<img src="{pixel_url}" width="1" height="1" alt="">"#)
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
                Ok(url)
                    if sanitize::own_pixel_token_of_url(&url).as_deref() == Some(token)
                        && url.starts_with("https://") =>
                {
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

/// The user turned read status off **on this device** (R12): the relay is
/// to delete the mailbox's tokens. Recorded, so it survives being offline;
/// `flush_delete` sends it. A device that only learns "off" through sync
/// never calls this (R13).
pub fn request_delete<S: Store>(store: &S, account_id: &AccountId) -> Result<(), StoreError> {
    store.sync_meta_set(account_id, META_DELETE_PENDING, "1")
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
    let pending = store
        .sync_meta_get(account_id, META_DELETE_PENDING)?
        .is_some_and(|v| !v.is_empty());
    if !pending {
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
