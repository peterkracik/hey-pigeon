//! heypigeon core: domain types, ports, sync + outbox logic.
//! Depends on traits only — adapters live in sibling crates.

pub mod devsync;
pub mod domain;
pub mod fakes;
pub mod outbox;
pub mod ports;
pub mod search;
pub mod sync;
