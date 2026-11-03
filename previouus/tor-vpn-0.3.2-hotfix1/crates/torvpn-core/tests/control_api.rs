//! Real TCP regression tests; no Windows network settings are touched.
use std::{sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};
use torvpn_core::{
    api::Client,
    config, control_server,
    state::{Engagement, Phase},
};

async fn fixture() -> (
    String,
    Client,
    tokio::task::JoinHandle<anyhow::Result<()>>,
    std::path::PathBuf,
    Arc<Engagement>,
) {
    let reserve = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = reserve.local_addr().unwrap().to_string();
    drop(reserve);
    let mut cfg = config::load_or_default(None).await.unwrap();
    cfg.status.listen = addr.clone();
    let dir = std::env::temp_dir().join(format!(
        "torvpn-api-{}-{}",
        std::process::id(),
        rand::random::<u64>()
    ));
    tokio::fs::create_dir_all(&dir).await.unwrap();
    let eng = Engagement::new(dir.join("state.json"));
    let eng2 = eng.clone();
    let dir2 = dir.clone();
    let (tx, rx) = tokio::sync::oneshot::channel();
    let handle = tokio::spawn(control_server::run(cfg, dir2, eng2, Some(tx)));
    tokio::time::timeout(Duration::from_secs(2), rx)
        .await
        .unwrap()
        .unwrap();
    let client = Client::from_token_file(&addr, &dir.join("api_token"))
        .await
        .unwrap();
    (addr, client, handle, dir, eng)
}
#[tokio::test]
async fn status_does_not_need_internet() {
    let (_, client, handle, dir, _) = fixture().await;
    let status = tokio::time::timeout(Duration::from_millis(500), client.status())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(status.phase, Phase::Disengaged);
    assert!(status.exit_ip.is_none());
    handle.abort();
    let _ = handle.await;
    tokio::fs::remove_dir_all(dir).await.unwrap();
}
#[tokio::test]
async fn authentication_cannot_be_omitted() {
    let (addr, _, handle, dir, _) = fixture().await;
    let client = Client::new(addr, "wrong-token");
    let err = client.status().await.unwrap_err();
    assert!(err.to_string().contains("401"));
    handle.abort();
    let _ = handle.await;
    tokio::fs::remove_dir_all(dir).await.unwrap();
}
#[tokio::test]
async fn fragmented_headers_are_read_completely() {
    let (addr, _, handle, dir, _) = fixture().await;
    let token = tokio::fs::read_to_string(dir.join("api_token"))
        .await
        .unwrap();
    let mut sock = TcpStream::connect(addr).await.unwrap();
    sock.write_all(b"GET /status HTTP/1.1\r\nX-TorVPN-")
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(25)).await;
    sock.write_all(format!("Token: {token}\r\n\r\n").as_bytes())
        .await
        .unwrap();
    let mut response = String::new();
    sock.read_to_string(&mut response).await.unwrap();
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    handle.abort();
    let _ = handle.await;
    tokio::fs::remove_dir_all(dir).await.unwrap();
}
#[tokio::test]
async fn country_validation_prevents_request_injection() {
    let (_, client, handle, dir, _) = fixture().await;
    client.exit_set("gb,de").await.unwrap(); // supported before Tor is started
    client.exit_clear().await.unwrap();
    assert!(client.exit_set("us\r\nInjected: yes").await.is_err());
    assert!(client.exit_set("USA").await.is_err());
    handle.abort();
    let _ = handle.await;
    tokio::fs::remove_dir_all(dir).await.unwrap();
}
