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

pub struct Opts {
    pub folder: Option<String>,
    pub theme: Option<String>,
    pub args: Vec<String>,
}

fn parse_opts(mut args: Vec<String>) -> Opts {
    let mut o = Opts { folder: None, theme: None, args: Vec::new() };
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--folder" | "--dir" | "-C" if i + 1 < args.len() => {
                o.folder = Some(args.remove(i + 1));
                args.remove(i);
            }
            "--theme" if i + 1 < args.len() => {
                o.theme = Some(args.remove(i + 1));
                args.remove(i);
            }
            _ => i += 1,
        }
    }
    o.args = args;
    o
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

pub fn run(name: &str) {
    let opts = parse_opts(std::env::args().skip(1).collect());
    if opts.args.iter().any(|a| a == "--version" || a == "-V") {
        println!("Quire {}", VERSION);
        return;
    }
    // Before the folder: updating the program never touches a journal.
    if opts.args.first().map(|s| s.as_str()) == Some("update") {
        std::process::exit(update::run(&opts.args[1..]));
    }
    let settings = Settings::load();
    let folder = resolve_folder(&opts, &settings);
    if !folder.is_dir() {
        if let Err(e) = std::fs::create_dir_all(&folder) {
            eprintln!("  Can't use {}: {}", folder.display(), e);
            std::process::exit(2);
        }
    }
    let j = Journal::open(&folder);
    let split_tags = split_tags_from(&settings.split_tags);
    let tty = std::io::stdout().is_terminal();
    let theme_id = opts.theme.clone().unwrap_or_else(|| settings.theme());
    let cmd = opts.args.first().map(|s| s.as_str()).unwrap_or("");
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

    let open = |screen: app::Screen, draft_title: Option<String>| {
        if !tty {
            eprintln!("  {} {} needs a terminal", name, cmd);
            std::process::exit(1);
        }
        let mut a = app::App::new(j.clone(), settings.clone(), split_tags.clone(), &theme_id);
        if let Some(m) = &migrated {
            a.toast(format!("inbox.md folded into inbox/: {} moved, {} already there; original in {}", m.moved, m.skipped, m.backup), false);
        } else if let Some(m) = &split_migrated {
            a.toast(format!("{} split journal(s) folded into split/: {} moved, {} already there; originals in .quire/migration/", m.journals, m.moved, m.skipped), false);
        }
        if let Some(t) = draft_title {
            a.start_draft(&t, "");
        } else {
            a.screen = screen;
        }
        if let Err(e) = app::run(a) {
            eprintln!("  error: {}", e);
            std::process::exit(1);
        }
    };

    match cmd {
        "" => {
            if tty {
                open(app::Screen::Today, None);
            } else {
                cli::help(name);
            }
        }
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
        "sort" => cli::sort_text(&j),
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
                let mut a = app::App::new(j.clone(), settings.clone(), split_tags.clone(), &theme_id);
                a.random();
                if let Err(e) = app::run(a) {
                    eprintln!("  error: {}", e);
                }
            } else {
                cli::random_text(&j);
            }
        }
        "transfer" => cli::transfer_text(&j, &split_tags),
        "cleanup" => cli::cleanup_text(&j, &split_tags),
        "export" => cli::export_text(&j, &joined),
        "open" => cli::open_folder(&j),
        "config" => {
            if let Err(e) = cli::config() {
                eprintln!("  error: {}", e);
                std::process::exit(1);
            }
        }
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
            let mut text = String::new();
            std::io::stdin().read_to_string(&mut text).ok();
            match j.import_text(&text, &now_local()) {
                Ok(n) => println!("  {} draft(s) added to the inbox.", n),
                Err(e) => eprintln!("  error: {}", e),
            }
        }
        "help" | "--help" | "-h" => cli::help(name),
        other => {
            if regex::Regex::new(r"^\d{4}-\d{2}-\d{2}$").unwrap().is_match(other) {
                cli::log(&j, other);
            } else if tty {
                // jnl: anything else is a title for a new draft.
                open(app::Screen::Write, Some(opts.args.join(" ")));
            } else {
                cli::help(name);
            }
        }
    }
}
