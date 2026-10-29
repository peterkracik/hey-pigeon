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
  AI/         Foundation Models backend + providers, triage prompt/agent/tools, Ask my inbox, attachments, usage
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
- **Reload is the funnel.** `AppModel.reload()` re-reads the current view,
  counts and the cross-account reminder list (`scheduledAcrossAccounts`),
  then refreshes the badge and widget snapshot once per main-actor turn.
  Change several navigation properties together with `navigate(to:folder:)`
  (one reload), not one assignment after another.
- **SwiftUI `List` aborts on duplicate ids.** Rows go through
  `AppModel.unique`; keep it that way when adding sources of rows.
- **Platform code goes in `Shared/Platform.swift`.** Haptics, keyboard,
  clipboard, app state, system settings, APNs registration, toolbar
  placements (`.barLeading` / `.barTrailing`), `inlineNavigationTitle()`,
  `plainInput(_:)`, `Color(light:dark:)` and `Device.name`. Do not import
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

The Mac and the iPad plan, with the file-by-file list of what still needs
a platform twin, is `../docs/porting-macos-ipados.md`. Keep new code inside
that plan: no new direct UIKit use outside `Platform.swift` and the
representables listed there.
