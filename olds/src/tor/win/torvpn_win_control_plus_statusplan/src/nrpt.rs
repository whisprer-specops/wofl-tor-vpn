use anyhow::Result;
use tokio::process::Command;
use crate::config::Config;

pub async fn apply_dns_lock(cfg: &Config) -> Result<()> {
    let script = include_str!("../scripts/dns-apply.ps1");
    let args = serde_json::json!({
        "AdapterHint": cfg.tun.interface,
        "DnsLoopback": "127.0.0.1",
        "TorDnsPort": cfg.tor.dns_port
    }).to_string();

    Command::new("powershell")
        .arg("-NoProfile").arg("-ExecutionPolicy").arg("Bypass")
        .arg("-Command").arg(script)
        .arg(args)
        .status().await?;
    Ok(())
}

pub async fn teardown_dns_lock() -> Result<()> {
    let script = include_str!("../scripts/dns-teardown.ps1");
    Command::new("powershell")
        .arg("-NoProfile").arg("-ExecutionPolicy").arg("Bypass")
        .arg("-Command").arg(script)
        .status().await?;
    Ok(())
}
