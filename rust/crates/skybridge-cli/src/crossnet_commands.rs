use anyhow::Result;
use serde_json::json;
use skybridge_crossnet_client::{
    ConnectResult, DisconnectResult, HostResult, LeaseMode, StatusOutcome, StatusResult,
};

use crate::{CrossnetConnectArgs, CrossnetHostArgs, CrossnetLeaseMode, CrossnetStatusArgs};

impl From<CrossnetLeaseMode> for LeaseMode {
    fn from(mode: CrossnetLeaseMode) -> Self {
        match mode {
            CrossnetLeaseMode::Short => LeaseMode::Short,
            CrossnetLeaseMode::Long => LeaseMode::Long,
        }
    }
}

pub(crate) async fn host(args: CrossnetHostArgs) -> Result<()> {
    let result = skybridge_crossnet_client::host(args.lease.map(LeaseMode::from)).await?;
    print_host(&result, args.output.json)
}

pub(crate) async fn connect(args: CrossnetConnectArgs) -> Result<()> {
    let result = skybridge_crossnet_client::connect(&args.code).await?;
    print_connect(&result, args.output.json)
}

pub(crate) async fn disconnect(as_json: bool) -> Result<()> {
    let result = skybridge_crossnet_client::disconnect().await?;
    print_disconnect(&result, as_json)
}

pub(crate) async fn status(args: CrossnetStatusArgs) -> Result<()> {
    match skybridge_crossnet_client::status(args.watch).await? {
        StatusOutcome::Snapshot(snapshot) => print_status(&snapshot, args.output.json),
        StatusOutcome::Watch(mut watch) => {
            print_status(watch.initial(), args.output.json)?;
            while let Some(event) = watch.next_event().await? {
                print_status(&event, args.output.json)?;
            }
            Ok(())
        }
    }
}

fn print_host(result: &HostResult, as_json: bool) -> Result<()> {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "code": result.code,
                "session_id": result.session_id,
                "expires_at": result.expires_at,
                "lease_mode": result.lease_mode,
            }))?
        );
    } else {
        println!("Connection Code: {}", result.code);
        println!("Session ID: {}", result.session_id);
        println!("Lease Mode: {}", result.lease_mode);
        println!(
            "Expires At: {}",
            result.expires_at.as_deref().unwrap_or("never")
        );
    }
    Ok(())
}

fn print_connect(result: &ConnectResult, as_json: bool) -> Result<()> {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "session_id": result.session_id,
                "remote_device_name": result.remote_device_name,
                "readiness": result.readiness,
            }))?
        );
    } else {
        println!("Session ID: {}", result.session_id);
        println!(
            "Remote Device: {}",
            result.remote_device_name.as_deref().unwrap_or("unknown")
        );
        println!("Readiness: {}", result.readiness);
    }
    Ok(())
}

fn print_disconnect(result: &DisconnectResult, as_json: bool) -> Result<()> {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({ "disconnected": result.disconnected }))?
        );
    } else if result.disconnected {
        println!("Disconnected cross-network session");
    } else {
        println!("No cross-network session to disconnect");
    }
    Ok(())
}

fn print_status(status: &StatusResult, as_json: bool) -> Result<()> {
    let session_present = status.session_present || status.session_id.is_some();
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "connection_status": status.connection_status,
                "readiness": status.readiness,
                "session_present": session_present,
                "session_ref": status.session_ref,
                "suite": status.suite,
                "signaling_health": status.signaling_health,
                "auth_loaded": status.auth_loaded,
                "tenant_bound": status.tenant_bound,
            }))?
        );
    } else {
        println!("Connection Status: {}", status.connection_status);
        println!("Readiness: {}", status.readiness);
        println!(
            "Session: {}",
            if session_present { "present" } else { "none" }
        );
        println!(
            "Session Ref: {}",
            status.session_ref.as_deref().unwrap_or("none")
        );
        println!("Suite: {}", status.suite.as_deref().unwrap_or("none"));
        println!(
            "Signaling Health: {}",
            status.signaling_health.as_deref().unwrap_or("unknown")
        );
        println!("Auth Loaded: {}", status.auth_loaded);
        println!("Tenant Bound: {}", status.tenant_bound);
    }
    Ok(())
}
