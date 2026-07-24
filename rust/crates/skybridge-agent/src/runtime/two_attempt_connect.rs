//! Agent-side glue that drives a live PQC -> Classic two-attempt handshake through
//! the portable [`skybridge_core::TwoAttemptHandshakeDriver`].
//!
//! The core driver is transport-agnostic (it takes attempt closures + a
//! classifier). This module supplies the *agent-specific* pieces the runtime alone
//! has: the local ML-DSA signing identity (from on-disk key material), the
//! [`skybridge_core::PolicyGate`] posture, the PQC/Classic suites in play, and a
//! tracing-backed audit sink for the emitted, signed [`skybridge_core::DowngradeEvent`].
//!
//! This is the runtime counterpart of Swift's
//! `TwoAttemptHandshakeManager.performHandshakeWithPreparation`: the live transport
//! (the WebRTC data channel, or a test) provides the two attempt closures; this
//! module owns the identity/gate/classification/audit wiring so the
//! downgrade-resistance contract is enforced once, in one place.

use anyhow::{Result, anyhow};
use skybridge_core::{
    CryptoSuite, DowngradePolicy, DowngradeSigningIdentity, FallbackReason, HandshakeOutcome,
    PolicyGate, SignedDowngradeEvent, TwoAttemptError, TwoAttemptHandshakeDriver,
};
use tracing::{info, warn};

use crate::state::DeviceIdentityMaterial;

/// Build the local [`DowngradeSigningIdentity`] used to sign authorized downgrade
/// events from the agent's resolved device identity.
///
/// Requires an ML-DSA protocol identity (the same key the PQC handshake signs
/// MessageA with). Returns an error for an Ed25519-only identity, since an
/// auditable PQC->Classic downgrade is only meaningful when a PQC identity exists.
pub(super) fn signing_identity_from_device(
    identity: &DeviceIdentityMaterial,
) -> Result<DowngradeSigningIdentity> {
    if !identity.signing_key.algorithm().is_ml_dsa() {
        return Err(anyhow!(
            "downgrade-event signing requires an ML-DSA protocol identity, got {}",
            identity.signing_key.algorithm()
        ));
    }
    let secret_key = identity
        .signing_key
        .ml_dsa_secret_key_bytes()
        .ok_or_else(|| anyhow!("missing ML-DSA signing secret key for downgrade signing"))?;
    Ok(DowngradeSigningIdentity {
        algorithm: identity.signing_key.algorithm(),
        public_key: identity.signing_key.public_key_bytes(),
        secret_key,
    })
}

/// Default classifier for a live agent handshake error.
///
/// The agent's live attempt closures surface failures as `anyhow::Error`; this maps
/// them to a [`FallbackReason`] using the same whitelist as Swift's
/// `shouldAllowFallback`. The mapping is deliberately conservative: only an error
/// that explicitly names a PQC-provider / suite-negotiation failure is treated as
/// fallback-eligible. Everything else — crucially anything timeout- or
/// auth-shaped, and anything ambiguous — maps to a BLOCKED reason
/// ([`FallbackReason::Timeout`] as the safe default) so it can never authorize a
/// downgrade. This preserves downgrade resistance against packet-dropping or
/// transcript-tampering attackers, exactly as the Swift manager does.
pub(super) fn classify_agent_handshake_error(error: &anyhow::Error) -> FallbackReason {
    let message = error.to_string().to_ascii_lowercase();
    // ALLOWED set (whitelist): explicit PQC-unavailability / no-mutual-suite.
    let mentions_pqc_provider = message.contains("no peer pqc kem public keys")
        || message.contains("no peer pqc public keys")
        || message.contains("pqc provider")
        || message.contains("missing preferred pqc suites")
        || message.contains("missing ml-dsa")
        || message.contains("no usable pqc");
    let mentions_suite_negotiation = message.contains("no mutually supported pqc suite")
        || message.contains("suite negotiation")
        || message.contains("responder selected unsupported suite")
        || message.contains("responder selected non-pqc suite");

    if mentions_pqc_provider {
        FallbackReason::PqcProviderUnavailable
    } else if mentions_suite_negotiation {
        FallbackReason::SuiteNegotiationFailed
    } else {
        // BLOCKED default: timeouts, signature/identity/replay/key-confirmation
        // failures, and *anything ambiguous* are never fallback-eligible.
        FallbackReason::Timeout
    }
}

/// Drive a live PQC -> Classic two-attempt handshake for `peer`.
///
/// - `gate`: the agent's [`PolicyGate`] (posture + per-peer cooldown). Carrying it
///   across calls is what makes the 300 s rate limit real.
/// - `identity`: the agent device identity (must be ML-DSA-65 or ML-DSA-87).
/// - `attempt_pqc` / `attempt_classic`: live attempt closures supplied by the
///   transport layer. `attempt_classic` is invoked **only** after the gate
///   authorizes a downgrade (local-only / pre-send).
/// - `transcript_anchor`: optional SHA-256 of the PQC MessageA, to bind the audit
///   record to the negotiation it downgraded from.
///
/// On an authorized downgrade a [`SignedDowngradeEvent`] is logged (audit sink) and
/// then the classic attempt runs. BLOCKED reasons / strict policy / rate limit all
/// fail closed and emit no event.
#[allow(clippy::too_many_arguments)]
pub(super) fn drive_two_attempt_handshake<T, FP, FC>(
    gate: &mut PolicyGate,
    identity: &DowngradeSigningIdentity,
    peer: &str,
    session_id: &str,
    from_suite: CryptoSuite,
    to_suite: CryptoSuite,
    transcript_anchor: Option<Vec<u8>>,
    attempt_pqc: FP,
    attempt_classic: FC,
) -> Result<HandshakeOutcome, TwoAttemptError<anyhow::Error>>
where
    FP: FnMut() -> Result<T>,
    FC: FnMut() -> Result<T>,
{
    let mut driver = TwoAttemptHandshakeDriver::new(gate, identity, from_suite, to_suite);
    if let Some(anchor) = transcript_anchor {
        driver = driver.with_transcript_anchor(anchor);
    }

    let session_id = session_id.to_owned();
    let peer_owned = peer.to_owned();
    let mut sink = move |signed: SignedDowngradeEvent| {
        emit_signed_downgrade(&session_id, &peer_owned, &signed);
    };

    let (outcome, _session) = driver.run::<T, anyhow::Error, _, _, _>(
        peer,
        attempt_pqc,
        classify_agent_handshake_error,
        attempt_classic,
        &mut sink,
    )?;
    Ok(outcome)
}

/// Audit sink: log the signed, tamper-evident downgrade record. Self-verifies the
/// signature before logging so a mis-signed record is surfaced loudly.
fn emit_signed_downgrade(session_id: &str, peer: &str, signed: &SignedDowngradeEvent) {
    let verified = signed.verify().is_ok();
    let json = serde_json::to_string(signed)
        .unwrap_or_else(|error| format!("{{\"serialize_error\":\"{}\"}}", error));
    if verified {
        warn!(
            kind = "agent.session.crypto_downgrade",
            session_id = %session_id,
            peer = %peer,
            from_suite = signed.event.from_suite,
            to_suite = signed.event.to_suite,
            reason = signed.event.reason.diagnostic_code(),
            downgrade_resistance = %signed.event.downgrade_resistance,
            signed = true,
            signature_verified = true,
            signed_event_json = %json,
            "authorized PQC->Classic downgrade (signed, auditable)"
        );
    } else {
        // Should be impossible (we just signed it), but never log a record we
        // cannot verify without flagging it.
        warn!(
            kind = "agent.session.crypto_downgrade_unverified",
            session_id = %session_id,
            peer = %peer,
            signed_event_json = %json,
            "emitted downgrade event failed self-verification"
        );
    }
    info!(
        kind = "agent.session.crypto_downgrade_summary",
        session_id = %session_id,
        peer = %peer,
        reason = signed.event.reason.diagnostic_code(),
        "crypto downgrade event recorded"
    );
}

/// The Classic suite an agent PQC handshake downgrades to.
pub(super) const AGENT_CLASSIC_FALLBACK_SUITE: CryptoSuite = CryptoSuite::X25519_ED25519;

/// The default agent downgrade posture (prefer PQC, allow gated+rate-limited
/// classic fallback) — mirrors the PQC initiator/responder config defaults in
/// `pqc_config.rs`.
pub(super) const AGENT_DEFAULT_DOWNGRADE_POLICY: DowngradePolicy = DowngradePolicy::PreferPqc;

#[cfg(test)]
mod tests {
    use super::*;
    use skybridge_core::{PolicyGate, ProtocolSigningAlgorithm};

    fn mldsa_identity() -> DowngradeSigningIdentity {
        let (public_key, secret_key) = skybridge_core::mldsa65_generate_keypair();
        DowngradeSigningIdentity {
            algorithm: ProtocolSigningAlgorithm::MlDsa65,
            public_key,
            secret_key,
        }
    }

    #[test]
    fn classifier_whitelist_matches_swift_contract() {
        // ALLOWED set.
        assert_eq!(
            classify_agent_handshake_error(&anyhow!(
                "no peer PQC KEM public keys available for preferred suites"
            )),
            FallbackReason::PqcProviderUnavailable
        );
        assert_eq!(
            classify_agent_handshake_error(&anyhow!(
                "no mutually supported PQC suite found in MessageA"
            )),
            FallbackReason::SuiteNegotiationFailed
        );
        // BLOCKED: timeouts, auth failures, and ambiguous errors all map to a
        // non-eligible reason.
        for message in [
            "handshake timed out",
            "Finished MAC verification failed",
            "ML-DSA-65 signature verification failed",
            "some unrelated transport error",
        ] {
            let reason = classify_agent_handshake_error(&anyhow!(message));
            assert!(
                !reason.is_fallback_eligible(),
                "{message:?} classified as eligible {reason:?}, must be BLOCKED"
            );
        }
    }

    #[test]
    fn eligible_failure_drives_classic_and_succeeds() {
        let mut gate = PolicyGate::new(AGENT_DEFAULT_DOWNGRADE_POLICY);
        let identity = mldsa_identity();
        let mut classic_calls = 0_u32;
        let outcome = drive_two_attempt_handshake::<&str, _, _>(
            &mut gate,
            &identity,
            "device-fedcba0987654321",
            "session-abc",
            CryptoSuite::MLKEM768_MLDSA65,
            AGENT_CLASSIC_FALLBACK_SUITE,
            Some(vec![0x01, 0x02]),
            || {
                Err(anyhow!(
                    "no peer PQC KEM public keys available for preferred suites"
                ))
            },
            || {
                classic_calls += 1;
                Ok("classic")
            },
        )
        .expect("eligible fallback should drive classic");
        assert_eq!(outcome, HandshakeOutcome::ClassicFallbackSucceeded);
        assert_eq!(classic_calls, 1);
    }

    #[test]
    fn blocked_failure_fails_closed() {
        let mut gate = PolicyGate::new(AGENT_DEFAULT_DOWNGRADE_POLICY);
        let identity = mldsa_identity();
        let result = drive_two_attempt_handshake::<&str, _, _>(
            &mut gate,
            &identity,
            "device-fedcba0987654321",
            "session-abc",
            CryptoSuite::MLKEM768_MLDSA65,
            AGENT_CLASSIC_FALLBACK_SUITE,
            None,
            || Err(anyhow!("handshake timed out waiting for MessageB")),
            || -> Result<&str> { panic!("classic must not run for a BLOCKED reason") },
        );
        assert!(matches!(
            result,
            Err(TwoAttemptError::FallbackBlocked {
                reason: FallbackReason::Timeout,
                ..
            })
        ));
    }

    #[test]
    fn pqc_success_skips_fallback() {
        let mut gate = PolicyGate::new(AGENT_DEFAULT_DOWNGRADE_POLICY);
        let identity = mldsa_identity();
        let outcome = drive_two_attempt_handshake::<&str, _, _>(
            &mut gate,
            &identity,
            "device-fedcba0987654321",
            "session-abc",
            CryptoSuite::MLKEM768_MLDSA65,
            AGENT_CLASSIC_FALLBACK_SUITE,
            None,
            || Ok("pqc"),
            || -> Result<&str> { panic!("classic must not run when PQC succeeds") },
        )
        .expect("pqc success");
        assert_eq!(outcome, HandshakeOutcome::PqcSucceeded);
    }
}
