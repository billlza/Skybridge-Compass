use crate::transport::{PeerCapabilities, PeerPlatform};
use std::collections::BTreeMap;

pub const SKYBRIDGE_QUIC_PRIMARY_SERVICE: &str = "_skybridge._udp";
pub const SKYBRIDGE_TCP_FALLBACK_SERVICE: &str = "_skybridge._tcp";
pub const SKYBRIDGE_FILE_TRANSFER_SERVICE: &str = "_skybridge-xfer._tcp";
pub const SKYBRIDGE_REMOTE_CONTROL_SERVICE: &str = "_skybridge-rd._tcp";
pub const SKYBRIDGE_LEGACY_FILE_TRANSFER_SERVICE: &str = "_skybridge-transfer._tcp";
pub const SKYBRIDGE_LEGACY_REMOTE_CONTROL_SERVICE: &str = "_skybridge-remote._tcp";
const MAX_TXT_RECORD_BYTES: usize = 4096;
const MAX_TXT_KEY_BYTES: usize = 64;
const MAX_TXT_VALUE_BYTES: usize = 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryServiceKind {
    QuicPrimary,
    TcpFallback,
    FileTransfer,
    RemoteControl,
}

impl DiscoveryServiceKind {
    pub const fn service_type(self) -> &'static str {
        match self {
            Self::QuicPrimary => SKYBRIDGE_QUIC_PRIMARY_SERVICE,
            Self::TcpFallback => SKYBRIDGE_TCP_FALLBACK_SERVICE,
            Self::FileTransfer => SKYBRIDGE_FILE_TRANSFER_SERVICE,
            Self::RemoteControl => SKYBRIDGE_REMOTE_CONTROL_SERVICE,
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
    ConflictingFieldAliases(&'static str),
    InvalidPublicKeyFingerprint,
    InvalidTxtPair(String),
    DuplicateTxtKey(String),
    TxtRecordTooLarge,
    TxtKeyTooLong(String),
    TxtValueTooLong(String),
}

pub fn parse_txt_advertisement(txt: &str) -> Result<PeerAdvertisement, DiscoveryError> {
    parse_txt_map(parse_txt_pairs(txt)?)
}

pub fn parse_txt_map(
    txt_record: BTreeMap<String, String>,
) -> Result<PeerAdvertisement, DiscoveryError> {
    let device_id = required_aliased_field(
        &txt_record,
        "deviceId",
        &[
            "deviceId",
            "id",
            "deviceID",
            "device_id",
            "uuid",
            "uniqueId",
            "unique_id",
        ],
    )?;
    let public_key_fingerprint = required_aliased_field(
        &txt_record,
        "pubKeyFP",
        &[
            "pubKeyFP",
            "pubKeyFp",
            "pub_key_fp",
            "identityFingerprint",
            "publicKeyFingerprint",
        ],
    )?;
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
        "_skybridge-xfer._tcp" | "_skybridge-transfer._tcp" => {
            Some(DiscoveryServiceKind::FileTransfer)
        }
        "_skybridge-rd._tcp" | "_skybridge-remote._tcp" => {
            Some(DiscoveryServiceKind::RemoteControl)
        }
        _ => match normalize_token(value).as_str() {
            "udp" | "quic" | "primary" => Some(DiscoveryServiceKind::QuicPrimary),
            "tcp" | "fallback" => Some(DiscoveryServiceKind::TcpFallback),
            "file-transfer" | "filetransfer" => Some(DiscoveryServiceKind::FileTransfer),
            "remote-control" | "remotecontrol" | "remote-desktop" | "remotedesktop" => {
                Some(DiscoveryServiceKind::RemoteControl)
            }
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
    if txt.len() > MAX_TXT_RECORD_BYTES {
        return Err(DiscoveryError::TxtRecordTooLarge);
    }
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
        if key.len() > MAX_TXT_KEY_BYTES {
            return Err(DiscoveryError::TxtKeyTooLong(key.into()));
        }
        let value = value.trim();
        if value.len() > MAX_TXT_VALUE_BYTES {
            return Err(DiscoveryError::TxtValueTooLong(key.into()));
        }
        if value.contains('\0') {
            return Err(DiscoveryError::InvalidTxtPair(pair.into()));
        }
        if pairs.insert(key.to_string(), value.to_string()).is_some() {
            return Err(DiscoveryError::DuplicateTxtKey(key.into()));
        }
    }
    Ok(pairs)
}

fn required_aliased_field(
    txt_record: &BTreeMap<String, String>,
    canonical_name: &'static str,
    aliases: &[&str],
) -> Result<String, DiscoveryError> {
    let mut discovered_value: Option<String> = None;
    for alias in aliases {
        let Some(raw) = txt_record.get(*alias) else {
            continue;
        };
        let value = raw.trim();
        if value.is_empty() {
            if discovered_value.is_none() {
                return Err(DiscoveryError::EmptyField(canonical_name));
            }
            continue;
        }
        if let Some(existing) = discovered_value.as_deref() {
            if existing != value {
                return Err(DiscoveryError::ConflictingFieldAliases(canonical_name));
            }
            continue;
        }
        discovered_value = Some(value.to_string());
    }

    discovered_value.ok_or(DiscoveryError::MissingField(canonical_name))
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
    fn parses_apple_discovery_aliases_without_weakening_identity() {
        let ad = parse_txt_advertisement(&format!(
            "unique_id=ipad-1;identityFingerprint={FP};platform=iPadOS;capabilities=webrtc"
        ))
        .expect("advertisement");

        assert_eq!(ad.device_id, "ipad-1");
        assert_eq!(ad.public_key_fingerprint, FP);
        assert_eq!(ad.platform, PeerPlatform::Apple);
    }

    #[test]
    fn rejects_conflicting_discovery_aliases() {
        assert_eq!(
            parse_txt_advertisement(&format!(
                "deviceId=mac-1;uniqueId=mac-2;pubKeyFP={FP};platform=macOS"
            ))
            .unwrap_err(),
            DiscoveryError::ConflictingFieldAliases("deviceId")
        );
        assert_eq!(
            parse_txt_advertisement(&format!(
                "deviceId=mac-1;pubKeyFP={FP};identityFingerprint=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789;platform=macOS"
            ))
            .unwrap_err(),
            DiscoveryError::ConflictingFieldAliases("pubKeyFP")
        );
    }

    #[test]
    fn rejects_duplicate_and_oversized_txt_pairs_without_last_wins() {
        assert_eq!(
            parse_txt_advertisement(&format!(
                "deviceId=mac-1;pubKeyFP={FP};deviceId=mac-2;platform=macOS"
            ))
            .unwrap_err(),
            DiscoveryError::DuplicateTxtKey("deviceId".into())
        );
        assert_eq!(
            parse_txt_advertisement(&format!(
                "deviceId=mac-1;pubKeyFP={FP};{}=x",
                "k".repeat(MAX_TXT_KEY_BYTES + 1)
            ))
            .unwrap_err(),
            DiscoveryError::TxtKeyTooLong("k".repeat(MAX_TXT_KEY_BYTES + 1))
        );
        assert_eq!(
            parse_txt_advertisement(&format!(
                "deviceId=mac-1;pubKeyFP={FP};name={}",
                "x".repeat(MAX_TXT_VALUE_BYTES + 1)
            ))
            .unwrap_err(),
            DiscoveryError::TxtValueTooLong("name".into())
        );
        assert_eq!(
            parse_txt_advertisement(&"x".repeat(MAX_TXT_RECORD_BYTES + 1)).unwrap_err(),
            DiscoveryError::TxtRecordTooLarge
        );
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
    fn service_kind_accepts_legacy_aliases_but_emits_canonical_names() {
        assert_eq!(
            parse_service_kind("_skybridge._udp"),
            Some(DiscoveryServiceKind::QuicPrimary)
        );
        assert_eq!(
            parse_service_kind("_skybridge._tcp"),
            Some(DiscoveryServiceKind::TcpFallback)
        );
        assert_eq!(
            parse_service_kind("_skybridge-xfer._tcp"),
            Some(DiscoveryServiceKind::FileTransfer)
        );
        assert_eq!(
            parse_service_kind("_skybridge-transfer._tcp"),
            Some(DiscoveryServiceKind::FileTransfer)
        );
        assert_eq!(
            parse_service_kind("_skybridge-rd._tcp"),
            Some(DiscoveryServiceKind::RemoteControl)
        );
        assert_eq!(
            parse_service_kind("_skybridge-remote._tcp"),
            Some(DiscoveryServiceKind::RemoteControl)
        );
        assert_eq!(
            DiscoveryServiceKind::QuicPrimary.service_type(),
            SKYBRIDGE_QUIC_PRIMARY_SERVICE
        );
        assert_eq!(
            DiscoveryServiceKind::FileTransfer.service_type(),
            "_skybridge-xfer._tcp"
        );
        assert_eq!(
            DiscoveryServiceKind::RemoteControl.service_type(),
            "_skybridge-rd._tcp"
        );
        assert_eq!(
            SKYBRIDGE_LEGACY_FILE_TRANSFER_SERVICE,
            "_skybridge-transfer._tcp"
        );
        assert_eq!(
            SKYBRIDGE_LEGACY_REMOTE_CONTROL_SERVICE,
            "_skybridge-remote._tcp"
        );
    }
}
