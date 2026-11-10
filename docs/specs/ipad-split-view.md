# iPad split view

Status: Draft
Related: `docs/porting-macos-ipados.md` ("iPadOS: next steps"),
`docs/ios.md` ("iPad and hardware keyboards"), `ios-app/CLAUDE.md`

## What and why

On a regular-width iPad the app is the phone's: one column, a thread
pushed over the list. The list keeps to a readable column
(`readableColumn`) and has the Mac's keys (`ListKeys`), but the width
beside it is empty. This puts the open thread beside the list, as Mail on
the iPad and the Mac's reading pane do, so triage is "j, read, e" without
a push and a pop.

**Out of scope:** a permanent folders column (the sidebar stays the
sheet it is), multiple windows, a hover action bar, any change to the
iPhone or to the iPad in a compact width (Slide Over, a narrow Split
View), any change to the Mac.

## Behaviour

- R1. On an iPad whose window is regular width, each list tab (Inbox,
  Remind me, Need reply) shows two columns: the list, and the open
  thread beside it. Which device it is comes from `Device.name == "iPad"`
  (constant for the process), not from the size class alone: a large
  iPhone in landscape is regular width too and stays one column.
- R2. In a compact width the iPad is the phone: one column, the thread
  pushed. Nothing about it changes.
- R3. A tap on a row (or Return on the keyboard cursor's row) shows the
  thread in the second column and marks it read, as today. The row stays
  highlighted while its thread is open (`Theme.cursor`).
- R4. With no thread open the second column is a designed empty state:
  the pigeon and "No thread open", nothing else.
- R5. An action that takes the open thread's row out of the list (Mark
  done, Delete, Remind me, Move to folder) opens the next row's thread,
  or the empty state when there is none — the Mac's auto-advance
  (`WindowState.advanceOpen`), with the same Undo toast.
- R6. The open thread survives a change of window width. Going from two
  columns to one, the thread is pushed; going back, it is beside the
  list. An unsent reply being written is not lost in either direction.
- R7. A draft row opens the composer, as today, and never the second
  column.
- R8. The thread's bars (Reply pill, AI circle, triage bar) sit at the
  bottom of the thread's column, not across the window. The tab bar
  stays visible while a thread is open in the second column (it is
  hidden only when the thread is pushed).
- R9. A notification, a widget, Spotlight or a Siri intent that opens a
  thread (`AppModel.pendingThreadId`) opens it in the second column.
- R10. The keys: `j`/`k` move the cursor and, with a thread open, open
  the row they land on (the Mac's rule); `e` `h` `n` `s` `u` ⌘⌫ act on
  the open thread, else on the cursor's row; Esc closes the open thread.
  One set of key equivalents is live at a time (the list's and the
  thread bar's use the same letters).
- R11. The Search tab keeps one column in this version.
- R12. The Bundles cover keeps one column in this version.

## Where it lives

| Layer | What goes here |
| --- | --- |
| Core | nothing |
| Bridge | nothing |
| Shared shell (`ios-app/HeyPigeon`) | `MailListScreen` (`Features/Inbox/InboxView.swift`): the two-column layout around the existing `ThreadList` and `ThreadView`; a platform helper in `Shared/Platform.swift` that says whether this device splits (`Device.name`), so no bare `#if` and the Mac branch is `false`; the auto-advance rule as a static function next to `ListCursor` (`Features/Inbox/ListKeys.swift`) |
| iPhone / iPad only | the layout itself; the phone never takes the branch |
| Mac only | nothing: the Mac has its reading pane (`MacWindows.readingPaneKey`) |

Syncs between devices: no.
Leaves the device: nothing.

## Platform matrix

| | iPhone | iPad | Mac |
| --- | --- | --- | --- |
| Surface | one column (unchanged) | regular width: list + thread; compact: one column | reading pane (unchanged) |
| Entry points | tap | tap, Return, `j`/`k` with a thread open, notification, widget, Spotlight, intent | unchanged |
| Settings | none | none (always on at regular width) | View › Reading Pane (unchanged) |
| Status | n/a | not built | built |

## Platform differences

- The iPad has no setting for it; the Mac's reading pane is a menu
  switch. Reason: the Mac's single-line rows are worth the whole window,
  the iPad's three-line rows are not.
- The iPad's second column has the thread's own two bars; the Mac's has
  its one small card (`ThreadChrome.oneBar`). Reason: touch targets.

## How to build it (for whoever has a device)

These are the points that could not be settled without running it, which
is why it is a spec and not code.

1. **View identity.** The list and the thread must be the same views
   whether one column or two is showing (R6). Do not write
   `if regular { NavigationSplitView } else { NavigationStack }`: that
   rebuilds both on every window resize, loses scroll position and an
   inline state such as `ThreadView`'s `replyChoice`, and is what
   `ReadableColumn` had to stop doing. Two shapes are known to keep
   identity; try them in this order:
   - `NavigationSplitView` with two columns in every width on the iPad,
     left to collapse by itself in a compact width. `MailListScreen.path`
     becomes the detail's content; check that the collapsed form pushes
     and pops like today's stack, and that `ThreadView`'s
     `.hidesTabBar()` only applies when collapsed.
   - If the collapsed split view does not behave like the stack (the
     back-swipe, the toolbar, the tab bar), keep today's
     `NavigationStack` for the list and put the thread in an `HStack`
     beside it at regular width, as the Mac's `MainWindow` does for its
     reading pane (`showsPane`), with `path.last` as the shown thread and
     the stack's push suppressed while two columns show.
2. **The readable column.** `readableColumn()` centres the list at
   760 pt. With two columns the list column is narrower than that, so
   its margins are zero by `ReadableLayout.margin(in:)` already; apply
   it to the thread's column as today. Check the list column's width
   (the Mac uses `MacLayout.paneListWidth`, 420) against three-line rows
   at the largest text size.
3. **Bars.** `ThreadView`'s bars are a `safeAreaInset` of the thread, so
   they follow its column for free; the toast does not
   (`ToastMetrics.bottomInset(threadOpen:)` assumes the thread covers the
   tab bar). With two columns the tab bar is visible: the toast's inset
   must be the tab bar's.
4. **Keys.** `ListKeys` is switched off while a thread is pushed
   (`path.isEmpty`) because the thread's bar carries the same letters.
   With two columns both are on screen: decide R10 in one place — the
   thread bar's `threadKey`s off while the list's are on, the list's keys
   acting on the open thread first.
5. **Auto-advance.** `ListCursor.after(removing:in:)` already gives the
   neighbour; `ThreadView`'s `onClose` (called by Done, Delete, Mark
   unread, Move) is where the next thread is chosen instead of a pop.
6. **Sheets and deep links.** `MailListScreen`'s
   `.onChange(of: model.pendingThreadId)` sets `path`; nothing else
   should need to change.

## Acceptance criteria

- [ ] R1, R2 — the iPhone and a compact-width iPad are unchanged (the
      existing `ios-ci` iPhone tests and the iPad build)
- [ ] R5 — a pure function for the next thread, tested beside
      `ListCursorTests`
- [ ] R6 — checked by hand on an iPad: resize the window with a thread
      open and with a reply's sheet up
- [ ] R8 — checked by hand: the bars and the toast, both appearances,
      largest text size
- [ ] R10 — checked by hand with a hardware keyboard: no letter runs
      twice
- [ ] Same wording and symbol on every platform ("No thread open")
- [ ] `ios-ci`, `macos-ci` green
- [ ] `docs/ios.md` ("iPad and hardware keyboards") and
      `docs/porting-macos-ipados.md` updated

## Open questions / assumptions

- Assumed: no folders column. The owner's brief keeps folders in a
  drawer; a three-column iPad layout would add chrome the phone and the
  Mac do not have.
- Assumed: always on at regular width, with no switch.
- Open: the list column's width, and whether it should be resizable.
- Open: whether the Search tab should get the second column too (R11
  leaves it out to keep the first version small).

## Verification

Not built. Written during the interface review because the layout could
not be verified without a device (Linux, no Xcode).
