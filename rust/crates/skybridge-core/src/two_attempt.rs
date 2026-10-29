//! Live PQC -> Classic two-attempt handshake driver (portable).
//!
//! This is the Rust runtime counterpart of Swift's
//! `Sources/SkyBridgeCore/P2P/TwoAttemptHandshakeManager.swift`. The policy layer
//! ([`crate::policy`]) and the initiator-side gate
//! ([`crate::pqc_handshake::PqcInitiatorHandshake::authorize_classic_fallback`])
//! already exist and are unit-tested, but until now *nothing* in the runtime drove
//! a live PQC failure through them: there was no "attempt PQC, classify failure,
//! gate, then maybe attempt Classic" loop the way Swift has. This module is that
//! loop.
//!
//! ## Contract (mirrors the Swift manager)
//! - **PQC-first**: attempts the PQC/hybrid handshake first.
//! - **Reason-gated fallback**: on PQC failure the caller's classifier maps the
//!   error to a [`FallbackReason`]. Only the ALLOWED set
//!   (`{PqcProviderUnavailable, SuiteNegotiationFailed}`) is fallback-eligible;
//!   every BLOCKED reason (`Timeout`, `SignatureVerificationFailed`,
//!   `ReplayDetected`, `KeyConfirmationFailed`, `IdentityMismatch`,
//!   `SuiteSignatureMismatch`) fails closed with a typed non-downgrade error and
//!   emits **no** [`DowngradeEvent`]. This is `shouldAllowFallback`'s whitelist.
//! - **Local-only / pre-send**: the downgrade decision is taken here, on the
//!   initiator, before any Classic `MessageA` is sent (the Classic executor is only
//!   invoked *after* the gate authorizes). A wire peer cannot induce it.
//! - **Policy gate + rate limit**: authorization runs through
//!   [`PolicyGate::authorize_downgrade`], so the [`DowngradePolicy`] posture (strict
//!   modes deny) and the per-peer 300 s cooldown both apply.
//! - **Auditable + signed**: an authorized downgrade emits a
//!   [`SignedDowngradeEvent`] (detached ML-DSA-65 over the canonical event bytes) to
//!   a caller-supplied sink, so the record is tamper-evident and replayable.
//!
//! The driver is transport-agnostic and synchronous: the two attempts are supplied
//! as closures, exactly like the Swift `PreparedHandshakeExecutor`. This keeps the
//! downgrade-resistance logic in one testable place regardless of whether the live
//! transport is the native WebRTC data channel, an in-process pipe, or a test.

use crate::policy::{
    DowngradeDecision, DowngradePolicy, DowngradeSignatureError, FallbackReason, PolicyGate,
    SignedDowngradeEvent,
};
use crate::{CryptoSuite, ProtocolSigningAlgorithm};

/// The local ML-DSA identity used to sign an authorized [`crate::DowngradeEvent`].
///
/// This is the same key material the PQC handshake signs MessageA with; the driver
/// borrows it only to produce the detached audit signature.
#[derive(Clone)]
pub struct DowngradeSigningIdentity {
    /// Exact ML-DSA algorithm for the active protocol identity.
    pub algorithm: ProtocolSigningAlgorithm,
    /// Algorithm-matched ML-DSA public key (carried for verification).
    pub public_key: Vec<u8>,
    /// Algorithm-matched ML-DSA secret key (never emitted).
    pub secret_key: Vec<u8>,
}

impl std::fmt::Debug for DowngradeSigningIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print key bytes.
        f.debug_struct("DowngradeSigningIdentity")
            .field("algorithm", &self.algorithm)
            .field("public_key_len", &self.public_key.len())
            .field("secret_key_len", &self.secret_key.len())
            .finish()
    }
}

/// Why the two-attempt driver failed without (or before) completing a handshake.
#[derive(Debug, thiserror::Error)]
pub enum TwoAttemptError<E> {
    /// The PQC attempt failed for a BLOCKED reason — the driver fails closed and
    /// emits no [`crate::DowngradeEvent`]. Carries the classified reason and the
    /// original PQC error.
    #[error("pqc handshake failed for non-downgradable reason {reason:?}; no fallback permitted")]
    FallbackBlocked {
        /// The BLOCKED reason the PQC failure was classified into.
        reason: FallbackReason,
        /// The original PQC attempt error.
        source: E,
    },
    /// The PQC failure reason was fallback-eligible, but the active
    /// [`DowngradePolicy`] forbids any classic business fallback (strict modes).
    #[error("classic fallback denied by policy {policy:?} for reason {reason:?}")]
    FallbackDeniedByPolicy {
        /// The policy posture that denied the fallback.
        policy: DowngradePolicy,
        /// The fallback-eligible reason that was nonetheless denied by policy.
        reason: FallbackReason,
        /// The original PQC attempt error.
        source: E,
    },
    /// The PQC failure reason was eligible and policy-permitted, but the per-peer
    /// fallback cooldown has not yet elapsed.
    #[error("classic fallback rate-limited for peer; {remaining_seconds}s remaining")]
    FallbackRateLimited {
        /// Remaining cooldown in seconds.
        remaining_seconds: u64,
        /// The original PQC attempt error.
        source: E,
    },
    /// The fallback was authorized and the Classic attempt was performed, but the
    /// Classic attempt itself failed. The (signed) downgrade event was already
    /// emitted to the sink before this error.
    #[error("classic fallback attempt failed after authorized downgrade")]
    ClassicAttemptFailed {
        /// The Classic attempt error.
        source: E,
    },
    /// Signing the authorized [`crate::DowngradeEvent`] failed (e.g. malformed key).
    /// The downgrade is aborted (fail-closed) rather than proceeding unsigned.
    #[error("failed to sign authorized downgrade event: {0}")]
    Signing(#[from] DowngradeSignatureError),
}

/// Sink for the signed downgrade audit record. Called exactly once, *before* the
/// Classic attempt is performed, whenever a downgrade is authorized.
pub type DowngradeEventSink<'a> = dyn FnMut(SignedDowngradeEvent) + 'a;

/// Outcome of a successful two-attempt run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HandshakeOutcome {
    /// The initial PQC/hybrid attempt succeeded; no downgrade occurred.
    PqcSucceeded,
    /// The PQC attempt failed eligibly, the gate authorized a downgrade, and the
    /// Classic attempt then succeeded.
    ClassicFallbackSucceeded,
}

/// The two-attempt handshake driver: the live PQC->Classic retry loop.
///
/// Construct with a [`PolicyGate`] (carrying the [`DowngradePolicy`] posture and
/// the per-peer cooldown), the local signing identity, and the Classic suite a
/// downgrade would target, then call [`Self::run`].
pub struct TwoAttemptHandshakeDriver<'gate, 'id> {
    gate: &'gate mut PolicyGate,
    identity: &'id DowngradeSigningIdentity,
    from_suite: CryptoSuite,
    to_suite: CryptoSuite,
    transcript_anchor: Option<Vec<u8>>,
}

impl<'gate, 'id> TwoAttemptHandshakeDriver<'gate, 'id> {
    /// Create a driver. `from_suite` is the PQC suite attempted first; `to_suite`
    /// is the Classic suite a downgrade would target (typically
    /// [`CryptoSuite::X25519_ED25519`]).
    pub fn new(
        gate: &'gate mut PolicyGate,
        identity: &'id DowngradeSigningIdentity,
        from_suite: CryptoSuite,
        to_suite: CryptoSuite,
    ) -> Self {
        Self {
            gate,
            identity,
            from_suite,
            to_suite,
            transcript_anchor: None,
        }
    }

    /// Bind the emitted [`crate::DowngradeEvent`] to a specific handshake transcript
    /// (the SHA-256 hash of the PQC `MessageA`), so the audit record is anchored to
    /// the negotiation it downgraded from.
    pub fn with_transcript_anchor(mut self, anchor: impl Into<Vec<u8>>) -> Self {
        self.transcript_anchor = Some(anchor.into());
        self
    }

    /// Run the two-attempt strategy for `peer`.
    ///
    /// - `attempt_pqc`: performs the PQC/hybrid handshake. On `Ok` the driver
    ///   returns [`HandshakeOutcome::PqcSucceeded`] with the session value.
    /// - `classify`: maps a PQC error into a [`FallbackReason`]. BLOCKED reasons
    ///   fail closed; ALLOWED reasons proceed to the gate. (Mirrors Swift
    ///   `shouldAllowFallback` — the whitelist lives in [`FallbackReason`].)
    /// - `attempt_classic`: performs the Classic handshake, invoked **only** after
    ///   the gate authorizes a downgrade (local-only / pre-send).
    /// - `emit`: receives the [`SignedDowngradeEvent`] for an authorized downgrade,
    ///   called once before `attempt_classic`.
    ///
    /// The session value type `T` and error type `E` are caller-chosen, so the same
    /// driver works for real session keys, opaque transport handles, or test fakes.
    pub fn run<T, E, FP, FC, FR>(
        &mut self,
        peer: &str,
        mut attempt_pqc: FP,
        mut classify: FR,
        mut attempt_classic: FC,
        emit: &mut DowngradeEventSink<'_>,
    ) -> Result<(HandshakeOutcome, T), TwoAttemptError<E>>
    where
        FP: FnMut() -> Result<T, E>,
        FC: FnMut() -> Result<T, E>,
        FR: FnMut(&E) -> FallbackReason,
    {
        // Attempt 1: PQC / hybrid.
        let pqc_error = match attempt_pqc() {
            Ok(session) => return Ok((HandshakeOutcome::PqcSucceeded, session)),
            Err(error) => error,
        };

        // Classify the failure. The whitelist is structural: BLOCKED reasons can
        // never authorize a downgrade (downgrade resistance vs. packet-dropping /
        // auth-tampering attackers).
        let reason = classify(&pqc_error);

        // Route the (eligible-or-not) reason through the single policy gate. The
        // gate enforces: (1) reason eligibility, (2) policy posture, (3) per-peer
        // cooldown — and only mints + arms a DowngradeEvent on authorization.
        let decision = self.gate.authorize_downgrade(
            peer,
            self.from_suite,
            self.to_suite,
            reason,
            self.transcript_anchor.as_deref(),
        );

        let event = match decision {
            DowngradeDecision::Allowed(event) => event,
            DowngradeDecision::DeniedReasonIneligible(reason) => {
                return Err(TwoAttemptError::FallbackBlocked {
                    reason,
                    source: pqc_error,
                });
            }
            DowngradeDecision::DeniedByPolicy => {
                return Err(TwoAttemptError::FallbackDeniedByPolicy {
                    policy: self.gate.policy(),
                    reason,
                    source: pqc_error,
                });
            }
            DowngradeDecision::DeniedRateLimited { remaining } => {
                return Err(TwoAttemptError::FallbackRateLimited {
                    remaining_seconds: remaining.as_secs(),
                    source: pqc_error,
                });
            }
        };

        // Sign the authorized event with the local ML-DSA identity and hand the
        // tamper-evident record to the sink *before* sending any Classic MessageA.
        let signed = SignedDowngradeEvent::sign(
            event,
            self.identity.algorithm,
            &self.identity.public_key,
            &self.identity.secret_key,
        )?;
        emit(signed);

        // Attempt 2: Classic (only reached on an authorized, signed downgrade).
        match attempt_classic() {
            Ok(session) => Ok((HandshakeOutcome::ClassicFallbackSucceeded, session)),
            Err(error) => Err(TwoAttemptError::ClassicAttemptFailed { source: error }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::policy::FALLBACK_COOLDOWN;

    const PQC_SUITE: CryptoSuite = CryptoSuite::MLKEM768_MLDSA65;
    const CLASSIC_SUITE: CryptoSuite = CryptoSuite::X25519_ED25519;
    const PEER: &str = "device-fedcba0987654321";

    #[derive(Debug, PartialEq, Eq)]
    enum FakeError {
        ProviderUnavailable,
        Timeout,
    }

    fn classify(error: &FakeError) -> FallbackReason {
        match error {
            FakeError::ProviderUnavailable => FallbackReason::PqcProviderUnavailable,
            FakeError::Timeout => FallbackReason::Timeout,
        }
    }

    fn test_identity() -> DowngradeSigningIdentity {
        let (public_key, secret_key) = crate::mldsa65_generate_keypair();
        DowngradeSigningIdentity {
            algorithm: ProtocolSigningAlgorithm::MlDsa65,
            public_key,
            secret_key,
        }
    }

    /// PQC succeeds first try: no downgrade, no event.
    #[test]
    fn pqc_success_emits_no_event() {
        let mut gate = PolicyGate::new(DowngradePolicy::PreferPqc);
        let identity = test_identity();
        let mut driver =
            TwoAttemptHandshakeDriver::new(&mut gate, &identity, PQC_SUITE, CLASSIC_SUITE);

        let mut events = Vec::new();
        let outcome = driver
            .run::<&str, FakeError, _, _, _>(
                PEER,
                || Ok("pqc-session"),
                classify,
                || panic!("classic attempt must not run when PQC succeeds"),
                &mut |signed| events.push(signed),
            )
            .expect("pqc success");
        assert_eq!(outcome.0, HandshakeOutcome::PqcSucceeded);
        assert_eq!(outcome.1, "pqc-session");
        assert!(events.is_empty(), "no downgrade => no event");
    }

    /// Eligible reason + authorizing policy => one signed event, classic attempt
    /// runs, fallback succeeds. The emitted event verifies against the identity key.
    #[test]
    fn eligible_reason_authorizes_classic_and_emits_one_signed_event() {
        let mut gate = PolicyGate::new(DowngradePolicy::PreferPqc);
        let identity = test_identity();
        let public_key = identity.public_key.clone();
        let mut driver =
            TwoAttemptHandshakeDriver::new(&mut gate, &identity, PQC_SUITE, CLASSIC_SUITE)
                .with_transcript_anchor(vec![0xaa, 0xbb, 0xcc, 0xdd]);

        let mut events = Vec::new();
        let mut classic_calls = 0_u32;
        let outcome = driver
            .run::<&str, FakeError, _, _, _>(
                PEER,
                || Err(FakeError::ProviderUnavailable),
                classify,
                || {
                    classic_calls += 1;
                    Ok("classic-session")
                },
                &mut |signed| events.push(signed),
            )
            .expect("authorized fallback should succeed");

        assert_eq!(outcome.0, HandshakeOutcome::ClassicFallbackSucceeded);
        assert_eq!(outcome.1, "classic-session");
        assert_eq!(classic_calls, 1, "classic attempt must run exactly once");
        assert_eq!(events.len(), 1, "exactly one downgrade event emitted");

        let signed = &events[0];
        signed.verify().expect("emitted event must self-verify");
        signed
            .verify_with(&public_key)
            .expect("emitted event must verify against the identity key");
        assert_eq!(signed.event.peer, PEER);
        assert_eq!(signed.event.from_suite, PQC_SUITE.wire_id);
        assert_eq!(signed.event.to_suite, CLASSIC_SUITE.wire_id);
        assert_eq!(signed.event.reason, FallbackReason::PqcProviderUnavailable);
        assert_eq!(
            signed.event.transcript_anchor.as_deref(),
            Some("aabbccdd"),
            "event must be anchored to the supplied transcript"
        );
        assert_eq!(signed.event.cooldown_seconds, FALLBACK_COOLDOWN.as_secs());
    }

    /// Blocked reason (timeout) => fails closed, classic never runs, zero events.
    #[test]
    fn blocked_reason_fails_closed_with_no_event() {
        let mut gate = PolicyGate::new(DowngradePolicy::PreferPqc);
        let identity = test_identity();
        let mut driver =
            TwoAttemptHandshakeDriver::new(&mut gate, &identity, PQC_SUITE, CLASSIC_SUITE);

        let mut events = Vec::new();
        let result = driver.run::<&str, FakeError, _, _, _>(
            PEER,
            || Err(FakeError::Timeout),
            classify,
            || panic!("classic attempt must not run for a BLOCKED reason"),
            &mut |signed| events.push(signed),
        );

        match result {
            Err(TwoAttemptError::FallbackBlocked { reason, source }) => {
                assert_eq!(reason, FallbackReason::Timeout);
                assert_eq!(source, FakeError::Timeout);
            }
            other => panic!("expected FallbackBlocked, got {other:?}"),
        }
        assert!(events.is_empty(), "BLOCKED reason must emit no event");
    }

    /// Strict policy denies an otherwise-eligible reason: no event, fails closed.
    #[test]
    fn strict_policy_denies_eligible_reason() {
        let mut gate = PolicyGate::new(DowngradePolicy::StrictPqcCompliance);
        let identity = test_identity();
        let mut driver =
            TwoAttemptHandshakeDriver::new(&mut gate, &identity, PQC_SUITE, CLASSIC_SUITE);

        let mut events = Vec::new();
        let result = driver.run::<&str, FakeError, _, _, _>(
            PEER,
            || Err(FakeError::ProviderUnavailable),
            classify,
            || panic!("classic attempt must not run under strict policy"),
            &mut |signed| events.push(signed),
        );

        match result {
            Err(TwoAttemptError::FallbackDeniedByPolicy { policy, reason, .. }) => {
                assert_eq!(policy, DowngradePolicy::StrictPqcCompliance);
                assert_eq!(reason, FallbackReason::PqcProviderUnavailable);
            }
            other => panic!("expected FallbackDeniedByPolicy, got {other:?}"),
        }
        assert!(events.is_empty());
    }

    /// The per-peer cooldown denies a second fallback inside the window — one event
    /// total, second run fails closed.
    #[test]
    fn cooldown_denies_second_fallback_in_window() {
        // Long cooldown so the second call is unambiguously inside the window.
        let mut gate = PolicyGate::with_cooldown(
            DowngradePolicy::PreferPqc,
            std::time::Duration::from_secs(300),
        );
        let identity = test_identity();
        let mut events = Vec::new();

        // First fallback: authorized + emitted.
        {
            let mut driver =
                TwoAttemptHandshakeDriver::new(&mut gate, &identity, PQC_SUITE, CLASSIC_SUITE);
            let first = driver.run::<&str, FakeError, _, _, _>(
                PEER,
                || Err(FakeError::ProviderUnavailable),
                classify,
                || Ok("classic-session"),
                &mut |signed| events.push(signed),
            );
            assert_eq!(
                first.expect("first fallback authorized").0,
                HandshakeOutcome::ClassicFallbackSucceeded
            );
        }
        assert_eq!(events.len(), 1);

        // Second fallback for the same peer, same window: rate-limited.
        {
            let mut driver =
                TwoAttemptHandshakeDriver::new(&mut gate, &identity, PQC_SUITE, CLASSIC_SUITE);
            let second = driver.run::<&str, FakeError, _, _, _>(
                PEER,
                || Err(FakeError::ProviderUnavailable),
                classify,
                || panic!("classic must not run while rate-limited"),
                &mut |signed| events.push(signed),
            );
            match second {
                Err(TwoAttemptError::FallbackRateLimited {
                    remaining_seconds, ..
                }) => {
                    assert!(remaining_seconds > 0);
                    assert!(remaining_seconds <= 300);
                }
                other => panic!("expected FallbackRateLimited, got {other:?}"),
            }
        }
        assert_eq!(
            events.len(),
            1,
            "rate-limited second fallback emits no event"
        );
    }

    /// If the authorized classic attempt itself fails, the event was still emitted
    /// (the downgrade was authorized) but the run reports ClassicAttemptFailed.
    #[test]
    fn classic_attempt_failure_after_authorized_downgrade() {
        let mut gate = PolicyGate::new(DowngradePolicy::PreferPqc);
        let identity = test_identity();
        let mut driver =
            TwoAttemptHandshakeDriver::new(&mut gate, &identity, PQC_SUITE, CLASSIC_SUITE);

        let mut events = Vec::new();
        let result = driver.run::<&str, FakeError, _, _, _>(
            PEER,
            || Err(FakeError::ProviderUnavailable),
            classify,
            || Err(FakeError::Timeout),
            &mut |signed| events.push(signed),
        );
        assert!(matches!(
            result,
            Err(TwoAttemptError::ClassicAttemptFailed { .. })
        ));
        assert_eq!(
            events.len(),
            1,
            "the authorized downgrade event is emitted even if the classic attempt then fails"
        );
    }
}
