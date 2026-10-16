//! Editor macros every shell shares: ↩ in a list (Nook's ListContinuation,
//! the Linux app's `listContinuation`) and toggling `**` / `_` / `` ` ``
//! around a word. Pure string rules.

use once_cell::sync::Lazy;
use regex::Regex;

/// What pressing return at the end of `line` should do.
#[derive(Debug, PartialEq, Eq)]
pub enum ListStep {
    /// Start the next line with this prefix (`- `, `3. `, `- [ ] `).
    Continue(String),
    /// The item was empty: remove the first `n` characters of the line
    /// (the marker) and end the list.
    End(usize),
}

static CHECK: Lazy<Regex> = Lazy::new(|| Regex::new(r"^(\s*)([-*+] \[[ xX]\] )(.*)$").unwrap());
static ORDERED: Lazy<Regex> = Lazy::new(|| Regex::new(r"^(\s*)(\d+)([.)] )(.*)$").unwrap());
static BULLET: Lazy<Regex> = Lazy::new(|| Regex::new(r"^(\s*)([-*+] )(.*)$").unwrap());

pub fn list_continuation(line: &str) -> Option<ListStep> {
    // A line may still carry its ending ("- milk\r\n"); `.` never matches
    // `\n`, so drop it first. A lone trailing `\r` is whitespace to trim().
    let line = line.strip_suffix('\n').unwrap_or(line);
    if let Some(m) = CHECK.captures(line) {
        return Some(if m[3].trim().is_empty() {
            ListStep::End(m[1].chars().count() + m[2].chars().count())
        } else {
            ListStep::Continue(format!("{}{}[ ] ", &m[1], &m[2][..2]))
        });
    }
    if let Some(m) = ORDERED.captures(line) {
        return Some(if m[4].trim().is_empty() {
            ListStep::End(m[1].chars().count() + m[2].chars().count() + m[3].chars().count())
        } else {
            let n: u64 = m[2].parse().unwrap_or(0);
            ListStep::Continue(format!("{}{}{}", &m[1], n.saturating_add(1), &m[3]))
        });
    }
    if let Some(m) = BULLET.captures(line) {
        return Some(if m[3].trim().is_empty() {
            ListStep::End(m[1].chars().count() + m[2].chars().count())
        } else {
            ListStep::Continue(format!("{}{}", &m[1], &m[2]))
        });
    }
    None
}

/// Wrap `text` in `open`…`close`, or unwrap it if it already is.
pub fn toggle_wrap(text: &str, open: &str, close: &str) -> String {
    if text.starts_with(open) && text.ends_with(close) && text.len() >= open.len() + close.len() {
        text[open.len()..text.len() - close.len()].to_string()
    } else {
        format!("{}{}{}", open, text, close)
    }
}

/// The run of non-whitespace characters around char index `col` in `line`,
/// as a char range. None when the cursor is on whitespace.
pub fn word_at(line: &str, col: usize) -> Option<(usize, usize)> {
    let chars: Vec<char> = line.chars().collect();
    if chars.is_empty() {
        return None;
    }
    let mut i = col.min(chars.len());
    if i == chars.len() || chars[i].is_whitespace() {
        if i == 0 || chars[i - 1].is_whitespace() {
            return None;
        }
        i -= 1;
    }
    let mut a = i;
    while a > 0 && !chars[a - 1].is_whitespace() {
        a -= 1;
    }
    let mut b = i;
    while b < chars.len() && !chars[b].is_whitespace() {
        b += 1;
    }
    Some((a, b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_lines_with_their_endings() {
        assert_eq!(list_continuation("- milk\r\n"), Some(ListStep::Continue("- ".into())));
        assert_eq!(list_continuation("- milk\n"), Some(ListStep::Continue("- ".into())));
        assert_eq!(list_continuation("- \r\n"), Some(ListStep::End(2)));
        assert_eq!(list_continuation("- [ ] \r\n"), Some(ListStep::End(6)));
        assert_eq!(list_continuation("2. x\r\n"), Some(ListStep::Continue("3. ".into())));
        assert_eq!(list_continuation("prose\r\n"), None);
    }

    #[test]
    fn lists() {
        assert_eq!(list_continuation("- a"), Some(ListStep::Continue("- ".into())));
        assert_eq!(list_continuation("  * a"), Some(ListStep::Continue("  * ".into())));
        assert_eq!(list_continuation("- "), Some(ListStep::End(2)));
        assert_eq!(list_continuation("3. x"), Some(ListStep::Continue("4. ".into())));
        assert_eq!(list_continuation("3) "), Some(ListStep::End(3)));
        assert_eq!(list_continuation("- [x] done"), Some(ListStep::Continue("- [ ] ".into())));
        assert_eq!(list_continuation("- [ ] "), Some(ListStep::End(6)));
        assert_eq!(list_continuation("18446744073709551615. x"), Some(ListStep::Continue("18446744073709551615. ".into())));
        assert_eq!(list_continuation("plain"), None);
        assert_eq!(list_continuation("-no space"), None);
    }

    #[test]
    fn wrap_and_words() {
        assert_eq!(toggle_wrap("x", "**", "**"), "**x**");
        assert_eq!(toggle_wrap("**x**", "**", "**"), "x");
        assert_eq!(toggle_wrap("", "_", "_"), "__");
        assert_eq!(word_at("ab cd", 0), Some((0, 2)));
        assert_eq!(word_at("ab cd", 2), Some((0, 2)), "end of a word still selects it");
        assert_eq!(word_at("ab cd", 3), Some((3, 5)));
        assert_eq!(word_at("ab  cd", 3), None);
        assert_eq!(word_at("", 0), None);
    }
}
