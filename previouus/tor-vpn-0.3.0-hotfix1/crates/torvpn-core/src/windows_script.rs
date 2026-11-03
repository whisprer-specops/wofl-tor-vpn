//! One bounded, output-capturing runner for the bundled administrative scripts.
use anyhow::{Context, Result};
use base64::Engine;
use std::path::PathBuf;
pub async fn run(name: &str, mut args: serde_json::Value) -> Result<()> {
    let dir = std::env::current_exe()?
        .parent()
        .context("executable parent")?
        .to_path_buf();
    let script = dir.join("scripts").join(name);
    anyhow::ensure!(
        script.is_file(),
        "missing script {}; use Repair.ps1 to install the complete package",
        script.display()
    );
    args["StateDir"] = crate::paths::state_dir()
        .to_string_lossy()
        .to_string()
        .into();
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
    .arg(encoded)
    .kill_on_drop(true);
    #[cfg(windows)]
    cmd.creation_flags(0x0800_0000);
    let out = tokio::time::timeout(std::time::Duration::from_secs(75), cmd.output())
        .await
        .with_context(|| format!("{name} timed out"))?
        .with_context(|| format!("launch {}", script.display()))?;
    anyhow::ensure!(
        out.status.success(),
        "{name} failed ({}): {}",
        out.status,
        crate::firewall::ps_fail_detail(&out.stdout, &out.stderr)
    );
    Ok(())
}
