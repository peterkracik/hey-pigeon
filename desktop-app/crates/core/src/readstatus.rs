//! Read status: what became of a message the user sent
//! (docs/specs/read-status.md).
//!
//! This is the local half (R1–R4): **Sent**, **Not delivered** and
//! **Replied** are read from the stored thread alone — the headers the
//! list tier already keeps, no body, no network, no setting. Opens (the
//! relay's half) join here later as stored events; the precedence is this
//! module's either way: a reply, then a bounce, then what the relay said,
//! then plain Sent.

use crate::domain::Message;
use crate::sync::bare_addr;

/// The status of one sent message. Ordered by precedence, lowest first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ReadState {
    /// Gmail accepted the message.
    Sent,
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
    /// message); None for `Sent`, whose time is the message's own.
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
    if !is_sent(sent) {
        return None;
    }
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
    } else {
        (ReadState::Sent, None)
    };
    Some(ReadStatus { state, at })
}

/// `status` for every message of a thread, in the thread's order.
pub fn statuses(thread: &[Message]) -> Vec<Option<ReadStatus>> {
    thread.iter().map(|m| status(m, thread)).collect()
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
