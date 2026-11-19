//! Read status, engine side (docs/specs/read-status.md): the per-account
//! switch, and what this device knows of the relay.
//!
//! The setting (stored on the account, synced as `account:read_status`),
//! the relay URL the build was made with, the address of the relay's
//! `opens` function, which the relay itself reports, and the part of a
//! sync round that is read status's: a pending "forget this mailbox", the
//! poll, and the catch-up. The rules are the core's
//! (`heypigeon_core::readstatus`); this file hands it the provider and
//! the store, and decides nothing about a message.
//!
//! The relay URL is kept under its own key, apart from push's: turning
//! "New mail (push)" off clears those (`push.rs`), and the Mac, which has
//! no push at all, still has a relay.

use std::sync::Arc;

use heypigeon_core::domain::{now_ms, AccountId};
use heypigeon_core::ports::{MailError, Store};
use heypigeon_core::{devsync, readstatus};

use crate::engine::Engine;
use crate::types::*;

/// The relay this build talks to (`configure_relay`).
const RELAY_URL: &str = "relay.url";
/// Where the relay's `opens` function answers, as the relay last said.
pub(crate) const OPENS_URL: &str = "opens.url";
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
        // The provider forgets it too. Busy (a sync holds it): the next
        // discovery sets it right.
        if let Ok(provider) = self.provider.try_read() {
            provider.set_opens_url(None);
        }
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
    /// On: the relay is asked where its read-status half is, so the next
    /// message can be tracked. Off **here** (R12): from this moment no
    /// pixel is added and nothing is polled for the account, and the relay
    /// is asked to delete the mailbox's tokens — now if it can be reached,
    /// on the following sync rounds until it has answered. A device that
    /// learns "off" from another one never comes through here, and sends
    /// no delete (R13).
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
        if enabled {
            readstatus::cancel_delete(&self.store, &account_id)?;
        } else {
            readstatus::request_delete(&self.store, &account_id)?;
        }
        self.notify_threads_updated();
        self.push_devsync_later(account_id.clone());
        // Outside a runtime (a plain sync call from Swift) there is
        // nothing to spawn on; the next sync round does the same.
        let engine = Arc::clone(self);
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(async move {
                if enabled {
                    engine.discover_opens(&account_id).await;
                } else {
                    engine.flush_opens_delete(&account_id).await;
                }
            });
        }
        Ok(())
    }
}

// Internals — not exported.
impl Engine {
    /// Where the relay's `opens` function answers, when the relay has said.
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
                self.provider.read().await.set_opens_url(self.opens_url());
            }
            // A relay that refuses the token says nothing about the
            // account's Gmail grant: the sync itself finds that out.
            Err(MailError::AuthExpired) => {
                log::info!("read status: the relay refused to say where opens is")
            }
            Err(_) => log::info!("read status: the relay did not say where opens is"),
        }
    }

    /// Send a pending "forget this mailbox" (R12), if there is one.
    pub(crate) async fn flush_opens_delete(&self, account_id: &AccountId) {
        let provider = self.provider.read().await;
        if let Err(e) = readstatus::flush_delete(&*provider, &self.store, account_id).await {
            log::warn!("read status: pending delete not read: {e}");
        }
    }

    /// Read status's part of a sync round, for one account. Returns
    /// whether anything a view shows changed. With read status off (and
    /// no delete pending) it reads two rows and makes no request.
    pub(crate) async fn read_status_round(&self, account_id: &AccountId) -> bool {
        self.flush_opens_delete(account_id).await;
        let now = now_ms();
        let added = {
            let provider = self.provider.read().await;
            readstatus::poll(&*provider, &self.store, account_id, now).await
        };
        let mut changed = match added {
            Ok(n) => n > 0,
            Err(e) => {
                log::warn!("read status: poll not kept: {e}");
                false
            }
        };
        // The tokens of mail sent from the user's other devices: a few
        // threads of their own recent sent mail a round, each tried once
        // per launch (a thread Gmail no longer has must not be asked for
        // again every 30 seconds).
        let threads =
            readstatus::catch_up_threads(&self.store, account_id, now).unwrap_or_default();
        for thread_id in threads {
            if !self
                .catch_up_tried
                .lock()
                .unwrap()
                .insert(thread_id.clone())
            {
                continue;
            }
            let Ok(Some(thread)) = self.store.get_thread(&thread_id) else {
                continue;
            };
            let Ok(meta) = self.store.list_message_meta(&thread_id) else {
                continue;
            };
            match self.fetch_bodies_into_store(&thread, &meta).await {
                Ok(_) => changed = true,
                Err(_) => log::info!("read status: a sent thread could not be read for its token"),
            }
        }
        changed
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

    /// R12, R13: turning it off on this device leaves a "forget this
    /// mailbox" for the relay, kept until it has been sent; turning it on
    /// again takes it back. (That a device which only learns "off" through
    /// sync leaves none is the core's test.)
    #[test]
    fn turning_off_here_asks_the_relay_to_forget_the_mailbox() {
        let (engine, dir) = open("off-switch");
        engine.configure_relay(RELAY.into()).unwrap();
        let a = "a@x.com".to_string();
        let pending = || {
            engine
                .store
                .sync_meta_get(&a, readstatus::META_DELETE_PENDING)
                .unwrap()
                .is_some_and(|v| !v.is_empty())
        };
        assert!(!pending());
        engine.set_read_status(a.clone(), true).unwrap();
        assert!(!pending());
        engine.set_read_status(a.clone(), false).unwrap();
        assert!(pending());
        // Off again changes nothing; on takes the request back.
        engine.set_read_status(a.clone(), false).unwrap();
        assert!(pending());
        engine.set_read_status(a.clone(), true).unwrap();
        assert!(!pending());
        // Only this mailbox's.
        engine.set_read_status(a.clone(), false).unwrap();
        assert!(engine
            .store
            .sync_meta_get(&"b@x.com".to_string(), readstatus::META_DELETE_PENDING)
            .unwrap()
            .is_none_or(|v| v.is_empty()));
        let _ = std::fs::remove_dir_all(dir);
    }

    /// R1, R6 at the bridge: a thread handed to a shell says Opened or
    /// Hidden for a tracked message, with every event newest first, and
    /// never calls a hidden fetch an open.
    #[test]
    fn a_thread_carries_opens_and_hidden_fetches() {
        use heypigeon_core::domain::{OpenEvent, OpenLabel, OpenToken};
        let (engine, dir) = open("events");
        let a = "a@x.com".to_string();
        engine
            .store
            .upsert_thread(&domain::Thread {
                id: "t1".into(),
                account_id: a.clone(),
                msg_count: 3,
                ..Default::default()
            })
            .unwrap();
        for (id, token) in [("s1", Some("aa")), ("s2", Some("bb")), ("s3", None)] {
            engine
                .store
                .upsert_message(&domain::Message {
                    id: id.into(),
                    thread_id: "t1".into(),
                    account_id: a.clone(),
                    from_addr: a.clone(),
                    date: 1_000,
                    label_ids: vec!["SENT".into()],
                    ..Default::default()
                })
                .unwrap();
            if let Some(token) = token {
                engine
                    .store
                    .open_token_put(&OpenToken {
                        token: token.into(),
                        account_id: a.clone(),
                        message_id: Some(id.into()),
                        thread_id: Some("t1".into()),
                        sent_at: 1_000,
                        expires_at: i64::MAX,
                        polled_at: None,
                    })
                    .unwrap();
            }
        }
        let opened = |at| OpenEvent {
            label: OpenLabel::Opened,
            at,
        };
        let hidden = |at| OpenEvent {
            label: OpenLabel::Hidden,
            at,
        };
        engine
            .store
            .open_events_add("aa", &[hidden(2_000), opened(3_000), opened(5_000)], 9)
            .unwrap();
        engine
            .store
            .open_events_add("bb", &[hidden(4_000)], 9)
            .unwrap();
        let t = engine.get_thread_local("t1".into()).unwrap().unwrap();
        let status = |id: &str| {
            t.messages
                .iter()
                .find(|m| m.id == id)
                .unwrap()
                .read_status
                .clone()
                .unwrap()
        };
        let s1 = status("s1");
        assert_eq!((s1.state, s1.at), (MessageReadState::Opened, Some(5_000)));
        assert_eq!(
            s1.events,
            vec![
                MessageOpenEvent {
                    opened: true,
                    at: 5_000
                },
                MessageOpenEvent {
                    opened: true,
                    at: 3_000
                },
                MessageOpenEvent {
                    opened: false,
                    at: 2_000
                },
            ]
        );
        let s2 = status("s2");
        assert_eq!((s2.state, s2.at), (MessageReadState::Hidden, Some(4_000)));
        assert_eq!(
            s2.events,
            vec![MessageOpenEvent {
                opened: false,
                at: 4_000
            }]
        );
        let s3 = status("s3");
        assert_eq!(
            (s3.state, s3.at, s3.events.len()),
            (MessageReadState::Sent, None, 0)
        );
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
