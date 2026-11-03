//! Typed HTTP client for the local control server. Used by the tray and the
//! CLI subcommands. Stays dependency-free (no reqwest) — we already bundle
//! tokio TcpStream for everything else.

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::state::Phase;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusResp {
    pub phase: Phase,
    #[serde(default)]
    pub full_tunnel: bool,
    #[serde(default)]
    pub message: String,
    #[serde(default)]
    pub since_ms: u64,
    #[serde(default)]
    pub tor_pid: Option<u32>,
    #[serde(default)]
    pub tun2socks_pid: Option<u32>,
    #[serde(default)]
    pub exit_ip: Option<String>,
}

pub struct Client {
    base: String, // e.g. "127.0.0.1:8787"
    token: String,
}

impl Client {
    /// Load the API token from `token_path` and pair it with the base address.
    pub async fn from_token_file(base: impl Into<String>, token_path: &Path) -> Result<Self> {
        let token = tokio::fs::read_to_string(token_path)
            .await
            .with_context(|| format!("reading token {}", token_path.display()))?
            .trim()
            .to_string();
        Ok(Self {
            base: base.into(),
            token,
        })
    }

    pub fn new(base: impl Into<String>, token: impl Into<String>) -> Self {
        Self {
            base: base.into(),
            token: token.into(),
        }
    }

    pub async fn status(&self) -> Result<StatusResp> {
        let body = self.do_request("GET", "/status").await?;
        serde_json::from_str(&body).with_context(|| format!("parse status: {body}"))
    }

    pub async fn connect(&self) -> Result<()> {
        self.do_request("POST", "/control/connect")
            .await
            .map(|_| ())
    }

    pub async fn disconnect(&self) -> Result<()> {
        self.do_request("POST", "/control/disconnect")
            .await
            .map(|_| ())
    }

    pub async fn toggle(&self) -> Result<Phase> {
        let body = self.do_request("POST", "/control/toggle").await?;
        let v: serde_json::Value = serde_json::from_str(&body)?;
        let phase: Phase = serde_json::from_value(v.get("phase").cloned().unwrap_or_default())?;
        Ok(phase)
    }

    pub async fn newnym(&self) -> Result<()> {
        self.do_request("POST", "/control/newnym").await.map(|_| ())
    }

    pub async fn exit_set(&self, countries_csv: &str) -> Result<()> {
        validate_countries(countries_csv)?;
        let path = format!("/control/exitset?cc={countries_csv}");
        self.do_request("POST", &path).await.map(|_| ())
    }

    pub async fn exit_clear(&self) -> Result<()> {
        self.do_request("POST", "/control/exitclear")
            .await
            .map(|_| ())
    }

    async fn do_request(&self, method: &str, path: &str) -> Result<String> {
        let seconds = if path == "/status" { 5 } else { 900 };
        tokio::time::timeout(
            std::time::Duration::from_secs(seconds),
            self.request_inner(method, path),
        )
        .await
        .context("service request timed out (see svc.log)")?
    }

    async fn request_inner(&self, method: &str, path: &str) -> Result<String> {
        let mut sock = TcpStream::connect(&self.base)
            .await
            .with_context(|| format!("connect {}", self.base))?;
        let host = &self.base;
        let req = format!(
            "{method} {path} HTTP/1.1\r\nHost: {host}\r\nX-TorVPN-Token: {token}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
            token = self.token,
        );
        sock.write_all(req.as_bytes()).await?;
        let mut raw = Vec::with_capacity(4096);
        let mut tmp = [0u8; 4096];
        loop {
            match sock.read(&mut tmp).await {
                Ok(0) => break,
                Ok(n) => {
                    raw.extend_from_slice(&tmp[..n]);
                    anyhow::ensure!(raw.len() <= 65536, "service response too large");
                }
                Err(e) => return Err(e.into()),
            }
        }
        let text = String::from_utf8_lossy(&raw).to_string();
        // Split headers/body
        let (head, body) = text
            .split_once("\r\n\r\n")
            .ok_or_else(|| anyhow!("malformed response"))?;
        let first = head.lines().next().unwrap_or("");
        let mut parts = first.split_whitespace();
        let _ = parts.next(); // HTTP/1.1
        let code: u16 = parts.next().unwrap_or("0").parse().unwrap_or(0);
        if !(200..300).contains(&code) {
            return Err(anyhow!("HTTP {code}: {body}"));
        }
        Ok(body.to_string())
    }
}

pub fn validate_countries(csv: &str) -> Result<()> {
    if csv.is_empty() {
        return Ok(());
    }
    anyhow::ensure!(
        csv.split(',')
            .all(|c| c.len() == 2 && c.bytes().all(|b| b.is_ascii_alphabetic())),
        "countries must be comma-separated two-letter codes, e.g. gb,de"
    );
    Ok(())
}
