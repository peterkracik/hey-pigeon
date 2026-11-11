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
│ (≡)                                                  (✎) │  ← sidebar · compose
│ ● Sender                                          10:42  │
│   Subject                                                │
│   two lines of snippet…                                  │
│ ─────────────────────────────────────────────────────────│
│   …                                                      │
│        ( Inbox 2 · Invoices · Travel · Newsletters )     │  ← Jev label pill (Settings › Triage)
│   (  Inbox  ·  Remind me  ·  Need reply  )   (🔍)        │  ← tab bar + search
└──────────────────────────────────────────────────────────┘
```

- **Tabs = the rail.** Inbox, Remind me (reminders) and Need reply are the
  tab bar; Search is the system's separate search circle. Inbox carries an
  unread badge, Remind me the number of reminders due today, Need reply its
  count. The app icon badge is unified unread + reminders due today.
- **The sidebar (≡)** is the desktop sidebar as a sheet: Inbox, then the
  accounts (All / each account) on a card of their own — a disconnected
  one with a Reconnect row under it — then the desktop's folders in
  its order — Pinned (Gmail's Starred) · Sent · Drafts · Archive · Remind me · Need reply ·
  All emails · Spam · Trash — the Gmail labels, Add account and Settings.
  Picking a folder shows it in the Inbox tab.
- **The label pill** above the tab bar is the desktop's label tabs under the
  folder title: the folder (no filter), then the **Jev triage labels** from
  Settings › Triage. One tap narrows the list to that label. Gmail labels
  stay in the sidebar. Accounts (desktop `0`/`1`/`2`) switch in the sidebar,
  under Inbox, and the choice applies across all tabs.
- **Groups** are the desktop's: Pinned (when "Pinned list" is on) · Today ·
  Last 7 days · Older. Remind me buckets by due date; Need reply has no
  Pinned group.
- **Rows:** flat, edge to edge, one colour. Unread is a bar on the left
  edge (white on dark, the accent on light) and the bold sender. In the
  unified view the sender's first letter takes the account colour — no
  dot, no avatar.
- **The title** sits between the two circles: folder, unread count and —
  with more than one account — the account's dot and name. Tapping it
  switches account (All · each). Search stays in the bottom-right circle,
  where iOS 26's own Mail keeps it.
- **Compose** is the top-right circle; with an AI provider connected a
  sparkle sits next to it and summarizes the current view (folder ·
  label filter · account) in a sheet. When "Ask my inbox" is there too,
  the one sparkle is a menu of the two (`MailListScreen.aiBarItem`), so
  the bar never holds more than the sidebar, the title and two circles.
  A thread has the summary sparkle in its top bar.
- **Triage chips** (Jev labels + priority) appear inline on rows, not as a
  filter bar; a priority filter can join the account pill later.
- **The thread view hides the tab bar** and shows two floating glass bars in
  its place: Reply (+ new message), and the triage actions.

### Rows

Three lines, flat, a 1 pt gap between rows, no cards and no avatar — and
a fourth line of chips (the bundle, up to two Jev labels) only when there
is something to say:

```text
▌Sender name  3                                ⏰ 10:42
▌Subject line                          [Suggested] 📎
▌First line of the snippet…
```

- The unread mark is a 3 pt bar on the row's left edge (the accent on
  light, white on dark) and the bolder sender; a read row has neither. In
  the unified view the sender's first letter takes the account's colour.
  VoiceOver reads the row's state as its value (`ThreadRow.spokenState`:
  Unread, Reminder, Need reply, Pinned, Done, Has attachment).
- Sender in semibold (14 pt Manrope, bold when unread), subject semibold
  when unread, one line of snippet in grey.
- Reminder, need-reply, pin and done marks sit next to the time; the AI's
  suggestion, a Draft chip and the attachment clip sit at the end of the
  subject line, only when present.
- Day groups have a small grey header (Pinned · Today · Last 7 days ·
  Older); Remind me has its due buckets (Overdue · Today · Tomorrow ·
  This week · Later).
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

- The tab bar is the floating glass pill with the Search tab as the separate
  circle (`Tab(role: .search)`); it minimizes on scroll
  (`tabBarMinimizeBehavior(.onScrollDown)`) so a long inbox is all rows.
- No navigation title (`toolbar(removing: .title)`): the bar is just the
  two glass circles, and the list starts right under them.
- Toolbar items, the account pill, the undo toast, the thread's participant
  pill and both bottom bars are glass (`glassEffect`, `.buttonStyle(.glass)`).
- Sheets (Remind me, Sidebar) are plain iOS 26 sheets: the system draws the
  glass background and grabber; content is a grouped list with a title row
  and a close button, no navigation bar.

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
| `e` mark done | **swipe right, long** | accent pink: the "check off" moment, row slides out, Undo toast for 5 s |
| `h` remind me | **swipe left, short** | opens the Remind sheet |
| `n` need reply | **swipe left, long** | blue; toggles, row gets the ↩︎ mark |
| `s` pin, `#` delete, `v` move, `l` label | long-press menu | also in the thread's More menu |
| `enter` open | tap | |
| `esc` back | back / edge swipe | |
| `j`/`k` | scroll | |
| `/` search | Search tab | |
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

Half-height sheet: the title row (`SheetHeader`, shared with Add to
bundle), then the toggle **"Only if nobody replies"** (desktop's
follow-up) — first, because a preset sets the reminder and closes the
sheet — then the presets as a grouped list — *Later today (18:00)*,
*Tomorrow (09:00)*, *This weekend*, *Next week*, *In a month*, *Pick date…* —
and a *Remove reminder* row when one is set. Times respect the user's locale and a
"day starts at" setting (default 09:00).

### Thread view

Pushed onto the stack. The top bar holds the back circle, the other people's
names and the AI + More circles; the subject sits in the content with one
line of the list's chips (priority, Jev labels and a "+" to edit them, the
reminder and need-reply badges as coloured pills) and the message count. Messages are the inbox's rows — sender · time, one
snippet line, the unread bar on the left edge, 1 pt gaps: latest expanded on
the card surface, older ones collapsed on the canvas, tap to expand. Past four
messages the middle folds into one "N earlier messages" row; a run of unread
messages before the last two stays visible.

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
  behind a ••• button, same rules as desktop.
- **Attachments** are chips under the message: tap fetches the bytes
  (`messages.attachments.get`, cached as a file) and opens Quick Look. Never
  auto-open. On images and PDFs, **Explain attachment** has the on-device
  model read it (OCR, barcodes) and offers one-tap chips — remind me on
  travel day, copy the tracking number; mail that smells like a receipt,
  ticket or shipment gets the chips under the subject as the thread opens
  ([ios-intelligence.md](./ios-intelligence.md) "Attachment understanding").
- **AI summary** card at the top when a summary exists or auto-summarize is
  on; "Summarize" in the toolbar menu otherwise.
- **Two floating bars** replace the tab bar while a thread is open: the
  Reply pill and the AI circle, and under it, as one glass bar,
  the triage bar: Done · Remind · Need reply · Pin · Delete. A set toggle
  shows a filled icon in its state colour (done mint, reminder lavender,
  need reply sky, pin amber). Labels, Mark unread, Add to bundle, Forward,
  Report spam and Delete live in the top-right More menu — only what the
  bar does not hold: Pin and Remind me are the bar's, Unsubscribe is the
  chip under the subject.
- **Reply pill** works like Superhuman's: tapping it runs the default (Reply
  all when others are on the latest message, else Reply), the chevron picks
  Reply · Reply all · Forward with each one's recipients (the pick sticks for
  the thread; a reply goes to the message's Reply-To when its sender set
  one, and the account's "Send mail as" addresses count as the user's own;
  the rules are in `docs/specs/reply-recipients.md`), and the AI draft is its own circle beside it. There are no action
  links under the bodies: an open message's ••• or a long press on any
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
its **X** (or a swipe down, or leaving the app) saves the message as a
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

- **Accounts** — avatar, name, email, connection state; Name, Color (the
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
  message, and the triage, Ask and attachment features of
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
  chips on rows; a thread's labels can be edited by hand (sticky until
  Reanalyze). *Siri triage* opens one page for "Hey Siri, triage my
  inbox": the run, its *Rules* (a dry-run switch and your own triage rules
  in your words, both synced) and the journal.
- **Inbox** — Pinned list; Swipe actions (the four tiers).
- **Appearance** — System · Light · Dark; on the Mac also *Show in the
  menu bar* (the menu bar extra with the unread count).
- **About** — version, links. Updates come through TestFlight / App Store.

### Compose

The desktop Composer: From chip (account dot + address, switching swaps
the signature while the body is pristine), To with recipient chips and a
Cc/Bcc toggle, Subject, a rich-text body (iOS 26 `TextEditor` over
`AttributedString`), attachment chips (Files or Photos, 18 MB cap), and the
footer: Send · Discard · ✨ Edit with AI · Attach · Aa (bold, italic,
underline, strikethrough, link). Plain text always goes out; an html part
only when formatting was applied.

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
- The only animation of note is archive: the row slides out in ~150 ms with
  a haptic. Everything else is the system's.
- Dark mode from day one, following the system. Colours come from the same
  tokens as `desktop-app/src/styles/colors.css` (navy scale, pink accent,
  five account tags).
- Typography: Manrope for titles and sender names (brand), the system font
  for body text and the mail content (legibility, Dynamic Type for free).
  Every custom size is declared `relativeTo` a text style so Dynamic Type
  scales it.

### iPad and hardware keyboards

At regular width an iPad shows three columns (`Features/Pad/PadSplitView`:
the sidebar's list, the thread list, the open thread) with the list's
keys (`PadKeys`); see `porting-macos-ipados.md`. In a narrow window it is
the phone's tabs. The open thread keeps to a readable column
(`readableColumn`, 760 pt, centred) when its column is wider than that.

## Platform constraints and how we handle them

| Concern | Desktop today | iOS |
| --- | --- | --- |
| OAuth redirect | Loopback `127.0.0.1:<port>` | **Reversed-client-id scheme** via `ASWebAuthenticationSession`. Google requires an **"iOS" OAuth client** (no secret). `oauth::AuthRequest` is the shared piece; `oauth::authorize` stays the desktop loopback wrapper. |
| Client secret | Required by Desktop-app clients | None. `ClientConfig.client_secret` is now `Option`. |
| Secrets | OS keychain (`keyring`) | iOS Keychain through the same crate (`apple-native` covers iOS). Items are per app; not iCloud-synced in v1. |
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
   file"), optional push relay.
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
optional metadata-only push relay (`relay/README.md`).
