//! HTML sanitation for mail bodies: what makes an e-mail's markup safe to
//! hand to a view, while it still looks like the mail the sender made.
//!
//! One function, [`html`]. It runs where a body enters the store (the
//! provider's full fetch), where a draft is read for the composer, and —
//! for a body an older build stored as received — where it leaves for a
//! shell, so every HTML string the shells are given has been through it
//! (once: a stored body carries a flag that says so). The shells
//! keep their own layer (a web view with the mail's JavaScript off, a
//! content security policy, navigation handed to the system); this one is
//! there so that a mistake in either is not enough.
//!
//! The markup goes through `ammonia` (an allowlist over a real HTML
//! parse): tags and attributes that are not named below are dropped, and
//! URLs are held to a short list of schemes. The rest is handled here,
//! because e-mail needs it and ammonia has no hook that fits:
//!
//! - **`<style>` blocks are kept.** Newsletters lay themselves out (and
//!   switch to dark mode) through them. Ammonia can only drop a tag whose
//!   content is raw text, so the blocks are read from the input, their CSS
//!   scrubbed ([`scrub_stylesheet`]) and written back in front of the
//!   sanitized markup. What is written back cannot hold a tag: it is the
//!   text of a `<style>` element, and the scrub leaves no `<` that could
//!   end one.
//! - **Inline `style` attributes are kept, declaration by declaration**
//!   ([`filter_inline_style`]). Ammonia's own style-property filter was
//!   tried and put aside: it loses the inside of nested functions
//!   (`linear-gradient(…, rgba(0,0,0,.5) 100%)` came out as
//!   `linear-gradient(…, rgba( 100%)`), which both breaks the mail and
//!   changes the result on a second pass.
//! - **A full document keeps its body's attributes**: `<body style=…
//!   class=…>` becomes a `<div>` around the content, since a fragment has
//!   no body to carry them.
//! - **Nesting is capped** ([`cap_nesting`]) before the parse. The HTML
//!   parser's work grows with the square of how deep block elements nest:
//!   20,000 `<div>`s inside each other — 100 KB of mail — took it a
//!   second, a megabyte of them would take minutes, and this runs on mail
//!   anyone can send. Browsers stop at a depth of 512 for the same
//!   reason. Past `MAX_NESTING` the tags that would go deeper are left
//!   out; what they wrapped stays.
//! - **`<pre>` keeps a leading blank line** ([`keep_pre_line_breaks`]),
//!   which the serializer would lose.
//! - **Tracking pixels are taken out** ([`block_tracking_pixels`]): a
//!   remote picture too small to see, or hidden, is there to tell the
//!   sender the mail was opened. Each leaves [`TRACKER_MARKER`] in its
//!   place, which the shells count ("3 trackers blocked"). A heuristic:
//!   what it misses is still a remote picture, and those load only when
//!   the shell's image policy lets them.
//! - **Names beginning `hp-` belong to the app** ([`OWN_PREFIX`]): the
//!   marker's class, and what the shells add to a body they show. A
//!   `class` or `id` in mail that begins so loses it, so a sender cannot
//!   write a marker (a blocked tracker that never was) or pass for
//!   something the app put there.
//! - **A body past [`MAX_INPUT_BYTES`] comes out as its text**
//!   ([`oversized_as_text`]): parsing costs time and memory in proportion,
//!   and mail of any size can be sent to anyone.
//!
//! `html(html(x)) == html(x)`: a body stored sanitized can go through
//! again (a draft opened, saved and opened once more) without changing.
//! For a body with markers that takes telling this function's own output
//! from mail that copies it, byte for byte — which only a secret can do.
//! Such output ends in a **seal** ([`seal`]): a comment holding a keyed
//! hash of everything before it, under a key that never leaves the
//! device ([`set_seal_key`]). Input that ends in a valid seal is returned
//! as it is; everything else is mail, and loses its `hp-` names.

use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

/// Elements that stay, with their content.
const TAGS: &[&str] = &[
    "a",
    "abbr",
    "acronym",
    "address",
    "article",
    "aside",
    "b",
    "bdi",
    "bdo",
    "big",
    "blockquote",
    "br",
    "caption",
    "center",
    "cite",
    "code",
    "col",
    "colgroup",
    "dd",
    "del",
    "details",
    "dfn",
    "div",
    "dl",
    "dt",
    "em",
    "figcaption",
    "figure",
    "font",
    "footer",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "header",
    "hgroup",
    "hr",
    "i",
    "img",
    "ins",
    "kbd",
    "li",
    "main",
    "mark",
    "nav",
    "nobr",
    "ol",
    "p",
    "pre",
    "q",
    "rp",
    "rt",
    "ruby",
    "s",
    "samp",
    "section",
    "small",
    "span",
    "strike",
    "strong",
    "sub",
    "summary",
    "sup",
    "table",
    "tbody",
    "td",
    "tfoot",
    "th",
    "thead",
    "time",
    "tr",
    "tt",
    "u",
    "ul",
    "var",
    "wbr",
];

/// Elements that go together with everything inside them. (Any other
/// element that is not in `TAGS` — `form`, `label`, Outlook's `o:p` —
/// loses its tag and keeps its content; `input`, `meta`, `link` and `base`
/// have none.) These are the ones whose content is not for reading:
/// script and style text, the document title, what a frame or a plug-in
/// shows when it cannot run, form controls' own text, drawings.
const REMOVED_WITH_CONTENT: &[&str] = &[
    "applet", "audio", "button", "canvas", "embed", "frame", "frameset", "iframe", "math",
    "noembed", "noframes", "noscript", "object", "script", "select", "style", "svg", "template",
    "textarea", "title", "video", "xml",
];

/// Attributes that stay on any element. `class` and `id` stay as written:
/// the shells fold quoted mail by them (`div.gmail_quote`,
/// `div#mail-editor-reference-message-container`).
const GENERIC_ATTRIBUTES: &[&str] = &[
    "align", "bgcolor", "class", "dir", "height", "id", "lang", "role", "style", "title", "valign",
    "width",
];

/// Attributes that stay on one element.
const TAG_ATTRIBUTES: &[(&str, &[&str])] = &[
    ("a", &["href", "name"]),
    ("blockquote", &["type"]),
    ("br", &["clear"]),
    ("col", &["span"]),
    ("colgroup", &["span"]),
    ("del", &["datetime"]),
    ("details", &["open"]),
    ("font", &["color", "face", "size"]),
    ("hr", &["color", "noshade", "size"]),
    ("img", &["alt", "border", "hspace", "src", "vspace"]),
    ("ins", &["datetime"]),
    ("li", &["type", "value"]),
    ("ol", &["reversed", "start", "type"]),
    (
        "table",
        &["background", "border", "cellpadding", "cellspacing"],
    ),
    (
        "td",
        &[
            "abbr",
            "background",
            "colspan",
            "headers",
            "nowrap",
            "rowspan",
            "scope",
        ],
    ),
    (
        "th",
        &[
            "abbr",
            "background",
            "colspan",
            "headers",
            "nowrap",
            "rowspan",
            "scope",
        ],
    ),
    ("time", &["datetime"]),
    ("tr", &["background"]),
    ("ul", &["type"]),
];

/// URL schemes ammonia lets through on `href` and `src`; `filter_attribute`
/// then narrows them by attribute (`cid:` and `data:` are for pictures).
const URL_SCHEMES: &[&str] = &["cid", "data", "http", "https", "mailto", "tel"];

/// Where a link may lead: the web, a composer, the phone.
const LINK_SCHEMES: &[&str] = &["http", "https", "mailto", "tel"];

/// CSS properties dropped from inline styles and neutralised in style
/// blocks: `position` lets mail draw over other mail (Gmail strips it
/// too, so no layout counts on it); the rest ran script in old browsers.
const FORBIDDEN_PROPERTIES: &[&str] = &["position", "behavior", "-ms-behavior", "-moz-binding"];

/// How deep elements may nest (counted the way `cap_nesting` counts).
/// Real mail — layout tables inside layout tables — stays under a few
/// dozen.
const MAX_NESTING: usize = 256;

/// Sanitize an HTML mail body (or draft) for display. See the module
/// documentation for what stays and what goes.
pub fn html(input: &str) -> String {
    if is_sealed(input) {
        return input.to_string();
    }
    if input.len() > MAX_INPUT_BYTES {
        return oversized_as_text(input);
    }
    let input = &*cap_nesting(input, MAX_NESTING);
    let mut out = String::with_capacity(input.len());
    for css in style_blocks(input) {
        let css = scrub_stylesheet(css);
        if !css.trim().is_empty() {
            out.push_str("<style>");
            out.push_str(&css);
            out.push_str("</style>");
        }
    }
    let markup = builder().clean(&body_as_div(input)).to_string();
    keep_pre_line_breaks(&block_tracking_pixels(&markup), &mut out);
    seal(&mut out);
    out
}

/// What stands where a tracking pixel was. Hidden, so the mail looks the
/// same; a class of its own, so the shells can count them. Only this
/// module writes it: mail cannot (`OWN_PREFIX`).
pub const TRACKER_MARKER: &str = "<span class=\"hp-tracker\" style=\"display:none\"></span>";

/// How the names the app itself writes into a body begin: the marker's
/// class here, the classes the shells add when they show one
/// (`hp-linkwarn`). A `class` or `id` in mail may not begin so
/// (`filter_attribute`), in any letter case — a page in quirks mode
/// matches class names without it.
const OWN_PREFIX: &str = "hp-";

fn is_own_name(name: &str) -> bool {
    name.get(..OWN_PREFIX.len())
        .is_some_and(|start| start.eq_ignore_ascii_case(OWN_PREFIX))
}

/// A `class` value without the names that are the app's; None when
/// nothing is left of it.
fn without_own_classes(value: &str) -> Option<Cow<'_, str>> {
    if !value.split_ascii_whitespace().any(is_own_name) {
        return Some(Cow::Borrowed(value));
    }
    let kept: Vec<&str> = value
        .split_ascii_whitespace()
        .filter(|name| !is_own_name(name))
        .collect();
    (!kept.is_empty()).then(|| Cow::Owned(kept.join(" ")))
}

// ---- The seal: how a second pass knows this function's own output.
//
// Sanitized output goes through `html` again (a stored draft opened, a
// body a shell hands back), and must come out the same, markers and all.
// Mail must not be able to bring a marker in. Both at once need the two
// to be told apart, and whatever this function writes a sender can write
// too — unless it takes a secret to write it. So output that holds a
// marker ends in `<!--hp-seal:…-->`: HMAC-SHA256, cut to 128 bits, of
// every byte before the comment, under a key only this install has.
// Input with a valid seal is this function's output, unchanged since, and
// is returned as it is. Any other input — mail, a body edited after it
// was sanitized, one sealed on another device, one stored before there
// were seals — is sanitized as mail: its `hp-` names go, and so does the
// comment. A seal says nothing about any other text, so one that leaks
// (a reply quoting the body) lets nobody make another.
//
// Output without a marker carries no seal: it has nothing to protect and
// is its own second pass already.

const SEAL_START: &str = "<!--hp-seal:";
const SEAL_END: &str = "-->";
/// Hex digits in a seal: 128 bits.
const SEAL_DIGITS: usize = 32;

/// The key seals are made with. None when the system gave no random
/// bytes: then nothing is sealed, and nothing passes as sealed.
static SEAL_KEY: OnceLock<Option<[u8; 32]>> = OnceLock::new();

/// Give the sanitizer this install's key (the engine keeps one in its
/// store), so a body sealed in one launch is recognised in the next. The
/// first key of a process stays — false says this one came too late.
/// Without one, a random key made on first use serves until the process
/// ends.
pub fn set_seal_key(key: [u8; 32]) -> bool {
    SEAL_KEY.set(Some(key)).is_ok()
}

fn seal_key() -> Option<&'static [u8; 32]> {
    SEAL_KEY
        .get_or_init(|| {
            let mut key = [0u8; 32];
            getrandom::fill(&mut key).ok().map(|()| key)
        })
        .as_ref()
}

/// HMAC-SHA256 (RFC 2104) for a key of at most one block.
fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    use sha2::{Digest, Sha256};
    let (mut inner, mut outer) = ([0x36u8; 64], [0x5cu8; 64]);
    for (i, byte) in key.iter().take(64).enumerate() {
        inner[i] ^= byte;
        outer[i] ^= byte;
    }
    let digest = Sha256::new()
        .chain_update(inner)
        .chain_update(message)
        .finalize();
    Sha256::new()
        .chain_update(outer)
        .chain_update(digest)
        .finalize()
        .into()
}

/// The seal's digits for `body` under `key`.
fn seal_digits(key: &[u8; 32], body: &str) -> String {
    hmac_sha256(key, body.as_bytes())[..SEAL_DIGITS / 2]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// End `out` with its seal, when it holds a marker.
fn seal(out: &mut String) {
    if !out.contains(TRACKER_MARKER) {
        return;
    }
    let Some(key) = seal_key() else {
        return;
    };
    let digits = seal_digits(key, out);
    out.push_str(SEAL_START);
    out.push_str(&digits);
    out.push_str(SEAL_END);
}

/// `(what comes before, the digits)` when `html` ends in the shape of a
/// seal — valid or not.
fn split_seal(html: &str) -> Option<(&str, &str)> {
    let rest = html.strip_suffix(SEAL_END)?;
    let at = rest.len().checked_sub(SEAL_DIGITS)?;
    if !rest.is_char_boundary(at) {
        return None;
    }
    let (rest, digits) = rest.split_at(at);
    Some((rest.strip_suffix(SEAL_START)?, digits))
}

/// Whether `html` is this install's sanitized output, as it was written.
fn is_sealed(html: &str) -> bool {
    let Some((body, digits)) = split_seal(html) else {
        return false;
    };
    let Some(key) = seal_key() else {
        return false;
    };
    // Every digit is compared, however early one differs.
    let differing = seal_digits(key, body)
        .bytes()
        .zip(digits.bytes())
        .fold(0u8, |sum, (ours, theirs)| sum | (ours ^ theirs));
    differing == 0
}

/// A sanitized body without the seal it may end in: what the reader
/// sees. (The seal is a comment; nothing that shows the body needs it
/// gone.)
pub fn unsealed(html: &str) -> &str {
    split_seal(html).map_or(html, |(body, _)| body)
}

/// The longest body that is parsed. Real HTML mail is tens to hundreds of
/// kilobytes; this leaves room for the odd one that carries its pictures
/// inline.
pub const MAX_INPUT_BYTES: usize = 4 * 1024 * 1024;

/// A picture this small in both directions (CSS pixels) cannot be seen.
const PIXEL_MAX_SIZE: f64 = 2.0;

/// Sanitized `markup` with its tracking pixels replaced by
/// `TRACKER_MARKER`. What a tracking pixel is, is a guess made from the
/// tag alone: an `<img>` loaded from the web (`http` / `https`: a `cid:`
/// or `data:` picture is part of the mail and tells nobody anything),
/// with no `class` or `id` — a style sheet can size or show a picture it
/// can name, and newsletters do: a logo whose attributes say 1 × 1 and
/// whose class says otherwise, a picture hidden inline and shown on a
/// narrow screen — that is
/// - at most 2 × 2, both directions known (a 1 × 600 rule or a spacer
///   that is only narrow is layout). The inline style goes before the
///   `width` / `height` attributes, as it does on screen: a style size
///   that is no pixel length (`100%`, `auto`) leaves the size unknown
///   whatever the attribute says, and a `max-` length caps it;
/// - or hidden by its own inline style (`display:none`,
///   `visibility:hidden`).
///
/// It errs towards leaving a picture in. A pixel of 3 × 3, a transparent
/// one (`opacity:0`), one hidden by the element around it, one drawn as a
/// CSS background, or one that was simply given a class gets through. It
/// is then a remote picture like any other: whether it loads is the
/// shell's image policy's decision, as before there was this.
///
/// Runs on ammonia's output, where a tag is a tag and every attribute is
/// `name="value"`, so the tag is read as it was written.
fn block_tracking_pixels(markup: &str) -> Cow<'_, str> {
    let mut out: Option<String> = None;
    let mut copied = 0;
    let mut from = 0;
    while let Some(pos) = markup[from..].find("<img") {
        let tag = from + pos;
        let Some(end) = markup[tag..].find('>').map(|i| tag + i + 1) else {
            break;
        };
        from = end;
        if !markup[tag + 4..].starts_with([' ', '>']) {
            continue;
        }
        if is_tracking_pixel(&markup[tag + 4..end - 1]) {
            let out = out.get_or_insert_with(|| String::with_capacity(markup.len()));
            out.push_str(&markup[copied..tag]);
            out.push_str(TRACKER_MARKER);
            copied = end;
        }
    }
    match out {
        Some(mut out) => {
            out.push_str(&markup[copied..]);
            Cow::Owned(out)
        }
        None => Cow::Borrowed(markup),
    }
}

/// `attributes` is the inside of a sanitized `<img …>` tag.
fn is_tracking_pixel(attributes: &str) -> bool {
    let mut src = None;
    let mut style = "";
    let (mut width, mut height) = (None, None);
    let mut addressable = false;
    let mut rest = attributes;
    // ` name="value"` pairs, as the serializer writes them.
    while let Some((name, after)) = rest.trim_start().split_once("=\"") {
        let Some((value, after)) = after.split_once('"') else {
            break;
        };
        match name.trim() {
            "src" => src = Some(value),
            "style" => style = value,
            "width" => width = css_pixels(value),
            "height" => height = css_pixels(value),
            "class" | "id" => addressable |= !value.trim().is_empty(),
            _ => {}
        }
        rest = after;
    }
    if !matches!(src.and_then(url_scheme).as_deref(), Some("http" | "https")) {
        return false;
    }
    let mut hidden = false;
    // What the style says of each direction: its size (None when it is
    // not a pixel length) and its cap.
    let (mut style_width, mut style_height) = (None, None);
    let (mut max_width, mut max_height) = (None, None);
    for declaration in style.split(';') {
        let Some((name, value)) = declaration.split_once(':') else {
            continue;
        };
        let value = value.to_ascii_lowercase();
        let value = value.replace("!important", "");
        let value = value.trim();
        match name.trim().to_ascii_lowercase().as_str() {
            "display" => hidden |= value == "none",
            "visibility" => hidden |= value == "hidden",
            "width" => style_width = Some(css_pixels(value)),
            "height" => style_height = Some(css_pixels(value)),
            "max-width" => max_width = css_pixels(value).or(max_width),
            "max-height" => max_height = css_pixels(value).or(max_height),
            _ => {}
        }
    }
    // The style wins over the attribute, as it does on screen — also when
    // what it says is `100%`.
    let tiny = |attribute: Option<f64>, style: Option<Option<f64>>, max: Option<f64>| {
        let size = match (style.unwrap_or(attribute), max) {
            (Some(size), Some(max)) => Some(size.min(max)),
            (size, max) => size.or(max),
        };
        size.is_some_and(|px| px <= PIXEL_MAX_SIZE)
    };
    let unseen =
        hidden || (tiny(width, style_width, max_width) && tiny(height, style_height, max_height));
    unseen && !addressable
}

/// A length in CSS pixels: `1`, `1px`, `0`. None for anything relative
/// (`1%`, `1em`) or not a number.
fn css_pixels(value: &str) -> Option<f64> {
    let value = value.trim().to_ascii_lowercase();
    let number = value.strip_suffix("px").unwrap_or(&value).trim();
    let px: f64 = number.parse().ok()?;
    (px.is_finite() && px >= 0.0).then_some(px)
}

/// Elements that start a new line when a body is read as text.
const LINE_BREAKING_ELEMENTS: &[&str] = &[
    "address",
    "article",
    "aside",
    "blockquote",
    "br",
    "dd",
    "div",
    "dl",
    "dt",
    "footer",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "header",
    "hr",
    "li",
    "main",
    "ol",
    "p",
    "pre",
    "section",
    "table",
    "tr",
    "ul",
];

/// A body too large to parse, as its text: the tags left out (script and
/// style with their content), block elements turned into line breaks,
/// white space collapsed the way a browser would. No DOM is built — one
/// pass over the bytes — and nothing of the input's markup survives: the
/// only tags in the result are the `<div>` around it and `<br>`.
fn oversized_as_text(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut text = String::with_capacity(input.len() / 4);
    // Whether a space / a line break is owed before the next character.
    let (mut space, mut line_break) = (false, false);
    let mut at = 0;
    while at < input.len() {
        let rest = &input[at..];
        if rest.starts_with('<') {
            let name_at = at + 1 + usize::from(rest[1..].starts_with('/'));
            if rest.starts_with("<!--") {
                at = rest.find("-->").map_or(input.len(), |i| at + i + 3);
                continue;
            }
            if bytes.get(name_at).is_some_and(u8::is_ascii_alphabetic) {
                let name_len = bytes[name_at..]
                    .iter()
                    .position(|b| b.is_ascii_whitespace() || matches!(b, b'/' | b'>'))
                    .unwrap_or(bytes.len() - name_at);
                let name = &input[name_at..name_at + name_len];
                let after = tag_end(bytes, name_at + name_len).unwrap_or(input.len());
                at = after;
                let start_tag = !rest[1..].starts_with('/');
                if names(LINE_BREAKING_ELEMENTS, name) {
                    line_break = true;
                } else if start_tag && names(RAW_TEXT_ELEMENTS, name) {
                    // Its content is not for reading.
                    let end = format!("</{}", name.to_ascii_lowercase());
                    at = find_ignore_ascii_case(&input[after..], &end)
                        .map_or(input.len(), |i| after + i);
                }
                continue;
            }
            if rest[1..].starts_with(['!', '?']) {
                at = rest.find('>').map_or(input.len(), |i| at + i + 1);
                continue;
            }
        }
        let c = rest.chars().next().unwrap_or(' ');
        at += c.len_utf8();
        if c.is_whitespace() {
            space = true;
            continue;
        }
        if line_break && !text.is_empty() {
            text.push_str("<br>");
        } else if space && !text.is_empty() {
            text.push(' ');
        }
        (space, line_break) = (false, false);
        match c {
            '<' => text.push_str("&lt;"),
            '>' => text.push_str("&gt;"),
            // An entity stays one; a bare `&` becomes one.
            '&' if !starts_entity(&input[at..]) => text.push_str("&amp;"),
            c => text.push(c),
        }
    }
    let wrapped = format!("<div>{text}</div>");
    // Small enough now (it usually is: markup is most of such a body), it
    // goes through the sanitizer proper, which also makes it read the same
    // on any later pass.
    if wrapped.len() <= MAX_INPUT_BYTES {
        html(&wrapped)
    } else {
        wrapped
    }
}

/// Whether what follows an `&` makes it a character reference
/// (`amp;`, `#39;`, `#x27;`).
fn starts_entity(after: &str) -> bool {
    let Some(end) = after.bytes().take(32).position(|b| b == b';') else {
        return false;
    };
    let name = &after[..end];
    match name.strip_prefix('#') {
        Some(number) => {
            let digits = number.strip_prefix(['x', 'X']);
            match digits {
                Some(hex) => !hex.is_empty() && hex.bytes().all(|b| b.is_ascii_hexdigit()),
                None => !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()),
            }
        }
        None => !name.is_empty() && name.bytes().all(|b| b.is_ascii_alphanumeric()),
    }
}

/// Append sanitized `markup` to `out`, with the line break the HTML
/// serialization rules ask for after `<pre>` when its text starts with
/// one. A parser drops the first line break inside `<pre>`; the
/// serializer ammonia uses does not write the extra one that makes up for
/// it, so preformatted text that began with a blank line lost it (and
/// one more on every further pass).
fn keep_pre_line_breaks(markup: &str, out: &mut String) {
    let mut rest = markup;
    while let Some(pos) = rest.find("<pre") {
        // In sanitized markup `<` only starts a tag and `>` only ends one.
        let Some(end) = rest[pos..].find('>').map(|i| pos + i + 1) else {
            break;
        };
        out.push_str(&rest[..end]);
        let is_pre = rest[pos + 4..].starts_with(['>', ' ']);
        if is_pre && rest[end..].starts_with('\n') {
            out.push('\n');
        }
        rest = &rest[end..];
    }
    out.push_str(rest);
}

fn builder() -> &'static ammonia::Builder<'static> {
    static BUILDER: OnceLock<ammonia::Builder<'static>> = OnceLock::new();
    BUILDER.get_or_init(|| {
        let set = |names: &[&'static str]| names.iter().copied().collect::<HashSet<_>>();
        let mut b = ammonia::Builder::empty();
        b.tags(set(TAGS))
            .clean_content_tags(set(REMOVED_WITH_CONTENT))
            .generic_attributes(set(GENERIC_ATTRIBUTES))
            // Screen readers go by these (`role="presentation"` on a
            // layout table); they name nothing a page could run.
            .generic_attribute_prefixes(set(&["aria-"]))
            .tag_attributes(
                TAG_ATTRIBUTES
                    .iter()
                    .map(|(tag, attributes)| (*tag, set(attributes)))
                    .collect::<HashMap<_, _>>(),
            )
            .url_schemes(set(URL_SCHEMES))
            // A link inside the mail (`href="#details"`) has no scheme.
            .url_relative(ammonia::UrlRelative::PassThrough)
            .link_rel(Some("noopener noreferrer"))
            .strip_comments(true)
            .attribute_filter(filter_attribute);
        b
    })
}

/// The per-attribute rules ammonia's lists cannot express. Runs on
/// attributes that already passed them (so `href` and `src` carry an
/// allowed scheme or none); returns the value to keep, None to drop it.
fn filter_attribute<'a>(element: &str, attribute: &str, value: &'a str) -> Option<Cow<'a, str>> {
    match attribute {
        "style" => filter_inline_style(value).map(Cow::Owned),
        // A link leads somewhere a person can go; `cid:` and `data:` are
        // not places.
        "href" => match url_scheme(value) {
            Some(scheme) if !LINK_SCHEMES.contains(&scheme.as_str()) => None,
            _ => Some(Cow::Borrowed(value)),
        },
        "src" if element == "img" => is_image_url(value, true).then_some(Cow::Borrowed(value)),
        // `background` is a picture's address too, but not one ammonia
        // checks: it has to name its scheme here.
        "background" => is_image_url(value, false).then_some(Cow::Borrowed(value)),
        // Names beginning `hp-` are the app's own (`OWN_PREFIX`).
        "class" => without_own_classes(value),
        "id" if is_own_name(value.trim()) => None,
        _ => Some(Cow::Borrowed(value)),
    }
}

/// A picture's address: the web, an inline part of the mail (`cid:`, which
/// the shell resolves), or the picture itself as a `data:image/…` URL —
/// never `data:` of another type, which could be a page. `relative` says
/// whether an address without a scheme is acceptable.
fn is_image_url(value: &str, relative: bool) -> bool {
    match url_scheme(value).as_deref() {
        Some("http" | "https" | "cid") => true,
        Some("data") => data_url_is_image(value),
        Some(_) => false,
        None => relative,
    }
}

fn data_url_is_image(value: &str) -> bool {
    let compact: String = value
        .chars()
        .filter(|c| !c.is_ascii_whitespace() && !c.is_ascii_control())
        .take(16)
        .collect::<String>()
        .to_ascii_lowercase();
    compact.starts_with("data:image/")
}

/// The scheme of a URL as a browser reads it (leading spaces and control
/// characters skipped, tabs and line breaks ignored anywhere), lowercase;
/// None for a relative one.
fn url_scheme(value: &str) -> Option<String> {
    let mut scheme = String::new();
    let trimmed = value.trim_start_matches(|c: char| c <= ' ');
    for c in trimmed.chars() {
        match c {
            '\t' | '\n' | '\r' => continue,
            ':' => {
                let starts_with_letter = scheme
                    .chars()
                    .next()
                    .is_some_and(|c| c.is_ascii_alphabetic());
                return starts_with_letter.then_some(scheme);
            }
            c if c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.') => {
                scheme.push(c.to_ascii_lowercase())
            }
            _ => return None,
        }
    }
    None
}

// ------------------------------------------------------------------- CSS

/// An inline `style` attribute, declaration by declaration: one stays as
/// written unless it sets a forbidden property, is not a declaration at
/// all, or its value could run script or load something that is not a
/// picture. None when nothing is left.
fn filter_inline_style(value: &str) -> Option<String> {
    let css = strip_css_comments(value);
    let mut kept: Vec<String> = Vec::new();
    for declaration in split_top_level(&css, ';') {
        let Some((name, value)) = split_top_level_once(declaration, ':') else {
            continue;
        };
        let (name, value) = (name.trim(), value.trim());
        if value.is_empty() || !is_property_name(name) {
            continue;
        }
        if FORBIDDEN_PROPERTIES.contains(&name.to_ascii_lowercase().as_str()) {
            continue;
        }
        if !is_balanced(value) || css_value_is_unsafe(value) {
            continue;
        }
        kept.push(format!("{name}:{value}"));
    }
    (!kept.is_empty()).then(|| kept.join(";"))
}

/// The text of a `<style>` element, made safe to keep:
/// - comments and the `<!-- -->` wrapper old mail puts around its CSS go;
/// - `@import` rules go (a style sheet from elsewhere);
/// - `expression(`, `javascript:` / `vbscript:` and the forbidden
///   properties are renamed (`x-…`), which makes the declaration they are
///   in one that no browser knows;
/// - a sheet that still names one of those once its CSS escapes are read
///   (`\65xpression(`) is dropped whole: nothing honest writes that;
/// - no `<` is left in front of anything that could start or end a tag,
///   so the text cannot close its own `<style>` element.
///
/// `url(…)` stays: whether it loads is the shell's content security
/// policy's decision (that is how "load remote images" works).
fn scrub_stylesheet(css: &str) -> String {
    let css = css.replace("<!--", " ").replace("-->", " ");
    let css = strip_css_comments(&css);
    let css = remove_imports(&css);
    let mut css = rename(&css, "expression", Follows::Paren, Precedes::NotIdent);
    for scheme in ["javascript", "vbscript"] {
        css = rename(&css, scheme, Follows::Colon, Precedes::NotIdent);
    }
    for property in FORBIDDEN_PROPERTIES {
        css = rename(&css, property, Follows::Colon, Precedes::Declaration);
    }
    if stylesheet_is_unsafe(&css) {
        return String::new();
    }
    // `<` only means something to CSS in a string or a range query
    // (`width < 600px`); in front of a letter, `/`, `!` or `?` it could
    // be read as markup by whatever handles this text next.
    let mut out = String::with_capacity(css.len());
    let mut chars = css.chars().peekable();
    while let Some(c) = chars.next() {
        out.push(c);
        if c == '<'
            && chars
                .peek()
                .is_some_and(|n| n.is_ascii_alphabetic() || matches!(n, '/' | '!' | '?'))
        {
            out.push(' ');
        }
    }
    out
}

/// What must come after a name for it to be the thing to rename.
#[derive(Clone, Copy)]
enum Follows {
    /// `name(`: a function.
    Paren,
    /// `name:` — a property, or a URL scheme.
    Colon,
}

/// What must come before it.
#[derive(Clone, Copy)]
enum Precedes {
    /// Anything that is not part of a longer name (`x-expression(` and
    /// `background-position:` are other names).
    NotIdent,
    /// The start of a declaration: `{`, `;` or the start of the text. A
    /// selector can hold the same word (`.position:hover`).
    Declaration,
}

fn is_ident_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '\\') || !c.is_ascii()
}

/// Byte offsets in `css` where `name` stands as `follows` / `precedes`
/// say, compared without case.
fn occurrences(css: &str, name: &str, follows: Follows, precedes: Precedes) -> Vec<usize> {
    let lower = css.to_ascii_lowercase();
    let mut found = Vec::new();
    let mut from = 0;
    while let Some(pos) = lower[from..].find(name) {
        let at = from + pos;
        from = at + name.len();
        let before = css[..at].trim_end_matches(|c: char| c.is_whitespace());
        let preceded = match precedes {
            Precedes::NotIdent => !css[..at].chars().next_back().is_some_and(is_ident_char),
            Precedes::Declaration => before.is_empty() || before.ends_with(['{', ';']),
        };
        let after = css[from..].trim_start_matches(|c: char| c.is_whitespace());
        let followed = match follows {
            Follows::Paren => after.starts_with('('),
            Follows::Colon => after.starts_with(':'),
        };
        if preceded && followed {
            found.push(at);
        }
    }
    found
}

/// `css` with `x-` put in front of every such occurrence of `name`. The
/// renamed form is not an occurrence itself, so a second pass adds
/// nothing.
fn rename(css: &str, name: &str, follows: Follows, precedes: Precedes) -> String {
    let at = occurrences(css, name, follows, precedes);
    if at.is_empty() {
        return css.to_string();
    }
    let mut out = String::with_capacity(css.len() + 2 * at.len());
    let mut from = 0;
    for pos in at {
        out.push_str(&css[from..pos]);
        out.push_str("x-");
        from = pos;
    }
    out.push_str(&css[from..]);
    out
}

/// Whether the sheet still holds something `scrub_stylesheet` renames or
/// removes once CSS escapes and spacing are out of the way — written so
/// that a plain reading would miss it.
fn stylesheet_is_unsafe(css: &str) -> bool {
    let plain = css_plain(css);
    plain.contains("@import")
        || !occurrences(&plain, "expression", Follows::Paren, Precedes::NotIdent).is_empty()
        || ["javascript", "vbscript"]
            .iter()
            .any(|s| !occurrences(&plain, s, Follows::Colon, Precedes::NotIdent).is_empty())
        || FORBIDDEN_PROPERTIES
            .iter()
            .any(|p| !occurrences(&plain, p, Follows::Colon, Precedes::Declaration).is_empty())
}

/// Whether one inline declaration's value could run script (the old
/// `expression(`, a `javascript:` URL) or names, in `url(…)`, something
/// that is not a picture's address.
fn css_value_is_unsafe(value: &str) -> bool {
    let plain = css_plain(value);
    if ["expression(", "javascript:", "vbscript:", "@import"]
        .iter()
        .any(|bad| plain.contains(bad))
    {
        return true;
    }
    let mut rest = plain.as_str();
    while let Some(pos) = rest.find("url(") {
        rest = &rest[pos + 4..];
        let address = rest.trim_start_matches(['"', '\'']);
        if !is_image_url(address, true) {
            return true;
        }
    }
    false
}

/// CSS as a parser ends up reading it, for looking through: escapes
/// resolved (`\65` is `e`), lowercase, no white space or control
/// characters.
fn css_plain(css: &str) -> String {
    let mut out = String::with_capacity(css.len());
    let mut chars = css.chars().peekable();
    while let Some(c) = chars.next() {
        let c = if c == '\\' {
            let mut hex = String::new();
            while hex.len() < 6 {
                match chars.peek() {
                    Some(h) if h.is_ascii_hexdigit() => hex.push(chars.next().unwrap_or('0')),
                    _ => break,
                }
            }
            if hex.is_empty() {
                // `\x` is `x`; a backslash at the very end is nothing.
                match chars.next() {
                    Some(next) => next,
                    None => break,
                }
            } else {
                // One white space character after the digits ends the escape.
                if chars.peek().is_some_and(|w| w.is_whitespace()) {
                    chars.next();
                }
                u32::from_str_radix(&hex, 16)
                    .ok()
                    .and_then(char::from_u32)
                    .unwrap_or('\u{fffd}')
            }
        } else {
            c
        };
        if !c.is_whitespace() && !c.is_control() {
            out.extend(c.to_lowercase());
        }
    }
    out
}

/// `css` without `/* … */` comments (each becomes a space, so the words
/// around it do not join into a new one). An unclosed comment runs to the
/// end, as it does for a browser.
fn strip_css_comments(css: &str) -> Cow<'_, str> {
    if !css.contains("/*") {
        return Cow::Borrowed(css);
    }
    let mut out = String::with_capacity(css.len());
    let mut rest = css;
    while let Some(start) = rest.find("/*") {
        out.push_str(&rest[..start]);
        out.push(' ');
        match rest[start + 2..].find("*/") {
            Some(end) => rest = &rest[start + 2 + end + 2..],
            None => return Cow::Owned(out),
        }
    }
    out.push_str(rest);
    Cow::Owned(out)
}

/// `css` without its `@import` rules: each from the `@` through the `;`
/// that ends it (or the block it opens, or the end of the text).
fn remove_imports(css: &str) -> String {
    let lower = css.to_ascii_lowercase();
    let mut out = String::with_capacity(css.len());
    let mut from = 0;
    while let Some(pos) = lower[from..].find("@import") {
        let start = from + pos;
        out.push_str(&css[from..start]);
        out.push(' ');
        let rule = &css[start..];
        let end = match rule.find([';', '{']) {
            Some(i) if rule[i..].starts_with(';') => i + 1,
            Some(i) => rule[i..]
                .find('}')
                .map_or(rule.len(), |close| i + close + 1),
            None => rule.len(),
        };
        from = start + end;
    }
    out.push_str(&css[from..]);
    out
}

/// A property name: letters, digits and hyphens (`mso-line-height-rule`,
/// `-webkit-text-size-adjust`), nothing a parser would have to interpret.
fn is_property_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Quotes closed and parentheses matched: a value that is not would take
/// the declarations after it along when a browser reads it.
fn is_balanced(value: &str) -> bool {
    let mut depth = 0i32;
    let mut quote: Option<char> = None;
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        match (quote, c) {
            (_, '\\') => {
                chars.next();
            }
            (Some(q), c) if c == q => quote = None,
            (Some(_), _) => {}
            (None, '"' | '\'') => quote = Some(c),
            (None, '(') => depth += 1,
            (None, ')') => {
                depth -= 1;
                if depth < 0 {
                    return false;
                }
            }
            _ => {}
        }
    }
    depth == 0 && quote.is_none()
}

/// `text` split at each `separator` that is not inside quotes or
/// parentheses (a `;` in `url("a;b")` or `content: ";"` separates
/// nothing).
fn split_top_level(text: &str, separator: char) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut depth = 0i32;
    let mut quote: Option<char> = None;
    let mut start = 0;
    let mut chars = text.char_indices();
    while let Some((i, c)) = chars.next() {
        match (quote, c) {
            (_, '\\') => {
                chars.next();
            }
            (Some(q), c) if c == q => quote = None,
            (Some(_), _) => {}
            (None, '"' | '\'') => quote = Some(c),
            (None, '(') => depth += 1,
            (None, ')') => depth = (depth - 1).max(0),
            (None, c) if c == separator && depth == 0 => {
                parts.push(&text[start..i]);
                start = i + c.len_utf8();
            }
            _ => {}
        }
    }
    parts.push(&text[start..]);
    parts
}

fn split_top_level_once(text: &str, separator: char) -> Option<(&str, &str)> {
    let first = split_top_level(text, separator).into_iter().next()?;
    (first.len() < text.len()).then(|| (first, &text[first.len() + separator.len_utf8()..]))
}

// ------------------------------------------------- reading the raw input

/// True at a tag name's end: white space, `>` or `/`, or the end of the
/// text.
fn ends_tag_name(byte: Option<&u8>) -> bool {
    byte.is_none_or(|b| b.is_ascii_whitespace() || matches!(b, b'>' | b'/'))
}

/// The next `tag` (lowercase, like `<style`) in `lower` at or after
/// `from` that is outside an HTML comment: its offset. Mail made for
/// Outlook keeps Outlook's own markup in conditional comments
/// (`<!--[if mso]><style>…</style><![endif]-->`), and that is not for us.
fn next_tag(lower: &str, tag: &str, mut from: usize) -> Option<usize> {
    let mut found = from + lower[from..].find(tag)?;
    // Walk the comments that open before it; each step moves forward, so
    // a mail made of nothing but comments is still read once.
    while let Some(comment) = lower[from..found].find("<!--") {
        let inside = from + comment + 4;
        from = inside + lower[inside..].find("-->")? + 3;
        if from > found {
            found = from + lower[from..].find(tag)?;
        }
    }
    Some(found)
}

/// The text inside each `<style>` element of `input`, in order. Read with
/// a scan, not a parse: where the two disagree (a `<style` inside a
/// `<textarea>`, say) the result is at worst some text that is not CSS,
/// and `scrub_stylesheet` makes whatever it is given safe to put in a
/// `<style>` element.
fn style_blocks(input: &str) -> Vec<&str> {
    let lower = input.to_ascii_lowercase();
    let bytes = lower.as_bytes();
    let mut blocks = Vec::new();
    let mut from = 0;
    while let Some(open) = next_tag(&lower, "<style", from) {
        from = open + 6;
        if !ends_tag_name(bytes.get(from)) {
            continue;
        }
        let Some(content) = tag_end(bytes, from) else {
            break;
        };
        // Raw text ends at the first `</style` that ends a tag name.
        let mut search = content;
        let end = loop {
            match lower[search..].find("</style") {
                Some(pos) if ends_tag_name(bytes.get(search + pos + 7)) => break search + pos,
                Some(pos) => search += pos + 7,
                None => break input.len(),
            }
        };
        blocks.push(&input[content..end]);
        from = end;
    }
    blocks
}

/// The offset just past the `>` that ends a start tag, scanning its
/// attributes from `from` (just after the tag name) the way the HTML
/// tokenizer does: a `>` inside a quoted attribute value does not end the
/// tag, and a quote only quotes where a value starts. None when the text
/// ends first.
fn tag_end(bytes: &[u8], mut from: usize) -> Option<usize> {
    loop {
        while bytes.get(from)?.is_ascii_whitespace() || bytes[from] == b'/' {
            from += 1;
        }
        if bytes[from] == b'>' {
            return Some(from + 1);
        }
        // An attribute name runs to white space, `/`, `>` or `=` (one
        // that comes first is part of the name).
        from += 1;
        while !matches!(bytes.get(from)?, b'=' | b'>' | b'/') && !bytes[from].is_ascii_whitespace()
        {
            from += 1;
        }
        while bytes.get(from)?.is_ascii_whitespace() {
            from += 1;
        }
        if bytes[from] != b'=' {
            continue;
        }
        from += 1;
        while bytes.get(from)?.is_ascii_whitespace() {
            from += 1;
        }
        match bytes[from] {
            quote @ (b'"' | b'\'') => {
                from += 1;
                while *bytes.get(from)? != quote {
                    from += 1;
                }
                from += 1;
            }
            b'>' => return Some(from + 1),
            _ => {
                while *bytes.get(from)? != b'>' && !bytes[from].is_ascii_whitespace() {
                    from += 1;
                }
            }
        }
    }
}

/// Elements with no content, hence nothing to nest.
const VOID_ELEMENTS: &[&str] = &[
    "area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img", "input",
    "keygen", "link", "meta", "param", "source", "track", "wbr",
];

/// Elements the parser closes by itself when the next one of their kind
/// starts (`<p>one<p>two`, `<li>`, table rows and cells) or does not open
/// at all in a fragment (`<html>`, `<body>`): mail routinely leaves them
/// unclosed, and that is not nesting. They only get deep inside one of
/// the elements that are counted.
const SELF_CLOSING_ELEMENTS: &[&str] = &[
    "body", "caption", "colgroup", "dd", "dt", "head", "html", "li", "optgroup", "option", "p",
    "rb", "rp", "rt", "rtc", "tbody", "td", "tfoot", "th", "thead", "tr",
];

/// Elements whose content is text up to their own end tag, whatever it
/// looks like.
const RAW_TEXT_ELEMENTS: &[&str] = &[
    "iframe",
    "noembed",
    "noframes",
    "plaintext",
    "script",
    "style",
    "textarea",
    "title",
    "xmp",
];

/// Formatting elements: closing one that is not the innermost open
/// element makes the parser rebuild what is inside it rather than close
/// it, so the depth stays what it was.
const FORMATTING_ELEMENTS: &[&str] = &[
    "a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small", "strike", "strong", "tt", "u",
];

/// Elements an end tag does not reach past: `</div>` inside a table cell
/// does not close a `<div>` around the table.
const SCOPE_ELEMENTS: &[&str] = &[
    "applet",
    "caption",
    "desc",
    "foreignobject",
    "marquee",
    "math",
    "object",
    "svg",
    "table",
    "td",
    "template",
    "th",
    "title",
];

/// How far down the open elements an end tag looks for its start tag.
/// (Looking all the way would be the quadratic scan this guards against.)
const END_TAG_REACH: usize = 32;

fn names(list: &[&str], name: &str) -> bool {
    list.iter().any(|n| n.eq_ignore_ascii_case(name))
}

/// `input` with element nesting held to `limit`: a start tag that would
/// open an element deeper than that is left out, and so is its end tag;
/// the content between them stays where it was.
///
/// The depth is kept by a scan that follows the HTML parser closely
/// enough to never count fewer open elements than it would have (it
/// errs towards more: an end tag it cannot place closes nothing), so
/// `limit` here bounds the parser's own stack to a small multiple of it.
/// Whatever the scan gets wrong costs a wrapper element in a document
/// that nests hundreds deep, never safety — the result is sanitized like
/// any other input.
fn cap_nesting(input: &str, limit: usize) -> Cow<'_, str> {
    struct Open<'a> {
        name: &'a str,
        /// Its start tag was left out, so its end tag will be too.
        dropped: bool,
    }
    let bytes = input.as_bytes();
    let mut open: Vec<Open<'_>> = Vec::new();
    // Elements open and not dropped, and how many of the open ones are
    // `<svg>` / `<math>` (inside those, `<g/>` closes itself and nothing
    // is raw text).
    let (mut depth, mut foreign) = (0usize, 0usize);
    let mut out: Option<String> = None;
    let mut copied = 0;
    let mut at = 0;
    while let Some(pos) = bytes[at..].iter().position(|b| *b == b'<') {
        let tag = at + pos;
        let rest = &input[tag + 1..];
        at = tag + 1;
        let end_tag = rest.starts_with('/');
        let name_at = tag + 1 + usize::from(end_tag);
        if !bytes.get(name_at).is_some_and(u8::is_ascii_alphabetic) {
            // Not a tag. A comment's (or `<![CDATA[`'s) content is not
            // markup either.
            if rest.starts_with("!--") {
                at = input[name_at..]
                    .find("-->")
                    .map_or(input.len(), |i| name_at + i + 3);
            } else if foreign > 0 && rest.starts_with("![CDATA[") {
                at = input[name_at..]
                    .find("]]>")
                    .map_or(input.len(), |i| name_at + i + 3);
            }
            continue;
        }
        let name_len = bytes[name_at..]
            .iter()
            .position(|b| b.is_ascii_whitespace() || matches!(b, b'/' | b'>'))
            .unwrap_or(bytes.len() - name_at);
        let name = &input[name_at..name_at + name_len];
        let Some(after) = tag_end(bytes, name_at + name_len) else {
            break;
        };
        at = after;
        let mut drop_tag = false;
        if end_tag {
            let reach = open.len().saturating_sub(END_TAG_REACH);
            let found = open[reach..]
                .iter()
                .rposition(|o| o.name.eq_ignore_ascii_case(name))
                .map(|i| reach + i);
            let innermost = found.is_some_and(|i| i + 1 == open.len());
            let closes = match found {
                None => false,
                Some(_) if innermost => true,
                // A dropped element further out: only its tag goes.
                Some(i) if open[i].dropped => {
                    open.remove(i);
                    drop_tag = true;
                    false
                }
                Some(i) => {
                    !names(FORMATTING_ELEMENTS, name)
                        && !open[i + 1..].iter().any(|o| names(SCOPE_ELEMENTS, o.name))
                }
            };
            if let (true, Some(i)) = (closes, found) {
                drop_tag = open[i].dropped;
                for closed in open.drain(i..) {
                    depth -= usize::from(!closed.dropped);
                    foreign -= usize::from(names(&["svg", "math"], closed.name));
                }
            }
        } else if foreign == 0 && names(RAW_TEXT_ELEMENTS, name) {
            // Skip its text: tags in there are not tags.
            let lower_end = format!("</{}", name.to_ascii_lowercase());
            let mut search = after;
            at = loop {
                let Some(pos) = find_ignore_ascii_case(&input[search..], &lower_end) else {
                    break input.len();
                };
                let end = search + pos + lower_end.len();
                if ends_tag_name(bytes.get(end)) {
                    break tag_end(bytes, end).unwrap_or(input.len());
                }
                search = end;
            };
            if name.eq_ignore_ascii_case("plaintext") {
                at = input.len();
            }
        } else if names(VOID_ELEMENTS, name)
            || names(SELF_CLOSING_ELEMENTS, name)
            || (foreign > 0 && input[..after].ends_with("/>"))
        {
            // Opens nothing that stays open.
        } else {
            drop_tag = depth >= limit;
            depth += usize::from(!drop_tag);
            foreign += usize::from(names(&["svg", "math"], name));
            open.push(Open {
                name,
                dropped: drop_tag,
            });
        }
        if drop_tag {
            let out = out.get_or_insert_with(|| String::with_capacity(input.len()));
            out.push_str(&input[copied..tag]);
            copied = after;
        }
    }
    match out {
        Some(mut out) => {
            out.push_str(&input[copied..]);
            Cow::Owned(out)
        }
        None => Cow::Borrowed(input),
    }
}

/// `needle` (lowercase ASCII) in `haystack`, compared without case.
fn find_ignore_ascii_case(haystack: &str, needle: &str) -> Option<usize> {
    let (h, n) = (haystack.as_bytes(), needle.as_bytes());
    if n.is_empty() || h.len() < n.len() {
        return None;
    }
    let first = n[0];
    (0..=h.len() - n.len()).find(|&i| {
        h[i].to_ascii_lowercase() == first
            && h[i..i + n.len()]
                .iter()
                .zip(n)
                .all(|(a, b)| a.to_ascii_lowercase() == *b)
    })
}

/// A full document's `<body …>` start tag as a `<div …>`: a fragment has
/// no body, and the parser would drop the tag and with it the mail's own
/// `style`, `class` and `dir`. The `<div>` is then sanitized like any
/// other, and stays open to the end as the body did. Only the tag's name
/// changes, so whatever the tag really was (text inside a comment, say),
/// the input means the same as before.
fn body_as_div(input: &str) -> Cow<'_, str> {
    let lower = input.to_ascii_lowercase();
    let mut from = 0;
    while let Some(at) = next_tag(&lower, "<body", from) {
        from = at + 5;
        // Only a tag that carries attributes is worth keeping.
        if lower
            .as_bytes()
            .get(from)
            .is_some_and(u8::is_ascii_whitespace)
        {
            return Cow::Owned(format!("{}<div{}", &input[..at], &input[from..]));
        }
    }
    Cow::Borrowed(input)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The attribute value of the first `name="…"` in `html`, entities
    /// decoded (`&amp;` is how HTML writes `&` inside an attribute).
    fn attribute(html: &str, name: &str) -> Option<String> {
        let start = html.find(&format!(" {name}=\""))? + name.len() + 3;
        let end = start + html[start..].find('"')?;
        Some(
            html[start..end]
                .replace("&quot;", "\"")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&amp;", "&"),
        )
    }

    #[test]
    fn links_stay_clickable_with_their_exact_url() {
        for url in [
            "https://example.com/path?a=1&b=2#frag",
            "http://example.com/",
            "mailto:a@b.c?subject=x",
            "https://example.com/a%20b/?q=%C3%A9&utm_source=news&redirect=https%3A%2F%2Fx.y%2F#top",
            "tel:+421900123456",
            "HTTPS://EXAMPLE.COM/Path",
        ] {
            let out = html(&format!(r#"<a href="{url}">go</a>"#));
            assert_eq!(attribute(&out, "href").as_deref(), Some(url), "{out}");
            assert!(out.contains(">go</a>"), "{out}");
        }
        // Written the way HTML asks for (`&amp;`), it is the same link.
        let out = html(r#"<a href="https://example.com/?a=1&amp;b=2">go</a>"#);
        assert_eq!(
            attribute(&out, "href").as_deref(),
            Some("https://example.com/?a=1&b=2")
        );
        // The serialized form: only `&` is rewritten, as `&amp;`.
        assert_eq!(
            html(r#"<a href="https://example.com/path?a=1&b=2#frag">go</a>"#),
            r#"<a href="https://example.com/path?a=1&amp;b=2#frag" rel="noopener noreferrer">go</a>"#
        );
        // A link inside the mail keeps working too.
        assert!(html(r##"<a href="#details">more</a>"##).contains(r##"href="#details""##));
    }

    #[test]
    fn a_link_loses_its_script_not_itself() {
        let out = html(
            r#"<a href="https://example.com/x" onclick="steal()" onmouseover="x()" target="_blank">go</a>"#,
        );
        assert_eq!(
            out,
            r#"<a href="https://example.com/x" rel="noopener noreferrer">go</a>"#
        );

        for bad in [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "  javascript:alert(1)",
            "java\tscript:alert(1)",
            "vbscript:msgbox(1)",
            "data:text/html,<script>alert(1)</script>",
            "data:image/png;base64,AAAA",
            "cid:part1@x",
            "file:///etc/passwd",
            "ftp://example.com/x",
        ] {
            let out = html(&format!(r#"<a href="{bad}">go</a>"#));
            assert!(!out.contains("href"), "{bad}: {out}");
            assert!(out.contains(">go</a>"), "the text stays: {out}");
        }
    }

    #[test]
    fn what_can_run_or_submit_is_gone() {
        let out = html(concat!(
            "<p>before</p>",
            "<script>alert('s')</script>",
            "<iframe src=\"https://evil.example/\">frame text</iframe>",
            "<form action=\"https://evil.example/\"><input name=\"q\" value=\"v\">",
            "<button>Press</button><textarea>typed</textarea>",
            "<select><option>pick</option></select><span>kept in form</span></form>",
            "<meta http-equiv=\"refresh\" content=\"0;url=https://evil.example/\">",
            "<base href=\"https://evil.example/\">",
            "<link rel=\"stylesheet\" href=\"https://evil.example/x.css\">",
            "<object data=\"x.swf\"><param name=\"a\" value=\"b\">fallback</object>",
            "<embed src=\"x.swf\"><applet code=\"X\">applet text</applet>",
            "<svg><script>alert(1)</script><text>drawn</text></svg>",
            "<math><mi>x</mi></math>",
            "<noscript><img src=\"https://evil.example/px\"></noscript>",
            "<img src=\"https://example.com/a.png\" onerror=\"alert(1)\" onload=\"x()\">",
            "<div onclick=\"x()\" onmouseenter=\"y()\">div</div>",
            "<p>after</p>",
        ));
        assert_eq!(
            out,
            concat!(
                "<p>before</p>",
                "<span>kept in form</span>",
                "<img src=\"https://example.com/a.png\">",
                "<div>div</div>",
                "<p>after</p>",
            )
        );
    }

    #[test]
    fn a_full_document_comes_out_as_its_content_without_the_title() {
        let out = html(concat!(
            "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">",
            "<title>Your order has shipped</title></head>",
            "<body class=\"mail\" dir=\"ltr\" style=\"margin:0;background-color:#f4f4f4\" ",
            "onload=\"x()\"><p>Hello</p></body></html>",
        ));
        assert_eq!(
            out,
            concat!(
                "<div class=\"mail\" dir=\"ltr\" style=\"margin:0;background-color:#f4f4f4\">",
                "<p>Hello</p></div>",
            )
        );
        // A body tag with nothing to carry is not wrapped.
        assert_eq!(html("<html><body><p>Hi</p></body></html>"), "<p>Hi</p>");
    }

    #[test]
    fn pictures_keep_cid_and_image_data_addresses() {
        let out = html(concat!(
            "<img src=\"cid:abc@x\" alt=\"logo\" width=\"120\" height=\"40\">",
            "<img src=\"data:image/png;base64,iVBORw0KGgo=\">",
            "<img src=\"https://example.com/a.png?x=1&y=2\">",
        ));
        // Byte for byte: the shell finds inline parts by `src="cid:…"`.
        assert!(out.contains(r#"src="cid:abc@x""#), "{out}");
        assert!(out.contains(r#"alt="logo""#) && out.contains(r#"width="120""#));
        assert!(
            out.contains(r#"src="data:image/png;base64,iVBORw0KGgo=""#),
            "{out}"
        );
        assert!(out.contains(r#"src="https://example.com/a.png?x=1&amp;y=2""#));

        // `data:` that is not a picture is a page in disguise.
        for bad in [
            "data:text/html,<script>alert(1)</script>",
            "data:text/html;base64,PHNjcmlwdD4=",
            " data:TEXT/html,x",
            "javascript:alert(1)",
            "file:///x.png",
        ] {
            let out = html(&format!(r#"<img src="{bad}" alt="a">"#));
            assert_eq!(out, r#"<img alt="a">"#, "{bad}");
        }
        // And nothing but a picture may use it.
        assert!(!html(r#"<a href="data:text/html,x">x</a>"#).contains("data:"));
        assert!(!html(r#"<td background="data:text/html,x">x</td>"#).contains("data:"));
    }

    #[test]
    fn mail_layout_survives() {
        let input = concat!(
            "<center><table width=\"600\" height=\"80\" align=\"center\" bgcolor=\"#ffffff\" ",
            "border=\"0\" cellpadding=\"0\" cellspacing=\"0\" role=\"presentation\" ",
            "background=\"https://example.com/bg.png\" style=\"border-collapse:collapse\">",
            "<tbody><tr bgcolor=\"#eeeeee\"><td colspan=\"2\" rowspan=\"1\" valign=\"top\" ",
            "align=\"left\" width=\"50%\" class=\"cell\" id=\"main\">",
            "<font color=\"#333333\" face=\"Arial\" size=\"2\">Text</font></td></tr></tbody>",
            "</table></center>",
            "<div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">On Mon wrote:</div>",
            "<blockquote class=\"gmail_quote\" style=\"margin:0 0 0 .8ex;border-left:1px solid ",
            "#ccc;padding-left:1ex\">quoted</blockquote></div>",
            "<div id=\"mail-editor-reference-message-container\"><blockquote type=\"cite\">",
            "older</blockquote></div>",
            "<h1 align=\"center\" lang=\"en\" title=\"t\">Head</h1><ul><li>one</li></ul>",
            "<hr><pre>code</pre><p>line<br>break</p>",
        );
        // Everything in it is allowed: it comes out as it went in.
        assert_eq!(html(input), input);
    }

    #[test]
    fn inline_styles_stay_as_written_minus_what_is_not_layout() {
        let style = |css: &str| {
            let out = html(&format!(r#"<p style="{css}">x</p>"#));
            attribute(&out, "style")
        };
        // Nested functions, `!important`, quoted names, vendor and Outlook
        // properties: all as written (ammonia's own filter broke these).
        for css in [
            "color:#FF0000 !important",
            "font-family:'Helvetica Neue', Arial, sans-serif",
            "background-image:linear-gradient(to right, #fff 0%, rgba(0,0,0,.5) 100%)",
            "width:calc(100% - 20px);max-width:600px",
            "background:url(https://example.com/a.png?x=1&y=2) no-repeat",
            "background:url('cid:bg@x')",
            "background:url(data:image/gif;base64,R0lGOD)",
            "mso-line-height-rule:exactly;-webkit-text-size-adjust:100%",
            "font:bold 12px/1.5 Arial;margin:0 auto;display:none",
            "background-position:center top;z-index:2",
        ] {
            assert_eq!(style(css).as_deref(), Some(css), "{css}");
        }
        // Spacing is tidied, empty declarations go.
        assert_eq!(
            style("color : red ;; ; FONT-SIZE:12PX;").as_deref(),
            Some("color:red;FONT-SIZE:12PX")
        );
        // What draws over other content or ran script, goes — alone.
        assert_eq!(
            style("color:red;position:fixed;top:0;POSITION : absolute").as_deref(),
            Some("color:red;top:0")
        );
        for (css, kept) in [
            ("width:expression(alert(1));color:red", "color:red"),
            ("width:e\\78pression(alert(1));color:red", "color:red"),
            ("width:exp/**/ression(alert(1));color:red", "color:red"),
            ("background:url(javascript:alert(1));color:red", "color:red"),
            (
                "background:url( 'java\\0a script:x' );color:red",
                "color:red",
            ),
            ("background:url(data:text/html,x);color:red", "color:red"),
            ("behavior:url(x.htc);color:red", "color:red"),
            ("-moz-binding:url(x.xml#y);color:red", "color:red"),
            ("color:red;not a declaration;margin:0", "color:red;margin:0"),
            // An unclosed value would swallow what follows: it goes.
            ("color:red;background:url(x;margin:0", "color:red"),
        ] {
            assert_eq!(style(css).as_deref(), Some(kept), "{css}");
        }
        // Nothing left, no attribute.
        assert_eq!(html(r#"<p style="position:fixed">x</p>"#), "<p>x</p>");
    }

    #[test]
    fn style_blocks_are_kept_as_raw_scrubbed_text() {
        let out = html(concat!(
            "<html><head><style type=\"text/css\">\n",
            "@import url(\"https://evil.example/x.css\");\n",
            "/* a comment */\n",
            "body, .wrap > td { margin:0; font-family:\"Helvetica Neue\", Arial }\n",
            "@media (prefers-color-scheme: dark) { .wrap { background:#000 !important } }\n",
            "@media only screen and (max-width:600px) { .col { width:100% !important } }\n",
            ".hero { background:url(https://example.com/hero.png) }\n",
            "</style></head><body><p class=\"wrap\">Hi</p></body></html>",
        ));
        assert!(out.starts_with("<style>"), "{out}");
        assert!(out.ends_with("</style><p class=\"wrap\">Hi</p>"), "{out}");
        // Raw text: quotes and `>` are not turned into entities.
        assert!(
            out.contains("body, .wrap > td { margin:0; font-family:\"Helvetica Neue\", Arial }")
        );
        assert!(out.contains(
            "@media (prefers-color-scheme: dark) { .wrap { background:#000 !important } }"
        ));
        assert!(out.contains("(max-width:600px) { .col { width:100% !important } }"));
        assert!(out.contains(".hero { background:url(https://example.com/hero.png) }"));
        assert!(
            !out.contains("@import") && !out.contains("evil.example"),
            "{out}"
        );
        assert!(!out.contains("a comment"));
    }

    #[test]
    fn style_blocks_cannot_carry_script_or_markup() {
        // Closing the element early: what follows is markup, and is
        // sanitized as markup.
        let out = html("<style>p{color:red}</style><script>alert(1)</script><p>x</p>");
        assert_eq!(out, "<style>p{color:red}</style><p>x</p>");
        let out = html("<style>a{}</style ><img src=x onerror=alert(1)><style>b{}</style>");
        assert_eq!(out, "<style>a{}</style><style>b{}</style><img src=\"x\">");

        // Script-era CSS is renamed into nothing a browser knows.
        let scrubbed = scrub_stylesheet(
            "a{width:expression(alert(1));behavior:url(x.htc);-moz-binding:url(x);\
             background:url(javascript:alert(1));position:fixed}\
             .position:hover{background-position:0 0}",
        );
        assert_eq!(
            scrubbed,
            "a{width:x-expression(alert(1));x-behavior:url(x.htc);x--moz-binding:url(x);\
             background:url(x-javascript:alert(1));x-position:fixed}\
             .position:hover{background-position:0 0}"
        );
        // Hidden behind escapes, the whole sheet goes.
        assert_eq!(scrub_stylesheet("a{width:e\\78pression(alert(1))}"), "");
        assert_eq!(scrub_stylesheet("@\\69mport 'x';a{color:red}"), "");
        assert_eq!(scrub_stylesheet("a{pos\\69tion:fixed}"), "");
        // Imports go however they end.
        assert_eq!(
            scrub_stylesheet("@import 'a.css';p{}@IMPORT url(b.css) screen;q{}").trim(),
            "p{} q{}"
        );
        assert_eq!(scrub_stylesheet("p{} @import 'a.css'").trim(), "p{}");
        // The old comment wrapper goes; nothing tag-like is left.
        assert_eq!(
            scrub_stylesheet("<!-- p{color:red} -->").trim(),
            "p{color:red}"
        );
        let scrubbed = scrub_stylesheet("p{content:\"</style><script>x</script>\"} q{}");
        assert!(!scrubbed.to_lowercase().contains("</style"), "{scrubbed}");
        assert!(!scrubbed.contains("<s"), "{scrubbed}");
        // A range query's `<` is not a tag.
        assert_eq!(
            scrub_stylesheet("@media (width < 600px){p{margin:0}}"),
            "@media (width < 600px){p{margin:0}}"
        );
    }

    /// A newsletter the way they come: a full document, a style block,
    /// nested layout tables, a tracking pixel, a hidden preheader, an
    /// Outlook conditional comment, links with tracking parameters.
    fn newsletter() -> String {
        let row = concat!(
            "<tr><td class=\"col\" width=\"50%\" valign=\"top\" style=\"padding:12px 24px;",
            "font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:15px;",
            "line-height:22px;color:#333333\">",
            "<h2 style=\"margin:0 0 8px;font-size:18px\">Autumn picks №{n}</h2>",
            "<p style=\"margin:0 0 12px\">Hand-finished wool, back in stock &amp; ",
            "shipping this week — <b>20&nbsp;% off</b> until Sunday.</p>",
            "<a href=\"https://shop.example/c/{n}?utm_source=news&utm_medium=email&id=a%2Fb#sizes\" ",
            "style=\"display:inline-block;padding:10px 18px;background-color:#1a73e8;",
            "color:#ffffff;text-decoration:none;border-radius:4px\" target=\"_blank\" ",
            "onclick=\"track({n})\">Shop now</a></td>",
            "<td class=\"col\" width=\"50%\"><img src=\"https://cdn.example/img/{n}.jpg\" ",
            "width=\"280\" height=\"180\" alt=\"Wool scarf {n}\" border=\"0\" ",
            "style=\"display:block;max-width:100%;height:auto\"></td></tr>",
        );
        let mut rows = String::new();
        for n in 0..40 {
            rows.push_str(&row.replace("{n}", &n.to_string()));
        }
        format!(
            concat!(
                "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\">",
                "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head>",
                "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">",
                "<meta name=\"viewport\" content=\"width=device-width\">",
                "<title>Autumn picks from Example Shop</title>",
                "<style type=\"text/css\">\n",
                "@import url(https://fonts.example/css?family=Inter);\n",
                "body {{ margin:0; padding:0; background-color:#f4f4f4 }}\n",
                "table {{ border-collapse:collapse }}\n",
                "@media only screen and (max-width:600px) {{ .col {{ display:block !important; ",
                "width:100% !important }} }}\n",
                "@media (prefers-color-scheme: dark) {{ body, .card {{ background:#111 !important; ",
                "color:#eee !important }} }}\n",
                "</style>",
                "<!--[if mso]><style>.col {{ width:300px }}</style><![endif]-->",
                "</head><body bgcolor=\"#f4f4f4\" style=\"margin:0;padding:0\">",
                "<div style=\"display:none;max-height:0;overflow:hidden\">Back in stock this week</div>",
                "<table role=\"presentation\" width=\"100%\" bgcolor=\"#f4f4f4\" border=\"0\" ",
                "cellpadding=\"0\" cellspacing=\"0\"><tr><td align=\"center\">",
                "<table class=\"card\" width=\"600\" bgcolor=\"#ffffff\" border=\"0\" ",
                "cellpadding=\"0\" cellspacing=\"0\" style=\"max-width:600px\">",
                "<tr><td colspan=\"2\" align=\"center\" style=\"padding:24px\">",
                "<img src=\"cid:logo@shop.example\" width=\"140\" alt=\"Example Shop\"></td></tr>",
                "{rows}",
                "<tr><td colspan=\"2\" style=\"padding:24px;font-size:12px;color:#888888\">",
                "You get this because you signed up at example.shop. ",
                "<a href=\"https://shop.example/unsubscribe?u=42&t=abc\">Unsubscribe</a> · ",
                "<a href=\"mailto:help@shop.example?subject=Question\">Write to us</a></td></tr>",
                "</table></td></tr></table>",
                "<img src=\"https://track.example/open?u=42\" width=\"1\" height=\"1\" alt=\"\">",
                "<script>document.location='https://evil.example/'</script>",
                "</body></html>",
            ),
            rows = rows
        )
    }

    /// The text a reader sees: tags out, entities decoded, spacing
    /// collapsed. (Good enough for markup that is already sanitized, or
    /// that this test wrote.)
    fn visible_text(html: &str) -> String {
        let mut text = String::new();
        let mut in_tag = false;
        for c in html.chars() {
            match c {
                '<' => in_tag = true,
                '>' if in_tag => {
                    in_tag = false;
                    text.push(' ');
                }
                c if !in_tag => text.push(c),
                _ => {}
            }
        }
        text.replace("&nbsp;", "\u{a0}")
            .replace("&amp;", "&")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    }

    #[test]
    fn a_newsletter_keeps_its_text_layout_and_links() {
        let input = newsletter();
        let out = html(&input);

        // What a reader sees is what the sender wrote, minus the title
        // (a browser tab's, not the mail's) and the script.
        let body = &input[input.find("<body").unwrap()..];
        let written = visible_text(&body.replace(
            "<script>document.location='https://evil.example/'</script>",
            "",
        ));
        let shown = visible_text(&out[out.find("</style>").unwrap() + 8..]);
        assert_eq!(shown, written);
        assert!(shown.contains("Autumn picks №7"));
        assert!(shown.contains("shipping this week — 20 % off until Sunday."));
        assert!(!out.contains("Autumn picks from Example Shop"), "the title");

        // Layout: the tables, their attributes and inline styles.
        assert_eq!(
            out.matches("<table").count(),
            input.matches("<table").count()
        );
        assert_eq!(out.matches("<td").count(), input.matches("<td").count());
        assert!(out.contains(
            "<table class=\"card\" width=\"600\" bgcolor=\"#ffffff\" border=\"0\" \
             cellpadding=\"0\" cellspacing=\"0\" style=\"max-width:600px\">"
        ));
        assert!(
            out.contains("font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:15px")
        );
        // The body's own attributes, on the div that stands in for it.
        assert!(out.contains("<div bgcolor=\"#f4f4f4\" style=\"margin:0;padding:0\">"));
        // The style block, without its import; the one written for
        // Outlook alone (in a conditional comment) is not ours to apply.
        assert!(out.starts_with("<style>"));
        assert!(out.contains("@media (prefers-color-scheme: dark)"));
        assert!(!out.contains("@import") && !out.contains("fonts.example"));
        assert_eq!(out.matches("<style>").count(), 1);
        assert!(!out.contains("300px"));

        // Every link, exactly, and still a link.
        assert_eq!(out.matches("<a href=").count(), 42);
        assert!(out.contains(
            "<a href=\"https://shop.example/c/7?utm_source=news&amp;utm_medium=email&amp;id=a%2Fb#sizes\""
        ));
        assert!(out.contains("<a href=\"https://shop.example/unsubscribe?u=42&amp;t=abc\""));
        assert!(out.contains("<a href=\"mailto:help@shop.example?subject=Question\""));
        // Pictures: inline part, remote ones (the shell decides on those).
        assert!(out.contains("src=\"cid:logo@shop.example\""));
        assert!(out.contains("src=\"https://cdn.example/img/7.jpg\""));
        // Nothing that runs.
        let lower = out.to_lowercase();
        assert!(!lower.contains("<script") && !lower.contains("onclick"));
        assert!(!lower.contains("evil.example") && !lower.contains("<meta"));
    }

    #[test]
    fn sanitizing_twice_changes_nothing() {
        let samples = [
            newsletter(),
            "<p>plain</p>".to_string(),
            "just text & an ampersand < a bracket".to_string(),
            "<html><head><title>T</title><style>p{color:red}</style></head>\
             <body class=\"b\" style=\"margin:0\"><p style=\"color : red ; position:fixed\">x</p>"
                .to_string(),
            "<p title=\"<body class=x> <style>y</style> </style>\">attr</p>".to_string(),
            "<style>a{width:expression(1);position:fixed} <body x> </style><i>i</i>".to_string(),
            "<style><!-- p{} --></style><style>@import 'x';</style><b>b</b>".to_string(),
            "<div style=\"background:url(&quot;https://x.y/a.png&quot;);font-family:&quot;A B&quot;\">d</div>"
                .to_string(),
            "<table><tr><td>cell<td>cell 2<p>unclosed<a href=\"https://x.y/?a=1&b=2\">l"
                .to_string(),
            "<svg><style>x</style><a href=\"javascript:1\">s</a></svg><textarea><style>t</style>"
                .to_string(),
            "<!-- <style>c{}</style> --><plaintext><style>p{}</style>".to_string(),
            "<!--[if mso]><body class=o><style>o{}</style><![endif]--><body class=b><p>x".to_string(),
            "<!-- never closed <style>c{}</style><body class=b>".to_string(),
            "<pre>\n\nfirst line after two breaks</pre><pre>\nx</pre>".to_string(),
            "text\r\nwith\rold\nline breaks &nbsp;&copy;&#8212;&unknown; and a nul \0".to_string(),
            "<p>caf\u{e9} \u{1f600} <b>\u{202e}rtl</b></p><a href=\"https://x.y/\u{e9}?q=\u{1f600}\">u</a>"
                .to_string(),
            "<table><tr><td>cell</td></tr><p>fostered</p><caption>c</caption></table>".to_string(),
            "<a href=\"https://a.b\"><a href=\"https://c.d\">nested links</a></a>".to_string(),
            "<b><i>mis<p>nested</b> formatting</i></p>".to_string(),
            format!("{}deep", "<div>".repeat(600)),
            format!("{}x", "<b><div></b>".repeat(400)),
            format!("{}x", "<div><table><tr><td>".repeat(300)),
            format!("{}x{}", "<blockquote><span>".repeat(300), "</span>".repeat(300)),
        ];
        for sample in samples {
            let once = html(&sample);
            let twice = html(&once);
            assert_eq!(twice, once, "input: {sample}");
        }
    }

    /// The start tags of sanitized markup, outside its `<style>` blocks.
    /// (In what the sanitizer writes, `<` and `>` inside text and
    /// attribute values are entities, so the brackets left are tags'.)
    fn start_tags(out: &str) -> Vec<String> {
        let mut rest = out;
        let mut markup = String::new();
        while let Some(start) = rest.find("<style>") {
            markup.push_str(&rest[..start]);
            let after = &rest[start..];
            rest = &after[after.find("</style>").map_or(after.len(), |end| end + 8)..];
        }
        markup.push_str(rest);
        markup
            .split('<')
            .skip(1)
            .filter(|t| !t.starts_with('/'))
            .map(|t| t.split('>').next().unwrap_or("").to_lowercase())
            .collect()
    }

    /// Markup written to get script past a sanitizer: parser quirks,
    /// namespace switches, raw-text elements, obfuscated schemes. Whatever
    /// each turns into, it is made of allowed tags only, with no handler
    /// and no script URL, and a second pass finds nothing more to remove.
    #[test]
    fn hostile_markup_comes_out_inert() {
        let vectors = [
            "<img src=x onerror=alert(1)>",
            "<img src=x onerror=alert(1)//",
            "<IMG SRC=\"javascript:alert(1)\" OnLoad=alert(1)>",
            "<a href=\"jav&#x09;ascript:alert(1)\">x</a>",
            "<a href=\"&#106;avascript:alert(1)\">x</a>",
            "<a href=\"javascript&colon;alert(1)\">x</a>",
            "<a href=\" &#14; javascript:alert(1)\">x</a>",
            "<a href=\"data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==\">x</a>",
            "<body onload=alert(1) class=x><p>b</p>",
            "<svg onload=alert(1)><script>alert(1)</script><a xlink:href=\"javascript:1\">s</a>",
            "<svg><style><img src=x onerror=alert(1)></style></svg>",
            "<svg><iframe><a title=\"</iframe><img src onerror=alert(1)>\">test",
            "<math><mtext><table><mglyph><style><img src=x onerror=alert(1)>",
            "<form><math><mtext></form><form><mglyph><style></math><img src onerror=alert(1)>",
            "<noscript><p title=\"</noscript><img src=x onerror=alert(1)>\">",
            "<select><template><style><!--</style><a rel=\"--></style></template></select>\
             <img id=x src onerror=alert(1)>\">",
            "<style></style><img src=x onerror=alert(1)>",
            "<style><!--</style><img src=x onerror=alert(1)>--></style>",
            "<style>a{background:url(\"</style><script>alert(1)</script>\")}</style>",
            "<style>*{}</style\t><script>alert(1)</script>",
            "<STYLE>a{}</STYLE ><SCRIPT SRC=//evil.example/x.js></SCRIPT>",
            "<style>@import'//evil.example/x.css';a{behavior:url(x.htc)}</style>",
            "<style>a{width:expr/**/ession(alert(1))}</style><p>p</p>",
            "<title><img src=x onerror=alert(1)></title>",
            "<textarea><img src=x onerror=alert(1)></textarea>",
            "<xmp><img src=x onerror=alert(1)></xmp>",
            "<plaintext><img src=x onerror=alert(1)>",
            "<iframe srcdoc=\"<script>alert(1)</script>\"></iframe>",
            "<object data=\"javascript:alert(1)\"></object><embed src=\"javascript:alert(1)\">",
            "<meta http-equiv=refresh content=\"0;url=javascript:alert(1)\">",
            "<base href=\"javascript:alert(1)//\"><a href=\"x\">rel</a>",
            "<link rel=stylesheet href=\"javascript:alert(1)\">",
            "<form action=\"javascript:alert(1)\"><input type=submit formaction=\"javascript:1\">",
            "<button onclick=alert(1) formaction=\"javascript:1\">b</button>",
            "<div style=\"width:expression(alert(1))\">d</div>",
            "<div style=\"background:url('javascript:alert(1)')\">d</div>",
            "<div style=\"position:fixed;top:0;left:0;width:100%;height:100%\">overlay</div>",
            "<table background=\"javascript:alert(1)\"><tr><td background=\"vbscript:x\">c",
            "<img src=\"data:image/svg+xml;base64,AAAA\" onerror=\"x\">",
            "<a href=\"https://example.com\" onclick=\"x\" style=\"behavior:url(x)\">ok</a>",
            "<p title=\"</p><script>alert(1)</script>\" class=\"\"><script>x</script>\">t</p>",
            "<!--><script>alert(1)</script>-->",
            "<!--[if mso]><script>alert(1)</script><![endif]--><p>after</p>",
            "<? xml version=\"1.0\" ?><p>pi</p><![CDATA[<script>alert(1)</script>]]>",
        ];
        for vector in vectors {
            let out = html(vector);
            for tag in start_tags(&out) {
                let name = tag.split(|c: char| c.is_whitespace()).next().unwrap_or("");
                assert!(
                    TAGS.contains(&name) || name == "style",
                    "`{name}` survived in `{out}` from `{vector}`"
                );
                assert!(
                    !tag.split_whitespace().skip(1).any(|a| a.starts_with("on")),
                    "a handler survived in `{out}` from `{vector}`"
                );
                for bad in [
                    "javascript:",
                    "vbscript:",
                    "data:text",
                    "srcdoc",
                    "formaction",
                ] {
                    assert!(!tag.contains(bad), "`{bad}` in `{out}` from `{vector}`");
                }
            }
            for bad in ["expression(alert", "@import", "<script", "position:fixed"] {
                let lower = out.to_lowercase().replace("x-expression", "");
                assert!(!lower.contains(bad), "`{bad}` in `{out}` from `{vector}`");
            }
            assert_eq!(html(&out), out, "second pass changed `{vector}`");
        }
    }

    /// Input built to make a careless scan go over the same text again
    /// and again: each of these is read in one pass. (No clock here — a
    /// scan that is not linear makes this test take minutes, which is the
    /// failure.)
    #[test]
    fn pathological_input_is_read_once() {
        let comments = format!(
            "{}<style>p{{}}</style><p>end</p>",
            "<!-- c -->".repeat(50_000)
        );
        assert_eq!(html(&comments), "<style>p{}</style><p>end</p>");
        let swallowed = "<!-- <style>a{}</style> <body x> -->".repeat(20_000);
        assert_eq!(html(&swallowed), "");
        let imports = format!("<style>{}p{{}}</style>", "@import 'x';".repeat(50_000));
        assert_eq!(
            html(&imports).trim_start_matches("<style>").trim(),
            "p{}</style>"
        );
        let unclosed = format!("{}<p>x</p>", "<style".repeat(50_000));
        assert!(html(&unclosed).len() < 64);
        let renames = format!("<style>a{{{}}}</style>", "position:fixed;".repeat(50_000));
        assert_eq!(html(&renames).matches("x-position:fixed").count(), 50_000);
        let nested = format!("{}deep{}", "<div>".repeat(20_000), "</div>".repeat(20_000));
        assert!(html(&nested).contains("deep"));
        let declarations = format!("<p style=\"{}\">x</p>", "color:red;".repeat(50_000));
        assert!(html(&declarations).contains("color:red;color:red"));
    }

    #[test]
    fn preformatted_text_keeps_its_first_blank_line() {
        // A parser drops the first line break in `<pre>`: to show one
        // blank line, the markup needs two — before and after.
        assert_eq!(html("<pre>\n\ncode</pre>"), "<pre>\n\ncode</pre>");
        assert_eq!(html("<pre>\ncode</pre>"), "<pre>code</pre>");
        assert_eq!(
            html("<pre class=\"x\">\n\n\na</pre><p>\nb</p>"),
            "<pre class=\"x\">\n\n\na</pre><p>\nb</p>"
        );
    }

    #[test]
    fn tracking_pixels_become_markers_and_pictures_stay() {
        let pixels = [
            r#"<img src="https://track.example/open?u=42&c=7" width="1" height="1" alt="">"#,
            r#"<img src="http://track.example/o.gif" width="0" height="0">"#,
            r#"<img src="https://track.example/o.gif" height="2" width="2px" border="0">"#,
            r#"<img src="https://track.example/o" style="width:1px;height:1px">"#,
            r#"<img src="https://track.example/o" style="WIDTH: 1px !important; HEIGHT: 0">"#,
            r#"<img src="https://track.example/o" width="1" style="height:1px">"#,
            r#"<img src="https://track.example/o" style="max-width:1px;max-height:1px">"#,
            r#"<img src="https://track.example/o" width="600" height="400" style="width:1px;height:1px">"#,
            r#"<img src="https://track.example/o" style="display:none">"#,
            r#"<img src="https://track.example/o" style="display: none !important" width="50">"#,
            r#"<img src="https://track.example/o" style="visibility:hidden">"#,
            r#"<IMG SRC="HTTPS://TRACK.EXAMPLE/O" WIDTH=1 HEIGHT=1>"#,
            // Capped at a pixel, whatever the width asks for.
            r#"<img src="https://track.example/o" style="width:100%;max-width:1px;height:1px">"#,
            r#"<img src="https://track.example/o" style="max-width:1px;width:100%" height="1">"#,
            // A name of the app's is no name: it is gone before this looks.
            r#"<img src="https://track.example/o" width="1" height="1" class="hp-keep">"#,
        ];
        for pixel in pixels {
            let out = html(&format!("<p>before</p>{pixel}<p>after</p>"));
            assert_eq!(
                unsealed(&out),
                format!("<p>before</p>{TRACKER_MARKER}<p>after</p>"),
                "{pixel}"
            );
        }

        let pictures = [
            // Seen: any size that is not tiny both ways.
            r#"<img src="https://cdn.example/hero.jpg" width="600" height="300">"#,
            r#"<img src="https://cdn.example/rule.gif" width="1" height="600">"#,
            r#"<img src="https://cdn.example/spacer.gif" width="20" height="1">"#,
            r#"<img src="https://cdn.example/a.png" width="1">"#,
            r#"<img src="https://cdn.example/a.png" style="width:100%;height:auto">"#,
            r#"<img src="https://cdn.example/a.png" width="1%" height="1%">"#,
            r#"<img src="https://cdn.example/a.png">"#,
            // Hidden until a style sheet shows it on a narrow screen.
            r#"<img src="https://cdn.example/mobile.png" class="mobile-only" style="display:none">"#,
            r#"<img src="https://cdn.example/mobile.png" id="m" style="display:none">"#,
            // Tiny by its attributes, but a style sheet can name it and
            // say otherwise…
            r#"<img src="https://cdn.example/logo.png" width="0" height="0" class="logo">"#,
            r#"<img src="https://cdn.example/logo.png" width="1" height="1" id="logo">"#,
            r#"<img src="https://cdn.example/logo.png" class="logo" style="width:1px;height:1px">"#,
            // …or its own style does: that is the size it is shown at.
            r#"<img src="https://cdn.example/banner.png" width="1" height="1" style="width:100%">"#,
            r#"<img src="https://cdn.example/banner.png" width="1" height="1" style="height:auto">"#,
            r#"<img src="https://cdn.example/banner.png" width="1" height="1" style="width:2em;height:2em">"#,
            r#"<img src="https://cdn.example/banner.png" width="1" height="1" style="width:300px">"#,
            r#"<img src="https://cdn.example/banner.png" style="max-width:100%" width="1" height="600">"#,
            // Part of the mail: nothing is loaded from anywhere.
            r#"<img src="cid:pixel@x" width="1" height="1">"#,
            r#"<img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" width="1" height="1">"#,
            r#"<img src="cid:logo@x" style="display:none">"#,
            // Not addressed to the web at all.
            r#"<img src="spacer.gif" width="1" height="1">"#,
            r#"<img width="1" height="1" alt="">"#,
        ];
        for picture in pictures {
            let out = html(picture);
            assert_eq!(out, picture, "left as it is");
            assert!(!out.contains("hp-tracker"));
        }
    }

    #[test]
    fn trackers_are_counted_once_however_often_the_body_is_sanitized() {
        let input = newsletter();
        let once = html(&input);
        assert_eq!(once.matches(TRACKER_MARKER).count(), 1);
        assert!(!once.contains("track.example"));
        // The pictures that show are all still there.
        assert_eq!(once.matches("<img ").count(), 41);
        let twice = html(&once);
        assert_eq!(twice, once);
        assert_eq!(twice.matches("hp-tracker").count(), 1);
        assert_eq!(html(&twice), once);
    }

    /// Mail cannot bring the app's names in: a class or an id beginning
    /// `hp-` goes, whatever its case and whatever stands next to it, and
    /// with it every way of writing a marker.
    #[test]
    fn names_beginning_hp_are_taken_from_mail() {
        assert_eq!(
            html(r#"<p class="lead hp-tracker  HP-LinkWarn note">x</p>"#),
            r#"<p class="lead note">x</p>"#
        );
        assert_eq!(html(r#"<p class="hp-linkwarn">x</p>"#), "<p>x</p>");
        assert_eq!(
            html("<p class=\"a\thp-x\nb\">x</p>"),
            r#"<p class="a b">x</p>"#
        );
        assert_eq!(
            html(r##"<a id="hp-linkwarn" href="#x">x</a>"##)
                .matches("id=")
                .count(),
            0
        );
        assert_eq!(html(r#"<p id=" Hp-1 ">x</p>"#), "<p>x</p>");
        // Other names are the sender's to use, also ones that look alike.
        for kept in [
            r#"<p class="php-code chp-1 hp">x</p>"#,
            r#"<p id="php-code">x</p>"#,
            r#"<p class="hp_tracker">x</p>"#,
        ] {
            assert_eq!(html(kept), kept);
        }
        // A document's own body is mail too.
        let document = html(r#"<html><body class="hp-tracker wide"><p>x</p></body></html>"#);
        assert_eq!(document, r#"<div class="wide"><p>x</p></div>"#);

        // A marker written by the sender — as this module writes it, or
        // any other way — counts for nothing.
        let forged = [
            TRACKER_MARKER.to_string(),
            format!("<p>hi</p>{TRACKER_MARKER}{TRACKER_MARKER}"),
            r#"<span class='hp-tracker' style='display:none'></span>"#.to_string(),
            r#"<SPAN CLASS="HP-TRACKER"></SPAN>"#.to_string(),
            r#"<div class="x hp-tracker"><span class="hp-tracker"></span></div>"#.to_string(),
        ];
        for mail in forged {
            let out = html(&mail);
            assert_eq!(out.matches("hp-").count(), 0, "{mail}: {out}");
            assert_eq!(html(&out), out);
        }
        // Where mail may say the words — its text, an attribute's value,
        // a style sheet — they are words: never the marker's bytes, which
        // is what gets counted.
        let quoted = [
            format!("<style>{TRACKER_MARKER}</style><p>hi</p>"),
            format!("<!--{TRACKER_MARKER}--><p title='{TRACKER_MARKER}'>{TRACKER_MARKER}</p>"),
            format!("<textarea>{TRACKER_MARKER}</textarea><xmp>{TRACKER_MARKER}</xmp>"),
            format!("<a href='https://x.example/{TRACKER_MARKER}'>x</a>"),
        ];
        for mail in quoted {
            let out = html(&mail);
            assert_eq!(out.matches(TRACKER_MARKER).count(), 0, "{mail}: {out}");
            assert_eq!(unsealed(&out), out, "nothing to seal: {mail}");
            assert_eq!(html(&out), out);
        }
        // Next to a real tracker, the forged ones still count for nothing.
        let pixel = r#"<img src="https://track.example/o" width="1" height="1">"#;
        let out = html(&format!("{TRACKER_MARKER}{pixel}{TRACKER_MARKER}"));
        assert_eq!(out.matches("hp-tracker").count(), 1);
        assert_eq!(out.matches(TRACKER_MARKER).count(), 1);
    }

    /// A body with markers ends in a seal, and that is what a second pass
    /// goes by: this install's output comes back as it is, and anything
    /// else that ends like one — a made-up seal, a real one moved to
    /// another body, a sealed body that was changed — is mail.
    #[test]
    fn only_a_sealed_body_keeps_its_markers_on_a_second_pass() {
        let pixel = r#"<img src="https://track.example/o" width="1" height="1">"#;
        let once = html(&format!("<p>one</p>{pixel}{pixel}"));
        let (body, digits) = split_seal(&once).expect("sealed");
        assert_eq!(body, format!("<p>one</p>{TRACKER_MARKER}{TRACKER_MARKER}"));
        assert_eq!(unsealed(&once), body);
        assert_eq!(digits.len(), 32);
        assert!(digits.bytes().all(|b| b.is_ascii_hexdigit()));
        assert_eq!(once.matches("hp-").count(), 3, "two markers and the seal");
        // The same body gets the same seal; another body another.
        assert_eq!(html(&format!("<p>one</p>{pixel}{pixel}")), once);
        let other = html(&format!("<p>two</p>{pixel}{pixel}"));
        assert_ne!(split_seal(&other).unwrap().1, digits);

        // Again and again: unchanged.
        assert_eq!(html(&once), once);
        assert_eq!(html(&html(&once)), once);

        // Without its seal it is mail that happens to hold markers.
        assert_eq!(
            html(body),
            "<p>one</p><span style=\"display:none\"></span><span style=\"display:none\"></span>"
        );
        let mail = [
            // a seal that was never made
            format!("{body}<!--hp-seal:{}-->", "0".repeat(32)),
            format!("{body}<!--hp-seal:{}-->", "f".repeat(32)),
            // this body's seal on more markers than it was made for
            format!("{body}{TRACKER_MARKER}<!--hp-seal:{digits}-->"),
            format!("{TRACKER_MARKER}{once}"),
            // another body's seal
            format!("{body}<!--hp-seal:{}-->", split_seal(&other).unwrap().1),
            // the right seal, not at the end, or not quite itself
            format!("{once}<p>ps</p>"),
            format!("{once} "),
            format!("{body}<!--hp-seal:{}-->", digits.to_uppercase()),
            format!("{body}<!-- hp-seal:{digits}-->"),
            format!("{body}<!--hp-seal:{digits}é-->"),
        ];
        for input in mail {
            let out = html(&input);
            assert_eq!(out.matches("hp-").count(), 0, "{input}: {out}");
            assert_eq!(html(&out), out);
        }
        // Mail that carries a tracker of its own beside forged markers and
        // a forged seal: one marker, and the seal is this function's.
        let out = html(&format!("{body}{pixel}<!--hp-seal:{}-->", "0".repeat(32)));
        assert_eq!(out.matches(TRACKER_MARKER).count(), 1);
        assert_eq!(out.matches("hp-seal:").count(), 1);
        assert_eq!(html(&out), out);
    }

    /// RFC 4231, test case 2.
    #[test]
    fn the_seals_hash_is_hmac_sha256() {
        let mac = hmac_sha256(b"Jefe", b"what do ya want for nothing?");
        let hex: String = mac.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(
            hex,
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
        let key = [7u8; 32];
        assert_eq!(seal_digits(&key, "x"), seal_digits(&key, "x"));
        assert_ne!(seal_digits(&key, "x"), seal_digits(&[8u8; 32], "x"));
        assert_ne!(seal_digits(&key, "x"), seal_digits(&key, "y"));
    }

    #[test]
    fn a_body_too_large_to_parse_comes_out_as_its_text() {
        let unit = concat!(
            "<tr><td onclick=\"steal()\"><p>Row &amp; column &copy; 2 < 3 & more</p>",
            "<a href=\"javascript:alert(1)\">link text</a><br>next line",
            "<script>alert('never shown')</script><style>p{color:red}</style>",
            "<img src=\"https://track.example/o\" width=\"1\" height=\"1\"></td></tr>\n",
        );
        let mut input = String::from("<html><head><title>Title</title></head><body><table>");
        while input.len() <= MAX_INPUT_BYTES {
            input.push_str(unit);
        }
        input.push_str("</table><p>The end.</p></body></html>");

        let out = html(&input);
        // Only the wrapper and line breaks are markup.
        assert!(
            out.starts_with("<div>Row &amp; column © 2 &lt; 3 &amp; more<br>"),
            "{}",
            &out[..120]
        );
        assert!(
            out.ends_with("<br>The end.</div>"),
            "{}",
            &out[out.len() - 80..]
        );
        let tags: Vec<&str> = out
            .split('<')
            .skip(1)
            .map(|t| &t[..t.find('>').unwrap_or(0)])
            .collect();
        assert!(tags.iter().all(|t| matches!(*t, "div" | "/div" | "br")));
        for gone in [
            "never shown",
            "color:red",
            "Title",
            "javascript",
            "onclick",
            "track.example",
        ] {
            assert!(!out.contains(gone), "{gone}");
        }
        assert!(out.contains("link text<br>next line"));
        // Far smaller than what came in, and stable.
        assert!(out.len() < input.len() / 2);
        assert_eq!(html(&out), out);

        // Text alone can be too large as well: it is escaped, not parsed,
        // and a second pass leaves it as it is.
        let text = "words & <b>bold</b> ".repeat(MAX_INPUT_BYTES / 16);
        let out = oversized_as_text(&text);
        assert!(out.len() > MAX_INPUT_BYTES);
        assert!(out.starts_with("<div>words &amp; bold words &amp; bold"));
        assert!(!out[5..out.len() - 6].contains('<'));
        assert_eq!(oversized_as_text(&out), out);
        assert_eq!(html(&out), out);

        // Just under the bound: parsed as usual.
        assert_eq!(html("<p onclick=\"x()\">small</p>"), "<p>small</p>");
    }

    #[test]
    fn nesting_is_capped_and_the_content_stays() {
        let opened = |html: &str, tag: &str| html.matches(&format!("<{tag}")).count();

        // Deeper than the cap: the innermost wrappers go, in pairs.
        let deep = format!("{}text{}", "<div>".repeat(2_000), "</div>".repeat(2_000));
        let capped = cap_nesting(&deep, 256);
        assert_eq!(opened(&capped, "div"), 256);
        assert_eq!(capped.matches("</div>").count(), 256);
        assert!(capped.contains("<div>text</div>"));
        assert!(html(&deep).contains("<div>text</div>"));

        // Ways to go deep that a count of start and end tags would miss:
        // end tags that close nothing, formatting elements closed out of
        // order, end tags stopped by a table cell, a quote where no value
        // starts, a slash that closes nothing in HTML.
        for (unit, tag) in [
            ("<div></span>", "div"),
            ("<b><div></b>", "div"),
            ("<div><table><tr><td></div>", "table"),
            ("<div \">", "div"),
            ("<div/>", "div"),
            ("<span><p>", "span"),
            ("<li><center>", "center"),
            ("<svg><title><div>", "div"),
        ] {
            let input = unit.repeat(5_000);
            let capped = cap_nesting(&input, 256);
            assert!(
                opened(&capped, tag) <= 256,
                "{unit}: {}",
                opened(&capped, tag)
            );
            // And the parse of what is left is quick (see the module docs).
            let _ = html(&input);
        }

        // What is not nesting is left alone: paragraphs, list items and
        // table rows nobody closed, void elements, self-closed drawing
        // elements, and tag-shaped text in comments, raw text and
        // attribute values.
        let untouched = [
            "<p>one".repeat(3_000),
            format!("<ul>{}</ul>", "<li>item".repeat(3_000)),
            format!("<table>{}</table>", "<tr><td>a<td>b".repeat(3_000)),
            "line<br><img src=\"a.png\"><hr>".repeat(3_000),
            format!("<svg>{}</svg>", "<path d=\"M0 0\"/>".repeat(3_000)),
            format!("<!-- {} --><p>x</p>", "<div>".repeat(3_000)),
            format!("<style>{}</style><p>x</p>", "<div>".repeat(3_000)),
            format!("<script>{}</script><p>x</p>", "'<div>'+".repeat(3_000)),
            format!("<p title=\"{}\">x</p>", "<div>".repeat(3_000)),
            format!("<textarea>{}</textarea>", "<div>".repeat(3_000)),
            newsletter(),
        ];
        for input in untouched {
            assert!(
                matches!(cap_nesting(&input, 256), Cow::Borrowed(_)),
                "{}…",
                &input[..40]
            );
        }
    }

    #[test]
    fn url_schemes_are_read_the_way_a_browser_reads_them() {
        assert_eq!(url_scheme("https://x.y").as_deref(), Some("https"));
        assert_eq!(
            url_scheme(" \n JavaScript:x").as_deref(),
            Some("javascript")
        );
        assert_eq!(
            url_scheme("java\tscr\nipt:x").as_deref(),
            Some("javascript")
        );
        assert_eq!(url_scheme("mailto:a@b.c").as_deref(), Some("mailto"));
        assert_eq!(url_scheme("#top"), None);
        assert_eq!(url_scheme("/path?x=a:b"), None);
        assert_eq!(url_scheme("image.png"), None);
        assert_eq!(url_scheme("1http://x"), None);
        assert_eq!(url_scheme("//host/path"), None);
    }

    /// Not a test of behaviour: prints what one pass over a
    /// newsletter-sized body costs. Run it optimized:
    /// `cargo test --release -p heypigeon-core sanitize::tests::cost -- --ignored --nocapture`
    #[test]
    #[ignore = "a measurement, not a check"]
    fn cost_of_a_newsletter_sized_body() {
        let mut input = newsletter();
        let filler = input.clone();
        while input.len() < 150_000 {
            input.push_str(&filler);
        }
        let _ = html(&input); // builds the policy once
        let runs = 50;
        let started = std::time::Instant::now();
        let mut out_len = 0;
        for _ in 0..runs {
            out_len = html(&input).len();
        }
        let each = started.elapsed() / runs;
        println!(
            "sanitize: {} KB in, {} KB out, {:.2} ms per pass",
            input.len() / 1024,
            out_len / 1024,
            each.as_secs_f64() * 1000.0
        );
    }
}
