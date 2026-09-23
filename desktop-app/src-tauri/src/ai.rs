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

/// Group summaries render in a fixed-height collapsible block in the inbox
/// list (never a scrolling essay), so brevity is enforced in the prompt
/// itself rather than truncated after the fact.
const SUMMARY_SYSTEM_PROMPT: &str = "You're the user's personal assistant, giving them a quick heads-up on their active (not yet done) emails. Talk directly to them, warm and casual — e.g. \"You've got an invoice from...\" or \"Sarah followed up on...\" — first or second person, never a detached report. Return at most 3 short lines, one per notable item or theme; merge similar emails into one line. Plain text only: no markdown, no headers, no bullet characters, no preamble. If nothing is worth calling out, say so in one friendly line (e.g. \"Nothing urgent here.\").";

/// One email's contribution to a group summary — subject + snippet only,
/// never the full body (same privacy posture as Jev triage in
/// `adapter-jev`: this is a batch of many emails, so keeping the payload
/// small also matters for cost).
#[derive(serde::Deserialize)]
pub struct SummaryItem {
    pub from: String,
    pub subject: String,
    pub snippet: String,
}

/// Thread summaries render in the same fixed-height block as group
/// summaries, but recap turns in ONE conversation rather than digest many
/// separate emails — different framing needs a different system prompt.
const THREAD_SUMMARY_SYSTEM_PROMPT: &str = "You're the user's personal assistant, recapping an email conversation so they can skip reading every message. Talk directly to them, warm and casual — e.g. \"Sarah's asking for the invoice, and Priya already sent the draft.\" Return at most 3 short lines covering who said what and where things currently stand. Plain text only: no markdown, no headers, no bullet characters, no preamble.";

/// One message's contribution to a thread summary — sender + trimmed body
/// text only (never HTML), same privacy posture as `SummaryItem`.
#[derive(serde::Deserialize)]
pub struct ThreadSummaryItem {
    pub from: String,
    pub snippet: String,
}

fn build_thread_summary_prompt(subject: &str, items: &[ThreadSummaryItem]) -> String {
    let mut out = format!("Subject: {subject}\n\n");
    out.push_str(
        &items
            .iter()
            .map(|i| format!("{}: {}", i.from, i.snippet))
            .collect::<Vec<_>>()
            .join("\n\n"),
    );
    out
}

/// Pure prompt builder — no network, unit-testable directly (DESIGN.md's
/// fakes-over-mocks convention, same as `adapter-openai::build_body`).
fn build_summary_prompt(items: &[SummaryItem]) -> String {
    items
        .iter()
        .map(|i| format!("From: {}\nSubject: {}\n{}", i.from, i.subject, i.snippet))
        .collect::<Vec<_>>()
        .join("\n\n")
}

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
    let model = state
        .secrets
        .get(&model_secret_key("openai"))
        .map_err(estr)?;
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
            .map(|m| AiModel {
                id: m.id,
                label: m.label,
            })
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
            state
                .secrets
                .set(&key_secret_key("openai"), &key)
                .map_err(estr)
        }
        other => Err(format!("unknown AI provider {other}")),
    }
}

#[tauri::command]
pub fn remove_ai_key(state: State<'_, AiState>, provider_id: String) -> Result<(), String> {
    match provider_id.as_str() {
        "openai" => {
            state
                .secrets
                .delete(&key_secret_key("openai"))
                .map_err(estr)?;
            state
                .secrets
                .delete(&model_secret_key("openai"))
                .map_err(estr)
        }
        other => Err(format!("unknown AI provider {other}")),
    }
}

/// Persist the selected model (a small local preference, not a secret —
/// reuses the SecretStore's generic key/value shape rather than a new
/// SQLite migration for one string).
#[tauri::command]
pub fn set_ai_model(
    state: State<'_, AiState>,
    provider_id: String,
    model: String,
) -> Result<(), String> {
    match provider_id.as_str() {
        "openai" => state
            .secrets
            .set(&model_secret_key("openai"), &model)
            .map_err(estr),
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
                    ChatMessage {
                        role: ChatRole::System,
                        content: EDIT_SYSTEM_PROMPT.to_string(),
                    },
                    ChatMessage {
                        role: ChatRole::User,
                        content: user_content,
                    },
                ],
            };
            OpenAiProvider::new(key)
                .complete(req)
                .await
                .map(|s| s.trim().to_string())
                .map_err(estr)
        }
        other => Err(format!("unknown AI provider {other}")),
    }
}

/// Summarize a batch of active (not-done) emails from one inbox-list group
/// (a day bucket) into a few short lines. Caller (InboxList.svelte) triggers this
/// only on an explicit click and caches the result client-side keyed on the
/// group's contents \u2014 this command itself is stateless and always calls
/// the provider.
#[tauri::command]
pub async fn ai_summarize_group(
    state: State<'_, AiState>,
    provider_id: String,
    items: Vec<SummaryItem>,
) -> Result<String, String> {
    if items.is_empty() {
        return Err("nothing to summarize".to_string());
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
            let req = CompletionRequest {
                model,
                messages: vec![
                    ChatMessage {
                        role: ChatRole::System,
                        content: SUMMARY_SYSTEM_PROMPT.to_string(),
                    },
                    ChatMessage {
                        role: ChatRole::User,
                        content: build_summary_prompt(&items),
                    },
                ],
            };
            OpenAiProvider::new(key)
                .complete(req)
                .await
                .map(|s| s.trim().to_string())
                .map_err(estr)
        }
        other => Err(format!("unknown AI provider {other}")),
    }
}

/// Summarize one open thread's messages into a short recap. Caller
/// (ThreadView.svelte) triggers this only on an explicit click and caches
/// the result client-side keyed on the thread's message ids \u2014 this
/// command itself is stateless and always calls the provider.
#[tauri::command]
pub async fn ai_summarize_thread(
    state: State<'_, AiState>,
    provider_id: String,
    subject: String,
    items: Vec<ThreadSummaryItem>,
) -> Result<String, String> {
    if items.is_empty() {
        return Err("nothing to summarize".to_string());
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
            let req = CompletionRequest {
                model,
                messages: vec![
                    ChatMessage {
                        role: ChatRole::System,
                        content: THREAD_SUMMARY_SYSTEM_PROMPT.to_string(),
                    },
                    ChatMessage {
                        role: ChatRole::User,
                        content: build_thread_summary_prompt(&subject, &items),
                    },
                ],
            };
            OpenAiProvider::new(key)
                .complete(req)
                .await
                .map(|s| s.trim().to_string())
                .map_err(estr)
        }
        other => Err(format!("unknown AI provider {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_summary_prompt_includes_each_item() {
        let items = vec![
            SummaryItem {
                from: "billing@x.com".to_string(),
                subject: "Invoice #42".to_string(),
                snippet: "Payment due Friday".to_string(),
            },
            SummaryItem {
                from: "newsletter@y.com".to_string(),
                subject: "Weekly digest".to_string(),
                snippet: "Top stories this week".to_string(),
            },
        ];
        let prompt = build_summary_prompt(&items);
        assert!(prompt.contains("Invoice #42"));
        assert!(prompt.contains("billing@x.com"));
        assert!(prompt.contains("Weekly digest"));
        assert_eq!(prompt.matches("From:").count(), 2);
    }

    #[test]
    fn build_thread_summary_prompt_includes_subject_and_each_message() {
        let items = vec![
            ThreadSummaryItem {
                from: "Sarah".to_string(),
                snippet: "Can you send the invoice?".to_string(),
            },
            ThreadSummaryItem {
                from: "Me".to_string(),
                snippet: "Sent, let me know if anything's missing.".to_string(),
            },
        ];
        let prompt = build_thread_summary_prompt("Invoice #42", &items);
        assert!(prompt.starts_with("Subject: Invoice #42"));
        assert!(prompt.contains("Sarah: Can you send the invoice?"));
        assert!(prompt.contains("Me: Sent, let me know if anything's missing."));
    }
}
