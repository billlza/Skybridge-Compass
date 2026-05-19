use skybridge_core::{
    RuntimeSessionKeepaliveStatus, RuntimeSessionRecord, RuntimeSessionState, SessionReadiness,
};

pub(super) fn describe_readiness(readiness: &SessionReadiness) -> String {
    match readiness {
        SessionReadiness::Idle => "idle".to_owned(),
        SessionReadiness::TransportReady { session_id } => {
            format!("transport_ready({session_id})")
        }
        SessionReadiness::HandshakeComplete {
            session_id,
            negotiated_suite,
        } => format!("handshake_complete({session_id}, suite={negotiated_suite})"),
    }
}

pub(super) fn describe_runtime_readiness(session: &RuntimeSessionRecord) -> String {
    let current = describe_readiness(&session.readiness);
    match session.last_established_readiness.as_ref() {
        Some(last_established) if session.readiness != *last_established => format!(
            "{current} (last_established={})",
            describe_readiness(last_established)
        ),
        _ => current,
    }
}

pub(super) fn describe_terminal_runtime_summary(session: &RuntimeSessionRecord) -> Option<String> {
    if !matches!(
        session.state,
        RuntimeSessionState::Disconnected | RuntimeSessionState::Failed
    ) {
        return None;
    }

    let phase = match session.state {
        RuntimeSessionState::Disconnected => "disconnected",
        RuntimeSessionState::Failed => "failed",
        _ => unreachable!("non-terminal session state passed to terminal summary"),
    };
    let mut summary = match session.effective_established_readiness() {
        Some(readiness) => format!("{phase} after {}", describe_readiness(readiness)),
        None => format!("{phase} before transport became ready"),
    };
    if let Some(reason) = session
        .last_transport_error
        .as_deref()
        .or(session.last_error.as_deref())
    {
        summary.push_str(&format!(" (reason={reason})"));
    }
    Some(summary)
}

pub(super) fn describe_keepalive_brief(keepalive: &RuntimeSessionKeepaliveStatus) -> String {
    let mut summary = format!(
        "hb {}/{} ping {} pong {} replied {}",
        keepalive.heartbeat_sent_count,
        keepalive.heartbeat_received_count,
        keepalive.ping_sent_count,
        keepalive.pong_received_count,
        keepalive.pong_replied_count,
    );
    if let Some(ping_id) = keepalive.last_ping_id {
        summary.push_str(&format!(" last_ping={ping_id}"));
    }
    if let Some(pong_id) = keepalive.last_pong_id {
        summary.push_str(&format!(" last_pong={pong_id}"));
    }
    if let Some(last_activity_at) = keepalive.last_activity_at {
        summary.push_str(&format!(" active={last_activity_at}"));
    }
    summary
}
