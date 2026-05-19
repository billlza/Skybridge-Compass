use super::*;

#[test]
fn p2p_remote_ios_window_requires_two_second_cadence_evidence() {
    let mut passing = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut passing,
        "remote-desktop-pass fps=60.0 rxFps=60.0 windowSeconds=10.0 windowFPS=60.0 windowRxFps=60.0 min2sDisplayFrames=118 min2sRxFrames=118 twoSecondRequiredFrames=118 rollingDisplayCadencePass=1 rollingRxCadencePass=1 rollingCombinedCadencePass=1 rollingCadencePass=1 pass=1 frame=2056x1329",
        false,
        true,
    );
    let check = check_p2p_remote_ios_window_fps(&passing, 59.0);
    assert!(check.ok, "{}", check.detail);

    let mut rx_drop = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut rx_drop,
        "remote-desktop-pass fps=60.0 rxFps=60.0 windowSeconds=10.0 windowFPS=60.0 windowRxFps=60.0 min2sDisplayFrames=118 min2sRxFrames=110 twoSecondRequiredFrames=118 rollingDisplayCadencePass=1 rollingRxCadencePass=0 rollingCombinedCadencePass=0 rollingCadencePass=0 pass=1 frame=2056x1329",
        false,
        true,
    );
    let check = check_p2p_remote_ios_window_fps(&rx_drop, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("min2sRxFrames=Some(110)"));

    let mut combined_drop = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut combined_drop,
        "remote-desktop-pass fps=60.0 rxFps=60.0 windowSeconds=10.0 windowFPS=60.0 windowRxFps=60.0 min2sDisplayFrames=118 min2sRxFrames=118 twoSecondRequiredFrames=118 rollingDisplayCadencePass=1 rollingRxCadencePass=0 rollingCombinedCadencePass=0 rollingCadencePass=0 pass=1 frame=2056x1329",
        false,
        true,
    );
    let check = check_p2p_remote_ios_window_fps(&combined_drop, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("displayCadenceFailures=1"));

    let mut display_drop = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut display_drop,
        "remote-desktop status fps=60.0 rxFps=60.0 windowSeconds=2.2 windowFPS=60.0 windowRxFps=60.0 min2sDisplayFrames=117 min2sRxFrames=118 twoSecondRequiredFrames=118 rollingDisplayCadencePass=0 rollingRxCadencePass=1 rollingCadencePass=0 pass=0 frame=2056x1329",
        false,
        true,
    );
    let check = check_p2p_remote_ios_window_fps(&display_drop, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("displayCadenceFailures=1"));
    assert!(check.detail.contains("min2sDisplayFrames=Some(117)"));
}
