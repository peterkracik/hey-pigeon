//! Optimistic mutations: apply locally now, queue for the provider, drain later.
//! This is the entire "feels instant" trick (DESIGN.md).

use crate::devsync;
use crate::domain::{AccountId, Message, Mutation};
use crate::ports::{MailError, MailProvider, Store, StoreError};

#[derive(Debug, thiserror::Error)]
pub enum OutboxError {
    #[error(transparent)]
    Store(#[from] StoreError),
}

/// How many times the provider may refuse a row before the drain stops
/// retrying it. The row stays in the outbox (`Store::outbox_counts` reports
/// it as parked): a change Gmail will never take — a thread deleted
/// elsewhere, a label that is gone — used to be sent again on every drain,
/// for good.
pub const MAX_ATTEMPTS: i64 = 5;

/// Apply a mutation to the local store and enqueue it for the provider.
/// Returns immediately — the UI never waits for the network.
///
/// Done (archive) and delete also end the thread's reminder, follow-up and
/// "needs reply" flag: those lists only hold mail still waiting in the
/// inbox. Returns true when it cleared one, so the caller can push the
/// cross-device sync map now rather than on the next round.
pub fn enqueue<S: Store>(
    store: &S,
    account_id: &AccountId,
    mutation: Mutation,
) -> Result<bool, OutboxError> {
    enqueue_item(store, account_id, mutation).map(|(_, cleared)| cleared)
}

/// `enqueue`, also returning the outbox row's id: the caller that waits for
/// a send looks the row up after the drain (`Store::outbox_contains`).
pub fn enqueue_item<S: Store>(
    store: &S,
    account_id: &AccountId,
    mutation: Mutation,
) -> Result<(i64, bool), OutboxError> {
    let mutation = with_reply_headers(store, mutation);
    store.apply_local(&mutation)?;
    let id = store.outbox_push(account_id, &mutation)?;
    let cleared = match &mutation {
        Mutation::Archive { thread_id }
        | Mutation::Trash { thread_id }
        | Mutation::MarkSpam {
            thread_id,
            spam: true,
        } => devsync::clear_on_done(store, thread_id)?,
        _ => false,
    };
    Ok((id, cleared))
}

/// `In-Reply-To` and `References` for a reply to the newest message of
/// `messages` that is mail (not the user's unsent draft): its Message-ID,
/// and its own References followed by that Message-ID (RFC 5322 3.6.4).
/// None when that message's Message-ID is not stored — mail synced before
/// the header was kept.
pub fn reply_headers(messages: &[Message]) -> Option<(String, String)> {
    let parent = messages
        .iter()
        .rev()
        .find(|m| !m.label_ids.iter().any(|l| l == "DRAFT"))?;
    let id = parent.message_id_header.as_deref()?.trim();
    if id.is_empty() {
        return None;
    }
    let references = match parent.references_header.as_deref().map(str::trim) {
        Some(r) if !r.is_empty() => format!("{r} {id}"),
        _ => id.to_string(),
    };
    Some((id.to_string(), references))
}

/// Fill a reply's `In-Reply-To` / `References` from the stored thread when
/// the caller did not. Never fails: a reply without them still goes out
/// and still threads on the sender's side.
fn with_reply_headers<S: Store>(store: &S, mut mutation: Mutation) -> Mutation {
    if let Mutation::Send {
        reply_to_thread: Some(thread_id),
        in_reply_to,
        references,
        ..
    }
    | Mutation::SaveDraft {
        reply_to_thread: Some(thread_id),
        in_reply_to,
        references,
        ..
    } = &mut mutation
    {
        if in_reply_to.is_none() {
            let found = store
                .list_message_meta(thread_id)
                .ok()
                .and_then(|messages| reply_headers(&messages));
            if let Some((id, refs)) = found {
                *in_reply_to = Some(id);
                *references = Some(refs);
            }
        }
    }
    mutation
}

/// What one drain did.
#[derive(Debug, Default)]
pub struct DrainReport {
    pub applied: usize,
    pub failed: usize,
    /// Every row that did not go through this time, with the reason.
    pub failures: Vec<(i64, MailError)>,
}

impl DrainReport {
    pub fn failure(&self, id: i64) -> Option<&MailError> {
        self.failures.iter().find(|(i, _)| *i == id).map(|(_, e)| e)
    }
}

/// Drain pending mutations against the provider, oldest first, `batch`
/// rows per page, through the whole queue. Returns (applied, failed).
pub async fn drain<M: MailProvider, S: Store>(
    provider: &M,
    store: &S,
    batch: u32,
) -> Result<(usize, usize), OutboxError> {
    let report = drain_report(provider, store, batch).await?;
    Ok((report.applied, report.failed))
}

/// `drain`, with the reason each failed row failed.
///
/// What a failure means decides what happens next:
/// - The provider refused the row (`Provider`): it is counted against
///   `MAX_ATTEMPTS` and the drain goes on to the next row.
/// - The account's grant is gone (`AuthExpired`): the rest of that
///   account's rows are skipped, other accounts' rows still go out. One
///   signed-out account used to stop every other account's changes.
/// - The network is down or Gmail is rate limiting: the drain stops, and
///   nothing is counted against the rows — an hour offline must not park a
///   queued send. One transport failure alone does not prove that, so the
///   next row is tried: if that one gets an answer, the failure was the
///   first row's own (an upload the connection keeps dropping) and it is
///   counted, so it cannot block the queue behind it for good.
///
/// Callers must not run two drains at once: both would read the same rows
/// and apply each twice (a send, sent twice). The shells hold a lock.
pub async fn drain_report<M: MailProvider, S: Store>(
    provider: &M,
    store: &S,
    batch: u32,
) -> Result<DrainReport, OutboxError> {
    let mut report = DrainReport::default();
    let mut signed_out: Vec<AccountId> = Vec::new();
    // A row that failed in transport, until the next row shows whether the
    // network or the row was at fault.
    let mut unreached: Option<i64> = None;
    let mut after_id = 0i64;
    'pages: loop {
        let items = store.outbox_list_due(after_id, batch.max(1), MAX_ATTEMPTS)?;
        let Some(last) = items.last() else {
            break;
        };
        after_id = last.id;
        for item in items {
            if signed_out.contains(&item.account_id) {
                continue;
            }
            match provider.apply(&item.account_id, &item.mutation).await {
                Ok(()) => {
                    store.outbox_delete(item.id)?;
                    report.applied += 1;
                    if let Some(id) = unreached.take() {
                        store.outbox_bump_attempts(id)?;
                    }
                }
                Err(MailError::AuthExpired) => {
                    log::warn!(
                        "outbox drain: auth expired for {}, skipping its rows",
                        item.account_id
                    );
                    signed_out.push(item.account_id.clone());
                    report.failed += 1;
                    report.failures.push((item.id, MailError::AuthExpired));
                }
                Err(e @ (MailError::Network(_) | MailError::RateLimited { .. })) => {
                    log::warn!("outbox drain: item {} not sent: {e}", item.id);
                    let rate_limited = matches!(e, MailError::RateLimited { .. });
                    report.failed += 1;
                    report.failures.push((item.id, e));
                    if rate_limited || unreached.is_some() {
                        break 'pages;
                    }
                    unreached = Some(item.id);
                }
                Err(e) => {
                    store.outbox_bump_attempts(item.id)?;
                    if item.attempts + 1 >= MAX_ATTEMPTS {
                        log::warn!(
                            "outbox drain: item {} refused {MAX_ATTEMPTS} times, parked: {e}",
                            item.id
                        );
                    } else {
                        log::warn!("outbox drain: item {} failed: {e}", item.id);
                    }
                    report.failed += 1;
                    report.failures.push((item.id, e));
                    if let Some(id) = unreached.take() {
                        store.outbox_bump_attempts(id)?;
                    }
                }
            }
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::ThreadFilter;
    use crate::fakes::{FakeProvider, MemStore};

    fn seeded_store() -> MemStore {
        let store = MemStore::default();
        store
            .upsert_account(&crate::fakes::sample_account("a1"))
            .unwrap();
        store
    }

    #[tokio::test]
    async fn enqueue_applies_locally_and_queues() {
        let store = seeded_store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        crate::sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let t = &store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap()[0];

        enqueue(
            &store,
            &"a1".to_string(),
            Mutation::Archive {
                thread_id: t.id.clone(),
            },
        )
        .unwrap();

        // local effect is immediate
        let t2 = store.get_thread(&t.id).unwrap().unwrap();
        assert!(t2.is_archived);
        assert!(!t2.is_inbox);
        assert_eq!(store.outbox_list(10).unwrap().len(), 1);
    }

    #[tokio::test]
    async fn done_clears_reminder_follow_up_and_needs_reply() {
        let store = seeded_store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        crate::sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let ids: Vec<_> = store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap()
            .into_iter()
            .map(|t| t.id)
            .collect();
        let (flagged, plain) = (&ids[0], &ids[1]);
        store.set_schedule(flagged, Some(1)).unwrap();
        store.set_follow_up(flagged, Some(1)).unwrap();
        store.set_needs_reply(flagged, true).unwrap();

        let a1 = "a1".to_string();
        assert!(enqueue(
            &store,
            &a1,
            Mutation::Archive {
                thread_id: flagged.clone()
            }
        )
        .unwrap());
        let t = store.get_thread(flagged).unwrap().unwrap();
        assert_eq!(
            (t.scheduled_at, t.follow_up_since, t.needs_reply),
            (None, None, false)
        );
        // The clears travel to the other devices as tombstones.
        let keys: Vec<_> = store
            .sync_entries(&a1)
            .unwrap()
            .into_iter()
            .filter(|e| e.value.is_none())
            .map(|e| e.key)
            .collect();
        assert_eq!(keys.len(), 3, "{keys:?}");

        // Nothing to clear: no sync entries, nothing to push.
        assert!(!enqueue(
            &store,
            &a1,
            Mutation::Trash {
                thread_id: plain.clone()
            }
        )
        .unwrap());
        assert_eq!(store.sync_entries(&a1).unwrap().len(), 3);
    }

    #[tokio::test]
    async fn drain_applies_remotely_and_clears_queue() {
        let store = seeded_store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        crate::sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let id = store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap()[0]
            .id
            .clone();
        enqueue(
            &store,
            &"a1".to_string(),
            Mutation::Archive {
                thread_id: id.clone(),
            },
        )
        .unwrap();

        let (applied, failed) = drain(&provider, &store, 10).await.unwrap();

        assert_eq!((applied, failed), (1, 0));
        assert!(store.outbox_list(10).unwrap().is_empty());
        assert!(provider
            .applied_mutations()
            .iter()
            .any(|(_, m)| matches!(m, Mutation::Archive { thread_id } if *thread_id == id),));
    }

    /// Three archived threads queued; returns their ids, oldest row first.
    async fn three_queued(store: &MemStore, provider: &FakeProvider) -> Vec<String> {
        crate::sync::backfill(provider, store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let ids: Vec<String> = store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap()
            .into_iter()
            .map(|t| t.id)
            .collect();
        for id in &ids {
            enqueue(
                store,
                &"a1".to_string(),
                Mutation::Archive {
                    thread_id: id.clone(),
                },
            )
            .unwrap();
        }
        ids
    }

    /// Offline: the rows stay queued and nothing is counted against them,
    /// however many drains come by — an hour without network must not park
    /// a queued change.
    #[tokio::test]
    async fn offline_drains_keep_rows_queued_without_counting_attempts() {
        let store = seeded_store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        three_queued(&store, &provider).await;
        provider.fail_applies(true);

        for _ in 0..(MAX_ATTEMPTS + 2) {
            let (applied, failed) = drain(&provider, &store, 10).await.unwrap();
            // The second transport failure in a row ends the drain.
            assert_eq!((applied, failed), (0, 2));
        }
        let items = store.outbox_list(10).unwrap();
        assert_eq!(items.len(), 3);
        assert!(items.iter().all(|i| i.attempts == 0));
        assert_eq!(store.outbox_counts(MAX_ATTEMPTS).unwrap(), (3, 0));

        // Back online: everything goes out.
        provider.fail_applies(false);
        assert_eq!(drain(&provider, &store, 10).await.unwrap(), (3, 0));
        assert!(store.outbox_list(10).unwrap().is_empty());
    }

    /// A row the provider refuses is counted, parked after `MAX_ATTEMPTS`
    /// and kept; the rows behind it go out on the first drain.
    #[tokio::test]
    async fn a_refused_row_is_parked_and_never_blocks_the_queue() {
        let store = seeded_store();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        let ids = three_queued(&store, &provider).await;
        provider.refuse_thread(&ids[0]);

        // Page size 1: the refused row is alone on the first page.
        let report = drain_report(&provider, &store, 1).await.unwrap();
        assert_eq!((report.applied, report.failed), (2, 1));
        let left = store.outbox_list(10).unwrap();
        assert_eq!(left.len(), 1);
        assert_eq!(left[0].attempts, 1);
        assert!(matches!(
            report.failure(left[0].id),
            Some(MailError::Provider(_))
        ));

        for _ in 1..MAX_ATTEMPTS {
            assert_eq!(drain(&provider, &store, 10).await.unwrap(), (0, 1));
        }
        // Parked: still there, no longer tried.
        assert_eq!(drain(&provider, &store, 10).await.unwrap(), (0, 0));
        assert_eq!(store.outbox_list(10).unwrap()[0].attempts, MAX_ATTEMPTS);
        assert_eq!(store.outbox_counts(MAX_ATTEMPTS).unwrap(), (0, 1));
        assert!(store.outbox_contains(left[0].id).unwrap());
    }

    #[test]
    fn reply_headers_come_from_the_newest_mail_not_a_draft() {
        let msg = |id: &str, date: i64, labels: &[&str]| Message {
            id: id.to_string(),
            thread_id: "t".to_string(),
            date,
            label_ids: labels.iter().map(|l| l.to_string()).collect(),
            ..Default::default()
        };
        let mut first = msg("m1", 1, &["INBOX"]);
        first.message_id_header = Some("<one@x.com>".to_string());
        let mut second = msg("m2", 2, &["INBOX"]);
        second.message_id_header = Some(" <two@x.com> ".to_string());
        second.references_header = Some("<zero@x.com> <one@x.com>".to_string());
        let draft = msg("m3", 3, &["DRAFT"]);

        assert_eq!(
            reply_headers(&[first.clone(), second.clone(), draft.clone()]),
            Some((
                "<two@x.com>".to_string(),
                "<zero@x.com> <one@x.com> <two@x.com>".to_string()
            ))
        );
        // No References on the parent: its Message-ID starts the chain.
        assert_eq!(
            reply_headers(std::slice::from_ref(&first)),
            Some(("<one@x.com>".to_string(), "<one@x.com>".to_string()))
        );
        // Synced before the header was kept: nothing to say, not an error.
        assert_eq!(reply_headers(&[first, msg("m4", 4, &["INBOX"])]), None);
        assert_eq!(reply_headers(&[draft]), None);
    }

    /// A reply queued without threading headers gets them from the stored
    /// thread; one that already carries them, or answers an unknown thread,
    /// goes out as it is.
    #[tokio::test]
    async fn a_queued_reply_carries_the_stored_threading_headers() {
        let store = seeded_store();
        let provider = FakeProvider::with_sample_data("a1", 1, 10);
        crate::sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let thread = store
            .list_threads(None, &ThreadFilter::Inbox, None, 10)
            .unwrap()
            .remove(0);
        let mut parent = store.list_messages(&thread.id).unwrap().remove(0);
        parent.message_id_header = Some("<parent@x.com>".to_string());
        store.upsert_message(&parent).unwrap();

        let reply = |thread_id: &str, in_reply_to: Option<&str>| Mutation::Send {
            to: vec!["b@x.com".to_string()],
            cc: vec![],
            bcc: vec![],
            subject: "Re: hi".to_string(),
            body_text: "ok".to_string(),
            body_html: None,
            attachments: vec![],
            reply_to_thread: Some(thread_id.to_string()),
            from_addr: None,
            in_reply_to: in_reply_to.map(str::to_string),
            references: None,
        };
        let a1 = "a1".to_string();
        enqueue(&store, &a1, reply(&thread.id, None)).unwrap();
        enqueue(&store, &a1, reply(&thread.id, Some("<other@x.com>"))).unwrap();
        enqueue(&store, &a1, reply("unknown-thread", None)).unwrap();

        let queued: Vec<(Option<String>, Option<String>)> = store
            .outbox_list(10)
            .unwrap()
            .into_iter()
            .map(|i| match i.mutation {
                Mutation::Send {
                    in_reply_to,
                    references,
                    ..
                } => (in_reply_to, references),
                _ => unreachable!(),
            })
            .collect();
        assert_eq!(
            queued,
            vec![
                (
                    Some("<parent@x.com>".to_string()),
                    Some("<parent@x.com>".to_string())
                ),
                (Some("<other@x.com>".to_string()), None),
                (None, None),
            ]
        );
    }

    /// Outbox rows written before `from_addr` and the threading headers
    /// existed still read.
    #[test]
    fn rows_from_older_builds_still_deserialize() {
        let old = r#"{"kind":"send","to":["a@x.com"],"subject":"s","body_text":"b"}"#;
        let m: Mutation = serde_json::from_str(old).unwrap();
        assert!(matches!(
            m,
            Mutation::Send {
                from_addr: None,
                in_reply_to: None,
                references: None,
                ..
            }
        ));
    }
}
