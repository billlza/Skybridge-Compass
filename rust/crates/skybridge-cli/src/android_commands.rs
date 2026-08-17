//! `skybridge android …` — desktop-side operator commands for the Android
//! debug app's `adb-bridge/1` read-only diagnostic surface.
//!
//! Everything device-facing goes through `adb` (located via `--adb`,
//! `ANDROID_HOME`/`ANDROID_SDK_ROOT`, then `PATH`); after `adb forward` the
//! request itself travels over a plain localhost `TcpStream`, so this module
//! is portable across macOS, Windows, and Linux. All pure protocol/argument
//! logic (and its tests) lives in [`crate::android_bridge`].

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

use crate::android_bridge::{
    AdbDeviceEntry, MAX_RESPONSE_LINE_BYTES, adb_candidates, adb_devices_args, adb_endpoint_args,
    adb_forward_args, adb_forward_remove_args, build_bridge_request, decode_bridge_response,
    next_request_id, parse_adb_devices, parse_endpoint_document, parse_forward_local_port,
    resolve_target_serial,
};
use crate::{AndroidBridgeArgs, AndroidDevicesArgs};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const IO_TIMEOUT: Duration = Duration::from_secs(10);

/// `skybridge android devices`.
pub(crate) async fn devices(args: AndroidDevicesArgs) -> Result<()> {
    let adb = locate_adb(args.adb)?;
    let devices = list_devices(&adb)?;
    print_devices(&devices, args.output.json)
}

/// `skybridge android status|doctor|lan|code` — one bridge round trip.
pub(crate) async fn bridge_query(args: AndroidBridgeArgs, method: &'static str) -> Result<()> {
    let adb = locate_adb(args.adb.clone())?;
    let devices = list_devices(&adb)?;
    let serial = resolve_target_serial(&devices, args.serial.as_deref())?;

    let endpoint_arguments = adb_endpoint_args(&serial, &args.package)?;
    let endpoint_output = run_adb(&adb, &endpoint_arguments)?;
    if !endpoint_output.status.success() {
        bail!(
            "could not read the bridge endpoint from {package} on {serial}; install and launch the \
             SkyBridge debug build once so it publishes its per-boot endpoint \
             (code: endpoint_unreadable)",
            package = args.package,
        );
    }
    let endpoint = parse_endpoint_document(&String::from_utf8_lossy(&endpoint_output.stdout))?;

    let forward_output = run_adb(&adb, &adb_forward_args(&serial, &endpoint.socket)?)?;
    ensure_adb_success("adb forward", &forward_output)?;
    let local_port = parse_forward_local_port(&String::from_utf8_lossy(&forward_output.stdout))?;

    let round_trip = bridge_round_trip(local_port, &endpoint.token, method);

    // Release the forward even when the round trip failed; the failure to
    // remove is only worth a warning because adb reclaims forwards on exit.
    match adb_forward_remove_args(&serial, local_port).and_then(|removal| run_adb(&adb, &removal)) {
        Ok(removal_output) if removal_output.status.success() => {}
        _ => eprintln!("Warning: could not remove adb forward tcp:{local_port}"),
    }

    let result = round_trip?;
    print_bridge_result(method, &serial, &args.package, &result, args.output.json)
}

/// Finds a usable `adb`: explicit `--adb`, then `ANDROID_HOME` /
/// `ANDROID_SDK_ROOT` platform-tools, then the bare name for `PATH` lookup.
fn locate_adb(explicit: Option<PathBuf>) -> Result<PathBuf> {
    let candidates = adb_candidates(
        explicit,
        std::env::var_os("ANDROID_HOME").map(PathBuf::from),
        std::env::var_os("ANDROID_SDK_ROOT").map(PathBuf::from),
        cfg!(windows),
    );
    for candidate in candidates {
        let is_bare_name = candidate.components().count() == 1;
        if is_bare_name || candidate.is_file() {
            return Ok(candidate);
        }
    }
    bail!(
        "adb executable not found; pass --adb or set ANDROID_HOME/ANDROID_SDK_ROOT to an SDK \
         containing platform-tools (code: adb_not_found)"
    );
}

fn run_adb(adb: &Path, arguments: &[String]) -> Result<std::process::Output> {
    Command::new(adb).args(arguments).output().with_context(|| {
        format!(
            "could not execute {adb:?}; install Android platform-tools or pass --adb \
             (code: adb_not_found)"
        )
    })
}

fn ensure_adb_success(action: &str, output: &std::process::Output) -> Result<()> {
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let excerpt = stderr.lines().next().unwrap_or("").trim();
    bail!("{action} failed: {excerpt} (code: adb_command_failed)");
}

fn list_devices(adb: &Path) -> Result<Vec<AdbDeviceEntry>> {
    let output = run_adb(adb, &adb_devices_args())?;
    ensure_adb_success("adb devices", &output)?;
    Ok(parse_adb_devices(&String::from_utf8_lossy(&output.stdout)))
}

/// One NDJSON request/response round trip over the forwarded localhost port.
fn bridge_round_trip(local_port: u16, token: &str, method: &str) -> Result<Value> {
    let address = SocketAddr::from((Ipv4Addr::LOCALHOST, local_port));
    let mut stream = TcpStream::connect_timeout(&address, CONNECT_TIMEOUT).with_context(|| {
        format!(
            "could not connect to the forwarded bridge port 127.0.0.1:{local_port}; make sure the \
             SkyBridge debug app process is running (code: bridge_unreachable)"
        )
    })?;
    stream
        .set_read_timeout(Some(IO_TIMEOUT))
        .context("configure bridge read timeout")?;
    stream
        .set_write_timeout(Some(IO_TIMEOUT))
        .context("configure bridge write timeout")?;

    let request_id = next_request_id();
    let request_line = build_bridge_request(&request_id, token, method)?;
    stream
        .write_all(request_line.as_bytes())
        .context("send adb-bridge request")?;
    stream.flush().context("flush adb-bridge request")?;

    let mut reader = BufReader::new(stream.take(MAX_RESPONSE_LINE_BYTES as u64 + 2));
    let mut response_line = String::new();
    reader
        .read_line(&mut response_line)
        .context("read adb-bridge response")?;
    if response_line.trim().is_empty() {
        bail!(
            "the bridge closed the connection before responding; relaunch the SkyBridge debug app \
             (code: bridge_unreachable)"
        );
    }
    decode_bridge_response(&request_id, &response_line)
}

fn print_devices(devices: &[AdbDeviceEntry], as_json: bool) -> Result<()> {
    if as_json {
        let rows: Vec<Value> = devices
            .iter()
            .map(|entry| {
                json!({
                    "serial": entry.serial,
                    "state": entry.state,
                    "detail": entry.detail,
                })
            })
            .collect();
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "schema_version": 1,
                "capability_id": "android.adb.devices",
                "control_effect": "read_only",
                "devices": rows,
            }))?
        );
        return Ok(());
    }
    if devices.is_empty() {
        println!("No Android devices attached");
        return Ok(());
    }
    for entry in devices {
        if entry.detail.is_empty() {
            println!("{}  {}", entry.serial, entry.state);
        } else {
            println!("{}  {}  {}", entry.serial, entry.state, entry.detail);
        }
    }
    Ok(())
}

fn print_bridge_result(
    method: &str,
    serial: &str,
    package: &str,
    result: &Value,
    as_json: bool,
) -> Result<()> {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "schema_version": 1,
                "capability_id": format!("android.bridge.{method}"),
                "runtime_target": "android_debug_app_runtime",
                "control_effect": "read_only",
                "protocol": crate::android_bridge::BRIDGE_PROTOCOL_NAME,
                "serial": serial,
                "package": package,
                "result": result,
            }))?
        );
        return Ok(());
    }

    println!("Device: {serial}");
    println!("Package: {package}");
    match method {
        "status" => print_status_text(result),
        "doctor" => print_doctor_text(result),
        "lan" => print_lan_text(result),
        "code" => print_code_text(result),
        other => println!("{other}: {result}"),
    }
    Ok(())
}

fn print_status_text(result: &Value) {
    println!("App Version: {}", field(result, "versionName"));
    println!("Version Code: {}", field(result, "versionCode"));
    println!("Build Type: {}", field(result, "buildType"));
    println!("Device Model: {}", field(result, "deviceModel"));
    println!("Android SDK: {}", field(result, "sdkInt"));
    println!(
        "Classic LAN Control Sessions: {}",
        field(result, "classicLanControlSessions")
    );
    let discovery = result.get("discovery").cloned().unwrap_or(Value::Null);
    println!(
        "Local Network Permission: {}",
        field(&discovery, "localNetworkPermissionGranted")
    );
    print_advertising_line(&discovery);
    print_session_rows("Product Sessions", result.get("productSessions"));
}

fn print_doctor_text(result: &Value) {
    println!(
        "ML-KEM Native Provider: {}",
        field(result, "mlKemNativeAvailable")
    );
    println!("X-Wing KEM: {}", field(result, "xWingAvailable"));
    println!(
        "X-Wing Failure Reason: {}",
        field(result, "xWingFailureReason")
    );
    let nsd = result.get("nsd").cloned().unwrap_or(Value::Null);
    print_advertising_line(&nsd);
    let signaling = result.get("signaling").cloned().unwrap_or(Value::Null);
    println!("Signaling Server: {}", field(&signaling, "serverUrl"));
    println!(
        "Signaling WebSocket: {}",
        field(&signaling, "webSocketUrl")
    );
    println!("STUN: {}", field(&signaling, "stunUrl"));
    println!("TURN: {}", field(&signaling, "turnUrls"));
    println!(
        "TURN Credential Endpoint: {}",
        field(&signaling, "turnCredentialEndpoint")
    );
}

fn print_lan_text(result: &Value) {
    println!(
        "Approval Gate Installed: {}",
        field(result, "approvalGateInstalled")
    );
    println!(
        "Inbound Store Installed: {}",
        field(result, "inboundStoreInstalled")
    );
    println!(
        "Classic LAN Control Sessions: {}",
        field(result, "classicLanControlSessions")
    );
    println!(
        "File Transfer Service Type: {}",
        field(result, "fileTransferServiceType")
    );
    let advertising = result.get("advertising").cloned().unwrap_or(Value::Null);
    print_advertising_line(&advertising);
}

fn print_code_text(result: &Value) {
    println!("Scope: {}", field(result, "scope"));
    print_session_rows("Active Code Sessions", result.get("activeCodeSessions"));
}

fn print_advertising_line(container: &Value) {
    let state = field(container, "advertising");
    let service_type = field(container, "advertisingServiceType");
    let detail = field(container, "advertisingDetail");
    if detail == "none" {
        println!("NSD Advertising: {state} ({service_type})");
    } else {
        println!("NSD Advertising: {state} ({service_type}) — {detail}");
    }
}

fn print_session_rows(label: &str, sessions: Option<&Value>) {
    let Some(rows) = sessions.and_then(Value::as_array) else {
        println!("{label}: unknown");
        return;
    };
    println!("{label}: {}", rows.len());
    for row in rows {
        println!(
            "  - ref={} state={} remote={} routes={} expiresAt={}",
            field(row, "sessionRef"),
            field(row, "state"),
            field(row, "remoteDeviceRef"),
            field(row, "routeBindings"),
            field(row, "expiresAtEpochMillis"),
        );
    }
}

/// Displays one JSON field as human-readable text; absent/null become stable
/// placeholders so the operator can tell "not reported" from a real value.
fn field(container: &Value, key: &str) -> String {
    match container.get(key) {
        None => "unknown".to_owned(),
        Some(Value::Null) => "none".to_owned(),
        Some(Value::String(text)) => text.clone(),
        Some(Value::Bool(flag)) => flag.to_string(),
        Some(Value::Number(number)) => number.to_string(),
        Some(other) => serde_json::to_string(other)
            .unwrap_or_else(|_| "<unrenderable>".to_owned()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn field_rendering_distinguishes_absent_null_and_values() {
        let value = json!({
            "text": "hello",
            "flag": true,
            "count": 3,
            "nothing": null,
            "list": ["a", "b"],
        });
        assert_eq!(field(&value, "text"), "hello");
        assert_eq!(field(&value, "flag"), "true");
        assert_eq!(field(&value, "count"), "3");
        assert_eq!(field(&value, "nothing"), "none");
        assert_eq!(field(&value, "missing"), "unknown");
        assert_eq!(field(&value, "list"), "[\"a\",\"b\"]");
    }

    #[test]
    fn bridge_round_trip_answers_over_a_local_tcp_listener() {
        use std::net::TcpListener;

        let listener =
            TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind an ephemeral test port");
        let port = listener.local_addr().expect("test listener address").port();

        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept bridge test connection");
            let mut reader = BufReader::new(stream.try_clone().expect("clone test stream"));
            let mut line = String::new();
            reader.read_line(&mut line).expect("read request line");
            let request: Value = serde_json::from_str(line.trim()).expect("request is JSON");
            assert_eq!(request["v"], 1);
            assert_eq!(request["method"], "status");
            assert_eq!(request["token"], "0123456789abcdef0123");
            let response = json!({
                "v": 1,
                "id": request["id"],
                "ok": true,
                "result": { "versionName": "1.0.2-debug" },
            });
            let mut stream = stream;
            let mut body = response.to_string();
            body.push('\n');
            stream
                .write_all(body.as_bytes())
                .expect("write response line");
        });

        let result = bridge_round_trip(port, "0123456789abcdef0123", "status")
            .expect("round trip should succeed");
        assert_eq!(result["versionName"], "1.0.2-debug");
        server.join().expect("test server thread");
    }

    #[test]
    fn bridge_round_trip_fails_closed_when_nothing_listens() {
        use std::net::TcpListener;

        // Bind then drop to get a port that is very likely closed.
        let port = {
            let listener =
                TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind probe port");
            listener.local_addr().expect("probe address").port()
        };
        let error = bridge_round_trip(port, "0123456789abcdef0123", "status")
            .expect_err("closed port must fail");
        assert!(format!("{error:#}").contains("bridge_unreachable"));
    }
}
