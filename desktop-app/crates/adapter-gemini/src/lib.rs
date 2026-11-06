//! Google Gemini adapter: implements `AiProvider` over the Gemini API's
//! `generateContent` with a pasted API key. Only this crate speaks
//! Google's wire format.

use heypigeon_core::ports::{AiError, AiProvider, ChatRole, CompletionRequest, ModelInfo};
use serde::{Deserialize, Serialize};

const API_BASE: &str = "https://generativelanguage.googleapis.com/v1beta";

/// The picker's list. First entry is the default (cost).
const MODELS: &[(&str, &str)] = &[
    ("gemini-2.5-flash", "Gemini 2.5 Flash (default)"),
    ("gemini-2.5-pro", "Gemini 2.5 Pro"),
    ("gemini-2.5-flash-lite", "Gemini 2.5 Flash-Lite"),
];

pub struct GeminiProvider {
    http: reqwest::Client,
    api_key: String,
}

impl GeminiProvider {
    pub fn new(api_key: String) -> Self {
        Self {
            // A request that never answers used to hang the caller for
            // good: the shells showed a spinner nothing could cancel. Long
            // enough for a completion, short enough to come back with an error.
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(90))
                .build()
                .unwrap_or_default(),
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
struct WirePart {
    text: String,
}

#[derive(Serialize)]
struct WireContent {
    #[serde(skip_serializing_if = "Option::is_none")]
    role: Option<&'static str>,
    parts: Vec<WirePart>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    system_instruction: Option<WireContent>,
    contents: Vec<WireContent>,
}

/// Pure request-body builder: system messages become the
/// `systemInstruction`, the rest `contents` ("model" is Gemini's
/// assistant role).
fn build_body(req: &CompletionRequest) -> WireRequest {
    let mut system = Vec::new();
    let mut contents = Vec::new();
    for m in &req.messages {
        let role = match m.role {
            ChatRole::System => {
                system.push(WirePart {
                    text: m.content.clone(),
                });
                continue;
            }
            ChatRole::User => "user",
            ChatRole::Assistant => "model",
        };
        contents.push(WireContent {
            role: Some(role),
            parts: vec![WirePart {
                text: m.content.clone(),
            }],
        });
    }
    WireRequest {
        system_instruction: (!system.is_empty()).then_some(WireContent {
            role: None,
            parts: system,
        }),
        contents,
    }
}

#[derive(Deserialize)]
struct WireRespPart {
    #[serde(default)]
    text: String,
}

#[derive(Deserialize)]
struct WireRespContent {
    #[serde(default)]
    parts: Vec<WireRespPart>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireCandidate {
    #[serde(default)]
    content: Option<WireRespContent>,
    #[serde(default)]
    finish_reason: Option<String>,
}

#[derive(Deserialize)]
struct WireResponse {
    #[serde(default)]
    candidates: Vec<WireCandidate>,
}

/// Pure response parser: the first candidate's text parts joined.
fn parse_completion(json: &str) -> Result<String, AiError> {
    let parsed: WireResponse =
        serde_json::from_str(json).map_err(|e| AiError::Provider(e.to_string()))?;
    let Some(first) = parsed.candidates.into_iter().next() else {
        return Err(AiError::Provider("empty response".to_string()));
    };
    let text: String = first
        .content
        .map(|c| c.parts.into_iter().map(|p| p.text).collect())
        .unwrap_or_default();
    if text.is_empty() {
        let why = first.finish_reason.unwrap_or_else(|| "empty".into());
        return Err(AiError::Provider(format!("no answer ({why})")));
    }
    Ok(text)
}

fn map_status_error(status: u16, body: &str) -> AiError {
    // Gemini answers a bad key with 400 API_KEY_INVALID, not 401.
    if status == 400 && body.contains("API_KEY_INVALID") {
        return AiError::AuthInvalid;
    }
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

impl AiProvider for GeminiProvider {
    fn id(&self) -> &str {
        "gemini"
    }

    fn models(&self) -> Vec<ModelInfo> {
        Self::model_catalog()
    }

    async fn complete(&self, req: CompletionRequest) -> Result<String, AiError> {
        let body = build_body(&req);
        let resp = self
            .http
            .post(format!("{API_BASE}/models/{}:generateContent", req.model))
            .header("x-goog-api-key", &self.api_key)
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

    /// Listing models needs a valid key and spends no tokens.
    async fn verify(&self) -> Result<(), AiError> {
        let resp = self
            .http
            .get(format!("{API_BASE}/models"))
            .header("x-goog-api-key", &self.api_key)
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
    fn build_body_splits_system_and_names_the_model_role() {
        let req = CompletionRequest {
            model: "gemini-2.5-flash".to_string(),
            messages: vec![
                ChatMessage {
                    role: ChatRole::System,
                    content: "be terse".to_string(),
                },
                ChatMessage {
                    role: ChatRole::User,
                    content: "hi".to_string(),
                },
                ChatMessage {
                    role: ChatRole::Assistant,
                    content: "hello".to_string(),
                },
            ],
        };
        let json = serde_json::to_value(build_body(&req)).unwrap();
        assert_eq!(json["systemInstruction"]["parts"][0]["text"], "be terse");
        assert!(json["systemInstruction"].get("role").is_none());
        assert_eq!(json["contents"][0]["role"], "user");
        assert_eq!(json["contents"][1]["role"], "model");
    }

    #[test]
    fn parse_completion_joins_parts() {
        let json = r#"{"candidates":[{"content":{"parts":[{"text":"hello"},{"text":" there"}],"role":"model"},"finishReason":"STOP"}]}"#;
        assert_eq!(parse_completion(json).unwrap(), "hello there");
    }

    #[test]
    fn parse_completion_errors_on_blocked_or_empty() {
        let blocked = r#"{"candidates":[{"finishReason":"SAFETY"}]}"#;
        let err = parse_completion(blocked).unwrap_err().to_string();
        assert!(err.contains("SAFETY"));
        assert!(parse_completion(r#"{"candidates":[]}"#).is_err());
        assert!(parse_completion("nope").is_err());
    }

    #[test]
    fn map_status_error_knows_geminis_bad_key() {
        assert!(matches!(
            map_status_error(
                400,
                r#"{"error":{"status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#
            ),
            AiError::AuthInvalid
        ));
        assert!(matches!(
            map_status_error(400, "other"),
            AiError::Provider(_)
        ));
        assert!(matches!(
            map_status_error(429, ""),
            AiError::RateLimited { .. }
        ));
    }

    #[test]
    fn catalog_starts_with_the_default() {
        assert_eq!(GeminiProvider::model_catalog()[0].id, "gemini-2.5-flash");
    }
}
