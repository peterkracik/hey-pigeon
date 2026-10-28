//! The `Engine` object the Swift shell holds for the app's lifetime.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use heypigeon_adapter_gmail::oauth::{self, AuthRequest, ClientConfig};
use heypigeon_adapter_gmail::GmailProvider;
use heypigeon_adapter_sqlite::SqliteStore;
use heypigeon_core::domain::{self, now_ms, AccountId};
use heypigeon_core::ports::{
    MailError, MailProvider, SecretStore, Store, SyncError as TransportError,
};
use heypigeon_core::{devsync, outbox, sync};
use tokio::sync::RwLock;

use crate::secrets::default_secret_store;
use crate::types::*;

/// Backfill window on first sync (DESIGN.md: 90 days first, older later —
/// the desktop shell uses 30 today; the phone follows it).
const BACKFILL_DAYS: u32 = 30;
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
    oauth_client: ClientConfig,
    pub(crate) provider: RwLock<GmailProvider>,
    pending_oauth: Mutex<Option<AuthRequest>>,
    listener: Mutex<Option<Arc<dyn EngineListener>>>,
    /// Accounts with a delta sync in flight (foreground + background can overlap).
    syncing: Mutex<HashSet<AccountId>>,
    /// Accounts whose Google grant no longer works (edge-triggered).
    disconnected: Mutex<HashSet<AccountId>>,
    sync_status: Mutex<HashMap<AccountId, SyncStatusEntry>>,
    /// Guards Jev classification from overlapping runs (settings.rs).
    pub(crate) classifying: Mutex<bool>,
    /// Last Jev failure; None after a clean run (settings.rs).
    pub(crate) triage_last_error: Mutex<Option<String>>,
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
            .filter(|a| {
                !matches!(
                    secrets.get(&heypigeon_adapter_gmail::refresh_token_key(&a.id)),
                    Ok(Some(_))
                )
            })
            .map(|a| a.id)
            .collect();
        for id in &disconnected {
            log::warn!("account {id} has no stored refresh token; marked disconnected");
        }

        Ok(Arc::new(Self {
            store,
            secrets,
            oauth_client,
            provider: RwLock::new(provider),
            pending_oauth: Mutex::new(None),
            listener: Mutex::new(None),
            syncing: Mutex::new(HashSet::new()),
            disconnected: Mutex::new(disconnected),
            sync_status: Mutex::new(HashMap::new()),
            classifying: Mutex::new(false),
            triage_last_error: Mutex::new(None),
        }))
    }

    pub fn set_listener(&self, listener: Option<Arc<dyn EngineListener>>) {
        *self.listener.lock().unwrap() = listener;
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
    /// in lowercase (`inbox`, `starred`, …) plus `label:<id>`.
    pub fn unread_counts(
        &self,
        account_id: Option<String>,
    ) -> Result<HashMap<String, i64>, EngineError> {
        use domain::ThreadFilter as F;
        let mut out = HashMap::new();
        for (key, filter) in [
            ("inbox", F::Inbox),
            ("all", F::All),
            ("starred", F::Starred),
            ("sent", F::Sent),
            ("drafts", F::Drafts),
            ("archive", F::Archive),
            ("spam", F::Spam),
            ("trash", F::Trash),
        ] {
            out.insert(
                key.to_string(),
                self.store.count_unread(account_id.as_ref(), &filter)?,
            );
        }
        for label in self.store.list_labels()? {
            let n = self
                .store
                .count_unread(account_id.as_ref(), &F::Label(label.id.clone()))?;
            out.insert(format!("label:{}", label.id), n);
        }
        Ok(out)
    }

    /// Every scheduled ("remind me") thread, even archived / outside the
    /// inbox window — the Scheduled view, and the source for local
    /// reminder notifications.
    pub fn list_scheduled(&self) -> Result<Vec<MailThread>, EngineError> {
        Ok(self
            .store
            .list_scheduled()?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Every "needs reply" thread, even archived / outside the inbox window.
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

    /// Thread + messages. Bodies are fetched from Gmail on first open (the
    /// only network read in the UI path) and cached; later opens are local.
    pub async fn get_thread(
        &self,
        thread_id: String,
    ) -> Result<Option<ThreadWithMessages>, EngineError> {
        let Some(mut thread) = self.store.get_thread(&thread_id)? else {
            return Ok(None);
        };
        let mut messages = self.store.list_messages(&thread_id)?;
        if heypigeon_core::sync::needs_bodies(&messages) {
            let fetched = {
                let provider = self.provider.read().await;
                provider.fetch_bodies(&thread.account_id, &thread_id).await
            };
            let (has_attachment, fetched) = match fetched {
                Ok(v) => v,
                Err(MailError::AuthExpired) => {
                    self.mark_disconnected(&thread.account_id);
                    return Err(MailError::AuthExpired.into());
                }
                Err(e) => return Err(e.into()),
            };
            for m in &fetched {
                self.store.upsert_message(m)?;
            }
            messages = self.store.list_messages(&thread_id)?;
            // Backfill only sees Gmail's metadata tier, so has_attachment is
            // first known here — persist it back onto the thread.
            if has_attachment != thread.has_attachment {
                thread.has_attachment = has_attachment;
                self.store.upsert_thread(&thread)?;
            }
        }
        Ok(Some(ThreadWithMessages {
            thread: thread.into(),
            messages: messages.into_iter().map(Into::into).collect(),
        }))
    }

    // ------------------------------------------------------------ writes

    /// Apply a mutation locally now (the row changes before this returns),
    /// queue it for Gmail, and drain the outbox. Failures stay queued and
    /// retry on the next drain; `AuthExpired` marks the account disconnected.
    pub async fn mutate(
        self: Arc<Self>,
        account_id: String,
        mutation: Mutation,
    ) -> Result<(), EngineError> {
        outbox::enqueue(&self.store, &account_id, mutation.into())?;
        self.notify_threads_updated();
        self.drain_outbox().await
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
    pub async fn sync_all(&self) -> Result<bool, EngineError> {
        let accounts = self.store.list_accounts()?;
        let mut changed = false;
        for a in accounts {
            changed |= self.sync_account(&a.id).await;
        }
        if let Err(e) = self.drain_outbox().await {
            log::warn!("outbox drain after sync failed: {e}");
        }
        if changed {
            self.notify_threads_updated();
        }
        // Jev triage rides the sync cadence, never its own timer (desktop
        // does the same at the end of its poll tick).
        self.classify_pending().await;
        Ok(changed)
    }

    /// Delta round for one account only (pull-to-refresh in a filtered view).
    pub async fn sync_now(&self, account_id: String) -> Result<bool, EngineError> {
        let changed = self.sync_account(&account_id).await;
        if changed {
            self.notify_threads_updated();
        }
        Ok(changed)
    }

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

    /// Clears a stale disconnected mark; true if it was set.
    fn mark_connected(&self, account_id: &AccountId) -> bool {
        self.disconnected.lock().unwrap().remove(account_id)
    }

    async fn drain_outbox(&self) -> Result<(), EngineError> {
        let provider = self.provider.read().await;
        let (applied, failed) = outbox::drain(&*provider, &self.store, 20).await?;
        if applied + failed > 0 {
            log::info!("outbox drain: applied={applied} failed={failed}");
        }
        Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;

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

    fn sample_thread(id: &str, account: &str) -> domain::Thread {
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
        let inbox = e.list_threads(ThreadFilter::Inbox, None, None, 50).unwrap();
        assert!(inbox.is_empty());
        let archived = e
            .list_threads(ThreadFilter::Archive, None, None, 50)
            .unwrap();
        assert_eq!(archived.len(), 1);
        assert!(archived[0].is_archived);
        assert_eq!(e.store.outbox_list(10).unwrap().len(), 1);

        Arc::clone(&e)
            .set_schedule("t1".into(), Some(now_ms() + 86_400_000), true)
            .unwrap();
        let scheduled = e.list_scheduled().unwrap();
        assert_eq!(scheduled.len(), 1);
        assert!(scheduled[0].follow_up_since.is_some());
        Arc::clone(&e).set_needs_reply("t1".into(), true).unwrap();
        assert_eq!(e.list_needs_reply().unwrap().len(), 1);

        let status = e.account_status().unwrap();
        assert_eq!(status.len(), 1);
        // A drain failure alone never flips the connection state (parity with
        // the desktop shell: only a sync round or a reopen decides that).
        assert_eq!(status[0].connection, ConnectionState::Connected);
        assert_eq!(status[0].sync, SyncState::Pending);

        // Reopen: the account has no refresh token → starts out disconnected,
        // and the local state (archive, reminder, flag) survived.
        drop(e);
        let e = Engine::open(dir.to_string_lossy().into_owned(), client()).unwrap();
        let status = e.account_status().unwrap();
        assert_eq!(status[0].connection, ConnectionState::Disconnected);
        assert_eq!(e.list_scheduled().unwrap().len(), 1);
        assert_eq!(e.list_needs_reply().unwrap().len(), 1);
        assert_eq!(e.store.outbox_list(10).unwrap().len(), 1);

        e.remove_account("a@x.com".into()).await.unwrap();
        assert!(e.list_accounts().unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
