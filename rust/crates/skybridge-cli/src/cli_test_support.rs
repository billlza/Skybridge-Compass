#![cfg(test)]

use std::ffi::{OsStr, OsString};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::thread;

use anyhow::Result;
use serde_json::json;

use crate::performance_budgets::P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS;
use crate::{
    DoctorCheck, DoctorProbeReport, OutputOptions, PerformanceCheckArgs, PerformanceKindArg,
};

pub(crate) fn doctor_check<'a>(report: &'a DoctorProbeReport, name: &str) -> &'a DoctorCheck {
    report
        .checks
        .iter()
        .find(|check| check.name == name)
        .unwrap_or_else(|| panic!("{name} check missing"))
}

pub(crate) fn doctor_check_optional<'a>(
    report: &'a DoctorProbeReport,
    name: &str,
) -> Option<&'a DoctorCheck> {
    report.checks.iter().find(|check| check.name == name)
}

pub(crate) fn fixture_dir(parts: &[&str]) -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.push("tests");
    path.push("fixtures");
    for part in parts {
        path.push(part);
    }
    path
}

pub(crate) fn performance_artifact_args(
    kind: PerformanceKindArg,
    artifact_dir: PathBuf,
) -> PerformanceCheckArgs {
    PerformanceCheckArgs {
        kind,
        session_id: None,
        latest: false,
        artifact_dir: Some(artifact_dir),
        log_file: None,
        since_seconds: 1,
        min_fps: 59.0,
        min_width: 0,
        min_height: 0,
        exact_video_size: false,
        require_audio: true,
        strict_fps_floor: true,
        min_pass_window_seconds: P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS,
        manual_artifact: false,
        output: OutputOptions { json: false },
    }
}

pub(crate) fn make_test_dir(name: &str) -> Result<PathBuf> {
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "skybridge-cli-{name}-{}-{nonce}",
        std::process::id()
    ));
    std::fs::create_dir_all(&path)?;
    Ok(path)
}

pub(crate) struct EnvVarGuard {
    _lock: MutexGuard<'static, ()>,
    key: String,
    previous: Option<OsString>,
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        restore_env_var(&self.key, self.previous.take());
    }
}

pub(crate) fn set_env_var_for_test(key: &str, value: impl AsRef<OsStr>) -> EnvVarGuard {
    let lock = env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let previous = std::env::var_os(key);
    unsafe {
        std::env::set_var(key, value);
    }
    EnvVarGuard {
        _lock: lock,
        key: key.to_owned(),
        previous,
    }
}

fn restore_env_var(key: &str, previous: Option<OsString>) {
    unsafe {
        if let Some(previous) = previous {
            std::env::set_var(key, previous);
        } else {
            std::env::remove_var(key);
        }
    }
}

fn env_lock() -> &'static Mutex<()> {
    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    ENV_LOCK.get_or_init(|| Mutex::new(()))
}

pub(crate) fn spawn_mock_server(
    routes: Vec<(&'static str, &'static str, u16, serde_json::Value)>,
) -> Result<String> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let address = listener.local_addr()?;
    let routes = Arc::new(routes);
    thread::spawn(move || {
        for stream in listener.incoming().take(16) {
            let Ok(mut stream) = stream else { continue };
            let mut buffer = [0_u8; 4096];
            let bytes_read = stream.read(&mut buffer).unwrap_or(0);
            let request = String::from_utf8_lossy(&buffer[..bytes_read]);
            let mut first_line = request.lines().next().unwrap_or("").split_whitespace();
            let method = first_line.next().unwrap_or("");
            let path = first_line.next().unwrap_or("");
            let route = routes.iter().find(|(route_method, route_path, _, _)| {
                *route_method == method && *route_path == path
            });
            let (status, body) = route
                .map(|(_, _, status, body)| (*status, body.clone()))
                .unwrap_or_else(|| (404, json!({ "error": "not_found" })));
            let reason = if status == 200 { "OK" } else { "ERROR" };
            let body = body.to_string();
            let response = format!(
                "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(response.as_bytes());
        }
    });
    Ok(format!("http://{address}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn env_var_guard_restores_after_unwind() {
        let key = format!("SKYBRIDGE_CLI_TEST_ENV_GUARD_{}", std::process::id());
        restore_env_var(&key, None);

        let result = std::panic::catch_unwind(|| {
            let _guard = set_env_var_for_test(&key, "temporary");
            assert_eq!(std::env::var_os(&key), Some(OsString::from("temporary")));
            panic!("force env guard unwind");
        });

        assert!(result.is_err());
        assert_eq!(std::env::var_os(&key), None);

        {
            let _guard = set_env_var_for_test(&key, "second");
            assert_eq!(std::env::var_os(&key), Some(OsString::from("second")));
        }
        assert_eq!(std::env::var_os(&key), None);
    }
}
