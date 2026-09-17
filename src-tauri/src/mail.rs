//! Tauri IPC surface: typed commands + events over the core.
//! The webview only ever sees these commands — no fs, no network, no shell.

use std::sync::Arc;

use heypigeon_adapter_gmail::{oauth, GmailProvider};
use heypigeon_adapter_sqlite::SqliteStore;
use heypigeon_core::domain::{
    Account, AccountId, Label, Message, Mutation, SearchResult, Thread, ThreadFilter, ThreadId,
};
use heypigeon_core::fakes::FakeProvider;
use heypigeon_core::ports::{MailProvider, SecretStore, Store, SyncError};
use heypigeon_core::{devsync, outbox, sync};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_notification::NotificationExt;
use tokio::sync::RwLock;

const FAKE_ACCOUNT_ID: &str = "fake";
const BACKFILL_DAYS: u32 = 30;
/// Background delta-sync poll cadence (DESIGN.md: polling tier, ~30s).
const DELTA_POLL_SECS: u64 = 30;
/// Focus-triggered delta syncs at most this often.
const FOCUS_SYNC_MIN_SECS: u64 = 5;
const THREADS_UPDATED: &str = "threads_updated";
const ACCOUNT_COLORS: &[&str] = &["sky", "lavender", "mint", "amber", "coral"];

/// Mail backend selector. `MailProvider` is not dyn-compatible (RPITIT), so
/// enum dispatch it is.
pub enum Backend {
    Fake(FakeProvider),
    Gmail(GmailProvider),
}

macro_rules! with_provider {
    ($backend:expr, $p:ident => $body:expr) => {
        match $backend {
            Backend::Fake($p) => $body,
            Backend::Gmail($p) => $body,
        }
    };
}

pub struct MailState {
    pub store: SqliteStore,
    pub secrets: Arc<dyn SecretStore + Send + Sync>,
    pub backend: RwLock<Backend>,
    /// Debounce for focus-triggered delta syncs.
    last_focus_sync: std::sync::Mutex<std::time::Instant>,
    /// Accounts with a delta sync in flight (focus + interval can overlap).
    syncing: std::sync::Mutex<std::collections::HashSet<AccountId>>,
    /// thread_id -> scheduled_at already notified, so a due "remind me"
    /// fires once per poll cadence, not on every tick until dismissed.
    /// Re-notifies on reschedule (a changed scheduled_at won't match).
    notified_reminders: std::sync::Mutex<std::collections::HashMap<ThreadId, i64>>,
    /// Last cross-device sync outcome per account: Settings shows it, and
    /// a failure is logged once per distinct cause, not every 30s tick.
    sync_status: std::sync::Mutex<std::collections::HashMap<AccountId, SyncStatus>>,
}

#[derive(Serialize, Clone, Copy, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum SyncState {
    /// No round has finished since the app started (one is on its way).
    Pending,
    Ok,
    /// Scope missing / Drive API not enabled — needs a re-connect or setup
    /// step (detail says which), not a retry.
    Unavailable,
    AuthExpired,
    Error,
}

#[derive(Serialize, Clone, PartialEq, Debug)]
pub struct SyncStatus {
    pub state: SyncState,
    pub detail: Option<String>,
    /// Epoch ms of the last successful round, on any run of the app —
    /// persisted by the core, so it survives restarts and failures.
    pub last_sync_at: Option<i64>,
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[derive(Serialize)]
pub struct ThreadWithMessages {
    pub thread: Thread,
    pub messages: Vec<Message>,
}

fn estr(e: impl std::fmt::Display) -> String {
    e.to_string()
}

fn oauth_config_path() -> std::path::PathBuf {
    dirs_config().join("heypigeon/oauth.json")
}

fn dirs_config() -> std::path::PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(Into::into)
        .unwrap_or_else(|| {
            std::path::PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config")
        })
}

fn load_oauth_config() -> Result<oauth::ClientConfig, String> {
    let path = oauth_config_path();
    let raw = std::fs::read_to_string(&path)
        .map_err(|_| format!("missing OAuth config at {} — see docs/google-oauth-setup.md", path.display()))?;
    serde_json::from_str(&raw).map_err(estr)
}

// ------------------------------------------------------------------ commands

/// Webview-side logging into the app log — WKWebView has no visible console,
/// so the frontend pipes runtime errors here (see src/main.ts).
#[tauri::command]
pub fn weblog(msg: String) {
    log::info!("web: {msg}");
}

#[tauri::command]
pub fn list_accounts(state: State<'_, MailState>) -> Result<Vec<Account>, String> {
    state.store.list_accounts().map_err(estr)
}

#[tauri::command]
pub fn list_threads(
    state: State<'_, MailState>,
    account_id: Option<AccountId>,
    filter: Option<String>,
    before: Option<i64>,
    limit: Option<u32>,
) -> Result<Vec<Thread>, String> {
    let filter = match filter.as_deref() {
        None => ThreadFilter::Inbox,
        Some(s) => ThreadFilter::parse(s).ok_or_else(|| format!("unknown filter {s}"))?,
    };
    state
        .store
        .list_threads(account_id.as_ref(), &filter, before, limit.unwrap_or(200))
        .map_err(estr)
}

/// The stored user labels across all accounts (sidebar), name-sorted.
#[tauri::command]
pub fn list_labels(state: State<'_, MailState>) -> Result<Vec<Label>, String> {
    state.store.list_labels().map_err(estr)
}

/// Unread thread counts per sidebar key — every system folder plus every
/// stored label, e.g. `{"inbox": 3, "starred": 1, "label:Label_5": 2}`.
/// One round-trip instead of one query per sidebar row.
#[tauri::command]
pub fn unread_counts(
    state: State<'_, MailState>,
    account_id: Option<AccountId>,
) -> Result<std::collections::HashMap<String, i64>, String> {
    let mut out = std::collections::HashMap::new();
    for (key, filter) in [
        ("inbox", ThreadFilter::Inbox),
        ("all", ThreadFilter::All),
        ("starred", ThreadFilter::Starred),
        ("sent", ThreadFilter::Sent),
        ("drafts", ThreadFilter::Drafts),
        ("archive", ThreadFilter::Archive),
        ("spam", ThreadFilter::Spam),
        ("trash", ThreadFilter::Trash),
    ] {
        let n = state.store.count_unread(account_id.as_ref(), &filter).map_err(estr)?;
        out.insert(key.to_string(), n);
    }
    for label in state.store.list_labels().map_err(estr)? {
        let n = state
            .store
            .count_unread(account_id.as_ref(), &ThreadFilter::Label(label.id.clone()))
            .map_err(estr)?;
        out.insert(format!("label:{}", label.id), n);
    }
    Ok(out)
}

/// Calendar feed: every scheduled thread, regardless of inbox/archive state
/// or the inbox page window — a schedule must stay visible after archiving.
#[tauri::command]
pub fn list_scheduled(state: State<'_, MailState>) -> Result<Vec<Thread>, String> {
    state.store.list_scheduled().map_err(estr)
}

/// Local FTS5 search: Gmail-style operators + bare text → ranked threads
/// with a snippet preview (same thread shape as `list_threads`).
/// Async so the FTS scan runs off the main thread — search-as-you-type
/// fires per keystroke and must never stall the UI.
#[tauri::command]
pub async fn search_threads(
    state: State<'_, MailState>,
    query: String,
    limit: Option<u32>,
) -> Result<Vec<SearchResult>, String> {
    let parsed = heypigeon_core::search::parse(&query);
    state.store.search(&parsed, limit.unwrap_or(50)).map_err(estr)
}

/// Thread + messages; fetches bodies from the provider on first open
/// (backfill stores metadata only — DESIGN.md tiering).
#[tauri::command]
pub async fn get_thread(
    state: State<'_, MailState>,
    thread_id: ThreadId,
) -> Result<Option<ThreadWithMessages>, String> {
    let Some(thread) = state.store.get_thread(&thread_id).map_err(estr)? else {
        return Ok(None);
    };
    let mut messages = state.store.list_messages(&thread_id).map_err(estr)?;
    let missing_bodies = messages.iter().all(|m| m.body_html.is_none() && m.body_text.is_none());
    if missing_bodies {
        let backend = state.backend.read().await;
        let fetched =
            with_provider!(&*backend, p => p.fetch_bodies(&thread.account_id, &thread_id).await)
                .map_err(estr)?;
        for m in &fetched {
            state.store.upsert_message(m).map_err(estr)?;
        }
        messages = state.store.list_messages(&thread_id).map_err(estr)?;
    }
    Ok(Some(ThreadWithMessages { thread, messages }))
}

/// Optimistic: local apply + outbox enqueue (instant), then a drain attempt.
/// Failures stay queued; the next mutate/sync retries them.
#[tauri::command]
pub async fn mutate(
    app: AppHandle,
    state: State<'_, MailState>,
    account_id: AccountId,
    mutation: Mutation,
) -> Result<(), String> {
    outbox::enqueue(&state.store, &account_id, mutation).map_err(estr)?;
    let _ = app.emit(THREADS_UPDATED, ());
    let backend = state.backend.read().await;
    let (applied, failed) =
        with_provider!(&*backend, p => outbox::drain(p, &state.store, 20).await).map_err(estr)?;
    log::info!("outbox drain: applied={applied} failed={failed}");
    Ok(())
}

#[tauri::command]
pub async fn sync_now(
    app: AppHandle,
    state: State<'_, MailState>,
    account_id: AccountId,
) -> Result<usize, String> {
    let backend = state.backend.read().await;
    let n = with_provider!(&*backend, p => sync::backfill(p, &state.store, &account_id, BACKFILL_DAYS).await)
        .map_err(estr)?;
    let _ = app.emit(THREADS_UPDATED, ());
    Ok(n)
}

/// Set or clear a thread's "remind me" schedule (epoch ms). Never sent to
/// Gmail (no outbox, no provider call) — it reaches the user's other
/// devices through the cross-device sync map instead (DESIGN.md).
#[tauri::command]
pub async fn set_schedule(
    app: AppHandle,
    state: State<'_, MailState>,
    account_id: AccountId,
    thread_id: ThreadId,
    scheduled_at: Option<i64>,
) -> Result<(), String> {
    let _ = account_id; // command shape mirrors mutate; the thread knows its account
    let thread = state
        .store
        .get_thread(&thread_id)
        .map_err(estr)?
        .ok_or_else(|| format!("unknown thread {thread_id}"))?;
    state.store.set_schedule(&thread_id, scheduled_at).map_err(estr)?;
    devsync::record_reminder(&state.store, &thread.account_id, &thread_id, scheduled_at).map_err(estr)?;
    let _ = app.emit(THREADS_UPDATED, ());
    // Push straight away — one small upload — so a second device sees the
    // reminder on its next poll instead of after ours.
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        devsync_account(&handle, &thread.account_id).await;
    });
    Ok(())
}

/// Cross-device sync state per account (Settings UI). Every account gets
/// an entry: `Pending` with the persisted last-sync time until the first
/// round of this session reports in.
#[tauri::command]
pub fn sync_status(
    state: State<'_, MailState>,
) -> Result<std::collections::HashMap<AccountId, SyncStatus>, String> {
    let live = state.sync_status.lock().unwrap().clone();
    let mut out = std::collections::HashMap::new();
    for account in state.store.list_accounts().map_err(estr)? {
        let status = match live.get(&account.id) {
            Some(s) => s.clone(),
            None => SyncStatus {
                state: SyncState::Pending,
                detail: None,
                last_sync_at: devsync::last_sync_at(&state.store, &account.id).map_err(estr)?,
            },
        };
        out.insert(account.id, status);
    }
    Ok(out)
}

/// Update per-account settings: display name, color (predefined palette),
/// signature. Omitted fields stay unchanged.
#[tauri::command]
pub async fn update_account(
    app: AppHandle,
    state: State<'_, MailState>,
    account_id: AccountId,
    display_name: Option<String>,
    color: Option<String>,
    signature: Option<String>,
) -> Result<(), String> {
    if let Some(c) = &color {
        if !ACCOUNT_COLORS.contains(&c.as_str()) {
            return Err(format!("unknown color {c}"));
        }
    }
    let mut account = state
        .store
        .list_accounts()
        .map_err(estr)?
        .into_iter()
        .find(|a| a.id == account_id)
        .ok_or_else(|| format!("unknown account {account_id}"))?;
    if let Some(n) = display_name {
        let n = n.trim().to_string();
        if !n.is_empty() {
            account.display_name = n;
        }
    }
    if let Some(c) = color {
        account.color = c;
    }
    if let Some(s) = signature {
        account.signature = s;
    }
    state.store.upsert_account(&account).map_err(estr)?;
    let _ = app.emit(THREADS_UPDATED, ());
    Ok(())
}

/// Accounts owning `label_id`. Label ids are per-account, but the sidebar
/// dedupes by id (the same Gmail id can exist in several connected accounts)
/// — so label ops apply to EVERY owning account: that is the chosen semantic
/// for the single deduped sidebar row.
fn label_owners(state: &MailState, label_id: &str) -> Result<Vec<AccountId>, String> {
    let owners: Vec<AccountId> = state
        .store
        .list_labels()
        .map_err(estr)?
        .into_iter()
        .filter(|l| l.id == label_id)
        .map(|l| l.account_id)
        .collect();
    if owners.is_empty() {
        return Err(format!("unknown label {label_id}"));
    }
    Ok(owners)
}

/// Rename a user label remotely (every owning account), then refresh the
/// stored label list from the provider so the sidebar reconciles.
#[tauri::command]
pub async fn update_label(
    app: AppHandle,
    state: State<'_, MailState>,
    label_id: String,
    new_name: String,
) -> Result<(), String> {
    let new_name = new_name.trim().to_string();
    if new_name.is_empty() {
        return Err("label name cannot be empty".into());
    }
    let backend = state.backend.read().await;
    // Continue past per-account failures (e.g. one expired token) so owners
    // don't diverge silently; report which accounts failed.
    let mut failed: Vec<String> = Vec::new();
    for account_id in label_owners(&state, &label_id)? {
        let r: Result<(), String> = async {
            with_provider!(&*backend, p => p.update_label(&account_id, &label_id, &new_name).await)
                .map_err(estr)?;
            state.store.rename_label(&account_id, &label_id, &new_name).map_err(estr)?;
            let labels =
                with_provider!(&*backend, p => p.list_labels(&account_id).await).map_err(estr)?;
            state.store.set_labels(&account_id, &labels).map_err(estr)?;
            Ok(())
        }
        .await;
        if let Err(e) = r {
            failed.push(format!("{account_id}: {e}"));
        }
    }
    let _ = app.emit(THREADS_UPDATED, ());
    if failed.is_empty() { Ok(()) } else { Err(failed.join("; ")) }
}

/// Delete a user label remotely (every owning account — see `label_owners`),
/// strip it from stored threads, then refresh the stored label list.
#[tauri::command]
pub async fn delete_label(
    app: AppHandle,
    state: State<'_, MailState>,
    label_id: String,
) -> Result<(), String> {
    let backend = state.backend.read().await;
    // Continue past per-account failures; retry heals remaining owners.
    let mut failed: Vec<String> = Vec::new();
    for account_id in label_owners(&state, &label_id)? {
        let r: Result<(), String> = async {
            with_provider!(&*backend, p => p.delete_label(&account_id, &label_id).await)
                .map_err(estr)?;
            state.store.delete_label(&account_id, &label_id).map_err(estr)?;
            let labels =
                with_provider!(&*backend, p => p.list_labels(&account_id).await).map_err(estr)?;
            state.store.set_labels(&account_id, &labels).map_err(estr)?;
            Ok(())
        }
        .await;
        if let Err(e) = r {
            failed.push(format!("{account_id}: {e}"));
        }
    }
    let _ = app.emit(THREADS_UPDATED, ());
    if failed.is_empty() { Ok(()) } else { Err(failed.join("; ")) }
}

/// Disconnect an account: local data + stored refresh token.
#[tauri::command]
pub async fn remove_account(
    app: AppHandle,
    state: State<'_, MailState>,
    account_id: AccountId,
) -> Result<(), String> {
    state.store.delete_account(&account_id).map_err(estr)?;
    let _ = state
        .secrets
        .delete(&heypigeon_adapter_gmail::refresh_token_key(&account_id));
    let _ = app.emit(THREADS_UPDATED, ());
    Ok(())
}

/// Sender contact photo via the People API (Gmail backend only).
#[tauri::command]
pub async fn lookup_avatar(
    state: State<'_, MailState>,
    account_id: AccountId,
    email: String,
) -> Result<Option<String>, String> {
    let backend = state.backend.read().await;
    Ok(match &*backend {
        Backend::Gmail(p) => p.contact_photo(&account_id, &email).await,
        Backend::Fake(_) => None,
    })
}

/// Run the OAuth consent flow, connect the Gmail account, start backfill.
/// The one command that changes the active backend.
#[tauri::command]
pub async fn start_gmail_oauth(app: AppHandle, state: State<'_, MailState>) -> Result<String, String> {
    let config = load_oauth_config()?;
    let tokens = oauth::authorize(&config, |url| {
        // ponytail: macOS-only browser open; switch to tauri-plugin-opener
        // when iOS/Windows matter (M4+).
        let _ = std::process::Command::new("open").arg(url).spawn();
    })
    .await
    .map_err(estr)?;

    let provider = GmailProvider::new(config, Arc::clone(&state.secrets));
    // Account id = email address; fetch it with the fresh access token.
    let bootstrap_id: AccountId = "pending".to_string();
    provider.install_tokens(&bootstrap_id, &tokens).await.map_err(estr)?;
    let profile = provider.profile(&bootstrap_id).await.map_err(estr)?;
    let email = profile.email.clone();
    provider.install_tokens(&email, &tokens).await.map_err(estr)?;
    let avatar_url = provider.fetch_profile_photo(&email).await;

    let existing = state.store.list_accounts().map_err(estr)?;
    // Re-connecting an existing account must keep its color stable.
    let color = existing
        .iter()
        .find(|a| a.id == email)
        .map(|a| a.color.clone())
        .unwrap_or_else(|| {
            ACCOUNT_COLORS[existing.iter().filter(|a| a.id != FAKE_ACCOUNT_ID).count()
                % ACCOUNT_COLORS.len()]
                .to_string()
        });
    state
        .store
        .upsert_account(&Account {
            id: email.clone(),
            email: email.clone(),
            display_name: email.split('@').next().unwrap_or(&email).to_string(),
            color,
            history_id: None,
            avatar_url,
            signature: String::new(),
        })
        .map_err(estr)?;
    // Real mail replaces the dev fake account.
    let _ = state.store.delete_account(FAKE_ACCOUNT_ID);

    *state.backend.write().await = Backend::Gmail(provider);
    let _ = app.emit(THREADS_UPDATED, ());
    spawn_startup_sync(app.clone(), email.clone());
    Ok(email)
}

// ---------------------------------------------------------------- delta sync

/// One delta sync for one account; returns whether anything changed.
/// Skips (returns false) when a sync for the account is already in flight —
/// `update_labels` is read-modify-write, and a duplicate expired-checkpoint
/// backfill would waste quota.
async fn delta_account(handle: AppHandle, account_id: AccountId) -> bool {
    let state = handle.state::<MailState>();
    if !state.syncing.lock().unwrap().insert(account_id.clone()) {
        return false;
    }
    let result = {
        let backend = state.backend.read().await;
        with_provider!(&*backend, p => sync::delta_sync(p, &state.store, &account_id, BACKFILL_DAYS).await)
    };
    // Cross-device state rides the same cadence (DESIGN.md: the sync loop
    // is the poll). Runs even after a failed delta — an independent
    // failure mode, and it is cheap.
    let synced = devsync_account(&handle, &account_id).await;
    state.syncing.lock().unwrap().remove(&account_id);
    let changed = match result {
        Ok(changed) => changed,
        Err(e) => {
            log::warn!("delta({account_id}) failed: {e}");
            false
        }
    };
    changed || synced
}

/// One cross-device sync round for one account (Gmail backend only — the
/// dev fake has no cloud behind it). Records the outcome for Settings and
/// logs a failure once per distinct cause. Returns whether local rows
/// changed (a reminder set/cleared on another device).
async fn devsync_account(handle: &AppHandle, account_id: &AccountId) -> bool {
    let state = handle.state::<MailState>();
    let result = {
        let backend = state.backend.read().await;
        let Backend::Gmail(p) = &*backend else { return false };
        devsync::sync_account(p, &state.store, account_id).await
    };
    // Persisted by the core on success; read it back so a failure still
    // shows when things last worked, even across restarts.
    let last_sync_at = devsync::last_sync_at(&state.store, account_id).unwrap_or(None);
    let mut statuses = state.sync_status.lock().unwrap();
    let previous = statuses.get(account_id).cloned();
    let status = match &result {
        Ok(_) => SyncStatus { state: SyncState::Ok, detail: None, last_sync_at },
        Err(devsync::DevSyncError::Transport(SyncError::Unavailable(why))) => {
            SyncStatus { state: SyncState::Unavailable, detail: Some(why.clone()), last_sync_at }
        }
        Err(devsync::DevSyncError::Transport(SyncError::AuthExpired)) => {
            SyncStatus { state: SyncState::AuthExpired, detail: None, last_sync_at }
        }
        Err(e) => SyncStatus { state: SyncState::Error, detail: Some(e.to_string()), last_sync_at },
    };
    let same_failure = previous
        .as_ref()
        .is_some_and(|p| p.state == status.state && p.detail == status.detail);
    if status.state != SyncState::Ok && !same_failure {
        log::warn!("devsync({account_id}) failed: {}", status.detail.as_deref().unwrap_or("auth expired"));
    }
    statuses.insert(account_id.clone(), status);
    result.unwrap_or(false)
}

/// Delta-sync every account in parallel; emit `threads_updated` when any
/// account changed. One failing account must not block another.
pub async fn delta_sync_all(handle: &AppHandle) {
    let accounts = match handle.state::<MailState>().store.list_accounts() {
        Ok(a) => a,
        Err(e) => {
            log::warn!("delta sync: list_accounts failed: {e}");
            return;
        }
    };
    let tasks: Vec<_> = accounts
        .into_iter()
        .map(|a| tauri::async_runtime::spawn(delta_account(handle.clone(), a.id)))
        .collect();
    let mut any_changed = false;
    for t in tasks {
        any_changed |= t.await.unwrap_or(false);
    }
    if any_changed {
        let _ = handle.emit(THREADS_UPDATED, ());
    }
}

/// Background poll: delta sync all accounts every `DELTA_POLL_SECS`.
pub fn spawn_delta_loop(handle: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(DELTA_POLL_SECS));
        // Wake-from-sleep must not fire a burst of back-to-back polls.
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        interval.tick().await; // fires immediately — skip, startup sync just ran
        loop {
            interval.tick().await;
            delta_sync_all(&handle).await;
            notify_due_reminders(&handle);
        }
    });
}

/// Desktop notification for every "remind me" schedule that has come due
/// since the last check. Piggybacks on the delta-sync poll cadence
/// (DESIGN.md ~30s) instead of a second timer.
fn notify_due_reminders(handle: &AppHandle) {
    let state = handle.state::<MailState>();
    let scheduled = match state.store.list_scheduled() {
        Ok(s) => s,
        Err(e) => {
            log::warn!("reminder check: list_scheduled failed: {e}");
            return;
        }
    };
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let mut notified = state.notified_reminders.lock().unwrap();
    // Drop bookkeeping for threads no longer scheduled (cleared reminder).
    let still_scheduled: std::collections::HashSet<&ThreadId> =
        scheduled.iter().map(|t| &t.id).collect();
    notified.retain(|id, _| still_scheduled.contains(id));
    for thread in &scheduled {
        let Some(due_at) = thread.scheduled_at else { continue };
        if due_at > now_ms {
            continue;
        }
        if notified.get(&thread.id) == Some(&due_at) {
            continue; // already notified for this exact schedule
        }
        let _ = handle
            .notification()
            .builder()
            .title(format!("Reminder: {}", thread.subject))
            .body(&thread.from_summary)
            .show();
        notified.insert(thread.id.clone(), due_at);
    }
}

/// Window focus → immediate delta sync, rate-limited to one per
/// `FOCUS_SYNC_MIN_SECS` (focus events fire liberally on macOS).
pub fn on_focus(handle: AppHandle) {
    {
        let state = handle.state::<MailState>();
        let mut last = state.last_focus_sync.lock().unwrap();
        if last.elapsed() < std::time::Duration::from_secs(FOCUS_SYNC_MIN_SECS) {
            return;
        }
        *last = std::time::Instant::now();
    }
    tauri::async_runtime::spawn(async move { delta_sync_all(&handle).await });
}

// ------------------------------------------------------------------- startup

/// Startup/connect sync: delta from the stored checkpoint. `delta_sync`
/// falls back to a full backfill when the checkpoint is missing or expired,
/// but never resets a valid one — so changes made while the app was closed
/// (archive/trash on another device) are applied, not discarded.
fn spawn_startup_sync(handle: AppHandle, account_id: AccountId) {
    tauri::async_runtime::spawn(async move {
        if delta_account(handle.clone(), account_id).await {
            let _ = handle.emit(THREADS_UPDATED, ());
        }
    });
}

/// Open the DB, pick the backend (Gmail when a refresh token exists, else the
/// fake provider seeded with sample data), and kick off the startup sync.
// `secrets` is shared with `ai::init` (one FileSecretStore in-memory cache
// in debug builds) — two independent instances over the same JSON file
// would each persist() a whole-file rewrite from its own stale cache and
// could silently clobber the other's writes (Gmail tokens vs. AI keys).
pub fn init(app: &tauri::App, secrets: Arc<dyn SecretStore + Send + Sync>) -> Result<(), Box<dyn std::error::Error>> {
    let data_dir = app.path().app_data_dir()?;
    std::fs::create_dir_all(&data_dir)?;
    let store = SqliteStore::open(&data_dir.join("heypigeon.db"))?;

    // Gmail mode when config + stored refresh tokens for known accounts exist.
    let gmail_accounts = load_oauth_config().ok().and_then(|config| {
        let accounts = store.list_accounts().ok()?;
        let with_tokens: Vec<AccountId> = accounts
            .iter()
            .filter(|a| {
                a.id != FAKE_ACCOUNT_ID
                    && matches!(
                        secrets.get(&heypigeon_adapter_gmail::refresh_token_key(&a.id)),
                        Ok(Some(_))
                    )
            })
            .map(|a| a.id.clone())
            .collect();
        (!with_tokens.is_empty()).then_some((config, with_tokens))
    });

    let (backend, sync_accounts) = match gmail_accounts {
        Some((config, account_ids)) => {
            log::info!("backend: gmail ({})", account_ids.join(", "));
            (Backend::Gmail(GmailProvider::new(config, Arc::clone(&secrets))), account_ids)
        }
        None => {
            log::info!("backend: fake");
            store.upsert_account(&Account {
                id: FAKE_ACCOUNT_ID.to_string(),
                email: "fake@heypigeon.app".to_string(),
                display_name: "Fake".to_string(),
                color: "sky".to_string(),
                history_id: None,
                avatar_url: None,
                signature: String::new(),
            })?;
            (
                Backend::Fake(FakeProvider::with_sample_data(FAKE_ACCOUNT_ID, 40, 15)),
                vec![FAKE_ACCOUNT_ID.to_string()],
            )
        }
    };

    app.manage(MailState {
        store,
        secrets,
        backend: RwLock::new(backend),
        last_focus_sync: std::sync::Mutex::new(std::time::Instant::now()),
        syncing: std::sync::Mutex::new(std::collections::HashSet::new()),
        notified_reminders: std::sync::Mutex::new(std::collections::HashMap::new()),
        sync_status: std::sync::Mutex::new(std::collections::HashMap::new()),
    });
    // Every account syncs independently — one failing must not block another.
    for account_id in sync_accounts {
        spawn_startup_sync(app.handle().clone(), account_id);
    }
    spawn_delta_loop(app.handle().clone());
    Ok(())
}
