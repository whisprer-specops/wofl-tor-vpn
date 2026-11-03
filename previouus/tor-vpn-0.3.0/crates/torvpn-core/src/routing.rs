//! Pin Tor's current direct peers before moving public IPv4 traffic to TUN.
use crate::{config::Config, tor_control::TorControl};
use anyhow::{Context, Result};
use std::path::Path;
pub async fn apply(cfg: &Config, sd: &Path) -> Result<()> {
    let mut ctl = TorControl::connect(
        &format!("127.0.0.1:{}", cfg.tor.control_port),
        &sd.join("tor-data/control_auth_cookie"),
    )
    .await?;
    let guards = ctl
        .guard_ipv4_addrs()
        .await
        .context("discovering Tor direct peers")?;
    anyhow::ensure!(
        !guards.is_empty(),
        "no Tor direct peers found; refusing a route loop"
    );
    // Tor cannot safely reach a NEW direct IP through its own SOCKS tunnel.
    // Constrain this session to the bypass routes we install. Reconnecting
    // removes this runtime-only constraint and discovers a fresh peer set.
    let allowed = guards
        .iter()
        .map(|ip| format!("{ip}:*"))
        .collect::<Vec<_>>()
        .join(",");
    ctl.set_conf("ReachableAddresses", &allowed).await?;
    crate::windows_script::run(
        "route-apply.ps1",
        serde_json::json!({
            "AdapterHint": cfg.tun.interface, "GuardIps": guards,
        }),
    )
    .await
}
pub async fn teardown(_sd: &Path) -> Result<()> {
    crate::windows_script::run("route-teardown.ps1", serde_json::json!({})).await
}
