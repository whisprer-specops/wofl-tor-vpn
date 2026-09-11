//! Async Tor ControlPort client. Uses a single `BufReader<TcpStream>` so we
//! can read line-buffered while still issuing writes through `get_mut()` —
//! avoids tokio's missing `try_clone` on `TcpStream`.

use anyhow::{bail, Context, Result};
use hex::encode as hex_encode;
use std::path::Path;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;

pub struct TorControl {
    reader: BufReader<TcpStream>,
}

impl TorControl {
    pub async fn connect(control_addr: &str, cookie_path: &Path) -> Result<Self> {
        let stream = TcpStream::connect(control_addr)
            .await
            .with_context(|| format!("connect {}", control_addr))?;
        let mut s = Self { reader: BufReader::new(stream) };
        s.authenticate(cookie_path).await?;
        Ok(s)
    }

    async fn authenticate(&mut self, cookie_path: &Path) -> Result<()> {
        let cookie = tokio::fs::read(cookie_path)
            .await
            .with_context(|| format!("read cookie {}", cookie_path.display()))?;
        let cmd = format!("AUTHENTICATE {}\r\n", hex_encode(cookie));
        self.send_oneshot(&cmd).await
    }

    pub async fn signal_newnym(&mut self) -> Result<()> {
        self.send_oneshot("SIGNAL NEWNYM\r\n").await
    }

    pub async fn set_conf(&mut self, key: &str, value: &str) -> Result<()> {
        let cmd = if value.is_empty() {
            format!("RESETCONF {}\r\n", key)
        } else {
            format!("SETCONF {}={}\r\n", key, value)
        };
        self.send_oneshot(&cmd).await
    }

    pub async fn get_info(&mut self, key: &str) -> Result<String> {
        self.query_value(&format!("GETINFO {}\r\n", key)).await
    }

    pub async fn circuits(&mut self) -> Result<String> {
        self.query_value("GETINFO circuit-status\r\n").await
    }

    /// Cheap rollup of useful health keys; ignores individual misses.
    pub async fn health_summary(&mut self) -> Result<String> {
        let keys = [
            "status/bootstrap-phase",
            "status/circuit-established",
            "net/listeners/socks",
            "net/listeners/dns",
            "traffic/read",
            "traffic/written",
        ];
        let mut out = String::new();
        for k in keys {
            if let Ok(v) = self.get_info(k).await {
                out.push_str(&format!("{}={}\n", k, v.trim()));
            }
        }
        Ok(out)
    }

    /// Send one command, consume the response until a final `250 ...` (or
    /// other terminal status). Returns Ok on 2xx, Err on 4xx/5xx.
    async fn send_oneshot(&mut self, cmd: &str) -> Result<()> {
        self.reader.get_mut().write_all(cmd.as_bytes()).await?;
        loop {
            let mut line = String::new();
            let n = self.reader.read_line(&mut line).await?;
            if n == 0 { bail!("control: EOF"); }
            // Continuation lines start with "250-" or "250+"; terminal is "250 ".
            if line.starts_with("250 ") || line.trim() == "250 OK" { return Ok(()); }
            if line.starts_with('4') || line.starts_with('5') {
                bail!("control error: {}", line.trim());
            }
            // Otherwise it's a mid-response continuation; keep reading.
        }
    }

    async fn query_value(&mut self, cmd: &str) -> Result<String> {
        self.reader.get_mut().write_all(cmd.as_bytes()).await?;
        let mut buf = String::new();
        loop {
            let mut line = String::new();
            let n = self.reader.read_line(&mut line).await?;
            if n == 0 { bail!("control: EOF"); }
            if let Some(rest) = line.strip_prefix("250-") {
                buf.push_str(rest);
            } else if let Some(rest) = line.strip_prefix("250 ") {
                if !rest.trim().is_empty() { buf.push_str(rest); }
                return Ok(buf.trim().to_string());
            } else if line.starts_with('4') || line.starts_with('5') {
                bail!("control error: {}", line.trim());
            } else if line == "250 OK\r\n" || line.trim() == "250 OK" {
                return Ok(buf.trim().to_string());
            }
            // Otherwise some data line we don't recognize — keep accumulating.
            else {
                buf.push_str(&line);
            }
        }
    }
}
