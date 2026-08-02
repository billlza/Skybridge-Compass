use std::collections::BTreeMap;

use anyhow::{Result, bail};
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InboundFileTransferApprovalDecision {
    Approve,
    Reject,
    Expire,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InboundFileTransferApprovalStatus {
    PendingDecision,
    DecisionRequested,
    AgentApplied,
    AgentFailed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InboundFileTransferApprovalBinding {
    pub transfer_id: String,
    pub session_id: String,
    pub target_runtime_id: String,
    pub authenticated_peer_device_id: String,
    pub authenticated_peer_device_name: String,
    pub authenticated_peer_protocol_fingerprint: String,
    pub metadata_sha256_hex: String,
    pub file_name: String,
    pub file_size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboundFileTransferApprovalRequest {
    pub schema_version: u32,
    pub transfer_id: String,
    pub session_id: String,
    pub target_runtime_id: String,
    pub authenticated_peer_device_id: String,
    pub authenticated_peer_device_name: String,
    pub authenticated_peer_protocol_fingerprint: String,
    pub metadata_sha256_hex: String,
    pub file_name: String,
    pub file_size: u64,
    pub status: InboundFileTransferApprovalStatus,
    pub decision: Option<InboundFileTransferApprovalDecision>,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
    #[serde(default, with = "time::serde::rfc3339::option")]
    pub applied_at: Option<OffsetDateTime>,
    #[serde(default)]
    pub failure_reason: Option<String>,
}

impl InboundFileTransferApprovalRequest {
    pub const SCHEMA_VERSION: u32 = 1;

    pub fn pending(binding: InboundFileTransferApprovalBinding, now: OffsetDateTime) -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            transfer_id: binding.transfer_id,
            session_id: binding.session_id,
            target_runtime_id: binding.target_runtime_id,
            authenticated_peer_device_id: binding.authenticated_peer_device_id,
            authenticated_peer_device_name: binding.authenticated_peer_device_name,
            authenticated_peer_protocol_fingerprint: binding
                .authenticated_peer_protocol_fingerprint,
            metadata_sha256_hex: binding.metadata_sha256_hex,
            file_name: binding.file_name,
            file_size: binding.file_size,
            status: InboundFileTransferApprovalStatus::PendingDecision,
            decision: None,
            created_at: now,
            updated_at: now,
            applied_at: None,
            failure_reason: None,
        }
    }

    pub fn request_decision(
        &mut self,
        decision: InboundFileTransferApprovalDecision,
        now: OffsetDateTime,
    ) -> Result<()> {
        if self.status != InboundFileTransferApprovalStatus::PendingDecision {
            bail!("inbound file-transfer approval is not pending a decision");
        }
        self.status = InboundFileTransferApprovalStatus::DecisionRequested;
        self.decision = Some(decision);
        self.updated_at = now;
        Ok(())
    }

    pub fn mark_applied(&mut self, now: OffsetDateTime) -> Result<()> {
        if self.status != InboundFileTransferApprovalStatus::DecisionRequested
            || self.decision.is_none()
        {
            bail!("inbound file-transfer decision is not ready to apply");
        }
        self.status = InboundFileTransferApprovalStatus::AgentApplied;
        self.applied_at = Some(now);
        self.failure_reason = None;
        self.updated_at = now;
        Ok(())
    }

    pub fn mark_failed(&mut self, reason: impl Into<String>, now: OffsetDateTime) -> Result<()> {
        if self.status != InboundFileTransferApprovalStatus::DecisionRequested {
            bail!("inbound file-transfer decision is not ready to fail");
        }
        self.status = InboundFileTransferApprovalStatus::AgentFailed;
        self.failure_reason = Some(reason.into());
        self.updated_at = now;
        Ok(())
    }

    pub fn is_terminal(&self) -> bool {
        matches!(
            self.status,
            InboundFileTransferApprovalStatus::AgentApplied
                | InboundFileTransferApprovalStatus::AgentFailed
        )
    }

    pub fn registry_key(&self) -> String {
        format!(
            "{}:{}{}:{}{}:{}",
            self.session_id.len(),
            self.session_id,
            self.target_runtime_id.len(),
            self.target_runtime_id,
            self.transfer_id.len(),
            self.transfer_id
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboundFileTransferApprovalRegistry {
    pub schema_version: u32,
    #[serde(default)]
    pub requests: BTreeMap<String, InboundFileTransferApprovalRequest>,
}

impl Default for InboundFileTransferApprovalRegistry {
    fn default() -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            requests: BTreeMap::new(),
        }
    }
}

impl InboundFileTransferApprovalRegistry {
    pub const SCHEMA_VERSION: u32 = 1;
    pub const MAX_REQUESTS: usize = 128;

    pub fn insert(&mut self, request: InboundFileTransferApprovalRequest) -> Result<()> {
        let registry_key = request.registry_key();
        if !self.requests.contains_key(&registry_key) {
            while self.requests.len() >= Self::MAX_REQUESTS {
                let Some(oldest_terminal_key) = self
                    .requests
                    .iter()
                    .filter(|(_, existing)| existing.is_terminal())
                    .min_by(|(left_key, left), (right_key, right)| {
                        left.updated_at
                            .cmp(&right.updated_at)
                            .then_with(|| left_key.cmp(right_key))
                    })
                    .map(|(key, _)| key.clone())
                else {
                    bail!(
                        "inbound file-transfer approval registry is full with nonterminal requests"
                    );
                };
                self.requests.remove(&oldest_terminal_key);
            }
        }
        self.requests.insert(registry_key, request);
        Ok(())
    }

    pub fn values_sorted(&self) -> Vec<InboundFileTransferApprovalRequest> {
        let mut values = self.requests.values().cloned().collect::<Vec<_>>();
        values.sort_by_key(|request| std::cmp::Reverse(request.updated_at));
        values
    }
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
        matches!(
            self.status,
            FileTransferControlRequestStatus::AgentObserved
                | FileTransferControlRequestStatus::TransferInProgress
                | FileTransferControlRequestStatus::TransferCompleted
                | FileTransferControlRequestStatus::TransferFailed
        )
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

    pub fn is_terminal(&self) -> bool {
        matches!(
            self.status,
            FileTransferControlRequestStatus::TransferCompleted
                | FileTransferControlRequestStatus::TransferFailed
                | FileTransferControlRequestStatus::AgentRejected
        )
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

    pub fn insert(&mut self, request: FileTransferControlRequest) -> Result<()> {
        let request_id = request.request_id.clone();
        if !self.requests.contains_key(&request_id) {
            while self.requests.len() >= Self::MAX_REQUESTS {
                let Some(oldest_terminal_id) = self
                    .requests
                    .values()
                    .filter(|existing| existing.is_terminal())
                    .min_by(|left, right| {
                        left.updated_at
                            .cmp(&right.updated_at)
                            .then_with(|| left.request_id.cmp(&right.request_id))
                    })
                    .map(|existing| existing.request_id.clone())
                else {
                    bail!("file transfer request registry is full with nonterminal requests");
                };
                self.requests.remove(&oldest_terminal_id);
            }
        }
        self.requests.insert(request_id, request);
        Ok(())
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
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inbound_binding(index: u128, runtime_id: String) -> InboundFileTransferApprovalBinding {
        InboundFileTransferApprovalBinding {
            transfer_id: uuid::Uuid::from_u128(index + 1).hyphenated().to_string(),
            session_id: "session-approval".to_owned(),
            target_runtime_id: runtime_id,
            authenticated_peer_device_id: "peer-device".to_owned(),
            authenticated_peer_device_name: "Peer".to_owned(),
            authenticated_peer_protocol_fingerprint: "fingerprint".to_owned(),
            metadata_sha256_hex: "11".repeat(32),
            file_name: "payload.bin".to_owned(),
            file_size: 4,
        }
    }

    #[test]
    fn inbound_approval_registry_evicts_terminal_composite_key_at_capacity() {
        let now = OffsetDateTime::now_utc();
        let mut registry = InboundFileTransferApprovalRegistry::default();
        for index in 0..InboundFileTransferApprovalRegistry::MAX_REQUESTS as u128 {
            let mut request = InboundFileTransferApprovalRequest::pending(
                inbound_binding(index, format!("runtime-{index}")),
                now,
            );
            request
                .request_decision(InboundFileTransferApprovalDecision::Expire, now)
                .expect("request expiry");
            request.mark_applied(now).expect("apply expiry");
            registry.insert(request).expect("insert terminal approval");
        }
        let replacement = InboundFileTransferApprovalRequest::pending(
            inbound_binding(10_000, "runtime-current".to_owned()),
            now,
        );
        let replacement_key = replacement.registry_key();
        registry
            .insert(replacement)
            .expect("bounded insertion must evict one terminal composite key");
        assert_eq!(
            registry.requests.len(),
            InboundFileTransferApprovalRegistry::MAX_REQUESTS
        );
        assert!(registry.requests.contains_key(&replacement_key));
    }

    #[test]
    fn inbound_approval_composite_key_separates_runtime_incarnations() {
        let now = OffsetDateTime::now_utc();
        let first = InboundFileTransferApprovalRequest::pending(
            inbound_binding(7, "runtime-a".to_owned()),
            now,
        );
        let second = InboundFileTransferApprovalRequest::pending(
            inbound_binding(7, "runtime-b".to_owned()),
            now,
        );
        assert_ne!(first.registry_key(), second.registry_key());
        let mut registry = InboundFileTransferApprovalRegistry::default();
        registry.insert(first).expect("insert first runtime");
        registry.insert(second).expect("insert second runtime");
        assert_eq!(registry.requests.len(), 2);
    }

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
        registry.insert(request).expect("insert pending request");

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
        assert!(request.is_agent_observed());
        assert!(request.transfer_started_at.is_some());
        assert!(!request.receipt_verified);

        request.record_bytes_transferred(10, now);
        request.mark_transfer_completed(10, now);
        assert!(request.is_transfer_completed());
        assert!(request.is_agent_observed());
        assert!(request.receipt_verified);
        assert!(request.receipt_sha256_match);
        assert_eq!(request.bytes_transferred, 10);
        assert!(request.transfer_completed_at.is_some());

        let mut failing = request.clone();
        failing.mark_transfer_failed("sha256 mismatch", now);
        assert!(failing.is_transfer_failed());
        assert!(failing.is_agent_observed());
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
    fn file_transfer_request_registry_prunes_only_oldest_terminal_entries() {
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
            request.mark_transfer_failed("terminal history", request.updated_at);
            registry
                .insert(request)
                .expect("terminal history should remain bounded");
        }

        assert_eq!(
            registry.requests.len(),
            FileTransferControlRequestRegistry::MAX_REQUESTS
        );
        assert!(registry.get("request-000").is_none());
        assert!(registry.get("request-001").is_none());
        assert!(registry.get("request-002").is_some());
    }

    #[test]
    fn file_transfer_request_registry_rejects_insert_when_all_entries_are_nonterminal() {
        let mut registry = FileTransferControlRequestRegistry::default();
        for index in 0..FileTransferControlRequestRegistry::MAX_REQUESTS {
            registry
                .insert(FileTransferControlRequest::pending_send(
                    format!("request-{index:03}"),
                    "session-1",
                    "runtime-1",
                    FileTransferSourceSnapshot {
                        source_path: format!("/private/source-{index:03}.bin"),
                        size_bytes: 0,
                        sha256_hex:
                            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                                .to_owned(),
                    },
                    FileTransferDestinationBinding {
                        requested_peer_ref: "remote-device".to_owned(),
                        remote_device_id: "remote-device".to_owned(),
                        remote_protocol_public_key_fingerprint: "fingerprint".to_owned(),
                    },
                ))
                .expect("fill active registry");
        }
        let before = registry.clone();
        let error = registry
            .insert(FileTransferControlRequest::pending_send(
                "overflow",
                "session-2",
                "runtime-2",
                FileTransferSourceSnapshot {
                    source_path: "/private/overflow.bin".to_owned(),
                    size_bytes: 0,
                    sha256_hex: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                        .to_owned(),
                },
                FileTransferDestinationBinding {
                    requested_peer_ref: "remote-device".to_owned(),
                    remote_device_id: "remote-device".to_owned(),
                    remote_protocol_public_key_fingerprint: "fingerprint".to_owned(),
                },
            ))
            .expect_err("all-active registry must reject without eviction");
        assert!(error.to_string().contains("nonterminal"));
        assert_eq!(registry, before);
    }
}
