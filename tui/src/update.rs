//! `quire update` (also `jnl update`): bring the terminal app and the desktop
//! AppImage up to the latest GitHub release. Release builds of the terminal
//! app carry their target triple (QUIRE_RELEASE_TARGET, set by
//! .github/workflows/release.yml); any other build came from source (every
//! Mac, for now), and rebuilds itself from the release's tag with cargo, or is
//! pointed at install.sh when it can't. The AppImage is found from its launcher
//! entry and replaced when its SHA-256 isn't the release's; a .deb or .rpm is
//! left to the package manager. `--main` skips releases and builds the terminal
//! app from the main branch with cargo. Runs only when asked: Quire never checks
//! in the background.

use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::{Path, PathBuf};

/// Where releases are published: a public repository holding only the
/// releases and install.sh, so the source repository can be private.
/// (1.0.0 and older read Caddickbrown/Quire's releases; 1.0.1 was published
/// to both, so they update once from there and then read this one.)
pub const RELEASE_REPO: &str = "Caddickbrown/quire-release";
/// The source, which `cargo install` builds from (a source build, `--main`).
pub const SOURCE_REPO: &str = "Caddickbrown/Quire";
const INSTALL: &str = "curl -fsSL https://raw.githubusercontent.com/Caddickbrown/quire-release/main/install.sh | bash -s -- --tui";
/// The target triple of a release build; None for a source build.
pub const RELEASE_TARGET: Option<&str> = option_env!("QUIRE_RELEASE_TARGET");
/// The longest one request may take, start to last byte (the AppImage is
/// about 100 MB).
const DOWNLOAD_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15 * 60);
/// The key releases are signed with: `plugins.updater.pubkey` in
/// linux/src-tauri/tauri.conf.json (base64 of a minisign public-key file),
/// the same one the desktop app's own updater checks. A test holds the two
/// together.
const UPDATER_PUBKEY: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IEE1N0VDMjcxOTg0ODcxNUMKUldSY2NVaVljY0orcGFuRXQzZTNhUzduZnU2dXhjTkF0eWd0Z1ZTZGVCMXkxdklOSnREQlhWQzAK";
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
        // The whole of one request, body included: a connection that stalls
        // mid-download ends in an error instead of hanging for good.
        .timeout_connect(Some(std::time::Duration::from_secs(30)))
        .timeout_global(Some(DOWNLOAD_TIMEOUT))
        .build()
        .new_agent()
}

/// The GitHub API address of the latest release.
pub fn latest_url() -> String {
    format!("https://api.github.com/repos/{RELEASE_REPO}/releases/latest")
}

fn latest(agent: &ureq::Agent) -> Result<Release, String> {
    let url = latest_url();
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
        // The first address and every one a redirect names: https, and GitHub's.
        if !download_host_ok(&url) {
            return Err(format!("Download failed: {} is not an https address at GitHub; nothing was fetched from it.", url.split(['?', '#']).next().unwrap_or(&url)));
        }
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

/// Where a release file may come from: `https://` and a host of GitHub's
/// (github.com, or a name under it or under githubusercontent.com, where
/// release files are served). A redirect to plain http, to another site or
/// to a relative path is refused, not followed.
pub fn download_host_ok(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://") else { return false };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    // No user:password@ part, which can dress another host up as GitHub.
    if authority.contains('@') {
        return false;
    }
    let host = authority.strip_suffix(":443").unwrap_or(authority).to_ascii_lowercase();
    host == "github.com" || host.ends_with(".github.com") || host.ends_with(".githubusercontent.com")
}

/// The hex digest at the start of a `sha256sum` line.
pub fn expected_digest(sums: &str) -> Option<String> {
    let d = sums.split_whitespace().next()?.to_ascii_lowercase();
    (d.len() == 64 && d.bytes().all(|b| b.is_ascii_hexdigit())).then_some(d)
}

pub fn hex_sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// Is `sig` (a release's `<file>.sig`: base64 of a minisign signature, as
/// `tauri signer sign` writes it) a signature of `bytes` by `pubkey` (base64
/// of a minisign public-key file)?
pub fn verify_signature(pubkey: &str, bytes: &[u8], sig: &str) -> Result<(), String> {
    use base64::Engine;
    let text = |b64: &str, what: &str| {
        base64::engine::general_purpose::STANDARD.decode(b64.trim()).ok().and_then(|b| String::from_utf8(b).ok()).ok_or_else(|| format!("the {what} isn't readable"))
    };
    let key = minisign_verify::PublicKey::decode(&text(pubkey, "signing key")?).map_err(|e| format!("the signing key isn't readable: {e}"))?;
    let sig = minisign_verify::Signature::decode(&text(sig, "signature")?).map_err(|e| format!("the signature isn't readable: {e}"))?;
    key.verify(bytes, &sig, true).map_err(|e| format!("the signature doesn't match: {e}"))
}

/// Check a downloaded release file against its `.sig`. A signature that
/// fails, or none at all, stops the update: the SHA-256 comes from the same
/// release, so on its own it says nothing about who made it. (Releases from
/// 0.11.0 and older have no signatures; they are installed by hand.)
fn check_signature(agent: &ureq::Agent, rel: &Release, name: &str, bytes: &[u8]) -> Result<(), String> {
    let Some(url) = url_of(rel, &format!("{name}.sig")) else {
        return Err(format!(
            "release {} has no signature for {name}, so it can't be checked; nothing was changed.",
            rel.tag_name
        ));
    };
    let sig = String::from_utf8(download(agent, &url)?).map_err(|_| format!("The signature of {name} isn't text; nothing was changed."))?;
    verify_signature(UPDATER_PUBKEY, bytes, &sig).map_err(|e| format!("{name} is not signed by Quire's release key ({e}); nothing was changed."))
}

/// What a terminal tarball's `<file>.release.sig` signs: the release's tag,
/// the file's name and its SHA-256, one per line. The tarball's own `.sig`
/// covers its bytes only, and its name carries no version, so an older
/// signed tarball uploaded under a new tag passed as the new release. This
/// one names the tag. .github/workflows/release.yml writes the same text,
/// byte for byte; a test holds the format.
pub fn release_statement(tag: &str, name: &str, bytes: &[u8]) -> String {
    format!("Quire release file\ntag: {tag}\nfile: {name}\nsha256: {}\n", hex_sha256(bytes))
}

/// Check a downloaded terminal tarball against its `.release.sig`: signed by
/// the release key for this release's tag and this file name. None at all
/// stops the update too. (Releases made before this check have only the bytes' `.sig`;
/// a client from before this change still checks that one, which every
/// release keeps publishing.)
fn check_release_signature(agent: &ureq::Agent, rel: &Release, name: &str, bytes: &[u8]) -> Result<(), String> {
    let sig_name = format!("{name}.release.sig");
    let Some(url) = url_of(rel, &sig_name) else {
        return Err(format!(
            "release {} has no {sig_name}, so it can't be checked as this release's; nothing was changed.",
            rel.tag_name
        ));
    };
    let sig = String::from_utf8(download(agent, &url)?).map_err(|_| format!("{sig_name} isn't text; nothing was changed."))?;
    verify_signature(UPDATER_PUBKEY, release_statement(&rel.tag_name, name, bytes).as_bytes(), &sig).map_err(|e| {
        format!("{name} is not signed by Quire's release key as release {}'s ({e}); nothing was changed.", rel.tag_name)
    })
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

/// Write `data` to a new file beside `dest` and return its path: a name no
/// one else has (`create_new`, so a leftover or a planted link is never
/// written through), executable, and on the disk before anything is renamed.
fn stage(dest: &Path, data: &[u8]) -> std::io::Result<PathBuf> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let name = dest.file_name().and_then(|n| n.to_str()).unwrap_or("quire");
    for _ in 0..16 {
        let tmp = dest.with_file_name(format!(".{name}.update-{:016x}", rand::random::<u64>()));
        let mut f = match std::fs::OpenOptions::new().write(true).create_new(true).mode(0o755).open(&tmp) {
            Ok(f) => f,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        };
        let written = f.write_all(data).and_then(|_| {
            use std::os::unix::fs::PermissionsExt;
            // The mode asked for above is cut down by the umask.
            f.set_permissions(std::fs::Permissions::from_mode(0o755))
        }).and_then(|_| f.sync_all());
        if let Err(e) = written {
            let _ = std::fs::remove_file(&tmp);
            return Err(e);
        }
        return Ok(tmp);
    }
    Err(std::io::Error::new(std::io::ErrorKind::AlreadyExists, "no free temporary name"))
}

fn sync_dir(dir: &Path) {
    if let Ok(d) = std::fs::File::open(dir) {
        let _ = d.sync_all();
    }
}

/// What every Quire terminal binary holds (the source repository's name; it
/// was also the release repository's up to 1.0.0), and an older jnl (the Go
/// CLI, the bash script) doesn't. Kept as it is when releases moved, so a
/// new binary still knows an old one as Quire's.
const QUIRE_MARK: &[u8] = b"Caddickbrown/Quire";

/// Whether the file at `path` is one of Quire's terminal binaries, judged by
/// its bytes. A link is judged by what it points at.
pub fn is_quires(path: &Path) -> bool {
    std::fs::read(path).is_ok_and(|b| b.windows(QUIRE_MARK.len()).any(|w| w == QUIRE_MARK))
}

/// Put the new binaries beside the running one. Every one is written in full
/// first, under a temporary name; only then is each renamed over the old
/// name, so a full disk or a failed write leaves both old binaries as they
/// were, never a new `quire` beside an old `jnl`. If a rename itself fails,
/// the ones already done are put back from a link to the old file. The
/// running process keeps its own (now unlinked) copy throughout. A file
/// already there that isn't Quire's (another `jnl`, put beside it by hand)
/// is never written over: the update stops first, with nothing changed.
pub fn replace_bins(dir: &Path, bins: &[(String, Vec<u8>)]) -> Result<(), String> {
    for (name, _) in bins {
        let dest = dir.join(name);
        if std::fs::symlink_metadata(&dest).is_ok() && !std::fs::metadata(&dest).is_ok_and(|m| m.is_dir()) && !is_quires(&dest) {
            return Err(format!(
                "{} isn't Quire's (another {name}?), so it wasn't replaced; nothing was changed. Move it elsewhere and run the update again.",
                dest.display()
            ));
        }
    }
    let mut staged: Vec<(PathBuf, PathBuf)> = Vec::new();
    let drop_staged = |staged: &[(PathBuf, PathBuf)]| staged.iter().for_each(|(tmp, _)| { let _ = std::fs::remove_file(tmp); });
    for (name, data) in bins {
        let dest = dir.join(name);
        match stage(&dest, data) {
            Ok(tmp) => staged.push((tmp, dest)),
            Err(e) => {
                drop_staged(&staged);
                return Err(format!("Can't write {}: {e}; nothing was changed.", dest.display()));
            }
        }
    }
    // The old binaries, kept under another name until every rename has worked.
    let old: Vec<Option<PathBuf>> = staged.iter().map(|(tmp, dest)| {
        let mut keep = tmp.clone().into_os_string();
        keep.push(".old");
        let keep = PathBuf::from(keep);
        std::fs::hard_link(dest, &keep).ok().map(|_| keep)
    }).collect();
    let mut failed = None;
    for (i, (tmp, dest)) in staged.iter().enumerate() {
        if let Err(e) = std::fs::rename(tmp, dest) {
            let mut undone = true;
            for (j, (_, done)) in staged.iter().enumerate().take(i) {
                undone &= old[j].as_ref().is_some_and(|keep| std::fs::rename(keep, done).is_ok());
            }
            let state = if i == 0 || undone { "nothing was changed" } else { "the earlier ones are already the new version: run the update again" };
            failed = Some(format!("Can't replace {}: {e}; {state}.", dest.display()));
            break;
        }
    }
    drop_staged(&staged);
    old.iter().flatten().for_each(|keep| { let _ = std::fs::remove_file(keep); });
    sync_dir(dir);
    failed.map_or(Ok(()), Err)
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

/// What `quire update` was asked to do.
#[derive(Debug, Default, PartialEq)]
pub struct Asked {
    pub check: bool,
    pub terminal: bool,
    pub desktop: bool,
    pub main: bool,
    pub help: bool,
}

/// The arguments, or the one that isn't known. Anything unknown stops the
/// command: `--chek` or `--dry-run` must never be read as "go ahead".
pub fn parse_args(args: &[String]) -> Result<Asked, String> {
    let mut asked = Asked::default();
    for a in args {
        match a.as_str() {
            "--check" => asked.check = true,
            "--terminal" => asked.terminal = true,
            "--desktop" => asked.desktop = true,
            "--main" => asked.main = true,
            "--help" | "-h" | "help" => asked.help = true,
            other => return Err(format!("update doesn't take {other:?}; nothing was done.")),
        }
    }
    Ok(asked)
}

const USAGE: &str = "
  quire update              install the latest release: the terminal app and the desktop AppImage
  quire update --check      only say whether there is one
  quire update --terminal   the terminal app only
  quire update --desktop    the desktop AppImage only
  quire update --main       build the terminal app from the latest code on main, with cargo
";

/// `quire update [--check] [--terminal | --desktop | --main]`. Both apps by
/// default. Returns the exit code.
pub fn run(args: &[String]) -> i32 {
    let asked = match parse_args(args) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("  {e}");
            eprint!("{USAGE}");
            return 2;
        }
    };
    if asked.help {
        print!("{USAGE}");
        return 0;
    }
    if asked.main {
        return match update_from_main(asked.desktop, asked.check) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("  {e}");
                1
            }
        };
    }
    let (terminal, desktop) = match (asked.terminal, asked.desktop) {
        (true, false) => (true, false),
        (false, true) => (false, true),
        _ => (true, true),
    };
    let check_only = asked.check;
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
        println!("  Terminal app: Quire {current} is up to date.");
        return Ok(());
    }
    println!("  Terminal app: Quire {version} is out (you have {current}).");
    print!("{}", notes_preview(&rel.body));
    if check_only {
        println!("  Run `quire update` to install it.");
        return Ok(());
    }
    let Some(target) = RELEASE_TARGET else {
        return rebuild_from_source(&rel.tag_name, version);
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
    check_release_signature(agent, rel, &name, &tarball)?;
    replace_bins(&dir, &unpack(&tarball)?)?;
    println!("  ✓ Quire {version} installed in {}.", dir.display());
    Ok(())
}

/// Where cargo should install to, given the folder this program runs from:
/// `--root` is the parent of a `bin` folder. Anywhere else, cargo can't put
/// the new binaries over these ones.
pub fn cargo_root(dir: &Path) -> Option<&Path> {
    (dir.file_name()? == "bin").then(|| dir.parent()).flatten()
}

/// What cargo builds: a release's tag, or the latest code on main.
#[derive(Clone, Copy)]
pub enum Revision<'a> {
    Tag(&'a str),
    Main,
}

/// The `cargo install` arguments that rebuild both binaries.
pub fn cargo_args(revision: Revision, root: &Path) -> Vec<String> {
    let mut args: Vec<String> = ["install", "--locked", "--force", "--git"].map(String::from).to_vec();
    args.push(format!("https://github.com/{SOURCE_REPO}"));
    match revision {
        Revision::Tag(tag) => args.extend(["--tag".to_string(), tag.to_string()]),
        Revision::Main => args.extend(["--branch".to_string(), "main".to_string()]),
    }
    args.push("--root".to_string());
    args.push(root.display().to_string());
    args.push("quire-tui".to_string());
    args
}

/// cargo from PATH, or where rustup puts it.
fn find_cargo() -> Option<PathBuf> {
    let works = |c: &Path| std::process::Command::new(c).arg("--version").output().is_ok_and(|o| o.status.success());
    let path = PathBuf::from("cargo");
    if works(&path) {
        return Some(path);
    }
    let home = std::env::var_os("CARGO_HOME").map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cargo")))?;
    Some(home.join("bin/cargo")).filter(|c| works(c))
}

/// A source build has no release file to download, so build the release's tag.
/// cargo only replaces the binaries once the build has worked.
fn rebuild_from_source(tag: &str, version: &str) -> Result<(), String> {
    let dir = install_dir()?;
    let (Some(cargo), Some(root)) = (find_cargo(), cargo_root(&dir)) else {
        println!("  This copy was built from source. To update it, re-run the installer:\n    {INSTALL}");
        return Ok(());
    };
    println!("  This copy was built from source, so it's being rebuilt. That takes a few minutes…");
    let status = std::process::Command::new(cargo).args(cargo_args(Revision::Tag(tag), root)).status()
        .map_err(|e| format!("Couldn't run cargo: {e}"))?;
    if !status.success() {
        return Err("The build failed; nothing was changed.".into());
    }
    println!("  ✓ Quire {version} installed in {}.", dir.display());
    Ok(())
}

/// `--main`: the terminal app from the latest code on main, for trying a fix
/// before it's in a release. Only the terminal app: the desktop app needs its
/// own toolchain, and comes from releases.
fn update_from_main(desktop: bool, check_only: bool) -> Result<(), String> {
    if desktop {
        return Err("--main builds the terminal app only. The desktop app comes from releases.".into());
    }
    if check_only {
        println!("  `quire update --main` would build the terminal app from the latest code on main.");
        return Ok(());
    }
    let dir = install_dir()?;
    let Some(cargo) = find_cargo() else {
        return Err("--main needs cargo, which isn't installed. Get it from https://rustup.rs".into());
    };
    let Some(root) = cargo_root(&dir) else {
        return Err(format!("--main can't install into {}: cargo needs a folder called bin.", dir.display()));
    };
    println!("  Building from main, which isn't a release. That takes a few minutes…");
    let status = std::process::Command::new(cargo).args(cargo_args(Revision::Main, root)).status()
        .map_err(|e| format!("Couldn't run cargo: {e}"))?;
    if !status.success() {
        return Err("The build failed; nothing was changed.".into());
    }
    println!("  ✓ Quire from main installed in {}.", dir.display());
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
    // `Quire.desktop` matches the Wayland app id; `quire.desktop` is what older installs wrote.
    if let Some(p) = data
        .and_then(|d| ["Quire.desktop", "quire.desktop"].iter()
            .find_map(|n| std::fs::read_to_string(d.join("applications").join(n)).ok()))
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
    {how}", url_of(rel, &file).unwrap_or_else(|| format!("https://github.com/{RELEASE_REPO}/releases/latest")));
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
            check_signature(agent, rel, &file, &bytes)?;
            replace_file(&path, &bytes)?;
            println!("  ✓ Desktop app updated to {version}. If it's open, restart it.");
            Ok(())
        }
    }
}

/// Write `bytes` over `path` by a temporary file and a rename (executable):
/// written in full and synced first, as `replace_bins` does.
pub fn replace_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let tmp = stage(path, bytes).map_err(|e| format!("can't write {}: {e}", path.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("can't write {}: {e}", path.display())
    })?;
    if let Some(dir) = path.parent() {
        sync_dir(dir);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A release without a signature for the file is refused before
    /// anything is downloaded: a SHA-256 from the same release proves nothing
    /// about who made it.
    #[test]
    fn a_release_with_no_signature_is_refused() {
        let rel = Release {
            tag_name: "v9.0.0".into(),
            body: String::new(),
            assets: vec![Asset { name: "quire-x.tar.gz".into(), browser_download_url: "https://github.com/a/b".into() }],
        };
        let agent = ureq::Agent::new_with_defaults();
        let err = check_signature(&agent, &rel, "quire-x.tar.gz", b"bytes").unwrap_err();
        assert!(err.contains("no signature") && err.contains("nothing was changed"), "{err}");
    }

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
    fn an_unknown_argument_stops_the_update() {
        let args = |s: &str| s.split_whitespace().map(String::from).collect::<Vec<_>>();
        assert_eq!(parse_args(&[]), Ok(Asked::default()));
        assert_eq!(parse_args(&args("--check --desktop")), Ok(Asked { check: true, desktop: true, ..Asked::default() }));
        assert_eq!(parse_args(&args("--main")), Ok(Asked { main: true, ..Asked::default() }));
        for help in ["--help", "-h", "help"] {
            assert!(parse_args(&args(help)).unwrap().help, "{help}");
        }
        // A typo, or a flag from another program, is never "go ahead".
        for bad in ["--chek", "--dry-run", "--check=1", "-n", "now", "--check --hlep"] {
            assert!(parse_args(&args(bad)).unwrap_err().contains("nothing was done"), "{bad}");
        }
        // `run` answers these before anything is looked up or downloaded.
        assert_eq!(run(&args("--help")), 0);
        assert_eq!(run(&args("--chek")), 2);
        assert_eq!(run(&args("--check --dry-run")), 2);
    }

    #[test]
    fn releases_come_from_the_public_release_repo() {
        assert_eq!(latest_url(), "https://api.github.com/repos/Caddickbrown/quire-release/releases/latest");
        assert!(INSTALL.starts_with("curl -fsSL https://raw.githubusercontent.com/Caddickbrown/quire-release/main/install.sh "), "{INSTALL}");
        // Builds from source still clone the source repository.
        assert!(cargo_args(Revision::Main, Path::new("/r")).contains(&"https://github.com/Caddickbrown/Quire".to_string()));
        // A new binary still carries the mark an old one is known by.
        assert_eq!(QUIRE_MARK, SOURCE_REPO.as_bytes());
        assert!(download_host_ok("https://github.com/Caddickbrown/quire-release/releases/download/v1.0.1/quire-x86_64-unknown-linux-gnu.tar.gz"));
    }

    #[test]
    fn the_desktop_app_updates_from_the_release_repo() {
        let conf: serde_json::Value = serde_json::from_str(include_str!("../../linux/src-tauri/tauri.conf.json")).unwrap();
        assert_eq!(
            conf["plugins"]["updater"]["endpoints"],
            serde_json::json!(["https://github.com/Caddickbrown/quire-release/releases/latest/download/latest.json"])
        );
    }

    #[test]
    fn downloads_come_from_github_over_https_only() {
        for ok in [
            "https://github.com/Caddickbrown/Quire/releases/download/v1.0.0/quire-x.tar.gz",
            "https://objects.githubusercontent.com/github-production-release-asset/1/2?sig=abc",
            "https://release-assets.githubusercontent.com/x",
            "https://GitHub.com:443/x",
        ] {
            assert!(download_host_ok(ok), "{ok}");
        }
        for bad in [
            "http://github.com/Caddickbrown/Quire/releases/download/v1.0.0/quire-x.tar.gz",
            "https://example.com/quire-x.tar.gz",
            "https://github.com.example.com/x",
            "https://examplegithub.com/x",
            "https://notgithubusercontent.com/x",
            "https://github.com@example.com/x",
            "https://example.com/?https://github.com/",
            "/Caddickbrown/Quire/releases/x",
            "file:///etc/passwd",
            "",
        ] {
            assert!(!download_host_ok(bad), "{bad}");
        }
    }

    /// A throwaway key, and its signature of `SIGNED`, in the release's formats.
    const TEST_KEY: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IFRFU1QKUldSTmZtaHY1YzE3THNFVUd1YXl2NTd5Z3daYWttcHF0dGd3TzZHRzM5KytUYkJ6RzJwdzFRSU4K";
    const TEST_SIG: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSTmZtaHY1YzE3TGttczNzRFVDVkZLaUxvM3I1dVlkSlFheFI2aHVhc1FtTlFwTUNyd1A2SDhyaWsrNHlNK0NlTTBaeExDUnV2bDJRSGhHUUVyWStiWTlFbVkzYW9Jdmc0PQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzk0NzAwMDAwCWZpbGU6cXVpcmUtdGVzdC50YXIuZ3oKVGxqSmlJbjZTczY2YSs0bG5yMHNYbzBMRGJ3LzlCWlZQL3hoTW5zT3RtNEdpMzRLeHczYkNVSXFXN1VIaTRSaE5TeEsyb25ZVjdUT1RtUGhSNFAzQmc9PQo=";
    const SIGNED: &[u8] = b"quire test tarball";

    #[test]
    fn a_release_file_is_checked_against_its_signature() {
        assert_eq!(verify_signature(TEST_KEY, SIGNED, TEST_SIG), Ok(()));
        assert_eq!(verify_signature(TEST_KEY, SIGNED, &format!("{TEST_SIG}\n")), Ok(()), "a trailing newline is the file's, not the signature's");
        // Other bytes, another key, or a signature that isn't one: all refused.
        assert!(verify_signature(TEST_KEY, b"quire test tarball, changed", TEST_SIG).unwrap_err().contains("doesn't match"));
        assert!(verify_signature(UPDATER_PUBKEY, SIGNED, TEST_SIG).is_err(), "signed by a key that isn't the release's");
        assert!(verify_signature(TEST_KEY, SIGNED, "").unwrap_err().contains("signature isn't readable"));
        assert!(verify_signature(TEST_KEY, SIGNED, "bm90IGEgc2lnbmF0dXJl").unwrap_err().contains("signature isn't readable"));
        assert!(verify_signature("", SIGNED, TEST_SIG).unwrap_err().contains("signing key"));
    }

    /// One key for both updaters: the terminal's is the desktop app's.
    #[test]
    fn the_release_key_is_the_desktop_updaters() {
        let conf: serde_json::Value = serde_json::from_str(include_str!("../../linux/src-tauri/tauri.conf.json")).unwrap();
        assert_eq!(conf["plugins"]["updater"]["pubkey"], UPDATER_PUBKEY);
        use base64::Engine;
        let key = String::from_utf8(base64::engine::general_purpose::STANDARD.decode(UPDATER_PUBKEY).unwrap()).unwrap();
        assert!(minisign_verify::PublicKey::decode(&key).is_ok(), "and it is a key");
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
        assert_eq!(names_in(d.path()), ["Quire.AppImage"], "no temporary file is left");
    }

    #[test]
    fn source_builds_rebuild_into_their_own_folder() {
        assert_eq!(cargo_root(Path::new("/home/d/.cargo/bin")), Some(Path::new("/home/d/.cargo")));
        assert_eq!(cargo_root(Path::new("/home/d/.local/bin")), Some(Path::new("/home/d/.local")));
        assert_eq!(cargo_root(Path::new("/home/d/Quire/target/release")), None);
        let args = cargo_args(Revision::Tag("v1.2.3"), Path::new("/home/d/.cargo")).join(" ");
        assert_eq!(args, "install --locked --force --git https://github.com/Caddickbrown/Quire --tag v1.2.3 --root /home/d/.cargo quire-tui");
    }

    #[test]
    fn main_builds_the_branch_into_the_same_folder() {
        let args = cargo_args(Revision::Main, Path::new("/home/d/.cargo")).join(" ");
        assert_eq!(args, "install --locked --force --git https://github.com/Caddickbrown/Quire --branch main --root /home/d/.cargo quire-tui");
    }

    #[test]
    fn main_refuses_the_desktop_app_and_only_reports_with_check() {
        assert!(update_from_main(true, false).unwrap_err().contains("terminal app only"));
        // Runs no build: asking is all --check does.
        assert_eq!(update_from_main(false, true), Ok(()));
    }

    #[test]
    fn unpack_and_replace() {
        let bins = unpack(&tarball(&["quire", "jnl", "README.md"])).unwrap();
        assert_eq!(bins.iter().map(|b| b.0.as_str()).collect::<Vec<_>>(), ["quire", "jnl"]);
        assert!(unpack(&tarball(&["quire"])).unwrap_err().contains("no jnl"));
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("quire"), "old Caddickbrown/Quire build").unwrap();
        replace_bins(d.path(), &bins).unwrap();
        assert_eq!(std::fs::read_to_string(d.path().join("quire")).unwrap(), "#!quire");
        assert_eq!(std::fs::read_to_string(d.path().join("jnl")).unwrap(), "#!jnl");
        assert_eq!(names_in(d.path()), ["jnl", "quire"], "no temporary file is left");
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(d.path().join("jnl")).unwrap().permissions().mode() & 0o777, 0o755);
    }

    /// One binary that can't be written must not leave the other replaced.
    #[test]
    fn a_failed_stage_or_rename_leaves_both_old_binaries() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("quire"), "old quire, Caddickbrown/Quire").unwrap();
        // A folder where `jnl` should go: its rename fails after quire's worked.
        std::fs::create_dir(d.path().join("jnl")).unwrap();
        std::fs::write(d.path().join("jnl/keep"), "x").unwrap();
        let bins = vec![("quire".to_string(), b"new quire".to_vec()), ("jnl".to_string(), b"new jnl".to_vec())];
        let e = replace_bins(d.path(), &bins).unwrap_err();
        assert!(e.contains("nothing was changed"), "{e}");
        assert_eq!(std::fs::read_to_string(d.path().join("quire")).unwrap(), "old quire, Caddickbrown/Quire");
        assert_eq!(names_in(d.path()), ["jnl", "quire"]);
        // A folder that can't be written to: nothing is staged, nothing renamed.
        let e = replace_bins(&d.path().join("missing"), &bins).unwrap_err();
        assert!(e.contains("nothing was changed"), "{e}");
    }

    /// Review 12: a `jnl` beside `quire` that isn't Quire's (the Go CLI, the
    /// bash script) is not renamed over; Quire's own, or a link to it, is.
    #[test]
    fn a_jnl_that_isnt_quires_is_left_where_it_is() {
        let bins = vec![("quire".to_string(), b"new quire Caddickbrown/Quire".to_vec()), ("jnl".to_string(), b"new jnl Caddickbrown/Quire".to_vec())];
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("quire"), "old quire Caddickbrown/Quire").unwrap();
        std::fs::write(d.path().join("jnl"), "#!/usr/bin/env bash\n# the original jnl\n: \"${JNL_DIR:=$HOME/notes}\"\n").unwrap();
        let e = replace_bins(d.path(), &bins).unwrap_err();
        assert!(e.contains("isn't Quire's") && e.contains("nothing was changed"), "{e}");
        assert!(std::fs::read_to_string(d.path().join("jnl")).unwrap().contains("the original jnl"));
        assert_eq!(std::fs::read_to_string(d.path().join("quire")).unwrap(), "old quire Caddickbrown/Quire", "not half done");
        assert_eq!(names_in(d.path()), ["jnl", "quire"]);
        // Quire's own jnl, as a link to quire: replaced.
        std::fs::remove_file(d.path().join("jnl")).unwrap();
        std::os::unix::fs::symlink("quire", d.path().join("jnl")).unwrap();
        replace_bins(d.path(), &bins).unwrap();
        assert_eq!(std::fs::read_to_string(d.path().join("jnl")).unwrap(), "new jnl Caddickbrown/Quire");
        // None there yet: written.
        std::fs::remove_file(d.path().join("jnl")).unwrap();
        replace_bins(d.path(), &bins).unwrap();
        assert!(d.path().join("jnl").is_file());
    }

    /// The format release.yml signs, byte for byte, and a statement signed by
    /// a throwaway key (`tauri signer sign` on that text) checked against it:
    /// another tag, another name or other bytes don't verify.
    #[test]
    fn a_tarballs_signature_names_its_release() {
        const KEY: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IEQzODZBM0ZGNDY2OUVBMzgKUldRNDZtbEcvNk9HMDBOSmx2ZGxIdWlGbm5wbEI5YTBXU3VpRGhjRU1DVGZsR0ZsalQzMld6V08K";
        const SIG: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVRNDZtbEcvNk9HMDNqNjJDb1dpazdkeHBMT1dBTXZSOU53VDZneUVUSGlhYmdpby9kNUhmNmIxTndQMDhPYTc5cWI3MldxL1NWZm9ac21QWmNZNkNISkM4YzdQMi9lcHdvPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzk0OTkyMjM3CWZpbGU6cXVpcmUtdGVzdC50YXIuZ3oucmVsZWFzZQo0ckczVUloWXV4R3JmMmFxYXlPdHd2V3IwV0gyM3FIeHFyb05GeEZxaXRMb2pvMm15dGFZejRKb0dqM1V1ZERwN2JiLzQ1bDFpTitYM1JNWkRIN0JEZz09Cg==";
        let statement = release_statement("v9.9.9", "quire-test.tar.gz", SIGNED);
        assert_eq!(statement, format!("Quire release file\ntag: v9.9.9\nfile: quire-test.tar.gz\nsha256: {}\n", hex_sha256(SIGNED)));
        assert_eq!(verify_signature(KEY, statement.as_bytes(), SIG), Ok(()));
        for other in [release_statement("v9.9.10", "quire-test.tar.gz", SIGNED), release_statement("v9.9.9", "quire-other.tar.gz", SIGNED),
                      release_statement("v9.9.9", "quire-test.tar.gz", b"an older tarball")] {
            assert!(verify_signature(KEY, other.as_bytes(), SIG).is_err(), "{other}");
        }
        // The tarball's own .sig, of its bytes only, is not this signature.
        assert!(verify_signature(TEST_KEY, statement.as_bytes(), TEST_SIG).is_err());
        // release.yml writes the same lines.
        let workflow = include_str!("../../.github/workflows/release.yml");
        assert!(workflow.contains(r"printf 'Quire release file\ntag: %s\nfile: %s\nsha256: %s\n' "), "release.yml's statement format changed");
    }

    /// A release with only the bytes' signature is refused by this client.
    #[test]
    fn a_release_with_no_release_signature_is_refused() {
        let rel = Release { tag_name: "v9.9.9".into(), body: String::new(),
                            assets: vec![Asset { name: "quire-x.tar.gz.sig".into(), browser_download_url: "https://github.com/x".into() }] };
        let err = check_release_signature(&ureq::Agent::new_with_defaults(), &rel, "quire-x.tar.gz", b"bytes").unwrap_err();
        assert!(err.contains("quire-x.tar.gz.release.sig") && err.contains("nothing was changed"), "{err}");
    }

    fn names_in(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(dir).unwrap().flatten().map(|e| e.file_name().to_string_lossy().to_string()).collect();
        v.sort();
        v
    }
}
