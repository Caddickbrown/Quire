//! Nook-compatible media compression ("Data Saver") for Quire.
//!
//! Self-contained: no tauri dependency. Progress is reported through a plain
//! `&mut dyn FnMut(usize, usize)` callback (done, total).
//!
//! Journal layout handled here:
//! - `root/assets/**` holds media, nested (`assets/2026/09/x.jpg`) or flat
//!   (`assets/<UUID>.jpg`, as written by the Nook iOS app).
//! - Content files: `root/inbox.md`, `root/journal/**/*.md`, and any other
//!   `root/*.md` except export.md, nook-export.md, transfer.md, readme.md.
//! - Ledger: `root/.quire/datasaver-<device_id>.json` (read from `.nook/` too) =
//!   `{"savedBytes": i64, "assets": [String]}`; each device writes only its own.

use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::fs;
use std::io::{Cursor, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};

use image::codecs::bmp::BmpEncoder;
use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::{CompressionType, FilterType as PngFilter, PngEncoder};
use image::codecs::tiff::TiffEncoder;
use image::imageops::FilterType;
use image::{ColorType, DynamicImage, ImageDecoder, ImageFormat, ImageReader};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};

/// Longest edge (px) for images when Data Saver is on.
pub const MAX_IMAGE_EDGE: u32 = 2048;
/// JPEG quality used by Data Saver.
pub const JPEG_QUALITY: u8 = 70;
/// JPEG quality for HEIC conversion when Data Saver is off.
pub const HEIC_FULL_QUALITY: u8 = 85;

pub const HEIC_TOOL_MISSING: &str = "HEIC conversion needs libheif (heif-convert) or ImageMagick";
pub const FFMPEG_MISSING: &str = "Video and audio compression needs ffmpeg";

const IMAGE_EXTS: &[&str] = &["jpg", "jpeg", "png", "tiff", "tif", "bmp"];
const VIDEO_EXTS: &[&str] = &["mov", "mp4", "m4v"];
const AUDIO_EXTS: &[&str] = &["m4a", "weba", "webm", "ogg", "opus"];
const HEIC_EXTS: &[&str] = &["heic", "heif"];
const EXCLUDED_ROOT_MD: &[&str] = &["export.md", "nook-export.md", "transfer.md", "readme.md"];
const TMP_PREFIX: &str = "._tmp_";

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolStatus {
    /// `ffmpeg` found on PATH.
    pub ffmpeg: bool,
    /// `heif-convert`, `magick` or (non-Windows) `convert` found on PATH.
    pub heif: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompressReport {
    pub heic_converted: usize,
    pub images: usize,
    pub videos: usize,
    pub audio: usize,
    pub saved_bytes: i64,
    pub skipped_missing_tools: Vec<String>,
    pub errors: Vec<String>,
}

/// On-disk ledger, byte-compatible with Nook's `datasaver-<device>.json`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ledger {
    #[serde(default)]
    pub saved_bytes: i64,
    #[serde(default)]
    pub assets: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Image,
    Video,
    Audio,
}

/// Internal error distinguishing "tool missing" (retry later, don't mark
/// handled) from a real failure.
#[derive(Debug)]
enum MediaError {
    MissingTool(&'static str),
    Failed(String),
}

impl MediaError {
    fn into_string(self) -> String {
        match self {
            MediaError::MissingTool(s) => s.to_string(),
            MediaError::Failed(s) => s,
        }
    }
}

// ---------------------------------------------------------------------------
// Extension helpers
// ---------------------------------------------------------------------------

fn ext_of(path: &Path) -> String {
    path.extension().and_then(OsStr::to_str).unwrap_or("").to_ascii_lowercase()
}

fn norm_ext(ext: &str) -> String {
    ext.trim_start_matches('.').to_ascii_lowercase()
}

fn kind_of(ext: &str) -> Option<Kind> {
    let e = norm_ext(ext);
    if IMAGE_EXTS.contains(&e.as_str()) {
        Some(Kind::Image)
    } else if VIDEO_EXTS.contains(&e.as_str()) {
        Some(Kind::Video)
    } else if AUDIO_EXTS.contains(&e.as_str()) {
        Some(Kind::Audio)
    } else {
        None
    }
}

/// True for jpg/jpeg/png/tiff/tif/bmp (case-insensitive).
pub fn is_compressible_image(ext: &str) -> bool {
    kind_of(ext) == Some(Kind::Image)
}

pub fn is_heic(ext: &str) -> bool {
    HEIC_EXTS.contains(&norm_ext(ext).as_str())
}

/// True for video/audio extensions handled by ffmpeg.
pub fn is_compressible_av(ext: &str) -> bool {
    matches!(kind_of(ext), Some(Kind::Video) | Some(Kind::Audio))
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

fn image_format_for(ext: &str) -> Option<ImageFormat> {
    match norm_ext(ext).as_str() {
        "jpg" | "jpeg" => Some(ImageFormat::Jpeg),
        "png" => Some(ImageFormat::Png),
        "tif" | "tiff" => Some(ImageFormat::Tiff),
        "bmp" => Some(ImageFormat::Bmp),
        _ => None,
    }
}

fn decode_oriented(bytes: &[u8], fallback: ImageFormat) -> Option<DynamicImage> {
    let mut reader = ImageReader::new(Cursor::new(bytes)).with_guessed_format().ok()?;
    if reader.format().is_none() {
        reader.set_format(fallback);
    }
    let mut decoder = reader.into_decoder().ok()?;
    let orientation = decoder.orientation().ok();
    let mut img = DynamicImage::from_decoder(decoder).ok()?;
    if let Some(o) = orientation {
        img.apply_orientation(o);
    }
    Some(img)
}

fn to_8bit(img: &DynamicImage, allow_alpha: bool) -> DynamicImage {
    let c = img.color();
    match (c.has_color(), c.has_alpha() && allow_alpha) {
        (false, false) => DynamicImage::ImageLuma8(img.to_luma8()),
        (false, true) => DynamicImage::ImageLumaA8(img.to_luma_alpha8()),
        (true, false) => DynamicImage::ImageRgb8(img.to_rgb8()),
        (true, true) => DynamicImage::ImageRgba8(img.to_rgba8()),
    }
}

fn encode(img: &DynamicImage, format: ImageFormat) -> Option<Vec<u8>> {
    let mut buf = Vec::new();
    match format {
        ImageFormat::Jpeg => {
            // JPEG has no alpha and only 8-bit L/RGB.
            let img = match img.color() {
                ColorType::L8 | ColorType::Rgb8 => img.clone(),
                _ => to_8bit(img, false),
            };
            img.write_with_encoder(JpegEncoder::new_with_quality(&mut buf, JPEG_QUALITY)).ok()?;
        }
        ImageFormat::Png => {
            let try_write = |im: &DynamicImage| -> Option<Vec<u8>> {
                let mut out = Vec::new();
                im.write_with_encoder(PngEncoder::new_with_quality(
                    &mut out,
                    CompressionType::Best,
                    PngFilter::Adaptive,
                ))
                .ok()?;
                Some(out)
            };
            buf = try_write(img).or_else(|| try_write(&to_8bit(img, true)))?;
        }
        ImageFormat::Tiff => {
            let try_write = |im: &DynamicImage| -> Option<Vec<u8>> {
                let mut out = Cursor::new(Vec::new());
                im.write_with_encoder(TiffEncoder::new(&mut out)).ok()?;
                Some(out.into_inner())
            };
            buf = try_write(img).or_else(|| try_write(&to_8bit(img, true)))?;
        }
        ImageFormat::Bmp => {
            let im = match img.color() {
                ColorType::L8 | ColorType::La8 | ColorType::Rgb8 | ColorType::Rgba8 => img.clone(),
                _ => to_8bit(img, true),
            };
            im.write_with_encoder(BmpEncoder::new(&mut buf)).ok()?;
        }
        _ => return None,
    }
    Some(buf)
}

/// Decode, apply EXIF orientation, downscale so the longest edge is at most
/// 2048 px (never enlarging, Lanczos3) and re-encode in the same format
/// (JPEG q70, PNG best+adaptive, TIFF/BMP default).
///
/// Returns `Some` only if the result is strictly smaller than `bytes`.
/// Non-compressible extensions (gif, webp, svg, ...) and undecodable input
/// return `None`.
pub fn compress_image_bytes(bytes: &[u8], ext: &str) -> Option<Vec<u8>> {
    recompress(bytes, ext, false)
}

/// `cap_edge`: also accept a not-smaller result when the source exceeded the
/// edge limit (used for HEIC-derived JPEGs, whose size must be capped).
fn recompress(bytes: &[u8], ext: &str, cap_edge: bool) -> Option<Vec<u8>> {
    let format = image_format_for(ext)?;
    let mut img = decode_oriented(bytes, format)?;
    let oversized = img.width().max(img.height()) > MAX_IMAGE_EDGE;
    if oversized {
        // resize() keeps aspect ratio and fits inside the box.
        img = img.resize(MAX_IMAGE_EDGE, MAX_IMAGE_EDGE, FilterType::Lanczos3);
    }
    let out = encode(&img, format)?;
    if out.len() < bytes.len() || (cap_edge && oversized) {
        Some(out)
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Tool discovery
// ---------------------------------------------------------------------------

fn find_in_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    let mut names = vec![name.to_string()];
    if cfg!(windows) {
        names.push(format!("{name}.exe"));
    }
    for dir in std::env::split_paths(&path) {
        for n in &names {
            let p = dir.join(n);
            if is_executable(&p) {
                return Some(p);
            }
        }
    }
    None
}

#[cfg(unix)]
fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(p).map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
}

#[cfg(not(unix))]
fn is_executable(p: &Path) -> bool {
    p.is_file()
}

/// HEIC converters in preference order. ImageMagick 6's `convert` is skipped
/// on Windows because `convert.exe` there is the system FAT->NTFS tool.
fn heic_tools() -> Vec<(&'static str, PathBuf)> {
    let mut v = Vec::new();
    for name in ["heif-convert", "magick", "convert"] {
        if name == "convert" && cfg!(windows) {
            continue;
        }
        if let Some(p) = find_in_path(name) {
            v.push((name, p));
        }
    }
    v
}

/// Which external tools are available (PATH lookup only, nothing is run).
pub fn tools() -> ToolStatus {
    ToolStatus { ffmpeg: find_in_path("ffmpeg").is_some(), heif: !heic_tools().is_empty() }
}

// ---------------------------------------------------------------------------
// File helpers
// ---------------------------------------------------------------------------

fn parent_dir(path: &Path) -> PathBuf {
    match path.parent() {
        Some(p) if !p.as_os_str().is_empty() => p.to_path_buf(),
        _ => PathBuf::from("."),
    }
}

/// Write via a `._tmp_*` file in the same directory, then rename over target.
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let dir = parent_dir(path);
    let mut tmp = tempfile::Builder::new()
        .prefix(TMP_PREFIX)
        .tempfile_in(&dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?;
    tmp.write_all(bytes).map_err(|e| format!("{}: {e}", path.display()))?;
    tmp.as_file().sync_all().ok();
    keep_mode(tmp.path(), path);
    tmp.persist(path).map_err(|e| format!("{}: {}", path.display(), e.error))?;
    Ok(())
}

fn file_len(p: &Path) -> i64 {
    fs::metadata(p).map(|m| m.len() as i64).unwrap_or(0)
}

/// `dir/stem.jpg`, or `stem-1.jpg`, `stem-2.jpg`, ... if taken.
fn unique_jpg_path(heic: &Path) -> PathBuf {
    let dir = parent_dir(heic);
    let stem = heic.file_stem().and_then(OsStr::to_str).unwrap_or("image").to_string();
    let first = dir.join(format!("{stem}.jpg"));
    if !first.exists() {
        return first;
    }
    (1..)
        .map(|i| dir.join(format!("{stem}-{i}.jpg")))
        .find(|p| !p.exists())
        .expect("infinite iterator")
}

fn run_tool(cmd: &mut Command) -> Result<(), String> {
    let out = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        let tail: String = err.lines().rev().take(3).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join(" | ");
        Err(format!("exit {}: {}", out.status, tail.trim()))
    }
}

// ---------------------------------------------------------------------------
// HEIC -> JPEG
// ---------------------------------------------------------------------------

fn heic_to_jpeg_inner(path: &Path, data_saver: bool) -> Result<PathBuf, MediaError> {
    let tools = heic_tools();
    if tools.is_empty() {
        return Err(MediaError::MissingTool(HEIC_TOOL_MISSING));
    }
    let q = if data_saver { JPEG_QUALITY } else { HEIC_FULL_QUALITY };
    let dir = parent_dir(path);
    // Convert inside a private temp dir so partial output and any auxiliary
    // files heif-convert may emit (depth maps, burst frames) never leak.
    let work = tempfile::Builder::new()
        .prefix(TMP_PREFIX)
        .tempdir_in(&dir)
        .map_err(|e| MediaError::Failed(format!("{}: {e}", dir.display())))?;
    let out = work.path().join("out.jpg");
    let mut last_err = String::new();
    let mut produced: Option<PathBuf> = None;
    for (name, exe) in &tools {
        let mut cmd = Command::new(exe);
        if *name == "heif-convert" {
            cmd.arg("-q").arg(q.to_string()).arg(path).arg(&out);
        } else {
            cmd.arg(path).arg("-auto-orient").arg("-quality").arg(q.to_string()).arg(&out);
        }
        match run_tool(&mut cmd) {
            Ok(()) => {
                if let Some(p) = pick_jpeg_output(work.path(), &out) {
                    produced = Some(p);
                    break;
                }
                last_err = format!("{name}: produced no output");
            }
            Err(e) => last_err = format!("{name}: {e}"),
        }
    }
    let produced = produced.ok_or_else(|| {
        MediaError::Failed(format!("HEIC conversion failed for {}: {last_err}", path.display()))
    })?;
    let mut bytes = fs::read(&produced).map_err(|e| MediaError::Failed(e.to_string()))?;
    if data_saver {
        // Smaller re-encode, or the 2048-edge version even if not smaller.
        if let Some(out) = recompress(&bytes, "jpg", true) {
            bytes = out;
        }
    }
    let target = unique_jpg_path(path);
    write_atomic(&target, &bytes).map_err(MediaError::Failed)?;
    Ok(target)
}

/// `out.jpg` if present, otherwise the first JPEG the tool wrote (multi-image
/// HEICs produce `out-1.jpg`, `out-2.jpg`, ...; ImageMagick `out-0.jpg`).
fn pick_jpeg_output(dir: &Path, expected: &Path) -> Option<PathBuf> {
    if fs::metadata(expected).map(|m| m.len() > 0).unwrap_or(false) {
        return Some(expected.to_path_buf());
    }
    let mut jpgs: Vec<PathBuf> = fs::read_dir(dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| ext_of(p) == "jpg" && !p.to_string_lossy().contains("depth") && !p.to_string_lossy().contains("urn:"))
        .collect();
    jpgs.sort();
    jpgs.into_iter().find(|p| file_len(p) > 0)
}

/// Convert a HEIC/HEIF file to `<same stem>.jpg` beside it (`-1`, `-2`, ...
/// if taken). Data saver: q70 then `compress_image_bytes` (2048 edge);
/// otherwise q85 at full size. With data saver the 2048 edge cap is always
/// enforced, even in the rare case the downscaled JPEG isn't smaller. The source file is left in place.
pub fn heic_to_jpeg(path: &Path, data_saver: bool) -> Result<PathBuf, String> {
    heic_to_jpeg_inner(path, data_saver).map_err(MediaError::into_string)
}

// ---------------------------------------------------------------------------
// Video / audio via ffmpeg
// ---------------------------------------------------------------------------

/// Long edge capped at 1280 (so 16:9 lands at 1280x720), never upscaled; the
/// `-2` keeps aspect ratio with an even dimension, the second scale makes the
/// capped side even too (odd-sized sources), which libx264 requires.
const VIDEO_SCALE: &str = "scale='if(gt(iw,ih),min(1280,iw),-2)':'if(gt(iw,ih),-2,min(1280,ih))',scale=trunc(iw/2)*2:trunc(ih/2)*2";

fn ffmpeg_args(ext: &str, input: &Path, output: &Path) -> Option<Vec<String>> {
    let e = norm_ext(ext);
    let mut a: Vec<String> = vec!["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i"]
        .into_iter()
        .map(String::from)
        .collect();
    a.push(input.to_string_lossy().into_owned());
    let tail: Vec<&str> = match e.as_str() {
        "mov" | "mp4" | "m4v" => {
            let fmt = if e == "mov" { "mov" } else { "mp4" };
            vec![
                "-map", "0:v:0", "-map", "0:a?", "-c:v", "libx264", "-preset", "medium", "-crf", "23",
                "-vf", VIDEO_SCALE, "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", "-f", fmt,
            ]
        }
        "m4a" => vec!["-vn", "-c:a", "aac", "-ac", "1", "-ar", "44100", "-b:a", "48k", "-f", "ipod"],
        "weba" | "webm" => vec!["-vn", "-c:a", "libopus", "-b:a", "32k", "-ac", "1", "-f", "webm"],
        "ogg" | "opus" => vec!["-vn", "-c:a", "libopus", "-b:a", "32k", "-ac", "1", "-f", "ogg"],
        _ => return None,
    };
    a.extend(tail.into_iter().map(String::from));
    a.push(output.to_string_lossy().into_owned());
    Some(a)
}

/// Returns Ok(Some(saved)) if replaced, Ok(None) if the result wasn't smaller.
fn compress_av(path: &Path) -> Result<Option<i64>, MediaError> {
    let ext = ext_of(path);
    let ffmpeg = find_in_path("ffmpeg").ok_or(MediaError::MissingTool(FFMPEG_MISSING))?;
    let dir = parent_dir(path);
    let tmp = tempfile::Builder::new()
        .prefix(TMP_PREFIX)
        .suffix(&format!(".{ext}"))
        .tempfile_in(&dir)
        .map_err(|e| MediaError::Failed(format!("{}: {e}", dir.display())))?
        .into_temp_path(); // deleted on drop unless persisted
    let args = ffmpeg_args(&ext, path, &tmp)
        .ok_or_else(|| MediaError::Failed(format!("not a video/audio file: {}", path.display())))?;
    run_tool(Command::new(ffmpeg).args(&args))
        .map_err(|e| MediaError::Failed(format!("ffmpeg failed on {}: {e}", path.display())))?;
    let before = file_len(path);
    let after = file_len(&tmp);
    if after > 0 && after < before {
        keep_mode(&tmp, path);
        tmp.persist(path).map_err(|e| MediaError::Failed(format!("{}: {}", path.display(), e.error)))?;
        Ok(Some(before - after))
    } else {
        drop(tmp);
        Ok(None)
    }
}

fn compress_image_file(path: &Path) -> Result<Option<i64>, MediaError> {
    let bytes = fs::read(path).map_err(|e| MediaError::Failed(format!("{}: {e}", path.display())))?;
    match compress_image_bytes(&bytes, &ext_of(path)) {
        Some(out) => {
            write_atomic(path, &out).map_err(MediaError::Failed)?;
            Ok(Some(bytes.len() as i64 - out.len() as i64))
        }
        None => Ok(None),
    }
}

fn compress_path(path: &Path) -> Result<Option<i64>, MediaError> {
    match kind_of(&ext_of(path)) {
        Some(Kind::Image) => compress_image_file(path),
        Some(Kind::Video) | Some(Kind::Audio) => compress_av(path),
        None => Ok(None),
    }
}

/// Compress one media file in place (meant for video/audio in the background
/// after attach; compressible images work too). Ok(Some(saved_bytes)) when
/// replaced, Ok(None) when not smaller or not a compressible type, Err when
/// ffmpeg is missing or fails.
pub fn compress_file_in_place(path: &Path) -> Result<Option<i64>, String> {
    compress_path(path).map_err(MediaError::into_string)
}

// ---------------------------------------------------------------------------
// Attach-time processing
// ---------------------------------------------------------------------------

/// Process freshly attached bytes. HEIC/HEIF always become JPEG (original
/// bytes/ext returned if no converter is installed or conversion fails);
/// with `data_saver`, compressible images are recompressed when smaller.
/// Returns (bytes, final extension).
pub fn on_attach(src_bytes: &[u8], ext: &str, data_saver: bool) -> (Vec<u8>, String) {
    if is_heic(ext) {
        let converted = (|| -> Option<Vec<u8>> {
            let dir = tempfile::tempdir().ok()?;
            let src = dir.path().join(format!("attach.{}", norm_ext(ext)));
            fs::write(&src, src_bytes).ok()?;
            let jpg = heic_to_jpeg(&src, data_saver).ok()?;
            fs::read(jpg).ok()
        })();
        return match converted {
            Some(b) => (b, "jpg".to_string()),
            None => (src_bytes.to_vec(), ext.to_string()),
        };
    }
    if data_saver && is_compressible_image(ext) {
        if let Some(b) = compress_image_bytes(src_bytes, ext) {
            return (b, ext.to_string());
        }
    }
    (src_bytes.to_vec(), ext.to_string())
}

// ---------------------------------------------------------------------------
// Ledger
// ---------------------------------------------------------------------------

/// The sidecar the ledger is written to: `.quire/`, taking over from
/// `.nook/` on the first write (the same rule as `Journal::sidecar_mut`).
fn ledger_dir(root: &Path) -> PathBuf {
    let (q, n) = (root.join(crate::journal::SIDECAR), root.join(crate::journal::LEGACY_SIDECAR));
    if !q.is_dir() && n.is_dir() {
        let _ = fs::rename(&n, &q);
    }
    q
}

/// Every folder ledgers may be read from: both sidecars, since a Nook device
/// may still be writing `.nook/` while Quire writes `.quire/`.
fn ledger_dirs(root: &Path) -> Vec<PathBuf> {
    [crate::journal::SIDECAR, crate::journal::LEGACY_SIDECAR].iter().map(|d| root.join(d)).filter(|p| p.is_dir()).collect()
}

fn safe_device_id(id: &str) -> String {
    id.chars().map(|c| if c == '/' || c == '\\' || c == ':' { '_' } else { c }).collect()
}

pub fn ledger_path(root: &Path, device_id: &str) -> PathBuf {
    ledger_dir(root).join(format!("datasaver-{}.json", safe_device_id(device_id)))
}

/// This device's ledger (empty if missing or unreadable).
pub fn read_ledger(root: &Path, device_id: &str) -> Ledger {
    let name = format!("datasaver-{}.json", safe_device_id(device_id));
    ledger_dirs(root)
        .iter()
        .find_map(|d| fs::read(d.join(&name)).ok())
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

/// Atomically write this device's ledger.
pub fn write_ledger(root: &Path, device_id: &str, ledger: &Ledger) -> Result<(), String> {
    fs::create_dir_all(ledger_dir(root)).map_err(|e| e.to_string())?;
    let json = serde_json::to_vec_pretty(ledger).map_err(|e| e.to_string())?;
    write_atomic(&ledger_path(root, device_id), &json)
}

fn all_ledgers(root: &Path) -> Vec<Ledger> {
    let mut out = Vec::new();
    for dir in ledger_dirs(root) {
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        out.extend(
            rd.flatten()
                .filter(|e| {
                    let n = e.file_name().to_string_lossy().into_owned();
                    n.starts_with("datasaver-") && n.ends_with(".json")
                })
                .filter_map(|e| fs::read(e.path()).ok())
                .filter_map(|b| serde_json::from_slice::<Ledger>(&b).ok()),
        );
    }
    out
}

/// Sum of `savedBytes` across every device's ledger.
pub fn data_saved_total(root: &Path) -> i64 {
    all_ledgers(root).iter().map(|l| l.saved_bytes).sum()
}

/// Union of asset IDs across every device's ledger.
pub fn handled_assets(root: &Path) -> HashSet<String> {
    all_ledgers(root).into_iter().flat_map(|l| l.assets).collect()
}

/// Asset ID: path under `assets/` without extension, `/`-separated
/// (flat `assets/<UUID>.jpg` -> `<UUID>`; nested -> `2026/09/30-080000`).
pub fn asset_id(root: &Path, path: &Path) -> Option<String> {
    let rel = path.strip_prefix(root.join("assets")).ok()?;
    let mut parts: Vec<String> = rel.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
    let last = parts.pop()?;
    let stem = match last.rfind('.') {
        Some(i) if i > 0 => last[..i].to_string(),
        _ => last,
    };
    parts.push(stem);
    Some(parts.join("/"))
}

fn ledger_mark(ledger: &mut Ledger, id: String, saved: i64) {
    if saved > 0 {
        ledger.saved_bytes += saved;
    }
    if !ledger.assets.contains(&id) {
        ledger.assets.push(id);
    }
}

// ---------------------------------------------------------------------------
// Walking
// ---------------------------------------------------------------------------

fn is_hidden(name: &OsStr) -> bool {
    name.to_string_lossy().starts_with('.')
}

/// All non-hidden regular files under `dir` (no symlink following), sorted.
fn walk_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            if is_hidden(&e.file_name()) {
                continue;
            }
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() {
                stack.push(e.path());
            } else if ft.is_file() {
                out.push(e.path());
            }
        }
    }
    out.sort();
    out
}

/// inbox.md, inbox/**/*.md, journal/**/*.md, split/**/*.md and other root *.md (minus export/transfer/readme).
pub fn content_files(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(rd) = fs::read_dir(root) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_ascii_lowercase();
            if name.starts_with('.') || !name.ends_with(".md") || EXCLUDED_ROOT_MD.contains(&name.as_str()) {
                continue;
            }
            if e.file_type().map(|t| t.is_file()).unwrap_or(false) {
                out.push(e.path());
            }
        }
    }
    out.extend(walk_files(&root.join("inbox")).into_iter().filter(|p| ext_of(p) == "md"));
    out.extend(walk_files(&root.join("journal")).into_iter().filter(|p| ext_of(p) == "md"));
    out.extend(walk_files(&root.join("split")).into_iter().filter(|p| ext_of(p) == "md"));
    out.sort();
    out
}

// ---------------------------------------------------------------------------
// Relinking
// ---------------------------------------------------------------------------

static IMG_LINK: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"!\[[^\]\n]*\]\(\s*(<[^>\n]*>|[^)\s]+)(?:\s+"[^"\n]*")?\s*\)"#).unwrap());

fn lexical_normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = std::str::from_utf8(&b[i + 1..i + 3]).ok();
            if let Some(v) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Rewrite image links in one markdown file's text. `swaps` maps a normalised
/// absolute-ish HEIC path to the suffix to splice in (e.g. ".jpg" or "-1.jpg").
/// A link matches if it resolves to the HEIC either relative to `root` or
/// relative to the md file's directory. Only the filename's extension (plus
/// any de-dup suffix) changes; the link's relative form is kept.
/// Returns (new text if changed, set of HEIC keys referenced).
fn relink_text(
    text: &str,
    md_path: &Path,
    root: &Path,
    swaps: &HashMap<PathBuf, String>,
) -> (Option<String>, HashSet<PathBuf>) {
    let md_dir = parent_dir(md_path);
    let mut hits = HashSet::new();
    let mut changed = false;
    let out = IMG_LINK.replace_all(text, |caps: &regex::Captures| {
        let whole = caps.get(0).unwrap();
        let url_m = caps.get(1).unwrap();
        let raw = url_m.as_str();
        let (open, inner, close) = if raw.starts_with('<') && raw.ends_with('>') && raw.len() >= 2 {
            ("<", &raw[1..raw.len() - 1], ">")
        } else {
            ("", raw, "")
        };
        let decoded = percent_decode(inner);
        let candidates = [
            lexical_normalize(&root.join(&decoded)),
            lexical_normalize(&md_dir.join(&decoded)),
        ];
        let Some((key, suffix)) = candidates.iter().find_map(|c| swaps.get_key_value(c)) else {
            return whole.as_str().to_string();
        };
        // Splice: keep everything up to the last '.' of the final segment.
        let seg_start = inner.rfind('/').map(|i| i + 1).unwrap_or(0);
        let dot = match inner[seg_start..].rfind('.') {
            Some(d) => seg_start + d,
            None => return whole.as_str().to_string(),
        };
        let new_url = format!("{open}{}{suffix}{close}", &inner[..dot]);
        hits.insert(key.clone());
        changed = true;
        let s = whole.start();
        let w = whole.as_str();
        format!("{}{}{}", &w[..url_m.start() - s], new_url, &w[url_m.end() - s..])
    });
    let new = if changed && out != text { Some(out.into_owned()) } else { None };
    (new, hits)
}

/// Relink all content files from each HEIC to its converted JPEG.
/// `conversions` = (heic path, jpg path) pairs, both under `root`.
/// Every content file is read strictly; changed files are written atomically.
/// Returns the HEICs that are safe to delete: all only if every content file
/// was read OK, minus any HEIC referenced by a file whose write failed.
pub fn relink_heics(
    root: &Path,
    conversions: &[(PathBuf, PathBuf)],
    errors: &mut Vec<String>,
) -> Vec<PathBuf> {
    let mut swaps: HashMap<PathBuf, String> = HashMap::new();
    let mut by_key: HashMap<PathBuf, PathBuf> = HashMap::new();
    for (heic, jpg) in conversions {
        let hs = heic.file_stem().and_then(OsStr::to_str).unwrap_or("");
        let js = jpg.file_stem().and_then(OsStr::to_str).unwrap_or("");
        let extra = js.strip_prefix(hs).unwrap_or("");
        let key = lexical_normalize(heic);
        swaps.insert(key.clone(), format!("{extra}.jpg"));
        by_key.insert(key, heic.clone());
    }
    if swaps.is_empty() {
        return Vec::new();
    }
    let mut read_failed = false;
    let mut blocked: HashSet<PathBuf> = HashSet::new();
    for md in content_files(root) {
        let text = match fs::read_to_string(&md) {
            Ok(t) => t,
            Err(e) => {
                read_failed = true;
                errors.push(format!("Couldn't read {}: {e}", md.display()));
                continue;
            }
        };
        let (new, hits) = relink_text(&text, &md, root, &swaps);
        if let Some(new) = new {
            if let Err(e) = write_atomic(&md, new.as_bytes()) {
                errors.push(format!("Couldn't update links in {}: {e}", md.display()));
                blocked.extend(hits);
            }
        }
    }
    if read_failed {
        return Vec::new();
    }
    by_key.into_iter().filter(|(k, _)| !blocked.contains(k)).map(|(_, h)| h).collect()
}

// ---------------------------------------------------------------------------
// Bulk compression
// ---------------------------------------------------------------------------

fn push_unique(v: &mut Vec<String>, s: &str) {
    if !v.iter().any(|x| x == s) {
        v.push(s.to_string());
    }
}

/// Data Saver over the whole journal.
///
/// (a) Every `assets/**/*.heic|heif` (not ledger-filtered) is converted to
/// JPEG, content links are rewritten, and the HEIC is deleted when safe.
/// (b) Every compressible image/video/audio under `assets/**` whose ID is in
/// no device's ledger is compressed serially. Results go to this device's
/// ledger. Progress covers both passes: `progress(done, total)`.
pub fn compress_existing(
    root: &Path,
    device_id: &str,
    progress: &mut dyn FnMut(usize, usize),
) -> Result<CompressReport, String> {
    let assets = root.join("assets");
    if !root.is_dir() {
        return Err(format!("Journal folder not found: {}", root.display()));
    }
    let mut report = CompressReport::default();
    let mut ledger = read_ledger(root, device_id);
    let handled = handled_assets(root);

    let files: Vec<PathBuf> = walk_files(&assets)
        .into_iter()
        .filter(|p| !p.file_name().map(|n| n.to_string_lossy().starts_with(TMP_PREFIX)).unwrap_or(true))
        .collect();
    let heics: Vec<PathBuf> = files.iter().filter(|p| is_heic(&ext_of(p))).cloned().collect();
    // Candidates are listed before the HEIC pass, so freshly converted JPEGs
    // (already compressed) are not recompressed.
    let candidates: Vec<PathBuf> = files
        .iter()
        .filter(|p| kind_of(&ext_of(p)).is_some())
        .filter(|p| asset_id(root, p).map(|id| !handled.contains(&id)).unwrap_or(false))
        .cloned()
        .collect();
    let total = heics.len() + candidates.len();
    let mut done = 0usize;
    progress(0, total);

    // (a) HEIC pass
    let mut conversions: Vec<(PathBuf, PathBuf)> = Vec::new();
    for heic in &heics {
        match heic_to_jpeg_inner(heic, true) {
            Ok(jpg) => {
                let saved = file_len(heic) - file_len(&jpg);
                if let Some(id) = asset_id(root, &jpg) {
                    ledger_mark(&mut ledger, id, saved);
                }
                if saved > 0 {
                    report.saved_bytes += saved;
                }
                conversions.push((heic.clone(), jpg));
            }
            Err(MediaError::MissingTool(t)) => push_unique(&mut report.skipped_missing_tools, t),
            Err(MediaError::Failed(e)) => report.errors.push(e),
        }
        done += 1;
        progress(done, total);
    }
    if !conversions.is_empty() {
        for heic in relink_heics(root, &conversions, &mut report.errors) {
            match fs::remove_file(&heic) {
                Ok(()) => report.heic_converted += 1,
                Err(e) => report.errors.push(format!("Couldn't delete {}: {e}", heic.display())),
            }
        }
        if let Err(e) = write_ledger(root, device_id, &ledger) {
            report.errors.push(format!("Couldn't write ledger: {e}"));
        }
    }

    // (b) compression pass
    for path in &candidates {
        let kind = kind_of(&ext_of(path)).expect("filtered above");
        let id = asset_id(root, path).expect("filtered above");
        let mut dirty = false;
        match compress_path(path) {
            Ok(Some(saved)) => {
                report.saved_bytes += saved;
                match kind {
                    Kind::Image => report.images += 1,
                    Kind::Video => report.videos += 1,
                    Kind::Audio => report.audio += 1,
                }
                ledger_mark(&mut ledger, id, saved);
                dirty = true;
            }
            Ok(None) => {
                ledger_mark(&mut ledger, id, 0);
                dirty = true;
            }
            // Not marked handled: retried on a later run.
            Err(MediaError::MissingTool(t)) => push_unique(&mut report.skipped_missing_tools, t),
            Err(MediaError::Failed(e)) => report.errors.push(e),
        }
        if dirty {
            if let Err(e) = write_ledger(root, device_id, &ledger) {
                report.errors.push(format!("Couldn't write ledger: {e}"));
            }
        }
        done += 1;
        progress(done, total);
    }
    Ok(report)
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

/// Decimal byte count like Apple's ByteCountFormatter `.file` style:
/// "Zero KB", "512 bytes", "1.5 MB", "2 GB" (one decimal, trailing .0 dropped).
#[allow(dead_code)]
pub fn human_bytes(n: i64) -> String {
    if n == 0 {
        return "Zero KB".to_string();
    }
    let sign = if n < 0 { "-" } else { "" };
    let a = n.unsigned_abs() as f64;
    if a < 1000.0 {
        let unit = if a as u64 == 1 { "byte" } else { "bytes" };
        return format!("{sign}{} {unit}", a as u64);
    }
    let units = ["KB", "MB", "GB", "TB", "PB"];
    let mut v = a / 1000.0;
    let mut i = 0;
    // Round first so 999_950 bytes reads "1 MB", not "1000 KB".
    while (v * 10.0).round() / 10.0 >= 1000.0 && i < units.len() - 1 {
        v /= 1000.0;
        i += 1;
    }
    let s = format!("{:.1}", v);
    let s = s.strip_suffix(".0").unwrap_or(&s);
    format!("{sign}{s} {}", units[i])
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgb, RgbImage};

    fn photo_like(w: u32, h: u32) -> DynamicImage {
        // Smooth gradients plus mild deterministic noise: compresses like a photo.
        let mut seed: u32 = 12345;
        DynamicImage::ImageRgb8(RgbImage::from_fn(w, h, |x, y| {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12345);
            let n = ((seed >> 16) & 0x0f) as u8;
            Rgb([
                ((x * 255 / w) as u8).wrapping_add(n),
                ((y * 255 / h) as u8).wrapping_add(n),
                (((x + y) / 20 % 256) as u8).wrapping_add(n),
            ])
        }))
    }

    fn encode_png_default(img: &DynamicImage) -> Vec<u8> {
        let mut c = Cursor::new(Vec::new());
        img.write_to(&mut c, ImageFormat::Png).unwrap();
        c.into_inner()
    }

    fn encode_jpeg_q(img: &DynamicImage, q: u8) -> Vec<u8> {
        let mut buf = Vec::new();
        img.write_with_encoder(JpegEncoder::new_with_quality(&mut buf, q)).unwrap();
        buf
    }

    fn dims(bytes: &[u8]) -> (u32, u32) {
        let img = ImageReader::new(Cursor::new(bytes)).with_guessed_format().unwrap().decode().unwrap();
        (img.width(), img.height())
    }

    #[test]
    fn big_png_downscaled_and_smaller() {
        let src = encode_png_default(&photo_like(4000, 3000));
        let out = compress_image_bytes(&src, "PNG").expect("should shrink");
        assert!(out.len() < src.len());
        assert_eq!(dims(&out), (2048, 1536));
        assert_eq!(image::guess_format(&out).unwrap(), ImageFormat::Png);
    }

    #[test]
    fn big_jpeg_downscaled_and_smaller() {
        let src = encode_jpeg_q(&photo_like(3000, 4000), 95);
        let out = compress_image_bytes(&src, "jpeg").expect("should shrink");
        assert!(out.len() < src.len());
        assert_eq!(dims(&out), (1536, 2048));
        assert_eq!(image::guess_format(&out).unwrap(), ImageFormat::Jpeg);
    }

    #[test]
    fn tiny_image_returns_none() {
        let img = DynamicImage::ImageRgb8(RgbImage::from_pixel(4, 4, Rgb([10, 20, 30])));
        let src = encode(&img, ImageFormat::Png).unwrap(); // already best-compressed
        assert!(compress_image_bytes(&src, "png").is_none());
    }

    #[test]
    fn non_compressible_formats_untouched() {
        assert!(compress_image_bytes(b"GIF89a....", "gif").is_none());
        assert!(compress_image_bytes(b"RIFF....WEBP", "webp").is_none());
        assert!(compress_image_bytes(b"<svg/>", "svg").is_none());
        assert!(compress_image_bytes(b"garbage", "jpg").is_none());
    }

    #[test]
    fn bmp_and_tiff_roundtrip() {
        let img = photo_like(2500, 1000);
        for fmt in [ImageFormat::Bmp, ImageFormat::Tiff] {
            let mut c = Cursor::new(Vec::new());
            img.write_to(&mut c, fmt).unwrap();
            let src = c.into_inner();
            let ext = if fmt == ImageFormat::Bmp { "bmp" } else { "tif" };
            let out = compress_image_bytes(&src, ext).expect("downscale shrinks");
            assert_eq!(image::guess_format(&out).unwrap(), fmt);
            assert_eq!(dims(&out), (2048, 819));
        }
    }

    #[test]
    fn asset_ids() {
        let root = Path::new("/j");
        assert_eq!(asset_id(root, Path::new("/j/assets/ABC-123.jpg")).unwrap(), "ABC-123");
        assert_eq!(asset_id(root, Path::new("/j/assets/2026/09/30-080000.mov")).unwrap(), "2026/09/30-080000");
        assert!(asset_id(root, Path::new("/j/other/x.jpg")).is_none());
    }

    #[test]
    fn ledger_read_write_sum() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        assert_eq!(data_saved_total(root), 0);
        let a = Ledger { saved_bytes: 1000, assets: vec!["X".into(), "2026/09/a".into()] };
        write_ledger(root, "mac-1", &a).unwrap();
        // Nook-written file (camelCase, compact), in Nook's own sidecar
        fs::create_dir_all(root.join(".nook")).unwrap();
        fs::write(root.join(".nook/datasaver-iphone.json"), r#"{"savedBytes":234,"assets":["Y"]}"#).unwrap();
        fs::write(root.join(".nook/other.json"), r#"{"savedBytes":999999}"#).unwrap();
        assert_eq!(read_ledger(root, "mac-1"), a);
        assert_eq!(data_saved_total(root), 1234);
        let h = handled_assets(root);
        assert_eq!(h.len(), 3);
        assert!(h.contains("Y") && h.contains("X") && h.contains("2026/09/a"));
        let raw = fs::read_to_string(ledger_path(root, "mac-1")).unwrap();
        assert!(raw.contains("\"savedBytes\"") && raw.contains("\"assets\""));
        // no stray temp files
        assert_eq!(fs::read_dir(root.join(".quire")).unwrap().count(), 1);
        assert_eq!(fs::read_dir(root.join(".nook")).unwrap().count(), 2);
    }

    #[test]
    fn relink_text_both_forms() {
        let root = Path::new("/j");
        let md = Path::new("/j/journal/2026/09/30.md");
        let mut swaps = HashMap::new();
        swaps.insert(PathBuf::from("/j/assets/2026/09/x.heic"), ".jpg".to_string());
        swaps.insert(PathBuf::from("/j/assets/My Pic.HEIC"), "-1.jpg".to_string());
        let text = "a ![alt](assets/2026/09/x.heic) b ![](../../../assets/2026/09/x.heic \"t\")\n\
                    c ![](assets/My%20Pic.HEIC) d ![](<../../../assets/My Pic.HEIC>) e ![](assets/2026/09/y.heic) f [x](assets/2026/09/x.heic)";
        let (new, hits) = relink_text(text, md, root, &swaps);
        let new = new.unwrap();
        assert_eq!(
            new,
            "a ![alt](assets/2026/09/x.jpg) b ![](../../../assets/2026/09/x.jpg \"t\")\n\
             c ![](assets/My%20Pic-1.jpg) d ![](<../../../assets/My Pic-1.jpg>) e ![](assets/2026/09/y.heic) f [x](assets/2026/09/x.heic)"
        );
        assert_eq!(hits.len(), 2);
        let (none, _) = relink_text("nothing here ![](assets/z.png)", md, root, &swaps);
        assert!(none.is_none());
    }

    #[test]
    fn relink_heics_fake_conversion() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("assets/2026/09")).unwrap();
        fs::create_dir_all(root.join("journal/2026/09")).unwrap();
        let heic = root.join("assets/2026/09/x.heic");
        fs::write(&heic, b"fake").unwrap();
        fs::write(root.join("assets/2026/09/x.jpg"), b"taken").unwrap();
        // fake conversion: collision -> x-1.jpg
        let jpg = unique_jpg_path(&heic);
        assert_eq!(jpg.file_name().unwrap(), "x-1.jpg");
        fs::write(&jpg, b"jpeg").unwrap();
        let flat = root.join("assets/UUID-1.HEIC");
        fs::write(&flat, b"fake").unwrap();
        let flat_jpg = unique_jpg_path(&flat);
        fs::write(&flat_jpg, b"jpeg").unwrap();

        fs::write(root.join("journal/2026/09/30.md"), "![](../../../assets/2026/09/x.heic)\n![](assets/UUID-1.HEIC)\n").unwrap();
        fs::write(root.join("inbox.md"), "![a](assets/2026/09/x.heic)").unwrap();
        fs::write(root.join("export.md"), "![a](assets/2026/09/x.heic)").unwrap();
        fs::write(root.join("Ideas.md"), "![](assets/UUID-1.HEIC)").unwrap();

        let mut errors = Vec::new();
        let mut del = relink_heics(root, &[(heic.clone(), jpg), (flat.clone(), flat_jpg)], &mut errors);
        del.sort();
        assert!(errors.is_empty(), "{errors:?}");
        assert_eq!(del.len(), 2);
        assert_eq!(
            fs::read_to_string(root.join("journal/2026/09/30.md")).unwrap(),
            "![](../../../assets/2026/09/x-1.jpg)\n![](assets/UUID-1.jpg)\n"
        );
        assert_eq!(fs::read_to_string(root.join("inbox.md")).unwrap(), "![a](assets/2026/09/x-1.jpg)");
        assert_eq!(fs::read_to_string(root.join("Ideas.md")).unwrap(), "![](assets/UUID-1.jpg)");
        assert_eq!(fs::read_to_string(root.join("export.md")).unwrap(), "![a](assets/2026/09/x.heic)");
    }

    #[cfg(unix)]
    #[test]
    fn relink_unreadable_file_blocks_deletion() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("assets")).unwrap();
        let heic = root.join("assets/a.heic");
        fs::write(&heic, b"x").unwrap();
        let jpg = root.join("assets/a.jpg");
        fs::write(&jpg, b"x").unwrap();
        // invalid UTF-8 makes the strict read fail regardless of user (root ignores perms)
        fs::write(root.join("bad.md"), [0xff, 0xfe, 0x00]).unwrap();
        fs::write(root.join("inbox.md"), "![](assets/a.heic)").unwrap();
        let mut errors = Vec::new();
        let del = relink_heics(root, &[(heic, jpg)], &mut errors);
        assert!(del.is_empty());
        assert_eq!(errors.len(), 1);
        // readable file still got relinked
        assert_eq!(fs::read_to_string(root.join("inbox.md")).unwrap(), "![](assets/a.jpg)");
    }

    #[test]
    fn content_file_selection() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("journal/2026")).unwrap();
        for f in ["inbox.md", "Work.md", "README.md", "nook-export.md", "transfer.md", "export.md", "notes.txt", ".hidden.md", "journal/2026/01.md"] {
            fs::write(root.join(f), "").unwrap();
        }
        let names: Vec<String> = content_files(root)
            .iter()
            .map(|p| p.strip_prefix(root).unwrap().to_string_lossy().replace('\\', "/"))
            .collect();
        assert_eq!(names, vec!["Work.md", "inbox.md", "journal/2026/01.md"]);
    }

    #[test]
    fn compress_existing_images_and_ledger() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("assets/2026/09")).unwrap();
        let big = encode_jpeg_q(&photo_like(3000, 2000), 95);
        fs::write(root.join("assets/2026/09/a.jpg"), &big).unwrap();
        fs::write(root.join("assets/FLAT-UUID.jpg"), &big).unwrap();
        fs::write(root.join("assets/done.jpg"), &big).unwrap();
        fs::write(root.join("assets/._tmp_leftover.jpg"), &big).unwrap();
        fs::write(root.join("assets/anim.gif"), b"GIF89a").unwrap();
        let tiny = encode(&DynamicImage::ImageRgb8(RgbImage::new(2, 2)), ImageFormat::Png).unwrap();
        fs::write(root.join("assets/tiny.png"), &tiny).unwrap();
        fs::create_dir_all(root.join(".nook")).unwrap();
        fs::write(root.join(".nook/datasaver-phone.json"), r#"{"savedBytes":5,"assets":["done"]}"#).unwrap();

        let mut calls = Vec::new();
        let rep = compress_existing(root, "desk", &mut |d, t| calls.push((d, t))).unwrap();
        assert_eq!(rep.images, 2, "{rep:?}");
        assert!(rep.saved_bytes > 0);
        assert!(rep.errors.is_empty());
        assert_eq!(calls.last(), Some(&(3, 3)));
        assert_eq!(fs::read(root.join("assets/done.jpg")).unwrap(), big);
        let l = read_ledger(root, "desk");
        assert_eq!(l.saved_bytes, rep.saved_bytes);
        let mut ids = l.assets.clone();
        ids.sort();
        assert_eq!(ids, vec!["2026/09/a", "FLAT-UUID", "tiny"]);
        assert_eq!(data_saved_total(root), rep.saved_bytes + 5);
        // second run: nothing to do
        let rep2 = compress_existing(root, "desk", &mut |_, _| {}).unwrap();
        assert_eq!(rep2, CompressReport::default());
        let json = serde_json::to_string(&rep).unwrap();
        assert!(json.contains("heicConverted") && json.contains("skippedMissingTools") && json.contains("savedBytes"));
    }

    #[test]
    fn on_attach_behaviour() {
        let big = encode_jpeg_q(&photo_like(3000, 2000), 95);
        let (b, e) = on_attach(&big, "JPG", true);
        assert!(b.len() < big.len());
        assert_eq!(e, "JPG");
        let (b, _) = on_attach(&big, "jpg", false);
        assert_eq!(b, big);
        let (b, e) = on_attach(b"not really", "gif", true);
        assert_eq!((b.as_slice(), e.as_str()), (&b"not really"[..], "gif"));
        // Bogus HEIC bytes: conversion fails (or no tool) -> original back.
        let (b, e) = on_attach(b"bogus heic", "heic", true);
        assert_eq!((b.as_slice(), e.as_str()), (&b"bogus heic"[..], "heic"));
    }

    #[test]
    fn human_bytes_format() {
        assert_eq!(human_bytes(0), "Zero KB");
        assert_eq!(human_bytes(1), "1 byte");
        assert_eq!(human_bytes(999), "999 bytes");
        assert_eq!(human_bytes(1000), "1 KB");
        assert_eq!(human_bytes(1_540), "1.5 KB");
        assert_eq!(human_bytes(12_345_678), "12.3 MB");
        assert_eq!(human_bytes(999_960), "1 MB");
        assert_eq!(human_bytes(2_000_000_000), "2 GB");
        assert_eq!(human_bytes(-1_500_000), "-1.5 MB");
    }

    #[test]
    fn tool_probe_does_not_panic() {
        let t = tools();
        let _ = serde_json::to_string(&t).unwrap();
    }

    // ---- ffmpeg-dependent (skipped when ffmpeg is absent) ----

    fn ffmpeg() -> Option<PathBuf> {
        let p = find_in_path("ffmpeg");
        if p.is_none() {
            eprintln!("ffmpeg not installed; skipping");
        }
        p
    }

    fn gen(args: &[&str]) {
        let st = Command::new("ffmpeg")
            .args(["-hide_banner", "-loglevel", "error", "-nostdin", "-y"])
            .args(args)
            .status()
            .unwrap();
        assert!(st.success(), "ffmpeg gen failed: {args:?}");
    }

    fn probe_dims(p: &Path) -> (u32, u32) {
        let out = Command::new("ffprobe")
            .args(["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x"])
            .arg(p)
            .output()
            .unwrap();
        let s = String::from_utf8_lossy(&out.stdout);
        let mut it = s.trim().split('x').map(|v| v.parse::<u32>().unwrap());
        (it.next().unwrap(), it.next().unwrap())
    }

    fn make_video(path: &Path, size: &str) {
        let p = path.to_str().unwrap();
        gen(&[
            "-f", "lavfi", "-i", &format!("testsrc=duration=2:size={size}:rate=30"),
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-c:v", "mpeg4", "-q:v", "1", "-c:a", "aac", "-b:a", "256k", "-shortest", p,
        ]);
    }

    #[test]
    fn video_landscape_portrait_odd() {
        if ffmpeg().is_none() || find_in_path("ffprobe").is_none() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        for (name, size, want) in [
            ("land.mp4", "1920x1080", (1280, 720)),
            ("port.mov", "1080x1920", (720, 1280)),
            ("square.m4v", "1500x1500", (1280, 1280)),
            ("small.mp4", "641x361", (640, 362)), // odd source made even, never upscaled
        ] {
            let p = dir.path().join(name);
            make_video(&p, size);
            let before = file_len(&p);
            let res = compress_file_in_place(&p).unwrap();
            let saved = res.unwrap_or_else(|| panic!("{name} should shrink"));
            assert_eq!(file_len(&p), before - saved);
            assert_eq!(probe_dims(&p), want, "{name}");
        }
        // no temp files left behind
        let leftovers: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with(TMP_PREFIX))
            .collect();
        assert!(leftovers.is_empty());
    }

    #[test]
    fn audio_m4a_and_ogg() {
        if ffmpeg().is_none() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let m4a = dir.path().join("a.m4a");
        gen(&["-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-ac", "2", "-c:a", "aac", "-b:a", "256k", m4a.to_str().unwrap()]);
        assert!(compress_file_in_place(&m4a).unwrap().is_some());
        let ogg = dir.path().join("b.ogg");
        gen(&["-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-ac", "2", "-c:a", "libopus", "-b:a", "256k", ogg.to_str().unwrap()]);
        assert!(compress_file_in_place(&ogg).unwrap().is_some());
        let webm = dir.path().join("c.webm");
        gen(&["-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-ac", "2", "-c:a", "libopus", "-b:a", "256k", webm.to_str().unwrap()]);
        assert!(compress_file_in_place(&webm).unwrap().is_some());
        // already-small file: not replaced, temp cleaned up
        let small = dir.path().join("d.m4a");
        gen(&["-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-ac", "1", "-c:a", "aac", "-b:a", "24k", small.to_str().unwrap()]);
        let before = fs::read(&small).unwrap();
        assert_eq!(compress_file_in_place(&small).unwrap(), None);
        assert_eq!(fs::read(&small).unwrap(), before);
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 4);
    }

    /// Real HEIC end-to-end; set QUIRE_TEST_HEIC=/path/to/sample.heic to run.
    #[test]
    fn heic_end_to_end() {
        let Some(sample) = std::env::var_os("QUIRE_TEST_HEIC").map(PathBuf::from) else { return };
        if !tools().heif {
            eprintln!("no HEIC tool; skipping");
            return;
        }
        let bytes = fs::read(&sample).unwrap();
        let (jpg, ext) = on_attach(&bytes, "HEIC", true);
        assert_eq!(ext, "jpg");
        assert_eq!(image::guess_format(&jpg).unwrap(), ImageFormat::Jpeg);
        assert!(dims(&jpg).0.max(dims(&jpg).1) <= MAX_IMAGE_EDGE);

        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("assets/2026/09")).unwrap();
        fs::create_dir_all(root.join("journal/2026/09")).unwrap();
        fs::copy(&sample, root.join("assets/2026/09/p.heic")).unwrap();
        fs::write(root.join("journal/2026/09/30.md"), "![](../../../assets/2026/09/p.heic)").unwrap();
        let rep = compress_existing(root, "d", &mut |_, _| {}).unwrap();
        assert_eq!(rep.heic_converted, 1, "{rep:?}");
        assert!(!root.join("assets/2026/09/p.heic").exists());
        assert!(root.join("assets/2026/09/p.jpg").exists());
        assert_eq!(fs::read_to_string(root.join("journal/2026/09/30.md")).unwrap(), "![](../../../assets/2026/09/p.jpg)");
        assert!(read_ledger(root, "d").assets.contains(&"2026/09/p".to_string()));
        let leftovers = fs::read_dir(root.join("assets/2026/09")).unwrap().count();
        assert_eq!(leftovers, 1);
    }

    #[test]
    fn compress_existing_with_video() {
        if ffmpeg().is_none() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("assets/2026/09")).unwrap();
        make_video(&root.join("assets/2026/09/clip.mov"), "1280x720");
        let rep = compress_existing(root, "d", &mut |_, _| {}).unwrap();
        assert_eq!(rep.videos, 1, "{rep:?}");
        assert!(read_ledger(root, "d").assets.contains(&"2026/09/clip".to_string()));
    }
}

/// Temp files are created 0600; give the replacement the original file's
/// mode (or 0644 for a new file) so other apps and sync tools can read it.
fn keep_mode(tmp: &Path, original: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(original).map(|m| m.permissions().mode() & 0o777).unwrap_or(0o644) | 0o444;
        let _ = fs::set_permissions(tmp, fs::Permissions::from_mode(mode));
    }
    #[cfg(not(unix))]
    let _ = (tmp, original);
}
