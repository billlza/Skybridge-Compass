use anyhow::Result;
use serde::Serialize;
use serde_json::json;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum OperatorCapabilityStatus {
    Available,
    ReadOnly,
    RequestOnly,
    Planned,
}

impl OperatorCapabilityStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Available => "available",
            Self::ReadOnly => "read_only",
            Self::RequestOnly => "request_only",
            Self::Planned => "planned",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
struct OperatorCapability {
    id: &'static str,
    status: OperatorCapabilityStatus,
    command: &'static str,
    owner_module: &'static str,
    authority_boundary: &'static str,
    verification_gate: &'static str,
}

const OPERATOR_CAPABILITY_SCHEMA_VERSION: u32 = 1;

fn operator_capabilities() -> &'static [OperatorCapability] {
    &[
        OperatorCapability {
            id: "crossnet.host",
            status: OperatorCapabilityStatus::Available,
            command: "app-bound: skybridge crossnet host [--lease short|long] [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Mac app operator socket; requires the running signed Mac app to have auth_loaded=true and tenant_bound=true; returns a real app-issued connection code and never falls back to native CLI auth",
            verification_gate: "skybridge-crossnet-client fake UDS preflight tests + live app socket smoke",
        },
        OperatorCapability {
            id: "crossnet.connect",
            status: OperatorCapabilityStatus::Available,
            command: "app-bound: skybridge crossnet connect <code> [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Mac app operator socket; mutates CrossNetworkConnectionManager in the running Mac app only after app auth and tenant preflight pass",
            verification_gate: "skybridge-crossnet-client fake UDS preflight tests + live app socket smoke",
        },
        OperatorCapability {
            id: "crossnet.disconnect",
            status: OperatorCapabilityStatus::Available,
            command: "app-bound: skybridge crossnet disconnect [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Mac app operator socket; requires app auth and tenant binding and reports whether an app session was present before disconnect",
            verification_gate: "OperatorControlServer disconnect auth gate + crossnet client preflight tests",
        },
        OperatorCapability {
            id: "crossnet.status",
            status: OperatorCapabilityStatus::ReadOnly,
            command: "app-bound/read-only: skybridge crossnet status [--watch] [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "read-only Mac app operator socket status; reports auth_loaded/tenant_bound plus redacted session presence/ref without exposing raw session ids",
            verification_gate: "crossnet status redaction tests + live app socket smoke",
        },
        OperatorCapability {
            id: "device.status",
            status: OperatorCapabilityStatus::Available,
            command: "skybridge device status [--json]",
            owner_module: "device_commands::status",
            authority_boundary: "local identity, PQC identity, and agent health read-only report",
            verification_gate: "device_status_reports_local_identity_without_auth",
        },
        OperatorCapability {
            id: "device.discovery.nearby",
            status: OperatorCapabilityStatus::ReadOnly,
            command: "skybridge device discover --nearby [--json]",
            owner_module: "device_commands + NearbyDiscoverySnapshotRegistry",
            authority_boundary: "read-only agent-owned nearby discovery snapshot; this command does not start Bonjour/local-network scanning, missing or stale snapshots fail closed, and discovery does not authorize connection",
            verification_gate: "device_discovery_nearby_snapshot_gate + nearby_discovery_json_contract_fails_closed_without_fake_empty_results",
        },
        OperatorCapability {
            id: "device.discovery.active_scan",
            status: OperatorCapabilityStatus::ReadOnly,
            command: "skybridge device discover --nearby --scan [--json]",
            owner_module: "device_commands + agent-owned active mDNS scanner",
            authority_boundary: "read-only result of the agent-owned active mDNS scanner; the agent performs the live Bonjour/local-network scan with protocol identity dedupe and locator-free device refs, missing or stale active snapshots fail closed, and discovery never authorizes connection",
            verification_gate: "device_discovery_nearby_snapshot_gate + connectivity_matrix_gate",
        },
        OperatorCapability {
            id: "native.code.create",
            status: OperatorCapabilityStatus::Available,
            command: "headless-native: skybridge code create [--json]",
            owner_module: "connection_code::create + skybridge-agent state",
            authority_boundary: "standalone native CLI auth/session state under the selected state_dir; does not mutate the Mac GUI runtime and must not be used as a GUI interop substitute",
            verification_gate: "connection_code::tests",
        },
        OperatorCapability {
            id: "native.connect",
            status: OperatorCapabilityStatus::Available,
            command: "headless-native: skybridge connect <code> [--json]",
            owner_module: "connection_code::connect + skybridge-agent state",
            authority_boundary: "standalone native signaling/WebRTC runtime backed by Rust state_dir; does not bind or update CrossNetworkConnectionManager in the Mac app",
            verification_gate: "connection_code::tests",
        },
        OperatorCapability {
            id: "session.list",
            status: OperatorCapabilityStatus::Available,
            command: "skybridge session ls [--json]",
            owner_module: "session_commands",
            authority_boundary: "read-only native/headless SessionRegistry projection; for Mac GUI session state use `skybridge crossnet status`",
            verification_gate: "session_commands::tests",
        },
        OperatorCapability {
            id: "session.inspect",
            status: OperatorCapabilityStatus::Available,
            command: "skybridge session inspect <id> [--json]",
            owner_module: "session_commands",
            authority_boundary: "read-only native/headless single-session projection; not a Mac GUI runtime projection",
            verification_gate: "session_commands::tests",
        },
        OperatorCapability {
            id: "session.disconnect",
            status: OperatorCapabilityStatus::Available,
            command: "skybridge disconnect <session-id>",
            owner_module: "session_commands",
            authority_boundary: "updates native/headless ManagedSessionControl and RuntimeSessionRecord through skybridge-agent state helpers; for Mac GUI disconnect use `skybridge crossnet disconnect`",
            verification_gate: "dispatch_covers_operator_entry_error_and_wrapper_paths",
        },
        OperatorCapability {
            id: "file.transfer.send",
            status: OperatorCapabilityStatus::RequestOnly,
            command: "request-only: skybridge file send <path> --to <peer> --session-id <id> [--json]",
            owner_module: "file_commands + FileTransferControlRequestRegistry + agent file_transfer coordinator",
            authority_boundary: "requires current handshake-complete session proof, bound remote protocol identity, and local regular-file SHA-256 snapshot; the CLI synchronously writes only an agent-owned pending request, after which the managed agent performs a live chunked transfer over the encrypted control channel and records success only on a SHA-256-verified receipt; transfer outcome is observable via `file history`",
            verification_gate: "file_transfer_contract_gate + file_transfer_agent_observation_request_registry_gate + file_transfer_json_contract_fails_closed_without_path_or_peer_leakage + real_device_file_transfer_gate",
        },
        OperatorCapability {
            id: "file.transfer.receive",
            status: OperatorCapabilityStatus::Planned,
            command: "planned/fail-closed: skybridge file receive [--json]",
            owner_module: "file_commands + agent file_transfer coordinator",
            authority_boundary: "inbound transfers are auto-received by the managed agent runtime into the state-dir received/ directory with filename sanitization, path-traversal and symlink rejection, collision-safe non-overwriting writes, and SHA-256 verification before atomic rename; the standalone `file receive` CLI verb stays fail-closed because reception requires no synchronous operator action",
            verification_gate: "file_transfer_json_contract_fails_closed_without_path_or_peer_leakage + real_device_file_transfer_gate",
        },
        OperatorCapability {
            id: "file.transfer.history",
            status: OperatorCapabilityStatus::ReadOnly,
            command: "skybridge file history [--json]",
            owner_module: "file_commands",
            authority_boundary: "reports redacted request registry state including evidence-gated transfer progress and SHA-256 receipt verification; success fields are true only when the agent recorded a verified receipt",
            verification_gate: "file_transfer_agent_observation_request_registry_gate + file_transfer_json_contract_fails_closed_without_path_or_peer_leakage",
        },
        OperatorCapability {
            id: "remote_desktop.contract",
            status: OperatorCapabilityStatus::ReadOnly,
            command: "skybridge remote-desktop contract [--json]",
            owner_module: "remote_desktop_commands",
            authority_boundary: "read-only CLI request contract; cannot mutate sessions or claim live sender mode evidence",
            verification_gate: "remote_desktop_contract_keeps_live_application_unobserved",
        },
        OperatorCapability {
            id: "remote_desktop.status",
            status: OperatorCapabilityStatus::ReadOnly,
            command: "skybridge remote-desktop status [--session-id <id>] [--json]",
            owner_module: "remote_desktop_commands + SessionRegistry + RemoteDesktopControlRequestRegistry",
            authority_boundary: "read-only runtime session and pending request projection; cannot claim live sender apply evidence",
            verification_gate: "remote_desktop_dispatch_registers_pending_request_without_live_success",
        },
        OperatorCapability {
            id: "remote_desktop.resolution_contract",
            status: OperatorCapabilityStatus::ReadOnly,
            command: "skybridge remote-desktop resolutions [--json]",
            owner_module: "remote_desktop_commands",
            authority_boundary: "request-contract-only list, not observed sender-supported modes",
            verification_gate: "remote_desktop_json_contract_is_machine_readable_without_live_success_claims",
        },
        OperatorCapability {
            id: "remote_desktop.start",
            status: OperatorCapabilityStatus::RequestOnly,
            command: "request-only: skybridge remote-desktop start --session-id <id> [--resolution <preset>] [--fps <value>] [--json]",
            owner_module: "remote_desktop_commands + RemoteDesktopControlRequestRegistry",
            authority_boundary: "writes an agent-owned pending request for an established session; live apply still requires sender apply evidence and real-device evidence",
            verification_gate: "remote_desktop_pending_request_registry_gate + real_device_p2p_remote_gate + remote_control_notice_artifact_gate",
        },
        OperatorCapability {
            id: "remote_desktop.stop",
            status: OperatorCapabilityStatus::RequestOnly,
            command: "request-only: skybridge remote-desktop stop --session-id <id> [--json]",
            owner_module: "remote_desktop_commands + RemoteDesktopControlRequestRegistry",
            authority_boundary: "writes an agent-owned pending request only; does not kill processes or report stream stopped before observe",
            verification_gate: "remote_desktop_pending_request_registry_gate + real_device_p2p_remote_gate",
        },
        OperatorCapability {
            id: "remote_desktop.resolutions.list",
            status: OperatorCapabilityStatus::ReadOnly,
            command: "skybridge remote-desktop resolutions --session-id <id> [--json]",
            owner_module: "remote_desktop_commands + RemoteDesktopCapabilitySnapshotRegistry",
            authority_boundary: "read-only agent-owned observed sender display capability snapshot; not a sender apply receipt and not live apply",
            verification_gate: "remote_desktop_capability_snapshot_registry_gate + remote_desktop_json_contract_is_machine_readable_without_live_success_claims",
        },
        OperatorCapability {
            id: "remote_desktop.resolution.set",
            status: OperatorCapabilityStatus::RequestOnly,
            command: "request-only: skybridge remote-desktop set-resolution --session-id <id> --resolution <preset> [--json]",
            owner_module: "remote_desktop_commands + RemoteDesktopControlRequestRegistry",
            authority_boundary: "validates the request contract and records a pending request; observed sender mode change still requires observe evidence",
            verification_gate: "remote_desktop_pending_request_registry_gate + real_device_p2p_remote_gate",
        },
        OperatorCapability {
            id: "remote_desktop.fps.set",
            status: OperatorCapabilityStatus::RequestOnly,
            command: "request-only: skybridge remote-desktop set-fps --session-id <id> --fps <value> [--json]",
            owner_module: "remote_desktop_commands + RemoteDesktopControlRequestRegistry",
            authority_boundary: "validates bounded fps and records a pending request; FPS is not applied until sender apply and media evidence exist",
            verification_gate: "remote_desktop_pending_request_registry_gate + performance_p2p_remote_final_window_fps_gate",
        },
        OperatorCapability {
            id: "remote_desktop.media.doctor",
            status: OperatorCapabilityStatus::ReadOnly,
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
                "capabilities": capabilities,
            }))?
        );
        return Ok(());
    }

    println!(
        "Operator Capability Contract v{}",
        OPERATOR_CAPABILITY_SCHEMA_VERSION
    );
    for capability in capabilities {
        println!(
            "{} [{}] {}",
            capability.id,
            capability.status.as_str(),
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
            "crossnet.status",
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

        for required in ["crossnet.host", "crossnet.connect", "crossnet.disconnect"] {
            let capability = capabilities
                .iter()
                .find(|capability| capability.id == required)
                .expect("app-bound crossnet capability must be declared");
            assert_eq!(capability.status, OperatorCapabilityStatus::Available);
            assert!(
                capability.command.contains("app-bound"),
                "{required} must advertise the Mac app authority boundary"
            );
            assert!(
                capability
                    .authority_boundary
                    .contains("Mac app operator socket"),
                "{required} must not look like a native state-dir mutation"
            );
        }

        for required in ["native.code.create", "native.connect"] {
            let capability = capabilities
                .iter()
                .find(|capability| capability.id == required)
                .expect("native/headless capability must be declared");
            assert_eq!(capability.status, OperatorCapabilityStatus::Available);
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
    fn operator_capability_contract_renders_text_and_json() -> Result<()> {
        print_operator_capabilities(false)?;
        print_operator_capabilities(true)
    }
}
