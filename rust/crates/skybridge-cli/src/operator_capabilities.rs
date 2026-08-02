use anyhow::Result;
use serde::Serialize;
use serde_json::json;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum OperatorCapabilityStatus {
    Available,
    ReadOnly,
    Unavailable,
    /// The handler is implemented and enabled in the build, but the evidence its
    /// `verification_gate` demands has not been captured yet.
    ///
    /// This exists so a verb that genuinely mutates the runtime cannot be
    /// mislabelled `planned` (which would deny an enabled code path) or
    /// `available` (which would claim proof nobody produced).
    PendingLiveProof,
    Planned,
}

impl OperatorCapabilityStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Available => "available",
            Self::ReadOnly => "read_only",
            Self::Unavailable => "unavailable",
            Self::PendingLiveProof => "pending_live_proof",
            Self::Planned => "planned",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum OperatorRuntimeTarget {
    MacAppRuntime,
    NativeHeadlessStateDir,
    AgentOwnedRegistry,
    ArtifactOnly,
}

impl OperatorRuntimeTarget {
    fn as_str(self) -> &'static str {
        match self {
            Self::MacAppRuntime => "mac_app_runtime",
            Self::NativeHeadlessStateDir => "native_headless_state_dir",
            Self::AgentOwnedRegistry => "agent_owned_registry",
            Self::ArtifactOnly => "artifact_only",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum OperatorControlEffect {
    ReadOnly,
    NativeMutation,
    /// The Mac app applies the change to its live runtime and reports the value
    /// it reads back afterwards.
    MacRuntimeMutation,
    MacMutationNotEnabled,
    ContractOnly,
    PlannedFailClosed,
    UnavailableFailClosed,
    ArtifactOnly,
}

impl OperatorControlEffect {
    fn as_str(self) -> &'static str {
        match self {
            Self::ReadOnly => "read_only",
            Self::NativeMutation => "native_mutation",
            Self::MacRuntimeMutation => "mac_runtime_mutation",
            Self::MacMutationNotEnabled => "mac_mutation_not_enabled",
            Self::ContractOnly => "contract_only",
            Self::PlannedFailClosed => "planned_fail_closed",
            Self::UnavailableFailClosed => "unavailable_fail_closed",
            Self::ArtifactOnly => "artifact_only",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
struct OperatorCapability {
    id: &'static str,
    status: OperatorCapabilityStatus,
    runtime_target: OperatorRuntimeTarget,
    control_effect: OperatorControlEffect,
    command: &'static str,
    owner_module: &'static str,
    authority_boundary: &'static str,
    verification_gate: &'static str,
}

const OPERATOR_CAPABILITY_SCHEMA_VERSION: u32 = 1;

fn operator_capabilities() -> &'static [OperatorCapability] {
    &[
        OperatorCapability {
            id: "crossnet.preflight",
            status: OperatorCapabilityStatus::ReadOnly,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::ReadOnly,
            command: "app-bound/read-only: skybridge crossnet preflight [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Reads the running Mac app's crossnet-control/1 hello state and reports protocol/auth/tenant preconditions plus per-method mutation availability; when auth and tenant are ready, crossnet.settings.set may be enabled while host/connect/disconnect remain disabled, but the signed-app socket smoke release gate still blocks an end-to-end release claim; preflight itself does not generate codes, connect peers, mutate settings, or control iOS runtime",
            verification_gate: "crossnet_preflight_json_contract + Mac OperatorControlServer hello round-trip + signed Mac app socket smoke",
        },
        OperatorCapability {
            id: "crossnet.host",
            status: OperatorCapabilityStatus::Planned,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::MacMutationNotEnabled,
            command: "planned/app-bound: skybridge crossnet host [--lease short|long] [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Rust CLI client, crossnet-control/1 wire contract, and initial Mac-only socket server source are present; host must still fail closed with method_not_enabled until the signed Mac app owns auth_loaded=true, tenant_bound=true, real code issuance, and live socket smoke evidence",
            verification_gate: "Mac OperatorControlServer auth/tenant gate tests + live signed-app socket smoke + real code issuance evidence",
        },
        OperatorCapability {
            id: "crossnet.connect",
            status: OperatorCapabilityStatus::Planned,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::MacMutationNotEnabled,
            command: "planned/app-bound: skybridge crossnet connect <code> [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Rust CLI client, crossnet-control/1 wire contract, and initial Mac-only socket server source are present; connect validates the code contract but must still fail closed with method_not_enabled until the signed Mac app mutates CrossNetworkConnectionManager after app auth, tenant preflight, and live socket smoke pass",
            verification_gate: "Mac OperatorControlServer auth/tenant gate tests + live signed-app socket smoke + CrossNetworkConnectionManager mutation evidence",
        },
        OperatorCapability {
            id: "crossnet.disconnect",
            status: OperatorCapabilityStatus::Planned,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::MacMutationNotEnabled,
            command: "planned/app-bound: skybridge crossnet disconnect [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Rust CLI client, crossnet-control/1 wire contract, and initial Mac-only socket server source are present; disconnect must still fail closed with method_not_enabled until app auth, tenant binding, app session presence, and live socket smoke are enforced by the signed Mac app",
            verification_gate: "Mac OperatorControlServer disconnect auth gate tests + live signed-app socket smoke + app session teardown evidence",
        },
        OperatorCapability {
            id: "crossnet.status.snapshot",
            status: OperatorCapabilityStatus::ReadOnly,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::ReadOnly,
            command: "app-bound/read-only: skybridge crossnet status [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Reads one Mac-only crossnet-control/1 status snapshot from the running Mac app; exposes auth_loaded, tenant_bound, readiness, and redacted session_ref only; does not watch streams, mutate sessions, change settings, or control iOS runtime",
            verification_gate: "Mac OperatorControlServer status redaction tests + signed Mac app socket smoke before release readiness claims",
        },
        OperatorCapability {
            id: "crossnet.settings.snapshot",
            status: OperatorCapabilityStatus::ReadOnly,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::ReadOnly,
            command: "app-bound/read-only: skybridge crossnet settings [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Reads an allowlisted, non-secret Mac app settings projection through crossnet-control/1; each entry declares whether it belongs to the smaller typed mutation allowlist, raw paths/tokens/session ids are excluded, and this read command does not write UserDefaults, mutate runtime state, or control iOS runtime",
            verification_gate: "Mac OperatorControlServer settings snapshot allowlist tests + Rust settings JSON contract + signed Mac app socket smoke before release readiness claims",
        },
        OperatorCapability {
            id: "crossnet.settings.set",
            status: OperatorCapabilityStatus::PendingLiveProof,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::MacRuntimeMutation,
            command: "app-bound: skybridge crossnet settings set <id> <value> [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Mac-app-bound settings mutation is implemented and enabled: the app applies one entry from a typed allowlist that is a strict subset of the readable projection, requires auth_loaded=true and tenant_bound=true, re-reads the property from its runtime after the apply hook, and fails closed with setting_runtime_apply_failed when the read-back differs; pqc.* ids stay immutable here because their authority is the versioned protocol identity prepare/commit flow, which can require peer re-pinning; Rust state_dir/UserDefaults direct writes are not valid GUI control and status stays pending_live_proof until live signed-app socket smoke is captured",
            verification_gate: "Mac OperatorControlServer auth/tenant and settings allowlist tests + runtime observation tests + live signed-app socket smoke",
        },
        OperatorCapability {
            id: "crossnet.navigation",
            status: OperatorCapabilityStatus::Planned,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::MacMutationNotEnabled,
            command: "planned/app-bound: skybridge crossnet navigate <dashboard|settings> [--json]",
            owner_module: "Mac OperatorControlServer + app-owned injected navigation coordinator",
            authority_boundary: "crossnet-control/1 does not currently expose navigation; this must remain method_not_enabled until the Mac app owns an injected navigation coordinator with typed destinations and read-back, and it must not be emulated through global notifications or direct view-state writes",
            verification_gate: "typed navigation destination tests + app-owned coordinator read-back + live signed-app socket smoke",
        },
        OperatorCapability {
            id: "crossnet.status.watch",
            status: OperatorCapabilityStatus::Planned,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::PlannedFailClosed,
            command: "planned/fail-closed: skybridge crossnet status --watch [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "The Mac-only status watch parser/client shape exists, but the server currently returns watch_not_supported; watch must stay fail-closed until stream lifecycle, backpressure, and signed Mac app socket smoke are proven",
            verification_gate: "Mac OperatorControlServer watch_not_supported tests + stream lifecycle/backpressure tests + live signed-app socket smoke",
        },
        OperatorCapability {
            id: "device.status",
            status: OperatorCapabilityStatus::Available,
            runtime_target: OperatorRuntimeTarget::NativeHeadlessStateDir,
            control_effect: OperatorControlEffect::ReadOnly,
            command: "skybridge device status [--json]",
            owner_module: "device_commands::status",
            authority_boundary: "local identity and primary PQC identity read-only report; agent health is projected only when the runtime lock, schema, state directory, healthy status, and freshness checks all pass, otherwise it is explicitly unavailable",
            verification_gate: "device_status_reports_local_identity_without_auth",
        },
        OperatorCapability {
            id: "device.discovery.nearby",
            status: OperatorCapabilityStatus::ReadOnly,
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::ReadOnly,
            command: "skybridge device discover --nearby [--json]",
            owner_module: "device_commands + NearbyDiscoverySnapshotRegistry",
            authority_boundary: "read-only agent-owned nearby discovery snapshot; this command does not start Bonjour/local-network scanning, missing or stale snapshots fail closed, and discovery does not authorize connection",
            verification_gate: "device_discovery_nearby_snapshot_gate + nearby_discovery_json_contract_fails_closed_without_fake_empty_results",
        },
        OperatorCapability {
            id: "device.discovery.active_scan",
            status: OperatorCapabilityStatus::ReadOnly,
            runtime_target: OperatorRuntimeTarget::NativeHeadlessStateDir,
            control_effect: OperatorControlEffect::ReadOnly,
            command: "skybridge device discover --nearby --scan [--scan-seconds <1..30>] [--show-addresses] [--json]",
            owner_module: "device_commands + skybridge-agent discovery service",
            authority_boundary: "performs one bounded foreground mDNS scan without requiring a running Desktop app or long-running agent; persists only locator-free candidate device refs and never authorizes connection; addresses stay omitted unless --show-addresses is explicit, then remain short-lived advertised_unverified observations with authenticated=false, connectable=false, and persisted=false",
            verification_gate: "active_scan_duration_bounds + active_scan_locator_free_snapshot + explicit_address_disclosure_json_contract + controlled-LAN real-device scan gate",
        },
        OperatorCapability {
            id: "native.code.create",
            status: OperatorCapabilityStatus::Available,
            runtime_target: OperatorRuntimeTarget::NativeHeadlessStateDir,
            control_effect: OperatorControlEffect::NativeMutation,
            command: "headless-native: skybridge code create [--json]",
            owner_module: "connection_code::create + skybridge-agent state",
            authority_boundary: "requires a health-fresh agent that owns the selected state_dir runtime lock before any remote code lease is requested; success means the code and Initiator ManagedSessionControl were registered for the active skybridge-agent, while peer_connected remains false until a later identity-bound handshake; does not mutate the Mac GUI runtime and must not be used as a GUI interop substitute",
            verification_gate: "code_create_rejects_inactive_agent_before_control_plane_setup + connection_code::tests",
        },
        OperatorCapability {
            id: "native.connect",
            status: OperatorCapabilityStatus::PendingLiveProof,
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::NativeMutation,
            command: "headless-native: skybridge connect <code> [--timeout-seconds <1..300>] [--json]",
            owner_module: "connection_code::connect + skybridge-agent state",
            authority_boundary: "requires a health-fresh agent that owns the active runtime lock; the CLI registers a Responder ManagedSessionControl with an immutable registration owner, follows only that owner's current worker incarnation, and reports ready only when an exact current-runtime receipt has identity-bound HandshakeComplete evidence, a fresh authenticated SBWC heartbeat carrying the peer name/features, and a fresh selected ICE pair carrying explicit direct-or-relay IP semantics; does not bind or update CrossNetworkConnectionManager in the Mac app; status remains pending_live_proof until a real-device cross-platform handshake artifact is captured",
            verification_gate: "connection_code::connect::tests + agent_runtime_is_active health-and-lock gate + native identity-bound handshake + authenticated heartbeat + selected ICE route gate",
        },
        OperatorCapability {
            id: "session.list",
            status: OperatorCapabilityStatus::Available,
            runtime_target: OperatorRuntimeTarget::NativeHeadlessStateDir,
            control_effect: OperatorControlEffect::ReadOnly,
            command: "skybridge session ls [--json]",
            owner_module: "session_commands",
            authority_boundary: "read-only native/headless SessionRegistry projection; for Mac GUI session state use `skybridge crossnet status`",
            verification_gate: "session_commands::tests",
        },
        OperatorCapability {
            id: "session.inspect",
            status: OperatorCapabilityStatus::Available,
            runtime_target: OperatorRuntimeTarget::NativeHeadlessStateDir,
            control_effect: OperatorControlEffect::ReadOnly,
            command: "skybridge session inspect <id> [--json]",
            owner_module: "session_commands",
            authority_boundary: "read-only native/headless single-session projection; not a Mac GUI runtime projection",
            verification_gate: "session_commands::tests",
        },
        OperatorCapability {
            id: "session.disconnect",
            status: OperatorCapabilityStatus::Available,
            runtime_target: OperatorRuntimeTarget::NativeHeadlessStateDir,
            control_effect: OperatorControlEffect::NativeMutation,
            command: "skybridge disconnect <session-id>",
            owner_module: "session_commands",
            authority_boundary: "updates native/headless ManagedSessionControl and RuntimeSessionRecord through skybridge-agent state helpers; for Mac GUI disconnect use `skybridge crossnet disconnect`",
            verification_gate: "dispatch_covers_operator_entry_error_and_wrapper_paths",
        },
        OperatorCapability {
            id: "file.transfer.send",
            status: OperatorCapabilityStatus::PendingLiveProof,
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::NativeMutation,
            command: "skybridge file send <path> --to <peer> --session-id <id> [--detach] [--timeout-seconds <1..3600>] [--json]",
            owner_module: "file_commands + FileTransferControlRequestRegistry + agent file_transfer coordinator",
            authority_boundary: "requires a health-fresh lock-owning agent, current handshake-complete session proof, bound remote protocol identity, and local regular-file SHA-256 snapshot; by default the CLI waits and reports success only after TransferCompleted with a verified matching SHA-256 receipt, while --detach reports only request registration for the still-active agent, never agent observation, and never transfer success; outcome remains observable via `file history`; status remains pending_live_proof until a real-device cross-platform file-transfer artifact is captured",
            verification_gate: "file_send_wait_decision_and_json_contract + file_transfer_agent_observation_request_registry_gate + file_transfer_json_contract_fails_closed_without_path_or_peer_leakage + real_device_file_transfer_gate",
        },
        OperatorCapability {
            id: "file.transfer.receive",
            status: OperatorCapabilityStatus::PendingLiveProof,
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::NativeMutation,
            command: "skybridge file receive --list [--json] | --session-id <id> (--accept|--reject) <transfer-uuid> [--json]",
            owner_module: "file_commands + InboundFileTransferApprovalRegistry + agent file_transfer coordinator",
            authority_boundary: "listing is a read-only projection of persisted inbound approval records; accept/reject requires a health-fresh lock-owning agent and the current runtime incarnation, stable authenticated peer device id, and protocol fingerprint, then records only a pending agent decision (applied=false); the agent owns the live native sender and emits metadata ACK/error, and allocates staging/storage only after approval; status remains pending_live_proof until a real-device cross-platform inbound transfer artifact is captured",
            verification_gate: "inbound_approval_registry_and_receiver_tests + file_receive_list_and_decision_json_contract + real_device_file_transfer_gate",
        },
        OperatorCapability {
            id: "file.transfer.history",
            status: OperatorCapabilityStatus::ReadOnly,
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::ReadOnly,
            command: "skybridge file history [--json]",
            owner_module: "file_commands",
            authority_boundary: "reports redacted request registry state including evidence-gated transfer progress and SHA-256 receipt verification; success fields are true only when the agent recorded a verified receipt",
            verification_gate: "file_transfer_agent_observation_request_registry_gate + file_transfer_json_contract_fails_closed_without_path_or_peer_leakage",
        },
        OperatorCapability {
            id: "remote_desktop.contract",
            status: OperatorCapabilityStatus::ReadOnly,
            runtime_target: OperatorRuntimeTarget::ArtifactOnly,
            control_effect: OperatorControlEffect::ContractOnly,
            command: "skybridge remote-desktop contract [--json]",
            owner_module: "remote_desktop_commands",
            authority_boundary: "read-only CLI request contract; cannot mutate sessions or claim live sender mode evidence",
            verification_gate: "remote_desktop_contract_keeps_live_application_unobserved",
        },
        OperatorCapability {
            id: "remote_desktop.status",
            status: OperatorCapabilityStatus::ReadOnly,
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::ReadOnly,
            command: "skybridge remote-desktop status [--session-id <id>] [--json]",
            owner_module: "remote_desktop_commands + SessionRegistry + RemoteDesktopControlRequestRegistry",
            authority_boundary: "read-only runtime session and pending request projection; cannot claim live sender apply evidence",
            verification_gate: "remote_desktop_dispatch_rejects_unverified_peer_without_registry_write",
        },
        OperatorCapability {
            id: "remote_desktop.resolution_contract",
            status: OperatorCapabilityStatus::ReadOnly,
            runtime_target: OperatorRuntimeTarget::ArtifactOnly,
            control_effect: OperatorControlEffect::ContractOnly,
            command: "skybridge remote-desktop resolutions [--json]",
            owner_module: "remote_desktop_commands",
            authority_boundary: "request-contract-only list, not observed sender-supported modes",
            verification_gate: "remote_desktop_json_contract_is_machine_readable_without_live_success_claims",
        },
        OperatorCapability {
            id: "remote_desktop.start",
            status: OperatorCapabilityStatus::Unavailable,
            runtime_target: OperatorRuntimeTarget::NativeHeadlessStateDir,
            control_effect: OperatorControlEffect::UnavailableFailClosed,
            command: "unavailable/fail-closed: skybridge remote-desktop start --session-id <id> [--resolution <preset>] [--fps <value>] [--json]",
            owner_module: "remote_desktop_commands + authenticated RuntimeSessionRecord evidence",
            authority_boundary: "verifies the authenticated peer capability boundary, then rejects without a registry write because the standalone Rust runtime has no screen-capture/media/input backend or applied readback receipt",
            verification_gate: "standalone remote desktop backend + authenticated SBWC control/apply receipt + real_device_p2p_remote_gate + remote_control_notice_artifact_gate",
        },
        OperatorCapability {
            id: "remote_desktop.stop",
            status: OperatorCapabilityStatus::Unavailable,
            runtime_target: OperatorRuntimeTarget::NativeHeadlessStateDir,
            control_effect: OperatorControlEffect::UnavailableFailClosed,
            command: "unavailable/fail-closed: skybridge remote-desktop stop --session-id <id> [--json]",
            owner_module: "remote_desktop_commands + authenticated RuntimeSessionRecord evidence",
            authority_boundary: "rejects without claiming a stream stop because the standalone runtime does not own a remote desktop backend or live stream state",
            verification_gate: "standalone remote desktop backend + runtime applied readback receipt + real_device_p2p_remote_gate",
        },
        OperatorCapability {
            id: "remote_desktop.resolutions.list",
            status: OperatorCapabilityStatus::ReadOnly,
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::ReadOnly,
            command: "skybridge remote-desktop resolutions --session-id <id> [--json]",
            owner_module: "remote_desktop_commands + RemoteDesktopCapabilitySnapshotRegistry",
            authority_boundary: "read-only agent-owned observed sender display capability snapshot; not a sender apply receipt and not live apply",
            verification_gate: "remote_desktop_capability_snapshot_registry_gate + remote_desktop_json_contract_is_machine_readable_without_live_success_claims",
        },
        OperatorCapability {
            id: "remote_desktop.resolution.set",
            status: OperatorCapabilityStatus::Unavailable,
            runtime_target: OperatorRuntimeTarget::NativeHeadlessStateDir,
            control_effect: OperatorControlEffect::UnavailableFailClosed,
            command: "unavailable/fail-closed: skybridge remote-desktop set-resolution --session-id <id> --resolution <preset> [--json]",
            owner_module: "remote_desktop_commands + authenticated RuntimeSessionRecord evidence",
            authority_boundary: "validates bounded input, then rejects without a registry write because no standalone sender can apply and read back the requested mode",
            verification_gate: "standalone sender mode backend + authenticated applied readback receipt + real_device_p2p_remote_gate",
        },
        OperatorCapability {
            id: "remote_desktop.fps.set",
            status: OperatorCapabilityStatus::Unavailable,
            runtime_target: OperatorRuntimeTarget::NativeHeadlessStateDir,
            control_effect: OperatorControlEffect::UnavailableFailClosed,
            command: "unavailable/fail-closed: skybridge remote-desktop set-fps --session-id <id> --fps <value> [--json]",
            owner_module: "remote_desktop_commands + authenticated RuntimeSessionRecord evidence",
            authority_boundary: "validates bounded input, then rejects without a registry write because no standalone sender can apply and read back FPS",
            verification_gate: "standalone sender FPS backend + authenticated applied readback receipt + performance_p2p_remote_final_window_fps_gate",
        },
        OperatorCapability {
            id: "remote_desktop.media.doctor",
            status: OperatorCapabilityStatus::ReadOnly,
            runtime_target: OperatorRuntimeTarget::ArtifactOnly,
            control_effect: OperatorControlEffect::ArtifactOnly,
            command: "skybridge doctor webrtc-media --latest|--session-id <id> [--json]",
            owner_module: "webrtc_media_doctor",
            authority_boundary: "artifact-only diagnosis; cannot mutate live sessions",
            verification_gate: "webrtc_media_doctor_tests",
        },
    ]
}

pub(crate) fn print_operator_capabilities(as_json: bool) -> Result<()> {
    let capabilities = operator_capabilities();
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "schema_version": OPERATOR_CAPABILITY_SCHEMA_VERSION,
                "product_name": "SkyBridge CLI",
                "binary_name": "skybridge",
                "ios_runtime_control_supported": false,
                "mac_gui_control_protocol": "crossnet-control/1",
                "mac_gui_control_release_gate": "signed_mac_app_socket_smoke_required",
                "capabilities": capabilities,
            }))?
        );
        return Ok(());
    }

    println!(
        "SkyBridge CLI Operator Capability Contract v{}",
        OPERATOR_CAPABILITY_SCHEMA_VERSION
    );
    println!("iOS runtime control supported: false");
    println!("Mac GUI control protocol: crossnet-control/1 (signed Mac app socket smoke required)");
    for capability in capabilities {
        println!(
            "{} [{} target={} effect={}] {}",
            capability.id,
            capability.status.as_str(),
            capability.runtime_target.as_str(),
            capability.control_effect.as_str(),
            capability.command
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests;
