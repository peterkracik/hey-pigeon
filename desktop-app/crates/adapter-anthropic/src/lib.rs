//! Anthropic (Claude) adapter: implements `AiProvider` over the Messages
//! API with a pasted API key. Only this crate speaks Anthropic's wire
//! format — the core and the shells see the provider-agnostic trait.

use heypigeon_core::ports::{AiError, AiProvider, ChatRole, CompletionRequest, ModelInfo};
use serde::{Deserialize, Serialize};

const API_BASE: &str = "https://api.anthropic.com/v1";
const API_VERSION: &str = "2026-10-21";
/// Lets the API answer from another model when a safety classifier
/// declines a request, instead of an empty answer (Opus and Sonnet only).
const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";
/// Non-streaming ceiling: long enough for a draft, short enough to stay
/// under HTTP timeouts.
const MAX_TOKENS: u32 = 16_000;

/// The picker's list. First entry is the default.
const MODELS: &[(&str, &str)] = &[
    ("claude-opus-5-5", "Claude Opus 5.5 (default)"),
    ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
    ("claude-haiku-5-5", "Claude Haiku 5.5"),
];

pub struct AnthropicProvider {
    http: reqwest::Client,
    api_key: String,
}

/// The HTTP client every instance shares. A provider value is made per
/// call (the key is read from the keychain each time), and a client of
/// its own meant a new connection — a TLS handshake — for every request:
/// one per email during a triage pass.
fn http_client() -> reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT
        .get_or_init(|| {
            // A request that never answers used to hang the caller for
            // good: the shells showed a spinner nothing could cancel. Long
            // enough for a completion, short enough to come back with an error.
            reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(90))
                .build()
                .unwrap_or_default()
        })
        .clone()
}

impl AnthropicProvider {
    pub fn new(api_key: String) -> Self {
        Self {
            http: http_client(),
            api_key,
        }
    }

    /// Same list as `AiProvider::models()`, without an instance.
    pub fn model_catalog() -> Vec<ModelInfo> {
        MODELS
            .iter()
            .map(|(id, label)| ModelInfo {
                id: id.to_string(),
                label: label.to_string(),
            })
            .collect()
    }
}

#[derive(Serialize)]
struct WireMessage<'a> {
    role: &'a str,
    content: String,
}

#[derive(Serialize)]
struct WireRequest<'a> {
    model: &'a str,
    max_tokens: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    system: Option<String>,
    messages: Vec<WireMessage<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    fallbacks: Option<&'static str>,
}

/// Whether the model takes the server-side refusal fallback.
fn takes_fallback(model: &str) -> bool {
    model.starts_with("claude-opus-5") || model.starts_with("claude-sonnet-5-5")
}

/// Pure request-body builder. System messages go to the top-level
/// `system` field; the rest keep their order, consecutive turns of the
/// same role merged (the API wants them alternating, starting with user).
fn build_body(req: &CompletionRequest) -> WireRequest<'_> {
    let mut system = Vec::new();
    let mut messages: Vec<WireMessage> = Vec::new();
    for m in &req.messages {
        let role = match m.role {
            ChatRole::System => {
                system.push(m.content.as_str());
                continue;
            }
            ChatRole::User => "user",
            ChatRole::Assistant => "assistant",
        };
        match messages.last_mut() {
            Some(last) if last.role == role => {
                last.content.push_str("\n\n");
                last.content.push_str(&m.content);
            }
            _ => messages.push(WireMessage {
                role,
                content: m.content.clone(),
            }),
        }
    }
    WireRequest {
        model: &req.model,
        max_tokens: MAX_TOKENS,
        system: (!system.is_empty()).then(|| system.join("\n\n")),
        messages,
        fallbacks: takes_fallback(&req.model).then_some("default"),
    }
}

#[derive(Deserialize)]
struct WireBlock {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    text: String,
}

#[derive(Deserialize)]
struct WireResponse {
    #[serde(default)]
    content: Vec<WireBlock>,
    #[serde(default)]
    stop_reason: Option<String>,
}

/// Pure response parser: the text blocks joined (thinking blocks skipped).
fn parse_completion(json: &str) -> Result<String, AiError> {
    let parsed: WireResponse =
        serde_json::from_str(json).map_err(|e| AiError::Provider(e.to_string()))?;
    if parsed.stop_reason.as_deref() == Some("refusal") {
        return Err(AiError::Provider("Claude declined this request".into()));
    }
    let text: Vec<String> = parsed
        .content
        .into_iter()
        .filter(|b| b.kind == "text")
        .map(|b| b.text)
        .collect();
    if text.is_empty() {
        return Err(AiError::Provider("empty response".to_string()));
    }
    Ok(text.join(""))
}

fn map_status_error(status: u16, body: &str) -> AiError {
    match status {
        401 | 403 => AiError::AuthInvalid,
        429 => AiError::RateLimited {
            retry_after_secs: None,
        },
        _ => AiError::Provider(format!(
            "HTTP {status}: {}",
            body.chars().take(200).collect::<String>()
        )),
    }
}

impl AiProvider for AnthropicProvider {
    fn id(&self) -> &str {
        "anthropic"
    }

    fn models(&self) -> Vec<ModelInfo> {
        Self::model_catalog()
    }

    async fn complete(&self, req: CompletionRequest) -> Result<String, AiError> {
        let body = build_body(&req);
        let mut request = self
            .http
            .post(format!("{API_BASE}/messages"))
            .header("x-api-key", &self.api_key)
            .header("anthropic-version", API_VERSION);
        if body.fallbacks.is_some() {
            request = request.header("anthropic-beta", FALLBACK_BETA);
        }
        let resp = request
            .json(&body)
            .send()
            .await
            .map_err(|e| AiError::Network(e.to_string()))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| AiError::Network(e.to_string()))?;
        if !status.is_success() {
            return Err(map_status_error(status.as_u16(), &text));
        }
        parse_completion(&text)
    }

    /// `GET /v1/models` needs a valid key and spends no tokens.
    async fn verify(&self) -> Result<(), AiError> {
        let resp = self
            .http
            .get(format!("{API_BASE}/models"))
            .header("x-api-key", &self.api_key)
            .header("anthropic-version", API_VERSION)
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

    fn msg(role: ChatRole, content: &str) -> ChatMessage {
        ChatMessage {
            role,
            content: content.to_string(),
        }
    }

    #[test]
    fn system_moves_to_the_top_level_and_same_role_turns_merge() {
        let req = CompletionRequest {
            model: "claude-haiku-5-5".to_string(),
            messages: vec![
                msg(ChatRole::System, "be terse"),
                msg(ChatRole::User, "a"),
                msg(ChatRole::User, "b"),
            ],
        };
        let body = build_body(&req);
        assert_eq!(body.system.as_deref(), Some("be terse"));
        assert_eq!(body.messages.len(), 1);
        assert_eq!(body.messages[0].role, "user");
        assert_eq!(body.messages[0].content, "a\n\nb");
        assert!(body.fallbacks.is_none());
        let json = serde_json::to_value(&body).unwrap();
        assert!(json.get("temperature").is_none());
    }

    #[test]
    fn opus_and_sonnet_ask_for_the_refusal_fallback() {
        for model in ["claude-opus-5-5", "claude-sonnet-5-5"] {
            let req = CompletionRequest {
                model: model.to_string(),
                messages: vec![msg(ChatRole::User, "hi")],
            };
            assert_eq!(build_body(&req).fallbacks, Some("default"));
        }
    }

    #[test]
    fn parse_completion_joins_text_blocks_and_skips_thinking() {
        let json = r#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"hello"},{"type":"text","text":" there"}],"stop_reason":"end_turn"}"#;
        assert_eq!(parse_completion(json).unwrap(), "hello there");
    }

    #[test]
    fn parse_completion_errors_on_refusal_and_empty() {
        let refused = r#"{"content":[],"stop_reason":"refusal"}"#;
        assert!(matches!(
            parse_completion(refused),
            Err(AiError::Provider(_))
        ));
        assert!(matches!(
            parse_completion(r#"{"content":[]}"#),
            Err(AiError::Provider(_))
        ));
        assert!(parse_completion("nope").is_err());
    }

    #[test]
    fn map_status_error_distinguishes_auth_and_rate_limit() {
        assert!(matches!(map_status_error(401, ""), AiError::AuthInvalid));
        assert!(matches!(
            map_status_error(429, ""),
            AiError::RateLimited { .. }
        ));
        assert!(matches!(map_status_error(529, ""), AiError::Provider(_)));
    }

    #[test]
    fn catalog_starts_with_the_default() {
        assert_eq!(AnthropicProvider::model_catalog()[0].id, "claude-opus-5-5");
    }
}
