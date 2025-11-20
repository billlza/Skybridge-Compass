use skybridge_core::crypto::{KeyExchangeProvider, P256KeyExchange};
use skybridge_core::ffi::{
    skybridge_engine_connect, skybridge_engine_disconnect, skybridge_engine_free,
    skybridge_engine_last_input_len, skybridge_engine_new, skybridge_engine_poll_events,
    skybridge_engine_send_heartbeat, skybridge_engine_send_input, skybridge_engine_state,
    SkybridgeErrorCode, SkybridgeEvent, SkybridgeEventKind, SkybridgeSessionConfig,
    SkybridgeSessionState,
};
use std::os::raw::c_char;
use std::ptr;

#[test]
fn ffi_engine_lifecycle_runs() {
    let handle = skybridge_engine_new();
    assert!(!handle.is_null());

    let peer_key = tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
        .unwrap()
        .block_on(async {
            P256KeyExchange
                .generate()
                .await
                .expect("peer key")
                .public_key
        });

    let client_id = b"ffi-client";
    let config = SkybridgeSessionConfig {
        client_id_ptr: client_id.as_ptr() as *const c_char,
        client_id_len: client_id.len(),
        heartbeat_interval_ms: 10,
        peer_public_key_ptr: peer_key.as_ptr(),
        peer_public_key_len: peer_key.len(),
    };

    let connect_result = skybridge_engine_connect(handle, config);
    assert_eq!(connect_result, SkybridgeErrorCode::Ok);
    let state = skybridge_engine_state(handle);
    assert_eq!(state, SkybridgeSessionState::Connected);

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

    let shutdown_result = skybridge_engine_disconnect(handle);
    assert_eq!(shutdown_result, SkybridgeErrorCode::Ok);
    let disconnect_event = unsafe { skybridge_engine_poll_events(handle, &mut event) };
    assert_eq!(disconnect_event, SkybridgeErrorCode::Ok);
    assert_eq!(event.kind, SkybridgeEventKind::Disconnected);
    let final_state = skybridge_engine_state(handle);
    assert_eq!(final_state, SkybridgeSessionState::Disconnected);

    unsafe { skybridge_engine_free(handle) };
}
