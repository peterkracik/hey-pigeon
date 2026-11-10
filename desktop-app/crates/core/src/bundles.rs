//! Bundles: the deterministic half (docs/bundles.md "Assignment").
//!
//! `extract_anchors` pulls the identifiers that tie emails about one thing
//! together — booking references, order, invoice and tracking numbers,
//! flight numbers — out of a subject and snippet. Two threads sharing an
//! anchor are about the same thing, so a thread that shares one with a
//! thread already in a bundle joins it (`Link`). No model is involved: this
//! layer is meant to be near-certain, so it only fires on an identifier
//! that follows a keyword saying what it is ("Order #112-334", "booking
//! reference K7QX2M"), never on a bare number.
//!
//! Anchors are stored as `"<kind>:<VALUE>"` strings (`order:112-334`),
//! upper-cased with spaces removed, so equality is string equality.

use std::collections::hash_map::RandomState;
use std::collections::{BTreeMap, HashSet};
use std::fmt;
use std::hash::{BuildHasher, Hasher};

use crate::domain::{now_ms, Bundle, BundleOrigin, BundleSource, BundleStatus, ThreadId};
use crate::ports::{Store, StoreError};

/// What an anchor identifies. Decides how the bundle view labels the fact.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum AnchorKind {
    Flight,
    Booking,
    Order,
    Invoice,
    Tracking,
}

impl AnchorKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            AnchorKind::Flight => "flight",
            AnchorKind::Booking => "booking",
            AnchorKind::Order => "order",
            AnchorKind::Invoice => "invoice",
            AnchorKind::Tracking => "tracking",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "flight" => AnchorKind::Flight,
            "booking" => AnchorKind::Booking,
            "order" => AnchorKind::Order,
            "invoice" => AnchorKind::Invoice,
            "tracking" => AnchorKind::Tracking,
            _ => return None,
        })
    }
}

/// One identifier found in an email.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Anchor {
    pub kind: AnchorKind,
    /// Upper-cased, no spaces: `112-334`, `K7QX2M`, `AT1323`.
    pub value: String,
}

impl Anchor {
    fn new(kind: AnchorKind, value: &str) -> Self {
        Self {
            kind,
            value: value.to_uppercase(),
        }
    }

    /// Parse the stored `"<kind>:<VALUE>"` form.
    pub fn parse(s: &str) -> Option<Self> {
        let (kind, value) = s.split_once(':')?;
        Some(Self {
            kind: AnchorKind::parse(kind)?,
            value: value.to_string(),
        })
    }
}

impl fmt::Display for Anchor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}", self.kind.as_str(), self.value)
    }
}

/// Words that name an identifier, and the kind they name. Matched as whole
/// words, case-insensitively. Multi-word phrases are not needed: the scan
/// skips filler words ("reference", "number", "no.") after the keyword.
const KEYWORDS: &[(&str, AnchorKind)] = &[
    ("order", AnchorKind::Order),
    ("objednávka", AnchorKind::Order),
    ("objednávky", AnchorKind::Order),
    ("bestellung", AnchorKind::Order),
    ("commande", AnchorKind::Order),
    ("invoice", AnchorKind::Invoice),
    ("faktura", AnchorKind::Invoice),
    ("rechnung", AnchorKind::Invoice),
    ("booking", AnchorKind::Booking),
    ("reservation", AnchorKind::Booking),
    ("rezervace", AnchorKind::Booking),
    ("rezervácia", AnchorKind::Booking),
    ("confirmation", AnchorKind::Booking),
    ("pnr", AnchorKind::Booking),
    ("tracking", AnchorKind::Tracking),
    ("parcel", AnchorKind::Tracking),
    ("shipment", AnchorKind::Tracking),
    ("package", AnchorKind::Tracking),
    ("zásilka", AnchorKind::Tracking),
    ("zásielka", AnchorKind::Tracking),
    ("flight", AnchorKind::Flight),
    ("let", AnchorKind::Flight),
    ("flug", AnchorKind::Flight),
    ("vol", AnchorKind::Flight),
];

/// Words that may sit between a keyword and its identifier ("Order
/// number: 112-334", "booking reference is K7QX2M").
const FILLER: &[&str] = &[
    "#",
    "no",
    "nr",
    "num",
    "number",
    "číslo",
    "cislo",
    "č",
    "ref",
    "reference",
    "code",
    "id",
    "is",
    "was",
    "has",
    "number:",
    "confirmed",
    "details",
    "for",
    "your",
    "the",
    "of",
];

/// How many tokens after a keyword may still hold its identifier.
const LOOKAHEAD: usize = 4;

/// Every anchor in `text` (a subject and a snippet, joined), deduplicated,
/// in a stable order.
pub fn extract_anchors(text: &str) -> Vec<Anchor> {
    let tokens: Vec<&str> = text.split_whitespace().collect();
    let mut found: Vec<Anchor> = Vec::new();
    for (i, raw) in tokens.iter().enumerate() {
        let word = trim_punct(raw).to_lowercase();
        // "order#112-334": the keyword glued to its number.
        let (word, glued) = match word.split_once('#') {
            Some((w, rest)) if !w.is_empty() => (w.to_string(), Some(rest.to_string())),
            _ => (word, None),
        };
        let Some(kind) = KEYWORDS
            .iter()
            .find(|(k, _)| *k == word)
            .map(|(_, kind)| *kind)
        else {
            continue;
        };
        if let Some(value) = glued.as_deref().and_then(|g| accept(kind, g)) {
            found.push(Anchor::new(kind, &value));
            continue;
        }
        if kind == AnchorKind::Flight {
            if let Some(a) = flight_after(&tokens[i + 1..]) {
                found.push(a);
            }
            continue;
        }
        for next in tokens.iter().skip(i + 1).take(LOOKAHEAD) {
            let cleaned = trim_punct(next);
            let bare = cleaned.trim_start_matches('#');
            if bare.is_empty() || FILLER.contains(&bare.to_lowercase().trim_end_matches('.')) {
                continue;
            }
            if let Some(value) = accept(kind, bare) {
                found.push(Anchor::new(kind, &value));
            }
            break;
        }
    }
    // A bare UPS number needs no keyword: "1Z" plus 16 characters is
    // distinctive enough on its own.
    for raw in &tokens {
        let t = trim_punct(raw).to_uppercase();
        if t.len() == 18 && t.starts_with("1Z") && t.chars().all(|c| c.is_ascii_alphanumeric()) {
            found.push(Anchor::new(AnchorKind::Tracking, &t));
        }
    }
    found.sort();
    found.dedup();
    found
}

/// Strip the punctuation that clings to a word in prose, keeping the
/// characters identifiers use (`-`, `/`, `#`).
fn trim_punct(s: &str) -> &str {
    s.trim_matches(|c: char| {
        matches!(
            c,
            '.' | ','
                | ';'
                | ':'
                | '('
                | ')'
                | '['
                | ']'
                | '"'
                | '\''
                | '!'
                | '?'
                | '“'
                | '”'
                | '«'
                | '»'
        )
    })
}

/// Whether `token` looks like an identifier of `kind`; returns it
/// normalized. Every kind needs digits except a booking code, which may be
/// six letters (an airline PNR).
fn accept(kind: AnchorKind, token: &str) -> Option<String> {
    let t = token.trim_matches('-');
    if !t
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '/')
    {
        return None;
    }
    let digits = t.chars().filter(char::is_ascii_digit).count();
    let letters = t.chars().filter(|c| c.is_ascii_alphabetic()).count();
    let len = t.chars().count();
    let ok = match kind {
        AnchorKind::Order | AnchorKind::Invoice => (4..=30).contains(&len) && digits >= 3,
        AnchorKind::Tracking => (8..=35).contains(&len) && digits >= 6,
        AnchorKind::Booking => {
            let upper = t == t.to_uppercase();
            (5..=12).contains(&len)
                && upper
                && (digits >= 1 || (len == 6 && letters == 6))
                && !t.contains('/')
        }
        AnchorKind::Flight => false,
    };
    ok.then(|| t.to_string())
}

/// A flight number in the tokens after "flight": an airline code (two
/// letters, or a letter and a digit) and one to four digits, written
/// together ("AT1323") or apart ("AT 1323").
fn flight_after(tokens: &[&str]) -> Option<Anchor> {
    let words: Vec<&str> = tokens
        .iter()
        .take(LOOKAHEAD)
        .map(|t| trim_punct(t))
        .collect();
    for (i, w) in words.iter().enumerate() {
        if FILLER.contains(&w.to_lowercase().as_str()) {
            continue;
        }
        if let Some(n) = flight_number(w) {
            return Some(Anchor::new(AnchorKind::Flight, &n));
        }
        if is_airline_code(w) {
            if let Some(next) = words.get(i + 1) {
                if (1..=4).contains(&next.len()) && next.chars().all(|c| c.is_ascii_digit()) {
                    return Some(Anchor::new(AnchorKind::Flight, &format!("{w}{next}")));
                }
            }
        }
        return None;
    }
    None
}

fn is_airline_code(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 2
        && b.iter()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
        && b.iter().any(|c| c.is_ascii_uppercase())
}

fn flight_number(s: &str) -> Option<String> {
    if s.len() < 3 || s.len() > 6 || !s.is_ascii() {
        return None;
    }
    let (code, num) = s.split_at(2);
    (is_airline_code(code) && num.chars().all(|c| c.is_ascii_digit())).then(|| s.to_string())
}

/// A new random bundle id: 128 bits as hex, like triage label ids. Two
/// devices creating bundles offline never collide. `RandomState` is seeded
/// from the OS per instance, which is all an id needs (not a secret).
pub fn new_bundle_id() -> String {
    let mut out = String::with_capacity(32);
    for salt in [now_ms() as u64, std::process::id() as u64] {
        let mut h = RandomState::new().build_hasher();
        h.write_u64(salt);
        out.push_str(&format!("{:016x}", h.finish()));
    }
    out
}

/// The text anchors are read from: the subject and every stored message's
/// snippet (the thread's own snippet is only the newest message).
fn thread_text<S: Store>(store: &S, thread_id: &ThreadId, subject: &str, snippet: &str) -> String {
    let mut text = format!("{subject} \n {snippet}");
    if let Ok(messages) = store.list_message_meta(thread_id) {
        for m in messages {
            text.push_str(" \n ");
            text.push_str(&m.snippet);
        }
    }
    text
}

/// What one `link_pass` did.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct LinkOutcome {
    /// Threads whose anchors were (re)scanned.
    pub scanned: usize,
    /// Threads that joined a bundle through a shared anchor.
    pub linked: Vec<ThreadId>,
    /// Archived bundles a newly linked thread reopened (a refund, a
    /// "how was your stay").
    pub reopened: Vec<String>,
}

impl LinkOutcome {
    pub fn changed(&self) -> bool {
        !self.linked.is_empty() || !self.reopened.is_empty()
    }
}

/// One round of the deterministic layer, run at the end of each sync:
/// scan up to `limit` threads whose anchors are stale, then join each
/// scanned thread that is in no bundle to the one bundle it shares an
/// anchor with. Two candidate bundles means the anchor is ambiguous and
/// the thread stays out; an exclusion (the user removed it) always wins.
pub fn link_pass<S: Store>(store: &S, limit: u32) -> Result<LinkOutcome, StoreError> {
    let mut outcome = LinkOutcome::default();
    let stale = store.list_threads_needing_anchors(limit)?;
    // Scan first and store every thread's anchors as one write (a batch is
    // up to `limit` threads, and one commit each held the write lock for
    // the whole pass), then link: a thread may join through another one
    // scanned in this same batch.
    let scanned: Vec<(ThreadId, Vec<String>, i64)> = stale
        .iter()
        .map(|t| {
            let text = thread_text(store, &t.id, &t.subject, &t.snippet);
            let anchors = extract_anchors(&text)
                .iter()
                .map(|a| a.to_string())
                .collect();
            (t.id.clone(), anchors, t.msg_count)
        })
        .collect();
    store.set_thread_anchors_batch(&scanned)?;
    outcome.scanned = scanned.len();
    for (t, (_, anchors, _)) in stale.iter().zip(&scanned) {
        if t.bundle_id.is_some() || anchors.is_empty() {
            continue;
        }
        if let Some(bundle_id) = candidate_bundle(store, &t.id, anchors)? {
            store.set_thread_bundle(&t.id, Some((&bundle_id, BundleSource::Link)))?;
            outcome.linked.push(t.id.clone());
            if reopen(store, &bundle_id)? {
                outcome.reopened.push(bundle_id);
            }
        }
    }
    Ok(outcome)
}

/// The single bundle that the threads sharing `anchors` with `thread_id`
/// belong to, unless the user excluded the thread from it.
fn candidate_bundle<S: Store>(
    store: &S,
    thread_id: &ThreadId,
    anchors: &[String],
) -> Result<Option<String>, StoreError> {
    let mut bundles: HashSet<String> = HashSet::new();
    for (other, _) in store.threads_with_anchors(anchors)? {
        if &other == thread_id {
            continue;
        }
        if let Some(b) = store.get_thread(&other)?.and_then(|t| t.bundle_id) {
            bundles.insert(b);
        }
    }
    if bundles.len() != 1 {
        return Ok(None);
    }
    let Some(bundle_id) = bundles.into_iter().next() else {
        return Ok(None);
    };
    let exists = store.list_bundles()?.iter().any(|b| b.id == bundle_id);
    if !exists || store.is_excluded_from_bundle(&bundle_id, thread_id)? {
        return Ok(None);
    }
    Ok(Some(bundle_id))
}

/// The bundle a thread most likely belongs to, for the top of the "Add
/// to bundle" picker: the one bundle it shares an anchor with. Scans the
/// thread first if it has never been scanned.
pub fn suggest_for<S: Store>(
    store: &S,
    thread_id: &ThreadId,
) -> Result<Option<String>, StoreError> {
    let Some(t) = store.get_thread(thread_id)? else {
        return Ok(None);
    };
    let mut anchors = store.thread_anchors(thread_id)?;
    if anchors.is_empty() {
        let text = thread_text(store, &t.id, &t.subject, &t.snippet);
        anchors = extract_anchors(&text)
            .iter()
            .map(|a| a.to_string())
            .collect();
        store.set_thread_anchors(&t.id, &anchors, t.msg_count)?;
    }
    if anchors.is_empty() {
        return Ok(None);
    }
    let found = candidate_bundle(store, thread_id, &anchors)?;
    Ok(found.filter(|b| t.bundle_id.as_deref() != Some(b.as_str())))
}

/// Bring an archived bundle back to the active list. Ok(true) if it was
/// archived.
fn reopen<S: Store>(store: &S, bundle_id: &str) -> Result<bool, StoreError> {
    let Some(mut b) = store
        .list_bundles()?
        .into_iter()
        .find(|b| b.id == bundle_id)
    else {
        return Ok(false);
    };
    if b.status != BundleStatus::Archived {
        return Ok(false);
    }
    b.status = BundleStatus::Active;
    b.updated_at = now_ms();
    store.upsert_bundle(&b)?;
    Ok(true)
}

/// The user put `thread_id` into `bundle_id`: pull in the threads that
/// share an anchor with it and are in no bundle yet (the shipping notice
/// for the invoice just added). One hop, so a stray shared number cannot
/// chain unrelated mail together. Returns the threads that joined.
pub fn spread_from<S: Store>(
    store: &S,
    thread_id: &ThreadId,
    bundle_id: &str,
) -> Result<Vec<ThreadId>, StoreError> {
    let mut anchors = store.thread_anchors(thread_id)?;
    if anchors.is_empty() {
        // Not scanned yet (older mail): scan it now.
        if let Some(t) = store.get_thread(thread_id)? {
            let text = thread_text(store, &t.id, &t.subject, &t.snippet);
            anchors = extract_anchors(&text)
                .iter()
                .map(|a| a.to_string())
                .collect();
            store.set_thread_anchors(&t.id, &anchors, t.msg_count)?;
        }
    }
    let mut joined = Vec::new();
    for (other, _) in store.threads_with_anchors(&anchors)? {
        if &other == thread_id {
            continue;
        }
        let Some(t) = store.get_thread(&other)? else {
            continue;
        };
        if t.bundle_id.is_some() || store.is_excluded_from_bundle(bundle_id, &other)? {
            continue;
        }
        store.set_thread_bundle(&other, Some((bundle_id, BundleSource::Link)))?;
        joined.push(other);
    }
    Ok(joined)
}

/// Links in an email that track a parcel or an order: an `href` (HTML) or
/// a bare URL (plain text) whose address or link text says "track", plus
/// any link that carries one of `numbers` (the tracking numbers found).
/// Deduplicated, in order of appearance, at most five.
pub fn tracking_links(text: &str, numbers: &[String]) -> Vec<String> {
    let lower = text.to_lowercase();
    let mut out: Vec<String> = Vec::new();
    let mut start = 0;
    while let Some(pos) = lower[start..].find("http") {
        let at = start + pos;
        let rest = &text[at..];
        let end = rest
            .find(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | '<' | '>' | ')' | ']'))
            .unwrap_or(rest.len());
        let url = rest[..end]
            .trim_end_matches(['.', ',', ';'])
            .replace("&amp;", "&");
        start = at + end.max(4);
        if !(url.starts_with("https://") || url.starts_with("http://")) {
            continue;
        }
        // The link text right after an HTML anchor ("Track your parcel").
        let after = &lower[(at + end).min(lower.len())..];
        let label = after
            .split_once('>')
            .map(|(_, t)| t.split('<').next().unwrap_or(""))
            .unwrap_or("");
        // Pictures and tracking pixels are not links to follow.
        if is_asset_url(&url) {
            continue;
        }
        let upper = url.to_uppercase();
        let tracks = url.to_lowercase().contains("track")
            || (after.starts_with('"') && label.contains("track"))
            || numbers.iter().any(|n| upper.contains(n.as_str()));
        if tracks && !out.contains(&url) {
            out.push(url);
        }
        if out.len() == 5 {
            break;
        }
    }
    out
}

/// An image, a style sheet or a script, by its path or its host (a CDN
/// serving mail assets: `m.media-amazon.com`, `img.`, `static.`).
fn is_asset_url(url: &str) -> bool {
    let lower = url.to_lowercase();
    let path = lower.split_once("://").map(|(_, r)| r).unwrap_or(&lower);
    let (host, rest) = path.split_once('/').unwrap_or((path, ""));
    let file = rest.split(['?', '#']).next().unwrap_or("");
    const EXT: &[&str] = &[
        ".gif", ".png", ".jpg", ".jpeg", ".webp", ".svg", ".css", ".js", ".ico",
    ];
    EXT.iter().any(|e| file.ends_with(e))
        || file.contains("/images/")
        || file.contains("pixel")
        || host.split('.').next().is_some_and(|h| {
            matches!(
                h,
                "img" | "image" | "images" | "static" | "cdn" | "media" | "assets"
            ) || h.ends_with("media")
        })
        || host.contains("media-amazon")
}

/// One key fact in the bundle view: an identifier and the email it came
/// from (docs/bundles.md "Summary"). Every fact links back to its source.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BundleFact {
    pub anchor: Anchor,
    /// The newest thread carrying this anchor.
    pub thread_id: ThreadId,
    /// That thread's newest message, epoch ms.
    pub at: i64,
}

/// The facts for a bundle: each distinct anchor across its threads, by
/// kind (flights first, tracking last), then oldest first so a trip reads
/// in order.
pub fn bundle_facts<S: Store>(store: &S, bundle_id: &str) -> Result<Vec<BundleFact>, StoreError> {
    // Threads come newest first, so the first sighting of an anchor is its
    // newest source.
    let mut seen: BTreeMap<Anchor, (ThreadId, i64)> = BTreeMap::new();
    for t in store.list_bundle_threads(bundle_id)? {
        for raw in store.thread_anchors(&t.id)? {
            if let Some(a) = Anchor::parse(&raw) {
                seen.entry(a)
                    .or_insert_with(|| (t.id.clone(), t.last_msg_at));
            }
        }
    }
    let mut facts: Vec<BundleFact> = seen
        .into_iter()
        .map(|(anchor, (thread_id, at))| BundleFact {
            anchor,
            thread_id,
            at,
        })
        .collect();
    facts.sort_by(|a, b| a.anchor.kind.cmp(&b.anchor.kind).then(a.at.cmp(&b.at)));
    Ok(facts)
}

/// A new bundle row, active, stamped now.
pub fn new_bundle(name: &str, kind: crate::domain::BundleKind, description: &str) -> Bundle {
    let now = now_ms();
    Bundle {
        id: new_bundle_id(),
        name: name.to_string(),
        kind,
        description: description.to_string(),
        status: BundleStatus::Active,
        origin: BundleOrigin::User,
        created_at: now,
        updated_at: now,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(text: &str) -> Vec<String> {
        extract_anchors(text)
            .iter()
            .map(|a| a.to_string())
            .collect()
    }

    #[test]
    fn order_numbers_after_the_keyword() {
        assert_eq!(
            kinds("Your order #112-334 has shipped"),
            vec!["order:112-334"]
        );
        assert_eq!(
            kinds("Order number: 4471982 confirmed"),
            vec!["order:4471982"]
        );
        assert_eq!(kinds("Re: order#A-55120"), vec!["order:A-55120"]);
        assert_eq!(
            kinds("Vaše objednávka č. 2026-1189 byla odeslána"),
            vec!["order:2026-1189"]
        );
    }

    #[test]
    fn booking_codes_need_a_keyword_and_a_code_shape() {
        assert_eq!(
            kinds("Booking confirmed · booking reference K7QX2M"),
            vec!["booking:K7QX2M"]
        );
        assert_eq!(
            kinds("Reservation 4471-982 at Casa Alfama"),
            vec!["booking:4471-982"]
        );
        // Lowercase prose after the keyword is not a code.
        assert!(kinds("Your booking is ready").is_empty());
        assert!(kinds("Thanks for your reservation request").is_empty());
    }

    #[test]
    fn flights_with_and_without_a_space() {
        assert_eq!(
            kinds("Check in for flight AT1323 now"),
            vec!["flight:AT1323"]
        );
        assert_eq!(
            kinds("Your flight AT 1326 to Prague"),
            vec!["flight:AT1326"]
        );
        assert_eq!(kinds("Flight U2 4517 is delayed"), vec!["flight:U24517"]);
        assert!(kinds("Flight delayed, sorry").is_empty());
    }

    #[test]
    fn tracking_numbers() {
        assert_eq!(
            kinds("Track your parcel: 00340434161094000000"),
            vec!["tracking:00340434161094000000"]
        );
        assert_eq!(
            kinds("It's on its way 1Z999AA10123456784"),
            vec!["tracking:1Z999AA10123456784"]
        );
        // Too few digits for a tracking number.
        assert!(kinds("Your package ABC-12 arrives").is_empty());
    }

    #[test]
    fn plain_prose_and_bare_numbers_give_nothing() {
        assert!(kinds("Sunday lunch? Bring the kids at 12:30").is_empty());
        assert!(kinds("Call me on 0905 123 456").is_empty());
        assert!(kinds("In order to help, here is 2026's plan").is_empty());
    }

    #[test]
    fn several_anchors_dedupe_and_sort() {
        assert_eq!(
            kinds("Order 112-334 shipped. Order 112-334, tracking 1Z999AA10123456784"),
            vec!["order:112-334", "tracking:1Z999AA10123456784"]
        );
    }

    use crate::domain::{BundleKind, Thread};
    use crate::fakes::MemStore;

    fn thread(id: &str, subject: &str, at: i64) -> Thread {
        Thread {
            id: id.into(),
            account_id: "a".into(),
            subject: subject.into(),
            snippet: String::new(),
            last_msg_at: at,
            is_read: true,
            is_inbox: true,
            is_archived: false,
            msg_count: 1,
            from_summary: "x".into(),
            last_from_addr: "x@example.com".into(),
            scheduled_at: None,
            labels: vec!["INBOX".into()],
            has_attachment: false,
            priority: None,
            triage_label_ids: vec![],
            needs_reply: false,
            follow_up_since: None,
            suggestion: None,
            bundle_id: None,
        }
    }

    fn store_with(threads: &[Thread]) -> MemStore {
        let s = MemStore::default();
        for t in threads {
            s.upsert_thread(t).unwrap();
        }
        s
    }

    #[test]
    fn a_shared_order_number_links_a_new_thread() {
        let s = store_with(&[
            thread("invoice", "Invoice for order #112-334", 1),
            thread("shipped", "Your order #112-334 has shipped", 2),
            thread("lunch", "Sunday lunch?", 3),
        ]);
        let b = new_bundle("Christmas 2026", BundleKind::Shopping, "");
        s.upsert_bundle(&b).unwrap();
        // The first pass only scans: nothing is in a bundle yet.
        let first = link_pass(&s, 100).unwrap();
        assert_eq!(first.scanned, 3);
        assert!(first.linked.is_empty());
        // The user adds the invoice; the shipping notice follows it.
        s.set_thread_bundle(&"invoice".into(), Some((&b.id, BundleSource::User)))
            .unwrap();
        assert_eq!(
            spread_from(&s, &"invoice".into(), &b.id).unwrap(),
            vec!["shipped".to_string()]
        );
        // A later email about the same order links on the next pass.
        s.upsert_thread(&thread("delivered", "Order 112-334 delivered", 4))
            .unwrap();
        let next = link_pass(&s, 100).unwrap();
        assert_eq!(next.linked, vec!["delivered".to_string()]);
        let ids: Vec<String> = s
            .list_bundle_threads(&b.id)
            .unwrap()
            .into_iter()
            .map(|t| t.id)
            .collect();
        assert_eq!(ids, vec!["delivered", "shipped", "invoice"]);
        assert!(s
            .get_thread(&"lunch".into())
            .unwrap()
            .unwrap()
            .bundle_id
            .is_none());
    }

    #[test]
    fn exclusions_and_ambiguity_keep_a_thread_out() {
        let s = store_with(&[
            thread("a1", "Booking reference K7QX2M", 1),
            thread("b1", "Order #555-777 confirmed", 2),
        ]);
        let trip = new_bundle("Lisbon", BundleKind::Trip, "");
        let shop = new_bundle("Shop", BundleKind::Shopping, "");
        s.upsert_bundle(&trip).unwrap();
        s.upsert_bundle(&shop).unwrap();
        link_pass(&s, 100).unwrap();
        s.set_thread_bundle(&"a1".into(), Some((&trip.id, BundleSource::User)))
            .unwrap();
        s.set_thread_bundle(&"b1".into(), Some((&shop.id, BundleSource::User)))
            .unwrap();
        // Excluded from the trip: the next email with its code stays out.
        s.exclude_from_bundle(&trip.id, &"a2".into()).unwrap();
        s.upsert_thread(&thread("a2", "Booking K7QX2M changed", 3))
            .unwrap();
        // Two bundles share nothing with this one, but it names both codes.
        s.upsert_thread(&thread("mix", "Booking K7QX2M and order 555-777", 4))
            .unwrap();
        let out = link_pass(&s, 100).unwrap();
        assert!(out.linked.is_empty());
    }

    #[test]
    fn linking_reopens_an_archived_bundle_and_facts_list_anchors() {
        let s = store_with(&[thread("t1", "Flight AT1323 booking reference K7QX2M", 10)]);
        let mut trip = new_bundle("Lisbon", BundleKind::Trip, "");
        s.upsert_bundle(&trip).unwrap();
        link_pass(&s, 100).unwrap();
        s.set_thread_bundle(&"t1".into(), Some((&trip.id, BundleSource::User)))
            .unwrap();
        trip.status = BundleStatus::Archived;
        s.upsert_bundle(&trip).unwrap();
        s.upsert_thread(&thread("t2", "Refund for booking K7QX2M", 20))
            .unwrap();
        let out = link_pass(&s, 100).unwrap();
        assert_eq!(out.reopened, vec![trip.id.clone()]);
        let facts: Vec<String> = bundle_facts(&s, &trip.id)
            .unwrap()
            .iter()
            .map(|f| format!("{}@{}", f.anchor, f.thread_id))
            .collect();
        assert_eq!(facts, vec!["flight:AT1323@t1", "booking:K7QX2M@t2"]);
    }

    #[test]
    fn bundle_ids_are_random_hex() {
        let a = new_bundle_id();
        assert_eq!(a.len(), 32);
        assert!(a.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, new_bundle_id());
    }

    #[test]
    fn tracking_links_come_from_hrefs_and_plain_text() {
        let html = r#"<p>Shipped!</p><a href="https://shop.example/orders/112?x=1&amp;y=2">Track your parcel</a>
            <a href="https://shop.example/help">Help</a> https://carrier.example/t?n=1Z999AA10123456784."#;
        assert_eq!(
            tracking_links(html, &["1Z999AA10123456784".to_string()]),
            vec![
                "https://shop.example/orders/112?x=1&y=2".to_string(),
                "https://carrier.example/t?n=1Z999AA10123456784".to_string()
            ]
        );
        assert_eq!(
            tracking_links("Follow it: https://track.dpd.example/abc", &[]),
            vec!["https://track.dpd.example/abc".to_string()]
        );
        assert!(tracking_links("See https://shop.example/help for help", &[]).is_empty());
        // Pictures and pixels are never tracking links.
        assert!(tracking_links(
            r#"<img src="https://m.media-amazon.com/images/G/01/track.gif"> <img src="https://img.shop.example/track-pixel?x=1">"#,
            &[]
        )
        .is_empty());
    }

    #[test]
    fn stored_form_round_trips() {
        let a = Anchor::parse("booking:K7QX2M").unwrap();
        assert_eq!(a.kind, AnchorKind::Booking);
        assert_eq!(a.to_string(), "booking:K7QX2M");
        assert!(Anchor::parse("weird:1").is_none());
    }
}
