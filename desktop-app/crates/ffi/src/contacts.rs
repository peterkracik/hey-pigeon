//! Recipient suggestions: who the user writes to, for the composer's To /
//! Cc fields. Local first — the people the stored mail is from and to,
//! ranked by how often — then the account's Google contacts. Nothing here
//! is stored: the local ranking is rebuilt from the messages table every
//! few minutes and kept in memory.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use heypigeon_adapter_sqlite::Correspondence;
use heypigeon_core::ports::Store;
use heypigeon_core::sync::{bare_addr, display_name};

use crate::engine::Engine;
use crate::types::*;

/// How long the local ranking is reused before it is rebuilt.
const REFRESH: Duration = Duration::from_secs(10 * 60);
/// How long a suggestion waits for the People API. The local answers are
/// ready at once; a slow network must not hold the field up.
const PEOPLE_WAIT: Duration = Duration::from_secs(3);
const MAX_LIMIT: u32 = 50;

/// One person the stored mail names.
#[derive(Debug, Clone, PartialEq)]
struct Person {
    name: String,
    email: String,
    /// `email` lowercased, and "name email" lowercased: what a query is
    /// matched against.
    key: String,
    haystack: String,
    /// The user has written to this address.
    sent_to: bool,
    /// How many stored messages name it.
    score: i64,
    last_at: i64,
}

/// The ranked people, and when they were read from the store.
pub(crate) struct Correspondents {
    built_at: Instant,
    people: Arc<Vec<Person>>,
}

/// Rank the people in `rows`, best first: the ones the user has written
/// to, then everyone else, most mail first within each (someone written
/// to twice is a likelier recipient than a newsletter that arrived fifty
/// times). `own` (lowercase) are the user's own addresses, never
/// suggested. Senders that cannot be written to (`noreply@…`) are left
/// out unless the user did write to them.
fn rank(rows: &[Correspondence], own: &HashSet<String>) -> Vec<Person> {
    struct Tally {
        name: String,
        email: String,
        score: i64,
        sent_to: bool,
        last_at: i64,
    }
    let mut tally: HashMap<String, Tally> = HashMap::new();
    let mut add = |entry: &str, weight: i64, sent_to: bool, last_at: i64| {
        let email = bare_addr(entry);
        let key = email.to_lowercase();
        if !key.contains('@') || key.contains(char::is_whitespace) || own.contains(&key) {
            return;
        }
        let name = display_name(entry);
        let name = if name.eq_ignore_ascii_case(&email) || name.contains('@') {
            String::new()
        } else {
            name
        };
        let t = tally.entry(key).or_insert_with(|| Tally {
            name: String::new(),
            email,
            score: 0,
            sent_to: false,
            last_at: 0,
        });
        if t.name.is_empty() {
            t.name = name;
        }
        t.score += weight;
        t.sent_to |= sent_to;
        t.last_at = t.last_at.max(last_at);
    };
    for row in rows {
        if row.sent {
            for entry in row.to_addrs.iter().chain(&row.cc_addrs) {
                add(entry, row.count, true, row.last_at);
            }
        } else {
            add(&row.from_addr, row.count, false, row.last_at);
            for entry in row.to_addrs.iter().chain(&row.cc_addrs) {
                add(entry, row.count, false, row.last_at);
            }
        }
    }
    let mut people: Vec<Person> = tally
        .into_iter()
        .filter(|(key, t)| t.sent_to || !is_no_reply(key))
        .map(|(key, t)| Person {
            haystack: format!("{} {key}", t.name.to_lowercase()),
            name: t.name,
            email: t.email,
            key,
            sent_to: t.sent_to,
            score: t.score,
            last_at: t.last_at,
        })
        .collect();
    people.sort_by(|a, b| {
        b.sent_to
            .cmp(&a.sent_to)
            .then(b.score.cmp(&a.score))
            .then(b.last_at.cmp(&a.last_at))
            .then(a.key.cmp(&b.key))
    });
    people
}

fn is_no_reply(address: &str) -> bool {
    let local = address.split('@').next().unwrap_or("");
    let squeezed: String = local.chars().filter(|c| c.is_alphanumeric()).collect();
    ["noreply", "donotreply", "mailerdaemon"]
        .iter()
        .any(|n| squeezed.contains(n))
}

/// The best `limit` people matching `query` (lowercase): those whose name
/// or address starts with it (any word of the name, the address, its
/// domain) before those that merely contain it; by rank within each.
fn matching(people: &[Person], query: &str, limit: usize) -> Vec<ContactSuggestion> {
    let starts = |p: &Person| {
        p.key.starts_with(query)
            || p.haystack
                .split(|c: char| c.is_whitespace() || c == '@' || c == '.')
                .any(|word| word.starts_with(query))
    };
    let suggestion = |p: &Person| ContactSuggestion {
        name: p.name.clone(),
        email: p.email.clone(),
        photo_url: None,
    };
    let mut out: Vec<ContactSuggestion> = people
        .iter()
        .filter(|p| starts(p))
        .take(limit)
        .map(suggestion)
        .collect();
    if out.len() < limit && !query.is_empty() {
        out.extend(
            people
                .iter()
                .filter(|p| !starts(p) && p.haystack.contains(query))
                .take(limit - out.len())
                .map(suggestion),
        );
    }
    out
}

/// Local suggestions first, then the People API's, one entry per address.
/// A People match for an address already listed fills in what the local
/// entry lacks (a name, the photo) instead of adding a second row.
fn merge(
    mut local: Vec<ContactSuggestion>,
    remote: Vec<ContactSuggestion>,
    own: &HashSet<String>,
    limit: usize,
) -> Vec<ContactSuggestion> {
    for r in remote {
        let key = r.email.to_lowercase();
        if own.contains(&key) {
            continue;
        }
        match local.iter_mut().find(|l| l.email.to_lowercase() == key) {
            Some(known) => {
                if known.name.is_empty() {
                    known.name = r.name;
                }
                if known.photo_url.is_none() {
                    known.photo_url = r.photo_url;
                }
            }
            None => local.push(r),
        }
    }
    local.truncate(limit);
    local
}

#[uniffi::export(async_runtime = "tokio")]
impl Engine {
    /// Suggestions for a recipient field as the user types: the people
    /// they correspond with (addresses in the stored mail's From / To /
    /// Cc, the ones they write to first), then their Google contacts and
    /// "other contacts" from every connected account, one entry per
    /// address. An empty query lists the most frequent correspondents.
    /// The Google half failing (offline, a grant without the contacts
    /// scopes) or taking too long leaves the local half.
    pub async fn search_contacts(
        self: Arc<Self>,
        query: String,
        limit: u32,
    ) -> Result<Vec<ContactSuggestion>, EngineError> {
        let query = query.trim().to_lowercase();
        let limit = limit.clamp(1, MAX_LIMIT) as usize;
        let accounts = self.store.list_accounts()?;
        let own: HashSet<String> = accounts.iter().map(|a| a.email.to_lowercase()).collect();

        // The first build reads the whole messages table: off the caller's
        // thread.
        let engine = Arc::clone(&self);
        let own_for_build = own.clone();
        let people = tokio::task::spawn_blocking(move || engine.correspondents(&own_for_build))
            .await
            .map_err(|e| EngineError::Store(e.to_string()))??;
        let local = matching(&people, &query, limit);
        if query.is_empty() {
            return Ok(local);
        }

        let disconnected = self.disconnected_accounts();
        let searches = accounts
            .iter()
            .filter(|a| !disconnected.contains(&a.id))
            .map(|a| {
                let engine = Arc::clone(&self);
                let (account_id, query) = (a.id.clone(), query.clone());
                async move {
                    let provider = engine.provider.read().await;
                    provider
                        .search_people(&account_id, &query, limit as u32)
                        .await
                }
            });
        let found = tokio::time::timeout(PEOPLE_WAIT, futures::future::join_all(searches)).await;
        let remote: Vec<ContactSuggestion> = match found {
            Ok(per_account) => per_account
                .into_iter()
                .filter_map(|r| match r {
                    Ok(people) => Some(people),
                    Err(e) => {
                        log::info!("contacts: people search failed: {e}");
                        None
                    }
                })
                .flatten()
                .map(|p| ContactSuggestion {
                    name: p.name,
                    email: p.email,
                    photo_url: p.photo_url,
                })
                .collect(),
            Err(_) => {
                log::info!("contacts: people search timed out");
                Vec::new()
            }
        };
        Ok(merge(local, remote, &own, limit))
    }
}

// Internals — not exported.
impl Engine {
    /// The ranked correspondents, rebuilt from the store when older than
    /// `REFRESH`.
    fn correspondents(&self, own: &HashSet<String>) -> Result<Arc<Vec<Person>>, EngineError> {
        if let Some(c) = self.correspondents.lock().unwrap().as_ref() {
            if c.built_at.elapsed() < REFRESH {
                return Ok(Arc::clone(&c.people));
            }
        }
        let people = Arc::new(rank(&self.store.correspondents()?, own));
        *self.correspondents.lock().unwrap() = Some(Correspondents {
            built_at: Instant::now(),
            people: Arc::clone(&people),
        });
        Ok(people)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(from: &str, to: &[&str], cc: &[&str], sent: bool, count: i64) -> Correspondence {
        Correspondence {
            from_addr: from.to_string(),
            to_addrs: to.iter().map(|s| s.to_string()).collect(),
            cc_addrs: cc.iter().map(|s| s.to_string()).collect(),
            sent,
            count,
            last_at: count,
        }
    }

    fn emails(v: &[ContactSuggestion]) -> Vec<&str> {
        v.iter().map(|c| c.email.as_str()).collect()
    }

    #[test]
    fn people_written_to_outrank_senders_and_own_and_noreply_stay_out() {
        let own: HashSet<String> = ["me@x.com".to_string()].into();
        let rows = [
            row("News <news@shop.com>", &["me@x.com"], &[], false, 50),
            row("noreply@bank.com", &["me@x.com"], &[], false, 30),
            row(
                "me@x.com",
                &["Priya Nair <priya@acme.co>"],
                &["Sam <sam@acme.co>"],
                true,
                2,
            ),
            row(
                "PRIYA@acme.co",
                &["me@x.com"],
                &["Lee <lee@acme.co>"],
                false,
                1,
            ),
        ];
        let people = rank(&rows, &own);
        let all = matching(&people, "", 10);
        assert_eq!(
            emails(&all),
            vec![
                "priya@acme.co",
                "sam@acme.co",
                "news@shop.com",
                "lee@acme.co"
            ]
        );
        assert_eq!(all[0].name, "Priya Nair");

        // A name's second word, an address, a domain: all "start with".
        assert_eq!(emails(&matching(&people, "nai", 10)), vec!["priya@acme.co"]);
        assert_eq!(emails(&matching(&people, "sam@", 10)), vec!["sam@acme.co"]);
        assert_eq!(
            emails(&matching(&people, "acme", 2)),
            vec!["priya@acme.co", "sam@acme.co"]
        );
        // Contained, not at a word start: after the prefix matches.
        assert_eq!(emails(&matching(&people, "ee", 10)), vec!["lee@acme.co"]);
        assert_eq!(emails(&matching(&people, "hop", 10)), vec!["news@shop.com"]);
    }

    #[test]
    fn people_api_answers_extend_and_enrich_the_local_ones() {
        let own: HashSet<String> = ["me@x.com".to_string()].into();
        let local = vec![ContactSuggestion {
            name: String::new(),
            email: "priya@acme.co".to_string(),
            photo_url: None,
        }];
        let remote = vec![
            ContactSuggestion {
                name: "Priya Nair".to_string(),
                email: "Priya@acme.co".to_string(),
                photo_url: Some("https://photo/p".to_string()),
            },
            ContactSuggestion {
                name: "Me".to_string(),
                email: "me@x.com".to_string(),
                photo_url: None,
            },
            ContactSuggestion {
                name: "Pat".to_string(),
                email: "pat@acme.co".to_string(),
                photo_url: None,
            },
        ];
        let merged = merge(local, remote, &own, 10);
        assert_eq!(emails(&merged), vec!["priya@acme.co", "pat@acme.co"]);
        assert_eq!(merged[0].name, "Priya Nair");
        assert_eq!(merged[0].photo_url.as_deref(), Some("https://photo/p"));
    }
}
