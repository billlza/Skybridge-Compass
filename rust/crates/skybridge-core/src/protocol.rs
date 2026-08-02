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
    #[serde(rename = "ML-DSA-87")]
    MlDsa87,
}

impl ProtocolSigningAlgorithm {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ed25519 => "Ed25519",
            Self::MlDsa65 => "ML-DSA-65",
            Self::MlDsa87 => "ML-DSA-87",
        }
    }

    /// Stable cross-platform signature-algorithm identifier.
    pub const fn wire_code(self) -> u16 {
        match self {
            Self::Ed25519 => 0x0001,
            Self::MlDsa65 => 0x0002,
            Self::MlDsa87 => 0x0004,
        }
    }

    pub fn from_wire_code(wire_code: u16) -> Result<Self, CurrentPathSecurityError> {
        match wire_code {
            0x0001 => Ok(Self::Ed25519),
            0x0002 => Ok(Self::MlDsa65),
            0x0004 => Ok(Self::MlDsa87),
            _ => Err(CurrentPathSecurityError::InvalidProtocolIdentity(
                "unknown signing algorithm wire code".to_owned(),
            )),
        }
    }

    pub const fn is_ml_dsa(self) -> bool {
        matches!(self, Self::MlDsa65 | Self::MlDsa87)
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
            "ML-DSA-87" | "mldsa87" | "MLDSA87" => Ok(Self::MlDsa87),
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
    /// EXPERIMENTAL, DEFAULT-OFF (built only with the `q-periapt` feature on
    /// skybridge-core): Q-Periapt ContextBound `ML-KEM-768 + X25519` hybrid KEM
    /// with ML-DSA-65 signatures. The constant itself is always defined (it is a
    /// plain wire id); only the KEM dispatch is feature-gated.
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
            "q-periapt"
            | "qperiapt"
            | "qperiapt-contextbound"
            | "q-periapt-contextbound"
            | "q-periapt+ml-dsa-65" => Some(Self::QPERIAPT_CONTEXTBOUND_MLDSA65),
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
    #[error("invalid insecure-loopback transport opt-in")]
    InvalidInsecureLoopbackOptIn,
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
            ProtocolSigningAlgorithm::MlDsa65
                if public_key_bytes.len() != crate::pqc::MLDSA65_PUBLIC_KEY_BYTES =>
            {
                Err(CurrentPathSecurityError::InvalidProtocolIdentity(format!(
                    "ML-DSA-65 public key must be {} bytes",
                    crate::pqc::MLDSA65_PUBLIC_KEY_BYTES
                )))
            }
            ProtocolSigningAlgorithm::MlDsa65 => Ok(()),
            ProtocolSigningAlgorithm::MlDsa87
                if public_key_bytes.len() != crate::pqc::MLDSA87_PUBLIC_KEY_BYTES =>
            {
                Err(CurrentPathSecurityError::InvalidProtocolIdentity(format!(
                    "ML-DSA-87 public key must be {} bytes",
                    crate::pqc::MLDSA87_PUBLIC_KEY_BYTES
                )))
            }
            ProtocolSigningAlgorithm::MlDsa87 => Ok(()),
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

/// Transport policy for externally supplied control-plane and signaling origins.
///
/// Production callers use [`SecureOnly`](OriginTransportPolicy::SecureOnly). Plaintext HTTP/WS
/// exists only for explicitly opted-in local development and is still restricted to loopback
/// hosts; it can never authorize plaintext traffic to a LAN or public address.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum OriginTransportPolicy {
    #[default]
    SecureOnly,
    AllowPlaintextLoopback,
}

impl OriginTransportPolicy {
    pub const INSECURE_LOOPBACK_ENV: &'static str = "SKYBRIDGE_ALLOW_INSECURE_LOOPBACK_TRANSPORT";

    pub fn from_environment() -> Result<Self, CurrentPathSecurityError> {
        match std::env::var(Self::INSECURE_LOOPBACK_ENV) {
            Ok(value) => Self::parse_explicit_opt_in(&value),
            Err(std::env::VarError::NotPresent) => Ok(Self::SecureOnly),
            Err(std::env::VarError::NotUnicode(_)) => {
                Err(CurrentPathSecurityError::InvalidInsecureLoopbackOptIn)
            }
        }
    }

    pub fn parse_explicit_opt_in(raw: &str) -> Result<Self, CurrentPathSecurityError> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "1" | "true" => Ok(Self::AllowPlaintextLoopback),
            "0" | "false" => Ok(Self::SecureOnly),
            _ => Err(CurrentPathSecurityError::InvalidInsecureLoopbackOptIn),
        }
    }
}

impl CurrentPathOriginPolicy {
    pub fn canonical_origin(raw: &str) -> Result<String, CurrentPathSecurityError> {
        Self::canonical_origin_with_policy(raw, OriginTransportPolicy::SecureOnly)
    }

    pub fn canonical_origin_with_policy(
        raw: &str,
        transport_policy: OriginTransportPolicy,
    ) -> Result<String, CurrentPathSecurityError> {
        canonical_transport_origin(raw, transport_policy, "https", "http")
    }

    pub fn canonical_websocket_origin(raw: &str) -> Result<String, CurrentPathSecurityError> {
        Self::canonical_websocket_origin_with_policy(raw, OriginTransportPolicy::SecureOnly)
    }

    pub fn canonical_websocket_origin_with_policy(
        raw: &str,
        transport_policy: OriginTransportPolicy,
    ) -> Result<String, CurrentPathSecurityError> {
        let parsed = url::Url::parse(raw).map_err(|_| CurrentPathSecurityError::InvalidOrigin)?;
        match parsed.scheme() {
            "https" | "http" => Self::canonical_origin_with_policy(raw, transport_policy),
            "wss" | "ws" => canonical_transport_origin(raw, transport_policy, "wss", "ws"),
            _ => Err(CurrentPathSecurityError::InvalidOrigin),
        }
    }
}

fn canonical_transport_origin(
    raw: &str,
    transport_policy: OriginTransportPolicy,
    secure_scheme: &str,
    plaintext_scheme: &str,
) -> Result<String, CurrentPathSecurityError> {
    let parsed = url::Url::parse(raw).map_err(|_| CurrentPathSecurityError::InvalidOrigin)?;
    let scheme = parsed.scheme().to_ascii_lowercase();
    if scheme != secure_scheme
        && !(scheme == plaintext_scheme
            && transport_policy == OriginTransportPolicy::AllowPlaintextLoopback
            && is_strict_loopback_host(&parsed))
    {
        return Err(CurrentPathSecurityError::InvalidOrigin);
    }
    if parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err(CurrentPathSecurityError::InvalidOrigin);
    }
    if parsed.path() != "/" && !parsed.path().is_empty() {
        return Err(CurrentPathSecurityError::InvalidOrigin);
    }
    Ok(parsed.origin().ascii_serialization())
}

fn is_strict_loopback_host(url: &url::Url) -> bool {
    match url.host() {
        Some(url::Host::Domain(host)) => host.eq_ignore_ascii_case("localhost"),
        Some(url::Host::Ipv4(address)) => address.is_loopback(),
        Some(url::Host::Ipv6(address)) => address.is_loopback(),
        None => false,
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
    fn fingerprint_matches_cross_platform_canonical_vectors() {
        let vectors = [
            (
                ProtocolSigningAlgorithm::Ed25519,
                (0_u8..32).collect::<Vec<_>>(),
                "09d14ebcd4f85644dbb1957e4b5bcf4501953e8ff2a96a6debcc1c9e5ef25de6",
            ),
            (
                ProtocolSigningAlgorithm::MlDsa65,
                vec![0x65; 1_952],
                "1fdfd364181724c0cc67300bef7bdf2b555614b550785781d9fb3ef6de0e26d4",
            ),
            (
                ProtocolSigningAlgorithm::MlDsa87,
                vec![0x87; crate::pqc::MLDSA87_PUBLIC_KEY_BYTES],
                "49fa4ab724c2d05fb329373c72d899767f4cdb95f18dd497a36714aea3ee32c4",
            ),
        ];

        for (algorithm, public_key, expected) in vectors {
            assert_eq!(
                ProtocolIdentityBinding::compute_fingerprint(algorithm, &public_key),
                expected
            );
        }
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
    fn production_origin_policy_rejects_all_plaintext_origins() {
        for origin in [
            "http://localhost:8080",
            "http://127.0.0.1:8080",
            "http://[::1]:8080",
            "http://192.168.1.20:8080",
            "http://api.example.com",
        ] {
            assert!(
                CurrentPathOriginPolicy::canonical_origin(origin).is_err(),
                "production policy accepted plaintext origin {origin}"
            );
        }
    }

    #[test]
    fn plaintext_opt_in_is_restricted_to_strict_loopback_hosts() {
        let policy = OriginTransportPolicy::AllowPlaintextLoopback;
        assert_eq!(
            CurrentPathOriginPolicy::canonical_origin_with_policy("http://localhost:8080", policy)
                .unwrap(),
            "http://localhost:8080"
        );
        assert_eq!(
            CurrentPathOriginPolicy::canonical_origin_with_policy("http://127.0.0.2:8080", policy)
                .unwrap(),
            "http://127.0.0.2:8080"
        );
        assert_eq!(
            CurrentPathOriginPolicy::canonical_origin_with_policy("http://[::1]:8080", policy)
                .unwrap(),
            "http://[::1]:8080"
        );

        for origin in [
            "http://localhost.example.com:8080",
            "http://127.0.0.1.example.com:8080",
            "http://192.168.1.20:8080",
            "http://user@localhost:8080",
            "http://localhost:8080/path",
            "http://localhost:8080?token=secret",
        ] {
            assert!(
                CurrentPathOriginPolicy::canonical_origin_with_policy(origin, policy).is_err(),
                "loopback policy accepted unsafe origin {origin}"
            );
        }
    }

    #[test]
    fn websocket_origin_policy_accepts_wss_and_restricts_ws_to_opted_in_loopback() {
        assert_eq!(
            CurrentPathOriginPolicy::canonical_websocket_origin("wss://signal.example:8443")
                .unwrap(),
            "wss://signal.example:8443"
        );
        assert!(
            CurrentPathOriginPolicy::canonical_websocket_origin("ws://127.0.0.1:8080").is_err()
        );
        assert_eq!(
            CurrentPathOriginPolicy::canonical_websocket_origin_with_policy(
                "ws://127.0.0.1:8080",
                OriginTransportPolicy::AllowPlaintextLoopback,
            )
            .unwrap(),
            "ws://127.0.0.1:8080"
        );
        assert!(
            CurrentPathOriginPolicy::canonical_websocket_origin_with_policy(
                "ws://192.168.1.20:8080",
                OriginTransportPolicy::AllowPlaintextLoopback,
            )
            .is_err()
        );
    }

    #[test]
    fn insecure_loopback_opt_in_parser_is_explicit() {
        assert_eq!(
            OriginTransportPolicy::parse_explicit_opt_in("true").unwrap(),
            OriginTransportPolicy::AllowPlaintextLoopback
        );
        assert_eq!(
            OriginTransportPolicy::parse_explicit_opt_in("0").unwrap(),
            OriginTransportPolicy::SecureOnly
        );
        assert!(OriginTransportPolicy::parse_explicit_opt_in("yes").is_err());
        assert!(OriginTransportPolicy::parse_explicit_opt_in("").is_err());
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
    fn mldsa87_has_exact_cross_platform_wire_and_key_contract() {
        assert_eq!(ProtocolSigningAlgorithm::MlDsa87.wire_code(), 0x0004);
        assert_eq!(
            ProtocolSigningAlgorithm::from_wire_code(0x0004).unwrap(),
            ProtocolSigningAlgorithm::MlDsa87
        );
        assert_eq!(
            "ML-DSA-87".parse::<ProtocolSigningAlgorithm>().unwrap(),
            ProtocolSigningAlgorithm::MlDsa87
        );
        assert!(
            ProtocolIdentityBinding::validate_key_encoding(
                &vec![0; crate::pqc::MLDSA87_PUBLIC_KEY_BYTES],
                ProtocolSigningAlgorithm::MlDsa87,
            )
            .is_ok()
        );
        assert!(
            ProtocolIdentityBinding::validate_key_encoding(
                &vec![0; crate::pqc::MLDSA87_PUBLIC_KEY_BYTES - 1],
                ProtocolSigningAlgorithm::MlDsa87,
            )
            .is_err()
        );
        assert!(ProtocolSigningAlgorithm::from_wire_code(0x0003).is_err());
    }
}
