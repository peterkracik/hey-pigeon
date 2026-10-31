# Hey Pigeon for Mac

The native Mac app: the same Swift shell as the phone
([`ios-app/`](../ios-app)) over the same Rust core, in a Mac window. One
model (`AppModel`), one engine, the same Siri intents, Spotlight index,
widgets, AI layer and feature screens — compiled for macOS behind the
platform door in `ios-app/HeyPigeon/Shared/Platform.swift` — plus what only
a Mac has: a menu bar, the desktop's keyboard map, a command palette, hover
actions, a Settings window, a menu bar extra, and a thread in its own
window. The window is the phone's shape made bigger, Superhuman's
minimalism in Liquid Glass: no title bar, no toolbar, the list full width
up to a readable maximum, a thread opening in its place, the folders in a
drawer that slides away. Design notes in
[docs/porting-macos-ipados.md](../docs/porting-macos-ipados.md).

```text
macos-app/
  HeyPigeonMac/           Mac-only sources (macOS 27, Liquid Glass)
    App/                  HeyPigeonMacApp (scenes, deep links, scene phase), MacAppDelegate (notifications,
                          APNs, Dock menu), MacSyncLoop (the 30 s timer + new-mail banners), MacCommands (menus),
                          MacUpdater (Sparkle: in-app updates from the mac-latest release)
    Features/             MainWindow (the drawer + the NavigationStack, sheets, toast), SidebarColumn (the
                          drawer), InboxPage (the header row, the list, search, hover and swipe actions, the
                          batch bar), ThreadPage (the header row over the shared ThreadView; + ThreadWindow),
                          WindowState (the open thread, the cursor, the keyboard map, every action),
                          CommandPalette (⌘K), ShortcutsSheet (?), MenuBarExtraView
    Resources/            The Mac icon set; drop Manrope-*.ttf into Fonts/ for the brand typeface
  HeyPigeonMacShare/      The share menu's "Hey Pigeon": NSViewController over the shared ShareView
  HeyPigeonMacTests/      Swift Testing: the keyboard map, the selection, the palette filter, the widget links
  scripts/build-rust.sh   cargo (aarch64-apple-darwin) → uniffi → xcframework, via the iOS script
  project.yml             XcodeGen spec (the .xcodeproj is generated); the widgets target reuses
                          ios-app/HeyPigeonWidgets, the tests target reuses ios-app/HeyPigeonTests
  Config/                 Local.xcconfig with your team id + Google OAuth client (git-ignored)
```

## What is Mac-shaped

| | Phone | Mac |
| --- | --- | --- |
| Layout | Tabs + a stack + sheets | One column like the phone: the list full width (to 1040 pt), a thread in its place (`NavigationStack`), the folders in a drawer (⌃⌘S); no title bar or toolbar — the header rows are glass circles like the phone's; Settings is a window (⌘,); ⌘↩ opens a thread in its own window |
| Actions on a row | Two-tier swipes, long-press menu | The keyboard map (`e h n s u # r a f l v i j k`, `g`-chords, `0 1 2`, `/`, `⌘K`, `?`), a hover bar (Done + the four swipe actions from Settings), two-finger trackpad swipes (the same four), the context menu, the Message menu with ⌘ equivalents |
| After Mark done | Undo toast, back to the list | Undo toast; in a thread the next one opens, in the list the next row takes the cursor (auto-advance) |
| Several at once | — | ⌘/⇧-click rows: a glass batch bar at the bottom |
| Sync | On open, pull, background refresh, the optional relay | Every 30 s while open, every activation, ⇧⌘N; no relay — the Mac build has no push entitlement |
| New mail | A relay push → banner | The timer's diff → banner (Settings › Notifications), communication-style with the sender's initial |
| Siri, Spotlight, Shortcuts | App Intents, the Mail schema, the index | The same files; "Ask my inbox" and "triage my inbox" through the Mailbox menu and the palette |
| Widgets | Unread · Next reminder · Need reply, Live Activities, Controls | The three widgets; Done and 1 h are `heypigeon://` links the app acts on |
| Default mail app | iOS Settings › Default Apps | Settings › Default email app asks macOS to make Hey Pigeon the `mailto:` handler and shows whether it is |
| Updates | TestFlight | In-app (Sparkle): an hourly check of the `mac-latest` feed, a background download, the install on the next quit; Hey Pigeon › Check for Updates… and a switch in Settings › Updates |
| Compose | Full-screen sheet | A sheet on the window, same composer (rich text, attachments, AI) |

Everything else — the rows, the thread view with its glass bars, the Remind
sheet, the summaries, Ask my inbox, attachments and "Explain attachment",
Settings' sections — is the phone's code.

## Build

1. Tools: Xcode 27+ (macOS 27 SDK), Rust (`rustup`), `brew install xcodegen`.
2. Rust target: `rustup target add aarch64-apple-darwin` (macOS 27 runs on
   Apple Silicon only, so there is no Intel slice).
3. OAuth client: Google has no "macOS" client type; a client of type **iOS**
   works from a Mac app through the same consent sheet
   (`ASWebAuthenticationSession`, the reversed client id as the callback
   scheme). Reuse the phone's client, or add one for bundle id
   `app.heypigeon.mac` (see [docs/google-oauth-setup.md](../docs/google-oauth-setup.md)).
   Copy the client id and its reversed form into `Config/Local.xcconfig`
   (start from `Local.xcconfig.example`). Leave `SPARKLE_PUBLIC_ED_KEY`
   empty: a development build should not update itself.
4. `scripts/build-rust.sh` once by hand (it also runs as a pre-build phase;
   `PLATFORM_NAME=macosx` picks the Mac slice).
5. `xcodegen generate && open HeyPigeonMac.xcodeproj`, run.

To work on the UI without 3–4, set `HEYPIGEON_MOCK=1` in the scheme: the app
runs against the in-memory sample inbox.

The app is sandboxed (network client, user-selected files, the App Group
shared with the widget and share extensions). The published build is
signed with Developer ID and carries no provisioning profile, so it holds
no entitlement that needs one: the App Group is the team-prefixed
`<TEAMID>.group.app.heypigeon` (the form macOS honors without a profile;
`AppGroup.identifier` reads it from the Info.plist) and there is no push
entitlement — the Mac syncs itself, the relay is the phone's.
Its data lives in the container's Application Support; OAuth tokens and keys
in the Keychain.

## Tests (CI)

`.github/workflows/macos-ci.yml` runs on every pull request that touches the
Mac app, the shared shell or the Rust crates: `xcodebuild test` on the
`xcode-27` runner, unsigned and with no OAuth client, so the app runs on the
sample inbox. Locally:

```sh
PLATFORM_NAME=macosx scripts/build-rust.sh && xcodegen generate
xcodebuild test -project HeyPigeonMac.xcodeproj -scheme HeyPigeon -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## Publishing and updates (CI)

`.github/workflows/publish-macos.yml` builds an Apple Silicon archive, signs
it with Developer ID through the App Store Connect key and notarizes it — the
Swift app's twin of `publish-ios`. **Every push to `main`** that changes the
app (anything under `macos-app/` except docs, the shared shell in
`ios-app/HeyPigeon`, the widgets, the share view, the Rust crates) publishes
the zip to the rolling `mac-latest` pre-release, so the download link never
changes:
`https://github.com/peterkracik/hey-pigeon/releases/download/mac-latest/HeyPigeon-mac-latest.zip`.
Install once: unzip, drag `HeyPigeon.app` into Applications, open it from
there. Opened straight from the download instead, macOS runs a temporary
read-only copy (App Translocation) from which the app's URL scheme is not
its own — Google's sign-in cannot call back — and Sparkle cannot replace
the bundle; the app says so at launch (`InstallLocation`).

**Updates are in-app** ([Sparkle](https://sparkle-project.org)). Next to
the zip the workflow uploads `appcast.xml` — the build number
(`CFBundleVersion`, the publish run number, so it only grows), the zip's
size and its EdDSA signature. The app polls it once an hour (`SUFeedURL`
in `project.yml`), downloads a newer build in the background, verifies the
signature against `SUPublicEDKey` and installs it when the app next quits;
Hey Pigeon › Check for Updates… does the round now, and Settings › Updates
turns the automatic install off. A `mac-v*` tag still cuts a versioned
release with `HeyPigeon-mac-<version>.zip` — a download, not an update.

The workflow reads the GitHub environment `macos` (synced from a Doppler
config of the same shape): `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`
and `APPLE_TEAM_ID`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID` and
`ASC_API_KEY_P8` as `publish-ios` has them (here only for notarization),
`HEYPIGEON_MAC_OAUTH_CLIENT_ID` (an iOS-type Google client; the phone's
value works), and
`SPARKLE_PRIVATE_ED_KEY`, the update signing key. Make that one once, on
any Mac, with Sparkle's tools (the `Sparkle-<version>.tar.xz` on
[its releases page](https://github.com/sparkle-project/Sparkle/releases)):

```sh
bin/generate_keys                      # makes the key in your login keychain, prints the public half
bin/generate_keys -x sparkle-key.txt   # the private half, one base64 line → SPARKLE_PRIVATE_ED_KEY
```

Put the file's line into Doppler as `SPARKLE_PRIVATE_ED_KEY` and delete
the file; the keychain copy is your backup — a lost key means every
installed app stops seeing updates until it is reinstalled by hand. The
public half is optional (`SPARKLE_PUBLIC_ED_KEY`): the build derives it
from the private key when it is missing. The Mac keeps its own bundle id,
`app.heypigeon.mac`, next to the phone's `app.heypigeon.ios` and the old
Tauri app's `app.heypigeon`.

```sh
git tag mac-v0.1.0 && git push origin mac-v0.1.0
```

Conventions for changing the app (what is shared, where Mac code goes,
the keyboard rule) are in [CLAUDE.md](CLAUDE.md).
