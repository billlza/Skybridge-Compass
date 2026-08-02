use super::*;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use skybridge_agent::{
    load_managed_session_controls, register_managed_session, store_auth_session,
};
use skybridge_core::{AuthSession, ManagedSessionControl, OriginTransportPolicy};
use time::OffsetDateTime;

use crate::OutputOptions;
use crate::cli_test_support::{activate_test_agent, make_test_dir, spawn_mock_server};

#[tokio::test]
async fn code_create_rejects_inactive_agent_before_control_plane_setup() -> Result<()> {
    let state_dir = make_test_dir("code-create-agent-precondition")?;
    let error = code_create(
        Some(state_dir),
        CodeCreateArgs {
            device_name: Some("desk".to_owned()),
            ttl_seconds: 60,
            output: OutputOptions { json: true },
        },
    )
    .await
    .expect_err("code creation without an active agent must fail before requesting a lease");
    assert!(
        error.to_string().contains("runtime lock"),
        "unexpected precondition error: {error:#}"
    );
    Ok(())
}

#[tokio::test]
async fn code_create_registers_runtime_and_managed_control_with_mock_control_plane() -> Result<()> {
    let state_dir = make_test_dir("code-create-happy")?;
    let paths = resolve_paths(Some(state_dir))?;
    let _active_agent = activate_test_agent(&paths)?;
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
    let signal_server = SignalServerClient::new_with_transport_policy(
        &base_url,
        "test-key",
        "test-client",
        "1",
        OriginTransportPolicy::AllowPlaintextLoopback,
    )?;

    let output = code_create_with_client(
        &paths,
        CodeCreateArgs {
            device_name: Some("desk-create".to_owned()),
            ttl_seconds: 60,
            output: OutputOptions { json: true },
        },
        &signal_server,
    )
    .await?;

    assert_eq!(output["schema_version"], 1);
    assert_eq!(output["capability_id"], "native.code.create");
    assert_eq!(output["success"], true);
    assert_eq!(output["status"], "code_registered");
    assert_eq!(output["runtime_owner"], "skybridge-agent");
    assert_eq!(output["peer_connected"], false);

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

#[tokio::test]
async fn managed_session_cleanup_makes_no_unowned_change_when_control_authority_is_unreadable()
-> Result<()> {
    let state_dir = make_test_dir("managed-session-cleanup")?;
    let paths = resolve_paths(Some(state_dir))?;
    upsert_session_runtime(
        &paths,
        RuntimeSessionRecord::new(
            "runtime-cleanup",
            "session-cleanup",
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "https://signal.example.com",
            "local-device",
            None,
            None,
            None,
            RuntimeSessionState::Pending,
        ),
    )
    .await?;
    let registration_id = ManagedSessionControl::new(
        "session-cleanup",
        RuntimeSessionRole::Initiator,
        RuntimeSessionSource::Code,
        "local-device",
        "https://signal.example.com",
        "token-cleanup",
        None,
    )
    .registration_id;
    std::fs::create_dir_all(&paths.session_controls_file)?;

    assert!(
        cleanup_managed_session_attempt(
            &paths,
            "session-cleanup",
            &registration_id,
            "control registration failed",
        )
        .await
        .is_err(),
        "control cleanup error must remain observable"
    );
    let registry = load_session_registry(&paths).await?;
    let record = registry.get("session-cleanup").expect("runtime survives");
    assert_eq!(record.state, RuntimeSessionState::Pending);
    assert_eq!(record.last_error, None);
    Ok(())
}

#[tokio::test]
async fn stale_code_create_or_connect_cleanup_cannot_disconnect_a_replacement_registration()
-> Result<()> {
    let state_dir = make_test_dir("managed-session-exact-cleanup")?;
    let paths = resolve_paths(Some(state_dir))?;
    let session_id = "session-exact-cleanup";
    let mut original_registration_id = None;

    for runtime_id in ["runtime-original", "runtime-replacement"] {
        let session = RuntimeSessionRecord::new(
            runtime_id,
            session_id,
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            "https://signal.example.com",
            "local-device",
            Some("remote-device".to_owned()),
            Some("Remote Device".to_owned()),
            Some("remote-fingerprint".to_owned()),
            RuntimeSessionState::Connecting,
        );
        let control = ManagedSessionControl::new(
            session_id,
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            "local-device",
            "https://signal.example.com",
            format!("token-{runtime_id}"),
            None,
        );
        if original_registration_id.is_none() {
            original_registration_id = Some(control.registration_id.clone());
        }
        register_managed_session(&paths, session, control).await?;
    }

    let cleanup_applied = cleanup_managed_session_attempt(
        &paths,
        session_id,
        original_registration_id
            .as_deref()
            .expect("original registration id"),
        "original connection attempt failed",
    )
    .await?;
    assert!(
        !cleanup_applied,
        "stale cleanup must lose the registration CAS"
    );

    let sessions = load_session_registry(&paths).await?;
    let replacement = sessions
        .get(session_id)
        .expect("replacement runtime must survive stale cleanup");
    assert_eq!(replacement.runtime_id, "runtime-replacement");
    assert_eq!(replacement.state, RuntimeSessionState::Connecting);
    let controls = load_managed_session_controls(&paths).await?;
    let replacement_control = controls
        .get(session_id)
        .expect("replacement control must survive stale cleanup");
    assert_eq!(replacement_control.target_runtime_id, "runtime-replacement");
    assert_ne!(
        replacement_control.registration_id,
        original_registration_id.expect("original registration id")
    );
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
