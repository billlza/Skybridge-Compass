use std::path::PathBuf;
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct AgentRuntimeOptions {
    pub state_dir: Option<PathBuf>,
    pub heartbeat_interval: Duration,
    /// Whether the agent-owned active mDNS nearby scanner runs.
    pub discovery_scan_enabled: bool,
    /// How often a new active scan pass is started.
    pub discovery_scan_interval: Duration,
    /// How long each active scan pass browses for responses.
    pub discovery_scan_window: Duration,
}

impl Default for AgentRuntimeOptions {
    fn default() -> Self {
        Self {
            state_dir: None,
            heartbeat_interval: Duration::from_secs(2),
            discovery_scan_enabled: true,
            discovery_scan_interval: Duration::from_secs(30),
            discovery_scan_window: Duration::from_secs(4),
        }
    }
}
