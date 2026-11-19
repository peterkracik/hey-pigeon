//! Parcels: what the mail of a bundle says about a shipment, and the list
//! the inbox's parcel card shows (docs/specs/parcel-card.md).
//!
//! Three parts, none of them a model:
//!
//! - **Reading** what one email says — a status, the day the parcel is
//!   expected, what is in it — from the shop's schema.org markup
//!   ([`from_markup`]: `ParcelDelivery` / `Order`, JSON-LD or microdata)
//!   and, where the wording is unambiguous, from the subject and the
//!   start of the preview line ([`from_text`]). Markup is read from the
//!   message as received, by the provider's full fetch: the sanitizer
//!   takes scripts and `itemprop` out of the body the store keeps.
//! - **Keeping** it per thread, one row per source
//!   ([`remember_deliveries`], and the text pass in `bundles::link_pass`).
//! - **The overview** ([`overview`]): the tracking links of each active
//!   bundle grouped into parcels — the rule the bundle's Info page uses
//!   (`BundleTracking.shipments` in the shell) — each with what its
//!   emails say, the ones that are over left out, in the card's order.
//!
//! Nothing is guessed: a field no email states is `None`, a day that is
//! implausible for its email is dropped, and no value from markup is ever
//! used as an address. Mail is untrusted: every scan here is linear in
//! the input and bounded in what it keeps.

use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value};

use crate::bundles::{self, Anchor, AnchorKind};
use crate::domain::{
    Bundle, BundleKind, BundleStatus, Delivery, DeliverySource, Message, ParcelStatus, Thread,
    ThreadId,
};
use crate::ports::{Store, StoreError};

const DAY_MS: i64 = 86_400_000;
/// Mail older than this has no parcel on its way.
pub const WINDOW_MS: i64 = 45 * DAY_MS;
/// Threads of a bundle read for parcels, newest first (the Info page's
/// `LINK_SCAN_THREADS`).
const SCAN_THREADS: usize = 15;
/// How long a delivered parcel stays, from the email that said so.
const DELIVERED_GRACE_MS: i64 = DAY_MS;
/// Days a parcel stays after the day it was expected.
const LATE_DAYS: i64 = 3;
/// How long a parcel with no day stays, from its newest email.
const UNDATED_MS: i64 = 14 * DAY_MS;
/// Most parcels the overview lists.
pub const MAX_PARCELS: usize = 12;
/// Characters of an item title.
const MAX_TITLE: usize = 120;
/// JSON-LD blocks read from one message, and the size of each.
const MAX_BLOCKS: usize = 8;
const MAX_BLOCK_BYTES: usize = 64 * 1024;
/// How deep the JSON is walked, and how many of its nodes.
const MAX_DEPTH: usize = 6;
const MAX_NODES: usize = 400;
/// A day is believed only this close to its email.
const DAYS_BEFORE: i64 = 30;
const DAYS_AFTER: i64 = 366;

// ---------------------------------------------------------------- days

/// Days since 1970-01-01 of a civil date (proleptic Gregorian).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

fn days_in_month(y: i64, m: i64) -> i64 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
        2 => 28,
        _ => 0,
    }
}

/// A real calendar date, as days since the epoch.
fn valid_day(y: i64, m: i64, d: i64) -> Option<i64> {
    ((2000..=2100).contains(&y) && (1..=12).contains(&m) && d >= 1 && d <= days_in_month(y, m))
        .then(|| days_from_civil(y, m, d))
}

fn format_day(days: i64) -> String {
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02}")
}

/// `2026-11-20`, alone or at the start of a timestamp
/// (`2026-11-20T23:59:00+01:00`), as days since the epoch. The date is
/// taken as written: the day at the place the shop meant.
fn iso_day(s: &str) -> Option<i64> {
    let b = s.trim().as_bytes();
    if b.len() < 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    if b.len() > 10 && b[10].is_ascii_digit() {
        return None;
    }
    let num = |r: std::ops::Range<usize>| -> Option<i64> {
        let part = &b[r];
        part.iter()
            .all(u8::is_ascii_digit)
            .then(|| part.iter().fold(0, |n, c| n * 10 + i64::from(c - b'0')))
    };
    valid_day(num(0..4)?, num(5..7)?, num(8..10)?)
}

/// The UTC calendar day of an instant, as `2026-11-20`.
pub fn day_string(ms: i64) -> String {
    format_day(day_of(ms, 0))
}

/// The calendar day an instant falls on, `utc_offset_min` east of UTC.
fn day_of(ms: i64, utc_offset_min: i32) -> i64 {
    (ms + i64::from(utc_offset_min) * 60_000).div_euclid(DAY_MS)
}

/// Whether an email of `at` can mean this day: not long past when it was
/// sent, not more than a year ahead. A shop's test value, a typo or a
/// hostile `1970-01-01` is dropped rather than shown.
fn plausible(day: i64, at: i64) -> bool {
    let sent = day_of(at, 0);
    (sent - DAYS_BEFORE..=sent + DAYS_AFTER).contains(&day)
}

// -------------------------------------------------------------- markup

/// What a message's schema.org markup says about a parcel: a
/// `ParcelDelivery` or an `Order`, as JSON-LD or as microdata. `html` is
/// the body as received. None when there is no such markup or it states
/// nothing usable. `at` is left 0: the caller knows the message.
pub fn from_markup(html: &str) -> Option<Delivery> {
    // Most mail has no such markup: look before copying the body.
    if !contains_ignore_ascii_case(html, "schema.org") {
        return None;
    }
    // ASCII lower-casing keeps every byte where it was, so an index found
    // in `lower` is the same place in `html`.
    let lower = html.to_ascii_lowercase();
    let found = json_ld(html, &lower).or_else(|| microdata(html, &lower))?;
    (!found.is_empty()).then_some(found)
}

/// Whether `needle` (ASCII) is in `hay` in any letter case, without a
/// lower-cased copy of `hay`.
fn contains_ignore_ascii_case(hay: &str, needle: &str) -> bool {
    let needle = needle.as_bytes();
    hay.as_bytes()
        .windows(needle.len())
        .any(|w| w.eq_ignore_ascii_case(needle))
}

/// The text of each `<script type="application/ld+json">`, bounded.
fn ld_blocks<'a>(html: &'a str, lower: &str) -> Vec<&'a str> {
    let mut out = Vec::new();
    let mut from = 0;
    while out.len() < MAX_BLOCKS {
        let Some(open) = lower[from..].find("<script").map(|p| from + p) else {
            break;
        };
        let Some(tag_end) = lower[open..].find('>').map(|p| open + p) else {
            break;
        };
        let Some(close) = lower[tag_end..].find("</script").map(|p| tag_end + p) else {
            break;
        };
        let body = &html[tag_end + 1..close];
        if lower[open..tag_end].contains("ld+json") && body.len() <= MAX_BLOCK_BYTES {
            out.push(body);
        }
        from = close + "</script".len();
    }
    out
}

fn json_ld(html: &str, lower: &str) -> Option<Delivery> {
    for block in ld_blocks(html, lower) {
        let text = block.trim();
        let text = text.strip_prefix("<!--").unwrap_or(text);
        let text = text.strip_suffix("-->").unwrap_or(text);
        // serde_json stops at its own nesting limit: deep input is an
        // error here, not a stack.
        let Ok(value) = serde_json::from_str::<Value>(text) else {
            continue;
        };
        let mut budget = MAX_NODES;
        if let Some(d) = find_delivery(&value, 0, &mut budget) {
            return Some(d);
        }
    }
    None
}

/// The first parcel or order in a JSON-LD value that states something.
fn find_delivery(v: &Value, depth: usize, budget: &mut usize) -> Option<Delivery> {
    if depth > MAX_DEPTH || *budget == 0 {
        return None;
    }
    *budget -= 1;
    match v {
        Value::Array(items) => items
            .iter()
            .find_map(|item| find_delivery(item, depth + 1, budget)),
        Value::Object(o) => {
            let found = if is_type(o, "ParcelDelivery") {
                Some(parcel_delivery(o))
            } else if is_type(o, "Order") {
                Some(order(o))
            } else {
                None
            };
            found
                .filter(|d| !d.is_empty())
                .or_else(|| find_delivery(o.get("@graph")?, depth + 1, budget))
        }
        _ => None,
    }
}

/// `ParcelDelivery`, `http://schema.org/ParcelDelivery`, or a list
/// holding either.
fn is_type(o: &Map<String, Value>, name: &str) -> bool {
    let is = |s: &str| s.rsplit('/').next().unwrap_or(s) == name;
    match o.get("@type") {
        Some(Value::String(s)) => is(s),
        Some(Value::Array(a)) => a.iter().any(|t| t.as_str().is_some_and(is)),
        _ => false,
    }
}

fn text_of<'a>(o: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    o.get(key)?.as_str()
}

/// An object, or the first object of a list.
fn object_of<'a>(o: &'a Map<String, Value>, key: &str) -> Option<&'a Map<String, Value>> {
    match o.get(key)? {
        Value::Object(inner) => Some(inner),
        Value::Array(items) => items.iter().find_map(Value::as_object),
        _ => None,
    }
}

fn parcel_delivery(o: &Map<String, Value>) -> Delivery {
    let order = object_of(o, "partOfOrder");
    let mut items = names(o.get("itemShipped"));
    if items.is_empty() {
        items = order.map(order_items).unwrap_or_default();
    }
    Delivery {
        status: order
            .and_then(|order| text_of(order, "orderStatus"))
            .and_then(status_of),
        expected_day: text_of(o, "expectedArrivalUntil")
            .and_then(iso_day)
            .or_else(|| text_of(o, "expectedArrivalFrom").and_then(iso_day))
            .map(format_day),
        expected_in_days: None,
        title: title_of(&items),
        at: 0,
    }
}

fn order(o: &Map<String, Value>) -> Delivery {
    let mut d = object_of(o, "orderDelivery")
        .map(parcel_delivery)
        .unwrap_or_default();
    d.status = text_of(o, "orderStatus").and_then(status_of).or(d.status);
    if d.title.is_none() {
        d.title = title_of(&order_items(o));
    }
    d
}

/// What an order holds: `orderedItem` (products, or order items holding
/// one) and `acceptedOffer` (offers of an item).
fn order_items(o: &Map<String, Value>) -> Vec<String> {
    let mut out = Vec::new();
    for (key, inner) in [
        ("orderedItem", "orderedItem"),
        ("acceptedOffer", "itemOffered"),
    ] {
        let entries: Vec<&Value> = match o.get(key) {
            Some(Value::Array(items)) => items.iter().take(MAX_ITEMS).collect(),
            Some(single) => vec![single],
            None => Vec::new(),
        };
        for entry in entries {
            let Some(entry) = entry.as_object() else {
                continue;
            };
            let named = names(entry.get(inner));
            if named.is_empty() {
                out.extend(text_of(entry, "name").and_then(clean_title));
            } else {
                out.extend(named);
            }
        }
        if !out.is_empty() {
            break;
        }
    }
    out
}

/// Items read from one list.
const MAX_ITEMS: usize = 20;

/// The `name` of a thing, or of each thing in a list; a bare string is
/// its own name.
fn names(v: Option<&Value>) -> Vec<String> {
    let name = |v: &Value| -> Option<String> {
        match v {
            Value::String(s) => clean_title(s),
            Value::Object(o) => text_of(o, "name").and_then(clean_title),
            _ => None,
        }
    };
    match v {
        Some(Value::Array(items)) => items.iter().take(MAX_ITEMS).filter_map(name).collect(),
        Some(single) => name(single).into_iter().collect(),
        None => Vec::new(),
    }
}

/// "Magnetic case", or "Magnetic case + 2 more".
fn title_of(items: &[String]) -> Option<String> {
    let first = items.first()?;
    Some(match items.len() {
        1 => first.clone(),
        n => format!("{first} + {} more", n - 1),
    })
}

/// A title as plain text for the app's own chrome: entities decoded,
/// one line, no control, invisible or direction-changing characters (a
/// title must not be able to rearrange the row it stands in), at most
/// `MAX_TITLE` characters. None when nothing readable is left or it is
/// an address rather than a name.
fn clean_title(raw: &str) -> Option<String> {
    let decoded = raw
        .replace("&nbsp;", " ")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&");
    let mut visible = String::with_capacity(decoded.len());
    let mut marks = 0;
    for c in decoded.chars() {
        let c = if c.is_whitespace() { ' ' } else { c };
        if c.is_control() || is_invisible(c) {
            continue;
        }
        // A letter carries a few marks ("ệ" is two); a pile of them
        // draws over the rows above and below.
        if is_combining(c) {
            marks += 1;
            if marks > MAX_MARKS {
                continue;
            }
        } else {
            marks = 0;
        }
        visible.push(c);
    }
    let one_line = visible.split_whitespace().collect::<Vec<_>>().join(" ");
    let lower = one_line.to_ascii_lowercase();
    if one_line.is_empty() || lower.starts_with("http://") || lower.starts_with("https://") {
        return None;
    }
    Some(one_line.chars().take(MAX_TITLE).collect())
}

/// Combining marks kept after one letter.
const MAX_MARKS: usize = 3;

/// Characters that draw nothing or change the direction of what follows:
/// zero-width and bidi controls (U+061C, U+200B–200F, U+202A–202E,
/// U+2060–2069, U+FEFF), the soft hyphen, the fillers that look like a
/// space but are letters (U+115F, U+1160, U+3164, U+FFA0), the Mongolian
/// vowel separator, the grapheme joiner, and the tag characters.
fn is_invisible(c: char) -> bool {
    matches!(c,
        '\u{00AD}'
            | '\u{034F}'
            | '\u{061C}'
            | '\u{115F}'
            | '\u{1160}'
            | '\u{180E}'
            | '\u{200B}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{206F}'
            | '\u{3164}'
            | '\u{FEFF}'
            | '\u{FFA0}'
            | '\u{FFF9}'..='\u{FFFB}'
            | '\u{E0000}'..='\u{E007F}')
}

/// The marks that stack on the letter before them: the combining
/// diacritics blocks, and the Hebrew, Arabic and Thai ones. Not every
/// mark Unicode has — the ones a title can be piled high with.
fn is_combining(c: char) -> bool {
    matches!(c,
        '\u{0300}'..='\u{036F}'
            | '\u{0483}'..='\u{0489}'
            | '\u{0591}'..='\u{05BD}'
            | '\u{0610}'..='\u{061A}'
            | '\u{064B}'..='\u{065F}'
            | '\u{06D6}'..='\u{06DC}'
            | '\u{0E31}'
            | '\u{0E34}'..='\u{0E3A}'
            | '\u{0E47}'..='\u{0E4E}'
            | '\u{1AB0}'..='\u{1AFF}'
            | '\u{1DC0}'..='\u{1DFF}'
            | '\u{20D0}'..='\u{20FF}'
            | '\u{FE20}'..='\u{FE2F}')
}

/// schema.org's `OrderStatus` values, and the plain words some shops
/// write in their place. Anything else (processing, cancelled, a
/// problem) is not a parcel's status.
fn status_of(raw: &str) -> Option<ParcelStatus> {
    let name: String = raw
        .trim()
        .rsplit('/')
        .next()
        .unwrap_or(raw)
        .chars()
        .filter(|c| c.is_ascii_alphabetic())
        .collect::<String>()
        .to_ascii_lowercase();
    Some(match name.as_str() {
        "orderintransit" | "intransit" | "shipped" => ParcelStatus::Shipped,
        "outfordelivery" => ParcelStatus::OutForDelivery,
        "orderdelivered" | "delivered" => ParcelStatus::Delivered,
        _ => return None,
    })
}

/// Microdata, read flat: the properties whose names say enough on their
/// own (`expectedArrivalUntil`, `orderStatus`), and the first `name`
/// right after `itemShipped`. No tree is built — a real parse of hostile
/// HTML for three values is not worth its cost; a property that is not
/// where this looks is simply not found.
fn microdata(html: &str, lower: &str) -> Option<Delivery> {
    let typed = lower.contains("schema.org/parceldelivery") || lower.contains("schema.org/order");
    if !typed || !lower.contains("itemprop") {
        return None;
    }
    let expected = prop(html, lower, "expectedarrivaluntil", 0, lower.len())
        .and_then(|v| iso_day(&v))
        .or_else(|| {
            prop(html, lower, "expectedarrivalfrom", 0, lower.len()).and_then(|v| iso_day(&v))
        });
    let status = prop(html, lower, "orderstatus", 0, lower.len()).and_then(|v| status_of(&v));
    let title = find_prop(lower, "itemshipped", 0, lower.len()).and_then(|at| {
        // Back to the start of a character: that many bytes on may be
        // the middle of a letter ("ž"), and a slice there is no slice.
        let mut until = (at + ITEM_NAME_REACH).min(lower.len());
        while !lower.is_char_boundary(until) {
            until -= 1;
        }
        prop(html, lower, "name", at + 1, until).and_then(|v| clean_title(&v))
    });
    Some(Delivery {
        status,
        expected_day: expected.map(format_day),
        expected_in_days: None,
        title,
        at: 0,
    })
}

/// How far after `itemprop="itemShipped"` its `name` may stand, in bytes.
const ITEM_NAME_REACH: usize = 800;
/// Characters of an element's text taken as a property's value.
const MAX_PROP_TEXT: usize = 300;

/// Where `itemprop="<name>"` stands in `lower[from..until]`.
fn find_prop(lower: &str, name: &str, from: usize, until: usize) -> Option<usize> {
    let mut at = from;
    while at < until {
        let found = at + lower.get(at..until)?.find("itemprop=")?;
        let rest = lower[found + "itemprop=".len()..].trim_start_matches(['"', '\'']);
        // `strip_prefix`, not a slice at the name's length: what follows
        // is mail, and that many bytes in may be the middle of a letter.
        let named = rest.strip_prefix(name).is_some_and(|after| {
            after
                .chars()
                .next()
                .is_none_or(|c| matches!(c, '"' | '\'' | '>' | '/') || c.is_ascii_whitespace())
        });
        if named {
            return Some(found);
        }
        at = found + "itemprop=".len();
    }
    None
}

/// The value of the first `itemprop="<name>"` in `lower[from..until]`:
/// the element's `content`, `datetime` or `href`, else its text.
fn prop(html: &str, lower: &str, name: &str, from: usize, until: usize) -> Option<String> {
    let at = find_prop(lower, name, from, until)?;
    let start = lower[..at].rfind('<')?;
    let end = at + lower[at..].find('>')?;
    let (tag, tag_lower) = (&html[start..end], &lower[start..end]);
    for attribute in ["content", "datetime", "href"] {
        if let Some(value) = attr(tag, tag_lower, attribute) {
            return Some(value);
        }
    }
    let text = &html[end + 1..];
    let text = &text[..text.find('<').unwrap_or(text.len())];
    let text: String = text.trim().chars().take(MAX_PROP_TEXT).collect();
    (!text.is_empty()).then_some(text)
}

/// One attribute's value in a tag's text.
fn attr(tag: &str, tag_lower: &str, name: &str) -> Option<String> {
    let mut from = 0;
    loop {
        let at = from + tag_lower[from..].find(name)?;
        let after = at + name.len();
        let starts_word = tag_lower[..at]
            .chars()
            .next_back()
            .is_some_and(|c| c.is_ascii_whitespace());
        if starts_word && tag_lower[after..].starts_with('=') {
            let value = &tag[after + 1..];
            let value = match value.chars().next()? {
                q @ ('"' | '\'') => value[1..].split(q).next()?,
                _ => value.split(|c: char| c.is_ascii_whitespace()).next()?,
            };
            return Some(value.to_string());
        }
        from = after;
    }
}

// ---------------------------------------------------------------- text

/// Characters of the preview line read for a status or a day: its first
/// sentence or two. Further in, "shipped" is as likely to be about what
/// happens next.
const SNIPPET_HEAD: usize = 160;

/// What a subject and the start of a preview line say, where the wording
/// is unambiguous (docs/specs/parcel-card.md R3.2). `at` is the email's
/// time: a date written without a year is the next such date from then.
pub fn from_text(subject: &str, snippet: &str, at: i64) -> Option<Delivery> {
    let head: String = snippet.chars().take(SNIPPET_HEAD).collect();
    let status = status_in(subject).or_else(|| status_in(&head));
    // A delivered parcel is expected no more; "delivered today" is not
    // a day to wait for.
    let day = (status != Some(ParcelStatus::Delivered))
        .then(|| day_in(subject, at).or_else(|| day_in(&head, at)))
        .flatten();
    let d = Delivery {
        status,
        expected_day: match day {
            Some(Day::On(days)) => Some(format_day(days)),
            _ => None,
        },
        expected_in_days: match day {
            Some(Day::In(n)) => Some(n),
            _ => None,
        },
        title: None,
        at,
    };
    (!d.is_empty()).then_some(d)
}

/// Words before a status word that turn it into something else: a
/// promise, a condition, a failure. Looked for in the four words before
/// ("once your order has shipped").
const NOT_YET: &[&str] = &[
    "not",
    "no",
    "never",
    "will",
    "would",
    "can",
    "could",
    "cannot",
    "be",
    "being",
    "to",
    "once",
    "when",
    "until",
    "if",
    "unable",
    "failed",
    "attempt",
    "attempted",
    "shall",
    "should",
    "soon",
    "get",
    "getting",
    "before",
    "after", // cs / sk
    "nebyla",
    "nebola",
    "nebylo",
    "nebolo",
    "nepodařilo",
    "nepodarilo",
    "bude",
    "budou",
    "budú",
    "až",
    "ak",
    "pokud",
    "než", // de
    "nicht",
    "wird",
    "werden",
    "konnte",
    "wenn",
    "sobald",
];

const NOT_YET_REACH: usize = 4;

const DELIVERED: &[&[&str]] = &[
    &["delivered"],
    &["zugestellt"],
    &["doručena"],
    &["doručená"],
    &["doručeno"],
    &["doručené"],
    &["doručili", "jsme"],
    &["doručili", "sme"],
    &["livré"],
    &["livrée"],
];

const OUT_FOR_DELIVERY: &[&[&str]] = &[
    &["out", "for", "delivery"],
    &["in", "zustellung"],
    &["wird", "heute", "zugestellt"],
    &["dnes", "doručíme"],
    &["bude", "dnes", "doručena"],
    &["bude", "dnes", "doručená"],
    &["kurýr", "je", "na", "cestě"],
    &["kuriér", "je", "na", "ceste"],
];

const SHIPPED: &[&[&str]] = &[
    &["shipped"],
    &["dispatched"],
    &["on", "its", "way"],
    &["on", "the", "way"],
    &["in", "transit"],
    &["versandt"],
    &["versendet"],
    &["unterwegs"],
    &["odeslána"],
    &["odesláno"],
    &["odoslaná"],
    &["odoslané"],
    &["odeslali", "jsme"],
    &["odoslali", "sme"],
    &["na", "cestě"],
    &["na", "ceste"],
    &["expédié"],
    &["expédiée"],
];

/// Lower-cased words without the punctuation around them.
fn words(text: &str) -> Vec<String> {
    text.split_whitespace()
        .map(|w| {
            w.trim_matches(|c: char| !c.is_alphanumeric())
                .to_lowercase()
        })
        .filter(|w| !w.is_empty())
        .collect()
}

/// Whether `words` state `phrase`, and not as a promise or a failure
/// (`NOT_YET` in the `NOT_YET_REACH` words before it).
fn stated(words: &[String], phrase: &[&str]) -> bool {
    words.windows(phrase.len()).enumerate().any(|(i, window)| {
        let matches = window.iter().zip(phrase).all(|(w, p)| w == p);
        let before = &words[i.saturating_sub(NOT_YET_REACH)..i];
        let negated = before
            .iter()
            .any(|w| NOT_YET.contains(&w.as_str()) || w.ends_with("n't") || w.ends_with("n’t"));
        // "Sold and shipped by Acme" says who ships, not that it has.
        let seller = matches!(phrase, ["shipped"] | ["dispatched"])
            && words.get(i + 1).is_some_and(|w| w == "by" || w == "from");
        matches && !negated && !seller
    })
}

fn status_in(text: &str) -> Option<ParcelStatus> {
    let words = words(text);
    let any = |phrases: &[&[&str]]| phrases.iter().any(|p| stated(&words, p));
    if any(DELIVERED) {
        Some(ParcelStatus::Delivered)
    } else if any(OUT_FOR_DELIVERY) {
        Some(ParcelStatus::OutForDelivery)
    } else if any(SHIPPED) {
        Some(ParcelStatus::Shipped)
    } else {
        None
    }
}

/// A day found in text: a date, or so many days after the email.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Day {
    On(i64),
    In(u8),
}

/// Words that say a day after them is when the parcel comes.
const DELIVERY_WORDS: &[&str] = &[
    "arriving",
    "arrives",
    "arrive",
    "arrival",
    "delivery",
    "delivered",
    "deliver",
    "expected",
    "estimated",
    "eta",
    "doručení",
    "doručenie",
    "doručíme",
    "doručena",
    "doručená",
    "lieferung",
    "zustellung",
    "zugestellt",
    "geliefert",
    "livraison",
];

/// Words that may stand between a delivery word and its day.
const DAY_FILLER: &[&str] = &[
    "on",
    "by",
    "date",
    "day",
    "is",
    "the",
    "for",
    "of",
    "before",
    "estimated",
    "expected",
    "am",
    "bis",
    "ist",
    "dne",
    "dňa",
    "do",
    "le",
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
    "mon",
    "tue",
    "wed",
    "thu",
    "fri",
    "sat",
    "sun",
    "pondělí",
    "úterý",
    "středa",
    "čtvrtek",
    "pátek",
    "sobota",
    "neděle",
    "pondelok",
    "utorok",
    "streda",
    "štvrtok",
    "piatok",
    "nedeľa",
    "montag",
    "dienstag",
    "mittwoch",
    "donnerstag",
    "freitag",
    "samstag",
    "sonntag",
];

/// Words after which a date without a year is still a date ("am 20.11.",
/// "dne 20.11."): a bare `2.10.` after "delivery" may be a price.
const DATE_LEADS: &[&str] = &["on", "by", "am", "bis", "dne", "dňa", "do", "le"];

const MONTHS: &[(&str, i64)] = &[
    ("january", 1),
    ("jan", 1),
    ("february", 2),
    ("feb", 2),
    ("march", 3),
    ("mar", 3),
    ("april", 4),
    ("apr", 4),
    ("may", 5),
    ("june", 6),
    ("jun", 6),
    ("july", 7),
    ("jul", 7),
    ("august", 8),
    ("aug", 8),
    ("september", 9),
    ("sep", 9),
    ("sept", 9),
    ("october", 10),
    ("oct", 10),
    ("november", 11),
    ("nov", 11),
    ("december", 12),
    ("dec", 12),
];

/// How many words after a delivery word are read for its day.
const DAY_REACH: usize = 5;

/// The day a delivery word is followed by, if any.
fn day_in(text: &str, at: i64) -> Option<Day> {
    // Dots and dashes stay: they are what a date is written with.
    let tokens: Vec<String> = text
        .split_whitespace()
        .map(|w| {
            w.trim_matches(|c: char| {
                matches!(c, ',' | ';' | ':' | '!' | '?' | '(' | ')' | '"' | '\'')
            })
            .to_lowercase()
        })
        .filter(|w| !w.is_empty())
        .collect();
    for (i, token) in tokens.iter().enumerate() {
        if !DELIVERY_WORDS.contains(&token.trim_end_matches('.')) {
            continue;
        }
        for j in i + 1..tokens.len().min(i + 1 + DAY_REACH) {
            let word = tokens[j].trim_end_matches('.');
            match word {
                "today" | "dnes" | "heute" => return Some(Day::In(0)),
                "tomorrow" | "zítra" | "zajtra" | "morgen" => return Some(Day::In(1)),
                _ => {}
            }
            if let Some(day) = date_at(&tokens, j, at) {
                return plausible(day, at).then_some(Day::On(day));
            }
            if !DAY_FILLER.contains(&word) {
                break;
            }
        }
    }
    None
}

/// A date starting at `tokens[j]`: `2026-11-20`, `20.11.2026`, `20.11.`
/// (after a word that leads a date), `Nov 20`, `20 November`, each with
/// an optional year. Without one it is the first such date not more than
/// `DAYS_BEFORE` days before the email.
fn date_at(tokens: &[String], j: usize, at: i64) -> Option<i64> {
    let token = tokens[j].as_str();
    if let Some(day) = iso_day(token.trim_end_matches('.')) {
        return Some(day);
    }
    let sent = day_of(at, 0);
    let (sent_year, _, _) = civil_from_days(sent);
    let without_year = |m: i64, d: i64| -> Option<i64> {
        [sent_year, sent_year + 1]
            .into_iter()
            .filter_map(|y| valid_day(y, m, d))
            .find(|day| *day >= sent - DAYS_BEFORE)
    };
    let number = |s: &str| -> Option<i64> {
        (!s.is_empty() && s.len() <= 4 && s.bytes().all(|b| b.is_ascii_digit()))
            .then(|| s.parse().ok())
            .flatten()
    };
    // 20.11.2026 · 20.11. (and "20.11.2026." at the end of a sentence)
    let dotted = match token.matches('.').count() {
        3 => token.strip_suffix('.').unwrap_or(token),
        _ => token,
    };
    let parts: Vec<&str> = dotted.split('.').collect();
    if let [d, m, y] = parts[..] {
        let (d, m) = (number(d)?, number(m)?);
        if y.is_empty() {
            let led = j > 0 && DATE_LEADS.contains(&tokens[j - 1].as_str());
            return led.then(|| without_year(m, d)).flatten();
        }
        return valid_day(number(y).filter(|y| *y >= 2000)?, m, d);
    }
    // Nov 20 [2026] · 20 November [2026] · 20th Nov
    let month = |s: &str| {
        let s = s.trim_end_matches('.');
        MONTHS.iter().find(|(name, _)| *name == s).map(|(_, m)| *m)
    };
    let day_number = |s: &str| {
        let s = s.trim_end_matches('.');
        let s = ["st", "nd", "rd", "th"]
            .iter()
            .find_map(|suffix| s.strip_suffix(suffix))
            .unwrap_or(s);
        number(s).filter(|d| (1..=31).contains(d))
    };
    let next = tokens.get(j + 1).map(String::as_str);
    let (m, d) = match (month(token), next.and_then(day_number)) {
        (Some(m), Some(d)) => (m, d),
        _ => (next.and_then(month)?, day_number(token)?),
    };
    let year = tokens
        .get(j + 2)
        .and_then(|y| number(y.trim_end_matches('.')))
        .filter(|y| (2000..=2100).contains(y));
    match year {
        Some(y) => valid_day(y, m, d),
        None => without_year(m, d),
    }
}

// ------------------------------------------------------------- keeping

/// Keep what a full fetch read from its messages' markup
/// (`Message::delivery`): per thread the newest message's, unless a newer
/// message's is already kept (a fetch may bring only the messages the
/// store lacked). A day that is implausible for its email is dropped
/// here, where the email's time is known. Returns how many threads were
/// written.
pub fn remember_deliveries<S: Store>(store: &S, messages: &[Message]) -> Result<usize, StoreError> {
    let mut newest: HashMap<&ThreadId, Delivery> = HashMap::new();
    for m in messages {
        let Some(found) = &m.delivery else {
            continue;
        };
        let mut d = found.clone();
        d.at = m.date;
        d.expected_in_days = None;
        d.expected_day = d
            .expected_day
            .filter(|day| iso_day(day).is_some_and(|day| plausible(day, m.date)));
        if d.is_empty() {
            continue;
        }
        if newest.get(&m.thread_id).is_none_or(|kept| kept.at <= d.at) {
            newest.insert(&m.thread_id, d);
        }
    }
    let mut items = Vec::new();
    for (thread_id, d) in newest {
        let kept = store
            .thread_deliveries(thread_id)?
            .into_iter()
            .find(|(source, _)| *source == DeliverySource::Markup);
        if kept.is_none_or(|(_, kept)| kept.at <= d.at) {
            items.push((thread_id.clone(), Some(d)));
        }
    }
    store.set_thread_deliveries(DeliverySource::Markup, &items)?;
    Ok(items.len())
}

/// What a thread's kept rows add up to, per field the email it came from.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Known {
    status: Option<(ParcelStatus, i64)>,
    /// Days since the epoch, and the email's time.
    day: Option<(i64, i64)>,
    title: Option<(String, i64)>,
}

impl Known {
    /// Fold one kept row in (docs/specs/parcel-card.md R5): the furthest
    /// status; the newest email's day and title, markup before text
    /// within one email.
    fn add(&mut self, source: DeliverySource, d: &Delivery, utc_offset_min: i32) {
        if let Some(status) = d.status {
            if self.status.is_none_or(|(kept, _)| status > kept) {
                self.status = Some((status, d.at));
            }
        }
        let day = d.expected_day.as_deref().and_then(iso_day).or_else(|| {
            d.expected_in_days
                .map(|n| day_of(d.at, utc_offset_min) + i64::from(n))
        });
        let wins =
            |kept_at: i64| d.at > kept_at || (d.at == kept_at && source == DeliverySource::Markup);
        if let Some(day) = day {
            if self.day.is_none_or(|(_, at)| wins(at)) {
                self.day = Some((day, d.at));
            }
        }
        if let Some(title) = &d.title {
            if self.title.as_ref().is_none_or(|(_, at)| wins(*at)) {
                self.title = Some((title.clone(), d.at));
            }
        }
    }
}

// ------------------------------------------------------------ overview

/// One parcel on the inbox's card.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Parcel {
    /// The same on every device: `number:<16 hex digits of the tracking
    /// or order number's SHA-256>` (`number_id`), or `thread:<the newest
    /// email's thread id>`. What a dismissal names.
    pub id: String,
    pub bundle_id: String,
    /// The newest email about it, the account it is in, and that email's
    /// tracking link.
    pub thread_id: ThreadId,
    pub account_id: String,
    pub url: String,
    /// The link's host, lower-cased: `track.dhl.com`.
    pub host: String,
    pub subject: String,
    /// Who that email is from, as the list shows it.
    pub sender: String,
    /// That email's time, epoch ms.
    pub at: i64,
    pub status: Option<ParcelStatus>,
    /// `2026-11-20`.
    pub expected_day: Option<String>,
    pub title: Option<String>,
}

/// The card's parcels, and the threads whose tracking links have not
/// been read from their bodies yet (the caller reads them off the
/// caller's thread; they are in the next overview).
#[derive(Debug, Clone, Default)]
pub struct Overview {
    pub parcels: Vec<Parcel>,
    pub unread: Vec<Thread>,
}

/// Hosts that only pass a click on to the carrier (mail services' and
/// analytics' redirects). The shell's `BundleTracking.redirects` is the
/// same list: within one email the carrier's own link wins over these.
const REDIRECTS: &[&str] = &[
    "omtrdc.net",
    "sendgrid.net",
    "list-manage.com",
    "mandrillapp.com",
    "mailgun.org",
    "sparkpostmail.com",
    "awstrack.me",
    "mjt.lu",
    "exacttarget.com",
    "klclick.com",
    "hubspotlinks.com",
    "doubleclick.net",
];

fn is_redirect(host: &str) -> bool {
    REDIRECTS
        .iter()
        .any(|r| host == *r || host.ends_with(&format!(".{r}")))
}

/// The host a web address really leads to, lower-cased, without a port.
/// None unless that can be read off the address the way every browser
/// and URL parser reads it:
///
/// - an address that names a user before the host
///   (`https://dhl.com@evil.example/`): nothing honest is written that
///   way;
/// - a backslash, a control character or anything outside ASCII before
///   the path (`https://dhl.com\@evil.example/`): one parser takes `\`
///   for a `/` and stops at `dhl.com`, another escapes it and goes on to
///   `evil.example` — and the card names the host it opens;
/// - a port that is not a number;
/// - an IP address: a parcel's page has a name, and the card would show
///   digits that say nothing about who is behind them.
pub fn host_of(url: &str) -> Option<String> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))?;
    let authority = rest.split(['/', '?', '#']).next()?;
    if authority
        .chars()
        .any(|c| c == '@' || c == '\\' || !c.is_ascii() || c.is_ascii_control() || c == ' ')
    {
        return None;
    }
    let (host, port) = match authority.split_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (authority, None),
    };
    if port.is_some_and(|p| !p.chars().all(|c| c.is_ascii_digit())) {
        return None;
    }
    let host = host.to_ascii_lowercase();
    let plain = host
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-');
    // Every form of an IPv4 address ends in a number (`192.168.1.1`,
    // `0x7f.1`); no name does.
    let numeric = host
        .rsplit('.')
        .next()
        .is_some_and(|last| last.chars().all(|c| c.is_ascii_digit()) || last.starts_with("0x"));
    (plain
        && !numeric
        && host.contains('.')
        && !host.starts_with('.')
        && !host.ends_with('.')
        && !host.contains(".."))
    .then_some(host)
}

/// A parcel's id from its tracking or order number: `number:` and the
/// first 16 hex digits of the number's SHA-256. The same on every
/// device, so a dismissal made on one holds on the others — and not the
/// number itself, because dismissals are a synced pref and a tracking
/// number is enough to follow or redirect a parcel.
fn number_id(number: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(number.as_bytes());
    let hex: String = digest[..8].iter().map(|b| format!("{b:02x}")).collect();
    format!("number:{hex}")
}

/// One tracking link and the thread it is in (an index into the bundle's
/// scanned threads).
struct Link {
    thread: usize,
    url: String,
    host: String,
}

/// The parcels of the active bundles in `bundles`, in the card's order
/// (docs/specs/parcel-card.md R1, R2, R5–R7). `now` is epoch ms;
/// `utc_offset_min` is the reader's time zone, for "today" and for when
/// a day is over. Reads no mail: links come from what was last read from
/// each thread's bodies (`bundles::stored_tracking_links`).
pub fn overview<S: Store>(
    store: &S,
    bundles: &[Bundle],
    now: i64,
    utc_offset_min: i32,
) -> Result<Overview, StoreError> {
    let today = day_of(now, utc_offset_min);
    let mut out = Overview::default();
    // (rank, key, parcel): see the sort below.
    let mut ranked: Vec<(u8, i64, Parcel)> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for bundle in bundles {
        if bundle.status != BundleStatus::Active {
            continue;
        }
        let threads: Vec<Thread> =
            store.list_recent_bundle_threads(&bundle.id, now - WINDOW_MS, SCAN_THREADS as u32)?;
        if threads.is_empty() {
            continue;
        }
        // Each thread's identifiers once: its tracking numbers decide
        // which links are read, and the bundle's numbers which links are
        // one parcel.
        let mut links: Vec<Link> = Vec::new();
        let mut tracked: Vec<bool> = Vec::with_capacity(threads.len());
        let (mut tracking, mut orders): (Vec<String>, Vec<String>) = (Vec::new(), Vec::new());
        for (i, t) in threads.iter().enumerate() {
            let anchors: Vec<Anchor> = store
                .thread_anchors(&t.id)?
                .iter()
                .filter_map(|a| Anchor::parse(a))
                .collect();
            let own: Vec<String> = anchors
                .iter()
                .filter(|a| a.kind == AnchorKind::Tracking)
                .map(|a| a.value.clone())
                .collect();
            tracked.push(!own.is_empty());
            for a in anchors {
                match a.kind {
                    AnchorKind::Tracking => tracking.push(a.value),
                    AnchorKind::Order => orders.push(a.value),
                    _ => {}
                }
            }
            match bundles::stored_tracking_links(store, t, &own)? {
                Some(found) => links.extend(found.into_iter().filter_map(|url| {
                    let host = host_of(&url)?;
                    Some(Link {
                        thread: i,
                        url,
                        host,
                    })
                })),
                None => out.unread.push(t.clone()),
            }
        }
        // Tracking numbers before order numbers; short ones are left
        // out, since "4545" is in many an address by chance.
        let numbers: Vec<String> = tracking
            .into_iter()
            .chain(orders)
            .filter(|n| n.chars().count() >= 6)
            .collect();
        let by_number: Vec<Option<String>> = links
            .iter()
            .map(|link| {
                let address = link.url.to_uppercase();
                numbers
                    .iter()
                    .find(|n| address.contains(n.as_str()))
                    .map(|n| number_id(n))
            })
            .collect();
        // An email's links without a number are the same parcel as its
        // first link with one ("the same email"): the shop's redirect and
        // the carrier's own page for it, side by side in one mail.
        let mut number_of_email: HashMap<usize, String> = HashMap::new();
        for (link, key) in links.iter().zip(&by_number) {
            if let Some(key) = key {
                number_of_email
                    .entry(link.thread)
                    .or_insert_with(|| key.clone());
            }
        }
        let mut order: Vec<String> = Vec::new();
        let mut groups: HashMap<String, Vec<Link>> = HashMap::new();
        for (link, key) in links.into_iter().zip(by_number) {
            let key = key
                .or_else(|| number_of_email.get(&link.thread).cloned())
                .unwrap_or_else(|| format!("thread:{}", threads[link.thread].id));
            if !groups.contains_key(&key) {
                order.push(key.clone());
            }
            groups.entry(key).or_default().push(link);
        }
        for key in order {
            let Some(group) = groups.remove(&key) else {
                continue;
            };
            // One link per email, the carrier's own where there is one;
            // threads come newest first, so the first is the parcel's.
            let mut per_email: Vec<Link> = Vec::new();
            for link in group {
                match per_email.iter_mut().find(|l| l.thread == link.thread) {
                    Some(kept) => {
                        if is_redirect(&kept.host) && !is_redirect(&link.host) {
                            *kept = link;
                        }
                    }
                    None => per_email.push(link),
                }
            }
            let Some(newest) = per_email.first() else {
                continue;
            };
            let mut known = Known::default();
            for link in &per_email {
                for (source, d) in store.thread_deliveries(&threads[link.thread].id)? {
                    known.add(source, &d, utc_offset_min);
                }
            }
            // A sign that this is a parcel and not some other page with
            // "track" in its address (R2).
            let is_parcel = bundle.kind == BundleKind::Shopping
                || key.starts_with("number:")
                || per_email.iter().any(|l| tracked[l.thread])
                || known.status.is_some()
                || known.day.is_some();
            if !is_parcel {
                continue;
            }
            let email = &threads[newest.thread];
            let status = known.status.map(|(s, _)| s);
            let day = known.day.map(|(d, _)| d);
            // Over (R6), and where it stands in the card (R7).
            let (rank, sort) = match (known.status, day) {
                (Some((ParcelStatus::Delivered, said)), _) => {
                    if now - said > DELIVERED_GRACE_MS {
                        continue;
                    }
                    (2, -said)
                }
                (_, Some(day)) => {
                    if today > day + LATE_DAYS {
                        continue;
                    }
                    (0, day)
                }
                (status, None) => {
                    if now - email.last_msg_at > UNDATED_MS {
                        continue;
                    }
                    match status {
                        Some((ParcelStatus::OutForDelivery, _)) => (0, today),
                        _ => (1, -email.last_msg_at),
                    }
                }
            };
            if !seen.insert(key.clone()) {
                continue;
            }
            ranked.push((
                rank,
                sort,
                Parcel {
                    id: key,
                    bundle_id: bundle.id.clone(),
                    thread_id: email.id.clone(),
                    account_id: email.account_id.clone(),
                    url: newest.url.clone(),
                    host: newest.host.clone(),
                    subject: email.subject.clone(),
                    sender: email.from_summary.clone(),
                    at: email.last_msg_at,
                    status,
                    expected_day: day.map(format_day),
                    title: known.title.map(|(t, _)| t),
                },
            ));
        }
    }
    // With a day, the earliest first; then without, the newest email
    // first; delivered last. Equal keys: the newest email, then the id,
    // so the order never depends on the store's.
    ranked.sort_by(|a, b| (a.0, a.1, -a.2.at, &a.2.id).cmp(&(b.0, b.1, -b.2.at, &b.2.id)));
    out.parcels = ranked
        .into_iter()
        .take(MAX_PARCELS)
        .map(|(_, _, p)| p)
        .collect();
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundles::{link_pass, new_bundle};
    use crate::domain::BundleSource;
    use crate::fakes::MemStore;

    /// 2026-11-19 12:00 UTC.
    const NOW: i64 = 1_795_089_600_000;

    fn day(s: &str) -> Option<String> {
        Some(s.to_string())
    }

    // ---- markup

    #[test]
    fn json_ld_parcel_delivery() {
        let html = r#"<html><head><script type="application/ld+json">
        {"@context":"http://schema.org","@type":"ParcelDelivery",
         "expectedArrivalUntil":"2026-11-20T23:59:00+01:00",
         "trackingNumber":"00340434161094000000",
         "trackingUrl":"https://evil.example/not-used",
         "itemShipped":[{"@type":"Product","name":"Magnetic Case &amp; 2 Screen Protectors"},
                        {"@type":"Product","name":"USB-C Adapter"}],
         "partOfOrder":{"@type":"Order","orderNumber":"112-334","orderStatus":"http://schema.org/OrderInTransit"}}
        </script></head><body>Shipped</body></html>"#;
        assert_eq!(
            from_markup(html),
            Some(Delivery {
                status: Some(ParcelStatus::Shipped),
                expected_day: day("2026-11-20"),
                expected_in_days: None,
                title: Some("Magnetic Case & 2 Screen Protectors + 1 more".into()),
                at: 0,
            })
        );
    }

    #[test]
    fn json_ld_order_with_delivery_and_graph() {
        let html = r#"<SCRIPT TYPE='application/ld+json'>{"@context":"https://schema.org","@graph":[
          {"@type":"Organization","name":"Shop"},
          {"@type":["Order"],"orderStatus":"https://schema.org/OrderDelivered",
           "acceptedOffer":{"@type":"Offer","itemOffered":{"@type":"Product","name":"Kettle"}},
           "orderDelivery":{"@type":"ParcelDelivery","expectedArrivalFrom":"2026-11-18"}}]}</SCRIPT>"#;
        let d = from_markup(html).unwrap();
        assert_eq!(d.status, Some(ParcelStatus::Delivered));
        assert_eq!(d.expected_day, day("2026-11-18"));
        assert_eq!(d.title.as_deref(), Some("Kettle"));
        // An order that is only being processed states nothing.
        let processing = r#"<script type="application/ld+json">{"@context":"http://schema.org",
          "@type":"Order","orderStatus":"http://schema.org/OrderProcessing"}</script>"#;
        assert_eq!(from_markup(processing), None);
        // No schema.org, no work.
        assert_eq!(from_markup("<p>Your parcel was delivered</p>"), None);
    }

    #[test]
    fn microdata_is_read_flat() {
        let html = r#"<div itemscope itemtype="http://schema.org/ParcelDelivery">
          <div itemprop="carrier" itemscope itemtype="http://schema.org/Organization">
            <meta itemprop="name" content="DHL"/></div>
          <div itemprop="itemShipped" itemscope itemtype="http://schema.org/Product">
            <span itemprop='name'>Wool socks</span></div>
          <meta itemprop="expectedArrivalUntil" content="2026-11-21T12:00:00-08:00"/>
          <div itemprop="partOfOrder" itemscope itemtype="http://schema.org/Order">
            <link itemprop="orderStatus" href="http://schema.org/OrderInTransit"/></div></div>"#;
        assert_eq!(
            from_markup(html),
            Some(Delivery {
                status: Some(ParcelStatus::Shipped),
                expected_day: day("2026-11-21"),
                expected_in_days: None,
                title: Some("Wool socks".into()),
                at: 0,
            })
        );
    }

    /// The name is looked for a fixed number of bytes after `itemShipped`;
    /// in mail that is not ASCII that many bytes on can be the middle of
    /// a letter, and the title was lost.
    #[test]
    fn microdata_title_survives_a_reach_that_ends_inside_a_letter() {
        for pad in 0..3 {
            let html = format!(
                r#"<div itemscope itemtype="http://schema.org/ParcelDelivery">{}
                   <div itemprop="itemShipped"><span itemprop="name">Vlněné ponožky</span></div>{}</div>"#,
                "x".repeat(pad),
                "ž".repeat(ITEM_NAME_REACH)
            );
            assert_eq!(
                from_markup(&html).and_then(|d| d.title).as_deref(),
                Some("Vlněné ponožky"),
                "pad {pad}"
            );
        }
        // The early look for schema.org is in any letter case.
        assert!(contains_ignore_ascii_case(
            "x SCHEMA.Org/Order",
            "schema.org"
        ));
        assert!(!contains_ignore_ascii_case("schema.or", "schema.org"));
    }

    #[test]
    fn hostile_markup_is_bounded() {
        // Deep nesting is an error, not a stack.
        let deep = format!(
            r#"<script type="application/ld+json">{}{}</script> schema.org"#,
            "[".repeat(10_000),
            "]".repeat(10_000)
        );
        assert_eq!(from_markup(&deep), None);
        // An oversized block is not parsed; a small one after it is.
        let big = format!(
            r#"<script type="application/ld+json">{{"@type":"ParcelDelivery","x":"{}"}}</script>
               <script type="application/ld+json">{{"@context":"http://schema.org","@type":"ParcelDelivery","expectedArrivalUntil":"2026-11-20"}}</script>"#,
            "a".repeat(MAX_BLOCK_BYTES)
        );
        assert_eq!(from_markup(&big).unwrap().expected_day, day("2026-11-20"));
        // Unclosed, truncated, not JSON, the wrong shapes: nothing.
        for html in [
            r#"schema.org <script type="application/ld+json">{"@type":"ParcelDelivery""#,
            r#"schema.org <script type="application/ld+json">not json</script>"#,
            r#"schema.org <script type="application/ld+json">{"@type":7,"itemShipped":{"name":[1,2]}}</script>"#,
            r#"schema.org <script type="application/ld+json">{"@type":"ParcelDelivery","expectedArrivalUntil":20261120,"itemShipped":null}</script>"#,
            r#"schema.org/ParcelDelivery <meta itemprop="expectedArrivalUntil" content="#,
            r#"schema.org/Order itemprop="orderStatus" itemprop= <"#,
            "schema.org/Order <İ itemprop=\"orderStatus\" content=\"İİİ\">",
        ] {
            assert_eq!(from_markup(html), None, "{html}");
        }
        // A title is one line of plain text: no controls, no direction
        // overrides, no address, and not without end.
        let titled = |name: &str| {
            from_markup(&format!(
                r#"<script type="application/ld+json">{{"@context":"http://schema.org","@type":"ParcelDelivery","itemShipped":{{"name":{}}}}}</script>"#,
                serde_json::to_string(name).unwrap()
            ))
            .and_then(|d| d.title)
        };
        assert_eq!(
            titled("Case\u{202E}\n\tfor\u{0007}  X3\u{200B}").as_deref(),
            Some("Case for X3")
        );
        assert_eq!(titled("https://evil.example/login"), None);
        assert_eq!(titled(" \u{200F} "), None);
        // Nor the other things that draw nothing or draw over the row:
        // the Arabic letter mark, a soft hyphen, a filler that passes for
        // a space, tag characters, and a pile of combining marks.
        assert_eq!(
            titled("Ca\u{00AD}se\u{061C}\u{3164}\u{E0041}\u{E007F} X3").as_deref(),
            Some("Case X3")
        );
        assert_eq!(titled("\u{3164}\u{E0020}"), None);
        let piled = titled(&format!("Z{}algo e\u{0301}", "\u{0301}\u{0489}".repeat(40))).unwrap();
        assert_eq!(piled, "Z\u{0301}\u{0489}\u{0301}algo e\u{0301}");
        assert_eq!(titled(&"é".repeat(500)).unwrap().chars().count(), MAX_TITLE);
        // Dates that are no dates.
        for bad in [
            "2026-13-01",
            "2026-02-30",
            "1970-01-01",
            "20261120",
            "2026-11-200",
        ] {
            assert_eq!(iso_day(bad), None, "{bad}");
        }
    }

    // ---- text

    fn text(subject: &str, snippet: &str) -> Option<Delivery> {
        from_text(subject, snippet, NOW)
    }

    #[test]
    fn status_from_text() {
        let status = |s: &str| text(s, "").and_then(|d| d.status);
        for s in [
            "Delivered: your package",
            "Your parcel has been delivered",
            "Ihre Sendung wurde zugestellt",
            "Zásilka byla doručena",
            "Vaša zásielka bola doručená",
        ] {
            assert_eq!(status(s), Some(ParcelStatus::Delivered), "{s}");
        }
        for s in [
            "Out for delivery: Magnetic case",
            "Ihr Paket wird heute zugestellt",
            "Zásilku vám dnes doručíme",
        ] {
            assert_eq!(status(s), Some(ParcelStatus::OutForDelivery), "{s}");
        }
        for s in [
            "Your order #112-334 has shipped",
            "Shipped: 2 items",
            "Your parcel is on its way!",
            "Ihre Bestellung wurde versandt",
            "Vaše objednávka byla odeslána",
            "Objednávka bola odoslaná",
        ] {
            assert_eq!(status(s), Some(ParcelStatus::Shipped), "{s}");
        }
        // The subject first; the start of the preview line when it says
        // nothing; never further in.
        assert_eq!(
            text("Order 112-334", "Good news: your order has shipped.").and_then(|d| d.status),
            Some(ParcelStatus::Shipped)
        );
        let far = format!("{} your order has shipped", "word ".repeat(40));
        assert_eq!(text("Order 112-334", &far), None);
    }

    #[test]
    fn negations_are_not_a_status() {
        for s in [
            "Your parcel will be delivered tomorrow",
            "We could not deliver: not delivered",
            "Your parcel couldn't be delivered",
            "To be delivered by Friday",
            "We'll email you once your order has shipped",
            "Your order has not shipped yet",
            "When will my order be shipped?",
            "Sold by Acme and shipped by Amazon",
            "Free shipping on all orders",
            "Zásilka nebyla doručena",
            "Zásielka bude doručená zajtra",
            "Ihr Paket konnte nicht zugestellt werden",
            "Thanks for your order",
        ] {
            assert_eq!(text(s, "").and_then(|d| d.status), None, "{s}");
        }
    }

    #[test]
    fn days_from_text() {
        let found = |s: &str| text(s, "").map(|d| (d.expected_day, d.expected_in_days));
        assert_eq!(
            found("Arriving tomorrow: your package"),
            Some((None, Some(1)))
        );
        assert_eq!(found("Out for delivery today"), Some((None, Some(0))));
        assert_eq!(
            found("Zásielka bude doručená zajtra"),
            Some((None, Some(1)))
        );
        assert_eq!(
            found("Arriving Friday, November 20"),
            Some((day("2026-11-20"), None))
        );
        assert_eq!(
            found("Estimated delivery: 24 Nov 2026"),
            Some((day("2026-11-24"), None))
        );
        assert_eq!(
            found("Delivery on 2026-11-23."),
            Some((day("2026-11-23"), None))
        );
        assert_eq!(
            found("Lieferung am 20.11."),
            Some((day("2026-11-20"), None))
        );
        assert_eq!(
            found("Doručení dne 3.12.2026"),
            Some((day("2026-12-03"), None))
        );
        // Without a year, the next such date: January is next year's.
        assert_eq!(
            found("Expected delivery Jan 5"),
            Some((day("2027-01-05"), None))
        );
        // Not read: a weekday alone, month/day, a price, a date that is
        // not about the delivery, a date too far from the email.
        for s in [
            "Arriving Friday",
            "Arriving 11/20",
            "Delivery 2.10.",
            "Delivery fee 20.11.",
            "Order placed November 12",
            "Delivery date 2031-01-01",
            "Your order from November 20 has shipped",
        ] {
            let d = text(s, "");
            assert!(
                d.as_ref()
                    .is_none_or(|d| d.expected_day.is_none() && d.expected_in_days.is_none()),
                "{s}: {d:?}"
            );
        }
        // Delivered has no day to wait for.
        assert_eq!(found("Delivered today at 14:02"), Some((None, None)));
    }

    #[test]
    fn implausible_days_are_dropped() {
        let s = MemStore::default();
        let message = |id: &str, date: i64, expected: &str| Message {
            id: id.into(),
            thread_id: "t".into(),
            date,
            delivery: Some(Delivery {
                expected_day: day(expected),
                title: Some("Kettle".into()),
                ..Default::default()
            }),
            ..Default::default()
        };
        // A year and a half ahead: the title stays, the day goes.
        remember_deliveries(&s, &[message("m1", NOW, "2028-06-01")]).unwrap();
        let kept = s.thread_deliveries(&"t".to_string()).unwrap();
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].1.expected_day, None);
        assert_eq!(kept[0].1.title.as_deref(), Some("Kettle"));
        assert_eq!(kept[0].1.at, NOW);
        // A newer message's replaces it; an older one fetched later does not.
        remember_deliveries(&s, &[message("m2", NOW + 10, "2026-11-21")]).unwrap();
        remember_deliveries(&s, &[message("m0", NOW - 10, "2026-11-25")]).unwrap();
        let kept = s.thread_deliveries(&"t".to_string()).unwrap();
        assert_eq!(kept[0].1.expected_day, day("2026-11-21"));
    }

    // ---- overview

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
            from_summary: "Shop".into(),
            last_from_addr: "shop@example.com".into(),
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

    /// A thread in `bundle` whose one message's body holds `body`, with
    /// its identifiers scanned and its links read, as after a sync and a
    /// fetch.
    fn mail(s: &MemStore, bundle: &Bundle, id: &str, subject: &str, at: i64, body: &str) {
        s.upsert_thread(&thread(id, subject, at)).unwrap();
        s.upsert_message(&Message {
            id: format!("m-{id}"),
            thread_id: id.into(),
            account_id: "a".into(),
            date: at,
            body_html: Some(body.into()),
            body_fetched: true,
            ..Default::default()
        })
        .unwrap();
        s.set_thread_bundle(&id.to_string(), Some((&bundle.id, BundleSource::User)))
            .unwrap();
        link_pass(s, 100).unwrap();
        let t = s.get_thread(&id.to_string()).unwrap().unwrap();
        let numbers = bundles::tracking_numbers(s, &t.id).unwrap();
        bundles::refresh_tracking_links(s, &t, &numbers).unwrap();
    }

    fn shop(s: &MemStore, kind: BundleKind) -> Bundle {
        let b = new_bundle("Zalando order", kind, "");
        s.upsert_bundle(&b).unwrap();
        b
    }

    fn parcels(s: &MemStore, now: i64) -> Vec<Parcel> {
        let bundles = s.list_bundles().unwrap();
        let o = overview(s, &bundles, now, 60).unwrap();
        assert!(o.unread.is_empty());
        o.parcels
    }

    const H: i64 = 3_600_000;

    #[test]
    fn links_of_one_number_are_one_parcel() {
        let s = MemStore::default();
        let b = shop(&s, BundleKind::Shopping);
        mail(
            &s,
            &b,
            "shipped",
            "Your order #112-334 has shipped",
            NOW - 30 * H,
            r#"<a href="https://u1.ct.sendgrid.net/ls/click?x=1">Track your parcel</a>
               <a href="https://www.dhl.com/track?id=00340434161094000000">Track</a>
               Tracking number: 00340434161094000000"#,
        );
        mail(
            &s,
            &b,
            "today",
            "Out for delivery: tracking 00340434161094000000",
            NOW - 2 * H,
            r#"<a href="https://www.dhl.com/track?id=00340434161094000000&utm=x">Track</a>"#,
        );
        mail(
            &s,
            &b,
            "other",
            "Your second parcel is on its way",
            NOW - 5 * H,
            r#"<a href="https://tracking.gls.example/p/77">Track parcel</a>"#,
        );
        let found = parcels(&s, NOW);
        assert_eq!(found.len(), 2);
        // Out for delivery counts as today: first.
        let first = &found[0];
        // The id names the number without holding it: it goes into a
        // synced pref when the parcel is dismissed.
        assert_eq!(first.id, number_id("00340434161094000000"));
        assert_eq!(first.id.len(), "number:".len() + 16);
        assert!(!first.id.contains("0034043416"));
        assert_eq!(
            first.id, "number:bfa83b19dfd2e747",
            "the same on every device"
        );
        assert_eq!(first.thread_id, "today");
        assert_eq!(first.host, "www.dhl.com");
        assert_eq!(first.status, Some(ParcelStatus::OutForDelivery));
        assert_eq!(first.bundle_id, b.id);
        assert_eq!(first.account_id, "a");
        assert_eq!(found[1].id, "thread:other");
        assert_eq!(found[1].status, Some(ParcelStatus::Shipped));
        assert_eq!(found[1].url, "https://tracking.gls.example/p/77");
    }

    #[test]
    fn a_track_link_alone_is_a_parcel_only_in_a_shopping_bundle() {
        let s = MemStore::default();
        let project = shop(&s, BundleKind::Project);
        let body = r#"<a href="https://jobs.example/track/application">Track your application</a>"#;
        mail(&s, &project, "job", "Thanks for applying", NOW - H, body);
        assert!(parcels(&s, NOW).is_empty());
        // The same link with a status in the subject is one.
        mail(
            &s,
            &project,
            "sent",
            "Your sample has shipped",
            NOW - H,
            body,
        );
        assert_eq!(parcels(&s, NOW).len(), 1);
        // A user before the host is never a link to offer.
        let shopping = shop(&s, BundleKind::Shopping);
        mail(
            &s,
            &shopping,
            "spoof",
            "Track it",
            NOW - H,
            r#"<a href="https://dhl.com@evil.example/track">Track your parcel</a>"#,
        );
        assert!(parcels(&s, NOW).iter().all(|p| p.thread_id != "spoof"));
        assert_eq!(
            host_of("https://DHL.com:443/track?x=1").as_deref(),
            Some("dhl.com")
        );
        assert_eq!(host_of("https://dhl.com@evil.example/"), None);
        assert_eq!(host_of("ftp://dhl.com/"), None);
        assert_eq!(host_of("https://localhost/"), None);
    }

    /// A backslash before the path: one URL parser stops the host there,
    /// another escapes it and goes on to what follows the `@`. No host is
    /// read off such an address, so no parcel is made of it.
    #[test]
    fn an_address_parsers_disagree_on_is_no_parcel() {
        let s = MemStore::default();
        let shopping = shop(&s, BundleKind::Shopping);
        let spoofs = [
            r"https://dhl.com\@evil.example/track",
            r"https://dhl.com:443\@evil.example/track",
            r"https://dhl.com\.evil.example/track",
            "https://dhl.com&#92;@evil.example/track",
            "https://dhl.com%5C@evil.example/track",
            "https://dhl.com\u{0001}.evil.example/track",
            "https://dhl.com\u{3002}evil.example/track",
            "https://dhl.com:8o/track",
            "https://dhl..com/track",
        ];
        for (i, url) in spoofs.iter().enumerate() {
            assert_eq!(host_of(url), None, "{url}");
            mail(
                &s,
                &shopping,
                &format!("spoof{i}"),
                "Track it",
                NOW - H,
                &format!(r#"<a href="{url}">Track your parcel</a>"#),
            );
        }
        assert!(parcels(&s, NOW).is_empty());
        // An IP address is no parcel's page either, in any spelling.
        for url in [
            "https://192.168.1.1/track",
            "http://203.0.113.7:8080/track",
            "https://0x7f.0.0.1/track",
            "https://2130706433.1/track",
        ] {
            assert_eq!(host_of(url), None, "{url}");
        }
        mail(
            &s,
            &shopping,
            "ip",
            "Track it",
            NOW - H,
            r#"<a href="https://203.0.113.7/track">Track your parcel</a>"#,
        );
        assert!(parcels(&s, NOW).is_empty());
        // What is left alone: a name with digits, a port, a query.
        assert_eq!(
            host_of("https://track.123post.example:8443/p?id=1#x").as_deref(),
            Some("track.123post.example")
        );
    }

    #[test]
    fn status_is_the_furthest_and_the_day_the_newest() {
        let s = MemStore::default();
        let b = shop(&s, BundleKind::Shopping);
        let link = r#"<a href="https://carrier.example/track?n=1Z999AA10123456784">Track</a>"#;
        mail(
            &s,
            &b,
            "t1",
            "Shipped: tracking 1Z999AA10123456784",
            NOW - 48 * H,
            link,
        );
        mail(
            &s,
            &b,
            "t2",
            "Update on 1Z999AA10123456784",
            NOW - 4 * H,
            link,
        );
        let id = |t: &str| t.to_string();
        s.set_thread_deliveries(
            DeliverySource::Markup,
            &[
                (
                    id("t1"),
                    Some(Delivery {
                        status: Some(ParcelStatus::Shipped),
                        expected_day: day("2026-11-25"),
                        title: Some("Kettle".into()),
                        at: NOW - 48 * H,
                        ..Default::default()
                    }),
                ),
                (
                    id("t2"),
                    Some(Delivery {
                        expected_day: day("2026-11-21"),
                        at: NOW - 4 * H,
                        ..Default::default()
                    }),
                ),
            ],
        )
        .unwrap();
        let found = parcels(&s, NOW);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].status, Some(ParcelStatus::Shipped));
        assert_eq!(found[0].expected_day, day("2026-11-21"));
        assert_eq!(found[0].title.as_deref(), Some("Kettle"));
        // "Tomorrow" in the newest email's subject counts from the day it
        // arrived where the reader is (UTC+1 here): 23:30 UTC is already
        // the next day.
        let late = NOW + 11 * H + H / 2;
        mail(
            &s,
            &b,
            "t3",
            "Arriving tomorrow: 1Z999AA10123456784",
            late,
            link,
        );
        assert_eq!(parcels(&s, late + 1)[0].expected_day, day("2026-11-21"));
        let bundles = s.list_bundles().unwrap();
        let utc = overview(&s, &bundles, late + 1, 0).unwrap();
        assert_eq!(utc.parcels[0].expected_day, day("2026-11-20"));
    }

    #[test]
    fn parcels_leave_by_themselves() {
        let s = MemStore::default();
        let b = shop(&s, BundleKind::Shopping);
        let link = |n: u8| format!(r#"<a href="https://carrier.example/track/{n}">Track</a>"#);
        mail(&s, &b, "undated", "Your order has shipped", NOW, &link(1));
        mail(&s, &b, "dated", "Arriving Nov 24", NOW, &link(2));
        mail(&s, &b, "done", "Delivered: your parcel", NOW, &link(3));
        let ids = |now: i64| -> Vec<String> {
            let mut ids: Vec<String> = parcels(&s, now).into_iter().map(|p| p.thread_id).collect();
            ids.sort();
            ids
        };
        assert_eq!(ids(NOW + H), ["dated", "done", "undated"]);
        // Delivered: a day after the email that said so.
        assert_eq!(ids(NOW + 25 * H), ["dated", "undated"]);
        // Expected the 24th: there until three days after it.
        assert_eq!(ids(NOW + 8 * 24 * H), ["dated", "undated"]);
        assert_eq!(ids(NOW + 9 * 24 * H), ["undated"]);
        // No day: fourteen days after its newest email.
        assert_eq!(ids(NOW + 14 * 24 * H + H), Vec::<String>::new());
    }

    #[test]
    fn order_is_by_day_then_newest_then_delivered() {
        let s = MemStore::default();
        let b = shop(&s, BundleKind::Shopping);
        let link = |n: u8| format!(r#"<a href="https://carrier.example/track/{n}">Track</a>"#);
        mail(
            &s,
            &b,
            "delivered",
            "Delivered: your parcel",
            NOW - H,
            &link(1),
        );
        mail(
            &s,
            &b,
            "old",
            "Your order has shipped",
            NOW - 50 * H,
            &link(2),
        );
        mail(
            &s,
            &b,
            "new",
            "Your order has shipped",
            NOW - 3 * H,
            &link(3),
        );
        mail(&s, &b, "later", "Arriving Nov 24", NOW - 2 * H, &link(4));
        mail(
            &s,
            &b,
            "sooner",
            "Arriving tomorrow",
            NOW - 20 * H,
            &link(5),
        );
        let order: Vec<String> = parcels(&s, NOW).into_iter().map(|p| p.thread_id).collect();
        assert_eq!(order, ["sooner", "later", "new", "old", "delivered"]);
    }

    #[test]
    fn archived_bundles_and_old_mail_have_no_parcels() {
        let s = MemStore::default();
        let mut b = shop(&s, BundleKind::Shopping);
        let link = r#"<a href="https://carrier.example/track/1">Track</a>"#;
        mail(&s, &b, "old", "Arriving Nov 24", NOW - 46 * 24 * H, link);
        assert!(parcels(&s, NOW).is_empty());
        mail(&s, &b, "fresh", "Your order has shipped", NOW - H, link);
        // Two emails, one address: still two parcels' worth of nothing in
        // common, but the address is listed once per email, so two rows
        // would name the same page. The link is the newest email's.
        assert!(!parcels(&s, NOW).is_empty());
        b.status = BundleStatus::Archived;
        s.upsert_bundle(&b).unwrap();
        assert!(parcels(&s, NOW).is_empty());
        // A thread whose links were never read is handed back to be read.
        b.status = BundleStatus::Active;
        s.upsert_bundle(&b).unwrap();
        s.upsert_thread(&thread("unread", "Your order has shipped", NOW))
            .unwrap();
        s.set_thread_bundle(&"unread".to_string(), Some((&b.id, BundleSource::User)))
            .unwrap();
        let o = overview(&s, &s.list_bundles().unwrap(), NOW, 0).unwrap();
        assert_eq!(
            o.unread.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(),
            ["unread"]
        );
    }

    #[test]
    fn civil_days_round_trip() {
        assert_eq!(format_day(0), "1970-01-01");
        assert_eq!(format_day(day_of(NOW, 0)), "2026-11-19");
        assert_eq!(iso_day("2028-02-29").map(format_day), day("2028-02-29"));
        for d in [-1, 0, 59, 60, 365, 20_000, 30_000] {
            let (y, m, dd) = civil_from_days(d);
            assert_eq!(days_from_civil(y, m, dd), d);
        }
    }
}
