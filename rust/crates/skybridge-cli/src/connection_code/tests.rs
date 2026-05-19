use super::*;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use skybridge_agent::{load_managed_session_controls, store_auth_session};
use skybridge_core::{AuthSession, SignalingLifecyclePhase};
use time::OffsetDateTime;

use crate::OutputOptions;
use crate::cli_test_support::{make_test_dir, spawn_mock_server};

#[test]
fn inline_connect_state_sends_join_once_when_bound() {
    let mut state = InlineConnectState::default();

    let first = state.apply_lifecycle_phase(SignalingLifecyclePhase::Bound);
    assert_eq!(
        first,
        InlineLifecycleDecision {
            send_join: true,
            failed_before_bound: false,
        }
    );
    assert!(state.signaling_bound);
    assert!(state.join_sent);
    assert!(!state.signaling_stream_closed);

    let second = state.apply_lifecycle_phase(SignalingLifecyclePhase::Bound);
    assert_eq!(
        second,
        InlineLifecycleDecision {
            send_join: false,
            failed_before_bound: false,
        }
    );
    assert!(state.signaling_bound);
}

#[test]
fn inline_connect_state_distinguishes_failed_before_and_after_bound() {
    let mut failed_before_bound = InlineConnectState::default();
    let before = failed_before_bound.apply_lifecycle_phase(SignalingLifecyclePhase::Failed);
    assert_eq!(
        before,
        InlineLifecycleDecision {
            send_join: false,
            failed_before_bound: true,
        }
    );
    assert!(failed_before_bound.signaling_stream_closed);

    let mut failed_after_bound = InlineConnectState::default();
    failed_after_bound.apply_lifecycle_phase(SignalingLifecyclePhase::Bound);
    let after = failed_after_bound.apply_lifecycle_phase(SignalingLifecyclePhase::Failed);
    assert_eq!(
        after,
        InlineLifecycleDecision {
            send_join: false,
            failed_before_bound: false,
        }
    );
    assert!(failed_after_bound.signaling_stream_closed);
}

#[tokio::test]
async fn code_create_registers_runtime_and_managed_control_with_mock_control_plane() -> Result<()> {
    let state_dir = make_test_dir("code-create-happy")?;
    let paths = resolve_paths(Some(state_dir))?;
    store_auth_session(
        &paths,
        &AuthSession {
            access_token: test_access_token("tenant-create")?,
            refresh_token: None,
            user_identifier: "user-create".to_owned(),
            nebula_id: None,
            display_name: "Create User".to_owned(),
            issued_at: OffsetDateTime::now_utc(),
        },
    )
    .await?;
    let identity = ensure_device_identity(&paths).await?;

    let now_ms = OffsetDateTime::now_utc().unix_timestamp() * 1_000;
    let expires_ms = now_ms + 60_000;
    let base_url = spawn_mock_server(vec![
        (
            "POST",
            "/api/webrtc/admission/challenge",
            200,
            json!({
                "challengeId": "challenge-create",
                "nonce": "nonce-create",
                "tenantId": "tenant-create",
                "userId": "user-create",
                "deviceId": identity.state.device.device_id,
                "clientIpHash": "ip-hash-create",
                "clientVersion": "test-client",
                "protocolVersion": "1",
                "state": "issued",
                "issuedAt": now_ms,
                "expiresAt": expires_ms,
            }),
        ),
        (
            "POST",
            "/api/webrtc/admission",
            200,
            json!({
                "admissionToken": "admission-create",
                "state": "active",
                "issuedAt": now_ms,
                "expiresAt": expires_ms,
            }),
        ),
        (
            "POST",
            "/api/webrtc/register-code",
            200,
            json!({
                "code": "SB-CREATE",
                "sessionId": "SESSION-CREATE",
                "sessionToken": "session-token-create",
                "turnAdmissionToken": "turn-admission-create",
                "expiresIn": 60,
                "signalingServerOrigin": base_origin_placeholder(),
            }),
        ),
        (
            "GET",
            "/api/turn/credentials",
            200,
            json!({
                "username": "turn-user",
                "password": "turn-pass",
                "ttl": 60,
                "uris": ["turn:127.0.0.1:3478"],
                "mode": "test",
            }),
        ),
    ])?;
    let signal_server = SignalServerClient::new(&base_url, "test-key", "test-client", "1")?;

    code_create_with_client(
        &paths,
        CodeCreateArgs {
            device_name: Some("desk-create".to_owned()),
            ttl_seconds: 60,
            output: OutputOptions { json: true },
        },
        &signal_server,
    )
    .await?;

    let registry = load_session_registry(&paths).await?;
    let record = registry
        .get("SESSION-CREATE")
        .expect("code create should persist runtime session");
    assert_eq!(record.role, RuntimeSessionRole::Initiator);
    assert_eq!(record.source, RuntimeSessionSource::Code);
    assert_eq!(record.state, RuntimeSessionState::Pending);
    assert_eq!(record.signaling_server_origin, base_origin_placeholder());
    assert!(record.remote_device_id.is_none());

    let controls = load_managed_session_controls(&paths).await?;
    let control = controls
        .sessions
        .get("SESSION-CREATE")
        .expect("code create should persist managed session control");
    assert_eq!(control.role, RuntimeSessionRole::Initiator);
    assert_eq!(control.source, RuntimeSessionSource::Code);
    assert_eq!(control.signaling_session_token, "session-token-create");
    let turn_credentials = control
        .turn_credentials
        .as_ref()
        .expect("turn credentials should be stored with control");
    assert_eq!(turn_credentials.username, "turn-user");
    assert_eq!(turn_credentials.uris, vec!["turn:127.0.0.1:3478"]);
    Ok(())
}

fn test_access_token(tenant_id: &str) -> Result<String> {
    let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"none"}"#);
    let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&json!({
        "tenant_id": tenant_id,
        "exp": OffsetDateTime::now_utc().unix_timestamp() + 3_600,
    }))?);
    Ok(format!("{header}.{payload}.signature"))
}

fn base_origin_placeholder() -> &'static str {
    "http://127.0.0.1:65535"
}
