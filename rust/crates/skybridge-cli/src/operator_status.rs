use std::path::PathBuf;

use anyhow::{Result, anyhow};
use serde_json::json;
use skybridge_agent::{
    ensure_device_identity, load_auth_session, load_health_snapshot, resolve_paths,
};
use skybridge_core::{SignalServerClient, derive_tenant_identifier};
use time::OffsetDateTime;

mod health;

pub(crate) use health::{describe_agent_status, metrics, tail_logs};

pub(crate) async fn doctor(state_dir: Option<PathBuf>, as_json: bool) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let identity = ensure_device_identity(&paths).await?;
    let health = load_health_snapshot(&paths).await?;
    let auth_session = load_auth_session(&paths).await?;
    let signal_server = SignalServerClient::from_env()?;
    let now = OffsetDateTime::now_utc();

    let identity_ok =
        identity.state.schema_version == skybridge_core::LocalIdentityState::SCHEMA_VERSION;
    let auth_ok = auth_session
        .as_ref()
        .is_some_and(|session| derive_tenant_identifier(&session.access_token).is_some());
    let health_freshness = health
        .as_ref()
        .map(|value| (now - value.updated_at).whole_seconds())
        .unwrap_or(-1);
    let health_ok = health.as_ref().is_some_and(|value| {
        value.schema_version == skybridge_core::AgentHealthSnapshot::SCHEMA_VERSION
            && health_freshness <= 10
    });
    let log_exists = tokio::fs::try_exists(&paths.log_file).await?;
    let control_plane_health = signal_server.probe_health().await;
    let control_plane_ok = control_plane_health.is_ok();
    let control_plane_detail = match &control_plane_health {
        Ok(snapshot) => format!(
            "reachable via {} (status={} instance={} backend={})",
            signal_server.base_url,
            snapshot.status,
            snapshot.instance_id.as_deref().unwrap_or("unknown"),
            snapshot.state_backend.as_deref().unwrap_or("unknown")
        ),
        Err(error) => format!(
            "control-plane probe failed against {}: {}",
            signal_server.base_url, error
        ),
    };

    let report = json!({
        "state_dir": paths.root.display().to_string(),
        "checks": [
            {
                "name": "state_directory",
                "ok": tokio::fs::try_exists(&paths.root).await?,
                "detail": "state directory is resolved and accessible",
            },
            {
                "name": "device_identity",
                "ok": identity_ok,
                "detail": if identity_ok {
                    "device identity and signing key are present"
                } else {
                    "device identity missing or schema-mismatched"
                },
            },
            {
                "name": "auth_session",
                "ok": auth_ok,
                "detail": if auth_ok {
                    "auth session present and tenant derivation succeeded"
                } else {
                    "auth session missing or tenant derivation failed; run `skybridge login`"
                },
            },
            {
                "name": "agent_health",
                "ok": health_ok,
                "detail": if health_ok {
                    format!("health snapshot is fresh ({}s old)", health_freshness)
                } else if health.is_some() {
                    format!("health snapshot is stale ({}s old)", health_freshness)
                } else {
                    "health snapshot missing; start the agent in foreground or background".to_owned()
                },
            },
            {
                "name": "agent_log",
                "ok": log_exists,
                "detail": if log_exists {
                    "structured log file exists".to_owned()
                } else {
                    "structured log file missing; run the agent once to create it".to_owned()
                },
            },
            {
                "name": "control_plane",
                "ok": control_plane_ok,
                "detail": control_plane_detail,
            }
        ]
    });

    if as_json {
        println!("{}", serde_json::to_string_pretty(&report)?);
        return Ok(());
    }

    println!("State directory: {}", paths.root.display());
    for check in report["checks"]
        .as_array()
        .ok_or_else(|| anyhow!("doctor report shape changed"))?
    {
        let status = if check["ok"].as_bool().unwrap_or(false) {
            "OK"
        } else {
            "WARN"
        };
        println!(
            "[{}] {}: {}",
            status,
            check["name"].as_str().unwrap_or("unknown"),
            check["detail"].as_str().unwrap_or("")
        );
    }
    Ok(())
}
