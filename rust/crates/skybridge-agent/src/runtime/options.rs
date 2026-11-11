use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Result, ensure};

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

impl AgentRuntimeOptions {
    /// Check public library inputs before creating state or starting workers.
    pub(super) fn validate(&self) -> Result<()> {
        ensure!(
            !self.heartbeat_interval.is_zero(),
            "agent heartbeat interval must be positive"
        );
        if self.discovery_scan_enabled {
            ensure!(
                (Duration::from_secs(1)..=Duration::from_secs(3600))
                    .contains(&self.discovery_scan_interval),
                "discovery scan interval must be between 1 and 3600 seconds"
            );
            ensure!(
                (Duration::from_secs(1)..=Duration::from_secs(30))
                    .contains(&self.discovery_scan_window),
                "discovery scan window must be between 1 and 30 seconds"
            );
        }
        Ok(())
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_runtime_options_fail_before_tokio_interval_or_scanning() {
        assert!(AgentRuntimeOptions::default().validate().is_ok());
        assert!(
            AgentRuntimeOptions {
                heartbeat_interval: Duration::ZERO,
                ..Default::default()
            }
            .validate()
            .is_err()
        );
        assert!(
            AgentRuntimeOptions {
                discovery_scan_interval: Duration::ZERO,
                ..Default::default()
            }
            .validate()
            .is_err()
        );
        assert!(
            AgentRuntimeOptions {
                discovery_scan_window: Duration::from_secs(31),
                ..Default::default()
            }
            .validate()
            .is_err()
        );
        assert!(
            AgentRuntimeOptions {
                discovery_scan_enabled: false,
                discovery_scan_window: Duration::ZERO,
                ..Default::default()
            }
            .validate()
            .is_ok()
        );
    }
}
