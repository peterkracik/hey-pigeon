# CLAUDE.md

Hey Pigeon is a local-first Gmail client: no backend (README.md, DESIGN.md).
Each part has its own guide; read the one for the folder you work in.

| Folder | What | Guide |
| --- | --- | --- |
| `ios-app/` | SwiftUI app (iPhone, iPad) over the Rust core | `ios-app/CLAUDE.md`, `ios-app/README.md`, `docs/ios.md`, `docs/ios-intelligence.md`, `docs/porting-macos-ipados.md` |
| `desktop-app/` | Tauri + Svelte Mac app; `crates/` is the Rust core shared with iOS | `DESIGN.md` |
| `relay/`, `terraform/` | Optional push relay for iOS (sees an address and a change counter, never mail) | `relay/README.md`, `terraform/README.md` |
| `site/` | heypigeon.app | — |

CI: `rust-ci` (crates), `ios-ci` (iOS build + tests on PRs), `publish-ios`
(main → TestFlight), `build-macos` (desktop). A change to `desktop-app/crates`
also rebuilds and ships the iOS app, so keep `ios-ci` green for it too.
