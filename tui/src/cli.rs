//! jnl's commands, printed the way jnl prints them, so scripts and muscle
//! memory carry over. Anything interactive lives in `app`.

use quire_core::stats::{self, jnl_stats};
use quire_core::*;
use std::path::Path;

pub fn inbox(j: &Journal) {
    let drafts: Vec<Entry> = j.load_all().into_iter().filter(|e| e.source == "inbox").collect();
    if drafts.is_empty() {
        println!("  Inbox is empty.");
        return;
    }
    println!();
    println!("  Inbox — {} draft{}", drafts.len(), if drafts.len() == 1 { "" } else { "s" });
    println!("  ──────────────────────────────");
    for e in &drafts {
        for line in e.raw.trim_end().split('\n') {
            println!("  {}", line);
        }
        println!();
    }
}

pub fn log(j: &Journal, date: &str) {
    let rel = journal_rel(date);
    let content = j.read(&rel);
    if content.trim().is_empty() {
        println!("  No entries for {}.", date);
        return;
    }
    let es = parse_entries(&content);
    let wc: usize = es.iter().map(|e| e.body.split_whitespace().count()).sum();
    println!();
    println!("  {} — {} {}, {} words", date, es.len(), if es.len() == 1 { "entry" } else { "entries" }, wc);
    println!("  ──────────────────────────────");
    for line in content.trim_end_matches('\n').split('\n') {
        println!("  {}", line);
    }
    println!();
}

pub fn list(j: &Journal) {
    let mut files = j.walk_md(JOURNAL_DIR);
    files.sort();
    files.reverse();
    println!();
    if files.is_empty() {
        println!("  No journal entries yet.");
        println!();
        return;
    }
    let mut total = 0;
    for f in &files {
        let es = parse_entries(&j.read(f));
        let wc: usize = es.iter().map(|e| e.body.split_whitespace().count()).sum();
        total += wc;
        let date = f.trim_start_matches("journal/").trim_end_matches(".md").replace('/', "-");
        println!("  {:<14}  {:>2} entries  {:>4} words", date, es.len(), wc);
    }
    println!("  ───────────────────────────────────");
    println!("  {} days  ·  {} words total", files.len(), total);
    println!();
}

pub fn stats_text(j: &Journal) {
    let es = j.load_all();
    let s = jnl_stats(&es, &stats::today());
    println!();
    println!("  Writing stats");
    println!("  ─────────────────────────────────────────────────");
    println!("  Days written:     {}", s.days);
    println!("  Total entries:    {}", s.entries);
    println!("  Total words:      {}", s.words);
    if let Some(avg) = s.words.checked_div(s.entries) {
        println!("  Avg per entry:    {} words", avg);
    }
    if let Some((d, w)) = &s.longest_day {
        println!("  Longest day:      {}  ({} words)", d, w);
    }
    if let Some((d, n)) = &s.busiest_day {
        println!("  Busiest day:      {}  ({} entries)", d, n);
    }
    println!("  Inbox drafts:     {} waiting", s.drafts);
    println!();
    print!("  Current streak:   {} day(s)", s.current_streak);
    if s.current_streak > 1 {
        print!("  ({} → {})", s.current_start.clone().unwrap_or_default(), stats::today());
    }
    println!();
    print!("  Best streak:      {} day(s)", s.best_streak);
    if let (true, Some((a, b))) = (s.best_streak > 1, &s.best_span) {
        print!("  ({} → {})", a, b);
    }
    println!();
    println!();
    if !s.per_year.is_empty() {
        println!("  {:<6}  {:>8}  {:>8}", "Year", "Entries", "Words");
        println!("  ──────────────────────────────");
        for (y, e, w) in &s.per_year {
            println!("  {:<6}  {:>8}  {:>8}", y, e, w);
        }
        println!();
    }
    if s.dow.iter().any(|n| *n > 0) {
        println!("  Day of week (days written):");
        for (i, n) in ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].iter().zip(s.dow.iter()) {
            println!("    {:<4}  {}", i, n);
        }
        println!();
    }
}

pub fn search(j: &Journal, query: &str) {
    if query.trim().is_empty() {
        println!("  Usage: search <term>");
        return;
    }
    println!();
    println!("  Searching: {:?}", query);
    println!();
    let q = search::Query::parse(query);
    let mut found = 0;
    let mut cur = String::new();
    let mut es = j.load_all();
    es.sort_by(|a, b| b.ts.cmp(&a.ts));
    for e in es.iter().filter(|e| q.matches(e)) {
        let head = if e.source == "inbox" { "inbox (unfiled)".to_string() } else { e.date.clone() };
        if head != cur {
            if !cur.is_empty() {
                println!();
            }
            println!("  {}:", head);
            cur = head;
        }
        let title = if e.title.is_empty() { first_line(&e.body) } else { e.title.clone() };
        println!("    {}  {}", e.time, title);
        found += 1;
    }
    if found == 0 {
        println!("  Nothing found.");
    }
    println!();
}

pub fn tags(j: &Journal) {
    let es = j.load_all();
    println!();
    println!("  Tags used:");
    for (t, n) in stats::count_tags(es.iter()) {
        println!("  {:<24}  {}", t, n);
    }
    println!();
}

pub fn tag(j: &Journal, name: &str) {
    if name.is_empty() {
        println!("  Usage: tag <tagname>");
        return;
    }
    let name = if name.starts_with('@') { name.to_string() } else { format!("@{}", name) };
    println!();
    println!("  Entries tagged {}:", name);
    println!();
    let mut es: Vec<Entry> = j.load_all().into_iter().filter(|e| e.source != "inbox" && e.tags.iter().any(|t| t.eq_ignore_ascii_case(&name))).collect();
    es.sort_by(|a, b| b.ts.cmp(&a.ts));
    let mut cur = String::new();
    for e in es {
        if e.date != cur {
            println!("  ── {} ──", e.date);
            cur = e.date.clone();
        }
        for line in e.raw.trim_end().split('\n') {
            println!("  {}", line);
        }
        println!();
    }
}

pub fn random_text(j: &Journal) -> Option<Entry> {
    use rand::Rng;
    let es: Vec<Entry> = j.load_all().into_iter().filter(|e| e.source != "inbox").collect();
    if es.is_empty() {
        println!("  No journal entries yet.");
        return None;
    }
    let e = es[rand::rng().random_range(0..es.len())].clone();
    println!();
    for line in e.raw.trim_end().split('\n') {
        println!("  {}", line);
    }
    println!();
    Some(e)
}

pub fn cleanup_text(j: &Journal, split_tags: &[String]) {
    match cleanup(j, split_tags) {
        Ok(r) => {
            println!("  Cleanup: {} file(s) checked, {} moved to their day, {} formatted, {} reordered, {} duplicate(s) removed, {} extracted to split journals.", r.files, r.moved, r.formatted, r.reordered, r.deduped, r.extracted);
            for e in r.errors {
                println!("  ! {}", e);
            }
            let (removed, errors) = remove_ds_store(j);
            println!("  Removed {removed} .DS_Store file(s).");
            for e in errors {
                println!("  ! {}", e);
            }
        }
        Err(e) => eprintln!("  error: {}", e),
    }
}

pub fn export_text(j: &Journal, out: &str) {
    let dest = if out.is_empty() { j.root().join("export.md") } else { Path::new(out).to_path_buf() };
    match export_all(j, &dest) {
        Ok(n) => println!("  Exported {} entries to {}", n, dest.display()),
        Err(e) => eprintln!("  error: {}", e),
    }
}

pub fn sort_text(j: &Journal) {
    match sort_inbox(j) {
        Ok(true) => println!("  Inbox sorted."),
        Ok(false) => println!("  Inbox already in order."),
        Err(e) => eprintln!("  error: {}", e),
    }
}

pub fn transfer_text(j: &Journal, split_tags: &[String]) {
    match import_transfer(j, &now_local(), split_tags) {
        Ok(0) => println!("  transfer.md is empty."),
        Ok(n) => println!("  Filed {} entr{} from transfer.md.", n, if n == 1 { "y" } else { "ies" }),
        Err(e) => eprintln!("  error: {}", e),
    }
}

pub fn open_folder(j: &Journal) {
    println!("  Opening {}", j.root().display());
    let cmd = if cfg!(target_os = "macos") { "open" } else if cfg!(target_os = "windows") { "explorer" } else { "xdg-open" };
    let _ = std::process::Command::new(cmd).arg(j.root()).spawn();
}

/// jnl's `config`: open ~/.config/jnl/config in $EDITOR, writing the default
/// file first when there is none.
pub fn config() -> Result<(), String> {
    let path = jnl_config_path().ok_or("No config folder")?;
    if !path.exists() {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let home = dirs::home_dir().map(|h| h.join("notes").display().to_string()).unwrap_or_else(|| "~/notes".into());
        let content = format!(
            "# jnl configuration — written by 'quire config' on {}\n# Env vars set before jnl or quire runs always override these values.\n: \"${{JNL_DIR:={}}}\"\n: \"${{EDITOR:=micro}}\"\n: \"${{JNL_SPLIT_TAGS:=}}\"\n",
            chrono::Local::now().format("%Y-%m-%d %H:%M"),
            home
        );
        std::fs::write(&path, content).map_err(|e| e.to_string())?;
    }
    let editor = std::env::var("VISUAL").or_else(|_| std::env::var("EDITOR")).unwrap_or_else(|_| "vi".into());
    let status = std::process::Command::new(&editor).arg(&path).status().map_err(|e| format!("{}: {}", editor, e))?;
    if !status.success() {
        return Err(format!("{} exited with {}", editor, status));
    }
    Ok(())
}

pub fn help(name: &str) {
    println!(
        "
  {n}                    today: words, streak, on this day, a prompt, the inbox
  {n} new [title]        write a new draft (added to the inbox)
  {n} review             work through the inbox one draft at a time
  {n} browse             browse filed entries by year → month → day (s: split journals)
  {n} inbox              print the inbox
  {n} sort               sort the inbox files into date order (in place)
  {n} log [date]         print a day's entries (default: today)
  {n} yesterday          print yesterday's entries
  {n} list               all journal days with entry + word counts
  {n} stats              streaks and totals (a screen on a terminal, text in a pipe)
  {n} search <query>     words · \"phrase\" · tag:x · before:2026-03 · after:2025 · has:image · is:starred
  {n} tags               all @tags with usage counts
  {n} tag <name>         all entries tagged @name
  {n} random             a random past entry
  {n} transfer           file everything in transfer.md (no review)
  {n} cleanup            move misdated entries to their day, standardise punctuation, reorder, dedupe, extract split-tagged entries, remove .DS_Store files
  {n} export [file]      combine all entries into one file (default: export.md)
  {n} open               open the journal folder in the file manager
  {n} config             edit ~/.config/jnl/config
  {n} migrate            fold a legacy inbox.md into inbox/ and .nook/ into .quire/
  {n} update [--check]   install the latest release: the terminal app and the desktop
                         AppImage (--terminal / --desktop for one; --check: only say)

  Options:  --folder PATH   --theme NAME   --help

  The folder: $JNL_DIR, else ~/.config/quire/settings.json, else
  ~/.config/jnl/config, else ~/notes. Split tags: Quire's settings, else
  $JNL_SPLIT_TAGS, else jnl's config.
",
        n = name
    );
}

pub fn first_line(s: &str) -> String {
    s.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim().to_string()
}
