//! SkyBridge Compass for Ubuntu
//!
//! A cross-platform P2P file transfer and remote desktop application.

use futures::StreamExt;
use futures::channel::mpsc;
use gtk4::prelude::*;
use gtk4::{self as gtk, gdk, gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::{Arc, RwLock};
use tracing::{Level, info};
use tracing_subscriber::FmtSubscriber;

#[cfg(feature = "webrtc")]
mod remote_json_video;

use skybridge_core::remote::encoder::SenderCapabilityResolver;
use skybridge_core::{
    auth::{AuthError, AuthSession, AuthenticationService},
    crypto::suite::CryptoSuiteId,
    discovery::{DeviceCapability, DeviceDiscoveryManager, DiscoveredDevice, DiscoveryConfig},
    p2p::{
        ConnectionTrustPolicy, CryptoTier, HandshakePolicy, LocalIdentity, LocalIdentityStore,
        P2PConnectionManager, TcpControlEvent, TcpControlService, TrustStore,
    },
    remote::{
        AutoDecoder, CaptureConfig, EncoderConfig, MacRemoteControlServer,
        MacRemoteControlServerConfig, RateControl, RemoteDesktopManager, ScreenCapturer,
        UltraStreamCodec, UltraStreamDecodedFrame, UltraStreamReceiver, UltraStreamSender,
        UnifiedEncoder, VideoCodec, VncConfig, VncServer, VncServerConfig,
    },
    transfer::{
        FileTransferEngine, FileTransferServer, FileTransferServerConfig,
        IncomingTransferCompleted, IncomingTransferDecision, IncomingTransferPromptConfig,
        IncomingTransferPromptRequest, IncomingTransferRequest, TransferConfig, TransferKeyStore,
    },
};

#[cfg(feature = "webrtc")]
use skybridge_core::remote::supported_remote_video_formats;
#[cfg(target_os = "linux")]
use skybridge_core::remote::{
    bootstrap_portal_session, close_runtime_portal_session, ensure_runtime_portal_session,
};

#[cfg(feature = "webrtc")]
use skybridge_core::p2p::{
    AppMessage, HeartbeatPayload, KemPublicKeyInfo, PairingIdentityExchangePayload, PeerIdentity,
    SwiftDateSeconds, enforce_inbound_trust_policy,
};

#[cfg(feature = "webrtc")]
use skybridge_core::transfer::IncomingTransferSource;

#[cfg(feature = "webrtc")]
use skybridge_core::remote::{KeyEvent, MouseButton, MouseEvent, UnifiedInputHandler};

#[cfg(feature = "webrtc")]
use remote_json_video::RemoteJsonVideoState;

use skybridge_ui::{
    AppSettings, ConnectionPhase, ConnectionUpdate, DashboardPage, DevicesPage, LogLevel,
    LoginPage, MonitorPage, RemotePage, SettingsPage, StreamingStatus, TransfersPage, UsbPage,
};

#[cfg(feature = "webrtc")]
use skybridge_core::webrtc::{
    CrossNetworkFileTransferMessage, CrossNetworkFileTransferOp, IceConfig, KeyboardEventTypeWire,
    KeyboardEventWire, MouseEventTypeWire, MouseEventWire, ProtocolIdentityBinding,
    RemoteMessageTypeWire, RemoteMessageWire, ScreenDataWire, SignalingControlClient,
    TurnCredentialResponse, WebRtcCrossNetworkManager, WebRtcSignalingClientConfig,
    WebRtcStartParams, preferred_turn_uri_with_override, should_initiate_pqc_rekey,
};
#[cfg(feature = "webrtc")]
use url::Url;

const APP_ID: &str = "com.skybridge.compass.ubuntu";
const INCOMING_TRANSFER_DECISION_TIMEOUT_SECS: u64 = 60;

#[cfg(target_os = "linux")]
fn register_host_app_identity() {
    let app = gio::Application::builder()
        .application_id(APP_ID)
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    let _ = app.register(gio::Cancellable::NONE);
}

#[cfg(target_os = "linux")]
fn has_flag(args: &[String], flag: &str) -> bool {
    args.iter().any(|arg| arg == flag)
}

#[cfg(target_os = "linux")]
fn arg_value<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    args.windows(2)
        .find(|window| window[0] == flag)
        .map(|window| window[1].as_str())
}

#[cfg(target_os = "linux")]
fn parse_u64_arg(args: &[String], flag: &str, default: u64) -> Result<u64, String> {
    match arg_value(args, flag) {
        Some(value) => value
            .parse::<u64>()
            .map_err(|err| format!("invalid value for {}: {}", flag, err)),
        None => Ok(default),
    }
}

#[cfg(target_os = "linux")]
fn parse_i32_arg(args: &[String], flag: &str) -> Result<Option<i32>, String> {
    match arg_value(args, flag) {
        Some(value) => value
            .parse::<i32>()
            .map(Some)
            .map_err(|err| format!("invalid value for {}: {}", flag, err)),
        None => Ok(None),
    }
}

#[cfg(target_os = "linux")]
fn frame_has_visible_pixels(frame: &skybridge_core::remote::CapturedFrame) -> bool {
    match frame.format {
        skybridge_core::remote::PixelFormat::Bgra8888
        | skybridge_core::remote::PixelFormat::Rgba8888 => frame
            .data
            .chunks_exact(4)
            .any(|chunk| chunk[0] != 0 || chunk[1] != 0 || chunk[2] != 0),
        skybridge_core::remote::PixelFormat::Rgb888
        | skybridge_core::remote::PixelFormat::Bgr888 => frame.data.chunks_exact(3).any(|chunk| {
            chunk.first().copied().unwrap_or_default() != 0
                || chunk.get(1).copied().unwrap_or_default() != 0
                || chunk.get(2).copied().unwrap_or_default() != 0
        }),
    }
}

#[cfg(target_os = "linux")]
struct PortalRuntimeValidationSummary {
    duration_secs: u64,
    frames: u64,
    non_black_frames: u64,
    max_gap_ms: u64,
    input_smoke_ran: bool,
    width: u32,
    height: u32,
}

#[cfg(target_os = "linux")]
async fn validate_runtime_portal_session(
    args: &[String],
) -> Result<PortalRuntimeValidationSummary, String> {
    use skybridge_core::remote::{
        CaptureConfig, KeyEvent, MouseButton, MouseEvent, ScreenCapturer, UnifiedInputHandler,
        keysym,
    };

    let duration_secs = parse_u64_arg(args, "--portal-validate-secs", 300)?;
    if duration_secs == 0 {
        return Err("--portal-validate-secs must be greater than zero".to_string());
    }
    let input_smoke = has_flag(args, "--portal-validate-input");
    let capture_cursor = !has_flag(args, "--portal-validate-hide-cursor");

    let snapshot = ensure_runtime_portal_session(capture_cursor)
        .await
        .map_err(|err| err.to_string())?;

    let mut capturer = ScreenCapturer::new().map_err(|err| err.to_string())?;
    capturer.initialize().await.map_err(|err| err.to_string())?;

    let mut receiver = capturer
        .start(&CaptureConfig {
            target_fps: 60,
            capture_cursor,
            pixel_format: skybridge_core::remote::PixelFormat::Bgra8888,
            screen_id: Some(snapshot.stream.pipewire_node_id),
            ..CaptureConfig::default()
        })
        .await
        .map_err(|err| err.to_string())?;

    let center_x = parse_i32_arg(args, "--portal-pointer-x")?
        .unwrap_or((snapshot.stream.width / 2).try_into().unwrap_or(i32::MAX));
    let center_y = parse_i32_arg(args, "--portal-pointer-y")?
        .unwrap_or((snapshot.stream.height / 2).try_into().unwrap_or(i32::MAX));

    if input_smoke && !snapshot.input_allowed {
        return Err(
            "runtime portal session restored screen sharing but not remote interaction; rerun --portal-bootstrap and enable Allow Remote Interaction".to_string()
        );
    }

    if input_smoke {
        let mut input = UnifiedInputHandler::new().map_err(|err| err.to_string())?;
        input.initialize().await.map_err(|err| err.to_string())?;
        input
            .send_mouse(&MouseEvent::move_to(center_x, center_y))
            .await
            .map_err(|err| format!("pointer validation failed: {}", err))?;
        input
            .send_mouse(&MouseEvent::click(MouseButton::Left, center_x, center_y))
            .await
            .map_err(|err| format!("click validation failed: {}", err))?;
        input
            .send_key(&KeyEvent::key_down(keysym::ESCAPE, Default::default()))
            .await
            .map_err(|err| format!("keyboard key-down validation failed: {}", err))?;
        input
            .send_key(&KeyEvent::key_up(keysym::ESCAPE, Default::default()))
            .await
            .map_err(|err| format!("keyboard key-up validation failed: {}", err))?;
    }

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(duration_secs);
    let mut frame_count = 0u64;
    let mut non_black_frames = 0u64;
    let mut max_gap_ms = 0u64;
    let mut last_frame_at: Option<std::time::Instant> = None;

    while std::time::Instant::now() < deadline {
        let frame = tokio::time::timeout(std::time::Duration::from_millis(750), receiver.recv())
            .await
            .map_err(|_| {
                "capture stalled for more than 750ms while validating persistent output".to_string()
            })?
            .ok_or_else(|| "capture stream closed unexpectedly".to_string())?;

        let now = std::time::Instant::now();
        if let Some(last_frame_at) = last_frame_at {
            let gap_ms = now.duration_since(last_frame_at).as_millis() as u64;
            max_gap_ms = max_gap_ms.max(gap_ms);
            if gap_ms > 500 {
                let _ = capturer.stop().await;
                close_runtime_portal_session().await;
                return Err(format!(
                    "frozen frame gap {}ms exceeded the 500ms runtime validation limit",
                    gap_ms
                ));
            }
        }
        last_frame_at = Some(now);
        frame_count += 1;
        if frame_has_visible_pixels(&frame) {
            non_black_frames += 1;
        }
    }

    capturer.stop().await.map_err(|err| err.to_string())?;
    close_runtime_portal_session().await;

    if non_black_frames == 0 {
        return Err("runtime validation completed without observing a non-black frame".to_string());
    }

    Ok(PortalRuntimeValidationSummary {
        duration_secs,
        frames: frame_count,
        non_black_frames,
        max_gap_ms,
        input_smoke_ran: input_smoke,
        width: snapshot.stream.width,
        height: snapshot.stream.height,
    })
}

#[cfg(target_os = "linux")]
fn maybe_run_portal_command() -> Option<glib::ExitCode> {
    let args: Vec<String> = std::env::args().collect();
    let bootstrap = has_flag(&args, "--portal-bootstrap");
    let validate_runtime = has_flag(&args, "--portal-validate-runtime");
    if !bootstrap && !validate_runtime {
        return None;
    }

    register_host_app_identity();

    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(err) => {
            eprintln!("portal bootstrap runtime init failed: {err}");
            return Some(glib::ExitCode::FAILURE);
        }
    };

    if bootstrap {
        match runtime.block_on(async { bootstrap_portal_session(true).await }) {
            Ok(snapshot) => {
                println!(
                    "portal-bootstrap ok state={:?} session={} node={} size={}x{} restore_token_present={} pipewire_fd_valid={} input_allowed={}",
                    snapshot.state,
                    snapshot.session_handle,
                    snapshot.stream.pipewire_node_id,
                    snapshot.stream.width,
                    snapshot.stream.height,
                    snapshot.restore_token_present,
                    snapshot.pipewire_fd_valid,
                    snapshot.input_allowed,
                );
                Some(glib::ExitCode::SUCCESS)
            }
            Err(err) => {
                eprintln!("portal-bootstrap failed: {err}");
                Some(glib::ExitCode::FAILURE)
            }
        }
    } else {
        match runtime.block_on(async { validate_runtime_portal_session(&args).await }) {
            Ok(summary) => {
                println!(
                    "portal-runtime-validation ok duration={}s frames={} non_black_frames={} max_gap_ms={} input_smoke_ran={} size={}x{}",
                    summary.duration_secs,
                    summary.frames,
                    summary.non_black_frames,
                    summary.max_gap_ms,
                    summary.input_smoke_ran,
                    summary.width,
                    summary.height,
                );
                Some(glib::ExitCode::SUCCESS)
            }
            Err(err) => {
                eprintln!("portal-runtime-validation failed: {err}");
                Some(glib::ExitCode::FAILURE)
            }
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn maybe_run_portal_command() -> Option<glib::ExitCode> {
    None
}

fn init_app_icon_theme() {
    gtk::Window::set_default_icon_name(APP_ID);

    let Some(display) = gdk::Display::default() else {
        return;
    };

    let icon_theme = gtk::IconTheme::for_display(&display);
    let local_icon_search_paths = [
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../packaging/linux/hicolor/scalable/apps"),
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../packaging/linux/hicolor/48x48/apps"),
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../packaging/linux/hicolor/512x512/apps"),
    ];

    for local_icon_search_path in local_icon_search_paths {
        if local_icon_search_path.is_dir() {
            icon_theme.add_search_path(local_icon_search_path);
        }
    }
}

#[cfg(feature = "webrtc")]
fn signaling_url_with_shard(
    base: &str,
    session_id: &str,
    session_token: Option<&str>,
) -> Result<Url, url::ParseError> {
    let mut url = Url::parse(base)?;
    let shard = session_id.trim();
    let session_token = session_token
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let client_version = std::env::var("SKYBRIDGE_CLIENT_VERSION")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string());
    let protocol_version = std::env::var("SKYBRIDGE_PROTOCOL_VERSION")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| skybridge_core::PROTOCOL_VERSION.to_string());
    if !shard.is_empty() || session_token.is_some() {
        let mut pairs: Vec<(String, String)> = url
            .query_pairs()
            .filter(|(key, _)| key != "shard" && key != "st" && key != "cv" && key != "pv")
            .map(|(key, value)| (key.into_owned(), value.into_owned()))
            .collect();
        pairs.push(("shard".to_string(), shard.to_string()));
        if let Some(session_token) = session_token {
            pairs.push(("st".to_string(), session_token.to_string()));
        }
        pairs.push(("cv".to_string(), client_version));
        pairs.push(("pv".to_string(), protocol_version));
        {
            let mut query = url.query_pairs_mut();
            query.clear();
            for (key, value) in pairs {
                query.append_pair(&key, &value);
            }
        }
    }
    Ok(url)
}

#[cfg(feature = "webrtc")]
fn signaling_server_base_url(settings: &AppSettings) -> Result<String, String> {
    let configured = settings
        .network
        .webrtc_signaling_server_url
        .trim()
        .to_string();
    if !configured.is_empty() {
        return Ok(configured);
    }

    let mut url = Url::parse(settings.network.webrtc_signaling_url.trim())
        .map_err(|err| format!("Invalid WebSocket URL: {}", err))?;
    let scheme = match url.scheme() {
        "wss" => "https",
        "ws" => "http",
        "https" => "https",
        "http" => "http",
        other => return Err(format!("Unsupported signaling scheme: {}", other)),
    };
    url.set_scheme(scheme)
        .map_err(|_| "Invalid signaling server scheme".to_string())?;
    url.set_path("");
    url.set_query(None);
    url.set_fragment(None);
    let base = if url.path().is_empty() {
        url.to_string()
    } else {
        url[..url::Position::AfterPath]
            .trim_end_matches('/')
            .to_string()
    };
    Ok(base.trim_end_matches('/').to_string())
}

#[cfg(feature = "webrtc")]
fn signaling_control_client(settings: &AppSettings) -> Result<SignalingControlClient, String> {
    let base_url = signaling_server_base_url(settings)?;
    let (bearer_token, tenant_id) = signaling_user_auth_context();
    Ok(SignalingControlClient::new(
        base_url,
        Some(settings.network.webrtc_client_api_key.clone()),
    )
    .with_user_auth(bearer_token, tenant_id))
}

#[cfg(feature = "webrtc")]
fn signaling_user_auth_context() -> (Option<String>, Option<String>) {
    let env_token = std::env::var("SKYBRIDGE_BEARER_TOKEN")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let env_tenant = std::env::var("SKYBRIDGE_TENANT_ID")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    if env_token.is_some() {
        return (env_token, env_tenant);
    }

    let mut auth = match AuthenticationService::new() {
        Ok(service) => service,
        Err(_) => return (None, env_tenant),
    };
    let session = match auth.load_persisted_session() {
        Ok(Some(session)) => session,
        _ => return (None, env_tenant),
    };
    (
        Some(session.token.access_token().to_string()),
        env_tenant.or_else(|| Some(session.user.user_id.clone())),
    )
}

#[cfg(feature = "webrtc")]
fn local_protocol_identity_binding(
    identity: &LocalIdentity,
) -> Result<ProtocolIdentityBinding, String> {
    let algorithm = SignatureAlgorithm::Ed25519;
    let public_key = identity
        .signing_public_key(algorithm)
        .ok_or_else(|| "Missing local protocol signing public key".to_string())?;
    Ok(ProtocolIdentityBinding::new(
        identity.device_id.clone(),
        algorithm,
        public_key,
    ))
}

#[cfg(feature = "webrtc")]
fn preferred_turn_uri(server_uris: &[String], override_url: &str) -> Option<String> {
    preferred_turn_uri_with_override(server_uris, override_url)
}

#[cfg(feature = "webrtc")]
async fn dynamic_ice_config(
    settings: &AppSettings,
    device_id: &str,
    turn_admission_token: Option<&str>,
) -> Result<IceConfig, String> {
    let control = signaling_control_client(settings)?;
    let dynamic = control
        .fetch_turn_credentials(turn_admission_token, Some(device_id))
        .await;

    let override_url = settings.network.webrtc_turn_url.trim();
    let override_username = settings.network.webrtc_turn_username.trim();
    let override_password = settings.network.webrtc_turn_password.trim();

    let (turn_url, turn_username, turn_password) = match dynamic {
        Ok(TurnCredentialResponse {
            username,
            password,
            uris,
            ..
        }) => {
            let selected = preferred_turn_uri(&uris, override_url).unwrap_or_default();
            if selected.is_empty() {
                tracing::warn!(
                    uris = ?uris,
                    "No TURN URI supported by the current Rust WebRTC runtime; continuing with STUN/direct candidates only"
                );
            } else {
                tracing::info!(selected_turn_url = %selected, uris = ?uris, "Selected TURN URI");
            }
            let username = if override_username.is_empty() {
                username.trim().to_string()
            } else {
                override_username.to_string()
            };
            let password = if override_password.is_empty() {
                password.trim().to_string()
            } else {
                override_password.to_string()
            };
            (selected, username, password)
        }
        Err(err) => {
            tracing::warn!(
                "TURN credentials unavailable, falling back to overrides/STUN: {}",
                err
            );
            (
                override_url.to_string(),
                override_username.to_string(),
                override_password.to_string(),
            )
        }
    };

    Ok(IceConfig {
        stun_url: settings.network.webrtc_stun_url.clone(),
        turn_url,
        turn_username,
        turn_password,
        relay_only: settings.deployment.relay_only_webrtc || settings.is_cloud_terminal(),
    })
}

mod autostart_linux;
mod tray;
mod ui_capture;

/// Authentication events for UI updates
enum AuthUiEvent {
    LoggedIn(UserSummary),
    PendingVerification(String),
    Info(String),
    Error(String),
}

enum DashboardUiEvent {
    ConnectionStatus(ConnectionUpdate),
    DevicesUpdated {
        devices: Vec<DiscoveredDevice>,
    },
    CrossNetworkCode {
        code: String,
    },
    #[cfg_attr(not(feature = "webrtc"), allow(dead_code))]
    CrossNetworkPeerHint {
        code: String,
        peer_id: Option<String>,
        peer_fingerprint: Option<String>,
    },
    #[cfg_attr(not(feature = "webrtc"), allow(dead_code))]
    CrossNetworkRoomStatus {
        code: String,
        status: String,
    },
}

enum UiEvent {
    AccountSyncFinished {
        ok: bool,
        message: String,
    },
    IncomingTransferPrompt {
        request: IncomingTransferRequest,
        decision_tx: tokio::sync::oneshot::Sender<IncomingTransferDecision>,
    },
    IncomingTransferCompleted(IncomingTransferCompleted),
    #[cfg_attr(not(feature = "webrtc"), allow(dead_code))]
    RemoteControlPrompt {
        session_id: String,
        sender_device_id: Option<String>,
        sender_device_name: Option<String>,
        decision_tx: tokio::sync::oneshot::Sender<bool>,
    },
}

struct PendingIncomingTransfer {
    request: IncomingTransferRequest,
    decision_tx: tokio::sync::oneshot::Sender<IncomingTransferDecision>,
    notification_id: String,
}

struct PendingRemoteControl {
    sender_device_id: Option<String>,
    sender_device_name: Option<String>,
    decision_tx: tokio::sync::oneshot::Sender<bool>,
    notification_id: String,
}

struct UserSummary {
    display_name: String,
    user_id: String,
    nebula_id: Option<String>,
}

struct StreamRequest {
    connection_id: String,
}

#[derive(Debug, Clone)]
struct RemoteDesktopBgraFrame {
    connection_id: String,
    width: u16,
    height: u16,
    bgra: Vec<u8>,
}

#[cfg(feature = "webrtc")]
struct WebRtcInboundFileTransfer {
    transfer_id: String,
    file_name: String,
    file_size: i64,
    chunk_size: i32,
    total_chunks: i32,
    temp_path: std::path::PathBuf,
    final_path: std::path::PathBuf,
    overwrite: bool,
    received_bytes: i64,
    file: tokio::fs::File,
    sender_device_id: Option<String>,
    sender_device_name: Option<String>,
}

#[cfg(feature = "webrtc")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RemoteControlApproval {
    Unknown,
    Pending,
    Approved,
    Denied,
}

#[cfg(feature = "webrtc")]
#[derive(Clone)]
struct WebRtcSessionState {
    dashboard_tx: mpsc::UnboundedSender<DashboardUiEvent>,
    ui_tx: mpsc::UnboundedSender<UiEvent>,
    inbound_transfers: Arc<tokio::sync::Mutex<HashMap<String, WebRtcInboundFileTransfer>>>,
    pending_transfers: Arc<tokio::sync::Mutex<std::collections::HashSet<String>>>,
    remote_approval: Arc<tokio::sync::Mutex<RemoteControlApproval>>,
}

#[cfg(feature = "webrtc")]
async fn send_webrtc_json<T: serde::Serialize>(
    handle: &skybridge_core::webrtc::WebRtcCrossNetworkHandle,
    msg: &T,
) {
    if let Ok(bytes) = serde_json::to_vec(msg) {
        let _ = handle.send_app_payload(bytes);
    }
}

#[cfg(feature = "webrtc")]
fn build_pairing_identity_exchange(identity: &LocalIdentity) -> AppMessage {
    let kem_public_keys = identity
        .kem_public_keys
        .iter()
        .filter(|(suite, _)| suite.is_pqc())
        .map(|(suite, public_key)| KemPublicKeyInfo {
            suite_wire_id: suite.wire_id(),
            public_key: public_key.clone(),
        })
        .collect();

    AppMessage::PairingIdentityExchange(PairingIdentityExchangePayload {
        device_id: identity.device_id.clone(),
        kem_public_keys,
        device_name: None,
        model_name: None,
        platform: Some("Ubuntu".to_string()),
        os_version: std::env::var("SKYBRIDGE_OS_VERSION").ok(),
        chip: None,
        remote_video_formats: Some(supported_remote_video_formats()),
        sent_at: SwiftDateSeconds::now(),
    })
}

#[cfg(feature = "webrtc")]
fn persist_peer_kem_keys(payload: &PairingIdentityExchangePayload) {
    if payload.device_id.trim().is_empty() {
        return;
    }
    let Ok(mut store) = TrustStore::load() else {
        return;
    };

    for key in &payload.kem_public_keys {
        let Some(suite) = CryptoSuiteId::from_wire_id(key.suite_wire_id) else {
            continue;
        };
        let _ = store.upsert_peer_kem_key(&payload.device_id, suite, key.public_key.clone());
    }
}

#[cfg(feature = "webrtc")]
fn pairing_kem_key_map(
    payload: &PairingIdentityExchangePayload,
) -> HashMap<CryptoSuiteId, Vec<u8>> {
    let mut keys = HashMap::new();
    for key in &payload.kem_public_keys {
        let Some(suite) = CryptoSuiteId::from_wire_id(key.suite_wire_id) else {
            continue;
        };
        keys.insert(suite, key.public_key.clone());
    }
    keys
}

#[cfg(feature = "webrtc")]
async fn maybe_start_outbound_webrtc_pqc_rekey(
    handle: &Arc<skybridge_core::webrtc::WebRtcCrossNetworkHandle>,
    identity: &LocalIdentity,
    payload: &PairingIdentityExchangePayload,
) {
    if payload.kem_public_keys.is_empty() {
        return;
    }

    let Some(should_initiate) = should_initiate_pqc_rekey(
        Some(identity.device_id.as_str()),
        Some(payload.device_id.as_str()),
    ) else {
        tracing::info!(
            "WebRTC PQC rekey waiting for stable initiator election: peer={}",
            payload.device_id
        );
        return;
    };

    if !should_initiate {
        tracing::info!(
            "WebRTC PQC rekey elected peer as initiator; waiting inbound rekey: peer={}",
            payload.device_id
        );
        return;
    }

    match handle
        .start_outbound_pqc_rekey(
            Some(payload.device_id.clone()),
            pairing_kem_key_map(payload),
        )
        .await
    {
        Ok(true) => tracing::info!(
            "WebRTC outbound PQC rekey started: peer={}",
            payload.device_id
        ),
        Ok(false) => {}
        Err(err) => tracing::warn!(
            "WebRTC outbound PQC rekey start failed (preserving session): peer={} err={}",
            payload.device_id,
            err
        ),
    }
}

#[cfg(feature = "webrtc")]
fn validate_inbound_webrtc_peer(
    settings: &AppSettings,
    payload: &PairingIdentityExchangePayload,
    peer_identity: Option<&PeerIdentity>,
) -> Result<Option<String>, String> {
    let policy = connection_trust_policy_from_settings(settings);
    let device_id = payload.device_id.trim();
    if device_id.is_empty() {
        if policy.block_unknown {
            return Err("Unknown device blocked: missing pairing device ID".to_string());
        }
        return Ok(None);
    }

    let actual_fingerprint = peer_identity
        .map(|identity| identity.public_key_fingerprint.as_str())
        .unwrap_or_default();
    enforce_inbound_trust_policy(policy, device_id, actual_fingerprint)
        .map_err(|err| err.to_string())?;
    Ok(Some(device_id.to_string()))
}

#[cfg(feature = "webrtc")]
fn persist_verified_webrtc_peer_identity(
    device_id: &str,
    peer_identity: Option<&PeerIdentity>,
) -> Result<(), String> {
    let Some(peer_identity) = peer_identity else {
        return Ok(());
    };
    let mut store =
        TrustStore::load().map_err(|err| format!("Trust store unavailable: {}", err))?;
    let verified_identity = PeerIdentity {
        device_id: device_id.to_string(),
        public_key_fingerprint: peer_identity.public_key_fingerprint.clone(),
        signing_algorithm: peer_identity.signing_algorithm,
        signing_public_key: peer_identity.signing_public_key.clone(),
        kem_public_key: peer_identity.kem_public_key.clone(),
        platform: peer_identity.platform,
        protocol_version: peer_identity.protocol_version.clone(),
    };
    store
        .upsert_peer_identity(&verified_identity)
        .map_err(|err| format!("Failed to persist verified peer identity: {}", err))?;
    store
        .upsert_current_path_authority(
            device_id,
            peer_identity.signing_algorithm,
            &peer_identity.public_key_fingerprint,
        )
        .map_err(|err| format!("Failed to persist current-path authority: {}", err))
}

#[cfg(feature = "webrtc")]
async fn fail_webrtc_session(
    session_id: &str,
    handle: &Arc<skybridge_core::webrtc::WebRtcCrossNetworkHandle>,
    state: &WebRtcSessionState,
    reason: String,
) {
    let _ = state
        .dashboard_tx
        .unbounded_send(DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
            message: format!("WebRTC {} failed: {}", session_id, reason),
            phase: ConnectionPhase::Failed,
            connection_id: Some(session_id.to_string()),
            peer_id: None,
            peer_name: None,
            streaming: None,
        }));
    let _ = handle.close().await;
}

fn sanitize_filename(name: &str) -> String {
    let base = std::path::Path::new(name)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("SkyBridgeFile");
    let trimmed = base.trim();
    if trimmed.is_empty() {
        "SkyBridgeFile".to_string()
    } else {
        trimmed.to_string()
    }
}

fn unique_destination(base_dir: &std::path::Path, file_name: &str) -> std::path::PathBuf {
    let safe = sanitize_filename(file_name);
    let mut candidate = base_dir.join(&safe);
    let stem = std::path::Path::new(&safe)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("SkyBridgeFile")
        .to_string();
    let ext = std::path::Path::new(&safe)
        .extension()
        .and_then(|s| s.to_str())
        .map(|s| s.to_string());
    let mut idx = 1;
    while candidate.exists() {
        let alt = if let Some(ext) = ext.as_ref() {
            format!("{} ({}) .{}", stem, idx, ext).replace(" .", ".")
        } else {
            format!("{} ({})", stem, idx)
        };
        candidate = base_dir.join(alt);
        idx += 1;
    }
    candidate
}

fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut size = bytes as f64;
    let mut unit = 0usize;
    while size >= 1024.0 && unit + 1 < UNITS.len() {
        size /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{} {}", bytes, UNITS[unit])
    } else {
        format!("{:.1} {}", size, UNITS[unit])
    }
}

fn finalize_incoming_transfer_decision(
    app: &adw::Application,
    pending: &Rc<RefCell<HashMap<String, PendingIncomingTransfer>>>,
    transfer_id: &str,
    decision: IncomingTransferDecision,
) {
    let entry = pending.borrow_mut().remove(transfer_id);
    if let Some(entry) = entry {
        app.withdraw_notification(&entry.notification_id);
        let _ = entry.decision_tx.send(decision);
    }
}

fn present_incoming_transfer_dialog(
    app: adw::Application,
    parent: adw::ApplicationWindow,
    pending: Rc<RefCell<HashMap<String, PendingIncomingTransfer>>>,
    transfer_id: String,
) {
    let request = pending
        .borrow()
        .get(&transfer_id)
        .map(|entry| entry.request.clone());
    let Some(request) = request else {
        return;
    };

    parent.present();

    let sender = request
        .sender_device_name
        .clone()
        .or(request.sender_device_id.clone())
        .unwrap_or_else(|| "Unknown device".to_string());
    let save_path = request.target_dir.join(&request.file_name);
    let confirm_overwrite = AppSettings::load().transfer.confirm_overwrite;
    let details = format!(
        "{} wants to send {} ({}).\nSave to {}",
        sender,
        request.file_name,
        format_bytes(request.file_size),
        save_path.display()
    );

    let dialog = adw::AlertDialog::new(Some("Incoming Transfer"), Some(&details));
    dialog.add_response("decline", "Decline");
    dialog.add_response("accept", "Accept");
    dialog.set_response_appearance("accept", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("accept"));
    dialog.set_close_response("decline");

    let app_clone = app.clone();
    let pending_clone = pending.clone();
    let transfer_id_clone = transfer_id.clone();
    let parent_clone = parent.clone();
    let save_path_clone = save_path.clone();
    dialog.connect_response(None, move |dialog, response| {
        if response == "accept" {
            if confirm_overwrite && save_path_clone.exists() {
                let overwrite_dialog = adw::AlertDialog::new(
                    Some("Overwrite existing file?"),
                    Some(&format!(
                        "“{}” already exists.\nOverwrite it?",
                        save_path_clone.display()
                    )),
                );
                overwrite_dialog.add_response("cancel", "Cancel");
                overwrite_dialog.add_response("overwrite", "Overwrite");
                overwrite_dialog
                    .set_response_appearance("overwrite", adw::ResponseAppearance::Destructive);
                overwrite_dialog.set_default_response(Some("cancel"));
                overwrite_dialog.set_close_response("cancel");

                let app2 = app_clone.clone();
                let pending2 = pending_clone.clone();
                let transfer_id2 = transfer_id_clone.clone();
                let save_path2 = save_path_clone.clone();
                overwrite_dialog.connect_response(None, move |dialog, response| {
                    if response == "overwrite" {
                        finalize_incoming_transfer_decision(
                            &app2,
                            &pending2,
                            &transfer_id2,
                            IncomingTransferDecision {
                                accept: true,
                                save_path: Some(save_path2.clone()),
                                overwrite: true,
                            },
                        );
                    }
                    dialog.close();
                });
                overwrite_dialog.present(Some(&parent_clone));
            } else {
                finalize_incoming_transfer_decision(
                    &app_clone,
                    &pending_clone,
                    &transfer_id_clone,
                    IncomingTransferDecision {
                        accept: true,
                        save_path: Some(save_path_clone.clone()),
                        overwrite: !confirm_overwrite,
                    },
                );
            }
        } else {
            finalize_incoming_transfer_decision(
                &app_clone,
                &pending_clone,
                &transfer_id_clone,
                IncomingTransferDecision::decline(),
            );
        }
        dialog.close();
    });
    dialog.present(Some(&parent));
}

fn finalize_remote_control_decision(
    app: &adw::Application,
    pending: &Rc<RefCell<HashMap<String, PendingRemoteControl>>>,
    session_id: &str,
    allow: bool,
) {
    let entry = pending.borrow_mut().remove(session_id);
    if let Some(entry) = entry {
        app.withdraw_notification(&entry.notification_id);
        let _ = entry.decision_tx.send(allow);
    }
}

fn present_remote_control_dialog(
    app: adw::Application,
    parent: adw::ApplicationWindow,
    pending: Rc<RefCell<HashMap<String, PendingRemoteControl>>>,
    session_id: String,
) {
    let entry = pending.borrow().get(&session_id).map(|entry| {
        (
            entry.sender_device_id.clone(),
            entry.sender_device_name.clone(),
        )
    });
    let Some((sender_device_id, sender_device_name)) = entry else {
        return;
    };

    parent.present();

    let sender = sender_device_name
        .or(sender_device_id)
        .unwrap_or_else(|| "Unknown device".to_string());
    let details = format!(
        "{} wants to control this device. Verified fingerprint matches trusted peer.",
        sender
    );

    let dialog = adw::AlertDialog::new(Some("Remote Control Request"), Some(&details));
    dialog.add_response("deny", "Deny");
    dialog.add_response("allow", "Allow");
    dialog.set_response_appearance("allow", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("deny"));
    dialog.set_close_response("deny");

    let app_clone = app.clone();
    let pending_clone = pending.clone();
    let session_id_clone = session_id.clone();
    dialog.connect_response(None, move |dialog, response| {
        let allow = response == "allow";
        finalize_remote_control_decision(&app_clone, &pending_clone, &session_id_clone, allow);
        dialog.close();
    });
    dialog.present(Some(&parent));
}

#[cfg(feature = "webrtc")]
async fn ensure_input_handler(
    input: &mut Option<UnifiedInputHandler>,
) -> Option<&UnifiedInputHandler> {
    if input.is_none() {
        let mut h = UnifiedInputHandler::new().ok()?;
        h.initialize().await.ok()?;
        *input = Some(h);
    }
    input.as_ref()
}

#[cfg(feature = "webrtc")]
#[allow(clippy::too_many_arguments)]
async fn handle_webrtc_app_payload(
    session_id: &str,
    handle: &Arc<skybridge_core::webrtc::WebRtcCrossNetworkHandle>,
    settings: &AppSettings,
    identity: &LocalIdentity,
    payload: &[u8],
    remote_frame_tx: &mpsc::UnboundedSender<RemoteDesktopBgraFrame>,
    state: &WebRtcSessionState,
    remote_video_state: &mut RemoteJsonVideoState,
    input: &mut Option<UnifiedInputHandler>,
) {
    // 0) AppMessage control payloads (macOS/iOS compatible, encrypted)
    if let Ok(msg) = serde_json::from_slice::<AppMessage>(payload) {
        if let AppMessage::PairingIdentityExchange(payload) = msg {
            let peer_identity = handle.peer_identity().await;
            let device_id =
                match validate_inbound_webrtc_peer(settings, &payload, peer_identity.as_ref()) {
                    Ok(device_id) => device_id,
                    Err(reason) => {
                        fail_webrtc_session(session_id, handle, state, reason).await;
                        return;
                    }
                };
            if let Some(device_id) = device_id.as_deref()
                && let Err(reason) =
                    persist_verified_webrtc_peer_identity(device_id, peer_identity.as_ref())
            {
                fail_webrtc_session(session_id, handle, state, reason).await;
                return;
            }
            persist_peer_kem_keys(&payload);
            // Best-effort: reply with our bundle (idempotent).
            if identity.supported_suites.iter().any(|s| s.is_pqc()) {
                send_webrtc_json(handle.as_ref(), &build_pairing_identity_exchange(identity)).await;
                maybe_start_outbound_webrtc_pqc_rekey(handle, identity, &payload).await;
            }
        }
        return;
    }

    // 1) Cross-network file transfer (macOS/iOS JSON wire)
    if let Ok(msg) = serde_json::from_slice::<CrossNetworkFileTransferMessage>(payload) {
        match msg.op {
            CrossNetworkFileTransferOp::Metadata => {
                let file_name = match msg.file_name.as_deref() {
                    Some(v) => v.to_string(),
                    None => {
                        let err = CrossNetworkFileTransferMessage {
                            message: Some("Invalid metadata (missing fileName)".to_string()),
                            ..CrossNetworkFileTransferMessage::new(
                                CrossNetworkFileTransferOp::Error,
                                msg.transfer_id.clone(),
                            )
                        };
                        send_webrtc_json(handle.as_ref(), &err).await;
                        return;
                    }
                };
                let file_size = match msg.file_size {
                    Some(v) if v > 0 => v,
                    _ => {
                        let err = CrossNetworkFileTransferMessage {
                            message: Some("Invalid metadata (missing fileSize)".to_string()),
                            ..CrossNetworkFileTransferMessage::new(
                                CrossNetworkFileTransferOp::Error,
                                msg.transfer_id.clone(),
                            )
                        };
                        send_webrtc_json(handle.as_ref(), &err).await;
                        return;
                    }
                };
                let chunk_size = match msg.chunk_size {
                    Some(v) if v > 0 => v,
                    _ => 64 * 1024,
                };
                let total_chunks = msg.total_chunks.unwrap_or(0).max(0);

                let transfer_id = msg.transfer_id.clone();
                {
                    let map = state.inbound_transfers.lock().await;
                    if map.contains_key(&transfer_id) {
                        return;
                    }
                }
                {
                    let mut pending = state.pending_transfers.lock().await;
                    if pending.contains(&transfer_id) {
                        return;
                    }
                    pending.insert(transfer_id.clone());
                }

                let safe_name = sanitize_filename(&file_name);
                let request = IncomingTransferRequest {
                    source: IncomingTransferSource::WebRtcDataChannel,
                    transfer_id: transfer_id.clone(),
                    file_name: safe_name,
                    file_size: file_size as u64,
                    sender_device_id: msg.sender_device_id.clone(),
                    sender_device_name: msg.sender_device_name.clone(),
                    target_dir: settings.transfer.save_location.clone(),
                };

                let handle = handle.clone();
                let ui_tx = state.ui_tx.clone();
                let inbound_transfers = Arc::clone(&state.inbound_transfers);
                let pending_transfers = Arc::clone(&state.pending_transfers);
                tokio::spawn(async move {
                    let settings = AppSettings::load();
                    let is_trusted = request
                        .sender_device_id
                        .as_deref()
                        .and_then(|device_id| {
                            TrustStore::load().ok().map(|ts| ts.is_trusted(device_id))
                        })
                        .unwrap_or(false);

                    let decision = if settings.transfer.auto_accept_trusted && is_trusted {
                        let base_dir = settings.transfer.save_location;
                        let mut save_path = base_dir.join(&request.file_name);
                        let overwrite = !settings.transfer.confirm_overwrite;
                        if settings.transfer.confirm_overwrite && save_path.exists() {
                            save_path = unique_destination(&base_dir, &request.file_name);
                        }
                        IncomingTransferDecision {
                            accept: true,
                            save_path: Some(save_path),
                            overwrite,
                        }
                    } else {
                        let (tx, rx) = tokio::sync::oneshot::channel::<IncomingTransferDecision>();
                        if ui_tx
                            .unbounded_send(UiEvent::IncomingTransferPrompt {
                                request: request.clone(),
                                decision_tx: tx,
                            })
                            .is_err()
                        {
                            IncomingTransferDecision::decline()
                        } else {
                            match tokio::time::timeout(
                                std::time::Duration::from_secs(
                                    INCOMING_TRANSFER_DECISION_TIMEOUT_SECS,
                                ),
                                rx,
                            )
                            .await
                            {
                                Ok(Ok(d)) => d,
                                _ => IncomingTransferDecision::decline(),
                            }
                        }
                    };

                    if !decision.accept {
                        let err = CrossNetworkFileTransferMessage {
                            message: Some("Declined".to_string()),
                            ..CrossNetworkFileTransferMessage::new(
                                CrossNetworkFileTransferOp::Error,
                                transfer_id.clone(),
                            )
                        };
                        send_webrtc_json(handle.as_ref(), &err).await;
                        pending_transfers.lock().await.remove(&transfer_id);
                        return;
                    }

                    let Some(mut final_path) = decision.save_path else {
                        let err = CrossNetworkFileTransferMessage {
                            message: Some("Missing save path".to_string()),
                            ..CrossNetworkFileTransferMessage::new(
                                CrossNetworkFileTransferOp::Error,
                                transfer_id.clone(),
                            )
                        };
                        send_webrtc_json(handle.as_ref(), &err).await;
                        pending_transfers.lock().await.remove(&transfer_id);
                        return;
                    };

                    if !decision.overwrite && final_path.exists() {
                        let base = final_path.parent().unwrap_or(request.target_dir.as_path());
                        final_path = unique_destination(base, &request.file_name);
                    }
                    if let Some(parent) = final_path.parent() {
                        let _ = tokio::fs::create_dir_all(parent).await;
                    }
                    let temp_dir = final_path
                        .parent()
                        .map(|p| p.to_path_buf())
                        .unwrap_or_else(|| request.target_dir.clone());
                    let temp_path = temp_dir.join(format!(".skybridge-{}.partial", transfer_id));
                    let file = match tokio::fs::File::create(&temp_path).await {
                        Ok(f) => f,
                        Err(e) => {
                            let err = CrossNetworkFileTransferMessage {
                                message: Some(format!("Open temp file failed: {}", e)),
                                ..CrossNetworkFileTransferMessage::new(
                                    CrossNetworkFileTransferOp::Error,
                                    transfer_id.clone(),
                                )
                            };
                            send_webrtc_json(handle.as_ref(), &err).await;
                            pending_transfers.lock().await.remove(&transfer_id);
                            return;
                        }
                    };

                    {
                        let mut map = inbound_transfers.lock().await;
                        map.insert(
                            transfer_id.clone(),
                            WebRtcInboundFileTransfer {
                                transfer_id: transfer_id.clone(),
                                file_name: request.file_name.clone(),
                                file_size: request.file_size as i64,
                                chunk_size,
                                total_chunks,
                                temp_path,
                                final_path,
                                overwrite: decision.overwrite,
                                received_bytes: 0,
                                file,
                                sender_device_id: request.sender_device_id.clone(),
                                sender_device_name: request.sender_device_name.clone(),
                            },
                        );
                    }

                    let ack = CrossNetworkFileTransferMessage::new(
                        CrossNetworkFileTransferOp::MetadataAck,
                        transfer_id.clone(),
                    );
                    send_webrtc_json(handle.as_ref(), &ack).await;
                    pending_transfers.lock().await.remove(&transfer_id);
                });
            }
            CrossNetworkFileTransferOp::Chunk => {
                let idx = match msg.chunk_index {
                    Some(v) if v >= 0 => v,
                    _ => return,
                };
                let data = match msg.chunk_data {
                    Some(d) => d,
                    None => return,
                };
                let (transfer_id, received_bytes) = {
                    let mut inbound_transfers = state.inbound_transfers.lock().await;
                    let Some(st) = inbound_transfers.get_mut(&msg.transfer_id) else {
                        let err = CrossNetworkFileTransferMessage {
                            message: Some("Unknown transferId (no metadata)".to_string()),
                            ..CrossNetworkFileTransferMessage::new(
                                CrossNetworkFileTransferOp::Error,
                                msg.transfer_id.clone(),
                            )
                        };
                        send_webrtc_json(handle.as_ref(), &err).await;
                        return;
                    };

                    use tokio::io::{AsyncSeekExt, AsyncWriteExt};
                    let raw_size = msg.raw_size.unwrap_or(data.len() as i32).max(0) as i64;
                    if st.total_chunks > 0 && idx >= st.total_chunks {
                        let err = CrossNetworkFileTransferMessage {
                            message: Some(format!(
                                "Invalid chunk index {} (total {})",
                                idx, st.total_chunks
                            )),
                            ..CrossNetworkFileTransferMessage::new(
                                CrossNetworkFileTransferOp::Error,
                                msg.transfer_id.clone(),
                            )
                        };
                        send_webrtc_json(handle.as_ref(), &err).await;
                        return;
                    }
                    let offset = (idx as i64) * (st.chunk_size as i64);
                    if st
                        .file
                        .seek(std::io::SeekFrom::Start(offset.max(0) as u64))
                        .await
                        .is_ok()
                        && st.file.write_all(&data).await.is_ok()
                    {
                        st.received_bytes =
                            st.received_bytes.max(offset + raw_size).min(st.file_size);
                    }
                    (st.transfer_id.clone(), st.received_bytes)
                };

                let mut ack = CrossNetworkFileTransferMessage::new(
                    CrossNetworkFileTransferOp::ChunkAck,
                    transfer_id,
                );
                ack.chunk_index = Some(idx);
                ack.received_bytes = Some(received_bytes);
                send_webrtc_json(handle.as_ref(), &ack).await;
            }
            CrossNetworkFileTransferOp::Complete => {
                let Some(st) = ({
                    let mut inbound_transfers = state.inbound_transfers.lock().await;
                    inbound_transfers.remove(&msg.transfer_id)
                }) else {
                    return;
                };
                let _ = st.file.sync_all().await;
                let mut final_path = st.final_path.clone();
                if !st.overwrite && final_path.exists() {
                    let base = final_path
                        .parent()
                        .unwrap_or_else(|| std::path::Path::new("."));
                    final_path = unique_destination(base, &st.file_name);
                }
                let rename_result = tokio::fs::rename(&st.temp_path, &final_path).await;

                let ack = CrossNetworkFileTransferMessage::new(
                    CrossNetworkFileTransferOp::CompleteAck,
                    st.transfer_id.clone(),
                );
                send_webrtc_json(handle.as_ref(), &ack).await;

                let (success, error, save_path) = match rename_result {
                    Ok(()) => (true, None, Some(final_path)),
                    Err(err) => (false, Some(err.to_string()), None),
                };
                let _ = state
                    .ui_tx
                    .unbounded_send(UiEvent::IncomingTransferCompleted(
                        IncomingTransferCompleted {
                            source: IncomingTransferSource::WebRtcDataChannel,
                            transfer_id: st.transfer_id.clone(),
                            file_name: st.file_name,
                            save_path,
                            success,
                            received_bytes: st.received_bytes.max(0) as u64,
                            error,
                            sender_device_id: st.sender_device_id,
                            sender_device_name: st.sender_device_name,
                        },
                    ));
            }
            CrossNetworkFileTransferOp::Cancel => {
                if let Some(st) = {
                    let mut inbound_transfers = state.inbound_transfers.lock().await;
                    inbound_transfers.remove(&msg.transfer_id)
                } {
                    let _ = tokio::fs::remove_file(&st.temp_path).await;
                }
            }
            CrossNetworkFileTransferOp::Error
            | CrossNetworkFileTransferOp::MetadataAck
            | CrossNetworkFileTransferOp::ChunkAck
            | CrossNetworkFileTransferOp::CompleteAck => {
                // For now we only implement inbound receive path; outbound sender can be added next.
            }
        }
        return;
    }

    // 2) Remote desktop/control messages (macOS/iOS JSON wire)
    if let Ok(msg) = serde_json::from_slice::<RemoteMessageWire>(payload) {
        match msg.msg_type {
            RemoteMessageTypeWire::ScreenData => {
                let Ok(screen) = serde_json::from_slice::<ScreenDataWire>(&msg.payload) else {
                    return;
                };
                match remote_video_state.decode_screen_data(&screen) {
                    Ok(Some(frame)) => {
                        let _ = remote_frame_tx.unbounded_send(RemoteDesktopBgraFrame {
                            connection_id: session_id.to_string(),
                            width: frame.width,
                            height: frame.height,
                            bgra: frame.bgra,
                        });
                    }
                    Ok(None) => {}
                    Err(err) => {
                        tracing::debug!(
                            "Remote JSON screen decode failed for {}: {}",
                            session_id,
                            err
                        );
                    }
                }
            }
            RemoteMessageTypeWire::MouseEvent => {
                if !settings.remote_desktop.allow_control {
                    return;
                }
                if settings.remote_desktop.require_confirmation {
                    let mut approval = state.remote_approval.lock().await;
                    match *approval {
                        RemoteControlApproval::Approved => {}
                        RemoteControlApproval::Denied | RemoteControlApproval::Pending => {
                            return;
                        }
                        RemoteControlApproval::Unknown => {
                            *approval = RemoteControlApproval::Pending;
                            drop(approval);
                            let ui_tx = state.ui_tx.clone();
                            let approval_state = Arc::clone(&state.remote_approval);
                            let session_id = session_id.to_string();
                            tokio::spawn(async move {
                                let (tx, rx) = tokio::sync::oneshot::channel::<bool>();
                                let _ = ui_tx.unbounded_send(UiEvent::RemoteControlPrompt {
                                    session_id: session_id.clone(),
                                    sender_device_id: None,
                                    sender_device_name: None,
                                    decision_tx: tx,
                                });
                                let allow = match tokio::time::timeout(
                                    std::time::Duration::from_secs(
                                        INCOMING_TRANSFER_DECISION_TIMEOUT_SECS,
                                    ),
                                    rx,
                                )
                                .await
                                {
                                    Ok(Ok(v)) => v,
                                    _ => false,
                                };
                                let mut approval = approval_state.lock().await;
                                *approval = if allow {
                                    RemoteControlApproval::Approved
                                } else {
                                    RemoteControlApproval::Denied
                                };
                            });
                            return;
                        }
                    }
                }
                let Some(handler) = ensure_input_handler(input).await else {
                    return;
                };
                if let Ok(evt) = serde_json::from_slice::<MouseEventWire>(&msg.payload) {
                    let x = evt.x as i32;
                    let y = evt.y as i32;
                    match evt.event_type {
                        MouseEventTypeWire::MouseMoved => {
                            let _ = handler.send_mouse(&MouseEvent::move_to(x, y)).await;
                        }
                        MouseEventTypeWire::LeftMouseDown => {
                            let _ = handler
                                .send_mouse(&MouseEvent::button_down(MouseButton::Left, x, y))
                                .await;
                        }
                        MouseEventTypeWire::LeftMouseUp => {
                            let _ = handler
                                .send_mouse(&MouseEvent::button_up(MouseButton::Left, x, y))
                                .await;
                        }
                        MouseEventTypeWire::RightMouseDown => {
                            let _ = handler
                                .send_mouse(&MouseEvent::button_down(MouseButton::Right, x, y))
                                .await;
                        }
                        MouseEventTypeWire::RightMouseUp => {
                            let _ = handler
                                .send_mouse(&MouseEvent::button_up(MouseButton::Right, x, y))
                                .await;
                        }
                        MouseEventTypeWire::ScrollUp => {
                            let _ = handler.send_mouse(&MouseEvent::scroll(0, -1, x, y)).await;
                        }
                        MouseEventTypeWire::ScrollDown => {
                            let _ = handler.send_mouse(&MouseEvent::scroll(0, 1, x, y)).await;
                        }
                    }
                }
            }
            RemoteMessageTypeWire::KeyboardEvent => {
                if !settings.remote_desktop.allow_control {
                    return;
                }
                if settings.remote_desktop.require_confirmation {
                    let mut approval = state.remote_approval.lock().await;
                    match *approval {
                        RemoteControlApproval::Approved => {}
                        RemoteControlApproval::Denied | RemoteControlApproval::Pending => {
                            return;
                        }
                        RemoteControlApproval::Unknown => {
                            *approval = RemoteControlApproval::Pending;
                            drop(approval);
                            let ui_tx = state.ui_tx.clone();
                            let approval_state = Arc::clone(&state.remote_approval);
                            let session_id = session_id.to_string();
                            tokio::spawn(async move {
                                let (tx, rx) = tokio::sync::oneshot::channel::<bool>();
                                let _ = ui_tx.unbounded_send(UiEvent::RemoteControlPrompt {
                                    session_id: session_id.clone(),
                                    sender_device_id: None,
                                    sender_device_name: None,
                                    decision_tx: tx,
                                });
                                let allow = match tokio::time::timeout(
                                    std::time::Duration::from_secs(
                                        INCOMING_TRANSFER_DECISION_TIMEOUT_SECS,
                                    ),
                                    rx,
                                )
                                .await
                                {
                                    Ok(Ok(v)) => v,
                                    _ => false,
                                };
                                let mut approval = approval_state.lock().await;
                                *approval = if allow {
                                    RemoteControlApproval::Approved
                                } else {
                                    RemoteControlApproval::Denied
                                };
                            });
                            return;
                        }
                    }
                }
                let Some(handler) = ensure_input_handler(input).await else {
                    return;
                };
                if let Ok(evt) = serde_json::from_slice::<KeyboardEventWire>(&msg.payload) {
                    // NOTE: macOS/iOS keyCode is platform-specific. For now we pass it through as keysym.
                    let keysym = evt.key_code.max(0) as u32;
                    let ev = match evt.event_type {
                        KeyboardEventTypeWire::KeyDown => {
                            KeyEvent::key_down(keysym, Default::default())
                        }
                        KeyboardEventTypeWire::KeyUp => {
                            KeyEvent::key_up(keysym, Default::default())
                        }
                    };
                    let _ = handler.send_key(&ev).await;
                }
            }
            RemoteMessageTypeWire::Clipboard
            | RemoteMessageTypeWire::StreamConfiguration
            | RemoteMessageTypeWire::DamageReport
            | RemoteMessageTypeWire::CursorUpdate
            | RemoteMessageTypeWire::OverlayUpdate => {}
        }
    }

    // Unknown payload: ignore.
}
fn normalize_connection_code(raw: &str) -> Option<String> {
    let code: String = raw
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(10)
        .collect::<String>()
        .to_uppercase();
    if (6..=10).contains(&code.len()) {
        Some(code)
    } else {
        None
    }
}

fn spawn_mac_remote_control_server(
    runtime: &Arc<tokio::runtime::Runtime>,
    config: MacRemoteControlServerConfig,
) -> tokio::task::JoinHandle<()> {
    let server = MacRemoteControlServer::new(config);
    runtime.spawn(async move {
        if let Err(err) = server.serve().await {
            tracing::error!("Remote control server stopped: {}", err);
        }
    })
}

fn spawn_vnc_server(
    runtime: &Arc<tokio::runtime::Runtime>,
    config: VncServerConfig,
) -> tokio::task::JoinHandle<()> {
    let vnc_server = VncServer::new(config);
    runtime.spawn(async move {
        if let Err(err) = vnc_server.serve().await {
            tracing::error!("VNC server stopped: {}", err);
        }
    })
}

fn spawn_transfer_server(
    runtime: &Arc<tokio::runtime::Runtime>,
    config: FileTransferServerConfig,
    transfer_engine: Arc<FileTransferEngine>,
    transfer_keys: Arc<TransferKeyStore>,
) -> tokio::task::JoinHandle<()> {
    let transfer_server = FileTransferServer::new(config, transfer_engine, transfer_keys);
    runtime.spawn(async move {
        if let Err(err) = transfer_server.serve().await {
            tracing::error!("File transfer server stopped: {}", err);
        }
    })
}

/// Sidebar UI handles
struct Sidebar {
    widget: gtk::Box,
    user_name: gtk::Label,
    user_id: gtk::Label,
    nav_buttons: HashMap<String, gtk::Button>,
    settings_btn: gtk::Button,
}

impl Sidebar {
    fn set_selected(&self, selected_id: &str) {
        for (id, btn) in &self.nav_buttons {
            if id == selected_id {
                btn.add_css_class("selected");
            } else {
                btn.remove_css_class("selected");
            }
        }
    }
}

fn main() -> glib::ExitCode {
    if let Some(exit_code) = maybe_run_portal_command() {
        return exit_code;
    }

    let initial_settings = AppSettings::load();
    let log_level = match initial_settings.developer.log_level {
        LogLevel::Error => Level::ERROR,
        LogLevel::Warn => Level::WARN,
        LogLevel::Info => Level::INFO,
        LogLevel::Debug => Level::DEBUG,
        LogLevel::Trace => Level::TRACE,
    };

    // Initialize logging
    let subscriber = FmtSubscriber::builder().with_max_level(log_level).finish();
    tracing::subscriber::set_global_default(subscriber).expect("setting default subscriber failed");

    info!("Starting SkyBridge Compass for Ubuntu");

    // Initialize libadwaita
    let mut app_builder = adw::Application::builder().application_id(APP_ID);
    if std::env::var("SKYBRIDGE_UI_CAPTURE_ID").is_ok() {
        app_builder = app_builder.flags(gio::ApplicationFlags::NON_UNIQUE);
    }
    let app = app_builder.build();

    app.connect_activate(build_ui);

    app.run()
}

fn build_ui(app: &adw::Application) {
    // Initialize CSS
    skybridge_ui::utils::init_css();
    init_app_icon_theme();

    if ui_capture::maybe_run_ui_capture(app) {
        return;
    }

    let runtime = Arc::new(
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("Failed to create Tokio runtime"),
    );
    let _tokio_runtime_guard = runtime.enter();

    let settings = AppSettings::load();
    let identity = match LocalIdentityStore::load_or_generate(CryptoSuiteId::all()) {
        Ok(identity) => identity,
        Err(err) => {
            tracing::error!("Failed to initialize local identity: {}", err);
            return;
        }
    };
    let quic_port = settings.network.quic_port;
    let mut p2p_manager = match P2PConnectionManager::new(
        identity.clone(),
        format!("0.0.0.0:{}", quic_port).parse().unwrap(),
    ) {
        Ok(manager) => manager,
        Err(err) => {
            tracing::error!("Failed to initialize P2P manager: {}", err);
            return;
        }
    };
    let transfer_engine = Arc::new(FileTransferEngine::new());
    let transfer_keys = Arc::new(TransferKeyStore::new());
    p2p_manager.set_transfer_key_store(Arc::clone(&transfer_keys));
    let mut p2p_manager = Arc::new(p2p_manager);

    let auth = Arc::new(tokio::sync::Mutex::new(
        AuthenticationService::new().expect("Failed to initialize auth service"),
    ));

    let login_page = Rc::new(LoginPage::new());
    let (auth_tx, mut auth_rx) = mpsc::unbounded::<AuthUiEvent>();
    let (ui_tx, mut ui_rx) = mpsc::unbounded::<UiEvent>();

    // Create main window
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .icon_name(APP_ID)
        .title("SkyBridge Compass")
        .default_width(1200)
        .default_height(800)
        .build();
    window.add_css_class("main-window");

    // System tray (SNI) and close-to-tray behavior.
    let (tray_ui_tx, mut tray_ui_rx) = mpsc::unbounded::<tray::TrayUiEvent>();
    {
        let window = window.clone();
        let app = app.clone();
        glib::MainContext::default().spawn_local(async move {
            while let Some(event) = tray_ui_rx.next().await {
                match event {
                    tray::TrayUiEvent::ShowWindow => {
                        window.present();
                    }
                    tray::TrayUiEvent::HideWindow => {
                        window.set_visible(false);
                    }
                    tray::TrayUiEvent::Quit => {
                        app.quit();
                    }
                }
            }
        });
    }
    window.connect_close_request(move |win| {
        let settings = AppSettings::load();
        if settings.device.show_tray_icon && settings.device.minimize_to_tray {
            win.set_visible(false);
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });

    let tray_handle: Arc<tokio::sync::Mutex<Option<ksni::Handle<tray::CompassTray>>>> =
        Arc::new(tokio::sync::Mutex::new(None));
    {
        let tray_handle = Arc::clone(&tray_handle);
        let initial_visible = settings.device.show_tray_icon;
        let tray_ui_tx = tray_ui_tx.clone();
        runtime.spawn(async move {
            match tray::spawn_tray(tray::CompassTray::new(tray_ui_tx, initial_visible)).await {
                Ok(handle) => {
                    *tray_handle.lock().await = Some(handle);
                }
                Err(err) => {
                    tracing::warn!("Tray service unavailable: {}", err);
                }
            }
        });
    }

    // Main horizontal split
    let main_paned = gtk::Paned::builder()
        .orientation(gtk::Orientation::Horizontal)
        .shrink_start_child(false)
        .resize_start_child(false)
        .margin_start(24)
        .margin_end(24)
        .margin_top(24)
        .margin_bottom(24)
        .build();
    main_paned.add_css_class("app-shell");
    main_paned.set_overflow(gtk::Overflow::Hidden);

    // Sidebar
    let sidebar = Rc::new(create_sidebar());
    main_paned.set_start_child(Some(&sidebar.widget));

    // Content area with view stack
    let view_stack = adw::ViewStack::builder().build();
    view_stack.add_css_class("content-stack");
    view_stack.set_hexpand(true);
    view_stack.set_vexpand(true);

    // Add pages
    let dashboard_page = Rc::new(DashboardPage::new());
    view_stack.add_titled(&dashboard_page.widget, Some("dashboard"), "Main Console");

    let devices_page = Rc::new(DevicesPage::new());
    view_stack.add_titled(&devices_page.widget, Some("devices"), "Device Discovery");

    let transfers_page = TransfersPage::new();
    view_stack.add_titled(&transfers_page.widget, Some("transfers"), "File Transfer");

    let usb_page = Rc::new(UsbPage::new());
    view_stack.add_titled(&usb_page.widget, Some("usb"), "USB Management");

    let remote_page = Rc::new(RemotePage::new());
    view_stack.add_titled(&remote_page.widget, Some("remote"), "Remote Desktop");

    let monitoring_page = Rc::new(MonitorPage::new());
    view_stack.add_titled(
        &monitoring_page.widget,
        Some("monitoring"),
        "System Monitor",
    );

    let settings_page = Rc::new(SettingsPage::new());
    view_stack.add_titled(&settings_page.widget, Some("settings"), "Settings");

    // Wire sidebar navigation
    for (id, button) in &sidebar.nav_buttons {
        let view_stack = view_stack.clone();
        let sidebar = sidebar.clone();
        let id = id.clone();
        button.connect_clicked(move |_| {
            view_stack.set_visible_child_name(&id);
            sidebar.set_selected(&id);
        });
    }
    {
        let view_stack = view_stack.clone();
        let sidebar = sidebar.clone();
        let settings_btn = sidebar.settings_btn.clone();
        settings_btn.connect_clicked(move |_| {
            view_stack.set_visible_child_name("settings");
            sidebar.set_selected("settings");
        });
    }

    // Remote desktop preview window (lazy): receives decoded BGRA frames from background tasks.
    let (remote_frame_tx, mut remote_frame_rx) = mpsc::unbounded::<RemoteDesktopBgraFrame>();
    let remote_window_state: Rc<
        RefCell<Option<(adw::ApplicationWindow, gtk::Picture, gtk::Label)>>,
    > = Rc::new(RefCell::new(None));
    {
        let remote_window_state = remote_window_state.clone();
        let app = app.clone();
        let parent = window.clone();
        glib::MainContext::default().spawn_local(async move {
            while let Some(frame) = remote_frame_rx.next().await {
                let (win, picture, meta_label) = {
                    let mut guard = remote_window_state.borrow_mut();
                    if guard.is_none() {
                        let win = adw::ApplicationWindow::builder()
                            .application(&app)
                            .title("Remote Desktop")
                            .default_width(1280)
                            .default_height(720)
                            .build();
                        win.set_transient_for(Some(&parent));

                        let root = gtk::Box::builder()
                            .orientation(gtk::Orientation::Vertical)
                            .spacing(6)
                            .margin_top(6)
                            .margin_bottom(6)
                            .margin_start(6)
                            .margin_end(6)
                            .build();

                        let meta_label = gtk::Label::builder()
                            .label("Waiting for frames…")
                            .xalign(0.0)
                            .css_classes(vec!["dim-label".to_string()])
                            .build();
                        root.append(&meta_label);

                        let picture = gtk::Picture::new();
                        picture.set_hexpand(true);
                        picture.set_vexpand(true);
                        picture.set_content_fit(gtk::ContentFit::Contain);
                        root.append(&picture);

                        win.set_content(Some(&root));
                        win.present();

                        *guard = Some((win, picture, meta_label));
                    }
                    guard.as_ref().unwrap().clone()
                };

                meta_label.set_text(&format!(
                    "{} • {}×{}",
                    frame.connection_id, frame.width, frame.height
                ));

                let expected = frame.width as usize * frame.height as usize * 4;
                if frame.bgra.len() < expected {
                    continue;
                }

                let bytes = glib::Bytes::from_owned(frame.bgra);
                let stride = frame.width as usize * 4;
                let texture = gdk::MemoryTexture::new(
                    frame.width as i32,
                    frame.height as i32,
                    gdk::MemoryFormat::B8g8r8a8,
                    &bytes,
                    stride,
                );
                picture.set_paintable(Some(&texture));
                win.present();
            }
        });
    }

    let (dashboard_tx, mut dashboard_rx) = mpsc::unbounded::<DashboardUiEvent>();
    let (stream_tx, stream_rx) = tokio::sync::mpsc::unbounded_channel::<StreamRequest>();
    let connection_names = Arc::new(RwLock::new(HashMap::<String, String>::new()));

    // TCP control channel (macOS/iOS compatible): listen on the same port we advertise via _skybridge._tcp.
    let mut tcp_control =
        TcpControlService::new(identity.clone(), handshake_policy_from_settings(&settings));
    tcp_control.set_trust_policy(connection_trust_policy_from_settings(&settings));
    tcp_control.set_transfer_key_store(Arc::clone(&transfer_keys));
    let remote_packet_routes: Arc<
        std::sync::Mutex<HashMap<String, tokio::sync::mpsc::Sender<Vec<u8>>>>,
    > = Arc::new(std::sync::Mutex::new(HashMap::new()));
    let connection_peer_ids: Arc<std::sync::Mutex<HashMap<String, String>>> =
        Arc::new(std::sync::Mutex::new(HashMap::new()));
    let dashboard_tx_tcp = dashboard_tx.clone();
    let connection_names_tcp = Arc::clone(&connection_names);
    let remote_packet_routes_tcp = Arc::clone(&remote_packet_routes);
    let connection_peer_ids_tcp = Arc::clone(&connection_peer_ids);
    let transfer_keys_tcp = Arc::clone(&transfer_keys);
    let remote_frame_tx_tcp = remote_frame_tx.clone();
    tcp_control.on_event(move |evt| match evt {
        TcpControlEvent::HandshakeEstablished {
            connection_id,
            peer_device_id,
            suite,
            session_keys,
            ..
        } => {
            let peer_name = connection_names_tcp
                .read()
                .ok()
                .and_then(|map| map.get(&connection_id).cloned());
            if let Some(peer_id) = peer_device_id.as_ref()
                && let Ok(mut map) = connection_peer_ids_tcp.lock()
            {
                map.insert(connection_id.clone(), peer_id.clone());
            }
            let message = if let Some(name) = peer_name.as_ref() {
                format!("Connected (TCP) to {} [{:?}]", name, suite)
            } else if let Some(peer_id) = peer_device_id.as_ref() {
                format!("Connected (TCP) to {} [{:?}]", peer_id, suite)
            } else {
                format!("Connected (TCP) [{}]", suite.wire_id())
            };
            let _ = dashboard_tx_tcp.unbounded_send(DashboardUiEvent::ConnectionStatus(
                ConnectionUpdate {
                    message,
                    phase: ConnectionPhase::Connected,
                    connection_id: Some(connection_id.clone()),
                    peer_id: peer_device_id,
                    peer_name,
                    streaming: None,
                },
            ));

            // Remote desktop: set up a per-connection decoder pipeline (best-effort).
            let (tx, rx) = tokio::sync::mpsc::channel::<Vec<u8>>(16);
            if let Ok(mut map) = remote_packet_routes_tcp.lock() {
                map.insert(connection_id.clone(), tx);
            }
            let ui_tx = remote_frame_tx_tcp.clone();
            let _ = std::thread::Builder::new()
                .name("skybridge-rd-decode".to_string())
                .spawn(move || {
                    run_tcp_control_remote_desktop_decoder(connection_id, session_keys, rx, ui_tx);
                });
        }
        TcpControlEvent::Failed {
            connection_id,
            error,
            ..
        } => {
            let peer_name = connection_names_tcp
                .read()
                .ok()
                .and_then(|map| map.get(&connection_id).cloned());
            let _ = dashboard_tx_tcp.unbounded_send(DashboardUiEvent::ConnectionStatus(
                ConnectionUpdate {
                    message: format!("TCP control failed: {}", error),
                    phase: ConnectionPhase::Failed,
                    connection_id: Some(connection_id.clone()),
                    peer_id: None,
                    peer_name,
                    streaming: None,
                },
            ));

            if let Ok(mut map) = remote_packet_routes_tcp.lock() {
                map.remove(&connection_id);
            }
            if let Ok(mut map) = connection_peer_ids_tcp.lock() {
                map.remove(&connection_id);
            }
        }
        TcpControlEvent::RemoteDesktopFrame {
            connection_id,
            payload,
            ..
        } => {
            if let Ok(map) = remote_packet_routes_tcp.lock()
                && let Some(tx) = map.get(&connection_id)
            {
                let _ = tx.try_send(payload);
            }
        }
        TcpControlEvent::Disconnected { connection_id, .. } => {
            if let Ok(mut map) = remote_packet_routes_tcp.lock() {
                map.remove(&connection_id);
            }
            let peer_id = if let Ok(mut map) = connection_peer_ids_tcp.lock() {
                map.remove(&connection_id)
            } else {
                None
            };
            if let Some(peer_id) = peer_id
                && AppSettings::load().security.clear_keys_on_disconnect
            {
                transfer_keys_tcp.remove(&peer_id);
            }
        }
        _ => {}
    });
    let tcp_control = Arc::new(tcp_control);
    let tcp_control_listen = Arc::clone(&tcp_control);
    runtime.spawn(async move {
        let bind: std::net::SocketAddr = format!("0.0.0.0:{}", quic_port).parse().unwrap();
        let _ = tcp_control_listen.start_listening(bind).await;
    });
    let dashboard_tx_established = dashboard_tx.clone();
    let stream_tx_established = stream_tx.clone();
    let connection_names_established = Arc::clone(&connection_names);
    if let Some(manager) = Arc::get_mut(&mut p2p_manager) {
        manager.on_connection_established(move |connection_id, peer_id| {
            let connection_id_for_name = connection_id.clone();
            let peer_id_for_ui = peer_id.clone();
            let peer_name = connection_names_established
                .read()
                .ok()
                .and_then(|map| map.get(&connection_id_for_name).cloned());
            let message = if let Some(name) = peer_name.as_ref() {
                format!("Connected to {}", name)
            } else if let Some(peer_id) = peer_id_for_ui.as_ref() {
                format!("Connected to {}", peer_id)
            } else {
                format!("Connected ({})", connection_id)
            };
            let _ = dashboard_tx_established.unbounded_send(DashboardUiEvent::ConnectionStatus(
                ConnectionUpdate {
                    message,
                    phase: ConnectionPhase::Connected,
                    connection_id: Some(connection_id.clone()),
                    peer_id: peer_id_for_ui,
                    peer_name,
                    streaming: Some(StreamingStatus {
                        active: false,
                        message: Some("Starting stream".to_string()),
                    }),
                },
            ));
            let _ = stream_tx_established.send(StreamRequest { connection_id });
        });
    }
    let dashboard_ui = dashboard_page.clone();
    let devices_ui = devices_page.clone();
    glib::MainContext::default().spawn_local(async move {
        while let Some(event) = dashboard_rx.next().await {
            match event {
                DashboardUiEvent::ConnectionStatus(update) => {
                    dashboard_ui.update_connection_status(update);
                }
                DashboardUiEvent::DevicesUpdated { devices } => {
                    dashboard_ui.update_devices(&devices);
                    devices_ui.update_devices(&devices);
                }
                DashboardUiEvent::CrossNetworkCode { code } => {
                    dashboard_ui.set_cross_network_code(&code);
                }
                DashboardUiEvent::CrossNetworkPeerHint {
                    code,
                    peer_id,
                    peer_fingerprint,
                } => {
                    dashboard_ui.set_cross_network_peer_hint(
                        &code,
                        peer_id.as_deref(),
                        peer_fingerprint.as_deref(),
                    );
                }
                DashboardUiEvent::CrossNetworkRoomStatus { code, status } => {
                    dashboard_ui.set_cross_network_room_status(&code, &status);
                }
            }
        }
    });

    let runtime_connect = runtime.clone();
    let p2p_connect = Arc::clone(&p2p_manager);
    let tcp_connect = Arc::clone(&tcp_control);
    let dashboard_tx_connect = dashboard_tx.clone();
    let connection_names_connect = Arc::clone(&connection_names);
    devices_page.set_on_device_activated(move |device| {
        let runtime = runtime_connect.clone();
        let manager = Arc::clone(&p2p_connect);
        let tcp = Arc::clone(&tcp_connect);
        let dashboard_tx = dashboard_tx_connect.clone();
        let connection_names = Arc::clone(&connection_names_connect);
        runtime.spawn(async move {
            let peer_name = device.name.clone();
            let peer_id = device.device_id.clone();
            let Some(addr) = device.addresses.first().copied() else {
                let _ = dashboard_tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                    ConnectionUpdate {
                        message: "No address for device".to_string(),
                        phase: ConnectionPhase::Failed,
                        connection_id: None,
                        peer_id: Some(peer_id.clone()),
                        peer_name: Some(peer_name.clone()),
                        streaming: None,
                    },
                ));
                return;
            };

            let _ =
                dashboard_tx.unbounded_send(DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                    message: format!("Connecting to {}", peer_name),
                    phase: ConnectionPhase::Connecting,
                    connection_id: None,
                    peer_id: Some(peer_id.clone()),
                    peer_name: Some(peer_name.clone()),
                    streaming: None,
                }));

            let current_settings = AppSettings::load();
            if let Err(err) = validate_outbound_device_trust(&device, &current_settings) {
                let _ = dashboard_tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                    ConnectionUpdate {
                        message: err,
                        phase: ConnectionPhase::Failed,
                        connection_id: None,
                        peer_id: Some(peer_id.clone()),
                        peer_name: Some(peer_name.clone()),
                        streaming: None,
                    },
                ));
                return;
            }
            let expected_fingerprint = preferred_outbound_peer_fingerprint(&device);

            // Prefer macOS/iOS-compatible TCP control channel.
            match tcp
                .connect_with_peer_hint(
                    addr,
                    Some(&device.device_id),
                    expected_fingerprint.as_deref(),
                )
                .await
            {
                Ok(handle) => {
                    if let Ok(mut map) = connection_names.write() {
                        map.insert(handle.connection_id.clone(), peer_name.clone());
                    }
                    let _ = dashboard_tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                        ConnectionUpdate {
                            message: "TCP connected (handshaking...)".to_string(),
                            phase: ConnectionPhase::Handshaking,
                            connection_id: Some(handle.connection_id),
                            peer_id: Some(peer_id.clone()),
                            peer_name: Some(peer_name.clone()),
                            streaming: None,
                        },
                    ));
                }
                Err(_) => {
                    // Fallback to QUIC (Ubuntu-Ubuntu).
                    match manager.connect(addr).await {
                        Ok(connection_id) => {
                            if let Ok(mut map) = connection_names.write() {
                                map.insert(connection_id.clone(), peer_name.clone());
                            }
                            let policy = handshake_policy_from_settings(&current_settings);
                            if let Err(err) = manager
                                .handshake_with_peer_hint(
                                    &connection_id,
                                    Some(&device.device_id),
                                    expected_fingerprint.as_deref(),
                                    policy,
                                )
                                .await
                            {
                                if let Ok(mut map) = connection_names.write() {
                                    map.remove(&connection_id);
                                }
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: format!("Handshake failed: {}", err),
                                        phase: ConnectionPhase::Failed,
                                        connection_id: Some(connection_id),
                                        peer_id: Some(peer_id.clone()),
                                        peer_name: Some(peer_name.clone()),
                                        streaming: None,
                                    }),
                                );
                            } else {
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: "Handshake started (QUIC)".to_string(),
                                        phase: ConnectionPhase::Handshaking,
                                        connection_id: Some(connection_id),
                                        peer_id: Some(peer_id.clone()),
                                        peer_name: Some(peer_name.clone()),
                                        streaming: None,
                                    }),
                                );
                            }
                        }
                        Err(err) => {
                            let _ = dashboard_tx.unbounded_send(
                                DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                    message: format!("Connect failed: {}", err),
                                    phase: ConnectionPhase::Failed,
                                    connection_id: None,
                                    peer_id: Some(peer_id.clone()),
                                    peer_name: Some(peer_name.clone()),
                                    streaming: None,
                                }),
                            );
                        }
                    }
                }
            };
        });
    });

    let runtime_connect = runtime.clone();
    let p2p_connect = Arc::clone(&p2p_manager);
    let tcp_connect = Arc::clone(&tcp_control);
    let dashboard_tx_connect = dashboard_tx.clone();
    let connection_names_connect = Arc::clone(&connection_names);
    dashboard_page.set_on_device_connect(move |device| {
        let runtime = runtime_connect.clone();
        let manager = Arc::clone(&p2p_connect);
        let tcp = Arc::clone(&tcp_connect);
        let dashboard_tx = dashboard_tx_connect.clone();
        let connection_names = Arc::clone(&connection_names_connect);
        runtime.spawn(async move {
            let peer_name = device.name.clone();
            let peer_id = device.device_id.clone();
            let Some(addr) = device.addresses.first().copied() else {
                let _ = dashboard_tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                    ConnectionUpdate {
                        message: "No address for device".to_string(),
                        phase: ConnectionPhase::Failed,
                        connection_id: None,
                        peer_id: Some(peer_id.clone()),
                        peer_name: Some(peer_name.clone()),
                        streaming: None,
                    },
                ));
                return;
            };

            let _ =
                dashboard_tx.unbounded_send(DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                    message: format!("Connecting to {}", peer_name),
                    phase: ConnectionPhase::Connecting,
                    connection_id: None,
                    peer_id: Some(peer_id.clone()),
                    peer_name: Some(peer_name.clone()),
                    streaming: None,
                }));

            let current_settings = AppSettings::load();
            if let Err(err) = validate_outbound_device_trust(&device, &current_settings) {
                let _ = dashboard_tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                    ConnectionUpdate {
                        message: err,
                        phase: ConnectionPhase::Failed,
                        connection_id: None,
                        peer_id: Some(peer_id.clone()),
                        peer_name: Some(peer_name.clone()),
                        streaming: None,
                    },
                ));
                return;
            }
            let expected_fingerprint = preferred_outbound_peer_fingerprint(&device);

            // Prefer macOS/iOS-compatible TCP control channel.
            match tcp
                .connect_with_peer_hint(
                    addr,
                    Some(&device.device_id),
                    expected_fingerprint.as_deref(),
                )
                .await
            {
                Ok(handle) => {
                    if let Ok(mut map) = connection_names.write() {
                        map.insert(handle.connection_id.clone(), peer_name.clone());
                    }
                    let _ = dashboard_tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                        ConnectionUpdate {
                            message: "TCP connected (handshaking...)".to_string(),
                            phase: ConnectionPhase::Handshaking,
                            connection_id: Some(handle.connection_id),
                            peer_id: Some(peer_id.clone()),
                            peer_name: Some(peer_name.clone()),
                            streaming: None,
                        },
                    ));
                }
                Err(_) => {
                    // Fallback to QUIC (Ubuntu-Ubuntu).
                    match manager.connect(addr).await {
                        Ok(connection_id) => {
                            if let Ok(mut map) = connection_names.write() {
                                map.insert(connection_id.clone(), peer_name.clone());
                            }
                            let policy = handshake_policy_from_settings(&current_settings);
                            if let Err(err) = manager
                                .handshake_with_peer_hint(
                                    &connection_id,
                                    Some(&device.device_id),
                                    expected_fingerprint.as_deref(),
                                    policy,
                                )
                                .await
                            {
                                if let Ok(mut map) = connection_names.write() {
                                    map.remove(&connection_id);
                                }
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: format!("Handshake failed: {}", err),
                                        phase: ConnectionPhase::Failed,
                                        connection_id: Some(connection_id),
                                        peer_id: Some(peer_id.clone()),
                                        peer_name: Some(peer_name.clone()),
                                        streaming: None,
                                    }),
                                );
                            } else {
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: "Handshake started (QUIC)".to_string(),
                                        phase: ConnectionPhase::Handshaking,
                                        connection_id: Some(connection_id),
                                        peer_id: Some(peer_id.clone()),
                                        peer_name: Some(peer_name.clone()),
                                        streaming: None,
                                    }),
                                );
                            }
                        }
                        Err(err) => {
                            let _ = dashboard_tx.unbounded_send(
                                DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                    message: format!("Connect failed: {}", err),
                                    phase: ConnectionPhase::Failed,
                                    connection_id: None,
                                    peer_id: Some(peer_id.clone()),
                                    peer_name: Some(peer_name.clone()),
                                    streaming: None,
                                }),
                            );
                        }
                    }
                }
            };
        });
    });

    // Cross-network (WebRTC) host/join wiring (feature-gated)
    {
        let dashboard_tx_webrtc = dashboard_tx.clone();
        #[cfg(feature = "webrtc")]
        let identity_webrtc = identity.clone();
        #[cfg(feature = "webrtc")]
        let remote_frame_tx_webrtc_host = remote_frame_tx.clone();
        #[cfg(feature = "webrtc")]
        let ui_tx_webrtc = ui_tx.clone();

        dashboard_page.set_on_webrtc_host(move || {
            let dashboard_tx = dashboard_tx_webrtc.clone();

            #[cfg(feature = "webrtc")]
            {
                let identity = identity_webrtc.clone();
                let remote_frame_tx = remote_frame_tx_webrtc_host.clone();
                let ui_tx = ui_tx_webrtc.clone();
                std::thread::spawn(move || {
                    let runtime = tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                        .expect("webrtc host runtime");
                    runtime.block_on(async move {
                        let settings = AppSettings::load();
                        if !settings.network.enable_webrtc {
                            let _ = dashboard_tx.unbounded_send(
                                DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                    message: "WebRTC is disabled in Settings".to_string(),
                                    phase: ConnectionPhase::Failed,
                                    connection_id: None,
                                    peer_id: None,
                                    peer_name: None,
                                    streaming: None,
                                }),
                            );
                            return;
                        }

                        let control = match signaling_control_client(&settings) {
                            Ok(client) => client,
                            Err(err) => {
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: err,
                                        phase: ConnectionPhase::Failed,
                                        connection_id: None,
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    }),
                                );
                                return;
                            }
                        };

                        let binding = match local_protocol_identity_binding(&identity) {
                            Ok(binding) => binding,
                            Err(err) => {
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: err,
                                        phase: ConnectionPhase::Failed,
                                        connection_id: None,
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    }),
                                );
                                return;
                            }
                        };

                        let lease = match control
                            .register_connection_code(
                                &binding,
                                &identity,
                                &settings.device.name,
                                600,
                            )
                            .await
                        {
                            Ok(lease) => lease,
                            Err(err) => {
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: format!("Register code failed: {}", err),
                                        phase: ConnectionPhase::Failed,
                                        connection_id: None,
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    }),
                                );
                                return;
                            }
                        };

                        let _ = dashboard_tx.unbounded_send(DashboardUiEvent::CrossNetworkCode {
                            code: lease.code.clone(),
                        });

                        let url = match signaling_url_with_shard(
                            &settings.network.webrtc_signaling_url,
                            &lease.session_id,
                            Some(&lease.initiator_token),
                        ) {
                            Ok(u) => u,
                            Err(err) => {
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: format!("Invalid signaling URL: {}", err),
                                        phase: ConnectionPhase::Failed,
                                        connection_id: None,
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    }),
                                );
                                return;
                            }
                        };

                        let signaling_cfg = WebRtcSignalingClientConfig { url };
                        let ice = match dynamic_ice_config(
                            &settings,
                            &identity.device_id,
                            Some(&lease.turn_admission_token),
                        )
                        .await
                        {
                            Ok(ice) => ice,
                            Err(err) => {
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: format!("TURN setup failed: {}", err),
                                        phase: ConnectionPhase::Failed,
                                        connection_id: None,
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    }),
                                );
                                return;
                            }
                        };

                        let (biz_tx, mut biz_rx) =
                            tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
                        let mut mgr = WebRtcCrossNetworkManager::new();
                        let tx = dashboard_tx.clone();
                        let sid = lease.session_id.clone();
                        mgr.on_event(move |evt| match evt {
                            skybridge_core::webrtc::CrossNetworkEvent::TransportReady {
                                session_id,
                            } => {
                                let _ =
                                    tx.unbounded_send(DashboardUiEvent::CrossNetworkRoomStatus {
                                        code: session_id.clone(),
                                        status: "transport ready".to_string(),
                                    });
                                let _ = tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                                    ConnectionUpdate {
                                        message: format!("WebRTC transport ready ({})", session_id),
                                        phase: ConnectionPhase::Connecting,
                                        connection_id: Some(session_id),
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    },
                                ));
                            }
                            skybridge_core::webrtc::CrossNetworkEvent::PeerHintResolved {
                                session_id,
                                peer_device_id,
                                expected_peer_fingerprint,
                            } => {
                                let _ = tx.unbounded_send(DashboardUiEvent::CrossNetworkPeerHint {
                                    code: session_id.clone(),
                                    peer_id: Some(peer_device_id.clone()),
                                    peer_fingerprint: expected_peer_fingerprint.clone(),
                                });
                                let _ =
                                    tx.unbounded_send(DashboardUiEvent::CrossNetworkRoomStatus {
                                        code: session_id.clone(),
                                        status: format!("peer mapped: {}", peer_device_id),
                                    });
                                let _ = tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                                    ConnectionUpdate {
                                        message: format!("WebRTC peer resolved ({})", session_id),
                                        phase: ConnectionPhase::Connecting,
                                        connection_id: Some(session_id),
                                        peer_id: Some(peer_device_id),
                                        peer_name: None,
                                        streaming: None,
                                    },
                                ));
                            }
                            skybridge_core::webrtc::CrossNetworkEvent::HandshakeEstablished {
                                session_id,
                                peer_device_id,
                            } => {
                                let _ =
                                    tx.unbounded_send(DashboardUiEvent::CrossNetworkRoomStatus {
                                        code: session_id.clone(),
                                        status: "handshake established".to_string(),
                                    });
                                let _ = tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                                    ConnectionUpdate {
                                        message: format!(
                                            "WebRTC handshake established ({})",
                                            session_id
                                        ),
                                        phase: ConnectionPhase::Connected,
                                        connection_id: Some(session_id),
                                        peer_id: peer_device_id,
                                        peer_name: None,
                                        streaming: None,
                                    },
                                ));
                            }
                            skybridge_core::webrtc::CrossNetworkEvent::Status {
                                session_id,
                                message,
                            } => {
                                let _ =
                                    tx.unbounded_send(DashboardUiEvent::CrossNetworkRoomStatus {
                                        code: session_id.clone(),
                                        status: message.clone(),
                                    });
                                let _ = tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                                    ConnectionUpdate {
                                        message: format!("WebRTC {}: {}", session_id, message),
                                        phase: ConnectionPhase::Connecting,
                                        connection_id: Some(session_id),
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    },
                                ));
                            }
                            skybridge_core::webrtc::CrossNetworkEvent::Failed {
                                session_id,
                                error,
                            } => {
                                let _ = tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                                    ConnectionUpdate {
                                        message: format!("WebRTC {} failed: {}", session_id, error),
                                        phase: ConnectionPhase::Failed,
                                        connection_id: Some(session_id),
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    },
                                ));
                            }
                            skybridge_core::webrtc::CrossNetworkEvent::AppPayload {
                                session_id: _,
                                data,
                            } => {
                                let _ = biz_tx.send(data);
                            }
                        });

                        let policy = handshake_policy_from_settings(&settings);
                        let trust_policy = connection_trust_policy_from_settings(&settings);
                        let handle = match mgr
                            .start_offerer(WebRtcStartParams {
                                session_id: sid.clone(),
                                local_device_id: identity.device_id.clone(),
                                signaling_cfg,
                                signaling_auth_token: Some(lease.initiator_token.clone()),
                                signaling_server_origin: Some(
                                    lease.signaling_server_origin.clone(),
                                ),
                                ice,
                                identity: identity.clone(),
                                policy,
                                trust_policy,
                                peer_device_id_hint: None,
                                expected_peer_fingerprint: None,
                                current_path_remote_authority: None,
                            })
                            .await
                        {
                            Ok(h) => h,
                            Err(err) => {
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: format!("WebRTC start failed: {}", err),
                                        phase: ConnectionPhase::Failed,
                                        connection_id: Some(sid.clone()),
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    }),
                                );
                                return;
                            }
                        };

                        let handle = Arc::new(handle);

                        // Best-effort: send our PQC KEM identity bundle for bootstrap (macOS/iOS compatible).
                        if identity.supported_suites.iter().any(|s| s.is_pqc()) {
                            send_webrtc_json(
                                handle.as_ref(),
                                &build_pairing_identity_exchange(&identity),
                            )
                            .await;
                        }

                        // Business router loop (file transfer + remote input)
                        let state = WebRtcSessionState {
                            dashboard_tx: dashboard_tx.clone(),
                            ui_tx,
                            inbound_transfers: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
                            pending_transfers: Arc::new(tokio::sync::Mutex::new(
                                std::collections::HashSet::new(),
                            )),
                            remote_approval: Arc::new(tokio::sync::Mutex::new(
                                RemoteControlApproval::Unknown,
                            )),
                        };
                        let remote_video_formats = supported_remote_video_formats();
                        let mut remote_video_state = RemoteJsonVideoState::new();
                        let mut input: Option<UnifiedInputHandler> = None;
                        let mut heartbeat =
                            tokio::time::interval(std::time::Duration::from_secs(2));
                        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                        loop {
                            tokio::select! {
                                _ = heartbeat.tick() => {
                                    // macOS/iOS WebRTC screen streaming is gated by receiving `AppMessage.heartbeat`.
                                    let hb = AppMessage::Heartbeat(HeartbeatPayload {
                                        sent_at: SwiftDateSeconds::now(),
                                        device_id: Some(identity.device_id.clone()),
                                        device_name: None,
                                        model_name: None,
                                        platform: None,
                                        os_version: None,
                                        chip: None,
                                        remote_video_formats: Some(remote_video_formats.clone()),
                                    });
                                    send_webrtc_json(handle.as_ref(), &hb).await;
                                }
                                maybe_payload = biz_rx.recv() => {
                                    let Some(payload) = maybe_payload else { break };
                                    let current = AppSettings::load();
                                    handle_webrtc_app_payload(
                                        &sid,
                                        &handle,
                                        &current,
                                        &identity,
                                        &payload,
                                        &remote_frame_tx,
                                        &state,
                                        &mut remote_video_state,
                                        &mut input,
                                    )
                                    .await;
                                    if handle.is_closed() {
                                        break;
                                    }
                                }
                            }
                        }
                    });
                });
            }

            #[cfg(not(feature = "webrtc"))]
            {
                let _ = dashboard_tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                    ConnectionUpdate {
                        message: "WebRTC feature not enabled (build with --features webrtc)"
                            .to_string(),
                        phase: ConnectionPhase::Failed,
                        connection_id: None,
                        peer_id: None,
                        peer_name: None,
                        streaming: None,
                    },
                ));
            }
        });
    }

    {
        let dashboard_tx_webrtc = dashboard_tx.clone();
        #[cfg(feature = "webrtc")]
        let identity_webrtc = identity.clone();
        #[cfg(feature = "webrtc")]
        let remote_frame_tx_webrtc = remote_frame_tx.clone();
        #[cfg(feature = "webrtc")]
        let ui_tx_webrtc = ui_tx.clone();
        dashboard_page.set_on_webrtc_join(move |raw_code| {
            let dashboard_tx = dashboard_tx_webrtc.clone();

            let Some(code) = normalize_connection_code(&raw_code) else {
                let _ = dashboard_tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                    ConnectionUpdate {
                        message: "Invalid code (need 6-10 letters/numbers)".to_string(),
                        phase: ConnectionPhase::Failed,
                        connection_id: None,
                        peer_id: None,
                        peer_name: None,
                        streaming: None,
                    },
                ));
                return;
            };
            let _ = dashboard_tx
                .unbounded_send(DashboardUiEvent::CrossNetworkCode { code: code.clone() });

            #[cfg(feature = "webrtc")]
            {
                let identity = identity_webrtc.clone();
                let remote_frame_tx = remote_frame_tx_webrtc.clone();
                let ui_tx = ui_tx_webrtc.clone();
                std::thread::spawn(move || {
                    let runtime = tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                        .expect("webrtc join runtime");
                    runtime.block_on(async move {
                        let settings = AppSettings::load();
                        if !settings.network.enable_webrtc {
                            let _ = dashboard_tx.unbounded_send(
                                DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                    message: "WebRTC is disabled in Settings".to_string(),
                                    phase: ConnectionPhase::Failed,
                                    connection_id: None,
                                    peer_id: None,
                                    peer_name: None,
                                    streaming: None,
                                }),
                            );
                            return;
                        }

                        let control = match signaling_control_client(&settings) {
                            Ok(client) => client,
                            Err(err) => {
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: err,
                                        phase: ConnectionPhase::Failed,
                                        connection_id: None,
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    }),
                                );
                                return;
                            }
                        };

                        let binding = match local_protocol_identity_binding(&identity) {
                            Ok(binding) => binding,
                            Err(err) => {
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: err,
                                        phase: ConnectionPhase::Failed,
                                        connection_id: None,
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    }),
                                );
                                return;
                            }
                        };

                        let lookup = match control
                            .lookup_connection_code(&code, &binding, &identity)
                            .await
                        {
                            Ok(lookup) => lookup,
                            Err(err) => {
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: format!("Lookup failed: {}", err),
                                        phase: ConnectionPhase::Failed,
                                        connection_id: None,
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    }),
                                );
                                return;
                            }
                        };
                        let current_path_remote_authority = lookup.remote_authority();

                        let url = match signaling_url_with_shard(
                            &settings.network.webrtc_signaling_url,
                            &lookup.session_id,
                            Some(&lookup.responder_token),
                        ) {
                            Ok(u) => u,
                            Err(err) => {
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: format!("Invalid signaling URL: {}", err),
                                        phase: ConnectionPhase::Failed,
                                        connection_id: None,
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    }),
                                );
                                return;
                            }
                        };

                        let signaling_cfg = WebRtcSignalingClientConfig { url };
                        let ice = match dynamic_ice_config(
                            &settings,
                            &identity.device_id,
                            Some(&lookup.turn_admission_token),
                        )
                        .await
                        {
                            Ok(ice) => ice,
                            Err(err) => {
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: format!("TURN setup failed: {}", err),
                                        phase: ConnectionPhase::Failed,
                                        connection_id: None,
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    }),
                                );
                                return;
                            }
                        };

                        let (biz_tx, mut biz_rx) =
                            tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
                        let mut mgr = WebRtcCrossNetworkManager::new();
                        let tx = dashboard_tx.clone();
                        mgr.on_event(move |evt| match evt {
                            skybridge_core::webrtc::CrossNetworkEvent::TransportReady {
                                session_id,
                            } => {
                                let _ =
                                    tx.unbounded_send(DashboardUiEvent::CrossNetworkRoomStatus {
                                        code: session_id.clone(),
                                        status: "transport ready".to_string(),
                                    });
                                let _ = tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                                    ConnectionUpdate {
                                        message: format!("WebRTC transport ready ({})", session_id),
                                        phase: ConnectionPhase::Connecting,
                                        connection_id: Some(session_id),
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    },
                                ));
                            }
                            skybridge_core::webrtc::CrossNetworkEvent::PeerHintResolved {
                                session_id,
                                peer_device_id,
                                expected_peer_fingerprint,
                            } => {
                                let _ = tx.unbounded_send(DashboardUiEvent::CrossNetworkPeerHint {
                                    code: session_id.clone(),
                                    peer_id: Some(peer_device_id.clone()),
                                    peer_fingerprint: expected_peer_fingerprint.clone(),
                                });
                                let _ =
                                    tx.unbounded_send(DashboardUiEvent::CrossNetworkRoomStatus {
                                        code: session_id.clone(),
                                        status: format!("peer mapped: {}", peer_device_id),
                                    });
                                let _ = tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                                    ConnectionUpdate {
                                        message: format!("WebRTC peer resolved ({})", session_id),
                                        phase: ConnectionPhase::Connecting,
                                        connection_id: Some(session_id),
                                        peer_id: Some(peer_device_id),
                                        peer_name: None,
                                        streaming: None,
                                    },
                                ));
                            }
                            skybridge_core::webrtc::CrossNetworkEvent::HandshakeEstablished {
                                session_id,
                                peer_device_id,
                            } => {
                                let _ =
                                    tx.unbounded_send(DashboardUiEvent::CrossNetworkRoomStatus {
                                        code: session_id.clone(),
                                        status: "handshake established".to_string(),
                                    });
                                let _ = tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                                    ConnectionUpdate {
                                        message: format!(
                                            "WebRTC handshake established ({})",
                                            session_id
                                        ),
                                        phase: ConnectionPhase::Connected,
                                        connection_id: Some(session_id),
                                        peer_id: peer_device_id,
                                        peer_name: None,
                                        streaming: None,
                                    },
                                ));
                            }
                            skybridge_core::webrtc::CrossNetworkEvent::Status {
                                session_id,
                                message,
                            } => {
                                let _ =
                                    tx.unbounded_send(DashboardUiEvent::CrossNetworkRoomStatus {
                                        code: session_id.clone(),
                                        status: message.clone(),
                                    });
                                let _ = tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                                    ConnectionUpdate {
                                        message: format!("WebRTC {}: {}", session_id, message),
                                        phase: ConnectionPhase::Connecting,
                                        connection_id: Some(session_id),
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    },
                                ));
                            }
                            skybridge_core::webrtc::CrossNetworkEvent::Failed {
                                session_id,
                                error,
                            } => {
                                let _ = tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                                    ConnectionUpdate {
                                        message: format!("WebRTC {} failed: {}", session_id, error),
                                        phase: ConnectionPhase::Failed,
                                        connection_id: Some(session_id),
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    },
                                ));
                            }
                            skybridge_core::webrtc::CrossNetworkEvent::AppPayload {
                                session_id: _,
                                data,
                            } => {
                                let _ = biz_tx.send(data);
                            }
                        });

                        let policy = handshake_policy_from_settings(&settings);
                        let trust_policy = connection_trust_policy_from_settings(&settings);
                        let handle = match mgr
                            .start_answerer(WebRtcStartParams {
                                session_id: lookup.session_id.clone(),
                                local_device_id: identity.device_id.clone(),
                                signaling_cfg,
                                signaling_auth_token: Some(lookup.responder_token.clone()),
                                signaling_server_origin: Some(
                                    lookup.signaling_server_origin.clone(),
                                ),
                                ice,
                                identity: identity.clone(),
                                policy,
                                trust_policy,
                                peer_device_id_hint: Some(lookup.initiator_device_id.clone()),
                                expected_peer_fingerprint: Some(
                                    lookup.initiator_protocol_public_key_fingerprint.clone(),
                                ),
                                current_path_remote_authority,
                            })
                            .await
                        {
                            Ok(h) => h,
                            Err(err) => {
                                let _ = dashboard_tx.unbounded_send(
                                    DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
                                        message: format!("WebRTC start failed: {}", err),
                                        phase: ConnectionPhase::Failed,
                                        connection_id: Some(code.clone()),
                                        peer_id: None,
                                        peer_name: None,
                                        streaming: None,
                                    }),
                                );
                                return;
                            }
                        };

                        let handle = Arc::new(handle);

                        // Best-effort: send our PQC KEM identity bundle for bootstrap (macOS/iOS compatible).
                        if identity.supported_suites.iter().any(|s| s.is_pqc()) {
                            send_webrtc_json(
                                handle.as_ref(),
                                &build_pairing_identity_exchange(&identity),
                            )
                            .await;
                        }

                        let state = WebRtcSessionState {
                            dashboard_tx: dashboard_tx.clone(),
                            ui_tx,
                            inbound_transfers: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
                            pending_transfers: Arc::new(tokio::sync::Mutex::new(
                                std::collections::HashSet::new(),
                            )),
                            remote_approval: Arc::new(tokio::sync::Mutex::new(
                                RemoteControlApproval::Unknown,
                            )),
                        };
                        let remote_video_formats = supported_remote_video_formats();
                        let mut remote_video_state = RemoteJsonVideoState::new();
                        let mut input: Option<UnifiedInputHandler> = None;
                        let mut heartbeat =
                            tokio::time::interval(std::time::Duration::from_secs(2));
                        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                        loop {
                            tokio::select! {
                                _ = heartbeat.tick() => {
                                    // macOS/iOS WebRTC screen streaming is gated by receiving `AppMessage.heartbeat`.
                                    let hb = AppMessage::Heartbeat(HeartbeatPayload {
                                        sent_at: SwiftDateSeconds::now(),
                                        device_id: Some(identity.device_id.clone()),
                                        device_name: None,
                                        model_name: None,
                                        platform: None,
                                        os_version: None,
                                        chip: None,
                                        remote_video_formats: Some(remote_video_formats.clone()),
                                    });
                                    send_webrtc_json(handle.as_ref(), &hb).await;
                                }
                                maybe_payload = biz_rx.recv() => {
                                    let Some(payload) = maybe_payload else { break };
                                    let current = AppSettings::load();
                                    handle_webrtc_app_payload(
                                        &code,
                                        &handle,
                                        &current,
                                        &identity,
                                        &payload,
                                        &remote_frame_tx,
                                        &state,
                                        &mut remote_video_state,
                                        &mut input,
                                    )
                                    .await;
                                    if handle.is_closed() {
                                        break;
                                    }
                                }
                            }
                        }
                    });
                });
            }

            #[cfg(not(feature = "webrtc"))]
            {
                let _ = dashboard_tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                    ConnectionUpdate {
                        message: "WebRTC feature not enabled (build with --features webrtc)"
                            .to_string(),
                        phase: ConnectionPhase::Failed,
                        connection_id: None,
                        peer_id: None,
                        peer_name: None,
                        streaming: None,
                    },
                ));
            }
        });
    }

    // Set dashboard as default
    view_stack.set_visible_child_name("dashboard");

    main_paned.set_end_child(Some(&view_stack));
    main_paned.set_position(246);

    let root_stack = gtk::Stack::builder().build();
    root_stack.add_named(&login_page.widget, Some("login"));
    root_stack.add_named(&main_paned, Some("main"));
    root_stack.set_visible_child_name("login");

    // Set window content
    window.set_content(Some(&root_stack));

    let pending_incoming: Rc<RefCell<HashMap<String, PendingIncomingTransfer>>> =
        Rc::new(RefCell::new(HashMap::new()));
    let pending_remote: Rc<RefCell<HashMap<String, PendingRemoteControl>>> =
        Rc::new(RefCell::new(HashMap::new()));

    {
        let settings_page = settings_page.clone();
        let app = app.clone();
        let pending_incoming = pending_incoming.clone();
        let pending_remote = pending_remote.clone();
        glib::MainContext::default().spawn_local(async move {
            while let Some(event) = ui_rx.next().await {
                match event {
                    UiEvent::AccountSyncFinished { ok, message } => {
                        settings_page.set_sync_busy(false);
                        settings_page.set_sync_status(&message);
                        if ok {
                            settings_page.refresh_account_state();
                        }
                    }
                    UiEvent::IncomingTransferPrompt {
                        request,
                        decision_tx,
                    } => {
                        let transfer_id = request.transfer_id.clone();
                        let notification_id = format!("incoming-transfer-{}", transfer_id);
                        if let Some(existing) = pending_incoming.borrow_mut().remove(&transfer_id) {
                            app.withdraw_notification(&existing.notification_id);
                            let _ = existing
                                .decision_tx
                                .send(IncomingTransferDecision::decline());
                        }

                        let sender = request
                            .sender_device_name
                            .clone()
                            .or(request.sender_device_id.clone())
                            .unwrap_or_else(|| "Unknown device".to_string());
                        let body = format!(
                            "{} wants to send “{}” ({})",
                            sender,
                            request.file_name,
                            format_bytes(request.file_size)
                        );

                        pending_incoming.borrow_mut().insert(
                            transfer_id.clone(),
                            PendingIncomingTransfer {
                                request,
                                decision_tx,
                                notification_id: notification_id.clone(),
                            },
                        );

                        let target = transfer_id.to_variant();
                        let notif = gio::Notification::new("Incoming file transfer");
                        notif.set_body(Some(&body));
                        notif.add_button_with_target_value(
                            "Review",
                            "app.incoming-review",
                            Some(&target),
                        );
                        notif.add_button_with_target_value(
                            "Decline",
                            "app.incoming-decline",
                            Some(&target),
                        );
                        notif.set_default_action_and_target_value(
                            "app.incoming-review",
                            Some(&target),
                        );
                        app.send_notification(Some(&notification_id), &notif);

                        let app = app.clone();
                        let pending_incoming = pending_incoming.clone();
                        glib::MainContext::default().spawn_local(async move {
                            glib::timeout_future(std::time::Duration::from_secs(
                                INCOMING_TRANSFER_DECISION_TIMEOUT_SECS,
                            ))
                            .await;
                            if let Some(entry) = pending_incoming.borrow_mut().remove(&transfer_id)
                            {
                                app.withdraw_notification(&entry.notification_id);
                                let _ = entry.decision_tx.send(IncomingTransferDecision::decline());
                            }
                        });
                    }
                    UiEvent::IncomingTransferCompleted(done) => {
                        let settings = AppSettings::load();
                        if !settings.transfer.notify_on_complete {
                            continue;
                        }
                        if !done.success && done.error.as_deref() == Some("declined") {
                            continue;
                        }

                        let sender = done
                            .sender_device_name
                            .clone()
                            .or(done.sender_device_id.clone())
                            .unwrap_or_else(|| "Unknown device".to_string());
                        let title = if done.success {
                            "Transfer complete"
                        } else {
                            "Transfer failed"
                        };
                        let mut body = format!("{} • {}", sender, done.file_name);
                        if let Some(path) = done.save_path.as_ref() {
                            body = format!("{}\nSaved to: {}", body, path.display());
                        }
                        if let Some(err) = done.error.as_deref() {
                            body = format!("{}\n{}", body, err);
                        }

                        let notif = gio::Notification::new(title);
                        notif.set_body(Some(&body));
                        let id = format!("incoming-transfer-complete-{}", done.transfer_id);
                        app.send_notification(Some(&id), &notif);
                    }
                    UiEvent::RemoteControlPrompt {
                        session_id,
                        sender_device_id,
                        sender_device_name,
                        decision_tx,
                    } => {
                        let notification_id = format!("remote-control-{}", session_id);
                        if let Some(existing) = pending_remote.borrow_mut().remove(&session_id) {
                            app.withdraw_notification(&existing.notification_id);
                            let _ = existing.decision_tx.send(false);
                        }

                        let sender = sender_device_name
                            .clone()
                            .or(sender_device_id.clone())
                            .unwrap_or_else(|| "Unknown device".to_string());
                        let body = format!("Remote control request from {}", sender);

                        pending_remote.borrow_mut().insert(
                            session_id.clone(),
                            PendingRemoteControl {
                                sender_device_id,
                                sender_device_name,
                                decision_tx,
                                notification_id: notification_id.clone(),
                            },
                        );

                        let target = session_id.to_variant();
                        let notif = gio::Notification::new("Remote control request");
                        notif.set_body(Some(&body));
                        notif.add_button_with_target_value(
                            "Review",
                            "app.remote-review",
                            Some(&target),
                        );
                        notif.add_button_with_target_value(
                            "Decline",
                            "app.remote-decline",
                            Some(&target),
                        );
                        notif.set_default_action_and_target_value(
                            "app.remote-review",
                            Some(&target),
                        );
                        app.send_notification(Some(&notification_id), &notif);

                        let app = app.clone();
                        let pending_remote = pending_remote.clone();
                        glib::MainContext::default().spawn_local(async move {
                            glib::timeout_future(std::time::Duration::from_secs(
                                INCOMING_TRANSFER_DECISION_TIMEOUT_SECS,
                            ))
                            .await;
                            if let Some(entry) = pending_remote.borrow_mut().remove(&session_id) {
                                app.withdraw_notification(&entry.notification_id);
                                let _ = entry.decision_tx.send(false);
                            }
                        });
                    }
                }
            }
        });
    }

    // App actions used by Settings and notifications.
    {
        let root_stack = root_stack.clone();
        let window = window.clone();
        let show_login = gio::SimpleAction::new("show-login", None);
        show_login.connect_activate(move |_, _| {
            root_stack.set_visible_child_name("login");
            window.present();
        });
        app.add_action(&show_login);
    }
    {
        let settings_page = settings_page.clone();
        let runtime = runtime.clone();
        let auth = auth.clone();
        let ui_tx = ui_tx.clone();
        let sync = gio::SimpleAction::new("sync-account", None);
        sync.connect_activate(move |_, _| {
            if !settings_page.is_signed_in() {
                settings_page.set_sync_status("Not signed in");
                return;
            }
            settings_page.set_sync_busy(true);
            let auth = auth.clone();
            let ui_tx = ui_tx.clone();
            runtime.spawn(async move {
                let mut auth = auth.lock().await;
                let result = auth.refresh_token().await;
                let (ok, message) = match result {
                    Ok(_) => {
                        let when = chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string();
                        (true, format!("Last synced: {}", when))
                    }
                    Err(err) => (false, format!("Sync failed: {}", auth_error_message(err))),
                };
                let _ = ui_tx.unbounded_send(UiEvent::AccountSyncFinished { ok, message });
            });
        });
        app.add_action(&sync);
    }
    {
        let app = app.clone();
        let app_for_dialog = app.clone();
        let window = window.clone();
        let pending_incoming = pending_incoming.clone();
        let review = gio::SimpleAction::new("incoming-review", Some(glib::VariantTy::STRING));
        review.connect_activate(move |_, param| {
            let Some(transfer_id) = param.and_then(|v| v.str()).map(|s| s.to_string()) else {
                return;
            };
            present_incoming_transfer_dialog(
                app_for_dialog.clone(),
                window.clone(),
                pending_incoming.clone(),
                transfer_id,
            );
        });
        app.add_action(&review);
    }
    {
        let app = app.clone();
        let app_for_decision = app.clone();
        let pending_incoming = pending_incoming.clone();
        let decline = gio::SimpleAction::new("incoming-decline", Some(glib::VariantTy::STRING));
        decline.connect_activate(move |_, param| {
            let Some(transfer_id) = param.and_then(|v| v.str()).map(|s| s.to_string()) else {
                return;
            };
            finalize_incoming_transfer_decision(
                &app_for_decision,
                &pending_incoming,
                &transfer_id,
                IncomingTransferDecision::decline(),
            );
        });
        app.add_action(&decline);
    }
    {
        let app = app.clone();
        let app_for_dialog = app.clone();
        let window = window.clone();
        let pending_remote = pending_remote.clone();
        let review = gio::SimpleAction::new("remote-review", Some(glib::VariantTy::STRING));
        review.connect_activate(move |_, param| {
            let Some(session_id) = param.and_then(|v| v.str()).map(|s| s.to_string()) else {
                return;
            };
            present_remote_control_dialog(
                app_for_dialog.clone(),
                window.clone(),
                pending_remote.clone(),
                session_id,
            );
        });
        app.add_action(&review);
    }
    {
        let app = app.clone();
        let app_for_decision = app.clone();
        let pending_remote = pending_remote.clone();
        let decline = gio::SimpleAction::new("remote-decline", Some(glib::VariantTy::STRING));
        decline.connect_activate(move |_, param| {
            let Some(session_id) = param.and_then(|v| v.str()).map(|s| s.to_string()) else {
                return;
            };
            finalize_remote_control_decision(
                &app_for_decision,
                &pending_remote,
                &session_id,
                false,
            );
        });
        app.add_action(&decline);
    }

    let login_page_rx = login_page.clone();
    let sidebar_rx = sidebar.clone();
    let root_stack_rx = root_stack.clone();
    let settings_page_rx = settings_page.clone();
    let dashboard_page_rx = dashboard_page.clone();
    let auto_join_consumed = Rc::new(RefCell::new(false));
    let auto_join_consumed_rx = auto_join_consumed.clone();
    glib::MainContext::default().spawn_local(async move {
        while let Some(event) = auth_rx.next().await {
            login_page_rx.set_loading(false);
            match event {
                AuthUiEvent::LoggedIn(summary) => {
                    tracing::info!("Auth UI received LoggedIn event");
                    let UserSummary {
                        display_name,
                        user_id,
                        nebula_id,
                    } = summary;
                    let display_name = if display_name.is_empty() {
                        "User".to_string()
                    } else {
                        display_name
                    };
                    let user_id = nebula_id.unwrap_or(user_id);
                    sidebar_rx.user_name.set_label(&display_name);
                    sidebar_rx.user_id.set_label(&format!("ID: {}", user_id));
                    root_stack_rx.set_visible_child_name("main");
                    login_page_rx.clear_status();
                    settings_page_rx.refresh_account_state();
                    let auto_join_code = std::env::var("SKYBRIDGE_TEST_CONNECTION_CODE")
                        .ok()
                        .map(|code| code.trim().to_string())
                        .filter(|code| !code.is_empty());
                    if let Some(code) = auto_join_code
                        && !*auto_join_consumed_rx.borrow()
                    {
                        *auto_join_consumed_rx.borrow_mut() = true;
                        let dashboard_page_join = dashboard_page_rx.clone();
                        tracing::info!("Scheduling automation WebRTC join for {}", code);
                        glib::timeout_add_seconds_local_once(1, move || {
                            dashboard_page_join.trigger_webrtc_join(code);
                        });
                    }
                }
                AuthUiEvent::PendingVerification(email) => {
                    login_page_rx.show_error(&format!(
                        "Registration successful. Verify {} and then sign in.",
                        email
                    ));
                }
                AuthUiEvent::Info(message) => {
                    login_page_rx.show_error(&message);
                }
                AuthUiEvent::Error(message) => {
                    login_page_rx.show_error(&message);
                }
            }
        }
    });

    let login_page_cb = login_page.clone();
    let auth_tx_login = auth_tx.clone();
    let auth_login = auth.clone();
    let runtime_login = runtime.clone();
    login_page.connect_login(move |email, password| {
        login_page_cb.clear_status();
        login_page_cb.set_loading(true);

        let auth_tx_login = auth_tx_login.clone();
        let auth_login = auth_login.clone();
        let email_clone = email.clone();
        runtime_login.spawn(async move {
            let mut auth = auth_login.lock().await;
            let result = auth.login_email(&email, &password).await;
            match result {
                Ok(session) => {
                    let summary = summarize_session(session, Some(&email_clone));
                    let _ = auth_tx_login.unbounded_send(AuthUiEvent::LoggedIn(summary));
                }
                Err(AuthError::EmailVerificationRequired) => {
                    let _ =
                        auth_tx_login.unbounded_send(AuthUiEvent::PendingVerification(email_clone));
                }
                Err(err) => {
                    let _ =
                        auth_tx_login.unbounded_send(AuthUiEvent::Error(auth_error_message(err)));
                }
            }
        });
    });

    let login_page_register = login_page.clone();
    let auth_tx_register = auth_tx.clone();
    let auth_register = auth.clone();
    let runtime_register = runtime.clone();
    login_page.connect_register(move |email, password| {
        login_page_register.clear_status();
        login_page_register.set_loading(true);

        let auth_tx_register = auth_tx_register.clone();
        let auth_register = auth_register.clone();
        let email_clone = email.clone();
        runtime_register.spawn(async move {
            let mut auth = auth_register.lock().await;
            let result = auth.register(Some(&email), None, &password, None).await;
            match result {
                Ok(session) => {
                    let summary = summarize_session(session, Some(&email_clone));
                    let _ = auth_tx_register.unbounded_send(AuthUiEvent::LoggedIn(summary));
                }
                Err(AuthError::EmailVerificationRequired) => {
                    let _ = auth_tx_register
                        .unbounded_send(AuthUiEvent::PendingVerification(email_clone));
                }
                Err(err) => {
                    let _ = auth_tx_register
                        .unbounded_send(AuthUiEvent::Error(auth_error_message(err)));
                }
            }
        });
    });

    let login_page_phone = login_page.clone();
    let auth_tx_phone = auth_tx.clone();
    let auth_phone = auth.clone();
    let runtime_phone = runtime.clone();
    login_page.connect_send_phone_code(move |phone| {
        login_page_phone.clear_status();
        login_page_phone.set_loading(true);

        let auth_tx_phone = auth_tx_phone.clone();
        let auth_phone = auth_phone.clone();
        runtime_phone.spawn(async move {
            let mut auth = auth_phone.lock().await;
            let result = auth.send_phone_code(&phone).await;
            match result {
                Ok(()) => {
                    let _ = auth_tx_phone
                        .unbounded_send(AuthUiEvent::Info("SMS code sent.".to_string()));
                }
                Err(err) => {
                    let _ =
                        auth_tx_phone.unbounded_send(AuthUiEvent::Error(auth_error_message(err)));
                }
            }
        });
    });

    let login_page_phone_login = login_page.clone();
    let auth_tx_phone_login = auth_tx.clone();
    let auth_phone_login = auth.clone();
    let runtime_phone_login = runtime.clone();
    login_page.connect_phone_login(move |phone, code| {
        login_page_phone_login.clear_status();
        login_page_phone_login.set_loading(true);

        let auth_tx_phone_login = auth_tx_phone_login.clone();
        let auth_phone_login = auth_phone_login.clone();
        runtime_phone_login.spawn(async move {
            let mut auth = auth_phone_login.lock().await;
            let result = auth.login_phone(&phone, &code).await;
            match result {
                Ok(session) => {
                    let summary = summarize_session(session, None);
                    let _ = auth_tx_phone_login.unbounded_send(AuthUiEvent::LoggedIn(summary));
                }
                Err(err) => {
                    let _ = auth_tx_phone_login
                        .unbounded_send(AuthUiEvent::Error(auth_error_message(err)));
                }
            }
        });
    });

    let login_page_apple = login_page.clone();
    let auth_tx_apple = auth_tx.clone();
    let auth_apple = auth.clone();
    let runtime_apple = runtime.clone();
    login_page.connect_apple_login(move || {
        login_page_apple.clear_status();
        login_page_apple.set_loading(true);

        let auth_tx_apple = auth_tx_apple.clone();
        let auth_apple = auth_apple.clone();
        runtime_apple.spawn(async move {
            let mut auth = auth_apple.lock().await;
            let result = auth.login_apple().await;
            match result {
                Ok(session) => {
                    let summary = summarize_session(session, session.user.email.as_deref());
                    let _ = auth_tx_apple.unbounded_send(AuthUiEvent::LoggedIn(summary));
                }
                Err(err) => {
                    let _ =
                        auth_tx_apple.unbounded_send(AuthUiEvent::Error(auth_error_message(err)));
                }
            }
        });
    });

    // Initialize services in background
    let dashboard_tx_clone = dashboard_tx.clone();
    let runtime_clone = runtime.clone();
    let identity_clone = identity.clone();
    let settings_clone = settings.clone();
    let transfer_engine_clone = Arc::clone(&transfer_engine);
    let transfer_keys_clone = Arc::clone(&transfer_keys);
    let p2p_manager_clone = Arc::clone(&p2p_manager);
    let tray_handle_clone = Arc::clone(&tray_handle);
    let stream_rx = stream_rx;
    let ui_tx_clone = ui_tx.clone();
    runtime.spawn(async move {
        init_services(
            dashboard_tx_clone,
            ui_tx_clone,
            runtime_clone,
            identity_clone,
            settings_clone,
            transfer_engine_clone,
            transfer_keys_clone,
            p2p_manager_clone,
            tray_handle_clone,
            stream_rx,
        )
        .await;
    });

    let auth_tx_restore = auth_tx.clone();
    let auth_restore = auth.clone();
    runtime.spawn(async move {
        let mut auth = auth_restore.lock().await;
        if let Ok(Some(session)) = auth.load_persisted_session() {
            tracing::info!("Restored persisted session");
            let summary = summarize_session(session, None);
            let _ = auth_tx_restore.unbounded_send(AuthUiEvent::LoggedIn(summary));
            return;
        }

        let test_email = std::env::var("SKYBRIDGE_TEST_EMAIL").ok();
        let test_password = std::env::var("SKYBRIDGE_TEST_PASSWORD").ok();
        if let (Some(email), Some(password)) = (test_email, test_password) {
            let email = email.trim().to_string();
            if email.is_empty() || password.is_empty() {
                return;
            }

            match auth.login_email(&email, &password).await {
                Ok(session) => {
                    tracing::info!("Automation login succeeded");
                    let summary = summarize_session(session, session.user.email.as_deref());
                    let _ = auth_tx_restore.unbounded_send(AuthUiEvent::LoggedIn(summary));
                }
                Err(err) => {
                    let _ = auth_tx_restore.unbounded_send(AuthUiEvent::Error(format!(
                        "Automation login failed: {}",
                        auth_error_message(err)
                    )));
                }
            }
        }
    });

    window.present();
}

/// Create sidebar navigation
fn create_sidebar() -> Sidebar {
    let sidebar = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .width_request(280)
        .css_classes(vec!["sidebar".to_string()])
        .build();

    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .css_classes(vec!["sidebar-header".to_string()])
        .build();

    let header_row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .css_classes(vec!["sidebar-brand-row".to_string()])
        .build();

    let app_icon = skybridge_ui::utils::brand_logo_image(40);
    app_icon.add_css_class("sidebar-brand-icon");
    header_row.append(&app_icon);

    let header_text = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(2)
        .valign(gtk::Align::Center)
        .css_classes(vec!["sidebar-brand-copy".to_string()])
        .build();

    let app_title = gtk::Label::builder()
        .label("SkyBridge Compass")
        .css_classes(vec!["sidebar-title".to_string()])
        .xalign(0.0)
        .build();
    let app_subtitle = gtk::Label::builder()
        .label("Next-Gen Cross-Platform\nConnection Experience")
        .css_classes(vec![
            "sidebar-subtitle".to_string(),
            "dim-label".to_string(),
        ])
        .wrap(true)
        .xalign(0.0)
        .build();
    let device_info = gtk::Label::builder()
        .label(format!(
            "{} • Ubuntu Desktop",
            hostname::get()
                .map(|h| h.to_string_lossy().to_string())
                .unwrap_or_else(|_| "Ubuntu Device".to_string())
        ))
        .css_classes(vec!["sidebar-device".to_string(), "dim-label".to_string()])
        .xalign(0.0)
        .build();

    header_text.append(&app_title);
    header_text.append(&app_subtitle);
    header_text.append(&device_info);
    header_row.append(&header_text);
    header.append(&header_row);
    sidebar.append(&header);

    // Navigation menu
    let nav_box = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(4)
        .margin_top(16)
        .margin_bottom(8)
        .vexpand(true)
        .css_classes(vec!["sidebar-nav".to_string()])
        .build();

    let nav_items = [
        ("go-home-symbolic", "Main Console", "dashboard", true),
        (
            "system-search-symbolic",
            "Device Discovery",
            "devices",
            false,
        ),
        ("usb-symbolic", "USB Management", "usb", false),
        (
            "folder-symbolic",
            "File Transfer (Quantum Communication)",
            "transfers",
            false,
        ),
        (
            "video-display-symbolic",
            "Remote Desktop (Quantum Communication)",
            "remote",
            false,
        ),
        ("face-smile-symbolic", "System Monitor", "monitoring", false),
        ("preferences-system-symbolic", "Settings", "settings", false),
    ];

    let mut nav_buttons = HashMap::<String, gtk::Button>::new();
    for (icon, label, id, selected) in nav_items {
        let nav_item = create_nav_item(icon, label, id, selected);
        nav_item.set_sensitive(true);
        nav_buttons.insert(id.to_string(), nav_item.clone());
        nav_box.append(&nav_item);
    }

    sidebar.append(&nav_box);

    // User profile at bottom
    let profile = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .css_classes(vec![
            "user-profile".to_string(),
            "sidebar-footer".to_string(),
        ])
        .build();

    let avatar = adw::Avatar::builder()
        .size(36)
        .text("User")
        .show_initials(true)
        .css_classes(vec!["user-avatar".to_string()])
        .build();
    profile.append(&avatar);

    let user_info = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(2)
        .hexpand(true)
        .valign(gtk::Align::Center)
        .build();

    let user_name = gtk::Label::builder()
        .label("Not signed in")
        .css_classes(vec!["user-name".to_string()])
        .xalign(0.0)
        .build();
    let user_id = gtk::Label::builder()
        .label("ID: -")
        .css_classes(vec!["user-id".to_string(), "dim-label".to_string()])
        .xalign(0.0)
        .build();

    user_info.append(&user_name);
    user_info.append(&user_id);
    profile.append(&user_info);

    // Settings button
    let settings_btn = gtk::Button::builder()
        .icon_name("emblem-system-symbolic")
        .css_classes(vec!["flat".to_string(), "circular".to_string()])
        .valign(gtk::Align::Center)
        .build();
    profile.append(&settings_btn);

    sidebar.append(&profile);

    Sidebar {
        widget: sidebar,
        user_name,
        user_id,
        nav_buttons,
        settings_btn,
    }
}

/// Create navigation item
fn create_nav_item(icon_name: &str, label: &str, nav_id: &str, selected: bool) -> gtk::Button {
    let item = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .css_classes(vec!["nav-content".to_string()])
        .build();

    let icon = skybridge_ui::utils::image_from_icon_name(icon_name);
    icon.add_css_class("nav-icon");
    item.append(&icon);

    let text = gtk::Label::builder()
        .label(label)
        .css_classes(vec!["nav-label".to_string()])
        .xalign(0.0)
        .hexpand(true)
        .build();
    item.append(&text);

    let mut classes = vec![
        "nav-item".to_string(),
        format!("nav-{}", nav_id),
        "flat".to_string(),
    ];
    if selected {
        classes.push("selected".to_string());
    }
    gtk::Button::builder()
        .child(&item)
        .css_classes(classes)
        .has_frame(false)
        .build()
}

fn summarize_session(session: &AuthSession, fallback_email: Option<&str>) -> UserSummary {
    let display_name = session
        .user
        .display_name
        .clone()
        .or_else(|| session.user.email.clone())
        .or_else(|| fallback_email.map(str::to_string))
        .unwrap_or_else(|| "User".to_string());
    let nebula_id = session
        .user
        .nebula_id
        .as_ref()
        .map(|id| id.formatted.clone());
    UserSummary {
        display_name,
        user_id: session.user.user_id.clone(),
        nebula_id,
    }
}

fn auth_error_message(error: AuthError) -> String {
    match error {
        AuthError::SupabaseConfigMissing => {
            "Supabase not configured. Open Settings to set SUPABASE_URL and SUPABASE_ANON_KEY."
                .to_string()
        }
        AuthError::SupabaseConfigInvalid(message) => {
            format!("Supabase config invalid: {}", message)
        }
        AuthError::EmailVerificationRequired => {
            "Registration successful. Please verify your email, then sign in.".to_string()
        }
        AuthError::OAuth(message) => format!("Apple login failed: {}", message),
        AuthError::InvalidCredentials => "Invalid credentials".to_string(),
        other => other.to_string(),
    }
}

fn handshake_policy_from_settings(settings: &AppSettings) -> HandshakePolicy {
    let mut policy = HandshakePolicy::default_policy();
    if settings.security.enable_pqc {
        policy.require_pqc = !settings.security.allow_classic_only;
        policy.allow_classic_fallback = settings.security.allow_classic_only;
        policy.minimum_tier = if settings.security.prefer_hybrid {
            CryptoTier::NativePqc
        } else {
            CryptoTier::LiboqsPqc
        };
    } else {
        policy.require_pqc = false;
        policy.allow_classic_fallback = true;
        policy.minimum_tier = CryptoTier::Classic;
    }
    policy
}

fn connection_trust_policy_from_settings(settings: &AppSettings) -> ConnectionTrustPolicy {
    ConnectionTrustPolicy {
        block_unknown: settings.security.block_unknown,
        require_verification: settings.security.require_verification,
    }
}

fn preferred_outbound_peer_fingerprint(device: &DiscoveredDevice) -> Option<String> {
    if let Ok(store) = TrustStore::load() {
        if let Some(pinned) = store.peer_current_path_fingerprint(&device.device_id) {
            return Some(pinned);
        }
        if let Some(pinned) = store.peer_signing_fingerprint(&device.device_id) {
            return Some(pinned);
        }
    }

    let discovered = device.public_key_fingerprint.trim();
    if discovered.is_empty() {
        None
    } else {
        Some(discovered.to_string())
    }
}

fn validate_outbound_device_trust(
    device: &DiscoveredDevice,
    settings: &AppSettings,
) -> Result<(), String> {
    let policy = connection_trust_policy_from_settings(settings);
    if !policy.block_unknown && !policy.require_verification {
        return Ok(());
    }

    let store = TrustStore::load().map_err(|err| format!("Trust store unavailable: {}", err))?;

    if policy.block_unknown && !store.is_trusted(&device.device_id) {
        return Err(format!("Blocked unknown device: {}", device.name));
    }

    if policy.require_verification && preferred_outbound_peer_fingerprint(device).is_none() {
        return Err(format!(
            "Cannot verify {}: no trusted or discovered fingerprint",
            device.name
        ));
    }

    Ok(())
}

fn transfer_config_from_settings(settings: &AppSettings) -> TransferConfig {
    TransferConfig {
        chunk_size: settings.transfer.chunk_size_mb * 1024 * 1024,
        max_concurrent: settings.transfer.max_concurrent,
        max_parallel_chunks: settings.transfer.max_parallel_chunks,
        compression: settings.transfer.compression,
        zstd_level: settings.transfer.zstd_level,
        encryption_enabled: true,
        resume_enabled: settings.transfer.enable_resume,
        manifest_dir: None,
        verify_chunks: settings.transfer.verify_chunks,
        latency_threshold_ms: settings.network.lan_latency_threshold_ms,
    }
}

fn mac_remote_server_config_from_settings(settings: &AppSettings) -> MacRemoteControlServerConfig {
    let name = if settings.device.name.is_empty() {
        "SkyBridge Remote".to_string()
    } else {
        format!("SkyBridge Remote - {}", settings.device.name)
    };
    MacRemoteControlServerConfig {
        bind_addr: format!("0.0.0.0:{}", settings.network.remote_control_port)
            .parse()
            .unwrap(),
        name,
        target_fps: settings.remote_desktop.framerate.max(1),
        jpeg_quality: 55,
        capture_cursor: settings.remote_desktop.show_cursor,
        allow_input: settings.remote_desktop.allow_control,
    }
}

fn vnc_server_config_from_settings(settings: &AppSettings) -> VncServerConfig {
    let name = if settings.device.name.is_empty() {
        "SkyBridge VNC".to_string()
    } else {
        format!("SkyBridge VNC - {}", settings.device.name)
    };
    VncServerConfig {
        bind_addr: format!("0.0.0.0:{}", settings.network.vnc_port)
            .parse()
            .unwrap(),
        name,
        target_fps: settings.remote_desktop.framerate.max(1),
        capture_cursor: settings.remote_desktop.show_cursor,
        allow_input: settings.remote_desktop.allow_control,
    }
}

fn transfer_server_config_from_settings(
    settings: &AppSettings,
    incoming_prompt: Option<IncomingTransferPromptConfig>,
) -> FileTransferServerConfig {
    FileTransferServerConfig {
        bind_addr: format!("0.0.0.0:{}", settings.network.transfer_port)
            .parse()
            .unwrap(),
        target_dir: settings.transfer.save_location.clone(),
        incoming_prompt,
    }
}

fn map_quality_to_vnc(quality: u8) -> u8 {
    let q = quality.clamp(1, 51) as u32;
    let mapped = ((51 - q) * 8 / 50) + 1;
    mapped as u8
}

fn vnc_client_config_from_settings(settings: &AppSettings) -> VncConfig {
    VncConfig {
        max_fps: settings.remote_desktop.framerate.max(1),
        quality: map_quality_to_vnc(settings.remote_desktop.quality),
        local_cursor: settings.remote_desktop.show_cursor,
        compression: !settings.remote_desktop.low_latency,
        ..VncConfig::default()
    }
}

fn encoder_config_from_settings(settings: &AppSettings) -> EncoderConfig {
    let bitrate = settings.remote_desktop.bitrate_mbps.max(1) * 1_000_000;
    let max_bitrate = bitrate + (bitrate / 2);
    let framerate = settings.remote_desktop.framerate.max(1);
    let rate_control = if settings.remote_desktop.low_latency {
        RateControl::Cbr
    } else {
        RateControl::ConstantQuality
    };
    let capabilities = SenderCapabilityResolver::probe(settings.remote_desktop.hardware_encoder);
    let resolved_codec = capabilities.resolve_requested_codec(
        settings.remote_desktop.codec,
        settings.remote_desktop.low_latency,
    );
    EncoderConfig {
        codec: resolved_codec,
        hardware: capabilities.encoder,
        bitrate,
        max_bitrate,
        framerate,
        keyframe_interval: framerate.saturating_mul(2),
        rate_control,
        quality: settings.remote_desktop.quality,
        preset: settings.remote_desktop.preset,
        b_frames: !settings.remote_desktop.low_latency,
        low_latency: settings.remote_desktop.low_latency,
        tune_screen: settings.remote_desktop.tune_screen,
    }
}

fn capture_config_from_settings(settings: &AppSettings) -> CaptureConfig {
    CaptureConfig {
        target_fps: settings.remote_desktop.framerate.max(1),
        capture_cursor: settings.remote_desktop.show_cursor,
        ..CaptureConfig::default()
    }
}

fn ultrastream_codec_from_encoder(codec: VideoCodec) -> UltraStreamCodec {
    match codec {
        VideoCodec::Auto => UltraStreamCodec::H264,
        VideoCodec::H264 => UltraStreamCodec::H264,
        VideoCodec::H265 => UltraStreamCodec::Hevc,
        VideoCodec::Av1 => {
            tracing::warn!("AV1 not supported by UltraStream, falling back to H.264");
            UltraStreamCodec::H264
        }
    }
}

fn timestamp_ms_from_frame(ts_ns: u64) -> u32 {
    let ms = ts_ns / 1_000_000;
    ms.min(u64::from(u32::MAX)) as u32
}

fn looks_like_ultrastream_packet(packet: &[u8]) -> bool {
    packet.len() >= 4 && &packet[..4] == b"USTR"
}

fn run_tcp_control_remote_desktop_decoder(
    connection_id: String,
    session_keys: skybridge_core::p2p::SessionKeys,
    mut packet_rx: tokio::sync::mpsc::Receiver<Vec<u8>>,
    ui_tx: mpsc::UnboundedSender<RemoteDesktopBgraFrame>,
) {
    let mut receiver = match UltraStreamReceiver::new_with_session_keys(&session_keys) {
        Ok(receiver) => receiver,
        Err(err) => {
            tracing::warn!(
                "Remote desktop receiver init failed for {}: {}",
                connection_id,
                err
            );
            return;
        }
    };

    let mut decoder = match AutoDecoder::new() {
        Ok(decoder) => decoder,
        Err(err) => {
            tracing::warn!(
                "Remote desktop decode unavailable for {}: {}",
                connection_id,
                err
            );
            return;
        }
    };

    let mut warned_non_ustr = false;
    let mut warned_decode = false;
    while let Some(packet) = packet_rx.blocking_recv() {
        if !looks_like_ultrastream_packet(&packet) {
            if !warned_non_ustr {
                tracing::debug!(
                    "Remote desktop payload for {} is not UltraStream (missing USTR magic)",
                    connection_id
                );
                warned_non_ustr = true;
            }
            continue;
        }

        match receiver.handle_packet_with_decoder(&packet, &mut decoder) {
            Ok(Some(UltraStreamDecodedFrame::Bgra {
                width,
                height,
                data,
            })) => {
                let _ = ui_tx.unbounded_send(RemoteDesktopBgraFrame {
                    connection_id: connection_id.clone(),
                    width,
                    height,
                    bgra: data,
                });
            }
            Ok(Some(_)) => {}
            Ok(None) => {}
            Err(err) => {
                if !warned_decode {
                    tracing::warn!("Remote desktop decode error for {}: {}", connection_id, err);
                    warned_decode = true;
                } else {
                    tracing::debug!("Remote desktop decode error for {}: {}", connection_id, err);
                }
            }
        }
    }
}

async fn stream_ultrastream_for_connection(
    connection_id: String,
    p2p_manager: Arc<P2PConnectionManager>,
    remote_manager: Arc<RemoteDesktopManager>,
) -> Result<(), String> {
    let connection = p2p_manager
        .get_connection(&connection_id)
        .await
        .ok_or_else(|| "Connection not found".to_string())?;
    let session_keys = {
        let conn = connection.read().await;
        conn.session_keys()
            .cloned()
            .ok_or_else(|| "Session keys not established".to_string())?
    };

    let mut sender = UltraStreamSender::new_with_session_keys(&session_keys)
        .map_err(|err| format!("UltraStream sender init failed: {}", err))?;

    let (mut encoder_config, mut capture_config) = remote_manager.streaming_config().await;

    let mut capturer =
        ScreenCapturer::new().map_err(|err| format!("Capture init failed: {}", err))?;
    capturer
        .initialize()
        .await
        .map_err(|err| format!("Capture initialize failed: {}", err))?;
    let mut frame_rx = capturer
        .start(&capture_config)
        .await
        .map_err(|err| format!("Capture start failed: {}", err))?;

    let mut encoder = UnifiedEncoder::new(encoder_config.clone()).map_err(|err| err.to_string())?;
    let mut encoder_ready = false;
    let mut last_size = (0u32, 0u32);
    let mut config_tick = tokio::time::interval(std::time::Duration::from_secs(1));

    loop {
        tokio::select! {
            _ = config_tick.tick() => {
                let (new_encoder, new_capture) = remote_manager.streaming_config().await;
                if new_capture != capture_config {
                    let _ = capturer.stop().await;
                    capture_config = new_capture;
                    frame_rx = capturer
                        .start(&capture_config)
                        .await
                        .map_err(|err| format!("Capture restart failed: {}", err))?;
                    encoder_ready = false;
                }

                if new_encoder != encoder_config {
                    if encoder.update_config(&new_encoder).is_err() {
                        encoder =
                            UnifiedEncoder::new(new_encoder.clone()).map_err(|err| err.to_string())?;
                        encoder_ready = false;
                    }
                    encoder_config = new_encoder;
                }
            }
            frame = frame_rx.recv() => {
                let Some(frame) = frame else { break; };
                if frame.width == 0 || frame.height == 0 {
                    continue;
                }

                let size_changed = last_size != (frame.width, frame.height);
                if !encoder_ready || size_changed {
                    if encoder_ready {
                        let _ = encoder.shutdown().await;
                    }
                    encoder =
                        UnifiedEncoder::new(encoder_config.clone()).map_err(|err| err.to_string())?;
                    encoder
                        .initialize(frame.width, frame.height)
                        .await
                        .map_err(|err| err.to_string())?;
                    encoder_ready = true;
                    last_size = (frame.width, frame.height);
                }

                let encoded = encoder.encode(&frame).await.map_err(|err| err.to_string())?;
                let codec = ultrastream_codec_from_encoder(encoder_config.codec);
                let timestamp_ms = timestamp_ms_from_frame(frame.timestamp);
                let width = encoded.width.min(u16::MAX as u32) as u16;
                let height = encoded.height.min(u16::MAX as u32) as u16;

                let send_result = {
                    let mut conn = connection.write().await;
                    conn.send_ultrastream_frame(
                        &mut sender,
                        codec,
                        width,
                        height,
                        timestamp_ms,
                        &encoded.data,
                    )
                    .await
                };

                if let Err(err) = send_result {
                    return Err(format!("UltraStream send failed: {}", err));
                }
            }
        }
    }

    let _ = capturer.stop().await;
    let _ = encoder.shutdown().await;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn init_services(
    dashboard_tx: mpsc::UnboundedSender<DashboardUiEvent>,
    ui_tx: mpsc::UnboundedSender<UiEvent>,
    runtime: Arc<tokio::runtime::Runtime>,
    identity: LocalIdentity,
    settings: AppSettings,
    transfer_engine: Arc<FileTransferEngine>,
    transfer_keys: Arc<TransferKeyStore>,
    p2p_manager: Arc<P2PConnectionManager>,
    tray_handle: Arc<tokio::sync::Mutex<Option<ksni::Handle<tray::CompassTray>>>>,
    mut stream_rx: tokio::sync::mpsc::UnboundedReceiver<StreamRequest>,
) {
    info!("Initializing services...");
    if let Err(err) = autostart_linux::set_autostart_enabled(settings.device.start_on_login) {
        tracing::warn!("Failed to apply autostart setting: {}", err);
    }

    let (incoming_prompt_tx, mut incoming_prompt_rx) =
        tokio::sync::mpsc::unbounded_channel::<IncomingTransferPromptRequest>();
    let (incoming_completed_tx, mut incoming_completed_rx) =
        tokio::sync::mpsc::unbounded_channel::<IncomingTransferCompleted>();
    let incoming_prompt_config = IncomingTransferPromptConfig {
        request_tx: incoming_prompt_tx,
        completed_tx: Some(incoming_completed_tx),
        decision_timeout: std::time::Duration::from_secs(INCOMING_TRANSFER_DECISION_TIMEOUT_SECS),
    };

    {
        let ui_tx = ui_tx.clone();
        runtime.spawn(async move {
            while let Some(req) = incoming_prompt_rx.recv().await {
                let IncomingTransferPromptRequest {
                    request,
                    decision_tx,
                } = req;
                let settings = AppSettings::load();
                let is_trusted = request
                    .sender_device_id
                    .as_deref()
                    .and_then(|device_id| {
                        TrustStore::load().ok().map(|ts| ts.is_trusted(device_id))
                    })
                    .unwrap_or(false);
                if settings.transfer.auto_accept_trusted && is_trusted {
                    let base_dir = settings.transfer.save_location;
                    let mut save_path = base_dir.join(&request.file_name);
                    let overwrite = !settings.transfer.confirm_overwrite;
                    if settings.transfer.confirm_overwrite && save_path.exists() {
                        save_path = unique_destination(&base_dir, &request.file_name);
                    }
                    let _ = decision_tx.send(IncomingTransferDecision {
                        accept: true,
                        save_path: Some(save_path),
                        overwrite,
                    });
                    continue;
                }
                let _ = ui_tx.unbounded_send(UiEvent::IncomingTransferPrompt {
                    request,
                    decision_tx,
                });
            }
        });
    }
    {
        let ui_tx = ui_tx.clone();
        runtime.spawn(async move {
            while let Some(done) = incoming_completed_rx.recv().await {
                let _ = ui_tx.unbounded_send(UiEvent::IncomingTransferCompleted(done));
            }
        });
    }

    transfer_engine.set_config(transfer_config_from_settings(&settings));
    let remote_manager = Arc::new(RemoteDesktopManager::with_config(
        vnc_client_config_from_settings(&settings),
    ));
    remote_manager
        .update_streaming_config(
            encoder_config_from_settings(&settings),
            capture_config_from_settings(&settings),
        )
        .await;

    let stream_manager = Arc::clone(&p2p_manager);
    let stream_remote = Arc::clone(&remote_manager);
    let stream_dashboard_tx = dashboard_tx.clone();
    runtime.spawn(async move {
        let mut active_streams: HashMap<String, tokio::task::JoinHandle<()>> = HashMap::new();
        while let Some(request) = stream_rx.recv().await {
            let settings = AppSettings::load();
            if !settings
                .device
                .capabilities
                .contains(&DeviceCapability::RemoteDesktopView)
            {
                tracing::info!("Remote desktop view disabled; skipping stream");
                continue;
            }

            if let Some(handle) = active_streams.get(&request.connection_id)
                && !handle.is_finished()
            {
                continue;
            }
            active_streams.remove(&request.connection_id);

            let connection_id = request.connection_id.clone();
            let p2p = Arc::clone(&stream_manager);
            let remote = Arc::clone(&stream_remote);
            let dashboard_tx = stream_dashboard_tx.clone();
            let handle = tokio::spawn(async move {
                let _ = dashboard_tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                    ConnectionUpdate {
                        message: "Streaming active".to_string(),
                        phase: ConnectionPhase::Connected,
                        connection_id: Some(connection_id.clone()),
                        peer_id: None,
                        peer_name: None,
                        streaming: Some(StreamingStatus {
                            active: true,
                            message: Some("Streaming".to_string()),
                        }),
                    },
                ));
                if let Err(err) =
                    stream_ultrastream_for_connection(connection_id.clone(), p2p, remote).await
                {
                    tracing::warn!("UltraStream ended for {}: {}", connection_id, err);
                    let _ = dashboard_tx.unbounded_send(DashboardUiEvent::ConnectionStatus(
                        ConnectionUpdate {
                            message: format!("Streaming stopped: {}", err),
                            phase: ConnectionPhase::Connected,
                            connection_id: Some(connection_id.clone()),
                            peer_id: None,
                            peer_name: None,
                            streaming: Some(StreamingStatus {
                                active: false,
                                message: Some("Streaming stopped".to_string()),
                            }),
                        },
                    ));
                }
            });
            active_streams.insert(request.connection_id, handle);
        }
    });

    let device_id = identity.device_id.clone();
    let device_name = if settings.device.name.is_empty() {
        hostname::get()
            .map(|h| h.to_string_lossy().to_string())
            .unwrap_or_else(|_| "Ubuntu Device".to_string())
    } else {
        settings.device.name.clone()
    };
    let device_capabilities = settings.device.capabilities.clone();
    let fingerprint = identity.primary_signing_fingerprint().unwrap_or_default();
    if fingerprint.is_empty() {
        tracing::warn!("Local identity fingerprint unavailable; discovery may be limited");
    }

    // Initialize discovery
    let discovery_config = DiscoveryConfig {
        enable_mdns: settings.network.enable_mdns,
        enable_bluetooth: settings.network.enable_bluetooth,
        enable_wifi_direct: settings.network.enable_wifi_direct,
        discovery_timeout_secs: settings.network.discovery_timeout_secs,
        prefer_ipv6: settings.network.prefer_ipv6,
        remote_port: if settings.network.enable_remote_control_server {
            Some(settings.network.remote_control_port)
        } else {
            None
        },
        transfer_port: if settings.network.enable_transfer_server {
            Some(settings.network.transfer_port)
        } else {
            None
        },
    };
    let mut discovery = DeviceDiscoveryManager::with_config(
        device_id.clone(),
        device_name,
        fingerprint.clone(),
        discovery_config,
    );
    let _ = discovery.set_capabilities(device_capabilities);

    let devices_cache = Arc::new(RwLock::new(HashMap::<String, DiscoveredDevice>::new()));

    // Set up discovery callbacks
    let dashboard_tx_discovered = dashboard_tx.clone();
    let devices_cache_discovered = Arc::clone(&devices_cache);
    discovery.on_device_discovered(move |device| {
        info!("Device discovered: {}", device.name);
        let mut cache = devices_cache_discovered.write().unwrap();
        cache.insert(device.device_id.clone(), device.clone());
        let devices = cache.values().cloned().collect();
        let _ =
            dashboard_tx_discovered.unbounded_send(DashboardUiEvent::DevicesUpdated { devices });
    });

    let dashboard_tx_removed = dashboard_tx.clone();
    let devices_cache_removed = Arc::clone(&devices_cache);
    discovery.on_device_removed(move |device_id| {
        info!("Device removed: {}", device_id);
        let mut cache = devices_cache_removed.write().unwrap();
        cache.remove(device_id);
        let devices = cache.values().cloned().collect();
        let _ = dashboard_tx_removed.unbounded_send(DashboardUiEvent::DevicesUpdated { devices });
    });

    // Start discovery
    if let Err(e) = discovery.start(settings.network.quic_port) {
        tracing::error!("Failed to start discovery: {}", e);
    } else {
        info!("Discovery started on port {}", settings.network.quic_port);
        let _ = dashboard_tx.unbounded_send(DashboardUiEvent::ConnectionStatus(ConnectionUpdate {
            message: "Scanning via mDNS...".to_string(),
            phase: ConnectionPhase::Discovering,
            connection_id: None,
            peer_id: None,
            peer_name: None,
            streaming: None,
        }));
    }

    let discovery = Arc::new(tokio::sync::Mutex::new(discovery));
    let remote_updates = Arc::clone(&remote_manager);
    let discovery_updates = Arc::clone(&discovery);
    let runtime_updates = Arc::clone(&runtime);
    let transfer_engine_updates = Arc::clone(&transfer_engine);
    let transfer_keys_updates = Arc::clone(&transfer_keys);

    let mut remote_control_handle = if settings.network.enable_remote_control_server {
        Some(spawn_mac_remote_control_server(
            &runtime,
            mac_remote_server_config_from_settings(&settings),
        ))
    } else {
        tracing::info!("Remote control server disabled in settings");
        None
    };

    let mut vnc_handle = if settings.network.enable_vnc_server {
        Some(spawn_vnc_server(
            &runtime,
            vnc_server_config_from_settings(&settings),
        ))
    } else {
        tracing::info!("VNC server disabled in settings");
        None
    };
    let mut transfer_handle = if settings.network.enable_transfer_server {
        Some(spawn_transfer_server(
            &runtime,
            transfer_server_config_from_settings(&settings, Some(incoming_prompt_config.clone())),
            Arc::clone(&transfer_engine),
            Arc::clone(&transfer_keys),
        ))
    } else {
        tracing::info!("File transfer server disabled in settings");
        None
    };

    runtime.spawn(async move {
        let mut last_name = settings.device.name.clone();
        let mut last_caps = settings.device.capabilities.clone();
        let mut last_autostart = settings.device.start_on_login;
        let mut last_tray_visible = settings.device.show_tray_icon;
        let mut last_network = settings.network.clone();
        let mut last_remote = settings.remote_desktop.clone();
        let mut last_vnc_client_config = vnc_client_config_from_settings(&settings);
        let mut last_encoder_config = encoder_config_from_settings(&settings);
        let mut last_capture_config = capture_config_from_settings(&settings);
        let mut last_transfer_config = transfer_config_from_settings(&settings);
        let mut last_transfer_dir = settings.transfer.save_location.clone();

        loop {
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            let settings = AppSettings::load();
            let name = settings.device.name.clone();
            let caps = settings.device.capabilities.clone();
            let mut discovery = discovery_updates.lock().await;

            if settings.device.start_on_login != last_autostart {
                if let Err(err) =
                    autostart_linux::set_autostart_enabled(settings.device.start_on_login)
                {
                    tracing::warn!("Failed to update autostart setting: {}", err);
                }
                last_autostart = settings.device.start_on_login;
            }

            if settings.device.show_tray_icon != last_tray_visible {
                let handle = { tray_handle.lock().await.clone() };
                if let Some(handle) = handle {
                    let visible = settings.device.show_tray_icon;
                    let _ = handle.update(|tray| tray.set_visible(visible)).await;
                }
                last_tray_visible = settings.device.show_tray_icon;
            }

            let mut name_changed = false;
            if !name.is_empty() && name != last_name {
                let _ = discovery.set_device_name(name.clone());
                last_name = name;
                name_changed = true;
            }
            if caps != last_caps {
                let _ = discovery.set_capabilities(caps.clone());
                last_caps = caps;
            }

            let config_changed = settings.network.enable_mdns != last_network.enable_mdns
                || settings.network.enable_bluetooth != last_network.enable_bluetooth
                || settings.network.enable_wifi_direct != last_network.enable_wifi_direct
                || settings.network.prefer_ipv6 != last_network.prefer_ipv6
                || settings.network.discovery_timeout_secs != last_network.discovery_timeout_secs
                || settings.network.enable_remote_control_server
                    != last_network.enable_remote_control_server
                || settings.network.remote_control_port != last_network.remote_control_port
                || settings.network.enable_vnc_server != last_network.enable_vnc_server
                || settings.network.vnc_port != last_network.vnc_port
                || settings.network.enable_transfer_server != last_network.enable_transfer_server
                || settings.network.transfer_port != last_network.transfer_port;

            if config_changed {
                let config = DiscoveryConfig {
                    enable_mdns: settings.network.enable_mdns,
                    enable_bluetooth: settings.network.enable_bluetooth,
                    enable_wifi_direct: settings.network.enable_wifi_direct,
                    discovery_timeout_secs: settings.network.discovery_timeout_secs,
                    prefer_ipv6: settings.network.prefer_ipv6,
                    remote_port: if settings.network.enable_remote_control_server {
                        Some(settings.network.remote_control_port)
                    } else {
                        None
                    },
                    transfer_port: if settings.network.enable_transfer_server {
                        Some(settings.network.transfer_port)
                    } else {
                        None
                    },
                };
                discovery.set_config(config);
            }

            if settings.network.enable_remote_control_server {
                let needs_restart = !last_network.enable_remote_control_server
                    || settings.network.remote_control_port != last_network.remote_control_port
                    || settings.remote_desktop.framerate != last_remote.framerate
                    || settings.remote_desktop.show_cursor != last_remote.show_cursor
                    || settings.remote_desktop.allow_control != last_remote.allow_control
                    || name_changed;
                if needs_restart {
                    if let Some(handle) = remote_control_handle.take() {
                        handle.abort();
                    }
                    remote_control_handle = Some(spawn_mac_remote_control_server(
                        &runtime_updates,
                        mac_remote_server_config_from_settings(&settings),
                    ));
                }
            } else if last_network.enable_remote_control_server
                && let Some(handle) = remote_control_handle.take()
            {
                handle.abort();
            }

            if settings.network.enable_vnc_server {
                let needs_restart = !last_network.enable_vnc_server
                    || settings.network.vnc_port != last_network.vnc_port
                    || settings.remote_desktop.framerate != last_remote.framerate
                    || settings.remote_desktop.show_cursor != last_remote.show_cursor
                    || settings.remote_desktop.allow_control != last_remote.allow_control
                    || name_changed;
                if needs_restart {
                    if let Some(handle) = vnc_handle.take() {
                        handle.abort();
                    }
                    vnc_handle = Some(spawn_vnc_server(
                        &runtime_updates,
                        vnc_server_config_from_settings(&settings),
                    ));
                }
            } else if last_network.enable_vnc_server
                && let Some(handle) = vnc_handle.take()
            {
                handle.abort();
            }

            if settings.network.enable_transfer_server {
                let needs_restart = !last_network.enable_transfer_server
                    || settings.network.transfer_port != last_network.transfer_port
                    || settings.transfer.save_location != last_transfer_dir;
                if needs_restart {
                    if let Some(handle) = transfer_handle.take() {
                        handle.abort();
                    }
                    transfer_handle = Some(spawn_transfer_server(
                        &runtime_updates,
                        transfer_server_config_from_settings(
                            &settings,
                            Some(incoming_prompt_config.clone()),
                        ),
                        Arc::clone(&transfer_engine_updates),
                        Arc::clone(&transfer_keys_updates),
                    ));
                }
            } else if last_network.enable_transfer_server
                && let Some(handle) = transfer_handle.take()
            {
                handle.abort();
            }

            let transfer_config = transfer_config_from_settings(&settings);
            if transfer_config != last_transfer_config {
                transfer_engine_updates.set_config(transfer_config.clone());
                last_transfer_config = transfer_config;
            }

            let vnc_client_config = vnc_client_config_from_settings(&settings);
            if vnc_client_config != last_vnc_client_config {
                remote_updates
                    .update_default_config(vnc_client_config.clone())
                    .await;
                last_vnc_client_config = vnc_client_config;
            }

            let encoder_config = encoder_config_from_settings(&settings);
            let capture_config = capture_config_from_settings(&settings);
            if encoder_config != last_encoder_config || capture_config != last_capture_config {
                remote_updates
                    .update_streaming_config(encoder_config.clone(), capture_config.clone())
                    .await;
                last_encoder_config = encoder_config;
                last_capture_config = capture_config;
            }

            if settings.network.quic_port != last_network.quic_port {
                tracing::info!("QUIC port change will apply after restart");
            }

            last_network = settings.network.clone();
            last_remote = settings.remote_desktop.clone();
            last_transfer_dir = settings.transfer.save_location.clone();
        }
    });

    let _transfer_engine = transfer_engine;
    let _transfer_keys = transfer_keys;

    // Initialize remote desktop
    let _remote = remote_manager;

    if let Err(err) = p2p_manager.start() {
        tracing::error!("Failed to start P2P manager: {}", err);
    }

    info!("Services initialized successfully");
}
