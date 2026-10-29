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

#[test]
fn device_discover_active_scan_dispatch_shape_is_bounded_before_network_io() {
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "device",
            "discover",
            "--nearby",
            "--scan",
            "--scan-seconds",
            "0",
            "--json",
        ])
        .is_err(),
        "out-of-range scan duration must fail before mDNS network I/O"
    );
    assert!(
        Cli::try_parse_from([
            "skybridge",
            "device",
            "discover",
            "--nearby",
            "--show-addresses",
            "--json",
        ])
        .is_err(),
        "address disclosure must require an explicit active scan"
    );
}

async fn dispatch_args<const N: usize>(args: [&str; N]) -> Result<()> {
    crate::dispatch(Cli::try_parse_from(args)?).await
}
