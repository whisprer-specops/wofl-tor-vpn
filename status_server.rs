use anyhow::Result;
use tokio::net::{TcpListener, TcpStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use serde_json::json;
use crate::config::Config;
use crate::tor_control::TorControl;
use crate::proxy_manager::ProxyManager;
use std::path::Path;
use tokio::fs;


fn token_path(state_dir: &Path) -> std::path::PathBuf { state_dir.join("api_token") }

async fn ensure_token(state_dir: &Path) -> anyhow::Result<String> {
    if let Ok(bytes) = fs::read(token_path(state_dir)).await {
        return Ok(String::from_utf8_lossy(&bytes).trim().to_string());
    }
    // generate 32-byte hex token
    let tok = {
        let mut b = [0u8;32];
        getrandom::getrandom(&mut b)?;
        let mut s = String::new();
        for x in b { s.push_str(&format!("{:02x}", x)); }
        s
    };
    fs::write(token_path(state_dir), tok.as_bytes()).await?;
    Ok(tok)
}

fn parse_token_from_headers(req: &str) -> Option<String> {
    for line in req.lines() {
        if line.to_ascii_lowercase().starts_with("x-torvpn-token:") {
            return Some(line.split(':').nth(1)?.trim().to_string());
        }
        if line.to_ascii_lowercase().starts_with("authorization:") {
            let v = line.split(':').nth(1)?.trim();
            if let Some(rest) = v.strip_prefix("Bearer ") { return Some(rest.trim().to_string()); }
            if let Some(rest) = v.strip_prefix("bearer ") { return Some(rest.trim().to_string()); }
        }
    }
    None
}

async fn last_newnym_path(state_dir: &Path) -> std::path::PathBuf { state_dir.join("newnym_state.json") }

async fn maybe_newnym(cfg: &Config, state_dir: &Path) -> anyhow::Result<(bool, u64)> {
    // Enforce 10s cooldown
    let path = last_newnym_path(state_dir);
    let mut last: u64 = 0;
    if let Ok(b) = fs::read(&path).await {
        if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&b) {
            last = v.get("ts").and_then(|x| x.as_u64()).unwrap_or(0);
        }
    }
    let now = now_ms();
    let min = 10_000;
    if now < last + min {
        return Ok((false, ((last + min - now) / 1000) as u64));
    }
    let cookie = state_dir.join("tor-data").join("control_auth_cookie");
    let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
    let mut ctl = TorControl::connect(&addr, &cookie).await?;
    let _ = ctl.signal_newnym().await;
    let v = serde_json::json!({ "ts": now });
    fs::write(&path, serde_json::to_vec_pretty(&v)?).await?;
    Ok((true, 0))
}


pub async fn run(cfg: Config, state_dir: std::path::PathBuf) -> Result<()> {
    if !cfg.status.enabled { return Ok(()); }
    let addr = cfg.status.listen.clone();
    let listener = TcpListener::bind(&addr).await?;
    tokio::spawn(async move {
        loop {
            match listener.accept().await {
                Ok((sock, _)) => { let _ = handle(sock, &cfg, &state_dir).await; }
                Err(_) => break,
            }
        }
    });
    Ok(())
}

async fn handle(mut sock: TcpStream, cfg: &Config, state_dir: &Path) -> Result<()> {
    let mut buf = vec![0u8; 1024];
    let n = sock.read(&mut buf).await?;
    let req = String::from_utf8_lossy(&buf[..n]);
    let first = req.lines().next().unwrap_or("GET / HTTP/1.1");
    let mut parts = first.split_whitespace();
    let method = parts.next().unwrap_or("GET");
    let raw_path = parts.next().unwrap_or("/");
    let (path, query) = parse_query(raw_path);
    if path == "/control/proxynext" {
        let tok = ensure_token(state_dir).await?;
        let got = parse_token_from_headers(&req).or_else(|| query_get(query, "token").map(|x| x.to_string()));
        if got.as_deref() != Some(&tok) { respond(&mut sock, 403, r#"{"error":"forbidden"}"#).await?; return Ok(()); }
        if method != "POST" { respond(&mut sock, 405, r#"{"error":"method not allowed"}"#).await?; return Ok(()); }

        if cfg.proxy.proxies.is_empty() || !cfg.proxy.enabled {
            respond(&mut sock, 400, r#"{"error":"no proxies configured or proxy disabled"}"#).await?; return Ok(());
        }
        let cookie = state_dir.join("tor-data").join("control_auth_cookie");
        let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
        let mut ctl = TorControl::connect(&addr, &cookie).await?;

        let mut pm = ProxyManager::load(&state_dir.to_path_buf()).await?;
        if let Some(p) = pm.current(&cfg) {
            apply_proxy(&mut ctl, p.typ.as_str(), &p.addr, p.username.as_deref(), p.password.as_deref()).await?;
            pm.next(&cfg);
            let _ = pm.save(&state_dir.to_path_buf()).await;
            let _ = ctl.signal_newnym().await;
            respond(&mut sock, 200, r#"{"ok":true,"proxynext_applied":true}"#).await?; return Ok(());
        } else {
            respond(&mut sock, 500, r#"{"error":"proxy rotation failed"}"#).await?; return Ok(());
        }
    }
    if path == "/control/newnym" {
        // Token check
        let tok = ensure_token(state_dir).await?;
        let got = parse_token_from_headers(&req).or_else(|| req.split(' ').nth(1).and_then(|p| p.split("token=").nth(1)).map(|x| x.to_string()));
        if got.as_deref() != Some(&tok) { respond(&mut sock, 403, r#"{"error":"forbidden"}"#).await?; return Ok(()); }
        if method != "POST" { respond(&mut sock, 405, r#"{"error":"method not allowed"}"#).await?; return Ok(()); }
        let (sent, wait) = maybe_newnym(cfg, state_dir).await?;
        let body = serde_json::json!({ "ok": true, "newnym_sent": sent, "cooldown_remaining": wait }).to_string();
        respond(&mut sock, 200, &body).await?; return Ok(());
    }
    if path == "/control/exitset" {
        let tok = ensure_token(state_dir).await?;
        let got = parse_token_from_headers(&req).or_else(|| query_get(query, "token").map(|x| x.to_string()));
        if got.as_deref() != Some(&tok) { respond(&mut sock, 403, r#"{"error":"forbidden"}"#).await?; return Ok(()); }
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
    if path != "/status" {
        respond(&mut sock, 404, r#"{"error":"not found"}"#).await?; return Ok(());
    }

    // Read hop state
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

    // Snapshot hop item
    let hop_item = cfg.hop.sequence.get(idx).cloned();

    // Resolve exit IP via Tor SOCKS (best-effort)
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
        "mode": cfg.net.mode,
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

async fn get_exit_ip_via_socks(socks_port: u16) -> Result<String> {
    use tokio::net::TcpStream;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut s = TcpStream::connect(("127.0.0.1", socks_port)).await?;
    // SOCKS greeting
    s.write_all(&[0x05, 0x01, 0x00]).await?;
    let mut resp = [0u8;2]; s.read_exact(&mut resp).await?;
    if resp != [0x05, 0x00] { anyhow::bail!("socks auth failed"); }
    // CONNECT api.ipify.org:80 via domain name
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
    // consume bind addr
    match hdr[3] {
        0x01 => { let mut skip=[0u8;6]; s.read_exact(&mut skip).await?; }
        0x03 => { let mut len=[0u8;1]; s.read_exact(&mut len).await?; let mut skip=vec![0u8; len[0] as usize + 2]; s.read_exact(&mut skip).await?; }
        0x04 => { let mut skip=[0u8;18]; s.read_exact(&mut skip).await?; }
        _ => {}
    }
    // Send GET /?format=text
    let get = "GET /?format=text HTTP/1.1\r\nHost: api.ipify.org\r\nConnection: close\r\n\r\n";
    s.write_all(get.as_bytes()).await?;
    let mut buf = Vec::new();
    let mut tmp = [0u8;1024];
    loop {
        match s.read(&mut tmp).await {
            Ok(0) => break,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(_) => break,
        }
    }
    let body = String::from_utf8_lossy(&buf);
    // Extract last line as IP
    if let Some(idx) = body.rfind("\r\n\r\n") {
        let ip = body[idx+4..].trim();
        return Ok(ip.to_string());
    }
    anyhow::bail!("no ip in response")
}
