use std::collections::BTreeMap;
use std::future::pending;
use std::sync::Arc;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Duration;

use anyhow::{Result, anyhow};
use bytes::BytesMut;
use ed25519_dalek::SigningKey;
use tokio::time::timeout;
use webrtc::data_channel::{RTCDataChannelId, RTCDataChannelState};
use webrtc::error::{Error as WebRtcError, Result as WebRtcResult};

use super::*;
use crate::{
    BootstrapKemPublicKey, ClassicInitiatorConfig, ClassicResponderConfig, CrossNetworkTransferId,
    CryptoSuite, DowngradePolicy, PqcInitiatorConfig, PqcResponderConfig, ProtocolIdentityBinding,
    ProtocolSigningAlgorithm, RustPqcIdentityMaterial,
    encode_cross_network_file_transfer_message_v1, make_explicit_classic_join_envelope,
    make_join_envelope,
};

struct TestDataChannel {
    id: RTCDataChannelId,
    label: Option<String>,
    fail_send: bool,
    never_complete_send: bool,
    send_delay: Option<Duration>,
    sent_chunks: Option<StdMutex<Vec<Vec<u8>>>>,
    send_count: AtomicUsize,
    max_send_bytes: AtomicUsize,
    close_count: AtomicUsize,
}

struct SetupDropProbe(Arc<AtomicBool>);

impl Drop for SetupDropProbe {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

impl TestDataChannel {
    fn new(id: RTCDataChannelId, label: Option<&str>, fail_send: bool) -> Self {
        Self {
            id,
            label: label.map(str::to_owned),
            fail_send,
            never_complete_send: false,
            send_delay: None,
            sent_chunks: None,
            send_count: AtomicUsize::new(0),
            max_send_bytes: AtomicUsize::new(0),
            close_count: AtomicUsize::new(0),
        }
    }

    fn never_resolving_send(id: RTCDataChannelId, label: Option<&str>) -> Self {
        Self {
            id,
            label: label.map(str::to_owned),
            fail_send: false,
            never_complete_send: true,
            send_delay: None,
            sent_chunks: None,
            send_count: AtomicUsize::new(0),
            max_send_bytes: AtomicUsize::new(0),
            close_count: AtomicUsize::new(0),
        }
    }

    fn delayed(id: RTCDataChannelId, label: Option<&str>, send_delay: Duration) -> Self {
        Self {
            id,
            label: label.map(str::to_owned),
            fail_send: false,
            never_complete_send: false,
            send_delay: Some(send_delay),
            sent_chunks: None,
            send_count: AtomicUsize::new(0),
            max_send_bytes: AtomicUsize::new(0),
            close_count: AtomicUsize::new(0),
        }
    }

    fn capturing(id: RTCDataChannelId, label: Option<&str>, send_delay: Duration) -> Self {
        Self {
            id,
            label: label.map(str::to_owned),
            fail_send: false,
            never_complete_send: false,
            send_delay: Some(send_delay),
            sent_chunks: Some(StdMutex::new(Vec::new())),
            send_count: AtomicUsize::new(0),
            max_send_bytes: AtomicUsize::new(0),
            close_count: AtomicUsize::new(0),
        }
    }

    fn captured_chunks(&self) -> Vec<Vec<u8>> {
        self.sent_chunks
            .as_ref()
            .expect("capture was not enabled")
            .lock()
            .expect("capture mutex poisoned")
            .clone()
    }
}

#[async_trait::async_trait]
impl DataChannel for TestDataChannel {
    async fn label(&self) -> WebRtcResult<String> {
        self.label.clone().ok_or(WebRtcError::ErrDataChannelClosed)
    }

    async fn ordered(&self) -> WebRtcResult<bool> {
        Ok(true)
    }

    async fn max_packet_life_time(&self) -> WebRtcResult<Option<u16>> {
        Ok(None)
    }

    async fn max_retransmits(&self) -> WebRtcResult<Option<u16>> {
        Ok(None)
    }

    async fn protocol(&self) -> WebRtcResult<String> {
        Ok(String::new())
    }

    async fn negotiated(&self) -> WebRtcResult<bool> {
        Ok(false)
    }

    fn id(&self) -> RTCDataChannelId {
        self.id
    }

    async fn ready_state(&self) -> WebRtcResult<RTCDataChannelState> {
        Ok(RTCDataChannelState::Open)
    }

    async fn buffered_amount_high_threshold(&self) -> WebRtcResult<u32> {
        Ok(u32::MAX)
    }

    async fn set_buffered_amount_high_threshold(&self, _threshold: u32) -> WebRtcResult<()> {
        Ok(())
    }

    async fn buffered_amount_low_threshold(&self) -> WebRtcResult<u32> {
        Ok(0)
    }

    async fn set_buffered_amount_low_threshold(&self, _threshold: u32) -> WebRtcResult<()> {
        Ok(())
    }

    async fn send(&self, data: BytesMut) -> WebRtcResult<()> {
        self.send_count.fetch_add(1, Ordering::SeqCst);
        self.max_send_bytes.fetch_max(data.len(), Ordering::SeqCst);
        if self.never_complete_send {
            pending::<WebRtcResult<()>>().await
        } else if self.fail_send {
            Err(WebRtcError::ErrDataChannelClosed)
        } else {
            if let Some(delay) = self.send_delay {
                tokio::time::sleep(delay).await;
            }
            if let Some(chunks) = self.sent_chunks.as_ref() {
                chunks
                    .lock()
                    .expect("capture mutex poisoned")
                    .push(data.to_vec());
            }
            Ok(())
        }
    }

    async fn send_text(&self, _text: &str) -> WebRtcResult<()> {
        if self.fail_send {
            Err(WebRtcError::ErrDataChannelClosed)
        } else {
            Ok(())
        }
    }

    async fn poll(&self) -> Option<DataChannelEvent> {
        pending().await
    }

    async fn close(&self) -> WebRtcResult<()> {
        self.close_count.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}

fn classic_config_pair() -> Result<(ClassicInitiatorConfig, ClassicResponderConfig)> {
    let initiator_key = SigningKey::from_bytes(&[0x31; 32]);
    let responder_key = SigningKey::from_bytes(&[0x42; 32]);
    Ok((
        ClassicInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-native-classic-init",
                ProtocolSigningAlgorithm::Ed25519,
                initiator_key.verifying_key().to_bytes().to_vec(),
                None,
            )?,
            signing_secret_key: initiator_key.to_bytes().to_vec(),
            local_device_name: Some("Native Classic Initiator".to_owned()),
            policy: DowngradePolicy::Default,
        },
        ClassicResponderConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-native-classic-resp",
                ProtocolSigningAlgorithm::Ed25519,
                responder_key.verifying_key().to_bytes().to_vec(),
                None,
            )?,
            signing_secret_key: responder_key.to_bytes().to_vec(),
            local_device_name: Some("Native Classic Responder".to_owned()),
            policy: DowngradePolicy::Default,
        },
    ))
}

async fn native_test_initiator(session_id: &str) -> Result<NativeWebRtcSession> {
    let (classic_initiator, _) = classic_config_pair()?;
    NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: session_id.to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: Some(classic_initiator),
        classic_responder: None,
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await
}

fn pqc_join_bootstrap(
    device_id: &str,
    identity: &RustPqcIdentityMaterial,
) -> Result<WebRtcJoinBootstrap> {
    WebRtcJoinBootstrap::new(
        device_id,
        identity.signing_algorithm,
        ProtocolIdentityBinding::compute_fingerprint(
            identity.signing_algorithm,
            &identity.signing_public_key,
        ),
        identity.signing_public_key.clone(),
        vec![
            BootstrapKemPublicKey {
                suite_wire_id: CryptoSuite::XWING_MLDSA.wire_id,
                public_key: identity.xwing_public_key.clone(),
            },
            BootstrapKemPublicKey {
                suite_wire_id: CryptoSuite::MLKEM768_MLDSA65.wire_id,
                public_key: identity.mlkem768_public_key.clone(),
            },
        ],
        Some("Rust".to_owned()),
        None,
    )
}

fn established_classic_initiator() -> Result<(NativeSessionHandshake, ClassicSessionKeys)> {
    let (initiator_config, responder_config) = classic_config_pair()?;
    let mut initiator = NativeSessionHandshake::classic_initiator(initiator_config)?;
    let mut responder = NativeSessionHandshake::classic_responder(responder_config)?;

    let message_a = initiator.start()?;
    let responder_actions = responder.handle_frame(&message_a)?;
    if responder_actions.outbound_frames.len() != 2 {
        return Err(anyhow!(
            "classic responder did not emit MessageB and Finished"
        ));
    }
    let message_b_actions = initiator.handle_frame(&responder_actions.outbound_frames[0])?;
    if message_b_actions.established.is_some() {
        return Err(anyhow!("classic initiator established before Finished"));
    }
    let initiator_actions = initiator.handle_frame(&responder_actions.outbound_frames[1])?;
    let keys = initiator_actions
        .established
        .ok_or_else(|| anyhow!("classic initiator did not establish"))?;
    let client_finished = initiator_actions
        .outbound_frames
        .first()
        .ok_or_else(|| anyhow!("classic initiator did not emit Finished"))?;
    if responder
        .handle_frame(client_finished)?
        .established
        .is_none()
    {
        return Err(anyhow!("classic responder did not establish"));
    }
    Ok((initiator, keys))
}

/// The selected-ICE-route observation is what `native.connect` ultimately
/// gates on: five seconds after transport-ready, a session whose stats never
/// yield a nominated pair is torn down. This pins that path against a REAL
/// in-process loopback pair, so a stats regression in the WebRTC stack fails
/// here instead of only on live two-agent runs.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn selected_ice_route_is_observed_on_a_real_loopback_pair() -> Result<()> {
    let (mut initiator, mut responder) = new_started_classic_pair("route-observation").await?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(12);
    let mut route_events = 0usize;
    let mut disconnects: Vec<String> = Vec::new();
    while tokio::time::Instant::now() < deadline && route_events < 2 {
        tokio::select! {
            event = initiator.next_event() => {
                if let Some(event) = event {
                    match &event {
                        NativeWebRtcEvent::SignalingEnvelope(envelope) => {
                            responder.handle_signaling_envelope(envelope).await?;
                        }
                        NativeWebRtcEvent::SelectedIceRoute(observation) => {
                            assert_eq!(observation.remote_address, "127.0.0.1");
                            assert!(observation.remote_port > 0);
                            assert_eq!(observation.protocol, "udp");
                            route_events += 1;
                        }
                        NativeWebRtcEvent::TransportDisconnected { reason } => {
                            disconnects.push(format!("initiator:{reason:?}"));
                        }
                        _ => {}
                    }
                }
            }
            event = responder.next_event() => {
                if let Some(event) = event {
                    match &event {
                        NativeWebRtcEvent::SignalingEnvelope(envelope) => {
                            initiator.handle_signaling_envelope(envelope).await?;
                        }
                        NativeWebRtcEvent::SelectedIceRoute(observation) => {
                            assert_eq!(observation.remote_address, "127.0.0.1");
                            assert!(observation.remote_port > 0);
                            assert_eq!(observation.protocol, "udp");
                            route_events += 1;
                        }
                        NativeWebRtcEvent::TransportDisconnected { reason } => {
                            disconnects.push(format!("responder:{reason:?}"));
                        }
                        _ => {}
                    }
                }
            }
            _ = tokio::time::sleep(Duration::from_millis(50)) => {}
        }
        if !disconnects.is_empty() {
            break;
        }
    }

    assert!(
        disconnects.is_empty(),
        "transport must not disconnect while awaiting the route observation: {disconnects:?}"
    );
    assert_eq!(
        route_events, 2,
        "both sides must observe their selected ICE route within the observation window"
    );
    Ok(())
}

/// Builds and starts a REAL classic loopback pair (actual UDP sockets and ICE),
/// pinned to 127.0.0.1 so the test is hermetic.
async fn new_started_classic_pair(
    session_id: &str,
) -> Result<(NativeWebRtcSession, NativeWebRtcSession)> {
    let (classic_initiator, classic_responder) = classic_config_pair()?;
    let initiator = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: session_id.to_owned(),
        local_device_id: "device-a".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: Some(classic_initiator),
        classic_responder: None,
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;
    let responder = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: session_id.to_owned(),
        local_device_id: "device-b".to_owned(),
        role: RuntimeSessionRole::Responder,
        turn_credentials: None,
        classic_initiator: None,
        classic_responder: Some(classic_responder),
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;
    initiator.start().await?;
    responder.start().await?;
    initiator.notify_remote_join("device-b").await?;
    Ok((initiator, responder))
}

async fn pump_events(
    initiator: &mut NativeWebRtcSession,
    responder: &mut NativeWebRtcSession,
    min_ready: usize,
    min_handshake: usize,
) -> Result<Vec<NativeWebRtcEvent>> {
    let mut observed = Vec::new();
    let mut ready_count = 0usize;
    let mut handshake_count = 0usize;

    for _ in 0..256 {
        tokio::select! {
            event = initiator.next_event() => {
                if let Some(event) = event {
                    match &event {
                        NativeWebRtcEvent::SignalingEnvelope(envelope) => {
                            responder.handle_signaling_envelope(envelope).await?;
                        }
                        NativeWebRtcEvent::TransportReady => {
                            ready_count += 1;
                            observed.push(event);
                        }
                        NativeWebRtcEvent::HandshakeComplete { .. } => {
                            handshake_count += 1;
                            observed.push(event);
                        }
                        NativeWebRtcEvent::Keepalive { .. } => {}
                        NativeWebRtcEvent::AuthenticatedPeerHeartbeat { .. } => {}
                        NativeWebRtcEvent::SelectedIceRoute(_) => {}
                        NativeWebRtcEvent::TransportDisconnected { .. } => observed.push(event),
                        NativeWebRtcEvent::InboundFileFrame(_) => {}
                    }
                }
            }
            event = responder.next_event() => {
                if let Some(event) = event {
                    match &event {
                        NativeWebRtcEvent::SignalingEnvelope(envelope) => {
                            initiator.handle_signaling_envelope(envelope).await?;
                        }
                        NativeWebRtcEvent::TransportReady => {
                            ready_count += 1;
                            observed.push(event);
                        }
                        NativeWebRtcEvent::HandshakeComplete { .. } => {
                            handshake_count += 1;
                            observed.push(event);
                        }
                        NativeWebRtcEvent::Keepalive { .. } => {}
                        NativeWebRtcEvent::AuthenticatedPeerHeartbeat { .. } => {}
                        NativeWebRtcEvent::SelectedIceRoute(_) => {}
                        NativeWebRtcEvent::TransportDisconnected { .. } => observed.push(event),
                        NativeWebRtcEvent::InboundFileFrame(_) => {}
                    }
                }
            }
            _ = tokio::time::sleep(Duration::from_millis(50)) => {}
        }

        if ready_count >= min_ready && handshake_count >= min_handshake {
            break;
        }
    }

    Ok(observed)
}

#[tokio::test]
async fn native_webrtc_completes_rust_to_rust_default_classic_handshake() -> Result<()> {
    let (classic_initiator, classic_responder) = classic_config_pair()?;
    let initiator_fingerprint = classic_initiator
        .local_binding
        .protocol_public_key_fingerprint
        .clone();
    let responder_fingerprint = classic_responder
        .local_binding
        .protocol_public_key_fingerprint
        .clone();
    let mut initiator = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "native-test".to_owned(),
        local_device_id: "device-a".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: Some(classic_initiator),
        classic_responder: None,
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;
    let mut responder = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "native-test".to_owned(),
        local_device_id: "device-b".to_owned(),
        role: RuntimeSessionRole::Responder,
        turn_credentials: None,
        classic_initiator: None,
        classic_responder: Some(classic_responder),
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;

    initiator
        .configure_heartbeat_advertisement(NativeWebRtcHeartbeatAdvertisement {
            capabilities: Some(vec!["file_transfer".to_owned()]),
            file_transfer_port: None,
            remote_control_port: None,
        })
        .await?;
    initiator.start().await?;
    responder.start().await?;
    initiator.notify_remote_join("device-b").await?;

    let observed = timeout(
        Duration::from_secs(15),
        pump_events(&mut initiator, &mut responder, 2, 2),
    )
    .await
    .map_err(|_| anyhow!("native_webrtc_test_timeout"))??;

    let ready_count = observed
        .iter()
        .filter(|event| matches!(event, NativeWebRtcEvent::TransportReady))
        .count();
    let handshake_events = observed
        .iter()
        .filter_map(|event| match event {
            NativeWebRtcEvent::HandshakeComplete {
                negotiated_suite,
                peer_protocol_public_key_fingerprint,
            } => Some((negotiated_suite, peer_protocol_public_key_fingerprint)),
            _ => None,
        })
        .collect::<Vec<_>>();

    assert_eq!(ready_count, 2, "observed events: {observed:?}");
    assert_eq!(handshake_events.len(), 2, "observed events: {observed:?}");
    assert!(handshake_events.iter().all(|(suite, _)| *suite == "X25519"));
    assert!(
        handshake_events
            .iter()
            .any(|(_, fingerprint)| fingerprint.as_str() == initiator_fingerprint.as_str())
    );
    assert!(
        handshake_events
            .iter()
            .any(|(_, fingerprint)| fingerprint.as_str() == responder_fingerprint.as_str())
    );
    assert!(
        observed
            .iter()
            .all(|event| { !matches!(event, NativeWebRtcEvent::TransportDisconnected { .. }) })
    );

    let file_transfer_id = CrossNetworkTransferId::parse("51515151-5151-4151-8151-515151515151")?;
    let file_plaintext = encode_cross_network_file_transfer_message_v1(
        &CrossNetworkFileTransferMessageV1::MetadataAck {
            transfer_id: file_transfer_id.clone(),
        },
    )?;
    initiator
        .sender_handle()
        .send_file_app_frame(&file_plaintext)
        .await?;
    let mut saw_authenticated_heartbeat = false;
    let mut saw_file_frame = false;
    let mut saw_pong = false;
    timeout(Duration::from_secs(5), async {
        while !(saw_authenticated_heartbeat && saw_file_frame && saw_pong) {
            tokio::select! {
                event = initiator.next_event() => {
                    match event.ok_or_else(|| anyhow!("initiator event stream ended"))? {
                        NativeWebRtcEvent::SignalingEnvelope(envelope) => {
                            responder.handle_signaling_envelope(&envelope).await?;
                        }
                        NativeWebRtcEvent::AuthenticatedPeerHeartbeat {
                            payload,
                            sbwc_counter,
                            received_at_unix_seconds,
                        } => {
                            assert_eq!(payload.device_id.as_deref(), Some("device-b"));
                            assert!(payload.remote_video_formats.is_none());
                            assert!(payload.capabilities.is_none());
                            assert!(payload.sent_at.is_finite());
                            assert!(sbwc_counter > 0);
                            assert!(received_at_unix_seconds.is_finite());
                            saw_authenticated_heartbeat = true;
                        }
                        NativeWebRtcEvent::Keepalive {
                            kind: RuntimeSessionKeepaliveKind::PongReceived,
                            ..
                        } => saw_pong = true,
                        NativeWebRtcEvent::TransportDisconnected { reason } => {
                            return Err(anyhow!("initiator disconnected during SBWC loopback: {reason:?}"));
                        }
                        _ => {}
                    }
                }
                event = responder.next_event() => {
                    match event.ok_or_else(|| anyhow!("responder event stream ended"))? {
                        NativeWebRtcEvent::SignalingEnvelope(envelope) => {
                            initiator.handle_signaling_envelope(&envelope).await?;
                        }
                        NativeWebRtcEvent::AuthenticatedPeerHeartbeat {
                            payload,
                            sbwc_counter,
                            received_at_unix_seconds,
                        } => {
                            assert_eq!(payload.device_id.as_deref(), Some("device-a"));
                            assert!(payload.remote_video_formats.is_none());
                            assert_eq!(
                                payload.capabilities.as_deref(),
                                Some(["file_transfer".to_owned()].as_slice())
                            );
                            assert!(payload.file_transfer_port.is_none());
                            assert!(payload.sent_at.is_finite());
                            assert!(sbwc_counter > 0);
                            assert!(received_at_unix_seconds.is_finite());
                            saw_authenticated_heartbeat = true;
                        }
                        NativeWebRtcEvent::InboundFileFrame(message) => {
                            assert_eq!(
                                *message,
                                CrossNetworkFileTransferMessageV1::MetadataAck {
                                    transfer_id: file_transfer_id.clone(),
                                }
                            );
                            saw_file_frame = true;
                        }
                        NativeWebRtcEvent::Keepalive {
                            kind: RuntimeSessionKeepaliveKind::PongReceived,
                            ..
                        } => saw_pong = true,
                        NativeWebRtcEvent::TransportDisconnected { reason } => {
                            return Err(anyhow!("responder disconnected during SBWC loopback: {reason:?}"));
                        }
                        _ => {}
                    }
                }
            }
        }
        Ok::<(), anyhow::Error>(())
    })
    .await
    .map_err(|_| anyhow!("SBWC app/file loopback timeout"))??;

    initiator.close().await?;
    responder.close().await?;
    Ok(())
}

#[tokio::test]
async fn native_heartbeat_advertisement_is_explicit_and_frozen_at_start() -> Result<()> {
    let session = native_test_initiator("heartbeat-advertisement-freeze").await?;
    session.start().await?;
    let error = session
        .configure_heartbeat_advertisement(NativeWebRtcHeartbeatAdvertisement {
            capabilities: Some(vec!["file_transfer".to_owned()]),
            file_transfer_port: None,
            remote_control_port: None,
        })
        .await
        .expect_err("post-start capability configuration must fail closed");
    assert!(error.to_string().contains("frozen after session start"));
    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn native_webrtc_rejects_handshake_free_session_configuration() -> Result<()> {
    let error = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "missing-handshake".to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: None,
        classic_responder: None,
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await
    .err()
    .ok_or_else(|| anyhow!("handshake-free native session config unexpectedly succeeded"))?;
    assert!(
        error
            .to_string()
            .contains("exactly one initiator handshake")
    );
    Ok(())
}

#[tokio::test]
async fn native_webrtc_rejects_wrong_role_and_multiple_handshake_configs() -> Result<()> {
    let (_, classic_responder) = classic_config_pair()?;
    let wrong_role = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "wrong-role-handshake".to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: None,
        classic_responder: Some(classic_responder),
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await
    .err()
    .ok_or_else(|| anyhow!("wrong-role handshake config unexpectedly succeeded"))?;
    assert!(
        wrong_role
            .to_string()
            .contains("exactly one initiator handshake")
    );

    let (classic_initiator, classic_responder) = classic_config_pair()?;
    let multiple = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "multiple-handshakes".to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: Some(classic_initiator),
        classic_responder: Some(classic_responder),
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await
    .err()
    .ok_or_else(|| anyhow!("multiple handshake configs unexpectedly succeeded"))?;
    assert!(
        multiple
            .to_string()
            .contains("exactly one initiator handshake")
    );
    Ok(())
}

#[tokio::test]
async fn native_webrtc_rejects_offer_without_sdp_payload() -> Result<()> {
    let (_, classic_responder) = classic_config_pair()?;
    let session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "semantic-validation".to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Responder,
        turn_credentials: None,
        classic_initiator: None,
        classic_responder: Some(classic_responder),
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;
    let error = session
        .handle_signaling_envelope(&WebRtcSignalingEnvelope {
            session_id: "semantic-validation".to_owned(),
            from: "remote-device".to_owned(),
            to: Some("local-device".to_owned()),
            kind: WebRtcMessageType::Offer,
            payload: None,
            auth_token: None,
            sent_at: 0.0,
        })
        .await
        .expect_err("an offer without SDP must fail semantic validation");
    assert!(error.to_string().contains("missing its SDP payload"));
    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn pqc_initiator_requires_join_bootstrap_before_offer_creation() -> Result<()> {
    let local_identity = RustPqcIdentityMaterial::generate()?;
    let local_device_id = "device-local-pqc-0001";
    let session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "pqc-join-required".to_owned(),
        local_device_id: local_device_id.to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: None,
        classic_responder: None,
        pqc_initiator: Some(PqcInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                local_device_id,
                local_identity.signing_algorithm,
                local_identity.signing_public_key,
                None,
            )?,
            signing_secret_key: local_identity.signing_secret_key,
            local_device_name: Some("Local PQC".to_owned()),
            preferred_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
            peer_kem_public_keys: BTreeMap::new(),
            policy: DowngradePolicy::PreferPqc,
        }),
        pqc_responder: None,
    })
    .await?;
    session.start().await?;

    let error = session
        .handle_signaling_envelope(&make_explicit_classic_join_envelope(
            "pqc-join-required",
            "device-remote-pqc-0002",
        )?)
        .await
        .expect_err("PQC initiator must not create an offer without peer KEM bootstrap");
    assert!(
        error
            .to_string()
            .contains("requires a complete remote Join")
    );
    let state = session.inner.state.lock().await;
    assert!(!state.offer_started);
    assert!(state.handshake.is_none());
    assert!(state.pending_pqc_initiator.is_some());
    drop(state);
    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn pqc_initiator_rejects_join_key_that_conflicts_with_operator_pin() -> Result<()> {
    let local_identity = RustPqcIdentityMaterial::generate()?;
    let remote_identity = RustPqcIdentityMaterial::generate()?;
    let incorrect_pin_identity = RustPqcIdentityMaterial::generate()?;
    let local_device_id = "device-local-pqc-pin-0001";
    let remote_device_id = "device-remote-pqc-pin-0002";
    let session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "pqc-join-pin".to_owned(),
        local_device_id: local_device_id.to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: None,
        classic_responder: None,
        pqc_initiator: Some(PqcInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                local_device_id,
                local_identity.signing_algorithm,
                local_identity.signing_public_key,
                None,
            )?,
            signing_secret_key: local_identity.signing_secret_key,
            local_device_name: Some("Pinned PQC".to_owned()),
            preferred_suites: vec![CryptoSuite::XWING_MLDSA],
            peer_kem_public_keys: BTreeMap::from([(
                CryptoSuite::XWING_MLDSA,
                incorrect_pin_identity.xwing_public_key,
            )]),
            policy: DowngradePolicy::PreferPqc,
        }),
        pqc_responder: None,
    })
    .await?;
    session.start().await?;

    let error = session
        .handle_signaling_envelope(&make_join_envelope(
            "pqc-join-pin",
            remote_device_id,
            pqc_join_bootstrap(remote_device_id, &remote_identity)?,
        )?)
        .await
        .expect_err("remote Join must match the configured KEM pin");
    assert!(
        error
            .to_string()
            .contains("does not match the configured pin")
    );
    let state = session.inner.state.lock().await;
    assert!(!state.offer_started);
    assert!(state.handshake.is_none());
    assert!(state.pending_pqc_initiator.is_some());
    drop(state);
    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn pqc_handshake_completion_rejects_identity_not_bound_by_join() -> Result<()> {
    let local_identity = RustPqcIdentityMaterial::generate()?;
    let advertised_remote_identity = RustPqcIdentityMaterial::generate()?;
    let local_device_id = "device-local-pqc-responder-0001";
    let remote_device_id = "device-remote-pqc-identity-0002";
    let session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "pqc-join-identity-binding".to_owned(),
        local_device_id: local_device_id.to_owned(),
        role: RuntimeSessionRole::Responder,
        turn_credentials: None,
        classic_initiator: None,
        classic_responder: None,
        pqc_initiator: None,
        pqc_responder: Some(PqcResponderConfig {
            local_binding: ProtocolIdentityBinding::new(
                local_device_id,
                local_identity.signing_algorithm,
                local_identity.signing_public_key.clone(),
                None,
            )?,
            local_device_name: Some("PQC Responder".to_owned()),
            identity: local_identity,
            supported_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
            policy: DowngradePolicy::PreferPqc,
        }),
    })
    .await?;
    session
        .inner
        .bind_remote_device_id(remote_device_id)
        .await?;
    session
        .inner
        .install_remote_join_bootstrap(Some(pqc_join_bootstrap(
            remote_device_id,
            &advertised_remote_identity,
        )?))
        .await?;

    let (_, keys_for_different_peer_identity) = established_classic_initiator()?;
    let error = session
        .inner
        .mark_handshake_complete(keys_for_different_peer_identity)
        .await
        .expect_err("handshake identity must match the identity authenticated by Join");
    assert!(
        error
            .to_string()
            .contains("does not match the signaling Join")
    );
    let state = session.inner.state.lock().await;
    assert!(state.app_secure_runtime.is_none());
    assert!(!state.handshake_complete_emitted);
    drop(state);
    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn native_webrtc_completes_rust_to_rust_pqc_handshake() -> Result<()> {
    let initiator_device_id = "device-alpha-0001";
    let responder_device_id = "device-bravo-0002";
    let initiator_identity = RustPqcIdentityMaterial::generate()?;
    let responder_identity = RustPqcIdentityMaterial::generate()?;
    let initiator_fingerprint = ProtocolIdentityBinding::compute_fingerprint(
        initiator_identity.signing_algorithm,
        &initiator_identity.signing_public_key,
    );
    let responder_fingerprint = ProtocolIdentityBinding::compute_fingerprint(
        responder_identity.signing_algorithm,
        &responder_identity.signing_public_key,
    );
    let initiator_bootstrap = WebRtcJoinBootstrap::new(
        initiator_device_id,
        initiator_identity.signing_algorithm,
        initiator_fingerprint.clone(),
        initiator_identity.signing_public_key.clone(),
        vec![
            BootstrapKemPublicKey {
                suite_wire_id: CryptoSuite::XWING_MLDSA.wire_id,
                public_key: initiator_identity.xwing_public_key.clone(),
            },
            BootstrapKemPublicKey {
                suite_wire_id: CryptoSuite::MLKEM768_MLDSA65.wire_id,
                public_key: initiator_identity.mlkem768_public_key.clone(),
            },
        ],
        Some("Rust".to_owned()),
        None,
    )?;
    let responder_bootstrap = WebRtcJoinBootstrap::new(
        responder_device_id,
        responder_identity.signing_algorithm,
        responder_fingerprint.clone(),
        responder_identity.signing_public_key.clone(),
        vec![
            BootstrapKemPublicKey {
                suite_wire_id: CryptoSuite::XWING_MLDSA.wire_id,
                public_key: responder_identity.xwing_public_key.clone(),
            },
            BootstrapKemPublicKey {
                suite_wire_id: CryptoSuite::MLKEM768_MLDSA65.wire_id,
                public_key: responder_identity.mlkem768_public_key.clone(),
            },
        ],
        Some("Rust".to_owned()),
        None,
    )?;
    let mut initiator = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "native-pqc-test".to_owned(),
        local_device_id: initiator_device_id.to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: None,
        classic_responder: None,
        pqc_initiator: Some(PqcInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                initiator_device_id,
                initiator_identity.signing_algorithm,
                initiator_identity.signing_public_key.clone(),
                None,
            )?,
            signing_secret_key: initiator_identity.signing_secret_key.clone(),
            local_device_name: Some("Rust PQC Initiator".to_owned()),
            preferred_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
            peer_kem_public_keys: BTreeMap::new(),
            policy: crate::DowngradePolicy::PreferPqc,
        }),
        pqc_responder: None,
    })
    .await?;
    let mut responder = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "native-pqc-test".to_owned(),
        local_device_id: responder_device_id.to_owned(),
        role: RuntimeSessionRole::Responder,
        turn_credentials: None,
        classic_initiator: None,
        classic_responder: None,
        pqc_initiator: None,
        pqc_responder: Some(PqcResponderConfig {
            local_binding: ProtocolIdentityBinding::new(
                responder_device_id,
                responder_identity.signing_algorithm,
                responder_identity.signing_public_key.clone(),
                None,
            )?,
            local_device_name: Some("Rust PQC Responder".to_owned()),
            identity: responder_identity,
            supported_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
            policy: crate::DowngradePolicy::PreferPqc,
        }),
    })
    .await?;

    initiator.start().await?;
    responder.start().await?;
    initiator
        .handle_signaling_envelope(&make_join_envelope(
            "native-pqc-test",
            responder_device_id,
            responder_bootstrap,
        )?)
        .await?;
    responder
        .handle_signaling_envelope(&make_join_envelope(
            "native-pqc-test",
            initiator_device_id,
            initiator_bootstrap,
        )?)
        .await?;

    let observed = timeout(
        Duration::from_secs(20),
        pump_events(&mut initiator, &mut responder, 2, 2),
    )
    .await
    .map_err(|_| anyhow!("native_webrtc_pqc_test_timeout"))??;

    let ready_count = observed
        .iter()
        .filter(|event| matches!(event, NativeWebRtcEvent::TransportReady))
        .count();
    let handshake_events = observed
        .iter()
        .filter_map(|event| match event {
            NativeWebRtcEvent::HandshakeComplete {
                negotiated_suite,
                peer_protocol_public_key_fingerprint,
            } => Some((
                negotiated_suite.as_str(),
                peer_protocol_public_key_fingerprint.as_str(),
            )),
            _ => None,
        })
        .collect::<Vec<_>>();

    assert_eq!(ready_count, 2, "observed events: {observed:?}");
    assert_eq!(handshake_events.len(), 2, "observed events: {observed:?}");
    assert!(
        handshake_events
            .iter()
            .all(|(suite, _)| { *suite == "X-Wing" || *suite == "ML-KEM-768" })
    );
    assert!(
        handshake_events
            .iter()
            .any(|(_, fingerprint)| *fingerprint == initiator_fingerprint)
    );
    assert!(
        handshake_events
            .iter()
            .any(|(_, fingerprint)| *fingerprint == responder_fingerprint)
    );
    assert!(
        observed
            .iter()
            .all(|event| !matches!(event, NativeWebRtcEvent::TransportDisconnected { .. }))
    );

    initiator.close().await?;
    responder.close().await?;
    Ok(())
}

#[tokio::test]
async fn native_webrtc_rejects_oversized_sdp_and_ice_fields_before_peer_processing() -> Result<()> {
    let (_, classic_responder) = classic_config_pair()?;
    let session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "bounded-signaling".to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Responder,
        turn_credentials: None,
        classic_initiator: None,
        classic_responder: Some(classic_responder),
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;

    let oversized_sdp = "v".repeat(MAX_SIGNALING_SDP_BYTES + 1);
    let sdp_error = session
        .handle_signaling_envelope(&WebRtcSignalingEnvelope {
            session_id: "bounded-signaling".to_owned(),
            from: "remote-device".to_owned(),
            to: Some("local-device".to_owned()),
            kind: WebRtcMessageType::Offer,
            payload: Some(Box::new(WebRtcSignalingPayload {
                sdp: Some(oversized_sdp),
                ..Default::default()
            })),
            auth_token: None,
            sent_at: 0.0,
        })
        .await
        .expect_err("oversized SDP must fail before WebRTC parsing");
    assert!(sdp_error.to_string().contains("exceeds byte limit"));

    let candidate_error = session
        .handle_signaling_envelope(&WebRtcSignalingEnvelope {
            session_id: "bounded-signaling".to_owned(),
            from: "remote-device".to_owned(),
            to: Some("local-device".to_owned()),
            kind: WebRtcMessageType::IceCandidate,
            payload: Some(Box::new(WebRtcSignalingPayload {
                candidate: Some("c".repeat(MAX_ICE_CANDIDATE_BYTES + 1)),
                sdp_mid: Some("0".to_owned()),
                sdp_m_line_index: Some(0),
                ..Default::default()
            })),
            auth_token: None,
            sent_at: 0.0,
        })
        .await
        .expect_err("oversized ICE candidate must fail before buffering");
    assert!(candidate_error.to_string().contains("exceeds byte limit"));

    let index_error = session
        .handle_signaling_envelope(&WebRtcSignalingEnvelope {
            session_id: "bounded-signaling".to_owned(),
            from: "remote-device".to_owned(),
            to: Some("local-device".to_owned()),
            kind: WebRtcMessageType::IceCandidate,
            payload: Some(Box::new(WebRtcSignalingPayload {
                candidate: Some("candidate:1 1 udp 1 127.0.0.1 9 typ host".to_owned()),
                sdp_mid: Some("0".to_owned()),
                sdp_m_line_index: Some(-1),
                ..Default::default()
            })),
            auth_token: None,
            sent_at: 0.0,
        })
        .await
        .expect_err("negative ICE m-line index must not be silently discarded");
    assert!(index_error.to_string().contains("out of range"));

    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn native_webrtc_bounds_pending_remote_ice_candidates() -> Result<()> {
    let (_, classic_responder) = classic_config_pair()?;
    let session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "bounded-pending-ice".to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Responder,
        turn_credentials: None,
        classic_initiator: None,
        classic_responder: Some(classic_responder),
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;

    for index in 0..MAX_REMOTE_ICE_CANDIDATES {
        let disposition = session
            .handle_signaling_envelope(&WebRtcSignalingEnvelope {
                session_id: "bounded-pending-ice".to_owned(),
                from: "remote-device".to_owned(),
                to: Some("local-device".to_owned()),
                kind: WebRtcMessageType::IceCandidate,
                payload: Some(Box::new(WebRtcSignalingPayload {
                    candidate: Some(format!("candidate:{index} 1 udp 1 127.0.0.1 9 typ host")),
                    sdp_mid: Some("0".to_owned()),
                    sdp_m_line_index: Some(0),
                    ..Default::default()
                })),
                auth_token: None,
                sent_at: 0.0,
            })
            .await?;
        assert_eq!(
            disposition,
            NativeWebRtcSignalingDisposition::AcceptedWithPeerBinding
        );
    }

    let overflow = session
        .handle_signaling_envelope(&WebRtcSignalingEnvelope {
            session_id: "bounded-pending-ice".to_owned(),
            from: "remote-device".to_owned(),
            to: Some("local-device".to_owned()),
            kind: WebRtcMessageType::IceCandidate,
            payload: Some(Box::new(WebRtcSignalingPayload {
                candidate: Some("candidate:overflow 1 udp 1 127.0.0.1 9 typ host".to_owned()),
                sdp_mid: Some("0".to_owned()),
                sdp_m_line_index: Some(0),
                ..Default::default()
            })),
            auth_token: None,
            sent_at: 0.0,
        })
        .await
        .expect_err("candidate beyond the bounded queue must be rejected");
    assert!(overflow.to_string().contains("candidate limit exceeded"));
    let state = session.inner.state.lock().await;
    assert_eq!(
        state.pending_remote_candidates.len(),
        MAX_REMOTE_ICE_CANDIDATES
    );
    drop(state);

    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn native_webrtc_rejects_unreadable_labels_and_duplicate_control_channels() -> Result<()> {
    let (classic_initiator, _) = classic_config_pair()?;
    let session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "control-channel-uniqueness".to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: Some(classic_initiator),
        classic_responder: None,
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;

    let unreadable = Arc::new(TestDataChannel::new(10, None, false));
    let unreadable_channel: Arc<dyn DataChannel> = unreadable.clone();
    let label_error = session
        .inner
        .attach_data_channel(unreadable_channel)
        .await
        .expect_err("unreadable label must be rejected");
    assert!(label_error.to_string().contains("label_read_failed"));
    assert_eq!(unreadable.close_count.load(Ordering::SeqCst), 1);

    let empty_label = Arc::new(TestDataChannel::new(13, Some(""), false));
    let empty_label_channel: Arc<dyn DataChannel> = empty_label;
    let open_error = session
        .inner
        .validate_open_control_channel_label(&empty_label_channel)
        .await
        .expect_err("an empty label must be rejected before opening the control channel");
    assert!(
        open_error
            .to_string()
            .contains("unexpected_data_channel_label")
    );

    let primary = Arc::new(TestDataChannel::new(11, Some(CONTROL_CHANNEL_LABEL), false));
    let primary_channel: Arc<dyn DataChannel> = primary.clone();
    session.inner.attach_data_channel(primary_channel).await?;

    let repeated_callback = Arc::new(TestDataChannel::new(11, Some(CONTROL_CHANNEL_LABEL), false));
    let repeated_callback_channel: Arc<dyn DataChannel> = repeated_callback.clone();
    session
        .inner
        .attach_data_channel(repeated_callback_channel)
        .await?;
    assert_eq!(repeated_callback.close_count.load(Ordering::SeqCst), 0);

    let duplicate = Arc::new(TestDataChannel::new(12, Some(CONTROL_CHANNEL_LABEL), false));
    let duplicate_channel: Arc<dyn DataChannel> = duplicate.clone();
    let duplicate_error = session
        .inner
        .attach_data_channel(duplicate_channel)
        .await
        .expect_err("duplicate control channel must be rejected");
    assert!(duplicate_error.to_string().contains("duplicate_control"));
    assert_eq!(duplicate.close_count.load(Ordering::SeqCst), 1);
    let attached = session.inner.data_channel.lock().await;
    assert!(attached.as_ref().is_some_and(|value| {
        let primary_trait: Arc<dyn DataChannel> = primary.clone();
        Arc::ptr_eq(value, &primary_trait)
    }));
    drop(attached);

    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn native_webrtc_rejects_text_control_messages_and_unbounded_framing() -> Result<()> {
    let (classic_initiator, _) = classic_config_pair()?;
    let session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "bounded-framing".to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: Some(classic_initiator),
        classic_responder: None,
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;

    let text_error = session
        .inner
        .handle_data_channel_message(RTCDataChannelMessage {
            is_string: true,
            data: BytesMut::from(&b"not-binary-framing"[..]),
        })
        .await
        .expect_err("text message must not enter the binary frame buffer");
    assert!(text_error.to_string().contains("text_message_rejected"));

    let oversized_chunk = vec![0_u8; MAX_INBOUND_FRAMED_BUFFER_BYTES + 1];
    let buffer_error = session
        .inner
        .append_inbound_chunk(&oversized_chunk)
        .await
        .expect_err("framing buffer must reject growth beyond its limit");
    assert!(buffer_error.to_string().contains("buffer limit exceeded"));

    let invalid_length = u32::try_from(MAX_FRAMED_PAYLOAD_BYTES + 1)?.to_be_bytes();
    session.inner.append_inbound_chunk(&invalid_length).await?;
    let length_error = session
        .inner
        .take_next_inbound_frame()
        .await
        .expect_err("oversized declared frame length must be rejected");
    assert!(
        length_error
            .to_string()
            .contains("invalid framed payload length")
    );
    session.inner.clear_inbound_frame_buffer().await;

    let mut tiny_frame_flood = BytesMut::new();
    for _ in 0..(MAX_INBOUND_FRAMES_PER_DATA_MESSAGE + 32) {
        tiny_frame_flood.extend_from_slice(&1_u32.to_be_bytes());
        tiny_frame_flood.extend_from_slice(&[0xff]);
    }
    session
        .inner
        .handle_data_channel_message(RTCDataChannelMessage {
            is_string: false,
            data: tiny_frame_flood,
        })
        .await
        .expect_err("the first invalid tiny frame must stop parsing the remaining flood");
    assert!(
        session
            .inner
            .state
            .lock()
            .await
            .inbound_framed_buffer
            .is_empty()
    );

    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn heartbeat_send_failure_emits_disconnect_and_clears_live_state() -> Result<()> {
    let (classic_initiator, _) = classic_config_pair()?;
    let (established_handshake, established_keys) = established_classic_initiator()?;
    let mut session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "heartbeat-send-failure".to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: Some(classic_initiator),
        classic_responder: None,
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;
    let failing = Arc::new(TestDataChannel::new(20, Some(CONTROL_CHANNEL_LABEL), true));
    let failing_channel: Arc<dyn DataChannel> = failing.clone();
    *session.inner.data_channel.lock().await = Some(failing_channel);
    {
        let mut state = session.inner.state.lock().await;
        state.handshake = Some(established_handshake);
        state.app_secure_runtime = Some(NativeAppSecureRuntime::new(established_keys));
    }

    session.inner.ensure_heartbeat_task().await?;
    let event = timeout(Duration::from_secs(2), session.next_event())
        .await
        .map_err(|_| anyhow!("disconnect event timeout"))?
        .ok_or_else(|| anyhow!("native event stream ended before disconnect"))?;
    let NativeWebRtcEvent::TransportDisconnected { reason } = event else {
        return Err(anyhow!("expected disconnect after heartbeat send failure"));
    };
    assert!(
        reason
            .as_deref()
            .is_some_and(|value| value.contains("keepalive_failed"))
    );
    assert_eq!(failing.send_count.load(Ordering::SeqCst), 1);
    let state = session.inner.state.lock().await;
    assert!(!state.heartbeat_task_started);
    assert!(state.app_secure_runtime.is_none());
    assert!(state.outstanding_ping.is_none());
    assert!(state.transport_disconnected_emitted);
    drop(state);
    assert!(session.inner.data_channel.lock().await.is_none());

    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn foreground_framed_send_timeout_returns_error_without_faking_disconnect() -> Result<()> {
    let (classic_initiator, _) = classic_config_pair()?;
    let session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "foreground-send-timeout".to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: Some(classic_initiator),
        classic_responder: None,
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;
    let never_resolving = Arc::new(TestDataChannel::never_resolving_send(
        21,
        Some(CONTROL_CHANNEL_LABEL),
    ));
    let channel: Arc<dyn DataChannel> = never_resolving.clone();

    let error = timeout(
        Duration::from_secs(1),
        session.inner.send_framed_payload_with_timeout(
            &channel,
            b"foreground-payload",
            Duration::from_millis(20),
        ),
    )
    .await
    .map_err(|_| anyhow!("bounded framed send test did not finish"))?
    .expect_err("never-resolving data channel send must time out");
    assert_eq!(error.to_string(), "data_channel_send_timeout");
    assert_eq!(never_resolving.send_count.load(Ordering::SeqCst), 1);
    assert!(
        !session
            .inner
            .state
            .lock()
            .await
            .transport_disconnected_emitted
    );

    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn outbound_frame_gate_prevents_concurrent_chunk_interleaving() -> Result<()> {
    let session = native_test_initiator("outbound-frame-gate").await?;
    let captured = Arc::new(TestDataChannel::capturing(
        30,
        Some(CONTROL_CHANNEL_LABEL),
        Duration::from_millis(1),
    ));
    let first_channel: Arc<dyn DataChannel> = captured.clone();
    let second_channel: Arc<dyn DataChannel> = captured.clone();
    let first_inner = Arc::clone(&session.inner);
    let second_inner = Arc::clone(&session.inner);
    let first_payload = vec![0x11; 18_000];
    let second_payload = vec![0x22; 18_000];

    let (first, second) = tokio::join!(
        first_inner.send_framed_payload(&first_channel, &first_payload),
        second_inner.send_framed_payload(&second_channel, &second_payload),
    );
    first?;
    second?;

    let chunks = captured.captured_chunks();
    assert!(
        chunks
            .iter()
            .all(|chunk| chunk.len() <= DATA_CHANNEL_FRAME_CHUNK_BYTES)
    );
    let stream = chunks.concat();
    let mut first_frame = Vec::with_capacity(first_payload.len() + 4);
    first_frame.extend_from_slice(&(first_payload.len() as u32).to_be_bytes());
    first_frame.extend_from_slice(&first_payload);
    let mut second_frame = Vec::with_capacity(second_payload.len() + 4);
    second_frame.extend_from_slice(&(second_payload.len() as u32).to_be_bytes());
    second_frame.extend_from_slice(&second_payload);
    let mut first_then_second = first_frame.clone();
    first_then_second.extend_from_slice(&second_frame);
    let mut second_then_first = second_frame;
    second_then_first.extend_from_slice(&first_frame);
    assert!(stream == first_then_second || stream == second_then_first);

    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn outbound_framing_accepts_exact_cap_rejects_overflow_and_chunks_to_8k() -> Result<()> {
    let session = native_test_initiator("outbound-frame-boundary").await?;
    let channel_impl = Arc::new(TestDataChannel::new(31, Some(CONTROL_CHANNEL_LABEL), false));
    let channel: Arc<dyn DataChannel> = channel_impl.clone();
    let boundary = vec![0x5a; MAX_FRAMED_PAYLOAD_BYTES];
    session
        .inner
        .send_framed_payload_with_timeout(&channel, &boundary, Duration::from_secs(10))
        .await?;
    let expected_chunks = (MAX_FRAMED_PAYLOAD_BYTES + 4).div_ceil(DATA_CHANNEL_FRAME_CHUNK_BYTES);
    assert_eq!(
        channel_impl.send_count.load(Ordering::SeqCst),
        expected_chunks
    );
    assert!(channel_impl.max_send_bytes.load(Ordering::SeqCst) <= DATA_CHANNEL_FRAME_CHUNK_BYTES);

    let count_before_rejection = channel_impl.send_count.load(Ordering::SeqCst);
    let oversized = vec![0u8; MAX_FRAMED_PAYLOAD_BYTES + 1];
    let error = session
        .inner
        .send_framed_payload(&channel, &oversized)
        .await
        .expect_err("payload above the exact transport cap must fail");
    assert!(
        error
            .to_string()
            .contains("invalid outbound framed payload length")
    );
    assert_eq!(
        channel_impl.send_count.load(Ordering::SeqCst),
        count_before_rejection
    );

    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn outbound_frame_deadline_covers_all_chunks_and_partial_timeout_disconnects() -> Result<()> {
    let session = native_test_initiator("outbound-frame-total-deadline").await?;
    let delayed = Arc::new(TestDataChannel::delayed(
        32,
        Some(CONTROL_CHANNEL_LABEL),
        Duration::from_millis(10),
    ));
    let channel: Arc<dyn DataChannel> = delayed.clone();
    let payload = vec![0x33; DATA_CHANNEL_FRAME_CHUNK_BYTES * 3];
    let error = session
        .inner
        .send_framed_payload_with_timeout(&channel, &payload, Duration::from_millis(25))
        .await
        .expect_err("one total deadline must bound the complete frame");
    assert_eq!(error.to_string(), "data_channel_send_timeout");
    let send_count = delayed.send_count.load(Ordering::SeqCst);
    assert!((2..=3).contains(&send_count));
    assert!(
        session
            .inner
            .state
            .lock()
            .await
            .transport_disconnected_emitted
    );

    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn sbwc_counter_is_shared_exhaustive_and_never_reused_after_send_failure() -> Result<()> {
    let session = native_test_initiator("sbwc-counter").await?;
    let (_, keys) = established_classic_initiator()?;
    {
        let mut state = session.inner.state.lock().await;
        state.app_secure_runtime = Some(NativeAppSecureRuntime::new(keys));
    }

    let heartbeat = crate::handshake_app_frame::build_heartbeat_plaintext("local-device", None)?;
    session
        .inner
        .seal_authenticated_payload(WebRtcAppSecurePacketType::AppControl, &heartbeat)
        .await?;
    let file = encode_cross_network_file_transfer_message_v1(
        &CrossNetworkFileTransferMessageV1::MetadataAck {
            transfer_id: CrossNetworkTransferId::parse("71717171-7171-4171-8171-717171717171")?,
        },
    )?;
    session
        .inner
        .seal_authenticated_payload(WebRtcAppSecurePacketType::FileTransfer, &file)
        .await?;

    let failing = Arc::new(TestDataChannel::new(33, Some(CONTROL_CHANNEL_LABEL), true));
    let failing_channel: Arc<dyn DataChannel> = failing;
    *session.inner.data_channel.lock().await = Some(failing_channel);
    assert!(session.inner.send_file_app_frame(&file).await.is_err());
    assert!(session.inner.send_file_app_frame(&file).await.is_err());
    {
        let mut state = session.inner.state.lock().await;
        let runtime = state
            .app_secure_runtime
            .as_mut()
            .ok_or_else(|| anyhow!("SBWC runtime missing"))?;
        assert_eq!(runtime.last_send_counter, 4);
        runtime.last_send_counter = u64::MAX;
    }
    let exhausted = session
        .inner
        .seal_authenticated_payload(WebRtcAppSecurePacketType::AppControl, &heartbeat)
        .await
        .expect_err("counter exhaustion must fail closed");
    assert!(exhausted.to_string().contains("counter exhausted"));

    session.close().await?;
    Ok(())
}

#[test]
fn sbwc_replay_is_recorded_only_after_successful_authentication() -> Result<()> {
    let (_, initiator_keys) = established_classic_initiator()?;
    let mut responder_keys = initiator_keys.clone();
    std::mem::swap(
        &mut responder_keys.send_key,
        &mut responder_keys.receive_key,
    );
    let mut sender = NativeAppSecureRuntime::new(initiator_keys);
    let mut receiver = NativeAppSecureRuntime::new(responder_keys);
    let plaintext = crate::handshake_app_frame::build_ping_plaintext(9)?;
    let packet = sender.seal(
        RuntimeSessionRole::Initiator,
        WebRtcAppSecurePacketType::AppControl,
        &plaintext,
    )?;
    let mut tampered = packet.clone();
    *tampered.last_mut().ok_or_else(|| anyhow!("missing tag"))? ^= 1;
    assert!(
        receiver
            .open_and_record(RuntimeSessionRole::Responder, &tampered)
            .is_err()
    );
    receiver.open_and_record(RuntimeSessionRole::Responder, &packet)?;
    let duplicate = receiver
        .open_and_record(RuntimeSessionRole::Responder, &packet)
        .expect_err("authenticated duplicate must be rejected");
    assert!(duplicate.to_string().contains("duplicate-counter"));
    Ok(())
}

#[tokio::test]
async fn native_setup_timeout_cancels_stalled_operation_and_releases_resources() -> Result<()> {
    let dropped = Arc::new(AtomicBool::new(false));
    let probe = SetupDropProbe(Arc::clone(&dropped));
    let error = timeout(
        Duration::from_secs(1),
        run_native_setup_with_timeout(
            "stalled_native_setup",
            Duration::from_millis(20),
            async move {
                let _probe = probe;
                pending::<Result<()>>().await
            },
        ),
    )
    .await
    .map_err(|_| anyhow!("native setup deadline test did not finish"))?
    .expect_err("stalled native setup must time out");
    assert_eq!(error.to_string(), "stalled_native_setup_timeout");
    assert!(dropped.load(Ordering::SeqCst));
    Ok(())
}

#[tokio::test]
async fn background_framed_send_timeout_clears_live_state_and_disconnects() -> Result<()> {
    let (classic_initiator, _) = classic_config_pair()?;
    let mut session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "background-send-timeout".to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: Some(classic_initiator),
        classic_responder: None,
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;
    {
        let mut state = session.inner.state.lock().await;
        state.heartbeat_task_started = true;
        state.app_secure_runtime = Some(NativeAppSecureRuntime::new(ClassicSessionKeys {
            send_key: vec![0x11; 32],
            receive_key: vec![0x22; 32],
            negotiated_suite: "test-suite".to_owned(),
            peer_protocol_public_key_fingerprint: "test-fingerprint".to_owned(),
            transcript_hash: vec![0x33; 32],
        }));
    }
    let never_resolving = Arc::new(TestDataChannel::never_resolving_send(
        22,
        Some(CONTROL_CHANNEL_LABEL),
    ));
    let channel: Arc<dyn DataChannel> = never_resolving.clone();
    let worker_inner = Arc::clone(&session.inner);
    let heartbeat_handle = tokio::spawn(async move {
        worker_inner
            .send_framed_payload_with_timeout(
                &channel,
                b"background-payload",
                Duration::from_millis(20),
            )
            .await
    });

    Arc::clone(&session.inner)
        .monitor_keepalive_task(heartbeat_handle)
        .await;
    let event = timeout(Duration::from_secs(1), session.next_event())
        .await
        .map_err(|_| anyhow!("disconnect event timeout"))?
        .ok_or_else(|| anyhow!("native event stream ended before disconnect"))?;
    let NativeWebRtcEvent::TransportDisconnected { reason } = event else {
        return Err(anyhow!("expected disconnect after background send timeout"));
    };
    assert!(
        reason
            .as_deref()
            .is_some_and(|value| value.contains("data_channel_send_timeout"))
    );
    assert_eq!(never_resolving.send_count.load(Ordering::SeqCst), 1);
    let state = session.inner.state.lock().await;
    assert!(!state.heartbeat_task_started);
    assert!(state.app_secure_runtime.is_none());
    assert!(state.transport_disconnected_emitted);
    drop(state);

    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn heartbeat_task_panic_is_observed_as_transport_disconnect() -> Result<()> {
    let (classic_initiator, _) = classic_config_pair()?;
    let mut session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "heartbeat-task-panic".to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: Some(classic_initiator),
        classic_responder: None,
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;
    session.inner.state.lock().await.heartbeat_task_started = true;
    let heartbeat_handle: tokio::task::JoinHandle<Result<()>> = tokio::spawn(async move {
        if std::hint::black_box(true) {
            panic!("simulated keepalive worker panic");
        }
        Ok(())
    });

    Arc::clone(&session.inner)
        .monitor_keepalive_task(heartbeat_handle)
        .await;
    let event = timeout(Duration::from_secs(1), session.next_event())
        .await
        .map_err(|_| anyhow!("disconnect event timeout"))?
        .ok_or_else(|| anyhow!("native event stream ended before disconnect"))?;
    let NativeWebRtcEvent::TransportDisconnected { reason } = event else {
        return Err(anyhow!("expected disconnect after keepalive task panic"));
    };
    assert!(
        reason
            .as_deref()
            .is_some_and(|value| value.contains("keepalive_task_join_failed"))
    );
    let state = session.inner.state.lock().await;
    assert!(!state.heartbeat_task_started);
    assert!(state.transport_disconnected_emitted);
    drop(state);

    session.close().await?;
    Ok(())
}

#[tokio::test]
async fn expired_or_mismatched_pong_never_preserves_false_liveness() -> Result<()> {
    let (classic_initiator, _) = classic_config_pair()?;
    let session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "pong-validation".to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: Some(classic_initiator),
        classic_responder: None,
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;
    {
        let mut state = session.inner.state.lock().await;
        state.outstanding_ping = Some(OutstandingPing {
            id: 7,
            sent_at: Instant::now() - PONG_TIMEOUT,
        });
    }
    let timeout_error = session
        .inner
        .reject_expired_outstanding_ping()
        .await
        .expect_err("expired outstanding pong must fail liveness");
    assert!(timeout_error.to_string().contains("pong_timeout"));
    let late_pong = session
        .inner
        .acknowledge_outstanding_pong(7)
        .await
        .expect_err("a pong received after the deadline must not restore liveness");
    assert!(late_pong.to_string().contains("pong_timeout"));

    {
        let mut state = session.inner.state.lock().await;
        state.outstanding_ping = Some(OutstandingPing {
            id: 7,
            sent_at: Instant::now(),
        });
    }

    let mismatch = session
        .inner
        .acknowledge_outstanding_pong(8)
        .await
        .expect_err("mismatched pong must not clear the outstanding ping");
    assert!(mismatch.to_string().contains("unexpected_keepalive_pong"));
    assert_eq!(
        session
            .inner
            .state
            .lock()
            .await
            .outstanding_ping
            .map(|ping| ping.id),
        Some(7)
    );
    session.inner.acknowledge_outstanding_pong(7).await?;
    assert!(session.inner.state.lock().await.outstanding_ping.is_none());

    session.close().await?;
    Ok(())
}
