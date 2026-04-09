//! mDNS Discovery
//!
//! mDNS/Bonjour service for device discovery.

use mdns_sd::{ResolvedService, ServiceDaemon, ServiceEvent, ServiceInfo};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{debug, error, info, warn};

use super::types::{DiscoveredDevice, Platform, txt_fields};
use crate::p2p::TrustStore;

fn get_txt_value(properties: &mdns_sd::TxtProperties, keys: &[&str]) -> Option<String> {
    for &key in keys {
        if let Some(value) = properties.get_property_val_str(key) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

/// mDNS service types
pub const SERVICE_TYPE: &str = "_skybridge._tcp.local.";
pub const QUIC_SERVICE_TYPE: &str = "_skybridge._udp.local.";
pub const REMOTE_SERVICE_TYPE: &str = "_skybridge-remote._tcp.local.";
pub const TRANSFER_SERVICE_TYPE: &str = "_skybridge-transfer._tcp.local.";

/// Callback type for device discovery
pub type DeviceDiscoveredCallback = Arc<dyn Fn(&DiscoveredDevice) + Send + Sync>;

/// Callback type for device removal
pub type DeviceRemovedCallback = Arc<dyn Fn(&str) + Send + Sync>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ServiceKind {
    Control,
    Quic,
    Remote,
    Transfer,
    Unknown,
}

impl ServiceKind {
    fn from_service_type(service_type: &str) -> Self {
        let normalized = service_type
            .trim()
            .trim_end_matches('.')
            .to_ascii_lowercase();

        if normalized.starts_with("_skybridge-remote._tcp") {
            Self::Remote
        } else if normalized.starts_with("_skybridge-transfer._tcp") {
            Self::Transfer
        } else if normalized.starts_with("_skybridge._udp") {
            Self::Quic
        } else if normalized.starts_with("_skybridge._tcp") {
            Self::Control
        } else {
            Self::Unknown
        }
    }
}

#[derive(Debug, Clone)]
struct ServiceIndexEntry {
    device_id: String,
    kind: ServiceKind,
    addresses: Vec<SocketAddr>,
}

/// mDNS browser
pub struct MdnsBrowser {
    daemon: ServiceDaemon,
    discovered: Arc<RwLock<HashMap<String, DiscoveredDevice>>>,
    service_index_by_fullname: Arc<RwLock<HashMap<String, ServiceIndexEntry>>>,
    on_discovered: Option<DeviceDiscoveredCallback>,
    on_removed: Option<DeviceRemovedCallback>,
}

impl MdnsBrowser {
    /// Create a new mDNS browser
    pub fn new() -> Result<Self, mdns_sd::Error> {
        let daemon = ServiceDaemon::new()?;

        Ok(Self {
            daemon,
            discovered: Arc::new(RwLock::new(HashMap::new())),
            service_index_by_fullname: Arc::new(RwLock::new(HashMap::new())),
            on_discovered: None,
            on_removed: None,
        })
    }

    /// Set device discovered callback
    pub fn set_on_discovered(&mut self, callback: DeviceDiscoveredCallback) {
        self.on_discovered = Some(callback);
    }

    /// Set device removed callback
    pub fn set_on_removed(&mut self, callback: DeviceRemovedCallback) {
        self.on_removed = Some(callback);
    }

    /// Start browsing for services
    pub fn start_browse(&self) -> Result<(), mdns_sd::Error> {
        for service_type in [
            SERVICE_TYPE,
            QUIC_SERVICE_TYPE,
            REMOTE_SERVICE_TYPE,
            TRANSFER_SERVICE_TYPE,
        ] {
            let receiver = self.daemon.browse(service_type)?;
            let discovered = self.discovered.clone();
            let service_index_by_fullname = self.service_index_by_fullname.clone();
            let on_discovered = self.on_discovered.clone();
            let on_removed = self.on_removed.clone();
            let runtime = tokio::runtime::Handle::current();

            tokio::task::spawn_blocking(move || {
                loop {
                    match receiver.recv() {
                        Ok(event) => {
                            runtime.block_on(Self::handle_event(
                                event,
                                &discovered,
                                &service_index_by_fullname,
                                on_discovered.as_ref(),
                                on_removed.as_ref(),
                            ));
                        }
                        Err(e) => {
                            error!("mDNS receive error: {:?}", e);
                            break;
                        }
                    }
                }
            });
        }

        info!(
            "Started mDNS browsing for {}, {}, {} and {}",
            SERVICE_TYPE, QUIC_SERVICE_TYPE, REMOTE_SERVICE_TYPE, TRANSFER_SERVICE_TYPE
        );
        Ok(())
    }

    /// Handle mDNS service event
    async fn handle_event(
        event: ServiceEvent,
        discovered: &Arc<RwLock<HashMap<String, DiscoveredDevice>>>,
        service_index_by_fullname: &Arc<RwLock<HashMap<String, ServiceIndexEntry>>>,
        on_discovered: Option<&DeviceDiscoveredCallback>,
        on_removed: Option<&DeviceRemovedCallback>,
    ) {
        match event {
            ServiceEvent::ServiceResolved(info) => {
                let service_kind = ServiceKind::from_service_type(&info.ty_domain);
                let fullname = info.get_fullname().to_string();
                debug!("Service resolved: {} ({:?})", fullname, service_kind);

                if let Some(device) = Self::parse_resolved_service(&info, service_kind) {
                    let device_id = device.device_id.clone();

                    {
                        let mut index = service_index_by_fullname.write().await;
                        index.insert(
                            fullname,
                            ServiceIndexEntry {
                                device_id: device_id.clone(),
                                kind: service_kind,
                                addresses: Self::addresses_for_kind(&device, service_kind),
                            },
                        );
                    }

                    let (merged_device, is_new) = {
                        let mut devices = discovered.write().await;
                        if let Some(existing) = devices.get_mut(&device_id) {
                            Self::merge_device(existing, device, service_kind);
                            (existing.clone(), false)
                        } else {
                            devices.insert(device_id.clone(), device.clone());
                            (device, true)
                        }
                    };

                    if let Some(callback) = on_discovered {
                        callback(&merged_device);
                    }

                    if is_new {
                        info!(
                            "Discovered device: {} ({})",
                            merged_device.name, merged_device.platform
                        );
                    } else {
                        debug!(
                            "Updated device: {} ({})",
                            merged_device.name, merged_device.platform
                        );
                    }
                }
            }
            ServiceEvent::ServiceRemoved(service_type, fullname) => {
                let removed_entry = {
                    let mut index = service_index_by_fullname.write().await;
                    index.remove(&fullname)
                };

                if let Some(removed_entry) = removed_entry {
                    debug!("Service removed: {} ({:?})", fullname, removed_entry.kind);

                    let (still_online, has_kind_remaining) = {
                        let index = service_index_by_fullname.read().await;
                        let still_online = index
                            .values()
                            .any(|entry| entry.device_id == removed_entry.device_id);
                        let has_kind_remaining = index.values().any(|entry| {
                            entry.device_id == removed_entry.device_id
                                && entry.kind == removed_entry.kind
                        });
                        (still_online, has_kind_remaining)
                    };

                    let (device_id, device_name) = {
                        let mut devices = discovered.write().await;
                        if let Some(device) = devices.get_mut(&removed_entry.device_id) {
                            Self::remove_addresses_for_kind(
                                device,
                                removed_entry.kind,
                                &removed_entry.addresses,
                            );
                            if !has_kind_remaining {
                                match removed_entry.kind {
                                    ServiceKind::Control | ServiceKind::Quic => {}
                                    ServiceKind::Remote => {
                                        device.remote_addresses.clear();
                                    }
                                    ServiceKind::Transfer => {
                                        device.transfer_addresses.clear();
                                    }
                                    ServiceKind::Unknown => {}
                                }
                            }
                            if !still_online {
                                device.is_online = false;
                            }
                            (Some(device.device_id.clone()), Some(device.name.clone()))
                        } else {
                            (None, None)
                        }
                    };

                    if !still_online && let Some(device_id) = device_id {
                        if let Some(callback) = on_removed {
                            callback(&device_id);
                        }

                        if let Some(name) = device_name {
                            info!("Device went offline: {}", name);
                        }
                    }
                } else {
                    debug!(
                        "Service removed (unindexed): {} ({})",
                        fullname, service_type
                    );
                }
            }
            ServiceEvent::SearchStarted(_) => {
                debug!("mDNS search started");
            }
            ServiceEvent::SearchStopped(_) => {
                debug!("mDNS search stopped");
            }
            ServiceEvent::ServiceFound(_, _) => {
                // Service found but not yet resolved - wait for ServiceResolved
            }
            _ => {
                debug!("Unhandled mDNS event variant");
            }
        }
    }

    fn dedupe_addresses(addresses: &mut Vec<SocketAddr>) {
        addresses.sort();
        addresses.dedup();
    }

    fn addresses_for_kind(device: &DiscoveredDevice, service_kind: ServiceKind) -> Vec<SocketAddr> {
        match service_kind {
            ServiceKind::Control | ServiceKind::Quic | ServiceKind::Unknown => {
                device.addresses.clone()
            }
            ServiceKind::Remote => device.remote_addresses.clone(),
            ServiceKind::Transfer => device.transfer_addresses.clone(),
        }
    }

    fn merge_device(
        existing: &mut DiscoveredDevice,
        mut incoming: DiscoveredDevice,
        service_kind: ServiceKind,
    ) {
        existing.touch();

        if !incoming.name.trim().is_empty() {
            existing.name = incoming.name;
        }
        if !incoming.public_key_fingerprint.trim().is_empty() {
            existing.public_key_fingerprint = incoming.public_key_fingerprint;
        }
        if incoming.platform != Platform::Unknown {
            existing.platform = incoming.platform;
        }
        if let Some(unique_id) = incoming.unique_id.take()
            && !unique_id.trim().is_empty()
        {
            existing.unique_id = Some(unique_id);
        }
        if let Some(os_version) = incoming.os_version.take()
            && !os_version.trim().is_empty()
        {
            existing.os_version = Some(os_version);
        }
        if !incoming.capabilities.is_empty() {
            existing.capabilities = incoming.capabilities;
        }
        if !incoming.supported_suites.is_empty() {
            existing.supported_suites = incoming.supported_suites;
        }
        if !incoming.remote_video_formats.is_empty() {
            existing.remote_video_formats = incoming.remote_video_formats;
        }
        if !incoming.protocol_version.trim().is_empty() {
            existing.protocol_version = incoming.protocol_version;
        }

        match service_kind {
            ServiceKind::Control | ServiceKind::Quic | ServiceKind::Unknown => {
                for addr in incoming.addresses {
                    existing.addresses.push(addr);
                }
                Self::dedupe_addresses(&mut existing.addresses);
            }
            ServiceKind::Remote => {
                for addr in incoming.remote_addresses {
                    existing.remote_addresses.push(addr);
                }
                Self::dedupe_addresses(&mut existing.remote_addresses);
            }
            ServiceKind::Transfer => {
                for addr in incoming.transfer_addresses {
                    existing.transfer_addresses.push(addr);
                }
                Self::dedupe_addresses(&mut existing.transfer_addresses);
            }
        }
    }

    fn remove_addresses_for_kind(
        device: &mut DiscoveredDevice,
        service_kind: ServiceKind,
        addresses: &[SocketAddr],
    ) {
        let remove_set: std::collections::HashSet<SocketAddr> = addresses.iter().copied().collect();
        match service_kind {
            ServiceKind::Control | ServiceKind::Quic | ServiceKind::Unknown => {
                device.addresses.retain(|addr| !remove_set.contains(addr));
            }
            ServiceKind::Remote => {
                device
                    .remote_addresses
                    .retain(|addr| !remove_set.contains(addr));
            }
            ServiceKind::Transfer => {
                device
                    .transfer_addresses
                    .retain(|addr| !remove_set.contains(addr));
            }
        }
    }

    fn parse_common(
        properties: &mdns_sd::TxtProperties,
        addresses: Vec<SocketAddr>,
    ) -> Option<DiscoveredDevice> {
        let device_id = get_txt_value(
            properties,
            &[
                txt_fields::DEVICE_ID,
                "deviceid",
                "device_id",
                "id",
                "deviceID",
            ],
        )?;
        let unique_id = get_txt_value(
            properties,
            &[txt_fields::UNIQUE_ID, "uniqueid", "unique_id", "uid"],
        )
        .or_else(|| Some(device_id.clone()));
        let name = get_txt_value(properties, &[txt_fields::NAME, "device", "fn"])
            .unwrap_or_else(|| device_id.clone());
        let pub_key_fp = get_txt_value(
            properties,
            &[txt_fields::PUB_KEY_FP, "pubkeyfp", "pub_key_fp", "fp"],
        )
        .unwrap_or_default();
        let platform = get_txt_value(properties, &[txt_fields::PLATFORM, "os"])
            .map(|v| Platform::from_str(&v))
            .unwrap_or(Platform::Unknown);
        let os_version = get_txt_value(
            properties,
            &[txt_fields::OS_VERSION, "osversion", "os_version", "osv"],
        );

        let capabilities = get_txt_value(properties, &[txt_fields::CAPABILITIES, "cap"])
            .map(|v| DiscoveredDevice::parse_capabilities(&v))
            .unwrap_or_default();

        let version = get_txt_value(properties, &[txt_fields::VERSION, "ver"])
            .unwrap_or_else(|| crate::PROTOCOL_VERSION.to_string());

        let supported_suites = get_txt_value(
            properties,
            &[txt_fields::CRYPTO_SUITES, "cryptosuites", "suites"],
        )
        .map(|v| DiscoveredDevice::parse_crypto_suites(&v))
        .unwrap_or_else(|| crate::crypto::suite::CryptoSuiteId::classic().to_vec());
        let remote_video_formats = get_txt_value(
            properties,
            &[
                txt_fields::REMOTE_VIDEO_FORMATS,
                "remotevideoformats",
                "remote_video_formats",
                "remoteformats",
            ],
        )
        .map(|v| DiscoveredDevice::parse_remote_video_formats(&v))
        .unwrap_or_default();

        let mut device = DiscoveredDevice::new(device_id, name, pub_key_fp.clone(), platform);
        device.unique_id = unique_id;
        device.os_version = os_version;
        device.capabilities = capabilities;
        device.supported_suites = supported_suites;
        device.protocol_version = version;
        device.remote_video_formats = remote_video_formats;
        device.addresses = addresses;

        if !pub_key_fp.is_empty()
            && let Ok(mut store) = TrustStore::load()
        {
            let _ = store.upsert_peer_fingerprint(&device.device_id, &pub_key_fp);
        }

        Some(device)
    }

    /// Parse resolved service info into DiscoveredDevice
    fn parse_resolved_service(
        info: &ResolvedService,
        service_kind: ServiceKind,
    ) -> Option<DiscoveredDevice> {
        let addresses: Vec<SocketAddr> = info
            .get_addresses()
            .iter()
            .map(|addr| SocketAddr::new(addr.to_ip_addr(), info.get_port()))
            .collect();
        let mut device = Self::parse_common(info.get_properties(), addresses)?;
        match service_kind {
            ServiceKind::Control | ServiceKind::Quic | ServiceKind::Unknown => {}
            ServiceKind::Remote => {
                device.remote_addresses = device.addresses.clone();
                device.addresses.clear();
            }
            ServiceKind::Transfer => {
                device.transfer_addresses = device.addresses.clone();
                device.addresses.clear();
            }
        }
        Some(device)
    }

    /// Parse service info into DiscoveredDevice
    #[cfg(test)]
    fn parse_service_info(info: &ServiceInfo) -> Option<DiscoveredDevice> {
        Self::parse_service_info_with_kind(info, ServiceKind::Control)
    }

    /// Parse service info with explicit service kind (tests)
    #[cfg(test)]
    fn parse_service_info_with_kind(
        info: &ServiceInfo,
        service_kind: ServiceKind,
    ) -> Option<DiscoveredDevice> {
        let addresses: Vec<SocketAddr> = info
            .get_addresses()
            .iter()
            .map(|addr| SocketAddr::new(*addr, info.get_port()))
            .collect();
        let mut device = Self::parse_common(info.get_properties(), addresses)?;
        match service_kind {
            ServiceKind::Control | ServiceKind::Quic | ServiceKind::Unknown => {}
            ServiceKind::Remote => {
                device.remote_addresses = device.addresses.clone();
                device.addresses.clear();
            }
            ServiceKind::Transfer => {
                device.transfer_addresses = device.addresses.clone();
                device.addresses.clear();
            }
        }
        Some(device)
    }

    /// Get discovered devices
    pub async fn devices(&self) -> Vec<DiscoveredDevice> {
        let devices = self.discovered.read().await;
        devices.values().cloned().collect()
    }

    /// Get online devices only
    pub async fn online_devices(&self) -> Vec<DiscoveredDevice> {
        let devices = self.discovered.read().await;
        devices.values().filter(|d| d.is_online).cloned().collect()
    }

    /// Get device by ID
    pub async fn get_device(&self, device_id: &str) -> Option<DiscoveredDevice> {
        let devices = self.discovered.read().await;
        devices.get(device_id).cloned()
    }

    /// Clear all discovered devices
    #[allow(dead_code)]
    pub async fn clear(&self) {
        let mut devices = self.discovered.write().await;
        devices.clear();
    }
}

/// mDNS service advertiser
pub struct MdnsAdvertiser {
    daemon: ServiceDaemon,
    service_fullnames: Vec<String>,
    current_ports: HashMap<String, u16>,
}

impl MdnsAdvertiser {
    /// Create a new mDNS advertiser
    pub fn new() -> Result<Self, mdns_sd::Error> {
        let daemon = ServiceDaemon::new()?;

        Ok(Self {
            daemon,
            service_fullnames: Vec::new(),
            current_ports: HashMap::new(),
        })
    }

    /// Get system hostname safely
    fn get_hostname() -> String {
        hostname::get()
            .map(|h| h.to_string_lossy().to_string())
            .unwrap_or_else(|e| {
                warn!("Failed to get hostname: {}, using fallback", e);
                "skybridge-device".to_string()
            })
    }

    /// Start advertising our service
    pub fn advertise(
        &mut self,
        device: &DiscoveredDevice,
        port: u16,
        remote_port: Option<u16>,
        transfer_port: Option<u16>,
    ) -> Result<(), mdns_sd::Error> {
        // Mirror macOS/iOS: advertise both TCP (_skybridge._tcp) and QUIC/UDP (_skybridge._udp)
        // control endpoints on the same port number.
        let mut services = vec![
            (SERVICE_TYPE.to_string(), port),
            (QUIC_SERVICE_TYPE.to_string(), port),
        ];
        if let Some(remote) = remote_port.filter(|p| *p > 0) {
            services.push((REMOTE_SERVICE_TYPE.to_string(), remote));
        }
        if let Some(transfer) = transfer_port.filter(|p| *p > 0) {
            services.push((TRANSFER_SERVICE_TYPE.to_string(), transfer));
        }
        self.advertise_services(device, &services)
    }

    fn advertise_services(
        &mut self,
        device: &DiscoveredDevice,
        services: &[(String, u16)],
    ) -> Result<(), mdns_sd::Error> {
        // Stop any existing advertisement
        if !self.service_fullnames.is_empty() {
            self.stop()?;
        }

        let instance_name = &device.device_id;
        let hostname = Self::get_hostname();

        let mut properties = HashMap::new();
        properties.insert(txt_fields::DEVICE_ID.to_string(), device.device_id.clone());
        properties.insert(txt_fields::NAME.to_string(), device.name.clone());
        properties.insert(
            txt_fields::PUB_KEY_FP.to_string(),
            device.public_key_fingerprint.clone(),
        );
        properties.insert(
            txt_fields::UNIQUE_ID.to_string(),
            device
                .unique_id
                .clone()
                .unwrap_or_else(|| device.device_id.clone()),
        );
        properties.insert(
            txt_fields::PLATFORM.to_string(),
            device.platform.as_str().to_string(),
        );
        properties.insert(
            txt_fields::CAPABILITIES.to_string(),
            device.capabilities_string(),
        );
        properties.insert(
            txt_fields::VERSION.to_string(),
            device.protocol_version.clone(),
        );
        properties.insert(
            txt_fields::CRYPTO_SUITES.to_string(),
            device.crypto_suites_string(),
        );
        if !device.remote_video_formats.is_empty() {
            properties.insert(
                txt_fields::REMOTE_VIDEO_FORMATS.to_string(),
                device.remote_video_formats_string(),
            );
        }
        if let Some(os_version) = device
            .os_version
            .clone()
            .or_else(|| std::env::var("SKYBRIDGE_OS_VERSION").ok())
            && !os_version.trim().is_empty()
        {
            properties.insert(txt_fields::OS_VERSION.to_string(), os_version);
        }

        for (service_type, port) in services {
            let mut properties_for_service = properties.clone();
            properties_for_service.insert("port".to_string(), port.to_string());
            if service_type == TRANSFER_SERVICE_TYPE {
                properties_for_service.insert("transferPort".to_string(), port.to_string());
            }
            if service_type == REMOTE_SERVICE_TYPE {
                properties_for_service.insert("remotePort".to_string(), port.to_string());
            }
            let service_info = ServiceInfo::new(
                service_type.as_str(),
                instance_name,
                &format!("{}.local.", hostname),
                "",
                *port,
                properties_for_service,
            )?;

            let fullname = service_info.get_fullname().to_string();
            self.daemon.register(service_info)?;
            self.service_fullnames.push(fullname.clone());
            self.current_ports.insert(service_type.to_string(), *port);

            info!("Advertising mDNS service: {} on port {}", fullname, port);
        }

        Ok(())
    }

    /// Re-advertise with updated device info
    pub fn re_advertise(&mut self, device: &DiscoveredDevice) -> Result<(), mdns_sd::Error> {
        if self.current_ports.is_empty() {
            return Err(mdns_sd::Error::Again);
        }
        let services: Vec<(String, u16)> = self
            .current_ports
            .iter()
            .map(|(k, v)| (k.clone(), *v))
            .collect();
        self.advertise_services(device, &services)
    }

    /// Stop advertising
    pub fn stop(&mut self) -> Result<(), mdns_sd::Error> {
        for fullname in self.service_fullnames.drain(..) {
            let _ = self.daemon.unregister(&fullname);
        }
        self.current_ports.clear();
        info!("Stopped advertising mDNS services");
        Ok(())
    }

    /// Check if currently advertising
    #[allow(dead_code)]
    pub fn is_advertising(&self) -> bool {
        !self.service_fullnames.is_empty()
    }
}

impl Drop for MdnsAdvertiser {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::path::PathBuf;

    fn protocol_sample_path(file_name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../docs/mac-baseline/protocol-samples")
            .join(file_name)
    }

    #[test]
    fn test_service_type() {
        assert!(SERVICE_TYPE.starts_with("_skybridge."));
        assert!(SERVICE_TYPE.ends_with(".local."));
        assert!(QUIC_SERVICE_TYPE.starts_with("_skybridge."));
        assert!(QUIC_SERVICE_TYPE.ends_with(".local."));
    }

    #[test]
    fn test_get_hostname() {
        let hostname = MdnsAdvertiser::get_hostname();
        assert!(!hostname.is_empty());
    }

    #[test]
    fn test_parse_service_info_accepts_pro_release_fields() {
        let mut props = HashMap::new();
        props.insert(txt_fields::DEVICE_ID.to_string(), "dev-1".to_string());
        props.insert(txt_fields::PUB_KEY_FP.to_string(), "fp-1".to_string());
        props.insert(txt_fields::UNIQUE_ID.to_string(), "uid-1".to_string());
        props.insert(txt_fields::NAME.to_string(), "Device One".to_string());
        props.insert(txt_fields::PLATFORM.to_string(), "macos".to_string());
        props.insert(txt_fields::OS_VERSION.to_string(), "macOS 26.2".to_string());

        let info = ServiceInfo::new(SERVICE_TYPE, "dev-1", "host.local.", "", 1234, props)
            .expect("service info");
        let device = MdnsBrowser::parse_service_info(&info).expect("parsed device");
        assert_eq!(device.device_id, "dev-1");
        assert_eq!(device.unique_id.as_deref(), Some("uid-1"));
        assert_eq!(device.name, "Device One");
        assert_eq!(device.public_key_fingerprint, "fp-1");
        assert_eq!(device.platform, Platform::MacOS);
        assert_eq!(device.os_version.as_deref(), Some("macOS 26.2"));
    }

    #[test]
    fn test_parse_service_info_accepts_alias_fields() {
        let mut props = HashMap::new();
        props.insert("device_id".to_string(), "dev-2".to_string());
        props.insert("pub_key_fp".to_string(), "fp-2".to_string());
        props.insert("unique_id".to_string(), "uid-2".to_string());
        props.insert("fn".to_string(), "Fn Device".to_string());
        props.insert("os".to_string(), "windows".to_string());
        props.insert("os_version".to_string(), "Windows 11".to_string());

        let info = ServiceInfo::new(SERVICE_TYPE, "dev-2", "host.local.", "", 1234, props)
            .expect("service info");
        let device = MdnsBrowser::parse_service_info(&info).expect("parsed device");
        assert_eq!(device.device_id, "dev-2");
        assert_eq!(device.unique_id.as_deref(), Some("uid-2"));
        assert_eq!(device.name, "Fn Device");
        assert_eq!(device.public_key_fingerprint, "fp-2");
        assert_eq!(device.platform, Platform::Windows);
        assert_eq!(device.os_version.as_deref(), Some("Windows 11"));
    }

    #[test]
    fn test_parse_service_info_accepts_remote_video_formats_alias() {
        let mut props = HashMap::new();
        props.insert("device_id".to_string(), "dev-3".to_string());
        props.insert("pub_key_fp".to_string(), "fp-3".to_string());
        props.insert(
            "remote_video_formats".to_string(),
            "jpeg,h264,hevc".to_string(),
        );

        let info = ServiceInfo::new(SERVICE_TYPE, "dev-3", "host.local.", "", 1234, props)
            .expect("service info");
        let device = MdnsBrowser::parse_service_info(&info).expect("parsed device");
        assert_eq!(
            device.remote_video_formats,
            vec!["jpeg".to_string(), "h264".to_string(), "hevc".to_string()]
        );
    }

    #[test]
    fn test_parse_service_info_matches_mac_baseline_alias_sample() {
        let sample_path = protocol_sample_path("discovery_txt_aliases.json");
        let raw = std::fs::read_to_string(&sample_path)
            .unwrap_or_else(|err| panic!("failed to read {}: {}", sample_path.display(), err));
        let parsed: Value = serde_json::from_str(&raw)
            .unwrap_or_else(|err| panic!("failed to parse {}: {}", sample_path.display(), err));
        let canonical = parsed
            .get("canonical")
            .and_then(Value::as_object)
            .expect("canonical sample object");
        let aliases = parsed
            .get("aliases")
            .and_then(Value::as_object)
            .expect("aliases sample object");

        let mut props = HashMap::new();
        for (key, value) in aliases {
            props.insert(key.clone(), value.as_str().unwrap_or_default().to_string());
        }

        let info = ServiceInfo::new(SERVICE_TYPE, "sample-dev", "host.local.", "", 1234, props)
            .expect("service info from baseline aliases");
        let device = MdnsBrowser::parse_service_info(&info).expect("parsed device");

        assert_eq!(
            device.device_id,
            canonical
                .get("deviceId")
                .and_then(Value::as_str)
                .expect("canonical deviceId")
        );
        assert_eq!(
            device.name,
            canonical
                .get("name")
                .and_then(Value::as_str)
                .expect("canonical name")
        );
        assert_eq!(
            device.public_key_fingerprint,
            canonical
                .get("pubKeyFP")
                .and_then(Value::as_str)
                .expect("canonical pubKeyFP")
        );
        assert_eq!(
            device.unique_id.as_deref(),
            canonical.get("uniqueId").and_then(Value::as_str)
        );
        assert_eq!(
            device.platform,
            Platform::parse_lossy(
                canonical
                    .get("platform")
                    .and_then(Value::as_str)
                    .expect("canonical platform")
            )
        );
        assert_eq!(
            device.os_version.as_deref(),
            canonical.get("osVersion").and_then(Value::as_str)
        );
    }

    #[test]
    fn test_parse_service_info_remote_endpoint_maps_to_remote_addresses() {
        let mut props = HashMap::new();
        props.insert(
            txt_fields::DEVICE_ID.to_string(),
            "dev-remote-1".to_string(),
        );
        props.insert(
            txt_fields::PUB_KEY_FP.to_string(),
            "fp-remote-1".to_string(),
        );
        props.insert(txt_fields::NAME.to_string(), "Remote Device".to_string());
        props.insert(txt_fields::PLATFORM.to_string(), "macos".to_string());

        let info = ServiceInfo::new(
            REMOTE_SERVICE_TYPE,
            "dev-remote-1",
            "host.local.",
            "192.168.1.50",
            5901,
            props,
        )
        .expect("service info");
        let device = MdnsBrowser::parse_service_info_with_kind(&info, ServiceKind::Remote)
            .expect("parsed device");
        assert!(device.addresses.is_empty());
        assert_eq!(device.remote_addresses.len(), 1);
        assert_eq!(
            device.remote_addresses[0].port(),
            5901,
            "remote service port should map to remote endpoint"
        );
    }

    #[test]
    fn test_service_removed_keeps_device_online_if_other_service_is_still_present() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let discovered: Arc<RwLock<HashMap<String, DiscoveredDevice>>> =
                Arc::new(RwLock::new(HashMap::new()));
            let service_index_by_fullname: Arc<RwLock<HashMap<String, ServiceIndexEntry>>> =
                Arc::new(RwLock::new(HashMap::new()));

            let mut props = HashMap::new();
            props.insert(txt_fields::DEVICE_ID.to_string(), "dev-mac-1".to_string());
            props.insert(txt_fields::PUB_KEY_FP.to_string(), "fp-mac-1".to_string());
            props.insert(txt_fields::NAME.to_string(), "My Mac".to_string());
            props.insert(txt_fields::PLATFORM.to_string(), "macos".to_string());

            let control_info = ServiceInfo::new(
                SERVICE_TYPE,
                "My Mac",
                "host.local.",
                "192.168.1.51",
                1234,
                props.clone(),
            )
            .expect("control service info");
            let control_fullname = control_info.get_fullname().to_string();
            MdnsBrowser::handle_event(
                ServiceEvent::ServiceResolved(Box::new(control_info.as_resolved_service())),
                &discovered,
                &service_index_by_fullname,
                None,
                None,
            )
            .await;

            let remote_info = ServiceInfo::new(
                REMOTE_SERVICE_TYPE,
                "My Mac",
                "host.local.",
                "192.168.1.51",
                5901,
                props,
            )
            .expect("remote service info");
            let remote_fullname = remote_info.get_fullname().to_string();
            MdnsBrowser::handle_event(
                ServiceEvent::ServiceResolved(Box::new(remote_info.as_resolved_service())),
                &discovered,
                &service_index_by_fullname,
                None,
                None,
            )
            .await;

            MdnsBrowser::handle_event(
                ServiceEvent::ServiceRemoved(SERVICE_TYPE.to_string(), control_fullname),
                &discovered,
                &service_index_by_fullname,
                None,
                None,
            )
            .await;

            {
                let devices = discovered.read().await;
                let device = devices.get("dev-mac-1").expect("device present");
                assert!(
                    device.is_online,
                    "device should remain online while remote service is still active"
                );
                assert_eq!(
                    device.best_remote_address().map(SocketAddr::port),
                    Some(5901)
                );
            }

            MdnsBrowser::handle_event(
                ServiceEvent::ServiceRemoved(REMOTE_SERVICE_TYPE.to_string(), remote_fullname),
                &discovered,
                &service_index_by_fullname,
                None,
                None,
            )
            .await;

            let devices = discovered.read().await;
            let device = devices.get("dev-mac-1").expect("device still present");
            assert!(
                !device.is_online,
                "device should go offline after the last indexed service is removed"
            );
        });
    }

    #[test]
    fn test_service_removed_uses_fullname_index_instead_of_instance_name() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let discovered: Arc<RwLock<HashMap<String, DiscoveredDevice>>> =
                Arc::new(RwLock::new(HashMap::new()));
            let service_index_by_fullname: Arc<RwLock<HashMap<String, ServiceIndexEntry>>> =
                Arc::new(RwLock::new(HashMap::new()));

            // Simulate a macOS instance name that does NOT equal the stable deviceId.
            let mut props = HashMap::new();
            props.insert(txt_fields::DEVICE_ID.to_string(), "dev-mac-1".to_string());
            props.insert(txt_fields::PUB_KEY_FP.to_string(), "fp-mac-1".to_string());
            props.insert(txt_fields::NAME.to_string(), "My Mac".to_string());
            props.insert(txt_fields::PLATFORM.to_string(), "macos".to_string());

            let info = ServiceInfo::new(SERVICE_TYPE, "My Mac", "host.local.", "", 1234, props)
                .expect("service info");
            let fullname = info.get_fullname().to_string();

            MdnsBrowser::handle_event(
                ServiceEvent::ServiceResolved(Box::new(info.as_resolved_service())),
                &discovered,
                &service_index_by_fullname,
                None,
                None,
            )
            .await;

            {
                let devices = discovered.read().await;
                let device = devices.get("dev-mac-1").expect("device inserted");
                assert!(device.is_online);
            }

            MdnsBrowser::handle_event(
                ServiceEvent::ServiceRemoved(SERVICE_TYPE.to_string(), fullname),
                &discovered,
                &service_index_by_fullname,
                None,
                None,
            )
            .await;

            let devices = discovered.read().await;
            let device = devices.get("dev-mac-1").expect("device still present");
            assert!(!device.is_online);
        });
    }
}
