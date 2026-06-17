use anyhow::{Result, anyhow, bail};
use skybridge_agent::{
    ensure_rust_pqc_identity, refresh_auth_session_if_needed, signing_binding, signing_signature,
};
use skybridge_core::{
    CryptoSuite, PqcResponderConfig, ProtocolIdentityBinding, ProtocolSigningAlgorithm,
    SignalServerClient, derive_tenant_identifier,
};

const ENV_PQC_BRIDGE_IDENTITY: &str = "SKYBRIDGE_PQC_BRIDGE_IDENTITY";

pub(crate) fn pqc_bridge_identity_enabled() -> bool {
    std::env::var(ENV_PQC_BRIDGE_IDENTITY)
        .ok()
        .is_some_and(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes"
            )
        })
}

pub(crate) async fn maybe_inline_pqc_responder_config(
    paths: &skybridge_agent::AgentPaths,
    identity: &skybridge_agent::DeviceIdentityMaterial,
    local_binding: &ProtocolIdentityBinding,
) -> Result<Option<PqcResponderConfig>> {
    if local_binding.protocol_signing_algorithm != ProtocolSigningAlgorithm::MlDsa65
        && !pqc_bridge_identity_enabled()
    {
        return Ok(None);
    }

    let pqc_identity = ensure_rust_pqc_identity(paths).await?;
    let pqc_binding =
        if local_binding.protocol_signing_algorithm == ProtocolSigningAlgorithm::MlDsa65 {
            local_binding.clone()
        } else {
            ProtocolIdentityBinding::new(
                local_binding.device_id.clone(),
                pqc_identity.signing_algorithm,
                pqc_identity.signing_public_key.clone(),
                None,
            )?
        };
    Ok(Some(PqcResponderConfig {
        local_binding: pqc_binding,
        local_device_name: Some(identity.state.device.device_name.clone()),
        identity: pqc_identity,
        supported_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
        policy: skybridge_core::DowngradePolicy::PreferPqc,
    }))
}

pub(crate) async fn request_admission_lease(
    signal_server: &SignalServerClient,
    auth_session: &skybridge_core::AuthSession,
    tenant_id: &str,
    identity: &skybridge_agent::DeviceIdentityMaterial,
) -> Result<skybridge_core::AdmissionLease> {
    let binding = signing_binding(identity)?;
    let challenge = signal_server
        .request_admission_challenge(auth_session, tenant_id, &binding)
        .await?;
    let signature = signing_signature(identity, &challenge.signature_payload())?;
    signal_server
        .complete_admission(auth_session, tenant_id, &challenge, &binding, &signature)
        .await
}

pub(crate) async fn require_auth_session(
    paths: &skybridge_agent::AgentPaths,
) -> Result<skybridge_core::AuthSession> {
    if let Some(session) = refresh_auth_session_if_needed(paths).await? {
        return Ok(session);
    }
    bail!("No auth session found. Run `skybridge login` first.")
}

pub(crate) fn require_tenant_id(session: &skybridge_core::AuthSession) -> Result<String> {
    derive_tenant_identifier(&session.access_token).ok_or_else(|| {
        anyhow!("failed to derive tenant id from access token; set SKYBRIDGE_TENANT_ID if needed")
    })
}
