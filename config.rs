use anyhow::Result;
use serde::{Serialize, Deserialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusCfg {
    pub enabled: bool,
    pub listen: String,  // e.g., "127.0.0.1:18081"
}


#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HopCfg {
    pub enabled: bool,
    pub randomize: bool,    // shuffle sequence each cycle
    pub loop_forever: bool, // loop at end
    pub jitter: String,     // e.g., "30s" max jitter added to each hop
    pub sequence: Vec<HopItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HopItem {
    pub duration: String,          // "15m", "1h"
    pub exit_countries: Vec<String>,
    pub proxy: Option<String>,     // "next" or "socks5://host:port" or "https://host:port"
}


#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyCfg {
    pub enabled: bool,
    pub rotation: String, // "sequential" | "random" | "off"
    pub proxies: Vec<ProxyItem>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyItem {
    pub typ: String,      // "socks5" | "https"
    pub addr: String,     // "host:port"
    pub username: Option<String>,
    pub password: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExitCfg {
    pub countries: Vec<String>, // ["us","de"]
    pub strict: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PqcCfg {
    pub enabled: bool,
    pub algo_sig: String,   // "dilithium2"
    pub algo_kem: String,   // "kyber1024"
}


#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecurityCfg {
    pub allow_uids: Vec<u32>,    // additional UIDs allowed direct egress (e.g., tor)
    pub tor_user: String,        // username to resolve and auto-allow (e.g., "tor")
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetCfg {
    pub mode: String,        // "tun2socks" or "transparent"
}
use tokio::fs;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub status: StatusCfg,
    pub hop: HopCfg,
    pub security: SecurityCfg,
    pub net: NetCfg,
    pub tun: TunCfg,
    pub tor: TorCfg,
    pub tun2socks: Tun2SocksCfg,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TunCfg {
    pub interface: String,   // e.g., "tun0"
    pub cidr: String,        // e.g., "10.111.0.1/30"
    pub mtu: u16,            // e.g., 1500 -> often 1400 for VPNs
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TorCfg {
    pub socks_port: u16,     // 9050
    pub trans_port: u16,    // 9040 (transparent mode)
    pub dns_port: u16,       // 5353
    pub control_port: u16,   // 9051
    pub use_bridges: bool,
    pub client_transport_plugin: Option<String>,
    pub bridges: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tun2SocksCfg {
    pub binary: String,      // "tun2socks"
}

pub async fn load_or_default(profile: Option<&std::path::Path>) -> Result<Config> {
    if let Some(p) = profile {
        let bytes = fs::read(p).await?;
        let cfg: Config = toml::from_slice(&bytes)?;
        Ok(cfg)
    } else {
        let s = include_str!("../profiles/default.toml");
        let cfg: Config = toml::from_str(s)?;
        Ok(cfg)
    }
}
