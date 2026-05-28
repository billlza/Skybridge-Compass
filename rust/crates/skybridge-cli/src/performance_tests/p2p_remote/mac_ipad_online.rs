use super::*;

#[test]
fn mac_ipad_online_connect_button_accepts_strong_online_row_and_real_endpoint() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    add_required_mac_ipad_online_connect_evidence(&mut evidence);

    let check = check_p2p_remote_mac_ipad_online_connect_button(&evidence);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("iosIpadHeartbeat=1"));
    assert!(check.detail.contains("dashboardRoleBoot=1"));
    assert!(check.detail.contains("macOnlineRows=1"));
    assert!(check.detail.contains("realRowSourceRows=1"));
    assert!(check.detail.contains("connectableEnabledRows=1"));
    assert!(check.detail.contains("buttonSourceClicks=1"));
    assert!(check.detail.contains("realEndpointSamples=1"));
    assert!(check.detail.contains("connectSuccess=1"));
    assert!(check.detail.contains("connectFailure=0"));
    assert!(
        check
            .detail
            .contains("orderedIdentity=identityKey:ipad-stable-1")
    );
}

#[test]
fn mac_ipad_online_connect_button_accepts_external_ax_click_with_endpoint_in_connect_result() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut evidence);
    update_p2p_remote_evidence(
        &mut evidence,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id identityKey=ipad-stable-1",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 identityKey=ipad-stable-1",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "mac-online-connect-start action=button targetFamily=ipad source=OnlineDeviceCard evidenceSource=external-ax clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 identityKey=ipad-stable-1",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "mac-online-connect-result action=button targetFamily=ipad result=success source=OnlineDeviceCard evidenceSource=external-ax observer=accessibility targetRowBound=1 status=connected identityKey=ipad-stable-1",
        true,
        false,
    );

    let check = check_p2p_remote_mac_ipad_online_connect_button(&evidence);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("buttonSourceClicks=1"));
    assert!(check.detail.contains("realEndpointSamples=0"));
    assert!(
        check
            .detail
            .contains("orderedIdentity=identityKey:ipad-stable-1")
    );
}

#[test]
fn mac_ipad_online_connect_button_rejects_duplicate_physical_device_rows() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut evidence);
    update_p2p_remote_evidence(
        &mut evidence,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeCloud controlEndpoint=1 candidateCount=1 dedupeKey=ipad-physical-1 identityKey=serial:icloud-device-chain-ipad",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 dedupeKey=ipad-physical-1 identityKey=bonjour:ziang-ipad.local",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeUSB controlEndpoint=1 candidateCount=1 dedupeKey=ipad-physical-1 identityKey=serial:00008103-0011223344556677",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 dedupeKey=ipad-physical-1 identityKey=bonjour:ziang-ipad.local",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 dedupeKey=ipad-physical-1 identityKey=bonjour:ziang-ipad.local",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 dedupeKey=ipad-physical-1 identityKey=bonjour:ziang-ipad.local",
        ),
        true,
        false,
    );

    let check = check_p2p_remote_mac_ipad_online_connect_button(&evidence);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("macOnlineRows=3"));
    assert!(
        check
            .detail
            .contains("duplicatePhysicalRows=physical:ipad-physical-1")
    );
}

#[test]
fn mac_ipad_online_connect_button_rejects_duplicate_presentation_rows_without_dedupe_key() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut evidence);
    update_p2p_remote_evidence(
        &mut evidence,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    for identity in [
        "serial:icloud-device-chain-ipad",
        "bonjour:ziang-ipad.local",
        "serial:00008103-0011223344556677",
    ] {
        update_p2p_remote_evidence(
            &mut evidence,
            &with_real_bonjour_route(&format!(
                "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 device=ZiangdeIPad model=iPadPro identityKey={identity}",
            )),
            true,
            false,
        );
    }
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 device=ZiangdeIPad model=iPadPro identityKey=bonjour:ziang-ipad.local",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 device=ZiangdeIPad model=iPadPro identityKey=bonjour:ziang-ipad.local",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 device=ZiangdeIPad model=iPadPro identityKey=bonjour:ziang-ipad.local",
        ),
        true,
        false,
    );

    let check = check_p2p_remote_mac_ipad_online_connect_button(&evidence);
    assert!(!check.ok, "{}", check.detail);
    assert!(
        check
            .detail
            .contains("duplicatePhysicalRows=presentation:ipad:ziangdeipad:ipadpro")
    );
}

#[test]
fn mac_ipad_online_connect_button_rejects_same_identity_rendered_multiple_times() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut evidence);
    update_p2p_remote_evidence(
        &mut evidence,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    for surface in ["connected", "recent", "online"] {
        update_p2p_remote_evidence(
            &mut evidence,
            &with_real_bonjour_route(&format!(
                "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=app-smoke surface={surface} status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=id:ipad-stable-1"
            )),
            true,
            false,
        );
    }
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=id:ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=id:ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=id:ipad-stable-1",
        ),
        true,
        false,
    );

    let check = check_p2p_remote_mac_ipad_online_connect_button(&evidence);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("macOnlineRows=3"));
    assert!(
        check
            .detail
            .contains("duplicatePhysicalRows=identityKey:id:ipad-stable-1:rows=3")
    );
}

#[test]
fn mac_ipad_online_connect_button_rejects_mixed_trusted_cloud_and_online_rows_for_same_ipad() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut evidence);
    update_p2p_remote_evidence(
        &mut evidence,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: Ziang的iPad",
        false,
        true,
    );
    for row in [
        "mac-ipad-cloud-device-ui targetFamily=ipad visible=1 source=CloudDeviceCard evidenceSource=app-smoke status=offline buttonEnabled=0 dedupeKey=ziangdeipad-ipad device=ZiangdeIPad model=iPad identityKey=id:ipad-stable-1",
        "mac-ipad-trusted-device-ui targetFamily=ipad visible=1 source=TrustedDeviceCard evidenceSource=app-smoke status=connected buttonEnabled=0 dedupeKey=ziangdeipad-ipad device=ZiangdeIPad model=iPad identityKey=id:ipad-stable-1",
        "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=app-smoke status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 dedupeKey=ziangdeipad-ipad device=ZiangdeIPad model=iPad identityKey=id:ipad-stable-1",
    ] {
        update_p2p_remote_evidence(&mut evidence, &with_real_bonjour_route(row), true, false);
    }
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=id:ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=id:ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=id:ipad-stable-1",
        ),
        true,
        false,
    );

    let check = check_p2p_remote_mac_ipad_online_connect_button(&evidence);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("macOnlineRows=3"));
    assert!(
        check
            .detail
            .contains("duplicatePhysicalRows=physical:ziangdeipad-ipad:rows=3")
    );
}

#[test]
fn mac_ipad_online_connect_button_rejects_display_only_or_fake_connect() {
    let mut display_only = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut display_only);
    update_p2p_remote_evidence(
        &mut display_only,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut display_only,
        "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        true,
        false,
    );

    let display_only_check = check_p2p_remote_mac_ipad_online_connect_button(&display_only);
    assert!(!display_only_check.ok, "{}", display_only_check.detail);
    assert!(display_only_check.detail.contains("connectClicks=0"));
    assert!(display_only_check.detail.contains("connectStarts=0"));

    let mut programmatic_only = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut programmatic_only);
    update_p2p_remote_evidence(
        &mut programmatic_only,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut programmatic_only,
        &with_real_bonjour_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut programmatic_only,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=ProgrammaticConnect resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut programmatic_only,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut programmatic_only,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );

    let view_model_only_check = check_p2p_remote_mac_ipad_online_connect_button(&programmatic_only);
    assert!(
        !view_model_only_check.ok,
        "{}",
        view_model_only_check.detail
    );
    assert!(
        view_model_only_check
            .detail
            .contains("buttonSourceClicks=0")
    );
    assert!(
        view_model_only_check
            .detail
            .contains("realEndpointSamples=0")
    );

    let mut app_emitted_click = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut app_emitted_click);
    update_p2p_remote_evidence(
        &mut app_emitted_click,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut app_emitted_click,
        &with_real_bonjour_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut app_emitted_click,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut app_emitted_click,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut app_emitted_click,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );

    let app_emitted_click_check =
        check_p2p_remote_mac_ipad_online_connect_button(&app_emitted_click);
    assert!(
        !app_emitted_click_check.ok,
        "{}",
        app_emitted_click_check.detail
    );
    assert!(app_emitted_click_check.detail.contains("connectClicks=1"));
    assert!(
        app_emitted_click_check
            .detail
            .contains("buttonSourceClicks=0")
    );

    let mut unbound_accessibility_click = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut unbound_accessibility_click);
    update_p2p_remote_evidence(
        &mut unbound_accessibility_click,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut unbound_accessibility_click,
        &with_real_bonjour_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut unbound_accessibility_click,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=0 resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut unbound_accessibility_click,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut unbound_accessibility_click,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );

    let unbound_accessibility_click_check =
        check_p2p_remote_mac_ipad_online_connect_button(&unbound_accessibility_click);
    assert!(
        !unbound_accessibility_click_check.ok,
        "{}",
        unbound_accessibility_click_check.detail
    );
    assert!(
        unbound_accessibility_click_check
            .detail
            .contains("connectClicks=1")
    );
    assert!(
        unbound_accessibility_click_check
            .detail
            .contains("buttonSourceClicks=0")
    );

    let mut cloud_only = P2pRemotePerformanceEvidence::default();
    add_required_mac_ipad_online_connect_evidence(&mut cloud_only);
    update_p2p_remote_evidence(
        &mut cloud_only,
        "mac-online-connect action=button targetFamily=ipad source=CloudDeviceList resolvedSource=skybridgeCloud controlEndpoint=0 candidateCount=0 noConnectableEndpoint=1",
        true,
        false,
    );

    let cloud_only_check = check_p2p_remote_mac_ipad_online_connect_button(&cloud_only);
    assert!(!cloud_only_check.ok, "{}", cloud_only_check.detail);
    assert!(cloud_only_check.detail.contains("noEndpointFailures=1"));

    let mut weak_match = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut weak_match);
    update_p2p_remote_evidence(
        &mut weak_match,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut weak_match,
        &with_real_bonjour_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=name resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut weak_match,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut weak_match,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut weak_match,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );

    let weak_match_check = check_p2p_remote_mac_ipad_online_connect_button(&weak_match);
    assert!(!weak_match_check.ok, "{}", weak_match_check.detail);
    assert!(weak_match_check.detail.contains("strongMatchRows=0"));
    assert!(weak_match_check.detail.contains("weakMatchRows=1"));

    let mut split_evidence = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut split_evidence);
    update_p2p_remote_evidence(
        &mut split_evidence,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut split_evidence,
        "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeCloud controlEndpoint=0 candidateCount=0 identityKey=ipad-stable-1",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut split_evidence,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut split_evidence,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );

    let split_evidence_check = check_p2p_remote_mac_ipad_online_connect_button(&split_evidence);
    assert!(!split_evidence_check.ok, "{}", split_evidence_check.detail);
    assert!(
        split_evidence_check
            .detail
            .contains("connectableEnabledRows=0")
    );

    let mut identity_as_route = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut identity_as_route);
    update_p2p_remote_evidence(
        &mut identity_as_route,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut identity_as_route,
        &with_invalid_identity_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut identity_as_route,
        &with_invalid_identity_route(
            "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut identity_as_route,
        &with_invalid_identity_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut identity_as_route,
        &with_invalid_identity_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );

    let identity_as_route_check =
        check_p2p_remote_mac_ipad_online_connect_button(&identity_as_route);
    assert!(
        !identity_as_route_check.ok,
        "{}",
        identity_as_route_check.detail
    );
    assert!(
        identity_as_route_check
            .detail
            .contains("connectableEnabledRows=0")
    );
    assert!(identity_as_route_check.detail.contains("connectStarts=0"));
}

#[test]
fn mac_ipad_online_connect_button_rejects_mismatched_or_unsuccessful_click_chain() {
    let mut mismatch = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut mismatch);
    update_p2p_remote_evidence(
        &mut mismatch,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut mismatch,
        &with_real_bonjour_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-a",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut mismatch,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-b",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut mismatch,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-b",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut mismatch,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-b",
        ),
        true,
        false,
    );

    let check = check_p2p_remote_mac_ipad_online_connect_button(&mismatch);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("orderedIdentity=-"));
    assert!(check.detail.contains("rowIdentities=1"));
    assert!(check.detail.contains("successIdentities=1"));

    let mut cross_surface = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut cross_surface);
    update_p2p_remote_evidence(
        &mut cross_surface,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut cross_surface,
        &with_real_bonjour_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut cross_surface,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=CloudDeviceList resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut cross_surface,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut cross_surface,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );

    let check = check_p2p_remote_mac_ipad_online_connect_button(&cross_surface);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("orderedIdentity=-"));
    assert!(check.detail.contains("rowIdentities=1"));
    assert!(check.detail.contains("buttonSourceClicks=0"));
    assert!(check.detail.contains("clickIdentities=0"));

    let mut failed_result = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut failed_result);
    update_p2p_remote_evidence(
        &mut failed_result,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut failed_result,
        &with_real_bonjour_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut failed_result,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut failed_result,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut failed_result,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=failure resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );

    let check = check_p2p_remote_mac_ipad_online_connect_button(&failed_result);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("connectSuccess=0"));
    assert!(check.detail.contains("connectFailure=1"));

    let mut unconfirmed_ax_result = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut unconfirmed_ax_result);
    update_p2p_remote_evidence(
        &mut unconfirmed_ax_result,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut unconfirmed_ax_result,
        "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id identityKey=ipad-stable-1",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut unconfirmed_ax_result,
        "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 identityKey=ipad-stable-1",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut unconfirmed_ax_result,
        "mac-online-connect-start action=button targetFamily=ipad source=OnlineDeviceCard evidenceSource=external-ax clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 identityKey=ipad-stable-1",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut unconfirmed_ax_result,
        "mac-online-connect-result action=button targetFamily=ipad result=success source=OnlineDeviceCard evidenceSource=external-ax observer=accessibility targetRowBound=1 status=online identityKey=ipad-stable-1",
        true,
        false,
    );

    let check = check_p2p_remote_mac_ipad_online_connect_button(&unconfirmed_ax_result);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("connectSuccess=0"));
    assert!(check.detail.contains("connectFailure=1"));

    let mut failure_then_success = P2pRemotePerformanceEvidence::default();
    add_dashboard_boot(&mut failure_then_success);
    update_p2p_remote_evidence(
        &mut failure_then_success,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut failure_then_success,
        &with_real_bonjour_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut failure_then_success,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut failure_then_success,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut failure_then_success,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=failure resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut failure_then_success,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );

    let check = check_p2p_remote_mac_ipad_online_connect_button(&failure_then_success);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("connectSuccess=1"));
    assert!(check.detail.contains("connectFailure=1"));
}

#[test]
fn mac_ipad_online_connect_button_rejects_non_dashboard_or_non_row_sources() {
    let mut local_host_like = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut local_host_like,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut local_host_like,
        "boot role=mac-host process=LocalLanInteropHost uiRole=headless",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut local_host_like,
        &with_real_bonjour_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=LocalLanInteropHost status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut local_host_like,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=LocalLanInteropHost resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut local_host_like,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut local_host_like,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );

    let check = check_p2p_remote_mac_ipad_online_connect_button(&local_host_like);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("dashboardRoleBoot=0"));
    assert!(check.detail.contains("realRowSourceRows=0"));
    assert!(check.detail.contains("buttonSourceClicks=0"));
    assert!(check.detail.contains("orderedIdentity=-"));
}

#[test]
fn mac_ipad_online_connect_button_rejects_script_only_launch_marker_as_dashboard_boot() {
    let mut script_only_launch = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut script_only_launch,
        "launch requested role=mac-online-ipad-client process=SkyBridgeCompassApp uiRole=external-accessibility method=open-app-bundle",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut script_only_launch,
        "boot role=mac-online-ipad-client process=SkyBridgeCompassApp uiRole=external-accessibility",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut script_only_launch,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut script_only_launch,
        &with_real_bonjour_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut script_only_launch,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut script_only_launch,
        &with_real_bonjour_route(
            "mac-online-connect-start action=button targetFamily=ipad source=OnlineDeviceCard evidenceSource=external-ax clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut script_only_launch,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success source=OnlineDeviceCard evidenceSource=external-ax observer=accessibility targetRowBound=1 status=connected resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );

    let check = check_p2p_remote_mac_ipad_online_connect_button(&script_only_launch);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("dashboardRoleBoot=0"));
    assert!(check.detail.contains("connectSuccess=1"));
    assert!(
        check
            .detail
            .contains("orderedIdentity=identityKey:ipad-stable-1")
    );
}

fn add_required_mac_ipad_online_connect_evidence(evidence: &mut P2pRemotePerformanceEvidence) {
    add_dashboard_boot(evidence);
    update_p2p_remote_evidence(
        evidence,
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad",
        false,
        true,
    );
    update_p2p_remote_evidence(
        evidence,
        &with_real_bonjour_route(
            "mac-online-device-ui targetFamily=ipad visible=1 source=OnlineDeviceCard evidenceSource=external-ax status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        evidence,
        &with_real_bonjour_route(
            "mac-online-connect action=button targetFamily=ipad source=OnlineDeviceCard clickSource=accessibility clickMechanism=AXUIElementPerformAction targetRowBound=1 resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        evidence,
        &with_real_bonjour_route(
            "mac-online-connect-start targetFamily=ipad resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
    update_p2p_remote_evidence(
        evidence,
        &with_real_bonjour_route(
            "mac-online-connect-result action=button targetFamily=ipad result=success resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1 identityKey=ipad-stable-1",
        ),
        true,
        false,
    );
}

fn with_real_bonjour_route(line: &str) -> String {
    format!(
        "{line} service=_skybridge._tcp bonjourServiceName=iPad endpointHost=- endpointPort=9527"
    )
}

fn with_invalid_identity_route(line: &str) -> String {
    format!(
        "{line} service=_skybridge._tcp bonjourServiceName=id:ipad-stable-1 endpointHost=- endpointPort=9527"
    )
}

fn add_dashboard_boot(evidence: &mut P2pRemotePerformanceEvidence) {
    update_p2p_remote_evidence(
        evidence,
        "boot role=mac-online-ipad-client process=SkyBridgeCompassApp uiRole=root-container",
        true,
        false,
    );
}
