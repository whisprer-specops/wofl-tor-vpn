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

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::io::Write;
use std::path::PathBuf;

use torvpn_core::{api, config, paths};
#[cfg(windows)]
use torvpn_core::{control_server, state::Engagement};

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

/// Writes every log line to BOTH stderr and a persistent file. Stderr matters
/// for interactive CLI invocations (`connect`, `status`, ...) where a console
/// is actually attached; the file matters for `service-run`, which the SCM
/// launches with no console at all — every `log::warn!`/`log::error!` from
/// firewall/DNS/tor/routing would otherwise vanish into nothing, which is
/// exactly the kind of silent failure that turned "tor.exe not found" into a
/// support question instead of a self-evident error. Writing to a
/// nonexistent console handle is a harmless no-op, so one code path covers
/// both cases.
struct TeeWriter {
    file: std::fs::File,
}

impl Write for TeeWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let _ = std::io::stderr().write_all(buf);
        self.file.write_all(buf)?;
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        let _ = std::io::stderr().flush();
        self.file.flush()
    }
}

/// Logs land in `%ProgramData%\torvpn\svc.log`. That directory is already
/// world-readable (Users get read+execute — see installer.iss `[Dirs]`), the
/// same permission that lets the user-mode tray read the LocalSystem
/// service's api_token, so a non-elevated user can open this log directly.
fn init_logging() {
    let mut builder =
        env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"));
    let dir = paths::state_dir();
    let _ = std::fs::create_dir_all(&dir);
    if let Ok(file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("svc.log"))
    {
        builder.target(env_logger::Target::Pipe(Box::new(TeeWriter { file })));
    }
    builder.init();
}

/// A `log::error!` call only helps if the code got far enough to make one.
/// A genuine `panic!`/`.unwrap()` failure bypasses the `log` crate entirely —
/// it goes through Rust's own panic hook, which by default prints to stderr,
/// which (same disease as tray round 1 and svc round 3) goes nowhere useful
/// for a headless SCM service. This is that same fix applied to panics
/// specifically: install a hook that writes the message + exact file:line to
/// `svc.log` (and stderr, for interactive CLI runs) before anything unwinds
/// or aborts. Install this BEFORE anything that could panic — first line of
/// `main()`, ahead even of `init_logging()`.
fn init_panic_hook() {
    let log_path = paths::state_dir().join("svc.log");
    std::panic::set_hook(Box::new(move |info| {
        let msg = info
            .payload()
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| info.payload().downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "<non-string panic payload>".to_string());
        let loc = info
            .location()
            .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
            .unwrap_or_else(|| "<unknown location>".to_string());
        let epoch_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let line = format!("[epoch_ms={epoch_ms}] PANIC at {loc}: {msg}\n");

        let _ = std::io::stderr().write_all(line.as_bytes());
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
        {
            let _ = f.write_all(line.as_bytes());
        }
    }));
}

#[tokio::main]
async fn main() -> Result<()> {
    init_panic_hook();
    init_logging();
    log::info!(
        "torvpn-svc {} starting, args: {:?}",
        env!("CARGO_PKG_VERSION"),
        std::env::args().collect::<Vec<_>>()
    );
    let cli = Cli::parse();

    // Profile resolution: CLI flag → %PROGRAMDATA%\torvpn\profile.toml → bundled.
    let profile_path = cli.profile.clone().or_else(|| {
        let p = paths::config_path();
        if p.exists() {
            Some(p)
        } else {
            None
        }
    });

    match cli.cmd {
        Cmd::ServiceRun => {
            #[cfg(windows)]
            {
                service::run_service_dispatcher()?;
                return Ok(());
            }
            #[cfg(not(windows))]
            {
                anyhow::bail!("ServiceRun is Windows-only");
            }
        }

        Cmd::ServiceInstall => service_install(profile_path.as_deref()).await,
        Cmd::ServiceUninstall => service_uninstall().await,

        // All "live" commands go through the API to the running service.
        Cmd::Connect
        | Cmd::Disconnect
        | Cmd::Toggle
        | Cmd::Status
        | Cmd::Newnym
        | Cmd::ExitSet { .. }
        | Cmd::ExitClear => {
            let cfg = config::load_or_default(profile_path.as_deref()).await?;
            let client =
                api::Client::from_token_file(&cfg.status.listen, &paths::api_token_path()).await?;
            match cli.cmd {
                Cmd::Connect => {
                    client.connect().await?;
                    println!("connected");
                }
                Cmd::Disconnect => {
                    client.disconnect().await?;
                    println!("disconnected");
                }
                Cmd::Toggle => {
                    let p = client.toggle().await?;
                    println!("{:?}", p);
                }
                Cmd::Status => {
                    let s = client.status().await?;
                    println!("{}", serde_json::to_string_pretty(&s)?);
                }
                Cmd::Newnym => {
                    client.newnym().await?;
                    println!("newnym ok");
                }
                Cmd::ExitSet { countries } => {
                    client.exit_set(&countries).await?;
                    println!("exits set: {countries}");
                }
                Cmd::ExitClear => {
                    client.exit_clear().await?;
                    println!("exits cleared");
                }
                _ => unreachable!(),
            }
            Ok(())
        }
    }
}

async fn service_install(profile_path: Option<&std::path::Path>) -> Result<()> {
    let exe = std::env::current_exe().context("current_exe")?;

    // Two-step install:
    //
    //   1. Create the service entry via sc.exe with a placeholder binPath.
    //      We use a placeholder because sc.exe's quoting of paths-with-spaces
    //      is genuinely cursed -- the embedded backslash-escaped quotes get
    //      mangled by every shell that touches them (cmd, pwsh, PowerShell
    //      ISE, all differently). It's not worth fighting.
    //
    //   2. Write the REAL binPath directly to the registry under
    //      HKLM\SYSTEM\CurrentControlSet\Services\TorVPN\ImagePath. The
    //      "ImagePath" registry value IS the binPath -- sc.exe is just a
    //      wrapper around editing it. Writing it ourselves with the windows
    //      crate's registry API avoids ALL shell-quoting issues.
    //
    // The placeholder still has to be syntactically valid for sc.exe, hence
    // the short no-spaces path -- it'll be overwritten in step 2 before the
    // service ever starts.
    let created = tokio::process::Command::new("sc.exe")
        .args([
            "create",
            "TorVPN",
            "binPath=",
            "placeholder.exe",
            "start=",
            "auto",
        ])
        .output()
        .await
        .context("sc.exe create")?;
    anyhow::ensure!(
        created.status.success(),
        "service creation failed: {} {}",
        String::from_utf8_lossy(&created.stdout),
        String::from_utf8_lossy(&created.stderr)
    );

    // Step 2: write the real binPath via registry. clap subcommands are
    // kebab-cased, so we MUST register "service-run" (not "ServiceRun") or
    // the binary will exit 0 on every start and the tray will see nothing.
    let real_binpath = format!("\"{}\" service-run", exe.display());
    #[cfg(windows)]
    write_service_image_path(&real_binpath).context("write ImagePath in registry")?;
    // On non-Windows this line is never reached (the sc.exe calls above already
    // error out); keep a use of `real_binpath` so the dev-host build is clean.
    #[cfg(not(windows))]
    let _ = &real_binpath;

    // Description (cosmetic; sc.exe handles this one fine).
    let _ = tokio::process::Command::new("sc.exe")
        .args([
            "description",
            "TorVPN",
            "Tor-routed VPN daemon (torvpn-svc)",
        ])
        .status()
        .await;

    // Auto-recovery: three restarts at 5s intervals after a crash.
    let _ = tokio::process::Command::new("sc.exe")
        .args([
            "failure",
            "TorVPN",
            "reset=",
            "60",
            "actions=",
            "restart/5000/restart/5000/restart/5000",
        ])
        .status()
        .await;

    // Now start it.
    let started = tokio::process::Command::new("sc.exe")
        .args(["start", "TorVPN"])
        .output()
        .await
        .context("sc.exe start")?;
    anyhow::ensure!(
        started.status.success(),
        "service start failed: {} {}",
        String::from_utf8_lossy(&started.stdout),
        String::from_utf8_lossy(&started.stderr)
    );

    println!("Registered service 'TorVPN'; waiting for its API.");
    println!("  binPath: {real_binpath}");

    // `sc.exe start` returning is NOT proof the control server is up —
    // verified the hard way (Round 10 assumed it blocked until Running;
    // it didn't reliably in practice, and crash-recovery teardown alone
    // took 23s in one real run here, well past what `sc start` waited for).
    // Rather than guess at another timing number, poll the one fact that
    // actually matters: can something connect to the configured address yet.
    let listen = match config::load_or_default(profile_path).await {
        Ok(cfg) => cfg.status.listen,
        Err(_) => "127.0.0.1:8787".to_string(), // shipped default, best-effort fallback
    };
    print!("Waiting for the control server on {listen} ");
    use std::io::Write as _;
    let _ = std::io::stdout().flush();
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(240);
    loop {
        if let Ok(client) = api::Client::from_token_file(&listen, &paths::api_token_path()).await {
            if client.status().await.is_ok() {
                println!(" up.");
                break;
            }
        }
        if tokio::time::Instant::now() >= deadline {
            anyhow::bail!(
                "Control API did not become ready in 240s; see %ProgramData%\\torvpn\\svc.log"
            );
        }
        print!(".");
        let _ = std::io::stdout().flush();
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
    }
    Ok(())
}

/// Write the service's ImagePath value (== binPath) directly to the registry.
/// This sidesteps `sc.exe`'s quoting of paths-with-spaces, which is silently
/// broken under several PowerShell + cmd combinations. Requires admin (the
/// HKLM key is ACL'd for SYSTEM + Administrators).
#[cfg(windows)]
fn write_service_image_path(binpath: &str) -> Result<()> {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::System::Registry::{
        RegCloseKey, RegOpenKeyExW, RegSetValueExW, HKEY_LOCAL_MACHINE, KEY_SET_VALUE,
        REG_EXPAND_SZ,
    };

    let subkey: Vec<u16> = OsStr::new(r"SYSTEM\CurrentControlSet\Services\TorVPN")
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let value_name: Vec<u16> = OsStr::new("ImagePath")
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let value_data: Vec<u16> = OsStr::new(binpath)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let value_bytes: &[u8] = unsafe {
        std::slice::from_raw_parts(value_data.as_ptr() as *const u8, value_data.len() * 2)
    };

    unsafe {
        let mut hkey = std::ptr::null_mut();
        let rc = RegOpenKeyExW(
            HKEY_LOCAL_MACHINE,
            subkey.as_ptr(),
            0,
            KEY_SET_VALUE,
            &mut hkey,
        );
        if rc != 0 {
            anyhow::bail!("RegOpenKeyExW failed: {rc} (need admin?)");
        }
        let rc = RegSetValueExW(
            hkey,
            value_name.as_ptr(),
            0,
            REG_EXPAND_SZ,
            value_bytes.as_ptr(),
            value_bytes.len() as u32,
        );
        RegCloseKey(hkey);
        if rc != 0 {
            anyhow::bail!("RegSetValueExW failed: {rc}");
        }
    }
    Ok(())
}

async fn service_uninstall() -> Result<()> {
    let _ = tokio::process::Command::new("sc.exe")
        .args(["stop", "TorVPN"])
        .status()
        .await;
    // sc stop returns as soon as STOP is signalled, but the service may still
    // be in STOP_PENDING when we try to delete. Give SCM a moment to settle
    // or `sc delete` returns "service marked for deletion" and the entry
    // sticks around until reboot.
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    tokio::process::Command::new("sc.exe")
        .args(["delete", "TorVPN"])
        .status()
        .await?;
    println!("Uninstalled service 'TorVPN'.");
    Ok(())
}

/// Used by the service to start the control server with an empty engagement.
/// Public so `service.rs` can call it.
///
/// `ready` flips to `true` once the control server's TCP listener is
/// confirmed bound (or immediately, if the control server is disabled in
/// config) — `service.rs` polls it and only reports `ServiceState::Running`
/// to the SCM once it's true. Without this, the SCM (and anyone scripting
/// `sc start` immediately followed by a CLI `connect`) could observe
/// "Running" well before anything was actually listening on 127.0.0.1:8787 —
/// crash-recovery teardown alone launches three sequential `powershell.exe`
/// processes before the listener ever binds, which is easily a multi-second
/// window on a cold Defender-scanned invocation.
#[cfg(windows)]
pub(crate) async fn serve_forever(
    stop_signal: std::sync::Arc<std::sync::atomic::AtomicBool>,
    ready: std::sync::Arc<std::sync::atomic::AtomicBool>,
) -> Result<()> {
    let cfg_path = paths::config_path();
    let cfg = if cfg_path.exists() {
        config::load_or_default(Some(&cfg_path)).await?
    } else {
        config::load_or_default(None).await?
    };
    let state_dir = paths::state_dir();
    tokio::fs::create_dir_all(&state_dir).await?;

    torvpn_core::config::validate(&cfg)?;
    // Recover before accepting another connect. Errors are fatal, visible in
    // svc.log and SCM; Running must never mean a server that failed to bind.
    torvpn_core::state::teardown_env(&state_dir).await?;
    let engagement = Engagement::new(paths::state_file());
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
    let cfg2 = cfg.clone();
    let sd2 = state_dir.clone();
    let eng2 = engagement.clone();
    let mut server =
        tokio::spawn(async move { control_server::run(cfg2, sd2, eng2, Some(ready_tx)).await });
    tokio::time::timeout(std::time::Duration::from_secs(15), ready_rx)
        .await
        .context("control listener readiness timed out")?
        .context("control listener failed before becoming ready")?;
    ready.store(true, std::sync::atomic::Ordering::SeqCst);
    log::info!("[service] control server ready");
    let eng_start = engagement.clone();
    let cfg_start = cfg.clone();
    let sd_start = state_dir.clone();
    let auto = tokio::spawn(async move {
        if cfg_start.startup.auto_connect {
            if let Err(e) = eng_start.connect(&cfg_start, &sd_start).await {
                log::error!("[service] automatic connect failed: {e:#}");
            }
        }
    });
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(2));
    loop {
        tokio::select! {
            result = &mut server => {
                auto.abort();
                let _ = engagement.disconnect(&state_dir).await;
                result.context("control task panicked")??;
                anyhow::bail!("control server stopped unexpectedly");
            }
            _ = interval.tick() => {
                if stop_signal.load(std::sync::atomic::Ordering::SeqCst) { break; }
                engagement.health_tick().await;
                if engagement.current().await.phase == torvpn_core::state::Phase::Engaged {
                    // Hop plans are optional. Failures are visible, never silently discarded.
                    if let Err(e) = torvpn_core::hop_plan::maybe_tick(&cfg, &state_dir).await {
                        log::warn!("hop plan: {e:#}");
                    }
                }
            }
        }
    }
    // Disconnect requests cancellation of bootstrap before waiting on its lock.
    let result = engagement.disconnect(&state_dir).await;
    auto.abort();
    let _ = auto.await;
    server.abort();
    let _ = server.await;
    result
}
