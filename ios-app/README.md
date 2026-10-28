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

## Publishing (CI)

`.github/workflows/publish-ios.yml` builds, signs and uploads the app to App
Store Connect (TestFlight) on every `ios-v*` tag, or by hand from the Actions
tab. The build is plain `xcodebuild` on a macOS runner — Expo's EAS Build
cannot compile a native Xcode + Rust project — and the upload goes through
**EAS Submit** (expo.dev), which accepts any signed IPA. `uploader: xcrun`
does the same upload with Apple's `altool` and no Expo account; `none` just
produces the IPA as a workflow artifact.

```sh
git tag ios-v0.1.0 && git push origin ios-v0.1.0
```

One-time setup, then the secrets listed at the top of the workflow:

1. **App Store Connect**: an app record for bundle id `app.heypigeon.ios`
   (its numeric Apple ID is `ASC_APP_ID`), and an API key with the App
   Manager role (`ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, the `.p8` as base64
   in `ASC_API_KEY_P8`).
2. **Signing**: an *Apple Distribution* certificate exported as `.p12`
   (`IOS_DISTRIBUTION_CERTIFICATE_P12` base64 + its password). Provisioning
   profiles are created by Xcode cloud signing at build time, nothing to
   upload.
3. **Google**: the iOS OAuth client id in `HEYPIGEON_IOS_OAUTH_CLIENT_ID`
   (same idea as the baked-in desktop client).
4. **Expo** (default uploader only): a project on expo.dev
   (`EXPO_PROJECT_ID`) and an access token (`EXPO_TOKEN`).

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
