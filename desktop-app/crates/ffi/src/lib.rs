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
mod bundles;
mod contacts;
mod engine;
mod keyed;
mod mailbox;
mod push;
mod secrets;
mod settings;
mod suggest;
mod types;

pub use ai::*;
pub use bundles::*;
pub use engine::*;
pub use types::*;

/// The core's HTML sanitizer (`heypigeon_core::sanitize::html`), as the
/// engine applies it to every mail body and draft before the shell gets
/// one: for the shell's own tests, and for HTML that reaches it some
/// other way. Sanitizing twice changes nothing: a body that holds
/// tracker markers ends in a seal (`<!--hp-seal:…-->`) the sanitizer
/// knows its own output by. HTML without a valid one is treated as mail —
/// names beginning `hp-` are taken from it, a marker's class included —
/// so a sanitized body that was edited since has no markers left.
#[uniffi::export]
pub fn sanitize_html(html: String) -> String {
    heypigeon_core::sanitize::html(&html)
}
