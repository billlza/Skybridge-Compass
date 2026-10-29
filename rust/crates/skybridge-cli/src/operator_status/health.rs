use std::path::PathBuf;

use anyhow::{Result, anyhow};
use serde_json::json;
use skybridge_agent::resolve_paths;
use skybridge_core::AgentRuntimeStatus;

use crate::agent_runtime_guard::load_active_agent_health;

pub(crate) async fn metrics(state_dir: Option<PathBuf>, as_json: bool) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let health = load_active_agent_health(&paths)
        .await
        .map_err(anyhow::Error::new)?;

    let payload = json!({
        "health_schema_version": health.schema_version,
        "status": health.status,
        "updated_at": health.updated_at.format(&time::format_description::well_known::Rfc3339)?,
        "active_sessions": health.active_sessions,
        "active_transfers": health.active_transfers,
        "active_transfers_observation": observation_label(health.active_transfers),
        "fallback_invocation_count": health.fallback_invocation_count,
        "fallback_invocation_count_observation": observation_label(health.fallback_invocation_count),
    });

    if as_json {
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else {
        println!("Status: {}", describe_agent_status(health.status));
        println!("Updated At: {}", health.updated_at);
        println!("Active Sessions: {}", health.active_sessions);
        println!(
            "Active Transfers: {}",
            display_observation(health.active_transfers)
        );
        println!(
            "Fallback Invocation Count: {}",
            display_observation(health.fallback_invocation_count)
        );
    }
    Ok(())
}

fn observation_label<T>(value: Option<T>) -> &'static str {
    if value.is_some() {
        "observed"
    } else {
        "unobserved"
    }
}

fn display_observation<T: std::fmt::Display>(value: Option<T>) -> String {
    value.map_or_else(|| "unobserved".to_owned(), |value| value.to_string())
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
        let active_agent = crate::cli_test_support::activate_test_agent(&paths)?;
        let now = OffsetDateTime::now_utc();
        std::fs::write(
            &paths.health_file,
            serde_json::to_string(&skybridge_core::AgentHealthSnapshot {
                schema_version: skybridge_core::AgentHealthSnapshot::SCHEMA_VERSION,
                instance_id: active_agent.instance_id().to_owned(),
                status: AgentRuntimeStatus::Healthy,
                pid: std::process::id(),
                state_dir: state_dir.display().to_string(),
                started_at: now,
                updated_at: now,
                active_sessions: 2,
                active_transfers: Some(1),
                fallback_invocation_count: Some(0),
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

    #[tokio::test]
    async fn metrics_rejects_a_stale_snapshot_even_when_the_runtime_lock_is_held() -> Result<()> {
        let state_dir = make_test_dir("stale-metrics")?;
        let paths = resolve_paths(Some(state_dir.clone()))?;
        let active_agent = crate::cli_test_support::activate_test_agent(&paths)?;
        let mut stale = skybridge_core::AgentHealthSnapshot::new_for_instance(
            AgentRuntimeStatus::Healthy,
            std::process::id(),
            paths.root.display().to_string(),
            active_agent.instance_id(),
        );
        stale.updated_at = OffsetDateTime::now_utc() - time::Duration::seconds(11);
        std::fs::write(&paths.health_file, serde_json::to_vec_pretty(&stale)?)?;

        let error = metrics(Some(state_dir), true)
            .await
            .expect_err("stale metrics must fail closed");
        assert!(error.to_string().contains("freshness window"));
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
