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
) -> Result<()> {
    if !cfg.status.enabled { return Ok(()); }
    let token = auth::ensure_token(&state_dir.join("api_token")).await?;
    let hmac_secret = auth::ensure_hmac_secret(&state_dir.join("api_hmac_secret")).await?;

    let listener = TcpListener::bind(&cfg.status.listen).await?;
    log::info!("control server: listening on {}", cfg.status.listen);

    loop {
        let (sock, peer) = match listener.accept().await {
            Ok(p) => p,
            Err(e) => { log::warn!("accept: {e}"); continue; }
        };
        let cfg       = cfg.clone();
        let state_dir = state_dir.clone();
        let engagement = engagement.clone();
        let token     = token.clone();
        let hmac      = hmac_secret.clone();
        tokio::spawn(async move {
            let _ = handle(sock, peer.to_string(), &cfg, &state_dir, &engagement, &token, &hmac).await;
        });
    }
}

async fn handle(
    mut sock: TcpStream,
    peer: String,
    cfg: &Config,
    state_dir: &Path,
    engagement: &Arc<Engagement>,
    token: &str,
    hmac_secret: &[u8],
) -> Result<()> {
    // Read up to 8 KiB of the request (headers; we don't accept bodies).
    let mut buf = vec![0u8; 8 * 1024];
    let n = sock.read(&mut buf).await?;
    let req = String::from_utf8_lossy(&buf[..n]);
    let (method, path, query, headers) = parse_request(&req);

    // Rate limit on non-loopback only.
    if !cfg.status.listen.starts_with("127.0.0.1") {
        if rate_limit_check(state_dir, &peer).await.is_err() {
            return respond(&mut sock, 429, r#"{"error":"too many requests"}"#).await;
        }
    }

    // Public health endpoint: token still required, but no engagement state mutation.
    let need_auth = true;
    if need_auth {
        let presented = headers.get("x-torvpn-token").map(String::as_str)
            .or_else(|| {
                headers.get("authorization")
                    .and_then(|h| h.strip_prefix("Bearer "))
            });
        let hmac_hdr = headers.get("x-torvpn-hmac").map(String::as_str);
        if auth::check(token, hmac_secret, presented, hmac_hdr, method, path).is_err() {
            return respond(&mut sock, 401, r#"{"error":"unauthorized"}"#).await;
        }
    }

    let result = route(method, path, query.as_deref(), cfg, state_dir, engagement).await;
    match result {
        Ok((code, body)) => respond(&mut sock, code, &body).await,
        Err(e) => {
            let body = serde_json::json!({"error": e.to_string()}).to_string();
            respond(&mut sock, 500, &body).await
        }
    }
}

async fn route(
    method: &str,
    path: &str,
    query: Option<&str>,
    cfg: &Config,
    state_dir: &Path,
    engagement: &Arc<Engagement>,
) -> Result<(u16, String)> {
    match (method, path) {
        ("GET", "/status") => {
            let snap = engagement.current().await;
            let exit_ip = if snap.phase == Phase::Engaged {
                get_exit_ip_via_socks(cfg.tor.socks_port).await.ok()
            } else { None };
            let body = serde_json::json!({
                "phase":        snap.phase,
                "message":      snap.message,
                "since_ms":     snap.since_ms,
                "tor_pid":      snap.tor_pid,
                "tun2socks_pid":snap.tun2socks_pid,
                "tor": {
                    "socks_port":   cfg.tor.socks_port,
                    "dns_port":     cfg.tor.dns_port,
                    "control_port": cfg.tor.control_port,
                },
                "exit_ip": exit_ip,
            }).to_string();
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

        ("POST", "/control/exitset") => {
            let cc = query_get(query, "cc").unwrap_or("");
            let list: Vec<String> = cc.split(',')
                .map(|s| s.trim().to_lowercase())
                .filter(|s| !s.is_empty())
                .map(|s| format!("{{{}}}", s)).collect();
            let cookie = state_dir.join("tor-data").join("control_auth_cookie");
            let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
            let mut ctl = TorControl::connect(&addr, &cookie).await?;
            if list.is_empty() {
                let _ = ctl.set_conf("ExitNodes", "").await;
                let _ = ctl.set_conf("StrictNodes", "0").await;
            } else {
                let joined = list.join(",");
                ctl.set_conf("ExitNodes", &joined).await?;
                ctl.set_conf("StrictNodes", "1").await?;
            }
            let _ = ctl.signal_newnym().await;
            Ok((200, r#"{"ok":true}"#.to_string()))
        }

        ("POST", "/control/exitclear") => {
            let cookie = state_dir.join("tor-data").join("control_auth_cookie");
            let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
            let mut ctl = TorControl::connect(&addr, &cookie).await?;
            let _ = ctl.set_conf("ExitNodes", "").await;
            let _ = ctl.set_conf("StrictNodes", "0").await;
            let _ = ctl.signal_newnym().await;
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
            let order: Vec<usize> = v.get("order").and_then(|x| x.as_array())
                .map(|a| a.iter().filter_map(|x| x.as_u64()).map(|x| x as usize).collect())
                .unwrap_or_default();
            let randomized = v.get("randomized").and_then(|x| x.as_bool()).unwrap_or(false);
            let idx = v.get("idx").and_then(|x| x.as_u64()).unwrap_or(0) as usize;
            let next = v.get("next_epoch_ms").and_then(|x| x.as_u64()).unwrap_or(0);
            (order, randomized, idx, next)
        }
        Err(_) => (vec![], false, 0, 0),
    };
    let now = now_ms();
    let remaining = if next_epoch_ms > now { (next_epoch_ms - now) / 1000 } else { 0 };
    let total = cfg.hop.sequence.len();
    let mut upcoming = Vec::new();
    if !order.is_empty() {
        for k in idx..order.len() {
            let i = order[k];
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
    }).to_string()
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
fn parse_request(req: &str) -> (&str, &str, Option<String>, std::collections::HashMap<String, String>) {
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
        if line.is_empty() { break; }
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
                if k == key { return Some(v); }
            }
        }
        None
    })
}

fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64
}

async fn rate_limit_check(state_dir: &Path, peer: &str) -> Result<()> {
    let p = state_dir.join("rate_limit.json");
    let now = now_ms();
    let mut map: serde_json::Value = match tokio::fs::read(&p).await {
        Ok(b) => serde_json::from_slice(&b).unwrap_or(serde_json::json!({})),
        Err(_) => serde_json::json!({}),
    };
    let ip = peer.split(':').next().unwrap_or(peer);
    let ent = map.get(ip).cloned()
        .unwrap_or(serde_json::json!({"last_ms":0,"burst":0,"win_ms":now,"count":0}));
    let last  = ent.get("last_ms").and_then(|x| x.as_u64()).unwrap_or(0);
    let burst = ent.get("burst").and_then(|x| x.as_u64()).unwrap_or(0);
    let mut win_ms = ent.get("win_ms").and_then(|x| x.as_u64()).unwrap_or(now);
    let mut count  = ent.get("count").and_then(|x| x.as_u64()).unwrap_or(0);

    let new_burst = if now > last + 1000 { 0 } else { burst + 1 };
    if now > win_ms + 60_000 { win_ms = now; count = 0; }
    count += 1;
    if new_burst > 5 || count > 120 {
        return Err(anyhow::anyhow!("rate limited"));
    }
    map.as_object_mut().unwrap().insert(ip.to_string(), serde_json::json!({
        "last_ms": now, "burst": new_burst, "win_ms": win_ms, "count": count,
    }));
    let _ = tokio::fs::write(&p, serde_json::to_vec_pretty(&map)?).await;
    Ok(())
}

/// Plain SOCKS5 → api.ipify.org probe. Used by /status when engaged.
async fn get_exit_ip_via_socks(socks_port: u16) -> Result<String> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut s = TcpStream::connect(("127.0.0.1", socks_port)).await?;
    s.write_all(&[0x05, 0x01, 0x00]).await?;
    let mut resp = [0u8; 2];
    s.read_exact(&mut resp).await?;
    if resp != [0x05, 0x00] { anyhow::bail!("socks auth failed"); }
    let host = "api.ipify.org";
    let hb = host.as_bytes();
    let port: u16 = 80;
    let mut req = Vec::with_capacity(7 + hb.len());
    req.extend_from_slice(&[0x05, 0x01, 0x00, 0x03, hb.len() as u8]);
    req.extend_from_slice(hb);
    req.extend_from_slice(&[(port >> 8) as u8, (port & 0xff) as u8]);
    s.write_all(&req).await?;
    let mut hdr = [0u8; 4];
    s.read_exact(&mut hdr).await?;
    if hdr[1] != 0x00 { anyhow::bail!("socks connect failed"); }
    match hdr[3] {
        0x01 => { let mut skip = [0u8; 6]; s.read_exact(&mut skip).await?; }
        0x03 => { let mut len = [0u8; 1]; s.read_exact(&mut len).await?;
                  let mut skip = vec![0u8; len[0] as usize + 2]; s.read_exact(&mut skip).await?; }
        0x04 => { let mut skip = [0u8; 18]; s.read_exact(&mut skip).await?; }
        _ => {}
    }
    let get = b"GET /?format=text HTTP/1.1\r\nHost: api.ipify.org\r\nConnection: close\r\n\r\n";
    s.write_all(get).await?;
    let mut buf = Vec::new();
    let mut tmp = [0u8; 1024];
    loop {
        match s.read(&mut tmp).await {
            Ok(0) => break,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(_) => break,
        }
    }
    let body = String::from_utf8_lossy(&buf);
    if let Some(idx) = body.rfind("\r\n\r\n") {
        return Ok(body[idx + 4..].trim().to_string());
    }
    anyhow::bail!("no body");
}
