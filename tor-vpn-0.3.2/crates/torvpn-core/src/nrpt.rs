use crate::config::Config;
use anyhow::Result;
pub async fn apply_dns_lock(cfg: &Config) -> Result<()> {
    crate::windows_script::run(
        "dns-apply.ps1",
        serde_json::json!({
            "AdapterHint": cfg.tun.interface, "TorDnsPort": cfg.tor.dns_port,
        }),
    )
    .await
}
pub async fn teardown_dns_lock() -> Result<()> {
    crate::windows_script::run("dns-teardown.ps1", serde_json::json!({})).await
}
