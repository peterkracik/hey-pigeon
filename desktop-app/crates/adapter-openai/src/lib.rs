//! OpenAI (ChatGPT) adapter: implements `AiProvider` over the Chat
//! Completions API. Only this crate speaks OpenAI's wire format — the core
//! and the UI see the provider-agnostic trait.

use heypigeon_core::ports::{AiError, AiProvider, ChatRole, CompletionRequest, ModelInfo};
use serde::{Deserialize, Serialize};

const API_BASE: &str = "https://api.openai.com/v1";

/// Curated chat-capable models for the picker — the raw `/v1/models` list
/// also includes embeddings/whisper/moderation models that don't belong in
/// a completion picker. First entry is the recommended default (cost).
const MODELS: &[(&str, &str)] = &[
    ("gpt-4o-mini", "GPT-4o mini (default)"),
    ("gpt-4o", "GPT-4o"),
    ("gpt-4.1-mini", "GPT-4.1 mini"),
    ("gpt-4.1", "GPT-4.1"),
];

pub struct OpenAiProvider {
    http: reqwest::Client,
    api_key: String,
}

impl OpenAiProvider {
    pub fn new(api_key: String) -> Self {
        Self { http: reqwest::Client::new(), api_key }
    }

    /// Same list as `AiProvider::models()`, without needing an instance —
    /// the settings UI's model picker doesn't have a key yet the first
    /// time it needs this.
    pub fn model_catalog() -> Vec<ModelInfo> {
        MODELS.iter().map(|(id, label)| ModelInfo { id: id.to_string(), label: label.to_string() }).collect()
    }
}

fn role_str(role: ChatRole) -> &'static str {
    match role {
        ChatRole::System => "system",
        ChatRole::User => "user",
        ChatRole::Assistant => "assistant",
    }
}

#[derive(Serialize)]
struct WireMessage<'a> {
    role: &'a str,
    content: &'a str,
}

#[derive(Serialize)]
struct WireRequest<'a> {
    model: &'a str,
    messages: Vec<WireMessage<'a>>,
}

/// Pure request-body builder — no network, so it's unit-testable directly
/// (DESIGN.md's fakes-over-mocks: exercise the wire shape without a server).
fn build_body(req: &CompletionRequest) -> WireRequest<'_> {
    WireRequest {
        model: &req.model,
        messages: req
            .messages
            .iter()
            .map(|m| WireMessage { role: role_str(m.role), content: &m.content })
            .collect(),
    }
}

#[derive(Deserialize)]
struct WireChoice {
    message: WireChoiceMessage,
}

#[derive(Deserialize)]
struct WireChoiceMessage {
    content: String,
}

#[derive(Deserialize)]
struct WireResponse {
    choices: Vec<WireChoice>,
}

/// Pure response parser — see `build_body`.
fn parse_completion(json: &str) -> Result<String, AiError> {
    let parsed: WireResponse =
        serde_json::from_str(json).map_err(|e| AiError::Provider(e.to_string()))?;
    parsed
        .choices
        .into_iter()
        .next()
        .map(|c| c.message.content)
        .ok_or_else(|| AiError::Provider("empty response".to_string()))
}

/// Map a non-2xx HTTP status to the right `AiError` variant.
fn map_status_error(status: u16, body: &str) -> AiError {
    match status {
        401 | 403 => AiError::AuthInvalid,
        429 => AiError::RateLimited { retry_after_secs: None },
        _ => AiError::Provider(format!("HTTP {status}: {}", body.chars().take(200).collect::<String>())),
    }
}

impl AiProvider for OpenAiProvider {
    fn id(&self) -> &str {
        "openai"
    }

    fn models(&self) -> Vec<ModelInfo> {
        Self::model_catalog()
    }

    async fn complete(&self, req: CompletionRequest) -> Result<String, AiError> {
        let body = build_body(&req);
        let resp = self
            .http
            .post(format!("{API_BASE}/chat/completions"))
            .bearer_auth(&self.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|e| AiError::Network(e.to_string()))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| AiError::Network(e.to_string()))?;
        if !status.is_success() {
            return Err(map_status_error(status.as_u16(), &text));
        }
        parse_completion(&text)
    }

    /// Free provider-native check: `GET /v1/models` needs a valid key but
    /// spends no completion tokens, unlike the trait's default `complete()`
    /// ping.
    async fn verify(&self) -> Result<(), AiError> {
        let resp = self
            .http
            .get(format!("{API_BASE}/models"))
            .bearer_auth(&self.api_key)
            .send()
            .await
            .map_err(|e| AiError::Network(e.to_string()))?;
        let status = resp.status();
        if status.is_success() {
            Ok(())
        } else {
            let text = resp.text().await.unwrap_or_default();
            Err(map_status_error(status.as_u16(), &text))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use heypigeon_core::ports::ChatMessage;

    #[test]
    fn build_body_maps_roles_and_preserves_order() {
        let req = CompletionRequest {
            model: "gpt-4o-mini".to_string(),
            messages: vec![
                ChatMessage { role: ChatRole::System, content: "be terse".to_string() },
                ChatMessage { role: ChatRole::User, content: "hi".to_string() },
            ],
        };
        let body = build_body(&req);
        assert_eq!(body.model, "gpt-4o-mini");
        assert_eq!(body.messages[0].role, "system");
        assert_eq!(body.messages[1].role, "user");
        assert_eq!(body.messages[1].content, "hi");
    }

    #[test]
    fn parse_completion_extracts_first_choice() {
        let json = r#"{"choices":[{"message":{"role":"assistant","content":"hello there"}}]}"#;
        assert_eq!(parse_completion(json).unwrap(), "hello there");
    }

    #[test]
    fn parse_completion_errors_on_empty_choices() {
        let json = r#"{"choices":[]}"#;
        assert!(matches!(parse_completion(json), Err(AiError::Provider(_))));
    }

    #[test]
    fn parse_completion_errors_on_garbage() {
        assert!(matches!(parse_completion("not json"), Err(AiError::Provider(_))));
    }

    #[test]
    fn map_status_error_distinguishes_auth_and_rate_limit() {
        assert!(matches!(map_status_error(401, ""), AiError::AuthInvalid));
        assert!(matches!(map_status_error(403, ""), AiError::AuthInvalid));
        assert!(matches!(map_status_error(429, ""), AiError::RateLimited { .. }));
        assert!(matches!(map_status_error(500, "boom"), AiError::Provider(_)));
    }

    #[test]
    fn curated_models_start_with_the_cost_default() {
        let p = OpenAiProvider::new("k".to_string());
        assert_eq!(p.models()[0].id, "gpt-4o-mini");
    }
}
