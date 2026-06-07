use crate::transport::{PeerCapabilities, PeerPlatform};
use std::collections::BTreeMap;

pub const SKYBRIDGE_QUIC_PRIMARY_SERVICE: &str = "_skybridge._udp";
pub const SKYBRIDGE_TCP_FALLBACK_SERVICE: &str = "_skybridge._tcp";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryServiceKind {
    QuicPrimary,
    TcpFallback,
}

impl DiscoveryServiceKind {
    pub const fn service_type(self) -> &'static str {
        match self {
            Self::QuicPrimary => SKYBRIDGE_QUIC_PRIMARY_SERVICE,
            Self::TcpFallback => SKYBRIDGE_TCP_FALLBACK_SERVICE,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerAdvertisement {
    pub device_id: String,
    pub public_key_fingerprint: String,
    pub platform: PeerPlatform,
    pub platform_label: String,
    pub capabilities: Vec<String>,
    pub name: String,
    pub protocol_version: String,
}

impl PeerAdvertisement {
    pub fn peer_capabilities(&self) -> PeerCapabilities {
        let mut capabilities = match self.platform {
            PeerPlatform::Apple => PeerCapabilities::apple(),
            PeerPlatform::Windows => PeerCapabilities::windows(),
            PeerPlatform::Unknown => PeerCapabilities {
                platform: PeerPlatform::Unknown,
                supports_apple_native: false,
                supports_msquic: false,
                supports_skybridge_ice_msquic: false,
                supports_webrtc_data_channel: false,
                supports_tcp_fallback: false,
                supports_relay: false,
            },
        };

        for capability in &self.capabilities {
            match normalize_token(capability).as_str() {
                "apple-native" | "network-framework" | "networkframework" => {
                    capabilities.supports_apple_native = true;
                }
                "msquic" | "quic" | "windows-native-msquic" => {
                    capabilities.supports_msquic = true;
                }
                "skybridge-ice-msquic" | "ice-msquic" => {
                    capabilities.supports_skybridge_ice_msquic = true;
                }
                "webrtc" | "webrtc-datachannel" | "webrtc-data-channel" => {
                    capabilities.supports_webrtc_data_channel = true;
                }
                "tcp" | "tcp-fallback" => {
                    capabilities.supports_tcp_fallback = true;
                }
                "relay" | "turn" => {
                    capabilities.supports_relay = true;
                }
                _ => {}
            }
        }

        capabilities
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiscoveryError {
    MissingField(&'static str),
    EmptyField(&'static str),
    InvalidPublicKeyFingerprint,
    InvalidTxtPair(String),
}

pub fn parse_txt_advertisement(txt: &str) -> Result<PeerAdvertisement, DiscoveryError> {
    parse_txt_map(parse_txt_pairs(txt)?)
}

pub fn parse_txt_map(
    txt_record: BTreeMap<String, String>,
) -> Result<PeerAdvertisement, DiscoveryError> {
    let device_id = required_field(&txt_record, "deviceId")?;
    let public_key_fingerprint = required_field(&txt_record, "pubKeyFP")?;
    if !is_valid_public_key_fingerprint(&public_key_fingerprint) {
        return Err(DiscoveryError::InvalidPublicKeyFingerprint);
    }

    let platform_label = txt_record
        .get("platform")
        .filter(|value| !value.trim().is_empty())
        .cloned()
        .unwrap_or_else(|| "unknown".into());
    let capabilities = txt_record
        .get("capabilities")
        .map(|value| {
            value
                .split(',')
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    Ok(PeerAdvertisement {
        device_id,
        public_key_fingerprint,
        platform: parse_peer_platform(&platform_label),
        platform_label,
        capabilities,
        name: txt_record
            .get("name")
            .filter(|value| !value.trim().is_empty())
            .cloned()
            .unwrap_or_else(|| "Unknown Device".into()),
        protocol_version: txt_record
            .get("version")
            .filter(|value| !value.trim().is_empty())
            .cloned()
            .unwrap_or_else(|| "1.0".into()),
    })
}

pub fn parse_service_kind(value: &str) -> Option<DiscoveryServiceKind> {
    let raw = value.trim().to_ascii_lowercase();
    match raw.as_str() {
        "_skybridge._udp" => Some(DiscoveryServiceKind::QuicPrimary),
        "_skybridge._tcp" => Some(DiscoveryServiceKind::TcpFallback),
        _ => match normalize_token(value).as_str() {
            "udp" | "quic" | "primary" => Some(DiscoveryServiceKind::QuicPrimary),
            "tcp" | "fallback" => Some(DiscoveryServiceKind::TcpFallback),
            _ => None,
        },
    }
}

pub fn is_valid_public_key_fingerprint(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn parse_txt_pairs(txt: &str) -> Result<BTreeMap<String, String>, DiscoveryError> {
    let mut pairs = BTreeMap::new();
    for raw_pair in txt.split(';') {
        let pair = raw_pair.trim();
        if pair.is_empty() {
            continue;
        }

        let Some((key, value)) = pair.split_once('=') else {
            return Err(DiscoveryError::InvalidTxtPair(pair.into()));
        };
        let key = key.trim();
        if key.is_empty() {
            return Err(DiscoveryError::InvalidTxtPair(pair.into()));
        }
        pairs.insert(key.to_string(), value.trim().to_string());
    }
    Ok(pairs)
}

fn required_field(
    txt_record: &BTreeMap<String, String>,
    name: &'static str,
) -> Result<String, DiscoveryError> {
    let value = txt_record
        .get(name)
        .ok_or(DiscoveryError::MissingField(name))?
        .trim();
    if value.is_empty() {
        return Err(DiscoveryError::EmptyField(name));
    }
    Ok(value.to_string())
}

fn parse_peer_platform(value: &str) -> PeerPlatform {
    match normalize_token(value).as_str() {
        "macos" | "ios" | "ipados" | "apple" => PeerPlatform::Apple,
        "windows" | "win" => PeerPlatform::Windows,
        _ => PeerPlatform::Unknown,
    }
}

fn normalize_token(value: &str) -> String {
    value.trim().to_ascii_lowercase().replace('_', "-")
}

#[cfg(test)]
mod tests {
    use super::*;

    const FP: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    #[test]
    fn parses_mac_bonjour_txt_shape_and_keeps_defaults() {
        let ad = parse_txt_advertisement(&format!(
            "deviceId=mac-1;pubKeyFP={FP};platform=macOS;capabilities=webrtc,tcp;name=Desk Mac;version=v1"
        ))
        .expect("advertisement");

        assert_eq!(ad.device_id, "mac-1");
        assert_eq!(ad.public_key_fingerprint, FP);
        assert_eq!(ad.platform, PeerPlatform::Apple);
        assert_eq!(ad.capabilities, vec!["webrtc", "tcp"]);
        assert_eq!(ad.name, "Desk Mac");
        assert_eq!(ad.protocol_version, "v1");

        let capabilities = ad.peer_capabilities();
        assert!(capabilities.supports_apple_native);
        assert!(capabilities.supports_webrtc_data_channel);
        assert!(capabilities.supports_tcp_fallback);
        assert!(!capabilities.supports_msquic);
    }

    #[test]
    fn parses_windows_capabilities_for_future_dns_sd_adapter() {
        let ad = parse_txt_advertisement(&format!(
            "deviceId=win-1;pubKeyFP={FP};platform=Windows;capabilities=msquic,webrtc,relay;name=Windows;version=v1"
        ))
        .expect("advertisement");
        let capabilities = ad.peer_capabilities();

        assert_eq!(ad.platform, PeerPlatform::Windows);
        assert!(capabilities.supports_msquic);
        assert!(capabilities.supports_webrtc_data_channel);
        assert!(capabilities.supports_relay);
        assert!(!capabilities.supports_apple_native);
    }

    #[test]
    fn validates_required_fields_and_lowercase_fingerprint() {
        assert_eq!(
            parse_txt_advertisement("pubKeyFP=abc").unwrap_err(),
            DiscoveryError::MissingField("deviceId")
        );
        assert_eq!(
            parse_txt_advertisement("deviceId=mac;pubKeyFP=").unwrap_err(),
            DiscoveryError::EmptyField("pubKeyFP")
        );
        assert_eq!(
            parse_txt_advertisement(&format!(
                "deviceId=mac;pubKeyFP={}",
                FP.to_ascii_uppercase()
            ))
            .unwrap_err(),
            DiscoveryError::InvalidPublicKeyFingerprint
        );
    }

    #[test]
    fn service_kind_matches_apple_primary_and_fallback_names() {
        assert_eq!(
            parse_service_kind("_skybridge._udp"),
            Some(DiscoveryServiceKind::QuicPrimary)
        );
        assert_eq!(
            parse_service_kind("_skybridge._tcp"),
            Some(DiscoveryServiceKind::TcpFallback)
        );
        assert_eq!(
            DiscoveryServiceKind::QuicPrimary.service_type(),
            SKYBRIDGE_QUIC_PRIMARY_SERVICE
        );
    }
}
