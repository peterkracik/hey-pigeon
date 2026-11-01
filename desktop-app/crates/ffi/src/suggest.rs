//! AI suggestions for new mail: each new unread email is read once by the
//! shell's model, which proposes "Need reply" (the sender waits on an
//! answer) or "Remind me" on a date the email names (a meeting, a
//! deadline). Nothing changes on its own — the proposal waits on the thread
//! until the user accepts it (the app calls `set_needs_reply` /
//! `set_schedule`, which drop it) or dismisses it.
//!
//! Rides the sync cadence after triage, like `classify_pending`. Only the
//! shell's backends answer (Apple's models on device or in Private Cloud
//! Compute, or a model package the shell registered), in the user's
//! provider order: OpenAI never gets a body without a tap, and the dates
//! need the user's time zone, which only the shell knows. Results
//! are local, like triage: every device can analyze its own new mail.

use std::sync::Arc;

use heypigeon_core::domain::{now_ms, Message, Suggestion, Thread};
use heypigeon_core::ports::{MailError, MailProvider, Store};

use crate::ai::AiBackend;
use crate::engine::Engine;
use crate::types::*;

/// The switch (`pref:ai.suggest`, synced). Unset = on: it only runs when
/// one of the shell's models is there to answer.
pub(crate) const SUGGEST_ENABLED_PREF: &str = "ai.suggest";
/// Threads analyzed per sync round; the next round continues.
const SUGGEST_BATCH: u32 = 5;
/// "New" mail: arrived in the last three days. Older unread mail (the first
/// sync of a mailbox, a week away) is not worth a model call each.
const SUGGEST_WINDOW_MS: i64 = 3 * 86_400_000;
/// The model reads at most this much of the newest message; the backend
/// trims further to its own context window.
const SUGGEST_BODY_CHARS: usize = 4_000;
/// A reminder further out than this is the model misreading a year.
const SUGGEST_MAX_AHEAD_MS: i64 = 366 * 86_400_000;

#[uniffi::export]
impl Engine {
    /// Drop a thread's AI suggestion without acting on it. The same
    /// message is never proposed again; a new one in the thread may be.
    pub fn dismiss_suggestion(&self, thread_id: String) -> Result<(), EngineError> {
        if self.store.clear_thread_suggestion(&thread_id)? {
            self.notify_threads_updated();
        }
        Ok(())
    }
}

// Internals — not exported.
impl Engine {
    fn suggestions_enabled(&self) -> Result<bool, EngineError> {
        Ok(self
            .store
            .get_pref(SUGGEST_ENABLED_PREF)?
            .and_then(|v| v.as_bool())
            .unwrap_or(true))
    }

    /// The shell backend that answers: the preferred provider, then the
    /// fallback order, skipping anything that is not a shell backend on
    /// this device (OpenAI is never sent a body for this).
    fn suggestion_backend(&self) -> Result<Option<Arc<dyn AiBackend>>, EngineError> {
        Ok(self
            .provider_candidates()?
            .iter()
            .find_map(|id| self.backend(id)))
    }

    /// Analyze up to `SUGGEST_BATCH` new unread threads. Called at the end
    /// of `sync_all`, after triage; overlapping rounds are skipped.
    pub(crate) async fn suggest_pending(&self) {
        {
            let mut running = self.suggesting.lock().unwrap();
            if *running {
                return;
            }
            *running = true;
        }
        let result = self.suggest_pending_inner().await;
        *self.suggesting.lock().unwrap() = false;
        match result {
            Ok(0) => {}
            Ok(n) => {
                log::info!("suggest: {n} new suggestion(s)");
                self.notify_threads_updated();
            }
            Err(e) => log::warn!("suggest: {e}"),
        }
    }

    /// Returns how many threads got a suggestion (not how many were read).
    async fn suggest_pending_inner(&self) -> Result<usize, EngineError> {
        if !self.suggestions_enabled()? {
            return Ok(0);
        }
        let Some(backend) = self.suggestion_backend()? else {
            return Ok(0);
        };
        let now = now_ms();
        let pending = self
            .store
            .list_threads_needing_suggestion(now - SUGGEST_WINDOW_MS, SUGGEST_BATCH)?;
        let mut n = 0;
        for thread in pending {
            let messages = self.messages_with_bodies(&thread).await?;
            // Thread row landed before its messages (mid-sync race): the
            // next round sees it again.
            let Some(last) = newest_mail(&messages) else {
                continue;
            };
            let answer = backend
                .suggest(
                    thread.subject.clone(),
                    last.from_addr.clone(),
                    body_for_model(last),
                    last.date,
                )
                .await;
            let suggestion = match answer {
                Ok(s) => s.map(Suggestion::from).and_then(|s| sane(s, now)),
                Err(e) => {
                    // Recorded as "nothing to suggest" so one email the model
                    // declines cannot block the queue; the round stops, so a
                    // model that is not ready costs one thread, not five.
                    self.store
                        .set_thread_suggestion(&thread.id, None, thread.msg_count)?;
                    return Err(e);
                }
            };
            self.store
                .set_thread_suggestion(&thread.id, suggestion.as_ref(), thread.msg_count)?;
            if suggestion.is_some() {
                n += 1;
            }
        }
        Ok(n)
    }

    /// The thread's messages, with bodies fetched first when the store has
    /// only Gmail's metadata tier (new mail always is). A failed fetch is
    /// not fatal — the model reads the snippet instead.
    async fn messages_with_bodies(&self, thread: &Thread) -> Result<Vec<Message>, EngineError> {
        let messages = self.store.list_messages(&thread.id)?;
        if !heypigeon_core::sync::needs_bodies(&messages) {
            return Ok(messages);
        }
        let fetched = {
            let provider = self.provider.read().await;
            provider.fetch_bodies(&thread.account_id, &thread.id).await
        };
        match fetched {
            Ok((has_attachment, fetched)) => {
                for m in &fetched {
                    self.store.upsert_message(m)?;
                }
                // Same as `get_thread`: the metadata tier cannot tell, the
                // full fetch can.
                if has_attachment != thread.has_attachment {
                    let mut t = thread.clone();
                    t.has_attachment = has_attachment;
                    self.store.upsert_thread(&t)?;
                }
                Ok(self.store.list_messages(&thread.id)?)
            }
            Err(MailError::AuthExpired) => {
                self.mark_disconnected(&thread.account_id);
                Err(MailError::AuthExpired.into())
            }
            Err(e) => {
                log::warn!("suggest: bodies for {}: {e}", thread.id);
                Ok(messages)
            }
        }
    }
}

/// The newest message that is mail, not one of the user's unsent drafts.
fn newest_mail(messages: &[Message]) -> Option<&Message> {
    messages
        .iter()
        .rev()
        .find(|m| !m.label_ids.iter().any(|l| l == "DRAFT"))
}

/// Plain text, else the snippet, cut to `SUGGEST_BODY_CHARS` on a char
/// boundary.
fn body_for_model(m: &Message) -> String {
    let text = m
        .body_text
        .as_deref()
        .filter(|t| !t.trim().is_empty())
        .unwrap_or(&m.snippet)
        .trim();
    text.chars().take(SUGGEST_BODY_CHARS).collect()
}

/// A reminder in the past or more than a year out is dropped: offering
/// "Remind me yesterday" is worse than offering nothing.
fn sane(s: Suggestion, now: i64) -> Option<Suggestion> {
    match s {
        Suggestion::Remind { at } if at <= now || at > now + SUGGEST_MAX_AHEAD_MS => None,
        s => Some(s),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::fakes::ScriptedBackend;
    use crate::engine::tests_support::sample_thread;
    use heypigeon_core::domain::Account;

    fn open(tag: &str) -> (Arc<Engine>, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "heypigeon-ffi-suggest-{tag}-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let e = Engine::open(
            dir.to_string_lossy().into_owned(),
            OauthClient {
                client_id: "123-abc.apps.googleusercontent.com".into(),
                client_secret: None,
            },
        )
        .unwrap();
        e.store
            .upsert_account(&Account {
                id: "me@x.com".into(),
                email: "me@x.com".into(),
                display_name: "me".into(),
                color: "sky".into(),
                history_id: None,
                avatar_url: None,
                signature: String::new(),
            })
            .unwrap();
        (e, dir)
    }

    /// A new unread thread whose one message has a body (no Gmail fetch).
    fn add_thread(e: &Engine, id: &str, body: &str, at: i64) {
        let mut t = sample_thread(id, "me@x.com");
        t.last_msg_at = at;
        e.store.upsert_thread(&t).unwrap();
        e.store
            .upsert_message(&Message {
                id: format!("{id}-m1"),
                thread_id: id.into(),
                account_id: "me@x.com".into(),
                from_addr: "ana@example.com".into(),
                to_addrs: vec!["me@x.com".into()],
                date: at,
                snippet: body.chars().take(40).collect(),
                body_html: None,
                body_text: Some(body.into()),
                label_ids: vec!["INBOX".into(), "UNREAD".into()],
                is_read: false,
            })
            .unwrap();
    }

    fn backend(answer: Result<Option<ThreadSuggestion>, String>) -> Arc<ScriptedBackend> {
        let b = ScriptedBackend::new(
            "",
            TriageVerdict {
                priority: Priority::Low,
                label_ids: vec![],
            },
        );
        *b.suggestion.lock().unwrap() = answer;
        b
    }

    fn row(e: &Engine, id: &str) -> MailThread {
        e.get_thread_row(id.into()).unwrap().unwrap()
    }

    #[tokio::test]
    async fn new_unread_mail_gets_one_suggestion_and_dismiss_keeps_it_gone() {
        let (e, dir) = open("dismiss");
        add_thread(&e, "t1", "Can you send me the deck by Friday?", now_ms());
        let b = backend(Ok(Some(ThreadSuggestion::NeedsReply)));
        e.set_ai_backend(Some(b.clone()));

        e.suggest_pending().await;
        assert_eq!(
            b.suggestions_asked.lock().unwrap().as_slice(),
            [(
                "Hello".to_string(),
                "Can you send me the deck by Friday?".to_string()
            )]
        );
        assert_eq!(row(&e, "t1").suggestion, Some(ThreadSuggestion::NeedsReply));
        // Proposed, not applied: still in the inbox, not flagged.
        assert!(!row(&e, "t1").needs_reply);
        assert_eq!(
            e.list_threads(ThreadFilter::Inbox, None, None, 10)
                .unwrap()
                .len(),
            1
        );

        // Already analyzed: the next round asks nothing.
        e.suggest_pending().await;
        assert_eq!(b.suggestions_asked.lock().unwrap().len(), 1);

        e.dismiss_suggestion("t1".into()).unwrap();
        assert_eq!(row(&e, "t1").suggestion, None);
        e.suggest_pending().await;
        assert_eq!(b.suggestions_asked.lock().unwrap().len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn accepting_through_the_flag_or_the_reminder_clears_the_suggestion() {
        let (e, dir) = open("accept");
        let now = now_ms();
        add_thread(&e, "t1", "Please confirm", now);
        add_thread(&e, "t2", "Dinner on the 12th at 7pm", now - 1);
        let at = now + 3 * 86_400_000;
        let b = backend(Ok(Some(ThreadSuggestion::Remind { at })));
        e.set_ai_backend(Some(b.clone()));
        e.suggest_pending().await;
        assert_eq!(
            row(&e, "t2").suggestion,
            Some(ThreadSuggestion::Remind { at })
        );

        Arc::clone(&e).set_needs_reply("t1".into(), true).unwrap();
        assert_eq!(row(&e, "t1").suggestion, None);
        Arc::clone(&e)
            .set_schedule("t2".into(), Some(at), false)
            .unwrap();
        let t2 = row(&e, "t2");
        assert_eq!((t2.suggestion, t2.scheduled_at), (None, Some(at)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn old_read_or_switched_off_mail_is_never_sent_to_the_model() {
        let (e, dir) = open("skip");
        let now = now_ms();
        add_thread(&e, "old", "Last month's note", now - 10 * 86_400_000);
        add_thread(&e, "read", "Already seen", now);
        let mut read = e.store.get_thread(&"read".to_string()).unwrap().unwrap();
        read.is_read = true;
        e.store.upsert_thread(&read).unwrap();
        let b = backend(Ok(Some(ThreadSuggestion::NeedsReply)));
        e.set_ai_backend(Some(b.clone()));
        e.suggest_pending().await;
        assert!(b.suggestions_asked.lock().unwrap().is_empty());

        add_thread(&e, "new", "Are you coming?", now);
        e.set_pref("ai.suggest".into(), Some("false".into()))
            .unwrap();
        e.suggest_pending().await;
        assert!(b.suggestions_asked.lock().unwrap().is_empty());
        e.set_pref("ai.suggest".into(), Some("true".into()))
            .unwrap();
        e.suggest_pending().await;
        assert_eq!(b.suggestions_asked.lock().unwrap().len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_model_error_or_a_past_date_leaves_no_suggestion_and_no_retry_loop() {
        let (e, dir) = open("error");
        let now = now_ms();
        add_thread(&e, "t1", "Something the model declines", now);
        add_thread(&e, "t2", "Yesterday's party", now - 1);
        let b = backend(Err("The model declined this content.".into()));
        e.set_ai_backend(Some(b.clone()));
        e.suggest_pending().await;
        // The round stopped at the first error; that thread is settled.
        assert_eq!(b.suggestions_asked.lock().unwrap().len(), 1);
        assert_eq!(row(&e, "t1").suggestion, None);

        *b.suggestion.lock().unwrap() = Ok(Some(ThreadSuggestion::Remind {
            at: now - 86_400_000,
        }));
        e.suggest_pending().await;
        assert_eq!(b.suggestions_asked.lock().unwrap().len(), 2);
        assert_eq!(row(&e, "t2").suggestion, None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn without_a_shell_backend_nothing_runs() {
        let (e, dir) = open("nobackend");
        add_thread(&e, "t1", "Are you free?", now_ms());
        e.suggest_pending().await;
        assert_eq!(row(&e, "t1").suggestion, None);
        // Not marked as analyzed either: a device that gains Apple
        // Intelligence later still gets the proposal.
        let b = backend(Ok(Some(ThreadSuggestion::NeedsReply)));
        e.set_ai_backend(Some(b.clone()));
        e.suggest_pending().await;
        assert_eq!(row(&e, "t1").suggestion, Some(ThreadSuggestion::NeedsReply));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn reminders_outside_the_next_year_are_dropped() {
        let now = 1_000_000_000_000;
        assert_eq!(
            sane(Suggestion::NeedsReply, now),
            Some(Suggestion::NeedsReply)
        );
        assert_eq!(sane(Suggestion::Remind { at: now - 1 }, now), None);
        assert_eq!(sane(Suggestion::Remind { at: now }, now), None);
        let next_week = now + 7 * 86_400_000;
        assert_eq!(
            sane(Suggestion::Remind { at: next_week }, now),
            Some(Suggestion::Remind { at: next_week })
        );
        assert_eq!(
            sane(
                Suggestion::Remind {
                    at: now + SUGGEST_MAX_AHEAD_MS + 1
                },
                now
            ),
            None
        );
    }
}
