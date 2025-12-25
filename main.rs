//! torvpn: Linux MVP skeleton – manages Tor and an external tun2socks, with nftables kill-switch.
//! - tor_manager: generates torrc from profile, spawns tor, monitors bootstrap via stdout.
//! - tun2socks_manager: spawns external tun2socks (go-tun2socks or similar) bound to tor's SOCKS.
//! - nftables: applies strict allowlist to TUN + Tor only; teardown restores previous state.
//! - CLI: start/stop/status --profile <file>
//!
//! Requirements on system:
//!   - tor binary in PATH
//!   - tun2socks binary in PATH (e.g., `tun2socks` from go-tun2socks)
//!   - iproute2, nftables
//!   - Linux with /dev/net/tun support
//!
//! This is privacy tooling for legitimate use only.

mod tor_manager;
mod proxy_manager;
mod pqc;
mod leaktest;
mod tun2socks_manager;
mod nftables;
mod routing;
mod config;
mod tor_control;
mod status_server;
mod status;
mod hop_plan;

use clap::{Parser, Subcommand};
use anyhow::{Result, bail};
use std::path::PathBuf;
use tokio::{fs, process::Command};
use dirs::home_dir;

#[derive(Parser, Debug)]
#[command(name="torvpn", version, about="Tor-routed VPN (Linux MVP)")]
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
    /// Rotate to next proxy in the configured list and NEWNYM
    ProxyNext,
    /// Apply current proxy and exit policy from profile
    ApplyPolicy,
    /// Set exit countries (comma-separated, e.g. us,de) and enable StrictNodes
    ExitSet { countries: String },
    /// Clear exit country preferences
    ExitClear,
    /// Run leak test (DNS and Tor SOCKS connectivity)
    Leaktest,
    /// Run long-lived daemon that monitors and auto-recovers components
    Daemon,
    /// Tor control: signal NEWNYM
    Newnym,
    /// Tor control: print circuits
    Circuits,
    /// Tor control: health summary
    Health,
    /// Start Tor + tun2socks + nftables
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
        Cmd::Daemon => daemon(cfg.clone(), &state_dir).await?,
        Cmd::Newnym => control_newnym(&state_dir, &cfg).await?,
        Cmd::Circuits => control_circuits(&state_dir, &cfg).await?,
        Cmd::Health => control_health(&state_dir, &cfg).await?,
        Cmd::Leaktest => do_leaktest(&cfg).await?,
        Cmd::ProxyNext => proxy_next(&state_dir, &cfg).await?,
        Cmd::ApplyPolicy => apply_policy(&state_dir, &cfg).await?,
        Cmd::ExitSet { countries } => exit_set(&state_dir, &cfg, &countries).await?,
        Cmd::ExitClear => exit_clear(&state_dir, &cfg).await?,
        Cmd::PqcKeygen { out_dir } => { pqc::keygen_sig(std::path::Path::new(&out_dir)).await?; println!("Keys written to {}", out_dir); },
        Cmd::PqcSign { sk, input, sig_out } => { pqc::sign_file(std::path::Path::new(&sk), std::path::Path::new(&input), std::path::Path::new(&sig_out)).await?; println!("Signed -> {}", sig_out); },
        Cmd::PqcVerify { pk, input, sig } => { let ok = pqc::verify_file(std::path::Path::new(&pk), std::path::Path::new(&input), std::path::Path::new(&sig)).await?; println!("Verify: {}", if ok {"OK"} else {"FAIL"}); },
        Cmd::PqcKemDemo { out_dir } => { pqc::kem_demo(std::path::Path::new(&out_dir)).await?; println!("KEM demo written to {}", out_dir); },
        Cmd::Stop => stop(&state_dir).await?,
        Cmd::Status => status(&state_dir).await?,
    }
    Ok(())
}

fn default_state_dir() -> Result<PathBuf> {
    let mut p = home_dir().ok_or_else(|| anyhow::anyhow!("no home dir"))?;
    p.push(".local/share/torvpn");
    Ok(p)
}

async fn start(cfg: config::Config, state_dir: &PathBuf) -> Result<()> {
    // 1) nftables up (fail-closed ASAP)
    nftables::apply_rules(&cfg, state_dir).await?;

    // 2) Networking plumbing
    if cfg.net.mode == "tun2socks" {
        // Policy routing + MSS clamping for tun2socks
        routing::apply_for_tun2socks(&cfg).await?;
    create_tun(&cfg).await?;

        }

    // 3) Start Tor
    let tor = tor_manager::TorInstance::start(&cfg, state_dir).await?;

    // 4) Start tun2socks or enable transparent mode
    if cfg.net.mode == "tun2socks" {
        // Policy routing + MSS clamping for tun2socks
        routing::apply_for_tun2socks(&cfg).await?;
    let t2s = tun2socks_manager::Tun2Socks::start(&cfg).await?;
    let t2s_pid = t2s.pid();
    } else {
        // transparent mode: no tun2socks; tor TransPort handles redirection via nftables
        let t2s_pid: i32 = 0;
    }

    // Save PIDs
    let pid_path = state_dir.join("pids.json");
    let pids = serde_json::json!({
        "tor": tor.pid(),
        "tun2socks": t2s_pid,
    });
    tokio::fs::write(&pid_path, serde_json::to_vec_pretty(&pids)?).await?;

    println!("torvpn: started (Tor PID {}, tun2socks PID {})", tor.pid(), t2s.pid());
    Ok(())
}

async fn stop(state_dir: &PathBuf) -> Result<()> {
    // Read PIDs if present
    let pid_path = state_dir.join("pids.json");
    if let Ok(bytes) = tokio::fs::read(&pid_path).await {
        if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&bytes) {
            if let Some(pid) = val.get("tun2socks").and_then(|v| v.as_i64()) {
                let _ = Command::new("pkill").args(["-TERM", "-P", &pid.to_string()]).status().await;
                let _ = Command::new("kill").arg(pid.to_string()).status().await;
            }
            if let Some(pid) = val.get("tor").and_then(|v| v.as_i64()) {
                let _ = Command::new("kill").arg(pid.to_string()).status().await;
            }
        }
        let _ = tokio::fs::remove_file(&pid_path).await;
    }

    // 1) Teardown tun2socks routing policy
    let _ = routing::teardown_for_tun2socks().await;
    // 2) Teardown tun
    teardown_tun().await?;
    // 2) nftables down
    nftables::teardown_rules().await?;

    println!("torvpn: stopped");
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

async fn create_tun(cfg: &config::Config) -> Result<()> {
    // ip tuntap add dev <name> mode tun
    // ip addr add <cidr> dev <name>
    // ip link set <name> up
    let tun = &cfg.tun.interface;
    let cidr = &cfg.tun.cidr;
    let status = Command::new("sh").arg("-lc")
        .arg(format!(
            "ip tuntap add dev {tun} mode tun && ip addr add {cidr} dev {tun} && ip link set {tun} up"
        )).status().await?;
    if !status.success() { bail!("failed to create TUN: {status:?}"); }
    Ok(())
}

async fn teardown_tun() -> Result<()> {
    let _ = Command::new("sh").arg("-lc")
        .arg("ip link show tun0 >/dev/null 2>&1 && ip link set tun0 down && ip tuntap del dev tun0 mode tun || true")
        .status().await?;
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

async fn daemon(cfg: config::Config, state_dir: &std::path::Path) -> anyhow::Result<()> {
    // start status server
    let _ = status_server::run(cfg.clone(), state_dir.to_path_buf()).await;
    use tokio::time::{sleep, Duration};
    loop {
        // spawn status server once per daemon invocation
        if cfg.status.enabled {
            let _ = tokio::spawn(status::run(cfg.clone(), state_dir.clone()));
        }
        // ensure running
        if let Err(e) = start(cfg.clone(), &state_dir.to_path_buf()).await {
            eprintln!("[daemon] start error: {e:?}");
        }
        // Simple monitor loop: check every 10s that Tor's control answers
        for _ in 0..3600 {
            let _ = hop_plan::maybe_tick(&cfg, state_dir).await;
            match control_connect(state_dir, &cfg).await {
                Ok(_) => { /* healthy */ }
                Err(e) => {
                    eprintln!("[daemon] health failed: {e:?}; restarting...");
                    let _ = stop(&state_dir.to_path_buf()).await;
                    break;
                }
            }
            sleep(Duration::from_secs(10)).await;
        }
        // Cycle stop to refresh
        let _ = stop(&state_dir.to_path_buf()).await;
        sleep(Duration::from_secs(2)).await;
    }
}


async fn do_leaktest(cfg: &config::Config) -> anyhow::Result<()> {
    let r = leaktest::run(cfg.tor.socks_port).await?;
    println!("LeakTest results:");
    println!("  DNS UDP 53 blocked: {}", if r.dns_udp_blocked { "PASS" } else { "FAIL" });
    println!("  Tor SOCKS HTTP:     {}", if r.tor_socks_ok { "PASS" } else { "FAIL" });
    for n in r.notes { println!("  - {}", n); }
    Ok(())
}


async fn proxy_next(state_dir: &std::path::Path, cfg: &config::Config) -> anyhow::Result<()> {
    tor_manager::apply_proxy_and_exit(cfg, state_dir).await?;
    println!("Applied next proxy (if enabled) and rotated circuits.");
    Ok(())
}

async fn apply_policy(state_dir: &std::path::Path, cfg: &config::Config) -> anyhow::Result<()> {
    tor_manager::apply_proxy_and_exit(cfg, state_dir).await?;
    println!("Applied proxy/exit policy from profile.");
    Ok(())
}

async fn exit_set(state_dir: &std::path::Path, cfg: &config::Config, countries: &str) -> anyhow::Result<()> {
    let mut cfg2 = cfg.clone();
    cfg2.exit.countries = countries.split(',').map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty()).collect();
    cfg2.exit.strict = true;
    tor_manager::apply_proxy_and_exit(&cfg2, state_dir).await?;
    println!("Set ExitNodes to {{{}}}, StrictNodes=1", cfg2.exit.countries.join(","));
    Ok(())
}

async fn exit_clear(state_dir: &std::path::Path, cfg: &config::Config) -> anyhow::Result<()> {
    let mut cfg2 = cfg.clone();
    cfg2.exit.countries.clear();
    cfg2.exit.strict = false;
    tor_manager::apply_proxy_and_exit(&cfg2, state_dir).await?;
    println!("Cleared ExitNodes/StrictNodes");
    Ok(())
}
