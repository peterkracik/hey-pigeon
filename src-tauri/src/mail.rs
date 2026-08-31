//! Tauri IPC surface: typed commands + events over the core.
//! The webview only ever sees these commands — no fs, no network, no shell.

use heypigeon_core::domain::{Account, AccountId, Message, Mutation, Thread, ThreadId};
use heypigeon_core::fakes::FakeProvider;
use heypigeon_core::ports::{MailProvider, Store};
use heypigeon_core::{outbox, sync};
use heypigeon_adapter_sqlite::SqliteStore;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};

/// Mail backend selector. Gmail variant lands with the gmail adapter —
/// `MailProvider` is not dyn-compatible (RPITIT), so enum dispatch it is.
pub enum Backend {
    Fake(FakeProvider),
}

impl Backend {
    async fn apply(&self, account_id: &AccountId, m: &Mutation) -> Result<(), String> {
        match self {
            Backend::Fake(p) => p.apply(account_id, m).await.map_err(|e| e.to_string()),
        }
    }
}

pub struct MailState {
    pub store: SqliteStore,
    pub backend: Backend,
}

#[derive(Serialize)]
pub struct ThreadWithMessages {
    pub thread: Thread,
    pub messages: Vec<Message>,
}

const THREADS_UPDATED: &str = "threads_updated";

#[tauri::command]
pub fn list_accounts(state: State<'_, MailState>) -> Result<Vec<Account>, String> {
    state.store.list_accounts().map_err(|e| e.to_string())
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
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_thread(
    state: State<'_, MailState>,
    thread_id: ThreadId,
) -> Result<Option<ThreadWithMessages>, String> {
    let thread = state.store.get_thread(&thread_id).map_err(|e| e.to_string())?;
    match thread {
        None => Ok(None),
        Some(thread) => {
            let messages = state.store.list_messages(&thread_id).map_err(|e| e.to_string())?;
            Ok(Some(ThreadWithMessages { thread, messages }))
        }
    }
}

/// Optimistic: local apply + outbox enqueue, then a background drain attempt.
#[tauri::command]
pub async fn mutate(
    app: AppHandle,
    state: State<'_, MailState>,
    account_id: AccountId,
    mutation: Mutation,
) -> Result<(), String> {
    outbox::enqueue(&state.store, &account_id, mutation).map_err(|e| e.to_string())?;
    let _ = app.emit(THREADS_UPDATED, ());
    // Drain in the same command (fake backend is instant). With Gmail this
    // stays correct: failures remain queued and the periodic drain retries.
    match &state.backend {
        Backend::Fake(p) => {
            let _ = outbox::drain(p, &state.store, 20).await.map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[tauri::command]
pub async fn sync_now(
    app: AppHandle,
    state: State<'_, MailState>,
    account_id: AccountId,
) -> Result<usize, String> {
    let n = match &state.backend {
        Backend::Fake(p) => sync::backfill(p, &state.store, &account_id, 30)
            .await
            .map_err(|e| e.to_string())?,
    };
    let _ = app.emit(THREADS_UPDATED, ());
    Ok(n)
}

/// Wire up state at startup: open the DB in the app data dir and, in fake
/// mode, seed one account + backfill so the UI has data on first launch.
pub fn init(app: &tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let data_dir = app.path().app_data_dir()?;
    std::fs::create_dir_all(&data_dir)?;
    let store = SqliteStore::open(&data_dir.join("heypigeon.db"))?;

    let provider = FakeProvider::with_sample_data("fake", 40, 15);
    let account = Account {
        id: "fake".to_string(),
        email: "fake@heypigeon.app".to_string(),
        display_name: "Fake".to_string(),
        color: "sky".to_string(),
        history_id: None,
    };
    store.upsert_account(&account)?;

    app.manage(MailState { store, backend: Backend::Fake(provider) });

    // Initial backfill in the background; UI hears about it via the event.
    let handle = app.handle().clone();
    tauri::async_runtime::spawn(async move {
        let state = handle.state::<MailState>();
        let Backend::Fake(p) = &state.backend;
        match sync::backfill(p, &state.store, &"fake".to_string(), 30).await {
            Ok(n) => {
                log::info!("startup backfill: {n} threads");
                let _ = handle.emit(THREADS_UPDATED, ());
            }
            Err(e) => log::error!("startup backfill failed: {e}"),
        }
    });
    Ok(())
}
