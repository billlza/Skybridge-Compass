use std::path::PathBuf;

use anyhow::{Result, anyhow};
use serde_json::json;
use skybridge_agent::{
    ensure_device_identity, resolve_paths, signing_binding, update_enrollment_status,
};
use skybridge_core::{
    EnrollmentStatus, ProtocolIdentityBinding, ProtocolSigningAlgorithm, SignalServerClient,
};

mod status;

pub(crate) use status::device_status;

pub(crate) async fn device_enroll(
    state_dir: Option<PathBuf>,
    args: crate::DeviceEnrollArgs,
) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let auth_session = crate::auth_support::require_auth_session(&paths).await?;
    let tenant_id = crate::auth_support::require_tenant_id(&auth_session)?;
    let identity = ensure_device_identity(&paths).await?;
    let binding = signing_binding(&identity)?;
    let signal_server = SignalServerClient::from_env()?;
    let invite_token = args
        .invite_token
        .or_else(|| std::env::var("SKYBRIDGE_ENROLL_INVITE_TOKEN").ok())
        .ok_or_else(|| {
            anyhow!(
                "missing invite token; pass --invite-token or set SKYBRIDGE_ENROLL_INVITE_TOKEN"
            )
        })?;
    let device_name = args
        .device_name
        .clone()
        .unwrap_or_else(|| identity.state.device.device_name.clone());

    let registered = signal_server
        .enroll_first_device(
            &auth_session,
            &tenant_id,
            &binding,
            &invite_token,
            &device_name,
        )
        .await?;
    let identity =
        update_enrollment_status(&paths, EnrollmentStatus::Enrolled, Some(&device_name)).await?;

    if args.output.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "enrolled": true,
                "tenant_id": tenant_id,
                "device": registered,
                "local_identity": identity,
            }))?
        );
    } else {
        println!("Device enrolled");
        println!("Tenant ID: {}", tenant_id);
        println!("Device ID: {}", registered.device_id);
        println!("Status: {}", registered.status);
    }
    Ok(())
}

pub(crate) async fn device_approve(
    state_dir: Option<PathBuf>,
    args: crate::DeviceApproveArgs,
) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let auth_session = crate::auth_support::require_auth_session(&paths).await?;
    let tenant_id = crate::auth_support::require_tenant_id(&auth_session)?;
    let identity = ensure_device_identity(&paths).await?;
    let approver_binding = signing_binding(&identity)?;
    let pending_algorithm = args.pending_algorithm.parse::<ProtocolSigningAlgorithm>()?;
    let pending_binding = ProtocolIdentityBinding::new(
        args.pending_device_id.clone(),
        pending_algorithm,
        match pending_algorithm {
            ProtocolSigningAlgorithm::Ed25519 => vec![0_u8; 32],
            ProtocolSigningAlgorithm::MlDsa65 => vec![1_u8],
        },
        Some(args.pending_fingerprint.clone()),
    )?;
    let signal_server = SignalServerClient::from_env()?;
    let registered = signal_server
        .confirm_device_enrollment(
            &auth_session,
            &tenant_id,
            &approver_binding,
            &pending_binding,
            args.device_name.as_deref().unwrap_or("Approved Device"),
        )
        .await?;

    if args.output.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "confirmed": true,
                "tenant_id": tenant_id,
                "device": registered,
            }))?
        );
    } else {
        println!("Device approved");
        println!("Pending Device ID: {}", registered.device_id);
        println!("Status: {}", registered.status);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn device_enroll_and_approve_fail_before_network_without_auth() -> Result<()> {
        let enroll_dir = make_test_dir("device-enroll-missing-auth")?;
        assert!(
            device_enroll(
                Some(enroll_dir),
                crate::DeviceEnrollArgs {
                    invite_token: Some("invite".to_owned()),
                    device_name: Some("Mac".to_owned()),
                    output: crate::OutputOptions { json: false },
                },
            )
            .await
            .is_err()
        );

        let approve_dir = make_test_dir("device-approve-missing-auth")?;
        assert!(
            device_approve(
                Some(approve_dir),
                crate::DeviceApproveArgs {
                    pending_device_id: "pending-device".to_owned(),
                    pending_algorithm: "ed25519".to_owned(),
                    pending_fingerprint: "fingerprint".to_owned(),
                    device_name: Some("iPhone".to_owned()),
                    output: crate::OutputOptions { json: false },
                },
            )
            .await
            .is_err()
        );
        Ok(())
    }

    fn make_test_dir(name: &str) -> Result<PathBuf> {
        let dir = std::env::temp_dir().join(format!("skybridge-cli-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir)?;
        Ok(dir)
    }
}
