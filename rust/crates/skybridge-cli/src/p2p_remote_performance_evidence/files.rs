use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

pub(crate) fn p2p_remote_performance_artifact_available(artifact_dir: Option<&Path>) -> bool {
    let Some(artifact_dir) = artifact_dir else {
        return false;
    };
    p2p_remote_performance_files(artifact_dir)
        .is_ok_and(|files| files.iter().any(|path| is_p2p_remote_ios_log(path)))
}

pub(crate) fn p2p_remote_performance_files(artifact_dir: &Path) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    let mut ios_primary_logs = Vec::new();
    let mut ios_fallback_logs = Vec::new();
    let mut mac_status_logs = Vec::new();
    let mut mac_stdout_log: Option<PathBuf> = None;
    for entry in fs::read_dir(artifact_dir)
        .with_context(|| format!("failed to read artifact dir {}", artifact_dir.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
            continue;
        };
        if is_p2p_remote_mac_status_log(name) {
            mac_status_logs.push(path);
        } else if name == "mac.stdout.log" {
            mac_stdout_log = Some(path);
        } else if is_p2p_remote_ios_status_log_name(name) {
            if is_p2p_remote_ios_fallback_log_name(name) {
                ios_fallback_logs.push(path);
            } else {
                ios_primary_logs.push(path);
            }
        }
    }
    if ios_primary_logs.is_empty() {
        files.extend(ios_fallback_logs);
    } else {
        files.extend(ios_primary_logs);
    }
    if mac_status_logs.is_empty() {
        if let Some(path) = mac_stdout_log {
            files.push(path);
        }
    } else {
        mac_status_logs.sort();
        files.extend(mac_status_logs);
    }
    files.sort();
    Ok(files)
}

pub(super) fn is_p2p_remote_ios_log(path: &Path) -> bool {
    path.file_name()
        .and_then(|value| value.to_str())
        .is_some_and(is_p2p_remote_ios_status_log_name)
}

fn is_p2p_remote_mac_status_log(name: &str) -> bool {
    name == "mac.status.log" || (name.starts_with("mac-") && name.ends_with(".status.log"))
}

fn is_p2p_remote_ios_status_log_name(name: &str) -> bool {
    (name.starts_with("ios-p2p-remote") && name.ends_with(".status.log"))
        || name == "ios-console.status.log"
}

fn is_p2p_remote_ios_fallback_log_name(name: &str) -> bool {
    name == "ios-console.status.log"
        || name.contains(".console.status.log")
        || name.contains(".app-cache.status.log")
}
