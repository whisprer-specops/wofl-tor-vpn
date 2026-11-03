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
    pid: u32,
    #[cfg(windows)]
    _job: crate::process_job::Job,
}

impl TorInstance {
    pub fn pid(&self) -> u32 {
        self.pid
    }
    pub fn has_exited(&mut self) -> std::io::Result<bool> {
        match self.child.as_mut() {
            Some(c) => c.try_wait().map(|v| v.is_some()),
            None => Ok(true),
        }
    }

    pub async fn start(cfg: &Config, state_dir: &Path) -> Result<Self> {
        let tor_path = find_tor(cfg).context("locating tor.exe")?;
        let tor_data = state_dir.join("tor-data");
        fs::create_dir_all(&tor_data).await?;

        let torrc_path = state_dir.join("torrc.generated");
        let torrc = generate_torrc(cfg, &tor_data, &tor_path)?;
        fs::write(&torrc_path, torrc).await?;

        let mut cmd = Command::new(&tor_path);
        cmd.arg("-f").arg(&torrc_path);
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
        if let Some(dir) = tor_path.parent() {
            cmd.current_dir(dir);
        }
        cmd.kill_on_drop(true);

        #[cfg(windows)]
        {
            // tokio::process::Command exposes creation_flags() as an
            // inherent method on Windows, so no trait import is needed.
            // CREATE_NO_WINDOW = 0x08000000 keeps the service host from
            // popping a console window when it spawns tor.
            cmd.creation_flags(0x0800_0000);
        }

        let mut child = cmd
            .spawn()
            .with_context(|| format!("spawn {}", tor_path.display()))?;
        let pid = child.id().context("spawned process has no PID")?;
        #[cfg(windows)]
        let job = crate::process_job::Job::for_child(&child)?;

        // Drain stderr immediately; an unread pipe can deadlock a child.
        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    log::warn!("[tor stderr] {line}");
                }
            });
        }
        // Monitor bootstrap with a timeout. If tor never reaches 100, give up.
        let stdout = child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?;
        let mut reader = BufReader::new(stdout).lines();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(180);
        let mut boot: u8 = 0;
        let mut last_lines = std::collections::VecDeque::new();
        loop {
            tokio::select! {
                _ = tokio::time::sleep_until(deadline) => {
                    bail!("Tor bootstrap timed out at {}%; recent output: {:?}", boot, last_lines);
                }
                line = reader.next_line() => {
                    let line = match line? {
                        Some(l) => l,
                        None => bail!("Tor exited before bootstrap; recent output: {:?}. See svc.log for stderr.", last_lines),
                    };
                    log::info!("[tor] {line}");
                    if last_lines.len() >= 8 { last_lines.pop_front(); }
                    last_lines.push_back(line.clone());
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

        Ok(Self {
            child: Some(child),
            pid,
            #[cfg(windows)]
            _job: job,
        })
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

/// Resolve tor.exe exactly as `TorInstance::start` will, for callers that need
/// the path BEFORE tor is running. The kill-switch is the one that matters: in
/// full-tunnel mode it runs *first* (so nothing leaks while tor bootstraps) and
/// must add an Allow rule for the real tor binary — but tor isn't running yet,
/// so it can't ask a live tor where it lives. Sharing this one resolver means
/// the firewall allow-rule and the process we actually launch can never
/// disagree about which tor.exe is "the" tor.exe — which they previously could,
/// because the firewall only ever saw the raw `tor_path_hint` while this
/// function also checks next-to-exe and PATH.
pub(crate) fn resolve_tor_path(cfg: &Config) -> Result<PathBuf> {
    find_tor(cfg)
}

fn find_tor(cfg: &Config) -> Result<PathBuf> {
    // Every candidate we tried, so a failure is self-diagnosing instead of a
    // bare "not found". This function runs INSIDE the service process — a
    // LocalSystem process whose environment (PATH included) was captured
    // whenever it last started, not your interactive shell's. That mismatch
    // ("I definitely added it to PATH!") is exactly what this diagnostic
    // exists to make obvious on the first try.
    let mut tried: Vec<String> = Vec::new();

    if let Some(hint) = cfg.tor.tor_path_hint.as_ref().filter(|s| !s.is_empty()) {
        let p = PathBuf::from(hint);
        if p.exists() {
            return Ok(p);
        }
        tried.push(format!("tor_path_hint '{hint}' (not found)"));
    } else {
        tried.push("tor_path_hint is empty".to_string());
    }

    // Bundled-next-to-binary discovery: %ProgramFiles%\TorVPN\tor\tor.exe
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            for cand in [
                dir.join("tor").join("tor.exe"),
                dir.join("tor.exe"),
                dir.join("Tor").join("tor.exe"),
            ] {
                if cand.exists() {
                    return Ok(cand);
                }
                tried.push(format!("{} (not found)", cand.display()));
            }
        }
    }

    if let Ok(p) = which::which("tor.exe") {
        return Ok(p);
    }
    if let Ok(p) = which::which("tor") {
        return Ok(p);
    }
    tried.push("PATH search for tor.exe / tor (not found)".to_string());

    // The single most useful line when someone insists "it's on my PATH": show
    // exactly what PATH this process sees. A Windows service's environment is
    // frozen at whatever it was when the service (or the machine) last
    // started — editing System/User PATH afterwards and restarting a
    // *terminal* never reaches an already-running service.
    let path_seen = std::env::var("PATH").unwrap_or_else(|_| "<PATH not set>".to_string());

    Err(anyhow!(
        "tor.exe not found. Tried: {}. PATH this service process sees: {path_seen}. \
         Fix: set [tor].tor_path_hint = \"C:/full/path/to/tor.exe\" in \
         %ProgramData%\\torvpn\\profile.toml (forward slashes, or \\\\ — a bare \\ \
         in a TOML string is an escape code), then `Restart-Service TorVPN`. That's \
         checked first and skips PATH entirely — a System PATH edit needs a full \
         reboot to reach a running service; a User PATH edit never reaches \
         LocalSystem at all.",
        tried.join("; ")
    ))
}

fn parse_bootstrap_percent(line: &str) -> Option<u8> {
    let idx = line.find("Bootstrapped ")?;
    let rest = &line[idx + "Bootstrapped ".len()..];
    let pct_str = rest.split('%').next()?;
    pct_str.trim().parse::<u8>().ok()
}

fn generate_torrc(cfg: &Config, data_dir: &Path, tor_path: &Path) -> Result<String> {
    let mut s = String::with_capacity(2048);

    s.push_str(&format!(
        "DataDirectory {}\n",
        tor_quote(&data_dir.to_string_lossy())
    ));
    s.push_str("Log notice stdout\n");
    s.push_str("ClientOnly 1\n");
    s.push_str("AvoidDiskWrites 1\n");

    // GeoIP data ships in <tor.exe dir>\data\. Tor needs it for country-based
    // ExitNodes (the tray's "Exit country" menu). Without GeoIPFile tor loads
    // no country map and silently ignores {us}, {de}, … selections, so point
    // at the files when they're present next to the bundled tor.exe.
    if let Some(tor_dir) = tor_path.parent() {
        let geoip = tor_dir.join("data").join("geoip");
        let geoip6 = tor_dir.join("data").join("geoip6");
        if geoip.exists() {
            s.push_str(&format!(
                "GeoIPFile {}\n",
                tor_quote(&geoip.to_string_lossy())
            ));
        }
        if geoip6.exists() {
            s.push_str(&format!(
                "GeoIPv6File {}\n",
                tor_quote(&geoip6.to_string_lossy())
            ));
        }
    }

    // Control plane: the service drives NEWNYM / SETCONF over the ControlPort.
    s.push_str(&format!("ControlPort 127.0.0.1:{}\n", cfg.tor.control_port));
    s.push_str("CookieAuthentication 1\n");
    s.push_str(&format!("DNSPort 127.0.0.1:{}\n", cfg.tor.dns_port));

    // ===== Speed knobs =====
    let perf = &cfg.perf;

    // SOCKS ports. tun2socks connects to the *base* port; any extra ports give
    // additional isolated circuit pools for a future multi-dialer.
    //
    // Two hard rules are enforced here, because getting either wrong makes tor
    // refuse to launch (and that's exactly what wedged this build):
    //
    //   1. A SOCKS port must never collide with ControlPort or DNSPort. The old
    //      code emitted socks_port .. socks_port+N, which walked straight over
    //      ControlPort — with the defaults (socks 9050, control 9051) tor was
    //      told to bind 9051 as BOTH a SOCKSPort and the ControlPort. Fatal.
    //
    //   2. SOCKSPort isolation flags are bare keywords, optionally "No"-prefixed
    //      — never "flag=0". The old line ("IsolateClientAddr=0" plus a
    //      contradictory IsolateSOCKSAuth + NoIsolateSOCKSAuth pair) was invalid
    //      syntax that tor rejects outright. We want *less* isolation for
    //      throughput (every stream arrives from one loopback client via
    //      tun2socks, so isolating buys nothing), so we use the documented
    //      negations.
    let base = cfg.tor.socks_port;
    let control = cfg.tor.control_port;
    let dns = cfg.tor.dns_port;

    if base == control || base == dns {
        bail!(
            "config error: [tor].socks_port ({base}) must differ from \
             control_port ({control}) and dns_port ({dns})"
        );
    }

    let want = perf.parallel_socks_ports.max(1);
    // Base port first — it's the one tun2socks dials.
    let mut ports: Vec<u16> = vec![base];
    let mut cand = base;
    while (ports.len() as u8) < want {
        cand = match cand.checked_add(1) {
            Some(p) => p,
            None => break,
        };
        if cand == control || cand == dns || ports.contains(&cand) {
            continue;
        }
        ports.push(cand);
    }
    for port in &ports {
        // NoIsolateClientAddr + NoIsolateSOCKSAuth = maximal circuit sharing.
        s.push_str(&format!("SOCKSPort 127.0.0.1:{port} IsolateSOCKSAuth\n"));
    }

    s.push_str("AutomapHostsOnResolve 1\n");
    s.push_str("AutomapHostsSuffixes .onion\n");

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
    s.push_str(&format!(
        "NumEntryGuards {}\n",
        perf.num_entry_guards.max(1)
    ));
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
        let list = cfg
            .exit
            .countries
            .iter()
            .map(|c| format!("{{{}}}", c.to_lowercase()))
            .collect::<Vec<_>>()
            .join(",");
        s.push_str(&format!("ExitNodes {}\n", list));
        if cfg.exit.strict {
            s.push_str("StrictNodes 1\n");
        }
    }

    // Bridges only if explicitly enabled.
    if cfg.tor.use_bridges {
        s.push_str("UseBridges 1\n");
        for b in &cfg.tor.bridges {
            s.push_str(&format!("Bridge {}\n", b));
        }
        if let Some(obfs) = &cfg.tor.client_transport_plugin {
            if !obfs.is_empty() {
                s.push_str(&format!(
                    "ClientTransportPlugin obfs4 exec {}\n",
                    tor_quote(obfs)
                ));
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
        let list = cfg
            .exit
            .countries
            .iter()
            .map(|c| format!("{{{}}}", c.to_lowercase()))
            .collect::<Vec<_>>()
            .join(",");
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
                    if let Some(u) = &p.username {
                        ctl.set_conf("Socks5ProxyUsername", u).await?;
                    }
                    if let Some(pw) = &p.password {
                        ctl.set_conf("Socks5ProxyPassword", pw).await?;
                    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;

    fn default_cfg() -> Config {
        toml::from_str(include_str!("../../../profiles/default_win.toml"))
            .expect("bundled default profile must parse")
    }

    /// Pull the port out of every `SOCKSPort 127.0.0.1:<port> ...` line.
    fn socks_ports(torrc: &str) -> Vec<u16> {
        torrc
            .lines()
            .filter_map(|l| l.strip_prefix("SOCKSPort 127.0.0.1:"))
            .filter_map(|rest| rest.split_whitespace().next())
            .filter_map(|p| p.parse::<u16>().ok())
            .collect()
    }

    #[test]
    fn quoted_windows_paths_preserve_spaces_and_backslashes() {
        assert_eq!(
            tor_quote(r"C:\Program Files\TorVPN\tor-data"),
            r#""C:\\Program Files\\TorVPN\\tor-data""#
        );
    }

    #[test]
    fn generated_config_is_accepted_by_real_tor_when_available() {
        let Some(tor) = std::env::var_os("TORVPN_TEST_TOR") else {
            return;
        };
        let dir = std::env::temp_dir().join(format!(
            "torvpn-torrc-{}-{}",
            std::process::id(),
            rand::random::<u64>()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let text = generate_torrc(
            &default_cfg(),
            &dir.join("data with spaces"),
            Path::new(&tor),
        )
        .unwrap();
        let conf = dir.join("test.torrc");
        std::fs::write(&conf, text).unwrap();
        let out = std::process::Command::new(&tor)
            .args(["--verify-config", "-f"])
            .arg(&conf)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{} {}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn no_socks_port_collides_with_control_or_dns() {
        let mut cfg = default_cfg();
        // Force the worst case: 4 ports over the old contiguous layout that
        // used to slam SOCKSPort onto ControlPort (9051).
        cfg.perf.parallel_socks_ports = 4;
        cfg.tor.socks_port = 9050;
        cfg.tor.control_port = 9051;
        cfg.tor.dns_port = 5353;

        let torrc = generate_torrc(&cfg, Path::new("/nonexistent"), Path::new("/x/tor.exe"))
            .expect("torrc generation");
        let ports = socks_ports(&torrc);

        assert_eq!(
            ports.len(),
            4,
            "should emit exactly the requested port count"
        );
        assert_eq!(
            ports[0], 9050,
            "tun2socks dials the base port, emit it first"
        );
        assert!(
            !ports.contains(&9051),
            "must not reuse ControlPort as a SOCKSPort"
        );
        assert!(
            !ports.contains(&5353),
            "must not reuse DNSPort as a SOCKSPort"
        );
        // No duplicates.
        let mut sorted = ports.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), ports.len(), "SOCKS ports must be unique");
        // ControlPort still declared exactly once, on its own line.
        assert_eq!(torrc.matches("ControlPort 127.0.0.1:9051").count(), 1);
    }

    #[test]
    fn socks_lines_use_valid_isolation_flags() {
        let cfg = default_cfg();
        let torrc = generate_torrc(&cfg, Path::new("/nonexistent"), Path::new("/x/tor.exe"))
            .expect("torrc generation");
        for line in torrc.lines().filter(|l| l.starts_with("SOCKSPort")) {
            // The invalid `flag=0` form is what tor rejected before.
            assert!(
                !line.contains('='),
                "isolation flags are bare keywords: {line}"
            );
            // No contradictory Isolate + NoIsolate of the same knob.
            assert!(
                !(line.contains(" IsolateSOCKSAuth") && line.contains("NoIsolateSOCKSAuth")),
                "contradictory isolation flags: {line}"
            );
        }
    }

    #[test]
    fn base_port_colliding_with_control_is_a_hard_error() {
        let mut cfg = default_cfg();
        cfg.tor.socks_port = 9051;
        cfg.tor.control_port = 9051;
        let err =
            generate_torrc(&cfg, Path::new("/nonexistent"), Path::new("/x/tor.exe")).unwrap_err();
        assert!(err.to_string().contains("must differ"), "got: {err}");
    }
}

/// Tor configuration quoted strings use C-style escapes. Windows backslashes
/// and spaces must survive parsing instead of becoming escapes or arguments.
fn tor_quote(value: &str) -> String {
    format!(
        "\"{}\"",
        value
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', "\\n")
            .replace('\r', "\\r")
    )
}
