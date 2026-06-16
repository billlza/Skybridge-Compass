use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use serde::Serialize;
use skybridge_agent::{ACTIVE_SCAN_SOURCE, load_nearby_discovery_snapshot_registry, resolve_paths};
use skybridge_core::{
    NearbyDiscoveredDevice, NearbyDiscoveryEndpointClass, NearbyDiscoverySnapshot,
    NearbyDiscoveryTrustStatus,
};
use time::OffsetDateTime;

const SCHEMA_VERSION: u32 = 1;
const DISCOVERY_STATUS_PLANNED: &str = "planned";
const DISCOVERY_STATUS_READ_ONLY: &str = "read_only";
const DISCOVERY_STATUS_STALE: &str = "stale";
const DISCOVERY_MISSING_ERROR: &str =
    "nearby device discovery has no trusted agent discovery snapshot yet";
const DISCOVERY_STALE_ERROR: &str = "nearby device discovery snapshot is stale";
const DISCOVERY_ACTIVE_SCAN_MISSING_ERROR: &str =
    "active nearby device scan has no fresh agent-owned scanner snapshot yet";
const DISCOVERY_ACTIVE_SCAN_STALE_ERROR: &str = "active nearby device scan snapshot is stale";
const DISCOVERY_ACTIVE_SCAN_GATE: &str = "agent_owned_discovery_scanner";
const DISCOVERY_CACHE_SOURCE: &str = "runtime/nearby-discovery-snapshots.json";
const REQUIRED_GATES: &[&str] = &[
    "agent_owned_discovery_snapshot",
    "shared_bonjour_identity_dedupe",
    "protocol_identity_trust_projection",
    "freshness_window_validation",
    "connectivity_matrix_gate",
];
const REQUIRED_GATES_BEFORE_CONNECT: &[&str] = &[
    "explicit_operator_connect_request",
    "protocol_identity_trust_projection",
    "route_revalidation",
    "session_handshake_gate",
];

#[derive(Debug, Serialize)]
struct DeviceDiscoverReport {
    schema_version: u32,
    capability_id: &'static str,
    accepted: bool,
    status: String,
    nearby_requested: bool,
    mutation_supported: bool,
    source: String,
    scan_id: Option<String>,
    observed_at: Option<String>,
    expires_at: Option<String>,
    devices_returned: usize,
    devices: Vec<DeviceDiscoverDeviceReport>,
    snapshot_authorizes_connection: bool,
    error: Option<DeviceDiscoverErrorReport>,
    required_gates_before_results: &'static [&'static str],
    required_gates_before_connect: &'static [&'static str],
}

#[derive(Debug, Serialize)]
struct DeviceDiscoverErrorReport {
    code: String,
    message: String,
    retryable: bool,
    required_gate: &'static str,
}

#[derive(Debug, Serialize)]
struct DeviceDiscoverDeviceReport {
    device_ref: String,
    display_name: String,
    endpoint_class: NearbyDiscoveryEndpointClass,
    trust_status: NearbyDiscoveryTrustStatus,
    capabilities: Vec<String>,
    connectable: bool,
    connection_authorized: bool,
}

pub(crate) async fn device_discover(
    state_dir: Option<PathBuf>,
    args: crate::DeviceDiscoverArgs,
) -> Result<()> {
    if args.scan {
        return device_discover_active_scan(state_dir, args).await;
    }

    if !args.nearby {
        if args.output.json {
            print_rejection_report(
                false,
                DISCOVERY_STATUS_PLANNED,
                "device_discovery_nearby_required",
                "pass --nearby to request nearby discovery",
                false,
                "agent_owned_discovery_snapshot",
            )?;
        }
        bail!("pass --nearby to request the planned nearby discovery contract");
    }

    let paths = resolve_paths(state_dir)?;
    let registry = load_nearby_discovery_snapshot_registry(&paths).await?;
    let now = OffsetDateTime::now_utc();
    let Some(snapshot) = registry.latest_fresh(now) else {
        let status = if registry.latest().is_some() {
            DISCOVERY_STATUS_STALE
        } else {
            DISCOVERY_STATUS_PLANNED
        };
        let message = if status == DISCOVERY_STATUS_STALE {
            DISCOVERY_STALE_ERROR
        } else {
            DISCOVERY_MISSING_ERROR
        };
        if args.output.json {
            print_rejection_report(
                true,
                status,
                if status == DISCOVERY_STATUS_STALE {
                    "device_discovery_snapshot_stale"
                } else {
                    "device_discovery_snapshot_missing"
                },
                message,
                status == DISCOVERY_STATUS_STALE,
                "agent_owned_discovery_snapshot",
            )?;
        }
        bail!(
            "{message}; results must come from a fresh agent-owned discovery snapshot that reuses the shared Bonjour identity and trust model"
        );
    };

    let report = snapshot_report(snapshot).context("failed to build discovery snapshot report")?;
    if args.output.json {
        println!("{}", serde_json::to_string_pretty(&report)?);
        return Ok(());
    }

    println!("Nearby discovery snapshot: {}", report.status);
    println!("Source: {}", report.source);
    println!("Devices: {}", report.devices_returned);
    for device in &report.devices {
        println!(
            "- {} [{} {:?} connectable={}]",
            device.display_name, device.device_ref, device.trust_status, device.connectable
        );
    }
    Ok(())
}

async fn device_discover_active_scan(
    state_dir: Option<PathBuf>,
    args: crate::DeviceDiscoverArgs,
) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let registry = load_nearby_discovery_snapshot_registry(&paths).await?;
    let now = OffsetDateTime::now_utc();

    // Only snapshots produced by the agent-owned active scanner satisfy --scan;
    // passive presence snapshots are never promoted to an active scan result.
    let fresh_active = registry
        .snapshots
        .values()
        .filter(|snapshot| snapshot.source == ACTIVE_SCAN_SOURCE && snapshot.is_fresh_at(now))
        .max_by_key(|snapshot| snapshot.updated_at);

    let Some(snapshot) = fresh_active else {
        let has_active_history = registry
            .snapshots
            .values()
            .any(|snapshot| snapshot.source == ACTIVE_SCAN_SOURCE);
        let (status, code, message, retryable) = if has_active_history {
            (
                DISCOVERY_STATUS_STALE,
                "device_discovery_active_scan_snapshot_stale",
                DISCOVERY_ACTIVE_SCAN_STALE_ERROR,
                true,
            )
        } else {
            (
                DISCOVERY_STATUS_PLANNED,
                "device_discovery_active_scan_snapshot_missing",
                DISCOVERY_ACTIVE_SCAN_MISSING_ERROR,
                false,
            )
        };
        if args.output.json {
            print_rejection_report(
                args.nearby,
                status,
                code,
                message,
                retryable,
                DISCOVERY_ACTIVE_SCAN_GATE,
            )?;
        }
        bail!(
            "{message}; active scan results must come from a fresh agent-owned mDNS scan snapshot"
        );
    };

    let report =
        snapshot_report(snapshot).context("failed to build active scan snapshot report")?;
    if args.output.json {
        println!("{}", serde_json::to_string_pretty(&report)?);
        return Ok(());
    }

    println!("Active nearby scan snapshot: {}", report.status);
    println!("Source: {}", report.source);
    println!("Devices: {}", report.devices_returned);
    for device in &report.devices {
        println!(
            "- {} [{} {:?} connectable={}]",
            device.display_name, device.device_ref, device.trust_status, device.connectable
        );
    }
    Ok(())
}

fn rejection_report(
    nearby_requested: bool,
    status: &str,
    code: &str,
    message: &str,
    retryable: bool,
    required_gate: &'static str,
) -> DeviceDiscoverReport {
    DeviceDiscoverReport {
        schema_version: SCHEMA_VERSION,
        capability_id: "device.discovery.nearby",
        accepted: false,
        status: status.to_owned(),
        nearby_requested,
        mutation_supported: false,
        source: DISCOVERY_CACHE_SOURCE.to_owned(),
        scan_id: None,
        observed_at: None,
        expires_at: None,
        devices_returned: 0,
        devices: Vec::new(),
        snapshot_authorizes_connection: false,
        error: Some(DeviceDiscoverErrorReport {
            code: code.to_owned(),
            message: message.to_owned(),
            retryable,
            required_gate,
        }),
        required_gates_before_results: REQUIRED_GATES,
        required_gates_before_connect: REQUIRED_GATES_BEFORE_CONNECT,
    }
}

fn snapshot_report(snapshot: &NearbyDiscoverySnapshot) -> Result<DeviceDiscoverReport> {
    let devices = snapshot
        .devices
        .iter()
        .map(device_report)
        .collect::<Vec<_>>();
    Ok(DeviceDiscoverReport {
        schema_version: SCHEMA_VERSION,
        capability_id: "device.discovery.nearby",
        accepted: true,
        status: DISCOVERY_STATUS_READ_ONLY.to_owned(),
        nearby_requested: true,
        mutation_supported: false,
        source: snapshot.source.clone(),
        scan_id: Some(snapshot.scan_id.clone()),
        observed_at: Some(snapshot.observed_at.to_string()),
        expires_at: Some(snapshot.expires_at.to_string()),
        devices_returned: devices.len(),
        devices,
        snapshot_authorizes_connection: false,
        error: None,
        required_gates_before_results: REQUIRED_GATES,
        required_gates_before_connect: REQUIRED_GATES_BEFORE_CONNECT,
    })
}

fn device_report(device: &NearbyDiscoveredDevice) -> DeviceDiscoverDeviceReport {
    DeviceDiscoverDeviceReport {
        device_ref: device.device_ref.clone(),
        display_name: device.display_name.clone(),
        endpoint_class: device.endpoint_class,
        trust_status: device.trust_status,
        capabilities: device.capabilities.clone(),
        connectable: device.connectable,
        connection_authorized: false,
    }
}

fn print_rejection_report(
    nearby_requested: bool,
    status: &str,
    code: &str,
    message: &str,
    retryable: bool,
    required_gate: &'static str,
) -> Result<()> {
    eprintln!(
        "{}",
        serde_json::to_string_pretty(&rejection_report(
            nearby_requested,
            status,
            code,
            message,
            retryable,
            required_gate
        ))?
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn nearby_discovery_fails_closed_until_agent_snapshot_exists() {
        assert!(
            device_discover(
                Some(crate::cli_test_support::make_test_dir("nearby-discovery-missing").unwrap()),
                crate::DeviceDiscoverArgs {
                    nearby: true,
                    scan: false,
                    output: crate::OutputOptions { json: false },
                },
            )
            .await
            .is_err()
        );
    }

    #[test]
    fn discovery_report_keeps_planned_contract_explicit() {
        let report = rejection_report(
            true,
            DISCOVERY_STATUS_PLANNED,
            "device_discovery_snapshot_missing",
            DISCOVERY_MISSING_ERROR,
            false,
            "agent_owned_discovery_snapshot",
        );
        assert_eq!(report.schema_version, 1);
        assert_eq!(report.capability_id, "device.discovery.nearby");
        assert_eq!(report.status, "planned");
        assert!(!report.accepted);
        assert!(!report.mutation_supported);
        assert_eq!(report.devices_returned, 0);
        assert!(report.devices.is_empty());
        assert!(!report.snapshot_authorizes_connection);
        assert!(
            report
                .required_gates_before_results
                .contains(&"protocol_identity_trust_projection")
        );
    }
}
