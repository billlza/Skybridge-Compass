use skybridge_core::ffi::{
    skybridge_engine_check_liveness, skybridge_engine_clear_events, skybridge_engine_connect,
    skybridge_engine_decrypt_payload, skybridge_engine_disconnect,
    skybridge_engine_encrypt_payload, skybridge_engine_free, skybridge_engine_last_input_len,
    skybridge_engine_local_public_key, skybridge_engine_metrics, skybridge_engine_new,
    skybridge_engine_poll_events, skybridge_engine_reconnect, skybridge_engine_send_heartbeat,
    skybridge_engine_send_input, skybridge_engine_snapshot, skybridge_engine_state,
    skybridge_engine_throttle_stream, SkybridgeBuffer, SkybridgeEngineSnapshot, SkybridgeErrorCode,
    SkybridgeEvent, SkybridgeEventKind, SkybridgeFlowRate, SkybridgeSessionConfig,
    SkybridgeSessionState, SkybridgeStreamMetrics, SKYBRIDGE_EVENT_CAPACITY,
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
