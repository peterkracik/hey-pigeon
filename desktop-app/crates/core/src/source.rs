//! A message's "Advanced" actions (docs/specs/message-advanced.md): the
//! message as it was sent, asked from the provider when the user asks
//! for it, and the text of a stored body.
//!
//! The store keeps a message's HTML sanitized (`sanitize::html`) and only
//! the few headers the app acts on. What the sender really wrote — the
//! HTML part untouched, every header — is fetched on demand
//! (`MailProvider::fetch_source`), handed to the shell and dropped: it
//! is never stored, never logged, and nothing in the app renders it.

use std::collections::HashSet;
use std::sync::OnceLock;

/// The largest HTML part that is handed over (R4). It ends up on the
/// clipboard as one string; twice what the reader parses
/// (`sanitize::MAX_INPUT_BYTES`), so any mail the app shows as HTML can
/// be copied.
pub const MAX_HTML_BYTES: usize = 8 * 1024 * 1024;

/// The HTML part of a message as it was sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceHtml {
    /// The part's content, exactly as the provider returned it:
    /// unsanitized. Only ever for the clipboard.
    Sent(String),
    /// The message has no HTML part (plain-text mail).
    Missing,
    /// The part is longer than `MAX_HTML_BYTES`; nothing was kept.
    TooLarge,
}

impl SourceHtml {
    /// What a fetched HTML part becomes: itself, unless there is none or
    /// it is over the cap. A cut-off copy would no longer be the
    /// original, so an oversized part is refused whole.
    pub fn from_sent(html: Option<String>) -> Self {
        match html {
            None => Self::Missing,
            Some(h) if h.len() > MAX_HTML_BYTES => Self::TooLarge,
            Some(h) => Self::Sent(h),
        }
    }
}

/// One message as it was sent: every header in the order the provider
/// lists them (name, value), and its HTML part.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageSource {
    pub headers: Vec<(String, String)>,
    pub html: SourceHtml,
}

/// Tags that end a line in `plain_text`.
const LINE_TAGS: &[&str] = &[
    "br", "div", "tr", "li", "table", "ul", "ol", "hr", "section", "article", "header", "footer",
];
/// Tags with an empty line around them.
const PARAGRAPH_TAGS: &[&str] = &["p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre"];
/// Table cells: a space between two of them.
const CELL_TAGS: &[&str] = &["td", "th"];
/// Elements whose content is not text a reader sees.
const UNSEEN: &[&str] = &["script", "style", "title"];

/// A parse that keeps only the tags `plain_text` reads a line break (or
/// a cell's end) from, without attributes; all other markup goes and its
/// text stays.
fn text_builder() -> &'static ammonia::Builder<'static> {
    static BUILDER: OnceLock<ammonia::Builder<'static>> = OnceLock::new();
    BUILDER.get_or_init(|| {
        let mut b = ammonia::Builder::empty();
        b.tags(
            LINE_TAGS
                .iter()
                .chain(PARAGRAPH_TAGS)
                .chain(CELL_TAGS)
                .copied()
                .collect::<HashSet<_>>(),
        )
        .clean_content_tags(UNSEEN.iter().copied().collect::<HashSet<_>>())
        .strip_comments(true);
        b
    })
}

/// The text of an HTML body, for "Copy plain text" on a message that
/// came without a text part (R6): what a reader sees, one line per block,
/// an empty line between paragraphs, list items marked `- `. Links keep
/// their words and lose their addresses. Meant for a body the core has
/// already sanitized; anything else is parsed just the same.
pub fn plain_text(html: &str) -> String {
    let kept = text_builder().clean(html).to_string();
    let mut out = String::new();
    let mut rest = kept.as_str();
    while let Some(lt) = rest.find('<') {
        push_text(&mut out, &rest[..lt]);
        let Some(len) = rest[lt..].find('>') else {
            rest = "";
            break;
        };
        let tag = &rest[lt + 1..lt + len];
        let closing = tag.starts_with('/');
        let name = tag
            .trim_matches('/')
            .split_whitespace()
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        let name = name.as_str();
        if name == "br" {
            trim_line_end(&mut out);
            // Two in a row are an empty line; more add nothing.
            if !out.ends_with("\n\n") {
                out.push('\n');
            }
        } else if PARAGRAPH_TAGS.contains(&name) {
            break_line(&mut out, 2);
        } else if LINE_TAGS.contains(&name) {
            break_line(&mut out, 1);
            if name == "li" && !closing {
                out.push_str("- ");
            }
        } else if CELL_TAGS.contains(&name) && closing {
            push_text(&mut out, " ");
        }
        rest = &rest[lt + len + 1..];
    }
    push_text(&mut out, rest);
    out.trim().to_string()
}

/// Text between two tags: its white space runs are one space each (as a
/// page shows them), none at a line's start, and the serializer's
/// escapes are undone.
fn push_text(out: &mut String, chunk: &str) {
    let chunk = chunk.replace("&nbsp;", " ");
    let mut pending_space = false;
    for c in chunk.chars() {
        if c.is_whitespace() {
            pending_space = true;
            continue;
        }
        if pending_space && !out.is_empty() && !out.ends_with(['\n', ' ']) {
            out.push(' ');
        }
        pending_space = false;
        out.push(c);
    }
    if pending_space && !out.is_empty() && !out.ends_with(['\n', ' ']) {
        out.push(' ');
    }
    // `&amp;` last, and only on what this call added, so `&amp;lt;` stays
    // the `&lt;` its author wrote. The escapes are ASCII: undoing them in
    // the tail cannot split a character.
    if chunk.contains('&') {
        let from = out.len().saturating_sub(chunk.len() + 1);
        let from = (from..=out.len())
            .find(|i| out.is_char_boundary(*i))
            .unwrap_or(out.len());
        let tail = out[from..]
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&amp;", "&");
        out.truncate(from);
        out.push_str(&tail);
    }
}

fn trim_line_end(out: &mut String) {
    while out.ends_with(' ') {
        out.pop();
    }
}

/// End the line being written: `newlines` line ends after its text (two
/// leave an empty line), never more than that however many blocks close
/// and open in a row, and none at the very start.
fn break_line(out: &mut String, newlines: usize) {
    trim_line_end(out);
    if out.is_empty() {
        return;
    }
    let have = out.chars().rev().take_while(|c| *c == '\n').count();
    for _ in have..newlines {
        out.push('\n');
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// R3, R4: the part is kept as it came; none is "missing"; one over
    /// the cap is refused whole, at exactly one byte over.
    #[test]
    fn html_is_kept_missing_or_too_large() {
        let raw = "<p onclick=\"x()\">Hi</p><script>alert(1)</script>";
        assert_eq!(
            SourceHtml::from_sent(Some(raw.to_string())),
            SourceHtml::Sent(raw.to_string())
        );
        assert_eq!(SourceHtml::from_sent(None), SourceHtml::Missing);
        let at_cap = "a".repeat(MAX_HTML_BYTES);
        assert!(matches!(
            SourceHtml::from_sent(Some(at_cap.clone())),
            SourceHtml::Sent(_)
        ));
        assert_eq!(
            SourceHtml::from_sent(Some(at_cap + "a")),
            SourceHtml::TooLarge
        );
    }

    /// The fake provider answers like a real one: the message's headers
    /// in order, its HTML as it holds it, an error for a message it does
    /// not know.
    #[tokio::test]
    async fn the_fake_provider_hands_over_a_messages_source() {
        use crate::fakes::FakeProvider;
        use crate::ports::MailProvider;
        let provider = FakeProvider::with_sample_data("acc", 1, 10);
        let account = "acc".to_string();
        let page = provider.list_recent(&account, 30, None).await.unwrap();
        let (thread, messages) = &page.threads[0];
        let source = provider
            .fetch_source(&account, &messages[0].id)
            .await
            .unwrap();
        assert_eq!(source.headers[0].0, "From");
        assert!(source
            .headers
            .contains(&("Subject".to_string(), thread.subject.clone())));
        assert_eq!(source.html, SourceHtml::Missing);
        assert!(provider
            .fetch_source(&account, &"nope".to_string())
            .await
            .is_err());
    }

    /// R6: blocks are lines, paragraphs are parted by an empty line,
    /// white space collapses as on a page.
    #[test]
    fn plain_text_follows_the_blocks() {
        let html = "<div>Hello,\n   world</div><div>Second line</div>\
                    <p>A paragraph<br>on two lines.</p><p>Another.</p>";
        assert_eq!(
            plain_text(html),
            "Hello, world\nSecond line\n\nA paragraph\non two lines.\n\nAnother."
        );
    }

    /// Scripts, styles and comments are not text; a link is its words;
    /// escapes come back as the characters they stand for.
    #[test]
    fn plain_text_drops_what_is_not_seen_and_decodes_escapes() {
        let html = "<style>p{color:red}</style><p>Tom &amp; Jerry &lt;tj@x.com&gt;&nbsp;wrote \
                    <a href=\"https://example.com\">this</a><!-- note --></p><script>x()</script>";
        assert_eq!(plain_text(html), "Tom & Jerry <tj@x.com> wrote this");
        // What the author wrote as an escape of an escape stays one.
        assert_eq!(plain_text("<p>&amp;lt;b&amp;gt;</p>"), "&lt;b&gt;");
    }

    #[test]
    fn plain_text_marks_list_items_and_parts_table_cells() {
        let html = "<ul><li>One</li><li>Two</li></ul>\
                    <table><tr><td>Total</td><td>12 €</td></tr><tr><td>Paid</td></tr></table>";
        assert_eq!(plain_text(html), "- One\n- Two\nTotal 12 €\nPaid");
    }

    #[test]
    fn plain_text_of_nothing_is_empty_and_breaks_do_not_pile_up() {
        assert_eq!(plain_text(""), "");
        assert_eq!(plain_text("<div><div><p></p></div></div>"), "");
        assert_eq!(
            plain_text("<p>a</p><div></div><br><br><br><p>b</p>"),
            "a\n\nb"
        );
    }
}
