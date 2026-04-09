#![cfg(feature = "webrtc")]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use chrono::Utc;
use reqwest::header::{ACCEPT, HeaderMap, HeaderValue};
use rustls::crypto::CryptoProvider;
use serde::Deserialize;
use serde::Serialize;
use skybridge_core::auth::{AuthSession, AuthenticationService};
use skybridge_core::crypto::signature::SignatureAlgorithm;
use skybridge_core::crypto::suite::CryptoSuiteId;
use skybridge_core::p2p::{
    AppMessage, ConnectionTrustPolicy, HandshakePolicy, KemPublicKeyInfo, LocalIdentity,
    LocalIdentityStore, PairingIdentityExchangePayload, SwiftDateSeconds,
};
use skybridge_core::remote::supported_remote_video_formats;
use skybridge_core::webrtc::{
    CrossNetworkEvent, CrossNetworkFileTransferMessage, CrossNetworkFileTransferOp, IceConfig,
    ProtocolIdentityBinding, SignalingControlClient, WebRtcCrossNetworkHandle,
    WebRtcCrossNetworkManager, WebRtcSignalingClientConfig, WebRtcStartParams,
    preferred_turn_uri_for_webrtc_rs, should_initiate_pqc_rekey,
};
use tokio::io::{AsyncSeekExt, AsyncWriteExt};
use tokio::sync::mpsc;
use tracing::{info, warn};
use url::Url;

#[derive(Debug)]
struct Config {
    code: String,
    output_dir: PathBuf,
    signaling_ws_url: String,
    signaling_http_url: String,
    client_api_key: String,
    device_id: String,
    device_name: String,
    timeout_seconds: u64,
    require_pqc: bool,
    classic_only: bool,
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

#[derive(Debug)]
struct ReceiveState {
    transfer_id: String,
    file_name: String,
    file_size: i64,
    chunk_size: i32,
    total_chunks: i32,
    temp_path: PathBuf,
    final_path: PathBuf,
    file: tokio::fs::File,
    received_bytes: i64,
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
    let _ = config.require_pqc;
    tokio::fs::create_dir_all(&config.output_dir)
        .await
        .with_context(|| format!("create output dir {}", config.output_dir.display()))?;

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

    let deadline = Instant::now() + Duration::from_secs(config.timeout_seconds);
    let mut inbound: HashMap<String, ReceiveState> = HashMap::new();
    let mut sent_pairing = false;

    while Instant::now() < deadline {
        let timeout = deadline.saturating_duration_since(Instant::now());
        let next_evt = tokio::time::timeout(timeout, evt_rx.recv()).await?;
        let Some(evt) = next_evt else {
            bail!("event channel closed");
        };

        match evt {
            CrossNetworkEvent::TransportReady { session_id } => {
                info!("transport ready session={}", session_id);
            }
            CrossNetworkEvent::PeerHintResolved {
                session_id,
                peer_device_id,
                expected_peer_fingerprint,
            } => {
                info!(
                    "peer hint resolved session={} peer={} fingerprint={}",
                    session_id,
                    peer_device_id,
                    expected_peer_fingerprint.unwrap_or_else(|| "-".to_string())
                );
            }
            CrossNetworkEvent::HandshakeEstablished {
                session_id,
                peer_device_id,
            } => {
                info!(
                    "handshake established session={} peer={}",
                    session_id,
                    peer_device_id.unwrap_or_else(|| "-".to_string())
                );
                if !sent_pairing {
                    send_json(
                        handle.as_ref(),
                        &build_pairing_identity_exchange(&identity, &config.device_name),
                    )
                    .await?;
                    sent_pairing = true;
                }
            }
            CrossNetworkEvent::Status {
                session_id,
                message,
            } => {
                info!("status session={} {}", session_id, message);
            }
            CrossNetworkEvent::Failed { session_id, error } => {
                bail!("webrtc failed session={} error={}", session_id, error);
            }
            CrossNetworkEvent::AppPayload { session_id, data } => {
                if let Ok(app_msg) = serde_json::from_slice::<AppMessage>(&data) {
                    if let AppMessage::PairingIdentityExchange(payload) = app_msg {
                        if !sent_pairing {
                            send_json(
                                handle.as_ref(),
                                &build_pairing_identity_exchange(&identity, &config.device_name),
                            )
                            .await?;
                            sent_pairing = true;
                        }
                        maybe_start_outbound_pqc_rekey(handle.as_ref(), &identity, &payload).await;
                    }
                    continue;
                }

                let msg: CrossNetworkFileTransferMessage = match serde_json::from_slice(&data) {
                    Ok(msg) => msg,
                    Err(err) => {
                        warn!(
                            "ignoring non-file payload for session {}: {}",
                            session_id, err
                        );
                        continue;
                    }
                };

                match msg.op {
                    CrossNetworkFileTransferOp::Metadata => {
                        let file_name = sanitize_filename(
                            msg.file_name
                                .as_deref()
                                .ok_or_else(|| anyhow!("missing file_name"))?,
                        );
                        let file_size =
                            msg.file_size.ok_or_else(|| anyhow!("missing file_size"))?;
                        let chunk_size = msg.chunk_size.unwrap_or(64 * 1024);
                        let total_chunks = msg.total_chunks.unwrap_or(0);
                        let transfer_id = msg.transfer_id.clone();
                        let final_path = unique_destination(&config.output_dir, &file_name);
                        let temp_path = final_path.with_extension("part");
                        let file = tokio::fs::File::create(&temp_path)
                            .await
                            .with_context(|| format!("create temp file {}", temp_path.display()))?;
                        inbound.insert(
                            transfer_id.clone(),
                            ReceiveState {
                                transfer_id: transfer_id.clone(),
                                file_name: file_name.clone(),
                                file_size,
                                chunk_size,
                                total_chunks,
                                temp_path,
                                final_path,
                                file,
                                received_bytes: 0,
                            },
                        );

                        let ack = CrossNetworkFileTransferMessage::new(
                            CrossNetworkFileTransferOp::MetadataAck,
                            transfer_id,
                        );
                        send_json(handle.as_ref(), &ack).await?;
                        info!("metadata accepted file={} size={}", file_name, file_size);
                    }
                    CrossNetworkFileTransferOp::Chunk => {
                        let idx = msg
                            .chunk_index
                            .ok_or_else(|| anyhow!("missing chunk_index"))?;
                        let data = msg
                            .chunk_data
                            .ok_or_else(|| anyhow!("missing chunk_data"))?;
                        let raw_size = msg.raw_size.unwrap_or(data.len() as i32).max(0) as i64;
                        let Some(state) = inbound.get_mut(&msg.transfer_id) else {
                            warn!("chunk for unknown transfer {}", msg.transfer_id);
                            continue;
                        };
                        let offset = (idx as i64) * (state.chunk_size as i64);
                        state
                            .file
                            .seek(std::io::SeekFrom::Start(offset.max(0) as u64))
                            .await?;
                        state.file.write_all(&data).await?;
                        state.received_bytes = state
                            .received_bytes
                            .max(offset + raw_size)
                            .min(state.file_size);
                        let mut ack = CrossNetworkFileTransferMessage::new(
                            CrossNetworkFileTransferOp::ChunkAck,
                            state.transfer_id.clone(),
                        );
                        ack.chunk_index = Some(idx);
                        ack.received_bytes = Some(state.received_bytes);
                        send_json(handle.as_ref(), &ack).await?;
                    }
                    CrossNetworkFileTransferOp::Complete => {
                        let Some(state) = inbound.remove(&msg.transfer_id) else {
                            warn!("complete for unknown transfer {}", msg.transfer_id);
                            continue;
                        };
                        state.file.sync_all().await?;
                        drop(state.file);
                        if let Err(rename_err) =
                            tokio::fs::rename(&state.temp_path, &state.final_path).await
                        {
                            warn!(
                                "rename fallback for {} after error: {}",
                                state.final_path.display(),
                                rename_err
                            );
                            let bytes = tokio::fs::read(&state.temp_path).await?;
                            tokio::fs::write(&state.final_path, bytes).await?;
                            tokio::fs::remove_file(&state.temp_path).await?;
                        }
                        let ack = CrossNetworkFileTransferMessage::new(
                            CrossNetworkFileTransferOp::CompleteAck,
                            state.transfer_id.clone(),
                        );
                        send_json(handle.as_ref(), &ack).await?;
                        info!(
                            "receive complete file={} path={} bytes={} chunks={}",
                            state.file_name,
                            state.final_path.display(),
                            state.received_bytes,
                            state.total_chunks
                        );
                        println!("RECEIVED_FILE={}", state.final_path.display());
                        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                        handle.close().await.ok();
                        return Ok(());
                    }
                    CrossNetworkFileTransferOp::Cancel => {
                        warn!("transfer cancelled id={}", msg.transfer_id);
                    }
                    CrossNetworkFileTransferOp::Error => {
                        bail!(
                            "sender reported error transfer={} message={}",
                            msg.transfer_id,
                            msg.message.unwrap_or_else(|| "-".to_string())
                        );
                    }
                    CrossNetworkFileTransferOp::MetadataAck
                    | CrossNetworkFileTransferOp::ChunkAck
                    | CrossNetworkFileTransferOp::CompleteAck => {}
                }
            }
        }
    }

    bail!("timeout waiting for transfer");
}

fn parse_args() -> Result<Config> {
    let mut code = None::<String>;
    let mut output_dir = None::<PathBuf>;
    let mut signaling_ws_url = std::env::var("SKYBRIDGE_SIGNALING_WEBSOCKET_URL")
        .unwrap_or_else(|_| "wss://api.nebula-technologies.net/ws".to_string());
    let mut signaling_http_url = std::env::var("SKYBRIDGE_SIGNALING_SERVER_URL")
        .unwrap_or_else(|_| "https://api.nebula-technologies.net".to_string());
    let mut client_api_key = std::env::var("SKYBRIDGE_CLIENT_API_KEY")
        .unwrap_or_else(|_| "skybridge-client-v1".to_string());
    let mut device_id = std::env::var("SKYBRIDGE_DEVICE_ID")
        .unwrap_or_else(|_| format!("ubuntu-smoke-{}", Utc::now().timestamp()));
    let mut device_name =
        std::env::var("SKYBRIDGE_DEVICE_NAME").unwrap_or_else(|_| "Ubuntu Smoke".to_string());
    let mut timeout_seconds = 180u64;
    let mut require_pqc = false;
    let mut classic_only = false;
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
            "--output-dir" => output_dir = args.next().map(PathBuf::from),
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
            "--require-pqc" => require_pqc = true,
            "--classic-only" => classic_only = true,
            "--help" | "-h" => {
                println!(
                    "Usage: skybridge-webrtc-file-receiver --code <6-char-code> --output-dir <dir> [--signaling-ws-url <wss://.../ws>] [--signaling-http-url <https://...>] [--client-api-key <key>] [--device-id <id>] [--device-name <name>] [--timeout <seconds>] [--require-pqc|--classic-only]"
                );
                std::process::exit(0);
            }
            other => bail!("unknown arg: {}", other),
        }
    }

    Ok(Config {
        code: code.ok_or_else(|| anyhow!("--code is required"))?,
        output_dir: output_dir.ok_or_else(|| anyhow!("--output-dir is required"))?,
        signaling_ws_url,
        signaling_http_url,
        client_api_key,
        device_id,
        device_name,
        timeout_seconds,
        require_pqc,
        classic_only,
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
) {
    if !identity.supported_suites.iter().any(|suite| suite.is_pqc()) {
        return;
    }
    if payload.kem_public_keys.is_empty() {
        return;
    }

    let Some(should_initiate) = should_initiate_pqc_rekey(
        Some(identity.device_id.as_str()),
        Some(payload.device_id.as_str()),
    ) else {
        info!(
            "pqc rekey waiting for stable initiator election peer={}",
            payload.device_id
        );
        return;
    };

    if !should_initiate {
        info!(
            "pqc rekey elected peer as initiator; waiting inbound peer={}",
            payload.device_id
        );
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

    match handle
        .start_outbound_pqc_rekey(Some(payload.device_id.clone()), peer_kem_keys)
        .await
    {
        Ok(true) => info!("outbound PQC rekey started peer={}", payload.device_id),
        Ok(false) => {}
        Err(err) => warn!(
            "outbound PQC rekey start failed, preserving session peer={} err={}",
            payload.device_id, err
        ),
    }
}

fn build_pairing_identity_exchange(identity: &LocalIdentity, device_name: &str) -> AppMessage {
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
        model_name: Some("Ubuntu Smoke".to_string()),
        platform: Some("Ubuntu".to_string()),
        os_version: None,
        chip: None,
        remote_video_formats: Some(supported_remote_video_formats()),
        sent_at: SwiftDateSeconds::now(),
    })
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

fn sanitize_filename(name: &str) -> String {
    let base = Path::new(name)
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

fn unique_destination(base_dir: &Path, file_name: &str) -> PathBuf {
    let target = base_dir.join(file_name);
    if !target.exists() {
        return target;
    }
    let stem = target
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("file");
    let ext = target.extension().and_then(|s| s.to_str()).unwrap_or("");
    for idx in 1..10_000 {
        let candidate_name = if ext.is_empty() {
            format!("{stem}-{idx}")
        } else {
            format!("{stem}-{idx}.{ext}")
        };
        let candidate = base_dir.join(candidate_name);
        if !candidate.exists() {
            return candidate;
        }
    }
    base_dir.join(format!("{}-{}.bin", stem, Utc::now().timestamp()))
}
