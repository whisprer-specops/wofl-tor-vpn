//! Engagement state machine.
//!
//! ```text
//!   Disengaged ──connect──▶ Engaging ──ok──▶ Engaged ──disconnect──▶ Disengaging ──ok──▶ Disengaged
//!         ▲                     │                                       │
//!         └─────────────error───┘                                       │
//!         ▲                                                             │
//!         └────────────────────────error────────────────────────────────┘
//! ```
//!
//! Only one transition runs at a time, gated by a `Mutex`. The state is
//! observable via `current()` and is also mirrored to a JSON file on disk
//! so the CLI can read it without going through HTTP.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::Arc};
use tokio::sync::Mutex;

use crate::config::Config;
use crate::{firewall, nrpt, tor_manager, tun2socks_mgr};

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
}

impl Default for Snapshot {
    fn default() -> Self {
        Self {
            phase: Phase::Disengaged,
            message: String::new(),
            since_ms: now_ms(),
            tor_pid: None,
            tun2socks_pid: None,
        }
    }
}

fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64
}

/// Live, shared engagement controller. Hold this in the service main; the
/// HTTP server gets an `Arc<Engagement>` clone to drive it.
pub struct Engagement {
    inner: Mutex<Inner>,
    state_file: PathBuf,
}

struct Inner {
    snapshot: Snapshot,
    tor: Option<tor_manager::TorInstance>,
    t2s: Option<tun2socks_mgr::Tun2Socks>,
}

impl Engagement {
    pub fn new(state_file: PathBuf) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(Inner {
                snapshot: Snapshot::default(),
                tor: None,
                t2s: None,
            }),
            state_file,
        })
    }

    pub async fn current(&self) -> Snapshot {
        self.inner.lock().await.snapshot.clone()
    }

    async fn write_snapshot(&self, snap: &Snapshot) {
        if let Ok(bytes) = serde_json::to_vec_pretty(snap) {
            if let Some(p) = self.state_file.parent() {
                let _ = tokio::fs::create_dir_all(p).await;
            }
            let _ = tokio::fs::write(&self.state_file, bytes).await;
        }
    }

    async fn set_phase(&self, inner: &mut Inner, phase: Phase, msg: impl Into<String>) {
        inner.snapshot.phase = phase;
        inner.snapshot.message = msg.into();
        inner.snapshot.since_ms = now_ms();
        inner.snapshot.tor_pid = inner.tor.as_ref().map(|t| t.pid());
        inner.snapshot.tun2socks_pid = inner.t2s.as_ref().map(|t| t.pid());
        log::info!("[state] {:?}: {}", inner.snapshot.phase, inner.snapshot.message);
        self.write_snapshot(&inner.snapshot).await;
    }

    /// Idempotent: returns immediately as Ok(()) if already Engaged.
    pub async fn connect(self: &Arc<Self>, cfg: &Config, state_dir: &std::path::Path) -> Result<()> {
        let mut inner = self.inner.lock().await;
        match inner.snapshot.phase {
            Phase::Engaged => return Ok(()),
            Phase::Engaging => return Ok(()),
            _ => {}
        }
        self.set_phase(&mut inner, Phase::Engaging, "applying firewall").await;

        // Apply protections fail-closed BEFORE starting tor, so leaks during
        // bootstrap can't escape via the default route.
        if let Err(e) = firewall::apply_rules(cfg).await {
            self.set_phase(&mut inner, Phase::Error, format!("firewall: {e}")).await;
            return Err(e);
        }
        self.set_phase(&mut inner, Phase::Engaging, "applying DNS lock").await;
        if let Err(e) = nrpt::apply_dns_lock(cfg).await {
            self.set_phase(&mut inner, Phase::Error, format!("dns lock: {e}")).await;
            let _ = firewall::teardown_rules().await;
            return Err(e);
        }

        self.set_phase(&mut inner, Phase::Engaging, "bootstrapping tor").await;
        let tor = match tor_manager::TorInstance::start(cfg, state_dir).await {
            Ok(t) => t,
            Err(e) => {
                self.set_phase(&mut inner, Phase::Error, format!("tor: {e}")).await;
                let _ = nrpt::teardown_dns_lock().await;
                let _ = firewall::teardown_rules().await;
                return Err(e);
            }
        };
        inner.tor = Some(tor);

        self.set_phase(&mut inner, Phase::Engaging, "starting tun2socks").await;
        let t2s = match tun2socks_mgr::Tun2Socks::start(cfg).await {
            Ok(t) => t,
            Err(e) => {
                // tear tor back down — we shouldn't leave it orphaned
                if let Some(tor) = inner.tor.take() { tor.stop().await; }
                let _ = nrpt::teardown_dns_lock().await;
                let _ = firewall::teardown_rules().await;
                self.set_phase(&mut inner, Phase::Error, format!("tun2socks: {e}")).await;
                return Err(e);
            }
        };
        inner.t2s = Some(t2s);

        // Persist PIDs for `Status` CLI and crash recovery.
        let pid_path = state_dir.join("pids.json");
        let pids = serde_json::json!({
            "tor": inner.tor.as_ref().map(|t| t.pid()),
            "tun2socks": inner.t2s.as_ref().map(|t| t.pid()),
        });
        let _ = tokio::fs::write(&pid_path, serde_json::to_vec_pretty(&pids).unwrap()).await;

        self.set_phase(&mut inner, Phase::Engaged, "engaged").await;
        Ok(())
    }

    /// Idempotent: returns Ok(()) if already Disengaged.
    pub async fn disconnect(self: &Arc<Self>, state_dir: &std::path::Path) -> Result<()> {
        let mut inner = self.inner.lock().await;
        match inner.snapshot.phase {
            Phase::Disengaged => return Ok(()),
            Phase::Disengaging => return Ok(()),
            _ => {}
        }
        self.set_phase(&mut inner, Phase::Disengaging, "stopping tun2socks").await;
        if let Some(t) = inner.t2s.take() { t.stop().await; }
        self.set_phase(&mut inner, Phase::Disengaging, "stopping tor").await;
        if let Some(t) = inner.tor.take() { t.stop().await; }

        // Belt-and-braces taskkill in case start_kill missed something
        // (orphan from a previous crash, etc.)
        let _ = tokio::process::Command::new("taskkill").args(["/IM","tun2socks.exe","/F"]).status().await;
        let _ = tokio::process::Command::new("taskkill").args(["/IM","tor.exe","/F"]).status().await;

        self.set_phase(&mut inner, Phase::Disengaging, "tearing down DNS lock").await;
        let _ = nrpt::teardown_dns_lock().await;
        self.set_phase(&mut inner, Phase::Disengaging, "tearing down firewall").await;
        let _ = firewall::teardown_rules().await;

        // Clean up PID file
        let _ = tokio::fs::remove_file(state_dir.join("pids.json")).await;

        self.set_phase(&mut inner, Phase::Disengaged, "disengaged").await;
        Ok(())
    }

    /// Toggle helper used by the tray.
    pub async fn toggle(self: &Arc<Self>, cfg: &Config, state_dir: &std::path::Path) -> Result<Phase> {
        let phase = self.inner.lock().await.snapshot.phase;
        match phase {
            Phase::Disengaged | Phase::Error => {
                self.connect(cfg, state_dir).await
                    .with_context(|| "toggle: connect failed")?;
            }
            Phase::Engaged => {
                self.disconnect(state_dir).await
                    .with_context(|| "toggle: disconnect failed")?;
            }
            // Mid-transition: just report current.
            _ => {}
        }
        Ok(self.inner.lock().await.snapshot.phase)
    }
}
