use crate::state::AppState;
use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::IntoResponse,
    routing::get,
    Router,
};
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use tokio::sync::broadcast;
use tokio::sync::broadcast::error::TryRecvError;
use tokio::sync::broadcast::Receiver as BReceiver;
use tokio::time::{interval, Duration};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentDevice {
    id: String,
    name: String,
    ipv4: String,
    device_id: String,
    #[serde(rename = "pubKeyFP")]
    pub_key_fp: String,
    unique_identifier: String,
    source: String,
    connection_types: Vec<String>,
}

pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/agent", get(ws_handler))
        .with_state(state)
}

async fn ws_handler(State(state): State<AppState>, ws: WebSocketUpgrade) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(state, socket))
}

async fn handle_socket(state: AppState, mut socket: WebSocket) {
    let mut tick_devices = interval(Duration::from_secs(2));
    let mut tick_forward = interval(Duration::from_millis(50));
    let mut session_rx: HashMap<String, BReceiver<String>> = HashMap::new();
    let mut authed = false;
    loop {
        tokio::select! {
            _ = tick_devices.tick() => {
                let payload = serde_json::json!({
                    "devices": [
                        AgentDevice {
                            id: "local_dev_001".to_string(),
                            name: "Bonjour-MacBook-Pro".to_string(),
                            ipv4: "192.168.1.110".to_string(),
                            device_id: "mac-device-uuid".to_string(),
                            pub_key_fp: "sha256:ABCDEF123456".to_string(),
                            unique_identifier: "MAC-01-LOCAL".to_string(),
                            source: "SkyBridge Bonjour".to_string(),
                            connection_types: vec!["wifi".to_string()],
                        },
                        AgentDevice {
                            id: "local_dev_002".to_string(),
                            name: "Bonjour-iPhone".to_string(),
                            ipv4: "192.168.1.120".to_string(),
                            device_id: "iphone-device-uuid".to_string(),
                            pub_key_fp: "sha256:7890ABCDEF".to_string(),
                            unique_identifier: "IPH-15-LOCAL".to_string(),
                            source: "SkyBridge Bonjour".to_string(),
                            connection_types: vec!["wifi".to_string(), "bluetooth".to_string()],
                        }
                    ]
                });
                let txt = payload.to_string();
                if socket.send(Message::Text(txt)).await.is_err() {
                    break;
                }
            },
            _ = tick_forward.tick() => {
                for (_sid, rx) in session_rx.iter_mut() {
                    loop {
                        match rx.try_recv() {
                            Ok(txt) => {
                                if socket.send(Message::Text(txt)).await.is_err() { break; }
                            },
                            Err(TryRecvError::Lagged(_)) => { break; },
                            Err(TryRecvError::Closed) => { break; },
                            Err(TryRecvError::Empty) => { break; },
                        }
                    }
                }
            },
            msg = socket.recv() => {
                match msg {
                    Some(Ok(Message::Text(t))) => {
                        if let Ok(v) = serde_json::from_str::<Value>(&t) {
                            match v.get("type").and_then(|x| x.as_str()) {
                                Some("auth") => {
                                    if let Some(tok) = v.get("token").and_then(|x| x.as_str()) {
                                        if tok == "dev" {
                                            authed = true;
                                        } else {
                                            authed = state.supabase.get_user(tok).await.is_ok();
                                        }
                                    }
                                },
                                Some("session-join") => {
                                    if authed {
                                        if let Some(sid) = v.get("sessionId").and_then(|x| x.as_str()) {
                                            let did_opt = v.get("deviceId").and_then(|x| x.as_str());
                                            let key = if let Some(did) = did_opt { format!("{}::{}", sid, did) } else { sid.to_string() };
                                            let tx = if let Some(entry) = state.ws_topics.get(&key) { entry.value().clone() } else {
                                                let (tx_new, _rx_new) = broadcast::channel::<String>(128);
                                                state.ws_topics.insert(key.clone(), tx_new.clone());
                                                tx_new
                                            };
                                            let rx = tx.subscribe();
                                            session_rx.insert(key, rx);
                                        }
                                    }
                                },
                                Some("session-leave") => {
                                    if authed {
                                        if let Some(sid) = v.get("sessionId").and_then(|x| x.as_str()) {
                                            let did_opt = v.get("deviceId").and_then(|x| x.as_str());
                                            let key = if let Some(did) = did_opt { format!("{}::{}", sid, did) } else { sid.to_string() };
                                            session_rx.remove(&key);
                                        }
                                    }
                                },
                                _ => {
                                    if authed {
                                        if let Some(sid) = v.get("sessionId").and_then(|x| x.as_str()) {
                                            let did_opt = v.get("deviceId").and_then(|x| x.as_str());
                                            let key = if let Some(did) = did_opt { format!("{}::{}", sid, did) } else { sid.to_string() };
                                            if let Some(entry) = state.ws_topics.get(&key) {
                                                let _ = entry.value().send(t.clone());
                                            }
                                        } else {
                                            let _ = state.ws_tx.send(t);
                                        }
                                    }
                                }
                            }
                        } else {
                            let _ = state.ws_tx.send(t);
                        }
                    },
                    Some(Ok(Message::Binary(_b))) => {},
                    Some(Ok(Message::Close(_))) => { break; },
                    None => break,
                    _ => {}
                }
            }
        }
    }
    session_rx.clear();
}
