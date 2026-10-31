# CLAUDE.md

Hey Pigeon is a local-first Gmail client: no backend (README.md, DESIGN.md).
Each part has its own guide; read the one for the folder you work in.

| Folder | What | Guide |
| --- | --- | --- |
| `ios-app/` | SwiftUI app (iPhone, iPad) over the Rust core; `HeyPigeon/` is also the Mac app's shared shell | `ios-app/CLAUDE.md`, `ios-app/README.md`, `docs/ios.md`, `docs/ios-intelligence.md`, `docs/porting-macos-ipados.md` |
| `macos-app/` | Native SwiftUI Mac app (macOS 27, Liquid Glass) over the same shell and core | `macos-app/CLAUDE.md`, `macos-app/README.md`, `docs/porting-macos-ipados.md` |
| `desktop-app/` | Tauri + Svelte Mac app; `crates/` is the Rust core shared with iOS and the native Mac app | `DESIGN.md` |
| `relay/`, `terraform/` | Optional push relay for iOS (sees an address and a change counter, never mail) | `relay/README.md`, `terraform/README.md` |
| `site/` | heypigeon.app | — |

CI: `rust-ci` (crates), `ios-ci` (iOS build + tests on PRs), `macos-ci`
(native Mac build + tests on PRs), `publish-ios` (main → TestFlight),
`publish-macos` (main → the notarized `mac-latest` build; `mac-v*` tags →
a versioned release), `build-macos` (Tauri desktop). A change to `desktop-app/crates` or to `ios-app/HeyPigeon` also
rebuilds the iOS app and the Mac app, so keep `ios-ci` and `macos-ci` green
for it too.
