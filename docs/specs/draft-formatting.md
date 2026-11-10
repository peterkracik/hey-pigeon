# Draft and forward formatting

Status: Implemented — #120, and the follow-up that added R5–R6
Related: `docs/ios.md` (Compose), `macos-app/README.md`

## What and why

A message's formatting survives being saved as a draft and reopened, and
a forward on the Mac keeps the formatting of the mail it forwards. A
reopened draft used to lose its bold and links and was then sent as
plain text.

**Out of scope:** inline pictures in a draft or a forward (they travel as
attachments); a rich forward on the phone.

## Behaviour

- R1. A saved draft's html part reaches the composer with the draft.
  Sending it sends that formatting.
- R2. The phone's editor reads back bold, italic, underline,
  strikethrough, links to web and mail addresses, line breaks and
  paragraphs. A draft with anything else (a list, another editor's
  blocks) opens as its plain text, and saving it from the phone then
  saves plain text.
- R3. The Mac's editor loads the draft's html whole.
- R4. Html on its way into a composer loses its `<style>` blocks and its
  `cid:` pictures (`ComposerHTML.clean`): a style block would apply to
  the editor's own page, and the picture comes back as an attachment
  without a Content-ID.
- R5. The Mac's editor page runs only its own script (a nonce in its
  content security policy); a handler inside loaded content does not
  run. The core's sanitizer is the first layer, this the second.
- R6. A forward carries the account's signature over the quoted header
  (From, Date, Subject, To) and the message's attachments up to the
  size one message may carry. On the Mac the forwarded message keeps
  its html under that header; pictures from the web in it are not
  loaded in the editor and are sent as the original had them.

## Where it lives

| Layer | What goes here |
| --- | --- |
| Core (`desktop-app/crates/core`, adapters) | a draft's html is sanitized where it enters (`to_draft`) |
| Bridge (`crates/ffi`, `RustEngine`, `MockEngine`) | `RustEngine.draft()` passes `bodyHTML`, cleaned (R4) |
| Shared shell (`ios-app/HeyPigeon`) | `ComposerHTML`, `SendDraft.forward`, `AppModel.forwardDraft`, `ComposeView.richBody`, `RichText` |
| iPhone / iPad only | `RichText.attributed(html:)` (R2) |
| Mac only | `MacComposeEditor`, `HTMLEditorView.document` (R3, R5), the html of a forward (R6) |

Syncs between devices: the draft itself, through Gmail.
Leaves the device: nothing new.

## Platform matrix

| | iPhone | iPad | Mac |
| --- | --- | --- | --- |
| Surface | composer sheet | same | inline composer or window |
| Entry points | Drafts, "Continue draft", Forward | same | same, `f` |
| Settings | none | none | none |
| Status | Implemented | Implemented | Implemented |

## Platform differences

- R2 / R3: the phone's editor is a text editor over an attributed string
  and can hold only the formatting it writes; the Mac's is an html
  editor. A draft with richer html keeps it on the Mac and opens as
  plain text on the phone.
- R6: the phone forwards the message's text; the Mac its html.

## Acceptance criteria

- [x] R2 — `aSavedDraftsHTMLReadsBackIntoTheEditor` (`ModelTests`)
- [x] R4 — `replyGoesWhereTheSenderAskedAndNeverToTheUsersOwnAlias`
  (the `ComposerHTML.clean` case)
- [x] R5 — `thePagesOwnScriptRunsAndHandlersInTheContentDoNot`
  (`EditorPageTests`, Mac)
- [x] R6 (text, signature) — `forwardQuotesTheMessageUnderOneFwd`
- [ ] R1, R3, R6 (attachments, the Mac's html) — no test; read from the code
- [x] `rust-ci`, `ios-ci`, `macos-ci` green

## Open questions / assumptions

- A forwarded newsletter's web pictures show as missing in the Mac's
  editor while writing (the page loads nothing from the web) and arrive
  intact. Assumed acceptable; not yet looked at on a Mac.

## Verification

Not yet verified on a device. Tests and CI only.
