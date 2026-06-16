//! Agent-owned active nearby device scanner (mDNS / DNS-SD).
//!
//! Browses the shared SkyBridge service type and projects the resolved peers
//! into the existing [`NearbyDiscoverySnapshot`] model. This is the live
//! execution that backs `skybridge device discover --nearby --scan`.
//!
//! Security / honesty posture (matches the snapshot validation in `state.rs`):
//! - `device_ref` is derived from a hash of the advertised protocol identity
//!   key, never from a hostname or IP address, so the public discovery
//!   snapshot contract cannot leak a network locator.
//! - Trust is projected conservatively: a peer is only marked
//!   `ProtocolIdentityVerified` / `Trusted` when the agent already knows its
//!   protocol identity. Everything else is a `Candidate` and is never
//!   `connectable`. We never fabricate trust from raw mDNS advertisements.
//! - Discovery never authorizes a connection; the CLI always reports
//!   `connection_authorized = false`. A connection still requires the explicit
//!   operator request + handshake gates.

use std::collections::BTreeMap;
use std::time::Duration;

use anyhow::{Context, Result};
use sha2::{Digest, Sha256};
use skybridge_core::{
    NearbyDiscoveredDevice, NearbyDiscoveryEndpointClass, NearbyDiscoverySnapshot,
    NearbyDiscoverySnapshotRegistry, NearbyDiscoveryTrustStatus,
};

/// Service type advertised by SkyBridge peers (see
/// `Docs/CrossPlatformDiscoveryDesign.md`).
pub const SKYBRIDGE_SERVICE_TYPE: &str = "_skybridge._tcp.local.";

/// Snapshot `source` marker identifying an active, agent-owned mDNS scan as
/// opposed to a passive presence snapshot. `device discover --nearby --scan`
/// only accepts snapshots carrying this provenance.
pub const ACTIVE_SCAN_SOURCE: &str = "agent_owned_active_mdns_scan";

/// Stable scan id for the rolling active-scan snapshot. Reusing a single id
/// keeps the registry bounded (one live active snapshot, refreshed each pass)
/// instead of growing until [`NearbyDiscoverySnapshotRegistry::MAX_SNAPSHOTS`].
pub const ACTIVE_SCAN_ID: &str = "active-mdns-scan";

/// TXT keys in the shared discovery contract.
const TXT_KEY_IDENTITY: &str = "pk";
const TXT_KEY_NAME: &str = "dn";
const TXT_KEY_CAPABILITIES: &str = "caps";

const MAX_CAPABILITIES_PER_DEVICE: usize = 16;
const MAX_PUBLIC_TEXT_BYTES: usize = 128;

/// Default freshness window for an active scan snapshot, in seconds.
pub const DEFAULT_ACTIVE_SCAN_TTL_SECONDS: i64 = 120;

/// One peer resolved during an active scan, prior to trust projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedNearbyPeer {
    /// Decoded protocol identity public key bytes advertised in TXT (if any).
    pub identity_public_key: Option<Vec<u8>>,
    /// Advertised display name (raw; sanitized during projection).
    pub display_name: String,
    /// Capability tokens advertised in TXT (raw; sanitized during projection).
    pub capabilities: Vec<String>,
    /// Whether at least one routable address + port was resolved.
    pub has_reachable_address: bool,
}

/// Build an active-scan [`NearbyDiscoverySnapshot`] from resolved peers.
///
/// This is the pure projection step (no I/O) so it can be unit tested:
/// it dedupes by protocol identity, projects trust from `trusted_identities`,
/// derives locator-free `device_ref`s, and enforces the public-text limits the
/// snapshot validator requires.
pub fn build_active_scan_snapshot(
    peers: Vec<ResolvedNearbyPeer>,
    trusted_identities: &BTreeMap<String, NearbyDiscoveryTrustStatus>,
    ttl_seconds: i64,
) -> NearbyDiscoverySnapshot {
    // Keyed by device_ref so multiple interfaces/addresses of the same protocol
    // identity collapse into a single deduped device.
    let mut devices: BTreeMap<String, NearbyDiscoveredDevice> = BTreeMap::new();

    for peer in peers {
        let Some(identity) = peer
            .identity_public_key
            .as_ref()
            .filter(|key| !key.is_empty())
        else {
            // No protocol identity advertised -> not a verifiable SkyBridge
            // peer. We skip it rather than fabricate a candidate device.
            continue;
        };

        let device_ref = identity_device_ref(identity);
        let trust_status = trusted_identities
            .get(&device_ref)
            .copied()
            .unwrap_or(NearbyDiscoveryTrustStatus::Candidate);
        let connectable = peer.has_reachable_address
            && matches!(
                trust_status,
                NearbyDiscoveryTrustStatus::ProtocolIdentityVerified
                    | NearbyDiscoveryTrustStatus::Trusted
            );
        let display_name = sanitized_display_name(&peer.display_name, &device_ref);
        let capabilities = sanitized_capabilities(peer.capabilities);

        devices
            .entry(device_ref.clone())
            .and_modify(|existing| {
                // Merge duplicate observations: keep the strongest trust, OR the
                // reachability, and union capabilities (bounded).
                if trust_rank(trust_status) > trust_rank(existing.trust_status) {
                    existing.trust_status = trust_status;
                }
                existing.connectable = existing.connectable || connectable;
                merge_capabilities(&mut existing.capabilities, &capabilities);
            })
            .or_insert_with(|| {
                NearbyDiscoveredDevice::new(
                    device_ref.clone(),
                    display_name,
                    NearbyDiscoveryEndpointClass::LocalNetwork,
                    trust_status,
                    capabilities,
                    connectable,
                )
            });
    }

    let mut device_list: Vec<NearbyDiscoveredDevice> = devices.into_values().collect();
    device_list.truncate(NearbyDiscoverySnapshotRegistry::MAX_DEVICES_PER_SNAPSHOT);

    NearbyDiscoverySnapshot::new(ACTIVE_SCAN_ID, ACTIVE_SCAN_SOURCE, device_list, ttl_seconds)
}

/// Perform a live mDNS browse for `duration` and return resolved SkyBridge
/// peers. This performs real network I/O and is therefore exercised by the
/// real-device smoke lane rather than unit tests; all projection logic lives in
/// [`build_active_scan_snapshot`].
pub async fn scan_nearby_peers(duration: Duration) -> Result<Vec<ResolvedNearbyPeer>> {
    use mdns_sd::{ServiceDaemon, ServiceEvent};

    let daemon = ServiceDaemon::new().context("failed to start mDNS service daemon")?;
    let receiver = daemon
        .browse(SKYBRIDGE_SERVICE_TYPE)
        .context("failed to browse SkyBridge service type")?;

    let deadline = tokio::time::Instant::now() + duration;
    let mut peers: BTreeMap<String, ResolvedNearbyPeer> = BTreeMap::new();

    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match tokio::time::timeout(remaining, receiver.recv_async()).await {
            Ok(Ok(ServiceEvent::ServiceResolved(resolved))) => {
                let peer = resolved_peer_from_service(resolved.as_ref());
                // Dedupe by fullname during collection so repeated answers for
                // the same instance don't inflate the list before projection.
                peers.insert(resolved.fullname.clone(), peer);
            }
            Ok(Ok(_)) => {}
            // Channel closed: the daemon stopped delivering events.
            Ok(Err(_)) => break,
            // Browse window elapsed.
            Err(_) => break,
        }
    }

    // Best-effort shutdown; failure to stop the daemon must not fail the scan.
    if let Err(error) = daemon.shutdown() {
        tracing::debug!(
            kind = "agent.discovery.daemon_shutdown_failed",
            error = %error,
            "mDNS daemon shutdown returned an error"
        );
    }

    Ok(peers.into_values().collect())
}

fn resolved_peer_from_service(service: &mdns_sd::ResolvedService) -> ResolvedNearbyPeer {
    let txt = &service.txt_properties;
    let identity_public_key = txt
        .get_property_val_str(TXT_KEY_IDENTITY)
        .and_then(decode_identity_key);
    let display_name = txt
        .get_property_val_str(TXT_KEY_NAME)
        .map(str::to_owned)
        .unwrap_or_else(|| instance_label_from_fullname(&service.fullname));
    let capabilities = txt
        .get_property_val_str(TXT_KEY_CAPABILITIES)
        .map(parse_capability_list)
        .unwrap_or_default();
    let has_reachable_address = !service.addresses.is_empty() && service.port != 0;

    ResolvedNearbyPeer {
        identity_public_key,
        display_name,
        capabilities,
        has_reachable_address,
    }
}

/// Derive a stable, locator-free device reference from a protocol identity key.
/// `id-` + 16 hex chars of SHA-256(identity) keeps it free of `:`, `/`, `.`,
/// and all-digit forms, satisfying the snapshot locator validator.
fn identity_device_ref(identity: &[u8]) -> String {
    let digest = Sha256::digest(identity);
    let mut device_ref = String::with_capacity(3 + 16);
    device_ref.push_str("id-");
    for byte in digest.iter().take(8) {
        use std::fmt::Write as _;
        let _ = write!(device_ref, "{byte:02x}");
    }
    device_ref
}

fn sanitized_display_name(raw: &str, device_ref: &str) -> String {
    let cleaned = clamp_public_text(raw);
    if cleaned.is_empty() {
        // Fall back to a non-empty, locator-free label tied to the identity.
        format!("peer-{}", &device_ref[3..])
    } else {
        cleaned
    }
}

fn sanitized_capabilities(raw: Vec<String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for capability in raw {
        let cleaned = clamp_public_text(&capability);
        if cleaned.is_empty() || looks_like_locator(&cleaned) {
            continue;
        }
        if !out.iter().any(|existing| existing == &cleaned) {
            out.push(cleaned);
        }
        if out.len() >= MAX_CAPABILITIES_PER_DEVICE {
            break;
        }
    }
    out
}

fn merge_capabilities(existing: &mut Vec<String>, incoming: &[String]) {
    for capability in incoming {
        if existing.len() >= MAX_CAPABILITIES_PER_DEVICE {
            break;
        }
        if !existing.iter().any(|value| value == capability) {
            existing.push(capability.clone());
        }
    }
}

/// Strip control characters and clamp to the public-text byte budget on a UTF-8
/// boundary. Returns a trimmed, validator-safe string.
fn clamp_public_text(value: &str) -> String {
    let filtered: String = value.chars().filter(|ch| !ch.is_control()).collect();
    let trimmed = filtered.trim();
    if trimmed.len() <= MAX_PUBLIC_TEXT_BYTES {
        return trimmed.to_owned();
    }
    let mut end = MAX_PUBLIC_TEXT_BYTES;
    while end > 0 && !trimmed.is_char_boundary(end) {
        end -= 1;
    }
    trimmed[..end].trim().to_owned()
}

/// Mirror of the snapshot validator's locator heuristic so capability tokens we
/// emit cannot trip validation downstream.
fn looks_like_locator(value: &str) -> bool {
    let trimmed = value.trim();
    trimmed.contains(':')
        || trimmed.contains('/')
        || trimmed.ends_with(".local")
        || trimmed
            .split('.')
            .all(|segment| !segment.is_empty() && segment.chars().all(|ch| ch.is_ascii_digit()))
}

fn instance_label_from_fullname(fullname: &str) -> String {
    let label = fullname
        .strip_suffix(&format!(".{SKYBRIDGE_SERVICE_TYPE}"))
        .or_else(|| fullname.split("._skybridge").next())
        .unwrap_or(fullname);
    clamp_public_text(label)
}

fn parse_capability_list(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|token| !token.is_empty())
        .map(str::to_owned)
        .collect()
}

fn decode_identity_key(value: &str) -> Option<Vec<u8>> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(bytes) = decode_hex(trimmed) {
        return Some(bytes);
    }
    use base64::Engine as _;
    if let Ok(bytes) = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(trimmed) {
        return Some(bytes);
    }
    base64::engine::general_purpose::STANDARD
        .decode(trimmed)
        .ok()
}

fn decode_hex(value: &str) -> Option<Vec<u8>> {
    if value.len() < 2 || !value.len().is_multiple_of(2) {
        return None;
    }
    let mut bytes = Vec::with_capacity(value.len() / 2);
    let raw = value.as_bytes();
    let mut index = 0;
    while index < raw.len() {
        let hi = (raw[index] as char).to_digit(16)?;
        let lo = (raw[index + 1] as char).to_digit(16)?;
        bytes.push((hi * 16 + lo) as u8);
        index += 2;
    }
    Some(bytes)
}

fn trust_rank(status: NearbyDiscoveryTrustStatus) -> u8 {
    match status {
        NearbyDiscoveryTrustStatus::Unknown => 0,
        NearbyDiscoveryTrustStatus::Candidate => 1,
        NearbyDiscoveryTrustStatus::ProtocolIdentityVerified => 2,
        NearbyDiscoveryTrustStatus::Trusted => 3,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn peer(
        identity: Option<&[u8]>,
        name: &str,
        caps: &[&str],
        reachable: bool,
    ) -> ResolvedNearbyPeer {
        ResolvedNearbyPeer {
            identity_public_key: identity.map(|bytes| bytes.to_vec()),
            display_name: name.to_owned(),
            capabilities: caps.iter().map(|c| (*c).to_owned()).collect(),
            has_reachable_address: reachable,
        }
    }

    #[test]
    fn build_snapshot_marks_active_provenance_and_never_authorizes_connection() {
        let snapshot = build_active_scan_snapshot(
            vec![peer(
                Some(b"identity-key-aaa"),
                "Studio Mac",
                &["remote_desktop"],
                true,
            )],
            &BTreeMap::new(),
            DEFAULT_ACTIVE_SCAN_TTL_SECONDS,
        );
        assert_eq!(snapshot.source, ACTIVE_SCAN_SOURCE);
        assert_eq!(snapshot.scan_id, ACTIVE_SCAN_ID);
        assert_eq!(snapshot.devices.len(), 1);
        let device = &snapshot.devices[0];
        // No trust material -> candidate, and candidates are never connectable.
        assert_eq!(device.trust_status, NearbyDiscoveryTrustStatus::Candidate);
        assert!(!device.connectable);
        assert!(device.device_ref.starts_with("id-"));
        assert!(!looks_like_locator(&device.device_ref));
    }

    #[test]
    fn build_snapshot_projects_trust_and_allows_connectable_when_verified() {
        let identity = b"verified-peer-key";
        let device_ref = identity_device_ref(identity);
        let mut trusted = BTreeMap::new();
        trusted.insert(device_ref.clone(), NearbyDiscoveryTrustStatus::Trusted);

        let snapshot = build_active_scan_snapshot(
            vec![peer(
                Some(identity),
                "Trusted Mac",
                &["file_transfer"],
                true,
            )],
            &trusted,
            DEFAULT_ACTIVE_SCAN_TTL_SECONDS,
        );
        let device = &snapshot.devices[0];
        assert_eq!(device.trust_status, NearbyDiscoveryTrustStatus::Trusted);
        assert!(device.connectable);
    }

    #[test]
    fn build_snapshot_does_not_mark_connectable_without_reachable_address() {
        let identity = b"verified-but-unreachable";
        let device_ref = identity_device_ref(identity);
        let mut trusted = BTreeMap::new();
        trusted.insert(
            device_ref,
            NearbyDiscoveryTrustStatus::ProtocolIdentityVerified,
        );

        let snapshot = build_active_scan_snapshot(
            vec![peer(Some(identity), "Unreachable", &[], false)],
            &trusted,
            DEFAULT_ACTIVE_SCAN_TTL_SECONDS,
        );
        assert!(!snapshot.devices[0].connectable);
    }

    #[test]
    fn build_snapshot_skips_peers_without_protocol_identity() {
        let snapshot = build_active_scan_snapshot(
            vec![peer(None, "Anonymous", &["remote_desktop"], true)],
            &BTreeMap::new(),
            DEFAULT_ACTIVE_SCAN_TTL_SECONDS,
        );
        assert!(snapshot.devices.is_empty());
    }

    #[test]
    fn build_snapshot_dedupes_same_identity_and_unions_capabilities() {
        let identity = b"same-identity";
        let snapshot = build_active_scan_snapshot(
            vec![
                peer(Some(identity), "Mac (en0)", &["remote_desktop"], false),
                peer(Some(identity), "Mac (en1)", &["file_transfer"], true),
            ],
            &BTreeMap::new(),
            DEFAULT_ACTIVE_SCAN_TTL_SECONDS,
        );
        assert_eq!(snapshot.devices.len(), 1);
        let device = &snapshot.devices[0];
        assert!(device.capabilities.contains(&"remote_desktop".to_owned()));
        assert!(device.capabilities.contains(&"file_transfer".to_owned()));
    }

    #[test]
    fn sanitized_capabilities_drop_locators_and_control_chars() {
        let caps = sanitized_capabilities(vec![
            "remote_desktop".to_owned(),
            "192.168.0.2".to_owned(),
            "mac.local".to_owned(),
            "with/slash".to_owned(),
            "ctrl\u{0007}token".to_owned(),
            "remote_desktop".to_owned(),
        ]);
        assert_eq!(
            caps,
            vec!["remote_desktop".to_owned(), "ctrltoken".to_owned()]
        );
    }

    #[test]
    fn display_name_falls_back_to_identity_label_when_empty() {
        let device_ref = identity_device_ref(b"abc");
        let name = sanitized_display_name("   ", &device_ref);
        assert!(name.starts_with("peer-"));
        assert!(!name.is_empty());
    }

    #[test]
    fn decode_identity_key_accepts_hex_and_base64() {
        assert_eq!(decode_identity_key("0a0b0c"), Some(vec![10, 11, 12]));
        use base64::Engine as _;
        let encoded = base64::engine::general_purpose::STANDARD.encode([1u8, 2, 3, 250]);
        assert_eq!(decode_identity_key(&encoded), Some(vec![1, 2, 3, 250]));
        assert_eq!(decode_identity_key(""), None);
    }

    #[test]
    fn instance_label_strips_service_type() {
        assert_eq!(
            instance_label_from_fullname("Studio Mac._skybridge._tcp.local."),
            "Studio Mac"
        );
    }
}
