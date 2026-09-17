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
It's a local Tauri app that talks directly to Google's APIs using your own
OAuth grant:

- Your mail, contacts, and reminders never leave **your own Google account** —
  Gmail for mail, and a hidden per-app Drive folder (`appDataFolder`) for
  cross-device reminder sync.
- Everything the app reads is cached in a local SQLite database on your
  device, purely for instant local search/browsing.
- AI features (optional) are bring-your-own-API-key: requests go straight
  from your device to the provider (OpenAI first) — the developer never sees
  that traffic or holds your key.

Because there's no backend and no third-party data store, there's no
"Hey Pigeon got breached" risk model to worry about — your data's exposure
surface is exactly your own Google account's, unchanged by using this app.

## Status

Early, personal, actively-changing. See [DESIGN.md](./DESIGN.md) for the
full design and current milestone.

## Running it

```sh
npm install
npm run tauri dev
```

You'll need your own Google OAuth client for Gmail/Drive access — see
[docs/google-oauth-setup.md](./docs/google-oauth-setup.md), or use a signed
release build (macOS) which ships with a default client baked in — see
[Releases](https://github.com/peterkracik/hey-pigeon/releases).

## License

Not currently licensed for reuse/redistribution — source is visible for
transparency, not (yet) an open contribution invitation.
