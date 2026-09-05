//! Data Saver media compression.
//! Images downsample/re-encode via the pure-Rust `image` crate (kept in the
//! source format so the `![](assets/<uuid>.<ext>)` markdown link never changes).
//! Video/audio transcode via the `ffmpeg` CLI when it is installed (best-effort:
//! if ffmpeg is missing or the encode fails, the original bytes are kept).

use image::ImageFormat;
use std::io::Cursor;
use std::path::Path;
use std::process::Command;

/// Raster formats we'll re-encode. GIF is excluded (would flatten animation);
/// HEIC/HEIF need libheif so are skipped on Linux.
pub fn is_compressible_image(ext: &str) -> bool {
    matches!(ext, "jpg" | "jpeg" | "png" | "bmp" | "tiff" | "tif")
}

pub fn is_video(ext: &str) -> bool {
    crate::parser::media_kind(ext) == crate::parser::MediaKind::Video
}

/// The audio formats ffmpeg can re-encode for us. Narrower than the parser's
/// `AUDIO_EXTS` (which is about *classifying* a link): `wav`/`aiff`/`caf` are
/// left alone, and `weba` is WebM audio — what the recorder falls back to when
/// the webview can't give us Ogg/Opus.
pub fn is_audio(ext: &str) -> bool {
    matches!(ext, "m4a" | "mp3" | "ogg" | "opus" | "oga" | "weba")
}

pub fn is_transcodable(ext: &str) -> bool {
    is_video(ext) || is_audio(ext)
}

/// The longest edge Data Saver downsamples to.
const MAX_EDGE: u32 = 2048;

/// Downsample to 2048px on the longest edge and re-encode in the same format.
/// Returns None if the data can't be decoded (caller keeps the original bytes).
pub fn downsample(data: &[u8], ext: &str) -> Option<Vec<u8>> {
    let img = image::load_from_memory(data).ok()?;
    // `thumbnail` scales by a ratio that is *not* clamped to 1, so an image
    // already smaller than 2048px came back enlarged — a Data Saver that made
    // files bigger. Only resize when there is something to shrink.
    let (w, h) = (img.width(), img.height());
    let shrunk = if w > MAX_EDGE || h > MAX_EDGE {
        img.thumbnail(MAX_EDGE, MAX_EDGE) // preserves aspect
    } else {
        img
    };
    let mut buf: Vec<u8> = Vec::new();
    match ext {
        "jpg" | "jpeg" => {
            let rgb = shrunk.to_rgb8();
            let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 70);
            enc.encode_image(&rgb).ok()?;
        }
        "png" => {
            shrunk.write_to(&mut Cursor::new(&mut buf), ImageFormat::Png).ok()?;
        }
        "bmp" => {
            shrunk.write_to(&mut Cursor::new(&mut buf), ImageFormat::Bmp).ok()?;
        }
        "tiff" | "tif" => {
            shrunk.write_to(&mut Cursor::new(&mut buf), ImageFormat::Tiff).ok()?;
        }
        _ => return None,
    }
    Some(buf)
}

/// Transcode `path` in place if ffmpeg is available and the result is smaller.
/// Returns bytes saved, Some(0) if handled-but-no-gain, or None on hard failure.
pub fn compress_in_place(path: &Path, ext: &str) -> Option<u64> {
    let original = std::fs::metadata(path).ok()?.len();
    if original == 0 {
        return Some(0);
    }
    let tmp = path.with_file_name(format!("._tmp_{}.{}", uuid::Uuid::new_v4(), ext));
    let args = ffmpeg_args(ext)?;

    let mut cmd = Command::new("ffmpeg");
    cmd.arg("-y").arg("-i").arg(path);
    for a in &args {
        cmd.arg(a);
    }
    cmd.arg(&tmp);
    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());

    let status = match cmd.status() {
        Ok(s) => s,
        Err(_) => {
            // ffmpeg not installed — nothing we can do; treat as handled.
            let _ = std::fs::remove_file(&tmp);
            return Some(0);
        }
    };
    if !status.success() {
        let _ = std::fs::remove_file(&tmp);
        return Some(0);
    }
    let new_size = std::fs::metadata(&tmp).ok().map(|m| m.len()).unwrap_or(u64::MAX);
    if new_size >= original {
        let _ = std::fs::remove_file(&tmp);
        return Some(0);
    }
    // Swap in place (keeps the same filename/extension).
    if std::fs::rename(&tmp, path).is_err() {
        let _ = std::fs::remove_file(&tmp);
        return None;
    }
    Some(original - new_size)
}

/// ffmpeg output options for an extension. None → don't try to transcode.
fn ffmpeg_args(ext: &str) -> Option<Vec<String>> {
    let s = |v: &str| v.to_string();
    match ext {
        "mp4" | "mov" | "m4v" => Some(vec![
            s("-vf"), s("scale=-2:min(720\\,ih)"),
            s("-c:v"), s("libx264"), s("-crf"), s("28"), s("-preset"), s("medium"),
            s("-c:a"), s("aac"), s("-b:a"), s("96k"),
            s("-movflags"), s("+faststart"),
        ]),
        "webm" | "mkv" => Some(vec![
            s("-vf"), s("scale=-2:min(720\\,ih)"),
            s("-c:v"), s("libvpx-vp9"), s("-crf"), s("34"), s("-b:v"), s("0"),
            s("-c:a"), s("libopus"), s("-b:a"), s("64k"),
        ]),
        "m4a" => Some(vec![s("-c:a"), s("aac"), s("-b:a"), s("48k"), s("-ac"), s("1")]),
        // WebM audio: ffmpeg won't infer a muxer from ".weba", so name it.
        "weba" => Some(vec![
            s("-c:a"), s("libopus"), s("-b:a"), s("48k"), s("-ac"), s("1"), s("-f"), s("webm"),
        ]),
        "mp3" => Some(vec![s("-c:a"), s("libmp3lame"), s("-b:a"), s("64k"), s("-ac"), s("1")]),
        "ogg" | "opus" | "oga" => {
            Some(vec![s("-c:a"), s("libopus"), s("-b:a"), s("48k"), s("-ac"), s("1")])
        }
        _ => None,
    }
}

/// Replace `path`'s contents atomically: write a sibling temp file, fsync it,
/// then rename over the original. A crash mid-write leaves the old file whole
/// rather than a truncated one — the same discipline `store::write_file` uses
/// for journal text.
pub fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    let tmp = path.with_file_name(format!("._tmp_{}", uuid::Uuid::new_v4()));
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
    }
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn data_saver_never_enlarges_a_small_image() {
        // `thumbnail` scales by an unclamped ratio, so a 120×80 photo used to
        // come back as 2048×1365 — Data Saver making the file bigger.
        let small = image::RgbImage::new(120, 80);
        let mut png: Vec<u8> = Vec::new();
        image::DynamicImage::ImageRgb8(small)
            .write_to(&mut Cursor::new(&mut png), ImageFormat::Png)
            .unwrap();
        let out = downsample(&png, "png").unwrap();
        let decoded = image::load_from_memory(&out).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (120, 80));
    }

    #[test]
    fn a_big_image_still_shrinks_to_the_long_edge() {
        let big = image::RgbImage::new(4096, 2048);
        let mut png: Vec<u8> = Vec::new();
        image::DynamicImage::ImageRgb8(big)
            .write_to(&mut Cursor::new(&mut png), ImageFormat::Png)
            .unwrap();
        let out = downsample(&png, "png").unwrap();
        let decoded = image::load_from_memory(&out).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (2048, 1024));
    }
}
