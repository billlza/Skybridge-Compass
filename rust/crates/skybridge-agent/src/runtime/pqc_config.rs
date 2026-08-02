use std::collections::BTreeMap;

use anyhow::{Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use skybridge_core::{
    BootstrapKemPublicKey, CryptoSuite, PqcInitiatorConfig, PqcResponderConfig,
    ProtocolIdentityBinding, RuntimeSessionRole, RustPqcIdentityMaterial, WebRtcJoinBootstrap,
};

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

fn ensure_pqc_bridge_identity_disabled() -> Result<()> {
    let enabled = match optional_env(ENV_PQC_BRIDGE_IDENTITY)? {
        None => false,
        Some(value) => parse_bridge_identity_value(&value)?,
    };
    reject_pqc_bridge_identity(enabled)
}

fn reject_pqc_bridge_identity(enabled: bool) -> Result<()> {
    if enabled {
        bail!(
            "{ENV_PQC_BRIDGE_IDENTITY}=true is unsupported: the ML-DSA bridge handshake identity has no signed binding to the Ed25519 control-plane identity"
        );
    }
    Ok(())
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

pub(super) async fn build_local_join_bootstrap(
    paths: &AgentPaths,
    local_binding: &ProtocolIdentityBinding,
    local_device_id: &str,
    responder_config: Option<&PqcResponderConfig>,
) -> Result<Option<WebRtcJoinBootstrap>> {
    if local_binding.device_id != local_device_id {
        bail!("managed session local device id does not match the protocol identity binding");
    }
    if !local_binding.protocol_signing_algorithm.is_ml_dsa() {
        return Ok(None);
    }

    let owned_identity;
    let identity = if let Some(config) = responder_config {
        if config.local_binding != *local_binding {
            bail!("PQC responder identity does not match the managed session binding");
        }
        &config.identity
    } else {
        owned_identity =
            ensure_rust_pqc_identity_for_algorithm(paths, local_binding.protocol_signing_algorithm)
                .await?;
        &owned_identity
    };
    build_join_bootstrap_from_identity(local_binding, local_device_id, identity).map(Some)
}

fn build_join_bootstrap_from_identity(
    local_binding: &ProtocolIdentityBinding,
    local_device_id: &str,
    identity: &RustPqcIdentityMaterial,
) -> Result<WebRtcJoinBootstrap> {
    if identity.signing_algorithm != local_binding.protocol_signing_algorithm
        || identity.signing_public_key != local_binding.protocol_public_key_bytes
    {
        bail!("PQC join bootstrap identity does not match the protocol signing authority");
    }
    #[cfg(not(feature = "q-periapt"))]
    let advertised_suites = [CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65];
    #[cfg(feature = "q-periapt")]
    let advertised_suites = [
        CryptoSuite::XWING_MLDSA,
        CryptoSuite::QPERIAPT_CONTEXTBOUND_MLDSA65,
        CryptoSuite::MLKEM768_MLDSA65,
    ];
    let kem_public_keys = advertised_suites
        .into_iter()
        .map(|suite| {
            let public_key = identity
                .public_key_for_suite(suite)
                .ok_or_else(|| anyhow!("missing local KEM public key for {suite}"))?;
            Ok(BootstrapKemPublicKey {
                suite_wire_id: suite.wire_id,
                public_key: public_key.to_vec(),
            })
        })
        .collect::<Result<Vec<_>>>()?;

    WebRtcJoinBootstrap::new(
        local_device_id,
        local_binding.protocol_signing_algorithm,
        local_binding.protocol_public_key_fingerprint.clone(),
        local_binding.protocol_public_key_bytes.clone(),
        kem_public_keys,
        Some(platform_wire_name().to_owned()),
        None,
    )
}

fn platform_wire_name() -> &'static str {
    match std::env::consts::OS {
        "macos" => "macOS",
        "windows" => "Windows",
        "linux" => "Linux",
        platform => platform,
    }
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
    _paths: &AgentPaths,
    identity: &DeviceIdentityMaterial,
    local_binding: &skybridge_core::ProtocolIdentityBinding,
    role: RuntimeSessionRole,
) -> Result<Option<PqcInitiatorConfig>> {
    ensure_pqc_bridge_identity_disabled()?;
    if role != RuntimeSessionRole::Initiator {
        return Ok(None);
    }

    let preferred_suite = preferred_suite_from_env()?;

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

    if !local_binding.protocol_signing_algorithm.is_ml_dsa() {
        if !peer_kem_public_keys.is_empty() || preferred_suite.is_some() {
            bail!(
                "PQC peer pins or suite preferences are configured, but the local protocol identity is {}; select ML-DSA-65 or ML-DSA-87 first",
                local_binding.protocol_signing_algorithm
            );
        }
        return Ok(None);
    }

    let signing_secret_key = identity
        .signing_key
        .ml_dsa_secret_key_bytes()
        .ok_or_else(|| {
            anyhow!(
                "missing {} signing secret key",
                local_binding.protocol_signing_algorithm
            )
        })?;
    #[cfg(not(feature = "q-periapt"))]
    let candidates = vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65];
    #[cfg(feature = "q-periapt")]
    let candidates = vec![
        CryptoSuite::XWING_MLDSA,
        CryptoSuite::QPERIAPT_CONTEXTBOUND_MLDSA65,
        CryptoSuite::MLKEM768_MLDSA65,
    ];

    let mut preferred_suites = Vec::new();
    if let Some(preferred_suite) = preferred_suite {
        if !candidates.contains(&preferred_suite) {
            bail!("preferred PQC suite {preferred_suite} is not enabled in this build");
        }
        preferred_suites.push(preferred_suite);
    }
    for candidate in candidates {
        if !preferred_suites.contains(&candidate) {
            preferred_suites.push(candidate);
        }
    }

    Ok(Some(PqcInitiatorConfig {
        local_binding: local_binding.clone(),
        signing_secret_key,
        local_device_name: Some(identity.state.device.device_name.clone()),
        preferred_suites,
        // These environment values are optional pins. The authoritative peer
        // KEM set is learned from the validated signaling Join and each supplied
        // pin must match it exactly before MessageA can be created.
        peer_kem_public_keys,
        // The ML-DSA identity has no independently bound Ed25519 fallback key;
        // an unavailable or invalid PQC Join therefore fails closed.
        policy: skybridge_core::DowngradePolicy::PreferPqc,
    }))
}

pub(super) async fn build_pqc_responder_config(
    paths: &AgentPaths,
    identity: &DeviceIdentityMaterial,
    local_binding: &skybridge_core::ProtocolIdentityBinding,
    role: RuntimeSessionRole,
) -> Result<Option<PqcResponderConfig>> {
    ensure_pqc_bridge_identity_disabled()?;
    if role != RuntimeSessionRole::Responder {
        return Ok(None);
    }
    if !local_binding.protocol_signing_algorithm.is_ml_dsa() {
        return Ok(None);
    }

    let handshake_algorithm = local_binding.protocol_signing_algorithm;
    let pqc_identity = ensure_rust_pqc_identity_for_algorithm(paths, handshake_algorithm).await?;
    Ok(Some(PqcResponderConfig {
        local_binding: local_binding.clone(),
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
    fn local_pqc_join_bootstrap_exports_canonical_identity_and_kem_keys() -> Result<()> {
        let identity = RustPqcIdentityMaterial::generate()?;
        let device_id = "device-local-0001";
        let binding = ProtocolIdentityBinding::new(
            device_id,
            identity.signing_algorithm,
            identity.signing_public_key.clone(),
            None,
        )?;

        let bootstrap = build_join_bootstrap_from_identity(&binding, device_id, &identity)?;

        assert_eq!(
            bootstrap.protocol_public_key_fingerprint,
            binding.protocol_public_key_fingerprint
        );
        assert_eq!(
            bootstrap.protocol_public_key_bytes,
            identity.signing_public_key
        );
        #[cfg(not(feature = "q-periapt"))]
        let expected_suites = vec![
            CryptoSuite::XWING_MLDSA.wire_id,
            CryptoSuite::MLKEM768_MLDSA65.wire_id,
        ];
        #[cfg(feature = "q-periapt")]
        let expected_suites = vec![
            CryptoSuite::XWING_MLDSA.wire_id,
            CryptoSuite::QPERIAPT_CONTEXTBOUND_MLDSA65.wire_id,
            CryptoSuite::MLKEM768_MLDSA65.wire_id,
        ];
        assert_eq!(
            bootstrap
                .kem_public_keys
                .iter()
                .map(|key| key.suite_wire_id)
                .collect::<Vec<_>>(),
            expected_suites
        );
        assert_eq!(
            bootstrap.kem_public_keys[0].public_key,
            identity.xwing_public_key
        );
        assert_eq!(
            bootstrap
                .kem_public_keys
                .last()
                .map(|key| key.public_key.as_slice()),
            Some(identity.mlkem768_public_key.as_slice())
        );
        assert_eq!(bootstrap.platform.as_deref(), Some(platform_wire_name()));
        Ok(())
    }

    #[test]
    fn local_pqc_join_bootstrap_rejects_identity_authority_mismatch() -> Result<()> {
        let identity = RustPqcIdentityMaterial::generate()?;
        let other_identity = RustPqcIdentityMaterial::generate()?;
        let device_id = "device-local-0001";
        let mismatched_binding = ProtocolIdentityBinding::new(
            device_id,
            other_identity.signing_algorithm,
            other_identity.signing_public_key,
            None,
        )?;

        let error = build_join_bootstrap_from_identity(&mismatched_binding, device_id, &identity)
            .expect_err("mismatched signing authority must fail closed");
        assert!(error.to_string().contains("does not match"));
        Ok(())
    }

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
    fn bridge_identity_true_is_not_a_supported_runtime_mode() {
        let enabled = parse_bridge_identity_value("true").unwrap();
        assert!(
            enabled,
            "parser must preserve the explicit operator request"
        );
        let error =
            reject_pqc_bridge_identity(enabled).expect_err("bridge identity mode must fail closed");
        assert!(error.to_string().contains("has no signed binding"));
        reject_pqc_bridge_identity(false).expect("explicit false must remain allowed");
    }

    #[test]
    fn base64_peer_key_decoder_never_maps_invalid_data_to_an_empty_key() {
        let result = STANDARD.decode(b"%%%invalid-base64%%%");
        assert!(result.is_err());
    }
}
