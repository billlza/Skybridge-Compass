use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(target_os = "macos")]
use std::io::{BufRead, BufReader, Write};
#[cfg(target_os = "macos")]
use std::os::unix::fs::PermissionsExt;
#[cfg(target_os = "macos")]
use std::os::unix::net::UnixListener;
#[cfg(target_os = "macos")]
use std::thread;

use serde_json::Value;
use skybridge_agent::{
    load_file_transfer_request_registry, observe_file_transfer_requests_for_established_session,
    observe_remote_desktop_requests_for_established_session, resolve_paths,
    upsert_nearby_discovery_snapshot, upsert_remote_desktop_capability_snapshot,
    upsert_session_runtime,
};
use skybridge_core::{
    NearbyDiscoveredDevice, NearbyDiscoveryEndpointClass, NearbyDiscoverySnapshot,
    NearbyDiscoveryTrustStatus, RemoteDesktopCapabilitySnapshot, RemoteDesktopObservedMode,
    RuntimeSessionRecord, RuntimeSessionRole, RuntimeSessionSource, RuntimeSessionState,
    SessionReadiness,
};

#[test]
fn cli_identity_contract_uses_skybridge_cli_display_name_and_stable_binary()
-> Result<(), Box<dyn std::error::Error>> {
    let help = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .arg("--help")
        .output()?;
    assert!(
        help.status.success(),
        "skybridge --help failed with status {:?}; stderr={}",
        help.status.code(),
        String::from_utf8_lossy(&help.stderr)
    );
    assert!(
        help.stderr.is_empty(),
        "skybridge --help must not write stderr on success: {}",
        String::from_utf8_lossy(&help.stderr)
    );
    let help_stdout = String::from_utf8_lossy(&help.stdout);
    assert!(help_stdout.contains("SkyBridge CLI"), "{help_stdout}");
    assert!(help_stdout.contains("Usage: skybridge"), "{help_stdout}");
    assert!(
        !help_stdout.contains("Usage: skybridge-cli"),
        "{help_stdout}"
    );

    let version = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .arg("version")
        .output()?;
    assert!(
        version.status.success(),
        "skybridge version failed with status {:?}; stderr={}",
        version.status.code(),
        String::from_utf8_lossy(&version.stderr)
    );
    assert!(
        version.stderr.is_empty(),
        "skybridge version must not write stderr on success: {}",
        String::from_utf8_lossy(&version.stderr)
    );
    let version_payload: Value = serde_json::from_slice(&version.stdout)?;
    assert_eq!(version_payload["product_name"], "SkyBridge CLI");
    assert_eq!(version_payload["binary_name"], "skybridge");
    assert_eq!(version_payload["workspace"], "rust");

    let capabilities = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args(["capabilities", "--json"])
        .output()?;
    assert!(
        capabilities.status.success(),
        "skybridge capabilities --json failed with status {:?}; stderr={}",
        capabilities.status.code(),
        String::from_utf8_lossy(&capabilities.stderr)
    );
    let capability_payload: Value = serde_json::from_slice(&capabilities.stdout)?;
    assert_eq!(capability_payload["product_name"], "SkyBridge CLI");
    assert_eq!(capability_payload["binary_name"], "skybridge");
    assert_eq!(
        capability_payload["mac_gui_control_protocol"],
        "crossnet-control/1"
    );

    Ok(())
}

#[test]
fn capabilities_json_contract_is_machine_readable_without_live_success_claims()
-> Result<(), Box<dyn std::error::Error>> {
    let output = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args(["capabilities", "--json"])
        .output()?;

    assert!(
        output.status.success(),
        "capabilities --json failed with status {:?}; stderr={}",
        output.status.code(),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        output.stderr.is_empty(),
        "capabilities --json must keep stderr separate from the JSON contract: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let payload: Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(payload["schema_version"], 1);
    assert_eq!(payload["ios_runtime_control_supported"], false);
    assert_eq!(payload["mac_gui_control_protocol"], "crossnet-control/1");
    assert_eq!(
        payload["mac_gui_control_release_gate"],
        "signed_mac_app_socket_smoke_required"
    );

    let capabilities = payload["capabilities"]
        .as_array()
        .ok_or("capabilities must be a JSON array")?;
    assert!(
        !capabilities.is_empty(),
        "capabilities contract must not be empty"
    );

    for capability in capabilities {
        for field in [
            "id",
            "status",
            "runtime_target",
            "control_effect",
            "command",
            "owner_module",
            "authority_boundary",
            "verification_gate",
        ] {
            let value = capability[field]
                .as_str()
                .ok_or_else(|| format!("{field} must be a string"))?;
            assert!(
                !value.trim().is_empty(),
                "{field} must not be empty in {capability:?}"
            );
        }
    }

    assert_eq!(
        capability_status(capabilities, "crossnet.preflight")?,
        "read_only"
    );
    assert_eq!(
        capability_runtime_target(capabilities, "crossnet.preflight")?,
        "mac_app_runtime"
    );
    assert_eq!(
        capability_control_effect(capabilities, "crossnet.preflight")?,
        "read_only"
    );
    let preflight_command = capability_command(capabilities, "crossnet.preflight")?;
    assert!(
        preflight_command.contains("crossnet preflight"),
        "crossnet preflight capability must name the Mac app readiness command"
    );

    assert_eq!(
        capability_status(capabilities, "session.disconnect")?,
        "available"
    );
    assert_eq!(
        capability_status(capabilities, "remote_desktop.media.doctor")?,
        "read_only"
    );
    assert_eq!(
        capability_status(capabilities, "crossnet.status.snapshot")?,
        "read_only"
    );
    assert_eq!(
        capability_runtime_target(capabilities, "crossnet.status.snapshot")?,
        "mac_app_runtime"
    );
    assert_eq!(
        capability_control_effect(capabilities, "crossnet.status.snapshot")?,
        "read_only"
    );
    let status_snapshot_boundary =
        capability_authority_boundary(capabilities, "crossnet.status.snapshot")?;
    assert!(
        status_snapshot_boundary.contains("redacted session_ref")
            && status_snapshot_boundary.contains("does not")
            && status_snapshot_boundary.contains("iOS runtime"),
        "crossnet.status.snapshot must stay read-only, Mac-only, and redacted"
    );
    assert_eq!(
        capability_status(capabilities, "crossnet.settings.snapshot")?,
        "read_only"
    );
    assert_eq!(
        capability_runtime_target(capabilities, "crossnet.settings.snapshot")?,
        "mac_app_runtime"
    );
    assert_eq!(
        capability_control_effect(capabilities, "crossnet.settings.snapshot")?,
        "read_only"
    );
    let settings_snapshot_boundary =
        capability_authority_boundary(capabilities, "crossnet.settings.snapshot")?;
    assert!(
        settings_snapshot_boundary.contains("allowlisted")
            && settings_snapshot_boundary.contains("non-secret")
            && settings_snapshot_boundary.contains("does not write UserDefaults")
            && settings_snapshot_boundary.contains("iOS runtime"),
        "crossnet.settings.snapshot must stay read-only, allowlisted, and Mac-only"
    );
    assert_eq!(
        capability_status(capabilities, "crossnet.settings.set")?,
        "planned"
    );
    assert_eq!(
        capability_runtime_target(capabilities, "crossnet.settings.set")?,
        "mac_app_runtime"
    );
    assert_eq!(
        capability_control_effect(capabilities, "crossnet.settings.set")?,
        "mac_mutation_not_enabled"
    );
    let settings_set_boundary =
        capability_authority_boundary(capabilities, "crossnet.settings.set")?;
    assert!(
        settings_set_boundary.contains("typed allowlist")
            && settings_set_boundary.contains("runtime observation proof")
            && settings_set_boundary.contains("fail closed"),
        "crossnet.settings.set must remain planned until runtime mutation is proven"
    );
    assert_eq!(
        capability_status(capabilities, "crossnet.status.watch")?,
        "planned"
    );
    assert_eq!(
        capability_runtime_target(capabilities, "crossnet.status.watch")?,
        "mac_app_runtime"
    );
    assert_eq!(
        capability_control_effect(capabilities, "crossnet.status.watch")?,
        "planned_fail_closed"
    );
    let status_watch_boundary =
        capability_authority_boundary(capabilities, "crossnet.status.watch")?;
    assert!(
        status_watch_boundary.contains("watch_not_supported")
            && status_watch_boundary.contains("fail-closed"),
        "crossnet.status.watch must keep the fail-closed stream gate visible"
    );

    for planned_crossnet in ["crossnet.host", "crossnet.connect", "crossnet.disconnect"] {
        assert_eq!(
            capability_status(capabilities, planned_crossnet)?,
            "planned",
            "{planned_crossnet} must not claim end-to-end availability before signed Mac app socket smoke exists"
        );
        let boundary = capability_authority_boundary(capabilities, planned_crossnet)?;
        assert_eq!(
            capability_runtime_target(capabilities, planned_crossnet)?,
            "mac_app_runtime",
            "{planned_crossnet} must remain Mac-app scoped, not iOS or native-headless scoped"
        );
        let effect = capability_control_effect(capabilities, planned_crossnet)?;
        assert_eq!(effect, "mac_mutation_not_enabled");
        assert!(
            boundary.contains("Mac-only")
                && boundary.contains("signed Mac app")
                && boundary.contains("live socket smoke"),
            "{planned_crossnet} must keep the Mac-only signed-app smoke gate visible"
        );
    }
    let discovery_command = capability_command(capabilities, "device.discovery.nearby")?;
    assert_eq!(
        capability_runtime_target(capabilities, "device.discovery.nearby")?,
        "agent_owned_registry"
    );
    assert_eq!(
        capability_control_effect(capabilities, "device.discovery.nearby")?,
        "read_only"
    );
    assert!(
        discovery_command.contains("device discover --nearby"),
        "nearby discovery capability must name the fail-closed CLI surface"
    );
    let remote_start_command = capability_command(capabilities, "remote_desktop.start")?;
    assert!(
        remote_start_command.contains("--session-id")
            && remote_start_command.contains("--resolution")
            && remote_start_command.contains("--fps"),
        "remote desktop start capability text must match the actual clap options"
    );
    let remote_resolution_command =
        capability_command(capabilities, "remote_desktop.resolution.set")?;
    assert!(
        remote_resolution_command.contains("--resolution")
            && !remote_resolution_command.contains("--size"),
        "remote desktop resolution capability text must match the actual clap option"
    );
    let remote_fps_gate = capability_verification_gate(capabilities, "remote_desktop.fps.set")?;
    assert!(
        remote_fps_gate.contains("performance_p2p_remote_final_window_fps_gate"),
        "remote desktop fps capability must keep the FPS evidence gate visible"
    );
    for read_only in [
        "device.discovery.nearby",
        "remote_desktop.contract",
        "remote_desktop.status",
        "remote_desktop.resolution_contract",
        "remote_desktop.resolutions.list",
    ] {
        assert_eq!(capability_status(capabilities, read_only)?, "read_only");
    }

    assert_eq!(
        capability_status(capabilities, "file.transfer.send")?,
        "request_only"
    );
    assert_eq!(
        capability_runtime_target(capabilities, "file.transfer.send")?,
        "agent_owned_registry"
    );
    assert_eq!(
        capability_control_effect(capabilities, "file.transfer.send")?,
        "request_only"
    );
    assert_eq!(
        capability_status(capabilities, "file.transfer.receive")?,
        "planned"
    );
    let file_send_command = capability_command(capabilities, "file.transfer.send")?;
    assert!(
        file_send_command.contains("file send") && file_send_command.contains("--session-id"),
        "file send capability must expose the explicit request-only session binding"
    );
    let remote_resolutions_command =
        capability_command(capabilities, "remote_desktop.resolutions.list")?;
    assert!(
        remote_resolutions_command.contains("remote-desktop resolutions")
            && remote_resolutions_command.contains("--session-id"),
        "observed resolution listing must require an explicit session filter"
    );
    for request_only in [
        "remote_desktop.start",
        "remote_desktop.stop",
        "remote_desktop.resolution.set",
        "remote_desktop.fps.set",
    ] {
        assert_eq!(
            capability_status(capabilities, request_only)?,
            "request_only"
        );
        assert_eq!(
            capability_runtime_target(capabilities, request_only)?,
            "agent_owned_registry"
        );
        assert_eq!(
            capability_control_effect(capabilities, request_only)?,
            "request_only"
        );
    }

    Ok(())
}

#[cfg(target_os = "macos")]
#[test]
fn crossnet_cli_json_contract_uses_fake_socket_for_preflight_status_connect_json()
-> Result<(), Box<dyn std::error::Error>> {
    let secret = "session-token-secret";

    let preflight_home = make_crossnet_fake_home("preflight")?;
    let preflight_server = spawn_crossnet_fake_server(
        &preflight_home,
        vec![FakeCrossnetResponse {
            method: "crossnet.hello",
            result: serde_json::json!({
                "engine_version": "test-app",
                "proto": 1,
                "auth_loaded": false,
                "tenant_bound": true
            }),
        }],
    )?;
    let preflight = run_skybridge_with_home(&preflight_home, ["crossnet", "preflight", "--json"])?;
    assert_success_with_clean_stderr(&preflight, "crossnet preflight --json");
    let preflight_payload: Value = serde_json::from_slice(&preflight.stdout)?;
    assert_eq!(preflight_payload["preconditions_ready"], false);
    assert_eq!(preflight_payload["mutation_methods_enabled"], false);
    assert_eq!(preflight_payload["ready_for_mutation"], false);
    assert_eq!(preflight_payload["failure_code"], "auth_required");
    assert_eq!(preflight_payload["failure_class"], "operator_precondition");
    assert_eq!(
        preflight_payload["release_gate"],
        "signed_mac_app_socket_smoke_required"
    );
    let preflight_requests = join_crossnet_fake_server(preflight_server)?;
    assert_eq!(
        request_method(&preflight_requests[0]),
        Some("crossnet.hello")
    );
    let _ = std::fs::remove_dir_all(&preflight_home);

    let status_home = make_crossnet_fake_home("status")?;
    let status_server = spawn_crossnet_fake_server(
        &status_home,
        vec![FakeCrossnetResponse {
            method: "crossnet.status",
            result: serde_json::json!({
                "connection_status": "failed",
                "readiness": "idle",
                "session_present": false,
                "session_ref": null,
                "suite": null,
                "signaling_health": "degraded_fatal",
                "failure_code": "runtime_failed",
                "failure_class": "runtime_failure",
                "auth_loaded": true,
                "tenant_bound": true,
                "raw_failure_reason": secret
            }),
        }],
    )?;
    let status = run_skybridge_with_home(&status_home, ["crossnet", "status", "--json"])?;
    assert_success_with_clean_stderr(&status, "crossnet status --json");
    assert_public_output_excludes_secret(&status.stdout, secret);
    let status_payload: Value = serde_json::from_slice(&status.stdout)?;
    assert_eq!(status_payload["connection_status"], "failed");
    assert_eq!(status_payload["failure_code"], "runtime_failed");
    assert_eq!(status_payload["failure_class"], "runtime_failure");
    let status_requests = join_crossnet_fake_server(status_server)?;
    assert_eq!(request_method(&status_requests[0]), Some("crossnet.status"));
    let _ = std::fs::remove_dir_all(&status_home);

    let connect_home = make_crossnet_fake_home("connect-json")?;
    let connect_server = spawn_crossnet_fake_server(
        &connect_home,
        vec![
            FakeCrossnetResponse {
                method: "crossnet.hello",
                result: serde_json::json!({
                    "engine_version": "test-app",
                    "proto": 1,
                    "auth_loaded": true,
                    "tenant_bound": true
                }),
            },
            FakeCrossnetResponse {
                method: "crossnet.connect",
                result: serde_json::json!({
                    "session_id": secret,
                    "session_ref": "sha256:connectref",
                    "remote_device_name": "Test Mac",
                    "readiness": "handshake_complete"
                }),
            },
        ],
    )?;
    let connect =
        run_skybridge_with_home(&connect_home, ["crossnet", "connect", "ABCDEFGH", "--json"])?;
    assert_success_with_clean_stderr(&connect, "crossnet connect --json");
    assert_public_output_excludes_secret(&connect.stdout, secret);
    let connect_payload: Value = serde_json::from_slice(&connect.stdout)?;
    assert_eq!(connect_payload["session_ref"], "sha256:connectref");
    assert!(
        connect_payload.get("session_id").is_none(),
        "connect JSON must not expose raw session_id: {connect_payload:?}"
    );
    let connect_requests = join_crossnet_fake_server(connect_server)?;
    assert_eq!(request_method(&connect_requests[0]), Some("crossnet.hello"));
    assert_eq!(
        request_method(&connect_requests[1]),
        Some("crossnet.connect")
    );
    assert_eq!(
        connect_requests[1]
            .get("params")
            .and_then(|params| params.get("code"))
            .and_then(Value::as_str),
        Some("ABCDEFGH")
    );
    let _ = std::fs::remove_dir_all(&connect_home);

    Ok(())
}

#[cfg(target_os = "macos")]
#[test]
fn crossnet_cli_text_connect_uses_session_ref_without_raw_session_id()
-> Result<(), Box<dyn std::error::Error>> {
    let secret = "session-token-secret";
    let home = make_crossnet_fake_home("connect-text")?;
    let server = spawn_crossnet_fake_server(
        &home,
        vec![
            FakeCrossnetResponse {
                method: "crossnet.hello",
                result: serde_json::json!({
                    "engine_version": "test-app",
                    "proto": 1,
                    "auth_loaded": true,
                    "tenant_bound": true
                }),
            },
            FakeCrossnetResponse {
                method: "crossnet.connect",
                result: serde_json::json!({
                    "session_id": secret,
                    "session_ref": "sha256:textref",
                    "remote_device_name": "Test Mac",
                    "readiness": "handshake_complete"
                }),
            },
        ],
    )?;

    let output = run_skybridge_with_home(&home, ["crossnet", "connect", "ABCDEFGH"])?;
    assert_success_with_clean_stderr(&output, "crossnet connect");
    assert_public_output_excludes_secret(&output.stdout, secret);
    let rendered = String::from_utf8_lossy(&output.stdout);
    assert!(
        rendered.contains("Session Ref: sha256:textref"),
        "{rendered}"
    );
    assert!(!rendered.contains("Session ID:"), "{rendered}");
    let requests = join_crossnet_fake_server(server)?;
    assert_eq!(request_method(&requests[0]), Some("crossnet.hello"));
    assert_eq!(request_method(&requests[1]), Some("crossnet.connect"));
    let _ = std::fs::remove_dir_all(&home);

    Ok(())
}

#[cfg(target_os = "macos")]
struct FakeCrossnetResponse {
    method: &'static str,
    result: Value,
}

#[cfg(target_os = "macos")]
type CrossnetFakeServerHandle = thread::JoinHandle<Result<Vec<Value>, String>>;

#[cfg(target_os = "macos")]
fn make_crossnet_fake_home(name: &str) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let short_name: String = name.chars().take(4).collect();
    let suffix = (nanos & 0xffff_ffff) as u64;
    let home = PathBuf::from(format!(
        "/tmp/sbcx-{}-{suffix:08x}-{short_name}",
        std::process::id()
    ));
    std::fs::create_dir(&home)?;
    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700))?;
    let socket_dir = home.join("Library/Application Support/SkyBridge");
    std::fs::create_dir_all(&socket_dir)?;
    std::fs::set_permissions(&socket_dir, std::fs::Permissions::from_mode(0o700))?;
    Ok(home)
}

#[cfg(target_os = "macos")]
fn crossnet_socket_path(home: &Path) -> PathBuf {
    home.join("Library/Application Support/SkyBridge/crossnet-control.sock")
}

#[cfg(target_os = "macos")]
fn spawn_crossnet_fake_server(
    home: &Path,
    responses: Vec<FakeCrossnetResponse>,
) -> Result<CrossnetFakeServerHandle, Box<dyn std::error::Error>> {
    let socket_path = crossnet_socket_path(home);
    let listener = UnixListener::bind(&socket_path)?;
    let handle = thread::spawn(move || {
        let mut requests = Vec::new();
        for expected in responses {
            let (stream, _) = listener.accept().map_err(|err| err.to_string())?;
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).map_err(|err| err.to_string())?;
            let request: Value = serde_json::from_str(&line).map_err(|err| err.to_string())?;
            let id = request
                .get("id")
                .and_then(Value::as_str)
                .ok_or_else(|| "request missing id".to_owned())?
                .to_owned();
            let method = request
                .get("method")
                .and_then(Value::as_str)
                .ok_or_else(|| "request missing method".to_owned())?;
            if method != expected.method {
                return Err(format!(
                    "unexpected crossnet method: expected {} got {method}",
                    expected.method
                ));
            }
            let response = serde_json::json!({
                "v": 1,
                "id": id,
                "ok": true,
                "result": expected.result,
            });
            serde_json::to_writer(reader.get_mut(), &response).map_err(|err| err.to_string())?;
            reader
                .get_mut()
                .write_all(b"\n")
                .map_err(|err| err.to_string())?;
            reader.get_mut().flush().map_err(|err| err.to_string())?;
            requests.push(request);
        }
        Ok(requests)
    });
    Ok(handle)
}

#[cfg(target_os = "macos")]
fn run_skybridge_with_home<const N: usize>(
    home: &Path,
    args: [&str; N],
) -> Result<std::process::Output, Box<dyn std::error::Error>> {
    Ok(Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .env("HOME", home)
        .args(args)
        .output()?)
}

#[cfg(target_os = "macos")]
fn assert_success_with_clean_stderr(output: &std::process::Output, command: &str) {
    assert!(
        output.status.success(),
        "{command} failed with status {:?}; stdout={}; stderr={}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        output.stderr.is_empty(),
        "{command} must keep stderr clean on success: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[cfg(target_os = "macos")]
fn assert_public_output_excludes_secret(output: &[u8], secret: &str) {
    let rendered = String::from_utf8_lossy(output);
    assert!(
        !rendered.contains(secret),
        "public crossnet output leaked secret `{secret}`: {rendered}"
    );
}

#[cfg(target_os = "macos")]
fn request_method(request: &Value) -> Option<&str> {
    request.get("method").and_then(Value::as_str)
}

#[cfg(target_os = "macos")]
fn join_crossnet_fake_server(
    handle: thread::JoinHandle<Result<Vec<Value>, String>>,
) -> Result<Vec<Value>, Box<dyn std::error::Error>> {
    match handle.join() {
        Ok(Ok(requests)) => Ok(requests),
        Ok(Err(message)) => Err(message.into()),
        Err(_) => Err("crossnet fake server panicked".into()),
    }
}

#[test]
fn performance_json_contract_redacts_artifact_targets_and_identity_details()
-> Result<(), Box<dyn std::error::Error>> {
    let p2p_artifact = copy_fixture_dir(
        &["p2p-remote", "full-2k60-pass"],
        "p2p-remote-secret-ipad-device-1",
    )?;
    let p2p_artifact_arg = p2p_artifact.display().to_string();
    let p2p = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "check",
            "performance",
            "--kind",
            "p2p-remote",
            "--artifact-dir",
            &p2p_artifact_arg,
            "--json",
            "--min-fps",
            "59",
            "--min-width",
            "2056",
            "--min-height",
            "1329",
            "--exact-video-size",
            "--min-pass-window-seconds",
            "10",
            "--require-audio",
            "true",
            "--strict-fps-floor",
            "true",
        ])
        .output()?;
    assert!(
        p2p.status.success(),
        "P2P performance JSON should pass for the golden fixture; stderr={}",
        String::from_utf8_lossy(&p2p.stderr)
    );
    assert!(
        p2p.stderr.is_empty(),
        "P2P performance JSON must keep stderr clean: {}",
        String::from_utf8_lossy(&p2p.stderr)
    );
    let p2p_payload: Value = serde_json::from_slice(&p2p.stdout)?;
    assert_eq!(
        p2p_payload["target"],
        "performance p2p-remote artifact=<redacted-artifact-dir> min_fps=59.0"
    );
    let p2p_stdout = String::from_utf8_lossy(&p2p.stdout);
    for secret in [
        p2p_artifact_arg.as_str(),
        "p2p-remote-secret-ipad-device-1",
        "ipad-stable-1",
        "ipad-device-1",
        "ipad-fp-1",
        "192.0.2.10",
        "mac.local",
        "abc",
        "123456",
    ] {
        assert!(
            !p2p_stdout.contains(secret),
            "P2P public performance JSON leaked {secret}: {p2p_stdout}"
        );
    }

    let file_artifact = copy_fixture_dir(
        &["file-transfer", "signed-kem-pass"],
        "file-transfer-secret-golden-artifact",
    )?;
    let file_artifact_arg = file_artifact.display().to_string();
    let file_transfer = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "check",
            "performance",
            "--kind",
            "file-transfer",
            "--artifact-dir",
            &file_artifact_arg,
            "--json",
        ])
        .output()?;
    assert!(
        file_transfer.status.success(),
        "file-transfer performance JSON should pass for the golden fixture; stderr={}",
        String::from_utf8_lossy(&file_transfer.stderr)
    );
    assert!(
        file_transfer.stderr.is_empty(),
        "file-transfer performance JSON must keep stderr clean: {}",
        String::from_utf8_lossy(&file_transfer.stderr)
    );
    let file_payload: Value = serde_json::from_slice(&file_transfer.stdout)?;
    assert_eq!(
        file_payload["target"],
        "performance file-transfer artifact=<redacted-artifact-dir>"
    );
    let file_stdout = String::from_utf8_lossy(&file_transfer.stdout);
    for secret in [
        file_artifact_arg.as_str(),
        "file-transfer-secret-golden-artifact",
        "192.168.0.2",
        "mac.local",
        "abc",
        "123456",
        "id:peer",
        "ios-smoke-GOLDEN.txt",
        "mac-smoke-GOLDEN.txt",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    ] {
        assert!(
            !file_stdout.contains(secret),
            "file-transfer public performance JSON leaked {secret}: {file_stdout}"
        );
    }

    Ok(())
}

#[test]
fn file_transfer_json_contract_fails_closed_without_path_or_peer_leakage()
-> Result<(), Box<dyn std::error::Error>> {
    let send = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "file",
            "send",
            "/tmp/secret-payload.txt",
            "--to",
            "peer-device-secret",
            "--json",
        ])
        .output()?;
    assert!(
        !send.status.success(),
        "file send --json must remain fail-closed until route and receipt proof exist"
    );
    assert!(
        send.stdout.is_empty(),
        "failed JSON file send must not emit fake success to stdout"
    );
    let stderr = String::from_utf8_lossy(&send.stderr);
    assert!(
        stderr.contains("\"capability_id\": \"file.transfer.send\"")
            && stderr.contains("\"accepted\": false")
            && stderr.contains("\"status\": \"planned\"")
            && stderr.contains("\"route_bound\": false")
            && stderr.contains("real_device_file_transfer_gate"),
        "file send failure should expose the planned contract and required gates; stderr={stderr}"
    );
    assert!(
        !stderr.contains("secret-payload") && !stderr.contains("peer-device-secret"),
        "file send planned contract must not leak local paths or peer identifiers; stderr={stderr}"
    );

    let state_dir = make_state_dir("file-transfer-json-contract")?;
    seed_established_session(&state_dir, "session-1")?;
    let source_path = state_dir.join("secret-payload-request.bin");
    std::fs::write(&source_path, b"hello")?;
    let state_arg = state_dir.display().to_string();
    let source_arg = source_path.display().to_string();
    let send = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &state_arg,
            "file",
            "send",
            &source_arg,
            "--to",
            "remote-device",
            "--session-id",
            "session-1",
            "--json",
        ])
        .output()?;
    assert!(
        send.status.success(),
        "file send should register a pending agent-owned request for a handshake-complete session; stderr={}",
        String::from_utf8_lossy(&send.stderr)
    );
    assert!(
        send.stderr.is_empty(),
        "successful file send request registration must keep stderr clean: {}",
        String::from_utf8_lossy(&send.stderr)
    );
    let payload: Value = serde_json::from_slice(&send.stdout)?;
    assert_eq!(payload["capability_id"], "file.transfer.send");
    assert_eq!(payload["action"], "send");
    assert_eq!(payload["accepted"], true);
    assert_eq!(payload["request_registered"], true);
    assert_eq!(payload["status"], "pending_agent_observation");
    assert_eq!(payload["pending_agent_observation"], true);
    assert_eq!(payload["agent_observed"], false);
    assert_eq!(payload["transfer_started"], false);
    assert_eq!(payload["applied"], false);
    assert_eq!(payload["receipt_verified"], false);
    assert_eq!(payload["source_regular_file_verified"], true);
    assert_eq!(payload["source_sha256_recorded"], true);
    assert_eq!(payload["destination_bound_to_session_peer"], true);
    assert_eq!(payload["session_id"], "session-1");
    assert!(
        payload["target_runtime_id"].is_null(),
        "public file send JSON must not expose internal runtime ids"
    );
    assert_eq!(payload["source_size_bytes"], 5);
    assert!(
        payload["request_id"]
            .as_str()
            .is_some_and(|value| !value.trim().is_empty())
    );
    assert!(
        payload["required_gates_before_live_transfer"]
            .as_array()
            .ok_or("required_gates_before_live_transfer must be an array")?
            .iter()
            .any(|gate| gate == "file_sha256_receipt")
    );
    let stdout = String::from_utf8_lossy(&send.stdout);
    assert!(
        !stdout.contains("secret-payload-request")
            && !stdout.contains("remote-device")
            && !stdout.contains("fingerprint")
            && !stdout.contains("runtime-session-1")
            && !stdout.contains("2cf24dba"),
        "public file send JSON must not leak local filenames, peer ids, fingerprints, or file hashes; stdout={stdout}"
    );
    assert_no_unevidenced_success_or_legacy_ack_terms(&send.stdout);
    let runtime = tokio::runtime::Runtime::new()?;
    let registry = runtime.block_on(async {
        let paths = resolve_paths(Some(state_dir.clone()))?;
        load_file_transfer_request_registry(&paths).await
    })?;
    let pending = registry.pending_for_session("session-1");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].source.size_bytes, 5);
    assert_eq!(
        pending[0].source.sha256_hex,
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    );

    let mismatch_state_dir = make_state_dir("file-transfer-mismatch-json-contract")?;
    seed_established_session(&mismatch_state_dir, "session-mismatch")?;
    let mismatch_source_path = mismatch_state_dir.join("secret-payload-mismatch.bin");
    std::fs::write(&mismatch_source_path, b"mismatch")?;
    let mismatch_state_arg = mismatch_state_dir.display().to_string();
    let mismatch_source_arg = mismatch_source_path.display().to_string();
    let mismatch = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &mismatch_state_arg,
            "file",
            "send",
            &mismatch_source_arg,
            "--to",
            "wrong-peer-secret",
            "--session-id",
            "session-mismatch",
            "--json",
        ])
        .output()?;
    assert!(
        !mismatch.status.success(),
        "session-bound file send destination mismatch must fail closed"
    );
    assert!(
        mismatch.stdout.is_empty(),
        "destination mismatch must not emit fake file-transfer success to stdout"
    );
    let mismatch_stderr = String::from_utf8_lossy(&mismatch.stderr);
    assert!(
        mismatch_stderr.contains("\"capability_id\": \"file.transfer.send\"")
            && mismatch_stderr.contains("\"accepted\": false")
            && mismatch_stderr.contains("\"request_registered\": false")
            && mismatch_stderr.contains("\"pending_agent_observation\": false")
            && mismatch_stderr.contains("\"transfer_started\": false")
            && mismatch_stderr.contains("\"applied\": false")
            && mismatch_stderr.contains("\"receipt_verified\": false")
            && mismatch_stderr.contains("\"status\": \"rejected\"")
            && mismatch_stderr.contains("\"session_id_provided\": true")
            && mismatch_stderr.contains("\"code\": \"file_transfer_request_rejected\""),
        "destination mismatch should emit a stable redacted request rejection; stderr={mismatch_stderr}"
    );
    assert!(
        !mismatch_stderr.contains("wrong-peer-secret")
            && !mismatch_stderr.contains("secret-payload-mismatch")
            && !mismatch_stderr.contains("session-mismatch")
            && !mismatch_stderr.contains("remote-device")
            && !mismatch_stderr.contains("fingerprint")
            && !mismatch_stderr.contains(&mismatch_state_arg),
        "destination mismatch rejection must not leak peer identity, paths, or state dir; stderr={mismatch_stderr}"
    );
    let runtime = tokio::runtime::Runtime::new()?;
    let mismatch_registry = runtime.block_on(async {
        let paths = resolve_paths(Some(mismatch_state_dir.clone()))?;
        load_file_transfer_request_registry(&paths).await
    })?;
    assert!(
        mismatch_registry
            .pending_for_session("session-mismatch")
            .is_empty(),
        "destination mismatch must fail before writing a pending file-transfer request"
    );

    let invalid_source_state_dir = make_state_dir("file-transfer-invalid-source-json-contract")?;
    seed_established_session(&invalid_source_state_dir, "session-invalid-source")?;
    let invalid_state_arg = invalid_source_state_dir.display().to_string();
    let missing_source = invalid_source_state_dir.join("missing-secret-payload.bin");
    let missing_source_arg = missing_source.display().to_string();
    let missing_file = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &invalid_state_arg,
            "file",
            "send",
            &missing_source_arg,
            "--to",
            "remote-device",
            "--session-id",
            "session-invalid-source",
            "--json",
        ])
        .output()?;
    assert!(
        !missing_file.status.success(),
        "missing source files must fail closed"
    );
    assert!(missing_file.stdout.is_empty());
    let missing_file_stderr = String::from_utf8_lossy(&missing_file.stderr);
    assert!(
        missing_file_stderr.contains("\"status\": \"rejected\"")
            && missing_file_stderr.contains("\"request_registered\": false")
            && missing_file_stderr.contains("\"pending_agent_observation\": false"),
        "missing file should emit stable rejection JSON; stderr={missing_file_stderr}"
    );
    assert!(
        !missing_file_stderr.contains("missing-secret-payload")
            && !missing_file_stderr.contains("remote-device")
            && !missing_file_stderr.contains("session-invalid-source")
            && !missing_file_stderr.contains(&invalid_state_arg),
        "missing file rejection must not leak paths or peer/session identifiers; stderr={missing_file_stderr}"
    );

    let directory_source = invalid_source_state_dir.join("secret-directory-source");
    std::fs::create_dir_all(&directory_source)?;
    let directory_source_arg = directory_source.display().to_string();
    let directory = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &invalid_state_arg,
            "file",
            "send",
            &directory_source_arg,
            "--to",
            "remote-device",
            "--session-id",
            "session-invalid-source",
            "--json",
        ])
        .output()?;
    assert!(
        !directory.status.success(),
        "directory sources must fail closed"
    );
    assert!(directory.stdout.is_empty());
    let directory_stderr = String::from_utf8_lossy(&directory.stderr);
    assert!(
        directory_stderr.contains("\"status\": \"rejected\"")
            && directory_stderr.contains("\"request_registered\": false")
            && directory_stderr.contains("\"pending_agent_observation\": false"),
        "directory source should emit stable rejection JSON; stderr={directory_stderr}"
    );
    assert!(
        !directory_stderr.contains("secret-directory-source")
            && !directory_stderr.contains("remote-device")
            && !directory_stderr.contains(&invalid_state_arg),
        "directory rejection must not leak local paths or peer identifiers; stderr={directory_stderr}"
    );

    let blank_peer_source = invalid_source_state_dir.join("blank-peer-payload.bin");
    std::fs::write(&blank_peer_source, b"blank-peer")?;
    let blank_peer_source_arg = blank_peer_source.display().to_string();
    let blank_peer = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &invalid_state_arg,
            "file",
            "send",
            &blank_peer_source_arg,
            "--to",
            "",
            "--session-id",
            "session-invalid-source",
            "--json",
        ])
        .output()?;
    assert!(
        !blank_peer.status.success(),
        "blank peer refs must fail closed"
    );
    assert!(blank_peer.stdout.is_empty());
    let blank_peer_stderr = String::from_utf8_lossy(&blank_peer.stderr);
    assert!(
        blank_peer_stderr.contains("\"status\": \"rejected\"")
            && blank_peer_stderr.contains("\"request_registered\": false")
            && blank_peer_stderr.contains("\"pending_agent_observation\": false"),
        "blank peer should emit stable rejection JSON; stderr={blank_peer_stderr}"
    );

    let invalid_source_registry = runtime.block_on(async {
        let paths = resolve_paths(Some(invalid_source_state_dir.clone()))?;
        load_file_transfer_request_registry(&paths).await
    })?;
    assert!(
        invalid_source_registry
            .pending_for_session("session-invalid-source")
            .is_empty(),
        "invalid file-transfer inputs must fail before writing pending requests"
    );

    let receive = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args(["file", "receive", "--json"])
        .output()?;
    assert!(
        !receive.status.success(),
        "file receive --json must remain fail-closed until receive policy and sender identity proof exist"
    );
    assert!(
        receive.stdout.is_empty(),
        "failed JSON file receive must not emit fake success to stdout"
    );
    let stderr = String::from_utf8_lossy(&receive.stderr);
    assert!(
        stderr.contains("\"capability_id\": \"file.transfer.receive\"")
            && stderr.contains("\"accepted\": false")
            && stderr.contains("\"status\": \"planned\"")
            && stderr.contains("receiver_write_policy"),
        "file receive failure should expose the planned contract and required gates; stderr={stderr}"
    );

    let empty_history_state_dir = make_state_dir("file-transfer-empty-history-json-contract")?;
    let empty_history_state_arg = empty_history_state_dir.display().to_string();
    let empty_history = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &empty_history_state_arg,
            "file",
            "history",
            "--json",
        ])
        .output()?;
    assert!(
        empty_history.status.success(),
        "file history --json should read an empty agent-owned request registry"
    );
    assert!(
        empty_history.stderr.is_empty(),
        "empty file history --json must keep stderr clean: {}",
        String::from_utf8_lossy(&empty_history.stderr)
    );
    let payload: Value = serde_json::from_slice(&empty_history.stdout)?;
    assert_eq!(payload["schema_version"], 1);
    assert_eq!(payload["capability_id"], "file.transfer.history");
    assert_eq!(payload["status"], "read_only_empty");
    assert_eq!(payload["history_supported"], true);
    assert_eq!(payload["pending_requests"], 0);
    assert!(
        payload["history"]
            .as_array()
            .ok_or("empty history must be an array")?
            .is_empty()
    );

    let history = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args(["--state-dir", &state_arg, "file", "history", "--json"])
        .output()?;
    assert!(
        history.status.success(),
        "file history --json should read the agent-owned pending request registry"
    );
    assert!(
        history.stderr.is_empty(),
        "file history --json must keep stderr clean: {}",
        String::from_utf8_lossy(&history.stderr)
    );
    let payload: Value = serde_json::from_slice(&history.stdout)?;
    assert_eq!(payload["schema_version"], 1);
    assert_eq!(payload["capability_id"], "file.transfer.history");
    assert_eq!(payload["status"], "pending_agent_observation");
    assert_eq!(payload["history_supported"], true);
    assert_eq!(payload["pending_requests"], 1);
    assert_eq!(payload["history"][0]["session_id"], "session-1");
    assert_eq!(payload["history"][0]["status"], "pending_agent_observation");
    assert_eq!(payload["history"][0]["pending_agent_observation"], true);
    assert_eq!(payload["history"][0]["agent_observed"], false);
    assert_eq!(payload["history"][0]["transfer_started"], false);
    assert_eq!(payload["history"][0]["transfer_completed"], false);
    assert_eq!(payload["history"][0]["receipt_verified"], false);
    assert_eq!(payload["history"][0]["source_size_bytes"], 5);
    assert_eq!(payload["history"][0]["source_sha256_recorded"], true);
    assert!(
        payload["required_gates_before_history"]
            .as_array()
            .ok_or("required_gates_before_history must be an array")?
            .iter()
            .any(|gate| gate == "real_device_file_transfer_gate")
    );
    let history_stdout = String::from_utf8_lossy(&history.stdout);
    for secret in [
        source_arg.as_str(),
        "secret-payload-request",
        "remote-device",
        "fingerprint",
        "runtime-session-1",
        "2cf24dba",
        state_arg.as_str(),
    ] {
        assert!(
            !history_stdout.contains(secret),
            "file history JSON leaked private request detail {secret}: {history_stdout}"
        );
    }

    let observed = runtime.block_on(async {
        let paths = resolve_paths(Some(state_dir.clone()))?;
        observe_file_transfer_requests_for_established_session(&paths, "session-1").await
    })?;
    assert_eq!(observed.len(), 1);
    assert!(observed[0].is_agent_observed());
    assert!(!observed[0].is_pending_agent_observation());

    let observed_history = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args(["--state-dir", &state_arg, "file", "history", "--json"])
        .output()?;
    assert!(
        observed_history.status.success(),
        "file history --json should show agent observe without transfer success; stderr={}",
        String::from_utf8_lossy(&observed_history.stderr)
    );
    assert!(
        observed_history.stderr.is_empty(),
        "observed file history --json must keep stderr clean: {}",
        String::from_utf8_lossy(&observed_history.stderr)
    );
    let payload: Value = serde_json::from_slice(&observed_history.stdout)?;
    assert_eq!(payload["status"], "agent_observed");
    assert_eq!(payload["history_supported"], true);
    assert_eq!(payload["pending_requests"], 0);
    assert_eq!(payload["history"][0]["status"], "agent_observed");
    assert_eq!(payload["history"][0]["pending_agent_observation"], false);
    assert_eq!(payload["history"][0]["agent_observed"], true);
    assert_eq!(payload["history"][0]["transfer_started"], false);
    assert_eq!(payload["history"][0]["transfer_completed"], false);
    assert_eq!(payload["history"][0]["receipt_verified"], false);
    assert_eq!(payload["history"][0]["source_size_bytes"], 5);
    assert_eq!(payload["history"][0]["source_sha256_recorded"], true);
    assert_no_unevidenced_success_or_legacy_ack_terms(&observed_history.stdout);
    let observed_history_stdout = String::from_utf8_lossy(&observed_history.stdout);
    for secret in [
        source_arg.as_str(),
        "secret-payload-request",
        "remote-device",
        "fingerprint",
        "runtime-session-1",
        "2cf24dba",
        state_arg.as_str(),
    ] {
        assert!(
            !observed_history_stdout.contains(secret),
            "observed file history JSON leaked private request detail {secret}: {observed_history_stdout}"
        );
    }

    Ok(())
}

#[test]
fn remote_desktop_json_contract_is_machine_readable_without_live_success_claims()
-> Result<(), Box<dyn std::error::Error>> {
    let output = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args(["remote-desktop", "contract", "--json"])
        .output()?;

    assert!(
        output.status.success(),
        "remote-desktop contract --json failed with status {:?}; stderr={}",
        output.status.code(),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        output.stderr.is_empty(),
        "remote-desktop contract --json must not write diagnostics to stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let payload: Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(payload["schema_version"], 1);
    assert_eq!(payload["live_control_status"], "planned");
    assert_eq!(payload["mutation_supported"], false);
    assert_eq!(payload["agent_observation_supported"], true);
    assert!(
        payload["required_gates"]
            .as_array()
            .ok_or("required_gates must be an array")?
            .iter()
            .any(|gate| gate == "real_device_p2p_remote_gate")
    );
    assert!(
        payload["commands"]
            .as_array()
            .ok_or("commands must be an array")?
            .iter()
            .any(|command| command["command"]
                .as_str()
                .is_some_and(|value| value.contains("set-fps"))
                && command["status"] == "request_only")
    );

    let resolutions = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args(["remote-desktop", "resolutions", "--json"])
        .output()?;
    assert!(
        resolutions.status.success(),
        "remote-desktop resolutions --json failed with status {:?}; stderr={}",
        resolutions.status.code(),
        String::from_utf8_lossy(&resolutions.stderr)
    );
    assert!(
        resolutions.stderr.is_empty(),
        "remote-desktop resolutions --json must not write diagnostics to stderr: {}",
        String::from_utf8_lossy(&resolutions.stderr)
    );
    let payload: Value = serde_json::from_slice(&resolutions.stdout)?;
    assert_eq!(payload["live_control_status"], "planned");
    assert_eq!(payload["mutation_supported"], false);
    assert!(payload["session_filter"].is_null());
    assert_eq!(payload["observed_modes_status"], "planned");
    assert_eq!(
        payload["observed_modes_source"],
        "agent_owned_remote_desktop_capability_snapshot_not_live_apply"
    );
    assert!(
        payload["observed_sessions"]
            .as_array()
            .ok_or("observed_sessions must be an array")?
            .is_empty(),
        "unfiltered request-contract output must not fabricate observed sender modes"
    );
    assert_eq!(
        payload["resolutions"]
            .as_array()
            .ok_or("resolutions must be an array")?
            .iter()
            .map(|resolution| resolution["id"].as_str())
            .collect::<Vec<_>>(),
        vec![
            Some("auto"),
            Some("1280x720"),
            Some("1920x1080"),
            Some("2056x1329"),
            Some("2560x1440"),
        ],
        "request-contract resolutions must stay bounded until sender modes are observed"
    );
    assert_eq!(
        payload["fps_values"]
            .as_array()
            .ok_or("fps_values must be an array")?
            .iter()
            .map(|fps| fps.as_u64())
            .collect::<Vec<_>>(),
        vec![Some(30), Some(60), Some(120)],
        "request-contract FPS values must stay bounded until sender observe/apply exists"
    );

    let state_dir = make_state_dir("remote-desktop-json-contract")?;
    seed_established_session(&state_dir, "session-1")?;
    seed_established_session(&state_dir, "session-modes")?;
    seed_capability_snapshot(&state_dir, "session-modes")?;
    let state_arg = state_dir.display().to_string();

    let observed_resolutions = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &state_arg,
            "remote-desktop",
            "resolutions",
            "--session-id",
            "session-modes",
            "--json",
        ])
        .output()?;
    assert!(
        observed_resolutions.status.success(),
        "remote-desktop resolutions --session-id should read the agent-owned snapshot; stderr={}",
        String::from_utf8_lossy(&observed_resolutions.stderr)
    );
    assert!(
        observed_resolutions.stderr.is_empty(),
        "observed resolution listing must keep stderr clean: {}",
        String::from_utf8_lossy(&observed_resolutions.stderr)
    );
    let payload: Value = serde_json::from_slice(&observed_resolutions.stdout)?;
    assert_eq!(payload["session_filter"], "session-modes");
    assert_eq!(payload["observed_modes_status"], "available");
    assert_eq!(payload["live_control_status"], "planned");
    assert_eq!(payload["mutation_supported"], false);
    assert_eq!(
        payload["observed_sessions"][0]["session_id"],
        "session-modes"
    );
    assert!(
        payload["observed_sessions"][0]["target_runtime_id"].is_null(),
        "observed mode public JSON must not expose internal runtime ids"
    );
    assert_eq!(
        payload["observed_sessions"][0]["sender_modes"][0]["id"],
        "1920x1080@60"
    );
    assert_eq!(
        payload["observed_sessions"][0]["display_modes"][0]["id"],
        "display-main"
    );
    assert_eq!(
        payload["observed_sessions"][0]["live_apply_supported"],
        false
    );
    assert_eq!(
        payload["observed_sessions"][0]["control_request_agent_observed"],
        false
    );
    assert!(
        payload["observed_sessions"][0]["agent_observed"].is_null(),
        "observed mode public JSON must avoid ambiguous agent_observed wording"
    );
    assert!(
        payload["observed_sessions"][0]["expires_at"]
            .as_str()
            .is_some_and(|value| !value.trim().is_empty()),
        "observed mode JSON must include freshness metadata"
    );
    assert_eq!(payload["observed_sessions"][0]["applied"], false);

    seed_established_session(&state_dir, "session-stale-modes")?;
    seed_stale_capability_snapshot(&state_dir, "session-stale-modes")?;
    let stale_resolutions = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &state_arg,
            "remote-desktop",
            "resolutions",
            "--session-id",
            "session-stale-modes",
            "--json",
        ])
        .output()?;
    assert!(
        stale_resolutions.status.success(),
        "stale capability snapshots should produce a stale report, not a hard failure; stderr={}",
        String::from_utf8_lossy(&stale_resolutions.stderr)
    );
    assert!(
        stale_resolutions.stderr.is_empty(),
        "stale resolution listing must keep stderr clean: {}",
        String::from_utf8_lossy(&stale_resolutions.stderr)
    );
    let payload: Value = serde_json::from_slice(&stale_resolutions.stdout)?;
    assert_eq!(payload["session_filter"], "session-stale-modes");
    assert_eq!(payload["observed_modes_status"], "stale");
    assert_eq!(payload["live_control_status"], "planned");
    assert!(
        payload["observed_sessions"]
            .as_array()
            .ok_or("stale observed_sessions must be an array")?
            .is_empty(),
        "stale capability snapshots must not expose stale sender modes"
    );
    let stale_stdout = String::from_utf8_lossy(&stale_resolutions.stdout);
    assert!(
        !stale_stdout.contains("runtime-session-stale-modes")
            && !stale_stdout.contains("stale-secret-mode"),
        "stale resolution report must not leak stale runtime ids or mode names; stdout={stale_stdout}"
    );

    let live_start = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &state_arg,
            "remote-desktop",
            "start",
            "--session-id",
            "session-1",
            "--resolution",
            "1920x1080",
            "--fps",
            "60",
            "--json",
        ])
        .output()?;
    assert!(
        live_start.status.success(),
        "remote-desktop start should register a pending agent-owned request for an established session; stderr={}",
        String::from_utf8_lossy(&live_start.stderr)
    );
    assert!(
        live_start.stderr.is_empty(),
        "successful request registration must keep stderr clean: {}",
        String::from_utf8_lossy(&live_start.stderr)
    );
    let payload: Value = serde_json::from_slice(&live_start.stdout)?;
    assert_eq!(payload["accepted"], true);
    assert_eq!(payload["request_registered"], true);
    assert_eq!(payload["pending_agent_observation"], true);
    assert_eq!(payload["agent_observed"], false);
    assert_eq!(payload["applied"], false);
    assert_eq!(payload["live_control_status"], "pending_agent_observation");
    assert!(
        payload["request_id"]
            .as_str()
            .is_some_and(|value| !value.trim().is_empty())
    );
    assert_eq!(payload["request"]["action"], "start");
    assert_eq!(payload["request"]["fps"], 60);
    assert_eq!(payload["request"]["resolution"]["kind"], "preset");
    assert_eq!(payload["request"]["resolution"]["id"], "1920x1080");
    assert_no_unevidenced_success_or_legacy_ack_terms(&live_start.stdout);

    let set_resolution_payload = run_remote_desktop_mutation(
        "remote-desktop-set-resolution-json-contract",
        "session-resolution",
        [
            "remote-desktop",
            "set-resolution",
            "--session-id",
            "session-resolution",
            "--resolution",
            "2056x1329",
            "--json",
        ],
    )?;
    assert_eq!(set_resolution_payload["accepted"], true);
    assert_eq!(set_resolution_payload["request_registered"], true);
    assert_eq!(set_resolution_payload["pending_agent_observation"], true);
    assert_eq!(set_resolution_payload["agent_observed"], false);
    assert_eq!(set_resolution_payload["applied"], false);
    assert_eq!(
        set_resolution_payload["request"]["action"],
        "set_resolution"
    );
    assert_eq!(
        set_resolution_payload["request"]["resolution"]["kind"],
        "preset"
    );
    assert_eq!(
        set_resolution_payload["request"]["resolution"]["id"],
        "2056x1329"
    );
    assert!(
        set_resolution_payload["request"]["fps"].is_null(),
        "set-resolution must not smuggle FPS into the request payload"
    );

    let set_fps_payload = run_remote_desktop_mutation(
        "remote-desktop-set-fps-json-contract",
        "session-fps",
        [
            "remote-desktop",
            "set-fps",
            "--session-id",
            "session-fps",
            "--fps",
            "120",
            "--json",
        ],
    )?;
    assert_eq!(set_fps_payload["accepted"], true);
    assert_eq!(set_fps_payload["request_registered"], true);
    assert_eq!(set_fps_payload["pending_agent_observation"], true);
    assert_eq!(set_fps_payload["agent_observed"], false);
    assert_eq!(set_fps_payload["applied"], false);
    assert_eq!(set_fps_payload["request"]["action"], "set_fps");
    assert_eq!(set_fps_payload["request"]["fps"], 120);
    assert!(
        set_fps_payload["request"]["resolution"].is_null(),
        "set-fps must not smuggle a resolution into the request payload"
    );

    let stop_payload = run_remote_desktop_mutation(
        "remote-desktop-stop-json-contract",
        "session-stop",
        [
            "remote-desktop",
            "stop",
            "--session-id",
            "session-stop",
            "--json",
        ],
    )?;
    assert_eq!(stop_payload["accepted"], true);
    assert_eq!(stop_payload["request_registered"], true);
    assert_eq!(stop_payload["pending_agent_observation"], true);
    assert_eq!(stop_payload["agent_observed"], false);
    assert_eq!(stop_payload["applied"], false);
    assert_eq!(stop_payload["request"]["action"], "stop");
    assert!(
        stop_payload["request"]["resolution"].is_null() && stop_payload["request"]["fps"].is_null(),
        "stop must not smuggle resolution or fps into the request payload"
    );

    let status = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &state_arg,
            "remote-desktop",
            "status",
            "--session-id",
            "session-1",
            "--json",
        ])
        .output()?;
    assert!(
        status.status.success(),
        "remote-desktop status should show pending request; stderr={}",
        String::from_utf8_lossy(&status.stderr)
    );
    let payload: Value = serde_json::from_slice(&status.stdout)?;
    assert_eq!(payload["live_control_status"], "pending_agent_observation");
    assert_eq!(payload["sessions"][0]["pending_agent_observation"], true);
    assert_eq!(payload["sessions"][0]["remote_identity_bound"], true);
    assert_eq!(
        payload["sessions"][0]["remote_display_name_available"],
        true
    );
    assert!(
        payload["sessions"][0]["remote_device_id"].is_null()
            && payload["sessions"][0]["remote_device_name"].is_null()
            && payload["sessions"][0]["remote_protocol_public_key_fingerprint"].is_null(),
        "remote desktop status public JSON must not expose peer identifiers"
    );
    assert_eq!(
        payload["sessions"][0]["pending_request"]["request_id"],
        live_start_request_id(&live_start.stdout)?
    );

    let duplicate_start = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &state_arg,
            "remote-desktop",
            "start",
            "--session-id",
            "session-1",
            "--resolution",
            "1920x1080",
            "--fps",
            "60",
            "--json",
        ])
        .output()?;
    assert!(
        !duplicate_start.status.success(),
        "duplicate pending request must fail closed"
    );
    assert!(
        duplicate_start.stdout.is_empty(),
        "duplicate pending request must not emit fake success to stdout"
    );
    let duplicate_stderr = String::from_utf8_lossy(&duplicate_start.stderr);
    assert!(
        duplicate_stderr.contains("\"code\": \"remote_desktop_request_rejected\"")
            && duplicate_stderr
                .contains("remote desktop request rejected before agent observation"),
        "duplicate failure should use stable redacted JSON and terminal error; stderr={duplicate_stderr}"
    );
    assert!(
        !duplicate_stderr.contains("fingerprint")
            && !duplicate_stderr.contains("remote-device")
            && !duplicate_stderr.contains("/"),
        "remote desktop request rejection must not leak peer identity or local paths; stderr={duplicate_stderr}"
    );

    let runtime = tokio::runtime::Runtime::new()?;
    let observed = runtime.block_on(async {
        let paths = resolve_paths(Some(state_dir.clone()))?;
        observe_remote_desktop_requests_for_established_session(&paths, "session-1").await
    })?;
    assert_eq!(observed.len(), 1);
    assert!(observed[0].is_agent_observed());
    assert!(!observed[0].is_pending_agent_observation());

    let observed_status = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &state_arg,
            "remote-desktop",
            "status",
            "--session-id",
            "session-1",
            "--json",
        ])
        .output()?;
    assert!(
        observed_status.status.success(),
        "remote-desktop status should show agent observe without live apply; stderr={}",
        String::from_utf8_lossy(&observed_status.stderr)
    );
    assert!(
        observed_status.stderr.is_empty(),
        "observed remote-desktop status must keep stderr clean: {}",
        String::from_utf8_lossy(&observed_status.stderr)
    );
    let payload: Value = serde_json::from_slice(&observed_status.stdout)?;
    assert_eq!(payload["live_control_status"], "agent_observed_not_applied");
    assert_eq!(payload["agent_observation_supported"], true);
    assert_eq!(payload["mutation_supported"], false);
    assert_eq!(
        payload["sessions"][0]["live_control_status"],
        "agent_observed_not_applied"
    );
    assert_eq!(payload["sessions"][0]["pending_agent_observation"], false);
    assert!(payload["sessions"][0]["pending_request"].is_null());
    assert_eq!(
        payload["sessions"][0]["latest_request"]["request_id"],
        live_start_request_id(&live_start.stdout)?
    );
    assert_eq!(
        payload["sessions"][0]["latest_request"]["status"],
        "agent_observed_not_applied"
    );
    assert_eq!(
        payload["sessions"][0]["latest_request"]["pending_agent_observation"],
        false
    );
    assert_eq!(
        payload["sessions"][0]["latest_request"]["agent_observed"],
        true
    );
    assert_eq!(payload["sessions"][0]["latest_request"]["applied"], false);
    assert_no_unevidenced_success_or_legacy_ack_terms(&observed_status.stdout);

    let invalid_state_dir = make_state_dir("remote-desktop-invalid-json-contract")?;
    let invalid_session_id = "/tmp/session-token-secret";
    let invalid_state_arg = invalid_state_dir.display().to_string();
    let invalid_fps = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &invalid_state_arg,
            "remote-desktop",
            "set-fps",
            "--session-id",
            invalid_session_id,
            "--fps",
            "75",
            "--json",
        ])
        .output()?;
    assert!(
        !invalid_fps.status.success(),
        "invalid remote desktop FPS must fail closed"
    );
    assert!(
        invalid_fps.stdout.is_empty(),
        "invalid remote desktop FPS must not emit fake success to stdout"
    );
    let invalid_fps_stderr = String::from_utf8_lossy(&invalid_fps.stderr);
    assert!(
        invalid_fps_stderr.contains("\"code\": \"remote_desktop_request_invalid\"")
            && invalid_fps_stderr.contains("\"request_registered\": false")
            && invalid_fps_stderr.contains("\"accepted\": false")
            && invalid_fps_stderr.contains("\"session_id_provided\": true")
            && invalid_fps_stderr.contains("\"pending_agent_observation\": false")
            && invalid_fps_stderr.contains("\"applied\": false")
            && invalid_fps_stderr.contains("remote_desktop.request_contract"),
        "invalid FPS failure should use stable request-contract JSON; stderr={invalid_fps_stderr}"
    );
    assert!(
        !invalid_fps_stderr.contains("fingerprint")
            && !invalid_fps_stderr.contains("remote-device")
            && !invalid_fps_stderr.contains("session-token-secret")
            && !invalid_fps_stderr.contains(&invalid_state_arg),
        "invalid FPS rejection must not leak peer identity or state paths; stderr={invalid_fps_stderr}"
    );

    let invalid_resolution = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &invalid_state_arg,
            "remote-desktop",
            "set-resolution",
            "--session-id",
            invalid_session_id,
            "--resolution",
            "../../remote-device-secret",
            "--json",
        ])
        .output()?;
    assert!(
        !invalid_resolution.status.success(),
        "invalid remote desktop resolution must fail closed"
    );
    assert!(
        invalid_resolution.stdout.is_empty(),
        "invalid remote desktop resolution must not emit fake success to stdout"
    );
    let invalid_resolution_stderr = String::from_utf8_lossy(&invalid_resolution.stderr);
    assert!(
        invalid_resolution_stderr.contains("\"code\": \"remote_desktop_request_invalid\"")
            && invalid_resolution_stderr.contains("\"action\": \"set_resolution\"")
            && invalid_resolution_stderr.contains("\"request_registered\": false")
            && invalid_resolution_stderr.contains("\"session_id_provided\": true")
            && invalid_resolution_stderr.contains("\"applied\": false"),
        "invalid resolution failure should use stable request-contract JSON; stderr={invalid_resolution_stderr}"
    );
    assert!(
        !invalid_resolution_stderr.contains("remote-device-secret")
            && !invalid_resolution_stderr.contains("../")
            && !invalid_resolution_stderr.contains("session-token-secret")
            && !invalid_resolution_stderr.contains(&invalid_state_arg),
        "invalid resolution rejection must not echo path-like user input or state paths; stderr={invalid_resolution_stderr}"
    );

    let invalid_paths = resolve_paths(Some(invalid_state_dir))?;
    assert!(
        !invalid_paths.remote_desktop_requests_file.exists(),
        "invalid remote desktop requests must fail before writing the pending request registry"
    );

    Ok(())
}

#[test]
fn nearby_discovery_json_contract_fails_closed_without_fake_empty_results()
-> Result<(), Box<dyn std::error::Error>> {
    let state_dir = make_state_dir("nearby-discovery-json-contract")?;
    let state_arg = state_dir.display().to_string();
    let output = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &state_arg,
            "device",
            "discover",
            "--nearby",
            "--json",
        ])
        .output()?;

    assert!(
        !output.status.success(),
        "device discover --nearby must remain fail-closed until an agent-owned discovery snapshot exists"
    );
    assert!(
        output.stdout.is_empty(),
        "failed JSON discovery must not emit fake empty results to stdout"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("\"capability_id\": \"device.discovery.nearby\"")
            && stderr.contains("\"accepted\": false")
            && stderr.contains("\"status\": \"planned\"")
            && stderr.contains("agent_owned_discovery_snapshot"),
        "nearby discovery failure should expose the planned contract and required gate; stderr={stderr}"
    );
    assert!(
        !stderr.contains("nearby-device-1") && !stderr.contains("MacBook.local"),
        "missing snapshot report must not leak fabricated nearby device details; stderr={stderr}"
    );

    let active_scan_output = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &state_arg,
            "device",
            "discover",
            "--nearby",
            "--scan",
            "--json",
        ])
        .output()?;
    assert!(
        !active_scan_output.status.success(),
        "active nearby scan must remain fail-closed until an agent-owned scanner exists"
    );
    assert!(
        active_scan_output.stdout.is_empty(),
        "failed active scan must not emit fake discovery results to stdout"
    );
    let active_scan_stderr = String::from_utf8_lossy(&active_scan_output.stderr);
    assert!(
        active_scan_stderr.contains("\"capability_id\": \"device.discovery.nearby\"")
            && active_scan_stderr.contains("\"accepted\": false")
            && active_scan_stderr.contains("\"status\": \"planned\"")
            && active_scan_stderr.contains("device_discovery_active_scan_snapshot_missing")
            && active_scan_stderr.contains("agent_owned_discovery_scanner"),
        "active scan failure should fail closed when no agent-owned scan snapshot exists; stderr={active_scan_stderr}"
    );
    assert!(
        !active_scan_stderr.contains("nearby-device-1")
            && !active_scan_stderr.contains("MacBook.local"),
        "active scan failure must not leak fabricated nearby device details; stderr={active_scan_stderr}"
    );

    let stale_state_dir = make_state_dir("nearby-discovery-stale-json-contract")?;
    seed_stale_nearby_discovery_snapshot(&stale_state_dir)?;
    let stale_state_arg = stale_state_dir.display().to_string();
    let stale_output = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &stale_state_arg,
            "device",
            "discover",
            "--nearby",
            "--json",
        ])
        .output()?;
    assert!(
        !stale_output.status.success(),
        "stale discovery snapshots must fail closed"
    );
    assert!(
        stale_output.stdout.is_empty(),
        "stale discovery snapshots must not emit stale devices to stdout"
    );
    let stale_stderr = String::from_utf8_lossy(&stale_output.stderr);
    assert!(
        stale_stderr.contains("\"status\": \"stale\"")
            && stale_stderr.contains("device_discovery_snapshot_stale"),
        "stale failure should be explicit; stderr={stale_stderr}"
    );
    assert!(
        !stale_stderr.contains("stale-device-1"),
        "stale failure must not leak stale device refs; stderr={stale_stderr}"
    );

    seed_nearby_discovery_snapshot(&state_dir)?;
    let output = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &state_arg,
            "device",
            "discover",
            "--nearby",
            "--json",
        ])
        .output()?;
    assert!(
        output.status.success(),
        "device discover --nearby should read a fresh agent-owned snapshot; stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        output.stderr.is_empty(),
        "successful nearby discovery snapshot report must keep stderr clean: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let payload: Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(payload["capability_id"], "device.discovery.nearby");
    assert_eq!(payload["accepted"], true);
    assert_eq!(payload["status"], "read_only");
    assert_eq!(payload["mutation_supported"], false);
    assert_eq!(payload["devices_returned"], 1);
    assert_eq!(payload["snapshot_authorizes_connection"], false);
    assert_eq!(payload["devices"][0]["device_ref"], "nearby-device-1");
    assert_eq!(payload["devices"][0]["display_name"], "Studio Mac");
    assert_eq!(payload["devices"][0]["endpoint_class"], "local_network");
    assert_eq!(
        payload["devices"][0]["trust_status"],
        "protocol_identity_verified"
    );
    assert_eq!(payload["devices"][0]["connectable"], true);
    assert_eq!(payload["devices"][0]["connection_authorized"], false);
    assert!(
        payload["required_gates_before_connect"]
            .as_array()
            .ok_or("required_gates_before_connect must be an array")?
            .iter()
            .any(|gate| gate == "session_handshake_gate")
    );

    let active_scan_state_dir = make_state_dir("nearby-discovery-active-scan-json-contract")?;
    seed_active_scan_snapshot(&active_scan_state_dir)?;
    let active_scan_state_arg = active_scan_state_dir.display().to_string();
    let active_scan_success = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .args([
            "--state-dir",
            &active_scan_state_arg,
            "device",
            "discover",
            "--nearby",
            "--scan",
            "--json",
        ])
        .output()?;
    assert!(
        active_scan_success.status.success(),
        "device discover --nearby --scan should read a fresh agent-owned active scan snapshot; stderr={}",
        String::from_utf8_lossy(&active_scan_success.stderr)
    );
    assert!(
        active_scan_success.stderr.is_empty(),
        "successful active scan report must keep stderr clean: {}",
        String::from_utf8_lossy(&active_scan_success.stderr)
    );
    let active_payload: Value = serde_json::from_slice(&active_scan_success.stdout)?;
    assert_eq!(active_payload["capability_id"], "device.discovery.nearby");
    assert_eq!(active_payload["accepted"], true);
    assert_eq!(active_payload["status"], "read_only");
    assert_eq!(active_payload["source"], "agent_owned_active_mdns_scan");
    assert_eq!(active_payload["devices_returned"], 1);
    assert_eq!(active_payload["snapshot_authorizes_connection"], false);
    assert_eq!(active_payload["devices"][0]["device_ref"], "id-active1");
    assert_eq!(active_payload["devices"][0]["connection_authorized"], false);

    Ok(())
}

fn capability_status<'a>(
    capabilities: &'a [Value],
    id: &str,
) -> Result<&'a str, Box<dyn std::error::Error>> {
    capabilities
        .iter()
        .find(|capability| capability["id"] == id)
        .and_then(|capability| capability["status"].as_str())
        .ok_or_else(|| format!("missing capability status for {id}").into())
}

fn capability_command<'a>(
    capabilities: &'a [Value],
    id: &str,
) -> Result<&'a str, Box<dyn std::error::Error>> {
    capabilities
        .iter()
        .find(|capability| capability["id"] == id)
        .and_then(|capability| capability["command"].as_str())
        .ok_or_else(|| format!("missing capability command for {id}").into())
}

fn capability_runtime_target<'a>(
    capabilities: &'a [Value],
    id: &str,
) -> Result<&'a str, Box<dyn std::error::Error>> {
    capabilities
        .iter()
        .find(|capability| capability["id"] == id)
        .and_then(|capability| capability["runtime_target"].as_str())
        .ok_or_else(|| format!("missing capability runtime target for {id}").into())
}

fn capability_control_effect<'a>(
    capabilities: &'a [Value],
    id: &str,
) -> Result<&'a str, Box<dyn std::error::Error>> {
    capabilities
        .iter()
        .find(|capability| capability["id"] == id)
        .and_then(|capability| capability["control_effect"].as_str())
        .ok_or_else(|| format!("missing capability control effect for {id}").into())
}

fn capability_verification_gate<'a>(
    capabilities: &'a [Value],
    id: &str,
) -> Result<&'a str, Box<dyn std::error::Error>> {
    capabilities
        .iter()
        .find(|capability| capability["id"] == id)
        .and_then(|capability| capability["verification_gate"].as_str())
        .ok_or_else(|| format!("missing capability verification gate for {id}").into())
}

fn capability_authority_boundary<'a>(
    capabilities: &'a [Value],
    id: &str,
) -> Result<&'a str, Box<dyn std::error::Error>> {
    capabilities
        .iter()
        .find(|capability| capability["id"] == id)
        .and_then(|capability| capability["authority_boundary"].as_str())
        .ok_or_else(|| format!("missing capability authority boundary for {id}").into())
}

fn make_state_dir(name: &str) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let path = std::env::temp_dir().join(format!(
        "skybridge-cli-{name}-{}-{nonce}",
        std::process::id()
    ));
    std::fs::create_dir_all(&path)?;
    Ok(path)
}

fn fixture_dir(parts: &[&str]) -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.push("tests");
    path.push("fixtures");
    for part in parts {
        path.push(part);
    }
    path
}

fn copy_fixture_dir(
    parts: &[&str],
    temp_name: &str,
) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let source = fixture_dir(parts);
    let destination = make_state_dir(temp_name)?;
    for entry in std::fs::read_dir(&source)? {
        let entry = entry?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        std::fs::copy(path, destination.join(entry.file_name()))?;
    }
    Ok(destination)
}

fn seed_established_session(
    state_dir: &Path,
    session_id: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async {
        let paths = resolve_paths(Some(state_dir.to_path_buf()))?;
        let mut record = RuntimeSessionRecord::new(
            format!("runtime-{session_id}"),
            session_id.to_owned(),
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "https://signal.example.com",
            "local-device",
            Some("remote-device".to_owned()),
            Some("Remote Device".to_owned()),
            Some("fingerprint".to_owned()),
            RuntimeSessionState::Bound,
        );
        let readiness = SessionReadiness::HandshakeComplete {
            session_id: session_id.to_owned(),
            negotiated_suite: "X-Wing".to_owned(),
        };
        record.readiness = readiness.clone();
        record.last_established_readiness = Some(readiness);
        upsert_session_runtime(&paths, record).await?;
        Ok::<(), anyhow::Error>(())
    })?;
    Ok(())
}

fn seed_capability_snapshot(
    state_dir: &Path,
    session_id: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async {
        let paths = resolve_paths(Some(state_dir.to_path_buf()))?;
        let snapshot = RemoteDesktopCapabilitySnapshot::new(
            session_id.to_owned(),
            format!("runtime-{session_id}"),
            vec![RemoteDesktopObservedMode::new(
                "1920x1080@60",
                1920,
                1080,
                60,
            )],
            vec![RemoteDesktopObservedMode::new(
                "display-main",
                2056,
                1329,
                60,
            )],
        );
        upsert_remote_desktop_capability_snapshot(&paths, snapshot).await?;
        Ok::<(), anyhow::Error>(())
    })?;
    Ok(())
}

fn seed_stale_capability_snapshot(
    state_dir: &Path,
    session_id: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async {
        let paths = resolve_paths(Some(state_dir.to_path_buf()))?;
        let observed_at = time::OffsetDateTime::now_utc() - time::Duration::seconds(600);
        let snapshot = RemoteDesktopCapabilitySnapshot {
            schema_version: RemoteDesktopCapabilitySnapshot::SCHEMA_VERSION,
            session_id: session_id.to_owned(),
            target_runtime_id: format!("runtime-{session_id}"),
            sender_modes: vec![RemoteDesktopObservedMode::new(
                "stale-secret-mode",
                1920,
                1080,
                60,
            )],
            display_modes: vec![],
            observed_at,
            expires_at: observed_at + time::Duration::seconds(60),
            updated_at: observed_at,
        };
        upsert_remote_desktop_capability_snapshot(&paths, snapshot).await?;
        Ok::<(), anyhow::Error>(())
    })?;
    Ok(())
}

fn seed_nearby_discovery_snapshot(state_dir: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async {
        let paths = resolve_paths(Some(state_dir.to_path_buf()))?;
        let snapshot = NearbyDiscoverySnapshot::new(
            "scan-1",
            "agent_owned_nearby_discovery_snapshot",
            vec![NearbyDiscoveredDevice::new(
                "nearby-device-1",
                "Studio Mac",
                NearbyDiscoveryEndpointClass::LocalNetwork,
                NearbyDiscoveryTrustStatus::ProtocolIdentityVerified,
                vec!["remote_desktop".to_owned(), "file_transfer".to_owned()],
                true,
            )],
            300,
        );
        upsert_nearby_discovery_snapshot(&paths, snapshot).await?;
        Ok::<(), anyhow::Error>(())
    })?;
    Ok(())
}

fn seed_active_scan_snapshot(state_dir: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async {
        let paths = resolve_paths(Some(state_dir.to_path_buf()))?;
        let snapshot = NearbyDiscoverySnapshot::new(
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
        );
        upsert_nearby_discovery_snapshot(&paths, snapshot).await?;
        Ok::<(), anyhow::Error>(())
    })?;
    Ok(())
}

fn seed_stale_nearby_discovery_snapshot(
    state_dir: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async {
        let paths = resolve_paths(Some(state_dir.to_path_buf()))?;
        let observed_at = time::OffsetDateTime::now_utc() - time::Duration::seconds(600);
        let snapshot = NearbyDiscoverySnapshot {
            schema_version: NearbyDiscoverySnapshot::SCHEMA_VERSION,
            scan_id: "scan-stale".to_owned(),
            source: "agent_owned_nearby_discovery_snapshot".to_owned(),
            devices: vec![NearbyDiscoveredDevice::new(
                "stale-device-1",
                "Stale Mac",
                NearbyDiscoveryEndpointClass::LocalNetwork,
                NearbyDiscoveryTrustStatus::Trusted,
                vec!["remote_desktop".to_owned()],
                true,
            )],
            observed_at,
            expires_at: observed_at + time::Duration::seconds(60),
            updated_at: observed_at,
        };
        upsert_nearby_discovery_snapshot(&paths, snapshot).await?;
        Ok::<(), anyhow::Error>(())
    })?;
    Ok(())
}

fn live_start_request_id(stdout: &[u8]) -> Result<Value, Box<dyn std::error::Error>> {
    let payload: Value = serde_json::from_slice(stdout)?;
    Ok(payload["request_id"].clone())
}

/// Honesty guardrail for *evidence-free* command outputs (request registration,
/// agent-observed-but-not-transferred history, live-control request/observe).
///
/// Policy: the guardrail forbids claiming success without evidence, not the
/// success vocabulary itself. Live transfers legitimately render
/// `receipt_verified: true` / `transfer_started: true` once the agent records a
/// SHA-256-verified receipt — those evidenced outputs are asserted separately.
/// The outputs passed here have, by construction, performed no transfer/apply,
/// so any success-true field would be an unevidenced claim, and the obsolete
/// `*_ack` vocabulary must never reappear.
fn assert_no_unevidenced_success_or_legacy_ack_terms(output: &[u8]) {
    let rendered = String::from_utf8_lossy(output);
    for forbidden in [
        "pending_agent_ack",
        "agent_acked",
        "request_acked",
        "request_ack_failed",
        "\"applied\": true",
        "\"transfer_started\": true",
        "\"transfer_completed\": true",
        "\"receipt_verified\": true",
        "\"receipt_sha256_match\": true",
        "\"mutation_supported\": true",
    ] {
        assert!(
            !rendered.contains(forbidden),
            "evidence-free public JSON must not claim success without evidence or render legacy ack terms `{forbidden}`: {rendered}"
        );
    }
}

fn run_remote_desktop_mutation<const N: usize>(
    state_name: &str,
    session_id: &str,
    args: [&str; N],
) -> Result<Value, Box<dyn std::error::Error>> {
    let state_dir = make_state_dir(state_name)?;
    seed_established_session(&state_dir, session_id)?;
    let state_arg = state_dir.display().to_string();
    let output = Command::new(env!("CARGO_BIN_EXE_skybridge"))
        .arg("--state-dir")
        .arg(&state_arg)
        .args(args)
        .output()?;
    assert!(
        output.status.success(),
        "remote desktop mutation should register a pending request; status={:?}; stderr={}",
        output.status.code(),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        output.stderr.is_empty(),
        "successful request registration must keep stderr clean: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(serde_json::from_slice(&output.stdout)?)
}
