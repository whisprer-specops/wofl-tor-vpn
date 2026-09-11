use anyhow::Result;
use tokio::process::Command;
use crate::config::Config;

pub async fn apply_rules(cfg: &Config) -> Result<()> {
    // Apply strict outbound block, allowing only Tor process and Wintun adapter traffic.
    // We shell out to bundled PowerShell scripts for clarity.
    let script = include_str!("../scripts/fw-apply.ps1");
    let args = serde_json::json!({
        "AdapterHint": cfg.tun.interface,
        "TorPath": cfg.tor.tor_path_hint.as_deref().unwrap_or("tor.exe")
    }).to_string();

    Command::new("powershell")
        .arg("-NoProfile").arg("-ExecutionPolicy").arg("Bypass")
        .arg("-Command").arg(script)
        .arg(args)
        .status().await?;
    Ok(())
}

pub async fn teardown_rules() -> Result<()> {
    let script = include_str!("../scripts/fw-teardown.ps1");
    Command::new("powershell")
        .arg("-NoProfile").arg("-ExecutionPolicy").arg("Bypass")
        .arg("-Command").arg(script)
        .status().await?;
    Ok(())
}
