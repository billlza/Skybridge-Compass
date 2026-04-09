//! Secure Session Overlap Avoidance (SOA) support.
//!
//! Mirrors the macOS/iOS Pro release design:
//! - MessageA may carry an optional "SOA1" extensions container (handled in `messages.rs`).
//! - The SOA TLV (type=0x0001) binds:
//!   - initiatorPeerId (32 bytes)
//!   - targetPeerId (32 bytes)
//!   - attemptId (16 bytes)
//! - Supersede arbitration is keyed by a canonical pairKey (sorted concatenation).

use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

pub const SOA_TLV_TYPE: u16 = 0x0001;
pub const SOA_VERSION: u8 = 1;
pub const PEER_ID_LEN: usize = 32;
pub const ATTEMPT_ID_LEN: usize = 16;
pub const SOA_VALUE_LEN: usize = 1 + PEER_ID_LEN + PEER_ID_LEN + ATTEMPT_ID_LEN;
type SupersedeCallback = Box<dyn Fn([u8; PEER_ID_LEN], [u8; ATTEMPT_ID_LEN]) + Send + Sync>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SoaExtension {
    pub version: u8,
    pub initiator_peer_id: [u8; PEER_ID_LEN],
    pub target_peer_id: [u8; PEER_ID_LEN],
    pub attempt_id: [u8; ATTEMPT_ID_LEN],
}

impl SoaExtension {
    pub fn encode_tlv(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(4 + SOA_VALUE_LEN);
        out.extend_from_slice(&SOA_TLV_TYPE.to_le_bytes());
        out.extend_from_slice(&(SOA_VALUE_LEN as u16).to_le_bytes());
        out.push(self.version);
        out.extend_from_slice(&self.initiator_peer_id);
        out.extend_from_slice(&self.target_peer_id);
        out.extend_from_slice(&self.attempt_id);
        out
    }

    pub fn decode_from_extensions(raw: &[u8]) -> Option<Self> {
        if raw.is_empty() {
            return None;
        }
        let mut offset = 0usize;
        while offset + 4 <= raw.len() {
            let tlv_type = u16::from_le_bytes([raw[offset], raw[offset + 1]]);
            let len = u16::from_le_bytes([raw[offset + 2], raw[offset + 3]]) as usize;
            offset += 4;
            if offset + len > raw.len() {
                return None;
            }
            if tlv_type == SOA_TLV_TYPE {
                if len != SOA_VALUE_LEN {
                    return None;
                }
                let value = &raw[offset..offset + len];
                let version = value[0];
                if version != SOA_VERSION {
                    return None;
                }
                let mut initiator_peer_id = [0u8; PEER_ID_LEN];
                initiator_peer_id.copy_from_slice(&value[1..1 + PEER_ID_LEN]);
                let mut target_peer_id = [0u8; PEER_ID_LEN];
                target_peer_id
                    .copy_from_slice(&value[1 + PEER_ID_LEN..1 + PEER_ID_LEN + PEER_ID_LEN]);
                let mut attempt_id = [0u8; ATTEMPT_ID_LEN];
                attempt_id.copy_from_slice(&value[SOA_VALUE_LEN - ATTEMPT_ID_LEN..SOA_VALUE_LEN]);
                return Some(Self {
                    version,
                    initiator_peer_id,
                    target_peer_id,
                    attempt_id,
                });
            }
            offset += len;
        }
        None
    }
}

/// Canonical peer id bytes (matches Pro release).
///
/// `peerId = SHA256(trim(lowercased(deviceIdString)))`
pub fn canonical_peer_id_bytes(raw: &str) -> [u8; 32] {
    let normalized = raw.trim().to_lowercase();
    Sha256::digest(normalized.as_bytes()).into()
}

/// Canonical SOA pairKey (sorted concatenation).
pub fn pair_key(a: [u8; 32], b: [u8; 32]) -> [u8; 64] {
    let (first, second) = if a <= b { (a, b) } else { (b, a) };
    let mut out = [0u8; 64];
    out[..32].copy_from_slice(&first);
    out[32..].copy_from_slice(&second);
    out
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegisterDecision {
    Accepted,
    AlreadyConnected,
    AlreadyInProgress,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IncomingDecision {
    Accept,
    RejectAlreadyConnected,
    RejectBinding,
    RejectRateLimited,
    RejectLocalWinner {
        winner_peer_id: [u8; 32],
        winner_attempt_id: [u8; 16],
    },
    AcceptAndSupersedeLocal {
        winner_peer_id: [u8; 32],
        winner_attempt_id: [u8; 16],
    },
}

pub struct OutgoingAttempt {
    pub pair_key: [u8; 64],
    pub initiator_peer_id: [u8; 32],
    pub attempt_id: [u8; 16],
    pub started_at: Instant,
    pub on_superseded: Box<dyn Fn([u8; 32], [u8; 16]) + Send + Sync + 'static>,
}

struct ArbiterState {
    outgoing_by_pair: HashMap<[u8; 64], OutgoingAttempt>,
    established_pairs: HashSet<[u8; 64]>,
    supersede_timestamps_by_pair: HashMap<[u8; 64], Vec<Instant>>,
}

/// Global SOA session arbiter (process-local).
pub struct PeerSessionArbiter {
    pending_window: Duration,
    supersede_rate_limit: usize,
    supersede_rate_window: Duration,
    state: Mutex<ArbiterState>,
}

impl PeerSessionArbiter {
    pub fn shared() -> &'static Self {
        static INSTANCE: OnceLock<PeerSessionArbiter> = OnceLock::new();
        INSTANCE.get_or_init(|| PeerSessionArbiter {
            pending_window: Duration::from_secs(10),
            supersede_rate_limit: 3,
            supersede_rate_window: Duration::from_secs(60),
            state: Mutex::new(ArbiterState {
                outgoing_by_pair: HashMap::new(),
                established_pairs: HashSet::new(),
                supersede_timestamps_by_pair: HashMap::new(),
            }),
        })
    }

    pub fn register_outgoing(&self, attempt: OutgoingAttempt) -> RegisterDecision {
        let mut guard = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if guard.established_pairs.contains(&attempt.pair_key) {
            return RegisterDecision::AlreadyConnected;
        }
        if let Some(existing) = guard.outgoing_by_pair.get(&attempt.pair_key)
            && Instant::now().saturating_duration_since(existing.started_at) <= self.pending_window
        {
            return RegisterDecision::AlreadyInProgress;
        }
        guard.outgoing_by_pair.insert(attempt.pair_key, attempt);
        RegisterDecision::Accepted
    }

    pub fn clear_outgoing(&self, pair_key: [u8; 64], attempt_id: Option<[u8; 16]>) {
        let mut guard = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some(existing) = guard.outgoing_by_pair.get(&pair_key) else {
            return;
        };
        if let Some(attempt_id) = attempt_id
            && existing.attempt_id != attempt_id
        {
            return;
        }
        guard.outgoing_by_pair.remove(&pair_key);
    }

    pub fn mark_established(&self, pair_key: [u8; 64]) {
        let mut guard = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.established_pairs.insert(pair_key);
        guard.outgoing_by_pair.remove(&pair_key);
    }

    pub fn clear_established(&self, pair_key: [u8; 64]) {
        let mut guard = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.established_pairs.remove(&pair_key);
    }

    pub fn evaluate_incoming(
        &self,
        pair_key: [u8; 64],
        remote_initiator_peer_id: [u8; 32],
        remote_attempt_id: [u8; 16],
        target_peer_id: [u8; 32],
        expected_remote_peer_id: [u8; 32],
        local_peer_id: [u8; 32],
    ) -> IncomingDecision {
        let mut on_superseded: Option<SupersedeCallback> = None;

        let decision = {
            let now = Instant::now();
            let mut guard = self
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());

            if guard.established_pairs.contains(&pair_key) {
                return IncomingDecision::RejectAlreadyConnected;
            }

            if target_peer_id != local_peer_id
                || remote_initiator_peer_id != expected_remote_peer_id
            {
                return IncomingDecision::RejectBinding;
            }

            let Some(local) = guard.outgoing_by_pair.get(&pair_key) else {
                return IncomingDecision::Accept;
            };

            if now.saturating_duration_since(local.started_at) > self.pending_window {
                guard.outgoing_by_pair.remove(&pair_key);
                return IncomingDecision::Accept;
            }

            // Rate limit supersede per pair.
            let recent = guard
                .supersede_timestamps_by_pair
                .get(&pair_key)
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter(|t| now.saturating_duration_since(*t) <= self.supersede_rate_window)
                .collect::<Vec<_>>();
            if recent.len() >= self.supersede_rate_limit {
                guard.supersede_timestamps_by_pair.insert(pair_key, recent);
                return IncomingDecision::RejectRateLimited;
            }

            let remote_wins = is_remote_winner(
                local.initiator_peer_id,
                local.attempt_id,
                remote_initiator_peer_id,
                remote_attempt_id,
            );

            if remote_wins {
                let mut updated = recent;
                updated.push(now);
                guard.supersede_timestamps_by_pair.insert(pair_key, updated);
                let local = guard
                    .outgoing_by_pair
                    .remove(&pair_key)
                    .expect("local attempt must exist");
                on_superseded = Some(local.on_superseded);
                IncomingDecision::AcceptAndSupersedeLocal {
                    winner_peer_id: remote_initiator_peer_id,
                    winner_attempt_id: remote_attempt_id,
                }
            } else {
                IncomingDecision::RejectLocalWinner {
                    winner_peer_id: local.initiator_peer_id,
                    winner_attempt_id: local.attempt_id,
                }
            }
        };

        if let Some(cb) = on_superseded {
            cb(remote_initiator_peer_id, remote_attempt_id);
        }
        decision
    }
}

fn is_remote_winner(
    local_initiator_peer_id: [u8; 32],
    local_attempt_id: [u8; 16],
    remote_initiator_peer_id: [u8; 32],
    remote_attempt_id: [u8; 16],
) -> bool {
    if remote_initiator_peer_id == local_initiator_peer_id {
        return remote_attempt_id < local_attempt_id;
    }
    remote_initiator_peer_id < local_initiator_peer_id
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::RngExt;
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };

    #[test]
    fn soa_tlv_roundtrip() {
        let mut initiator_peer_id = [0u8; 32];
        let mut target_peer_id = [0u8; 32];
        let mut attempt_id = [0u8; 16];
        let mut rng = rand::rng();
        rng.fill(&mut initiator_peer_id);
        rng.fill(&mut target_peer_id);
        rng.fill(&mut attempt_id);

        let ext = SoaExtension {
            version: SOA_VERSION,
            initiator_peer_id,
            target_peer_id,
            attempt_id,
        };
        let encoded = ext.encode_tlv();
        let decoded = SoaExtension::decode_from_extensions(&encoded).expect("decode ext");
        assert_eq!(decoded, ext);
    }

    #[test]
    fn arbiter_supersedes_local_when_remote_wins() {
        let arbiter = PeerSessionArbiter::shared();

        let local_peer_id = [0xFFu8; 32];
        let remote_peer_id = [0x00u8; 32];
        let pair_key = pair_key(local_peer_id, remote_peer_id);

        let local_attempt_id = [0xFFu8; 16];
        let remote_attempt_id = [0x00u8; 16];

        let superseded = Arc::new(AtomicBool::new(false));
        let superseded_cb = superseded.clone();

        let decision = arbiter.register_outgoing(OutgoingAttempt {
            pair_key,
            initiator_peer_id: local_peer_id,
            attempt_id: local_attempt_id,
            started_at: Instant::now(),
            on_superseded: Box::new(move |_winner_peer_id, _winner_attempt_id| {
                superseded_cb.store(true, Ordering::SeqCst);
            }),
        });
        assert_eq!(decision, RegisterDecision::Accepted);

        let incoming = arbiter.evaluate_incoming(
            pair_key,
            remote_peer_id,
            remote_attempt_id,
            local_peer_id,
            remote_peer_id,
            local_peer_id,
        );
        assert!(matches!(
            incoming,
            IncomingDecision::AcceptAndSupersedeLocal { .. }
        ));
        assert!(superseded.load(Ordering::SeqCst));

        arbiter.clear_outgoing(pair_key, None);
        arbiter.clear_established(pair_key);
    }
}
