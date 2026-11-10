//! The two rules the user sets on their own mail that Gmail's API gives
//! this app no way to set there: mute a conversation, block a sender.
//! (Gmail's mute is not in its API, and filters need a scope the app does
//! not ask for.) Both are app-wide preferences — lists that travel
//! between the user's devices like every other preference — applied here
//! after each sync round:
//!
//! - a **muted** thread that new mail brought back to the inbox is marked
//!   done and read, as it was when it was muted;
//! - an inbox thread that holds nobody's mail but a **blocked** sender's
//!   (and the user's own) goes to Spam. A conversation where a blocked
//!   person is one voice among others stays: a thread goes to Spam whole,
//!   and Gmail deletes what is there after thirty days — colleagues' mail
//!   with it.
//!
//! Each is an ordinary optimistic change through the outbox, so Gmail
//! (and the other devices, through it) end up in the same state.
//!
//! **Once per arrival.** A rule acts on a thread when mail from someone
//! else arrives in it, and then leaves it alone until more does: it
//! remembers (on this device, `Store::rule_mark`) the newest such mail it
//! acted on. So "Not spam" on a blocked sender's thread, or a muted
//! thread moved back to the inbox — here, on another device, or in
//! Gmail itself — stays as the user put it. The rules look at what the
//! store holds, not at what one round brought, so a round that was missed
//! changes nothing, and blocking a sender also moves the mail of theirs
//! that is already in the inbox (once).

use crate::domain::{AccountId, Message, Mutation, Thread, ThreadId};
use crate::outbox::{self, OutboxError};
use crate::ports::Store;
use crate::sync::{bare_addr, is_own_message};

/// The preference holding the muted threads: a JSON array of thread ids.
pub const MUTE_THREADS_PREF: &str = "mute.threads";
/// The preference holding the blocked senders: a JSON array of e-mail
/// addresses, lowercase.
pub const BLOCK_SENDERS_PREF: &str = "block.senders";

/// The names the rules keep their marks under (`Store::rule_mark`).
const MUTE: &str = "mute";
const BLOCK: &str = "block";

/// What one pass did.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Applied {
    /// Muted threads taken out of the inbox again.
    pub muted: Vec<ThreadId>,
    /// Threads moved to Spam for their sender.
    pub blocked: Vec<ThreadId>,
}

impl Applied {
    pub fn any(&self) -> bool {
        !self.muted.is_empty() || !self.blocked.is_empty()
    }
}

/// A preference that is a list of strings; anything else reads as empty.
fn string_list<S: Store>(store: &S, name: &str) -> Vec<String> {
    store
        .get_pref(name)
        .ok()
        .flatten()
        .and_then(|v| serde_json::from_value::<Vec<String>>(v).ok())
        .unwrap_or_default()
}

/// The thread's mail from other people: not the user's own, not a draft.
fn from_others<'a>(messages: &'a [Message], own_email: &str) -> Vec<&'a Message> {
    messages
        .iter()
        .filter(|m| !m.label_ids.iter().any(|l| l == "DRAFT") && !is_own_message(m, own_email))
        .collect()
}

/// When the newest of them arrived (epoch ms); 0 when there is none.
fn newest_arrival(others: &[&Message]) -> i64 {
    others.iter().map(|m| m.date).max().unwrap_or(0)
}

/// Apply both rules to one account's mail. With both lists empty this is
/// two preference reads and one no-op delete. The changes are queued
/// (`outbox::enqueue`); the caller drains.
pub fn apply<S: Store>(store: &S, account_id: &AccountId) -> Result<Applied, OutboxError> {
    let mut applied = Applied::default();
    let in_inbox = |t: &Thread| t.is_inbox && !t.is_archived;
    let muted = string_list(store, MUTE_THREADS_PREF);
    let blocked: Vec<String> = string_list(store, BLOCK_SENDERS_PREF)
        .into_iter()
        .map(|a| a.trim().to_lowercase())
        .filter(|a| !a.is_empty())
        .collect();
    // A thread that is no longer muted starts afresh if it is muted again.
    store.retain_rule_marks(MUTE, &muted)?;
    if muted.is_empty() && blocked.is_empty() {
        return Ok(applied);
    }
    let own_email = store
        .list_accounts()?
        .into_iter()
        .find(|a| &a.id == account_id)
        .map(|a| a.email)
        .unwrap_or_else(|| account_id.clone());

    for thread_id in muted {
        let Some(thread) = store.get_thread(&thread_id)? else {
            continue;
        };
        if &thread.account_id != account_id {
            continue;
        }
        let mark = store.rule_mark(MUTE, &thread_id)?;
        if !in_inbox(&thread) && mark.is_some() {
            continue;
        }
        let messages = store.list_message_meta(&thread_id)?;
        let arrival = newest_arrival(&from_others(&messages, &own_email));
        if !in_inbox(&thread) {
            // Muted and out of the inbox, as muting leaves it: this is the
            // mail the rule has nothing more to say about. If the thread
            // turns up in the inbox with nothing newer, the user put it
            // there.
            store.set_rule_mark(MUTE, &thread_id, arrival)?;
            continue;
        }
        if mark.is_some_and(|acted_on| arrival <= acted_on) {
            continue;
        }
        outbox::enqueue(
            store,
            account_id,
            Mutation::Archive {
                thread_id: thread_id.clone(),
            },
        )?;
        if !thread.is_read {
            outbox::enqueue(
                store,
                account_id,
                Mutation::MarkRead {
                    thread_id: thread_id.clone(),
                    read: true,
                },
            )?;
        }
        store.set_rule_mark(MUTE, &thread_id, arrival)?;
        applied.muted.push(thread_id);
    }

    if blocked.is_empty() {
        return Ok(applied);
    }
    // Candidates by the row (its newest sender who is not the user); the
    // rule itself is about every message.
    for thread in store.inbox_threads_from(account_id, &blocked)? {
        if !in_inbox(&thread) {
            continue;
        }
        let messages = store.list_message_meta(&thread.id)?;
        let others = from_others(&messages, &own_email);
        let all_blocked = !others.is_empty()
            && others
                .iter()
                .all(|m| blocked.contains(&bare_addr(&m.from_addr).to_lowercase()));
        if !all_blocked {
            continue;
        }
        let arrival = newest_arrival(&others);
        if store
            .rule_mark(BLOCK, &thread.id)?
            .is_some_and(|acted_on| arrival <= acted_on)
        {
            continue;
        }
        outbox::enqueue(
            store,
            account_id,
            Mutation::MarkSpam {
                thread_id: thread.id.clone(),
                spam: true,
            },
        )?;
        store.set_rule_mark(BLOCK, &thread.id, arrival)?;
        applied.blocked.push(thread.id);
    }
    Ok(applied)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::ThreadFilter;
    use crate::fakes::{sample_account, FakeProvider, MemStore};
    use serde_json::json;

    const A1: &str = "a1";

    async fn synced_store(threads: usize) -> (MemStore, FakeProvider) {
        let store = MemStore::default();
        store.upsert_account(&sample_account(A1)).unwrap();
        let provider = FakeProvider::with_sample_data(A1, threads, 10);
        crate::sync::backfill(&provider, &store, &A1.to_string(), 30)
            .await
            .unwrap();
        (store, provider)
    }

    fn inbox(store: &MemStore) -> Vec<String> {
        let mut ids: Vec<String> = store
            .list_threads(None, &ThreadFilter::Inbox, None, 100)
            .unwrap()
            .into_iter()
            .map(|t| t.id)
            .collect();
        ids.sort();
        ids
    }

    fn queued(store: &MemStore) -> Vec<String> {
        store
            .outbox_list(100)
            .unwrap()
            .iter()
            .map(|i| {
                format!(
                    "{}:{}",
                    i.mutation.kind_name(),
                    i.mutation.thread_id().cloned().unwrap_or_default()
                )
            })
            .collect()
    }

    /// Mail arrives in a thread: a message from `from` (or from the user,
    /// with `SENT`), newer than what is there, and the thread back in the
    /// inbox unread — what a delta round leaves behind.
    fn arrive(store: &MemStore, thread_id: &str, from: &str, own: bool) {
        let mut thread = store.get_thread(&thread_id.to_string()).unwrap().unwrap();
        let newest = store
            .list_messages(&thread.id)
            .unwrap()
            .last()
            .cloned()
            .unwrap();
        thread.msg_count += 1;
        thread.last_msg_at = newest.date + 1_000;
        if !own {
            thread.is_inbox = true;
            thread.is_archived = false;
            thread.is_read = false;
            thread.labels = vec!["INBOX".into(), "UNREAD".into()];
            thread.last_from_addr = bare_addr(from);
        }
        store.upsert_thread(&thread).unwrap();
        store
            .upsert_message(&Message {
                id: format!("{thread_id}:m{}", thread.msg_count),
                from_addr: from.to_string(),
                date: thread.last_msg_at,
                label_ids: vec![if own { "SENT" } else { "INBOX" }.to_string()],
                is_read: own,
                ..newest
            })
            .unwrap();
    }

    /// What the user (here, on another device, or in Gmail) does to put a
    /// thread back: it is in the inbox again, with no new mail.
    fn rescue(store: &MemStore, thread_id: &str) {
        let mut thread = store.get_thread(&thread_id.to_string()).unwrap().unwrap();
        thread.is_inbox = true;
        thread.is_archived = false;
        thread.labels = vec!["INBOX".into()];
        store.upsert_thread(&thread).unwrap();
    }

    fn mute(store: &MemStore, thread_id: &str) {
        outbox::enqueue(
            store,
            &A1.to_string(),
            Mutation::Archive {
                thread_id: thread_id.to_string(),
            },
        )
        .unwrap();
        for item in store.outbox_list(100).unwrap() {
            store.outbox_delete(item.id).unwrap();
        }
        store
            .set_pref(MUTE_THREADS_PREF, Some(&json!([thread_id])))
            .unwrap();
    }

    /// Nothing set: nothing read but the two preferences, nothing queued.
    #[tokio::test]
    async fn without_rules_nothing_happens() {
        let (store, _) = synced_store(3).await;
        let applied = apply(&store, &A1.to_string()).unwrap();
        assert!(!applied.any());
        assert_eq!(inbox(&store).len(), 3);
        assert!(queued(&store).is_empty());
        // A preference of the wrong shape is no rule either.
        store
            .set_pref(MUTE_THREADS_PREF, Some(&json!("a1:t0")))
            .unwrap();
        store.set_pref(BLOCK_SENDERS_PREF, Some(&json!(7))).unwrap();
        assert!(!apply(&store, &A1.to_string()).unwrap().any());
    }

    /// A muted thread that new mail brought back to the inbox is done and
    /// read again once the round is over; other mail is left alone, and a
    /// second pass has nothing to do.
    #[tokio::test]
    async fn a_muted_thread_leaves_the_inbox_again_when_mail_arrives() {
        let (store, provider) = synced_store(3).await;
        let a1 = A1.to_string();
        let muted = "a1:t0";
        mute(&store, muted);
        store
            .set_pref(MUTE_THREADS_PREF, Some(&json!([muted, "unknown-thread"])))
            .unwrap();
        assert!(!apply(&store, &a1).unwrap().any(), "it is not in the inbox");

        arrive(&store, muted, "sender0@example.com", false);
        assert!(inbox(&store).contains(&muted.to_string()));

        let applied = apply(&store, &a1).unwrap();
        assert_eq!(applied.muted, vec![muted.to_string()]);
        assert!(applied.blocked.is_empty());
        let after = store.get_thread(&muted.to_string()).unwrap().unwrap();
        assert!(after.is_archived && !after.is_inbox && after.is_read);
        assert_eq!(inbox(&store), vec!["a1:t1", "a1:t2"]);
        assert_eq!(
            queued(&store),
            vec![format!("archive:{muted}"), format!("read:{muted}")]
        );
        // Gmail hears of it through the outbox like any other change.
        outbox::drain(&provider, &store, 10).await.unwrap();
        assert!(queued(&store).is_empty());
        assert!(!apply(&store, &a1).unwrap().any());
    }

    /// The rule acts once per arrival. A muted thread the user moved back
    /// to the inbox stays there, round after round — whether it had been
    /// archived by muting or by the rule — until someone else writes
    /// again. The user's own reply is not an arrival.
    #[tokio::test]
    async fn a_muted_thread_the_user_moved_back_stays() {
        let (store, _) = synced_store(2).await;
        let a1 = A1.to_string();
        let muted = "a1:t0";
        mute(&store, muted);
        // A round passes with the thread muted and out of the inbox.
        assert!(!apply(&store, &a1).unwrap().any());

        rescue(&store, muted);
        for _ in 0..3 {
            assert!(!apply(&store, &a1).unwrap().any(), "rescued: left alone");
        }
        assert!(inbox(&store).contains(&muted.to_string()));
        arrive(&store, muted, "a1@example.com", true);
        assert!(!apply(&store, &a1).unwrap().any(), "the user's own reply");

        // New mail from someone else: the rule acts, once.
        arrive(&store, muted, "sender0@example.com", false);
        assert_eq!(apply(&store, &a1).unwrap().muted, vec![muted.to_string()]);
        rescue(&store, muted);
        assert!(!apply(&store, &a1).unwrap().any());
        assert!(inbox(&store).contains(&muted.to_string()));

        // Unmuted and muted again: a fresh start, not the old mark.
        store.set_pref(MUTE_THREADS_PREF, Some(&json!([]))).unwrap();
        assert!(!apply(&store, &a1).unwrap().any());
        assert_eq!(store.rule_mark(MUTE, &muted.to_string()).unwrap(), None);
        store
            .set_pref(MUTE_THREADS_PREF, Some(&json!([muted])))
            .unwrap();
        assert_eq!(
            apply(&store, &a1).unwrap().muted,
            vec![muted.to_string()],
            "muted while it sits in the inbox"
        );
    }

    /// A thread goes to Spam only when everyone else in it is blocked.
    #[tokio::test]
    async fn only_a_blocked_senders_own_threads_go_to_spam() {
        let (store, _) = synced_store(5).await;
        let a1 = A1.to_string();
        // Sample thread N is from senderN@example.com.
        store
            .set_pref(
                BLOCK_SENDERS_PREF,
                Some(&json!(["sender1@example.com", " Sender2@Example.com "])),
            )
            .unwrap();
        // Thread 2: the user answered last. Still nobody's but theirs.
        arrive(&store, "a1:t2", "a1@example.com", true);
        // Thread 3: a group thread where a blocked person replied last.
        arrive(&store, "a1:t3", "Blocked <sender1@example.com>", false);
        // Thread 4: a blocked address in the display name only.
        arrive(
            &store,
            "a1:t4",
            r#""sender1@example.com <sender1@example.com>" <friend@example.com>"#,
            false,
        );
        // Another account's rules pass does not touch this account's mail.
        assert!(!apply(&store, &"other".to_string()).unwrap().any());

        let mut applied = apply(&store, &a1).unwrap();
        applied.blocked.sort();
        assert_eq!(applied.blocked, vec!["a1:t1", "a1:t2"]);
        assert!(applied.muted.is_empty());
        let spam = store.get_thread(&"a1:t1".to_string()).unwrap().unwrap();
        assert!(!spam.is_inbox && spam.labels.contains(&"SPAM".to_string()));
        // The colleagues' thread and the look-alike stay where they are.
        assert_eq!(inbox(&store), vec!["a1:t0", "a1:t3", "a1:t4"]);
        let mut sent = queued(&store);
        sent.sort();
        assert_eq!(sent, vec!["spam:a1:t1", "spam:a1:t2"]);
        assert!(!apply(&store, &a1).unwrap().any());
    }

    /// "Not spam" is the user's answer to the rule for the mail it acted
    /// on: the thread stays in the inbox until that sender writes again.
    #[tokio::test]
    async fn not_spam_holds_until_the_blocked_sender_writes_again() {
        let (store, _) = synced_store(2).await;
        let a1 = A1.to_string();
        store
            .set_pref(BLOCK_SENDERS_PREF, Some(&json!(["sender1@example.com"])))
            .unwrap();
        assert_eq!(apply(&store, &a1).unwrap().blocked, vec!["a1:t1"]);

        outbox::enqueue(
            &store,
            &a1,
            Mutation::MarkSpam {
                thread_id: "a1:t1".into(),
                spam: false,
            },
        )
        .unwrap();
        for _ in 0..3 {
            assert!(!apply(&store, &a1).unwrap().any(), "rescued: left alone");
        }
        assert!(inbox(&store).contains(&"a1:t1".to_string()));

        arrive(&store, "a1:t1", "sender1@example.com", false);
        assert_eq!(apply(&store, &a1).unwrap().blocked, vec!["a1:t1"]);
        assert!(!inbox(&store).contains(&"a1:t1".to_string()));
    }
}
