//! quire-core — the one journal core behind every Quire shell.
//!
//! The on-disk format is jnl's, byte for byte (see `journal`). Everything a
//! shell needs that is not a window lives here: parsing and rendering,
//! filing and moving entries, split journals, templates, saved searches,
//! media and Data Saver, cleanup, backup, imports, stats.
//!
//! Shells: the Linux Tauri app (`linux/`), the terminal app (`tui/`), and the
//! Swift shell (`apple/`) over UniFFI (`bindings/`); Kotlin comes later.

pub mod editing;
pub mod extras;
pub mod journal;
pub mod media;
pub mod prompts;
pub mod search;
pub mod settings;
pub mod stats;
pub mod themes;
pub mod vault;

pub use extras::*;
pub use journal::*;
pub use settings::Settings;
pub use vault::{FsVault, Item, Vault};

mod media_cleanup;
pub use media_cleanup::{archive_orphan_media, cleanup_media, orphan_media, MediaCleanupReport};
