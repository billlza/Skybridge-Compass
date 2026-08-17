//! Desktop-side client logic for the Android debug app's `adb-bridge/1`
//! read-only diagnostic surface.
//!
//! The Android app (debug builds only) hosts a localhost-scoped NDJSON server
//! on the abstract UNIX socket `skybridge-adb-bridge`, authenticated with a
//! per-boot random token the app writes into its private files directory. The
//! desktop CLI reaches it exclusively through `adb`:
//!
//! 1. `adb -s <serial> shell run-as <debug-package> cat files/debug-adb-bridge.json`
//!    reads the endpoint document (socket name + per-boot token).
//! 2. `adb -s <serial> forward tcp:0 localabstract:skybridge-adb-bridge`
//!    binds an ephemeral local TCP port to the in-app socket.
//! 3. One NDJSON request/response round trip over `127.0.0.1:<port>`.
//! 4. `adb -s <serial> forward --remove tcp:<port>` releases the forward.
//!
//! This module holds only pure logic — wire encode/decode, `adb` argument
//! construction, and output parsing — so its unit tests never execute a real
//! `adb` or open sockets. The process/socket side lives in
//! `android_commands.rs`.

use std::path::PathBuf;

use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};

/// Wire-protocol version of the `adb-bridge/1` contract.
pub(crate) const BRIDGE_PROTOCOL_VERSION: u64 = 1;

/// Protocol identifier the app writes into its endpoint document.
pub(crate) const BRIDGE_PROTOCOL_NAME: &str = "adb-bridge/1";

/// Abstract UNIX-domain socket name the Android debug app listens on.
pub(crate) const BRIDGE_ABSTRACT_SOCKET: &str = "skybridge-adb-bridge";

/// Endpoint document path relative to the debug app's private data directory
/// (the working directory `run-as <package>` starts in).
pub(crate) const BRIDGE_ENDPOINT_RELATIVE_PATH: &str = "files/debug-adb-bridge.json";

/// Default application id of the Android debug build hosting the bridge.
pub(crate) const DEFAULT_DEBUG_PACKAGE: &str = "com.skybridge.compass.debug";

/// Read-only methods the `adb-bridge/1` surface implements.
pub(crate) const BRIDGE_METHODS: &[&str] = &["status", "doctor", "lan", "code"];

/// Maximum accepted NDJSON response line, before the trailing newline.
pub(crate) const MAX_RESPONSE_LINE_BYTES: usize = 256 * 1024;

/// Parsed `adb devices -l` row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AdbDeviceEntry {
    pub(crate) serial: String,
    pub(crate) state: String,
    pub(crate) detail: String,
}

/// Endpoint document the debug app writes for `run-as` retrieval.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BridgeEndpoint {
    pub(crate) socket: String,
    pub(crate) token: String,
}

/// Validates an `adb -s` serial: non-empty, no whitespace or control bytes, so
/// a malformed value can never smuggle extra `adb` arguments or device-shell
/// words.
pub(crate) fn validate_serial(serial: &str) -> Result<()> {
    if serial.is_empty() {
        bail!("device serial is empty (code: serial_invalid)");
    }
    if serial
        .chars()
        .any(|character| character.is_whitespace() || character.is_control())
    {
        bail!(
            "device serial contains whitespace or control characters (code: serial_invalid)"
        );
    }
    Ok(())
}

/// Validates an Android application id before it is interpolated into a device
/// shell command (`adb shell run-as <package> …` re-parses through the device
/// shell, so the charset must stay inert there).
pub(crate) fn validate_package(package: &str) -> Result<()> {
    let segments: Vec<&str> = package.split('.').collect();
    if segments.len() < 2 {
        bail!(
            "Android package id must contain at least two dot-separated segments (code: package_invalid)"
        );
    }
    for segment in segments {
        let mut characters = segment.chars();
        let leading_ok = characters
            .next()
            .is_some_and(|first| first.is_ascii_alphabetic() || first == '_');
        if !leading_ok
            || !segment
                .chars()
                .all(|character| character.is_ascii_alphanumeric() || character == '_')
        {
            bail!(
                "Android package id contains characters outside [A-Za-z0-9_.] segments (code: package_invalid)"
            );
        }
    }
    Ok(())
}

/// Validates an abstract-socket name read back from the endpoint document
/// before it is embedded into an `adb forward` specification.
pub(crate) fn validate_socket_name(socket: &str) -> Result<()> {
    if socket.is_empty()
        || !socket.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-')
        })
    {
        bail!(
            "bridge socket name contains characters outside [A-Za-z0-9._-] (code: socket_invalid)"
        );
    }
    Ok(())
}

/// `adb devices -l` argument vector.
pub(crate) fn adb_devices_args() -> Vec<String> {
    vec!["devices".to_owned(), "-l".to_owned()]
}

/// Argument vector that reads the bridge endpoint document via `run-as`.
pub(crate) fn adb_endpoint_args(serial: &str, package: &str) -> Result<Vec<String>> {
    validate_serial(serial)?;
    validate_package(package)?;
    Ok(vec![
        "-s".to_owned(),
        serial.to_owned(),
        "shell".to_owned(),
        "run-as".to_owned(),
        package.to_owned(),
        "cat".to_owned(),
        BRIDGE_ENDPOINT_RELATIVE_PATH.to_owned(),
    ])
}

/// Argument vector that binds an ephemeral local TCP port to the in-app
/// abstract socket. `tcp:0` makes `adb` choose (and print) the local port.
pub(crate) fn adb_forward_args(serial: &str, socket: &str) -> Result<Vec<String>> {
    validate_serial(serial)?;
    validate_socket_name(socket)?;
    Ok(vec![
        "-s".to_owned(),
        serial.to_owned(),
        "forward".to_owned(),
        "tcp:0".to_owned(),
        format!("localabstract:{socket}"),
    ])
}

/// Argument vector that releases a previously established forward.
pub(crate) fn adb_forward_remove_args(serial: &str, local_port: u16) -> Result<Vec<String>> {
    validate_serial(serial)?;
    Ok(vec![
        "-s".to_owned(),
        serial.to_owned(),
        "forward".to_owned(),
        "--remove".to_owned(),
        format!("tcp:{local_port}"),
    ])
}

/// Parses the local port `adb forward tcp:0 …` prints on stdout.
pub(crate) fn parse_forward_local_port(stdout: &str) -> Result<u16> {
    let trimmed = stdout.trim();
    let port: u16 = trimmed.parse().map_err(|_| {
        anyhow!(
            "adb forward did not report a local port (got {trimmed:?}) (code: forward_port_unparsed)"
        )
    })?;
    if port == 0 {
        bail!("adb forward reported local port 0 (code: forward_port_unparsed)");
    }
    Ok(port)
}

/// Parses `adb devices -l` output into device rows, skipping the banner and
/// daemon-startup notices.
pub(crate) fn parse_adb_devices(stdout: &str) -> Vec<AdbDeviceEntry> {
    stdout
        .lines()
        .map(str::trim)
        .filter(|line| {
            !line.is_empty()
                && !line.starts_with("List of devices attached")
                && !line.starts_with('*')
        })
        .filter_map(|line| {
            let mut words = line.split_whitespace();
            let serial = words.next()?.to_owned();
            let state = words.next()?.to_owned();
            let detail = words.collect::<Vec<_>>().join(" ");
            Some(AdbDeviceEntry {
                serial,
                state,
                detail,
            })
        })
        .collect()
}

/// Chooses the target device: an explicit `--serial` must exist and be in the
/// `device` state; otherwise exactly one ready device may be attached.
pub(crate) fn resolve_target_serial(
    devices: &[AdbDeviceEntry],
    requested: Option<&str>,
) -> Result<String> {
    if let Some(serial) = requested {
        validate_serial(serial)?;
        let Some(entry) = devices.iter().find(|entry| entry.serial == serial) else {
            bail!("device {serial} is not attached (code: device_not_found)");
        };
        if entry.state != "device" {
            bail!(
                "device {serial} is attached but not ready (state: {}) (code: device_not_ready)",
                entry.state
            );
        }
        return Ok(entry.serial.clone());
    }

    let ready: Vec<&AdbDeviceEntry> = devices
        .iter()
        .filter(|entry| entry.state == "device")
        .collect();
    match ready.as_slice() {
        [] => bail!(
            "no Android device is attached in the `device` state; connect one and authorize USB debugging (code: device_required)"
        ),
        [only] => Ok(only.serial.clone()),
        many => {
            let serials = many
                .iter()
                .map(|entry| entry.serial.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            bail!(
                "multiple Android devices are attached ({serials}); pick one with --serial (code: device_ambiguous)"
            );
        }
    }
}

/// Ordered `adb` executable candidates. Absolute SDK locations come first;
/// the bare executable name last so `PATH` resolution stays the fallback.
pub(crate) fn adb_candidates(
    explicit: Option<PathBuf>,
    android_home: Option<PathBuf>,
    android_sdk_root: Option<PathBuf>,
    windows: bool,
) -> Vec<PathBuf> {
    if let Some(path) = explicit {
        return vec![path];
    }
    let executable = if windows { "adb.exe" } else { "adb" };
    let mut candidates = Vec::new();
    for sdk in [android_home, android_sdk_root].into_iter().flatten() {
        candidates.push(sdk.join("platform-tools").join(executable));
    }
    candidates.push(PathBuf::from(executable));
    candidates
}

/// Parses the endpoint document read via `run-as`, rejecting anything that is
/// not a current-protocol bridge endpoint. Token bytes never appear in errors.
pub(crate) fn parse_endpoint_document(raw: &str) -> Result<BridgeEndpoint> {
    let value: Value = serde_json::from_str(raw.trim()).map_err(|_| {
        anyhow!(
            "bridge endpoint document is not valid JSON; launch the SkyBridge debug app once so it can publish its per-boot endpoint (code: endpoint_unreadable)"
        )
    })?;
    let proto = value.get("proto").and_then(Value::as_str).unwrap_or("");
    if proto != BRIDGE_PROTOCOL_NAME {
        bail!(
            "bridge endpoint document reports protocol {proto:?}, expected {BRIDGE_PROTOCOL_NAME:?} (code: endpoint_protocol_mismatch)"
        );
    }
    let socket = match value.get("socket").and_then(Value::as_str).map(str::trim) {
        Some(socket) if !socket.is_empty() => socket.to_owned(),
        // The socket field is advisory; absent means the canonical name.
        _ => BRIDGE_ABSTRACT_SOCKET.to_owned(),
    };
    let token = value
        .get("token")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_owned();
    if token.len() < 16 {
        bail!(
            "bridge endpoint document omits a usable per-boot token (code: endpoint_token_missing)"
        );
    }
    Ok(BridgeEndpoint { socket, token })
}

/// Encodes one `adb-bridge/1` request line (newline-terminated NDJSON).
pub(crate) fn build_bridge_request(id: &str, token: &str, method: &str) -> Result<String> {
    if !BRIDGE_METHODS.contains(&method) {
        bail!("unsupported adb-bridge method {method:?} (code: method_unsupported)");
    }
    let mut line = serde_json::to_string(&json!({
        "v": BRIDGE_PROTOCOL_VERSION,
        "id": id,
        "token": token,
        "method": method,
        "params": {},
    }))
    .context("encode adb-bridge request")?;
    line.push('\n');
    Ok(line)
}

/// Decodes one `adb-bridge/1` response line into the `result` object, bailing
/// with the server-declared error code/message on `ok:false`.
pub(crate) fn decode_bridge_response(expected_id: &str, line: &str) -> Result<Value> {
    let value: Value = serde_json::from_str(line.trim())
        .map_err(|_| anyhow!("adb-bridge response is not valid JSON (code: response_unparsed)"))?;
    let version = value.get("v").and_then(Value::as_u64).unwrap_or(0);
    if version != BRIDGE_PROTOCOL_VERSION {
        bail!(
            "adb-bridge protocol mismatch: client v{BRIDGE_PROTOCOL_VERSION} server v{version} (code: protocol_version_mismatch)"
        );
    }
    let id = value.get("id").and_then(Value::as_str).unwrap_or("");
    if id != expected_id {
        bail!("adb-bridge response id does not match the request (code: response_id_mismatch)");
    }
    let Some(ok) = value.get("ok").and_then(Value::as_bool) else {
        bail!("adb-bridge response is missing the boolean `ok` field (code: response_unparsed)");
    };
    if ok {
        return value
            .get("result")
            .cloned()
            .ok_or_else(|| anyhow!("adb-bridge ok response omitted `result` (code: response_unparsed)"));
    }
    let error = value.get("error").cloned().unwrap_or(Value::Null);
    let code = error
        .get("code")
        .and_then(Value::as_str)
        .unwrap_or("bridge_error");
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("the Android debug bridge rejected the request");
    bail!("{message} (code: {code})");
}

/// Process-unique request id; the bridge echoes it so a response can never be
/// attributed to the wrong request on a reused forward.
pub(crate) fn next_request_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    format!("cli-{}-{nanos}", std::process::id())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_args_target_run_as_cat_of_the_endpoint_document() {
        let args = adb_endpoint_args("R5CT1234", "com.skybridge.compass.debug")
            .expect("valid serial/package should build args");
        assert_eq!(
            args,
            vec![
                "-s",
                "R5CT1234",
                "shell",
                "run-as",
                "com.skybridge.compass.debug",
                "cat",
                "files/debug-adb-bridge.json",
            ]
        );
    }

    #[test]
    fn forward_args_bind_ephemeral_tcp_to_the_abstract_socket() {
        let args = adb_forward_args("emulator-5554", BRIDGE_ABSTRACT_SOCKET)
            .expect("valid serial should build args");
        assert_eq!(
            args,
            vec![
                "-s",
                "emulator-5554",
                "forward",
                "tcp:0",
                "localabstract:skybridge-adb-bridge",
            ]
        );
        let removal = adb_forward_remove_args("emulator-5554", 41_222)
            .expect("valid serial should build removal args");
        assert_eq!(
            removal,
            vec!["-s", "emulator-5554", "forward", "--remove", "tcp:41222"]
        );
        assert!(adb_forward_args("emulator-5554", "evil socket").is_err());
        assert!(adb_forward_args("emulator-5554", "").is_err());
    }

    #[test]
    fn serial_and_package_validation_reject_shell_metacharacters() {
        assert!(validate_serial("").is_err());
        assert!(validate_serial("serial with space").is_err());
        assert!(validate_serial("tab\tserial").is_err());
        assert!(validate_serial("R5CT1234").is_ok());

        assert!(validate_package("com.skybridge.compass.debug").is_ok());
        assert!(validate_package("singleword").is_err());
        assert!(validate_package("com.sky;rm").is_err());
        assert!(validate_package("com.sky bridge").is_err());
        assert!(validate_package("com.1leading").is_err());
        assert!(adb_endpoint_args("ok", "com.sky;rm -rf").is_err());
    }

    #[test]
    fn forward_port_parsing_accepts_adb_stdout_and_rejects_garbage() {
        assert_eq!(
            parse_forward_local_port("41533\n").expect("plain port should parse"),
            41_533
        );
        assert!(parse_forward_local_port("").is_err());
        assert!(parse_forward_local_port("0").is_err());
        assert!(parse_forward_local_port("error: device offline").is_err());
    }

    #[test]
    fn adb_devices_parsing_skips_banner_and_daemon_lines() {
        let stdout = "* daemon not running; starting now at tcp:5037\n\
                      * daemon started successfully\n\
                      List of devices attached\n\
                      R5CT1234       device usb:1-1 product:e3q model:SM_S948U device:e3q transport_id:2\n\
                      emulator-5554  offline\n\n";
        let devices = parse_adb_devices(stdout);
        assert_eq!(devices.len(), 2);
        assert_eq!(devices[0].serial, "R5CT1234");
        assert_eq!(devices[0].state, "device");
        assert!(devices[0].detail.contains("model:SM_S948U"));
        assert_eq!(devices[1].serial, "emulator-5554");
        assert_eq!(devices[1].state, "offline");
        assert_eq!(devices[1].detail, "");
    }

    #[test]
    fn target_serial_resolution_requires_exactly_one_ready_device() {
        let ready = AdbDeviceEntry {
            serial: "A".to_owned(),
            state: "device".to_owned(),
            detail: String::new(),
        };
        let offline = AdbDeviceEntry {
            serial: "B".to_owned(),
            state: "offline".to_owned(),
            detail: String::new(),
        };
        let second_ready = AdbDeviceEntry {
            serial: "C".to_owned(),
            state: "device".to_owned(),
            detail: String::new(),
        };

        assert_eq!(
            resolve_target_serial(std::slice::from_ref(&ready), None)
                .expect("single ready device should resolve"),
            "A"
        );
        let no_ready = resolve_target_serial(std::slice::from_ref(&offline), None)
            .expect_err("offline-only should fail");
        assert!(no_ready.to_string().contains("device_required"));
        let ambiguous = resolve_target_serial(&[ready.clone(), second_ready], None)
            .expect_err("two ready devices should fail");
        assert!(ambiguous.to_string().contains("device_ambiguous"));
        let missing = resolve_target_serial(std::slice::from_ref(&ready), Some("Z"))
            .expect_err("unknown serial should fail");
        assert!(missing.to_string().contains("device_not_found"));
        let not_ready = resolve_target_serial(&[offline], Some("B"))
            .expect_err("offline serial should fail");
        assert!(not_ready.to_string().contains("device_not_ready"));
    }

    #[test]
    fn adb_candidates_prefer_explicit_then_sdk_env_then_path() {
        let explicit = adb_candidates(
            Some(PathBuf::from("/custom/adb")),
            Some(PathBuf::from("/sdk-home")),
            None,
            false,
        );
        assert_eq!(explicit, vec![PathBuf::from("/custom/adb")]);

        let from_env = adb_candidates(
            None,
            Some(PathBuf::from("/sdk-home")),
            Some(PathBuf::from("/sdk-root")),
            false,
        );
        assert_eq!(
            from_env,
            vec![
                PathBuf::from("/sdk-home/platform-tools/adb"),
                PathBuf::from("/sdk-root/platform-tools/adb"),
                PathBuf::from("adb"),
            ]
        );

        let windows = adb_candidates(None, Some(PathBuf::from("C:/sdk")), None, true);
        assert_eq!(
            windows,
            vec![
                PathBuf::from("C:/sdk/platform-tools/adb.exe"),
                PathBuf::from("adb.exe"),
            ]
        );
    }

    #[test]
    fn endpoint_document_parsing_validates_protocol_socket_and_token() {
        let endpoint = parse_endpoint_document(
            r#"{"v":1,"proto":"adb-bridge/1","socket":"skybridge-adb-bridge","token":"0123456789abcdef0123"}"#,
        )
        .expect("well-formed endpoint should parse");
        assert_eq!(endpoint.socket, "skybridge-adb-bridge");
        assert_eq!(endpoint.token, "0123456789abcdef0123");

        assert!(parse_endpoint_document("run-as: package not debuggable").is_err());
        let defaulted = parse_endpoint_document(
            r#"{"proto":"adb-bridge/1","token":"0123456789abcdef0123"}"#,
        )
        .expect("missing socket field should fall back to the canonical name");
        assert_eq!(defaulted.socket, BRIDGE_ABSTRACT_SOCKET);
        let wrong_proto = parse_endpoint_document(
            r#"{"proto":"other/9","socket":"s","token":"0123456789abcdef0123"}"#,
        )
        .expect_err("wrong protocol must be rejected");
        assert!(wrong_proto.to_string().contains("endpoint_protocol_mismatch"));
        let short_token =
            parse_endpoint_document(r#"{"proto":"adb-bridge/1","socket":"s","token":"short"}"#)
                .expect_err("short token must be rejected");
        assert!(short_token.to_string().contains("endpoint_token_missing"));
        assert!(!short_token.to_string().contains("short"));
    }

    #[test]
    fn bridge_request_encoding_carries_version_token_and_method() {
        let line = build_bridge_request("req-1", "token-0123456789abcdef", "status")
            .expect("status request should encode");
        assert!(line.ends_with('\n'));
        let value: Value = serde_json::from_str(line.trim()).expect("request must be JSON");
        assert_eq!(value["v"], 1);
        assert_eq!(value["id"], "req-1");
        assert_eq!(value["token"], "token-0123456789abcdef");
        assert_eq!(value["method"], "status");
        assert!(value["params"].is_object());

        assert!(build_bridge_request("req-1", "token", "reboot").is_err());
    }

    #[test]
    fn bridge_response_decoding_returns_result_and_surfaces_server_errors() {
        let ok = decode_bridge_response(
            "req-1",
            r#"{"v":1,"id":"req-1","ok":true,"result":{"versionName":"1.0.2-debug"}}"#,
        )
        .expect("ok response should decode");
        assert_eq!(ok["versionName"], "1.0.2-debug");

        let unauthorized = decode_bridge_response(
            "req-1",
            r#"{"v":1,"id":"req-1","ok":false,"error":{"code":"unauthorized","message":"token mismatch"}}"#,
        )
        .expect_err("server error must surface");
        let text = unauthorized.to_string();
        assert!(text.contains("unauthorized"), "{text}");
        assert!(text.contains("token mismatch"), "{text}");

        let wrong_id =
            decode_bridge_response("req-1", r#"{"v":1,"id":"other","ok":true,"result":{}}"#)
                .expect_err("mismatched id must fail");
        assert!(wrong_id.to_string().contains("response_id_mismatch"));

        let wrong_version =
            decode_bridge_response("req-1", r#"{"v":2,"id":"req-1","ok":true,"result":{}}"#)
                .expect_err("mismatched version must fail");
        assert!(
            wrong_version
                .to_string()
                .contains("protocol_version_mismatch")
        );

        assert!(decode_bridge_response("req-1", "garbage").is_err());
        assert!(
            decode_bridge_response("req-1", r#"{"v":1,"id":"req-1","ok":true}"#).is_err()
        );
    }

    #[test]
    fn request_ids_are_distinct_across_calls() {
        assert_ne!(next_request_id(), next_request_id());
    }
}
