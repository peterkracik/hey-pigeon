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
│   (  Inbox  ·  Scheduled  ·  Need reply  )   (🔍)        │  ← tab bar + search
└──────────────────────────────────────────────────────────┘
```

- **Tabs = the rail.** Inbox, Scheduled (reminders) and Need reply are the
  tab bar; Search is the system's separate search circle. Inbox carries an
  unread badge, Need reply its count.
- **The sidebar (≡)** is the desktop sidebar as a sheet: the accounts
  (All / each account) nested under Inbox, then the desktop's folders in
  its order — Starred · Sent · Drafts · Archive · Scheduled · Need reply ·
  All emails · Spam · Trash — the Gmail labels, Add account and Settings.
  Picking a folder shows it in the Inbox tab.
- **The label pill** above the tab bar is the desktop's label tabs under the
  folder title: the folder (no filter), then the **Jev triage labels** from
  Settings › Triage. One tap narrows the list to that label. Gmail labels
  stay in the sidebar. Accounts (desktop `0`/`1`/`2`) switch in the sidebar,
  nested under Inbox, and the choice applies across all tabs.
- **Groups** are the desktop's: Pinned (when "Pinned list" is on) · Today ·
  Last 7 days · Older. Scheduled buckets by due date; Need reply has no
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
  label filter · account) in a sheet. A thread has the same sparkle in
  its top bar.
- **Triage chips** (Jev labels + priority) appear inline on rows, not as a
  filter bar; a priority filter can join the account pill later.
- **The thread view hides the tab bar** and shows two floating glass bars in
  its place: Reply (+ new message), and the triage actions.

### Rows

Three lines, flat, hairline separators, no cards and no avatar — about
86 pt per row, so six rows are visible above the bars:

```text
● Sender name  3                                ⏰ 10:42
  Subject line                              [medium] 📎
  First line of the snippet…
```

- The dot is the unread mark: account-coloured in the unified view, accent
  when filtered to one account; a read row has no dot.
- Sender in semibold (15 pt Manrope), subject semibold when unread, one
  line of snippet in grey.
- Reminder, need-reply and star marks sit next to the time; priority chip
  and attachment clip sit at the end of the subject line, only when present.
- No day-group headers in the inbox (the time column carries the date);
  Scheduled keeps its due buckets (Overdue · Today · Tomorrow · This week ·
  Later).
- Pagination is keyset (`before = last row's last_msg_at`), 50 rows a page.

### Liquid Glass (iOS 26)

The app targets iOS 26 and uses the system's Liquid Glass surfaces rather
than drawing its own chrome:

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
the desktop's "Hover actions", translated to the phone's gesture.

Multi-select: the native List edit mode (Edit button, or two-finger drag
down the rows) shows a bottom bar with Archive · Read · Remind · Trash.

Pull-to-refresh runs `sync_all`. The app also syncs on every foreground.

### Remind sheet

Half-height sheet with the presets as a grouped list — *Later today (18:00)*,
*Tomorrow (09:00)*, *This weekend*, *Next week*, *In a month*, *Pick date…* —
a toggle **"Only if nobody replies"** (desktop's follow-up), and a *Remove
reminder* row when one is set. Times respect the user's locale and a
"day starts at" setting (default 09:00).

### Thread view

Pushed onto the stack. The top bar holds the back circle, a glass pill with
the participants and a More circle; the subject sits in the content with its
unread dot and priority chip, then a status line (reminder, AI summary).
Messages are flat rows with hairlines: latest expanded, older ones collapsed
to sender · first line · date, tap to expand — same as desktop.

- **Body** renders in a `WKWebView` with JavaScript off, a strict CSP meta
  tag, `about:blank` origin and remote images blocked by default; a one-tap
  "Load images" bar per sender remembers the choice. The HTML is the
  ammonia-sanitized body the core already stores. Links open in
  `SFSafariViewController`; the real URL is shown in a long-press preview.
- **Attachments** are chips under the message: tap fetches the bytes
  (`messages.attachments.get`, cached) and opens Quick Look. Never auto-open.
- **AI summary** card at the top when a summary exists or auto-summarize is
  on; "Summarize" in the toolbar menu otherwise.
- **Two floating bars** replace the tab bar while a thread is open: a Reply
  pill (with the AI draft spark) next to a new-message circle, and under it
  the triage bar: Archive · Remind · Need reply · Star · Collapse all. Labels,
  Mark unread, Forward and Trash live in the top-right More menu.
- Thread-level swipe between adjacent threads is deliberately **not** in v1
  (it fights the system back-swipe).

### Compose and reply

Full-screen sheet. From-account picker at the top, defaulting to the account
that received the thread. Recipient field with People-API suggestions (the
core already does the lookups). Plain text in v1 — rich text and inline
images follow once the desktop composer's HTML path is proven on the phone.
Above the keyboard: a one-row **AI bar** when a provider is configured
("Draft reply", "Shorter", "Friendlier", "Formal", free instruction) — the
desktop `Cmd+J` popover, as an input accessory. Attachments via the Photos
picker and the Files picker; 25 MB guard. Send is optimistic through the
outbox, with the same retry semantics as desktop.

### Scheduled, Need reply, Labels

Scheduled (its own tab) groups by due date: Overdue · Today · Tomorrow ·
This week · Later. Need reply (its own tab) is a plain list. Labels are the
same rows filtered by `label:<id>`, reachable from the Inbox title menu;
label management (rename, colour, delete) stays in Settings.

### Settings

The desktop's sections, same order, same wording:

- **Accounts** — avatar, name, email, connection state; Name, Color (the
  five tags), Sync (reminder sync over the account's Drive app folder),
  Signature; Reconnect, Remove (asks once); Add account.
- **AI** — ChatGPT (OpenAI): paste a key (verified before it is stored),
  Model, Auto-summarize, Remove. Powers "Summarize N active" on the day
  groups, "Summarize thread", the ✨ draft reply, and Edit with AI in
  compose (tone and edit presets or a freeform instruction).
- **Triage** — Jev: key (verified), Auto-triage, Reanalyze all emails, the
  labels (add; swipe to remove). Classification runs at the end of every
  sync round, bounded per round, never on its own timer. The labels are the
  bottom pill and the chips on rows; a thread's labels can be edited by hand
  (sticky until Reanalyze).
- **Inbox** — Pinned list; Swipe actions (the four tiers).
- **Appearance** — System · Light · Dark (iOS only; the desktop follows
  the system).
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

- Empty inbox is a designed moment: the pigeon, "All clear", the time of the
  last sync. Not a shrug.
- Loading is skeleton rows, never a spinner in the list.
- The only animation of note is archive: the row slides out in ~150 ms with
  a light haptic. Everything else is the system's.
- Dark mode from day one, following the system. Colours come from the same
  tokens as `desktop-app/src/styles/colors.css` (navy scale, pink accent,
  five account tags).
- Typography: Manrope for titles and sender names (brand), the system font
  for body text and the mail content (legibility, Dynamic Type for free).
  Every custom size is declared `relativeTo` a text style so Dynamic Type
  scales it.

### iPad and hardware keyboards

`NavigationSplitView` gives the sidebar · list · thread layout for free on
iPad, and SwiftUI's `.keyboardShortcut` brings the desktop keyboard map
back 1:1 when a keyboard is attached: `j`/`k`/`e`/`u`/`h`/`n`/`/`/`⌘K`.
Not an M1 goal, but the structure above does not have to change for it.

## Platform constraints and how we handle them

| Concern | Desktop today | iOS |
| --- | --- | --- |
| OAuth redirect | Loopback `127.0.0.1:<port>` | **Reversed-client-id scheme** via `ASWebAuthenticationSession`. Google requires an **"iOS" OAuth client** (no secret). `oauth::AuthRequest` is the shared piece; `oauth::authorize` stays the desktop loopback wrapper. |
| Client secret | Required by Desktop-app clients | None. `ClientConfig.client_secret` is now `Option`. |
| Secrets | OS keychain (`keyring`) | iOS Keychain through the same crate (`apple-native` covers iOS). Items are per app; not iCloud-synced in v1. |
| Sync cadence | 30 s poll loop in Rust | **The shell owns cadence.** Foreground: sync on launch, on every foreground, on pull. Background: `BGAppRefreshTask` (iOS decides when; expect a few times a day). No loop inside the engine. |
| New-mail push | Polling | **Optional relay** (issue #16, `relay/`, `terraform/`): Gmail `users.watch` → Pub/Sub → Cloud Run → silent APNs push → the phone runs one delta sync and composes the notification locally; badge = unified unread. The relay sees email + historyId, never mail. Off by default — local-first still means the inbox is current the moment the app opens. Settings → Notifications → "New mail (push)" + relay URL. |
| Reminder notifications | Posted from the poll loop | **Local notifications**, scheduled ahead from `list_scheduled()` on every sync (next 7 days, replaced wholesale each time). Works fully offline, no server. Follow-ups cancel on the next sync that sees a reply. |
| Mail HTML | Sandboxed iframe, CSP | `WKWebView` with scripts off, CSP meta, remote images blocked, links to Safari VC. Same sanitized HTML. |
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

## Out of scope

Android (the same `ffi` crate would bind through UniFFI's Kotlin generator,
but nobody is asking), the App Store, generic IMAP, any server beyond the
optional metadata-only push relay (`relay/README.md`).
