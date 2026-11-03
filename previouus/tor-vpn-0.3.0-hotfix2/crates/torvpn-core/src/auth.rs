//! Bearer-token + optional HMAC auth for the local control server.
//!
//! On first run, the service generates two secrets under `state_dir()`:
//!   - `api_token`        : random URL-safe string the tray reads
//!   - `api_hmac_secret`  : key for optional HMAC of remote calls
//!
//! Tray runs as the user; service runs as LocalSystem. ProgramData is
//! readable by Users by default, so the tray can read the token.

use anyhow::{anyhow, Context, Result};
use hmac::{Hmac, Mac};
use rand::RngCore;
use sha2::Sha256;
use std::path::Path;
use tokio::fs;

type HmacSha256 = Hmac<Sha256>;

const TOKEN_LEN: usize = 32;
const SECRET_LEN: usize = 32;

/// Read existing token, or create one if missing.
pub async fn ensure_token(token_path: &Path) -> Result<String> {
    if let Ok(bytes) = fs::read(token_path).await {
        if let Ok(s) = String::from_utf8(bytes) {
            let s = s.trim().to_string();
            if !s.is_empty() {
                return Ok(s);
            }
        }
    }
    let mut buf = [0u8; TOKEN_LEN];
    rand::thread_rng().fill_bytes(&mut buf);
    let token = hex::encode(buf);
    if let Some(p) = token_path.parent() {
        fs::create_dir_all(p).await?;
    }
    fs::write(token_path, &token)
        .await
        .with_context(|| format!("writing token to {}", token_path.display()))?;
    Ok(token)
}

pub async fn ensure_hmac_secret(secret_path: &Path) -> Result<Vec<u8>> {
    if let Ok(bytes) = fs::read(secret_path).await {
        if bytes.len() >= SECRET_LEN {
            return Ok(bytes);
        }
    }
    let mut buf = [0u8; SECRET_LEN];
    rand::thread_rng().fill_bytes(&mut buf);
    if let Some(p) = secret_path.parent() {
        fs::create_dir_all(p).await?;
    }
    fs::write(secret_path, &buf).await?;
    Ok(buf.to_vec())
}

/// Validate a request: bearer token must match; if `X-TorVPN-HMAC` is
/// provided, also verify it.
///
/// `hmac_header` format: `<ts_epoch_secs>:<hex(HMAC-SHA256(secret, ts||method||path))>`
/// Clock skew tolerance ±300s.
pub fn check(
    expected_token: &str,
    hmac_secret: &[u8],
    presented_token: Option<&str>,
    hmac_header: Option<&str>,
    method: &str,
    path: &str,
) -> Result<()> {
    let Some(tok) = presented_token else {
        return Err(anyhow!("missing token"));
    };
    if !constant_time_eq(tok.as_bytes(), expected_token.as_bytes()) {
        return Err(anyhow!("bad token"));
    }
    if let Some(hdr) = hmac_header {
        let (ts_s, sig_hex) = hdr.split_once(':').ok_or_else(|| anyhow!("bad hmac"))?;
        let ts: i64 = ts_s.parse().map_err(|_| anyhow!("bad hmac ts"))?;
        let now = now_secs();
        if (now - ts).abs() > 300 {
            return Err(anyhow!("hmac ts skew"));
        }
        let mut mac = HmacSha256::new_from_slice(hmac_secret).map_err(|_| anyhow!("hmac key"))?;
        mac.update(ts_s.as_bytes());
        mac.update(method.as_bytes());
        mac.update(path.as_bytes());
        let want = mac.finalize().into_bytes();
        let got = hex::decode(sig_hex).map_err(|_| anyhow!("bad hmac hex"))?;
        if !constant_time_eq(&want, &got) {
            return Err(anyhow!("hmac mismatch"));
        }
    }
    Ok(())
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

fn now_secs() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
