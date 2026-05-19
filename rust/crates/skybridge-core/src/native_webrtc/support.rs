use std::net::{IpAddr, UdpSocket};
use std::time::{SystemTime, UNIX_EPOCH};

use webrtc::peer_connection::RTCIceServer;

use crate::TurnCredentials;

pub(super) fn build_ice_servers(turn_credentials: Option<&TurnCredentials>) -> Vec<RTCIceServer> {
    match turn_credentials {
        Some(credentials) if !credentials.uris.is_empty() => vec![RTCIceServer {
            urls: credentials.uris.clone(),
            username: credentials.username.clone(),
            credential: credentials.password.clone(),
        }],
        _ => Vec::new(),
    }
}

pub(super) fn native_webrtc_udp_bind_addrs() -> Vec<String> {
    if let Ok(raw_addrs) = std::env::var("SKYBRIDGE_NATIVE_WEBRTC_UDP_ADDRS") {
        let configured = raw_addrs
            .split(',')
            .map(str::trim)
            .filter(|addr| !addr.is_empty())
            .map(ToOwned::to_owned)
            .collect::<Vec<_>>();
        if !configured.is_empty() {
            return configured;
        }
    }

    let mut addrs = Vec::new();
    push_unique_addr(&mut addrs, "127.0.0.1:0".to_owned());
    if let Some(primary_addr) = primary_ipv4_udp_bind_addr() {
        push_unique_addr(&mut addrs, primary_addr);
    }
    addrs
}

fn primary_ipv4_udp_bind_addr() -> Option<String> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    let local_addr = socket.local_addr().ok()?;
    match local_addr.ip() {
        IpAddr::V4(ip) if !ip.is_unspecified() && !ip.is_loopback() => Some(format!("{ip}:0")),
        _ => None,
    }
}

fn push_unique_addr(addrs: &mut Vec<String>, addr: String) {
    if !addrs.iter().any(|existing| existing == &addr) {
        addrs.push(addr);
    }
}

pub(super) fn now_unix_seconds() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or_default()
}
