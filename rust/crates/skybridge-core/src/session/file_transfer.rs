use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FileTransferControlAction {
    Send,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FileTransferControlRequestStatus {
    #[serde(rename = "pending_agent_observation", alias = "pending_agent_ack")]
    PendingAgentObservation,
    #[serde(rename = "agent_observed", alias = "agent_acked")]
    AgentObserved,
    /// The agent has begun the live chunked transfer over the data channel.
    TransferInProgress,
    /// The transfer finished and the receiver's SHA-256 receipt matched.
    TransferCompleted,
    /// The transfer was started but did not close with a verified receipt.
    TransferFailed,
    AgentRejected,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileTransferSourceSnapshot {
    pub source_path: String,
    pub size_bytes: u64,
    pub sha256_hex: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileTransferDestinationBinding {
    pub requested_peer_ref: String,
    pub remote_device_id: String,
    pub remote_protocol_public_key_fingerprint: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileTransferControlRequest {
    pub schema_version: u32,
    pub request_id: String,
    pub session_id: String,
    pub target_runtime_id: String,
    pub action: FileTransferControlAction,
    pub source: FileTransferSourceSnapshot,
    pub destination: FileTransferDestinationBinding,
    pub status: FileTransferControlRequestStatus,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
    /// Live transfer evidence (all additive + serde-defaulted for back-compat).
    /// These are the only basis on which any "success" is ever claimed.
    #[serde(default, with = "time::serde::rfc3339::option")]
    pub transfer_started_at: Option<OffsetDateTime>,
    #[serde(default)]
    pub bytes_transferred: u64,
    #[serde(default)]
    pub receipt_verified: bool,
    /// Whether the receiver's computed SHA-256 matched the source snapshot.
    #[serde(default)]
    pub receipt_sha256_match: bool,
    #[serde(default, with = "time::serde::rfc3339::option")]
    pub transfer_completed_at: Option<OffsetDateTime>,
    /// Generic failure reason (never carries path / peer / digest material).
    #[serde(default)]
    pub failure_reason: Option<String>,
}

impl FileTransferControlRequest {
    pub const SCHEMA_VERSION: u32 = 1;

    pub fn pending_send(
        request_id: impl Into<String>,
        session_id: impl Into<String>,
        target_runtime_id: impl Into<String>,
        source: FileTransferSourceSnapshot,
        destination: FileTransferDestinationBinding,
    ) -> Self {
        let now = OffsetDateTime::now_utc();
        Self {
            schema_version: Self::SCHEMA_VERSION,
            request_id: request_id.into(),
            session_id: session_id.into(),
            target_runtime_id: target_runtime_id.into(),
            action: FileTransferControlAction::Send,
            source,
            destination,
            status: FileTransferControlRequestStatus::PendingAgentObservation,
            created_at: now,
            updated_at: now,
            transfer_started_at: None,
            bytes_transferred: 0,
            receipt_verified: false,
            receipt_sha256_match: false,
            transfer_completed_at: None,
            failure_reason: None,
        }
    }

    pub fn is_pending_agent_observation(&self) -> bool {
        self.status == FileTransferControlRequestStatus::PendingAgentObservation
    }

    pub fn is_agent_observed(&self) -> bool {
        self.status == FileTransferControlRequestStatus::AgentObserved
    }

    pub fn is_transfer_in_progress(&self) -> bool {
        self.status == FileTransferControlRequestStatus::TransferInProgress
    }

    pub fn is_transfer_completed(&self) -> bool {
        self.status == FileTransferControlRequestStatus::TransferCompleted
    }

    pub fn is_transfer_failed(&self) -> bool {
        self.status == FileTransferControlRequestStatus::TransferFailed
    }

    pub fn mark_agent_observed(&mut self, now: OffsetDateTime) {
        self.status = FileTransferControlRequestStatus::AgentObserved;
        self.updated_at = now;
    }

    pub fn mark_transfer_started(&mut self, now: OffsetDateTime) {
        self.status = FileTransferControlRequestStatus::TransferInProgress;
        self.transfer_started_at = Some(now);
        self.bytes_transferred = 0;
        self.updated_at = now;
    }

    pub fn record_bytes_transferred(&mut self, bytes_transferred: u64, now: OffsetDateTime) {
        self.bytes_transferred = bytes_transferred;
        self.updated_at = now;
    }

    pub fn mark_transfer_completed(&mut self, bytes_transferred: u64, now: OffsetDateTime) {
        self.status = FileTransferControlRequestStatus::TransferCompleted;
        self.bytes_transferred = bytes_transferred;
        self.receipt_verified = true;
        self.receipt_sha256_match = true;
        self.transfer_completed_at = Some(now);
        self.failure_reason = None;
        self.updated_at = now;
    }

    pub fn mark_transfer_failed(&mut self, reason: impl Into<String>, now: OffsetDateTime) {
        self.status = FileTransferControlRequestStatus::TransferFailed;
        self.receipt_verified = false;
        self.failure_reason = Some(reason.into());
        self.updated_at = now;
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileTransferControlRequestRegistry {
    pub schema_version: u32,
    #[serde(default)]
    pub requests: BTreeMap<String, FileTransferControlRequest>,
}

impl Default for FileTransferControlRequestRegistry {
    fn default() -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            requests: BTreeMap::new(),
        }
    }
}

impl FileTransferControlRequestRegistry {
    pub const SCHEMA_VERSION: u32 = 1;
    pub const MAX_REQUESTS: usize = 128;

    pub fn insert(&mut self, request: FileTransferControlRequest) {
        self.requests.insert(request.request_id.clone(), request);
        self.prune_to_limit();
    }

    pub fn get(&self, request_id: &str) -> Option<&FileTransferControlRequest> {
        self.requests.get(request_id)
    }

    pub fn pending_for_session(&self, session_id: &str) -> Vec<&FileTransferControlRequest> {
        let mut requests = self
            .requests
            .values()
            .filter(|request| {
                request.session_id == session_id && request.is_pending_agent_observation()
            })
            .collect::<Vec<_>>();
        requests.sort_by_key(|request| std::cmp::Reverse(request.updated_at));
        requests
    }

    pub fn pending_ids_for_session_runtime(
        &self,
        session_id: &str,
        target_runtime_id: &str,
    ) -> Vec<String> {
        let mut requests = self
            .requests
            .values()
            .filter(|request| {
                request.session_id == session_id
                    && request.target_runtime_id == target_runtime_id
                    && request.is_pending_agent_observation()
            })
            .collect::<Vec<_>>();
        requests.sort_by_key(|request| std::cmp::Reverse(request.updated_at));
        requests
            .into_iter()
            .map(|request| request.request_id.clone())
            .collect()
    }

    pub fn values_sorted(&self) -> Vec<FileTransferControlRequest> {
        let mut values = self.requests.values().cloned().collect::<Vec<_>>();
        values.sort_by_key(|request| std::cmp::Reverse(request.updated_at));
        values
    }

    fn prune_to_limit(&mut self) {
        let overflow = self.requests.len().saturating_sub(Self::MAX_REQUESTS);
        if overflow == 0 {
            return;
        }

        let mut oldest_keys = self
            .requests
            .values()
            .map(|request| (request.updated_at, request.request_id.clone()))
            .collect::<Vec<_>>();
        oldest_keys.sort_by(|left, right| left.0.cmp(&right.0).then_with(|| left.1.cmp(&right.1)));
        for (_, key) in oldest_keys.into_iter().take(overflow) {
            self.requests.remove(&key);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_transfer_request_registry_tracks_pending_send_by_session() {
        let mut registry = FileTransferControlRequestRegistry::default();
        let request = FileTransferControlRequest::pending_send(
            "request-1",
            "session-1",
            "runtime-1",
            FileTransferSourceSnapshot {
                source_path: "/private/source.bin".to_owned(),
                size_bytes: 42,
                sha256_hex: "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"
                    .to_owned(),
            },
            FileTransferDestinationBinding {
                requested_peer_ref: "remote-device".to_owned(),
                remote_device_id: "remote-device".to_owned(),
                remote_protocol_public_key_fingerprint: "fingerprint".to_owned(),
            },
        );
        registry.insert(request);

        let pending = registry.pending_for_session("session-1");
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].request_id, "request-1");
        assert!(pending[0].is_pending_agent_observation());
        assert_eq!(
            registry.pending_ids_for_session_runtime("session-1", "runtime-1"),
            vec!["request-1".to_owned()]
        );

        let now = OffsetDateTime::now_utc();
        registry
            .requests
            .get_mut("request-1")
            .expect("request should exist")
            .mark_agent_observed(now);
        let observed = registry.get("request-1").expect("request should exist");
        assert!(observed.is_agent_observed());
        assert!(!observed.is_pending_agent_observation());
        assert_eq!(observed.updated_at, now);
        assert!(registry.pending_for_session("session-1").is_empty());
        assert!(
            registry
                .pending_ids_for_session_runtime("session-1", "runtime-1")
                .is_empty()
        );

        let serialized = serde_json::to_string(&registry).expect("registry should serialize");
        assert!(serialized.contains("\"target_runtime_id\":\"runtime-1\""));
        assert!(serialized.contains("\"sha256_hex\""));
        assert!(!serialized.contains("signaling_session_token"));
        assert!(!serialized.contains("turn_credentials"));
    }

    #[test]
    fn transfer_transitions_track_evidence() {
        let mut request = FileTransferControlRequest::pending_send(
            "request-1",
            "session-1",
            "runtime-1",
            FileTransferSourceSnapshot {
                source_path: "/private/source.bin".to_owned(),
                size_bytes: 10,
                sha256_hex: "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"
                    .to_owned(),
            },
            FileTransferDestinationBinding {
                requested_peer_ref: "remote-device".to_owned(),
                remote_device_id: "remote-device".to_owned(),
                remote_protocol_public_key_fingerprint: "fingerprint".to_owned(),
            },
        );
        let now = OffsetDateTime::now_utc();
        request.mark_agent_observed(now);
        request.mark_transfer_started(now);
        assert!(request.is_transfer_in_progress());
        assert!(request.transfer_started_at.is_some());
        assert!(!request.receipt_verified);

        request.record_bytes_transferred(10, now);
        request.mark_transfer_completed(10, now);
        assert!(request.is_transfer_completed());
        assert!(request.receipt_verified);
        assert!(request.receipt_sha256_match);
        assert_eq!(request.bytes_transferred, 10);
        assert!(request.transfer_completed_at.is_some());

        let mut failing = request.clone();
        failing.mark_transfer_failed("sha256 mismatch", now);
        assert!(failing.is_transfer_failed());
        assert!(!failing.receipt_verified);
        assert_eq!(failing.failure_reason.as_deref(), Some("sha256 mismatch"));
    }

    #[test]
    fn legacy_v1_request_without_evidence_fields_deserializes_with_defaults() {
        // A pre-evidence (schema v1) record on disk must still load.
        let legacy = r#"{
            "schema_version": 1,
            "request_id": "request-1",
            "session_id": "session-1",
            "target_runtime_id": "runtime-1",
            "action": "send",
            "source": {"source_path": "/p/s.bin", "size_bytes": 5,
                "sha256_hex": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"},
            "destination": {"requested_peer_ref": "r", "remote_device_id": "r",
                "remote_protocol_public_key_fingerprint": "f"},
            "status": "agent_observed",
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z"
        }"#;
        let request: FileTransferControlRequest =
            serde_json::from_str(legacy).expect("legacy record should deserialize");
        assert!(request.is_agent_observed());
        assert_eq!(request.bytes_transferred, 0);
        assert!(!request.receipt_verified);
        assert!(request.transfer_started_at.is_none());
        assert!(request.failure_reason.is_none());
    }

    #[test]
    fn file_transfer_request_registry_prunes_oldest_entries_to_declared_limit() {
        let mut registry = FileTransferControlRequestRegistry::default();
        let base = OffsetDateTime::now_utc() - time::Duration::hours(1);
        for index in 0..(FileTransferControlRequestRegistry::MAX_REQUESTS + 2) {
            let mut request = FileTransferControlRequest::pending_send(
                format!("request-{index:03}"),
                "session-1",
                "runtime-1",
                FileTransferSourceSnapshot {
                    source_path: format!("/private/source-{index:03}.bin"),
                    size_bytes: index as u64,
                    sha256_hex: "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"
                        .to_owned(),
                },
                FileTransferDestinationBinding {
                    requested_peer_ref: "remote-device".to_owned(),
                    remote_device_id: "remote-device".to_owned(),
                    remote_protocol_public_key_fingerprint: "fingerprint".to_owned(),
                },
            );
            request.updated_at = base + time::Duration::seconds(index as i64);
            registry.insert(request);
        }

        assert_eq!(
            registry.requests.len(),
            FileTransferControlRequestRegistry::MAX_REQUESTS
        );
        assert!(registry.get("request-000").is_none());
        assert!(registry.get("request-001").is_none());
        assert!(registry.get("request-002").is_some());
    }
}
