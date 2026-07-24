use std::collections::BTreeMap;

use anyhow::{Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use skybridge_core::{
    CryptoSuite, PqcInitiatorConfig, PqcResponderConfig, ProtocolSigningAlgorithm,
    RuntimeSessionRole,
};
use tracing::warn;

use crate::state::{DeviceIdentityMaterial, ensure_rust_pqc_identity_for_algorithm};

use super::AgentPaths;

const ENV_PEER_MLKEM768_PUBLIC_KEY_B64: &str = "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64";
const ENV_PEER_XWING_PUBLIC_KEY_B64: &str = "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64";
/// EXPERIMENTAL, DEFAULT-OFF: peer public key for the Q-Periapt ContextBound
/// suite. It is accepted only when skybridge-core is built with the `q-periapt`
/// feature; configuring it in a shipping build fails before handshake setup.
const ENV_PEER_QPERIAPT_PUBLIC_KEY_B64: &str = "SKYBRIDGE_PQC_PEER_QPERIAPT_PUBLIC_KEY_BASE64";
const ENV_PQC_PREFERRED_SUITE: &str = "SKYBRIDGE_PQC_PREFERRED_SUITE";
const ENV_PQC_BRIDGE_IDENTITY: &str = "SKYBRIDGE_PQC_BRIDGE_IDENTITY";

fn pqc_bridge_identity_enabled() -> Result<bool> {
    match optional_env(ENV_PQC_BRIDGE_IDENTITY)? {
        None => Ok(false),
        Some(value) => parse_bridge_identity_value(&value),
    }
}

fn parse_bridge_identity_value(value: &str) -> Result<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" => Ok(true),
        "0" | "false" | "no" => Ok(false),
        _ => bail!("{ENV_PQC_BRIDGE_IDENTITY} must be one of true/false, 1/0, or yes/no"),
    }
}

fn optional_env(name: &str) -> Result<Option<String>> {
    match std::env::var(name) {
        Ok(value) => {
            let value = value.trim();
            if value.is_empty() {
                bail!("{name} must not be empty when set");
            }
            Ok(Some(value.to_owned()))
        }
        Err(std::env::VarError::NotPresent) => Ok(None),
        Err(std::env::VarError::NotUnicode(_)) => bail!("{name} is not valid Unicode"),
    }
}

fn decode_optional_peer_key(name: &str, description: &str) -> Result<Option<Vec<u8>>> {
    optional_env(name)?
        .map(|value| {
            STANDARD
                .decode(value.as_bytes())
                .map_err(|error| anyhow!("invalid {description}: {error}"))
        })
        .transpose()
}

fn preferred_suite_from_env() -> Result<Option<CryptoSuite>> {
    optional_env(ENV_PQC_PREFERRED_SUITE)?
        .map(|value| parse_preferred_suite_value(&value))
        .transpose()
}

fn parse_preferred_suite_value(value: &str) -> Result<CryptoSuite> {
    CryptoSuite::from_name(value).ok_or_else(|| anyhow!("unknown PQC preferred suite {value:?}"))
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
    if let Some(public_key) =
        decode_optional_peer_key(ENV_PEER_XWING_PUBLIC_KEY_B64, "X-Wing peer public key")?
    {
        peer_kem_public_keys.insert(CryptoSuite::XWING_MLDSA, public_key);
    }
    if let Some(public_key) = decode_optional_peer_key(
        ENV_PEER_MLKEM768_PUBLIC_KEY_B64,
        "ML-KEM-768 peer public key",
    )? {
        peer_kem_public_keys.insert(CryptoSuite::MLKEM768_MLDSA65, public_key);
    }
    // EXPERIMENTAL, DEFAULT-OFF: register a Q-Periapt ContextBound peer key if the
    // operator supplied one, so the suite is selectable when preferred.
    #[cfg(feature = "q-periapt")]
    if let Some(public_key) = decode_optional_peer_key(
        ENV_PEER_QPERIAPT_PUBLIC_KEY_B64,
        "Q-Periapt peer public key",
    )? {
        peer_kem_public_keys.insert(CryptoSuite::QPERIAPT_CONTEXTBOUND_MLDSA65, public_key);
    }
    #[cfg(not(feature = "q-periapt"))]
    if optional_env(ENV_PEER_QPERIAPT_PUBLIC_KEY_B64)?.is_some() {
        bail!("{ENV_PEER_QPERIAPT_PUBLIC_KEY_B64} requires the q-periapt build feature");
    }

    let bridge_identity = pqc_bridge_identity_enabled()?;

    if peer_kem_public_keys.is_empty() {
        if local_binding.protocol_signing_algorithm.is_ml_dsa() || bridge_identity {
            bail!(
                "{} protocol identity selected but no peer PQC public keys are configured via {} or {}",
                local_binding.protocol_signing_algorithm,
                ENV_PEER_XWING_PUBLIC_KEY_B64,
                ENV_PEER_MLKEM768_PUBLIC_KEY_B64
            );
        }
        return Ok(None);
    }

    let (pqc_binding, signing_secret_key) = if local_binding.protocol_signing_algorithm.is_ml_dsa()
    {
        let signing_secret_key =
            identity
                .signing_key
                .ml_dsa_secret_key_bytes()
                .ok_or_else(|| {
                    anyhow!(
                        "missing {} signing secret key",
                        local_binding.protocol_signing_algorithm
                    )
                })?;
        (local_binding.clone(), signing_secret_key)
    } else if bridge_identity {
        let pqc_identity =
            ensure_rust_pqc_identity_for_algorithm(paths, ProtocolSigningAlgorithm::MlDsa65)
                .await?;
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
            "peer PQC public keys are configured, but the local protocol identity is {}; select ML-DSA-65 or ML-DSA-87 first",
            local_binding.protocol_signing_algorithm
        );
    };
    let preferred_suite = preferred_suite_from_env()?;
    let mut preferred_suites = Vec::new();
    if let Some(preferred_suite) = preferred_suite {
        if !peer_kem_public_keys.contains_key(&preferred_suite) {
            bail!("preferred PQC suite {preferred_suite} has no configured peer public key");
        }
        preferred_suites.push(preferred_suite);
    }
    #[cfg(not(feature = "q-periapt"))]
    let candidates = vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65];
    #[cfg(feature = "q-periapt")]
    let candidates = vec![
        CryptoSuite::XWING_MLDSA,
        CryptoSuite::QPERIAPT_CONTEXTBOUND_MLDSA65,
        CryptoSuite::MLKEM768_MLDSA65,
    ];
    for candidate in candidates {
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
    let bridge_identity = pqc_bridge_identity_enabled()?;
    if !local_binding.protocol_signing_algorithm.is_ml_dsa() && !bridge_identity {
        return Ok(None);
    }

    let handshake_algorithm = if local_binding.protocol_signing_algorithm.is_ml_dsa() {
        local_binding.protocol_signing_algorithm
    } else {
        ProtocolSigningAlgorithm::MlDsa65
    };
    let pqc_identity = ensure_rust_pqc_identity_for_algorithm(paths, handshake_algorithm).await?;
    let pqc_binding = if local_binding.protocol_signing_algorithm.is_ml_dsa() {
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
        supported_suites: {
            // The agent advertises the Q-Periapt ContextBound suite only when skybridge-core is
            // built with the `q-periapt` feature; otherwise the shipping suite set is unchanged.
            #[cfg(not(feature = "q-periapt"))]
            let suites = vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65];
            #[cfg(feature = "q-periapt")]
            let suites = vec![
                CryptoSuite::XWING_MLDSA,
                CryptoSuite::MLKEM768_MLDSA65,
                CryptoSuite::QPERIAPT_CONTEXTBOUND_MLDSA65,
            ];
            suites
        },
        policy: skybridge_core::DowngradePolicy::PreferPqc,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preferred_suite_parser_accepts_known_values_and_rejects_unknown_values() {
        assert_eq!(
            parse_preferred_suite_value("X-Wing").unwrap(),
            CryptoSuite::XWING_MLDSA
        );
        assert!(parse_preferred_suite_value("not-a-suite").is_err());
    }

    #[test]
    fn bridge_identity_parser_is_explicit_and_fail_closed() {
        assert!(parse_bridge_identity_value("true").unwrap());
        assert!(!parse_bridge_identity_value("0").unwrap());
        assert!(parse_bridge_identity_value("").is_err());
        assert!(parse_bridge_identity_value("enabled").is_err());
    }

    #[test]
    fn base64_peer_key_decoder_never_maps_invalid_data_to_an_empty_key() {
        let result = STANDARD.decode(b"%%%invalid-base64%%%");
        assert!(result.is_err());
    }
}
