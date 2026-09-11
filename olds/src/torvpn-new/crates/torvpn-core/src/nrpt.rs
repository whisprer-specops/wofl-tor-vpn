//! NRPT + DNS-port firewall lock. Same script-resolution strategy as `firewall`.

use anyhow::{Context, Result};
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

async fn run_ps1(name: &str, json_args: Option<String>) -> Result<()> {
    let script = script_path(name)?;
    let mut cmd = Command::new("powershell");
    cmd.arg("-NoProfile")
       .arg("-ExecutionPolicy").arg("Bypass")
       .arg("-File").arg(&script);
    if let Some(j) = json_args { cmd.arg(j); }
    cmd.status().await.with_context(|| format!("run {}", script.display()))?;
    Ok(())
}

pub async fn apply_dns_lock(cfg: &Config) -> Result<()> {
    let args = serde_json::json!({
        "AdapterHint": cfg.tun.interface,
        "DnsLoopback": "127.0.0.1",
        "TorDnsPort":  cfg.tor.dns_port,
    }).to_string();
    run_ps1("dns-apply.ps1", Some(args)).await
}

pub async fn teardown_dns_lock() -> Result<()> {
    run_ps1("dns-teardown.ps1", None).await
}
