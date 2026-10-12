//! quire-core — the one journal core behind every Quire shell.
//!
//! The on-disk format is jnl's, byte for byte (see `journal`). Everything a
//! shell needs that is not a window lives here: parsing and rendering,
//! filing and moving entries, split journals, templates, saved searches,
//! media and Data Saver, cleanup, backup, imports, stats.
//!
//! Shells: the Linux Tauri app (`linux/`), the terminal app (`tui/`), and the
//! Swift and Kotlin shells to come, which reach this crate over a bridge.

pub mod extras;
pub mod journal;
pub mod media;
pub mod vault;

pub use extras::*;
pub use journal::*;
pub use vault::{FsVault, Item, Vault};
