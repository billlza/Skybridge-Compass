use crate::performance_evidence::extract_text_value;

use super::P2pRemotePerformanceEvidence;

pub(super) fn update_p2p_remote_route_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
    is_mac: bool,
    is_ios: bool,
) {
    if is_mac
        && (line.contains("mac-remote")
            || line.contains("mac remote")
            || line.contains("mac-stream-config"))
        && extract_text_value(line, "peer")
            .as_deref()
            .is_some_and(is_link_local_endpoint_token)
    {
        evidence.mac_link_local_peer_seen = true;
    }

    if is_ios && line.contains("ios-lan-remote-route-ready") {
        evidence.lan_route_ready_samples += 1;
        let resolved_address_class = extract_text_value(line, "resolvedAddressClass");
        let resolved_peer_to_peer =
            extract_text_value(line, "resolvedPeerToPeer").as_deref() == Some("true");
        match resolved_address_class.as_deref() {
            Some("lan-direct") if !resolved_peer_to_peer => {
                evidence.lan_resolved_direct_route_samples += 1;
            }
            Some("link-local") => evidence.lan_resolved_link_local_route_samples += 1,
            _ => {}
        }
        if resolved_peer_to_peer {
            evidence.lan_resolved_peer_to_peer_route_samples += 1;
        }
    }

    if is_ios
        && (line.contains("ios-lan-remote-route ")
            || (line.contains("LAN 远控连接候选") && line.contains("addressClass=")))
    {
        evidence.lan_route_samples += 1;
        let address_class = extract_text_value(line, "addressClass");
        let peer_to_peer = extract_text_value(line, "peerToPeer").as_deref() == Some("true");
        match address_class.as_deref() {
            Some("lan-direct") if !peer_to_peer => evidence.lan_direct_route_samples += 1,
            Some("bonjour-service") if !peer_to_peer => {
                evidence.lan_bonjour_infrastructure_route_samples += 1;
            }
            Some("link-local") => evidence.lan_link_local_route_samples += 1,
            _ => {}
        }
        if peer_to_peer {
            evidence.lan_peer_to_peer_route_samples += 1;
        }
    }
}

fn is_link_local_endpoint_token(value: &str) -> bool {
    let mut token = value
        .trim()
        .trim_start_matches("peer:")
        .trim_start_matches("host:")
        .trim_start_matches("ip:")
        .trim_matches(|c| c == '[' || c == ']')
        .to_ascii_lowercase();
    if let Some((address, _scope)) = token.split_once('%') {
        token = address.to_owned();
    }
    token.starts_with("fe80:") || token.starts_with("169.254.")
}
