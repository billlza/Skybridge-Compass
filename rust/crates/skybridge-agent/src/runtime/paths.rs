use std::path::PathBuf;

use anyhow::{Result, anyhow};
use directories::ProjectDirs;

#[derive(Debug, Clone)]
pub struct AgentPaths {
    pub root: PathBuf,
    pub identity_dir: PathBuf,
    pub runtime_dir: PathBuf,
    pub logs_dir: PathBuf,
    pub received_dir: PathBuf,
    pub identity_file: PathBuf,
    pub agent_runtime_lock_file: PathBuf,
    pub session_controls_file: PathBuf,
    pub session_controls_lock_file: PathBuf,
    pub nearby_discovery_snapshots_file: PathBuf,
    pub file_transfer_requests_file: PathBuf,
    pub remote_desktop_requests_file: PathBuf,
    pub remote_desktop_capabilities_file: PathBuf,
    pub health_file: PathBuf,
    pub log_file: PathBuf,
}

pub fn resolve_paths(state_dir_override: Option<PathBuf>) -> Result<AgentPaths> {
    let root = if let Some(explicit) = state_dir_override {
        explicit
    } else if let Some(from_env) = std::env::var_os("SKYBRIDGE_STATE_DIR") {
        PathBuf::from(from_env)
    } else {
        let dirs = ProjectDirs::from("com", "SkyBridge", "skybridge")
            .ok_or_else(|| anyhow!("failed to resolve platform state directory"))?;
        dirs.state_dir()
            .unwrap_or_else(|| dirs.data_local_dir())
            .to_path_buf()
    };

    Ok(AgentPaths {
        identity_dir: root.join("identity"),
        runtime_dir: root.join("runtime"),
        logs_dir: root.join("logs"),
        received_dir: root.join("received"),
        identity_file: root.join("identity").join("device.json"),
        agent_runtime_lock_file: root.join("runtime").join("agent.lock"),
        session_controls_file: root.join("runtime").join("session-controls.json"),
        session_controls_lock_file: root.join("runtime").join("session-controls.json.lock"),
        nearby_discovery_snapshots_file: root
            .join("runtime")
            .join("nearby-discovery-snapshots.json"),
        file_transfer_requests_file: root.join("runtime").join("file-transfer-requests.json"),
        remote_desktop_requests_file: root.join("runtime").join("remote-desktop-requests.json"),
        remote_desktop_capabilities_file: root
            .join("runtime")
            .join("remote-desktop-capabilities.json"),
        health_file: root.join("runtime").join("health.json"),
        log_file: root.join("logs").join("agent.log"),
        root,
    })
}
