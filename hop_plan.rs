use anyhow::{Result, Context};
use crate::config::{Config, HopItem};
use crate::proxy_manager::ProxyManager;
use crate::tor_control::TorControl;
use humantime::parse_duration;
use rand::Rng;
use tokio::fs;
use tokio::time::{Instant, Duration};
use std::path::Path;

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct HopState {
    order: Vec<usize>,
    idx: usize,
    next_epoch_ms: u64,
}

fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64
}

pub async fn maybe_tick(cfg: &Config, state_dir: &Path) -> Result<()> {
    if !cfg.hop.enabled || cfg.hop.sequence.is_empty() { return Ok(()); }
    let state_path = state_dir.join("hop_state.json");
    let mut st: HopState = if let Ok(b) = fs::read(&state_path).await {
        serde_json::from_slice(&b).unwrap_or(HopState { idx: 0, next_epoch_ms: 0, order: vec![], randomized: false })
    } else { HopState { idx: 0, next_epoch_ms: 0, order: vec![], randomized: false } };

    if st.next_epoch_ms == 0 {
        st.order = (0..cfg.hop.sequence.len()).collect();
        if cfg.hop.randomize { st.order.shuffle(&mut rand::thread_rng()); }
        // initialize
        st.idx = 0;
        st.next_epoch_ms = now_ms();
    }

    if now_ms() >= st.next_epoch_ms {
        // Apply hop item
        let mut idx = st.idx;
        if idx >= cfg.hop.sequence.len() {
            if cfg.hop.loop_forever {
                idx = 0;
            } else {
                // disable once completed
                st.idx = idx;
                st.next_epoch_ms = u64::MAX;
                fs::write(&state_path, serde_json::to_vec_pretty(&st)?).await?;
                return Ok(());
            }
        }
        let mapped = if st.order.is_empty() { idx } else { st.order[idx] };
        let item = &cfg.hop.sequence[mapped];
        apply_item(cfg, state_dir, item).await?;

        // schedule next
        let mut dur = parse_duration(&item.duration).context("invalid hop duration")?;
        // apply jitter if defined
        if !cfg.hop.jitter.is_empty() {
            if let Ok(j) = parse_duration(&cfg.hop.jitter) {
                let jitter_ms = rand::thread_rng().gen_range(0..=j.as_millis() as u64);
                dur += Duration::from_millis(jitter_ms);
            }
        }
        st.idx = idx + 1;
        st.next_epoch_ms = now_ms() + dur.as_millis() as u64;
        fs::write(&state_path, serde_json::to_vec_pretty(&st)?).await?;
    }

    Ok(())
}

async fn apply_item(cfg: &Config, state_dir: &Path, item: &HopItem) -> Result<()> {
    let cookie = state_dir.join("tor-data").join("control_auth_cookie");
    let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
    let mut ctl = TorControl::connect(&addr, &cookie).await?;

    // Exit policy
    if !item.exit_countries.is_empty() {
        let list = item.exit_countries.iter().map(|c| format!("{{{}}}", c.to_lowercase())).collect::<Vec<_>>().join(",");
        ctl.set_conf("ExitNodes", &list).await?;
        ctl.set_conf("StrictNodes", "1").await?;
    }

    // Proxy selection
    match &item.proxy {
        None => { /* leave as-is */ }
        Some(s) if s.eq_ignore_ascii_case("next") => {
            if cfg.proxy.enabled {
                let mut pm = ProxyManager::load(&state_dir.to_path_buf()).await?;
                if let Some(p) = pm.current(cfg) {
                    apply_proxy(&mut ctl, p.typ.as_str(), &p.addr, p.username.as_deref(), p.password.as_deref()).await?;
                    pm.next(cfg);
                    let _ = pm.save(&state_dir.to_path_buf()).await;
                }
            }
        }
        Some(url) => {
            if url.starts_with("socks5://") {
                // strip scheme
                let addr = url.trim_start_matches("socks5://");
                apply_proxy(&mut ctl, "socks5", addr, None, None).await?;
            } else if url.starts_with("https://") {
                let addr = url.trim_start_matches("https://");
                apply_proxy(&mut ctl, "https", addr, None, None).await?;
            }
        }
    }

    // rotate circuits
    let _ = ctl.signal_newnym().await;
    Ok(())
}

async fn apply_proxy(ctl: &mut TorControl, typ: &str, addr: &str, user: Option<&str>, pass: Option<&str>) -> Result<()> {
    match typ {
        "socks5" => {
            ctl.set_conf("Socks5Proxy", addr).await?;
            if let Some(u) = user { ctl.set_conf("Socks5ProxyUsername", u).await?; }
            if let Some(pw) = pass { ctl.set_conf("Socks5ProxyPassword", pw).await?; }
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
