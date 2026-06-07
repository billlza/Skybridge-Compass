use crate::channel::{map_all_channels, ChannelMappingError, ChannelProfile};
use crate::frame::FRAME_HEADER_LEN;
use crate::suite::{
    negotiate_suite, offered_suites, CryptoProviderCapabilities, CryptoSuite, CryptoSuitePolicy,
    CryptoSuiteSelectionError, SelectedCryptoSuite,
};
use crate::transport::{
    NetworkPath, PeerCapabilities, SkyBridgeTransportKind, TransportPlan, TransportSelector,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrafficPaddingPlan {
    pub sbp2_enabled: bool,
    pub fixed_payload_len: Option<usize>,
}

impl TrafficPaddingPlan {
    pub const fn disabled() -> Self {
        Self {
            sbp2_enabled: false,
            fixed_payload_len: None,
        }
    }

    pub const fn sbp2_fixed(fixed_payload_len: usize) -> Self {
        Self {
            sbp2_enabled: true,
            fixed_payload_len: Some(fixed_payload_len),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionRequest {
    pub local: PeerCapabilities,
    pub remote: PeerCapabilities,
    pub path: NetworkPath,
    pub local_crypto: CryptoProviderCapabilities,
    pub remote_suite_wire_ids: Vec<u16>,
    pub suite_policy: CryptoSuitePolicy,
    pub traffic_padding: TrafficPaddingPlan,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionPlan {
    pub transport: TransportPlan,
    pub transport_kind: SkyBridgeTransportKind,
    pub offered_suites: Vec<CryptoSuite>,
    pub selected_suite: SelectedCryptoSuite,
    pub channels: Vec<ChannelProfile>,
    pub traffic_padding: TrafficPaddingPlan,
    pub frame_header_len: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionPlanError {
    UnsupportedTransport,
    CryptoSuite(CryptoSuiteSelectionError),
    ChannelMapping(ChannelMappingError),
}

impl From<CryptoSuiteSelectionError> for ConnectionPlanError {
    fn from(value: CryptoSuiteSelectionError) -> Self {
        Self::CryptoSuite(value)
    }
}

impl From<ChannelMappingError> for ConnectionPlanError {
    fn from(value: ChannelMappingError) -> Self {
        Self::ChannelMapping(value)
    }
}

pub fn plan_connection(request: ConnectionRequest) -> Result<ConnectionPlan, ConnectionPlanError> {
    let transport = TransportSelector::select(request.local, request.remote, request.path);
    let transport_kind = transport
        .kind
        .ok_or(ConnectionPlanError::UnsupportedTransport)?;
    let offered = offered_suites(request.local_crypto, request.suite_policy);
    let selected = negotiate_suite(
        request.local_crypto,
        &request.remote_suite_wire_ids,
        request.suite_policy,
    )?;
    let channels = map_all_channels(transport_kind)?;

    Ok(ConnectionPlan {
        transport,
        transport_kind,
        offered_suites: offered,
        selected_suite: selected,
        channels,
        traffic_padding: request.traffic_padding,
        frame_header_len: FRAME_HEADER_LEN,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::channel::AdapterChannelBinding;
    use crate::suite::{CryptoSuite, CryptoSuiteAudit};
    use crate::transport::{PeerCapabilities, PeerPlatform, RelayPolicy, TransportAuditReason};

    fn request(
        local: PeerCapabilities,
        remote: PeerCapabilities,
        path: NetworkPath,
    ) -> ConnectionRequest {
        ConnectionRequest {
            local,
            remote,
            path,
            local_crypto: CryptoProviderCapabilities::research_all(),
            remote_suite_wire_ids: vec![
                CryptoSuite::X25519Ed25519.wire_id(),
                CryptoSuite::MlKem768MlDsa65.wire_id(),
                CryptoSuite::XWingHybrid.wire_id(),
            ],
            suite_policy: CryptoSuitePolicy::compatibility(),
            traffic_padding: TrafficPaddingPlan::sbp2_fixed(512),
        }
    }

    #[test]
    fn windows_to_apple_plan_uses_webrtc_distinct_channels_and_pqc_suite() {
        let plan = plan_connection(request(
            PeerCapabilities::windows(),
            PeerCapabilities::apple(),
            NetworkPath::cross_nat(),
        ))
        .expect("connection plan");

        assert_eq!(
            plan.transport_kind,
            SkyBridgeTransportKind::WebRtcDataChannel
        );
        assert_eq!(
            plan.transport.audit_reason,
            TransportAuditReason::WebRtcInterop
        );
        assert_eq!(plan.transport.relay_policy, RelayPolicy::Allowed);
        assert_eq!(plan.selected_suite.suite, CryptoSuite::XWingHybrid);
        assert_eq!(
            plan.selected_suite.audit,
            CryptoSuiteAudit::HybridPqcPreferred
        );
        assert_eq!(plan.channels.len(), 5);
        assert!(plan.channels.iter().all(|profile| matches!(
            profile.binding,
            AdapterChannelBinding::WebRtcDataChannel { .. }
        )));
        assert!(plan.traffic_padding.sbp2_enabled);
        assert_eq!(plan.traffic_padding.fixed_payload_len, Some(512));
        assert_eq!(plan.frame_header_len, FRAME_HEADER_LEN);
    }

    #[test]
    fn apple_to_apple_plan_keeps_native_transport_not_webrtc() {
        let plan = plan_connection(request(
            PeerCapabilities::apple(),
            PeerCapabilities::apple(),
            NetworkPath::same_lan(),
        ))
        .expect("connection plan");

        assert_eq!(plan.transport_kind, SkyBridgeTransportKind::AppleNative);
        assert_eq!(
            plan.transport.audit_reason,
            TransportAuditReason::AppleNativeDefault
        );
        assert!(plan.channels.iter().all(|profile| !matches!(
            profile.binding,
            AdapterChannelBinding::WebRtcDataChannel { .. }
        )));
    }

    #[test]
    fn unsupported_transport_fails_before_adapter_channel_mapping() {
        let local = PeerCapabilities {
            platform: PeerPlatform::Windows,
            supports_apple_native: false,
            supports_msquic: false,
            supports_skybridge_ice_msquic: false,
            supports_webrtc_data_channel: false,
            supports_tcp_fallback: false,
            supports_relay: false,
        };
        let remote = PeerCapabilities {
            platform: PeerPlatform::Apple,
            supports_apple_native: false,
            supports_msquic: false,
            supports_skybridge_ice_msquic: false,
            supports_webrtc_data_channel: false,
            supports_tcp_fallback: false,
            supports_relay: false,
        };

        let result = plan_connection(request(local, remote, NetworkPath::cross_nat()));

        assert_eq!(result, Err(ConnectionPlanError::UnsupportedTransport));
    }

    #[test]
    fn timeout_does_not_create_classic_connection_plan() {
        let mut request = request(
            PeerCapabilities::windows(),
            PeerCapabilities::apple(),
            NetworkPath::cross_nat(),
        );
        request.local_crypto = CryptoProviderCapabilities {
            supports_xwing_hybrid: false,
            supports_mlkem_768_mldsa_65: false,
            supports_x25519_ed25519: true,
            supports_p256_ecdsa: false,
        };
        request.remote_suite_wire_ids = vec![CryptoSuite::X25519Ed25519.wire_id()];
        request.suite_policy = CryptoSuitePolicy {
            timeout_observed: true,
            ..CryptoSuitePolicy::compatibility()
        };

        let result = plan_connection(request);

        assert_eq!(
            result,
            Err(ConnectionPlanError::CryptoSuite(
                CryptoSuiteSelectionError::TimeoutCannotDowngrade
            ))
        );
    }
}
