use std::path::PathBuf;
use std::time::Duration;

use anyhow::Result;
use serde_json::json;
use skybridge_agent::{ensure_device_identity, resolve_paths};
use skybridge_core::discover_nearby_peers;

pub async fn device_discover(
    state_dir: Option<PathBuf>,
    timeout_seconds: u64,
    as_json: bool,
) -> Result<()> {
    let local_device_id = if let Ok(paths) = resolve_paths(state_dir) {
        ensure_device_identity(&paths)
            .await
            .ok()
            .map(|identity| identity.state.device.device_id)
    } else {
        None
    };
    let mut peers = discover_nearby_peers(Duration::from_secs(timeout_seconds.max(1))).await?;
    if let Some(local_device_id) = local_device_id {
        peers.retain(|peer| peer.device_id.as_deref() != Some(local_device_id.as_str()));
    }

    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "timeout_seconds": timeout_seconds.max(1),
                "peers": peers,
            }))?
        );
        return Ok(());
    }

    if peers.is_empty() {
        println!(
            "No nearby SkyBridge peers found within {}s",
            timeout_seconds.max(1)
        );
        return Ok(());
    }

    for peer in peers {
        let addresses = if peer.addresses.is_empty() {
            "<unresolved>".to_owned()
        } else {
            peer.addresses.join(", ")
        };
        let services = if peer.advertised_services.is_empty() {
            "<unknown>".to_owned()
        } else {
            peer.advertised_services.join(", ")
        };
        let transfer = peer
            .transfer_port
            .map(|port| port.to_string())
            .unwrap_or_else(|| "<none>".to_owned());
        println!(
            "{} [{}] addr={} transfer_port={} services={}",
            peer.device_name, peer.peer_id, addresses, transfer, services
        );
    }
    Ok(())
}
