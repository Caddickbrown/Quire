//! The printed commands, run as a script would run them: what they exit
//! with, and what they leave on disk. Each run has a home and a settings
//! folder of its own, so the real ones are never read or written. (`update`
//! is not run here: it would reach the network. Its arguments are tested in
//! `update.rs`.)

use std::path::Path;
use std::process::{Command, Output, Stdio};

struct Run {
    home: tempfile::TempDir,
}

impl Run {
    fn new() -> Run {
        Run { home: tempfile::tempdir().unwrap() }
    }

    fn config(&self) -> std::path::PathBuf {
        self.home.path().join("config/quire")
    }

    fn settings(&self, json: &str) {
        std::fs::create_dir_all(self.config()).unwrap();
        std::fs::write(self.config().join("settings.json"), json).unwrap();
    }

    fn quire(&self, args: &[&str], stdin: &str) -> Output {
        use std::io::Write;
        let mut child = Command::new(env!("CARGO_BIN_EXE_quire"))
            .args(args)
            .env("HOME", self.home.path())
            .env("XDG_CONFIG_HOME", self.home.path().join("config"))
            .env("QUIRE_CONFIG_DIR", self.config())
            .env_remove("JNL_DIR")
            .env_remove("JNL_SPLIT_TAGS")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
        child.wait_with_output().unwrap()
    }
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).to_string()
}

fn write(root: &Path, rel: &str, body: &str) {
    let p = root.join(rel);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, body).unwrap();
}

/// Review of 14 November, T7.
#[test]
fn a_command_that_fails_exits_with_a_failure() {
    let run = Run::new();
    let journal = run.home.path().join("j");
    write(&journal, "journal/2026/03/04.md", "[2026-03-04 10:00:00] One\nbody\n");
    let folder = journal.to_str().unwrap();
    // It works, and says so with 0.
    let out = run.quire(&["--folder", folder, "import"], "A thought\n\nand its body\n");
    assert!(out.status.success(), "{}", text(&out.stderr));
    assert!(text(&out.stdout).contains("1 draft(s) added"));
    let out = run.quire(&["--folder", folder, "export", run.home.path().join("out.md").to_str().unwrap()], "");
    assert!(out.status.success() && run.home.path().join("out.md").exists(), "{}", text(&out.stderr));
    // Nowhere to write the export: an error and a status to match.
    let nowhere = run.home.path().join("out.md/inside-a-file.md");
    let out = run.quire(&["--folder", folder, "export", nowhere.to_str().unwrap()], "");
    assert_eq!(out.status.code(), Some(1), "{}{}", text(&out.stdout), text(&out.stderr));
    assert!(text(&out.stderr).contains("error:"));
    // An inbox that can't be read: `sort` and `import` stop the pipeline too.
    write(&journal, "inbox/2026/03/05.md", "");
    std::fs::write(journal.join("inbox/2026/03/05.md"), [0xff, 0xfe, 0x00, 0xc3]).unwrap();
    let out = run.quire(&["--folder", folder, "sort"], "");
    assert_eq!(out.status.code(), Some(1), "{}{}", text(&out.stdout), text(&out.stderr));
    // Input that is not text is a read error, not an empty import.
    std::fs::remove_file(journal.join("inbox/2026/03/05.md")).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_quire"))
        .args(["--folder", folder, "import"])
        .env("HOME", run.home.path())
        .env("QUIRE_CONFIG_DIR", run.config())
        .env_remove("JNL_DIR")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    use std::io::Write;
    child.stdin.take().unwrap().write_all(&[0xff, 0xfe, 0x00, 0xc3]).unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1), "{}{}", text(&out.stdout), text(&out.stderr));
    assert!(text(&out.stderr).contains("couldn't read"), "{}", text(&out.stderr));
}

/// T15: asking for help makes no folder and migrates nothing.
#[test]
fn help_touches_nothing() {
    let run = Run::new();
    for args in [&["help"][..], &["--help"], &["-h"], &[], &["some", "title"]] {
        let out = run.quire(args, "");
        assert!(out.status.success(), "{args:?}: {}", text(&out.stderr));
        assert!(text(&out.stdout).contains("browse filed entries"), "{args:?}");
    }
    assert!(!run.home.path().join("notes").exists(), "no ~/notes was made to print the help");
    // With a folder named, a legacy inbox.md is left for a command that reads the journal.
    let journal = run.home.path().join("j");
    write(&journal, "inbox.md", "[2026-03-04 10:00:00] Old\nbody\n");
    let out = run.quire(&["--folder", journal.to_str().unwrap(), "help"], "");
    assert!(out.status.success());
    assert!(journal.join("inbox.md").exists() && !journal.join("inbox").exists(), "help migrated the inbox");
    let missing = run.home.path().join("not-made");
    let out = run.quire(&["--folder", missing.to_str().unwrap(), "--help"], "");
    assert!(out.status.success() && !missing.exists());
}

/// T3: the settings' folder is gone (a drive not mounted, a folder renamed).
#[test]
fn a_missing_settings_folder_stops_quire() {
    let run = Run::new();
    let gone = run.home.path().join("Journal on a drive");
    run.settings(&format!("{{\"folder\": {:?}}}", gone.to_str().unwrap()));
    let out = run.quire(&["inbox"], "");
    assert_eq!(out.status.code(), Some(2), "{}{}", text(&out.stdout), text(&out.stderr));
    let said = text(&out.stderr);
    assert!(said.contains("isn't there") && said.contains("Journal on a drive") && said.contains("--folder PATH"), "{said}");
    assert!(!run.home.path().join("notes").exists(), "no new journal in ~/notes");
    assert!(!gone.exists(), "and the missing folder is not made either");
    // Named outright, another folder is used as asked.
    let other = run.home.path().join("other");
    let out = run.quire(&["--folder", other.to_str().unwrap(), "inbox"], "");
    assert!(out.status.success(), "{}", text(&out.stderr));
    // Back in place, it is the journal again.
    write(&gone, "inbox/2026/03/04.md", "[2026-03-04 10:00:00] Here\nbody\n");
    let out = run.quire(&["inbox"], "");
    assert!(out.status.success() && text(&out.stdout).contains("Here"), "{}", text(&out.stderr));
}

/// T16: an option with no value, or one Quire doesn't have, is an error.
#[test]
fn a_bad_option_is_said_and_writes_nothing() {
    let run = Run::new();
    for args in [&["--folder"][..], &["--fodler", "x"], &["--theme"]] {
        let out = run.quire(args, "");
        assert_eq!(out.status.code(), Some(2), "{args:?}");
        assert!(text(&out.stderr).contains("--help"), "{args:?}: {}", text(&out.stderr));
    }
    assert!(!run.home.path().join("notes").exists());
}

/// Review 12: `quire update` replaces a `jnl` beside it only when it is
/// Quire's, judged by its bytes; both built binaries pass that test.
#[test]
fn both_binaries_are_recognised_as_quires() {
    for bin in [env!("CARGO_BIN_EXE_quire"), env!("CARGO_BIN_EXE_jnl")] {
        assert!(quire_tui::update::is_quires(Path::new(bin)), "{bin}");
    }
}
