use crate::error::{CoreError, CoreResult};
use crate::suite::{CryptoSuite, CryptoSuiteAudit};
use crate::transport::{
    SkyBridgeChannel, SkyBridgeReliability, SkyBridgeTransportKind, TransportAuditReason,
};
use std::sync::Mutex;

/// Represents runtime state of a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Disconnected,
    Connecting,
    Connected,
    Reconnecting,
    ShuttingDown,
}

/// Thread-safe state machine guarding engine lifecycle transitions.
#[derive(Debug)]
pub struct SessionStateMachine {
    state: Mutex<SessionState>,
}

impl SessionStateMachine {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(SessionState::Disconnected),
        }
    }

    /// Returns the current session state.
    pub fn current(&self) -> SessionState {
        *self.state.lock().unwrap()
    }

    /// Attempts a state transition using an explicit table of allowed predecessors.
    pub fn transition(&self, next: SessionState) -> CoreResult<()> {
        let allowed = Self::allowed_predecessors(next);
        let mut guard = self.state.lock().unwrap();
        let current = *guard;

        if !allowed.contains(&current) {
            return Err(CoreError::InvalidState {
                expected: Self::describe_expected(allowed),
                actual: current,
            });
        }

        *guard = next;
        Ok(())
    }

    fn allowed_predecessors(target: SessionState) -> &'static [SessionState] {
        match target {
            SessionState::Disconnected => &[
                SessionState::ShuttingDown,
                SessionState::Connecting,
                SessionState::Reconnecting,
                SessionState::Connected,
                SessionState::Disconnected,
            ],
            SessionState::Connecting => &[SessionState::Disconnected],
            SessionState::Connected => &[SessionState::Connecting, SessionState::Reconnecting],
            SessionState::Reconnecting => &[SessionState::Connected],
            SessionState::ShuttingDown => &[
                SessionState::Connected,
                SessionState::Reconnecting,
                SessionState::Connecting,
                SessionState::Disconnected,
            ],
        }
    }

    fn describe_expected(states: &[SessionState]) -> String {
        states
            .iter()
            .map(|state| match state {
                SessionState::Disconnected => "Disconnected",
                SessionState::Connecting => "Connecting",
                SessionState::Connected => "Connected",
                SessionState::Reconnecting => "Reconnecting",
                SessionState::ShuttingDown => "ShuttingDown",
            })
            .collect::<Vec<_>>()
            .join("|")
    }
}

impl Default for SessionStateMachine {
    fn default() -> Self {
        Self::new()
    }
}

/// Configuration for establishing a new session.
#[derive(Debug, Clone)]
pub struct SessionConfig {
    pub client_id: String,
    pub heartbeat_interval_ms: u64,
    pub peer_public_key: Option<Vec<u8>>,
    pub transport_binding: Option<SessionTransportBinding>,
}

impl SessionConfig {
    pub fn validate(&self) -> CoreResult<()> {
        if self.client_id.trim().is_empty() {
            return Err(CoreError::InvalidConfig {
                reason: "client_id is required".into(),
            });
        }

        if self.heartbeat_interval_ms == 0 {
            return Err(CoreError::InvalidConfig {
                reason: "heartbeat interval must be greater than zero".into(),
            });
        }

        if let Some(key) = &self.peer_public_key {
            if key.is_empty() {
                return Err(CoreError::InvalidConfig {
                    reason: "peer public key must not be empty".into(),
                });
            }
        }

        if let Some(binding) = &self.transport_binding {
            binding.validate()?;
        }

        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionTransportBinding {
    pub transport: SkyBridgeTransportKind,
    pub transport_audit: TransportAuditReason,
    pub relay_required: bool,
    pub relay_allowed: bool,
    pub selected_suite: CryptoSuite,
    pub selected_suite_wire_id: u16,
    pub suite_audit: CryptoSuiteAudit,
    pub sbp2_enabled: bool,
    pub sbp2_fixed_payload_len: usize,
    pub frame_header_len: usize,
    pub transport_binding_digest: [u8; 32],
    pub adapter_kind: SkyBridgeTransportKind,
    pub adapter_binding: String,
    pub local_endpoint: String,
    pub remote_endpoint: String,
    pub selected_candidate_pair: String,
    pub relay_id: Option<String>,
    pub timestamp_window_ms: u64,
    pub channel_mappings: Vec<SessionChannelBinding>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionAdapterBindingKind {
    AppleStream,
    AppleDatagram,
    MsQuicStream,
    MsQuicDatagram,
    WebRtcDataChannel,
    RelayStream,
    TcpStream,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionChannelBinding {
    pub channel: SkyBridgeChannel,
    pub reliability: SkyBridgeReliability,
    pub max_retransmits: u16,
    pub binding_kind: SessionAdapterBindingKind,
    pub head_of_line_isolated: bool,
}

impl SessionTransportBinding {
    pub fn validate(&self) -> CoreResult<()> {
        if self.selected_suite_wire_id == 0 {
            return Err(CoreError::InvalidConfig {
                reason: "selected suite wire id is required".into(),
            });
        }

        if self.frame_header_len == 0 {
            return Err(CoreError::InvalidConfig {
                reason: "frame header length is required".into(),
            });
        }

        if self.sbp2_enabled && self.sbp2_fixed_payload_len == 0 {
            return Err(CoreError::InvalidConfig {
                reason: "SBP2 fixed payload length is required when SBP2 is enabled".into(),
            });
        }

        if self.adapter_binding.trim().is_empty() {
            return Err(CoreError::InvalidConfig {
                reason: "adapter binding is required".into(),
            });
        }

        if self.local_endpoint.trim().is_empty() {
            return Err(CoreError::InvalidConfig {
                reason: "local endpoint is required".into(),
            });
        }

        if self.remote_endpoint.trim().is_empty() {
            return Err(CoreError::InvalidConfig {
                reason: "remote endpoint is required".into(),
            });
        }

        if self.selected_candidate_pair.trim().is_empty() {
            return Err(CoreError::InvalidConfig {
                reason: "selected candidate pair is required".into(),
            });
        }

        if self.timestamp_window_ms == 0 {
            return Err(CoreError::InvalidConfig {
                reason: "transport timestamp window must be greater than zero".into(),
            });
        }

        if self.channel_mappings.len() != 5 {
            return Err(CoreError::InvalidConfig {
                reason: "transport channel mappings must include all five Core channels".into(),
            });
        }

        let mut seen = [false; 5];
        for mapping in &self.channel_mappings {
            let index = channel_index(mapping.channel);
            if seen[index] {
                return Err(CoreError::InvalidConfig {
                    reason: "transport channel mappings must not contain duplicate channels".into(),
                });
            }
            seen[index] = true;
        }

        Ok(())
    }
}

fn channel_index(channel: SkyBridgeChannel) -> usize {
    match channel {
        SkyBridgeChannel::Control => 0,
        SkyBridgeChannel::File => 1,
        SkyBridgeChannel::Clipboard => 2,
        SkyBridgeChannel::Telemetry => 3,
        SkyBridgeChannel::Realtime => 4,
    }
}

/// Trait to be implemented by session managers.
#[async_trait::async_trait(?Send)]
pub trait AsyncSessionManager {
    async fn establish_async(&self, config: SessionConfig) -> CoreResult<()>;
    async fn reconnect_async(&self) -> CoreResult<()>;
    async fn terminate_async(&self);
    fn state(&self) -> SessionState;
}

/// Heartbeat hook for the platform layer.
#[async_trait::async_trait(?Send)]
pub trait HeartbeatEmitter {
    async fn emit(&self) -> CoreResult<()>;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_channel_mappings() -> Vec<SessionChannelBinding> {
        vec![
            SessionChannelBinding {
                channel: SkyBridgeChannel::Control,
                reliability: SkyBridgeReliability::ReliableOrdered,
                max_retransmits: 0,
                binding_kind: SessionAdapterBindingKind::WebRtcDataChannel,
                head_of_line_isolated: true,
            },
            SessionChannelBinding {
                channel: SkyBridgeChannel::File,
                reliability: SkyBridgeReliability::ReliableOrdered,
                max_retransmits: 0,
                binding_kind: SessionAdapterBindingKind::WebRtcDataChannel,
                head_of_line_isolated: true,
            },
            SessionChannelBinding {
                channel: SkyBridgeChannel::Clipboard,
                reliability: SkyBridgeReliability::ReliableOrdered,
                max_retransmits: 0,
                binding_kind: SessionAdapterBindingKind::WebRtcDataChannel,
                head_of_line_isolated: true,
            },
            SessionChannelBinding {
                channel: SkyBridgeChannel::Telemetry,
                reliability: SkyBridgeReliability::ReliableUnordered,
                max_retransmits: 0,
                binding_kind: SessionAdapterBindingKind::WebRtcDataChannel,
                head_of_line_isolated: true,
            },
            SessionChannelBinding {
                channel: SkyBridgeChannel::Realtime,
                reliability: SkyBridgeReliability::PartialReliable { max_retransmits: 1 },
                max_retransmits: 1,
                binding_kind: SessionAdapterBindingKind::WebRtcDataChannel,
                head_of_line_isolated: true,
            },
        ]
    }

    #[test]
    fn transition_table_allows_happy_path() {
        let machine = SessionStateMachine::new();
        machine.transition(SessionState::Connecting).unwrap();
        assert_eq!(machine.current(), SessionState::Connecting);
        machine.transition(SessionState::Connected).unwrap();
        assert_eq!(machine.current(), SessionState::Connected);
        machine.transition(SessionState::Reconnecting).unwrap();
        machine.transition(SessionState::Connected).unwrap();
        machine.transition(SessionState::ShuttingDown).unwrap();
        machine.transition(SessionState::Disconnected).unwrap();
        assert_eq!(machine.current(), SessionState::Disconnected);
    }

    #[test]
    fn invalid_transition_reports_expected_states() {
        let machine = SessionStateMachine::new();
        let err = machine
            .transition(SessionState::Connected)
            .expect_err("cannot connect directly from disconnected");

        match err {
            CoreError::InvalidState { expected, actual } => {
                assert_eq!(actual, SessionState::Disconnected);
                assert_eq!(expected, "Connecting|Reconnecting");
            }
            other => panic!("unexpected error: {:?}", other),
        }
    }

    #[test]
    fn config_validation_rejects_bad_inputs() {
        let empty_id = SessionConfig {
            client_id: "   ".into(),
            heartbeat_interval_ms: 1,
            peer_public_key: None,
            transport_binding: None,
        };
        let err = empty_id.validate().unwrap_err();
        assert!(matches!(err, CoreError::InvalidConfig { .. }));

        let zero_heartbeat = SessionConfig {
            client_id: "id".into(),
            heartbeat_interval_ms: 0,
            peer_public_key: None,
            transport_binding: None,
        };
        let err = zero_heartbeat.validate().unwrap_err();
        assert!(matches!(err, CoreError::InvalidConfig { .. }));

        let empty_key = SessionConfig {
            client_id: "id".into(),
            heartbeat_interval_ms: 10,
            peer_public_key: Some(Vec::new()),
            transport_binding: None,
        };
        let err = empty_key.validate().unwrap_err();
        assert!(matches!(err, CoreError::InvalidConfig { .. }));

        let bad_transport_binding = SessionConfig {
            client_id: "id".into(),
            heartbeat_interval_ms: 10,
            peer_public_key: None,
            transport_binding: Some(SessionTransportBinding {
                transport: SkyBridgeTransportKind::WebRtcDataChannel,
                transport_audit: TransportAuditReason::WebRtcInterop,
                relay_required: false,
                relay_allowed: true,
                selected_suite: CryptoSuite::XWingHybrid,
                selected_suite_wire_id: 0,
                suite_audit: CryptoSuiteAudit::HybridPqcPreferred,
                sbp2_enabled: true,
                sbp2_fixed_payload_len: 512,
                frame_header_len: 16,
                transport_binding_digest: [0x42; 32],
                adapter_kind: SkyBridgeTransportKind::WebRtcDataChannel,
                adapter_binding: "external webrtc".into(),
                local_endpoint: "windows.example:5443".into(),
                remote_endpoint: "mac.example:5443".into(),
                selected_candidate_pair: "webrtc/dtls/sctp-selected".into(),
                relay_id: None,
                timestamp_window_ms: 10_000,
                channel_mappings: valid_channel_mappings(),
            }),
        };
        let err = bad_transport_binding.validate().unwrap_err();
        assert!(matches!(err, CoreError::InvalidConfig { .. }));
    }
}
