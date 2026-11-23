# A message's Advanced menu

Status: Implemented — not yet in a PR; `ios-ci` and `macos-ci` have not run on it
Related: `DESIGN.md` (Rendering untrusted mail), `docs/ios.md` (Thread),
`docs/specs/marker-look.md` (the sheet's look)

## What and why

"It would be good to have advance options for email, and one would be to
copy the original html code of the email." Every message gets an
**Advanced** submenu with three items: **Copy original HTML** (the HTML
exactly as it was sent — the app itself keeps only a sanitized copy),
**Copy plain text**, and **Show headers** (From, To, Reply-To,
Message-ID, the date and the rest, in a sheet with a copy button). It is
for the moments a mail has to be looked at as what it is: a template to
debug, a sender to check, a message to report.

**Out of scope:** showing or rendering the original HTML anywhere in the
app; the raw RFC 822 message with its attachments (`.eml`); saving to a
file; "Show original" in a browser; any setting; drafts that are not
synced to Gmail yet.

## Behaviour

Copy original HTML

- R1. The action asks Gmail for the message again, when the user picks
  it and only then (`messages.get`, `format=full`: one request, with the
  account's existing grant; a second one for the part's data when Gmail
  hands a long part over separately). Nothing of the answer is stored,
  cached or logged.
- R2. Offline, nothing is asked and nothing is copied; the toast says
  "You're offline. The original HTML is fetched from Gmail, so nothing
  was copied."
- R3. The message's HTML part goes to the clipboard as text, exactly as
  Gmail returns it — transfer encoding undone, nothing else changed: not
  sanitized, scripts, trackers and the sender's own markup included. The
  part is the one the reader shows. The toast says "HTML copied". The
  HTML is never handed to a view.
- R4. A message with no HTML part: "This email has no HTML, only plain
  text. Nothing was copied." A part over 8 MB (`source::MAX_HTML_BYTES`)
  is not copied, whole or cut: "This email's HTML is too large to copy".
- R5. Any failure (Gmail unreachable, the message gone, the account
  disconnected) copies nothing — the clipboard keeps what it held — and
  the toast says why: "Couldn't fetch the original HTML: …". A fetch
  that takes longer than 0.7 s says "Fetching the original from Gmail…"
  meanwhile; a second ask for the same message while one is running is
  ignored.

Copy plain text

- R6. Local and instant, online or not: the message's text part as the
  device stores it; for a message that came as HTML alone, the text of
  its stored (sanitized) HTML as the core reads it (`source::plain_text`:
  a line per block, an empty line between paragraphs, list items as
  `- `, links as their words); failing both, its snippet. The toast says
  "Text copied", or "This email has no text to copy".

Show headers

- R7. A sheet, "Headers", with the thread's subject under the title. It
  opens at once and fetches the message's original headers with the same
  request as R1 (the store keeps only a few of them, and not as sent).
  Nothing is stored: the headers are on the model while the sheet is
  open. Offline it says so and asks nothing; a failure is shown with
  "Try again".
- R8. The sheet lists the headers in two groups: **Main** — From, To, Cc,
  Bcc, Reply-To, Subject, Date, Message-ID, In-Reply-To, References, in
  that order, those the message has — then **All other headers** in the
  order they were sent. A value is shown whole and can be selected.
- R9. **Copy all** copies every header as `Name: value`, one per line, in
  the order the message was sent with, and says "Copied" in place (a
  toast would be under the sheet).

Everywhere

- R10. The menu is on every message of a thread, the user's own sent
  messages included: in the open message's ••• and on a long press
  (right-click) of its header line, after Reply · Reply all · Forward.
- R11. Two accounts: the request is made with the account the thread
  belongs to. A message the store does not hold in that thread is
  refused before Gmail is asked.
- R12. Nothing here changes mail, so there is no Undo and nothing to
  sync.

## Where it lives

| Layer | What goes here |
| --- | --- |
| Core (`desktop-app/crates/core`, adapters) | `core::source`: `MessageSource`, `SourceHtml` (`Sent` / `Missing` / `TooLarge`, the 8 MB cap), `plain_text`; port `MailProvider::fetch_source` (default: not supported; fake in `fakes.rs`); `adapter-gmail`: `fetch_source` (`format=full`, the reader's HTML part, undecoded beyond base64). No schema change |
| Bridge (`crates/ffi`, `RustEngine`, `MockEngine`) | `Engine::message_source(thread_id, message_id)`, records `MessageSource` / `MailHeader` / `SourceHtml`, free function `plain_text_of_html`; `MailEngine.originalMessage` → `OriginalMessage` / `HeaderLine` / `OriginalHTML`; `MailHTML.plainText`; `MockEngine.originalMessage` with `originals`, `originalFailure`, `originalRequests` |
| Shared shell (`ios-app/HeyPigeon`) | `Features/Thread/MessageAdvanced.swift`: the words, the pure rules (`plainText(of:)`, `sections`, `text`), `AppModel.advanced(_:on:in:)`, `advanced(_:onLatestOf:)`, `copyOriginalHTML`, `copyPlainText`, `showHeaders`, `loadHeaders`, `copyHeaders`, `MessageAdvancedMenu`; `MessageHeadersSheet.swift`; `AppModel.headersSheet` presented by `SharedSheets`; the menu in `ThreadView`'s `MessageRow` |
| iPhone / iPad only | — |
| Mac only (`macos-app/HeyPigeonMac`) | `MailCommand.advanced`, `WindowState.run`, the Message menu's Advanced submenu, three palette entries |

Syncs between devices: no.

Leaves the device: one Gmail API request for that message (two for a
very long HTML part), to Google, with the account's existing grant and
scope — the same kind of request that opens a thread. Nothing new goes
anywhere else, and no privacy sentence in the app changes. What is new
is on the device: unsanitized HTML reaches the clipboard, on the user's
explicit action and only there; other apps can read the clipboard, as
with anything copied.

Why `format=full` and not `format=raw`: `raw` is the whole RFC 822
message, attachments included (tens of megabytes for one copy), and
would need a MIME parser in the core. `full` returns every header and
each part with only its transfer encoding undone, without the
attachments, and is the request the reader already makes.

## Platform matrix

| | iPhone | iPad | Mac |
| --- | --- | --- | --- |
| Surface | the thread; toast; Headers sheet | the same | the same (thread page, thread window, an email on the Bundles page) |
| Entry points | open message's ••• › Advanced; long press on a message's header line › Advanced | the same (right-click with a pointer) | the same ••• and right-click; Message › Advanced in the menu bar; palette: "Copy original HTML", "Copy plain text", "Show headers" |
| Settings | none | none | none |
| Status | Implemented | Implemented | Implemented |

## Platform differences

- The Mac's menu bar and palette entries act on the **latest message** of
  the open or highlighted email (they name an email, not a message); any
  other message is reached through its own •••, as on the phone. The
  phone and the iPad have no menu bar or palette.
- The menu bar writes the items in title case ("Copy Original HTML"), as
  every item beside them.
- No bare key on the Mac: these are rare actions, and the map is full.

## Acceptance criteria

- [x] R3, R4 (core) — `source::tests::html_is_kept_missing_or_too_large`;
  `adapter-gmail` `source_is_the_html_part_as_sent_with_every_header`,
  `source_html_of_single_part_and_plain_mail`
- [x] R6 (core) — `source::tests::plain_text_*`; ffi
  `plain_text_of_html_is_the_cores`
- [x] R11 — ffi `message_source_refuses_what_the_store_does_not_hold`
- [x] Port default and fake — `the_fake_provider_hands_over_a_messages_source`
- [ ] R1–R5 (shell) — `MessageAdvancedModelTests` (written; needs `ios-ci`)
- [ ] R6–R9 (shell) — `MessageAdvancedRuleTests`, `MessageAdvancedModelTests`
- [ ] Mac entry points — `MessageAdvancedMacTests` (needs `macos-ci`)
- [x] Same wording and symbol on every platform (one enum:
  `MessageAdvancedAction`)
- [x] `MockEngine` covers the new operation
- [x] `rust-ci` commands green locally · [ ] `ios-ci` · [ ] `macos-ci`
- [x] Guides updated (`DESIGN.md`, `ios-app/CLAUDE.md`, `macos-app/CLAUDE.md`);
  privacy copy checked, unchanged

## Open questions / assumptions

- "Exactly as sent" is the HTML part as Gmail's API returns it: the
  bytes of the part with base64 / quoted-printable undone. A part in a
  legacy charset that Gmail does not hand over as UTF-8 is copied with
  replacement characters, as the reader shows it. The byte-exact message
  would be `format=raw` (see above) — say so if that is what is wanted.
- The cap is 8 MB, twice what the reader parses. Assumed.
- Show headers uses the on-demand fetch only; there is no offline
  fallback built from the stored fields (they are already on the open
  message: sender, recipients, date, where replies go).
- Copy plain text does not fetch: for HTML-only mail the text is derived
  from the sanitized body, so it lacks link addresses and may include
  text the sender hid with CSS.
- No iOS App Intent or Shortcut for these. Assumed not wanted.
- On the Mac a thread in its own window presents the Headers sheet on
  the main window, as Remind me does there today (existing behaviour of
  the shared sheets, not changed here).

## Verification

2026-11-23, by the architect, on the working tree (not committed).

```
Spec: docs/specs/message-advanced.md   Verdict: Not verified (Swift not compiled)

Rules           R1 adapter-gmail fetch_source · R2–R5 MessageAdvanced.swift copyOriginalHTML ·
                R6 core/src/source.rs plain_text, MessageAdvanced.plainText · R7–R9 loadHeaders,
                MessageHeadersSheet, sections/text · R10 ThreadView MessageRow.menuItems ·
                R11 ffi Engine::message_source
Parity          iPhone / iPad / Mac share one menu, one model path and one sheet; the Mac's
                extra entry points are listed above
Layering        rules in core and in static functions; views only call AppModel
Tests / CI      rust: fmt + the rust-ci test command green locally · ios-ci not run · macos-ci not run
Not checked     anything Swift (no compiler here); the live Gmail request (unit-tested on wire JSON only)
```
