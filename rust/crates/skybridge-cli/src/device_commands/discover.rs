use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::Serialize;
use skybridge_agent::{
    ACTIVE_SCAN_SOURCE, ActiveScanError, ActiveScanFailureKind, ActiveScanFailureStage,
    ActiveScanResult, DEFAULT_ON_DEMAND_SCAN_SECONDS, load_nearby_discovery_snapshot_registry,
    resolve_paths, run_active_scan, upsert_nearby_discovery_snapshot,
};
use skybridge_core::{
    NearbyDiscoveredDevice, NearbyDiscoveryEndpointClass, NearbyDiscoverySnapshot,
    NearbyDiscoveryTrustStatus,
};
use time::OffsetDateTime;

const SCHEMA_VERSION: u32 = 1;
const DISCOVERY_STATUS_PLANNED: &str = "planned";
const DISCOVERY_STATUS_READ_ONLY: &str = "read_only";
const DISCOVERY_STATUS_STALE: &str = "stale";
const DISCOVERY_STATUS_FAILED: &str = "failed";
const DISCOVERY_MISSING_ERROR: &str =
    "nearby device discovery has no trusted agent discovery snapshot yet";
const DISCOVERY_STALE_ERROR: &str = "nearby device discovery snapshot is stale";
const DISCOVERY_CACHE_SOURCE: &str = "runtime/nearby-discovery-snapshots.json";
const REQUIRED_GATES: &[&str] = &[
    "agent_owned_discovery_snapshot",
    "shared_bonjour_identity_dedupe",
    "protocol_identity_trust_projection",
    "freshness_window_validation",
    "connectivity_matrix_gate",
];
const ACTIVE_SCAN_REQUIRED_GATES: &[&str] = &[
    "native_foreground_mdns_scan",
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
    active_scan_duration_seconds: Option<u64>,
    addresses_included: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    advertised_endpoints: Option<Vec<AdvertisedEndpointReport>>,
    snapshot_authorizes_connection: bool,
    error: Option<DeviceDiscoverErrorReport>,
    required_gates_before_results: &'static [&'static str],
    required_gates_before_connect: &'static [&'static str],
}

#[derive(Debug, Serialize)]
struct AdvertisedEndpointReport {
    device_ref: String,
    address: IpAddr,
    port: u16,
    provenance: &'static str,
    authenticated: bool,
    connectable: bool,
    connection_authorized: bool,
    persisted: bool,
    observed_at: String,
    expires_at: String,
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
    if !args.nearby {
        bail!("--scan requires --nearby");
    }
    let paths = resolve_paths(state_dir)?;
    let scan_seconds = args.scan_seconds.unwrap_or(DEFAULT_ON_DEMAND_SCAN_SECONDS);
    let result = match run_active_scan(Duration::from_secs(scan_seconds)).await {
        Ok(result) => result,
        Err(error) => {
            if args.output.json {
                crate::cli_output::write_json_failure(&active_scan_failure_report(
                    &error,
                    scan_seconds,
                ))
                .context("failed to render active discovery scan JSON failure")?;
            }
            return Err(anyhow::Error::new(error).context("active nearby mDNS scan failed"));
        }
    };

    // Persist only the locator-free projection. The state validator rejects any
    // accidental locator-bearing public snapshot.
    persist_active_scan_snapshot(&paths, &result).await?;

    let report = active_scan_report(&result, scan_seconds, args.show_addresses)
        .context("failed to build active scan report")?;
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
    if let Some(endpoints) = &report.advertised_endpoints {
        for endpoint in endpoints {
            println!(
                "  address {} [{} authenticated=false connectable=false]",
                SocketAddr::new(endpoint.address, endpoint.port),
                endpoint.provenance
            );
        }
    }
    Ok(())
}

async fn persist_active_scan_snapshot(
    paths: &skybridge_agent::AgentPaths,
    result: &ActiveScanResult,
) -> Result<()> {
    upsert_nearby_discovery_snapshot(paths, result.snapshot.clone())
        .await
        .context("failed to persist locator-free active scan snapshot")?;
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
        active_scan_duration_seconds: None,
        addresses_included: false,
        advertised_endpoints: None,
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

fn active_scan_failure_report(error: &ActiveScanError, scan_seconds: u64) -> DeviceDiscoverReport {
    let (code, message, retryable, required_gate) = match (error.kind(), error.stage()) {
        (ActiveScanFailureKind::InvalidRequest, _) => (
            "device_discovery_scan_request_invalid",
            "nearby discovery rejected the bounded active-scan request",
            false,
            "native_foreground_mdns_scan",
        ),
        (ActiveScanFailureKind::PermissionDenied, _) => (
            "device_discovery_permission_denied",
            "nearby discovery does not have permission to open the local mDNS transport",
            false,
            "local_network_permission",
        ),
        (ActiveScanFailureKind::TransportUnavailable, ActiveScanFailureStage::TransportStart) => (
            "device_discovery_transport_unavailable",
            "nearby discovery could not start the local mDNS transport",
            true,
            "native_foreground_mdns_scan",
        ),
        (ActiveScanFailureKind::TransportUnavailable, ActiveScanFailureStage::ScanRuntime) => (
            "device_discovery_scan_runtime_failed",
            "nearby discovery transport failed while the bounded scan was running",
            true,
            "native_foreground_mdns_scan",
        ),
        (
            ActiveScanFailureKind::TransportUnavailable,
            ActiveScanFailureStage::RequestValidation,
        ) => (
            "device_discovery_scan_request_invalid",
            "nearby discovery rejected the bounded active-scan request",
            false,
            "native_foreground_mdns_scan",
        ),
    };
    DeviceDiscoverReport {
        schema_version: SCHEMA_VERSION,
        capability_id: "device.discovery.nearby",
        accepted: false,
        status: DISCOVERY_STATUS_FAILED.to_owned(),
        nearby_requested: true,
        mutation_supported: false,
        source: ACTIVE_SCAN_SOURCE.to_owned(),
        scan_id: None,
        observed_at: None,
        expires_at: None,
        devices_returned: 0,
        devices: Vec::new(),
        active_scan_duration_seconds: Some(scan_seconds),
        addresses_included: false,
        advertised_endpoints: None,
        snapshot_authorizes_connection: false,
        error: Some(DeviceDiscoverErrorReport {
            code: code.to_owned(),
            message: message.to_owned(),
            retryable,
            required_gate,
        }),
        required_gates_before_results: ACTIVE_SCAN_REQUIRED_GATES,
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
        active_scan_duration_seconds: None,
        addresses_included: false,
        advertised_endpoints: None,
        snapshot_authorizes_connection: false,
        error: None,
        required_gates_before_results: REQUIRED_GATES,
        required_gates_before_connect: REQUIRED_GATES_BEFORE_CONNECT,
    })
}

fn active_scan_report(
    result: &ActiveScanResult,
    scan_seconds: u64,
    show_addresses: bool,
) -> Result<DeviceDiscoverReport> {
    let mut report = snapshot_report(&result.snapshot)?;
    report.required_gates_before_results = ACTIVE_SCAN_REQUIRED_GATES;
    report.active_scan_duration_seconds = Some(scan_seconds);
    report.addresses_included = show_addresses;
    if show_addresses {
        let now = OffsetDateTime::now_utc();
        report.advertised_endpoints = Some(
            result
                .advertised_endpoints
                .iter()
                .filter(|observation| observation.is_fresh_at(now))
                .map(|observation| AdvertisedEndpointReport {
                    device_ref: observation.device_ref.clone(),
                    address: observation.address,
                    port: observation.port,
                    provenance: skybridge_agent::AdvertisedEndpointObservation::PROVENANCE,
                    authenticated: false,
                    connectable: false,
                    connection_authorized: false,
                    persisted: false,
                    observed_at: observation.observed_at.to_string(),
                    expires_at: observation.expires_at.to_string(),
                })
                .collect(),
        );
    }
    Ok(report)
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
    crate::cli_output::write_json_failure(&rejection_report(
        nearby_requested,
        status,
        code,
        message,
        retryable,
        required_gate,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[tokio::test]
    async fn nearby_discovery_fails_closed_until_agent_snapshot_exists() {
        assert!(
            device_discover(
                Some(crate::cli_test_support::make_test_dir("nearby-discovery-missing").unwrap()),
                crate::DeviceDiscoverArgs {
                    nearby: true,
                    scan: false,
                    scan_seconds: None,
                    show_addresses: false,
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
        assert!(!report.addresses_included);
        assert!(report.advertised_endpoints.is_none());
        assert!(
            report
                .required_gates_before_results
                .contains(&"protocol_identity_trust_projection")
        );
    }

    #[test]
    fn active_scan_failure_json_distinguishes_permission_start_and_runtime_without_leaks()
    -> Result<()> {
        let private_detail =
            "/Users/example/private/mdns.sock session-token-secret Operation not permitted";
        let permission = serde_json::to_value(active_scan_failure_report(
            &ActiveScanError::transport_start(private_detail),
            2,
        ))?;
        assert_eq!(permission["accepted"], false);
        assert_eq!(permission["status"], "failed");
        assert_eq!(permission["source"], ACTIVE_SCAN_SOURCE);
        assert_eq!(permission["active_scan_duration_seconds"], 2);
        assert_eq!(permission["devices_returned"], 0);
        assert_eq!(
            permission["error"]["code"],
            "device_discovery_permission_denied"
        );
        assert_eq!(permission["error"]["retryable"], false);
        assert_eq!(
            permission["error"]["required_gate"],
            "local_network_permission"
        );
        let encoded = permission.to_string();
        assert!(!encoded.contains("/Users/example"));
        assert!(!encoded.contains("session-token-secret"));
        assert!(!encoded.contains("Operation not permitted"));

        let transport_start = serde_json::to_value(active_scan_failure_report(
            &ActiveScanError::transport_start("daemon bootstrap failed"),
            2,
        ))?;
        assert_eq!(
            transport_start["error"]["code"],
            "device_discovery_transport_unavailable"
        );
        assert_eq!(transport_start["error"]["retryable"], true);

        let runtime = serde_json::to_value(active_scan_failure_report(
            &ActiveScanError::scan_runtime("monitor stream dropped"),
            2,
        ))?;
        assert_eq!(
            runtime["error"]["code"],
            "device_discovery_scan_runtime_failed"
        );
        assert_eq!(runtime["error"]["retryable"], true);
        assert_ne!(runtime["error"]["code"], transport_start["error"]["code"]);
        Ok(())
    }

    #[test]
    fn active_scan_with_no_devices_is_success_not_a_failure_projection() -> Result<()> {
        let result = ActiveScanResult {
            snapshot: NearbyDiscoverySnapshot::new(
                "active-mdns-scan",
                ACTIVE_SCAN_SOURCE,
                Vec::new(),
                120,
            ),
            advertised_endpoints: Vec::new(),
        };
        let payload = serde_json::to_value(active_scan_report(&result, 2, false)?)?;
        assert_eq!(payload["accepted"], true);
        assert_eq!(payload["status"], "read_only");
        assert_eq!(payload["devices_returned"], 0);
        assert!(payload["devices"].as_array().is_some_and(Vec::is_empty));
        assert!(payload["error"].is_null());
        Ok(())
    }

    #[test]
    fn active_scan_json_hides_addresses_by_default_and_labels_explicit_disclosure() -> Result<()> {
        use skybridge_agent::AdvertisedEndpointObservation;

        let snapshot = NearbyDiscoverySnapshot::new(
            "active-mdns-scan",
            skybridge_agent::ACTIVE_SCAN_SOURCE,
            vec![NearbyDiscoveredDevice::new(
                "id-test",
                "Nearby Mac",
                NearbyDiscoveryEndpointClass::LocalNetwork,
                NearbyDiscoveryTrustStatus::Candidate,
                vec!["file_transfer".to_owned()],
                false,
            )],
            120,
        );
        let observed_at = OffsetDateTime::now_utc();
        let result = ActiveScanResult {
            snapshot,
            advertised_endpoints: vec![AdvertisedEndpointObservation {
                device_ref: "id-test".to_owned(),
                address: "192.0.2.44".parse()?,
                port: 7443,
                observed_at,
                expires_at: observed_at + time::Duration::seconds(30),
            }],
        };

        let hidden = serde_json::to_value(active_scan_report(&result, 4, false)?)?;
        assert_eq!(hidden["addresses_included"], false);
        assert_eq!(hidden["source"], skybridge_agent::ACTIVE_SCAN_SOURCE);
        assert_eq!(hidden["snapshot_authorizes_connection"], false);
        assert_eq!(hidden["devices"][0]["trust_status"], "candidate");
        assert_eq!(hidden["devices"][0]["connectable"], false);
        assert!(hidden.get("advertised_endpoints").is_none());
        assert!(!hidden.to_string().contains("192.0.2.44"));
        let result_gates = hidden["required_gates_before_results"]
            .as_array()
            .expect("active scan result gates must be an array");
        assert!(
            result_gates
                .iter()
                .any(|gate| gate == "native_foreground_mdns_scan")
        );
        assert!(
            !result_gates
                .iter()
                .any(|gate| gate == "agent_owned_discovery_snapshot")
        );

        let disclosed = serde_json::to_value(active_scan_report(&result, 4, true)?)?;
        assert_eq!(disclosed["addresses_included"], true);
        assert_eq!(
            disclosed["advertised_endpoints"][0]["provenance"],
            "advertised_unverified"
        );
        assert_eq!(disclosed["advertised_endpoints"][0]["authenticated"], false);
        assert_eq!(disclosed["advertised_endpoints"][0]["connectable"], false);
        assert_eq!(
            disclosed["advertised_endpoints"][0]["connection_authorized"],
            false
        );
        assert_eq!(disclosed["advertised_endpoints"][0]["persisted"], false);
        assert_eq!(
            disclosed["advertised_endpoints"][0]["address"],
            "192.0.2.44"
        );
        assert!(!result.snapshot.devices[0].connectable);
        Ok(())
    }

    #[tokio::test]
    async fn active_scan_persistence_keeps_ephemeral_address_out_of_registry() -> Result<()> {
        use skybridge_agent::AdvertisedEndpointObservation;

        let state_dir = crate::cli_test_support::make_test_dir("active-scan-locator-free")?;
        let paths = resolve_paths(Some(state_dir))?;
        let observed_at = OffsetDateTime::now_utc();
        let result = ActiveScanResult {
            snapshot: NearbyDiscoverySnapshot::new(
                "active-mdns-scan",
                skybridge_agent::ACTIVE_SCAN_SOURCE,
                vec![NearbyDiscoveredDevice::new(
                    "id-persisted",
                    "Nearby Mac",
                    NearbyDiscoveryEndpointClass::LocalNetwork,
                    NearbyDiscoveryTrustStatus::Candidate,
                    vec!["file_transfer".to_owned()],
                    false,
                )],
                120,
            ),
            advertised_endpoints: vec![AdvertisedEndpointObservation {
                device_ref: "id-persisted".to_owned(),
                address: "192.0.2.88".parse()?,
                port: 7443,
                observed_at,
                expires_at: observed_at + time::Duration::seconds(30),
            }],
        };

        persist_active_scan_snapshot(&paths, &result).await?;
        let registry = load_nearby_discovery_snapshot_registry(&paths).await?;
        let persisted = serde_json::to_string(&registry)?;
        assert!(persisted.contains("id-persisted"));
        assert!(!persisted.contains("192.0.2.88"));
        assert!(!persisted.contains("\"port\""));
        assert!(!registry.latest().expect("snapshot should persist").devices[0].connectable);
        Ok(())
    }

    #[test]
    fn active_scan_cli_enforces_nearby_address_and_duration_boundaries() {
        assert_eq!(DEFAULT_ON_DEMAND_SCAN_SECONDS, 4);
        assert!(
            crate::Cli::try_parse_from([
                "skybridge",
                "device",
                "discover",
                "--nearby",
                "--show-addresses",
            ])
            .is_err(),
            "address disclosure must require a live scan"
        );
        assert!(
            crate::Cli::try_parse_from(["skybridge", "device", "discover", "--scan"]).is_err(),
            "an active scan must require the explicit nearby scope"
        );
        for invalid in ["0", "31"] {
            assert!(
                crate::Cli::try_parse_from([
                    "skybridge",
                    "device",
                    "discover",
                    "--nearby",
                    "--scan",
                    "--scan-seconds",
                    invalid,
                ])
                .is_err(),
                "scan duration {invalid} must be rejected"
            );
        }

        let parsed = crate::Cli::try_parse_from([
            "skybridge",
            "device",
            "discover",
            "--nearby",
            "--scan",
            "--show-addresses",
            "--scan-seconds",
            "30",
        ])
        .expect("maximum bounded scan with explicit address disclosure should parse");
        let crate::Commands::Device(command) = parsed.command else {
            panic!("expected device command");
        };
        let crate::DeviceSubcommand::Discover(args) = command.command else {
            panic!("expected discover command");
        };
        assert_eq!(args.scan_seconds, Some(30));
        assert!(args.show_addresses);
    }
}
