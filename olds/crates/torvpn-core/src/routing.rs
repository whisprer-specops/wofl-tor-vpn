//! Split-tunnel routing.
//!
//! For a full-device VPN we push the default route onto the Wintun adapter so
//! everything flows into tun2socks -> tor. The catch is the **routing loop**:
//! tor's own connections to its entry guards are just outbound TCP, so with a
//! naive "default route -> tunnel" they'd re-enter the tunnel, hit tun2socks,
//! come back to tor's SOCKS port, and tor would try to reach the guard again...
//! forever. The tunnel would eat its own transport.
//!
//! The fix (standard tun2socks practice): pin `/32` host routes for the exact
//! IPs tor talks to directly (its guards) to the *physical* gateway, then set
//! the default route to the tunnel. Longest-prefix-match means the guard `/32`s
//! always beat the tunnel's `/0`, so tor's guard traffic escapes on the real
//! link while everything else is tunnelled.
//!
//! We discover the guard IPs live from tor's ControlPort. If we can't (no
//! guards yet, control down), we REFUSE to flip the default route — a loop that
//! kills the user's network is far worse than "the tunnel didn't come up".
//!
//! All the actual Windows route/adapter mutation lives in the two PowerShell
//! scripts; this module is discovery + orchestration only. Route changes made
//! by the scripts are non-persistent (no `-p`), so a reboot always clears them.

use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};
use tokio::process::Command;

use crate::config::Config;
use crate::tor_control::TorControl;

fn script_path(name: &str) -> Result<PathBuf> {
    let exe = std::env::current_exe().context("current_exe")?;
    let dir = exe.parent().context("exe has no parent")?;
    let direct = dir.join(name);
    if direct.exists() {
        return Ok(direct);
    }
    Ok(dir.join("scripts").join(name))
}

/// Run one of the routing scripts. Unlike the DNS lock, routing failures are
/// fatal to `connect()` — a half-applied route table is dangerous — so a
/// non-zero exit is surfaced as an error for the caller to roll back on.
async fn run_ps1(name: &str, json_args: Option<String>) -> Result<()> {
    let script = script_path(name)?;
    let mut cmd = Command::new("powershell");
    cmd.arg("-NoProfile")
        .arg("-ExecutionPolicy").arg("Bypass")
        .arg("-File").arg(&script);
    if let Some(j) = json_args {
        cmd.arg(j);
    }
    let status = cmd
        .status()
        .await
        .with_context(|| format!("run {}", script.display()))?;
    if !status.success() {
        bail!("{name} failed (exit {:?})", status.code());
    }
    Ok(())
}

/// Ask tor which relays it currently holds direct connections to (its guards),
/// resolved to IPv4 addresses via the consensus.
async fn discover_guard_ips(cfg: &Config, state_dir: &Path) -> Result<Vec<String>> {
    let cookie = state_dir.join("tor-data").join("control_auth_cookie");
    let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
    let mut ctl = TorControl::connect(&addr, &cookie)
        .await
        .context("connecting to tor ControlPort for guard discovery")?;
    ctl.guard_ipv4_addrs().await
}

/// Bring up the split tunnel: pin guard `/32`s to the physical gateway, assign
/// the Wintun address, and move the default route onto the tunnel.
pub async fn apply(cfg: &Config, state_dir: &Path) -> Result<()> {
    let guards = discover_guard_ips(cfg, state_dir)
        .await
        .context("discovering tor guard IPs for split routing")?;

    // FAIL-SAFE: no guards => a tunnel default route would loop tor's own
    // traffic. Do not touch the route table.
    if guards.is_empty() {
        bail!(
            "no tor guard IPs discovered — refusing to move the default route \
             onto the tunnel (that would loop tor's guard traffic and kill \
             connectivity). Is tor fully bootstrapped?"
        );
    }
    log::info!("split routing: pinning {} guard IP(s) to physical gateway", guards.len());

    // Persist what we're about to add so teardown removes exactly these.
    let statef = state_dir.join("routes.json");
    let doc = serde_json::json!({
        "guards": guards,
        "interface": cfg.tun.interface,
    });
    if let Ok(bytes) = serde_json::to_vec_pretty(&doc) {
        let _ = tokio::fs::write(&statef, bytes).await;
    }

    let args = serde_json::json!({
        "AdapterHint": cfg.tun.interface,
        "GuardIps":    guards,
    })
    .to_string();
    run_ps1("route-apply.ps1", Some(args)).await
}

/// Tear the split tunnel down: remove the tunnel default route and the guard
/// `/32`s. The physical default route was never removed (only out-prioritised),
/// so connectivity returns the moment the tunnel default is gone.
///
/// Takes no `Config` on purpose: it recovers the interface name and the guard
/// set from the persisted `routes.json`, so it works as blind crash-recovery on
/// service start-up too. Safe to call when nothing is applied.
pub async fn teardown(state_dir: &Path) -> Result<()> {
    let statef = state_dir.join("routes.json");
    let (guards, interface): (Vec<String>, String) = match tokio::fs::read(&statef).await {
        Ok(b) => {
            let v: serde_json::Value = serde_json::from_slice(&b).unwrap_or_default();
            let guards = v
                .get("guards")
                .and_then(|g| g.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            let interface = v
                .get("interface")
                .and_then(|x| x.as_str())
                .unwrap_or("torvpn")
                .to_string();
            (guards, interface)
        }
        Err(_) => (Vec::new(), "torvpn".to_string()),
    };

    let args = serde_json::json!({
        "AdapterHint": interface,
        "GuardIps":    guards,
    })
    .to_string();
    let result = run_ps1("route-teardown.ps1", Some(args)).await;
    let _ = tokio::fs::remove_file(&statef).await;
    result
}
