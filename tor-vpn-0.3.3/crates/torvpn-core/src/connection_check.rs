//! HTTPS acceptance uses the ordinary system route. A SOCKS diagnostic can
//! explain a failure, but can never substitute for full-tunnel acceptance.
use crate::config::Config;
use anyhow::{bail, Context, Result};
use serde::Serialize;
use std::{path::Path, time::Duration};
use tokio::process::Command;

const ENDPOINT: &str = "https://check.torproject.org/api/ip";
const META: &str = "\nTORVPN_CURL_META\t";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Route {
    System,
    Socks,
}
impl Route {
    fn label(self) -> &'static str {
        match self {
            Self::System => "system-route",
            Self::Socks => "socks-proxy",
        }
    }
}
#[derive(Serialize)]
struct Attempt {
    route: &'static str,
    diagnostic_only: bool,
    attempt: u8,
    exit_code: Option<i32>,
    elapsed_ms: u64,
    metadata: String,
    stderr: String,
    body: String,
    verified_ip: Option<String>,
    error: Option<String>,
}
#[derive(Serialize)]
struct Report {
    endpoint: &'static str,
    full_tunnel: bool,
    accepted: bool,
    attempts: Vec<Attempt>,
}
#[derive(Clone, Copy)]
struct Policy {
    process_timeout: Duration,
    retry_delay: Duration,
}
impl Default for Policy {
    fn default() -> Self {
        Self {
            process_timeout: Duration::from_secs(30),
            retry_delay: Duration::from_secs(2),
        }
    }
}

fn command(curl: &Path, cfg: &Config, route: Route) -> Command {
    let mut cmd = Command::new(curl);
    // -q must be FIRST: ignore curlrc before processing other arguments.
    cmd.args([
        "-q", "--fail", "--silent", "--show-error", "--verbose",
        "--ipv4", "--http1.1", "--proto", "=https",
        "--connect-timeout", "12", "--max-time", "25",
        "--max-filesize", "65536", "--write-out",
        "\nTORVPN_CURL_META\tremote_ip=%{remote_ip}\thttp_code=%{http_code}\tssl_verify_result=%{ssl_verify_result}\ttime_connect=%{time_connect}\ttime_appconnect=%{time_appconnect}\ttime_total=%{time_total}\n",
    ]);
    for key in [
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "NO_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "no_proxy",
    ] {
        cmd.env_remove(key);
    }
    match route {
        Route::System => {
            cmd.args(["--noproxy", "*"]);
        }
        Route::Socks => {
            cmd.args(["--noproxy", "", "--socks5-hostname"])
                .arg(format!("127.0.0.1:{}", cfg.tor.socks_port));
        }
    }
    cmd.arg(ENDPOINT).kill_on_drop(true);
    #[cfg(windows)]
    cmd.creation_flags(0x0800_0000);
    cmd
}
fn clipped(text: &str, max: usize) -> String {
    text.chars().take(max).collect()
}
fn confirmed_ip(bytes: &[u8]) -> Result<String> {
    let doc: serde_json::Value =
        serde_json::from_slice(bytes).context("Tor check returned invalid JSON")?;
    anyhow::ensure!(
        doc.get("IsTor").and_then(|v| v.as_bool()) == Some(true),
        "Tor Project check did not confirm a Tor exit (IsTor is not true)"
    );
    let ip = doc
        .get("IP")
        .and_then(|v| v.as_str())
        .context("Tor check omitted IP")?;
    let parsed: std::net::IpAddr = ip.parse().context("Tor check returned invalid IP")?;
    anyhow::ensure!(
        !parsed.is_loopback() && !parsed.is_unspecified(),
        "Tor check returned a non-exit IP"
    );
    Ok(ip.to_owned())
}
fn retryable(attempt: &Attempt) -> bool {
    match attempt.exit_code {
        Some(6 | 7 | 28 | 52 | 55 | 56) => true,
        Some(35) => attempt.stderr.to_ascii_lowercase().contains("reset"),
        // Certificate failures, rejected IsTor results, malformed successful
        // responses and unsupported curl flags are not retried as transients.
        _ => false,
    }
}
async fn progress(sd: &Path, message: &str) {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    let value = serde_json::json!({"script":"HTTPS check", "message":message, "updated_ms":now});
    if let Ok(bytes) = serde_json::to_vec(&value) {
        let _ = tokio::fs::write(sd.join("admin-progress.json"), bytes).await;
    }
    log::info!("{message}");
}
async fn save(sd: &Path, report: &Report) -> Result<()> {
    tokio::fs::write(
        sd.join("verification.json"),
        serde_json::to_vec_pretty(report)?,
    )
    .await
    .context("saving HTTPS verification evidence")
}
async fn probe(
    curl: &Path,
    cfg: &Config,
    route: Route,
    number: u8,
    diagnostic: bool,
    policy: Policy,
) -> Attempt {
    let start = tokio::time::Instant::now();
    let mut result = Attempt {
        route: route.label(),
        diagnostic_only: diagnostic,
        attempt: number,
        exit_code: None,
        elapsed_ms: 0,
        metadata: String::new(),
        stderr: String::new(),
        body: String::new(),
        verified_ip: None,
        error: None,
    };
    match tokio::time::timeout(policy.process_timeout, command(curl, cfg, route).output()).await {
        Ok(Ok(out)) => {
            result.exit_code = out.status.code();
            result.stderr = clipped(&String::from_utf8_lossy(&out.stderr), 16000);
            let text = String::from_utf8_lossy(&out.stdout);
            let (body, meta) = text.rsplit_once(META).unwrap_or((&text, ""));
            result.body = clipped(body, 65536);
            result.metadata = clipped(meta.trim(), 2000);
            if out.status.success() {
                match confirmed_ip(body.as_bytes()) {
                    Ok(ip) => result.verified_ip = Some(ip),
                    Err(e) => result.error = Some(format!("{e:#}")),
                }
            } else {
                result.error = Some(format!(
                    "curl exited {:?}: {}",
                    result.exit_code,
                    clipped(result.stderr.trim(), 1600)
                ));
            }
        }
        Ok(Err(e)) => result.error = Some(format!("launch/wait for curl: {e}")),
        Err(_) => {
            result.error = Some(format!(
                "curl exceeded {}ms process deadline",
                policy.process_timeout.as_millis()
            ))
        }
    }
    result.elapsed_ms = start.elapsed().as_millis() as u64;
    result
}
pub(crate) async fn verify(cfg: &Config, sd: &Path) -> Result<String> {
    let curl = if cfg!(windows) {
        std::path::PathBuf::from(
            std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into()),
        )
        .join("System32")
        .join("curl.exe")
    } else {
        "curl".into()
    };
    verify_with(&curl, cfg, sd, Policy::default()).await
}
async fn verify_with(curl: &Path, cfg: &Config, sd: &Path, policy: Policy) -> Result<String> {
    let route = if cfg.tun.full_tunnel {
        Route::System
    } else {
        Route::Socks
    };
    let mut report = Report {
        endpoint: ENDPOINT,
        full_tunnel: cfg.tun.full_tunnel,
        accepted: false,
        attempts: Vec::new(),
    };
    save(sd, &report).await?;
    for number in 1..=3 {
        progress(
            sd,
            &format!("Verifying {} HTTPS, attempt {number}/3", route.label()),
        )
        .await;
        let attempt = probe(curl, cfg, route, number, false, policy).await;
        let verified = attempt.verified_ip.clone();
        let again = retryable(&attempt) && number < 3;
        report.attempts.push(attempt);
        if let Some(ip) = verified {
            report.accepted = true;
            save(sd, &report).await?;
            return Ok(ip);
        }
        save(sd, &report).await?;
        if !again {
            break;
        }
        tokio::time::sleep(policy.retry_delay).await;
    }
    let failure = report
        .attempts
        .last()
        .and_then(|a| a.error.clone())
        .unwrap_or_else(|| "HTTPS check failed without a diagnostic".into());
    let mut detail = String::new();
    if cfg.tun.full_tunnel {
        progress(
            sd,
            "System-route check failed; testing SOCKS for diagnosis only",
        )
        .await;
        let diagnostic = probe(curl, cfg, Route::Socks, 1, true, policy).await;
        detail = if diagnostic.verified_ip.is_some() {
            "; SOCKS HTTPS succeeded but system-route HTTPS failed; full tunnel was NOT accepted"
                .into()
        } else {
            format!(
                "; SOCKS diagnostic also failed: {}",
                diagnostic.error.as_deref().unwrap_or("unconfirmed")
            )
        };
        report.attempts.push(diagnostic);
        save(sd, &report).await?;
    }
    bail!("{failure}{detail}. See verification.json for TLS/route details")
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::{os::unix::fs::PermissionsExt, path::PathBuf};

    struct Fixture {
        dir: PathBuf,
        exe: PathBuf,
    }
    impl Fixture {
        fn new(body: &str) -> Self {
            let dir = std::env::temp_dir().join(format!("torvpn-https-{}", rand::random::<u64>()));
            std::fs::create_dir_all(&dir).unwrap();
            let exe = dir.join("fake curl");
            let prefix = r#"#!/bin/sh
set -eu
printf '%s\n' "$@" > "$0.args"
if [ "${HTTP_PROXY+x}${HTTPS_PROXY+x}${ALL_PROXY+x}${NO_PROXY+x}${http_proxy+x}${https_proxy+x}${all_proxy+x}${no_proxy+x}" != "" ]; then
  printf 'proxy environment was not removed' >&2
  exit 90
fi
"#;
            std::fs::write(&exe, format!("{prefix}{body}\n")).unwrap();
            std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
            Self { dir, exe }
        }
        fn cfg(&self, full: bool) -> Config {
            let mut cfg: Config =
                toml::from_str(include_str!("../../../profiles/default_win.toml")).unwrap();
            cfg.tun.full_tunnel = full;
            cfg
        }
        fn report(&self) -> serde_json::Value {
            serde_json::from_slice(&std::fs::read(self.dir.join("verification.json")).unwrap())
                .unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }
    fn quick() -> Policy {
        Policy {
            process_timeout: Duration::from_secs(2),
            retry_delay: Duration::ZERO,
        }
    }

    #[tokio::test]
    async fn actual_reset_then_success_retries_system_route_with_tls_validation() {
        let f = Fixture::new(
            r#"
n=0
if [ -f "$0.count" ]; then n=$(cat "$0.count"); fi
n=$((n+1)); printf '%s' "$n" > "$0.count"
if [ "$n" -eq 1 ]; then printf 'curl: (35) Send failure: Connection was reset' >&2; exit 35; fi
printf '{"IsTor":true,"IP":"198.51.100.9"}\nTORVPN_CURL_META\tremote_ip=192.0.2.1\thttp_code=200\tssl_verify_result=0\n'
"#,
        );
        let ip = verify_with(&f.exe, &f.cfg(true), &f.dir, quick())
            .await
            .unwrap();
        assert_eq!(ip, "198.51.100.9");
        let report = f.report();
        assert_eq!(report["accepted"], true);
        assert_eq!(report["attempts"].as_array().unwrap().len(), 2);
        assert_eq!(report["attempts"][0]["exit_code"], 35);
        assert!(report["attempts"][1]["metadata"]
            .as_str()
            .unwrap()
            .contains("http_code=200"));
        let args = std::fs::read_to_string(f.exe.with_file_name("fake curl.args")).unwrap();
        assert!(args.starts_with("-q\n"));
        assert!(args.contains("--ipv4\n") && args.contains("--http1.1\n"));
        assert!(args.contains("--noproxy\n*\n"));
        for bad in [
            "--socks5-hostname",
            "--insecure",
            "--ssl-no-revoke",
            "--ssl-revoke-best-effort",
        ] {
            assert!(!args.contains(bad));
        }
    }
    #[tokio::test]
    async fn socks_success_after_native_resets_never_accepts_full_tunnel() {
        let f = Fixture::new(
            r#"
case "$*" in
 *--socks5-hostname*) printf '{"IsTor":true,"IP":"198.51.100.9"}' ;;
 *) printf 'curl: (35) Send failure: Connection was reset' >&2; exit 35 ;;
esac
"#,
        );
        let error = verify_with(&f.exe, &f.cfg(true), &f.dir, quick())
            .await
            .unwrap_err();
        assert!(error
            .to_string()
            .contains("SOCKS HTTPS succeeded but system-route HTTPS failed"));
        let report = f.report();
        assert_eq!(report["accepted"], false);
        let attempts = report["attempts"].as_array().unwrap();
        assert_eq!(attempts.len(), 4);
        assert!(attempts[..3]
            .iter()
            .all(|a| a["route"] == "system-route" && a["diagnostic_only"] == false));
        assert_eq!(attempts[3]["diagnostic_only"], true);
        assert_eq!(attempts[3]["verified_ip"], "198.51.100.9");
    }
    #[tokio::test]
    async fn certificate_failure_is_not_retried_or_downgraded() {
        let f = Fixture::new("printf 'curl: (60) certificate verification failed' >&2; exit 60");
        assert!(verify_with(&f.exe, &f.cfg(true), &f.dir, quick())
            .await
            .is_err());
        let report = f.report();
        assert_eq!(report["attempts"].as_array().unwrap().len(), 2);
        assert_eq!(report["attempts"][0]["exit_code"], 60);
        assert_eq!(report["attempts"][1]["diagnostic_only"], true);
        assert_eq!(report["accepted"], false);
    }
    #[tokio::test]
    async fn non_tor_success_response_is_rejected_without_native_retry() {
        let f = Fixture::new(r#"printf '{"IsTor":false,"IP":"198.51.100.9"}'"#);
        let error = verify_with(&f.exe, &f.cfg(true), &f.dir, quick())
            .await
            .unwrap_err();
        assert!(error.to_string().contains("IsTor is not true"));
        let report = f.report();
        assert_eq!(report["attempts"].as_array().unwrap().len(), 2);
        assert_eq!(report["accepted"], false);
    }
    #[tokio::test]
    async fn hung_curl_is_bounded_and_its_failure_report_survives() {
        let f = Fixture::new("exec sleep 30");
        let policy = Policy {
            process_timeout: Duration::from_millis(100),
            retry_delay: Duration::ZERO,
        };
        let started = tokio::time::Instant::now();
        assert!(verify_with(&f.exe, &f.cfg(true), &f.dir, policy)
            .await
            .is_err());
        assert!(started.elapsed() < Duration::from_secs(2));
        let report = f.report();
        assert_eq!(report["accepted"], false);
        assert!(report["attempts"][0]["error"]
            .as_str()
            .unwrap()
            .contains("100ms"));
    }
    #[tokio::test]
    async fn explicit_socks_mode_verifies_proxy_without_claiming_system_tunnel() {
        let f = Fixture::new(r#"printf '{"IsTor":true,"IP":"198.51.100.9"}'"#);
        verify_with(&f.exe, &f.cfg(false), &f.dir, quick())
            .await
            .unwrap();
        let report = f.report();
        assert_eq!(report["full_tunnel"], false);
        assert_eq!(report["attempts"][0]["route"], "socks-proxy");
    }
    #[test]
    fn malformed_missing_and_non_exit_check_results_fail() {
        for body in [
            "garbage",
            r#"{"IsTor":"true","IP":"198.51.100.9"}"#,
            r#"{"IsTor":true}"#,
            r#"{"IsTor":true,"IP":"bad"}"#,
            r#"{"IsTor":true,"IP":"127.0.0.1"}"#,
            r#"{"IsTor":true,"IP":"0.0.0.0"}"#,
        ] {
            assert!(confirmed_ip(body.as_bytes()).is_err());
        }
    }
}
