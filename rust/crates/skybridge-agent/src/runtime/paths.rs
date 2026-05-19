use std::path::PathBuf;

use anyhow::{Result, anyhow};
use directories::ProjectDirs;

#[derive(Debug, Clone)]
pub struct AgentPaths {
    pub root: PathBuf,
    pub identity_dir: PathBuf,
    pub runtime_dir: PathBuf,
    pub logs_dir: PathBuf,
    pub identity_file: PathBuf,
    pub session_controls_file: PathBuf,
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
            .ok_or_else(|| anyhow!("platform state directory is unavailable"))?
            .to_path_buf()
    };

    Ok(AgentPaths {
        identity_dir: root.join("identity"),
        runtime_dir: root.join("runtime"),
        logs_dir: root.join("logs"),
        identity_file: root.join("identity").join("device.json"),
        session_controls_file: root.join("runtime").join("session-controls.json"),
        health_file: root.join("runtime").join("health.json"),
        log_file: root.join("logs").join("agent.log"),
        root,
    })
}
