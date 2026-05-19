use std::path::PathBuf;
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct AgentRuntimeOptions {
    pub state_dir: Option<PathBuf>,
    pub heartbeat_interval: Duration,
}

impl Default for AgentRuntimeOptions {
    fn default() -> Self {
        Self {
            state_dir: None,
            heartbeat_interval: Duration::from_secs(2),
        }
    }
}
