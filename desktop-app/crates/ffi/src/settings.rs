//! The Settings surface of the engine: per-account edits, the AI provider
//! (BYO OpenAI key), and Jev auto-triage with its local labels. Mirrors
//! `src-tauri/src/ai.rs` + `autolabel.rs` + `mail::update_account` one to
//! one so the phone's Settings screen is the desktop's.

use std::sync::Arc;

use heypigeon_adapter_jev::{ClassifyInput, JevClassifier};
use heypigeon_adapter_openai::OpenAiProvider;
use heypigeon_core::devsync;
use heypigeon_core::domain::now_ms;
use heypigeon_core::ports::{
    AiProvider, ChatMessage, ChatRole, CompletionRequest, SecretStore, Store,
};

use crate::engine::{Engine, ACCOUNT_COLORS, BACKFILL_DAYS};
use crate::types::*;

const AI_PROVIDER: &str = "openai";
const AI_KEY: &str = "ai.openai.api_key";
const JEV_KEY: &str = "triage.jev.api_key";
/// The selected model and the triage switch are synced preferences
/// (`pref:ai.model`, `pref:triage.enabled`), not secrets: the keys stay
/// per device, these choices follow the user. Both lived in the secret
/// store before settings synced — `migrate_legacy_prefs` moves them once.
const AI_MODEL_PREF: &str = "ai.model";
const TRIAGE_ENABLED_PREF: &str = "triage.enabled";
const LEGACY_AI_MODEL_SECRET: &str = "ai.openai.model";
const LEGACY_TRIAGE_ENABLED_SECRET: &str = "triage.enabled";

/// One-time move of the two prefs that used to sit in the secret store.
/// Called from `Engine::open`; a pref already set wins over the legacy
/// value (it may have arrived from another device).
pub(crate) fn migrate_legacy_prefs(store: &impl Store, secrets: &dyn SecretStore) {
    let moves: [(&str, &str, fn(String) -> serde_json::Value); 2] = [
        (
            AI_MODEL_PREF,
            LEGACY_AI_MODEL_SECRET,
            serde_json::Value::String,
        ),
        (TRIAGE_ENABLED_PREF, LEGACY_TRIAGE_ENABLED_SECRET, |raw| {
            serde_json::Value::Bool(raw == "true")
        }),
    ];
    for (pref, secret, convert) in moves {
        if let (Ok(None), Ok(Some(raw))) = (store.get_pref(pref), secrets.get(secret)) {
            match store.set_pref(pref, Some(&convert(raw))) {
                Ok(()) => {
                    let _ = secrets.delete(secret);
                }
                Err(e) => log::warn!("settings: could not migrate {pref}: {e}"),
            }
        }
    }
}

/// Threads classified per sync round. Bounded so one large inbox cannot
/// turn a refresh into a multi-minute Jev round; the next round continues.
const TRIAGE_BATCH: u32 = 10;

// The prompts are copied verbatim from the desktop shell (src-tauri/src/ai.rs)
// so both apps get the same voice from the same model. The two summary
// prompts ask for a tiny markdown subset ("- " bullets + **bold**) that
// SummaryMarkup.swift renders on iOS, as SummaryText.svelte does on desktop.
const EDIT_SYSTEM_PROMPT: &str = "You are an email writing assistant. You may be given the prior conversation for context — use it to answer questions or reference details the user asks for. Apply the user's instruction to the given text and return ONLY the revised text — no preamble, no explanation, no markdown formatting, no surrounding quotes.";
const SUMMARY_SYSTEM_PROMPT: &str = "You write a factual digest of the user's active (not yet done) emails. Informational only: state what each email is and what it contains, in a neutral third-person tone. No greetings, no opinions, no advice, no questions, no chit-chat.\n\nFormat rules:\n- Return 1 to 4 bullet points, each on its own line starting with \"- \".\n- One bullet per notable email or theme; merge similar emails into one bullet (e.g. \"3 newsletters\").\n- Keep each bullet to one short sentence or fragment.\n- Wrap the key facts in **double asterisks** for bold: sender or company names, amounts, dates, deadlines, order or invoice numbers.\n- Use only \"- \" bullets and **bold**. No headers, no other markdown, no preamble, no closing line.\n- If nothing is notable, return a single bullet: \"- Nothing notable.\"";
const THREAD_SUMMARY_SYSTEM_PROMPT: &str = "You write a factual recap of one email conversation so the reader does not have to read every message. Informational only: who said what, what was asked, what was agreed, and the current state. Neutral, report-style tone; refer to the user (labelled \"Me\" in the transcript) as \"you\". No greetings, no opinions, no advice, no questions, no chit-chat.\n\nFormat rules:\n- Return 1 to 4 bullet points, each on its own line starting with \"- \".\n- Keep each bullet to one short sentence or fragment.\n- The last bullet states the current status or open item (e.g. **Waiting on** a reply, a **deadline**, a **decision**).\n- Wrap the key facts in **double asterisks** for bold: people's names, amounts, dates, deadlines, decisions.\n- Use only \"- \" bullets and **bold**. No headers, no other markdown, no preamble, no closing line.";
const DRAFT_REPLY_SYSTEM_PROMPT: &str = "You are drafting an email reply on behalf of the user, who appears as \"Me\" in the conversation transcript. Write the reply to the latest message from the other participant(s): answer their questions, respond to their requests, and keep the user's established tone from any earlier \"Me\" messages. Be concise and natural. Never invent facts, dates, or commitments the conversation does not support — put a short placeholder in square brackets where the user must fill something in. If the user provided notes, build the reply around them. Return ONLY the reply body as plain text: no subject line, no markdown, no explanation, no surrounding quotes, and no signature block.";

fn build_draft_reply_prompt(subject: &str, history: &str, notes: Option<&str>) -> String {
    let mut out = format!("Subject: {subject}\n\nConversation so far (oldest first):\n{history}");
    if let Some(n) = notes.map(str::trim).filter(|n| !n.is_empty()) {
        out.push_str("\n\nNotes from the user for this reply:\n");
        out.push_str(n);
    }
    out.push_str("\n\nWrite the reply.");
    out
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

fn build_summary_prompt(items: &[SummaryItem]) -> String {
    items
        .iter()
        .map(|i| format!("From: {}\nSubject: {}\n{}", i.from, i.subject, i.snippet))
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn ai_err(e: impl std::fmt::Display) -> EngineError {
    EngineError::Ai(e.to_string())
}

fn check_provider(provider_id: &str) -> Result<(), EngineError> {
    if provider_id == AI_PROVIDER {
        Ok(())
    } else {
        Err(EngineError::Invalid(format!(
            "unknown AI provider {provider_id}"
        )))
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl Engine {
    // ------------------------------------------------------------ accounts

    /// Update per-account settings: display name, colour (one of the five
    /// tags), signature. `None` leaves a field unchanged.
    pub fn update_account(
        self: &Arc<Self>,
        account_id: String,
        display_name: Option<String>,
        color: Option<String>,
        signature: Option<String>,
    ) -> Result<(), EngineError> {
        if let Some(c) = &color {
            if !ACCOUNT_COLORS.contains(&c.as_str()) {
                return Err(EngineError::Invalid(format!("unknown color {c}")));
            }
        }
        let mut account = self
            .store
            .list_accounts()?
            .into_iter()
            .find(|a| a.id == account_id)
            .ok_or_else(|| EngineError::Invalid(format!("unknown account {account_id}")))?;
        // Every field that actually changed is recorded for the user's
        // other devices (`account:<field>` keys on this account's file).
        let mut changed: Vec<(&str, String)> = Vec::new();
        if let Some(n) = display_name {
            let n = n.trim().to_string();
            if !n.is_empty() && n != account.display_name {
                account.display_name = n.clone();
                changed.push((devsync::ACCOUNT_FIELD_DISPLAY_NAME, n));
            }
        }
        if let Some(c) = color {
            if c != account.color {
                account.color = c.clone();
                changed.push((devsync::ACCOUNT_FIELD_COLOR, c));
            }
        }
        if let Some(s) = signature {
            if s != account.signature {
                account.signature = s.clone();
                changed.push((devsync::ACCOUNT_FIELD_SIGNATURE, s));
            }
        }
        if changed.is_empty() {
            return Ok(());
        }
        self.store.upsert_account(&account)?;
        for (field, value) in &changed {
            devsync::record_account_field(&self.store, &account_id, field, value)?;
        }
        self.notify_threads_updated();
        self.push_devsync_later(account_id);
        Ok(())
    }

    // ------------------------------------------------------------ AI (OpenAI)

    pub fn ai_status(&self) -> Result<AiStatus, EngineError> {
        let configured = matches!(self.secrets.get(AI_KEY), Ok(Some(_)));
        Ok(AiStatus {
            configured,
            provider_id: configured.then(|| AI_PROVIDER.to_string()),
            model: self.stored_model()?,
        })
    }

    /// Static catalogue; no key needed.
    pub fn ai_models(&self, provider_id: String) -> Result<Vec<AiModel>, EngineError> {
        check_provider(&provider_id)?;
        Ok(OpenAiProvider::model_catalog()
            .into_iter()
            .map(|m| AiModel {
                id: m.id,
                label: m.label,
            })
            .collect())
    }

    /// Verify a pasted key with one live call before persisting it, so a
    /// typo or a revoked key never gets saved.
    pub async fn set_ai_key(
        &self,
        provider_id: String,
        api_key: String,
    ) -> Result<(), EngineError> {
        check_provider(&provider_id)?;
        let key = api_key.trim().to_string();
        if key.is_empty() {
            return Err(EngineError::Invalid("API key is empty".into()));
        }
        OpenAiProvider::new(key.clone())
            .verify()
            .await
            .map_err(ai_err)?;
        self.secrets.set(AI_KEY, &key)?;
        Ok(())
    }

    /// Forget this device's key. The model choice stays: it is a synced
    /// preference shared with the user's other devices, which keep their
    /// own keys.
    pub fn remove_ai_key(&self, provider_id: String) -> Result<(), EngineError> {
        check_provider(&provider_id)?;
        self.secrets.delete(AI_KEY)?;
        Ok(())
    }

    /// Persist the selected model and push it to the user's other devices.
    pub fn set_ai_model(
        self: &Arc<Self>,
        provider_id: String,
        model: String,
    ) -> Result<(), EngineError> {
        check_provider(&provider_id)?;
        let value = serde_json::Value::String(model);
        self.store.set_pref(AI_MODEL_PREF, Some(&value))?;
        devsync::record_pref(&self.store, AI_MODEL_PREF, Some(value))?;
        self.push_app_wide_later();
        Ok(())
    }

    /// Apply one instruction (preset or freeform) to a piece of compose
    /// text and return the revised text. `history` is the plain-text
    /// transcript when replying inside a thread.
    pub async fn ai_edit_text(
        &self,
        provider_id: String,
        instruction: String,
        text: String,
        history: Option<String>,
    ) -> Result<String, EngineError> {
        check_provider(&provider_id)?;
        let instruction = instruction.trim();
        let text = text.trim();
        if instruction.is_empty() {
            return Err(EngineError::Invalid("instruction is empty".into()));
        }
        if text.is_empty() {
            return Err(EngineError::Invalid("nothing to edit".into()));
        }
        let mut user = String::new();
        if let Some(h) = history.as_deref().map(str::trim).filter(|h| !h.is_empty()) {
            user.push_str("Conversation so far (oldest first):\n");
            user.push_str(h);
            user.push_str("\n\n");
        }
        user.push_str(&format!("Instruction: {instruction}\n\nText:\n{text}"));
        self.openai_complete(EDIT_SYSTEM_PROMPT, user).await
    }

    /// A few lines about a group of active (not done) emails.
    pub async fn ai_summarize_group(
        &self,
        provider_id: String,
        items: Vec<SummaryItem>,
    ) -> Result<String, EngineError> {
        check_provider(&provider_id)?;
        if items.is_empty() {
            return Err(EngineError::Invalid("nothing to summarize".into()));
        }
        self.openai_complete(SUMMARY_SYSTEM_PROMPT, build_summary_prompt(&items))
            .await
    }

    /// A short recap of one open thread.
    pub async fn ai_summarize_thread(
        &self,
        provider_id: String,
        subject: String,
        items: Vec<ThreadSummaryItem>,
    ) -> Result<String, EngineError> {
        check_provider(&provider_id)?;
        if items.is_empty() {
            return Err(EngineError::Invalid("nothing to summarize".into()));
        }
        self.openai_complete(
            THREAD_SUMMARY_SYSTEM_PROMPT,
            build_thread_summary_prompt(&subject, &items),
        )
        .await
    }

    /// Draft a reply to the open thread from its transcript (+ the user's
    /// notes). Never sends: the user edits and sends themselves.
    pub async fn ai_draft_reply(
        &self,
        provider_id: String,
        subject: String,
        history: String,
        notes: Option<String>,
    ) -> Result<String, EngineError> {
        check_provider(&provider_id)?;
        if history.trim().is_empty() {
            return Err(EngineError::Invalid("nothing to reply to".into()));
        }
        self.openai_complete(
            DRAFT_REPLY_SYSTEM_PROMPT,
            build_draft_reply_prompt(&subject, &history, notes.as_deref()),
        )
        .await
    }

    // ------------------------------------------------------------ triage (Jev)

    pub fn triage_status(&self) -> Result<TriageStatus, EngineError> {
        Ok(TriageStatus {
            configured: matches!(self.secrets.get(JEV_KEY), Ok(Some(_))),
            enabled: self.triage_enabled()?,
            last_error: self.triage_last_error.lock().unwrap().clone(),
        })
    }

    /// Verify the key with one trivial request before persisting it.
    pub async fn set_jev_key(&self, api_key: String) -> Result<(), EngineError> {
        let key = api_key.trim().to_string();
        if key.is_empty() {
            return Err(EngineError::Invalid("API key is empty".into()));
        }
        JevClassifier::new(key.clone())
            .verify()
            .await
            .map_err(ai_err)?;
        self.secrets.set(JEV_KEY, &key)?;
        Ok(())
    }

    pub fn remove_jev_key(&self) -> Result<(), EngineError> {
        self.secrets.delete(JEV_KEY)?;
        Ok(())
    }

    /// The on/off switch is a synced preference, pushed to the user's
    /// other devices.
    pub fn set_autolabel_enabled(self: &Arc<Self>, enabled: bool) -> Result<(), EngineError> {
        let value = serde_json::Value::Bool(enabled);
        self.store.set_pref(TRIAGE_ENABLED_PREF, Some(&value))?;
        devsync::record_pref(&self.store, TRIAGE_ENABLED_PREF, Some(value))?;
        self.push_app_wide_later();
        Ok(())
    }

    /// Labels are app-wide and sync by id (`triage_label:<id>` on the
    /// first account's file); the store mints a random id so two devices
    /// never collide.
    pub fn create_triage_label(self: &Arc<Self>, name: String) -> Result<TriageLabel, EngineError> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err(EngineError::Invalid("label name cannot be empty".into()));
        }
        let label = self.store.create_triage_label(&name)?;
        devsync::record_triage_label(&self.store, &label.id, Some(&label.name))?;
        self.push_app_wide_later();
        Ok(label.into())
    }

    pub fn rename_triage_label(
        self: &Arc<Self>,
        id: String,
        new_name: String,
    ) -> Result<(), EngineError> {
        let new_name = new_name.trim().to_string();
        if new_name.is_empty() {
            return Err(EngineError::Invalid("label name cannot be empty".into()));
        }
        self.store.rename_triage_label(&id, &new_name)?;
        devsync::record_triage_label(&self.store, &id, Some(&new_name))?;
        self.push_app_wide_later();
        Ok(())
    }

    /// Deleting a label changes what is on screen (its chips disappear).
    /// The tombstone removes it on the user's other devices too.
    pub fn delete_triage_label(self: &Arc<Self>, id: String) -> Result<(), EngineError> {
        self.store.delete_triage_label(&id)?;
        devsync::record_triage_label(&self.store, &id, None)?;
        self.notify_threads_updated();
        self.push_app_wide_later();
        Ok(())
    }

    /// Settings "Reanalyze all emails": every thread becomes stale and the
    /// next sync rounds reclassify the mailbox gradually. Manual label pins
    /// are lifted here and, through their tombstones, on every device.
    pub fn reanalyze_all_triage(self: &Arc<Self>) -> Result<(), EngineError> {
        self.store.reset_triage()?;
        devsync::record_reset_triage(&self.store)?;
        for account in self.store.list_accounts()? {
            self.push_devsync_later(account.id);
        }
        Ok(())
    }

    /// Manual label edit from the thread view. Sticky until "Reanalyze";
    /// the pin travels to the user's other devices (`thread_triage:<id>`
    /// on the thread's account file). Jev's own results stay local.
    pub fn set_manual_triage_labels(
        self: &Arc<Self>,
        thread_id: String,
        label_ids: Vec<String>,
    ) -> Result<(), EngineError> {
        let thread = self
            .store
            .get_thread(&thread_id)?
            .ok_or_else(|| EngineError::Invalid(format!("unknown thread {thread_id}")))?;
        self.store
            .set_manual_triage_labels(&thread_id, &label_ids)?;
        devsync::record_thread_triage(
            &self.store,
            &thread.account_id,
            &thread_id,
            Some(&label_ids),
        )?;
        self.notify_threads_updated();
        self.push_devsync_later(thread.account_id);
        Ok(())
    }
}

// Internals — not exported.
impl Engine {
    fn triage_enabled(&self) -> Result<bool, EngineError> {
        Ok(self
            .store
            .get_pref(TRIAGE_ENABLED_PREF)?
            .and_then(|v| v.as_bool())
            .unwrap_or(false))
    }

    /// The stored model preference, if any.
    fn stored_model(&self) -> Result<Option<String>, EngineError> {
        Ok(self
            .store
            .get_pref(AI_MODEL_PREF)?
            .and_then(|v| v.as_str().map(str::to_string)))
    }

    async fn openai_complete(&self, system: &str, user: String) -> Result<String, EngineError> {
        let key = self.secrets.get(AI_KEY)?.ok_or_else(|| {
            EngineError::Invalid("connect an AI provider in Settings first".into())
        })?;
        let model = self.stored_model()?.unwrap_or_else(|| {
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
                    content: system.to_string(),
                },
                ChatMessage {
                    role: ChatRole::User,
                    content: user,
                },
            ],
        };
        OpenAiProvider::new(key)
            .complete(req)
            .await
            .map(|s| s.trim().to_string())
            .map_err(ai_err)
    }

    /// Classify up to `TRIAGE_BATCH` stale threads. Called at the end of
    /// `sync_all`; overlapping rounds are skipped.
    pub(crate) async fn classify_pending(&self) {
        {
            let mut running = self.classifying.lock().unwrap();
            if *running {
                return;
            }
            *running = true;
        }
        let result = self.classify_pending_inner().await;
        *self.classifying.lock().unwrap() = false;
        match result {
            Ok(0) => {}
            Ok(n) => {
                log::info!("triage: classified {n} thread(s)");
                *self.triage_last_error.lock().unwrap() = None;
                self.notify_threads_updated();
            }
            Err(e) => {
                log::warn!("triage: {e}");
                *self.triage_last_error.lock().unwrap() = Some(e.to_string());
            }
        }
    }

    async fn classify_pending_inner(&self) -> Result<usize, EngineError> {
        if !self.triage_enabled()? {
            return Ok(0);
        }
        let Some(api_key) = self.secrets.get(JEV_KEY)? else {
            return Ok(0);
        };
        // Only mail inside the sync window: the archive walk brings in years
        // of old threads, and classifying those would cost an AI call each.
        let cutoff = now_ms() - i64::from(BACKFILL_DAYS) * 86_400_000;
        let pending: Vec<_> = self
            .store
            .list_threads_needing_triage(TRIAGE_BATCH)?
            .into_iter()
            .filter(|t| t.last_msg_at >= cutoff)
            .collect();
        if pending.is_empty() {
            return Ok(0);
        }
        let labels = self.store.list_triage_labels()?;
        let classifier = JevClassifier::new(api_key);
        let mut n = 0;
        for thread in pending {
            let messages = self.store.list_messages(&thread.id)?;
            // Thread row landed before its messages (mid-sync race): the
            // next round sees it again.
            let Some(last) = messages.last() else {
                continue;
            };
            let input = ClassifyInput {
                subject: &thread.subject,
                snippet: &thread.snippet,
                from: &last.from_addr,
            };
            let result = classifier.classify(&input, &labels).await.map_err(ai_err)?;
            self.store.set_thread_triage(
                &thread.id,
                &result.label_ids,
                result.priority,
                thread.msg_count,
            )?;
            n += 1;
        }
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::Engine;
    use std::sync::Arc;

    fn open(tag: &str) -> (Arc<Engine>, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "heypigeon-ffi-settings-{tag}-{}-{}",
            std::process::id(),
            heypigeon_core::domain::now_ms()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let e = Engine::open(
            dir.to_string_lossy().into_owned(),
            OauthClient {
                client_id: "123-abc.apps.googleusercontent.com".into(),
                client_secret: None,
            },
        )
        .unwrap();
        (e, dir)
    }

    #[test]
    fn triage_labels_round_trip_and_status() {
        let (e, dir) = open("triage");
        let s = e.triage_status().unwrap();
        assert!(!s.configured && !s.enabled && s.last_error.is_none());
        let l = e.create_triage_label("  Invoices ".into()).unwrap();
        assert_eq!(l.name, "Invoices");
        assert!(e.create_triage_label("   ".into()).is_err());
        e.rename_triage_label(l.id.clone(), "Bills".into()).unwrap();
        assert_eq!(e.list_triage_labels().unwrap()[0].name, "Bills");
        e.delete_triage_label(l.id).unwrap();
        assert!(e.list_triage_labels().unwrap().is_empty());
        e.set_autolabel_enabled(true).unwrap();
        assert!(e.triage_status().unwrap().enabled);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn ai_status_and_model_catalog() {
        let (e, dir) = open("ai");
        let s = e.ai_status().unwrap();
        assert!(!s.configured && s.provider_id.is_none());
        assert!(!e.ai_models("openai".into()).unwrap().is_empty());
        assert!(e.ai_models("other".into()).is_err());
        e.set_ai_model("openai".into(), "gpt-x".into()).unwrap();
        assert_eq!(e.ai_status().unwrap().model.as_deref(), Some("gpt-x"));
        // Removing this device's key keeps the (synced) model choice.
        e.remove_ai_key("openai".into()).unwrap();
        assert_eq!(e.ai_status().unwrap().model.as_deref(), Some("gpt-x"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn legacy_secret_store_prefs_migrate_once() {
        let (e, dir) = open("migrate");
        e.secrets.set(LEGACY_AI_MODEL_SECRET, "gpt-old").unwrap();
        e.secrets.set(LEGACY_TRIAGE_ENABLED_SECRET, "true").unwrap();
        migrate_legacy_prefs(&e.store, &*e.secrets);
        assert_eq!(e.ai_status().unwrap().model.as_deref(), Some("gpt-old"));
        assert!(e.triage_status().unwrap().enabled);
        assert_eq!(e.secrets.get(LEGACY_AI_MODEL_SECRET).unwrap(), None);
        assert_eq!(e.secrets.get(LEGACY_TRIAGE_ENABLED_SECRET).unwrap(), None);
        // A pref already set (synced in from elsewhere) wins over a
        // lingering legacy value.
        e.set_ai_model("openai".into(), "gpt-new".into()).unwrap();
        e.secrets.set(LEGACY_AI_MODEL_SECRET, "gpt-old").unwrap();
        migrate_legacy_prefs(&e.store, &*e.secrets);
        assert_eq!(e.ai_status().unwrap().model.as_deref(), Some("gpt-new"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Every settings edit lands in the sync map so the next round carries
    /// it to the user's other devices; prefs come back as JSON text.
    #[test]
    fn settings_edits_are_recorded_for_sync() {
        let (e, dir) = open("record");
        e.store
            .upsert_account(&heypigeon_core::domain::Account {
                id: "me@x.com".into(),
                email: "me@x.com".into(),
                display_name: "me".into(),
                color: "sky".into(),
                history_id: None,
                avatar_url: None,
                signature: String::new(),
            })
            .unwrap();
        let acc = "me@x.com".to_string();
        e.update_account(acc.clone(), Some("Peter".into()), None, None)
            .unwrap();
        let label = e.create_triage_label("Bills".into()).unwrap();
        e.set_ai_model("openai".into(), "gpt-x".into()).unwrap();
        e.set_autolabel_enabled(true).unwrap();
        e.set_pref("swipe_actions".into(), Some("[\"done\",\"delete\"]".into()))
            .unwrap();
        assert!(e.set_pref("bad:name".into(), None).is_err());
        assert!(e
            .set_pref("pin_list".into(), Some("not json".into()))
            .is_err());

        let keys: Vec<String> = e
            .store
            .sync_entries(&acc)
            .unwrap()
            .into_iter()
            .filter(|en| en.value.is_some())
            .map(|en| en.key)
            .collect();
        assert_eq!(
            keys,
            vec![
                "account:display_name".to_string(),
                "pref:ai.model".to_string(),
                "pref:swipe_actions".to_string(),
                "pref:triage.enabled".to_string(),
                format!("triage_label:{}", label.id),
            ]
        );
        let prefs = e.get_prefs().unwrap();
        assert_eq!(prefs["swipe_actions"], "[\"done\",\"delete\"]");
        assert_eq!(prefs["triage.enabled"], "true");
        e.set_pref("swipe_actions".into(), None).unwrap();
        assert!(!e.get_prefs().unwrap().contains_key("swipe_actions"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn update_account_validates_color_and_keeps_fields() {
        let (e, dir) = open("account");
        e.store
            .upsert_account(&heypigeon_core::domain::Account {
                id: "me@x.com".into(),
                email: "me@x.com".into(),
                display_name: "me".into(),
                color: "sky".into(),
                history_id: None,
                avatar_url: None,
                signature: String::new(),
            })
            .unwrap();
        assert!(e
            .update_account("me@x.com".into(), None, Some("neon".into()), None)
            .is_err());
        e.update_account(
            "me@x.com".into(),
            Some("Peter".into()),
            Some("mint".into()),
            Some("— P".into()),
        )
        .unwrap();
        let a = &e.list_accounts().unwrap()[0];
        assert_eq!(
            (
                a.display_name.as_str(),
                a.color.as_str(),
                a.signature.as_str()
            ),
            ("Peter", "mint", "— P")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn prompts() {
        let p =
            build_draft_reply_prompt("Invoice #42", "Sarah: Can you send it?", Some("say Friday"));
        assert!(p.starts_with("Subject: Invoice #42"));
        assert!(p.contains("Notes from the user for this reply:\nsay Friday"));
        assert!(!build_draft_reply_prompt("Hi", "Sam: Hello", Some("   ")).contains("Notes from"));
        let s = build_summary_prompt(&[SummaryItem {
            from: "a@b".into(),
            subject: "S".into(),
            snippet: "x".into(),
        }]);
        assert!(s.contains("From: a@b\nSubject: S\nx"));
    }

    /// Both summary prompts must ask for the subset SummaryMarkup.swift
    /// renders — and stay identical to the desktop shell's copies.
    #[test]
    fn summary_prompts_ask_for_the_rendered_markdown_subset() {
        for prompt in [SUMMARY_SYSTEM_PROMPT, THREAD_SUMMARY_SYSTEM_PROMPT] {
            assert!(prompt.contains("starting with \"- \""));
            assert!(prompt.contains("**bold**"));
            assert!(prompt.contains("No headers, no other markdown"));
        }
    }
}
