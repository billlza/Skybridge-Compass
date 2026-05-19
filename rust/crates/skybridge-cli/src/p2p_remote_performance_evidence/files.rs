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
    let mut mac_status_log: Option<PathBuf> = None;
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
        if name == "mac.status.log" {
            mac_status_log = Some(path);
        } else if name == "mac.stdout.log" {
            mac_stdout_log = Some(path);
        } else if name.starts_with("ios-p2p-remote") && name.ends_with(".status.log") {
            if name.contains(".console.status.log") || name.contains(".app-cache.status.log") {
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
    if let Some(path) = mac_status_log {
        files.push(path);
    } else if let Some(path) = mac_stdout_log {
        files.push(path);
    }
    files.sort();
    Ok(files)
}

pub(super) fn is_p2p_remote_ios_log(path: &Path) -> bool {
    path.file_name()
        .and_then(|value| value.to_str())
        .is_some_and(|name| name.starts_with("ios-p2p-remote") && name.ends_with(".status.log"))
}
