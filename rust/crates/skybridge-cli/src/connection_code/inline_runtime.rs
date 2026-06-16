use anyhow::Result;
use skybridge_agent::{AgentPaths, load_session_registry, store_session_registry};
use skybridge_core::{
    InboundMessage, NativeWebRtcEvent, NativeWebRtcSession, RuntimeSessionState,
    RuntimeSessionTransportEvent, SignalingConnection, SignalingLifecycleEvent,
};

pub(super) async fn drain_inline_native_events(
    paths: &AgentPaths,
    connection: &SignalingConnection,
    session_id: &str,
    native_session: &mut NativeWebRtcSession,
) -> Result<()> {
    while let Some(event) = native_session.try_next_event() {
        apply_inline_native_event(paths, connection, session_id, event).await?;
    }
    Ok(())
}

pub(super) async fn apply_runtime_session_event(
    paths: &AgentPaths,
    session_id: &str,
    event: &SignalingLifecycleEvent,
) -> Result<()> {
    let mut registry = load_session_registry(paths).await?;
    registry.apply_signaling_event(session_id, event);
    store_session_registry(paths, &registry).await
}

pub(super) async fn apply_inline_inbound_runtime_event(
    paths: &AgentPaths,
    session_id: &str,
    inbound: InboundMessage,
    native_session: &NativeWebRtcSession,
) -> Result<()> {
    match inbound {
        InboundMessage::Envelope(envelope) => {
            let mut registry = load_session_registry(paths).await?;
            registry.update_remote_peer(session_id, envelope.from.clone(), None, None);
            store_session_registry(paths, &registry).await?;
            native_session.handle_signaling_envelope(&envelope).await?;
        }
        InboundMessage::ServerFrame(_) | InboundMessage::Unknown => {}
    }
    Ok(())
}

pub(super) async fn apply_inline_native_event(
    paths: &AgentPaths,
    connection: &SignalingConnection,
    session_id: &str,
    event: NativeWebRtcEvent,
) -> Result<()> {
    match event {
        NativeWebRtcEvent::SignalingEnvelope(envelope) => {
            connection.send(envelope).await?;
        }
        NativeWebRtcEvent::TransportReady => {
            let mut registry = load_session_registry(paths).await?;
            registry
                .apply_transport_event(session_id, RuntimeSessionTransportEvent::TransportReady);
            store_session_registry(paths, &registry).await?;
        }
        NativeWebRtcEvent::HandshakeComplete { negotiated_suite } => {
            let mut registry = load_session_registry(paths).await?;
            registry.apply_transport_event(
                session_id,
                RuntimeSessionTransportEvent::HandshakeComplete { negotiated_suite },
            );
            store_session_registry(paths, &registry).await?;
        }
        NativeWebRtcEvent::Keepalive { kind, ping_id } => {
            let mut registry = load_session_registry(paths).await?;
            registry.apply_transport_event(
                session_id,
                RuntimeSessionTransportEvent::Keepalive { kind, ping_id },
            );
            store_session_registry(paths, &registry).await?;
        }
        NativeWebRtcEvent::TransportDisconnected { reason } => {
            let mut registry = load_session_registry(paths).await?;
            registry.apply_transport_event(
                session_id,
                RuntimeSessionTransportEvent::TransportDisconnected { reason },
            );
            store_session_registry(paths, &registry).await?;
        }
        NativeWebRtcEvent::InboundFileFrame(_) => {
            // The inline connect path is not a file-transfer endpoint; live
            // transfers are owned by the long-running managed agent runtime.
        }
    }
    Ok(())
}

pub(super) async fn should_stop_inline_connect(
    paths: &AgentPaths,
    session_id: &str,
    signaling_stream_closed: bool,
) -> Result<bool> {
    let registry = load_session_registry(paths).await?;
    let Some(record) = registry.get(session_id) else {
        return Ok(true);
    };
    if matches!(
        record.state,
        RuntimeSessionState::Disconnected | RuntimeSessionState::Failed
    ) {
        return Ok(true);
    }
    if signaling_stream_closed && !record.readiness.is_transport_established_for(session_id) {
        return Ok(true);
    }
    Ok(false)
}
