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
        let mut s = Self {
            reader: BufReader::new(stream),
        };
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
        tokio::time::timeout(std::time::Duration::from_secs(10), self.send_inner(cmd))
            .await
            .context("Tor control command timed out")?
    }
    async fn send_inner(&mut self, cmd: &str) -> Result<()> {
        self.reader.get_mut().write_all(cmd.as_bytes()).await?;
        loop {
            let mut line = String::new();
            let n = self.reader.read_line(&mut line).await?;
            if n == 0 {
                bail!("control: EOF");
            }
            // Continuation lines start with "250-" or "250+"; terminal is "250 ".
            if line.starts_with("250 ") || line.trim() == "250 OK" {
                return Ok(());
            }
            if line.starts_with('4') || line.starts_with('5') {
                bail!("control error: {}", line.trim());
            }
            // Otherwise it's a mid-response continuation; keep reading.
        }
    }

    async fn query_value(&mut self, cmd: &str) -> Result<String> {
        tokio::time::timeout(std::time::Duration::from_secs(10), self.query_inner(cmd))
            .await
            .context("Tor control query timed out")?
    }
    async fn query_inner(&mut self, cmd: &str) -> Result<String> {
        self.reader.get_mut().write_all(cmd.as_bytes()).await?;
        let mut buf = String::new();
        loop {
            let mut line = String::new();
            let n = self.reader.read_line(&mut line).await?;
            if n == 0 {
                bail!("control: EOF");
            }
            if let Some(rest) = line.strip_prefix("250-") {
                buf.push_str(rest);
            } else if let Some(rest) = line.strip_prefix("250 ") {
                if !rest.trim().is_empty() {
                    buf.push_str(rest);
                }
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

    // ---- Guard / direct-peer discovery (for split routing) ------------------

    /// Fingerprints of the relays tor holds *direct* OR connections to — i.e.
    /// its entry guards (and, briefly after bootstrap, any directory peer).
    /// These are exactly the IPs that must bypass the Wintun tunnel, or we get
    /// a routing loop (tor's own guard traffic re-entering the tunnel).
    pub async fn direct_peer_fingerprints(&mut self) -> Result<Vec<String>> {
        let raw = self.get_info("orconn-status").await?;
        Ok(parse_orconn_fingerprints(&raw))
    }

    /// Resolve a relay fingerprint to its advertised IPv4 via the consensus
    /// (`GETINFO ns/id/<fp>`). Returns None if the relay isn't in the current
    /// consensus or has no parseable v4 address.
    pub async fn router_ipv4(&mut self, fingerprint: &str) -> Result<Option<String>> {
        let key = format!("ns/id/{}", fingerprint);
        match self.get_info(&key).await {
            Ok(raw) => Ok(parse_router_ipv4(&raw)),
            // A single missing relay shouldn't sink the whole routing setup.
            Err(_) => Ok(None),
        }
    }

    /// Convenience: the deduplicated set of IPv4 addresses tor is connected to
    /// directly. This is what the routing layer pins to the physical gateway.
    pub async fn guard_ipv4_addrs(&mut self) -> Result<Vec<String>> {
        let fps = self.direct_peer_fingerprints().await?;
        let mut ips: Vec<String> = Vec::new();
        for fp in fps {
            if let Some(ip) = self.router_ipv4(&fp).await? {
                if !ips.contains(&ip) {
                    ips.push(ip);
                }
            }
        }
        Ok(ips)
    }
}

/// Extract 40-hex relay fingerprints from a `GETINFO orconn-status` payload.
/// Lines look like `$<40-HEX>~Nickname CONNECTED`; we tolerate the control
/// protocol's `250+`/`.` framing noise by only accepting well-formed tokens.
fn parse_orconn_fingerprints(raw: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for line in raw.lines() {
        let tok = line.trim();
        let Some(rest) = tok.strip_prefix('$') else {
            continue;
        };
        // Fingerprint runs until '~', whitespace, or end.
        let fp: String = rest
            .chars()
            .take_while(|c| *c != '~' && *c != '=' && !c.is_whitespace())
            .collect();
        if fp.len() == 40 && fp.chars().all(|c| c.is_ascii_hexdigit()) {
            let fp = fp.to_uppercase();
            if !out.contains(&fp) {
                out.push(fp);
            }
        }
    }
    out
}

/// Pull the IPv4 out of a consensus router-status (`r`) line from
/// `GETINFO ns/id/<fp>`. Format:
///   r <nick> <id-b64> <digest-b64> <date> <time> <IP> <ORPort> <DirPort>
fn parse_router_ipv4(raw: &str) -> Option<String> {
    for line in raw.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("r ") else {
            continue;
        };
        let fields: Vec<&str> = rest.split_whitespace().collect();
        // fields: [nick, id, digest, date, time, IP, ORPort, DirPort]
        if let Some(ip) = fields.get(5) {
            if ip.parse::<std::net::Ipv4Addr>().is_ok() {
                return Some((*ip).to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_orconn_fingerprints_and_dedups() {
        let raw = "250+orconn-status=\n\
                   $AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA~guardOne CONNECTED\n\
                   $bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb~guardTwo CONNECTED\n\
                   $AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA~guardOne CONNECTED\n\
                   .\n250 OK\r\n";
        let fps = parse_orconn_fingerprints(raw);
        assert_eq!(fps.len(), 2, "should dedup the repeated guard");
        assert!(fps.contains(&"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".to_string()));
        // Case-normalised to upper.
        assert!(fps.contains(&"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB".to_string()));
    }

    #[test]
    fn ignores_framing_and_short_tokens() {
        let raw = "250+orconn-status=\n$deadbeef short\n.\n250 OK";
        assert!(parse_orconn_fingerprints(raw).is_empty());
    }

    #[test]
    fn parses_router_ipv4_from_r_line() {
        let raw = "250+ns/id/$AAAA=\n\
                   r SomeRelay abcdEFgh1234 ZZZZdigest 2026-09-05 12:00:00 185.220.101.7 443 80\n\
                   s Fast Guard Running Stable Valid\n\
                   w Bandwidth=12000\n.\n250 OK";
        assert_eq!(parse_router_ipv4(raw).as_deref(), Some("185.220.101.7"));
    }

    #[test]
    fn router_ipv4_none_when_absent() {
        let raw = "250+ns/id/$AAAA=\n.\n250 OK";
        assert_eq!(parse_router_ipv4(raw), None);
    }
}
