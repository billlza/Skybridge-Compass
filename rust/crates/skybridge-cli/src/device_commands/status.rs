use std::path::PathBuf;

use anyhow::Result;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::json;
use skybridge_agent::{
    ensure_device_identity, ensure_rust_pqc_identity_for_algorithm, load_auth_session,
    load_health_snapshot, resolve_paths,
};
use skybridge_core::{
    AuthState, CryptoSuite, EnrollmentStatus, ProtocolIdentityBinding, ProtocolSigningAlgorithm,
    derive_tenant_identifier,
};

use crate::operator_status::describe_agent_status;

async fn maybe_pqc_identity_report(
    paths: &skybridge_agent::AgentPaths,
    identity: &skybridge_agent::DeviceIdentityMaterial,
) -> Result<Option<serde_json::Value>> {
    let bridge_identity = crate::auth_support::pqc_bridge_identity_enabled()?;
    if !identity.state.device.protocol_signing_algorithm.is_ml_dsa() && !bridge_identity {
        return Ok(None);
    }

    let signing_algorithm = if identity.state.device.protocol_signing_algorithm.is_ml_dsa() {
        identity.state.device.protocol_signing_algorithm
    } else {
        ProtocolSigningAlgorithm::MlDsa65
    };
    let pqc_identity = ensure_rust_pqc_identity_for_algorithm(paths, signing_algorithm).await?;
    Ok(Some(json!({
        "signing_algorithm": pqc_identity.signing_algorithm,
        "supported_suites": [
            CryptoSuite::XWING_MLDSA.to_string(),
            CryptoSuite::MLKEM768_MLDSA65.to_string(),
        ],
        "signing_public_key_base64": STANDARD.encode(&pqc_identity.signing_public_key),
        "signing_public_key_fingerprint": ProtocolIdentityBinding::compute_fingerprint(
            pqc_identity.signing_algorithm,
            &pqc_identity.signing_public_key,
        ),
        "kem_public_keys": [
            {
                "suite": CryptoSuite::XWING_MLDSA.to_string(),
                "wire_id": format!("{:#06x}", CryptoSuite::XWING_MLDSA.wire_id),
                "public_key_base64": STANDARD.encode(&pqc_identity.xwing_public_key),
            },
            {
                "suite": CryptoSuite::MLKEM768_MLDSA65.to_string(),
                "wire_id": format!("{:#06x}", CryptoSuite::MLKEM768_MLDSA65.wire_id),
                "public_key_base64": STANDARD.encode(&pqc_identity.mlkem768_public_key),
            }
        ],
        "bootstrap_env": {
            "SKYBRIDGE_PROTOCOL_SIGNING_ALGORITHM": pqc_identity.signing_algorithm.as_str(),
            "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64": STANDARD.encode(&pqc_identity.xwing_public_key),
            "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64": STANDARD.encode(&pqc_identity.mlkem768_public_key),
        }
    })))
}

pub(crate) async fn device_status(state_dir: Option<PathBuf>, as_json: bool) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let identity = ensure_device_identity(&paths).await?;
    let health = load_health_snapshot(&paths).await?;
    let auth_session = load_auth_session(&paths).await?;
    let tenant_id = auth_session
        .as_ref()
        .and_then(|session| derive_tenant_identifier(&session.access_token));
    let pqc_identity = maybe_pqc_identity_report(&paths, &identity).await?;

    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "schema_version": identity.state.schema_version,
                "account_id": identity.state.account_id,
                "auth_state": identity.state.auth_state,
                "tenant_id": tenant_id,
                "device": identity.state.device,
                "pqc_identity": pqc_identity,
                "agent_health": health,
            }))?
        );
        return Ok(());
    }

    println!("Device ID: {}", identity.state.device.device_id);
    println!("Device Name: {}", identity.state.device.device_name);
    println!(
        "Enrollment: {}",
        describe_enrollment(identity.state.device.enrollment_status)
    );
    println!("Auth State: {}", describe_auth(identity.state.auth_state));
    println!(
        "Algorithm: {}",
        identity.state.device.protocol_signing_algorithm
    );
    println!(
        "Fingerprint: {}",
        identity
            .state
            .device
            .public_key_fingerprint
            .as_deref()
            .unwrap_or("<pending>")
    );
    println!(
        "Tenant ID: {}",
        tenant_id.as_deref().unwrap_or("<unresolved>")
    );
    if let Some(pqc_identity) = pqc_identity {
        let suites = pqc_identity["supported_suites"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|value| value.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        println!(
            "PQC: {}",
            if suites.is_empty() {
                "enabled"
            } else {
                &suites
            }
        );
    }
    if let Some(health) = health {
        println!(
            "Agent: {} (updated {})",
            describe_agent_status(health.status),
            health.updated_at
        );
    } else {
        println!("Agent: no health snapshot yet");
    }
    Ok(())
}

fn describe_enrollment(status: EnrollmentStatus) -> &'static str {
    match status {
        EnrollmentStatus::Unenrolled => "unenrolled",
        EnrollmentStatus::PendingApproval => "pending_approval",
        EnrollmentStatus::Enrolled => "enrolled",
    }
}

fn describe_auth(state: AuthState) -> &'static str {
    match state {
        AuthState::LoggedOut => "logged_out",
        AuthState::LoggedIn => "logged_in",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn device_status_reports_local_identity_without_auth() -> Result<()> {
        let state_dir = make_test_dir("device-status")?;

        device_status(Some(state_dir.clone()), false).await?;
        device_status(Some(state_dir), true).await
    }

    #[test]
    fn presentation_helpers_cover_device_status_text() {
        assert_eq!(
            describe_enrollment(EnrollmentStatus::Unenrolled),
            "unenrolled"
        );
        assert_eq!(
            describe_enrollment(EnrollmentStatus::PendingApproval),
            "pending_approval"
        );
        assert_eq!(describe_enrollment(EnrollmentStatus::Enrolled), "enrolled");
        assert_eq!(describe_auth(AuthState::LoggedOut), "logged_out");
        assert_eq!(describe_auth(AuthState::LoggedIn), "logged_in");
    }

    fn make_test_dir(name: &str) -> Result<PathBuf> {
        let dir = std::env::temp_dir().join(format!("skybridge-cli-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir)?;
        Ok(dir)
    }
}
