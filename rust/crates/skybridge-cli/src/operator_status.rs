use std::path::PathBuf;

use anyhow::{Result, anyhow, bail};
use serde_json::json;
use skybridge_agent::{
    agent_runtime_is_active, ensure_device_identity, load_auth_session, resolve_paths,
};
use skybridge_core::{SignalServerClient, derive_tenant_identifier};
use time::OffsetDateTime;

use crate::agent_runtime_guard::load_active_agent_health;

mod health;

pub(crate) use health::{describe_agent_status, metrics, tail_logs};

pub(crate) async fn doctor(state_dir: Option<PathBuf>, as_json: bool) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let identity = ensure_device_identity(&paths).await?;
    let auth_session = load_auth_session(&paths).await?;
    let signal_server = SignalServerClient::from_env()?;
    let now = OffsetDateTime::now_utc();
    let runtime_lock = agent_runtime_is_active(&paths);
    let runtime_active = runtime_lock.as_ref().is_ok_and(|active| *active);
    let active_health = load_active_agent_health(&paths).await;

    let identity_ok =
        identity.state.schema_version == skybridge_core::LocalIdentityState::SCHEMA_VERSION;
    let auth_ok = auth_session
        .as_ref()
        .is_some_and(|session| derive_tenant_identifier(&session.access_token).is_some());
    let health_freshness = active_health
        .as_ref()
        .ok()
        .map(|value| (now - value.updated_at).whole_seconds())
        .unwrap_or(-1);
    let health_ok = active_health.is_ok();
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

    let checks = json!([
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
            "name": "agent_runtime_lock",
            "ok": runtime_active,
            "detail": match &runtime_lock {
                Ok(true) => "one agent owns the state directory runtime lock".to_owned(),
                Ok(false) => "no agent owns the state directory runtime lock".to_owned(),
                Err(_) => "agent runtime lock probe failed".to_owned(),
            },
        },
        {
            "name": "agent_health",
            "ok": health_ok,
            "detail": match &active_health {
                Ok(_) => format!("lock-owning agent health is schema-valid and fresh ({}s old)", health_freshness),
                Err(error) => format!("agent health verification failed (code: {})", error.code),
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
    ]);
    let check_list = checks
        .as_array()
        .ok_or_else(|| anyhow!("doctor checks shape changed"))?;
    let overall_ok = check_list
        .iter()
        .map(|check| {
            check["ok"]
                .as_bool()
                .ok_or_else(|| anyhow!("doctor check is missing a boolean ok field"))
        })
        .collect::<Result<Vec<_>>>()?
        .into_iter()
        .all(|ok| ok);
    let report = json!({
        "state_dir": paths.root.display().to_string(),
        "overall_ok": overall_ok,
        "checks": checks.clone(),
    });

    if as_json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("State directory: {}", paths.root.display());
        for check in check_list {
            let check_ok = check["ok"]
                .as_bool()
                .ok_or_else(|| anyhow!("doctor check is missing a boolean ok field"))?;
            let name = check["name"]
                .as_str()
                .ok_or_else(|| anyhow!("doctor check is missing its name"))?;
            let detail = check["detail"]
                .as_str()
                .ok_or_else(|| anyhow!("doctor check is missing its detail"))?;
            println!(
                "[{}] {}: {}",
                if check_ok { "OK" } else { "ERROR" },
                name,
                detail
            );
        }
    }
    if !overall_ok {
        bail!("one or more SkyBridge doctor checks failed");
    }
    Ok(())
}
