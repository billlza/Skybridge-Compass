use anyhow::{Result, anyhow, bail};
use skybridge_agent::{refresh_auth_session_if_needed, signing_binding, signing_signature};
use skybridge_core::{SignalServerClient, derive_tenant_identifier};

const ENV_PQC_BRIDGE_IDENTITY: &str = "SKYBRIDGE_PQC_BRIDGE_IDENTITY";

pub(crate) fn pqc_bridge_identity_enabled() -> Result<bool> {
    match std::env::var(ENV_PQC_BRIDGE_IDENTITY) {
        Err(std::env::VarError::NotPresent) => parse_pqc_bridge_identity(None),
        Err(std::env::VarError::NotUnicode(_)) => {
            bail!("{ENV_PQC_BRIDGE_IDENTITY} is not valid Unicode")
        }
        Ok(value) => parse_pqc_bridge_identity(Some(&value)),
    }
}

fn parse_pqc_bridge_identity(value: Option<&str>) -> Result<bool> {
    match value.map(|value| value.trim().to_ascii_lowercase()) {
        None => Ok(false),
        Some(value) => match value.as_str() {
            "1" | "true" | "yes" => bail!(
                "{ENV_PQC_BRIDGE_IDENTITY}=true is not supported: the independent PQC handshake identity has no signed binding to the control-plane identity; configure the primary protocol identity as ML-DSA instead"
            ),
            "0" | "false" | "no" => Ok(false),
            _ => bail!("{ENV_PQC_BRIDGE_IDENTITY} must be one of true/false, 1/0, or yes/no"),
        },
    }
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
    bail!(
        "No native CLI auth session found in {}. Run `skybridge login` for the standalone native CLI path, or use `skybridge crossnet connect <code>` to drive the signed Mac app session through crossnet-control/1.",
        paths.identity_dir.display()
    )
}

pub(crate) fn require_tenant_id(session: &skybridge_core::AuthSession) -> Result<String> {
    derive_tenant_identifier(&session.access_token).ok_or_else(|| {
        anyhow!("failed to derive tenant id from access token; set SKYBRIDGE_TENANT_ID if needed")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bridge_identity_configuration_fails_closed_without_a_signed_binding() {
        assert!(!parse_pqc_bridge_identity(None).expect("unset should stay disabled"));
        assert!(!parse_pqc_bridge_identity(Some("false")).expect("false should stay disabled"));
        let unsupported = parse_pqc_bridge_identity(Some("true"))
            .expect_err("an unbound bridge identity must fail closed");
        assert!(unsupported.to_string().contains("no signed binding"));
        assert!(parse_pqc_bridge_identity(Some("sometimes")).is_err());
    }
}
