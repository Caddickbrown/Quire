//! The composer's text buffer: lines, a caret, soft wrapping, and the macros
//! (↩ in a list, toggling `**`/`_`/`` ` `` on the word under the caret,
//! `@` autocomplete). Line 0 is the title; the body starts at line 1.

use quire_core::editing::{list_continuation, toggle_wrap, word_at, ListStep};
use std::time::Instant;
use unicode_width::UnicodeWidthChar;

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
        let line = &mut self.lines[self.row];
        let b = Self::byte_at(line, self.col);
        line.insert(b, ch);
        self.col += 1;
        self.touched();
    }

    pub fn insert_str(&mut self, s: &str) {
        for ch in s.chars() {
            if ch == '\n' {
                self.split_line();
            } else {
                self.insert_char(ch);
            }
        }
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
        if self.col > 0 {
            let line = &mut self.lines[self.row];
            let b = Self::byte_at(line, self.col - 1);
            line.remove(b);
            self.col -= 1;
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
        if self.col < self.cur_len() {
            let line = &mut self.lines[self.row];
            let b = Self::byte_at(line, self.col);
            line.remove(b);
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
        if self.col > 0 {
            self.col -= 1;
        } else if self.row > 0 {
            self.row -= 1;
            self.col = self.cur_len();
        }
        self.want_col = None;
    }

    pub fn right(&mut self) {
        if self.col < self.cur_len() {
            self.col += 1;
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
        self.row = r.row;
        self.col = (r.start + want).min(r.end);
        if r.end < self.lines[r.row].chars().count() && self.col == r.end && self.col > r.start {
            // Not past the trailing space of a wrapped row.
            self.col = r.end;
        }
        self.want_col = Some(want);
    }

    /// A click `dx` cells into visual row `r`: the caret goes before the
    /// character there, or to the row's end. `last` says `r` is the line's
    /// last segment; otherwise its end belongs to the row below.
    pub fn place(&mut self, r: VisualRow, dx: usize, last: bool) {
        let Some(line) = self.lines.get(r.row) else { return };
        let chars: Vec<char> = line.chars().collect();
        let (mut col, mut w) = (r.start, 0);
        while col < r.end.min(chars.len()) {
            let cw = chars[col].width().unwrap_or(1);
            if w + cw > dx {
                break;
            }
            w += cw;
            col += 1;
        }
        if col == r.end && !last && r.end > r.start {
            col = r.end - 1;
        }
        self.row = r.row;
        self.col = col;
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

    /// Soft-wrap every line to `width` cells, breaking at spaces.
    pub fn layout(&self, width: usize) -> Vec<VisualRow> {
        let width = width.max(8);
        let mut out = Vec::new();
        for (row, line) in self.lines.iter().enumerate() {
            let chars: Vec<char> = line.chars().collect();
            if chars.is_empty() {
                out.push(VisualRow { row, start: 0, end: 0 });
                continue;
            }
            let mut start = 0;
            while start < chars.len() {
                let mut w = 0;
                let mut end = start;
                let mut last_space: Option<usize> = None;
                while end < chars.len() {
                    let cw = chars[end].width().unwrap_or(1);
                    if w + cw > width {
                        break;
                    }
                    w += cw;
                    if chars[end] == ' ' {
                        last_space = Some(end);
                    }
                    end += 1;
                }
                if end < chars.len() {
                    if let Some(sp) = last_space {
                        if sp > start {
                            end = sp + 1;
                        }
                    }
                }
                out.push(VisualRow { row, start, end });
                start = end;
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
        self.lines[r.row].chars().skip(r.start).take(self.col.saturating_sub(r.start)).map(|c| c.width().unwrap_or(1)).sum()
    }

    /// Keep the caret on screen: scroll only once it leaves a band near the
    /// top or bottom, then settle it a little above centre.
    pub fn ensure_visible(&mut self, rows: &[VisualRow], height: usize) {
        let Some(i) = self.visual_index(rows) else { return };
        let height = height.max(3);
        let band = (height / 5).clamp(1, 4);
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
