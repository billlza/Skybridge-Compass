use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use serde::Serialize;
use skybridge_agent::{
    ManagedSessionRegistrationObservation, ensure_device_identity,
    observe_managed_session_registration, register_managed_session, resolve_paths,
    verify_managed_handshake_receipt,
};
use skybridge_core::{
    ManagedSessionControl, RuntimeAuthenticatedPeerObservation, RuntimeSelectedIceRouteObservation,
    RuntimeSessionRecord, RuntimeSessionRole, RuntimeSessionRouteKind, RuntimeSessionSource,
    RuntimeSessionState, SessionReadiness, SignalServerClient, make_runtime_id,
};
use time::OffsetDateTime;

use crate::{ConnectCommand, agent_runtime_guard, auth_support};

const CONNECT_SCHEMA_VERSION: u32 = 2;
const CONNECT_CAPABILITY_ID: &str = "native.connect";
const CONNECT_RUNTIME_OWNER: &str = "skybridge-agent";
const CONNECT_POLL_INTERVAL: Duration = Duration::from_millis(100);
const CONNECT_EVIDENCE_FRESHNESS: time::Duration = time::Duration::seconds(15);

#[derive(Debug, Serialize)]
struct ConnectSuccessReport {
    schema_version: u32,
    capability_id: &'static str,
    success: bool,
    status: &'static str,
    runtime_owner: &'static str,
    session_id: String,
    peer: ConnectPeerReport,
    security: ConnectSecurityReport,
    features: ConnectFeaturesReport,
}

#[derive(Debug, Serialize)]
struct ConnectPeerReport {
    device_id: String,
    name: Option<String>,
    name_source: &'static str,
    platform: Option<String>,
    ip: String,
    ip_observed: bool,
    ip_source: &'static str,
    ip_semantics: &'static str,
    port: u16,
    transport: String,
    route_kind: &'static str,
}

#[derive(Debug, Serialize)]
struct ConnectSecurityReport {
    handshake_complete: bool,
    protocol_identity_bound: bool,
    negotiated_suite: String,
    suite_source: &'static str,
}

#[derive(Debug, Serialize)]
struct ConnectFeaturesReport {
    observed: bool,
    source: &'static str,
    values: Vec<String>,
    file_transfer_port: Option<u16>,
    remote_control_port: Option<u16>,
}

#[derive(Debug, Serialize)]
struct ConnectFailureReport<'a> {
    schema_version: u32,
    capability_id: &'static str,
    success: bool,
    status: &'static str,
    runtime_owner: &'static str,
    session_id: Option<&'a str>,
    cleanup_completed: bool,
    cleanup_applied: bool,
    error: ConnectErrorReport<'a>,
}

#[derive(Debug, Serialize)]
struct ConnectErrorReport<'a> {
    code: &'a str,
    message: &'a str,
    retryable: bool,
}

#[derive(Debug, PartialEq, Eq)]
enum ConnectWaitDecision {
    Pending,
    Complete {
        runtime_id: String,
        negotiated_suite: String,
    },
    Failed(ConnectAttemptFailure),
}

#[derive(Debug, PartialEq, Eq)]
struct ConnectHandshakeObservation {
    runtime_id: String,
    negotiated_suite: String,
}

#[derive(Debug, PartialEq, Eq)]
struct ConnectAttemptFailure {
    code: &'static str,
    message: String,
    retryable: bool,
}

impl ConnectAttemptFailure {
    fn from_agent_guard(error: agent_runtime_guard::AgentRuntimeGuardError) -> Self {
        Self {
            code: error.code,
            message: error.message,
            retryable: error.retryable,
        }
    }

    fn session_state_unavailable(_error: &anyhow::Error) -> Self {
        Self {
            code: "session_state_unavailable",
            message: "failed to read the agent-owned session and registration authority".to_owned(),
            retryable: true,
        }
    }

    fn session_registration_failed() -> Self {
        Self {
            code: "session_registration_failed",
            message: "failed to register the agent-owned session transaction".to_owned(),
            retryable: true,
        }
    }

    fn session_missing(session_id: &str) -> Self {
        Self {
            code: "session_missing",
            message: format!("agent-owned session `{session_id}` disappeared before handshake"),
            retryable: false,
        }
    }

    fn session_registration_replaced(session_id: &str) -> Self {
        Self {
            code: "session_registration_replaced",
            message: format!(
                "agent-owned session `{session_id}` was replaced by another registration before this connection attempt completed"
            ),
            retryable: true,
        }
    }

    fn handshake_receipt_changed() -> Self {
        Self {
            code: "handshake_receipt_changed",
            message: "managed handshake authority changed before success could be reported"
                .to_owned(),
            retryable: true,
        }
    }

    fn handshake_failed(session_id: &str, state: RuntimeSessionState) -> Self {
        Self {
            code: "handshake_failed",
            message: format!(
                "session `{session_id}` entered terminal state `{}` before handshake completed",
                runtime_state_label(state)
            ),
            retryable: true,
        }
    }

    fn timeout(session_id: &str, timeout: Duration) -> Self {
        Self {
            code: "connection_ready_timeout",
            message: format!(
                "session `{session_id}` did not reach ready state with handshake, authenticated peer capabilities, and selected ICE route within {} seconds",
                timeout.as_secs()
            ),
            retryable: true,
        }
    }
}

pub(crate) async fn connect_code(state_dir: Option<PathBuf>, args: ConnectCommand) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    require_agent_active(&paths, args.json).await?;

    let auth_session = auth_support::require_auth_session(&paths).await?;
    let tenant_id = auth_support::require_tenant_id(&auth_session)?;
    let identity = ensure_device_identity(&paths).await?;
    let signal_server = SignalServerClient::from_env()?;
    let admission =
        auth_support::request_admission_lease(&signal_server, &auth_session, &tenant_id, &identity)
            .await?;
    let lookup = signal_server
        .lookup_connection_code(&admission.token, &args.code)
        .await?;
    let turn_credentials = signal_server
        .fetch_turn_credentials(&lookup.turn_admission_lease.token)
        .await?;
    let canonical_origin =
        signal_server.canonical_signaling_origin(&lookup.signaling_server_origin)?;

    // Recheck immediately before publishing work to the agent-owned registries. The agent may
    // have stopped while the control-plane requests were in flight.
    require_agent_active(&paths, args.json).await?;

    let runtime_id = make_runtime_id(&lookup.session_id);
    let initial_record = RuntimeSessionRecord::new(
        runtime_id.clone(),
        lookup.session_id.clone(),
        RuntimeSessionRole::Responder,
        RuntimeSessionSource::Code,
        canonical_origin.clone(),
        identity.state.device.device_id.clone(),
        Some(lookup.initiator_device_id.clone()),
        lookup.initiator_device_name.clone(),
        Some(lookup.initiator_protocol_public_key_fingerprint.clone()),
        RuntimeSessionState::Connecting,
    );
    let control = ManagedSessionControl::new(
        lookup.session_id.clone(),
        RuntimeSessionRole::Responder,
        RuntimeSessionSource::Code,
        identity.state.device.device_id.clone(),
        canonical_origin,
        lookup.session_token.clone(),
        Some(turn_credentials),
    );
    let registration_id = control.registration_id.clone();
    if let Err(error) = register_managed_session(&paths, initial_record, control).await {
        let failure = ConnectAttemptFailure::session_registration_failed();
        print_connect_failure_if_requested(
            args.json,
            Some(&lookup.session_id),
            &failure,
            false,
            false,
        )?;
        return Err(error.context("failed to register the agent-owned session transaction"));
    }

    let timeout = Duration::from_secs(args.timeout_seconds);
    match wait_for_handshake(&paths, &lookup.session_id, &registration_id, timeout).await {
        Ok(observation) => {
            let receipt = match verify_managed_handshake_receipt(
                &paths,
                &lookup.session_id,
                &registration_id,
                &observation.runtime_id,
                &observation.negotiated_suite,
            )
            .await
            {
                Ok(receipt) => receipt,
                Err(receipt_error) => {
                    let failure = ConnectAttemptFailure::handshake_receipt_changed();
                    let cleanup = super::cleanup_managed_session_attempt(
                        &paths,
                        &lookup.session_id,
                        &registration_id,
                        "managed handshake authority changed before success reporting",
                    )
                    .await;
                    let (cleanup_completed, cleanup_applied) = cleanup_report(&cleanup);
                    print_connect_failure_if_requested(
                        args.json,
                        Some(&lookup.session_id),
                        &failure,
                        cleanup_completed,
                        cleanup_applied,
                    )?;
                    return match cleanup {
                        Ok(_) => Err(anyhow!(failure.message).context(format!(
                            "managed handshake receipt verification failed: {receipt_error:#}"
                        ))),
                        Err(cleanup_error) => Err(anyhow!(failure.message).context(format!(
                            "managed handshake receipt verification failed: {receipt_error:#}; exact cleanup also failed: {cleanup_error:#}"
                        ))),
                    };
                }
            };
            let report = connect_success_report(
                receipt.session_id.clone(),
                receipt.remote_device_id.clone(),
                receipt.negotiated_suite.clone(),
                &receipt.authenticated_peer,
                &receipt.selected_ice_route,
            );
            let print_result = print_connect_success(args.json, &report);
            // Keep the shared registry authority through synchronous output.
            drop(receipt);
            print_result
        }
        Err(failure) => {
            let cleanup = super::cleanup_managed_session_attempt(
                &paths,
                &lookup.session_id,
                &registration_id,
                "connection attempt did not complete",
            )
            .await;
            let (cleanup_completed, cleanup_applied) = cleanup_report(&cleanup);
            print_connect_failure_if_requested(
                args.json,
                Some(&lookup.session_id),
                &failure,
                cleanup_completed,
                cleanup_applied,
            )?;
            match cleanup {
                Ok(_) => bail!(failure.message),
                Err(cleanup_error) => Err(anyhow!(failure.message).context(format!(
                    "failed to clean up session control after connection failure: {cleanup_error:#}"
                ))),
            }
        }
    }
}

async fn require_agent_active(paths: &skybridge_agent::AgentPaths, as_json: bool) -> Result<()> {
    let failure = match agent_runtime_guard::require_active_agent(paths).await {
        Ok(()) => return Ok(()),
        Err(error) => ConnectAttemptFailure::from_agent_guard(error),
    };
    print_connect_failure_if_requested(as_json, None, &failure, true, false)?;
    bail!(failure.message)
}

async fn wait_for_handshake(
    paths: &skybridge_agent::AgentPaths,
    session_id: &str,
    expected_registration_id: &str,
    timeout: Duration,
) -> std::result::Result<ConnectHandshakeObservation, ConnectAttemptFailure> {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        agent_runtime_guard::require_active_agent(paths)
            .await
            .map_err(ConnectAttemptFailure::from_agent_guard)?;

        let observation =
            observe_managed_session_registration(paths, session_id, expected_registration_id)
                .await
                .map_err(|error| ConnectAttemptFailure::session_state_unavailable(&error))?;
        let record = match observation {
            ManagedSessionRegistrationObservation::Current(record) => record,
            ManagedSessionRegistrationObservation::Missing => {
                return Err(ConnectAttemptFailure::session_missing(session_id));
            }
            ManagedSessionRegistrationObservation::Replaced => {
                return Err(ConnectAttemptFailure::session_registration_replaced(
                    session_id,
                ));
            }
        };
        match evaluate_connect_record(
            session_id,
            &record.runtime_id,
            record.state,
            &record.readiness,
            record.authenticated_peer.as_ref(),
            record.selected_ice_route.as_ref(),
            OffsetDateTime::now_utc(),
        ) {
            ConnectWaitDecision::Pending => {}
            ConnectWaitDecision::Complete {
                runtime_id,
                negotiated_suite,
            } => {
                agent_runtime_guard::require_active_agent(paths)
                    .await
                    .map_err(ConnectAttemptFailure::from_agent_guard)?;
                return Ok(ConnectHandshakeObservation {
                    runtime_id,
                    negotiated_suite,
                });
            }
            ConnectWaitDecision::Failed(failure) => return Err(failure),
        }

        if tokio::time::Instant::now() >= deadline {
            return Err(ConnectAttemptFailure::timeout(session_id, timeout));
        }
        tokio::time::sleep(CONNECT_POLL_INTERVAL).await;
    }
}

fn evaluate_connect_record(
    expected_session_id: &str,
    runtime_id: &str,
    state: RuntimeSessionState,
    readiness: &SessionReadiness,
    authenticated_peer: Option<&RuntimeAuthenticatedPeerObservation>,
    selected_ice_route: Option<&RuntimeSelectedIceRouteObservation>,
    now: OffsetDateTime,
) -> ConnectWaitDecision {
    if matches!(
        state,
        RuntimeSessionState::Disconnected | RuntimeSessionState::Failed
    ) {
        return ConnectWaitDecision::Failed(ConnectAttemptFailure::handshake_failed(
            expected_session_id,
            state,
        ));
    }

    match readiness {
        SessionReadiness::HandshakeComplete {
            session_id,
            negotiated_suite,
        } if session_id == expected_session_id
            && connection_evidence_is_fresh(authenticated_peer, selected_ice_route, now) =>
        {
            ConnectWaitDecision::Complete {
                runtime_id: runtime_id.to_owned(),
                negotiated_suite: negotiated_suite.clone(),
            }
        }
        SessionReadiness::Idle
        | SessionReadiness::TransportReady { .. }
        | SessionReadiness::HandshakeComplete { .. } => ConnectWaitDecision::Pending,
    }
}

fn connection_evidence_is_fresh(
    authenticated_peer: Option<&RuntimeAuthenticatedPeerObservation>,
    selected_ice_route: Option<&RuntimeSelectedIceRouteObservation>,
    now: OffsetDateTime,
) -> bool {
    let (Some(authenticated_peer), Some(selected_ice_route)) =
        (authenticated_peer, selected_ice_route)
    else {
        return false;
    };
    if authenticated_peer.capabilities.is_none() {
        return false;
    }
    let heartbeat_age = now - authenticated_peer.observed_at;
    let route_age = now - selected_ice_route.observed_at;
    !heartbeat_age.is_negative()
        && heartbeat_age <= CONNECT_EVIDENCE_FRESHNESS
        && !route_age.is_negative()
        && route_age <= CONNECT_EVIDENCE_FRESHNESS
}

fn connect_success_report(
    session_id: String,
    remote_device_id: String,
    negotiated_suite: String,
    authenticated_peer: &RuntimeAuthenticatedPeerObservation,
    selected_ice_route: &RuntimeSelectedIceRouteObservation,
) -> ConnectSuccessReport {
    let (route_kind, ip_semantics) = match selected_ice_route.kind {
        RuntimeSessionRouteKind::Direct => ("direct", "selected_peer_candidate"),
        RuntimeSessionRouteKind::Relay => {
            let semantics = if selected_ice_route.remote_candidate_type == "relay" {
                "relay_endpoint"
            } else {
                "selected_peer_candidate_via_relay"
            };
            ("relay", semantics)
        }
    };
    ConnectSuccessReport {
        schema_version: CONNECT_SCHEMA_VERSION,
        capability_id: CONNECT_CAPABILITY_ID,
        success: true,
        status: "ready",
        runtime_owner: CONNECT_RUNTIME_OWNER,
        session_id,
        peer: ConnectPeerReport {
            device_id: remote_device_id,
            name: Some(authenticated_peer.device_name.clone()),
            name_source: "authenticated_sbwc_heartbeat",
            platform: authenticated_peer.platform.clone(),
            ip: selected_ice_route.remote_address.clone(),
            ip_observed: true,
            ip_source: "selected_ice_pair_stats",
            ip_semantics,
            port: selected_ice_route.remote_port,
            transport: selected_ice_route.protocol.clone(),
            route_kind,
        },
        security: ConnectSecurityReport {
            handshake_complete: true,
            protocol_identity_bound: true,
            negotiated_suite,
            suite_source: "native_handshake_event",
        },
        features: ConnectFeaturesReport {
            observed: true,
            source: "authenticated_sbwc_heartbeat",
            values: authenticated_peer
                .capabilities
                .clone()
                .expect("ready evidence requires an authenticated capability snapshot"),
            file_transfer_port: authenticated_peer.file_transfer_port,
            remote_control_port: authenticated_peer.remote_control_port,
        },
    }
}

fn print_connect_success(as_json: bool, report: &ConnectSuccessReport) -> Result<()> {
    if as_json {
        println!("{}", serde_json::to_string_pretty(report)?);
    } else {
        let peer_name = report
            .peer
            .name
            .as_deref()
            .unwrap_or(&report.peer.device_id);
        println!(
            "Connected to {peer_name} for session {} with suite {}.",
            report.session_id, report.security.negotiated_suite
        );
        println!("Runtime Owner: {}", report.runtime_owner);
        println!(
            "Peer Route: {}:{} over {} ({}, {}).",
            report.peer.ip,
            report.peer.port,
            report.peer.transport,
            report.peer.route_kind,
            report.peer.ip_semantics
        );
        let features = if report.features.values.is_empty() {
            "none".to_owned()
        } else {
            report.features.values.join(", ")
        };
        println!("Peer Features: {features}");
    }
    Ok(())
}

fn print_connect_failure_if_requested(
    as_json: bool,
    session_id: Option<&str>,
    failure: &ConnectAttemptFailure,
    cleanup_completed: bool,
    cleanup_applied: bool,
) -> Result<()> {
    if as_json {
        let report =
            connect_failure_report(session_id, failure, cleanup_completed, cleanup_applied);
        crate::cli_output::write_json_failure(&report)?;
    }
    Ok(())
}

fn connect_failure_report<'a>(
    session_id: Option<&'a str>,
    failure: &'a ConnectAttemptFailure,
    cleanup_completed: bool,
    cleanup_applied: bool,
) -> ConnectFailureReport<'a> {
    ConnectFailureReport {
        schema_version: CONNECT_SCHEMA_VERSION,
        capability_id: CONNECT_CAPABILITY_ID,
        success: false,
        status: "failed",
        runtime_owner: CONNECT_RUNTIME_OWNER,
        session_id,
        cleanup_completed,
        cleanup_applied,
        error: ConnectErrorReport {
            code: failure.code,
            message: &failure.message,
            retryable: failure.retryable,
        },
    }
}

fn cleanup_report(cleanup: &Result<bool>) -> (bool, bool) {
    match cleanup {
        Ok(applied) => (true, *applied),
        Err(_) => (false, false),
    }
}

fn runtime_state_label(state: RuntimeSessionState) -> &'static str {
    match state {
        RuntimeSessionState::Pending => "pending",
        RuntimeSessionState::Connecting => "connecting",
        RuntimeSessionState::Bound => "bound",
        RuntimeSessionState::Degraded => "degraded",
        RuntimeSessionState::Disconnected => "disconnected",
        RuntimeSessionState::Failed => "failed",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn observed_connection_evidence(
        now: OffsetDateTime,
    ) -> (
        RuntimeAuthenticatedPeerObservation,
        RuntimeSelectedIceRouteObservation,
    ) {
        (
            RuntimeAuthenticatedPeerObservation {
                device_id: "peer-1".to_owned(),
                device_name: "Peer One".to_owned(),
                platform: Some("ios".to_owned()),
                capabilities: Some(vec!["file_transfer".to_owned()]),
                file_transfer_port: Some(8080),
                remote_control_port: None,
                sbwc_counter: 1,
                observed_at: now,
            },
            RuntimeSelectedIceRouteObservation {
                remote_address: "192.0.2.20".to_owned(),
                remote_port: 49152,
                protocol: "udp".to_owned(),
                local_candidate_type: "host".to_owned(),
                remote_candidate_type: "srflx".to_owned(),
                kind: RuntimeSessionRouteKind::Direct,
                observed_at: now,
            },
        )
    }

    #[test]
    fn connection_only_succeeds_for_current_handshake_complete_evidence() {
        let now = OffsetDateTime::now_utc();
        let (peer, route) = observed_connection_evidence(now);
        assert_eq!(
            evaluate_connect_record(
                "session-1",
                "runtime-1",
                RuntimeSessionState::Bound,
                &SessionReadiness::Idle,
                Some(&peer),
                Some(&route),
                now,
            ),
            ConnectWaitDecision::Pending
        );
        assert_eq!(
            evaluate_connect_record(
                "session-1",
                "runtime-1",
                RuntimeSessionState::Bound,
                &SessionReadiness::TransportReady {
                    session_id: "session-1".to_owned(),
                },
                Some(&peer),
                Some(&route),
                now,
            ),
            ConnectWaitDecision::Pending
        );
        assert_eq!(
            evaluate_connect_record(
                "session-1",
                "runtime-1",
                RuntimeSessionState::Bound,
                &SessionReadiness::HandshakeComplete {
                    session_id: "other-session".to_owned(),
                    negotiated_suite: "X-Wing".to_owned(),
                },
                Some(&peer),
                Some(&route),
                now,
            ),
            ConnectWaitDecision::Pending
        );
        assert_eq!(
            evaluate_connect_record(
                "session-1",
                "runtime-1",
                RuntimeSessionState::Bound,
                &SessionReadiness::HandshakeComplete {
                    session_id: "session-1".to_owned(),
                    negotiated_suite: "X-Wing".to_owned(),
                },
                None,
                None,
                now,
            ),
            ConnectWaitDecision::Pending
        );
        assert_eq!(
            evaluate_connect_record(
                "session-1",
                "runtime-1",
                RuntimeSessionState::Bound,
                &SessionReadiness::HandshakeComplete {
                    session_id: "session-1".to_owned(),
                    negotiated_suite: "X-Wing".to_owned(),
                },
                Some(&peer),
                Some(&route),
                now,
            ),
            ConnectWaitDecision::Complete {
                runtime_id: "runtime-1".to_owned(),
                negotiated_suite: "X-Wing".to_owned(),
            }
        );
    }

    #[test]
    fn terminal_session_state_fails_even_with_stale_handshake_evidence() {
        let now = OffsetDateTime::now_utc();
        let (peer, route) = observed_connection_evidence(now);
        let readiness = SessionReadiness::HandshakeComplete {
            session_id: "session-1".to_owned(),
            negotiated_suite: "X-Wing".to_owned(),
        };
        for state in [
            RuntimeSessionState::Disconnected,
            RuntimeSessionState::Failed,
        ] {
            let ConnectWaitDecision::Failed(failure) = evaluate_connect_record(
                "session-1",
                "runtime-1",
                state,
                &readiness,
                Some(&peer),
                Some(&route),
                now,
            ) else {
                panic!("terminal state must fail closed");
            };
            assert_eq!(failure.code, "handshake_failed");
        }
    }

    #[test]
    fn connection_success_json_preserves_evidence_boundaries() -> Result<()> {
        let now = OffsetDateTime::now_utc();
        let (peer, route) = observed_connection_evidence(now);
        let report = connect_success_report(
            "session-1".to_owned(),
            "peer-1".to_owned(),
            "X-Wing".to_owned(),
            &peer,
            &route,
        );
        let payload = serde_json::to_value(report)?;
        assert_eq!(payload["schema_version"], 2);
        assert_eq!(payload["capability_id"], "native.connect");
        assert_eq!(payload["success"], true);
        assert_eq!(payload["status"], "ready");
        assert_eq!(payload["runtime_owner"], "skybridge-agent");
        assert_eq!(payload["peer"]["name"], "Peer One");
        assert_eq!(
            payload["peer"]["name_source"],
            "authenticated_sbwc_heartbeat"
        );
        assert_eq!(payload["peer"]["platform"], "ios");
        assert_eq!(payload["peer"]["ip"], "192.0.2.20");
        assert_eq!(payload["peer"]["ip_observed"], true);
        assert_eq!(payload["peer"]["ip_source"], "selected_ice_pair_stats");
        assert_eq!(payload["peer"]["ip_semantics"], "selected_peer_candidate");
        assert_eq!(payload["security"]["handshake_complete"], true);
        assert_eq!(payload["security"]["protocol_identity_bound"], true);
        assert_eq!(payload["security"]["negotiated_suite"], "X-Wing");
        assert_eq!(payload["features"]["observed"], true);
        assert_eq!(
            payload["features"]["source"],
            "authenticated_sbwc_heartbeat"
        );
        assert_eq!(
            payload["features"]["values"],
            serde_json::json!(["file_transfer"])
        );
        assert_eq!(payload["features"]["file_transfer_port"], 8080);
        Ok(())
    }

    #[test]
    fn connection_failure_json_never_claims_success() -> Result<()> {
        let failure = ConnectAttemptFailure::timeout("session-1", Duration::from_secs(30));
        let report = connect_failure_report(Some("session-1"), &failure, true, true);
        let payload = serde_json::to_value(report)?;
        assert_eq!(payload["success"], false);
        assert_eq!(payload["status"], "failed");
        assert_eq!(payload["error"]["code"], "connection_ready_timeout");
        assert_eq!(payload["cleanup_completed"], true);
        assert_eq!(payload["cleanup_applied"], true);
        Ok(())
    }

    #[test]
    fn worker_runtime_handoff_can_satisfy_the_same_registration_attempt() {
        let now = OffsetDateTime::now_utc();
        let (peer, route) = observed_connection_evidence(now);
        let decision = evaluate_connect_record(
            "session-1",
            "runtime-replacement",
            RuntimeSessionState::Bound,
            &SessionReadiness::HandshakeComplete {
                session_id: "session-1".to_owned(),
                negotiated_suite: "X-Wing".to_owned(),
            },
            Some(&peer),
            Some(&route),
            now,
        );
        assert_eq!(
            decision,
            ConnectWaitDecision::Complete {
                runtime_id: "runtime-replacement".to_owned(),
                negotiated_suite: "X-Wing".to_owned(),
            },
            "registration ownership, not the worker incarnation, binds the attempt"
        );
    }

    #[test]
    fn receipt_change_failure_is_structured_and_never_claims_success() -> Result<()> {
        let failure = ConnectAttemptFailure::handshake_receipt_changed();
        let report = connect_failure_report(Some("session-1"), &failure, true, false);
        let payload = serde_json::to_value(report)?;
        assert_eq!(payload["success"], false);
        assert_eq!(payload["error"]["code"], "handshake_receipt_changed");
        assert_eq!(payload["cleanup_completed"], true);
        assert_eq!(payload["cleanup_applied"], false);
        Ok(())
    }

    #[test]
    fn public_connection_failures_do_not_echo_internal_error_chains() {
        let sentinel = "/Users/example/private/session-token-secret";
        let internal = anyhow!("registry failed at {sentinel}");
        let registry = ConnectAttemptFailure::session_state_unavailable(&internal);
        let registration = ConnectAttemptFailure::session_registration_failed();

        assert!(!registry.message.contains(sentinel));
        assert!(!registration.message.contains(sentinel));
        assert_eq!(registry.code, "session_state_unavailable");
        assert_eq!(registration.code, "session_registration_failed");
    }
}
