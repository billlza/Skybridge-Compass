use super::*;

#[test]
fn p2p_remote_lan_route_rejects_link_local_peer_to_peer_video_path() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "ios-lan-remote-route candidate=1/2 addressClass=lan-direct peerToPeer=false endpoint=192.168.1.20:5901",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "ios-lan-remote-route-ready requestedAddressClass=lan-direct resolvedAddressClass=lan-direct resolvedPeerToPeer=false requested=192.168.1.20:5901 resolved=192.168.1.20:5901",
        false,
        true,
    );
    let check = check_p2p_remote_lan_route(&evidence);
    assert!(check.ok, "{}", check.detail);

    let mut console_route_evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut console_route_evidence,
        "[02:35:53.599] [INFO] [General] 🔗 LAN 远控连接候选[1/2]: endpoint=192.168.0.106:5901 addressClass=lan-direct peerToPeer=false",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut console_route_evidence,
        "ios-lan-remote-route-ready requestedAddressClass=lan-direct resolvedAddressClass=lan-direct resolvedPeerToPeer=false requested=192.168.0.106:5901 resolved=192.168.0.106:5901",
        false,
        true,
    );
    let check = check_p2p_remote_lan_route(&console_route_evidence);
    assert!(check.ok, "{}", check.detail);

    let mut bonjour_infra_evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut bonjour_infra_evidence,
        "ios-lan-remote-route candidate=1/1 addressClass=bonjour-service peerToPeer=false endpoint=Mac._skybridge-rd._tcp.local.",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut bonjour_infra_evidence,
        "ios-lan-remote-route-ready requestedAddressClass=bonjour-service resolvedAddressClass=lan-direct resolvedPeerToPeer=false requested=Mac._skybridge-rd._tcp.local. resolved=192.168.1.20:5901",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut bonjour_infra_evidence,
        "mac-remote-frame-tx peer=peer:192.168.1.20 sentFPS=60.0",
        true,
        false,
    );
    let check = check_p2p_remote_lan_route(&bonjour_infra_evidence);
    assert!(check.ok, "{}", check.detail);

    let mut bonjour_peer_to_peer_evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut bonjour_peer_to_peer_evidence,
        "ios-lan-remote-route candidate=1/1 addressClass=bonjour-service peerToPeer=false endpoint=Mac._skybridge-rd._tcp.local.",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut bonjour_peer_to_peer_evidence,
        "ios-lan-remote-route-ready requestedAddressClass=bonjour-service resolvedAddressClass=link-local resolvedPeerToPeer=true requested=Mac._skybridge-rd._tcp.local. resolved=fe80::1%en0:5901",
        false,
        true,
    );
    let check = check_p2p_remote_lan_route(&bonjour_peer_to_peer_evidence);
    assert!(!check.ok, "{}", check.detail);

    update_p2p_remote_evidence(
        &mut evidence,
        "ios-lan-remote-route candidate=1/1 addressClass=link-local peerToPeer=true endpoint=[fe80::1%en0]:5901",
        false,
        true,
    );
    let check = check_p2p_remote_lan_route(&evidence);
    assert!(!check.ok, "{}", check.detail);

    let mut mac_peer_evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut mac_peer_evidence,
        "mac-remote-frame-tx peer=peer:fe80::1470:23a5:6005:d56d%en0 sentFPS=60.0",
        true,
        false,
    );
    let check = check_p2p_remote_lan_route(&mac_peer_evidence);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("macLinkLocalPeer=true"));
}
