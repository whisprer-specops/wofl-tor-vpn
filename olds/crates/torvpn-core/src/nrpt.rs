//! NRPT + DNS-port firewall lock. Same script-resolution strategy as `firewall`.

use anyhow::{bail, Context, Result};
use std::path::PathBuf;
use tokio::process::Command;

use crate::config::Config;

fn script_path(name: &str) -> Result<PathBuf> {
    let exe = std::env::current_exe().context("current_exe")?;
    let dir = exe.parent().context("exe has no parent")?;
    let direct = dir.join(name);
    if direct.exists() { return Ok(direct); }
    Ok(dir.join("scripts").join(name))
}

/// Strict: used for APPLYING the DNS lock. See firewall::run_ps1_strict for
/// why a silently-no-op'd protection is worse than an honest failure —
/// `connect()` should not reach "Engaged" believing DNS is locked when the
/// script that locks it never actually ran.
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

/// Best-effort: used for teardown. Always runs to completion; logs and
/// swallows failures rather than leaving cleanup half-done.
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

pub async fn apply_dns_lock(cfg: &Config) -> Result<()> {
    let args = serde_json::json!({
        "AdapterHint": cfg.tun.interface,
        "DnsLoopback": "127.0.0.1",
        "TorDnsPort":  cfg.tor.dns_port,
    }).to_string();
    run_ps1_strict("dns-apply.ps1", Some(args)).await
}

pub async fn teardown_dns_lock() -> Result<()> {
    run_ps1_soft("dns-teardown.ps1", None).await;
    Ok(())
}
