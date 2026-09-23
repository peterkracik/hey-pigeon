//! Jev auto-triage IPC surface + background classification (DESIGN.md "AI
//! features"). Local-only labels + priority (Peter's decision: app-local
//! tags, not real Gmail labels) — see `heypigeon_core::domain::TriageLabel`
//! and `Priority`.
//!
//! Runs automatically at the end of the delta-sync poll (no explicit "AI
//! action" button, unlike the OpenAI edit feature) — Settings must disclose
//! this. Independent of mail backend: classification only needs a thread's
//! subject/snippet/sender, so it runs for the dev fake account too.

use std::sync::Mutex;

use heypigeon_adapter_jev::{ClassifyInput, JevClassifier};
use heypigeon_core::domain::{ThreadId, TriageLabel};
use heypigeon_core::ports::Store;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};

use crate::mail::{MailState, THREADS_UPDATED};

/// Threads classified per poll tick. Bounded so one slow/large inbox can't
/// turn a 30s tick into a multi-minute Jev round; the next tick picks up
/// where this one left off (`list_threads_needing_triage` is idempotent).
const TRIAGE_BATCH: u32 = 10;

fn key_secret_key() -> &'static str {
    "triage.jev.api_key"
}

fn enabled_secret_key() -> &'static str {
    "triage.enabled"
}

fn estr(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// Runtime-only bits that don't belong in `MailState` (core sync/store
/// plumbing) or the SQLite store (ephemeral, reset every launch).
pub struct AutolabelState {
    /// Guards `classify_pending` from overlapping runs \u2014 a slow Jev round
    /// can still be in flight when the next ~30s poll tick fires.
    classifying: Mutex<bool>,
    /// Last classification failure (mirrors `mail::SyncStatus` for devsync);
    /// None after a clean run so a stale error doesn't linger in Settings.
    last_error: Mutex<Option<String>>,
}

pub fn init(app: &tauri::App) {
    app.manage(AutolabelState {
        classifying: Mutex::new(false),
        last_error: Mutex::new(None),
    });
}

#[derive(Serialize)]
pub struct TriageStatus {
    pub configured: bool,
    pub enabled: bool,
    pub last_error: Option<String>,
}

#[tauri::command]
pub fn autolabel_status(
    mail: State<'_, MailState>,
    astate: State<'_, AutolabelState>,
) -> Result<TriageStatus, String> {
    let configured = matches!(mail.secrets.get(key_secret_key()), Ok(Some(_)));
    let enabled = mail
        .secrets
        .get(enabled_secret_key())
        .map_err(estr)?
        .as_deref()
        == Some("true");
    Ok(TriageStatus {
        configured,
        enabled,
        last_error: astate.last_error.lock().unwrap().clone(),
    })
}

/// "Authenticate" before persisting, same pattern as `ai::set_ai_key`: a
/// typo or revoked key never gets saved.
#[tauri::command]
pub async fn set_jev_key(mail: State<'_, MailState>, api_key: String) -> Result<(), String> {
    let key = api_key.trim().to_string();
    if key.is_empty() {
        return Err("API key is empty".to_string());
    }
    JevClassifier::new(key.clone())
        .verify()
        .await
        .map_err(estr)?;
    mail.secrets.set(key_secret_key(), &key).map_err(estr)
}

#[tauri::command]
pub fn remove_jev_key(mail: State<'_, MailState>) -> Result<(), String> {
    mail.secrets.delete(key_secret_key()).map_err(estr)
}

/// Small local preference, not a secret \u2014 reuses `SecretStore`'s generic
/// key/value shape rather than a new SQLite migration for one flag (mirrors
/// `ai::set_ai_model`).
#[tauri::command]
pub fn set_autolabel_enabled(mail: State<'_, MailState>, enabled: bool) -> Result<(), String> {
    mail.secrets
        .set(enabled_secret_key(), if enabled { "true" } else { "false" })
        .map_err(estr)
}

#[tauri::command]
pub fn list_triage_labels(mail: State<'_, MailState>) -> Result<Vec<TriageLabel>, String> {
    mail.store.list_triage_labels().map_err(estr)
}

#[tauri::command]
pub fn create_triage_label(
    mail: State<'_, MailState>,
    name: String,
) -> Result<TriageLabel, String> {
    let name = name.trim().to_string();
    if name.is_empty() {
        return Err("label name cannot be empty".to_string());
    }
    mail.store.create_triage_label(&name).map_err(estr)
}

#[tauri::command]
pub fn rename_triage_label(
    mail: State<'_, MailState>,
    id: String,
    new_name: String,
) -> Result<(), String> {
    let new_name = new_name.trim().to_string();
    if new_name.is_empty() {
        return Err("label name cannot be empty".to_string());
    }
    mail.store.rename_triage_label(&id, &new_name).map_err(estr)
}

/// Deleting a label changes what's already rendered (its chips disappear
/// from every thread that had it) — worth a refresh, unlike create/rename.
#[tauri::command]
pub fn delete_triage_label(
    app: AppHandle,
    mail: State<'_, MailState>,
    id: String,
) -> Result<(), String> {
    mail.store.delete_triage_label(&id).map_err(estr)?;
    let _ = app.emit(THREADS_UPDATED, ());
    Ok(())
}

/// Settings "Reanalyze all emails": force every thread stale so the next
/// poll ticks reclassify the whole mailbox, gradually (bounded by
/// `TRIAGE_BATCH` per tick). Doesn't clear existing labels/priority — old
/// values stay visible until each thread's turn comes up.
#[tauri::command]
pub fn reanalyze_all_triage(mail: State<'_, MailState>) -> Result<(), String> {
    mail.store.reset_triage().map_err(estr)
}

/// User-driven label edit (footer "+" menu / badge × in the UI). Sticky:
/// pins these labels so the next auto-classification leaves them alone
/// (only "Reanalyze all emails" lifts the pin) — Peter's decision: manual
/// edits are not fed back into future Jev requests, just persisted as-is.
#[tauri::command]
pub fn set_manual_triage_labels(
    app: AppHandle,
    mail: State<'_, MailState>,
    thread_id: ThreadId,
    label_ids: Vec<String>,
) -> Result<(), String> {
    mail.store
        .set_manual_triage_labels(&thread_id, &label_ids)
        .map_err(estr)?;
    let _ = app.emit(THREADS_UPDATED, ());
    Ok(())
}

/// Classify up to `TRIAGE_BATCH` stale threads with Jev. Called at the end
/// of the delta-sync poll and after backfill (see mail.rs) — never on a
/// dedicated timer, so a failing Jev key can't spin faster than mail sync.
pub async fn classify_pending(app: &AppHandle) {
    let astate = app.state::<AutolabelState>();
    {
        let mut running = astate.classifying.lock().unwrap();
        if *running {
            return;
        }
        *running = true;
    }
    let result = classify_pending_inner(app).await;
    *astate.classifying.lock().unwrap() = false;

    match result {
        Ok(0) => {}
        Ok(n) => {
            log::info!("triage: classified {n} thread(s)");
            *astate.last_error.lock().unwrap() = None;
            let _ = app.emit(THREADS_UPDATED, ());
        }
        Err(e) => {
            log::warn!("triage: {e}");
            *astate.last_error.lock().unwrap() = Some(e);
        }
    }
}

async fn classify_pending_inner(app: &AppHandle) -> Result<usize, String> {
    let mail = app.state::<MailState>();
    let enabled = mail
        .secrets
        .get(enabled_secret_key())
        .map_err(estr)?
        .as_deref()
        == Some("true");
    if !enabled {
        return Ok(0);
    }
    let Some(api_key) = mail.secrets.get(key_secret_key()).map_err(estr)? else {
        return Ok(0);
    };

    let pending = mail
        .store
        .list_threads_needing_triage(TRIAGE_BATCH)
        .map_err(estr)?;
    if pending.is_empty() {
        return Ok(0);
    }
    let labels = mail.store.list_triage_labels().map_err(estr)?;
    let classifier = JevClassifier::new(api_key);

    let mut n = 0;
    for thread in pending {
        let messages = mail.store.list_messages(&thread.id).map_err(estr)?;
        // Thread row landed before its messages (rare mid-sync race) — skip
        // for now, the next tick sees it again (triage_msg_count untouched).
        let Some(last) = messages.last() else {
            continue;
        };
        let input = ClassifyInput {
            subject: &thread.subject,
            snippet: &thread.snippet,
            from: &last.from_addr,
        };
        let result = classifier.classify(&input, &labels).await.map_err(estr)?;
        mail.store
            .set_thread_triage(
                &thread.id,
                &result.label_ids,
                result.priority,
                thread.msg_count,
            )
            .map_err(estr)?;
        n += 1;
    }
    Ok(n)
}
