# Porting the iOS app to iPadOS and macOS

Where the SwiftUI app stands for the iPad and a native Mac build, and what
is left to do, file by file. The desktop Tauri app (`desktop-app/`) stays
the Mac product for now; this is about bringing the Swift shell — with its
Siri, Spotlight, Foundation Models and widget work — to the other two
platforms.

## Where it stands

| | iPadOS | macOS (native SwiftUI target) |
| --- | --- | --- |
| Builds | Yes: `TARGETED_DEVICE_FAMILY` is `1,2`; `ios-ci` builds for an iPad simulator on every PR | No target yet |
| Platform calls | Behind `Shared/Platform.swift` | `Platform.swift` has AppKit branches, not compiled yet |
| Layout | The phone's `TabView` + `NavigationStack`, full screen | — |
| Keyboard | `e` `h` `n` `s` `r` `⌘⌫` on a thread, `⌘N` compose | Same shortcuts carry over |
| Device copy | `Device.name` → "iPad" | `Device.name` → "Mac" |
| Rust core | Same xcframework slices (`aarch64-apple-ios`, `-sim`) | Needs a macOS slice in `build-rust.sh` |

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

The macOS branches are written against plain AppKit and will need a first
compile when the target exists.

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

## macOS: what a native target needs

Add a `HeyPigeonMac` target to `project.yml` (platform `macOS`, the same
`HeyPigeon/` sources minus the files below, `HeyPigeonCore` with a macOS
slice) and work through this list:

| File | iOS-only API | macOS replacement |
| --- | --- | --- |
| `App/AppDelegate.swift`, `App/HeyPigeonApp.swift` | `UIApplicationDelegate`, `@UIApplicationDelegateAdaptor` | `NSApplicationDelegate` + `@NSApplicationDelegateAdaptor`; the APNs callbacks have the same names |
| `App/AppModel.swift` | `BGTaskScheduler` background refresh | `NSBackgroundActivityScheduler`, or sync on a timer while running |
| `Shared/NewMailNotifier.swift` | `UIBackgroundFetchResult`, `UIGraphicsImageRenderer` avatar | A `Bool` result; draw the avatar with `NSImage(size:flipped:drawingHandler:)` |
| `Features/Thread/MessageBodyView.swift` | `UIViewRepresentable` for `UITextView` and `WKWebView` | `NSViewRepresentable` twins (`NSTextView`, `WKWebView`); CSP, link policy and scripts unchanged |
| `Features/Thread/AttachmentViews.swift` | `quickLookPreview` | Available on macOS; check the sheet sizing |
| `AI/AttachmentUnderstanding.swift` | `UIImage`, `UIGraphicsImageRenderer` | `CGImage` throughout (PDFKit and Vision take it on both) |
| `Engine/RustEngine.swift` | HTML import via UIKit's `NSAttributedString` | AppKit's, already behind `#if canImport` |
| `HeyPigeonShare/ShareViewController.swift` | `UIViewController`, `openURL:` responder trick | An `NSViewController` share extension; `NSWorkspace` cannot be used from it either, so keep the pending-share handoff |
| `HeyPigeonWidgets/*` | Live Activities (`ActivityKit`) | Not on macOS; widgets and Controls build as they are |
| `Shared/*LiveActivityController.swift` | `ActivityKit` | Compile out on macOS |
| `Theme.swift` `menuList()` | `listSectionSpacing`, `presentationDragIndicator` | Wrap the iOS-only modifiers like `groupedListStyle()` |
| `Features/**` | `.tabBarMinimizeBehavior`, `.toolbar(.hidden, for: .tabBar)`, `Tab(role: .search)` | `#if os(iOS)`; a Mac window uses the split view above instead of tabs |

Bundle ids: the Mac app is `app.heypigeon` (the Tauri product). A native
SwiftUI Mac target would need its own id, or replace the Tauri app under
that id deliberately — decide before the first archive.

## Rules while porting

- No new `import UIKit` outside `Platform.swift`, the representables and the
  files in the table above.
- Copy names the device through `Device.name`.
- Every platform branch keeps the iOS branch byte-for-byte what ships, so
  a port never changes the phone app by accident; `ios-ci` checks the
  iPhone and iPad builds on each change.
