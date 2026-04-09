//! WebRTC session wrapper (DataChannel-oriented).
//!
//! This is an MVP implementation to mirror the macOS/iOS behavior:
//! - Create an RTCPeerConnection
//! - Create/open a single DataChannel for binary messages
//! - Exchange SDP + ICE candidates via signaling
//!
//! We only depend on the `webrtc` crate (pion-style) and expose a minimal API.

use std::sync::Arc;

use bytes::Bytes;
use tokio::sync::Mutex;
use tracing::{info, warn};

use webrtc::api::APIBuilder;
use webrtc::api::interceptor_registry::register_default_interceptors;
use webrtc::api::media_engine::MediaEngine;
use webrtc::api::setting_engine::SettingEngine;
use webrtc::data_channel::RTCDataChannel;
use webrtc::data_channel::data_channel_message::DataChannelMessage;
use webrtc::ice::mdns::MulticastDnsMode;
use webrtc::ice::network_type::NetworkType;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;
use webrtc::ice_transport::ice_candidate_type::RTCIceCandidateType;
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::peer_connection::RTCPeerConnection;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState;
use webrtc::peer_connection::policy::ice_transport_policy::RTCIceTransportPolicy;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::signaling_state::RTCSignalingState;

type SharedCallback<T> = Arc<Mutex<Option<T>>>;
type StringCallback = Box<dyn Fn(String) + Send + Sync>;
type IceCallback = Box<dyn Fn(RTCIceCandidateInit) + Send + Sync>;
type DataCallback = Box<dyn Fn(Vec<u8>) + Send + Sync>;
type ReadyCallback = Box<dyn Fn() + Send + Sync>;

#[derive(Debug, thiserror::Error)]
pub enum WebRtcSessionError {
    #[error("webrtc error: {0}")]
    WebRtc(String),
    #[error("data channel not ready")]
    DataChannelNotReady,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WebRtcRole {
    Offerer,
    Answerer,
}

#[derive(Debug, Clone)]
pub struct IceConfig {
    pub stun_url: String,
    pub turn_url: String,
    pub turn_username: String,
    pub turn_password: String,
    pub relay_only: bool,
}

pub struct WebRtcSession {
    pub session_id: String,
    pub local_device_id: String,
    pub role: WebRtcRole,
    pub ice: IceConfig,

    pc: Arc<RTCPeerConnection>,
    dc: Arc<Mutex<Option<Arc<RTCDataChannel>>>>,

    /// Local SDP offer (offerer)
    pub on_local_offer: SharedCallback<StringCallback>,
    /// Local SDP answer (answerer)
    pub on_local_answer: SharedCallback<StringCallback>,
    /// Local ICE candidate (both)
    pub on_local_ice_candidate: SharedCallback<IceCallback>,
    /// Incoming DataChannel bytes (both)
    pub on_data: SharedCallback<DataCallback>,
    /// DataChannel ready (open)
    pub on_ready: SharedCallback<ReadyCallback>,
}

impl WebRtcSession {
    pub async fn new(
        session_id: String,
        local_device_id: String,
        role: WebRtcRole,
        ice: IceConfig,
    ) -> Result<Self, WebRtcSessionError> {
        let mut m = MediaEngine::default();
        // DataChannel-only: we still register defaults to satisfy API expectations.
        m.register_default_codecs()
            .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;

        let mut registry = webrtc::interceptor::registry::Registry::new();
        registry = register_default_interceptors(registry, &mut m)
            .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;

        let mut setting_engine = SettingEngine::default();
        // Cloud-hosted Linux answerers behave more predictably when we avoid
        // IPv6 probing and mDNS host candidates that remote WAN peers cannot use.
        setting_engine.set_network_types(vec![NetworkType::Udp4]);
        setting_engine.set_ice_multicast_dns_mode(MulticastDnsMode::Disabled);
        if let Some(public_ip) = explicit_public_nat_ip() {
            info!(
                session_id = %session_id,
                public_ip = %public_ip,
                "Configuring WebRTC 1:1 NAT public host candidate"
            );
            setting_engine.set_nat_1to1_ips(vec![public_ip], RTCIceCandidateType::Host);
        }

        let api = APIBuilder::new()
            .with_setting_engine(setting_engine)
            .with_media_engine(m)
            .with_interceptor_registry(registry)
            .build();

        let mut ice_servers = Vec::new();
        if !ice.stun_url.trim().is_empty() {
            ice_servers.push(RTCIceServer {
                urls: vec![ice.stun_url.clone()],
                ..Default::default()
            });
        }
        let turn_url = ice.turn_url.trim();
        let turn_username = ice.turn_username.trim();
        let turn_password = ice.turn_password.trim();
        if !turn_url.is_empty() {
            if turn_username.is_empty() || turn_password.is_empty() {
                warn!(
                    session_id = %session_id,
                    "Skipping TURN server because credentials are missing"
                );
            } else {
                ice_servers.push(RTCIceServer {
                    urls: vec![ice.turn_url.clone()],
                    username: ice.turn_username.clone(),
                    credential: ice.turn_password.clone(),
                });
            }
        }

        let config = RTCConfiguration {
            ice_servers,
            ice_transport_policy: if ice.relay_only {
                RTCIceTransportPolicy::Relay
            } else {
                RTCIceTransportPolicy::All
            },
            ..Default::default()
        };

        let pc = Arc::new(
            api.new_peer_connection(config)
                .await
                .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?,
        );

        let dc: Arc<Mutex<Option<Arc<RTCDataChannel>>>> = Arc::new(Mutex::new(None));

        let on_local_offer: SharedCallback<StringCallback> = Arc::new(Mutex::new(None));
        let on_local_answer: SharedCallback<StringCallback> = Arc::new(Mutex::new(None));
        let on_local_ice_candidate: SharedCallback<IceCallback> = Arc::new(Mutex::new(None));
        let on_data: SharedCallback<DataCallback> = Arc::new(Mutex::new(None));
        let on_ready: SharedCallback<ReadyCallback> = Arc::new(Mutex::new(None));

        // ICE candidates callback
        {
            let on_local_ice_candidate = Arc::clone(&on_local_ice_candidate);
            pc.on_ice_candidate(Box::new(move |cand| {
                let on_local_ice_candidate = Arc::clone(&on_local_ice_candidate);
                Box::pin(async move {
                    if let Some(cand) = cand {
                        let init = cand.to_json().unwrap_or_default();
                        if let Some(cb) = &*on_local_ice_candidate.lock().await {
                            cb(init);
                        }
                    }
                })
            }));
        }

        // Connection state logging
        pc.on_peer_connection_state_change(Box::new(move |s: RTCPeerConnectionState| {
            Box::pin(async move {
                info!("WebRTC PC state: {:?}", s);
            })
        }));

        // DataChannel callback for answerer (offerer creates it locally)
        {
            let dc_store = Arc::clone(&dc);
            let on_data = Arc::clone(&on_data);
            let on_ready = Arc::clone(&on_ready);
            pc.on_data_channel(Box::new(move |chan: Arc<RTCDataChannel>| {
                let dc_store = Arc::clone(&dc_store);
                let on_data = Arc::clone(&on_data);
                let on_ready = Arc::clone(&on_ready);
                Box::pin(async move {
                    {
                        let mut guard = dc_store.lock().await;
                        *guard = Some(Arc::clone(&chan));
                    }

                    chan.on_open(Box::new(move || {
                        let on_ready = Arc::clone(&on_ready);
                        Box::pin(async move {
                            if let Some(cb) = &*on_ready.lock().await {
                                cb();
                            }
                        })
                    }));

                    chan.on_message(Box::new(move |msg: DataChannelMessage| {
                        let on_data = Arc::clone(&on_data);
                        Box::pin(async move {
                            if let Some(cb) = &*on_data.lock().await {
                                cb(msg.data.to_vec());
                            }
                        })
                    }));
                })
            }));
        }

        Ok(Self {
            session_id,
            local_device_id,
            role,
            ice,
            pc,
            dc,
            on_local_offer,
            on_local_answer,
            on_local_ice_candidate,
            on_data,
            on_ready,
        })
    }

    pub async fn start(&self) -> Result<(), WebRtcSessionError> {
        if self.role == WebRtcRole::Offerer {
            // Create DataChannel and start offer
            let chan = self
                .pc
                .create_data_channel("skybridge", None)
                .await
                .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;

            {
                let mut guard = self.dc.lock().await;
                *guard = Some(Arc::clone(&chan));
            }

            // Wire callbacks
            {
                let on_ready = Arc::clone(&self.on_ready);
                chan.on_open(Box::new(move || {
                    let on_ready = Arc::clone(&on_ready);
                    Box::pin(async move {
                        if let Some(cb) = &*on_ready.lock().await {
                            cb();
                        }
                    })
                }));
            }
            {
                let on_data = Arc::clone(&self.on_data);
                chan.on_message(Box::new(move |msg: DataChannelMessage| {
                    let on_data = Arc::clone(&on_data);
                    Box::pin(async move {
                        if let Some(cb) = &*on_data.lock().await {
                            cb(msg.data.to_vec());
                        }
                    })
                }));
            }

            let offer = self
                .pc
                .create_offer(None)
                .await
                .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;
            self.pc
                .set_local_description(offer)
                .await
                .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;

            if let Some(local) = self.pc.local_description().await
                && let Some(cb) = &*self.on_local_offer.lock().await
            {
                cb(local.sdp);
            }
        }
        Ok(())
    }

    pub async fn set_remote_offer(&self, sdp: String) -> Result<(), WebRtcSessionError> {
        let signaling_state = self.pc.signaling_state();
        if self.pc.remote_description().await.is_some()
            || signaling_state == RTCSignalingState::HaveRemoteOffer
            || signaling_state == RTCSignalingState::HaveLocalPranswer
        {
            info!(
                session_id = %self.session_id,
                ?signaling_state,
                "Ignoring duplicate remote offer"
            );
            return Ok(());
        }
        let desc = RTCSessionDescription::offer(sdp)
            .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;
        self.pc
            .set_remote_description(desc)
            .await
            .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;

        // Create answer
        let answer = self
            .pc
            .create_answer(None)
            .await
            .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;
        self.pc
            .set_local_description(answer)
            .await
            .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;
        if let Some(local) = self.pc.local_description().await
            && let Some(cb) = &*self.on_local_answer.lock().await
        {
            cb(local.sdp);
        }
        Ok(())
    }

    pub async fn set_remote_answer(&self, sdp: String) -> Result<(), WebRtcSessionError> {
        let signaling_state = self.pc.signaling_state();
        if self.pc.remote_description().await.is_some()
            || signaling_state == RTCSignalingState::Stable
        {
            info!(
                session_id = %self.session_id,
                ?signaling_state,
                "Ignoring duplicate remote answer"
            );
            return Ok(());
        }
        let desc = RTCSessionDescription::answer(sdp)
            .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;
        self.pc
            .set_remote_description(desc)
            .await
            .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;
        Ok(())
    }

    pub async fn add_remote_ice_candidate(
        &self,
        candidate: RTCIceCandidateInit,
    ) -> Result<(), WebRtcSessionError> {
        self.pc
            .add_ice_candidate(candidate)
            .await
            .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;
        Ok(())
    }

    pub async fn send(&self, data: Vec<u8>) -> Result<(), WebRtcSessionError> {
        let chan = {
            let guard = self.dc.lock().await;
            guard.clone()
        }
        .ok_or(WebRtcSessionError::DataChannelNotReady)?;

        chan.send(&Bytes::from(data))
            .await
            .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;
        Ok(())
    }

    pub async fn close(&self) -> Result<(), WebRtcSessionError> {
        if let Some(chan) = self.dc.lock().await.clone() {
            chan.close()
                .await
                .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;
        }
        self.pc
            .close()
            .await
            .map_err(|e| WebRtcSessionError::WebRtc(e.to_string()))?;
        Ok(())
    }
}

fn explicit_public_nat_ip() -> Option<String> {
    let value = std::env::var("SKYBRIDGE_WEBRTC_PUBLIC_IP").ok()?;
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    match trimmed.parse::<std::net::IpAddr>() {
        Ok(std::net::IpAddr::V4(_)) => Some(trimmed.to_string()),
        Ok(std::net::IpAddr::V6(_)) => {
            warn!("Ignoring IPv6 public ICE override because Rust WebRTC is pinned to UDP/IPv4");
            None
        }
        Err(_) => {
            warn!("Ignoring invalid SKYBRIDGE_WEBRTC_PUBLIC_IP override");
            None
        }
    }
}
