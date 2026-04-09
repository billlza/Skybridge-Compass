//! Settings State
//!
//! Application settings with persistence support.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use skybridge_core::DEFAULT_TCP_PORT;
use skybridge_core::crypto::suite::CryptoSuiteId;
use skybridge_core::discovery::DeviceCapability;
use skybridge_core::p2p::LocalIdentityStore;
use skybridge_core::remote::{EncoderPreset, HardwareEncoder, VideoCodec};
use skybridge_core::transfer::CompressionStrategy;

/// Application settings
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AppSettings {
    /// Device settings
    pub device: DeviceSettings,
    /// Transfer settings
    pub transfer: TransferSettings,
    /// Remote desktop settings
    pub remote_desktop: RemoteDesktopSettings,
    /// Security settings
    pub security: SecuritySettings,
    /// Network settings
    pub network: NetworkSettings,
    /// Deployment profile and production hardening toggles
    #[serde(default)]
    pub deployment: DeploymentSettings,
    /// Developer settings
    #[serde(default)]
    pub developer: DeveloperSettings,
}

impl AppSettings {
    fn settings_override_path() -> Option<PathBuf> {
        std::env::var("SKYBRIDGE_SETTINGS_PATH")
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
    }

    fn decode_settings(content: &str, path: &Path) -> Result<Self, std::io::Error> {
        match path.extension().and_then(|ext| ext.to_str()) {
            Some(ext) if ext.eq_ignore_ascii_case("toml") => toml::from_str(content)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e)),
            _ => serde_json::from_str(content)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e)),
        }
    }

    fn encode_settings(&self, path: &Path) -> Result<String, std::io::Error> {
        match path.extension().and_then(|ext| ext.to_str()) {
            Some(ext) if ext.eq_ignore_ascii_case("toml") => {
                toml::to_string_pretty(self).map_err(std::io::Error::other)
            }
            _ => serde_json::to_string_pretty(self).map_err(std::io::Error::other),
        }
    }

    /// Load settings from disk
    pub fn load() -> Self {
        if let Some(path) = Self::settings_override_path() {
            let mut settings = if path.exists() {
                let loaded: Self = std::fs::read_to_string(&path)
                    .map_err(std::io::Error::other)
                    .and_then(|content| Self::decode_settings(&content, &path))
                    .unwrap_or_default();
                loaded
            } else {
                Self::default()
            };

            if settings.sync_identity() {
                let _ = settings.save();
            }
            settings.apply_deployment_policy();
            return settings;
        }

        let mut settings =
            if let Some(dirs) = directories::ProjectDirs::from("com", "skybridge", "compass") {
                let config_path = dirs.config_dir().join("settings.json");
                if config_path.exists() {
                    if let Ok(content) = std::fs::read_to_string(&config_path) {
                        serde_json::from_str(&content).unwrap_or_else(|_| Self::default())
                    } else {
                        Self::default()
                    }
                } else {
                    Self::default()
                }
            } else {
                Self::default()
            };

        if settings.sync_identity() {
            let _ = settings.save();
        }

        settings.apply_deployment_policy();

        settings
    }

    /// Load settings from an arbitrary path
    pub fn load_from_path(path: &Path) -> Result<Self, std::io::Error> {
        let content = std::fs::read_to_string(path)?;
        let mut settings = Self::decode_settings(&content, path)?;
        settings.sync_identity();
        settings.apply_deployment_policy();
        Ok(settings)
    }

    /// Save settings to disk
    pub fn save(&self) -> Result<(), std::io::Error> {
        if let Some(path) = Self::settings_override_path() {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            let content = self.encode_settings(&path)?;
            std::fs::write(path, content)?;
            return Ok(());
        }

        if let Some(dirs) = directories::ProjectDirs::from("com", "skybridge", "compass") {
            let config_dir = dirs.config_dir();
            std::fs::create_dir_all(config_dir)?;
            let config_path = config_dir.join("settings.json");
            let content = self.encode_settings(&config_path)?;
            std::fs::write(config_path, content)?;
        }
        Ok(())
    }

    /// Save settings to an arbitrary path
    pub fn save_to_path(&self, path: &Path) -> Result<(), std::io::Error> {
        let content = self.encode_settings(path)?;
        std::fs::write(path, content)?;
        Ok(())
    }

    /// Reset settings on disk to defaults
    pub fn reset_on_disk() -> Result<(), std::io::Error> {
        let mut defaults = Self::default();
        defaults.sync_identity();
        defaults.save()
    }

    /// Get config directory path
    pub fn config_dir() -> Option<PathBuf> {
        directories::ProjectDirs::from("com", "skybridge", "compass")
            .map(|d| d.config_dir().to_path_buf())
    }

    /// Get cache directory path
    pub fn cache_dir() -> Option<PathBuf> {
        directories::ProjectDirs::from("com", "skybridge", "compass")
            .map(|d| d.cache_dir().to_path_buf())
    }

    /// Get data directory path
    pub fn data_dir() -> Option<PathBuf> {
        directories::ProjectDirs::from("com", "skybridge", "compass")
            .map(|d| d.data_dir().to_path_buf())
    }

    fn sync_identity(&mut self) -> bool {
        let Ok(identity) = LocalIdentityStore::load_or_generate(CryptoSuiteId::all()) else {
            return false;
        };
        let mut changed = false;
        if self.device.device_id != identity.device_id {
            self.device.device_id = identity.device_id.clone();
            changed = true;
        }
        let fingerprint = identity.primary_signing_fingerprint().unwrap_or_default();
        if self.device.public_key_fingerprint != fingerprint {
            self.device.public_key_fingerprint = fingerprint;
            changed = true;
        }
        changed
    }

    fn apply_deployment_policy(&mut self) {
        if self.deployment.profile != DeploymentProfile::CloudTerminal {
            return;
        }

        self.network.enable_remote_control_server = false;
        self.network.enable_vnc_server = false;
        self.network.enable_webrtc = true;

        if self.deployment.clipboard_policy == ClipboardPolicy::Disabled {
            self.device
                .capabilities
                .retain(|cap| *cap != DeviceCapability::Clipboard);
        }

        if self.remote_desktop.codec == VideoCodec::Av1 {
            self.remote_desktop.codec = VideoCodec::Auto;
        }
    }

    /// True when the settings are pinned to the hardened cloud-terminal profile.
    pub fn is_cloud_terminal(&self) -> bool {
        self.deployment.profile == DeploymentProfile::CloudTerminal
    }
}

/// Device settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceSettings {
    /// Device display name
    pub name: String,
    /// Device ID (from local identity)
    #[serde(default)]
    pub device_id: String,
    /// Device fingerprint (SHA-256)
    #[serde(default)]
    pub public_key_fingerprint: String,
    /// Enabled capabilities
    pub capabilities: Vec<DeviceCapability>,
    /// Start on login
    pub start_on_login: bool,
    /// Show in system tray
    pub show_tray_icon: bool,
    /// Minimize to tray on close
    pub minimize_to_tray: bool,
}

impl Default for DeviceSettings {
    fn default() -> Self {
        Self {
            name: hostname::get()
                .map(|h| h.to_string_lossy().to_string())
                .unwrap_or_else(|_| "Ubuntu Device".to_string()),
            device_id: String::new(),
            public_key_fingerprint: String::new(),
            capabilities: vec![
                DeviceCapability::FileTransfer,
                DeviceCapability::Clipboard,
                DeviceCapability::RemoteDesktopView,
            ],
            start_on_login: false,
            show_tray_icon: true,
            minimize_to_tray: true,
        }
    }
}

/// Transfer settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferSettings {
    /// Default save location
    pub save_location: PathBuf,
    /// Compression strategy
    pub compression: CompressionStrategy,
    /// Zstd compression level (1-22)
    pub zstd_level: i32,
    /// Chunk size in MB
    pub chunk_size_mb: usize,
    /// Maximum concurrent transfers
    pub max_concurrent: usize,
    /// Maximum parallel chunks per transfer
    pub max_parallel_chunks: usize,
    /// Enable transfer resume
    pub enable_resume: bool,
    /// Verify chunks with BLAKE3
    pub verify_chunks: bool,
    /// Auto-accept from trusted devices
    pub auto_accept_trusted: bool,
    /// Ask before overwriting files
    pub confirm_overwrite: bool,
    /// Show notification on complete
    pub notify_on_complete: bool,
}

impl Default for TransferSettings {
    fn default() -> Self {
        Self {
            save_location: dirs::download_dir().unwrap_or_else(|| PathBuf::from("~/Downloads")),
            compression: CompressionStrategy::Adaptive,
            zstd_level: 10,
            chunk_size_mb: 2,
            max_concurrent: 4,
            max_parallel_chunks: 4,
            enable_resume: true,
            verify_chunks: true,
            auto_accept_trusted: false,
            confirm_overwrite: true,
            notify_on_complete: true,
        }
    }
}

/// Remote desktop settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteDesktopSettings {
    /// Video codec
    pub codec: VideoCodec,
    /// Hardware encoder preference
    pub hardware_encoder: HardwareEncoder,
    /// Encoder preset
    pub preset: EncoderPreset,
    /// Target bitrate in Mbps
    pub bitrate_mbps: u32,
    /// Target framerate
    pub framerate: u32,
    /// Quality level (1-51, lower = better)
    pub quality: u8,
    /// Enable low latency mode
    pub low_latency: bool,
    /// Enable screen content tuning
    pub tune_screen: bool,
    /// Show cursor
    pub show_cursor: bool,
    /// Capture audio
    pub capture_audio: bool,
    /// Allow remote control (not just view)
    pub allow_control: bool,
    /// Require confirmation for remote access
    pub require_confirmation: bool,
}

impl Default for RemoteDesktopSettings {
    fn default() -> Self {
        Self {
            codec: VideoCodec::H264,
            hardware_encoder: HardwareEncoder::Auto,
            preset: EncoderPreset::Fast,
            bitrate_mbps: 8,
            framerate: 30,
            quality: 23,
            low_latency: true,
            tune_screen: true,
            show_cursor: true,
            capture_audio: false,
            allow_control: false,
            require_confirmation: true,
        }
    }
}

/// Security settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecuritySettings {
    /// Enable post-quantum cryptography
    pub enable_pqc: bool,
    /// Prefer hybrid PQC (X-Wing)
    pub prefer_hybrid: bool,
    /// Allow classic-only connections (for older devices)
    pub allow_classic_only: bool,
    /// Require device verification
    pub require_verification: bool,
    /// Trusted device IDs
    pub trusted_devices: Vec<String>,
    /// Block unknown devices
    pub block_unknown: bool,
    /// Clear session keys on disconnect
    pub clear_keys_on_disconnect: bool,
}

impl Default for SecuritySettings {
    fn default() -> Self {
        Self {
            enable_pqc: true,
            prefer_hybrid: true,
            allow_classic_only: true,
            require_verification: false,
            trusted_devices: Vec::new(),
            block_unknown: false,
            clear_keys_on_disconnect: true,
        }
    }
}

/// Network settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkSettings {
    /// QUIC port for P2P connections
    pub quic_port: u16,
    /// Enable mDNS discovery
    pub enable_mdns: bool,
    /// Enable Bluetooth discovery
    pub enable_bluetooth: bool,
    /// Enable Wi-Fi Direct
    pub enable_wifi_direct: bool,
    /// Prefer IPv6
    pub prefer_ipv6: bool,
    /// Connection timeout in seconds
    pub connection_timeout_secs: u32,
    /// Discovery timeout in seconds
    pub discovery_timeout_secs: u32,
    /// Latency threshold for LAN detection (ms)
    pub lan_latency_threshold_ms: u32,
    /// Enable macOS-compatible remote control server
    #[serde(default)]
    pub enable_remote_control_server: bool,
    /// Remote control server port (advertised via _skybridge-remote._tcp)
    #[serde(default)]
    pub remote_control_port: u16,
    /// Enable VNC server
    #[serde(default)]
    pub enable_vnc_server: bool,
    /// VNC server port
    #[serde(default)]
    pub vnc_port: u16,
    /// Enable file transfer server
    #[serde(default)]
    pub enable_transfer_server: bool,
    /// File transfer server port
    #[serde(default)]
    pub transfer_port: u16,

    /// Enable cross-network WebRTC transport
    #[serde(default)]
    pub enable_webrtc: bool,
    /// WebSocket signaling URL
    #[serde(default)]
    pub webrtc_signaling_url: String,
    /// HTTPS signaling control plane base URL
    #[serde(default)]
    pub webrtc_signaling_server_url: String,
    /// Optional client API key for TURN/signaling control plane
    #[serde(default)]
    pub webrtc_client_api_key: String,
    /// STUN URL (e.g. stun:host:port)
    #[serde(default)]
    pub webrtc_stun_url: String,
    /// TURN URL (e.g. turn:host:port)
    #[serde(default)]
    pub webrtc_turn_url: String,
    /// TURN username (optional)
    #[serde(default)]
    pub webrtc_turn_username: String,
    /// TURN password (optional)
    #[serde(default)]
    pub webrtc_turn_password: String,
}

impl Default for NetworkSettings {
    fn default() -> Self {
        Self {
            quic_port: 51820,
            enable_mdns: true,
            enable_bluetooth: true,
            enable_wifi_direct: false,
            prefer_ipv6: false,
            connection_timeout_secs: 30,
            discovery_timeout_secs: 10,
            lan_latency_threshold_ms: 5,
            enable_remote_control_server: false,
            remote_control_port: 5901,
            enable_vnc_server: false,
            vnc_port: 5900,
            enable_transfer_server: true,
            transfer_port: DEFAULT_TCP_PORT,

            enable_webrtc: true,
            webrtc_signaling_url: "wss://api.nebula-technologies.net/ws".to_string(),
            webrtc_signaling_server_url: "https://api.nebula-technologies.net".to_string(),
            webrtc_client_api_key: String::new(),
            webrtc_stun_url: "stun:54.92.79.99:3478".to_string(),
            webrtc_turn_url: String::new(),
            webrtc_turn_username: String::new(),
            webrtc_turn_password: String::new(),
        }
    }
}

/// Deployment hardening settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeploymentSettings {
    /// Runtime deployment profile.
    #[serde(default)]
    pub profile: DeploymentProfile,
    /// Clipboard behavior for production-facing remote sessions.
    #[serde(default)]
    pub clipboard_policy: ClipboardPolicy,
    /// Force WebRTC into relay-only mode for hardened cloud terminals.
    #[serde(default)]
    pub relay_only_webrtc: bool,
}

impl Default for DeploymentSettings {
    fn default() -> Self {
        Self {
            profile: DeploymentProfile::Desktop,
            clipboard_policy: ClipboardPolicy::Enabled,
            relay_only_webrtc: false,
        }
    }
}

/// Supported deployment profiles.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DeploymentProfile {
    /// Traditional desktop/lab deployment.
    #[default]
    Desktop,
    /// Hardened cloud-hosted Linux terminal profile.
    CloudTerminal,
}

/// Clipboard policy for deployment profiles.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ClipboardPolicy {
    /// Clipboard sync is available.
    #[default]
    Enabled,
    /// Clipboard sync is intentionally disabled.
    Disabled,
}

/// Developer settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeveloperSettings {
    /// Log verbosity level
    #[serde(default)]
    pub log_level: LogLevel,
}

impl Default for DeveloperSettings {
    fn default() -> Self {
        Self {
            log_level: LogLevel::Debug,
        }
    }
}

/// Log level preference
#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default)]
pub enum LogLevel {
    /// Error only
    Error,
    /// Warning and error
    Warn,
    /// Info, warning, and error
    Info,
    /// Debug logging
    #[default]
    Debug,
    /// Trace logging
    Trace,
}
