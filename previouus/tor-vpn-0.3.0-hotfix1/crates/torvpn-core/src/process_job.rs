//! Windows closes the owned job handle on service death, killing its children
//! even when Rust destructors do not run (crash, forced service termination).
use anyhow::{Context, Result};
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
pub(crate) struct Job {
    _handle: OwnedHandle,
}
impl Job {
    pub(crate) fn for_child(child: &tokio::process::Child) -> Result<Self> {
        // All handles are checked and immediately adopted into OwnedHandle;
        // the information buffer lives for the synchronous Win32 call.
        unsafe {
            let raw = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            anyhow::ensure!(
                !raw.is_null(),
                "CreateJobObjectW: {}",
                std::io::Error::last_os_error()
            );
            let handle = OwnedHandle::from_raw_handle(raw);
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if SetInformationJobObject(
                handle.as_raw_handle(),
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const _,
                std::mem::size_of_val(&info) as u32,
            ) == 0
            {
                return Err(std::io::Error::last_os_error()).context("configure child job");
            }
            // Borrow the exact process handle rather than reopening a PID,
            // which could be recycled if a child exits immediately.
            let raw_child = child.raw_handle().context("child process has no handle")?;
            if AssignProcessToJobObject(handle.as_raw_handle(), raw_child) == 0 {
                return Err(std::io::Error::last_os_error()).context("assign owned child to job");
            }
            Ok(Self { _handle: handle })
        }
    }
}
