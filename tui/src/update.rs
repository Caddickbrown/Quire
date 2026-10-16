//! `quire update` (also `jnl update`): bring the terminal app and the desktop
//! AppImage up to the latest GitHub release. Release builds of the terminal
//! app carry their target triple (QUIRE_RELEASE_TARGET, set by
//! .github/workflows/release.yml); any other build came from source and is
//! pointed at install.sh instead. The AppImage is found from its launcher
//! entry and replaced when its SHA-256 isn't the release's; a .deb or .rpm is
//! left to the package manager. Runs only when asked: Quire never checks in
//! the background.

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

/// `quire update [--check] [--terminal | --desktop]`. Both apps by default.
/// Returns the exit code.
pub fn run(args: &[String]) -> i32 {
    let has = |f: &str| args.iter().any(|a| a == f);
    let (terminal, desktop) = match (has("--terminal"), has("--desktop")) {
        (true, false) => (true, false),
        (false, true) => (false, true),
        _ => (true, true),
    };
    let check_only = has("--check");
    let result = latest(&agent()).and_then(|rel| {
        let agent = agent();
        let mut failed = None;
        if terminal {
            if let Err(e) = update_terminal(&agent, &rel, check_only) {
                eprintln!("  {e}");
                failed = Some(());
            }
        }
        if desktop {
            if let Err(e) = update_desktop(&agent, &rel, check_only, !terminal) {
                eprintln!("  Desktop app: {e}");
                failed = Some(());
            }
        }
        failed.map_or(Ok(()), |_| Err(String::new()))
    });
    match result {
        Ok(()) => 0,
        Err(e) => {
            if !e.is_empty() {
                eprintln!("  {e}");
            }
            1
        }
    }
}

fn url_of(rel: &Release, name: &str) -> Option<String> {
    rel.assets.iter().find(|a| a.name == name).map(|a| a.browser_download_url.clone())
}

fn update_terminal(agent: &ureq::Agent, rel: &Release, check_only: bool) -> Result<(), String> {
    let current = env!("CARGO_PKG_VERSION");
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
    let tar_url = url_of(rel, &name).ok_or_else(|| format!("Release {version} has no build for {target}"))?;
    let sum_url = url_of(rel, &format!("{name}.sha256")).ok_or_else(|| format!("Release {version} has no checksum for {name}"))?;
    let dir = install_dir()?;
    println!("  Downloading {name}…");
    let sums = String::from_utf8(download(agent, &sum_url)?).map_err(|_| "The checksum file isn't text".to_string())?;
    let want = expected_digest(&sums).ok_or("The checksum file has no SHA-256 digest")?;
    let tarball = download(agent, &tar_url)?;
    if hex_sha256(&tarball) != want {
        return Err("The download doesn't match its checksum; nothing was changed.".into());
    }
    replace_bins(&dir, &unpack(&tarball)?)?;
    println!("  ✓ Quire {version} installed in {}.", dir.display());
    Ok(())
}

// ---------- the desktop app ----------

/// How the desktop app is installed on this machine.
#[derive(Debug, PartialEq)]
pub enum Desktop {
    AppImage(PathBuf),
    /// "deb" or "rpm", with the installed version when the package manager says.
    Package(&'static str, Option<String>),
    None,
}

/// The machine's architecture as the release names it: x86_64 or aarch64.
fn arch() -> &'static str {
    match RELEASE_TARGET.map(|t| t.split('-').next().unwrap_or("")).unwrap_or(std::env::consts::ARCH) {
        "aarch64" => "aarch64",
        _ => "x86_64",
    }
}

/// The desktop release file for a version, architecture and kind.
pub fn desktop_asset(version: &str, arch: &str, kind: &str) -> String {
    let deb_arch = if arch == "aarch64" { "arm64" } else { "amd64" };
    match kind {
        "deb" => format!("Quire_{version}_{deb_arch}.deb"),
        "rpm" => format!("Quire-{version}-1.{arch}.rpm"),
        _ => format!("Quire_{version}_{}.AppImage", if arch == "aarch64" { "aarch64" } else { "amd64" }),
    }
}

/// The AppImage a launcher entry starts (install.sh writes
/// `Exec=/path/Quire.AppImage`, or `Exec=env APPIMAGE_EXTRACT_AND_RUN=1 /path`).
pub fn appimage_in_entry(entry: &str) -> Option<PathBuf> {
    let exec = entry.lines().find_map(|l| l.trim().strip_prefix("Exec="))?;
    exec.split_whitespace().find(|w| w.ends_with(".AppImage")).map(PathBuf::from)
}

/// The digest listed for `name` in a `sha256sum` listing.
pub fn digest_for(sums: &str, name: &str) -> Option<String> {
    sums.lines().find_map(|l| {
        let mut it = l.split_whitespace();
        let (d, n) = (it.next()?, it.next()?);
        (n.trim_start_matches('*') == name).then(|| d.to_ascii_lowercase())
    })
}

fn find_desktop() -> Desktop {
    if let Some(p) = std::env::var_os("QUIRE_APPIMAGE").map(PathBuf::from).filter(|p| p.is_file()) {
        return Desktop::AppImage(p);
    }
    let data = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).or_else(|| dirs::home_dir().map(|h| h.join(".local/share")));
    if let Some(p) = data
        .and_then(|d| std::fs::read_to_string(d.join("applications/quire.desktop")).ok())
        .and_then(|e| appimage_in_entry(&e))
        .filter(|p| p.is_file())
    {
        return Desktop::AppImage(p);
    }
    if let Some(p) = dirs::home_dir().map(|h| h.join("Applications/Quire.AppImage")).filter(|p| p.is_file()) {
        return Desktop::AppImage(p);
    }
    if Path::new("/usr/bin/quire-desktop").exists() {
        let out = |cmd: &str, args: &[&str]| {
            std::process::Command::new(cmd).args(args).output().ok().filter(|o| o.status.success()).map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        };
        if let Some(v) = out("dpkg-query", &["-W", "-f=${Version}", "quire"]) {
            return Desktop::Package("deb", Some(v).filter(|v| !v.is_empty()));
        }
        return Desktop::Package("rpm", out("rpm", &["-q", "--qf", "%{VERSION}", "quire"]));
    }
    Desktop::None
}

/// `asked`: the desktop app alone was asked for, so say so when there is none.
fn update_desktop(agent: &ureq::Agent, rel: &Release, check_only: bool, asked: bool) -> Result<(), String> {
    let version = rel.tag_name.trim_start_matches('v');
    match find_desktop() {
        Desktop::None => {
            if asked {
                println!("  No Quire desktop app found (looked for the AppImage in ~/Applications and its launcher entry).");
            }
            Ok(())
        }
        Desktop::Package(kind, installed) => {
            if installed.as_deref().is_some_and(|v| !is_newer(version, v)) {
                println!("  Desktop app ({kind}) is up to date.");
                return Ok(());
            }
            let file = desktop_asset(version, arch(), kind);
            let how = if kind == "deb" { format!("sudo apt install ./{file}") } else { format!("sudo dnf install ./{file}") };
            println!("  Desktop app: Quire {version} is out as a .{kind}, which your package manager installs:");
            println!("    {}
    {how}", url_of(rel, &file).unwrap_or_else(|| format!("https://github.com/{REPO}/releases/latest")));
            println!("  Or re-run the installer to switch to the AppImage, which `quire update` keeps current.");
            Ok(())
        }
        Desktop::AppImage(path) => {
            let file = desktop_asset(version, arch(), "appimage");
            let sums_name = format!("SHA256SUMS-desktop-{}", arch());
            let sums_url = url_of(rel, &sums_name).ok_or_else(|| format!("release {version} has no {sums_name}"))?;
            let sums = String::from_utf8(download(agent, &sums_url)?).map_err(|_| "the checksum file isn't text".to_string())?;
            let want = digest_for(&sums, &file).ok_or_else(|| format!("{sums_name} doesn't list {file}"))?;
            let have = std::fs::read(&path).map(|b| hex_sha256(&b)).map_err(|e| format!("can't read {}: {e}", path.display()))?;
            if have == want {
                println!("  Desktop app (AppImage) is up to date.");
                return Ok(());
            }
            println!("  Desktop app: Quire {version} is out for {}.", path.display());
            if check_only {
                return Ok(());
            }
            let url = url_of(rel, &file).ok_or_else(|| format!("release {version} has no {file}"))?;
            println!("  Downloading {file}…");
            let bytes = download(agent, &url)?;
            if hex_sha256(&bytes) != want {
                return Err("the download doesn't match its checksum; nothing was changed.".into());
            }
            replace_file(&path, &bytes)?;
            println!("  ✓ Desktop app updated to {version}. If it's open, restart it.");
            Ok(())
        }
    }
}

/// Write `bytes` over `path` by a temporary file and a rename (executable).
pub fn replace_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("Quire.AppImage");
    let tmp = path.with_file_name(format!(".{name}.update"));
    std::fs::write(&tmp, bytes)
        .and_then(|_| std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755)))
        .and_then(|_| std::fs::rename(&tmp, path))
        .map_err(|e| {
            let _ = std::fs::remove_file(&tmp);
            format!("can't write {}: {e}", path.display())
        })
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
    fn desktop_files() {
        assert_eq!(desktop_asset("0.8.1", "x86_64", "appimage"), "Quire_0.8.1_amd64.AppImage");
        assert_eq!(desktop_asset("0.8.1", "aarch64", "appimage"), "Quire_0.8.1_aarch64.AppImage");
        assert_eq!(desktop_asset("0.8.1", "aarch64", "deb"), "Quire_0.8.1_arm64.deb");
        assert_eq!(desktop_asset("0.8.1", "x86_64", "rpm"), "Quire-0.8.1-1.x86_64.rpm");
        let entry = "[Desktop Entry]\nName=Quire\nExec=env APPIMAGE_EXTRACT_AND_RUN=1 /home/a/Applications/Quire.AppImage\n";
        assert_eq!(appimage_in_entry(entry), Some(PathBuf::from("/home/a/Applications/Quire.AppImage")));
        assert_eq!(appimage_in_entry("Exec=/usr/bin/quire-desktop\n"), None);
        let sums = "AB12  Quire_0.8.1_amd64.AppImage\ncd34 *Quire_0.8.1_amd64.deb\n";
        assert_eq!(digest_for(sums, "Quire_0.8.1_amd64.AppImage").as_deref(), Some("ab12"));
        assert_eq!(digest_for(sums, "Quire_0.8.1_amd64.deb").as_deref(), Some("cd34"));
        assert_eq!(digest_for(sums, "nope"), None);
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("Quire.AppImage");
        std::fs::write(&p, "old").unwrap();
        replace_file(&p, b"new").unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "new");
        assert!(!d.path().join(".Quire.AppImage.update").exists());
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
