use skybridge_core::ffi::skybridge_transport_binding_digest;
use skybridge_core::ffi::{
    skybridge_decode_frame_metadata, skybridge_decode_frame_payload, skybridge_encode_frame,
    skybridge_encode_sbp2_frame, skybridge_engine_check_liveness, skybridge_engine_clear_events,
    skybridge_engine_connect, skybridge_engine_decrypt_payload, skybridge_engine_disconnect,
    skybridge_engine_encrypt_payload, skybridge_engine_free, skybridge_engine_last_input_len,
    skybridge_engine_local_public_key, skybridge_engine_metrics, skybridge_engine_new,
    skybridge_engine_poll_events, skybridge_engine_reconnect, skybridge_engine_send_heartbeat,
    skybridge_engine_send_input, skybridge_engine_snapshot, skybridge_engine_state,
    skybridge_engine_throttle_stream, skybridge_map_channel,
    skybridge_parse_discovery_advertisement, skybridge_plan_connection,
    skybridge_plan_file_transfer_readiness, skybridge_project_signaling_lifecycle_state,
    skybridge_select_transport, skybridge_verify_webrtc_session_launch,
    SkybridgeAdapterBindingKind, SkybridgeBuffer, SkybridgeChannelKind, SkybridgeChannelMapping,
    SkybridgeConnectionPlan, SkybridgeCryptoProviderCapabilities, SkybridgeCryptoSuiteAuditCode,
    SkybridgeCryptoSuiteKind, SkybridgeCryptoSuitePolicy, SkybridgeDiscoveryAdvertisement,
    SkybridgeDiscoveryServiceKind, SkybridgeEngineSnapshot, SkybridgeErrorCode, SkybridgeEvent,
    SkybridgeEventKind, SkybridgeFileTransferAddressClass, SkybridgeFileTransferManifestFile,
    SkybridgeFileTransferManifestMode, SkybridgeFileTransferPlannerVerdict,
    SkybridgeFileTransferPortProvenance, SkybridgeFileTransferReadinessCode,
    SkybridgeFileTransferReadinessStatus, SkybridgeFileTransferRouteCandidate,
    SkybridgeFileTransferRouteSource, SkybridgeFlowRate, SkybridgeFrameMetadata,
    SkybridgeNetworkPath, SkybridgePeerCapabilities, SkybridgePeerPlatform,
    SkybridgeReliabilityKind, SkybridgeSessionConfig, SkybridgeSessionState,
    SkybridgeSignalingFailureClass, SkybridgeSignalingHealth, SkybridgeSignalingLifecycleEvent,
    SkybridgeSignalingLifecycleEventKind, SkybridgeSignalingLifecyclePhase,
    SkybridgeSignalingLifecycleState, SkybridgeSignalingReadiness, SkybridgeStreamMetrics,
    SkybridgeTrafficPaddingPlan, SkybridgeTransportAuditCode, SkybridgeTransportBindingDigest,
    SkybridgeTransportKind, SkybridgeTransportSelection, SkybridgeVerifiedWebRtcSessionLaunch,
    SKYBRIDGE_EVENT_CAPACITY,
};
use std::os::raw::c_char;
use std::ptr;
use std::time::{SystemTime, UNIX_EPOCH};

const DISCOVERY_FP: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const TRANSPORT_BINDING_DIGEST: [u8; 32] = [0x42; 32];
const ADAPTER_BINDING: &[u8] = b"external webrtc datachannel";
const LOCAL_ENDPOINT: &[u8] = b"windows.example:5443";
const REMOTE_ENDPOINT: &[u8] = b"mac.example:5443";
const SELECTED_CANDIDATE_PAIR: &[u8] = b"webrtc/dtls/sctp-selected";
const WEBRTC_CHANNEL_MAPPINGS: [SkybridgeChannelMapping; 5] = [
    SkybridgeChannelMapping {
        channel: SkybridgeChannelKind::Control,
        reliability: SkybridgeReliabilityKind::ReliableOrdered,
        max_retransmits: 0,
        binding_kind: SkybridgeAdapterBindingKind::WebRtcDataChannel,
        head_of_line_isolated: 1,
    },
    SkybridgeChannelMapping {
        channel: SkybridgeChannelKind::File,
        reliability: SkybridgeReliabilityKind::ReliableOrdered,
        max_retransmits: 0,
        binding_kind: SkybridgeAdapterBindingKind::WebRtcDataChannel,
        head_of_line_isolated: 1,
    },
    SkybridgeChannelMapping {
        channel: SkybridgeChannelKind::Clipboard,
        reliability: SkybridgeReliabilityKind::ReliableOrdered,
        max_retransmits: 0,
        binding_kind: SkybridgeAdapterBindingKind::WebRtcDataChannel,
        head_of_line_isolated: 1,
    },
    SkybridgeChannelMapping {
        channel: SkybridgeChannelKind::Telemetry,
        reliability: SkybridgeReliabilityKind::ReliableUnordered,
        max_retransmits: 0,
        binding_kind: SkybridgeAdapterBindingKind::WebRtcDataChannel,
        head_of_line_isolated: 1,
    },
    SkybridgeChannelMapping {
        channel: SkybridgeChannelKind::Realtime,
        reliability: SkybridgeReliabilityKind::PartialReliable,
        max_retransmits: 1,
        binding_kind: SkybridgeAdapterBindingKind::WebRtcDataChannel,
        head_of_line_isolated: 1,
    },
];

fn valid_session_config(client_id: &[u8], peer_public_key: &[u8]) -> SkybridgeSessionConfig {
    SkybridgeSessionConfig {
        client_id_ptr: client_id.as_ptr() as *const c_char,
        client_id_len: client_id.len(),
        heartbeat_interval_ms: 10,
        peer_public_key_ptr: peer_public_key.as_ptr(),
        peer_public_key_len: peer_public_key.len(),
        transport: SkybridgeTransportKind::WebRtcDataChannel,
        transport_audit: SkybridgeTransportAuditCode::WebRtcInterop,
        relay_required: 0,
        relay_allowed: 1,
        selected_suite: SkybridgeCryptoSuiteKind::XWingHybrid,
        selected_suite_wire_id: 0x0001,
        suite_audit: SkybridgeCryptoSuiteAuditCode::HybridPqcPreferred,
        sbp2_enabled: 1,
        sbp2_fixed_payload_len: 512,
        frame_header_len: 20,
        transport_binding_digest_ptr: TRANSPORT_BINDING_DIGEST.as_ptr(),
        transport_binding_digest_len: TRANSPORT_BINDING_DIGEST.len(),
        adapter_kind: SkybridgeTransportKind::WebRtcDataChannel,
        is_live_adapter_ready: 1,
        adapter_binding_ptr: ADAPTER_BINDING.as_ptr(),
        adapter_binding_len: ADAPTER_BINDING.len(),
        local_endpoint_ptr: LOCAL_ENDPOINT.as_ptr(),
        local_endpoint_len: LOCAL_ENDPOINT.len(),
        remote_endpoint_ptr: REMOTE_ENDPOINT.as_ptr(),
        remote_endpoint_len: REMOTE_ENDPOINT.len(),
        selected_candidate_pair_ptr: SELECTED_CANDIDATE_PAIR.as_ptr(),
        selected_candidate_pair_len: SELECTED_CANDIDATE_PAIR.len(),
        relay_id_ptr: ptr::null(),
        relay_id_len: 0,
        timestamp_window_ms: 10_000,
        channel_mappings_ptr: WEBRTC_CHANNEL_MAPPINGS.as_ptr(),
        channel_mapping_count: WEBRTC_CHANNEL_MAPPINGS.len(),
    }
}

fn empty_engine_snapshot() -> SkybridgeEngineSnapshot {
    SkybridgeEngineSnapshot {
        state: SkybridgeSessionState::Disconnected,
        last_heartbeat_ms: 0,
        has_last_heartbeat: false,
        has_secrets: false,
        has_transport_binding: false,
        transport_kind: SkybridgeTransportKind::Unsupported,
        adapter_kind: SkybridgeTransportKind::Unsupported,
        transport_binding_digest: [0; 32],
    }
}

fn empty_discovery_advertisement() -> SkybridgeDiscoveryAdvertisement {
    SkybridgeDiscoveryAdvertisement {
        service_kind: SkybridgeDiscoveryServiceKind::Unknown,
        device_id: [0; 64],
        device_id_len: 0,
        public_key_fingerprint: [0; 64],
        public_key_fingerprint_len: 0,
        platform: SkybridgePeerPlatform::Unknown,
        platform_label: [0; 32],
        platform_label_len: 0,
        capabilities: [0; 256],
        capabilities_len: 0,
        name: [0; 128],
        name_len: 0,
        protocol_version: [0; 32],
        protocol_version_len: 0,
        peer_capabilities: SkybridgePeerCapabilities {
            platform: SkybridgePeerPlatform::Unknown,
            supports_apple_native: 0,
            supports_msquic: 0,
            supports_skybridge_ice_msquic: 0,
            supports_webrtc_data_channel: 0,
            supports_tcp_fallback: 0,
            supports_relay: 0,
        },
    }
}

fn empty_verified_webrtc_session_launch() -> SkybridgeVerifiedWebRtcSessionLaunch {
    SkybridgeVerifiedWebRtcSessionLaunch {
        peer_device_id: [0; 64],
        peer_device_id_len: 0,
        peer_public_key_fingerprint: [0; 64],
        peer_public_key_fingerprint_len: 0,
        helper_name: [0; 128],
        helper_name_len: 0,
        adapter_binding: [0; 256],
        adapter_binding_len: 0,
        local_endpoint: [0; 256],
        local_endpoint_len: 0,
        remote_endpoint: [0; 256],
        remote_endpoint_len: 0,
        selected_candidate_pair: [0; 256],
        selected_candidate_pair_len: 0,
        relay_id: [0; 128],
        relay_id_len: 0,
        timestamp_window_ms: 0,
        captured_at_unix_ms: 0,
        proof_age_ms: 0,
        transport_secret_fingerprint: [0; 32],
        capability_digest: [0; 32],
        transport_binding_digest: [0; 32],
    }
}

fn empty_signaling_lifecycle_state() -> SkybridgeSignalingLifecycleState {
    SkybridgeSignalingLifecycleState {
        session_id: [0; 128],
        session_id_len: 0,
        backend: [0; 128],
        backend_len: 0,
        generation: 0,
        lifecycle_phase: SkybridgeSignalingLifecyclePhase::Idle,
        signaling_health: SkybridgeSignalingHealth::Healthy,
        readiness: SkybridgeSignalingReadiness::Idle,
        last_established_readiness: SkybridgeSignalingReadiness::Idle,
        failure_class: SkybridgeSignalingFailureClass::None,
        negotiated_suite: [0; 64],
        negotiated_suite_len: 0,
        reconnect_attempt_count: 0,
        business_sends_allowed: 0,
        can_report_connected: 0,
    }
}

fn fixed_bytes<const N: usize>(value: &str) -> ([u8; N], usize) {
    let bytes = value.as_bytes();
    assert!(bytes.len() <= N);
    let mut buffer = [0; N];
    buffer[..bytes.len()].copy_from_slice(bytes);
    (buffer, bytes.len())
}

fn signaling_event(
    kind: SkybridgeSignalingLifecycleEventKind,
    generation: u64,
) -> SkybridgeSignalingLifecycleEvent {
    let (session_id, session_id_len) = fixed_bytes("session-ffi");
    let (backend, backend_len) = fixed_bytes("wss-primary");
    SkybridgeSignalingLifecycleEvent {
        session_id,
        session_id_len,
        backend,
        backend_len,
        generation,
        kind,
        failure_class: SkybridgeSignalingFailureClass::None,
        negotiated_suite: [0; 64],
        negotiated_suite_len: 0,
    }
}

fn signaling_event_with_suite(
    kind: SkybridgeSignalingLifecycleEventKind,
    generation: u64,
    suite: &str,
) -> SkybridgeSignalingLifecycleEvent {
    let mut event = signaling_event(kind, generation);
    let (suite, suite_len) = fixed_bytes(suite);
    event.negotiated_suite = suite;
    event.negotiated_suite_len = suite_len;
    event
}

fn fixed_utf8<const N: usize>(buffer: &[u8; N], len: usize) -> &str {
    std::str::from_utf8(&buffer[..len]).expect("valid utf-8")
}

fn empty_file_transfer_verdict() -> SkybridgeFileTransferPlannerVerdict {
    SkybridgeFileTransferPlannerVerdict {
        status: SkybridgeFileTransferReadinessStatus::Blocked,
        code: SkybridgeFileTransferReadinessCode::MissingRoute,
        selected_address_class: SkybridgeFileTransferAddressClass::Invalid,
        selected_route_source: SkybridgeFileTransferRouteSource::Unknown,
        selected_peer_id: [0; 128],
        selected_peer_id_len: 0,
        selected_device_name: [0; 128],
        selected_device_name_len: 0,
        selected_host: [0; 128],
        selected_host_len: 0,
        selected_port: 0,
        selected_listener_generation: 0,
        has_selected_listener_generation: 0,
        manifest_version: 0,
        manifest_file_count: 0,
        manifest_total_bytes: 0,
        manifest_total_chunks: 0,
        manifest_chunk_size: 0,
        manifest_digest: [0; 32],
        has_manifest_digest: 0,
        file_channel_binding_kind: SkybridgeAdapterBindingKind::WebRtcDataChannel,
        has_file_channel: 0,
        file_channel_head_of_line_isolated: 0,
        frame_header_len: 0,
        audit: [0; 256],
        audit_len: 0,
    }
}

fn file_transfer_candidate(
    requested_host: &str,
    resolved_host: Option<&str>,
    service_type: Option<&str>,
    port: u16,
    provenance: SkybridgeFileTransferPortProvenance,
    listener_generation: u64,
) -> SkybridgeFileTransferRouteCandidate {
    let (peer_id, peer_id_len) = fixed_bytes("id:peer-1");
    let (device_name, device_name_len) = fixed_bytes("Desk Mac");
    let (requested_host, requested_host_len) = fixed_bytes(requested_host);
    let (resolved_host, resolved_host_len) =
        resolved_host.map(fixed_bytes).unwrap_or(([0; 128], 0));
    let (service_type, service_type_len) = service_type.map(fixed_bytes).unwrap_or(([0; 64], 0));

    SkybridgeFileTransferRouteCandidate {
        peer_id,
        peer_id_len,
        device_name,
        device_name_len,
        requested_host,
        requested_host_len,
        resolved_host,
        resolved_host_len,
        service_type,
        service_type_len,
        port,
        has_port: 1,
        route_source: SkybridgeFileTransferRouteSource::AuthenticatedSession,
        port_provenance: provenance,
        listener_generation,
        has_listener_generation: 1,
    }
}

fn file_transfer_manifest_file(
    display_name: &str,
    relative_path: &str,
    byte_len: u64,
    sha256_hex: &str,
) -> SkybridgeFileTransferManifestFile {
    let (display_name, display_name_len) = fixed_bytes(display_name);
    let (relative_path, relative_path_len) = fixed_bytes(relative_path);
    let (sha256_hex, sha256_hex_len) = fixed_bytes(sha256_hex);
    let (mime_type, mime_type_len) = fixed_bytes("application/octet-stream");

    SkybridgeFileTransferManifestFile {
        display_name,
        display_name_len,
        relative_path,
        relative_path_len,
        byte_len,
        sha256_hex,
        sha256_hex_len,
        mime_type,
        mime_type_len,
    }
}

fn empty_frame_metadata() -> SkybridgeFrameMetadata {
    SkybridgeFrameMetadata {
        channel: SkybridgeChannelKind::Control,
        sequence: 0,
        flags: 0,
        frame_header_len: 0,
        encoded_len: 0,
        payload_len: 0,
        decoded_payload_len: 0,
    }
}

fn webrtc_session_proof_json(captured_at_unix_ms: i64) -> String {
    format!(
        r#"{{
  "helperName": "ffi-session-helper",
  "peerDeviceId": "mac-ffi",
  "peerPublicKeyFingerprint": "{DISCOVERY_FP}",
  "dataChannelOpen": true,
  "sbf1EchoVerified": true,
  "sbf1FrameMagic": "SBF1",
  "adapterBinding": "verified webrtc datachannel helper",
  "localEndpoint": "windows.lan:5443",
  "remoteEndpoint": "mac.lan:5443",
  "selectedCandidatePair": "webrtc/dtls/sctp/ffi-selected",
  "transportSecretFingerprintHex": "6666666666666666666666666666666666666666666666666666666666666666",
  "capabilityDigestHex": "7777777777777777777777777777777777777777777777777777777777777777",
  "relayId": "relay-ffi",
  "timestampWindowMs": 15000,
  "capturedAtUnixMs": {captured_at_unix_ms}
}}"#
    )
}

#[test]
fn ffi_engine_lifecycle_runs() {
    let handle = skybridge_engine_new();
    assert!(!handle.is_null());

    let mut local_public = SkybridgeBuffer {
        data_ptr: ptr::null(),
        data_len: 0,
    };
    let local_key_result = unsafe { skybridge_engine_local_public_key(handle, &mut local_public) };
    assert_eq!(local_key_result, SkybridgeErrorCode::Ok);
    assert!(!local_public.data_ptr.is_null());
    assert!(local_public.data_len > 0);
    let local_key =
        unsafe { std::slice::from_raw_parts(local_public.data_ptr, local_public.data_len) };

    let client_id = b"ffi-client";
    let config = valid_session_config(client_id, local_key);

    let connect_result = skybridge_engine_connect(handle, config);
    assert_eq!(connect_result, SkybridgeErrorCode::Ok);
    let state = skybridge_engine_state(handle);
    assert_eq!(state, SkybridgeSessionState::Connected);

    let mut snapshot = empty_engine_snapshot();
    let snapshot_res = unsafe { skybridge_engine_snapshot(handle, &mut snapshot) };
    assert_eq!(snapshot_res, SkybridgeErrorCode::Ok);
    assert_eq!(snapshot.state, SkybridgeSessionState::Connected);
    assert!(snapshot.has_secrets);
    assert!(!snapshot.has_last_heartbeat);
    assert!(snapshot.has_transport_binding);
    assert_eq!(
        snapshot.transport_kind,
        SkybridgeTransportKind::WebRtcDataChannel
    );
    assert_eq!(
        snapshot.adapter_kind,
        SkybridgeTransportKind::WebRtcDataChannel
    );
    assert_eq!(snapshot.transport_binding_digest, TRANSPORT_BINDING_DIGEST);

    let mut event = SkybridgeEvent {
        kind: SkybridgeEventKind::None,
        data_ptr: ptr::null(),
        data_len: 0,
    };
    let poll_result = unsafe { skybridge_engine_poll_events(handle, &mut event) };
    assert_eq!(poll_result, SkybridgeErrorCode::Ok);
    assert_eq!(event.kind, SkybridgeEventKind::Connected);

    let heartbeat_result = skybridge_engine_send_heartbeat(handle);
    assert_eq!(heartbeat_result, SkybridgeErrorCode::Ok);
    let hb_event = unsafe { skybridge_engine_poll_events(handle, &mut event) };
    assert_eq!(hb_event, SkybridgeErrorCode::Ok);
    assert_eq!(event.kind, SkybridgeEventKind::HeartbeatAck);
    let snapshot_res = unsafe { skybridge_engine_snapshot(handle, &mut snapshot) };
    assert_eq!(snapshot_res, SkybridgeErrorCode::Ok);
    assert!(snapshot.has_last_heartbeat);

    let liveness_ok = skybridge_engine_check_liveness(handle, 2);
    assert_eq!(liveness_ok, SkybridgeErrorCode::Ok);

    std::thread::sleep(std::time::Duration::from_millis(30));
    let timeout_res = skybridge_engine_check_liveness(handle, 2);
    assert_eq!(timeout_res, SkybridgeErrorCode::InvalidState);
    let timeout_event = unsafe { skybridge_engine_poll_events(handle, &mut event) };
    assert_eq!(timeout_event, SkybridgeErrorCode::Ok);
    assert_eq!(event.kind, SkybridgeEventKind::HeartbeatTimeout);

    let flow = SkybridgeFlowRate {
        target_bitrate_bps: 1_000_000,
        max_latency_ms: 40,
    };
    let throttle_result = skybridge_engine_throttle_stream(handle, flow);
    assert_eq!(throttle_result, SkybridgeErrorCode::Ok);

    // Encrypt/decrypt roundtrip through the C ABI.
    let mut crypto_buffer = SkybridgeBuffer {
        data_ptr: ptr::null(),
        data_len: 0,
    };
    let plaintext = b"ffi-encrypt-payload";
    let encrypt_res = unsafe {
        skybridge_engine_encrypt_payload(
            handle,
            plaintext.as_ptr(),
            plaintext.len(),
            &mut crypto_buffer,
        )
    };
    assert_eq!(encrypt_res, SkybridgeErrorCode::Ok);
    assert!(!crypto_buffer.data_ptr.is_null());
    assert!(crypto_buffer.data_len > 0);
    let ciphertext =
        unsafe { std::slice::from_raw_parts(crypto_buffer.data_ptr, crypto_buffer.data_len) };
    assert_ne!(ciphertext, plaintext);

    let decrypt_res = unsafe {
        skybridge_engine_decrypt_payload(
            handle,
            crypto_buffer.data_ptr,
            crypto_buffer.data_len,
            &mut crypto_buffer,
        )
    };
    assert_eq!(decrypt_res, SkybridgeErrorCode::Ok);
    let decrypted =
        unsafe { std::slice::from_raw_parts(crypto_buffer.data_ptr, crypto_buffer.data_len) };
    assert_eq!(decrypted, plaintext);

    let payload = [1u8, 2, 3, 4];
    let input_result =
        unsafe { skybridge_engine_send_input(handle, payload.as_ptr(), payload.len()) };
    assert_eq!(input_result, SkybridgeErrorCode::Ok);
    let input_event = unsafe { skybridge_engine_poll_events(handle, &mut event) };
    assert_eq!(input_event, SkybridgeErrorCode::Ok);
    assert_eq!(event.kind, SkybridgeEventKind::InputReceived);
    assert_eq!(event.data_len, payload.len());
    let data = unsafe { std::slice::from_raw_parts(event.data_ptr, event.data_len) };
    assert_eq!(data, payload);
    let recorded_len = skybridge_engine_last_input_len(handle);
    assert_eq!(recorded_len, payload.len());

    let mut metrics = SkybridgeStreamMetrics {
        bitrate_bps: 0,
        packet_loss_ppm: 0,
    };
    let metrics_result = unsafe { skybridge_engine_metrics(handle, &mut metrics) };
    assert_eq!(metrics_result, SkybridgeErrorCode::Ok);
    assert_eq!(metrics.bitrate_bps, flow.target_bitrate_bps);

    let reconnect_result = skybridge_engine_reconnect(handle);
    assert_eq!(reconnect_result, SkybridgeErrorCode::Ok);
    let reconnect_event = unsafe { skybridge_engine_poll_events(handle, &mut event) };
    assert_eq!(reconnect_event, SkybridgeErrorCode::Ok);
    assert_eq!(event.kind, SkybridgeEventKind::Reconnected);

    let shutdown_result = skybridge_engine_disconnect(handle);
    assert_eq!(shutdown_result, SkybridgeErrorCode::Ok);
    let disconnect_event = unsafe { skybridge_engine_poll_events(handle, &mut event) };
    assert_eq!(disconnect_event, SkybridgeErrorCode::Ok);
    assert_eq!(event.kind, SkybridgeEventKind::Disconnected);
    let final_state = skybridge_engine_state(handle);
    assert_eq!(final_state, SkybridgeSessionState::Disconnected);
    let snapshot_res = unsafe { skybridge_engine_snapshot(handle, &mut snapshot) };
    assert_eq!(snapshot_res, SkybridgeErrorCode::Ok);
    assert_eq!(snapshot.state, SkybridgeSessionState::Disconnected);
    assert!(!snapshot.has_secrets);
    assert!(!snapshot.has_last_heartbeat);

    unsafe { skybridge_engine_free(handle) };
}

#[test]
fn ffi_connect_rejects_invalid_config() {
    let handle = skybridge_engine_new();
    assert!(!handle.is_null());

    let mut local_public = SkybridgeBuffer {
        data_ptr: ptr::null(),
        data_len: 0,
    };
    unsafe { skybridge_engine_local_public_key(handle, &mut local_public) };
    let local_key =
        unsafe { std::slice::from_raw_parts(local_public.data_ptr, local_public.data_len) };

    let client_id = b" ";
    let mut config = valid_session_config(client_id, local_key);
    config.heartbeat_interval_ms = 0;

    let connect_result = skybridge_engine_connect(handle, config);
    assert_eq!(connect_result, SkybridgeErrorCode::InvalidInput);
    assert_eq!(
        skybridge_engine_state(handle),
        SkybridgeSessionState::Disconnected
    );

    unsafe { skybridge_engine_free(handle) };
}

#[test]
fn ffi_connect_rejects_missing_transport_binding_digest() {
    let handle = skybridge_engine_new();
    assert!(!handle.is_null());

    let mut local_public = SkybridgeBuffer {
        data_ptr: ptr::null(),
        data_len: 0,
    };
    unsafe { skybridge_engine_local_public_key(handle, &mut local_public) };
    let local_key =
        unsafe { std::slice::from_raw_parts(local_public.data_ptr, local_public.data_len) };
    let client_id = b"missing-digest";
    let mut config = valid_session_config(client_id, local_key);
    config.transport_binding_digest_len = 0;

    assert_eq!(
        skybridge_engine_connect(handle, config),
        SkybridgeErrorCode::InvalidInput
    );
    assert_eq!(
        skybridge_engine_state(handle),
        SkybridgeSessionState::Disconnected
    );

    unsafe { skybridge_engine_free(handle) };
}

#[test]
fn ffi_connect_rejects_preflight_only_adapter() {
    let handle = skybridge_engine_new();
    assert!(!handle.is_null());

    let mut local_public = SkybridgeBuffer {
        data_ptr: ptr::null(),
        data_len: 0,
    };
    unsafe { skybridge_engine_local_public_key(handle, &mut local_public) };
    let local_key =
        unsafe { std::slice::from_raw_parts(local_public.data_ptr, local_public.data_len) };
    let client_id = b"preflight-only";
    let mut config = valid_session_config(client_id, local_key);
    config.is_live_adapter_ready = 0;

    assert_eq!(
        skybridge_engine_connect(handle, config),
        SkybridgeErrorCode::InvalidInput
    );
    assert_eq!(
        skybridge_engine_state(handle),
        SkybridgeSessionState::Disconnected
    );

    unsafe { skybridge_engine_free(handle) };
}

#[test]
fn ffi_connect_rejects_suite_wire_mismatch() {
    let handle = skybridge_engine_new();
    assert!(!handle.is_null());

    let mut local_public = SkybridgeBuffer {
        data_ptr: ptr::null(),
        data_len: 0,
    };
    unsafe { skybridge_engine_local_public_key(handle, &mut local_public) };
    let local_key =
        unsafe { std::slice::from_raw_parts(local_public.data_ptr, local_public.data_len) };
    let client_id = b"suite-mismatch";
    let mut config = valid_session_config(client_id, local_key);
    config.selected_suite_wire_id = 0x1001;

    assert_eq!(
        skybridge_engine_connect(handle, config),
        SkybridgeErrorCode::InvalidInput
    );
    assert_eq!(
        skybridge_engine_state(handle),
        SkybridgeSessionState::Disconnected
    );

    unsafe { skybridge_engine_free(handle) };
}

#[test]
fn ffi_connect_rejects_missing_or_duplicate_channel_mappings() {
    let handle = skybridge_engine_new();
    assert!(!handle.is_null());

    let mut local_public = SkybridgeBuffer {
        data_ptr: ptr::null(),
        data_len: 0,
    };
    unsafe { skybridge_engine_local_public_key(handle, &mut local_public) };
    let local_key =
        unsafe { std::slice::from_raw_parts(local_public.data_ptr, local_public.data_len) };

    let client_id = b"missing-channels";
    let mut config = valid_session_config(client_id, local_key);
    config.channel_mapping_count = 0;
    assert_eq!(
        skybridge_engine_connect(handle, config),
        SkybridgeErrorCode::InvalidInput
    );

    let client_id = b"duplicate-channels";
    let mut duplicate_mappings = WEBRTC_CHANNEL_MAPPINGS;
    duplicate_mappings[4].channel = SkybridgeChannelKind::Control;
    let mut config = valid_session_config(client_id, local_key);
    config.channel_mappings_ptr = duplicate_mappings.as_ptr();
    assert_eq!(
        skybridge_engine_connect(handle, config),
        SkybridgeErrorCode::InvalidInput
    );
    assert_eq!(
        skybridge_engine_state(handle),
        SkybridgeSessionState::Disconnected
    );

    unsafe { skybridge_engine_free(handle) };
}

#[test]
fn ffi_event_queue_is_bounded_and_clearable() {
    let handle = skybridge_engine_new();
    assert!(!handle.is_null());

    // Connect once to unlock event emission.
    let mut local_public = SkybridgeBuffer {
        data_ptr: ptr::null(),
        data_len: 0,
    };
    unsafe { skybridge_engine_local_public_key(handle, &mut local_public) };
    let local_key =
        unsafe { std::slice::from_raw_parts(local_public.data_ptr, local_public.data_len) };
    let client_id = b"bounded";
    let mut config = valid_session_config(client_id, local_key);
    config.heartbeat_interval_ms = 5;
    assert_eq!(
        skybridge_engine_connect(handle, config),
        SkybridgeErrorCode::Ok
    );

    // Saturate the event queue with many inputs; ensure capacity is enforced.
    for _ in 0..(SKYBRIDGE_EVENT_CAPACITY + 50) {
        let payload = [1u8, 2, 3];
        let result =
            unsafe { skybridge_engine_send_input(handle, payload.as_ptr(), payload.len()) };
        assert_eq!(result, SkybridgeErrorCode::Ok);
    }

    let mut polled = 0usize;
    let mut event = SkybridgeEvent {
        kind: SkybridgeEventKind::None,
        data_ptr: ptr::null(),
        data_len: 0,
    };
    loop {
        let res = unsafe { skybridge_engine_poll_events(handle, &mut event) };
        assert_eq!(res, SkybridgeErrorCode::Ok);
        if event.kind == SkybridgeEventKind::None {
            break;
        }
        polled += 1;
    }

    assert!(polled <= SKYBRIDGE_EVENT_CAPACITY);

    // Clearing should drop any leftover events and payload references.
    assert_eq!(
        skybridge_engine_clear_events(handle),
        SkybridgeErrorCode::Ok
    );
    let clear_res = unsafe { skybridge_engine_poll_events(handle, &mut event) };
    assert_eq!(clear_res, SkybridgeErrorCode::Ok);
    assert_eq!(event.kind, SkybridgeEventKind::None);
    assert!(event.data_ptr.is_null());

    unsafe { skybridge_engine_free(handle) };
}

#[test]
fn ffi_connect_rejects_channel_binding_transport_mismatch() {
    let handle = skybridge_engine_new();
    assert!(!handle.is_null());

    let mut local_public = SkybridgeBuffer {
        data_ptr: ptr::null(),
        data_len: 0,
    };
    unsafe { skybridge_engine_local_public_key(handle, &mut local_public) };
    let local_key =
        unsafe { std::slice::from_raw_parts(local_public.data_ptr, local_public.data_len) };

    let client_id = b"binding-transport-mismatch";
    let mut mismatched_mappings = WEBRTC_CHANNEL_MAPPINGS;
    mismatched_mappings[0].binding_kind = SkybridgeAdapterBindingKind::AppleStream;
    let mut config = valid_session_config(client_id, local_key);
    config.channel_mappings_ptr = mismatched_mappings.as_ptr();

    assert_eq!(
        skybridge_engine_connect(handle, config),
        SkybridgeErrorCode::InvalidInput
    );
    assert_eq!(
        skybridge_engine_state(handle),
        SkybridgeSessionState::Disconnected
    );

    unsafe { skybridge_engine_free(handle) };
}

#[test]
fn ffi_transport_selector_exports_adr_defaults() {
    let windows = SkybridgePeerCapabilities {
        platform: SkybridgePeerPlatform::Windows,
        supports_apple_native: 0,
        supports_msquic: 1,
        supports_skybridge_ice_msquic: 0,
        supports_webrtc_data_channel: 1,
        supports_tcp_fallback: 1,
        supports_relay: 1,
    };
    let apple = SkybridgePeerCapabilities {
        platform: SkybridgePeerPlatform::Apple,
        supports_apple_native: 1,
        supports_msquic: 0,
        supports_skybridge_ice_msquic: 0,
        supports_webrtc_data_channel: 1,
        supports_tcp_fallback: 1,
        supports_relay: 1,
    };
    let same_lan = SkybridgeNetworkPath {
        same_lan: 1,
        cross_nat: 0,
    };
    let cross_nat = SkybridgeNetworkPath {
        same_lan: 0,
        cross_nat: 1,
    };
    let mut selection = SkybridgeTransportSelection {
        kind: SkybridgeTransportKind::Unsupported,
        audit_code: SkybridgeTransportAuditCode::UnsupportedNoCompatibleTransport,
        priority: 0,
        relay_required: 0,
        relay_allowed: 0,
    };

    let result = unsafe { skybridge_select_transport(windows, windows, same_lan, &mut selection) };
    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(selection.kind, SkybridgeTransportKind::WindowsNativeMsQuic);
    assert_eq!(
        selection.audit_code,
        SkybridgeTransportAuditCode::WindowsNativeMsQuicSameLan
    );
    assert_eq!(selection.priority, 100);
    assert_eq!(selection.relay_allowed, 0);

    let result = unsafe { skybridge_select_transport(windows, apple, cross_nat, &mut selection) };
    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(selection.kind, SkybridgeTransportKind::WebRtcDataChannel);
    assert_eq!(
        selection.audit_code,
        SkybridgeTransportAuditCode::WebRtcInterop
    );
    assert_eq!(selection.priority, 70);
    assert_eq!(selection.relay_allowed, 1);
    assert_eq!(selection.relay_required, 0);

    let result = unsafe { skybridge_select_transport(apple, apple, same_lan, &mut selection) };
    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(selection.kind, SkybridgeTransportKind::AppleNative);
    assert_eq!(
        selection.audit_code,
        SkybridgeTransportAuditCode::AppleNativeDefault
    );

    let null_result =
        unsafe { skybridge_select_transport(windows, apple, cross_nat, ptr::null_mut()) };
    assert_eq!(null_result, SkybridgeErrorCode::InvalidInput);
}

#[test]
fn ffi_transport_binding_digest_exports_core_transcript() {
    let local_endpoint = b"10.0.0.1:443";
    let remote_endpoint = b"10.0.0.2:443";
    let candidate_pair = b"host/udp";
    let secret_fingerprint = b"secret-fingerprint";
    let capability_digest = b"capability-digest";
    let mut digest = SkybridgeTransportBindingDigest { digest: [0; 32] };

    let result = unsafe {
        skybridge_transport_binding_digest(
            SkybridgeTransportKind::WebRtcDataChannel,
            local_endpoint.as_ptr(),
            local_endpoint.len(),
            remote_endpoint.as_ptr(),
            remote_endpoint.len(),
            candidate_pair.as_ptr(),
            candidate_pair.len(),
            secret_fingerprint.as_ptr(),
            secret_fingerprint.len(),
            ptr::null(),
            0,
            10_000,
            capability_digest.as_ptr(),
            capability_digest.len(),
            &mut digest,
        )
    };

    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_ne!(digest.digest, [0; 32]);

    let relay_id = b"turn-a";
    let mut relay_digest = SkybridgeTransportBindingDigest { digest: [0; 32] };
    let relay_result = unsafe {
        skybridge_transport_binding_digest(
            SkybridgeTransportKind::Relay,
            local_endpoint.as_ptr(),
            local_endpoint.len(),
            remote_endpoint.as_ptr(),
            remote_endpoint.len(),
            candidate_pair.as_ptr(),
            candidate_pair.len(),
            secret_fingerprint.as_ptr(),
            secret_fingerprint.len(),
            relay_id.as_ptr(),
            relay_id.len(),
            10_000,
            capability_digest.as_ptr(),
            capability_digest.len(),
            &mut relay_digest,
        )
    };

    assert_eq!(relay_result, SkybridgeErrorCode::Ok);
    assert_ne!(digest.digest, relay_digest.digest);

    let unsupported_result = unsafe {
        skybridge_transport_binding_digest(
            SkybridgeTransportKind::Unsupported,
            local_endpoint.as_ptr(),
            local_endpoint.len(),
            remote_endpoint.as_ptr(),
            remote_endpoint.len(),
            candidate_pair.as_ptr(),
            candidate_pair.len(),
            secret_fingerprint.as_ptr(),
            secret_fingerprint.len(),
            ptr::null(),
            0,
            10_000,
            capability_digest.as_ptr(),
            capability_digest.len(),
            &mut digest,
        )
    };
    assert_eq!(unsupported_result, SkybridgeErrorCode::InvalidInput);

    let null_out = unsafe {
        skybridge_transport_binding_digest(
            SkybridgeTransportKind::WebRtcDataChannel,
            local_endpoint.as_ptr(),
            local_endpoint.len(),
            remote_endpoint.as_ptr(),
            remote_endpoint.len(),
            candidate_pair.as_ptr(),
            candidate_pair.len(),
            secret_fingerprint.as_ptr(),
            secret_fingerprint.len(),
            ptr::null(),
            0,
            10_000,
            capability_digest.as_ptr(),
            capability_digest.len(),
            ptr::null_mut(),
        )
    };
    assert_eq!(null_out, SkybridgeErrorCode::InvalidInput);
}

#[test]
fn ffi_webrtc_session_launch_verifies_proof_and_binding_digest() {
    let captured_at_unix_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock after unix epoch")
        .as_millis() as i64;
    let proof = webrtc_session_proof_json(captured_at_unix_ms);
    let expected_device_id = b"mac-ffi";
    let expected_fingerprint = DISCOVERY_FP.as_bytes();
    let mut launch = empty_verified_webrtc_session_launch();

    let result = unsafe {
        skybridge_verify_webrtc_session_launch(
            proof.as_ptr(),
            proof.len(),
            expected_device_id.as_ptr(),
            expected_device_id.len(),
            expected_fingerprint.as_ptr(),
            expected_fingerprint.len(),
            SkybridgeTransportKind::WebRtcDataChannel,
            SkybridgeTransportAuditCode::WebRtcInterop,
            60_000,
            &mut launch,
        )
    };

    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(
        fixed_utf8(&launch.peer_device_id, launch.peer_device_id_len),
        "mac-ffi"
    );
    assert_eq!(
        fixed_utf8(
            &launch.peer_public_key_fingerprint,
            launch.peer_public_key_fingerprint_len
        ),
        DISCOVERY_FP
    );
    assert_eq!(
        fixed_utf8(&launch.helper_name, launch.helper_name_len),
        "ffi-session-helper"
    );
    assert_eq!(launch.transport_secret_fingerprint, [0x66; 32]);
    assert_eq!(launch.capability_digest, [0x77; 32]);
    assert_eq!(launch.timestamp_window_ms, 15_000);
    assert!(launch.proof_age_ms <= 60_000);

    let local_endpoint = b"windows.lan:5443";
    let remote_endpoint = b"mac.lan:5443";
    let candidate_pair = b"webrtc/dtls/sctp/ffi-selected";
    let secret_fingerprint = [0x66u8; 32];
    let capability_digest = [0x77u8; 32];
    let relay_id = b"relay-ffi";
    let mut expected_digest = SkybridgeTransportBindingDigest { digest: [0; 32] };
    let digest_result = unsafe {
        skybridge_transport_binding_digest(
            SkybridgeTransportKind::WebRtcDataChannel,
            local_endpoint.as_ptr(),
            local_endpoint.len(),
            remote_endpoint.as_ptr(),
            remote_endpoint.len(),
            candidate_pair.as_ptr(),
            candidate_pair.len(),
            secret_fingerprint.as_ptr(),
            secret_fingerprint.len(),
            relay_id.as_ptr(),
            relay_id.len(),
            15_000,
            capability_digest.as_ptr(),
            capability_digest.len(),
            &mut expected_digest,
        )
    };

    assert_eq!(digest_result, SkybridgeErrorCode::Ok);
    assert_eq!(launch.transport_binding_digest, expected_digest.digest);

    let apple_native_result = unsafe {
        skybridge_verify_webrtc_session_launch(
            proof.as_ptr(),
            proof.len(),
            expected_device_id.as_ptr(),
            expected_device_id.len(),
            expected_fingerprint.as_ptr(),
            expected_fingerprint.len(),
            SkybridgeTransportKind::AppleNative,
            SkybridgeTransportAuditCode::AppleNativeDefault,
            60_000,
            &mut launch,
        )
    };
    assert_eq!(
        apple_native_result,
        SkybridgeErrorCode::UnsupportedTransport
    );
}

#[test]
fn ffi_webrtc_session_launch_rejects_placeholder_endpoint() {
    let captured_at_unix_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock after unix epoch")
        .as_millis() as i64;
    let proof = webrtc_session_proof_json(captured_at_unix_ms).replace(
        r#""localEndpoint": "windows.lan:5443""#,
        r#""localEndpoint": "127.0.0.1:0""#,
    );
    let expected_device_id = b"mac-ffi";
    let expected_fingerprint = DISCOVERY_FP.as_bytes();
    let mut launch = empty_verified_webrtc_session_launch();

    let result = unsafe {
        skybridge_verify_webrtc_session_launch(
            proof.as_ptr(),
            proof.len(),
            expected_device_id.as_ptr(),
            expected_device_id.len(),
            expected_fingerprint.as_ptr(),
            expected_fingerprint.len(),
            SkybridgeTransportKind::WebRtcDataChannel,
            SkybridgeTransportAuditCode::WebRtcInterop,
            60_000,
            &mut launch,
        )
    };

    assert_eq!(result, SkybridgeErrorCode::InvalidInput);
}

#[test]
fn ffi_signaling_lifecycle_keeps_socket_open_distinct_from_connected() {
    let mut state = empty_signaling_lifecycle_state();
    let socket_event = signaling_event(SkybridgeSignalingLifecycleEventKind::SocketOpen, 1);

    let result =
        unsafe { skybridge_project_signaling_lifecycle_state(state, socket_event, &mut state) };

    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(
        state.lifecycle_phase,
        SkybridgeSignalingLifecyclePhase::SocketOpen
    );
    assert_eq!(state.readiness, SkybridgeSignalingReadiness::Idle);
    assert_eq!(state.business_sends_allowed, 0);
    assert_eq!(state.can_report_connected, 0);

    let bound_event = signaling_event(SkybridgeSignalingLifecycleEventKind::Bound, 1);
    let result =
        unsafe { skybridge_project_signaling_lifecycle_state(state, bound_event, &mut state) };

    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(
        state.lifecycle_phase,
        SkybridgeSignalingLifecyclePhase::Bound
    );
    assert_eq!(state.business_sends_allowed, 1);
    assert_eq!(state.can_report_connected, 0);
}

#[test]
fn ffi_signaling_lifecycle_ignores_stale_generation_events() {
    let mut state = empty_signaling_lifecycle_state();
    let bound = signaling_event(SkybridgeSignalingLifecycleEventKind::Bound, 3);
    let result = unsafe { skybridge_project_signaling_lifecycle_state(state, bound, &mut state) };
    assert_eq!(result, SkybridgeErrorCode::Ok);

    let stale_socket_open = signaling_event(SkybridgeSignalingLifecycleEventKind::SocketOpen, 2);
    let result = unsafe {
        skybridge_project_signaling_lifecycle_state(state, stale_socket_open, &mut state)
    };

    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(
        state.lifecycle_phase,
        SkybridgeSignalingLifecyclePhase::Bound
    );
    assert_eq!(state.generation, 3);
}

#[test]
fn ffi_signaling_lifecycle_rejects_readiness_before_bound() {
    let mut state = empty_signaling_lifecycle_state();
    let ready = signaling_event(SkybridgeSignalingLifecycleEventKind::TransportReady, 1);
    let result = unsafe { skybridge_project_signaling_lifecycle_state(state, ready, &mut state) };
    assert_eq!(result, SkybridgeErrorCode::InvalidInput);
    assert_eq!(state.can_report_connected, 0);
}

#[test]
fn ffi_signaling_lifecycle_preserves_audit_after_post_handshake_failure() {
    let mut state = empty_signaling_lifecycle_state();
    let bound = signaling_event(SkybridgeSignalingLifecycleEventKind::Bound, 1);
    let result = unsafe { skybridge_project_signaling_lifecycle_state(state, bound, &mut state) };
    assert_eq!(result, SkybridgeErrorCode::Ok);

    let ready = signaling_event(SkybridgeSignalingLifecycleEventKind::TransportReady, 1);
    let result = unsafe { skybridge_project_signaling_lifecycle_state(state, ready, &mut state) };
    assert_eq!(result, SkybridgeErrorCode::Ok);

    let handshake = signaling_event_with_suite(
        SkybridgeSignalingLifecycleEventKind::HandshakeComplete,
        1,
        "xwing-hybrid",
    );
    let result =
        unsafe { skybridge_project_signaling_lifecycle_state(state, handshake, &mut state) };
    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(
        state.readiness,
        SkybridgeSignalingReadiness::HandshakeComplete
    );
    assert_eq!(state.can_report_connected, 1);

    let mut failed = signaling_event(SkybridgeSignalingLifecycleEventKind::Failed, 1);
    failed.failure_class = SkybridgeSignalingFailureClass::TokenExpired;
    let result = unsafe { skybridge_project_signaling_lifecycle_state(state, failed, &mut state) };

    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(
        state.lifecycle_phase,
        SkybridgeSignalingLifecyclePhase::Failed
    );
    assert_eq!(
        state.signaling_health,
        SkybridgeSignalingHealth::DegradedFatal
    );
    assert_eq!(state.readiness, SkybridgeSignalingReadiness::Idle);
    assert_eq!(
        state.last_established_readiness,
        SkybridgeSignalingReadiness::HandshakeComplete
    );
    assert_eq!(state.can_report_connected, 0);
}

#[test]
fn ffi_signaling_lifecycle_rejects_missing_handshake_suite() {
    let mut state = empty_signaling_lifecycle_state();
    let handshake = signaling_event(SkybridgeSignalingLifecycleEventKind::HandshakeComplete, 1);

    let result =
        unsafe { skybridge_project_signaling_lifecycle_state(state, handshake, &mut state) };

    assert_eq!(result, SkybridgeErrorCode::InvalidInput);
}

#[test]
fn ffi_file_transfer_readiness_exports_ready_route_and_manifest_plan() {
    const HASH: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    let route = [file_transfer_candidate(
        "192.168.31.20",
        None,
        None,
        8080,
        SkybridgeFileTransferPortProvenance::ListenerTruth,
        7,
    )];
    let files = [file_transfer_manifest_file(
        "a.bin",
        "folder/a.bin",
        1_500_000,
        HASH,
    )];
    let target = b"peer-1";
    let mut verdict = empty_file_transfer_verdict();

    let result = unsafe {
        skybridge_plan_file_transfer_readiness(
            route.as_ptr(),
            route.len(),
            target.as_ptr(),
            target.len(),
            7,
            1,
            SkybridgeFileTransferManifestMode::Transfer,
            files.as_ptr(),
            files.len(),
            1024 * 1024,
            WEBRTC_CHANNEL_MAPPINGS.as_ptr(),
            WEBRTC_CHANNEL_MAPPINGS.len(),
            &mut verdict,
        )
    };

    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(verdict.status, SkybridgeFileTransferReadinessStatus::Ready);
    assert_eq!(verdict.code, SkybridgeFileTransferReadinessCode::Ok);
    assert_eq!(
        verdict.selected_address_class,
        SkybridgeFileTransferAddressClass::LanDirect
    );
    assert_eq!(
        fixed_utf8(&verdict.selected_peer_id, verdict.selected_peer_id_len),
        "peer-1"
    );
    assert_eq!(
        fixed_utf8(&verdict.selected_host, verdict.selected_host_len),
        "192.168.31.20"
    );
    assert_eq!(verdict.selected_port, 8080);
    assert_eq!(verdict.has_selected_listener_generation, 1);
    assert_eq!(verdict.selected_listener_generation, 7);
    assert_eq!(verdict.manifest_version, 1);
    assert_eq!(verdict.manifest_file_count, 1);
    assert_eq!(verdict.manifest_total_bytes, 1_500_000);
    assert_eq!(verdict.manifest_total_chunks, 2);
    assert_eq!(verdict.manifest_chunk_size, 1024 * 1024);
    assert_eq!(verdict.has_manifest_digest, 1);
    assert_ne!(verdict.manifest_digest, [0; 32]);
    assert_eq!(verdict.has_file_channel, 1);
    assert_eq!(
        verdict.file_channel_binding_kind,
        SkybridgeAdapterBindingKind::WebRtcDataChannel
    );
    assert_eq!(verdict.file_channel_head_of_line_isolated, 1);
    assert_eq!(verdict.frame_header_len, 20);
}

#[test]
fn ffi_file_transfer_readiness_keeps_intent_only_distinct_from_ready_manifest() {
    let mut verdict = empty_file_transfer_verdict();

    let result = unsafe {
        skybridge_plan_file_transfer_readiness(
            ptr::null(),
            0,
            ptr::null(),
            0,
            0,
            0,
            SkybridgeFileTransferManifestMode::IntentOnly,
            ptr::null(),
            0,
            1024 * 1024,
            WEBRTC_CHANNEL_MAPPINGS.as_ptr(),
            WEBRTC_CHANNEL_MAPPINGS.len(),
            &mut verdict,
        )
    };

    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(
        verdict.status,
        SkybridgeFileTransferReadinessStatus::IntentOnly
    );
    assert_eq!(
        verdict.code,
        SkybridgeFileTransferReadinessCode::IntentOnlyNoFiles
    );
    assert_eq!(verdict.has_manifest_digest, 0);
    assert_eq!(verdict.manifest_file_count, 0);
    assert_eq!(verdict.selected_host_len, 0);
    assert_eq!(verdict.has_file_channel, 1);
}

#[test]
fn ffi_file_transfer_readiness_rejects_link_local_and_stale_ports() {
    const HASH: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    let link_local = [file_transfer_candidate(
        "fe80::1%en0",
        None,
        None,
        8080,
        SkybridgeFileTransferPortProvenance::ListenerTruth,
        7,
    )];
    let files = [file_transfer_manifest_file("a.bin", "a.bin", 1, HASH)];
    let mut verdict = empty_file_transfer_verdict();

    let result = unsafe {
        skybridge_plan_file_transfer_readiness(
            link_local.as_ptr(),
            link_local.len(),
            ptr::null(),
            0,
            7,
            1,
            SkybridgeFileTransferManifestMode::Transfer,
            files.as_ptr(),
            files.len(),
            1024 * 1024,
            WEBRTC_CHANNEL_MAPPINGS.as_ptr(),
            WEBRTC_CHANNEL_MAPPINGS.len(),
            &mut verdict,
        )
    };

    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(
        verdict.status,
        SkybridgeFileTransferReadinessStatus::Blocked
    );
    assert_eq!(
        verdict.code,
        SkybridgeFileTransferReadinessCode::RequestedPeerToPeerRoute
    );
    assert_eq!(verdict.has_manifest_digest, 1);

    let stale = [file_transfer_candidate(
        "192.168.31.20",
        None,
        None,
        49444,
        SkybridgeFileTransferPortProvenance::RegistryState,
        7,
    )];
    let result = unsafe {
        skybridge_plan_file_transfer_readiness(
            stale.as_ptr(),
            stale.len(),
            ptr::null(),
            0,
            7,
            1,
            SkybridgeFileTransferManifestMode::Transfer,
            files.as_ptr(),
            files.len(),
            1024 * 1024,
            WEBRTC_CHANNEL_MAPPINGS.as_ptr(),
            WEBRTC_CHANNEL_MAPPINGS.len(),
            &mut verdict,
        )
    };

    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(
        verdict.status,
        SkybridgeFileTransferReadinessStatus::Blocked
    );
    assert_eq!(
        verdict.code,
        SkybridgeFileTransferReadinessCode::RouteStalePort
    );
}

#[test]
fn ffi_file_transfer_readiness_rejects_manifest_paths_and_bad_ffi_inputs() {
    const HASH: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    let route = [file_transfer_candidate(
        "192.168.31.20",
        None,
        None,
        8080,
        SkybridgeFileTransferPortProvenance::ListenerTruth,
        7,
    )];
    let traversal = [file_transfer_manifest_file("a.bin", "../a.bin", 1, HASH)];
    let mut verdict = empty_file_transfer_verdict();

    let result = unsafe {
        skybridge_plan_file_transfer_readiness(
            route.as_ptr(),
            route.len(),
            ptr::null(),
            0,
            7,
            1,
            SkybridgeFileTransferManifestMode::Transfer,
            traversal.as_ptr(),
            traversal.len(),
            1024 * 1024,
            WEBRTC_CHANNEL_MAPPINGS.as_ptr(),
            WEBRTC_CHANNEL_MAPPINGS.len(),
            &mut verdict,
        )
    };

    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(
        verdict.status,
        SkybridgeFileTransferReadinessStatus::Blocked
    );
    assert_eq!(
        verdict.code,
        SkybridgeFileTransferReadinessCode::ManifestPathRejected
    );

    let null_out = unsafe {
        skybridge_plan_file_transfer_readiness(
            route.as_ptr(),
            route.len(),
            ptr::null(),
            0,
            7,
            1,
            SkybridgeFileTransferManifestMode::Transfer,
            traversal.as_ptr(),
            traversal.len(),
            1024 * 1024,
            WEBRTC_CHANNEL_MAPPINGS.as_ptr(),
            WEBRTC_CHANNEL_MAPPINGS.len(),
            ptr::null_mut(),
        )
    };
    assert_eq!(null_out, SkybridgeErrorCode::InvalidInput);

    let null_candidates_with_count = unsafe {
        skybridge_plan_file_transfer_readiness(
            ptr::null(),
            1,
            ptr::null(),
            0,
            7,
            1,
            SkybridgeFileTransferManifestMode::Transfer,
            traversal.as_ptr(),
            traversal.len(),
            1024 * 1024,
            WEBRTC_CHANNEL_MAPPINGS.as_ptr(),
            WEBRTC_CHANNEL_MAPPINGS.len(),
            &mut verdict,
        )
    };
    assert_eq!(null_candidates_with_count, SkybridgeErrorCode::InvalidInput);

    let invalid_utf8 = [0xffu8];
    let invalid_target = unsafe {
        skybridge_plan_file_transfer_readiness(
            ptr::null(),
            0,
            invalid_utf8.as_ptr(),
            invalid_utf8.len(),
            0,
            0,
            SkybridgeFileTransferManifestMode::IntentOnly,
            ptr::null(),
            0,
            1024 * 1024,
            ptr::null(),
            0,
            &mut verdict,
        )
    };
    assert_eq!(invalid_target, SkybridgeErrorCode::InvalidInput);
}

#[test]
fn ffi_connection_plan_exports_full_core_contract() {
    let windows = SkybridgePeerCapabilities {
        platform: SkybridgePeerPlatform::Windows,
        supports_apple_native: 0,
        supports_msquic: 1,
        supports_skybridge_ice_msquic: 0,
        supports_webrtc_data_channel: 1,
        supports_tcp_fallback: 1,
        supports_relay: 1,
    };
    let apple = SkybridgePeerCapabilities {
        platform: SkybridgePeerPlatform::Apple,
        supports_apple_native: 1,
        supports_msquic: 0,
        supports_skybridge_ice_msquic: 0,
        supports_webrtc_data_channel: 1,
        supports_tcp_fallback: 1,
        supports_relay: 1,
    };
    let cross_nat = SkybridgeNetworkPath {
        same_lan: 0,
        cross_nat: 1,
    };
    let local_crypto = SkybridgeCryptoProviderCapabilities {
        supports_xwing_hybrid: 1,
        supports_mlkem_768_mldsa_65: 1,
        supports_x25519_ed25519: 1,
        supports_p256_ecdsa: 0,
    };
    let remote_suites = [0x1001, 0x0101, 0x0001];
    let suite_policy = SkybridgeCryptoSuitePolicy {
        allow_classic_fallback: 1,
        allow_legacy_p256: 0,
        timeout_observed: 0,
    };
    let traffic_padding = SkybridgeTrafficPaddingPlan {
        sbp2_enabled: 1,
        fixed_payload_len: 512,
    };
    let empty_mapping = SkybridgeChannelMapping {
        channel: SkybridgeChannelKind::Control,
        reliability: SkybridgeReliabilityKind::ReliableOrdered,
        max_retransmits: 0,
        binding_kind: SkybridgeAdapterBindingKind::MsQuicStream,
        head_of_line_isolated: 0,
    };
    let mut plan = SkybridgeConnectionPlan {
        transport: SkybridgeTransportSelection {
            kind: SkybridgeTransportKind::Unsupported,
            audit_code: SkybridgeTransportAuditCode::UnsupportedNoCompatibleTransport,
            priority: 0,
            relay_required: 0,
            relay_allowed: 0,
        },
        selected_suite: SkybridgeCryptoSuiteKind::Unknown,
        selected_suite_wire_id: 0,
        suite_audit: SkybridgeCryptoSuiteAuditCode::None,
        offered_suites: [SkybridgeCryptoSuiteKind::Unknown; 4],
        offered_suite_wire_ids: [0; 4],
        offered_suite_count: 0,
        channel_mappings: [empty_mapping; 5],
        channel_mapping_count: 0,
        sbp2_enabled: 0,
        sbp2_fixed_payload_len: 0,
        frame_header_len: 0,
    };

    let result = unsafe {
        skybridge_plan_connection(
            windows,
            apple,
            cross_nat,
            local_crypto,
            remote_suites.as_ptr(),
            remote_suites.len(),
            suite_policy,
            traffic_padding,
            &mut plan,
        )
    };

    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(
        plan.transport.kind,
        SkybridgeTransportKind::WebRtcDataChannel
    );
    assert_eq!(
        plan.transport.audit_code,
        SkybridgeTransportAuditCode::WebRtcInterop
    );
    assert_eq!(plan.selected_suite, SkybridgeCryptoSuiteKind::XWingHybrid);
    assert_eq!(plan.selected_suite_wire_id, 0x0001);
    assert_eq!(
        plan.suite_audit,
        SkybridgeCryptoSuiteAuditCode::HybridPqcPreferred
    );
    assert_eq!(plan.offered_suite_count, 3);
    assert_eq!(plan.offered_suite_wire_ids[..3], [0x0001, 0x0101, 0x1001]);
    assert_eq!(plan.channel_mapping_count, 5);
    assert!(plan.channel_mappings.iter().all(|mapping| {
        mapping.binding_kind == SkybridgeAdapterBindingKind::WebRtcDataChannel
            && mapping.head_of_line_isolated == 1
    }));
    assert_eq!(
        plan.channel_mappings[4].reliability,
        SkybridgeReliabilityKind::PartialReliable
    );
    assert_eq!(plan.channel_mappings[4].max_retransmits, 1);
    assert_eq!(plan.sbp2_enabled, 1);
    assert_eq!(plan.sbp2_fixed_payload_len, 512);
    assert_eq!(plan.frame_header_len, 20);

    let null_plan = unsafe {
        skybridge_plan_connection(
            windows,
            apple,
            cross_nat,
            local_crypto,
            remote_suites.as_ptr(),
            remote_suites.len(),
            suite_policy,
            traffic_padding,
            ptr::null_mut(),
        )
    };
    assert_eq!(null_plan, SkybridgeErrorCode::InvalidInput);

    let classic_only = SkybridgeCryptoProviderCapabilities {
        supports_xwing_hybrid: 0,
        supports_mlkem_768_mldsa_65: 0,
        supports_x25519_ed25519: 1,
        supports_p256_ecdsa: 0,
    };
    let timeout_policy = SkybridgeCryptoSuitePolicy {
        timeout_observed: 1,
        ..suite_policy
    };
    let classic_remote = [0x1001];
    let timeout_result = unsafe {
        skybridge_plan_connection(
            windows,
            apple,
            cross_nat,
            classic_only,
            classic_remote.as_ptr(),
            classic_remote.len(),
            timeout_policy,
            traffic_padding,
            &mut plan,
        )
    };
    assert_eq!(timeout_result, SkybridgeErrorCode::TimeoutCannotDowngrade);
}

#[test]
fn ffi_connection_plan_keeps_apple_to_apple_native() {
    let apple = SkybridgePeerCapabilities {
        platform: SkybridgePeerPlatform::Apple,
        supports_apple_native: 1,
        supports_msquic: 0,
        supports_skybridge_ice_msquic: 0,
        supports_webrtc_data_channel: 1,
        supports_tcp_fallback: 1,
        supports_relay: 1,
    };
    let same_lan = SkybridgeNetworkPath {
        same_lan: 1,
        cross_nat: 0,
    };
    let local_crypto = SkybridgeCryptoProviderCapabilities {
        supports_xwing_hybrid: 1,
        supports_mlkem_768_mldsa_65: 1,
        supports_x25519_ed25519: 1,
        supports_p256_ecdsa: 0,
    };
    let remote_suites = [0x1001, 0x0101, 0x0001];
    let suite_policy = SkybridgeCryptoSuitePolicy {
        allow_classic_fallback: 1,
        allow_legacy_p256: 0,
        timeout_observed: 0,
    };
    let traffic_padding = SkybridgeTrafficPaddingPlan {
        sbp2_enabled: 1,
        fixed_payload_len: 512,
    };
    let empty_mapping = SkybridgeChannelMapping {
        channel: SkybridgeChannelKind::Control,
        reliability: SkybridgeReliabilityKind::ReliableOrdered,
        max_retransmits: 0,
        binding_kind: SkybridgeAdapterBindingKind::MsQuicStream,
        head_of_line_isolated: 0,
    };
    let mut plan = SkybridgeConnectionPlan {
        transport: SkybridgeTransportSelection {
            kind: SkybridgeTransportKind::Unsupported,
            audit_code: SkybridgeTransportAuditCode::UnsupportedNoCompatibleTransport,
            priority: 0,
            relay_required: 0,
            relay_allowed: 0,
        },
        selected_suite: SkybridgeCryptoSuiteKind::Unknown,
        selected_suite_wire_id: 0,
        suite_audit: SkybridgeCryptoSuiteAuditCode::None,
        offered_suites: [SkybridgeCryptoSuiteKind::Unknown; 4],
        offered_suite_wire_ids: [0; 4],
        offered_suite_count: 0,
        channel_mappings: [empty_mapping; 5],
        channel_mapping_count: 0,
        sbp2_enabled: 0,
        sbp2_fixed_payload_len: 0,
        frame_header_len: 0,
    };

    let result = unsafe {
        skybridge_plan_connection(
            apple,
            apple,
            same_lan,
            local_crypto,
            remote_suites.as_ptr(),
            remote_suites.len(),
            suite_policy,
            traffic_padding,
            &mut plan,
        )
    };

    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(plan.transport.kind, SkybridgeTransportKind::AppleNative);
    assert_eq!(
        plan.transport.audit_code,
        SkybridgeTransportAuditCode::AppleNativeDefault
    );
    assert_eq!(plan.transport.relay_required, 0);
    assert_eq!(plan.transport.relay_allowed, 0);
    assert_eq!(plan.selected_suite, SkybridgeCryptoSuiteKind::XWingHybrid);
    assert_eq!(plan.channel_mapping_count, 5);
    assert_eq!(
        plan.channel_mappings[0].binding_kind,
        SkybridgeAdapterBindingKind::AppleStream
    );
    assert_eq!(
        plan.channel_mappings[1].binding_kind,
        SkybridgeAdapterBindingKind::AppleStream
    );
    assert_eq!(
        plan.channel_mappings[2].binding_kind,
        SkybridgeAdapterBindingKind::AppleStream
    );
    assert_eq!(
        plan.channel_mappings[3].binding_kind,
        SkybridgeAdapterBindingKind::AppleDatagram
    );
    assert_eq!(
        plan.channel_mappings[4].binding_kind,
        SkybridgeAdapterBindingKind::AppleDatagram
    );
    assert!(plan
        .channel_mappings
        .iter()
        .all(|mapping| { mapping.binding_kind != SkybridgeAdapterBindingKind::WebRtcDataChannel }));
    assert_eq!(plan.sbp2_enabled, 1);
    assert_eq!(plan.sbp2_fixed_payload_len, 512);
}

#[test]
fn ffi_channel_mapping_exports_adapter_contracts() {
    let mut mapping = SkybridgeChannelMapping {
        channel: SkybridgeChannelKind::Control,
        reliability: SkybridgeReliabilityKind::ReliableOrdered,
        max_retransmits: 0,
        binding_kind: SkybridgeAdapterBindingKind::MsQuicStream,
        head_of_line_isolated: 0,
    };

    let result = unsafe {
        skybridge_map_channel(
            SkybridgeTransportKind::WindowsNativeMsQuic,
            SkybridgeChannelKind::Telemetry,
            &mut mapping,
        )
    };
    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(mapping.channel, SkybridgeChannelKind::Telemetry);
    assert_eq!(
        mapping.reliability,
        SkybridgeReliabilityKind::ReliableUnordered
    );
    assert_eq!(
        mapping.binding_kind,
        SkybridgeAdapterBindingKind::MsQuicDatagram
    );
    assert_eq!(mapping.head_of_line_isolated, 1);

    let result = unsafe {
        skybridge_map_channel(
            SkybridgeTransportKind::WebRtcDataChannel,
            SkybridgeChannelKind::File,
            &mut mapping,
        )
    };
    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(mapping.channel, SkybridgeChannelKind::File);
    assert_eq!(
        mapping.reliability,
        SkybridgeReliabilityKind::ReliableOrdered
    );
    assert_eq!(
        mapping.binding_kind,
        SkybridgeAdapterBindingKind::WebRtcDataChannel
    );

    let result = unsafe {
        skybridge_map_channel(
            SkybridgeTransportKind::TcpFallback,
            SkybridgeChannelKind::Realtime,
            &mut mapping,
        )
    };
    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(
        mapping.reliability,
        SkybridgeReliabilityKind::PartialReliable
    );
    assert_eq!(mapping.max_retransmits, 1);
    assert_eq!(mapping.binding_kind, SkybridgeAdapterBindingKind::TcpStream);
    assert_eq!(mapping.head_of_line_isolated, 0);

    let bad_transport = unsafe {
        skybridge_map_channel(
            SkybridgeTransportKind::Unsupported,
            SkybridgeChannelKind::Control,
            &mut mapping,
        )
    };
    assert_eq!(bad_transport, SkybridgeErrorCode::InvalidInput);

    let null_result = unsafe {
        skybridge_map_channel(
            SkybridgeTransportKind::WindowsNativeMsQuic,
            SkybridgeChannelKind::Control,
            ptr::null_mut(),
        )
    };
    assert_eq!(null_result, SkybridgeErrorCode::InvalidInput);
}

#[test]
fn ffi_frame_codec_exports_plain_and_sbp2_contracts() {
    let payload = b"file-chunk";
    let mut encoded = [0u8; 64];
    let mut written = 0usize;

    let plain_result = unsafe {
        skybridge_encode_frame(
            SkybridgeChannelKind::File,
            42,
            payload.as_ptr(),
            payload.len(),
            1,
            encoded.as_mut_ptr(),
            encoded.len(),
            &mut written,
        )
    };

    assert_eq!(plain_result, SkybridgeErrorCode::Ok);
    assert_eq!(written, 20 + payload.len());

    let frame = &encoded[..written];
    let mut metadata = empty_frame_metadata();
    let metadata_result =
        unsafe { skybridge_decode_frame_metadata(frame.as_ptr(), frame.len(), &mut metadata) };
    assert_eq!(metadata_result, SkybridgeErrorCode::Ok);
    assert_eq!(metadata.channel, SkybridgeChannelKind::File);
    assert_eq!(metadata.sequence, 42);
    assert_eq!(metadata.flags, 0x0002);
    assert_eq!(metadata.frame_header_len, 20);
    assert_eq!(metadata.encoded_len, written);
    assert_eq!(metadata.payload_len, payload.len());
    assert_eq!(metadata.decoded_payload_len, payload.len());

    let mut decoded = [0u8; 16];
    let mut decoded_len = 0usize;
    let decode_payload_result = unsafe {
        skybridge_decode_frame_payload(
            frame.as_ptr(),
            frame.len(),
            decoded.as_mut_ptr(),
            decoded.len(),
            &mut decoded_len,
        )
    };
    assert_eq!(decode_payload_result, SkybridgeErrorCode::Ok);
    assert_eq!(&decoded[..decoded_len], payload);

    let mut tiny = [0u8; 4];
    let mut required_len = 0usize;
    let small_buffer_result = unsafe {
        skybridge_encode_frame(
            SkybridgeChannelKind::Control,
            1,
            payload.as_ptr(),
            payload.len(),
            1,
            tiny.as_mut_ptr(),
            tiny.len(),
            &mut required_len,
        )
    };
    assert_eq!(small_buffer_result, SkybridgeErrorCode::InvalidInput);
    assert_eq!(required_len, 20 + payload.len());

    let sbp2_payload = b"hello";
    let mut sbp2_encoded = [0u8; 96];
    let mut sbp2_written = 0usize;
    let sbp2_result = unsafe {
        skybridge_encode_sbp2_frame(
            SkybridgeChannelKind::Realtime,
            7,
            sbp2_payload.as_ptr(),
            sbp2_payload.len(),
            32,
            sbp2_encoded.as_mut_ptr(),
            sbp2_encoded.len(),
            &mut sbp2_written,
        )
    };
    assert_eq!(sbp2_result, SkybridgeErrorCode::Ok);
    assert_eq!(sbp2_written, 20 + 8 + 32);

    let sbp2_frame = &sbp2_encoded[..sbp2_written];
    let sbp2_metadata = unsafe {
        let mut value = empty_frame_metadata();
        let result =
            skybridge_decode_frame_metadata(sbp2_frame.as_ptr(), sbp2_frame.len(), &mut value);
        assert_eq!(result, SkybridgeErrorCode::Ok);
        value
    };
    assert_eq!(sbp2_metadata.channel, SkybridgeChannelKind::Realtime);
    assert_eq!(sbp2_metadata.sequence, 7);
    assert_eq!(sbp2_metadata.flags, 0x0003);
    assert_eq!(sbp2_metadata.payload_len, 8 + 32);
    assert_eq!(sbp2_metadata.decoded_payload_len, sbp2_payload.len());

    let mut unpadded = [0u8; 16];
    let mut unpadded_len = 0usize;
    let sbp2_decode_result = unsafe {
        skybridge_decode_frame_payload(
            sbp2_frame.as_ptr(),
            sbp2_frame.len(),
            unpadded.as_mut_ptr(),
            unpadded.len(),
            &mut unpadded_len,
        )
    };
    assert_eq!(sbp2_decode_result, SkybridgeErrorCode::Ok);
    assert_eq!(&unpadded[..unpadded_len], sbp2_payload);
}

#[test]
fn ffi_discovery_advertisement_exports_mac_bonjour_contract() {
    let service = b"_skybridge._udp";
    let txt = format!(
        "deviceId=mac-1;pubKeyFP={DISCOVERY_FP};platform=macOS;capabilities=webrtc,tcp;name=Desk Mac;version=v1"
    );
    let mut advertisement = empty_discovery_advertisement();

    let result = unsafe {
        skybridge_parse_discovery_advertisement(
            service.as_ptr(),
            service.len(),
            txt.as_ptr(),
            txt.len(),
            &mut advertisement,
        )
    };

    assert_eq!(result, SkybridgeErrorCode::Ok);
    assert_eq!(
        advertisement.service_kind,
        SkybridgeDiscoveryServiceKind::QuicPrimary
    );
    assert_eq!(advertisement.platform, SkybridgePeerPlatform::Apple);
    assert_eq!(
        advertisement.peer_capabilities.platform,
        SkybridgePeerPlatform::Apple
    );
    assert_eq!(advertisement.peer_capabilities.supports_apple_native, 1);
    assert_eq!(
        advertisement.peer_capabilities.supports_webrtc_data_channel,
        1
    );
    assert_eq!(advertisement.peer_capabilities.supports_tcp_fallback, 1);
    assert_eq!(advertisement.peer_capabilities.supports_msquic, 0);
    assert_eq!(
        fixed_utf8(&advertisement.device_id, advertisement.device_id_len),
        "mac-1"
    );
    assert_eq!(
        fixed_utf8(
            &advertisement.public_key_fingerprint,
            advertisement.public_key_fingerprint_len
        ),
        DISCOVERY_FP
    );
    assert_eq!(
        fixed_utf8(
            &advertisement.platform_label,
            advertisement.platform_label_len
        ),
        "macOS"
    );
    assert_eq!(
        fixed_utf8(&advertisement.capabilities, advertisement.capabilities_len),
        "webrtc,tcp"
    );
    assert_eq!(
        fixed_utf8(&advertisement.name, advertisement.name_len),
        "Desk Mac"
    );
    assert_eq!(
        fixed_utf8(
            &advertisement.protocol_version,
            advertisement.protocol_version_len
        ),
        "v1"
    );

    let null_out = unsafe {
        skybridge_parse_discovery_advertisement(
            service.as_ptr(),
            service.len(),
            txt.as_ptr(),
            txt.len(),
            ptr::null_mut(),
        )
    };
    assert_eq!(null_out, SkybridgeErrorCode::InvalidInput);

    let bad_txt = format!(
        "deviceId=mac-1;pubKeyFP={};platform=macOS",
        DISCOVERY_FP.to_ascii_uppercase()
    );
    let bad_result = unsafe {
        skybridge_parse_discovery_advertisement(
            service.as_ptr(),
            service.len(),
            bad_txt.as_ptr(),
            bad_txt.len(),
            &mut advertisement,
        )
    };
    assert_eq!(bad_result, SkybridgeErrorCode::InvalidInput);
}
