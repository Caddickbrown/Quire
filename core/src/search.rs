//! The global search's query grammar — the same one as Nook's
//! `Models/SearchQuery.swift` and the Linux app's `parseQuery`. Keep the
//! three in step.
//!
//! Grammar:
//!     plain terms          case-insensitive substring match on title + body
//!                          (not the timestamp header)
//!     "exact phrase"       quoted phrases match as one substring
//!     tag:name  or  @name  entry carries @name
//!     before:2026-03       entry date strictly before the (partial) ISO date
//!     after:2026-03        entry date on/after the (partial) ISO date
//!     has:image            entry links media of that kind (image|video|audio|media)
//!     is:starred           entry is starred
//!
//! Every clause must match (AND). An empty query matches nothing.

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
        for token in tokenize(raw) {
            let lower = token.to_lowercase();
            if let Some(name) = lower.strip_prefix("tag:") {
                if !name.is_empty() {
                    q.tags.push(if name.starts_with('@') { name.to_string() } else { format!("@{}", name) });
                }
            } else if lower.starts_with('@') && lower.len() > 1 && !token.contains(' ') {
                q.tags.push(lower);
            } else if let Some(d) = lower.strip_prefix("before:") {
                if is_partial_date(d) {
                    q.before = Some(d.to_string());
                }
            } else if let Some(d) = lower.strip_prefix("after:") {
                if is_partial_date(d) {
                    q.after = Some(d.to_string());
                }
            } else if let Some(kind) = lower.strip_prefix("has:") {
                if ["image", "video", "audio", "media"].contains(&kind) {
                    q.has.push(kind.to_string());
                }
            } else if lower == "is:starred" {
                q.starred = true;
            } else if !lower.is_empty() {
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

/// Whitespace-split, except quoted runs ("two words") come out whole.
pub fn tokenize(s: &str) -> Vec<String> {
    let mut tokens = vec![];
    let mut current = String::new();
    let mut in_quotes = false;
    for ch in s.chars() {
        if ch == '"' {
            if !current.is_empty() {
                tokens.push(std::mem::take(&mut current));
            }
            in_quotes = !in_quotes;
        } else if ch.is_whitespace() && !in_quotes {
            if !current.is_empty() {
                tokens.push(std::mem::take(&mut current));
            }
        } else {
            current.push(ch);
        }
    }
    if !current.is_empty() {
        tokens.push(current);
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

        let recorded = entry("2026-01-02", "", "![](assets/a.m4a) ![](assets/b.webm) [f](assets/c.pdf)");
        assert!(Query::parse("has:audio").matches(&recorded));
        assert!(Query::parse("has:video").matches(&recorded));
        assert!(!Query::parse("has:image").matches(&recorded));
        assert!(Query::parse("has:media").matches(&recorded));
    }
}
