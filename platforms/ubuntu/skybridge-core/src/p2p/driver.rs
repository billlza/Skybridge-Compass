//! Handshake Driver
//!
//! Implements the SkyBridge P2P handshake protocol.

use rand::RngExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use tracing::{debug, error, info, warn};

use super::TrustStore;
use super::messages::{
    CryptoCapabilities, FinishedDirection, FinishedMessage, HANDSHAKE_VERSION,
    HandshakeErrorMessage, HandshakeMessage, HandshakeSealedBox, IdentityPublicKeys, MessageA,
    MessageB,
};
use super::soa::{self, PeerSessionArbiter};
use super::types::{
    HandshakeAttemptStrategy, HandshakeFailureReason, HandshakePolicy, HandshakeRole,
    HandshakeState, KeyShare, P2PError, PeerIdentity, SessionKeys,
};
use crate::crypto::provider::CryptoProvider;
use crate::crypto::signature::{
    SignatureAlgorithm, compute_authoritative_public_key_fingerprint,
    compute_legacy_public_key_fingerprint, verify_with_algorithm,
};
use crate::crypto::suite::{CryptoSuite, CryptoSuiteId};

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SigningKeyPair {
    private_key: Vec<u8>,
    public_key: Vec<u8>,
}

/// Handshake timeout
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);
const CLASSIC_FALLBACK_COOLDOWN: Duration = Duration::from_secs(300);
const HANDSHAKE_PAYLOAD_INFO: &[u8] = b"handshake-payload";
const KEMDEM_EXPORTER_CONTEXT_PREFIX: &[u8] = b"SkyBridge-KEMDEM-SessionRoot-v1|";
type HpkeKeySchedule = (Vec<u8>, Vec<u8>, Vec<u8>);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ClassicHpkeInteropMode {
    Rfc9180,
    LegacySkyBridgeV1,
}

static CLASSIC_FALLBACK_COOLDOWN_BY_PEER: OnceLock<Mutex<HashMap<String, Instant>>> =
    OnceLock::new();
#[cfg(test)]
static CLASSIC_FALLBACK_TEST_MUTEX: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RuntimeCryptoProfile {
    /// Ubuntu 26+: prefer X-Wing, then ML-KEM, then classic.
    XWingPreferred,
    /// Ubuntu 23-25: prefer ML-KEM (liboqs-tier), then classic.
    LiboqsPqcPreferred,
    /// Ubuntu 20-22: classic only.
    ClassicOnly,
}

/// Local identity for handshake
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocalIdentity {
    /// Device ID
    pub device_id: String,
    /// Signing keys by algorithm
    signing_keys: HashMap<SignatureAlgorithm, SigningKeyPair>,
    /// KEM private keys (per suite)
    pub kem_private_keys: Vec<(CryptoSuiteId, Vec<u8>)>,
    /// KEM public keys (per suite)
    pub kem_public_keys: Vec<(CryptoSuiteId, Vec<u8>)>,
    /// Supported suites
    pub supported_suites: Vec<CryptoSuiteId>,
}

impl LocalIdentity {
    /// Create a new local identity
    pub fn generate(device_id: String, suites: &[CryptoSuiteId]) -> Result<Self, P2PError> {
        if suites.is_empty() {
            return Err(P2PError::Protocol("No crypto suites provided".to_string()));
        }

        let mut signing_keys = HashMap::new();
        // Always provision Ed25519 for classic compatibility
        let classic_crypto = CryptoProvider::new(CryptoSuiteId::X25519_AES256GCM_Ed25519);
        let (classic_priv, classic_pub) = classic_crypto.generate_signing_keypair()?;
        signing_keys.insert(
            SignatureAlgorithm::Ed25519,
            SigningKeyPair {
                private_key: classic_priv,
                public_key: classic_pub,
            },
        );

        // Provision ML-DSA if any PQC suites are supported
        if suites.iter().any(|suite| suite.is_pqc()) {
            let pqc_crypto = CryptoProvider::new(CryptoSuiteId::MlKem768_AES256GCM_MlDsa65);
            let (pqc_priv, pqc_pub) = pqc_crypto.generate_signing_keypair()?;
            signing_keys.insert(
                SignatureAlgorithm::MlDsa65,
                SigningKeyPair {
                    private_key: pqc_priv,
                    public_key: pqc_pub,
                },
            );
        }

        // Generate KEM keys for each suite
        let mut kem_private_keys = Vec::new();
        let mut kem_public_keys = Vec::new();
        let mut generated_by_canonical: HashMap<CryptoSuiteId, (Vec<u8>, Vec<u8>)> = HashMap::new();

        for &suite_id in suites {
            let canonical_suite = suite_id.canonical_kem_suite();
            let (priv_key, pub_key) =
                if let Some(existing) = generated_by_canonical.get(&canonical_suite) {
                    existing.clone()
                } else {
                    let crypto = CryptoProvider::new(canonical_suite);
                    let generated = crypto.generate_kem_keypair()?;
                    generated_by_canonical.insert(canonical_suite, generated.clone());
                    generated
                };

            if !kem_private_keys.iter().any(|(id, _)| *id == suite_id) {
                kem_private_keys.push((suite_id, priv_key.clone()));
            }
            if !kem_public_keys.iter().any(|(id, _)| *id == suite_id) {
                kem_public_keys.push((suite_id, pub_key.clone()));
            }
        }

        let mut identity = Self {
            device_id,
            signing_keys,
            kem_private_keys,
            kem_public_keys,
            supported_suites: suites.to_vec(),
        };
        identity.ensure_interop_suite_aliases();
        Ok(identity)
    }

    pub fn supports_suite(&self, suite_id: CryptoSuiteId) -> bool {
        self.supported_suites.contains(&suite_id)
            || self
                .supported_suites
                .iter()
                .any(|suite| suite.canonical_kem_suite() == suite_id.canonical_kem_suite())
    }

    /// Get signing public key for algorithm
    pub fn signing_public_key(&self, alg: SignatureAlgorithm) -> Option<&[u8]> {
        self.signing_keys
            .get(&alg)
            .map(|kp| kp.public_key.as_slice())
    }

    /// Preferred signing algorithm for discovery and handshake
    pub fn primary_signing_algorithm(&self) -> SignatureAlgorithm {
        if self.supported_suites.iter().any(|suite| suite.is_pqc()) {
            SignatureAlgorithm::MlDsa65
        } else {
            SignatureAlgorithm::Ed25519
        }
    }

    /// Primary signing public key (used for discovery fingerprinting)
    pub fn primary_signing_public_key(&self) -> Option<&[u8]> {
        self.signing_public_key(self.primary_signing_algorithm())
    }

    /// Primary signing public key fingerprint (SHA-256 hex)
    pub fn primary_signing_fingerprint(&self) -> Option<String> {
        self.primary_signing_public_key()
            .map(compute_legacy_public_key_fingerprint)
    }

    /// Get signing private key for algorithm
    pub fn signing_private_key(&self, alg: SignatureAlgorithm) -> Option<&[u8]> {
        self.signing_keys
            .get(&alg)
            .map(|kp| kp.private_key.as_slice())
    }

    /// Get key share for a specific suite
    pub fn key_share_for_suite(&self, suite_id: CryptoSuiteId) -> Option<KeyShare> {
        self.kem_public_keys
            .iter()
            .find(|(id, _)| *id == suite_id)
            .or_else(|| {
                self.kem_public_keys
                    .iter()
                    .find(|(id, _)| id.canonical_kem_suite() == suite_id.canonical_kem_suite())
            })
            .map(|(_id, key)| KeyShare {
                suite_id: suite_id.wire_id(),
                public_key: key.clone(),
            })
    }

    /// Get all key shares
    pub fn all_key_shares(&self) -> Vec<KeyShare> {
        self.kem_public_keys
            .iter()
            .map(|(id, key)| KeyShare {
                suite_id: id.wire_id(),
                public_key: key.clone(),
            })
            .collect()
    }

    /// Get KEM public keys as a map (suite -> public key)
    pub fn kem_public_key_map(&self) -> HashMap<CryptoSuiteId, Vec<u8>> {
        self.kem_public_keys
            .iter()
            .map(|(id, key)| (*id, key.clone()))
            .collect()
    }

    /// Get KEM private key for suite
    pub fn kem_private_key(&self, suite_id: CryptoSuiteId) -> Option<&[u8]> {
        self.kem_private_keys
            .iter()
            .find(|(id, _)| *id == suite_id)
            .or_else(|| {
                self.kem_private_keys
                    .iter()
                    .find(|(id, _)| id.canonical_kem_suite() == suite_id.canonical_kem_suite())
            })
            .map(|(_, key)| key.as_slice())
    }

    /// Normalize the X-Wing public key encoding to the draft-09 order:
    /// `pk = pk_M(1184) || pk_X(32)`.
    ///
    /// Earlier local builds encoded X-Wing keys as `pk_X || pk_M`. This helper
    /// is used on startup to transparently migrate persisted identities.
    pub fn normalize_xwing_public_key_order(&mut self) -> bool {
        use x25519_dalek::{PublicKey, StaticSecret};

        let suite_id = CryptoSuiteId::XWing_AES256GCM_MlDsa65;
        let Some(priv_key) = self.kem_private_key(suite_id) else {
            return false;
        };
        if priv_key.len() < 32 {
            return false;
        }

        let sk_bytes: [u8; 32] = match priv_key[..32].try_into() {
            Ok(v) => v,
            Err(_) => return false,
        };
        let pk_x = PublicKey::from(&StaticSecret::from(sk_bytes)).to_bytes();

        let mut changed = false;
        for (id, pub_key) in self.kem_public_keys.iter_mut() {
            if *id != suite_id {
                continue;
            }
            if pub_key.len() != 1216 {
                continue;
            }
            let first32 = &pub_key[..32];
            let last32 = &pub_key[pub_key.len() - 32..];

            if last32 == pk_x {
                // Already in spec order (pk_M || pk_X).
                continue;
            }
            if first32 == pk_x {
                // Legacy order (pk_X || pk_M) -> migrate.
                let mut migrated = Vec::with_capacity(pub_key.len());
                migrated.extend_from_slice(&pub_key[32..]);
                migrated.extend_from_slice(&pub_key[..32]);
                *pub_key = migrated;
                changed = true;
            }
        }
        changed
    }

    pub fn ensure_interop_suite_aliases(&mut self) -> bool {
        let mut changed = false;
        changed |= self.ensure_suite_alias(
            CryptoSuiteId::MlKem768_AES256GCM_MlDsa65,
            CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65,
        );
        changed
    }

    fn ensure_suite_alias(
        &mut self,
        canonical_suite: CryptoSuiteId,
        alias_suite: CryptoSuiteId,
    ) -> bool {
        let mut changed = false;
        if self.supported_suites.contains(&canonical_suite)
            && !self.supported_suites.contains(&alias_suite)
        {
            self.supported_suites.push(alias_suite);
            changed = true;
        }

        if !self
            .kem_private_keys
            .iter()
            .any(|(id, _)| *id == alias_suite)
            && let Some((_, key)) = self
                .kem_private_keys
                .iter()
                .find(|(id, _)| *id == canonical_suite)
                .cloned()
        {
            self.kem_private_keys.push((alias_suite, key));
            changed = true;
        }

        if !self
            .kem_public_keys
            .iter()
            .any(|(id, _)| *id == alias_suite)
            && let Some((_, key)) = self
                .kem_public_keys
                .iter()
                .find(|(id, _)| *id == canonical_suite)
                .cloned()
        {
            self.kem_public_keys.push((alias_suite, key));
            changed = true;
        }

        changed
    }
}

#[derive(Debug, Clone)]
struct ClassicEphemeralKeyPair {
    private_key: [u8; 32],
    public_key: [u8; 32],
}

/// Handshake driver
pub struct HandshakeDriver {
    /// Role in handshake
    role: HandshakeRole,
    /// Current state
    state: HandshakeState,
    /// Local identity
    local_identity: LocalIdentity,
    /// Peer identity (filled in during handshake)
    peer_identity: Option<PeerIdentity>,
    /// Peer device id hint (from discovery/pairing)
    peer_device_id: Option<String>,
    /// Expected peer signing fingerprint (trusted pin or discovery hint)
    expected_peer_fingerprint: Option<String>,
    /// Negotiated crypto provider
    crypto: Option<CryptoProvider>,
    /// Current epoch
    epoch: u64,
    /// MessageA transcript bytes (without signature)
    message_a_transcript: Option<Vec<u8>>,
    /// MessageB transcript bytes (without signature)
    message_b_transcript: Option<Vec<u8>>,
    /// MessageA transcript hash
    message_a_hash: Option<Vec<u8>>,
    /// Transcript hash (A || B)
    transcript_hash: Option<Vec<u8>>,
    /// Client nonce
    client_nonce: Option<[u8; 32]>,
    /// Server nonce
    server_nonce: Option<[u8; 32]>,
    /// Handshake policy
    policy: HandshakePolicy,
    /// Current attempt strategy
    attempt_strategy: HandshakeAttemptStrategy,
    /// Runtime profile-derived suite ordering and downgrade behavior.
    runtime_crypto_profile: RuntimeCryptoProfile,
    /// Suites offered in MessageA (initiator only)
    offered_suites: Vec<CryptoSuiteId>,
    /// Explicit suite selection for the next outbound MessageA, used when we need
    /// to mirror a peer's current-path suite exactly instead of advertising a
    /// broader local preference set.
    explicit_offered_suites: Option<Vec<CryptoSuiteId>>,
    /// Peer KEM public keys (for PQC encapsulation)
    peer_kem_public_keys: HashMap<CryptoSuiteId, Vec<u8>>,
    /// Stored PQC shared secrets from MessageA encapsulation
    pqc_shared_secrets: HashMap<CryptoSuiteId, Vec<u8>>,
    /// Ephemeral classic key pair generated for MessageA (initiator only).
    classic_ephemeral_keypair: Option<ClassicEphemeralKeyPair>,
    /// X25519 private key for the optional v2 forward-secure contribution.
    v2_initiator_contribution_private_key: Option<[u8; 32]>,
    /// Early Finished cached while initiator is still validating MessageB.
    pending_finished: Option<FinishedMessage>,

    soa_enabled: bool,
    outbound_extensions_raw: Vec<u8>,
    soa_pair_key: Option<[u8; 64]>,
}

impl HandshakeDriver {
    /// Create a new handshake driver as initiator
    pub fn new_initiator(identity: LocalIdentity) -> Self {
        Self::new_initiator_with_policy(identity, HandshakePolicy::default())
    }

    /// Create a new handshake driver as initiator with policy
    pub fn new_initiator_with_policy(identity: LocalIdentity, policy: HandshakePolicy) -> Self {
        let runtime_crypto_profile = Self::detect_runtime_crypto_profile();
        let attempt_strategy =
            Self::default_attempt_strategy(&identity, policy, runtime_crypto_profile);
        Self {
            role: HandshakeRole::Initiator,
            state: HandshakeState::Idle,
            local_identity: identity,
            peer_identity: None,
            peer_device_id: None,
            expected_peer_fingerprint: None,
            crypto: None,
            epoch: Self::current_epoch(),
            message_a_transcript: None,
            message_b_transcript: None,
            message_a_hash: None,
            transcript_hash: None,
            client_nonce: None,
            server_nonce: None,
            policy,
            attempt_strategy,
            runtime_crypto_profile,
            offered_suites: Vec::new(),
            explicit_offered_suites: None,
            peer_kem_public_keys: HashMap::new(),
            pqc_shared_secrets: HashMap::new(),
            classic_ephemeral_keypair: None,
            v2_initiator_contribution_private_key: None,
            pending_finished: None,
            soa_enabled: true,
            outbound_extensions_raw: Vec::new(),
            soa_pair_key: None,
        }
    }

    /// Create a new handshake driver as initiator with peer KEM public keys
    pub fn new_initiator_with_peer_keys(
        identity: LocalIdentity,
        policy: HandshakePolicy,
        peer_kem_public_keys: HashMap<CryptoSuiteId, Vec<u8>>,
    ) -> Self {
        let mut driver = Self::new_initiator_with_policy(identity, policy);
        driver.peer_kem_public_keys = peer_kem_public_keys;
        driver
    }

    /// Create a new handshake driver as responder
    pub fn new_responder(identity: LocalIdentity) -> Self {
        Self::new_responder_with_policy(identity, HandshakePolicy::default())
    }

    /// Create a new handshake driver as responder with policy
    pub fn new_responder_with_policy(identity: LocalIdentity, policy: HandshakePolicy) -> Self {
        let runtime_crypto_profile = Self::detect_runtime_crypto_profile();
        let attempt_strategy =
            Self::default_attempt_strategy(&identity, policy, runtime_crypto_profile);
        Self {
            role: HandshakeRole::Responder,
            state: HandshakeState::Idle,
            local_identity: identity,
            peer_identity: None,
            peer_device_id: None,
            expected_peer_fingerprint: None,
            crypto: None,
            epoch: Self::current_epoch(),
            message_a_transcript: None,
            message_b_transcript: None,
            message_a_hash: None,
            transcript_hash: None,
            client_nonce: None,
            server_nonce: None,
            policy,
            attempt_strategy,
            runtime_crypto_profile,
            offered_suites: Vec::new(),
            explicit_offered_suites: None,
            peer_kem_public_keys: HashMap::new(),
            pqc_shared_secrets: HashMap::new(),
            classic_ephemeral_keypair: None,
            v2_initiator_contribution_private_key: None,
            pending_finished: None,
            soa_enabled: true,
            outbound_extensions_raw: Vec::new(),
            soa_pair_key: None,
        }
    }

    /// Get current state
    pub fn state(&self) -> &HandshakeState {
        &self.state
    }

    /// Get peer identity if available
    pub fn peer_identity(&self) -> Option<&PeerIdentity> {
        self.peer_identity.as_ref()
    }

    /// Get session keys if established
    pub fn session_keys(&self) -> Option<&SessionKeys> {
        self.state.session_keys()
    }

    /// Override attempt strategy (useful for tests or explicit policy)
    pub fn set_attempt_strategy(&mut self, strategy: HandshakeAttemptStrategy) {
        self.attempt_strategy = strategy;
    }

    /// Override the next outbound MessageA suite list.
    ///
    /// This is primarily used for Apple interop-sensitive paths like strict-PQC
    /// rekey, where advertising extra suites can push MessageA beyond the
    /// parser's size limit or accidentally offer a suite the peer did not
    /// explicitly publish for the current path.
    pub fn set_explicit_offered_suites(&mut self, suites: Vec<CryptoSuiteId>) {
        self.explicit_offered_suites = if suites.is_empty() {
            None
        } else {
            Some(suites)
        };
    }

    /// Set peer KEM public keys (must be called before start for PQC attempt)
    pub fn set_peer_kem_public_keys(&mut self, keys: HashMap<CryptoSuiteId, Vec<u8>>) {
        self.peer_kem_public_keys = keys;
    }

    /// Update a single peer KEM public key
    pub fn update_peer_kem_public_key(&mut self, suite: CryptoSuiteId, key: Vec<u8>) {
        self.peer_kem_public_keys.insert(suite, key);
    }

    /// Set peer device ID hint (from discovery/pairing)
    pub fn set_peer_device_id(&mut self, device_id: Option<String>) {
        self.peer_device_id = device_id;
    }

    /// Set the expected peer signing fingerprint for local verification.
    pub fn set_expected_peer_fingerprint(&mut self, fingerprint: Option<String>) {
        self.expected_peer_fingerprint = fingerprint
            .map(|value| value.trim().to_ascii_lowercase())
            .filter(|value| !value.is_empty());
    }

    /// Provide outbound MessageA extensions TLV bytes (will be container-wrapped on the wire).
    ///
    /// IMPORTANT: This must be set before `start()` so the bytes are covered by sigA.
    pub fn set_outbound_extensions_raw(&mut self, extensions_raw: Vec<u8>) {
        self.outbound_extensions_raw = extensions_raw;
    }

    /// Disable SOA arbitration for this driver instance (e.g., in-band rekeys).
    pub fn disable_soa(&mut self) {
        self.soa_enabled = false;
    }

    pub fn soa_pair_key(&self) -> Option<[u8; 64]> {
        self.soa_pair_key
    }

    /// Current epoch based on time
    fn current_epoch() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
    }

    fn default_attempt_strategy(
        identity: &LocalIdentity,
        policy: HandshakePolicy,
        runtime_crypto_profile: RuntimeCryptoProfile,
    ) -> HandshakeAttemptStrategy {
        let supports_pqc = identity.supported_suites.iter().any(|suite| suite.is_pqc());
        if policy.require_pqc {
            HandshakeAttemptStrategy::PqcOnly
        } else if runtime_crypto_profile == RuntimeCryptoProfile::ClassicOnly {
            HandshakeAttemptStrategy::ClassicOnly
        } else if supports_pqc {
            HandshakeAttemptStrategy::PqcOnly
        } else {
            HandshakeAttemptStrategy::ClassicOnly
        }
    }

    fn detect_runtime_crypto_profile() -> RuntimeCryptoProfile {
        if let Ok(raw_major) = std::env::var("SKYBRIDGE_UBUNTU_VERSION_MAJOR")
            && let Ok(major) = raw_major.trim().parse::<u32>()
        {
            return Self::runtime_crypto_profile_for_ubuntu_major(major);
        }

        Self::read_ubuntu_major_version_from_os_release()
            .map(Self::runtime_crypto_profile_for_ubuntu_major)
            // Non-Ubuntu development hosts keep existing "prefer PQC/hybrid" behavior.
            .unwrap_or(RuntimeCryptoProfile::XWingPreferred)
    }

    fn runtime_crypto_profile_for_ubuntu_major(major: u32) -> RuntimeCryptoProfile {
        match major {
            0..=22 => RuntimeCryptoProfile::ClassicOnly,
            23..=25 => RuntimeCryptoProfile::LiboqsPqcPreferred,
            _ => RuntimeCryptoProfile::XWingPreferred,
        }
    }

    fn read_ubuntu_major_version_from_os_release() -> Option<u32> {
        let content = std::fs::read_to_string("/etc/os-release").ok()?;
        let mut distro_id: Option<String> = None;
        let mut version_id: Option<String> = None;

        for line in content.lines() {
            if let Some(value) = line.strip_prefix("ID=") {
                distro_id = Some(value.trim().trim_matches('"').to_string());
            } else if let Some(value) = line.strip_prefix("VERSION_ID=") {
                version_id = Some(value.trim().trim_matches('"').to_string());
            }
        }

        if distro_id.as_deref() != Some("ubuntu") {
            return None;
        }

        let version_id_value = version_id?;
        let major_raw = version_id_value.split('.').next()?.trim();
        major_raw.parse::<u32>().ok()
    }

    fn runtime_allows_suite(profile: RuntimeCryptoProfile, suite: CryptoSuiteId) -> bool {
        match profile {
            RuntimeCryptoProfile::XWingPreferred => true,
            RuntimeCryptoProfile::LiboqsPqcPreferred => {
                suite.canonical_kem_suite() == CryptoSuiteId::MlKem768_AES256GCM_MlDsa65
                    || !suite.is_pqc()
            }
            RuntimeCryptoProfile::ClassicOnly => !suite.is_pqc(),
        }
    }

    fn runtime_suite_order(profile: RuntimeCryptoProfile) -> &'static [CryptoSuiteId] {
        match profile {
            RuntimeCryptoProfile::XWingPreferred => &[
                CryptoSuiteId::XWing_AES256GCM_MlDsa65,
                CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65,
                CryptoSuiteId::MlKem768_AES256GCM_MlDsa65,
                CryptoSuiteId::X25519_AES256GCM_Ed25519,
            ],
            RuntimeCryptoProfile::LiboqsPqcPreferred => &[
                CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65,
                CryptoSuiteId::MlKem768_AES256GCM_MlDsa65,
                CryptoSuiteId::X25519_AES256GCM_Ed25519,
            ],
            RuntimeCryptoProfile::ClassicOnly => &[CryptoSuiteId::X25519_AES256GCM_Ed25519],
        }
    }

    /// Returns the crypto suites that should be advertised via discovery on this runtime.
    ///
    /// This mirrors the runtime handshake policy:
    /// - Ubuntu 20–22: classic-only
    /// - Ubuntu 23–25: liboqs-tier PQC (ML-KEM) + classic
    /// - Ubuntu 26+: X-Wing preferred + fallback suites
    pub fn runtime_advertised_crypto_suites() -> Vec<CryptoSuiteId> {
        Self::runtime_suite_order(Self::detect_runtime_crypto_profile()).to_vec()
    }

    fn runtime_ordered_local_suites(&self) -> Vec<CryptoSuiteId> {
        let mut suites = Vec::new();

        for preferred in Self::runtime_suite_order(self.runtime_crypto_profile) {
            if self.local_identity.supports_suite(*preferred)
                && Self::runtime_allows_suite(self.runtime_crypto_profile, *preferred)
                && !suites.contains(preferred)
            {
                suites.push(*preferred);
            }
        }

        for suite in self.local_identity.supported_suites.iter().copied() {
            if Self::runtime_allows_suite(self.runtime_crypto_profile, suite)
                && !suites.contains(&suite)
            {
                suites.push(suite);
            }
        }

        suites
    }

    fn has_peer_kem_public_key_for_suite(&self, suite: CryptoSuiteId) -> bool {
        self.peer_kem_public_keys.contains_key(&suite)
            || self
                .peer_kem_public_keys
                .contains_key(&suite.canonical_kem_suite())
    }

    fn peer_kem_public_key_for_suite(&self, suite: CryptoSuiteId) -> Option<Vec<u8>> {
        self.peer_kem_public_keys.get(&suite).cloned().or_else(|| {
            self.peer_kem_public_keys
                .get(&suite.canonical_kem_suite())
                .cloned()
        })
    }

    fn fallback_cooldown_store() -> &'static Mutex<HashMap<String, Instant>> {
        CLASSIC_FALLBACK_COOLDOWN_BY_PEER.get_or_init(|| Mutex::new(HashMap::new()))
    }

    fn fallback_cooldown_peer_key(&self) -> String {
        self.peer_device_id
            .clone()
            .unwrap_or_else(|| "__unknown_peer__".to_string())
    }

    fn classic_fallback_cooldown_remaining(&self) -> Option<Duration> {
        let peer_key = self.fallback_cooldown_peer_key();
        let now = Instant::now();
        let store = Self::fallback_cooldown_store();
        let guard = store
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let last_fallback = guard.get(&peer_key)?;
        let elapsed = now.saturating_duration_since(*last_fallback);
        if elapsed >= CLASSIC_FALLBACK_COOLDOWN {
            None
        } else {
            Some(CLASSIC_FALLBACK_COOLDOWN - elapsed)
        }
    }

    fn ensure_classic_fallback_cooldown_allows(&self) -> Result<(), Duration> {
        match self.classic_fallback_cooldown_remaining() {
            Some(remaining) => Err(remaining),
            None => Ok(()),
        }
    }

    fn record_classic_fallback_cooldown(&self) {
        let peer_key = self.fallback_cooldown_peer_key();
        let store = Self::fallback_cooldown_store();
        let mut guard = store
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.insert(peer_key, Instant::now());
    }

    #[cfg(test)]
    fn reset_classic_fallback_cooldown_for_tests() {
        let store = Self::fallback_cooldown_store();
        let mut guard = store
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.clear();
    }

    #[cfg(test)]
    fn fallback_test_mutex() -> &'static Mutex<()> {
        CLASSIC_FALLBACK_TEST_MUTEX.get_or_init(|| Mutex::new(()))
    }

    /// Generate random bytes
    fn random_bytes() -> [u8; 32] {
        let mut bytes = [0u8; 32];
        rand::rng().fill(&mut bytes);
        bytes
    }

    fn suite_for_signing_algorithm(alg: SignatureAlgorithm) -> CryptoSuiteId {
        match alg {
            SignatureAlgorithm::Ed25519 => CryptoSuiteId::X25519_AES256GCM_Ed25519,
            SignatureAlgorithm::MlDsa65 => CryptoSuiteId::MlKem768_AES256GCM_MlDsa65,
            SignatureAlgorithm::P256Ecdsa => CryptoSuiteId::X25519_AES256GCM_Ed25519,
        }
    }

    fn select_signing_algorithm(suites: &[CryptoSuiteId]) -> SignatureAlgorithm {
        let has_pqc = suites.iter().any(|suite| suite.is_pqc());
        if has_pqc {
            SignatureAlgorithm::MlDsa65
        } else {
            SignatureAlgorithm::Ed25519
        }
    }

    fn suites_are_homogeneous(suites: &[CryptoSuiteId]) -> bool {
        let has_pqc = suites.iter().any(|suite| suite.is_pqc());
        let has_classic = suites.iter().any(|suite| !suite.is_pqc());
        !(has_pqc && has_classic)
    }

    fn build_capabilities(suites: &[CryptoSuiteId]) -> CryptoCapabilities {
        let mut supported_kem = Vec::new();
        if suites.contains(&CryptoSuiteId::XWing_AES256GCM_MlDsa65) {
            supported_kem.push("X-Wing".to_string());
        }
        if suites.contains(&CryptoSuiteId::MlKem768_AES256GCM_MlDsa65) {
            supported_kem.push("ML-KEM-768".to_string());
        }
        if suites.contains(&CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65) {
            supported_kem.push("ML-KEM-768-FS".to_string());
        }
        if suites.contains(&CryptoSuiteId::X25519_AES256GCM_Ed25519) {
            supported_kem.push("X25519".to_string());
        }

        let pqc_available = suites.iter().any(|suite| suite.is_pqc());
        let supported_signature = if pqc_available {
            vec!["ML-DSA-65".to_string(), "P-256".to_string()]
        } else {
            vec!["P-256".to_string()]
        };
        let supported_auth_profiles = if pqc_available {
            vec![
                "Hybrid".to_string(),
                "PQC".to_string(),
                "Classic".to_string(),
            ]
        } else {
            vec!["Classic".to_string()]
        };
        let supported_aead = vec!["AES-256-GCM".to_string(), "ChaCha20-Poly1305".to_string()];

        CryptoCapabilities {
            supported_kem,
            supported_signature,
            supported_auth_profiles,
            supported_aead,
            pqc_available,
            platform_version: format!("{}-{}", std::env::consts::OS, crate::PROTOCOL_VERSION),
            provider_type: if pqc_available {
                "liboqs".to_string()
            } else {
                "CryptoKit-Classic".to_string()
            },
        }
    }

    fn generate_v2_initiator_contribution(&mut self) -> [u8; 32] {
        use x25519_dalek::{PublicKey, StaticSecret};

        let private_key = StaticSecret::random();
        let public_key = PublicKey::from(&private_key).to_bytes();
        self.v2_initiator_contribution_private_key = Some(private_key.to_bytes());
        public_key
    }

    fn derive_responder_v2_contribution(
        initiator_contribution: &[u8],
    ) -> Result<([u8; 32], [u8; 32]), P2PError> {
        use x25519_dalek::{PublicKey, StaticSecret};

        let initiator_public_bytes: [u8; 32] = initiator_contribution.try_into().map_err(|_| {
            P2PError::InvalidMessage("Invalid v2 initiator contribution length".to_string())
        })?;
        let initiator_public = PublicKey::from(initiator_public_bytes);
        let responder_private = StaticSecret::random();
        let responder_public = PublicKey::from(&responder_private).to_bytes();
        let shared_secret = responder_private
            .diffie_hellman(&initiator_public)
            .to_bytes();
        Ok((responder_public, shared_secret))
    }

    fn derive_initiator_v2_shared_secret(
        &mut self,
        responder_contribution: &[u8],
    ) -> Result<[u8; 32], P2PError> {
        use x25519_dalek::{PublicKey, StaticSecret};

        let responder_public_bytes: [u8; 32] = responder_contribution.try_into().map_err(|_| {
            P2PError::InvalidMessage("Invalid v2 responder contribution length".to_string())
        })?;
        let mut initiator_private = self
            .v2_initiator_contribution_private_key
            .take()
            .ok_or_else(|| {
                P2PError::Protocol("Missing initiator v2 contribution private key".to_string())
            })?;
        let responder_public = PublicKey::from(responder_public_bytes);
        let shared_secret = StaticSecret::from(initiator_private)
            .diffie_hellman(&responder_public)
            .to_bytes();
        initiator_private.fill(0);
        Ok(shared_secret)
    }

    fn compose_v2_shared_secret(
        static_secret: &[u8],
        ephemeral_secret: &[u8],
        transcript_hash_a: &[u8],
        suite: CryptoSuiteId,
    ) -> Vec<u8> {
        let mut ikm = b"SkyBridge-v2-compose|".to_vec();
        ikm.extend_from_slice(static_secret);
        ikm.extend_from_slice(ephemeral_secret);

        let mut info = b"SkyBridge-v2-static+ephemeral".to_vec();
        info.extend_from_slice(&suite.wire_id().to_le_bytes());

        crate::crypto::kdf::derive_key(&ikm, Some(transcript_hash_a), &info, 32)
    }

    fn hpke_seal_payload_classic(
        recipient_public_key_raw32: &[u8],
        plaintext: &[u8],
        suite_wire_id: u16,
        interop_mode: ClassicHpkeInteropMode,
    ) -> Result<(HandshakeSealedBox, Vec<u8>), P2PError> {
        Self::hpke_x25519_sha256_chachapoly_seal_and_export(
            recipient_public_key_raw32,
            HANDSHAKE_PAYLOAD_INFO,
            plaintext,
            suite_wire_id,
            interop_mode,
        )
    }

    fn hpke_open_payload_classic(
        sealed: &HandshakeSealedBox,
        receiver_keypair: &ClassicEphemeralKeyPair,
        suite_wire_id: u16,
    ) -> Result<(Vec<u8>, Vec<u8>), P2PError> {
        Self::hpke_x25519_sha256_chachapoly_open_and_export(
            sealed,
            &receiver_keypair.private_key,
            &receiver_keypair.public_key,
            HANDSHAKE_PAYLOAD_INFO,
            suite_wire_id,
        )
    }

    fn hpke_x25519_sha256_chachapoly_seal_and_export(
        recipient_public_key_raw32: &[u8],
        info: &[u8],
        plaintext: &[u8],
        suite_wire_id: u16,
        interop_mode: ClassicHpkeInteropMode,
    ) -> Result<(HandshakeSealedBox, Vec<u8>), P2PError> {
        use chacha20poly1305::aead::{Aead, KeyInit, Payload};
        use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
        use hkdf::Hkdf;
        use x25519_dalek::{PublicKey, StaticSecret};

        const KEM_ID: u16 = 0x0020;
        const KDF_ID: u16 = 0x0001;
        const AEAD_ID: u16 = 0x0003;

        if recipient_public_key_raw32.len() != 32 {
            return Err(P2PError::Protocol(
                "Invalid X25519 public key length".to_string(),
            ));
        }
        let pk_r_bytes: [u8; 32] = recipient_public_key_raw32
            .try_into()
            .map_err(|_| P2PError::Protocol("Invalid X25519 public key".to_string()))?;
        let pk_r = PublicKey::from(pk_r_bytes);

        // Build HPKE suite_id / kem_suite_id per RFC9180.
        let mut suite_id = [0u8; 10];
        suite_id[..4].copy_from_slice(b"HPKE");
        suite_id[4..6].copy_from_slice(&KEM_ID.to_be_bytes());
        suite_id[6..8].copy_from_slice(&KDF_ID.to_be_bytes());
        suite_id[8..10].copy_from_slice(&AEAD_ID.to_be_bytes());

        let mut kem_suite_id = [0u8; 5];
        kem_suite_id[..3].copy_from_slice(b"KEM");
        kem_suite_id[3..5].copy_from_slice(&KEM_ID.to_be_bytes());

        fn hkdf_extract_sha256(salt: &[u8], ikm: &[u8]) -> Vec<u8> {
            let (prk, _) =
                Hkdf::<Sha256>::extract(if salt.is_empty() { None } else { Some(salt) }, ikm);
            prk.as_slice().to_vec()
        }

        fn hkdf_expand_sha256(
            prk: &[u8],
            info: &[u8],
            out_len: usize,
        ) -> Result<Vec<u8>, P2PError> {
            let hk = Hkdf::<Sha256>::from_prk(prk)
                .map_err(|_| P2PError::Protocol("HPKE HKDF from_prk failed".to_string()))?;
            let mut okm = vec![0u8; out_len];
            hk.expand(info, &mut okm)
                .map_err(|_| P2PError::Protocol("HPKE HKDF expand failed".to_string()))?;
            Ok(okm)
        }

        fn labeled_extract(suite_id: &[u8], salt: &[u8], label: &str, ikm: &[u8]) -> Vec<u8> {
            let mut labeled_ikm = Vec::new();
            labeled_ikm.extend_from_slice(b"HPKE-v1");
            labeled_ikm.extend_from_slice(suite_id);
            labeled_ikm.extend_from_slice(label.as_bytes());
            labeled_ikm.extend_from_slice(ikm);
            hkdf_extract_sha256(salt, &labeled_ikm)
        }

        fn labeled_expand(
            suite_id: &[u8],
            prk: &[u8],
            label: &str,
            info: &[u8],
            out_len: usize,
        ) -> Result<Vec<u8>, P2PError> {
            let mut labeled_info = Vec::new();
            labeled_info.extend_from_slice(&(out_len as u16).to_be_bytes());
            labeled_info.extend_from_slice(b"HPKE-v1");
            labeled_info.extend_from_slice(suite_id);
            labeled_info.extend_from_slice(label.as_bytes());
            labeled_info.extend_from_slice(info);
            hkdf_expand_sha256(prk, &labeled_info, out_len)
        }

        fn dhkem_extract_and_expand(
            kem_suite_id: &[u8],
            dh: &[u8],
            kem_context: &[u8],
        ) -> Result<Vec<u8>, P2PError> {
            let eae_prk = labeled_extract(kem_suite_id, &[], "eae_prk", dh);
            labeled_expand(kem_suite_id, &eae_prk, "shared_secret", kem_context, 32)
        }

        fn key_schedule(
            suite_id: &[u8],
            shared_secret: &[u8],
            info: &[u8],
            interop_mode: ClassicHpkeInteropMode,
        ) -> Result<HpkeKeySchedule, P2PError> {
            let psk_id_hash = labeled_extract(suite_id, &[], "psk_id_hash", &[]);
            let info_hash = labeled_extract(suite_id, &[], "info_hash", info);
            let mut ks_context = Vec::new();
            if matches!(interop_mode, ClassicHpkeInteropMode::Rfc9180) {
                ks_context.push(0x00);
            }
            ks_context.extend_from_slice(&psk_id_hash);
            ks_context.extend_from_slice(&info_hash);

            let secret = match interop_mode {
                ClassicHpkeInteropMode::Rfc9180 => {
                    labeled_extract(suite_id, shared_secret, "secret", &[])
                }
                ClassicHpkeInteropMode::LegacySkyBridgeV1 => {
                    labeled_extract(suite_id, &[], "secret", shared_secret)
                }
            };
            let key = labeled_expand(suite_id, &secret, "key", &ks_context, 32)?;
            let base_nonce = labeled_expand(suite_id, &secret, "base_nonce", &ks_context, 12)?;
            let exporter_secret = labeled_expand(suite_id, &secret, "exp", &ks_context, 32)?;
            Ok((key, base_nonce, exporter_secret))
        }

        fn export_secret(
            suite_id: &[u8],
            exporter_secret: &[u8],
            exporter_context: &[u8],
        ) -> Result<Vec<u8>, P2PError> {
            labeled_expand(suite_id, exporter_secret, "sec", exporter_context, 32)
        }

        // Sender: generate ephemeral keypair and do DH.
        let sk_e = StaticSecret::random();
        let pk_e = PublicKey::from(&sk_e).to_bytes();
        let dh = sk_e.diffie_hellman(&pk_r).to_bytes();

        // DHKEM kem_context = enc || pkR.
        let mut kem_context = Vec::with_capacity(64);
        kem_context.extend_from_slice(&pk_e);
        kem_context.extend_from_slice(recipient_public_key_raw32);

        let shared_secret = dhkem_extract_and_expand(&kem_suite_id, &dh, &kem_context)?;
        let (key, base_nonce, exporter_secret) =
            key_schedule(&suite_id, &shared_secret, info, interop_mode)?;

        // Seal: ChaCha20-Poly1305 with aad=info; nonce=base_nonce (seq=0).
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(&base_nonce),
                Payload {
                    msg: plaintext,
                    aad: info,
                },
            )
            .map_err(|_| P2PError::Protocol("HPKE seal failed".to_string()))?;

        // Exporter context: "SkyBridge-KEMDEM-SessionRoot-v1|" || suiteWireIdLE || info.
        let mut exporter_context = Vec::new();
        exporter_context.extend_from_slice(KEMDEM_EXPORTER_CONTEXT_PREFIX);
        exporter_context.extend_from_slice(&suite_wire_id.to_le_bytes());
        exporter_context.extend_from_slice(info);
        let exported = export_secret(&suite_id, &exporter_secret, &exporter_context)?;

        Ok((
            HandshakeSealedBox {
                encapsulated_key: pk_e.to_vec(),
                nonce: Vec::new(),
                ciphertext,
                tag: Vec::new(),
            },
            exported,
        ))
    }

    fn hpke_x25519_sha256_chachapoly_open_and_export(
        sealed: &HandshakeSealedBox,
        receiver_private_key_raw32: &[u8; 32],
        receiver_public_key_raw32: &[u8; 32],
        info: &[u8],
        suite_wire_id: u16,
    ) -> Result<(Vec<u8>, Vec<u8>), P2PError> {
        use chacha20poly1305::aead::{Aead, KeyInit, Payload};
        use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
        use hkdf::Hkdf;
        use x25519_dalek::{PublicKey, StaticSecret};

        const KEM_ID: u16 = 0x0020;
        const KDF_ID: u16 = 0x0001;
        const AEAD_ID: u16 = 0x0003;

        if sealed.encapsulated_key.len() != 32 {
            return Err(P2PError::Protocol(
                "HPKE encapsulated key length mismatch".to_string(),
            ));
        }
        if !sealed.nonce.is_empty() || !sealed.tag.is_empty() {
            return Err(P2PError::Protocol(
                "HPKE v2 expects empty nonce/tag".to_string(),
            ));
        }

        let enc_bytes: [u8; 32] = sealed
            .encapsulated_key
            .as_slice()
            .try_into()
            .map_err(|_| P2PError::Protocol("HPKE invalid encapsulated key".to_string()))?;
        let enc_pub = PublicKey::from(enc_bytes);

        // Build suite IDs.
        let mut suite_id = [0u8; 10];
        suite_id[..4].copy_from_slice(b"HPKE");
        suite_id[4..6].copy_from_slice(&KEM_ID.to_be_bytes());
        suite_id[6..8].copy_from_slice(&KDF_ID.to_be_bytes());
        suite_id[8..10].copy_from_slice(&AEAD_ID.to_be_bytes());

        let mut kem_suite_id = [0u8; 5];
        kem_suite_id[..3].copy_from_slice(b"KEM");
        kem_suite_id[3..5].copy_from_slice(&KEM_ID.to_be_bytes());

        fn hkdf_extract_sha256(salt: &[u8], ikm: &[u8]) -> Vec<u8> {
            let (prk, _) =
                Hkdf::<Sha256>::extract(if salt.is_empty() { None } else { Some(salt) }, ikm);
            prk.as_slice().to_vec()
        }

        fn hkdf_expand_sha256(
            prk: &[u8],
            info: &[u8],
            out_len: usize,
        ) -> Result<Vec<u8>, P2PError> {
            let hk = Hkdf::<Sha256>::from_prk(prk)
                .map_err(|_| P2PError::Protocol("HPKE HKDF from_prk failed".to_string()))?;
            let mut okm = vec![0u8; out_len];
            hk.expand(info, &mut okm)
                .map_err(|_| P2PError::Protocol("HPKE HKDF expand failed".to_string()))?;
            Ok(okm)
        }

        fn labeled_extract(suite_id: &[u8], salt: &[u8], label: &str, ikm: &[u8]) -> Vec<u8> {
            let mut labeled_ikm = Vec::new();
            labeled_ikm.extend_from_slice(b"HPKE-v1");
            labeled_ikm.extend_from_slice(suite_id);
            labeled_ikm.extend_from_slice(label.as_bytes());
            labeled_ikm.extend_from_slice(ikm);
            hkdf_extract_sha256(salt, &labeled_ikm)
        }

        fn labeled_expand(
            suite_id: &[u8],
            prk: &[u8],
            label: &str,
            info: &[u8],
            out_len: usize,
        ) -> Result<Vec<u8>, P2PError> {
            let mut labeled_info = Vec::new();
            labeled_info.extend_from_slice(&(out_len as u16).to_be_bytes());
            labeled_info.extend_from_slice(b"HPKE-v1");
            labeled_info.extend_from_slice(suite_id);
            labeled_info.extend_from_slice(label.as_bytes());
            labeled_info.extend_from_slice(info);
            hkdf_expand_sha256(prk, &labeled_info, out_len)
        }

        fn dhkem_extract_and_expand(
            kem_suite_id: &[u8],
            dh: &[u8],
            kem_context: &[u8],
        ) -> Result<Vec<u8>, P2PError> {
            let eae_prk = labeled_extract(kem_suite_id, &[], "eae_prk", dh);
            labeled_expand(kem_suite_id, &eae_prk, "shared_secret", kem_context, 32)
        }

        fn key_schedule(
            suite_id: &[u8],
            shared_secret: &[u8],
            info: &[u8],
            interop_mode: ClassicHpkeInteropMode,
        ) -> Result<HpkeKeySchedule, P2PError> {
            let psk_id_hash = labeled_extract(suite_id, &[], "psk_id_hash", &[]);
            let info_hash = labeled_extract(suite_id, &[], "info_hash", info);
            let mut ks_context = Vec::new();
            if matches!(interop_mode, ClassicHpkeInteropMode::Rfc9180) {
                ks_context.push(0x00);
            }
            ks_context.extend_from_slice(&psk_id_hash);
            ks_context.extend_from_slice(&info_hash);

            let secret = match interop_mode {
                ClassicHpkeInteropMode::Rfc9180 => {
                    labeled_extract(suite_id, shared_secret, "secret", &[])
                }
                ClassicHpkeInteropMode::LegacySkyBridgeV1 => {
                    labeled_extract(suite_id, &[], "secret", shared_secret)
                }
            };
            let key = labeled_expand(suite_id, &secret, "key", &ks_context, 32)?;
            let base_nonce = labeled_expand(suite_id, &secret, "base_nonce", &ks_context, 12)?;
            let exporter_secret = labeled_expand(suite_id, &secret, "exp", &ks_context, 32)?;
            Ok((key, base_nonce, exporter_secret))
        }

        fn export_secret(
            suite_id: &[u8],
            exporter_secret: &[u8],
            exporter_context: &[u8],
        ) -> Result<Vec<u8>, P2PError> {
            labeled_expand(suite_id, exporter_secret, "sec", exporter_context, 32)
        }

        let sk_r = StaticSecret::from(*receiver_private_key_raw32);
        let dh = sk_r.diffie_hellman(&enc_pub).to_bytes();

        let mut kem_context = Vec::with_capacity(64);
        kem_context.extend_from_slice(&enc_bytes);
        kem_context.extend_from_slice(receiver_public_key_raw32);

        let shared_secret = dhkem_extract_and_expand(&kem_suite_id, &dh, &kem_context)?;
        let try_open =
            |interop_mode: ClassicHpkeInteropMode| -> Result<(Vec<u8>, Vec<u8>), P2PError> {
                let (key, base_nonce, exporter_secret) =
                    key_schedule(&suite_id, &shared_secret, info, interop_mode)?;

                let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
                let plaintext = cipher
                    .decrypt(
                        Nonce::from_slice(&base_nonce),
                        Payload {
                            msg: sealed.ciphertext.as_ref(),
                            aad: info,
                        },
                    )
                    .map_err(|_| P2PError::Protocol("HPKE open failed".to_string()))?;

                let mut exporter_context = Vec::new();
                exporter_context.extend_from_slice(KEMDEM_EXPORTER_CONTEXT_PREFIX);
                exporter_context.extend_from_slice(&suite_wire_id.to_le_bytes());
                exporter_context.extend_from_slice(info);
                let exported = export_secret(&suite_id, &exporter_secret, &exporter_context)?;

                Ok((plaintext, exported))
            };

        match try_open(ClassicHpkeInteropMode::Rfc9180) {
            Ok(result) => Ok(result),
            Err(rfc9180_err) => {
                debug!(
                    "Classic HPKE RFC9180 open failed; retrying legacy interop: enc={} ciphertext={} err={:?}",
                    sealed.encapsulated_key.len(),
                    sealed.ciphertext.len(),
                    rfc9180_err
                );
                try_open(ClassicHpkeInteropMode::LegacySkyBridgeV1)
            }
        }
    }

    fn classic_hpke_interop_mode_for_provider(provider_type: &str) -> ClassicHpkeInteropMode {
        if provider_type.eq_ignore_ascii_case("classic") {
            ClassicHpkeInteropMode::LegacySkyBridgeV1
        } else {
            ClassicHpkeInteropMode::Rfc9180
        }
    }

    fn seal_handshake_payload(
        shared_secret: &[u8],
        transcript_hash_a: &[u8],
        plaintext: &[u8],
        encapsulated_key: Vec<u8>,
    ) -> Result<HandshakeSealedBox, P2PError> {
        use aes_gcm::{Aes256Gcm, KeyInit, Nonce, aead::Aead};

        let key = crate::crypto::kdf::derive_key(
            shared_secret,
            Some(transcript_hash_a),
            b"handshake-payload",
            32,
        );
        let cipher = Aes256Gcm::new_from_slice(&key)
            .map_err(|_| P2PError::Protocol("Invalid AES key".to_string()))?;
        let mut nonce_bytes = [0u8; 12];
        rand::rng().fill(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);
        let mut ciphertext = cipher
            .encrypt(nonce, plaintext)
            .map_err(|_| P2PError::Protocol("Payload encryption failed".to_string()))?;
        if ciphertext.len() < 16 {
            return Err(P2PError::Protocol(
                "Encrypted payload too short".to_string(),
            ));
        }
        let tag = ciphertext.split_off(ciphertext.len() - 16);
        Ok(HandshakeSealedBox {
            encapsulated_key,
            nonce: nonce_bytes.to_vec(),
            ciphertext,
            tag,
        })
    }

    fn open_handshake_payload(
        shared_secret: &[u8],
        transcript_hash_a: &[u8],
        sealed: &HandshakeSealedBox,
    ) -> Result<Vec<u8>, P2PError> {
        use aes_gcm::{Aes256Gcm, KeyInit, Nonce, aead::Aead};

        let key = crate::crypto::kdf::derive_key(
            shared_secret,
            Some(transcript_hash_a),
            b"handshake-payload",
            32,
        );
        let cipher = Aes256Gcm::new_from_slice(&key)
            .map_err(|_| P2PError::Protocol("Invalid AES key".to_string()))?;
        let nonce = Nonce::from_slice(&sealed.nonce);
        let mut combined = sealed.ciphertext.clone();
        combined.extend_from_slice(&sealed.tag);
        let plaintext = cipher
            .decrypt(nonce, combined.as_ref())
            .map_err(|_| P2PError::Protocol("Payload decryption failed".to_string()))?;
        Ok(plaintext)
    }

    fn smoke_digest_label(bytes: &[u8]) -> String {
        let digest = hex::encode(Sha256::digest(bytes));
        digest[..16].to_string()
    }

    fn persist_peer_identity(&self) {
        let Some(peer) = &self.peer_identity else {
            return;
        };
        if peer.device_id.is_empty() {
            return;
        }
        if let Ok(mut store) = TrustStore::load() {
            let _ = store.upsert_peer_identity(peer);
        }
    }

    fn verify_peer_fingerprint(
        &mut self,
        public_key: &[u8],
        algorithm: SignatureAlgorithm,
    ) -> Result<(), P2PError> {
        let actual_legacy_fp = compute_legacy_public_key_fingerprint(public_key);
        let actual_authoritative_fp =
            compute_authoritative_public_key_fingerprint(algorithm, public_key);
        if let Some(expected_fp) = self.expected_peer_fingerprint.as_ref()
            && expected_fp != &actual_legacy_fp
            && expected_fp != &actual_authoritative_fp
        {
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::IdentityMismatch {
                    expected: expected_fp.clone(),
                    actual: actual_authoritative_fp.clone(),
                },
            };
            return Err(P2PError::TrustPolicyViolation(
                "Peer fingerprint did not match expected identity".to_string(),
            ));
        }

        let Some(device_id) = self.peer_device_id.as_deref() else {
            return Ok(());
        };
        let Ok(store) = TrustStore::load() else {
            return Ok(());
        };
        let Some(expected_fp) = store.peer_pinned_fingerprint_for_algorithm(device_id, algorithm)
        else {
            return Ok(());
        };
        if expected_fp != actual_legacy_fp && expected_fp != actual_authoritative_fp {
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::IdentityMismatch {
                    expected: expected_fp,
                    actual: actual_authoritative_fp,
                },
            };
            return Err(P2PError::HandshakeFailed {
                reason: "Identity mismatch".to_string(),
            });
        }
        Ok(())
    }

    fn prepare_offered_suites(&mut self) -> Result<Vec<CryptoSuiteId>, P2PError> {
        let mut suites: Vec<CryptoSuiteId> = if let Some(explicit) = &self.explicit_offered_suites {
            explicit
                .iter()
                .copied()
                .filter(|suite| self.local_identity.supports_suite(*suite))
                .filter(|suite| Self::runtime_allows_suite(self.runtime_crypto_profile, *suite))
                .filter(|suite| self.policy.allows_suite(*suite))
                .filter(|suite| suite.is_negotiable())
                .collect()
        } else {
            self.runtime_ordered_local_suites()
                .into_iter()
                .filter(|suite| self.policy.allows_suite(*suite))
                .filter(|suite| suite.is_negotiable())
                .collect()
        };

        match self.attempt_strategy {
            HandshakeAttemptStrategy::PqcOnly => suites.retain(|suite| suite.is_pqc()),
            HandshakeAttemptStrategy::ClassicOnly => suites.retain(|suite| !suite.is_pqc()),
        }

        if self.role == HandshakeRole::Initiator
            && self.attempt_strategy == HandshakeAttemptStrategy::PqcOnly
        {
            suites
                .retain(|suite| !suite.is_pqc() || self.has_peer_kem_public_key_for_suite(*suite));
        }

        if suites.is_empty() {
            let reason = match self.attempt_strategy {
                HandshakeAttemptStrategy::PqcOnly => HandshakeFailureReason::PqcUnavailable,
                HandshakeAttemptStrategy::ClassicOnly => {
                    HandshakeFailureReason::SuiteNegotiationFailed
                }
            };
            let reason_string = reason.to_string();
            self.state = HandshakeState::Failed { reason };
            return Err(P2PError::HandshakeFailed {
                reason: reason_string,
            });
        }

        if !Self::suites_are_homogeneous(&suites) {
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::SignatureAlgorithmMismatch,
            };
            return Err(P2PError::Protocol(
                "Mixed PQC and classic suites in one attempt".to_string(),
            ));
        }

        Ok(suites)
    }

    fn build_key_shares(&mut self, suites: &[CryptoSuiteId]) -> Result<Vec<KeyShare>, P2PError> {
        self.pqc_shared_secrets.clear();
        self.classic_ephemeral_keypair = None;
        self.v2_initiator_contribution_private_key = None;
        let mut shares = Vec::new();

        for suite in suites {
            if suite.is_pqc() {
                if let Some(peer_pub) = self.peer_kem_public_key_for_suite(*suite) {
                    let crypto = CryptoProvider::new(*suite);
                    let (encapsulated, shared_secret) = crypto.kem_encapsulate(&peer_pub)?;
                    self.pqc_shared_secrets.insert(*suite, shared_secret);
                    shares.push(KeyShare {
                        suite_id: suite.wire_id(),
                        public_key: encapsulated,
                    });
                }
            } else if *suite == CryptoSuiteId::X25519_AES256GCM_Ed25519 {
                use x25519_dalek::{PublicKey, StaticSecret};

                let secret = StaticSecret::random();
                let public = PublicKey::from(&secret);
                let priv_bytes = secret.to_bytes();
                let pub_bytes = public.to_bytes();

                self.classic_ephemeral_keypair = Some(ClassicEphemeralKeyPair {
                    private_key: priv_bytes,
                    public_key: pub_bytes,
                });
                shares.push(KeyShare {
                    suite_id: suite.wire_id(),
                    public_key: pub_bytes.to_vec(),
                });
            } else if let Some(share) = self.local_identity.key_share_for_suite(*suite) {
                // Fallback for parse-only classic marker suites.
                shares.push(share);
            }
        }

        if shares.is_empty() {
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::SuiteNegotiationFailed,
            };
            return Err(P2PError::HandshakeFailed {
                reason: "No key shares could be built".to_string(),
            });
        }

        Ok(shares)
    }

    /// Start the handshake (initiator only)
    pub async fn start(&mut self) -> Result<HandshakeMessage, P2PError> {
        if self.role != HandshakeRole::Initiator {
            return Err(P2PError::Protocol(
                "Only initiator can start handshake".to_string(),
            ));
        }

        if !matches!(self.state, HandshakeState::Idle) {
            return Err(P2PError::Protocol("Handshake already started".to_string()));
        }

        info!("Starting handshake as initiator");
        self.state = HandshakeState::SendingMessageA;

        // Build MessageA (with optional PQC->classic fallback)
        let message_a = match self.build_message_a().await {
            Ok(msg) => msg,
            Err(err) => {
                let fallback_allowed = self.policy.allow_classic_fallback
                    && self.attempt_strategy == HandshakeAttemptStrategy::PqcOnly;
                let should_fallback = matches!(
                    self.state,
                    HandshakeState::Failed {
                        reason: HandshakeFailureReason::PqcUnavailable
                            | HandshakeFailureReason::SuiteNegotiationFailed
                    }
                );
                if fallback_allowed && should_fallback {
                    if let Err(remaining) = self.ensure_classic_fallback_cooldown_allows() {
                        self.state = HandshakeState::Failed {
                            reason: HandshakeFailureReason::ClassicFallbackNotAllowed,
                        };
                        return Err(P2PError::HandshakeFailed {
                            reason: format!(
                                "Classic fallback cooldown active for peer {}; retry in {}s",
                                self.fallback_cooldown_peer_key(),
                                remaining.as_secs()
                            ),
                        });
                    }
                    self.record_classic_fallback_cooldown();
                    self.attempt_strategy = HandshakeAttemptStrategy::ClassicOnly;
                    self.state = HandshakeState::SendingMessageA;
                    self.build_message_a().await?
                } else {
                    return Err(err);
                }
            }
        };

        // Update state
        self.pending_finished = None;
        self.state = HandshakeState::WaitingMessageB {
            deadline: Instant::now() + HANDSHAKE_TIMEOUT,
        };

        Ok(HandshakeMessage::MessageA(message_a))
    }

    /// Process received message
    pub async fn process_message(
        &mut self,
        message: HandshakeMessage,
    ) -> Result<Option<HandshakeMessage>, P2PError> {
        match message {
            HandshakeMessage::MessageA(msg) => self.process_message_a(msg).await,
            HandshakeMessage::MessageB(msg) => self.process_message_b(msg).await,
            HandshakeMessage::Finished(msg) => self.process_finished(msg).await,
            HandshakeMessage::Error(err) => {
                error!("Received handshake error: {}", err.message);
                self.state = HandshakeState::Failed {
                    reason: HandshakeFailureReason::RejectedByPeer,
                };
                Err(P2PError::HandshakeFailed {
                    reason: err.message,
                })
            }
        }
    }

    /// Build MessageA
    async fn build_message_a(&mut self) -> Result<MessageA, P2PError> {
        self.soa_pair_key = None;

        let client_nonce = Self::random_bytes();
        let offered_suites = self.prepare_offered_suites()?;
        self.offered_suites = offered_suites.clone();

        let signing_algorithm = Self::select_signing_algorithm(&offered_suites);
        let signing_public_key = self
            .local_identity
            .signing_public_key(signing_algorithm)
            .ok_or_else(|| P2PError::Protocol("Missing signing public key".to_string()))?
            .to_vec();

        let signing_private_key = self
            .local_identity
            .signing_private_key(signing_algorithm)
            .ok_or_else(|| P2PError::Protocol("Missing signing private key".to_string()))?
            .to_vec();

        let key_shares = self.build_key_shares(&offered_suites)?;
        let capabilities = Self::build_capabilities(&offered_suites);
        let identity_public_key = IdentityPublicKeys {
            protocol_public_key: signing_public_key.clone(),
            protocol_algorithm: signing_algorithm,
            secure_enclave_public_key: None,
        }
        .encode();

        let mut message_a = MessageA {
            version: HANDSHAKE_VERSION,
            supported_suites: offered_suites.iter().map(|s| s.wire_id()).collect(),
            key_shares,
            client_nonce,
            capabilities,
            policy: self.policy,
            identity_public_key,
            initiator_contribution: offered_suites
                .iter()
                .any(|suite| suite.is_forward_secure_v2())
                .then(|| self.generate_v2_initiator_contribution().to_vec()),
            extensions_raw: self.outbound_extensions_raw.clone(),
            signature: Vec::new(), // Will be filled in
            secure_enclave_signature: None,
        };

        if let Some(ext) = soa::SoaExtension::decode_from_extensions(&message_a.extensions_raw) {
            self.soa_pair_key = Some(soa::pair_key(ext.initiator_peer_id, ext.target_peer_id));
        }

        // Sign the message
        let signing_data = message_a.signature_preimage();
        let crypto = CryptoProvider::new(Self::suite_for_signing_algorithm(signing_algorithm));
        message_a.signature = crypto.sign(&signing_data, &signing_private_key).await?;
        if std::env::var("SKYBRIDGE_SMOKE_ROLE").is_ok() {
            let suite_summary = offered_suites
                .iter()
                .map(|suite| format!("{:?}", suite))
                .collect::<Vec<_>>()
                .join(",");
            let preimage_digest = hex::encode(Sha256::digest(&signing_data));
            println!(
                "🧪 linux tx MessageA suites={} sigAlg={} pubBytes={} sigBytes={} preimageSha256={}",
                suite_summary,
                signing_algorithm.protocol_name(),
                signing_public_key.len(),
                message_a.signature.len(),
                &preimage_digest[..16]
            );
        }

        // Store transcript/hash/nonce
        let transcript_bytes = message_a.transcript_bytes();
        let transcript_hash = Sha256::digest(&transcript_bytes).to_vec();
        self.message_a_transcript = Some(transcript_bytes);
        self.message_a_hash = Some(transcript_hash);
        self.client_nonce = Some(message_a.client_nonce);

        Ok(message_a)
    }

    /// Process received MessageA (responder)
    async fn process_message_a(
        &mut self,
        message_a: MessageA,
    ) -> Result<Option<HandshakeMessage>, P2PError> {
        if self.role != HandshakeRole::Responder {
            return Err(P2PError::Protocol(
                "Initiator should not receive MessageA".to_string(),
            ));
        }

        debug!("Processing MessageA");
        self.state = HandshakeState::ProcessingMessageA;

        let identity_keys =
            IdentityPublicKeys::decode_with_legacy_fallback(&message_a.identity_public_key)?;

        // Verify signature
        let signing_data = message_a.signature_preimage();
        let valid = verify_with_algorithm(
            identity_keys.protocol_algorithm,
            &signing_data,
            &message_a.signature,
            &identity_keys.protocol_public_key,
        )
        .await
        .map_err(|err| P2PError::Crypto(crate::crypto::provider::CryptoError::Signature(err)))?;

        if !valid {
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::SignatureVerificationFailed,
            };
            return Ok(Some(HandshakeMessage::Error(
                HandshakeErrorMessage::signature_failed(),
            )));
        }

        if let Some(unknown) = message_a
            .supported_suites
            .iter()
            .copied()
            .find(|&id| CryptoSuiteId::from_wire_id(id).is_none())
        {
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::UnknownSuite { wire_id: unknown },
            };
            return Ok(Some(HandshakeMessage::Error(
                HandshakeErrorMessage::unsupported_suite(&format!(
                    "Unknown crypto suite 0x{unknown:04x}"
                )),
            )));
        }

        let their_suites: Vec<CryptoSuiteId> = message_a
            .supported_suites
            .iter()
            .filter_map(|&id| CryptoSuiteId::from_wire_id(id))
            .collect();

        if their_suites.is_empty() {
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::SuiteNegotiationFailed,
            };
            return Ok(Some(HandshakeMessage::Error(
                HandshakeErrorMessage::no_common_suite(),
            )));
        }

        let has_pqc = their_suites.iter().any(|suite| suite.is_pqc());
        let has_classic = their_suites.iter().any(|suite| !suite.is_pqc());
        if has_pqc && has_classic {
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::SignatureAlgorithmMismatch,
            };
            return Ok(Some(HandshakeMessage::Error(
                HandshakeErrorMessage::invalid_message("Mixed PQC and classic suites"),
            )));
        }

        let expected_sign_alg = if has_pqc {
            SignatureAlgorithm::MlDsa65
        } else {
            SignatureAlgorithm::Ed25519
        };
        if identity_keys.protocol_algorithm != expected_sign_alg {
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::SignatureAlgorithmMismatch,
            };
            return Ok(Some(HandshakeMessage::Error(
                HandshakeErrorMessage::signature_failed(),
            )));
        }

        self.verify_peer_fingerprint(
            &identity_keys.protocol_public_key,
            identity_keys.protocol_algorithm,
        )?;

        if self.soa_enabled
            && let Some(ext) = soa::SoaExtension::decode_from_extensions(&message_a.extensions_raw)
        {
            let local_peer_id = soa::canonical_peer_id_bytes(&self.local_identity.device_id);
            let pair_key = soa::pair_key(local_peer_id, ext.initiator_peer_id);
            self.soa_pair_key = Some(pair_key);

            let decision = PeerSessionArbiter::shared().evaluate_incoming(
                pair_key,
                ext.initiator_peer_id,
                ext.attempt_id,
                ext.target_peer_id,
                ext.initiator_peer_id,
                local_peer_id,
            );

            match decision {
                soa::IncomingDecision::Accept
                | soa::IncomingDecision::AcceptAndSupersedeLocal { .. } => {}
                soa::IncomingDecision::RejectAlreadyConnected => {
                    self.state = HandshakeState::Failed {
                        reason: HandshakeFailureReason::InvalidMessage(
                            "SOA: already connected".to_string(),
                        ),
                    };
                    return Ok(Some(HandshakeMessage::Error(
                        HandshakeErrorMessage::invalid_message("SOA: already connected"),
                    )));
                }
                soa::IncomingDecision::RejectBinding => {
                    self.state = HandshakeState::Failed {
                        reason: HandshakeFailureReason::InvalidMessage(
                            "SOA binding rejected".to_string(),
                        ),
                    };
                    return Ok(Some(HandshakeMessage::Error(
                        HandshakeErrorMessage::invalid_message("SOA binding rejected"),
                    )));
                }
                soa::IncomingDecision::RejectRateLimited => {
                    self.state = HandshakeState::Failed {
                        reason: HandshakeFailureReason::InvalidMessage(
                            "SOA rate limited".to_string(),
                        ),
                    };
                    return Ok(Some(HandshakeMessage::Error(
                        HandshakeErrorMessage::invalid_message("SOA rate limited"),
                    )));
                }
                soa::IncomingDecision::RejectLocalWinner { .. } => {
                    self.state = HandshakeState::Failed {
                        reason: HandshakeFailureReason::InvalidMessage(
                            "SOA superseded by local attempt".to_string(),
                        ),
                    };
                    return Ok(Some(HandshakeMessage::Error(
                        HandshakeErrorMessage::invalid_message("SOA superseded by local attempt"),
                    )));
                }
            }
        }

        // Find common suite
        let our_suites: Vec<CryptoSuiteId> = self
            .runtime_ordered_local_suites()
            .into_iter()
            .filter(|suite| self.policy.allows_suite(*suite))
            .filter(|suite| suite.is_negotiable())
            .collect();
        let selected_suite =
            CryptoSuite::negotiate(&our_suites, &their_suites).ok_or_else(|| {
                self.state = HandshakeState::Failed {
                    reason: HandshakeFailureReason::NoCommonSuite,
                };
                P2PError::NoCommonSuite
            })?;

        if !message_a.policy.allows_suite(selected_suite.id) {
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::SuiteNegotiationFailed,
            };
            return Ok(Some(HandshakeMessage::Error(
                HandshakeErrorMessage::no_common_suite(),
            )));
        }

        debug!("Selected crypto suite: {}", selected_suite);

        // Store peer identity
        let peer_device_id = self.peer_device_id.clone().unwrap_or_default();
        self.peer_identity = Some(PeerIdentity {
            device_id: peer_device_id,
            public_key_fingerprint: compute_authoritative_public_key_fingerprint(
                identity_keys.protocol_algorithm,
                &identity_keys.protocol_public_key,
            ),
            signing_algorithm: identity_keys.protocol_algorithm,
            signing_public_key: identity_keys.protocol_public_key.clone(),
            kem_public_key: Vec::new(),
            platform: crate::discovery::Platform::Unknown,
            protocol_version: message_a.version.to_string(),
        });
        self.persist_peer_identity();

        // Store MessageA transcript and nonce
        let transcript_bytes = message_a.transcript_bytes();
        let transcript_hash = Sha256::digest(&transcript_bytes).to_vec();
        self.message_a_transcript = Some(transcript_bytes);
        self.message_a_hash = Some(transcript_hash);
        self.client_nonce = Some(message_a.client_nonce);

        // Build and send MessageB
        self.crypto = Some(CryptoProvider::new(selected_suite.id));
        let message_b = self.build_message_b(&message_a, selected_suite.id).await?;

        self.state = HandshakeState::WaitingFinished {
            deadline: Instant::now() + HANDSHAKE_TIMEOUT,
            session_keys: self.state.session_keys().cloned().unwrap(),
            expecting_from: HandshakeRole::Initiator,
        };

        Ok(Some(HandshakeMessage::MessageB(message_b)))
    }

    /// Build MessageB
    async fn build_message_b(
        &mut self,
        message_a: &MessageA,
        selected_suite: CryptoSuiteId,
    ) -> Result<MessageB, P2PError> {
        let crypto = self.crypto.as_ref().unwrap();
        let server_nonce = Self::random_bytes();
        self.server_nonce = Some(server_nonce);

        // Get initiator's key share for the selected suite
        let initiator_key_share = message_a
            .key_shares
            .iter()
            .find(|ks| ks.suite_id == selected_suite.wire_id())
            .ok_or_else(|| P2PError::Protocol("No key share for selected suite".to_string()))?;

        let signing_algorithm = if selected_suite.is_pqc() {
            SignatureAlgorithm::MlDsa65
        } else {
            SignatureAlgorithm::Ed25519
        };
        let signing_public_key = self
            .local_identity
            .signing_public_key(signing_algorithm)
            .ok_or_else(|| P2PError::Protocol("Missing signing public key".to_string()))?
            .to_vec();
        let signing_private_key = self
            .local_identity
            .signing_private_key(signing_algorithm)
            .ok_or_else(|| P2PError::Protocol("Missing signing private key".to_string()))?
            .to_vec();

        let identity_public_key = IdentityPublicKeys {
            protocol_public_key: signing_public_key.clone(),
            protocol_algorithm: signing_algorithm,
            secure_enclave_public_key: None,
        }
        .encode();

        let transcript_hash_a = self
            .message_a_hash
            .as_ref()
            .ok_or_else(|| P2PError::Protocol("Missing MessageA transcript hash".to_string()))?;
        let payload =
            Self::build_capabilities(&self.runtime_ordered_local_suites()).deterministic_encode();
        let (sealed_payload, shared_secret_for_session, responder_share) = if selected_suite
            .is_pqc()
        {
            let kem_private_key = self
                .local_identity
                .kem_private_key(selected_suite)
                .ok_or_else(|| P2PError::Protocol("No KEM key for suite".to_string()))?;
            let mut shared_secret =
                crypto.kem_decapsulate(&initiator_key_share.public_key, kem_private_key)?;
            if selected_suite.is_forward_secure_v2() {
                let initiator_contribution =
                    message_a.initiator_contribution.as_deref().ok_or_else(|| {
                        P2PError::InvalidMessage("Missing v2 initiator contribution".to_string())
                    })?;
                let (responder_contribution, mut ephemeral_secret) =
                    Self::derive_responder_v2_contribution(initiator_contribution)?;
                let session_secret = Self::compose_v2_shared_secret(
                    &shared_secret,
                    &ephemeral_secret,
                    transcript_hash_a,
                    selected_suite,
                );
                let sealed_payload = Self::seal_handshake_payload(
                    &session_secret,
                    transcript_hash_a,
                    &payload,
                    Vec::new(),
                )?;
                shared_secret.fill(0);
                ephemeral_secret.fill(0);
                (
                    sealed_payload,
                    session_secret,
                    responder_contribution.to_vec(),
                )
            } else {
                let sealed_payload = Self::seal_handshake_payload(
                    &shared_secret,
                    transcript_hash_a,
                    &payload,
                    Vec::new(),
                )?;
                (sealed_payload, shared_secret, Vec::new())
            }
        } else {
            let (sealed_payload, exported) = Self::hpke_seal_payload_classic(
                &initiator_key_share.public_key,
                &payload,
                selected_suite.wire_id(),
                Self::classic_hpke_interop_mode_for_provider(&message_a.capabilities.provider_type),
            )?;
            let responder_share = sealed_payload.encapsulated_key.clone();
            (sealed_payload, exported, responder_share)
        };

        // Build message (without signature)
        let mut message_b = MessageB {
            version: HANDSHAKE_VERSION,
            selected_suite: selected_suite.wire_id(),
            responder_share,
            server_nonce,
            encrypted_payload: sealed_payload,
            identity_public_key,
            signature: Vec::new(),
            secure_enclave_signature: None,
        };

        // Sign over MessageA || MessageB
        let signing_data = message_b.signature_preimage(transcript_hash_a);
        let signing_crypto =
            CryptoProvider::new(Self::suite_for_signing_algorithm(signing_algorithm));
        message_b.signature = signing_crypto
            .sign(&signing_data, &signing_private_key)
            .await?;

        // Update transcript
        let transcript_b = message_b.transcript_bytes();
        self.message_b_transcript = Some(transcript_b.clone());
        let transcript_hash_b = Sha256::digest(&transcript_b).to_vec();
        let transcript_hash =
            Sha256::digest([transcript_hash_a.as_slice(), transcript_hash_b.as_slice()].concat())
                .to_vec();
        self.transcript_hash = Some(transcript_hash);

        // Derive session keys
        let client_nonce = self
            .client_nonce
            .ok_or_else(|| P2PError::Protocol("Missing client nonce".to_string()))?;
        let session_keys = SessionKeys::derive(
            &shared_secret_for_session,
            transcript_hash_a,
            &transcript_hash_b,
            &client_nonce,
            &server_nonce,
            selected_suite,
            self.epoch,
            self.role,
        );

        // Update state with session keys
        self.pending_finished = None;
        self.state = HandshakeState::WaitingFinished {
            deadline: Instant::now() + HANDSHAKE_TIMEOUT,
            session_keys,
            expecting_from: HandshakeRole::Initiator,
        };

        Ok(message_b)
    }

    /// Process received MessageB (initiator)
    async fn process_message_b(
        &mut self,
        message_b: MessageB,
    ) -> Result<Option<HandshakeMessage>, P2PError> {
        if self.role != HandshakeRole::Initiator {
            return Err(P2PError::Protocol(
                "Responder should not receive MessageB".to_string(),
            ));
        }

        debug!("Processing MessageB");
        self.state = HandshakeState::ProcessingMessageB { epoch: self.epoch };

        let identity_keys =
            IdentityPublicKeys::decode_with_legacy_fallback(&message_b.identity_public_key)?;

        // Verify signature
        let transcript_hash_a = self
            .message_a_hash
            .clone()
            .ok_or_else(|| P2PError::Protocol("Missing MessageA transcript hash".to_string()))?;
        let signing_data = message_b.signature_preimage(&transcript_hash_a);
        let valid = verify_with_algorithm(
            identity_keys.protocol_algorithm,
            &signing_data,
            &message_b.signature,
            &identity_keys.protocol_public_key,
        )
        .await
        .map_err(|err| P2PError::Crypto(crate::crypto::provider::CryptoError::Signature(err)))?;

        if !valid {
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::SignatureVerificationFailed,
            };
            return Err(P2PError::SignatureVerificationFailed);
        }

        let Some(selected_suite) = CryptoSuiteId::from_wire_id(message_b.selected_suite) else {
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::UnknownSuite {
                    wire_id: message_b.selected_suite,
                },
            };
            return Err(P2PError::HandshakeFailed {
                reason: format!("Unknown selected suite 0x{:04x}", message_b.selected_suite),
            });
        };

        if !self.offered_suites.is_empty() && !self.offered_suites.contains(&selected_suite) {
            warn!(
                "MessageB selected suite was not offered: selected={:?} offered={:?}",
                selected_suite, self.offered_suites
            );
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::SuiteNegotiationFailed,
            };
            return Err(P2PError::HandshakeFailed {
                reason: "Selected suite not offered".to_string(),
            });
        }

        let expected_sign_alg = if selected_suite.is_pqc() {
            SignatureAlgorithm::MlDsa65
        } else {
            SignatureAlgorithm::Ed25519
        };
        if identity_keys.protocol_algorithm != expected_sign_alg {
            warn!(
                "MessageB signature algorithm mismatch: selected={:?} expected={} actual={}",
                selected_suite,
                expected_sign_alg.protocol_name(),
                identity_keys.protocol_algorithm.protocol_name()
            );
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::SignatureAlgorithmMismatch,
            };
            return Err(P2PError::SignatureVerificationFailed);
        }

        let crypto = CryptoProvider::new(selected_suite);
        self.crypto = Some(crypto.clone());

        self.verify_peer_fingerprint(
            &identity_keys.protocol_public_key,
            identity_keys.protocol_algorithm,
        )?;

        // Store peer identity
        let peer_device_id = self.peer_device_id.clone().unwrap_or_default();
        self.peer_identity = Some(PeerIdentity {
            device_id: peer_device_id,
            public_key_fingerprint: compute_authoritative_public_key_fingerprint(
                identity_keys.protocol_algorithm,
                &identity_keys.protocol_public_key,
            ),
            signing_algorithm: identity_keys.protocol_algorithm,
            signing_public_key: identity_keys.protocol_public_key.clone(),
            kem_public_key: Vec::new(),
            platform: crate::discovery::Platform::Unknown,
            protocol_version: message_b.version.to_string(),
        });
        self.persist_peer_identity();

        // Update transcript
        let transcript_b = message_b.transcript_bytes();
        self.message_b_transcript = Some(transcript_b.clone());
        let transcript_hash_b = Sha256::digest(&transcript_b).to_vec();
        let transcript_hash =
            Sha256::digest([transcript_hash_a.as_slice(), transcript_hash_b.as_slice()].concat())
                .to_vec();
        self.transcript_hash = Some(transcript_hash);
        self.server_nonce = Some(message_b.server_nonce);

        let (shared_secret_for_session, payload) = if selected_suite.is_pqc() {
            let mut shared_secret =
                self.pqc_shared_secrets
                    .remove(&selected_suite)
                    .ok_or_else(|| {
                        warn!(
                            "MessageB missing cached PQC shared secret for suite {:?}; cached={:?}",
                            selected_suite,
                            self.pqc_shared_secrets.keys().copied().collect::<Vec<_>>()
                        );
                        P2PError::Protocol("Missing PQC shared secret".to_string())
                    })?;
            if std::env::var("SKYBRIDGE_SMOKE_ROLE").is_ok() {
                println!(
                    "🧪 linux rx MessageB staticSecretSha256={} suite={:?}",
                    Self::smoke_digest_label(&shared_secret),
                    selected_suite
                );
            }
            if selected_suite.is_forward_secure_v2() {
                let mut ephemeral_secret = self
                    .derive_initiator_v2_shared_secret(&message_b.responder_share)
                    .map_err(|err| {
                        warn!(
                            "MessageB failed to derive v2 initiator secret: suite={:?} responderShareLen={} err={}",
                            selected_suite,
                            message_b.responder_share.len(),
                            err
                        );
                        err
                    })?
                    .to_vec();
                let session_secret = Self::compose_v2_shared_secret(
                    &shared_secret,
                    &ephemeral_secret,
                    &transcript_hash_a,
                    selected_suite,
                );
                if std::env::var("SKYBRIDGE_SMOKE_ROLE").is_ok() {
                    let payload_key = crate::crypto::kdf::derive_key(
                        &session_secret,
                        Some(&transcript_hash_a),
                        b"handshake-payload",
                        32,
                    );
                    println!(
                        "🧪 linux rx MessageB sessionSecretSha256={} payloadKeySha256={} suite={:?}",
                        Self::smoke_digest_label(&session_secret),
                        Self::smoke_digest_label(&payload_key),
                        selected_suite
                    );
                }
                let payload = Self::open_handshake_payload(
                    &session_secret,
                    &transcript_hash_a,
                    &message_b.encrypted_payload,
                )
                .map_err(|err| {
                    warn!(
                        "MessageB payload open failed after v2 secret composition: suite={:?} responderShareLen={} encLen={} nonceLen={} tagLen={} ctLen={} err={}",
                        selected_suite,
                        message_b.responder_share.len(),
                        message_b.encrypted_payload.encapsulated_key.len(),
                        message_b.encrypted_payload.nonce.len(),
                        message_b.encrypted_payload.tag.len(),
                        message_b.encrypted_payload.ciphertext.len(),
                        err
                    );
                    err
                })?;
                shared_secret.fill(0);
                ephemeral_secret.fill(0);
                (session_secret, payload)
            } else {
                if std::env::var("SKYBRIDGE_SMOKE_ROLE").is_ok() {
                    let payload_key = crate::crypto::kdf::derive_key(
                        &shared_secret,
                        Some(&transcript_hash_a),
                        b"handshake-payload",
                        32,
                    );
                    println!(
                        "🧪 linux rx MessageB payloadKeySha256={} suite={:?}",
                        Self::smoke_digest_label(&payload_key),
                        selected_suite
                    );
                }
                let payload = Self::open_handshake_payload(
                    &shared_secret,
                    &transcript_hash_a,
                    &message_b.encrypted_payload,
                )
                .map_err(|err| {
                    warn!(
                        "MessageB payload open failed: suite={:?} responderShareLen={} encLen={} nonceLen={} tagLen={} ctLen={} err={}",
                        selected_suite,
                        message_b.responder_share.len(),
                        message_b.encrypted_payload.encapsulated_key.len(),
                        message_b.encrypted_payload.nonce.len(),
                        message_b.encrypted_payload.tag.len(),
                        message_b.encrypted_payload.ciphertext.len(),
                        err
                    );
                    err
                })?;
                (shared_secret, payload)
            }
        } else {
            if !message_b.encrypted_payload.encapsulated_key.is_empty()
                && message_b.responder_share != message_b.encrypted_payload.encapsulated_key
            {
                warn!(
                    "Classic MessageB responder share mismatch: suite={:?} responderShareLen={} encLen={}",
                    selected_suite,
                    message_b.responder_share.len(),
                    message_b.encrypted_payload.encapsulated_key.len()
                );
                self.state = HandshakeState::Failed {
                    reason: HandshakeFailureReason::InvalidMessage(
                        "Encapsulated key mismatch".to_string(),
                    ),
                };
                return Err(P2PError::Protocol("Encapsulated key mismatch".to_string()));
            }

            let kp = self.classic_ephemeral_keypair.take().ok_or_else(|| {
                warn!("Classic MessageB missing initiator ephemeral keypair");
                P2PError::Protocol("Missing initiator classic ephemeral keypair".to_string())
            })?;
            let (payload, exported) = Self::hpke_open_payload_classic(
                &message_b.encrypted_payload,
                &kp,
                selected_suite.wire_id(),
            )
            .map_err(|err| {
                warn!(
                    "Classic MessageB payload open failed: suite={:?} responderShareLen={} encLen={} nonceLen={} ctLen={} err={}",
                    selected_suite,
                    message_b.responder_share.len(),
                    message_b.encrypted_payload.encapsulated_key.len(),
                    message_b.encrypted_payload.nonce.len(),
                    message_b.encrypted_payload.ciphertext.len(),
                    err
                );
                err
            })?;
            (exported, payload)
        };
        let _ = CryptoCapabilities::deterministic_decode(&payload).map_err(|err| {
            warn!(
                "MessageB capabilities decode failed: suite={:?} payloadLen={} err={}",
                selected_suite,
                payload.len(),
                err
            );
            err
        })?;

        // Derive session keys
        let client_nonce = self
            .client_nonce
            .ok_or_else(|| P2PError::Protocol("Missing client nonce".to_string()))?;
        let session_keys = SessionKeys::derive(
            &shared_secret_for_session,
            &transcript_hash_a,
            &transcript_hash_b,
            &client_nonce,
            &message_b.server_nonce,
            selected_suite,
            self.epoch,
            self.role,
        );

        // Create and send Finished message
        let finished = FinishedMessage::new(
            &session_keys.send_control_key,
            &session_keys.transcript_hash,
            FinishedDirection::InitiatorToResponder,
        );

        self.state = HandshakeState::WaitingFinished {
            deadline: Instant::now() + HANDSHAKE_TIMEOUT,
            session_keys,
            expecting_from: HandshakeRole::Responder,
        };

        if let Some(pending_finished) = self.pending_finished.take() {
            let _ = self.process_finished(pending_finished).await?;
        }

        Ok(Some(HandshakeMessage::Finished(finished)))
    }

    /// Process Finished message
    async fn process_finished(
        &mut self,
        finished: FinishedMessage,
    ) -> Result<Option<HandshakeMessage>, P2PError> {
        let session_keys = match &self.state {
            HandshakeState::WaitingFinished { session_keys, .. } => session_keys.clone(),
            HandshakeState::WaitingMessageB { .. } if self.role == HandshakeRole::Initiator => {
                debug!("Stashing early Finished while waiting for MessageB");
                self.pending_finished = Some(finished);
                return Ok(None);
            }
            _ => {
                return Err(P2PError::Protocol(
                    "Unexpected Finished message".to_string(),
                ));
            }
        };

        let expected_direction = match self.role {
            HandshakeRole::Initiator => FinishedDirection::ResponderToInitiator,
            HandshakeRole::Responder => FinishedDirection::InitiatorToResponder,
        };
        if finished.direction != expected_direction {
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::InvalidMessage(
                    "Finished direction mismatch".to_string(),
                ),
            };
            return Err(P2PError::HandshakeFailed {
                reason: "Finished direction mismatch".to_string(),
            });
        }

        // Verify the finished message
        if !finished.verify(
            &session_keys.recv_control_key,
            &session_keys.transcript_hash,
        ) {
            self.state = HandshakeState::Failed {
                reason: HandshakeFailureReason::InvalidMessage(
                    "Finished verification failed".to_string(),
                ),
            };
            return Err(P2PError::HandshakeFailed {
                reason: "Finished verification failed".to_string(),
            });
        }

        info!("Handshake completed successfully");

        // If we're the responder, send our Finished message
        let response = if self.role == HandshakeRole::Responder {
            let our_finished = FinishedMessage::new(
                &session_keys.send_control_key,
                &session_keys.transcript_hash,
                FinishedDirection::ResponderToInitiator,
            );
            Some(HandshakeMessage::Finished(our_finished))
        } else {
            None
        };

        self.state = HandshakeState::Established { session_keys };

        Ok(response)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_handshake_classic() {
        let suites = vec![CryptoSuiteId::X25519_AES256GCM_Ed25519];

        let initiator_identity = LocalIdentity::generate("initiator".to_string(), &suites).unwrap();
        let responder_identity = LocalIdentity::generate("responder".to_string(), &suites).unwrap();

        let mut initiator = HandshakeDriver::new_initiator(initiator_identity);
        let mut responder = HandshakeDriver::new_responder(responder_identity);

        // Initiator starts
        let message_a = initiator.start().await.unwrap();

        // Responder processes MessageA, sends MessageB
        let message_b = responder.process_message(message_a).await.unwrap().unwrap();

        // Initiator processes MessageB, sends Finished
        let finished = initiator.process_message(message_b).await.unwrap().unwrap();

        // Responder processes Finished, sends Finished
        let final_msg = responder.process_message(finished).await.unwrap();
        assert!(final_msg.is_some()); // Responder's Finished

        // Initiator processes final Finished
        if let Some(msg) = final_msg {
            let _ = initiator.process_message(msg).await.unwrap();
        }

        // Both should be established
        assert!(initiator.state().is_established());
        assert!(responder.state().is_established());

        // Session keys should match
        let init_keys = initiator.session_keys().unwrap();
        let resp_keys = responder.session_keys().unwrap();
        assert_eq!(init_keys.send_control_key, resp_keys.recv_control_key);
        assert_eq!(init_keys.recv_control_key, resp_keys.send_control_key);
        assert_eq!(init_keys.send_video_key, resp_keys.recv_video_key);
        assert_eq!(init_keys.recv_video_key, resp_keys.send_video_key);
        assert_eq!(init_keys.send_file_key, resp_keys.recv_file_key);
        assert_eq!(init_keys.recv_file_key, resp_keys.send_file_key);
    }

    #[tokio::test]
    async fn test_initiator_buffers_early_finished_until_message_b_arrives() {
        let suites = vec![CryptoSuiteId::X25519_AES256GCM_Ed25519];

        let initiator_identity =
            LocalIdentity::generate("early-finished-initiator".to_string(), &suites).unwrap();
        let responder_identity =
            LocalIdentity::generate("early-finished-responder".to_string(), &suites).unwrap();

        let mut initiator = HandshakeDriver::new_initiator(initiator_identity);
        let mut responder = HandshakeDriver::new_responder(responder_identity);

        let message_a = initiator.start().await.unwrap();
        let message_b = responder.process_message(message_a).await.unwrap().unwrap();

        let responder_keys = responder
            .session_keys()
            .expect("responder must derive session keys after MessageA")
            .clone();
        let early_finished = HandshakeMessage::Finished(FinishedMessage::new(
            &responder_keys.send_control_key,
            &responder_keys.transcript_hash,
            FinishedDirection::ResponderToInitiator,
        ));

        let buffered = initiator.process_message(early_finished).await.unwrap();
        assert!(buffered.is_none());
        assert!(matches!(
            initiator.state(),
            HandshakeState::WaitingMessageB { .. }
        ));

        let client_finished = initiator
            .process_message(message_b)
            .await
            .unwrap()
            .expect("initiator must still send its Finished");
        assert!(matches!(client_finished, HandshakeMessage::Finished(_)));
        assert!(initiator.state().is_established());
    }

    #[tokio::test]
    async fn test_handshake_hybrid_pqc() {
        // Both sides support hybrid PQC and should negotiate to the best suite
        // allowed by the runtime crypto profile on this host.
        let suites = vec![
            CryptoSuiteId::XWing_AES256GCM_MlDsa65,
            CryptoSuiteId::MlKem768_AES256GCM_MlDsa65,
            CryptoSuiteId::X25519_AES256GCM_Ed25519,
        ];

        let initiator_identity =
            LocalIdentity::generate("pqc_initiator".to_string(), &suites).unwrap();
        let responder_identity =
            LocalIdentity::generate("pqc_responder".to_string(), &suites).unwrap();
        let peer_kem_keys = responder_identity.kem_public_key_map();

        let mut initiator = HandshakeDriver::new_initiator_with_peer_keys(
            initiator_identity,
            HandshakePolicy::default(),
            peer_kem_keys,
        );
        let mut responder = HandshakeDriver::new_responder(responder_identity);
        let expected_suite =
            HandshakeDriver::runtime_suite_order(HandshakeDriver::detect_runtime_crypto_profile())
                .iter()
                .copied()
                .find(|suite| suites.contains(suite))
                .expect("expected at least one runtime-compatible crypto suite");

        // Full handshake
        let message_a = initiator.start().await.unwrap();
        let message_b = responder.process_message(message_a).await.unwrap().unwrap();
        let finished = initiator.process_message(message_b).await.unwrap().unwrap();
        let final_msg = responder.process_message(finished).await.unwrap();
        if let Some(msg) = final_msg {
            let _ = initiator.process_message(msg).await.unwrap();
        }

        assert!(initiator.state().is_established());
        assert!(responder.state().is_established());

        // Verify negotiated suite matches the runtime trust/crypto policy.
        // `MlKem768FsCompat` is an acceptable negotiated wire variant for the
        // same canonical ML-KEM suite on hosts that expose the forward-secure
        // compatibility profile.
        let init_keys = initiator.session_keys().unwrap();
        assert_eq!(
            init_keys.suite_id.canonical_kem_suite(),
            expected_suite.canonical_kem_suite()
        );
    }

    #[allow(clippy::await_holding_lock)]
    #[tokio::test]
    async fn test_handshake_pqc_to_classic_fallback() {
        let _serial = HandshakeDriver::fallback_test_mutex()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        HandshakeDriver::reset_classic_fallback_cooldown_for_tests();
        // Ubuntu 22-25 with PQC meets older device with only classic
        let pqc_suites = vec![
            CryptoSuiteId::XWing_AES256GCM_MlDsa65,
            CryptoSuiteId::MlKem768_AES256GCM_MlDsa65,
            CryptoSuiteId::X25519_AES256GCM_Ed25519,
        ];
        let classic_suites = vec![CryptoSuiteId::X25519_AES256GCM_Ed25519];

        let initiator_identity =
            LocalIdentity::generate("ubuntu_pqc".to_string(), &pqc_suites).unwrap();
        let responder_identity =
            LocalIdentity::generate("legacy_device".to_string(), &classic_suites).unwrap();

        let mut initiator = HandshakeDriver::new_initiator(initiator_identity);
        let mut responder = HandshakeDriver::new_responder(responder_identity);

        // Full handshake
        let message_a = initiator.start().await.unwrap();
        let message_b = responder.process_message(message_a).await.unwrap().unwrap();
        let finished = initiator.process_message(message_b).await.unwrap().unwrap();
        let final_msg = responder.process_message(finished).await.unwrap();
        if let Some(msg) = final_msg {
            let _ = initiator.process_message(msg).await.unwrap();
        }

        assert!(initiator.state().is_established());
        assert!(responder.state().is_established());

        // Verify fallback to classic suite
        let init_keys = initiator.session_keys().unwrap();
        assert_eq!(init_keys.suite_id, CryptoSuiteId::X25519_AES256GCM_Ed25519);
    }

    #[tokio::test]
    async fn test_handshake_v2_fs_pqc() {
        let suites = vec![CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65];
        let initiator_identity = LocalIdentity::generate("v2-init".to_string(), &suites).unwrap();
        let responder_identity = LocalIdentity::generate("v2-resp".to_string(), &suites).unwrap();
        let peer_kem_keys = responder_identity.kem_public_key_map();

        let mut initiator = HandshakeDriver::new_initiator_with_peer_keys(
            initiator_identity,
            HandshakePolicy::strict_pqc(),
            peer_kem_keys,
        );
        let mut responder = HandshakeDriver::new_responder_with_policy(
            responder_identity,
            HandshakePolicy::strict_pqc(),
        );

        let message_a = initiator.start().await.unwrap();
        let message_b = responder
            .process_message(message_a.clone())
            .await
            .unwrap()
            .unwrap();

        match message_a {
            HandshakeMessage::MessageA(msg_a) => {
                assert_eq!(
                    msg_a.supported_suites,
                    vec![CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65.wire_id()]
                );
                assert_eq!(
                    msg_a
                        .initiator_contribution
                        .as_deref()
                        .map(|bytes| bytes.len()),
                    Some(32)
                );
            }
            other => panic!("expected MessageA, got {:?}", other),
        }

        match &message_b {
            HandshakeMessage::MessageB(msg_b) => {
                assert_eq!(
                    msg_b.selected_suite,
                    CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65.wire_id()
                );
                assert_eq!(msg_b.responder_share.len(), 32);
                assert!(msg_b.encrypted_payload.encapsulated_key.is_empty());
            }
            other => panic!("expected MessageB, got {:?}", other),
        }

        let finished = initiator.process_message(message_b).await.unwrap().unwrap();
        let final_msg = responder.process_message(finished).await.unwrap();
        if let Some(msg) = final_msg {
            let _ = initiator.process_message(msg).await.unwrap();
        }

        assert!(initiator.state().is_established());
        assert!(responder.state().is_established());

        let init_keys = initiator.session_keys().unwrap();
        let resp_keys = responder.session_keys().unwrap();
        assert_eq!(
            init_keys.suite_id,
            CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65
        );
        assert_eq!(init_keys.send_control_key, resp_keys.recv_control_key);
        assert_eq!(init_keys.recv_control_key, resp_keys.send_control_key);
    }

    #[test]
    fn test_runtime_crypto_profile_mapping() {
        assert_eq!(
            HandshakeDriver::runtime_crypto_profile_for_ubuntu_major(20),
            RuntimeCryptoProfile::ClassicOnly
        );
        assert_eq!(
            HandshakeDriver::runtime_crypto_profile_for_ubuntu_major(21),
            RuntimeCryptoProfile::ClassicOnly
        );
        assert_eq!(
            HandshakeDriver::runtime_crypto_profile_for_ubuntu_major(22),
            RuntimeCryptoProfile::ClassicOnly
        );
        assert_eq!(
            HandshakeDriver::runtime_crypto_profile_for_ubuntu_major(23),
            RuntimeCryptoProfile::LiboqsPqcPreferred
        );
        assert_eq!(
            HandshakeDriver::runtime_crypto_profile_for_ubuntu_major(24),
            RuntimeCryptoProfile::LiboqsPqcPreferred
        );
        assert_eq!(
            HandshakeDriver::runtime_crypto_profile_for_ubuntu_major(25),
            RuntimeCryptoProfile::LiboqsPqcPreferred
        );
        assert_eq!(
            HandshakeDriver::runtime_crypto_profile_for_ubuntu_major(26),
            RuntimeCryptoProfile::XWingPreferred
        );
    }

    #[allow(clippy::await_holding_lock)]
    #[tokio::test]
    async fn test_classic_fallback_cooldown_blocks_immediate_retry() {
        let _serial = HandshakeDriver::fallback_test_mutex()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        HandshakeDriver::reset_classic_fallback_cooldown_for_tests();

        let suites = vec![
            CryptoSuiteId::XWing_AES256GCM_MlDsa65,
            CryptoSuiteId::MlKem768_AES256GCM_MlDsa65,
            CryptoSuiteId::X25519_AES256GCM_Ed25519,
        ];
        let mut first = HandshakeDriver::new_initiator(
            LocalIdentity::generate("cooldown-init-1".to_string(), &suites).unwrap(),
        );
        first.set_attempt_strategy(HandshakeAttemptStrategy::PqcOnly);
        first.set_peer_device_id(Some("cooldown-peer".to_string()));
        let first_message = first.start().await.unwrap();

        match first_message {
            HandshakeMessage::MessageA(msg_a) => {
                assert_eq!(
                    msg_a.supported_suites,
                    vec![CryptoSuiteId::X25519_AES256GCM_Ed25519.wire_id()]
                );
            }
            other => panic!("expected MessageA, got {:?}", other),
        }
        first.record_classic_fallback_cooldown();

        let mut second = HandshakeDriver::new_initiator(
            LocalIdentity::generate("cooldown-init-2".to_string(), &suites).unwrap(),
        );
        second.set_attempt_strategy(HandshakeAttemptStrategy::PqcOnly);
        second.set_peer_device_id(Some("cooldown-peer".to_string()));
        let err = second
            .start()
            .await
            .expect_err("second fallback for same peer should hit cooldown");

        match err {
            P2PError::HandshakeFailed { reason } => {
                assert!(reason.contains("cooldown"));
            }
            other => panic!("unexpected error: {}", other),
        }

        HandshakeDriver::reset_classic_fallback_cooldown_for_tests();
    }

    #[tokio::test]
    async fn test_expected_peer_fingerprint_mismatch_is_rejected() {
        let suites = vec![CryptoSuiteId::X25519_AES256GCM_Ed25519];
        let initiator_identity = LocalIdentity::generate("fp-init".to_string(), &suites).unwrap();
        let responder_identity = LocalIdentity::generate("fp-resp".to_string(), &suites).unwrap();

        let mut initiator = HandshakeDriver::new_initiator_with_policy(
            initiator_identity,
            HandshakePolicy::default(),
        );
        let mut responder = HandshakeDriver::new_responder_with_policy(
            responder_identity,
            HandshakePolicy::default(),
        );
        responder.set_expected_peer_fingerprint(Some("deadbeef".repeat(8)));

        let message_a = initiator.start().await.unwrap();
        let err = responder
            .process_message(message_a)
            .await
            .expect_err("fingerprint mismatch must be rejected");

        match err {
            P2PError::TrustPolicyViolation(reason) => {
                assert!(reason.contains("fingerprint"));
            }
            other => panic!("unexpected error: {}", other),
        }
        assert!(responder.state().is_failed());
    }
}
