use std::collections::BTreeMap;
use std::time::Duration;

use anyhow::{Result, anyhow};
use tokio::time::timeout;

use super::*;
use crate::{
    CryptoSuite, PqcInitiatorConfig, PqcResponderConfig, ProtocolIdentityBinding,
    RustPqcIdentityMaterial,
};

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
                        NativeWebRtcEvent::SignalingEnvelope(envelope) => responder.handle_signaling_envelope(envelope).await?,
                        NativeWebRtcEvent::TransportReady => {
                            ready_count += 1;
                            observed.push(event);
                        }
                        NativeWebRtcEvent::HandshakeComplete { .. } => {
                            handshake_count += 1;
                            observed.push(event);
                        }
                        NativeWebRtcEvent::Keepalive { .. } => {}
                        NativeWebRtcEvent::TransportDisconnected { .. } => observed.push(event),
                        NativeWebRtcEvent::InboundFileFrame(_) => {}
                    }
                }
            }
            event = responder.next_event() => {
                if let Some(event) = event {
                    match &event {
                        NativeWebRtcEvent::SignalingEnvelope(envelope) => initiator.handle_signaling_envelope(envelope).await?,
                        NativeWebRtcEvent::TransportReady => {
                            ready_count += 1;
                            observed.push(event);
                        }
                        NativeWebRtcEvent::HandshakeComplete { .. } => {
                            handshake_count += 1;
                            observed.push(event);
                        }
                        NativeWebRtcEvent::Keepalive { .. } => {}
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
async fn native_webrtc_marks_ready_from_real_data_channel_open_without_faking_handshake()
-> Result<()> {
    let mut initiator = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "native-test".to_owned(),
        local_device_id: "device-a".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: None,
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
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await?;

    initiator.start().await?;
    responder.start().await?;
    initiator.notify_remote_join("device-b").await?;

    let observed = timeout(
        Duration::from_secs(15),
        pump_events(&mut initiator, &mut responder, 2, 0),
    )
    .await
    .map_err(|_| anyhow!("native_webrtc_test_timeout"))??;

    let ready_count = observed
        .iter()
        .filter(|event| matches!(event, NativeWebRtcEvent::TransportReady))
        .count();
    let handshake_count = observed
        .iter()
        .filter(|event| matches!(event, NativeWebRtcEvent::HandshakeComplete { .. }))
        .count();

    assert_eq!(ready_count, 2);
    assert_eq!(handshake_count, 0);
    assert!(
        observed
            .iter()
            .all(|event| { !matches!(event, NativeWebRtcEvent::TransportDisconnected { .. }) })
    );

    initiator.close().await?;
    responder.close().await?;
    Ok(())
}

#[tokio::test]
async fn native_webrtc_completes_rust_to_rust_pqc_handshake() -> Result<()> {
    let initiator_identity = RustPqcIdentityMaterial::generate()?;
    let responder_identity = RustPqcIdentityMaterial::generate()?;
    let mut initiator = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "native-pqc-test".to_owned(),
        local_device_id: "device-a".to_owned(),
        role: RuntimeSessionRole::Initiator,
        turn_credentials: None,
        classic_initiator: None,
        pqc_initiator: Some(PqcInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-1234567890abcd",
                initiator_identity.signing_algorithm,
                initiator_identity.signing_public_key.clone(),
                None,
            )?,
            signing_secret_key: initiator_identity.signing_secret_key.clone(),
            local_device_name: Some("Rust PQC Initiator".to_owned()),
            preferred_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
            peer_kem_public_keys: BTreeMap::from([
                (
                    CryptoSuite::XWING_MLDSA,
                    responder_identity.xwing_public_key.clone(),
                ),
                (
                    CryptoSuite::MLKEM768_MLDSA65,
                    responder_identity.mlkem768_public_key.clone(),
                ),
            ]),
        }),
        pqc_responder: None,
    })
    .await?;
    let mut responder = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "native-pqc-test".to_owned(),
        local_device_id: "device-b".to_owned(),
        role: RuntimeSessionRole::Responder,
        turn_credentials: None,
        classic_initiator: None,
        pqc_initiator: None,
        pqc_responder: Some(PqcResponderConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-fedcba0987654321",
                responder_identity.signing_algorithm,
                responder_identity.signing_public_key.clone(),
                None,
            )?,
            local_device_name: Some("Rust PQC Responder".to_owned()),
            identity: responder_identity,
            supported_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
        }),
    })
    .await?;

    initiator.start().await?;
    responder.start().await?;
    initiator.notify_remote_join("device-b").await?;

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
            NativeWebRtcEvent::HandshakeComplete { negotiated_suite } => {
                Some(negotiated_suite.as_str())
            }
            _ => None,
        })
        .collect::<Vec<_>>();

    assert_eq!(ready_count, 2);
    assert_eq!(handshake_events.len(), 2);
    assert!(
        handshake_events
            .iter()
            .all(|suite| { *suite == "X-Wing" || *suite == "ML-KEM-768" })
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
