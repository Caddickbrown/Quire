//! The looks, read from `themes.json` at the repository root (compiled in).
//! Every shell draws from the same tokens; the terminal uses the subset it
//! can show.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Theme {
    pub id: String,
    pub name: String,
    pub dark: bool,
    pub writing_font: String,
    pub page: String,
    pub ground: String,
    pub chrome: String,
    pub card: String,
    pub ink: String,
    pub muted: String,
    pub faint: String,
    pub line: String,
    pub line2: String,
    pub accent: String,
    pub accent_soft: String,
    pub accent_ink: String,
    pub on_accent: String,
    pub head_weight: u32,
    pub rule_h: u32,
}

#[derive(Deserialize)]
struct File {
    themes: Vec<Theme>,
}

const SOURCE: &str = include_str!("../../themes.json");

/// Every theme, in the order the pickers show them.
pub fn themes() -> Vec<Theme> {
    serde_json::from_str::<File>(SOURCE).map(|f| f.themes).unwrap_or_default()
}

/// A theme by id, else the first (Almanac).
pub fn theme(id: &str) -> Theme {
    let all = themes();
    all.iter().find(|t| t.id == id).cloned().unwrap_or_else(|| all[0].clone())
}

/// The dark partner a light theme switches to when the system goes dark.
pub fn dark_partner(id: &str) -> &'static str {
    match id {
        "marathon-day" => "marathon",
        _ => "cinema",
    }
}

/// `#RRGGBB` → (r, g, b).
pub fn rgb(hex: &str) -> Option<(u8, u8, u8)> {
    let h = hex.trim().trim_start_matches('#');
    if h.len() != 6 {
        return None;
    }
    let p = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).ok();
    Some((p(0)?, p(2)?, p(4)?))
}

/// Linear blend of two colours, `t` from `a` (0) to `b` (1).
pub fn mix(a: (u8, u8, u8), b: (u8, u8, u8), t: f32) -> (u8, u8, u8) {
    let t = t.clamp(0.0, 1.0);
    let f = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t).round() as u8;
    (f(a.0, b.0), f(a.1, b.1), f(a.2, b.2))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_parses_and_has_the_seven() {
        let t = themes();
        let ids: Vec<&str> = t.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(ids, vec!["almanac", "broadsheet", "linen", "cinema", "night", "marathon", "marathon-day"]);
        for th in &t {
            for c in [&th.page, &th.ink, &th.muted, &th.faint, &th.line, &th.card, &th.accent] {
                assert!(rgb(c).is_some(), "{} has a bad colour {}", th.id, c);
            }
        }
        assert_eq!(theme("nope").id, "almanac");
        assert!(theme("cinema").dark);
        assert_eq!(mix((0, 0, 0), (255, 255, 255), 0.5), (128, 128, 128));
        assert_eq!(dark_partner("marathon-day"), "marathon");
    }
}
