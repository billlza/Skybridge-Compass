//! Native active nearby device scanner (mDNS / DNS-SD).
//!
//! Browses the shared SkyBridge service type and projects the resolved peers
//! into the existing [`NearbyDiscoverySnapshot`] model. The agent uses it for
//! periodic discovery, while `skybridge device discover --nearby --scan` runs
//! it directly as a bounded foreground operation without requiring the agent or
//! Desktop app.
//!
//! Security / honesty posture (matches the snapshot validation in `state.rs`):
//! - `device_ref` is derived from a hash of the advertised protocol identity
//!   key, never from a hostname or IP address, so the public discovery
//!   snapshot contract cannot leak a network locator.
//! - Every mDNS identity is an unauthenticated claim, including a fingerprint
//!   that matches a locally known peer. Results remain `Candidate` and are
//!   never `connectable`; only a later signed handshake can prove key
//!   possession and promote session trust.
//! - Discovery never authorizes a connection; the CLI always reports
//!   `connection_authorized = false`. A connection still requires the explicit
//!   operator request + handshake gates.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::net::IpAddr;
use std::time::Duration;

use skybridge_core::{
    MLDSA65_PUBLIC_KEY_BYTES, MLDSA87_PUBLIC_KEY_BYTES, NearbyDiscoveredDevice,
    NearbyDiscoveryEndpointClass, NearbyDiscoverySnapshot, NearbyDiscoverySnapshotRegistry,
    NearbyDiscoveryTrustStatus, ProtocolIdentityBinding, ProtocolSigningAlgorithm,
};
use time::OffsetDateTime;

use crate::state::looks_like_network_locator;

/// Service type advertised by SkyBridge peers (see
/// `Docs/CrossPlatformDiscoveryDesign.md`).
pub const SKYBRIDGE_SERVICE_TYPE: &str = "_skybridge._tcp.local.";

/// Snapshot `source` marker identifying a native active mDNS scan as opposed to
/// a passive presence snapshot. Both the agent and the standalone CLI use this
/// scanner, so the provenance deliberately does not claim a particular owner.
pub const ACTIVE_SCAN_SOURCE: &str = "native_active_mdns_scan";

/// Stable scan id for the rolling active-scan snapshot. Reusing a single id
/// keeps the registry bounded (one live active snapshot, refreshed each pass)
/// instead of growing until [`NearbyDiscoverySnapshotRegistry::MAX_SNAPSHOTS`].
pub const ACTIVE_SCAN_ID: &str = "active-mdns-scan";

/// Legacy TXT keys still emitted by older non-Apple peers.
const TXT_KEY_IDENTITY: &str = "pk";

/// Canonical aliases from `Docs/bonjour_interop_contract.json` plus the
/// display/capability keys used by the Apple advertiser.
const TXT_DEVICE_IDENTITY_KEYS: &[&str] = &[
    "deviceId",
    "id",
    "deviceID",
    "device_id",
    "uuid",
    "uniqueId",
    "unique_id",
];
const TXT_FINGERPRINT_KEYS: &[&str] = &[
    "pubKeyFP",
    "pubKeyFp",
    "pub_key_fp",
    "identityFingerprint",
    "publicKeyFingerprint",
    "protocolIdentityFingerprint",
];
const TXT_SIGNING_ALGORITHM_KEYS: &[&str] = &[
    "protocolSigningAlgorithm",
    "protocol_signing_algorithm",
    "signingAlgorithm",
];
const TXT_DISPLAY_NAME_KEYS: &[&str] = &["name", "dn", "device"];
const TXT_CAPABILITY_KEYS: &[&str] = &["capabilities", "caps"];

const MAX_CAPABILITIES_PER_DEVICE: usize = 16;
const MAX_PUBLIC_TEXT_BYTES: usize = 128;
const MAX_ADVERTISED_ENDPOINTS_PER_DEVICE: usize = 8;
const ED25519_PUBLIC_KEY_BYTES: usize = 32;
const MAX_ENCODED_IDENTITY_KEY_BYTES: usize = MLDSA87_PUBLIC_KEY_BYTES * 2;

/// Default freshness window for an active scan snapshot, in seconds.
pub const DEFAULT_ACTIVE_SCAN_TTL_SECONDS: i64 = 120;

/// Default duration of one operator-requested active scan.
pub const DEFAULT_ON_DEMAND_SCAN_SECONDS: u64 = 4;
/// Smallest accepted operator-requested scan window.
pub const MIN_ON_DEMAND_SCAN_SECONDS: u64 = 1;
/// Largest accepted operator-requested scan window.
pub const MAX_ON_DEMAND_SCAN_SECONDS: u64 = 30;
/// Locator observations are deliberately shorter-lived than the public snapshot
/// and are never persisted by the scanner.
pub const ADVERTISED_ENDPOINT_TTL_SECONDS: i64 = 30;
const DAEMON_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);

/// One address advertised by mDNS during the current scan.
///
/// This is discovery evidence only. It is not authenticated, connectable, or a
/// route authorization, and callers must not persist it in the locator-free
/// [`NearbyDiscoverySnapshot`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdvertisedEndpointObservation {
    pub device_ref: String,
    pub address: IpAddr,
    pub port: u16,
    pub observed_at: OffsetDateTime,
    pub expires_at: OffsetDateTime,
}

impl AdvertisedEndpointObservation {
    pub const PROVENANCE: &'static str = "advertised_unverified";

    pub fn is_fresh_at(&self, now: OffsetDateTime) -> bool {
        self.expires_at > now
    }
}

/// Result of one bounded, foreground mDNS scan.
///
/// `snapshot` is safe to persist through the existing state validator.
/// `advertised_endpoints` is an ephemeral, unverified projection for an explicit
/// operator display request only.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActiveScanResult {
    pub snapshot: NearbyDiscoverySnapshot,
    pub advertised_endpoints: Vec<AdvertisedEndpointObservation>,
}

/// Stable phase at which a bounded foreground discovery scan failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActiveScanFailureStage {
    RequestValidation,
    TransportStart,
    ScanRuntime,
}

/// Stable semantic reason for an active discovery scan failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActiveScanFailureKind {
    InvalidRequest,
    PermissionDenied,
    TransportUnavailable,
}

/// Typed active-scan boundary error.
///
/// The internal detail remains available to the human-readable error chain,
/// while machine-readable callers project only `stage()` and `kind()` into a
/// bounded, redacted public contract.
#[derive(Debug)]
pub struct ActiveScanError {
    stage: ActiveScanFailureStage,
    kind: ActiveScanFailureKind,
    detail: String,
}

impl ActiveScanError {
    pub fn transport_start(detail: impl fmt::Display) -> Self {
        Self::transport(ActiveScanFailureStage::TransportStart, detail)
    }

    pub fn scan_runtime(detail: impl fmt::Display) -> Self {
        Self::transport(ActiveScanFailureStage::ScanRuntime, detail)
    }

    pub fn stage(&self) -> ActiveScanFailureStage {
        self.stage
    }

    pub fn kind(&self) -> ActiveScanFailureKind {
        self.kind
    }

    fn invalid_request(detail: impl Into<String>) -> Self {
        Self {
            stage: ActiveScanFailureStage::RequestValidation,
            kind: ActiveScanFailureKind::InvalidRequest,
            detail: detail.into(),
        }
    }

    fn transport(stage: ActiveScanFailureStage, detail: impl fmt::Display) -> Self {
        let detail = detail.to_string();
        let kind = if detail_indicates_permission_denied(&detail) {
            ActiveScanFailureKind::PermissionDenied
        } else {
            ActiveScanFailureKind::TransportUnavailable
        };
        Self {
            stage,
            kind,
            detail,
        }
    }

    fn with_shutdown_failure(mut self, shutdown: Self) -> Self {
        self.detail = format!("{}; shutdown also failed: {shutdown}", self.detail);
        self
    }
}

impl fmt::Display for ActiveScanError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let stage = match self.stage {
            ActiveScanFailureStage::RequestValidation => "active scan request validation failed",
            ActiveScanFailureStage::TransportStart => "mDNS transport startup failed",
            ActiveScanFailureStage::ScanRuntime => "mDNS scan runtime failed",
        };
        write!(formatter, "{stage}: {}", self.detail)
    }
}

impl std::error::Error for ActiveScanError {}

fn detail_indicates_permission_denied(detail: &str) -> bool {
    let normalized = detail.to_ascii_lowercase();
    normalized.contains("operation not permitted")
        || normalized.contains("permission denied")
        || normalized.contains("access is denied")
        || normalized.contains("os error 1)")
        || normalized.contains("os error 5)")
        || normalized.contains("os error 13)")
}

/// One peer resolved during an active scan, prior to trust projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedNearbyPeer {
    /// Typed identity evidence advertised in TXT (if any).
    ///
    /// A fingerprint-only advertisement is a discovery hint, never proof that
    /// the advertiser owns the corresponding protocol key.
    pub identity: Option<AdvertisedProtocolIdentity>,
    /// Advertised display name (raw; sanitized during projection).
    pub display_name: String,
    /// Capability tokens advertised in TXT (raw; sanitized during projection).
    pub capabilities: Vec<String>,
    /// Whether at least one routable address + port was resolved.
    pub has_reachable_address: bool,
    /// Raw addresses advertised for this service during the bounded scan.
    /// These never enter the public snapshot projection.
    pub advertised_endpoints: Vec<(IpAddr, u16)>,
}

/// Identity material carried by an unauthenticated Bonjour advertisement.
///
/// Keeping full keys and fingerprint-only hints as separate variants prevents
/// callers from accidentally using an Apple `pubKeyFP` value as if it were a
/// protocol public key. Both variants derive the same locator-free reference
/// from the canonical algorithm-tagged protocol fingerprint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdvertisedProtocolIdentity {
    RawPublicKeyClaim {
        device_id: Option<String>,
        algorithm: ProtocolSigningAlgorithm,
        public_key: Vec<u8>,
        canonical_fingerprint: String,
    },
    FingerprintClaim {
        device_id: String,
        algorithm: Option<ProtocolSigningAlgorithm>,
        canonical_fingerprint: String,
    },
}

impl AdvertisedProtocolIdentity {
    fn from_public_key_claim(
        public_key: Vec<u8>,
        device_id: Option<&str>,
        advertised_algorithm: Option<&str>,
    ) -> Option<Self> {
        let algorithm = match advertised_algorithm {
            Some(value) => parse_canonical_signing_algorithm(value)?,
            None if public_key.len() == ED25519_PUBLIC_KEY_BYTES => {
                ProtocolSigningAlgorithm::Ed25519
            }
            None => return None,
        };
        ProtocolIdentityBinding::validate_key_encoding(&public_key, algorithm).ok()?;
        let device_id = match device_id {
            Some(value) => Some(normalized_advertised_device_id(value)?),
            None => None,
        };
        let canonical_fingerprint =
            ProtocolIdentityBinding::compute_fingerprint(algorithm, &public_key);
        Some(Self::RawPublicKeyClaim {
            device_id,
            algorithm,
            public_key,
            canonical_fingerprint,
        })
    }

    fn from_fingerprint_claim(
        device_id: Option<&str>,
        fingerprint: &str,
        algorithm: Option<&str>,
    ) -> Option<Self> {
        if !ProtocolIdentityBinding::is_valid_fingerprint(fingerprint) {
            return None;
        }
        let device_id = normalized_advertised_device_id(device_id?)?;
        let algorithm = match algorithm {
            Some(value) => Some(parse_canonical_signing_algorithm(value)?),
            None => None,
        };
        Some(Self::FingerprintClaim {
            device_id,
            algorithm,
            canonical_fingerprint: fingerprint.to_owned(),
        })
    }

    fn fingerprint(&self) -> &str {
        match self {
            Self::RawPublicKeyClaim {
                canonical_fingerprint,
                ..
            }
            | Self::FingerprintClaim {
                canonical_fingerprint,
                ..
            } => canonical_fingerprint,
        }
    }

    fn device_ref(&self) -> String {
        fingerprint_device_ref(self.fingerprint())
    }

    fn agrees_with(&self, other: &Self) -> bool {
        if self.fingerprint() != other.fingerprint() {
            return false;
        }
        match (self, other) {
            (
                Self::RawPublicKeyClaim {
                    device_id: left_id,
                    algorithm: left,
                    ..
                },
                Self::RawPublicKeyClaim {
                    device_id: right_id,
                    algorithm: right,
                    ..
                },
            ) => left == right && optional_device_ids_agree(left_id, right_id),
            (
                Self::RawPublicKeyClaim {
                    device_id: left_id,
                    algorithm,
                    ..
                },
                Self::FingerprintClaim {
                    device_id: right_id,
                    algorithm: Some(hint),
                    ..
                },
            )
            | (
                Self::FingerprintClaim {
                    device_id: right_id,
                    algorithm: Some(hint),
                    ..
                },
                Self::RawPublicKeyClaim {
                    device_id: left_id,
                    algorithm,
                    ..
                },
            ) => algorithm == hint && optional_device_id_matches(left_id, right_id),
            (
                Self::FingerprintClaim {
                    device_id: left_id,
                    algorithm: left_algorithm,
                    ..
                },
                Self::FingerprintClaim {
                    device_id: right_id,
                    algorithm: right_algorithm,
                    ..
                },
            ) => {
                left_id == right_id
                    && (left_algorithm.is_none()
                        || right_algorithm.is_none()
                        || left_algorithm == right_algorithm)
            }
            (
                Self::RawPublicKeyClaim {
                    device_id: left_id, ..
                },
                Self::FingerprintClaim {
                    device_id: right_id,
                    algorithm: None,
                    ..
                },
            )
            | (
                Self::FingerprintClaim {
                    device_id: right_id,
                    algorithm: None,
                    ..
                },
                Self::RawPublicKeyClaim {
                    device_id: left_id, ..
                },
            ) => optional_device_id_matches(left_id, right_id),
        }
    }
}

fn normalized_advertised_device_id(value: &str) -> Option<String> {
    let normalized = ProtocolIdentityBinding::normalized_device_id(value).ok()?;
    (normalized == value).then_some(normalized)
}

fn parse_canonical_signing_algorithm(value: &str) -> Option<ProtocolSigningAlgorithm> {
    let parsed = value.parse::<ProtocolSigningAlgorithm>().ok()?;
    (parsed.as_str() == value).then_some(parsed)
}

fn optional_device_ids_agree(left: &Option<String>, right: &Option<String>) -> bool {
    left.is_none() || right.is_none() || left == right
}

fn optional_device_id_matches(optional: &Option<String>, required: &str) -> bool {
    optional.as_deref().is_none_or(|value| value == required)
}

/// Execute one bounded foreground scan and produce both the locator-free public
/// snapshot and optional ephemeral locator observations.
pub async fn run_active_scan(
    duration: Duration,
) -> std::result::Result<ActiveScanResult, ActiveScanError> {
    let seconds = duration.as_secs();
    if duration.subsec_nanos() != 0
        || !(MIN_ON_DEMAND_SCAN_SECONDS..=MAX_ON_DEMAND_SCAN_SECONDS).contains(&seconds)
    {
        return Err(ActiveScanError::invalid_request(format!(
            "active scan duration must be a whole number of seconds in {MIN_ON_DEMAND_SCAN_SECONDS}..={MAX_ON_DEMAND_SCAN_SECONDS}"
        )));
    }

    let peers = scan_nearby_peers(duration).await?;
    Ok(active_scan_result_from_peers(
        peers,
        DEFAULT_ACTIVE_SCAN_TTL_SECONDS,
    ))
}

fn active_scan_result_from_peers(
    peers: Vec<ResolvedNearbyPeer>,
    snapshot_ttl_seconds: i64,
) -> ActiveScanResult {
    let observed_at = OffsetDateTime::now_utc();
    let expires_at = observed_at + time::Duration::seconds(ADVERTISED_ENDPOINT_TTL_SECONDS);
    let mut observations = BTreeMap::new();

    for peer in &peers {
        let Some(identity) = peer.identity.as_ref() else {
            continue;
        };
        let device_ref = identity.device_ref();
        for (address, port) in peer
            .advertised_endpoints
            .iter()
            .take(MAX_ADVERTISED_ENDPOINTS_PER_DEVICE)
        {
            if *port == 0
                || address.is_unspecified()
                || address.is_multicast()
                || address.is_loopback()
            {
                continue;
            }
            observations
                .entry((device_ref.clone(), *address, *port))
                .or_insert_with(|| AdvertisedEndpointObservation {
                    device_ref: device_ref.clone(),
                    address: *address,
                    port: *port,
                    observed_at,
                    expires_at,
                });
        }
    }

    let snapshot = build_active_scan_snapshot(peers, snapshot_ttl_seconds);
    let included_device_refs = snapshot
        .devices
        .iter()
        .map(|device| device.device_ref.as_str())
        .collect::<BTreeSet<_>>();
    observations.retain(|(device_ref, _, _), _| included_device_refs.contains(device_ref.as_str()));

    ActiveScanResult {
        snapshot,
        advertised_endpoints: observations.into_values().collect(),
    }
}

/// Build an active-scan [`NearbyDiscoverySnapshot`] from resolved peers.
///
/// This is the pure projection step (no I/O) so it can be unit tested:
/// it dedupes identity claims, derives locator-free `device_ref`s, and enforces
/// the public-text limits the snapshot validator requires. Bonjour is an
/// unauthenticated discovery channel, so every result remains a non-connectable
/// candidate until a later signed handshake proves key possession.
pub fn build_active_scan_snapshot(
    peers: Vec<ResolvedNearbyPeer>,
    ttl_seconds: i64,
) -> NearbyDiscoverySnapshot {
    // Keyed by device_ref so multiple interfaces/addresses of the same protocol
    // identity collapse into a single deduped device.
    let mut devices: BTreeMap<String, NearbyDiscoveredDevice> = BTreeMap::new();
    let mut identities: BTreeMap<String, AdvertisedProtocolIdentity> = BTreeMap::new();
    let mut ambiguous_device_refs = BTreeSet::new();

    for peer in peers {
        let Some(identity) = peer.identity.as_ref() else {
            // No protocol identity advertised -> not a verifiable SkyBridge
            // peer. We skip it rather than fabricate a candidate device.
            continue;
        };

        let device_ref = identity.device_ref();
        if ambiguous_device_refs.contains(&device_ref) {
            continue;
        }
        if let Some(existing_identity) = identities.get(&device_ref)
            && !existing_identity.agrees_with(identity)
        {
            identities.remove(&device_ref);
            devices.remove(&device_ref);
            ambiguous_device_refs.insert(device_ref);
            continue;
        }
        identities
            .entry(device_ref.clone())
            .or_insert_with(|| identity.clone());
        let trust_status = NearbyDiscoveryTrustStatus::Candidate;
        let connectable = false;
        let display_name = sanitized_display_name(&peer.display_name, &device_ref);
        let capabilities = sanitized_capabilities(peer.capabilities);

        devices
            .entry(device_ref.clone())
            .and_modify(|existing| {
                // Merge duplicate unauthenticated observations and union
                // capability hints (bounded). Neither reachability nor a known
                // fingerprint claim authorizes a connection.
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
pub async fn scan_nearby_peers(
    duration: Duration,
) -> std::result::Result<Vec<ResolvedNearbyPeer>, ActiveScanError> {
    use mdns_sd::ServiceDaemon;

    let daemon = ServiceDaemon::new().map_err(ActiveScanError::transport_start)?;
    let monitor = daemon.monitor().map_err(ActiveScanError::transport_start)?;
    let receiver = daemon
        .browse(SKYBRIDGE_SERVICE_TYPE)
        .map_err(ActiveScanError::transport_start)?;

    let deadline = tokio::time::Instant::now() + duration;
    let mut peers: BTreeMap<String, ResolvedNearbyPeer> = BTreeMap::new();
    let mut ambiguous_device_refs = BTreeSet::new();

    let scan_result = loop {
        tokio::select! {
            event = receiver.recv_async() => {
                if let Err(error) = record_scan_event(
                    event,
                    &mut peers,
                    &mut ambiguous_device_refs,
                ) {
                    break Err(error);
                }
            }
            event = monitor.recv_async() => {
                if let Err(error) = validate_daemon_event(event) {
                    break Err(error);
                }
            }
            _ = tokio::time::sleep_until(deadline) => break Ok(()),
        }
    };

    let shutdown_result = shutdown_daemon(&daemon).await;
    match (scan_result, shutdown_result) {
        (Ok(()), Ok(())) => Ok(peers.into_values().collect()),
        (Err(scan_error), Ok(())) => Err(scan_error),
        (Ok(()), Err(shutdown_error)) => Err(shutdown_error),
        (Err(scan_error), Err(shutdown_error)) => {
            Err(scan_error.with_shutdown_failure(shutdown_error))
        }
    }
}

async fn shutdown_daemon(
    daemon: &mdns_sd::ServiceDaemon,
) -> std::result::Result<(), ActiveScanError> {
    let receiver = daemon.shutdown().map_err(ActiveScanError::scan_runtime)?;
    match tokio::time::timeout(DAEMON_SHUTDOWN_TIMEOUT, receiver.recv_async()).await {
        Ok(Ok(mdns_sd::DaemonStatus::Shutdown)) => Ok(()),
        Ok(Ok(_)) => Err(ActiveScanError::scan_runtime(
            "mDNS service daemon returned a non-shutdown terminal status",
        )),
        Ok(Err(error)) => Err(ActiveScanError::scan_runtime(format!(
            "mDNS service daemon shutdown status failed: {error}"
        ))),
        Err(_) => Err(ActiveScanError::scan_runtime(format!(
            "mDNS service daemon did not confirm shutdown within {} seconds",
            DAEMON_SHUTDOWN_TIMEOUT.as_secs()
        ))),
    }
}

fn record_scan_event<E>(
    event: std::result::Result<mdns_sd::ServiceEvent, E>,
    peers: &mut BTreeMap<String, ResolvedNearbyPeer>,
    ambiguous_device_refs: &mut BTreeSet<String>,
) -> std::result::Result<(), ActiveScanError>
where
    E: std::fmt::Display,
{
    match event {
        Ok(mdns_sd::ServiceEvent::ServiceResolved(resolved)) => {
            let peer = resolved_peer_from_service(resolved.as_ref());
            record_resolved_peer(peer, peers, ambiguous_device_refs);
            Ok(())
        }
        Ok(_) => Ok(()),
        Err(error) => Err(ActiveScanError::scan_runtime(format!(
            "mDNS browse event stream failed: {error}"
        ))),
    }
}

fn record_resolved_peer(
    peer: ResolvedNearbyPeer,
    peers: &mut BTreeMap<String, ResolvedNearbyPeer>,
    ambiguous_device_refs: &mut BTreeSet<String>,
) {
    let Some(identity) = peer.identity.as_ref() else {
        return;
    };
    let device_ref = identity.device_ref();
    if ambiguous_device_refs.contains(&device_ref) {
        return;
    }
    if let Some(existing) = peers.get(&device_ref) {
        let identities_agree = existing
            .identity
            .as_ref()
            .is_some_and(|existing_identity| existing_identity.agrees_with(identity));
        if !identities_agree {
            peers.remove(&device_ref);
            ambiguous_device_refs.insert(device_ref);
            return;
        }
    }
    if let Some(existing) = peers.get_mut(&device_ref) {
        if (existing.display_name.trim().is_empty()
            || looks_like_network_locator(&existing.display_name))
            && !peer.display_name.trim().is_empty()
            && !looks_like_network_locator(&peer.display_name)
        {
            existing.display_name = peer.display_name;
        }
        merge_capabilities(&mut existing.capabilities, &peer.capabilities);
        existing
            .advertised_endpoints
            .extend(peer.advertised_endpoints);
        existing.advertised_endpoints.sort_unstable();
        existing.advertised_endpoints.dedup();
        existing
            .advertised_endpoints
            .truncate(MAX_ADVERTISED_ENDPOINTS_PER_DEVICE);
        existing.has_reachable_address =
            existing.has_reachable_address || peer.has_reachable_address;
        return;
    }
    if peers.len() < NearbyDiscoverySnapshotRegistry::MAX_DEVICES_PER_SNAPSHOT {
        peers.insert(device_ref, peer);
    }
}

fn validate_daemon_event<E>(
    event: std::result::Result<mdns_sd::DaemonEvent, E>,
) -> std::result::Result<(), ActiveScanError>
where
    E: std::fmt::Display,
{
    match event {
        Ok(mdns_sd::DaemonEvent::Error(error)) => Err(ActiveScanError::scan_runtime(format!(
            "mDNS service daemon reported a network error: {error}"
        ))),
        Ok(_) => Ok(()),
        Err(error) => Err(ActiveScanError::scan_runtime(format!(
            "mDNS daemon monitor stream failed: {error}"
        ))),
    }
}

fn resolved_peer_from_service(service: &mdns_sd::ResolvedService) -> ResolvedNearbyPeer {
    let txt = &service.txt_properties;
    let identity = match (
        consistent_txt_value(txt, TXT_DEVICE_IDENTITY_KEYS),
        consistent_txt_value(txt, TXT_FINGERPRINT_KEYS),
        consistent_txt_value(txt, TXT_SIGNING_ALGORITHM_KEYS),
    ) {
        (Ok(device_id), Ok(fingerprint), Ok(signing_algorithm)) => advertised_identity_from_fields(
            txt.get_property_val_str(TXT_KEY_IDENTITY),
            device_id,
            fingerprint,
            signing_algorithm,
        ),
        _ => None,
    };
    let display_name = first_txt_value(txt, TXT_DISPLAY_NAME_KEYS)
        .map(str::to_owned)
        .unwrap_or_else(|| instance_label_from_fullname(&service.fullname));
    let capabilities = first_txt_value(txt, TXT_CAPABILITY_KEYS)
        .map(parse_capability_list)
        .unwrap_or_default();
    let mut advertised_endpoints = service
        .addresses
        .iter()
        .map(mdns_sd::ScopedIp::to_ip_addr)
        .filter(|address| {
            !address.is_unspecified() && !address.is_multicast() && !address.is_loopback()
        })
        .map(|address| (address, service.port))
        .collect::<Vec<_>>();
    advertised_endpoints.sort_unstable();
    advertised_endpoints.dedup();
    advertised_endpoints.truncate(MAX_ADVERTISED_ENDPOINTS_PER_DEVICE);
    let has_reachable_address = service.port != 0 && !advertised_endpoints.is_empty();

    ResolvedNearbyPeer {
        identity,
        display_name,
        capabilities,
        has_reachable_address,
        advertised_endpoints,
    }
}

fn first_txt_value<'a>(txt: &'a mdns_sd::TxtProperties, keys: &[&str]) -> Option<&'a str> {
    keys.iter()
        .find_map(|key| txt.get_property_val_str(key))
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn consistent_txt_value<'a>(
    txt: &'a mdns_sd::TxtProperties,
    keys: &[&str],
) -> std::result::Result<Option<&'a str>, ()> {
    let mut observed = None;
    for key in keys {
        let Some(value) = txt
            .get_property_val_str(key)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        else {
            continue;
        };
        if observed.is_some_and(|existing| existing != value) {
            return Err(());
        }
        observed = Some(value);
    }
    Ok(observed)
}

fn advertised_identity_from_fields(
    legacy_public_key: Option<&str>,
    device_id: Option<&str>,
    fingerprint: Option<&str>,
    signing_algorithm: Option<&str>,
) -> Option<AdvertisedProtocolIdentity> {
    let decoded_public_key =
        legacy_public_key
            .and_then(decode_identity_key)
            .and_then(|public_key| {
                AdvertisedProtocolIdentity::from_public_key_claim(
                    public_key,
                    device_id,
                    signing_algorithm,
                )
            });
    let has_fingerprint_contract_field =
        device_id.is_some() || fingerprint.is_some() || signing_algorithm.is_some();
    let fingerprint_hint = if has_fingerprint_contract_field {
        Some(AdvertisedProtocolIdentity::from_fingerprint_claim(
            device_id,
            fingerprint?,
            signing_algorithm,
        )?)
    } else {
        None
    };

    match (decoded_public_key, fingerprint_hint) {
        (Some(public_key), Some(hint)) if public_key.agrees_with(&hint) => Some(public_key),
        (Some(_), Some(_)) => None,
        (Some(public_key), None) => Some(public_key),
        (None, Some(hint)) => Some(hint),
        (None, None) => None,
    }
}

/// Derive a stable, locator-free device reference from the canonical protocol
/// identity fingerprint. `fp-` + the complete fingerprint keeps
/// legacy full-key advertisements and Apple fingerprint-only advertisements on
/// the same reference without hashing the fingerprint a second time.
fn fingerprint_device_ref(fingerprint: &str) -> String {
    debug_assert!(ProtocolIdentityBinding::is_valid_fingerprint(fingerprint));
    let mut device_ref = String::with_capacity(3 + fingerprint.len());
    device_ref.push_str("fp-");
    device_ref.push_str(fingerprint);
    device_ref
}

fn sanitized_display_name(raw: &str, device_ref: &str) -> String {
    let cleaned = clamp_public_text(raw);
    if cleaned.is_empty() || looks_like_network_locator(&cleaned) {
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
        if cleaned.is_empty() || looks_like_network_locator(&cleaned) {
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

fn instance_label_from_fullname(fullname: &str) -> String {
    let label = fullname
        .strip_suffix(&format!(".{SKYBRIDGE_SERVICE_TYPE}"))
        .or_else(|| fullname.split("._skybridge").next())
        .unwrap_or(fullname);
    clamp_public_text(label)
}

fn parse_capability_list(value: &str) -> Vec<String> {
    value
        .split(|character: char| character == ',' || character == ';' || character.is_whitespace())
        .map(str::trim)
        .filter(|token| !token.is_empty())
        .map(str::to_owned)
        .collect()
}

fn decode_identity_key(value: &str) -> Option<Vec<u8>> {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed.len() > MAX_ENCODED_IDENTITY_KEY_BYTES {
        return None;
    }
    let decoded = if let Some(bytes) = decode_hex(trimmed) {
        Some(bytes)
    } else {
        use base64::Engine as _;
        base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(trimmed)
            .ok()
            .or_else(|| {
                base64::engine::general_purpose::STANDARD
                    .decode(trimmed)
                    .ok()
            })
    }?;
    matches!(
        decoded.len(),
        ED25519_PUBLIC_KEY_BYTES | MLDSA65_PUBLIC_KEY_BYTES | MLDSA87_PUBLIC_KEY_BYTES
    )
    .then_some(decoded)
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

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};

    fn test_identity(seed: &[u8]) -> AdvertisedProtocolIdentity {
        let public_key = if seed.len() == ED25519_PUBLIC_KEY_BYTES {
            seed.to_vec()
        } else {
            Sha256::digest(seed).to_vec()
        };
        AdvertisedProtocolIdentity::from_public_key_claim(public_key, None, None)
            .expect("test public key must be valid")
    }

    fn test_device_ref(seed: &[u8]) -> String {
        test_identity(seed).device_ref()
    }

    fn peer(
        identity: Option<&[u8]>,
        name: &str,
        caps: &[&str],
        reachable: bool,
    ) -> ResolvedNearbyPeer {
        ResolvedNearbyPeer {
            identity: identity.map(test_identity),
            display_name: name.to_owned(),
            capabilities: caps.iter().map(|c| (*c).to_owned()).collect(),
            has_reachable_address: reachable,
            advertised_endpoints: reachable
                .then_some(("192.0.2.10".parse().expect("test address"), 7443))
                .into_iter()
                .collect(),
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
            DEFAULT_ACTIVE_SCAN_TTL_SECONDS,
        );
        assert_eq!(snapshot.source, ACTIVE_SCAN_SOURCE);
        assert_eq!(snapshot.scan_id, ACTIVE_SCAN_ID);
        assert_eq!(snapshot.devices.len(), 1);
        let device = &snapshot.devices[0];
        // No trust material -> candidate, and candidates are never connectable.
        assert_eq!(device.trust_status, NearbyDiscoveryTrustStatus::Candidate);
        assert!(!device.connectable);
        assert!(device.device_ref.starts_with("fp-"));
        assert!(!looks_like_network_locator(&device.device_ref));
    }

    #[test]
    fn known_fingerprint_claim_does_not_authorize_a_connection() {
        let identity = b"verified-peer-key";
        let device_ref = test_device_ref(identity);

        let snapshot = build_active_scan_snapshot(
            vec![peer(Some(identity), "Known Mac", &["file_transfer"], true)],
            DEFAULT_ACTIVE_SCAN_TTL_SECONDS,
        );
        let device = &snapshot.devices[0];
        assert_eq!(device.device_ref, device_ref);
        assert_eq!(device.trust_status, NearbyDiscoveryTrustStatus::Candidate);
        assert!(!device.connectable);
    }

    #[test]
    fn build_snapshot_does_not_mark_connectable_without_reachable_address() {
        let identity = b"verified-but-unreachable";

        let snapshot = build_active_scan_snapshot(
            vec![peer(Some(identity), "Unreachable", &[], false)],
            DEFAULT_ACTIVE_SCAN_TTL_SECONDS,
        );
        assert!(!snapshot.devices[0].connectable);
    }

    #[test]
    fn build_snapshot_skips_peers_without_protocol_identity() {
        let snapshot = build_active_scan_snapshot(
            vec![peer(None, "Anonymous", &["remote_desktop"], true)],
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
            "host.example.com".to_owned(),
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
        let device_ref = test_device_ref(b"abc");
        let name = sanitized_display_name("   ", &device_ref);
        assert!(name.starts_with("peer-"));
        assert!(!name.is_empty());

        let locator_name = sanitized_display_name("192.0.2.55", &device_ref);
        assert!(locator_name.starts_with("peer-"));
        assert!(!locator_name.contains("192.0.2.55"));

        let fqdn_name = sanitized_display_name("host.example.com", &device_ref);
        assert!(fqdn_name.starts_with("peer-"));
        assert!(!fqdn_name.contains("host.example.com"));
    }

    #[test]
    fn decode_identity_key_accepts_hex_and_base64() {
        let hex_key = "0a".repeat(ED25519_PUBLIC_KEY_BYTES);
        assert_eq!(
            decode_identity_key(&hex_key),
            Some(vec![0x0a; ED25519_PUBLIC_KEY_BYTES])
        );
        use base64::Engine as _;
        let raw_key = vec![0x5a; ED25519_PUBLIC_KEY_BYTES];
        let encoded = base64::engine::general_purpose::STANDARD.encode(&raw_key);
        assert_eq!(decode_identity_key(&encoded), Some(raw_key));
        assert_eq!(decode_identity_key(""), None);
        assert_eq!(decode_identity_key("0a0b0c"), None);
        assert_eq!(
            decode_identity_key(&"a".repeat(MAX_ENCODED_IDENTITY_KEY_BYTES + 1)),
            None
        );
    }

    #[test]
    fn apple_fingerprint_contract_is_a_typed_untrusted_hint() {
        let public_key = [0x41; ED25519_PUBLIC_KEY_BYTES];
        let fingerprint = ProtocolIdentityBinding::compute_fingerprint(
            ProtocolSigningAlgorithm::Ed25519,
            &public_key,
        );
        let identity = advertised_identity_from_fields(
            None,
            Some("device-ios-000001"),
            Some(&fingerprint),
            Some("Ed25519"),
        )
        .expect("canonical Apple identity hint should parse");

        assert!(matches!(
            &identity,
            AdvertisedProtocolIdentity::FingerprintClaim {
                device_id,
                algorithm: Some(ProtocolSigningAlgorithm::Ed25519),
                canonical_fingerprint,
            } if device_id == "device-ios-000001"
                && canonical_fingerprint == &ProtocolIdentityBinding::compute_fingerprint(
                    ProtocolSigningAlgorithm::Ed25519,
                    &public_key,
                )
        ));
        assert_eq!(identity.device_ref(), format!("fp-{fingerprint}"));
    }

    #[test]
    fn legacy_public_key_and_apple_fingerprint_resolve_to_one_reference() {
        let public_key = [0x52; ED25519_PUBLIC_KEY_BYTES];
        let public_key_hex = public_key
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let fingerprint = ProtocolIdentityBinding::compute_fingerprint(
            ProtocolSigningAlgorithm::Ed25519,
            &public_key,
        );
        let full_identity = advertised_identity_from_fields(
            Some(&public_key_hex),
            Some("device-ios-000002"),
            Some(&fingerprint),
            Some("Ed25519"),
        )
        .expect("matching key and hint should parse");
        let hint_identity = advertised_identity_from_fields(
            None,
            Some("device-ios-000002"),
            Some(&fingerprint),
            Some("Ed25519"),
        )
        .expect("fingerprint hint should parse");

        assert!(matches!(
            &full_identity,
            AdvertisedProtocolIdentity::RawPublicKeyClaim { .. }
        ));
        assert_eq!(full_identity.device_ref(), hint_identity.device_ref());
        assert!(full_identity.agrees_with(&hint_identity));
    }

    #[test]
    fn malformed_or_conflicting_apple_identity_fields_fail_closed() {
        let public_key = [0x63; ED25519_PUBLIC_KEY_BYTES];
        let public_key_hex = public_key
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let fingerprint = ProtocolIdentityBinding::compute_fingerprint(
            ProtocolSigningAlgorithm::Ed25519,
            &public_key,
        );
        let conflicting_fingerprint = "f".repeat(64);

        assert!(
            advertised_identity_from_fields(
                Some(&public_key_hex),
                Some("device-ios-000003"),
                Some(&conflicting_fingerprint),
                Some("Ed25519"),
            )
            .is_none()
        );
        assert!(
            advertised_identity_from_fields(
                None,
                Some("device-ios-000003"),
                Some(&fingerprint.to_uppercase()),
                Some("Ed25519"),
            )
            .is_none()
        );
        assert!(
            advertised_identity_from_fields(None, None, Some(&fingerprint), Some("Ed25519"),)
                .is_none()
        );
        assert!(
            advertised_identity_from_fields(
                None,
                Some("device-ios-000003"),
                Some(&fingerprint),
                Some("ed25519"),
            )
            .is_none()
        );
    }

    #[test]
    fn capability_parser_accepts_shared_apple_and_legacy_separators() {
        assert_eq!(
            parse_capability_list("file_transfer; remote_desktop,clipboard_sync"),
            vec!["file_transfer", "remote_desktop", "clipboard_sync"]
        );
    }

    #[test]
    fn conflicting_device_ids_for_one_fingerprint_are_ambiguous() {
        let fingerprint = ProtocolIdentityBinding::compute_fingerprint(
            ProtocolSigningAlgorithm::Ed25519,
            &[0x74; ED25519_PUBLIC_KEY_BYTES],
        );
        let first = ResolvedNearbyPeer {
            identity: AdvertisedProtocolIdentity::from_fingerprint_claim(
                Some("device-ios-000004"),
                &fingerprint,
                Some("Ed25519"),
            ),
            display_name: "First".to_owned(),
            capabilities: vec!["file_transfer".to_owned()],
            has_reachable_address: true,
            advertised_endpoints: vec![("192.0.2.20".parse().unwrap(), 7443)],
        };
        let second = ResolvedNearbyPeer {
            identity: AdvertisedProtocolIdentity::from_fingerprint_claim(
                Some("device-ios-000005"),
                &fingerprint,
                Some("Ed25519"),
            ),
            display_name: "Second".to_owned(),
            capabilities: vec!["remote_desktop".to_owned()],
            has_reachable_address: true,
            advertised_endpoints: vec![("192.0.2.21".parse().unwrap(), 7443)],
        };

        let snapshot =
            build_active_scan_snapshot(vec![first, second], DEFAULT_ACTIVE_SCAN_TTL_SECONDS);
        assert!(snapshot.devices.is_empty());
    }

    #[test]
    fn unresolved_or_invalid_identities_do_not_consume_the_device_budget() {
        let mut peers = BTreeMap::new();
        let mut ambiguous = BTreeSet::new();
        for index in 0..(NearbyDiscoverySnapshotRegistry::MAX_DEVICES_PER_SNAPSHOT * 2) {
            record_resolved_peer(
                peer(None, &format!("spoof-{index}"), &["file_transfer"], true),
                &mut peers,
                &mut ambiguous,
            );
        }
        assert!(peers.is_empty());

        let valid_identity = [0x42; ED25519_PUBLIC_KEY_BYTES];
        record_resolved_peer(
            peer(
                Some(&valid_identity),
                "Supported device",
                &["file_transfer"],
                true,
            ),
            &mut peers,
            &mut ambiguous,
        );
        assert_eq!(peers.len(), 1);
        assert!(peers.contains_key(&test_device_ref(&valid_identity)));
    }

    #[test]
    fn collection_deduplicates_by_identity_before_enforcing_the_device_budget() {
        let mut peers = BTreeMap::new();
        let mut ambiguous = BTreeSet::new();
        let identity = [0x24; ED25519_PUBLIC_KEY_BYTES];
        record_resolved_peer(
            peer(
                Some(&identity),
                "host.example.com",
                &["file_transfer"],
                true,
            ),
            &mut peers,
            &mut ambiguous,
        );
        record_resolved_peer(
            peer(Some(&identity), "Nearby Mac", &["remote_desktop"], true),
            &mut peers,
            &mut ambiguous,
        );
        assert_eq!(peers.len(), 1);
        let collected = peers
            .get(&test_device_ref(&identity))
            .expect("identity should be collected once");
        assert_eq!(collected.display_name, "Nearby Mac");
        assert!(collected.capabilities.contains(&"file_transfer".to_owned()));
        assert!(
            collected
                .capabilities
                .contains(&"remote_desktop".to_owned())
        );
    }

    #[test]
    fn instance_label_strips_service_type() {
        assert_eq!(
            instance_label_from_fullname("Studio Mac._skybridge._tcp.local."),
            "Studio Mac"
        );
    }

    #[test]
    fn active_scan_result_keeps_locators_out_of_public_snapshot() {
        let mut resolved = peer(
            Some(b"ephemeral-address-peer"),
            "Nearby Mac",
            &["file_transfer"],
            true,
        );
        resolved.advertised_endpoints.extend([
            ("127.0.0.1".parse().unwrap(), 7443),
            ("0.0.0.0".parse().unwrap(), 7443),
        ]);
        let result = active_scan_result_from_peers(vec![resolved], DEFAULT_ACTIVE_SCAN_TTL_SECONDS);

        assert_eq!(result.snapshot.devices.len(), 1);
        assert_eq!(result.advertised_endpoints.len(), 1);
        let observation = &result.advertised_endpoints[0];
        assert_eq!(observation.address, "192.0.2.10".parse::<IpAddr>().unwrap());
        assert_eq!(observation.port, 7443);
        assert!(observation.expires_at > observation.observed_at);
        assert_eq!(
            observation.expires_at - observation.observed_at,
            time::Duration::seconds(ADVERTISED_ENDPOINT_TTL_SECONDS)
        );

        let persisted = serde_json::to_string(&result.snapshot).expect("snapshot should serialize");
        assert!(!persisted.contains("192.0.2.10"));
        assert!(!persisted.contains("7443"));
        assert_eq!(
            result.snapshot.devices[0].trust_status,
            NearbyDiscoveryTrustStatus::Candidate
        );
        assert!(!result.snapshot.devices[0].connectable);
    }

    #[tokio::test]
    async fn active_scan_rejects_out_of_bounds_duration_before_network_io() {
        for duration in [
            Duration::ZERO,
            Duration::from_secs(31),
            Duration::from_millis(1_500),
        ] {
            let error = run_active_scan(duration)
                .await
                .expect_err("invalid duration must fail before transport startup");
            assert_eq!(error.kind(), ActiveScanFailureKind::InvalidRequest);
            assert_eq!(error.stage(), ActiveScanFailureStage::RequestValidation);
        }
    }

    #[test]
    fn active_scan_transport_errors_preserve_stable_stage_and_permission_semantics() {
        let permission = ActiveScanError::transport_start(
            "failed to create signal socket: Operation not permitted (os error 1)",
        );
        assert_eq!(permission.kind(), ActiveScanFailureKind::PermissionDenied);
        assert_eq!(permission.stage(), ActiveScanFailureStage::TransportStart);

        let unavailable =
            ActiveScanError::transport_start("failed to initialize mDNS daemon transport");
        assert_eq!(
            unavailable.kind(),
            ActiveScanFailureKind::TransportUnavailable
        );
        assert_eq!(unavailable.stage(), ActiveScanFailureStage::TransportStart);

        let runtime = ActiveScanError::scan_runtime("daemon monitor channel closed");
        assert_eq!(runtime.kind(), ActiveScanFailureKind::TransportUnavailable);
        assert_eq!(runtime.stage(), ActiveScanFailureStage::ScanRuntime);
    }

    #[test]
    fn active_scan_event_stream_error_is_not_projected_as_success() {
        let mut peers = BTreeMap::new();
        let mut ambiguous = BTreeSet::new();
        let event: std::result::Result<mdns_sd::ServiceEvent, &str> =
            Err("event channel closed unexpectedly");
        let error = record_scan_event(event, &mut peers, &mut ambiguous)
            .expect_err("event stream errors must fail the active scan");
        assert!(error.to_string().contains("event stream failed"));
        assert_eq!(error.stage(), ActiveScanFailureStage::ScanRuntime);
        assert!(peers.is_empty());

        let monitor_event: std::result::Result<mdns_sd::DaemonEvent, &str> =
            Err("monitor channel closed unexpectedly");
        let error = validate_daemon_event(monitor_event)
            .expect_err("daemon monitor errors must fail the active scan");
        assert!(error.to_string().contains("monitor stream failed"));
        assert_eq!(error.stage(), ActiveScanFailureStage::ScanRuntime);
    }
}
