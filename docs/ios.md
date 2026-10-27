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

Three levels, no tab bar, no hamburger:

```text
Inbox (root)  ──push──►  Thread  ──sheet──►  Reply / Compose
  │
  ├─ title tap ─► Views menu (Inbox · Scheduled · Need reply · Starred · Drafts ·
  │               Sent · Archive · All mail · Spam · Trash · ── Labels…)
  ├─ avatar tap ─► Accounts sheet (All · account A · account B · + Add · Settings)
  ├─ pull down ──► Search (same FTS5 engine, same operators as desktop)
  └─ compose ───► Compose sheet
```

- **Root is the Inbox**, unified across accounts by default (desktop's `0`).
  The large title names the current view; tapping it opens the views menu —
  this is the sidebar, as a menu. It is the native `.toolbarTitleMenu`
  affordance, so it costs no chrome.
- **Accounts live behind the avatar chip** top-left: stacked account dots,
  tap to filter to one account (desktop's `1`/`2`), with "Add account" and
  "Settings" at the bottom of the same sheet. Long-press cycles accounts.
- **Search is the pull-down field** under the title. Results replace the list
  in place; the query syntax is Gmail's, exactly as on desktop.
- **Triage chips** (Jev labels + priority) appear as one horizontally
  scrolling row under the title *only when Jev is configured*. Unconfigured
  users never see them — clean by default, everything reachable when wanted.
- **Compose** is the only persistent button (top-right pencil). Floating
  buttons were rejected: they cover the last row, which is where the user is
  looking when they finish triaging.

### Rows and groups

Same anatomy as desktop, one line shorter:

```text
[dot] Sender name                                   10:42
      Subject line · first line of the snippet…     📎 ⏰ ↩︎
```

- Account dot only in the unified view (hidden when filtered to one account).
- Unread: sender in semibold plus a 3-pt accent bar on the leading edge. No
  sea of bold.
- Badges, right-aligned under the time, only when true: attachment, reminder
  (with "if no reply" variant), needs reply, priority dot.
- **Day groups** ("Today", "Yesterday", "Mon 23") as sticky section headers,
  exactly the desktop grouping. When auto-summarize is on, the day's AI
  summary is a soft card under the header, collapsible per group (desktop's
  `i`).
- Pagination is keyset (`before = last row's last_msg_at`), 50 rows a page,
  so the list is as cheap 10,000 threads deep as at the top.

### Gestures (the keyboard map, translated)

| Desktop | iOS | Notes |
| --- | --- | --- |
| `e` archive | **swipe right, full** | The "check off" moment: accent fill, haptic, row slides out. Undo toast for 5 s. |
| `u` read/unread | swipe right, short | |
| `h` remind me | **swipe left, first action** | Opens the Remind sheet (below) |
| `n` need reply | swipe left, second action | Toggles; row gets the ↩︎ badge |
| `#` trash, star, labels | swipe left, "…" | Also all in the long-press menu |
| `enter` open | tap | |
| `esc` back | back / edge swipe | |
| `j`/`k` | scroll | After archiving from inside a thread: pop back (default) or advance to the next thread (setting) |
| `/` search | pull down | |
| `cmd+k` palette | long-press a row | Context menu with preview: Archive, Read/Unread, Star, Remind me…, Need reply, Labels…, Trash |
| `0`/`1`/`2` accounts | avatar chip | |
| `g i` / `g a` | title menu | |
| `?` | — | Not needed; gestures are discoverable |

Multi-select: the native List edit mode (Edit button, or two-finger drag
down the rows) shows a bottom bar with Archive · Read · Remind · Trash.

Pull-to-refresh runs `sync_all`. The app also syncs on every foreground.

### Remind sheet

Half-height sheet with presets in a 2×3 grid — *Later today (18:00)*,
*Tomorrow (09:00)*, *This weekend*, *Next week*, *In a month*, *Pick date…* —
a toggle **"Only if nobody replies"** (desktop's follow-up), and a *Remove
reminder* row when one is set. Times respect the user's locale and a
"day starts at" setting (default 09:00).

### Thread view

Pushed onto the stack. Inline title is the subject; the list below shows the
latest message expanded and older ones collapsed to one-line rows (sender ·
first line · time), tap to expand — same as desktop.

- **Body** renders in a `WKWebView` with JavaScript off, a strict CSP meta
  tag, `about:blank` origin and remote images blocked by default; a one-tap
  "Load images" bar per sender remembers the choice. The HTML is the
  ammonia-sanitized body the core already stores. Links open in
  `SFSafariViewController`; the real URL is shown in a long-press preview.
- **Attachments** are chips under the message: tap fetches the bytes
  (`messages.attachments.get`, cached) and opens Quick Look. Never auto-open.
- **AI summary** card at the top when a summary exists or auto-summarize is
  on; "Summarize" in the toolbar menu otherwise.
- **Bottom toolbar** (the only toolbar in the app): Archive · Remind ·
  Need reply · **Reply** · More (Star, Labels, Mark unread, Forward,
  Summarize, Trash).
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

Scheduled groups by due date: Overdue · Today · Tomorrow · This week ·
Later. Need reply is a plain list. Labels are the same rows filtered by
`label:<id>`, reachable from the title menu; label management (rename,
colour, delete) stays in Settings.

### Settings

Accounts (colour, display name, signature, connection and sync state,
Reconnect, Remove) · AI provider (key paste, model, auto-summarize) · Jev
triage (key, enabled, labels, reanalyze) · Notifications · Appearance
(system / light / dark) · About. Account removal and anything that deletes
asks once.

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
| New-mail push | Polling | **Not in v1.** Real push needs APNs, i.e. a relay — DESIGN.md's "one true server case". Local-first means the inbox is current the moment the app opens; that is the v1 promise. Optional self-hostable relay later, metadata only. |
| Reminder notifications | Posted from the poll loop | **Local notifications**, scheduled ahead from `list_scheduled()` on every sync (next 7 days, replaced wholesale each time). Works fully offline, no server. Follow-ups cancel on the next sync that sees a reply. |
| Mail HTML | Sandboxed iframe, CSP | `WKWebView` with scripts off, CSP meta, remote images blocked, links to Safari VC. Same sanitized HTML. |
| Attachments | Disk LRU cache | Same core logic; cache in the app container, relative paths. |
| Cross-device state | Drive `appDataFolder` | Identical — the same adapter runs; reminders and flags set on the phone show on the Mac within a poll. |
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
but nobody is asking), the App Store, generic IMAP, any server.
