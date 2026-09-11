use anyhow::{Result, Context};
use tokio::net::{TcpStream, UdpSocket};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use std::time::Duration;

pub struct LeakReport {
    pub dns_udp_blocked: bool,
    pub tor_socks_ok: bool,
    pub notes: Vec<String>,
}

pub async fn run(socks_port: u16) -> Result<LeakReport> {
    let mut notes = Vec::new();
    // 1) Try to resolve via direct UDP 53 (send a tiny DNS query to 1.1.1.1; expect no response)
    let dns_udp_blocked = match dns_probe_udp().await {
        Ok(false) => { notes.push("Received a DNS response from 1.1.1.1:53 (possible leak)".into()); false },
        Ok(true)  => { notes.push("No DNS response from 1.1.1.1:53 within timeout (blocked or redirected)".into()); true },
        Err(e)    => { notes.push(format!("DNS UDP probe error (treated as blocked): {e:?}")); true },
    };

    // 2) Try Tor SOCKS connect to example.com:80 and issue HTTP HEAD
    let tor_socks_ok = match socks_http_head("example.com", 80, socks_port).await {
        Ok(true)  => { notes.push("Tor SOCKS HTTP HEAD to example.com succeeded".into()); true },
        Ok(false) => { notes.push("Tor SOCKS HTTP HEAD to example.com failed".into()); false },
        Err(e)    => { notes.push(format!("Tor SOCKS probe error: {e:?}")); false },
    };

    Ok(LeakReport { dns_udp_blocked, tor_socks_ok, notes })
}

async fn dns_probe_udp() -> Result<bool> {
    // Returns true if we did NOT receive a response (good), false if we did (leak)
    let sock = UdpSocket::bind("0.0.0.0:0").await?;
    sock.connect(("1.1.1.1", 53)).await?;
    // Minimal DNS query for A record of example.com
    let query: [u8; 28] = [
        0x12,0x34, 0x01,0x00, 0x00,0x01, 0x00,0x00, 0x00,0x00, 0x00,0x00,
        0x07,b'e',b'x',b'a',b'm',b'p',b'l',b'e', 0x03,b'c',b'o',b'm', 0x00,
        0x00,0x01, 0x00,0x01
    ];
    sock.send(&query).await?;
    let mut buf = [0u8; 512];
    let recv = tokio::time::timeout(Duration::from_millis(900), sock.recv(&mut buf)).await;
    match recv {
        Ok(Ok(n)) if n > 0 => Ok(false),
        _ => Ok(true),
    }
}

async fn socks_http_head(host: &str, port: u16, socks_port: u16) -> Result<bool> {
    // SOCKS5 handshake + CONNECT + send HTTP HEAD
    let addr = format!("127.0.0.1:{}", socks_port);
    let mut s = TcpStream::connect(addr).await?;

    // Greeting: no auth
    s.write_all(&[0x05, 0x01, 0x00]).await?;
    let mut resp = [0u8; 2];
    s.read_exact(&mut resp).await?;
    if resp != [0x05, 0x00] { return Ok(false); }

    // CONNECT to host:port with domain name
    let host_bytes = host.as_bytes();
    if host_bytes.len() > 255 { return Ok(false); }
    let mut req = Vec::with_capacity(7 + host_bytes.len());
    req.extend_from_slice(&[0x05, 0x01, 0x00, 0x03, host_bytes.len() as u8]);
    req.extend_from_slice(host_bytes);
    req.extend_from_slice(&[(port >> 8) as u8, (port & 0xff) as u8]);
    s.write_all(&req).await?;

    // Read connect reply: 0x05, 0x00 = success
    let mut hdr = [0u8; 4];
    s.read_exact(&mut hdr).await?;
    if hdr[1] != 0x00 { return Ok(false); }
    // Consume BND.ADDR and BND.PORT fields
    match hdr[3] {
        0x01 => { // IPv4
            let mut skip = [0u8; 6]; s.read_exact(&mut skip).await?;
        }
        0x03 => {
            let mut len = [0u8;1]; s.read_exact(&mut len).await?;
            let mut skip = vec![0u8; len[0] as usize + 2]; s.read_exact(&mut skip).await?;
        }
        0x04 => { let mut skip = [0u8; 18]; s.read_exact(&mut skip).await?; }
        _ => return Ok(false)
    }

    // Send HEAD request
    let req = format!("HEAD / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n");
    s.write_all(req.as_bytes()).await?;

    let mut buf = vec![0u8; 1024];
    let n = tokio::time::timeout(Duration::from_secs(5), s.read(&mut buf)).await;
    match n {
        Ok(Ok(m)) if m > 0 => Ok(true),
        _ => Ok(false),
    }
}
