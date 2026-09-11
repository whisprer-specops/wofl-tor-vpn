//! Windows SCM service dispatcher.
//!
//! The service:
//!   - Registers a control handler that flips a stop flag on `Stop`.
//!   - Sets state to `Running` immediately (control server can serve /status).
//!   - Idles in `serve_forever` until SCM tells us to stop.
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

    status_handle.set_service_status(ServiceStatus {
        service_type:        SERVICE_TYPE,
        current_state:       ServiceState::Running,
        controls_accepted:   ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
        exit_code:           ServiceExitCode::Win32(0),
        checkpoint:          0,
        wait_hint:           Duration::from_secs(5),
        process_id:          None,
    })?;

    let rt = Runtime::new()?;
    rt.block_on(async {
        if let Err(e) = crate::serve_forever(stop.clone()).await {
            log::error!("[service] serve_forever: {e:?}");
        }
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
