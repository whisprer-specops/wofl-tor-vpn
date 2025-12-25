use anyhow::Result;
use serde::Serialize;
use std::sync::{Arc, Mutex};
use tokio::time::{sleep, Duration, Instant};
use hyper::{Body, Request, Response, Server, Method, StatusCode};
use hyper::service::{make_service_fn, service_fn};

#[derive(Clone, Default, Serialize)]
struct Shared {
    exit_ip: String,
    last_check_epoch_ms: u64,
}

fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64
}

pub async fn run(cfg: crate::config::Config, state_dir: std::path::PathBuf) -> Result<()> {
    if !cfg.status.enabled { return Ok(()); }
    let addr: std::net::SocketAddr = cfg.status.listen.parse()?;
    let shared = Arc::new(Mutex::new(Shared::default()));

    // Background task: update exit IP periodically
    {
        let shared = shared.clone();
        let cfg2 = cfg.clone();
        let state_dir2 = state_dir.clone();
        tokio::spawn(async move {
            loop {
                if let Ok(ip) = resolve_exit_ip(&cfg2, &state_dir2).await {
                    let mut s = shared.lock().unwrap();
                    s.exit_ip = ip;
                    s.last_check_epoch_ms = now_ms();
                }
                sleep(Duration::from_secs(60)).await;
            }
        });
    }

    let make_svc = make_service_fn(move |_conn| {
        let shared = shared.clone();
        let cfg = cfg.clone();
        let state_dir = state_dir.clone();
        async move {
            Ok::<_, anyhow::Error>(service_fn(move |req| {
                let shared = shared.clone();
                let cfg = cfg.clone();
                let state_dir = state_dir.clone();
                async move { handle(req, shared, cfg, state_dir).await }
            }))
        }
    });

    let server = Server::bind(&addr).serve(make_svc);
    if let Err(e) = server.await {
        eprintln!("[status] server error: {:?}", e);
    }
    Ok(())
}

async fn handle(req: Request<Body>, shared: Arc<Mutex<Shared>>, cfg: crate::config::Config, state_dir: std::path::PathBuf) -> Result<Response<Body>> {
    if req.method() == Method::GET && req.uri().path() == "/status" {
        let (hop_idx, mapped_idx, remaining_ms, next_epoch_ms, item_json) = read_hop_state(&cfg, &state_dir).await.unwrap_or((-1i64, -1i64, 0u64, 0u64, serde_json::json!({})));
        let s = shared.lock().unwrap().clone();
        let resp = serde_json::json!({
            "hop_index": hop_idx,
            "mapped_index": mapped_idx,
            "time_remaining_ms": remaining_ms,
            "next_epoch_ms": next_epoch_ms,
            "current_hop": item_json,
            "exit_ip": s.exit_ip,
            "exit_ip_last_checked_ms": s.last_check_epoch_ms
        });
        let body = serde_json::to_vec(&resp)?;
        Ok(Response::new(Body::from(body)))
    } else {
        let mut r = Response::new(Body::empty());
        *r.status_mut() = StatusCode::NOT_FOUND;
        Ok(r)
    }
}

async fn read_hop_state(cfg: &crate::config::Config, state_dir: &std::path::Path) -> Result<(i64,i64,u64,u64,serde_json::Value)> {
    use tokio::fs;
    let p = state_dir.join("hop_state.json");
    let b = fs::read(&p).await?;
    #[derive(serde::Deserialize)]
    struct HS { idx: usize, next_epoch_ms: u64, order: Option<Vec<usize>> }
    let st: HS = serde_json::from_slice(&b)?;
    let now = now_ms();
    let remaining = if st.next_epoch_ms > now { st.next_epoch_ms - now } else { 0 };
    let n = cfg.hop.sequence.len();
    if n == 0 { return Ok((-1,-1, remaining, st.next_epoch_ms, serde_json::json!({}))); }
    let mapped = if let Some(order) = st.order.as_ref() {
        if st.idx < order.len() { order[st.idx] } else { st.idx.min(n-1) }
    } else { st.idx.min(n-1) };
    // Build minimal JSON of the current item
    let it = &cfg.hop.sequence[mapped];
    let item_json = serde_json::json!({
        "duration": it.duration,
        "exit_countries": it.exit_countries,
        "proxy": it.proxy
    });
    Ok((st.idx as i64, mapped as i64, remaining, st.next_epoch_ms, item_json))
}

async fn resolve_exit_ip(cfg: &crate::config::Config, state_dir: &std::path::Path) -> Result<String> {
    // Try HTTPS first
    if let Ok(c) = reqwest::Client::builder().build() {
        if let Ok(resp) = c.get("https://check.torproject.org/api/ip").send().await {
            if resp.status().is_success() {
                if let Ok(v) = resp.json::<serde_json::Value>().await {
                    if let Some(ip) = v.get("IP").and_then(|x| x.as_str()) {
                        return Ok(ip.to_string());
                    }
                }
            }
        }
        if let Ok(resp) = c.get("https://api.ipify.org?format=json").send().await {
            if resp.status().is_success() {
                if let Ok(v) = resp.json::<serde_json::Value>().await {
                    if let Some(ip) = v.get("ip").and_then(|x| x.as_str()) {
                        return Ok(ip.to_string());
                    }
                }
            }
        }
    }
    // Fallback: Tor control GETINFO address
    let cookie = state_dir.join("tor-data").join("control_auth_cookie");
    let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
    if let Ok(mut ctl) = crate::tor_control::TorControl::connect(&addr, &cookie).await {
        if let Ok(s) = ctl.get_info("address").await {
            return Ok(s.trim().to_string());
        }
    }
    Ok(String::new())
}
