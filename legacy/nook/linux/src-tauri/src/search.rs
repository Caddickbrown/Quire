//! The global search's query grammar — a faithful port of the Swift
//! `Models/SearchQuery.swift` (which is itself covered by `make check` and
//! NookTests on the Apple side). Keep the two in step.
//!
//! Grammar:
//!     plain terms          case-insensitive substring match on title + body
//!                          (not the timestamp header — see `matches`)
//!     "exact phrase"       quoted phrases match as one substring
//!     tag:name             entry carries @name (leading @ optional)
//!     before:2026-03       entry date strictly before the (partial) ISO date
//!     after:2026-03        entry date on/after the (partial) ISO date
//!     has:image            entry links media of that kind (image|video|audio|media)
//!     is:starred           entry is starred
//!
//! Every clause must match (AND). An empty query matches nothing.

use crate::parser::{self, Entry};

#[derive(Debug, Default, PartialEq)]
pub struct Query {
    pub terms: Vec<String>,   // lowercased plain words + quoted phrases
    pub tags: Vec<String>,    // "@name", lowercased
    pub before: Option<String>,
    pub after: Option<String>,
    pub has: Vec<String>,     // "image" | "video" | "audio" | "media"
    pub starred: bool,
}

impl Query {
    pub fn is_empty(&self) -> bool {
        self.terms.is_empty()
            && self.tags.is_empty()
            && self.before.is_none()
            && self.after.is_none()
            && self.has.is_empty()
            && !self.starred
    }

    pub fn parse(raw: &str) -> Query {
        let mut q = Query::default();
        for token in tokenize(raw) {
            let lower = token.to_lowercase();
            if let Some(name) = lower.strip_prefix("tag:") {
                if !name.is_empty() {
                    q.tags.push(if name.starts_with('@') {
                        name.to_string()
                    } else {
                        format!("@{}", name)
                    });
                }
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

    pub fn matches(&self, entry: &Entry) -> bool {
        if self.is_empty() {
            return false;
        }
        // Plain terms search what the writer wrote — the title and the body —
        // and deliberately not `raw`, whose timestamp header made searching
        // "2025" return every entry written that year. Dates have their own
        // before:/after: operators. Tags still come from `raw`, since a @tag in
        // the title counts.
        if !self.terms.is_empty() {
            let text = format!("{}\n{}", entry.suffix, entry.body).to_lowercase();
            if self.terms.iter().any(|t| !text.contains(t.as_str())) {
                return false;
            }
        }
        if !self.tags.is_empty() {
            let present: Vec<String> = entry.tags.iter().map(|t| t.to_lowercase()).collect();
            if self.tags.iter().any(|t| !present.contains(t)) {
                return false;
            }
        }
        if let Some(before) = &self.before {
            if !(entry.date.as_str() < before.as_str()) {
                return false;
            }
        }
        if let Some(after) = &self.after {
            if !(entry.date.as_str() > after.as_str() || entry.date.starts_with(after.as_str())) {
                return false;
            }
        }
        if self.starred && !entry.is_starred {
            return false;
        }
        if !self.has.is_empty() {
            let paths = parser::media_paths(&entry.raw);
            // Shared with the badges/dots (parser::media_kind); an unrecognised
            // extension reads as an image, matching the Swift `MediaKind`.
            let kind_of = |p: &str| -> &'static str {
                match parser::media_kind(p) {
                    parser::MediaKind::Video => "video",
                    parser::MediaKind::Audio => "audio",
                    _ => "image",
                }
            };
            for want in &self.has {
                let ok = match want.as_str() {
                    "media" => !paths.is_empty(),
                    kind => paths.iter().any(|p| kind_of(p) == kind),
                };
                if !ok {
                    return false;
                }
            }
        }
        true
    }
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
        } else if (ch == ' ' || ch == '\n' || ch == '\t') && !in_quotes {
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
    parts
        .iter()
        .enumerate()
        .all(|(i, p)| p.len() == widths[i] && p.chars().all(|c| c.is_ascii_digit()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(date: &str, suffix: &str, body: &str) -> Entry {
        let ts = format!("{} 08:00:00", date);
        let raw = if suffix.is_empty() {
            format!("[{}]\n{}", ts, body)
        } else {
            format!("[{}] {}\n{}", ts, suffix, body)
        };
        parser::parse_entries(&raw).into_iter().next().unwrap()
    }

    #[test]
    fn grammar_matches_swift_port() {
        assert_eq!(
            tokenize(r#"plain "two words" tag:work"#),
            vec!["plain", "two words", "tag:work"]
        );
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

        // Operator prefixes are case-insensitive, like the Swift port's
        // `lower.hasPrefix` checks.
        assert_eq!(Query::parse("Before:2026-03").before.as_deref(), Some("2026-03"));
        assert_eq!(Query::parse("AFTER:2025").after.as_deref(), Some("2025"));
        assert_eq!(Query::parse("TAG:Work").tags, vec!["@work"]);
        assert!(Query::parse("Is:Starred").starred);
        assert_eq!(Query::parse("HAS:Image").has, vec!["image"]);

        // A plain term searches title + body, never the timestamp header —
        // searching "2025" must not return every entry written that year.
        let dated = entry("2025-06-01", "Morning", "nothing numeric here");
        assert!(!Query::parse("2025").matches(&dated));
        assert!(Query::parse("morning").matches(&dated));
        assert!(Query::parse("numeric").matches(&dated));
        assert!(Query::parse("2025").matches(&entry("2025-06-01", "", "bought it in 2025")));

        // The Linux recorder's own formats classify like their Apple cousins.
        let recorded = entry("2026-01-02", "", "![](assets/a.weba) ![](assets/b.webm)");
        assert!(Query::parse("has:audio").matches(&recorded));
        assert!(Query::parse("has:video").matches(&recorded));
        assert!(!Query::parse("has:image").matches(&recorded));
    }
}
