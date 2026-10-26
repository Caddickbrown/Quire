//! Photos, video and sound, the way Nook keeps them.
//!
//! A file lives in `<base>/assets/<UUID>.<ext>` and an entry points at it with
//! an ordinary markdown image link, `![caption](assets/<UUID>.<ext>)`, relative
//! to the journal folder rather than to the day file. That is Nook's layout to
//! the byte — an uppercase UUID, a lowercase extension — so a photo attached
//! here is one Nook shows, and one its Data Saver can shrink later. Wander does
//! no compressing of its own: it copies the file in as it is and leaves the
//! efficiency to Nook.

use std::fs;
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

const IMAGE: &[&str] = &["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"];
const VIDEO: &[&str] = &["mov", "mp4", "m4v", "webm"];
const AUDIO: &[&str] = &["m4a", "mp3", "wav", "aac", "aiff", "caf", "ogg", "opus", "flac"];

/// The extension of `path`, lower-cased, if it is one of the media kinds above.
pub fn media_ext(path: &Path) -> Option<String> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    [IMAGE, VIDEO, AUDIO]
        .iter()
        .any(|kind| kind.contains(&ext.as_str()))
        .then_some(ext)
}

pub fn assets_dir(base: &Path) -> PathBuf {
    base.join("assets")
}

fn fresh_name(ext: &str) -> String {
    format!("{}.{}", uuid::Uuid::new_v4().to_string().to_uppercase(), ext)
}

/// A dotted name beside the final one, so a sync client or Nook's asset list
/// never picks up a file that is still being written.
fn staging(dir: &Path, ext: &str) -> PathBuf {
    dir.join(format!(".{}.{}.part", uuid::Uuid::new_v4(), ext))
}

/// Copy a file the reader dropped on the page into assets/, and return the
/// link path for it: `assets/<UUID>.<ext>`.
pub fn import(base: &Path, source: &Path) -> Result<String, String> {
    let name = source
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let ext = media_ext(source)
        .ok_or_else(|| format!("{} isn't a photo, a video or a sound file", name))?;
    let dir = assets_dir(base);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let part = staging(&dir, &ext);
    let target = dir.join(fresh_name(&ext));
    fs::copy(source, &part)
        .and_then(|_| fs::rename(&part, &target))
        .map_err(|e| {
            let _ = fs::remove_file(&part);
            format!("{} couldn't be copied in: {}", name, e)
        })?;
    Ok(format!("assets/{}", target.file_name().unwrap().to_string_lossy()))
}

/// Keep a recording made in the page. The webview can only record into Ogg or
/// WebM, which neither Apple build can play, so when ffmpeg is installed the
/// recording is turned into AAC in an .m4a — the format the iPhone records its
/// own memos in. Without ffmpeg it is kept as it came, and plays here and in
/// the Android build.
pub fn save_recording(base: &Path, bytes: &[u8], ext: &str) -> Result<String, String> {
    let ext = ext.to_ascii_lowercase();
    if !AUDIO.contains(&ext.as_str()) && !VIDEO.contains(&ext.as_str()) {
        return Err(format!("A recording can't be saved as .{}", ext));
    }
    let dir = assets_dir(base);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let part = staging(&dir, &ext);
    fs::write(&part, bytes).map_err(|e| format!("The recording couldn't be saved: {}", e))?;

    if ext != "m4a" && AUDIO.contains(&ext.as_str()) {
        let converted = staging(&dir, "m4a");
        if to_m4a(&part, &converted) {
            let _ = fs::remove_file(&part);
            return finish(&dir, &converted, "m4a");
        }
        let _ = fs::remove_file(&converted);
    }
    finish(&dir, &part, &ext)
}

fn finish(dir: &Path, part: &Path, ext: &str) -> Result<String, String> {
    let target = dir.join(fresh_name(ext));
    fs::rename(part, &target).map_err(|e| {
        let _ = fs::remove_file(part);
        format!("The recording couldn't be saved: {}", e)
    })?;
    Ok(format!("assets/{}", target.file_name().unwrap().to_string_lossy()))
}

/// A voice note being recorded by ffmpeg, straight from the microphone into an
/// .m4a. On Linux this is how Wander records: WebKitGTK's own recorder needs
/// gst-plugins-bad, which most desktops don't install, and would hand back Ogg
/// that has to be converted anyway. Dropped without being stopped (the app
/// quitting mid-note), ffmpeg is killed and the half-file removed.
pub struct Recording {
    child: Child,
    part: PathBuf,
    dir: PathBuf,
}

/// The microphone, as ffmpeg names it here: PulseAudio's default source, which
/// PipeWire also answers to.
#[cfg(target_os = "linux")]
const MICROPHONE: &[&str] = &["-f", "pulse", "-i", "default"];

/// Start recording into assets/. Err if this platform records in the webview
/// instead (Windows and macOS: their webviews record natively), or if ffmpeg
/// isn't installed.
pub fn start_recording(base: &Path) -> Result<Recording, String> {
    #[cfg(not(target_os = "linux"))]
    {
        let _ = base;
        return Err("unsupported".to_string());
    }
    #[cfg(target_os = "linux")]
    {
        let dir = assets_dir(base);
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let part = staging(&dir, "m4a");
        let child = Command::new("ffmpeg")
            .args(["-loglevel", "error", "-y"])
            .args(MICROPHONE)
            .args(["-ac", "1", "-c:a", "aac", "-b:a", "96k", "-f", "ipod"])
            .arg(&part)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| match e.kind() {
                ErrorKind::NotFound => "Recording needs ffmpeg — install it and try again".to_string(),
                _ => format!("The microphone couldn't be opened: {}", e),
            })?;
        Ok(Recording { child, part, dir })
    }
}

impl Recording {
    /// Stop, and keep the note: `q` on ffmpeg's stdin lets it finish the file
    /// properly, where a kill would leave an .m4a with no index to play from.
    pub fn stop(mut self) -> Result<String, String> {
        if let Some(mut stdin) = self.child.stdin.take() {
            let _ = stdin.write_all(b"q");
        }
        let status = self.child.wait().map_err(|e| e.to_string())?;
        let recorded = fs::metadata(&self.part).is_ok_and(|m| m.len() > 0);
        if !status.success() || !recorded {
            let _ = fs::remove_file(&self.part);
            return Err("The microphone didn't record anything".to_string());
        }
        let (dir, part) = (self.dir.clone(), self.part.clone());
        // Kept: nothing left for Drop to clean up.
        self.part = PathBuf::new();
        finish(&dir, &part, "m4a")
    }
}

impl Drop for Recording {
    fn drop(&mut self) {
        if self.part.as_os_str().is_empty() {
            return;
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_file(&self.part);
    }
}

/// Mono AAC at 96 kbps: plenty for a voice, and what every build can play.
/// False if ffmpeg isn't installed or the conversion fails, and the caller
/// keeps the original.
fn to_m4a(input: &Path, output: &Path) -> bool {
    let status = Command::new("ffmpeg")
        .args(["-nostdin", "-loglevel", "error", "-y", "-i"])
        .arg(input)
        .args(["-vn", "-ac", "1", "-c:a", "aac", "-b:a", "96k", "-f", "ipod"])
        .arg(output)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    match status {
        Ok(status) => status.success() && fs::metadata(output).is_ok_and(|m| m.len() > 0),
        Err(e) if e.kind() == ErrorKind::NotFound => false,
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("wander-media-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn is_nook_name(link: &str, ext: &str) -> bool {
        let Some(name) = link.strip_prefix("assets/") else { return false };
        let Some(stem) = name.strip_suffix(&format!(".{}", ext)) else { return false };
        uuid::Uuid::parse_str(stem).is_ok() && stem == stem.to_uppercase()
    }

    #[test]
    fn an_import_is_copied_under_a_nook_style_name() {
        let base = scratch();
        let photo = base.join("Holiday.JPG");
        fs::write(&photo, b"not really a jpeg").unwrap();
        let link = import(&base, &photo).unwrap();
        assert!(is_nook_name(&link, "jpg"), "{}", link);
        assert_eq!(fs::read(base.join(&link)).unwrap(), b"not really a jpeg");
        assert!(photo.exists(), "the original is left where it was");
        let leftovers: Vec<_> = fs::read_dir(assets_dir(&base))
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with('.'))
            .collect();
        assert!(leftovers.is_empty(), "no staging file is left behind");
    }

    #[test]
    fn only_media_can_be_imported() {
        let base = scratch();
        let notes = base.join("notes.txt");
        fs::write(&notes, b"text").unwrap();
        assert!(import(&base, &notes).is_err());
        assert!(!assets_dir(&base).exists() || fs::read_dir(assets_dir(&base)).unwrap().next().is_none());
    }

    #[test]
    fn a_recording_is_kept_even_without_a_conversion() {
        let base = scratch();
        // Not real Ogg, so ffmpeg (if installed) fails and the bytes are kept.
        let link = save_recording(&base, b"not really ogg", "ogg").unwrap();
        assert!(is_nook_name(&link, "ogg"), "{}", link);
        assert_eq!(fs::read(base.join(&link)).unwrap(), b"not really ogg");
    }

    #[test]
    fn a_real_recording_becomes_m4a_when_ffmpeg_is_installed() {
        let base = scratch();
        let ogg = base.join("tone.ogg");
        let made = Command::new("ffmpeg")
            .args(["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "sine=duration=1", "-c:a", "libopus"])
            .arg(&ogg)
            .status();
        if !made.is_ok_and(|s| s.success()) {
            return; // no ffmpeg (or no Opus encoder): the fallback test covers it
        }
        let link = save_recording(&base, &fs::read(&ogg).unwrap(), "ogg").unwrap();
        assert!(is_nook_name(&link, "m4a"), "{}", link);
        assert!(fs::metadata(base.join(&link)).unwrap().len() > 0);
    }

    #[test]
    fn a_recording_must_be_sound_or_video() {
        let base = scratch();
        assert!(save_recording(&base, b"x", "exe").is_err());
    }
}
