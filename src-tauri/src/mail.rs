//! Tauri IPC surface: typed commands + events over the core.
//! The webview only ever sees these commands — no fs, no network, no shell.

use std::sync::Arc;

use heypigeon_adapter_gmail::{oauth, GmailProvider};
use heypigeon_adapter_sqlite::SqliteStore;
use heypigeon_core::domain::{Account, AccountId, Message, Mutation, Thread, ThreadId};
use heypigeon_core::fakes::FakeProvider;
use heypigeon_core::ports::{MailProvider, SecretStore, Store};
use heypigeon_core::{outbox, sync};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};
use tokio::sync::RwLock;

const FAKE_ACCOUNT_ID: &str = "fake";
const BACKFILL_DAYS: u32 = 30;
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

#[tauri::command]
pub fn list_accounts(state: State<'_, MailState>) -> Result<Vec<Account>, String> {
    state.store.list_accounts().map_err(estr)
}

#[tauri::command]
pub fn list_threads(
    state: State<'_, MailState>,
    account_id: Option<AccountId>,
    before: Option<i64>,
    limit: Option<u32>,
) -> Result<Vec<Thread>, String> {
    state
        .store
        .list_threads(account_id.as_ref(), before, limit.unwrap_or(200))
        .map_err(estr)
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
        })
        .map_err(estr)?;
    // Real mail replaces the dev fake account.
    let _ = state.store.delete_account(FAKE_ACCOUNT_ID);

    *state.backend.write().await = Backend::Gmail(provider);
    let _ = app.emit(THREADS_UPDATED, ());
    spawn_backfill(app.clone(), email.clone());
    Ok(email)
}

// ------------------------------------------------------------------- startup

fn spawn_backfill(handle: AppHandle, account_id: AccountId) {
    tauri::async_runtime::spawn(async move {
        let state = handle.state::<MailState>();
        let backend = state.backend.read().await;
        let result =
            with_provider!(&*backend, p => sync::backfill(p, &state.store, &account_id, BACKFILL_DAYS).await);
        match result {
            Ok(n) => {
                log::info!("backfill({account_id}): {n} threads");
                let _ = handle.emit(THREADS_UPDATED, ());
            }
            Err(e) => log::error!("backfill({account_id}) failed: {e}"),
        }
    });
}

/// Open the DB, pick the backend (Gmail when a refresh token exists, else the
/// fake provider seeded with sample data), and kick off the startup sync.
pub fn init(app: &tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let data_dir = app.path().app_data_dir()?;
    std::fs::create_dir_all(&data_dir)?;
    let store = SqliteStore::open(&data_dir.join("heypigeon.db"))?;
    let secrets: Arc<dyn SecretStore + Send + Sync> =
        Arc::from(crate::secrets::default_secret_store(&data_dir)?);

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
            })?;
            (
                Backend::Fake(FakeProvider::with_sample_data(FAKE_ACCOUNT_ID, 40, 15)),
                vec![FAKE_ACCOUNT_ID.to_string()],
            )
        }
    };

    app.manage(MailState { store, secrets, backend: RwLock::new(backend) });
    // Every account syncs independently — one failing must not block another.
    for account_id in sync_accounts {
        spawn_backfill(app.handle().clone(), account_id);
    }
    Ok(())
}
