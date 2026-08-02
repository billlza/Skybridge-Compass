use std::fmt;

use skybridge_agent::{
    AgentPaths, agent_runtime_is_active, load_agent_runtime_lease, load_health_snapshot,
};
use skybridge_core::{AgentHealthSnapshot, AgentRuntimeLease, AgentRuntimeStatus};
use time::OffsetDateTime;

const MAX_HEALTH_AGE_SECONDS: i64 = 10;

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AgentRuntimeGuardError {
    pub(crate) code: &'static str,
    pub(crate) message: String,
    pub(crate) retryable: bool,
}

impl fmt::Display for AgentRuntimeGuardError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for AgentRuntimeGuardError {}

/// Verifies that this state directory has one lock-owning agent and a fresh healthy heartbeat.
///
/// The runtime lock is probed both before and after reading health so a stale health file cannot
/// authorize work and an agent that exits during the read is rejected.
pub(crate) async fn require_active_agent(paths: &AgentPaths) -> Result<(), AgentRuntimeGuardError> {
    load_active_agent_health(paths).await.map(|_| ())
}

/// Returns the same fresh, schema-valid snapshot that authorizes managed CLI work.
/// Metrics and status callers must use this instead of trusting `health.json` alone.
pub(crate) async fn load_active_agent_health(
    paths: &AgentPaths,
) -> Result<AgentHealthSnapshot, AgentRuntimeGuardError> {
    evaluate_runtime_lock(agent_runtime_is_active(paths))?;
    let lease_before = load_runtime_lease(paths).await?;
    let health = load_health_snapshot(paths)
        .await
        .map_err(|_error| AgentRuntimeGuardError {
            code: "agent_health_unavailable",
            message: "failed to read the SkyBridge agent health snapshot".to_owned(),
            retryable: true,
        })?;
    let lease_after = load_runtime_lease(paths).await?;
    evaluate_runtime_lock(agent_runtime_is_active(paths))?;
    let health = health.ok_or_else(|| AgentRuntimeGuardError {
        code: "agent_health_missing",
        message: "the lock-owning SkyBridge agent has no health snapshot".to_owned(),
        retryable: true,
    })?;
    evaluate_runtime_lease_binding(paths, &lease_before, &health, &lease_after)?;
    evaluate_health_snapshot(paths, Some(&health), OffsetDateTime::now_utc())?;
    Ok(health)
}

async fn load_runtime_lease(
    paths: &AgentPaths,
) -> Result<AgentRuntimeLease, AgentRuntimeGuardError> {
    load_agent_runtime_lease(paths)
        .await
        .map_err(|_error| AgentRuntimeGuardError {
            code: "agent_lease_unavailable",
            message: "failed to read the SkyBridge agent runtime lease".to_owned(),
            retryable: true,
        })?
        .ok_or_else(|| AgentRuntimeGuardError {
            code: "agent_lease_missing",
            message: "the lock-owning SkyBridge agent has no runtime lease".to_owned(),
            retryable: true,
        })
}

fn evaluate_runtime_lock(
    activity_result: anyhow::Result<bool>,
) -> Result<(), AgentRuntimeGuardError> {
    match activity_result {
        Ok(true) => Ok(()),
        Ok(false) => Err(AgentRuntimeGuardError {
            code: "agent_unavailable",
            message: "the SkyBridge agent does not own this state directory's runtime lock; start `skybridge agent run` first"
                .to_owned(),
            retryable: true,
        }),
        Err(_error) => Err(AgentRuntimeGuardError {
            code: "agent_state_check_failed",
            message: "failed to verify the SkyBridge agent runtime lock".to_owned(),
            retryable: true,
        }),
    }
}

fn evaluate_health_snapshot(
    paths: &AgentPaths,
    health: Option<&AgentHealthSnapshot>,
    now: OffsetDateTime,
) -> Result<(), AgentRuntimeGuardError> {
    let Some(health) = health else {
        return Err(AgentRuntimeGuardError {
            code: "agent_health_missing",
            message: "the lock-owning SkyBridge agent has no health snapshot".to_owned(),
            retryable: true,
        });
    };
    if health.schema_version != AgentHealthSnapshot::SCHEMA_VERSION {
        return Err(AgentRuntimeGuardError {
            code: "agent_health_schema_mismatch",
            message: format!(
                "unsupported agent health schema {}; expected {}",
                health.schema_version,
                AgentHealthSnapshot::SCHEMA_VERSION
            ),
            retryable: false,
        });
    }
    if health.instance_id.trim().is_empty() {
        return Err(AgentRuntimeGuardError {
            code: "agent_health_instance_missing",
            message: "the agent health snapshot has no runtime instance identifier".to_owned(),
            retryable: false,
        });
    }
    if health.state_dir != paths.root.display().to_string() {
        return Err(AgentRuntimeGuardError {
            code: "agent_health_state_dir_mismatch",
            message: "the lock-owning agent health snapshot belongs to a different state directory"
                .to_owned(),
            retryable: false,
        });
    }
    if health.status != AgentRuntimeStatus::Healthy {
        return Err(AgentRuntimeGuardError {
            code: "agent_not_healthy",
            message: format!(
                "the lock-owning SkyBridge agent is `{}` rather than `healthy`",
                agent_status_label(health.status)
            ),
            retryable: true,
        });
    }
    let age = now - health.updated_at;
    if age.is_negative() || age > time::Duration::seconds(MAX_HEALTH_AGE_SECONDS) {
        return Err(AgentRuntimeGuardError {
            code: "agent_health_stale",
            message: format!(
                "the lock-owning SkyBridge agent health snapshot is outside the {}-second freshness window",
                MAX_HEALTH_AGE_SECONDS
            ),
            retryable: true,
        });
    }
    Ok(())
}

fn evaluate_runtime_lease_binding(
    paths: &AgentPaths,
    lease_before: &AgentRuntimeLease,
    health: &AgentHealthSnapshot,
    lease_after: &AgentRuntimeLease,
) -> Result<(), AgentRuntimeGuardError> {
    if lease_before.schema_version != AgentRuntimeLease::SCHEMA_VERSION
        || lease_after.schema_version != AgentRuntimeLease::SCHEMA_VERSION
    {
        return Err(AgentRuntimeGuardError {
            code: "agent_lease_schema_mismatch",
            message: "the agent runtime lease schema is unsupported".to_owned(),
            retryable: false,
        });
    }
    if lease_before != lease_after {
        return Err(AgentRuntimeGuardError {
            code: "agent_lease_changed",
            message: "the agent runtime lease changed while health was being verified".to_owned(),
            retryable: true,
        });
    }
    if lease_before.instance_id.trim().is_empty() {
        return Err(AgentRuntimeGuardError {
            code: "agent_lease_instance_missing",
            message: "the agent runtime lease has no instance identifier".to_owned(),
            retryable: false,
        });
    }
    if lease_before.state_dir != paths.root.display().to_string() {
        return Err(AgentRuntimeGuardError {
            code: "agent_lease_state_dir_mismatch",
            message: "the agent runtime lease belongs to a different state directory".to_owned(),
            retryable: false,
        });
    }
    if health.instance_id != lease_before.instance_id || health.pid != lease_before.pid {
        return Err(AgentRuntimeGuardError {
            code: "agent_lease_health_mismatch",
            message: "the health snapshot does not belong to the lock-owning agent instance"
                .to_owned(),
            retryable: true,
        });
    }
    Ok(())
}

fn agent_status_label(status: AgentRuntimeStatus) -> &'static str {
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

    #[test]
    fn runtime_lock_gate_distinguishes_inactive_and_probe_failure() {
        assert!(evaluate_runtime_lock(Ok(true)).is_ok());

        let inactive = evaluate_runtime_lock(Ok(false)).expect_err("inactive agent must fail");
        assert_eq!(inactive.code, "agent_unavailable");
        assert!(inactive.retryable);

        let check_failure = evaluate_runtime_lock(Err(anyhow::anyhow!("lock unavailable")))
            .expect_err("agent lock probe error must fail");
        assert_eq!(check_failure.code, "agent_state_check_failed");
        assert!(check_failure.retryable);
        assert!(!check_failure.message.contains("lock unavailable"));
    }

    #[test]
    fn health_gate_requires_matching_fresh_healthy_snapshot() -> anyhow::Result<()> {
        let state_dir =
            std::env::temp_dir().join(format!("skybridge-cli-agent-guard-{}", std::process::id()));
        let paths = skybridge_agent::resolve_paths(Some(state_dir))?;
        let now = OffsetDateTime::now_utc();
        let mut healthy = AgentHealthSnapshot::new(
            AgentRuntimeStatus::Healthy,
            std::process::id(),
            paths.root.display().to_string(),
        );
        healthy.updated_at = now;
        assert!(evaluate_health_snapshot(&paths, Some(&healthy), now).is_ok());

        let missing =
            evaluate_health_snapshot(&paths, None, now).expect_err("missing health must fail");
        assert_eq!(missing.code, "agent_health_missing");

        let mut stale = healthy.clone();
        stale.updated_at = now - time::Duration::seconds(MAX_HEALTH_AGE_SECONDS + 1);
        let stale_error = evaluate_health_snapshot(&paths, Some(&stale), now)
            .expect_err("stale health must fail");
        assert_eq!(stale_error.code, "agent_health_stale");

        let mut degraded = healthy.clone();
        degraded.status = AgentRuntimeStatus::Degraded;
        let degraded_error = evaluate_health_snapshot(&paths, Some(&degraded), now)
            .expect_err("degraded health must fail");
        assert_eq!(degraded_error.code, "agent_not_healthy");

        let mut wrong_state_dir = healthy;
        wrong_state_dir.state_dir = "/different/state-dir".to_owned();
        let mismatch = evaluate_health_snapshot(&paths, Some(&wrong_state_dir), now)
            .expect_err("health from a different state directory must fail");
        assert_eq!(mismatch.code, "agent_health_state_dir_mismatch");
        Ok(())
    }

    #[test]
    fn lease_binding_rejects_mismatched_changed_and_empty_instances() -> anyhow::Result<()> {
        let state_dir =
            std::env::temp_dir().join(format!("skybridge-cli-agent-lease-{}", std::process::id()));
        let paths = skybridge_agent::resolve_paths(Some(state_dir))?;
        let health = AgentHealthSnapshot::new(
            AgentRuntimeStatus::Healthy,
            std::process::id(),
            paths.root.display().to_string(),
        );
        let lease = AgentRuntimeLease::new(
            health.instance_id.clone(),
            health.pid,
            paths.root.display().to_string(),
        );
        assert!(evaluate_runtime_lease_binding(&paths, &lease, &health, &lease).is_ok());

        let mismatched_health = AgentHealthSnapshot::new(
            AgentRuntimeStatus::Healthy,
            health.pid,
            paths.root.display().to_string(),
        );
        let mismatch = evaluate_runtime_lease_binding(&paths, &lease, &mismatched_health, &lease)
            .expect_err("different health instance must fail");
        assert_eq!(mismatch.code, "agent_lease_health_mismatch");

        let changed_lease = AgentRuntimeLease::new(
            "replacement-instance",
            health.pid,
            paths.root.display().to_string(),
        );
        let changed = evaluate_runtime_lease_binding(&paths, &lease, &health, &changed_lease)
            .expect_err("lease swap during verification must fail");
        assert_eq!(changed.code, "agent_lease_changed");

        let mut empty_lease = lease.clone();
        empty_lease.instance_id.clear();
        let empty = evaluate_runtime_lease_binding(&paths, &empty_lease, &health, &empty_lease)
            .expect_err("empty lease instance must fail");
        assert_eq!(empty.code, "agent_lease_instance_missing");

        let mut empty_health = health;
        empty_health.instance_id.clear();
        let empty =
            evaluate_health_snapshot(&paths, Some(&empty_health), OffsetDateTime::now_utc())
                .expect_err("empty health instance must fail");
        assert_eq!(empty.code, "agent_health_instance_missing");
        Ok(())
    }

    #[test]
    fn legacy_schema_health_deserializes_but_is_explicitly_rejected() -> anyhow::Result<()> {
        let state_dir = std::env::temp_dir().join("skybridge-cli-agent-legacy-health");
        let paths = skybridge_agent::resolve_paths(Some(state_dir))?;
        let legacy: AgentHealthSnapshot = serde_json::from_value(serde_json::json!({
            "schema_version": 2,
            "status": "healthy",
            "pid": 1,
            "state_dir": paths.root.display().to_string(),
            "started_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "active_sessions": 7,
            "active_transfers": 4,
            "fallback_invocation_count": 2
        }))?;
        let error = evaluate_health_snapshot(&paths, Some(&legacy), legacy.updated_at)
            .expect_err("legacy health schema must not authorize work");
        assert_eq!(error.code, "agent_health_schema_mismatch");
        Ok(())
    }

    #[tokio::test]
    async fn lock_holder_with_unbound_fresh_health_cannot_authorize_work() -> anyhow::Result<()> {
        let state_dir = std::env::temp_dir().join(format!(
            "skybridge-cli-agent-forged-health-{}-{}",
            std::process::id(),
            OffsetDateTime::now_utc().unix_timestamp_nanos()
        ));
        let paths = skybridge_agent::resolve_paths(Some(state_dir))?;
        std::fs::create_dir_all(&paths.runtime_dir)?;
        let lock_file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&paths.agent_runtime_lock_file)?;
        lock_file.lock()?;
        let lease = AgentRuntimeLease::new("lease-owner", 1, paths.root.display().to_string());
        std::fs::write(
            &paths.agent_runtime_lock_file,
            serde_json::to_vec_pretty(&lease)?,
        )?;
        let forged_health = AgentHealthSnapshot::new_for_instance(
            AgentRuntimeStatus::Healthy,
            1,
            paths.root.display().to_string(),
            "different-instance",
        );
        std::fs::write(
            &paths.health_file,
            serde_json::to_vec_pretty(&forged_health)?,
        )?;

        let error = load_active_agent_health(&paths)
            .await
            .expect_err("unbound health must not authorize the lock holder");
        assert_eq!(error.code, "agent_lease_health_mismatch");
        lock_file.unlock()?;
        let _ = std::fs::remove_dir_all(&paths.root);
        Ok(())
    }
}
