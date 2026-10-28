use std::ffi::OsString;
use std::os::windows::ffi::OsStringExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::Duration;

use serde_json::Value;
use tokio::net::windows::named_pipe::ClientOptions;
use windows_sys::Win32::Foundation::{ERROR_NO_MORE_FILES, ERROR_PIPE_BUSY, INVALID_HANDLE_VALUE};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows_sys::Win32::System::Pipes::GetNamedPipeServerProcessId;

use super::{
    AppControlError, AppResult, AppTransport, encode_request, exchange, verify_server_pid,
};

pub(crate) fn list_instances() -> AppResult<Vec<u32>> {
    // SAFETY: This API has no pointer inputs and returns an owned snapshot handle.
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err(AppControlError::new(
            "app_discovery_failed",
            "Could not enumerate Windows app processes",
        ));
    }
    // SAFETY: A successful snapshot is a uniquely owned, CloseHandle-compatible handle.
    let snapshot = unsafe { OwnedHandle::from_raw_handle(snapshot) };
    let mut entry = PROCESSENTRY32W {
        dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
        ..Default::default()
    };
    let mut instances = Vec::new();
    // SAFETY: The snapshot remains alive and entry is a correctly sized writable structure.
    let mut found = unsafe { Process32FirstW(snapshot.as_raw_handle(), &mut entry) };
    loop {
        if found == 0 {
            if std::io::Error::last_os_error().raw_os_error() == Some(ERROR_NO_MORE_FILES as i32) {
                break;
            }
            return Err(AppControlError::new(
                "app_discovery_failed",
                "Windows process enumeration did not complete",
            ));
        }
        let end = entry
            .szExeFile
            .iter()
            .position(|c| *c == 0)
            .unwrap_or(entry.szExeFile.len());
        let name = OsString::from_wide(&entry.szExeFile[..end]);
        if entry.th32ProcessID != 0
            && name
                .to_string_lossy()
                .eq_ignore_ascii_case("Skybridge.WinClient.exe")
        {
            instances.push(entry.th32ProcessID);
            if instances.len() > 128 {
                return Err(AppControlError::new(
                    "app_instance_limit",
                    "Too many SkyBridge app instances are running",
                ));
            }
        }
        // SAFETY: The snapshot and correctly sized writable entry remain valid throughout iteration.
        found = unsafe { Process32NextW(snapshot.as_raw_handle(), &mut entry) };
    }
    instances.sort_unstable();
    instances.dedup();
    Ok(instances)
}

pub(crate) struct AppClient {
    pid: u32,
    mutation_attempted: Arc<AtomicBool>,
}

impl AppClient {
    pub(crate) fn new(pid: u32, mutation_attempted: Arc<AtomicBool>) -> Self {
        Self {
            pid,
            mutation_attempted,
        }
    }
}

impl AppTransport for AppClient {
    async fn call(&mut self, method: &'static str, params: Value) -> AppResult<Value> {
        let id = uuid::Uuid::new_v4().hyphenated().to_string();
        let request = encode_request(&id, method, params)?;
        let name = format!(r"\\.\pipe\SkyBridge.OperatorControl.v1.{}", self.pid);
        let mut pipe = loop {
            // Tokio defaults to SECURITY_IDENTIFICATION, preventing server impersonation
            // of this client. Do not override the default security_qos_flags.
            match ClientOptions::new().open(&name) {
                Ok(pipe) => break pipe,
                Err(error) if error.raw_os_error() == Some(ERROR_PIPE_BUSY as i32) => {
                    // Retry only an unopened, unwritten connection, within the command deadline.
                    tokio::time::sleep(Duration::from_millis(25)).await;
                }
                Err(_) => {
                    return Err(AppControlError::new(
                        "app_pipe_unavailable",
                        "The selected app's operator pipe is unavailable",
                    ));
                }
            }
        };
        let mut server_pid = 0;
        // SAFETY: pipe owns a live named-pipe handle and server_pid is writable u32 storage.
        if unsafe { GetNamedPipeServerProcessId(pipe.as_raw_handle(), &mut server_pid) } == 0 {
            return Err(AppControlError::new(
                "app_pipe_identity_unavailable",
                "Could not verify the operator pipe's server process",
            ));
        }
        verify_server_pid(self.pid, server_pid)?;
        if matches!(
            method,
            "app.settings.set" | "app.remote_desktop.start" | "app.remote_desktop.stop"
        ) {
            self.mutation_attempted.store(true, Ordering::Release);
        }
        // There is deliberately no retry after any request bytes may have been written.
        exchange(&mut pipe, &id, &request).await
    }
}
