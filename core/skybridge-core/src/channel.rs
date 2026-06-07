use crate::transport::{SkyBridgeChannel, SkyBridgeReliability, SkyBridgeTransportKind};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdapterChannelBinding {
    AppleStream { name: &'static str },
    AppleDatagram { name: &'static str },
    MsQuicStream { name: &'static str },
    MsQuicDatagram { name: &'static str },
    WebRtcDataChannel { label: &'static str },
    RelayStream { name: &'static str },
    TcpStream { name: &'static str },
}

impl AdapterChannelBinding {
    pub fn label(&self) -> &'static str {
        match self {
            Self::AppleStream { name }
            | Self::AppleDatagram { name }
            | Self::MsQuicStream { name }
            | Self::MsQuicDatagram { name }
            | Self::RelayStream { name }
            | Self::TcpStream { name } => name,
            Self::WebRtcDataChannel { label } => label,
        }
    }

    pub fn isolates_head_of_line_blocking(&self) -> bool {
        !matches!(self, Self::TcpStream { .. })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelProfile {
    pub channel: SkyBridgeChannel,
    pub reliability: SkyBridgeReliability,
    pub binding: AdapterChannelBinding,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelMappingError {
    UnsupportedTransport,
}

pub fn map_channel(
    transport: SkyBridgeTransportKind,
    channel: SkyBridgeChannel,
) -> Result<ChannelProfile, ChannelMappingError> {
    let reliability = channel.default_reliability();
    let binding = match transport {
        SkyBridgeTransportKind::AppleNative => map_apple_native(channel),
        SkyBridgeTransportKind::WindowsNativeMsQuic
        | SkyBridgeTransportKind::SkyBridgeIceMsQuic => map_msquic(channel),
        SkyBridgeTransportKind::WebRtcDataChannel => map_webrtc(channel),
        SkyBridgeTransportKind::Relay => map_relay(channel),
        SkyBridgeTransportKind::TcpFallback => map_tcp_fallback(channel),
    };

    Ok(ChannelProfile {
        channel,
        reliability,
        binding,
    })
}

pub fn map_all_channels(
    transport: SkyBridgeTransportKind,
) -> Result<Vec<ChannelProfile>, ChannelMappingError> {
    all_channels()
        .into_iter()
        .map(|channel| map_channel(transport, channel))
        .collect()
}

pub fn all_channels() -> [SkyBridgeChannel; 5] {
    [
        SkyBridgeChannel::Control,
        SkyBridgeChannel::File,
        SkyBridgeChannel::Clipboard,
        SkyBridgeChannel::Telemetry,
        SkyBridgeChannel::Realtime,
    ]
}

fn map_apple_native(channel: SkyBridgeChannel) -> AdapterChannelBinding {
    match channel {
        SkyBridgeChannel::Control => AdapterChannelBinding::AppleStream {
            name: "skybridge.control",
        },
        SkyBridgeChannel::File => AdapterChannelBinding::AppleStream {
            name: "skybridge.file",
        },
        SkyBridgeChannel::Clipboard => AdapterChannelBinding::AppleStream {
            name: "skybridge.clipboard",
        },
        SkyBridgeChannel::Telemetry => AdapterChannelBinding::AppleDatagram {
            name: "skybridge.telemetry",
        },
        SkyBridgeChannel::Realtime => AdapterChannelBinding::AppleDatagram {
            name: "skybridge.realtime",
        },
    }
}

fn map_msquic(channel: SkyBridgeChannel) -> AdapterChannelBinding {
    match channel {
        SkyBridgeChannel::Control => AdapterChannelBinding::MsQuicStream {
            name: "skybridge.control",
        },
        SkyBridgeChannel::File => AdapterChannelBinding::MsQuicStream {
            name: "skybridge.file",
        },
        SkyBridgeChannel::Clipboard => AdapterChannelBinding::MsQuicStream {
            name: "skybridge.clipboard",
        },
        SkyBridgeChannel::Telemetry => AdapterChannelBinding::MsQuicDatagram {
            name: "skybridge.telemetry",
        },
        SkyBridgeChannel::Realtime => AdapterChannelBinding::MsQuicDatagram {
            name: "skybridge.realtime",
        },
    }
}

fn map_webrtc(channel: SkyBridgeChannel) -> AdapterChannelBinding {
    match channel {
        SkyBridgeChannel::Control => AdapterChannelBinding::WebRtcDataChannel {
            label: "skybridge.control",
        },
        SkyBridgeChannel::File => AdapterChannelBinding::WebRtcDataChannel {
            label: "skybridge.file",
        },
        SkyBridgeChannel::Clipboard => AdapterChannelBinding::WebRtcDataChannel {
            label: "skybridge.clipboard",
        },
        SkyBridgeChannel::Telemetry => AdapterChannelBinding::WebRtcDataChannel {
            label: "skybridge.telemetry",
        },
        SkyBridgeChannel::Realtime => AdapterChannelBinding::WebRtcDataChannel {
            label: "skybridge.realtime",
        },
    }
}

fn map_relay(channel: SkyBridgeChannel) -> AdapterChannelBinding {
    match channel {
        SkyBridgeChannel::Control => AdapterChannelBinding::RelayStream {
            name: "skybridge.control",
        },
        SkyBridgeChannel::File => AdapterChannelBinding::RelayStream {
            name: "skybridge.file",
        },
        SkyBridgeChannel::Clipboard => AdapterChannelBinding::RelayStream {
            name: "skybridge.clipboard",
        },
        SkyBridgeChannel::Telemetry => AdapterChannelBinding::RelayStream {
            name: "skybridge.telemetry",
        },
        SkyBridgeChannel::Realtime => AdapterChannelBinding::RelayStream {
            name: "skybridge.realtime",
        },
    }
}

fn map_tcp_fallback(channel: SkyBridgeChannel) -> AdapterChannelBinding {
    match channel {
        SkyBridgeChannel::Control => AdapterChannelBinding::TcpStream {
            name: "skybridge.control",
        },
        SkyBridgeChannel::File => AdapterChannelBinding::TcpStream {
            name: "skybridge.file",
        },
        SkyBridgeChannel::Clipboard => AdapterChannelBinding::TcpStream {
            name: "skybridge.clipboard",
        },
        SkyBridgeChannel::Telemetry => AdapterChannelBinding::TcpStream {
            name: "skybridge.telemetry",
        },
        SkyBridgeChannel::Realtime => AdapterChannelBinding::TcpStream {
            name: "skybridge.realtime",
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn webrtc_maps_every_logical_channel_to_distinct_datachannels() {
        let profiles = map_all_channels(SkyBridgeTransportKind::WebRtcDataChannel).unwrap();
        let labels = profiles
            .iter()
            .map(|profile| profile.binding.label())
            .collect::<HashSet<_>>();

        assert_eq!(profiles.len(), 5);
        assert_eq!(labels.len(), 5);
        assert!(labels.contains("skybridge.control"));
        assert!(labels.contains("skybridge.file"));
        assert!(labels.contains("skybridge.telemetry"));
    }

    #[test]
    fn windows_msquic_uses_streams_for_ordered_work_and_datagrams_for_latency_sensitive_work() {
        assert_eq!(
            map_channel(
                SkyBridgeTransportKind::WindowsNativeMsQuic,
                SkyBridgeChannel::Control
            )
            .unwrap()
            .binding,
            AdapterChannelBinding::MsQuicStream {
                name: "skybridge.control"
            }
        );
        assert_eq!(
            map_channel(
                SkyBridgeTransportKind::WindowsNativeMsQuic,
                SkyBridgeChannel::Telemetry
            )
            .unwrap()
            .binding,
            AdapterChannelBinding::MsQuicDatagram {
                name: "skybridge.telemetry"
            }
        );
        assert_eq!(
            map_channel(
                SkyBridgeTransportKind::WindowsNativeMsQuic,
                SkyBridgeChannel::Realtime
            )
            .unwrap()
            .reliability,
            SkyBridgeReliability::PartialReliable { max_retransmits: 1 }
        );
    }

    #[test]
    fn apple_native_keeps_same_core_channel_names_without_using_webrtc() {
        let profiles = map_all_channels(SkyBridgeTransportKind::AppleNative).unwrap();
        assert!(profiles.iter().all(|profile| !matches!(
            profile.binding,
            AdapterChannelBinding::WebRtcDataChannel { .. }
        )));
        assert_eq!(profiles[0].binding.label(), "skybridge.control");
    }

    #[test]
    fn tcp_fallback_is_marked_as_not_head_of_line_isolated() {
        let profile = map_channel(SkyBridgeTransportKind::TcpFallback, SkyBridgeChannel::File)
            .expect("profile");

        assert!(!profile.binding.isolates_head_of_line_blocking());
    }

    #[test]
    fn every_transport_maps_every_core_channel_name() {
        let transports = [
            SkyBridgeTransportKind::AppleNative,
            SkyBridgeTransportKind::WindowsNativeMsQuic,
            SkyBridgeTransportKind::SkyBridgeIceMsQuic,
            SkyBridgeTransportKind::WebRtcDataChannel,
            SkyBridgeTransportKind::Relay,
            SkyBridgeTransportKind::TcpFallback,
        ];
        let expected = [
            "skybridge.control",
            "skybridge.file",
            "skybridge.clipboard",
            "skybridge.telemetry",
            "skybridge.realtime",
        ];

        for transport in transports {
            let labels = map_all_channels(transport)
                .unwrap()
                .into_iter()
                .map(|profile| profile.binding.label())
                .collect::<Vec<_>>();
            assert_eq!(labels, expected);
        }
    }
}
