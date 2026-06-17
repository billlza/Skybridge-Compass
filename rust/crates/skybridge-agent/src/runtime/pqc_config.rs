use std::collections::BTreeMap;

use anyhow::{Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use skybridge_core::{CryptoSuite, PqcInitiatorConfig, PqcResponderConfig, RuntimeSessionRole};
use tracing::warn;

use crate::state::{DeviceIdentityMaterial, ensure_rust_pqc_identity};

use super::AgentPaths;

const ENV_PEER_MLKEM768_PUBLIC_KEY_B64: &str = "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64";
const ENV_PEER_XWING_PUBLIC_KEY_B64: &str = "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64";
const ENV_PQC_PREFERRED_SUITE: &str = "SKYBRIDGE_PQC_PREFERRED_SUITE";
const ENV_PQC_BRIDGE_IDENTITY: &str = "SKYBRIDGE_PQC_BRIDGE_IDENTITY";

fn pqc_bridge_identity_enabled() -> bool {
    std::env::var(ENV_PQC_BRIDGE_IDENTITY)
        .ok()
        .is_some_and(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes"
            )
        })
}

pub(super) async fn build_pqc_initiator_config_from_env(
    paths: &AgentPaths,
    identity: &DeviceIdentityMaterial,
    local_binding: &skybridge_core::ProtocolIdentityBinding,
    role: RuntimeSessionRole,
) -> Result<Option<PqcInitiatorConfig>> {
    if role != RuntimeSessionRole::Initiator {
        return Ok(None);
    }

    let mut peer_kem_public_keys = BTreeMap::new();
    if let Some(value) = std::env::var(ENV_PEER_XWING_PUBLIC_KEY_B64)
        .ok()
        .filter(|value| !value.trim().is_empty())
    {
        peer_kem_public_keys.insert(
            CryptoSuite::XWING_MLDSA,
            STANDARD
                .decode(value.trim().as_bytes())
                .map_err(|error| anyhow!("invalid X-Wing peer public key: {error}"))?,
        );
    }
    if let Some(value) = std::env::var(ENV_PEER_MLKEM768_PUBLIC_KEY_B64)
        .ok()
        .filter(|value| !value.trim().is_empty())
    {
        peer_kem_public_keys.insert(
            CryptoSuite::MLKEM768_MLDSA65,
            STANDARD
                .decode(value.trim().as_bytes())
                .map_err(|error| anyhow!("invalid ML-KEM-768 peer public key: {error}"))?,
        );
    }

    let bridge_identity = pqc_bridge_identity_enabled();

    if peer_kem_public_keys.is_empty() {
        if local_binding.protocol_signing_algorithm
            == skybridge_core::ProtocolSigningAlgorithm::MlDsa65
            || bridge_identity
        {
            bail!(
                "ML-DSA-65 protocol identity selected but no peer PQC public keys are configured via {} or {}",
                ENV_PEER_XWING_PUBLIC_KEY_B64,
                ENV_PEER_MLKEM768_PUBLIC_KEY_B64
            );
        }
        return Ok(None);
    }

    let (pqc_binding, signing_secret_key) = if local_binding.protocol_signing_algorithm
        == skybridge_core::ProtocolSigningAlgorithm::MlDsa65
    {
        let signing_secret_key = identity
            .signing_key
            .mldsa65_secret_key_bytes()
            .ok_or_else(|| anyhow!("missing ML-DSA-65 signing secret key"))?;
        (local_binding.clone(), signing_secret_key)
    } else if bridge_identity {
        let pqc_identity = ensure_rust_pqc_identity(paths).await?;
        warn!(
            kind = "agent.session.pqc_bridge_identity_enabled",
            device_id = %local_binding.device_id,
            control_plane_algorithm = %local_binding.protocol_signing_algorithm,
            handshake_algorithm = %pqc_identity.signing_algorithm,
            "using bridge PQC handshake identity separate from control-plane identity"
        );
        (
            skybridge_core::ProtocolIdentityBinding::new(
                local_binding.device_id.clone(),
                pqc_identity.signing_algorithm,
                pqc_identity.signing_public_key.clone(),
                None,
            )
            .map_err(anyhow::Error::from)?,
            pqc_identity.signing_secret_key,
        )
    } else {
        bail!(
            "peer PQC public keys are configured, but the local protocol identity is {}; set SKYBRIDGE_PROTOCOL_SIGNING_ALGORITHM=ML-DSA-65 first",
            local_binding.protocol_signing_algorithm
        );
    };
    let preferred_suite = std::env::var(ENV_PQC_PREFERRED_SUITE)
        .ok()
        .and_then(|value| CryptoSuite::from_name(&value));
    let mut preferred_suites = Vec::new();
    if let Some(preferred_suite) = preferred_suite
        && peer_kem_public_keys.contains_key(&preferred_suite)
    {
        preferred_suites.push(preferred_suite);
    }
    for candidate in [CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65] {
        if peer_kem_public_keys.contains_key(&candidate) && !preferred_suites.contains(&candidate) {
            preferred_suites.push(candidate);
        }
    }

    Ok(Some(PqcInitiatorConfig {
        local_binding: pqc_binding,
        signing_secret_key,
        local_device_name: Some(identity.state.device.device_name.clone()),
        preferred_suites,
        peer_kem_public_keys,
        // Prefer PQC, allow a gated/rate-limited local classic fallback.
        policy: skybridge_core::DowngradePolicy::PreferPqc,
    }))
}

pub(super) async fn build_pqc_responder_config(
    paths: &AgentPaths,
    identity: &DeviceIdentityMaterial,
    local_binding: &skybridge_core::ProtocolIdentityBinding,
    role: RuntimeSessionRole,
) -> Result<Option<PqcResponderConfig>> {
    if role != RuntimeSessionRole::Responder {
        return Ok(None);
    }
    let bridge_identity = pqc_bridge_identity_enabled();
    if local_binding.protocol_signing_algorithm != skybridge_core::ProtocolSigningAlgorithm::MlDsa65
        && !bridge_identity
    {
        return Ok(None);
    }

    let pqc_identity = ensure_rust_pqc_identity(paths).await?;
    let pqc_binding = if local_binding.protocol_signing_algorithm
        == skybridge_core::ProtocolSigningAlgorithm::MlDsa65
    {
        local_binding.clone()
    } else {
        warn!(
            kind = "agent.session.pqc_bridge_identity_enabled",
            device_id = %local_binding.device_id,
            control_plane_algorithm = %local_binding.protocol_signing_algorithm,
            handshake_algorithm = %pqc_identity.signing_algorithm,
            "using bridge PQC responder identity separate from control-plane identity"
        );
        skybridge_core::ProtocolIdentityBinding::new(
            local_binding.device_id.clone(),
            pqc_identity.signing_algorithm,
            pqc_identity.signing_public_key.clone(),
            None,
        )
        .map_err(anyhow::Error::from)?
    };
    Ok(Some(PqcResponderConfig {
        local_binding: pqc_binding,
        local_device_name: Some(identity.state.device.device_name.clone()),
        identity: pqc_identity,
        supported_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
        policy: skybridge_core::DowngradePolicy::PreferPqc,
    }))
}
