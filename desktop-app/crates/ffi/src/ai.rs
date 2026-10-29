//! The on-device AI door (docs/ios-intelligence.md, step 5).
//!
//! `core::ports::AiProvider` is a Rust trait and Apple's Foundation Models
//! is a Swift framework, so the on-device provider is Swift code the core
//! calls back into: the shell implements [`AiBackend`] (a UniFFI foreign
//! trait, like `EngineListener`) and hands it to `Engine::set_ai_backend`;
//! [`ForeignAiProvider`] wraps it as an `AiProvider`, so the summary, draft
//! and edit paths in `settings.rs` never learn which side of the bridge
//! answered. The same backend classifies for triage, so a device with Apple
//! Intelligence needs no key for anything.

use std::sync::Arc;

use heypigeon_core::ports::{AiError, AiProvider, ChatRole, CompletionRequest, ModelInfo};

use crate::types::*;

/// Provider id of the shell's on-device backend (`pref:ai.provider`).
pub const APPLE_PROVIDER: &str = "apple";
/// Provider id of Apple's Private Cloud Compute model, registered by the
/// shell as a second backend when the device can reach it (iOS 27).
pub const APPLE_CLOUD_PROVIDER: &str = "apple-cloud";
/// The foreign (shell-side) provider ids the settings accept even when the
/// shell has not registered them on this device: the choice is a synced
/// preference, and another device may well have the backend.
pub const FOREIGN_PROVIDERS: &[&str] = &[APPLE_PROVIDER, APPLE_CLOUD_PROVIDER];

/// Implemented on the Swift side over `LanguageModelSession`. Called from
/// engine threads; the implementation hops to whatever actor it needs. The
/// shell registers one backend per provider it can offer (`id()`: "apple"
/// for the on-device model, "apple-cloud" for Private Cloud Compute, …)
/// through `Engine::add_ai_backend`.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait AiBackend: Send + Sync {
    /// Stable id, e.g. "apple".
    fn id(&self) -> String;
    /// What Settings shows as the model: one entry for the system model.
    fn models(&self) -> Vec<AiModel>;
    /// One completion: a system instruction and one user prompt, the whole
    /// answer back. The backend owns the context-window handling (chunking
    /// a prompt that does not fit, never an error for a long thread).
    async fn complete(&self, system: String, user: String) -> Result<String, EngineError>;
    /// Triage one email against the user's labels: a priority and the ids
    /// of the labels that apply (zero or more), as structured output.
    async fn classify(
        &self,
        subject: String,
        snippet: String,
        from: String,
        labels: Vec<TriageLabel>,
    ) -> Result<TriageVerdict, EngineError>;
}

/// The core's view of the shell's backend.
pub(crate) struct ForeignAiProvider {
    backend: Arc<dyn AiBackend>,
    id: String,
}

impl ForeignAiProvider {
    pub(crate) fn new(backend: Arc<dyn AiBackend>) -> Self {
        let id = backend.id();
        Self { backend, id }
    }
}

impl AiProvider for ForeignAiProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn models(&self) -> Vec<ModelInfo> {
        self.backend
            .models()
            .into_iter()
            .map(|m| ModelInfo {
                id: m.id,
                label: m.label,
            })
            .collect()
    }

    /// The backend takes one system + one user string: system messages are
    /// joined into the instruction, everything else into the prompt in
    /// order, which is exactly the shape every caller in `settings.rs`
    /// builds anyway.
    async fn complete(&self, req: CompletionRequest) -> Result<String, AiError> {
        let mut system = Vec::new();
        let mut user = Vec::new();
        for m in req.messages {
            match m.role {
                ChatRole::System => system.push(m.content),
                ChatRole::User | ChatRole::Assistant => user.push(m.content),
            }
        }
        self.backend
            .complete(system.join("\n\n"), user.join("\n\n"))
            .await
            .map_err(|e| AiError::Provider(e.to_string()))
    }

    /// The shell already knows whether the model is available before it
    /// hands the backend over; nothing to spend here.
    async fn verify(&self) -> Result<(), AiError> {
        Ok(())
    }
}

#[cfg(test)]
pub(crate) mod fakes {
    use super::*;
    use std::sync::Mutex;

    /// A backend that answers from a script and records what it was asked.
    pub(crate) struct ScriptedBackend {
        pub(crate) provider_id: String,
        pub(crate) completions: Mutex<Vec<(String, String)>>,
        pub(crate) classifications: Mutex<Vec<String>>,
        pub(crate) verdict: TriageVerdict,
        pub(crate) answer: String,
    }

    impl ScriptedBackend {
        pub(crate) fn new(answer: &str, verdict: TriageVerdict) -> Arc<Self> {
            Self::with_id(APPLE_PROVIDER, answer, verdict)
        }

        pub(crate) fn with_id(
            provider_id: &str,
            answer: &str,
            verdict: TriageVerdict,
        ) -> Arc<Self> {
            Arc::new(Self {
                provider_id: provider_id.to_string(),
                completions: Mutex::new(Vec::new()),
                classifications: Mutex::new(Vec::new()),
                verdict,
                answer: answer.to_string(),
            })
        }
    }

    #[async_trait::async_trait]
    impl AiBackend for ScriptedBackend {
        fn id(&self) -> String {
            self.provider_id.clone()
        }
        fn models(&self) -> Vec<AiModel> {
            vec![AiModel {
                id: format!("{}-model", self.provider_id),
                label: "On this device".into(),
            }]
        }
        async fn complete(&self, system: String, user: String) -> Result<String, EngineError> {
            self.completions.lock().unwrap().push((system, user));
            Ok(self.answer.clone())
        }
        async fn classify(
            &self,
            subject: String,
            _snippet: String,
            _from: String,
            _labels: Vec<TriageLabel>,
        ) -> Result<TriageVerdict, EngineError> {
            self.classifications.lock().unwrap().push(subject);
            Ok(self.verdict.clone())
        }
    }
}
