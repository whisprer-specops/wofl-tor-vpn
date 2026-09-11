//! Profile loader. Default profile is bundled as a TOML string; user can
//! override per-deploy with a file at `%PROGRAMDATA%\torvpn\profile.toml`.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;
use tokio::fs;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub status:    StatusCfg,
    pub hop:       HopCfg,
    pub proxy:     ProxyCfg,
    pub exit:      ExitCfg,
    pub pqc:       PqcCfg,
    pub tun:       TunCfg,
    pub tor:       TorCfg,
    pub tun2socks: Tun2SocksCfg,
    /// Speed / latency tuning knobs (new in 0.2).
    #[serde(default)]
    pub perf:      PerfCfg,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusCfg {
    pub enabled: bool,
    /// Loopback only by default — tray app contacts this. e.g. "127.0.0.1:8787".
    pub listen:  String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HopCfg {
    pub enabled:      bool,
    pub randomize:    bool,
    pub loop_forever: bool,
    pub jitter:       String,
    pub sequence:     Vec<HopItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HopItem {
    pub duration:       String,
    pub exit_countries: Vec<String>,
    /// "next" | "socks5://h:p" | "https://h:p" | None
    pub proxy:          Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyCfg {
    pub enabled:  bool,
    pub rotation: String, // "sequential" | "random" | "off"
    pub proxies:  Vec<ProxyItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyItem {
    pub typ:      String, // "socks5" | "https"
    pub addr:     String, // "host:port"
    pub username: Option<String>,
    pub password: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExitCfg {
    pub countries: Vec<String>,
    pub strict:    bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PqcCfg {
    pub enabled:  bool,
    pub algo_sig: String,
    pub algo_kem: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TunCfg {
    pub interface: String,
    pub mtu:       u16,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TorCfg {
    pub socks_port:              u16,
    pub dns_port:                u16,
    pub control_port:            u16,
    pub use_bridges:             bool,
    pub client_transport_plugin: Option<String>,
    pub bridges:                 Vec<String>,
    /// Optional absolute path to tor.exe. If empty/None, we look in PATH then
    /// fall back to the bundled path next to the binary.
    pub tor_path_hint:           Option<String>,
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
    #[serde(default = "default_true")]
    pub disable_padding: bool,
}

fn default_socks_ports() -> u8 { 4 }
fn default_circuit_build_timeout() -> u16 { 10 }
fn default_num_guards() -> u8 { 3 }
fn default_true() -> bool { true }

impl Default for PerfCfg {
    fn default() -> Self {
        Self {
            parallel_socks_ports:        default_socks_ports(),
            circuit_build_timeout_secs:  default_circuit_build_timeout(),
            num_entry_guards:            default_num_guards(),
            ipv4_only:                   true,
            disable_padding:             true,
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
        return Ok(cfg);
    }
    let s = include_str!("../../../profiles/default_win.toml");
    Ok(toml::from_str(s).context("parsing bundled default profile")?)
}
