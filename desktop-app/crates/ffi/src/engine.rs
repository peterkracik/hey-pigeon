//! The `Engine` object the Swift shell holds for the app's lifetime.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use heypigeon_adapter_gmail::oauth::{self, AuthRequest, ClientConfig};
use heypigeon_adapter_gmail::GmailProvider;
use heypigeon_adapter_sqlite::SqliteStore;
use heypigeon_core::domain::{self, now_ms, AccountId, AttachmentRef, ThreadId};
use heypigeon_core::ports::{
    MailError, MailProvider, SecretStore, Store, SyncError as TransportError,
};
use heypigeon_core::{devsync, outbox, sync};
use tokio::sync::RwLock;

use crate::ai::AiBackend;
use crate::secrets::default_secret_store;
use crate::types::*;

/// Backfill window on first sync (DESIGN.md: 90 days first, older later —
/// the desktop shell uses 30 today; the phone follows it).
pub(crate) const BACKFILL_DAYS: u32 = 30;
/// Archive-walk pages (100 threads each) per `backfill_older` call.
const OLDER_PAGES_PER_CALL: usize = 1;
/// Minimum gap between archive-walk pages for one account. A page costs
/// about 1,010 Gmail quota units (threads.list + 100 threads.get), and the
/// per-user limit can be as low as 6,000 units a minute: back to back, the
/// walk spent all of it and opening a thread failed with 403
/// rateLimitExceeded. One page per 20 s keeps the walk near half the
/// quota, leaving the rest for the delta sync and thread opens.
const OLDER_PAGE_GAP: Duration = Duration::from_secs(20);
/// How long the walk stays off an account after Gmail rate-limited it.
const OLDER_RATE_LIMIT_PAUSE: Duration = Duration::from_secs(60);
/// Outbox rows per page of a drain.
const DRAIN_BATCH: u32 = 20;
/// How long a reply waits for Gmail to name the message it answers (its
/// Message-ID, when the store does not have it) before going out without.
const REPLY_HEADERS_WAIT: Duration = Duration::from_secs(5);
/// Threads whose attachment list is remembered (`Engine::attachments`).
const ATTACHMENT_LISTS_MAX: usize = 200;
const KEYCHAIN_SERVICE: &str = "app.heypigeon";
pub(crate) const ACCOUNT_COLORS: &[&str] = &["sky", "lavender", "mint", "amber", "coral"];

/// Change notifications, implemented on the Swift side. Called from engine
/// threads — hop to the main actor before touching UI.
#[uniffi::export(with_foreign)]
pub trait EngineListener: Send + Sync {
    /// Thread rows changed (sync applied something, a mutation was queued,
    /// a reminder moved). Re-query whatever is on screen.
    fn on_threads_updated(&self);
    /// Fires once per transition of an account into the disconnected state.
    fn on_account_disconnected(&self, account_id: String);
    /// A sync round applied settings written on another device: account
    /// name/colour/signature, triage labels, prefs (`get_prefs`), the AI
    /// model or the triage switch. Re-read them. Never fires for this
    /// device's own edits, so it cannot race the optimistic UI.
    fn on_prefs_updated(&self);
    /// The analysis pass moved: a round started, an email was classified,
    /// or the pass paused between rounds or finished (`AnalysisPass`).
    /// Fires per email, so keep the handler cheap — it is not a reload.
    fn on_analysis_progress(&self, progress: AnalysisPass);
}

#[derive(Default)]
struct SyncStatusEntry {
    state: SyncState,
    detail: Option<String>,
}

impl Default for SyncState {
    fn default() -> Self {
        SyncState::Pending
    }
}

#[derive(uniffi::Object)]
pub struct Engine {
    pub(crate) store: SqliteStore,
    pub(crate) secrets: Arc<dyn SecretStore + Send + Sync>,
    /// Where the database and the attachment cache live.
    data_dir: PathBuf,
    oauth_client: ClientConfig,
    pub(crate) provider: RwLock<GmailProvider>,
    pending_oauth: Mutex<Option<AuthRequest>>,
    listener: Mutex<Option<Arc<dyn EngineListener>>>,
    /// Accounts with a delta sync in flight (foreground + background can overlap).
    syncing: Mutex<HashSet<AccountId>>,
    /// account → when the archive walk may fetch its next page
    /// (`OLDER_PAGE_GAP`, `OLDER_RATE_LIMIT_PAUSE`).
    older_due: Mutex<HashMap<AccountId, Instant>>,
    /// Accounts whose Google grant no longer works (edge-triggered).
    disconnected: Mutex<HashSet<AccountId>>,
    sync_status: Mutex<HashMap<AccountId, SyncStatusEntry>>,
    /// Guards Jev classification from overlapping runs (settings.rs).
    pub(crate) classifying: Mutex<bool>,
    /// Guards the AI suggestion pass from overlapping runs (suggest.rs).
    pub(crate) suggesting: Mutex<bool>,
    /// Guards the AI bundling pass from overlapping runs (bundles.rs).
    pub(crate) bundling: Mutex<bool>,
    /// Last Jev failure; None after a clean run (settings.rs).
    pub(crate) triage_last_error: Mutex<Option<String>>,
    /// Where the current analysis pass is (settings.rs, `classify_pending`).
    pub(crate) analysis: Mutex<AnalysisPass>,
    /// The shell's AI backends, one per provider it can offer on this device
    /// ("apple" on-device, "apple-cloud" Private Cloud Compute, …), in
    /// registration order (ai.rs).
    pub(crate) ai_backends: Mutex<Vec<Arc<dyn AiBackend>>>,
    /// One outbox drain at a time. Two at once read the same rows and
    /// applied each twice — every `mutate` drained, and so did every sync
    /// round — which for a queued send meant the mail went out twice.
    drain_lock: tokio::sync::Mutex<()>,
    /// A background drain is already waiting for its turn: the mutations
    /// queued meanwhile are covered by it (a bulk action is one drain, not
    /// one per thread).
    drain_queued: AtomicBool,
    /// Why each outbox row that is still queued failed last time, for the
    /// caller that waits on a send: (account disconnected, message).
    drain_failures: Mutex<HashMap<i64, (bool, String)>>,
    /// thread → (its message count, its attachments), from the full fetch
    /// that brought its bodies. `list_attachments` used to download the
    /// whole thread a second time on every open to answer this.
    attachments: Mutex<HashMap<ThreadId, (i64, Vec<AttachmentRef>)>>,
    /// The people the stored mail is from and to, ranked, for recipient
    /// suggestions (contacts.rs).
    pub(crate) correspondents: Mutex<Option<crate::contacts::Correspondents>>,
}

#[uniffi::export(async_runtime = "tokio")]
impl Engine {
    /// Open (or create) the local database under `data_dir` and wire the
    /// Gmail provider for `oauth`. Cheap: no network. Accounts whose refresh
    /// token is missing from the secret store start out disconnected.
    #[uniffi::constructor]
    pub fn open(data_dir: String, oauth: OauthClient) -> Result<Arc<Self>, EngineError> {
        let data_dir = PathBuf::from(data_dir);
        std::fs::create_dir_all(&data_dir).map_err(|e| EngineError::Store(e.to_string()))?;
        let store = SqliteStore::open(&data_dir.join("heypigeon.db"))?;
        let secrets: Arc<dyn SecretStore + Send + Sync> =
            Arc::from(default_secret_store(KEYCHAIN_SERVICE, &data_dir)?);
        let oauth_client = ClientConfig {
            client_id: oauth.client_id,
            client_secret: oauth.client_secret,
        };
        let provider = GmailProvider::new(oauth_client.clone(), Arc::clone(&secrets));
        crate::settings::migrate_legacy_prefs(&store, &*secrets);

        let disconnected: HashSet<AccountId> = store
            .list_accounts()?
            .into_iter()
            // Only a token that is really absent means disconnected. A read
            // that fails — the Keychain refuses while the iPhone is locked,
            // which is exactly when background refresh and push launch the
            // app — says nothing about the account, and marking it here
            // showed the user as signed out until the next launch.
            .filter(
                |a| match secrets.get(&heypigeon_adapter_gmail::refresh_token_key(&a.id)) {
                    Ok(Some(_)) => false,
                    Ok(None) => true,
                    Err(e) => {
                        log::warn!(
                            "refresh token for {} unreadable ({e}); not marking it disconnected",
                            a.id
                        );
                        false
                    }
                },
            )
            .map(|a| a.id)
            .collect();
        for id in &disconnected {
            log::warn!("account {id} has no stored refresh token; marked disconnected");
        }

        Ok(Arc::new(Self {
            store,
            secrets,
            data_dir,
            oauth_client,
            provider: RwLock::new(provider),
            pending_oauth: Mutex::new(None),
            listener: Mutex::new(None),
            syncing: Mutex::new(HashSet::new()),
            older_due: Mutex::new(HashMap::new()),
            disconnected: Mutex::new(disconnected),
            sync_status: Mutex::new(HashMap::new()),
            classifying: Mutex::new(false),
            suggesting: Mutex::new(false),
            bundling: Mutex::new(false),
            triage_last_error: Mutex::new(None),
            analysis: Mutex::new(AnalysisPass::default()),
            ai_backends: Mutex::new(Vec::new()),
            drain_lock: tokio::sync::Mutex::new(()),
            drain_queued: AtomicBool::new(false),
            drain_failures: Mutex::new(HashMap::new()),
            attachments: Mutex::new(HashMap::new()),
            correspondents: Mutex::new(None),
        }))
    }

    pub fn set_listener(&self, listener: Option<Arc<dyn EngineListener>>) {
        *self.listener.lock().unwrap() = listener;
    }

    /// The shell's on-device AI (Apple Intelligence), or `None` on a device
    /// without one. With a backend set, AI and triage need no key:
    /// `ai_status` / `triage_status` say which provider answers. `None`
    /// forgets every registered backend; `add_ai_backend` registers more
    /// than one (the Private Cloud Compute model next to the on-device one).
    pub fn set_ai_backend(&self, backend: Option<Arc<dyn AiBackend>>) {
        match backend {
            Some(b) => self.add_ai_backend(b),
            None => self.ai_backends.lock().unwrap().clear(),
        }
    }

    /// Register (or replace, by `id()`) one shell backend. Order of first
    /// registration is the order `ai_status` lists them in.
    pub fn add_ai_backend(&self, backend: Arc<dyn AiBackend>) {
        let id = backend.id();
        let mut backends = self.ai_backends.lock().unwrap();
        if let Some(slot) = backends.iter_mut().find(|b| b.id() == id) {
            *slot = backend;
        } else {
            backends.push(backend);
        }
    }

    /// Forget one backend (the device lost the model, or the user turned
    /// the provider off in Settings).
    pub fn remove_ai_backend(&self, provider_id: String) {
        self.ai_backends
            .lock()
            .unwrap()
            .retain(|b| b.id() != provider_id);
    }

    // ------------------------------------------------------------ reads

    pub fn list_accounts(&self) -> Result<Vec<Account>, EngineError> {
        Ok(self
            .store
            .list_accounts()?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Newest first, keyset-paginated: pass the last row's `last_msg_at` as
    /// `before` for the next page. `account_id` None = unified inbox.
    pub fn list_threads(
        &self,
        filter: ThreadFilter,
        account_id: Option<String>,
        before: Option<i64>,
        limit: u32,
    ) -> Result<Vec<MailThread>, EngineError> {
        Ok(self
            .store
            .list_threads(account_id.as_ref(), &filter.into(), before, limit)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Stored user labels across all accounts, name-sorted.
    pub fn list_labels(&self) -> Result<Vec<MailLabel>, EngineError> {
        Ok(self
            .store
            .list_labels()?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn list_triage_labels(&self) -> Result<Vec<TriageLabel>, EngineError> {
        Ok(self
            .store
            .list_triage_labels()?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Unread thread count per view key: the folder names of `ThreadFilter`
    /// in lowercase (`inbox`, `starred`, …) plus `label:<id>`. One pass over
    /// the unread rows in the store (`Store::unread_counts`).
    pub fn unread_counts(
        &self,
        account_id: Option<String>,
    ) -> Result<HashMap<String, i64>, EngineError> {
        Ok(self.store.unread_counts(account_id.as_ref())?)
    }

    /// Every scheduled ("remind me") thread still in the inbox, past the
    /// inbox page window too — the Scheduled view, and the source for
    /// local reminder notifications.
    pub fn list_scheduled(&self) -> Result<Vec<MailThread>, EngineError> {
        Ok(self
            .store
            .list_scheduled()?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Every "needs reply" thread still in the inbox, past the inbox page
    /// window too.
    pub fn list_needs_reply(&self) -> Result<Vec<MailThread>, EngineError> {
        Ok(self
            .store
            .list_needs_reply()?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Local FTS5 search (Gmail-style operators + bare text), ranked.
    pub fn search(&self, query: String, limit: u32) -> Result<Vec<SearchHit>, EngineError> {
        let parsed = heypigeon_core::search::parse(&query);
        Ok(self
            .store
            .search(&parsed, limit)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// One thread's row from the store, no network: the open thread view
    /// re-reads it on every change, whichever list it was opened from.
    pub fn get_thread_row(&self, thread_id: String) -> Result<Option<MailThread>, EngineError> {
        Ok(self.store.get_thread(&thread_id)?.map(Into::into))
    }

    /// Thread + messages. Bodies are fetched from Gmail on first open (the
    /// only network read in the UI path) and cached; later opens are local.
    /// "Fetched" is a per-message flag, so a message with no text at all
    /// is not fetched again, and a reply that landed in a thread read
    /// before fetches alone, not the whole thread.
    pub async fn get_thread(
        &self,
        thread_id: String,
    ) -> Result<Option<ThreadWithMessages>, EngineError> {
        let Some(mut thread) = self.store.get_thread(&thread_id)? else {
            return Ok(None);
        };
        let meta = self.store.list_message_meta(&thread_id)?;
        if heypigeon_core::sync::needs_bodies(&meta) {
            match self.fetch_bodies_into_store(&thread, &meta).await {
                Ok(has_attachment) => thread.has_attachment = has_attachment,
                Err(MailError::AuthExpired) => {
                    self.mark_disconnected(&thread.account_id);
                    return Err(MailError::AuthExpired.into());
                }
                Err(e) => return Err(e.into()),
            }
        }
        let messages = self.store.list_messages(&thread_id)?;
        Ok(Some(ThreadWithMessages {
            thread: thread.into(),
            messages: messages.into_iter().map(Into::into).collect(),
        }))
    }

    /// Thread + whatever messages the store holds, no network: bodies are
    /// there only for threads opened before (or synced in full). The
    /// Spotlight indexer and the message entities read through here so
    /// indexing a mailbox never costs a fetch per thread.
    pub fn get_thread_local(
        &self,
        thread_id: String,
    ) -> Result<Option<ThreadWithMessages>, EngineError> {
        let Some(thread) = self.store.get_thread(&thread_id)? else {
            return Ok(None);
        };
        let messages = self.store.list_messages(&thread_id)?;
        Ok(Some(ThreadWithMessages {
            thread: thread.into(),
            messages: messages.into_iter().map(Into::into).collect(),
        }))
    }

    /// The thread's attachments (filename, type, size, where to fetch).
    /// Answered from memory when the thread's bodies were fetched this
    /// session (the same response lists them); one network read otherwise.
    pub async fn list_attachments(
        &self,
        thread_id: String,
    ) -> Result<Vec<MailAttachment>, EngineError> {
        let Some(thread) = self.store.get_thread(&thread_id)? else {
            return Ok(Vec::new());
        };
        let refs = match self.remembered_attachments(&thread_id, thread.msg_count) {
            Some(refs) => refs,
            None => {
                let fetched = {
                    let provider = self.provider.read().await;
                    provider
                        .list_attachments(&thread.account_id, &thread_id)
                        .await
                };
                let refs = match fetched {
                    Ok(v) => v,
                    Err(MailError::AuthExpired) => {
                        self.mark_disconnected(&thread.account_id);
                        return Err(MailError::AuthExpired.into());
                    }
                    Err(e) => return Err(e.into()),
                };
                self.remember_attachments(&thread_id, thread.msg_count, refs.clone());
                refs
            }
        };
        Ok(refs
            .into_iter()
            .map(|a| MailAttachment {
                thread_id: thread_id.clone(),
                message_id: a.message_id,
                attachment_id: a.attachment_id,
                filename: a.filename,
                mime_type: a.mime_type,
                size: a.size,
                content_id: a.content_id,
            })
            .collect())
    }

    /// One attachment's bytes as a file under the data directory
    /// (`attachments/<hash>/<filename>`), fetched once and reused: the path
    /// is what Quick Look and the on-device model read. Never auto-fetched.
    pub async fn fetch_attachment(
        &self,
        attachment: MailAttachment,
    ) -> Result<String, EngineError> {
        let dir = self
            .data_dir
            .join("attachments")
            .join(attachment_cache_key(&attachment));
        let safe_name = safe_filename(&attachment.filename);
        let path = dir.join(&safe_name);
        if path.is_file() {
            return Ok(path.to_string_lossy().into_owned());
        }
        let Some(thread) = self.store.get_thread(&attachment.thread_id)? else {
            return Err(EngineError::Invalid(format!(
                "unknown thread {}",
                attachment.thread_id
            )));
        };
        let reference = domain::AttachmentRef {
            message_id: attachment.message_id.clone(),
            attachment_id: attachment.attachment_id.clone(),
            filename: attachment.filename.clone(),
            mime_type: attachment.mime_type.clone(),
            size: attachment.size,
            content_id: attachment.content_id.clone(),
        };
        let fetched = {
            let provider = self.provider.read().await;
            provider
                .fetch_attachment(&thread.account_id, &reference)
                .await
        };
        let bytes = match fetched {
            Ok(b) => b,
            Err(MailError::AuthExpired) => {
                self.mark_disconnected(&thread.account_id);
                return Err(MailError::AuthExpired.into());
            }
            Err(e) => return Err(e.into()),
        };
        std::fs::create_dir_all(&dir).map_err(|e| EngineError::Store(e.to_string()))?;
        std::fs::write(&path, bytes).map_err(|e| EngineError::Store(e.to_string()))?;
        Ok(path.to_string_lossy().into_owned())
    }

    /// Drop the attachment cache (Settings, or an account removal).
    pub fn clear_attachment_cache(&self) -> Result<(), EngineError> {
        let dir = self.data_dir.join("attachments");
        if dir.is_dir() {
            std::fs::remove_dir_all(&dir).map_err(|e| EngineError::Store(e.to_string()))?;
        }
        Ok(())
    }

    /// The thread's Gmail draft (its newest DRAFT message), fetched from
    /// Gmail for the composer. None when the thread holds no draft.
    pub async fn load_draft(&self, thread_id: String) -> Result<Option<DraftContent>, EngineError> {
        let Some(thread) = self.store.get_thread(&thread_id)? else {
            return Ok(None);
        };
        let messages = self.store.list_message_meta(&thread_id)?;
        let is_draft = |m: &domain::Message| m.label_ids.iter().any(|l| l == "DRAFT");
        let Some(message) = messages.iter().rev().find(|m| is_draft(m)) else {
            return Ok(None);
        };
        let fetched = {
            let provider = self.provider.read().await;
            provider.get_draft(&thread.account_id, &message.id).await
        };
        let d = match fetched {
            Ok(d) => d,
            Err(MailError::AuthExpired) => {
                self.mark_disconnected(&thread.account_id);
                return Err(MailError::AuthExpired.into());
            }
            Err(e) => return Err(e.into()),
        };
        // A reply draft sits in the thread it answers; a new message is alone.
        let reply_to_thread = messages
            .iter()
            .any(|m| !is_draft(m))
            .then(|| thread_id.clone());
        Ok(Some(DraftContent {
            message_id: d.message_id,
            account_id: thread.account_id,
            to: d.to,
            cc: d.cc,
            bcc: d.bcc,
            subject: d.subject,
            body_text: d.body_text,
            body_html: d.body_html,
            attachments: d.attachments.into_iter().map(Into::into).collect(),
            reply_to_thread,
        }))
    }

    // ------------------------------------------------------------ writes

    /// Apply a mutation locally now (the row changes before this returns)
    /// and queue it for Gmail.
    ///
    /// A change to a thread (archive, read, trash, star, label, spam…)
    /// returns here: Gmail hears of it from a background drain, and a
    /// failure stays queued for the next one (`pending_mutations`).
    ///
    /// Outgoing mail and drafts (`Send`, `SaveDraft`, `DeleteDraft`) wait
    /// for Gmail's answer: `Ok` means Gmail took it. An error means this
    /// attempt failed — the row stays queued and later drains retry it
    /// (a send made offline goes out when the network is back), unless
    /// Gmail itself keeps refusing it (`failed_mutations`).
    /// `EngineError::AuthExpired` when the account needs reconnecting.
    pub async fn mutate(
        self: Arc<Self>,
        account_id: String,
        mutation: Mutation,
    ) -> Result<(), EngineError> {
        let mutation: domain::Mutation = mutation.into();
        let outgoing = mutation.is_outgoing();
        if outgoing {
            self.find_reply_headers(&account_id, &mutation).await;
        }
        // Done/delete also clears the reminder and "needs reply" flag.
        let (row, cleared) = outbox::enqueue_item(&self.store, &account_id, mutation)?;
        if cleared {
            self.push_devsync_later(account_id.clone());
        }
        self.notify_threads_updated();
        if !outgoing {
            self.drain_soon();
            return Ok(());
        }
        self.drain_outbox().await?;
        if !self.store.outbox_contains(row)? {
            return Ok(());
        }
        Err(match self.drain_failures.lock().unwrap().get(&row) {
            Some((true, why)) => EngineError::AuthExpired(why.clone()),
            Some((false, why)) => EngineError::Mail(format!("{why} (queued, will retry)")),
            None => EngineError::Mail("not sent yet (queued, will retry)".into()),
        })
    }

    /// Outbox rows still waiting for Gmail: changes made offline, or that
    /// failed and will be retried. 0 when everything is through — the
    /// shell's "changes waiting to sync" indicator.
    pub fn pending_mutations(&self) -> u32 {
        self.store
            .outbox_counts(outbox::MAX_ATTEMPTS)
            .map(|(waiting, _)| waiting)
            .unwrap_or(0)
    }

    /// Outbox rows Gmail refused `outbox::MAX_ATTEMPTS` times (a thread
    /// deleted elsewhere, a label that is gone): kept, no longer retried.
    pub fn failed_mutations(&self) -> u32 {
        self.store
            .outbox_counts(outbox::MAX_ATTEMPTS)
            .map(|(_, parked)| parked)
            .unwrap_or(0)
    }

    /// Set/clear the local "remind me" schedule (epoch ms; None clears).
    /// `follow_up` = "only if no reply": the schedule clears itself once
    /// someone else writes in the thread. Pushed to the other devices right
    /// away in the background.
    pub fn set_schedule(
        self: Arc<Self>,
        thread_id: String,
        scheduled_at: Option<i64>,
        follow_up: bool,
    ) -> Result<(), EngineError> {
        let thread = self
            .store
            .get_thread(&thread_id)?
            .ok_or_else(|| EngineError::Invalid(format!("unknown thread {thread_id}")))?;
        self.store.set_schedule(&thread_id, scheduled_at)?;
        // A reminder settles the question the AI suggestion asked (this is
        // also how accepting a "Remind me" proposal clears it).
        if scheduled_at.is_some() {
            self.store.clear_thread_suggestion(&thread_id)?;
        }
        devsync::record_reminder(&self.store, &thread.account_id, &thread_id, scheduled_at)?;
        let follow_up_since = match (scheduled_at, follow_up) {
            (Some(_), true) => Some(now_ms()),
            _ => None,
        };
        if follow_up_since != thread.follow_up_since {
            self.store.set_follow_up(&thread_id, follow_up_since)?;
            devsync::record_follow_up(
                &self.store,
                &thread.account_id,
                &thread_id,
                follow_up_since,
            )?;
        }
        self.notify_threads_updated();
        self.push_devsync_later(thread.account_id);
        Ok(())
    }

    /// Set/clear the local "needs reply" flag. Pushed to the other devices
    /// right away in the background.
    pub fn set_needs_reply(
        self: Arc<Self>,
        thread_id: String,
        needs_reply: bool,
    ) -> Result<(), EngineError> {
        let thread = self
            .store
            .get_thread(&thread_id)?
            .ok_or_else(|| EngineError::Invalid(format!("unknown thread {thread_id}")))?;
        self.store.set_needs_reply(&thread_id, needs_reply)?;
        // Same as a reminder: flagging it answers the AI suggestion.
        if needs_reply {
            self.store.clear_thread_suggestion(&thread_id)?;
        }
        devsync::record_needs_reply(&self.store, &thread.account_id, &thread_id, needs_reply)?;
        self.notify_threads_updated();
        self.push_devsync_later(thread.account_id);
        Ok(())
    }

    /// App-wide preferences (pinned list, swipe actions, auto-summarize…)
    /// as `name → JSON text`. The store is the truth and the values travel
    /// between the user's devices (`pref:<name>` keys on the first
    /// account's file); the shell keeps nothing of its own beyond a
    /// one-time migration of what it stored before. Missing = never set.
    pub fn get_prefs(&self) -> Result<HashMap<String, String>, EngineError> {
        self.store
            .list_prefs()?
            .into_iter()
            .map(|(name, value)| {
                serde_json::to_string(&value)
                    .map(|v| (name, v))
                    .map_err(|e| EngineError::Store(e.to_string()))
            })
            .collect()
    }

    /// Set (`value_json` = JSON text) or clear (`None`) one preference and
    /// push it to the user's other devices. Never a secret: API keys and
    /// tokens stay in this device's keychain.
    pub fn set_pref(
        self: &Arc<Self>,
        name: String,
        value_json: Option<String>,
    ) -> Result<(), EngineError> {
        let name = name.trim().to_string();
        if name.is_empty() || name.contains(':') {
            return Err(EngineError::Invalid(format!("invalid pref name {name:?}")));
        }
        let value: Option<serde_json::Value> = value_json
            .map(|v| serde_json::from_str::<serde_json::Value>(&v))
            .transpose()
            .map_err(|e| EngineError::Invalid(format!("pref {name} is not JSON: {e}")))?
            .filter(|v| !v.is_null());
        self.store.set_pref(&name, value.as_ref())?;
        devsync::record_pref(&self.store, &name, value)?;
        self.push_app_wide_later();
        Ok(())
    }

    /// Forget an account: its rows, its labels and its refresh token. If
    /// push is on, the relay registration and the Gmail watch go first
    /// (best effort — the lease expires on its own within 7 days anyway).
    pub async fn remove_account(&self, account_id: String) -> Result<(), EngineError> {
        self.forget_push_for_account(&account_id).await;
        self.store.delete_account(&account_id)?;
        let _ = self
            .secrets
            .delete(&heypigeon_adapter_gmail::refresh_token_key(&account_id));
        self.disconnected.lock().unwrap().remove(&account_id);
        self.sync_status.lock().unwrap().remove(&account_id);
        self.notify_threads_updated();
        Ok(())
    }

    // ------------------------------------------------------------ sync

    /// One delta round for every account (backfill on first contact), then
    /// an outbox drain. Returns whether anything changed locally. The shell
    /// calls this on launch, on foreground, on pull-to-refresh and from
    /// background refresh; one failing account never blocks another.
    ///
    /// The round runs as a task on the engine's runtime, accounts side by
    /// side, not on the thread that awaits it: its database writes and
    /// JSON parsing used to occupy one of the caller's (Swift's) few
    /// cooperative threads. It also finishes if the caller stops waiting.
    pub async fn sync_all(self: Arc<Self>) -> Result<bool, EngineError> {
        on_runtime(async move { self.sync_all_round().await }).await?
    }

    /// Delta round for one account only (pull-to-refresh in a filtered view).
    pub async fn sync_now(self: Arc<Self>, account_id: String) -> Result<bool, EngineError> {
        on_runtime(async move {
            let changed = self.sync_account(&account_id).await;
            if changed {
                self.notify_threads_updated();
            }
            changed
        })
        .await
    }

    /// One step of the archive walk: mail older than the backfill window,
    /// a page per account, checkpointed so it resumes across launches
    /// (DESIGN.md "Progressive backfill"). Returns whether any account has
    /// more to fetch — the shell keeps calling while that is true and the
    /// app is in front. Never fires `on_threads_updated`: old mail lands
    /// below the newest page, so the shell appends it instead of resetting
    /// a scrolled list. An account mid-sync is skipped (still "more"); one
    /// that fails is skipped until the next call, so a network error ends
    /// the shell's loop instead of spinning it. Pages are paced to Gmail's
    /// quota (`OLDER_PAGE_GAP`): the call sleeps until an account is due,
    /// and a rate-limited account is paused, not dropped from the walk.
    pub async fn backfill_older(self: Arc<Self>) -> Result<bool, EngineError> {
        on_runtime(async move { self.backfill_older_step().await }).await?
    }
}

/// Run `task` on the engine's runtime and wait for it. An exported async
/// function is polled by the caller's executor — Swift's cooperative pool,
/// a handful of threads the whole app shares — so whatever it does between
/// awaits (database writes, parsing) runs there. The long passes move.
async fn on_runtime<T: Send + 'static>(
    task: impl std::future::Future<Output = T> + Send + 'static,
) -> Result<T, EngineError> {
    tokio::spawn(task)
        .await
        .map_err(|e| EngineError::Store(format!("engine task failed: {e}")))
}

// Internals — not exported.
impl Engine {
    async fn sync_all_round(self: Arc<Self>) -> Result<bool, EngineError> {
        let accounts = self.store.list_accounts()?;
        // One task per account: two accounts' rounds are two sets of
        // network waits, and ran one after the other.
        let rounds: Vec<_> = accounts
            .into_iter()
            .map(|a| {
                let engine = Arc::clone(&self);
                tokio::spawn(async move { engine.sync_account(&a.id).await })
            })
            .collect();
        let mut changed = false;
        for round in rounds {
            changed |= round.await.unwrap_or(false);
        }
        if let Err(e) = self.drain_outbox().await {
            log::warn!("outbox drain after sync failed: {e}");
        }
        if changed {
            self.notify_threads_updated();
        }
        // Bundles: link new mail by shared booking, order and tracking
        // numbers. Local, but hundreds of threads' worth of reading and
        // scanning after a backfill: on the blocking pool, not a worker.
        let engine = Arc::clone(&self);
        let _ = tokio::task::spawn_blocking(move || engine.link_bundles_pending()).await;
        // Jev triage rides the sync cadence, never its own timer (desktop
        // does the same at the end of its poll tick).
        self.classify_pending().await;
        // Then the "Need reply" / "Remind me" proposals for new unread
        // mail, on the same cadence (suggest.rs).
        self.suggest_pending().await;
        // Then the model groups new mail into bundles (bundles.rs).
        self.bundle_pending().await;
        Ok(changed)
    }

    async fn backfill_older_step(&self) -> Result<bool, EngineError> {
        // Pace the walk to Gmail's per-minute quota: wait for the first
        // account that is due, then fetch for every account that is.
        let accounts = self.store.list_accounts()?;
        let next_due = {
            let due = self.older_due.lock().unwrap();
            accounts
                .iter()
                .filter_map(|a| due.get(&a.id).copied())
                .min()
        };
        if let Some(at) = next_due {
            let now = Instant::now();
            if at > now {
                tokio::time::sleep(at - now).await;
            }
        }
        let mut more = false;
        for a in accounts {
            if self.disconnected.lock().unwrap().contains(&a.id) {
                continue;
            }
            let due = self.older_due.lock().unwrap().get(&a.id).copied();
            if due.is_some_and(|at| at > Instant::now()) {
                more = true;
                continue;
            }
            if !self.syncing.lock().unwrap().insert(a.id.clone()) {
                more = true;
                continue;
            }
            let result = {
                let provider = self.provider.read().await;
                sync::backfill_older(
                    &*provider,
                    &self.store,
                    &a.id,
                    BACKFILL_DAYS,
                    OLDER_PAGES_PER_CALL,
                )
                .await
            };
            self.syncing.lock().unwrap().remove(&a.id);
            let gap = match result {
                Ok((_, done)) => {
                    more |= !done;
                    OLDER_PAGE_GAP
                }
                Err(sync::SyncError::Mail(MailError::AuthExpired)) => {
                    self.mark_disconnected(&a.id);
                    OLDER_PAGE_GAP
                }
                // Quota, not a failure: pause this account and keep the
                // walk going, instead of ending it until the next launch.
                Err(sync::SyncError::Mail(MailError::RateLimited { .. })) => {
                    log::info!("backfill_older({}) rate limited, pausing", a.id);
                    more = true;
                    OLDER_RATE_LIMIT_PAUSE
                }
                Err(e) => {
                    log::warn!("backfill_older({}) failed: {e}", a.id);
                    OLDER_PAGE_GAP
                }
            };
            self.older_due
                .lock()
                .unwrap()
                .insert(a.id.clone(), Instant::now() + gap);
        }
        Ok(more)
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl Engine {
    /// Connection + cross-device sync state for every stored account.
    pub fn account_status(&self) -> Result<Vec<AccountStatus>, EngineError> {
        let disconnected = self.disconnected.lock().unwrap();
        let statuses = self.sync_status.lock().unwrap();
        Ok(self
            .store
            .list_accounts()?
            .into_iter()
            .map(|a| {
                let s = statuses.get(&a.id);
                AccountStatus {
                    connection: if disconnected.contains(&a.id) {
                        ConnectionState::Disconnected
                    } else {
                        ConnectionState::Connected
                    },
                    sync: s.map(|s| s.state).unwrap_or_default(),
                    sync_detail: s.and_then(|s| s.detail.clone()),
                    last_sync_at: devsync::last_sync_at(&self.store, &a.id).unwrap_or(None),
                    account_id: a.id,
                }
            })
            .collect())
    }

    // ------------------------------------------------------------ oauth

    /// Start a consent flow. `redirect_uri` None = the iOS reversed-client-id
    /// scheme for this client. `login_hint` pre-selects a known account on
    /// Google's side when reconnecting. Only one flow is pending at a time;
    /// starting another replaces it.
    pub fn begin_oauth(
        &self,
        login_hint: Option<String>,
        redirect_uri: Option<String>,
    ) -> Result<OauthSession, EngineError> {
        let redirect_uri =
            redirect_uri.unwrap_or_else(|| oauth::ios_redirect_uri(&self.oauth_client.client_id));
        let request = AuthRequest::begin(&self.oauth_client, login_hint.as_deref(), &redirect_uri);
        let callback_scheme = redirect_uri
            .split(':')
            .next()
            .unwrap_or_default()
            .to_string();
        let session = OauthSession {
            url: request.url().to_string(),
            redirect_uri,
            callback_scheme,
        };
        *self.pending_oauth.lock().unwrap() = Some(request);
        Ok(session)
    }

    /// Finish the pending consent flow with the callback URL the auth
    /// session delivered. Exchanges the code, stores the refresh token in
    /// the keychain, upserts the account (keeping an existing account's
    /// color) and starts its first sync in the background. Resolves with
    /// the email that actually signed in — Google treats `login_hint` as a
    /// hint only, so check it against the account you meant to reconnect.
    pub async fn finish_oauth(
        self: Arc<Self>,
        callback_url: String,
    ) -> Result<String, EngineError> {
        let request = self
            .pending_oauth
            .lock()
            .unwrap()
            .take()
            .ok_or_else(|| EngineError::Oauth("no consent flow in progress".into()))?;
        let tokens = request.finish(&callback_url).await?;

        let provider = self.provider.read().await;
        // Account id = email address; fetch it with the fresh access token.
        let bootstrap_id: AccountId = "pending".to_string();
        provider.install_tokens(&bootstrap_id, &tokens).await?;
        let profile = provider.profile(&bootstrap_id).await?;
        let email = profile.email.clone();
        provider.install_tokens(&email, &tokens).await?;
        let avatar_url = provider.fetch_profile_photo(&email).await;
        drop(provider);
        let _ = self
            .secrets
            .delete(&heypigeon_adapter_gmail::refresh_token_key(&bootstrap_id));

        let existing = self.store.list_accounts()?;
        let color = existing
            .iter()
            .find(|a| a.id == email)
            .map(|a| a.color.clone())
            .unwrap_or_else(|| ACCOUNT_COLORS[existing.len() % ACCOUNT_COLORS.len()].to_string());
        self.store.upsert_account(&domain::Account {
            id: email.clone(),
            email: email.clone(),
            display_name: email.split('@').next().unwrap_or(&email).to_string(),
            color,
            history_id: None,
            avatar_url,
            signature: String::new(),
        })?;
        self.disconnected.lock().unwrap().remove(&email);
        self.notify_threads_updated();

        let engine = Arc::clone(&self);
        let account_id = email.clone();
        tokio::spawn(async move {
            if engine.sync_account(&account_id).await {
                engine.notify_threads_updated();
            }
        });
        Ok(email)
    }
}

/// One outbox drain at a time, whoever asks: the caller waits for the
/// drain in flight and then runs its own over what is left. `queued` is
/// the "a background drain is waiting" mark (`Engine::drain_soon`),
/// lowered once the drain holds the lock — a mutation queued after that
/// point may be missed by this drain's reads and needs its own.
pub(crate) async fn drain_exclusive<M: MailProvider, S: Store>(
    lock: &tokio::sync::Mutex<()>,
    queued: &AtomicBool,
    provider: &M,
    store: &S,
) -> Result<outbox::DrainReport, outbox::OutboxError> {
    let _one_at_a_time = lock.lock().await;
    queued.store(false, Ordering::SeqCst);
    outbox::drain_report(provider, store, DRAIN_BATCH).await
}

// Internals — not exported.
impl Engine {
    pub(crate) fn notify_prefs_updated(&self) {
        let listener = self.listener.lock().unwrap().clone();
        if let Some(l) = listener {
            l.on_prefs_updated();
        }
    }

    pub(crate) fn notify_threads_updated(&self) {
        if let Some(l) = self.listener.lock().unwrap().clone() {
            l.on_threads_updated();
        }
    }

    /// Store the analysis pass's new state and tell the shell, only when
    /// it changed.
    pub(crate) fn set_analysis(&self, progress: AnalysisPass) {
        {
            let mut current = self.analysis.lock().unwrap();
            if *current == progress {
                return;
            }
            *current = progress;
        }
        if let Some(l) = self.listener.lock().unwrap().clone() {
            l.on_analysis_progress(progress);
        }
    }

    pub(crate) fn mark_disconnected(&self, account_id: &AccountId) {
        let newly = self.disconnected.lock().unwrap().insert(account_id.clone());
        if !newly {
            return;
        }
        log::warn!("account {account_id} disconnected: Google rejected the stored grant");
        if let Some(l) = self.listener.lock().unwrap().clone() {
            l.on_account_disconnected(account_id.clone());
        }
    }

    /// The accounts whose Google grant no longer works.
    pub(crate) fn disconnected_accounts(&self) -> HashSet<AccountId> {
        self.disconnected.lock().unwrap().clone()
    }

    /// Clears a stale disconnected mark; true if it was set.
    fn mark_connected(&self, account_id: &AccountId) -> bool {
        self.disconnected.lock().unwrap().remove(account_id)
    }

    /// Drain the outbox, one drain at a time: a second caller waits for
    /// the one in flight, then drains what is left (usually nothing).
    async fn drain_outbox(&self) -> Result<(), EngineError> {
        let report = {
            let provider = self.provider.read().await;
            drain_exclusive(
                &self.drain_lock,
                &self.drain_queued,
                &*provider,
                &self.store,
            )
            .await?
        };
        if report.applied + report.failed > 0 {
            log::info!(
                "outbox drain: applied={} failed={}",
                report.applied,
                report.failed
            );
        }
        let mut failures = self.drain_failures.lock().unwrap();
        // Rows no longer queued have nothing to report; this also bounds
        // the map by the outbox.
        failures.retain(|id, _| self.store.outbox_contains(*id).unwrap_or(false));
        for (id, e) in report.failures {
            let auth = matches!(e, MailError::AuthExpired);
            failures.insert(id, (auth, e.to_string()));
        }
        Ok(())
    }

    /// Drain in the background, for the mutations whose caller does not
    /// wait. One waiting drain covers every mutation queued before it
    /// starts, so a bulk action is one pass over the outbox.
    fn drain_soon(self: &Arc<Self>) {
        if self.drain_queued.swap(true, Ordering::SeqCst) {
            return;
        }
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            // No runtime to spawn on (never the case for an async export):
            // the next sync round drains.
            self.drain_queued.store(false, Ordering::SeqCst);
            return;
        };
        let engine = Arc::clone(self);
        handle.spawn(async move {
            let before = engine.pending_mutations();
            if let Err(e) = engine.drain_outbox().await {
                log::warn!("background outbox drain failed: {e}");
            }
            // The shell shows how many changes wait; tell it when that
            // moved (it re-reads on this notice).
            if engine.pending_mutations() != before {
                engine.notify_threads_updated();
            }
        });
    }

    /// Fetch what `meta` lacks of the thread's bodies and store it. Returns
    /// the thread's attachment flag as now known (the metadata tier cannot
    /// tell; a full fetch can), persisted when it changed.
    pub(crate) async fn fetch_bodies_into_store(
        &self,
        thread: &domain::Thread,
        meta: &[domain::Message],
    ) -> Result<bool, MailError> {
        let missing: Vec<String> = meta
            .iter()
            .filter(|m| !m.body_fetched)
            .map(|m| m.id.clone())
            .collect();
        let full = {
            let provider = self.provider.read().await;
            provider
                .fetch_full(&thread.account_id, &thread.id, &missing, meta.len())
                .await?
        };
        let store_err = |e: heypigeon_core::ports::StoreError| MailError::Provider(e.to_string());
        for m in &full.messages {
            self.store.upsert_message(m).map_err(store_err)?;
        }
        if full.whole_thread {
            // A stored message the whole thread no longer has was deleted
            // at Gmail and the sync has not caught up: there is nothing
            // to fetch for it, and leaving it "not fetched" would send
            // every open of this thread to the network until it does.
            for m in meta.iter().filter(|m| !m.body_fetched) {
                if !full.messages.iter().any(|f| f.id == m.id) {
                    let mut gone = m.clone();
                    gone.body_fetched = true;
                    self.store.upsert_message(&gone).map_err(store_err)?;
                }
            }
        }
        let has_attachment = if full.whole_thread {
            full.has_attachment
        } else {
            thread.has_attachment || full.has_attachment
        };
        if has_attachment != thread.has_attachment {
            let mut t = thread.clone();
            t.has_attachment = has_attachment;
            self.store.upsert_thread(&t).map_err(store_err)?;
        }
        if full.whole_thread {
            let count = (full.messages.len() as i64).max(thread.msg_count);
            self.remember_attachments(&thread.id, count, full.attachments);
        } else {
            self.merge_attachments(&thread.id, meta.len(), &missing, full.attachments);
        }
        Ok(has_attachment)
    }

    /// The thread's attachment list, if remembered for this message count
    /// (a new message makes the list stale).
    fn remembered_attachments(
        &self,
        thread_id: &ThreadId,
        msg_count: i64,
    ) -> Option<Vec<AttachmentRef>> {
        self.attachments
            .lock()
            .unwrap()
            .get(thread_id)
            .filter(|(count, _)| *count == msg_count)
            .map(|(_, refs)| refs.clone())
    }

    fn remember_attachments(&self, thread_id: &ThreadId, msg_count: i64, refs: Vec<AttachmentRef>) {
        let mut lists = self.attachments.lock().unwrap();
        if lists.len() >= ATTACHMENT_LISTS_MAX {
            lists.clear();
        }
        lists.insert(thread_id.clone(), (msg_count, refs));
    }

    /// A partial fetch brought `fetched` for the `missing` messages only:
    /// the remembered list stays complete if it covered every other
    /// message, and is dropped otherwise (the next ask fetches it).
    fn merge_attachments(
        &self,
        thread_id: &ThreadId,
        stored_messages: usize,
        missing: &[String],
        fetched: Vec<AttachmentRef>,
    ) {
        let mut lists = self.attachments.lock().unwrap();
        let Some((count, mut refs)) = lists.remove(thread_id) else {
            return;
        };
        if count as usize + missing.len() != stored_messages {
            return;
        }
        refs.retain(|a| !missing.contains(&a.message_id));
        refs.extend(fetched);
        lists.insert(thread_id.clone(), (stored_messages as i64, refs));
    }

    /// A reply needs the Message-ID of the mail it answers. Mail synced
    /// before the store kept that header has none: ask Gmail for it once
    /// and keep it, so `outbox::enqueue_item` finds it. Best effort and
    /// bounded — a reply without it still goes out.
    async fn find_reply_headers(&self, account_id: &AccountId, mutation: &domain::Mutation) {
        let (domain::Mutation::Send {
            reply_to_thread: Some(thread_id),
            in_reply_to: None,
            ..
        }
        | domain::Mutation::SaveDraft {
            reply_to_thread: Some(thread_id),
            in_reply_to: None,
            ..
        }) = mutation
        else {
            return;
        };
        let Ok(meta) = self.store.list_message_meta(thread_id) else {
            return;
        };
        if outbox::reply_headers(&meta).is_some() {
            return;
        }
        let Some(mut parent) = meta
            .into_iter()
            .rev()
            .find(|m| !m.label_ids.iter().any(|l| l == "DRAFT"))
        else {
            return;
        };
        let asked = tokio::time::timeout(REPLY_HEADERS_WAIT, async {
            let provider = self.provider.read().await;
            provider.message_reply_headers(account_id, &parent.id).await
        })
        .await;
        match asked {
            Ok(Ok((Some(message_id), references))) => {
                parent.message_id_header = Some(message_id);
                parent.references_header = references;
                if let Err(e) = self.store.upsert_message(&parent) {
                    log::warn!("reply headers for {thread_id} not stored: {e}");
                }
            }
            Ok(Ok((None, _))) => {}
            Ok(Err(e)) => log::info!("reply headers for {thread_id} unavailable: {e}"),
            Err(_) => log::info!("reply headers for {thread_id} timed out"),
        }
    }

    /// Delta sync + cross-device round for one account. Returns whether
    /// anything changed locally. Never errors: failures are logged and
    /// reflected in `account_status`.
    async fn sync_account(&self, account_id: &AccountId) -> bool {
        if !self.syncing.lock().unwrap().insert(account_id.clone()) {
            return false;
        }
        let result = {
            let provider = self.provider.read().await;
            sync::delta_sync(&*provider, &self.store, account_id, BACKFILL_DAYS).await
        };
        // Cross-device state rides the same cadence, even after a failed
        // delta — independent failure mode, and cheap.
        let synced = self.devsync_account(account_id).await;
        // The push watch lease is renewed on the same cadence too (push.rs):
        // one meta read per round, one Gmail call per day at most.
        if result.is_ok() {
            self.renew_watch(account_id).await;
        }
        self.syncing.lock().unwrap().remove(account_id);
        let changed = match result {
            Ok(changed) => self.mark_connected(account_id) || changed,
            Err(sync::SyncError::Mail(MailError::AuthExpired)) => {
                self.mark_disconnected(account_id);
                false
            }
            Err(e) => {
                log::warn!("delta({account_id}) failed: {e}");
                false
            }
        };
        changed || synced
    }

    async fn devsync_account(&self, account_id: &AccountId) -> bool {
        let result = {
            let provider = self.provider.read().await;
            devsync::sync_account(&*provider, &self.store, account_id).await
        };
        let entry = match &result {
            Ok(_) => SyncStatusEntry {
                state: SyncState::Ok,
                detail: None,
            },
            Err(devsync::DevSyncError::Transport(TransportError::Unavailable(why))) => {
                SyncStatusEntry {
                    state: SyncState::Unavailable,
                    detail: Some(why.clone()),
                }
            }
            Err(devsync::DevSyncError::Transport(TransportError::AuthExpired)) => SyncStatusEntry {
                state: SyncState::AuthExpired,
                detail: None,
            },
            Err(e) => SyncStatusEntry {
                state: SyncState::Error,
                detail: Some(e.to_string()),
            },
        };
        let auth_expired = entry.state == SyncState::AuthExpired;
        {
            let mut statuses = self.sync_status.lock().unwrap();
            let same_failure = statuses
                .get(account_id)
                .is_some_and(|p| p.state == entry.state && p.detail == entry.detail);
            if entry.state != SyncState::Ok && !same_failure {
                log::warn!(
                    "devsync({account_id}) failed: {}",
                    entry.detail.as_deref().unwrap_or("auth expired")
                );
            }
            statuses.insert(account_id.clone(), entry);
        }
        // Drive and Gmail share the grant: a rejected token here means the
        // whole account is disconnected, not just reminder sync.
        if auth_expired {
            self.mark_disconnected(account_id);
        }
        let applied = result.unwrap_or_default();
        if applied.settings > 0 {
            self.notify_prefs_updated();
        }
        applied.any()
    }

    /// One small upload so a second device sees a reminder/flag on its next
    /// poll instead of after ours. Runs on the engine's runtime.
    pub(crate) fn push_devsync_later(self: &Arc<Self>, account_id: AccountId) {
        let engine = Arc::clone(self);
        // Outside a runtime (plain sync call from Swift) there is nothing
        // to spawn on; the next sync round pushes it instead.
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(async move {
                if engine.devsync_account(&account_id).await {
                    engine.notify_threads_updated();
                }
            });
        }
    }

    /// `push_devsync_later` for the account whose file carries the
    /// app-wide keys (triage labels, prefs) — `devsync::app_wide_account`.
    pub(crate) fn push_app_wide_later(self: &Arc<Self>) {
        match devsync::app_wide_account(&self.store) {
            Ok(Some(account_id)) => self.push_devsync_later(account_id),
            Ok(None) => {}
            Err(e) => log::warn!("devsync: cannot pick the app-wide account: {e}"),
        }
    }
}

/// Cache directory name for one attachment: a hash of its coordinates
/// (Gmail attachment ids run to hundreds of characters, past the path
/// component limit).
fn attachment_cache_key(a: &MailAttachment) -> String {
    // FNV-1a 64, no dependency needed for a cache key.
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in format!("{}\n{}\n{}", a.thread_id, a.message_id, a.attachment_id).bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{h:016x}")
}

/// A filename safe to write under the cache: no separators, no empty name.
fn safe_filename(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| {
            if c == '/' || c == '\\' || c == ':' || c.is_control() {
                '_'
            } else {
                c
            }
        })
        .collect();
    let trimmed = cleaned.trim().trim_start_matches('.');
    if trimmed.is_empty() {
        "attachment".to_string()
    } else {
        trimmed.chars().take(120).collect()
    }
}

#[cfg(test)]
pub(crate) mod tests_support {
    use heypigeon_core::domain;

    pub(crate) fn sample_thread(id: &str, account: &str) -> domain::Thread {
        domain::Thread {
            id: id.to_string(),
            account_id: account.to_string(),
            subject: "Hello".to_string(),
            snippet: "hi there".to_string(),
            last_msg_at: 1_700_000_000_000,
            is_read: false,
            is_inbox: true,
            is_archived: false,
            msg_count: 1,
            from_summary: "Priya".to_string(),
            last_from_addr: "priya@example.com".to_string(),
            scheduled_at: None,
            labels: vec!["INBOX".to_string()],
            has_attachment: false,
            priority: None,
            triage_label_ids: vec![],
            needs_reply: false,
            follow_up_since: None,
            suggestion: None,
            bundle_id: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tests_support::sample_thread;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "heypigeon-ffi-{tag}-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    fn client() -> OauthClient {
        OauthClient {
            client_id: "123-abc.apps.googleusercontent.com".to_string(),
            client_secret: None,
        }
    }

    #[test]
    fn opens_empty_and_reopens() {
        let dir = temp_dir("open");
        let e = Engine::open(dir.to_string_lossy().into_owned(), client()).unwrap();
        assert!(e.list_accounts().unwrap().is_empty());
        assert!(e
            .list_threads(ThreadFilter::Inbox, None, None, 50)
            .unwrap()
            .is_empty());
        assert_eq!(e.unread_counts(None).unwrap()["inbox"], 0);
        drop(e);
        let e = Engine::open(dir.to_string_lossy().into_owned(), client()).unwrap();
        assert!(e.account_status().unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn oauth_session_uses_reversed_client_id_scheme() {
        let dir = temp_dir("oauth");
        let e = Engine::open(dir.to_string_lossy().into_owned(), client()).unwrap();
        let s = e.begin_oauth(Some("me@example.com".into()), None).unwrap();
        assert_eq!(
            s.redirect_uri,
            "com.googleusercontent.apps.123-abc:/oauthredirect"
        );
        assert_eq!(s.callback_scheme, "com.googleusercontent.apps.123-abc");
        assert!(s.url.starts_with("https://accounts.google.com/"));
        assert!(s.url.contains("login_hint=me%40example.com"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn finish_oauth_rejects_bad_state_and_missing_flow() {
        let dir = temp_dir("finish");
        let e = Engine::open(dir.to_string_lossy().into_owned(), client()).unwrap();
        let err = Arc::clone(&e)
            .finish_oauth("x:/oauthredirect?code=1&state=2".into())
            .await
            .unwrap_err();
        assert!(matches!(err, EngineError::Oauth(_)), "{err}");
        let s = e.begin_oauth(None, None).unwrap();
        let err = Arc::clone(&e)
            .finish_oauth(format!("{}?code=abc&state=WRONG", s.redirect_uri))
            .await
            .unwrap_err();
        assert!(matches!(err, EngineError::Oauth(_)), "{err}");
        // The flow is consumed either way.
        assert!(matches!(
            Arc::clone(&e)
                .finish_oauth("x:/?code=1&state=2".into())
                .await,
            Err(EngineError::Oauth(_))
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn mutations_apply_locally_without_a_working_grant() {
        let dir = temp_dir("mutate");
        let e = Engine::open(dir.to_string_lossy().into_owned(), client()).unwrap();
        e.store
            .upsert_account(&domain::Account {
                id: "a@x.com".into(),
                email: "a@x.com".into(),
                display_name: "a".into(),
                color: "sky".into(),
                history_id: None,
                avatar_url: None,
                signature: String::new(),
            })
            .unwrap();
        e.store
            .upsert_thread(&sample_thread("t1", "a@x.com"))
            .unwrap();

        Arc::clone(&e)
            .set_schedule("t1".into(), Some(now_ms() + 86_400_000), true)
            .unwrap();
        let scheduled = e.list_scheduled().unwrap();
        assert_eq!(scheduled.len(), 1);
        assert!(scheduled[0].follow_up_since.is_some());
        Arc::clone(&e).set_needs_reply("t1".into(), true).unwrap();
        assert_eq!(e.list_needs_reply().unwrap().len(), 1);
        // Flagged mail lives in those lists, not the inbox.
        assert!(e
            .list_threads(ThreadFilter::Inbox, None, None, 50)
            .unwrap()
            .is_empty());

        // No refresh token stored → the drain hits AuthExpired without any
        // network, the row is still archived locally and stays queued.
        Arc::clone(&e)
            .mutate(
                "a@x.com".into(),
                Mutation::Archive {
                    thread_id: "t1".into(),
                },
            )
            .await
            .unwrap();
        let archived = e
            .list_threads(ThreadFilter::Archive, None, None, 50)
            .unwrap();
        assert_eq!(archived.len(), 1);
        assert!(archived[0].is_archived);
        assert_eq!(e.store.outbox_list(10).unwrap().len(), 1);
        // Waiting, not given up on: the account is signed out, which is
        // not the change's fault.
        assert_eq!((e.pending_mutations(), e.failed_mutations()), (1, 0));
        // Done ends the reminder and the "needs reply" flag.
        assert!(archived[0].scheduled_at.is_none() && !archived[0].needs_reply);
        assert!(e.list_scheduled().unwrap().is_empty());
        assert!(e.list_needs_reply().unwrap().is_empty());

        let status = e.account_status().unwrap();
        assert_eq!(status.len(), 1);
        // A drain failure alone never flips the connection state (parity with
        // the desktop shell: only a sync round or a reopen decides that).
        assert_eq!(status[0].connection, ConnectionState::Connected);
        assert_eq!(status[0].sync, SyncState::Pending);

        // Reopen: the account has no refresh token → starts out disconnected,
        // and the local state (archive, cleared flags) survived.
        drop(e);
        let e = Engine::open(dir.to_string_lossy().into_owned(), client()).unwrap();
        let status = e.account_status().unwrap();
        assert_eq!(status[0].connection, ConnectionState::Disconnected);
        assert_eq!(
            e.list_threads(ThreadFilter::Archive, None, None, 50)
                .unwrap()
                .len(),
            1
        );
        assert!(e.list_scheduled().unwrap().is_empty());
        assert!(e.list_needs_reply().unwrap().is_empty());
        assert_eq!(e.store.outbox_list(10).unwrap().len(), 1);

        e.remove_account("a@x.com".into()).await.unwrap();
        assert!(e.list_accounts().unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Two drains asked for at once (a mutation's and a sync round's):
    /// every queued change reaches the provider once. Before the lock both
    /// read the same rows and each applied them.
    #[tokio::test]
    async fn concurrent_drains_apply_each_row_once() {
        use heypigeon_core::fakes::{sample_account, FakeProvider, MemStore};

        let store = MemStore::default();
        store.upsert_account(&sample_account("a1")).unwrap();
        let provider = FakeProvider::with_sample_data("a1", 3, 10);
        sync::backfill(&provider, &store, &"a1".to_string(), 30)
            .await
            .unwrap();
        let threads = store
            .list_threads(None, &domain::ThreadFilter::Inbox, None, 10)
            .unwrap();
        for t in &threads {
            outbox::enqueue(
                &store,
                &"a1".to_string(),
                domain::Mutation::Archive {
                    thread_id: t.id.clone(),
                },
            )
            .unwrap();
        }
        // Each apply lets the other drain run before it answers.
        provider.slow_applies(3);
        let lock = tokio::sync::Mutex::new(());
        let queued = AtomicBool::new(true);

        let (a, b) = tokio::join!(
            drain_exclusive(&lock, &queued, &provider, &store),
            drain_exclusive(&lock, &queued, &provider, &store),
        );

        let (a, b) = (a.unwrap(), b.unwrap());
        assert_eq!(a.applied + b.applied, 3);
        assert_eq!(
            provider.applied_mutations().len(),
            3,
            "no row applied twice"
        );
        assert!(store.outbox_list(10).unwrap().is_empty());
        assert!(!queued.load(Ordering::SeqCst));

        // The same two drains without the lock are the bug: both read the
        // rows before either deletes one.
        for t in &threads {
            outbox::enqueue(
                &store,
                &"a1".to_string(),
                domain::Mutation::Unarchive {
                    thread_id: t.id.clone(),
                },
            )
            .unwrap();
        }
        let _ = tokio::join!(
            outbox::drain_report(&provider, &store, DRAIN_BATCH),
            outbox::drain_report(&provider, &store, DRAIN_BATCH),
        );
        assert_eq!(provider.applied_mutations().len(), 3 + 6);
    }

    /// The attachment list a full fetch brought answers `list_attachments`
    /// until the thread grows; a partial fetch extends it only when it
    /// covered every other message.
    #[test]
    fn attachment_lists_are_remembered_per_message_count() {
        let dir = temp_dir("attachments");
        let e = Engine::open(dir.to_string_lossy().into_owned(), client()).unwrap();
        let part = |message: &str, id: &str| AttachmentRef {
            message_id: message.to_string(),
            attachment_id: id.to_string(),
            filename: "a.pdf".to_string(),
            mime_type: "application/pdf".to_string(),
            size: 1,
            content_id: None,
        };
        let t1 = "t1".to_string();
        assert!(e.remembered_attachments(&t1, 2).is_none());
        e.remember_attachments(&t1, 2, vec![part("m1", "a")]);
        assert_eq!(e.remembered_attachments(&t1, 2).unwrap().len(), 1);
        // A new message arrived: the list is stale until it is fetched.
        assert!(e.remembered_attachments(&t1, 3).is_none());
        e.merge_attachments(&t1, 3, &["m3".to_string()], vec![part("m3", "b")]);
        let ids: Vec<String> = e
            .remembered_attachments(&t1, 3)
            .unwrap()
            .into_iter()
            .map(|a| a.attachment_id)
            .collect();
        assert_eq!(ids, vec!["a", "b"]);
        // Two new messages but only one fetched: the list cannot be
        // complete, so it is dropped rather than trusted.
        e.merge_attachments(&t1, 5, &["m5".to_string()], vec![]);
        assert!(e.remembered_attachments(&t1, 5).is_none());
        // No list, no merge.
        e.merge_attachments(&"t2".to_string(), 1, &["m1".to_string()], vec![]);
        assert!(e.remembered_attachments(&"t2".to_string(), 1).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The exported async functions run inside async-compat's runtime.
    /// Its default is a single thread; the `multi-thread` feature this
    /// crate turns on must reach the copy UniFFI uses.
    #[test]
    fn the_engine_runtime_is_multi_threaded() {
        let flavor = std::thread::spawn(|| {
            futures::executor::block_on(async_compat::Compat::new(async {
                tokio::runtime::Handle::current().runtime_flavor()
            }))
        })
        .join()
        .unwrap();
        assert_eq!(flavor, tokio::runtime::RuntimeFlavor::MultiThread);
    }

    #[test]
    fn get_thread_local_reads_the_store_without_a_fetch() {
        let dir = temp_dir("local");
        let e = Engine::open(dir.to_string_lossy().into_owned(), client()).unwrap();
        assert!(e.get_thread_local("nope".into()).unwrap().is_none());
        e.store
            .upsert_account(&domain::Account {
                id: "me@x.com".into(),
                email: "me@x.com".into(),
                display_name: "me".into(),
                color: "sky".into(),
                history_id: None,
                avatar_url: None,
                signature: String::new(),
            })
            .unwrap();
        e.store
            .upsert_thread(&sample_thread("t1", "me@x.com"))
            .unwrap();
        e.store
            .upsert_message(&domain::Message {
                id: "m1".into(),
                thread_id: "t1".into(),
                account_id: "me@x.com".into(),
                from_addr: "priya@example.com".into(),
                to_addrs: vec!["me@x.com".into()],
                date: 1_700_000_000_000,
                snippet: "hi there".into(),
                body_html: None,
                body_text: Some("hi there, full text".into()),
                label_ids: vec!["INBOX".into()],
                is_read: false,
                ..Default::default()
            })
            .unwrap();
        let t = e.get_thread_local("t1".into()).unwrap().unwrap();
        assert_eq!(t.thread.id, "t1");
        assert_eq!(t.messages.len(), 1);
        assert_eq!(
            t.messages[0].body_text.as_deref(),
            Some("hi there, full text")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn attachment_cache_paths_are_short_and_safe() {
        let a = MailAttachment {
            thread_id: "t1".into(),
            message_id: "m1".into(),
            attachment_id: "A".repeat(600),
            filename: "../../etc/passwd:report.pdf".into(),
            mime_type: "application/pdf".into(),
            size: 1,
            content_id: None,
        };
        let key = attachment_cache_key(&a);
        assert_eq!(key.len(), 16);
        assert!(key.chars().all(|c| c.is_ascii_hexdigit()));
        let mut b = a.clone();
        b.attachment_id = "B".repeat(600);
        assert_ne!(attachment_cache_key(&b), key);
        assert_eq!(safe_filename(&a.filename), "_.._etc_passwd_report.pdf");
        assert_eq!(safe_filename("   "), "attachment");
        assert_eq!(safe_filename(".hidden"), "hidden");
    }
}
