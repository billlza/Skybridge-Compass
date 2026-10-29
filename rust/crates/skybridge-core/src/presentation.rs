use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::{CryptoSuite, signaling::SignalingSessionHealth};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionPresentationPhase {
    Disconnected,
    Connecting,
    Connected,
    Reconnecting,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionDisplayState {
    Disconnected,
    Connecting,
    Reconnecting,
    ConnectedClassic,
    ConnectedApplePqc,
    ConnectedDegradedSignaling,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionDisconnectKind {
    Explicit,
    RemoteLeave,
    Transient,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActiveSessionSnapshotSource {
    P2p,
    Qr,
    Code,
    Icloud,
    Reused,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActiveSessionSnapshotPhase {
    Connecting,
    TransportReady,
    HandshakeComplete,
    Reconnecting,
    Disconnecting,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectionPresentationLabels {
    pub connected_text: String,
    pub disconnected_text: String,
    pub connecting_text: String,
    pub reconnecting_text: String,
}

impl Default for ConnectionPresentationLabels {
    fn default() -> Self {
        Self {
            connected_text: "已连接".to_owned(),
            disconnected_text: "未连接".to_owned(),
            connecting_text: "连接中".to_owned(),
            reconnecting_text: "重连中".to_owned(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectionPresentationPeer {
    pub display_name: String,
    pub crypto_kind: Option<String>,
    pub suite: Option<String>,
    pub guard_status: Option<String>,
    #[serde(with = "time::serde::rfc3339")]
    pub connected_at: OffsetDateTime,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActiveSessionSnapshot {
    pub snapshot_token: Uuid,
    pub session_id: String,
    pub source: ActiveSessionSnapshotSource,
    pub phase: ActiveSessionSnapshotPhase,
    pub device_id: Option<String>,
    pub device_name: Option<String>,
    pub negotiated_suite: Option<String>,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectionPresentationInput {
    pub labels: ConnectionPresentationLabels,
    pub file_transfer_active: bool,
    pub latest_peer_connection: Option<ConnectionPresentationPeer>,
    pub latest_connected_device: Option<ConnectionPresentationPeer>,
    pub active_session_snapshot: Option<ActiveSessionSnapshot>,
    pub cross_network_fallback: Option<ActiveSessionSnapshot>,
    pub compatibility_mode_enabled: bool,
    pub signaling_health: Option<SignalingSessionHealth>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectionPresentation {
    pub phase: ConnectionPresentationPhase,
    pub is_connected: bool,
    pub display_state: ConnectionDisplayState,
    pub status_text: String,
    pub detail_text: Option<String>,
}

pub struct ActiveSessionSnapshotContract;

impl ActiveSessionSnapshotContract {
    pub fn activate(
        session_id: impl Into<String>,
        source: ActiveSessionSnapshotSource,
        phase: ActiveSessionSnapshotPhase,
        device_id: Option<String>,
        device_name: Option<String>,
        negotiated_suite: Option<String>,
    ) -> ActiveSessionSnapshot {
        ActiveSessionSnapshot {
            snapshot_token: Uuid::now_v7(),
            session_id: session_id.into(),
            source,
            phase,
            device_id,
            device_name,
            negotiated_suite,
            updated_at: OffsetDateTime::now_utc(),
        }
    }

    pub fn update(
        current: Option<&ActiveSessionSnapshot>,
        session_id: &str,
        snapshot_token: Uuid,
        phase: ActiveSessionSnapshotPhase,
        device_id: Option<String>,
        device_name: Option<String>,
        negotiated_suite: Option<String>,
    ) -> Option<ActiveSessionSnapshot> {
        let current = current?;
        if current.session_id != session_id || current.snapshot_token != snapshot_token {
            return Some(current.clone());
        }

        Some(ActiveSessionSnapshot {
            snapshot_token: current.snapshot_token,
            session_id: current.session_id.clone(),
            source: current.source,
            phase,
            device_id: device_id.or_else(|| current.device_id.clone()),
            device_name: device_name.or_else(|| current.device_name.clone()),
            negotiated_suite: negotiated_suite.or_else(|| current.negotiated_suite.clone()),
            updated_at: OffsetDateTime::now_utc(),
        })
    }

    pub fn disconnect(
        current: Option<&ActiveSessionSnapshot>,
        session_id: &str,
        snapshot_token: Uuid,
        kind: SessionDisconnectKind,
    ) -> Option<ActiveSessionSnapshot> {
        let current = current?;
        if current.session_id != session_id || current.snapshot_token != snapshot_token {
            return Some(current.clone());
        }

        match kind {
            SessionDisconnectKind::Explicit | SessionDisconnectKind::RemoteLeave => None,
            SessionDisconnectKind::Transient => Some(ActiveSessionSnapshot {
                snapshot_token: current.snapshot_token,
                session_id: current.session_id.clone(),
                source: current.source,
                phase: ActiveSessionSnapshotPhase::Reconnecting,
                device_id: current.device_id.clone(),
                device_name: current.device_name.clone(),
                negotiated_suite: current.negotiated_suite.clone(),
                updated_at: OffsetDateTime::now_utc(),
            }),
        }
    }
}

pub struct ConnectionPresentationContract;

impl ConnectionPresentationContract {
    pub fn evaluate(input: &ConnectionPresentationInput) -> ConnectionPresentation {
        let snapshot = input
            .active_session_snapshot
            .as_ref()
            .or(input.cross_network_fallback.as_ref());

        match snapshot {
            Some(snapshot) => Self::from_snapshot(input, snapshot),
            None => ConnectionPresentation {
                phase: ConnectionPresentationPhase::Disconnected,
                is_connected: false,
                display_state: ConnectionDisplayState::Disconnected,
                status_text: input.labels.disconnected_text.clone(),
                detail_text: None,
            },
        }
    }

    fn from_snapshot(
        input: &ConnectionPresentationInput,
        snapshot: &ActiveSessionSnapshot,
    ) -> ConnectionPresentation {
        let degraded = matches!(
            input.signaling_health,
            Some(
                SignalingSessionHealth::DegradedRecoverable | SignalingSessionHealth::DegradedFatal
            )
        );
        let detail = snapshot
            .device_name
            .clone()
            .or_else(|| snapshot.negotiated_suite.clone());

        match snapshot.phase {
            ActiveSessionSnapshotPhase::Connecting => ConnectionPresentation {
                phase: ConnectionPresentationPhase::Connecting,
                is_connected: false,
                display_state: ConnectionDisplayState::Connecting,
                status_text: input.labels.connecting_text.clone(),
                detail_text: detail,
            },
            ActiveSessionSnapshotPhase::Reconnecting => ConnectionPresentation {
                phase: ConnectionPresentationPhase::Reconnecting,
                is_connected: false,
                display_state: ConnectionDisplayState::Reconnecting,
                status_text: input.labels.reconnecting_text.clone(),
                detail_text: detail,
            },
            ActiveSessionSnapshotPhase::TransportReady
            | ActiveSessionSnapshotPhase::HandshakeComplete => {
                let display_state = if degraded {
                    ConnectionDisplayState::ConnectedDegradedSignaling
                } else if Self::is_pqc_suite(snapshot.negotiated_suite.as_deref()) {
                    ConnectionDisplayState::ConnectedApplePqc
                } else {
                    ConnectionDisplayState::ConnectedClassic
                };
                let detail_text = if degraded {
                    Some(match detail {
                        Some(detail) => format!("{detail} · 信令降级"),
                        None => "信令降级".to_owned(),
                    })
                } else {
                    detail
                };

                ConnectionPresentation {
                    phase: ConnectionPresentationPhase::Connected,
                    is_connected: true,
                    display_state,
                    status_text: input.labels.connected_text.clone(),
                    detail_text,
                }
            }
            ActiveSessionSnapshotPhase::Disconnecting => ConnectionPresentation {
                phase: ConnectionPresentationPhase::Disconnected,
                is_connected: false,
                display_state: ConnectionDisplayState::Disconnected,
                status_text: input.labels.disconnected_text.clone(),
                detail_text: detail,
            },
        }
    }

    fn is_pqc_suite(suite: Option<&str>) -> bool {
        suite.is_some_and(|suite| {
            CryptoSuite::from_name(suite)
                .map(CryptoSuite::is_pqc)
                .unwrap_or_else(|| {
                    let normalized = suite.to_ascii_lowercase();
                    normalized.contains("ml-")
                        || normalized.contains("apple")
                        || normalized.contains("x-wing")
                        || normalized.contains("pqc")
                })
        })
    }
}
