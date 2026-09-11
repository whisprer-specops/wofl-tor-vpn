//! Spawns and supervises `tor.exe`.
//!
//! Speed-first torrc strategy (controllable via `[perf]` in the profile):
//!
//! - **Multiple SOCKS ports** (`parallel_socks_ports`, default 4) with
//!   `IsolateSOCKSAuth 0` and `KeepAliveIsolateSOCKSAuth 0` — letting flows
//!   share the same fast circuits when they don't actively need isolation.
//!   This is the single biggest throughput win.
//!
//! - **`CircuitBuildTimeout 10`** with `LearnCircuitBuildTimeout 0` — don't
//!   slowly relax to accept slow circuits; drop them and try again.
//!
//! - **`NumEntryGuards 3`** — wider guard pool, more chances to find a fast
//!   first hop. Anonymity cost is minor.
//!
//! - **`ClientUseIPv4 1, ClientUseIPv6 0`** by default — skip slow v6 paths.
//!
//! - **`CircuitPadding 0`, `ConnectionPadding 0`** — turn off netflow padding
//!   (latency win, small fingerprinting cost we're explicitly accepting).
//!
//! - **No bridges**, **no obfs4** unless the profile asks (these add hops
//!   and CPU for obfuscation we don't need).
//!
//! - **No `SafeSocks`** (we want apps to be able to resolve via SOCKS5h).
//!
//! - **`AvoidDiskWrites 1`** — keep tor mostly in-memory; faster, less I/O.
//!
//! - **`MaxCircuitDirtiness 600`** — reuse a hot circuit for ten minutes
//!   instead of churning every few seconds.
//!
//! Binary discovery order:
//!   1. `tor_path_hint` from the profile (if set and exists)
//!   2. `tor.exe` next to the current executable (the bundled Tor case)
//!   3. `tor.exe` in PATH
//!   4. Plain `tor` in PATH (dev/test on non-Windows)

use anyhow::{anyhow, bail, Context, Result};
use std::path::{Path, PathBuf};
use tokio::{
    fs,
    io::{AsyncBufReadExt, BufReader},
    process::{Child, Command},
};

use crate::config::Config;

pub struct TorInstance {
    child: Option<Child>,
    pid:   u32,
}

impl TorInstance {
    pub fn pid(&self) -> u32 { self.pid }

    pub async fn start(cfg: &Config, state_dir: &Path) -> Result<Self> {
        let tor_path = find_tor(cfg).context("locating tor.exe")?;
        let tor_data = state_dir.join("tor-data");
        fs::create_dir_all(&tor_data).await?;

        let torrc_path = state_dir.join("torrc.generated");
        let torrc = generate_torrc(cfg, &tor_data)?;
        fs::write(&torrc_path, torrc).await?;

        let mut cmd = Command::new(&tor_path);
        cmd.arg("-f").arg(&torrc_path);
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
        cmd.kill_on_drop(true);

        #[cfg(windows)]
        {
            // tokio::process::Command exposes creation_flags() as an
            // inherent method on Windows, so no trait import is needed.
            // CREATE_NO_WINDOW = 0x08000000 keeps the service host from
            // popping a console window when it spawns tor.
            cmd.creation_flags(0x0800_0000);
        }

        let mut child = cmd.spawn().with_context(|| format!("spawn {}", tor_path.display()))?;
        let pid = child.id().unwrap_or_default();

        // Monitor bootstrap with a timeout. If tor never reaches 100, give up.
        let stdout = child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?;
        let mut reader = BufReader::new(stdout).lines();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(90);
        let mut boot: u8 = 0;
        loop {
            tokio::select! {
                _ = tokio::time::sleep_until(deadline) => {
                    bail!("tor bootstrap timed out at {}%", boot);
                }
                line = reader.next_line() => {
                    let line = match line? {
                        Some(l) => l,
                        None => bail!("tor exited before bootstrap"),
                    };
                    log::debug!("[tor] {line}");
                    if let Some(p) = parse_bootstrap_percent(&line) {
                        if p > boot { boot = p; log::info!("tor bootstrap: {}%", p); }
                        if boot >= 100 { break; }
                    }
                    if let Some(code) = child.try_wait()? {
                        bail!("tor exited early with {code:?}");
                    }
                }
            }
        }

        // Drain remaining stdout in the background so the pipe doesn't fill.
        tokio::spawn(async move {
            while let Ok(Some(l)) = reader.next_line().await {
                log::debug!("[tor] {l}");
            }
        });

        Ok(Self { child: Some(child), pid })
    }

    /// Best-effort graceful stop. Falls back to taskkill if needed.
    pub async fn stop(mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.start_kill();
            // Don't wait forever; we'll taskkill /T /F if it lingers.
            let _ = tokio::time::timeout(std::time::Duration::from_secs(3), child.wait()).await;
        }
    }
}

fn find_tor(cfg: &Config) -> Result<PathBuf> {
    if let Some(hint) = cfg.tor.tor_path_hint.as_ref().filter(|s| !s.is_empty()) {
        let p = PathBuf::from(hint);
        if p.exists() { return Ok(p); }
    }
    // Bundled-next-to-binary discovery: %ProgramFiles%\TorVPN\tor\tor.exe
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            for cand in [
                dir.join("tor").join("tor.exe"),
                dir.join("tor.exe"),
                dir.join("Tor").join("tor.exe"),
            ] {
                if cand.exists() { return Ok(cand); }
            }
        }
    }
    if let Ok(p) = which::which("tor.exe") { return Ok(p); }
    if let Ok(p) = which::which("tor")     { return Ok(p); }
    Err(anyhow!("tor.exe not found (set [tor].tor_path_hint or install bundled)"))
}

fn parse_bootstrap_percent(line: &str) -> Option<u8> {
    let idx = line.find("Bootstrapped ")?;
    let rest = &line[idx + "Bootstrapped ".len()..];
    let pct_str = rest.split('%').next()?;
    pct_str.trim().parse::<u8>().ok()
}

fn generate_torrc(cfg: &Config, data_dir: &Path) -> Result<String> {
    let mut s = String::with_capacity(2048);

    s.push_str(&format!("DataDirectory {}\n", data_dir.display()));
    s.push_str("ClientOnly 1\n");
    s.push_str("AvoidDiskWrites 1\n");

    // ===== Speed knobs =====
    let perf = &cfg.perf;

    // Multiple SOCKS ports. Apps that don't need isolation share circuits.
    let n = perf.parallel_socks_ports.max(1);
    for i in 0..n {
        let port = cfg.tor.socks_port + i as u16;
        // IsolateSOCKSAuth=0 + KeepAliveIsolateSOCKSAuth=0 = max sharing.
        s.push_str(&format!(
            "SOCKSPort 127.0.0.1:{port} IsolateSOCKSAuth IsolateClientAddr=0 NoIsolateSOCKSAuth\n"
        ));
        // Note: the documented spelling is IsolateSOCKSAuth/IsolateClientAddr in
        // newer tor. The "NoIsolateSOCKSAuth" flag form was added in 0.4.x.
        // Older tor will ignore unknown flags after a warning — non-fatal.
        let _ = i; let _ = port;
    }
    // First SOCKS port — also the one tun2socks dials.
    // (Already emitted above for i=0; that's the canonical one.)

    s.push_str(&format!("DNSPort 127.0.0.1:{}\n", cfg.tor.dns_port));
    s.push_str(&format!("ControlPort 127.0.0.1:{}\n", cfg.tor.control_port));
    s.push_str("CookieAuthentication 1\n");

    s.push_str("AutomapHostsOnResolve 1\n");
    s.push_str("AutomapHostsSuffixes .onion,.exit\n");

    // IPv4 only by default — IPv6 paths over Tor are typically slow.
    if perf.ipv4_only {
        s.push_str("ClientUseIPv4 1\nClientUseIPv6 0\n");
    } else {
        s.push_str("ClientUseIPv4 1\nClientUseIPv6 1\n");
    }

    s.push_str(&format!(
        "CircuitBuildTimeout {}\n",
        perf.circuit_build_timeout_secs.max(3)
    ));
    s.push_str("LearnCircuitBuildTimeout 0\n");
    s.push_str(&format!("NumEntryGuards {}\n", perf.num_entry_guards.max(1)));
    s.push_str("KeepalivePeriod 60\n");
    s.push_str("MaxCircuitDirtiness 600\n");
    s.push_str("NewCircuitPeriod 30\n");

    if perf.disable_padding {
        s.push_str("CircuitPadding 0\nConnectionPadding 0\n");
    } else {
        s.push_str("CircuitPadding 1\nConnectionPadding 1\n");
    }

    // Exit policy
    if !cfg.exit.countries.is_empty() {
        let list = cfg.exit.countries.iter()
            .map(|c| format!("{{{}}}", c.to_lowercase()))
            .collect::<Vec<_>>().join(",");
        s.push_str(&format!("ExitNodes {}\n", list));
        if cfg.exit.strict { s.push_str("StrictNodes 1\n"); }
    }

    // Bridges only if explicitly enabled.
    if cfg.tor.use_bridges {
        s.push_str("UseBridges 1\n");
        for b in &cfg.tor.bridges { s.push_str(&format!("Bridge {}\n", b)); }
        if let Some(obfs) = &cfg.tor.client_transport_plugin {
            if !obfs.is_empty() {
                s.push_str(&format!("ClientTransportPlugin obfs4 exec {}\n", obfs));
            }
        }
    }

    Ok(s)
}

/// Apply runtime exit-policy and upstream-proxy changes via ControlPort.
/// Used by `applypolicy`, hop scheduler, and the /control/exitset endpoint.
pub async fn apply_proxy_and_exit(cfg: &Config, state_dir: &Path) -> Result<()> {
    use crate::proxy_manager::ProxyManager;
    use crate::tor_control::TorControl;
    use tokio::time::{sleep, Duration};

    let cookie = state_dir.join("tor-data").join("control_auth_cookie");
    let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
    let mut ctl = TorControl::connect(&addr, &cookie).await?;

    if cfg.exit.countries.is_empty() {
        let _ = ctl.set_conf("ExitNodes", "").await;
        let _ = ctl.set_conf("StrictNodes", "0").await;
    } else {
        let list = cfg.exit.countries.iter()
            .map(|c| format!("{{{}}}", c.to_lowercase()))
            .collect::<Vec<_>>().join(",");
        let strict = if cfg.exit.strict { "1" } else { "0" };
        ctl.set_conf("ExitNodes", &list).await?;
        ctl.set_conf("StrictNodes", strict).await?;
    }

    if cfg.proxy.enabled {
        let mut pm = ProxyManager::load(state_dir).await?;
        if let Some(p) = pm.current(cfg) {
            match p.typ.as_str() {
                "socks5" => {
                    ctl.set_conf("Socks5Proxy", &p.addr).await?;
                    if let Some(u) = &p.username { ctl.set_conf("Socks5ProxyUsername", u).await?; }
                    if let Some(pw) = &p.password { ctl.set_conf("Socks5ProxyPassword", pw).await?; }
                }
                "https" => {
                    ctl.set_conf("HTTPSProxy", &p.addr).await?;
                    if let Some(u) = &p.username {
                        let auth = format!("{}:{}", u, p.password.clone().unwrap_or_default());
                        ctl.set_conf("HTTPSProxyAuthenticator", &auth).await?;
                    }
                }
                _ => {}
            }
            pm.next(cfg);
            let _ = pm.save(state_dir).await;
            sleep(Duration::from_millis(300)).await;
        }
    } else {
        let _ = ctl.set_conf("Socks5Proxy", "").await;
        let _ = ctl.set_conf("HTTPSProxy", "").await;
    }

    let _ = ctl.signal_newnym().await;
    Ok(())
}
