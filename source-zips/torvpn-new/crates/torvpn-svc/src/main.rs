//! torvpn-svc: Windows service binary + CLI control.
//!
//! As a service, it idles on the control HTTP server and only spins up
//! tor/tun2socks when something hits `/control/connect` (or the user clicks
//! the tray icon). That's the key behavioural change from previous versions
//! which started everything eagerly.
//!
//! As a CLI, it's a thin client to the service — `connect`, `disconnect`,
//! `toggle`, `status`, etc. — using the local HTTP API.
//!
//! Subcommands that don't fit the API (service install/uninstall, profile
//! load for service-mode init) are handled directly.

use anyhow::{anyhow, Context, Result};
use clap::{Parser, Subcommand};
use std::path::PathBuf;

use torvpn_core::{api, config, paths, state::Engagement, control_server};

#[cfg(windows)]
mod service;

#[derive(Parser, Debug)]
#[command(name = "torvpn-svc", version, about = "TorVPN Windows service + CLI")]
struct Cli {
    /// Override the profile path (default: %ProgramData%\torvpn\profile.toml or bundled).
    #[arg(long)]
    profile: Option<PathBuf>,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Engage the VPN (talks to the running service).
    Connect,
    /// Disengage the VPN.
    Disconnect,
    /// Flip engagement state.
    Toggle,
    /// JSON status from the service.
    Status,
    /// Force new Tor circuits.
    Newnym,
    /// Set exit countries (comma-separated cc, e.g. "us,de"); empty clears.
    ExitSet { countries: String },
    /// Clear exit-country preference.
    ExitClear,

    /// Install the Windows service (admin required).
    ServiceInstall,
    /// Uninstall the Windows service.
    ServiceUninstall,
    /// Internal: invoked by the SCM. Don't run by hand.
    ServiceRun,
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let cli = Cli::parse();

    // Profile resolution: CLI flag → %PROGRAMDATA%\torvpn\profile.toml → bundled.
    let profile_path = cli.profile.clone().or_else(|| {
        let p = paths::config_path();
        if p.exists() { Some(p) } else { None }
    });

    match cli.cmd {
        Cmd::ServiceRun => {
            #[cfg(windows)]
            { service::run_service_dispatcher()?; return Ok(()); }
            #[cfg(not(windows))]
            { anyhow::bail!("ServiceRun is Windows-only"); }
        }

        Cmd::ServiceInstall   => service_install().await,
        Cmd::ServiceUninstall => service_uninstall().await,

        // All "live" commands go through the API to the running service.
        Cmd::Connect | Cmd::Disconnect | Cmd::Toggle | Cmd::Status
        | Cmd::Newnym | Cmd::ExitSet { .. } | Cmd::ExitClear => {
            let cfg = config::load_or_default(profile_path.as_deref()).await?;
            let client = api::Client::from_token_file(&cfg.status.listen, &paths::api_token_path()).await?;
            match cli.cmd {
                Cmd::Connect    => { client.connect().await?;    println!("connected"); }
                Cmd::Disconnect => { client.disconnect().await?; println!("disconnected"); }
                Cmd::Toggle => {
                    let p = client.toggle().await?;
                    println!("{:?}", p);
                }
                Cmd::Status => {
                    let s = client.status().await?;
                    println!("{}", serde_json::to_string_pretty(&s)?);
                }
                Cmd::Newnym => { client.newnym().await?; println!("newnym ok"); }
                Cmd::ExitSet { countries } => {
                    client.exit_set(&countries).await?;
                    println!("exits set: {countries}");
                }
                Cmd::ExitClear => { client.exit_clear().await?; println!("exits cleared"); }
                _ => unreachable!(),
            }
            Ok(())
        }
    }
}

async fn service_install() -> Result<()> {
    let exe = std::env::current_exe().context("current_exe")?;
    let binpath = format!("\"{}\" ServiceRun", exe.display());
    tokio::process::Command::new("sc.exe")
        .args(["create", "TorVPN", "binPath=", &binpath, "start=", "auto"])
        .status().await?;
    tokio::process::Command::new("sc.exe")
        .args(["description", "TorVPN", "Tor-routed VPN daemon (torvpn-svc)"])
        .status().await?;
    tokio::process::Command::new("sc.exe")
        .args(["failure", "TorVPN", "reset=", "60", "actions=", "restart/5000/restart/5000/restart/5000"])
        .status().await?;
    tokio::process::Command::new("sc.exe").args(["start", "TorVPN"]).status().await?;
    println!("Installed and started service 'TorVPN'.");
    Ok(())
}

async fn service_uninstall() -> Result<()> {
    let _ = tokio::process::Command::new("sc.exe").args(["stop", "TorVPN"]).status().await;
    tokio::process::Command::new("sc.exe").args(["delete", "TorVPN"]).status().await?;
    println!("Uninstalled service 'TorVPN'.");
    Ok(())
}

/// Used by the service to start the control server with an empty engagement.
/// Public so `service.rs` can call it.
#[cfg(windows)]
pub(crate) async fn serve_forever(stop_signal: std::sync::Arc<std::sync::atomic::AtomicBool>) -> Result<()> {
    let cfg_path = paths::config_path();
    let cfg = if cfg_path.exists() {
        config::load_or_default(Some(&cfg_path)).await?
    } else {
        config::load_or_default(None).await?
    };
    let state_dir = paths::state_dir();
    tokio::fs::create_dir_all(&state_dir).await?;

    let engagement = Engagement::new(paths::state_file());

    // Watchdog: every 5s, if engaged, tick the hop plan.
    let cfg_for_tick = cfg.clone();
    let sd_for_tick  = state_dir.clone();
    let eng_for_tick = engagement.clone();
    let stop_for_tick = stop_signal.clone();
    tokio::spawn(async move {
        use std::sync::atomic::Ordering;
        while !stop_for_tick.load(Ordering::SeqCst) {
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            if eng_for_tick.current().await.phase == torvpn_core::state::Phase::Engaged {
                let _ = torvpn_core::hop_plan::maybe_tick(&cfg_for_tick, &sd_for_tick).await;
            }
        }
    });

    // Run control server in a task we can cancel.
    let cfg2 = cfg.clone();
    let sd2 = state_dir.clone();
    let eng2 = engagement.clone();
    let server = tokio::spawn(async move {
        let _ = control_server::run(cfg2, sd2, eng2).await;
    });

    // Wait for SCM stop.
    {
        use std::sync::atomic::Ordering;
        while !stop_signal.load(Ordering::SeqCst) {
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        }
    }

    // On stop: gracefully disengage so we don't leave firewall/DNS locked.
    let _ = engagement.disconnect(&state_dir).await;
    server.abort();
    let _ = server.await;
    Ok(())
}

// Stub for non-Windows so `cargo check` works on dev hosts.
#[cfg(not(windows))]
#[allow(dead_code)]
async fn _unused_for_unix() -> Result<()> { Err(anyhow!("unix build")) }
