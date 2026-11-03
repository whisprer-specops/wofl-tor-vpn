//! Serialized network changes with an independently readable status snapshot.
use crate::{config::Config, firewall, nrpt, routing, tor_manager, tun2socks_mgr};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::sync::{watch, Mutex, RwLock};

pub async fn teardown_env(state_dir: &Path) -> Result<()> {
    // Attempt every cleanup even if an earlier one failed. Keep recovery files
    // when an operation fails, so the next attempt can finish restoring state.
    let routes = routing::teardown(state_dir).await;
    let dns = nrpt::teardown_dns_lock().await;
    let fw = firewall::teardown_rules().await;
    routes?;
    dns?;
    fw?;
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Phase {
    Disengaged,
    Engaging,
    Engaged,
    Disengaging,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub phase: Phase,
    pub message: String,
    pub since_ms: u64,
    pub tor_pid: Option<u32>,
    pub tun2socks_pid: Option<u32>,
    pub full_tunnel: bool,
    pub exit_ip: Option<String>,
}
impl Default for Snapshot {
    fn default() -> Self {
        Self {
            phase: Phase::Disengaged,
            message: "Disconnected".into(),
            since_ms: now_ms(),
            tor_pid: None,
            tun2socks_pid: None,
            full_tunnel: false,
            exit_ip: None,
        }
    }
}
fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
struct Inner {
    tor: Option<tor_manager::TorInstance>,
    t2s: Option<tun2socks_mgr::Tun2Socks>,
}
pub struct Engagement {
    inner: Mutex<Inner>,
    snapshot: RwLock<Snapshot>,
    cancel: watch::Sender<bool>,
    state_file: PathBuf,
}
impl Engagement {
    pub fn new(state_file: PathBuf) -> Arc<Self> {
        let (cancel, _) = watch::channel(false);
        Arc::new(Self {
            inner: Mutex::new(Inner {
                tor: None,
                t2s: None,
            }),
            snapshot: RwLock::new(Snapshot::default()),
            cancel,
            state_file,
        })
    }
    pub async fn current(&self) -> Snapshot {
        self.snapshot.read().await.clone()
    }
    async fn publish(&self, inner: &Inner, phase: Phase, message: impl Into<String>) {
        let snap = {
            let mut s = self.snapshot.write().await;
            s.phase = phase;
            s.message = message.into();
            s.since_ms = now_ms();
            s.tor_pid = inner.tor.as_ref().map(|t| t.pid());
            s.tun2socks_pid = inner.t2s.as_ref().map(|t| t.pid());
            if phase != Phase::Engaged {
                s.exit_ip = None;
            }
            s.clone()
        };
        log::info!("[state] {:?}: {}", snap.phase, snap.message);
        if let Some(p) = self.state_file.parent() {
            let _ = tokio::fs::create_dir_all(p).await;
        }
        if let Ok(bytes) = serde_json::to_vec_pretty(&snap) {
            let _ = tokio::fs::write(&self.state_file, bytes).await;
        }
    }
    async fn stop_children(inner: &mut Inner) {
        if let Some(t) = inner.t2s.take() {
            t.stop().await;
        }
        if let Some(t) = inner.tor.take() {
            t.stop().await;
        }
    }
    pub async fn connect(self: &Arc<Self>, cfg: &Config, sd: &Path) -> Result<()> {
        let mut inner = self
            .inner
            .try_lock()
            .context("a connection operation is already running")?;
        if self.current().await.phase == Phase::Engaged {
            return Ok(());
        }
        crate::config::validate(cfg)?;
        self.cancel.send_replace(false);
        let mut cancelled = self.cancel.subscribe();
        self.snapshot.write().await.full_tunnel = cfg.tun.full_tunnel;
        // Resolve dependencies before modifying the network.
        let preflight = async {
            tor_manager::resolve_tor_path(cfg)?;
            if cfg.tun.full_tunnel {
                tun2socks_mgr::resolve_binary(cfg)?;
            }
            Result::<()>::Ok(())
        }
        .await;
        if let Err(e) = preflight {
            self.publish(&inner, Phase::Error, format!("Preflight: {e:#}"))
                .await;
            return Err(e);
        }
        self.publish(
            &inner,
            Phase::Engaging,
            "Recovering previous session settings",
        )
        .await;
        Self::stop_children(&mut inner).await;
        if let Err(e) = teardown_env(sd).await {
            self.publish(&inner, Phase::Error, format!("Recovery failed: {e:#}"))
                .await;
            return Err(e);
        }
        // Administrative scripts finish their bounded step before cancellation
        // triggers recovery; never race rollback against a half-running script.
        let result = self
            .connect_inner(&mut inner, cfg, sd, &mut cancelled)
            .await;
        if let Err(e) = result {
            Self::stop_children(&mut inner).await;
            let cleanup = teardown_env(sd).await;
            let suffix = cleanup
                .err()
                .map(|e| format!("; recovery also failed: {e:#}"))
                .unwrap_or_default();
            self.publish(&inner, Phase::Error, format!("{e:#}{suffix}"))
                .await;
            return Err(e);
        }
        Ok(())
    }
    async fn connect_inner(
        &self,
        inner: &mut Inner,
        cfg: &Config,
        sd: &Path,
        cancelled: &mut watch::Receiver<bool>,
    ) -> Result<()> {
        anyhow::ensure!(!*cancelled.borrow(), "Connection cancelled");
        if cfg.tun.full_tunnel {
            self.publish(inner, Phase::Engaging, "Applying firewall protection")
                .await;
            firewall::apply_rules(cfg).await.context("firewall setup")?;
        }
        self.publish(
            inner,
            Phase::Engaging,
            "Starting Tor; bootstrap progress is in svc.log",
        )
        .await;
        anyhow::ensure!(!*cancelled.borrow(), "Connection cancelled");
        inner.tor = Some(tokio::select! {
            result = tor_manager::TorInstance::start(cfg, sd) => result.context("Tor startup")?,
            _ = cancelled.wait_for(|v| *v) => anyhow::bail!("Connection cancelled"),
        });
        if cfg.tun.full_tunnel {
            self.publish(inner, Phase::Engaging, "Creating Wintun adapter")
                .await;
            inner.t2s = Some(
                tun2socks_mgr::Tun2Socks::start(cfg)
                    .await
                    .context("tun2socks startup")?,
            );
            anyhow::ensure!(!*cancelled.borrow(), "Connection cancelled");
            // The tunnel allow rule must be added AFTER its adapter exists.
            firewall::allow_tunnel(cfg)
                .await
                .context("allowing tunnel interface")?;
            anyhow::ensure!(!*cancelled.borrow(), "Connection cancelled");
            self.publish(inner, Phase::Engaging, "Routing DNS through Tor")
                .await;
            nrpt::apply_dns_lock(cfg).await.context("DNS setup")?;
            anyhow::ensure!(!*cancelled.borrow(), "Connection cancelled");
            self.publish(inner, Phase::Engaging, "Installing tunnel routes")
                .await;
            routing::apply(cfg, sd).await.context("route setup")?;
        }
        self.publish(
            inner,
            Phase::Engaging,
            "Verifying HTTPS connection through Tor",
        )
        .await;
        let ip = tokio::select! {
            result = verify_connection(cfg) => result.context("Tor connection verification")?,
            _ = cancelled.wait_for(|v| *v) => anyhow::bail!("Connection cancelled"),
        };
        {
            let mut snap = self.snapshot.write().await;
            snap.exit_ip = Some(ip.clone());
        }
        self.publish(
            inner,
            Phase::Engaged,
            if cfg.tun.full_tunnel {
                format!("TCP tunnel verified; exit {ip}. Native IPv6 and non-DNS UDP blocked.")
            } else {
                format!("SOCKS proxy verified; exit {ip}. System traffic is NOT redirected.")
            },
        )
        .await;
        Ok(())
    }
    pub async fn disconnect(self: &Arc<Self>, sd: &Path) -> Result<()> {
        self.cancel.send_replace(true);
        let mut inner = self.inner.lock().await;
        self.publish(&inner, Phase::Disengaging, "Restoring network settings")
            .await;
        // Keep the firewall armed until the tunnel and DNS changes are removed.
        Self::stop_children(&mut inner).await;
        match teardown_env(sd).await {
            Ok(()) => {
                self.publish(
                    &inner,
                    Phase::Disengaged,
                    "Disconnected; original network settings restored",
                )
                .await;
                Ok(())
            }
            Err(e) => {
                self.publish(
                    &inner,
                    Phase::Error,
                    format!("Recovery failed: {e:#}. Run Recover-Network.ps1 as Administrator."),
                )
                .await;
                Err(e)
            }
        }
    }
    pub async fn toggle(self: &Arc<Self>, cfg: &Config, sd: &Path) -> Result<Phase> {
        match self.current().await.phase {
            Phase::Disengaged | Phase::Error => self.connect(cfg, sd).await?,
            Phase::Engaged | Phase::Engaging => self.disconnect(sd).await?,
            Phase::Disengaging => {}
        }
        Ok(self.current().await.phase)
    }
    /// A dead Tor/tun2socks process must not leave a green tray indicator.
    /// Keep protection armed on failure until the user disconnects/retries.
    pub async fn health_tick(&self) {
        let Ok(mut inner) = self.inner.try_lock() else {
            return;
        };
        if self.current().await.phase != Phase::Engaged {
            return;
        }
        let dead = inner
            .tor
            .as_mut()
            .map(|t| t.has_exited())
            .transpose()
            .map(|v| v.unwrap_or(true))
            .unwrap_or(true)
            || inner
                .t2s
                .as_mut()
                .map(|t| t.has_exited())
                .transpose()
                .map(|v| v.unwrap_or(false))
                .unwrap_or(true);
        if dead {
            Self::stop_children(&mut inner).await;
            self.publish(&inner, Phase::Error, "A tunnel process exited. Protection retained; disconnect to restore networking, or retry.").await;
        }
    }
}

/// HTTPS uses Windows' native curl, with config files and environment proxies
/// disabled. In full-tunnel mode this probes ordinary Windows routing; a SOCKS
/// probe alone would say nothing about whether the TUN route is functional.
async fn verify_connection(cfg: &Config) -> Result<String> {
    let curl = if cfg!(windows) {
        PathBuf::from(std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into()))
            .join("System32")
            .join("curl.exe")
    } else {
        PathBuf::from("curl")
    };
    let mut cmd = tokio::process::Command::new(curl);
    cmd.args([
        "-q",
        "--fail",
        "--silent",
        "--show-error",
        "--proto",
        "=https",
        "--connect-timeout",
        "20",
        "--max-time",
        "40",
    ]);
    for key in [
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "NO_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "no_proxy",
    ] {
        cmd.env_remove(key);
    }
    cmd.arg("--noproxy")
        .arg(if cfg.tun.full_tunnel { "*" } else { "" });
    if !cfg.tun.full_tunnel {
        cmd.arg("--socks5-hostname")
            .arg(format!("127.0.0.1:{}", cfg.tor.socks_port));
    }
    cmd.arg("https://check.torproject.org/api/ip");
    cmd.kill_on_drop(true);
    #[cfg(windows)]
    cmd.creation_flags(0x0800_0000);
    let out = tokio::time::timeout(std::time::Duration::from_secs(45), cmd.output())
        .await
        .context("verification timed out")??;
    anyhow::ensure!(
        out.status.success(),
        "HTTPS check failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let doc: serde_json::Value =
        serde_json::from_slice(&out.stdout).context("invalid Tor check response")?;
    anyhow::ensure!(
        doc.get("IsTor").and_then(|v| v.as_bool()) == Some(true),
        "Tor Project check did not confirm a Tor exit"
    );
    let ip = doc
        .get("IP")
        .and_then(|v| v.as_str())
        .context("Tor check omitted IP")?;
    let _: std::net::IpAddr = ip.parse().context("invalid exit IP")?;
    Ok(ip.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn status_remains_readable_during_transition() {
        let eng = Engagement::new(std::env::temp_dir().join("unused-torvpn-state"));
        let _operation = eng.inner.lock().await;
        eng.snapshot.write().await.phase = Phase::Engaging;
        let snap = tokio::time::timeout(std::time::Duration::from_millis(100), eng.current())
            .await
            .expect("status must not wait on operation lock");
        assert_eq!(snap.phase, Phase::Engaging);
    }
}
