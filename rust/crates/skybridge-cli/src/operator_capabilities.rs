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
}

impl OperatorCapabilityStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Available => "available",
            Self::ReadOnly => "read_only",
            Self::Unavailable => "unavailable",
            Self::PendingLiveProof => "pending_live_proof",
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
    /// The Mac app creates or tears down a cross-network *session* and reports
    /// the session state it reads back afterwards.
    ///
    /// Distinct from ``MacRuntimeMutation`` so an operator can tell "I changed a
    /// setting" from "I moved this machine onto or off a live peer session".
    MacSessionMutation,
    ContractOnly,
    UnavailableFailClosed,
    ArtifactOnly,
}

impl OperatorControlEffect {
    fn as_str(self) -> &'static str {
        match self {
            Self::ReadOnly => "read_only",
            Self::NativeMutation => "native_mutation",
            Self::MacRuntimeMutation => "mac_runtime_mutation",
            Self::MacSessionMutation => "mac_session_mutation",
            Self::ContractOnly => "contract_only",
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
            verification_gate: "preflight_payload_reports_ready_mac_app_without_mutation_claims + crossnet_cli_json_contract_uses_fake_socket_for_preflight_status_connect_json + Mac OperatorControlServer hello round-trip + signed Mac app socket smoke",
        },
        OperatorCapability {
            id: "crossnet.host",
            status: OperatorCapabilityStatus::PendingLiveProof,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::MacSessionMutation,
            command: "app-bound: skybridge crossnet host [--lease short|long] [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Mac-only session issuance is implemented and enabled: the signed Mac app calls CrossNetworkConnectionManager.issueConnectionCode with the operator-supplied lease instead of writing the GUI lease preference, requires auth_loaded=true and tenant_bound=true, and the router rejects the response unless the applied lease equals the requested lease and the hosting session is reported as a redacted session_ref; a code is real server-issued material, so a host that cannot reach signaling fails closed rather than returning a placeholder; this verb is NOT read-only with respect to an existing session, because the manager tears the current session down when the requested lease differs from the active one, and it returns the app's existing code unchanged when the lease and authority already match, so an operator must treat `host --lease` as a session-affecting command; status stays pending_live_proof until live signed-app socket smoke is captured",
            verification_gate: "Mac OperatorControlServer auth/tenant gate tests + host lease read-back rejection tests + live signed-app socket smoke + real code issuance evidence",
        },
        OperatorCapability {
            id: "crossnet.connect",
            status: OperatorCapabilityStatus::PendingLiveProof,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::MacSessionMutation,
            command: "app-bound: skybridge crossnet connect <code> [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Mac-only code redemption is implemented and enabled: the signed Mac app calls CrossNetworkConnectionManager.connectWithCode after auth_loaded=true and tenant_bound=true, and reports the readiness it reads back from its own runtime rather than a constant; connectWithCode returns when the offer session starts and not when the peer answers, so this verb never claims handshake_complete unless the app's connection status agrees, and a run that leaves the app failed is rejected; status stays pending_live_proof until live signed-app socket smoke is captured with a real peer",
            verification_gate: "Mac OperatorControlServer auth/tenant gate tests + connect readiness read-back rejection tests + live signed-app socket smoke + CrossNetworkConnectionManager mutation evidence",
        },
        OperatorCapability {
            id: "crossnet.devices",
            status: OperatorCapabilityStatus::ReadOnly,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::ReadOnly,
            command: "app-bound/read-only: skybridge crossnet devices [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Reads the Mac app's unified online-device snapshot through crossnet-control/1 after auth and tenant preflight; entries carry a redacted device_ref plus display name, platform, and online state only — raw device ids, IP addresses, MAC addresses, and serial numbers never cross this surface; the list mutates nothing and does not dial any device",
            verification_gate: "Mac OperatorControlServer devices redaction tests + signed Mac app socket smoke before release readiness claims",
        },
        OperatorCapability {
            id: "crossnet.connect_device",
            status: OperatorCapabilityStatus::PendingLiveProof,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::MacSessionMutation,
            command: "app-bound: skybridge crossnet connect-device <device_ref> [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer + OnlineDeviceConnectionCoordinator",
            authority_boundary: "Mac-only one-click device join is implemented and enabled: the signed Mac app resolves the redacted device_ref against its unified online-device snapshot, dials the device's discovered and pinned-trust control routes through the app's own online-device coordinator (the peer admits automatically, nothing is typed on it), and reports the device manager's own connected read-back; a dial the manager does not read back as connected fails closed rather than claiming a join, and status stays pending_live_proof until live signed-app socket smoke is captured with a real peer device",
            verification_gate: "typed device-ref resolution tests + connected read-back rejection tests + live signed-app socket smoke",
        },
        OperatorCapability {
            id: "crossnet.disconnect",
            status: OperatorCapabilityStatus::PendingLiveProof,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::MacSessionMutation,
            command: "app-bound: skybridge crossnet disconnect [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Mac-only session teardown is implemented and enabled: the signed Mac app calls CrossNetworkConnectionManager.disconnect after auth_loaded=true and tenant_bound=true, then re-reads its own connection state; because disconnect cannot fail loudly, teardown is only reported when the read-back shows no surviving session, and having nothing to tear down is reported as disconnected=false rather than as success; status stays pending_live_proof until live signed-app socket smoke is captured",
            verification_gate: "Mac OperatorControlServer disconnect auth gate tests + post-teardown read-back rejection tests + live signed-app socket smoke + app session teardown evidence",
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
            authority_boundary: "Mac-app-bound settings mutation is implemented and enabled: the app applies one entry from a typed allowlist that is a strict subset of the readable projection, requires auth_loaded=true and tenant_bound=true, re-reads the property from its runtime after the apply hook, and fails closed with setting_runtime_apply_failed when the read-back differs; pqc.* ids stay immutable here because their authority is the versioned protocol identity prepare/commit flow, which can require peer re-pinning; the remote_desktop.* capture ids are mutable but carry an applies_at_next_capture_start note because ScreenCaptureKit reads size and frame rate only when a stream starts, so writing them never retunes a running session; Rust state_dir/UserDefaults direct writes are not valid GUI control and status stays pending_live_proof until live signed-app socket smoke is captured",
            verification_gate: "Mac OperatorControlServer auth/tenant and settings allowlist tests + runtime observation tests + live signed-app socket smoke",
        },
        OperatorCapability {
            id: "crossnet.navigation",
            status: OperatorCapabilityStatus::PendingLiveProof,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::MacRuntimeMutation,
            command: "app-bound: skybridge crossnet navigate <destination> [--json]",
            owner_module: "Mac OperatorControlServer + app-owned injected navigation coordinator",
            authority_boundary: "Mac-only UI navigation is implemented and enabled through an app-owned injected navigation coordinator with typed destinations: the dashboard view applies the request through its own selection state and confirms what it actually presented, the router refuses any result the UI did not confirm (navigation_apply_failed), it is not emulated through global notifications or direct view-state writes, and status stays pending_live_proof until live signed-app socket smoke is captured",
            verification_gate: "typed navigation destination tests + app-owned coordinator read-back rejection tests + live signed-app socket smoke",
        },
        OperatorCapability {
            id: "crossnet.status.watch",
            status: OperatorCapabilityStatus::PendingLiveProof,
            runtime_target: OperatorRuntimeTarget::MacAppRuntime,
            control_effect: OperatorControlEffect::ReadOnly,
            command: "app-bound/read-only: skybridge crossnet status --watch [--json]",
            owner_module: "crossnet_commands + skybridge-crossnet-client + Mac OperatorControlServer",
            authority_boundary: "Mac-only status streaming is implemented and enabled: the app pushes a coalesced, deduplicated redacted status snapshot over the same one-connection stream whenever the connection manager's state settles, each frame re-reads auth flags, the per-client send is timeout-bounded so a stalled watcher cannot wedge the app, and a build without a wired push source still fails closed with watch_not_supported; the stream mutates nothing, and status stays pending_live_proof until live signed-app socket smoke is captured",
            verification_gate: "Mac OperatorControlServer watch stream tests (initial response + coalesced events + fail-closed unwired source) + send-timeout bound + live signed-app socket smoke",
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
            verification_gate: "active_scan_cli_enforces_nearby_address_and_duration_boundaries + active_scan_persistence_keeps_ephemeral_address_out_of_registry + active_scan_json_hides_addresses_by_default_and_labels_explicit_disclosure + controlled-LAN real-device scan gate",
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
            verification_gate: "file_send_wait_decision_requires_verified_matching_receipt + file_send_wait_decision_surfaces_failure_and_rejection + file_send_json_only_claims_success_for_verified_completion + file_transfer_agent_observation_request_registry_gate + file_transfer_json_contract_fails_closed_without_path_or_peer_leakage + real_device_file_transfer_gate",
        },
        OperatorCapability {
            id: "file.transfer.receive",
            status: OperatorCapabilityStatus::PendingLiveProof,
            runtime_target: OperatorRuntimeTarget::AgentOwnedRegistry,
            control_effect: OperatorControlEffect::NativeMutation,
            command: "skybridge file receive --list [--json] | --session-id <id> (--accept|--reject) <transfer-uuid> [--json]",
            owner_module: "file_commands + InboundFileTransferApprovalRegistry + agent file_transfer coordinator",
            authority_boundary: "listing is a read-only projection of persisted inbound approval records; accept/reject requires a health-fresh lock-owning agent and the current runtime incarnation, stable authenticated peer device id, and protocol fingerprint, then records only a pending agent decision (applied=false); the agent owns the live native sender and emits metadata ACK/error, and allocates staging/storage only after approval; status remains pending_live_proof until a real-device cross-platform inbound transfer artifact is captured",
            verification_gate: "persistent_approval_registry_is_the_pending_timeout_authority + stale_inbound_approvals_are_terminalized_before_capacity_reuse + file_receive_list_and_decision_json_contract + real_device_file_transfer_gate",
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
            authority_boundary: "verifies the authenticated peer capability boundary, then rejects without a registry write: the standalone Rust runtime has no screen-capture/media/input backend, and remote desktop admission on the Mac app requires an already-accepted inbound authenticated transport that the operator CLI does not own, so there is no entry point to promote on either side",
            verification_gate: "standalone remote desktop backend + authenticated SBWC control/apply receipt + real_device_p2p_remote_gate + remote_control_notice_artifact_gate",
        },
        OperatorCapability {
            id: "remote_desktop.stop",
            status: OperatorCapabilityStatus::Unavailable,
            runtime_target: OperatorRuntimeTarget::NativeHeadlessStateDir,
            control_effect: OperatorControlEffect::UnavailableFailClosed,
            command: "unavailable/fail-closed: skybridge remote-desktop stop --session-id <id> [--json]",
            owner_module: "remote_desktop_commands + authenticated RuntimeSessionRecord evidence",
            authority_boundary: "rejects without claiming a stream stop because the standalone runtime does not own a remote desktop backend or live stream state; the Mac app can tear a peer down but addresses peers by device id rather than by this command's agent session id, so a targeted stop needs an app-side session listing method that does not exist yet",
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
            authority_boundary: "validates bounded input, then rejects without a registry write because no standalone sender can apply and read back the requested mode for an agent-owned session; the Mac app's own capture resolution is settable and read-back-verified through `skybridge crossnet settings set remote_desktop.resolution <preset>`, which is host-scoped and takes effect at the next capture start rather than retuning a running stream",
            verification_gate: "standalone sender mode backend + authenticated applied readback receipt + real_device_p2p_remote_gate",
        },
        OperatorCapability {
            id: "remote_desktop.fps.set",
            status: OperatorCapabilityStatus::Unavailable,
            runtime_target: OperatorRuntimeTarget::NativeHeadlessStateDir,
            control_effect: OperatorControlEffect::UnavailableFailClosed,
            command: "unavailable/fail-closed: skybridge remote-desktop set-fps --session-id <id> --fps <value> [--json]",
            owner_module: "remote_desktop_commands + authenticated RuntimeSessionRecord evidence",
            authority_boundary: "validates the bounded fps contract, then rejects without a registry write because no standalone sender can apply and read back a frame rate for an agent-owned session; the Mac app's own capture frame rate is settable and read-back-verified through `skybridge crossnet settings set remote_desktop.target_fps <30|60|120>`, which is host-scoped and takes effect at the next capture start rather than retuning a running stream",
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
