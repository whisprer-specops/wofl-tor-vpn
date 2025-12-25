use anyhow::{Result, bail};
use tokio::process::Command;
use crate::config::Config;

pub struct Tun2Socks {
    pid: i32,
}

impl Tun2Socks {
    pub fn pid(&self) -> i32 { self.pid }

    pub async fn start(cfg: &Config) -> Result<Self> {
        // We expect an external tun2socks binary in PATH.
        let bin = which::which(&cfg.tun2socks.binary)?;
        let tun = &cfg.tun.interface;
        let socks = cfg.tor.socks_port;
        let mtu = cfg.tun.mtu;

        // Common go-tun2socks syntax:
        // tun2socks -device tun://<name> -proxy socks5://127.0.0.1:<port> -mtu <mtu>
        let mut cmd = Command::new(bin);
        cmd.arg("-device").arg(format!("tun://{}", tun))
           .arg("-proxy").arg(format!("socks5://127.0.0.1:{}", socks))
           .arg("-mtu").arg(mtu.to_string());
        cmd.stdout(std::process::Stdio::null());
        cmd.stderr(std::process::Stdio::inherit());
        let child = cmd.spawn()?;
        let pid = child.id().unwrap_or_default() as i32;

        // We don't await; long-running daemon
        Ok(Self { pid })
    }
}
