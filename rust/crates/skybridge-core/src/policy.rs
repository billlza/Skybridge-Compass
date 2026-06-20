//! Auditable-downgrade policy layer (portable).
//!
//! This is the Rust port of the Swift policy that governs whether a crypto-suite
//! downgrade (PQC -> Classic fallback) is permitted, rate-limits it per peer, and
//! emits a structured, replayable audit record. The canonical specification lives
//! in `Sources/SkyBridgeCore/P2P/TwoAttemptHandshakeManager.swift`
//! (`shouldAllowFallback(_)` whitelist + `FallbackRateLimiter`).
//!
//! Three-layer separation (negotiation / providers / **policy**) is now real
//! off-Apple: the negotiation code in `pqc_handshake.rs` / `classic_handshake.rs`
//! routes its downgrade decisions through this module instead of emitting inert,
//! discarded policy bytes.
//!
//! ## Downgrade-resistance invariants (paper terminology)
//! - **Local-only / pre-send**: a downgrade is decided locally before a Classic
//!   `MessageA` is sent; the wire peer cannot *induce* a downgrade.
//! - **Rate-limited**: at most one fallback per peer per `FALLBACK_COOLDOWN`
//!   (300 s), tracked on a monotonic clock so a wall-clock rollback cannot widen
//!   the window.
//! - **Reason-gated**: only `pqcProviderUnavailable` and `suiteNegotiationFailed`
//!   are fallback-eligible. Every network-derived or authentication failure
//!   (`timeout`, `signatureVerificationFailed`, `replayDetected`,
//!   `keyConfirmationFailed`, `identityMismatch`, `suiteSignatureMismatch`) is
//!   *structurally* ineligible: `FallbackReason::is_fallback_eligible()` returns
//!   `false` for all of them, so a packet-dropping attacker cannot force a
//!   downgrade.
//! - **Auditable**: an authorized downgrade produces a `DowngradeEvent` that is
//!   serde-serializable and therefore replayable / verifiable after the fact.
//!   Non-fallback failures are reported as typed events but are *not* labeled
//!   "downgrade".

use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::{
    CryptoSuite, ProtocolSigningAlgorithm, mldsa65_sign_detached, mldsa65_verify_detached,
};

/// Per-peer cooldown enforced between two authorized Classic fallbacks.
///
/// Mirrors `TwoAttemptHandshakeManager.fallbackCooldownSeconds = 300`.
pub const FALLBACK_COOLDOWN: Duration = Duration::from_secs(300);

/// The downgrade posture for a handshake.
///
/// `StrictPqc` has two realizations, matching the Swift `HandshakePolicy`
/// distinction between a hard "no classic path at all" stance and the
/// bootstrap-assisted recovery flow:
///
/// - [`DowngradePolicy::StrictPqcCompliance`] — no classic path exists. Fallback
///   is never authorized, regardless of reason.
/// - [`DowngradePolicy::StrictPqcBootstrapAssisted`] — a one-time classic control
///   channel is permitted *only* to recover a paired peer's KEM public key, after
///   which a PQC rekey is mandatory before any business traffic. Business-traffic
///   fallback is still denied.
/// - [`DowngradePolicy::PreferPqc`] — try PQC first, allow an eligible+rate-limited
///   Classic fallback (the default operational posture).
/// - [`DowngradePolicy::Default`] — same fallback gating as `PreferPqc` but does
///   not *require* an initial PQC attempt; used by peers that have no PQC provider.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DowngradePolicy {
    /// Strict PQC, compliance realization: classic fallback is *never* allowed.
    StrictPqcCompliance,
    /// Strict PQC, bootstrap-assisted realization: a one-time classic *control*
    /// channel is allowed for paired KEM-key recovery, then mandatory PQC rekey.
    StrictPqcBootstrapAssisted,
    /// Prefer PQC, allow eligible + rate-limited classic business-traffic fallback.
    #[default]
    PreferPqc,
    /// Default posture: no mandatory initial PQC attempt; same fallback gating.
    Default,
}

impl DowngradePolicy {
    /// Whether this policy mandates that the *first* handshake attempt is PQC.
    pub fn requires_pqc(self) -> bool {
        matches!(
            self,
            Self::StrictPqcCompliance | Self::StrictPqcBootstrapAssisted | Self::PreferPqc
        )
    }

    /// Whether this policy permits a Classic fallback to carry *business traffic*.
    ///
    /// Both strict realizations deny this: compliance has no classic path at all,
    /// and bootstrap-assisted only permits a classic *control* channel for KEM-key
    /// recovery (see [`Self::allows_bootstrap_control_channel`]), never business
    /// traffic without a subsequent PQC rekey.
    pub fn allows_classic_business_fallback(self) -> bool {
        matches!(self, Self::PreferPqc | Self::Default)
    }

    /// Whether this policy permits a one-time classic *control* channel solely to
    /// recover a paired peer's KEM public key (bootstrap-assisted only).
    pub fn allows_bootstrap_control_channel(self) -> bool {
        matches!(self, Self::StrictPqcBootstrapAssisted)
    }
}

/// Why a handshake attempt failed, partitioned into the fallback taxonomy.
///
/// The ALLOWED set is exactly `{PqcProviderUnavailable, SuiteNegotiationFailed}`
/// (the Swift whitelist). Everything else is BLOCKED. Network-derived failures
/// (notably `Timeout`) are *structurally* ineligible so an attacker cannot force a
/// downgrade by dropping or delaying packets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FallbackReason {
    // ---- ALLOWED (fallback-eligible) ----
    /// No PQC provider / no usable PQC suite is available locally.
    PqcProviderUnavailable,
    /// PQC suite negotiation produced no mutually supported suite.
    SuiteNegotiationFailed,

    // ---- BLOCKED (never fallback-eligible) ----
    /// Network-derived timeout. MUST NOT trigger fallback (downgrade resistance).
    Timeout,
    /// Peer signature failed to verify.
    SignatureVerificationFailed,
    /// Replay / anti-rollback detection tripped.
    ReplayDetected,
    /// Key confirmation (FINISHED MAC) failed.
    KeyConfirmationFailed,
    /// Peer identity did not match the pinned/enrolled identity.
    IdentityMismatch,
    /// The signed suite list did not match the negotiated suite.
    SuiteSignatureMismatch,
}

impl FallbackReason {
    /// `true` only for the ALLOWED set. Returns `false` for *every* BLOCKED
    /// reason, including all network-derived failures.
    ///
    /// This is the single structural gate that makes timeout/auth failures
    /// fallback-ineligible — there is no code path that flips a BLOCKED reason to
    /// eligible.
    pub fn is_fallback_eligible(self) -> bool {
        matches!(
            self,
            Self::PqcProviderUnavailable | Self::SuiteNegotiationFailed
        )
    }

    /// Stable, lowercase diagnostic code (matches the Swift `diagnosticReasonCode`
    /// vocabulary used in the audit trail).
    pub fn diagnostic_code(self) -> &'static str {
        match self {
            Self::PqcProviderUnavailable => "pqc_provider_unavailable",
            Self::SuiteNegotiationFailed => "suite_negotiation_failed",
            Self::Timeout => "timeout",
            Self::SignatureVerificationFailed => "signature_verification_failed",
            Self::ReplayDetected => "replay_detected",
            Self::KeyConfirmationFailed => "key_confirmation_failed",
            Self::IdentityMismatch => "identity_mismatch",
            Self::SuiteSignatureMismatch => "suite_signature_mismatch",
        }
    }
}

/// The outcome of asking the policy to authorize a downgrade.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DowngradeDecision {
    /// Downgrade authorized; carries the structured audit record to emit.
    Allowed(DowngradeEvent),
    /// Denied because the policy forbids any classic business fallback.
    DeniedByPolicy,
    /// Denied because the failure reason is not fallback-eligible (BLOCKED set).
    DeniedReasonIneligible(FallbackReason),
    /// Denied because the per-peer cooldown has not elapsed.
    DeniedRateLimited { remaining: Duration },
}

impl DowngradeDecision {
    /// Convenience: did the policy authorize the downgrade?
    pub fn is_allowed(&self) -> bool {
        matches!(self, Self::Allowed(_))
    }

    /// The audit record, if the downgrade was authorized.
    pub fn event(&self) -> Option<&DowngradeEvent> {
        match self {
            Self::Allowed(event) => Some(event),
            _ => None,
        }
    }
}

/// Per-peer fallback rate limiter (300 s cooldown), on a monotonic clock.
///
/// Mirrors the Swift `FallbackRateLimiter` actor: it records the last *authorized*
/// fallback per peer using `std::time::Instant` (monotonic, immune to wall-clock
/// rollback) so an attacker cannot widen the window by changing the system clock.
#[derive(Debug, Default)]
pub struct FallbackRateLimiter {
    cooldown: Option<Duration>,
    last_fallback: HashMap<String, Instant>,
}

impl FallbackRateLimiter {
    /// A limiter using the canonical [`FALLBACK_COOLDOWN`] (300 s).
    pub fn new() -> Self {
        Self {
            cooldown: None,
            last_fallback: HashMap::new(),
        }
    }

    /// A limiter with a custom cooldown (primarily for tests).
    pub fn with_cooldown(cooldown: Duration) -> Self {
        Self {
            cooldown: Some(cooldown),
            last_fallback: HashMap::new(),
        }
    }

    fn cooldown(&self) -> Duration {
        self.cooldown.unwrap_or(FALLBACK_COOLDOWN)
    }

    /// Whether a fallback is currently allowed for `peer` (cooldown elapsed).
    pub fn can_fallback(&self, peer: &str) -> bool {
        self.remaining_cooldown(peer).is_zero()
    }

    /// Remaining cooldown for `peer`; `Duration::ZERO` if a fallback is allowed.
    pub fn remaining_cooldown(&self, peer: &str) -> Duration {
        match self.last_fallback.get(peer) {
            None => Duration::ZERO,
            Some(last) => {
                let elapsed = last.elapsed();
                self.cooldown()
                    .checked_sub(elapsed)
                    .unwrap_or(Duration::ZERO)
            }
        }
    }

    /// Record that a fallback has just been authorized for `peer`, starting the
    /// cooldown window.
    pub fn record_fallback(&mut self, peer: &str) {
        self.last_fallback.insert(peer.to_owned(), Instant::now());
    }
}

/// A structured, replayable downgrade audit record.
///
/// Emitted *only* when a downgrade is authorized. It is serde-serializable so it
/// can be persisted, shipped to an audit log, and replayed/verified later — this
/// is the portable realization of the "auditable downgrade" contribution.
///
/// `transcript_anchor` binds the record to the in-progress handshake transcript
/// (the SHA-256 transcript hash of `MessageA`), so an auditor can confirm the
/// downgrade belongs to a specific, signed negotiation rather than a forged one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DowngradeEvent {
    /// Audit schema version for forward-compatible replay.
    pub schema_version: u32,
    /// Stable identifier of the peer the downgrade targets.
    pub peer: String,
    /// Wire id of the suite being downgraded *from* (the PQC suite attempted).
    pub from_suite: u16,
    /// Wire id of the suite being downgraded *to* (the Classic suite).
    pub to_suite: u16,
    /// The fallback-eligible reason that authorized the downgrade.
    pub reason: FallbackReason,
    /// Policy posture in effect when the downgrade was authorized.
    pub policy: DowngradePolicy,
    /// Cooldown window (seconds) enforced for this peer at authorization time.
    pub cooldown_seconds: u64,
    /// RFC-3339 wall-clock timestamp of the authorization (for human audit; the
    /// rate-limit decision itself uses a monotonic clock, not this field).
    #[serde(with = "time::serde::rfc3339")]
    pub timestamp_window: OffsetDateTime,
    /// Hex-encoded transcript hash anchoring this record to a specific handshake.
    pub transcript_anchor: Option<String>,
    /// Constant downgrade-resistance descriptor, mirroring the Swift audit context
    /// (`downgradeResistance` = "policy_gate+no_timeout_fallback+rate_limited").
    pub downgrade_resistance: String,
}

impl DowngradeEvent {
    /// Current audit schema version.
    pub const SCHEMA_VERSION: u32 = 1;

    /// Canonical descriptor of the enforced downgrade-resistance properties.
    pub const DOWNGRADE_RESISTANCE: &'static str = "policy_gate+no_timeout_fallback+rate_limited";

    /// Domain-separation tag prepended to every canonical signing pre-image so a
    /// `DowngradeEvent` signature can never be confused with any other ML-DSA-65
    /// signature this identity produces (handshake MessageA/MessageB, etc.).
    pub const SIGNING_DOMAIN: &'static [u8] = b"SkyBridge-DowngradeEvent-v1";

    fn new(
        peer: &str,
        from_suite: CryptoSuite,
        to_suite: CryptoSuite,
        reason: FallbackReason,
        policy: DowngradePolicy,
        cooldown: Duration,
        transcript_anchor: Option<&[u8]>,
    ) -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            peer: peer.to_owned(),
            from_suite: from_suite.wire_id,
            to_suite: to_suite.wire_id,
            reason,
            policy,
            cooldown_seconds: cooldown.as_secs(),
            timestamp_window: OffsetDateTime::now_utc(),
            transcript_anchor: transcript_anchor.map(hex_encode),
            downgrade_resistance: Self::DOWNGRADE_RESISTANCE.to_owned(),
        }
    }

    /// Deterministic, version-stable byte serialization of this event used as the
    /// ML-DSA-65 signing pre-image.
    ///
    /// This is intentionally *not* `serde_json` — JSON map/whitespace ordering is
    /// not a stable signing input across crate/serde versions. Instead every field
    /// is length-prefixed and emitted in a fixed order behind a domain tag, so the
    /// exact same bytes are reproduced by [`SignedDowngradeEvent::verify`] when a
    /// persisted/replayed event is checked. The unsigned serde encoding of
    /// [`DowngradeEvent`] is left untouched (it is FFI-consumed) — the signature is
    /// computed over *this* canonical form and carried alongside in
    /// [`SignedDowngradeEvent`].
    pub fn canonical_bytes(&self) -> Vec<u8> {
        fn push_len_prefixed(out: &mut Vec<u8>, bytes: &[u8]) {
            out.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
            out.extend_from_slice(bytes);
        }

        let mut out = Vec::new();
        out.extend_from_slice(Self::SIGNING_DOMAIN);
        out.extend_from_slice(&self.schema_version.to_le_bytes());
        push_len_prefixed(&mut out, self.peer.as_bytes());
        out.extend_from_slice(&self.from_suite.to_le_bytes());
        out.extend_from_slice(&self.to_suite.to_le_bytes());
        push_len_prefixed(&mut out, self.reason.diagnostic_code().as_bytes());
        // Policy posture: a single stable discriminant byte (independent of the
        // legacy `requirePQC` wire byte, which collapses distinct postures).
        out.push(match self.policy {
            DowngradePolicy::StrictPqcCompliance => 0x00,
            DowngradePolicy::StrictPqcBootstrapAssisted => 0x01,
            DowngradePolicy::PreferPqc => 0x02,
            DowngradePolicy::Default => 0x03,
        });
        out.extend_from_slice(&self.cooldown_seconds.to_le_bytes());
        // Timestamp as Unix-nanoseconds (i128) — order-stable and resolution-stable.
        out.extend_from_slice(&self.timestamp_window.unix_timestamp_nanos().to_le_bytes());
        match &self.transcript_anchor {
            Some(anchor) => {
                out.push(0x01);
                push_len_prefixed(&mut out, anchor.as_bytes());
            }
            None => out.push(0x00),
        }
        push_len_prefixed(&mut out, self.downgrade_resistance.as_bytes());
        out
    }
}

/// A [`DowngradeEvent`] with a detached ML-DSA-65 signature over its canonical
/// serialization, plus the signer's identity so a verifier can re-check it.
///
/// This is the cryptographically tamper-evident realization of the auditable
/// downgrade record: the structured [`DowngradeEvent`] is unchanged (and still
/// serde-/FFI-stable), and the signature is computed over
/// [`DowngradeEvent::canonical_bytes`] — so a persisted or replayed event whose
/// fields were altered will fail [`Self::verify`]. The signer's public key is
/// carried for convenience, but a relying party MUST verify against an
/// *independently trusted* key (e.g. the peer's pinned identity), not blindly
/// against `signer_public_key` — see [`Self::verify_with`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedDowngradeEvent {
    /// The structured downgrade record (its own serde encoding is unchanged).
    pub event: DowngradeEvent,
    /// Signing algorithm — always [`ProtocolSigningAlgorithm::MlDsa65`] today.
    pub signer_algorithm: ProtocolSigningAlgorithm,
    /// The signer's ML-DSA-65 public key (base64 in the serde encoding).
    #[serde(with = "base64_standard")]
    pub signer_public_key: Vec<u8>,
    /// Detached ML-DSA-65 signature over [`DowngradeEvent::canonical_bytes`]
    /// (base64 in the serde encoding).
    #[serde(with = "base64_standard")]
    pub signature: Vec<u8>,
}

/// Errors from signing or verifying a [`SignedDowngradeEvent`].
#[derive(Debug, thiserror::Error)]
pub enum DowngradeSignatureError {
    /// The local identity did not use ML-DSA-65 (the only supported signer).
    #[error("downgrade-event signing requires an ML-DSA-65 identity, got {0}")]
    UnsupportedSignerAlgorithm(ProtocolSigningAlgorithm),
    /// The detached ML-DSA-65 signature failed to verify against the public key.
    #[error("downgrade-event signature verification failed: {0}")]
    InvalidSignature(String),
    /// The underlying ML-DSA-65 sign/verify primitive errored (e.g. malformed key).
    #[error("downgrade-event crypto error: {0}")]
    Crypto(String),
}

impl SignedDowngradeEvent {
    /// Sign `event` with the local ML-DSA-65 identity, producing a detached
    /// signature over [`DowngradeEvent::canonical_bytes`].
    ///
    /// `public_key`/`secret_key` are the local identity's ML-DSA-65 key pair (the
    /// same material the PQC handshake signs MessageA with — see
    /// `RustPqcIdentityMaterial` / the agent's `ProtocolSigningKeyMaterial`).
    pub fn sign(
        event: DowngradeEvent,
        signer_algorithm: ProtocolSigningAlgorithm,
        public_key: &[u8],
        secret_key: &[u8],
    ) -> Result<Self, DowngradeSignatureError> {
        if signer_algorithm != ProtocolSigningAlgorithm::MlDsa65 {
            return Err(DowngradeSignatureError::UnsupportedSignerAlgorithm(
                signer_algorithm,
            ));
        }
        let canonical = event.canonical_bytes();
        let signature = mldsa65_sign_detached(&canonical, secret_key)
            .map_err(|error| DowngradeSignatureError::Crypto(error.to_string()))?;
        Ok(Self {
            event,
            signer_algorithm,
            signer_public_key: public_key.to_vec(),
            signature,
        })
    }

    /// Recompute the canonical bytes and verify the detached signature against the
    /// *embedded* `signer_public_key`.
    ///
    /// This proves the event has not been tampered with since it was signed by the
    /// holder of `signer_public_key`. It does NOT by itself prove *who* signed it —
    /// to bind the record to a known peer, verify against an externally trusted key
    /// with [`Self::verify_with`].
    pub fn verify(&self) -> Result<(), DowngradeSignatureError> {
        let key = self.signer_public_key.clone();
        self.verify_with(&key)
    }

    /// Recompute the canonical bytes and verify the detached signature against an
    /// externally supplied, trusted public key (e.g. the peer's pinned ML-DSA-65
    /// identity). A key that differs from the true signer fails verification.
    pub fn verify_with(&self, public_key: &[u8]) -> Result<(), DowngradeSignatureError> {
        if self.signer_algorithm != ProtocolSigningAlgorithm::MlDsa65 {
            return Err(DowngradeSignatureError::UnsupportedSignerAlgorithm(
                self.signer_algorithm,
            ));
        }
        let canonical = self.event.canonical_bytes();
        mldsa65_verify_detached(&canonical, &self.signature, public_key)
            .map_err(|error| DowngradeSignatureError::InvalidSignature(error.to_string()))
    }
}

/// The first-class policy object that gates suite selection / classic fallback.
///
/// It bundles a [`DowngradePolicy`] with a [`FallbackRateLimiter`] and is the
/// single authority the handshake code consults before sending a downgraded
/// (Classic) `MessageA`.
#[derive(Debug)]
pub struct PolicyGate {
    policy: DowngradePolicy,
    rate_limiter: FallbackRateLimiter,
}

impl PolicyGate {
    /// A gate with the given policy and the canonical 300 s cooldown.
    pub fn new(policy: DowngradePolicy) -> Self {
        Self {
            policy,
            rate_limiter: FallbackRateLimiter::new(),
        }
    }

    /// A gate with a custom cooldown (primarily for tests).
    pub fn with_cooldown(policy: DowngradePolicy, cooldown: Duration) -> Self {
        Self {
            policy,
            rate_limiter: FallbackRateLimiter::with_cooldown(cooldown),
        }
    }

    /// The configured policy posture.
    pub fn policy(&self) -> DowngradePolicy {
        self.policy
    }

    /// Decide whether a PQC -> Classic downgrade is authorized for `peer` given
    /// the failure `reason`, recording the fallback (and starting the cooldown)
    /// *only* when it authorizes one.
    ///
    /// This is the single gate the handshake routes through. The ordering matters:
    /// 1. reason eligibility (structural — blocks timeout/auth failures),
    /// 2. policy posture (strict modes deny business fallback),
    /// 3. per-peer rate limit (cooldown),
    /// 4. and only then is the cooldown clock armed and a [`DowngradeEvent`] minted.
    pub fn authorize_downgrade(
        &mut self,
        peer: &str,
        from_suite: CryptoSuite,
        to_suite: CryptoSuite,
        reason: FallbackReason,
        transcript_anchor: Option<&[u8]>,
    ) -> DowngradeDecision {
        // 1. Structural eligibility: BLOCKED reasons (timeout, auth failures, ...)
        //    can never be downgraded.
        if !reason.is_fallback_eligible() {
            return DowngradeDecision::DeniedReasonIneligible(reason);
        }

        // 2. Policy posture: strict modes forbid classic business fallback.
        if !self.policy.allows_classic_business_fallback() {
            return DowngradeDecision::DeniedByPolicy;
        }

        // 3. Per-peer rate limit (monotonic-clock cooldown).
        let remaining = self.rate_limiter.remaining_cooldown(peer);
        if !remaining.is_zero() {
            return DowngradeDecision::DeniedRateLimited { remaining };
        }

        // Authorized: arm the cooldown and mint the auditable record.
        self.rate_limiter.record_fallback(peer);
        let event = DowngradeEvent::new(
            peer,
            from_suite,
            to_suite,
            reason,
            self.policy,
            self.rate_limiter.cooldown(),
            transcript_anchor,
        );
        DowngradeDecision::Allowed(event)
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// Base64 (standard) serde codec for the `Vec<u8>` fields of
/// [`SignedDowngradeEvent`] (public key + signature), keeping the wrapper's JSON
/// human-readable and consistent with `ProtocolIdentityBinding`.
mod base64_standard {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S>(value: &[u8], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&STANDARD.encode(value))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        STANDARD
            .decode(value.as_bytes())
            .map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PQC_SUITE: CryptoSuite = CryptoSuite::MLKEM768_MLDSA65;
    const CLASSIC_SUITE: CryptoSuite = CryptoSuite::X25519_ED25519;

    // ---- Taxonomy: BLOCKED reasons are never eligible ----

    #[test]
    fn blocked_reasons_are_not_fallback_eligible() {
        for reason in [
            FallbackReason::Timeout,
            FallbackReason::SignatureVerificationFailed,
            FallbackReason::ReplayDetected,
            FallbackReason::KeyConfirmationFailed,
            FallbackReason::IdentityMismatch,
            FallbackReason::SuiteSignatureMismatch,
        ] {
            assert!(
                !reason.is_fallback_eligible(),
                "{reason:?} must be structurally fallback-ineligible"
            );
        }
    }

    // ---- Taxonomy: ALLOWED reasons are eligible ----

    #[test]
    fn allowed_reasons_are_fallback_eligible() {
        assert!(FallbackReason::PqcProviderUnavailable.is_fallback_eligible());
        assert!(FallbackReason::SuiteNegotiationFailed.is_fallback_eligible());
    }

    // ---- Gate: BLOCKED reasons are denied even under PreferPqc ----

    #[test]
    fn gate_denies_blocked_reasons_even_when_policy_allows() {
        let mut gate = PolicyGate::new(DowngradePolicy::PreferPqc);
        for reason in [
            FallbackReason::Timeout,
            FallbackReason::SignatureVerificationFailed,
            FallbackReason::ReplayDetected,
            FallbackReason::KeyConfirmationFailed,
            FallbackReason::IdentityMismatch,
            FallbackReason::SuiteSignatureMismatch,
        ] {
            let decision =
                gate.authorize_downgrade("peer-a", PQC_SUITE, CLASSIC_SUITE, reason, None);
            assert_eq!(
                decision,
                DowngradeDecision::DeniedReasonIneligible(reason),
                "{reason:?} must be denied by the gate"
            );
            assert!(!decision.is_allowed());
        }
    }

    // ---- Gate: eligible reason under PreferPqc is allowed ----

    #[test]
    fn gate_allows_eligible_reason_under_prefer_pqc() {
        let mut gate = PolicyGate::new(DowngradePolicy::PreferPqc);
        let decision = gate.authorize_downgrade(
            "peer-a",
            PQC_SUITE,
            CLASSIC_SUITE,
            FallbackReason::PqcProviderUnavailable,
            Some(&[0xab, 0xcd]),
        );
        assert!(decision.is_allowed());
        let event = decision.event().expect("authorized => event");
        assert_eq!(event.from_suite, PQC_SUITE.wire_id);
        assert_eq!(event.to_suite, CLASSIC_SUITE.wire_id);
        assert_eq!(event.reason, FallbackReason::PqcProviderUnavailable);
        assert_eq!(event.transcript_anchor.as_deref(), Some("abcd"));
    }

    // ---- Strict modes deny business fallback ----

    #[test]
    fn strict_compliance_denies_eligible_reason() {
        let mut gate = PolicyGate::new(DowngradePolicy::StrictPqcCompliance);
        let decision = gate.authorize_downgrade(
            "peer-a",
            PQC_SUITE,
            CLASSIC_SUITE,
            FallbackReason::SuiteNegotiationFailed,
            None,
        );
        assert_eq!(decision, DowngradeDecision::DeniedByPolicy);
    }

    #[test]
    fn strict_bootstrap_denies_business_fallback_but_allows_control_channel() {
        let policy = DowngradePolicy::StrictPqcBootstrapAssisted;
        assert!(!policy.allows_classic_business_fallback());
        assert!(policy.allows_bootstrap_control_channel());

        let mut gate = PolicyGate::new(policy);
        let decision = gate.authorize_downgrade(
            "peer-a",
            PQC_SUITE,
            CLASSIC_SUITE,
            FallbackReason::PqcProviderUnavailable,
            None,
        );
        assert_eq!(decision, DowngradeDecision::DeniedByPolicy);
    }

    // ---- 300 s cooldown enforced: second fallback within window denied ----

    #[test]
    fn cooldown_denies_second_fallback_within_window() {
        // Use a long custom cooldown so the second call is unambiguously inside it.
        let mut gate =
            PolicyGate::with_cooldown(DowngradePolicy::PreferPqc, Duration::from_secs(300));
        let first = gate.authorize_downgrade(
            "peer-a",
            PQC_SUITE,
            CLASSIC_SUITE,
            FallbackReason::PqcProviderUnavailable,
            None,
        );
        assert!(first.is_allowed(), "first fallback should be authorized");

        let second = gate.authorize_downgrade(
            "peer-a",
            PQC_SUITE,
            CLASSIC_SUITE,
            FallbackReason::PqcProviderUnavailable,
            None,
        );
        match second {
            DowngradeDecision::DeniedRateLimited { remaining } => {
                assert!(remaining > Duration::ZERO);
                assert!(remaining <= Duration::from_secs(300));
            }
            other => panic!("expected rate-limited denial, got {other:?}"),
        }
    }

    #[test]
    fn cooldown_is_per_peer() {
        let mut gate = PolicyGate::new(DowngradePolicy::PreferPqc);
        let a = gate.authorize_downgrade(
            "peer-a",
            PQC_SUITE,
            CLASSIC_SUITE,
            FallbackReason::PqcProviderUnavailable,
            None,
        );
        let b = gate.authorize_downgrade(
            "peer-b",
            PQC_SUITE,
            CLASSIC_SUITE,
            FallbackReason::PqcProviderUnavailable,
            None,
        );
        assert!(a.is_allowed());
        assert!(
            b.is_allowed(),
            "a different peer must not share the cooldown"
        );
    }

    #[test]
    fn cooldown_expiry_allows_again() {
        // Zero cooldown => the window is always elapsed.
        let mut gate =
            PolicyGate::with_cooldown(DowngradePolicy::PreferPqc, Duration::from_secs(0));
        let first = gate.authorize_downgrade(
            "peer-a",
            PQC_SUITE,
            CLASSIC_SUITE,
            FallbackReason::SuiteNegotiationFailed,
            None,
        );
        let second = gate.authorize_downgrade(
            "peer-a",
            PQC_SUITE,
            CLASSIC_SUITE,
            FallbackReason::SuiteNegotiationFailed,
            None,
        );
        assert!(first.is_allowed());
        assert!(
            second.is_allowed(),
            "expired cooldown should re-allow fallback"
        );
    }

    // ---- DowngradeEvent round-trips through serde ----

    #[test]
    fn downgrade_event_round_trips_through_serde() {
        let mut gate = PolicyGate::new(DowngradePolicy::PreferPqc);
        let decision = gate.authorize_downgrade(
            "peer-roundtrip",
            PQC_SUITE,
            CLASSIC_SUITE,
            FallbackReason::PqcProviderUnavailable,
            Some(&[0xde, 0xad, 0xbe, 0xef]),
        );
        let event = decision.event().cloned().expect("authorized => event");

        let json = serde_json::to_string(&event).expect("serialize");
        let decoded: DowngradeEvent = serde_json::from_str(&json).expect("deserialize");

        assert_eq!(decoded, event);
        assert_eq!(decoded.peer, "peer-roundtrip");
        assert_eq!(decoded.from_suite, PQC_SUITE.wire_id);
        assert_eq!(decoded.to_suite, CLASSIC_SUITE.wire_id);
        assert_eq!(decoded.reason, FallbackReason::PqcProviderUnavailable);
        assert_eq!(decoded.policy, DowngradePolicy::PreferPqc);
        assert_eq!(decoded.cooldown_seconds, FALLBACK_COOLDOWN.as_secs());
        assert_eq!(decoded.transcript_anchor.as_deref(), Some("deadbeef"));
        assert_eq!(
            decoded.downgrade_resistance,
            DowngradeEvent::DOWNGRADE_RESISTANCE
        );
    }

    // ---- Signing: sign -> verify round-trips, tamper/wrong-key fail ----

    fn sample_event() -> DowngradeEvent {
        let mut gate = PolicyGate::new(DowngradePolicy::PreferPqc);
        gate.authorize_downgrade(
            "device-fedcba0987654321",
            PQC_SUITE,
            CLASSIC_SUITE,
            FallbackReason::PqcProviderUnavailable,
            Some(&[0x01, 0x02, 0x03, 0x04]),
        )
        .event()
        .cloned()
        .expect("authorized => event")
    }

    #[test]
    fn signed_event_round_trips_sign_then_verify() {
        let (public_key, secret_key) = crate::mldsa65_generate_keypair();
        let signed = SignedDowngradeEvent::sign(
            sample_event(),
            ProtocolSigningAlgorithm::MlDsa65,
            &public_key,
            &secret_key,
        )
        .expect("sign");
        // Verifies against the embedded key and against the same key supplied out-of-band.
        signed.verify().expect("self-verify");
        signed.verify_with(&public_key).expect("trusted-key verify");
    }

    #[test]
    fn signed_event_survives_serde_round_trip() {
        let (public_key, secret_key) = crate::mldsa65_generate_keypair();
        let signed = SignedDowngradeEvent::sign(
            sample_event(),
            ProtocolSigningAlgorithm::MlDsa65,
            &public_key,
            &secret_key,
        )
        .expect("sign");
        let json = serde_json::to_string(&signed).expect("serialize");
        let decoded: SignedDowngradeEvent = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded, signed);
        // The inner event's own serde encoding is unchanged / still present.
        assert_eq!(decoded.event, signed.event);
        decoded.verify().expect("verify after serde round-trip");
    }

    #[test]
    fn tampered_event_fails_verification() {
        let (public_key, secret_key) = crate::mldsa65_generate_keypair();
        let signed = SignedDowngradeEvent::sign(
            sample_event(),
            ProtocolSigningAlgorithm::MlDsa65,
            &public_key,
            &secret_key,
        )
        .expect("sign");

        // Mutate a field after signing: the recomputed canonical bytes no longer match.
        let mut tampered = signed.clone();
        tampered.event.peer = "device-attacker0000000".to_owned();
        assert!(
            matches!(
                tampered.verify(),
                Err(DowngradeSignatureError::InvalidSignature(_))
            ),
            "a tampered event must fail signature verification"
        );

        // Flipping the recorded suite is also caught.
        let mut tampered_suite = signed.clone();
        tampered_suite.event.to_suite = PQC_SUITE.wire_id;
        assert!(tampered_suite.verify().is_err());
    }

    #[test]
    fn wrong_key_fails_verification() {
        let (public_key, secret_key) = crate::mldsa65_generate_keypair();
        let (other_public_key, _other_secret_key) = crate::mldsa65_generate_keypair();
        let signed = SignedDowngradeEvent::sign(
            sample_event(),
            ProtocolSigningAlgorithm::MlDsa65,
            &public_key,
            &secret_key,
        )
        .expect("sign");
        // A different (attacker / unrelated) public key must not verify the signature.
        assert!(
            signed.verify_with(&other_public_key).is_err(),
            "verifying against the wrong key must fail"
        );
    }

    #[test]
    fn signing_rejects_non_mldsa_identity() {
        let (public_key, secret_key) = crate::mldsa65_generate_keypair();
        let result = SignedDowngradeEvent::sign(
            sample_event(),
            ProtocolSigningAlgorithm::Ed25519,
            &public_key,
            &secret_key,
        );
        assert!(matches!(
            result,
            Err(DowngradeSignatureError::UnsupportedSignerAlgorithm(
                ProtocolSigningAlgorithm::Ed25519
            ))
        ));
    }

    #[test]
    fn canonical_bytes_are_deterministic_and_domain_separated() {
        let event = sample_event();
        assert_eq!(event.canonical_bytes(), event.canonical_bytes());
        assert!(
            event
                .canonical_bytes()
                .starts_with(DowngradeEvent::SIGNING_DOMAIN),
            "canonical pre-image must be domain-separated"
        );
    }

    // ---- Wire encoding parity with the on-wire policy bytes ----

    #[test]
    fn policy_wire_bytes_match_legacy_format() {
        // PreferPqc / strict realizations encode requirePQC=1; Default=0.
        assert_eq!(encode_policy_wire_byte(DowngradePolicy::PreferPqc), 0x01);
        assert_eq!(
            encode_policy_wire_byte(DowngradePolicy::StrictPqcCompliance),
            0x01
        );
        assert_eq!(encode_policy_wire_byte(DowngradePolicy::Default), 0x00);
    }
}

/// Encode a policy posture's `requirePQC` flag into the legacy on-wire policy byte
/// (`pqc_policy_bytes` emits `0x01`; `classic_policy_bytes` emits `0x00`).
///
/// Kept here so the handshake codecs and the policy layer agree on the meaning of
/// the first policy byte without changing the wire format.
pub(crate) fn encode_policy_wire_byte(policy: DowngradePolicy) -> u8 {
    if policy.requires_pqc() { 0x01 } else { 0x00 }
}
