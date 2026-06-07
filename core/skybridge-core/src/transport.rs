use sha2::{Digest, Sha256};

/// Platform family advertised by a SkyBridge peer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerPlatform {
    Apple,
    Windows,
    Unknown,
}

impl PeerPlatform {
    pub fn is_apple(self) -> bool {
        matches!(self, Self::Apple)
    }

    pub fn is_windows(self) -> bool {
        matches!(self, Self::Windows)
    }
}

/// Core-owned transport kinds. Concrete libraries are adapters behind these values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkyBridgeTransportKind {
    AppleNative,
    WindowsNativeMsQuic,
    SkyBridgeIceMsQuic,
    WebRtcDataChannel,
    Relay,
    TcpFallback,
}

/// Logical channels are scheduled by Core, then mapped by each transport adapter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkyBridgeChannel {
    Control,
    File,
    Clipboard,
    Telemetry,
    Realtime,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkyBridgeReliability {
    ReliableOrdered,
    ReliableUnordered,
    PartialReliable { max_retransmits: u16 },
    Unreliable,
}

impl SkyBridgeChannel {
    pub fn default_reliability(self) -> SkyBridgeReliability {
        match self {
            Self::Control | Self::File | Self::Clipboard => SkyBridgeReliability::ReliableOrdered,
            Self::Telemetry => SkyBridgeReliability::ReliableUnordered,
            Self::Realtime => SkyBridgeReliability::PartialReliable { max_retransmits: 1 },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PeerCapabilities {
    pub platform: PeerPlatform,
    pub supports_apple_native: bool,
    pub supports_msquic: bool,
    pub supports_skybridge_ice_msquic: bool,
    pub supports_webrtc_data_channel: bool,
    pub supports_tcp_fallback: bool,
    pub supports_relay: bool,
}

impl PeerCapabilities {
    pub fn apple() -> Self {
        Self {
            platform: PeerPlatform::Apple,
            supports_apple_native: true,
            supports_msquic: false,
            supports_skybridge_ice_msquic: false,
            supports_webrtc_data_channel: true,
            supports_tcp_fallback: true,
            supports_relay: true,
        }
    }

    pub fn windows() -> Self {
        Self {
            platform: PeerPlatform::Windows,
            supports_apple_native: false,
            supports_msquic: true,
            supports_skybridge_ice_msquic: false,
            supports_webrtc_data_channel: true,
            supports_tcp_fallback: true,
            supports_relay: true,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NetworkPath {
    pub same_lan: bool,
    pub cross_nat: bool,
}

impl NetworkPath {
    pub fn same_lan() -> Self {
        Self {
            same_lan: true,
            cross_nat: false,
        }
    }

    pub fn cross_nat() -> Self {
        Self {
            same_lan: false,
            cross_nat: true,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayPolicy {
    NotNeeded,
    Allowed,
    Required,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportAuditReason {
    AppleNativeDefault,
    WindowsNativeMsQuicSameLan,
    WindowsSkyBridgeIceMsQuic,
    WebRtcInterop,
    TcpFallbackSameLan,
    RelayFallback,
    UnsupportedNoCompatibleTransport,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TransportPlan {
    pub kind: Option<SkyBridgeTransportKind>,
    pub priority: u8,
    pub relay_policy: RelayPolicy,
    pub audit_reason: TransportAuditReason,
}

impl TransportPlan {
    pub fn unsupported() -> Self {
        Self {
            kind: None,
            priority: 0,
            relay_policy: RelayPolicy::NotNeeded,
            audit_reason: TransportAuditReason::UnsupportedNoCompatibleTransport,
        }
    }

    pub fn is_supported(self) -> bool {
        self.kind.is_some()
    }
}

pub struct TransportSelector;

impl TransportSelector {
    pub fn select(
        local: PeerCapabilities,
        remote: PeerCapabilities,
        path: NetworkPath,
    ) -> TransportPlan {
        if local.platform.is_apple()
            && remote.platform.is_apple()
            && local.supports_apple_native
            && remote.supports_apple_native
        {
            return TransportPlan {
                kind: Some(SkyBridgeTransportKind::AppleNative),
                priority: 100,
                relay_policy: RelayPolicy::NotNeeded,
                audit_reason: TransportAuditReason::AppleNativeDefault,
            };
        }

        if local.platform.is_windows()
            && remote.platform.is_windows()
            && path.same_lan
            && local.supports_msquic
            && remote.supports_msquic
        {
            return TransportPlan {
                kind: Some(SkyBridgeTransportKind::WindowsNativeMsQuic),
                priority: 100,
                relay_policy: RelayPolicy::NotNeeded,
                audit_reason: TransportAuditReason::WindowsNativeMsQuicSameLan,
            };
        }

        if local.platform.is_windows()
            && remote.platform.is_windows()
            && local.supports_skybridge_ice_msquic
            && remote.supports_skybridge_ice_msquic
        {
            return TransportPlan {
                kind: Some(SkyBridgeTransportKind::SkyBridgeIceMsQuic),
                priority: 90,
                relay_policy: RelayPolicy::Allowed,
                audit_reason: TransportAuditReason::WindowsSkyBridgeIceMsQuic,
            };
        }

        if local.supports_webrtc_data_channel && remote.supports_webrtc_data_channel {
            return TransportPlan {
                kind: Some(SkyBridgeTransportKind::WebRtcDataChannel),
                priority: 70,
                relay_policy: if path.cross_nat {
                    RelayPolicy::Allowed
                } else {
                    RelayPolicy::NotNeeded
                },
                audit_reason: TransportAuditReason::WebRtcInterop,
            };
        }

        if path.same_lan && local.supports_tcp_fallback && remote.supports_tcp_fallback {
            return TransportPlan {
                kind: Some(SkyBridgeTransportKind::TcpFallback),
                priority: 40,
                relay_policy: RelayPolicy::NotNeeded,
                audit_reason: TransportAuditReason::TcpFallbackSameLan,
            };
        }

        if local.supports_relay && remote.supports_relay {
            return TransportPlan {
                kind: Some(SkyBridgeTransportKind::Relay),
                priority: 10,
                relay_policy: RelayPolicy::Required,
                audit_reason: TransportAuditReason::RelayFallback,
            };
        }

        TransportPlan::unsupported()
    }
}

/// Core transcript material that binds the selected adapter to the SkyBridge session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportBindingMaterial {
    pub transport_kind: SkyBridgeTransportKind,
    pub local_endpoint: String,
    pub remote_endpoint: String,
    pub selected_candidate_pair: String,
    pub transport_secret_fingerprint: Vec<u8>,
    pub relay_id: Option<String>,
    pub timestamp_window_ms: u64,
    pub capability_digest: Vec<u8>,
}

impl TransportBindingMaterial {
    pub fn transcript_digest(&self) -> [u8; 32] {
        let mut hasher = Sha256::new();
        hasher.update(format!("{:?}", self.transport_kind).as_bytes());
        hasher.update(self.local_endpoint.as_bytes());
        hasher.update(self.remote_endpoint.as_bytes());
        hasher.update(self.selected_candidate_pair.as_bytes());
        hasher.update(&self.transport_secret_fingerprint);
        if let Some(relay_id) = &self.relay_id {
            hasher.update(relay_id.as_bytes());
        }
        hasher.update(self.timestamp_window_ms.to_be_bytes());
        hasher.update(&self.capability_digest);
        hasher.finalize().into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apple_peers_keep_native_transport_ahead_of_webrtc() {
        let local = PeerCapabilities::apple();
        let remote = PeerCapabilities::apple();

        let plan = TransportSelector::select(local, remote, NetworkPath::same_lan());

        assert_eq!(plan.kind, Some(SkyBridgeTransportKind::AppleNative));
        assert_eq!(plan.priority, 100);
        assert_eq!(plan.audit_reason, TransportAuditReason::AppleNativeDefault);
    }

    #[test]
    fn windows_same_lan_prefers_msquic_over_webrtc() {
        let local = PeerCapabilities::windows();
        let remote = PeerCapabilities::windows();

        let plan = TransportSelector::select(local, remote, NetworkPath::same_lan());

        assert_eq!(plan.kind, Some(SkyBridgeTransportKind::WindowsNativeMsQuic));
        assert_eq!(
            plan.audit_reason,
            TransportAuditReason::WindowsNativeMsQuicSameLan
        );
    }

    #[test]
    fn windows_to_apple_selects_webrtc_interop() {
        let local = PeerCapabilities::windows();
        let remote = PeerCapabilities::apple();

        let plan = TransportSelector::select(local, remote, NetworkPath::cross_nat());

        assert_eq!(plan.kind, Some(SkyBridgeTransportKind::WebRtcDataChannel));
        assert_eq!(plan.priority, 70);
        assert_eq!(plan.relay_policy, RelayPolicy::Allowed);
    }

    #[test]
    fn unsupported_when_no_capabilities_overlap() {
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

        let plan = TransportSelector::select(local, remote, NetworkPath::cross_nat());

        assert!(!plan.is_supported());
        assert_eq!(
            plan.audit_reason,
            TransportAuditReason::UnsupportedNoCompatibleTransport
        );
    }

    #[test]
    fn logical_channels_have_expected_default_reliability() {
        assert_eq!(
            SkyBridgeChannel::Control.default_reliability(),
            SkyBridgeReliability::ReliableOrdered
        );
        assert_eq!(
            SkyBridgeChannel::File.default_reliability(),
            SkyBridgeReliability::ReliableOrdered
        );
        assert_eq!(
            SkyBridgeChannel::Telemetry.default_reliability(),
            SkyBridgeReliability::ReliableUnordered
        );
        assert_eq!(
            SkyBridgeChannel::Realtime.default_reliability(),
            SkyBridgeReliability::PartialReliable { max_retransmits: 1 }
        );
    }

    #[test]
    fn transport_binding_digest_changes_when_adapter_changes() {
        let base = TransportBindingMaterial {
            transport_kind: SkyBridgeTransportKind::WebRtcDataChannel,
            local_endpoint: "10.0.0.1:443".into(),
            remote_endpoint: "10.0.0.2:443".into(),
            selected_candidate_pair: "host/udp".into(),
            transport_secret_fingerprint: vec![1, 2, 3, 4],
            relay_id: None,
            timestamp_window_ms: 10_000,
            capability_digest: vec![9, 8, 7, 6],
        };
        let mut changed = base.clone();
        changed.transport_kind = SkyBridgeTransportKind::Relay;
        changed.relay_id = Some("turn-a".into());

        assert_ne!(base.transcript_digest(), changed.transcript_digest());
    }
}
