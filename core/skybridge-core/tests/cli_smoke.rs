use sha2::{Digest, Sha256};
use std::process::Command;

const WEBRTC_PROOF_FINGERPRINT: &str =
    "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

fn sha256_hex_for_test(value: &str) -> String {
    let digest = Sha256::digest(value.as_bytes());
    let mut hex = String::with_capacity(64);
    for byte in digest {
        use std::fmt::Write as _;
        write!(&mut hex, "{byte:02x}").unwrap();
    }
    hex
}

fn skybridge() -> Command {
    Command::new(env!("CARGO_BIN_EXE_skybridge"))
}

fn write_webrtc_proof_fixture(file_name: &str, sbf1_echo_verified: bool) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "skybridge-cli-smoke-webrtc-proof-{}-{file_name}.json",
        std::process::id()
    ));
    let captured_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis();
    let proof = format!(
        r#"{{
  "helperName": "schema-smoke-webrtc-helper",
  "peerDeviceId": "mac-1",
  "peerPublicKeyFingerprint": "{WEBRTC_PROOF_FINGERPRINT}",
  "dataChannelOpen": true,
  "sbf1EchoVerified": {sbf1_echo_verified},
  "sbf1FrameMagic": "SBF1",
  "adapterBinding": "verified webrtc datachannel helper",
  "localEndpoint": "windows.lan:5443",
  "remoteEndpoint": "mac.lan:5443",
  "selectedCandidatePair": "webrtc/dtls/sctp/helper-selected",
  "transportSecretFingerprintHex": "6666666666666666666666666666666666666666666666666666666666666666",
  "capabilityDigestHex": "7777777777777777777777777777777777777777777777777777777777777777",
  "relayId": "relay-helper",
  "timestampWindowMs": 15000,
  "capturedAtUnixMs": {captured_at}
}}"#
    );
    std::fs::write(&path, proof).unwrap();
    path
}

fn write_product_control_evidence_fixture(
    file_name: &str,
    secret_inputs_captured: bool,
) -> std::path::PathBuf {
    write_product_control_evidence_fixture_for_session(
        file_name,
        secret_inputs_captured,
        "session-secret",
        "peer-device-1",
    )
}

fn write_product_control_evidence_fixture_for_session(
    file_name: &str,
    secret_inputs_captured: bool,
    session_id: &str,
    remote_device_id: &str,
) -> std::path::PathBuf {
    let dir = std::env::current_dir()
        .unwrap()
        .join("target")
        .join("test-fixtures");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(format!(
        "skybridge-cli-smoke-product-control-evidence-{}-{file_name}.json",
        std::process::id()
    ));
    let session_id_sha256 = sha256_hex_for_test(session_id);
    let remote_device_id_sha256 = sha256_hex_for_test(remote_device_id);
    let proof = format!(
        r#"{{
  "EvidenceVersion": 1,
  "Profile": "current-path-product-control-appcontrol",
  "EvidenceScope": "AdmissionLookupBoundSdpIceProductControlHandshakeAppControlPong",
  "Status": "appControlPong",
  "Steps": {{
    "AdmissionChallenge": true,
    "AdmissionLease": true,
    "LookupCode": true,
    "SignalingBound": true,
    "ProductControlTransport": true,
    "ProductHandshake": true,
    "AppControlPingPong": true
  }},
  "HeaderValuesCaptured": false,
  "SecretInputsCaptured": {secret_inputs_captured},
  "ConnectionCodeCaptured": false,
  "QueryTokenPresent": false,
  "Bound": true,
  "Role": "offer",
  "SignalingExchangeRole": "offerer",
  "HelperMode": "product-control-offer",
  "RemoteSignalWaitType": "answer",
  "RemoteIdentitySource": "connectionCodeLookup",
  "RemoteIdentityServerAttested": true,
  "NotRemoteIdentityProof": false,
  "SecureSessionState": "Established",
  "DataChannelLabel": "skybridge",
  "SessionIdSha256": "{session_id_sha256}",
  "RemoteDeviceIdSha256": "{remote_device_id_sha256}",
  "RemoteProtocolPublicKeyFingerprint": "{WEBRTC_PROOF_FINGERPRINT}",
  "LateRemoteIceCandidateRelayCount": 0,
  "ProductSendCount": 1,
  "ProductReceiveCount": 1,
  "NotHandshakeProof": false,
  "NotAppControlProof": false,
  "NegotiatedSuiteWireId": "0x0101",
  "PolicyRequirePqc": true,
  "PolicyAllowClassicFallback": false,
  "ResponderIdentityFingerprintVerified": true,
  "ResponderSignatureVerified": true,
  "ResponderFinishedVerified": true,
  "InitiatorFinishedSent": true,
  "AppControlPacketType": "AppControl",
  "AppControlCryptoFormat": "SkybridgeSecureEnvelopeV1",
  "AppControlPayloadFormat": "SkybridgeSecureEnvelopeV1",
  "AppControlSbwcEnvelope": true,
  "AppControlSbwcCounterPresent": true,
  "AppControlReplayProtection": "sbwc-replay-window",
  "AuthenticatedAppControlPingPongProof": true,
  "AppControlReceivedMessageKind": "pong",
  "AppControlPongIdMatches": true,
  "AppControlOutboundCounter": 1,
  "AppControlInboundCounter": 1,
  "AppControlSessionHash": "session-hash",
  "AppControlTranscriptPrefix": "transcript-prefix",
  "PeerMlKem768PublicKeyCaptured": false,
  "PeerMlKem768PublicKeySource": "operatorProvidedOutOfBand",
  "PeerMlKem768PublicKeyServerAttested": false,
  "RemoteProductAppObserved": false,
  "PeerTrustPersistenceProof": false,
  "NotMacProductAppProof": true,
  "RecordedAt": "2026-07-06T00:00:00.0000000Z"
}}"#
    );
    std::fs::write(&path, proof).unwrap();
    path
}

fn write_product_control_evidence_variant(
    file_name: &str,
    session_id: &str,
    remote_device_id: &str,
    mutate: impl FnOnce(&mut serde_json::Value),
) -> std::path::PathBuf {
    let path = write_product_control_evidence_fixture_for_session(
        file_name,
        false,
        session_id,
        remote_device_id,
    );
    let mut evidence: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    mutate(&mut evidence);
    std::fs::write(&path, serde_json::to_vec_pretty(&evidence).unwrap()).unwrap();
    path
}

fn make_operator_state_dir(name: &str) -> std::path::PathBuf {
    let dir = std::env::current_dir()
        .unwrap()
        .join("target")
        .join("test-fixtures")
        .join(format!(
            "skybridge-cli-smoke-operator-state-{}-{name}",
            std::process::id()
        ));
    if dir.exists() {
        std::fs::remove_dir_all(&dir).unwrap();
    }
    std::fs::create_dir_all(dir.join("runtime")).unwrap();
    dir
}

fn write_remote_desktop_session_registry(
    state_dir: &std::path::Path,
    session_id: &str,
    session_state: &str,
) {
    let session_registry = format!(
        r#"{{
  "schema_version": 1,
  "sessions": {{
    "{session_id}": {{
      "schema_version": 1,
      "session_id": "{session_id}",
      "target_runtime_id": "windows-runtime-1",
      "remote_device_id": "peer-device-1",
      "remote_protocol_public_key_fingerprint": "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
      "state": "{session_state}",
      "secure_session_state": "Established",
      "readiness": {{
        "kind": "product_control_secure_session"
      }},
      "created_at_unix_ms": 1783296000000,
      "updated_at_unix_ms": 1783296000000,
      "expires_at_unix_ms": 4102444800000
    }}
  }}
}}"#
    );
    std::fs::write(
        state_dir.join("runtime").join("sessions.json"),
        session_registry,
    )
    .unwrap();
}

fn write_connection_code_snapshot_fixture(
    file_name: &str,
    code: &str,
    session_id: &str,
    expires_at: &str,
) -> std::path::PathBuf {
    let dir = std::env::current_dir()
        .unwrap()
        .join("target")
        .join("test-fixtures")
        .join(format!(
            "skybridge-cli-smoke-code-snapshot-{}",
            std::process::id()
        ));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(file_name);
    let snapshot = format!(
        r#"{{
  "schemaVersion": 1,
  "code": "{code}",
  "sessionId": "{session_id}",
  "expiresAt": "{expires_at}",
  "leaseMode": "short",
  "deviceId": "windows-device-1",
  "protocolPublicKeyFingerprint": "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
  "generatedAt": "2026-07-06T00:00:00Z"
}}"#
    );
    std::fs::write(&path, snapshot).unwrap();
    path
}

struct NearbyDiscoveryFixture<'a> {
    scan_id: &'a str,
    source: &'a str,
    observed_at: &'a str,
    expires_at: &'a str,
    updated_at: &'a str,
    device_ref: &'a str,
    display_name: &'a str,
    trust_status: &'a str,
    connectable: bool,
}

fn write_nearby_discovery_snapshot_registry(
    state_dir: &std::path::Path,
    fixture: NearbyDiscoveryFixture<'_>,
) {
    let NearbyDiscoveryFixture {
        scan_id,
        source,
        observed_at,
        expires_at,
        updated_at,
        device_ref,
        display_name,
        trust_status,
        connectable,
    } = fixture;
    let registry = format!(
        r#"{{
  "schema_version": 1,
  "snapshots": {{
    "{scan_id}": {{
      "schema_version": 1,
      "scan_id": "{scan_id}",
      "source": "{source}",
      "devices": [
        {{
          "device_ref": "{device_ref}",
          "display_name": "{display_name}",
          "endpoint_class": "local_network",
          "trust_status": "{trust_status}",
          "capabilities": ["remote_desktop", "file_transfer"],
          "connectable": {connectable}
        }}
      ],
      "observed_at": "{observed_at}",
      "expires_at": "{expires_at}",
      "updated_at": "{updated_at}"
    }}
  }}
}}"#
    );
    std::fs::write(
        state_dir
            .join("runtime")
            .join("nearby-discovery-snapshots.json"),
        registry,
    )
    .unwrap();
}

fn write_file_transfer_source_fixture(file_name: &str) -> std::path::PathBuf {
    let dir = std::env::current_dir()
        .unwrap()
        .join("target")
        .join("test-fixtures");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(format!(
        "skybridge-cli-smoke-file-transfer-source-{}-{file_name}.txt",
        std::process::id()
    ));
    std::fs::write(&path, b"skybridge file transfer request fixture\n").unwrap();
    path
}

#[test]
fn cli_help_smoke() {
    let output = skybridge().arg("--help").output().expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("SkyBridge CLI"));
    assert!(stdout.contains("skybridge capabilities [--json]"));
    assert!(stdout.contains("skybridge device discover --nearby"));
    assert!(stdout.contains("skybridge file send"));
    assert!(stdout.contains("skybridge evidence status --evidence"));
    assert!(stdout.contains("skybridge remote-desktop start"));
    assert!(stdout.contains("skybridge pqc status [--json]"));
    assert!(stdout.contains("skybridge session ls"));
    assert!(stdout.contains("transport select"));
}

#[test]
fn cli_no_args_prints_help_smoke() {
    let output = skybridge().output().expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("USAGE:"));
    assert!(stdout.contains("version [--json]"));
    assert!(stdout.contains("capabilities [--json]"));
    assert!(stdout.contains("device discover --nearby"));
    assert!(stdout.contains("evidence status --evidence"));
    assert!(stdout.contains("remote-desktop contract"));
    assert!(stdout.contains("pqc status [--json]"));
    assert!(stdout.contains("session ls"));
    assert!(stdout.contains("connection plan"));
    assert!(stdout.contains("discovery parse"));
    assert!(stdout.contains("webrtc-proof validate"));
}

#[test]
fn cli_capabilities_reports_skybridge_cli_surface() {
    let output = skybridge()
        .args(["capabilities", "--json"])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("capabilities JSON should parse");
    assert_eq!(payload["schema_version"], 1);
    assert_eq!(payload["contracts_schema_version"], 1);
    assert_eq!(payload["product_name"], "SkyBridge CLI");
    assert_eq!(payload["binary_name"], "skybridge");
    assert_eq!(payload["platform"], "windows");
    assert_eq!(payload["surface"], "windows_protocol_diagnostic");
    assert_eq!(
        payload["operator_command_parity"],
        "discovery_snapshot_remote_desktop_and_file_transfer_request_registries_available_windows_agent_observation_required"
    );
    assert_eq!(payload["mac_gui_control_protocol"], "crossnet-control/1");
    assert_eq!(payload["mac_gui_control_supported"], false);
    assert_eq!(payload["ios_runtime_control_supported"], false);

    let capabilities = payload["capabilities"]
        .as_array()
        .expect("capabilities array");
    assert!(
        !capabilities.is_empty(),
        "capabilities output must not be empty"
    );
    let find_capability = |id: &str| {
        capabilities
            .iter()
            .find(|capability| capability["id"] == id)
            .unwrap_or_else(|| panic!("missing capability {id}: {stdout}"))
    };

    let discovery = find_capability("device.discovery.nearby");
    assert_eq!(discovery["status"], "read_only_state_dir_supported");
    assert_eq!(
        discovery["control_effect"],
        "agent_snapshot_read_only_projection"
    );
    assert_eq!(
        discovery["proof_state"],
        "discovery_snapshot_projected_not_connect_authorization"
    );
    assert!(discovery["command"]
        .as_str()
        .unwrap()
        .contains("device discover"));

    let crossnet = find_capability("crossnet.connect");
    assert_eq!(crossnet["status"], "planned_fail_closed");
    assert_eq!(crossnet["runtime_target"], "mac_app_runtime");
    assert_eq!(crossnet["control_effect"], "mac_mutation_not_enabled");

    let transport = find_capability("current_path.product_control.transport");
    assert_eq!(transport["status"], "external_live_gate");
    let transport_proof = transport["proof_state"].as_str().unwrap();
    assert!(transport_proof.contains("NotHandshakeProof"));
    assert!(transport_proof.contains("NotAppControlProof"));
    assert!(transport_proof.contains("NotMacProductAppProof"));

    let appcontrol = find_capability("current_path.product_control.appcontrol");
    assert_eq!(appcontrol["status"], "external_live_gate");
    let appcontrol_boundary = appcontrol["authority_boundary"].as_str().unwrap();
    assert!(appcontrol_boundary.contains("ML-DSA"));
    assert!(appcontrol_boundary.contains("ML-KEM"));
    assert!(appcontrol_boundary.contains("does not prove Mac product app observation"));
    assert!(appcontrol_boundary.contains("persisted peer trust"));

    let pqc = find_capability("pqc.handshake");
    assert_eq!(pqc["status"], "read_only_diagnostic");
    assert_eq!(
        pqc["proof_state"],
        "suite_negotiation_diagnostic_not_handshake_proof"
    );
}

#[test]
fn cli_code_and_disconnect_commands_fail_closed_without_secret_leak() {
    let output = skybridge().args(["--help"]).output().expect("run cli");
    assert!(output.status.success());
    let help = String::from_utf8(output.stdout).unwrap();
    assert!(help.contains("skybridge code create"));
    assert!(help.contains("skybridge code current"));
    assert!(help.contains("skybridge disconnect"));

    let secret_name = "studio-secret-device";
    let output = skybridge()
        .args([
            "code",
            "create",
            "--device-name",
            secret_name,
            "--ttl-seconds",
            "300",
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(!stderr.contains(secret_name));
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("code create JSON should parse");
    assert_eq!(payload["capability_id"], "native.code.create");
    assert_eq!(payload["status"], "planned_fail_closed");
    assert_eq!(payload["code_created"], false);
    assert_eq!(payload["mutation_supported"], false);

    let secret_session = "session-secret";
    let output = skybridge()
        .args(["disconnect", secret_session, "--json"])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(!stderr.contains(secret_session));
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("disconnect JSON should parse");
    assert_eq!(payload["capability_id"], "session.disconnect");
    assert_eq!(payload["status"], "planned_fail_closed");
    assert_eq!(payload["session_disconnected"], false);
}

#[test]
fn cli_code_current_reads_snapshot_without_raw_code_or_path_leak() {
    let secret_code = "SB-SECRET-CODE";
    let secret_session = "SESSION-SECRET";
    let snapshot = write_connection_code_snapshot_fixture(
        "connection-code-latest.json",
        secret_code,
        secret_session,
        "2099-01-01T00:00:00Z",
    );
    let snapshot_string = snapshot.to_string_lossy().to_string();

    let output = skybridge()
        .args(["code", "current", "--snapshot", &snapshot_string, "--json"])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(!stdout.contains(secret_code));
    assert!(!stdout.contains(secret_session));
    assert!(!stdout.contains(&snapshot_string));
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("code current JSON should parse");
    assert_eq!(payload["capability_id"], "native.code.current");
    assert_eq!(payload["status"], "snapshot_available");
    assert_eq!(payload["code_present"], true);
    assert!(payload["code_ref"].as_str().unwrap().starts_with("code-"));
    assert_eq!(payload["session_id_present"], true);
    assert_eq!(payload["expired"], false);
    assert_eq!(payload["mutation_supported"], false);
    assert_eq!(payload["live_runtime_started"], false);
    assert_eq!(
        payload["proof_boundary"]["raw_connection_code_redacted"],
        true
    );
}

#[test]
fn cli_code_current_rejects_expired_snapshot_without_secret_leak() {
    let secret_code = "SB-OLD-SECRET";
    let secret_session = "SESSION-OLD-SECRET";
    let snapshot = write_connection_code_snapshot_fixture(
        "expired-connection-code.json",
        secret_code,
        secret_session,
        "2000-01-01T00:00:00Z",
    );
    let snapshot_string = snapshot.to_string_lossy().to_string();

    let output = skybridge()
        .args(["code", "current", "--snapshot", &snapshot_string, "--json"])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(!stderr.contains(secret_code));
    assert!(!stderr.contains(secret_session));
    assert!(!stderr.contains(&snapshot_string));
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("code current error JSON should parse");
    assert_eq!(payload["capability_id"], "native.code.current");
    assert_eq!(payload["error"]["code"], "connection_code_snapshot_expired");
    assert_eq!(payload["retryable"], false);
}

#[test]
fn cli_capabilities_quantifies_remaining_operator_gaps() {
    let output = skybridge()
        .args(["capabilities", "--json"])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("capabilities JSON should parse");
    let gaps = payload["operator_gap_summary"]
        .as_array()
        .expect("operator_gap_summary array");
    assert!(!gaps.is_empty(), "operator gap summary must not be empty");

    let find_gap = |capability_id: &str| {
        gaps.iter()
            .find(|gap| gap["capability_id"] == capability_id)
            .unwrap_or_else(|| panic!("missing gap summary for {capability_id}: {stdout}"))
    };

    for capability_id in [
        "device.discovery.nearby",
        "native.connect",
        "pqc.handshake",
        "file.transfer.send",
        "remote_desktop.start",
    ] {
        let gap = find_gap(capability_id);
        assert_eq!(
            gap["live_proven"], false,
            "{capability_id} must not overclaim live proof"
        );
        assert!(gap["command"].as_str().unwrap().starts_with("skybridge "));
        assert!(!gap["current_state"].as_str().unwrap().is_empty());
        assert!(gap["proven_gates"].as_array().is_some());
        assert!(
            !gap["missing_gates"].as_array().unwrap().is_empty(),
            "{capability_id} must expose missing gates"
        );
        assert!(!gap["next_verification"].as_str().unwrap().is_empty());
    }

    let discovery = find_gap("device.discovery.nearby");
    assert_eq!(discovery["current_state"], "read_only_snapshot_projection");
    assert!(discovery["proven_gates"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!(
            "fresh_agent_owned_discovery_snapshot_projection"
        )));
    assert!(discovery["missing_gates"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!("native_dns_sd_require_peer_gate")));

    let pqc = find_gap("pqc.handshake");
    assert_eq!(pqc["current_state"], "suite_negotiation_diagnostic_only");
    assert!(pqc["proven_gates"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!("pqc_suite_policy_available")));
    for missing_gate in [
        "verified_peer_protocol_identity",
        "ml_dsa_signed_handshake",
        "ml_kem_or_xwing_session_keys",
        "sbwc_secure_session_established",
    ] {
        assert!(
            pqc["missing_gates"]
                .as_array()
                .unwrap()
                .contains(&serde_json::json!(missing_gate)),
            "pqc gap must include {missing_gate}: {stdout}"
        );
    }
}

#[test]
fn cli_device_discover_state_dir_returns_fresh_snapshot_read_only() {
    let state_dir = make_operator_state_dir("discovery-snapshot");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    write_nearby_discovery_snapshot_registry(
        &state_dir,
        NearbyDiscoveryFixture {
            scan_id: "scan-1",
            source: "agent_owned_nearby_discovery_snapshot",
            observed_at: "2026-07-06T00:00:00Z",
            expires_at: "2099-01-01T00:00:00Z",
            updated_at: "2026-07-06T00:00:01Z",
            device_ref: "nearby-device-1",
            display_name: "Studio Mac",
            trust_status: "protocol_identity_verified",
            connectable: true,
        },
    );

    let output = skybridge()
        .args([
            "device",
            "discover",
            "--nearby",
            "--state-dir",
            &state_dir_string,
            "--json",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(!stdout.contains(&state_dir_string));
    assert!(!stdout.contains("nearby-discovery-snapshots.json"));
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("device discovery JSON should parse");
    assert_eq!(payload["capability_id"], "device.discovery.nearby");
    assert_eq!(payload["accepted"], true);
    assert_eq!(payload["status"], "read_only");
    assert_eq!(payload["nearby_requested"], true);
    assert_eq!(payload["active_scan_requested"], false);
    assert_eq!(payload["active_scan_started"], false);
    assert_eq!(payload["mutation_supported"], false);
    assert_eq!(payload["devices_returned"], 1);
    assert_eq!(payload["snapshot_authorizes_connection"], false);
    assert_eq!(payload["proof_boundary"]["snapshot_projected"], true);
    assert_eq!(payload["session_created"], false);
    assert_eq!(payload["connect_supported"], false);
    assert_eq!(payload["devices"][0]["device_ref"], "nearby-device-1");
    assert_eq!(payload["devices"][0]["display_name"], "Studio Mac");
    assert_eq!(
        payload["devices"][0]["trust_status"],
        "protocol_identity_verified"
    );
    assert_eq!(payload["devices"][0]["connectable"], true);
    assert_eq!(payload["devices"][0]["connection_authorized"], false);
}

#[test]
fn cli_device_discover_scan_state_dir_reads_active_scan_snapshot_without_starting_scan() {
    let state_dir = make_operator_state_dir("discovery-active-scan");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    write_nearby_discovery_snapshot_registry(
        &state_dir,
        NearbyDiscoveryFixture {
            scan_id: "scan-active",
            source: "agent_owned_active_mdns_scan",
            observed_at: "2026-07-06T00:00:00Z",
            expires_at: "2099-01-01T00:00:00Z",
            updated_at: "2026-07-06T00:00:01Z",
            device_ref: "active-device-1",
            display_name: "Office Mac",
            trust_status: "trusted",
            connectable: true,
        },
    );

    let output = skybridge()
        .args([
            "device",
            "discover",
            "--nearby",
            "--scan",
            "--state-dir",
            &state_dir_string,
            "--json",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(!stdout.contains(&state_dir_string));
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("active discovery JSON should parse");
    assert_eq!(payload["accepted"], true);
    assert_eq!(payload["active_scan_requested"], true);
    assert_eq!(payload["active_scan_started"], false);
    assert_eq!(payload["source"], "agent_owned_active_mdns_scan");
    assert_eq!(payload["proof_boundary"]["active_scan_started"], false);
    assert_eq!(payload["devices_returned"], 1);
    assert_eq!(payload["devices"][0]["device_ref"], "active-device-1");
    assert_eq!(payload["devices"][0]["connection_authorized"], false);
    assert_eq!(payload["snapshot_authorizes_connection"], false);
}

#[test]
fn cli_device_discover_state_dir_errors_are_redacted_and_classified() {
    let missing = make_operator_state_dir("discovery-missing-registry");
    let missing_string = missing.to_string_lossy().to_string();
    let output = skybridge()
        .args([
            "device",
            "discover",
            "--nearby",
            "--state-dir",
            &missing_string,
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(!stderr.contains(&missing_string));
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("missing discovery JSON should parse");
    assert_eq!(
        payload["error"]["code"],
        "device_discovery_snapshot_missing"
    );
    assert_eq!(payload["accepted"], false);
    assert_eq!(payload["devices_returned"], 0);

    let stale = make_operator_state_dir("discovery-stale");
    let stale_string = stale.to_string_lossy().to_string();
    write_nearby_discovery_snapshot_registry(
        &stale,
        NearbyDiscoveryFixture {
            scan_id: "scan-stale",
            source: "agent_owned_nearby_discovery_snapshot",
            observed_at: "1999-12-31T23:59:58Z",
            expires_at: "2000-01-01T00:00:00Z",
            updated_at: "1999-12-31T23:59:59Z",
            device_ref: "stale-secret-device",
            display_name: "Stale Mac",
            trust_status: "trusted",
            connectable: true,
        },
    );
    let output = skybridge()
        .args([
            "device",
            "discover",
            "--nearby",
            "--state-dir",
            &stale_string,
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(!stderr.contains(&stale_string));
    assert!(!stderr.contains("stale-secret-device"));
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("stale discovery JSON should parse");
    assert_eq!(payload["error"]["code"], "device_discovery_snapshot_stale");
    assert_eq!(payload["error"]["retryable"], true);

    let corrupt = make_operator_state_dir("discovery-corrupt");
    let corrupt_string = corrupt.to_string_lossy().to_string();
    std::fs::write(
        corrupt
            .join("runtime")
            .join("nearby-discovery-snapshots.json"),
        "{not-json secret-device-ref}",
    )
    .unwrap();
    let output = skybridge()
        .args([
            "device",
            "discover",
            "--nearby",
            "--state-dir",
            &corrupt_string,
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(!stderr.contains(&corrupt_string));
    assert!(!stderr.contains("secret-device-ref"));
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("corrupt discovery JSON should parse");
    assert_eq!(
        payload["error"]["code"],
        "device_discovery_snapshot_registry_invalid"
    );
}

#[test]
fn cli_device_discover_rejects_strict_argument_matrix() {
    let cases: &[(&[&str], &str)] = &[
        (
            &["device", "discover", "--json"],
            "device_discovery_nearby_required",
        ),
        (
            &["device", "discover", "--nearby", "--json"],
            "device_discovery_snapshot_missing",
        ),
        (
            &["device", "discover", "--json", "--json"],
            "device_discovery_duplicate_option",
        ),
        (
            &["device", "discover", "--nearby", "--nearby", "--json"],
            "device_discovery_duplicate_option",
        ),
        (
            &["device", "discover", "--scan", "--scan", "--json"],
            "device_discovery_duplicate_option",
        ),
        (
            &[
                "device",
                "discover",
                "--state-dir",
                "secret-state-dir",
                "--state-dir",
                "other-secret-state-dir",
                "--json",
            ],
            "device_discovery_duplicate_option",
        ),
        (
            &["device", "discover", "--nearby", "--json", "--state-dir"],
            "device_discovery_state_dir_missing",
        ),
        (
            &["device", "discover", "--nearby", "--state-dir", "--json"],
            "device_discovery_state_dir_missing",
        ),
        (
            &["device", "discover", "--nearby", "--unsupported", "--json"],
            "device_discovery_unknown_option",
        ),
        (
            &[
                "device",
                "discover",
                "--nearby",
                "secret-positional-device",
                "--json",
            ],
            "device_discovery_unexpected_argument",
        ),
    ];

    for (args, expected_code) in cases {
        let output = skybridge().args(*args).output().expect("run cli");

        assert!(!output.status.success(), "args={args:?}");
        assert!(output.stdout.is_empty(), "args={args:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        for secret in [
            "secret-state-dir",
            "other-secret-state-dir",
            "secret-positional-device",
        ] {
            assert!(!stderr.contains(secret), "args={args:?} leaked {secret}");
        }
        let payload: serde_json::Value =
            serde_json::from_str(stderr.trim()).expect("device error JSON should parse");
        assert_eq!(payload["capability_id"], "device.discovery.nearby");
        assert_eq!(payload["accepted"], false);
        assert_eq!(payload["devices_returned"], 0);
        assert_eq!(payload["snapshot_authorizes_connection"], false);
        assert_eq!(payload["error"]["code"], *expected_code, "args={args:?}");
    }
}

#[test]
fn cli_operator_commands_fail_closed_without_live_success_claims() {
    let output = skybridge()
        .args(["device", "discover", "--nearby", "--scan", "--json"])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("device failure JSON should parse");
    assert_eq!(payload["capability_id"], "device.discovery.nearby");
    assert_eq!(payload["accepted"], false);
    assert_eq!(payload["devices_returned"], 0);
    assert_eq!(payload["snapshot_authorizes_connection"], false);

    let secret_path = "/Users/bill/private/payload.bin";
    let secret_peer = "peer-secret";
    let secret_session = "session-secret";
    let output = skybridge()
        .args([
            "file",
            "send",
            secret_path,
            "--to",
            secret_peer,
            "--session-id",
            secret_session,
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    for secret in [secret_path, secret_peer, secret_session] {
        assert!(
            !stderr.contains(secret),
            "file send failure leaked {secret}: {stderr}"
        );
    }
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("file send failure JSON should parse");
    assert_eq!(payload["capability_id"], "file.transfer.send");
    assert_eq!(payload["request_registered"], false);
    assert_eq!(payload["receipt_verified"], false);

    let output = skybridge()
        .args([
            "remote-desktop",
            "start",
            "--session-id",
            secret_session,
            "--resolution",
            "1920x1080",
            "--fps",
            "60",
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(!stderr.contains(secret_session));
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("remote desktop failure JSON should parse");
    assert_eq!(payload["capability_id"], "remote_desktop.start");
    assert_eq!(payload["request_registered"], false);
    assert_eq!(payload["pending_agent_observation"], false);
    assert_eq!(payload["applied"], false);
}

#[test]
fn cli_remote_desktop_registers_pending_request_for_established_session_registry() {
    let state_dir = make_operator_state_dir("remote-desktop-start");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    let secret_session = "session-secret";
    write_remote_desktop_session_registry(&state_dir, secret_session, "established");

    let output = skybridge()
        .args([
            "remote-desktop",
            "start",
            "--state-dir",
            &state_dir_string,
            "--session-id",
            secret_session,
            "--resolution",
            "1920x1080",
            "--fps",
            "60",
            "--json",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(!stdout.contains(secret_session));
    assert!(!stdout.contains(&state_dir_string));
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("remote desktop request JSON should parse");
    assert_eq!(payload["capability_id"], "remote_desktop.start");
    assert_eq!(payload["accepted"], true);
    assert_eq!(payload["status"], "request_registered");
    assert_eq!(payload["request_registry_supported"], true);
    assert_eq!(payload["request_registered"], true);
    assert_eq!(payload["pending_agent_observation"], true);
    assert_eq!(payload["agent_observed"], false);
    assert_eq!(payload["applied"], false);
    assert_eq!(payload["remote_desktop"]["proven"], false);
    assert_eq!(payload["session_id_provided"], true);
    assert_eq!(payload["resolution_provided"], true);
    assert_eq!(payload["fps_provided"], true);
    assert_eq!(payload["request"]["action"], "start");
    assert_eq!(payload["request"]["status"], "pending_agent_observation");
    assert_eq!(payload["request"]["resolution"], "1920x1080");
    assert_eq!(payload["request"]["fps"], 60);

    let request_registry_path = state_dir
        .join("runtime")
        .join("remote-desktop-requests.json");
    let request_registry = std::fs::read_to_string(request_registry_path).unwrap();
    let registry: serde_json::Value =
        serde_json::from_str(&request_registry).expect("request registry JSON should parse");
    let requests = registry["requests"].as_object().expect("requests map");
    assert_eq!(requests.len(), 1);
    let stored_request = requests.values().next().unwrap();
    assert_eq!(stored_request["session_id"], secret_session);
    assert_eq!(stored_request["target_runtime_id"], "windows-runtime-1");
    assert_eq!(stored_request["action"], "start");
    assert_eq!(stored_request["status"], "pending_agent_observation");

    let output = skybridge()
        .args([
            "remote-desktop",
            "status",
            "--state-dir",
            &state_dir_string,
            "--session-id",
            secret_session,
            "--json",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(!stdout.contains(secret_session));
    assert!(!stdout.contains(&state_dir_string));
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("remote desktop status JSON should parse");
    assert_eq!(
        payload["live_control_status"],
        "request_registry_pending_agent_observation"
    );
    assert_eq!(payload["request_registry_supported"], true);
    assert_eq!(payload["pending_requests"], 1);
    assert_eq!(payload["latest_request"]["action"], "start");
    assert_eq!(
        payload["latest_request"]["status"],
        "pending_agent_observation"
    );
    assert_eq!(payload["remote_desktop"]["proven"], false);
}

#[test]
fn cli_remote_desktop_rejects_non_established_registry_without_secret_leak() {
    let state_dir = make_operator_state_dir("remote-desktop-not-established");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    let secret_session = "session-secret";
    write_remote_desktop_session_registry(&state_dir, secret_session, "connecting");

    let output = skybridge()
        .args([
            "remote-desktop",
            "start",
            "--state-dir",
            &state_dir_string,
            "--session-id",
            secret_session,
            "--resolution",
            "1920x1080",
            "--fps",
            "60",
            "--json",
        ])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(!stderr.contains(secret_session));
    assert!(!stderr.contains(&state_dir_string));
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("remote desktop failure JSON should parse");
    assert_eq!(payload["capability_id"], "remote_desktop.start");
    assert_eq!(payload["accepted"], false);
    assert_eq!(payload["request_registered"], false);
    assert_eq!(payload["pending_agent_observation"], false);
    assert_eq!(
        payload["error"]["code"],
        "remote_desktop_session_not_established"
    );
}

#[test]
fn cli_file_transfer_registers_pending_send_request_for_established_session_registry() {
    let state_dir = make_operator_state_dir("file-transfer-send");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    let secret_session = "session-secret";
    let destination_peer = "peer-device-1";
    write_remote_desktop_session_registry(&state_dir, secret_session, "established");
    let source_path = write_file_transfer_source_fixture("register");
    let source_path_string = source_path.to_string_lossy().to_string();
    let source_size = std::fs::metadata(&source_path).unwrap().len();

    let output = skybridge()
        .args([
            "file",
            "send",
            "--state-dir",
            &state_dir_string,
            &source_path_string,
            "--to",
            destination_peer,
            "--session-id",
            secret_session,
            "--json",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    for secret in [
        &source_path_string,
        destination_peer,
        secret_session,
        &state_dir_string,
    ] {
        assert!(
            !stdout.contains(secret),
            "file send success leaked {secret}: {stdout}"
        );
    }
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("file transfer request JSON should parse");
    assert_eq!(payload["capability_id"], "file.transfer.send");
    assert_eq!(payload["accepted"], true);
    assert_eq!(payload["status"], "request_registered");
    assert_eq!(payload["request_registry_supported"], true);
    assert_eq!(payload["file_transfer_request_registry_supported"], true);
    assert_eq!(payload["request_registered"], true);
    assert_eq!(payload["pending_agent_observation"], true);
    assert_eq!(payload["agent_observed"], false);
    assert_eq!(payload["transfer_started"], false);
    assert_eq!(payload["receipt_verified"], false);
    assert_eq!(payload["file_transfer"]["proven"], false);
    assert_eq!(
        payload["proof_boundary"]["request_registered_not_live_transfer"],
        true
    );
    assert_eq!(
        payload["proof_boundary"]["file_sha256_receipt_proof"],
        false
    );
    assert!(payload["file_transfer"]["missing_gates"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!("file_sha256_receipt")));
    assert_eq!(payload["source_path_provided"], true);
    assert_eq!(payload["destination_peer_provided"], true);
    assert_eq!(payload["session_id_provided"], true);
    assert_eq!(payload["source_snapshot_recorded"], true);
    assert_eq!(payload["request"]["action"], "send");
    assert_eq!(payload["request"]["status"], "pending_agent_observation");
    assert_eq!(payload["request"]["transfer_started"], false);
    assert_eq!(payload["request"]["receipt_verified"], false);

    let request_registry_path = state_dir
        .join("runtime")
        .join("file-transfer-requests.json");
    let request_registry = std::fs::read_to_string(request_registry_path).unwrap();
    let registry: serde_json::Value =
        serde_json::from_str(&request_registry).expect("file transfer registry JSON should parse");
    let requests = registry["requests"].as_object().expect("requests map");
    assert_eq!(requests.len(), 1);
    let stored_request = requests.values().next().unwrap();
    assert_eq!(stored_request["session_id"], secret_session);
    assert_eq!(stored_request["target_runtime_id"], "windows-runtime-1");
    assert_eq!(stored_request["action"], "send");
    assert_eq!(stored_request["status"], "pending_agent_observation");
    assert_eq!(stored_request["source"]["source_path"], source_path_string);
    assert_eq!(stored_request["source"]["size_bytes"], source_size);
    assert_eq!(
        stored_request["destination"]["requested_peer_ref"],
        destination_peer
    );
    assert_eq!(
        stored_request["destination"]["remote_device_id"],
        destination_peer
    );
    assert_eq!(
        stored_request["source"]["sha256_hex"]
            .as_str()
            .unwrap()
            .len(),
        64
    );

    let output = skybridge()
        .args([
            "file",
            "history",
            "--state-dir",
            &state_dir_string,
            "--session-id",
            secret_session,
            "--json",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    for secret in [
        &source_path_string,
        destination_peer,
        secret_session,
        &state_dir_string,
    ] {
        assert!(
            !stdout.contains(secret),
            "file history leaked {secret}: {stdout}"
        );
    }
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("file history JSON should parse");
    assert_eq!(payload["status"], "request_history");
    assert_eq!(payload["history_supported"], true);
    assert_eq!(payload["file_transfer_request_registry_supported"], true);
    assert_eq!(payload["live_transfer_history_supported"], false);
    assert_eq!(payload["pending_requests"], 1);
    assert_eq!(payload["history"][0]["action"], "send");
    assert_eq!(payload["history"][0]["status"], "pending_agent_observation");
    assert_eq!(payload["history"][0]["transfer_started"], false);
    assert_eq!(payload["history"][0]["receipt_verified"], false);
    assert_eq!(payload["file_transfer"]["proven"], false);
}

#[test]
fn cli_session_ls_projects_agent_owned_session_registry_without_secret_leak() {
    let state_dir = make_operator_state_dir("session-ls");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    let secret_session = "session-secret";
    write_remote_desktop_session_registry(&state_dir, secret_session, "established");

    let output = skybridge()
        .args(["session", "ls", "--state-dir", &state_dir_string, "--json"])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(!stdout.contains(secret_session));
    assert!(!stdout.contains(&state_dir_string));
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("session ls JSON should parse");
    assert_eq!(payload["capability_id"], "session.ls");
    assert_eq!(payload["status"], "session_inventory");
    assert_eq!(payload["session_registry_supported"], true);
    assert_eq!(payload["mutation_supported"], false);
    assert_eq!(payload["live_runtime_started"], false);
    assert_eq!(
        payload["proof_boundary"]["session_inventory_not_live_runtime_proof"],
        true
    );
    assert_eq!(payload["sessions_total"], 1);
    assert_eq!(payload["proof_boundary"]["raw_session_ids_redacted"], true);
    let sessions = payload["sessions"].as_array().expect("sessions array");
    assert_eq!(sessions.len(), 1);
    let session = &sessions[0];
    assert!(session["session_ref"]
        .as_str()
        .unwrap()
        .starts_with("session-"));
    assert_eq!(session["session_id_present"], true);
    assert_eq!(session["state"], "established");
    assert_eq!(session["secure_session_state"], "Established");
    assert_eq!(session["readiness_kind"], "product_control_secure_session");
    assert_eq!(session["product_control_secure_session_ready"], true);
    assert_eq!(session["expired"], false);
    assert_eq!(session["remote_identity_bound"], true);
}

#[test]
fn cli_session_inspect_projects_single_session_without_secret_leak() {
    let state_dir = make_operator_state_dir("session-inspect");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    let secret_session = "session-secret";
    write_remote_desktop_session_registry(&state_dir, secret_session, "established");

    let output = skybridge()
        .args([
            "session",
            "inspect",
            "--state-dir",
            &state_dir_string,
            secret_session,
            "--json",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(!stdout.contains(secret_session));
    assert!(!stdout.contains(&state_dir_string));
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("session inspect JSON should parse");
    assert_eq!(payload["capability_id"], "session.inspect");
    assert_eq!(payload["status"], "session_found");
    assert_eq!(payload["session_found"], true);
    assert_eq!(payload["session"]["session_id_present"], true);
    assert_eq!(
        payload["session"]["product_control_secure_session_ready"],
        true
    );
}

#[test]
fn cli_session_inspect_errors_are_redacted_and_classified() {
    let state_dir = make_operator_state_dir("session-inspect-missing");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    write_remote_desktop_session_registry(&state_dir, "other-session", "established");

    let output = skybridge()
        .args([
            "session",
            "inspect",
            "--state-dir",
            &state_dir_string,
            "session-secret",
            "--json",
        ])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(!stderr.contains("session-secret"));
    assert!(!stderr.contains(&state_dir_string));
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("session failure JSON should parse");
    assert_eq!(payload["capability_id"], "session.inspect");
    assert_eq!(payload["session_found"], false);
    assert_eq!(payload["error"]["code"], "session_not_found");
    assert_eq!(payload["error"]["retryable"], false);
}

#[test]
fn cli_session_import_product_control_writes_authority_for_request_registries() {
    let state_dir = make_operator_state_dir("session-import-product-control");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    let secret_session = "session-secret";
    let destination_peer = "peer-device-1";
    let evidence = write_product_control_evidence_fixture_for_session(
        "session-import",
        false,
        secret_session,
        destination_peer,
    );
    let evidence_string = evidence.to_string_lossy().to_string();
    let session_id_file = state_dir.join("runtime").join("session-id.txt");
    std::fs::write(&session_id_file, format!("{secret_session}\n")).unwrap();
    let session_id_file_string = session_id_file.to_string_lossy().to_string();

    let output = skybridge()
        .args([
            "session",
            "import-product-control",
            "--state-dir",
            &state_dir_string,
            "--evidence",
            &evidence_string,
            "--session-id-file",
            &session_id_file_string,
            "--remote-device-id",
            destination_peer,
            "--target-runtime-id",
            "windows-runtime-1",
            "--ttl-seconds",
            "3600",
            "--json",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    for secret in [
        secret_session,
        destination_peer,
        &state_dir_string,
        &evidence_string,
        &session_id_file_string,
    ] {
        assert!(
            !stdout.contains(secret),
            "session import leaked {secret}: {stdout}"
        );
    }
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("session import JSON should parse");
    assert_eq!(payload["capability_id"], "session.import_product_control");
    assert_eq!(payload["accepted"], true);
    assert_eq!(payload["session_imported"], true);
    assert_eq!(payload["inserted"], true);
    assert_eq!(payload["live_runtime_started"], false);
    assert_eq!(payload["session_id_file_used"], true);
    assert_eq!(
        payload["session"]["product_control_secure_session_ready"],
        true
    );
    assert_eq!(
        payload["proof_boundary"]["session_import_not_live_runtime_start"],
        true
    );
    assert_eq!(
        payload["proof_boundary"]["request_registered_not_live_transfer"],
        true
    );
    assert_eq!(
        payload["proof_boundary"]["request_registered_not_live_remote_apply"],
        true
    );

    let source_path = write_file_transfer_source_fixture("import-downstream");
    let source_path_string = source_path.to_string_lossy().to_string();
    let output = skybridge()
        .args([
            "file",
            "send",
            "--state-dir",
            &state_dir_string,
            &source_path_string,
            "--to",
            destination_peer,
            "--session-id",
            secret_session,
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(!stdout.contains(secret_session));
    assert!(!stdout.contains(destination_peer));
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("file request JSON should parse");
    assert_eq!(payload["request_registered"], true);
    assert_eq!(payload["file_transfer"]["proven"], false);

    let remote_state = make_operator_state_dir("session-import-product-control-remote");
    let remote_state_string = remote_state.to_string_lossy().to_string();
    let evidence = write_product_control_evidence_fixture_for_session(
        "session-import-remote",
        false,
        secret_session,
        destination_peer,
    );
    let evidence_string = evidence.to_string_lossy().to_string();
    let import = skybridge()
        .args([
            "session",
            "import-product-control",
            "--state-dir",
            &remote_state_string,
            "--evidence",
            &evidence_string,
            "--session-id",
            secret_session,
            "--remote-device-id",
            destination_peer,
            "--target-runtime-id",
            "windows-runtime-1",
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(import.status.success());

    let output = skybridge()
        .args([
            "remote-desktop",
            "start",
            "--state-dir",
            &remote_state_string,
            "--session-id",
            secret_session,
            "--resolution",
            "1920x1080",
            "--fps",
            "60",
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(!stdout.contains(secret_session));
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("remote desktop request JSON should parse");
    assert_eq!(payload["request_registered"], true);
    assert_eq!(payload["remote_desktop"]["proven"], false);
    assert_eq!(payload["applied"], false);
}

#[test]
fn cli_session_import_product_control_rejects_hash_mismatch_without_mutation() {
    let state_dir = make_operator_state_dir("session-import-hash-mismatch");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    let evidence = write_product_control_evidence_fixture_for_session(
        "hash-mismatch",
        false,
        "session-secret",
        "peer-device-1",
    );
    let evidence_string = evidence.to_string_lossy().to_string();
    let wrong_session = "wrong-session-secret";

    let output = skybridge()
        .args([
            "session",
            "import-product-control",
            "--state-dir",
            &state_dir_string,
            "--evidence",
            &evidence_string,
            "--session-id",
            wrong_session,
            "--remote-device-id",
            "peer-device-1",
            "--json",
        ])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    for secret in [
        wrong_session,
        "peer-device-1",
        &state_dir_string,
        &evidence_string,
    ] {
        assert!(
            !stderr.contains(secret),
            "session import failure leaked {secret}: {stderr}"
        );
    }
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("session import failure JSON should parse");
    assert_eq!(
        payload["error"]["code"],
        "session_import_session_hash_mismatch"
    );
    assert_eq!(payload["session_imported"], false);
    assert!(!state_dir.join("runtime").join("sessions.json").exists());
}

#[test]
fn cli_session_import_product_control_rejects_ambiguous_session_id_sources() {
    let state_dir = make_operator_state_dir("session-import-ambiguous-session-id");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    let secret_session = "session-secret";
    let destination_peer = "peer-device-1";
    let evidence = write_product_control_evidence_fixture_for_session(
        "ambiguous-session-id",
        false,
        secret_session,
        destination_peer,
    );
    let evidence_string = evidence.to_string_lossy().to_string();
    let session_id_file = state_dir.join("runtime").join("session-id.txt");
    std::fs::write(&session_id_file, secret_session).unwrap();
    let session_id_file_string = session_id_file.to_string_lossy().to_string();

    let output = skybridge()
        .args([
            "session",
            "import-product-control",
            "--state-dir",
            &state_dir_string,
            "--evidence",
            &evidence_string,
            "--session-id",
            secret_session,
            "--session-id-file",
            &session_id_file_string,
            "--remote-device-id",
            destination_peer,
            "--json",
        ])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    for secret in [
        secret_session,
        destination_peer,
        &state_dir_string,
        &evidence_string,
        &session_id_file_string,
    ] {
        assert!(
            !stderr.contains(secret),
            "session import failure leaked {secret}: {stderr}"
        );
    }
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("session import failure JSON should parse");
    assert_eq!(
        payload["error"]["code"],
        "session_import_session_id_ambiguous"
    );
    assert_eq!(payload["session_imported"], false);
    assert!(!state_dir.join("runtime").join("sessions.json").exists());
}

#[test]
fn cli_session_import_rejects_request_and_secret_file_boundaries() {
    let state_dir = make_operator_state_dir("session-import-boundaries");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    let secret_session = "secret-import-session";
    let secret_peer = "secret-import-peer";
    let evidence = write_product_control_evidence_fixture_for_session(
        "session-import-boundaries",
        false,
        secret_session,
        secret_peer,
    );
    let evidence_string = evidence.to_string_lossy().to_string();
    let session_registry = state_dir.join("runtime").join("sessions.json");

    let required_cases = vec![
        (
            vec![
                "session".to_string(),
                "import-product-control".to_string(),
                "--json".to_string(),
            ],
            "session_import_state_dir_required",
        ),
        (
            vec![
                "session".to_string(),
                "import-product-control".to_string(),
                "--state-dir".to_string(),
                state_dir_string.clone(),
                "--json".to_string(),
            ],
            "session_import_evidence_required",
        ),
        (
            vec![
                "session".to_string(),
                "import-product-control".to_string(),
                "--state-dir".to_string(),
                state_dir_string.clone(),
                "--evidence".to_string(),
                evidence_string.clone(),
                "--remote-device-id".to_string(),
                secret_peer.to_string(),
                "--json".to_string(),
            ],
            "session_import_session_id_required",
        ),
        (
            vec![
                "session".to_string(),
                "import-product-control".to_string(),
                "--state-dir".to_string(),
                state_dir_string.clone(),
                "--evidence".to_string(),
                evidence_string.clone(),
                "--session-id".to_string(),
                secret_session.to_string(),
                "--json".to_string(),
            ],
            "session_import_remote_device_id_required",
        ),
    ];

    for (args, expected_code) in required_cases {
        let output = skybridge().args(&args).output().expect("run cli");

        assert!(!output.status.success(), "args={args:?}");
        assert!(output.stdout.is_empty(), "args={args:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        for secret in [
            state_dir_string.as_str(),
            evidence_string.as_str(),
            secret_session,
            secret_peer,
        ] {
            assert!(!stderr.contains(secret), "args={args:?} leaked {secret}");
        }
        let payload: serde_json::Value =
            serde_json::from_str(stderr.trim()).expect("session import error JSON should parse");
        assert_eq!(payload["capability_id"], "session.import_product_control");
        assert_eq!(payload["accepted"], false);
        assert_eq!(payload["session_imported"], false);
        assert_eq!(payload["error"]["code"], expected_code);
        assert!(!session_registry.exists());
    }

    let missing_evidence = state_dir
        .join("runtime")
        .join("secret-missing-evidence.json");
    let missing_evidence_string = missing_evidence.to_string_lossy().to_string();
    let output = skybridge()
        .args([
            "session",
            "import-product-control",
            "--state-dir",
            &state_dir_string,
            "--evidence",
            &missing_evidence_string,
            "--session-id",
            secret_session,
            "--remote-device-id",
            secret_peer,
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    for secret in [
        state_dir_string.as_str(),
        missing_evidence_string.as_str(),
        secret_session,
        secret_peer,
    ] {
        assert!(
            !stderr.contains(secret),
            "evidence read error leaked {secret}"
        );
    }
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("evidence read error JSON should parse");
    assert_eq!(
        payload["error"]["code"],
        "product_control_evidence_read_failed"
    );
    assert!(!session_registry.exists());

    let malformed_cases = vec![
        (
            vec![
                "session".to_string(),
                "import-product-control".to_string(),
                "--json".to_string(),
                "--json".to_string(),
            ],
            "duplicate --json",
        ),
        (
            vec![
                "session".to_string(),
                "import-product-control".to_string(),
                "--state-dir".to_string(),
                state_dir_string.clone(),
                "--state-dir".to_string(),
                "other-secret-state-dir".to_string(),
            ],
            "duplicate --state-dir",
        ),
        (
            vec![
                "session".to_string(),
                "import-product-control".to_string(),
                "--evidence".to_string(),
                evidence_string.clone(),
                "--evidence".to_string(),
                "other-secret-evidence".to_string(),
            ],
            "duplicate --evidence",
        ),
        (
            vec![
                "session".to_string(),
                "import-product-control".to_string(),
                "--session-id".to_string(),
                secret_session.to_string(),
                "--session-id".to_string(),
                "other-secret-session".to_string(),
            ],
            "duplicate --session-id",
        ),
        (
            vec![
                "session".to_string(),
                "import-product-control".to_string(),
                "--session-id-file".to_string(),
                "secret-session-file".to_string(),
                "--session-id-file".to_string(),
                "other-secret-session-file".to_string(),
            ],
            "duplicate --session-id-file",
        ),
        (
            vec![
                "session".to_string(),
                "import-product-control".to_string(),
                "--remote-device-id".to_string(),
                secret_peer.to_string(),
                "--remote-device-id".to_string(),
                "other-secret-peer".to_string(),
            ],
            "duplicate --remote-device-id",
        ),
        (
            vec![
                "session".to_string(),
                "import-product-control".to_string(),
                "--target-runtime-id".to_string(),
                "secret-runtime".to_string(),
                "--target-runtime-id".to_string(),
                "other-secret-runtime".to_string(),
            ],
            "duplicate --target-runtime-id",
        ),
        (
            vec![
                "session".to_string(),
                "import-product-control".to_string(),
                "--ttl-seconds".to_string(),
                "300".to_string(),
                "--ttl-seconds".to_string(),
                "600".to_string(),
            ],
            "duplicate --ttl-seconds",
        ),
        (
            vec![
                "session".to_string(),
                "import-product-control".to_string(),
                "--unsupported".to_string(),
            ],
            "unsupported session import-product-control option",
        ),
        (
            vec![
                "session".to_string(),
                "import-product-control".to_string(),
                "secret-positional-import".to_string(),
            ],
            "session import-product-control does not accept positional arguments",
        ),
    ];

    for (args, expected_error) in malformed_cases {
        let output = skybridge().args(&args).output().expect("run cli");

        assert!(!output.status.success(), "args={args:?}");
        assert!(output.stdout.is_empty(), "args={args:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(stderr.contains(expected_error), "args={args:?}: {stderr}");
        for secret in [
            state_dir_string.as_str(),
            evidence_string.as_str(),
            secret_session,
            secret_peer,
            "other-secret-state-dir",
            "other-secret-evidence",
            "other-secret-session",
            "secret-session-file",
            "other-secret-session-file",
            "other-secret-peer",
            "secret-runtime",
            "other-secret-runtime",
            "secret-positional-import",
        ] {
            assert!(!stderr.contains(secret), "args={args:?} leaked {secret}");
        }
        assert!(!session_registry.exists());
    }

    let missing_session_file = state_dir
        .join("runtime")
        .join("secret-missing-session-id.txt");
    let oversized_session_file = state_dir
        .join("runtime")
        .join("secret-oversized-session-id.txt");
    let invalid_utf8_session_file = state_dir.join("runtime").join("secret-invalid-utf8.txt");
    let invalid_session_file = state_dir
        .join("runtime")
        .join("secret-invalid-session-id.txt");
    std::fs::write(&oversized_session_file, vec![b'x'; 4 * 1024 + 1]).unwrap();
    std::fs::write(&invalid_utf8_session_file, [0xff, 0xfe]).unwrap();
    std::fs::write(&invalid_session_file, " secret-session-file ").unwrap();
    let secret_file_cases = [
        (
            missing_session_file,
            "session_import_session_id_file_read_failed",
        ),
        (
            state_dir.join("runtime"),
            "session_import_session_id_file_not_regular_file",
        ),
        (
            oversized_session_file,
            "session_import_session_id_file_too_large",
        ),
        (
            invalid_utf8_session_file,
            "session_import_session_id_file_read_failed",
        ),
        (
            invalid_session_file,
            "session_import_session_id_file_invalid",
        ),
    ];

    for (session_file, expected_code) in &secret_file_cases {
        let session_file_string = session_file.to_string_lossy().to_string();
        let output = skybridge()
            .args([
                "session",
                "import-product-control",
                "--state-dir",
                &state_dir_string,
                "--evidence",
                &evidence_string,
                "--session-id-file",
                &session_file_string,
                "--remote-device-id",
                secret_peer,
                "--json",
            ])
            .output()
            .expect("run cli");

        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        let stderr = String::from_utf8(output.stderr).unwrap();
        for secret in [
            state_dir_string.as_str(),
            evidence_string.as_str(),
            session_file_string.as_str(),
            secret_peer,
            "secret-session-file",
        ] {
            assert!(
                !stderr.contains(secret),
                "session file error leaked {secret}"
            );
        }
        let payload: serde_json::Value =
            serde_json::from_str(stderr.trim()).expect("session file error JSON should parse");
        assert_eq!(payload["error"]["code"], *expected_code);
        assert_eq!(payload["session_imported"], false);
        assert!(!session_registry.exists());
    }

    let missing_session_file_string = secret_file_cases[0].0.to_string_lossy().to_string();
    let output = skybridge()
        .args([
            "session",
            "import-product-control",
            "--state-dir",
            &state_dir_string,
            "--evidence",
            &evidence_string,
            "--session-id-file",
            &missing_session_file_string,
            "--remote-device-id",
            secret_peer,
        ])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert_eq!(
        stderr.trim(),
        "session import could not read --session-id-file"
    );
    assert!(!stderr.contains(&missing_session_file_string));
    assert!(!session_registry.exists());
}

#[test]
fn cli_session_import_rejects_identity_evidence_and_binding_conflict() {
    let secret_session = "secret-identity-session";
    let secret_peer = "secret-identity-peer";
    let state_dir = make_operator_state_dir("session-import-identity-errors");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    let session_registry = state_dir.join("runtime").join("sessions.json");

    let missing_session_hash = write_product_control_evidence_variant(
        "missing-session-hash",
        secret_session,
        secret_peer,
        |evidence| {
            evidence.as_object_mut().unwrap().remove("SessionIdSha256");
        },
    );
    let missing_remote_hash = write_product_control_evidence_variant(
        "missing-remote-hash",
        secret_session,
        secret_peer,
        |evidence| {
            evidence
                .as_object_mut()
                .unwrap()
                .remove("RemoteDeviceIdSha256");
        },
    );
    let missing_fingerprint = write_product_control_evidence_variant(
        "missing-remote-fingerprint",
        secret_session,
        secret_peer,
        |evidence| {
            evidence
                .as_object_mut()
                .unwrap()
                .remove("RemoteProtocolPublicKeyFingerprint");
        },
    );
    let remote_hash_mismatch = write_product_control_evidence_variant(
        "remote-hash-mismatch",
        secret_session,
        secret_peer,
        |evidence| {
            evidence["RemoteDeviceIdSha256"] =
                serde_json::json!(sha256_hex_for_test("different-secret-peer"));
        },
    );
    let evidence_cases = [
        (missing_session_hash, "session_import_session_hash_missing"),
        (
            missing_remote_hash,
            "session_import_remote_device_hash_missing",
        ),
        (
            missing_fingerprint,
            "session_import_remote_fingerprint_missing",
        ),
        (
            remote_hash_mismatch,
            "session_import_remote_device_hash_mismatch",
        ),
    ];

    for (evidence, expected_code) in &evidence_cases {
        let evidence_string = evidence.to_string_lossy().to_string();
        let output = skybridge()
            .args([
                "session",
                "import-product-control",
                "--state-dir",
                &state_dir_string,
                "--evidence",
                &evidence_string,
                "--session-id",
                secret_session,
                "--remote-device-id",
                secret_peer,
                "--json",
            ])
            .output()
            .expect("run cli");

        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        let stderr = String::from_utf8(output.stderr).unwrap();
        for secret in [
            state_dir_string.as_str(),
            evidence_string.as_str(),
            secret_session,
            secret_peer,
            "different-secret-peer",
        ] {
            assert!(!stderr.contains(secret), "identity error leaked {secret}");
        }
        let payload: serde_json::Value =
            serde_json::from_str(stderr.trim()).expect("identity error JSON should parse");
        assert_eq!(payload["capability_id"], "session.import_product_control");
        assert_eq!(payload["accepted"], false);
        assert_eq!(payload["session_imported"], false);
        assert_eq!(payload["error"]["code"], *expected_code);
        assert!(!session_registry.exists());
    }

    let conflict_state = make_operator_state_dir("session-import-binding-conflict");
    let conflict_state_string = conflict_state.to_string_lossy().to_string();
    let conflict_evidence = write_product_control_evidence_fixture_for_session(
        "session-import-binding-conflict",
        false,
        secret_session,
        secret_peer,
    );
    let conflict_evidence_string = conflict_evidence.to_string_lossy().to_string();
    let import_args = [
        "session",
        "import-product-control",
        "--state-dir",
        &conflict_state_string,
        "--evidence",
        &conflict_evidence_string,
        "--session-id",
        secret_session,
        "--remote-device-id",
        secret_peer,
        "--target-runtime-id",
        "windows-runtime-1",
        "--json",
    ];
    let output = skybridge().args(import_args).output().expect("run cli");
    assert!(
        output.status.success(),
        "initial import failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let conflict_json_args = [
        "session",
        "import-product-control",
        "--state-dir",
        &conflict_state_string,
        "--evidence",
        &conflict_evidence_string,
        "--session-id",
        secret_session,
        "--remote-device-id",
        secret_peer,
        "--target-runtime-id",
        "windows-runtime-2",
        "--json",
    ];
    let output = skybridge()
        .args(conflict_json_args)
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    for secret in [
        conflict_state_string.as_str(),
        conflict_evidence_string.as_str(),
        secret_session,
        secret_peer,
    ] {
        assert!(!stderr.contains(secret), "binding conflict leaked {secret}");
    }
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("binding conflict JSON should parse");
    assert_eq!(payload["capability_id"], "session.import_product_control");
    assert_eq!(payload["accepted"], false);
    assert_eq!(payload["session_imported"], false);
    assert_eq!(payload["error"]["code"], "session_binding_conflict");
    assert_eq!(
        payload["proof_boundary"]["session_import_not_live_runtime_start"],
        true
    );

    let conflict_text_args = [
        "session",
        "import-product-control",
        "--state-dir",
        &conflict_state_string,
        "--evidence",
        &conflict_evidence_string,
        "--session-id",
        secret_session,
        "--remote-device-id",
        secret_peer,
        "--target-runtime-id",
        "windows-runtime-2",
    ];
    let output = skybridge()
        .args(conflict_text_args)
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert_eq!(
        stderr.trim(),
        "session import conflicts with an existing operator session binding"
    );
    for secret in [
        conflict_state_string.as_str(),
        conflict_evidence_string.as_str(),
        secret_session,
        secret_peer,
    ] {
        assert!(!stderr.contains(secret), "binding conflict leaked {secret}");
    }

    let registry: serde_json::Value = serde_json::from_slice(
        &std::fs::read(conflict_state.join("runtime").join("sessions.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        registry["sessions"][secret_session]["target_runtime_id"],
        "windows-runtime-1"
    );
}

#[test]
fn cli_remote_desktop_rejects_unknown_or_duplicate_args_without_mutation() {
    let state_dir = make_operator_state_dir("remote-desktop-strict-args");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    let secret_session = "session-secret";
    write_remote_desktop_session_registry(&state_dir, secret_session, "established");

    let output = skybridge()
        .args([
            "remote-desktop",
            "start",
            "--state-dir",
            &state_dir_string,
            "--session-id",
            secret_session,
            "--session-id",
            secret_session,
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(!stderr.contains(secret_session));
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("remote desktop parse JSON should parse");
    assert_eq!(payload["error"]["code"], "remote_desktop_duplicate_option");
    assert!(!state_dir
        .join("runtime")
        .join("remote-desktop-requests.json")
        .exists());

    let output = skybridge()
        .args([
            "remote-desktop",
            "stop",
            "--state-dir",
            &state_dir_string,
            "--session-id",
            secret_session,
            "--resolution",
            "1920x1080",
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    let stderr = String::from_utf8(output.stderr).unwrap();
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("remote desktop parse JSON should parse");
    assert_eq!(
        payload["error"]["code"],
        "remote_desktop_resolution_not_allowed"
    );
    assert!(!state_dir
        .join("runtime")
        .join("remote-desktop-requests.json")
        .exists());
}

#[test]
fn cli_remote_desktop_rejects_option_shape_matrix() {
    let state_dir = make_operator_state_dir("remote-desktop-option-shape");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    let request_registry = state_dir
        .join("runtime")
        .join("remote-desktop-requests.json");
    let cases = vec![
        (
            vec![
                "remote-desktop".to_string(),
                "start".to_string(),
                "--json".to_string(),
                "--json".to_string(),
            ],
            "remote_desktop_duplicate_option",
        ),
        (
            vec![
                "remote-desktop".to_string(),
                "start".to_string(),
                "--state-dir".to_string(),
                state_dir_string.clone(),
                "--state-dir".to_string(),
                "other-secret-state-dir".to_string(),
                "--json".to_string(),
            ],
            "remote_desktop_duplicate_option",
        ),
        (
            vec![
                "remote-desktop".to_string(),
                "start".to_string(),
                "--json".to_string(),
                "--state-dir".to_string(),
            ],
            "remote_desktop_option_value_missing",
        ),
        (
            vec![
                "remote-desktop".to_string(),
                "start".to_string(),
                "--state-dir".to_string(),
                "--json".to_string(),
            ],
            "remote_desktop_option_value_missing",
        ),
        (
            vec![
                "remote-desktop".to_string(),
                "start".to_string(),
                "--json".to_string(),
                "--session-id".to_string(),
            ],
            "remote_desktop_option_value_missing",
        ),
        (
            vec![
                "remote-desktop".to_string(),
                "start".to_string(),
                "--resolution".to_string(),
                "1920x1080".to_string(),
                "--resolution".to_string(),
                "1280x720".to_string(),
                "--json".to_string(),
            ],
            "remote_desktop_duplicate_option",
        ),
        (
            vec![
                "remote-desktop".to_string(),
                "start".to_string(),
                "--json".to_string(),
                "--resolution".to_string(),
            ],
            "remote_desktop_option_value_missing",
        ),
        (
            vec![
                "remote-desktop".to_string(),
                "stop".to_string(),
                "--fps".to_string(),
                "60".to_string(),
                "--json".to_string(),
            ],
            "remote_desktop_fps_not_allowed",
        ),
        (
            vec![
                "remote-desktop".to_string(),
                "start".to_string(),
                "--fps".to_string(),
                "60".to_string(),
                "--fps".to_string(),
                "120".to_string(),
                "--json".to_string(),
            ],
            "remote_desktop_duplicate_option",
        ),
        (
            vec![
                "remote-desktop".to_string(),
                "start".to_string(),
                "--json".to_string(),
                "--fps".to_string(),
            ],
            "remote_desktop_option_value_missing",
        ),
        (
            vec![
                "remote-desktop".to_string(),
                "start".to_string(),
                "--unsupported".to_string(),
                "--json".to_string(),
            ],
            "remote_desktop_unsupported_option",
        ),
        (
            vec![
                "remote-desktop".to_string(),
                "start".to_string(),
                "secret-positional-remote".to_string(),
                "--json".to_string(),
            ],
            "remote_desktop_positional_argument_unsupported",
        ),
    ];

    for (args, expected_code) in cases {
        let output = skybridge().args(&args).output().expect("run cli");

        assert!(!output.status.success(), "args={args:?}");
        assert!(output.stdout.is_empty(), "args={args:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        for secret in [
            state_dir_string.as_str(),
            "other-secret-state-dir",
            "secret-positional-remote",
        ] {
            assert!(!stderr.contains(secret), "args={args:?} leaked {secret}");
        }
        let payload: serde_json::Value = serde_json::from_str(stderr.trim())
            .expect("remote desktop parse error JSON should parse");
        assert_eq!(payload["accepted"], false);
        assert_eq!(payload["status"], "request_invalid");
        assert_eq!(payload["request_registered"], false);
        assert_eq!(payload["pending_agent_observation"], false);
        assert_eq!(payload["applied"], false);
        assert_eq!(payload["error"]["code"], expected_code, "args={args:?}");
        assert!(!request_registry.exists());
    }
}

#[test]
fn cli_session_ls_rejects_oversized_registry_without_path_leak() {
    let state_dir = make_operator_state_dir("session-ls-oversized");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    std::fs::write(
        state_dir.join("runtime").join("sessions.json"),
        vec![b' '; 256 * 1024 + 1],
    )
    .unwrap();

    let output = skybridge()
        .args(["session", "ls", "--state-dir", &state_dir_string, "--json"])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(!stderr.contains(&state_dir_string));
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("session failure JSON should parse");
    assert_eq!(payload["capability_id"], "session.ls");
    assert_eq!(payload["session_registry_supported"], false);
    assert_eq!(payload["error"]["code"], "session_registry_too_large");
    assert_eq!(payload["error"]["retryable"], false);
}

#[test]
fn cli_file_transfer_state_dir_errors_are_redacted_and_classified() {
    let state_dir = make_operator_state_dir("file-transfer-errors");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    let secret_session = "session-secret";
    let destination_peer = "peer-device-1";
    write_remote_desktop_session_registry(&state_dir, secret_session, "connecting");
    let source_path = write_file_transfer_source_fixture("errors");
    let source_path_string = source_path.to_string_lossy().to_string();

    let output = skybridge()
        .args([
            "file",
            "send",
            "--state-dir",
            &state_dir_string,
            &source_path_string,
            "--to",
            destination_peer,
            "--session-id",
            secret_session,
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    for secret in [
        &source_path_string,
        destination_peer,
        secret_session,
        &state_dir_string,
    ] {
        assert!(
            !stderr.contains(secret),
            "file send failure leaked {secret}: {stderr}"
        );
    }
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("file send failure JSON should parse");
    assert_eq!(
        payload["error"]["code"],
        "file_transfer_session_not_established"
    );
    assert_eq!(payload["request_registered"], false);
    assert_eq!(payload["transfer_started"], false);
    assert_eq!(payload["receipt_verified"], false);

    let mismatch = make_operator_state_dir("file-transfer-peer-mismatch");
    let mismatch_string = mismatch.to_string_lossy().to_string();
    write_remote_desktop_session_registry(&mismatch, secret_session, "established");
    let output = skybridge()
        .args([
            "file",
            "send",
            "--state-dir",
            &mismatch_string,
            &source_path_string,
            "--to",
            "wrong-peer-secret",
            "--session-id",
            secret_session,
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    for secret in [
        &source_path_string,
        "wrong-peer-secret",
        secret_session,
        &mismatch_string,
    ] {
        assert!(
            !stderr.contains(secret),
            "file send peer mismatch leaked {secret}: {stderr}"
        );
    }
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(stderr.trim()).unwrap()["error"]["code"],
        "file_transfer_peer_mismatch"
    );

    let output = skybridge()
        .args([
            "file",
            "send",
            "--state-dir",
            &mismatch_string,
            "/private/missing/source.txt",
            "--to",
            destination_peer,
            "--session-id",
            secret_session,
            "--json",
        ])
        .output()
        .expect("run cli");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(!stderr.contains("/private/missing/source.txt"));
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(stderr.trim()).unwrap()["error"]["code"],
        "file_transfer_source_missing"
    );
}

#[test]
fn cli_file_send_rejects_incomplete_and_malformed_requests() {
    let state_dir = make_operator_state_dir("file-send-invalid-request");
    let state_dir_string = state_dir.to_string_lossy().to_string();
    let source_path = write_file_transfer_source_fixture("invalid-request");
    let source_path_string = source_path.to_string_lossy().to_string();
    let secret_peer = "secret-file-peer";
    let secret_session = "secret-file-session";
    let request_registry = state_dir
        .join("runtime")
        .join("file-transfer-requests.json");

    let incomplete_cases = vec![
        (
            vec![
                "file".to_string(),
                "send".to_string(),
                "--state-dir".to_string(),
                state_dir_string.clone(),
                "--json".to_string(),
            ],
            "file_transfer_source_missing",
            false,
            false,
            false,
        ),
        (
            vec![
                "file".to_string(),
                "send".to_string(),
                "--state-dir".to_string(),
                state_dir_string.clone(),
                source_path_string.clone(),
                "--session-id".to_string(),
                secret_session.to_string(),
                "--json".to_string(),
            ],
            "file_transfer_destination_required",
            true,
            false,
            true,
        ),
        (
            vec![
                "file".to_string(),
                "send".to_string(),
                "--state-dir".to_string(),
                state_dir_string.clone(),
                source_path_string.clone(),
                "--to".to_string(),
                secret_peer.to_string(),
                "--json".to_string(),
            ],
            "file_transfer_session_id_required",
            true,
            true,
            false,
        ),
    ];

    for (args, expected_code, source_provided, peer_provided, session_provided) in incomplete_cases
    {
        let output = skybridge().args(&args).output().expect("run cli");

        assert!(!output.status.success(), "args={args:?}");
        assert!(output.stdout.is_empty(), "args={args:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        for secret in [
            state_dir_string.as_str(),
            source_path_string.as_str(),
            secret_peer,
            secret_session,
        ] {
            assert!(!stderr.contains(secret), "args={args:?} leaked {secret}");
        }
        let payload: serde_json::Value =
            serde_json::from_str(stderr.trim()).expect("file request error JSON should parse");
        assert_eq!(payload["capability_id"], "file.transfer.send");
        assert_eq!(payload["accepted"], false);
        assert_eq!(payload["status"], "request_invalid");
        assert_eq!(payload["request_registered"], false);
        assert_eq!(payload["transfer_started"], false);
        assert_eq!(payload["receipt_verified"], false);
        assert_eq!(payload["source_path_provided"], source_provided);
        assert_eq!(payload["destination_peer_provided"], peer_provided);
        assert_eq!(payload["session_id_provided"], session_provided);
        assert_eq!(payload["error"]["code"], expected_code);
        assert!(!request_registry.exists());
    }

    let malformed_cases = vec![
        (
            vec![
                "file".to_string(),
                "send".to_string(),
                "--state-dir".to_string(),
                state_dir_string.clone(),
                "--state-dir".to_string(),
                "other-secret-state-dir".to_string(),
                "--json".to_string(),
            ],
            "duplicate --state-dir",
        ),
        (
            vec![
                "file".to_string(),
                "send".to_string(),
                source_path_string.clone(),
                "--to".to_string(),
                secret_peer.to_string(),
                "--to".to_string(),
                "other-secret-peer".to_string(),
                "--json".to_string(),
            ],
            "duplicate --to",
        ),
        (
            vec![
                "file".to_string(),
                "send".to_string(),
                source_path_string.clone(),
                "--session-id".to_string(),
                secret_session.to_string(),
                "--session-id".to_string(),
                "other-secret-session".to_string(),
                "--json".to_string(),
            ],
            "duplicate --session-id",
        ),
        (
            vec![
                "file".to_string(),
                "send".to_string(),
                source_path_string.clone(),
                "--unsupported".to_string(),
                "--json".to_string(),
            ],
            "unsupported file send option: --unsupported",
        ),
        (
            vec![
                "file".to_string(),
                "send".to_string(),
                source_path_string.clone(),
                "second-secret-source".to_string(),
                "--json".to_string(),
            ],
            "file send accepts exactly one source path",
        ),
        (
            vec![
                "file".to_string(),
                "send".to_string(),
                source_path_string.clone(),
                "--to".to_string(),
                "--json".to_string(),
            ],
            "--to requires a value",
        ),
    ];

    for (args, expected_error) in malformed_cases {
        let output = skybridge().args(&args).output().expect("run cli");

        assert!(!output.status.success(), "args={args:?}");
        assert!(output.stdout.is_empty(), "args={args:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(stderr.contains(expected_error), "args={args:?}: {stderr}");
        for secret in [
            state_dir_string.as_str(),
            source_path_string.as_str(),
            secret_peer,
            secret_session,
            "other-secret-state-dir",
            "other-secret-peer",
            "other-secret-session",
            "second-secret-source",
        ] {
            assert!(!stderr.contains(secret), "args={args:?} leaked {secret}");
        }
        assert!(!request_registry.exists());
    }
}

#[test]
fn cli_operator_contracts_report_read_only_windows_surface() {
    let output = skybridge()
        .args(["remote-desktop", "contract", "--json"])
        .output()
        .expect("run cli");
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let payload: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("remote desktop contract JSON should parse");
    assert_eq!(payload["live_control_status"], "request_registry_available");
    assert_eq!(payload["mutation_supported"], false);
    assert_eq!(payload["request_registry_supported"], true);
    assert!(payload["required_gates"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!("real_device_p2p_remote_gate")));

    let output = skybridge()
        .args(["file", "history", "--json"])
        .output()
        .expect("run cli");
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let payload: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("file history JSON should parse");
    assert_eq!(payload["history_supported"], false);
    assert_eq!(payload["pending_requests"], 0);
    assert!(payload["history"].as_array().unwrap().is_empty());
}

#[test]
fn cli_product_control_evidence_status_reports_read_only_boundaries() {
    let path = write_product_control_evidence_fixture("valid-smoke", false);
    let path_string = path.to_string_lossy().to_string();

    let output = skybridge()
        .args(["evidence", "status", "--evidence", &path_string, "--json"])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(
        !stdout.contains(&path_string),
        "evidence status leaked local path: {stdout}"
    );
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("evidence status JSON should parse");
    assert_eq!(
        payload["capability_id"],
        "current_path.product_control.evidence"
    );
    assert_eq!(payload["evidence_valid"], true);
    assert_eq!(payload["live_runtime_started"], false);
    assert_eq!(payload["request_registered"], false);
    assert_eq!(
        payload["product_control"]["proof_level"],
        "appcontrol_sbwc_ping_pong"
    );
    assert_eq!(payload["proof_boundary"]["mac_product_app_proof"], false);
    assert_eq!(payload["file_transfer"]["proven"], false);
    assert_eq!(payload["remote_desktop"]["proven"], false);
    assert_eq!(payload["freshness_enforced"], false);
}

#[test]
fn cli_product_control_evidence_rejects_secret_capture_without_input_leaks() {
    let path = write_product_control_evidence_fixture("bad-smoke", true);
    let path_string = path.to_string_lossy().to_string();
    let secret_session = "session-secret";

    let output = skybridge()
        .args([
            "remote-desktop",
            "status",
            "--session-id",
            secret_session,
            "--product-control-evidence",
            &path_string,
            "--json",
        ])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(!stderr.contains(&path_string));
    assert!(!stderr.contains(secret_session));
    let payload: serde_json::Value =
        serde_json::from_str(stderr.trim()).expect("evidence failure JSON should parse");
    assert_eq!(
        payload["capability_id"],
        "remote_desktop.status.product_control_evidence"
    );
    assert_eq!(payload["evidence_valid"], false);
    assert_eq!(
        payload["error"]["code"],
        "product_control_evidence_secret_capture_detected"
    );
}

#[test]
fn cli_version_smoke() {
    let output = skybridge().arg("version").output().expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.starts_with("skybridge-core "));
}

#[test]
fn cli_version_json_reports_windows_contract_identity() {
    let output = skybridge()
        .args(["version", "--json"])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("version JSON should parse");
    assert_eq!(payload["schema_version"], 1);
    assert_eq!(payload["product_name"], "SkyBridge CLI");
    assert_eq!(payload["binary_name"], "skybridge");
    assert_eq!(payload["cli_version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(payload["platform"], "windows");
    assert_eq!(payload["surface"], "windows_protocol_diagnostic");
    assert_eq!(payload["contracts_schema_version"], 1);
    assert_eq!(payload["mac_gui_control_supported"], false);
    assert_eq!(payload["ios_runtime_control_supported"], false);
}

#[test]
fn cli_windows_same_lan_selects_msquic() {
    let output = skybridge()
        .args([
            "transport",
            "select",
            "--local",
            "windows",
            "--remote",
            "windows",
            "--path",
            "same-lan",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("kind=WindowsNativeMsQuic"));
    assert!(stdout.contains("audit=WindowsNativeMsQuicSameLan"));
    assert!(stdout.contains("priority=100"));
}

#[test]
fn cli_windows_to_apple_selects_webrtc_interop() {
    let output = skybridge()
        .args([
            "transport",
            "select",
            "--local",
            "windows",
            "--remote",
            "macos",
            "--path",
            "cross-nat",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("kind=WebRtcDataChannel"));
    assert!(stdout.contains("audit=WebRtcInterop"));
    assert!(stdout.contains("relay_allowed=true"));
}

#[test]
fn cli_apple_to_apple_selects_apple_native() {
    let output = skybridge()
        .args([
            "transport",
            "select",
            "--local",
            "macos",
            "--remote",
            "ios",
            "--path",
            "same-lan",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("kind=AppleNative"));
    assert!(stdout.contains("audit=AppleNativeDefault"));
    assert!(stdout.contains("relay_allowed=false"));
}

#[test]
fn cli_ios_to_macos_selects_apple_native() {
    let output = skybridge()
        .args([
            "transport",
            "select",
            "--local",
            "ios",
            "--remote",
            "macos",
            "--path",
            "same-lan",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("kind=AppleNative"));
    assert!(stdout.contains("audit=AppleNativeDefault"));
    assert!(stdout.contains("relay_allowed=false"));
    assert!(!stdout.contains("WebRtcDataChannel"));
}

#[test]
fn cli_windows_to_ios_selects_webrtc_interop() {
    let output = skybridge()
        .args([
            "transport",
            "select",
            "--local",
            "windows",
            "--remote",
            "ios",
            "--path",
            "same-lan",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("kind=WebRtcDataChannel"));
    assert!(stdout.contains("audit=WebRtcInterop"));
    assert!(!stdout.contains("AppleNative"));
}

#[test]
fn cli_transport_bind_reports_binding_digest() {
    let output = skybridge()
        .args([
            "transport",
            "bind",
            "--transport",
            "webrtc",
            "--local-endpoint",
            "10.0.0.1:443",
            "--remote-endpoint",
            "10.0.0.2:443",
            "--candidate-pair",
            "host/udp",
            "--secret-fp",
            "secret-fingerprint",
            "--capability-digest",
            "capability-digest",
            "--timestamp-window-ms",
            "10000",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("transport=WebRtcDataChannel"));
    assert!(stdout.contains("relay_id=none"));
    let digest = stdout
        .lines()
        .find_map(|line| line.strip_prefix("binding_digest="))
        .expect("binding digest output");
    assert_eq!(digest.len(), 64);
    assert!(digest.chars().all(|value| value.is_ascii_hexdigit()));
    assert_eq!(digest, digest.to_ascii_lowercase());
}

#[test]
fn cli_transport_bind_accepts_relay_id() {
    let output = skybridge()
        .args([
            "transport",
            "bind",
            "--transport",
            "relay",
            "--local-endpoint",
            "relay-local",
            "--remote-endpoint",
            "relay-remote",
            "--candidate-pair",
            "relay/tcp",
            "--secret-fp",
            "secret-fingerprint",
            "--capability-digest",
            "capability-digest",
            "--timestamp-window-ms",
            "5000",
            "--relay-id",
            "relay-1",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("transport=Relay"));
    assert!(stdout.contains("relay_id=relay-1"));
}

#[test]
fn cli_suite_offer_lists_provider_derived_suites() {
    let output = skybridge()
        .args([
            "suite",
            "offer",
            "--caps",
            "xwing,x25519,p256",
            "--allow-classic",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("x-wing-hybrid=0x0001"));
    assert!(stdout.contains("x25519-ed25519=0x1001"));
    assert!(!stdout.contains("p256-ecdsa"));
}

#[test]
fn cli_suite_select_prefers_pqc_suite() {
    let output = skybridge()
        .args([
            "suite",
            "select",
            "--local-caps",
            "mlkem,x25519",
            "--remote-suites",
            "0x1001,0x0101",
            "--allow-classic",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("suite=ml-kem-768-ml-dsa-65 (0x0101)"));
    assert!(stdout.contains("audit=PurePqcPreferred"));
}

#[test]
fn cli_suite_select_blocks_timeout_downgrade() {
    let output = skybridge()
        .args([
            "suite",
            "select",
            "--local-caps",
            "x25519",
            "--remote-suites",
            "0x1001",
            "--allow-classic",
            "--timeout-observed",
        ])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert_eq!(output.status.code(), Some(2));
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("TimeoutCannotDowngrade"));
}

#[test]
fn cli_pqc_status_reports_operator_policy_and_missing_key_gates() {
    let output = skybridge()
        .args(["pqc", "status", "--json"])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    let payload: serde_json::Value =
        serde_json::from_str(&stdout).expect("pqc status JSON should parse");

    assert_eq!(payload["capability_id"], "pqc.handshake");
    assert_eq!(payload["status"], "read_only");
    assert_eq!(payload["suite_negotiation_supported"], true);
    assert_eq!(payload["strict_pqc_policy_available"], true);
    assert_eq!(payload["handshake_proven"], false);
    assert_eq!(payload["live_runtime_started"], false);
    assert_eq!(payload["mutation_supported"], false);
    assert_eq!(payload["session_created"], false);
    assert_eq!(
        payload["proof_boundary"]["suite_negotiation_not_handshake_proof"],
        true
    );

    let supported_suite_ids = payload["supported_suite_ids"]
        .as_array()
        .expect("supported_suite_ids array");
    assert!(supported_suite_ids.contains(&serde_json::json!("0x0001")));
    assert!(supported_suite_ids.contains(&serde_json::json!("0x0101")));

    let missing_gates = payload["missing_gates"]
        .as_array()
        .expect("missing_gates array");
    for missing_gate in [
        "verified_peer_protocol_identity",
        "ml_dsa_signed_handshake",
        "ml_kem_or_xwing_session_keys",
        "sbwc_secure_session_established",
    ] {
        assert!(
            missing_gates.contains(&serde_json::json!(missing_gate)),
            "pqc status must include missing gate {missing_gate}: {stdout}"
        );
    }
}

#[test]
fn cli_pqc_status_text_keeps_handshake_boundary_visible() {
    let output = skybridge()
        .args(["pqc", "status"])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("capability_id=pqc.handshake"));
    assert!(stdout.contains("status=read_only"));
    assert!(stdout.contains("handshake_proven=false"));
    assert!(stdout.contains("live_runtime_started=false"));
    assert!(stdout.contains("mutation_supported=false"));
    assert!(stdout.contains("session_created=false"));
    assert!(stdout.contains("supported_suite_ids=0x0001,0x0101"));
    assert!(stdout.contains("proof_boundary=suite_negotiation_not_handshake_proof"));
    assert!(stdout.contains("ml_dsa_signed_handshake"));
    assert!(stdout.contains("ml_kem_or_xwing_session_keys"));
    assert!(stdout.contains("sbwc_secure_session_established"));
}

#[test]
fn cli_pqc_status_rejects_ambiguous_options() {
    let output = skybridge()
        .args(["pqc", "status", "--json", "--extra"])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("expected pqc status [--json]"));
}

#[test]
fn cli_pqc_offer_lists_provider_derived_suites() {
    let output = skybridge()
        .args([
            "pqc",
            "offer",
            "--caps",
            "xwing,x25519,p256",
            "--allow-classic",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("x-wing-hybrid=0x0001"));
    assert!(stdout.contains("x25519-ed25519=0x1001"));
    assert!(!stdout.contains("p256-ecdsa"));
}

#[test]
fn cli_pqc_select_prefers_pqc_suite() {
    let output = skybridge()
        .args([
            "pqc",
            "select",
            "--local-caps",
            "mlkem,x25519",
            "--remote-suites",
            "0x1001,0x0101",
            "--allow-classic",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("suite=ml-kem-768-ml-dsa-65 (0x0101)"));
    assert!(stdout.contains("audit=PurePqcPreferred"));
}

#[test]
fn cli_channel_profile_reports_default_reliability() {
    let output = skybridge()
        .args(["channel", "profile", "--channel", "clipboard"])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("channel=Clipboard"));
    assert!(stdout.contains("reliability=reliable-ordered"));
}

#[test]
fn cli_channel_map_reports_transport_binding() {
    let output = skybridge()
        .args([
            "channel",
            "map",
            "--transport",
            "msquic",
            "--channel",
            "telemetry",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("channel=Telemetry"));
    assert!(stdout.contains("transport=WindowsNativeMsQuic"));
    assert!(stdout.contains("binding=skybridge.telemetry"));
    assert!(stdout.contains("reliability=reliable-unordered"));
    assert!(stdout.contains("head_of_line_isolated=true"));
}

#[test]
fn cli_frame_describe_accepts_plain_frame() {
    let output = skybridge()
        .args([
            "frame",
            "describe",
            "--channel",
            "control",
            "--sequence",
            "8",
            "--payload",
            "hello",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("channel=Control"));
    assert!(stdout.contains("sequence=8"));
    assert!(stdout.contains("flags=0x0002"));
    assert!(stdout.contains("payload_len=5"));
}

#[test]
fn cli_frame_describe_reports_roundtrip_metadata() {
    let output = skybridge()
        .args([
            "frame",
            "describe",
            "--channel",
            "control",
            "--sequence",
            "8",
            "--payload",
            "hello",
            "--sbp2-fixed",
            "32",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("channel=Control"));
    assert!(stdout.contains("sequence=8"));
    assert!(stdout.contains("flags=0x0003"));
    assert!(stdout.contains("frame_len=60"));
    assert!(stdout.contains("payload_len=5"));
}

#[test]
fn cli_connection_plan_reports_core_contract() {
    let output = skybridge()
        .args([
            "connection",
            "plan",
            "--local",
            "windows",
            "--remote",
            "macos",
            "--path",
            "cross-nat",
            "--local-caps",
            "xwing,mlkem,x25519",
            "--remote-suites",
            "0x1001,0x0101,0x0001",
            "--allow-classic",
            "--sbp2-fixed",
            "512",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("transport=WebRtcDataChannel"));
    assert!(stdout.contains("suite=x-wing-hybrid (0x0001)"));
    assert!(stdout.contains("channel_count=5"));
    assert!(stdout.contains("channel.realtime=WebRtcDataChannel:skybridge.realtime"));
    assert!(stdout.contains("sbp2_enabled=true"));
}

#[test]
fn cli_windows_to_apple_same_lan_connection_plan_uses_webrtc() {
    let output = skybridge()
        .args([
            "connection",
            "plan",
            "--local",
            "windows",
            "--remote",
            "macos",
            "--path",
            "same-lan",
            "--local-caps",
            "xwing,mlkem,x25519",
            "--remote-suites",
            "0x1001,0x0101,0x0001",
            "--allow-classic",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("transport=WebRtcDataChannel"));
    assert!(stdout.contains("transport_audit=WebRtcInterop"));
    assert!(stdout.contains("channel.control=WebRtcDataChannel:skybridge.control"));
    assert!(stdout.contains("channel.realtime=WebRtcDataChannel:skybridge.realtime"));
    assert!(!stdout.contains("AppleNative"));
}

#[test]
fn cli_apple_to_apple_connection_plan_keeps_apple_native_channels() {
    let output = skybridge()
        .args([
            "connection",
            "plan",
            "--local",
            "macos",
            "--remote",
            "ios",
            "--path",
            "same-lan",
            "--local-caps",
            "xwing,mlkem,x25519",
            "--remote-suites",
            "0x1001,0x0101,0x0001",
            "--allow-classic",
            "--sbp2-fixed",
            "512",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("transport=AppleNative"));
    assert!(stdout.contains("channel.control=AppleStream:skybridge.control"));
    assert!(stdout.contains("channel.file=AppleStream:skybridge.file"));
    assert!(stdout.contains("channel.telemetry=AppleDatagram:skybridge.telemetry"));
    assert!(stdout.contains("channel.realtime=AppleDatagram:skybridge.realtime"));
    assert!(stdout.contains("sbp2_enabled=true"));
}

#[test]
fn cli_discovery_parse_accepts_mac_bonjour_txt() {
    let output = skybridge()
        .args([
            "discovery",
            "parse",
            "--service",
            "_skybridge._udp",
            "--txt",
            "deviceId=mac-1;pubKeyFP=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef;platform=macOS;capabilities=webrtc,tcp;name=Desk Mac;version=v1",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("service=_skybridge._udp"));
    assert!(stdout.contains("device_id=mac-1"));
    assert!(stdout.contains("platform=Apple"));
    assert!(stdout.contains("supports_apple_native=true"));
    assert!(stdout.contains("supports_webrtc_data_channel=true"));
}

#[test]
fn cli_discovery_parse_normalizes_legacy_product_services() {
    for (legacy_service, canonical_service) in [
        ("_skybridge-transfer._tcp", "_skybridge-xfer._tcp"),
        ("_skybridge-remote._tcp", "_skybridge-rd._tcp"),
    ] {
        let output = skybridge()
            .args([
                "discovery",
                "parse",
                "--service",
                legacy_service,
                "--txt",
                "deviceId=mac-1;pubKeyFP=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef;platform=macOS;capabilities=webrtc;name=Desk Mac;version=v1",
            ])
            .output()
            .expect("run cli");

        assert!(output.status.success());
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert!(stdout.contains(&format!("service={canonical_service}")));
        assert!(!stdout.contains(&format!("service={legacy_service}")));
    }
}

#[test]
fn cli_discovery_parse_accepts_apple_txt_identity_aliases() {
    let output = skybridge()
        .args([
            "discovery",
            "parse",
            "--service",
            "_skybridge._udp",
            "--txt",
            "unique_id=ipad-1;identityFingerprint=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef;platform=iPadOS;capabilities=webrtc;name=iPad;version=v1",
        ])
        .output()
        .expect("run cli");

    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("device_id=ipad-1"));
    assert!(stdout.contains("platform=Apple"));
    assert!(stdout.contains("supports_webrtc_data_channel=true"));
}

#[test]
fn cli_webrtc_proof_validate_accepts_schema_smoke() {
    let proof_path = write_webrtc_proof_fixture("valid", true);
    let proof_path_text = proof_path.to_string_lossy().to_string();
    let output = skybridge()
        .args([
            "webrtc-proof",
            "validate",
            "--proof",
            &proof_path_text,
            "--expected-device-id",
            "mac-1",
            "--expected-fingerprint",
            WEBRTC_PROOF_FINGERPRINT,
        ])
        .output()
        .expect("run cli");

    let _ = std::fs::remove_file(proof_path);
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("webrtc_proof=valid"));
    assert!(stdout.contains("peer_device_id=mac-1"));
    assert!(stdout.contains("helper_name=schema-smoke-webrtc-helper"));
    assert!(stdout.contains("selected_candidate_pair=webrtc/dtls/sctp/helper-selected"));
    assert!(stdout.contains("timestamp_window_ms=15000"));
}

#[test]
fn cli_webrtc_proof_validate_rejects_missing_sbf1_smoke() {
    let proof_path = write_webrtc_proof_fixture("missing-sbf1", false);
    let proof_path_text = proof_path.to_string_lossy().to_string();
    let output = skybridge()
        .args([
            "webrtc-proof",
            "validate",
            "--proof",
            &proof_path_text,
            "--expected-device-id",
            "mac-1",
            "--expected-fingerprint",
            WEBRTC_PROOF_FINGERPRINT,
        ])
        .output()
        .expect("run cli");

    let _ = std::fs::remove_file(proof_path);
    assert!(!output.status.success());
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("webrtc proof validation failed"));
    assert!(stderr.contains("SBF1 echo frame"));
}

#[test]
fn cli_rejects_incomplete_transport_command() {
    let output = skybridge()
        .args(["transport", "select", "--local", "windows"])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert_eq!(output.status.code(), Some(2));
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("--remote"));
}

#[test]
fn cli_rejects_unknown_command() {
    let output = skybridge().arg("bogus").output().expect("run cli");

    assert!(!output.status.success());
    assert_eq!(output.status.code(), Some(2));
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("unknown command: bogus"));
}

#[test]
fn cli_rejects_invalid_suite_id_smoke() {
    let output = skybridge()
        .args([
            "suite",
            "select",
            "--local-caps",
            "x25519",
            "--remote-suites",
            "0xzz",
        ])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("invalid suite id: 0xzz"));
}

#[test]
fn cli_rejects_bad_discovery_txt_smoke() {
    let output = skybridge()
        .args([
            "discovery",
            "parse",
            "--service",
            "_skybridge._udp",
            "--txt",
            "deviceId=mac-1;pubKeyFP=bad;platform=macOS;capabilities=webrtc,tcp;name=Desk Mac;version=v1",
        ])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("InvalidPublicKeyFingerprint"));
}

#[test]
fn cli_rejects_too_small_sbp2_frame_smoke() {
    let output = skybridge()
        .args([
            "frame",
            "describe",
            "--channel",
            "control",
            "--sequence",
            "1",
            "--payload",
            "hello",
            "--sbp2-fixed",
            "4",
        ])
        .output()
        .expect("run cli");

    assert!(!output.status.success());
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("frame encode failed"));
    assert!(stderr.contains("TargetTooSmall"));
}
