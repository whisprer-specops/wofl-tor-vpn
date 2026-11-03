//! Profile loader. Default profile is bundled as a TOML string; user can
//! override per-deploy with a file at `%PROGRAMDATA%\torvpn\profile.toml`.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;
use tokio::fs;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub status: StatusCfg,
    #[serde(default)]
    pub startup: StartupCfg,
    pub hop: HopCfg,
    pub proxy: ProxyCfg,
    pub exit: ExitCfg,
    pub pqc: PqcCfg,
    pub tun: TunCfg,
    pub tor: TorCfg,
    pub tun2socks: Tun2SocksCfg,
    /// Speed / latency tuning knobs (new in 0.2).
    #[serde(default)]
    pub perf: PerfCfg,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StartupCfg {
    #[serde(default = "default_true")]
    pub auto_connect: bool,
}
impl Default for StartupCfg {
    fn default() -> Self {
        Self { auto_connect: true }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusCfg {
    pub enabled: bool,
    /// Loopback only by default — tray app contacts this. e.g. "127.0.0.1:8787".
    pub listen: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HopCfg {
    pub enabled: bool,
    pub randomize: bool,
    pub loop_forever: bool,
    pub jitter: String,
    pub sequence: Vec<HopItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HopItem {
    pub duration: String,
    pub exit_countries: Vec<String>,
    /// "next" | "socks5://h:p" | "https://h:p" | None
    pub proxy: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyCfg {
    pub enabled: bool,
    pub rotation: String, // "sequential" | "random" | "off"
    pub proxies: Vec<ProxyItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyItem {
    pub typ: String,  // "socks5" | "https"
    pub addr: String, // "host:port"
    pub username: Option<String>,
    pub password: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExitCfg {
    pub countries: Vec<String>,
    pub strict: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PqcCfg {
    pub enabled: bool,
    pub algo_sig: String,
    pub algo_kem: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TunCfg {
    pub interface: String,
    pub mtu: u16,
    /// Push the whole machine's default route through the tunnel (a true full
    /// VPN). When false, tor still engages and is usable as a local SOCKS/DNS
    /// proxy, but system traffic is NOT redirected — the safe mode for first-run
    /// testing before you trust the routing on your box. Defaults to true so a
    /// profile written before this knob existed still behaves as a full VPN.
    #[serde(default = "default_true")]
    pub full_tunnel: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TorCfg {
    pub socks_port: u16,
    pub dns_port: u16,
    pub control_port: u16,
    pub use_bridges: bool,
    pub client_transport_plugin: Option<String>,
    pub bridges: Vec<String>,
    /// Optional absolute path to tor.exe. If empty/None, we look in PATH then
    /// fall back to the bundled path next to the binary.
    pub tor_path_hint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tun2SocksCfg {
    pub binary: String,
}

/// Speed tuning. All have sane defaults so older profiles still load.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PerfCfg {
    /// How many parallel SOCKS ports tor should open. Each gets its own
    /// circuit pool, multiplying achievable throughput. 1 = vanilla.
    #[serde(default = "default_socks_ports")]
    pub parallel_socks_ports: u8,

    /// Drop circuits that take longer than this many seconds to build.
    /// Lower = pickier = faster average, but more rebuilds.
    #[serde(default = "default_circuit_build_timeout")]
    pub circuit_build_timeout_secs: u16,

    /// Number of guard nodes. Default tor = 1; raising to 3 widens the
    /// fast-path pool at minor anonymity cost.
    #[serde(default = "default_num_guards")]
    pub num_entry_guards: u8,

    /// Force IPv4-only to skip slow v6 paths. true unless you specifically
    /// need v6 connectivity.
    #[serde(default = "default_true")]
    pub ipv4_only: bool,

    /// Disable circuit padding (latency win, small fingerprinting cost).
    #[serde(default)]
    pub disable_padding: bool,
}

fn default_socks_ports() -> u8 {
    1
}
fn default_circuit_build_timeout() -> u16 {
    10
}
fn default_num_guards() -> u8 {
    3
}
fn default_true() -> bool {
    true
}

impl Default for PerfCfg {
    fn default() -> Self {
        Self {
            parallel_socks_ports: default_socks_ports(),
            circuit_build_timeout_secs: default_circuit_build_timeout(),
            num_entry_guards: default_num_guards(),
            ipv4_only: true,
            disable_padding: false,
        }
    }
}

/// Load from `path` if Some, otherwise the bundled default profile.
pub async fn load_or_default(profile: Option<&Path>) -> Result<Config> {
    if let Some(p) = profile {
        let bytes = fs::read(p)
            .await
            .with_context(|| format!("reading profile {}", p.display()))?;
        let s = std::str::from_utf8(&bytes).context("profile is not UTF-8")?;
        let cfg: Config = toml::from_str(s).context("parsing profile TOML")?;
        validate(&cfg)?;
        return Ok(cfg);
    }
    let s = include_str!("../../../profiles/default_win.toml");
    let cfg = toml::from_str(s).context("parsing bundled default profile")?;
    validate(&cfg)?;
    Ok(cfg)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The bundled default profile is compiled into the binary via include_str!;
    /// if it ever stops parsing, BOTH the service (no control server) and the
    /// tray (no client) die at startup — which looks exactly like "tray does
    /// nothing". Lock it down.
    #[test]
    fn bundled_default_profile_parses() {
        let cfg: Config = toml::from_str(include_str!("../../../profiles/default_win.toml"))
            .expect("default_win.toml must parse");
        assert!(cfg.status.enabled);
        assert_eq!(cfg.status.listen, "127.0.0.1:8787");
        assert!(cfg.perf.parallel_socks_ports >= 1);
    }

    #[test]
    fn bundled_obfs4_profile_parses() {
        let _cfg: Config = toml::from_str(include_str!("../../../profiles/obfs4_win.toml"))
            .expect("obfs4_win.toml must parse");
    }
}

/// The control API is local only. Unsupported transport combinations fail
/// before any firewall, DNS, or route changes are made.
pub fn validate(cfg: &Config) -> Result<()> {
    anyhow::ensure!(
        cfg.status.enabled,
        "[status].enabled must be true for the service/tray"
    );
    let addr: std::net::SocketAddr = cfg
        .status
        .listen
        .parse()
        .context("[status].listen must be a numeric loopback address:port")?;
    anyhow::ensure!(addr.ip().is_loopback(), "control API must bind to loopback");
    anyhow::ensure!(addr.port() != 0, "control API port must be nonzero");
    let ports = [cfg.tor.socks_port, cfg.tor.control_port, cfg.tor.dns_port];
    anyhow::ensure!(ports.iter().all(|p| *p != 0), "Tor ports must be nonzero");
    anyhow::ensure!(
        ports[0] != ports[1] && ports[0] != ports[2] && ports[1] != ports[2],
        "SOCKS, control, and DNS ports must be distinct"
    );
    anyhow::ensure!(
        cfg.tun.mtu >= 1280 && cfg.tun.mtu <= 9000,
        "TUN MTU must be 1280..9000"
    );
    anyhow::ensure!(
        !cfg.tun.interface.is_empty() && !cfg.tun.interface.contains(['\r', '\n']),
        "invalid tunnel name"
    );
    for cc in &cfg.exit.countries {
        anyhow::ensure!(
            cc.len() == 2 && cc.bytes().all(|b| b.is_ascii_alphabetic()),
            "exit countries must be two ASCII letters"
        );
    }
    if cfg.tun.full_tunnel {
        anyhow::ensure!(
            cfg.tor.dns_port == 53,
            "Windows NRPT requires [tor].dns_port = 53"
        );
        anyhow::ensure!(!cfg.tor.use_bridges && !cfg.proxy.enabled, "full tunnel currently supports direct Tor only; bridges/upstream proxies require proxy mode");
        anyhow::ensure!(
            cfg.perf.ipv4_only,
            "full tunnel requires ipv4_only = true; native IPv6 is blocked"
        );
    }
    anyhow::ensure!(
        !cfg.proxy.enabled,
        "Upstream proxy startup is not implemented safely; disable [proxy].enabled"
    );
    anyhow::ensure!(
        !cfg.hop.enabled,
        "Automatic hop plans are not supported in this repair build; use the exit-country menu"
    );
    anyhow::ensure!(
        !cfg.pqc.enabled,
        "PQC experiments do not encrypt Tor traffic; disable [pqc].enabled"
    );
    Ok(())
}

#[cfg(test)]
mod validation_tests {
    use super::*;
    #[tokio::test]
    async fn reject_conflicting_ports_and_remote_control_before_network_changes() {
        let cfg = load_or_default(None).await.unwrap();
        let mut bad = cfg.clone();
        bad.tor.control_port = bad.tor.socks_port;
        assert!(validate(&bad).is_err());
        bad = cfg.clone();
        bad.status.listen = "0.0.0.0:8787".into();
        assert!(validate(&bad).is_err());
        bad = cfg.clone();
        bad.tor.dns_port = 5353;
        assert!(validate(&bad).is_err());
        bad = cfg;
        bad.proxy.enabled = true;
        assert!(validate(&bad).is_err());
    }
}
