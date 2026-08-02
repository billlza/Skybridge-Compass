use super::super::CheckCoverageEntry;
use super::super::source::{SearchableCheckSource, source_has_all};

pub(super) fn append_entries(
    source: &SearchableCheckSource,
    entries: &mut Vec<CheckCoverageEntry>,
) {
    entries.push(CheckCoverageEntry {
        id: "signaling_doctor_gate",
        domain: "control-plane",
        command: "skybridge doctor signaling",
        covered: source_has_all(
            source,
            &[
                "Signaling(SignalingDoctorArgs)",
                "Some(DoctorSubcommand::Signaling(signaling))",
                "doctor_signaling",
                "build_signaling_doctor_report",
            ],
        ),
        evidence:
            "signaling doctor parses, dispatches, and builds a structured control-plane report"
                .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "crossnet_settings_mutation_read_back_gate",
        domain: "control-plane",
        command: "skybridge crossnet settings set <id> <value> --json",
        covered: source_has_all(
            source,
            &[
                "CrossnetSettingsSubcommand::Set(set_args)",
                "crossnet_commands::settings_set",
                "SettingsMutationResult",
                "parse_setting_value",
                "settings_mutation_payload",
                "mac_runtime_mutation",
                "setting_runtime_apply_failed",
            ],
        ),
        evidence:
            "settings mutation is restricted to a typed allowlist that is a strict subset of the readable projection, refuses readable-but-immutable pqc ids with a distinct reason, and fails closed unless the Mac app reports a post-apply runtime read-back equal to the requested value"
                .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "media_lease_doctor_gate",
        domain: "control-plane",
        command: "skybridge doctor media-lease",
        covered: source_has_all(
            source,
            &[
                "MediaLease(MediaLeaseDoctorArgs)",
                "Some(DoctorSubcommand::MediaLease(media_lease))",
                "doctor_media_lease",
                "build_media_lease_doctor_report",
            ],
        ),
        evidence:
            "media lease doctor parses, dispatches, and builds a structured control-plane report"
                .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "operator_capability_contract_gate",
        domain: "control-plane",
        command: "skybridge capabilities --json",
        covered: source_has_all(
            source,
            &[
                "Capabilities(OutputOptions)",
                "operator_capabilities::print_operator_capabilities",
                "device.discovery.nearby",
                "device.discovery.active_scan",
                "file.transfer.send",
                "remote_desktop.start",
                "remote_desktop.resolution.set",
                "remote_desktop.fps.set",
                "operator_capability_contract_covers_requested_surface_without_fake_success",
            ],
        ),
        evidence: "operator capabilities are declared with explicit status, authority boundary, and verification gate before live mutating commands are added"
            .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "device_discovery_nearby_snapshot_gate",
        domain: "control-plane",
        command: "skybridge device discover --nearby --json",
        covered: source_has_all(
            source,
            &[
                "DeviceSubcommand::Discover(args)",
                "device_commands::device_discover",
                "load_nearby_discovery_snapshot_registry",
                "nearby_discovery_fails_closed_until_agent_snapshot_exists",
                "nearby_discovery_json_contract_fails_closed_without_fake_empty_results",
            ],
        ),
        evidence: "nearby discovery reads only agent-owned snapshots and fails closed when snapshots are missing or stale"
            .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "device_discovery_active_scan_live_gate",
        domain: "control-plane",
        command: "skybridge device discover --nearby --scan --json",
        covered: source_has_all(
            source,
            &[
                "device.discovery.active_scan",
                "pub(crate) scan: bool",
                "pub(crate) show_addresses: bool",
                "run_active_scan",
                "DEFAULT_ON_DEMAND_SCAN_SECONDS",
                "advertised_unverified",
                "device_discovery_permission_denied",
                "active_scan_json_hides_addresses_by_default_and_labels_explicit_disclosure",
                "active_scan_failure_json_distinguishes_permission_start_and_runtime_without_leaks",
                "active_scan_with_no_devices_is_success_not_a_failure_projection",
                "active_scan_persistence_keeps_ephemeral_address_out_of_registry",
                "active_nearby_discovery_dispatch_never_falls_back_to_generic_json_failure",
                "device_discover_active_scan_dispatch_shape_is_bounded_before_network_io",
                "operator_capability_contract_covers_requested_surface_without_fake_success",
            ],
        ),
        evidence: "active nearby scanning executes one bounded foreground mDNS pass, emits classified redacted JSON for permission/start/runtime failures, distinguishes an empty successful scan, persists only a locator-free candidate snapshot, hides addresses by default, and never authorizes connection"
            .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "file_transfer_contract_gate",
        domain: "control-plane",
        command: "skybridge file send <path> --to <peer> --session-id <id> --json",
        covered: source_has_all(
            source,
            &[
                "File(FileCommand)",
                "FileSubcommand::Send(args)",
                "FileSubcommand::Receive(args)",
                "file_commands::send",
                "enqueue_file_transfer_send_request_for_established_session",
                "load_file_transfer_request_registry",
                "request_registered",
                "pending_agent_observation",
                "file_commands::receive",
                "file_commands::history",
                "file_transfer_history_projects_pending_requests_without_private_details",
                "file_transfer_contract_stays_planned_without_path_or_peer_leakage",
                "file_transfer_json_contract_fails_closed_without_path_or_peer_leakage",
                "invalid file-transfer inputs must fail before writing pending requests",
                "file_transfer_request_rejected",
            ],
        ),
        evidence: "file transfer send persists an agent-owned pending request; the managed agent then performs the live chunked transfer and records success only on a SHA-256-verified receipt"
            .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "file_transfer_agent_observation_request_registry_gate",
        domain: "control-plane",
        command: "skybridge file history --json",
        covered: source_has_all(
            source,
            &[
                "observe_file_transfer_requests_for_established_session",
                "is_agent_observed",
                "transfer_completed",
                "file_transfer_registry_registers_pending_send_without_live_success",
                "file_transfer_json_contract_fails_closed_without_path_or_peer_leakage",
                "transfer_started",
                "receipt_verified",
                "receipt_sha256_match",
                "request.bytes_transferred == request.source.size_bytes",
                "file_send_wait_decision_requires_verified_matching_receipt",
                "file_send_timeout_json_does_not_claim_cancellation",
            ],
        ),
        evidence: "file send waits for an agent-owned terminal request and reports success only when byte count and SHA-256 receipt evidence all match; detach and timeout never claim transfer completion"
            .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "remote_desktop_capability_snapshot_registry_gate",
        domain: "control-plane",
        command: "skybridge remote-desktop resolutions --session-id <id> --json",
        covered: source_has_all(
            source,
            &[
                "RemoteDesktopSubcommand::Resolutions(args)",
                "load_remote_desktop_capability_snapshot_registry",
                "upsert_remote_desktop_capability_snapshot",
                "expires_at",
                "snapshot.is_fresh_at",
                "remote_desktop_capability_snapshot_legacy_payload_defaults_to_expired",
                "remote_desktop_registries_prune_oldest_entries_to_declared_limits",
                "remote_desktop_dispatch_reads_agent_owned_capability_snapshot",
                "remote_desktop_json_contract_is_machine_readable_without_live_success_claims",
            ],
        ),
        evidence: "remote desktop observed modes are read from agent-owned capability snapshots without claiming live apply"
            .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "remote_desktop_contract_gate",
        domain: "control-plane",
        command: "skybridge remote-desktop contract --json",
        covered: source_has_all(
            source,
            &[
                "RemoteDesktop(RemoteDesktopCommand)",
                "RemoteDesktopSubcommand::Contract(output)",
                "remote_desktop_commands::contract",
                "remote_desktop_contract_keeps_live_application_unobserved",
                "remote_desktop_dispatch_rejects_unverified_peer_without_registry_write",
                "remote_desktop_json_contract_is_machine_readable_without_live_success_claims",
            ],
        ),
        evidence: "remote desktop CLI contract is machine-readable while live start/stop/resolution/fps changes remain unavailable until standalone backend, authenticated apply/readback, and real-device gates exist"
            .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "remote_desktop_unavailable_fail_closed_gate",
        domain: "control-plane",
        command: "skybridge remote-desktop start --session-id <id> --json",
        covered: source_has_all(
            source,
            &[
                "RemoteDesktopSubcommand::Start(args)",
                "RemoteDesktopSubcommand::Stop(args)",
                "RemoteDesktopSubcommand::SetResolution(args)",
                "RemoteDesktopSubcommand::SetFps(args)",
                "remote_desktop_commands::start",
                "remote_desktop_commands::stop",
                "remote_desktop_commands::set_resolution",
                "remote_desktop_commands::set_fps",
                "classify_mutation_unavailability",
                "load_remote_desktop_request_registry",
                "peer_capability_unverified",
                "peer_capability_not_advertised",
                "standalone_remote_desktop_backend_unavailable",
                "request_registered: false",
                "applied: false",
                "remote_desktop_dispatch_rejects_unverified_peer_without_registry_write",
                "remote_desktop_dispatch_rejects_all_mutations_without_registry_writes",
                "remote_desktop_dispatch_rejects_invalid_start_without_registry_write",
                "remote_desktop_json_contract_is_machine_readable_without_live_success_claims",
            ],
        ),
        evidence: "remote desktop mutations verify authenticated peer capability evidence and then reject without persistence because the standalone runtime has no screen-capture/media/input backend or applied readback receipt"
            .to_owned(),
    });
}
