# CLAUDE.md — Hey Pigeon for Mac

Guidance for Claude (and anyone) changing the native Mac app. Read
`../ios-app/CLAUDE.md` first: its ground rules (one state object, the
engine is the truth, reload is the funnel, platform code in
`Platform.swift`, privacy copy, Swift 6) all hold here. This file is what
is different on the Mac.

## What this is

A macOS 27 target over the phone's sources. `project.yml` compiles
`../ios-app/HeyPigeon` (minus the two iOS app files) together with
`HeyPigeonMac/`; the widgets and tests targets reuse the phone's folders
too. There is no second model, engine or intent layer.

```text
HeyPigeonMac/
  App/        HeyPigeonMacApp (scenes, commands, deep links), MacAppDelegate, MacSyncLoop, MacCommands,
              MacUpdater (Sparkle: the feed publish-macos writes, the app menu's Check for Updates…)
  Features/   MainWindow (sidebar + NavigationStack or Settings), MainToolbar, SearchSpotlight,
              MacStyle (the look), SidebarColumn, InboxPage (list, search filters, batch bar), MailRow
              (the row and its in-place preview), ThreadPage (ThreadView; ThreadWindow), WindowState,
              CommandPalette, ShortcutsSheet, MenuBarExtraView
HeyPigeonMacShare/   the share extension's NSViewController (the view is ../ios-app/HeyPigeonShare/ShareView.swift)
HeyPigeonMacTests/   the Mac window's own tests; the phone's tests run here too
```

## Ground rules

- **Shared first.** A screen, a sheet, a model method or an intent belongs
  in `../ios-app/HeyPigeon` with a platform gate, not in a Mac copy. The
  Mac folder holds only what has no phone twin: the window, the sidebar
  and list columns, the menus, the keyboard map, the palette, the menu
  bar extra, the timer sync.
- **Never change the phone by accident.** Every `#if os(iOS)` /
  `#if os(macOS)` branch keeps the iOS side what ships; new iOS-only
  modifiers go behind a helper in `Platform.swift` (`sheetSize`,
  `dismissKeyboardOnScroll`, `hidesTabBar`, `alwaysShownSearch`,
  `siriEntity`, …), never a bare `#if` in a feature file. `ios-ci` and
  `macos-ci` both run on a PR that touches the shared folder.
- **One window state object.** `WindowState` is per window (AppModel is
  per process): the open thread (`path`, the NavigationStack's, at most
  one deep), the highlighted rows, the drawer, the search, the sheets, the
  keyboard map and every action. Keys, menus, hover buttons, trackpad
  swipes and the palette all call `WindowState.run(_:in:rows:)`, which acts
  on the open thread else the highlighted rows (`focusRow`) and calls
  AppModel like the swipes do. Pure logic is static (`KeyboardMap.resolve`,
  `PaletteFilter`), tested in `HeyPigeonMacTests`.
- **The first desktop client's shape under a standard toolbar.** The
  window has the unified toolbar with no title
  (`.windowToolbarStyle(.unified(showsTitle: false))`,
  `.toolbar(removing: .title)`), so the traffic lights are where macOS
  puts them and behave as they do. (Two earlier rounds hid the toolbar
  and drew a top bar of our own; the traffic lights vanished, then had to
  be moved by hand and still felt wrong.) `MainToolbar` holds the
  sidebar button and the view's title at the leading end, summarize /
  ask / new message / search at the trailing end — no Settings gear:
  Settings is in the app menu (⌘,) and the palette, and opens as a page
  of the window (`WindowState.showSettings`, a grouped form through
  `SettingsList`). A full thread adds the shared ThreadView's own toolbar
  items and the navigation stack's Back; a shared view's sheet-only item
  goes behind a helper (`sheetCloseButton`). The triage labels are the
  phone's glass pill (`TriageSplitBar`) at the bottom of the list. Search
  is a Spotlight panel (`SearchSpotlight`, Liquid Glass) over the
  blurred window. Rows (`MailRow`) are single lines with a done circle,
  like the Svelte client's to-do rows; a click opens the row **in place**
  (`WindowState.expanded`, the latest message and "Open full thread ›"),
  Return or the row's arrow opens the full thread (`path`). A card's
  shadow goes on its background shape only — on the card it shadows the
  message's web view too. Scroll bars are hidden
  (`.scrollIndicators(.never)`). The list and the thread keep to
  `MacLayout.maxWidth`.
- **Bare letters only through `onKeyPress`.** A single-letter menu key
  equivalent steals the letter from every text field on macOS, so the
  Superhuman map lives in `WindowState.handle` (attached to the list, the
  detail and the window) and menu items carry ⌘-based equivalents. The
  window's handler sees keys before a text field inside it does, so
  `handle` ignores every key while the first responder is typing
  (`WindowState.isTyping`: an NSTextField or an editable NSTextView). After a
  chord changes the folder, ask the list for focus back
  (`listFocusRequest`): `AppModel.tab`'s didSet drops the first responder.
- **Auto-advance is opt-in in the list, always on in a thread.** In the
  list, set `pendingAdvance` (through `run`) before an action that may
  remove the highlighted row; a folder switch clears the highlight
  instead. With a thread open, its row leaving the list opens the next
  one (`rowsChanged`, `closeOpen`), and a folder switch closes it.
- **Sync is the timer.** No BGTaskScheduler on the Mac; `MacSyncLoop` runs
  a round every 30 s and composes new-mail banners from its diff
  (`NewMailNotifier.post`). The Mac build has no push entitlement — it is
  signed with Developer ID and no provisioning profile, which also makes
  the App Group the team-prefixed name (`AppGroup.identifier` reads it
  from the Info.plist) — so the relay is the phone's.
- **Widgets act through links.** A Mac widget's button runs in the
  extension, which has no engine; Done and Snooze are
  `heypigeon://done/<id>` and `heypigeon://snooze/<id>/<h>`
  (`AppGroup.Link`, `DeepLink`), handled by `AppModel.handle`.
- **Updates are Sparkle, configured in `project.yml`, not in code.**
  `SUFeedURL` is the appcast `publish-macos` uploads to the `mac-latest`
  release; `SUPublicEDKey` comes from the `SPARKLE_PUBLIC_ED_KEY` build
  setting (empty in CI and in a checkout without `Local.xcconfig`, which
  keeps the updater off — `MacUpdater.isConfigured`). Automatic checks and
  installs are Info.plist defaults; `MacUpdater` only mirrors Sparkle's
  state for the menu and Settings › Updates. `CFBundleVersion` is the
  publish run number, so it only grows; never give a build a lower one.
- **System callbacks are not on the main thread on the Mac.** AppKit and
  the frameworks behind it hand completion handlers back on XPC queues
  (`ASWebAuthenticationSession` did, and the first build crashed on Swift
  6's executor check). A closure handed to such an API is `@Sendable` and
  only resumes a continuation or hops to the main actor; a delegate
  method the framework may call off the main thread is `nonisolated` and
  reads state captured on the main actor beforehand (`OAuthCoordinator`).
- **Copy says "Mac" through `Device.name`**, and Settings sections that
  differ (Default email app, Notifications, Siri & Search, the swipe
  titles) branch on `#if os(macOS)` inside `SettingsView` with their own
  footer strings — the privacy sentence must stay true on both.

## Building and testing

Nothing Swift compiles on Linux; the source of truth is CI
(`.github/workflows/macos-ci.yml`: Rust macOS slice, `xcodegen generate`,
`xcodebuild test -destination 'platform=macOS'`, unsigned, mock engine).
Locally on a Mac: `PLATFORM_NAME=macosx scripts/build-rust.sh`,
`xcodegen generate`, then the same `xcodebuild test`. `HEYPIGEON_MOCK=1` in
the scheme runs the app on the sample inbox.

## Generated / ignored

`HeyPigeonMac.xcodeproj`, the `Info.plist`s and the entitlements are
generated by XcodeGen from `project.yml` — edit `project.yml`, never the
outputs. The Rust package is the phone's (`../ios-app/HeyPigeonCore`).
`Config/Local.xcconfig` holds the team id and the OAuth client (git-ignored).
