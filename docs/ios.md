# Hey Pigeon for iOS — design

Companion to [DESIGN.md](../DESIGN.md). That document's iOS section planned to
ship the Svelte app through Tauri's iOS target; this one revises that decision
and specifies what the phone app is. The desktop principles still hold: no
backend, local-first, all logic in the Rust core, the UI is a projection.

## Decision: native SwiftUI shell, shared Rust core

**The iOS app is a native SwiftUI app. It does not render a web view of the
Svelte UI. It links the same Rust crates the desktop app uses
(`core`, `adapter-gmail`, `adapter-sqlite`, later `adapter-openai` /
`adapter-jev`) through a UniFFI bridge crate, `crates/ffi`.**

```text
┌──────────── desktop (today) ────────────┐   ┌──────────── iOS ────────────┐
│ src-tauri (Rust wiring) ◄─IPC─► Svelte  │   │ SwiftUI app ◄─UniFFI─► ffi  │
└───────────────┬─────────────────────────┘   └──────────────┬──────────────┘
                │                                            │
                ▼                                            ▼
     crates/core · adapter-gmail · adapter-sqlite · adapter-openai · adapter-jev
                              (shared, unchanged)
```

### Why not Tauri iOS

The original plan was tempting because it promised one UI codebase. On
inspection it would not have delivered that:

- **The desktop UI is desktop-shaped.** `App.svelte` is a 2,500-line
  keyboard controller around a sidebar, a rail, a resizable column and a
  command palette. It has one media query. A phone UI with swipes, a
  navigation stack, sheets and a bottom toolbar is a new view layer whichever
  technology renders it — so the "shared UI" saving is close to zero.
- **The feel is the product.** DESIGN.md's whole thesis is that every action
  must be instant and native-feeling. In a WKWebView, swipe-to-archive,
  rubber-banding, large-title navigation, context-menu previews, haptics,
  Dynamic Type, keyboard avoidance and the share sheet are all things to
  reimplement or bridge through plugins. In SwiftUI they are the default.
- **iOS integration is where the real work is anyway.** OAuth through
  `ASWebAuthenticationSession`, Keychain, `BGAppRefreshTask`, local
  notifications, Quick Look for attachments, a future widget or share
  extension: every one of these is a native API. Tauri would add a plugin
  layer between us and each of them.
- **The part worth sharing is shareable without Tauri.** The sync engine,
  the outbox, FTS search, the Drive sync map, the Gmail adapter and the
  sanitizer are all plain Rust. UniFFI turns them into a Swift module with
  `async throws` functions. That is the door the ports-and-adapters design
  kept open, and it is a better door than a web view.

Costs we accept: a second UI to maintain (small, phone-sized), a Rust
cross-compile step in the Xcode build, and Swift as a second language in the
repo. Tauri stays the desktop shell; nothing about the Mac app changes.

### Architecture rule that comes out of this

`src-tauri/src/mail.rs` and `crates/ffi/src/engine.rs` are now two thin
wiring layers over the same core. Anything either one grows that is not
shell-specific (sync orchestration, connection state, reminder due logic)
belongs in `core`, not duplicated. Today the two share ~60 lines of glue
(connect flow, delta round, devsync status); lifting that into a
`core::engine` module is the first refactor to do once the phone app is
daily-drivable, not before.

## UX

**One idea, same as desktop: an inbox that feels like an elegant todo list.**
Archiving is checking something off. The keyboard map becomes a gesture map.

### Information architecture

Superhuman's phone layout is the reference: no title, two glass circles on
top, the list starts immediately, a drawer for folders and accounts, and a
floating "splits" pill above the tab bar. Here that maps to:

```text
┌──────────────────────────────────────────────────────────┐
│ (≡)                                                  (✦) │  ← sidebar · AI (when connected)
│ ● Sender                                          10:42  │
│   Subject                                                │
│   two lines of snippet…                                  │
│ ─────────────────────────────────────────────────────────│
│   …                                                      │
│        ( Inbox 2 · Invoices · Travel · Newsletters )     │  ← Jev label pill (Settings › Triage)
│   (  Inbox  ·  Remind me  ·  Need reply  )   (✎)        │  ← tab bar + compose
└──────────────────────────────────────────────────────────┘
```

- **Tabs = the rail.** Inbox, Remind me (reminders) and Need reply are the
  tab bar. Search is not in it (it was the system's separate search
  circle beside the bar): see **Search** below. Inbox carries an
  unread badge, Remind me the number of reminders due today, Need reply its
  count. The app icon badge is unified unread + reminders due today.
- **The sidebar (≡)** is the desktop sidebar as a sheet: Search, Inbox, then the
  accounts (All / each account) in a group of their own — a disconnected
  one with a Reconnect row under it — then Recent Opens (with read
  status in the build), the bundles, the desktop's folders in
  its order — Pinned (Gmail's Starred) · Sent · Drafts · Archive · Remind me · Need reply ·
  All emails · Spam · Trash — the Gmail labels and Settings. An account
  is added in Settings › Accounts.
  Picking a folder shows it in the Inbox tab.
- **The label pill** above the tab bar is the desktop's label tabs under the
  folder title: the folder (no filter), then the **Jev triage labels** from
  Settings › Triage. One tap narrows the list to that label. Gmail labels
  stay in the sidebar. Accounts (desktop `0`/`1`/`2`) switch in the sidebar,
  under Inbox, and the choice applies across all tabs.
- **Groups** are the desktop's: Pinned (when "Pinned list" is on) · Today ·
  Last 7 days · Older. Remind me buckets by due date; Need reply has no
  Pinned group.
- **Rows:** flat, edge to edge, on the paper, a hairline between two.
  Unread is the sender in bold under the pink highlighter; a read sender
  steps back to grey. In the unified view the account is a small dot in
  its colour before the time — no avatar.
- **The title** sits between the top bar's circles: folder, unread count and —
  with more than one account — the account's dot and name. Tapping it
  switches account (All · each).
- **Search** is not on screen until it is asked for: a short pull down
  on any of the three lists, let go, opens it (`PullDown`: 44–110 pt),
  and a longer pull is the system's refresh. The field is the search
  pane's own (`shownSearch`), not the list's: the navigation bar's
  drawer left on the list showed it at the top of every list. With the
  search up the list gives way to the field, the filter buttons, the
  recent searches and the results (`SearchPane`); the tab bar keeps the
  list's tab (`AppModel.listTab`), and Cancel or any tab goes back
  (`closeSearch`), the words and filters cleared. A result opens on the
  list's own stack, so back returns to the results. The way in without
  the gesture is the first row of the sidebar (≡ › Search), and for
  VoiceOver a "Search" action on the title; Spotlight's "Search in Hey
  Pigeon" lands in the same place. All of them set `tab = .search`, as
  on the iPad, where Search is a sidebar row and `/`.
- **Compose** is the glass circle beside the tab bar, under the thumb
  (where the search circle was). The system draws that circle only for
  a search-role tab, so it is one, with a pencil: choosing it opens the
  composer and the bar's selection stays on the list (`RootView.tabs`,
  `BarSlot`). ⌘N is a key equivalent on the same screen.
- **The AI** is the top-right circle, with a provider connected: a
  sparkle that summarizes the current view (folder ·
  label filter · account) in a sheet. When "Ask my inbox" is there too,
  the one sparkle is a menu of the two (`MailListScreen.aiBarItem`), so
  the top bar never holds more than the sidebar, the title and one circle.
  A thread has the summary sparkle in its top bar.
- **Triage labels** appear on rows as words (`#Travel`), not as a filter
  bar (the priority is in the thread's header line); a priority filter can
  join the account pill later.
- **The thread view hides the tab bar** and shows two floating glass bars in
  its place: Reply (+ new message), and the triage actions.

### The parcel card

Over the plain inbox (no search, no label filter), above Pinned: parcels
that are on their way, as a group of its own under the title "Parcels"
— it is not mail, and should not read as a row (`ParcelCardView`,
`docs/specs/parcel-card.md`). Collapsed it is the first parcel and
"+N more"; the X at the end of the title's rule dismisses them all, with
Undo.

```text
 PARCELS ──────────────────────────────────── ✕
 ┌──┐ Merino crew-neck jumper, navy + 1 more
 │🛍│ Expected tomorrow · www.dhl.com · 2 updates
 └──┘ (Track parcel)  View details          ⋯
 ──────────────────────────────────────────────
 ⌄ +1 more
```

It is drawn as the list around it is, and "card" is only its name: no
box and no fill around the group, the bundle's icon in an outlined
square, the host in the mono, Track parcel an outlined capsule (the
inbox's one ink action is Compose) and View details plain text.

The bundle's icon stands where Gmail shows the product: a picture would
be a request to the shop from the inbox. Status, day and title are the
core's, read from the mail (`core::parcels`); a row never says more than
an email did, and its second line always names the host Track parcel
opens — the link's own, never a carrier's name or the sender's. A bundle with a parcel here has no folded row — its quiet
mail is counted on the parcel's line. The same view is the first row of
the Mac window's list.

### Rows

Three lines on the paper, a hairline between two rows, no cards and no
avatar — and a fourth line (the bundle, up to two Jev labels as words)
only when there is something to say (`ThreadRowView`; the rules of the
look are [specs/marker-look.md](./specs/marker-look.md)):

```text
 Sender name  3                              ⏰ ● 10:42
 Subject line                        ✦ Need reply  📎
 First line of the snippet…
 ✈ Lisbon trip   #Travel
```

- Unread is the sender in bold under the highlighter (`marker()`: a pink
  band behind the lower part of the name), the subject in semibold and
  the time in ink. A read row's sender is medium weight in the secondary
  grey and its time tertiary. There is no bar on the row's edge and no
  dot for unread. In the unified view the account is a 6 pt dot in its
  colour before the time.
  VoiceOver reads the row's state as its value (`ThreadRow.spokenState`:
  Unread, Reminder, Need reply, Pinned, Done, Has attachment).
- The sender is Instrument Sans at 16 pt (`Theme.sender`), the subject 15,
  one line of snippet at 14 in the tertiary grey; the time, the message
  count and the labels are DM Mono. All of it scales with Dynamic Type,
  and the time never gives way to a long name.
- Reminder, need-reply, pin and done marks sit before the time, each a
  glyph in its state's colour (the pin in ink); the AI's suggestion (a
  sparkle and its words in the AI's pink, `StateMark`), a "Draft" mark and
  the attachment clip sit at the end of the subject line, only when
  present. Nothing on a row is a filled chip: a state is writing, a label
  a word (`TagText`).
- A group is titled by `SectionTitle`: its name in small mono capitals, a
  rule to the row's end and how many rows it holds, all in the light grey
  of structure (Pinned · Today · Last 7 days · Older); Remind me has its
  due buckets (Overdue · Today · Tomorrow · This week · Later).
- A done email listed in its bundle steps back to the tertiary grey with
  its subject and preview struck through, and so does a row while a swipe
  is about to mark it done; anywhere else a done thread has a mint check
  before its time.
- Pagination is keyset (`before = last row's last_msg_at`), 50 rows a page.
  Scheduled and Need reply are bounded lists and come back whole (never
  paged). The loaded rows never hold a thread twice, whatever the engine
  returns: SwiftUI's `List` aborts the process on duplicate row ids. A
  reload re-reads the pages already on screen, off the main thread, and
  replaces the rows only when they changed, so a sync landing mid-scroll
  neither cuts the list back to one page nor redraws it.

### Platform floor: iOS 27

The deployment target is **iOS 27** (`ios-app/project.yml`,
`HeyPigeonCore/Package.swift`, and `publish-ios.yml` archives against the
iOS 27 SDK on GitHub's `xcode-27` runner image — the `macos-26` image stops
at Xcode 26.6 / iOS 26.5). The app is installed on one phone, so the floor moves with the
phone instead of gating every call with `#available`. What iOS 27 buys is
the intelligence layer in [ios-intelligence.md](./ios-intelligence.md): the
`.mail.thread` schema and View Annotations for Siri, `SpotlightSearchTool`
for "Ask my inbox", Private Cloud Compute and pluggable `LanguageModel`
providers for Foundation Models, image input and the Vision tools, long-
running intents, `SyncableEntity` and notification entity identifiers.

### Liquid Glass (iOS 26)

The app uses the system's Liquid Glass surfaces (iOS 26+) rather than
drawing its own chrome:

- The tab bar is the floating glass pill, three tabs and nothing beside
  it (the search circle, `Tab(role: .search)`, went when search moved
  above the list); it stays whole while the list scrolls.
  The label bar over it is what folds on a scroll down, to the label in
  use (`TriageSplitBar`, `ScrollCollapse`); a tap, a scroll up or the top
  of the list opens it again. The open bar and the pill are one piece
  of glass (`glassEffectID`), so the bar shrinks into the pill.
- No navigation title (`toolbar(removing: .title)`): the bar is just the
  two glass circles, and the list starts right under them.
- Toolbar items, the account pill, the thread's participant pill and the
  thread's triage bar are glass (`glassEffect`, `.buttonStyle(.glass)`).
  What floats is the system's; what the app says on it is ink. Two things
  are not glass: the selected label of the pill and the thread's Reply are
  ink capsules, and the undo toast is an ink capsule on every platform
  (`toastSurface`), its Undo in pink.
- Sheets (Remind me, Sidebar) are plain iOS 26 sheets on the raised paper
  (`menuSheet`), with the system's grabber; content is a list of ruled
  rows under their titles with a title row and a close button, no
  navigation bar and no cards.

### Gestures (the keyboard map, translated)

Swipes have **two tiers in each direction**: a short drag arms the first
action, a longer one the second. Each threshold ticks with a haptic and the
revealed colour and icon change, so what happens on release is never a
guess. Letting go before the first threshold does nothing.

The actions are the desktop's, in the desktop's words: **Mark done** (`e`,
archive), **Pin** (`s`, the Gmail star), **Remind me** (`h`), **Need reply**
(`n`), **Mark read/unread** (`u`), **Move to folder** (`v`), **Add label**
(`l`), **Reply** / **Reply all** / **Forward**, **Delete** (`#`).

| Desktop | iOS default | Notes |
| --- | --- | --- |
| `u` read/unread | **swipe right, short** | grey |
| `e` mark done | **swipe right, long** | ink: the "check off" moment, the row's words are struck through while it is armed, the row slides out, Undo toast for 5 s |
| `h` remind me | **swipe left, short** | opens the Remind sheet |
| `n` need reply | **swipe left, long** | sky; toggles, row gets the ↩︎ mark |
| `s` pin, `#` delete, `v` move, `l` label | long-press menu | also in the thread's More menu |
| `enter` open | tap | |
| `esc` back | back / edge swipe | |
| `j`/`k` | scroll | |
| `/` search | a short pull down on the list · sidebar › Search | |
| `cmd+k` palette | long-press a row | Mark done, Remind me, Pin, Need reply, Mark read/unread, Move to folder, Add label, Jev labels, Delete |
| `0`/`1`/`2` accounts | sidebar | |
| `g i` / `g a` | sidebar · label pill | Scheduled and Need reply are tabs |
| `?` | — | Not needed; gestures are discoverable |

Which action sits on which tier is **Settings › Inbox › Swipe actions** —
the desktop's "Hover actions", translated to the phone's gesture. What an
action is called, its glyph and its colour are defined once
(`Shared/RowActionPresentation.swift`) for the swipes, the long-press
menu, the thread's bar, the Mac's hover bar and the command palette.

Multi-select is not built on the phone (the Mac has it: ⌘/⇧-click, ⇧J /
⇧K / X and a batch bar). The plan was the native List edit mode with a
bottom bar; it waits for a selection model in `ThreadList`.

A swipe's tiers are VoiceOver's custom actions on the row, each once.

Pull-to-refresh runs `sync_all`. The app also syncs on every foreground.

### Remind sheet

Half-height sheet on the raised paper: the title row (`SheetHeader`,
shared with Add to bundle), then, under one rule, the toggle **"Only if
nobody replies"** (desktop's follow-up) — first, because a preset sets
the reminder and closes the sheet — then the presets as ruled rows, each
with its time in the mono — *Later today (18:00)*, *Tomorrow (09:00)*,
*This weekend*, *Next week*, *In a month*, *Pick date…* — and a *Remove
reminder* row when one is set. No cards. Times respect the user's locale
and a "day starts at" setting (default 09:00).

### Thread view

Pushed onto the stack. The top bar holds the back circle, the other people's
names and the AI + More circles; the subject sits in the content, large,
with one line of marks under it (the priority's three bars, the Jev
labels as words and a "+" to edit them, the reminder and Need reply as
writing in their state's colour) and, at the line's end, the count in
words ("6 messages", quiet: a bare number read as one more mark).
Messages are the inbox's rows under one rule — sender · time, one snippet
line, a hairline between two, all on the paper: latest expanded, older
ones collapsed, tap to expand. A closed message that was read has its
sender in the secondary colour; the open one is bold ink and an unread
one is bold under the highlighter, as on a row. Past four
messages the middle folds into one "N earlier messages" line — small, in the
tertiary colour, a chevron before it; a run of unread
messages before the last two stays visible.

An open message's header is two lines. The first is the sender and the time,
as short as the day allows (`Formatters.messageTime`): "05:57" today,
"Yesterday, 05:57", "Thu, 09:12" within the week, then "Nov 12, 09:12", the
year only when it is another; the whole date is the tooltip and what
VoiceOver reads. The second is "to …" — by name where the thread knows the
address (`ThreadDetail.knownNames`) — and ends with the message's •••, so
the times of open and closed messages share one right edge.

The three devices share all of this and differ in the container only
(`ThreadChrome`): flat and edge to edge on the phone (no cards), a 760 pt
column on a regular-width iPad (`readableColumn`), and on the Mac the same
column, flat on the paper too, with the reply pills at the last message's
foot ([macos-app/CLAUDE.md](../macos-app/CLAUDE.md)).

- **Body** renders in a `WKWebView` with JavaScript off, a strict CSP meta
  tag, `about:blank` origin and remote images blocked by default; a one-tap
  "Load" line per sender remembers the choice. The HTML is the
  body the core stores, sanitized there (ammonia: scripts, handlers,
  forms and frames gone; layout and links kept); this view is the
  second layer. Web links open in
  the user's default browser (never in-app); the real URL is shown in a
  long-press preview.
  The trailing quoted history (`div.gmail_quote`, Outlook's reference
  container, a trailing `<blockquote>`, or `>` lines in plain text) folds
  behind a small, quiet ••• pill, same rules as desktop.
- **Attachments** are boxed tiles under the message (an outline, no
  fill): tap fetches the bytes (`messages.attachments.get`, cached as a
  file) and opens Quick Look. Never auto-open. On images and PDFs,
  **Explain attachment** has the on-device model read it (OCR, barcodes)
  and offers one-tap actions — remind me on travel day, copy the tracking
  number — each the action's words under the highlighter, as everything
  the AI suggests is; mail that smells like a receipt, ticket or shipment
  gets them under the subject as the thread opens
  ([ios-intelligence.md](./ios-intelligence.md) "Attachment understanding").
- **AI summary** card at the top when a summary exists or auto-summarize is
  on; "Summarize" in the toolbar menu otherwise.
- **Two floating bars** replace the tab bar while a thread is open: the
  Reply pill — the screen's one ink action, an ink capsule — with the AI
  circle beside it (the app's one pink fill), and under it, as one glass
  bar, the triage bar: Done · Remind · Need reply · Pin · Delete, ink
  glyphs with Delete in the danger colour. A set toggle shows a filled
  glyph in its state's colour (done mint, reminder lavender, need reply
  sky; the pin stays ink). Labels, Mark unread, Add to bundle, Forward,
  Report spam and Delete live in the top-right More menu — only what the
  bar does not hold: Pin and Remind me are the bar's, Unsubscribe is a
  mark in the line under the subject.
- **Reply pill** works like Superhuman's: tapping it runs the default (Reply
  all when others are on the latest message, else Reply), the chevron picks
  Reply · Reply all · Forward with each one's recipients (the pick sticks for
  the thread; a reply goes to the message's Reply-To when its sender set
  one, and the account's "Send mail as" addresses count as the user's own;
  the rules are in `docs/specs/reply-recipients.md`), and the AI draft is its own circle beside it. There are no action
  links under the bodies on the phone and the iPad (the Mac ends the last
  message with Reply · Reply all · Forward and keeps the triage alone on
  its floating bar): an open message's ••• or a long press on any
  message's header line replies to or forwards that one (the body is left
  to the long press that starts a text selection).
- Thread-level swipe between adjacent threads is deliberately **not** in v1
  (it fights the system back-swipe).

### Compose and reply

A sheet, or full screen (its corner button switches). The fields, the
rich-text body and the footer are in "Compose" below. The sparkle in the footer (when a provider is configured) opens the AI
sheet — the desktop `Cmd+J` popover with a second mode: **Edit** (tone and
edit presets, a free instruction, against the selection or the whole body)
(shared with the Mac's panel: `AIAssist.swift` — one list of presets and
tones, every request cancellable and given up on after 90 s, the result
shown for review, with tones to refine it, before it replaces anything,
and a footer that says what the tap sends and to whom; the request
carries the provider that footer was drawn with, and the core sends
nothing when another one would answer by then — the sheet says the
provider changed and the footer redraws)
and **Write** (a brief, or notes for a reply, that the AI turns into the
whole message; the sheet opens there when the body is empty). Attachments
via the Photos picker and the Files picker, 18 MB a message. **Send waits
5 s** (Settings › Compose › Undo send: 5 · 10 · 20 · 30)
in the toast with Undo — the desktop's deferred commit — and only then goes
through the outbox, with the same retry semantics as desktop; Undo reopens
the composer with the draft. Backgrounding the app inside the window sends
at once rather than risk losing the message. The composer has no Cancel:
its **X** (or leaving the app; the sheet does not close on a swipe down,
so scrolling back up through a message cannot close it) saves the message as a
Gmail draft — created on the first save, updated after that, skipped while
nothing changed — and the trash next to Send discards it, deleting that
draft, with Undo in the toast: Undo opens the composer on the message
again (`AppModel.discardDraft`). A send deletes the draft too once it
commits. A draft deleted from under its thread goes at once as well, and
its Undo saves it back (`discardSavedDraft`); only when the draft cannot
be read first — offline — does the delete ask, because it could not be
undone. A saved draft reopens with its formatting: the phone reads back
bold, italic, underline, strikethrough, links and paragraphs; a draft
with anything richer (a list, Gmail's own blocks) opens as its plain
text here, while the Mac's HTML editor loads it whole
(`docs/specs/draft-formatting.md`).

A reply shows the conversation it answers under the editor
(`ComposeThreadHistory`): the latest message open, earlier ones a line
each, tap to open. Replies go out without a quote — Gmail threads them —
unless **Quote in reply** puts the latest message into the text as "> "
lines, to be answered between them.

### Scheduled, Need reply, Labels

Scheduled (its own tab) groups by due date: Overdue · Today · Tomorrow ·
This week · Later. Need reply (its own tab) is a plain list. Labels are the
same rows filtered by `label:<id>`, reachable from the Inbox title menu;
label management (rename, colour, delete) stays in Settings.

### Settings

The desktop's sections, same wording. The root is short: **AI** and
**Triage** are a page each, pushed from two rows under Accounts
(`SettingsRoute`), on the phone, the iPad and the Mac. On the Mac
Settings is a page of the window, and the window's own Back, Esc and
title follow a pushed page (`WindowState.settingsPath`).

- **Accounts** — the initial in an outlined circle, name, email,
  connection state; Name, Color (the
  five tags), Sync (reminder sync over the account's Drive app folder),
  Signature; Reconnect, Remove (asks once); Add account.
- **AI** — one *Provider* select box: *Apple Intelligence · on this
  iPhone* (no key), *Apple Intelligence · Apple's cloud* (Private Cloud
  Compute, no key, Apple-private, never stored), *ChatGPT (OpenAI)*,
  *Claude (Anthropic)* or *Gemini (Google)* — the last three by API key
  only (paste a token, verified before it is stored; Model; Remove), each
  with its own key and model. Under it the picked provider's state; *If it
  can't answer* the order after it (private first · cloud first · stay on
  this iPhone), both synced; Auto-summarize; a token line per provider.
  Powers "Summarize N active" on the day groups, "Summarize thread", the ✨
  draft reply, Edit with AI in compose (tone and edit presets or a freeform
  instruction), the translate circle beside a selection in a received
  message (for the language pairs Apple's on-device translation does not
  have), and the triage, Ask and attachment features of
  [ios-intelligence.md](./ios-intelligence.md).
- **Siri & Search** — *Let Siri see your inbox* (the on-device Spotlight
  index Siri, Spotlight and "Ask my inbox" read), *Ask my inbox*, the Siri
  tip, the Shortcuts link, and a door to the app's own Siri & Search page in
  iOS Settings; the footer says how to make Siri and Spotlight answer from
  Hey Pigeon's mail rather than Apple Mail's (Mail's *Show in Search* off).
- **Default email app** — one button to iOS Settings › Apps › Default Apps,
  where Hey Pigeon is offered under Email once the build carries Apple's
  default-mail-client entitlement (ios-app/README.md "Default mail app").
  With it chosen, every `mailto:` link on the phone and Siri's "send an
  email" compose here. The app cannot read which app is the default, so
  there is no status line.
- **Triage** — *Classifier*: On this iPhone · Apple's cloud · Jev (key,
  verified); Auto-triage; Reanalyze all emails; then *Labels*, a section
  of their own (add; drag to reorder; swipe to remove). Classification runs at the end of every sync round, bounded per
  round, never on its own timer — except that a pass with mail left keeps
  going round after round while the app is in front, with its progress in
  the inbox, in Settings and (20+ emails) as a Live Activity. The labels are the bottom pill and the
  words on rows (`#Travel`); a thread's labels can be edited by hand (sticky until
  Reanalyze). *Siri triage* opens one page for "Hey Siri, triage my
  inbox": the run, its *Rules* (a dry-run switch and your own triage rules
  in your words, both synced) and the journal.
- **Inbox** — Pinned list; Swipe actions (the four tiers).
- **Appearance** — System · Light · Dark; on the Mac also *Show in the
  menu bar* (the menu bar extra with the unread count).
- **About** — version, links. Updates come through TestFlight / App Store.

The page is drawn as every menu is (`SettingsList`, `menuList`,
`menuCard`): sections under their light grey titles (`SectionTitle`; a
section with no name opens with the rule alone), rows parted by
hairlines, no cards. A switch that is on is ink, a field has an ink
underline, a text of several lines an outlined box, a small button at a
row's end is an outlined capsule, and what deletes is written in the
danger colour.

### Compose

The desktop Composer: From (account dot + address, switching swaps
the signature while the body is pristine), To with recipient chips and a
Cc/Bcc toggle, Subject, a rich-text body (iOS 26 `TextEditor` over
`AttributedString`), attachment chips (Files or Photos, 18 MB cap), and the
footer: Send · Discard · ✨ Edit with AI · Attach · Aa (bold, italic,
underline, strikethrough, link). A footer narrower than 480 pt (the
phone) keeps Send at full size and shows Send · ✨ · Attach · Aa · More,
with the read status switch, the snippets and Discard under More. Plain
text always goes out; an html part only when formatting was applied.

On the paper a field has no fill: its name in small mono capitals and a
hairline under it. A recipient and an attachment are boxed chips (an
outline, 6 pt corners). Send is the sheet's one ink action and the AI's
sparkle its pink; the message itself is written in the system font, as
it will be read.

### States and motion

- Waiting on a model or the network (a summary, Ask my inbox, Explain
  attachment, a translation) is one view, `ResultState`: a spinner and a
  word, or what went wrong with **Try again**, or the result. A thread
  that could not load has Try again too.
- Removing what cannot be brought back asks once, in one way — a
  confirmation dialog: an account, an API key, a triage label, a Gmail
  label. What can be undone gets Undo in the toast instead.
- The toast sits above the tab bar, and above the thread's two bars
  while a thread is open (`ToastMetrics.bottomInset(threadOpen:)`).
- The toast (`ToastStack`, one view for the phone and the Mac) is spoken
  by VoiceOver as it appears and stays 20 s while VoiceOver runs.
- Reduce Motion: the row leaves without the slide, a swiped row is back
  in place at once and the toast fades (`Motion` in Platform.swift).
- Empty inbox is a designed moment: the pigeon, "All clear", the time of the
  last sync. Not a shrug. With no account connected the same place is the
  way in: "Connect your Gmail" and one *Add Google account* button
  (`EmptyState`'s `connect`, from `AppModel.connectFirstAccount`), on the
  phone, in the iPad's list column (its thread column stays blank until
  there is mail) and in the Mac window.
- Loading is skeleton rows, never a spinner in the list.
- Every screen stands on one flat paper (`Theme.canvas`; white, and a
  dark grey a step off black in dark): the lists, a thread, Search and
  "All clear" alike. A sheet is the raised paper (`Theme.raised`), the
  same white on light and a step up on dark. There is no wash and no
  card; a mail row is opaque only so the swipe panel can sit behind it.
- The only animation of note is archive: the row slides out in ~150 ms with
  a haptic. Everything else is the system's.
- Dark mode from day one, following the system (or Settings ›
  Appearance). The colours are `Theme`'s tokens: paper, ink, three greys
  of text, the light grey of titles, one pink (a highlighter's band, the
  AI's ink, one fill) and the five state colours with a lighter pair for
  dark. The table and the rules for using them are
  [specs/marker-look.md](./specs/marker-look.md).
- Typography: Instrument Sans for the interface and DM Mono for what is
  read as data — times, counts, sizes, tags, keys and the titles of groups
  (`Theme.sans`, `Theme.mono`, the roles of `Theme.text`; the files are in
  `HeyPigeon/Resources/Fonts`, `Typeface` loads them for the app and both
  extensions). Mail content keeps the system font. Every size is declared
  `relativeTo` a text style so Dynamic Type scales it, and a weight is
  asked for by name, never with `.weight()` on a custom font.

### iPad and hardware keyboards

An iPad shows the phone's layout at every width: the tabs, one list and
a thread in its place, each kept to a readable column (`readableColumn`,
760 pt, centred) when the screen is wider than that. It had three columns
at regular width (`Features/Pad/PadSplitView`), which read as an ordinary
mail client; they are no longer shown. The folders' drawer and the list's
keys (`PadKeys`) are being rebuilt on the single list; see
`porting-macos-ipados.md`. Until then a hardware keyboard has ⌘N and the
open thread's own keys.

## Platform constraints and how we handle them

| Concern | Desktop today | iOS |
| --- | --- | --- |
| OAuth redirect | Loopback `127.0.0.1:<port>` | **Reversed-client-id scheme** via `ASWebAuthenticationSession`. Google requires an **"iOS" OAuth client** (no secret). `oauth::AuthRequest` is the shared piece; `oauth::authorize` stays the desktop loopback wrapper. |
| Client secret | Required by Desktop-app clients | None. `ClientConfig.client_secret` is now `Option`. |
| Secrets | OS keychain (`keyring`) | iOS Keychain, spoken to directly (`ffi/src/secrets.rs`): items are readable after the first unlock since a restart, so a push or background refresh on a locked phone can read the refresh token. Items are per app; not iCloud-synced in v1. |
| Sync cadence | 30 s poll loop in Rust | **The shell owns cadence.** Foreground: sync on launch, on every foreground, on pull. Background: `BGAppRefreshTask` (iOS decides when; expect a few times a day). No loop inside the engine. |
| New-mail push | Polling | **Optional relay** (issue #16, `relay/`, `terraform/`): Gmail `users.watch` → Pub/Sub → Cloud Run → silent APNs push → the phone runs one delta sync and composes the notification locally; badge = unified unread + reminders due today. The relay sees email + historyId, never mail. Off by default — local-first still means the inbox is current the moment the app opens. Settings → Notifications → "New mail (push)" + relay URL. |
| Reminder notifications | Posted from the poll loop | **Local notifications**, scheduled ahead from `list_scheduled()` when a reminder is set and on every sync (next 7 days, replaced wholesale each time). Each carries the icon badge it should leave behind (unread + reminders due by then), so the badge moves while the app is asleep. Shown in front too. Works fully offline, no server. Follow-ups cancel on the next sync that sees a reply. |
| Mail HTML | Sandboxed iframe, CSP | `WKWebView` with scripts off, CSP meta, remote images blocked, links to the default browser. Same sanitized HTML. |
| Attachments | Disk LRU cache | Same core logic; cache in the app container, relative paths. |
| Cross-device state | Drive `appDataFolder` | Identical — the same adapter runs; reminders, flags, account name/colour/signature, triage labels and prefs (`pref:<name>`: pinned list, auto-summarize, swipe actions, AI model, triage switch) set on the phone show on the Mac within a poll, and back. `AppModel` prefs are engine-backed (`prefs()` / `setPref`); UserDefaults only seeds a pre-sync install's values once. API keys stay in each device's keychain. |
| Distribution | Signed DMG via CI | Personal: Xcode run on device / TestFlight. The App Store is not a goal. |
| Bring-your-own OAuth | `~/.config/heypigeon/oauth.json` or CI-baked | `ios-app/Config/Local.xcconfig` (git-ignored) with the iOS client id; the reversed id becomes the URL scheme in Info.plist. |

## The bridge: `crates/ffi`

`heypigeon-ffi` exposes one UniFFI object, `Engine`, with the operations the
IPC contract already has (`desktop-app/src/lib/ipc.ts`), minus AI/Jev for
now:

- `Engine.open(dataDir, oauthClient)` — opens SQLite, wires Gmail. No network.
- Reads, synchronous and local: `listAccounts`, `listThreads(filter,
  accountId, before, limit)`, `listLabels`, `listTriageLabels`,
  `unreadCounts`, `listScheduled`, `listNeedsReply`, `search`,
  `accountStatus`.
- `getThread` — async; fetches bodies from Gmail on first open, then local.
- Writes: `mutate(accountId, mutation)` (optimistic + outbox drain),
  `setSchedule`, `setNeedsReply`, `removeAccount`.
- Sync: `syncAll()`, `syncNow(accountId)` — the shell calls these.
- OAuth: `beginOauth(loginHint, redirectUri)` → `{url, callbackScheme}`;
  `finishOauth(callbackUrl)` → email.
- `EngineListener` (implemented in Swift): `onThreadsUpdated`,
  `onAccountDisconnected`.

Records are explicit copies of the domain types (`MailThread`,
`MailMessage`, `MailLabel`, `Account`, `Mutation`, …) so `core` stays free
of binding concerns, and so the Swift names do not shadow
`Foundation.Thread` or `SwiftUI.Label`.

Build: `cargo build --release --target aarch64-apple-ios` (device) and
`aarch64-apple-ios-sim` (simulator) produce `libheypigeon_ffi.a`;
`uniffi-bindgen generate --library` emits `HeyPigeonCore.swift` plus a C
header and module map; `xcodebuild -create-xcframework` wraps the static
libraries. `ios-app/scripts/build-rust.sh` does all of it and is wired as an
Xcode run-script phase. Linux CI can already compile the crate, run its
tests and generate the bindings, which is how the API is kept honest without
a Mac.

## Milestones

1. **iOS-M1 — read and triage** (daily-drivable for mail you don't answer
   from the phone): connect account(s), unified inbox, thread view with safe
   HTML, archive / read / star / trash / remind / need reply with the gestures
   above, search, Scheduled and Need reply views, local reminder
   notifications, sync on foreground + pull + background refresh. *Gate: does
   archiving feel like Things 3?*
2. **iOS-M2 — write**: reply, compose, forward; attachments (view and send);
   AI bar; account settings; labels menu and management.
3. **iOS-M3 — polish**: iPad split view and keyboard map, widgets (unread
   count, next reminder), Shortcuts actions, share extension ("send this
   file"), optional relay (push; read status).
4. **iOS-M4 — Siri and on-device AI**: App Intents over `AppModel`, the
   Spotlight index the new Siri reads, the Mail schema domain, on-screen
   awareness, Foundation Models as the zero-key AI default, widgets and
   Controls. Specified and built in [ios-intelligence.md](./ios-intelligence.md);
   the widgets, Shortcuts and share-extension items of M3 are there too.
5. **iOS-M5 — iOS 27**: the deployment floor moves to 27 and the
   intelligence layer grows into it — Apple's Private Cloud Compute and
   pluggable `LanguageModel` providers behind one Swift backend, "Ask my
   inbox" over the Spotlight index, the agentic "triage my inbox" with a
   Live Activity, attachment understanding, the `.mail.thread` schema and
   View Annotations, syncable entities and donations. Built, in
   [ios-intelligence.md](./ios-intelligence.md) "iOS 27"; the first build
   on a Mac with the iOS 27 SDK is the gate.

## Out of scope

Android (the same `ffi` crate would bind through UniFFI's Kotlin generator,
but nobody is asking), the App Store, generic IMAP, any server beyond the
optional relay (`relay/README.md`): push, which sees an address and a
change counter, and read status, which for an account that turned it on
holds a random token per sent message and when it was opened. Never mail.
