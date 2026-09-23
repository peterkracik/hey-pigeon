//! Backfill sync: page through recent threads and upsert into the store.
//! Idempotent — safe to re-run after crash/quit (upserts keyed on native ids).

use crate::domain::{AccountId, Message, ThreadId};
use crate::ports::{HistoryChange, MailError, MailProvider, Store, StoreError};

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error(transparent)]
    Mail(#[from] MailError),
    #[error(transparent)]
    Store(#[from] StoreError),
}

/// M1 backfill: capture `historyId` FIRST (so the future delta loop has a
/// checkpoint that predates the backfill), then page newest-first through the
/// provider and upsert everything.
pub async fn backfill<M: MailProvider, S: Store>(
    provider: &M,
    store: &S,
    account_id: &AccountId,
    window_days: u32,
) -> Result<usize, SyncError> {
    let profile = provider.profile(account_id).await?;
    store.set_history_id(account_id, &profile.history_id)?;

    // Label list refresh rides the backfill (connect + sync_now). Cosmetic
    // sidebar data — a failure must not abort the mail sync.
    match provider.list_labels(account_id).await {
        Ok(labels) => store.set_labels(account_id, &labels)?,
        Err(e) => log::warn!("list_labels({account_id}) failed: {e}"),
    }

    let mut total = 0usize;
    let mut page_token: Option<String> = None;
    loop {
        let page = provider
            .list_recent(account_id, window_days, page_token.take())
            .await?;
        for (thread, messages) in &page.threads {
            store.upsert_thread(thread)?;
            for m in messages {
                store.upsert_message(m)?;
            }
            total += 1;
        }
        match page.next_page_token {
            Some(t) => page_token = Some(t),
            None => break,
        }
    }
    log::info!("backfill({account_id}): {total} threads");
    Ok(total)
}

/// M2 delta loop: apply the provider's history feed since the stored
/// checkpoint, then advance the checkpoint. Falls back to a full backfill
/// when the checkpoint is missing or expired (Gmail 404s an old historyId).
/// Returns whether anything changed locally.
pub async fn delta_sync<M: MailProvider, S: Store>(
    provider: &M,
    store: &S,
    account_id: &AccountId,
    window_days: u32,
) -> Result<bool, SyncError> {
    let Some(start) = store
        .list_accounts()?
        .into_iter()
        .find(|a| &a.id == account_id)
        .and_then(|a| a.history_id)
    else {
        log::info!("delta({account_id}): no checkpoint, running backfill");
        backfill(provider, store, account_id, window_days).await?;
        return Ok(true);
    };

    let mut changes = 0usize;
    let mut touched: Vec<ThreadId> = Vec::new();
    let mut page_token: Option<String> = None;
    // Checkpoint = newest history id actually applied; never regresses even
    // if a trailing page reports nothing newer.
    let mut latest = start.clone();
    loop {
        let page = match provider
            .list_history(account_id, &start, page_token.take())
            .await
        {
            Ok(p) => p,
            Err(MailError::HistoryExpired) => {
                log::info!("delta({account_id}): history expired, re-running backfill");
                backfill(provider, store, account_id, window_days).await?;
                return Ok(true);
            }
            Err(e) => return Err(e.into()),
        };
        for change in &page.changes {
            apply_change(store, change, &mut touched)?;
            changes += 1;
        }
        if newer_history_id(&page.latest_history_id, &latest) {
            latest = page.latest_history_id.clone();
        }
        match page.next_page_token {
            Some(t) => page_token = Some(t),
            None => break,
        }
    }
    // Threads whose messages changed in place need their derived row rebuilt.
    touched.sort();
    touched.dedup();
    for thread_id in &touched {
        refresh_thread(store, thread_id)?;
    }
    if latest != start {
        store.set_history_id(account_id, &latest)?;
    }
    log::info!("delta({account_id}): {changes} changes");
    Ok(changes > 0)
}

fn apply_change<S: Store>(
    store: &S,
    change: &HistoryChange,
    touched: &mut Vec<ThreadId>,
) -> Result<(), StoreError> {
    match change {
        // Fresh snapshot from the provider — plain upserts, like backfill.
        HistoryChange::MessageAdded { thread, messages } => {
            store.upsert_thread(thread)?;
            for m in messages {
                store.upsert_message(m)?;
            }
        }
        HistoryChange::MessageDeleted {
            thread_id,
            message_id,
        } => {
            store.delete_message(message_id)?;
            touched.push(thread_id.clone());
        }
        HistoryChange::LabelsAdded {
            thread_id,
            message_id,
            labels,
        } => {
            update_labels(store, thread_id, message_id, labels, &[])?;
            touched.push(thread_id.clone());
        }
        HistoryChange::LabelsRemoved {
            thread_id,
            message_id,
            labels,
        } => {
            update_labels(store, thread_id, message_id, &[], labels)?;
            touched.push(thread_id.clone());
        }
    }
    Ok(())
}

fn update_labels<S: Store>(
    store: &S,
    thread_id: &ThreadId,
    message_id: &str,
    add: &[String],
    remove: &[String],
) -> Result<(), StoreError> {
    // Unknown message (outside the backfill window) — nothing to update.
    let Some(mut m) = store
        .list_messages(thread_id)?
        .into_iter()
        .find(|m| m.id == message_id)
    else {
        return Ok(());
    };
    for l in add {
        if !m.label_ids.contains(l) {
            m.label_ids.push(l.clone());
        }
    }
    m.label_ids.retain(|l| !remove.contains(l));
    m.is_read = !m.label_ids.iter().any(|l| l == "UNREAD");
    store.upsert_message(&m)
}

/// Union of Gmail label ids over a thread's messages — the thread-level
/// `labels` field the folder queries run on.
pub fn thread_labels_union(messages: &[Message]) -> Vec<String> {
    let mut labels: Vec<String> = Vec::new();
    for m in messages {
        for l in &m.label_ids {
            if !labels.contains(l) {
                labels.push(l.clone());
            }
        }
    }
    labels
}

/// Archive-folder semantics: a thread is "archived" when the user removed it
/// from the inbox — no INBOX, and not in a state with its own folder (TRASH,
/// SPAM, DRAFT) — AND it contains at least one received message (a message
/// without SENT). A sent-only thread (every message carries SENT) was simply
/// never in the inbox: it belongs to Sent, not Archive. A sent thread that
/// got replies and was then archived has received messages, so it correctly
/// shows in both Sent and Archive.
pub fn derive_is_archived(labels: &[String], messages: &[Message]) -> bool {
    let has = |l: &str| labels.iter().any(|x| x == l);
    !has("INBOX")
        && !has("TRASH")
        && !has("SPAM")
        && !has("DRAFT")
        && messages
            .iter()
            .any(|m| !m.label_ids.iter().any(|l| l == "SENT"))
}

/// Rebuild a thread's derived row from its stored messages after in-place
/// changes (deletes, label flips). Trashed messages stay — the Trash folder
/// lists them locally; only a thread with no messages left (permanent
/// deletes) is dropped entirely.
fn refresh_thread<S: Store>(store: &S, thread_id: &ThreadId) -> Result<(), StoreError> {
    let Some(mut t) = store.get_thread(thread_id)? else {
        return Ok(()); // never synced locally — ignore
    };
    let messages = store.list_messages(thread_id)?; // sorted by date
    let Some(last) = messages.last() else {
        return store.delete_thread(thread_id);
    };
    t.snippet = last.snippet.clone();
    t.last_msg_at = last.date;
    t.msg_count = messages.len() as i64;
    t.is_read = messages.iter().all(|m| m.is_read);
    t.labels = thread_labels_union(&messages);
    // Inbox/archived state is label-derived too: back-in-inbox elsewhere must
    // clear a local archive, or the thread never reappears in the local inbox.
    t.is_inbox = t.labels.iter().any(|l| l == "INBOX");
    t.is_archived = derive_is_archived(&t.labels, &messages);
    t.from_summary = display_name(&last.from_addr);
    t.last_from_addr = bare_addr(&last.from_addr);
    store.upsert_thread(&t)
}

/// Gmail history ids are numeric strings; compare numerically when possible
/// (fake ids like "hist-2" fall back to lexicographic comparison).
fn newer_history_id(candidate: &str, current: &str) -> bool {
    match (candidate.parse::<u64>(), current.parse::<u64>()) {
        (Ok(c), Ok(cur)) => c > cur,
        _ => candidate > current,
    }
}

/// "Priya Nair <priya@acme.co>" → "Priya Nair" (falls back to the address).
fn display_name(from: &str) -> String {
    let name = from
        .split('<')
        .next()
        .unwrap_or("")
        .trim()
        .trim_matches('"');
    if name.is_empty() {
        from.trim().to_string()
    } else {
        name.to_string()
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::ThreadFilter;
    use crate::fakes::{FakeProvider, MemStore};

    #[tokio::test]
    async fn backfill_stores_history_id_then_threads() {
        let provider = FakeProvider::with_sample_data("a1", 25, 10); // 25 threads, page size 10
        let store = MemStore::default();
        store
            .upsert_account(&crate::fakes::sample_account("a1"))
            .unwrap();

        let n = backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();

        assert_eq!(n, 25, "all pages walked");
        let accounts = store.list_accounts().unwrap();
        assert_eq!(accounts[0].history_id.as_deref(), Some("hist-1"));
        let threads = store
            .list_threads(None, &ThreadFilter::Inbox, None, 100)
            .unwrap();
        assert_eq!(threads.len(), 25);
        // newest first
        assert!(threads
            .windows(2)
            .all(|w| w[0].last_msg_at >= w[1].last_msg_at));
    }

    fn new_thread_change(account_id: &str, i: usize, date: i64) -> HistoryChange {
        let tid = format!("{account_id}:new{i}");
        let thread = crate::domain::Thread {
            id: tid.clone(),
            account_id: account_id.to_string(),
            subject: format!("New thread {i}"),
            snippet: format!("New snippet {i}"),
            last_msg_at: date,
            is_read: false,
            is_inbox: true,
            is_archived: false,
            msg_count: 1,
            from_summary: "Newcomer".to_string(),
            last_from_addr: "new@example.com".to_string(),
            scheduled_at: None,
            labels: vec!["INBOX".to_string(), "UNREAD".to_string()],
            has_attachment: false,
            priority: None,
            triage_label_ids: Vec::new(),
        };
        let message = crate::domain::Message {
            id: format!("{tid}:m0"),
            thread_id: tid,
            account_id: account_id.to_string(),
            from_addr: "Newcomer <new@example.com>".to_string(),
            to_addrs: vec![format!("{account_id}@example.com")],
            date,
            snippet: format!("New snippet {i}"),
            body_html: None,
            body_text: None,
            label_ids: vec!["INBOX".to_string(), "UNREAD".to_string()],
            is_read: false,
        };
        HistoryChange::MessageAdded {
            thread,
            messages: vec![message],
        }
    }

    async fn synced_fixture(n: usize) -> (FakeProvider, MemStore) {
        let provider = FakeProvider::with_sample_data("a1", n, 10);
        let store = MemStore::default();
        store
            .upsert_account(&crate::fakes::sample_account("a1"))
            .unwrap();
        backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        (provider, store)
    }

    #[tokio::test]
    async fn delta_applies_added_message() {
        let (provider, store) = synced_fixture(3).await;
        provider.push_history(new_thread_change("a1", 0, 1_756_700_000_000), "hist-2");

        let changed = delta_sync(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();

        assert!(changed);
        let threads = store
            .list_threads(None, &ThreadFilter::Inbox, None, 100)
            .unwrap();
        assert_eq!(threads.len(), 4);
        assert_eq!(threads[0].id, "a1:new0", "new mail sorts first");
        assert!(!threads[0].is_read);
        // checkpoint advanced → second run is a no-op
        assert_eq!(
            store.list_accounts().unwrap()[0].history_id.as_deref(),
            Some("hist-2")
        );
        let changed = delta_sync(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        assert!(!changed);
    }

    #[tokio::test]
    async fn delta_applies_deleted_message() {
        let (provider, store) = synced_fixture(3).await;
        let victim = store
            .list_threads(None, &ThreadFilter::Inbox, None, 1)
            .unwrap()[0]
            .clone();
        provider.push_history(
            HistoryChange::MessageDeleted {
                thread_id: victim.id.clone(),
                message_id: format!("{}:m0", victim.id),
            },
            "hist-2",
        );

        let changed = delta_sync(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();

        assert!(changed);
        // sole message gone → thread dropped entirely
        assert!(store.get_thread(&victim.id).unwrap().is_none());
        assert_eq!(
            store
                .list_threads(None, &ThreadFilter::Inbox, None, 100)
                .unwrap()
                .len(),
            2
        );
    }

    #[tokio::test]
    async fn delta_applies_label_changes() {
        let (provider, store) = synced_fixture(3).await;
        let threads = store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap();
        let (a, b, c) = (&threads[0], &threads[1], &threads[2]);
        // a: UNREAD added; b: INBOX removed (archive); c: trashed (Gmail
        // adds TRASH and removes INBOX)
        provider.push_history(
            HistoryChange::LabelsAdded {
                thread_id: a.id.clone(),
                message_id: format!("{}:m0", a.id),
                labels: vec!["UNREAD".to_string()],
            },
            "hist-2",
        );
        provider.push_history(
            HistoryChange::LabelsRemoved {
                thread_id: b.id.clone(),
                message_id: format!("{}:m0", b.id),
                labels: vec!["INBOX".to_string()],
            },
            "hist-3",
        );
        provider.push_history(
            HistoryChange::LabelsAdded {
                thread_id: c.id.clone(),
                message_id: format!("{}:m0", c.id),
                labels: vec!["TRASH".to_string()],
            },
            "hist-4",
        );
        provider.push_history(
            HistoryChange::LabelsRemoved {
                thread_id: c.id.clone(),
                message_id: format!("{}:m0", c.id),
                labels: vec!["INBOX".to_string()],
            },
            "hist-5",
        );

        let changed = delta_sync(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();

        assert!(changed);
        assert!(!store.get_thread(&a.id).unwrap().unwrap().is_read);
        assert!(!store.get_thread(&b.id).unwrap().unwrap().is_inbox);
        // trashed thread stays local so the Trash folder can list it
        let c_after = store.get_thread(&c.id).unwrap().unwrap();
        assert!(c_after.labels.iter().any(|l| l == "TRASH"));
        assert!(!c_after.is_inbox && !c_after.is_archived);
        let listed = store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, a.id);
        let trash = store
            .list_threads(None, &ThreadFilter::Trash, None, 10)
            .unwrap();
        assert_eq!(trash.len(), 1);
        assert_eq!(trash[0].id, c.id);
        assert_eq!(
            store.list_accounts().unwrap()[0].history_id.as_deref(),
            Some("hist-5")
        );
    }

    #[tokio::test]
    async fn delta_label_changes_update_thread_labels_union() {
        let (provider, store) = synced_fixture(1).await;
        let t = store
            .list_threads(None, &ThreadFilter::Inbox, None, 1)
            .unwrap()[0]
            .clone();
        assert_eq!(
            t.labels,
            vec!["INBOX".to_string()],
            "backfill stores the union"
        );

        provider.push_history(
            HistoryChange::LabelsAdded {
                thread_id: t.id.clone(),
                message_id: format!("{}:m0", t.id),
                labels: vec!["STARRED".to_string(), "Label_1".to_string()],
            },
            "hist-2",
        );
        delta_sync(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();

        let after = store.get_thread(&t.id).unwrap().unwrap();
        assert!(after.labels.iter().any(|l| l == "STARRED"));
        assert!(after.labels.iter().any(|l| l == "Label_1"));
        let starred = store
            .list_threads(None, &ThreadFilter::Starred, None, 10)
            .unwrap();
        assert_eq!(starred.len(), 1);
        let labelled = store
            .list_threads(None, &ThreadFilter::Label("Label_1".to_string()), None, 10)
            .unwrap();
        assert_eq!(labelled.len(), 1);

        provider.push_history(
            HistoryChange::LabelsRemoved {
                thread_id: t.id.clone(),
                message_id: format!("{}:m0", t.id),
                labels: vec!["STARRED".to_string()],
            },
            "hist-3",
        );
        delta_sync(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let after = store.get_thread(&t.id).unwrap().unwrap();
        assert!(
            !after.labels.iter().any(|l| l == "STARRED"),
            "union follows removals"
        );
    }

    #[test]
    fn archive_semantics_sent_only_thread_is_not_archived() {
        let msg = |labels: &[&str]| Message {
            id: "m".to_string(),
            thread_id: "t".to_string(),
            account_id: "a1".to_string(),
            from_addr: "me@example.com".to_string(),
            to_addrs: vec![],
            date: 0,
            snippet: String::new(),
            body_html: None,
            body_text: None,
            label_ids: labels.iter().map(|s| s.to_string()).collect(),
            is_read: true,
        };
        // Sent-only thread: never in the inbox ≠ archived — belongs to Sent.
        let sent_only = vec![msg(&["SENT"])];
        assert!(!derive_is_archived(
            &thread_labels_union(&sent_only),
            &sent_only
        ));
        // Received mail without INBOX/TRASH/SPAM/DRAFT: the user archived it.
        let archived = vec![msg(&[])];
        assert!(derive_is_archived(
            &thread_labels_union(&archived),
            &archived
        ));
        // Sent thread with an archived reply: Sent AND Archive.
        let mixed = vec![msg(&["SENT"]), msg(&[])];
        assert!(derive_is_archived(&thread_labels_union(&mixed), &mixed));
        // Still in the inbox / trash / spam / drafts → not Archive.
        for l in ["INBOX", "TRASH", "SPAM", "DRAFT"] {
            let m = vec![msg(&[l])];
            assert!(!derive_is_archived(&thread_labels_union(&m), &m), "{l}");
        }
    }

    #[tokio::test]
    async fn backfill_stores_account_labels() {
        let (_, store) = synced_fixture(1).await;
        let labels = store.list_labels().unwrap();
        assert_eq!(labels.len(), 2, "FakeProvider serves two user labels");
        assert!(labels
            .iter()
            .any(|l| l.name == "Projects" && l.account_id == "a1"));
    }

    #[tokio::test]
    async fn delta_unarchives_locally_archived_thread() {
        let (provider, store) = synced_fixture(3).await;
        let victim = store
            .list_threads(None, &ThreadFilter::Inbox, None, 1)
            .unwrap()[0]
            .clone();
        // Local archive (optimistic apply): is_archived=1, is_inbox=0.
        store
            .apply_local(&crate::domain::Mutation::Archive {
                thread_id: victim.id.clone(),
            })
            .unwrap();
        assert!(store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap()
            .iter()
            .all(|t| t.id != victim.id));
        // Another device moves it back to the inbox.
        provider.push_history(
            HistoryChange::LabelsAdded {
                thread_id: victim.id.clone(),
                message_id: format!("{}:m0", victim.id),
                labels: vec!["INBOX".to_string()],
            },
            "hist-2",
        );

        let changed = delta_sync(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();

        assert!(changed);
        let t = store.get_thread(&victim.id).unwrap().unwrap();
        assert!(
            t.is_inbox && !t.is_archived,
            "remote un-archive clears local archive"
        );
        assert!(store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap()
            .iter()
            .any(|t| t.id == victim.id));
    }

    #[tokio::test]
    async fn delta_falls_back_to_backfill_on_expired_history() {
        let (provider, store) = synced_fixture(5).await;
        store
            .set_history_id(&"a1".to_string(), "hist-ancient")
            .unwrap();
        provider.expire_history();

        let changed = delta_sync(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();

        assert!(changed, "fallback backfill counts as a change");
        assert_eq!(
            store
                .list_threads(None, &ThreadFilter::Inbox, None, 100)
                .unwrap()
                .len(),
            5
        );
        // checkpoint reset to the fresh profile history id
        assert_eq!(
            store.list_accounts().unwrap()[0].history_id.as_deref(),
            Some("hist-1")
        );
    }

    #[tokio::test]
    async fn delta_without_checkpoint_runs_backfill() {
        let provider = FakeProvider::with_sample_data("a1", 4, 10);
        let store = MemStore::default();
        store
            .upsert_account(&crate::fakes::sample_account("a1"))
            .unwrap();

        let changed = delta_sync(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();

        assert!(changed);
        assert_eq!(
            store
                .list_threads(None, &ThreadFilter::Inbox, None, 100)
                .unwrap()
                .len(),
            4
        );
        assert_eq!(
            store.list_accounts().unwrap()[0].history_id.as_deref(),
            Some("hist-1")
        );
    }

    #[tokio::test]
    async fn backfill_is_idempotent() {
        let provider = FakeProvider::with_sample_data("a1", 5, 10);
        let store = MemStore::default();
        store
            .upsert_account(&crate::fakes::sample_account("a1"))
            .unwrap();
        backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        assert_eq!(
            store
                .list_threads(None, &ThreadFilter::Inbox, None, 100)
                .unwrap()
                .len(),
            5
        );
    }
}
