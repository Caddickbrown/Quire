//! `quire update` (also `jnl update`): replace the terminal app with the
//! latest GitHub release. Release builds carry their target triple
//! (QUIRE_RELEASE_TARGET, set by .github/workflows/release.yml); any other
//! build came from source and is pointed at install.sh instead. Runs only
//! when asked: Quire never checks in the background.

use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::{Path, PathBuf};

const REPO: &str = "Caddickbrown/Quire";
const INSTALL: &str = "curl -fsSL https://raw.githubusercontent.com/Caddickbrown/Quire/main/install.sh | bash -s -- --tui";
/// The target triple of a release build; None for a source build.
pub const RELEASE_TARGET: Option<&str> = option_env!("QUIRE_RELEASE_TARGET");
/// The binaries in each release tarball, installed side by side.
const BINS: [&str; 2] = ["quire", "jnl"];

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    #[serde(default)]
    body: String,
    #[serde(default)]
    assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
}

/// The release tarball for a target: version-less, so
/// `releases/latest/download/<name>` always names the newest one.
pub fn asset_name(target: &str) -> String {
    format!("quire-{target}.tar.gz")
}

/// `v0.7.1` or `0.7.1` → (0, 7, 1). A pre-release suffix is ignored.
pub fn parse_version(s: &str) -> Option<(u64, u64, u64)> {
    let core = s.trim().trim_start_matches('v').split(['-', '+']).next()?;
    let mut it = core.split('.').map(|p| p.parse::<u64>().ok());
    let v = (it.next()??, it.next()??, it.next()??);
    it.next().is_none().then_some(v)
}

pub fn is_newer(latest: &str, current: &str) -> bool {
    matches!((parse_version(latest), parse_version(current)), (Some(l), Some(c)) if l > c)
}

fn agent() -> ureq::Agent {
    use ureq::tls::{RootCerts, TlsConfig};
    // The system's certificates, so a proxy's CA (work networks) is trusted too.
    ureq::Agent::config_builder()
        .tls_config(TlsConfig::builder().root_certs(RootCerts::PlatformVerifier).build())
        .user_agent(concat!("quire/", env!("CARGO_PKG_VERSION")))
        // download() follows redirects itself; see there.
        .max_redirects(0)
        .build()
        .new_agent()
}

fn latest(agent: &ureq::Agent) -> Result<Release, String> {
    let url = format!("https://api.github.com/repos/{REPO}/releases/latest");
    let mut res = agent
        .get(&url)
        .header("Accept", "application/vnd.github+json")
        .call()
        .map_err(|e| match e {
            ureq::Error::StatusCode(404) => "No release has been published yet.".to_string(),
            e => format!("Couldn't reach GitHub: {e}"),
        })?;
    res.body_mut().read_json().map_err(|e| format!("GitHub's reply didn't parse: {e}"))
}

/// GitHub serves a release file by redirecting to another host. Letting ureq
/// follow that redirect failed reading the second response ("chunk expected
/// crlf") behind an HTTPS proxy; reading the redirect's body and following
/// it by hand works.
fn download(agent: &ureq::Agent, url: &str) -> Result<Vec<u8>, String> {
    let fail = |e: ureq::Error| format!("Download failed: {e}");
    let mut url = url.to_string();
    for _ in 0..5 {
        let mut res = agent.get(&url).call().map_err(fail)?;
        if res.status().is_redirection() {
            let next = res.headers().get("location").and_then(|v| v.to_str().ok()).map(str::to_string);
            let _ = res.body_mut().read_to_vec();
            url = next.ok_or("Download failed: a redirect with nowhere to go")?;
            continue;
        }
        return res.body_mut().with_config().limit(200 * 1024 * 1024).read_to_vec().map_err(fail);
    }
    Err("Download failed: too many redirects".into())
}

/// The hex digest at the start of a `sha256sum` line.
pub fn expected_digest(sums: &str) -> Option<String> {
    let d = sums.split_whitespace().next()?.to_ascii_lowercase();
    (d.len() == 64 && d.bytes().all(|b| b.is_ascii_hexdigit())).then_some(d)
}

pub fn hex_sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// The named binaries from a release tarball, by file name (any directory).
pub fn unpack(tarball: &[u8]) -> Result<Vec<(String, Vec<u8>)>, String> {
    let mut out = Vec::new();
    let mut ar = tar::Archive::new(flate2::read::GzDecoder::new(tarball));
    for entry in ar.entries().map_err(|e| format!("Bad tarball: {e}"))? {
        let mut entry = entry.map_err(|e| format!("Bad tarball: {e}"))?;
        let path = entry.path().map_err(|e| format!("Bad tarball: {e}"))?.into_owned();
        let Some(name) = path.file_name().and_then(|n| n.to_str()).map(str::to_string) else { continue };
        if BINS.contains(&name.as_str()) && entry.header().entry_type().is_file() {
            let mut data = Vec::new();
            entry.read_to_end(&mut data).map_err(|e| format!("Bad tarball: {e}"))?;
            out.push((name, data));
        }
    }
    for b in BINS {
        if !out.iter().any(|(n, _)| n == b) {
            return Err(format!("The release tarball has no {b}"));
        }
    }
    Ok(out)
}

/// Write each binary beside the running one: a temporary file, then a
/// rename over the old name, so a failure never leaves half a binary and the
/// running process keeps its own (now unlinked) copy.
pub fn replace_bins(dir: &Path, bins: &[(String, Vec<u8>)]) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    for (name, data) in bins {
        let tmp = dir.join(format!(".{name}.update"));
        let dest = dir.join(name);
        std::fs::write(&tmp, data)
            .and_then(|_| std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755)))
            .and_then(|_| std::fs::rename(&tmp, &dest))
            .map_err(|e| {
                let _ = std::fs::remove_file(&tmp);
                format!("Can't write {}: {e}", dest.display())
            })?;
    }
    Ok(())
}

fn install_dir() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().and_then(|p| p.canonicalize()).map_err(|e| format!("Can't find this program: {e}"))?;
    exe.parent().map(Path::to_path_buf).ok_or_else(|| "Can't find this program's folder".into())
}

/// The first few lines of the release notes.
fn notes_preview(body: &str) -> String {
    let lines: Vec<&str> = body.lines().filter(|l| !l.trim().is_empty()).collect();
    let mut s: String = lines.iter().take(12).map(|l| format!("    {l}\n")).collect();
    if lines.len() > 12 {
        s.push_str("    …\n");
    }
    s
}

/// `quire update [--check]`. Returns the exit code.
pub fn run(args: &[String]) -> i32 {
    match update(args.iter().any(|a| a == "--check")) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("  {e}");
            1
        }
    }
}

fn update(check_only: bool) -> Result<(), String> {
    let current = env!("CARGO_PKG_VERSION");
    let agent = agent();
    let rel = latest(&agent)?;
    let version = rel.tag_name.trim_start_matches('v');
    if !is_newer(version, current) {
        println!("  Quire {current} is up to date.");
        return Ok(());
    }
    println!("  Quire {version} is out (you have {current}).");
    print!("{}", notes_preview(&rel.body));
    if check_only {
        println!("  Run `quire update` to install it.");
        return Ok(());
    }
    let Some(target) = RELEASE_TARGET else {
        println!("  This copy was built from source. To update it, re-run the installer:\n    {INSTALL}");
        return Ok(());
    };
    let name = asset_name(target);
    let url_of = |n: &str| rel.assets.iter().find(|a| a.name == n).map(|a| a.browser_download_url.clone());
    let tar_url = url_of(&name).ok_or_else(|| format!("Release {version} has no build for {target}"))?;
    let sum_url = url_of(&format!("{name}.sha256")).ok_or_else(|| format!("Release {version} has no checksum for {name}"))?;
    let dir = install_dir()?;
    println!("  Downloading {name}…");
    let sums = String::from_utf8(download(&agent, &sum_url)?).map_err(|_| "The checksum file isn't text".to_string())?;
    let want = expected_digest(&sums).ok_or("The checksum file has no SHA-256 digest")?;
    let tarball = download(&agent, &tar_url)?;
    if hex_sha256(&tarball) != want {
        return Err("The download doesn't match its checksum; nothing was changed.".into());
    }
    replace_bins(&dir, &unpack(&tarball)?)?;
    println!("  ✓ Quire {version} installed in {}.", dir.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions() {
        assert_eq!(parse_version("v0.7.1"), Some((0, 7, 1)));
        assert_eq!(parse_version("1.2.3-rc.1"), Some((1, 2, 3)));
        assert_eq!(parse_version("1.2"), None);
        assert_eq!(parse_version("1.2.3.4"), None);
        assert!(is_newer("0.7.1", "0.7.0"));
        assert!(is_newer("0.10.0", "0.9.9"));
        assert!(!is_newer("0.7.0", "0.7.0"));
        assert!(!is_newer("0.6.9", "0.7.0"));
        assert!(!is_newer("junk", "0.7.0"));
    }

    #[test]
    fn digests() {
        let d = hex_sha256(b"quire");
        assert_eq!(d.len(), 64);
        assert_eq!(expected_digest(&format!("{}  quire-x.tar.gz\n", d.to_uppercase())), Some(d));
        assert_eq!(expected_digest("nope"), None);
    }

    fn tarball(names: &[&str]) -> Vec<u8> {
        let mut b = tar::Builder::new(flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast()));
        for n in names {
            let data = format!("#!{n}");
            let mut h = tar::Header::new_gnu();
            h.set_size(data.len() as u64);
            h.set_mode(0o755);
            h.set_cksum();
            b.append_data(&mut h, format!("quire-x86_64-unknown-linux-gnu/{n}"), data.as_bytes()).unwrap();
        }
        b.into_inner().unwrap().finish().unwrap()
    }

    #[test]
    fn unpack_and_replace() {
        let bins = unpack(&tarball(&["quire", "jnl", "README.md"])).unwrap();
        assert_eq!(bins.iter().map(|b| b.0.as_str()).collect::<Vec<_>>(), ["quire", "jnl"]);
        assert!(unpack(&tarball(&["quire"])).unwrap_err().contains("no jnl"));
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("quire"), "old").unwrap();
        replace_bins(d.path(), &bins).unwrap();
        assert_eq!(std::fs::read_to_string(d.path().join("quire")).unwrap(), "#!quire");
        assert_eq!(std::fs::read_to_string(d.path().join("jnl")).unwrap(), "#!jnl");
        assert!(!d.path().join(".quire.update").exists());
    }
}
