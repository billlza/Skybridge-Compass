mod discovery;
mod runtime;
mod state;

pub use discovery::{
    ACTIVE_SCAN_ID, ACTIVE_SCAN_SOURCE, ActiveScanError, ActiveScanFailureKind,
    ActiveScanFailureStage, ActiveScanResult, AdvertisedEndpointObservation,
    DEFAULT_ACTIVE_SCAN_TTL_SECONDS, DEFAULT_ON_DEMAND_SCAN_SECONDS, ResolvedNearbyPeer,
    SKYBRIDGE_SERVICE_TYPE, build_active_scan_snapshot, run_active_scan, scan_nearby_peers,
};
pub use runtime::{
    AgentPaths, AgentRuntimeOptions, agent_runtime_is_active, load_agent_runtime_lease,
    load_health_snapshot, resolve_paths, run_agent,
};
pub use state::{
    DeviceIdentityMaterial, ManagedSessionRegistrationCommit,
    ManagedSessionRegistrationJournalState, ManagedSessionRegistrationObservation,
    VerifiedManagedHandshakeReceipt, apply_transport_event, clear_auth_session,
    disconnect_managed_session, disconnect_managed_session_if_registration,
    disconnect_managed_session_if_runtime,
    enqueue_file_transfer_send_request_for_established_session,
    enqueue_remote_desktop_request_for_established_session, ensure_device_identity,
    ensure_rust_pqc_identity, ensure_rust_pqc_identity_for_algorithm, load_auth_session,
    load_file_transfer_request_registry, load_inbound_file_transfer_approval_registry,
    load_managed_session_controls, load_nearby_discovery_snapshot_registry,
    load_remote_desktop_capability_snapshot_registry, load_remote_desktop_request_registry,
    load_session_registry, observe_file_transfer_requests_for_established_session,
    observe_managed_session_registration, observe_remote_desktop_requests_for_established_session,
    refresh_auth_session_if_needed, register_managed_session, remove_managed_session_control,
    remove_session_runtime, request_inbound_file_transfer_decision, signing_binding,
    signing_signature, store_auth_session, update_enrollment_status, update_file_transfer_request,
    update_session_remote_peer, upsert_managed_session_control, upsert_nearby_discovery_snapshot,
    upsert_remote_desktop_capability_snapshot, upsert_session_runtime,
    verify_managed_handshake_receipt,
};
