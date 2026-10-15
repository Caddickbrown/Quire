use std::process::Command;
fn git(args: &[&str]) -> Option<String> {
    let output = Command::new("git").args(args).output().ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
}
fn main() {
    // Track the current branch and packed refs, including worktree git paths.
    for rel in ["HEAD", "packed-refs"] {
        if let Some(path) = git(&["rev-parse", "--git-path", rel]) {
            println!("cargo:rerun-if-changed={path}");
        }
    }
    if let Some(reference) = git(&["symbolic-ref", "-q", "HEAD"]) {
        if let Some(path) = git(&["rev-parse", "--git-path", &reference]) {
            println!("cargo:rerun-if-changed={path}");
        }
    }
    let suffix = git(&["rev-parse", "--short=7", "HEAD"])
        .map(|hash| format!(" ({hash})"))
        .unwrap_or_default();
    println!("cargo:rustc-env=QUIRE_GIT_SUFFIX={suffix}");
}
