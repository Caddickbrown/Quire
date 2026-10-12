//! Quire's themes on a terminal: the tokens from `themes.json` as ratatui
//! colours, 24-bit where the terminal says it can, else the nearest of the
//! 256.

use quire_core::themes::{mix, rgb, Theme};
use ratatui::style::{Color, Modifier, Style};

#[derive(Clone, Debug)]
pub struct Palette {
    pub id: String,
    pub name: String,
    pub dark: bool,
    pub bg: Color,
    pub fg: Color,
    pub muted: Color,
    pub faint: Color,
    pub line: Color,
    pub card: Color,
    pub accent: Color,
    pub on_accent: Color,
    /// Text that is dimmed out of focus.
    pub dim: Color,
    /// The heat strip's five levels.
    pub heat: [Color; 5],
    /// Bars that are not the highlighted one.
    pub bar: Color,
}

impl Palette {
    pub fn from_theme(t: &Theme, truecolor: bool) -> Palette {
        let c = |hex: &str| color(rgb(hex).unwrap_or((128, 128, 128)), truecolor);
        let page = rgb(&t.page).unwrap_or((0, 0, 0));
        let ink = rgb(&t.ink).unwrap_or((255, 255, 255));
        let card = rgb(&t.card).unwrap_or(page);
        let accent = rgb(&t.accent).unwrap_or(ink);
        let line = rgb(&t.line).unwrap_or(card);
        Palette {
            id: t.id.clone(),
            name: t.name.clone(),
            dark: t.dark,
            bg: c(&t.page),
            fg: c(&t.ink),
            muted: c(&t.muted),
            faint: c(&t.faint),
            line: c(&t.line),
            card: c(&t.card),
            accent: c(&t.accent),
            on_accent: c(&t.on_accent),
            dim: color(mix(page, ink, 0.38), truecolor),
            heat: [
                color(mix(card, line, 0.6), truecolor),
                color(mix(card, accent, 0.28), truecolor),
                color(mix(card, accent, 0.5), truecolor),
                color(mix(card, accent, 0.74), truecolor),
                color(accent, truecolor),
            ],
            bar: color(mix(card, accent, 0.55), truecolor),
        }
    }

    pub fn base(&self) -> Style {
        Style::default().fg(self.fg).bg(self.bg)
    }
    pub fn ink(&self) -> Style {
        Style::default().fg(self.fg)
    }
    pub fn bold(&self) -> Style {
        Style::default().fg(self.fg).add_modifier(Modifier::BOLD)
    }
    pub fn italic(&self) -> Style {
        Style::default().fg(self.fg).add_modifier(Modifier::ITALIC)
    }
    pub fn muted(&self) -> Style {
        Style::default().fg(self.muted)
    }
    pub fn muted_italic(&self) -> Style {
        Style::default().fg(self.muted).add_modifier(Modifier::ITALIC)
    }
    pub fn faint(&self) -> Style {
        Style::default().fg(self.faint)
    }
    pub fn line(&self) -> Style {
        Style::default().fg(self.line)
    }
    pub fn accent(&self) -> Style {
        Style::default().fg(self.accent)
    }
    pub fn key(&self) -> Style {
        Style::default().fg(self.accent).add_modifier(Modifier::BOLD)
    }
    pub fn brand(&self) -> Style {
        Style::default().fg(self.accent).add_modifier(Modifier::BOLD)
    }
    pub fn selected(&self) -> Style {
        Style::default().fg(self.fg).bg(self.card).add_modifier(Modifier::BOLD)
    }
    pub fn selected_bg(&self) -> Style {
        Style::default().bg(self.card)
    }
    pub fn caret(&self) -> Style {
        Style::default().fg(self.on_accent).bg(self.accent)
    }
    pub fn dimmed(&self) -> Style {
        Style::default().fg(self.dim)
    }
    pub fn code(&self) -> Style {
        Style::default().fg(self.fg).bg(self.card)
    }
}

/// Does this terminal take 24-bit colour?
pub fn truecolor() -> bool {
    let ct = std::env::var("COLORTERM").unwrap_or_default().to_lowercase();
    if ct.contains("truecolor") || ct.contains("24bit") {
        return true;
    }
    let tp = std::env::var("TERM_PROGRAM").unwrap_or_default().to_lowercase();
    ["iterm", "wezterm", "ghostty", "kitty", "vscode", "hyper", "alacritty", "rio"].iter().any(|p| tp.contains(p))
        || std::env::var("KITTY_WINDOW_ID").is_ok()
        || std::env::var("WT_SESSION").is_ok()
}

fn color(c: (u8, u8, u8), truecolor: bool) -> Color {
    if truecolor {
        Color::Rgb(c.0, c.1, c.2)
    } else {
        Color::Indexed(nearest_256(c))
    }
}

/// The closest xterm-256 index: the 6×6×6 cube or the 24-step grey ramp,
/// whichever is nearer.
pub fn nearest_256((r, g, b): (u8, u8, u8)) -> u8 {
    let steps = [0u8, 95, 135, 175, 215, 255];
    let near = |v: u8| steps.iter().enumerate().min_by_key(|(_, s)| (**s as i32 - v as i32).abs()).map(|(i, _)| i).unwrap_or(0);
    let (ri, gi, bi) = (near(r), near(g), near(b));
    let cube = (16 + 36 * ri + 6 * gi + bi) as u8;
    let (cr, cg, cb) = (steps[ri] as i32, steps[gi] as i32, steps[bi] as i32);
    let d_cube = (cr - r as i32).pow(2) + (cg - g as i32).pow(2) + (cb - b as i32).pow(2);
    let avg = (r as i32 + g as i32 + b as i32) / 3;
    let gi2 = ((avg - 8).max(0) / 10).min(23);
    let gv = 8 + 10 * gi2;
    let d_grey = 3 * (gv - avg).pow(2) + ((r as i32 - avg).pow(2) + (g as i32 - avg).pow(2) + (b as i32 - avg).pow(2));
    if d_grey < d_cube {
        (232 + gi2) as u8
    } else {
        cube
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nearest_colours() {
        assert_eq!(nearest_256((0, 0, 0)), 16);
        assert_eq!(nearest_256((255, 255, 255)), 231);
        assert_eq!(nearest_256((128, 128, 128)), 244);
        assert_eq!(nearest_256((255, 0, 0)), 196);
    }
}
