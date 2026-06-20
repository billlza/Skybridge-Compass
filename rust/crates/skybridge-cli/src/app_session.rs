//! `skybridge app` — cross-platform SkyBridge GUI app lifecycle control.
//!
//! Headline capability (Windows): `app launch --interactive` binds the launch
//! to the *active interactive console session* via the WTS/CreateProcessAsUserW
//! path, so a GUI surfaces on the logged-in user's desktop even when this CLI is
//! invoked from a service or as SYSTEM (where a plain `CreateProcessW` would land
//! in session 0 with no visible window). On macOS/unix `--interactive` is a no-op
//! and launch is a normal `spawn` (with `.app` bundles delegated to `open`).
//!
//! The arg-validation and JSON-assembly layers are deliberately platform-neutral
//! and unit-tested; only the actual OS syscalls are `cfg`-gated.

use std::path::PathBuf;

use anyhow::{Result, bail};
use serde::Serialize;
use serde_json::json;

use crate::{AppLaunchArgs, AppStatusArgs, AppStopArgs};

// ---------------------------------------------------------------------------
// Platform-neutral request/outcome types (unit-tested)
// ---------------------------------------------------------------------------

/// A validated launch request, independent of the OS backend.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LaunchRequest {
    pub(crate) exe: PathBuf,
    pub(crate) cwd: Option<PathBuf>,
    pub(crate) args: Vec<String>,
    pub(crate) interactive: bool,
}

impl LaunchRequest {
    fn from_args(args: &AppLaunchArgs) -> Result<Self> {
        if args.exe.as_os_str().is_empty() {
            bail!("--exe must not be empty");
        }
        Ok(Self {
            exe: args.exe.clone(),
            cwd: args.cwd.clone(),
            args: args.args.clone(),
            interactive: args.interactive,
        })
    }
}

/// Result of a launch attempt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LaunchOutcome {
    pub(crate) pid: u32,
    /// Active console session id (Windows interactive launch only); `None` elsewhere.
    pub(crate) session: Option<u32>,
    pub(crate) interactive: bool,
}

/// How `stop`/`status` identify the target process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ProcessSelector {
    Pid(u32),
    Name(String),
}

impl ProcessSelector {
    /// Enforce "exactly one of --pid / --name".
    fn from_pid_name(pid: Option<u32>, name: Option<String>) -> Result<Self> {
        match (pid, name) {
            (Some(_), Some(_)) => bail!("specify exactly one of --pid or --name, not both"),
            (None, None) => bail!("specify exactly one of --pid or --name"),
            (Some(pid), None) => {
                if pid == 0 {
                    bail!("--pid must be a non-zero process id");
                }
                Ok(ProcessSelector::Pid(pid))
            }
            (None, Some(name)) => {
                if name.trim().is_empty() {
                    bail!("--name must not be empty");
                }
                Ok(ProcessSelector::Name(name))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Command entrypoints (called from cli_dispatch)
// ---------------------------------------------------------------------------

pub(crate) fn launch(args: AppLaunchArgs) -> Result<()> {
    let as_json = args.output.json;
    let request = LaunchRequest::from_args(&args)?;
    let outcome = backend::launch(&request)?;
    print_launch(&request, &outcome, as_json)
}

pub(crate) fn stop(args: AppStopArgs) -> Result<()> {
    let as_json = args.output.json;
    let force = args.force;
    let selector = ProcessSelector::from_pid_name(args.pid, args.name)?;
    let stopped = backend::stop(&selector, force)?;
    print_stop(&selector, &stopped, force, as_json)
}

pub(crate) fn status(args: AppStatusArgs) -> Result<()> {
    let as_json = args.output.json;
    let selector = ProcessSelector::from_pid_name(args.pid, args.name)?;
    let snapshot = backend::status(&selector)?;
    print_status(&selector, &snapshot, as_json)
}

// ---------------------------------------------------------------------------
// Backend outcome value-objects shared by both platforms
// ---------------------------------------------------------------------------

/// Result of a stop request: the pids that were signalled/terminated.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct StopOutcome {
    pub(crate) pids: Vec<u32>,
}

/// Result of a status query.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct StatusSnapshot {
    pub(crate) pids: Vec<u32>,
}

// ---------------------------------------------------------------------------
// JSON / text presentation (platform-neutral, unit-tested)
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
struct LaunchJson {
    launched: bool,
    pid: u32,
    session: Option<u32>,
    exe: String,
    interactive: bool,
}

fn launch_json(request: &LaunchRequest, outcome: &LaunchOutcome) -> LaunchJson {
    LaunchJson {
        launched: true,
        pid: outcome.pid,
        session: outcome.session,
        exe: request.exe.display().to_string(),
        interactive: outcome.interactive,
    }
}

fn print_launch(request: &LaunchRequest, outcome: &LaunchOutcome, as_json: bool) -> Result<()> {
    let payload = launch_json(request, outcome);
    if as_json {
        println!("{}", serde_json::to_string_pretty(&json!(payload))?);
    } else {
        println!("Launched: {}", payload.exe);
        println!("PID: {}", payload.pid);
        println!(
            "Session: {}",
            payload
                .session
                .map(|s| s.to_string())
                .unwrap_or_else(|| "n/a".to_owned())
        );
        println!("Interactive: {}", payload.interactive);
    }
    Ok(())
}

fn selector_name(selector: &ProcessSelector) -> Option<&str> {
    match selector {
        ProcessSelector::Name(name) => Some(name.as_str()),
        ProcessSelector::Pid(_) => None,
    }
}

fn print_stop(
    selector: &ProcessSelector,
    outcome: &StopOutcome,
    force: bool,
    as_json: bool,
) -> Result<()> {
    let stopped = !outcome.pids.is_empty();
    let primary_pid = outcome.pids.first().copied();
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "stopped": stopped,
                "pid": primary_pid,
                "pids": outcome.pids,
                "name": selector_name(selector),
                "force": force,
            }))?
        );
    } else if stopped {
        println!(
            "Stopped pid(s): {}",
            outcome
                .pids
                .iter()
                .map(u32::to_string)
                .collect::<Vec<_>>()
                .join(", ")
        );
    } else {
        println!("No matching process to stop");
    }
    Ok(())
}

fn print_status(
    selector: &ProcessSelector,
    snapshot: &StatusSnapshot,
    as_json: bool,
) -> Result<()> {
    let running = !snapshot.pids.is_empty();
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "running": running,
                "pids": snapshot.pids,
                "name": selector_name(selector),
            }))?
        );
    } else {
        println!("Running: {running}");
        println!(
            "PIDs: {}",
            if snapshot.pids.is_empty() {
                "none".to_owned()
            } else {
                snapshot
                    .pids
                    .iter()
                    .map(u32::to_string)
                    .collect::<Vec<_>>()
                    .join(", ")
            }
        );
    }
    Ok(())
}

// ===========================================================================
// Unix / macOS backend
// ===========================================================================
#[cfg(unix)]
mod backend {
    use std::process::Command;

    use anyhow::{Context, Result, bail};

    use super::{LaunchOutcome, LaunchRequest, ProcessSelector, StatusSnapshot, StopOutcome};

    /// Launch the app. `.app` bundles are delegated to `open` so LaunchServices
    /// brings the GUI up properly; everything else is a direct `spawn`.
    /// `interactive` is a no-op on unix (session-binding is a Windows concept).
    pub(super) fn launch(request: &LaunchRequest) -> Result<LaunchOutcome> {
        let is_app_bundle = request
            .exe
            .extension()
            .and_then(|ext| ext.to_str())
            .map(|ext| ext.eq_ignore_ascii_case("app"))
            .unwrap_or(false);

        let pid = if is_app_bundle {
            launch_app_bundle(request)?
        } else {
            launch_executable(request)?
        };

        Ok(LaunchOutcome {
            pid,
            session: None,
            interactive: false,
        })
    }

    fn launch_executable(request: &LaunchRequest) -> Result<u32> {
        let mut command = Command::new(&request.exe);
        command.args(&request.args);
        if let Some(cwd) = request.cwd.as_ref() {
            command.current_dir(cwd);
        }
        let child = command.spawn().with_context(|| {
            format!("failed to spawn {}", request.exe.display())
        })?;
        Ok(child.id())
    }

    /// macOS `.app` bundle: `open -a <bundle> [--args ...]`.
    /// `open` exits immediately; the spawned GUI pid is not its child, so we
    /// resolve it by bundle name afterwards (best-effort, may be 0 if it
    /// daemonized under a different process name).
    fn launch_app_bundle(request: &LaunchRequest) -> Result<u32> {
        let mut command = Command::new("open");
        command.arg("-a").arg(&request.exe);
        if let Some(cwd) = request.cwd.as_ref() {
            command.current_dir(cwd);
        }
        if !request.args.is_empty() {
            command.arg("--args");
            command.args(&request.args);
        }
        let status = command
            .status()
            .with_context(|| format!("failed to run `open -a {}`", request.exe.display()))?;
        if !status.success() {
            bail!("`open` failed with status {status}");
        }
        // Best-effort pid resolution by bundle stem.
        let stem = request
            .exe
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("");
        Ok(pids_for_name(stem).first().copied().unwrap_or(0))
    }

    pub(super) fn stop(selector: &ProcessSelector, force: bool) -> Result<StopOutcome> {
        let pids = resolve_pids(selector);
        let signal = if force { "KILL" } else { "TERM" };
        let mut stopped = Vec::new();
        for pid in pids {
            if send_signal(pid, signal)? {
                stopped.push(pid);
            }
        }
        Ok(StopOutcome { pids: stopped })
    }

    pub(super) fn status(selector: &ProcessSelector) -> Result<StatusSnapshot> {
        let pids = match selector {
            ProcessSelector::Pid(pid) => {
                if pid_is_alive(*pid) {
                    vec![*pid]
                } else {
                    Vec::new()
                }
            }
            ProcessSelector::Name(name) => pids_for_name(name),
        };
        Ok(StatusSnapshot { pids })
    }

    fn resolve_pids(selector: &ProcessSelector) -> Vec<u32> {
        match selector {
            ProcessSelector::Pid(pid) => vec![*pid],
            ProcessSelector::Name(name) => pids_for_name(name),
        }
    }

    /// Resolve a process name to pids via `pgrep -x` (exact match), falling back
    /// to `pgrep -f` (full command-line substring) when the exact match is empty.
    fn pids_for_name(name: &str) -> Vec<u32> {
        if name.trim().is_empty() {
            return Vec::new();
        }
        let exact = run_pgrep(&["-x", name]);
        if !exact.is_empty() {
            return exact;
        }
        run_pgrep(&["-f", name])
    }

    fn run_pgrep(args: &[&str]) -> Vec<u32> {
        let output = match Command::new("pgrep").args(args).output() {
            Ok(output) => output,
            Err(_) => return Vec::new(),
        };
        parse_pgrep_pids(&String::from_utf8_lossy(&output.stdout))
    }

    /// Parse newline/whitespace-separated pids emitted by `pgrep`.
    fn parse_pgrep_pids(stdout: &str) -> Vec<u32> {
        stdout
            .split_whitespace()
            .filter_map(|token| token.parse::<u32>().ok())
            .filter(|pid| *pid != 0)
            .collect()
    }

    /// Send `signal` (name, e.g. "TERM"/"KILL") to `pid` via `/bin/kill`.
    /// Returns true if kill reported success.
    fn send_signal(pid: u32, signal: &str) -> Result<bool> {
        let status = Command::new("kill")
            .arg(format!("-{signal}"))
            .arg(pid.to_string())
            .status()
            .with_context(|| format!("failed to invoke kill -{signal} {pid}"))?;
        Ok(status.success())
    }

    /// `kill -0 <pid>` probes existence without delivering a signal.
    fn pid_is_alive(pid: u32) -> bool {
        if pid == 0 {
            return false;
        }
        Command::new("kill")
            .arg("-0")
            .arg(pid.to_string())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn parse_pgrep_pids_handles_multiline_and_noise() {
            assert_eq!(parse_pgrep_pids("123\n456\n"), vec![123, 456]);
            assert_eq!(parse_pgrep_pids("  789  \n"), vec![789]);
            assert_eq!(parse_pgrep_pids(""), Vec::<u32>::new());
            assert_eq!(parse_pgrep_pids("not-a-pid\n0\n42"), vec![42]);
        }
    }
}

// ===========================================================================
// Windows backend
// ===========================================================================
//
// SAFETY / PRIVILEGE NOTE: `app launch --interactive` calls
// `WTSQueryUserToken`, which requires the SE_TCB privilege. In practice this
// means the CLI must run as LocalSystem (or an account holding "Act as part of
// the operating system"). When the privilege is missing, `WTSQueryUserToken`
// fails with ERROR_PRIVILEGE_NOT_HELD (1314) and we surface a clear message.
//
// This module is compiled only on Windows and therefore is NOT verified by the
// macOS CI build — it is hand-written against windows-sys 0.61 bindings and
// must be compiled/tested on a real Windows box.
#[cfg(windows)]
mod backend {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    use std::ptr;

    use anyhow::{Result, anyhow, bail};

    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, ERROR_PRIVILEGE_NOT_HELD, FALSE, HANDLE, INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::Security::{
        DuplicateTokenEx, SecurityImpersonation, TokenPrimary, SECURITY_IMPERSONATION_LEVEL,
        TOKEN_TYPE,
    };
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    use windows_sys::Win32::System::Environment::{CreateEnvironmentBlock, DestroyEnvironmentBlock};
    use windows_sys::Win32::System::RemoteDesktop::{
        WTSGetActiveConsoleSessionId, WTSQueryUserToken,
    };
    use windows_sys::Win32::System::Threading::{
        CreateProcessAsUserW, CreateProcessW, OpenProcess, TerminateProcess,
        CREATE_NEW_CONSOLE, CREATE_UNICODE_ENVIRONMENT, PROCESS_INFORMATION, PROCESS_TERMINATE,
        STARTUPINFOW,
    };

    use super::{LaunchOutcome, LaunchRequest, ProcessSelector, StatusSnapshot, StopOutcome};

    // MAXIMUM_ALLOWED lives in Win32_System_SystemServices; inline the literal so
    // the feature set stays minimal. (winnt.h: MAXIMUM_ALLOWED = 0x02000000)
    const MAXIMUM_ALLOWED: u32 = 0x0200_0000;
    // 0xFFFFFFFF return from WTSGetActiveConsoleSessionId == no active session.
    const NO_ACTIVE_SESSION: u32 = 0xFFFF_FFFF;

    /// Encode a Rust `&OsStr` as a NUL-terminated UTF-16 buffer for the W APIs.
    fn to_wide(value: &OsStr) -> Vec<u16> {
        value.encode_wide().chain(std::iter::once(0)).collect()
    }

    /// Build a quoted command line: `"<exe>" arg arg ...`. The first token must be
    /// the program path (CreateProcess convention when lpApplicationName is set we
    /// still pass argv[0] for the child's GetCommandLine()).
    fn build_command_line(request: &LaunchRequest) -> Vec<u16> {
        let mut line = String::new();
        line.push('"');
        line.push_str(&request.exe.to_string_lossy());
        line.push('"');
        for arg in &request.args {
            line.push(' ');
            line.push('"');
            line.push_str(&arg.replace('"', "\\\""));
            line.push('"');
        }
        to_wide(OsStr::new(&line))
    }

    /// RAII guard so handles are always closed, even on early returns.
    struct OwnedHandle(HANDLE);
    impl OwnedHandle {
        fn is_valid(&self) -> bool {
            !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE
        }
    }
    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            if self.is_valid() {
                unsafe { CloseHandle(self.0) };
            }
        }
    }

    pub(super) fn launch(request: &LaunchRequest) -> Result<LaunchOutcome> {
        if request.interactive {
            launch_interactive(request)
        } else {
            launch_plain(request)
        }
    }

    /// Non-interactive launch: a normal `CreateProcessW` in the caller's session.
    fn launch_plain(request: &LaunchRequest) -> Result<LaunchOutcome> {
        let exe_wide = to_wide(request.exe.as_os_str());
        let mut cmdline = build_command_line(request);
        let cwd_wide = request.cwd.as_ref().map(|cwd| to_wide(cwd.as_os_str()));
        let cwd_ptr = cwd_wide
            .as_ref()
            .map(|buf| buf.as_ptr())
            .unwrap_or(ptr::null());

        let mut startup: STARTUPINFOW = unsafe { std::mem::zeroed() };
        startup.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        let mut info: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };

        let ok = unsafe {
            CreateProcessW(
                exe_wide.as_ptr(),
                cmdline.as_mut_ptr(),
                ptr::null(),
                ptr::null(),
                FALSE,
                CREATE_NEW_CONSOLE,
                ptr::null(),
                cwd_ptr,
                &startup,
                &mut info,
            )
        };
        if ok == 0 {
            let err = unsafe { GetLastError() };
            bail!(
                "CreateProcessW failed for {} (GetLastError={err})",
                request.exe.display()
            );
        }
        // We don't need the process/thread handles; close them to avoid leaks.
        let _process = OwnedHandle(info.hProcess);
        let _thread = OwnedHandle(info.hThread);
        Ok(LaunchOutcome {
            pid: info.dwProcessId,
            session: None,
            interactive: false,
        })
    }

    /// Interactive launch: bind the active console session and start the GUI on
    /// the logged-in user's desktop. Requires SE_TCB (run as SYSTEM/admin).
    fn launch_interactive(request: &LaunchRequest) -> Result<LaunchOutcome> {
        // 1. Find the active console session.
        let session_id = unsafe { WTSGetActiveConsoleSessionId() };
        if session_id == NO_ACTIVE_SESSION {
            bail!(
                "no active interactive console session \
                 (WTSGetActiveConsoleSessionId returned 0xFFFFFFFF) — \
                 is anyone logged in at the console?"
            );
        }

        // 2. Get the user token for that session (needs SE_TCB).
        let mut raw_token: HANDLE = ptr::null_mut();
        let ok = unsafe { WTSQueryUserToken(session_id, &mut raw_token) };
        if ok == 0 {
            let err = unsafe { GetLastError() };
            if err == ERROR_PRIVILEGE_NOT_HELD {
                return Err(anyhow!(
                    "WTSQueryUserToken denied: ERROR_PRIVILEGE_NOT_HELD (1314). \
                     Interactive launch needs the SE_TCB privilege — run this CLI \
                     as LocalSystem (e.g. via a SYSTEM service or PsExec -s)."
                ));
            }
            bail!("WTSQueryUserToken failed for session {session_id} (GetLastError={err})");
        }
        let user_token = OwnedHandle(raw_token);

        // 3. Duplicate it into a primary token suitable for CreateProcessAsUserW.
        let mut raw_dup: HANDLE = ptr::null_mut();
        let ok = unsafe {
            DuplicateTokenEx(
                user_token.0,
                MAXIMUM_ALLOWED,
                ptr::null(),
                SecurityImpersonation as SECURITY_IMPERSONATION_LEVEL,
                TokenPrimary as TOKEN_TYPE,
                &mut raw_dup,
            )
        };
        if ok == 0 {
            let err = unsafe { GetLastError() };
            bail!("DuplicateTokenEx failed (GetLastError={err})");
        }
        let dup_token = OwnedHandle(raw_dup);

        // 4. Build the user's environment block.
        let mut env_block: *mut core::ffi::c_void = ptr::null_mut();
        let env_ok = unsafe { CreateEnvironmentBlock(&mut env_block, dup_token.0, FALSE) };
        let have_env = env_ok != 0 && !env_block.is_null();

        // 5. CreateProcessAsUserW on the user's interactive desktop.
        let exe_wide = to_wide(request.exe.as_os_str());
        let mut cmdline = build_command_line(request);
        let cwd_wide = request.cwd.as_ref().map(|cwd| to_wide(cwd.as_os_str()));
        let cwd_ptr = cwd_wide
            .as_ref()
            .map(|buf| buf.as_ptr())
            .unwrap_or(ptr::null());
        let mut desktop = to_wide(OsStr::new("winsta0\\default"));

        let mut startup: STARTUPINFOW = unsafe { std::mem::zeroed() };
        startup.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        startup.lpDesktop = desktop.as_mut_ptr();
        let mut info: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };

        let flags = if have_env {
            CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_CONSOLE
        } else {
            CREATE_NEW_CONSOLE
        };
        let env_ptr: *const core::ffi::c_void = if have_env {
            env_block
        } else {
            ptr::null()
        };

        let ok = unsafe {
            CreateProcessAsUserW(
                dup_token.0,
                exe_wide.as_ptr(),
                cmdline.as_mut_ptr(),
                ptr::null(),
                ptr::null(),
                FALSE,
                flags,
                env_ptr,
                cwd_ptr,
                &startup,
                &mut info,
            )
        };

        // Always release the environment block if we created one.
        if have_env {
            unsafe { DestroyEnvironmentBlock(env_block) };
        }

        if ok == 0 {
            let err = unsafe { GetLastError() };
            bail!(
                "CreateProcessAsUserW failed for {} into session {session_id} (GetLastError={err})",
                request.exe.display()
            );
        }
        let _process = OwnedHandle(info.hProcess);
        let _thread = OwnedHandle(info.hThread);

        Ok(LaunchOutcome {
            pid: info.dwProcessId,
            session: Some(session_id),
            interactive: true,
        })
    }

    pub(super) fn stop(selector: &ProcessSelector, _force: bool) -> Result<StopOutcome> {
        // On Windows TerminateProcess is the only mechanism; `--force` is accepted
        // for parity with unix but does not change behaviour (there is no graceful
        // signal equivalent here).
        let pids = resolve_pids(selector)?;
        let mut stopped = Vec::new();
        for pid in pids {
            if terminate_pid(pid)? {
                stopped.push(pid);
            }
        }
        Ok(StopOutcome { pids: stopped })
    }

    pub(super) fn status(selector: &ProcessSelector) -> Result<StatusSnapshot> {
        let pids = match selector {
            ProcessSelector::Pid(pid) => {
                if pid_is_alive(*pid)? {
                    vec![*pid]
                } else {
                    Vec::new()
                }
            }
            ProcessSelector::Name(name) => pids_for_name(name)?,
        };
        Ok(StatusSnapshot { pids })
    }

    fn resolve_pids(selector: &ProcessSelector) -> Result<Vec<u32>> {
        match selector {
            ProcessSelector::Pid(pid) => Ok(vec![*pid]),
            ProcessSelector::Name(name) => pids_for_name(name),
        }
    }

    /// Terminate a single pid via OpenProcess(PROCESS_TERMINATE)+TerminateProcess.
    fn terminate_pid(pid: u32) -> Result<bool> {
        let handle = unsafe { OpenProcess(PROCESS_TERMINATE, FALSE, pid) };
        if handle.is_null() {
            // Process likely already gone, or access denied. Treat "not found"
            // as a non-stop rather than a hard error.
            return Ok(false);
        }
        let owned = OwnedHandle(handle);
        let ok = unsafe { TerminateProcess(owned.0, 1) };
        if ok == 0 {
            let err = unsafe { GetLastError() };
            bail!("TerminateProcess failed for pid {pid} (GetLastError={err})");
        }
        Ok(true)
    }

    fn pid_is_alive(pid: u32) -> Result<bool> {
        Ok(pids_snapshot()?.iter().any(|entry| entry.0 == pid))
    }

    /// Resolve a process name (with or without ".exe") to pids by enumerating the
    /// process snapshot. Matching is case-insensitive on the szExeFile field.
    fn pids_for_name(name: &str) -> Result<Vec<u32>> {
        let target = name.trim().to_ascii_lowercase();
        if target.is_empty() {
            return Ok(Vec::new());
        }
        let target_exe = if target.ends_with(".exe") {
            target.clone()
        } else {
            format!("{target}.exe")
        };
        let mut pids = Vec::new();
        for (pid, exe) in pids_snapshot()? {
            let exe_lower = exe.to_ascii_lowercase();
            if exe_lower == target || exe_lower == target_exe {
                pids.push(pid);
            }
        }
        Ok(pids)
    }

    /// Enumerate (pid, exe-name) for all processes via the ToolHelp snapshot.
    fn pids_snapshot() -> Result<Vec<(u32, String)>> {
        let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
        if snapshot == INVALID_HANDLE_VALUE {
            let err = unsafe { GetLastError() };
            bail!("CreateToolhelp32Snapshot failed (GetLastError={err})");
        }
        let owned = OwnedHandle(snapshot);

        let mut entry: PROCESSENTRY32W = unsafe { std::mem::zeroed() };
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;

        let mut out = Vec::new();
        let mut ok = unsafe { Process32FirstW(owned.0, &mut entry) };
        if ok == 0 {
            // Empty snapshot is unusual but not fatal.
            return Ok(out);
        }
        while ok != 0 {
            out.push((entry.th32ProcessID, wide_to_string(&entry.szExeFile)));
            ok = unsafe { Process32NextW(owned.0, &mut entry) };
        }
        Ok(out)
    }

    /// Decode a NUL-terminated fixed UTF-16 buffer (szExeFile) to a String.
    fn wide_to_string(buf: &[u16]) -> String {
        let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        String::from_utf16_lossy(&buf[..end])
    }

    // Silence unused-import warnings for the Context import on configs where it
    // is not exercised; keep the import for parity with the unix backend.
    #[allow(unused_imports)]
    use anyhow::Context as _ContextUnused;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn launch_args(exe: &str, interactive: bool) -> AppLaunchArgs {
        AppLaunchArgs {
            exe: PathBuf::from(exe),
            cwd: None,
            args: Vec::new(),
            interactive,
            output: crate::OutputOptions { json: true },
        }
    }

    #[test]
    fn launch_request_rejects_empty_exe() {
        let args = launch_args("", false);
        assert!(LaunchRequest::from_args(&args).is_err());
    }

    #[test]
    fn launch_request_carries_fields() {
        let mut args = launch_args("/Applications/SkyBridge.app", true);
        args.cwd = Some(PathBuf::from("/tmp"));
        args.args = vec!["--foo".to_owned(), "bar".to_owned()];
        let request = LaunchRequest::from_args(&args).expect("valid request");
        assert_eq!(request.exe, PathBuf::from("/Applications/SkyBridge.app"));
        assert_eq!(request.cwd, Some(PathBuf::from("/tmp")));
        assert_eq!(request.args, vec!["--foo".to_owned(), "bar".to_owned()]);
        assert!(request.interactive);
    }

    #[test]
    fn selector_requires_exactly_one() {
        assert!(ProcessSelector::from_pid_name(None, None).is_err());
        assert!(
            ProcessSelector::from_pid_name(Some(10), Some("x".to_owned())).is_err(),
            "both pid+name must be rejected"
        );
        assert!(ProcessSelector::from_pid_name(Some(0), None).is_err(), "pid 0 invalid");
        assert!(
            ProcessSelector::from_pid_name(None, Some("   ".to_owned())).is_err(),
            "blank name invalid"
        );
    }

    #[test]
    fn selector_pid_and_name_variants() {
        assert_eq!(
            ProcessSelector::from_pid_name(Some(42), None).unwrap(),
            ProcessSelector::Pid(42)
        );
        assert_eq!(
            ProcessSelector::from_pid_name(None, Some("SkyBridge".to_owned())).unwrap(),
            ProcessSelector::Name("SkyBridge".to_owned())
        );
    }

    #[test]
    fn launch_json_shape_is_stable() {
        let request = LaunchRequest {
            exe: PathBuf::from("C:/sb/app2/Skybridge.WinClient.exe"),
            cwd: None,
            args: Vec::new(),
            interactive: true,
        };
        let outcome = LaunchOutcome {
            pid: 4321,
            session: Some(2),
            interactive: true,
        };
        let value = serde_json::to_value(launch_json(&request, &outcome)).unwrap();
        assert_eq!(value["launched"], serde_json::json!(true));
        assert_eq!(value["pid"], serde_json::json!(4321));
        assert_eq!(value["session"], serde_json::json!(2));
        assert_eq!(value["interactive"], serde_json::json!(true));
        assert_eq!(
            value["exe"],
            serde_json::json!("C:/sb/app2/Skybridge.WinClient.exe")
        );
    }

    #[test]
    fn launch_json_non_interactive_session_null() {
        let request = LaunchRequest {
            exe: PathBuf::from("/Applications/SkyBridge.app"),
            cwd: None,
            args: Vec::new(),
            interactive: false,
        };
        let outcome = LaunchOutcome {
            pid: 99,
            session: None,
            interactive: false,
        };
        let value = serde_json::to_value(launch_json(&request, &outcome)).unwrap();
        assert_eq!(value["session"], serde_json::Value::Null);
        assert_eq!(value["interactive"], serde_json::json!(false));
    }

    #[test]
    fn selector_name_accessor() {
        assert_eq!(
            selector_name(&ProcessSelector::Name("Sky".to_owned())),
            Some("Sky")
        );
        assert_eq!(selector_name(&ProcessSelector::Pid(7)), None);
    }
}
