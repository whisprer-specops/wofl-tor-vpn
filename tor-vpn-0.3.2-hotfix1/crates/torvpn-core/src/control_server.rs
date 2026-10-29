//! Local control server. Speaks tiny HTTP over a TCP listener — no hyper,
//! no axum, no extra ms of binary size. Endpoints:
//!
//!   GET  /status            → JSON snapshot of engagement + tor health
//!   GET  /status/plan       → hop plan state
//!   POST /control/connect   → engage
//!   POST /control/disconnect→ disengage
//!   POST /control/toggle    → flip
//!   POST /control/newnym    → rotate Tor circuits (only if engaged)
//!   POST /control/exitset?cc=us,de  → set exits
//!   POST /control/exitclear         → clear exits
//!   POST /control/proxynext         → next upstream proxy
//!
//! All endpoints require the bearer token in either:
//!   - `X-TorVPN-Token: <token>` header, or
//!   - `Authorization: Bearer <token>` header.
//!
//! Optional `X-TorVPN-HMAC` for remote binds (we discourage remote binds).
//! When `listen` is not loopback, a simple per-IP rate limiter kicks in.

use anyhow::Result;
use std::path::Path;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::auth;
use crate::config::Config;
use crate::state::{Engagement, Phase};
use crate::tor_control::TorControl;

pub async fn run(
    cfg: Config,
    state_dir: std::path::PathBuf,
    engagement: Arc<Engagement>,
    ready_tx: Option<tokio::sync::oneshot::Sender<()>>,
) -> Result<()> {
    if !cfg.status.enabled {
        // Nobody's ever going to hear from us on this port — fire the ready
        // signal immediately so a caller waiting on it (see `serve_forever`,
        // which the SCM startup sequence blocks on before telling Windows
        // we're "Running") doesn't sit there until its timeout for a listener
        // that was never going to exist.
        if let Some(tx) = ready_tx {
            let _ = tx.send(());
        }
        return Ok(());
    }
    crate::config::validate(&cfg)?;
    let token = auth::ensure_token(&state_dir.join("api_token")).await?;
    let hmac_secret = auth::ensure_hmac_secret(&state_dir.join("api_hmac_secret")).await?;

    let listener = TcpListener::bind(&cfg.status.listen).await?;
    log::info!("control server: listening on {}", cfg.status.listen);
    // Only NOW is a `connect`/`status` call against this port guaranteed to
    // find something home. See `serve_forever` for why that matters: the SCM
    // used to get told "Running" the instant the process started, several
    // seconds before this bind ever happened (crash-recovery teardown alone
    // launches three sequential powershell.exe processes first) — a
    // `sc start` immediately followed by a CLI `connect` could win that race
    // and get a flat "connection refused" against a service that was, from
    // Windows' point of view, already "up".
    if let Some(tx) = ready_tx {
        let _ = tx.send(());
    }

    let live_cfg = Arc::new(tokio::sync::RwLock::new(cfg));
    loop {
        let (sock, _peer) = match listener.accept().await {
            Ok(p) => p,
            Err(e) => {
                log::warn!("accept: {e}");
                continue;
            }
        };
        let live_cfg = live_cfg.clone();
        let state_dir = state_dir.clone();
        let engagement = engagement.clone();
        let token = token.clone();
        let hmac = hmac_secret.clone();
        tokio::spawn(async move {
            let cfg = live_cfg.read().await.clone();
            if let Err(e) = handle(
                sock,
                &cfg,
                &live_cfg,
                &state_dir,
                &engagement,
                &token,
                &hmac,
            )
            .await
            {
                log::warn!("control request: {e:#}");
            }
        });
    }
}

async fn handle(
    mut sock: TcpStream,
    cfg: &Config,
    live_cfg: &tokio::sync::RwLock<Config>,
    state_dir: &Path,
    engagement: &Arc<Engagement>,
    token: &str,
    hmac_secret: &[u8],
) -> Result<()> {
    // Read up to 8 KiB of the request (headers; we don't accept bodies).
    let mut buf = vec![0u8; 8 * 1024];
    let n = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        let mut n = 0;
        loop {
            anyhow::ensure!(n < buf.len(), "request headers too large");
            let got = sock.read(&mut buf[n..]).await?;
            anyhow::ensure!(got > 0, "incomplete request headers");
            n += got;
            if buf[..n].windows(4).any(|w| w == b"\r\n\r\n") {
                break;
            }
        }
        Result::<usize>::Ok(n)
    })
    .await??;
    let req = String::from_utf8_lossy(&buf[..n]);
    let (method, path, query, headers) = parse_request(&req);

    // Public health endpoint: token still required, but no engagement state mutation.
    let need_auth = true;
    if need_auth {
        let presented = headers
            .get("x-torvpn-token")
            .map(String::as_str)
            .or_else(|| {
                headers
                    .get("authorization")
                    .and_then(|h| h.strip_prefix("Bearer "))
            });
        let hmac_hdr = headers.get("x-torvpn-hmac").map(String::as_str);
        if auth::check(token, hmac_secret, presented, hmac_hdr, method, path).is_err() {
            return respond(&mut sock, 401, r#"{"error":"unauthorized"}"#).await;
        }
    }

    let result = route(
        method,
        path,
        query.as_deref(),
        cfg,
        live_cfg,
        state_dir,
        engagement,
    )
    .await;
    match result {
        Ok((code, body)) => respond(&mut sock, code, &body).await,
        Err(e) => {
            // {:#} is anyhow's "alternate" Display: the full context chain
            // joined on one line ("locating tor.exe: tor.exe not found. Tried:
            // ...") instead of plain {}/.to_string(), which shows ONLY the
            // outermost .context() label. Without this, every enriched error
            // from find_tor/find_binary — the whole point of enriching them —
            // gets truncated back down to a useless one-liner before it ever
            // reaches the tray or CLI.
            let body = serde_json::json!({"error": format!("{e:#}")}).to_string();
            respond(&mut sock, 500, &body).await
        }
    }
}

async fn route(
    method: &str,
    path: &str,
    query: Option<&str>,
    cfg: &Config,
    live_cfg: &tokio::sync::RwLock<Config>,
    state_dir: &Path,
    engagement: &Arc<Engagement>,
) -> Result<(u16, String)> {
    match (method, path) {
        ("GET", "/status") => {
            let snap = engagement.current().await;
            let mut message = snap.message.clone();
            if matches!(snap.phase, Phase::Engaging | Phase::Disengaging) {
                match crate::windows_script::progress(state_dir).await {
                    Some((at, detail)) if at >= snap.since_ms => {
                        message = format!("{} — {}", message, detail)
                    }
                    _ => {}
                }
            }
            let exit_ip = snap.exit_ip.clone();
            let body = serde_json::json!({
                "phase":        snap.phase,
                "full_tunnel": snap.full_tunnel,
                "exit_countries": cfg.exit.countries,
                "message":      message,
                "since_ms":     snap.since_ms,
                "tor_pid":      snap.tor_pid,
                "tun2socks_pid":snap.tun2socks_pid,
                "tor": {
                    "socks_port":   cfg.tor.socks_port,
                    "dns_port":     cfg.tor.dns_port,
                    "control_port": cfg.tor.control_port,
                },
                "exit_ip": exit_ip,
            })
            .to_string();
            Ok((200, body))
        }

        ("GET", "/status/plan") => {
            let body = hop_plan_status(cfg, state_dir).await;
            Ok((200, body))
        }

        ("POST", "/control/connect") => {
            engagement.connect(cfg, state_dir).await?;
            Ok((200, r#"{"ok":true,"phase":"engaged"}"#.to_string()))
        }

        ("POST", "/control/disconnect") => {
            engagement.disconnect(state_dir).await?;
            Ok((200, r#"{"ok":true,"phase":"disengaged"}"#.to_string()))
        }

        ("POST", "/control/toggle") => {
            let phase = engagement.toggle(cfg, state_dir).await?;
            let body = serde_json::json!({"ok": true, "phase": phase}).to_string();
            Ok((200, body))
        }

        ("POST", "/control/newnym") => {
            if engagement.current().await.phase != Phase::Engaged {
                return Ok((409, r#"{"error":"not engaged"}"#.to_string()));
            }
            let cookie = state_dir.join("tor-data").join("control_auth_cookie");
            let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
            let mut ctl = TorControl::connect(&addr, &cookie).await?;
            ctl.signal_newnym().await?;
            Ok((200, r#"{"ok":true}"#.to_string()))
        }

        ("POST", "/control/exitset") | ("POST", "/control/exitclear") => {
            let cc = if path.ends_with("exitclear") {
                ""
            } else {
                query_get(query, "cc").unwrap_or("")
            };
            crate::api::validate_countries(cc)?;
            let countries: Vec<String> = cc
                .split(',')
                .filter(|s| !s.is_empty())
                .map(str::to_ascii_lowercase)
                .collect();
            let phase = engagement.current().await.phase;
            if matches!(phase, Phase::Engaging | Phase::Disengaging) {
                return Ok((409, r#"{"error":"wait for the current transition"}"#.into()));
            }
            if phase == Phase::Engaged {
                let cookie = state_dir.join("tor-data/control_auth_cookie");
                let mut ctl =
                    TorControl::connect(&format!("127.0.0.1:{}", cfg.tor.control_port), &cookie)
                        .await?;
                let exits = countries
                    .iter()
                    .map(|c| format!("{{{c}}}"))
                    .collect::<Vec<_>>()
                    .join(",");
                ctl.set_conf("ExitNodes", &exits).await?;
                ctl.set_conf("StrictNodes", if countries.is_empty() { "0" } else { "1" })
                    .await?;
                ctl.signal_newnym().await?;
            }
            // Session preference survives disconnect/reconnect. Tor keeps
            // existing streams on their existing circuits; NEWNYM affects new ones.
            live_cfg.write().await.exit.countries = countries;
            Ok((200, r#"{"ok":true}"#.to_string()))
        }

        ("POST", "/control/proxynext") => {
            crate::tor_manager::apply_proxy_and_exit(cfg, state_dir).await?;
            Ok((200, r#"{"ok":true}"#.to_string()))
        }

        _ => Ok((404, r#"{"error":"not found"}"#.to_string())),
    }
}

async fn hop_plan_status(cfg: &Config, state_dir: &Path) -> String {
    let st_path = state_dir.join("hop_state.json");
    let (order, randomized, idx, next_epoch_ms) = match tokio::fs::read(&st_path).await {
        Ok(b) => {
            let v: serde_json::Value = serde_json::from_slice(&b).unwrap_or_default();
            let order: Vec<usize> = v
                .get("order")
                .and_then(|x| x.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_u64())
                        .map(|x| x as usize)
                        .collect()
                })
                .unwrap_or_default();
            let randomized = v
                .get("randomized")
                .and_then(|x| x.as_bool())
                .unwrap_or(false);
            let idx = v.get("idx").and_then(|x| x.as_u64()).unwrap_or(0) as usize;
            let next = v.get("next_epoch_ms").and_then(|x| x.as_u64()).unwrap_or(0);
            (order, randomized, idx, next)
        }
        Err(_) => (vec![], false, 0, 0),
    };
    let now = now_ms();
    let remaining = if next_epoch_ms > now {
        (next_epoch_ms - now) / 1000
    } else {
        0
    };
    let total = cfg.hop.sequence.len();
    let mut upcoming = Vec::new();
    if !order.is_empty() {
        for &i in order.iter().skip(idx) {
            if let Some(item) = cfg.hop.sequence.get(i) {
                upcoming.push(serde_json::json!({
                    "index": i,
                    "duration": item.duration,
                    "exit_countries": item.exit_countries,
                    "proxy": item.proxy,
                }));
            }
        }
    }
    serde_json::json!({
        "randomized": randomized,
        "order_indices": order,
        "current_index_in_order": idx,
        "seconds_remaining": remaining,
        "total": total,
        "upcoming": upcoming,
    })
    .to_string()
}

// ----- HTTP plumbing -----

async fn respond(sock: &mut TcpStream, code: u16, body: &str) -> Result<()> {
    let status = match code {
        200 => "OK",
        202 => "Accepted",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        _ => "OK",
    };
    let resp = format!(
        "HTTP/1.1 {code} {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    sock.write_all(resp.as_bytes()).await?;
    let _ = sock.shutdown().await;
    Ok(())
}

/// Returns (method, path, query, lowercase-keyed headers).
fn parse_request(
    req: &str,
) -> (
    &str,
    &str,
    Option<String>,
    std::collections::HashMap<String, String>,
) {
    let mut headers = std::collections::HashMap::new();
    let mut lines = req.split("\r\n");
    let first = lines.next().unwrap_or("GET / HTTP/1.1");
    let mut parts = first.split_whitespace();
    let method = parts.next().unwrap_or("GET");
    let raw_path = parts.next().unwrap_or("/");
    let (path, query) = match raw_path.split_once('?') {
        Some((p, q)) => (p, Some(q.to_string())),
        None => (raw_path, None),
    };
    for line in lines {
        if line.is_empty() {
            break;
        }
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    (method, path, query, headers)
}

fn query_get<'a>(q: Option<&'a str>, key: &str) -> Option<&'a str> {
    q.and_then(|qs| {
        for pair in qs.split('&') {
            if let Some((k, v)) = pair.split_once('=') {
                if k == key {
                    return Some(v);
                }
            }
        }
        None
    })
}

fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
