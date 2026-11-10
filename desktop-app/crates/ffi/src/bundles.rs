//! Bundles for the shells (docs/bundles.md): the mail about one specific
//! thing — a trip, an order, a project — grouped so the app can show it
//! together with its key facts.
//!
//! Bundles make themselves. After each sync round the shell's model reads
//! each new email (sender, subject, preview) with the active bundles and
//! answers join one, start a trip / shopping / project bundle, or none
//! (`bundle_pending`). The deterministic layer (`core::bundles`) also links
//! mail sharing a booking, order, invoice, tracking or flight number. The
//! user only steps in to fix a wrong email or make a bundle the model did
//! not see.
//!
//! The model's bundles (`BundleOrigin::Ai`) stay on this device — every
//! device groups its own mail, like triage — and stay hidden until a second
//! email joins (one receipt is not a bundle); one that never grows goes
//! away after `AI_SINGLE_TTL_MS`. Any user edit adopts the bundle
//! (`BundleOrigin::User`): from then on it syncs, and another device's
//! twin of the same name folds into it (`devsync::merge_ai_twins`). The
//! user's own choices (add, remove) are sticky and sync as well.

use std::sync::Arc;

use heypigeon_core::bundles::{self as core_bundles, AnchorKind};
use heypigeon_core::devsync;
use heypigeon_core::domain::{self, now_ms, BundleOrigin, BundleSource, BundleStatus};
use heypigeon_core::ports::Store;

use crate::engine::Engine;
use crate::types::*;

/// Threads scanned for anchors per sync round. Scanning is local string
/// work (no network, no model), so the first round after an upgrade can
/// cover a mailbox's recent history quickly; the rest follows.
const ANCHOR_BATCH: u32 = 500;
/// The switch (`pref:bundles.auto`, synced). Unset = on: it only runs when
/// one of the shell's models is there to answer.
pub(crate) const AUTO_BUNDLES_PREF: &str = "bundles.auto";
/// Emails the model groups per sync round; the next round continues.
const BUNDLE_BATCH: u32 = 10;
/// Mail from the last month is grouped; older mail is left alone (the
/// first sync of a mailbox would otherwise ask about years of it).
const BUNDLE_WINDOW_MS: i64 = 30 * 86_400_000;
/// The model sees at most this many bundles, most recently active first.
const MAX_CANDIDATES: usize = 15;
/// A model bundle that still holds one email after this long is dropped.
const AI_SINGLE_TTL_MS: i64 = 21 * 86_400_000;
/// Names that are a kind, not a thing: "Shopping" would swallow every
/// order the user ever makes.
const GENERIC_NAMES: &[&str] = &[
    "trip",
    "travel",
    "shopping",
    "order",
    "orders",
    "purchase",
    "project",
    "work",
    "other",
    "misc",
    "general",
    "receipts",
    "newsletter",
    "newsletters",
];

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
    /// The model made it and the user has not touched it yet.
    pub automatic: bool,
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
    /// For a tracking number: the tracking link its email carries, if the
    /// email's text is stored.
    pub url: Option<String>,
}

/// A tracking link found in the bundle's mail ("Track your parcel"): one
/// per email and host, so an order with three "Track package" buttons is
/// one row.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BundleLink {
    pub url: String,
    /// The link's host, for the row: `track.dpd.example`.
    pub host: String,
    pub thread_id: String,
    /// The email's subject, so the row says which order it tracks.
    pub subject: String,
}

/// What the model says about a bundle as a whole.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BundleSummary {
    /// Where things stand and the latest decision or change, with the
    /// key facts in **bold**.
    pub status: String,
    /// What the user still has to do, at most three ("Send the invoice to
    /// Acme"); empty when nothing.
    pub actions: Vec<String>,
}

/// Everything the bundle view shows.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BundleDetail {
    pub bundle: MailBundle,
    pub facts: Vec<BundleFact>,
    /// Tracking links from the bundle's mail, newest first.
    pub links: Vec<BundleLink>,
    /// Newest first, done ones included.
    pub threads: Vec<MailThread>,
}

/// One bundle as the model sees it when grouping an email.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BundleCandidate {
    pub id: String,
    pub name: String,
    pub kind: BundleKind,
    /// The user's one line; empty when none.
    pub description: String,
    /// Subjects of emails already in it, newest first (at most three).
    pub examples: Vec<String>,
    /// Subjects of emails the user took out of it (at most three): the
    /// model should not put mail like these in.
    pub not_examples: Vec<String>,
}

/// The model's answer for one email.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum BundleChoice {
    /// It belongs to this candidate (`BundleCandidate::id`).
    Existing { bundle_id: String },
    /// It is about a specific trip, purchase or project none of the
    /// candidates covers.
    New { name: String, kind: BundleKind },
    /// Not part of anything worth a bundle.
    NoBundle,
}

/// Open = still waiting in the inbox (not done).
fn is_open(t: &domain::Thread) -> bool {
    t.is_inbox && !t.is_archived
}

/// Threads whose stored text is scanned for tracking links.
const LINK_SCAN_THREADS: usize = 15;
/// Threads the bundle summary reads, newest first.
const SUMMARY_THREADS: usize = 8;
/// Characters of each email the bundle summary reads.
const SUMMARY_CHARS: usize = 800;

const BUNDLE_SUMMARY_PROMPT: &str = "You brief a busy person on one bundle of their emails: everything about one trip, purchase or project, oldest email first, each marked open or done. Answer in exactly this shape and nothing else:\nSTATUS: one or two short sentences: where things stand now and the latest decision or change. Wrap the key facts in **double asterisks**: dates, amounts, names, order or booking numbers.\nACTION: one thing the person still has to do themselves, starting with a verb (Send the invoice to Acme, Write the project brief, Pay by 12 Dec, Check in for AT 1323). One ACTION line per task, at most three. Leave out what other people still have to do and what is already done. If nothing is left to do, write exactly: ACTION: none\nNever invent facts the emails do not state.";

/// `STATUS:` and `ACTION:` lines; anything else counts as status text, so
/// a model that ignores the shape still yields a summary.
fn parse_bundle_summary(answer: &str) -> BundleSummary {
    let mut status: Vec<String> = Vec::new();
    let mut actions: Vec<String> = Vec::new();
    for line in answer.lines() {
        let line = line.trim().trim_start_matches(['-', '*', ' ']);
        if line.is_empty() {
            continue;
        }
        let upper = line.to_uppercase();
        if upper.starts_with("ACTION") {
            let task = line.splitn(2, ':').nth(1).unwrap_or("").trim().trim();
            let none = task.is_empty()
                || task.eq_ignore_ascii_case("none")
                || task.eq_ignore_ascii_case("none.");
            if !none && actions.len() < 3 {
                actions.push(task.to_string());
            }
        } else if upper.starts_with("STATUS") {
            status.push(line.splitn(2, ':').nth(1).unwrap_or("").trim().to_string());
        } else {
            status.push(line.to_string());
        }
    }
    BundleSummary {
        status: status.join(" ").trim().to_string(),
        actions,
    }
}

/// `https://track.dpd.example/abc` → `track.dpd.example`.
fn host_of(url: &str) -> String {
    let rest = url.split_once("://").map(|(_, r)| r).unwrap_or(url);
    rest.split(['/', '?', '#'])
        .next()
        .unwrap_or(rest)
        .to_string()
}

/// A model bundle with fewer than two emails is still forming: hidden.
fn is_forming(b: &MailBundle) -> bool {
    b.automatic && b.thread_count < 2
}

/// One line, single spaces, at most 40 characters.
fn clean_name(name: &str) -> String {
    let one_line = name.split_whitespace().collect::<Vec<_>>().join(" ");
    one_line
        .trim_matches(|c: char| c == '"' || c == '\'' || c == '.')
        .chars()
        .take(40)
        .collect()
}

#[uniffi::export]
impl Engine {
    /// Every bundle: active first, then archived, each by name. A model
    /// bundle shows once it holds two emails.
    pub fn list_bundles(&self) -> Result<Vec<MailBundle>, EngineError> {
        // One grouped count for all of them: this runs on every reload, and
        // used to read every thread of every bundle to count it.
        let stats = self.store.bundle_stats()?;
        Ok(self
            .store
            .list_bundles()?
            .iter()
            .map(|b| mail_bundle_row(b, stats.get(&b.id).cloned().unwrap_or_default()))
            .filter(|b| !is_forming(b))
            .collect())
    }

    /// The bundle view: the row, its key facts and its threads. `None`
    /// for an unknown id (deleted on another device).
    pub fn bundle_detail(&self, bundle_id: String) -> Result<Option<BundleDetail>, EngineError> {
        let Some(b) = self.bundle(&bundle_id)? else {
            return Ok(None);
        };
        let domain_threads = self.store.list_bundle_threads(&bundle_id)?;
        // Tracking links per thread, from whatever text the store holds.
        let mut links: Vec<BundleLink> = Vec::new();
        let mut thread_links: std::collections::HashMap<String, Vec<String>> = Default::default();
        for t in domain_threads.iter().take(LINK_SCAN_THREADS) {
            let numbers: Vec<String> = self
                .store
                .thread_anchors(&t.id)?
                .iter()
                .filter_map(|a| core_bundles::Anchor::parse(a))
                .filter(|a| a.kind == AnchorKind::Tracking)
                .map(|a| a.value)
                .collect();
            let text: String = self
                .store
                .list_messages(&t.id)?
                .iter()
                .map(|m| {
                    m.body_html
                        .clone()
                        .or_else(|| m.body_text.clone())
                        .unwrap_or_default()
                })
                .collect::<Vec<_>>()
                .join("\n");
            let found = core_bundles::tracking_links(&text, &numbers);
            for url in &found {
                let host = host_of(url);
                let seen = links
                    .iter()
                    .any(|l| &l.url == url || (l.thread_id == t.id && l.host == host));
                if !seen {
                    links.push(BundleLink {
                        url: url.clone(),
                        host,
                        thread_id: t.id.clone(),
                        subject: t.subject.clone(),
                    });
                }
            }
            thread_links.insert(t.id.clone(), found);
        }
        let facts = core_bundles::bundle_facts(&self.store, &bundle_id)?
            .into_iter()
            .map(|f| {
                let url = (f.anchor.kind == AnchorKind::Tracking)
                    .then(|| thread_links.get(&f.thread_id))
                    .flatten()
                    .and_then(|urls| {
                        urls.iter()
                            .find(|u| u.to_uppercase().contains(&f.anchor.value))
                            .or_else(|| urls.first())
                            .cloned()
                    });
                BundleFact {
                    kind: f.anchor.kind.into(),
                    value: f.anchor.value,
                    thread_id: f.thread_id,
                    at: f.at,
                    url,
                }
            })
            .collect();
        let threads = domain_threads.into_iter().map(Into::into).collect();
        Ok(Some(BundleDetail {
            bundle: self.mail_bundle(&b)?,
            facts,
            links,
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
        // A correction makes the bundle the user's: it syncs from now on,
        // and so does this exclusion.
        if let Some(b) = self.bundle(&bundle_id)? {
            self.adopt(b)?;
        }
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

// The async calls need the engine's Tokio runtime (fetching bodies goes
// through reqwest); a plain export runs them on a bare executor and the
// first fetch panics with "no reactor running".
#[uniffi::export(async_runtime = "tokio")]
impl Engine {
    /// The bundle's status and what is left to do, from its newest emails
    /// (the text of each, fetched when the store has only its preview).
    /// Like the other summaries it runs on the preferred provider when the
    /// user asks (the bundle view asks on open only when that provider is
    /// on this device or Apple's cloud, or auto-summarize is on).
    pub async fn ai_summarize_bundle(
        &self,
        provider_id: String,
        bundle_id: String,
    ) -> Result<BundleSummary, EngineError> {
        crate::settings::check_provider(&provider_id, &self.backend_ids())?;
        let b = self.require_bundle(&bundle_id)?;
        let threads = self.store.list_bundle_threads(&bundle_id)?;
        if threads.is_empty() {
            return Err(EngineError::Invalid("nothing to summarize".into()));
        }
        let mut items: Vec<String> = Vec::new();
        for t in threads.iter().take(SUMMARY_THREADS) {
            let messages = self.messages_with_bodies(t).await?;
            let last = messages
                .iter()
                .rev()
                .find(|m| !m.label_ids.iter().any(|l| l == "DRAFT"));
            let text = last
                .and_then(|m| m.body_text.clone())
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| t.snippet.clone());
            let text: String = text.trim().chars().take(SUMMARY_CHARS).collect();
            let state = if t.is_inbox && !t.is_archived {
                "open"
            } else {
                "done"
            };
            items.push(format!(
                "Email ({state}) from {} — {}\n{}",
                t.from_summary, t.subject, text
            ));
        }
        // Oldest first: the summary reads as a story that ends now.
        items.reverse();
        let user = format!(
            "Bundle: {} ({})\n{}\n\n{}",
            b.name,
            b.kind.as_str(),
            b.description,
            items.join("\n\n")
        );
        let answer = self.complete(BUNDLE_SUMMARY_PROMPT, user).await?;
        Ok(parse_bundle_summary(&answer))
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
        b.origin = BundleOrigin::User;
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
        // Adding mail to an archived bundle means it is current again; any
        // hand edit makes a model bundle the user's.
        if b.status == BundleStatus::Archived || b.origin == BundleOrigin::Ai {
            b.status = BundleStatus::Active;
            self.adopt(b)?;
        }
        let joined = core_bundles::spread_from(&self.store, &thread_id, bundle_id)?;
        self.push_devsync_later(thread.account_id);
        Ok(joined.len() as u32)
    }

    /// The user touched this bundle: it becomes theirs and syncs.
    fn adopt(self: &Arc<Self>, mut b: domain::Bundle) -> Result<(), EngineError> {
        b.origin = BundleOrigin::User;
        b.updated_at = now_ms();
        self.store.upsert_bundle(&b)?;
        devsync::record_bundle(&self.store, &b.id, Some(&b))?;
        self.push_app_wide_later();
        Ok(())
    }

    fn auto_bundles_enabled(&self) -> Result<bool, EngineError> {
        Ok(self
            .store
            .get_pref(AUTO_BUNDLES_PREF)?
            .and_then(|v| v.as_bool())
            .unwrap_or(true))
    }

    /// Group up to `BUNDLE_BATCH` new emails. Called at the end of
    /// `sync_all`, after the suggestion pass; overlapping rounds are skipped.
    pub(crate) async fn bundle_pending(&self) {
        {
            let mut running = self.bundling.lock().unwrap();
            if *running {
                return;
            }
            *running = true;
        }
        let result = self.bundle_pending_inner().await;
        *self.bundling.lock().unwrap() = false;
        match result {
            Ok(0) => {}
            Ok(n) => {
                log::info!("bundles: grouped {n} email(s)");
                self.notify_threads_updated();
            }
            Err(e) => log::warn!("bundles: {e}"),
        }
    }

    /// Returns how many threads joined a bundle.
    async fn bundle_pending_inner(&self) -> Result<usize, EngineError> {
        let mut changed = self.prune_ai_bundles()?;
        if !self.auto_bundles_enabled()? {
            return Ok(changed);
        }
        let Some(backend) = self.suggestion_backend()? else {
            return Ok(changed);
        };
        let now = now_ms();
        let pending = self
            .store
            .list_threads_needing_bundling(now - BUNDLE_WINDOW_MS, BUNDLE_BATCH)?;
        if pending.is_empty() {
            return Ok(changed);
        }
        let mut candidates = self.candidates()?;
        // The batch is the newest mail, read oldest first: the first email
        // about a trip names its bundle, the later ones join it.
        for thread in pending.into_iter().rev() {
            // Linked by a shared number since the list was read.
            if self
                .store
                .get_thread(&thread.id)?
                .and_then(|t| t.bundle_id)
                .is_some()
            {
                self.store
                    .set_thread_bundling_done(&thread.id, thread.msg_count)?;
                continue;
            }
            let answer = backend
                .bundle(
                    thread.subject.clone(),
                    thread.last_from_addr.clone(),
                    thread.snippet.clone(),
                    candidates.clone(),
                )
                .await;
            // Asked once per message whatever the answer, so one email the
            // model declines cannot block the queue; an error ends the
            // round (a model that is not ready costs one email, not ten).
            self.store
                .set_thread_bundling_done(&thread.id, thread.msg_count)?;
            let choice = answer?;
            let Some(bundle_id) = self.resolve(choice, &mut candidates)? else {
                continue;
            };
            if self.store.is_excluded_from_bundle(&bundle_id, &thread.id)? {
                continue;
            }
            self.store
                .set_thread_bundle(&thread.id, Some((&bundle_id, BundleSource::Ai)))?;
            // Its booking or order number may bring older mail along.
            core_bundles::spread_from(&self.store, &thread.id, &bundle_id)?;
            if let Some(c) = candidates.iter_mut().find(|c| c.id == bundle_id) {
                c.examples.insert(0, thread.subject.clone());
                c.examples.truncate(3);
            }
            changed += 1;
        }
        Ok(changed)
    }

    /// The bundle an answer points at, creating a model bundle for `New`.
    /// A new name equal to a candidate's (without case) joins that one; a
    /// generic name ("Shopping") or an unknown id is no bundle.
    fn resolve(
        &self,
        choice: BundleChoice,
        candidates: &mut Vec<BundleCandidate>,
    ) -> Result<Option<String>, EngineError> {
        match choice {
            BundleChoice::NoBundle => Ok(None),
            BundleChoice::Existing { bundle_id } => Ok(candidates
                .iter()
                .any(|c| c.id == bundle_id)
                .then_some(bundle_id)),
            BundleChoice::New { name, kind } => {
                let name = clean_name(&name);
                if name.is_empty() || GENERIC_NAMES.contains(&name.to_lowercase().as_str()) {
                    return Ok(None);
                }
                if let Some(c) = candidates
                    .iter()
                    .find(|c| c.name.to_lowercase() == name.to_lowercase())
                {
                    return Ok(Some(c.id.clone()));
                }
                let mut b = core_bundles::new_bundle(&name, kind.into(), "");
                b.origin = BundleOrigin::Ai;
                self.store.upsert_bundle(&b)?;
                candidates.insert(
                    0,
                    BundleCandidate {
                        id: b.id.clone(),
                        name: b.name.clone(),
                        kind,
                        description: String::new(),
                        examples: Vec::new(),
                        not_examples: Vec::new(),
                    },
                );
                Ok(Some(b.id))
            }
        }
    }

    /// Active bundles, most recently active first, with a few subjects
    /// each so the model sees what is in them.
    fn candidates(&self) -> Result<Vec<BundleCandidate>, EngineError> {
        let mut out: Vec<(i64, BundleCandidate)> = Vec::new();
        for b in self.store.list_bundles()? {
            if b.status == BundleStatus::Archived {
                continue;
            }
            let threads = self.store.list_bundle_threads(&b.id)?;
            let last = threads
                .first()
                .map(|t| t.last_msg_at)
                .unwrap_or(b.created_at);
            let mut not_examples = Vec::new();
            for id in self.store.list_bundle_exclusions(&b.id)?.iter().take(3) {
                if let Some(t) = self.store.get_thread(id)? {
                    not_examples.push(t.subject);
                }
            }
            out.push((
                last,
                BundleCandidate {
                    id: b.id.clone(),
                    name: b.name.clone(),
                    kind: b.kind.into(),
                    description: b.description.clone(),
                    examples: threads.iter().take(3).map(|t| t.subject.clone()).collect(),
                    not_examples,
                },
            ));
        }
        out.sort_by(|a, b| b.0.cmp(&a.0));
        Ok(out
            .into_iter()
            .take(MAX_CANDIDATES)
            .map(|(_, c)| c)
            .collect())
    }

    /// Model bundles that came to nothing: empty ones, and ones still
    /// holding a single email `AI_SINGLE_TTL_MS` after it arrived. Returns
    /// how many threads left a bundle.
    fn prune_ai_bundles(&self) -> Result<usize, EngineError> {
        let now = now_ms();
        let mut left = 0;
        let ai: Vec<domain::Bundle> = self
            .store
            .list_bundles()?
            .into_iter()
            .filter(|b| b.origin == BundleOrigin::Ai)
            .collect();
        if ai.is_empty() {
            return Ok(0);
        }
        // Counted in one query: this runs at the end of every sync round.
        let stats = self.store.bundle_stats()?;
        for b in ai {
            let s = stats.get(&b.id).cloned().unwrap_or_default();
            let stale = match s.thread_count {
                0 => true,
                1 => now - s.last_activity_at.max(b.created_at) > AI_SINGLE_TTL_MS,
                _ => false,
            };
            if stale {
                left += s.thread_count as usize;
                self.store.delete_bundle(&b.id)?;
            }
        }
        Ok(left)
    }

    fn mail_bundle(&self, b: &domain::Bundle) -> Result<MailBundle, EngineError> {
        let threads = self.store.list_bundle_threads(&b.id)?;
        Ok(mail_bundle_row(
            b,
            domain::BundleStats {
                thread_count: threads.len() as u32,
                open_count: threads.iter().filter(|t| is_open(t)).count() as u32,
                last_activity_at: threads.iter().map(|t| t.last_msg_at).max().unwrap_or(0),
            },
        ))
    }
}

/// The Bundles-list row for a bundle and its counts.
fn mail_bundle_row(b: &domain::Bundle, stats: domain::BundleStats) -> MailBundle {
    MailBundle {
        id: b.id.clone(),
        name: b.name.clone(),
        kind: b.kind.into(),
        description: b.description.clone(),
        archived: b.status == BundleStatus::Archived,
        automatic: b.origin == BundleOrigin::Ai,
        created_at: b.created_at,
        thread_count: stats.thread_count,
        open_count: stats.open_count,
        last_activity_at: stats.last_activity_at,
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

    fn scripted(answers: &[(&str, BundleChoice)]) -> Arc<crate::ai::fakes::ScriptedBackend> {
        let b = crate::ai::fakes::ScriptedBackend::new(
            "",
            TriageVerdict {
                priority: Priority::Low,
                label_ids: vec![],
            },
        );
        *b.bundle_answers.lock().unwrap() = answers
            .iter()
            .map(|(s, c)| (s.to_string(), c.clone()))
            .collect();
        b
    }

    fn new_bundle(name: &str, kind: BundleKind) -> BundleChoice {
        BundleChoice::New {
            name: name.into(),
            kind,
        }
    }

    #[tokio::test]
    async fn the_model_creates_and_fills_bundles_and_hides_single_ones() {
        let e = open("auto");
        let now = now_ms();
        add(&e, "flight", "Your flight to Lisbon", now - 3_000, false);
        add(&e, "hotel", "Casa Alfama: your stay", now - 2_000, false);
        add(&e, "shoe", "Order confirmed at Zalando", now - 1_000, false);
        add(&e, "news", "The Weekly Byte #212", now, false);
        add(&e, "generic", "Thanks for shopping", now - 500, false);
        let backend = scripted(&[
            (
                "Your flight to Lisbon",
                new_bundle("Lisbon trip", BundleKind::Trip),
            ),
            // Same name, other case: joins the bundle the flight started.
            (
                "Casa Alfama: your stay",
                new_bundle("lisbon Trip", BundleKind::Trip),
            ),
            (
                "Order confirmed at Zalando",
                new_bundle("Zalando order", BundleKind::Shopping),
            ),
            (
                "Thanks for shopping",
                new_bundle("Shopping", BundleKind::Shopping),
            ),
        ]);
        e.set_ai_backend(Some(backend.clone()));

        e.bundle_pending().await;
        let listed = e.list_bundles().unwrap();
        assert_eq!(
            listed.len(),
            1,
            "the one-email Zalando bundle is still forming"
        );
        assert_eq!(listed[0].name, "Lisbon trip");
        assert!(listed[0].automatic);
        assert_eq!(listed[0].thread_count, 2);
        assert_eq!(
            e.get_thread_row("news".into()).unwrap().unwrap().bundle_id,
            None
        );
        assert_eq!(
            e.get_thread_row("generic".into())
                .unwrap()
                .unwrap()
                .bundle_id,
            None,
            "a kind is not a bundle name"
        );
        // Later emails were shown the bundles made earlier in the round.
        let asked = backend.bundles_asked.lock().unwrap().clone();
        let hotel = asked
            .iter()
            .find(|(s, _)| s == "Casa Alfama: your stay")
            .unwrap();
        assert_eq!(hotel.1, vec!["Lisbon trip".to_string()]);

        // Each email is asked about once.
        let before = backend.bundles_asked.lock().unwrap().len();
        e.bundle_pending().await;
        assert_eq!(backend.bundles_asked.lock().unwrap().len(), before);

        // A correction adopts the bundle: it is the user's now.
        e.remove_from_bundle("hotel".into()).unwrap();
        let b = e.list_bundles().unwrap();
        assert!(b.is_empty() || !b[0].automatic);
        let all = e.store.list_bundles().unwrap();
        let lisbon = all.iter().find(|b| b.name == "Lisbon trip").unwrap();
        assert_eq!(lisbon.origin, BundleOrigin::User);
        // A user-owned bundle with one email stays (only model ones prune).
        e.bundle_pending().await;
        assert!(e
            .store
            .list_bundles()
            .unwrap()
            .iter()
            .any(|b| b.id == lisbon.id));
    }

    #[tokio::test]
    async fn off_means_no_model_calls_and_old_singles_are_pruned() {
        let e = open("auto-off");
        let now = now_ms();
        add(&e, "t1", "Your flight to Rome", now, false);
        let backend = scripted(&[(
            "Your flight to Rome",
            new_bundle("Rome trip", BundleKind::Trip),
        )]);
        e.set_ai_backend(Some(backend.clone()));
        e.store
            .set_pref(AUTO_BUNDLES_PREF, Some(&serde_json::json!(false)))
            .unwrap();
        e.bundle_pending().await;
        assert!(backend.bundles_asked.lock().unwrap().is_empty());

        // A model bundle left with one old email goes away.
        let mut b = core_bundles::new_bundle("Paris trip", domain::BundleKind::Trip, "");
        b.origin = BundleOrigin::Ai;
        b.created_at = now - AI_SINGLE_TTL_MS - 1;
        e.store.upsert_bundle(&b).unwrap();
        add(&e, "old", "Paris hotel", now - AI_SINGLE_TTL_MS - 1, false);
        e.store
            .set_thread_bundle(&"old".to_string(), Some((&b.id, BundleSource::Ai)))
            .unwrap();
        e.bundle_pending().await;
        assert!(!e.store.list_bundles().unwrap().iter().any(|x| x.id == b.id));
        assert_eq!(
            e.get_thread_row("old".into()).unwrap().unwrap().bundle_id,
            None
        );
    }

    #[test]
    fn the_summary_answer_is_read_line_by_line() {
        let s = parse_bundle_summary(
            "STATUS: Flights are **booked**; the hotel moved check-in to **15:00**.\nACTION: Book a hotel for **15 Dec**\n- ACTION: Check in for AT 1323\nACTION: none",
        );
        assert_eq!(
            s.status,
            "Flights are **booked**; the hotel moved check-in to **15:00**."
        );
        assert_eq!(
            s.actions,
            vec!["Book a hotel for **15 Dec**", "Check in for AT 1323"]
        );
        let loose = parse_bundle_summary("All settled.\nACTION: none");
        assert_eq!(loose.status, "All settled.");
        assert!(loose.actions.is_empty());
        assert_eq!(
            host_of("https://track.dpd.example/abc?x"),
            "track.dpd.example"
        );
    }

    #[test]
    fn tracking_links_land_in_the_detail() {
        let e = open("links");
        add(&e, "ship", "Your order #112-334 has shipped", 1_000, false);
        e.store
            .upsert_message(&heypigeon_core::domain::Message {
                id: "ship-m1".into(),
                thread_id: "ship".into(),
                account_id: "me@x.com".into(),
                from_addr: "shop@example.com".into(),
                to_addrs: vec!["me@x.com".into()],
                date: 1_000,
                snippet: "Shipped".into(),
                body_html: Some(
                    r#"<a href="https://track.dpd.example/abc">Track your parcel</a>
                       <a href="https://track.dpd.example/abc?item=2">Track item 2</a>
                       <img src="https://m.media-amazon.example/images/G/track-pixel.gif">"#
                        .into(),
                ),
                body_text: None,
                label_ids: vec!["INBOX".into()],
                is_read: true,
                ..Default::default()
            })
            .unwrap();
        let b = e
            .create_bundle(
                "Gifts".into(),
                BundleKind::Shopping,
                "".into(),
                vec!["ship".into()],
            )
            .unwrap();
        let d = e.bundle_detail(b.id).unwrap().unwrap();
        assert_eq!(d.links.len(), 1);
        assert_eq!(d.links[0].host, "track.dpd.example");
        assert_eq!(d.links[0].thread_id, "ship");
        assert_eq!(d.links[0].subject, "Your order #112-334 has shipped");
    }

    #[test]
    fn names_are_one_short_line() {
        assert_eq!(clean_name("  \"Lisbon\n trip.\" "), "Lisbon trip");
        assert_eq!(clean_name(&"x".repeat(60)).len(), 40);
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
