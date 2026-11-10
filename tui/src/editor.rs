//! The composer's text buffer: lines, a caret, soft wrapping, and the macros
//! (↩ in a list, toggling `**`/`_`/`` ` `` on the word under the caret,
//! `@` autocomplete). Line 0 is the title; the body starts at line 1.

use quire_core::editing::{list_continuation, toggle_wrap, word_at, ListStep};
use std::time::Instant;
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

/// What a tab becomes when it is typed or pasted: a terminal draws no tab, so
/// one kept in the text would be counted but never seen.
pub const TAB: &str = "    ";

/// One grapheme cluster of a line: chars `[start, start + len)`, `width`
/// cells wide. The caret, the wrap and backspace all move a cluster at a
/// time, so a flag or a family emoji (several code points, two cells) is one
/// step and the caret stays where the terminal draws it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cluster {
    pub start: usize,
    pub len: usize,
    pub width: usize,
}

/// The cells a cluster takes, as ratatui draws it. A control character (a tab
/// already in an entry) is drawn as one space by the composer.
fn cluster_width(g: &str) -> usize {
    if g.chars().any(char::is_control) {
        g.chars().count()
    } else {
        g.width()
    }
}

pub fn clusters(line: &str) -> Vec<Cluster> {
    let mut out = Vec::new();
    let mut at = 0;
    for g in line.graphemes(true) {
        let len = g.chars().count();
        out.push(Cluster { start: at, len, width: cluster_width(g) });
        at += len;
    }
    out
}

/// Text as the buffer keeps it: LF line ends, a tab as spaces, no other
/// control characters (they would be counted and never drawn).
fn clean(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\r' => {
                if chars.peek() != Some(&'\n') {
                    out.push('\n');
                }
            }
            '\n' => out.push('\n'),
            '\t' => out.push_str(TAB),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

pub struct Editor {
    pub lines: Vec<String>,
    pub row: usize,
    /// Char index within the row.
    pub col: usize,
    /// First visual row shown.
    pub scroll: usize,
    pub dirty: bool,
    pub last_edit: Instant,
    want_col: Option<usize>,
}

/// One screen row of a wrapped line: chars `[start, end)` of `row`.
#[derive(Clone, Copy, Debug)]
pub struct VisualRow {
    pub row: usize,
    pub start: usize,
    pub end: usize,
}

impl Editor {
    pub fn new(title: &str, body: &str) -> Editor {
        let mut lines = vec![title.to_string()];
        if !body.is_empty() {
            lines.push(String::new());
            lines.extend(body.split('\n').map(|l| l.to_string()));
        }
        Editor { lines, row: 0, col: 0, scroll: 0, dirty: false, last_edit: Instant::now(), want_col: None }
    }

    pub fn title(&self) -> String {
        self.lines[0].clone()
    }

    pub fn body(&self) -> String {
        let mut rest: Vec<&str> = self.lines[1..].iter().map(|s| s.as_str()).collect();
        while rest.first().map(|l| l.trim().is_empty()).unwrap_or(false) {
            rest.remove(0);
        }
        rest.join("\n")
    }

    pub fn is_empty(&self) -> bool {
        self.lines.iter().all(|l| l.trim().is_empty())
    }

    pub fn word_count(&self) -> usize {
        self.body().split_whitespace().count()
    }

    /// Put the caret at the end of the text.
    pub fn to_end(&mut self) {
        self.row = self.lines.len() - 1;
        self.col = self.cur_len();
        self.want_col = None;
    }

    fn cur_len(&self) -> usize {
        self.lines[self.row].chars().count()
    }

    fn touched(&mut self) {
        self.dirty = true;
        self.last_edit = Instant::now();
        self.want_col = None;
    }

    fn byte_at(line: &str, col: usize) -> usize {
        line.char_indices().nth(col).map(|(b, _)| b).unwrap_or(line.len())
    }

    pub fn insert_char(&mut self, ch: char) {
        if ch == '\t' {
            return self.insert_str(TAB);
        }
        if ch.is_control() {
            return;
        }
        let line = &mut self.lines[self.row];
        let b = Self::byte_at(line, self.col);
        line.insert(b, ch);
        self.col += 1;
        self.touched();
    }

    /// Insert text at the caret, a whole line at a time: the caret's line is
    /// cut once and each pasted line goes in as one piece, so a long paste
    /// costs its own length and not that times the line's.
    pub fn insert_str(&mut self, s: &str) {
        let text = clean(s);
        if text.is_empty() {
            return;
        }
        let b = Self::byte_at(&self.lines[self.row], self.col);
        let tail = self.lines[self.row].split_off(b);
        let mut parts = text.split('\n');
        let first = parts.next().unwrap_or("");
        self.lines[self.row].push_str(first);
        self.col += first.chars().count();
        let mut more: Vec<String> = parts.map(str::to_string).collect();
        match more.last_mut() {
            Some(last) => {
                self.col = last.chars().count();
                last.push_str(&tail);
                let n = more.len();
                self.lines.splice(self.row + 1..self.row + 1, more);
                self.row += n;
            }
            None => self.lines[self.row].push_str(&tail),
        }
        self.touched();
    }

    /// The cluster that ends at, or holds, char `col` of the caret's line,
    /// and the one that starts at (or holds) it.
    fn cluster_before(&self, col: usize) -> Option<Cluster> {
        clusters(&self.lines[self.row]).into_iter().rev().find(|c| c.start < col)
    }

    fn cluster_at(&self, col: usize) -> Option<Cluster> {
        clusters(&self.lines[self.row]).into_iter().find(|c| c.start + c.len > col)
    }

    fn remove_chars(&mut self, start: usize, end: usize) {
        let line = &mut self.lines[self.row];
        let (a, b) = (Self::byte_at(line, start), Self::byte_at(line, end));
        line.replace_range(a..b, "");
    }

    fn split_line(&mut self) {
        let line = &mut self.lines[self.row];
        let b = Self::byte_at(line, self.col);
        let tail = line.split_off(b);
        self.lines.insert(self.row + 1, tail);
        self.row += 1;
        self.col = 0;
        self.touched();
    }

    /// Return: continue or end a list in the body; a plain break elsewhere.
    pub fn newline(&mut self) {
        if self.row > 0 && self.col == self.cur_len() {
            let line = self.lines[self.row].clone();
            match list_continuation(&line) {
                Some(ListStep::Continue(prefix)) => {
                    self.split_line();
                    self.insert_str(&prefix);
                    return;
                }
                Some(ListStep::End(n)) => {
                    let keep: String = line.chars().skip(n).collect();
                    self.lines[self.row] = keep;
                    self.col = 0;
                    self.touched();
                    return;
                }
                None => {}
            }
        }
        self.split_line();
    }

    pub fn backspace(&mut self) {
        if let Some(c) = self.cluster_before(self.col) {
            self.remove_chars(c.start, self.col);
            self.col = c.start;
            self.touched();
        } else if self.row > 0 {
            let cur = self.lines.remove(self.row);
            self.row -= 1;
            self.col = self.cur_len();
            self.lines[self.row].push_str(&cur);
            self.touched();
        }
    }

    pub fn delete(&mut self) {
        if let Some(c) = self.cluster_at(self.col) {
            self.remove_chars(self.col, c.start + c.len);
            self.touched();
        } else if self.row + 1 < self.lines.len() {
            let next = self.lines.remove(self.row + 1);
            self.lines[self.row].push_str(&next);
            self.touched();
        }
    }

    /// Delete the word before the caret (Ctrl+W / Alt+Backspace).
    pub fn delete_word_back(&mut self) {
        if self.col == 0 {
            self.backspace();
            return;
        }
        let chars: Vec<char> = self.lines[self.row].chars().collect();
        let mut a = self.col;
        while a > 0 && chars[a - 1].is_whitespace() {
            a -= 1;
        }
        while a > 0 && !chars[a - 1].is_whitespace() {
            a -= 1;
        }
        let new: String = chars[..a].iter().chain(chars[self.col..].iter()).collect();
        self.lines[self.row] = new;
        self.col = a;
        self.touched();
    }

    pub fn left(&mut self) {
        if let Some(c) = self.cluster_before(self.col) {
            self.col = c.start;
        } else if self.row > 0 {
            self.row -= 1;
            self.col = self.cur_len();
        }
        self.want_col = None;
    }

    pub fn right(&mut self) {
        if let Some(c) = self.cluster_at(self.col) {
            self.col = c.start + c.len;
        } else if self.row + 1 < self.lines.len() {
            self.row += 1;
            self.col = 0;
        }
        self.want_col = None;
    }

    pub fn word_left(&mut self) {
        if self.col == 0 {
            self.left();
            return;
        }
        let chars: Vec<char> = self.lines[self.row].chars().collect();
        let mut a = self.col;
        while a > 0 && chars[a - 1].is_whitespace() {
            a -= 1;
        }
        while a > 0 && !chars[a - 1].is_whitespace() {
            a -= 1;
        }
        self.col = a;
        self.want_col = None;
    }

    pub fn word_right(&mut self) {
        let chars: Vec<char> = self.lines[self.row].chars().collect();
        if self.col >= chars.len() {
            self.right();
            return;
        }
        let mut b = self.col;
        while b < chars.len() && !chars[b].is_whitespace() {
            b += 1;
        }
        while b < chars.len() && chars[b].is_whitespace() {
            b += 1;
        }
        self.col = b;
        self.want_col = None;
    }

    pub fn home(&mut self) {
        self.col = 0;
        self.want_col = None;
    }

    pub fn end(&mut self) {
        self.col = self.cur_len();
        self.want_col = None;
    }

    /// Up and down walk visual rows, keeping the column where it was.
    pub fn up(&mut self, width: usize) {
        self.move_visual(width, -1);
    }

    pub fn down(&mut self, width: usize) {
        self.move_visual(width, 1);
    }

    fn move_visual(&mut self, width: usize, delta: isize) {
        let rows = self.layout(width);
        let Some(i) = self.visual_index(&rows) else { return };
        let want = self.want_col.unwrap_or_else(|| self.visual_x(&rows[i]));
        let j = i as isize + delta;
        if j < 0 || j as usize >= rows.len() {
            if delta < 0 {
                self.row = 0;
                self.col = 0;
            } else {
                self.to_end();
            }
            return;
        }
        let r = rows[j as usize];
        let last = self.is_last_segment(&rows, &r);
        self.row = r.row;
        self.col = self.col_at(&r, want, last);
        self.want_col = Some(want);
    }

    /// The char `dx` cells into visual row `r`, walking cluster widths (a
    /// wide character is two cells and one step). On a row that wraps on, the
    /// row's end belongs to the row below, so the caret stops before the
    /// row's last cluster (its trailing space) instead.
    fn col_at(&self, r: &VisualRow, dx: usize, last: bool) -> usize {
        let Some(line) = self.lines.get(r.row) else { return 0 };
        let in_row: Vec<Cluster> = clusters(line).into_iter().filter(|c| c.start >= r.start && c.start < r.end).collect();
        let (mut col, mut w) = (r.start, 0);
        for c in &in_row {
            if w + c.width > dx {
                break;
            }
            w += c.width;
            col = c.start + c.len;
        }
        if col >= r.end && !last {
            if let Some(c) = in_row.last() {
                col = c.start;
            }
        }
        col
    }

    /// A click `dx` cells into visual row `r`: the caret goes before the
    /// character there, or to the row's end. `last` says `r` is the line's
    /// last segment; otherwise its end belongs to the row below.
    pub fn place(&mut self, r: VisualRow, dx: usize, last: bool) {
        if self.lines.get(r.row).is_none() {
            return;
        }
        self.row = r.row;
        self.col = self.col_at(&r, dx, last);
        self.want_col = None;
    }

    /// Insert an attachment's link into the body, on its own paragraph when
    /// the caret is mid-line (as the desktop app does); from the title, at
    /// the end of the body.
    pub fn insert_block(&mut self, text: &str) {
        if self.row == 0 {
            if self.lines.len() == 1 {
                self.lines.push(String::new());
                self.lines.push(String::new());
            }
            self.to_end();
        }
        if self.col > 0 {
            self.insert_str("\n\n");
        }
        self.insert_str(text);
    }

    /// Toggle `open…close` around the word under the caret (`**`, `_`, `` ` ``).
    pub fn toggle_wrap_word(&mut self, open: &str, close: &str) {
        let line = self.lines[self.row].clone();
        match word_at(&line, self.col) {
            Some((a, b)) => {
                let chars: Vec<char> = line.chars().collect();
                let word: String = chars[a..b].iter().collect();
                let new = toggle_wrap(&word, open, close);
                let rebuilt: String = chars[..a].iter().collect::<String>() + &new + &chars[b..].iter().collect::<String>();
                self.lines[self.row] = rebuilt;
                let grew = new.chars().count() as isize - word.chars().count() as isize;
                self.col = (self.col as isize + grew).clamp(a as isize, (a + new.chars().count()) as isize) as usize;
                self.touched();
            }
            None => {
                self.insert_str(open);
                let here = self.col;
                self.insert_str(close);
                self.col = here;
            }
        }
    }

    /// The `@word` being typed at the caret: (start col, text without `@`).
    pub fn tag_prefix(&self) -> Option<(usize, String)> {
        let chars: Vec<char> = self.lines[self.row].chars().collect();
        let mut a = self.col;
        while a > 0 && (chars[a - 1].is_ascii_alphanumeric() || chars[a - 1] == '_' || chars[a - 1] == '-') {
            a -= 1;
        }
        if a == 0 || chars[a - 1] != '@' {
            return None;
        }
        if a >= 2 && (chars[a - 2].is_alphanumeric() || chars[a - 2] == '.' || chars[a - 2] == '/') {
            return None; // an email or a URL
        }
        let text: String = chars[a..self.col].iter().collect();
        if text.chars().next().map(|c| !c.is_ascii_alphabetic()).unwrap_or(false) {
            return None;
        }
        Some((a - 1, text))
    }

    /// Replace the `@prefix` at the caret with `tag` (with its `@`) and a space.
    pub fn accept_tag(&mut self, tag: &str) {
        let Some((start, _)) = self.tag_prefix() else { return };
        let chars: Vec<char> = self.lines[self.row].chars().collect();
        let rebuilt: String = chars[..start].iter().collect::<String>() + tag + " " + &chars[self.col..].iter().collect::<String>();
        self.lines[self.row] = rebuilt;
        self.col = start + tag.chars().count() + 1;
        self.touched();
    }

    /// The body paragraph (rows between blank lines) the caret is in.
    pub fn paragraph(&self) -> (usize, usize) {
        if self.row == 0 {
            return (0, 0);
        }
        let blank = |i: usize| self.lines[i].trim().is_empty();
        if blank(self.row) {
            return (self.row, self.row);
        }
        let mut a = self.row;
        while a > 1 && !blank(a - 1) {
            a -= 1;
        }
        let mut b = self.row;
        while b + 1 < self.lines.len() && !blank(b + 1) {
            b += 1;
        }
        (a, b)
    }

    // ----- wrapping -----

    /// Soft-wrap every line to `width` cells, breaking at spaces and never
    /// inside a grapheme cluster.
    pub fn layout(&self, width: usize) -> Vec<VisualRow> {
        let width = width.max(8);
        let mut out = Vec::new();
        for (row, line) in self.lines.iter().enumerate() {
            let cs = clusters(line);
            if cs.is_empty() {
                out.push(VisualRow { row, start: 0, end: 0 });
                continue;
            }
            let total = cs.last().map(|c| c.start + c.len).unwrap_or(0);
            let spaces: Vec<bool> = line.graphemes(true).map(|g| g == " ").collect();
            let mut i = 0;
            while i < cs.len() {
                let start = cs[i].start;
                let mut w = 0;
                let mut k = i;
                let mut last_space: Option<usize> = None;
                while k < cs.len() {
                    // A cluster wider than the whole row still has to go somewhere.
                    if w + cs[k].width > width && k > i {
                        break;
                    }
                    w += cs[k].width;
                    if spaces[k] {
                        last_space = Some(k);
                    }
                    k += 1;
                }
                if k < cs.len() {
                    if let Some(sp) = last_space {
                        if sp > i {
                            k = sp + 1;
                        }
                    }
                }
                let end = cs.get(k).map(|c| c.start).unwrap_or(total);
                out.push(VisualRow { row, start, end });
                i = k;
            }
        }
        out
    }

    /// Which visual row the caret is on.
    pub fn visual_index(&self, rows: &[VisualRow]) -> Option<usize> {
        rows.iter().position(|r| r.row == self.row && self.col >= r.start && (self.col < r.end || (self.col == r.end && self.is_last_segment(rows, r))))
    }

    fn is_last_segment(&self, rows: &[VisualRow], r: &VisualRow) -> bool {
        !rows.iter().any(|o| o.row == r.row && o.start == r.end && o.end > o.start)
    }

    /// The caret's x within its visual row.
    pub fn visual_x(&self, r: &VisualRow) -> usize {
        clusters(&self.lines[r.row]).iter().filter(|c| c.start >= r.start && c.start + c.len <= self.col).map(|c| c.width).sum()
    }

    /// Keep the caret on screen: scroll only once it leaves a band near the
    /// top or bottom, then settle it a little above centre.
    pub fn ensure_visible(&mut self, rows: &[VisualRow], height: usize) {
        let Some(i) = self.visual_index(rows) else { return };
        // The real height, however small: pretending a one-row window has
        // three leaves the caret on a row that is not drawn.
        let height = height.max(1);
        let band = if height < 5 { 0 } else { (height / 5).clamp(1, 4) };
        if i < self.scroll + band || i + band >= self.scroll + height {
            let target = (height as f32 * 0.42) as usize;
            self.scroll = i.saturating_sub(target);
        }
        let max_scroll = rows.len().saturating_sub(height);
        self.scroll = self.scroll.min(max_scroll.max(i.saturating_sub(height - 1)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typing_lists_and_wrap() {
        let mut e = Editor::new("", "");
        e.insert_str("Title");
        e.newline();
        e.newline();
        e.insert_str("- one");
        e.newline();
        assert_eq!(e.lines[3], "- ");
        e.insert_str("two");
        e.newline();
        assert_eq!(e.lines[4], "- ");
        e.newline();
        assert_eq!(e.lines[4], "", "an empty item ends the list");
        assert_eq!(e.title(), "Title");
        assert_eq!(e.body(), "- one\n- two\n");
        e.insert_str("bold");
        e.toggle_wrap_word("**", "**");
        assert_eq!(e.lines[4], "**bold**");
        e.toggle_wrap_word("**", "**");
        assert_eq!(e.lines[4], "bold");
        e.insert_str(" @wo");
        assert_eq!(e.tag_prefix(), Some((5, "wo".into())));
        e.accept_tag("@work");
        assert_eq!(e.lines[4], "bold @work ");
        e.backspace();
        e.delete_word_back();
        assert_eq!(e.lines[4], "bold ");
    }

    #[test]
    fn layout_wraps_at_spaces() {
        let e = Editor::new("t", "aaaa bbbb cccc dddd");
        let rows = e.layout(10);
        let segs: Vec<String> = rows.iter().map(|r| e.lines[r.row].chars().skip(r.start).take(r.end - r.start).collect()).collect();
        assert_eq!(segs, vec!["t", "", "aaaa bbbb ", "cccc dddd"]);
        let mut e2 = e;
        e2.to_end();
        let rows = e2.layout(10);
        assert_eq!(e2.visual_index(&rows), Some(3));
        e2.up(10);
        assert_eq!((e2.row, e2.col), (2, 9));
    }

    #[test]
    fn clicks_place_the_caret() {
        let mut e = Editor::new("t", "aaaa bbbb cccc dddd");
        let rows = e.layout(10);
        e.place(rows[2], 2, false);
        assert_eq!((e.row, e.col), (2, 2));
        e.place(rows[2], 40, false);
        assert_eq!((e.row, e.col), (2, 9), "past a wrapped row: before its trailing space");
        e.place(rows[3], 40, true);
        assert_eq!((e.row, e.col), (2, 19), "past the last row: the line's end");
        e.place(rows[0], 0, true);
        assert_eq!((e.row, e.col), (0, 0));
    }

    /// T4: Up onto a wrapped row shorter than the caret's column used to put
    /// the caret at that row's end, which is the start of the row it came
    /// from, and every further Up stayed there.
    #[test]
    fn up_crosses_a_wrapped_row_shorter_than_the_caret_column() {
        let mut e = Editor::new("t", "aaaa bb cccccccccc");
        let rows = e.layout(10);
        let segs: Vec<String> = rows.iter().map(|r| e.lines[r.row].chars().skip(r.start).take(r.end - r.start).collect()).collect();
        assert_eq!(segs, vec!["t", "", "aaaa bb ", "cccccccccc"]);
        e.to_end();
        e.left(); // nine cells in: past the end of "aaaa bb "
        assert_eq!((e.row, e.col), (2, 17));
        e.up(10);
        assert_eq!((e.row, e.col), (2, 7), "before the wrapped row's trailing space, not at the next row's start");
        assert_eq!(e.visual_index(&e.layout(10)), Some(2));
        e.up(10);
        assert_eq!((e.row, e.col), (1, 0), "and Up keeps going");
        e.up(10);
        assert_eq!((e.row, e.col), (0, 1));
        // Back down: the column it started from is remembered.
        e.down(10);
        e.down(10);
        e.down(10);
        assert_eq!((e.row, e.col), (2, 17));
    }

    #[test]
    fn up_and_down_count_cells_not_chars() {
        // Row one is five wide characters (ten cells); row two is ASCII.
        let mut e = Editor::new("", "日本語日本\nabcdefgh");
        e.row = 3;
        e.col = 6;
        e.up(20);
        assert_eq!((e.row, e.col), (2, 3), "six cells in is three wide characters in");
        e.down(20);
        assert_eq!((e.row, e.col), (3, 6));
    }

    #[test]
    fn the_caret_and_backspace_move_a_cluster_at_a_time() {
        let family = "👨\u{200d}👩\u{200d}👧"; // five code points, one cluster, two cells
        let flag = "🇬🇧"; // two code points
        let mut e = Editor::new("", &format!("a{family}b{flag}e\u{301}"));
        e.row = 2;
        e.col = 0;
        let stops: Vec<usize> = (0..5).map(|_| { e.right(); e.col }).collect();
        assert_eq!(stops, vec![1, 6, 7, 9, 11]);
        let rows = e.layout(40);
        e.col = 6;
        assert_eq!(e.visual_x(&rows[2]), 3, "the family is two cells");
        e.left();
        assert_eq!(e.col, 1);
        e.col = 6;
        e.backspace();
        assert_eq!(e.lines[2], format!("ab{flag}e\u{301}"));
        e.delete(); // b
        e.delete(); // the flag, whole
        assert_eq!(e.lines[2], "ae\u{301}");
        // A wrap never lands inside a cluster.
        let e = Editor::new("", &family.repeat(6));
        for r in e.layout(8) {
            assert_eq!(r.start % 5, 0, "{r:?}");
        }
    }

    #[test]
    fn tabs_become_spaces_and_a_paste_goes_in_by_the_line() {
        let mut e = Editor::new("", "");
        e.insert_str("Title\n\nhead tail");
        e.col = 4;
        e.insert_str("\tone\r\ntwo\rthree\u{7}");
        assert_eq!(e.lines, vec!["Title", "", "head    one", "two", "three tail"]);
        assert_eq!((e.row, e.col), (4, 5));
        e.insert_char('\t');
        assert_eq!(e.lines[4], "three     tail");
        assert_eq!(e.col, 9);
        // A tab already in an entry is one cell, drawn as a space.
        let mut old = Editor::new("", "a\tb");
        old.to_end();
        assert_eq!(old.visual_x(&old.layout(20)[2]), 3);
        assert!(!old.dirty);
    }

    #[test]
    fn a_short_window_keeps_the_caret_on_a_drawn_row() {
        let mut e = Editor::new("t", "one\ntwo\nthree\nfour");
        e.to_end();
        for height in 1..4 {
            let rows = e.layout(20);
            e.ensure_visible(&rows, height);
            let i = e.visual_index(&rows).unwrap();
            assert!(i >= e.scroll && i < e.scroll + height, "height {height}: row {i}, scroll {}", e.scroll);
        }
    }

    #[test]
    fn attachments_get_their_own_paragraph() {
        let mut e = Editor::new("Title", "");
        e.to_end();
        e.insert_block("![](assets/a.jpg)");
        assert_eq!(e.body(), "![](assets/a.jpg)");
        e.insert_block("![](assets/b.jpg)");
        assert_eq!(e.body(), "![](assets/a.jpg)\n\n![](assets/b.jpg)");
        e.newline();
        e.insert_block("![](assets/c.jpg)");
        assert_eq!(e.body(), "![](assets/a.jpg)\n\n![](assets/b.jpg)\n![](assets/c.jpg)");
    }
}
