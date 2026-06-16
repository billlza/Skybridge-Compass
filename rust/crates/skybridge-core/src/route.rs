use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PresenceRouteSource {
    Inbound,
    Outbound,
    Presence,
    Webrtc,
    Compatibility,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresenceRouteDescriptor {
    pub peer_id: String,
    pub device_name: String,
    pub display_address: String,
    pub transfer_address: String,
    pub transfer_port: u16,
    pub route_source: PresenceRouteSource,
    #[serde(with = "time::serde::rfc3339")]
    pub connected_at: OffsetDateTime,
}

impl PresenceRouteDescriptor {
    pub fn is_complete(&self) -> bool {
        !self.peer_id.trim().is_empty()
            && !self.device_name.trim().is_empty()
            && !self.display_address.trim().is_empty()
            && !self.transfer_address.trim().is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActiveConnection {
    pub id: String,
    pub display_name: String,
    pub address: Option<String>,
    pub crypto_kind: String,
    pub suite: String,
    #[serde(with = "time::serde::rfc3339")]
    pub connected_at: OffsetDateTime,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresenceRegistry {
    pub active_connections: BTreeMap<String, ActiveConnection>,
    pub route_descriptors_by_peer_id: BTreeMap<String, PresenceRouteDescriptor>,
}

impl PresenceRegistry {
    pub fn mark_connected(
        &mut self,
        peer_id: impl Into<String>,
        display_name: impl Into<String>,
        address: Option<String>,
        crypto_kind: impl Into<String>,
        suite: impl Into<String>,
    ) {
        let peer_id = peer_id.into();
        let display_name = display_name.into();
        let connection = ActiveConnection {
            id: peer_id.clone(),
            display_name: display_name.clone(),
            address: address.clone(),
            crypto_kind: crypto_kind.into(),
            suite: suite.into(),
            connected_at: OffsetDateTime::now_utc(),
        };
        self.active_connections.insert(peer_id.clone(), connection);

        if !self.route_descriptors_by_peer_id.contains_key(&peer_id)
            && let Some(address) = address.and_then(|address| sanitize_address(Some(address)))
        {
            self.route_descriptors_by_peer_id.insert(
                peer_id.clone(),
                PresenceRouteDescriptor {
                    peer_id,
                    device_name: display_name,
                    display_address: address.clone(),
                    transfer_address: address,
                    transfer_port: 8080,
                    route_source: PresenceRouteSource::Compatibility,
                    connected_at: OffsetDateTime::now_utc(),
                },
            );
        }
    }

    pub fn publish_connected_atomically(
        &mut self,
        peer_id: impl Into<String>,
        display_name: impl Into<String>,
        address: Option<String>,
        crypto_kind: impl Into<String>,
        suite: impl Into<String>,
        route_descriptor: PresenceRouteDescriptor,
    ) -> bool {
        if !route_descriptor.is_complete() {
            return false;
        }

        let peer_id = peer_id.into();
        let display_name = display_name.into();
        self.route_descriptors_by_peer_id
            .insert(peer_id.clone(), route_descriptor.clone());
        self.active_connections.insert(
            peer_id.clone(),
            ActiveConnection {
                id: peer_id,
                display_name,
                address: address.or(Some(route_descriptor.display_address.clone())),
                crypto_kind: crypto_kind.into(),
                suite: suite.into(),
                connected_at: route_descriptor.connected_at,
            },
        );
        true
    }

    pub fn mark_disconnected(&mut self, peer_id: &str) {
        self.active_connections.remove(peer_id);
        self.route_descriptors_by_peer_id.remove(peer_id);
    }

    pub fn active_route_descriptors(&self) -> Vec<PresenceRouteDescriptor> {
        self.route_descriptors_by_peer_id
            .values()
            .cloned()
            .collect::<Vec<_>>()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActivePeerRoute {
    pub device_id: String,
    pub device_name: String,
    pub ip_address: String,
    pub port: u16,
    pub route_source: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteResolution {
    pub routes: Vec<ActivePeerRoute>,
    pub fallback_invoked: bool,
}

pub fn resolve_active_peer_routes(registry: &PresenceRegistry) -> RouteResolution {
    let mut routes = Vec::new();
    let mut dedupe = BTreeSet::new();
    let mut fallback_invoked = false;

    let mut append_route = |route: ActivePeerRoute| {
        let key = format!("{}:{}", route.ip_address.to_ascii_lowercase(), route.port);
        if dedupe.insert(key) {
            routes.push(route);
        }
    };

    for route in registry.active_route_descriptors() {
        if let Some(address) = sanitize_address(Some(route.transfer_address.clone())) {
            append_route(ActivePeerRoute {
                device_id: route.peer_id,
                device_name: route.device_name,
                ip_address: address,
                port: route.transfer_port,
                route_source: format!("presence:{:?}", route.route_source).to_ascii_lowercase(),
            });
        }
    }

    let mut presence = registry
        .active_connections
        .values()
        .cloned()
        .collect::<Vec<_>>();
    presence.sort_by_key(|connection| std::cmp::Reverse(connection.connected_at));

    for connection in presence {
        fallback_invoked = true;
        if let Some(address) = sanitize_address(
            connection
                .address
                .clone()
                .or_else(|| parse_address_from_peer_id(&connection.id)),
        ) {
            append_route(ActivePeerRoute {
                device_id: connection.id,
                device_name: connection.display_name,
                ip_address: address,
                port: 8080,
                route_source: "presence:compatibility".to_owned(),
            });
        }
    }

    RouteResolution {
        routes,
        fallback_invoked,
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiscoveredPeer {
    pub peer_id: String,
    pub device_id: Option<String>,
    pub name: String,
    pub ipv4: Option<String>,
    pub transfer_port: Option<u16>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NearbyDiscoveryEndpointClass {
    LocalNetwork,
    PeerToPeer,
    Relay,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NearbyDiscoveryTrustStatus {
    Unknown,
    Candidate,
    ProtocolIdentityVerified,
    Trusted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NearbyDiscoveredDevice {
    pub device_ref: String,
    pub display_name: String,
    pub endpoint_class: NearbyDiscoveryEndpointClass,
    pub trust_status: NearbyDiscoveryTrustStatus,
    #[serde(default)]
    pub capabilities: Vec<String>,
    pub connectable: bool,
}

impl NearbyDiscoveredDevice {
    pub fn new(
        device_ref: impl Into<String>,
        display_name: impl Into<String>,
        endpoint_class: NearbyDiscoveryEndpointClass,
        trust_status: NearbyDiscoveryTrustStatus,
        capabilities: Vec<String>,
        connectable: bool,
    ) -> Self {
        Self {
            device_ref: device_ref.into(),
            display_name: display_name.into(),
            endpoint_class,
            trust_status,
            capabilities,
            connectable,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NearbyDiscoverySnapshot {
    pub schema_version: u32,
    pub scan_id: String,
    pub source: String,
    #[serde(default)]
    pub devices: Vec<NearbyDiscoveredDevice>,
    #[serde(with = "time::serde::rfc3339")]
    pub observed_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub expires_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

impl NearbyDiscoverySnapshot {
    pub const SCHEMA_VERSION: u32 = 1;

    pub fn new(
        scan_id: impl Into<String>,
        source: impl Into<String>,
        devices: Vec<NearbyDiscoveredDevice>,
        ttl_seconds: i64,
    ) -> Self {
        let now = OffsetDateTime::now_utc();
        Self {
            schema_version: Self::SCHEMA_VERSION,
            scan_id: scan_id.into(),
            source: source.into(),
            devices,
            observed_at: now,
            expires_at: now + time::Duration::seconds(ttl_seconds),
            updated_at: now,
        }
    }

    pub fn is_fresh_at(&self, now: OffsetDateTime) -> bool {
        self.expires_at > now
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NearbyDiscoverySnapshotRegistry {
    pub schema_version: u32,
    pub snapshots: BTreeMap<String, NearbyDiscoverySnapshot>,
}

impl Default for NearbyDiscoverySnapshotRegistry {
    fn default() -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            snapshots: BTreeMap::new(),
        }
    }
}

impl NearbyDiscoverySnapshotRegistry {
    pub const SCHEMA_VERSION: u32 = 1;
    pub const MAX_SNAPSHOTS: usize = 32;
    pub const MAX_DEVICES_PER_SNAPSHOT: usize = 256;

    pub fn insert(&mut self, snapshot: NearbyDiscoverySnapshot) {
        self.snapshots.insert(snapshot.scan_id.clone(), snapshot);
    }

    pub fn latest_fresh(&self, now: OffsetDateTime) -> Option<&NearbyDiscoverySnapshot> {
        self.snapshots
            .values()
            .filter(|snapshot| snapshot.is_fresh_at(now))
            .max_by_key(|snapshot| snapshot.updated_at)
    }

    pub fn latest(&self) -> Option<&NearbyDiscoverySnapshot> {
        self.snapshots
            .values()
            .max_by_key(|snapshot| snapshot.updated_at)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UnifiedPeer {
    pub peer_id: String,
    pub device_id: Option<String>,
    pub name: String,
    pub address: Option<String>,
    pub transfer_port: Option<u16>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboundPresenceRouteResolution {
    pub name: String,
    pub display_address: String,
    pub transfer_address: String,
    pub transfer_port: u16,
}

pub fn resolve_inbound_presence_route(
    peer_id: &str,
    endpoint_label: &str,
    discovered_devices: &[DiscoveredPeer],
    unified_devices: &[UnifiedPeer],
) -> InboundPresenceRouteResolution {
    let stable_device_id = peer_id.strip_prefix("id:").unwrap_or(peer_id);
    let endpoint_address = endpoint_label
        .strip_prefix("peer:")
        .unwrap_or(endpoint_label)
        .trim()
        .to_owned();

    for device in discovered_devices {
        if (device.peer_id == peer_id || device.device_id.as_deref() == Some(stable_device_id))
            && let Some(display_address) = sanitize_address(device.ipv4.clone())
        {
            return InboundPresenceRouteResolution {
                name: device.name.clone(),
                display_address: display_address.clone(),
                transfer_address: display_address,
                transfer_port: device.transfer_port.unwrap_or(8080),
            };
        }
    }

    for device in unified_devices {
        if (device.peer_id == peer_id || device.device_id.as_deref() == Some(stable_device_id))
            && let Some(display_address) = sanitize_address(device.address.clone())
        {
            return InboundPresenceRouteResolution {
                name: device.name.clone(),
                display_address: display_address.clone(),
                transfer_address: display_address,
                transfer_port: device.transfer_port.unwrap_or(8080),
            };
        }
    }

    InboundPresenceRouteResolution {
        name: "Unknown peer".to_owned(),
        display_address: endpoint_address.clone(),
        transfer_address: endpoint_address,
        transfer_port: 8080,
    }
}

fn parse_address_from_peer_id(peer_id: &str) -> Option<String> {
    peer_id
        .rsplit(':')
        .next()
        .and_then(|candidate| sanitize_address(Some(candidate.to_owned())))
}

fn sanitize_address(address: Option<String>) -> Option<String> {
    let address = address?;
    let trimmed = address.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn publish_connected_atomically_rejects_incomplete_route() {
        let peer_id = "route-incomplete";
        let mut registry = PresenceRegistry::default();

        let route = PresenceRouteDescriptor {
            peer_id: peer_id.to_owned(),
            device_name: "Mac mini".to_owned(),
            display_address: "10.0.0.9".to_owned(),
            transfer_address: String::new(),
            transfer_port: 8080,
            route_source: PresenceRouteSource::Inbound,
            connected_at: OffsetDateTime::now_utc(),
        };

        assert!(!registry.publish_connected_atomically(
            peer_id,
            "Mac mini",
            Some("10.0.0.9".to_owned()),
            "Classic",
            "X25519",
            route,
        ));
        assert!(!registry.active_connections.contains_key(peer_id));
        assert!(!registry.route_descriptors_by_peer_id.contains_key(peer_id));
    }

    #[test]
    fn publish_connected_atomically_publishes_connection_and_route_together() {
        let peer_id = "route-complete";
        let mut registry = PresenceRegistry::default();

        let route = PresenceRouteDescriptor {
            peer_id: peer_id.to_owned(),
            device_name: "Mac mini".to_owned(),
            display_address: "10.0.0.9".to_owned(),
            transfer_address: "10.0.0.10".to_owned(),
            transfer_port: 9090,
            route_source: PresenceRouteSource::Inbound,
            connected_at: OffsetDateTime::now_utc(),
        };

        assert!(registry.publish_connected_atomically(
            peer_id,
            "Mac mini",
            Some("10.0.0.9".to_owned()),
            "Classic",
            "X25519",
            route.clone(),
        ));
        assert_eq!(
            registry.route_descriptors_by_peer_id.get(peer_id),
            Some(&route)
        );
        assert!(registry.active_connections.contains_key(peer_id));
    }

    #[test]
    fn resolve_inbound_presence_route_prefers_stable_device_id_match() {
        let discovered_devices = vec![DiscoveredPeer {
            peer_id: "id:device-1".to_owned(),
            device_id: Some("device-1".to_owned()),
            name: "MacBook Pro".to_owned(),
            ipv4: Some("192.168.31.20".to_owned()),
            transfer_port: Some(9528),
        }];

        let resolved = resolve_inbound_presence_route(
            "id:device-1",
            "peer:192.168.31.20",
            &discovered_devices,
            &[],
        );

        assert_eq!(resolved.name, "MacBook Pro");
        assert_eq!(resolved.display_address, "192.168.31.20");
        assert_eq!(resolved.transfer_port, 9528);
    }

    #[test]
    fn resolve_inbound_presence_route_falls_back_to_endpoint_address() {
        let resolved = resolve_inbound_presence_route("id:missing", "peer:10.0.0.42", &[], &[]);
        assert_eq!(resolved.display_address, "10.0.0.42");
        assert_eq!(resolved.transfer_port, 8080);
    }

    #[test]
    fn resolve_active_peer_routes_prefers_published_presence_route() {
        let mut registry = PresenceRegistry::default();
        let peer_id = "route-priority";
        registry.mark_connected(
            peer_id,
            "Compatibility Peer",
            Some("10.0.0.9".to_owned()),
            "Classic",
            "X25519",
        );

        let preferred_route = PresenceRouteDescriptor {
            peer_id: peer_id.to_owned(),
            device_name: "Precise Peer".to_owned(),
            display_address: "10.0.0.9".to_owned(),
            transfer_address: "10.0.0.42".to_owned(),
            transfer_port: 9443,
            route_source: PresenceRouteSource::Inbound,
            connected_at: OffsetDateTime::now_utc(),
        };
        assert!(registry.publish_connected_atomically(
            peer_id,
            "Precise Peer",
            Some("10.0.0.9".to_owned()),
            "Classic",
            "X25519",
            preferred_route,
        ));

        let resolution = resolve_active_peer_routes(&registry);
        let selected = resolution
            .routes
            .iter()
            .find(|route| route.device_id == peer_id)
            .expect("route must exist");

        assert_eq!(selected.ip_address, "10.0.0.42");
        assert_eq!(selected.port, 9443);
        assert_eq!(selected.route_source, "presence:inbound");
        assert!(resolution.fallback_invoked);
    }

    #[test]
    fn nearby_discovery_snapshot_registry_selects_only_fresh_snapshots() {
        let mut registry = NearbyDiscoverySnapshotRegistry::default();
        let stale = NearbyDiscoverySnapshot::new(
            "scan-stale",
            "agent_owned_nearby_discovery_snapshot",
            vec![NearbyDiscoveredDevice::new(
                "nearby-stale",
                "Old Mac",
                NearbyDiscoveryEndpointClass::LocalNetwork,
                NearbyDiscoveryTrustStatus::ProtocolIdentityVerified,
                vec!["file_transfer".to_owned()],
                true,
            )],
            60,
        );
        let now = stale.expires_at + time::Duration::seconds(1);
        registry.insert(stale);
        assert!(registry.latest_fresh(now).is_none());
        assert_eq!(
            registry
                .latest()
                .expect("stale snapshot still exists for diagnostics")
                .scan_id,
            "scan-stale"
        );

        let fresh = NearbyDiscoverySnapshot::new(
            "scan-fresh",
            "agent_owned_nearby_discovery_snapshot",
            vec![NearbyDiscoveredDevice::new(
                "nearby-fresh",
                "Studio Mac",
                NearbyDiscoveryEndpointClass::LocalNetwork,
                NearbyDiscoveryTrustStatus::Trusted,
                vec!["remote_desktop".to_owned()],
                true,
            )],
            300,
        );
        registry.insert(fresh);

        assert_eq!(
            registry
                .latest_fresh(OffsetDateTime::now_utc())
                .expect("fresh snapshot should be selected")
                .scan_id,
            "scan-fresh"
        );
    }

    #[test]
    fn nearby_discovery_snapshot_serializes_public_projection_only() {
        let snapshot = NearbyDiscoverySnapshot::new(
            "scan-1",
            "agent_owned_nearby_discovery_snapshot",
            vec![NearbyDiscoveredDevice::new(
                "nearby-device-1",
                "Studio Mac",
                NearbyDiscoveryEndpointClass::LocalNetwork,
                NearbyDiscoveryTrustStatus::ProtocolIdentityVerified,
                vec!["remote_desktop".to_owned(), "file_transfer".to_owned()],
                true,
            )],
            300,
        );
        let serialized = serde_json::to_string(&snapshot).expect("snapshot should serialize");
        assert!(serialized.contains("nearby-device-1"));
        assert!(serialized.contains("protocol_identity_verified"));
        assert!(!serialized.contains("192.168."));
        assert!(!serialized.contains("private_key"));
        assert!(!serialized.contains("fingerprint"));
    }
}
