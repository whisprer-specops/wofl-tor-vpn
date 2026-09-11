use anyhow::{Result, bail};
use std::path::{Path, PathBuf};
use tokio::{fs, process::Command, io::{AsyncBufReadExt, BufReader}};
use crate::config::Config;

pub struct TorInstance {
    pid: i32,
}

impl TorInstance {
    pub fn pid(&self) -> i32 { self.pid }
    pub async fn start(cfg: &Config, state_dir: &PathBuf) -> Result<Self> {
        let tor_path = which::which("tor.exe").or_else(|_| which::which("tor"))?;
        let tor_data = state_dir.join("tor-data");
        fs::create_dir_all(&tor_data).await?;

        // Write torrc from template or inline
        let torrc_path = state_dir.join("torrc.generated");
        let torrc = generate_torrc(cfg, &tor_data)?;
        fs::write(&torrc_path, torrc).await?;

        let mut cmd = Command::new(tor_path);
        cmd.arg("-f").arg(&torrc_path);
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
        let mut child = cmd.spawn()?;
        let pid = child.id().unwrap_or_default() as i32;

        // Monitor bootstrap from stdout
        if let Some(out) = child.stdout.take() {
            let mut reader = BufReader::new(out).lines();
            let mut boot = 0u8;
            while let Some(line) = reader.next_line().await? {
                if let Some(p) = parse_bootstrap_percent(&line) {
                    if p > boot { boot = p; }
                    if boot >= 100 {
                        break;
                    }
                }
                if let Some(code) = child.try_wait()? {
                    bail!("tor exited early with {code:?}");
                }
            }
        }
        Ok(Self { pid })
    }
}

fn parse_bootstrap_percent(line: &str) -> Option<u8> {
    if let Some(idx) = line.find("Bootstrapped ") {
        let rest = &line[idx + "Bootstrapped ".len()..];
        if let Some(pct_str) = rest.split('%').next() {
            if let Ok(v) = pct_str.trim().parse::<u8>() {
                return Some(v);
            }
        }
    }
    None
}

fn generate_torrc(cfg: &Config, data_dir: &Path) -> Result<String> {
    let socks = cfg.tor.socks_port;
    let dns = cfg.tor.dns_port;
    let ctrl = cfg.tor.control_port;
    let bridges = cfg.tor.use_bridges;

    let mut s = String::new();
    s.push_str(&format!("DataDirectory {}\n", data_dir.display()));
    s.push_str("ClientOnly 1\n");
    s.push_str(&format!("SOCKSPort 127.0.0.1:{}\n", socks));
    s.push_str(&format!("DNSPort 127.0.0.1:{}\n", dns));
    s.push_str("AutomapHostsOnResolve 1\nAutomapHostsSuffixes .onion,.exit\n");
    s.push_str("ClientUseIPv4 1\nClientUseIPv6 1\nSafeSocks 1\n");
    s.push_str("UseGuardFraction 1\nCircuitPadding 1\nAvoidDiskWrites 1\n");
    s.push_str(&format!("ControlPort 127.0.0.1:{}\n", ctrl));
    s.push_str("CookieAuthentication 1\n");
    if bridges {
        s.push_str("UseBridges 1\n");
        for b in &cfg.tor.bridges {
            s.push_str(&format!("Bridge {}\n", b));
        }
        if let Some(obfs) = &cfg.tor.client_transport_plugin {
            s.push_str(&format!("ClientTransportPlugin obfs4 exec {}\n", obfs));
        }
    }
    Ok(s)
}


pub async fn apply_proxy_and_exit(cfg: &crate::config::Config, state_dir: &std::path::Path) -> anyhow::Result<()> {
    use crate::tor_control::TorControl;
    use crate::proxy_manager::ProxyManager;
    use tokio::time::{sleep, Duration};
    let cookie = state_dir.join("tor-data").join("control_auth_cookie");
    let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
    let mut ctl = TorControl::connect(&addr, &cookie).await?;

    // Exit policy
    if !cfg.exit.countries.is_empty() {
        let list = cfg.exit.countries.iter().map(|c| format!("{{{}}}", c.to_lowercase())).collect::<Vec<_>>().join(",");
        let strict = if cfg.exit.strict { "1" } else { "0" };
        ctl.set_conf("ExitNodes", &list).await?;
        ctl.set_conf("StrictNodes", strict).await?;
    } else {
        let _ = ctl.set_conf("ExitNodes", "").await;
        let _ = ctl.set_conf("StrictNodes", "0").await;
    }

    // Proxy (pre-Tor)
    if cfg.proxy.enabled {
        if let Ok(mut pm) = ProxyManager::load(&state_dir.to_path_buf()).await {
            if let Some(p) = pm.current(cfg) {
                match p.typ.as_str() {
                    "socks5" => {
                        ctl.set_conf("Socks5Proxy", &p.addr).await?;
                        if let Some(u) = &p.username { ctl.set_conf("Socks5ProxyUsername", u).await?; }
                        if let Some(pw) = &p.password { ctl.set_conf("Socks5ProxyPassword", pw).await?; }
                    },
                    "https" => {
                        ctl.set_conf("HTTPSProxy", &p.addr).await?;
                        if let Some(u) = &p.username { ctl.set_conf("HTTPSProxyAuthenticator", &format!("{}:{}", u, p.password.clone().unwrap_or_default())).await?; }
                    },
                    _ => {}
                }
                pm.next(cfg);
                let _ = pm.save(&state_dir.to_path_buf()).await;
                let _ = ctl.signal_newnym().await;
                sleep(Duration::from_millis(500)).await;
            }
        }
    } else {
        let _ = ctl.set_conf("Socks5Proxy", "").await;
        let _ = ctl.set_conf("HTTPSProxy", "").await;
    }
    Ok(())
}
