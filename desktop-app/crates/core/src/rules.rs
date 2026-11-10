//! The two rules the user sets on their own mail that Gmail's API gives
//! this app no way to set there: mute a conversation, block a sender.
//! (Gmail's mute is not in its API, and filters need a scope the app does
//! not ask for.) Both are app-wide preferences — lists that travel
//! between the user's devices like every other preference — applied here
//! after each sync round:
//!
//! - a **muted** thread that is back in the inbox (someone wrote in it
//!   again) is marked done and read, as it was when it was muted;
//! - an inbox thread whose newest mail is from a **blocked** address goes
//!   to Spam.
//!
//! Each is an ordinary optimistic change through the outbox, so Gmail
//! (and the other devices, through it) end up in the same state. The
//! rules look at what the store holds, not at what the round brought:
//! blocking a sender also moves what is already in the inbox, and a round
//! that was missed changes nothing.

use crate::domain::{AccountId, Mutation, Thread, ThreadId};
use crate::outbox::{self, OutboxError};
use crate::ports::Store;
use crate::sync::{bare_addr, is_own_message};

/// The preference holding the muted threads: a JSON array of thread ids.
pub const MUTE_THREADS_PREF: &str = "mute.threads";
/// The preference holding the blocked senders: a JSON array of e-mail
/// addresses, lowercase.
pub const BLOCK_SENDERS_PREF: &str = "block.senders";

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

/// Apply both rules to one account's mail. With both lists empty this is
/// two preference reads. The changes are queued (`outbox::enqueue`); the
/// caller drains.
pub fn apply<S: Store>(store: &S, account_id: &AccountId) -> Result<Applied, OutboxError> {
    let mut applied = Applied::default();
    let in_inbox = |t: &Thread| t.is_inbox && !t.is_archived && &t.account_id == account_id;

    for thread_id in string_list(store, MUTE_THREADS_PREF) {
        let Some(thread) = store.get_thread(&thread_id)? else {
            continue;
        };
        if !in_inbox(&thread) {
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
        applied.muted.push(thread_id);
    }

    let blocked: Vec<String> = string_list(store, BLOCK_SENDERS_PREF)
        .into_iter()
        .map(|a| a.trim().to_lowercase())
        .filter(|a| !a.is_empty())
        .collect();
    if blocked.is_empty() {
        return Ok(applied);
    }
    let own_email = store
        .list_accounts()?
        .into_iter()
        .find(|a| &a.id == account_id)
        .map(|a| a.email)
        .unwrap_or_else(|| account_id.clone());
    for thread in store.inbox_threads_from(account_id, &blocked)? {
        if !in_inbox(&thread) {
            continue;
        }
        // The row names the newest sender who is not the user; the rule is
        // about the newest mail. Someone the user has just answered stays.
        let messages = store.list_message_meta(&thread.id)?;
        let newest = messages
            .iter()
            .rev()
            .find(|m| !m.label_ids.iter().any(|l| l == "DRAFT"));
        let from_blocked = match newest {
            Some(m) => {
                !is_own_message(m, &own_email)
                    && blocked.contains(&bare_addr(&m.from_addr).to_lowercase())
            }
            // No messages stored yet: the row is all there is to go by.
            None => blocked.contains(&thread.last_from_addr.to_lowercase()),
        };
        if !from_blocked {
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
        applied.blocked.push(thread.id);
    }
    Ok(applied)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{Message, ThreadFilter};
    use crate::fakes::{sample_account, FakeProvider, MemStore};
    use crate::ports::HistoryChange;
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
        store
            .list_threads(None, &ThreadFilter::Inbox, None, 100)
            .unwrap()
            .into_iter()
            .map(|t| t.id)
            .collect()
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
        let muted = "a1:t0".to_string();
        // The user mutes it: the shell archives it and lists it.
        outbox::enqueue(
            &store,
            &a1,
            Mutation::Archive {
                thread_id: muted.clone(),
            },
        )
        .unwrap();
        outbox::drain(&provider, &store, 10).await.unwrap();
        store
            .set_pref(MUTE_THREADS_PREF, Some(&json!([muted, "unknown-thread"])))
            .unwrap();
        assert!(!apply(&store, &a1).unwrap().any(), "it is not in the inbox");

        // Someone writes in it again: the delta round puts it back,
        // unread.
        let mut thread = store.get_thread(&muted).unwrap().unwrap();
        thread.is_inbox = true;
        thread.is_archived = false;
        thread.is_read = false;
        thread.labels = vec!["INBOX".into(), "UNREAD".into()];
        thread.msg_count = 2;
        let mut reply = store.list_messages(&muted).unwrap().remove(0);
        reply.id = format!("{muted}:m1");
        reply.date += 1;
        reply.is_read = false;
        provider.push_history(
            HistoryChange::MessageAdded {
                thread,
                messages: vec![reply],
            },
            "hist-2",
        );
        crate::sync::delta_sync(&provider, &store, &a1, 30)
            .await
            .unwrap();
        assert!(inbox(&store).contains(&muted));

        let applied = apply(&store, &a1).unwrap();
        assert_eq!(applied.muted, vec![muted.clone()]);
        assert!(applied.blocked.is_empty());
        let after = store.get_thread(&muted).unwrap().unwrap();
        assert!(after.is_archived && !after.is_inbox && after.is_read);
        assert_eq!(inbox(&store).len(), 2);
        assert_eq!(
            queued(&store),
            vec![format!("archive:{muted}"), format!("read:{muted}")]
        );
        // Gmail hears of it through the outbox like any other change.
        outbox::drain(&provider, &store, 10).await.unwrap();
        assert!(queued(&store).is_empty());
        assert!(!apply(&store, &a1).unwrap().any());
    }

    /// Mail whose newest message is from a blocked address goes to Spam;
    /// a thread the user answered last stays, as does another account's.
    #[tokio::test]
    async fn mail_from_a_blocked_sender_goes_to_spam() {
        let (store, _) = synced_store(4).await;
        let a1 = A1.to_string();
        // Sample thread N is from senderN@example.com.
        store
            .set_pref(
                BLOCK_SENDERS_PREF,
                Some(&json!(["sender1@example.com", " Sender2@Example.com "])),
            )
            .unwrap();
        // The user replied last in thread 2: the row still names the
        // other party, but the newest mail is the user's own.
        let t2 = "a1:t2".to_string();
        let received = store.list_messages(&t2).unwrap().remove(0);
        store
            .upsert_message(&Message {
                id: format!("{t2}:reply"),
                from_addr: "a1@example.com".to_string(),
                to_addrs: vec!["sender2@example.com".to_string()],
                date: received.date + 1,
                label_ids: vec!["SENT".to_string()],
                ..received
            })
            .unwrap();
        // Another account's rules pass does not touch this account's mail.
        assert!(!apply(&store, &"other".to_string()).unwrap().any());

        let applied = apply(&store, &a1).unwrap();
        assert_eq!(applied.blocked, vec!["a1:t1".to_string()]);
        assert!(applied.muted.is_empty());
        let spam = store.get_thread(&"a1:t1".to_string()).unwrap().unwrap();
        assert!(!spam.is_inbox && spam.labels.contains(&"SPAM".to_string()));
        let mut left = inbox(&store);
        left.sort();
        assert_eq!(left, vec!["a1:t0", "a1:t2", "a1:t3"]);
        assert_eq!(queued(&store), vec!["spam:a1:t1"]);
        // Out of the inbox, it is not looked at again.
        assert!(!apply(&store, &a1).unwrap().any());
    }
}
