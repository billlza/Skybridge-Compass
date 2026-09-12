use crate::channel::{map_channel, AdapterChannelBinding};
use crate::connection::{plan_connection, ConnectionPlan, ConnectionRequest, TrafficPaddingPlan};
use crate::discovery::{parse_service_kind, parse_txt_advertisement, DiscoveryServiceKind};
use crate::frame::{
    decode_frame, decode_frame_payload, encode_frame, encode_sbp2_frame, CoreFrame, FrameFlags,
};
use crate::operator_state::{
    metadata_is_unsafe, read_file_transfer_history, read_nearby_discovery_snapshot,
    read_remote_desktop_status, read_session_inventory,
    register_established_product_control_session,
    register_file_transfer_send_request_for_established_session,
    register_remote_desktop_request_for_established_session, reject_unsafe_path_components,
    remote_desktop_fps_supported, remote_desktop_resolution_request, FileTransferControlRequest,
    NearbyDiscoveredDevice, NearbyDiscoverySnapshotRead, OperatorStateError,
    ProductControlSessionRegistration, RemoteDesktopControlAction, RemoteDesktopControlRequest,
    RemoteDesktopControlRequestPayload, RuntimeSessionSummary, REMOTE_DESKTOP_FPS_VALUES,
    REMOTE_DESKTOP_RESOLUTION_IDS,
};
use crate::product_control_evidence::{
    validate_product_control_evidence_json, ProductControlEvidenceError,
    ProductControlEvidenceSummary, ProductControlProofLevel, MAX_PRODUCT_CONTROL_EVIDENCE_BYTES,
};
use crate::suite::{
    negotiate_suite, offered_suites, CryptoProviderCapabilities, CryptoSuite, CryptoSuitePolicy,
};
use crate::transport::{
    NetworkPath, PeerCapabilities, PeerPlatform, SkyBridgeChannel, SkyBridgeReliability,
    SkyBridgeTransportKind, TransportBindingMaterial, TransportPlan, TransportSelector,
};
use crate::webrtc_proof::validate_webrtc_proof_json;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::fmt::Write as FmtWrite;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::Path;
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

const HELP: &str = "\
SkyBridge CLI

USAGE:
  skybridge version [--json]
  skybridge capabilities [--json]
  skybridge device discover --nearby [--state-dir <dir>] [--scan] [--json]
  skybridge code create [--device-name <name>] [--ttl-seconds <n>] [--json]
  skybridge code current [--snapshot <path>] [--json]
  skybridge connect <code> [--json]
  skybridge session ls [--state-dir <dir>] [--json]
  skybridge session inspect [--state-dir <dir>] <id> [--json]
  skybridge session import-product-control --state-dir <dir> --evidence <path> (--session-id <id>|--session-id-file <path>) --remote-device-id <id> [--target-runtime-id <id>] [--ttl-seconds <n>] [--json]
  skybridge disconnect <session-id> [--json]
  skybridge file send [--state-dir <dir>] <path> --to <peer> --session-id <id> [--json]
  skybridge file receive [--json]
  skybridge file history [--state-dir <dir>] [--session-id <id>] [--json]
  skybridge evidence status --evidence <path> [--json]
  skybridge remote-desktop contract [--json]
  skybridge remote-desktop status [--state-dir <dir>] [--session-id <id>] [--product-control-evidence <path>] [--json]
  skybridge remote-desktop resolutions [--state-dir <dir>] [--session-id <id>] [--json]
  skybridge remote-desktop start [--state-dir <dir>] --session-id <id> [--resolution <preset>] [--fps <n>] [--json]
  skybridge remote-desktop stop [--state-dir <dir>] --session-id <id> [--json]
  skybridge remote-desktop set-resolution [--state-dir <dir>] --session-id <id> --resolution <preset> [--json]
  skybridge remote-desktop set-fps [--state-dir <dir>] --session-id <id> --fps <n> [--json]
  skybridge transport select --local <apple|windows> --remote <apple|windows> --path <same-lan|cross-nat>
  skybridge transport bind --transport <apple-native|msquic|webrtc|relay|tcp> --local-endpoint <text> --remote-endpoint <text> --candidate-pair <text> --secret-fp <text> --capability-digest <text> --timestamp-window-ms <n> [--relay-id <text>]
  skybridge suite offer --caps <xwing,mlkem,x25519,p256> [--allow-classic] [--allow-legacy-p256]
  skybridge suite select --local-caps <xwing,mlkem,x25519,p256> --remote-suites <0x0001,0x1001> [--allow-classic] [--allow-legacy-p256] [--timeout-observed]
  skybridge pqc status [--json]
  skybridge pqc offer --caps <xwing,mlkem,x25519,p256> [--allow-classic] [--allow-legacy-p256]
  skybridge pqc select --local-caps <xwing,mlkem,x25519,p256> --remote-suites <0x0001,0x1001> [--allow-classic] [--allow-legacy-p256] [--timeout-observed]
  skybridge channel profile --channel <control|file|clipboard|telemetry|realtime>
  skybridge channel map --transport <apple-native|msquic|webrtc|relay|tcp> --channel <control|file|clipboard|telemetry|realtime>
  skybridge frame describe --channel <control|file|clipboard|telemetry|realtime> --sequence <n> --payload <text> [--sbp2-fixed <n>]
  skybridge connection plan --local <apple|windows> --remote <apple|windows> --path <same-lan|cross-nat> --local-caps <xwing,mlkem,x25519,p256> --remote-suites <0x0001,0x1001> [--allow-classic] [--allow-legacy-p256] [--timeout-observed] [--sbp2-fixed <n>]
  skybridge discovery parse --service <udp|tcp|_skybridge._udp|_skybridge._tcp> --txt <deviceId|unique_id=...;pubKeyFP|identityFingerprint=...;platform=...;capabilities=...;name=...;version=...>
  skybridge webrtc-proof validate --proof <path> --expected-device-id <id> --expected-fingerprint <64-lowercase-hex> [--max-age-ms <n>]
";

const CAPABILITY_SCHEMA_VERSION: u32 = 1;
const OPERATOR_CONTRACT_SCHEMA_VERSION: u32 = 1;
const PRODUCT_NAME: &str = "SkyBridge CLI";
const BINARY_NAME: &str = "skybridge";
const WINDOWS_PLATFORM: &str = "windows";
const WINDOWS_CLI_SURFACE: &str = "windows_protocol_diagnostic";
const WINDOWS_OPERATOR_COMMAND_PARITY: &str =
    "discovery_snapshot_remote_desktop_and_file_transfer_request_registries_available_windows_agent_observation_required";
const MAX_CONNECTION_CODE_SNAPSHOT_BYTES: u64 = 64 * 1024;
const SESSION_IMPORT_DEFAULT_TTL_SECONDS: u64 = 3_600;
const SESSION_IMPORT_MAX_TTL_SECONDS: u64 = 86_400;
const SESSION_IMPORT_DEFAULT_TARGET_RUNTIME_ID: &str = "runtime-smoke-product-control";
const SESSION_IMPORT_SECRET_FILE_MAX_BYTES: u64 = 4 * 1024;
const SESSION_IMPORT_SECRET_VALUE_MAX_BYTES: usize = 512;

const DISCOVERY_REQUIRED_GATES: &[&str] = &[
    "windows_agent_owned_discovery_snapshot",
    "native_dns_sd_require_peer_gate",
    "shared_bonjour_identity_dedupe",
    "protocol_identity_trust_projection",
    "freshness_window_validation",
    "connectivity_matrix_gate",
];
const DISCOVERY_CONNECT_GATES: &[&str] = &[
    "explicit_operator_connect_request",
    "protocol_identity_trust_projection",
    "route_revalidation",
    "product_session_handshake_gate",
];
const CONNECT_REQUIRED_GATES: &[&str] = &[
    "windows_agent_state_registry",
    "current_path_admission_or_native_signaling",
    "verified_peer_protocol_identity",
    "ml_dsa_signed_handshake",
    "ml_kem_or_xwing_session_keys",
    "sbwc_secure_session_established",
];
const PQC_HANDSHAKE_MISSING_GATES: &[&str] = &[
    "verified_peer_protocol_identity",
    "ml_dsa_signed_handshake",
    "ml_kem_or_xwing_session_keys",
    "sbwc_secure_session_established",
];
const FILE_TRANSFER_REQUIRED_GATES: &[&str] = &[
    "product_control_secure_session",
    "shared_route_contract",
    "protocol_identity_binding",
    "receiver_write_policy",
    "transferred_bytes",
    "file_sha256_receipt",
    "real_device_file_transfer_gate",
];
const REMOTE_DESKTOP_REQUIRED_GATES: &[&str] = &[
    "product_control_secure_session",
    "remote_control_notice_artifact_gate",
    "sender_observed_mode_change",
    "capture_input_video_data_path",
    "real_device_p2p_remote_gate",
    "performance_p2p_remote_final_window_fps_gate",
];
const REMOTE_DESKTOP_EVIDENCE_SOURCES: &[&str] = &[
    "Scripts/verify-windows-current-path-product-control-appcontrol-live.ps1",
    "real_device_p2p_remote_gate",
    "remote_control_notice_artifact_gate",
    "performance_p2p_remote_final_window_fps_gate",
];
const REMOTE_DESKTOP_COMMAND_CONTRACTS: &[&str] = &[
    "skybridge remote-desktop contract [--json]",
    "skybridge remote-desktop status [--state-dir <dir>] [--session-id <id>] [--product-control-evidence <path>] [--json]",
    "skybridge remote-desktop resolutions [--state-dir <dir>] [--session-id <id>] [--json]",
    "skybridge remote-desktop start [--state-dir <dir>] --session-id <id> [--resolution <preset>] [--fps <n>] [--json]",
    "skybridge remote-desktop stop [--state-dir <dir>] --session-id <id> [--json]",
    "skybridge remote-desktop set-resolution [--state-dir <dir>] --session-id <id> --resolution <preset> [--json]",
    "skybridge remote-desktop set-fps [--state-dir <dir>] --session-id <id> --fps <n> [--json]",
];
const REMOTE_DESKTOP_RESOLUTION_CONTRACT: &[&str] = REMOTE_DESKTOP_RESOLUTION_IDS;
const REMOTE_DESKTOP_FPS_CONTRACT: &[u16] = REMOTE_DESKTOP_FPS_VALUES;

struct CliCapability {
    id: &'static str,
    status: &'static str,
    runtime_target: &'static str,
    control_effect: &'static str,
    command: &'static str,
    authority_boundary: &'static str,
    verification_gate: &'static str,
    proof_state: &'static str,
}

const WINDOWS_CLI_CAPABILITIES: &[CliCapability] = &[
    CliCapability {
        id: "device.discovery.nearby",
        status: "read_only_state_dir_supported",
        runtime_target: "windows_agent_owned_discovery_snapshot",
        control_effect: "agent_snapshot_read_only_projection",
        command: "skybridge device discover --nearby [--state-dir <dir>] [--scan] [--json]",
        authority_boundary: "The Windows core CLI can project an agent-owned nearby discovery snapshot from the operator state directory, but does not start DNS-SD browsing, synthesize peers, or treat discovery as peer authorization.",
        verification_gate: "Scripts/verify-windows-native-dns-sd-acceptance.ps1 with -RequirePeer before default enablement",
        proof_state: "discovery_snapshot_projected_not_connect_authorization",
    },
    CliCapability {
        id: "crossnet.preflight",
        status: "not_supported_on_windows_core_cli",
        runtime_target: "mac_app_runtime",
        control_effect: "read_only_not_available",
        command: "skybridge crossnet preflight [--json]",
        authority_boundary: "crossnet-control/1 is a Mac app-owned socket; Windows must not read or mutate Mac GUI state through this protocol.",
        verification_gate: "Mac signed app socket smoke; Windows interop uses separate current-path gates",
        proof_state: "mac_app_bound_only",
    },
    CliCapability {
        id: "crossnet.connect",
        status: "planned_fail_closed",
        runtime_target: "mac_app_runtime",
        control_effect: "mac_mutation_not_enabled",
        command: "skybridge crossnet connect <code> [--json]",
        authority_boundary: "Mac GUI mutation remains app-bound and unsupported by the Windows core CLI; native/headless success is not Mac product control.",
        verification_gate: "Mac crossnet-control/1 mutation smoke plus CrossNetworkConnectionManager observation",
        proof_state: "method_not_enabled_on_windows",
    },
    CliCapability {
        id: "native.connect",
        status: "planned_fail_closed",
        runtime_target: "future_windows_agent_state",
        control_effect: "native_mutation_contract_fail_closed",
        command: "skybridge connect <code> [--json]",
        authority_boundary: "The current Windows core CLI accepts the shared operator command shape but does not own a persistent Windows agent state directory or product session registry.",
        verification_gate: "future Windows SkyBridge CLI agent contract tests",
        proof_state: "operator_surface_missing",
    },
    CliCapability {
        id: "native.code.create",
        status: "planned_fail_closed",
        runtime_target: "future_windows_agent_state",
        control_effect: "native_mutation_contract_fail_closed",
        command: "skybridge code create [--device-name <name>] [--ttl-seconds <n>] [--json]",
        authority_boundary: "The Windows core CLI accepts the shared connection-code creation command shape, but does not register a code, write session state, or contact current-path signaling until a Windows agent owns registration and redacted code-publishing evidence.",
        verification_gate: "future Windows agent-owned connection-code registration gate",
        proof_state: "code_creation_not_enabled_on_windows_core_cli",
    },
    CliCapability {
        id: "native.code.current",
        status: "read_only_snapshot_supported",
        runtime_target: "windows_agent_owned_connection_code_snapshot",
        control_effect: "redacted_snapshot_projection",
        command: "skybridge code current [--snapshot <path>] [--json]",
        authority_boundary: "The Windows core CLI can validate a caller-provided connection-code snapshot as a read-only public status projection, but it redacts the raw code, raw session id, and local snapshot path from reports.",
        verification_gate: "future Windows agent-owned connection-code snapshot ownership and ACL gate",
        proof_state: "connection_code_snapshot_not_registration_proof",
    },
    CliCapability {
        id: "session.ls",
        status: "read_only_state_dir_supported",
        runtime_target: "windows_agent_owned_session_registry",
        control_effect: "redacted_agent_session_inventory_projection",
        command: "skybridge session ls [--state-dir <dir>] [--json]",
        authority_boundary: "The Windows core CLI can project a redacted session inventory from an agent-owned sessions.json registry, but it does not create sessions, disconnect sessions, or prove live runtime observation.",
        verification_gate: "future Windows agent-owned session registry ownership and ACL gate",
        proof_state: "session_inventory_not_live_runtime_proof",
    },
    CliCapability {
        id: "session.inspect",
        status: "read_only_state_dir_supported",
        runtime_target: "windows_agent_owned_session_registry",
        control_effect: "redacted_agent_session_projection",
        command: "skybridge session inspect [--state-dir <dir>] <id> [--json]",
        authority_boundary: "The inspect command accepts a caller-provided session id to find a registry entry but redacts the raw session id from reports; it is not a disconnect, reconnect, or product-control mutation.",
        verification_gate: "future Windows agent-owned session registry ownership and ACL gate",
        proof_state: "session_inventory_not_live_runtime_proof",
    },
    CliCapability {
        id: "session.import_product_control",
        status: "state_dir_mutation_supported_from_appcontrol_evidence",
        runtime_target: "windows_agent_owned_session_registry",
        control_effect: "upsert_established_product_control_session",
        command: "skybridge session import-product-control --state-dir <dir> --evidence <path> (--session-id <id>|--session-id-file <path>) --remote-device-id <id> [--target-runtime-id <id>] [--ttl-seconds <n>] [--json]",
        authority_boundary: "Imports only validated RuntimeSmoke AppControl ping/pong evidence into the core-owned session registry after session and peer hashes match; it does not prove file-transfer bytes, remote-desktop apply, or Mac product app observation.",
        verification_gate: "current-path product-control AppControl live gate followed by registry import and real-device file/remote gates",
        proof_state: "appcontrol_evidence_imported_not_live_file_or_remote_proof",
    },
    CliCapability {
        id: "session.disconnect",
        status: "planned_fail_closed",
        runtime_target: "future_windows_agent_state",
        control_effect: "native_mutation_contract_fail_closed",
        command: "skybridge disconnect <session-id> [--json]",
        authority_boundary: "The Windows core CLI accepts the shared disconnect command shape but does not mutate agent session state, tear down transport, or prove product-control disconnect until a Windows agent owns live sessions.",
        verification_gate: "future Windows agent-owned disconnect request and observation gate",
        proof_state: "disconnect_not_enabled_on_windows_core_cli",
    },
    CliCapability {
        id: "pqc.handshake",
        status: "read_only_diagnostic",
        runtime_target: "windows_protocol_diagnostic",
        control_effect: "read_only",
        command: "skybridge pqc status [--json]",
        authority_boundary: "Reports strict PQC suite-policy availability from Core only; it does not verify a peer identity, sign a handshake, derive session keys, create SBWC state, or authorize product control.",
        verification_gate: "current-path product-control AppControl live gate with ML-DSA verified handshake and established SBWC session",
        proof_state: "suite_negotiation_diagnostic_not_handshake_proof",
    },
    CliCapability {
        id: "file.transfer.send",
        status: "request_only_state_dir_supported",
        runtime_target: "product_control_secure_session",
        control_effect: "request_registry_pending_agent_observation",
        command: "skybridge file send --state-dir <dir> <path> --to <peer> --session-id <id> [--json]",
        authority_boundary: "The Windows core CLI can register a file-transfer request only against an agent-owned established product-control session registry; live transfer still requires agent observation, receiver write policy, transferred bytes, ACKs, and SHA-256 receipt evidence.",
        verification_gate: "real_device_file_transfer_gate with file_sha256_receipt",
        proof_state: "request_registered_not_live_transfer",
    },
    CliCapability {
        id: "remote_desktop.start",
        status: "request_only_state_dir_supported",
        runtime_target: "product_control_secure_session",
        control_effect: "request_registry_pending_agent_observation",
        command: "skybridge remote-desktop start --state-dir <dir> --session-id <id> [--resolution <preset>] [--fps <value>] [--json]",
        authority_boundary: "The Windows core CLI can register a request only against an agent-owned established product-control session registry; live apply still requires product remote-control policy, notice artifacts, capture/input/video data paths, and real-device performance evidence.",
        verification_gate: "real_device_p2p_remote_gate + remote_control_notice_artifact_gate + performance_p2p_remote_final_window_fps_gate",
        proof_state: "request_registered_not_live_apply",
    },
    CliCapability {
        id: "windows.protocol.discovery.parse",
        status: "available",
        runtime_target: "windows_protocol_diagnostic",
        control_effect: "read_only",
        command: "skybridge discovery parse --service <service> --txt <txt>",
        authority_boundary: "Parses Mac/iOS DNS-SD TXT shape and capability facts only; it does not browse the network or authorize a peer.",
        verification_gate: "core/skybridge-core/tests/cli_smoke.rs::cli_discovery_parse_accepts_mac_bonjour_txt",
        proof_state: "parser_only_not_peer_proof",
    },
    CliCapability {
        id: "windows.protocol.connection.plan",
        status: "available",
        runtime_target: "windows_protocol_diagnostic",
        control_effect: "read_only",
        command: "skybridge connection plan --local windows --remote <macos|ios> ...",
        authority_boundary: "Plans transport, suite, SBP2, and channel mappings through Core; it does not open sockets or prove a live peer.",
        verification_gate: "Scripts/verify-apple-native-preservation.ps1",
        proof_state: "plan_only_not_transport_proof",
    },
    CliCapability {
        id: "current_path.product_control.transport",
        status: "external_live_gate",
        runtime_target: "windows_product_runtime",
        control_effect: "transport_gate",
        command: "Scripts/verify-windows-current-path-product-control-transport-live.ps1",
        authority_boundary: "Transport-only evidence must keep NotHandshakeProof=true, NotAppControlProof=true, and NotMacProductAppProof=true.",
        verification_gate: "transport live gate with expected peer and current-path credentials",
        proof_state: "TransportOnly NotHandshakeProof NotAppControlProof NotMacProductAppProof",
    },
    CliCapability {
        id: "current_path.product_control.appcontrol",
        status: "external_live_gate",
        runtime_target: "windows_product_runtime",
        control_effect: "appcontrol_gate",
        command: "Scripts/verify-windows-current-path-product-control-appcontrol-live.ps1",
        authority_boundary: "AppControl proof requires current-path credentials, expected peer identity, explicit peer ML-KEM material, ML-DSA verified handshake, established SBWC session, and encrypted ping/pong; it still does not prove Mac product app observation or persisted peer trust.",
        verification_gate: "current-path product-control AppControl live gate",
        proof_state: "HandshakeEstablished AppControlReady NotMacProductAppProof PeerTrustPersistenceProof=false",
    },
];

pub fn run<I, S>(args: I, out: &mut impl Write, err: &mut impl Write) -> i32
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    match execute(args.into_iter().map(Into::into).collect(), out) {
        Ok(()) => 0,
        Err(message) => {
            let _ = writeln!(err, "{message}");
            2
        }
    }
}

fn execute(args: Vec<String>, out: &mut impl Write) -> Result<(), String> {
    if args.is_empty() || args == ["--help"] || args == ["-h"] {
        write!(out, "{HELP}").map_err(|err| err.to_string())?;
        return Ok(());
    }

    match args[0].as_str() {
        "version" => execute_version(&args[1..], out),
        "capabilities" => execute_capabilities(&args[1..], out),
        "device" => execute_device(&args[1..], out),
        "code" => execute_code(&args[1..], out),
        "connect" => execute_connect(&args[1..], out),
        "session" => execute_session(&args[1..], out),
        "disconnect" => execute_disconnect(&args[1..], out),
        "file" => execute_file(&args[1..], out),
        "evidence" => execute_evidence(&args[1..], out),
        "remote-desktop" => execute_remote_desktop(&args[1..], out),
        "transport" => execute_transport(&args[1..], out),
        "suite" => execute_suite(&args[1..], out),
        "pqc" => execute_pqc(&args[1..], out),
        "channel" => execute_channel(&args[1..], out),
        "frame" => execute_frame(&args[1..], out),
        "connection" => execute_connection(&args[1..], out),
        "discovery" => execute_discovery(&args[1..], out),
        "webrtc-proof" => execute_webrtc_proof(&args[1..], out),
        other => Err(format!("unknown command: {other}")),
    }
}

fn execute_version(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let as_json = match args {
        [] => false,
        [flag] if flag == "--json" => true,
        _ => return Err("expected version [--json]".into()),
    };

    if as_json {
        let payload = json!({
            "schema_version": CAPABILITY_SCHEMA_VERSION,
            "product_name": PRODUCT_NAME,
            "binary_name": BINARY_NAME,
            "cli_version": env!("CARGO_PKG_VERSION"),
            "workspace": "core/skybridge-core",
            "platform": WINDOWS_PLATFORM,
            "surface": WINDOWS_CLI_SURFACE,
            "contracts_schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
            "operator_command_parity": WINDOWS_OPERATOR_COMMAND_PARITY,
            "mac_gui_control_protocol": "crossnet-control/1",
            "mac_gui_control_supported": false,
            "ios_runtime_control_supported": false,
        });
        writeln!(out, "{}", json_string(payload)?).map_err(|err| err.to_string())?;
        return Ok(());
    }

    writeln!(out, "skybridge-core {}", env!("CARGO_PKG_VERSION")).map_err(|err| err.to_string())
}

fn execute_capabilities(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let as_json = match args {
        [] => false,
        [flag] if flag == "--json" => true,
        _ => return Err("expected capabilities [--json]".into()),
    };

    if as_json {
        let capabilities = WINDOWS_CLI_CAPABILITIES
            .iter()
            .map(|capability| {
                json!({
                    "id": capability.id,
                    "status": capability.status,
                    "runtime_target": capability.runtime_target,
                    "control_effect": capability.control_effect,
                    "command": capability.command,
                    "authority_boundary": capability.authority_boundary,
                    "verification_gate": capability.verification_gate,
                    "proof_state": capability.proof_state,
                })
            })
            .collect::<Vec<_>>();
        let payload = json!({
            "schema_version": CAPABILITY_SCHEMA_VERSION,
            "contracts_schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
            "product_name": PRODUCT_NAME,
            "binary_name": BINARY_NAME,
            "platform": WINDOWS_PLATFORM,
            "surface": WINDOWS_CLI_SURFACE,
            "operator_command_parity": WINDOWS_OPERATOR_COMMAND_PARITY,
            "mac_gui_control_protocol": "crossnet-control/1",
            "mac_gui_control_supported": false,
            "ios_runtime_control_supported": false,
            "capabilities": capabilities,
            "operator_gap_summary": operator_gap_summary(),
        });
        writeln!(
            out,
            "{}",
            serde_json::to_string_pretty(&payload).map_err(|err| err.to_string())?
        )
        .map_err(|err| err.to_string())?;
        return Ok(());
    }

    writeln!(
        out,
        "SkyBridge CLI Capability Contract v{CAPABILITY_SCHEMA_VERSION}"
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "binary_name={BINARY_NAME}").map_err(|err| err.to_string())?;
    writeln!(out, "platform={WINDOWS_PLATFORM}").map_err(|err| err.to_string())?;
    writeln!(out, "surface={WINDOWS_CLI_SURFACE}").map_err(|err| err.to_string())?;
    writeln!(
        out,
        "operator_command_parity={WINDOWS_OPERATOR_COMMAND_PARITY}"
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "mac_gui_control_protocol=crossnet-control/1").map_err(|err| err.to_string())?;
    writeln!(out, "mac_gui_control_supported=false").map_err(|err| err.to_string())?;
    writeln!(out, "ios_runtime_control_supported=false").map_err(|err| err.to_string())?;
    for capability in WINDOWS_CLI_CAPABILITIES {
        writeln!(
            out,
            "{} status={} target={} effect={} proof_state={} command={}",
            capability.id,
            capability.status,
            capability.runtime_target,
            capability.control_effect,
            capability.proof_state,
            capability.command
        )
        .map_err(|err| err.to_string())?;
    }
    Ok(())
}

fn operator_gap_summary() -> Vec<serde_json::Value> {
    vec![
        json!({
            "capability_id": "device.discovery.nearby",
            "command": "skybridge device discover --nearby [--state-dir <dir>] [--scan] [--json]",
            "current_state": "read_only_snapshot_projection",
            "live_proven": false,
            "proven_gates": ["fresh_agent_owned_discovery_snapshot_projection"],
            "missing_gates": DISCOVERY_REQUIRED_GATES,
            "next_verification": "Scripts/verify-windows-native-dns-sd-acceptance.ps1 -RequirePeer",
        }),
        json!({
            "capability_id": "native.connect",
            "command": "skybridge connect <code> [--json]",
            "current_state": "planned_fail_closed",
            "live_proven": false,
            "proven_gates": [],
            "missing_gates": CONNECT_REQUIRED_GATES,
            "next_verification": "future Windows agent-owned session registry plus current-path product-control AppControl live gate",
        }),
        json!({
            "capability_id": "native.code.create",
            "command": "skybridge code create [--device-name <name>] [--ttl-seconds <n>] [--json]",
            "current_state": "planned_fail_closed",
            "live_proven": false,
            "proven_gates": ["shared_command_shape"],
            "missing_gates": ["windows_agent_owned_connection_code_registration", "current_path_admission_register", "redacted_connection_code_publication"],
            "next_verification": "future Windows agent-owned connection-code registration gate with ConnectionCodeCaptured=false evidence",
        }),
        json!({
            "capability_id": "native.code.current",
            "command": "skybridge code current [--snapshot <path>] [--json]",
            "current_state": "read_only_redacted_snapshot_projection",
            "live_proven": false,
            "proven_gates": ["connection_code_snapshot_schema_validation", "raw_connection_code_redaction"],
            "missing_gates": ["windows_agent_owned_connection_code_snapshot", "current_path_registered_code_lifecycle_observation"],
            "next_verification": "future Windows agent-owned connection-code snapshot ownership and ACL gate",
        }),
        json!({
            "capability_id": "pqc.handshake",
            "command": "skybridge pqc status [--json]",
            "current_state": "suite_negotiation_diagnostic_only",
            "live_proven": false,
            "proven_gates": ["pqc_suite_policy_available"],
            "missing_gates": PQC_HANDSHAKE_MISSING_GATES,
            "next_verification": "Scripts/verify-windows-current-path-product-control-appcontrol-live.ps1 with ML-DSA verified handshake and established SBWC session",
        }),
        json!({
            "capability_id": "file.transfer.send",
            "command": "skybridge file send --state-dir <dir> <path> --to <peer> --session-id <id> [--json]",
            "current_state": "request_registry_pending_agent_observation",
            "live_proven": false,
            "proven_gates": ["request_registration_requires_established_product_control_session"],
            "missing_gates": FILE_TRANSFER_REQUIRED_GATES,
            "next_verification": "real_device_file_transfer_gate with transferred bytes and file_sha256_receipt",
        }),
        json!({
            "capability_id": "remote_desktop.start",
            "command": "skybridge remote-desktop start --state-dir <dir> --session-id <id> [--resolution <preset>] [--fps <value>] [--json]",
            "current_state": "request_registry_pending_agent_observation",
            "live_proven": false,
            "proven_gates": ["request_registration_requires_established_product_control_session"],
            "missing_gates": REMOTE_DESKTOP_REQUIRED_GATES,
            "next_verification": "real_device_p2p_remote_gate + remote_control_notice_artifact_gate + performance_p2p_remote_final_window_fps_gate",
        }),
        json!({
            "capability_id": "session.disconnect",
            "command": "skybridge disconnect <session-id> [--json]",
            "current_state": "planned_fail_closed",
            "live_proven": false,
            "proven_gates": ["shared_command_shape"],
            "missing_gates": ["windows_agent_owned_live_session", "disconnect_request_registry_or_runtime_apply", "agent_disconnect_observation"],
            "next_verification": "future Windows agent-owned disconnect request plus runtime observation gate",
        }),
    ]
}

fn execute_device(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let as_json = has_flag(args, "--json");
    let parsed = match parse_device_discover_args(args) {
        Ok(parsed) => parsed,
        Err(error) => {
            return fail_json_or_text(
                as_json,
                device_discovery_invalid_request_report(
                    has_flag(args, "--nearby"),
                    has_flag(args, "--scan"),
                    error.code,
                    error.message,
                ),
                error.message,
            );
        }
    };

    if !parsed.nearby_requested {
        return fail_json_or_text(
            parsed.as_json,
            device_discovery_invalid_request_report(
                false,
                parsed.active_scan_requested,
                "device_discovery_nearby_required",
                "pass --nearby to request nearby discovery",
            ),
            "pass --nearby to request nearby discovery",
        );
    }

    let Some(state_dir) = parsed.state_dir else {
        let (code, message, required_gate) = if parsed.active_scan_requested {
            (
                "device_discovery_active_scan_snapshot_missing",
                "active nearby device scan has no fresh Windows agent-owned scanner snapshot yet",
                "windows_agent_owned_discovery_scanner",
            )
        } else {
            (
                "device_discovery_snapshot_missing",
                "nearby device discovery has no trusted Windows agent-owned discovery snapshot yet",
                "windows_agent_owned_discovery_snapshot",
            )
        };
        return fail_json_or_text(
            parsed.as_json,
            device_discovery_rejected_report(
                parsed.nearby_requested,
                parsed.active_scan_requested,
                code,
                message,
                false,
                required_gate,
                "windows_core_cli_contract_only_no_agent_snapshot",
            ),
            "nearby device discovery requires a fresh Windows agent-owned DNS-SD snapshot; the core CLI must not synthesize peers",
        );
    };

    let snapshot = read_nearby_discovery_snapshot(state_dir, parsed.active_scan_requested)
        .map_err(|error| {
            device_discovery_operator_state_error(
                parsed.as_json,
                parsed.nearby_requested,
                parsed.active_scan_requested,
                error,
            )
        })?;
    let payload = device_discovery_snapshot_report(&snapshot, parsed.active_scan_requested)?;
    write_json_or_text(
        parsed.as_json,
        payload,
        "Nearby discovery snapshot loaded as a read-only projection; connection authorization is not granted.",
        out,
    )
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct DeviceDiscoverArgs<'a> {
    as_json: bool,
    nearby_requested: bool,
    active_scan_requested: bool,
    state_dir: Option<&'a str>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct DeviceDiscoverParseError {
    code: &'static str,
    message: &'static str,
}

fn parse_device_discover_args(
    args: &[String],
) -> Result<DeviceDiscoverArgs<'_>, DeviceDiscoverParseError> {
    if args.first().map(String::as_str) != Some("discover") {
        return Err(DeviceDiscoverParseError {
            code: "device_discovery_command_invalid",
            message: "expected device discover --nearby [--state-dir <dir>] [--scan] [--json]",
        });
    }

    let mut parsed = DeviceDiscoverArgs {
        as_json: false,
        nearby_requested: false,
        active_scan_requested: false,
        state_dir: None,
    };
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                if parsed.as_json {
                    return Err(DeviceDiscoverParseError {
                        code: "device_discovery_duplicate_option",
                        message: "device discovery received a duplicate option",
                    });
                }
                parsed.as_json = true;
                index += 1;
            }
            "--nearby" => {
                if parsed.nearby_requested {
                    return Err(DeviceDiscoverParseError {
                        code: "device_discovery_duplicate_option",
                        message: "device discovery received a duplicate option",
                    });
                }
                parsed.nearby_requested = true;
                index += 1;
            }
            "--scan" => {
                if parsed.active_scan_requested {
                    return Err(DeviceDiscoverParseError {
                        code: "device_discovery_duplicate_option",
                        message: "device discovery received a duplicate option",
                    });
                }
                parsed.active_scan_requested = true;
                index += 1;
            }
            "--state-dir" => {
                if parsed.state_dir.is_some() {
                    return Err(DeviceDiscoverParseError {
                        code: "device_discovery_duplicate_option",
                        message: "device discovery received a duplicate option",
                    });
                }
                let Some(value) = args.get(index + 1).map(String::as_str) else {
                    return Err(DeviceDiscoverParseError {
                        code: "device_discovery_state_dir_missing",
                        message: "device discovery --state-dir requires a value",
                    });
                };
                if value.starts_with("--") || value.trim().is_empty() {
                    return Err(DeviceDiscoverParseError {
                        code: "device_discovery_state_dir_missing",
                        message: "device discovery --state-dir requires a value",
                    });
                }
                parsed.state_dir = Some(value);
                index += 2;
            }
            value if value.starts_with("--") => {
                return Err(DeviceDiscoverParseError {
                    code: "device_discovery_unknown_option",
                    message: "device discovery received an unsupported option",
                });
            }
            _ => {
                return Err(DeviceDiscoverParseError {
                    code: "device_discovery_unexpected_argument",
                    message: "device discovery received an unexpected positional argument",
                });
            }
        }
    }
    Ok(parsed)
}

fn device_discovery_snapshot_report(
    read: &NearbyDiscoverySnapshotRead,
    active_scan_requested: bool,
) -> Result<serde_json::Value, String> {
    let snapshot = &read.snapshot;
    Ok(json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": "device.discovery.nearby",
        "accepted": true,
        "status": "read_only",
        "nearby_requested": true,
        "active_scan_requested": active_scan_requested,
        "active_scan_started": false,
        "mutation_supported": false,
        "source": &snapshot.source,
        "scan_id": &snapshot.scan_id,
        "observed_at": snapshot.observed_at.format(&Rfc3339).map_err(|err| err.to_string())?,
        "expires_at": snapshot.expires_at.format(&Rfc3339).map_err(|err| err.to_string())?,
        "updated_at": snapshot.updated_at.format(&Rfc3339).map_err(|err| err.to_string())?,
        "snapshots_total": read.snapshots_total,
        "devices_returned": snapshot.devices.len(),
        "devices": snapshot
            .devices
            .iter()
            .map(device_discovery_device_report)
            .collect::<Vec<_>>(),
        "snapshot_authorizes_connection": false,
        "session_created": false,
        "connect_supported": false,
        "error": serde_json::Value::Null,
        "proof_boundary": {
            "snapshot_projected": true,
            "active_scan_started": false,
            "snapshot_authorizes_connection": false,
            "connection_authorized": false,
            "session_created": false,
            "pqc_handshake_proof": false,
            "file_transfer_proof": false,
            "remote_desktop_proof": false,
        },
        "required_gates_before_results": DISCOVERY_REQUIRED_GATES,
        "required_gates_before_connect": DISCOVERY_CONNECT_GATES,
    }))
}

fn device_discovery_device_report(device: &NearbyDiscoveredDevice) -> serde_json::Value {
    json!({
        "device_ref": &device.device_ref,
        "display_name": &device.display_name,
        "endpoint_class": device.endpoint_class.as_str(),
        "trust_status": device.trust_status.as_str(),
        "capabilities": &device.capabilities,
        "connectable": device.connectable,
        "connection_authorized": false,
    })
}

fn device_discovery_invalid_request_report(
    nearby_requested: bool,
    active_scan_requested: bool,
    code: &'static str,
    message: &'static str,
) -> serde_json::Value {
    device_discovery_rejected_report(
        nearby_requested,
        active_scan_requested,
        code,
        message,
        false,
        "device_discovery_request_contract",
        "windows_core_cli_request_contract_validation",
    )
}

fn device_discovery_operator_state_error(
    as_json: bool,
    nearby_requested: bool,
    active_scan_requested: bool,
    error: OperatorStateError,
) -> String {
    let (code, retryable, message, required_gate) =
        device_discovery_operator_state_error_fields(error);
    if as_json {
        return json_string(device_discovery_rejected_report(
            nearby_requested,
            active_scan_requested,
            code,
            message,
            retryable,
            required_gate,
            "windows_operator_state_nearby_discovery_snapshot_registry",
        ))
        .unwrap_or_else(|_| message.to_string());
    }
    message.to_string()
}

fn device_discovery_operator_state_error_fields(
    error: OperatorStateError,
) -> (&'static str, bool, &'static str, &'static str) {
    match error {
        OperatorStateError::MissingStateDir => (
            "device_discovery_state_dir_missing",
            false,
            "device discovery requires an operator state directory",
            "windows_operator_state_directory",
        ),
        OperatorStateError::StateDirUnavailable | OperatorStateError::StateDirNotDirectory => (
            "device_discovery_state_dir_unavailable",
            false,
            "device discovery operator state directory is unavailable",
            "windows_operator_state_directory",
        ),
        OperatorStateError::UnsafePath => (
            "device_discovery_state_dir_unsafe",
            false,
            "device discovery operator state path contains an unsafe path component",
            "windows_operator_state_directory",
        ),
        OperatorStateError::NearbyDiscoverySnapshotMissing
        | OperatorStateError::SessionRegistryMissing => (
            "device_discovery_snapshot_missing",
            false,
            "nearby device discovery has no trusted Windows agent-owned discovery snapshot yet",
            "windows_agent_owned_discovery_snapshot",
        ),
        OperatorStateError::NearbyDiscoveryActiveScanSnapshotMissing => (
            "device_discovery_active_scan_snapshot_missing",
            false,
            "active nearby device scan has no fresh Windows agent-owned scanner snapshot yet",
            "windows_agent_owned_discovery_scanner",
        ),
        OperatorStateError::NearbyDiscoverySnapshotStale => (
            "device_discovery_snapshot_stale",
            true,
            "nearby device discovery snapshot is stale",
            "freshness_window_validation",
        ),
        OperatorStateError::NearbyDiscoveryActiveScanSnapshotStale => (
            "device_discovery_active_scan_snapshot_stale",
            true,
            "active nearby device scan snapshot is stale",
            "freshness_window_validation",
        ),
        OperatorStateError::NearbyDiscoverySnapshotRegistryTooLarge => (
            "device_discovery_snapshot_registry_too_large",
            false,
            "nearby discovery snapshot registry exceeds the maximum supported size",
            "windows_agent_owned_discovery_snapshot",
        ),
        OperatorStateError::NearbyDiscoverySnapshotRegistryRead
        | OperatorStateError::RegistryLocked => (
            "device_discovery_snapshot_registry_unreadable",
            true,
            "nearby discovery snapshot registry could not be read",
            "windows_agent_owned_discovery_snapshot",
        ),
        OperatorStateError::NearbyDiscoverySnapshotRegistryJson
        | OperatorStateError::NearbyDiscoverySnapshotRegistrySchema
        | OperatorStateError::NearbyDiscoverySnapshotRegistryInvalid => (
            "device_discovery_snapshot_registry_invalid",
            false,
            "nearby discovery snapshot registry is invalid",
            "windows_agent_owned_discovery_snapshot",
        ),
        OperatorStateError::Clock => (
            "device_discovery_clock_invalid",
            true,
            "system clock cannot be used for discovery snapshot freshness validation",
            "freshness_window_validation",
        ),
        OperatorStateError::SessionRegistryRead
        | OperatorStateError::SessionRegistryJson
        | OperatorStateError::SessionRegistrySchema
        | OperatorStateError::SessionRegistryInvalid
        | OperatorStateError::SessionRegistryTooLarge
        | OperatorStateError::InvalidSessionBinding
        | OperatorStateError::SessionBindingConflict
        | OperatorStateError::SessionRegistryWrite
        | OperatorStateError::SessionRegistryPersistVerify
        | OperatorStateError::SessionNotFound
        | OperatorStateError::SessionNotEstablished
        | OperatorStateError::SessionStale
        | OperatorStateError::RequestRegistryRead
        | OperatorStateError::RequestRegistryJson
        | OperatorStateError::RequestRegistrySchema
        | OperatorStateError::RequestRegistryInvalid
        | OperatorStateError::InvalidRequestPayload
        | OperatorStateError::PendingRequestExists
        | OperatorStateError::RequestRegistryFull
        | OperatorStateError::RequestRegistryWrite
        | OperatorStateError::RequestRegistryPersistVerify
        | OperatorStateError::FileTransferRequestRegistryRead
        | OperatorStateError::FileTransferRequestRegistryJson
        | OperatorStateError::FileTransferRequestRegistrySchema
        | OperatorStateError::FileTransferRequestRegistryInvalid
        | OperatorStateError::InvalidPeerRef
        | OperatorStateError::PeerBindingMissing
        | OperatorStateError::PeerMismatch
        | OperatorStateError::FileTransferSourceMissing
        | OperatorStateError::FileTransferSourceUnsafe
        | OperatorStateError::FileTransferSourceNotRegularFile
        | OperatorStateError::FileTransferSourceRead
        | OperatorStateError::FileTransferHashFailed
        | OperatorStateError::FileTransferRequestRegistryWrite
        | OperatorStateError::FileTransferRequestRegistryPersistVerify => (
            "device_discovery_snapshot_registry_invalid",
            false,
            "nearby discovery snapshot registry is invalid",
            "windows_agent_owned_discovery_snapshot",
        ),
    }
}

fn device_discovery_rejected_report(
    nearby_requested: bool,
    active_scan_requested: bool,
    code: &'static str,
    message: &'static str,
    retryable: bool,
    required_gate: &'static str,
    source: &'static str,
) -> serde_json::Value {
    json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": "device.discovery.nearby",
        "accepted": false,
        "status": "read_only_rejected",
        "nearby_requested": nearby_requested,
        "active_scan_requested": active_scan_requested,
        "active_scan_started": false,
        "mutation_supported": false,
        "source": source,
        "devices_returned": 0,
        "devices": [],
        "snapshot_authorizes_connection": false,
        "session_created": false,
        "connect_supported": false,
        "error": {
            "code": code,
            "message": message,
            "retryable": retryable,
            "required_gate": required_gate,
        },
        "required_gates_before_results": DISCOVERY_REQUIRED_GATES,
        "required_gates_before_connect": DISCOVERY_CONNECT_GATES,
    })
}

fn execute_code(args: &[String], out: &mut impl Write) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("create") => execute_code_create(args, out),
        Some("current") => execute_code_current(args, out),
        _ => Err("expected code create or code current".into()),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CodeCreateArgs<'a> {
    as_json: bool,
    device_name: Option<&'a str>,
    ttl_seconds: i64,
}

fn execute_code_create(args: &[String], _out: &mut impl Write) -> Result<(), String> {
    let parsed = parse_code_create_args(args)?;
    fail_json_or_text(
        parsed.as_json,
        json!({
            "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
            "capability_id": "native.code.create",
            "action": "code_create",
            "accepted": false,
            "status": "planned_fail_closed",
            "mutation_supported": false,
            "live_runtime_started": false,
            "device_name_provided": parsed.device_name.is_some(),
            "ttl_seconds_requested": parsed.ttl_seconds,
            "code_created": false,
            "connection_code_captured": false,
            "windows_agent_state_available": false,
            "proof_state": "code_creation_not_enabled_on_windows_core_cli",
            "error": {
                "code": "windows_operator_code_create_not_wired",
                "message": "Windows core CLI does not own connection-code registration state or current-path signaling runtime",
                "retryable": false,
                "required_gate": "windows_agent_owned_connection_code_registration",
            },
        }),
        "Windows operator code creation is not wired in the core CLI; connection-code registration requires a Windows agent and current-path admission gate",
    )
}

fn parse_code_create_args(args: &[String]) -> Result<CodeCreateArgs<'_>, String> {
    let mut parsed = CodeCreateArgs {
        as_json: false,
        device_name: None,
        ttl_seconds: 300,
    };
    let mut ttl_seconds_seen = false;
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                if parsed.as_json {
                    return Err("duplicate --json".into());
                }
                parsed.as_json = true;
                index += 1;
            }
            "--device-name" => {
                if parsed.device_name.is_some() {
                    return Err("duplicate --device-name".into());
                }
                let value = required_flag_value(args, index, "--device-name")?;
                if value.trim().is_empty() {
                    return Err("device name must not be empty".into());
                }
                parsed.device_name = Some(value);
                index += 2;
            }
            "--ttl-seconds" => {
                if ttl_seconds_seen {
                    return Err("duplicate --ttl-seconds".into());
                }
                let value = required_flag_value(args, index, "--ttl-seconds")?;
                parsed.ttl_seconds = value
                    .parse::<i64>()
                    .map_err(|_| "invalid --ttl-seconds".to_owned())?;
                if parsed.ttl_seconds <= 0 {
                    return Err("--ttl-seconds must be positive".into());
                }
                ttl_seconds_seen = true;
                index += 2;
            }
            value if value.starts_with("--") => {
                return Err(format!("unsupported code create option: {value}"));
            }
            _ => return Err("code create does not accept positional arguments".into()),
        }
    }
    Ok(parsed)
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CodeCurrentArgs<'a> {
    as_json: bool,
    snapshot: Option<&'a str>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ConnectionCodeSnapshotSummary {
    code_ref: String,
    code_present: bool,
    session_id_present: bool,
    expires_at: Option<String>,
    expired: bool,
    lease_mode: Option<String>,
    device_id_present: bool,
    protocol_public_key_fingerprint_present: bool,
    generated_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ConnectionCodeSnapshotError {
    MissingSnapshotPath,
    Missing,
    UnsafePath,
    NotRegularFile,
    TooLarge,
    Read,
    Json,
    Schema,
    Incomplete,
    InvalidExpiry,
    Expired,
}

fn execute_code_current(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let parsed = parse_code_current_args(args)?;
    let Some(snapshot_path) = parsed.snapshot else {
        return fail_json_or_text(
            parsed.as_json,
            connection_code_snapshot_error_payload(ConnectionCodeSnapshotError::MissingSnapshotPath),
            "connection code current requires --snapshot with an agent-owned snapshot path on Windows",
        );
    };
    let summary = read_connection_code_snapshot_summary(snapshot_path)
        .map_err(|error| connection_code_snapshot_error(parsed.as_json, error))?;
    let payload = json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": "native.code.current",
        "status": "snapshot_available",
        "snapshot_supported": true,
        "mutation_supported": false,
        "live_runtime_started": false,
        "code_present": summary.code_present,
        "code_ref": summary.code_ref,
        "session_id_present": summary.session_id_present,
        "expires_at": summary.expires_at,
        "expired": summary.expired,
        "lease_mode": summary.lease_mode,
        "device_id_present": summary.device_id_present,
        "protocol_public_key_fingerprint_present": summary.protocol_public_key_fingerprint_present,
        "generated_at": summary.generated_at,
        "source": "windows_connection_code_snapshot",
        "proof_boundary": {
            "connection_code_snapshot_not_registration_proof": true,
            "raw_connection_code_redacted": true,
            "raw_session_id_redacted": true,
            "snapshot_path_redacted": true,
        },
    });
    write_json_or_text(
        parsed.as_json,
        payload,
        "Connection code snapshot is present and unexpired; raw code and session id are redacted.",
        out,
    )
}

fn parse_code_current_args(args: &[String]) -> Result<CodeCurrentArgs<'_>, String> {
    let mut parsed = CodeCurrentArgs {
        as_json: false,
        snapshot: None,
    };
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                if parsed.as_json {
                    return Err("duplicate --json".into());
                }
                parsed.as_json = true;
                index += 1;
            }
            "--snapshot" => {
                if parsed.snapshot.is_some() {
                    return Err("duplicate --snapshot".into());
                }
                let value = required_flag_value(args, index, "--snapshot")?;
                if value.trim().is_empty() {
                    return Err("snapshot path must not be empty".into());
                }
                parsed.snapshot = Some(value);
                index += 2;
            }
            value if value.starts_with("--") => {
                return Err(format!("unsupported code current option: {value}"));
            }
            _ => return Err("code current does not accept positional arguments".into()),
        }
    }
    Ok(parsed)
}

fn read_connection_code_snapshot_summary(
    snapshot_path: &str,
) -> Result<ConnectionCodeSnapshotSummary, ConnectionCodeSnapshotError> {
    let path = Path::new(snapshot_path);
    reject_unsafe_path_components(path).map_err(|_| ConnectionCodeSnapshotError::UnsafePath)?;
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(ConnectionCodeSnapshotError::Missing);
        }
        Err(_) => return Err(ConnectionCodeSnapshotError::Read),
    };
    if metadata_is_unsafe(&metadata) {
        return Err(ConnectionCodeSnapshotError::UnsafePath);
    }
    if !metadata.is_file() {
        return Err(ConnectionCodeSnapshotError::NotRegularFile);
    }
    if metadata.len() > MAX_CONNECTION_CODE_SNAPSHOT_BYTES {
        return Err(ConnectionCodeSnapshotError::TooLarge);
    }

    let mut file = File::open(path).map_err(|_| ConnectionCodeSnapshotError::Read)?;
    let metadata = file
        .metadata()
        .map_err(|_| ConnectionCodeSnapshotError::Read)?;
    if !metadata.is_file() {
        return Err(ConnectionCodeSnapshotError::NotRegularFile);
    }
    if metadata.len() > MAX_CONNECTION_CODE_SNAPSHOT_BYTES {
        return Err(ConnectionCodeSnapshotError::TooLarge);
    }

    let mut body = String::new();
    file.read_to_string(&mut body)
        .map_err(|_| ConnectionCodeSnapshotError::Read)?;
    let snapshot = serde_json::from_str::<serde_json::Value>(&body)
        .map_err(|_| ConnectionCodeSnapshotError::Json)?;
    if snapshot
        .get("schemaVersion")
        .and_then(|value| value.as_u64())
        != Some(1)
    {
        return Err(ConnectionCodeSnapshotError::Schema);
    }
    let code = snapshot
        .get("code")
        .and_then(|value| value.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or(ConnectionCodeSnapshotError::Incomplete)?;
    let session_id_present = snapshot
        .get("sessionId")
        .and_then(|value| value.as_str())
        .map(str::trim)
        .is_some_and(|value| !value.is_empty());
    if !session_id_present {
        return Err(ConnectionCodeSnapshotError::Incomplete);
    }
    let expires_at = snapshot
        .get("expiresAt")
        .and_then(|value| value.as_str())
        .map(str::to_owned);
    let expired = if let Some(expires_at) = expires_at.as_deref() {
        let parsed = OffsetDateTime::parse(expires_at, &Rfc3339)
            .map_err(|_| ConnectionCodeSnapshotError::InvalidExpiry)?;
        parsed <= OffsetDateTime::now_utc()
    } else {
        false
    };
    if expired {
        return Err(ConnectionCodeSnapshotError::Expired);
    }

    Ok(ConnectionCodeSnapshotSummary {
        code_ref: short_hash_ref("code", code),
        code_present: true,
        session_id_present,
        expires_at,
        expired,
        lease_mode: snapshot
            .get("leaseMode")
            .and_then(|value| value.as_str())
            .map(str::to_owned),
        device_id_present: snapshot
            .get("deviceId")
            .and_then(|value| value.as_str())
            .map(str::trim)
            .is_some_and(|value| !value.is_empty()),
        protocol_public_key_fingerprint_present: snapshot
            .get("protocolPublicKeyFingerprint")
            .and_then(|value| value.as_str())
            .map(str::trim)
            .is_some_and(|value| !value.is_empty()),
        generated_at: snapshot
            .get("generatedAt")
            .and_then(|value| value.as_str())
            .map(str::to_owned),
    })
}

fn connection_code_snapshot_error(as_json: bool, error: ConnectionCodeSnapshotError) -> String {
    let payload = connection_code_snapshot_error_payload(error.clone());
    if as_json {
        return json_string(payload).unwrap_or_else(|_| connection_code_snapshot_error_text(error));
    }
    connection_code_snapshot_error_text(error)
}

fn connection_code_snapshot_error_payload(error: ConnectionCodeSnapshotError) -> serde_json::Value {
    let (code, message, retryable, required_gate) = connection_code_snapshot_error_fields(error);
    json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": "native.code.current",
        "accepted": false,
        "status": "snapshot_rejected",
        "snapshot_supported": true,
        "mutation_supported": false,
        "live_runtime_started": false,
        "code_present": false,
        "session_id_present": false,
        "retryable": retryable,
        "error": {
            "code": code,
            "message": message,
            "retryable": retryable,
            "required_gate": required_gate,
        },
        "proof_boundary": {
            "connection_code_snapshot_not_registration_proof": true,
            "raw_connection_code_redacted": true,
            "raw_session_id_redacted": true,
            "snapshot_path_redacted": true,
        },
    })
}

fn connection_code_snapshot_error_text(error: ConnectionCodeSnapshotError) -> String {
    let (_, message, _, _) = connection_code_snapshot_error_fields(error);
    message.to_owned()
}

fn connection_code_snapshot_error_fields(
    error: ConnectionCodeSnapshotError,
) -> (&'static str, &'static str, bool, &'static str) {
    match error {
        ConnectionCodeSnapshotError::MissingSnapshotPath => (
            "connection_code_snapshot_path_missing",
            "connection code current requires a snapshot path",
            false,
            "windows_agent_owned_connection_code_snapshot",
        ),
        ConnectionCodeSnapshotError::Missing => (
            "connection_code_snapshot_missing",
            "connection code snapshot is missing",
            false,
            "windows_agent_owned_connection_code_snapshot",
        ),
        ConnectionCodeSnapshotError::UnsafePath => (
            "connection_code_snapshot_unsafe",
            "connection code snapshot path contains a symlink or reparse point",
            false,
            "windows_agent_owned_connection_code_snapshot",
        ),
        ConnectionCodeSnapshotError::NotRegularFile => (
            "connection_code_snapshot_not_regular_file",
            "connection code snapshot is not a regular file",
            false,
            "windows_agent_owned_connection_code_snapshot",
        ),
        ConnectionCodeSnapshotError::TooLarge => (
            "connection_code_snapshot_too_large",
            "connection code snapshot exceeds the maximum supported size",
            false,
            "windows_agent_owned_connection_code_snapshot",
        ),
        ConnectionCodeSnapshotError::Read => (
            "connection_code_snapshot_unreadable",
            "connection code snapshot could not be read",
            false,
            "windows_agent_owned_connection_code_snapshot",
        ),
        ConnectionCodeSnapshotError::Json
        | ConnectionCodeSnapshotError::Schema
        | ConnectionCodeSnapshotError::Incomplete => (
            "connection_code_snapshot_invalid",
            "connection code snapshot is invalid",
            false,
            "windows_agent_owned_connection_code_snapshot",
        ),
        ConnectionCodeSnapshotError::InvalidExpiry => (
            "connection_code_snapshot_invalid_expiry",
            "connection code snapshot expiry is invalid",
            false,
            "windows_agent_owned_connection_code_snapshot",
        ),
        ConnectionCodeSnapshotError::Expired => (
            "connection_code_snapshot_expired",
            "connection code snapshot is expired",
            false,
            "windows_agent_owned_connection_code_snapshot",
        ),
    }
}

fn short_hash_ref(prefix: &str, secret: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(secret.as_bytes());
    let digest = hasher.finalize();
    let mut suffix = String::with_capacity(16);
    for byte in digest.iter().take(8) {
        let _ = write!(&mut suffix, "{byte:02x}");
    }
    format!("{prefix}-{suffix}")
}

fn execute_connect(args: &[String], _out: &mut impl Write) -> Result<(), String> {
    let as_json = has_flag(args, "--json");
    let code_provided = args
        .iter()
        .any(|value| value != "--json" && !value.starts_with("--") && !value.trim().is_empty());
    if !code_provided && !as_json {
        return Err("expected connect <code> [--json]".into());
    }

    fail_json_or_text(
        as_json,
        json!({
            "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
            "capability_id": "native.connect",
            "action": "connect",
            "accepted": false,
            "status": "planned_fail_closed",
            "mutation_supported": false,
            "code_provided": code_provided,
            "session_created": false,
            "windows_agent_state_available": false,
            "mac_gui_control_supported": false,
            "proof_state": "operator_surface_missing",
            "error": {
                "code": "windows_operator_connect_not_wired",
                "message": "Windows core CLI does not own a product session registry or current-path/native signaling runtime",
                "retryable": false,
                "required_gate": "windows_agent_state_registry",
            },
            "required_gates_before_session": CONNECT_REQUIRED_GATES,
        }),
        "Windows operator connect is not wired in the core CLI; product session creation requires a Windows agent state registry and verified product-control handshake",
    )
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct DisconnectArgs {
    as_json: bool,
    session_id_provided: bool,
}

fn parse_disconnect_args(args: &[String]) -> Result<DisconnectArgs, String> {
    let mut parsed = DisconnectArgs {
        as_json: false,
        session_id_provided: false,
    };
    for arg in args {
        match arg.as_str() {
            "--json" => {
                if parsed.as_json {
                    return Err("duplicate --json".into());
                }
                parsed.as_json = true;
            }
            value if value.starts_with("--") => {
                return Err(format!("unsupported disconnect option: {value}"));
            }
            value if value.trim().is_empty() => {
                return Err("disconnect session id must not be empty".into());
            }
            _ => {
                if parsed.session_id_provided {
                    return Err("disconnect accepts exactly one session id".into());
                }
                parsed.session_id_provided = true;
            }
        }
    }
    Ok(parsed)
}

fn execute_disconnect(args: &[String], _out: &mut impl Write) -> Result<(), String> {
    let parsed = parse_disconnect_args(args)?;
    if !parsed.session_id_provided && !parsed.as_json {
        return Err("expected disconnect <session-id> [--json]".into());
    }

    fail_json_or_text(
        parsed.as_json,
        json!({
            "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
            "capability_id": "session.disconnect",
            "action": "disconnect",
            "accepted": false,
            "status": "planned_fail_closed",
            "mutation_supported": false,
            "live_runtime_started": false,
            "session_id_provided": parsed.session_id_provided,
            "session_disconnected": false,
            "windows_agent_state_available": false,
            "proof_state": "disconnect_not_enabled_on_windows_core_cli",
            "error": {
                "code": "windows_operator_disconnect_not_wired",
                "message": "Windows core CLI does not own a live agent session runtime for disconnect",
                "retryable": false,
                "required_gate": "windows_agent_owned_live_session",
            },
        }),
        "Windows operator disconnect is not wired in the core CLI; disconnect requires a Windows agent-owned live session runtime",
    )
}

fn execute_session(args: &[String], out: &mut impl Write) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("ls") => execute_session_ls(args, out),
        Some("inspect") => execute_session_inspect(args, out),
        Some("import-product-control") => execute_session_import_product_control(args, out),
        _ => Err("expected session ls, session inspect, or session import-product-control".into()),
    }
}

fn execute_session_ls(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let parsed = parse_session_args(args, false)?;
    if let Some(state_dir) = parsed.state_dir {
        let snapshot = read_session_inventory(state_dir, None)
            .map_err(|error| session_operator_state_error(parsed.as_json, "session.ls", error))?;
        let payload = session_inventory_report(&snapshot);
        return write_json_or_text(
            parsed.as_json,
            payload,
            "Session inventory loaded from the Windows operator session registry; raw session ids are redacted.",
            out,
        );
    }

    let payload = json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": "session.ls",
        "status": "planned_fail_closed",
        "session_registry_supported": false,
        "mutation_supported": false,
        "live_runtime_started": false,
        "sessions_total": 0,
        "sessions": [],
        "source": "windows_core_cli_contract_only_no_agent_registry",
        "proof_boundary": {
            "session_inventory_not_live_runtime_proof": true,
            "raw_session_ids_redacted": true,
        },
        "required_gate": "windows_agent_owned_session_registry",
    });
    write_json_or_text(
        parsed.as_json,
        payload,
        "Session inventory requires --state-dir with an agent-owned Windows session registry.",
        out,
    )
}

fn execute_session_inspect(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let parsed = parse_session_args(args, true)?;
    let as_json = parsed.as_json;
    let Some(session_id) = parsed.session_id else {
        return fail_json_or_text(
            as_json,
            session_invalid_request_report("session_id_required", "session inspect requires <id>"),
            "session inspect requires <id>",
        );
    };
    let Some(state_dir) = parsed.state_dir else {
        return fail_json_or_text(
            as_json,
            session_operator_state_error_payload(
                "session.inspect",
                "session_state_dir_missing",
                false,
                "session inspect requires an operator state directory",
                "windows_agent_owned_session_registry",
            ),
            "session inspect requires --state-dir",
        );
    };

    let snapshot = read_session_inventory(state_dir, Some(session_id))
        .map_err(|error| session_operator_state_error(as_json, "session.inspect", error))?;
    let session = snapshot.sessions.first().ok_or_else(|| {
        session_operator_state_error(
            as_json,
            "session.inspect",
            OperatorStateError::SessionNotFound,
        )
    })?;
    let payload = json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": "session.inspect",
        "status": "session_found",
        "session_found": true,
        "session_registry_supported": true,
        "mutation_supported": false,
        "live_runtime_started": false,
        "source": "windows_operator_state_session_registry",
        "session": session_summary_report(session),
        "proof_boundary": {
            "session_inventory_not_live_runtime_proof": true,
            "raw_session_ids_redacted": true,
        },
    });
    write_json_or_text(
        as_json,
        payload,
        "Session entry found in the Windows operator session registry; raw session id is redacted.",
        out,
    )
}

fn execute_session_import_product_control(
    args: &[String],
    out: &mut impl Write,
) -> Result<(), String> {
    let parsed = parse_session_import_product_control_args(args)?;
    let as_json = parsed.as_json;
    let Some(state_dir) = parsed.state_dir else {
        return fail_json_or_text(
            as_json,
            session_import_invalid_request_report(
                "session_import_state_dir_required",
                "session import requires --state-dir",
            ),
            "session import requires --state-dir",
        );
    };
    let Some(evidence_path) = parsed.evidence_path else {
        return fail_json_or_text(
            as_json,
            session_import_invalid_request_report(
                "session_import_evidence_required",
                "session import requires --evidence",
            ),
            "session import requires --evidence",
        );
    };
    if parsed.session_id.is_some() && parsed.session_id_file.is_some() {
        return fail_json_or_text(
            as_json,
            session_import_invalid_request_report(
                "session_import_session_id_ambiguous",
                "session import accepts exactly one of --session-id or --session-id-file",
            ),
            "session import accepts exactly one of --session-id or --session-id-file",
        );
    }
    let session_id_from_file;
    let session_id_file_used = parsed.session_id_file.is_some();
    let session_id = match (parsed.session_id, parsed.session_id_file) {
        (Some(value), None) => value,
        (None, Some(path)) => {
            session_id_from_file = read_session_import_secret_file(path, as_json)?;
            session_id_from_file.as_str()
        }
        (None, None) => {
            return fail_json_or_text(
                as_json,
                session_import_invalid_request_report(
                    "session_import_session_id_required",
                    "session import requires --session-id or --session-id-file",
                ),
                "session import requires --session-id or --session-id-file",
            );
        }
        (Some(_), Some(_)) => unreachable!("ambiguous session id sources are rejected above"),
    };
    let Some(remote_device_id) = parsed.remote_device_id else {
        return fail_json_or_text(
            as_json,
            session_import_invalid_request_report(
                "session_import_remote_device_id_required",
                "session import requires --remote-device-id",
            ),
            "session import requires --remote-device-id",
        );
    };
    let target_runtime_id = parsed
        .target_runtime_id
        .unwrap_or(SESSION_IMPORT_DEFAULT_TARGET_RUNTIME_ID);
    let ttl_seconds = parsed
        .ttl_seconds
        .map(|value| parse_u64(value, "--ttl-seconds"))
        .transpose()?
        .unwrap_or(SESSION_IMPORT_DEFAULT_TTL_SECONDS);
    let expires_at_unix_ms = expires_at_unix_ms_from_ttl_seconds(ttl_seconds)?;

    let summary = read_product_control_evidence(evidence_path).map_err(|error| {
        product_control_evidence_error(as_json, "session.import_product_control.evidence", error)
    })?;
    validate_product_control_evidence_for_session_import(
        &summary,
        session_id,
        remote_device_id,
        as_json,
    )?;

    let registration = register_established_product_control_session(
        state_dir,
        session_id,
        target_runtime_id,
        remote_device_id,
        summary
            .remote_protocol_public_key_fingerprint
            .as_deref()
            .ok_or_else(|| {
                json_or_text_session_import_invalid_request(
                    as_json,
                    "session_import_remote_fingerprint_missing",
                    "product-control evidence is missing RemoteProtocolPublicKeyFingerprint",
                )
            })?,
        expires_at_unix_ms,
    )
    .map_err(|error| session_import_operator_state_error(as_json, error))?;

    let payload = session_import_success_report(
        &registration,
        parsed.target_runtime_id.is_some(),
        session_id_file_used,
        ttl_seconds,
    );
    write_json_or_text(
        as_json,
        payload,
        "Product-control AppControl evidence imported into the Windows operator session registry; raw identifiers are redacted.",
        out,
    )
}

struct SessionArgs<'a> {
    as_json: bool,
    state_dir: Option<&'a str>,
    session_id: Option<&'a str>,
}

fn parse_session_args(
    args: &[String],
    expects_session_id: bool,
) -> Result<SessionArgs<'_>, String> {
    let mut parsed = SessionArgs {
        as_json: false,
        state_dir: None,
        session_id: None,
    };
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                if parsed.as_json {
                    return Err("duplicate --json".into());
                }
                parsed.as_json = true;
                index += 1;
            }
            "--state-dir" => {
                if parsed.state_dir.is_some() {
                    return Err("duplicate --state-dir".into());
                }
                parsed.state_dir = Some(required_flag_value(args, index, "--state-dir")?);
                index += 2;
            }
            value if value.starts_with("--") => {
                return Err(format!("unsupported session option: {value}"));
            }
            value => {
                if !expects_session_id {
                    return Err("session ls does not accept a positional argument".into());
                }
                if parsed.session_id.is_some() {
                    return Err("session inspect accepts exactly one session id".into());
                }
                if value.trim().is_empty() {
                    return Err("session inspect requires <id>".into());
                }
                parsed.session_id = Some(value);
                index += 1;
            }
        }
    }
    Ok(parsed)
}

struct SessionImportProductControlArgs<'a> {
    as_json: bool,
    state_dir: Option<&'a str>,
    evidence_path: Option<&'a str>,
    session_id: Option<&'a str>,
    session_id_file: Option<&'a str>,
    remote_device_id: Option<&'a str>,
    target_runtime_id: Option<&'a str>,
    ttl_seconds: Option<&'a str>,
}

fn parse_session_import_product_control_args(
    args: &[String],
) -> Result<SessionImportProductControlArgs<'_>, String> {
    let mut parsed = SessionImportProductControlArgs {
        as_json: false,
        state_dir: None,
        evidence_path: None,
        session_id: None,
        session_id_file: None,
        remote_device_id: None,
        target_runtime_id: None,
        ttl_seconds: None,
    };
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                if parsed.as_json {
                    return Err("duplicate --json".into());
                }
                parsed.as_json = true;
                index += 1;
            }
            "--state-dir" => {
                if parsed.state_dir.is_some() {
                    return Err("duplicate --state-dir".into());
                }
                parsed.state_dir = Some(required_flag_value(args, index, "--state-dir")?);
                index += 2;
            }
            "--evidence" => {
                if parsed.evidence_path.is_some() {
                    return Err("duplicate --evidence".into());
                }
                parsed.evidence_path = Some(required_flag_value(args, index, "--evidence")?);
                index += 2;
            }
            "--session-id" => {
                if parsed.session_id.is_some() {
                    return Err("duplicate --session-id".into());
                }
                parsed.session_id = Some(required_flag_value(args, index, "--session-id")?);
                index += 2;
            }
            "--session-id-file" => {
                if parsed.session_id_file.is_some() {
                    return Err("duplicate --session-id-file".into());
                }
                parsed.session_id_file =
                    Some(required_flag_value(args, index, "--session-id-file")?);
                index += 2;
            }
            "--remote-device-id" => {
                if parsed.remote_device_id.is_some() {
                    return Err("duplicate --remote-device-id".into());
                }
                parsed.remote_device_id =
                    Some(required_flag_value(args, index, "--remote-device-id")?);
                index += 2;
            }
            "--target-runtime-id" => {
                if parsed.target_runtime_id.is_some() {
                    return Err("duplicate --target-runtime-id".into());
                }
                parsed.target_runtime_id =
                    Some(required_flag_value(args, index, "--target-runtime-id")?);
                index += 2;
            }
            "--ttl-seconds" => {
                if parsed.ttl_seconds.is_some() {
                    return Err("duplicate --ttl-seconds".into());
                }
                parsed.ttl_seconds = Some(required_flag_value(args, index, "--ttl-seconds")?);
                index += 2;
            }
            value if value.starts_with("--") => {
                return Err("unsupported session import-product-control option".into());
            }
            _ => {
                return Err(
                    "session import-product-control does not accept positional arguments".into(),
                )
            }
        }
    }
    Ok(parsed)
}

fn read_session_import_secret_file(path: &str, as_json: bool) -> Result<String, String> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err(json_or_text_session_import_invalid_request(
            as_json,
            "session_import_session_id_file_required",
            "session import --session-id-file requires a path",
        ));
    }
    let path = Path::new(trimmed);
    reject_unsafe_path_components(path).map_err(|_| {
        json_or_text_session_import_invalid_request(
            as_json,
            "session_import_session_id_file_symlink_rejected",
            "session import --session-id-file path contains a symlink or reparse point",
        )
    })?;
    let metadata = fs::metadata(path).map_err(|_| {
        json_or_text_session_import_invalid_request(
            as_json,
            "session_import_session_id_file_read_failed",
            "session import could not read --session-id-file",
        )
    })?;
    if !metadata.is_file() {
        return Err(json_or_text_session_import_invalid_request(
            as_json,
            "session_import_session_id_file_not_regular_file",
            "session import --session-id-file must be a regular file",
        ));
    }
    if metadata.len() > SESSION_IMPORT_SECRET_FILE_MAX_BYTES {
        return Err(json_or_text_session_import_invalid_request(
            as_json,
            "session_import_session_id_file_too_large",
            "session import --session-id-file exceeds the maximum supported size",
        ));
    }
    let raw = fs::read_to_string(path).map_err(|_| {
        json_or_text_session_import_invalid_request(
            as_json,
            "session_import_session_id_file_read_failed",
            "session import could not read --session-id-file",
        )
    })?;
    let value = raw
        .strip_suffix("\r\n")
        .or_else(|| raw.strip_suffix('\n'))
        .or_else(|| raw.strip_suffix('\r'))
        .unwrap_or(raw.as_str());
    if value.is_empty()
        || value.len() > SESSION_IMPORT_SECRET_VALUE_MAX_BYTES
        || value.trim() != value
        || value.chars().any(char::is_control)
    {
        return Err(json_or_text_session_import_invalid_request(
            as_json,
            "session_import_session_id_file_invalid",
            "session import --session-id-file contains an invalid session id",
        ));
    }
    Ok(value.to_string())
}

fn session_inventory_report(
    snapshot: &crate::operator_state::SessionInventorySnapshot,
) -> serde_json::Value {
    json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": "session.ls",
        "status": "session_inventory",
        "session_registry_supported": true,
        "mutation_supported": false,
        "live_runtime_started": false,
        "sessions_total": snapshot.sessions_total,
        "sessions": snapshot
            .sessions
            .iter()
            .map(session_summary_report)
            .collect::<Vec<_>>(),
        "source": "windows_operator_state_session_registry",
        "proof_boundary": {
            "session_inventory_not_live_runtime_proof": true,
            "raw_session_ids_redacted": true,
        },
    })
}

fn session_summary_report(session: &RuntimeSessionSummary) -> serde_json::Value {
    json!({
        "session_ref": session.session_ref,
        "session_id_present": session.session_id_present,
        "target_runtime_id_present": session.target_runtime_id_present,
        "remote_device_id_present": session.remote_device_id_present,
        "remote_identity_bound": session.remote_identity_bound,
        "state": session.state,
        "secure_session_state": session.secure_session_state,
        "readiness_kind": session.readiness_kind,
        "expires_at_unix_ms": session.expires_at_unix_ms,
        "expired": session.expired,
        "product_control_secure_session_ready": session.product_control_secure_session_ready,
    })
}

fn validate_product_control_evidence_for_session_import(
    summary: &ProductControlEvidenceSummary,
    session_id: &str,
    remote_device_id: &str,
    as_json: bool,
) -> Result<(), String> {
    if summary.proof_level != ProductControlProofLevel::AppControlSbwcPingPong
        || summary.secure_session_state != "Established"
    {
        return Err(json_or_text_session_import_invalid_request(
            as_json,
            "session_import_appcontrol_required",
            "session import requires established AppControl ping/pong evidence",
        ));
    }
    let Some(evidence_session_hash) = summary.session_id_sha256.as_deref() else {
        return Err(json_or_text_session_import_invalid_request(
            as_json,
            "session_import_session_hash_missing",
            "product-control evidence is missing SessionIdSha256",
        ));
    };
    let Some(evidence_remote_hash) = summary.remote_device_id_sha256.as_deref() else {
        return Err(json_or_text_session_import_invalid_request(
            as_json,
            "session_import_remote_device_hash_missing",
            "product-control evidence is missing RemoteDeviceIdSha256",
        ));
    };
    if summary.remote_protocol_public_key_fingerprint.is_none() {
        return Err(json_or_text_session_import_invalid_request(
            as_json,
            "session_import_remote_fingerprint_missing",
            "product-control evidence is missing RemoteProtocolPublicKeyFingerprint",
        ));
    }
    let session_id_hash = sha256_hex_text(session_id);
    if evidence_session_hash != session_id_hash.as_str() {
        return Err(json_or_text_session_import_invalid_request(
            as_json,
            "session_import_session_hash_mismatch",
            "product-control evidence SessionIdSha256 does not match --session-id",
        ));
    }
    let remote_device_id_hash = sha256_hex_text(remote_device_id);
    if evidence_remote_hash != remote_device_id_hash.as_str() {
        return Err(json_or_text_session_import_invalid_request(
            as_json,
            "session_import_remote_device_hash_mismatch",
            "product-control evidence RemoteDeviceIdSha256 does not match --remote-device-id",
        ));
    }
    Ok(())
}

fn session_import_success_report(
    registration: &ProductControlSessionRegistration,
    target_runtime_id_provided: bool,
    session_id_file_used: bool,
    ttl_seconds: u64,
) -> serde_json::Value {
    json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": "session.import_product_control",
        "accepted": true,
        "status": "session_imported",
        "session_registry_supported": true,
        "session_imported": true,
        "inserted": registration.inserted,
        "mutation_supported": true,
        "live_runtime_started": false,
        "target_runtime_id_provided": target_runtime_id_provided,
        "session_id_file_used": session_id_file_used,
        "ttl_seconds": ttl_seconds,
        "source": "windows_operator_state_session_registry",
        "session": session_summary_report(&registration.session),
        "proof_boundary": {
            "appcontrol_evidence_required": true,
            "session_import_not_live_runtime_start": true,
            "request_registered_not_live_transfer": true,
            "request_registered_not_live_remote_apply": true,
            "raw_session_ids_redacted": true,
        },
        "required_gates_before_live_transfer": FILE_TRANSFER_REQUIRED_GATES,
        "required_gates_before_live_remote_apply": REMOTE_DESKTOP_REQUIRED_GATES,
    })
}

fn session_import_invalid_request_report(
    code: &'static str,
    message: &'static str,
) -> serde_json::Value {
    json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": "session.import_product_control",
        "accepted": false,
        "status": "session_import_rejected",
        "session_registry_supported": false,
        "session_imported": false,
        "mutation_supported": false,
        "live_runtime_started": false,
        "source": "windows_core_cli_request_contract_validation",
        "error": {
            "code": code,
            "message": message,
            "retryable": false,
            "required_gate": "valid_runtime_smoke_appcontrol_evidence",
        },
        "proof_boundary": {
            "session_import_not_live_runtime_start": true,
            "raw_session_ids_redacted": true,
        },
    })
}

fn json_or_text_session_import_invalid_request(
    as_json: bool,
    code: &'static str,
    message: &'static str,
) -> String {
    if as_json {
        json_string(session_import_invalid_request_report(code, message))
            .unwrap_or_else(|_| message.to_string())
    } else {
        message.to_string()
    }
}

fn session_import_operator_state_error(as_json: bool, error: OperatorStateError) -> String {
    let (code, retryable, message, required_gate) = session_operator_state_error_fields(error);
    if as_json {
        return json_string(json!({
            "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
            "capability_id": "session.import_product_control",
            "accepted": false,
            "status": "session_import_rejected",
            "session_registry_supported": true,
            "session_imported": false,
            "mutation_supported": true,
            "live_runtime_started": false,
            "source": "windows_operator_state_session_registry",
            "error": {
                "code": code,
                "message": message,
                "retryable": retryable,
                "required_gate": required_gate,
            },
            "proof_boundary": {
                "session_import_not_live_runtime_start": true,
                "raw_session_ids_redacted": true,
            },
        }))
        .unwrap_or_else(|_| message.to_string());
    }
    message.to_string()
}

fn sha256_hex_text(value: &str) -> String {
    let digest = Sha256::digest(value.as_bytes());
    format_hex(&digest)
}

fn expires_at_unix_ms_from_ttl_seconds(ttl_seconds: u64) -> Result<i64, String> {
    if ttl_seconds == 0 || ttl_seconds > SESSION_IMPORT_MAX_TTL_SECONDS {
        return Err(format!(
            "--ttl-seconds must be between 1 and {SESSION_IMPORT_MAX_TTL_SECONDS}"
        ));
    }
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| "system clock is before Unix epoch".to_string())?
        .as_millis();
    let ttl_ms = u128::from(ttl_seconds)
        .checked_mul(1_000)
        .ok_or_else(|| "--ttl-seconds is too large".to_string())?;
    let expires_at = now_ms
        .checked_add(ttl_ms)
        .ok_or_else(|| "--ttl-seconds is too large".to_string())?;
    i64::try_from(expires_at).map_err(|_| "--ttl-seconds is too large".to_string())
}

fn session_invalid_request_report(code: &'static str, message: &'static str) -> serde_json::Value {
    session_operator_state_error_payload(
        "session.inspect",
        code,
        false,
        message,
        "session_command_contract",
    )
}

fn session_operator_state_error(
    as_json: bool,
    capability_id: &'static str,
    error: OperatorStateError,
) -> String {
    let (code, retryable, message, required_gate) = session_operator_state_error_fields(error);
    if as_json {
        return json_string(session_operator_state_error_payload(
            capability_id,
            code,
            retryable,
            message,
            required_gate,
        ))
        .unwrap_or_else(|_| message.to_string());
    }
    message.to_string()
}

fn session_operator_state_error_payload(
    capability_id: &'static str,
    code: &'static str,
    retryable: bool,
    message: &'static str,
    required_gate: &'static str,
) -> serde_json::Value {
    json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": capability_id,
        "accepted": false,
        "status": "session_inventory_rejected",
        "session_registry_supported": false,
        "session_found": false,
        "mutation_supported": false,
        "live_runtime_started": false,
        "source": "windows_operator_state_session_registry",
        "error": {
            "code": code,
            "message": message,
            "retryable": retryable,
            "required_gate": required_gate,
        },
        "proof_boundary": {
            "session_inventory_not_live_runtime_proof": true,
            "raw_session_ids_redacted": true,
        },
    })
}

fn session_operator_state_error_fields(
    error: OperatorStateError,
) -> (&'static str, bool, &'static str, &'static str) {
    match error {
        OperatorStateError::MissingStateDir => (
            "session_state_dir_missing",
            false,
            "session inventory requires an operator state directory",
            "windows_agent_owned_session_registry",
        ),
        OperatorStateError::StateDirUnavailable | OperatorStateError::StateDirNotDirectory => (
            "session_state_dir_unavailable",
            false,
            "session inventory operator state directory is unavailable",
            "windows_agent_owned_session_registry",
        ),
        OperatorStateError::UnsafePath => (
            "session_state_dir_unsafe",
            false,
            "session inventory operator state path contains an unsafe path component",
            "windows_agent_owned_session_registry",
        ),
        OperatorStateError::SessionRegistryMissing => (
            "session_registry_missing",
            false,
            "session inventory requires an agent-owned session registry",
            "windows_agent_owned_session_registry",
        ),
        OperatorStateError::SessionRegistryTooLarge => (
            "session_registry_too_large",
            false,
            "session inventory registry exceeds the maximum supported size",
            "windows_agent_owned_session_registry",
        ),
        OperatorStateError::SessionRegistryRead
        | OperatorStateError::SessionRegistryJson
        | OperatorStateError::SessionRegistrySchema
        | OperatorStateError::SessionRegistryInvalid => (
            "session_registry_invalid",
            false,
            "session inventory registry is invalid",
            "windows_agent_owned_session_registry",
        ),
        OperatorStateError::InvalidSessionBinding => (
            "session_binding_invalid",
            false,
            "session import binding is invalid",
            "valid_runtime_smoke_appcontrol_evidence",
        ),
        OperatorStateError::SessionBindingConflict => (
            "session_binding_conflict",
            false,
            "session import conflicts with an existing operator session binding",
            "windows_agent_owned_session_registry",
        ),
        OperatorStateError::SessionRegistryWrite
        | OperatorStateError::SessionRegistryPersistVerify => (
            "session_registry_write_failed",
            true,
            "session registry could not be persisted",
            "windows_agent_owned_session_registry",
        ),
        OperatorStateError::SessionNotFound => (
            "session_not_found",
            false,
            "session was not found in the operator registry",
            "windows_agent_owned_session_registry",
        ),
        OperatorStateError::Clock => (
            "session_clock_invalid",
            true,
            "system clock cannot be used for session freshness validation",
            "freshness_window_validation",
        ),
        OperatorStateError::SessionNotEstablished | OperatorStateError::SessionStale => (
            "session_registry_invalid",
            false,
            "session inventory registry is not usable for product-control requests",
            "windows_agent_owned_session_registry",
        ),
        OperatorStateError::RequestRegistryRead
        | OperatorStateError::RequestRegistryJson
        | OperatorStateError::RequestRegistrySchema
        | OperatorStateError::RequestRegistryInvalid
        | OperatorStateError::InvalidRequestPayload
        | OperatorStateError::PendingRequestExists
        | OperatorStateError::RequestRegistryFull
        | OperatorStateError::RegistryLocked
        | OperatorStateError::RequestRegistryWrite
        | OperatorStateError::RequestRegistryPersistVerify
        | OperatorStateError::FileTransferRequestRegistryRead
        | OperatorStateError::FileTransferRequestRegistryJson
        | OperatorStateError::FileTransferRequestRegistrySchema
        | OperatorStateError::FileTransferRequestRegistryInvalid
        | OperatorStateError::InvalidPeerRef
        | OperatorStateError::PeerBindingMissing
        | OperatorStateError::PeerMismatch
        | OperatorStateError::FileTransferSourceMissing
        | OperatorStateError::FileTransferSourceUnsafe
        | OperatorStateError::FileTransferSourceNotRegularFile
        | OperatorStateError::FileTransferSourceRead
        | OperatorStateError::FileTransferHashFailed
        | OperatorStateError::FileTransferRequestRegistryWrite
        | OperatorStateError::FileTransferRequestRegistryPersistVerify
        | OperatorStateError::NearbyDiscoverySnapshotMissing
        | OperatorStateError::NearbyDiscoveryActiveScanSnapshotMissing
        | OperatorStateError::NearbyDiscoverySnapshotStale
        | OperatorStateError::NearbyDiscoveryActiveScanSnapshotStale
        | OperatorStateError::NearbyDiscoverySnapshotRegistryRead
        | OperatorStateError::NearbyDiscoverySnapshotRegistryJson
        | OperatorStateError::NearbyDiscoverySnapshotRegistrySchema
        | OperatorStateError::NearbyDiscoverySnapshotRegistryInvalid
        | OperatorStateError::NearbyDiscoverySnapshotRegistryTooLarge => (
            "session_registry_invalid",
            false,
            "session inventory registry is invalid",
            "windows_agent_owned_session_registry",
        ),
    }
}

fn execute_file(args: &[String], out: &mut impl Write) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("send") => execute_file_send(args, out),
        Some("receive") => execute_file_receive(args),
        Some("history") => execute_file_history(args, out),
        _ => Err("expected file send, file receive, or file history".into()),
    }
}

fn execute_file_send(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let parsed = parse_file_send_args(args)?;
    let as_json = parsed.as_json;
    let source_path_provided = parsed
        .source_path
        .as_ref()
        .is_some_and(|value| !value.trim().is_empty());
    let destination_peer_provided = parsed
        .destination_peer
        .is_some_and(|value| !value.trim().is_empty());
    let session_id_provided = parsed
        .session_id
        .is_some_and(|value| !value.trim().is_empty());

    if let Some(state_dir) = parsed.state_dir {
        let Some(source_path) = parsed
            .source_path
            .as_deref()
            .filter(|value| !value.trim().is_empty())
        else {
            return fail_json_or_text(
                as_json,
                file_transfer_invalid_request_report(
                    source_path_provided,
                    destination_peer_provided,
                    session_id_provided,
                    "file_transfer_source_missing",
                    "file transfer send requires a source path",
                ),
                "file transfer send requires a source path",
            );
        };
        let Some(destination_peer) = parsed
            .destination_peer
            .filter(|value| !value.trim().is_empty())
        else {
            return fail_json_or_text(
                as_json,
                file_transfer_invalid_request_report(
                    source_path_provided,
                    false,
                    session_id_provided,
                    "file_transfer_destination_required",
                    "file transfer send requires --to",
                ),
                "file transfer send requires --to",
            );
        };
        let Some(session_id) = parsed.session_id.filter(|value| !value.trim().is_empty()) else {
            return fail_json_or_text(
                as_json,
                file_transfer_invalid_request_report(
                    source_path_provided,
                    destination_peer_provided,
                    false,
                    "file_transfer_session_id_required",
                    "file transfer send requires --session-id",
                ),
                "file transfer send requires --session-id",
            );
        };
        let registration = register_file_transfer_send_request_for_established_session(
            state_dir,
            session_id,
            destination_peer,
            source_path,
        )
        .map_err(|error| {
            file_transfer_operator_state_error(
                as_json,
                source_path_provided,
                destination_peer_provided,
                session_id_provided,
                error,
            )
        })?;
        let payload = file_transfer_registered_request_report(
            source_path_provided,
            destination_peer_provided,
            session_id_provided,
            &registration.request,
            registration.pending_requests_for_session,
        );
        return write_json_or_text(
            as_json,
            payload,
            "File transfer request registered for agent observation; live transfer is not proven.",
            out,
        );
    }

    fail_json_or_text(
        as_json,
        json!({
            "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
            "capability_id": "file.transfer.send",
            "action": "send",
            "accepted": false,
            "status": "planned_fail_closed",
            "mutation_supported": false,
            "request_registered": false,
            "pending_agent_observation": false,
            "agent_observed": false,
            "transfer_started": false,
            "applied": false,
            "receipt_verified": false,
            "source_path_provided": source_path_provided,
            "destination_peer_provided": destination_peer_provided,
            "session_id_provided": session_id_provided,
            "route_bound": false,
            "source": "windows_core_cli_contract_only_no_agent_registry",
            "error": {
                "code": "windows_file_transfer_agent_missing",
                "message": "Windows core CLI cannot register or observe file transfer requests without a product-control secure session and agent-owned registry",
                "retryable": false,
                "required_gate": "product_control_secure_session",
            },
            "required_gates_before_live_transfer": FILE_TRANSFER_REQUIRED_GATES,
        }),
        "Windows file send requires a product-control secure session, agent-owned request registry, receiver write policy, transferred bytes, and SHA-256 receipt evidence",
    )
}

fn execute_file_receive(args: &[String]) -> Result<(), String> {
    let as_json = has_flag(args, "--json");
    fail_json_or_text(
        as_json,
        json!({
            "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
            "capability_id": "file.transfer.receive",
            "action": "receive",
            "accepted": false,
            "status": "planned_fail_closed",
            "mutation_supported": false,
            "receiver_policy_available": false,
            "source": "windows_core_cli_contract_only_no_agent_registry",
            "error": {
                "code": "windows_file_receive_agent_missing",
                "message": "Windows inbound file receive requires an agent-owned receive policy and verified sender identity",
                "retryable": false,
                "required_gate": "receiver_write_policy",
            },
            "required_gates_before_live_transfer": FILE_TRANSFER_REQUIRED_GATES,
        }),
        "Windows file receive requires an agent-owned receive policy, verified sender identity, and real-device file-transfer evidence",
    )
}

fn execute_file_history(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let parsed = parse_file_history_args(args)?;
    let as_json = parsed.as_json;
    if let Some(state_dir) = parsed.state_dir {
        let snapshot =
            read_file_transfer_history(state_dir, parsed.session_id).map_err(|error| {
                file_transfer_operator_state_error(
                    as_json,
                    false,
                    false,
                    parsed.session_id.is_some(),
                    error,
                )
            })?;
        let payload = file_transfer_history_report(&snapshot);
        return write_json_or_text(
            as_json,
            payload,
            "File transfer request history loaded; live transfer evidence is not proven.",
            out,
        );
    }
    let payload = json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": "file.transfer.history",
        "status": "read_only_empty",
        "source": "windows_core_cli_contract_only_no_agent_registry",
        "history_supported": false,
        "agent_registry_available": false,
        "pending_requests": 0,
        "history": [],
        "required_gates_before_history": FILE_TRANSFER_REQUIRED_GATES,
    });
    write_json_or_text(
        as_json,
        payload,
        "File transfer history is empty because the Windows core CLI has no agent-owned transfer registry.",
        out,
    )
}

struct FileSendArgs<'a> {
    as_json: bool,
    state_dir: Option<&'a str>,
    source_path: Option<String>,
    destination_peer: Option<&'a str>,
    session_id: Option<&'a str>,
}

fn parse_file_send_args(args: &[String]) -> Result<FileSendArgs<'_>, String> {
    let mut parsed = FileSendArgs {
        as_json: false,
        state_dir: None,
        source_path: None,
        destination_peer: None,
        session_id: None,
    };
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                parsed.as_json = true;
                index += 1;
            }
            "--state-dir" => {
                if parsed.state_dir.is_some() {
                    return Err("duplicate --state-dir".into());
                }
                let value = required_flag_value(args, index, "--state-dir")?;
                parsed.state_dir = Some(value);
                index += 2;
            }
            "--to" => {
                if parsed.destination_peer.is_some() {
                    return Err("duplicate --to".into());
                }
                let value = required_flag_value(args, index, "--to")?;
                parsed.destination_peer = Some(value);
                index += 2;
            }
            "--session-id" => {
                if parsed.session_id.is_some() {
                    return Err("duplicate --session-id".into());
                }
                let value = required_flag_value(args, index, "--session-id")?;
                parsed.session_id = Some(value);
                index += 2;
            }
            value if value.starts_with("--") => {
                return Err(format!("unsupported file send option: {value}"));
            }
            value => {
                if parsed.source_path.is_some() {
                    return Err("file send accepts exactly one source path".into());
                }
                parsed.source_path = Some(value.to_string());
                index += 1;
            }
        }
    }
    Ok(parsed)
}

struct FileHistoryArgs<'a> {
    as_json: bool,
    state_dir: Option<&'a str>,
    session_id: Option<&'a str>,
}

fn parse_file_history_args(args: &[String]) -> Result<FileHistoryArgs<'_>, String> {
    let mut parsed = FileHistoryArgs {
        as_json: false,
        state_dir: None,
        session_id: None,
    };
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                parsed.as_json = true;
                index += 1;
            }
            "--state-dir" => {
                if parsed.state_dir.is_some() {
                    return Err("duplicate --state-dir".into());
                }
                parsed.state_dir = Some(required_flag_value(args, index, "--state-dir")?);
                index += 2;
            }
            "--session-id" => {
                if parsed.session_id.is_some() {
                    return Err("duplicate --session-id".into());
                }
                parsed.session_id = Some(required_flag_value(args, index, "--session-id")?);
                index += 2;
            }
            value => return Err(format!("unsupported file history option: {value}")),
        }
    }
    Ok(parsed)
}

fn required_flag_value<'a>(
    args: &'a [String],
    index: usize,
    flag: &str,
) -> Result<&'a str, String> {
    let value = args
        .get(index + 1)
        .map(String::as_str)
        .ok_or_else(|| format!("{flag} requires a value"))?;
    if value.starts_with("--") || value.trim().is_empty() {
        return Err(format!("{flag} requires a value"));
    }
    Ok(value)
}

fn file_transfer_registered_request_report(
    source_path_provided: bool,
    destination_peer_provided: bool,
    session_id_provided: bool,
    request: &FileTransferControlRequest,
    pending_requests_for_session: usize,
) -> serde_json::Value {
    json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": "file.transfer.send",
        "action": "send",
        "accepted": true,
        "status": "request_registered",
        "request_registry_supported": true,
        "file_transfer_request_registry_supported": true,
        "request_registered": true,
        "pending_agent_observation": true,
        "agent_observed": false,
        "transfer_started": false,
        "applied": false,
        "receipt_verified": false,
        "source_path_provided": source_path_provided,
        "destination_peer_provided": destination_peer_provided,
        "session_id_provided": session_id_provided,
        "source_snapshot_recorded": true,
        "source_hash_recorded_private": true,
        "source": "windows_operator_state_file_transfer_request_registry",
        "request": file_transfer_request_report(request),
        "pending_requests_for_session": pending_requests_for_session,
        "proof_boundary": {
            "request_registered_not_live_transfer": true,
            "product_control_session_required": true,
            "agent_observation_proof": false,
            "transferred_bytes_proof": false,
            "file_sha256_receipt_proof": false,
            "mac_product_app_proof": false,
        },
        "file_transfer": {
            "proven": false,
            "missing_gates": file_transfer_missing_gates_after_registered_request(),
        },
        "required_gates_before_live_transfer": FILE_TRANSFER_REQUIRED_GATES,
    })
}

fn file_transfer_history_report(
    snapshot: &crate::operator_state::FileTransferHistorySnapshot,
) -> serde_json::Value {
    json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": "file.transfer.history",
        "status": "request_history",
        "source": "windows_operator_state_file_transfer_request_registry",
        "history_supported": true,
        "file_transfer_request_registry_supported": true,
        "live_transfer_history_supported": false,
        "agent_registry_available": true,
        "sessions_total": snapshot.sessions_total,
        "pending_requests": snapshot.pending_requests,
        "latest_request": snapshot.latest_request.as_ref().map(file_transfer_request_report),
        "history": snapshot
            .history
            .iter()
            .map(file_transfer_request_report)
            .collect::<Vec<_>>(),
        "proof_boundary": {
            "request_history_not_live_transfer_history": true,
            "transferred_bytes_proof": false,
            "file_sha256_receipt_proof": false,
        },
        "file_transfer": {
            "proven": false,
            "missing_gates": FILE_TRANSFER_REQUIRED_GATES,
        },
        "required_gates_before_live_transfer": FILE_TRANSFER_REQUIRED_GATES,
    })
}

fn file_transfer_request_report(request: &FileTransferControlRequest) -> serde_json::Value {
    json!({
        "request_id": request.request_id,
        "action": request.action.as_str(),
        "status": request.status.as_str(),
        "target_runtime_bound": true,
        "created_at_unix_ms": request.created_at_unix_ms,
        "updated_at_unix_ms": request.updated_at_unix_ms,
        "transfer_started": request.transfer_started_at_unix_ms.is_some(),
        "bytes_transferred_recorded": request.bytes_transferred > 0,
        "receipt_verified": request.receipt_verified,
        "receipt_sha256_match": request.receipt_sha256_match,
        "transfer_completed": request.transfer_completed_at_unix_ms.is_some(),
    })
}

fn file_transfer_operator_state_error(
    as_json: bool,
    source_path_provided: bool,
    destination_peer_provided: bool,
    session_id_provided: bool,
    error: OperatorStateError,
) -> String {
    let (code, retryable, message) = file_transfer_operator_state_error_fields(error);
    if as_json {
        return json_string(json!({
            "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
            "capability_id": "file.transfer.send",
            "action": "send",
            "accepted": false,
            "status": "request_rejected",
            "request_registry_supported": true,
            "file_transfer_request_registry_supported": true,
            "request_registered": false,
            "pending_agent_observation": false,
            "agent_observed": false,
            "transfer_started": false,
            "applied": false,
            "receipt_verified": false,
            "source_path_provided": source_path_provided,
            "destination_peer_provided": destination_peer_provided,
            "session_id_provided": session_id_provided,
            "source": "windows_operator_state_file_transfer_request_registry",
            "error": {
                "code": code,
                "message": message,
                "retryable": retryable,
                "required_gate": "windows_operator_state_registry",
            },
            "required_gates_before_live_transfer": FILE_TRANSFER_REQUIRED_GATES,
        }))
        .unwrap_or_else(|_| message.to_string());
    }
    message.to_string()
}

fn file_transfer_operator_state_error_fields(
    error: OperatorStateError,
) -> (&'static str, bool, &'static str) {
    match error {
        OperatorStateError::MissingStateDir => (
            "file_transfer_state_dir_missing",
            false,
            "file transfer request registration requires an operator state directory",
        ),
        OperatorStateError::StateDirUnavailable | OperatorStateError::StateDirNotDirectory => (
            "file_transfer_state_dir_unavailable",
            false,
            "file transfer operator state directory is unavailable",
        ),
        OperatorStateError::UnsafePath => (
            "file_transfer_state_dir_unsafe",
            false,
            "file transfer operator state path contains an unsafe path component",
        ),
        OperatorStateError::SessionRegistryMissing => (
            "file_transfer_session_registry_missing",
            false,
            "file transfer request registration requires an agent-owned session registry",
        ),
        OperatorStateError::SessionRegistryRead
        | OperatorStateError::SessionRegistryJson
        | OperatorStateError::SessionRegistrySchema
        | OperatorStateError::SessionRegistryInvalid
        | OperatorStateError::SessionRegistryTooLarge
        | OperatorStateError::InvalidSessionBinding
        | OperatorStateError::SessionBindingConflict
        | OperatorStateError::SessionRegistryWrite
        | OperatorStateError::SessionRegistryPersistVerify => (
            "file_transfer_session_registry_invalid",
            false,
            "file transfer session registry is invalid",
        ),
        OperatorStateError::SessionNotFound => (
            "file_transfer_session_not_found",
            false,
            "file transfer session was not found in the operator registry",
        ),
        OperatorStateError::SessionNotEstablished => (
            "file_transfer_session_not_established",
            false,
            "file transfer session is not established for request registration",
        ),
        OperatorStateError::SessionStale => (
            "file_transfer_session_stale",
            false,
            "file transfer session registry entry is stale",
        ),
        OperatorStateError::InvalidPeerRef => (
            "file_transfer_peer_invalid",
            false,
            "file transfer destination peer reference is invalid",
        ),
        OperatorStateError::PeerBindingMissing => (
            "file_transfer_peer_binding_missing",
            false,
            "file transfer session is missing a verified peer binding",
        ),
        OperatorStateError::PeerMismatch => (
            "file_transfer_peer_mismatch",
            false,
            "file transfer destination does not match the established session peer",
        ),
        OperatorStateError::FileTransferSourceMissing => (
            "file_transfer_source_missing",
            false,
            "file transfer source is missing",
        ),
        OperatorStateError::FileTransferSourceUnsafe => (
            "file_transfer_source_unsafe",
            false,
            "file transfer source path contains an unsafe path component",
        ),
        OperatorStateError::FileTransferSourceNotRegularFile => (
            "file_transfer_source_not_regular_file",
            false,
            "file transfer source must be a regular file",
        ),
        OperatorStateError::FileTransferSourceRead | OperatorStateError::FileTransferHashFailed => {
            (
                "file_transfer_source_unreadable",
                false,
                "file transfer source could not be read",
            )
        }
        OperatorStateError::FileTransferRequestRegistryRead
        | OperatorStateError::FileTransferRequestRegistryJson
        | OperatorStateError::FileTransferRequestRegistrySchema
        | OperatorStateError::FileTransferRequestRegistryInvalid => (
            "file_transfer_request_registry_invalid",
            false,
            "file transfer request registry is invalid",
        ),
        OperatorStateError::InvalidRequestPayload => (
            "file_transfer_request_payload_invalid",
            false,
            "file transfer request payload is invalid",
        ),
        OperatorStateError::PendingRequestExists => (
            "file_transfer_pending_request_exists",
            false,
            "file transfer session already has a pending request awaiting agent observation",
        ),
        OperatorStateError::RequestRegistryFull => (
            "file_transfer_request_registry_full",
            false,
            "file transfer request registry is full",
        ),
        OperatorStateError::RegistryLocked => (
            "file_transfer_registry_locked",
            true,
            "file transfer operator registry is locked by another process",
        ),
        OperatorStateError::FileTransferRequestRegistryWrite
        | OperatorStateError::FileTransferRequestRegistryPersistVerify => (
            "file_transfer_request_registry_write_failed",
            true,
            "file transfer request registry could not be persisted",
        ),
        OperatorStateError::RequestRegistryRead
        | OperatorStateError::RequestRegistryJson
        | OperatorStateError::RequestRegistrySchema
        | OperatorStateError::RequestRegistryInvalid
        | OperatorStateError::RequestRegistryWrite
        | OperatorStateError::RequestRegistryPersistVerify
        | OperatorStateError::NearbyDiscoverySnapshotMissing
        | OperatorStateError::NearbyDiscoveryActiveScanSnapshotMissing
        | OperatorStateError::NearbyDiscoverySnapshotStale
        | OperatorStateError::NearbyDiscoveryActiveScanSnapshotStale
        | OperatorStateError::NearbyDiscoverySnapshotRegistryRead
        | OperatorStateError::NearbyDiscoverySnapshotRegistryJson
        | OperatorStateError::NearbyDiscoverySnapshotRegistrySchema
        | OperatorStateError::NearbyDiscoverySnapshotRegistryInvalid
        | OperatorStateError::NearbyDiscoverySnapshotRegistryTooLarge => (
            "file_transfer_request_registry_invalid",
            false,
            "file transfer request registry is invalid",
        ),
        OperatorStateError::Clock => (
            "file_transfer_clock_invalid",
            true,
            "system clock cannot be used for file transfer request registration",
        ),
    }
}

fn file_transfer_invalid_request_report(
    source_path_provided: bool,
    destination_peer_provided: bool,
    session_id_provided: bool,
    code: &'static str,
    message: &'static str,
) -> serde_json::Value {
    json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": "file.transfer.send",
        "action": "send",
        "accepted": false,
        "status": "request_invalid",
        "request_registry_supported": false,
        "request_registered": false,
        "pending_agent_observation": false,
        "agent_observed": false,
        "transfer_started": false,
        "applied": false,
        "receipt_verified": false,
        "source_path_provided": source_path_provided,
        "destination_peer_provided": destination_peer_provided,
        "session_id_provided": session_id_provided,
        "source": "windows_core_cli_request_contract_validation",
        "error": {
            "code": code,
            "message": message,
            "retryable": false,
            "required_gate": "file_transfer_request_contract",
        },
        "required_gates_before_live_transfer": FILE_TRANSFER_REQUIRED_GATES,
    })
}

fn file_transfer_missing_gates_after_registered_request() -> Vec<&'static str> {
    FILE_TRANSFER_REQUIRED_GATES
        .iter()
        .copied()
        .filter(|gate| *gate != "product_control_secure_session")
        .collect()
}

fn execute_evidence(args: &[String], out: &mut impl Write) -> Result<(), String> {
    if args.first().map(String::as_str) != Some("status") {
        return Err("expected evidence status --evidence <path> [--json]".into());
    }
    let as_json = has_flag(args, "--json");
    let evidence_path = required_option(args, "--evidence")?;
    let summary = read_product_control_evidence(evidence_path).map_err(|error| {
        product_control_evidence_error(as_json, "current_path.product_control.evidence", error)
    })?;
    let payload =
        product_control_evidence_report("current_path.product_control.evidence", &summary);
    write_json_or_text(
        as_json,
        payload,
        "Product-control evidence is valid as a read-only evidence report; it does not start a runtime or prove file-transfer/remote-desktop apply.",
        out,
    )
}

fn execute_remote_desktop(args: &[String], out: &mut impl Write) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("contract") => execute_remote_desktop_contract(args, out),
        Some("status") => execute_remote_desktop_status(args, out),
        Some("resolutions") => execute_remote_desktop_resolutions(args, out),
        Some("start") => execute_remote_desktop_mutation(args, "start", out),
        Some("stop") => execute_remote_desktop_mutation(args, "stop", out),
        Some("set-resolution") => execute_remote_desktop_mutation(args, "set-resolution", out),
        Some("set-fps") => execute_remote_desktop_mutation(args, "set-fps", out),
        _ => Err("expected remote-desktop contract, status, resolutions, start, stop, set-resolution, or set-fps".into()),
    }
}

fn execute_remote_desktop_contract(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let as_json = match args {
        [_] => false,
        [_, flag] if flag == "--json" => true,
        _ => return Err("expected remote-desktop contract [--json]".into()),
    };
    let payload = json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "live_control_status": "request_registry_available",
        "mutation_supported": false,
        "agent_observation_supported": false,
        "request_registry_supported": true,
        "request_contract_source": "windows_operator_state_remote_desktop_request_registry",
        "commands": REMOTE_DESKTOP_COMMAND_CONTRACTS,
        "resolution_request_contract": REMOTE_DESKTOP_RESOLUTION_CONTRACT,
        "fps_request_contract": REMOTE_DESKTOP_FPS_CONTRACT,
        "evidence_sources": REMOTE_DESKTOP_EVIDENCE_SOURCES,
        "required_gates": REMOTE_DESKTOP_REQUIRED_GATES,
    });
    write_json_or_text(
        as_json,
        payload,
        "Remote desktop request registration is available with --state-dir, but live apply still requires agent observation and real-device evidence.",
        out,
    )
}

fn execute_remote_desktop_status(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let as_json = has_flag(args, "--json");
    let session_filter_provided =
        optional_option(args, "--session-id").is_some_and(|value| !value.trim().is_empty());
    if args.iter().any(|arg| arg == "--session-id") && !session_filter_provided {
        return Err("missing required option: --session-id".into());
    }
    if let Some(evidence_path) = optional_option(args, "--product-control-evidence") {
        let summary = read_product_control_evidence(evidence_path).map_err(|error| {
            product_control_evidence_error(
                as_json,
                "remote_desktop.status.product_control_evidence",
                error,
            )
        })?;
        let mut payload = product_control_evidence_report(
            "remote_desktop.status.product_control_evidence",
            &summary,
        );
        payload["session_filter_provided"] = json!(session_filter_provided);
        return write_json_or_text(
            as_json,
            payload,
            "Remote desktop status read product-control evidence only; live remote-desktop apply still requires notice, media, and performance gates.",
            out,
        );
    }
    if let Some(state_dir) = optional_option(args, "--state-dir") {
        let session_filter =
            optional_option(args, "--session-id").filter(|value| !value.trim().is_empty());
        let snapshot = read_remote_desktop_status(state_dir, session_filter).map_err(|error| {
            remote_desktop_operator_state_error(
                as_json,
                "status",
                session_filter_provided,
                false,
                false,
                error,
            )
        })?;
        let latest_request = snapshot
            .latest_request
            .as_ref()
            .map(remote_desktop_request_report);
        let payload = json!({
            "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
            "live_control_status": "request_registry_pending_agent_observation",
            "mutation_supported": false,
            "agent_observation_supported": false,
            "request_registry_supported": true,
            "session_filter_provided": session_filter_provided,
            "sessions_total": snapshot.sessions_total,
            "pending_requests": snapshot.pending_requests,
            "latest_request": latest_request,
            "source": "windows_operator_state_remote_desktop_request_registry",
            "remote_desktop": {
                "proven": false,
                "missing_gates": remote_desktop_missing_gates_after_registered_request(),
            },
            "required_gates_before_live_apply": REMOTE_DESKTOP_REQUIRED_GATES,
        });
        return write_json_or_text(
            as_json,
            payload,
            "Remote desktop status read the Windows operator request registry; live apply still requires agent observation and media evidence.",
            out,
        );
    }
    let payload = json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "live_control_status": "planned_fail_closed",
        "mutation_supported": false,
        "agent_observation_supported": false,
        "request_registry_supported": false,
        "session_filter_provided": session_filter_provided,
        "sessions": [],
        "evidence_sources": REMOTE_DESKTOP_EVIDENCE_SOURCES,
        "required_gates_before_live_apply": REMOTE_DESKTOP_REQUIRED_GATES,
    });
    write_json_or_text(
        as_json,
        payload,
        "Remote desktop status has no Windows core CLI agent registry to inspect.",
        out,
    )
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ProductControlEvidenceReadError {
    MissingPath,
    Metadata,
    NotRegularFile,
    SymlinkOrReparsePath,
    TooLarge,
    Read,
    Validate(ProductControlEvidenceError),
}

fn read_product_control_evidence(
    path: &str,
) -> Result<ProductControlEvidenceSummary, ProductControlEvidenceReadError> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err(ProductControlEvidenceReadError::MissingPath);
    }
    reject_symlink_path_components(trimmed)?;
    let metadata = fs::metadata(trimmed).map_err(|_| ProductControlEvidenceReadError::Metadata)?;
    if !metadata.is_file() {
        return Err(ProductControlEvidenceReadError::NotRegularFile);
    }
    if metadata.len() > MAX_PRODUCT_CONTROL_EVIDENCE_BYTES {
        return Err(ProductControlEvidenceReadError::TooLarge);
    }
    let json = fs::read_to_string(trimmed).map_err(|_| ProductControlEvidenceReadError::Read)?;
    validate_product_control_evidence_json(&json).map_err(ProductControlEvidenceReadError::Validate)
}

fn reject_symlink_path_components(path: &str) -> Result<(), ProductControlEvidenceReadError> {
    let path = std::path::Path::new(path);
    let mut current = std::path::PathBuf::new();
    for component in path.components() {
        current.push(component.as_os_str());
        if current.as_os_str().is_empty() {
            continue;
        }
        let Ok(metadata) = fs::symlink_metadata(&current) else {
            continue;
        };
        if metadata_is_unsafe(&metadata) {
            return Err(ProductControlEvidenceReadError::SymlinkOrReparsePath);
        }
    }
    Ok(())
}

fn product_control_evidence_error(
    as_json: bool,
    capability_id: &'static str,
    error: ProductControlEvidenceReadError,
) -> String {
    let (code, retryable, detail) = product_control_evidence_error_fields(error);
    if as_json {
        return json_string(json!({
            "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
            "capability_id": capability_id,
            "evidence_path_provided": true,
            "evidence_valid": false,
            "accepted": false,
            "live_runtime_started": false,
            "mutation_supported": false,
            "error": {
                "code": code,
                "message": detail,
                "retryable": retryable,
                "required_gate": "valid_runtime_smoke_product_control_evidence",
            },
        }))
        .unwrap_or_else(|_| "product-control evidence validation failed".to_string());
    }
    detail.to_string()
}

fn product_control_evidence_error_fields(
    error: ProductControlEvidenceReadError,
) -> (&'static str, bool, &'static str) {
    match error {
        ProductControlEvidenceReadError::MissingPath => (
            "product_control_evidence_path_missing",
            false,
            "product-control evidence path is required",
        ),
        ProductControlEvidenceReadError::Metadata => (
            "product_control_evidence_read_failed",
            true,
            "product-control evidence file could not be inspected",
        ),
        ProductControlEvidenceReadError::NotRegularFile => (
            "product_control_evidence_not_regular_file",
            false,
            "product-control evidence must be a regular file",
        ),
        ProductControlEvidenceReadError::SymlinkOrReparsePath => (
            "product_control_evidence_symlink_rejected",
            false,
            "product-control evidence symlink or reparse path is rejected",
        ),
        ProductControlEvidenceReadError::TooLarge => (
            "product_control_evidence_too_large",
            false,
            "product-control evidence exceeds the maximum supported JSON size",
        ),
        ProductControlEvidenceReadError::Read => (
            "product_control_evidence_read_failed",
            true,
            "product-control evidence file could not be read",
        ),
        ProductControlEvidenceReadError::Validate(ProductControlEvidenceError::Json) => (
            "product_control_evidence_json_invalid",
            false,
            "product-control evidence JSON is invalid",
        ),
        ProductControlEvidenceReadError::Validate(
            ProductControlEvidenceError::UnsupportedSchema,
        ) => (
            "product_control_evidence_schema_unsupported",
            false,
            "product-control evidence schema or profile is unsupported",
        ),
        ProductControlEvidenceReadError::Validate(ProductControlEvidenceError::MissingField(_))
        | ProductControlEvidenceReadError::Validate(ProductControlEvidenceError::InvalidField(_))
        | ProductControlEvidenceReadError::Validate(ProductControlEvidenceError::IncompleteSteps) => {
            (
                "product_control_evidence_incomplete",
                false,
                "product-control evidence is missing required fields or completed steps",
            )
        }
        ProductControlEvidenceReadError::Validate(ProductControlEvidenceError::BoundaryInvalid) => {
            (
                "product_control_evidence_boundary_invalid",
                false,
                "product-control evidence proof boundary is invalid or overclaims product state",
            )
        }
        ProductControlEvidenceReadError::Validate(
            ProductControlEvidenceError::SecretCaptureDetected,
        ) => (
            "product_control_evidence_secret_capture_detected",
            false,
            "product-control evidence reports captured secret-bearing inputs",
        ),
    }
}

fn product_control_evidence_report(
    capability_id: &'static str,
    summary: &ProductControlEvidenceSummary,
) -> serde_json::Value {
    let remote_desktop_missing_gates =
        remote_desktop_missing_gates_after_product_control(summary.proof_level);
    json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": capability_id,
        "live_control_status": "read_only_product_control_evidence",
        "evidence_path_provided": true,
        "evidence_valid": true,
        "accepted": false,
        "live_runtime_started": false,
        "mutation_supported": false,
        "request_registry_supported": false,
        "request_registered": false,
        "freshness_enforced": false,
        "freshness_note": "RuntimeSmoke product-control evidence currently carries RecordedAt text but no CLI-enforced Unix timestamp freshness contract.",
        "product_control": {
            "proof_level": summary.proof_level.as_str(),
            "profile": summary.profile,
            "evidence_scope": summary.evidence_scope,
            "status": summary.status,
            "role": summary.role,
            "signaling_exchange_role": summary.signaling_exchange_role,
            "helper_mode": summary.helper_mode,
            "secure_session_state": summary.secure_session_state,
            "product_send_count": summary.product_send_count,
            "product_receive_count": summary.product_receive_count,
            "late_remote_ice_candidate_relay_count": summary.late_remote_ice_candidate_relay_count,
            "recorded_at_present": summary.recorded_at_present,
            "session_id_hash_present": summary.session_id_sha256.is_some(),
            "remote_device_id_hash_present": summary.remote_device_id_sha256.is_some(),
            "remote_protocol_public_key_fingerprint_present": summary
                .remote_protocol_public_key_fingerprint
                .is_some(),
        },
        "proof_boundary": {
            "transport_open_proof": true,
            "handshake_proof": summary.proof_level.handshake_proof(),
            "app_control_proof": summary.proof_level.app_control_proof(),
            "mac_product_app_proof": false,
            "not_mac_product_app_proof": summary.not_mac_product_app_proof,
            "remote_product_app_observed": summary.remote_product_app_observed,
            "peer_trust_persistence_proof": summary.peer_trust_persistence_proof,
            "remote_identity_source": summary.remote_identity_source,
            "remote_identity_server_attested": summary.remote_identity_server_attested,
            "not_remote_identity_proof": summary.not_remote_identity_proof,
        },
        "file_transfer": {
            "proven": false,
            "missing_gates": FILE_TRANSFER_REQUIRED_GATES,
        },
        "remote_desktop": {
            "proven": false,
            "missing_gates": remote_desktop_missing_gates,
        },
    })
}

fn remote_desktop_missing_gates_after_product_control(
    proof_level: ProductControlProofLevel,
) -> Vec<&'static str> {
    REMOTE_DESKTOP_REQUIRED_GATES
        .iter()
        .copied()
        .filter(|gate| {
            !(proof_level == ProductControlProofLevel::AppControlSbwcPingPong
                && *gate == "product_control_secure_session")
        })
        .collect()
}

fn execute_remote_desktop_resolutions(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let as_json = has_flag(args, "--json");
    let session_filter_provided =
        optional_option(args, "--session-id").is_some_and(|value| !value.trim().is_empty());
    if args.iter().any(|arg| arg == "--session-id") && !session_filter_provided {
        return Err("missing required option: --session-id".into());
    }
    let payload = json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "live_control_status": "planned_fail_closed",
        "mutation_supported": false,
        "source": "windows_core_cli_contract_only_no_product_session",
        "session_filter_provided": session_filter_provided,
        "observed_modes_status": "planned_fail_closed",
        "observed_modes_source": "windows_core_cli_contract_only_no_agent_snapshot",
        "observed_sessions": [],
        "resolutions": REMOTE_DESKTOP_RESOLUTION_CONTRACT,
        "fps_values": REMOTE_DESKTOP_FPS_CONTRACT,
        "required_gates_before_live_apply": REMOTE_DESKTOP_REQUIRED_GATES,
    });
    write_json_or_text(
        as_json,
        payload,
        "Remote desktop resolution contract is available, but observed sender modes require a product session and agent snapshot.",
        out,
    )
}

struct RemoteDesktopMutationArgs<'a> {
    as_json: bool,
    state_dir: Option<&'a str>,
    session_id: Option<&'a str>,
    resolution: Option<&'a str>,
    fps: Option<&'a str>,
}

impl RemoteDesktopMutationArgs<'_> {
    fn session_id_provided(&self) -> bool {
        self.session_id
            .is_some_and(|value| !value.trim().is_empty())
    }
}

struct RemoteDesktopMutationParseError {
    as_json: bool,
    session_id_provided: bool,
    code: &'static str,
    message: &'static str,
}

fn execute_remote_desktop_mutation(
    args: &[String],
    action: &str,
    out: &mut impl Write,
) -> Result<(), String> {
    let parsed = match parse_remote_desktop_mutation_args(args, action) {
        Ok(parsed) => parsed,
        Err(error) => {
            return fail_json_or_text(
                error.as_json,
                remote_desktop_invalid_request_report(
                    action,
                    error.session_id_provided,
                    error.code,
                    error.message,
                ),
                error.message,
            );
        }
    };
    let as_json = parsed.as_json;
    let session_id_provided = parsed.session_id_provided();
    let resolution_provided = parsed.resolution.is_some();
    let fps_provided = parsed.fps.is_some();
    if let Some(state_dir) = parsed.state_dir {
        let Some(session_id) = parsed.session_id else {
            return fail_json_or_text(
                as_json,
                remote_desktop_invalid_request_report(
                    action,
                    false,
                    "remote_desktop_session_id_required",
                    "remote desktop request registration requires --session-id",
                ),
                "remote desktop request registration requires --session-id",
            );
        };
        let request_action = parse_remote_desktop_action(action)?;
        let payload =
            parse_remote_desktop_request_payload(action, &parsed, as_json, session_id_provided)?;
        let registration = register_remote_desktop_request_for_established_session(
            state_dir,
            session_id,
            request_action,
            payload,
        )
        .map_err(|error| {
            remote_desktop_operator_state_error(
                as_json,
                action,
                session_id_provided,
                resolution_provided,
                fps_provided,
                error,
            )
        })?;
        let payload = remote_desktop_registered_request_report(
            action,
            session_id_provided,
            resolution_provided,
            fps_provided,
            &registration.request,
            registration.pending_requests_for_session,
        );
        return write_json_or_text(
            as_json,
            payload,
            "Remote desktop request registered for agent observation; live apply is not proven.",
            out,
        );
    }
    fail_json_or_text(
        as_json,
        json!({
            "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
            "capability_id": remote_desktop_capability_id(action),
            "action": action,
            "accepted": false,
            "status": "planned_fail_closed",
            "mutation_supported": false,
            "request_registry_supported": false,
            "request_registered": false,
            "pending_agent_observation": false,
            "agent_observed": false,
            "applied": false,
            "session_id_provided": session_id_provided,
            "resolution_provided": resolution_provided,
            "fps_provided": fps_provided,
            "source": "windows_core_cli_contract_only_no_product_session",
            "error": {
                "code": "windows_remote_desktop_agent_missing",
                "message": "Windows core CLI cannot register or apply remote desktop requests without a product-control secure session and agent-owned registry",
                "retryable": false,
                "required_gate": "product_control_secure_session",
            },
            "required_gates_before_live_apply": REMOTE_DESKTOP_REQUIRED_GATES,
        }),
        "Windows remote desktop control requires a product-control secure session, agent-owned request registry, notice artifacts, and real-device media evidence",
    )
}

fn parse_remote_desktop_mutation_args<'a>(
    args: &'a [String],
    action: &str,
) -> Result<RemoteDesktopMutationArgs<'a>, RemoteDesktopMutationParseError> {
    let mut parsed = RemoteDesktopMutationArgs {
        as_json: has_flag(args, "--json"),
        state_dir: None,
        session_id: None,
        resolution: None,
        fps: None,
    };
    let mut json_seen = false;
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                if json_seen {
                    return Err(remote_desktop_parse_error(
                        &parsed,
                        "remote_desktop_duplicate_option",
                        "duplicate remote desktop option",
                    ));
                }
                json_seen = true;
                index += 1;
            }
            "--state-dir" => {
                if parsed.state_dir.is_some() {
                    return Err(remote_desktop_parse_error(
                        &parsed,
                        "remote_desktop_duplicate_option",
                        "duplicate remote desktop option",
                    ));
                }
                parsed.state_dir = Some(required_remote_desktop_flag_value(
                    args,
                    index,
                    &parsed,
                    "--state-dir",
                )?);
                index += 2;
            }
            "--session-id" => {
                if parsed.session_id.is_some() {
                    return Err(remote_desktop_parse_error(
                        &parsed,
                        "remote_desktop_duplicate_option",
                        "duplicate remote desktop option",
                    ));
                }
                parsed.session_id = Some(required_remote_desktop_flag_value(
                    args,
                    index,
                    &parsed,
                    "--session-id",
                )?);
                index += 2;
            }
            "--resolution" => {
                if !matches!(action, "start" | "set-resolution") {
                    return Err(remote_desktop_parse_error(
                        &parsed,
                        "remote_desktop_resolution_not_allowed",
                        "remote desktop action does not accept --resolution",
                    ));
                }
                if parsed.resolution.is_some() {
                    return Err(remote_desktop_parse_error(
                        &parsed,
                        "remote_desktop_duplicate_option",
                        "duplicate remote desktop option",
                    ));
                }
                parsed.resolution = Some(required_remote_desktop_flag_value(
                    args,
                    index,
                    &parsed,
                    "--resolution",
                )?);
                index += 2;
            }
            "--fps" => {
                if !matches!(action, "start" | "set-fps") {
                    return Err(remote_desktop_parse_error(
                        &parsed,
                        "remote_desktop_fps_not_allowed",
                        "remote desktop action does not accept --fps",
                    ));
                }
                if parsed.fps.is_some() {
                    return Err(remote_desktop_parse_error(
                        &parsed,
                        "remote_desktop_duplicate_option",
                        "duplicate remote desktop option",
                    ));
                }
                parsed.fps = Some(required_remote_desktop_flag_value(
                    args, index, &parsed, "--fps",
                )?);
                index += 2;
            }
            value if value.starts_with("--") => {
                return Err(remote_desktop_parse_error(
                    &parsed,
                    "remote_desktop_unsupported_option",
                    "unsupported remote desktop option",
                ));
            }
            _ => {
                return Err(remote_desktop_parse_error(
                    &parsed,
                    "remote_desktop_positional_argument_unsupported",
                    "remote desktop command does not accept positional arguments",
                ));
            }
        }
    }
    if action == "set-resolution" && parsed.resolution.is_none() {
        return Err(remote_desktop_parse_error(
            &parsed,
            "remote_desktop_resolution_required",
            "remote desktop set-resolution requires --resolution",
        ));
    }
    if action == "set-fps" && parsed.fps.is_none() {
        return Err(remote_desktop_parse_error(
            &parsed,
            "remote_desktop_fps_required",
            "remote desktop set-fps requires --fps",
        ));
    }
    if let Some(resolution) = parsed.resolution {
        if !REMOTE_DESKTOP_RESOLUTION_CONTRACT.contains(&resolution) {
            return Err(remote_desktop_parse_error(
                &parsed,
                "remote_desktop_resolution_unsupported",
                "unsupported remote desktop resolution; use remote-desktop resolutions --json for the request contract",
            ));
        }
    }
    if let Some(fps) = parsed.fps {
        let Ok(parsed_fps) = fps.parse::<u16>() else {
            return Err(remote_desktop_parse_error(
                &parsed,
                "remote_desktop_fps_invalid",
                "remote desktop fps must be an unsigned integer",
            ));
        };
        if !remote_desktop_fps_supported(parsed_fps) {
            return Err(remote_desktop_parse_error(
                &parsed,
                "remote_desktop_fps_unsupported",
                "unsupported remote desktop fps; supported request values are 30, 60, and 120",
            ));
        }
    }
    Ok(parsed)
}

fn required_remote_desktop_flag_value<'a>(
    args: &'a [String],
    index: usize,
    parsed: &RemoteDesktopMutationArgs<'_>,
    flag: &'static str,
) -> Result<&'a str, RemoteDesktopMutationParseError> {
    let value = args.get(index + 1).map(String::as_str).ok_or_else(|| {
        remote_desktop_parse_error(
            parsed,
            "remote_desktop_option_value_missing",
            flag_value_message(flag),
        )
    })?;
    if value.starts_with("--") || value.trim().is_empty() {
        return Err(remote_desktop_parse_error(
            parsed,
            "remote_desktop_option_value_missing",
            flag_value_message(flag),
        ));
    }
    Ok(value)
}

fn flag_value_message(flag: &str) -> &'static str {
    match flag {
        "--state-dir" => "remote desktop --state-dir requires a value",
        "--session-id" => "remote desktop --session-id requires a value",
        "--resolution" => "remote desktop --resolution requires a value",
        "--fps" => "remote desktop --fps requires a value",
        _ => "remote desktop option requires a value",
    }
}

fn remote_desktop_parse_error(
    parsed: &RemoteDesktopMutationArgs<'_>,
    code: &'static str,
    message: &'static str,
) -> RemoteDesktopMutationParseError {
    RemoteDesktopMutationParseError {
        as_json: parsed.as_json,
        session_id_provided: parsed.session_id_provided(),
        code,
        message,
    }
}

fn parse_remote_desktop_action(action: &str) -> Result<RemoteDesktopControlAction, String> {
    match action {
        "start" => Ok(RemoteDesktopControlAction::Start),
        "stop" => Ok(RemoteDesktopControlAction::Stop),
        "set-resolution" => Ok(RemoteDesktopControlAction::SetResolution),
        "set-fps" => Ok(RemoteDesktopControlAction::SetFps),
        _ => Err("unsupported remote desktop action".into()),
    }
}

fn parse_remote_desktop_request_payload(
    action: &str,
    parsed: &RemoteDesktopMutationArgs<'_>,
    as_json: bool,
    session_id_provided: bool,
) -> Result<RemoteDesktopControlRequestPayload, String> {
    match action {
        "start" => {
            let resolution = parsed.resolution.unwrap_or("auto");
            let fps = parsed.fps.unwrap_or("60");
            let parsed_fps = fps.parse::<u16>().map_err(|_| {
                json_or_text_invalid_remote_desktop_request(
                    as_json,
                    action,
                    session_id_provided,
                    "remote_desktop_fps_invalid",
                    "remote desktop fps must be an unsigned integer",
                )
            })?;
            Ok(RemoteDesktopControlRequestPayload {
                resolution: Some(remote_desktop_resolution_request(resolution).map_err(|_| {
                    json_or_text_invalid_remote_desktop_request(
                        as_json,
                        action,
                        session_id_provided,
                        "remote_desktop_resolution_unsupported",
                        "unsupported remote desktop resolution; use remote-desktop resolutions --json for the request contract",
                    )
                })?),
                fps: Some(parsed_fps),
            })
        }
        "stop" => Ok(RemoteDesktopControlRequestPayload::default()),
        "set-resolution" => {
            let resolution = parsed.resolution.ok_or_else(|| {
                json_or_text_invalid_remote_desktop_request(
                    as_json,
                    action,
                    session_id_provided,
                    "remote_desktop_resolution_required",
                    "remote desktop set-resolution requires --resolution",
                )
            })?;
            Ok(RemoteDesktopControlRequestPayload {
                resolution: Some(remote_desktop_resolution_request(resolution).map_err(|_| {
                    json_or_text_invalid_remote_desktop_request(
                        as_json,
                        action,
                        session_id_provided,
                        "remote_desktop_resolution_unsupported",
                        "unsupported remote desktop resolution; use remote-desktop resolutions --json for the request contract",
                    )
                })?),
                fps: None,
            })
        }
        "set-fps" => {
            let fps = parsed.fps.ok_or_else(|| {
                json_or_text_invalid_remote_desktop_request(
                    as_json,
                    action,
                    session_id_provided,
                    "remote_desktop_fps_required",
                    "remote desktop set-fps requires --fps",
                )
            })?;
            let parsed_fps = fps.parse::<u16>().map_err(|_| {
                json_or_text_invalid_remote_desktop_request(
                    as_json,
                    action,
                    session_id_provided,
                    "remote_desktop_fps_invalid",
                    "remote desktop fps must be an unsigned integer",
                )
            })?;
            Ok(RemoteDesktopControlRequestPayload {
                resolution: None,
                fps: Some(parsed_fps),
            })
        }
        _ => Err("unsupported remote desktop action".into()),
    }
}

fn json_or_text_invalid_remote_desktop_request(
    as_json: bool,
    action: &str,
    session_id_provided: bool,
    code: &'static str,
    message: &'static str,
) -> String {
    if as_json {
        json_string(remote_desktop_invalid_request_report(
            action,
            session_id_provided,
            code,
            message,
        ))
        .unwrap_or_else(|_| message.to_string())
    } else {
        message.to_string()
    }
}

fn remote_desktop_registered_request_report(
    action: &str,
    session_id_provided: bool,
    resolution_provided: bool,
    fps_provided: bool,
    request: &RemoteDesktopControlRequest,
    pending_requests_for_session: usize,
) -> serde_json::Value {
    json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": remote_desktop_capability_id(action),
        "action": action,
        "accepted": true,
        "status": "request_registered",
        "live_control_status": "pending_agent_observation",
        "mutation_supported": false,
        "request_registry_supported": true,
        "request_registered": true,
        "pending_agent_observation": true,
        "agent_observed": false,
        "applied": false,
        "session_id_provided": session_id_provided,
        "resolution_provided": resolution_provided,
        "fps_provided": fps_provided,
        "source": "windows_operator_state_remote_desktop_request_registry",
        "request": remote_desktop_request_report(request),
        "pending_requests_for_session": pending_requests_for_session,
        "proof_boundary": {
            "request_registered_not_live_apply": true,
            "product_control_session_required": true,
            "remote_desktop_apply_proof": false,
            "file_transfer_receipt_proof": false,
            "mac_product_app_proof": false,
        },
        "remote_desktop": {
            "proven": false,
            "missing_gates": remote_desktop_missing_gates_after_registered_request(),
        },
        "required_gates_before_live_apply": REMOTE_DESKTOP_REQUIRED_GATES,
    })
}

fn remote_desktop_request_report(request: &RemoteDesktopControlRequest) -> serde_json::Value {
    json!({
        "request_id": request.request_id,
        "action": request.action.as_str(),
        "status": request.status.as_str(),
        "resolution": request
            .payload
            .resolution
            .as_ref()
            .map(|resolution| resolution.id().to_string()),
        "fps": request.payload.fps,
        "target_runtime_bound": true,
        "created_at_unix_ms": request.created_at_unix_ms,
        "updated_at_unix_ms": request.updated_at_unix_ms,
    })
}

fn remote_desktop_operator_state_error(
    as_json: bool,
    action: &str,
    session_id_provided: bool,
    resolution_provided: bool,
    fps_provided: bool,
    error: OperatorStateError,
) -> String {
    let (code, retryable, message) = remote_desktop_operator_state_error_fields(error);
    if as_json {
        return json_string(json!({
            "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
            "capability_id": remote_desktop_capability_id(action),
            "action": action,
            "accepted": false,
            "status": "request_rejected",
            "mutation_supported": false,
            "request_registry_supported": true,
            "request_registered": false,
            "pending_agent_observation": false,
            "agent_observed": false,
            "applied": false,
            "session_id_provided": session_id_provided,
            "resolution_provided": resolution_provided,
            "fps_provided": fps_provided,
            "source": "windows_operator_state_remote_desktop_request_registry",
            "error": {
                "code": code,
                "message": message,
                "retryable": retryable,
                "required_gate": "windows_operator_state_registry",
            },
            "required_gates_before_live_apply": REMOTE_DESKTOP_REQUIRED_GATES,
        }))
        .unwrap_or_else(|_| message.to_string());
    }
    message.to_string()
}

fn remote_desktop_operator_state_error_fields(
    error: OperatorStateError,
) -> (&'static str, bool, &'static str) {
    match error {
        OperatorStateError::MissingStateDir => (
            "remote_desktop_state_dir_missing",
            false,
            "remote desktop request registration requires an operator state directory",
        ),
        OperatorStateError::StateDirUnavailable | OperatorStateError::StateDirNotDirectory => (
            "remote_desktop_state_dir_unavailable",
            false,
            "remote desktop operator state directory is unavailable",
        ),
        OperatorStateError::UnsafePath => (
            "remote_desktop_state_dir_unsafe",
            false,
            "remote desktop operator state path contains an unsafe path component",
        ),
        OperatorStateError::SessionRegistryMissing => (
            "remote_desktop_session_registry_missing",
            false,
            "remote desktop request registration requires an agent-owned session registry",
        ),
        OperatorStateError::SessionRegistryRead
        | OperatorStateError::SessionRegistryJson
        | OperatorStateError::SessionRegistrySchema
        | OperatorStateError::SessionRegistryInvalid
        | OperatorStateError::SessionRegistryTooLarge
        | OperatorStateError::InvalidSessionBinding
        | OperatorStateError::SessionBindingConflict
        | OperatorStateError::SessionRegistryWrite
        | OperatorStateError::SessionRegistryPersistVerify => (
            "remote_desktop_session_registry_invalid",
            false,
            "remote desktop session registry is invalid",
        ),
        OperatorStateError::SessionNotFound => (
            "remote_desktop_session_not_found",
            false,
            "remote desktop session was not found in the operator registry",
        ),
        OperatorStateError::SessionNotEstablished => (
            "remote_desktop_session_not_established",
            false,
            "remote desktop session is not established for request registration",
        ),
        OperatorStateError::SessionStale => (
            "remote_desktop_session_stale",
            false,
            "remote desktop session registry entry is stale",
        ),
        OperatorStateError::RequestRegistryRead
        | OperatorStateError::RequestRegistryJson
        | OperatorStateError::RequestRegistrySchema
        | OperatorStateError::RequestRegistryInvalid => (
            "remote_desktop_request_registry_invalid",
            false,
            "remote desktop request registry is invalid",
        ),
        OperatorStateError::InvalidRequestPayload => (
            "remote_desktop_request_payload_invalid",
            false,
            "remote desktop request payload is invalid",
        ),
        OperatorStateError::PendingRequestExists => (
            "remote_desktop_pending_request_exists",
            false,
            "remote desktop session already has a pending request awaiting agent observation",
        ),
        OperatorStateError::RequestRegistryFull => (
            "remote_desktop_request_registry_full",
            false,
            "remote desktop request registry is full",
        ),
        OperatorStateError::RegistryLocked => (
            "remote_desktop_registry_locked",
            true,
            "remote desktop operator registry is locked by another process",
        ),
        OperatorStateError::RequestRegistryWrite
        | OperatorStateError::RequestRegistryPersistVerify => (
            "remote_desktop_request_registry_write_failed",
            true,
            "remote desktop request registry could not be persisted",
        ),
        OperatorStateError::FileTransferRequestRegistryRead
        | OperatorStateError::FileTransferRequestRegistryJson
        | OperatorStateError::FileTransferRequestRegistrySchema
        | OperatorStateError::FileTransferRequestRegistryInvalid
        | OperatorStateError::FileTransferRequestRegistryWrite
        | OperatorStateError::FileTransferRequestRegistryPersistVerify
        | OperatorStateError::InvalidPeerRef
        | OperatorStateError::PeerBindingMissing
        | OperatorStateError::PeerMismatch
        | OperatorStateError::FileTransferSourceMissing
        | OperatorStateError::FileTransferSourceUnsafe
        | OperatorStateError::FileTransferSourceNotRegularFile
        | OperatorStateError::FileTransferSourceRead
        | OperatorStateError::FileTransferHashFailed
        | OperatorStateError::NearbyDiscoverySnapshotMissing
        | OperatorStateError::NearbyDiscoveryActiveScanSnapshotMissing
        | OperatorStateError::NearbyDiscoverySnapshotStale
        | OperatorStateError::NearbyDiscoveryActiveScanSnapshotStale
        | OperatorStateError::NearbyDiscoverySnapshotRegistryRead
        | OperatorStateError::NearbyDiscoverySnapshotRegistryJson
        | OperatorStateError::NearbyDiscoverySnapshotRegistrySchema
        | OperatorStateError::NearbyDiscoverySnapshotRegistryInvalid
        | OperatorStateError::NearbyDiscoverySnapshotRegistryTooLarge => (
            "remote_desktop_request_registry_invalid",
            false,
            "remote desktop request registry is invalid",
        ),
        OperatorStateError::Clock => (
            "remote_desktop_clock_invalid",
            true,
            "system clock cannot be used for remote desktop request registration",
        ),
    }
}

fn remote_desktop_missing_gates_after_registered_request() -> Vec<&'static str> {
    REMOTE_DESKTOP_REQUIRED_GATES
        .iter()
        .copied()
        .filter(|gate| *gate != "product_control_secure_session")
        .collect()
}

fn remote_desktop_invalid_request_report(
    action: &str,
    session_id_provided: bool,
    code: &'static str,
    message: &'static str,
) -> serde_json::Value {
    json!({
        "schema_version": OPERATOR_CONTRACT_SCHEMA_VERSION,
        "capability_id": remote_desktop_capability_id(action),
        "action": action,
        "accepted": false,
        "status": "request_invalid",
        "mutation_supported": false,
        "request_registry_supported": false,
        "request_registered": false,
        "pending_agent_observation": false,
        "agent_observed": false,
        "applied": false,
        "session_id_provided": session_id_provided,
        "source": "windows_core_cli_request_contract_validation",
        "error": {
            "code": code,
            "message": message,
            "retryable": false,
            "required_gate": "remote_desktop_request_contract",
        },
        "required_gates_before_live_apply": REMOTE_DESKTOP_REQUIRED_GATES,
    })
}

fn remote_desktop_capability_id(action: &str) -> &'static str {
    match action {
        "stop" => "remote_desktop.stop",
        "set-resolution" => "remote_desktop.resolution.set",
        "set-fps" => "remote_desktop.fps.set",
        _ => "remote_desktop.start",
    }
}

fn write_json_or_text(
    as_json: bool,
    payload: serde_json::Value,
    text: &str,
    out: &mut impl Write,
) -> Result<(), String> {
    if as_json {
        writeln!(out, "{}", json_string(payload)?).map_err(|err| err.to_string())?;
    } else {
        writeln!(out, "{text}").map_err(|err| err.to_string())?;
    }
    Ok(())
}

fn fail_json_or_text(as_json: bool, payload: serde_json::Value, text: &str) -> Result<(), String> {
    if as_json {
        Err(json_string(payload)?)
    } else {
        Err(text.to_owned())
    }
}

fn json_string(payload: serde_json::Value) -> Result<String, String> {
    serde_json::to_string_pretty(&payload).map_err(|err| err.to_string())
}

fn execute_transport(args: &[String], out: &mut impl Write) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("select") => execute_transport_select(args, out),
        Some("bind") => execute_transport_bind(args, out),
        _ => Err("expected transport select or transport bind".into()),
    }
}

fn execute_transport_select(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let local = required_option(args, "--local")?;
    let remote = required_option(args, "--remote")?;
    let path = required_option(args, "--path")?;
    let plan = TransportSelector::select(
        default_capabilities(parse_platform(local)?),
        default_capabilities(parse_platform(remote)?),
        parse_path(path)?,
    );

    print_transport_plan(plan, out)
}

fn execute_transport_bind(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let material = TransportBindingMaterial {
        transport_kind: parse_transport_kind(required_option(args, "--transport")?)?,
        local_endpoint: required_option(args, "--local-endpoint")?.to_string(),
        remote_endpoint: required_option(args, "--remote-endpoint")?.to_string(),
        selected_candidate_pair: required_option(args, "--candidate-pair")?.to_string(),
        transport_secret_fingerprint: required_option(args, "--secret-fp")?.as_bytes().to_vec(),
        relay_id: optional_option(args, "--relay-id")
            .filter(|value| !value.is_empty())
            .map(str::to_string),
        timestamp_window_ms: parse_u64(
            required_option(args, "--timestamp-window-ms")?,
            "--timestamp-window-ms",
        )?,
        capability_digest: required_option(args, "--capability-digest")?
            .as_bytes()
            .to_vec(),
    };
    let digest = material.transcript_digest();

    writeln!(out, "transport={:?}", material.transport_kind).map_err(|err| err.to_string())?;
    writeln!(
        out,
        "relay_id={}",
        material.relay_id.as_deref().unwrap_or("none")
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "timestamp_window_ms={}", material.timestamp_window_ms)
        .map_err(|err| err.to_string())?;
    writeln!(out, "binding_digest={}", format_hex(&digest)).map_err(|err| err.to_string())?;
    Ok(())
}

fn execute_suite(args: &[String], out: &mut impl Write) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("offer") => {
            let caps = parse_crypto_caps(required_option(args, "--caps")?)?;
            let suites = offered_suites(caps, parse_suite_policy(args));
            print_suites(&suites, out)
        }
        Some("select") => {
            let local = parse_crypto_caps(required_option(args, "--local-caps")?)?;
            let remote = parse_suite_id_list(required_option(args, "--remote-suites")?)?;
            let selected = negotiate_suite(local, &remote, parse_suite_policy(args))
                .map_err(|err| format!("suite negotiation failed: {err:?}"))?;
            writeln!(
                out,
                "suite={} ({:#06x})",
                selected.suite.name(),
                selected.suite.wire_id()
            )
            .map_err(|err| err.to_string())?;
            writeln!(out, "audit={:?}", selected.audit).map_err(|err| err.to_string())?;
            Ok(())
        }
        _ => Err("expected suite offer or suite select".into()),
    }
}

fn execute_pqc(args: &[String], out: &mut impl Write) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("status") => execute_pqc_status(args, out),
        Some("offer") | Some("select") => execute_suite(args, out),
        _ => Err("expected pqc status, pqc offer, or pqc select".into()),
    }
}

fn execute_pqc_status(args: &[String], out: &mut impl Write) -> Result<(), String> {
    let as_json = match args {
        [command] if command == "status" => false,
        [command, flag] if command == "status" && flag == "--json" => true,
        _ => return Err("expected pqc status [--json]".into()),
    };
    let supported_suites = native_pqc_strict_suites();
    let supported_suite_ids = format_suite_ids(&supported_suites);

    if as_json {
        let payload = json!({
            "schema_version": CAPABILITY_SCHEMA_VERSION,
            "capability_id": "pqc.handshake",
            "status": "read_only",
            "suite_negotiation_supported": true,
            "strict_pqc_policy_available": true,
            "classic_fallback_allowed": false,
            "legacy_p256_allowed": false,
            "handshake_proven": false,
            "live_runtime_started": false,
            "mutation_supported": false,
            "session_created": false,
            "supported_suite_ids": supported_suite_ids,
            "supported_suites": supported_suites
                .iter()
                .map(|suite| {
                    json!({
                        "name": suite.name(),
                        "wire_id": format!("{:#06x}", suite.wire_id()),
                        "post_quantum": !suite.is_classic(),
                    })
                })
                .collect::<Vec<_>>(),
            "provider_capabilities": {
                "xwing_hybrid": true,
                "mlkem_768_mldsa_65": true,
                "x25519_ed25519": false,
                "p256_ecdsa": true,
            },
            "proof_boundary": {
                "suite_negotiation_not_handshake_proof": true,
                "no_peer_identity_verified": true,
                "no_session_keys_derived": true,
                "no_sbwc_secure_session_established": true,
            },
            "missing_gates": PQC_HANDSHAKE_MISSING_GATES,
        });
        writeln!(out, "{}", json_string(payload)?).map_err(|err| err.to_string())?;
        return Ok(());
    }

    writeln!(out, "capability_id=pqc.handshake").map_err(|err| err.to_string())?;
    writeln!(out, "status=read_only").map_err(|err| err.to_string())?;
    writeln!(out, "suite_negotiation_supported=true").map_err(|err| err.to_string())?;
    writeln!(out, "strict_pqc_policy_available=true").map_err(|err| err.to_string())?;
    writeln!(out, "handshake_proven=false").map_err(|err| err.to_string())?;
    writeln!(out, "live_runtime_started=false").map_err(|err| err.to_string())?;
    writeln!(out, "mutation_supported=false").map_err(|err| err.to_string())?;
    writeln!(out, "session_created=false").map_err(|err| err.to_string())?;
    writeln!(out, "supported_suite_ids={}", supported_suite_ids.join(","))
        .map_err(|err| err.to_string())?;
    writeln!(out, "proof_boundary=suite_negotiation_not_handshake_proof")
        .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "missing_gates={}",
        PQC_HANDSHAKE_MISSING_GATES.join(",")
    )
    .map_err(|err| err.to_string())?;
    Ok(())
}

fn execute_channel(args: &[String], out: &mut impl Write) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("profile") => {
            let channel = parse_channel(required_option(args, "--channel")?)?;
            let reliability = channel.default_reliability();

            writeln!(out, "channel={channel:?}").map_err(|err| err.to_string())?;
            writeln!(out, "reliability={}", format_reliability(reliability))
                .map_err(|err| err.to_string())?;
            Ok(())
        }
        Some("map") => {
            let transport = parse_transport_kind(required_option(args, "--transport")?)?;
            let channel = parse_channel(required_option(args, "--channel")?)?;
            let profile = map_channel(transport, channel)
                .map_err(|err| format!("channel map failed: {err:?}"))?;

            writeln!(out, "channel={:?}", profile.channel).map_err(|err| err.to_string())?;
            writeln!(out, "transport={transport:?}").map_err(|err| err.to_string())?;
            writeln!(out, "binding={}", profile.binding.label()).map_err(|err| err.to_string())?;
            writeln!(
                out,
                "reliability={}",
                format_reliability(profile.reliability)
            )
            .map_err(|err| err.to_string())?;
            writeln!(
                out,
                "head_of_line_isolated={}",
                profile.binding.isolates_head_of_line_blocking()
            )
            .map_err(|err| err.to_string())?;
            Ok(())
        }
        _ => Err("expected channel profile or channel map".into()),
    }
}

fn execute_frame(args: &[String], out: &mut impl Write) -> Result<(), String> {
    if args.first().map(String::as_str) != Some("describe") {
        return Err("expected frame describe".into());
    }

    let channel = parse_channel(required_option(args, "--channel")?)?;
    let sequence = parse_u64(required_option(args, "--sequence")?, "--sequence")?;
    let payload = required_option(args, "--payload")?.as_bytes().to_vec();
    let encoded = if let Some(padded) = optional_option(args, "--sbp2-fixed") {
        encode_sbp2_frame(
            channel,
            sequence,
            &payload,
            parse_usize(padded, "--sbp2-fixed")?,
        )
        .map_err(|err| format!("frame encode failed: {err:?}"))?
    } else {
        encode_frame(&CoreFrame {
            channel,
            sequence,
            flags: FrameFlags::END_OF_MESSAGE,
            payload,
        })
        .map_err(|err| format!("frame encode failed: {err:?}"))?
    };
    let decoded = decode_frame(&encoded).map_err(|err| format!("frame decode failed: {err:?}"))?;
    let decoded_payload =
        decode_frame_payload(&decoded).map_err(|err| format!("payload decode failed: {err:?}"))?;

    writeln!(out, "channel={:?}", decoded.channel).map_err(|err| err.to_string())?;
    writeln!(out, "sequence={}", decoded.sequence).map_err(|err| err.to_string())?;
    writeln!(out, "flags={:#06x}", decoded.flags.bits()).map_err(|err| err.to_string())?;
    writeln!(out, "frame_len={}", encoded.len()).map_err(|err| err.to_string())?;
    writeln!(out, "payload_len={}", decoded_payload.len()).map_err(|err| err.to_string())?;
    Ok(())
}

fn execute_connection(args: &[String], out: &mut impl Write) -> Result<(), String> {
    if args.first().map(String::as_str) != Some("plan") {
        return Err("expected connection plan".into());
    }

    let traffic_padding = optional_option(args, "--sbp2-fixed")
        .map(|value| parse_usize(value, "--sbp2-fixed"))
        .transpose()?
        .map(TrafficPaddingPlan::sbp2_fixed)
        .unwrap_or_else(TrafficPaddingPlan::disabled);

    let request = ConnectionRequest {
        local: default_capabilities(parse_platform(required_option(args, "--local")?)?),
        remote: default_capabilities(parse_platform(required_option(args, "--remote")?)?),
        path: parse_path(required_option(args, "--path")?)?,
        local_crypto: parse_crypto_caps(required_option(args, "--local-caps")?)?,
        remote_suite_wire_ids: parse_suite_id_list(required_option(args, "--remote-suites")?)?,
        suite_policy: parse_suite_policy(args),
        traffic_padding,
    };

    let plan =
        plan_connection(request).map_err(|err| format!("connection plan failed: {err:?}"))?;
    print_connection_plan(&plan, out)
}

fn execute_discovery(args: &[String], out: &mut impl Write) -> Result<(), String> {
    if args.first().map(String::as_str) != Some("parse") {
        return Err("expected discovery parse".into());
    }

    let service = parse_service_kind(required_option(args, "--service")?)
        .ok_or_else(|| "unsupported discovery service".to_string())?;
    let advertisement = parse_txt_advertisement(required_option(args, "--txt")?)
        .map_err(|err| format!("discovery TXT parse failed: {err:?}"))?;
    let capabilities = advertisement.peer_capabilities();

    writeln!(out, "service={}", format_service(service)).map_err(|err| err.to_string())?;
    writeln!(out, "device_id={}", advertisement.device_id).map_err(|err| err.to_string())?;
    writeln!(
        out,
        "public_key_fingerprint={}",
        advertisement.public_key_fingerprint
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "platform={:?}", advertisement.platform).map_err(|err| err.to_string())?;
    writeln!(out, "platform_label={}", advertisement.platform_label)
        .map_err(|err| err.to_string())?;
    writeln!(out, "name={}", advertisement.name).map_err(|err| err.to_string())?;
    writeln!(out, "version={}", advertisement.protocol_version).map_err(|err| err.to_string())?;
    writeln!(out, "capabilities={}", advertisement.capabilities.join(","))
        .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "supports_apple_native={}",
        capabilities.supports_apple_native
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "supports_msquic={}", capabilities.supports_msquic)
        .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "supports_webrtc_data_channel={}",
        capabilities.supports_webrtc_data_channel
    )
    .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "supports_tcp_fallback={}",
        capabilities.supports_tcp_fallback
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "supports_relay={}", capabilities.supports_relay)
        .map_err(|err| err.to_string())?;
    Ok(())
}

fn execute_webrtc_proof(args: &[String], out: &mut impl Write) -> Result<(), String> {
    if args.first().map(String::as_str) != Some("validate") {
        return Err("expected webrtc-proof validate".into());
    }

    let proof_path = required_option(args, "--proof")?;
    let expected_device_id = required_option(args, "--expected-device-id")?;
    let expected_fingerprint = required_option(args, "--expected-fingerprint")?;
    let max_age_ms = optional_option(args, "--max-age-ms")
        .map(|value| parse_u64(value, "--max-age-ms"))
        .transpose()?
        .unwrap_or(60_000);
    let json = fs::read_to_string(proof_path)
        .map_err(|err| format!("failed to read WebRTC proof: {err}"))?;
    let summary =
        validate_webrtc_proof_json(&json, expected_device_id, expected_fingerprint, max_age_ms)
            .map_err(|err| format!("webrtc proof validation failed: {err}"))?;

    writeln!(out, "webrtc_proof=valid").map_err(|err| err.to_string())?;
    writeln!(out, "peer_device_id={}", summary.peer_device_id).map_err(|err| err.to_string())?;
    writeln!(
        out,
        "peer_public_key_fingerprint={}",
        summary.peer_public_key_fingerprint
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "helper_name={}", summary.helper_name).map_err(|err| err.to_string())?;
    writeln!(out, "adapter_binding={}", summary.adapter_binding).map_err(|err| err.to_string())?;
    writeln!(out, "local_endpoint={}", summary.local_endpoint).map_err(|err| err.to_string())?;
    writeln!(out, "remote_endpoint={}", summary.remote_endpoint).map_err(|err| err.to_string())?;
    writeln!(
        out,
        "selected_candidate_pair={}",
        summary.selected_candidate_pair
    )
    .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "relay_id={}",
        summary.relay_id.as_deref().unwrap_or("none")
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "timestamp_window_ms={}", summary.timestamp_window_ms)
        .map_err(|err| err.to_string())?;
    writeln!(out, "proof_age_ms={}", summary.proof_age_ms).map_err(|err| err.to_string())?;
    Ok(())
}

fn has_flag(args: &[String], name: &str) -> bool {
    args.iter().any(|arg| arg == name)
}

fn optional_option<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.windows(2)
        .find(|window| window[0] == name)
        .map(|window| window[1].as_str())
}

fn required_option<'a>(args: &'a [String], name: &str) -> Result<&'a str, String> {
    args.windows(2)
        .find(|window| window[0] == name)
        .map(|window| window[1].as_str())
        .ok_or_else(|| format!("missing required option: {name}"))
}

fn parse_u64(value: &str, name: &str) -> Result<u64, String> {
    value
        .parse::<u64>()
        .map_err(|_| format!("invalid {name}: {value}"))
}

fn parse_usize(value: &str, name: &str) -> Result<usize, String> {
    value
        .parse::<usize>()
        .map_err(|_| format!("invalid {name}: {value}"))
}

fn parse_platform(value: &str) -> Result<PeerPlatform, String> {
    match normalize(value).as_str() {
        "apple" | "mac" | "macos" | "ios" => Ok(PeerPlatform::Apple),
        "windows" | "win" => Ok(PeerPlatform::Windows),
        other => Err(format!("unsupported platform: {other}")),
    }
}

fn default_capabilities(platform: PeerPlatform) -> PeerCapabilities {
    match platform {
        PeerPlatform::Apple => PeerCapabilities::apple(),
        PeerPlatform::Windows => PeerCapabilities::windows(),
        PeerPlatform::Unknown => PeerCapabilities {
            platform,
            supports_apple_native: false,
            supports_msquic: false,
            supports_skybridge_ice_msquic: false,
            supports_webrtc_data_channel: false,
            supports_tcp_fallback: false,
            supports_relay: false,
        },
    }
}

fn parse_path(value: &str) -> Result<NetworkPath, String> {
    match normalize(value).as_str() {
        "same-lan" | "lan" | "local" => Ok(NetworkPath::same_lan()),
        "cross-nat" | "nat" | "remote" => Ok(NetworkPath::cross_nat()),
        other => Err(format!("unsupported path: {other}")),
    }
}

fn parse_channel(value: &str) -> Result<SkyBridgeChannel, String> {
    match normalize(value).as_str() {
        "control" => Ok(SkyBridgeChannel::Control),
        "file" => Ok(SkyBridgeChannel::File),
        "clipboard" => Ok(SkyBridgeChannel::Clipboard),
        "telemetry" => Ok(SkyBridgeChannel::Telemetry),
        "realtime" | "real-time" => Ok(SkyBridgeChannel::Realtime),
        other => Err(format!("unsupported channel: {other}")),
    }
}

fn parse_transport_kind(value: &str) -> Result<SkyBridgeTransportKind, String> {
    match normalize(value).as_str() {
        "apple-native" | "apple" => Ok(SkyBridgeTransportKind::AppleNative),
        "msquic" | "windows-msquic" | "windows-native-msquic" => {
            Ok(SkyBridgeTransportKind::WindowsNativeMsQuic)
        }
        "skybridge-ice-msquic" | "ice-msquic" => Ok(SkyBridgeTransportKind::SkyBridgeIceMsQuic),
        "webrtc" | "webrtc-dc" | "webrtc-datachannel" => {
            Ok(SkyBridgeTransportKind::WebRtcDataChannel)
        }
        "relay" => Ok(SkyBridgeTransportKind::Relay),
        "tcp" | "tcp-fallback" => Ok(SkyBridgeTransportKind::TcpFallback),
        other => Err(format!("unsupported transport: {other}")),
    }
}

fn parse_crypto_caps(value: &str) -> Result<CryptoProviderCapabilities, String> {
    let mut caps = CryptoProviderCapabilities::empty();
    for raw in value.split(',') {
        match normalize(raw).as_str() {
            "" => {}
            "all" | "research-all" => caps = CryptoProviderCapabilities::research_all(),
            "current-p256" => caps = CryptoProviderCapabilities::current_p256(),
            "xwing" | "x-wing" | "x-wing-hybrid" => caps.supports_xwing_hybrid = true,
            "mlkem" | "ml-kem" | "ml-kem-768" | "ml-kem-768-ml-dsa-65" => {
                caps.supports_mlkem_768_mldsa_65 = true;
            }
            "x25519" | "x25519-ed25519" => caps.supports_x25519_ed25519 = true,
            "p256" | "p-256" | "p256-ecdsa" => caps.supports_p256_ecdsa = true,
            other => return Err(format!("unsupported crypto capability: {other}")),
        }
    }
    Ok(caps)
}

fn parse_suite_policy(args: &[String]) -> CryptoSuitePolicy {
    CryptoSuitePolicy {
        allow_classic_fallback: has_flag(args, "--allow-classic"),
        allow_legacy_p256: has_flag(args, "--allow-legacy-p256"),
        timeout_observed: has_flag(args, "--timeout-observed"),
    }
}

fn parse_suite_id_list(value: &str) -> Result<Vec<u16>, String> {
    value
        .split(',')
        .filter(|part| !part.trim().is_empty())
        .map(parse_suite_id)
        .collect()
}

fn parse_suite_id(value: &str) -> Result<u16, String> {
    let value = value.trim();
    if let Some(hex) = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
    {
        return u16::from_str_radix(hex, 16).map_err(|_| format!("invalid suite id: {value}"));
    }

    value
        .parse::<u16>()
        .map_err(|_| format!("invalid suite id: {value}"))
}

fn print_transport_plan(plan: TransportPlan, out: &mut impl Write) -> Result<(), String> {
    writeln!(
        out,
        "kind={}",
        plan.kind
            .map(|kind| format!("{kind:?}"))
            .unwrap_or_else(|| "Unsupported".into())
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "audit={:?}", plan.audit_reason).map_err(|err| err.to_string())?;
    writeln!(out, "priority={}", plan.priority).map_err(|err| err.to_string())?;
    writeln!(
        out,
        "relay_allowed={}",
        matches!(
            plan.relay_policy,
            crate::transport::RelayPolicy::Allowed | crate::transport::RelayPolicy::Required
        )
    )
    .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "relay_required={}",
        matches!(plan.relay_policy, crate::transport::RelayPolicy::Required)
    )
    .map_err(|err| err.to_string())?;
    Ok(())
}

fn print_suites(suites: &[CryptoSuite], out: &mut impl Write) -> Result<(), String> {
    if suites.is_empty() {
        writeln!(out, "suites=").map_err(|err| err.to_string())?;
        return Ok(());
    }

    for suite in suites {
        writeln!(out, "{}={:#06x}", suite.name(), suite.wire_id())
            .map_err(|err| err.to_string())?;
    }
    Ok(())
}

fn print_connection_plan(plan: &ConnectionPlan, out: &mut impl Write) -> Result<(), String> {
    writeln!(out, "transport={:?}", plan.transport_kind).map_err(|err| err.to_string())?;
    writeln!(out, "transport_audit={:?}", plan.transport.audit_reason)
        .map_err(|err| err.to_string())?;
    writeln!(out, "transport_priority={}", plan.transport.priority)
        .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "suite={} ({:#06x})",
        plan.selected_suite.suite.name(),
        plan.selected_suite.suite.wire_id()
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "suite_audit={:?}", plan.selected_suite.audit).map_err(|err| err.to_string())?;
    writeln!(
        out,
        "offered_suites={}",
        format_suite_list(&plan.offered_suites)
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "sbp2_enabled={}", plan.traffic_padding.sbp2_enabled)
        .map_err(|err| err.to_string())?;
    writeln!(
        out,
        "sbp2_fixed_payload_len={}",
        plan.traffic_padding
            .fixed_payload_len
            .map(|len| len.to_string())
            .unwrap_or_else(|| "none".into())
    )
    .map_err(|err| err.to_string())?;
    writeln!(out, "frame_header_len={}", plan.frame_header_len).map_err(|err| err.to_string())?;
    writeln!(out, "channel_count={}", plan.channels.len()).map_err(|err| err.to_string())?;
    for profile in &plan.channels {
        writeln!(
            out,
            "channel.{}={}:{}:{}:head_of_line_isolated={}",
            format_channel_key(profile.channel),
            format_binding_kind(&profile.binding),
            profile.binding.label(),
            format_reliability(profile.reliability),
            profile.binding.isolates_head_of_line_blocking()
        )
        .map_err(|err| err.to_string())?;
    }
    Ok(())
}

fn format_suite_list(suites: &[CryptoSuite]) -> String {
    suites
        .iter()
        .map(|suite| format!("{}:{:#06x}", suite.name(), suite.wire_id()))
        .collect::<Vec<_>>()
        .join(",")
}

fn native_pqc_strict_suites() -> Vec<CryptoSuite> {
    offered_suites(
        CryptoProviderCapabilities::with_native_pqc(),
        CryptoSuitePolicy::strict_pqc(),
    )
}

fn format_suite_ids(suites: &[CryptoSuite]) -> Vec<String> {
    suites
        .iter()
        .map(|suite| format!("{:#06x}", suite.wire_id()))
        .collect()
}

fn format_channel_key(channel: SkyBridgeChannel) -> &'static str {
    match channel {
        SkyBridgeChannel::Control => "control",
        SkyBridgeChannel::File => "file",
        SkyBridgeChannel::Clipboard => "clipboard",
        SkyBridgeChannel::Telemetry => "telemetry",
        SkyBridgeChannel::Realtime => "realtime",
    }
}

fn format_binding_kind(binding: &AdapterChannelBinding) -> &'static str {
    match binding {
        AdapterChannelBinding::AppleStream { .. } => "AppleStream",
        AdapterChannelBinding::AppleDatagram { .. } => "AppleDatagram",
        AdapterChannelBinding::MsQuicStream { .. } => "MsQuicStream",
        AdapterChannelBinding::MsQuicDatagram { .. } => "MsQuicDatagram",
        AdapterChannelBinding::WebRtcDataChannel { .. } => "WebRtcDataChannel",
        AdapterChannelBinding::RelayStream { .. } => "RelayStream",
        AdapterChannelBinding::TcpStream { .. } => "TcpStream",
    }
}

fn format_service(service: DiscoveryServiceKind) -> &'static str {
    service.service_type()
}

fn format_reliability(reliability: SkyBridgeReliability) -> String {
    match reliability {
        SkyBridgeReliability::ReliableOrdered => "reliable-ordered".into(),
        SkyBridgeReliability::ReliableUnordered => "reliable-unordered".into(),
        SkyBridgeReliability::PartialReliable { max_retransmits } => {
            format!("partial-reliable:{max_retransmits}")
        }
        SkyBridgeReliability::Unreliable => "unreliable".into(),
    }
}

fn format_hex(bytes: &[u8]) -> String {
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        write!(&mut output, "{byte:02x}").expect("write to String");
    }
    output
}

fn normalize(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const WEBRTC_PROOF_FINGERPRINT: &str =
        "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

    fn run_cli(args: &[&str]) -> (i32, String, String) {
        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = run(args.iter().copied(), &mut out, &mut err);
        (
            code,
            String::from_utf8(out).unwrap(),
            String::from_utf8(err).unwrap(),
        )
    }

    fn write_webrtc_proof_fixture(file_name: &str, sbf1_echo_verified: bool) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "skybridge-cli-webrtc-proof-{}-{file_name}.json",
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
        let dir = std::env::current_dir()
            .unwrap()
            .join("target")
            .join("test-fixtures");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!(
            "skybridge-cli-product-control-evidence-{}-{file_name}.json",
            std::process::id()
        ));
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

    fn make_operator_state_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::current_dir()
            .unwrap()
            .join("target")
            .join("test-fixtures")
            .join(format!(
                "skybridge-cli-operator-state-{}-{name}",
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
        expires_at_unix_ms: i64,
    ) {
        let session_registry = format!(
            r#"{{
  "schema_version": 1,
  "sessions": {{
    "{session_id}": {{
      "schema_version": 1,
      "session_id": "{session_id}",
      "target_runtime_id": "windows-runtime-1",
      "state": "{session_state}",
      "secure_session_state": "Established",
      "readiness": {{
        "kind": "product_control_secure_session"
      }},
      "created_at_unix_ms": 1783296000000,
      "updated_at_unix_ms": 1783296000000,
      "expires_at_unix_ms": {expires_at_unix_ms}
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

    #[test]
    fn version_command_reports_package_version() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(["version"], &mut out, &mut err);

        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert_eq!(
            String::from_utf8(out).unwrap(),
            format!("skybridge-core {}\n", env!("CARGO_PKG_VERSION"))
        );
    }

    #[test]
    fn version_json_reports_windows_contract_identity() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(["version", "--json"], &mut out, &mut err);

        assert_eq!(code, 0);
        assert!(err.is_empty());
        let stdout = String::from_utf8(out).unwrap();
        let payload: serde_json::Value = serde_json::from_str(&stdout).unwrap();
        assert_eq!(payload["product_name"], "SkyBridge CLI");
        assert_eq!(payload["binary_name"], "skybridge");
        assert_eq!(payload["platform"], "windows");
        assert_eq!(payload["surface"], "windows_protocol_diagnostic");
        assert_eq!(payload["cli_version"], env!("CARGO_PKG_VERSION"));
        assert_eq!(payload["contracts_schema_version"], 1);
        assert_eq!(payload["mac_gui_control_supported"], false);
        assert_eq!(payload["ios_runtime_control_supported"], false);
    }

    #[test]
    fn capabilities_reports_windows_surface_without_live_success_claims() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(["capabilities", "--json"], &mut out, &mut err);

        assert_eq!(code, 0);
        assert!(err.is_empty());
        let stdout = String::from_utf8(out).unwrap();
        let payload: serde_json::Value = serde_json::from_str(&stdout).unwrap();
        assert_eq!(payload["schema_version"], 1);
        assert_eq!(payload["contracts_schema_version"], 1);
        assert_eq!(payload["product_name"], "SkyBridge CLI");
        assert_eq!(payload["binary_name"], "skybridge");
        assert_eq!(payload["surface"], "windows_protocol_diagnostic");
        assert_eq!(
            payload["operator_command_parity"],
            "discovery_snapshot_remote_desktop_and_file_transfer_request_registries_available_windows_agent_observation_required"
        );
        assert_eq!(payload["mac_gui_control_supported"], false);
        assert_eq!(payload["ios_runtime_control_supported"], false);
        let capabilities = payload["capabilities"].as_array().unwrap();
        let discovery = capabilities
            .iter()
            .find(|capability| capability["id"] == "device.discovery.nearby")
            .expect("discovery capability");
        assert_eq!(discovery["status"], "read_only_state_dir_supported");
        assert_eq!(
            discovery["control_effect"],
            "agent_snapshot_read_only_projection"
        );
        let transport = capabilities
            .iter()
            .find(|capability| capability["id"] == "current_path.product_control.transport")
            .expect("transport capability");
        let proof_state = transport["proof_state"].as_str().unwrap();
        assert!(proof_state.contains("NotHandshakeProof"));
        assert!(proof_state.contains("NotAppControlProof"));
        assert!(proof_state.contains("NotMacProductAppProof"));

        let (code, stdout, stderr) = run_cli(&["capabilities"]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("SkyBridge CLI Capability Contract"));
        assert!(stdout.contains(
            "operator_command_parity=discovery_snapshot_remote_desktop_and_file_transfer_request_registries_available_windows_agent_observation_required"
        ));
        assert!(stdout.contains("file.transfer.send status=request_only_state_dir_supported"));
        assert!(stdout.contains("remote_desktop.start status=request_only_state_dir_supported"));
    }

    #[test]
    fn operator_commands_fail_closed_without_leaking_sensitive_inputs() {
        let (code, stdout, stderr) =
            run_cli(&["device", "discover", "--nearby", "--scan", "--json"]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        let payload = json_from_stderr(&stderr);
        assert_eq!(payload["capability_id"], "device.discovery.nearby");
        assert_eq!(payload["accepted"], false);
        assert_eq!(payload["devices_returned"], 0);
        assert_eq!(payload["snapshot_authorizes_connection"], false);
        assert_eq!(
            payload["error"]["code"],
            "device_discovery_active_scan_snapshot_missing"
        );

        let secret_code = "ABCD-EFGH-secret-code";
        let (code, stdout, stderr) = run_cli(&["connect", secret_code, "--json"]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(!stderr.contains(secret_code));
        let payload = json_from_stderr(&stderr);
        assert_eq!(payload["capability_id"], "native.connect");
        assert_eq!(payload["accepted"], false);
        assert_eq!(payload["code_provided"], true);
        assert_eq!(payload["session_created"], false);

        let secret_path = "/Users/bill/private/payload.bin";
        let secret_peer = "peer-device-secret";
        let secret_session = "session-secret";
        let (code, stdout, stderr) = run_cli(&[
            "file",
            "send",
            secret_path,
            "--to",
            secret_peer,
            "--session-id",
            secret_session,
            "--json",
        ]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        for secret in [secret_path, secret_peer, secret_session] {
            assert!(
                !stderr.contains(secret),
                "file send fail-closed report leaked {secret}: {stderr}"
            );
        }
        let payload = json_from_stderr(&stderr);
        assert_eq!(payload["capability_id"], "file.transfer.send");
        assert_eq!(payload["source_path_provided"], true);
        assert_eq!(payload["destination_peer_provided"], true);
        assert_eq!(payload["session_id_provided"], true);
        assert_eq!(payload["request_registered"], false);
        assert_eq!(payload["receipt_verified"], false);

        let (code, stdout, stderr) = run_cli(&["file", "receive", "--json"]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        let payload = json_from_stderr(&stderr);
        assert_eq!(payload["capability_id"], "file.transfer.receive");
        assert_eq!(payload["receiver_policy_available"], false);

        let (code, stdout, stderr) = run_cli(&[
            "remote-desktop",
            "start",
            "--session-id",
            secret_session,
            "--resolution",
            "1920x1080",
            "--fps",
            "60",
            "--json",
        ]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(!stderr.contains(secret_session));
        let payload = json_from_stderr(&stderr);
        assert_eq!(payload["capability_id"], "remote_desktop.start");
        assert_eq!(payload["accepted"], false);
        assert_eq!(payload["request_registered"], false);
        assert_eq!(payload["pending_agent_observation"], false);
        assert_eq!(payload["applied"], false);
        assert_eq!(payload["session_id_provided"], true);
    }

    #[test]
    fn session_commands_keep_read_only_text_boundaries() {
        let (code, stdout, stderr) = run_cli(&["session", "ls"]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("Session inventory requires --state-dir"));

        let secret_session = "session-secret";
        let (code, stdout, stderr) = run_cli(&["session", "inspect", secret_session]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(!stderr.contains(secret_session));
        assert!(stderr.contains("session inspect requires --state-dir"));

        let state_dir = make_operator_state_dir("session-text-success");
        let state_dir_string = state_dir.to_string_lossy().to_string();
        write_remote_desktop_session_registry(
            &state_dir,
            secret_session,
            "established",
            4_102_444_800_000,
        );
        let (code, stdout, stderr) = run_cli(&["session", "ls", "--state-dir", &state_dir_string]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("Session inventory loaded"));
        assert!(!stdout.contains(secret_session));
        assert!(!stdout.contains(&state_dir_string));
    }

    #[test]
    fn session_json_errors_are_classified_and_redacted() {
        let missing = make_operator_state_dir("session-json-missing");
        let missing_string = missing.to_string_lossy().to_string();
        let secret_session = "session-secret";
        let (code, stdout, stderr) = run_cli(&[
            "session",
            "inspect",
            "--state-dir",
            &missing_string,
            secret_session,
            "--json",
        ]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(!stderr.contains(secret_session));
        assert!(!stderr.contains(&missing_string));
        let payload = json_from_stderr(&stderr);
        assert_eq!(payload["capability_id"], "session.inspect");
        assert_eq!(payload["session_found"], false);
        assert_eq!(payload["error"]["code"], "session_registry_missing");

        let oversized = make_operator_state_dir("session-json-oversized");
        let oversized_string = oversized.to_string_lossy().to_string();
        std::fs::write(
            oversized.join("runtime").join("sessions.json"),
            vec![b' '; 256 * 1024 + 1],
        )
        .unwrap();
        let (code, stdout, stderr) =
            run_cli(&["session", "ls", "--state-dir", &oversized_string, "--json"]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(!stderr.contains(&oversized_string));
        let payload = json_from_stderr(&stderr);
        assert_eq!(payload["capability_id"], "session.ls");
        assert_eq!(payload["session_registry_supported"], false);
        assert_eq!(payload["error"]["code"], "session_registry_too_large");
    }

    #[test]
    fn operator_contract_commands_are_read_only_without_live_success_claims() {
        let (code, stdout, stderr) = run_cli(&["remote-desktop", "contract", "--json"]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        let payload: serde_json::Value = serde_json::from_str(&stdout).unwrap();
        assert_eq!(payload["live_control_status"], "request_registry_available");
        assert_eq!(payload["mutation_supported"], false);
        assert_eq!(payload["request_registry_supported"], true);
        assert!(payload["commands"].as_array().unwrap().iter().any(|command| {
            command
                == "skybridge remote-desktop start [--state-dir <dir>] --session-id <id> [--resolution <preset>] [--fps <n>] [--json]"
        }));

        let (code, stdout, stderr) = run_cli(&["remote-desktop", "resolutions", "--json"]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        let payload: serde_json::Value = serde_json::from_str(&stdout).unwrap();
        assert_eq!(payload["observed_modes_status"], "planned_fail_closed");
        assert!(payload["observed_sessions"].as_array().unwrap().is_empty());
        assert_eq!(
            payload["resolutions"],
            json!(["auto", "1280x720", "1920x1080", "2056x1329", "2560x1440"])
        );
        assert!(!payload["resolutions"]
            .as_array()
            .unwrap()
            .contains(&json!("3840x2160")));
        assert!(payload["fps_values"]
            .as_array()
            .unwrap()
            .contains(&json!(60)));

        let (code, stdout, stderr) = run_cli(&["remote-desktop", "status", "--json"]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        let payload: serde_json::Value = serde_json::from_str(&stdout).unwrap();
        assert_eq!(payload["request_registry_supported"], false);
        assert!(payload["sessions"].as_array().unwrap().is_empty());

        let (code, stdout, stderr) = run_cli(&["file", "history", "--json"]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        let payload: serde_json::Value = serde_json::from_str(&stdout).unwrap();
        assert_eq!(payload["status"], "read_only_empty");
        assert_eq!(payload["history_supported"], false);
        assert_eq!(payload["pending_requests"], 0);
    }

    #[test]
    fn remote_desktop_state_dir_registers_request_only_actions() {
        let cases = [
            (
                "start",
                vec![
                    "remote-desktop",
                    "start",
                    "--session-id",
                    "session-secret",
                    "--json",
                ],
                "start",
                Some("auto"),
                Some(60),
            ),
            (
                "stop",
                vec![
                    "remote-desktop",
                    "stop",
                    "--session-id",
                    "session-secret",
                    "--json",
                ],
                "stop",
                None,
                None,
            ),
            (
                "set-resolution",
                vec![
                    "remote-desktop",
                    "set-resolution",
                    "--session-id",
                    "session-secret",
                    "--resolution",
                    "2056x1329",
                    "--json",
                ],
                "set-resolution",
                Some("2056x1329"),
                None,
            ),
            (
                "set-fps",
                vec![
                    "remote-desktop",
                    "set-fps",
                    "--session-id",
                    "session-secret",
                    "--fps",
                    "120",
                    "--json",
                ],
                "set-fps",
                None,
                Some(120),
            ),
        ];

        for (name, mut args, expected_action, expected_resolution, expected_fps) in cases {
            let state_dir = make_operator_state_dir(name);
            let state_dir_string = state_dir.to_string_lossy().to_string();
            write_remote_desktop_session_registry(
                &state_dir,
                "session-secret",
                "established",
                4_102_444_800_000,
            );
            args.insert(2, &state_dir_string);
            args.insert(2, "--state-dir");

            let (code, stdout, stderr) = run_cli(&args);

            assert_eq!(code, 0, "{name} stderr={stderr}");
            assert!(stderr.is_empty());
            assert!(!stdout.contains("session-secret"));
            assert!(!stdout.contains(&state_dir_string));
            let payload: serde_json::Value = serde_json::from_str(&stdout).unwrap();
            assert_eq!(payload["accepted"], true);
            assert_eq!(payload["status"], "request_registered");
            assert_eq!(payload["request_registered"], true);
            assert_eq!(payload["pending_agent_observation"], true);
            assert_eq!(payload["applied"], false);
            assert_eq!(payload["request"]["action"], expected_action);
            assert_eq!(payload["request"]["status"], "pending_agent_observation");
            assert_eq!(
                payload["request"]["resolution"],
                expected_resolution.map_or(serde_json::Value::Null, serde_json::Value::from)
            );
            assert_eq!(
                payload["request"]["fps"],
                expected_fps.map_or(serde_json::Value::Null, serde_json::Value::from)
            );

            let status_args = [
                "remote-desktop",
                "status",
                "--state-dir",
                &state_dir_string,
                "--session-id",
                "session-secret",
                "--json",
            ];
            let (code, stdout, stderr) = run_cli(&status_args);
            assert_eq!(code, 0, "{name} status stderr={stderr}");
            assert!(stderr.is_empty());
            assert!(!stdout.contains("session-secret"));
            assert!(!stdout.contains(&state_dir_string));
            let status: serde_json::Value = serde_json::from_str(&stdout).unwrap();
            assert_eq!(status["request_registry_supported"], true);
            assert_eq!(status["pending_requests"], 1);
            assert_eq!(status["latest_request"]["action"], expected_action);
            assert_eq!(status["remote_desktop"]["proven"], false);
        }
    }

    #[test]
    fn remote_desktop_state_dir_errors_are_redacted_and_classified() {
        let missing_registry = make_operator_state_dir("missing-session-registry");
        let missing_registry_string = missing_registry.to_string_lossy().to_string();
        let (code, stdout, stderr) = run_cli(&[
            "remote-desktop",
            "start",
            "--state-dir",
            &missing_registry_string,
            "--session-id",
            "session-secret",
            "--json",
        ]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(!stderr.contains("session-secret"));
        assert!(!stderr.contains(&missing_registry_string));
        assert_eq!(
            json_from_stderr(&stderr)["error"]["code"],
            "remote_desktop_session_registry_missing"
        );

        let stale = make_operator_state_dir("stale-session");
        let stale_string = stale.to_string_lossy().to_string();
        write_remote_desktop_session_registry(&stale, "session-secret", "established", 1);
        let (code, stdout, stderr) = run_cli(&[
            "remote-desktop",
            "start",
            "--state-dir",
            &stale_string,
            "--session-id",
            "session-secret",
            "--json",
        ]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(!stderr.contains("session-secret"));
        assert!(!stderr.contains(&stale_string));
        assert_eq!(
            json_from_stderr(&stderr)["error"]["code"],
            "remote_desktop_session_stale"
        );

        let missing_session = make_operator_state_dir("missing-session");
        let missing_session_string = missing_session.to_string_lossy().to_string();
        write_remote_desktop_session_registry(
            &missing_session,
            "other-session",
            "established",
            4_102_444_800_000,
        );
        let (code, stdout, stderr) = run_cli(&[
            "remote-desktop",
            "start",
            "--state-dir",
            &missing_session_string,
            "--session-id",
            "session-secret",
            "--json",
        ]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(!stderr.contains("session-secret"));
        assert!(!stderr.contains(&missing_session_string));
        assert_eq!(
            json_from_stderr(&stderr)["error"]["code"],
            "remote_desktop_session_not_found"
        );

        let duplicate = make_operator_state_dir("duplicate-pending");
        let duplicate_string = duplicate.to_string_lossy().to_string();
        write_remote_desktop_session_registry(
            &duplicate,
            "session-secret",
            "established",
            4_102_444_800_000,
        );
        let first = run_cli(&[
            "remote-desktop",
            "start",
            "--state-dir",
            &duplicate_string,
            "--session-id",
            "session-secret",
            "--json",
        ]);
        assert_eq!(first.0, 0);
        let (code, stdout, stderr) = run_cli(&[
            "remote-desktop",
            "set-fps",
            "--state-dir",
            &duplicate_string,
            "--session-id",
            "session-secret",
            "--fps",
            "60",
            "--json",
        ]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(!stderr.contains("session-secret"));
        assert!(!stderr.contains(&duplicate_string));
        assert_eq!(
            json_from_stderr(&stderr)["error"]["code"],
            "remote_desktop_pending_request_exists"
        );

        let (code, stdout, stderr) = run_cli(&[
            "remote-desktop",
            "start",
            "--state-dir",
            &duplicate_string,
            "--json",
        ]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert_eq!(
            json_from_stderr(&stderr)["error"]["code"],
            "remote_desktop_session_id_required"
        );

        let (code, stdout, stderr) = run_cli(&[
            "remote-desktop",
            "start",
            "--state-dir",
            &duplicate_string,
            "--session-id",
            "session-secret",
            "--fps",
            "not-a-number",
            "--json",
        ]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert_eq!(
            json_from_stderr(&stderr)["error"]["code"],
            "remote_desktop_fps_invalid"
        );

        let (code, stdout, stderr) = run_cli(&[
            "remote-desktop",
            "set-resolution",
            "--state-dir",
            &duplicate_string,
            "--session-id",
            "session-secret",
            "--json",
        ]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert_eq!(
            json_from_stderr(&stderr)["error"]["code"],
            "remote_desktop_resolution_required"
        );

        let (code, stdout, stderr) = run_cli(&[
            "remote-desktop",
            "set-fps",
            "--state-dir",
            &duplicate_string,
            "--session-id",
            "session-secret",
            "--json",
        ]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert_eq!(
            json_from_stderr(&stderr)["error"]["code"],
            "remote_desktop_fps_required"
        );
    }

    #[test]
    fn remote_desktop_operator_state_error_mapping_is_stable_and_redacted() {
        let cases = [
            (
                OperatorStateError::MissingStateDir,
                "remote_desktop_state_dir_missing",
                false,
            ),
            (
                OperatorStateError::StateDirUnavailable,
                "remote_desktop_state_dir_unavailable",
                false,
            ),
            (
                OperatorStateError::StateDirNotDirectory,
                "remote_desktop_state_dir_unavailable",
                false,
            ),
            (
                OperatorStateError::UnsafePath,
                "remote_desktop_state_dir_unsafe",
                false,
            ),
            (
                OperatorStateError::SessionRegistryMissing,
                "remote_desktop_session_registry_missing",
                false,
            ),
            (
                OperatorStateError::SessionRegistryRead,
                "remote_desktop_session_registry_invalid",
                false,
            ),
            (
                OperatorStateError::SessionRegistryJson,
                "remote_desktop_session_registry_invalid",
                false,
            ),
            (
                OperatorStateError::SessionRegistrySchema,
                "remote_desktop_session_registry_invalid",
                false,
            ),
            (
                OperatorStateError::SessionRegistryInvalid,
                "remote_desktop_session_registry_invalid",
                false,
            ),
            (
                OperatorStateError::SessionNotFound,
                "remote_desktop_session_not_found",
                false,
            ),
            (
                OperatorStateError::SessionNotEstablished,
                "remote_desktop_session_not_established",
                false,
            ),
            (
                OperatorStateError::SessionStale,
                "remote_desktop_session_stale",
                false,
            ),
            (
                OperatorStateError::RequestRegistryRead,
                "remote_desktop_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::RequestRegistryJson,
                "remote_desktop_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::RequestRegistrySchema,
                "remote_desktop_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::RequestRegistryInvalid,
                "remote_desktop_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::InvalidRequestPayload,
                "remote_desktop_request_payload_invalid",
                false,
            ),
            (
                OperatorStateError::PendingRequestExists,
                "remote_desktop_pending_request_exists",
                false,
            ),
            (
                OperatorStateError::RequestRegistryFull,
                "remote_desktop_request_registry_full",
                false,
            ),
            (
                OperatorStateError::RegistryLocked,
                "remote_desktop_registry_locked",
                true,
            ),
            (
                OperatorStateError::RequestRegistryWrite,
                "remote_desktop_request_registry_write_failed",
                true,
            ),
            (
                OperatorStateError::RequestRegistryPersistVerify,
                "remote_desktop_request_registry_write_failed",
                true,
            ),
            (
                OperatorStateError::Clock,
                "remote_desktop_clock_invalid",
                true,
            ),
        ];

        for (error, expected_code, expected_retryable) in cases {
            let (code, retryable, detail) =
                remote_desktop_operator_state_error_fields(error.clone());
            assert_eq!(code, expected_code);
            assert_eq!(retryable, expected_retryable);
            assert!(detail.contains("remote desktop"));

            let json_error =
                remote_desktop_operator_state_error(true, "start", true, true, true, error);
            let payload: serde_json::Value = serde_json::from_str(&json_error).unwrap();
            assert_eq!(payload["error"]["code"], expected_code);
            assert_eq!(payload["error"]["retryable"], expected_retryable);
            assert_eq!(payload["request_registered"], false);
            assert!(!json_error.contains("session-secret"));
            assert!(!json_error.contains("/Users/bill"));
        }
    }

    #[test]
    fn file_transfer_operator_state_error_mapping_is_stable_and_redacted() {
        let cases = [
            (
                OperatorStateError::MissingStateDir,
                "file_transfer_state_dir_missing",
                false,
            ),
            (
                OperatorStateError::StateDirUnavailable,
                "file_transfer_state_dir_unavailable",
                false,
            ),
            (
                OperatorStateError::StateDirNotDirectory,
                "file_transfer_state_dir_unavailable",
                false,
            ),
            (
                OperatorStateError::UnsafePath,
                "file_transfer_state_dir_unsafe",
                false,
            ),
            (
                OperatorStateError::SessionRegistryMissing,
                "file_transfer_session_registry_missing",
                false,
            ),
            (
                OperatorStateError::SessionRegistryRead,
                "file_transfer_session_registry_invalid",
                false,
            ),
            (
                OperatorStateError::SessionRegistryJson,
                "file_transfer_session_registry_invalid",
                false,
            ),
            (
                OperatorStateError::SessionRegistrySchema,
                "file_transfer_session_registry_invalid",
                false,
            ),
            (
                OperatorStateError::SessionRegistryInvalid,
                "file_transfer_session_registry_invalid",
                false,
            ),
            (
                OperatorStateError::SessionNotFound,
                "file_transfer_session_not_found",
                false,
            ),
            (
                OperatorStateError::SessionNotEstablished,
                "file_transfer_session_not_established",
                false,
            ),
            (
                OperatorStateError::SessionStale,
                "file_transfer_session_stale",
                false,
            ),
            (
                OperatorStateError::InvalidPeerRef,
                "file_transfer_peer_invalid",
                false,
            ),
            (
                OperatorStateError::PeerBindingMissing,
                "file_transfer_peer_binding_missing",
                false,
            ),
            (
                OperatorStateError::PeerMismatch,
                "file_transfer_peer_mismatch",
                false,
            ),
            (
                OperatorStateError::FileTransferSourceMissing,
                "file_transfer_source_missing",
                false,
            ),
            (
                OperatorStateError::FileTransferSourceUnsafe,
                "file_transfer_source_unsafe",
                false,
            ),
            (
                OperatorStateError::FileTransferSourceNotRegularFile,
                "file_transfer_source_not_regular_file",
                false,
            ),
            (
                OperatorStateError::FileTransferSourceRead,
                "file_transfer_source_unreadable",
                false,
            ),
            (
                OperatorStateError::FileTransferHashFailed,
                "file_transfer_source_unreadable",
                false,
            ),
            (
                OperatorStateError::FileTransferRequestRegistryRead,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::FileTransferRequestRegistryJson,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::FileTransferRequestRegistrySchema,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::FileTransferRequestRegistryInvalid,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::InvalidRequestPayload,
                "file_transfer_request_payload_invalid",
                false,
            ),
            (
                OperatorStateError::PendingRequestExists,
                "file_transfer_pending_request_exists",
                false,
            ),
            (
                OperatorStateError::RequestRegistryFull,
                "file_transfer_request_registry_full",
                false,
            ),
            (
                OperatorStateError::RegistryLocked,
                "file_transfer_registry_locked",
                true,
            ),
            (
                OperatorStateError::FileTransferRequestRegistryWrite,
                "file_transfer_request_registry_write_failed",
                true,
            ),
            (
                OperatorStateError::FileTransferRequestRegistryPersistVerify,
                "file_transfer_request_registry_write_failed",
                true,
            ),
            (
                OperatorStateError::RequestRegistryRead,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::RequestRegistryJson,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::RequestRegistrySchema,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::RequestRegistryInvalid,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::RequestRegistryWrite,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::RequestRegistryPersistVerify,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::NearbyDiscoverySnapshotMissing,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::NearbyDiscoveryActiveScanSnapshotMissing,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::NearbyDiscoverySnapshotStale,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::NearbyDiscoveryActiveScanSnapshotStale,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::NearbyDiscoverySnapshotRegistryRead,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::NearbyDiscoverySnapshotRegistryJson,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::NearbyDiscoverySnapshotRegistrySchema,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::NearbyDiscoverySnapshotRegistryInvalid,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::NearbyDiscoverySnapshotRegistryTooLarge,
                "file_transfer_request_registry_invalid",
                false,
            ),
            (
                OperatorStateError::Clock,
                "file_transfer_clock_invalid",
                true,
            ),
        ];

        for (error, expected_code, expected_retryable) in cases {
            let (code, retryable, detail) =
                file_transfer_operator_state_error_fields(error.clone());
            assert_eq!(code, expected_code);
            assert_eq!(retryable, expected_retryable);
            assert!(detail.contains("file transfer"));

            let json_error = file_transfer_operator_state_error(true, true, true, true, error);
            let payload: serde_json::Value = serde_json::from_str(&json_error).unwrap();
            assert_eq!(payload["error"]["code"], expected_code);
            assert_eq!(payload["error"]["retryable"], expected_retryable);
            assert_eq!(payload["request_registered"], false);
            assert!(!json_error.contains("session-secret"));
            assert!(!json_error.contains("/Users/bill"));
        }

        let text_error = file_transfer_operator_state_error(
            false,
            false,
            false,
            false,
            OperatorStateError::FileTransferSourceMissing,
        );
        assert_eq!(text_error, "file transfer source is missing");
    }

    #[test]
    fn product_control_evidence_status_is_read_only_and_scoped() {
        let path = write_product_control_evidence_fixture("valid-unit", false);
        let path_string = path.to_string_lossy().to_string();

        let (code, stdout, stderr) =
            run_cli(&["evidence", "status", "--evidence", &path_string, "--json"]);

        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        let payload: serde_json::Value = serde_json::from_str(&stdout).unwrap();
        assert_eq!(
            payload["capability_id"],
            "current_path.product_control.evidence"
        );
        assert_eq!(payload["evidence_valid"], true);
        assert_eq!(payload["accepted"], false);
        assert_eq!(payload["live_runtime_started"], false);
        assert_eq!(
            payload["product_control"]["proof_level"],
            "appcontrol_sbwc_ping_pong"
        );
        assert_eq!(payload["proof_boundary"]["handshake_proof"], true);
        assert_eq!(payload["proof_boundary"]["app_control_proof"], true);
        assert_eq!(payload["proof_boundary"]["mac_product_app_proof"], false);
        assert_eq!(payload["remote_desktop"]["proven"], false);
        assert!(payload["remote_desktop"]["missing_gates"]
            .as_array()
            .unwrap()
            .contains(&json!("real_device_p2p_remote_gate")));
        assert_eq!(payload["freshness_enforced"], false);
        assert!(!stdout.contains(&path_string));

        let (code, stdout, stderr) = run_cli(&[
            "remote-desktop",
            "status",
            "--session-id",
            "session-secret",
            "--product-control-evidence",
            &path_string,
            "--json",
        ]);

        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(!stdout.contains("session-secret"));
        assert!(!stdout.contains(&path_string));
        let payload: serde_json::Value = serde_json::from_str(&stdout).unwrap();
        assert_eq!(
            payload["capability_id"],
            "remote_desktop.status.product_control_evidence"
        );
        assert_eq!(payload["session_filter_provided"], true);
        assert_eq!(payload["remote_desktop"]["proven"], false);
    }

    #[test]
    fn remote_desktop_status_rejects_bad_product_control_evidence_without_path_leak() {
        let path = write_product_control_evidence_fixture("bad-unit", true);
        let path_string = path.to_string_lossy().to_string();
        let secret_session = "session-secret";

        let (code, stdout, stderr) = run_cli(&[
            "remote-desktop",
            "status",
            "--session-id",
            secret_session,
            "--product-control-evidence",
            &path_string,
            "--json",
        ]);

        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(!stderr.contains(&path_string));
        assert!(!stderr.contains(secret_session));
        let payload = json_from_stderr(&stderr);
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
    fn product_control_evidence_error_mapping_is_stable_and_redacted() {
        let cases = [
            (
                ProductControlEvidenceReadError::MissingPath,
                "product_control_evidence_path_missing",
                false,
            ),
            (
                ProductControlEvidenceReadError::Metadata,
                "product_control_evidence_read_failed",
                true,
            ),
            (
                ProductControlEvidenceReadError::NotRegularFile,
                "product_control_evidence_not_regular_file",
                false,
            ),
            (
                ProductControlEvidenceReadError::SymlinkOrReparsePath,
                "product_control_evidence_symlink_rejected",
                false,
            ),
            (
                ProductControlEvidenceReadError::TooLarge,
                "product_control_evidence_too_large",
                false,
            ),
            (
                ProductControlEvidenceReadError::Read,
                "product_control_evidence_read_failed",
                true,
            ),
            (
                ProductControlEvidenceReadError::Validate(ProductControlEvidenceError::Json),
                "product_control_evidence_json_invalid",
                false,
            ),
            (
                ProductControlEvidenceReadError::Validate(
                    ProductControlEvidenceError::UnsupportedSchema,
                ),
                "product_control_evidence_schema_unsupported",
                false,
            ),
            (
                ProductControlEvidenceReadError::Validate(
                    ProductControlEvidenceError::MissingField("SecretSession"),
                ),
                "product_control_evidence_incomplete",
                false,
            ),
            (
                ProductControlEvidenceReadError::Validate(
                    ProductControlEvidenceError::InvalidField("SecretSession"),
                ),
                "product_control_evidence_incomplete",
                false,
            ),
            (
                ProductControlEvidenceReadError::Validate(
                    ProductControlEvidenceError::IncompleteSteps,
                ),
                "product_control_evidence_incomplete",
                false,
            ),
            (
                ProductControlEvidenceReadError::Validate(
                    ProductControlEvidenceError::BoundaryInvalid,
                ),
                "product_control_evidence_boundary_invalid",
                false,
            ),
            (
                ProductControlEvidenceReadError::Validate(
                    ProductControlEvidenceError::SecretCaptureDetected,
                ),
                "product_control_evidence_secret_capture_detected",
                false,
            ),
        ];

        for (error, expected_code, expected_retryable) in cases {
            let (code, retryable, detail) = product_control_evidence_error_fields(error.clone());
            assert_eq!(code, expected_code);
            assert_eq!(retryable, expected_retryable);
            assert!(detail.contains("product-control evidence"));

            let json_error = product_control_evidence_error(
                true,
                "current_path.product_control.evidence",
                error,
            );
            let payload: serde_json::Value = serde_json::from_str(&json_error).unwrap();
            assert_eq!(payload["error"]["code"], expected_code);
            assert_eq!(payload["error"]["retryable"], expected_retryable);
            assert_eq!(payload["evidence_path_provided"], true);
            assert_eq!(payload["evidence_valid"], false);
            assert!(!json_error.contains("SecretSession"));
        }

        let text_error = product_control_evidence_error(
            false,
            "current_path.product_control.evidence",
            ProductControlEvidenceReadError::MissingPath,
        );
        assert_eq!(text_error, "product-control evidence path is required");
    }

    #[test]
    fn remote_desktop_request_contract_rejects_invalid_options() {
        let secret_session = "session-secret";
        let (code, stdout, stderr) = run_cli(&[
            "remote-desktop",
            "start",
            "--session-id",
            secret_session,
            "--resolution",
            "1x1",
            "--json",
        ]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(!stderr.contains(secret_session));
        let payload = json_from_stderr(&stderr);
        assert_eq!(payload["status"], "request_invalid");
        assert_eq!(
            payload["error"]["code"],
            "remote_desktop_resolution_unsupported"
        );

        let (code, stdout, stderr) = run_cli(&[
            "remote-desktop",
            "set-fps",
            "--session-id",
            secret_session,
            "--fps",
            "999",
            "--json",
        ]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(!stderr.contains(secret_session));
        let payload = json_from_stderr(&stderr);
        assert_eq!(payload["capability_id"], "remote_desktop.fps.set");
        assert_eq!(payload["error"]["code"], "remote_desktop_fps_unsupported");

        let (code, stdout, stderr) = run_cli(&[
            "remote-desktop",
            "set-resolution",
            "--session-id",
            secret_session,
            "--resolution",
            "3840x2160",
            "--json",
        ]);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(!stderr.contains(secret_session));
        let payload = json_from_stderr(&stderr);
        assert_eq!(
            payload["error"]["code"],
            "remote_desktop_resolution_unsupported"
        );
    }

    #[test]
    fn transport_select_uses_core_policy() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
                "transport",
                "select",
                "--local",
                "windows",
                "--remote",
                "apple",
                "--path",
                "cross-nat",
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert!(stdout.contains("kind=WebRtcDataChannel"));
        assert!(stdout.contains("audit=WebRtcInterop"));
        assert!(stdout.contains("relay_allowed=true"));
    }

    #[test]
    fn transport_bind_reports_core_transcript_digest() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
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
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(err.is_empty());
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
    fn channel_profile_reports_reliability() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            ["channel", "profile", "--channel", "realtime"],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(stdout.contains("channel=Realtime"));
        assert!(stdout.contains("reliability=partial-reliable:1"));
    }

    #[test]
    fn channel_map_reports_adapter_binding() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
                "channel",
                "map",
                "--transport",
                "webrtc",
                "--channel",
                "file",
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert!(stdout.contains("channel=File"));
        assert!(stdout.contains("transport=WebRtcDataChannel"));
        assert!(stdout.contains("binding=skybridge.file"));
        assert!(stdout.contains("head_of_line_isolated=true"));
    }

    #[test]
    fn frame_describe_roundtrips_plain_payload() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
                "frame",
                "describe",
                "--channel",
                "control",
                "--sequence",
                "12",
                "--payload",
                "hello",
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert!(stdout.contains("channel=Control"));
        assert!(stdout.contains("sequence=12"));
        assert!(stdout.contains("flags=0x0002"));
        assert!(stdout.contains("payload_len=5"));
    }

    #[test]
    fn frame_describe_roundtrips_sbp2_payload() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
                "frame",
                "describe",
                "--channel",
                "control",
                "--sequence",
                "12",
                "--payload",
                "hello",
                "--sbp2-fixed",
                "32",
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(stdout.contains("flags=0x0003"));
        assert!(stdout.contains("frame_len=60"));
        assert!(stdout.contains("payload_len=5"));
    }

    #[test]
    fn connection_plan_reports_transport_suite_channels_and_padding() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
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
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert!(stdout.contains("transport=WebRtcDataChannel"));
        assert!(stdout.contains("transport_audit=WebRtcInterop"));
        assert!(stdout.contains("suite=x-wing-hybrid (0x0001)"));
        assert!(stdout.contains("suite_audit=HybridPqcPreferred"));
        assert!(stdout.contains("sbp2_enabled=true"));
        assert!(stdout.contains("sbp2_fixed_payload_len=512"));
        assert!(stdout.contains("frame_header_len=20"));
        assert!(stdout.contains(
            "channel.control=WebRtcDataChannel:skybridge.control:reliable-ordered:head_of_line_isolated=true"
        ));
    }

    #[test]
    fn discovery_parse_reports_mac_txt_capabilities() {
        let mut out = Vec::new();
        let mut err = Vec::new();
        let txt = "deviceId=mac-1;pubKeyFP=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef;platform=macOS;capabilities=webrtc,tcp;name=Desk Mac;version=v1";

        let code = run(
            [
                "discovery",
                "parse",
                "--service",
                "_skybridge._udp",
                "--txt",
                txt,
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert!(stdout.contains("service=_skybridge._udp"));
        assert!(stdout.contains("device_id=mac-1"));
        assert!(stdout.contains("platform=Apple"));
        assert!(stdout.contains("supports_apple_native=true"));
        assert!(stdout.contains("supports_webrtc_data_channel=true"));
    }

    #[test]
    fn webrtc_proof_validate_reports_schema_summary() {
        let proof_path = write_webrtc_proof_fixture("valid", true);
        let proof_path_text = proof_path.to_string_lossy().to_string();

        let (code, stdout, stderr) = run_cli(&[
            "webrtc-proof",
            "validate",
            "--proof",
            &proof_path_text,
            "--expected-device-id",
            "mac-1",
            "--expected-fingerprint",
            WEBRTC_PROOF_FINGERPRINT,
        ]);

        let _ = std::fs::remove_file(proof_path);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("webrtc_proof=valid"));
        assert!(stdout.contains("peer_device_id=mac-1"));
        assert!(stdout.contains("helper_name=schema-smoke-webrtc-helper"));
        assert!(stdout.contains("adapter_binding=verified webrtc datachannel helper"));
        assert!(stdout.contains("selected_candidate_pair=webrtc/dtls/sctp/helper-selected"));
        assert!(stdout.contains("relay_id=relay-helper"));
        assert!(stdout.contains("timestamp_window_ms=15000"));
    }

    #[test]
    fn webrtc_proof_validate_rejects_missing_sbf1_echo() {
        let proof_path = write_webrtc_proof_fixture("missing-sbf1", false);
        let proof_path_text = proof_path.to_string_lossy().to_string();

        let (code, stdout, stderr) = run_cli(&[
            "webrtc-proof",
            "validate",
            "--proof",
            &proof_path_text,
            "--expected-device-id",
            "mac-1",
            "--expected-fingerprint",
            WEBRTC_PROOF_FINGERPRINT,
        ]);

        let _ = std::fs::remove_file(proof_path);
        assert_eq!(code, 2);
        assert!(stdout.is_empty());
        assert!(stderr.contains("webrtc proof validation failed"));
        assert!(stderr.contains("SBF1 echo frame"));
    }

    #[test]
    fn suite_offer_is_derived_from_caps_and_policy() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
                "suite",
                "offer",
                "--caps",
                "xwing,x25519,p256",
                "--allow-classic",
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(err.is_empty());
        assert!(stdout.contains("x-wing-hybrid=0x0001"));
        assert!(stdout.contains("x25519-ed25519=0x1001"));
        assert!(!stdout.contains("p256-ecdsa"));
    }

    #[test]
    fn suite_select_reports_audit_reason() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
                "suite",
                "select",
                "--local-caps",
                "mlkem,x25519",
                "--remote-suites",
                "0x1001,0x0101",
                "--allow-classic",
            ],
            &mut out,
            &mut err,
        );

        let stdout = String::from_utf8(out).unwrap();
        assert_eq!(code, 0);
        assert!(stdout.contains("suite=ml-kem-768-ml-dsa-65 (0x0101)"));
        assert!(stdout.contains("audit=PurePqcPreferred"));
    }

    #[test]
    fn suite_select_rejects_timeout_downgrade() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            [
                "suite",
                "select",
                "--local-caps",
                "x25519",
                "--remote-suites",
                "0x1001",
                "--allow-classic",
                "--timeout-observed",
            ],
            &mut out,
            &mut err,
        );

        assert_eq!(code, 2);
        assert!(out.is_empty());
        assert!(String::from_utf8(err)
            .unwrap()
            .contains("TimeoutCannotDowngrade"));
    }

    #[test]
    fn invalid_command_returns_usage_error() {
        let mut out = Vec::new();
        let mut err = Vec::new();

        let code = run(
            ["transport", "select", "--local", "windows"],
            &mut out,
            &mut err,
        );

        assert_eq!(code, 2);
        assert!(out.is_empty());
        assert!(String::from_utf8(err).unwrap().contains("--remote"));
    }

    #[test]
    fn help_and_subcommand_errors_fail_closed() {
        let (code, stdout, stderr) = run_cli(&[]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("SkyBridge CLI"));

        let (code, stdout, stderr) = run_cli(&["-h"]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("capabilities [--json]"));
        assert!(stdout.contains("discovery parse"));

        for (args, expected) in [
            (&["bogus"][..], "unknown command: bogus"),
            (
                &["capabilities", "--text"][..],
                "expected capabilities [--json]",
            ),
            (
                &["device"][..],
                "expected device discover --nearby [--state-dir <dir>] [--scan] [--json]",
            ),
            (&["connect"][..], "expected connect <code> [--json]"),
            (
                &["file"][..],
                "expected file send, file receive, or file history",
            ),
            (
                &["evidence"][..],
                "expected evidence status --evidence <path> [--json]",
            ),
            (
                &["remote-desktop"][..],
                "expected remote-desktop contract, status, resolutions, start, stop, set-resolution, or set-fps",
            ),
            (
                &["transport"][..],
                "expected transport select or transport bind",
            ),
            (&["suite"][..], "expected suite offer or suite select"),
            (&["pqc"][..], "expected pqc status, pqc offer, or pqc select"),
            (&["channel"][..], "expected channel profile or channel map"),
            (&["frame"][..], "expected frame describe"),
            (&["connection"][..], "expected connection plan"),
            (&["discovery"][..], "expected discovery parse"),
            (&["webrtc-proof"][..], "expected webrtc-proof validate"),
        ] {
            let (code, stdout, stderr) = run_cli(args);
            assert_eq!(code, 2);
            assert!(stdout.is_empty());
            assert!(stderr.contains(expected));
        }
    }

    #[test]
    fn parsers_reject_invalid_scalar_options() {
        for (args, expected) in [
            (
                &[
                    "transport",
                    "select",
                    "--local",
                    "linux",
                    "--remote",
                    "apple",
                    "--path",
                    "same-lan",
                ][..],
                "unsupported platform: linux",
            ),
            (
                &[
                    "transport",
                    "select",
                    "--local",
                    "windows",
                    "--remote",
                    "apple",
                    "--path",
                    "moon",
                ][..],
                "unsupported path: moon",
            ),
            (
                &["channel", "profile", "--channel", "chat"][..],
                "unsupported channel: chat",
            ),
            (
                &[
                    "channel",
                    "map",
                    "--transport",
                    "carrier",
                    "--channel",
                    "control",
                ][..],
                "unsupported transport: carrier",
            ),
            (
                &["suite", "offer", "--caps", "banana"][..],
                "unsupported crypto capability: banana",
            ),
            (
                &[
                    "suite",
                    "select",
                    "--local-caps",
                    "x25519",
                    "--remote-suites",
                    "0xzz",
                ][..],
                "invalid suite id: 0xzz",
            ),
            (
                &[
                    "transport",
                    "bind",
                    "--transport",
                    "webrtc",
                    "--local-endpoint",
                    "a",
                    "--remote-endpoint",
                    "b",
                    "--candidate-pair",
                    "c",
                    "--secret-fp",
                    "d",
                    "--capability-digest",
                    "e",
                    "--timestamp-window-ms",
                    "soon",
                ][..],
                "invalid --timestamp-window-ms: soon",
            ),
            (
                &[
                    "frame",
                    "describe",
                    "--channel",
                    "control",
                    "--sequence",
                    "nan",
                    "--payload",
                    "hello",
                ][..],
                "invalid --sequence: nan",
            ),
            (
                &[
                    "connection",
                    "plan",
                    "--local",
                    "windows",
                    "--remote",
                    "macos",
                    "--path",
                    "cross-nat",
                    "--local-caps",
                    "xwing",
                    "--remote-suites",
                    "0x0001",
                    "--sbp2-fixed",
                    "tiny",
                ][..],
                "invalid --sbp2-fixed: tiny",
            ),
        ] {
            let (code, stdout, stderr) = run_cli(args);
            assert_eq!(code, 2);
            assert!(stdout.is_empty());
            assert!(stderr.contains(expected), "{stderr}");
        }
    }

    #[test]
    fn transport_aliases_and_binding_formatters_are_covered() {
        let (code, stdout, stderr) = run_cli(&[
            "transport",
            "bind",
            "--transport",
            "relay",
            "--local-endpoint",
            "local",
            "--remote-endpoint",
            "remote",
            "--candidate-pair",
            "relay/tcp",
            "--secret-fp",
            "secret",
            "--capability-digest",
            "caps",
            "--timestamp-window-ms",
            "2500",
            "--relay-id",
            "relay-1",
        ]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("transport=Relay"));
        assert!(stdout.contains("relay_id=relay-1"));

        let (code, stdout, stderr) = run_cli(&[
            "transport",
            "bind",
            "--transport",
            "tcp",
            "--local-endpoint",
            "local",
            "--remote-endpoint",
            "remote",
            "--candidate-pair",
            "tcp",
            "--secret-fp",
            "secret",
            "--capability-digest",
            "caps",
            "--timestamp-window-ms",
            "2500",
        ]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("transport=TcpFallback"));
        assert!(stdout.contains("relay_id=none"));

        let apple_stream = map_channel(
            SkyBridgeTransportKind::AppleNative,
            SkyBridgeChannel::Control,
        )
        .unwrap();
        let apple_datagram = map_channel(
            SkyBridgeTransportKind::AppleNative,
            SkyBridgeChannel::Telemetry,
        )
        .unwrap();
        let msquic_stream = map_channel(
            SkyBridgeTransportKind::WindowsNativeMsQuic,
            SkyBridgeChannel::File,
        )
        .unwrap();
        let msquic_datagram = map_channel(
            SkyBridgeTransportKind::WindowsNativeMsQuic,
            SkyBridgeChannel::Realtime,
        )
        .unwrap();
        let relay_stream =
            map_channel(SkyBridgeTransportKind::Relay, SkyBridgeChannel::Clipboard).unwrap();
        let tcp_stream = map_channel(
            SkyBridgeTransportKind::TcpFallback,
            SkyBridgeChannel::Control,
        )
        .unwrap();

        assert_eq!(format_binding_kind(&apple_stream.binding), "AppleStream");
        assert_eq!(
            format_binding_kind(&apple_datagram.binding),
            "AppleDatagram"
        );
        assert_eq!(format_binding_kind(&msquic_stream.binding), "MsQuicStream");
        assert_eq!(
            format_binding_kind(&msquic_datagram.binding),
            "MsQuicDatagram"
        );
        assert_eq!(format_binding_kind(&relay_stream.binding), "RelayStream");
        assert_eq!(format_binding_kind(&tcp_stream.binding), "TcpStream");
        assert_eq!(
            format_reliability(SkyBridgeReliability::Unreliable),
            "unreliable"
        );
    }

    #[test]
    fn suite_empty_offer_and_decimal_ids_are_reported() {
        let (code, stdout, stderr) = run_cli(&["suite", "offer", "--caps", ""]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert_eq!(stdout, "suites=\n");

        let (code, stdout, stderr) = run_cli(&[
            "suite",
            "select",
            "--local-caps",
            "x25519",
            "--remote-suites",
            "4097",
            "--allow-classic",
        ]);
        assert_eq!(code, 0);
        assert!(stderr.is_empty());
        assert!(stdout.contains("suite=x25519-ed25519 (0x1001)"));
    }

    #[test]
    fn unknown_default_capabilities_are_disabled() {
        let caps = default_capabilities(PeerPlatform::Unknown);

        assert_eq!(caps.platform, PeerPlatform::Unknown);
        assert!(!caps.supports_apple_native);
        assert!(!caps.supports_msquic);
        assert!(!caps.supports_skybridge_ice_msquic);
        assert!(!caps.supports_webrtc_data_channel);
        assert!(!caps.supports_tcp_fallback);
        assert!(!caps.supports_relay);
    }

    fn json_from_stderr(stderr: &str) -> serde_json::Value {
        serde_json::from_str(stderr.trim()).unwrap()
    }
}
