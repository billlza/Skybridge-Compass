use anyhow::Result;
use clap::Parser;
use skybridge_agent::{resolve_paths, upsert_nearby_discovery_snapshot};
use skybridge_core::{
    NearbyDiscoveredDevice, NearbyDiscoveryEndpointClass, NearbyDiscoverySnapshot,
    NearbyDiscoveryTrustStatus,
};

use crate::Cli;
use crate::cli_test_support::make_test_dir;

#[tokio::test]
async fn device_discover_dispatch_reads_agent_owned_snapshot() -> Result<()> {
    let state_dir = make_test_dir("device-discover-dispatch-snapshot")?;
    let state = state_dir.display().to_string();
    let paths = resolve_paths(Some(state_dir.clone()))?;
    upsert_nearby_discovery_snapshot(
        &paths,
        NearbyDiscoverySnapshot::new(
            "scan-1",
            "agent_owned_nearby_discovery_snapshot",
            vec![NearbyDiscoveredDevice::new(
                "nearby-device-1",
                "Studio Mac",
                NearbyDiscoveryEndpointClass::LocalNetwork,
                NearbyDiscoveryTrustStatus::ProtocolIdentityVerified,
                vec!["remote_desktop".to_owned()],
                true,
            )],
            300,
        ),
    )
    .await?;

    dispatch_args([
        "skybridge",
        "--state-dir",
        &state,
        "device",
        "discover",
        "--nearby",
        "--json",
    ])
    .await?;

    Ok(())
}

#[tokio::test]
async fn device_discover_dispatch_fails_closed_without_snapshot() -> Result<()> {
    let state_dir = make_test_dir("device-discover-dispatch-missing")?;
    let state = state_dir.display().to_string();

    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "device",
            "discover",
            "--nearby",
            "--json",
        ])
        .await
        .is_err(),
        "missing discovery snapshots must not produce fake empty results"
    );

    Ok(())
}

#[tokio::test]
async fn device_discover_dispatch_active_scan_fails_closed_without_active_snapshot() -> Result<()> {
    let state_dir = make_test_dir("device-discover-dispatch-active-scan")?;
    let state = state_dir.display().to_string();
    let paths = resolve_paths(Some(state_dir.clone()))?;
    // A passive nearby snapshot must not satisfy --scan: active scan only
    // accepts snapshots produced by the agent-owned active mDNS scanner.
    upsert_nearby_discovery_snapshot(
        &paths,
        NearbyDiscoverySnapshot::new(
            "scan-1",
            "agent_owned_nearby_discovery_snapshot",
            vec![NearbyDiscoveredDevice::new(
                "nearby-device-1",
                "Studio Mac",
                NearbyDiscoveryEndpointClass::LocalNetwork,
                NearbyDiscoveryTrustStatus::ProtocolIdentityVerified,
                vec!["remote_desktop".to_owned()],
                true,
            )],
            300,
        ),
    )
    .await?;

    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "device",
            "discover",
            "--nearby",
            "--scan",
            "--json",
        ])
        .await
        .is_err(),
        "active scan must fail closed when no agent-owned active scan snapshot exists"
    );

    Ok(())
}

#[tokio::test]
async fn device_discover_dispatch_active_scan_reads_agent_owned_active_snapshot() -> Result<()> {
    let state_dir = make_test_dir("device-discover-dispatch-active-scan-ok")?;
    let state = state_dir.display().to_string();
    let paths = resolve_paths(Some(state_dir.clone()))?;
    upsert_nearby_discovery_snapshot(
        &paths,
        NearbyDiscoverySnapshot::new(
            "active-mdns-scan",
            "agent_owned_active_mdns_scan",
            vec![NearbyDiscoveredDevice::new(
                "id-active1",
                "Scanned Mac",
                NearbyDiscoveryEndpointClass::LocalNetwork,
                NearbyDiscoveryTrustStatus::Candidate,
                vec!["remote_desktop".to_owned()],
                false,
            )],
            120,
        ),
    )
    .await?;

    dispatch_args([
        "skybridge",
        "--state-dir",
        &state,
        "device",
        "discover",
        "--nearby",
        "--scan",
        "--json",
    ])
    .await?;

    Ok(())
}

async fn dispatch_args<const N: usize>(args: [&str; N]) -> Result<()> {
    crate::dispatch(Cli::try_parse_from(args)?).await
}
