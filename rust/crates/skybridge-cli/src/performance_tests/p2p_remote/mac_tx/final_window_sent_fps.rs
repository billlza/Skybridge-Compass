use super::*;

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
            "[2026-05-15T00:00:{second:02}Z] mac-remote-frame-tx transport=sbc2-chunked-v1 sampleMs=1000 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 chunkedFrames=60 sentChunks=60 maxChunksPerFrame=1 sentFPS={sent_fps:.1} maxSendMs=12.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=12 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false\n"
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
            "[2026-05-15T00:00:{second:02}Z] mac-remote-frame-tx transport=sbc2-chunked-v1 sampleMs=1000 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 chunkedFrames=60 sentChunks=60 maxChunksPerFrame=1 sentFPS=60.0 maxSendMs=12.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=12 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false\n"
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
