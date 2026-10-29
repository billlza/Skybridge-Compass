use super::*;

#[test]
fn p2p_remote_fallback_parser_ignores_fail_fast_policy_lines() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "p2p-policy allowClassicFallback=0 fallback=false",
        "remote-desktop status no_timeout_fallback legacyFallback=false strict native path",
        "media-lane fallback=false allowClassicFallback=0 legacyFallback=false",
        "remote-desktop status attemptedFallback=none fallbackResult=none strict native path",
        "remote-desktop status attemptedFallback=none fallbackResult=not-attempted action=request-sync",
        "render-continuity-deferred session=s1 reason=frames-decoding-without-display classification=display-progress-present inputFPS=10.5 displayFPS=9.8 displayedWindow=10 displayedTotal=98 metalDisplayedWindow=10 metalDisplayedTotal=98 attemptedFallback=none fallbackResult=not-attempted",
        "render-continuity-deferred session=s1 reason=frames-decoding-without-display classification=input-cadence-below-display-failure-threshold inputFPS=10.5 displayFPS=9.8 displayedWindow=10 displayedTotal=98 metalDisplayedWindow=10 metalDisplayedTotal=98 attemptedFallback=none fallbackResult=not-attempted",
        "render-continuity-deferred-action reason=frames-decoding-without-display classification=input-cadence-below-display-failure-threshold attemptedFallback=none fallbackResult=not-attempted streamRefresh=suppressed",
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
        "remote-desktop-pass pipeline=sampleBufferDisplayLayer fps=60.0 rxFps=60.0 frame=2056x1329",
        "remote-desktop status renderPipeline=sampleBufferDisplayLayer fps=60.0 strict native path",
        "remote-desktop status compatibility fallback enabled",
        "remote-desktop status classic fallback",
        "remote-desktop transport=fallback reason=main-path-unavailable",
        "remote-desktop status fallback=true",
        "remote-desktop fail-fast reason=frames-decoding-without-display attemptedFallback=sampleBufferDisplayLayer fallbackResult=forbidden phase=render_main_path",
        "render-main-path-failed session=s1 reason=frames-decoding-without-display attemptedFallback=sampleBufferDisplayLayer fallbackResult=forbidden inputFPS=10.5 displayFPS=9.8 displayedTotal=98 metalDisplayedTotal=98",
        "failed stage=remote-desktop phase=render_main_path detail=\"frames-decoding-without-display\" attemptedFallback=sampleBufferDisplayLayer fallbackResult=forbidden transportAction=preserve audioAction=preserve",
        "remote-desktop status attemptedFallback=h264 fallbackResult=activated",
    ] {
        let mut evidence = P2pRemotePerformanceEvidence::default();
        update_p2p_remote_evidence(&mut evidence, line, true, true);

        assert!(evidence.fallback_detected, "{line}");
        assert!(!check_p2p_remote_no_fallback(&evidence).ok, "{line}");
    }
}
