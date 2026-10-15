//! What a paste can bring into the composer: a clipboard image (read
//! directly, since a terminal only ever passes text), or media files dropped
//! onto the window, which terminals paste as their paths.

use quire_core::media_kind;
use std::path::PathBuf;

/// What the system clipboard holds, as far as the composer cares.
pub enum Clip {
    /// Encoded bytes and their extension (jpg for opaque images, else png).
    Image(Vec<u8>, &'static str),
    Text(String),
    Empty,
}

/// Read the clipboard. Err when there is none to read (over SSH, say).
pub fn read_clipboard() -> Result<Clip, String> {
    let mut c = arboard::Clipboard::new().map_err(|_| "No clipboard here — drop the file onto the window, or paste its path".to_string())?;
    if let Ok(img) = c.get_image() {
        let (bytes, ext) = quire_core::media::encode_clipboard_image(img.width as u32, img.height as u32, img.bytes.into_owned())?;
        return Ok(Clip::Image(bytes, ext));
    }
    match c.get_text() {
        Ok(t) if !t.is_empty() => Ok(Clip::Text(t)),
        _ => Ok(Clip::Empty),
    }
}

/// The media files a paste names, if that is all it is: terminals paste a
/// drop as its path — quoted, backslash-escaped, or as file:// URIs, one or
/// several. None unless every part is an existing image, video or audio
/// file, so ordinary text (and other kinds of file) paste as text.
pub fn dropped_paths(s: &str) -> Option<Vec<PathBuf>> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    let whole = std::iter::once(s.to_string());
    for candidate in [split_words(s), Some(whole.collect())].into_iter().flatten() {
        let paths: Option<Vec<PathBuf>> = candidate.iter().map(|w| media_file(w)).collect();
        if let Some(p) = paths.filter(|p| !p.is_empty()) {
            return Some(p);
        }
    }
    None
}

fn media_file(word: &str) -> Option<PathBuf> {
    let w = word.trim();
    let path = if let Some(rest) = w.strip_prefix("file://") {
        let rest = rest.strip_prefix("localhost").unwrap_or(rest);
        PathBuf::from(percent_decode(rest)?)
    } else if let Some(rest) = w.strip_prefix("~/") {
        dirs::home_dir()?.join(rest)
    } else {
        PathBuf::from(w)
    };
    if !path.is_absolute() || !path.is_file() || media_kind(&path.to_string_lossy()) == "file" {
        return None;
    }
    Some(path)
}

/// Shell-style words: whitespace separates, quotes and backslashes keep it.
fn split_words(s: &str) -> Option<Vec<String>> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut started = false;
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        match c {
            '\'' | '"' => {
                started = true;
                loop {
                    match chars.next()? {
                        q if q == c => break,
                        '\\' if c == '"' => cur.push(chars.next()?),
                        x => cur.push(x),
                    }
                }
            }
            '\\' => {
                started = true;
                cur.push(chars.next()?);
            }
            c if c.is_whitespace() => {
                if started {
                    out.push(std::mem::take(&mut cur));
                    started = false;
                }
            }
            c => {
                started = true;
                cur.push(c);
            }
        }
    }
    if started {
        out.push(cur);
    }
    Some(out)
}

fn percent_decode(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            let hex = std::str::from_utf8(b.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn drops_are_recognised_in_every_terminal_shape() {
        let d = tempfile::tempdir().unwrap();
        let a = d.path().join("a photo.jpg");
        let b = d.path().join("clip.mp4");
        let txt = d.path().join("notes.txt");
        for p in [&a, &b, &txt] {
            fs::write(p, b"x").unwrap();
        }
        let (a_s, b_s) = (a.to_string_lossy().to_string(), b.to_string_lossy().to_string());
        // GNOME Terminal / WezTerm quote; Alacritty / iTerm escape; kitty sends URIs.
        assert_eq!(dropped_paths(&format!("'{}' ", a_s)), Some(vec![a.clone()]));
        assert_eq!(dropped_paths(&a_s.replace(' ', "\\ ")), Some(vec![a.clone()]));
        assert_eq!(dropped_paths(&format!("file://{}\r\nfile://{}\n", a_s.replace(' ', "%20"), b_s)), Some(vec![a.clone(), b.clone()]));
        assert_eq!(dropped_paths(&a_s), Some(vec![a.clone()]), "an unquoted path with a space still counts");
        assert_eq!(dropped_paths(&format!("\"{}\" '{}'", a_s, b_s)), Some(vec![a.clone(), b]));
        // Not a drop: text, a missing file, a non-media file, a relative path.
        assert_eq!(dropped_paths("hello there"), None);
        assert_eq!(dropped_paths(&format!("{} and more", a_s.replace(' ', "\\ "))), None);
        assert_eq!(dropped_paths(&txt.to_string_lossy()), None);
        assert_eq!(dropped_paths("/nowhere/x.jpg"), None);
        assert_eq!(dropped_paths("x.jpg"), None);
        assert_eq!(dropped_paths("'unterminated"), None);
        assert_eq!(dropped_paths("   "), None);
    }
}
