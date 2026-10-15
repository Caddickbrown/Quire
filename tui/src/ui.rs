//! Drawing the seven screens. One typeface, one accent, one rule under the
//! masthead; hairline section rules with a left label; keys in the accent
//! with muted labels, in the same order on every screen.

use crate::app::{App, Hit, Modal, Pick, Screen};
use crate::md;
use crate::theme::Palette;
use quire_core::stats;
use quire_core::Entry;
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Clear, Paragraph};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::Frame;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

const WEEKDAYS: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const MONTHS_SHORT: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

pub fn draw(f: &mut Frame, app: &mut App) {
    app.hits.borrow_mut().clear();
    let area = f.area();
    let p = app.pal.clone();
    f.render_widget(Block::default().style(p.base()), area);
    if area.height < 6 || area.width < 30 {
        put(f, Rect::new(0, 0, area.width, 1), Line::from(Span::styled("Quire needs a bigger window", p.muted())));
        return;
    }
    let pad: u16 = 2;
    let inner = Rect::new(pad, 0, area.width.saturating_sub(pad * 2), area.height);
    let head = Rect::new(inner.x, 0, inner.width, 1);
    let rule_row = Rect::new(inner.x, 1, inner.width, 1);
    let body = Rect::new(inner.x, 3, inner.width, area.height.saturating_sub(5));
    let hint_row = Rect::new(inner.x, area.height - 1, inner.width, 1);

    match app.screen {
        Screen::Today => {
            masthead(f, app, head, &p, "today", plain(Line::from(Span::styled(stats::long_date(&app.today), p.muted()))));
            rule(f, rule_row, &p);
            today(f, body, app);
            hints(f, app, hint_row, &p, &[("n", "new"), ("i", "inbox"), ("j", "journal"), ("/", "search"), ("r", "random"), ("l", "look back"), (",", "settings")], &[("?", "keys"), ("q", "quit")], Some(app.drafts().len()));
        }
        Screen::Inbox => {
            let n = app.drafts().len();
            let right = plain(Line::from(vec![Span::styled("draft ", p.muted()), Span::styled(format!("{}", (app.inbox_i + 1).min(n.max(1))), p.bold()), Span::styled(format!(" of {}   ", n), p.muted())]));
            masthead(f, app, head, &p, "inbox  ·  review", right);
            rule(f, rule_row, &p);
            inbox(f, body, app);
            hints(f, app, hint_row, &p, &[("f", "file"), ("e", "edit"), ("*", "star"), ("t", "date & time"), ("d", "delete"), ("↑↓", "drafts")], &[("?", "keys"), ("esc", "back")], None);
        }
        Screen::Browse => {
            let crumb = match &app.browse.pick {
                Pick::Main => "journal".to_string(),
                Pick::All => "journal  ·  all".to_string(),
                Pick::Split(t) => format!("journal  ·  @{}", t),
            };
            masthead(f, app, head, &p, &crumb, picker_line(app));
            rule(f, rule_row, &p);
            browse(f, body, app);
            if app.browse.filtering {
                put(f, hint_row, Line::from(vec![Span::styled("/ ", p.key()), Span::styled(app.browse.filter.clone(), p.ink()), Span::styled("▏", p.accent()), Span::styled("   type to filter   ↵ keep   esc clear", p.muted())]));
            } else {
                hints(f, app, hint_row, &p, &[("↵", "open"), ("← →", "columns"), ("↑↓", "move"), ("/", "filter"), ("s", "journal"), ("u", "to inbox"), ("r", "random")], &[("?", "keys"), ("esc", "back")], None);
            }
        }
        Screen::Write => {
            let crumb = match &app.draft {
                Some(d) if d.filed => "editing".to_string(),
                Some(d) if d.ref_.is_some() => "draft".to_string(),
                _ => "new draft".to_string(),
            };
            let when = app.draft.as_ref().map(|d| format!("{}  ·  {}", stats::long_date(&d.ts[..10]), &d.ts[11..16])).unwrap_or_default();
            masthead(f, app, head, &p, &crumb, plain(Line::from(Span::styled(when, p.muted()))));
            rule(f, rule_row, &p);
            write(f, Rect::new(inner.x, 3, inner.width, area.height.saturating_sub(6)), app);
            if app.modal.is_none() {
                hints(f, app, hint_row, &p, &[("^j", "file"), ("^s", "save"), ("^t", "date & time"), ("^f", "focus"), ("^p", "prompt"), ("^o", "timer"), ("^b ^i ^g", "wrap"), ("↵↵", "ends a list")], &[("F1", "keys"), ("esc", "back")], None);
            }
        }
        Screen::LookBack => {
            let years = stats::years(&app.entries, app.today[..4].parse().unwrap_or(2026));
            let mut right: Vec<Item> = Vec::new();
            for y in years.iter().take(6) {
                right.push((Span::styled(y.to_string(), if *y == app.year { p.bold() } else { p.muted() }), Some(Hit::Year(*y))));
                right.push((Span::styled("   ", p.muted()), None));
            }
            masthead(f, app, head, &p, "look back", right);
            rule(f, rule_row, &p);
            lookback(f, body, app);
            hints(f, app, hint_row, &p, &[("← →", "year"), ("j", "journal"), ("i", "inbox"), ("n", "new")], &[("?", "keys"), ("esc", "back")], None);
        }
        Screen::Settings => {
            masthead(f, app, head, &p, "settings", plain(Line::from(Span::styled("saved as you change them", p.muted()))));
            rule(f, rule_row, &p);
            settings(f, body, app);
            hints(f, app, hint_row, &p, &[("← →", "change"), ("↑↓", "choose")], &[("?", "keys"), ("esc", "back")], None);
        }
        Screen::Search => {
            let n = app.results().len();
            masthead(f, app, head, &p, "search", plain(Line::from(Span::styled(if app.query.is_empty() { String::new() } else { format!("{} result{}", n, if n == 1 { "" } else { "s" }) }, p.muted()))));
            rule(f, rule_row, &p);
            search(f, body, app);
            hints(f, app, hint_row, &p, &[("↵", "open"), ("↑↓", "results")], &[("esc", if app.query.is_empty() { "back" } else { "clear" })], None);
        }
    }

    if let Some(m) = &app.modal {
        // Only the modal's answers are clickable while it is up.
        app.hits.borrow_mut().clear();
        let (enter, esc) = (Some(Hit::Key(KeyEvent::from(KeyCode::Enter))), Some(Hit::Key(KeyEvent::from(KeyCode::Esc))));
        let items: Vec<Item> = match m {
            Modal::Retime(v) => vec![
                (Span::styled("Date & time  ", p.muted()), None),
                (Span::styled(v.clone(), p.ink()), None),
                (Span::styled("▏", p.accent()), None),
                (Span::styled("   YYYY-MM-DD HH:MM   ", p.muted()), None),
                (Span::styled("↵ apply", p.muted()), enter),
                (Span::styled("   ", p.muted()), None),
                (Span::styled("esc cancel", p.muted()), esc),
            ],
            Modal::Input { label, value, .. } => vec![
                (Span::styled(format!("{}  ", label), p.muted()), None),
                (Span::styled(value.clone(), p.ink()), None),
                (Span::styled("▏", p.accent()), None),
                (Span::styled("   ", p.muted()), None),
                (Span::styled("↵ ok", p.muted()), enter),
                (Span::styled("   ", p.muted()), None),
                (Span::styled("esc cancel", p.muted()), esc),
            ],
            Modal::Restore(names, i) => vec![
                (Span::styled("Restore  ", p.muted()), None),
                (Span::styled(format!("‹ {} ›", names.get(*i).map(|s| s.as_str()).unwrap_or("")), p.accent()), None),
                (Span::styled(format!("  {}/{}   ", i + 1, names.len()), p.faint()), None),
                (Span::styled("↵ restore", p.muted()), enter),
                (Span::styled("   ", p.muted()), None),
                (Span::styled("esc cancel", p.muted()), esc),
            ],
            Modal::Confirm { text, .. } => vec![
                (Span::styled(text.clone(), p.ink()), None),
                (Span::styled("   ", p.ink()), None),
                (Span::styled("y", p.key()), Some(Hit::Key(KeyEvent::from(KeyCode::Char('y'))))),
                (Span::styled(" yes", p.muted()), Some(Hit::Key(KeyEvent::from(KeyCode::Char('y'))))),
                (Span::styled("   ", p.muted()), None),
                (Span::styled("n", p.key()), Some(Hit::Key(KeyEvent::from(KeyCode::Char('n'))))),
                (Span::styled(" no", p.muted()), Some(Hit::Key(KeyEvent::from(KeyCode::Char('n'))))),
            ],
        };
        f.render_widget(Block::default().style(p.base()), hint_row);
        put_items(f, app, hint_row, items);
    }
    hover_highlight(f, app);
    if let Some((msg, _, err)) = &app.toast {
        let w = (msg.width() as u16 + 4).min(inner.width);
        let r = Rect::new(inner.x + inner.width.saturating_sub(w), area.height - 3, w, 1);
        f.render_widget(Clear, r);
        let st = if *err { Style::default().fg(p.on_accent).bg(p.accent) } else { Style::default().fg(p.fg).bg(p.card) };
        put(f, r, Line::from(Span::styled(format!("  {}  ", msg), st)));
    }
    if app.help {
        app.hits.borrow_mut().clear(); // any click closes it
        help_overlay(f, area, app);
    }
}

/// Underline what a click under the pointer would press. Text areas are left
/// alone, and so is anything while a modal or the help overlay is up.
fn hover_highlight(f: &mut Frame, app: &App) {
    use ratatui::layout::Position;
    use ratatui::style::Modifier;
    let Some((x, y)) = app.hover else { return };
    if !app.mouse || app.help {
        return;
    }
    let Some(rect) = app.hit_rect_at(x, y) else { return };
    let area = f.area();
    let buf = f.buffer_mut();
    for yy in rect.y..(rect.y + rect.height).min(area.height) {
        for xx in rect.x..(rect.x + rect.width).min(area.width) {
            if let Some(c) = buf.cell_mut(Position::new(xx, yy)) {
                let st = c.style().add_modifier(Modifier::UNDERLINED);
                c.set_style(st);
            }
        }
    }
}

// ---------- furniture ----------

fn put(f: &mut Frame, r: Rect, line: Line) {
    if r.width == 0 || r.height == 0 {
        return;
    }
    f.render_widget(Paragraph::new(line), r);
}

fn put_lines(f: &mut Frame, r: Rect, lines: Vec<Line>) {
    if r.width == 0 || r.height == 0 {
        return;
    }
    f.render_widget(Paragraph::new(lines), r);
}

/// A span, and what clicking it does.
type Item<'a> = (Span<'a>, Option<Hit>);

fn plain(l: Line<'_>) -> Vec<Item<'_>> {
    l.spans.into_iter().map(|s| (s, None)).collect()
}

fn items_width(items: &[Item]) -> u16 {
    items.iter().map(|(s, _)| s.width() as u16).sum()
}

/// Draw a row of spans, recording each clickable one where it lands.
fn put_items(f: &mut Frame, app: &App, r: Rect, items: Vec<Item>) {
    let mut x = r.x;
    let end = r.x + r.width;
    for (s, h) in &items {
        let w = (s.width() as u16).min(end.saturating_sub(x));
        if let Some(h) = h {
            app.hit(Rect::new(x, r.y, w, 1), h.clone());
        }
        x += w;
    }
    put(f, r, Line::from(items.into_iter().map(|(s, _)| s).collect::<Vec<_>>()));
}

fn masthead(f: &mut Frame, app: &App, r: Rect, p: &Palette, crumb: &str, right: Vec<Item>) {
    let left = Line::from(vec![Span::styled("QUIRE", p.brand()), Span::styled(format!("  ·  {}", crumb), p.faint())]);
    put(f, r, left);
    app.hit(Rect::new(r.x, r.y, 5, 1), Hit::Home);
    let rw = items_width(&right);
    if rw + 10 < r.width {
        put_items(f, app, Rect::new(r.x + r.width - rw, r.y, rw, 1), right);
    }
}

/// The key a hint label stands for, when a click can press it.
fn hint_key(k: &str) -> Option<KeyEvent> {
    let mut cs = k.chars();
    match (cs.next()?, cs.next(), cs.next()) {
        _ if k == "esc" => Some(KeyEvent::from(KeyCode::Esc)),
        _ if k == "F1" => Some(KeyEvent::from(KeyCode::F(1))),
        ('↵', None, _) => Some(KeyEvent::from(KeyCode::Enter)),
        ('^', Some(c), None) => Some(KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL)),
        (c, None, _) if !c.is_whitespace() => Some(KeyEvent::from(KeyCode::Char(c))),
        _ => None,
    }
}

fn rule(f: &mut Frame, r: Rect, p: &Palette) {
    put(f, r, Line::from(Span::styled("─".repeat(r.width as usize), p.line())));
}

fn section(label: &str, width: usize, p: &Palette) -> Line<'static> {
    let n = width.saturating_sub(label.width() + 3);
    Line::from(vec![Span::styled(label.to_string(), p.muted()), Span::styled(format!(" {}", "─".repeat(n)), p.line())])
}

fn hints(f: &mut Frame, app: &App, r: Rect, p: &Palette, left: &[(&str, &str)], right: &[(&str, &str)], inbox_count: Option<usize>) {
    let mut l: Vec<Item> = Vec::new();
    for (k, v) in left {
        let h = hint_key(k).map(Hit::Key);
        l.push((Span::styled(k.to_string(), p.key()), h.clone()));
        l.push((Span::styled(format!(" {}", v), p.muted()), h.clone()));
        if *v == "inbox" {
            if let Some(n) = inbox_count {
                if n > 0 {
                    l.push((Span::styled(format!(" {}", n), p.faint()), h));
                }
            }
        }
        l.push((Span::styled("   ", p.muted()), None));
    }
    let mut rt: Vec<Item> = Vec::new();
    for (i, (k, v)) in right.iter().enumerate() {
        if i > 0 {
            rt.push((Span::styled("   ", p.muted()), None));
        }
        let h = hint_key(k).map(Hit::Key);
        rt.push((Span::styled(k.to_string(), p.key()), h.clone()));
        rt.push((Span::styled(format!(" {}", v), p.muted()), h));
    }
    let rw = items_width(&rt);
    let lw = items_width(&l).min(r.width.saturating_sub(rw + 2));
    put_items(f, app, Rect::new(r.x, r.y, lw, 1), l);
    if rw < r.width {
        put_items(f, app, Rect::new(r.x + r.width - rw, r.y, rw, 1), rt);
    }
}

fn two_sided(f: &mut Frame, r: Rect, left: Line, right: Line) {
    let rw = right.width() as u16;
    let lw = r.width.saturating_sub(rw + 2);
    put(f, Rect::new(r.x, r.y, lw, 1), left);
    if rw < r.width {
        put(f, Rect::new(r.x + r.width - rw, r.y, rw, 1), right);
    }
}

fn trunc(s: &str, w: usize) -> String {
    if s.width() <= w {
        return s.to_string();
    }
    let mut out = String::new();
    let mut used = 0;
    for c in s.chars() {
        let cw = c.width().unwrap_or(1);
        if used + cw > w.saturating_sub(1) {
            break;
        }
        out.push(c);
        used += cw;
    }
    out.push('…');
    out
}

fn commas(n: usize) -> String {
    let s = n.to_string();
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

fn short_num(n: usize) -> String {
    if n >= 1000 {
        format!("{:.1}k", n as f64 / 1000.0)
    } else {
        n.to_string()
    }
}

fn goal_bar(n: usize, goal: usize, p: &Palette) -> Vec<Span<'static>> {
    let cells = 10;
    let filled = ((n as f64 / goal.max(1) as f64) * cells as f64).round().min(cells as f64) as usize;
    vec![Span::styled("▰".repeat(filled), p.accent()), Span::styled("▱".repeat(cells - filled), p.line())]
}

fn title_of(e: &Entry) -> (String, bool) {
    if !e.title.is_empty() {
        (e.title.clone(), false)
    } else {
        let fl = e.body.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim().to_string();
        if fl.is_empty() {
            ("untitled".into(), true)
        } else {
            (fl, true)
        }
    }
}

fn entry_row<'a>(e: &Entry, p: &Palette, width: usize, show_date: bool) -> (Line<'a>, Line<'a>) {
    let (t, untitled) = title_of(e);
    let mut left: Vec<Span> = Vec::new();
    left.push(Span::styled(if show_date { format!("{} {}  ", e.date, e.time) } else { format!("{}  ", e.time) }, p.muted()));
    if e.starred {
        left.push(Span::styled("★ ", p.accent()));
    }
    left.push(Span::styled(trunc(&t, width.saturating_sub(40)), if untitled { p.muted_italic() } else { p.ink() }));
    let mut right: Vec<Span> = Vec::new();
    if let Some(tag) = e.tags.first() {
        right.push(Span::styled(format!("{}  ", tag), p.accent()));
    }
    right.push(Span::styled(format!("{} words", e.words), p.muted()));
    (Line::from(left), Line::from(right))
}

// ---------- screens ----------

fn today(f: &mut Frame, r: Rect, app: &App) {
    let p = &app.pal;
    let w = r.width as usize;
    let mut y = r.y;
    let max_y = r.y + r.height;
    // Roomy on a tall terminal, tight on a short one: every section still shows.
    let roomy = r.height >= 24;
    let gap: u16 = if roomy { 2 } else { 1 };
    let otd_rows = if roomy { 3 } else { 2 };
    let words = app.words_today();
    let goal = app.settings.word_goal();
    put(f, Rect::new(r.x, y, r.width, 1), Line::from(vec![Span::styled(format!("  {}", commas(words)), p.bold()), Span::styled(" words today", p.muted())]));
    y += 1;
    let mut bar = vec![Span::styled("  ", p.ink())];
    bar.extend(goal_bar(words, goal, p));
    bar.push(Span::styled(format!("  of {}", goal), p.muted()));
    put(f, Rect::new(r.x, y, r.width, 1), Line::from(bar));
    y += gap;
    let days = stats::days_written(&app.entries);
    let streak = stats::current_streak(&days, &app.today);
    let drafts = app.drafts().len();
    let filed = app.filed();
    let first = filed.iter().map(|e| e.date.as_str()).min().map(|d| format!(" since {}", d.get(..7).unwrap_or(d))).unwrap_or_default();
    put(
        f,
        Rect::new(r.x, y, r.width, 1),
        Line::from(vec![
            Span::styled(format!("  {}", streak), p.bold()),
            Span::styled(" day streak   ·   ".to_string(), p.muted()),
            Span::styled(format!("{}", drafts), p.bold()),
            Span::styled(format!(" draft{} in the inbox   ·   ", if drafts == 1 { "" } else { "s" }), p.muted()),
            Span::styled(commas(filed.len()), p.bold()),
            Span::styled(format!(" entr{}{}", if filed.len() == 1 { "y" } else { "ies" }, first), p.muted()),
        ]),
    );
    y += gap + 1;
    let otd = stats::on_this_day(&app.entries, &app.today);
    if y + 3 < max_y {
        put(f, Rect::new(r.x + 2, y, r.width - 2, 1), section("ON THIS DAY", w - 2, p));
        y += gap;
        if otd.is_empty() {
            put(f, Rect::new(r.x + 2, y, r.width - 2, 1), Line::from(Span::styled("Nothing yet from earlier years.", p.faint())));
            y += 1;
        }
        for e in otd.iter().take(otd_rows) {
            if y >= max_y {
                break;
            }
            let (t, untitled) = title_of(e);
            let left = Line::from(vec![Span::styled(format!("  {}  ", e.date), p.accent()), Span::styled(trunc(&t, w.saturating_sub(30)), if untitled { p.muted_italic() } else { p.ink() })]);
            let mut right: Vec<Span> = Vec::new();
            if let Some(tag) = e.tags.first() {
                right.push(Span::styled(format!("{}  ", tag), p.accent()));
            }
            right.push(Span::styled(format!("{} words", e.words), p.muted()));
            two_sided(f, Rect::new(r.x, y, r.width, 1), left, Line::from(right));
            app.hit(Rect::new(r.x, y, r.width, 1), Hit::Show(e.file.clone(), e.index));
            y += 1;
        }
        y += gap;
    }
    if y + 4 < max_y {
        put(f, Rect::new(r.x + 2, y, r.width - 2, 1), section("A PROMPT", w - 2, p));
        y += gap;
        put(f, Rect::new(r.x + 2, y, r.width - 2, 1), Line::from(Span::styled(trunc(app.current_prompt(), w - 4), p.italic())));
        app.hit(Rect::new(r.x + 2, y, (app.current_prompt().width() as u16).min(r.width - 2), 1), Hit::Prompt);
        y += 1;
        put(f, Rect::new(r.x + 2, y, r.width - 2, 1), Line::from(Span::styled("↵ to start writing from it   ·   p for another", p.faint())));
        app.hit(Rect::new(r.x + 2, y, 26, 1), Hit::Prompt);
        app.hit(Rect::new(r.x + 2 + 33, y, 13, 1), Hit::Key(KeyEvent::from(KeyCode::Char('p'))));
        y += gap + 1;
    }
    if y + 2 < max_y {
        put(f, Rect::new(r.x + 2, y, r.width - 2, 1), section("INBOX", w - 2, p));
        y += gap;
        let ds = app.drafts();
        if ds.is_empty() {
            put(f, Rect::new(r.x + 2, y, r.width - 2, 1), Line::from(Span::styled("Empty. n starts a draft.", p.faint())));
        }
        for e in ds.iter() {
            if y >= max_y {
                break;
            }
            let (l, rt) = entry_row(e, p, w, true);
            let mut l2 = vec![Span::styled("  ", p.ink())];
            l2.extend(l.spans);
            two_sided(f, Rect::new(r.x, y, r.width, 1), Line::from(l2), rt);
            app.hit(Rect::new(r.x, y, r.width, 1), Hit::Edit(e.file.clone(), e.index));
            y += 1;
        }
    }
}

fn inbox(f: &mut Frame, r: Rect, app: &App) {
    let p = &app.pal;
    let ds = app.drafts();
    if ds.is_empty() {
        put(f, Rect::new(r.x + 2, r.y + 1, r.width - 2, 1), Line::from(Span::styled("Inbox is empty — nothing to review.", p.muted())));
        put(f, Rect::new(r.x + 2, r.y + 3, r.width - 2, 1), Line::from(vec![Span::styled("n", p.key()), Span::styled(" starts a draft", p.muted())]));
        return;
    }
    let sel = app.inbox_i.min(ds.len() - 1);
    if r.width >= 80 {
        // The list beside the draft, as Browse puts its entries.
        let lw = (r.width / 3).clamp(28, 40);
        inbox_list(f, Rect::new(r.x, r.y, lw, r.height), app, &ds, sel, false);
        let sep: Vec<Line> = (0..r.height).map(|_| Line::from(Span::styled("│", p.line()))).collect();
        put_lines(f, Rect::new(r.x + lw, r.y, 1, r.height), sep);
        draft_preview(f, Rect::new(r.x + lw + 2, r.y, r.width - lw - 2, r.height), app, ds[sel]);
    } else {
        // Narrow: the list above the draft.
        let rows = (ds.len() as u16).min(if r.height >= 20 { 5 } else { 3 });
        inbox_list(f, Rect::new(r.x, r.y, r.width, rows), app, &ds, sel, true);
        rule(f, Rect::new(r.x, r.y + rows, r.width, 1), p);
        draft_preview(f, Rect::new(r.x, r.y + rows + 1, r.width, r.height.saturating_sub(rows + 1)), app, ds[sel]);
    }
}

/// One row a draft: date and time, a star, the title. `wide` adds its first
/// tag and word count on the right.
fn inbox_list(f: &mut Frame, r: Rect, app: &App, ds: &[&Entry], sel: usize, wide: bool) {
    let p = &app.pal;
    let h = r.height as usize;
    let top = (sel + 1).saturating_sub(h);
    for (k, e) in ds.iter().enumerate().skip(top).take(h) {
        let y = r.y + (k - top) as u16;
        let row = Rect::new(r.x, y, r.width, 1);
        let on = k == sel;
        if on {
            f.render_widget(Block::default().style(p.selected_bg()), row);
        }
        let (t, untitled) = title_of(e);
        let when = format!("{} {}  ", e.date, e.time);
        let mut right: Vec<Span> = Vec::new();
        if wide {
            if let Some(tag) = e.tags.first() {
                right.push(Span::styled(format!("{}  ", tag), p.accent()));
            }
            right.push(Span::styled(format!("{} words", e.words), p.muted()));
        }
        let rw = Line::from(right.clone()).width();
        let room = (r.width as usize).saturating_sub(2 + when.width() + if e.starred { 2 } else { 0 } + if wide { rw + 2 } else { 0 });
        let mut left = vec![Span::styled(if on { "▸ " } else { "  " }, p.accent()), Span::styled(when, p.muted())];
        if e.starred {
            left.push(Span::styled("★ ", p.accent()));
        }
        let title_st = if untitled { p.muted_italic() } else if on { p.bold() } else { p.ink() };
        left.push(Span::styled(trunc(&t, room), title_st));
        let bg = |l: Vec<Span<'static>>| -> Vec<Span<'static>> { if on { l.into_iter().map(|s| { let st = s.style.bg(p.card); s.style(st) }).collect() } else { l } };
        two_sided(f, row, Line::from(bg(left)), Line::from(bg(right)));
        app.hit(row, Hit::Draft(k));
    }
}

fn draft_preview(f: &mut Frame, r: Rect, app: &App, e: &Entry) {
    let p = &app.pal;
    if r.width < 10 || r.height < 6 {
        return;
    }
    app.hit(r, Hit::Preview(e.file.clone(), e.index));
    let w = r.width as usize;
    let mut y = r.y;
    let dest = app.destination_of(e);
    let mut head = vec![Span::styled(format!("  {}  ·  {}", e.date, e.time), p.muted()), Span::styled("   →  ", p.faint())];
    if dest.starts_with("journal/") {
        head.push(Span::styled(dest.clone(), p.faint()));
    } else {
        let tag = dest.trim_end_matches(".md");
        head.push(Span::styled(dest.clone(), p.accent()));
        head.push(Span::styled("  split journal, because of ", p.faint()));
        head.push(Span::styled(format!("@{}", tag), p.accent()));
    }
    put(f, Rect::new(r.x, y, r.width, 1), Line::from(head));
    y += 2;
    if e.title.is_empty() {
        put(f, Rect::new(r.x + 2, y, r.width - 2, 1), Line::from(Span::styled("untitled — the first line will be the title", p.muted_italic())));
    } else {
        let mut t = vec![Span::styled(trunc(&e.title, w - 6), p.bold())];
        if e.starred {
            t.push(Span::styled(" ★", p.accent()));
        }
        put(f, Rect::new(r.x + 2, y, r.width - 2, 1), Line::from(t));
    }
    y += 2;
    let body_h = r.height.saturating_sub((y - r.y) + 2);
    let mut lines: Vec<Line> = Vec::new();
    for line in e.body.split('\n') {
        for seg in wrap_text(line, w.saturating_sub(4)) {
            lines.push(md::style_line(&seg, p, false));
        }
    }
    let shown = lines.len().min(body_h as usize);
    let more = lines.len() > shown;
    put_lines(f, Rect::new(r.x + 2, y, r.width - 2, shown as u16), lines.into_iter().take(shown).collect());
    y = r.y + r.height - 1;
    let mut foot = vec![Span::styled(format!("{} words  ·  {} tag{}", e.words, e.tags.len(), if e.tags.len() == 1 { "" } else { "s" }), p.muted())];
    if !e.tags.is_empty() {
        foot.push(Span::styled("  ·  ", p.muted()));
        foot.push(Span::styled(e.tags.join(" "), p.accent()));
    }
    if more {
        foot.push(Span::styled("  ·  ⋮ more below — e to read it all", p.faint()));
    }
    two_sided(f, Rect::new(r.x + 2, y, r.width - 2, 1), Line::from(foot), Line::from(Span::styled(e.file.clone(), p.faint())));
}

fn picker_line(app: &App) -> Vec<Item<'static>> {
    let p = &app.pal;
    let mut v: Vec<Item> = Vec::new();
    let mark = |pick: Pick, label: String, count: Option<usize>| -> Vec<Item<'static>> {
        let h = Some(Hit::Pick(pick.clone()));
        let mut s = vec![];
        if app.browse.pick == pick {
            s.push((Span::styled("▌", p.accent()), h.clone()));
            s.push((Span::styled(label, p.bold()), h.clone()));
        } else {
            s.push((Span::styled(label, if count.is_some() { p.accent() } else { p.faint() }), h.clone()));
        }
        if let Some(c) = count {
            s.push((Span::styled(format!(" {}", c), p.faint()), h));
        }
        s.push((Span::styled("   ", p.muted()), None));
        s
    };
    v.extend(mark(Pick::Main, "Main".into(), None));
    for t in app.split_names() {
        let n = app.entries.iter().filter(|e| e.split.as_deref() == Some(t.as_str())).count();
        v.extend(mark(Pick::Split(t.clone()), format!("@{}", t), Some(n)));
    }
    v.extend(mark(Pick::All, "all".into(), None));
    v
}

fn column<'a>(items: &[(String, usize)], sel: usize, active: bool, label: impl Fn(&str) -> String, width: usize, p: &Palette) -> Vec<Line<'a>> {
    let mut out = Vec::new();
    for (i, (k, n)) in items.iter().enumerate() {
        let is = i == sel;
        let count = format!("{}  ", n);
        let name = trunc(&label(k), width.saturating_sub(count.len() + 3));
        let padn = width.saturating_sub(2 + name.width() + count.len());
        let mut s: Vec<Span> = Vec::new();
        if is {
            s.push(Span::styled("▌ ", p.accent().bg(p.card)));
            s.push(Span::styled(name, if active { p.selected() } else { Style::default().fg(p.fg).bg(p.card) }));
            s.push(Span::styled(" ".repeat(padn), p.selected_bg()));
            s.push(Span::styled(count, p.muted().bg(p.card)));
        } else {
            s.push(Span::styled("  ", p.ink()));
            s.push(Span::styled(name, p.ink()));
            s.push(Span::styled(" ".repeat(padn), p.ink()));
            s.push(Span::styled(count, p.muted()));
        }
        out.push(Line::from(s));
    }
    out
}

fn browse(f: &mut Frame, r: Rect, app: &App) {
    let p = &app.pal;
    let sel = app.browse_sel();
    let years = app.browse_years();
    let months = sel.year.as_deref().map(|y| app.browse_months(y)).unwrap_or_default();
    let days = match (&sel.year, &sel.month) {
        (Some(y), Some(m)) => app.browse_days(y, m),
        _ => vec![],
    };
    if years.is_empty() {
        put(f, Rect::new(r.x + 2, r.y + 1, r.width - 2, 1), Line::from(Span::styled(if app.browse.filtering { "Nothing matches that filter." } else { "No entries here yet." }, p.muted())));
        return;
    }
    let wide = r.width >= 96;
    // Wide enough for the longest label and the biggest count, so neither is cut.
    let colw = |items: &[(String, usize)], label: u16| -> u16 {
        let digits = items.iter().map(|(_, n)| n.to_string().len()).max().unwrap_or(1) as u16;
        label + digits + 6
    };
    let (wy, wm, wd) = (colw(&years, 4), colw(&months, 9), colw(&days, 6));
    let sep = 3u16;
    let mut x = r.x;
    let h = r.height;
    let draw_col = |f: &mut Frame, col: usize, x: u16, w: u16, title: &str, lines: Vec<Line>, scroll_to: usize| {
        put(f, Rect::new(x, r.y, w, 1), Line::from(Span::styled(title.to_string(), p.muted())));
        app.hit(Rect::new(x, r.y, w, h), Hit::Column(col));
        let avail = h.saturating_sub(2) as usize;
        let start = scroll_to.saturating_sub(avail.saturating_sub(1));
        let shown: Vec<Line> = lines.into_iter().skip(start).take(avail).collect();
        for k in 0..shown.len() {
            app.hit(Rect::new(x, r.y + 2 + k as u16, w, 1), Hit::Item(col, start + k));
        }
        put_lines(f, Rect::new(x, r.y + 2, w, avail as u16), shown);
    };
    let vline = |f: &mut Frame, x: u16| {
        for yy in r.y + 2..r.y + h {
            put(f, Rect::new(x + 1, yy, 1, 1), Line::from(Span::styled("│", p.line())));
        }
    };
    draw_col(f, 0, x, wy, "YEAR", column(&years, app.browse.yi, app.browse.col == 0, |k| k.to_string(), wy as usize, p), app.browse.yi);
    x += wy;
    vline(f, x);
    x += sep;
    draw_col(f, 1, x, wm, "MONTH", column(&months, app.browse.mi, app.browse.col == 1, |k| stats::month_name(k.parse().unwrap_or(1)).to_string(), wm as usize, p), app.browse.mi);
    x += wm;
    vline(f, x);
    x += sep;
    draw_col(f, 2, x, wd, "DAY", column(&days, app.browse.di, app.browse.col == 2, |k| stats::parse_date(k).map(|d| d.format("%a %d").to_string()).unwrap_or_else(|| k.to_string()), wd as usize, p), app.browse.di);
    x += wd;
    if !wide {
        return;
    }
    vline(f, x);
    x += sep;
    let pw = (r.x + r.width).saturating_sub(x);
    let Some(date) = &sel.date else { return };
    let es = app.browse_day_entries(date);
    two_sided(f, Rect::new(x, r.y, pw, 1), Line::from(Span::styled(date.to_string(), p.muted())), Line::from(Span::styled(es.first().map(|e| e.file.clone()).unwrap_or_default(), p.faint())));
    let mut lines: Vec<Line> = Vec::new();
    // Which entry each line belongs to, for clicks.
    let mut owner: Vec<usize> = Vec::new();
    let mut sel_line = 0usize;
    for (i, e) in es.iter().enumerate() {
        let active = i == app.browse.ei;
        if active {
            sel_line = lines.len();
        }
        if i > 0 {
            lines.push(Line::from(Span::styled(format!("       {}", "─".repeat((pw as usize).saturating_sub(9))), p.line())));
        }
        let (t, untitled) = title_of(e);
        let marker = if active && app.browse.col == 3 { Span::styled("▌", p.accent()) } else { Span::styled(" ", p.ink()) };
        let mut head = vec![marker, Span::styled(format!("{}  ", e.time), p.accent())];
        head.push(Span::styled(trunc(&t, (pw as usize).saturating_sub(12)), if untitled { p.muted_italic() } else { p.bold() }));
        if e.starred {
            head.push(Span::styled(" ★", p.accent()));
        }
        if e.source == "inbox" {
            head.push(Span::styled("  draft", p.faint()));
        }
        lines.push(Line::from(head));
        lines.push(Line::from(""));
        for line in e.body.split('\n') {
            for seg in wrap_text(line, (pw as usize).saturating_sub(8)) {
                let mut l = md::style_line(&seg, p, false);
                l.spans.insert(0, Span::styled("       ", p.ink()));
                lines.push(l);
            }
        }
        lines.push(Line::from(""));
        let mut meta = vec![Span::styled(format!("       {} words", e.words), p.muted())];
        if !e.tags.is_empty() {
            meta.push(Span::styled("  ·  ", p.muted()));
            meta.push(Span::styled(e.tags.join(" "), p.accent()));
        }
        lines.push(Line::from(meta));
        owner.resize(lines.len(), i);
    }
    let avail = h.saturating_sub(2) as usize;
    let start = if sel_line + 3 > avail { sel_line.saturating_sub(2) } else { 0 };
    app.hit(Rect::new(x, r.y, pw, h), Hit::Column(3));
    for (k, i) in owner.iter().skip(start).take(avail).enumerate() {
        app.hit(Rect::new(x, r.y + 2 + k as u16, pw, 1), Hit::Item(3, *i));
    }
    let shown: Vec<Line> = lines.into_iter().skip(start).take(avail).collect();
    put_lines(f, Rect::new(x, r.y + 2, pw, avail as u16), shown);
}

/// Soft-wrap plain text at spaces to `width` cells.
fn wrap_text(line: &str, width: usize) -> Vec<String> {
    let width = width.max(8);
    if line.is_empty() {
        return vec![String::new()];
    }
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut cur_w = 0;
    for word in line.split(' ') {
        let ww = word.width();
        if cur_w > 0 && cur_w + 1 + ww > width {
            out.push(std::mem::take(&mut cur));
            cur_w = 0;
        }
        if cur_w > 0 {
            cur.push(' ');
            cur_w += 1;
        }
        if ww > width {
            for c in word.chars() {
                let cw = c.width().unwrap_or(1);
                if cur_w + cw > width {
                    out.push(std::mem::take(&mut cur));
                    cur_w = 0;
                }
                cur.push(c);
                cur_w += cw;
            }
        } else {
            cur.push_str(word);
            cur_w += ww;
        }
    }
    out.push(cur);
    out
}

fn write(f: &mut Frame, r: Rect, app: &mut App) {
    let p = app.pal.clone();
    let width = app.editor_width();
    let suggestions = app.tag_suggestions();
    let tag_pick = app.tag_pick;
    let focus = app.focus;
    let words_today = app.words_today();
    let goal = app.settings.word_goal();
    let timer = app.timer_left();
    let mut hits: Vec<(Rect, Hit)> = vec![(Rect::new(r.x, r.y, r.width, r.height.saturating_sub(2)), Hit::TextEnd)];
    let Some(d) = app.draft.as_mut() else { return };
    let left = r.x + (r.width.saturating_sub(width as u16)) / 2;
    let text_h = r.height.saturating_sub(2) as usize;
    let rows = d.ed.layout(width);
    d.ed.ensure_visible(&rows, text_h);
    let (pa, pb) = d.ed.paragraph();
    let caret_vi = d.ed.visual_index(&rows);
    let mut caret_pos: Option<(u16, u16)> = None;
    let mut line_after_title: Option<u16> = None;
    for (y, (vi, vr)) in (r.y..).zip(rows.iter().enumerate().skip(d.ed.scroll).take(text_h)) {
        let line = &d.ed.lines[vr.row];
        let chars: Vec<char> = line.chars().collect();
        let dim = focus && vr.row != 0 && !(vr.row >= pa && vr.row <= pb && pa > 0);
        let styled: Vec<(char, Style)> = if vr.row == 0 {
            chars.iter().map(|c| (*c, if dim { p.dimmed() } else { p.bold() })).collect()
        } else {
            md::style_chars(line, &p, dim)
        };
        let seg: Vec<(char, Style)> = styled.into_iter().skip(vr.start).take(vr.end - vr.start).collect();
        let mut l = md::spans_of(&seg);
        if vr.row == 0 && chars.is_empty() && caret_vi != Some(vi) {
            l = Line::from(Span::styled("Title — or leave it, and the first line will do", p.faint()));
        }
        put(f, Rect::new(left, y, width as u16, 1), l);
        let last = rows.get(vi + 1).is_none_or(|n| n.row != vr.row);
        hits.push((Rect::new(r.x, y, r.width, 1), Hit::Text(*vr, left, last)));
        if Some(vi) == caret_vi {
            let x = d.ed.visual_x(vr) as u16;
            caret_pos = Some((left + x.min(width as u16 - 1), y));
        }
        if vr.row == 0 && vr.end == chars.len() {
            line_after_title = Some(y + 1);
        }
    }
    if let Some(ly) = line_after_title {
        if ly < r.y + text_h as u16 {
            put(f, Rect::new(left, ly, 2, 1), Line::from(Span::styled("──", p.accent())));
        }
    }
    if let Some((cx, cy)) = caret_pos {
        f.set_cursor_position((cx, cy));
        if !suggestions.is_empty() {
            let w = suggestions.iter().map(|s| s.width()).max().unwrap_or(4) as u16 + 6;
            let hgt = suggestions.len() as u16;
            let px = cx.min(r.x + r.width - w);
            let py = if cy + 1 + hgt <= r.y + r.height { cy + 1 } else { cy.saturating_sub(hgt) };
            let area = Rect::new(px, py, w, hgt);
            f.render_widget(Clear, area);
            let lines: Vec<Line> = suggestions
                .iter()
                .enumerate()
                .map(|(i, t)| {
                    let st = if i == tag_pick { Style::default().fg(p.on_accent).bg(p.accent) } else { Style::default().fg(p.fg).bg(p.card) };
                    Line::from(Span::styled(format!(" {:<w$} ", t, w = (w - 2) as usize), st))
                })
                .collect();
            put_lines(f, area, lines);
            for i in 0..hgt {
                hits.push((Rect::new(px, py + i, w, 1), Hit::Suggestion(i as usize)));
            }
        }
    }
    // status line
    let sy = r.y + r.height - 1;
    let mut st: Vec<Span> = vec![Span::styled(commas(words_today), p.bold()), Span::styled(" words   ", p.muted())];
    st.extend(goal_bar(words_today, goal, &p));
    st.push(Span::styled(format!("  {}", goal), p.muted()));
    if let Some((t, paused)) = timer {
        let secs = t.as_secs();
        st.push(Span::styled("   ·   ", p.muted()));
        st.push(Span::styled(if paused { "‖ " } else { "◔ " }, p.accent()));
        st.push(Span::styled(format!("{:02}:{:02} {}", secs / 60, secs % 60, if paused { "paused" } else { "left" }), p.muted()));
    }
    let mut right: Vec<Span> = Vec::new();
    if focus {
        right.push(Span::styled("focus on  ·  ", p.faint()));
    }
    if d.ed.dirty {
        right.push(Span::styled("unsaved", p.faint()));
    } else if let Some(t) = &d.saved_at {
        right.push(Span::styled(format!("saved {}", t), p.faint()));
    } else if d.ref_.is_some() {
        right.push(Span::styled(d.ref_.as_ref().map(|r| r.0.clone()).unwrap_or_default(), p.faint()));
    } else {
        right.push(Span::styled("saves to the inbox", p.faint()));
    }
    two_sided(f, Rect::new(r.x, sy, r.width, 1), Line::from(st), Line::from(right));
    put(f, Rect::new(r.x, sy + 1, r.width, 1), Line::from(Span::styled("─".repeat(r.width as usize), p.line())));
    for (rect, h) in hits {
        app.hit(rect, h);
    }
}

fn settings(f: &mut Frame, r: Rect, app: &App) {
    let p = app.pal.clone();
    // One line a row, a heading and a gap before each group. Scroll so the
    // chosen row stays in view.
    let mut lines: Vec<(Option<usize>, &str)> = Vec::new();
    for i in 0..App::SETTING_ROWS {
        if let Some((_, head)) = App::SETTING_GROUPS.iter().find(|(at, _)| *at == i) {
            if i > 0 {
                lines.push((None, ""));
            }
            lines.push((None, head));
        }
        lines.push((Some(i), ""));
    }
    let h = r.height as usize;
    let sel_line = lines.iter().position(|(i, _)| *i == Some(app.settings_i)).unwrap_or(0);
    let top = (sel_line + 1).saturating_sub(h);
    for (k, (row, head)) in lines.iter().skip(top).take(h).enumerate() {
        let y = r.y + k as u16;
        let rect = Rect::new(r.x, y, r.width, 1);
        let Some(i) = row else {
            if !head.is_empty() {
                put(f, rect, section(head, r.width as usize, &p));
            }
            continue;
        };
        let i = *i;
        let (label, value) = app.setting_value(i);
        let sel = i == app.settings_i;
        let shown = if App::setting_is_action(i) { value } else { format!("‹ {} ›", value) };
        let room = (r.width as usize).saturating_sub(22);
        let items: Vec<Item> = vec![
            (Span::styled(if sel { "▸ " } else { "  " }, p.accent()), Some(Hit::Setting(i))),
            (Span::styled(format!("{:<20}", label), if sel { p.bold() } else { p.ink() }), Some(Hit::Setting(i))),
            (Span::styled(trunc(&shown, room), if sel { p.accent() } else { p.muted() }), Some(Hit::Setting(i))),
        ];
        put_items(f, app, rect, items);
    }
}

fn lookback(f: &mut Frame, r: Rect, app: &App) {
    let p = &app.pal;
    let ys = stats::year_stats(&app.entries, app.year);
    let days = stats::days_written(&app.entries);
    let streak = stats::current_streak(&days, &app.today);
    let (longest, span) = stats::longest_streak(&days);
    let all_filed = app.filed();
    let total_words: usize = all_filed.iter().map(|e| e.words).sum();
    let total_days = all_filed.iter().map(|e| e.date.as_str()).collect::<std::collections::BTreeSet<_>>().len();
    let w = r.width as usize;
    let mut y = r.y;
    let span_txt = span.map(|(a, b)| format!("       longest {}, {} – {}", longest, a, b)).unwrap_or_default();
    let left = Line::from(vec![Span::styled(format!("  {}", streak), p.bold()), Span::styled(" day streak", p.muted()), Span::styled(span_txt, p.faint())]);
    let right = Line::from(vec![Span::styled(commas(total_words), p.bold()), Span::styled(" words", p.muted()), Span::styled(format!("   in {} entries, {} days", commas(all_filed.len()), commas(total_days)), p.faint())]);
    two_sided(f, Rect::new(r.x, y, r.width, 1), left, right);
    y += 2;
    // The year as a heat strip: one column a week, Mon to Sun.
    put(f, Rect::new(r.x + 2, y, r.width - 2, 1), section(&format!("THE YEAR  {}", app.year), w - 2, p));
    y += 2;
    let jan1 = chrono::NaiveDate::from_ymd_opt(app.year, 1, 1).unwrap();
    let off = jan1.weekday().num_days_from_monday() as i64;
    let weeks = 53usize;
    let strip_w = weeks.min(w.saturating_sub(8));
    for (wd, name) in WEEKDAYS.iter().enumerate() {
        let mut spans: Vec<Span> = vec![Span::styled(format!("  {} ", name), p.faint())];
        for wk in 0..strip_w {
            let day_n = wk as i64 * 7 + wd as i64 - off;
            let date = jan1 + chrono::Duration::days(day_n);
            if date.year() != app.year || date.format("%Y-%m-%d").to_string() > app.today {
                spans.push(Span::styled(" ", p.ink()));
                continue;
            }
            let k = date.format("%Y-%m-%d").to_string();
            let words = ys.day_words.get(&k).copied().unwrap_or(0);
            let lv = ys.level(words) as usize;
            spans.push(Span::styled("▮", Style::default().fg(p.heat[lv])));
        }
        put(f, Rect::new(r.x, y, r.width, 1), Line::from(spans));
        y += 1;
    }
    let mut months = String::from("      ");
    let mut cursor = 0usize;
    for m in 1..=12u32 {
        let first = chrono::NaiveDate::from_ymd_opt(app.year, m, 1).unwrap();
        let col = ((first - jan1).num_days() + off) as usize / 7;
        if col >= strip_w {
            break;
        }
        while cursor < col {
            months.push(' ');
            cursor += 1;
        }
        months.push_str(MONTHS_SHORT[(m - 1) as usize]);
        cursor += 3;
    }
    put(f, Rect::new(r.x, y, r.width, 1), Line::from(Span::styled(months, p.faint())));
    y += 2;
    use chrono::Datelike;
    let two_col = w >= 96;
    let col_w = if two_col { (w - 4) / 2 } else { w - 2 };
    let x1 = r.x + 2;
    let x2 = r.x + 2 + col_w as u16 + 4;
    let max_y = r.y + r.height;
    // words a month
    let mut yy = y;
    if yy < max_y {
        put(f, Rect::new(x1, yy, col_w as u16, 1), section("WORDS A MONTH", col_w, p));
        yy += 2;
        let mmax = ys.month_words.iter().copied().max().unwrap_or(0).max(1);
        let bar_w = col_w.saturating_sub(16);
        let this_month = if app.year.to_string() == app.today[..4] { app.today[5..7].parse::<usize>().unwrap_or(0) } else { 0 };
        for (i, mw) in ys.month_words.iter().enumerate() {
            if yy >= max_y {
                break;
            }
            let n = ((*mw as f64 / mmax as f64) * bar_w as f64).round() as usize;
            let is_now = this_month == i + 1;
            let mut s = vec![Span::styled(format!("{}  ", MONTHS_SHORT[i]), p.faint()), Span::styled("▇".repeat(n), Style::default().fg(if is_now { p.accent } else { p.bar }))];
            if *mw > 0 {
                s.push(Span::styled(format!("  {}", short_num(*mw)), p.muted()));
            }
            if is_now {
                s.push(Span::styled(" so far", p.faint()));
            }
            put(f, Rect::new(x1, yy, col_w as u16, 1), Line::from(s));
            yy += 1;
        }
    }
    // tags and when
    let mut y2 = if two_col { y } else { yy + 1 };
    let xx = if two_col { x2 } else { x1 };
    if y2 < max_y {
        put(f, Rect::new(xx, y2, col_w as u16, 1), section("TAGS", col_w, p));
        y2 += 2;
        if ys.tags.is_empty() {
            put(f, Rect::new(xx, y2, col_w as u16, 1), Line::from(Span::styled("None this year.", p.faint())));
            y2 += 1;
        }
        for (t, n) in ys.tags.iter().take(6) {
            if y2 >= max_y {
                break;
            }
            two_sided(f, Rect::new(xx, y2, col_w as u16, 1), Line::from(Span::styled(format!("  {}", t), p.accent())), Line::from(Span::styled(format!("{}  ", n), p.muted())));
            y2 += 1;
        }
        y2 += 1;
    }
    if y2 + 2 < max_y {
        put(f, Rect::new(xx, y2, col_w as u16, 1), section("WHEN", col_w, p));
        y2 += 2;
        let total: usize = ys.hour_entries.iter().sum();
        let mornings: usize = ys.hour_entries[5..12].iter().sum();
        let pct = (mornings * 100).checked_div(total).unwrap_or(0);
        let best_wd = ys.weekday_entries.iter().enumerate().max_by_key(|(_, n)| **n).map(|(i, n)| (i, *n)).unwrap_or((0, 0));
        let bar = (pct as f64 / 100.0 * 12.0).round() as usize;
        let mut s = vec![Span::styled("  mornings ", p.faint()), Span::styled("▇".repeat(bar), p.accent()), Span::styled(format!(" {}%", pct), p.muted())];
        if best_wd.1 > 0 {
            s.push(Span::styled(format!("   {}s most", ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][best_wd.0]), p.faint()));
        }
        put(f, Rect::new(xx, y2, col_w as u16, 1), Line::from(s));
        y2 += 1;
        if y2 < max_y {
            put(f, Rect::new(xx, y2, col_w as u16, 1), Line::from(vec![Span::styled(format!("  {} entries · {} days · {} starred", commas(ys.entries), ys.days, ys.starred), p.muted())]));
        }
    }
}

fn search(f: &mut Frame, r: Rect, app: &App) {
    let p = &app.pal;
    let w = r.width as usize;
    put(f, Rect::new(r.x, r.y, r.width, 1), Line::from(vec![Span::styled("  / ", p.key()), Span::styled(app.query.clone(), p.ink()), Span::styled("▏", p.accent())]));
    put(f, Rect::new(r.x, r.y + 1, r.width, 1), Line::from(Span::styled("    words · \"exact phrase\" · @tag · before:2026-03 · after:2025 · has:image · is:starred", p.faint())));
    let res = app.results();
    let avail = (r.y + r.height).saturating_sub(r.y + 3) as usize;
    let start = app.search_i.saturating_sub(avail.saturating_sub(1));
    for (y, (i, e)) in (r.y + 3..).zip(res.iter().enumerate().skip(start).take(avail)) {
        let (l, rt) = entry_row(e, p, w, true);
        let mut l2 = vec![if i == app.search_i { Span::styled("▌ ", p.accent()) } else { Span::styled("  ", p.ink()) }];
        l2.extend(l.spans);
        let mut line = Line::from(l2);
        if i == app.search_i {
            line = line.style(p.selected_bg());
        }
        two_sided(f, Rect::new(r.x, y, r.width, 1), line, rt);
        app.hit(Rect::new(r.x, y, r.width, 1), Hit::Result(i));
    }
    if res.is_empty() && !app.query.trim().is_empty() {
        put(f, Rect::new(r.x + 2, r.y + 3, r.width - 2, 1), Line::from(Span::styled("Nothing found.", p.muted())));
    }
}

fn help_overlay(f: &mut Frame, area: Rect, app: &App) {
    let p = &app.pal;
    let rows: Vec<(&str, &str)> = match app.screen {
        Screen::Today => vec![("n", "new draft"), ("↵", "write from the prompt"), ("p", "another prompt"), ("i", "inbox"), ("j", "journal"), ("l", "look back"), ("/", "search"), ("r", "a random entry"), (",", "settings"), ("q", "quit")],
        Screen::Inbox => vec![("↑ ↓", "move between drafts"), ("f", "file the draft"), ("e  ↵", "edit it"), ("*", "star"), ("t", "change its date and time"), ("d", "delete"), ("n", "new draft"), ("esc", "back")],
        Screen::Browse => vec![("← →", "year · month · day · entries"), ("↑ ↓", "move"), ("↵", "open (edit) the entry"), ("/", "filter the column"), ("s", "main · split journals · all"), ("u", "return to the inbox"), ("*", "star"), ("t", "date and time"), ("d", "delete"), ("r", "random"), ("esc", "back")],
        Screen::Write => vec![("^j", "file to its day (or split journal)"), ("^s", "save now (it autosaves)"), ("^t", "date and time"), ("^f", "focus: dim all but this paragraph"), ("^p", "insert a prompt"), ("^o", "timer: start · pause · resume"), ("alt-o", "reset the timer"), ("^b ^i ^g", "bold · italic · code on the word"), ("@", "tag autocomplete, ↹ or ↵ accepts"), ("↹", "indent a list item"), ("↵ ↵", "an empty item ends the list"), ("^v", "paste; a clipboard image is attached"), ("drop", "a photo or video on the window attaches it"), ("^d", "discard the draft"), ("esc", "back (saved)")],
        Screen::LookBack => vec![("← →", "earlier · later year"), ("esc", "back")],
        Screen::Settings => vec![("↑ ↓", "choose a setting"), ("← →", "change it"), ("↵", "next value / toggle"), ("esc", "back")],
        Screen::Search => vec![("type", "to search"), ("↑ ↓", "results"), ("↵", "open"), ("esc", "clear, then back")],
    };
    let mut rows = rows;
    rows.push(("F2", if app.mouse { "mouse off (lets the terminal select)" } else { "mouse on: click, scroll" }));
    let w = 56u16.min(area.width - 4);
    let h = rows.len() as u16 + 4;
    let x = (area.width - w) / 2;
    let y = (area.height.saturating_sub(h)) / 2;
    let r = Rect::new(x, y, w, h);
    f.render_widget(Clear, r);
    f.render_widget(Block::default().style(Style::default().bg(p.card)), r);
    let mut lines = vec![Line::from(Span::styled(format!("  KEYS  ·  {}", match app.screen {
        Screen::Today => "today",
        Screen::Inbox => "inbox",
        Screen::Browse => "journal",
        Screen::Write => "writing",
        Screen::LookBack => "look back",
        Screen::Search => "search",
        Screen::Settings => "settings",
    }), p.muted().bg(p.card))), Line::from("")];
    for (k, v) in rows {
        lines.push(Line::from(vec![Span::styled(format!("  {:<9}", k), p.key().bg(p.card)), Span::styled(v.to_string(), Style::default().fg(p.fg).bg(p.card))]));
    }
    lines.push(Line::from(Span::styled("  any key closes", p.faint().bg(p.card))));
    put_lines(f, r, lines);
}
