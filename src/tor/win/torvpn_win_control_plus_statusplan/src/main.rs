//! torvpn_win: Windows MVP skeleton – manages Tor and external tun2socks (Wintun), with firewall kill-switch.
//! - tor_manager: generates torrc from profile, spawns tor.exe, monitors bootstrap via stdout.
//! - tun2socks_manager: spawns external tun2socks for Windows, device "wintun://<name>"
//! - firewall: applies strict outbound policy allowing only Wintun interface and Tor process
//! - CLI: start/stop/status --profile <file>
//!
//! Requirements on system:
//!   - tor.exe in PATH (or specify by PATH/installation)
//!   - tun2socks.exe in PATH (build that supports Wintun; includes wintun.dll)
//!   - PowerShell available (for firewall scripts)
//!
//! This is privacy tooling for legitimate use only.

mod tor_manager;
mod tun2socks_manager;
mod firewall;
mod proxy_manager;
mod pqc;
mod config;
mod service;
mod tor_control;
mod status_server;
mod hop_plan;
mod status;
mod nrpt;

use clap::{Parser, Subcommand};
use anyhow::{Result, bail};
use std::path::PathBuf;
use tokio::{fs, process::Command};
use dirs::home_dir;

#[derive(Parser, Debug)]
#[command(name="torvpn-win", version, about="Tor-routed VPN (Windows MVP)")]
struct Cli {
    /// Profile TOML path (overrides built-in profiles)
    #[arg(long)]
    profile: Option<PathBuf>,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// PQC: generate Dilithium2 signing keys into a directory
    PqcKeygen { out_dir: String },
    /// PQC: sign a file
    PqcSign { sk: String, input: String, sig_out: String },
    /// PQC: verify a file+sig
    PqcVerify { pk: String, input: String, sig: String },
    /// PQC: Kyber KEM demo (writes files)
    PqcKemDemo { out_dir: String },
    /// Rotate to next proxy and NEWNYM
    ProxyNext,
    /// Apply proxy/exit policy from profile
    ApplyPolicy,
    /// Set exit countries (comma-separated, e.g. us,de) and enable StrictNodes
    ExitSet { countries: String },
    /// Clear exit country preferences
    ExitClear,
    /// Tor control: signal NEWNYM
    Newnym,
    /// Tor control: print circuits
    Circuits,
    /// Tor control: health summary
    Health,
    /// Install the Windows Service
    ServiceInstall,
    /// Uninstall the Windows Service
    ServiceUninstall,
    /// Run as Windows Service (invoked by SCM)
    ServiceRun,
    /// Start Tor + tun2socks + firewall lock
    Start,
    /// Stop all components and restore firewall
    Stop,
    /// Show status (basic)
    Status,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let state_dir = default_state_dir()?;
    fs::create_dir_all(&state_dir).await?;

    let cfg = config::load_or_default(cli.profile.as_deref()).await?;
    match cli.cmd {
        Cmd::Start => start(cfg.clone(), &state_dir).await?,
        Cmd::Newnym => control_newnym(&state_dir, &cfg).await?,
        Cmd::Circuits => control_circuits(&state_dir, &cfg).await?,
        Cmd::Health => control_health(&state_dir, &cfg).await?,
        Cmd::ProxyNext => { tor_manager::apply_proxy_and_exit(&cfg, &state_dir).await?; println!("Applied next proxy (if enabled) and rotated circuits."); },
        Cmd::ApplyPolicy => { tor_manager::apply_proxy_and_exit(&cfg, &state_dir).await?; println!("Applied proxy/exit policy from profile."); },
        Cmd::ExitSet { countries } => { let mut c2 = cfg.clone(); c2.exit.countries = countries.split(',').map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty()).collect(); c2.exit.strict = true; tor_manager::apply_proxy_and_exit(&c2, &state_dir).await?; println!("Set ExitNodes to {{{}}}, StrictNodes=1", c2.exit.countries.join(",")); },
        Cmd::ExitClear => { let mut c2 = cfg.clone(); c2.exit.countries.clear(); c2.exit.strict = false; tor_manager::apply_proxy_and_exit(&c2, &state_dir).await?; println!("Cleared ExitNodes/StrictNodes"); },
        Cmd::PqcKeygen { out_dir } => { pqc::keygen_sig(std::path::Path::new(&out_dir)).await?; println!("Keys written to {}", out_dir); },
        Cmd::PqcSign { sk, input, sig_out } => { pqc::sign_file(std::path::Path::new(&sk), std::path::Path::new(&input), std::path::Path::new(&sig_out)).await?; println!("Signed -> {}", sig_out); },
        Cmd::PqcVerify { pk, input, sig } => { let ok = pqc::verify_file(std::path::Path::new(&pk), std::path::Path::new(&input), std::path::Path::new(&sig)).await?; println!("Verify: {}", if ok {"OK"} else {"FAIL"}); },
        Cmd::PqcKemDemo { out_dir } => { pqc::kem_demo(std::path::Path::new(&out_dir)).await?; println!("KEM demo written to {}", out_dir); },
        Cmd::ServiceInstall => service_install().await?,
        Cmd::ServiceUninstall => service_uninstall().await?,
        Cmd::ServiceRun => { service::run_service_dispatcher()?; },

        Cmd::Stop => stop(&state_dir).await?,
        Cmd::Status => status(&state_dir).await?,
    }
    Ok(())
}

fn default_state_dir() -> Result<PathBuf> {
    let mut p = home_dir().ok_or_else(|| anyhow::anyhow!("no home dir"))?;
    p.push("AppData/Local/torvpn");
    Ok(p)
}

async fn start(cfg: config::Config, state_dir: &PathBuf) -> Result<()> {
    // 1) Apply firewall policy (fail-closed ASAP). We pass adapter hint to PS script.
    firewall::apply_rules(&cfg).await?;

    // 2) DNS lock (NRPT + firewall DNS blocks)
    nrpt::apply_dns_lock(&cfg).await?;

    // 3) Start Tor
    let tor = tor_manager::TorInstance::start(&cfg, state_dir).await?;

    // 3) Start tun2socks (creates/uses Wintun adapter)
    let t2s = tun2socks_manager::Tun2Socks::start(&cfg).await?;

    // Save PIDs
    let pid_path = state_dir.join("pids.json");
    let pids = serde_json::json!({
        "tor": tor.pid(),
        "tun2socks": t2s.pid(),
    });
    tokio::fs::write(&pid_path, serde_json::to_vec_pretty(&pids)?).await?;

    println!("torvpn-win: started (Tor PID {}, tun2socks PID {})", tor.pid(), t2s.pid());
    Ok(())
}

async fn stop(state_dir: &PathBuf) -> Result<()> {
    // Read PIDs if present
    let pid_path = state_dir.join("pids.json");
    if let Ok(bytes) = tokio::fs::read(&pid_path).await {
        if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&bytes) {
            if let Some(pid) = val.get("tun2socks").and_then(|v| v.as_i64()) {
                let _ = Command::new("taskkill").args(["/PID", &pid.to_string(), "/T", "/F"]).status().await;
            }
            if let Some(pid) = val.get("tor").and_then(|v| v.as_i64()) {
                let _ = Command::new("taskkill").args(["/PID", &pid.to_string(), "/T", "/F"]).status().await;
            }
        }
        let _ = tokio::fs::remove_file(&pid_path).await;
    }

    // 1) Teardown DNS lock
    nrpt::teardown_dns_lock().await?;

    // 2) Teardown firewall
    firewall::teardown_rules().await?;

    println!("torvpn-win: stopped");
    Ok(())
}

async fn status(state_dir: &PathBuf) -> Result<()> {
    let pid_path = state_dir.join("pids.json");
    if let Ok(bytes) = tokio::fs::read(&pid_path).await {
        if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&bytes) {
            println!("{}", serde_json::to_string_pretty(&val)?);
            return Ok(());
        }
    }
    println!("not running");
    Ok(())
}


async fn service_install() -> anyhow::Result<()> {
    use tokio::process::Command;
    // Install service via sc.exe with binpath pointing to "torvpn-win.exe ServiceRun"
    let exe = std::env::current_exe()?;
    let binpath = format!("\"{}\" ServiceRun", exe.display());
    Command::new("sc.exe").args(["create","TorVPN","binPath=", &binpath,"start=","auto"]).status().await?;
    Command::new("sc.exe").args(["description","TorVPN","Tor-routed VPN daemon"]).status().await?;
    Command::new("sc.exe").args(["failure","TorVPN","reset=","60","actions=","restart/5000"]).status().await?;
    println!("Installed service 'TorVPN'.");
    Ok(())
}

async fn service_uninstall() -> anyhow::Result<()> {
    use tokio::process::Command;
    let _ = Command::new("sc.exe").args(["stop","TorVPN"]).status().await;
    let _ = Command::new("sc.exe").args(["delete","TorVPN"]).status().await;
    println!("Uninstalled service 'TorVPN'.");
    Ok(())
}


async fn control_connect(state_dir: &std::path::Path, cfg: &config::Config) -> anyhow::Result<tor_control::TorControl> {
    let cookie = state_dir.join("tor-data").join("control_auth_cookie");
    let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
    let ctl = tor_control::TorControl::connect(&addr, &cookie).await?;
    Ok(ctl)
}

async fn control_newnym(state_dir: &std::path::Path, cfg: &config::Config) -> anyhow::Result<()> {
    let mut ctl = control_connect(state_dir, cfg).await?;
    ctl.signal_newnym().await?;
    println!("OK: NEWNYM");
    Ok(())
}

async fn control_circuits(state_dir: &std::path::Path, cfg: &config::Config) -> anyhow::Result<()> {
    let mut ctl = control_connect(state_dir, cfg).await?;
    let s = ctl.circuits().await?;
    println!("{}", s);
    Ok(())
}

async fn control_health(state_dir: &std::path::Path, cfg: &config::Config) -> anyhow::Result<()> {
    let mut ctl = control_connect(state_dir, cfg).await?;
    let s = ctl.health_summary().await?;
    println!("{}", s);
    Ok(())
}
