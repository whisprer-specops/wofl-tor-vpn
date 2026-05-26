use anyhow::{Result};
use tokio::process::Command;
use crate::config::Config;

pub struct Tun2Socks {
    pid: i32,
}

impl Tun2Socks {
    pub fn pid(&self) -> i32 { self.pid }

    pub async fn start(cfg: &Config) -> Result<Self> {
        // Expect external tun2socks.exe that supports Wintun
        let bin = which::which(&cfg.tun2socks.binary)?;
        let ifname = &cfg.tun.interface;
        let socks = cfg.tor.socks_port;
        let mtu = cfg.tun.mtu;

        // Typical go-tun2socks Windows usage:
        // tun2socks.exe -device wintun://<name> -proxy socks5://127.0.0.1:<port> -mtu <mtu>
        let mut cmd = Command::new(bin);
        cmd.arg("-device").arg(format!("wintun://{}", ifname))
           .arg("-proxy").arg(format!("socks5://127.0.0.1:{}", socks))
           .arg("-mtu").arg(mtu.to_string());
        cmd.creation_flags(0x00000008); // CREATE_NO_WINDOW
        cmd.stdout(std::process::Stdio::null());
        cmd.stderr(std::process::Stdio::inherit());
        let child = cmd.spawn()?;
        let pid = child.id().unwrap_or_default() as i32;
        Ok(Self { pid })
    }
}
