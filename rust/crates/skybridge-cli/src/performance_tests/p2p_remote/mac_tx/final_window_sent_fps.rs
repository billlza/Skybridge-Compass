use super::*;

const STRICT_MAC_TX_TIMING: &str = "scheduleGapMaxMs=16.7 scheduleJitterMaxMs=2.0 completionGapMaxMs=30.0 contentCallbackGapMaxMs=30.0 contentActorHopMaxMs=2.0 encodedToSubmitMaxMs=20.0 submitGapMaxMs=16.7 clockFireToDrainMaxMs=2.0";

#[test]
fn p2p_remote_mac_final_window_rejects_low_min_sent_fps_inside_final_window() -> Result<()> {
    let artifact_dir = make_test_dir("p2p-remote-final-window-mac-fps")?;
    std::fs::write(
        artifact_dir.join("ios-p2p-remote-TEST.status.log"),
        "[2026-05-15T00:00:00Z] remote-desktop pass-window-start windowSeconds=10 windowFPS=60.0 windowRxFps=60.0 frame=2056x1329\n\
         [2026-05-15T00:00:10Z] remote-desktop-pass seconds=10 requestedSeconds=10 windowSeconds=10 windowFPS=60.0 windowRxFps=60.0 windowDisplayedFrames=600 windowReceivedFrames=600 twoSecondRequiredFrames=118 min2sDisplayFrames=118 min2sRxFrames=118 rollingCadencePass=1 frame=2056x1329\n",
    )?;
    let mut mac_log = String::new();
    for second in 1..=8 {
        mac_log.push_str(&format!(
            "[2026-05-15T00:00:{second:02}Z] mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false sampleMs=1000 captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encoded=60 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=0 cadenceBatchMax=1\n"
        ));
        let sent_fps = if second == 2 { 27.6 } else { 60.0 };
        mac_log.push_str(&format!(
            "[2026-05-15T00:00:{second:02}Z] mac-remote-frame-tx transport=sbc2-chunked-v1 sampleMs=1000 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 chunkedFrames=60 sentChunks=60 maxChunksPerFrame=1 sentFPS={sent_fps:.1} maxSendMs=12.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=18 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false\n"
        ));
    }
    std::fs::write(artifact_dir.join("mac.status.log"), mac_log)?;

    let evidence = read_p2p_remote_performance_evidence(&artifact_dir)?;
    let check = check_p2p_remote_mac_final_window_fps(
        &evidence,
        59.0,
        P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS,
    );
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("finalWindowMinSentFPS=Some(27.6)"));

    let mut mac_log = String::new();
    for second in 1..=8 {
        mac_log.push_str(&format!(
            "[2026-05-15T00:00:{second:02}Z] mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false sampleMs=1000 captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encoded=60 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=0 cadenceBatchMax=1\n"
        ));
        mac_log.push_str(&format!(
            "[2026-05-15T00:00:{second:02}Z] mac-remote-frame-tx transport=sbc2-chunked-v1 sampleMs=1000 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 chunkedFrames=60 sentChunks=60 maxChunksPerFrame=1 sentFPS=60.0 maxSendMs=12.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=18 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false\n"
        ));
    }
    std::fs::write(artifact_dir.join("mac.status.log"), mac_log)?;
    let evidence = read_p2p_remote_performance_evidence(&artifact_dir)?;
    let check = check_p2p_remote_mac_final_window_fps(
        &evidence,
        59.0,
        P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS,
    );
    assert!(check.ok, "{}", check.detail);
    Ok(())
}

#[test]
fn p2p_remote_mac_final_window_rejects_repeated_source_capture_cadence() -> Result<()> {
    let artifact_dir = make_test_dir("p2p-remote-final-window-mac-capture-fps")?;
    std::fs::write(
        artifact_dir.join("ios-p2p-remote-TEST.status.log"),
        "[2026-05-15T00:00:00Z] remote-desktop pass-window-start windowSeconds=10 windowFPS=60.0 windowRxFps=60.0 frame=2056x1329\n\
         [2026-05-15T00:00:10Z] remote-desktop-pass seconds=10 requestedSeconds=10 windowSeconds=10 windowFPS=60.0 windowRxFps=60.0 windowDisplayedFrames=600 windowReceivedFrames=600 twoSecondRequiredFrames=118 min2sDisplayFrames=118 min2sRxFrames=118 rollingCadencePass=1 frame=2056x1329\n",
    )?;
    let mut mac_log = String::new();
    for second in 1..=8 {
        let capture_fps = if second == 4 { 0.3 } else { 60.0 };
        let meaningful_fps = capture_fps;
        let source_frame_repeat = if second == 4 { 60 } else { 1 };
        let source_frame_age_ms = if second == 4 { 600.0 } else { 16.7 };
        mac_log.push_str(&format!(
            "[2026-05-15T00:00:{second:02}Z] mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false sampleMs=1000 captureFPS={capture_fps:.1} meaningfulFPS={meaningful_fps:.1} captured=60 meaningful=60 sourceFrameRepeatMax={source_frame_repeat} sourceFrameAgeMaxMs={source_frame_age_ms:.1} encoded=60 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=0 cadenceBatchMax=1\n"
        ));
        mac_log.push_str(&format!(
            "[2026-05-15T00:00:{second:02}Z] mac-remote-frame-tx transport=sbc2-chunked-v1 sampleMs=1000 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 chunkedFrames=60 sentChunks=60 maxChunksPerFrame=1 sentFPS=60.0 maxSendMs=12.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=18 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false\n"
        ));
    }
    std::fs::write(artifact_dir.join("mac.status.log"), mac_log)?;

    let evidence = read_p2p_remote_performance_evidence(&artifact_dir)?;
    let check = check_p2p_remote_mac_final_window_fps(
        &evidence,
        59.0,
        P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS,
    );
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("sckSourceFrameAgeMaxMs=Some(600.0)"));
    assert!(check.detail.contains("sckSourceFrameRepeatMax=Some(60)"));
    Ok(())
}

#[test]
fn p2p_remote_mac_final_window_accepts_low_sck_capture_when_cadenced_source_is_fresh() -> Result<()>
{
    let artifact_dir = make_test_dir("p2p-remote-final-window-mac-fresh-cadence")?;
    std::fs::write(
        artifact_dir.join("ios-p2p-remote-TEST.status.log"),
        "[2026-05-15T00:00:00Z] remote-desktop pass-window-start windowSeconds=10 windowFPS=60.0 windowRxFps=60.0 frame=2056x1329\n\
         [2026-05-15T00:00:10Z] remote-desktop-pass seconds=10 requestedSeconds=10 windowSeconds=10 windowFPS=60.0 windowRxFps=60.0 windowDisplayedFrames=600 windowReceivedFrames=600 twoSecondRequiredFrames=118 min2sDisplayFrames=118 min2sRxFrames=118 rollingCadencePass=1 frame=2056x1329\n",
    )?;
    let mut mac_log = String::new();
    for second in 1..=8 {
        mac_log.push_str(&format!(
            "[2026-05-15T00:00:{second:02}Z] mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false sampleMs=1000 captureFPS=55.0 meaningfulFPS=55.0 captured=55 meaningful=55 sourceFrameRepeatMax=2 sourceFrameAgeMaxMs=25.0 encoded=60 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=0 cadenceBatchMax=1\n"
        ));
        mac_log.push_str(&format!(
            "[2026-05-15T00:00:{second:02}Z] mac-remote-frame-tx transport=sbc2-chunked-v1 sampleMs=1000 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 chunkedFrames=60 sentChunks=60 maxChunksPerFrame=1 sentFPS=60.0 maxSendMs=12.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=18 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false\n"
        ));
    }
    std::fs::write(artifact_dir.join("mac.status.log"), mac_log)?;

    let evidence = read_p2p_remote_performance_evidence(&artifact_dir)?;
    let check = check_p2p_remote_mac_final_window_fps(
        &evidence,
        59.0,
        P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS,
    );
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("finalWindowMinCaptureFPS=Some(55.0)"));
    assert!(check.detail.contains("finalWindowEncodedFPS=60.0"));
    assert!(check.detail.contains("finalWindowSentFPS=60.0"));
    Ok(())
}

#[test]
fn p2p_remote_mac_tx_rejects_final_window_sender_timing_spikes() -> Result<()> {
    let artifact_dir = make_test_dir("p2p-remote-final-window-mac-timing")?;
    std::fs::write(
        artifact_dir.join("ios-p2p-remote-TEST.status.log"),
        "[2026-05-15T00:00:00Z] remote-desktop pass-window-start windowSeconds=10 windowFPS=60.0 windowRxFps=60.0 frame=2056x1329\n\
         [2026-05-15T00:00:10Z] remote-desktop-pass seconds=10 requestedSeconds=10 windowSeconds=10 windowFPS=60.0 windowRxFps=60.0 windowDisplayedFrames=600 windowReceivedFrames=600 twoSecondRequiredFrames=118 min2sDisplayFrames=118 min2sRxFrames=118 rollingCadencePass=1 frame=2056x1329\n",
    )?;

    let mut mac_log = String::new();
    for second in 1..=8 {
        mac_log.push_str(&format!(
            "[2026-05-15T00:00:{second:02}Z] mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false sampleMs=1000 captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encoded=60 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=0 cadenceBatchMax=1\n"
        ));
        let timing = if second == 4 {
            "scheduleGapMaxMs=80.0 scheduleJitterMaxMs=2.0 completionGapMaxMs=30.0 contentCallbackGapMaxMs=30.0 contentActorHopMaxMs=2.0 encodedToSubmitMaxMs=20.0 submitGapMaxMs=16.7 clockFireToDrainMaxMs=2.0"
        } else {
            STRICT_MAC_TX_TIMING
        };
        mac_log.push_str(&format!(
            "[2026-05-15T00:00:{second:02}Z] mac-remote-frame-tx source=encoded-direct-pump transport=sbc2-chunked-v1 chunkCapBytes=262144 sampleMs=1000 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 chunkedFrames=60 sentChunks=60 maxChunksPerFrame=1 sentFPS=60.0 maxSendMs=12.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=18 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false {timing}\n"
        ));
    }
    std::fs::write(artifact_dir.join("mac.status.log"), mac_log)?;

    let evidence = read_p2p_remote_performance_evidence(&artifact_dir)?;
    let check = check_p2p_remote_mac_tx(&evidence, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("scheduleGapMaxMs=Some(80.0)"));

    let mut mac_log = String::new();
    for second in 1..=8 {
        mac_log.push_str(&format!(
            "[2026-05-15T00:00:{second:02}Z] mac-sck-tx targetFPS=60 codec=hevc capturesAudio=false sampleMs=1000 captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encoded=60 encodedFPS=60.0 encodeFailures=0 cadenceTimerFires=120 cadenceSubmitted=60 cadenceCatchUpFrames=0 cadenceBatchMax=1\n"
        ));
        mac_log.push_str(&format!(
            "[2026-05-15T00:00:{second:02}Z] mac-remote-frame-tx source=encoded-direct-pump transport=sbc2-chunked-v1 chunkCapBytes=262144 sampleMs=1000 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 chunkedFrames=60 sentChunks=60 maxChunksPerFrame=1 sentFPS=60.0 maxSendMs=12.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=18 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false {STRICT_MAC_TX_TIMING}\n"
        ));
    }
    std::fs::write(artifact_dir.join("mac.status.log"), mac_log)?;
    let evidence = read_p2p_remote_performance_evidence(&artifact_dir)?;
    let check = check_p2p_remote_mac_tx(&evidence, 59.0);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("encodedToSubmitMaxMs=Some(20.0)"));
    Ok(())
}
