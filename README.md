# Hey Pigeon

A minimalist, keyboard-first Gmail client. **Superhuman-inspired, not
Superhuman-competing.**

> **This is a personal project, not a product.** I vibe-coded a Gmail client
> that fits how I personally use email, and I'm shaping it for my own daily
> use. It is **not production-ready**, has no support, no roadmap promises,
> and no intention of competing with any commercial email client. If you try
> it, treat it as **for testing purposes only** — expect rough edges and
> breaking changes without notice.

Design doc: [DESIGN.md](./DESIGN.md). Site: [heypigeon.app](https://heypigeon.app).

## No backend, ever

Hey Pigeon has **no server component of any kind** and never will by design.
It's a local app — native on the Mac, the iPhone and the iPad, over one
shared Rust core — that talks directly to Google's APIs using your own
OAuth grant:

- Your mail, contacts, and reminders never leave **your own Google account** —
  Gmail for mail, and a hidden per-app Drive folder (`appDataFolder`) for
  cross-device reminder sync.
- Everything the app reads is cached in a local SQLite database on your
  device, purely for instant local search/browsing.
- AI features (optional) never go through the developer. The default is
  **Apple Intelligence on the device** (no key, no network), with Apple's
  Private Cloud Compute (Apple's own servers, never stored, no key) and
  OpenAI (your own key; requests go straight from your device to the
  provider) as opt-ins; which one answers, and the order they fall back in,
  is yours to set.

Because there's no backend and no third-party data store, there's no
"Hey Pigeon got breached" risk model to worry about — your data's exposure
surface is exactly your own Google account's, unchanged by using this app.

The one honest exception: iOS push notifications need Apple's APNs, so the
iOS app can optionally talk to a tiny relay you host yourself in your own
Google Cloud project. It sees your address and a change counter, never mail
— see [relay/README.md](./relay/README.md). Off by default; the app is
complete without it.

## Status

Early, personal, actively-changing. See [DESIGN.md](./DESIGN.md) for the
full design and current milestone.

## Running it

```sh
cd desktop-app
npm install
npm run tauri dev
```

You'll need your own Google OAuth client for Gmail/Drive access — see
[docs/google-oauth-setup.md](./docs/google-oauth-setup.md), or use a signed
release build (macOS) which ships with a default client baked in — see
[Releases](https://github.com/peterkracik/hey-pigeon/releases).

## iOS

A native SwiftUI app over the same Rust core lives in
[`ios-app/`](./ios-app) — design in [docs/ios.md](./docs/ios.md), the Siri
and on-device AI layer in [docs/ios-intelligence.md](./docs/ios-intelligence.md).
It targets iOS 27 and ships through TestFlight to the author's phone: the
inbox and gestures, compose, widgets and Live Activities, Siri through App
Intents and the Mail schema, Apple Intelligence as the zero-key AI with
Apple's cloud and OpenAI as opt-ins, "Ask my inbox" over the on-device
Spotlight index, an agentic "triage my inbox", and attachment
understanding. Personal, not a product; rough edges expected.

## macOS (native)

The same Swift shell runs as a native Mac app in
[`macos-app/`](./macos-app): sidebar, list and thread in one window, the
desktop's keyboard map (`e` `h` `n` `s` `j` `k`, `g`-chords, `⌘K`), hover
and trackpad actions, a Settings window, a menu bar extra, widgets, the
share menu, Siri and Spotlight through the same App Intents, and the same
AI layer (Apple Intelligence on the Mac, Apple's cloud and OpenAI as
opt-ins). It is the Mac download: every push to `main` that changes it
publishes a Developer ID-signed, notarized zip to the rolling
[`mac-latest`](https://github.com/peterkracik/hey-pigeon/releases/tag/mac-latest)
release, and installed copies update themselves from it (Sparkle, hourly,
in the background; Hey Pigeon › Check for Updates… does it now). The
original Tauri desktop client in `desktop-app/` is no longer built; its
`crates/` are the core both apps run on.

## License

Not currently licensed for reuse/redistribution — source is visible for
transparency, not (yet) an open contribution invitation.
