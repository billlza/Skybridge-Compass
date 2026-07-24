mod discovery;
mod runtime;
mod state;

pub use discovery::{
    ACTIVE_SCAN_ID, ACTIVE_SCAN_SOURCE, DEFAULT_ACTIVE_SCAN_TTL_SECONDS, ResolvedNearbyPeer,
    SKYBRIDGE_SERVICE_TYPE, build_active_scan_snapshot, scan_nearby_peers,
};
pub use runtime::{
    AgentPaths, AgentRuntimeOptions, load_health_snapshot, resolve_paths, run_agent,
};
pub use state::{
    DeviceIdentityMaterial, apply_transport_event, clear_auth_session,
    enqueue_file_transfer_send_request_for_established_session,
    enqueue_remote_desktop_request_for_established_session, ensure_device_identity,
    ensure_rust_pqc_identity, ensure_rust_pqc_identity_for_algorithm, load_auth_session,
    load_file_transfer_request_registry, load_managed_session_controls,
    load_nearby_discovery_snapshot_registry, load_remote_desktop_capability_snapshot_registry,
    load_remote_desktop_request_registry, load_session_registry,
    observe_file_transfer_requests_for_established_session,
    observe_remote_desktop_requests_for_established_session, refresh_auth_session_if_needed,
    remove_managed_session_control, remove_session_runtime, signing_binding, signing_signature,
    store_auth_session, store_managed_session_controls, store_session_registry,
    update_enrollment_status, update_file_transfer_request, update_session_remote_peer,
    upsert_managed_session_control, upsert_nearby_discovery_snapshot,
    upsert_remote_desktop_capability_snapshot, upsert_session_runtime,
};
