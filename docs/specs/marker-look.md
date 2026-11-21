# The paper look ("Marker")

Status: Implemented
Related: `docs/ios.md` ("UX"), `macos-app/CLAUDE.md`, `.claude/agents/ux-ui.md`
("The design system as built"). Drawn first on the owner's design canvas as
"version 3b": every screen of the three apps in this look, light and dark.

## What and why

The apps take one new visual language: **paper, ink and one pink
highlighter**. Rows are ruled, not carded. Structure (hairlines, the titles
of groups and sections) is quiet grey; content and actions are ink; pink
only ever means "look here". Interface text is set in Instrument Sans, and
what is read as data (times, counts, tags, keys, titles of groups) in DM
Mono.

It replaces the first look (white cards on a grey canvas with a wash, a
pink unread bar, tinted chips, Manrope titles over the system font), which
had grown uneven: grey text under 4.5:1, a pin under 2:1 on white, tag
colours with no dark pair, and two ideas of what a read row is.

**Out of scope:** the views themselves. Every screen keeps its elements,
their order, their words and what they do; this spec changes how they are
drawn and nothing else. Also out: a message's own rendering (mail is shown
as it came, in the system font), the system's chrome (the glass bars,
alerts, menus, the tab bar's own labels), and the heypigeon.app site.

## The look

Tokens live in `Theme` (and `MacTheme` for the window's own surfaces). A
feature file never writes a hex value or a system font.

| Token | Light | Dark | For |
| --- | --- | --- | --- |
| `canvas`, `card` | `#FFFFFF` | `#16181D` | The paper: a list and its rows alike |
| `raised` | `#FFFFFF` | `#1E2026` | A sheet, a popover, a panel over the canvas |
| `sunken` | `#F4F4F6` | `#23262D` | A search field, a row under the pointer, a placeholder |
| `separator` | `#E7E7EA` | `#2B2E36` | The rule between two rows |
| `outline` | `#C9CACF` | `#3A3D45` | A boxed chip, a key, a text box |
| `textPrimary` (ink) | `#0B0D12` | `#F3F4F6` | Content, actions, selection |
| `onPrimary` | `#FFFFFF` | `#16181D` | Writing on an ink fill |
| `textSecondary` | `#454850` | `#B6B9C0` | A read sender, a tag, a quiet button |
| `textTertiary` | `#6B6E76` | `#8B8E96` | Previews, times, footers: 5:1 on the paper |
| `titleInk` | tertiary at 40 % | tertiary at 40 % | The words of a group's or a section's title: its name and its count |
| `titleRule` | `#E7E7EA` | `#2B2E36` | That title's rule, and the rule that opens a group with no name: the `separator` grey |
| `marker` | `#FFC9E2` | pink at 50 % | The highlighter's band |
| `pinkInk` | `#CC2277` | `#F58BBE` | The AI's glyph and a suggestion's words |
| `accent` | `#EE4D9B` | `#EE4D9B` | The one pink fill: the AI's draft button |
| `state(_:)` | coral `#B34E2E`, mint `#1F7A5C`, lavender `#6A4FC4`, sky `#2A6BAE`, amber `#A9761E` | `#F0916F`, `#5CC6A0`, `#A995F2`, `#7FB2E8`, `#E3B341` | A state as writing or a glyph |

- **R1. Paper.** One surface. A list, its rows, a thread and its messages
  stand on `canvas`; nothing is a card, nothing has a shadow for depth, and
  there is no wash behind a list. A sheet or a panel is `raised` (the same
  white on light, a step up on dark).
- **R2. Ruled rows.** Rows of a list are parted by a `separator` hairline;
  the last row of a group has none. On the phone a mail row is three lines
  (sender · marks · time, subject, preview) and a fourth for its tags when
  it has any; on the Mac it is one line.
- **R3. Unread is a pink corner.** An unread row's sender is bold and the
  row has a 10 pt pink triangle (`accent`) in its bottom leading corner
  (`unreadCorner()`); a read row's sender is medium weight in
  `textSecondary`. No bar on the row's edge, no dot, and no highlighter
  behind the name (0.3.0 had one; the owner chose the corner on the
  canvas page "Marker: edge to edge, pink corner"). The unread row's time
  is ink, a read row's `textTertiary`. On the phone a mail row and the
  hairline under it run from edge to edge; its words and the group's
  title stand 16 pt in. In a thread and in the menu bar extra unread is
  the weight alone; a widget's row has the corner too.
- **R4. Pink means "look here".** The corner marks an unread row and the
  highlighter an action the AI suggests. The AI's sparkle and a suggestion's words
  are `pinkInk`. The pink fill (`accent`) is the AI's own button (the
  draft circle beside Reply) and the unread corner, nothing else. Pink is never decoration,
  never "done", never an error, and never progress: a progress bar is ink
  on a `separator` track, in the app and on the Lock Screen.
- **R5. Titles stand back.** A group of rows and a section of a form are
  titled the same way (`SectionTitle`): the name in small mono capitals, a
  rule filling the line, a count at the far end where there is one. The
  words are `titleInk`; the rule is `titleRule`, as faint as the lines
  between rows, so a group's rule is one more hairline with a name on it
  and not a second, stronger kind of line down the page. A section with
  no name opens with the rule alone (`SectionRule`), in the same grey. A glyph before the name and a control after the rule
  keep their own strength. In a menu sheet and in Settings the grouped
  list's own lines over a section's first row and under its last are
  hidden (`menuCard()`): the title's rule opens a group and nothing
  closes it.
- **R6. Type.** Instrument Sans (regular, medium, semibold, bold) for the
  interface; DM Mono (regular, medium) for times, counts, sizes, tags,
  keys, tracking and order numbers, and titles. Sizes on the phone are
  relative to a text style, so Dynamic Type scales them; the Mac's window
  has sizes of its own. A weight is an argument (`Theme.sans(.footnote,
  .semibold)`), never `.weight()` on the result. SF Symbols keep a system
  font. Mail bodies keep the system font.
- **R7. States are writing, not fills.** A reminder, "Need reply", done,
  a draft, an error are a glyph and a few words in the state's colour
  (`Theme.state(_:)`, `StateMark`), never a tinted chip. A label is a word
  in the mono, `#Travel` (`TagText`). An account is a 6 pt dot in its
  colour. The pin is ink. A filter that can be switched is a boxed chip
  with an `outline`.
- **R8. One ink action.** A screen has one ink-filled primary action
  (Compose, Reply, Send, Add Google account, Save in a sheet): an ink
  capsule with `onPrimary` words. Every other button is glass (what
  floats), an outlined capsule or plain text. An item of a navigation
  bar (Done, Save) is the system's: its words in ink. Deleting is
  `danger` text, not a fill.
- **R9. Selection is ink.** The selected tab, segment or label is an ink
  capsule; the highlighted row of a list or a panel is `sunken` with a
  heavier name.
- **R10. Done is struck through.** A done email listed in its bundle
  (under Done there) has its subject and preview struck through and steps
  back to `textTertiary`; so does a row while a swipe, or the Mac's Done
  under the pointer, is about to mark it done. In a folder or a search a
  done thread keeps its row and has a mint check before its time (most of
  what a search finds is done, and a list of struck lines is hard to
  read). The Mark done swipe panel is ink.
- **R11. Controls.** A switch that is on is ink (`switchOn`). A text field
  has no fill: an ink underline, or a box with an `outline` for a text of
  several lines. A key is a mono letter in an `outline` box.
- **R12. What floats is the system's.** The tab bar, the bars over a
  thread, the label pill and the search field stay Liquid Glass as the
  system draws it. On the Mac a floating panel is the paper with a
  hairline, the Spotlight-style panel the paper with an ink outline. The
  one exception is the toast: an ink capsule on every platform, its words
  `onPrimary` and its Undo in `onPrimaryPink`.
- **R13. Dark.** The same rules with the dark column of the table. The
  surfaces are a dark grey a step off black, so the canvas lifts off the
  status bar and glass still reads. An ink fill turns light and its words
  dark. State colours take their lighter pair.
- **R14. Accessibility.** Text is at least 4.5:1 on its surface in both
  appearances, with one exception: a title's words (R5) are under 2:1
  (about 1.7:1 on the paper), by the owner's choice, and become
  `textTertiary` with Increase Contrast, as its rule does.
  Colour is never the only signal: a state has a glyph or a word, unread
  has a weight. Dynamic Type may not clip the sender or the time.

## Where it lives

| Layer | What goes here |
| --- | --- |
| Core, bridge | Nothing |
| Shared shell (`ios-app/HeyPigeon`) | `Shared/Theme.swift` (tokens, type roles, the menu helpers), `Shared/WidgetShared/Typeface.swift` (the two families, for the app and both extensions), `Shared/Marker.swift` (`SectionTitle`, `SectionRule`, `RowRule`, `TagText`, `StateMark`, `marker()`, the two capsule button styles), `Shared/Platform.swift` (`SystemChrome`: bar titles and segmented controls), every view under `Features/` |
| iPhone / iPad only | `Resources/Fonts` named in `UIAppFonts` for the app, the widgets and the share extension (`project.yml`) |
| Mac only (`macos-app/HeyPigeonMac`) | `Features/MacStyle.swift` (`MacTheme`, `TabPill`, the panels) and the window's own views; the same fonts folder through `ATSApplicationFontsPath` |
| Widgets, share extension | `Typeface` and `WidgetPalette`; they cannot see `Theme` |

Syncs between devices: no. Leaves the device: nothing.

The fonts are in `ios-app/HeyPigeon/Resources/Fonts` with their licences
(`OFL-InstrumentSans.txt`, `OFL-DMMono.txt`; both SIL Open Font License
1.1). Should a bundle lack them, `Typeface` falls back to the system font
at the same size and weight.

## Platform matrix

| | iPhone | iPad | Mac |
| --- | --- | --- | --- |
| Mail list | Three-line ruled rows, 16 pt in | The phone's, in the 760 pt column | One-line ruled rows, 40 pt, no day cards |
| Titles | 11 pt mono capitals | The phone's | 10.5 pt mono capitals |
| Menus, Settings | Sections under their titles, ruled rows, no cards | The phone's | A form in the reading column, no boxes |
| Thread | Flat messages parted by rules; Reply is the ink action | The phone's | One column of ruled messages; the reply foot's pills |
| Floating chrome | Liquid Glass | Liquid Glass | Paper panels with a hairline; glass for the label pill |
| Selection | Ink capsule (label pill, segments) | The phone's | Ink capsule (toolbar tabs), `sunken` row |

## Platform differences

- **Sizes.** The Mac's window does not scale with Dynamic Type; its text is
  13 pt where the phone's is a text style.
- **Hover.** Only the Mac has a pointer: a row under it is `sunken`.
- **A switch that is on, in dark.** The system draws the knob white, so
  the track is a light grey (`switchOn`), not the near-white ink.
- **Bar titles and segmented controls** are restyled through UIKit's
  appearance on iOS (`SystemChrome`); the Mac draws its own tabs.

## Acceptance criteria

- [ ] R1–R13 hold on every screen of the canvas, on iPhone, iPad and Mac, light and dark — converted screen by screen and read; seen only where "Verification" says
- [x] No hex colour outside `Theme`, `MacTheme` and `WidgetPalette` (the CSS of a message's own page aside: that is mail); no system text font in a feature file except on an SF Symbol and for mail content
- [x] No `.weight()` or `.bold()` applied to a `Theme` or `Typeface` font
- [x] The views are unchanged: same elements, order, words and actions (the unit and UI tests pass untouched)
- [x] `ios-ci` and `macos-ci` green
- [x] `docs/ios.md`, `macos-app/CLAUDE.md`, both READMEs and the ux-ui guide describe this look

## Open questions / assumptions

- Titles under 2:1 are the owner's choice. In 0.3.0 the words and the
  rule were half the tertiary grey (tried on the canvas); seen on a
  phone, three such titles down a screen of mail still drew the eye. The
  owner then chose the lightest of three steps (the canvas page "Marker:
  quieter separators", step 3): the rule in the hairline's grey and the
  words at 40 %. Increase Contrast restores both.
- Dark surfaces are lifted off black (`#16181D`), keeping the earlier rule
  that the canvas must not be near-black under the glass bars. The canvas'
  first dark board was darker.
- The tab bar's labels, alerts and menus stay in the system font: they are
  the system's.
- The fonts are committed to the repository (about 450 KB), so every build
  has them. Manrope, which was dropped in by hand, is no longer used.

Where what is built differs from the canvas, for the owner to keep or
change:

- **A widget's container** keeps the system's fill, not the paper: the
  system draws it and recolours it (a tinted Home Screen, StandBy), and
  the Lock Screen accessories take the system's colours.
- **A Live Activity's platter** on the Lock Screen is the dark tint it
  was, in both appearances, drawn with the dark column; the canvas drew
  it light.
- **The Mac's thread** starts its subject 16 pt in, where its messages'
  text does; the canvas has 32.
- **A group's count** is of the rows loaded so far, so "Older" grows as
  the list pages in.

## Verification

2026-11-21, on the branch of PR #164.

```
Spec: docs/specs/marker-look.md   Verdict: Verified with notes

Rules           R1–R3, R5, R7–R9, R11–R13 ✓ seen, on the screens listed under "Seen" ·
                R4, R6, R10, R14 ✓ read in the code (Theme, Marker, ThreadRowView, the two
                Live Activities); R4's "one pink fill" and R6's "no .weight()" also by search
Parity          iPhone ✓ · iPad ✓ (the phone's views in a column; built, not seen) · Mac ✓
                (its own window over the same tokens and pieces)
Layering        ✓ tokens and type in Theme / Typeface, the pieces in Marker.swift, the
                Mac's surfaces in MacStyle.swift, the extensions' copy in WidgetPalette;
                nothing in the core or the bridge
Tests / CI      ios-ci ✓ (iPhone: the unit and UI tests; iPad: the build) · macos-ci ✓ (the
                build and the tests), with the tests untouched but for one new unit test
                (ParcelCard.statusPieces) and the two that keep pictures
Seen            Pictures CI kept from an iPhone simulator, light and dark: the inbox (groups,
                unread, the AI's suggestion, tags, a bundle's mark, the pin, account dots),
                the inbox with the parcel card, a thread with its message, the Remind sheet,
                the empty Remind me and Need reply lists, the folders sheet, Settings (three
                screens of it), Ask my inbox, a new message, the list of bundles and a
                bundle's Emails page. The Mac window's inbox with the parcel card, light
                and dark (a snapshot of the hosted window, which does not draw glass).
Not seen        Anything on a device. The iPad. On the phone: search, a summary, the AI
                edit sheet, the swipe panels, the toast, Recent opens, Mailbox care, the
                triage journal, a bundle's Info page, a reply. On the Mac: a thread,
                the composer, Settings, the sidebar, the palette and the search panel, the
                bundle pages, the shortcuts sheet, the menu bar extra. The widgets, the
                Live Activities and the share sheet. Large text sizes, Increase Contrast,
                VoiceOver.
Drift / fixes   Found in the pictures and fixed: the grouped list's own lines around every
                section of a menu (menuCard hides them; a group with no name opens with
                SectionRule); 22 pt too much between two groups of the mail list. Found
                against the canvas and fixed: a progress bar is ink, not pink (this spec's
                R4 said pink). Left, for the owner: the list under "Open questions".
```
