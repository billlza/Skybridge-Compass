//! WebRTC cross-network manager (offerer + answerer).
//!
//! Mirrors macOS/iOS behavior:
//! - WebSocket signaling exchanging `WebRtcSignalingEnvelope`
//! - WebRTC DataChannel (binary)
//! - P2P handshake over framed DataChannel bytes (4-byte length prefix)
//! - Application AES-GCM using `SessionKeys` after handshake

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use tokio::sync::mpsc;
use tokio::sync::{Mutex, Notify};
use tokio::task::JoinHandle;
use tracing::debug;

use crate::crypto::suite::CryptoSuiteId;
use crate::p2p::{
    ConnectionTrustPolicy, CrossNetworkChannel, CrossNetworkInbound, HandshakePolicy,
    LocalIdentity, PeerIdentity, TrustStore, encode_frame, enforce_outbound_trust_policy,
};
use crate::webrtc::{
    CurrentPathRemoteAuthority, IceConfig, WebRtcRole, WebRtcSession, WebRtcSignalingClient,
    WebRtcSignalingClientConfig, WebRtcSignalingEnvelope, WebRtcSignalingPayload,
    WebRtcSignalingType, validate_current_path_origin, websocket_url_matches_origin,
};

/// Events emitted by the cross-network manager.
#[derive(Debug, Clone)]
pub enum CrossNetworkEvent {
    TransportReady {
        session_id: String,
    },
    PeerHintResolved {
        session_id: String,
        peer_device_id: String,
        expected_peer_fingerprint: Option<String>,
    },
    HandshakeEstablished {
        session_id: String,
        peer_device_id: Option<String>,
    },
    AppPayload {
        session_id: String,
        data: Vec<u8>,
    },
    Status {
        session_id: String,
        message: String,
    },
    Failed {
        session_id: String,
        error: String,
    },
}

pub type CrossNetworkCallback = Arc<dyn Fn(CrossNetworkEvent) + Send + Sync>;

/// A running cross-network WebRTC session handle.
pub struct WebRtcCrossNetworkHandle {
    pub session_id: String,
    app_send: mpsc::UnboundedSender<Vec<u8>>,
    session: Arc<WebRtcSession>,
    channel: Arc<Mutex<CrossNetworkChannel>>,
    closed: Arc<AtomicBool>,
    _signaling_task: JoinHandle<()>,
    _signaling_driver_task: JoinHandle<()>,
    _inbound_task: JoinHandle<()>,
    _app_sender_task: JoinHandle<()>,
    _join_heartbeat_task: JoinHandle<()>,
    _offer_resend_task: Option<JoinHandle<()>>,
}

/// Cross-network WebRTC manager.
pub struct WebRtcCrossNetworkManager {
    callback: Option<CrossNetworkCallback>,
}

#[derive(Debug, Clone)]
pub struct WebRtcStartParams {
    pub session_id: String,
    pub local_device_id: String,
    pub signaling_cfg: WebRtcSignalingClientConfig,
    pub signaling_auth_token: Option<String>,
    pub signaling_server_origin: Option<String>,
    pub ice: IceConfig,
    pub identity: LocalIdentity,
    pub policy: HandshakePolicy,
    pub trust_policy: ConnectionTrustPolicy,
    pub peer_device_id_hint: Option<String>,
    pub expected_peer_fingerprint: Option<String>,
    pub current_path_remote_authority: Option<CurrentPathRemoteAuthority>,
}

struct StartRequest {
    session_id: String,
    local_device_id: String,
    role: WebRtcRole,
    signaling_cfg: WebRtcSignalingClientConfig,
    signaling_auth_token: Option<String>,
    signaling_server_origin: Option<String>,
    ice: IceConfig,
    identity: LocalIdentity,
    policy: HandshakePolicy,
    trust_policy: ConnectionTrustPolicy,
    peer_device_id_hint: Option<String>,
    expected_peer_fingerprint: Option<String>,
    current_path_remote_authority: Option<CurrentPathRemoteAuthority>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ResolvedPeerHint {
    peer_device_id: String,
    expected_peer_fingerprint: Option<String>,
}

fn summarize_sdp_candidates(sdp: &str) -> String {
    let mut total = 0usize;
    let mut host = 0usize;
    let mut srflx = 0usize;
    let mut relay = 0usize;
    let mut prflx = 0usize;

    for line in sdp.lines() {
        let trimmed = line.trim();
        if !trimmed.starts_with("a=candidate:") {
            continue;
        }
        total += 1;
        if trimmed.contains(" typ host") {
            host += 1;
        } else if trimmed.contains(" typ srflx") {
            srflx += 1;
        } else if trimmed.contains(" typ relay") {
            relay += 1;
        } else if trimmed.contains(" typ prflx") {
            prflx += 1;
        }
    }

    format!(
        "candidates total={} host={} srflx={} relay={} prflx={}",
        total, host, srflx, relay, prflx
    )
}

fn peer_fingerprint_hint(device_id: &str) -> Option<String> {
    TrustStore::load()
        .ok()
        .and_then(|store| store.peer_fingerprint_hint(device_id))
}

async fn apply_peer_hint_to_channel(
    channel: &Arc<Mutex<CrossNetworkChannel>>,
    peer_device_id: &str,
    expected_peer_fingerprint: Option<String>,
) {
    let mut channel = channel.lock().await;
    channel.set_peer_device_id(Some(peer_device_id.to_string()));
    channel.set_expected_peer_fingerprint(expected_peer_fingerprint);
    if let Ok(store) = TrustStore::load() {
        let peer_kem_keys = store.peer_kem_keys(peer_device_id);
        if !peer_kem_keys.is_empty() {
            channel.set_peer_kem_public_keys(peer_kem_keys);
        }
    }
}

async fn maybe_resolve_peer_hint(
    sid: &str,
    local_device_id: &str,
    remote_device_id: &str,
    channel: &Arc<Mutex<CrossNetworkChannel>>,
    resolved_hint: &Arc<Mutex<Option<ResolvedPeerHint>>>,
    callback: &Option<CrossNetworkCallback>,
) {
    let remote_device_id = remote_device_id.trim();
    if remote_device_id.is_empty() || remote_device_id == local_device_id {
        return;
    }

    let updated_hint = ResolvedPeerHint {
        peer_device_id: remote_device_id.to_string(),
        expected_peer_fingerprint: peer_fingerprint_hint(remote_device_id),
    };

    {
        let mut state = resolved_hint.lock().await;
        if state.as_ref() == Some(&updated_hint) {
            return;
        }
        *state = Some(updated_hint.clone());
    }

    apply_peer_hint_to_channel(
        channel,
        remote_device_id,
        updated_hint.expected_peer_fingerprint.clone(),
    )
    .await;

    if let Some(cb) = callback {
        cb(CrossNetworkEvent::PeerHintResolved {
            session_id: sid.to_string(),
            peer_device_id: updated_hint.peer_device_id,
            expected_peer_fingerprint: updated_hint.expected_peer_fingerprint,
        });
    }
}

fn emit_status(
    callback: &Option<CrossNetworkCallback>,
    session_id: &str,
    message: impl Into<String>,
) {
    if let Some(cb) = callback {
        cb(CrossNetworkEvent::Status {
            session_id: session_id.to_string(),
            message: message.into(),
        });
    }
}

pub fn canonical_pqc_rekey_election_device_id(raw: Option<&str>) -> Option<String> {
    let raw = raw?;
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.to_ascii_lowercase().starts_with("webrtc-") {
        return None;
    }
    Some(trimmed.to_ascii_lowercase())
}

pub fn should_initiate_pqc_rekey(
    local_device_id: Option<&str>,
    remote_device_id: Option<&str>,
) -> Option<bool> {
    let local = canonical_pqc_rekey_election_device_id(local_device_id)?;
    let remote = canonical_pqc_rekey_election_device_id(remote_device_id)?;
    if local == remote {
        return None;
    }
    Some(local < remote)
}

impl Default for WebRtcCrossNetworkManager {
    fn default() -> Self {
        Self::new()
    }
}

impl WebRtcCrossNetworkManager {
    pub fn new() -> Self {
        Self { callback: None }
    }

    pub fn on_event<F>(&mut self, cb: F)
    where
        F: Fn(CrossNetworkEvent) + Send + Sync + 'static,
    {
        self.callback = Some(Arc::new(cb));
    }

    pub async fn start_offerer(
        &self,
        params: WebRtcStartParams,
    ) -> Result<WebRtcCrossNetworkHandle, anyhow::Error> {
        let WebRtcStartParams {
            session_id,
            local_device_id,
            signaling_cfg,
            signaling_auth_token,
            signaling_server_origin,
            ice,
            identity,
            policy,
            trust_policy,
            peer_device_id_hint,
            expected_peer_fingerprint,
            current_path_remote_authority,
        } = params;
        self.start(StartRequest {
            session_id,
            local_device_id,
            role: WebRtcRole::Offerer,
            signaling_cfg,
            signaling_auth_token,
            signaling_server_origin,
            ice,
            identity,
            policy,
            trust_policy,
            peer_device_id_hint,
            expected_peer_fingerprint,
            current_path_remote_authority,
        })
        .await
    }

    pub async fn start_answerer(
        &self,
        params: WebRtcStartParams,
    ) -> Result<WebRtcCrossNetworkHandle, anyhow::Error> {
        let WebRtcStartParams {
            session_id,
            local_device_id,
            signaling_cfg,
            signaling_auth_token,
            signaling_server_origin,
            ice,
            identity,
            policy,
            trust_policy,
            peer_device_id_hint,
            expected_peer_fingerprint,
            current_path_remote_authority,
        } = params;
        self.start(StartRequest {
            session_id,
            local_device_id,
            role: WebRtcRole::Answerer,
            signaling_cfg,
            signaling_auth_token,
            signaling_server_origin,
            ice,
            identity,
            policy,
            trust_policy,
            peer_device_id_hint,
            expected_peer_fingerprint,
            current_path_remote_authority,
        })
        .await
    }

    async fn start(&self, req: StartRequest) -> Result<WebRtcCrossNetworkHandle, anyhow::Error> {
        let StartRequest {
            session_id,
            local_device_id,
            role,
            signaling_cfg,
            signaling_auth_token,
            signaling_server_origin,
            ice,
            identity,
            policy,
            trust_policy,
            peer_device_id_hint,
            expected_peer_fingerprint,
            current_path_remote_authority,
        } = req;
        if let Some(expected_origin) = signaling_server_origin.as_deref() {
            let _ = validate_current_path_origin(expected_origin)
                .map_err(|err| anyhow::anyhow!("{}", err))?;
            if !websocket_url_matches_origin(&signaling_cfg.url, expected_origin)
                .map_err(|err| anyhow::anyhow!("{}", err))?
            {
                return Err(anyhow::anyhow!(
                    "signaling websocket origin does not match validated control-plane origin"
                ));
            }
        }
        let signaling_auth_token = signaling_auth_token
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());
        let authority_peer_device_id = current_path_remote_authority
            .as_ref()
            .map(|authority| authority.device_id.clone());
        let authority_peer_fingerprint = current_path_remote_authority
            .as_ref()
            .map(|authority| authority.protocol_public_key_fingerprint.clone());
        let peer_device_id_hint = peer_device_id_hint.or_else(|| authority_peer_device_id.clone());
        let expected_peer_fingerprint = expected_peer_fingerprint.or_else(|| {
            authority_peer_fingerprint.clone().or_else(|| {
                peer_device_id_hint
                    .as_deref()
                    .and_then(peer_fingerprint_hint)
            })
        });
        emit_status(
            &self.callback,
            &session_id,
            format!("WebRTC starting ({:?})", role),
        );

        if role == WebRtcRole::Answerer
            && (peer_device_id_hint.is_some() || expected_peer_fingerprint.is_some())
        {
            enforce_outbound_trust_policy(
                trust_policy,
                peer_device_id_hint.as_deref(),
                expected_peer_fingerprint.as_deref(),
            )?;
        }

        // Signaling
        let signaling = WebRtcSignalingClient::connect(signaling_cfg).await?;
        let (sig_tx, mut sig_rx, sig_task) = signaling.split();

        // WebRTC session
        let session = Arc::new(
            WebRtcSession::new(session_id.clone(), local_device_id.clone(), role, ice)
                .await
                .map_err(|e| anyhow::anyhow!("{}", e))?,
        );

        // Cross-network channel:
        // - Offerer acts as responder (waits for MessageA)
        // - Answerer acts as initiator (sends MessageA once ready)
        let channel = match role {
            WebRtcRole::Offerer => CrossNetworkChannel::new_responder(identity, policy),
            WebRtcRole::Answerer => CrossNetworkChannel::new_initiator(identity, policy),
        };
        let channel = Arc::new(Mutex::new(channel));
        if let Some(peer_device_id) = peer_device_id_hint.as_deref() {
            apply_peer_hint_to_channel(&channel, peer_device_id, expected_peer_fingerprint.clone())
                .await;
        } else if let Some(expected_peer_fingerprint) = expected_peer_fingerprint.clone() {
            channel
                .lock()
                .await
                .set_expected_peer_fingerprint(Some(expected_peer_fingerprint));
        }

        let resolved_hint = Arc::new(Mutex::new(peer_device_id_hint.as_ref().map(
            |peer_device_id| ResolvedPeerHint {
                peer_device_id: peer_device_id.clone(),
                expected_peer_fingerprint: expected_peer_fingerprint.clone(),
            },
        )));
        let handshake_notify = Arc::new(Notify::new());
        let closed = Arc::new(AtomicBool::new(false));
        let transport_ready = Arc::new(AtomicBool::new(false));
        let signaling_synchronized = Arc::new(AtomicBool::new(false));
        let latest_local_offer = Arc::new(Mutex::new(None::<String>));
        {
            let sid = session_id.clone();
            let mgr = self.callback.clone();
            let chan = Arc::clone(&channel);
            let session_sender = Arc::clone(&session);
            let resolved_hint = Arc::clone(&resolved_hint);
            let closed = Arc::clone(&closed);
            let transport_ready_for_callback = Arc::clone(&transport_ready);
            let signaling_synchronized = Arc::clone(&signaling_synchronized);
            *session.on_ready.lock().await = Some(Box::new(move || {
                let mgr = mgr.clone();
                let sid = sid.clone();
                let chan = Arc::clone(&chan);
                let session_sender = Arc::clone(&session_sender);
                let resolved_hint = Arc::clone(&resolved_hint);
                let closed = Arc::clone(&closed);
                let transport_ready = Arc::clone(&transport_ready_for_callback);
                let signaling_synchronized = Arc::clone(&signaling_synchronized);
                if let Some(cb) = &mgr {
                    cb(CrossNetworkEvent::TransportReady {
                        session_id: sid.clone(),
                    });
                }
                transport_ready.store(true, Ordering::SeqCst);
                signaling_synchronized.store(true, Ordering::SeqCst);
                if session_sender.role == WebRtcRole::Answerer {
                    tokio::spawn(async move {
                        let (peer_device_id, expected_peer_fingerprint) = {
                            let state = resolved_hint.lock().await;
                            (
                                state.as_ref().map(|hint| hint.peer_device_id.clone()),
                                state
                                    .as_ref()
                                    .and_then(|hint| hint.expected_peer_fingerprint.clone()),
                            )
                        };

                        if let Err(err) = enforce_outbound_trust_policy(
                            trust_policy,
                            peer_device_id.as_deref(),
                            expected_peer_fingerprint.as_deref(),
                        ) {
                            if let Some(cb) = &mgr {
                                cb(CrossNetworkEvent::Failed {
                                    session_id: sid.clone(),
                                    error: format!("trust policy: {}", err),
                                });
                            }
                            closed.store(true, Ordering::SeqCst);
                            let _ = session_sender.close().await;
                            return;
                        }

                        let msg_a = {
                            let mut ch = chan.lock().await;
                            match ch.start_handshake().await {
                                Ok(m) => m,
                                Err(err) => {
                                    if let Some(cb) = &mgr {
                                        cb(CrossNetworkEvent::Failed {
                                            session_id: sid.clone(),
                                            error: format!("handshake start: {}", err),
                                        });
                                    }
                                    closed.store(true, Ordering::SeqCst);
                                    let _ = session_sender.close().await;
                                    return;
                                }
                            }
                        };
                        match encode_frame(&msg_a) {
                            Ok(framed) => {
                                if let Err(err) = session_sender.send(framed).await {
                                    if let Some(cb) = &mgr {
                                        cb(CrossNetworkEvent::Failed {
                                            session_id: sid.clone(),
                                            error: format!("send messageA: {}", err),
                                        });
                                    }
                                    closed.store(true, Ordering::SeqCst);
                                    let _ = session_sender.close().await;
                                } else {
                                    emit_status(&mgr, &sid, "Handshake sent: messageA");
                                }
                            }
                            Err(err) => {
                                if let Some(cb) = &mgr {
                                    cb(CrossNetworkEvent::Failed {
                                        session_id: sid.clone(),
                                        error: format!("frame messageA: {}", err),
                                    });
                                }
                                closed.store(true, Ordering::SeqCst);
                                let _ = session_sender.close().await;
                            }
                        }
                    });
                }
            }));
        }

        let (inbound_tx, mut inbound_rx) = mpsc::unbounded_channel::<Vec<u8>>();

        // DataChannel inbound bytes → CrossNetworkChannel.
        //
        // Apple chunks large rekey frames (notably PQC MessageB) into many
        // small DataChannel messages. We must preserve chunk order when feeding
        // the shared length-frame decoder, so callbacks enqueue work onto a
        // single ordered task rather than spawning per chunk.
        {
            let sid = session_id.clone();
            let inbound_tx = inbound_tx.clone();
            *session.on_data.lock().await = Some(Box::new(move |bytes: Vec<u8>| {
                if inbound_tx.send(bytes).is_err() {
                    debug!(
                        "dropping inbound WebRTC chunk after receiver closed: {}",
                        sid
                    );
                }
            }));
        }

        let inbound_task: JoinHandle<()> = {
            let chan = Arc::clone(&channel);
            let session_sender = Arc::clone(&session);
            let mgr = self.callback.clone();
            let sid = session_id.clone();
            let handshake_notify = Arc::clone(&handshake_notify);
            tokio::spawn(async move {
                while let Some(bytes) = inbound_rx.recv().await {
                    let mut ch = chan.lock().await;
                    match ch.push_inbound_chunk(&bytes).await {
                        Ok(events) => {
                            for e in events {
                                match e {
                                    CrossNetworkInbound::OutboundFrame(raw) => {
                                        if let Ok(framed) = encode_frame(&raw) {
                                            if let Err(err) = session_sender.send(framed).await {
                                                if let Some(cb) = &mgr {
                                                    cb(CrossNetworkEvent::Failed {
                                                        session_id: sid.clone(),
                                                        error: format!("send failed: {}", err),
                                                    });
                                                }
                                            } else {
                                                emit_status(
                                                    &mgr,
                                                    &sid,
                                                    "Handshake/control frame sent",
                                                );
                                            }
                                        }
                                    }
                                    CrossNetworkInbound::HandshakeEstablished(_) => {
                                        let peer_device_id = ch
                                            .peer_identity()
                                            .map(|identity| identity.device_id.trim().to_string())
                                            .filter(|device_id| !device_id.is_empty());
                                        handshake_notify.notify_waiters();
                                        if let Some(cb) = &mgr {
                                            cb(CrossNetworkEvent::HandshakeEstablished {
                                                session_id: sid.clone(),
                                                peer_device_id,
                                            });
                                        }
                                    }
                                    CrossNetworkInbound::AppPayload(p) => {
                                        if let Some(cb) = &mgr {
                                            cb(CrossNetworkEvent::AppPayload {
                                                session_id: sid.clone(),
                                                data: p,
                                            });
                                        }
                                    }
                                }
                            }
                        }
                        Err(err) => {
                            if let Some(cb) = &mgr {
                                cb(CrossNetworkEvent::Failed {
                                    session_id: sid.clone(),
                                    error: format!("inbound failed: {}", err),
                                });
                            }
                        }
                    }
                }
            })
        };

        // WebRTC local SDP/ICE → signaling
        {
            let sid = session_id.clone();
            let from = local_device_id.clone();
            let sig_tx_offer = sig_tx.clone();
            let latest_local_offer = Arc::clone(&latest_local_offer);
            let mgr = self.callback.clone();
            let signaling_auth_token = signaling_auth_token.clone();
            *session.on_local_offer.lock().await = Some(Box::new(move |sdp: String| {
                let latest_local_offer = Arc::clone(&latest_local_offer);
                let sdp_for_cache = sdp.clone();
                let signaling_auth_token = signaling_auth_token.clone();
                tokio::spawn(async move {
                    *latest_local_offer.lock().await = Some(sdp_for_cache);
                });
                let mut env = WebRtcSignalingEnvelope::new(
                    sid.clone(),
                    from.clone(),
                    WebRtcSignalingType::Offer,
                )
                .with_payload(WebRtcSignalingPayload::sdp(sdp));
                if let Some(auth_token) = signaling_auth_token {
                    env = env.with_auth_token(auth_token);
                }
                emit_status(&mgr, &sid, "Signaling sent: offer");
                let _ = sig_tx_offer.send(env);
            }));
        }
        {
            let sid = session_id.clone();
            let from = local_device_id.clone();
            let sig_tx_answer = sig_tx.clone();
            let mgr = self.callback.clone();
            let signaling_auth_token = signaling_auth_token.clone();
            *session.on_local_answer.lock().await = Some(Box::new(move |sdp: String| {
                let mut env = WebRtcSignalingEnvelope::new(
                    sid.clone(),
                    from.clone(),
                    WebRtcSignalingType::Answer,
                )
                .with_payload(WebRtcSignalingPayload::sdp(sdp));
                if let Some(auth_token) = signaling_auth_token.clone() {
                    env = env.with_auth_token(auth_token);
                }
                emit_status(&mgr, &sid, "Signaling sent: answer");
                let _ = sig_tx_answer.send(env);
            }));
        }
        {
            let sid = session_id.clone();
            let from = local_device_id.clone();
            let sig_tx_ice = sig_tx.clone();
            let mgr = self.callback.clone();
            let signaling_auth_token = signaling_auth_token.clone();
            *session.on_local_ice_candidate.lock().await = Some(Box::new(move |cand| {
                let mut env = WebRtcSignalingEnvelope::new(
                    sid.clone(),
                    from.clone(),
                    WebRtcSignalingType::IceCandidate,
                )
                .with_payload(WebRtcSignalingPayload::ice_candidate(
                    cand.candidate,
                    cand.sdp_mid,
                    cand.sdp_mline_index.map(|v| v as i32),
                ));
                if let Some(auth_token) = signaling_auth_token.clone() {
                    env = env.with_auth_token(auth_token);
                }
                emit_status(&mgr, &sid, "Signaling sent: iceCandidate");
                let _ = sig_tx_ice.send(env);
            }));
        }

        // Start WebRTC offerer (creates DC + emits offer)
        session
            .start()
            .await
            .map_err(|e| anyhow::anyhow!("{}", e))?;

        // Join signaling room (best-effort, both sides)
        emit_status(&self.callback, &session_id, "Signaling sent: join");
        let mut join_env = WebRtcSignalingEnvelope::new(
            session_id.clone(),
            local_device_id.clone(),
            WebRtcSignalingType::Join,
        );
        if let Some(auth_token) = signaling_auth_token.clone() {
            join_env = join_env.with_auth_token(auth_token);
        }
        let _ = sig_tx.send(join_env);
        let join_heartbeat_task = {
            let sid = session_id.clone();
            let from = local_device_id.clone();
            let sig_tx_join = sig_tx.clone();
            let closed = Arc::clone(&closed);
            let transport_ready = Arc::clone(&transport_ready);
            let mgr = self.callback.clone();
            let signaling_auth_token = signaling_auth_token.clone();
            tokio::spawn(async move {
                for _ in 0..30 {
                    if closed.load(Ordering::SeqCst) || transport_ready.load(Ordering::SeqCst) {
                        break;
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                    if closed.load(Ordering::SeqCst) || transport_ready.load(Ordering::SeqCst) {
                        break;
                    }
                    let mut env = WebRtcSignalingEnvelope::new(
                        sid.clone(),
                        from.clone(),
                        WebRtcSignalingType::Join,
                    );
                    if let Some(auth_token) = signaling_auth_token.clone() {
                        env = env.with_auth_token(auth_token);
                    }
                    let _ = sig_tx_join.send(env);
                    emit_status(&mgr, &sid, "Signaling sent: join heartbeat");
                }
            })
        };
        let offer_resend_task = if role == WebRtcRole::Offerer {
            let sid = session_id.clone();
            let from = local_device_id.clone();
            let sig_tx_offer = sig_tx.clone();
            let latest_local_offer = Arc::clone(&latest_local_offer);
            let closed = Arc::clone(&closed);
            let signaling_synchronized = Arc::clone(&signaling_synchronized);
            let mgr = self.callback.clone();
            let signaling_auth_token = signaling_auth_token.clone();
            Some(tokio::spawn(async move {
                for _ in 0..40 {
                    if closed.load(Ordering::SeqCst)
                        || signaling_synchronized.load(Ordering::SeqCst)
                    {
                        break;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
                    if closed.load(Ordering::SeqCst)
                        || signaling_synchronized.load(Ordering::SeqCst)
                    {
                        break;
                    }
                    let Some(sdp) = latest_local_offer.lock().await.clone() else {
                        continue;
                    };
                    let mut env = WebRtcSignalingEnvelope::new(
                        sid.clone(),
                        from.clone(),
                        WebRtcSignalingType::Offer,
                    )
                    .with_payload(WebRtcSignalingPayload::sdp(sdp));
                    if let Some(auth_token) = signaling_auth_token.clone() {
                        env = env.with_auth_token(auth_token);
                    }
                    let _ = sig_tx_offer.send(env);
                    emit_status(&mgr, &sid, "Signaling resent: offer");
                }
            }))
        } else {
            None
        };

        // Signaling driver task: apply inbound envelopes to session
        let signaling_driver_task: JoinHandle<()> = {
            let session = Arc::clone(&session);
            let sid = session_id.clone();
            let local = local_device_id.clone();
            let chan = Arc::clone(&channel);
            let mgr = self.callback.clone();
            let resolved_hint = Arc::clone(&resolved_hint);
            let closed = Arc::clone(&closed);
            let signaling_synchronized = Arc::clone(&signaling_synchronized);
            let latest_local_offer = Arc::clone(&latest_local_offer);
            let current_path_remote_authority = current_path_remote_authority.clone();
            let signaling_auth_token = signaling_auth_token.clone();
            tokio::spawn(async move {
                // For answerer, we may receive offer before DC is ready; that's fine.
                while let Some(env) = sig_rx.recv().await {
                    if env.session_id != sid {
                        continue;
                    }
                    if env.from == local {
                        continue;
                    }
                    if let Some(authority) = current_path_remote_authority.as_ref()
                        && authority.device_id != env.from
                    {
                        if let Some(cb) = &mgr {
                            cb(CrossNetworkEvent::Failed {
                                session_id: sid.clone(),
                                error: format!(
                                    "signaling current-path mismatch: expected {}, got {}",
                                    authority.device_id, env.from
                                ),
                            });
                        }
                        closed.store(true, Ordering::SeqCst);
                        let _ = session.close().await;
                        break;
                    }
                    debug!(
                        session_id = %sid,
                        from = %env.from,
                        msg_type = ?env.msg_type,
                        "received WebRTC signaling envelope"
                    );
                    maybe_resolve_peer_hint(&sid, &local, &env.from, &chan, &resolved_hint, &mgr)
                        .await;
                    let (peer_device_id, expected_peer_fingerprint) = {
                        let state = resolved_hint.lock().await;
                        (
                            state.as_ref().map(|hint| hint.peer_device_id.clone()),
                            state
                                .as_ref()
                                .and_then(|hint| hint.expected_peer_fingerprint.clone()),
                        )
                    };
                    if let Some(peer_device_id) = peer_device_id.as_deref()
                        && let Err(err) = enforce_outbound_trust_policy(
                            trust_policy,
                            Some(peer_device_id),
                            expected_peer_fingerprint.as_deref(),
                        )
                    {
                        if let Some(cb) = &mgr {
                            cb(CrossNetworkEvent::Failed {
                                session_id: sid.clone(),
                                error: format!("trust policy: {}", err),
                            });
                        }
                        closed.store(true, Ordering::SeqCst);
                        let _ = session.close().await;
                        break;
                    }
                    match env.msg_type {
                        WebRtcSignalingType::Offer => {
                            emit_status(
                                &mgr,
                                &sid,
                                format!("Signaling received: offer from {}", env.from),
                            );
                            signaling_synchronized.store(true, Ordering::SeqCst);
                            if let Some(payload) = env.payload
                                && let Some(sdp) = payload.sdp
                            {
                                emit_status(
                                    &mgr,
                                    &sid,
                                    format!("Remote offer {}", summarize_sdp_candidates(&sdp)),
                                );
                                if let Err(err) = session.set_remote_offer(sdp).await {
                                    if let Some(cb) = &mgr {
                                        cb(CrossNetworkEvent::Failed {
                                            session_id: sid.clone(),
                                            error: format!("set_remote_offer: {}", err),
                                        });
                                    }
                                    break;
                                }
                            }
                        }
                        WebRtcSignalingType::Answer => {
                            emit_status(
                                &mgr,
                                &sid,
                                format!("Signaling received: answer from {}", env.from),
                            );
                            signaling_synchronized.store(true, Ordering::SeqCst);
                            if let Some(payload) = env.payload
                                && let Some(sdp) = payload.sdp
                                && let Err(err) = session.set_remote_answer(sdp).await
                            {
                                if let Some(cb) = &mgr {
                                    cb(CrossNetworkEvent::Failed {
                                        session_id: sid.clone(),
                                        error: format!("set_remote_answer: {}", err),
                                    });
                                }
                                break;
                            }
                        }
                        WebRtcSignalingType::IceCandidate => {
                            emit_status(
                                &mgr,
                                &sid,
                                format!("Signaling received: iceCandidate from {}", env.from),
                            );
                            if let Some(payload) = env.payload
                                && let Some(candidate) = payload.candidate
                            {
                                let init =
                                    webrtc::ice_transport::ice_candidate::RTCIceCandidateInit {
                                        candidate,
                                        sdp_mid: payload.sdp_mid,
                                        sdp_mline_index: payload
                                            .sdp_m_line_index
                                            .and_then(|i| u16::try_from(i).ok()),
                                        username_fragment: None,
                                    };
                                if let Err(err) = session.add_remote_ice_candidate(init).await {
                                    debug!("add_remote_ice_candidate failed: {}", err);
                                }
                            }
                        }
                        WebRtcSignalingType::Join => {
                            emit_status(
                                &mgr,
                                &sid,
                                format!("Signaling received: join from {}", env.from),
                            );
                            if role == WebRtcRole::Offerer
                                && let Some(sdp) = latest_local_offer.lock().await.clone()
                            {
                                let mut env = WebRtcSignalingEnvelope::new(
                                    sid.clone(),
                                    local.clone(),
                                    WebRtcSignalingType::Offer,
                                )
                                .with_payload(WebRtcSignalingPayload::sdp(sdp));
                                if let Some(auth_token) = signaling_auth_token.clone() {
                                    env = env.with_auth_token(auth_token);
                                }
                                let _ = sig_tx.send(env);
                                emit_status(
                                    &mgr,
                                    &sid,
                                    "Signaling resent: offer after remote join",
                                );
                            }
                        }
                        WebRtcSignalingType::Leave => {
                            emit_status(
                                &mgr,
                                &sid,
                                format!("Signaling received: leave from {}", env.from),
                            );
                        }
                    }
                }
            })
        };

        // App send task: plaintext -> encrypt -> frame -> DataChannel send
        let (app_tx, mut app_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let app_sender_task: JoinHandle<()> = {
            let session = Arc::clone(&session);
            let chan = Arc::clone(&channel);
            let sid = session_id.clone();
            let mgr = self.callback.clone();
            let handshake_notify = Arc::clone(&handshake_notify);
            tokio::spawn(async move {
                loop {
                    let Some(plaintext) = app_rx.recv().await else {
                        break;
                    };
                    // Wait until handshake established.
                    if !chan.lock().await.is_established() {
                        handshake_notify.notified().await;
                    }
                    let sealed = {
                        let ch = chan.lock().await;
                        match ch.encrypt_app_payload(&plaintext) {
                            Ok(b) => b,
                            Err(err) => {
                                if let Some(cb) = &mgr {
                                    cb(CrossNetworkEvent::Failed {
                                        session_id: sid.clone(),
                                        error: format!("encrypt app payload: {}", err),
                                    });
                                }
                                continue;
                            }
                        }
                    };
                    let framed = match encode_frame(&sealed) {
                        Ok(f) => f,
                        Err(err) => {
                            if let Some(cb) = &mgr {
                                cb(CrossNetworkEvent::Failed {
                                    session_id: sid.clone(),
                                    error: format!("frame app payload: {}", err),
                                });
                            }
                            continue;
                        }
                    };
                    if let Err(err) = session.send(framed).await {
                        if let Some(cb) = &mgr {
                            cb(CrossNetworkEvent::Failed {
                                session_id: sid.clone(),
                                error: format!("send app payload: {}", err),
                            });
                        }
                        break;
                    }
                }
            })
        };

        Ok(WebRtcCrossNetworkHandle {
            session_id,
            app_send: app_tx,
            session,
            channel,
            closed,
            _signaling_task: sig_task,
            _signaling_driver_task: signaling_driver_task,
            _inbound_task: inbound_task,
            _app_sender_task: app_sender_task,
            _join_heartbeat_task: join_heartbeat_task,
            _offer_resend_task: offer_resend_task,
        })
    }
}

impl WebRtcCrossNetworkHandle {
    /// Send a plaintext application payload over the encrypted channel.
    ///
    /// This will be AES-GCM encrypted with the negotiated `SessionKeys` and framed
    /// with a 4-byte big-endian length prefix (macOS/iOS compatible).
    pub fn send_app_payload(&self, data: Vec<u8>) -> anyhow::Result<()> {
        self.app_send
            .send(data)
            .map_err(|_| anyhow::anyhow!("webrtc app send channel closed"))
    }

    pub async fn peer_identity(&self) -> Option<PeerIdentity> {
        self.channel.lock().await.peer_identity().cloned()
    }

    pub async fn negotiated_suite(&self) -> Option<CryptoSuiteId> {
        self.channel
            .lock()
            .await
            .session_keys()
            .map(|keys| keys.suite_id)
    }

    pub async fn start_outbound_pqc_rekey(
        &self,
        peer_device_id: Option<String>,
        peer_kem_public_keys: HashMap<CryptoSuiteId, Vec<u8>>,
    ) -> anyhow::Result<bool> {
        let message_a = {
            let mut channel = self.channel.lock().await;
            channel
                .start_outbound_pqc_rekey(peer_device_id, peer_kem_public_keys)
                .await?
        };
        let Some(message_a) = message_a else {
            return Ok(false);
        };

        let framed = encode_frame(&message_a)?;
        self.session
            .send(framed)
            .await
            .map_err(|err| anyhow::anyhow!("{}", err))?;
        Ok(true)
    }

    pub async fn close(&self) -> anyhow::Result<()> {
        self.closed.store(true, Ordering::SeqCst);
        self._signaling_task.abort();
        self._signaling_driver_task.abort();
        self._inbound_task.abort();
        self._app_sender_task.abort();
        self.session
            .close()
            .await
            .map_err(|err| anyhow::anyhow!("{}", err))
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use super::{canonical_pqc_rekey_election_device_id, should_initiate_pqc_rekey};

    #[test]
    fn canonical_pqc_election_device_id_matches_apple_rules() {
        assert_eq!(
            canonical_pqc_rekey_election_device_id(Some("  Device-01  ")).as_deref(),
            Some("device-01")
        );
        assert_eq!(
            canonical_pqc_rekey_election_device_id(Some("webrtc-temp")),
            None
        );
        assert_eq!(canonical_pqc_rekey_election_device_id(Some("   ")), None);
        assert_eq!(canonical_pqc_rekey_election_device_id(None), None);
    }

    #[test]
    fn pqc_rekey_election_prefers_lexicographically_smaller_device_id() {
        assert_eq!(
            should_initiate_pqc_rekey(Some("alpha"), Some("beta")),
            Some(true)
        );
        assert_eq!(
            should_initiate_pqc_rekey(Some("beta"), Some("alpha")),
            Some(false)
        );
        assert_eq!(
            should_initiate_pqc_rekey(Some("webrtc-alpha"), Some("beta")),
            None
        );
        assert_eq!(
            should_initiate_pqc_rekey(Some("alpha"), Some("alpha")),
            None
        );
    }
}
