//! Spawns `tun2socks.exe` against a Wintun device, pointing at Tor's first
//! SOCKS port. Discovers the binary either via `[tun2socks].binary` (filename
//! on PATH or absolute path) or — if bundled — next to our exe.

use anyhow::{anyhow, Context, Result};
use std::path::PathBuf;
use tokio::process::{Child, Command};

use crate::config::Config;

pub struct Tun2Socks {
    child: Option<Child>,
    pid:   u32,
}

impl Tun2Socks {
    pub fn pid(&self) -> u32 { self.pid }

    pub async fn start(cfg: &Config) -> Result<Self> {
        let bin = find_binary(cfg).context("locating tun2socks.exe")?;
        let ifname = &cfg.tun.interface;
        let socks  = cfg.tor.socks_port;
        let mtu    = cfg.tun.mtu;

        let mut cmd = Command::new(&bin);
        cmd.arg("-device").arg(format!("wintun://{}", ifname))
           .arg("-proxy").arg(format!("socks5://127.0.0.1:{}", socks))
           .arg("-mtu").arg(mtu.to_string())
           .arg("-loglevel").arg("error");

        cmd.stdout(std::process::Stdio::null());
        cmd.stderr(std::process::Stdio::null());
        cmd.kill_on_drop(true);

        #[cfg(windows)]
        {
            // tokio's Command exposes creation_flags() inherently on Windows.
            cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }

        let child = cmd.spawn().with_context(|| format!("spawn {}", bin.display()))?;
        let pid = child.id().unwrap_or_default();
        Ok(Self { child: Some(child), pid })
    }

    pub async fn stop(mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.start_kill();
            let _ = tokio::time::timeout(std::time::Duration::from_secs(3), child.wait()).await;
        }
    }
}

fn find_binary(cfg: &Config) -> Result<PathBuf> {
    let configured = &cfg.tun2socks.binary;
    // Absolute or relative-with-slash path
    if configured.contains('\\') || configured.contains('/') {
        let p = PathBuf::from(configured);
        if p.exists() { return Ok(p); }
    }
    // Next to our binary (bundled install case)
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let cand = dir.join(configured);
            if cand.exists() { return Ok(cand); }
            let cand = dir.join("tun2socks").join(configured);
            if cand.exists() { return Ok(cand); }
        }
    }
    // PATH lookup
    if let Ok(p) = which::which(configured) { return Ok(p); }
    Err(anyhow!("tun2socks not found: {}", configured))
}
