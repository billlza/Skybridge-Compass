use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use directories::UserDirs;
use serde_json::json;
use skybridge_agent::{
    append_transfer_history_entry, ensure_device_identity, load_health_snapshot,
    load_managed_session_controls, load_session_registry, load_transfer_history,
    resolve_paths, save_session_transfer_request, wait_for_request_terminal_state,
};
use skybridge_core::{
    DEFAULT_FILE_TRANSFER_PORT, ManagedSessionDesiredState, NearbyPeer, ReceiveFileOptions,
    RuntimeSessionState, SendFileOptions, SessionFileTransferRequest, TransferDirection,
    TransferHistoryEntry, TransferStatus, advertise_file_transfer_service, discover_nearby_peers,
    receive_file_over_stream, send_file_over_stream,
};
use time::OffsetDateTime;
use tokio::net::{TcpListener, TcpStream, lookup_host};

pub async fn file_send(
    state_dir: Option<PathBuf>,
    source_path: PathBuf,
    target: String,
    discovery_timeout_seconds: u64,
    compress: bool,
    as_json: bool,
) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let identity = ensure_device_identity(&paths).await?;
    let started_at = OffsetDateTime::now_utc();

    if let Some(active_session) = resolve_active_session_target(&paths, target.trim()).await? {
        let metadata = std::fs::metadata(&source_path)
            .with_context(|| format!("failed to stat {}", source_path.display()))?;
        let file_name = source_path
            .file_name()
            .and_then(|value| value.to_str())
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| anyhow!("source path has no valid file name"))?
            .to_owned();
        let request = SessionFileTransferRequest::new_outgoing(
            active_session.session_id.clone(),
            source_path.display().to_string(),
            file_name.clone(),
            i64::try_from(metadata.len()).context("file size overflow")?,
            active_session.device_id.clone(),
            Some(active_session.label.clone()),
        );
        save_session_transfer_request(&paths, &request).await?;
        let completed = wait_for_request_terminal_state(&paths, &request.request_id).await?;
        if completed.state != skybridge_core::SessionTransferRequestState::Completed {
            bail!(
                "{}",
                completed
                    .error
                    .unwrap_or_else(|| "session file transfer failed".to_owned())
            );
        }
        if as_json {
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({
                    "transfer_id": completed.transfer_id.as_deref().unwrap_or(&completed.request_id),
                    "file_name": completed.file_name,
                    "file_size": completed.file_size,
                    "file_hash": completed.file_hash,
                    "target": {
                        "label": active_session.label,
                        "device_id": active_session.device_id,
                        "session_id": active_session.session_id,
                        "route_source": "session:data_channel",
                    }
                }))?
            );
        } else {
            println!(
                "Sent {} to {} via active session {}",
                completed.file_name, active_session.label, active_session.session_id
            );
            println!(
                "Transfer ID: {}",
                completed.transfer_id.as_deref().unwrap_or(&completed.request_id)
            );
            if let Some(file_hash) = completed.file_hash.as_deref() {
                println!("SHA-256: {file_hash}");
            }
            println!("Route Source: session:data_channel");
        }
        return Ok(());
    }

    let mut history_entry = build_outgoing_history_entry(
        &source_path,
        started_at,
        target.trim(),
        Some("pending".to_owned()),
    )?;

    let discovered = discover_nearby_peers(Duration::from_secs(
        discovery_timeout_seconds.max(1),
    ))
    .await?;
    let resolved = resolve_target(
        target.trim(),
        &discovered,
        &identity.state.device.device_id,
    )?;
    history_entry.remote_label = Some(resolved.label.clone());
    history_entry.remote_device_id = resolved.device_id.clone();
    history_entry.remote_address = Some(format!("{}:{}", resolved.address, resolved.port));
    history_entry.route_source = Some(resolved.route_source.clone());

    let mut stream = connect_to_target(&resolved.address, resolved.port).await?;
    let compression = compress.then_some("zlib".to_owned());
    let send_options = SendFileOptions {
        sender_device_id: Some(identity.state.device.device_id.clone()),
        sender_device_name: Some(identity.state.device.device_name.clone()),
        sender_platform: Some(format!(
            "{}-{}",
            std::env::consts::OS,
            std::env::consts::ARCH
        )),
        sender_os_version: None,
        sender_model_name: None,
        sender_chip: None,
        compression: compression.clone(),
        ..SendFileOptions::default()
    };

    let send_result = match send_file_over_stream(&mut stream, &source_path, &send_options).await {
        Ok(result) => result,
        Err(error) => {
            history_entry.status = TransferStatus::Failed;
            history_entry.completed_at = Some(OffsetDateTime::now_utc());
            history_entry.error = Some(error.to_string());
            history_entry.compression = compression;
            append_transfer_history_entry(&paths, history_entry).await?;
            return Err(error);
        }
    };

    history_entry.transfer_id = send_result.transfer_id.clone();
    history_entry.status = TransferStatus::Completed;
    history_entry.completed_at = Some(OffsetDateTime::now_utc());
    history_entry.file_hash = Some(send_result.file_hash.clone());
    history_entry.compression = send_result.compression.clone();
    append_transfer_history_entry(&paths, history_entry).await?;

    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "transfer_id": send_result.transfer_id,
                "file_name": send_result.file_name,
                "file_size": send_result.file_size,
                "file_hash": send_result.file_hash,
                "compression": send_result.compression,
                "target": {
                    "label": resolved.label,
                    "device_id": resolved.device_id,
                    "address": resolved.address,
                    "port": resolved.port,
                    "route_source": resolved.route_source,
                }
            }))?
        );
    } else {
        println!(
            "Sent {} to {} via {}:{}",
            send_result.file_name, resolved.label, resolved.address, resolved.port
        );
        println!("Transfer ID: {}", send_result.transfer_id);
        println!("SHA-256: {}", send_result.file_hash);
        println!("Route Source: {}", resolved.route_source);
    }
    Ok(())
}

pub async fn file_receive(
    state_dir: Option<PathBuf>,
    output_dir: Option<PathBuf>,
    requested_port: u16,
    once: bool,
) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let identity = ensure_device_identity(&paths).await?;
    let output_dir = resolve_receive_directory(output_dir)?;
    tokio::fs::create_dir_all(&output_dir).await?;

    let listener = bind_listener(requested_port).await?;
    let bound_port = listener.local_addr()?.port();
    let _advertisement = advertise_file_transfer_service(
        &identity.state.device.device_name,
        &identity.state.device.device_name,
        Some(&identity.state.device.device_id),
        identity.state.device.public_key_fingerprint.as_deref(),
        bound_port,
    )?;

    println!(
        "Receiving files into {} on port {}. Press Ctrl+C to stop.",
        output_dir.display(),
        bound_port
    );

    loop {
        tokio::select! {
            accept = listener.accept() => {
                let (mut socket, peer_addr) = accept?;
                let started_at = OffsetDateTime::now_utc();
                match receive_file_over_stream(&mut socket, &ReceiveFileOptions::new(output_dir.clone())).await {
                    Ok(received) => {
                        let sender_label = received
                            .sender_device_name
                            .clone()
                            .unwrap_or_else(|| peer_addr.ip().to_string());
                        append_transfer_history_entry(
                            &paths,
                            TransferHistoryEntry {
                                transfer_id: received.transfer_id.clone(),
                                direction: TransferDirection::Incoming,
                                status: TransferStatus::Completed,
                                file_name: received.file_name.clone(),
                                file_size: received.file_size,
                                local_path: Some(received.saved_path.display().to_string()),
                                remote_label: Some(sender_label.clone()),
                                remote_device_id: received.sender_device_id.clone(),
                                remote_address: Some(peer_addr.to_string()),
                                route_source: Some("nearby:tcp_listener".to_owned()),
                                compression: received.compression.clone(),
                                file_hash: Some(received.file_hash.clone()),
                                error: None,
                                started_at,
                                completed_at: Some(OffsetDateTime::now_utc()),
                            },
                        )
                        .await?;
                        println!(
                            "Received {} from {}",
                            received.file_name, sender_label
                        );
                        println!("Saved to: {}", received.saved_path.display());
                        println!("SHA-256: {}", received.file_hash);
                    }
                    Err(error) => {
                        append_transfer_history_entry(
                            &paths,
                            TransferHistoryEntry {
                                transfer_id: format!("failed-{}", OffsetDateTime::now_utc().unix_timestamp_nanos()),
                                direction: TransferDirection::Incoming,
                                status: TransferStatus::Failed,
                                file_name: "unknown".to_owned(),
                                file_size: 0,
                                local_path: None,
                                remote_label: Some(peer_addr.ip().to_string()),
                                remote_device_id: None,
                                remote_address: Some(peer_addr.to_string()),
                                route_source: Some("nearby:tcp_listener".to_owned()),
                                compression: None,
                                file_hash: None,
                                error: Some(error.to_string()),
                                started_at,
                                completed_at: Some(OffsetDateTime::now_utc()),
                            },
                        )
                        .await?;
                        eprintln!("Receive failed from {}: {}", peer_addr, error);
                    }
                }

                if once {
                    break;
                }
            }
            _ = tokio::signal::ctrl_c() => {
                println!("Stopping file receiver");
                break;
            }
        }
    }
    Ok(())
}

pub async fn file_history(state_dir: Option<PathBuf>, as_json: bool) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let history = load_transfer_history(&paths).await?;
    if as_json {
        println!("{}", serde_json::to_string_pretty(&history)?);
        return Ok(());
    }

    if history.entries.is_empty() {
        println!("No file transfer history recorded yet");
        return Ok(());
    }

    for entry in history.entries {
        let completed = entry
            .completed_at
            .map(|value: OffsetDateTime| value.to_string())
            .unwrap_or_else(|| "<pending>".to_owned());
        println!(
            "{} {:?} {:?} remote={} path={} completed={}",
            entry.file_name,
            entry.direction,
            entry.status,
            entry.remote_label.unwrap_or_else(|| "<unknown>".to_owned()),
            entry.local_path.unwrap_or_else(|| "<none>".to_owned()),
            completed
        );
        if let Some(error) = entry.error {
            println!("  error={error}");
        }
    }
    Ok(())
}

#[derive(Debug, Clone)]
struct ResolvedTransferTarget {
    label: String,
    device_id: Option<String>,
    address: String,
    port: u16,
    route_source: String,
}

#[derive(Debug, Clone)]
struct ActiveSessionTarget {
    session_id: String,
    device_id: Option<String>,
    label: String,
}

fn build_outgoing_history_entry(
    source_path: &Path,
    started_at: OffsetDateTime,
    remote_label: &str,
    route_source: Option<String>,
) -> Result<TransferHistoryEntry> {
    let metadata = std::fs::metadata(source_path)
        .with_context(|| format!("failed to stat {}", source_path.display()))?;
    let file_name = source_path
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("source path has no valid file name"))?
        .to_owned();
    Ok(TransferHistoryEntry {
        transfer_id: format!("pending-{}", started_at.unix_timestamp_nanos()),
        direction: TransferDirection::Outgoing,
        status: TransferStatus::Failed,
        file_name,
        file_size: i64::try_from(metadata.len()).context("file size overflow")?,
        local_path: Some(source_path.display().to_string()),
        remote_label: Some(remote_label.to_owned()),
        remote_device_id: None,
        remote_address: None,
        route_source,
        compression: None,
        file_hash: None,
        error: None,
        started_at,
        completed_at: None,
    })
}

fn resolve_receive_directory(output_dir: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(output_dir) = output_dir {
        return Ok(output_dir);
    }
    if let Some(user_dirs) = UserDirs::new() {
        if let Some(download_dir) = user_dirs.download_dir() {
            return Ok(download_dir.join("SkyBridge"));
        }
    }
    std::env::current_dir()
        .map(|path| path.join("SkyBridge"))
        .context("failed to resolve current directory for file receive")
}

async fn resolve_active_session_target(
    paths: &skybridge_agent::AgentPaths,
    raw_target: &str,
) -> Result<Option<ActiveSessionTarget>> {
    let target = raw_target.trim();
    if target.is_empty() {
        return Ok(None);
    }
    let controls = load_managed_session_controls(paths).await?;
    let active_controls = controls
        .active_controls()
        .into_iter()
        .filter(|control| control.desired_state == ManagedSessionDesiredState::Active)
        .map(|control| control.session_id)
        .collect::<std::collections::BTreeSet<_>>();
    if active_controls.is_empty() {
        return Ok(None);
    }
    let registry = load_session_registry(paths).await?;
    let health = load_health_snapshot(paths).await?;
    if health.is_none() {
        return Ok(None);
    }
    let normalized = target.to_ascii_lowercase();
    let matches = registry
        .values_sorted()
        .into_iter()
        .filter(|session| active_controls.contains(&session.session_id))
        .filter(|session| {
            matches!(session.state, RuntimeSessionState::Bound | RuntimeSessionState::Degraded)
                && session
                    .effective_established_readiness()
                    .is_some()
        })
        .filter(|session| {
            session.session_id.eq_ignore_ascii_case(&normalized)
                || session
                    .remote_device_id
                    .as_deref()
                    .is_some_and(|value| value.eq_ignore_ascii_case(&normalized))
                || session
                    .remote_device_name
                    .as_deref()
                    .is_some_and(|value| value.eq_ignore_ascii_case(&normalized))
        })
        .map(|session| ActiveSessionTarget {
            session_id: session.session_id.clone(),
            device_id: session.remote_device_id.clone(),
            label: session
                .remote_device_name
                .clone()
                .or_else(|| session.remote_device_id.clone())
                .unwrap_or_else(|| session.session_id.clone()),
        })
        .collect::<Vec<_>>();
    if matches.len() > 1 {
        let rendered = matches
            .iter()
            .map(|target| format!("{} [{}]", target.label, target.session_id))
            .collect::<Vec<_>>()
            .join(", ");
        bail!("target `{target}` matched multiple active sessions: {rendered}");
    }
    Ok(matches.into_iter().next())
}

async fn bind_listener(requested_port: u16) -> Result<TcpListener> {
    match TcpListener::bind(("0.0.0.0", requested_port)).await {
        Ok(listener) => Ok(listener),
        Err(error)
            if error.kind() == std::io::ErrorKind::AddrInUse
                && requested_port == DEFAULT_FILE_TRANSFER_PORT =>
        {
            TcpListener::bind(("0.0.0.0", 0))
                .await
                .context("failed to bind a fallback file transfer listener port")
        }
        Err(error) => Err(error).context("failed to bind file transfer listener"),
    }
}

fn resolve_target(
    raw_target: &str,
    discovered: &[NearbyPeer],
    local_device_id: &str,
) -> Result<ResolvedTransferTarget> {
    let target = raw_target.trim();
    if target.is_empty() {
        bail!("target cannot be empty");
    }

    let normalized = target.to_ascii_lowercase();
    let matches = discovered
        .iter()
        .filter(|peer| peer.device_id.as_deref() != Some(local_device_id))
        .filter(|peer| peer.is_transfer_capable())
        .filter(|peer| peer_matches(peer, &normalized))
        .collect::<Vec<_>>();
    if matches.len() == 1 {
        return resolved_from_peer(matches[0]);
    }
    if matches.len() > 1 {
        let labels = matches
            .iter()
            .map(|peer| format!("{} [{}]", peer.device_name, peer.peer_id))
            .collect::<Vec<_>>()
            .join(", ");
        bail!("target `{target}` is ambiguous: {labels}");
    }

    if let Some(endpoint) = parse_manual_endpoint(target) {
        return Ok(ResolvedTransferTarget {
            label: target.to_owned(),
            device_id: None,
            address: endpoint.address,
            port: endpoint.port,
            route_source: "manual".to_owned(),
        });
    }

    bail!("no nearby transfer-capable peer matched `{target}`")
}

fn resolved_from_peer(peer: &NearbyPeer) -> Result<ResolvedTransferTarget> {
    let address = peer
        .primary_address()
        .map(ToOwned::to_owned)
        .or_else(|| {
            (!peer.host_name.trim().is_empty()).then(|| peer.host_name.trim().trim_end_matches('.').to_owned())
        })
        .ok_or_else(|| anyhow!("peer `{}` has no usable network address", peer.peer_id))?;
    let port = peer.transfer_port.unwrap_or(peer.port);
    let route_source = if peer
        .advertised_services
        .iter()
        .any(|service| service == "_skybridge-transfer._tcp")
    {
        "discovery:transfer_bonjour"
    } else {
        "discovery:skybridge_bonjour"
    };
    Ok(ResolvedTransferTarget {
        label: peer.device_name.clone(),
        device_id: peer.device_id.clone(),
        address,
        port,
        route_source: route_source.to_owned(),
    })
}

fn peer_matches(peer: &NearbyPeer, normalized_target: &str) -> bool {
    peer.peer_id.eq_ignore_ascii_case(normalized_target)
        || peer
            .device_id
            .as_deref()
            .is_some_and(|value| value.eq_ignore_ascii_case(normalized_target))
        || peer.device_name.eq_ignore_ascii_case(normalized_target)
        || peer.service_name.eq_ignore_ascii_case(normalized_target)
        || peer.host_name.trim_end_matches('.').eq_ignore_ascii_case(normalized_target)
        || peer
            .addresses
            .iter()
            .any(|address| address.eq_ignore_ascii_case(normalized_target))
}

async fn connect_to_target(address: &str, port: u16) -> Result<TcpStream> {
    let endpoint = socket_endpoint(address, port);
    let mut candidates = lookup_host(endpoint.as_str())
        .await
        .with_context(|| format!("failed to resolve {endpoint}"))?;
    let candidate = candidates
        .next()
        .ok_or_else(|| anyhow!("no address candidates found for {endpoint}"))?;
    TcpStream::connect(candidate)
        .await
        .with_context(|| format!("failed to connect to {}", candidate))
}

fn socket_endpoint(address: &str, port: u16) -> String {
    if address.parse::<std::net::Ipv6Addr>().is_ok() {
        format!("[{address}]:{port}")
    } else {
        format!("{address}:{port}")
    }
}

struct ManualEndpoint {
    address: String,
    port: u16,
}

fn parse_manual_endpoint(target: &str) -> Option<ManualEndpoint> {
    if let Ok(socket_addr) = target.parse::<SocketAddr>() {
        return Some(ManualEndpoint {
            address: socket_addr.ip().to_string(),
            port: socket_addr.port(),
        });
    }

    if target.contains('.') || target.contains(':') || target.ends_with(".local") {
        if let Some((address, port)) = split_host_port(target) {
            return Some(ManualEndpoint {
                address: address.to_owned(),
                port,
            });
        }
        return Some(ManualEndpoint {
            address: target.trim_matches(&['[', ']'][..]).to_owned(),
            port: DEFAULT_FILE_TRANSFER_PORT,
        });
    }

    None
}

fn split_host_port(target: &str) -> Option<(&str, u16)> {
    if target.starts_with('[') {
        let end = target.find(']')?;
        let address = &target[1..end];
        let remainder = target.get((end + 1)..)?;
        let port = remainder.strip_prefix(':')?.parse::<u16>().ok()?;
        return Some((address, port));
    }

    let last_colon = target.rfind(':')?;
    if target[..last_colon].contains(':') {
        return None;
    }
    let address = &target[..last_colon];
    let port = target[(last_colon + 1)..].parse::<u16>().ok()?;
    if address.trim().is_empty() {
        return None;
    }
    Some((address, port))
}

#[cfg(test)]
mod tests {
    use super::*;
    use skybridge_core::SKYBRIDGE_FILE_TRANSFER_SERVICE_TYPE;

    fn sample_peer() -> NearbyPeer {
        NearbyPeer {
            peer_id: "device-1".to_owned(),
            device_id: Some("device-1".to_owned()),
            device_name: "Bill Mac".to_owned(),
            service_name: "Bill Mac".to_owned(),
            advertised_services: vec![SKYBRIDGE_FILE_TRANSFER_SERVICE_TYPE.to_owned()],
            host_name: "bill-mac.local.".to_owned(),
            addresses: vec!["192.168.1.22".to_owned()],
            port: DEFAULT_FILE_TRANSFER_PORT,
            transfer_port: Some(DEFAULT_FILE_TRANSFER_PORT),
            platform: Some("macos".to_owned()),
            capabilities: vec!["file_transfer".to_owned()],
            discovered_at: OffsetDateTime::now_utc(),
        }
    }

    #[test]
    fn resolve_target_matches_device_name() -> Result<()> {
        let peer = sample_peer();
        let resolved = resolve_target("Bill Mac", &[peer], "local-device")?;
        assert_eq!(resolved.address, "192.168.1.22");
        assert_eq!(resolved.port, DEFAULT_FILE_TRANSFER_PORT);
        Ok(())
    }

    #[test]
    fn manual_endpoint_defaults_port() {
        let endpoint = parse_manual_endpoint("10.0.0.42").expect("manual endpoint");
        assert_eq!(endpoint.address, "10.0.0.42");
        assert_eq!(endpoint.port, DEFAULT_FILE_TRANSFER_PORT);
    }
}
