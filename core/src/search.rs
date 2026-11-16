//! The global search's query grammar — the same one as Nook's
//! `Models/SearchQuery.swift` and the Linux app's `parseQuery`. Keep the
//! three in step.
//!
//! Grammar:
//!     plain terms          case-insensitive substring match on title + body
//!                          (not the timestamp header)
//!     "exact phrase"       quoted phrases match as one substring; curly
//!                          quotes and guillemets (“ ” „ « ») quote too, as
//!                          a phone keyboard types those. Anything quoted is
//!                          text, never an operator: "is:starred" finds the
//!                          words
//!     tag:name  or  @name  entry carries @name
//!     before:2026-03       entry date strictly before the (partial) ISO date
//!     after:2026-03        entry date on/after the (partial) ISO date
//!     has:image            entry links media of that kind (image|video|audio|media)
//!     is:starred           entry is starred
//!
//! Every clause must match (AND). An empty query matches nothing. An
//! operator whose value can't be used (`before:March`, `has:pdf`, `tag:`) is
//! searched for as text, so a mistyped filter narrows the search to nothing
//! instead of silently widening it.

use crate::extras::media_kind;
use crate::journal::{link_targets, resolve_link, Entry};

#[derive(Debug, Default, PartialEq, Clone)]
pub struct Query {
    pub terms: Vec<String>,
    pub tags: Vec<String>,
    pub before: Option<String>,
    pub after: Option<String>,
    pub has: Vec<String>,
    pub starred: bool,
}

impl Query {
    pub fn is_empty(&self) -> bool {
        self.terms.is_empty() && self.tags.is_empty() && self.before.is_none() && self.after.is_none() && self.has.is_empty() && !self.starred
    }

    pub fn parse(raw: &str) -> Query {
        let mut q = Query::default();
        for (token, quoted) in tokens(raw) {
            let lower = token.to_lowercase();
            if quoted {
                q.terms.push(lower);
                continue;
            }
            let value = |prefix: &str| lower.strip_prefix(prefix).map(str::to_string);
            if let Some(name) = value("tag:").filter(|n| !n.trim_start_matches('@').is_empty()) {
                q.tags.push(if name.starts_with('@') { name } else { format!("@{}", name) });
            } else if lower.starts_with('@') && lower.len() > 1 {
                q.tags.push(lower);
            } else if let Some(d) = value("before:").filter(|d| is_partial_date(d)) {
                q.before = Some(d);
            } else if let Some(d) = value("after:").filter(|d| is_partial_date(d)) {
                q.after = Some(d);
            } else if let Some(kind) = value("has:").filter(|k| ["image", "video", "audio", "media"].contains(&k.as_str())) {
                q.has.push(kind);
            } else if lower == "is:starred" {
                q.starred = true;
            } else {
                q.terms.push(lower);
            }
        }
        q
    }

    pub fn matches(&self, e: &Entry) -> bool {
        if self.is_empty() {
            return false;
        }
        if !self.terms.is_empty() {
            let text = format!("{}\n{}", e.title, e.body).to_lowercase();
            if self.terms.iter().any(|t| !text.contains(t.as_str())) {
                return false;
            }
        }
        if !self.tags.is_empty() {
            let present: Vec<String> = e.tags.iter().map(|t| t.to_lowercase()).collect();
            if self.tags.iter().any(|t| !present.contains(t)) {
                return false;
            }
        }
        if let Some(before) = &self.before {
            if e.date.as_str() >= before.as_str() {
                return false;
            }
        }
        if let Some(after) = &self.after {
            if !(e.date.as_str() > after.as_str() || e.date.starts_with(after.as_str())) {
                return false;
            }
        }
        if self.starred && !e.starred {
            return false;
        }
        if !self.has.is_empty() {
            let paths = media_paths(e);
            for want in &self.has {
                let ok = match want.as_str() {
                    "media" => !paths.is_empty(),
                    kind => paths.iter().any(|p| media_kind(p) == kind),
                };
                if !ok {
                    return false;
                }
            }
        }
        true
    }
}

/// The asset paths an entry links (root-relative, under `assets/`).
pub fn media_paths(e: &Entry) -> Vec<String> {
    link_targets(&e.raw).into_iter().filter_map(|p| resolve_link(&e.file, &p)).filter(|p| p.starts_with("assets/")).collect()
}

/// The characters that open or close a phrase: the straight quote, and the
/// curly and angle ones a phone keyboard's smart punctuation types for it.
pub const QUOTES: [char; 6] = ['"', '\u{201C}', '\u{201D}', '\u{201E}', '\u{00AB}', '\u{00BB}'];

/// Whitespace-split, except quoted runs ("two words") come out whole.
pub fn tokenize(s: &str) -> Vec<String> {
    tokens(s).into_iter().map(|(t, _)| t).collect()
}

/// `tokenize`, with whether each token was quoted.
fn tokens(s: &str) -> Vec<(String, bool)> {
    let mut tokens = vec![];
    let mut current = String::new();
    let mut in_quotes = false;
    for ch in s.chars() {
        if QUOTES.contains(&ch) {
            if !current.is_empty() {
                tokens.push((std::mem::take(&mut current), in_quotes));
            }
            in_quotes = !in_quotes;
        } else if ch.is_whitespace() && !in_quotes {
            if !current.is_empty() {
                tokens.push((std::mem::take(&mut current), false));
            }
        } else {
            current.push(ch);
        }
    }
    if !current.is_empty() {
        tokens.push((current, in_quotes));
    }
    tokens
}

/// "2026", "2026-03", or "2026-03-15".
pub fn is_partial_date(s: &str) -> bool {
    let parts: Vec<&str> = s.split('-').collect();
    if parts.is_empty() || parts.len() > 3 {
        return false;
    }
    let widths = [4, 2, 2];
    parts.iter().enumerate().all(|(i, p)| p.len() == widths[i] && p.chars().all(|c| c.is_ascii_digit()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::journal::Journal;

    fn entry(date: &str, suffix: &str, body: &str) -> Entry {
        let ts = format!("{} 08:00:00", date);
        let raw = if suffix.is_empty() { format!("[{}]\n{}", ts, body) } else { format!("[{}] {}\n{}", ts, suffix, body) };
        let d = tempfile::tempdir().unwrap();
        let j = Journal::open(d.path());
        j.write("journal/x.md", &raw).unwrap();
        j.load_file("journal/x.md").remove(0)
    }

    // The same cases as Nook's search.rs and SearchQuery.swift.
    #[test]
    fn grammar_matches_the_other_ports() {
        assert_eq!(tokenize(r#"plain "two words" tag:work"#), vec!["plain", "two words", "tag:work"]);
        let q = Query::parse("coffee tag:Work before:2026-03 after:2025 has:image is:starred");
        assert_eq!(q.terms, vec!["coffee"]);
        assert_eq!(q.tags, vec!["@work"]);
        assert_eq!(q.before.as_deref(), Some("2026-03"));
        assert_eq!(q.after.as_deref(), Some("2025"));
        assert_eq!(q.has, vec!["image"]);
        assert!(q.starred);
        assert!(Query::parse("").is_empty());
        assert!(!is_partial_date("26-03"));

        assert!(q.matches(&entry("2026-02-10", "Morning *", "coffee @work ![](assets/a.png)")));
        assert!(!q.matches(&entry("2026-02-10", "Morning *", "coffee @work")));
        assert!(!q.matches(&entry("2026-03-01", "Morning *", "coffee @work ![](assets/a.png)")));
        assert!(!q.matches(&entry("2024-12-31", "Morning *", "coffee @work ![](assets/a.png)")));

        let phrase = Query::parse(r#""exact phrase""#);
        assert!(phrase.matches(&entry("2026-01-01", "", "an exact phrase here")));
        assert!(!phrase.matches(&entry("2026-01-01", "", "exact other phrase")));
        assert!(Query::parse("after:2026-03").matches(&entry("2026-03-01", "", "x")));

        assert_eq!(Query::parse("Before:2026-03").before.as_deref(), Some("2026-03"));
        assert_eq!(Query::parse("TAG:Work").tags, vec!["@work"]);
        assert_eq!(Query::parse("@Work").tags, vec!["@work"], "bare @tag is a tag clause (Quire)");
        assert!(Query::parse("Is:Starred").starred);

        let dated = entry("2025-06-01", "Morning", "nothing numeric here");
        assert!(!Query::parse("2025").matches(&dated), "a plain term never searches the header");
        assert!(Query::parse("morning").matches(&dated));
        assert!(Query::parse("2025").matches(&entry("2025-06-01", "", "bought it in 2025")));

        // Smart punctuation: a phone types “ ” for ", and they quote the same.
        assert_eq!(tokenize("\u{201C}exact phrase\u{201D} \u{00AB}deux mots\u{00BB} \u{201E}zwei\u{201C}"), vec!["exact phrase", "deux mots", "zwei"]);
        let curly = Query::parse("\u{201C}exact phrase\u{201D}");
        assert_eq!(curly, phrase);
        assert!(curly.matches(&entry("2026-01-01", "", "an exact phrase here")));
        assert!(!curly.matches(&entry("2026-01-01", "", "exact other phrase")));

        // Anything quoted is text, never an operator.
        let starred_words = Query::parse(r#""is:starred""#);
        assert!(!starred_words.starred);
        assert_eq!(starred_words.terms, vec!["is:starred"]);
        assert!(starred_words.matches(&entry("2026-01-01", "", "type is:starred to filter")));
        let q = Query::parse(r#""tag:work stuff" "@home" "before:2026""#);
        assert!(q.tags.is_empty() && q.before.is_none());
        assert_eq!(q.terms, vec!["tag:work stuff", "@home", "before:2026"]);

        // An operator with a value that can't be used is searched as text, so
        // the search never comes back wider than what was asked.
        let q = Query::parse("coffee before:March has:pdf tag:");
        assert!(q.before.is_none() && q.has.is_empty() && q.tags.is_empty());
        assert_eq!(q.terms, vec!["coffee", "before:march", "has:pdf", "tag:"]);
        assert!(!q.matches(&entry("2026-01-01", "", "coffee")));

        let recorded = entry("2026-01-02", "", "![](assets/a.m4a) ![](assets/b.webm) [f](assets/c.pdf)");
        assert!(Query::parse("has:audio").matches(&recorded));
        assert!(Query::parse("has:video").matches(&recorded));
        assert!(!Query::parse("has:image").matches(&recorded));
        assert!(Query::parse("has:media").matches(&recorded));
    }
}
