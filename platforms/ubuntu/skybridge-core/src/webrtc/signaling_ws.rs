use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{debug, warn};
use url::Url;

use super::WebRtcSignalingEnvelope;

/// WebRTC signaling client configuration (WebSocket).
#[derive(Debug, Clone)]
pub struct WebRtcSignalingClientConfig {
    pub url: Url,
}

/// A small WebSocket client for exchanging `WebRtcSignalingEnvelope`.
///
/// This mirrors the macOS/iOS approach: "signaling is just envelope exchange".
pub struct WebRtcSignalingClient {
    tx: mpsc::UnboundedSender<WebRtcSignalingEnvelope>,
    rx: mpsc::UnboundedReceiver<WebRtcSignalingEnvelope>,
    _task: JoinHandle<()>,
}

impl WebRtcSignalingClient {
    pub async fn connect(config: WebRtcSignalingClientConfig) -> anyhow::Result<Self> {
        debug!("connecting WebRTC signaling websocket to {}", config.url);
        let (ws, _) = tokio_tungstenite::connect_async(config.url.as_str()).await?;
        debug!("connected WebRTC signaling websocket to {}", config.url);
        let (mut write, mut read) = ws.split();

        let (out_tx, mut out_rx) = mpsc::unbounded_channel::<WebRtcSignalingEnvelope>();
        let (in_tx, in_rx) = mpsc::unbounded_channel::<WebRtcSignalingEnvelope>();

        let task: JoinHandle<()> = tokio::spawn(async move {
            let mut bound = false;
            let mut pending_outbound: Vec<WebRtcSignalingEnvelope> = Vec::new();
            loop {
                tokio::select! {
                    outbound = out_rx.recv() => {
                        match outbound {
                            Some(env) => {
                                if !bound {
                                    pending_outbound.push(env);
                                    continue;
                                }
                                debug!(
                                    session_id = %env.session_id,
                                    msg_type = ?env.msg_type,
                                    "sending WebRTC signaling envelope"
                                );
                                match serde_json::to_string(&env) {
                                    Ok(text) => {
                                        if let Err(err) = write.send(tokio_tungstenite::tungstenite::Message::Text(text.into())).await {
                                            warn!("webrtc signaling send failed: {}", err);
                                            break;
                                        }
                                    }
                                    Err(err) => {
                                        warn!("webrtc signaling serialize failed: {}", err);
                                    }
                                }
                            }
                            None => break,
                        }
                    }
                    inbound = read.next() => {
                        match inbound {
                            Some(Ok(msg)) => {
                                match msg {
                                    tokio_tungstenite::tungstenite::Message::Text(txt) => {
                                        if let Ok(value) = serde_json::from_str::<serde_json::Value>(&txt)
                                            && value.get("type").and_then(|raw| raw.as_str()) == Some("bound")
                                        {
                                            bound = true;
                                            for env in pending_outbound.drain(..) {
                                                debug!(
                                                    session_id = %env.session_id,
                                                    msg_type = ?env.msg_type,
                                                    "sending WebRTC signaling envelope after bound"
                                                );
                                                match serde_json::to_string(&env) {
                                                    Ok(text) => {
                                                        if let Err(err) = write.send(tokio_tungstenite::tungstenite::Message::Text(text.into())).await {
                                                            warn!("webrtc signaling send failed after bound: {}", err);
                                                            break;
                                                        }
                                                    }
                                                    Err(err) => warn!("webrtc signaling serialize failed after bound: {}", err),
                                                }
                                            }
                                            continue;
                                        }
                                        match serde_json::from_str::<WebRtcSignalingEnvelope>(&txt) {
                                            Ok(env) => {
                                                debug!(
                                                    session_id = %env.session_id,
                                                    from = %env.from,
                                                    msg_type = ?env.msg_type,
                                                    "received WebRTC signaling envelope"
                                                );
                                                let _ = in_tx.send(env);
                                            }
                                            Err(err) => {
                                                debug!(
                                                    "webrtc signaling parse failed: {} text={}",
                                                    err,
                                                    txt.chars().take(200).collect::<String>()
                                                );
                                            }
                                        }
                                    }
                                    tokio_tungstenite::tungstenite::Message::Binary(bin) => {
                                        if let Ok(txt) = String::from_utf8(bin.to_vec())
                                            && let Ok(env) = serde_json::from_str::<WebRtcSignalingEnvelope>(&txt) {
                                                debug!(
                                                    session_id = %env.session_id,
                                                    from = %env.from,
                                                    msg_type = ?env.msg_type,
                                                    "received WebRTC signaling envelope"
                                                );
                                                let _ = in_tx.send(env);
                                            }
                                    }
                                    tokio_tungstenite::tungstenite::Message::Close(_) => break,
                                    _ => {}
                                }
                            }
                            Some(Err(err)) => {
                                warn!("webrtc signaling recv failed: {}", err);
                                break;
                            }
                            None => break,
                        }
                    }
                }
            }
        });

        Ok(Self {
            tx: out_tx,
            rx: in_rx,
            _task: task,
        })
    }

    pub fn send(&self, env: WebRtcSignalingEnvelope) -> anyhow::Result<()> {
        self.tx
            .send(env)
            .map_err(|_| anyhow::anyhow!("signaling channel closed"))
    }

    pub async fn recv(&mut self) -> Option<WebRtcSignalingEnvelope> {
        self.rx.recv().await
    }

    /// Split into a sender and a receiver (and keep-alive task).
    ///
    /// This is convenient for wiring callbacks that need a cheap cloneable sender.
    pub fn split(
        self,
    ) -> (
        mpsc::UnboundedSender<WebRtcSignalingEnvelope>,
        mpsc::UnboundedReceiver<WebRtcSignalingEnvelope>,
        JoinHandle<()>,
    ) {
        (self.tx, self.rx, self._task)
    }
}
