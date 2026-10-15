//! UniFFI boundary for native shells. Storage always calls the shell's vault;
//! this crate never opens a journal path or supplies an FsVault fallback.
use quire_core as core;
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum BridgeError {
    #[error("{message}")]
    Failure { message: String },
}
impl From<String> for BridgeError {
    fn from(message: String) -> Self {
        Self::Failure { message }
    }
}
type Result<T> = std::result::Result<T, BridgeError>;

#[derive(Clone, uniffi::Record)]
pub struct VaultItem {
    pub name: String,
    pub is_dir: bool,
    pub is_file: bool,
    pub len: u64,
}

#[uniffi::export(callback_interface)]
pub trait NativeVault: Send + Sync {
    fn read(&self, rel: String) -> Result<Option<Vec<u8>>>;
    fn write(&self, rel: String, bytes: Vec<u8>) -> Result<()>;
    fn remove(&self, rel: String) -> Result<bool>;
    fn rename(&self, from: String, to: String) -> Result<()>;
    fn list(&self, rel: String) -> Result<Vec<VaultItem>>;
    fn is_dir(&self, rel: String) -> bool;
    fn is_file(&self, rel: String) -> bool;
    fn len(&self, rel: String) -> u64;
    fn modified(&self, rel: String) -> Option<u64>;
}
struct CallbackVault(Box<dyn NativeVault>);
impl core::Vault for CallbackVault {
    fn read(&self, rel: &str) -> std::result::Result<Option<Vec<u8>>, String> {
        self.0.read(rel.into()).map_err(|e| e.to_string())
    }
    fn write(&self, rel: &str, bytes: &[u8]) -> std::result::Result<(), String> {
        self.0
            .write(rel.into(), bytes.into())
            .map_err(|e| e.to_string())
    }
    fn remove(&self, rel: &str) -> std::result::Result<bool, String> {
        self.0.remove(rel.into()).map_err(|e| e.to_string())
    }
    fn rename(&self, from: &str, to: &str) -> std::result::Result<(), String> {
        self.0
            .rename(from.into(), to.into())
            .map_err(|e| e.to_string())
    }
    fn list(&self, rel: &str) -> std::result::Result<Vec<core::Item>, String> {
        self.0
            .list(rel.into())
            .map(|items| {
                items
                    .into_iter()
                    .map(|i| core::Item {
                        name: i.name,
                        is_dir: i.is_dir,
                        is_file: i.is_file,
                        len: i.len,
                    })
                    .collect()
            })
            .map_err(|e| e.to_string())
    }
    fn is_dir(&self, rel: &str) -> bool {
        self.0.is_dir(rel.into())
    }
    fn is_file(&self, rel: &str) -> bool {
        self.0.is_file(rel.into())
    }
    fn len(&self, rel: &str) -> u64 {
        self.0.len(rel.into())
    }
    fn modified(&self, rel: &str) -> Option<u64> {
        self.0.modified(rel.into())
    }
    fn local_path(&self, _: &str) -> Option<PathBuf> {
        None
    }
}

// JSON carries core's existing serializable values without duplicating its
// data model. Requests are a closed enum, not an arbitrary filesystem RPC.
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Request {
    Load,
    Inbox,
    Migrate,
    New {
        ts: String,
        title: String,
        body: String,
    },
    Update {
        file: String,
        index: usize,
        raw: String,
        ts: String,
        title: String,
        body: String,
    },
    Delete {
        file: String,
        index: usize,
        raw: String,
    },
    File {
        file: String,
        index: usize,
        raw: String,
        tags: Vec<String>,
    },
    Unfile {
        file: String,
        index: usize,
        raw: String,
    },
    Import {
        text: String,
        ts: String,
    },
    Insert {
        file: String,
        raws: Vec<String>,
    },
    Sort,
    FileAll {
        tags: Vec<String>,
    },
    Cleanup {
        tags: Vec<String>,
    },
    Merge {
        tags: Vec<String>,
    },
    RenameTag {
        from: Vec<String>,
        to: String,
    },
    Files,
    Conflicts,
    MergeConflict {
        file: String,
    },
    FileTransfer {
        ts: String,
        tags: Vec<String>,
    },
    Read {
        file: String,
    },
    Write {
        file: String,
        content: String,
    },
    Sidecar {
        write: bool,
    },
    Records {
        prefix: String,
    },
    Templates,
    SaveTemplate {
        name: String,
        body: String,
    },
    DeleteTemplate {
        name: String,
    },
    Searches,
    SaveSearches {
        searches: Vec<core::SavedSearch>,
    },
    Orphans,
    DeleteOrphans,
    MergeContent {
        file: String,
        content: String,
    },
}
fn json<T: Serialize>(value: T) -> std::result::Result<String, String> {
    serde_json::to_string(&value).map_err(|e| e.to_string())
}

fn strict_tree(vault: &dyn core::Vault, rel: &str) -> std::result::Result<(), String> {
    for item in vault.list(rel)? {
        if item.is_dir {
            strict_tree(vault, &format!("{rel}/{}", item.name))?;
        }
    }
    Ok(())
}

#[derive(uniffi::Object)]
pub struct NativeJournal {
    journal: core::Journal,
    gate: Mutex<()>,
}
#[uniffi::export]
impl NativeJournal {
    #[uniffi::constructor]
    pub fn new(vault: Box<dyn NativeVault>) -> Arc<Self> {
        Arc::new(Self {
            journal: core::Journal::with_vault("native", Arc::new(CallbackVault(vault))),
            gate: Mutex::new(()),
        })
    }
    pub fn execute(&self, request: String) -> Result<String> {
        let _guard = self
            .gate
            .lock()
            .map_err(|_| BridgeError::from("Journal lock poisoned".to_string()))?;
        self.dispatch(serde_json::from_str(&request).map_err(|e| BridgeError::from(e.to_string()))?)
            .map_err(Into::into)
    }
}
impl NativeJournal {
    fn dispatch(&self, request: Request) -> std::result::Result<String, String> {
        let j = &self.journal;
        // Journal's convenience listing API tolerates unreadable directories.
        // Native snapshots and migrations must fail instead of mistaking an
        // evicted iCloud folder for an empty one.
        match &request {
            Request::Load
            | Request::Conflicts
            | Request::Migrate
            | Request::Files
            | Request::FileAll { .. }
            | Request::Cleanup { .. }
            | Request::Merge { .. }
            | Request::RenameTag { .. }
            | Request::Orphans
            | Request::DeleteOrphans => {
                j.vault().list("")?;
                for directory in ["inbox", "journal", "split"] {
                    strict_tree(j.vault(), directory)?;
                }
            }
            Request::Inbox | Request::Sort => {
                strict_tree(j.vault(), "inbox")?;
            }
            _ => {}
        }
        match request {
            Request::Load => json(j.try_load_all()?),
            Request::Inbox => {
                let mut entries = Vec::new();
                for file in j.inbox_files() {
                    entries.extend(j.try_load_file(&file)?);
                }
                json(entries)
            }
            Request::Migrate => {
                j.migrate_legacy_inbox()?;
                j.migrate_legacy_splits()?;
                json(true)
            }
            Request::New { ts, title, body } => json(j.new_draft(
                &ts,
                &core::strip_star(&title),
                core::has_star(&title),
                &body,
            )?),
            Request::Update {
                file,
                index,
                raw,
                ts,
                title,
                body,
            } => json(j.update_entry(
                &file,
                index,
                &raw,
                &ts,
                &core::strip_star(&title),
                core::has_star(&title),
                &body,
            )?),
            Request::Delete { file, index, raw } => {
                j.delete_entry(&file, index, &raw)?;
                json(true)
            }
            Request::File {
                file,
                index,
                raw,
                tags,
            } => json(j.file_draft(&file, index, &raw, &tags)?),
            Request::Unfile { file, index, raw } => json(j.unfile_entry(&file, index, &raw)?),
            Request::Import { text, ts } => json(j.import_text(&text, &ts)?),
            Request::Insert { file, raws } => json(
                j.insert_entries(&core::check_entry_rel(&file)?, &raws, true)?
                    .iter()
                    .filter(|i| i.is_some())
                    .count(),
            ),
            Request::Sort => json(core::sort_inbox(j)?),
            Request::FileAll { tags } => json(core::file_all(j, &tags)?),
            Request::Cleanup { tags } => json(core::cleanup(j, &tags)?),
            Request::Merge { tags } => json(core::merge_ex_split(j, &tags)?),
            Request::RenameTag { from, to } => json(core::rename_tags(j, &from, &to)?),
            Request::Conflicts => json(j.conflict_files()),
            Request::MergeConflict { file } => json(core::merge_conflict(j, &file)?),
            Request::FileTransfer { ts, tags } => json(core::import_transfer(j, &ts, &tags)?),
            Request::Files => json(j.entry_files().into_iter().map(|f| f.0).collect::<Vec<_>>()),
            Request::Read { file } => json(j.try_read(&core::check_rel(&file)?)?),
            Request::Write { file, content } => {
                j.write(&core::check_rel(&file)?, &content)?;
                json(true)
            }
            Request::Sidecar { write } => json(if write { j.sidecar_mut()? } else { j.sidecar() }),
            Request::Records { prefix } => {
                let mut records = std::collections::BTreeMap::new();
                for dir in [".nook", ".quire"] {
                    for item in j.vault().list(dir)? {
                        if item.is_file
                            && item.name.starts_with(&prefix)
                            && item.name.ends_with(".json")
                        {
                            records.insert(
                                item.name.clone(),
                                j.try_read(&format!("{dir}/{}", item.name))?,
                            );
                        }
                    }
                }
                json(records.into_values().collect::<Vec<_>>())
            }
            Request::Templates => json(core::list_templates(j)),
            Request::SaveTemplate { name, body } => {
                core::save_template(j, &name, &body)?;
                json(true)
            }
            Request::DeleteTemplate { name } => {
                core::delete_template(j, &name)?;
                json(true)
            }
            Request::Searches => json(core::load_searches(j)),
            Request::SaveSearches { searches } => {
                core::save_searches(j, &searches)?;
                json(true)
            }
            Request::Orphans => json(
                core::list_assets(j)?
                    .into_iter()
                    .filter(|a| !a.referenced)
                    .map(|a| a.rel)
                    .collect::<Vec<_>>(),
            ),
            Request::DeleteOrphans => json(core::delete_orphans(j)?),
            Request::MergeContent { file, content } => {
                let file = core::check_entry_rel(&file)?;
                let raws = core::parse_entries(&content)
                    .into_iter()
                    .map(|e| e.raw)
                    .collect::<Vec<_>>();
                json(
                    j.insert_entries(&file, &raws, true)?
                        .iter()
                        .filter(|i| i.is_some())
                        .count(),
                )
            }
        }
    }
}

#[uniffi::export]
pub fn parse_text(text: String) -> String {
    let entries = core::parse_entries(&core::normalised(&text)).into_iter().map(|e| serde_json::json!({"date":e.date,"ts":e.ts,"suffix":e.suffix,"body":e.body,"raw":e.raw})).collect::<Vec<_>>();
    serde_json::to_string(&entries).expect("plain entry values serialize")
}
#[uniffi::export]
pub fn preamble(text: String) -> String {
    core::leading_preamble(&core::normalised(&text))
}
#[uniffi::export]
pub fn render_text(pre: String, raws: Vec<String>) -> String {
    core::render(&pre, &raws)
}
#[uniffi::export]
pub fn tags_in(text: String) -> Vec<String> {
    core::TAG_RE
        .find_iter(&text)
        .map(|m| m.as_str().to_string())
        .collect()
}
#[uniffi::export]
pub fn header_line(line: String) -> bool {
    core::is_header_line(&line)
}
#[uniffi::export]
pub fn make_text(ts: String, title: String, body: String) -> String {
    core::make_raw(
        &ts,
        &core::strip_star(&title),
        core::has_star(&title),
        &body,
    )
}
#[uniffi::export]
pub fn punctuation(text: String) -> String {
    core::fix_punctuation(&text)
}

#[uniffi::export]
pub fn search_query(text: String) -> String {
    let q = core::search::Query::parse(&text);
    serde_json::json!({"terms":q.terms,"tags":q.tags,"before":q.before,"after":q.after,"has":q.has,"starred":q.starred}).to_string()
}
#[uniffi::export]
pub fn search_matches(query: String, raw: String, file: String) -> bool {
    let Some(e) = core::parse_entries(&core::normalised(&raw))
        .into_iter()
        .next()
    else {
        return false;
    };
    let entry = core::Entry {
        file,
        index: 0,
        source: String::new(),
        split: None,
        time: e.ts.get(11..).unwrap_or("").into(),
        title: core::strip_star(&e.suffix),
        starred: core::has_star(&e.suffix),
        tags: core::TAG_RE
            .find_iter(&e.raw)
            .map(|m| m.as_str().to_string())
            .collect(),
        words: e.body.split_whitespace().count(),
        ts: e.ts,
        date: e.date,
        body: e.body,
        raw: e.raw,
    };
    core::search::Query::parse(&query).matches(&entry)
}
#[derive(uniffi::Enum)]
pub enum ListAction {
    None,
    Continue { prefix: String },
    End { utf16_length: u32 },
}
#[uniffi::export]
pub fn continue_list(line: String) -> ListAction {
    match core::editing::list_continuation(&line) {
        None => ListAction::None,
        Some(core::editing::ListStep::Continue(prefix)) => ListAction::Continue { prefix },
        Some(core::editing::ListStep::End(n)) => ListAction::End {
            utf16_length: line.chars().take(n).map(char::len_utf16).sum::<usize>() as u32,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use quire_core::Vault;
    use serde_json::{json, Value};

    struct TestVault {
        fs: core::FsVault,
        fail_list: bool,
    }
    impl NativeVault for TestVault {
        fn read(&self, rel: String) -> Result<Option<Vec<u8>>> {
            self.fs.read(&rel).map_err(Into::into)
        }
        fn write(&self, rel: String, bytes: Vec<u8>) -> Result<()> {
            self.fs.write(&rel, &bytes).map_err(Into::into)
        }
        fn remove(&self, rel: String) -> Result<bool> {
            self.fs.remove(&rel).map_err(Into::into)
        }
        fn rename(&self, from: String, to: String) -> Result<()> {
            self.fs.rename(&from, &to).map_err(Into::into)
        }
        fn list(&self, rel: String) -> Result<Vec<VaultItem>> {
            if self.fail_list && rel == "inbox" {
                return Err("Cloud folder unavailable".to_string().into());
            }
            Ok(self
                .fs
                .list(&rel)?
                .into_iter()
                .map(|i| VaultItem {
                    name: i.name,
                    is_dir: i.is_dir,
                    is_file: i.is_file,
                    len: i.len,
                })
                .collect())
        }
        fn is_dir(&self, rel: String) -> bool {
            self.fs.is_dir(&rel)
        }
        fn is_file(&self, rel: String) -> bool {
            self.fs.is_file(&rel)
        }
        fn len(&self, rel: String) -> u64 {
            self.fs.len(&rel)
        }
        fn modified(&self, rel: String) -> Option<u64> {
            self.fs.modified(&rel)
        }
    }
    fn journal(d: &tempfile::TempDir) -> Arc<NativeJournal> {
        NativeJournal::new(Box::new(TestVault {
            fs: core::FsVault::new(d.path()),
            fail_list: false,
        }))
    }
    fn call(j: &NativeJournal, request: Value) -> Value {
        serde_json::from_str(&j.execute(request.to_string()).unwrap()).unwrap()
    }
    fn edit(w: &Value, ts: &str, title: &str) -> Value {
        json!({"op":"update", "file":w["file"], "index":w["index"], "raw":w["raw"], "ts":ts,"title":title,"body":"edited"})
    }
    #[test]
    fn callback_roundtrip_moves_draft_split_and_back() {
        let d = tempfile::tempdir().unwrap();
        let j = journal(&d);
        let w = call(
            &j,
            json!({"op":"new","ts":"2026-10-15 08:00:00","title":"First *","body":"A photo @work ![](assets/a.jpg)"}),
        );
        assert_eq!(w["file"], "inbox/2026/10/15.md");
        let label = call(
            &j,
            json!({"op":"file","file":w["file"],"index":w["index"],"raw":w["raw"],"tags":["@work"]}),
        );
        assert_eq!(label, "split/work/2026/10/15.md");
        let all = call(&j, json!({"op":"load"}));
        let e = &all[0];
        assert_eq!(e["file"], "split/work/2026/10/15.md");
        assert_eq!(e["starred"], true);
        let moved = call(&j, edit(e, "2026-10-16 08:00:00", "Second @work"));
        assert_eq!(moved["file"], "split/work/2026/10/16.md");
        let back = call(
            &j,
            json!({"op":"unfile","file":moved["file"],"index":moved["index"],"raw":moved["raw"]}),
        );
        assert_eq!(back["file"], "inbox/2026/10/16.md");
        call(
            &j,
            json!({"op":"delete","file":back["file"],"index":back["index"],"raw":back["raw"]}),
        );
        assert!(call(&j, json!({"op":"load"}))
            .as_array()
            .unwrap()
            .is_empty());
        assert!(!d.path().join("inbox/2026/10/16.md").exists());
    }
    #[test]
    fn stale_index_relocates_but_changed_raw_is_rejected() {
        let d = tempfile::tempdir().unwrap();
        let j = journal(&d);
        let a = call(
            &j,
            json!({"op":"new","ts":"2026-10-15 08:00:00","title":"A","body":"one"}),
        );
        let b = call(
            &j,
            json!({"op":"new","ts":"2026-10-15 08:00:00","title":"B","body":"two"}),
        );
        call(
            &j,
            json!({"op":"delete","file":a["file"],"index":a["index"],"raw":a["raw"]}),
        );
        let w = call(&j, edit(&b, "2026-10-15 08:00:00", "B revised"));
        assert_eq!(w["index"], 0);
        assert!(j
            .execute(edit(&b, "2026-10-15 08:00:00", "stale").to_string())
            .is_err());
        assert_eq!(call(&j, json!({"op":"load"}))[0]["title"], "B revised");
    }
    #[test]
    fn legacy_migrations_and_sidecar_writes_use_callback() {
        let d = tempfile::tempdir().unwrap();
        let fs = core::FsVault::new(d.path());
        fs.write(
            "inbox.md",
            b"Preamble\n\n[2026-10-15 08:00:00] draft\nbody\n",
        )
        .unwrap();
        fs.write("work.md", b"[2026-10-14 08:00:00] split\n@work\n")
            .unwrap();
        fs.write(".nook/templates/old.md", b"Old template").unwrap();
        let j = journal(&d);
        call(&j, json!({"op":"migrate"}));
        assert_eq!(call(&j, json!({"op":"load"})).as_array().unwrap().len(), 2);
        assert!(!d.path().join("inbox.md").exists());
        assert!(!d.path().join("work.md").exists());
        call(
            &j,
            json!({"op":"save_template","name":"new","body":"New template"}),
        );
        assert!(d.path().join(".quire/templates/old.md").is_file());
        assert_eq!(
            call(&j, json!({"op":"templates"}))
                .as_array()
                .unwrap()
                .len(),
            2
        );
    }
    #[test]
    fn unreadable_data_and_failed_directory_listing_never_become_empty_snapshots() {
        let d = tempfile::tempdir().unwrap();
        let fs = core::FsVault::new(d.path());
        fs.write("inbox/2026/10/15.md", &[0xff]).unwrap();
        let j = journal(&d);
        assert!(j.execute(json!({"op":"load"}).to_string()).is_err());
        assert!(j
            .execute(
                json!({"op":"new","ts":"2026-10-15 08:00:00","title":"lost","body":"no"})
                    .to_string()
            )
            .is_err());
        assert_eq!(fs.read("inbox/2026/10/15.md").unwrap().unwrap(), vec![0xff]);
        let j = NativeJournal::new(Box::new(TestVault {
            fs,
            fail_list: true,
        }));
        assert!(j
            .execute(json!({"op":"load"}).to_string())
            .unwrap_err()
            .to_string()
            .contains("Cloud folder unavailable"));
        assert!(j.execute(json!({"op":"migrate"}).to_string()).is_err());
    }
    #[test]
    fn native_request_rejects_paths_outside_journal() {
        let d = tempfile::tempdir().unwrap();
        let j = journal(&d);
        for file in ["../escape.md", "/tmp/escape.md"] {
            assert!(j
                .execute(json!({"op":"write","file":file,"content":"no"}).to_string())
                .is_err());
            assert!(j
                .execute(json!({"op":"insert","file":file,"raws":[]}).to_string())
                .is_err());
        }
    }
    #[test]
    fn swift_format_search_and_editor_exports_share_core_rules() {
        let text = "\u{feff}[2026–10–15 08:00:00] Bold **title**\r\nText @work\r\n";
        let es: Value = serde_json::from_str(&parse_text(text.into())).unwrap();
        assert_eq!(es[0]["ts"], "2026-10-15 08:00:00");
        assert!(search_matches(
            "tag:work after:2026-10".into(),
            es[0]["raw"].as_str().unwrap().into(),
            "inbox/2026/10/15.md".into()
        ));
        assert!(!search_matches(
            "is:starred".into(),
            es[0]["raw"].as_str().unwrap().into(),
            "inbox.md".into()
        ));
        assert!(matches!(
            continue_list("18446744073709551615. x".into()),
            ListAction::Continue { .. }
        ));
        assert_eq!(
            core::parse_entries(&make_text(
                "2026-10-15 08:00:00".into(),
                "Title".into(),
                "body\n[2026-10-16 08:00:00] pasted".into()
            ))
            .len(),
            1
        );
    }
}
