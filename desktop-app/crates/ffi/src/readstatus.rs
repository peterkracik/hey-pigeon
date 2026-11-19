//! Read status, engine side (docs/specs/read-status.md): the per-account
//! switch, and what this device knows of the relay.
//!
//! This is the part that can exist before anything is sent: the setting
//! (stored on the account, synced as `account:read_status`), the relay
//! URL the build was made with, and the address of the relay's `opens`
//! function, which the relay itself reports. Nothing here adds a pixel to
//! a message or calls `opens` — no register, no query, no delete.
//!
//! The relay URL is kept under its own key, apart from push's: turning
//! "New mail (push)" off clears those (`push.rs`), and the Mac, which has
//! no push at all, still has a relay.

use std::sync::Arc;

use heypigeon_core::devsync;
use heypigeon_core::domain::{now_ms, AccountId};
use heypigeon_core::ports::{MailError, Store};

use crate::engine::Engine;
use crate::types::*;

/// The relay this build talks to (`configure_relay`).
const RELAY_URL: &str = "relay.url";
/// Where the relay's `opens` function answers, as the relay last said.
const OPENS_URL: &str = "opens.url";
/// When the relay was last asked (epoch ms).
const OPENS_ASKED_AT: &str = "opens.asked_at_ms";

/// The relay is asked where `opens` is at most this often.
const ASK_EVERY_MS: i64 = 24 * 3_600_000;

/// Whether to ask the relay now: only for an account with read status on
/// (R11: an account with it off makes no request about it), only with a
/// relay, and not more than once a day.
fn discovery_due(
    read_status: bool,
    relay_url: Option<&str>,
    asked_at: Option<i64>,
    now: i64,
) -> bool {
    read_status
        && relay_url.is_some_and(|url| !url.is_empty())
        && asked_at.is_none_or(|at| now - at >= ASK_EVERY_MS || at > now)
}

#[uniffi::export]
impl Engine {
    /// Tell the engine which relay this build was made with (the shell
    /// reads it from its Info.plist); an empty string for none. Call at
    /// launch. A changed relay forgets what the old one said.
    pub fn configure_relay(&self, relay_url: String) -> Result<(), EngineError> {
        let relay_url = relay_url.trim().trim_end_matches('/').to_string();
        if !relay_url.is_empty() && !relay_url.starts_with("https://") {
            return Err(EngineError::Invalid(
                "relay URL must start with https://".into(),
            ));
        }
        let current = self.secrets.get(RELAY_URL)?.unwrap_or_default();
        if current == relay_url {
            return Ok(());
        }
        if relay_url.is_empty() {
            self.secrets.delete(RELAY_URL)?;
        } else {
            self.secrets.set(RELAY_URL, &relay_url)?;
        }
        let _ = self.secrets.delete(OPENS_URL);
        let _ = self.secrets.delete(OPENS_ASKED_AT);
        Ok(())
    }

    /// Whether read status can be turned on here: the build has a relay
    /// (R10). False means the setting is shown disabled, "Not available in
    /// this build".
    pub fn read_status_available(&self) -> bool {
        matches!(self.secrets.get(RELAY_URL), Ok(Some(url)) if !url.is_empty())
    }

    /// The read-status switch of one mailbox (R8). Stored on the account
    /// and recorded for the user's other devices. Turning it on needs a
    /// relay; turning it off never fails for the lack of one.
    ///
    /// Nothing is sent to the relay by either: no build registers a token
    /// yet, so there is nothing of this mailbox there to delete (R12's
    /// delete comes with the code that registers).
    pub fn set_read_status(
        self: &Arc<Self>,
        account_id: String,
        enabled: bool,
    ) -> Result<(), EngineError> {
        if enabled && !self.read_status_available() {
            return Err(EngineError::Invalid(
                "read status is not available in this build".into(),
            ));
        }
        let mut account = self
            .store
            .list_accounts()?
            .into_iter()
            .find(|a| a.id == account_id)
            .ok_or_else(|| EngineError::Invalid(format!("unknown account {account_id}")))?;
        if account.read_status == enabled {
            return Ok(());
        }
        account.read_status = enabled;
        self.store.upsert_account(&account)?;
        devsync::record_read_status(&self.store, &account_id, enabled)?;
        self.notify_threads_updated();
        self.push_devsync_later(account_id);
        Ok(())
    }
}

// Internals — not exported.
impl Engine {
    /// Where the relay's `opens` function answers, when the relay has said.
    #[allow(dead_code)] // read by the sender and the poll, which come next
    pub(crate) fn opens_url(&self) -> Option<String> {
        self.secrets
            .get(OPENS_URL)
            .ok()
            .flatten()
            .filter(|url| !url.is_empty())
    }

    /// Ask the relay where `opens` is, when that is due (`discovery_due`),
    /// with this account's token. One write-free GET to `register-token`;
    /// a failure changes nothing and is asked again on a later round.
    pub(crate) async fn discover_opens(&self, account_id: &AccountId) {
        let read_status = self
            .store
            .list_accounts()
            .ok()
            .and_then(|all| all.into_iter().find(|a| &a.id == account_id))
            .is_some_and(|a| a.read_status);
        let relay_url = self.secrets.get(RELAY_URL).ok().flatten();
        let asked_at = self
            .secrets
            .get(OPENS_ASKED_AT)
            .ok()
            .flatten()
            .and_then(|v| v.parse::<i64>().ok());
        if !discovery_due(read_status, relay_url.as_deref(), asked_at, now_ms()) {
            return;
        }
        let Some(relay_url) = relay_url else { return };
        let info = {
            let provider = self.provider.read().await;
            provider.relay_info(account_id, &relay_url).await
        };
        match info {
            Ok(info) => {
                let stored = match info.opens_url.as_deref().map(str::trim) {
                    Some(url) if url.starts_with("https://") => {
                        self.secrets.set(OPENS_URL, url.trim_end_matches('/'))
                    }
                    // No read status on this relay (or not yet): forget
                    // an address it gave before.
                    _ => self.secrets.delete(OPENS_URL),
                };
                if let Err(e) =
                    stored.and_then(|_| self.secrets.set(OPENS_ASKED_AT, &now_ms().to_string()))
                {
                    log::warn!("read status: relay answer not kept: {e}");
                }
            }
            Err(MailError::AuthExpired) => self.mark_disconnected(account_id),
            Err(e) => log::info!("read status: relay did not say where opens is: {e}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use heypigeon_core::domain;
    use std::path::PathBuf;

    const RELAY: &str = "https://register-token-abc-ew.a.run.app";

    fn open(tag: &str) -> (Arc<Engine>, PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "heypigeon-ffi-readstatus-{tag}-{}-{}",
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
        for id in ["a@x.com", "b@x.com"] {
            engine
                .store
                .upsert_account(&domain::Account {
                    id: id.into(),
                    email: id.into(),
                    display_name: id.into(),
                    color: "sky".into(),
                    history_id: None,
                    avatar_url: None,
                    signature: String::new(),
                    read_status: false,
                })
                .unwrap();
        }
        (engine, dir)
    }

    fn on(engine: &Engine, id: &str) -> bool {
        let accounts = engine.list_accounts().unwrap();
        accounts.iter().find(|a| a.id == id).unwrap().read_status
    }

    /// R8, R10: off for every account until turned on, and it cannot be
    /// turned on in a build without a relay.
    #[test]
    fn read_status_is_off_by_default_and_needs_a_relay() {
        let (engine, dir) = open("default");
        assert!(!on(&engine, "a@x.com") && !on(&engine, "b@x.com"));
        assert!(!engine.read_status_available());
        let err = engine.set_read_status("a@x.com".into(), true).unwrap_err();
        assert!(matches!(err, EngineError::Invalid(_)), "{err}");
        assert!(!on(&engine, "a@x.com"));
        // Off is always allowed, relay or not.
        engine.set_read_status("a@x.com".into(), false).unwrap();

        assert!(matches!(
            engine.configure_relay("http://plain.example".into()),
            Err(EngineError::Invalid(_))
        ));
        assert!(!engine.read_status_available());
        engine.configure_relay(format!(" {RELAY}/ ")).unwrap();
        assert!(engine.read_status_available());
        assert_eq!(
            engine.secrets.get(RELAY_URL).unwrap().as_deref(),
            Some(RELAY)
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    /// R8, R9, R25: the switch is one mailbox's, it is kept, and it is
    /// recorded for the user's other devices under `account:read_status`.
    #[test]
    fn the_switch_is_per_account_and_recorded_for_other_devices() {
        let (engine, dir) = open("switch");
        engine.configure_relay(RELAY.into()).unwrap();
        engine.set_read_status("a@x.com".into(), true).unwrap();
        assert!(on(&engine, "a@x.com"));
        assert!(!on(&engine, "b@x.com"));
        let key = devsync::account_field_key(devsync::ACCOUNT_FIELD_READ_STATUS);
        let recorded = |account: &str| {
            engine
                .store
                .sync_entries(&account.to_string())
                .unwrap()
                .into_iter()
                .find(|e| e.key == key)
                .and_then(|e| e.value)
        };
        assert_eq!(recorded("a@x.com"), Some(serde_json::json!(true)));
        assert_eq!(recorded("b@x.com"), None);

        engine.set_read_status("a@x.com".into(), false).unwrap();
        assert!(!on(&engine, "a@x.com"));
        assert_eq!(recorded("a@x.com"), Some(serde_json::json!(false)));
        assert!(matches!(
            engine.set_read_status("nobody@x.com".into(), false),
            Err(EngineError::Invalid(_))
        ));
        let _ = std::fs::remove_dir_all(dir);
    }

    /// Taking the relay away (a build without one) keeps an account's
    /// stored choice but forgets what the relay said; a different relay
    /// forgets it too.
    #[test]
    fn a_changed_relay_forgets_the_old_ones_answer() {
        let (engine, dir) = open("relay");
        engine.configure_relay(RELAY.into()).unwrap();
        engine
            .secrets
            .set(OPENS_URL, "https://o.example.test")
            .unwrap();
        engine.secrets.set(OPENS_ASKED_AT, "5").unwrap();
        assert_eq!(
            engine.opens_url().as_deref(),
            Some("https://o.example.test")
        );
        // The same relay again changes nothing.
        engine.configure_relay(format!("{RELAY}/")).unwrap();
        assert!(engine.opens_url().is_some());
        engine
            .configure_relay("https://other.example".into())
            .unwrap();
        assert_eq!(engine.opens_url(), None);
        assert_eq!(engine.secrets.get(OPENS_ASKED_AT).unwrap(), None);
        engine.configure_relay(String::new()).unwrap();
        assert!(!engine.read_status_available());
        let _ = std::fs::remove_dir_all(dir);
    }

    /// R11: the relay is asked about read status only for an account that
    /// has it on, only when there is a relay, and once a day.
    #[test]
    fn the_relay_is_asked_only_for_an_account_with_read_status_on() {
        const NOW: i64 = 1_800_000_000_000;
        assert!(!discovery_due(false, Some(RELAY), None, NOW));
        assert!(!discovery_due(true, None, None, NOW));
        assert!(!discovery_due(true, Some(""), None, NOW));
        assert!(discovery_due(true, Some(RELAY), None, NOW));
        assert!(!discovery_due(true, Some(RELAY), Some(NOW - 1), NOW));
        assert!(!discovery_due(
            true,
            Some(RELAY),
            Some(NOW - ASK_EVERY_MS + 1),
            NOW
        ));
        assert!(discovery_due(
            true,
            Some(RELAY),
            Some(NOW - ASK_EVERY_MS),
            NOW
        ));
        // A stamp from the future (the clock was set back) does not
        // silence it for good.
        assert!(discovery_due(true, Some(RELAY), Some(NOW + 1), NOW));
    }

    /// With read status off — every account, as shipped — a sync round's
    /// discovery step returns before it touches the network or the stamp.
    #[tokio::test]
    async fn discovery_does_nothing_while_read_status_is_off() {
        let (engine, dir) = open("off");
        engine.configure_relay(RELAY.into()).unwrap();
        engine.discover_opens(&"a@x.com".to_string()).await;
        assert_eq!(engine.secrets.get(OPENS_ASKED_AT).unwrap(), None);
        assert_eq!(engine.opens_url(), None);
        let _ = std::fs::remove_dir_all(dir);
    }
}
