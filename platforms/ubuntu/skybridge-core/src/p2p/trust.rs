//! Trust store for peer identity and KEM public keys.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::crypto::signature::SignatureAlgorithm;
use crate::crypto::suite::CryptoSuiteId;
use crate::p2p::types::{P2PError, PeerIdentity};

/// Trust store errors
#[derive(Debug, Error)]
pub enum TrustError {
    /// Project directory unavailable
    #[error("Trust store directory unavailable")]
    NoProjectDir,
    /// IO error
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    /// Serialization error
    #[error("Serialization error: {0}")]
    Serde(#[from] serde_json::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct TrustStoreData {
    peers: HashMap<String, TrustedPeer>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct TrustedPeer {
    device_id: String,
    #[serde(default)]
    verified: bool,
    #[serde(default)]
    signing_fingerprint: String,
    #[serde(default)]
    signing_algorithm: Option<SignatureAlgorithm>,
    #[serde(default)]
    protocol_signing_algorithm: Option<SignatureAlgorithm>,
    #[serde(default)]
    protocol_public_key_fingerprint: Option<String>,
    #[serde(default)]
    current_device_id: Option<String>,
    #[serde(default)]
    known_device_ids: Vec<String>,
    #[serde(default)]
    current_path_lifecycle_state: Option<CurrentPathLifecycleState>,
    #[serde(default)]
    kem_public_keys: HashMap<u16, Vec<u8>>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CurrentPathLifecycleState {
    Active,
    ReverificationRequired,
    Quarantined,
    Revoked,
}

/// Local trust policy gates enforced by the connection stack.
#[derive(Debug, Clone, Copy, Default)]
pub struct ConnectionTrustPolicy {
    /// Reject peers that do not already have a verified trust record.
    pub block_unknown: bool,
    /// Require an expected fingerprint (trusted pin or discovery hint) for outbound validation.
    pub require_verification: bool,
}

/// Trusted peer summary for UI display
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrustedPeerSummary {
    /// Peer device ID
    pub device_id: String,
    /// Signing key fingerprint (SHA-256 hex)
    pub signing_fingerprint: String,
    /// Signing algorithm
    pub signing_algorithm: Option<SignatureAlgorithm>,
    /// Current-path authoritative fingerprint when available.
    pub protocol_public_key_fingerprint: Option<String>,
}

/// Peer trust store
#[derive(Debug)]
pub struct TrustStore {
    path: PathBuf,
    data: TrustStoreData,
}

impl TrustStore {
    /// Load trust store from disk (or create empty)
    pub fn load() -> Result<Self, TrustError> {
        let path = Self::store_path()?;
        Self::load_at(path)
    }

    /// Save trust store to disk (atomic)
    pub fn save(&self) -> Result<(), TrustError> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp_path = self.path.with_extension("tmp");
        let serialized = serde_json::to_string_pretty(&self.data)?;
        fs::write(&tmp_path, serialized)?;
        fs::rename(tmp_path, &self.path)?;
        Ok(())
    }

    /// Update or insert a peer record
    pub fn upsert_peer_identity(&mut self, peer: &PeerIdentity) -> Result<(), TrustError> {
        if peer.device_id.is_empty() {
            return Ok(());
        }
        let entry = self
            .data
            .peers
            .entry(peer.device_id.clone())
            .or_insert_with(|| TrustedPeer {
                device_id: peer.device_id.clone(),
                verified: true,
                signing_fingerprint: String::new(),
                signing_algorithm: None,
                protocol_signing_algorithm: None,
                protocol_public_key_fingerprint: None,
                current_device_id: Some(peer.device_id.clone()),
                known_device_ids: vec![peer.device_id.clone()],
                current_path_lifecycle_state: None,
                kem_public_keys: HashMap::new(),
            });

        entry.verified = true;
        entry.current_device_id = Some(peer.device_id.clone());
        if !entry
            .known_device_ids
            .iter()
            .any(|id| id == &peer.device_id)
        {
            entry.known_device_ids.push(peer.device_id.clone());
        }
        match peer.signing_algorithm {
            SignatureAlgorithm::MlDsa65 => {
                entry.protocol_signing_algorithm = Some(peer.signing_algorithm);
                entry.protocol_public_key_fingerprint = Some(peer.public_key_fingerprint.clone());
                entry.current_path_lifecycle_state = Some(CurrentPathLifecycleState::Active);
            }
            SignatureAlgorithm::Ed25519 | SignatureAlgorithm::P256Ecdsa => {
                entry.signing_algorithm = Some(peer.signing_algorithm);
                entry.signing_fingerprint = peer.public_key_fingerprint.clone();
                if entry.protocol_public_key_fingerprint.is_none() {
                    entry.protocol_signing_algorithm = Some(peer.signing_algorithm);
                    entry.protocol_public_key_fingerprint =
                        Some(peer.public_key_fingerprint.clone());
                    entry.current_path_lifecycle_state = Some(CurrentPathLifecycleState::Active);
                }
            }
        }
        if !peer.kem_public_key.is_empty() {
            // Store KEM key against current suite if known
            // (Caller should also set per-suite explicitly when available)
        }

        self.save()
    }

    /// List trusted peers for UI display
    pub fn list_peers(&self) -> Vec<TrustedPeerSummary> {
        let mut peers: Vec<TrustedPeerSummary> = self
            .data
            .peers
            .values()
            .filter(|peer| peer.verified)
            .map(|peer| TrustedPeerSummary {
                device_id: peer.device_id.clone(),
                signing_fingerprint: peer.signing_fingerprint.clone(),
                signing_algorithm: peer.signing_algorithm,
                protocol_public_key_fingerprint: peer.protocol_public_key_fingerprint.clone(),
            })
            .collect();
        peers.sort_by(|a, b| a.device_id.cmp(&b.device_id));
        peers
    }

    /// Check whether a device is trusted (present in the trust store).
    pub fn is_trusted(&self, device_id: &str) -> bool {
        self.data
            .peers
            .get(device_id)
            .map(|peer| peer.verified)
            .unwrap_or(false)
    }

    /// Check whether a device has any local record (trusted or observed).
    pub fn has_peer(&self, device_id: &str) -> bool {
        self.data.peers.contains_key(device_id)
    }

    /// Update or insert a peer fingerprint observed from discovery.
    ///
    /// This never upgrades a peer to trusted and never overwrites a verified fingerprint pin.
    pub fn upsert_peer_fingerprint(
        &mut self,
        device_id: &str,
        fingerprint: &str,
    ) -> Result<(), TrustError> {
        if device_id.is_empty() || fingerprint.is_empty() {
            return Ok(());
        }
        let entry = self
            .data
            .peers
            .entry(device_id.to_string())
            .or_insert_with(|| TrustedPeer {
                device_id: device_id.to_string(),
                verified: false,
                signing_fingerprint: fingerprint.to_string(),
                signing_algorithm: None,
                protocol_signing_algorithm: None,
                protocol_public_key_fingerprint: None,
                current_device_id: None,
                known_device_ids: Vec::new(),
                current_path_lifecycle_state: None,
                kem_public_keys: HashMap::new(),
            });
        if !entry.verified {
            entry.signing_fingerprint = fingerprint.to_string();
        }
        self.save()
    }

    /// Upsert a peer KEM public key for a specific suite
    pub fn upsert_peer_kem_key(
        &mut self,
        device_id: &str,
        suite: CryptoSuiteId,
        public_key: Vec<u8>,
    ) -> Result<(), TrustError> {
        let entry = self
            .data
            .peers
            .entry(device_id.to_string())
            .or_insert_with(|| TrustedPeer {
                device_id: device_id.to_string(),
                verified: false,
                signing_fingerprint: String::new(),
                signing_algorithm: None,
                protocol_signing_algorithm: None,
                protocol_public_key_fingerprint: None,
                current_device_id: None,
                known_device_ids: Vec::new(),
                current_path_lifecycle_state: None,
                kem_public_keys: HashMap::new(),
            });

        entry.kem_public_keys.insert(suite.wire_id(), public_key);
        self.save()
    }

    /// Fetch peer KEM public keys by suite
    pub fn peer_kem_keys(&self, device_id: &str) -> HashMap<CryptoSuiteId, Vec<u8>> {
        let mut result = HashMap::new();
        let Some(peer) = self.data.peers.get(device_id) else {
            return result;
        };
        for (wire_id, key) in &peer.kem_public_keys {
            if let Some(suite) = CryptoSuiteId::from_wire_id(*wire_id) {
                result.insert(suite, key.clone());
            }
        }
        result
    }

    /// Fetch peer signing fingerprint (if available)
    pub fn peer_signing_fingerprint(&self, device_id: &str) -> Option<String> {
        let peer = self.data.peers.get(device_id)?;
        if !peer.verified || peer.signing_fingerprint.is_empty() {
            None
        } else {
            Some(peer.signing_fingerprint.clone())
        }
    }

    /// Fetch the locally pinned fingerprint for a specific protocol signing
    /// algorithm.
    pub fn peer_pinned_fingerprint_for_algorithm(
        &self,
        device_id: &str,
        algorithm: SignatureAlgorithm,
    ) -> Option<String> {
        let peer = self.data.peers.get(device_id)?;
        if !peer.verified {
            return None;
        }

        if peer.signing_algorithm == Some(algorithm) && !peer.signing_fingerprint.is_empty() {
            return Some(peer.signing_fingerprint.clone());
        }

        if peer.current_path_lifecycle_state == Some(CurrentPathLifecycleState::Active)
            && peer.protocol_signing_algorithm == Some(algorithm)
        {
            return peer.protocol_public_key_fingerprint.clone();
        }

        None
    }

    /// Fetch any locally known signing fingerprint for a peer.
    ///
    /// Unlike `peer_signing_fingerprint`, this also returns observed discovery hints for
    /// unverified peers, which is useful for outbound handshake pinning.
    pub fn peer_fingerprint_hint(&self, device_id: &str) -> Option<String> {
        let peer = self.data.peers.get(device_id)?;
        if peer.signing_fingerprint.is_empty() {
            None
        } else {
            Some(peer.signing_fingerprint.clone())
        }
    }

    /// Fetch the authoritative current-path fingerprint for a peer, if the
    /// peer has an active authority record.
    pub fn peer_current_path_fingerprint(&self, device_id: &str) -> Option<String> {
        let peer = self.data.peers.get(device_id)?;
        if peer.current_path_lifecycle_state != Some(CurrentPathLifecycleState::Active) {
            return None;
        }
        peer.protocol_public_key_fingerprint.clone()
    }

    /// Upsert a current-path authority learned from signaling or a verified
    /// cross-network handshake.
    pub fn upsert_current_path_authority(
        &mut self,
        device_id: &str,
        protocol_signing_algorithm: SignatureAlgorithm,
        protocol_public_key_fingerprint: &str,
    ) -> Result<(), TrustError> {
        let device_id = device_id.trim();
        let protocol_public_key_fingerprint =
            protocol_public_key_fingerprint.trim().to_ascii_lowercase();
        if device_id.is_empty() || protocol_public_key_fingerprint.is_empty() {
            return Ok(());
        }

        let entry = self
            .data
            .peers
            .entry(device_id.to_string())
            .or_insert_with(|| TrustedPeer {
                device_id: device_id.to_string(),
                verified: false,
                signing_fingerprint: protocol_public_key_fingerprint.clone(),
                signing_algorithm: Some(protocol_signing_algorithm),
                protocol_signing_algorithm: Some(protocol_signing_algorithm),
                protocol_public_key_fingerprint: Some(protocol_public_key_fingerprint.clone()),
                current_device_id: Some(device_id.to_string()),
                known_device_ids: vec![device_id.to_string()],
                current_path_lifecycle_state: Some(CurrentPathLifecycleState::Active),
                kem_public_keys: HashMap::new(),
            });

        entry.protocol_signing_algorithm = Some(protocol_signing_algorithm);
        entry.protocol_public_key_fingerprint = Some(protocol_public_key_fingerprint.clone());
        entry.current_device_id = Some(device_id.to_string());
        if !entry.known_device_ids.iter().any(|id| id == device_id) {
            entry.known_device_ids.push(device_id.to_string());
        }
        entry.current_path_lifecycle_state = Some(CurrentPathLifecycleState::Active);
        if entry.signing_fingerprint.is_empty() {
            entry.signing_fingerprint = protocol_public_key_fingerprint;
        }
        self.save()
    }

    /// Remove a peer from trust store
    pub fn remove_peer(&mut self, device_id: &str) -> Result<(), TrustError> {
        self.data.peers.remove(device_id);
        self.save()
    }

    /// Remove all peers from trust store
    pub fn clear_all(&mut self) -> Result<(), TrustError> {
        self.data.peers.clear();
        self.save()
    }

    fn store_path() -> Result<PathBuf, TrustError> {
        let project =
            ProjectDirs::from("com", "SkyBridge", "Compass").ok_or(TrustError::NoProjectDir)?;
        Ok(project.data_dir().join("p2p_trust.json"))
    }

    #[cfg(test)]
    fn store_path_for_tests(base: &std::path::Path) -> PathBuf {
        base.join("p2p_trust.json")
    }

    fn load_at(path: PathBuf) -> Result<Self, TrustError> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        if path.exists() {
            let raw = fs::read_to_string(&path)?;
            let data: TrustStoreData = serde_json::from_str(&raw)?;
            Ok(Self { path, data })
        } else {
            Ok(Self {
                path,
                data: TrustStoreData::default(),
            })
        }
    }
}

fn enforce_outbound_trust_policy_with_store(
    policy: ConnectionTrustPolicy,
    peer_device_id: Option<&str>,
    expected_peer_fingerprint: Option<&str>,
    store: Option<&TrustStore>,
) -> Result<(), P2PError> {
    if !policy.block_unknown && !policy.require_verification {
        return Ok(());
    }

    let peer_device_id = peer_device_id
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let expected_peer_fingerprint = expected_peer_fingerprint
        .map(str::trim)
        .filter(|value| !value.is_empty());

    if policy.block_unknown {
        let Some(device_id) = peer_device_id else {
            return Err(P2PError::TrustPolicyViolation(
                "Unknown device blocked: missing peer device ID".to_string(),
            ));
        };
        let trusted = store
            .as_ref()
            .map(|store| store.is_trusted(device_id))
            .unwrap_or(false);
        if !trusted {
            return Err(P2PError::TrustPolicyViolation(format!(
                "Unknown device blocked: {} is not trusted",
                device_id
            )));
        }
    }

    if policy.require_verification {
        let trusted_pin = peer_device_id.and_then(|device_id| {
            store
                .as_ref()
                .and_then(|store| store.peer_signing_fingerprint(device_id))
        });
        if trusted_pin.is_none() && expected_peer_fingerprint.is_none() {
            return Err(P2PError::TrustPolicyViolation(
                "Peer verification required but no fingerprint is available".to_string(),
            ));
        }
    }

    Ok(())
}

fn enforce_inbound_trust_policy_with_store(
    policy: ConnectionTrustPolicy,
    device_id: &str,
    actual_fingerprint: &str,
    store: Option<&TrustStore>,
) -> Result<(), P2PError> {
    if !policy.block_unknown && !policy.require_verification {
        return Ok(());
    }

    let trusted = store
        .as_ref()
        .map(|store| store.is_trusted(device_id))
        .unwrap_or(false);

    if policy.block_unknown && !trusted {
        return Err(P2PError::TrustPolicyViolation(format!(
            "Unknown device blocked: {} is not trusted",
            device_id
        )));
    }

    if let Some(expected) = store
        .as_ref()
        .and_then(|store| store.peer_signing_fingerprint(device_id))
        && expected != actual_fingerprint
    {
        return Err(P2PError::TrustPolicyViolation(format!(
            "Peer fingerprint mismatch for {}",
            device_id
        )));
    }

    Ok(())
}

/// Enforce local outbound trust policy for a connection attempt.
pub fn enforce_outbound_trust_policy(
    policy: ConnectionTrustPolicy,
    peer_device_id: Option<&str>,
    expected_peer_fingerprint: Option<&str>,
) -> Result<(), P2PError> {
    let store = TrustStore::load().ok();
    enforce_outbound_trust_policy_with_store(
        policy,
        peer_device_id,
        expected_peer_fingerprint,
        store.as_ref(),
    )
}

/// Enforce local inbound trust policy once a peer declares its device identity.
pub fn enforce_inbound_trust_policy(
    policy: ConnectionTrustPolicy,
    device_id: &str,
    actual_fingerprint: &str,
) -> Result<(), P2PError> {
    let store = TrustStore::load().ok();
    enforce_inbound_trust_policy_with_store(policy, device_id, actual_fingerprint, store.as_ref())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::discovery::Platform;
    use crate::p2p::types::PeerIdentity;
    use tempfile::tempdir;

    #[test]
    fn test_trust_store_roundtrip() {
        let dir = tempdir().unwrap();
        let path = TrustStore::store_path_for_tests(dir.path());
        let mut store = TrustStore {
            path,
            data: TrustStoreData::default(),
        };

        store
            .upsert_peer_kem_key(
                "peer-1",
                CryptoSuiteId::MlKem768_AES256GCM_MlDsa65,
                vec![1, 2, 3],
            )
            .unwrap();

        let loaded = TrustStore::load_at(store.path.clone()).unwrap();
        let keys = loaded.peer_kem_keys("peer-1");
        assert_eq!(
            keys.get(&CryptoSuiteId::MlKem768_AES256GCM_MlDsa65),
            Some(&vec![1, 2, 3])
        );
    }

    #[test]
    fn discovery_fingerprint_does_not_mark_peer_as_trusted() {
        let dir = tempdir().unwrap();
        let path = TrustStore::store_path_for_tests(dir.path());
        let mut store = TrustStore {
            path,
            data: TrustStoreData::default(),
        };

        store
            .upsert_peer_fingerprint("peer-1", "fp-observed")
            .unwrap();

        assert!(store.has_peer("peer-1"));
        assert!(!store.is_trusted("peer-1"));
        assert!(store.peer_signing_fingerprint("peer-1").is_none());
        assert_eq!(
            store.peer_fingerprint_hint("peer-1").as_deref(),
            Some("fp-observed")
        );
        assert!(store.list_peers().is_empty());
    }

    #[test]
    fn discovery_cannot_overwrite_verified_fingerprint() {
        let dir = tempdir().unwrap();
        let path = TrustStore::store_path_for_tests(dir.path());
        let mut store = TrustStore {
            path,
            data: TrustStoreData::default(),
        };
        let peer = PeerIdentity {
            device_id: "peer-1".to_string(),
            public_key_fingerprint: "fp-verified".to_string(),
            signing_algorithm: SignatureAlgorithm::Ed25519,
            signing_public_key: vec![1, 2, 3],
            kem_public_key: Vec::new(),
            platform: Platform::Ubuntu,
            protocol_version: "1".to_string(),
        };

        store.upsert_peer_identity(&peer).unwrap();
        store
            .upsert_peer_fingerprint("peer-1", "fp-spoofed")
            .unwrap();

        assert!(store.is_trusted("peer-1"));
        assert_eq!(
            store.peer_signing_fingerprint("peer-1").as_deref(),
            Some("fp-verified")
        );
    }

    #[test]
    fn algorithm_specific_pins_preserve_classic_and_current_path_authority() {
        let dir = tempdir().unwrap();
        let path = TrustStore::store_path_for_tests(dir.path());
        let mut store = TrustStore {
            path,
            data: TrustStoreData::default(),
        };
        let classic_peer = PeerIdentity {
            device_id: "peer-1".to_string(),
            public_key_fingerprint: "fp-ed25519".to_string(),
            signing_algorithm: SignatureAlgorithm::Ed25519,
            signing_public_key: vec![1, 2, 3],
            kem_public_key: Vec::new(),
            platform: Platform::Ubuntu,
            protocol_version: "1".to_string(),
        };
        store.upsert_peer_identity(&classic_peer).unwrap();
        store
            .upsert_current_path_authority("peer-1", SignatureAlgorithm::MlDsa65, "fp-mldsa")
            .unwrap();

        assert_eq!(
            store
                .peer_pinned_fingerprint_for_algorithm("peer-1", SignatureAlgorithm::Ed25519)
                .as_deref(),
            Some("fp-ed25519")
        );
        assert_eq!(
            store
                .peer_pinned_fingerprint_for_algorithm("peer-1", SignatureAlgorithm::MlDsa65)
                .as_deref(),
            Some("fp-mldsa")
        );
    }

    #[test]
    fn outbound_trust_policy_requires_known_peer_when_block_unknown() {
        let policy = ConnectionTrustPolicy {
            block_unknown: true,
            require_verification: false,
        };

        let err = enforce_outbound_trust_policy_with_store(policy, None, None, None).unwrap_err();
        assert!(matches!(err, P2PError::TrustPolicyViolation(_)));
        assert!(err.to_string().contains("missing peer device ID"));
    }

    #[test]
    fn inbound_trust_policy_rejects_pinned_fingerprint_mismatch() {
        let dir = tempdir().unwrap();
        let path = TrustStore::store_path_for_tests(dir.path());
        let mut store = TrustStore {
            path,
            data: TrustStoreData::default(),
        };
        let peer = PeerIdentity {
            device_id: "peer-1".to_string(),
            public_key_fingerprint: "fp-verified".to_string(),
            signing_algorithm: SignatureAlgorithm::Ed25519,
            signing_public_key: vec![1, 2, 3],
            kem_public_key: Vec::new(),
            platform: Platform::Ubuntu,
            protocol_version: "1".to_string(),
        };
        store.upsert_peer_identity(&peer).unwrap();

        let policy = ConnectionTrustPolicy {
            block_unknown: false,
            require_verification: true,
        };
        let err =
            enforce_inbound_trust_policy_with_store(policy, "peer-1", "fp-other", Some(&store))
                .unwrap_err();

        assert!(matches!(err, P2PError::TrustPolicyViolation(_)));
        assert!(err.to_string().contains("fingerprint mismatch"));
    }
}
