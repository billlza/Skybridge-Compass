use super::*;

#[test]
fn p2p_remote_mac_tx_check_uses_latest_steady_state_fps_but_keeps_backlog_hard_failures() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "mac-sck-tx codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=39.7 encodeFailures=0",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "mac-remote-frame-tx transport=sbc2-chunked-v1 chunkCapBytes=262144 maxChunksPerFrame=1 sent=28 wireBatchSingleFrames=28 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 sentFPS=27.6 maxSendMs=80.4 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=12 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "mac-sck-tx codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=0",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "mac-remote-frame-tx transport=sbc2-chunked-v1 chunkCapBytes=262144 maxChunksPerFrame=1 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 sentFPS=60.0 maxSendMs=95.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=12 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false",
        true,
        false,
    );

    let check = check_p2p_remote_mac_tx(&evidence, 59.0);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("minSentFPS=Some(27.6)"));

    update_p2p_remote_evidence(
        &mut evidence,
        "mac-remote-frame-tx transport=sbc2-chunked-v1 chunkCapBytes=262144 maxChunksPerFrame=1 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 sentFPS=60.0 maxSendMs=95.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=1 contentBacklogMax=6 contentBacklogLimit=12 contentBacklogBytesMax=3145727 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false",
        true,
        false,
    );
    let check = check_p2p_remote_mac_tx(&evidence, 59.0);
    assert!(!check.ok, "{}", check.detail);

    let mut dropped = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut dropped,
        "mac-sck-tx codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=0",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut dropped,
        "mac-remote-frame-tx transport=sbc2-chunked-v1 chunkCapBytes=262144 maxChunksPerFrame=1 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 sentFPS=60.0 maxSendMs=12.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=1 backpressure=1 rawBackpressure=1 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=12 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false",
        true,
        false,
    );
    let check = check_p2p_remote_mac_tx(&dropped, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("dropped=1"));
    assert!(check.detail.contains("backpressure=1"));

    let mut burst_cadence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut burst_cadence,
        "mac-sck-tx codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=0",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut burst_cadence,
        "mac-remote-frame-tx transport=sbc2-chunked-v1 chunkCapBytes=262144 maxChunksPerFrame=1 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 sentFPS=60.0 maxSendMs=12.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=4 scheduleBudgetMax=4 missedCadenceSlotsMax=3 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=12 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false",
        true,
        false,
    );
    let check = check_p2p_remote_mac_tx(&burst_cadence, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("maxFramesPerDrain=Some(4)"));
    assert!(check.detail.contains("scheduleBudgetMax=Some(4)"));
    assert!(check.detail.contains("missedCadenceSlotsMax=Some(3)"));

    let mut multi_chunk = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut multi_chunk,
        "mac-sck-tx codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=0",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut multi_chunk,
        "mac-remote-frame-tx transport=sbc2-chunked-v1 chunkCapBytes=262144 maxChunksPerFrame=2 sent=60 wireBatchSingleFrames=0 wireBatchMultiFrames=60 wireSingleUnbatchedFrames=0 sentFPS=60.0 maxSendMs=12.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=12 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false",
        true,
        false,
    );
    let check = check_p2p_remote_mac_tx(&multi_chunk, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("maxChunksPerFrame=Some(2)"));

    let mut unbatched = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut unbatched,
        "mac-sck-tx codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=0",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut unbatched,
        "mac-remote-frame-tx transport=sbc2-chunked-v1 chunkCapBytes=262144 maxChunksPerFrame=1 sent=60 wireBatchSingleFrames=0 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=60 sentFPS=60.0 maxSendMs=12.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=12 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false",
        true,
        false,
    );
    let check = check_p2p_remote_mac_tx(&unbatched, 59.0);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("wireSingleUnbatchedFrames=60"));
    assert!(check.detail.contains("wireSendAll=true"));

    let mut missing_wire_batch_evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut missing_wire_batch_evidence,
        "mac-sck-tx codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=0",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut missing_wire_batch_evidence,
        "mac-remote-frame-tx transport=sbc2-chunked-v1 chunkCapBytes=262144 maxChunksPerFrame=1 sent=60 sentFPS=60.0 maxSendMs=12.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=12 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=1 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false",
        true,
        false,
    );
    let check = check_p2p_remote_mac_tx(&missing_wire_batch_evidence, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("wireSendFrames=0"));
    assert!(check.detail.contains("txSentFrames=60"));
    assert!(check.detail.contains("wireSendAll=false"));

    let mut queued_burst = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut queued_burst,
        "mac-sck-tx codec=hevc capturesAudio=false captureFPS=60.0 meaningfulFPS=60.0 captured=60 meaningful=60 sourceFrameRepeatMax=1 sourceFrameAgeMaxMs=16.7 encodedFPS=60.0 encodeFailures=0",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut queued_burst,
        "mac-remote-frame-tx transport=sbc2-chunked-v1 chunkCapBytes=262144 maxChunksPerFrame=1 sent=60 wireBatchSingleFrames=60 wireBatchMultiFrames=0 wireSingleUnbatchedFrames=0 sentFPS=60.0 maxSendMs=12.0 writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only maxFramesPerDrain=1 scheduleBudgetMax=1 missedCadenceSlotsMax=0 dropped=0 backpressure=0 rawBackpressure=0 contentBacklogFull=0 contentBacklogMax=1 contentBacklogLimit=12 contentBacklogBytesMax=8192 contentBacklogByteLimit=3145728 staleQueueCatchUp=0 queuedMax=16 queueBacklog=0 queueAgeMaxMs=12.0 waitingForSync=false",
        true,
        false,
    );
    let check = check_p2p_remote_mac_tx(&queued_burst, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("queuedMax=Some(16)"));
    assert!(check.detail.contains("queuedLimit=6"));
}
