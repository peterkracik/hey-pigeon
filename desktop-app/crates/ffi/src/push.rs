//! The optional iOS push relay, engine side (issue #16; relay/ and
//! terraform/ hold the server half).
//!
//! Flow: the shell gets an APNs device token → `register_push_token` hands
//! it to the relay for every account (authenticated with the Google access
//! token, inside the Gmail adapter) → the relay answers with its Pub/Sub
//! topic → the engine calls `users.watch` for every account and keeps the
//! lease alive from `sync_account` (`core::push::ensure_watch`). The relay
//! only ever learns `email → device tokens` and, per event, `email +
//! historyId`. Mail never leaves the phone's own Gmail session.
//!
//! Settings live in the SecretStore key/value shape like the other small
//! preferences (settings.rs), never in the SQLite schema.

use heypigeon_core::domain::{now_ms, AccountId};
use heypigeon_core::ports::{MailError, Store};
use heypigeon_core::push as core_push;
use heypigeon_core::sync::SyncError;

use crate::engine::Engine;
use crate::types::*;

const RELAY_URL: &str = "push.relay_url";
const TOPIC: &str = "push.topic";
const DEVICE_TOKEN: &str = "push.device_token";
const ENVIRONMENT: &str = "push.environment";

#[uniffi::export(async_runtime = "tokio")]
impl Engine {
    /// Register this device with the relay for every connected account and
    /// start (or force-renew) the Gmail watches. Call on every APNs token
    /// the system hands out and whenever an account is added while push is
    /// on. `environment` is `"sandbox"` (Xcode) or `"production"`
    /// (TestFlight / App Store). Errors only when no account could be
    /// registered; per-account failures are logged and the account marked
    /// disconnected when Google rejected its grant.
    pub async fn register_push_token(
        &self,
        relay_url: String,
        device_token: String,
        environment: String,
    ) -> Result<(), EngineError> {
        let relay_url = relay_url.trim().to_string();
        if !relay_url.starts_with("https://") {
            return Err(EngineError::Invalid(
                "relay URL must start with https://".into(),
            ));
        }
        if device_token.trim().is_empty() {
            return Err(EngineError::Invalid("device token is empty".into()));
        }
        if environment != "sandbox" && environment != "production" {
            return Err(EngineError::Invalid(format!(
                "unknown APNs environment {environment}"
            )));
        }
        let accounts = self.store.list_accounts()?;
        if accounts.is_empty() {
            return Err(EngineError::Invalid("no accounts to register".into()));
        }
        let mut topic: Option<String> = None;
        let mut last_err: Option<EngineError> = None;
        for a in &accounts {
            let provider = self.provider.read().await;
            match provider
                .register_push_device(&a.id, &relay_url, &device_token, &environment)
                .await
            {
                Ok(t) => topic.get_or_insert(t),
                Err(MailError::AuthExpired) => {
                    self.mark_disconnected(&a.id);
                    last_err = Some(EngineError::AuthExpired(a.id.clone()));
                    continue;
                }
                Err(e) => {
                    log::warn!("push: relay registration for {} failed: {e}", a.id);
                    last_err = Some(e.into());
                    continue;
                }
            };
        }
        let Some(topic) = topic else {
            return Err(last_err.unwrap_or_else(|| EngineError::Invalid("relay refused".into())));
        };
        self.secrets.set(RELAY_URL, &relay_url)?;
        self.secrets.set(TOPIC, &topic)?;
        self.secrets.set(DEVICE_TOKEN, &device_token)?;
        self.secrets.set(ENVIRONMENT, &environment)?;
        // A fresh registration always re-watches: the topic may have changed
        // (new relay) and a stale lease from a previous install is worthless.
        for a in &accounts {
            self.ensure_watch(&a.id, &topic, true).await;
        }
        Ok(())
    }

    /// Turn push off: forget the device at the relay, stop every Gmail
    /// watch, clear the settings. Remote failures are logged, not returned
    /// — the user decided, and both leases expire on their own.
    pub async fn disable_push(&self) -> Result<(), EngineError> {
        let accounts = self.store.list_accounts()?;
        for a in &accounts {
            self.forget_push_for_account(&a.id).await;
        }
        for key in [RELAY_URL, TOPIC, DEVICE_TOKEN, ENVIRONMENT] {
            let _ = self.secrets.delete(key);
        }
        Ok(())
    }

    /// Current relay configuration and per-account watch expiry.
    pub fn push_status(&self) -> Result<PushStatus, EngineError> {
        let relay_url = self.secrets.get(RELAY_URL)?;
        let topic = self.secrets.get(TOPIC)?;
        let registered = matches!(self.secrets.get(DEVICE_TOKEN), Ok(Some(t)) if !t.is_empty());
        let accounts = self
            .store
            .list_accounts()?
            .into_iter()
            .map(|a| {
                let watch_expires_at_ms = core_push::watch_expiration(&self.store, &a.id)
                    .ok()
                    .flatten();
                PushAccountStatus {
                    account_id: a.id,
                    watch_expires_at_ms,
                }
            })
            .collect();
        Ok(PushStatus {
            enabled: registered && topic.is_some(),
            relay_url,
            topic,
            accounts,
        })
    }
}

// Internals — not exported.
impl Engine {
    /// Renew the watch lease if push is on and it is due (`sync_account`).
    pub(crate) async fn renew_watch(&self, account_id: &AccountId) {
        let Ok(Some(topic)) = self.secrets.get(TOPIC) else {
            return;
        };
        if topic.is_empty() {
            return;
        }
        self.ensure_watch(account_id, &topic, false).await;
    }

    async fn ensure_watch(&self, account_id: &AccountId, topic: &str, force: bool) {
        let provider = self.provider.read().await;
        match core_push::ensure_watch(&*provider, &self.store, account_id, topic, now_ms(), force)
            .await
        {
            Ok(_) => {}
            Err(SyncError::Mail(MailError::AuthExpired)) => self.mark_disconnected(account_id),
            Err(e) => log::warn!("push: watch for {account_id} failed: {e}"),
        }
    }

    /// Relay DELETE + `users.stop` for one account, best effort. Used when
    /// push is turned off and when an account is removed while push is on.
    pub(crate) async fn forget_push_for_account(&self, account_id: &AccountId) {
        let relay_url = self.secrets.get(RELAY_URL).ok().flatten();
        let device_token = self.secrets.get(DEVICE_TOKEN).ok().flatten();
        let provider = self.provider.read().await;
        if let (Some(url), Some(token)) = (relay_url, device_token) {
            if let Err(e) = provider
                .unregister_push_device(account_id, &url, &token)
                .await
            {
                log::warn!("push: relay unregister for {account_id} failed: {e}");
            }
        }
        if core_push::watch_expiration(&self.store, account_id)
            .ok()
            .flatten()
            .is_some()
        {
            if let Err(e) = core_push::disable_watch(&*provider, &self.store, account_id).await {
                log::warn!("push: users.stop for {account_id} failed: {e}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::Arc;

    fn open(tag: &str) -> (Arc<Engine>, PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "heypigeon-ffi-push-{tag}-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let engine = Engine::open(
            dir.to_string_lossy().into_owned(),
            OauthClient {
                client_id: "123-abc.apps.googleusercontent.com".to_string(),
                client_secret: None,
            },
        )
        .unwrap();
        (engine, dir)
    }

    #[tokio::test]
    async fn status_is_off_by_default() {
        let (engine, dir) = open("default");
        let s = engine.push_status().unwrap();
        assert!(!s.enabled);
        assert!(s.relay_url.is_none());
        assert!(s.accounts.is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn register_validates_input_before_any_network() {
        let (engine, dir) = open("validate");
        let err = engine
            .register_push_token("http://insecure".into(), "tok".into(), "sandbox".into())
            .await
            .unwrap_err();
        assert!(matches!(err, EngineError::Invalid(_)), "{err}");
        let err = engine
            .register_push_token("https://relay".into(), "".into(), "sandbox".into())
            .await
            .unwrap_err();
        assert!(matches!(err, EngineError::Invalid(_)), "{err}");
        let err = engine
            .register_push_token("https://relay".into(), "tok".into(), "staging".into())
            .await
            .unwrap_err();
        assert!(matches!(err, EngineError::Invalid(_)), "{err}");
        // No accounts yet: nothing to register, and nothing stored.
        let err = engine
            .register_push_token("https://relay".into(), "tok".into(), "sandbox".into())
            .await
            .unwrap_err();
        assert!(matches!(err, EngineError::Invalid(_)), "{err}");
        assert!(!engine.push_status().unwrap().enabled);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn disable_without_registration_is_a_no_op() {
        let (engine, dir) = open("disable");
        engine.disable_push().await.unwrap();
        assert!(!engine.push_status().unwrap().enabled);
        let _ = std::fs::remove_dir_all(dir);
    }
}
