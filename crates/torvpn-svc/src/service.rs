//! Windows SCM service dispatcher.
//!
//! The service:
//!   - Registers a control handler that flips a stop flag on `Stop`.
//!   - Reports `StartPending` (with checkpoints) while `serve_forever` runs
//!     crash-recovery teardown and binds the control server's listener, then
//!     `Running` only once that's confirmed — NOT the instant the process
//!     starts. See `serve_forever`'s doc comment in `main.rs` for why: the
//!     old "Running immediately" version let `sc start` return, and thus let
//!     a scripted `connect` right after it run, several seconds before
//!     anything was actually listening on 127.0.0.1:8787.
//!   - Idles until SCM tells us to stop.
//!   - On stop: gracefully disengages, then reports `Stopped` to SCM.
//!
//! `windows-service` 0.7 requires the SCM entry point to be an
//! `extern "system" fn(u32, *mut *mut u16)`. We generate that via the
//! `define_windows_service!` macro, which wraps a normal Rust fn taking
//! `Vec<OsString>`.

use anyhow::Result;
use std::ffi::OsString;
use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
use std::time::Duration;
use tokio::runtime::Runtime;
use windows_service::define_windows_service;
use windows_service::service::*;
use windows_service::service_control_handler::{self, ServiceControlHandlerResult};
use windows_service::service_dispatcher;

const SERVICE_NAME: &str = "TorVPN";
const SERVICE_TYPE: ServiceType = ServiceType::OWN_PROCESS;

// Macro expands into:
//     extern "system" fn ffi_service_main(argc: u32, argv: *mut *mut u16) { ... }
// which is what service_dispatcher::start wants. The macro forwards to
// `service_main_rust` with arguments already parsed into Vec<OsString>.
define_windows_service!(ffi_service_main, service_main_rust);

pub fn run_service_dispatcher() -> Result<()> {
    service_dispatcher::start(SERVICE_NAME, ffi_service_main)?;
    Ok(())
}

fn service_main_rust(_arguments: Vec<OsString>) {
    if let Err(e) = service_main() {
        eprintln!("[service] fatal: {e:?}");
    }
}

fn service_main() -> Result<()> {
    let stop = Arc::new(AtomicBool::new(false));
    let stop_for_handler = stop.clone();

    let status_handle = service_control_handler::register(SERVICE_NAME, move |evt| match evt {
        ServiceControl::Stop | ServiceControl::Shutdown => {
            stop_for_handler.store(true, Ordering::SeqCst);
            ServiceControlHandlerResult::NoError
        }
        ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
        _ => ServiceControlHandlerResult::NotImplemented,
    })?;

    // StartPending, not Running, until `serve_forever` confirms the control
    // server's listener is actually bound. `wait_hint` + rising `checkpoint`
    // is how a Windows service tells the SCM "still starting, don't give up
    // on me yet" instead of going straight to a state that invites a `sc
    // start`-then-`connect` script to race a listener that isn't there yet.
    status_handle.set_service_status(ServiceStatus {
        service_type:        SERVICE_TYPE,
        current_state:       ServiceState::StartPending,
        controls_accepted:   ServiceControlAccept::empty(),
        exit_code:           ServiceExitCode::Win32(0),
        checkpoint:          0,
        wait_hint:           Duration::from_secs(20),
        process_id:          None,
    })?;

    let rt = Runtime::new()?;
    let ready = Arc::new(AtomicBool::new(false));
    let ready_for_task = ready.clone();
    let stop_for_task = stop.clone();

    rt.block_on(async move {
        let handle = tokio::spawn(async move {
            if let Err(e) = crate::serve_forever(stop_for_task, ready_for_task).await {
                log::error!("[service] serve_forever: {e:?}");
            }
        });

        // Poll readiness, nudging the SCM checkpoint every 200ms so it never
        // times out on us mid-startup. ~20s safety cap matches serve_forever's
        // own 15s bind timeout plus slack — if we hit it, something's
        // genuinely wrong (see svc.log), but we still flip to Running rather
        // than hang the SCM forever on a service that IS alive, just stuck.
        let mut checkpoint: u32 = 0;
        while !ready.load(Ordering::SeqCst) && checkpoint < 100 {
            checkpoint += 1;
            let _ = status_handle.set_service_status(ServiceStatus {
                service_type:      SERVICE_TYPE,
                current_state:     ServiceState::StartPending,
                controls_accepted: ServiceControlAccept::empty(),
                exit_code:         ServiceExitCode::Win32(0),
                checkpoint,
                wait_hint:         Duration::from_secs(2),
                process_id:        None,
            });
            tokio::time::sleep(Duration::from_millis(200)).await;
        }

        let _ = status_handle.set_service_status(ServiceStatus {
            service_type:        SERVICE_TYPE,
            current_state:       ServiceState::Running,
            controls_accepted:   ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
            exit_code:           ServiceExitCode::Win32(0),
            checkpoint:          0,
            wait_hint:           Duration::from_secs(5),
            process_id:          None,
        });

        let _ = handle.await;
    });

    status_handle.set_service_status(ServiceStatus {
        service_type:        SERVICE_TYPE,
        current_state:       ServiceState::Stopped,
        controls_accepted:   ServiceControlAccept::empty(),
        exit_code:           ServiceExitCode::Win32(0),
        checkpoint:          0,
        wait_hint:           Duration::from_secs(0),
        process_id:          None,
    })?;
    Ok(())
}
