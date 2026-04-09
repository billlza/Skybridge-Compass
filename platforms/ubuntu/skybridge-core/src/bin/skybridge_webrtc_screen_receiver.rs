#![cfg(feature = "webrtc")]

use std::io::Cursor;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use chrono::Utc;
use reqwest::header::{ACCEPT, HeaderMap, HeaderValue};
use rustls::crypto::CryptoProvider;
use serde::Deserialize;
use serde::Serialize;
use sha2::{Digest, Sha256};
use skybridge_core::auth::{AuthSession, AuthenticationService};
use skybridge_core::crypto::signature::SignatureAlgorithm;
use skybridge_core::crypto::suite::CryptoSuiteId;
use skybridge_core::p2p::{
    AppMessage, ConnectionTrustPolicy, HandshakePolicy, HeartbeatPayload, KemPublicKeyInfo,
    LocalIdentity, LocalIdentityStore, PairingIdentityExchangePayload, SwiftDateSeconds,
};
use skybridge_core::remote::{
    AutoDecoder, UltraStreamCodec, UltraStreamDecodedFrame, UltraStreamDecoder, UltraStreamFrame,
    supported_remote_video_formats,
};
use skybridge_core::webrtc::{
    CrossNetworkEvent, IceConfig, ProtocolIdentityBinding, RemoteMessageTypeWire,
    RemoteMessageWire, ScreenDataWire, SignalingControlClient, WebRtcCrossNetworkHandle,
    WebRtcCrossNetworkManager, WebRtcSignalingClientConfig, WebRtcStartParams,
    preferred_turn_uri_for_webrtc_rs, should_initiate_pqc_rekey,
};
use tokio::sync::mpsc;
use tokio::time::{Instant, interval};
use tracing::{info, warn};
use url::Url;

#[derive(Debug)]
struct Config {
    code: String,
    signaling_ws_url: String,
    signaling_http_url: String,
    client_api_key: String,
    device_id: String,
    device_name: String,
    timeout_seconds: u64,
    require_pqc: bool,
    classic_only: bool,
    status_file: Option<PathBuf>,
    min_decoded_frames: u64,
    bearer_token: Option<String>,
    tenant_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TurnCredentialsResponse {
    username: String,
    password: String,
    #[serde(rename = "ttl")]
    _ttl: i32,
    uris: Option<Vec<String>>,
}

struct StatusReporter {
    status_file: Option<PathBuf>,
}

impl StatusReporter {
    fn new(status_file: Option<PathBuf>) -> Self {
        Self { status_file }
    }

    fn reset(&self) {
        if let Some(path) = &self.status_file {
            let _ = std::fs::create_dir_all(
                path.parent()
                    .map(PathBuf::from)
                    .unwrap_or_else(|| PathBuf::from(".")),
            );
            let _ = std::fs::write(path, "");
        }
    }

    fn append(&self, line: impl AsRef<str>) {
        let rendered = format!(
            "[{}] {}\n",
            chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            line.as_ref()
        );
        info!("{}", line.as_ref());
        if let Some(path) = &self.status_file {
            let _ = std::fs::create_dir_all(
                path.parent()
                    .map(PathBuf::from)
                    .unwrap_or_else(|| PathBuf::from(".")),
            );
            use std::io::Write;
            if let Ok(mut file) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
            {
                let _ = file.write_all(rendered.as_bytes());
            }
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = CryptoProvider::install_default(rustls::crypto::aws_lc_rs::default_provider());
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_target(false)
        .compact()
        .init();

    let config = parse_args()?;
    let reporter = StatusReporter::new(config.status_file.clone());
    reporter.reset();
    reporter.append("boot role=linux-screen-receiver");

    let suites = if config.classic_only {
        CryptoSuiteId::classic()
    } else {
        CryptoSuiteId::all()
    };
    let identity =
        LocalIdentityStore::load_or_generate(suites).context("load_or_generate local identity")?;
    let device_id = if config.device_id.trim().is_empty() {
        identity.device_id.clone()
    } else {
        config.device_id.clone()
    };

    let protocol_public_key = identity
        .signing_public_key(SignatureAlgorithm::Ed25519)
        .ok_or_else(|| anyhow!("missing Ed25519 signaling public key"))?;
    let binding = ProtocolIdentityBinding::new(
        device_id.clone(),
        SignatureAlgorithm::Ed25519,
        protocol_public_key,
    );
    let control = SignalingControlClient::new(
        config.signaling_http_url.clone(),
        (!config.client_api_key.trim().is_empty()).then(|| config.client_api_key.clone()),
    )
    .with_user_auth(config.bearer_token.clone(), config.tenant_id.clone());
    let lookup = control
        .lookup_connection_code(&config.code, &binding, &identity)
        .await
        .context("lookup_connection_code")?;
    let signaling_cfg = WebRtcSignalingClientConfig {
        url: signaling_url_with_shard(
            &config.signaling_ws_url,
            &lookup.session_id,
            Some(&lookup.responder_token),
        )?,
    };
    let ice = fetch_ice_config(&config, Some(&lookup.turn_admission_token))
        .await
        .unwrap_or_else(|err| {
            warn!("TURN fetch failed, falling back to STUN-only: {}", err);
            IceConfig {
                stun_url: "stun:54.92.79.99:3478".to_string(),
                turn_url: String::new(),
                turn_username: String::new(),
                turn_password: String::new(),
                relay_only: false,
            }
        });

    let mut manager = WebRtcCrossNetworkManager::new();
    let (evt_tx, mut evt_rx) = mpsc::unbounded_channel::<CrossNetworkEvent>();
    manager.on_event(move |evt| {
        let _ = evt_tx.send(evt);
    });

    let mut policy = HandshakePolicy::default_policy();
    if config.classic_only {
        policy.require_pqc = false;
        policy.allow_classic_fallback = true;
    }

    let handle = Arc::new(
        manager
            .start_answerer(WebRtcStartParams {
                session_id: lookup.session_id.clone(),
                local_device_id: device_id.clone(),
                signaling_cfg,
                signaling_auth_token: Some(lookup.responder_token.clone()),
                signaling_server_origin: Some(lookup.signaling_server_origin.clone()),
                ice,
                identity: identity.clone(),
                policy,
                trust_policy: ConnectionTrustPolicy::default(),
                peer_device_id_hint: Some(lookup.initiator_device_id.clone()),
                expected_peer_fingerprint: Some(
                    lookup.initiator_protocol_public_key_fingerprint.clone(),
                ),
                current_path_remote_authority: lookup.remote_authority(),
            })
            .await
            .context("start_answerer")?,
    );

    let local_formats = supported_remote_video_formats();
    reporter.append(format!("local-formats {}", local_formats.join(",")));

    let deadline = Instant::now() + Duration::from_secs(config.timeout_seconds);
    let mut heartbeat = interval(Duration::from_secs(2));
    heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    let mut sent_pairing = false;
    let mut frames_total: u64 = 0;
    let mut frames_decoded: u64 = 0;
    let mut app_payloads_seen: u64 = 0;
    let mut remote_messages_seen: u64 = 0;
    let mut last_format = String::new();
    let mut window_frames: u64 = 0;
    let mut window_start = Instant::now();
    let mut decoder = AutoDecoder::new().ok();

    loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => {
                bail!("timeout waiting for WebRTC screen frames");
            }
            _ = heartbeat.tick() => {
                let hb = AppMessage::Heartbeat(HeartbeatPayload {
                    sent_at: SwiftDateSeconds::now(),
                    device_id: Some(identity.device_id.clone()),
                    device_name: Some(config.device_name.clone()),
                    model_name: Some("Ubuntu Smoke".to_string()),
                    platform: Some("Ubuntu".to_string()),
                    os_version: None,
                    chip: None,
                    remote_video_formats: Some(local_formats.clone()),
                });
                send_json(handle.as_ref(), &hb).await?;
                reporter.append(format!(
                    "heartbeat-sent formats={}",
                    local_formats.join(",")
                ));
            }
            maybe_evt = evt_rx.recv() => {
                let Some(evt) = maybe_evt else {
                    bail!("event channel closed");
                };

                match evt {
                    CrossNetworkEvent::TransportReady { session_id } => {
                        reporter.append(format!("transport-ready session={}", session_id));
                    }
                    CrossNetworkEvent::PeerHintResolved {
                        session_id,
                        peer_device_id,
                        expected_peer_fingerprint,
                    } => {
                        reporter.append(format!(
                            "peer-hint session={} peer={} fingerprint={}",
                            session_id,
                            peer_device_id,
                            expected_peer_fingerprint.unwrap_or_else(|| "-".to_string())
                        ));
                    }
                    CrossNetworkEvent::HandshakeEstablished {
                        session_id,
                        peer_device_id,
                    } => {
                        let negotiated_suite = handle.negotiated_suite().await;
                        let suite = negotiated_suite
                            .map(|suite| format!("{:?}", suite))
                            .unwrap_or_else(|| "unknown".to_string());
                        reporter.append(format!(
                            "handshake session={} peer={} suite={}",
                            session_id,
                            peer_device_id.unwrap_or_else(|| "-".to_string()),
                            suite
                        ));
                        if !sent_pairing {
                            send_json(
                                handle.as_ref(),
                                &build_pairing_identity_exchange(&identity, &config.device_name, &local_formats),
                            )
                            .await?;
                            sent_pairing = true;
                        }

                        if frames_decoded >= config.min_decoded_frames
                            && (!config.require_pqc
                                || negotiated_suite.is_some_and(|suite| suite.is_pqc()))
                        {
                            reporter.append(format!(
                                "success session={} frames={} decoded={} format={}",
                                session_id,
                                frames_total,
                                frames_decoded,
                                last_format
                            ));
                            return Ok(());
                        }
                    }
                    CrossNetworkEvent::Status { session_id, message } => {
                        reporter.append(format!("status session={} {}", session_id, message));
                    }
                    CrossNetworkEvent::Failed { session_id, error } => {
                        bail!("webrtc failed session={} error={}", session_id, error);
                    }
                    CrossNetworkEvent::AppPayload { session_id, data } => {
                        app_payloads_seen += 1;
                        if app_payloads_seen <= 5 {
                            reporter.append(format!(
                                "app-payload session={} bytes={}",
                                session_id,
                                data.len()
                            ));
                        }
                        if let Ok(app_msg) = serde_json::from_slice::<AppMessage>(&data) {
                            match app_msg {
                                AppMessage::PairingIdentityExchange(payload) => {
                                    if payload.device_id.trim().is_empty() {
                                        reporter.append(format!(
                                            "peer-pairing-missing-device-id session={}",
                                            session_id
                                        ));
                                    }
                                    if let Some(remote_formats) = payload.remote_video_formats.as_ref() {
                                        reporter.append(format!(
                                            "peer-formats session={} formats={}",
                                            session_id,
                                            remote_formats.join(",")
                                        ));
                                    }
                                    if !sent_pairing {
                                        send_json(
                                            handle.as_ref(),
                                            &build_pairing_identity_exchange(&identity, &config.device_name, &local_formats),
                                        )
                                        .await?;
                                        sent_pairing = true;
                                    }
                                    maybe_start_outbound_pqc_rekey(
                                        handle.as_ref(),
                                        &identity,
                                        &payload,
                                        &reporter,
                                    )
                                    .await;
                                }
                                AppMessage::Heartbeat(payload) => {
                                    if let Some(remote_formats) = payload.remote_video_formats.as_ref() {
                                        reporter.append(format!(
                                            "peer-heartbeat session={} formats={}",
                                            session_id,
                                            remote_formats.join(",")
                                        ));
                                    }
                                }
                                _ => {}
                            }
                            continue;
                        }

                        let msg: RemoteMessageWire = match serde_json::from_slice(&data) {
                            Ok(msg) => msg,
                            Err(err) => {
                                warn!(
                                    "ignoring non-remote payload for session {}: {}",
                                    session_id, err
                                );
                                continue;
                            }
                        };

                        remote_messages_seen += 1;
                        if remote_messages_seen <= 10 {
                            reporter.append(format!(
                                "remote-message session={} type={:?} bytes={}",
                                session_id,
                                msg.msg_type,
                                data.len()
                            ));
                        }

                        if msg.msg_type != RemoteMessageTypeWire::ScreenData {
                            continue;
                        }

                        let screen: ScreenDataWire = match serde_json::from_slice(&msg.payload) {
                            Ok(screen) => screen,
                            Err(err) => {
                                warn!("screenData decode failed for session {}: {}", session_id, err);
                                continue;
                            }
                        };

                        let format = normalized_format(&screen);
                        if format != last_format {
                            reporter.append(format!(
                                "screen-format session={} format={} width={} height={} payload_bytes={}",
                                session_id,
                                format,
                                screen.width,
                                screen.height,
                                screen.image_data.len()
                            ));
                            last_format = format.clone();
                        }

                        frames_total += 1;
                        window_frames += 1;

                        match try_decode_screen_data(&screen, decoder.as_mut()) {
                            Ok(true) => {
                                frames_decoded += 1;
                                if frames_decoded == 1 {
                                    reporter.append(format!(
                                        "decode-ok session={} format={} width={} height={}",
                                        session_id,
                                        format,
                                        screen.width,
                                        screen.height
                                    ));
                                }
                            }
                            Ok(false) => {}
                            Err(err) => {
                                reporter.append(format!(
                                    "decode-failed session={} format={} error={}",
                                    session_id, format, err
                                ));
                            }
                        }

                        let elapsed = window_start.elapsed().as_secs_f64();
                        if elapsed >= 3.0 {
                            reporter.append(format!(
                                "stream-stats session={} frames={} decoded={} fps={:.1} last_format={}",
                                session_id,
                                frames_total,
                                frames_decoded,
                                window_frames as f64 / elapsed,
                                last_format
                            ));
                            window_start = Instant::now();
                            window_frames = 0;
                        }

                        if frames_decoded >= config.min_decoded_frames {
                            if config.require_pqc
                                && !handle
                                    .negotiated_suite()
                                    .await
                                    .is_some_and(|suite| suite.is_pqc())
                            {
                                reporter.append(format!(
                                    "waiting-pqc session={} frames={} decoded={} suite=classic",
                                    session_id,
                                    frames_total,
                                    frames_decoded
                                ));
                                continue;
                            }
                            reporter.append(format!(
                                "success session={} frames={} decoded={} format={}",
                                session_id,
                                frames_total,
                                frames_decoded,
                                last_format
                            ));
                            return Ok(());
                        }
                    }
                }
            }
        }
    }
}

fn parse_args() -> Result<Config> {
    let mut code = None::<String>;
    let mut signaling_ws_url = std::env::var("SKYBRIDGE_SIGNALING_WEBSOCKET_URL")
        .unwrap_or_else(|_| "wss://api.nebula-technologies.net/ws".to_string());
    let mut signaling_http_url = std::env::var("SKYBRIDGE_SIGNALING_SERVER_URL")
        .unwrap_or_else(|_| "https://api.nebula-technologies.net".to_string());
    let mut client_api_key = std::env::var("SKYBRIDGE_CLIENT_API_KEY")
        .unwrap_or_else(|_| "skybridge-client-v1".to_string());
    let mut device_id = std::env::var("SKYBRIDGE_DEVICE_ID")
        .unwrap_or_else(|_| format!("ubuntu-screen-smoke-{}", Utc::now().timestamp()));
    let mut device_name = std::env::var("SKYBRIDGE_DEVICE_NAME")
        .unwrap_or_else(|_| "Ubuntu Screen Smoke".to_string());
    let mut timeout_seconds = 120u64;
    let mut require_pqc = false;
    let mut classic_only = false;
    let mut status_file = std::env::var("SKYBRIDGE_SMOKE_STATUS_FILE")
        .ok()
        .map(PathBuf::from);
    let mut min_decoded_frames = 20u64;
    let auth_context = persisted_auth_context();
    let mut bearer_token = std::env::var("SKYBRIDGE_BEARER_TOKEN")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .or_else(|| {
            auth_context
                .as_ref()
                .map(|session| session.token.access_token().to_string())
        });
    let mut tenant_id = std::env::var("SKYBRIDGE_TENANT_ID")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .or_else(|| {
            auth_context
                .as_ref()
                .map(|session| session.user.user_id.clone())
        });

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--code" => code = args.next(),
            "--signaling-ws-url" => {
                signaling_ws_url = args
                    .next()
                    .ok_or_else(|| anyhow!("missing value for --signaling-ws-url"))?
            }
            "--signaling-http-url" => {
                signaling_http_url = args
                    .next()
                    .ok_or_else(|| anyhow!("missing value for --signaling-http-url"))?
            }
            "--client-api-key" => {
                client_api_key = args
                    .next()
                    .ok_or_else(|| anyhow!("missing value for --client-api-key"))?
            }
            "--device-id" => {
                device_id = args
                    .next()
                    .ok_or_else(|| anyhow!("missing value for --device-id"))?
            }
            "--device-name" => {
                device_name = args
                    .next()
                    .ok_or_else(|| anyhow!("missing value for --device-name"))?
            }
            "--timeout" => {
                timeout_seconds = args
                    .next()
                    .ok_or_else(|| anyhow!("missing value for --timeout"))?
                    .parse()
                    .context("parse --timeout")?
            }
            "--status-file" => {
                status_file = Some(PathBuf::from(
                    args.next()
                        .ok_or_else(|| anyhow!("missing value for --status-file"))?,
                ))
            }
            "--min-decoded-frames" => {
                min_decoded_frames = args
                    .next()
                    .ok_or_else(|| anyhow!("missing value for --min-decoded-frames"))?
                    .parse()
                    .context("parse --min-decoded-frames")?
            }
            "--require-pqc" => require_pqc = true,
            "--classic-only" => classic_only = true,
            "--help" | "-h" => {
                println!(
                    "Usage: skybridge-webrtc-screen-receiver --code <6-char-code> [--signaling-ws-url <wss://.../ws>] [--signaling-http-url <https://...>] [--client-api-key <key>] [--device-id <id>] [--device-name <name>] [--status-file <path>] [--timeout <seconds>] [--min-decoded-frames <count>] [--require-pqc|--classic-only]"
                );
                std::process::exit(0);
            }
            other => bail!("unknown arg: {}", other),
        }
    }

    Ok(Config {
        code: code.ok_or_else(|| anyhow!("--code is required"))?,
        signaling_ws_url,
        signaling_http_url,
        client_api_key,
        device_id,
        device_name,
        timeout_seconds,
        require_pqc,
        classic_only,
        status_file,
        min_decoded_frames,
        bearer_token: bearer_token.take(),
        tenant_id: tenant_id.take(),
    })
}

fn persisted_auth_context() -> Option<AuthSession> {
    let mut auth = AuthenticationService::new().ok()?;
    auth.load_persisted_session().ok().flatten().cloned()
}

async fn send_json<T: Serialize>(handle: &WebRtcCrossNetworkHandle, value: &T) -> Result<()> {
    let bytes = serde_json::to_vec(value)?;
    handle.send_app_payload(bytes)?;
    Ok(())
}

async fn maybe_start_outbound_pqc_rekey(
    handle: &WebRtcCrossNetworkHandle,
    identity: &LocalIdentity,
    payload: &PairingIdentityExchangePayload,
    reporter: &StatusReporter,
) {
    if !identity.supported_suites.iter().any(|suite| suite.is_pqc()) {
        return;
    }
    if payload.kem_public_keys.is_empty() {
        return;
    }

    let force_rekey = std::env::var("SKYBRIDGE_SMOKE_FORCE_PQC_REKEY")
        .ok()
        .is_some_and(|value| value.trim() == "1");

    let should_initiate = if force_rekey {
        reporter.append(format!("pqc-rekey-force peer={}", payload.device_id));
        true
    } else {
        let Some(should_initiate) = should_initiate_pqc_rekey(
            Some(identity.device_id.as_str()),
            Some(payload.device_id.as_str()),
        ) else {
            reporter.append(format!(
                "pqc-rekey-wait-election peer={}",
                payload.device_id
            ));
            return;
        };
        should_initiate
    };

    if !should_initiate {
        reporter.append(format!(
            "pqc-rekey-await-inbound peer={}",
            payload.device_id
        ));
        return;
    }

    let peer_kem_keys = payload
        .kem_public_keys
        .iter()
        .filter_map(|key| {
            CryptoSuiteId::from_wire_id(key.suite_wire_id)
                .map(|suite| (suite, key.public_key.clone()))
        })
        .collect();
    if std::env::var("SKYBRIDGE_SMOKE_ROLE").is_ok() {
        let mut digests = payload
            .kem_public_keys
            .iter()
            .map(|key| {
                let digest = hex::encode(Sha256::digest(&key.public_key));
                format!("0x{:04x}:{}", key.suite_wire_id, &digest[..16])
            })
            .collect::<Vec<_>>();
        digests.sort();
        println!("🧪 linux peer KEM digests={}", digests.join(","));
    }

    match handle
        .start_outbound_pqc_rekey(Some(payload.device_id.clone()), peer_kem_keys)
        .await
    {
        Ok(true) => reporter.append(format!("pqc-rekey-start peer={}", payload.device_id)),
        Ok(false) => {}
        Err(err) => reporter.append(format!(
            "pqc-rekey-start-failed peer={} error={}",
            payload.device_id, err
        )),
    }
}

fn build_pairing_identity_exchange(
    identity: &LocalIdentity,
    device_name: &str,
    remote_video_formats: &[String],
) -> AppMessage {
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
        device_name: Some(device_name.to_string()),
        model_name: Some("Ubuntu Screen Smoke".to_string()),
        platform: Some("Ubuntu".to_string()),
        os_version: None,
        chip: None,
        remote_video_formats: Some(remote_video_formats.to_vec()),
        sent_at: SwiftDateSeconds::now(),
    })
}

fn normalized_format(screen: &ScreenDataWire) -> String {
    let raw = screen.format.as_deref().unwrap_or("").trim().to_lowercase();
    if raw.is_empty() && looks_like_jpeg(&screen.image_data) {
        "jpeg".to_string()
    } else {
        raw
    }
}

fn looks_like_jpeg(bytes: &[u8]) -> bool {
    bytes.len() >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
}

fn try_decode_screen_data(
    screen: &ScreenDataWire,
    decoder: Option<&mut AutoDecoder>,
) -> Result<bool> {
    if screen.image_data.is_empty() {
        return Ok(false);
    }

    let width = screen.width.max(1).min(i32::from(u16::MAX)) as u16;
    let height = screen.height.max(1).min(i32::from(u16::MAX)) as u16;
    let format = normalized_format(screen);

    match format.as_str() {
        "bgra" => {
            let expected = width as usize * height as usize * 4;
            if screen.image_data.len() != expected {
                bail!(
                    "BGRA payload length mismatch: expected {} got {}",
                    expected,
                    screen.image_data.len()
                );
            }
            Ok(true)
        }
        "h264" | "hevc" => {
            let codec = if format == "h264" {
                UltraStreamCodec::H264
            } else {
                UltraStreamCodec::Hevc
            };
            let Some(decoder) = decoder else {
                bail!("decoder unavailable for {}", format);
            };
            let frame = UltraStreamFrame {
                codec,
                frame_id: 0,
                timestamp_ms: 0,
                width,
                height,
                data: screen.image_data.clone(),
            };
            match decoder
                .decode(&frame)
                .map_err(|err| anyhow!(err.to_string()))?
            {
                UltraStreamDecodedFrame::Bgra { .. } => Ok(true),
                UltraStreamDecodedFrame::Encoded(_) => Ok(false),
            }
        }
        "jpeg" | "image/jpeg" => {
            let mut jpeg = jpeg_decoder::Decoder::new(Cursor::new(&screen.image_data));
            let pixels = jpeg.decode().context("jpeg decode")?;
            let info = jpeg
                .info()
                .ok_or_else(|| anyhow!("jpeg info unavailable after decode"))?;
            if pixels.is_empty() {
                bail!("jpeg decode produced no pixels");
            }
            if info.width != width || info.height != height {
                bail!(
                    "jpeg dimensions mismatch: expected {}x{} got {}x{}",
                    width,
                    height,
                    info.width,
                    info.height
                );
            }
            Ok(true)
        }
        _ => Ok(false),
    }
}

async fn fetch_ice_config(
    config: &Config,
    turn_admission_token: Option<&str>,
) -> Result<IceConfig> {
    let url = Url::parse(&config.signaling_http_url)?.join("/api/turn/credentials")?;
    let mut headers = HeaderMap::new();
    headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
    headers.insert(
        "X-API-Key",
        HeaderValue::from_str(&config.client_api_key).context("invalid client api key header")?,
    );
    headers.insert(
        "X-Device-Id",
        HeaderValue::from_str(&config.device_id).context("invalid device id header")?,
    );
    if let Some(turn_admission_token) = turn_admission_token
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        headers.insert(
            "X-SkyBridge-Turn-Admission",
            HeaderValue::from_str(turn_admission_token).context("invalid turn admission header")?,
        );
    }
    let mut builder = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .default_headers(headers);
    if signaling_targets_loopback(&config.signaling_http_url) {
        builder = builder.no_proxy();
    }
    let client = builder.build()?;
    let response = client.get(url).send().await?;
    let response = response.error_for_status()?;
    let decoded: TurnCredentialsResponse = response.json().await?;
    let available_uris = decoded.uris.unwrap_or_default();
    let turn_url = preferred_turn_uri_for_webrtc_rs(&available_uris).unwrap_or_default();
    if turn_url.is_empty() {
        tracing::warn!(
            uris = ?available_uris,
            "No TURN URI supported by the current Rust WebRTC runtime; continuing with STUN/direct candidates only"
        );
    } else {
        tracing::info!(selected_turn_url = %turn_url, uris = ?available_uris, "Selected TURN URI");
    }
    Ok(IceConfig {
        stun_url: "stun:54.92.79.99:3478".to_string(),
        turn_url,
        turn_username: decoded.username,
        turn_password: decoded.password,
        relay_only: false,
    })
}

fn signaling_targets_loopback(raw: &str) -> bool {
    let Ok(url) = Url::parse(raw) else {
        return false;
    };
    matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "::1"))
}

fn signaling_url_with_shard(
    base: &str,
    session_id: &str,
    session_token: Option<&str>,
) -> Result<Url> {
    let mut url = Url::parse(base)?;
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
    {
        let mut pairs: Vec<(String, String)> = url
            .query_pairs()
            .filter(|(key, _)| key != "shard" && key != "st" && key != "cv" && key != "pv")
            .map(|(key, value)| (key.into_owned(), value.into_owned()))
            .collect();
        pairs.push(("shard".to_string(), session_id.trim().to_string()));
        if let Some(session_token) = session_token
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            pairs.push(("st".to_string(), session_token.to_string()));
        }
        pairs.push(("cv".to_string(), client_version));
        pairs.push(("pv".to_string(), protocol_version));
        let mut query = url.query_pairs_mut();
        query.clear();
        for (key, value) in pairs {
            query.append_pair(&key, &value);
        }
    }
    Ok(url)
}
