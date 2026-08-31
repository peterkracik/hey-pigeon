//! Search query parsing: Gmail-style operators → structured filters, bare
//! text → an FTS5 MATCH expression (last term gets a `*` prefix query so
//! search-as-you-type matches while the word is still being typed).
// ponytail: label:/has: operators skipped — labels/attachments tables don't
// exist yet (M3); add them when the data does.

/// Markers wrapped around FTS5 snippet() highlights. Private-use-area chars
/// so mail content can never contain them accidentally; the frontend splits
/// on these instead of trusting HTML from the backend.
pub const SNIPPET_START: char = '\u{e000}';
pub const SNIPPET_END: char = '\u{e001}';

/// A parsed search query: FTS match text plus structured filters.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SearchQuery {
    /// FTS5 MATCH expression built from the bare terms; None when the query
    /// is operators-only.
    pub fts_match: Option<String>,
    /// `from:` — substring match on the sender address (lowercased).
    pub from_contains: Option<String>,
    /// `to:` — substring match on recipient addresses (lowercased).
    pub to_contains: Option<String>,
    /// `is:unread`.
    pub unread_only: bool,
    /// `account:` — substring match on the account id/email (lowercased).
    pub account_contains: Option<String>,
}

impl SearchQuery {
    pub fn is_empty(&self) -> bool {
        self.fts_match.is_none()
            && self.from_contains.is_none()
            && self.to_contains.is_none()
            && !self.unread_only
            && self.account_contains.is_none()
    }
}

/// Parse a raw query string. Unknown `word:value` tokens are treated as bare
/// text (Gmail does the same for typos).
pub fn parse(raw: &str) -> SearchQuery {
    let mut q = SearchQuery::default();
    let mut terms: Vec<&str> = Vec::new();
    for token in raw.split_whitespace() {
        if let Some(v) = token.strip_prefix("from:") {
            if !v.is_empty() {
                q.from_contains = Some(v.to_lowercase());
                continue;
            }
        } else if let Some(v) = token.strip_prefix("to:") {
            if !v.is_empty() {
                q.to_contains = Some(v.to_lowercase());
                continue;
            }
        } else if let Some(v) = token.strip_prefix("account:") {
            if !v.is_empty() {
                q.account_contains = Some(v.to_lowercase());
                continue;
            }
        } else if token.eq_ignore_ascii_case("is:unread") {
            q.unread_only = true;
            continue;
        }
        terms.push(token);
    }
    q.fts_match = build_match(&terms);
    q
}

/// Quote every term (protects against FTS5 syntax: `-`, `:`, `"`, parens)
/// and turn the last one into a prefix query.
fn build_match(terms: &[&str]) -> Option<String> {
    if terms.is_empty() {
        return None;
    }
    let last = terms.len() - 1;
    let parts: Vec<String> = terms
        .iter()
        .enumerate()
        .map(|(i, t)| {
            let quoted = format!("\"{}\"", t.replace('"', "\"\""));
            if i == last {
                format!("{quoted}*")
            } else {
                quoted
            }
        })
        .collect();
    Some(parts.join(" "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bare_text_last_term_gets_prefix() {
        let q = parse("quarterly rep");
        assert_eq!(q.fts_match.as_deref(), Some("\"quarterly\" \"rep\"*"));
        assert!(q.from_contains.is_none() && !q.unread_only);
    }

    #[test]
    fn operators_are_extracted() {
        let q = parse("from:Priya@x.com is:unread account:Work to:me@y.com budget");
        assert_eq!(q.from_contains.as_deref(), Some("priya@x.com"));
        assert_eq!(q.to_contains.as_deref(), Some("me@y.com"));
        assert_eq!(q.account_contains.as_deref(), Some("work"));
        assert!(q.unread_only);
        assert_eq!(q.fts_match.as_deref(), Some("\"budget\"*"));
    }

    #[test]
    fn operators_only_has_no_fts_match() {
        let q = parse("is:unread");
        assert!(q.fts_match.is_none());
        assert!(!q.is_empty());
    }

    #[test]
    fn quotes_are_escaped_and_empty_is_empty() {
        assert_eq!(parse("a\"b").fts_match.as_deref(), Some("\"a\"\"b\"*"));
        assert!(parse("   ").is_empty());
    }
}
