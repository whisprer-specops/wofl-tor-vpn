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
    // .output() not .status(): capture the script's own stdout/stderr instead
    // of letting it inherit the service's (which, headless under SCM, goes
    // nowhere). A bare "exited with 1" tells you the script failed but not
    // WHY — the `throw` message, the failing cmdlet, the PowerShell error
    // record all live on stderr, and binning them is the same silent-failure
    // trap we've now paid for at four different layers. Fold the tail of it
    // straight into the error so it reaches both svc.log and the CLI/tray.
    let output = cmd.output().await
        .with_context(|| format!("run {}", script.display()))?;
    if !output.status.success() {
        bail!("{name} exited with {:?}: {} (script: {})",
            output.status.code(), ps_fail_detail(&output.stdout, &output.stderr), script.display());
    }
    Ok(())
}

/// Fold a failed PowerShell invocation's output into one line for an error
/// message. Prefers stderr (where `throw` and error records land), falls back
/// to stdout, caps length char-safely so a giant error record can't blow up a
/// log line or HTTP body.
pub(crate) fn ps_fail_detail(stdout: &[u8], stderr: &[u8]) -> String {
    let err = String::from_utf8_lossy(stderr);
    let out = String::from_utf8_lossy(stdout);
    let s = if !err.trim().is_empty() { err.trim() } else { out.trim() };
    if s.is_empty() {
        return "(no stdout/stderr captured — run the script by hand to see the error)".to_string();
    }
    let chars: Vec<char> = s.chars().collect();
    if chars.len() > 800 {
        format!("…{}", chars[chars.len() - 800..].iter().collect::<String>())
    } else {
        s.to_string()
    }
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
    // Resolve tor the SAME way tor_manager will actually launch it (hint →
    // next-to-exe → PATH), then hand the script a verified absolute path. This
    // closes a real divergence: the script used to get only the raw
    // `tor_path_hint` (literal "tor.exe" when unset) and re-resolve it with
    // weaker logic against the service's frozen PATH — so a tor that
    // tor_manager could find (e.g. via next-to-exe, which the script never
    // checked) would still trip fw-apply.ps1's "tor not found" throw and fail
    // the whole connect. If it genuinely can't be found, fail HERE with
    // find_tor's rich PATH-dump diagnostic instead of the script's opaque exit.
    let tor_path = crate::tor_manager::resolve_tor_path(cfg)
        .context("kill-switch: resolving tor.exe so it can be allowed through")?;
    let args = serde_json::json!({
        "AdapterHint": cfg.tun.interface,
        "TorPath":     tor_path.to_string_lossy(),
    }).to_string();
    run_ps1_strict("fw-apply.ps1", Some(args)).await
}

pub async fn teardown_rules() -> Result<()> {
    run_ps1_soft("fw-teardown.ps1", None).await;
    Ok(())
}
