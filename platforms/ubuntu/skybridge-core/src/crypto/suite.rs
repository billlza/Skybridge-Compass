//! Crypto Suites
//!
//! Defines the supported cryptographic suites for P2P connections.

use serde::{Deserialize, Serialize};

use super::aead::AeadAlgorithm;
use super::kem::KemAlgorithm;
use super::signature::SignatureAlgorithm;

/// Crypto suite identifier
///
/// Suite IDs are defined to match the cross-platform specification:
/// - 0x0001: Hybrid PQC (X-Wing) - Preferred for quantum-safe + classical security
/// - 0x0101: Pure PQC (ML-KEM-768) - Pure post-quantum
/// - 0x0102: Pure PQC FS variant (ML-KEM-768-FS) - ML-KEM-768 plus an X25519 FS contribution
/// - 0x1001: Classic (X25519) - For compatibility with non-PQC platforms
/// - 0x1002: Classic P-256 marker - parsed for compatibility; not negotiated by default
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u16)]
#[allow(non_camel_case_types)]
pub enum CryptoSuiteId {
    /// X-Wing (hybrid X25519 + ML-KEM-768) + AES-256-GCM + ML-DSA-65
    /// Preferred suite for quantum-resistant security with classic fallback
    /// Supported: Ubuntu 22-25, macOS 26+, iOS 26+, Windows 11, Android 16+
    XWing_AES256GCM_MlDsa65 = 0x0001,

    /// ML-KEM-768 + AES-256-GCM + ML-DSA-65
    /// Pure post-quantum cryptography
    MlKem768_AES256GCM_MlDsa65 = 0x0101,

    /// ML-KEM-768-FS + AES-256-GCM + ML-DSA-65
    /// Uses the ML-KEM-768 identity key plus an extra X25519 transcript-bound
    /// forward-secure contribution.
    MlKem768FsCompat_AES256GCM_MlDsa65 = 0x0102,

    /// X25519 + AES-256-GCM + Ed25519
    /// Classic cryptography for compatibility with older platforms (macOS <26, iOS <26)
    X25519_AES256GCM_Ed25519 = 0x1001,

    /// P-256 + AES-256-GCM + Ed25519
    /// Compatibility marker for classic peers that advertise 0x1002.
    /// This Ubuntu build currently parses this ID but does not negotiate it.
    P256Compat_AES256GCM_Ed25519 = 0x1002,
}

impl CryptoSuiteId {
    /// Get the wire ID for this suite
    pub fn wire_id(&self) -> u16 {
        *self as u16
    }

    /// Parse from wire ID
    pub fn from_wire_id(id: u16) -> Option<Self> {
        match id {
            0x0001 => Some(Self::XWing_AES256GCM_MlDsa65),
            0x0101 => Some(Self::MlKem768_AES256GCM_MlDsa65),
            0x0102 => Some(Self::MlKem768FsCompat_AES256GCM_MlDsa65),
            0x1001 => Some(Self::X25519_AES256GCM_Ed25519),
            0x1002 => Some(Self::P256Compat_AES256GCM_Ed25519),
            _ => None,
        }
    }

    /// Check if this is a post-quantum suite
    pub fn is_pqc(&self) -> bool {
        matches!(
            self,
            Self::MlKem768_AES256GCM_MlDsa65
                | Self::MlKem768FsCompat_AES256GCM_MlDsa65
                | Self::XWing_AES256GCM_MlDsa65
        )
    }

    /// Check if this is a hybrid suite
    pub fn is_hybrid(&self) -> bool {
        matches!(self, Self::XWing_AES256GCM_MlDsa65)
    }

    /// Check if this is the v2-FS suite marker.
    pub fn is_forward_secure_v2(&self) -> bool {
        matches!(self, Self::MlKem768FsCompat_AES256GCM_MlDsa65)
    }

    /// Canonical KEM identity suite used for long-lived public keys.
    pub fn canonical_kem_suite(&self) -> Self {
        match self {
            Self::MlKem768FsCompat_AES256GCM_MlDsa65 => Self::MlKem768_AES256GCM_MlDsa65,
            Self::P256Compat_AES256GCM_Ed25519 => Self::X25519_AES256GCM_Ed25519,
            _ => *self,
        }
    }

    /// Check if this is a classic compatibility marker suite.
    pub fn is_classic_compat_marker(&self) -> bool {
        matches!(self, Self::P256Compat_AES256GCM_Ed25519)
    }

    /// Whether the suite is negotiable in the current Ubuntu handshake implementation.
    pub fn is_negotiable(&self) -> bool {
        !self.is_classic_compat_marker()
    }

    /// Get all supported suites ordered by preference
    pub fn all() -> &'static [CryptoSuiteId] {
        &[
            // Prefer hybrid PQC suite (quantum-safe + classical security)
            Self::XWing_AES256GCM_MlDsa65,
            // Then forward-secure pure PQC
            Self::MlKem768FsCompat_AES256GCM_MlDsa65,
            // Then pure PQC
            Self::MlKem768_AES256GCM_MlDsa65,
            // Then classic suite for compatibility
            Self::X25519_AES256GCM_Ed25519,
        ]
    }

    /// Get classic-only suites (non-PQC)
    pub fn classic() -> &'static [CryptoSuiteId] {
        &[Self::X25519_AES256GCM_Ed25519]
    }

    /// Get PQC suites (quantum-safe)
    pub fn pqc() -> &'static [CryptoSuiteId] {
        &[
            Self::XWing_AES256GCM_MlDsa65,
            Self::MlKem768FsCompat_AES256GCM_MlDsa65,
            Self::MlKem768_AES256GCM_MlDsa65,
        ]
    }
}

/// Complete cryptographic suite configuration
#[derive(Debug, Clone)]
pub struct CryptoSuite {
    /// Suite identifier
    pub id: CryptoSuiteId,
    /// Human-readable name
    pub name: &'static str,
    /// KEM algorithm
    pub kem: KemAlgorithm,
    /// AEAD algorithm
    pub aead: AeadAlgorithm,
    /// Signature algorithm
    pub signature: SignatureAlgorithm,
}

impl CryptoSuite {
    /// Get suite configuration from ID
    pub fn from_id(id: CryptoSuiteId) -> Self {
        match id {
            CryptoSuiteId::XWing_AES256GCM_MlDsa65 => Self {
                id,
                name: "X-Wing-AES256GCM-ML-DSA-65",
                kem: KemAlgorithm::XWing,
                aead: AeadAlgorithm::Aes256Gcm,
                signature: SignatureAlgorithm::MlDsa65,
            },
            CryptoSuiteId::MlKem768_AES256GCM_MlDsa65 => Self {
                id,
                name: "ML-KEM-768-AES256GCM-ML-DSA-65",
                kem: KemAlgorithm::MlKem768,
                aead: AeadAlgorithm::Aes256Gcm,
                signature: SignatureAlgorithm::MlDsa65,
            },
            CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65 => Self {
                id,
                name: "ML-KEM-768-FS-AES256GCM-ML-DSA-65",
                kem: KemAlgorithm::MlKem768,
                aead: AeadAlgorithm::Aes256Gcm,
                signature: SignatureAlgorithm::MlDsa65,
            },
            CryptoSuiteId::X25519_AES256GCM_Ed25519 => Self {
                id,
                name: "X25519-AES256GCM-Ed25519",
                kem: KemAlgorithm::X25519,
                aead: AeadAlgorithm::Aes256Gcm,
                signature: SignatureAlgorithm::Ed25519,
            },
            CryptoSuiteId::P256Compat_AES256GCM_Ed25519 => Self {
                id,
                name: "P256-AES256GCM-Ed25519 (compat, non-negotiable)",
                // Parse-only compatibility marker. Ubuntu does not negotiate P-256
                // as a KEM in this build, so we map primitives conservatively.
                kem: KemAlgorithm::X25519,
                aead: AeadAlgorithm::Aes256Gcm,
                signature: SignatureAlgorithm::Ed25519,
            },
        }
    }

    /// Check if this suite uses post-quantum cryptography
    pub fn is_pqc(&self) -> bool {
        self.id.is_pqc()
    }

    /// Check if this suite uses hybrid key exchange
    pub fn is_hybrid(&self) -> bool {
        self.id.is_hybrid()
    }

    /// Get the preferred suite
    pub fn preferred() -> Self {
        Self::from_id(CryptoSuiteId::XWing_AES256GCM_MlDsa65)
    }

    /// Get all supported suites
    pub fn all() -> Vec<Self> {
        CryptoSuiteId::all()
            .iter()
            .map(|id| Self::from_id(*id))
            .collect()
    }

    /// Negotiate the best suite from supported and offered suites
    pub fn negotiate(our_suites: &[CryptoSuiteId], their_suites: &[CryptoSuiteId]) -> Option<Self> {
        // Our suites are ordered by preference
        for &our_id in our_suites {
            if !our_id.is_negotiable() {
                continue;
            }
            if their_suites.contains(&our_id) {
                return Some(Self::from_id(our_id));
            }
        }
        None
    }
}

impl std::fmt::Display for CryptoSuite {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_suite_negotiation() {
        let our_suites = CryptoSuiteId::all();
        let their_suites = CryptoSuiteId::classic();

        let negotiated = CryptoSuite::negotiate(our_suites, their_suites);
        assert!(negotiated.is_some());

        // Should pick the first classic suite since that's the first match
        let suite = negotiated.unwrap();
        assert!(!suite.is_pqc());
    }

    #[test]
    fn test_suite_pqc_negotiation() {
        let our_suites = CryptoSuiteId::pqc();
        let their_suites = CryptoSuiteId::all();

        let negotiated = CryptoSuite::negotiate(our_suites, their_suites);
        assert!(negotiated.is_some());
        assert!(negotiated.unwrap().is_pqc());
    }

    #[test]
    fn test_no_common_suite() {
        let our_suites = CryptoSuiteId::pqc();
        let their_suites = CryptoSuiteId::classic();

        let negotiated = CryptoSuite::negotiate(our_suites, their_suites);
        assert!(negotiated.is_none());
    }

    #[test]
    fn test_wire_id_roundtrip() {
        for &id in CryptoSuiteId::all() {
            let wire_id = id.wire_id();
            let parsed = CryptoSuiteId::from_wire_id(wire_id);
            assert_eq!(Some(id), parsed);
        }
        assert_eq!(
            CryptoSuiteId::from_wire_id(0x0102),
            Some(CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65)
        );
        assert_eq!(
            CryptoSuiteId::from_wire_id(0x1002),
            Some(CryptoSuiteId::P256Compat_AES256GCM_Ed25519)
        );
    }

    #[test]
    fn test_v2_fs_suite_is_negotiable() {
        assert!(CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65.is_forward_secure_v2());
        assert!(CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65.is_negotiable());
        assert!(CryptoSuiteId::all().contains(&CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65));
    }

    #[test]
    fn test_p256_compat_suite_is_parse_only_by_default() {
        assert!(CryptoSuiteId::P256Compat_AES256GCM_Ed25519.is_classic_compat_marker());
        assert!(!CryptoSuiteId::P256Compat_AES256GCM_Ed25519.is_negotiable());
        assert!(!CryptoSuiteId::all().contains(&CryptoSuiteId::P256Compat_AES256GCM_Ed25519));
    }
}
