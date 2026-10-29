//! Bounded administrative processes with persistent output and live progress.
use anyhow::{Context, Result};
use base64::Engine;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub async fn run(name: &str, mut args: serde_json::Value) -> Result<()> {
    let dir = std::env::current_exe()?
        .parent()
        .context("executable parent")?
        .to_path_buf();
    let script = dir.join("scripts").join(name);
    anyhow::ensure!(
        script.is_file(),
        "missing script {}; install the complete package",
        script.display()
    );
    let sd = crate::paths::state_dir();
    args["StateDir"] = sd.to_string_lossy().to_string().into();
    let encoded = base64::engine::general_purpose::STANDARD.encode(serde_json::to_vec(&args)?);
    let ps = if cfg!(windows) {
        PathBuf::from(std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into()))
            .join("System32/WindowsPowerShell/v1.0/powershell.exe")
    } else {
        PathBuf::from("powershell")
    };
    let mut cmd = tokio::process::Command::new(ps);
    cmd.args([
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
    ])
    .arg(&script)
    .arg("-JsonBase64")
    .arg(encoded);
    #[cfg(windows)]
    cmd.creation_flags(0x0800_0000);
    // Firewall changes may touch hundreds of rules. Batch operations avoid
    // hundreds of cmdlet launches, while a documented hard bound still applies.
    let limit = if matches!(name, "fw-apply.ps1" | "fw-teardown.ps1") {
        300
    } else {
        75
    };
    run_command(name, &sd, &mut cmd, Duration::from_secs(limit)).await
}

async fn run_command(
    name: &str,
    sd: &Path,
    cmd: &mut tokio::process::Command,
    limit: Duration,
) -> Result<()> {
    tokio::fs::create_dir_all(sd).await?;
    let log_path = sd.join(format!("script-{name}.log"));
    let output = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&log_path)?;
    cmd.stdout(std::process::Stdio::from(output.try_clone()?))
        .stderr(std::process::Stdio::from(output))
        .kill_on_drop(true);
    let progress = serde_json::json!({"script": name, "message": "Starting administrative script", "updated_ms": now_ms()});
    tokio::fs::write(
        sd.join("admin-progress.json"),
        serde_json::to_vec(&progress)?,
    )
    .await?;
    log::info!("[script] {name} starting; output: {}", log_path.display());
    let mut child = cmd.spawn().with_context(|| format!("launch {name}"))?;
    #[cfg(windows)]
    let _job = crate::process_job::Job::for_child(&child)?;
    let outcome = tokio::time::timeout(limit, child.wait()).await;
    if outcome.is_err() {
        // Finish terminating the exact child before recovery starts. Retain
        // its output and last checkpoint even when the process timed out.
        let _ = tokio::time::timeout(Duration::from_secs(5), child.kill()).await;
        let stage = progress_detail(sd)
            .await
            .unwrap_or_else(|| "no checkpoint available".into());
        anyhow::bail!(
            "{name} timed out after {}s; last stage: {stage}; output: {}",
            limit.as_secs(),
            log_path.display()
        );
    }
    let status = outcome
        .context("script timer")?
        .with_context(|| format!("wait for {name}"))?;
    let bytes = tokio::fs::read(&log_path).await.unwrap_or_default();
    anyhow::ensure!(
        status.success(),
        "{name} failed ({status}): {} (output: {})",
        crate::firewall::ps_fail_detail(&bytes, &[]),
        log_path.display()
    );
    log::info!("[script] {name} completed");
    Ok(())
}
fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
pub(crate) async fn progress_detail(sd: &Path) -> Option<String> {
    let (_, text) = progress(sd).await?;
    Some(text)
}
pub(crate) async fn progress(sd: &Path) -> Option<(u64, String)> {
    let bytes = tokio::fs::read(sd.join("admin-progress.json")).await.ok()?;
    let text = std::str::from_utf8(&bytes)
        .ok()?
        .trim_start_matches('\u{feff}');
    let doc: serde_json::Value = serde_json::from_str(text).ok()?;
    let script = doc.get("script")?.as_str()?;
    let message = doc.get("message")?.as_str()?;
    let at = doc.get("updated_ms")?.as_u64()?;
    Some((at, format!("{script}: {message}")))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    fn temp() -> PathBuf {
        std::env::temp_dir().join(format!("torvpn-script-{}", rand::random::<u64>()))
    }
    #[tokio::test]
    async fn timeout_retains_child_output_and_checkpoint() {
        let sd = temp();
        let mut cmd = tokio::process::Command::new("sh");
        cmd.args([
            "-c",
            "printf 'provider entered batch operation\\n'; exec sleep 20",
        ]);
        let error = run_command("test", &sd, &mut cmd, Duration::from_millis(200))
            .await
            .unwrap_err();
        assert!(error.to_string().contains("last stage:"));
        assert!(std::fs::read_to_string(sd.join("script-test.log"))
            .unwrap()
            .contains("provider entered batch"));
        tokio::fs::remove_dir_all(sd).await.unwrap();
    }
    #[tokio::test]
    async fn nonzero_script_exit_preserves_real_error_text() {
        let sd = temp();
        let mut cmd = tokio::process::Command::new("sh");
        cmd.args(["-c", "printf 'specific provider error\\n' >&2; exit 7"]);
        let error = run_command("test", &sd, &mut cmd, Duration::from_secs(2))
            .await
            .unwrap_err();
        assert!(error.to_string().contains("specific provider error"));
        tokio::fs::remove_dir_all(sd).await.unwrap();
    }
    #[tokio::test]
    async fn windows_utf8_bom_checkpoint_is_readable() {
        let sd = temp();
        tokio::fs::create_dir_all(&sd).await.unwrap();
        tokio::fs::write(sd.join("admin-progress.json"),"\u{feff}{\"script\":\"fw-apply.ps1\",\"message\":\"Suspending 187 Local rules in one batch\",\"updated_ms\":12}").await.unwrap();
        let (at, message) = progress(&sd).await.unwrap();
        assert_eq!(at, 12);
        assert!(message.contains("187 Local"));
        tokio::fs::remove_dir_all(sd).await.unwrap();
    }
}
