//! Markdown styled where it stands. A line comes back as one style per
//! character, so the editor can wrap it anywhere and still put the caret on
//! the right cell. The rules are the composer's: `##` fades to a hairline
//! and the heading takes weight; `>` goes italic and muted; list markers and
//! `@tags` take the accent; `**`, `_` and `` ` `` markers fade around what
//! they wrap; a checked item strikes through.

use crate::theme::Palette;
use once_cell::sync::Lazy;
use ratatui::style::{Modifier, Style};
use regex::Regex;

static HEADING: Lazy<Regex> = Lazy::new(|| Regex::new(r"^(\s*)(#{1,6}) ").unwrap());
static QUOTE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^(\s*)> ").unwrap());
static CHECK: Lazy<Regex> = Lazy::new(|| Regex::new(r"^(\s*)([-*+]) (\[[ xX]\]) ").unwrap());
static BULLET: Lazy<Regex> = Lazy::new(|| Regex::new(r"^(\s*)([-*+]) ").unwrap());
static ORDERED: Lazy<Regex> = Lazy::new(|| Regex::new(r"^(\s*)(\d+[.)]) ").unwrap());
static INLINE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(\*\*[^*\n]+?\*\*)|(`[^`\n]+?`)|((?:^|[^\w*])\*[^*\s][^*\n]*?\*)|((?:^|[^\w_])_[^_\s][^_\n]*?_)|(!?\[[^\]\n]*\]\([^)\n]*\))|(@[a-zA-Z][a-zA-Z0-9_-]*)").unwrap()
});

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Plain,
    Marker,
    Bold,
    Code,
    Italic,
    Link,
    Tag,
    Done,
    Quote,
    Heading,
}

/// Each char of `line` with the style it should be drawn in.
pub fn style_chars(line: &str, p: &Palette, dim: bool) -> Vec<(char, Style)> {
    let chars: Vec<char> = line.chars().collect();
    let mut kinds = vec![Kind::Plain; chars.len()];
    // byte offset → char index
    let mut idx_of = Vec::with_capacity(line.len() + 1);
    for (ci, (bi, ch)) in line.char_indices().enumerate() {
        while idx_of.len() < bi {
            idx_of.push(ci);
        }
        idx_of.push(ci);
        let _ = ch;
    }
    while idx_of.len() <= line.len() {
        idx_of.push(chars.len());
    }
    let mark = |kinds: &mut Vec<Kind>, a: usize, b: usize, k: Kind| {
        let (from, to) = (idx_of[a], idx_of[b].min(chars.len()));
        if from < to {
            kinds[from..to].fill(k);
        }
    };

    let mut rest_from = 0;
    let mut base = Kind::Plain;
    if let Some(m) = HEADING.captures(line) {
        let h = m.get(2).unwrap();
        mark(&mut kinds, h.start(), h.end(), Kind::Marker);
        rest_from = m.get(0).unwrap().end();
        base = Kind::Heading;
    } else if let Some(m) = QUOTE.captures(line) {
        let full = m.get(0).unwrap();
        mark(&mut kinds, full.start(), full.end(), Kind::Marker);
        rest_from = full.end();
        base = Kind::Quote;
    } else if let Some(m) = CHECK.captures(line) {
        let b = m.get(2).unwrap();
        let c = m.get(3).unwrap();
        mark(&mut kinds, b.start(), b.end(), Kind::Tag);
        let checked = !m[3].contains(' ');
        mark(&mut kinds, c.start(), c.end(), if checked { Kind::Tag } else { Kind::Marker });
        rest_from = m.get(0).unwrap().end();
        if checked {
            base = Kind::Done;
        }
    } else if let Some(m) = BULLET.captures(line) {
        let b = m.get(2).unwrap();
        mark(&mut kinds, b.start(), b.end(), Kind::Tag);
        rest_from = m.get(0).unwrap().end();
    } else if let Some(m) = ORDERED.captures(line) {
        let b = m.get(2).unwrap();
        mark(&mut kinds, b.start(), b.end(), Kind::Tag);
        rest_from = m.get(0).unwrap().end();
    }
    if base != Kind::Plain {
        mark(&mut kinds, rest_from, line.len(), base);
    }
    if base != Kind::Done {
        for c in INLINE.captures_iter(&line[rest_from..]) {
            let whole = c.get(0).unwrap();
            let (s, e) = (rest_from + whole.start(), rest_from + whole.end());
            if c.get(1).is_some() {
                mark(&mut kinds, s, s + 2, Kind::Marker);
                mark(&mut kinds, s + 2, e - 2, Kind::Bold);
                mark(&mut kinds, e - 2, e, Kind::Marker);
            } else if c.get(2).is_some() {
                mark(&mut kinds, s, s + 1, Kind::Marker);
                mark(&mut kinds, s + 1, e - 1, Kind::Code);
                mark(&mut kinds, e - 1, e, Kind::Marker);
            } else if c.get(3).is_some() || c.get(4).is_some() {
                // The match may start one char early (the non-word guard).
                let text = whole.as_str();
                let lead = text.chars().next().map(|ch| if ch == '*' || ch == '_' { 0 } else { ch.len_utf8() }).unwrap_or(0);
                let s2 = s + lead;
                mark(&mut kinds, s2, s2 + 1, Kind::Marker);
                mark(&mut kinds, s2 + 1, e - 1, Kind::Italic);
                mark(&mut kinds, e - 1, e, Kind::Marker);
            } else if c.get(5).is_some() {
                let text = whole.as_str();
                let bang = usize::from(text.starts_with('!'));
                let close = text.find("](").unwrap_or(text.len());
                mark(&mut kinds, s, s + bang + 1, Kind::Marker);
                mark(&mut kinds, s + bang + 1, s + close, Kind::Link);
                mark(&mut kinds, s + close, e, Kind::Marker);
            } else if c.get(6).is_some() {
                mark(&mut kinds, s, e, Kind::Tag);
            }
        }
    }

    chars
        .iter()
        .zip(kinds)
        .map(|(ch, k)| {
            let st = if dim {
                match k {
                    Kind::Marker => p.dimmed().add_modifier(Modifier::DIM),
                    Kind::Bold | Kind::Heading => p.dimmed().add_modifier(Modifier::BOLD),
                    Kind::Italic | Kind::Quote => p.dimmed().add_modifier(Modifier::ITALIC),
                    Kind::Done => p.dimmed().add_modifier(Modifier::CROSSED_OUT),
                    _ => p.dimmed(),
                }
            } else {
                match k {
                    Kind::Plain => p.ink(),
                    Kind::Marker => p.faint(),
                    Kind::Bold | Kind::Heading => p.bold(),
                    Kind::Code => p.code(),
                    Kind::Italic => p.italic(),
                    Kind::Quote => p.muted_italic(),
                    Kind::Link => Style::default().fg(p.muted).add_modifier(Modifier::UNDERLINED),
                    Kind::Tag => p.accent(),
                    Kind::Done => p.faint().add_modifier(Modifier::CROSSED_OUT),
                }
            };
            (*ch, st)
        })
        .collect()
}

/// A whole line as spans (runs of equal style).
pub fn style_line(line: &str, p: &Palette, dim: bool) -> ratatui::text::Line<'static> {
    spans_of(&style_chars(line, p, dim))
}

pub fn spans_of(chars: &[(char, Style)]) -> ratatui::text::Line<'static> {
    let mut out: Vec<ratatui::text::Span<'static>> = Vec::new();
    let mut cur = String::new();
    let mut cur_style: Option<Style> = None;
    for (ch, st) in chars {
        if cur_style.map(|c| c != *st).unwrap_or(false) {
            out.push(ratatui::text::Span::styled(std::mem::take(&mut cur), cur_style.unwrap()));
        }
        cur_style = Some(*st);
        cur.push(*ch);
    }
    if let Some(st) = cur_style {
        out.push(ratatui::text::Span::styled(cur, st));
    }
    ratatui::text::Line::from(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use quire_core::themes::theme;

    fn pal() -> Palette {
        Palette::from_theme(&theme("cinema"), true)
    }

    #[test]
    fn markers_fade_and_text_takes_weight() {
        let p = pal();
        let s = style_chars("## Head", &p, false);
        assert_eq!(s[0].1, p.faint());
        assert_eq!(s[3].1, p.bold());
        let s = style_chars("> quoted", &p, false);
        assert_eq!(s[0].1, p.faint());
        assert_eq!(s[2].1, p.muted_italic());
        let s = style_chars("- [x] done @tag", &p, false);
        assert_eq!(s[0].1, p.accent());
        assert!(s[6].1.add_modifier.contains(Modifier::CROSSED_OUT));
        let s = style_chars("a **b** `c` _d_ @t e", &p, false);
        assert_eq!(s[2].1, p.faint());
        assert_eq!(s[4].1, p.bold());
        assert_eq!(s[9].1, p.code());
        assert_eq!(s[13].1, p.italic());
        assert_eq!(s[16].1, p.accent());
        assert_eq!(s[19].1, p.ink());
        let s = style_chars("x", &p, true);
        assert_eq!(s[0].1.fg, Some(p.dim));
        // snake_case words are not italic
        let s = style_chars("some_var_name", &p, false);
        assert!(s.iter().all(|(_, st)| *st == p.ink()));
    }
}
