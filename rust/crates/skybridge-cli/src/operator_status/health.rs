use std::path::PathBuf;

use anyhow::{Result, anyhow, bail};
use serde_json::json;
use skybridge_agent::{load_health_snapshot, resolve_paths};
use skybridge_core::AgentRuntimeStatus;

pub(crate) async fn metrics(state_dir: Option<PathBuf>, as_json: bool) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let health = load_health_snapshot(&paths).await?;
    let Some(health) = health else {
        bail!("No health snapshot found. Start the agent first.");
    };

    let payload = json!({
        "status": health.status,
        "updated_at": health.updated_at.format(&time::format_description::well_known::Rfc3339)?,
        "active_sessions": health.active_sessions,
        "active_transfers": health.active_transfers,
        "fallback_invocation_count": health.fallback_invocation_count,
    });

    if as_json {
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else {
        println!("Status: {}", describe_agent_status(health.status));
        println!("Updated At: {}", health.updated_at);
        println!("Active Sessions: {}", health.active_sessions);
        println!("Active Transfers: {}", health.active_transfers);
        println!(
            "Fallback Invocation Count: {}",
            health.fallback_invocation_count
        );
    }
    Ok(())
}

pub(crate) async fn tail_logs(state_dir: Option<PathBuf>, lines: usize) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let body = tokio::fs::read_to_string(&paths.log_file)
        .await
        .map_err(|error| {
            anyhow!(
                "Failed to read {}: {}. Start the agent once to create the structured log file.",
                paths.log_file.display(),
                error
            )
        })?;

    let mut tail = body.lines().rev().take(lines).collect::<Vec<_>>();
    tail.reverse();
    for line in tail {
        println!("{line}");
    }
    Ok(())
}

pub(crate) fn describe_agent_status(status: AgentRuntimeStatus) -> &'static str {
    match status {
        AgentRuntimeStatus::Starting => "starting",
        AgentRuntimeStatus::Healthy => "healthy",
        AgentRuntimeStatus::Degraded => "degraded",
        AgentRuntimeStatus::Stopping => "stopping",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use time::OffsetDateTime;

    #[tokio::test]
    async fn metrics_and_tail_logs_cover_state_outputs() -> Result<()> {
        let state_dir = make_test_dir("metrics-tail-logs")?;
        let paths = resolve_paths(Some(state_dir.clone()))?;
        std::fs::create_dir_all(paths.health_file.parent().expect("health parent"))?;
        std::fs::create_dir_all(paths.log_file.parent().expect("log parent"))?;
        let now = OffsetDateTime::now_utc();
        std::fs::write(
            &paths.health_file,
            serde_json::to_string(&skybridge_core::AgentHealthSnapshot {
                schema_version: 1,
                status: AgentRuntimeStatus::Healthy,
                pid: 123,
                state_dir: state_dir.display().to_string(),
                started_at: now,
                updated_at: now,
                active_sessions: 2,
                active_transfers: 1,
                fallback_invocation_count: 0,
            })?,
        )?;
        std::fs::write(&paths.log_file, "one\ntwo\nthree\n")?;

        metrics(Some(state_dir.clone()), false).await?;
        metrics(Some(state_dir.clone()), true).await?;
        tail_logs(Some(state_dir.clone()), 2).await?;

        let missing_log_dir = make_test_dir("missing-tail-log")?;
        assert!(tail_logs(Some(missing_log_dir), 1).await.is_err());
        let missing_health_dir = make_test_dir("missing-health")?;
        assert!(metrics(Some(missing_health_dir), false).await.is_err());
        Ok(())
    }

    #[test]
    fn describe_agent_status_covers_all_states() {
        assert_eq!(
            describe_agent_status(AgentRuntimeStatus::Starting),
            "starting"
        );
        assert_eq!(
            describe_agent_status(AgentRuntimeStatus::Healthy),
            "healthy"
        );
        assert_eq!(
            describe_agent_status(AgentRuntimeStatus::Degraded),
            "degraded"
        );
        assert_eq!(
            describe_agent_status(AgentRuntimeStatus::Stopping),
            "stopping"
        );
    }

    fn make_test_dir(name: &str) -> Result<PathBuf> {
        let dir = std::env::temp_dir().join(format!("skybridge-cli-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir)?;
        Ok(dir)
    }
}
