# CLAUDE.md — Hey Pigeon for iOS

Guidance for Claude (and anyone) changing the iOS app. Read this first,
then `README.md` (build, publishing, where things live) and
`../docs/ios.md` / `../docs/ios-intelligence.md` for the design behind it.

## What this is

A SwiftUI shell (iOS 27+, iPhone and iPad) over the shared Rust core in
`../desktop-app/crates` (Gmail, SQLite, Drive sync, AI routing). The Swift
side owns UI, sync cadence, notifications, Siri/App Intents, Spotlight,
widgets and the Foundation Models backends; everything about mail itself
lives in Rust and comes through the UniFFI `Engine`.

```text
HeyPigeon/
  App/        HeyPigeonApp (scene, deep links, scene phase), AppModel (all state + actions), AppDelegate (APNs)
  Engine/     Models.swift (app models + the MailEngine protocol), RustEngine (UniFFI adapter), MockEngine, OAuth
  Features/   SwiftUI screens: Inbox, Thread, Compose, Search, Sidebar, Settings, Remind
  Intents/    App Intents, entities, Mail schema, Spotlight indexer, donations
  AI/         Foundation Models backend + providers, triage prompt/agent/tools, Ask my inbox, attachments, translation, usage
  Shared/     Platform (UIKit/AppKit door), Theme, Formatters, notifications, widgets snapshot, Live Activities, deep links
    WidgetShared/  compiled into the app AND both extensions — Foundation/SwiftUI/AppIntents/ActivityKit only
HeyPigeonWidgets/  widget extension (reads the App Group snapshot; never links Rust)
HeyPigeonShare/    share extension (writes a PendingShare; never sends)
HeyPigeonTests/    Swift Testing over MockEngine; Evaluations/ for the prompt harnesses
```

## Ground rules

- **One state object.** Views read `AppModel` from the environment; every
  mutation goes through an `AppModel` method so optimistic UI, undo, the
  badge, widgets and Spotlight stay consistent. Intents call the same
  methods as the swipes (`IntentSupport.model()`), never the engine.
- **The engine is the truth.** `MailEngine` reads are synchronous and local;
  anything that can touch the network is `async`. Map FFI records to app
  models in `RustEngine.swift` only. Keep `MockEngine` behaving like the core
  (its comments say which rule it mirrors) — the tests run on it.
- **Reload is the funnel.** A reload reads the current view, the folder
  counts and the cross-account lists (reminders, Need reply, the unread
  counts the badge and widgets show) in one `ListSnapshot` and lands it
  with `apply`, which assigns each property only when it moved. The
  engine's change notices go through `reloadSoon()`: one read per burst,
  off the main actor (`MailEngine.readInBackground`), and the pages on
  screen are kept. Navigation and the user's own actions call `reload()`
  so the result is there when they return. The badge, the widgets, the
  reminder notifications and the Lock Screen widgets read the model's last
  snapshot, never the store. Change several navigation properties
  together with `navigate(to:folder:)` (one reload), not one assignment
  after another.
- **The main thread only draws.** Store reads that are not a single row
  go through `MailEngine.readInBackground` (`StoreReader`); the Spotlight
  refresh plans its work there too. Views read ids through the model's
  maps (`account(for:)`, `bundle(id:)`, `triageLabelName`), which change
  only when their source does, so a reload that moved nothing redraws no
  row. No `.animation(value:)` keyed on the rows on a `List`.
- **The roots share their chrome.** The toast (`ToastStack`), the
  disconnected alert and the row sheets (`sharedSheets`) are
  `Shared/RootChrome.swift`, used by the phone's root, the Mac window and
  the Bundles cover. Something undoable gets `show(_:undo:)`, not a
  dialog: a discarded draft comes back through `discardDraft` /
  `discardSavedDraft`.
- **A banner's buttons act through the model.** Mark Done, Remind Me in 1
  Hour and Reply (`NotificationActions`) are registered and acted on in
  `NewMailNotifier` (`registerActions`, `perform`) for both apps; each
  app delegate only hands the action over. In the background the phone
  holds a `BackgroundGrace` until the change has left the outbox.
- **The network path is `Connectivity.shared`.** Offline shows as a line
  over the list (`OfflineBar`) with `AppModel.queuedChanges`; bodies are
  fetched ahead of a tap only on an unmetered path
  (`AppModel.prefetchBodies`). No send-later on the phone
  (`ComposePresentation.offersSendLater`): iOS decides when the app runs.
- **The iPad's columns are a layout, not a second app.** At regular
  width on an iPad `RootView` shows `PadSplitView` (`Features/Pad`): the
  sheet's `SidebarList`, the phone's `ThreadList` and `ThreadView` side
  by side; anywhere else, the tabs. What is open belongs to `PadState`
  (owned by `RootView`, so it outlives a resize across the width where
  the layouts swap; with the auto-advance and the key map, `PadKeys`),
  never to `AppModel`. The keys are key equivalents on buttons that draw
  nothing, not focus-based `onKeyPress`: nothing has to hold the focus,
  and a text field gets a bare letter first. The open thread's `e` `h`
  `n` `s` `r` `⌘⌫` are ThreadView's own (`threadKey`): do not bind them a
  second time. A new place must be reachable from `SidebarList` too,
  since the columns have no tab bar.
- **Mute and block are the app's own rules**, two synced prefs the core
  applies at the end of every sync (`mute.threads`, `block.senders`;
  `AppModel.mute`, `.block`). Gmail's API has no mute and its filters need
  a scope the app does not ask for. A rule acts once per arrival and
  never against the user: Not spam unblocks the sender, Move to inbox
  unmutes the thread. The Outbox (Settings › Outbox,
  `OutboxView`; `AppModel.openOutbox`) is where a change that could not be sent waits for the
  user; `failedChanges` puts a line over the list while there is one.
- **A message's HTML is sanitized by the core** and its tracking pixels
  replaced by a marker the view counts (`MailDocument.trackerCount`).
  What tells the reader something about a mail's safety must not be the
  mail's to forge or hide: the core strips `hp-` classes from incoming
  mail, the link note is styled inline and counted by the script
  (`linkWarningScript`), and the count is said again in the app's own
  chrome, where the mail's styles do not reach.
  `MailDocument` holds the page and its scripts; `RenderTests` loads the
  same page in a real web view, and `HeyPigeonUITests` launches the app on
  the sample inbox. Every wait in a test has a timeout.
- **SwiftUI `List` aborts on duplicate ids.** Rows go through
  `AppModel.unique`; keep it that way when adding sources of rows.
- **Platform code goes in `Shared/Platform.swift`.** Haptics, keyboard,
  clipboard, app state, system settings, APNs registration, toolbar
  placements (`.barLeading` / `.barTrailing`), `inlineNavigationTitle()`,
  `plainInput(_:)`, `Color(light:dark:)` and `Device.name`; Reduce Motion
  (`Motion.animation`, for anything the app animates itself), VoiceOver
  (`VoiceOver.announce`; `AppModel.show` speaks every toast) and
  `tapArea` for a control drawn smaller than 44 pt. Do not import
  UIKit in a feature file for these. Copy that names the device uses
  `Device.name` ("On this \(Device.name)"), never a literal "iPhone".
- **Privacy copy must be true.** Settings and sheet footers say what
  leaves the device; when you change what an AI call sends, change the
  sentence (see `SummarySheet.footnote`). App Intent descriptions must not
  contain "iPhone" or "Siri" (App Store Connect error 90626).
- **Free-text settings save on a pause** (`AppModel.savePrefSoon`,
  `prefSaveDelay`), toggles save at once; every pref write is a synced
  write to the user's other devices.
- **Simulator vs device SDK.** Some iOS 27 APIs exist only in the device
  SDK (Vision's `OCRTool`/`BarcodeReaderTool`). Gate them with
  `#if targetEnvironment(simulator)` so `ios-ci` keeps compiling.
- **Swift 6 language mode**, main-actor UI. Engine callbacks arrive on Rust
  threads and hop to the main actor (`RustEngine.Listener`); shared mutable
  state touched from those threads needs a lock (`Mutex`, `NSLock`).

## Style

Match the surrounding code: comments explain *why* in plain sentences
(what broke before, which desktop file a rule mirrors), not *what*. Doc
comments (`///`) on every type and non-obvious member. Short names inside
small scopes, full names at API level. User-facing words follow the
desktop ("Mark done", "Need reply", "Remind me"). No force unwraps outside
literals and tests.

## Building and testing

No Mac is needed to change code, but nothing Swift can be compiled on
Linux beyond pure-Foundation helpers. The source of truth is CI:

- `.github/workflows/ios-ci.yml` (every PR touching `ios-app/` or the Rust
  crates): builds the Rust simulator slice, `xcodegen generate`, then
  `xcodebuild test` on an iPhone simulator and `xcodebuild build` on an
  iPad one. Unsigned, no secrets, empty OAuth client → the app runs on
  `MockEngine`. A failed run uploads the `.xcresult` and the full log.
- `.github/workflows/publish-ios.yml` (pushes to `main`): signs and uploads
  to TestFlight. Never merge with `ios-ci` red: main ships.

Locally, on a Mac: `scripts/build-rust.sh`, `xcodegen generate`, then
`xcodebuild test -project HeyPigeon.xcodeproj -scheme HeyPigeon -destination 'platform=iOS Simulator,name=<an iPhone>' CODE_SIGNING_ALLOWED=NO`.
`HEYPIGEON_MOCK=1` in the scheme runs the app on the sample inbox.

Tests use Swift Testing (`@Test`, `#expect`) over `MockEngine`; build the
model with `AppModel(engine: MockEngine())` (it registers itself as
`AppModel.current`, which intents read). `ModelTests.swift` has
`makeRow` / `makeMessage` helpers. Pure logic belongs in static functions
so it can be tested without a view (`AppModel.group`, `AppModel.people`,
`ThreadDetail.foldedRange`, `SwipeGeometry`, `SpotlightIndexer.fingerprint`).
Model-dependent evaluations are gated with
`.enabled(if: AppleIntelligenceProvider.isAvailable)`.

## Generated / ignored

`HeyPigeon.xcodeproj`, `Info.plist`s and entitlements are generated by
XcodeGen from `project.yml` — edit `project.yml`, never the outputs.
`HeyPigeonCore/Sources` and the xcframework come from `scripts/build-rust.sh`.
`Config/Local.xcconfig` holds the team id and OAuth client (git-ignored).

## Porting

`HeyPigeon/` is also the native Mac app's shell (`../macos-app`,
`../macos-app/CLAUDE.md`): every file here except `App/HeyPigeonApp.swift`
and `App/AppDelegate.swift` compiles for macOS, so a change here runs on
both — `ios-ci` and `macos-ci` check it. Keep new code inside that shape:
no new direct UIKit use outside `Platform.swift` and the representables
(`MessageBodyView`), iOS-only modifiers behind a `Platform.swift` helper,
and copy that names the device through `Device.name`. The iPad plan and
the Mac's status are in `../docs/porting-macos-ipados.md`.
