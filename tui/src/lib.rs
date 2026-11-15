//! Quire in the terminal. One binary, two names: installed as `quire` and as
//! `jnl`, and every jnl subcommand keeps its spelling.

pub const VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), env!("QUIRE_GIT_SUFFIX"));

pub mod app;
mod backup;
pub mod cli;
pub mod editor;
pub mod md;
pub mod paste;
pub mod theme;
pub mod ui;
pub mod update;

use quire_core::*;
use std::io::IsTerminal;
use std::path::PathBuf;

#[derive(Debug)]
pub struct Opts {
    pub folder: Option<String>,
    pub theme: Option<String>,
    pub args: Vec<String>,
}

/// Commands whose arguments are fixed words, so an option may follow them
/// (`quire migrate --folder PATH`).
const PLAIN_COMMANDS: [&str; 20] = [
    "review", "browse", "inbox", "sort", "yesterday", "list", "ls", "stats", "tags", "random", "transfer", "cleanup", "open", "config", "migrate", "import",
    "help", "--help", "-h", "--version",
];
/// Commands whose arguments are the writer's own words (a title, a query, a
/// tag, a path) or another program's (`update`): nothing after them is taken
/// as one of Quire's options.
const TEXT_COMMANDS: [&str; 6] = ["new", "log", "search", "tag", "export", "update"];

fn is_date(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 10 && b.iter().enumerate().all(|(i, c)| if i == 4 || i == 7 { *c == b'-' } else { c.is_ascii_digit() })
}

/// Is this a command, and not the first word of a new draft's title?
fn is_command(cmd: &str) -> bool {
    PLAIN_COMMANDS.contains(&cmd) || TEXT_COMMANDS.contains(&cmd) || cmd == "-V" || is_date(cmd)
}

/// `--folder PATH` (`--dir`, `-C`) and `--theme NAME`, also as `--folder=PATH`.
/// They come before the command, or after one that takes no words of its
/// own. After `new`, a title, a query or `--`, everything is text: `quire new
/// My --theme song` is a draft with that title, not a change of theme.
fn parse_opts(args: Vec<String>) -> Result<Opts, String> {
    let mut o = Opts { folder: None, theme: None, args: Vec::new() };
    let mut it = args.into_iter();
    let mut text = false;
    while let Some(a) = it.next() {
        if text {
            o.args.push(a);
            continue;
        }
        let (flag, inline) = match a.split_once('=') {
            Some((f, v)) if f.starts_with('-') => (f.to_string(), Some(v.to_string())),
            _ => (a.clone(), None),
        };
        match flag.as_str() {
            "--" if inline.is_none() => text = true,
            "--folder" | "--dir" | "-C" | "--theme" => {
                let value = inline.or_else(|| it.next()).filter(|v| !v.trim().is_empty());
                let Some(value) = value else {
                    return Err(format!("{} needs a {}", flag, if flag == "--theme" { "theme's name" } else { "folder" }));
                };
                if flag == "--theme" {
                    o.theme = Some(value);
                } else {
                    o.folder = Some(value);
                }
            }
            _ if o.args.is_empty() && a.starts_with("--") && !PLAIN_COMMANDS.contains(&a.as_str()) => {
                return Err(format!("{} is not an option Quire has (a title that starts with it goes after --)", a));
            }
            _ => {
                // The command, or the first word of a title.
                text = o.args.is_empty() && !PLAIN_COMMANDS.contains(&a.as_str());
                o.args.push(a);
            }
        }
    }
    Ok(o)
}

/// The folder Quire's settings name, when it is not there: a drive that
/// isn't mounted, a folder moved or renamed. Never a reason to start another
/// journal somewhere else without saying so.
fn missing_settings_folder(settings: &Settings) -> Option<&str> {
    settings.folder.as_deref().filter(|f| !Settings::is_sample_folder(f) && !std::path::Path::new(f).is_dir())
}

/// A printed command that failed: say so and leave with a status a script
/// (`quire import && …`) can see.
fn done(result: Result<(), String>) {
    if let Err(e) = result {
        eprintln!("  error: {}", e);
        std::process::exit(1);
    }
}

/// The journal folder: `--folder`, else `$JNL_DIR`, else Quire's settings
/// (never the Linux app's sample), else jnl's config, else `~/notes`.
pub fn resolve_folder(opts: &Opts, settings: &Settings) -> PathBuf {
    if let Some(f) = &opts.folder {
        return PathBuf::from(expand_home(f));
    }
    if let Ok(d) = std::env::var("JNL_DIR") {
        if !d.trim().is_empty() {
            return PathBuf::from(expand_home(d.trim()));
        }
    }
    if let Some(f) = &settings.folder {
        if !Settings::is_sample_folder(f) && std::path::Path::new(f).is_dir() {
            return PathBuf::from(f);
        }
    }
    if let Some(d) = jnl_config().remove("JNL_DIR") {
        return PathBuf::from(expand_home(d.trim()));
    }
    dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")).join("notes")
}

/// The journal the settings mean when no `--folder` is given: Quire's own
/// folder when it has one, else whatever jnl's rules resolve to. Backups of
/// any other folder are kept apart from this one's.
fn home_folder(settings: &Settings) -> PathBuf {
    match &settings.folder {
        Some(f) if !Settings::is_sample_folder(f) && std::path::Path::new(f).is_dir() => PathBuf::from(f),
        _ => resolve_folder(&Opts { folder: None, theme: None, args: Vec::new() }, settings),
    }
}

fn same_folder(a: &std::path::Path, b: &std::path::Path) -> bool {
    let real = |p: &std::path::Path| p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
    real(a) == real(b)
}

/// A settings file that was set aside because it didn't parse, when there is
/// no settings file now: the defaults in use are not the person's choices.
fn set_aside_settings() -> Option<PathBuf> {
    let path = Settings::path();
    if path.exists() {
        return None;
    }
    let mut bad: Vec<PathBuf> = std::fs::read_dir(path.parent()?).ok()?.flatten().map(|e| e.path())
        .filter(|p| p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("settings.json.bad-")))
        .collect();
    bad.sort();
    bad.pop()
}

pub fn run(name: &str) {
    let opts = match parse_opts(std::env::args().skip(1).collect()) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("  {}", e);
            eprintln!("  {} --help lists the commands and options.", name);
            std::process::exit(2);
        }
    };
    let cmd = opts.args.first().map(|s| s.as_str()).unwrap_or("");
    if cmd == "--version" || cmd == "-V" {
        println!("Quire {}", VERSION);
        return;
    }
    // Before the folder: updating the program never touches a journal.
    if cmd == "update" {
        std::process::exit(update::run(&opts.args[1..]));
    }
    // Nor does asking what the commands are: no folder is made, nothing is
    // migrated. In a pipe, anything that is not a command gets the same.
    let tty = std::io::stdout().is_terminal();
    if matches!(cmd, "help" | "--help" | "-h") || (!tty && !is_command(cmd)) {
        cli::help(name);
        return;
    }
    // Settings that can't be used are never quietly replaced by defaults: the
    // folder would then be a guess (jnl's config, or a new ~/notes), and the
    // real journal would look empty or gone.
    let named = opts.folder.is_some() || std::env::var("JNL_DIR").is_ok_and(|d| !d.trim().is_empty());
    let mut warning: Option<String> = None;
    let settings = match Settings::try_load() {
        Ok(s) => s,
        Err(e) => {
            if !named {
                eprintln!("  {}", e);
                eprintln!("  Without its settings Quire would be guessing at the journal folder, so it has stopped.");
                eprintln!("  Put the settings file right, or name the folder: {} --folder PATH", name);
                std::process::exit(2);
            }
            eprintln!("  note: {}", e);
            warning = Some(e);
            // Defaults that `save` refuses to write over a file it couldn't read.
            let s = Settings::load();
            let _ = Settings::take_load_warning();
            s
        }
    };
    if warning.is_none() && settings.folder.is_none() {
        if let Some(bad) = set_aside_settings() {
            let w = format!("Settings are at their defaults: the last settings file couldn't be read and is kept as {} (delete it once you have what you need from it)", bad.display());
            eprintln!("  note: {}", w);
            warning = Some(w);
        }
    }
    if let Some(gone) = missing_settings_folder(&settings).filter(|_| !named) {
        eprintln!("  The journal folder in Quire's settings isn't there: {}", gone);
        eprintln!("  A drive that isn't mounted, or a folder that was moved or renamed? Quire has stopped rather than start another journal somewhere else.");
        eprintln!("  Put it back, or name a folder: {} --folder PATH", name);
        std::process::exit(2);
    }
    let folder = resolve_folder(&opts, &settings);
    if !folder.is_dir() {
        if warning.is_some() && !named {
            eprintln!("  {} isn't there, and Quire won't start a new journal while its settings are in doubt.", folder.display());
            eprintln!("  Name the folder: {} --folder PATH", name);
            std::process::exit(2);
        }
        if let Err(e) = std::fs::create_dir_all(&folder) {
            eprintln!("  Can't use {}: {}", folder.display(), e);
            std::process::exit(2);
        }
    }
    let j = Journal::open(&folder);
    let split_tags = split_tags_from(&settings.split_tags);
    let theme_id = opts.theme.clone().unwrap_or_else(|| settings.theme());
    let rest: Vec<String> = opts.args.iter().skip(1).cloned().collect();
    let joined = rest.join(" ");

    // Anything jnl or Nook left behind is folded in before any screen reads.
    let migrated = match j.migrate_legacy_inbox() {
        Ok(m) => m,
        Err(e) => {
            eprintln!("  note: {}", e);
            None
        }
    };
    let split_migrated = match j.migrate_legacy_splits() {
        Ok(m) => m,
        Err(e) => {
            eprintln!("  note: {}", e);
            None
        }
    };

    // Another journal than the settings' own keeps its backups, and the time
    // of its last one, to itself.
    let keyed = !same_folder(&folder, &home_folder(&settings));
    // The app, with what happened before it had a window to say it in.
    let make_app = || {
        let mut a = app::App::new(j.clone(), settings.clone(), split_tags.clone(), &theme_id);
        a.keyed_backups = keyed;
        if let Some(w) = &warning {
            a.notice(w.clone(), true);
        }
        a.report_restore_leftovers();
        if let Some(m) = &migrated {
            a.notice(format!("inbox.md folded into inbox/: {} moved, {} already there; original in {}", m.moved, m.skipped, m.backup), false);
        }
        if let Some(m) = &split_migrated {
            a.notice(format!("{} split journal(s) folded into split/: {} moved, {} already there; originals in .quire/migration/", m.journals, m.moved, m.skipped), false);
        }
        a
    };
    let open = |screen: app::Screen, draft_title: Option<String>| {
        if !tty {
            eprintln!("  {} {} needs a terminal", name, cmd);
            std::process::exit(1);
        }
        let mut a = make_app();
        if let Some(t) = draft_title {
            a.start_titled_draft(&t);
        } else {
            a.screen = screen;
        }
        if let Err(e) = app::run(a) {
            eprintln!("  error: {}", e);
            std::process::exit(1);
        }
    };

    match cmd {
        "" => open(app::Screen::Today, None),
        "new" => {
            if tty {
                open(app::Screen::Write, Some(joined));
            } else {
                eprintln!("  {} new needs a terminal; pipe text into `{} import` instead", name, name);
                std::process::exit(1);
            }
        }
        "review" => open(app::Screen::Inbox, None),
        "browse" => open(app::Screen::Browse, None),
        "inbox" => cli::inbox(&j),
        "sort" => done(cli::sort_text(&j)),
        "log" => {
            let d = if joined.is_empty() { stats::today() } else { joined.clone() };
            cli::log(&j, &d)
        }
        "yesterday" => {
            let y = (chrono::Local::now() - chrono::Duration::days(1)).format("%Y-%m-%d").to_string();
            cli::log(&j, &y)
        }
        "list" | "ls" => cli::list(&j),
        "stats" => {
            if tty {
                open(app::Screen::LookBack, None);
            } else {
                cli::stats_text(&j);
            }
        }
        "search" => {
            if tty && joined.is_empty() {
                open(app::Screen::Search, None);
            } else {
                cli::search(&j, &joined);
            }
        }
        "tags" => cli::tags(&j),
        "tag" => cli::tag(&j, rest.first().map(|s| s.as_str()).unwrap_or("")),
        "random" => {
            if tty {
                let mut a = make_app();
                a.random();
                done(app::run(a).map_err(|e| e.to_string()));
            } else {
                cli::random_text(&j);
            }
        }
        "transfer" => done(cli::transfer_text(&j, &split_tags)),
        "cleanup" => done(cli::cleanup_text(&j, &split_tags)),
        "export" => done(cli::export_text(&j, &joined)),
        "open" => cli::open_folder(&j),
        "config" => done(cli::config()),
        "migrate" => {
            if let Some(m) = &migrated {
                println!("  Moved {} draft(s) into inbox/ ({} already there). inbox.md kept as {}.", m.moved, m.skipped, m.backup);
            }
            if let Some(m) = &split_migrated {
                println!("  Moved {} entr{} from {} split journal(s) into split/ ({} already there). Originals kept as {}.", m.moved, if m.moved == 1 { "y" } else { "ies" }, m.journals, m.skipped, m.backups.join(", "));
            }
            if migrated.is_none() && split_migrated.is_none() {
                println!("  Nothing to migrate: no inbox.md or <tag>.md split journals in {}.", folder.display());
            }
        }
        "import" => {
            use std::io::Read;
            let stdin = std::io::stdin();
            if stdin.is_terminal() {
                // Nothing piped in: it would otherwise sit there, silent.
                eprintln!("  Type or paste the text, then press Ctrl-D. (Or pipe it in: pbpaste | {} import)", name);
            }
            let mut text = String::new();
            done(stdin.lock().read_to_string(&mut text).map(|_| ()).map_err(|e| format!("couldn't read the text to import: {}", e)));
            done(j.import_text(&text, &now_local()).map(|n| println!("  {} draft(s) added to the inbox.", n)));
        }
        other if is_date(other) => cli::log(&j, other),
        // jnl: anything else is a title for a new draft. (In a pipe it was
        // answered with the help, above.)
        _ => open(app::Screen::Write, Some(opts.args.join(" "))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts(line: &str) -> Result<Opts, String> {
        parse_opts(line.split_whitespace().map(String::from).collect())
    }

    /// Review of 14 November, T16.
    #[test]
    fn options_are_options_and_titles_are_titles() {
        let o = opts("--folder /tmp/j --theme cinema browse").unwrap();
        assert_eq!((o.folder.as_deref(), o.theme.as_deref(), o.args), (Some("/tmp/j"), Some("cinema"), vec!["browse".to_string()]));
        let o = opts("--folder=/tmp/j --theme=cinema").unwrap();
        assert_eq!((o.folder.as_deref(), o.theme.as_deref(), o.args.len()), (Some("/tmp/j"), Some("cinema"), 0));
        // After a command with no words of its own, as install.sh and habit have it.
        let o = opts("migrate --folder /tmp/j").unwrap();
        assert_eq!((o.folder.as_deref(), o.args), (Some("/tmp/j"), vec!["migrate".to_string()]));
        assert_eq!(opts("-C /tmp/j help").unwrap().folder.as_deref(), Some("/tmp/j"));
        // A title is the writer's words, whatever they look like.
        let o = opts("new My --theme song").unwrap();
        assert_eq!((o.theme, o.args.join(" ")), (None, "new My --theme song".to_string()));
        let o = opts("Call --folder dentist").unwrap();
        assert_eq!((o.folder, o.args.join(" ")), (None, "Call --folder dentist".to_string()));
        let o = opts("search tag:x --theme").unwrap();
        assert_eq!(o.args.join(" "), "search tag:x --theme");
        let o = opts("--theme cinema -- --folder is my title").unwrap();
        assert_eq!((o.folder, o.theme.as_deref(), o.args.join(" ")), (None, Some("cinema"), "--folder is my title".to_string()));
        // `update` takes its own arguments, untouched.
        assert_eq!(opts("update --check --theme x").unwrap().args.join(" "), "update --check --theme x");
        // An option with nothing after it, or one Quire doesn't have, is said, not written down as a draft.
        for bad in ["--folder", "--folder=", "--theme", "browse --folder", "--fodler /tmp/j", "--dry-run new x"] {
            assert!(opts(bad).is_err(), "{bad}");
        }
        assert!(opts("--folder").unwrap_err().contains("needs a folder"));
        assert_eq!(opts("--version").unwrap().args, ["--version"]);
        assert_eq!(opts("--help").unwrap().args, ["--help"]);
    }

    #[test]
    fn commands_and_dates_are_told_from_titles() {
        for c in ["new", "browse", "2026-03-04", "import", "update", "-V", "--help"] {
            assert!(is_command(c), "{c}");
        }
        for t in ["", "Call", "2026-3-4", "2026-03-041", "20260304ab", "newish"] {
            assert!(!is_command(t), "{t}");
        }
    }

    /// T3: a settings folder that is gone is never swapped for another.
    #[test]
    fn a_settings_folder_that_is_gone_is_noticed() {
        let d = tempfile::tempdir().unwrap();
        let there = Settings { folder: Some(d.path().display().to_string()), ..Settings::default() };
        assert_eq!(missing_settings_folder(&there), None);
        let gone = d.path().join("unmounted");
        let s = Settings { folder: Some(gone.display().to_string()), ..Settings::default() };
        assert_eq!(missing_settings_folder(&s), Some(gone.to_str().unwrap()));
        assert_eq!(missing_settings_folder(&Settings::default()), None, "no folder chosen yet is not a missing one");
    }
}
