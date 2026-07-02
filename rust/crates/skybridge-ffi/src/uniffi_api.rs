//! **UniFFI** (proc-macro) surface — one Rust definition that generates Kotlin
//! (Android) and Swift bindings.
//!
//! This mirrors the C-ABI surface for the parts UniFFI models idiomatically
//! (records, enums, an object with methods, and free functions). UniFFI gives
//! managed bindings — Kotlin/Swift get garbage-collected objects, native enums,
//! and thrown errors instead of raw pointers and status codes — which is the
//! ergonomic path for Android and Apple consumers, while the C ABI remains the
//! path for C/C++/C# P/Invoke.
//!
//! Generate bindings with the in-tree binary (see `src/bin/uniffi_bindgen.rs`):
//!
//! ```text
//! cargo run -p skybridge-ffi --features uniffi-scaffolding --bin uniffi-bindgen -- \
//!     generate --library target/debug/libskybridge_ffi.dylib \
//!     --language kotlin --out-dir target/bindings/kotlin
//! ```

use std::sync::Mutex;

use skybridge_core::{
    CryptoSuite, DowngradeDecision, DowngradePolicy, FallbackReason, PolicyGate,
    RustPqcIdentityMaterial,
};

/// Errors surfaced to UniFFI consumers (thrown as exceptions in Kotlin/Swift).
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SkyBridgeFfiError {
    /// A downgrade authorization was denied; the message explains why.
    #[error("downgrade denied: {message}")]
    DowngradeDenied { message: String },
    /// An underlying core operation failed.
    #[error("core error: {message}")]
    Core { message: String },
    /// An argument was invalid.
    #[error("invalid argument: {message}")]
    InvalidArgument { message: String },
}

/// Downgrade posture (UniFFI enum mirror of [`skybridge_core::DowngradePolicy`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDowngradePolicy {
    /// Strict PQC, compliance: classic fallback is never allowed.
    StrictPqcCompliance,
    /// Strict PQC, bootstrap-assisted: one-time classic control channel only.
    StrictPqcBootstrapAssisted,
    /// Prefer PQC, allow eligible + rate-limited classic business fallback.
    PreferPqc,
    /// Default posture: no mandatory initial PQC attempt; same fallback gating.
    Default,
}

impl From<FfiDowngradePolicy> for DowngradePolicy {
    fn from(value: FfiDowngradePolicy) -> Self {
        match value {
            FfiDowngradePolicy::StrictPqcCompliance => DowngradePolicy::StrictPqcCompliance,
            FfiDowngradePolicy::StrictPqcBootstrapAssisted => {
                DowngradePolicy::StrictPqcBootstrapAssisted
            }
            FfiDowngradePolicy::PreferPqc => DowngradePolicy::PreferPqc,
            FfiDowngradePolicy::Default => DowngradePolicy::Default,
        }
    }
}

impl From<DowngradePolicy> for FfiDowngradePolicy {
    fn from(value: DowngradePolicy) -> Self {
        match value {
            DowngradePolicy::StrictPqcCompliance => FfiDowngradePolicy::StrictPqcCompliance,
            DowngradePolicy::StrictPqcBootstrapAssisted => {
                FfiDowngradePolicy::StrictPqcBootstrapAssisted
            }
            DowngradePolicy::PreferPqc => FfiDowngradePolicy::PreferPqc,
            DowngradePolicy::Default => FfiDowngradePolicy::Default,
        }
    }
}

/// Failure reason (UniFFI enum mirror of [`skybridge_core::FallbackReason`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiFallbackReason {
    /// ALLOWED: no usable PQC provider/suite is available locally.
    PqcProviderUnavailable,
    /// ALLOWED: PQC suite negotiation produced no mutually supported suite.
    SuiteNegotiationFailed,
    /// BLOCKED: network-derived timeout (never downgrade-eligible).
    Timeout,
    /// BLOCKED: peer signature failed to verify.
    SignatureVerificationFailed,
    /// BLOCKED: replay / anti-rollback detection tripped.
    ReplayDetected,
    /// BLOCKED: key confirmation (FINISHED MAC) failed.
    KeyConfirmationFailed,
    /// BLOCKED: peer identity did not match the pinned/enrolled identity.
    IdentityMismatch,
    /// BLOCKED: signed suite list did not match the negotiated suite.
    SuiteSignatureMismatch,
}

impl From<FfiFallbackReason> for FallbackReason {
    fn from(value: FfiFallbackReason) -> Self {
        match value {
            FfiFallbackReason::PqcProviderUnavailable => FallbackReason::PqcProviderUnavailable,
            FfiFallbackReason::SuiteNegotiationFailed => FallbackReason::SuiteNegotiationFailed,
            FfiFallbackReason::Timeout => FallbackReason::Timeout,
            FfiFallbackReason::SignatureVerificationFailed => {
                FallbackReason::SignatureVerificationFailed
            }
            FfiFallbackReason::ReplayDetected => FallbackReason::ReplayDetected,
            FfiFallbackReason::KeyConfirmationFailed => FallbackReason::KeyConfirmationFailed,
            FfiFallbackReason::IdentityMismatch => FallbackReason::IdentityMismatch,
            FfiFallbackReason::SuiteSignatureMismatch => FallbackReason::SuiteSignatureMismatch,
        }
    }
}

/// A generated PQC device identity's *public* material (UniFFI record).
///
/// This is the safe-to-share half of a [`skybridge_core::RustPqcIdentityMaterial`]:
/// the secret keys never cross the binding boundary.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiPublicIdentity {
    /// ML-DSA-65 signing public key bytes.
    pub signing_public_key: Vec<u8>,
    /// ML-KEM-768 KEM public key bytes.
    pub mlkem768_public_key: Vec<u8>,
    /// X-Wing hybrid KEM public key bytes.
    pub xwing_public_key: Vec<u8>,
}

/// The result of asking the policy gate to authorize a downgrade (UniFFI record).
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiDowngradeOutcome {
    /// Whether the downgrade was authorized.
    pub authorized: bool,
    /// JSON of the auditable `DowngradeEvent` when authorized, otherwise a small
    /// JSON object describing the denial.
    pub detail_json: String,
}

/// Generate a fresh PQC device identity and return its public material.
///
/// The secret keys are generated and immediately dropped here — only the public
/// keys are returned. (For long-lived identities the host should persist via the
/// agent state store; this entry point proves the generation surface.)
#[uniffi::export]
pub fn generate_public_identity() -> Result<FfiPublicIdentity, SkyBridgeFfiError> {
    let material = RustPqcIdentityMaterial::generate().map_err(|e| SkyBridgeFfiError::Core {
        message: e.to_string(),
    })?;
    Ok(FfiPublicIdentity {
        signing_public_key: material.signing_public_key,
        mlkem768_public_key: material.mlkem768_public_key,
        xwing_public_key: material.xwing_public_key,
    })
}

/// Library version string.
#[uniffi::export]
pub fn library_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

/// A policy gate exposed as a UniFFI **object** (reference type with methods).
///
/// Kotlin/Swift get a managed handle; method calls route into the same
/// [`skybridge_core::PolicyGate`] the C ABI uses. Interior mutability via a
/// `Mutex` keeps the UniFFI-required `Send + Sync` while letting
/// `authorize_downgrade` take `&self`.
#[derive(uniffi::Object)]
pub struct FfiPolicyGate {
    inner: Mutex<PolicyGate>,
    policy: DowngradePolicy,
}

#[uniffi::export]
impl FfiPolicyGate {
    /// Construct a gate with the given posture and the canonical 300s cooldown.
    #[uniffi::constructor]
    pub fn new(policy: FfiDowngradePolicy) -> Self {
        let core_policy: DowngradePolicy = policy.into();
        Self {
            inner: Mutex::new(PolicyGate::new(core_policy)),
            policy: core_policy,
        }
    }

    /// The configured downgrade posture.
    pub fn policy(&self) -> FfiDowngradePolicy {
        self.policy.into()
    }

    /// Authorize (or deny) a PQC→Classic downgrade for `peer`.
    ///
    /// Returns an [`FfiDowngradeOutcome`] for both authorized and denied cases
    /// (denied is a normal result, not an error); only an internal serialization
    /// failure surfaces as [`SkyBridgeFfiError::Core`].
    pub fn authorize_downgrade(
        &self,
        peer: String,
        from_suite_wire: u16,
        to_suite_wire: u16,
        reason: FfiFallbackReason,
        transcript_anchor: Option<Vec<u8>>,
    ) -> Result<FfiDowngradeOutcome, SkyBridgeFfiError> {
        let mut gate = self.inner.lock().map_err(|_| SkyBridgeFfiError::Core {
            message: "policy gate poisoned".into(),
        })?;
        let decision = gate.authorize_downgrade(
            &peer,
            CryptoSuite::from_wire_id(from_suite_wire),
            CryptoSuite::from_wire_id(to_suite_wire),
            reason.into(),
            transcript_anchor.as_deref(),
        );
        Ok(decision_to_outcome(&decision))
    }
}

fn decision_to_outcome(decision: &DowngradeDecision) -> FfiDowngradeOutcome {
    match decision {
        DowngradeDecision::Allowed(event) => FfiDowngradeOutcome {
            authorized: true,
            detail_json: serde_json::to_string(event)
                .unwrap_or_else(|_| "{\"error\":\"serialize\"}".to_owned()),
        },
        DowngradeDecision::DeniedByPolicy => FfiDowngradeOutcome {
            authorized: false,
            detail_json: "{\"denied\":\"policy\"}".to_owned(),
        },
        DowngradeDecision::DeniedReasonIneligible(reason) => FfiDowngradeOutcome {
            authorized: false,
            detail_json: format!(
                "{{\"denied\":\"reason_ineligible\",\"reason\":\"{}\"}}",
                reason.diagnostic_code()
            ),
        },
        DowngradeDecision::DeniedRateLimited { remaining } => FfiDowngradeOutcome {
            authorized: false,
            detail_json: format!(
                "{{\"denied\":\"rate_limited\",\"remaining_seconds\":{}}}",
                remaining.as_secs()
            ),
        },
    }
}

/// A decoded discovery snapshot device (UniFFI record), for clients that want a
/// typed peer list rather than parsing the JSON snapshot themselves.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiDiscoveredDevice {
    /// Locator-free, stable device reference (`id-<hash>`).
    pub device_ref: String,
    /// Display name (sanitized).
    pub display_name: String,
    /// Capability tokens advertised by the peer.
    pub capabilities: Vec<String>,
    /// Whether the peer is connectable (verified/trusted + reachable).
    pub connectable: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uniffi_generate_public_identity_has_keys() {
        let id = generate_public_identity().expect("identity generation");
        assert!(!id.signing_public_key.is_empty());
        assert!(!id.mlkem768_public_key.is_empty());
        assert!(!id.xwing_public_key.is_empty());
    }

    #[test]
    fn uniffi_policy_gate_authorizes_and_denies() {
        let gate = FfiPolicyGate::new(FfiDowngradePolicy::PreferPqc);
        assert_eq!(gate.policy(), FfiDowngradePolicy::PreferPqc);

        let allowed = gate
            .authorize_downgrade(
                "peer-uniffi".into(),
                CryptoSuite::MLKEM768_MLDSA65.wire_id,
                CryptoSuite::X25519_ED25519.wire_id,
                FfiFallbackReason::PqcProviderUnavailable,
                Some(vec![0xab, 0xcd]),
            )
            .expect("authorize");
        assert!(allowed.authorized);
        assert!(allowed.detail_json.contains("downgrade_resistance"));

        let denied = gate
            .authorize_downgrade(
                "peer-uniffi".into(),
                CryptoSuite::MLKEM768_MLDSA65.wire_id,
                CryptoSuite::X25519_ED25519.wire_id,
                FfiFallbackReason::Timeout,
                None,
            )
            .expect("authorize-call ok");
        assert!(!denied.authorized);
        assert!(denied.detail_json.contains("reason_ineligible"));
    }

    #[test]
    fn uniffi_library_version_matches_pkg() {
        assert_eq!(library_version(), env!("CARGO_PKG_VERSION"));
    }
}
