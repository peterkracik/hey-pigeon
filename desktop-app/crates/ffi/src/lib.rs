//! UniFFI facade over the Hey Pigeon core for native shells (iOS first).
//!
//! This crate is to the SwiftUI app what `src-tauri/src/mail.rs` is to the
//! Svelte app: the thin wiring layer that owns the store, the secret store
//! and the Gmail provider, and exposes the same operations the IPC contract
//! does (`desktop-app/src/lib/ipc.ts`). All logic stays in `core` and the
//! adapters; nothing here knows about views.
//!
//! Shape rules (DESIGN.md "UI is a projection"):
//! - Records mirror the domain types field for field, so the Swift side
//!   reads the same shapes the Svelte side does.
//! - Reads are synchronous (SQLite, local, instant). Anything that may touch
//!   the network is `async` and shows up as `async throws` in Swift.
//! - The shell drives the sync cadence (foreground timer, background
//!   refresh): the engine exposes `sync_all`, it never spawns its own loop.
//!   iOS suspends background work, so a loop would only mislead.

uniffi::setup_scaffolding!();

mod ai;
mod engine;
mod push;
mod secrets;
mod settings;
mod types;

pub use ai::*;
pub use engine::*;
pub use types::*;
