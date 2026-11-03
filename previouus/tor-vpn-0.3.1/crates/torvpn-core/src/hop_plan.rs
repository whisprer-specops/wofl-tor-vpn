//! Country/proxy hop scheduler. Called periodically by the service health
//! loop; advances the current hop when the dwell timer expires.

use anyhow::{Context, Result};
use humantime::parse_duration;
use rand::{seq::SliceRandom, Rng};
use serde::{Deserialize, Serialize};
use std::path::Path;
use tokio::fs;
use tokio::time::Duration;

use crate::config::{Config, HopItem};
use crate::proxy_manager::ProxyManager;
use crate::tor_control::TorControl;

#[derive(Serialize, Deserialize, Default)]
struct HopState {
    #[serde(default)]
    order: Vec<usize>,
    #[serde(default)]
    randomized: bool,
    #[serde(default)]
    idx: usize,
    #[serde(default)]
    next_epoch_ms: u64,
}

fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

pub async fn maybe_tick(cfg: &Config, state_dir: &Path) -> Result<()> {
    if !cfg.hop.enabled || cfg.hop.sequence.is_empty() {
        return Ok(());
    }

    let state_path = state_dir.join("hop_state.json");
    let mut st: HopState = match fs::read(&state_path).await {
        Ok(b) => serde_json::from_slice(&b).unwrap_or_default(),
        Err(_) => HopState::default(),
    };

    if st.next_epoch_ms == 0 {
        st.order = (0..cfg.hop.sequence.len()).collect();
        if cfg.hop.randomize {
            st.order.shuffle(&mut rand::thread_rng());
            st.randomized = true;
        }
        st.idx = 0;
        st.next_epoch_ms = now_ms();
    }

    if now_ms() < st.next_epoch_ms {
        return Ok(());
    }

    // Advance.
    if st.idx >= cfg.hop.sequence.len() {
        if cfg.hop.loop_forever {
            st.idx = 0;
            st.order = (0..cfg.hop.sequence.len()).collect();
            if cfg.hop.randomize {
                st.order.shuffle(&mut rand::thread_rng());
            }
        } else {
            st.next_epoch_ms = u64::MAX;
            fs::write(&state_path, serde_json::to_vec_pretty(&st)?).await?;
            return Ok(());
        }
    }

    let mapped = if st.order.is_empty() {
        st.idx
    } else {
        st.order[st.idx]
    };
    let item = &cfg.hop.sequence[mapped];
    apply_item(cfg, state_dir, item).await?;

    let mut dur = parse_duration(&item.duration).context("invalid hop duration")?;
    if !cfg.hop.jitter.is_empty() {
        if let Ok(j) = parse_duration(&cfg.hop.jitter) {
            let max = j.as_millis() as u64;
            if max > 0 {
                let jitter_ms = rand::thread_rng().gen_range(0..=max);
                dur += Duration::from_millis(jitter_ms);
            }
        }
    }
    st.idx += 1;
    st.next_epoch_ms = now_ms() + dur.as_millis() as u64;
    fs::write(&state_path, serde_json::to_vec_pretty(&st)?).await?;
    Ok(())
}

async fn apply_item(cfg: &Config, state_dir: &Path, item: &HopItem) -> Result<()> {
    let cookie = state_dir.join("tor-data").join("control_auth_cookie");
    let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
    let mut ctl = TorControl::connect(&addr, &cookie).await?;

    if !item.exit_countries.is_empty() {
        let list = item
            .exit_countries
            .iter()
            .map(|c| format!("{{{}}}", c.to_lowercase()))
            .collect::<Vec<_>>()
            .join(",");
        ctl.set_conf("ExitNodes", &list).await?;
        ctl.set_conf("StrictNodes", "1").await?;
    }

    match &item.proxy {
        None => {}
        Some(s) if s.eq_ignore_ascii_case("next") => {
            if cfg.proxy.enabled {
                let mut pm = ProxyManager::load(state_dir).await?;
                if let Some(p) = pm.current(cfg) {
                    apply_proxy(
                        &mut ctl,
                        &p.typ,
                        &p.addr,
                        p.username.as_deref(),
                        p.password.as_deref(),
                    )
                    .await?;
                    pm.next(cfg);
                    let _ = pm.save(state_dir).await;
                }
            }
        }
        Some(url) if url.starts_with("socks5://") => {
            let addr = url.trim_start_matches("socks5://");
            apply_proxy(&mut ctl, "socks5", addr, None, None).await?;
        }
        Some(url) if url.starts_with("https://") => {
            let addr = url.trim_start_matches("https://");
            apply_proxy(&mut ctl, "https", addr, None, None).await?;
        }
        Some(_) => {}
    }

    let _ = ctl.signal_newnym().await;
    Ok(())
}

async fn apply_proxy(
    ctl: &mut TorControl,
    typ: &str,
    addr: &str,
    user: Option<&str>,
    pass: Option<&str>,
) -> Result<()> {
    match typ {
        "socks5" => {
            ctl.set_conf("Socks5Proxy", addr).await?;
            if let Some(u) = user {
                ctl.set_conf("Socks5ProxyUsername", u).await?;
            }
            if let Some(pw) = pass {
                ctl.set_conf("Socks5ProxyPassword", pw).await?;
            }
        }
        "https" => {
            ctl.set_conf("HTTPSProxy", addr).await?;
            if let Some(u) = user {
                let auth = format!("{}:{}", u, pass.unwrap_or(""));
                ctl.set_conf("HTTPSProxyAuthenticator", &auth).await?;
            }
        }
        _ => {}
    }
    Ok(())
}
