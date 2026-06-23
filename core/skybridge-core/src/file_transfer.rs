use crate::channel::{AdapterChannelBinding, ChannelProfile};
use crate::frame::FRAME_HEADER_LEN;
use crate::transport::{SkyBridgeChannel, SkyBridgeReliability};
use sha2::{Digest, Sha256};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

pub const FILE_TRANSFER_SERVICE_TYPE: &str = "_skybridge-transfer._tcp";
pub const FILE_TRANSFER_MANIFEST_VERSION: u16 = 1;
pub const DEFAULT_FILE_TRANSFER_CHUNK_SIZE: u64 = 1024 * 1024;
pub const MAX_FILE_TRANSFER_CANDIDATES: usize = 8;
pub const MAX_FILE_TRANSFER_MANIFEST_FILES: usize = 64;
pub const MAX_FILE_TRANSFER_CHUNK_SIZE: u64 = 16 * 1024 * 1024;
pub const MAX_FILE_TRANSFER_MANIFEST_BYTES: u64 = 1 << 40;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileTransferAddressClass {
    Invalid,
    BonjourService,
    LinkLocal,
    LanDirect,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileTransferRouteSource {
    AuthenticatedSession,
    RecentAuthenticatedInboundTransfer,
    ClassicSessionRegistry,
    PresenceOutbound,
    PresenceInbound,
    Unified,
    Manual,
    BonjourResolved,
    Unknown,
}

impl FileTransferRouteSource {
    const fn priority(self) -> u8 {
        match self {
            Self::AuthenticatedSession => 0,
            Self::RecentAuthenticatedInboundTransfer => 1,
            Self::ClassicSessionRegistry => 2,
            Self::PresenceOutbound => 3,
            Self::PresenceInbound => 4,
            Self::BonjourResolved => 5,
            Self::Unified => 6,
            Self::Manual => 7,
            Self::Unknown => 8,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileTransferPortProvenance {
    Unknown,
    ListenerTruth,
    PresenceDescriptor,
    PairingPayload,
    HeartbeatPayload,
    RegistryState,
    ManualInput,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileTransferManifestMode {
    IntentOnly,
    Transfer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileTransferReadinessStatus {
    Blocked,
    IntentOnly,
    Ready,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileTransferReadinessCode {
    Ok,
    IntentOnlyNoFiles,
    MissingRoute,
    TooManyCandidates,
    MissingIdentity,
    TargetPeerMismatch,
    UnsupportedServiceType,
    InvalidHost,
    RequestedPeerToPeerRoute,
    UnresolvedBonjourRoute,
    ResolvedPeerToPeerRoute,
    InvalidPort,
    RouteStalePort,
    RouteProvenanceMismatch,
    MissingFileChannel,
    InvalidManifest,
    ManifestPathRejected,
    ManifestHashRejected,
    ManifestTooLarge,
    ByteCountOverflow,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileTransferChannelBindingKind {
    AppleStream,
    AppleDatagram,
    MsQuicStream,
    MsQuicDatagram,
    WebRtcDataChannel,
    RelayStream,
    TcpStream,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTransferRouteCandidate {
    pub peer_id: String,
    pub device_name: String,
    pub requested_host: String,
    pub resolved_host: Option<String>,
    pub service_type: Option<String>,
    pub port: Option<u16>,
    pub route_source: FileTransferRouteSource,
    pub port_provenance: FileTransferPortProvenance,
    pub listener_generation: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTransferSelectedRoute {
    pub peer_id: String,
    pub device_name: String,
    pub host: String,
    pub port: u16,
    pub route_source: FileTransferRouteSource,
    pub address_class: FileTransferAddressClass,
    pub listener_generation: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTransferManifestFile {
    pub display_name: String,
    pub relative_path: String,
    pub byte_len: u64,
    pub sha256_hex: String,
    pub mime_type: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTransferManifestPlan {
    pub version: u16,
    pub file_count: usize,
    pub total_bytes: u64,
    pub total_chunks: u64,
    pub chunk_size: u64,
    pub digest: [u8; 32],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileTransferChannelMapping {
    pub channel: SkyBridgeChannel,
    pub reliability: SkyBridgeReliability,
    pub binding_kind: FileTransferChannelBindingKind,
    pub head_of_line_isolated: bool,
}

impl FileTransferChannelMapping {
    pub fn from_channel_profile(profile: &ChannelProfile) -> Self {
        Self {
            channel: profile.channel,
            reliability: profile.reliability,
            binding_kind: map_channel_binding_kind(&profile.binding),
            head_of_line_isolated: profile.binding.isolates_head_of_line_blocking(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTransferReadinessRequest {
    pub target_peer_id: Option<String>,
    pub required_listener_generation: Option<u64>,
    pub route_candidates: Vec<FileTransferRouteCandidate>,
    pub manifest_mode: FileTransferManifestMode,
    pub files: Vec<FileTransferManifestFile>,
    pub chunk_size: u64,
    pub channel_mappings: Vec<FileTransferChannelMapping>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTransferReadinessVerdict {
    pub status: FileTransferReadinessStatus,
    pub code: FileTransferReadinessCode,
    pub selected_route: Option<FileTransferSelectedRoute>,
    pub manifest: Option<FileTransferManifestPlan>,
    pub file_channel: Option<FileTransferChannelMapping>,
    pub audit: String,
    pub frame_header_len: usize,
}

impl FileTransferReadinessVerdict {
    fn blocked(code: FileTransferReadinessCode, audit: impl Into<String>) -> Self {
        Self {
            status: FileTransferReadinessStatus::Blocked,
            code,
            selected_route: None,
            manifest: None,
            file_channel: None,
            audit: audit.into(),
            frame_header_len: FRAME_HEADER_LEN,
        }
    }

    fn intent_only(file_channel: Option<FileTransferChannelMapping>) -> Self {
        Self {
            status: FileTransferReadinessStatus::IntentOnly,
            code: FileTransferReadinessCode::IntentOnlyNoFiles,
            selected_route: None,
            manifest: None,
            file_channel,
            audit: "intent-only file-transfer plan; no files or route are ready".into(),
            frame_header_len: FRAME_HEADER_LEN,
        }
    }
}

pub fn classify_file_transfer_host(raw: &str) -> FileTransferAddressClass {
    match normalize_ip_host(raw) {
        Some((_, ip)) if is_link_local(ip) => FileTransferAddressClass::LinkLocal,
        Some((_, ip)) if is_rejected_ip(ip) => FileTransferAddressClass::Invalid,
        Some(_) => FileTransferAddressClass::LanDirect,
        None => FileTransferAddressClass::Invalid,
    }
}

pub fn is_routable_file_transfer_lan_address(raw: &str) -> bool {
    classify_file_transfer_host(raw) == FileTransferAddressClass::LanDirect
}

pub fn prefers_peer_to_peer(raw: &str) -> bool {
    match normalize_ip_host(raw) {
        Some((_, ip)) => is_link_local(ip),
        None => true,
    }
}

pub fn plan_file_transfer_readiness(
    request: FileTransferReadinessRequest,
) -> FileTransferReadinessVerdict {
    if request.route_candidates.len() > MAX_FILE_TRANSFER_CANDIDATES {
        return FileTransferReadinessVerdict::blocked(
            FileTransferReadinessCode::TooManyCandidates,
            "too many file-transfer route candidates",
        );
    }

    let file_channel = find_file_channel(&request.channel_mappings);
    if request.manifest_mode == FileTransferManifestMode::IntentOnly {
        if !request.files.is_empty() {
            return FileTransferReadinessVerdict::blocked(
                FileTransferReadinessCode::InvalidManifest,
                "intent-only file-transfer plan must not carry files",
            );
        }
        return FileTransferReadinessVerdict::intent_only(file_channel);
    }

    let Some(file_channel) = file_channel else {
        return FileTransferReadinessVerdict::blocked(
            FileTransferReadinessCode::MissingFileChannel,
            "Core connection plan does not expose a file channel",
        );
    };

    let manifest = match plan_file_transfer_manifest(&request.files, request.chunk_size) {
        Ok(plan) => plan,
        Err(code) => {
            return FileTransferReadinessVerdict::blocked(
                code,
                format!("file-transfer manifest rejected: {code:?}"),
            )
        }
    };

    let selected_route = match select_file_transfer_route(
        &request.route_candidates,
        request.target_peer_id.as_deref(),
        request.required_listener_generation,
    ) {
        Ok(route) => route,
        Err(code) => {
            return FileTransferReadinessVerdict {
                status: FileTransferReadinessStatus::Blocked,
                code,
                selected_route: None,
                manifest: Some(manifest),
                file_channel: Some(file_channel),
                audit: format!("file-transfer route rejected: {code:?}"),
                frame_header_len: FRAME_HEADER_LEN,
            }
        }
    };

    FileTransferReadinessVerdict {
        status: FileTransferReadinessStatus::Ready,
        code: FileTransferReadinessCode::Ok,
        selected_route: Some(selected_route),
        manifest: Some(manifest),
        file_channel: Some(file_channel),
        audit: "file-transfer route and manifest are ready".into(),
        frame_header_len: FRAME_HEADER_LEN,
    }
}

pub fn plan_file_transfer_manifest(
    files: &[FileTransferManifestFile],
    chunk_size: u64,
) -> Result<FileTransferManifestPlan, FileTransferReadinessCode> {
    if files.is_empty() || files.len() > MAX_FILE_TRANSFER_MANIFEST_FILES {
        return Err(FileTransferReadinessCode::InvalidManifest);
    }
    if chunk_size == 0 || chunk_size > MAX_FILE_TRANSFER_CHUNK_SIZE {
        return Err(FileTransferReadinessCode::InvalidManifest);
    }

    let mut canonical_files = Vec::with_capacity(files.len());
    let mut total_bytes = 0u64;
    let mut total_chunks = 0u64;

    for file in files {
        let display_name = validate_display_name(&file.display_name)?;
        let relative_path = validate_relative_path(&file.relative_path)?;
        let sha256_hex = validate_sha256_hex(&file.sha256_hex)?;
        let mime_type = validate_optional_token(file.mime_type.as_deref())?;
        total_bytes = total_bytes
            .checked_add(file.byte_len)
            .ok_or(FileTransferReadinessCode::ByteCountOverflow)?;
        if total_bytes > MAX_FILE_TRANSFER_MANIFEST_BYTES {
            return Err(FileTransferReadinessCode::ManifestTooLarge);
        }
        total_chunks = total_chunks
            .checked_add(chunk_count(file.byte_len, chunk_size)?)
            .ok_or(FileTransferReadinessCode::ByteCountOverflow)?;
        canonical_files.push(CanonicalManifestFile {
            display_name,
            relative_path,
            byte_len: file.byte_len,
            sha256_hex,
            mime_type,
        });
    }

    canonical_files.sort_by(|lhs, rhs| {
        lhs.relative_path
            .cmp(&rhs.relative_path)
            .then(lhs.display_name.cmp(&rhs.display_name))
            .then(lhs.byte_len.cmp(&rhs.byte_len))
    });

    Ok(FileTransferManifestPlan {
        version: FILE_TRANSFER_MANIFEST_VERSION,
        file_count: canonical_files.len(),
        total_bytes,
        total_chunks,
        chunk_size,
        digest: manifest_digest(&canonical_files, chunk_size),
    })
}

pub fn select_file_transfer_route(
    candidates: &[FileTransferRouteCandidate],
    target_peer_id: Option<&str>,
    required_listener_generation: Option<u64>,
) -> Result<FileTransferSelectedRoute, FileTransferReadinessCode> {
    if candidates.is_empty() {
        return Err(FileTransferReadinessCode::MissingRoute);
    }

    let mut ordered = candidates.iter().collect::<Vec<_>>();
    ordered.sort_by_key(|candidate| candidate.route_source.priority());

    let mut first_error = None;
    for candidate in ordered {
        match validate_file_transfer_candidate(
            candidate,
            target_peer_id,
            required_listener_generation,
        ) {
            Ok(route) => return Ok(route),
            Err(code) => first_error.get_or_insert(code),
        };
    }

    Err(first_error.unwrap_or(FileTransferReadinessCode::MissingRoute))
}

pub fn validate_file_transfer_candidate(
    candidate: &FileTransferRouteCandidate,
    target_peer_id: Option<&str>,
    required_listener_generation: Option<u64>,
) -> Result<FileTransferSelectedRoute, FileTransferReadinessCode> {
    let peer_id = normalized_identity(&candidate.peer_id)
        .ok_or(FileTransferReadinessCode::MissingIdentity)?;
    if let Some(target_peer_id) = target_peer_id.and_then(normalized_identity) {
        if peer_id != target_peer_id {
            return Err(FileTransferReadinessCode::TargetPeerMismatch);
        }
    }

    let port = candidate
        .port
        .filter(|port| *port > 0)
        .ok_or(FileTransferReadinessCode::InvalidPort)?;

    match candidate.port_provenance {
        FileTransferPortProvenance::ListenerTruth
        | FileTransferPortProvenance::PresenceDescriptor => {}
        FileTransferPortProvenance::PairingPayload
        | FileTransferPortProvenance::HeartbeatPayload
        | FileTransferPortProvenance::RegistryState => {
            return Err(FileTransferReadinessCode::RouteStalePort)
        }
        FileTransferPortProvenance::Unknown | FileTransferPortProvenance::ManualInput => {
            return Err(FileTransferReadinessCode::RouteProvenanceMismatch)
        }
    }

    if let Some(required_generation) = required_listener_generation {
        if candidate.listener_generation != Some(required_generation) {
            return Err(FileTransferReadinessCode::RouteStalePort);
        }
    }

    let service_type = candidate.service_type.as_deref().map(str::trim);
    let is_bonjour = service_type.is_some_and(|value| !value.is_empty());
    if let Some(service_type) = service_type {
        if !service_type.is_empty() && service_type != FILE_TRANSFER_SERVICE_TYPE {
            return Err(FileTransferReadinessCode::UnsupportedServiceType);
        }
    }

    let host = if is_bonjour {
        let resolved = candidate
            .resolved_host
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or(FileTransferReadinessCode::UnresolvedBonjourRoute)?;
        normalize_ready_host(resolved, true)?
    } else {
        let requested_host = candidate.requested_host.trim();
        if classify_file_transfer_host(requested_host) == FileTransferAddressClass::LinkLocal {
            return Err(FileTransferReadinessCode::RequestedPeerToPeerRoute);
        }
        let route_host = candidate
            .resolved_host
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or(requested_host);
        normalize_ready_host(route_host, false)?
    };

    Ok(FileTransferSelectedRoute {
        peer_id,
        device_name: candidate.device_name.trim().to_string(),
        host,
        port,
        route_source: candidate.route_source,
        address_class: FileTransferAddressClass::LanDirect,
        listener_generation: candidate.listener_generation,
    })
}

fn find_file_channel(
    mappings: &[FileTransferChannelMapping],
) -> Option<FileTransferChannelMapping> {
    mappings
        .iter()
        .copied()
        .find(|mapping| mapping.channel == SkyBridgeChannel::File)
}

fn map_channel_binding_kind(binding: &AdapterChannelBinding) -> FileTransferChannelBindingKind {
    match binding {
        AdapterChannelBinding::AppleStream { .. } => FileTransferChannelBindingKind::AppleStream,
        AdapterChannelBinding::AppleDatagram { .. } => {
            FileTransferChannelBindingKind::AppleDatagram
        }
        AdapterChannelBinding::MsQuicStream { .. } => FileTransferChannelBindingKind::MsQuicStream,
        AdapterChannelBinding::MsQuicDatagram { .. } => {
            FileTransferChannelBindingKind::MsQuicDatagram
        }
        AdapterChannelBinding::WebRtcDataChannel { .. } => {
            FileTransferChannelBindingKind::WebRtcDataChannel
        }
        AdapterChannelBinding::RelayStream { .. } => FileTransferChannelBindingKind::RelayStream,
        AdapterChannelBinding::TcpStream { .. } => FileTransferChannelBindingKind::TcpStream,
    }
}

fn normalize_ready_host(
    raw: &str,
    from_bonjour: bool,
) -> Result<String, FileTransferReadinessCode> {
    match normalize_ip_host(raw) {
        Some((_, ip)) if is_link_local(ip) => {
            if from_bonjour {
                Err(FileTransferReadinessCode::ResolvedPeerToPeerRoute)
            } else {
                Err(FileTransferReadinessCode::RequestedPeerToPeerRoute)
            }
        }
        Some((_, ip)) if is_rejected_ip(ip) => Err(FileTransferReadinessCode::InvalidHost),
        Some((host, _)) => Ok(host),
        None => Err(FileTransferReadinessCode::InvalidHost),
    }
}

fn normalize_ip_host(raw: &str) -> Option<(String, IpAddr)> {
    let mut token = raw.trim().to_ascii_lowercase();
    if token.is_empty() {
        return None;
    }
    for prefix in ["host:", "peer:", "ip:"] {
        if let Some(rest) = token.strip_prefix(prefix) {
            token = rest.to_string();
            break;
        }
    }
    if token.starts_with('[') {
        let closing = token.find(']')?;
        let suffix = &token[closing + 1..];
        if suffix.is_empty()
            || suffix
                .strip_prefix(':')
                .is_some_and(|value| !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()))
            || suffix
                .strip_prefix('.')
                .is_some_and(|value| !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()))
        {
            token = token[1..closing].to_string();
        }
    } else if !token.contains(':') {
        if let Some((host, port)) = token.rsplit_once(':') {
            if !host.is_empty() && port.bytes().all(|b| b.is_ascii_digit()) {
                token = host.to_string();
            }
        } else {
            let parts = token.split('.').collect::<Vec<_>>();
            if parts.len() == 5
                && parts[..4].iter().all(|part| part.parse::<u8>().is_ok())
                && parts[4].parse::<u16>().is_ok()
            {
                token = parts[..4].join(".");
            }
        }
    }

    let validation = token
        .split_once('%')
        .map(|(host, _)| host)
        .unwrap_or(token.as_str());
    let ip = validation.parse::<IpAddr>().ok()?;
    Some((token, ip))
}

fn is_link_local(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.octets()[0] == 169 && ip.octets()[1] == 254,
        IpAddr::V6(ip) => ip.is_unicast_link_local(),
    }
}

fn is_rejected_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            ip.is_unspecified()
                || ip.is_loopback()
                || ip.is_multicast()
                || ip == Ipv4Addr::new(255, 255, 255, 255)
        }
        IpAddr::V6(ip) => {
            ip.is_unspecified()
                || ip.is_loopback()
                || ip.is_multicast()
                || is_ipv6_documentation(ip)
        }
    }
}

fn is_ipv6_documentation(ip: Ipv6Addr) -> bool {
    ip.segments()[0] == 0x2001 && ip.segments()[1] == 0x0db8
}

fn normalized_identity(raw: &str) -> Option<String> {
    let value = raw.trim().to_ascii_lowercase();
    if value.is_empty() {
        return None;
    }
    if let Some(rest) = value.strip_prefix("id:") {
        if rest.is_empty() {
            return None;
        }
        return Some(rest.to_string());
    }
    Some(value)
}

fn validate_display_name(raw: &str) -> Result<String, FileTransferReadinessCode> {
    let value = raw.trim();
    if value.is_empty()
        || value == "."
        || value == ".."
        || value.chars().any(is_forbidden_path_scalar)
        || value.contains('/')
        || value.contains('\\')
        || value.contains(':')
    {
        return Err(FileTransferReadinessCode::ManifestPathRejected);
    }
    Ok(value.to_string())
}

fn validate_relative_path(raw: &str) -> Result<String, FileTransferReadinessCode> {
    let value = raw.trim();
    if value.is_empty()
        || value.starts_with('/')
        || value.starts_with('\\')
        || has_windows_drive_prefix(value)
        || value.chars().any(is_forbidden_path_scalar)
    {
        return Err(FileTransferReadinessCode::ManifestPathRejected);
    }

    let mut parts = Vec::new();
    for part in value.split(['/', '\\']) {
        if part.is_empty() || part == "." || part == ".." || part.contains(':') {
            return Err(FileTransferReadinessCode::ManifestPathRejected);
        }
        parts.push(part);
    }
    Ok(parts.join("/"))
}

fn has_windows_drive_prefix(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':'
}

fn is_forbidden_path_scalar(ch: char) -> bool {
    ch == '\0' || ch.is_control() || ch == '\u{2044}' || ch == '\u{2215}'
}

fn validate_sha256_hex(raw: &str) -> Result<String, FileTransferReadinessCode> {
    let value = raw.trim();
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(FileTransferReadinessCode::ManifestHashRejected);
    }
    Ok(value.to_string())
}

fn validate_optional_token(raw: Option<&str>) -> Result<Option<String>, FileTransferReadinessCode> {
    let Some(value) = raw.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(None);
    };
    if value.len() > 128 || value.chars().any(|ch| ch == '\0' || ch.is_control()) {
        return Err(FileTransferReadinessCode::InvalidManifest);
    }
    Ok(Some(value.to_string()))
}

fn chunk_count(byte_len: u64, chunk_size: u64) -> Result<u64, FileTransferReadinessCode> {
    if byte_len == 0 {
        return Ok(0);
    }
    byte_len
        .checked_add(chunk_size - 1)
        .ok_or(FileTransferReadinessCode::ByteCountOverflow)
        .map(|value| value / chunk_size)
}

#[derive(Debug)]
struct CanonicalManifestFile {
    display_name: String,
    relative_path: String,
    byte_len: u64,
    sha256_hex: String,
    mime_type: Option<String>,
}

fn manifest_digest(files: &[CanonicalManifestFile], chunk_size: u64) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(b"skybridge-file-transfer-manifest-v1");
    hasher.update(FILE_TRANSFER_MANIFEST_VERSION.to_be_bytes());
    hasher.update(chunk_size.to_be_bytes());
    hasher.update((files.len() as u64).to_be_bytes());
    for file in files {
        update_digest_str(&mut hasher, &file.display_name);
        update_digest_str(&mut hasher, &file.relative_path);
        hasher.update(file.byte_len.to_be_bytes());
        update_digest_str(&mut hasher, &file.sha256_hex);
        update_digest_str(&mut hasher, file.mime_type.as_deref().unwrap_or(""));
    }
    hasher.finalize().into()
}

fn update_digest_str(hasher: &mut Sha256, value: &str) {
    hasher.update((value.len() as u64).to_be_bytes());
    hasher.update(value.as_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    const HASH_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const HASH_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn file_channel() -> FileTransferChannelMapping {
        FileTransferChannelMapping {
            channel: SkyBridgeChannel::File,
            reliability: SkyBridgeReliability::ReliableOrdered,
            binding_kind: FileTransferChannelBindingKind::WebRtcDataChannel,
            head_of_line_isolated: true,
        }
    }

    fn ready_route() -> FileTransferRouteCandidate {
        FileTransferRouteCandidate {
            peer_id: "id:peer-1".into(),
            device_name: "Mac".into(),
            requested_host: "192.168.31.20".into(),
            resolved_host: None,
            service_type: None,
            port: Some(8080),
            route_source: FileTransferRouteSource::AuthenticatedSession,
            port_provenance: FileTransferPortProvenance::ListenerTruth,
            listener_generation: Some(7),
        }
    }

    fn manifest_file(name: &str, path: &str, bytes: u64, hash: &str) -> FileTransferManifestFile {
        FileTransferManifestFile {
            display_name: name.into(),
            relative_path: path.into(),
            byte_len: bytes,
            sha256_hex: hash.into(),
            mime_type: Some("application/octet-stream".into()),
        }
    }

    #[test]
    fn route_readiness_accepts_routable_listener_truth() {
        let request = FileTransferReadinessRequest {
            target_peer_id: Some("peer-1".into()),
            required_listener_generation: Some(7),
            route_candidates: vec![ready_route()],
            manifest_mode: FileTransferManifestMode::Transfer,
            files: vec![manifest_file("a.bin", "a.bin", 1_500_000, HASH_A)],
            chunk_size: DEFAULT_FILE_TRANSFER_CHUNK_SIZE,
            channel_mappings: vec![file_channel()],
        };

        let verdict = plan_file_transfer_readiness(request);

        assert_eq!(verdict.status, FileTransferReadinessStatus::Ready);
        assert_eq!(verdict.code, FileTransferReadinessCode::Ok);
        assert_eq!(
            verdict.selected_route.as_ref().unwrap().host,
            "192.168.31.20"
        );
        assert_eq!(verdict.selected_route.as_ref().unwrap().port, 8080);
        assert_eq!(verdict.manifest.as_ref().unwrap().file_count, 1);
        assert_eq!(verdict.manifest.as_ref().unwrap().total_chunks, 2);
        assert_eq!(
            verdict.file_channel.unwrap().binding_kind,
            FileTransferChannelBindingKind::WebRtcDataChannel
        );
    }

    #[test]
    fn route_readiness_rejects_link_local_and_unresolved_bonjour() {
        let link_local = FileTransferRouteCandidate {
            requested_host: "fe80::1%en0".into(),
            ..ready_route()
        };
        assert_eq!(
            validate_file_transfer_candidate(&link_local, None, Some(7)).unwrap_err(),
            FileTransferReadinessCode::RequestedPeerToPeerRoute
        );

        let unresolved_bonjour = FileTransferRouteCandidate {
            requested_host: "Mac".into(),
            resolved_host: None,
            service_type: Some(FILE_TRANSFER_SERVICE_TYPE.into()),
            ..ready_route()
        };
        assert_eq!(
            validate_file_transfer_candidate(&unresolved_bonjour, None, Some(7)).unwrap_err(),
            FileTransferReadinessCode::UnresolvedBonjourRoute
        );

        let resolved_link_local = FileTransferRouteCandidate {
            requested_host: "Mac".into(),
            resolved_host: Some("fe80::1%en0".into()),
            service_type: Some(FILE_TRANSFER_SERVICE_TYPE.into()),
            ..ready_route()
        };
        assert_eq!(
            validate_file_transfer_candidate(&resolved_link_local, None, Some(7)).unwrap_err(),
            FileTransferReadinessCode::ResolvedPeerToPeerRoute
        );
    }

    #[test]
    fn route_readiness_rejects_stale_port_provenance_and_generation() {
        let stale_port = FileTransferRouteCandidate {
            port: Some(49444),
            port_provenance: FileTransferPortProvenance::RegistryState,
            ..ready_route()
        };
        assert_eq!(
            validate_file_transfer_candidate(&stale_port, None, Some(7)).unwrap_err(),
            FileTransferReadinessCode::RouteStalePort
        );

        let stale_generation = FileTransferRouteCandidate {
            listener_generation: Some(6),
            ..ready_route()
        };
        assert_eq!(
            validate_file_transfer_candidate(&stale_generation, None, Some(7)).unwrap_err(),
            FileTransferReadinessCode::RouteStalePort
        );
    }

    #[test]
    fn intent_only_is_explicit_and_does_not_create_manifest() {
        let request = FileTransferReadinessRequest {
            target_peer_id: None,
            required_listener_generation: None,
            route_candidates: Vec::new(),
            manifest_mode: FileTransferManifestMode::IntentOnly,
            files: Vec::new(),
            chunk_size: DEFAULT_FILE_TRANSFER_CHUNK_SIZE,
            channel_mappings: vec![file_channel()],
        };

        let verdict = plan_file_transfer_readiness(request);

        assert_eq!(verdict.status, FileTransferReadinessStatus::IntentOnly);
        assert_eq!(verdict.code, FileTransferReadinessCode::IntentOnlyNoFiles);
        assert!(verdict.manifest.is_none());
        assert!(verdict.selected_route.is_none());
    }

    #[test]
    fn manifest_digest_is_stable_after_sorting_and_counts_chunks() {
        let first = vec![
            manifest_file("b.bin", "folder/b.bin", 2_097_153, HASH_B),
            manifest_file("a.bin", "a.bin", 0, HASH_A),
        ];
        let second = vec![
            manifest_file("a.bin", "a.bin", 0, HASH_A),
            manifest_file("b.bin", "folder/b.bin", 2_097_153, HASH_B),
        ];

        let a = plan_file_transfer_manifest(&first, DEFAULT_FILE_TRANSFER_CHUNK_SIZE).unwrap();
        let b = plan_file_transfer_manifest(&second, DEFAULT_FILE_TRANSFER_CHUNK_SIZE).unwrap();

        assert_eq!(a.digest, b.digest);
        assert_eq!(a.file_count, 2);
        assert_eq!(a.total_bytes, 2_097_153);
        assert_eq!(a.total_chunks, 3);
    }

    #[test]
    fn manifest_rejects_path_traversal_hash_errors_and_missing_file_channel() {
        let traversal = vec![manifest_file("a.bin", "../a.bin", 1, HASH_A)];
        assert_eq!(
            plan_file_transfer_manifest(&traversal, DEFAULT_FILE_TRANSFER_CHUNK_SIZE).unwrap_err(),
            FileTransferReadinessCode::ManifestPathRejected
        );

        let bad_hash = vec![manifest_file(
            "a.bin",
            "a.bin",
            1,
            &HASH_A.to_ascii_uppercase(),
        )];
        assert_eq!(
            plan_file_transfer_manifest(&bad_hash, DEFAULT_FILE_TRANSFER_CHUNK_SIZE).unwrap_err(),
            FileTransferReadinessCode::ManifestHashRejected
        );

        let request = FileTransferReadinessRequest {
            target_peer_id: Some("peer-1".into()),
            required_listener_generation: Some(7),
            route_candidates: vec![ready_route()],
            manifest_mode: FileTransferManifestMode::Transfer,
            files: vec![manifest_file("a.bin", "a.bin", 1, HASH_A)],
            chunk_size: DEFAULT_FILE_TRANSFER_CHUNK_SIZE,
            channel_mappings: Vec::new(),
        };
        let verdict = plan_file_transfer_readiness(request);
        assert_eq!(verdict.status, FileTransferReadinessStatus::Blocked);
        assert_eq!(verdict.code, FileTransferReadinessCode::MissingFileChannel);
    }

    #[test]
    fn address_classifier_rejects_non_lan_special_addresses() {
        assert_eq!(
            classify_file_transfer_host("169.254.1.1"),
            FileTransferAddressClass::LinkLocal
        );
        assert_eq!(
            classify_file_transfer_host("127.0.0.1"),
            FileTransferAddressClass::Invalid
        );
        assert_eq!(
            classify_file_transfer_host("0.0.0.0"),
            FileTransferAddressClass::Invalid
        );
        assert_eq!(
            classify_file_transfer_host("192.168.0.106"),
            FileTransferAddressClass::LanDirect
        );
    }
}
