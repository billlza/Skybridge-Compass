//! Device Discovery Manager
//!
//! Unified device discovery across multiple channels (mDNS, Bluetooth, Wi-Fi Direct).

use std::sync::Arc;
use tracing::{debug, info};

use super::mdns::{MdnsAdvertiser, MdnsBrowser};
use super::types::{DeviceCapability, DiscoveredDevice, Platform};
use crate::p2p::HandshakeDriver;
use crate::remote::supported_remote_video_formats;

type DeviceDiscoveredHandler = Arc<dyn Fn(&DiscoveredDevice) + Send + Sync>;
type DeviceRemovedHandler = Arc<dyn Fn(&str) + Send + Sync>;

/// Discovery configuration
#[derive(Debug, Clone)]
pub struct DiscoveryConfig {
    /// Enable mDNS discovery
    pub enable_mdns: bool,
    /// Enable Bluetooth discovery
    pub enable_bluetooth: bool,
    /// Enable Wi-Fi Direct discovery
    pub enable_wifi_direct: bool,
    /// Discovery timeout in seconds
    pub discovery_timeout_secs: u32,
    /// Prefer IPv6
    pub prefer_ipv6: bool,
    /// Remote-control service port (for _skybridge-remote._tcp advertisement)
    pub remote_port: Option<u16>,
    /// File transfer service port (for _skybridge-transfer._tcp advertisement)
    pub transfer_port: Option<u16>,
}

impl Default for DiscoveryConfig {
    fn default() -> Self {
        Self {
            enable_mdns: true,
            enable_bluetooth: true,
            enable_wifi_direct: false,
            discovery_timeout_secs: 10,
            prefer_ipv6: false,
            remote_port: None,
            transfer_port: Some(8080),
        }
    }
}

/// Device discovery manager
pub struct DeviceDiscoveryManager {
    /// Local device info
    local_device: DiscoveredDevice,
    /// mDNS browser
    browser: Option<MdnsBrowser>,
    /// mDNS advertiser
    advertiser: Option<MdnsAdvertiser>,
    /// Discovery callback
    on_device_discovered: Option<DeviceDiscoveredHandler>,
    /// Removal callback
    on_device_removed: Option<DeviceRemovedHandler>,
    /// Running state
    is_running: bool,
    /// Current port
    current_port: u16,
    /// Configuration
    config: DiscoveryConfig,
}

impl DeviceDiscoveryManager {
    /// Create a new discovery manager
    pub fn new(device_id: String, device_name: String, public_key_fingerprint: String) -> Self {
        let mut local_device = DiscoveredDevice::new(
            device_id,
            device_name,
            public_key_fingerprint,
            Platform::Ubuntu,
        );

        // Set default capabilities
        local_device.capabilities = vec![
            DeviceCapability::FileTransfer,
            DeviceCapability::RemoteDesktopView,
            DeviceCapability::RemoteDesktopControl,
            DeviceCapability::Clipboard,
        ];

        local_device.supported_suites = HandshakeDriver::runtime_advertised_crypto_suites();
        local_device.remote_video_formats = supported_remote_video_formats();

        Self {
            local_device,
            browser: None,
            advertiser: None,
            on_device_discovered: None,
            on_device_removed: None,
            is_running: false,
            current_port: 0,
            config: DiscoveryConfig::default(),
        }
    }

    /// Create with custom configuration
    pub fn with_config(
        device_id: String,
        device_name: String,
        public_key_fingerprint: String,
        config: DiscoveryConfig,
    ) -> Self {
        let mut manager = Self::new(device_id, device_name, public_key_fingerprint);
        manager.config = config;
        manager
    }

    /// Update configuration
    pub fn set_config(&mut self, config: DiscoveryConfig) {
        self.config = config;
        // If running, restart to apply new config
        if self.is_running {
            let port = self.current_port;
            let _ = self.stop();
            let _ = self.start(port);
        }
    }

    /// Set device discovered callback
    pub fn on_device_discovered<F>(&mut self, callback: F)
    where
        F: Fn(&DiscoveredDevice) + Send + Sync + 'static,
    {
        self.on_device_discovered = Some(Arc::new(callback));
    }

    /// Set device removed callback
    pub fn on_device_removed<F>(&mut self, callback: F)
    where
        F: Fn(&str) + Send + Sync + 'static,
    {
        self.on_device_removed = Some(Arc::new(callback));
    }

    /// Start discovery
    pub fn start(&mut self, port: u16) -> Result<(), Box<dyn std::error::Error>> {
        if self.is_running {
            return Ok(());
        }

        info!("Starting device discovery on port {}", port);
        self.current_port = port;

        // Start mDNS if enabled
        if self.config.enable_mdns {
            self.start_mdns(port)?;
        }

        // Start Bluetooth if enabled
        if self.config.enable_bluetooth {
            self.start_bluetooth()?;
        }

        // Start Wi-Fi Direct if enabled
        if self.config.enable_wifi_direct {
            self.start_wifi_direct()?;
        }

        self.is_running = true;
        Ok(())
    }

    /// Start mDNS discovery
    fn start_mdns(&mut self, port: u16) -> Result<(), Box<dyn std::error::Error>> {
        // Start mDNS browser
        let mut browser = MdnsBrowser::new()?;

        // Wire up callbacks
        if let Some(ref callback) = self.on_device_discovered {
            browser.set_on_discovered(callback.clone());
        }
        if let Some(ref callback) = self.on_device_removed {
            browser.set_on_removed(callback.clone());
        }

        browser.start_browse()?;
        self.browser = Some(browser);

        // Start mDNS advertiser
        let mut advertiser = MdnsAdvertiser::new()?;
        let remote_port = self.config.remote_port;
        // macOS/iOS Pro release defaults to 8080; keep compatible even when control channel uses a different port.
        let transfer_port = self.config.transfer_port.unwrap_or(8080);
        advertiser.advertise(&self.local_device, port, remote_port, Some(transfer_port))?;
        self.advertiser = Some(advertiser);

        info!("mDNS discovery started");
        Ok(())
    }

    /// Start Bluetooth discovery.
    ///
    /// Ubuntu currently has no stable cross-distro BLE discovery backend wired in this crate;
    /// keep this as a no-op with explicit telemetry rather than silently failing.
    fn start_bluetooth(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        debug!(
            "Bluetooth discovery requested but backend is not available on this build; mDNS remains active"
        );
        Ok(())
    }

    /// Start Wi-Fi Direct discovery.
    ///
    /// Ubuntu currently relies on mDNS for interoperability; Wi-Fi Direct integration can be
    /// added later behind the same interface without breaking callers.
    fn start_wifi_direct(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        debug!(
            "Wi-Fi Direct discovery requested but backend is not available on this build; mDNS remains active"
        );
        Ok(())
    }

    /// Stop discovery
    pub fn stop(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        if !self.is_running {
            return Ok(());
        }

        info!("Stopping device discovery");

        if let Some(mut advertiser) = self.advertiser.take() {
            advertiser.stop()?;
        }

        self.browser = None;
        self.is_running = false;
        Ok(())
    }

    /// Re-advertise with current device info (call after updating name/capabilities)
    pub fn re_advertise(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        if let Some(ref mut advertiser) = self.advertiser {
            advertiser.re_advertise(&self.local_device)?;
            info!("Re-advertised with updated device info");
        }
        Ok(())
    }

    /// Get all discovered devices
    pub async fn devices(&self) -> Vec<DiscoveredDevice> {
        if let Some(browser) = &self.browser {
            browser.devices().await
        } else {
            Vec::new()
        }
    }

    /// Get online devices only
    pub async fn online_devices(&self) -> Vec<DiscoveredDevice> {
        if let Some(browser) = &self.browser {
            browser.online_devices().await
        } else {
            Vec::new()
        }
    }

    /// Get device by ID
    pub async fn get_device(&self, device_id: &str) -> Option<DiscoveredDevice> {
        if let Some(browser) = &self.browser {
            browser.get_device(device_id).await
        } else {
            None
        }
    }

    /// Get local device info
    pub fn local_device(&self) -> &DiscoveredDevice {
        &self.local_device
    }

    /// Get mutable local device info
    pub fn local_device_mut(&mut self) -> &mut DiscoveredDevice {
        &mut self.local_device
    }

    /// Update local device name and re-advertise
    pub fn set_device_name(&mut self, name: String) -> Result<(), Box<dyn std::error::Error>> {
        self.local_device.name = name;
        self.re_advertise()
    }

    /// Update local device capabilities and re-advertise
    pub fn set_capabilities(
        &mut self,
        capabilities: Vec<DeviceCapability>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        self.local_device.capabilities = capabilities;
        self.re_advertise()
    }

    /// Update public key fingerprint and re-advertise
    pub fn set_public_key_fingerprint(
        &mut self,
        fingerprint: String,
    ) -> Result<(), Box<dyn std::error::Error>> {
        self.local_device.public_key_fingerprint = fingerprint;
        self.re_advertise()
    }

    /// Check if discovery is running
    pub fn is_running(&self) -> bool {
        self.is_running
    }

    /// Get current configuration
    pub fn config(&self) -> &DiscoveryConfig {
        &self.config
    }

    /// Refresh discovery (restart browsing)
    pub fn refresh(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        if !self.is_running {
            return Ok(());
        }

        let port = self.current_port;
        self.stop()?;
        self.start(port)?;
        Ok(())
    }
}

impl Drop for DeviceDiscoveryManager {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_discovery_config_default() {
        let config = DiscoveryConfig::default();
        assert!(config.enable_mdns);
        assert!(config.enable_bluetooth);
        assert!(!config.enable_wifi_direct);
    }

    #[test]
    fn test_manager_creation() {
        let manager = DeviceDiscoveryManager::new(
            "test-id".to_string(),
            "Test Device".to_string(),
            "fingerprint".to_string(),
        );
        assert!(!manager.is_running());
        assert_eq!(manager.local_device().name, "Test Device");
    }

    #[test]
    fn test_manager_with_config() {
        let config = DiscoveryConfig {
            enable_mdns: false,
            enable_bluetooth: false,
            enable_wifi_direct: true,
            discovery_timeout_secs: 30,
            prefer_ipv6: true,
            remote_port: Some(5901),
            transfer_port: Some(8080),
        };

        let manager = DeviceDiscoveryManager::with_config(
            "test-id".to_string(),
            "Test".to_string(),
            "fp".to_string(),
            config,
        );

        assert!(!manager.config().enable_mdns);
        assert!(manager.config().enable_wifi_direct);
    }
}
