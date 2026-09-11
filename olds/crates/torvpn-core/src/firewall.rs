//! Windows Firewall kill-switch. Calls bundled PowerShell scripts. They live
//! under `%ProgramFiles%\TorVPN\scripts` after install; we resolve them via
//! `current_exe()` so the service binary can find them regardless of cwd.

use anyhow::{bail, Context, Result};
use std::path::PathBuf;
use tokio::process::Command;

use crate::config::Config;

/// Resolve a script's path. Does NOT check existence on the `scripts\`
/// fallback branch — the caller decides how hard to fail on a missing file
/// (see `run_ps1_strict` vs `run_ps1_soft` below).
fn script_path(name: &str) -> Result<PathBuf> {
    let exe = std::env::current_exe().context("current_exe")?;
    let dir = exe.parent().context("exe has no parent")?;
    // Try alongside the binary first, then a `scripts` subdir.
    let direct = dir.join(name);
    if direct.exists() { return Ok(direct); }
    let scripts = dir.join("scripts").join(name);
    Ok(scripts)
}

/// Strict: used for APPLYING the kill-switch. A kill-switch that silently
/// fails to engage while `connect()` still reports "Engaged" is worse than no
/// kill-switch at all — it's a false sense of protection. Checks the resolved
/// path exists before even shelling out (so a missing script gets a clear
/// "not found, tried: X" instead of an opaque PowerShell exit code), and
/// propagates a non-zero exit as a real error.
async fn run_ps1_strict(name: &str, json_args: Option<String>) -> Result<()> {
    let script = script_path(name)?;
    if !script.exists() {
        bail!(
            "{name} not found (tried next to the exe and in a scripts\\ subdir; \
             resolved to {}). A dev build via `cargo build` doesn't copy scripts \
             the way the installer does — copy the repo's scripts\\ folder next \
             to your torvpn-svc.exe.",
            script.display()
        );
    }
    let mut cmd = Command::new("powershell");
    cmd.arg("-NoProfile")
        .arg("-ExecutionPolicy").arg("Bypass")
        .arg("-File").arg(&script);
    if let Some(j) = json_args { cmd.arg(j); }
    let status = cmd.status().await
        .with_context(|| format!("run {}", script.display()))?;
    if !status.success() {
        bail!("{name} exited with {:?} (script: {})", status.code(), script.display());
    }
    Ok(())
}

/// Best-effort: used for TEARDOWN, which must always run to completion and
/// clean up as much as it can — bailing partway through a teardown is how you
/// leave a machine half-locked-down. Logs and swallows any failure.
async fn run_ps1_soft(name: &str, json_args: Option<String>) {
    let script = match script_path(name) {
        Ok(p) => p,
        Err(e) => { log::warn!("{name}: couldn't resolve script path: {e}"); return; }
    };
    if !script.exists() {
        log::warn!("{name}: not found at {} (nothing to tear down?)", script.display());
        return;
    }
    let mut cmd = Command::new("powershell");
    cmd.arg("-NoProfile")
        .arg("-ExecutionPolicy").arg("Bypass")
        .arg("-File").arg(&script);
    if let Some(j) = json_args { cmd.arg(j); }
    match cmd.status().await {
        Ok(status) if !status.success() => log::warn!("{name} returned {:?}", status.code()),
        Err(e) => log::warn!("{name}: failed to run: {e}"),
        Ok(_) => {}
    }
}

pub async fn apply_rules(cfg: &Config) -> Result<()> {
    let args = serde_json::json!({
        "AdapterHint": cfg.tun.interface,
        "TorPath":     cfg.tor.tor_path_hint.as_deref().unwrap_or("tor.exe"),
    }).to_string();
    run_ps1_strict("fw-apply.ps1", Some(args)).await
}

pub async fn teardown_rules() -> Result<()> {
    run_ps1_soft("fw-teardown.ps1", None).await;
    Ok(())
}
