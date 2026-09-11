//! Windows Firewall kill-switch. Calls bundled PowerShell scripts. They live
//! under `%ProgramFiles%\TorVPN\scripts` after install; we resolve them via
//! `current_exe()` so the service binary can find them regardless of cwd.

use anyhow::{Context, Result};
use std::path::PathBuf;
use tokio::process::Command;

use crate::config::Config;

fn script_path(name: &str) -> Result<PathBuf> {
    let exe = std::env::current_exe().context("current_exe")?;
    let dir = exe.parent().context("exe has no parent")?;
    // Try alongside the binary first, then a `scripts` subdir.
    let direct = dir.join(name);
    if direct.exists() { return Ok(direct); }
    let scripts = dir.join("scripts").join(name);
    Ok(scripts)
}

async fn run_ps1(name: &str, json_args: Option<String>) -> Result<()> {
    let script = script_path(name)?;
    let mut cmd = Command::new("powershell");
    cmd.arg("-NoProfile")
       .arg("-ExecutionPolicy").arg("Bypass")
       .arg("-File").arg(&script);
    if let Some(j) = json_args { cmd.arg(j); }
    let status = cmd.status().await
        .with_context(|| format!("run {}", script.display()))?;
    if !status.success() {
        log::warn!("{} returned {:?}", name, status.code());
    }
    Ok(())
}

pub async fn apply_rules(cfg: &Config) -> Result<()> {
    let args = serde_json::json!({
        "AdapterHint": cfg.tun.interface,
        "TorPath":     cfg.tor.tor_path_hint.as_deref().unwrap_or("tor.exe"),
    }).to_string();
    run_ps1("fw-apply.ps1", Some(args)).await
}

pub async fn teardown_rules() -> Result<()> {
    run_ps1("fw-teardown.ps1", None).await
}
