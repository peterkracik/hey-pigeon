# Porting the iOS app to iPadOS and macOS

Where the SwiftUI app stands for the iPad and the native Mac app, and what
is left to do. The native Mac app exists (`macos-app/`, built and tested by
`macos-ci`, published by `publish-macos`) and replaced the Tauri desktop
app (`desktop-app/`) as the Mac download; that app's shell is no longer
built, its Rust crates are the core. This document is the iPad plan and
the record of how the Swift shell — with its Siri, Spotlight, Foundation
Models and widget work — reached the Mac.

## Where it stands

| | iPadOS | macOS (native SwiftUI target, `macos-app/`) |
| --- | --- | --- |
| Builds | Yes: `TARGETED_DEVICE_FAMILY` is `1,2`; `ios-ci` builds for an iPad simulator on every PR | Yes: `macos-ci` builds and tests on every PR; `publish-macos` notarizes a zip on every push to `main` (the `mac-latest` release, with the Sparkle appcast installed apps update from) and on `mac-v*` tags |
| Platform calls | Behind `Shared/Platform.swift` | The AppKit branches of `Platform.swift`, compiled |
| Layout | The phone's `TabView` + `NavigationStack`, full screen | Sidebar · list · thread (`NavigationSplitView`), Settings as a window, a thread in its own window |
| Keyboard | `e` `h` `n` `s` `r` `⌘⌫` on a thread, `⌘N` compose | The desktop's whole map (`WindowState.handle`), menus with ⌘ equivalents, ⌘K palette |
| Device copy | `Device.name` → "iPad" | `Device.name` → "Mac" |
| Rust core | Same xcframework slices (`aarch64-apple-ios`, `-sim`) | `aarch64-apple-darwin` from the same `build-rust.sh` when `PLATFORM_NAME=macosx` (macOS 27 is Apple Silicon only; `ARCHS` can still add `x86_64`) |

## The platform layer

`ios-app/HeyPigeon/Shared/Platform.swift` is the only place feature code
should reach UIKit or AppKit:

| Need | API |
| --- | --- |
| Device name in copy | `Device.name` |
| Light/dark colour | `Color(light:dark:)` |
| Resign the keyboard | `Keyboard.dismiss()` |
| Haptics | `Haptics.archive()` / `.light()` / `.success()` / `.warning()` |
| Copy text | `Clipboard.copy(_:)` |
| App in front? | `AppLifecycle.isActive` |
| APNs | `RemoteNotifications.register()` / `.unregister()` |
| System Settings | `SystemSettings.openAppSettings()` / `.openDefaultApps()` |
| Toolbar ends | `ToolbarItemPlacement.barLeading` / `.barTrailing` |
| iOS-only modifiers | `inlineNavigationTitle()`, `plainInput(_:)`, `groupedListStyle()` |

The platform door also hides the modifiers that exist on one platform
only, so a feature file never writes a bare `#if`: `sheetSize` (detents on
iOS, a frame on the Mac), `dismissKeyboardOnScroll`, `hidesTabBar`,
`alwaysShownSearch`, `hidesNavigationBarInCompactWidth`, `siriEntity`, and
`Theme`'s `menuSectionSpacing` / `menuSheet`. `PlatformImage`,
`PlatformFont` and `PlatformColor` name the UIKit / AppKit types for the
few places that draw (the notification avatar, the attachment downscale).

## iPadOS: next steps

1. **Split view.** Replace the per-tab `NavigationStack` in
   `Features/Inbox/InboxView.swift` (`MailListScreen`) with a
   `NavigationSplitView` when `horizontalSizeClass == .regular`: sidebar
   (`SidebarSheet`'s list as a column) · thread list · `ThreadView`.
   `MailListScreen.path` becomes the detail selection; the compact layout
   keeps the stack. `SearchScreen` already reads the size class.
2. **List keyboard.** `j`/`k` selection and `/` for search need a selected
   row in `ThreadList` (the split view's selection gives one).
3. **Multiple windows.** `AppModel` is one per process (`AppModel.current`);
   per-window state (open thread, sheets) would move into a scene-scoped
   object before `UIApplicationSupportsMultipleScenes` is turned on.
4. **Pointer.** `SwipeableRow`'s drag tiers work with a trackpad swipe; a
   hover action bar like the desktop's would be the iPad-native addition.

## macOS: how the native target is built

`macos-app/project.yml` compiles `ios-app/HeyPigeon` (every file but
`App/HeyPigeonApp.swift` and `App/AppDelegate.swift`) with the Mac-only
sources in `macos-app/HeyPigeonMac`. The table that used to list what
needed a twin, as it was resolved:

| File | iOS-only API | What the Mac compiles |
| --- | --- | --- |
| `App/AppDelegate.swift`, `App/HeyPigeonApp.swift` | `UIApplicationDelegate`, `TabView` | `macos-app/HeyPigeonMac/App/MacAppDelegate.swift` (`NSApplicationDelegate`, same APNs and notification callbacks, the Dock menu) and `HeyPigeonMacApp.swift` (the scenes) |
| `App/AppModel.swift` | `BGTaskScheduler` | The two refresh functions are `#if os(iOS)`; the Mac syncs on a timer (`MacSyncLoop`) |
| `Shared/NewMailNotifier.swift` | `UIBackgroundFetchResult`, `UIGraphicsImageRenderer` | `FetchResult` is a plain enum on the Mac; the avatar is an `NSImage` |
| `Features/Thread/MessageBodyView.swift` | `UITextView`, `WKWebView` representables | `NSTextView` and `WKWebView` twins (`NSViewRepresentable`); the web view passes scroll wheel events up so the thread keeps scrolling |
| `AI/AttachmentUnderstanding.swift` | `UIImage` | `PlatformImage` (`NSImage` on the Mac) throughout |
| `Shared/*LiveActivityController.swift`, `WidgetShared/*ActivityAttributes.swift` | `ActivityKit` | `#if canImport(ActivityKit)`, with no-op controllers on the Mac |
| `WidgetShared/WidgetIntents.swift` | `LiveActivityIntent` | `InAppWidgetIntent` is `LiveActivityIntent` on iOS, `AppIntent` on the Mac; the Mac widgets act through `heypigeon://done` and `heypigeon://snooze` links instead |
| `HeyPigeonWidgets/*` | Live Activities, Controls, Lock Screen families | Gated out; `WidgetDoneButton` / `WidgetSnoozeButton` are intents on iOS and links on the Mac |
| `HeyPigeonShare/ShareViewController.swift` | `UIViewController` | The view moved to `ShareView.swift` (shared); `macos-app/HeyPigeonMacShare` hosts it in an `NSViewController` and opens the app through the extension context |
| `Theme.swift`, the sheets | `listSectionSpacing`, `presentationDetents`, `scrollDismissesKeyboard`, `navigationBarDrawer`, `toolbar(.hidden, for: .tabBar)` | The `Platform.swift` helpers above |
| `Features/Settings/SettingsView.swift` | iOS Settings doors, the relay toggle's copy | `#if os(macOS)` sections: the default-mail-app button asks macOS and shows the state, Notifications has the local new-mail switch, the swipe titles and footers say what the Mac does |

What is Mac-only, in `macos-app/HeyPigeonMac/Features`:

- `MainWindow` — the split view, the sheets, the toast, the disconnected alert.
- `SidebarColumn` — accounts, folders (Scheduled and Need reply among them), labels, Add account · Settings.
- `ThreadListColumn` — title and account menu, the toolbar search with the Search tab's filter bar and recent searches, the rows with the hover bar and the trackpad swipes, the Jev pill.
- `ThreadDetailColumn` — the shared `ThreadView` for one selection, a batch bar for several, `ThreadWindow` for a thread in its own window.
- `WindowState` — the selection, auto-advance, `KeyboardMap` (the desktop's keys and `g`-chords) and every action.
- `CommandPalette` (⌘K, with the `l` / `v` stages), `ShortcutsSheet` (`?`), `MenuBarExtraView`.

Rules that came out of it are in `macos-app/CLAUDE.md`: shared first, no
bare `#if` in a feature file, bare letters only through `onKeyPress`,
auto-advance opt-in, sync is the timer, widgets act through links.

Bundle ids: the Tauri app had `app.heypigeon`; the native Mac app is
`app.heypigeon.mac` (its extensions `app.heypigeon.mac.widgets` and
`.share`), so an old install and the new one sit side by side and neither
can update into the other — the native app is installed once by hand and
then updates itself (`MacUpdater`, `publish-macos.yml`).

## Rules while porting

- No new `import UIKit` outside `Platform.swift`, the representables and the
  files in the table above.
- Copy names the device through `Device.name`.
- Every platform branch keeps the iOS branch byte-for-byte what ships, so
  a port never changes the phone app by accident; `ios-ci` checks the
  iPhone and iPad builds on each change, and `macos-ci` the Mac.
