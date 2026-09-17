//! AI provider IPC surface (DESIGN.md "AI features"). Provider-agnostic by
//! design — commands take a `provider_id` string and match on it, so a
//! second provider is one new match arm here plus one new adapter crate,
//! never a signature change. Only ChatGPT (OpenAI) exists today.

use std::sync::Arc;

use heypigeon_adapter_openai::OpenAiProvider;
use heypigeon_core::ports::{AiProvider, ChatMessage, ChatRole, CompletionRequest, SecretStore};
use serde::Serialize;
use tauri::{Manager, State};

/// Kept terse and blunt on purpose — a chatty assistant reply would land
/// straight in the compose body otherwise (no post-processing beyond trim).
const EDIT_SYSTEM_PROMPT: &str = "You are an email writing assistant. You may be given the prior conversation for context — use it to answer questions or reference details the user asks for. Apply the user's instruction to the given text and return ONLY the revised text — no preamble, no explanation, no markdown formatting, no surrounding quotes.";

pub struct AiState {
    secrets: Arc<dyn SecretStore + Send + Sync>,
}

pub fn init(app: &tauri::App, secrets: Arc<dyn SecretStore + Send + Sync>) {
    app.manage(AiState { secrets });
}

fn estr(e: impl std::fmt::Display) -> String {
    e.to_string()
}

fn key_secret_key(provider_id: &str) -> String {
    format!("ai.{provider_id}.api_key")
}

fn model_secret_key(provider_id: &str) -> String {
    format!("ai.{provider_id}.model")
}

/// One entry in an `AiProvider::models()` list, over the wire.
#[derive(Serialize)]
pub struct AiModel {
    pub id: String,
    pub label: String,
}

#[derive(Serialize)]
pub struct AiStatus {
    pub configured: bool,
    pub provider_id: Option<String>,
    pub model: Option<String>,
}

/// Whether an AI provider is configured, and which model is selected —
/// never returns the stored key itself.
#[tauri::command]
pub fn ai_status(state: State<'_, AiState>) -> Result<AiStatus, String> {
    // Only "openai" exists today; check it explicitly rather than a loop
    // over a provider registry that doesn't exist yet either.
    let configured = matches!(state.secrets.get(&key_secret_key("openai")), Ok(Some(_)));
    let model = state.secrets.get(&model_secret_key("openai")).map_err(estr)?;
    Ok(AiStatus {
        configured,
        provider_id: configured.then(|| "openai".to_string()),
        model,
    })
}

/// Selectable models for one provider. Static list — `AiProvider::models()`
/// never hits the network, so no key is required to call this.
#[tauri::command]
pub fn ai_models(provider_id: String) -> Result<Vec<AiModel>, String> {
    match provider_id.as_str() {
        "openai" => Ok(OpenAiProvider::model_catalog()
            .into_iter()
            .map(|m| AiModel { id: m.id, label: m.label })
            .collect()),
        other => Err(format!("unknown AI provider {other}")),
    }
}

/// "Authenticate": verify a freshly pasted key with one live provider call
/// before persisting it (mirrors the Gmail OAuth flow, which fetches the
/// profile before storing tokens) — a typo or revoked key never gets saved.
#[tauri::command]
pub async fn set_ai_key(
    state: State<'_, AiState>,
    provider_id: String,
    api_key: String,
) -> Result<(), String> {
    let key = api_key.trim().to_string();
    if key.is_empty() {
        return Err("API key is empty".to_string());
    }
    match provider_id.as_str() {
        "openai" => {
            let provider = OpenAiProvider::new(key.clone());
            provider.verify().await.map_err(estr)?;
            state.secrets.set(&key_secret_key("openai"), &key).map_err(estr)
        }
        other => Err(format!("unknown AI provider {other}")),
    }
}

#[tauri::command]
pub fn remove_ai_key(state: State<'_, AiState>, provider_id: String) -> Result<(), String> {
    match provider_id.as_str() {
        "openai" => {
            state.secrets.delete(&key_secret_key("openai")).map_err(estr)?;
            state.secrets.delete(&model_secret_key("openai")).map_err(estr)
        }
        other => Err(format!("unknown AI provider {other}")),
    }
}

/// Persist the selected model (a small local preference, not a secret —
/// reuses the SecretStore's generic key/value shape rather than a new
/// SQLite migration for one string).
#[tauri::command]
pub fn set_ai_model(state: State<'_, AiState>, provider_id: String, model: String) -> Result<(), String> {
    match provider_id.as_str() {
        "openai" => state.secrets.set(&model_secret_key("openai"), &model).map_err(estr),
        other => Err(format!("unknown AI provider {other}")),
    }
}

/// Run one freeform or preset instruction against a piece of composer text
/// (the whole body, or just the current selection — the frontend decides
/// which) and return the revised text. `history`, when given, is a plain-
/// text transcript of the conversation being replied to — lets the model
/// answer a question raised earlier instead of only reshaping `text`.
#[tauri::command]
pub async fn ai_edit_text(
    state: State<'_, AiState>,
    provider_id: String,
    instruction: String,
    text: String,
    history: Option<String>,
) -> Result<String, String> {
    let instruction = instruction.trim();
    let text = text.trim();
    if instruction.is_empty() {
        return Err("instruction is empty".to_string());
    }
    if text.is_empty() {
        return Err("nothing to edit".to_string());
    }
    match provider_id.as_str() {
        "openai" => {
            let key = state
                .secrets
                .get(&key_secret_key("openai"))
                .map_err(estr)?
                .ok_or_else(|| "connect an AI provider in Settings first".to_string())?;
            let model = state
                .secrets
                .get(&model_secret_key("openai"))
                .map_err(estr)?
                .unwrap_or_else(|| {
                    OpenAiProvider::model_catalog()
                        .into_iter()
                        .next()
                        .map(|m| m.id)
                        .unwrap_or_default()
                });
            let mut user_content = String::new();
            if let Some(h) = history.as_deref().map(str::trim).filter(|h| !h.is_empty()) {
                user_content.push_str("Conversation so far (oldest first):\n");
                user_content.push_str(h);
                user_content.push_str("\n\n");
            }
            user_content.push_str(&format!("Instruction: {instruction}\n\nText:\n{text}"));
            let req = CompletionRequest {
                model,
                messages: vec![
                    ChatMessage { role: ChatRole::System, content: EDIT_SYSTEM_PROMPT.to_string() },
                    ChatMessage { role: ChatRole::User, content: user_content },
                ],
            };
            OpenAiProvider::new(key).complete(req).await.map(|s| s.trim().to_string()).map_err(estr)
        }
        other => Err(format!("unknown AI provider {other}")),
    }
}
