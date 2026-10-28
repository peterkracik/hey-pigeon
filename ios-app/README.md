# Hey Pigeon for iOS

Native SwiftUI shell over the shared Rust core. Design and rationale:
[docs/ios.md](../docs/ios.md). Status: **scaffold** — the Rust bridge is built
and tested on CI, the Swift side has not been compiled on a Mac yet.

```text
ios-app/
  HeyPigeon/            SwiftUI app (iOS 17+)
    App/                HeyPigeonApp, AppModel (state + actions + background refresh)
    Engine/             MailEngine protocol, MockEngine, RustEngine (UniFFI adapter), OAuth
    Features/           Inbox · Thread · Remind · Accounts · Compose · Settings
    Shared/             Theme (tokens), Formatters, ReminderScheduler
  HeyPigeonCore/        Swift package wrapping the Rust core (generated, git-ignored contents)
  scripts/build-rust.sh cargo → uniffi → xcframework
  project.yml           XcodeGen spec (the .xcodeproj is generated)
  Config/               Local.xcconfig with your team id + iOS OAuth client (git-ignored)
```

## Build

1. Tools: Xcode 16+, Rust (`rustup`), `brew install xcodegen`.
2. Rust targets: `rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios`.
3. OAuth client: in the same Google Cloud project as the desktop client
   (see [docs/google-oauth-setup.md](../docs/google-oauth-setup.md)), add a
   second credential of type **iOS**, bundle id `app.heypigeon.ios`. Copy the
   client id and its reversed form (Google shows both) into
   `Config/Local.xcconfig` (start from `Local.xcconfig.example`).
4. `scripts/build-rust.sh` once by hand (it also runs as a pre-build phase).
5. `xcodegen generate && open HeyPigeon.xcodeproj`, pick your device, run.

To work on the UI without any of 3–4, set `HEYPIGEON_MOCK=1` in the scheme:
the app runs against an in-memory sample inbox.

Fonts: drop `Manrope-Medium.ttf`, `Manrope-Bold.ttf`, `Manrope-ExtraBold.ttf`
into `HeyPigeon/Resources/Fonts/` for the brand typeface; without them SwiftUI
silently falls back to the system font.

## Publishing (EAS)

Release builds and TestFlight uploads run on **EAS** (expo.dev), the same
pipeline as any other app on the account. EAS Build can't use its default
Expo/React Native steps for this project, so `.eas/build/build-ios.yml` lists
the steps itself: install Rust + XcodeGen on the macOS worker, run
`scripts/build-rust.sh`, generate the Xcode project, then EAS's own
credential, version and fastlane steps. Signing certificates, provisioning
profiles and the App Store Connect API key all live in EAS's credential store
— nothing to export, nothing to put in Doppler except the Google client id.

`.eas/workflows/publish-ios.yml` chains build → submit on every `ios-v*` tag.
Versions: `app.json` holds the marketing version; build numbers are managed
remotely by EAS (`appVersionSource: remote`, `autoIncrement`).

```sh
git tag ios-v0.1.0 && git push origin ios-v0.1.0   # or: eas workflow:run publish-ios.yml
```

One-time setup, all from `ios-app/`:

1. `npm i -g eas-cli && eas login`, then `eas init` — links this folder to an
   EAS project (slug `hey-pigeon`) and writes `extra.eas.projectId` into
   `app.json`; commit that.
2. `eas credentials:configure-build -p ios -e production` — picks the team's
   existing Apple Distribution certificate from EAS's store (or creates one)
   and creates the App Store provisioning profile for `app.heypigeon.ios`.
3. `eas credentials -p ios` → App Store Connect API Key — reuse the key EAS
   already holds for your other apps, or upload one with the App Manager
   role. `eas submit` uses it; the app record for `app.heypigeon.ios` must
   exist in App Store Connect.
4. `eas env:set --name GOOGLE_IOS_CLIENT_ID --value <id>.apps.googleusercontent.com --environment production --visibility sensitive`
   — the iOS-type Google OAuth client (bundle id `app.heypigeon.ios`), created
   in the same Google Cloud project as the desktop client.
5. On expo.dev, connect the GitHub repository to the project so tag pushes
   trigger the workflow. Until then, `eas workflow:run publish-ios.yml` or
   `eas build -p ios -e production && eas submit -p ios --latest` by hand.

The first build is also the first time the Swift compiles anywhere, so expect
a round of compiler fixes from its log. Local sanity check without the cloud:
`eas build -p ios -e production --local` on a Mac with Rust installed.

**Bundle ids, deliberately two.** iOS is `app.heypigeon.ios`; the Mac app
stays `app.heypigeon`. They are separate products in App Store Connect
(separate listings, metadata and review), which is the intended setup — do
not merge them under one id. No wildcard App ID is needed: automatic
signing registers the explicit App ID on the first archive.

**Capabilities.** iOS-M1 needs none beyond a plain App ID: background
refresh and local notifications are Info.plist / permission matters, the
Keychain is the app's own, the OAuth redirect is a URL scheme. Add App
Groups + Keychain Sharing with the first extension (widget, share sheet),
Push Notifications only if the optional relay ever ships, iCloud KVS only
for the optional secret sync. `HeyPigeon/PrivacyInfo.xcprivacy` declares the
required-reason APIs (UserDefaults, SQLite file stats, monotonic clock); App
Store Connect rejects uploads without it.

The upload lands in TestFlight; releasing to the App Store is still the
"Submit for review" click in App Store Connect — or a later `fastlane
deliver` step, if that ever becomes a chore.

## Where things live

| Concern | Place |
| --- | --- |
| Everything that talks to Gmail / SQLite / Drive | `desktop-app/crates/*` (shared with the Mac app) |
| The Swift-facing API | `desktop-app/crates/ffi` → `Engine` |
| App models + the `MailEngine` seam | `HeyPigeon/Engine/Models.swift` |
| Optimistic actions, undo, sync cadence | `HeyPigeon/App/AppModel.swift` |
| Gesture map (swipe = keyboard shortcut) | `HeyPigeon/Features/Inbox/InboxView.swift` |
| Safe HTML rendering | `HeyPigeon/Features/Thread/MessageBodyView.swift` |
