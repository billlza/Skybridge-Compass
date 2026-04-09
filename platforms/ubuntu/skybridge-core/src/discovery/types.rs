//! Discovery Types
//!
//! Types for device discovery.

use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::time::Instant;

use crate::crypto::suite::CryptoSuiteId;

/// Platform type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    /// macOS
    MacOS,
    /// iOS
    IOS,
    /// iPadOS
    IPadOS,
    /// Android
    Android,
    /// Windows
    Windows,
    /// Linux
    Linux,
    /// Ubuntu (Linux variant)
    #[default]
    Ubuntu,
    /// Unknown platform
    Unknown,
}

impl Platform {
    /// Parse from string (lossy; unknown values map to `Platform::Unknown`)
    pub fn parse_lossy(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "macos" | "mac" => Self::MacOS,
            "ios" => Self::IOS,
            "ipados" => Self::IPadOS,
            "android" => Self::Android,
            "windows" | "win" => Self::Windows,
            "linux" => Self::Linux,
            "ubuntu" => Self::Ubuntu,
            _ => Self::Unknown,
        }
    }

    /// Backwards-compatible parser.
    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Self {
        Self::parse_lossy(s)
    }

    /// Convert to string for mDNS TXT record
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::MacOS => "macos",
            Self::IOS => "ios",
            Self::IPadOS => "ipados",
            Self::Android => "android",
            Self::Windows => "windows",
            Self::Linux => "linux",
            Self::Ubuntu => "ubuntu",
            Self::Unknown => "unknown",
        }
    }
}

impl std::str::FromStr for Platform {
    type Err = std::convert::Infallible;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(Self::parse_lossy(s))
    }
}

impl std::fmt::Display for Platform {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

/// Device capability
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DeviceCapability {
    /// File transfer
    FileTransfer,
    /// Remote desktop (view only)
    RemoteDesktopView,
    /// Remote desktop (control)
    RemoteDesktopControl,
    /// Clipboard sync
    Clipboard,
    /// Screen sharing
    ScreenShare,
    /// Audio streaming
    AudioStream,
}

impl DeviceCapability {
    /// Parse from string
    pub fn parse(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "file" | "filetransfer" | "file_transfer" => Some(Self::FileTransfer),
            // macOS/iOS (and some Android/Windows) commonly advertise these broader tokens.
            // Best-effort map them onto our more specific capability model.
            "remote_desktop" | "rd" => Some(Self::RemoteDesktopView),
            "rdview" | "remote_desktop_view" => Some(Self::RemoteDesktopView),
            "remote_control" | "control" => Some(Self::RemoteDesktopControl),
            "rdcontrol" | "remote_desktop_control" => Some(Self::RemoteDesktopControl),
            "clipboard" | "clipboard_sync" => Some(Self::Clipboard),
            "screen" | "screenshare" | "screen_share" | "screen_sharing" => Some(Self::ScreenShare),
            "audio" | "audiostream" | "audio_stream" => Some(Self::AudioStream),
            _ => None,
        }
    }

    /// Backwards-compatible parser.
    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Option<Self> {
        Self::parse(s)
    }

    /// Convert to string for mDNS TXT record
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::FileTransfer => "file",
            Self::RemoteDesktopView => "rdview",
            Self::RemoteDesktopControl => "rdcontrol",
            Self::Clipboard => "clipboard",
            Self::ScreenShare => "screen",
            Self::AudioStream => "audio",
        }
    }

    /// Get all capabilities
    pub fn all() -> &'static [DeviceCapability] {
        &[
            Self::FileTransfer,
            Self::RemoteDesktopView,
            Self::RemoteDesktopControl,
            Self::Clipboard,
            Self::ScreenShare,
            Self::AudioStream,
        ]
    }
}

/// A discovered device
#[derive(Debug, Clone)]
pub struct DiscoveredDevice {
    /// Device ID
    pub device_id: String,
    /// Unique identifier for merge prevention (Pro-release `uniqueId`)
    pub unique_id: Option<String>,
    /// Display name
    pub name: String,
    /// Public key fingerprint (SHA-256, hex, 64 chars)
    pub public_key_fingerprint: String,
    /// Platform
    pub platform: Platform,
    /// OS version string (Pro-release `osVersion`)
    pub os_version: Option<String>,
    /// Capabilities
    pub capabilities: Vec<DeviceCapability>,
    /// Supported crypto suites (ordered by preference)
    pub supported_suites: Vec<CryptoSuiteId>,
    /// Protocol version
    pub protocol_version: String,
    /// Apple-compatible remote screen-data formats this peer can receive (`jpeg`, `h264`, `hevc`).
    pub remote_video_formats: Vec<String>,
    /// Network addresses
    pub addresses: Vec<SocketAddr>,
    /// Remote-control service addresses (`_skybridge-remote._tcp`)
    pub remote_addresses: Vec<SocketAddr>,
    /// File-transfer service addresses (`_skybridge-transfer._tcp`)
    pub transfer_addresses: Vec<SocketAddr>,
    /// Last seen time
    pub last_seen: Instant,
    /// Is currently online
    pub is_online: bool,
}

impl DiscoveredDevice {
    /// Create a new discovered device
    pub fn new(
        device_id: String,
        name: String,
        public_key_fingerprint: String,
        platform: Platform,
    ) -> Self {
        Self {
            device_id,
            unique_id: None,
            name,
            public_key_fingerprint,
            platform,
            os_version: None,
            capabilities: Vec::new(),
            supported_suites: CryptoSuiteId::all().to_vec(),
            protocol_version: crate::PROTOCOL_VERSION.to_string(),
            remote_video_formats: Vec::new(),
            addresses: Vec::new(),
            remote_addresses: Vec::new(),
            transfer_addresses: Vec::new(),
            last_seen: Instant::now(),
            is_online: true,
        }
    }

    /// Update last seen time
    pub fn touch(&mut self) {
        self.last_seen = Instant::now();
        self.is_online = true;
    }

    /// Check if device has a capability
    pub fn has_capability(&self, cap: DeviceCapability) -> bool {
        self.capabilities.contains(&cap)
    }

    /// Get capabilities as comma-separated string
    pub fn capabilities_string(&self) -> String {
        self.capabilities
            .iter()
            .map(|c| c.as_str())
            .collect::<Vec<_>>()
            .join(",")
    }

    /// Parse capabilities from comma-separated string
    pub fn parse_capabilities(s: &str) -> Vec<DeviceCapability> {
        s.split(',')
            .filter_map(|part| DeviceCapability::parse(part.trim()))
            .collect()
    }

    /// Get crypto suites as comma-separated hex string (e.g., "0001,0101,1001")
    pub fn crypto_suites_string(&self) -> String {
        self.supported_suites
            .iter()
            .map(|s| format!("{:04x}", s.wire_id()))
            .collect::<Vec<_>>()
            .join(",")
    }

    /// Parse crypto suites from comma-separated hex string
    pub fn parse_crypto_suites(s: &str) -> Vec<CryptoSuiteId> {
        s.split(',')
            .filter_map(|part| {
                u16::from_str_radix(part.trim(), 16)
                    .ok()
                    .and_then(CryptoSuiteId::from_wire_id)
            })
            .collect()
    }

    /// Get remote video formats as comma-separated string.
    pub fn remote_video_formats_string(&self) -> String {
        self.remote_video_formats.join(",")
    }

    /// Parse remote video formats from comma-separated string.
    pub fn parse_remote_video_formats(s: &str) -> Vec<String> {
        let mut formats = Vec::new();
        for raw in s.split(',') {
            let normalized = raw.trim().to_lowercase();
            if normalized.is_empty() || formats.contains(&normalized) {
                continue;
            }
            formats.push(normalized);
        }
        formats
    }

    /// Check if this device supports PQC
    pub fn supports_pqc(&self) -> bool {
        self.supported_suites.iter().any(|s| s.is_pqc())
    }

    /// Check if this device supports hybrid PQC (X-Wing)
    pub fn supports_hybrid_pqc(&self) -> bool {
        self.supported_suites.iter().any(|s| s.is_hybrid())
    }

    /// Get the best address for connection
    pub fn best_address(&self) -> Option<&SocketAddr> {
        // Prefer IPv4 for now
        self.addresses
            .iter()
            .find(|a| a.is_ipv4())
            .or_else(|| self.addresses.first())
    }

    /// Get the best remote-control endpoint (falls back to control endpoint).
    pub fn best_remote_address(&self) -> Option<&SocketAddr> {
        self.remote_addresses
            .iter()
            .find(|a| a.is_ipv4())
            .or_else(|| self.remote_addresses.first())
            .or_else(|| self.best_address())
    }

    /// Get the best file-transfer endpoint (falls back to control endpoint).
    pub fn best_transfer_address(&self) -> Option<&SocketAddr> {
        self.transfer_addresses
            .iter()
            .find(|a| a.is_ipv4())
            .or_else(|| self.transfer_addresses.first())
            .or_else(|| self.best_address())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn best_remote_address_prefers_remote_service_endpoint() {
        let mut device = DiscoveredDevice::new(
            "dev-1".to_string(),
            "Device".to_string(),
            "fp".to_string(),
            Platform::MacOS,
        );
        device.addresses = vec!["192.168.1.10:7000".parse().expect("valid control endpoint")];
        device.remote_addresses = vec!["192.168.1.10:5901".parse().expect("valid remote endpoint")];

        assert_eq!(
            device.best_remote_address().map(SocketAddr::port),
            Some(5901)
        );
    }

    #[test]
    fn best_transfer_address_falls_back_to_control_endpoint() {
        let mut device = DiscoveredDevice::new(
            "dev-2".to_string(),
            "Device".to_string(),
            "fp".to_string(),
            Platform::Ubuntu,
        );
        device.addresses = vec!["10.0.0.2:7000".parse().expect("valid control endpoint")];
        assert_eq!(
            device.best_transfer_address().map(SocketAddr::port),
            Some(7000)
        );
    }
}

/// TXT record fields for mDNS
pub mod txt_fields {
    /// Device ID field
    pub const DEVICE_ID: &str = "deviceId";
    /// Public key fingerprint field
    pub const PUB_KEY_FP: &str = "pubKeyFP";
    /// Unique ID field (Pro-release)
    pub const UNIQUE_ID: &str = "uniqueId";
    /// Platform field
    pub const PLATFORM: &str = "platform";
    /// Capabilities field
    pub const CAPABILITIES: &str = "capabilities";
    /// Name field
    pub const NAME: &str = "name";
    /// Version field
    pub const VERSION: &str = "version";
    /// OS version field
    pub const OS_VERSION: &str = "osVersion";
    /// Crypto suites field (comma-separated hex IDs: "0001,0101,1001")
    pub const CRYPTO_SUITES: &str = "cryptoSuites";
    /// Remote video formats field (`jpeg,h264,hevc`)
    pub const REMOTE_VIDEO_FORMATS: &str = "remoteVideoFormats";
}
