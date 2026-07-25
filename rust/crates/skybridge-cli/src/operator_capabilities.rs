use anyhow::Result;
use serde::Serialize;
use serde_json::json;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum OperatorCapabilityStatus {
    Available,
    ReadOnly,
    RequestOnly,
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
            Self::RequestOnly => "request_only",
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
    RequestOnly,
    NativeMutation,
    /// The Mac app applies the change to its live runtime and reports the value
    /// it reads back afterwards.
    MacRuntimeMutation,
    MacMutationNotEnabled,
    ContractOnly,
    PlannedFailClosed,
    ArtifactOnly,
}

impl OperatorControlEffect {
    fn as_str(self) -> &'static str {
        match self {
            Self::ReadOnly => "read_only",
            Self::RequestOnly => "request_only",
            Self::NativeMutation => "native_mutation",
            Self::MacRuntimeMutation => "mac_runtime_mutation",
            Self::MacMutationNotEnabled => "mac_mutation_not_enabled",
            Self::ContractOnly => "contract_only",
            Self::PlannedFailClosed => "planned_fail_closed",
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
            authority_boundary: "Reads the running Mac app's crossnet-control/1 hello state and reports protocol/auth/tenant preconditions; mutation_methods_enabled remains false until signed Mac app socket smoke proves live mutation; does not generate codes, connect peers, mutate settings, or control iOS runtime",
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
            authority_boundary: "Reads an allowlisted, non-secret Mac app settings projection through crossnet-control/1; all entries are reported immutable in this CLI slice, raw paths/tokens/session ids are excluded, and this command does not write UserDefaults, mutate runtime state, or control iOS runtime",
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
            authority_boundary: "local identity, PQC identity, and agent health read-only report",
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
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::ReadOnly,
            command: "skybridge device discover --nearby --scan [--json]",
            owner_module: "device_commands + agent-owned active mDNS scanner",
            authority_boundary: "read-only result of the agent-owned active mDNS scanner; the agent performs the live Bonjour/local-network scan with protocol identity dedupe and locator-free device refs, missing or stale active snapshots fail closed, and discovery never authorizes connection",
            verification_gate: "device_discovery_nearby_snapshot_gate + connectivity_matrix_gate",
        },
        OperatorCapability {
            id: "native.code.create",
            status: OperatorCapabilityStatus::Available,
            runtime_target: OperatorRuntimeTarget::NativeHeadlessStateDir,
            control_effect: OperatorControlEffect::NativeMutation,
            command: "headless-native: skybridge code create [--json]",
            owner_module: "connection_code::create + skybridge-agent state",
            authority_boundary: "standalone native CLI auth/session state under the selected state_dir; does not mutate the Mac GUI runtime and must not be used as a GUI interop substitute",
            verification_gate: "connection_code::tests",
        },
        OperatorCapability {
            id: "native.connect",
            status: OperatorCapabilityStatus::Available,
            runtime_target: OperatorRuntimeTarget::NativeHeadlessStateDir,
            control_effect: OperatorControlEffect::NativeMutation,
            command: "headless-native: skybridge connect <code> [--json]",
            owner_module: "connection_code::connect + skybridge-agent state",
            authority_boundary: "standalone native signaling/WebRTC runtime backed by Rust state_dir; does not bind or update CrossNetworkConnectionManager in the Mac app",
            verification_gate: "connection_code::tests",
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
            status: OperatorCapabilityStatus::RequestOnly,
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::RequestOnly,
            command: "request-only: skybridge file send <path> --to <peer> --session-id <id> [--json]",
            owner_module: "file_commands + FileTransferControlRequestRegistry + agent file_transfer coordinator",
            authority_boundary: "requires current handshake-complete session proof, bound remote protocol identity, and local regular-file SHA-256 snapshot; the CLI synchronously writes only an agent-owned pending request, after which the managed agent performs a live chunked transfer over the encrypted control channel and records success only on a SHA-256-verified receipt; transfer outcome is observable via `file history`",
            verification_gate: "file_transfer_contract_gate + file_transfer_agent_observation_request_registry_gate + file_transfer_json_contract_fails_closed_without_path_or_peer_leakage + real_device_file_transfer_gate",
        },
        OperatorCapability {
            id: "file.transfer.receive",
            status: OperatorCapabilityStatus::Planned,
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::PlannedFailClosed,
            command: "planned/fail-closed: skybridge file receive [--json]",
            owner_module: "file_commands + agent file_transfer coordinator",
            authority_boundary: "inbound transfers are auto-received by the managed agent runtime into the state-dir received/ directory with filename sanitization, path-traversal and symlink rejection, collision-safe non-overwriting writes, and SHA-256 verification before atomic rename; the standalone `file receive` CLI verb stays fail-closed because reception requires no synchronous operator action",
            verification_gate: "file_transfer_json_contract_fails_closed_without_path_or_peer_leakage + real_device_file_transfer_gate",
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
            verification_gate: "remote_desktop_dispatch_registers_pending_request_without_live_success",
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
            status: OperatorCapabilityStatus::RequestOnly,
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::RequestOnly,
            command: "request-only: skybridge remote-desktop start --session-id <id> [--resolution <preset>] [--fps <value>] [--json]",
            owner_module: "remote_desktop_commands + RemoteDesktopControlRequestRegistry",
            authority_boundary: "writes an agent-owned pending request for an established session; live apply still requires sender apply evidence and real-device evidence",
            verification_gate: "remote_desktop_pending_request_registry_gate + real_device_p2p_remote_gate + remote_control_notice_artifact_gate",
        },
        OperatorCapability {
            id: "remote_desktop.stop",
            status: OperatorCapabilityStatus::RequestOnly,
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::RequestOnly,
            command: "request-only: skybridge remote-desktop stop --session-id <id> [--json]",
            owner_module: "remote_desktop_commands + RemoteDesktopControlRequestRegistry",
            authority_boundary: "writes an agent-owned pending request only; does not kill processes or report stream stopped before observe",
            verification_gate: "remote_desktop_pending_request_registry_gate + real_device_p2p_remote_gate",
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
            status: OperatorCapabilityStatus::RequestOnly,
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::RequestOnly,
            command: "request-only: skybridge remote-desktop set-resolution --session-id <id> --resolution <preset> [--json]",
            owner_module: "remote_desktop_commands + RemoteDesktopControlRequestRegistry",
            authority_boundary: "validates the request contract and records a pending request; observed sender mode change still requires observe evidence",
            verification_gate: "remote_desktop_pending_request_registry_gate + real_device_p2p_remote_gate",
        },
        OperatorCapability {
            id: "remote_desktop.fps.set",
            status: OperatorCapabilityStatus::RequestOnly,
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::RequestOnly,
            command: "request-only: skybridge remote-desktop set-fps --session-id <id> --fps <value> [--json]",
            owner_module: "remote_desktop_commands + RemoteDesktopControlRequestRegistry",
            authority_boundary: "validates bounded fps and records a pending request; FPS is not applied until sender apply and media evidence exist",
            verification_gate: "remote_desktop_pending_request_registry_gate + performance_p2p_remote_final_window_fps_gate",
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
mod tests {
    use super::*;

    #[test]
    fn operator_capability_contract_covers_requested_surface_without_fake_success() {
        let capabilities = operator_capabilities();
        let ids = capabilities
            .iter()
            .map(|capability| capability.id)
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(ids.len(), capabilities.len());

        for required in [
            "crossnet.preflight",
            "crossnet.status.snapshot",
            "crossnet.settings.snapshot",
            "device.discovery.nearby",
            "remote_desktop.contract",
            "remote_desktop.status",
            "remote_desktop.resolution_contract",
            "remote_desktop.resolutions.list",
            "remote_desktop.media.doctor",
        ] {
            let capability = capabilities
                .iter()
                .find(|capability| capability.id == required)
                .expect("requested read-only capability must be declared");
            assert_eq!(capability.status, OperatorCapabilityStatus::ReadOnly);
            assert!(
                !capability.authority_boundary.trim().is_empty(),
                "{required} must declare its authority boundary"
            );
            assert!(
                !capability.verification_gate.trim().is_empty(),
                "{required} must declare its verification gate"
            );
        }

        let preflight = capabilities
            .iter()
            .find(|capability| capability.id == "crossnet.preflight")
            .expect("crossnet preflight capability must be declared");
        assert_eq!(preflight.status, OperatorCapabilityStatus::ReadOnly);
        assert_eq!(
            preflight.runtime_target,
            OperatorRuntimeTarget::MacAppRuntime
        );
        assert_eq!(preflight.control_effect, OperatorControlEffect::ReadOnly);
        assert!(preflight.command.contains("crossnet preflight"));
        assert!(
            preflight.authority_boundary.contains("Mac app")
                && preflight.authority_boundary.contains("does not")
                && preflight.authority_boundary.contains("iOS runtime"),
            "crossnet.preflight must stay Mac-only and read-only"
        );

        let status_snapshot = capabilities
            .iter()
            .find(|capability| capability.id == "crossnet.status.snapshot")
            .expect("crossnet status snapshot capability must be declared");
        assert_eq!(status_snapshot.status, OperatorCapabilityStatus::ReadOnly);
        assert_eq!(
            status_snapshot.runtime_target,
            OperatorRuntimeTarget::MacAppRuntime
        );
        assert_eq!(
            status_snapshot.control_effect,
            OperatorControlEffect::ReadOnly
        );
        assert!(
            status_snapshot
                .authority_boundary
                .contains("redacted session_ref")
                && status_snapshot.authority_boundary.contains("does not")
                && status_snapshot.authority_boundary.contains("iOS runtime"),
            "crossnet.status.snapshot must stay Mac-only, read-only, and redacted"
        );

        let settings_snapshot = capabilities
            .iter()
            .find(|capability| capability.id == "crossnet.settings.snapshot")
            .expect("crossnet settings snapshot capability must be declared");
        assert_eq!(settings_snapshot.status, OperatorCapabilityStatus::ReadOnly);
        assert_eq!(
            settings_snapshot.runtime_target,
            OperatorRuntimeTarget::MacAppRuntime
        );
        assert_eq!(
            settings_snapshot.control_effect,
            OperatorControlEffect::ReadOnly
        );
        assert!(
            settings_snapshot.authority_boundary.contains("allowlisted")
                && settings_snapshot.authority_boundary.contains("non-secret")
                && settings_snapshot
                    .authority_boundary
                    .contains("does not write UserDefaults")
                && settings_snapshot.authority_boundary.contains("iOS runtime"),
            "crossnet.settings.snapshot must stay allowlisted, read-only, and Mac-only"
        );

        let settings_set = capabilities
            .iter()
            .find(|capability| capability.id == "crossnet.settings.set")
            .expect("crossnet settings set capability must be declared");
        // The handler is implemented and enabled, so `planned` would deny a live
        // code path; but no live signed-app socket smoke has been captured, so
        // `available` would claim absent proof. Both directions stay guarded.
        assert_eq!(
            settings_set.status,
            OperatorCapabilityStatus::PendingLiveProof
        );
        assert_eq!(
            settings_set.runtime_target,
            OperatorRuntimeTarget::MacAppRuntime
        );
        assert_eq!(
            settings_set.control_effect,
            OperatorControlEffect::MacRuntimeMutation
        );
        assert!(
            settings_set.authority_boundary.contains("typed allowlist")
                && settings_set
                    .authority_boundary
                    .contains("setting_runtime_apply_failed")
                && settings_set.authority_boundary.contains("fails closed")
                && settings_set.authority_boundary.contains("pqc.*")
                && settings_set
                    .authority_boundary
                    .contains("live signed-app socket smoke"),
            "crossnet.settings.set must declare its allowlist, read-back failure mode, pqc exclusion, and missing live proof"
        );
        assert!(
            !settings_set.command.contains("planned/"),
            "crossnet.settings.set is implemented, so its command must not be labelled planned"
        );

        let status_watch = capabilities
            .iter()
            .find(|capability| capability.id == "crossnet.status.watch")
            .expect("crossnet status watch capability must be declared");
        assert_eq!(status_watch.status, OperatorCapabilityStatus::Planned);
        assert_eq!(
            status_watch.runtime_target,
            OperatorRuntimeTarget::MacAppRuntime
        );
        assert_eq!(
            status_watch.control_effect,
            OperatorControlEffect::PlannedFailClosed
        );
        assert!(
            status_watch
                .authority_boundary
                .contains("watch_not_supported")
                && status_watch.authority_boundary.contains("fail-closed"),
            "crossnet.status.watch must keep the fail-closed stream gate visible"
        );

        for required in ["crossnet.host", "crossnet.connect", "crossnet.disconnect"] {
            let capability = capabilities
                .iter()
                .find(|capability| capability.id == required)
                .expect("app-bound crossnet capability must be declared");
            assert_eq!(capability.status, OperatorCapabilityStatus::Planned);
            assert_eq!(
                capability.runtime_target,
                OperatorRuntimeTarget::MacAppRuntime
            );
            assert_eq!(
                capability.control_effect,
                OperatorControlEffect::MacMutationNotEnabled
            );
            assert!(
                capability.command.contains("app-bound"),
                "{required} must advertise the Mac app authority boundary"
            );
            assert!(
                capability.authority_boundary.contains("Mac-only")
                    && capability.authority_boundary.contains("signed Mac app")
                    && capability.authority_boundary.contains("live socket smoke"),
                "{required} must keep the Mac-only signed-app smoke gate visible"
            );
        }

        for required in ["native.code.create", "native.connect"] {
            let capability = capabilities
                .iter()
                .find(|capability| capability.id == required)
                .expect("native/headless capability must be declared");
            assert_eq!(capability.status, OperatorCapabilityStatus::Available);
            assert_eq!(
                capability.runtime_target,
                OperatorRuntimeTarget::NativeHeadlessStateDir
            );
            assert_eq!(
                capability.control_effect,
                OperatorControlEffect::NativeMutation
            );
            assert!(
                capability.authority_boundary.contains("does not"),
                "{required} must not imply GUI mutation"
            );
        }

        let active_scan = capabilities
            .iter()
            .find(|capability| capability.id == "device.discovery.active_scan")
            .expect("active nearby scan capability must be declared");
        assert_eq!(active_scan.status, OperatorCapabilityStatus::ReadOnly);
        assert!(
            active_scan
                .command
                .contains("device discover --nearby --scan")
                && active_scan
                    .authority_boundary
                    .contains("agent-owned active mDNS scanner")
                && active_scan.authority_boundary.contains("fail closed")
        );

        let send = capabilities
            .iter()
            .find(|capability| capability.id == "file.transfer.send")
            .expect("file send capability must be declared");
        assert_eq!(send.status, OperatorCapabilityStatus::RequestOnly);
        assert!(send.command.contains("--session-id"));
        assert!(
            send.owner_module
                .contains("FileTransferControlRequestRegistry")
        );
        assert!(send.authority_boundary.contains("pending request"));

        let receive = capabilities
            .iter()
            .find(|capability| capability.id == "file.transfer.receive")
            .expect("file receive capability must be declared");
        assert_eq!(receive.status, OperatorCapabilityStatus::Planned);
        assert!(
            !receive.authority_boundary.trim().is_empty(),
            "file.transfer.receive must declare its authority boundary"
        );
        assert!(
            !receive.verification_gate.trim().is_empty(),
            "file.transfer.receive must declare its verification gate"
        );

        for required in [
            "remote_desktop.start",
            "remote_desktop.stop",
            "remote_desktop.resolution.set",
            "remote_desktop.fps.set",
        ] {
            let capability = capabilities
                .iter()
                .find(|capability| capability.id == required)
                .expect("request-only capability must be declared");
            assert_eq!(capability.status, OperatorCapabilityStatus::RequestOnly);
            assert!(
                capability.command.contains("request-only"),
                "{required} must not imply live application"
            );
            assert!(
                !capability.authority_boundary.trim().is_empty(),
                "{required} must declare its authority boundary"
            );
            assert!(
                !capability.verification_gate.trim().is_empty(),
                "{required} must declare its verification gate"
            );
        }
    }

    #[test]
    fn operator_capability_matrix_keeps_ios_out_of_rust_runtime_control() {
        for capability in operator_capabilities() {
            for field in [
                capability.id,
                capability.command,
                capability.owner_module,
                capability.authority_boundary,
                capability.verification_gate,
            ] {
                assert!(
                    !field.contains("ios_app_runtime"),
                    "{} must not introduce an iOS Rust CLI runtime target",
                    capability.id
                );
            }

            if capability.runtime_target == OperatorRuntimeTarget::MacAppRuntime {
                assert!(
                    capability
                        .owner_module
                        .contains("Mac OperatorControlServer"),
                    "{} must keep Mac GUI authority behind the app-owned OperatorControl server",
                    capability.id
                );
            }

            if capability.control_effect == OperatorControlEffect::MacMutationNotEnabled {
                assert_eq!(
                    capability.status,
                    OperatorCapabilityStatus::Planned,
                    "{} must not claim an enabled Mac GUI mutation before signed-app runtime proof",
                    capability.id
                );
            }

            // A verb that really mutates the Mac runtime may only be reported as
            // proven (`available`) or explicitly unproven (`pending_live_proof`).
            if capability.control_effect == OperatorControlEffect::MacRuntimeMutation {
                assert!(
                    matches!(
                        capability.status,
                        OperatorCapabilityStatus::Available
                            | OperatorCapabilityStatus::PendingLiveProof
                    ),
                    "{} performs a live Mac runtime mutation, so it must be available or pending_live_proof",
                    capability.id
                );
                assert!(
                    capability
                        .verification_gate
                        .contains("live signed-app socket smoke"),
                    "{} must keep a live signed-app socket smoke gate",
                    capability.id
                );
            }

            // `pending_live_proof` is only honest while the proof is genuinely
            // outstanding, so it must name the evidence it still needs.
            if capability.status == OperatorCapabilityStatus::PendingLiveProof {
                assert!(
                    capability
                        .authority_boundary
                        .contains("live signed-app socket smoke"),
                    "{} must state which live evidence is still missing",
                    capability.id
                );
            }
        }
    }

    #[test]
    fn operator_capability_contract_renders_text_and_json() -> Result<()> {
        print_operator_capabilities(false)?;
        print_operator_capabilities(true)
    }
}
