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
    pub randomize: bool,
    pub loop_forever: bool,
    pub jitter: String,
    pub sequence: Vec<HopItem>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HopItem {
    pub duration: String,
    pub exit_countries: Vec<String>,
    pub proxy: Option<String>,   // "next" or "socks5://host:port" or "https://host:port"
}


#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ProxyCfg {
    pub enabled: bool,
    pub rotation: String, // "sequential" | "random" | "off"
    pub proxies: Vec<ProxyItem>,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ProxyItem {
    pub typ: String,      // "socks5" | "https"
    pub addr: String,     // "host:port"
    pub username: Option<String>,
    pub password: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ExitCfg {
    pub countries: Vec<String>, // ["us","de"]
    pub strict: bool,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PqcCfg {
    pub enabled: bool,
    pub algo_sig: String,   // "dilithium2"
    pub algo_kem: String,   // "kyber1024"
}

use tokio::fs;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub status: StatusCfg,
    pub hop: HopCfg,
    pub proxy: ProxyCfg,
    pub exit: ExitCfg,
    pub pqc: PqcCfg,
    pub tun: TunCfg,
    pub tor: TorCfg,
    pub tun2socks: Tun2SocksCfg,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TunCfg {
    pub interface: String,   // e.g., "torvpn" (Wintun adapter name)
    pub mtu: u16,            // default 1400
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TorCfg {
    pub socks_port: u16,     // 9050
    pub dns_port: u16,       // 5353
    pub control_port: u16,   // 9051
    pub use_bridges: bool,
    pub client_transport_plugin: Option<String>,
    pub bridges: Vec<String>,
    pub tor_path_hint: Option<String>, // optional path to tor.exe
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tun2SocksCfg {
    pub binary: String,      // "tun2socks.exe"
}

pub async fn load_or_default(profile: Option<&std::path::Path>) -> Result<Config> {
    if let Some(p) = profile {
        let bytes = fs::read(p).await?;
        let cfg: Config = toml::from_slice(&bytes)?;
        Ok(cfg)
    } else {
        let s = include_str!("../profiles/default_win.toml");
        let cfg: Config = toml::from_str(s)?;
        Ok(cfg)
    }
}
