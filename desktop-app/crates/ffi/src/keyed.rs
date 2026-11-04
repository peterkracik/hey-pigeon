//! The providers the user brings an API key (token) for: ChatGPT
//! (OpenAI), Claude (Anthropic) and Gemini (Google). One enum over the
//! three adapter crates so `settings.rs` routes by id and never learns a
//! wire format. Keys sit in the device's secret store under
//! `ai.<id>.api_key` and never sync; the model each one uses is a synced
//! preference. They also classify for triage — only when the user picks
//! one as the classifier, never as a silent fallback — from the same
//! subject, sender and preview the Apple models and Jev see.

use heypigeon_adapter_anthropic::AnthropicProvider;
use heypigeon_adapter_gemini::GeminiProvider;
use heypigeon_adapter_openai::OpenAiProvider;
use heypigeon_core::domain::TriageLabel;
use heypigeon_core::ports::{
    AiError, AiProvider, ChatMessage, ChatRole, CompletionRequest, ModelInfo,
};

use crate::types::Priority;

/// Ids in the default fallback order (after the Apple models).
pub(crate) const KEYED_PROVIDERS: &[&str] = &["openai", "anthropic", "gemini"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Keyed {
    OpenAi,
    Anthropic,
    Gemini,
}

impl Keyed {
    pub(crate) fn from_id(id: &str) -> Option<Self> {
        match id {
            "openai" => Some(Self::OpenAi),
            "anthropic" => Some(Self::Anthropic),
            "gemini" => Some(Self::Gemini),
            _ => None,
        }
    }

    pub(crate) fn id(self) -> &'static str {
        match self {
            Self::OpenAi => "openai",
            Self::Anthropic => "anthropic",
            Self::Gemini => "gemini",
        }
    }

    /// Where this device keeps the key ("ai.openai.api_key" predates the
    /// other two and keeps its name).
    pub(crate) fn key_secret(self) -> String {
        format!("ai.{}.api_key", self.id())
    }

    /// The synced model preference. OpenAI keeps the original `ai.model`
    /// so a model picked before the other providers existed still holds.
    pub(crate) fn model_pref(self) -> &'static str {
        match self {
            Self::OpenAi => "ai.model",
            Self::Anthropic => "ai.model.anthropic",
            Self::Gemini => "ai.model.gemini",
        }
    }

    pub(crate) fn catalog(self) -> Vec<ModelInfo> {
        match self {
            Self::OpenAi => OpenAiProvider::model_catalog(),
            Self::Anthropic => AnthropicProvider::model_catalog(),
            Self::Gemini => GeminiProvider::model_catalog(),
        }
    }

    pub(crate) fn default_model(self) -> String {
        self.catalog()
            .into_iter()
            .next()
            .map(|m| m.id)
            .unwrap_or_default()
    }

    pub(crate) async fn verify(self, key: String) -> Result<(), AiError> {
        match self {
            Self::OpenAi => OpenAiProvider::new(key).verify().await,
            Self::Anthropic => AnthropicProvider::new(key).verify().await,
            Self::Gemini => GeminiProvider::new(key).verify().await,
        }
    }

    pub(crate) async fn complete(
        self,
        key: String,
        req: CompletionRequest,
    ) -> Result<String, AiError> {
        match self {
            Self::OpenAi => OpenAiProvider::new(key).complete(req).await,
            Self::Anthropic => AnthropicProvider::new(key).complete(req).await,
            Self::Gemini => GeminiProvider::new(key).complete(req).await,
        }
    }

    /// Triage one email: a priority and the ids of the labels that apply.
    pub(crate) async fn classify(
        self,
        key: String,
        model: String,
        input: ClassifyEmail<'_>,
        labels: &[TriageLabel],
    ) -> Result<(Vec<String>, Priority), AiError> {
        let req = CompletionRequest {
            model,
            messages: vec![
                ChatMessage {
                    role: ChatRole::System,
                    content: CLASSIFY_SYSTEM_PROMPT.to_string(),
                },
                ChatMessage {
                    role: ChatRole::User,
                    content: classify_prompt(&input, labels),
                },
            ],
        };
        let answer = self.complete(key, req).await?;
        parse_verdict(&answer, labels)
    }
}

/// What a keyed classifier sees: the same three fields as Jev and the
/// Apple models, never the body.
pub(crate) struct ClassifyEmail<'a> {
    pub subject: &'a str,
    pub snippet: &'a str,
    pub from: &'a str,
}

/// The Swift classifier's instruction (ios-app/HeyPigeon/AI/TriagePrompt.swift,
/// `shipped`), plus the JSON shape a plain completion has to answer in.
pub(crate) const CLASSIFY_SYSTEM_PROMPT: &str = "You sort one email for a busy person. Decide its priority — spam (junk, phishing, promotions), low (informational, no action), medium (worth reading soon), high (needs prompt attention) — and which of the person's own labels apply, if any. Only use labels from the list given. Judge from the sender, subject and preview only.\n\nAnswer with one JSON object and nothing else: {\"priority\": \"spam\" | \"low\" | \"medium\" | \"high\", \"labels\": [label names from the list]}";

fn classify_prompt(input: &ClassifyEmail<'_>, labels: &[TriageLabel]) -> String {
    let names: Vec<&str> = labels.iter().map(|l| l.name.as_str()).collect();
    format!(
        "From: {}\nSubject: {}\nPreview: {}\nAvailable labels: {}",
        input.from,
        input.subject,
        input.snippet,
        if names.is_empty() {
            "(none)".to_string()
        } else {
            names.join(", ")
        }
    )
}

#[derive(serde::Deserialize)]
struct WireVerdict {
    priority: String,
    #[serde(default)]
    labels: Vec<String>,
}

/// The model's JSON (fenced or not) to label ids and a priority. Names
/// match without case, each once; names not in the list are dropped.
pub(crate) fn parse_verdict(
    answer: &str,
    labels: &[TriageLabel],
) -> Result<(Vec<String>, Priority), AiError> {
    let start = answer.find('{');
    let end = answer.rfind('}');
    let json = match (start, end) {
        (Some(s), Some(e)) if e > s => &answer[s..=e],
        _ => return Err(AiError::Provider("classifier answered without JSON".into())),
    };
    let v: WireVerdict =
        serde_json::from_str(json).map_err(|e| AiError::Provider(e.to_string()))?;
    let priority = match v.priority.trim().to_ascii_lowercase().as_str() {
        "spam" => Priority::Spam,
        "low" => Priority::Low,
        "medium" => Priority::Medium,
        "high" => Priority::High,
        other => return Err(AiError::Provider(format!("unknown priority {other}"))),
    };
    let mut ids: Vec<String> = Vec::new();
    for name in &v.labels {
        if let Some(l) = labels
            .iter()
            .find(|l| l.name.eq_ignore_ascii_case(name.trim()))
        {
            if !ids.contains(&l.id) {
                ids.push(l.id.clone());
            }
        }
    }
    Ok((ids, priority))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn label(id: &str, name: &str) -> TriageLabel {
        TriageLabel {
            id: id.into(),
            name: name.into(),
        }
    }

    #[test]
    fn ids_secrets_and_prefs() {
        for id in KEYED_PROVIDERS {
            let k = Keyed::from_id(id).unwrap();
            assert_eq!(k.id(), *id);
            assert!(!k.catalog().is_empty());
        }
        assert!(Keyed::from_id("apple").is_none());
        assert_eq!(Keyed::OpenAi.key_secret(), "ai.openai.api_key");
        assert_eq!(Keyed::OpenAi.model_pref(), "ai.model");
        assert_eq!(Keyed::Anthropic.model_pref(), "ai.model.anthropic");
    }

    #[test]
    fn verdicts_map_names_to_known_ids_once() {
        let labels = [label("a", "Invoices"), label("b", "Travel")];
        let answer = "```json\n{\"priority\": \"High\", \"labels\": [\"invoices\", \"Travel\", \"Invoices\", \"Nope\"]}\n```";
        let (ids, p) = parse_verdict(answer, &labels).unwrap();
        assert_eq!(ids, vec!["a", "b"]);
        assert_eq!(p, Priority::High);
        let (ids, p) = parse_verdict("{\"priority\":\"spam\"}", &labels).unwrap();
        assert!(ids.is_empty());
        assert_eq!(p, Priority::Spam);
        assert!(parse_verdict("no json here", &labels).is_err());
        assert!(parse_verdict("{\"priority\":\"urgent\"}", &labels).is_err());
    }

    #[test]
    fn prompt_names_the_labels_and_never_a_body() {
        let input = ClassifyEmail {
            subject: "S",
            snippet: "P",
            from: "x@y",
        };
        assert!(classify_prompt(&input, &[]).contains("Available labels: (none)"));
        assert!(classify_prompt(&input, &[label("a", "Invoices")]).contains("Invoices"));
    }
}
