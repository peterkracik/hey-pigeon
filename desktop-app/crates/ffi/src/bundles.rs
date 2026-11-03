//! Bundles for the shells (docs/bundles.md): the mail about one specific
//! thing — a trip, an order, a project — grouped so the app can show it
//! together with its key facts.
//!
//! This is rollout step 1: bundles are made by hand, and the deterministic
//! layer (`core::bundles`) keeps them filled — an email sharing a booking
//! reference, order, invoice, tracking or flight number with one already in
//! a bundle joins it. Model-based assignment comes later behind the same
//! API. The user's own choices (add, remove) are sticky and reach their
//! other devices through the sync map; the links are re-derived on every
//! device, like triage results.

use std::sync::Arc;

use heypigeon_core::bundles::{self as core_bundles, AnchorKind};
use heypigeon_core::devsync;
use heypigeon_core::domain::{self, now_ms, BundleSource, BundleStatus};
use heypigeon_core::ports::Store;

use crate::engine::Engine;
use crate::types::*;

/// Threads scanned for anchors per sync round. Scanning is local string
/// work (no network, no model), so the first round after an upgrade can
/// cover a mailbox's recent history quickly; the rest follows.
const ANCHOR_BATCH: u32 = 500;

/// What a bundle is about (`domain::BundleKind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BundleKind {
    Trip,
    Shopping,
    Project,
    Other,
}

impl From<domain::BundleKind> for BundleKind {
    fn from(k: domain::BundleKind) -> Self {
        match k {
            domain::BundleKind::Trip => Self::Trip,
            domain::BundleKind::Shopping => Self::Shopping,
            domain::BundleKind::Project => Self::Project,
            domain::BundleKind::Other => Self::Other,
        }
    }
}

impl From<BundleKind> for domain::BundleKind {
    fn from(k: BundleKind) -> Self {
        match k {
            BundleKind::Trip => Self::Trip,
            BundleKind::Shopping => Self::Shopping,
            BundleKind::Project => Self::Project,
            BundleKind::Other => Self::Other,
        }
    }
}

/// One bundle as the Bundles list shows it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MailBundle {
    pub id: String,
    pub name: String,
    pub kind: BundleKind,
    /// The user's one line; empty when none.
    pub description: String,
    pub archived: bool,
    /// Epoch ms.
    pub created_at: i64,
    /// Threads in the bundle, done ones included (trash and spam never).
    pub thread_count: u32,
    /// Of those, still in the inbox (not done).
    pub open_count: u32,
    /// Newest message across the bundle's threads, epoch ms; 0 when empty.
    pub last_activity_at: i64,
}

/// What a key fact identifies (`core::bundles::AnchorKind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BundleFactKind {
    Flight,
    Booking,
    Order,
    Invoice,
    Tracking,
}

impl From<AnchorKind> for BundleFactKind {
    fn from(k: AnchorKind) -> Self {
        match k {
            AnchorKind::Flight => Self::Flight,
            AnchorKind::Booking => Self::Booking,
            AnchorKind::Order => Self::Order,
            AnchorKind::Invoice => Self::Invoice,
            AnchorKind::Tracking => Self::Tracking,
        }
    }
}

/// One key fact in the bundle view, with the email it came from.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BundleFact {
    pub kind: BundleFactKind,
    /// The identifier as found, upper-cased: `AT1323`, `112-334`.
    pub value: String,
    /// The newest thread carrying it — tapping the fact opens it.
    pub thread_id: String,
    /// That thread's newest message, epoch ms.
    pub at: i64,
}

/// Everything the bundle view shows.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BundleDetail {
    pub bundle: MailBundle,
    pub facts: Vec<BundleFact>,
    /// Newest first, done ones included.
    pub threads: Vec<MailThread>,
}

/// Open = still waiting in the inbox (not done).
fn is_open(t: &domain::Thread) -> bool {
    t.is_inbox && !t.is_archived
}

#[uniffi::export]
impl Engine {
    /// Every bundle: active first, then archived, each by name.
    pub fn list_bundles(&self) -> Result<Vec<MailBundle>, EngineError> {
        let bundles = self.store.list_bundles()?;
        bundles.iter().map(|b| self.mail_bundle(b)).collect()
    }

    /// The bundle view: the row, its key facts and its threads. `None`
    /// for an unknown id (deleted on another device).
    pub fn bundle_detail(&self, bundle_id: String) -> Result<Option<BundleDetail>, EngineError> {
        let Some(b) = self.bundle(&bundle_id)? else {
            return Ok(None);
        };
        let facts = core_bundles::bundle_facts(&self.store, &bundle_id)?
            .into_iter()
            .map(|f| BundleFact {
                kind: f.anchor.kind.into(),
                value: f.anchor.value,
                thread_id: f.thread_id,
                at: f.at,
            })
            .collect();
        let threads = self
            .store
            .list_bundle_threads(&bundle_id)?
            .into_iter()
            .map(Into::into)
            .collect();
        Ok(Some(BundleDetail {
            bundle: self.mail_bundle(&b)?,
            facts,
            threads,
        }))
    }

    /// "New bundle…", optionally from selected threads ("New bundle from
    /// these"). The threads join as the user's choice and pull in the mail
    /// that shares an identifier with them.
    pub fn create_bundle(
        self: &Arc<Self>,
        name: String,
        kind: BundleKind,
        description: String,
        thread_ids: Vec<String>,
    ) -> Result<MailBundle, EngineError> {
        let name = name.trim();
        if name.is_empty() {
            return Err(EngineError::Invalid("bundle name cannot be empty".into()));
        }
        let b = core_bundles::new_bundle(name, kind.into(), description.trim());
        self.store.upsert_bundle(&b)?;
        devsync::record_bundle(&self.store, &b.id, Some(&b))?;
        self.push_app_wide_later();
        for thread_id in thread_ids {
            self.put_in_bundle(&thread_id, &b.id)?;
        }
        self.notify_threads_updated();
        self.mail_bundle(&b)
    }

    /// Rename, change the kind or the description.
    pub fn update_bundle(
        self: &Arc<Self>,
        bundle_id: String,
        name: String,
        kind: BundleKind,
        description: String,
    ) -> Result<(), EngineError> {
        let name = name.trim();
        if name.is_empty() {
            return Err(EngineError::Invalid("bundle name cannot be empty".into()));
        }
        let mut b = self.require_bundle(&bundle_id)?;
        b.name = name.to_string();
        b.kind = kind.into();
        b.description = description.trim().to_string();
        self.save_bundle(&b)
    }

    /// Archive (the trip is over) or reopen a bundle. Archived bundles
    /// leave the active list but keep their threads.
    pub fn set_bundle_archived(
        self: &Arc<Self>,
        bundle_id: String,
        archived: bool,
    ) -> Result<(), EngineError> {
        let mut b = self.require_bundle(&bundle_id)?;
        b.status = if archived {
            BundleStatus::Archived
        } else {
            BundleStatus::Active
        };
        self.save_bundle(&b)
    }

    /// Delete a bundle. The mail stays where it is; only the grouping goes.
    pub fn delete_bundle(self: &Arc<Self>, bundle_id: String) -> Result<(), EngineError> {
        self.store.delete_bundle(&bundle_id)?;
        devsync::record_bundle(&self.store, &bundle_id, None)?;
        self.push_app_wide_later();
        self.notify_threads_updated();
        Ok(())
    }

    /// "Add to bundle…": the user's choice, sticky. Moves the thread out of
    /// any other bundle and pulls in the threads sharing an identifier with
    /// it. Returns how many other threads came along.
    pub fn add_to_bundle(
        self: &Arc<Self>,
        thread_id: String,
        bundle_id: String,
    ) -> Result<u32, EngineError> {
        let joined = self.put_in_bundle(&thread_id, &bundle_id)?;
        self.notify_threads_updated();
        Ok(joined)
    }

    /// "Remove from bundle": the thread leaves and nothing automatic puts
    /// it back in that bundle.
    pub fn remove_from_bundle(self: &Arc<Self>, thread_id: String) -> Result<(), EngineError> {
        let thread = self
            .store
            .get_thread(&thread_id)?
            .ok_or_else(|| EngineError::Invalid(format!("unknown thread {thread_id}")))?;
        let Some(bundle_id) = thread.bundle_id else {
            return Ok(());
        };
        self.store.set_thread_bundle(&thread_id, None)?;
        self.store.exclude_from_bundle(&bundle_id, &thread_id)?;
        devsync::record_bundle_thread(
            &self.store,
            &thread.account_id,
            &thread_id,
            &bundle_id,
            true,
        )?;
        self.push_devsync_later(thread.account_id);
        self.notify_threads_updated();
        Ok(())
    }

    /// The bundle to offer first in the "Add to bundle" picker: the one
    /// this thread shares a booking, order or tracking number with. `None`
    /// when there is no such bundle or the thread is already in it.
    pub fn suggest_bundle(&self, thread_id: String) -> Result<Option<String>, EngineError> {
        Ok(core_bundles::suggest_for(&self.store, &thread_id)?)
    }
}

// Internals — not exported.
impl Engine {
    /// End of each sync round: scan new mail for identifiers and link it to
    /// the bundles it belongs to. Local work only; never fails the round.
    pub(crate) fn link_bundles_pending(&self) {
        let outcome = match core_bundles::link_pass(&self.store, ANCHOR_BATCH) {
            Ok(o) => o,
            Err(e) => {
                log::warn!("bundles: link pass failed: {e}");
                return;
            }
        };
        // A reopened bundle's status is synced state: record it, or the
        // other devices' "archived" would win it back on the next merge.
        for id in &outcome.reopened {
            if let Ok(Some(b)) = self.bundle(id) {
                if let Err(e) = devsync::record_bundle(&self.store, id, Some(&b)) {
                    log::warn!("bundles: cannot record reopened bundle: {e}");
                }
            }
        }
        if outcome.changed() {
            self.notify_threads_updated();
        }
    }

    fn bundle(&self, id: &str) -> Result<Option<domain::Bundle>, EngineError> {
        Ok(self.store.list_bundles()?.into_iter().find(|b| b.id == id))
    }

    fn require_bundle(&self, id: &str) -> Result<domain::Bundle, EngineError> {
        self.bundle(id)?
            .ok_or_else(|| EngineError::Invalid(format!("unknown bundle {id}")))
    }

    fn save_bundle(self: &Arc<Self>, b: &domain::Bundle) -> Result<(), EngineError> {
        let mut b = b.clone();
        b.updated_at = now_ms();
        self.store.upsert_bundle(&b)?;
        devsync::record_bundle(&self.store, &b.id, Some(&b))?;
        self.push_app_wide_later();
        self.notify_threads_updated();
        Ok(())
    }

    /// The shared half of "Add to bundle" and "New bundle from these".
    fn put_in_bundle(
        self: &Arc<Self>,
        thread_id: &str,
        bundle_id: &str,
    ) -> Result<u32, EngineError> {
        let thread_id = thread_id.to_string();
        let thread = self
            .store
            .get_thread(&thread_id)?
            .ok_or_else(|| EngineError::Invalid(format!("unknown thread {thread_id}")))?;
        let mut b = self.require_bundle(bundle_id)?;
        self.store.clear_bundle_exclusion(bundle_id, &thread_id)?;
        self.store
            .set_thread_bundle(&thread_id, Some((bundle_id, BundleSource::User)))?;
        devsync::record_bundle_thread(
            &self.store,
            &thread.account_id,
            &thread_id,
            bundle_id,
            false,
        )?;
        // Adding mail to an archived bundle means it is current again.
        if b.status == BundleStatus::Archived {
            b.status = BundleStatus::Active;
            b.updated_at = now_ms();
            self.store.upsert_bundle(&b)?;
            devsync::record_bundle(&self.store, &b.id, Some(&b))?;
            self.push_app_wide_later();
        }
        let joined = core_bundles::spread_from(&self.store, &thread_id, bundle_id)?;
        self.push_devsync_later(thread.account_id);
        Ok(joined.len() as u32)
    }

    fn mail_bundle(&self, b: &domain::Bundle) -> Result<MailBundle, EngineError> {
        let threads = self.store.list_bundle_threads(&b.id)?;
        Ok(MailBundle {
            id: b.id.clone(),
            name: b.name.clone(),
            kind: b.kind.into(),
            description: b.description.clone(),
            archived: b.status == BundleStatus::Archived,
            created_at: b.created_at,
            thread_count: threads.len() as u32,
            open_count: threads.iter().filter(|t| is_open(t)).count() as u32,
            last_activity_at: threads.iter().map(|t| t.last_msg_at).max().unwrap_or(0),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::tests_support::sample_thread;
    use heypigeon_core::domain::Account;

    fn open(tag: &str) -> Arc<Engine> {
        let dir = std::env::temp_dir().join(format!(
            "heypigeon-ffi-bundles-{tag}-{}-{}",
            std::process::id(),
            now_ms()
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
        e.store
            .upsert_account(&Account {
                id: "me@x.com".into(),
                email: "me@x.com".into(),
                display_name: "me".into(),
                color: "sky".into(),
                history_id: None,
                avatar_url: None,
                signature: String::new(),
            })
            .unwrap();
        e
    }

    fn add(e: &Engine, id: &str, subject: &str, at: i64, done: bool) {
        let mut t = sample_thread(id, "me@x.com");
        t.subject = subject.into();
        t.snippet = String::new();
        t.last_msg_at = at;
        t.is_inbox = !done;
        t.is_archived = done;
        e.store.upsert_thread(&t).unwrap();
    }

    #[test]
    fn create_add_link_and_detail() {
        let e = open("flow");
        add(
            &e,
            "confirm",
            "Booking confirmed · booking reference K7QX2M",
            1_000,
            true,
        );
        add(
            &e,
            "seat",
            "Choose your seat · booking K7QX2M",
            2_000,
            false,
        );
        add(&e, "lunch", "Sunday lunch?", 3_000, false);
        e.link_bundles_pending();

        let trip = e
            .create_bundle(
                "  Lisbon trip ".into(),
                BundleKind::Trip,
                "".into(),
                vec!["confirm".into()],
            )
            .unwrap();
        assert_eq!(trip.name, "Lisbon trip");
        // The seat email shares the booking code and came along.
        assert_eq!(trip.thread_count, 2);
        assert_eq!(trip.open_count, 1);
        assert_eq!(
            e.get_thread_row("seat".into()).unwrap().unwrap().bundle_id,
            Some(trip.id.clone())
        );

        let detail = e.bundle_detail(trip.id.clone()).unwrap().unwrap();
        let ids: Vec<&str> = detail.threads.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(
            ids,
            vec!["seat", "confirm"],
            "done mail stays in the bundle"
        );
        assert_eq!(detail.facts.len(), 1);
        assert_eq!(detail.facts[0].kind, BundleFactKind::Booking);
        assert_eq!(detail.facts[0].value, "K7QX2M");
        assert_eq!(detail.facts[0].thread_id, "seat");

        // Removing is sticky: the next pass does not put it back.
        e.remove_from_bundle("seat".into()).unwrap();
        add(
            &e,
            "seat",
            "Choose your seat · booking K7QX2M",
            2_500,
            false,
        );
        e.link_bundles_pending();
        assert_eq!(
            e.get_thread_row("seat".into()).unwrap().unwrap().bundle_id,
            None
        );
        // Adding it back by hand lifts the exclusion.
        e.add_to_bundle("seat".into(), trip.id.clone()).unwrap();
        assert_eq!(
            e.get_thread_row("seat".into()).unwrap().unwrap().bundle_id,
            Some(trip.id.clone())
        );

        // New mail with the code links on the next sync round and the
        // picker suggests the bundle for nothing else.
        add(&e, "refund", "Refund for booking K7QX2M", 4_000, false);
        e.link_bundles_pending();
        assert_eq!(
            e.get_thread_row("refund".into())
                .unwrap()
                .unwrap()
                .bundle_id,
            Some(trip.id.clone())
        );
        assert_eq!(e.suggest_bundle("lunch".into()).unwrap(), None);
    }

    #[test]
    fn archive_rename_and_delete() {
        let e = open("lifecycle");
        add(&e, "t1", "Your order #112-334 has shipped", 1_000, false);
        let b = e
            .create_bundle("Gifts".into(), BundleKind::Shopping, "".into(), vec![])
            .unwrap();
        assert!(e
            .create_bundle(" ".into(), BundleKind::Other, "".into(), vec![])
            .is_err());

        e.update_bundle(
            b.id.clone(),
            "Christmas 2026".into(),
            BundleKind::Shopping,
            "All gifts".into(),
        )
        .unwrap();
        e.set_bundle_archived(b.id.clone(), true).unwrap();
        let listed = e.list_bundles().unwrap();
        assert_eq!(listed[0].name, "Christmas 2026");
        assert_eq!(listed[0].description, "All gifts");
        assert!(listed[0].archived);

        // Adding mail to an archived bundle reopens it.
        e.add_to_bundle("t1".into(), b.id.clone()).unwrap();
        assert!(!e.list_bundles().unwrap()[0].archived);

        e.delete_bundle(b.id.clone()).unwrap();
        assert!(e.list_bundles().unwrap().is_empty());
        assert_eq!(
            e.get_thread_row("t1".into()).unwrap().unwrap().bundle_id,
            None
        );
        assert!(e.bundle_detail(b.id).unwrap().is_none());
    }
}
