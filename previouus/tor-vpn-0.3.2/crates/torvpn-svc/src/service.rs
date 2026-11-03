//! Windows SCM lifecycle; Running means the authenticated control API is ready.
use anyhow::{Context, Result};
use std::{
    ffi::OsString,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use windows_service::{
    define_windows_service,
    service::*,
    service_control_handler::{self, ServiceControlHandlerResult},
    service_dispatcher,
};
const NAME: &str = "TorVPN";
define_windows_service!(ffi_main, service_main_rust);
pub fn run_service_dispatcher() -> Result<()> {
    service_dispatcher::start(NAME, ffi_main)?;
    Ok(())
}
fn service_main_rust(_: Vec<OsString>) {
    if let Err(e) = service_main() {
        log::error!("SCM service failed: {e:#}");
    }
}
fn service_main() -> Result<()> {
    let stop = Arc::new(AtomicBool::new(false));
    let handler_stop = stop.clone();
    let status = service_control_handler::register(NAME, move |event| match event {
        ServiceControl::Stop | ServiceControl::Shutdown => {
            handler_stop.store(true, Ordering::SeqCst);
            ServiceControlHandlerResult::NoError
        }
        ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
        _ => ServiceControlHandlerResult::NotImplemented,
    })?;
    let report = |state, checkpoint, code| -> windows_service::Result<()> {
        status.set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: state,
            controls_accepted: if state == ServiceState::Running {
                ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN
            } else {
                ServiceControlAccept::empty()
            },
            exit_code: ServiceExitCode::Win32(code),
            checkpoint,
            wait_hint: Duration::from_secs(10),
            process_id: None,
        })
    };
    report(ServiceState::StartPending, 1, 0)?;
    let rt = tokio::runtime::Runtime::new()?;
    let ready = Arc::new(AtomicBool::new(false));
    let result = rt.block_on(async {
        let ready_worker = ready.clone();
        let stop_worker = stop.clone();
        let mut worker =
            tokio::spawn(async move { crate::serve_forever(stop_worker, ready_worker).await });
        let start = tokio::time::Instant::now();
        let mut checkpoint = 1;
        while !ready.load(Ordering::SeqCst) {
            if worker.is_finished() {
                return worker.await.context("service startup task panicked")?;
            }
            if start.elapsed() > Duration::from_secs(600) {
                worker.abort();
                anyhow::bail!("service recovery/startup exceeded 600s; see svc.log");
            }
            checkpoint += 1;
            report(ServiceState::StartPending, checkpoint, 0)?;
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        report(ServiceState::Running, 0, 0)?;
        loop {
            tokio::select! {
                result = &mut worker => return result.context("service worker panicked")?,
                _ = tokio::time::sleep(Duration::from_millis(250)) => {
                    if stop.load(Ordering::SeqCst) {
                        checkpoint += 1;
                        report(ServiceState::StopPending, checkpoint, 0)?;
                    }
                }
            }
        }
    });
    report(ServiceState::Stopped, 0, if result.is_ok() { 0 } else { 1 })?;
    result
}
