use super::*;

#[test]
fn p2p_remote_fallback_parser_ignores_fail_fast_policy_lines() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "p2p-policy allowClassicFallback=0 fallback=false",
        "remote-desktop status no_timeout_fallback legacyFallback=false strict native path",
        "media-lane fallback=false allowClassicFallback=0 legacyFallback=false",
    ] {
        update_p2p_remote_evidence(&mut evidence, line, true, true);
    }

    assert!(evidence.fail_fast_configured);
    assert!(!evidence.fallback_detected);
    assert!(check_p2p_remote_no_fallback(&evidence).ok);
}

#[test]
fn p2p_remote_fallback_parser_flags_real_fallback_lines() {
    for line in [
        "HEVC 连续失败临时降级 H.264",
        "stream-stats fallbackProducer=cgdisplayEmergency",
        "stream-stats fallback producer=cgdisplayEmergency",
        "remote-desktop status pipeline=stillImageFallback",
        "remote-desktop status compatibility fallback enabled",
        "remote-desktop status classic fallback",
        "remote-desktop transport=fallback reason=main-path-unavailable",
        "remote-desktop status fallback=true",
    ] {
        let mut evidence = P2pRemotePerformanceEvidence::default();
        update_p2p_remote_evidence(&mut evidence, line, true, true);

        assert!(evidence.fallback_detected, "{line}");
        assert!(!check_p2p_remote_no_fallback(&evidence).ok, "{line}");
    }
}
