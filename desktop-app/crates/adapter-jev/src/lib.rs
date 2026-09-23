//! Jev decision-API adapter: hand-rolled client for JevTypeSafeAI.com's
//! `POST /v1/decide` endpoint (confirmed from that service's own docs at
//! https://jevtypesafeai.com/docs#decide).
//!
//! IMPORTANT: despite the name, JevTypeSafeAI.com states on its own docs
//! page "Independent service — not affiliated with or endorsed by TypeSafe
//! AI". It is NOT the vendor at typesafe.ai/docs.typesafe.ai (that site's
//! documented endpoint, api.typesafe.ai/v1/systemone, rejects keys issued
//! by this service and vice versa — verified live). The wire shapes
//! (Noul/Score/Choice questions + answers) happen to match closely enough
//! that this client only needed its base URL changed, not its types.
//!
//! Not an `AiProvider` — Jev returns typed judgments (Noul/Score), not chat
//! text, and there is exactly one implementation to abstract over, so this
//! stays a plain struct rather than a new port trait (DESIGN.md: a trait per
//! external dependency that realistically changes; nothing else earns one).
//! No third-party Jev crate either — the wire format is three JSON shapes,
//! smaller than trusting an unofficial, unmaintained community client.

use std::collections::HashMap;

use heypigeon_core::domain::{Priority, TriageLabel};
use serde::{Deserialize, Serialize};

const API_URL: &str = "https://jevtypesafeai.com/api/v1/decide";
const MODEL: &str = "jev-latest";

/// Ordered spam→high — index becomes the Score's numeric level (0..3),
/// which `priority_from_score` maps straight onto `Priority`'s own order.
const PRIORITY_CRITERIA: [&str; 4] = [
    "Spam or junk — promotional, phishing, or otherwise not worth the recipient's attention",
    "Low — informational, no action needed",
    "Medium — worth reading soon, not urgent",
    "High — needs prompt attention",
];

#[derive(Debug)]
pub enum JevError {
    AuthInvalid,
    RateLimited,
    Network(String),
    Provider(String),
}

impl std::fmt::Display for JevError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            JevError::AuthInvalid => write!(f, "invalid or revoked API key"),
            JevError::RateLimited => write!(f, "rate limited, retry later"),
            JevError::Network(e) => write!(f, "network: {e}"),
            JevError::Provider(e) => write!(f, "provider: {e}"),
        }
    }
}

impl std::error::Error for JevError {}

/// What one message contributes to the classification `state`. Subject +
/// snippet only — never the full body (Settings discloses exactly this).
pub struct ClassifyInput<'a> {
    pub subject: &'a str,
    pub snippet: &'a str,
    pub from: &'a str,
}

pub struct ClassifyResult {
    /// Ids of every user label Jev matched (Noul > 0.5) — zero or more.
    pub label_ids: Vec<String>,
    pub priority: Priority,
}

pub struct JevClassifier {
    http: reqwest::Client,
    api_key: String,
}

impl JevClassifier {
    pub fn new(api_key: String) -> Self {
        Self {
            http: reqwest::Client::new(),
            api_key,
        }
    }

    /// One Noul question per label plus one Score for priority, in a single
    /// request — Jev evaluates every question in a request in parallel, so
    /// this is already the cheap/batched shape (not one call per label).
    pub async fn classify(
        &self,
        input: &ClassifyInput<'_>,
        labels: &[TriageLabel],
    ) -> Result<ClassifyResult, JevError> {
        let body = build_body(input, labels);
        let resp = self
            .http
            .post(API_URL)
            .bearer_auth(&self.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|e| JevError::Network(e.to_string()))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| JevError::Network(e.to_string()))?;
        if !status.is_success() {
            return Err(map_status_error(status.as_u16(), &text));
        }
        parse_result(&text, labels)
    }

    /// Confirm the pasted key actually works — one trivial request (no
    /// labels), same shape as `AiProvider::verify`'s default.
    pub async fn verify(&self) -> Result<(), JevError> {
        let input = ClassifyInput {
            subject: "ping",
            snippet: "",
            from: "",
        };
        self.classify(&input, &[]).await.map(|_| ())
    }
}

#[derive(Serialize)]
struct WireRequest {
    state: String,
    model: &'static str,
    questions: HashMap<String, WireQuestion>,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum WireQuestion {
    Noul {
        instructions: String,
    },
    Score {
        instructions: String,
        criteria: Vec<String>,
    },
}

fn label_question_id(label_id: &str) -> String {
    format!("label:{label_id}")
}

/// Pure request-body builder — no network, unit-testable directly
/// (DESIGN.md's fakes-over-mocks: exercise the wire shape without a server).
fn build_body(input: &ClassifyInput<'_>, labels: &[TriageLabel]) -> WireRequest {
    let state = format!(
        "From: {}\nSubject: {}\n\n{}",
        input.from, input.subject, input.snippet
    );
    let mut questions = HashMap::with_capacity(labels.len() + 1);
    for label in labels {
        questions.insert(
            label_question_id(&label.id),
            WireQuestion::Noul {
                instructions: format!("Does this email belong in the '{}' category?", label.name),
            },
        );
    }
    questions.insert(
        "priority".to_string(),
        WireQuestion::Score {
            instructions: "How urgent or important is this email to the recipient?".to_string(),
            criteria: PRIORITY_CRITERIA.iter().map(|s| s.to_string()).collect(),
        },
    );
    WireRequest {
        state,
        model: MODEL,
        questions,
    }
}

#[derive(Deserialize)]
struct WireResponse {
    answers: HashMap<String, WireAnswer>,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum WireAnswer {
    Noul { noul: f64 },
    Score { score: f64 },
}

fn priority_from_score(score: f64) -> Priority {
    match score.round().clamp(0.0, 3.0) as i64 {
        0 => Priority::Spam,
        1 => Priority::Low,
        2 => Priority::Medium,
        _ => Priority::High,
    }
}

/// Pure response parser — see `build_body`.
fn parse_result(json: &str, labels: &[TriageLabel]) -> Result<ClassifyResult, JevError> {
    let parsed: WireResponse =
        serde_json::from_str(json).map_err(|e| JevError::Provider(e.to_string()))?;
    let label_ids = labels
        .iter()
        .filter(|l| {
            matches!(parsed.answers.get(&label_question_id(&l.id)), Some(WireAnswer::Noul { noul }) if *noul > 0.5)
        })
        .map(|l| l.id.clone())
        .collect();
    // A missing/malformed priority answer must not fail the whole
    // classification (labels are still useful) — default to the quiet end
    // (Low) rather than claim unearned urgency (Medium/High) on bad data.
    let priority = match parsed.answers.get("priority") {
        Some(WireAnswer::Score { score }) => priority_from_score(*score),
        _ => Priority::Low,
    };
    Ok(ClassifyResult {
        label_ids,
        priority,
    })
}

/// Map a non-2xx HTTP status to the right `JevError` variant.
fn map_status_error(status: u16, body: &str) -> JevError {
    match status {
        401 | 403 => JevError::AuthInvalid,
        429 | 529 => JevError::RateLimited,
        _ => JevError::Provider(format!(
            "HTTP {status}: {}",
            body.chars().take(200).collect::<String>()
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn label(id: &str, name: &str) -> TriageLabel {
        TriageLabel {
            id: id.to_string(),
            name: name.to_string(),
        }
    }

    #[test]
    fn build_body_has_one_noul_per_label_plus_priority() {
        let input = ClassifyInput {
            subject: "Invoice #42",
            snippet: "Payment due",
            from: "billing@x.com",
        };
        let labels = vec![label("1", "Bills"), label("2", "Work")];
        let body = build_body(&input, &labels);

        assert_eq!(body.model, "jev-latest");
        assert!(body.state.contains("Invoice #42"));
        assert!(body.state.contains("billing@x.com"));
        assert_eq!(body.questions.len(), 3, "2 labels + priority");
        assert!(matches!(
            body.questions.get("label:1"),
            Some(WireQuestion::Noul { .. })
        ));
        assert!(matches!(
            body.questions.get("label:2"),
            Some(WireQuestion::Noul { .. })
        ));
        match body.questions.get("priority") {
            Some(WireQuestion::Score { criteria, .. }) => assert_eq!(criteria.len(), 4),
            other => panic!("expected a Score question, got {other:?}"),
        }
    }

    impl std::fmt::Debug for WireQuestion {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            match self {
                WireQuestion::Noul { .. } => write!(f, "Noul"),
                WireQuestion::Score { .. } => write!(f, "Score"),
            }
        }
    }

    #[test]
    fn parse_result_includes_only_labels_above_half_probability() {
        let labels = vec![label("1", "Bills"), label("2", "Work")];
        let json = r#"{
            "model": "jev-1.13.0",
            "answers": {
                "label:1": {"type": "noul", "noul": 0.9},
                "label:2": {"type": "noul", "noul": 0.2},
                "priority": {"type": "score", "score": 1.4}
            },
            "usage": {"input_tokens": 10, "output_tokens": 5}
        }"#;
        let result = parse_result(json, &labels).unwrap();
        assert_eq!(result.label_ids, vec!["1".to_string()]);
        assert_eq!(result.priority, Priority::Low, "1.4 rounds to level 1");
    }

    #[test]
    fn parse_result_defaults_priority_when_missing() {
        let json =
            r#"{"model": "m", "answers": {}, "usage": {"input_tokens": 1, "output_tokens": 1}}"#;
        let result = parse_result(json, &[]).unwrap();
        assert!(result.label_ids.is_empty());
        assert_eq!(result.priority, Priority::Low);
    }

    #[test]
    fn parse_result_errors_on_garbage() {
        assert!(matches!(
            parse_result("not json", &[]),
            Err(JevError::Provider(_))
        ));
    }

    #[test]
    fn priority_from_score_rounds_to_nearest_level() {
        assert_eq!(priority_from_score(0.0), Priority::Spam);
        assert_eq!(priority_from_score(0.4), Priority::Spam);
        assert_eq!(priority_from_score(0.6), Priority::Low);
        assert_eq!(priority_from_score(1.5), Priority::Medium);
        assert_eq!(priority_from_score(2.5), Priority::High);
        assert_eq!(priority_from_score(3.0), Priority::High);
        assert_eq!(priority_from_score(-1.0), Priority::Spam, "clamped");
        assert_eq!(priority_from_score(5.0), Priority::High, "clamped");
    }

    #[test]
    fn map_status_error_distinguishes_auth_and_rate_limit() {
        assert!(matches!(map_status_error(401, ""), JevError::AuthInvalid));
        assert!(matches!(map_status_error(403, ""), JevError::AuthInvalid));
        assert!(matches!(map_status_error(429, ""), JevError::RateLimited));
        assert!(matches!(map_status_error(529, ""), JevError::RateLimited));
        assert!(matches!(
            map_status_error(500, "boom"),
            JevError::Provider(_)
        ));
    }

    /// Real network call against the live Jev API — not run by default (no
    /// key in CI). Opt in locally with a real key, e.g.:
    ///   doppler run --project hey-pigeon --config dev -- \
    ///     cargo test -p heypigeon-adapter-jev -- --ignored --nocapture
    #[tokio::test]
    #[ignore = "requires network + TYPESAFE_API_KEY"]
    async fn live_classify_against_real_api() {
        let api_key = std::env::var("TYPESAFE_API_KEY")
            .expect("set TYPESAFE_API_KEY to run this test (never hard-code it)");
        let classifier = JevClassifier::new(api_key);

        classifier
            .verify()
            .await
            .expect("verify() should succeed with a valid key");

        let labels = vec![label("1", "Bills"), label("2", "Newsletter")];
        let input = ClassifyInput {
            subject: "Your invoice #4471 is due",
            snippet:
                "Payment of $128.00 is due by Friday. Please remit at your earliest convenience.",
            from: "billing@utility-co.example",
        };
        let result = classifier
            .classify(&input, &labels)
            .await
            .expect("classify() should succeed with a valid key");

        // Not asserting exact model judgments (Jev is a live model, not a
        // fixture) — just that the response actually round-trips through
        // our wire types into a well-formed result.
        assert!(
            result
                .label_ids
                .iter()
                .all(|id| labels.iter().any(|l| &l.id == id)),
            "returned label ids must be a subset of the ones we asked about"
        );
        println!(
            "live Jev result: labels={:?} priority={:?}",
            result.label_ids, result.priority
        );
    }
}
