use crate::config::Config;
use anyhow::{Context, Result};
pub(crate) fn ps_fail_detail(stdout: &[u8], stderr: &[u8]) -> String {
    let err = String::from_utf8_lossy(stderr);
    let out = String::from_utf8_lossy(stdout);
    let s = if err.trim().is_empty() {
        out.trim()
    } else {
        err.trim()
    };
    let tail: String = s
        .chars()
        .rev()
        .take(2400)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    if tail.is_empty() {
        "no output captured".into()
    } else {
        tail
    }
}
pub async fn apply_rules(cfg: &Config) -> Result<()> {
    let tor = crate::tor_manager::resolve_tor_path(cfg).context("locating Tor for firewall")?;
    crate::windows_script::run(
        "fw-apply.ps1",
        serde_json::json!({
            "Mode": "arm", "AdapterHint": cfg.tun.interface, "TorPath": tor,
        }),
    )
    .await
}
pub async fn allow_tunnel(cfg: &Config) -> Result<()> {
    crate::windows_script::run(
        "fw-apply.ps1",
        serde_json::json!({
            "Mode": "tunnel", "AdapterHint": cfg.tun.interface,
        }),
    )
    .await
}
pub async fn teardown_rules() -> Result<()> {
    crate::windows_script::run("fw-teardown.ps1", serde_json::json!({})).await
}
