# Hey Pigeon for iOS

Native SwiftUI shell over the shared Rust core. Design and rationale:
[docs/ios.md](../docs/ios.md); the Siri, App Intents and on-device AI layer in
[docs/ios-intelligence.md](../docs/ios-intelligence.md). Status: the Rust
bridge is built and tested on CI and the Swift shell archives through
`publish-ios`; the iOS 27 features (the "iOS 27" section of that document)
are written but not yet compiled — its "Verify on the first build" table says
what to check.

```text
ios-app/
  HeyPigeon/            SwiftUI app (iOS 27+, Liquid Glass; Siri, Foundation Models and Spotlight intelligence)
    App/                HeyPigeonApp, AppModel (state + actions + background refresh)
    Engine/             MailEngine protocol, MockEngine, RustEngine (UniFFI adapter), OAuth
    Features/           Inbox · Thread · Remind · Accounts · Compose · Settings
    Intents/            App Intents: entities (.mail.thread, message, draft, mailbox, account), the verbs as intents,
                        the Mail schema domain, App Shortcuts, the triage and Ask intents, Spotlight index + delegate, donations
    AI/                 The model layer the Rust core calls back into: FoundationModelsBackend over ModelProviders
                        (on device · Private Cloud Compute · package models), the triage prompt, the agentic triage
                        (tools + agent + journal), Ask my inbox over SpotlightSearchTool, attachment understanding, usage
    Shared/             Theme (tokens), Formatters, ReminderScheduler, ReminderPresets, widget snapshot, Live Activities, deep links
      WidgetShared/     Compiled into the app and both extensions: App Group, snapshot, widget intents, activity attributes, pending share
  HeyPigeonWidgets/     Widget extension: Unread · Next reminder · Need reply, the reminder and triage Live Activities, Controls
  HeyPigeonShare/       Share extension: text, links and files → a pending share the app opens as a draft
  HeyPigeonTests/       Unit tests over the mock engine (intents, entities, presets, snapshot, deep links, triage plan,
                        attachment chips) and Evaluations/ (the triage and summary prompt harnesses)
  HeyPigeonCore/        Swift package wrapping the Rust core (generated, git-ignored contents)
  scripts/build-rust.sh cargo → uniffi → xcframework
  project.yml           XcodeGen spec (the .xcodeproj is generated)
  Config/               Local.xcconfig with your team id + iOS OAuth client (git-ignored)
```

## Build

1. Tools: Xcode 27+ (the iOS 27 SDK is the deployment floor — see docs/ios.md), Rust (`rustup`), `brew install xcodegen`.
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

Fonts: drop `Manrope-SemiBold.ttf`, `Manrope-Bold.ttf`, `Manrope-ExtraBold.ttf`
into `HeyPigeon/Resources/Fonts/` for the brand typeface; without them SwiftUI
silently falls back to the system font.

## Publishing (CI)

`.github/workflows/publish-ios.yml` builds, signs and uploads the app to App
Store Connect (TestFlight) on **every push to `main` that changes the app**:
anything under `ios-app/` (docs excepted) or in the Rust crates the
xcframework is built from. Changes elsewhere do not start it. The marketing
version is `MARKETING_VERSION` in `project.yml`; the build number is the run
number, so each push is a new TestFlight build of that version. Bump
`MARKETING_VERSION` when you want a new version. An `ios-v*` tag publishes
too and takes the version from the tag name:

```sh
git tag ios-v0.2.0 && git push origin ios-v0.2.0
```

The build is plain `xcodebuild` on a macOS runner — Expo's EAS Build cannot
compile a native Xcode + Rust project — and the upload goes through **EAS
Submit** (expo.dev), which accepts any signed IPA. A manual run from the
Actions tab can pick `uploader: xcrun` (Apple's `altool`, no Expo account) or
`none` (IPA as a workflow artifact only).

One-time setup (plus, since the widget and share extensions, the App Group
`group.app.heypigeon` registered in the developer portal and assigned to the
three App IDs — the workflow says exactly where until it is done), then the
secrets listed at the top of the workflow, in the
GitHub environment `ios` (synced there from Doppler):

1. **App Store Connect**: an app record for bundle id `app.heypigeon.ios`
   (its numeric Apple ID is `ASC_APP_ID`), and an API key with the App
   Manager role (`ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, the `.p8` as base64
   in `ASC_API_KEY_P8`).
2. **Signing**: an *Apple Distribution* certificate as `.p12`
   (`IOS_DISTRIBUTION_CERTIFICATE_P12` base64 + its password). The certificate
   is per team, so reuse the one EAS already manages for the other apps:
   `eas credentials -p ios` → Distribution Certificate → Download. The App
   Store provisioning profile is created and refreshed by fastlane `sigh`
   through the API key on every run (manual signing, no device needed);
   nothing to upload.
3. **Google**: the iOS OAuth client id in `HEYPIGEON_IOS_OAUTH_CLIENT_ID`
   (same idea as the baked-in desktop client).
4. **Expo** (default uploader only): a project on expo.dev
   (`EXPO_PROJECT_ID`) and an access token (`EXPO_TOKEN`).

**Bundle ids, deliberately two.** iOS is `app.heypigeon.ios`; the Mac app
stays `app.heypigeon`. They are separate products in App Store Connect
(separate listings, metadata and review), which is the intended setup — do
not merge them under one id. No wildcard App ID is needed: automatic
signing registers the explicit App ID on the first archive.

**Capabilities.** One: **Push Notifications** (`aps-environment` in the
entitlements XcodeGen writes from `project.yml`). `publish-ios` enables it
on the App ID `app.heypigeon.ios` through the App Store Connect key
(`fastlane produce enable_services`) before fetching the profile, so no
portal click is needed; for a local device build, enable it once under
developer.apple.com → Identifiers. It serves the optional relay only — the app runs fine with the
relay off, using background refresh and local notifications, which are
Info.plist / permission matters. The Keychain is the app's own, the OAuth
redirect is a URL scheme. Add App Groups + Keychain Sharing with the first
extension (widget, share sheet), iCloud KVS only for the optional secret
sync. `HeyPigeon/PrivacyInfo.xcprivacy` declares the required-reason APIs
(UserDefaults, SQLite file stats, monotonic clock); App Store Connect rejects
uploads without it.

**Push relay (optional).** `../relay/README.md` and `../terraform/README.md`.
The app side: `Shared/PushController.swift` (the toggle, the relay URL, the
APNs token → `Engine.registerPushToken`), `App/AppDelegate.swift` (token and
silent-push callbacks), `Shared/NewMailNotifier.swift` (one delta sync for the
account named in the push, a local notification per new unread thread, badge).
`HEYPIGEON_RELAY_URL` in `Config/Local.xcconfig` (or the value of the same
name on the `ios` GitHub environment for CI builds) bakes the relay into the
build, like the OAuth client. The URL is never shown in the UI: Settings →
Notifications has the on/off toggle (on by default) with one status line
under it — registration state and until when the mailbox is watched. A build
without a relay shows the toggle disabled ("Not available in this build").
Xcode builds register `sandbox` tokens, TestFlight / App Store builds
`production` ones; the relay routes per token.

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
| Attachments: chips, Quick Look, Explain attachment | `HeyPigeon/Features/Thread/AttachmentViews.swift`, `HeyPigeon/AI/AttachmentUnderstanding.swift` |
| The AI door the Rust core calls back into; which model answers | `HeyPigeon/AI/FoundationModelsBackend.swift`, `HeyPigeon/AI/ModelProviders.swift`; resolution in `desktop-app/crates/ffi/src/settings.rs` |
| The triage prompt and its evaluation | `HeyPigeon/AI/TriagePrompt.swift`, `HeyPigeonTests/Evaluations/` |
| Siri: entities, the Mail schema, the verbs | `HeyPigeon/Intents/Entities.swift`, `MailSchema.swift`, `MailSchemaIntents.swift`, `ThreadIntents.swift`, `ListIntents.swift` |
| "Ask my inbox" | `HeyPigeon/AI/InboxAsk.swift`, `HeyPigeon/Features/Inbox/AskSheet.swift`, `HeyPigeon/Intents/SpotlightIndexer.swift` |
| "Triage my inbox" | `HeyPigeon/AI/TriageTools.swift`, `HeyPigeon/AI/TriageAgent.swift`, `HeyPigeon/Intents/TriageIntents.swift`, `HeyPigeonWidgets/TriageLiveActivity.swift` |
| Settings | `HeyPigeon/Features/Settings/SettingsView.swift`, `TriageJournalView.swift` |
