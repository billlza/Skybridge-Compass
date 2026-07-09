use super::*;

#[test]
fn p2p_remote_hevc_main_path_requires_bounded_sck_cadence() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "mac-sck-first-frame codec=hevc verifiedSync=true",
        "mac-sck-encoder targetFPS=60 codec=hevc cadenceCatchUpLimit=2 maxFrameDelayCount=3 maximumRealTimeFrameRate=120 dataRateLimitBytesPerSecond=2000000 dataRateBurstLimitBytes=262004 dataRateBurstWindowMs=17 singleChunkHEVCBudgetBytes=262004 dataRateLimitsStatus=0 dataRateLimitsReadbackStatus=0 dataRateLimitsApplied=1 dataRateReadbackBurstLimitBytes=262004 dataRateReadbackBurstWindowMs=17 lowLatency=true lowLatencyRateControl=false capturesAudio=false",
        "mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=1 cadenceBatchMax=2",
    ] {
        update_p2p_remote_evidence(&mut evidence, line, true, false);
    }
    let check = check_p2p_remote_hevc_main_path(&evidence);
    assert!(check.ok, "{}", check.detail);
    assert!(
        check.detail.contains("sckLowLatencyRateControl=0/1"),
        "{}",
        check.detail
    );

    let mut transient_source_age_spike = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "mac-sck-first-frame codec=hevc verifiedSync=true",
        "mac-sck-encoder targetFPS=60 codec=hevc cadenceCatchUpLimit=2 maxFrameDelayCount=3 maximumRealTimeFrameRate=120 dataRateLimitBytesPerSecond=2000000 dataRateBurstLimitBytes=262004 dataRateBurstWindowMs=17 singleChunkHEVCBudgetBytes=262004 dataRateLimitsStatus=0 dataRateLimitsReadbackStatus=0 dataRateLimitsApplied=1 dataRateReadbackBurstLimitBytes=262004 dataRateReadbackBurstWindowMs=17 lowLatency=true lowLatencyRateControl=false capturesAudio=false",
        "mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=2 sourceFrameAgeMaxMs=38.6 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=0 cadenceBatchMax=1",
    ] {
        update_p2p_remote_evidence(&mut transient_source_age_spike, line, true, false);
    }
    let check = check_p2p_remote_hevc_main_path(&transient_source_age_spike);
    assert!(check.ok, "{}", check.detail);
    assert!(
        check
            .detail
            .contains("sckSourceFrameAgeBudgetExceeded=true")
    );
    assert!(check.detail.contains("sckSourceFrameRepeatMax=Some(2)"));

    let mut sparse_source_with_fresh_repeats = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "mac-sck-first-frame codec=hevc verifiedSync=true",
        "mac-sck-encoder targetFPS=60 codec=hevc cadenceCatchUpLimit=2 maxFrameDelayCount=3 maximumRealTimeFrameRate=120 dataRateLimitBytesPerSecond=2000000 dataRateBurstLimitBytes=262004 dataRateBurstWindowMs=17 singleChunkHEVCBudgetBytes=262004 dataRateLimitsStatus=0 dataRateLimitsReadbackStatus=0 dataRateLimitsApplied=1 dataRateReadbackBurstLimitBytes=262004 dataRateReadbackBurstWindowMs=17 lowLatency=true lowLatencyRateControl=false capturesAudio=false",
        "mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false captureFPS=53.0 meaningfulFPS=53.0 captured=53 meaningful=53 sourceFrameRepeatMax=2 sourceFrameAgeMaxMs=31.0 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=1 cadenceBatchMax=2",
    ] {
        update_p2p_remote_evidence(&mut sparse_source_with_fresh_repeats, line, true, false);
    }
    let check = check_p2p_remote_hevc_main_path(&sparse_source_with_fresh_repeats);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("sckCaptureFpsMin=Some(53.0)"));
    assert!(check.detail.contains("sckMeaningfulFpsMin=Some(53.0)"));
    assert!(check.detail.contains("minRequiredSourceFps=59.0"));

    let mut startup_waiting_sync_with_clean_final_window = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "mac-sck-first-frame codec=hevc verifiedSync=true",
        "mac-sck-encoder targetFPS=60 codec=hevc cadenceCatchUpLimit=2 maxFrameDelayCount=3 maximumRealTimeFrameRate=120 dataRateLimitBytesPerSecond=2000000 dataRateBurstLimitBytes=262004 dataRateBurstWindowMs=17 singleChunkHEVCBudgetBytes=262004 dataRateLimitsStatus=0 dataRateLimitsReadbackStatus=0 dataRateLimitsApplied=1 dataRateReadbackBurstLimitBytes=262004 dataRateReadbackBurstWindowMs=17 lowLatency=true lowLatencyRateControl=false capturesAudio=false",
        "remote-desktop-pass windowFPS=60.0 windowRxFps=60.0",
        "mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false captureFPS=53.0 meaningfulFPS=53.0 captured=53 meaningful=53 sourceFrameRepeatMax=3 sourceFrameAgeMaxMs=39.0 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=1 cadenceBatchMax=1 waitingSync=true",
    ] {
        update_p2p_remote_evidence(
            &mut startup_waiting_sync_with_clean_final_window,
            line,
            true,
            true,
        );
    }
    startup_waiting_sync_with_clean_final_window.mac_final_window_sck_samples = 1;
    startup_waiting_sync_with_clean_final_window.final_ios_remote_desktop_pass = true;
    startup_waiting_sync_with_clean_final_window.mac_final_window_min_capture_fps = Some(60.0);
    startup_waiting_sync_with_clean_final_window.mac_final_window_min_meaningful_fps = Some(60.0);
    startup_waiting_sync_with_clean_final_window.mac_final_window_sck_source_frame_age_max_ms =
        Some(24.0);
    startup_waiting_sync_with_clean_final_window.mac_final_window_sck_source_frame_repeat_max =
        Some(2);
    let check = check_p2p_remote_hevc_main_path(&startup_waiting_sync_with_clean_final_window);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("waitingSyncCleared=true"));
    assert!(check.detail.contains("finalSCKWindow=true"));
    assert!(check.detail.contains("sckSourceFrameAgeMaxMs=Some(24.0)"));

    let mut final_window_low_source_sample = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "mac-sck-first-frame codec=hevc verifiedSync=true",
        "mac-sck-encoder targetFPS=60 codec=hevc cadenceCatchUpLimit=2 maxFrameDelayCount=3 maximumRealTimeFrameRate=120 dataRateLimitBytesPerSecond=2000000 dataRateBurstLimitBytes=262004 dataRateBurstWindowMs=17 singleChunkHEVCBudgetBytes=262004 dataRateLimitsStatus=0 dataRateLimitsReadbackStatus=0 dataRateLimitsApplied=1 dataRateReadbackBurstLimitBytes=262004 dataRateReadbackBurstWindowMs=17 lowLatency=true lowLatencyRateControl=false capturesAudio=false",
        "remote-desktop-pass windowFPS=60.0 windowRxFps=60.0",
        "mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false captureFPS=53.0 meaningfulFPS=53.0 captured=53 meaningful=53 sourceFrameRepeatMax=3 sourceFrameAgeMaxMs=39.0 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=1 cadenceBatchMax=1 waitingSync=true",
    ] {
        update_p2p_remote_evidence(&mut final_window_low_source_sample, line, true, true);
    }
    final_window_low_source_sample.mac_final_window_sck_samples = 1;
    final_window_low_source_sample.final_ios_remote_desktop_pass = true;
    final_window_low_source_sample.mac_final_window_min_capture_fps = Some(56.0);
    final_window_low_source_sample.mac_final_window_min_meaningful_fps = Some(56.0);
    final_window_low_source_sample.mac_final_window_sck_source_frame_repeat_max = Some(2);
    final_window_low_source_sample.mac_final_window_sck_source_frame_age_max_ms = Some(39.2);
    let check = check_p2p_remote_hevc_main_path(&final_window_low_source_sample);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("finalSCKWindow=true"));
    assert!(check.detail.contains("sckCaptureFpsMin=Some(56.0)"));
    assert!(
        check
            .detail
            .contains("sckSourceFrameAgeBudgetExceeded=true")
    );

    let mut stale_source = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "mac-sck-first-frame codec=hevc verifiedSync=true",
        "mac-sck-encoder targetFPS=60 codec=hevc cadenceCatchUpLimit=2 maxFrameDelayCount=3 maximumRealTimeFrameRate=120 dataRateLimitBytesPerSecond=2000000 dataRateBurstLimitBytes=262004 dataRateBurstWindowMs=17 singleChunkHEVCBudgetBytes=262004 dataRateLimitsStatus=0 dataRateLimitsReadbackStatus=0 dataRateLimitsApplied=1 dataRateReadbackBurstLimitBytes=262004 dataRateReadbackBurstWindowMs=17 lowLatency=true lowLatencyRateControl=true capturesAudio=false",
        "mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false captureFPS=0.0 meaningfulFPS=0.0 captured=0 meaningful=0 sourceFrameRepeatMax=3600 sourceFrameAgeMaxMs=60000.0 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=1 cadenceBatchMax=2",
    ] {
        update_p2p_remote_evidence(&mut stale_source, line, true, false);
    }
    let check = check_p2p_remote_hevc_main_path(&stale_source);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("sckCaptureFpsMin=Some(0.0)"));
    assert!(check.detail.contains("sckSourceFrameRepeatMax=Some(3600)"));

    let mut missing_low_latency_rate_control = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "mac-sck-first-frame codec=hevc verifiedSync=true",
        "mac-sck-encoder targetFPS=60 codec=hevc cadenceCatchUpLimit=2 maxFrameDelayCount=3 maximumRealTimeFrameRate=120 dataRateLimitBytesPerSecond=2000000 dataRateBurstLimitBytes=262004 dataRateBurstWindowMs=17 singleChunkHEVCBudgetBytes=262004 dataRateLimitsStatus=0 dataRateLimitsReadbackStatus=0 dataRateLimitsApplied=1 dataRateReadbackBurstLimitBytes=262004 dataRateReadbackBurstWindowMs=17 lowLatency=true capturesAudio=false",
        "mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=1 cadenceBatchMax=2",
    ] {
        update_p2p_remote_evidence(&mut missing_low_latency_rate_control, line, true, false);
    }
    let check = check_p2p_remote_hevc_main_path(&missing_low_latency_rate_control);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("sckLowLatencyRateControl=0/0"));

    let mut single_frame_delay = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "mac-sck-first-frame codec=hevc verifiedSync=true",
        "mac-sck-encoder targetFPS=60 codec=hevc cadenceCatchUpLimit=2 maxFrameDelayCount=1 maximumRealTimeFrameRate=120 dataRateLimitBytesPerSecond=2000000 dataRateBurstLimitBytes=262004 dataRateBurstWindowMs=17 singleChunkHEVCBudgetBytes=262004 dataRateLimitsStatus=0 dataRateLimitsReadbackStatus=0 dataRateLimitsApplied=1 dataRateReadbackBurstLimitBytes=262004 dataRateReadbackBurstWindowMs=17 lowLatency=true lowLatencyRateControl=true capturesAudio=false",
        "mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=0 cadenceBatchMax=1",
    ] {
        update_p2p_remote_evidence(&mut single_frame_delay, line, true, false);
    }
    let check = check_p2p_remote_hevc_main_path(&single_frame_delay);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("sckMaxFrameDelayCount=Some(1)"));

    let mut encode_failed = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "mac-sck-first-frame codec=hevc verifiedSync=true",
        "mac-sck-encoder targetFPS=60 codec=hevc cadenceCatchUpLimit=2 maxFrameDelayCount=3 maximumRealTimeFrameRate=120 dataRateLimitBytesPerSecond=2000000 dataRateBurstLimitBytes=262004 dataRateBurstWindowMs=17 singleChunkHEVCBudgetBytes=262004 dataRateLimitsStatus=0 dataRateLimitsReadbackStatus=0 dataRateLimitsApplied=1 dataRateReadbackBurstLimitBytes=262004 dataRateReadbackBurstWindowMs=17 lowLatency=true lowLatencyRateControl=true capturesAudio=false",
        "mac-sck-encode-failed targetFPS=60 codec=hevc status=-12902 flags=0 ptsValue=1 ptsScale=1000000000 durationValue=1 durationScale=60 videoOutput=true capturesAudio=false",
        "mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=1 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=0 cadenceBatchMax=1",
    ] {
        update_p2p_remote_evidence(&mut encode_failed, line, true, false);
    }
    let check = check_p2p_remote_hevc_main_path(&encode_failed);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("sckEncodeFailures=1"));
    assert!(check.detail.contains("sckEncodeFailureLines=1"));
    assert!(check.detail.contains("sckEncodeFailureStatus=Some(-12902)"));

    let mut unbounded_cadence = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "mac-sck-first-frame codec=hevc verifiedSync=true",
        "mac-sck-encoder targetFPS=60 codec=hevc cadenceCatchUpLimit=4 maxFrameDelayCount=3 maximumRealTimeFrameRate=120 dataRateLimitBytesPerSecond=2000000 dataRateBurstLimitBytes=262004 dataRateBurstWindowMs=17 singleChunkHEVCBudgetBytes=262004 dataRateLimitsStatus=0 dataRateLimitsReadbackStatus=0 dataRateLimitsApplied=1 dataRateReadbackBurstLimitBytes=262004 dataRateReadbackBurstWindowMs=17 lowLatency=true lowLatencyRateControl=true capturesAudio=false",
        "mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=4 cadenceBatchMax=4",
    ] {
        update_p2p_remote_evidence(&mut unbounded_cadence, line, true, false);
    }
    let check = check_p2p_remote_hevc_main_path(&unbounded_cadence);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("sckCadenceCatchUpLimit=Some(4)"));
    assert!(check.detail.contains("sckCadenceBatchMax=Some(4)"));

    let mut unbounded_burst = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "mac-sck-first-frame codec=hevc verifiedSync=true",
        "mac-sck-encoder targetFPS=60 codec=hevc cadenceCatchUpLimit=2 maxFrameDelayCount=3 maximumRealTimeFrameRate=120 dataRateLimitBytesPerSecond=2000000 dataRateBurstLimitBytes=1500000 dataRateBurstWindowMs=17 singleChunkHEVCBudgetBytes=262004 dataRateLimitsStatus=0 dataRateLimitsReadbackStatus=0 dataRateLimitsApplied=1 dataRateReadbackBurstLimitBytes=1500000 dataRateReadbackBurstWindowMs=17 lowLatency=true lowLatencyRateControl=true capturesAudio=false",
        "mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=0 cadenceBatchMax=1",
    ] {
        update_p2p_remote_evidence(&mut unbounded_burst, line, true, false);
    }
    let check = check_p2p_remote_hevc_main_path(&unbounded_burst);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("sckBurstLimitBytes=Some(1500000)"));

    let mut unapplied_burst = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "mac-sck-first-frame codec=hevc verifiedSync=true",
        "mac-sck-encoder targetFPS=60 codec=hevc cadenceCatchUpLimit=2 maxFrameDelayCount=3 maximumRealTimeFrameRate=120 dataRateLimitBytesPerSecond=2000000 dataRateBurstLimitBytes=262004 dataRateBurstWindowMs=17 singleChunkHEVCBudgetBytes=262004 dataRateLimitsStatus=-12900 dataRateLimitsReadbackStatus=0 dataRateLimitsApplied=0 dataRateReadbackBurstLimitBytes=262004 dataRateReadbackBurstWindowMs=17 lowLatency=true lowLatencyRateControl=true capturesAudio=false",
        "mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=0 cadenceBatchMax=1",
    ] {
        update_p2p_remote_evidence(&mut unapplied_burst, line, true, false);
    }
    let check = check_p2p_remote_hevc_main_path(&unapplied_burst);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("dataRateLimitsStatus=Some(-12900)"));

    let mut oversized_sync = P2pRemotePerformanceEvidence::default();
    for line in [
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast",
        "mac-sck-first-frame codec=hevc verifiedSync=true",
        "mac-sck-encoder targetFPS=60 codec=hevc cadenceCatchUpLimit=2 maxFrameDelayCount=3 maximumRealTimeFrameRate=120 dataRateLimitBytesPerSecond=2000000 dataRateBurstLimitBytes=262004 dataRateBurstWindowMs=17 singleChunkHEVCBudgetBytes=262004 dataRateLimitsStatus=0 dataRateLimitsReadbackStatus=0 dataRateLimitsApplied=1 dataRateReadbackBurstLimitBytes=262004 dataRateReadbackBurstWindowMs=17 lowLatency=true lowLatencyRateControl=true capturesAudio=false",
        "mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=0 encodedFrameBytesMax=300000 encodedSyncFrameBytesMax=300000 singleChunkHEVCBudgetBytes=262004 oversizedEncodedFrames=1 oversizedSyncFrames=1 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=0 cadenceBatchMax=1",
    ] {
        update_p2p_remote_evidence(&mut oversized_sync, line, true, false);
    }
    let check = check_p2p_remote_hevc_main_path(&oversized_sync);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("sckOversizedSyncFrames=1"));
}
