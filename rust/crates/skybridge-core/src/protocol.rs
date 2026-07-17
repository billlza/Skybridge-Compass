use std::fmt::{Display, Formatter};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ProtocolSigningAlgorithm {
    #[serde(rename = "Ed25519")]
    Ed25519,
    #[serde(rename = "ML-DSA-65")]
    MlDsa65,
}

impl ProtocolSigningAlgorithm {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ed25519 => "Ed25519",
            Self::MlDsa65 => "ML-DSA-65",
        }
    }
}

impl Display for ProtocolSigningAlgorithm {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::str::FromStr for ProtocolSigningAlgorithm {
    type Err = CurrentPathSecurityError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let trimmed = value.trim();
        match trimmed {
            "Ed25519" | "ed25519" => Ok(Self::Ed25519),
            "ML-DSA-65" | "mldsa65" | "MLDSA65" => Ok(Self::MlDsa65),
            _ => Err(CurrentPathSecurityError::InvalidProtocolIdentity(
                "unknown signing algorithm".to_owned(),
            )),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct CryptoSuite {
    pub wire_id: u16,
}

impl CryptoSuite {
    pub const XWING_MLDSA: Self = Self { wire_id: 0x0001 };
    /// Decode-only legacy Q-Periapt ContextBound suite. Wire id 0x0011 remains
    /// recognizable for compatibility diagnostics, but is never negotiable or
    /// operator-selectable; the authenticated ABI2 policy suite uses a distinct
    /// contract in the Apple implementation.
    pub const QPERIAPT_CONTEXTBOUND_MLDSA65: Self = Self { wire_id: 0x0011 };
    pub const MLKEM768_MLDSA65: Self = Self { wire_id: 0x0101 };
    pub const MLKEM768_MLDSA65_FS: Self = Self { wire_id: 0x0102 };
    pub const X25519_ED25519: Self = Self { wire_id: 0x1001 };
    pub const P256_ECDSA: Self = Self { wire_id: 0x1002 };

    pub const fn from_wire_id(wire_id: u16) -> Self {
        Self { wire_id }
    }

    pub fn from_name(value: &str) -> Option<Self> {
        let normalized = value.trim().to_ascii_lowercase();
        match normalized.as_str() {
            "x-wing" | "x-wing+mldsa65" | "x-wing+ml-dsa-65" | "xwing" => Some(Self::XWING_MLDSA),
            "ml-kem-768" | "ml-kem-768+mldsa65" | "ml-kem-768+ml-dsa-65" => {
                Some(Self::MLKEM768_MLDSA65)
            }
            "ml-kem-768-fs" | "ml-kem-768-fs+mldsa65" | "ml-kem-768-fs+ml-dsa-65" => {
                Some(Self::MLKEM768_MLDSA65_FS)
            }
            "x25519" | "x25519+ed25519" => Some(Self::X25519_ED25519),
            "p-256" | "p-256+ecdsa" | "p256" => Some(Self::P256_ECDSA),
            _ => None,
        }
    }

    pub fn as_known_name(self) -> Option<&'static str> {
        match self.wire_id {
            0x0001 => Some("X-Wing"),
            0x0011 => Some("Q-Periapt-ContextBound"),
            0x0101 => Some("ML-KEM-768"),
            0x0102 => Some("ML-KEM-768-FS"),
            0x1001 => Some("X25519"),
            0x1002 => Some("P-256"),
            _ => None,
        }
    }

    pub fn is_known(self) -> bool {
        self.as_known_name().is_some()
    }

    pub fn is_legacy_only(self) -> bool {
        self.wire_id == Self::QPERIAPT_CONTEXTBOUND_MLDSA65.wire_id
    }

    pub fn is_negotiable(self) -> bool {
        self.is_known() && !self.is_legacy_only()
    }

    pub fn is_pqc(self) -> bool {
        matches!(self.wire_id >> 8, 0x00 | 0x01)
    }

    pub fn is_hybrid(self) -> bool {
        (self.wire_id >> 8) == 0x00
    }

    pub fn canonical_kem_suite(self) -> Self {
        match self.wire_id {
            0x0102 => Self::MLKEM768_MLDSA65,
            _ => self,
        }
    }
}

impl Display for CryptoSuite {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self.as_known_name() {
            Some(name) => f.write_str(name),
            None => write!(f, "unknown-{}", self.wire_id),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CurrentPathFailureClass {
    PeerReverificationRequired,
    IdentityConflict,
    DeviceIdMigrationRequired,
    BootstrapVersionRejected,
    BootstrapOriginMismatch,
    BootstrapExpired,
    BootstrapTokenConsumed,
    SessionExpired,
    QuarantinedIdentity,
    RevokedIdentity,
    AuthTokenRejected,
    MissingPinnedTrust,
    LegacyTrustInsufficient,
    IntegrityProofRequired,
    FinalDigestMismatch,
    MerkleMismatch,
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum CurrentPathSecurityError {
    #[error("invalid current-path deviceId")]
    InvalidDeviceId,
    #[error("invalid signaling origin")]
    InvalidOrigin,
    #[error("invalid authoritative identity: {0}")]
    InvalidProtocolIdentity(String),
    #[error("invalid bootstrap payload: {0}")]
    InvalidBootstrap(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProtocolIdentityBinding {
    pub device_id: String,
    pub protocol_signing_algorithm: ProtocolSigningAlgorithm,
    #[serde(with = "base64_standard")]
    pub protocol_public_key_bytes: Vec<u8>,
    pub protocol_public_key_fingerprint: String,
}

impl ProtocolIdentityBinding {
    pub const MAX_DEVICE_ID_LENGTH: usize = 128;
    pub const MIN_DEVICE_ID_LENGTH: usize = 16;

    pub fn new(
        device_id: impl Into<String>,
        protocol_signing_algorithm: ProtocolSigningAlgorithm,
        protocol_public_key_bytes: Vec<u8>,
        protocol_public_key_fingerprint: Option<String>,
    ) -> Result<Self, CurrentPathSecurityError> {
        let device_id = Self::normalized_device_id(&device_id.into())?;
        Self::validate_key_encoding(&protocol_public_key_bytes, protocol_signing_algorithm)?;
        let fingerprint = protocol_public_key_fingerprint.unwrap_or_else(|| {
            Self::compute_fingerprint(protocol_signing_algorithm, &protocol_public_key_bytes)
        });
        if !Self::is_valid_fingerprint(&fingerprint) {
            return Err(CurrentPathSecurityError::InvalidProtocolIdentity(
                "invalid authoritative fingerprint".to_owned(),
            ));
        }

        Ok(Self {
            device_id,
            protocol_signing_algorithm,
            protocol_public_key_bytes,
            protocol_public_key_fingerprint: fingerprint.to_ascii_lowercase(),
        })
    }

    pub fn normalized_device_id(raw: &str) -> Result<String, CurrentPathSecurityError> {
        let candidate = raw.trim();
        if candidate.len() < Self::MIN_DEVICE_ID_LENGTH
            || candidate.len() > Self::MAX_DEVICE_ID_LENGTH
        {
            return Err(CurrentPathSecurityError::InvalidDeviceId);
        }
        if !candidate
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'-'))
        {
            return Err(CurrentPathSecurityError::InvalidDeviceId);
        }
        Ok(candidate.to_owned())
    }

    pub fn is_valid_fingerprint(raw: &str) -> bool {
        raw.len() == 64
            && raw
                .chars()
                .all(|ch| ch.is_ascii_hexdigit() && !ch.is_ascii_uppercase())
    }

    pub fn validate_key_encoding(
        public_key_bytes: &[u8],
        algorithm: ProtocolSigningAlgorithm,
    ) -> Result<(), CurrentPathSecurityError> {
        match algorithm {
            ProtocolSigningAlgorithm::Ed25519 if public_key_bytes.len() == 32 => Ok(()),
            ProtocolSigningAlgorithm::Ed25519 => {
                Err(CurrentPathSecurityError::InvalidProtocolIdentity(
                    "ed25519 public key must be 32 bytes".to_owned(),
                ))
            }
            ProtocolSigningAlgorithm::MlDsa65 if public_key_bytes.is_empty() => {
                Err(CurrentPathSecurityError::InvalidProtocolIdentity(
                    "mlDSA65 public key must not be empty".to_owned(),
                ))
            }
            ProtocolSigningAlgorithm::MlDsa65 => Ok(()),
        }
    }

    pub fn compute_fingerprint(
        algorithm: ProtocolSigningAlgorithm,
        public_key_bytes: &[u8],
    ) -> String {
        let mut payload = Vec::new();
        let tag = algorithm.as_str().as_bytes();
        payload.extend_from_slice(&(tag.len() as u16).to_le_bytes());
        payload.extend_from_slice(tag);
        payload.extend_from_slice(&(public_key_bytes.len() as u32).to_le_bytes());
        payload.extend_from_slice(public_key_bytes);
        let digest = Sha256::digest(payload);
        digest.iter().map(|byte| format!("{byte:02x}")).collect()
    }
}

pub struct CurrentPathOriginPolicy;

impl CurrentPathOriginPolicy {
    pub fn canonical_origin(raw: &str) -> Result<String, CurrentPathSecurityError> {
        let parsed = url::Url::parse(raw).map_err(|_| CurrentPathSecurityError::InvalidOrigin)?;
        let scheme = parsed.scheme().to_ascii_lowercase();
        if scheme != "https" && scheme != "http" {
            return Err(CurrentPathSecurityError::InvalidOrigin);
        }
        if parsed.host_str().is_none() || parsed.query().is_some() || parsed.fragment().is_some() {
            return Err(CurrentPathSecurityError::InvalidOrigin);
        }
        if parsed.path() != "/" && !parsed.path().is_empty() {
            return Err(CurrentPathSecurityError::InvalidOrigin);
        }
        let host = parsed
            .host_str()
            .ok_or(CurrentPathSecurityError::InvalidOrigin)?
            .to_ascii_lowercase();
        let port = parsed.port();
        let explicit_port = match (scheme.as_str(), port) {
            ("https", None | Some(443)) | ("http", None | Some(80)) => None,
            (_, value) => value,
        };
        Ok(match explicit_port {
            Some(port) => format!("{scheme}://{host}:{port}"),
            None => format!("{scheme}://{host}"),
        })
    }
}

pub fn base64_url_encode(data: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(data)
}

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

    #[test]
    fn fingerprint_matches_contract_shape() {
        let fingerprint = ProtocolIdentityBinding::compute_fingerprint(
            ProtocolSigningAlgorithm::Ed25519,
            &[7_u8; 32],
        );
        assert_eq!(fingerprint.len(), 64);
        assert!(fingerprint.chars().all(|ch| ch.is_ascii_hexdigit()));
    }

    #[test]
    fn canonical_origin_rejects_paths_and_keeps_non_default_port() {
        assert_eq!(
            CurrentPathOriginPolicy::canonical_origin("https://api.example.com:8443").unwrap(),
            "https://api.example.com:8443"
        );
        assert!(CurrentPathOriginPolicy::canonical_origin("https://api.example.com/ws").is_err());
    }

    #[test]
    fn crypto_suite_parses_known_names_and_flags_pqc() {
        let xwing = CryptoSuite::from_name("X-Wing").unwrap();
        let mlkem = CryptoSuite::from_name("ML-KEM-768+ML-DSA-65").unwrap();
        let classic = CryptoSuite::from_name("X25519").unwrap();

        assert_eq!(xwing, CryptoSuite::XWING_MLDSA);
        assert!(xwing.is_pqc());
        assert!(xwing.is_hybrid());

        assert_eq!(mlkem, CryptoSuite::MLKEM768_MLDSA65);
        assert!(mlkem.is_pqc());
        assert!(!mlkem.is_hybrid());

        assert_eq!(classic, CryptoSuite::X25519_ED25519);
        assert!(!classic.is_pqc());
    }

    #[test]
    fn qperiapt_abi1_remains_wire_parseable_but_not_operator_selectable() {
        let legacy = CryptoSuite::from_wire_id(0x0011);

        assert!(legacy.is_known());
        assert!(legacy.is_legacy_only());
        assert!(!legacy.is_negotiable());
        assert_eq!(legacy.as_known_name(), Some("Q-Periapt-ContextBound"));
        assert_eq!(CryptoSuite::from_name("q-periapt"), None);
        assert_eq!(CryptoSuite::from_name("q-periapt-contextbound"), None);
    }
}
