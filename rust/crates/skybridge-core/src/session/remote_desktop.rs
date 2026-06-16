use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RemoteDesktopControlAction {
    Start,
    Stop,
    SetResolution,
    SetFps,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RemoteDesktopControlRequestStatus {
    #[serde(rename = "pending_agent_observation", alias = "pending_agent_ack")]
    PendingAgentObservation,
    #[serde(rename = "agent_observed", alias = "agent_acked")]
    AgentObserved,
    AgentRejected,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RemoteDesktopResolutionRequest {
    Auto,
    Preset { id: String, width: u16, height: u16 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct RemoteDesktopResolutionPreset {
    pub id: &'static str,
    pub width: Option<u16>,
    pub height: Option<u16>,
    pub note: &'static str,
}

pub const REMOTE_DESKTOP_FPS_REQUEST_CONTRACT: &[u16] = &[30, 60, 120];

pub const REMOTE_DESKTOP_RESOLUTION_REQUEST_CONTRACT: &[RemoteDesktopResolutionPreset] = &[
    RemoteDesktopResolutionPreset {
        id: "auto",
        width: None,
        height: None,
        note: "defer to sender policy after live control is implemented",
    },
    RemoteDesktopResolutionPreset {
        id: "1280x720",
        width: Some(1280),
        height: Some(720),
        note: "low-bandwidth diagnostic target",
    },
    RemoteDesktopResolutionPreset {
        id: "1920x1080",
        width: Some(1920),
        height: Some(1080),
        note: "baseline desktop remote-control target",
    },
    RemoteDesktopResolutionPreset {
        id: "2056x1329",
        width: Some(2056),
        height: Some(1329),
        note: "current iPad P2P remote evidence target",
    },
    RemoteDesktopResolutionPreset {
        id: "2560x1440",
        width: Some(2560),
        height: Some(1440),
        note: "high-detail desktop target pending sender mode confirmation",
    },
];

pub fn remote_desktop_resolution_preset_matches(id: &str, width: u16, height: u16) -> bool {
    REMOTE_DESKTOP_RESOLUTION_REQUEST_CONTRACT
        .iter()
        .any(|preset| {
            preset.id == id && preset.width == Some(width) && preset.height == Some(height)
        })
}

pub fn remote_desktop_fps_request_supported(fps: u16) -> bool {
    REMOTE_DESKTOP_FPS_REQUEST_CONTRACT.contains(&fps)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteDesktopObservedMode {
    pub id: String,
    pub width: u16,
    pub height: u16,
    pub fps: u16,
}

impl RemoteDesktopObservedMode {
    pub fn new(id: impl Into<String>, width: u16, height: u16, fps: u16) -> Self {
        Self {
            id: id.into(),
            width,
            height,
            fps,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteDesktopCapabilitySnapshot {
    pub schema_version: u32,
    pub session_id: String,
    pub target_runtime_id: String,
    pub sender_modes: Vec<RemoteDesktopObservedMode>,
    #[serde(default)]
    pub display_modes: Vec<RemoteDesktopObservedMode>,
    #[serde(with = "time::serde::rfc3339")]
    pub observed_at: OffsetDateTime,
    #[serde(
        default = "expired_remote_desktop_capability_time",
        with = "time::serde::rfc3339"
    )]
    pub expires_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

impl RemoteDesktopCapabilitySnapshot {
    pub const SCHEMA_VERSION: u32 = 1;

    pub fn new(
        session_id: impl Into<String>,
        target_runtime_id: impl Into<String>,
        sender_modes: Vec<RemoteDesktopObservedMode>,
        display_modes: Vec<RemoteDesktopObservedMode>,
    ) -> Self {
        let now = OffsetDateTime::now_utc();
        Self {
            schema_version: Self::SCHEMA_VERSION,
            session_id: session_id.into(),
            target_runtime_id: target_runtime_id.into(),
            sender_modes,
            display_modes,
            observed_at: now,
            expires_at: now + time::Duration::seconds(300),
            updated_at: now,
        }
    }

    pub fn is_fresh_at(&self, now: OffsetDateTime) -> bool {
        self.expires_at > now
    }
}

fn expired_remote_desktop_capability_time() -> OffsetDateTime {
    OffsetDateTime::UNIX_EPOCH
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteDesktopCapabilitySnapshotRegistry {
    pub schema_version: u32,
    pub snapshots: BTreeMap<String, RemoteDesktopCapabilitySnapshot>,
}

impl Default for RemoteDesktopCapabilitySnapshotRegistry {
    fn default() -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            snapshots: BTreeMap::new(),
        }
    }
}

impl RemoteDesktopCapabilitySnapshotRegistry {
    pub const SCHEMA_VERSION: u32 = 1;
    pub const MAX_SNAPSHOTS: usize = 128;

    pub fn insert(&mut self, snapshot: RemoteDesktopCapabilitySnapshot) {
        self.snapshots.insert(snapshot.session_id.clone(), snapshot);
        self.prune_to_limit();
    }

    pub fn get_for_session(&self, session_id: &str) -> Option<&RemoteDesktopCapabilitySnapshot> {
        self.snapshots.get(session_id)
    }

    pub fn values_sorted(&self) -> Vec<RemoteDesktopCapabilitySnapshot> {
        let mut values = self.snapshots.values().cloned().collect::<Vec<_>>();
        values.sort_by_key(|snapshot| std::cmp::Reverse(snapshot.updated_at));
        values
    }

    fn prune_to_limit(&mut self) {
        let overflow = self.snapshots.len().saturating_sub(Self::MAX_SNAPSHOTS);
        if overflow == 0 {
            return;
        }

        let mut oldest_keys = self
            .snapshots
            .values()
            .map(|snapshot| (snapshot.updated_at, snapshot.session_id.clone()))
            .collect::<Vec<_>>();
        oldest_keys.sort_by(|left, right| left.0.cmp(&right.0).then_with(|| left.1.cmp(&right.1)));
        for (_, key) in oldest_keys.into_iter().take(overflow) {
            self.snapshots.remove(&key);
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct RemoteDesktopControlRequestPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<RemoteDesktopResolutionRequest>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fps: Option<u16>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteDesktopControlRequest {
    pub schema_version: u32,
    pub request_id: String,
    pub session_id: String,
    pub target_runtime_id: String,
    pub action: RemoteDesktopControlAction,
    pub payload: RemoteDesktopControlRequestPayload,
    pub status: RemoteDesktopControlRequestStatus,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

impl RemoteDesktopControlRequest {
    pub const SCHEMA_VERSION: u32 = 1;

    pub fn pending(
        request_id: impl Into<String>,
        session_id: impl Into<String>,
        target_runtime_id: impl Into<String>,
        action: RemoteDesktopControlAction,
        payload: RemoteDesktopControlRequestPayload,
    ) -> Self {
        let now = OffsetDateTime::now_utc();
        Self {
            schema_version: Self::SCHEMA_VERSION,
            request_id: request_id.into(),
            session_id: session_id.into(),
            target_runtime_id: target_runtime_id.into(),
            action,
            payload,
            status: RemoteDesktopControlRequestStatus::PendingAgentObservation,
            created_at: now,
            updated_at: now,
        }
    }

    pub fn is_pending_agent_observation(&self) -> bool {
        self.status == RemoteDesktopControlRequestStatus::PendingAgentObservation
    }

    pub fn is_agent_observed(&self) -> bool {
        self.status == RemoteDesktopControlRequestStatus::AgentObserved
    }

    pub fn mark_agent_observed(&mut self, now: OffsetDateTime) {
        self.status = RemoteDesktopControlRequestStatus::AgentObserved;
        self.updated_at = now;
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteDesktopControlRequestRegistry {
    pub schema_version: u32,
    #[serde(default)]
    pub requests: BTreeMap<String, RemoteDesktopControlRequest>,
}

impl Default for RemoteDesktopControlRequestRegistry {
    fn default() -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            requests: BTreeMap::new(),
        }
    }
}

impl RemoteDesktopControlRequestRegistry {
    pub const SCHEMA_VERSION: u32 = 1;
    pub const MAX_REQUESTS: usize = 128;

    pub fn insert(&mut self, request: RemoteDesktopControlRequest) {
        self.requests.insert(request.request_id.clone(), request);
        self.prune_to_limit();
    }

    pub fn get(&self, request_id: &str) -> Option<&RemoteDesktopControlRequest> {
        self.requests.get(request_id)
    }

    pub fn pending_for_session(&self, session_id: &str) -> Vec<&RemoteDesktopControlRequest> {
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

    pub fn values_sorted(&self) -> Vec<RemoteDesktopControlRequest> {
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
    fn remote_desktop_control_request_registry_tracks_pending_by_session() {
        let mut registry = RemoteDesktopControlRequestRegistry::default();
        let request = RemoteDesktopControlRequest::pending(
            "request-1",
            "session-1",
            "runtime-1",
            RemoteDesktopControlAction::Start,
            RemoteDesktopControlRequestPayload {
                resolution: Some(RemoteDesktopResolutionRequest::Preset {
                    id: "1920x1080".to_owned(),
                    width: 1920,
                    height: 1080,
                }),
                fps: Some(60),
            },
        );
        registry.insert(request);

        let pending = registry.pending_for_session("session-1");
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].request_id, "request-1");
        assert!(pending[0].is_pending_agent_observation());

        let pending_ids = registry.pending_ids_for_session_runtime("session-1", "runtime-1");
        assert_eq!(pending_ids, vec!["request-1".to_owned()]);

        let mut observed = registry
            .requests
            .get("request-1")
            .cloned()
            .expect("request should exist");
        observed.mark_agent_observed(OffsetDateTime::now_utc());
        assert!(observed.is_agent_observed());
        assert!(!observed.is_pending_agent_observation());
        registry.insert(observed);
        assert!(registry.pending_for_session("session-1").is_empty());
        assert!(
            registry
                .pending_ids_for_session_runtime("session-1", "runtime-1")
                .is_empty()
        );

        let serialized = serde_json::to_string(&registry).expect("registry should serialize");
        assert!(serialized.contains("\"target_runtime_id\":\"runtime-1\""));
        assert!(!serialized.contains("signaling_session_token"));
        assert!(!serialized.contains("turn_credentials"));
    }

    #[test]
    fn remote_desktop_request_contract_is_shared_by_cli_and_agent() {
        assert!(remote_desktop_fps_request_supported(30));
        assert!(remote_desktop_fps_request_supported(60));
        assert!(remote_desktop_fps_request_supported(120));
        assert!(!remote_desktop_fps_request_supported(75));
        assert!(remote_desktop_resolution_preset_matches(
            "1920x1080",
            1920,
            1080
        ));
        assert!(!remote_desktop_resolution_preset_matches(
            "1920x1080",
            1280,
            720
        ));
        assert!(
            REMOTE_DESKTOP_RESOLUTION_REQUEST_CONTRACT
                .iter()
                .any(|preset| preset.id == "auto"
                    && preset.width.is_none()
                    && preset.height.is_none())
        );
    }

    #[test]
    fn remote_desktop_capability_snapshot_registry_tracks_observed_sender_modes() {
        let mut registry = RemoteDesktopCapabilitySnapshotRegistry::default();
        let snapshot = RemoteDesktopCapabilitySnapshot::new(
            "session-1",
            "runtime-1",
            vec![RemoteDesktopObservedMode::new(
                "1920x1080@60",
                1920,
                1080,
                60,
            )],
            vec![RemoteDesktopObservedMode::new(
                "display-main",
                2056,
                1329,
                60,
            )],
        );
        registry.insert(snapshot);

        let session_snapshot = registry
            .get_for_session("session-1")
            .expect("snapshot should be indexed by session id");
        assert_eq!(session_snapshot.target_runtime_id, "runtime-1");
        assert_eq!(session_snapshot.sender_modes[0].width, 1920);
        assert_eq!(session_snapshot.sender_modes[0].fps, 60);
        assert!(session_snapshot.expires_at > session_snapshot.observed_at);
        assert!(session_snapshot.is_fresh_at(session_snapshot.observed_at));

        let serialized = serde_json::to_string(&registry).expect("registry should serialize");
        assert!(serialized.contains("\"schema_version\":1"));
        assert!(serialized.contains("\"sender_modes\""));
        assert!(serialized.contains("\"expires_at\""));
        assert!(!serialized.contains("turn_credentials"));
        assert!(!serialized.contains("signaling_session_token"));
    }

    #[test]
    fn remote_desktop_capability_snapshot_legacy_payload_defaults_to_expired() {
        let payload = serde_json::json!({
            "schema_version": 1,
            "session_id": "session-legacy",
            "target_runtime_id": "runtime-legacy",
            "sender_modes": [
                {
                    "id": "1920x1080@60",
                    "width": 1920,
                    "height": 1080,
                    "fps": 60
                }
            ],
            "display_modes": [],
            "observed_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z"
        });
        let snapshot: RemoteDesktopCapabilitySnapshot =
            serde_json::from_value(payload).expect("legacy snapshot should deserialize");

        assert_eq!(snapshot.expires_at, OffsetDateTime::UNIX_EPOCH);
        assert!(!snapshot.is_fresh_at(OffsetDateTime::now_utc()));
    }

    #[test]
    fn remote_desktop_registries_prune_oldest_entries_to_declared_limits() {
        let mut capability_registry = RemoteDesktopCapabilitySnapshotRegistry::default();
        let base = OffsetDateTime::now_utc() - time::Duration::hours(1);
        for index in 0..(RemoteDesktopCapabilitySnapshotRegistry::MAX_SNAPSHOTS + 2) {
            let mut snapshot = RemoteDesktopCapabilitySnapshot::new(
                format!("session-{index:03}"),
                format!("runtime-{index:03}"),
                vec![RemoteDesktopObservedMode::new(
                    format!("mode-{index:03}"),
                    1920,
                    1080,
                    60,
                )],
                vec![],
            );
            snapshot.updated_at = base + time::Duration::seconds(index as i64);
            capability_registry.insert(snapshot);
        }
        assert_eq!(
            capability_registry.snapshots.len(),
            RemoteDesktopCapabilitySnapshotRegistry::MAX_SNAPSHOTS
        );
        assert!(capability_registry.get_for_session("session-000").is_none());
        assert!(capability_registry.get_for_session("session-001").is_none());
        assert!(capability_registry.get_for_session("session-002").is_some());

        let mut request_registry = RemoteDesktopControlRequestRegistry::default();
        for index in 0..(RemoteDesktopControlRequestRegistry::MAX_REQUESTS + 2) {
            let mut request = RemoteDesktopControlRequest::pending(
                format!("request-{index:03}"),
                "session-1",
                "runtime-1",
                RemoteDesktopControlAction::Start,
                RemoteDesktopControlRequestPayload::default(),
            );
            request.updated_at = base + time::Duration::seconds(index as i64);
            request_registry.insert(request);
        }
        assert_eq!(
            request_registry.requests.len(),
            RemoteDesktopControlRequestRegistry::MAX_REQUESTS
        );
        assert!(request_registry.get("request-000").is_none());
        assert!(request_registry.get("request-001").is_none());
        assert!(request_registry.get("request-002").is_some());
    }
}
