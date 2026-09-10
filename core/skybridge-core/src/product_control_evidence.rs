use serde::Deserialize;
use thiserror::Error;

pub const MAX_PRODUCT_CONTROL_EVIDENCE_BYTES: u64 = 256 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProductControlProofLevel {
    TransportOnly,
    AppControlSbwcPingPong,
}

impl ProductControlProofLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::TransportOnly => "transport_only",
            Self::AppControlSbwcPingPong => "appcontrol_sbwc_ping_pong",
        }
    }

    pub fn handshake_proof(self) -> bool {
        matches!(self, Self::AppControlSbwcPingPong)
    }

    pub fn app_control_proof(self) -> bool {
        matches!(self, Self::AppControlSbwcPingPong)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProductControlEvidenceSummary {
    pub profile: String,
    pub evidence_scope: String,
    pub status: String,
    pub role: String,
    pub signaling_exchange_role: String,
    pub helper_mode: String,
    pub secure_session_state: String,
    pub proof_level: ProductControlProofLevel,
    pub remote_identity_source: String,
    pub remote_identity_server_attested: bool,
    pub not_remote_identity_proof: bool,
    pub not_mac_product_app_proof: bool,
    pub remote_product_app_observed: bool,
    pub peer_trust_persistence_proof: bool,
    pub product_send_count: u64,
    pub product_receive_count: u64,
    pub late_remote_ice_candidate_relay_count: u64,
    pub recorded_at_present: bool,
    pub session_id_sha256: Option<String>,
    pub remote_device_id_sha256: Option<String>,
    pub remote_protocol_public_key_fingerprint: Option<String>,
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum ProductControlEvidenceError {
    #[error("product-control evidence JSON parse failed.")]
    Json,
    #[error("product-control evidence schema is unsupported.")]
    UnsupportedSchema,
    #[error("product-control evidence requires a {0}.")]
    MissingField(&'static str),
    #[error("product-control evidence {0} is invalid.")]
    InvalidField(&'static str),
    #[error("product-control evidence steps are incomplete.")]
    IncompleteSteps,
    #[error("product-control evidence proof boundary is invalid.")]
    BoundaryInvalid,
    #[error("product-control evidence reports captured secret-bearing inputs.")]
    SecretCaptureDetected,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ProductControlEvidenceDocument {
    evidence_version: Option<u32>,
    profile: Option<String>,
    evidence_scope: Option<String>,
    status: Option<String>,
    steps: Option<ProductControlSteps>,
    header_values_captured: Option<bool>,
    secret_inputs_captured: Option<bool>,
    connection_code_captured: Option<bool>,
    query_token_present: Option<bool>,
    bound: Option<bool>,
    role: Option<String>,
    signaling_exchange_role: Option<String>,
    helper_mode: Option<String>,
    remote_signal_wait_type: Option<String>,
    secure_session_state: Option<String>,
    data_channel_label: Option<String>,
    late_remote_ice_candidate_relay_count: Option<u64>,
    product_send_count: Option<u64>,
    product_receive_count: Option<u64>,
    remote_identity_source: Option<String>,
    remote_identity_server_attested: Option<bool>,
    not_remote_identity_proof: Option<bool>,
    negotiated_suite_wire_id: Option<String>,
    policy_require_pqc: Option<bool>,
    policy_allow_classic_fallback: Option<bool>,
    responder_identity_fingerprint_verified: Option<bool>,
    responder_signature_verified: Option<bool>,
    responder_finished_verified: Option<bool>,
    initiator_finished_sent: Option<bool>,
    initiator_identity_fingerprint_verified: Option<bool>,
    initiator_signature_verified: Option<bool>,
    responder_finished_sent: Option<bool>,
    initiator_finished_verified: Option<bool>,
    app_control_packet_type: Option<String>,
    app_control_crypto_format: Option<String>,
    app_control_payload_format: Option<String>,
    app_control_sbwc_envelope: Option<bool>,
    app_control_sbwc_counter_present: Option<bool>,
    app_control_replay_protection: Option<String>,
    app_control_legacy_nonce_length: Option<u64>,
    app_control_legacy_tag_length: Option<u64>,
    app_control_legacy_aad_length: Option<u64>,
    app_control_legacy_combined_layout: Option<String>,
    authenticated_app_control_ping_pong_proof: Option<bool>,
    app_control_received_message_kind: Option<String>,
    app_control_response_message_kind: Option<String>,
    app_control_pong_id_matches: Option<bool>,
    app_control_outbound_counter: Option<u64>,
    app_control_inbound_counter: Option<u64>,
    app_control_session_hash: Option<String>,
    app_control_transcript_prefix: Option<String>,
    session_id_sha256: Option<String>,
    remote_device_id_sha256: Option<String>,
    remote_protocol_public_key_fingerprint: Option<String>,
    peer_ml_kem768_public_key_captured: Option<bool>,
    peer_ml_kem768_public_key_source: Option<String>,
    peer_ml_kem768_public_key_server_attested: Option<bool>,
    local_ml_kem768_decapsulation_key_captured: Option<bool>,
    local_ml_kem768_encapsulation_key_captured: Option<bool>,
    local_ml_kem768_encapsulation_key_source: Option<String>,
    local_ml_kem768_encapsulation_key_server_published: Option<bool>,
    local_ml_kem768_key_pair_verified: Option<bool>,
    remote_product_app_observed: Option<bool>,
    peer_trust_persistence_proof: Option<bool>,
    not_handshake_proof: Option<bool>,
    not_app_control_proof: Option<bool>,
    not_mac_product_app_proof: Option<bool>,
    recorded_at: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ProductControlSteps {
    admission_challenge: Option<bool>,
    admission_lease: Option<bool>,
    lookup_code: Option<bool>,
    register_code: Option<bool>,
    signaling_bound: Option<bool>,
    product_control_transport: Option<bool>,
    product_handshake: Option<bool>,
    app_control_ping_pong: Option<bool>,
}

pub fn validate_product_control_evidence_json(
    json: &str,
) -> Result<ProductControlEvidenceSummary, ProductControlEvidenceError> {
    let document: ProductControlEvidenceDocument =
        serde_json::from_str(json).map_err(|_| ProductControlEvidenceError::Json)?;
    validate_document(document)
}

fn validate_document(
    document: ProductControlEvidenceDocument,
) -> Result<ProductControlEvidenceSummary, ProductControlEvidenceError> {
    if document.evidence_version != Some(1) {
        return Err(ProductControlEvidenceError::UnsupportedSchema);
    }
    reject_secret_capture(&document)?;

    let profile = require_text(document.profile.clone(), "Profile")?;
    let evidence_scope = require_text(document.evidence_scope.clone(), "EvidenceScope")?;
    let status = require_text(document.status.clone(), "Status")?;
    let steps = document
        .steps
        .as_ref()
        .ok_or(ProductControlEvidenceError::MissingField("Steps"))?;
    let role = require_text(document.role.clone(), "Role")?;
    let signaling_exchange_role = require_text(
        document.signaling_exchange_role.clone(),
        "SignalingExchangeRole",
    )?;
    let helper_mode = require_text(document.helper_mode.clone(), "HelperMode")?;
    let secure_session_state =
        require_text(document.secure_session_state.clone(), "SecureSessionState")?;
    let remote_identity_source = require_text(
        document.remote_identity_source.clone(),
        "RemoteIdentitySource",
    )?;
    let remote_identity_server_attested = document.remote_identity_server_attested.ok_or(
        ProductControlEvidenceError::MissingField("RemoteIdentityServerAttested"),
    )?;
    let not_remote_identity_proof = document.not_remote_identity_proof.unwrap_or(false);
    let not_mac_product_app_proof =
        require_bool(document.not_mac_product_app_proof, "NotMacProductAppProof")?;
    let remote_product_app_observed = require_bool(
        document.remote_product_app_observed,
        "RemoteProductAppObserved",
    )?;
    let peer_trust_persistence_proof = require_bool(
        document.peer_trust_persistence_proof,
        "PeerTrustPersistenceProof",
    )?;
    let product_send_count = require_count(document.product_send_count, "ProductSendCount")?;
    let product_receive_count =
        require_count(document.product_receive_count, "ProductReceiveCount")?;
    let late_remote_ice_candidate_relay_count = require_count(
        document.late_remote_ice_candidate_relay_count,
        "LateRemoteIceCandidateRelayCount",
    )?;
    let session_id_sha256 =
        optional_lowercase_sha256(document.session_id_sha256.clone(), "SessionIdSha256")?;
    let remote_device_id_sha256 = optional_lowercase_sha256(
        document.remote_device_id_sha256.clone(),
        "RemoteDeviceIdSha256",
    )?;
    let remote_protocol_public_key_fingerprint = optional_lowercase_sha256(
        document.remote_protocol_public_key_fingerprint.clone(),
        "RemoteProtocolPublicKeyFingerprint",
    )?;

    if document.bound != Some(true) || document.data_channel_label.as_deref() != Some("skybridge") {
        return Err(ProductControlEvidenceError::BoundaryInvalid);
    }
    if !not_mac_product_app_proof || remote_product_app_observed || peer_trust_persistence_proof {
        return Err(ProductControlEvidenceError::BoundaryInvalid);
    }

    let proof_level = match (
        profile.as_str(),
        evidence_scope.as_str(),
        status.as_str(),
        secure_session_state.as_str(),
    ) {
        (
            "current-path-product-control-transport"
            | "current-path-product-control-answerer-transport",
            "AdmissionLookupBoundSdpIceProductControlTransportOpen"
            | "AdmissionRegisterBoundSdpIceProductControlAnswererTransportOpen",
            "transportOpen",
            "TransportOnly",
        ) => {
            validate_transport_only(&document, steps, product_send_count, product_receive_count)?;
            ProductControlProofLevel::TransportOnly
        }
        (
            "current-path-product-control-appcontrol"
            | "current-path-product-control-answerer-appcontrol",
            "AdmissionLookupBoundSdpIceProductControlHandshakeAppControlPong"
            | "AdmissionRegisterBoundSdpIceProductControlAnswererHandshakeAppControlPong",
            "appControlPong",
            "Established",
        ) => {
            validate_appcontrol(
                &document,
                steps,
                &profile,
                product_send_count,
                product_receive_count,
            )?;
            ProductControlProofLevel::AppControlSbwcPingPong
        }
        _ => return Err(ProductControlEvidenceError::UnsupportedSchema),
    };

    validate_role_contract(ProductControlRoleFacts {
        profile: &profile,
        role: &role,
        signaling_exchange_role: &signaling_exchange_role,
        helper_mode: &helper_mode,
        remote_signal_wait_type: document.remote_signal_wait_type.as_deref(),
        remote_identity_source: &remote_identity_source,
        remote_identity_server_attested,
        not_remote_identity_proof,
    })?;

    Ok(ProductControlEvidenceSummary {
        profile,
        evidence_scope,
        status,
        role,
        signaling_exchange_role,
        helper_mode,
        secure_session_state,
        proof_level,
        remote_identity_source,
        remote_identity_server_attested,
        not_remote_identity_proof,
        not_mac_product_app_proof,
        remote_product_app_observed,
        peer_trust_persistence_proof,
        product_send_count,
        product_receive_count,
        late_remote_ice_candidate_relay_count,
        recorded_at_present: document
            .recorded_at
            .as_deref()
            .is_some_and(|value| !value.trim().is_empty()),
        session_id_sha256,
        remote_device_id_sha256,
        remote_protocol_public_key_fingerprint,
    })
}

fn validate_transport_only(
    document: &ProductControlEvidenceDocument,
    steps: &ProductControlSteps,
    product_send_count: u64,
    product_receive_count: u64,
) -> Result<(), ProductControlEvidenceError> {
    require_common_transport_steps(steps)?;
    if document.not_handshake_proof != Some(true)
        || document.not_app_control_proof != Some(true)
        || product_send_count != 0
        || product_receive_count != 0
        || steps.product_handshake == Some(true)
        || steps.app_control_ping_pong == Some(true)
    {
        return Err(ProductControlEvidenceError::BoundaryInvalid);
    }
    Ok(())
}

fn validate_appcontrol(
    document: &ProductControlEvidenceDocument,
    steps: &ProductControlSteps,
    profile: &str,
    product_send_count: u64,
    product_receive_count: u64,
) -> Result<(), ProductControlEvidenceError> {
    require_common_transport_steps(steps)?;
    if steps.product_handshake != Some(true) || steps.app_control_ping_pong != Some(true) {
        return Err(ProductControlEvidenceError::IncompleteSteps);
    }
    if document.not_handshake_proof != Some(false)
        || document.not_app_control_proof != Some(false)
        || product_send_count != 1
        || product_receive_count != 1
    {
        return Err(ProductControlEvidenceError::BoundaryInvalid);
    }

    if document.negotiated_suite_wire_id.as_deref() != Some("0x0101")
        || document.policy_require_pqc != Some(true)
        || document.policy_allow_classic_fallback != Some(false)
    {
        return Err(ProductControlEvidenceError::BoundaryInvalid);
    }

    validate_handshake_role(document, profile)?;

    if document.app_control_packet_type.as_deref() != Some("AppControl")
        || document.app_control_crypto_format.as_deref() != Some("SkybridgeSecureEnvelopeV1")
        || document.app_control_payload_format.as_deref() != Some("SkybridgeSecureEnvelopeV1")
        || document.app_control_sbwc_envelope != Some(true)
        || document.app_control_sbwc_counter_present != Some(true)
        || document.app_control_replay_protection.as_deref() != Some("sbwc-replay-window")
        || document.app_control_legacy_nonce_length.is_some()
        || document.app_control_legacy_tag_length.is_some()
        || document.app_control_legacy_aad_length.is_some()
        || document.app_control_legacy_combined_layout.is_some()
        || document.authenticated_app_control_ping_pong_proof != Some(true)
        || document.app_control_pong_id_matches != Some(true)
        || document.app_control_outbound_counter.is_none()
        || document.app_control_inbound_counter.is_none()
        || document
            .app_control_session_hash
            .as_deref()
            .is_none_or(|value| value.trim().is_empty())
        || document
            .app_control_transcript_prefix
            .as_deref()
            .is_none_or(|value| value.trim().is_empty())
    {
        return Err(ProductControlEvidenceError::BoundaryInvalid);
    }

    match profile {
        "current-path-product-control-appcontrol" => {
            if document.peer_ml_kem768_public_key_captured != Some(false)
                || document.peer_ml_kem768_public_key_source.as_deref()
                    != Some("operatorProvidedOutOfBand")
                || document.peer_ml_kem768_public_key_server_attested != Some(false)
                || document.app_control_received_message_kind.as_deref() != Some("pong")
            {
                return Err(ProductControlEvidenceError::BoundaryInvalid);
            }
        }
        "current-path-product-control-answerer-appcontrol" => {
            if document.local_ml_kem768_decapsulation_key_captured != Some(false)
                || document.local_ml_kem768_encapsulation_key_captured != Some(false)
                || document.local_ml_kem768_encapsulation_key_source.as_deref()
                    != Some("operatorProvidedOutOfBand")
                || document.local_ml_kem768_encapsulation_key_server_published != Some(false)
                || document.local_ml_kem768_key_pair_verified != Some(true)
                || document.app_control_received_message_kind.as_deref() != Some("ping")
                || document.app_control_response_message_kind.as_deref() != Some("pong")
            {
                return Err(ProductControlEvidenceError::BoundaryInvalid);
            }
        }
        _ => return Err(ProductControlEvidenceError::UnsupportedSchema),
    }

    Ok(())
}

fn require_common_transport_steps(
    steps: &ProductControlSteps,
) -> Result<(), ProductControlEvidenceError> {
    if steps.admission_challenge != Some(true)
        || steps.admission_lease != Some(true)
        || steps.signaling_bound != Some(true)
        || steps.product_control_transport != Some(true)
    {
        return Err(ProductControlEvidenceError::IncompleteSteps);
    }
    if steps.lookup_code != Some(true) && steps.register_code != Some(true) {
        return Err(ProductControlEvidenceError::IncompleteSteps);
    }
    Ok(())
}

fn validate_handshake_role(
    document: &ProductControlEvidenceDocument,
    profile: &str,
) -> Result<(), ProductControlEvidenceError> {
    match profile {
        "current-path-product-control-appcontrol" => {
            if document.responder_identity_fingerprint_verified != Some(true)
                || document.responder_signature_verified != Some(true)
                || document.responder_finished_verified != Some(true)
                || document.initiator_finished_sent != Some(true)
            {
                return Err(ProductControlEvidenceError::BoundaryInvalid);
            }
        }
        "current-path-product-control-answerer-appcontrol" => {
            if document.initiator_identity_fingerprint_verified != Some(true)
                || document.initiator_signature_verified != Some(true)
                || document.responder_finished_sent != Some(true)
                || document.initiator_finished_verified != Some(true)
            {
                return Err(ProductControlEvidenceError::BoundaryInvalid);
            }
        }
        _ => return Err(ProductControlEvidenceError::UnsupportedSchema),
    }
    Ok(())
}

struct ProductControlRoleFacts<'a> {
    profile: &'a str,
    role: &'a str,
    signaling_exchange_role: &'a str,
    helper_mode: &'a str,
    remote_signal_wait_type: Option<&'a str>,
    remote_identity_source: &'a str,
    remote_identity_server_attested: bool,
    not_remote_identity_proof: bool,
}

fn validate_role_contract(
    facts: ProductControlRoleFacts<'_>,
) -> Result<(), ProductControlEvidenceError> {
    let (
        expected_role,
        expected_exchange_role,
        expected_helper_mode,
        expected_remote_signal_wait_type,
        expected_remote_identity_source,
        expected_server_attested,
    ) = match facts.profile {
        "current-path-product-control-transport" | "current-path-product-control-appcontrol" => (
            "offer",
            "offerer",
            "product-control-offer",
            "answer",
            "connectionCodeLookup",
            true,
        ),
        "current-path-product-control-answerer-transport" => (
            "answer",
            "answerer",
            "product-control-answer",
            "offer",
            "operatorExpectedPeerNotServerAttested",
            false,
        ),
        "current-path-product-control-answerer-appcontrol" => (
            "answer",
            "answerer",
            "product-control-answer",
            "offer",
            "operatorExpectedPeerHandshakeVerifiedNotServerAttested",
            false,
        ),
        _ => return Err(ProductControlEvidenceError::UnsupportedSchema),
    };

    if facts.role != expected_role
        || facts.signaling_exchange_role != expected_exchange_role
        || facts.helper_mode != expected_helper_mode
        || facts.remote_signal_wait_type != Some(expected_remote_signal_wait_type)
        || facts.remote_identity_source != expected_remote_identity_source
        || facts.remote_identity_server_attested != expected_server_attested
    {
        return Err(ProductControlEvidenceError::BoundaryInvalid);
    }

    let expected_not_remote_identity_proof =
        facts.profile == "current-path-product-control-answerer-transport";
    if facts.not_remote_identity_proof != expected_not_remote_identity_proof {
        return Err(ProductControlEvidenceError::BoundaryInvalid);
    }

    Ok(())
}

fn reject_secret_capture(
    document: &ProductControlEvidenceDocument,
) -> Result<(), ProductControlEvidenceError> {
    if document.header_values_captured != Some(false)
        || document.secret_inputs_captured != Some(false)
        || document.connection_code_captured != Some(false)
        || document.query_token_present != Some(false)
    {
        return Err(ProductControlEvidenceError::SecretCaptureDetected);
    }
    Ok(())
}

fn require_text(
    value: Option<String>,
    label: &'static str,
) -> Result<String, ProductControlEvidenceError> {
    value
        .and_then(non_empty_trimmed)
        .ok_or(ProductControlEvidenceError::MissingField(label))
}

fn require_bool(
    value: Option<bool>,
    label: &'static str,
) -> Result<bool, ProductControlEvidenceError> {
    value.ok_or(ProductControlEvidenceError::MissingField(label))
}

fn require_count(
    value: Option<u64>,
    label: &'static str,
) -> Result<u64, ProductControlEvidenceError> {
    value.ok_or(ProductControlEvidenceError::MissingField(label))
}

fn non_empty_trimmed(value: String) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn optional_lowercase_sha256(
    value: Option<String>,
    label: &'static str,
) -> Result<Option<String>, ProductControlEvidenceError> {
    let Some(value) = value.and_then(non_empty_trimmed) else {
        return Ok(None);
    };
    if value.len() == 64
        && value
            .chars()
            .all(|ch| ch.is_ascii_digit() || matches!(ch, 'a'..='f'))
    {
        return Ok(Some(value));
    }
    Err(ProductControlEvidenceError::InvalidField(label))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn transport_json(overrides: &str) -> String {
        fixture_json(
            false,
            r#""Profile": "current-path-product-control-transport",
  "EvidenceScope": "AdmissionLookupBoundSdpIceProductControlTransportOpen",
  "Status": "transportOpen",
  "Role": "offer",
  "SignalingExchangeRole": "offerer",
  "HelperMode": "product-control-offer",
  "RemoteSignalWaitType": "answer",
  "RemoteIdentitySource": "connectionCodeLookup",
  "RemoteIdentityServerAttested": true,
  "NotRemoteIdentityProof": false,
  "SecureSessionState": "TransportOnly",
  "ProductSendCount": 0,
  "ProductReceiveCount": 0,
  "NotHandshakeProof": true,
  "NotAppControlProof": true"#,
            overrides,
        )
    }

    fn appcontrol_json(overrides: &str) -> String {
        fixture_json(
            true,
            r#""Profile": "current-path-product-control-appcontrol",
  "EvidenceScope": "AdmissionLookupBoundSdpIceProductControlHandshakeAppControlPong",
  "Status": "appControlPong",
  "Role": "offer",
  "SignalingExchangeRole": "offerer",
  "HelperMode": "product-control-offer",
  "RemoteSignalWaitType": "answer",
  "RemoteIdentitySource": "connectionCodeLookup",
  "RemoteIdentityServerAttested": true,
  "NotRemoteIdentityProof": false,
  "SecureSessionState": "Established",
  "ProductSendCount": 1,
  "ProductReceiveCount": 1,
  "NotHandshakeProof": false,
  "NotAppControlProof": false,
  "NegotiatedSuiteWireId": "0x0101",
  "PolicyRequirePqc": true,
  "PolicyAllowClassicFallback": false,
  "ResponderIdentityFingerprintVerified": true,
  "ResponderSignatureVerified": true,
  "ResponderFinishedVerified": true,
  "InitiatorFinishedSent": true,
  "AppControlPacketType": "AppControl",
  "AppControlCryptoFormat": "SkybridgeSecureEnvelopeV1",
  "AppControlPayloadFormat": "SkybridgeSecureEnvelopeV1",
  "AppControlSbwcEnvelope": true,
  "AppControlSbwcCounterPresent": true,
  "AppControlReplayProtection": "sbwc-replay-window",
  "AuthenticatedAppControlPingPongProof": true,
  "AppControlReceivedMessageKind": "pong",
  "AppControlPongIdMatches": true,
  "AppControlOutboundCounter": 1,
  "AppControlInboundCounter": 1,
  "AppControlSessionHash": "session-hash",
  "AppControlTranscriptPrefix": "transcript-prefix",
  "PeerMlKem768PublicKeyCaptured": false,
  "PeerMlKem768PublicKeySource": "operatorProvidedOutOfBand",
  "PeerMlKem768PublicKeyServerAttested": false"#,
            overrides,
        )
    }

    fn answerer_appcontrol_json(overrides: &str) -> String {
        fixture_json(
            true,
            r#""Profile": "current-path-product-control-answerer-appcontrol",
  "EvidenceScope": "AdmissionRegisterBoundSdpIceProductControlAnswererHandshakeAppControlPong",
  "Status": "appControlPong",
  "Role": "answer",
  "SignalingExchangeRole": "answerer",
  "HelperMode": "product-control-answer",
  "RemoteSignalWaitType": "offer",
  "RemoteIdentitySource": "operatorExpectedPeerHandshakeVerifiedNotServerAttested",
  "RemoteIdentityServerAttested": false,
  "NotRemoteIdentityProof": false,
  "SecureSessionState": "Established",
  "ProductSendCount": 1,
  "ProductReceiveCount": 1,
  "NotHandshakeProof": false,
  "NotAppControlProof": false,
  "NegotiatedSuiteWireId": "0x0101",
  "PolicyRequirePqc": true,
  "PolicyAllowClassicFallback": false,
  "InitiatorIdentityFingerprintVerified": true,
  "InitiatorSignatureVerified": true,
  "ResponderFinishedSent": true,
  "InitiatorFinishedVerified": true,
  "AppControlPacketType": "AppControl",
  "AppControlCryptoFormat": "SkybridgeSecureEnvelopeV1",
  "AppControlPayloadFormat": "SkybridgeSecureEnvelopeV1",
  "AppControlSbwcEnvelope": true,
  "AppControlSbwcCounterPresent": true,
  "AppControlReplayProtection": "sbwc-replay-window",
  "AuthenticatedAppControlPingPongProof": true,
  "AppControlReceivedMessageKind": "ping",
  "AppControlResponseMessageKind": "pong",
  "AppControlPongIdMatches": true,
  "AppControlOutboundCounter": 1,
  "AppControlInboundCounter": 1,
  "AppControlSessionHash": "session-hash",
  "AppControlTranscriptPrefix": "transcript-prefix",
  "LocalMlKem768DecapsulationKeyCaptured": false,
  "LocalMlKem768EncapsulationKeyCaptured": false,
  "LocalMlKem768EncapsulationKeySource": "operatorProvidedOutOfBand",
  "LocalMlKem768EncapsulationKeyServerPublished": false,
  "LocalMlKem768KeyPairVerified": true"#,
            overrides,
        )
    }

    fn fixture_json(appcontrol_steps: bool, body: &str, overrides: &str) -> String {
        let overrides = if overrides.is_empty() {
            String::new()
        } else {
            format!(",\n  {overrides}")
        };
        let product_handshake = if appcontrol_steps { "true" } else { "false" };
        let app_control_ping_pong = if appcontrol_steps { "true" } else { "false" };
        format!(
            r#"{{
  "EvidenceVersion": 1,
  "Steps": {{
    "AdmissionChallenge": true,
    "AdmissionLease": true,
    "LookupCode": true,
    "SignalingBound": true,
    "ProductControlTransport": true,
    "ProductHandshake": {product_handshake},
    "AppControlPingPong": {app_control_ping_pong}
  }},
  "HeaderValuesCaptured": false,
  "SecretInputsCaptured": false,
  "ConnectionCodeCaptured": false,
  "QueryTokenPresent": false,
  "Bound": true,
  "DataChannelLabel": "skybridge",
  "LateRemoteIceCandidateRelayCount": 0,
  "RemoteProductAppObserved": false,
  "PeerTrustPersistenceProof": false,
  "NotMacProductAppProof": true,
  "RecordedAt": "2026-07-06T00:00:00.0000000Z",
  {body}
  {overrides}
}}"#
        )
    }

    #[test]
    fn validates_transport_only_boundary() {
        let summary =
            validate_product_control_evidence_json(&transport_json("")).expect("valid transport");

        assert_eq!(summary.proof_level, ProductControlProofLevel::TransportOnly);
        assert_eq!(summary.profile, "current-path-product-control-transport");
        assert_eq!(summary.secure_session_state, "TransportOnly");
        assert!(!summary.proof_level.handshake_proof());
        assert!(!summary.proof_level.app_control_proof());
        assert!(summary.not_mac_product_app_proof);
        assert!(!summary.remote_product_app_observed);
        assert!(!summary.peer_trust_persistence_proof);
        assert!(summary.recorded_at_present);
    }

    #[test]
    fn validates_offerer_appcontrol_boundary() {
        let summary =
            validate_product_control_evidence_json(&appcontrol_json("")).expect("valid appcontrol");

        assert_eq!(
            summary.proof_level,
            ProductControlProofLevel::AppControlSbwcPingPong
        );
        assert_eq!(summary.secure_session_state, "Established");
        assert!(summary.proof_level.handshake_proof());
        assert!(summary.proof_level.app_control_proof());
        assert!(!summary.remote_product_app_observed);
        assert!(!summary.peer_trust_persistence_proof);
        assert_eq!(summary.session_id_sha256, None);
        assert_eq!(summary.remote_device_id_sha256, None);
        assert_eq!(summary.remote_protocol_public_key_fingerprint, None);
    }

    #[test]
    fn validates_answerer_appcontrol_boundary() {
        let summary = validate_product_control_evidence_json(&answerer_appcontrol_json(""))
            .expect("valid answerer appcontrol");

        assert_eq!(
            summary.proof_level,
            ProductControlProofLevel::AppControlSbwcPingPong
        );
        assert_eq!(summary.role, "answer");
        assert_eq!(
            summary.remote_identity_source,
            "operatorExpectedPeerHandshakeVerifiedNotServerAttested"
        );
        assert!(!summary.remote_identity_server_attested);
    }

    #[test]
    fn validates_optional_import_binding_hashes_when_present() {
        let summary = validate_product_control_evidence_json(&appcontrol_json(
            r#""SessionIdSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "RemoteDeviceIdSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "RemoteProtocolPublicKeyFingerprint": "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff""#,
        ))
        .expect("valid appcontrol with import hashes");

        assert_eq!(
            summary.session_id_sha256.as_deref(),
            Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        );
        assert_eq!(
            summary.remote_device_id_sha256.as_deref(),
            Some("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        );
        assert_eq!(
            summary.remote_protocol_public_key_fingerprint.as_deref(),
            Some("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
        );
    }

    #[test]
    fn rejects_malformed_optional_import_binding_hashes_when_present() {
        let err = validate_product_control_evidence_json(&appcontrol_json(
            r#""RemoteProtocolPublicKeyFingerprint": "001122""#,
        ))
        .unwrap_err();

        assert_eq!(
            err,
            ProductControlEvidenceError::InvalidField("RemoteProtocolPublicKeyFingerprint")
        );
    }

    #[test]
    fn rejects_transport_claiming_appcontrol() {
        let json = transport_json("")
            .replace(
                r#""Status": "transportOpen""#,
                r#""Status": "appControlPong""#,
            )
            .replace(
                r#""SecureSessionState": "TransportOnly""#,
                r#""SecureSessionState": "Established""#,
            );
        let err = validate_product_control_evidence_json(&json).unwrap_err();

        assert_eq!(err, ProductControlEvidenceError::UnsupportedSchema);
    }

    #[test]
    fn rejects_secret_capture_markers() {
        let json = appcontrol_json("").replace(
            r#""SecretInputsCaptured": false"#,
            r#""SecretInputsCaptured": true"#,
        );
        let err = validate_product_control_evidence_json(&json).unwrap_err();

        assert_eq!(err, ProductControlEvidenceError::SecretCaptureDetected);
    }

    #[test]
    fn rejects_mac_product_app_overclaim() {
        let json = appcontrol_json("").replace(
            r#""RemoteProductAppObserved": false"#,
            r#""RemoteProductAppObserved": true"#,
        );
        let err = validate_product_control_evidence_json(&json).unwrap_err();

        assert_eq!(err, ProductControlEvidenceError::BoundaryInvalid);
    }

    #[test]
    fn rejects_legacy_appcontrol_format() {
        let json = appcontrol_json("").replace(
            r#""AppControlPayloadFormat": "SkybridgeSecureEnvelopeV1""#,
            r#""AppControlPayloadFormat": "AppleLegacyAesGcmCombined""#,
        );
        let err = validate_product_control_evidence_json(&json).unwrap_err();

        assert_eq!(err, ProductControlEvidenceError::BoundaryInvalid);
    }
}
