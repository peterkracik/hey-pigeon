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
  App/        HeyPigeonMacApp (scenes, commands, deep links), MacAppDelegate (+ the banner's buttons), MacSyncLoop,
              Connectivity (the network path: no round without one), MacCommands,
              MacUpdater (Sparkle: the feed publish-macos writes, the app menu's Check for Updates…)
  Features/   MainWindow (sidebar + NavigationStack, Settings or the Bundles page), MainToolbar (+ ViewTabs),
              SearchSpotlight (+ SpotlightPanel),
              MacStyle (the look), SidebarColumn, InboxPage (list, search filters, batch bar), MailRow
              (the row and its in-place preview), ThreadPage (ThreadView; ThreadWindow), BundlesPage
              (the shared BundlesStack over the window's path), WindowState,
              CommandPalette, ShortcutsSheet, MenuBarExtraView, ThreadPrinter (⌘P)
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
  one deep), the highlighted rows, the drawer, the Bundles page and its
  stack (`showBundles`, `bundlePath`), the search, the sheets, the
  keyboard map and every action. Keys, menus, hover buttons, trackpad
  swipes and the palette all call `WindowState.run(_:in:rows:)`, which acts
  on the open thread (`openThread`: the Bundles page's open email while
  the page is up, else the stack's) else the highlighted rows (`focusRow`)
  and calls AppModel like the swipes do. Pure logic is static
  (`KeyboardMap.resolve`, `PaletteFilter`), tested in `HeyPigeonMacTests`.
- **The first desktop client's shape under a standard toolbar.** The
  window has the unified toolbar with no title
  (`.windowToolbarStyle(.unified(showsTitle: false))`,
  `.toolbar(removing: .title)`), so the traffic lights are where macOS
  puts them and behave as they do. (Two earlier rounds hid the toolbar
  and drew a top bar of our own; the traffic lights vanished, then had to
  be moved by hand and still felt wrong.) `MainToolbar` holds the phone's
  three tabs (`ViewTabs`: Inbox · Remind me · Need reply, with counts)
  and, for any other folder, its name at the leading end — over the list
  column: the window lays the sidebar out itself, so with it out a clear
  first item (`SidebarInset`, which measures its own place in the window)
  pushes the tabs past the divider; summarize /
  ask / new message / search at the trailing end, after a flexible
  `ToolbarSpacer` (`.primaryAction` puts items at the *leading* end on
  the Mac). No Settings gear and no sidebar button there: Settings is in
  the app menu (⌘,) and the palette and opens as a page of the window
  (`WindowState.showSettings`, a grouped form through `SettingsList`);
  the sidebar starts hidden and its button is a glass circle in the
  window's bottom-left corner. Bundles are a page of the window too
  (`BundlesPage`: the shared `BundlesStack` — the list, a bundle, an
  email in it — over `WindowState.bundlePath`; the phone covers its
  screen with the same stack, and a sheet here looked like a dialog):
  the sidebar opens it, the toolbar names it, Esc walks its stack back
  and then leaves it, a tab or a folder leaves it, and an email open in
  it is the window's open thread for every key and the inline reply.
  `AppModel.showBundles` is handed to the window the moment it turns
  on, so the root's sheets (`AppModel.modal(_:inBundles: false)`) serve
  the page. A page over the list (a full thread; a bundle or an email
  on the Bundles page) gets the window's own Back as the first item over
  the content column (`WindowState.canGoBack`, `run(.back)`) and its
  name after the tabs (`MainToolbar.otherTitle`: the thread's people);
  the stacks' own Back is hidden (`backInWindowToolbar` — it sat beside
  the traffic lights, over the sidebar) and ThreadView's principal item
  is the phone's only (`ThreadChrome.titleInBar` — here it was a
  bordered pill in the middle of the window). The thread's trailing
  items (sparkle, actions menu) are the shared view's; a shared view's
  sheet-only item goes behind a helper (`sheetCloseButton`,
  `composeChrome`). The thread's bottom bars are one small card in the
  middle (`ThreadChrome.oneBar`, `floatingBar`, `replyPillSurface`,
  `barButton`): the phone's two glass capsules stretched across the
  thread smeared the message under them. A `Menu` whose label is a chip
  or an icon takes `labelOnlyMenu()`: the Mac's default draws a white
  bezel around it under the pointer. The triage labels are the phone's
  glass pill (`TriageSplitBar`) at the bottom of the list. Search and the command
  palette are one shape (`SpotlightPanel`: Liquid Glass over the blurred,
  dimmed window, one at a time); while one is up the toolbar is empty
  and clear. The list has no section headers (a Mac list's header floats
  on a grey band): each day group's title is a plain row and its rows
  share one white card (`MailRow.Position`); the hover and cursor tint
  fills a row to 1 pt of the card's edge, rounded only where the card
  is. The command palette's ⌘B stage lists the bundles, the recently
  active first, and one opens as the Bundles page
  (`PaletteStage.bundles`, `MailCommand.bundles`). Rows are single lines; Done
  is the first hover action (a done circle at the start read as a
  selection checkbox). A click opens the row **in place**
  (`WindowState.expanded`, the latest message and "Open full thread ›"),
  Return or the row's arrow opens the full thread (`path`). Never put a
  shadow on a view that holds a message: it falls on the web view too.
  Scroll bars are hidden (`.scrollIndicators(.never)`), and the toolbar
  draws nothing over the columns: `.toolbarBackgroundVisibility(.hidden)`
  and `.scrollEdgeEffectHidden(true, for: .top)` on the window. The
  automatic background and both edge styles came and went with the
  pointer (the list reports itself scrolled under the bar when it relays
  out) and drew a lighter strip across the top, behind the traffic
  lights too. The sidebar is ⌘S (View › Show Folders), nothing in the
  app saves by hand. The open
  row's card shows the whole message, as the first client's did; the
  pointer over a row is the hand. The composer on
  the Mac (shared `ComposeView`) takes the window's look through
  Platform helpers: `composeChrome` (title, close and full-screen at the
  top), `borderlessFields`, `pillButton`, `labelOnlyMenu`. Its body is
  the Mac's own editor (`ComposeMac.swift`, next to the shared view, all
  of it behind `#if os(macOS)`): an HTML editor in a web view, as the
  first desktop client's contenteditable was — paragraphs with half a
  line of air between them on Return, a bare line break on
  Shift-Return, bullet and numbered lists, ⌘B · ⌘I · ⌘U · ⇧⌘X · ⌘K and
  ⇧⌘7 / ⇧⌘8 wired in the page (WebKit binds none of them in a
  contenteditable), ⌘J for the AI, ⌘↩ to send, plain text on paste. A
  reply is written **under its thread**, not in a sheet (Superhuman's
  inline reply): `ThreadView` puts `ComposeView(draft:inline:)` under
  the messages when the open draft answers its thread
  (`ComposePresentation.inlineReplies`, `AppModel.composeDetached`) and
  scrolls it to the middle; a reply from the list or a row's preview
  opens the thread first (`WindowState.showThread`); `MainWindow` shows
  the sheet only for a new message, a forward, a reply pulled out with
  the card's window button, or a reply to a thread no window shows
  (`ComposePlacement`, `ThreadWindows`). The card's "Draft to …" line
  keeps the prefilled fields folded; the sheet shows the thread's
  messages above a reply itself. A selection gets a floating toolbar;
  the footer's Aa opens a format bar with the same tools; and the AI is
  a panel under the text — chips, a line for an instruction, the result
  reviewed before it replaces anything, a Cancel that works and a
  timeout — not a sheet. `ComposeView` keeps the draft's lifecycle for
  both platforms (`withLifecycle`) and branches only in its two
  per-platform extensions; the phone's branches are what ship there.
  The AI's prompt carries who writes to whom (`AIWriteContext`) and the
  core keeps the draft's language. The list and the thread keep to
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
- **Nothing asks the store from a view body.** A count or a list a view
  shows comes from the model's last snapshot (`unifiedCounts`,
  `countsByAccount`, `needReplyAcrossAccounts`, all observed and assigned
  only when they moved) or from a `.task` that reads off the main actor
  (`readInBackground`). A query inside `body` runs on every render and is
  redrawn by none: nothing observes it. The list's order is the model's
  too (`flatRowIds`, `listIndex(of:)`, `rowOrderRevision`): do not flatten
  `groupedRows` per key press or compare id arrays per render.
- **The keyboard map, the shortcuts sheet and the tests move together.**
  A new bare key goes into `KeyboardMap.resolve`, `KeyboardMap.characters`
  and `ShortcutsSheet.groups`; `ShortcutsSheetTests` fails when one of the
  three is missing. Space previews (pages in a thread), ⇧J / ⇧K / X grow
  the selection, Z undoes (`AppModel.undoLast`, for two minutes).
- **The reading pane shares the stack's state.** View › Reading Pane
  (`MacWindows.readingPaneKey`) shows `state.path.last` beside the list
  instead of pushing it, when the content is at least
  `MacLayout.paneMinWidth` wide; `WindowState.readingPane` tells `expand`
  to open the thread there. Nothing else knows the difference.
- **Sync is the timer.** No BGTaskScheduler on the Mac; `MacSyncLoop` runs
  a quiet round every 30 s (`AppModel.sync(quiet:)`: no reload, no
  reminder pass, no Spotlight pass when the round brought nothing), every
  2 min in Low Power Mode, none without a network path (`Connectivity`),
  and composes new-mail banners from its diff
  (`NewMailNotifier.post`; their buttons are `NotificationActions`,
  handled in `MacAppDelegate.act`). The Mac build has no push entitlement — it is
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
