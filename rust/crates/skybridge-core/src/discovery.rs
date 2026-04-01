use std::collections::BTreeMap;
use std::net::IpAddr;
use std::time::{Duration, Instant};

use anyhow::Result;
use if_addrs::get_if_addrs;
use mdns_sd::{ResolvedService, ServiceDaemon, ServiceEvent, ServiceInfo, TxtProperty};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

pub const SKYBRIDGE_DISCOVERY_SERVICE_TYPE: &str = "_skybridge._tcp";
pub const SKYBRIDGE_FILE_TRANSFER_SERVICE_TYPE: &str = "_skybridge-transfer._tcp";
const LOCAL_DOMAIN: &str = "local.";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NearbyPeer {
    pub peer_id: String,
    pub device_id: Option<String>,
    pub device_name: String,
    pub service_name: String,
    pub advertised_services: Vec<String>,
    pub host_name: String,
    pub addresses: Vec<String>,
    pub port: u16,
    pub transfer_port: Option<u16>,
    pub platform: Option<String>,
    pub capabilities: Vec<String>,
    #[serde(with = "time::serde::rfc3339")]
    pub discovered_at: OffsetDateTime,
}

impl NearbyPeer {
    pub fn primary_address(&self) -> Option<&str> {
        self.addresses
            .iter()
            .find(|address| address.parse::<std::net::Ipv4Addr>().is_ok())
            .map(String::as_str)
            .or_else(|| self.addresses.first().map(String::as_str))
    }

    pub fn is_transfer_capable(&self) -> bool {
        self.transfer_port.is_some()
            || self
                .capabilities
                .iter()
                .any(|capability| capability.eq_ignore_ascii_case("file_transfer"))
            || self
                .advertised_services
                .iter()
                .any(|service| service == SKYBRIDGE_FILE_TRANSFER_SERVICE_TYPE)
    }
}

pub struct DiscoveryAdvertisement {
    daemon: ServiceDaemon,
    service_fullname: String,
    service_type: String,
}

impl DiscoveryAdvertisement {
    pub fn shutdown(&self) {
        let _ = self.daemon.unregister(&self.service_fullname);
        let _ = self.daemon.stop_browse(&self.service_type);
        let _ = self.daemon.shutdown();
    }
}

impl Drop for DiscoveryAdvertisement {
    fn drop(&mut self) {
        self.shutdown();
    }
}

pub async fn discover_nearby_peers(timeout: Duration) -> Result<Vec<NearbyPeer>> {
    discover_services(timeout, &[
        SKYBRIDGE_DISCOVERY_SERVICE_TYPE,
        SKYBRIDGE_FILE_TRANSFER_SERVICE_TYPE,
    ])
    .await
}

pub async fn discover_file_transfer_peers(timeout: Duration) -> Result<Vec<NearbyPeer>> {
    let peers = discover_services(timeout, &[SKYBRIDGE_FILE_TRANSFER_SERVICE_TYPE]).await?;
    Ok(peers
        .into_iter()
        .filter(NearbyPeer::is_transfer_capable)
        .collect())
}

pub fn advertise_file_transfer_service(
    instance_name: &str,
    device_name: &str,
    device_id: Option<&str>,
    public_key_fingerprint: Option<&str>,
    port: u16,
) -> Result<DiscoveryAdvertisement> {
    let daemon = ServiceDaemon::new()?;
    let service_type = full_service_type(SKYBRIDGE_FILE_TRANSFER_SERVICE_TYPE);
    let hostname = format!("{}.local.", sanitized_hostname());
    let unique_id = device_id
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(device_name)
        .trim();
    let mut properties = vec![
        ("platform", std::env::consts::OS.to_ascii_lowercase()),
        ("name", device_name.trim().to_owned()),
        ("model", current_model_hint()),
        ("capabilities", "file_transfer".to_owned()),
        ("transferPort", port.to_string()),
        ("port", port.to_string()),
        ("uniqueId", unique_id.to_owned()),
    ];
    if let Some(device_id) = device_id.filter(|value| !value.trim().is_empty()) {
        properties.push(("deviceId", device_id.trim().to_owned()));
    }
    if let Some(fingerprint) = public_key_fingerprint.filter(|value| !value.trim().is_empty()) {
        properties.push(("pubKeyFP", fingerprint.trim().to_owned()));
    }
    let properties = properties
        .into_iter()
        .map(|(key, value)| TxtProperty::from((key, value)))
        .collect::<Vec<_>>();

    let advertised_addresses = advertised_ip_addresses();
    let address_list = advertised_addresses
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(",");
    let service_info = ServiceInfo::new(
        &service_type,
        instance_name.trim(),
        &hostname,
        address_list,
        port,
        properties,
    )?;
    let service_fullname = service_info.get_fullname().to_owned();
    daemon.register(service_info)?;
    Ok(DiscoveryAdvertisement {
        daemon,
        service_fullname,
        service_type,
    })
}

async fn discover_services(timeout: Duration, service_types: &[&str]) -> Result<Vec<NearbyPeer>> {
    let requested = service_types
        .iter()
        .map(|value| value.to_string())
        .collect::<Vec<_>>();
    tokio::task::spawn_blocking(move || -> Result<Vec<NearbyPeer>> {
        let daemon = ServiceDaemon::new()?;
        let mut browsers = Vec::new();
        for service_type in requested {
            let full = full_service_type(&service_type);
            let receiver = daemon.browse(&full)?;
            browsers.push((service_type, full, receiver));
        }

        let deadline = Instant::now() + timeout;
        let mut peers = BTreeMap::<String, NearbyPeer>::new();
        while Instant::now() < deadline {
            for (service_type, _, receiver) in &browsers {
                if let Ok(ServiceEvent::ServiceResolved(info)) =
                    receiver.recv_timeout(Duration::from_millis(200))
                {
                    let discovered = nearby_peer_from_service_info(service_type, &info);
                    let key = discovered.peer_id.clone();
                    peers
                        .entry(key)
                        .and_modify(|existing| merge_peer(existing, &discovered))
                        .or_insert(discovered);
                }
            }
        }

        for (_, full, _) in &browsers {
            let _ = daemon.stop_browse(full);
        }
        let _ = daemon.shutdown();

        let mut resolved = peers.into_values().collect::<Vec<_>>();
        resolved.sort_by(|lhs, rhs| {
            lhs.device_name
                .to_ascii_lowercase()
                .cmp(&rhs.device_name.to_ascii_lowercase())
                .then(lhs.peer_id.cmp(&rhs.peer_id))
        });
        Ok(resolved)
    })
    .await?
}

fn merge_peer(existing: &mut NearbyPeer, discovered: &NearbyPeer) {
    for service in &discovered.advertised_services {
        if !existing.advertised_services.contains(service) {
            existing.advertised_services.push(service.clone());
        }
    }
    existing.advertised_services.sort();
    existing.advertised_services.dedup();

    for capability in &discovered.capabilities {
        if !existing.capabilities.contains(capability) {
            existing.capabilities.push(capability.clone());
        }
    }
    existing.capabilities.sort();
    existing.capabilities.dedup();

    for address in &discovered.addresses {
        if !existing.addresses.contains(address) {
            existing.addresses.push(address.clone());
        }
    }
    existing.addresses.sort_by(|lhs, rhs| {
        rhs.parse::<std::net::Ipv4Addr>()
            .is_ok()
            .cmp(&lhs.parse::<std::net::Ipv4Addr>().is_ok())
            .then(lhs.cmp(rhs))
    });
    existing.addresses.dedup();

    if existing.device_id.is_none() {
        existing.device_id = discovered.device_id.clone();
    }
    if existing.transfer_port.is_none() {
        existing.transfer_port = discovered.transfer_port;
    }
    if existing.platform.is_none() {
        existing.platform = discovered.platform.clone();
    }
    if existing.device_name.trim().is_empty() {
        existing.device_name = discovered.device_name.clone();
    }
    if existing.port == 0 {
        existing.port = discovered.port;
    }
    if existing.host_name.trim().is_empty() {
        existing.host_name = discovered.host_name.clone();
    }
}

fn nearby_peer_from_service_info(service_type: &str, info: &ResolvedService) -> NearbyPeer {
    let service_name = parse_service_name(info.get_fullname());
    let addresses = {
        let mut rendered = info
            .get_addresses()
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        rendered.sort_by(|lhs, rhs| {
            rhs.parse::<std::net::Ipv4Addr>()
                .is_ok()
                .cmp(&lhs.parse::<std::net::Ipv4Addr>().is_ok())
                .then(lhs.cmp(rhs))
        });
        rendered
    };
    let device_id = property_string(info, "deviceId");
    let device_name = property_string(info, "name")
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| service_name.clone());
    let transfer_port = property_string(info, "transferPort")
        .or_else(|| property_string(info, "port"))
        .and_then(|value| value.parse::<u16>().ok())
        .or(Some(info.get_port()));
    let capabilities = property_string(info, "capabilities")
        .map(|value| {
            value
                .split(',')
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let peer_id = device_id
        .clone()
        .unwrap_or_else(|| info.get_fullname().to_owned());
    NearbyPeer {
        peer_id,
        device_id,
        device_name,
        service_name,
        advertised_services: vec![service_type.to_owned()],
        host_name: info.get_hostname().to_owned(),
        addresses,
        port: info.get_port(),
        transfer_port,
        platform: property_string(info, "platform"),
        capabilities,
        discovered_at: OffsetDateTime::now_utc(),
    }
}

fn property_string(info: &ResolvedService, key: &str) -> Option<String> {
    info.get_property_val_str(key)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn parse_service_name(fullname: &str) -> String {
    fullname
        .split('.')
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fullname)
        .to_owned()
}

fn full_service_type(service_type: &str) -> String {
    if service_type.ends_with(".local.") {
        service_type.to_owned()
    } else if service_type.ends_with('.') {
        format!("{service_type}{LOCAL_DOMAIN}")
    } else {
        format!("{service_type}.{LOCAL_DOMAIN}")
    }
}

fn sanitized_hostname() -> String {
    hostname::get()
        .ok()
        .and_then(|value| value.into_string().ok())
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .map(|value| {
            value
                .chars()
                .map(|ch| {
                    if ch.is_ascii_alphanumeric() || ch == '-' {
                        ch.to_ascii_lowercase()
                    } else {
                        '-'
                    }
                })
                .collect::<String>()
        })
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "skybridge-host".to_owned())
}

fn current_model_hint() -> String {
    match std::env::consts::OS {
        "macos" => "Mac",
        "windows" => "WindowsPC",
        "linux" => "LinuxHost",
        other => other,
    }
    .to_owned()
}

fn advertised_ip_addresses() -> Vec<IpAddr> {
    let mut addresses = get_if_addrs()
        .ok()
        .into_iter()
        .flatten()
        .filter_map(|interface| {
            let ip = interface.ip();
            if ip.is_loopback() {
                None
            } else {
                Some(ip)
            }
        })
        .collect::<Vec<_>>();
    if addresses.is_empty() {
        addresses.push(IpAddr::V4(std::net::Ipv4Addr::LOCALHOST));
    }
    addresses.sort_by(|lhs, rhs| rhs.is_ipv4().cmp(&lhs.is_ipv4()).then(lhs.cmp(rhs)));
    addresses.dedup();
    addresses
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nearby_peer_prefers_ipv4_primary_address() {
        let peer = NearbyPeer {
            peer_id: "device-a".to_owned(),
            device_id: Some("device-a".to_owned()),
            device_name: "Device A".to_owned(),
            service_name: "Device A".to_owned(),
            advertised_services: vec![SKYBRIDGE_FILE_TRANSFER_SERVICE_TYPE.to_owned()],
            host_name: "device-a.local.".to_owned(),
            addresses: vec!["fe80::1".to_owned(), "192.168.1.20".to_owned()],
            port: 8080,
            transfer_port: Some(8080),
            platform: Some("macos".to_owned()),
            capabilities: vec!["file_transfer".to_owned()],
            discovered_at: OffsetDateTime::now_utc(),
        };

        assert_eq!(peer.primary_address(), Some("192.168.1.20"));
        assert!(peer.is_transfer_capable());
    }
}
