use super::*;

#[test]
fn p2p_remote_artifact_prefers_mac_status_log_over_stdout_noise() -> Result<()> {
    let artifact_dir = make_test_dir("p2p-remote-status-preferred")?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "mac-remote-frame-tx source=encoded-direct-pump transport=sbc2-chunked-v1 chunkCapBytes=262144 maxChunksPerFrame=1 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 sentFPS=60.0 maxSendMs=1.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=18 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false\n",
    )?;
    std::fs::write(
        artifact_dir.join("mac.stdout.log"),
        "mac-remote-frame-tx source=encoded-direct-pump transport=sbc2-chunked-v1 chunkCapBytes=262144 maxChunksPerFrame=1 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 sentFPS=60.0 maxSendMs=900.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=99 contentBacklogMax=6 contentBacklogLimit=18 contentBacklogBytesMax=1572864 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false\n",
    )?;
    std::fs::write(
        artifact_dir.join("mac-ui.status.log"),
        "mac-online-device-ui targetFamily=ipad visible=1 status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-p2p-remote-TEST.status.log"),
        "remote-desktop-pass fps=60.0 rxFps=60.0 frame=2056x1329\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-p2p-remote-TEST.console.status.log"),
        "remote-desktop-pass fps=1.0 rxFps=1.0 frame=1x1\n",
    )?;

    let files = p2p_remote_performance_files(&artifact_dir)?;
    let names = files
        .iter()
        .filter_map(|path| path.file_name().and_then(|value| value.to_str()))
        .collect::<Vec<_>>();

    assert!(names.contains(&"mac.status.log"));
    assert!(names.contains(&"mac-ui.status.log"));
    assert!(!names.contains(&"mac.stdout.log"));
    assert!(names.contains(&"ios-p2p-remote-TEST.status.log"));
    assert!(!names.contains(&"ios-p2p-remote-TEST.console.status.log"));
    Ok(())
}

#[test]
fn p2p_remote_artifact_accepts_ios_console_status_as_fallback_source() -> Result<()> {
    let artifact_dir = make_test_dir("p2p-remote-ios-console-fallback")?;
    std::fs::write(
        artifact_dir.join("mac-online-ipad.status.log"),
        "mac-online-device-ui targetFamily=ipad visible=1 status=online buttonEnabled=1 matchStrength=stable-id resolvedSource=skybridgeBonjour controlEndpoint=1 candidateCount=1\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-console.status.log"),
        "[DEBUG] [General] iCloud KVS 在线心跳已发布: iPad\n",
    )?;

    let files = p2p_remote_performance_files(&artifact_dir)?;
    let names = files
        .iter()
        .filter_map(|path| path.file_name().and_then(|value| value.to_str()))
        .collect::<Vec<_>>();

    assert!(names.contains(&"mac-online-ipad.status.log"));
    assert!(names.contains(&"ios-console.status.log"));
    Ok(())
}
