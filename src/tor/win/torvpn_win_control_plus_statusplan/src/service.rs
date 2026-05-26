use anyhow::Result;
use windows_service::service::*;
use windows_service::service_control_handler::{self, ServiceControlHandlerResult};
use windows_service::service_dispatcher;
use std::ffi::OsString;
use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
use tokio::runtime::Runtime;
use crate::config;
use crate::{firewall, nrpt, tor_manager, tun2socks_manager};

static SERVICE_NAME: &str = "TorVPN";
static SERVICE_TYPE: ServiceType = ServiceType::OWN_PROCESS;

pub fn run_service_dispatcher() -> Result<()> {
    service_dispatcher::start(SERVICE_NAME, ffi_service_main)?;
    Ok(())
}

fn ffi_service_main(_arguments: Vec<OsString>) {
    if let Err(e) = service_main() {
        eprintln!("[service] fatal: {:?}", e);
    }
}

fn service_main() -> Result<()> {
    let running = Arc::new(AtomicBool::new(true));
    let r2 = running.clone();

    let status_handle = service_control_handler::register(SERVICE_NAME, move |control_event| {
        match control_event {
            ServiceControl::Stop | ServiceControl::Interrogate => {
                r2.store(false, Ordering::SeqCst);
                ServiceControlHandlerResult::NoError
            }
            _ => ServiceControlHandlerResult::NotImplemented,
        }
    })?;

    let rt = Runtime::new()?;
    status_handle.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Running,
        controls_accepted: ServiceControlAccept::STOP,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: std::time::Duration::from_secs(10),
        process_id: None,
    })?;

    rt.block_on(async move {
        let state_dir = dirs::data_local_dir().unwrap_or_else(|| std::path::PathBuf::from(r"C:\ProgramData\torvpn"));
        let cfg = match config::load_or_default(None).await {
            Ok(c) => c,
            Err(e) => { eprintln!("[service] config load failed: {e:?}"); return; }
        };

        // start status server
        let _ = crate::status_server::run(cfg.clone(), state_dir.clone()).await;

        // Service daemon loop
        if cfg.status.enabled { let _ = tokio::spawn(crate::status::run(cfg.clone(), state_dir.clone())); }
            while running.load(Ordering::SeqCst) {
            // Apply protections
            if let Err(e) = nrpt::apply_dns_lock(&cfg).await { eprintln!("[service] dns lock: {e:?}"); }
            if let Err(e) = firewall::apply_rules(&cfg).await { eprintln!("[service] firewall: {e:?}"); }

            // Start Tor
            let tor = match tor_manager::TorInstance::start(&cfg, &state_dir).await {
                Ok(t) => t,
                Err(e) => { eprintln!("[service] tor start failed: {e:?}"); break; }
            };

            // Start tun2socks
            let t2s = match tun2socks_manager::Tun2Socks::start(&cfg).await {
                Ok(t) => Some(t),
                Err(e) => { eprintln!("[service] tun2socks start failed: {e:?}"); None }
            };

            // Health loop (poll Tor control)
            for _ in 0..3600 {
                if !running.load(Ordering::SeqCst) { break; }
                let cookie = state_dir.join("tor-data").join("control_auth_cookie");
                let addr = format!("127.0.0.1:{}", cfg.tor.control_port);
                let _ = crate::hop_plan::maybe_tick(&cfg, &state_dir).await;
                match crate::tor_control::TorControl::connect(&addr, &cookie).await {
                    Ok(_) => { /* healthy */ }
                    Err(e) => {
                        eprintln!("[service] control failed: {e:?}; restarting components...");
                        break;
                    }
                }
                tokio::time::sleep(std::time::Duration::from_secs(10)).await;
            }

            // Teardown for restart or stop
            let _ = tokio::process::Command::new("taskkill").args(["/IM","tun2socks.exe","/F"]).status().await;
            let _ = tokio::process::Command::new("taskkill").args(["/IM","tor.exe","/F"]).status().await;
            let _ = nrpt::teardown_dns_lock().await;
            let _ = firewall::teardown_rules().await;
        }
    });

    status_handle.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Stopped,
        controls_accepted: ServiceControlAccept::empty(),
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: std::time::Duration::from_secs(0),
        process_id: None,
    })?;
    Ok(())
}
