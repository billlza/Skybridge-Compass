use skybridge_core::ffi::{
    skybridge_engine_check_liveness, skybridge_engine_clear_events, skybridge_engine_connect,
    skybridge_engine_decrypt_payload, skybridge_engine_disconnect,
    skybridge_engine_encrypt_payload, skybridge_engine_free, skybridge_engine_last_input_len,
    skybridge_engine_local_public_key, skybridge_engine_metrics, skybridge_engine_new,
    skybridge_engine_poll_events, skybridge_engine_reconnect, skybridge_engine_send_heartbeat,
    skybridge_engine_send_input, skybridge_engine_snapshot, skybridge_engine_state,
    skybridge_engine_throttle_stream, skybridge_map_channel, skybridge_plan_connection,
    skybridge_select_transport, SkybridgeAdapterBindingKind, SkybridgeBuffer, SkybridgeChannelKind,
    SkybridgeChannelMapping, SkybridgeConnectionPlan, SkybridgeCryptoProviderCapabilities,
    SkybridgeCryptoSuiteAuditCode, SkybridgeCryptoSuiteKind, SkybridgeCryptoSuitePolicy,
    SkybridgeEngineSnapshot, SkybridgeErrorCode, SkybridgeEvent, SkybridgeEventKind,
    SkybridgeFlowRate, SkybridgeNetworkPath, SkybridgePeerCapabilities, SkybridgePeerPlatform,
    SkybridgeReliabilityKind, SkybridgeSessionConfig, SkybridgeSessionState,
    SkybridgeStreamMetrics, SkybridgeTrafficPaddingPlan, SkybridgeTransportAuditCode,
    SkybridgeTransportKind, SkybridgeTransportSelection, SKYBRIDGE_EVENT_CAPACITY,
};
use std::os::raw::c_char;
use std::ptr;

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
    let config = SkybridgeSessionConfig {
        client_id_ptr: client_id.as_ptr() as *const c_char,
        client_id_len: client_id.len(),
        heartbeat_interval_ms: 10,
        peer_public_key_ptr: local_key.as_ptr(),
        peer_public_key_len: local_key.len(),
    };

    let connect_result = skybridge_engine_connect(handle, config);
    assert_eq!(connect_result, SkybridgeErrorCode::Ok);
    let state = skybridge_engine_state(handle);
    assert_eq!(state, SkybridgeSessionState::Connected);

    let mut snapshot = SkybridgeEngineSnapshot {
        state: SkybridgeSessionState::Disconnected,
        last_heartbeat_ms: 0,
        has_last_heartbeat: false,
        has_secrets: false,
    };
    let snapshot_res = unsafe { skybridge_engine_snapshot(handle, &mut snapshot) };
    assert_eq!(snapshot_res, SkybridgeErrorCode::Ok);
    assert_eq!(snapshot.state, SkybridgeSessionState::Connected);
    assert!(snapshot.has_secrets);
    assert!(!snapshot.has_last_heartbeat);

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
    let config = SkybridgeSessionConfig {
        client_id_ptr: client_id.as_ptr() as *const c_char,
        client_id_len: client_id.len(),
        heartbeat_interval_ms: 0,
        peer_public_key_ptr: local_key.as_ptr(),
        peer_public_key_len: local_key.len(),
    };

    let connect_result = skybridge_engine_connect(handle, config);
    assert_eq!(connect_result, SkybridgeErrorCode::InvalidInput);
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
    let config = SkybridgeSessionConfig {
        client_id_ptr: client_id.as_ptr() as *const c_char,
        client_id_len: client_id.len(),
        heartbeat_interval_ms: 5,
        peer_public_key_ptr: local_key.as_ptr(),
        peer_public_key_len: local_key.len(),
    };
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
