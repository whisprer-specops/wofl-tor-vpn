use anyhow::Result;
use tokio::net::{TcpListener, TcpStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use serde_json::json;
use crate::config::Config;
use std::path::Path;
use tokio::fs;
use std::collections::HashMap;

pub async fn run(cfg: Config, state_dir: std::path::PathBuf) -> Result<()> {
    if !cfg.status.enabled { return Ok(()); }
    let addr = cfg.status.listen.clone();
    let listener = TcpListener::bind(&addr).await?;
    tokio::spawn(async move {
        loop {
            match listener.accept().await {
                Ok((sock, peer)) => { let _ = handle(sock, &cfg, &state_dir, peer.to_string()).await; }
                Err(_) => break,
            }
        }
    });
    Ok(())
}

async fn handle(mut sock: TcpStream, cfg: &Config, state_dir: &Path, peer: String) -> Result<()> {
    let mut buf = vec![0u8; 1024];
    let n = sock.read(&mut buf).await?;
    let req = String::from_utf8_lossy(&buf[..n]);
    let first = req.lines().next().unwrap_or("GET / HTTP/1.1");
    let mut parts = first.split_whitespace();
    let method = parts.next().unwrap_or("GET");
    let raw_path = parts.next().unwrap_or("/");
    let (path, query) = parse_query(raw_path);
    if path == "/control/exitclear" {
        if let Err(_) = auth_check(cfg, state_dir, method, path, &req, query) { respond(&mut sock, 403, r#"{"error":"forbidden"}"#).await?; return Ok(()); }
        if method != "POST" { respond(&mut sock, 405, r#"{"error":"method not allowed"}"#).await?; return Ok(()); }
        let cookie = state_dir.join("tor-data").join("control_auth_cookie");
        let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
        let mut ctl = TorControl::connect(&addr, &cookie).await?;
        let _ = ctl.set_conf("ExitNodes", "").await;
        let _ = ctl.set_conf("StrictNodes", "0").await;
        let _ = ctl.signal_newnym().await;
        respond(&mut sock, 200, r#"{"ok":true}"#).await?; return Ok(());
    }
    if path == "/control/exitset" {
        if let Err(_) = auth_check(cfg, state_dir, method, path, &req, query).map_err(|_| anyhow::anyhow!("forbidden")) { respond(&mut sock, 403, r#"{"error":"forbidden"}"#).await?; return Ok(()); }
        if method != "POST" { respond(&mut sock, 405, r#"{"error":"method not allowed"}"#).await?; return Ok(()); }

        let cc = query_get(query, "cc").unwrap_or("");
        let list: Vec<String> = cc.split(',').map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty()).map(|s| format!("{{{}}}", s)).collect();
        let cookie = state_dir.join("tor-data").join("control_auth_cookie");
        let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
        let mut ctl = TorControl::connect(&addr, &cookie).await?;

        if list.is_empty() {
            let _ = ctl.set_conf("ExitNodes", "").await;
            let _ = ctl.set_conf("StrictNodes", "0").await;
        } else {
            let join = list.join(",");
            ctl.set_conf("ExitNodes", &join).await?;
            ctl.set_conf("StrictNodes", "1").await?;
        }
        let _ = ctl.signal_newnym().await;
        respond(&mut sock, 200, r#"{"ok":true}"#).await?; return Ok(());
    }
    if path == "/status/plan" {
        // Return hop plan state including order + randomized flag + next hops
        let st_path = state_dir.join("hop_state.json");
        let mut order: Vec<usize> = vec![];
        let mut randomized = false;
        let mut idx = 0usize;
        let mut next_epoch_ms = 0u64;
        if let Ok(b) = fs::read(&st_path).await {
            if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&b) {
                if let Some(a) = v.get("order").and_then(|x| x.as_array()) {
                    order = a.iter().filter_map(|x| x.as_u64()).map(|x| x as usize).collect();
                }
                randomized = v.get("randomized").and_then(|x| x.as_bool()).unwrap_or(false);
                idx = v.get("idx").and_then(|x| x.as_u64()).unwrap_or(0) as usize;
                next_epoch_ms = v.get("next_epoch_ms").and_then(|x| x.as_u64()).unwrap_or(0);
            }
        }
        let now = now_ms();
        let remaining = if next_epoch_ms > now { (next_epoch_ms - now) / 1000 } else { 0 };
        let total = cfg.hop.sequence.len();
        let mut upcoming: Vec<serde_json::Value> = Vec::new();
        if !order.is_empty() && idx < order.len() {
            for k in idx..order.len() {
                let i = order[k];
                if let Some(item) = cfg.hop.sequence.get(i) {
                    upcoming.push(serde_json::json!({
                        "index": i,
                        "duration": item.duration,
                        "exit_countries": item.exit_countries,
                        "proxy": item.proxy
                    }));
                }
            }
        }
        let body = serde_json::json!({
            "randomized": randomized,
            "order_indices": order,
            "current_index_in_order": idx,
            "seconds_remaining": remaining,
            "total": total,
            "upcoming": upcoming
        }).to_string();
        respond(&mut sock, 200, &body).await?; return Ok(());
    }
    if path != "/status" {
        respond(&mut sock, 404, r#"{"error":"not found"}"#).await?; return Ok(());
    }

    // Simple rate limiter when not bound to loopback
    if !cfg.status.listen.starts_with("127.0.0.1") {
        if rate_limit_check(state_dir, &peer).await.is_err() {
            respond(&mut sock, 429, r#"{"error":"too many requests"}"#).await?; return Ok(());
        }
    }

    let st_path = state_dir.join("hop_state.json");
    let (idx, next_epoch_ms) = if let Ok(b) = fs::read(&st_path).await {
        if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&b) {
            (v.get("idx").and_then(|x| x.as_u64()).unwrap_or(0) as usize,
             v.get("next_epoch_ms").and_then(|x| x.as_u64()).unwrap_or(0))
        } else { (0, 0) }
    } else { (0, 0) };
    let total = cfg.hop.sequence.len();
    let now_ms = now_ms();
    let remaining = if next_epoch_ms > now_ms { (next_epoch_ms - now_ms) / 1000 } else { 0 };
    let hop_item = cfg.hop.sequence.get(idx).cloned();

    let exit_ip = match get_exit_ip_via_socks(cfg.tor.socks_port).await {
        Ok(s) => Some(s),
        Err(_) => None,
    };

    let body = json!({
        "current_index": idx,
        "total": total,
        "seconds_remaining": remaining,
        "next_epoch_ms": next_epoch_ms,
        "current_hop": hop_item,
        "tor": { "socks_port": cfg.tor.socks_port, "dns_port": cfg.tor.dns_port, "control_port": cfg.tor.control_port },
        "exit_ip": exit_ip,
    }).to_string();

    respond(&mut sock, 200, &body).await?;
    Ok(())
}

async fn respond(sock: &mut TcpStream, code: u16, body: &str) -> Result<()> {
    let status = match code { 200 => "OK", 404 => "Not Found", _ => "OK" };
    let resp = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        code, status, body.len(), body
    );
    sock.write_all(resp.as_bytes()).await?;
    Ok(())
}

fn parse_query(path: &str) -> (&str, Option<&str>) {
    if let Some((p, q)) = path.split_once('?') { (p, Some(q)) } else { (path, None) }
}
fn query_get<'a>(q: Option<&'a str>, key: &str) -> Option<&'a str> {
    q.and_then(|qs| {
        for pair in qs.split('&') {
            if let Some((k,v)) = pair.split_once('=') {
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

async fn apply_proxy(ctl: &mut TorControl, typ: &str, addr: &str, user: Option<&str>, pass: Option<&str>) -> anyhow::Result<()> {
    match typ {
        "socks5" => {
            ctl.set_conf("Socks5Proxy", addr).await?;
            if let Some(u) = user { ctl.set_conf("Socks5ProxyUsername", u).await?; }
            if let Some(pw) = pass { ctl.set_conf("Socks5ProxyPassword", pw).await?; }
        }
        "https" => {
            ctl.set_conf("HTTPSProxy", addr).await?;
            if let Some(u) = user {
                let auth = format!("{}:{}", u, pass.unwrap_or(\"\"));
                ctl.set_conf("HTTPSProxyAuthenticator", &auth).await?;
            }
        }
        _ => {}
    }
    Ok(())
}

async fn rate_limit_check(state_dir: &Path, peer: &str) -> anyhow::Result<()> {
    // File-based simple limiter: keep JSON map of ip -> {last_ms, burst, window_start_ms, count}
    let p = state_dir.join("rate_limit.json");
    let now = now_ms();
    let mut map: serde_json::Value = if let Ok(b) = fs::read(&p).await {
        serde_json::from_slice(&b).unwrap_or(serde_json::json!({}))
    } else { serde_json::json!({}) };
    let ip = peer.split(':').next().unwrap_or(peer);
    let ent = map.get(ip).cloned().unwrap_or(serde_json::json!({"last_ms":0,"burst":0,"win_ms":now,"count":0}));
    let last = ent.get("last_ms").and_then(|x| x.as_u64()).unwrap_or(0);
    let burst = ent.get("burst").and_then(|x| x.as_u64()).unwrap_or(0);
    let win_ms = ent.get("win_ms").and_then(|x| x.as_u64()).unwrap_or(now);
    let count = ent.get("count").and_then(|x| x.as_u64()).unwrap_or(0);

    let mut new_burst = if now > last + 1000 { 0 } else { burst + 1 };
    let mut new_win_ms = win_ms;
    let mut new_count = count;
    if now > win_ms + 60_000 { new_win_ms = now; new_count = 0; }
    new_count += 1;

    // thresholds: <=5 req/sec and <=120 req/min
    if new_burst > 5 || new_count > 120 {
        return Err(anyhow::anyhow!("rate limited"));
    }

    let mut new_ent = serde_json::json!({
        "last_ms": now,
        "burst": new_burst,
        "win_ms": new_win_ms,
        "count": new_count
    });
    map.as_object_mut().unwrap().insert(ip.to_string(), new_ent);
    fs::write(&p, serde_json::to_vec_pretty(&map)?).await?;
    Ok(())
}

async fn get_exit_ip_via_socks(socks_port: u16) -> Result<String> {
    use tokio::net::TcpStream;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut s = TcpStream::connect(("127.0.0.1", socks_port)).await?;
    s.write_all(&[0x05, 0x01, 0x00]).await?;
    let mut resp = [0u8;2]; s.read_exact(&mut resp).await?;
    if resp != [0x05, 0x00] { anyhow::bail!("socks auth failed"); }
    let host = "api.ipify.org";
    let port = 80u16;
    let hb = host.as_bytes();
    let mut req = Vec::with_capacity(7 + hb.len());
    req.extend_from_slice(&[0x05, 0x01, 0x00, 0x03, hb.len() as u8]);
    req.extend_from_slice(hb);
    req.extend_from_slice(&[(port >> 8) as u8, (port & 0xff) as u8]);
    s.write_all(&req).await?;
    let mut hdr = [0u8;4]; s.read_exact(&mut hdr).await?;
    if hdr[1] != 0x00 { anyhow::bail!("socks connect failed"); }
    match hdr[3] {
        0x01 => { let mut skip=[0u8;6]; s.read_exact(&mut skip).await?; }
        0x03 => { let mut len=[0u8;1]; s.read_exact(&mut len).await?; let mut skip=vec![0u8; len[0] as usize + 2]; s.read_exact(&mut skip).await?; }
        0x04 => { let mut skip=[0u8;18]; s.read_exact(&mut skip).await?; }
        _ => {}
    }
    let get = "GET /?format=text HTTP/1.1\r\nHost: api.ipify.org\r\nConnection: close\r\n\r\n";
    s.write_all(get.as_bytes()).await?;
    let mut buf = Vec::new(); let mut tmp = [0u8;1024];
    loop { match s.read(&mut tmp).await { Ok(0) => break, Ok(n) => buf.extend_from_slice(&tmp[..n]), Err(_) => break } }
    let body = String::from_utf8_lossy(&buf);
    if let Some(idx) = body.rfind("\r\n\r\n") {
        let ip = body[idx+4..].trim(); return Ok(ip.to_string());
    }
    anyhow::bail!("no ip in response")
}
