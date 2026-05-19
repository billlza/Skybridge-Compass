use super::*;

#[test]
fn p2p_remote_timing_correlation_requires_sender_and_receiver_timestamps() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "mac-remote-frame-tx source=encoded-direct-pump writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only sentFPS=60.0 scheduleGapMaxMs=18.0 scheduleJitterMaxMs=2.0 completionGapMaxMs=24.0 contentCallbackGapMaxMs=24.0 contentActorHopMaxMs=1.0 clockFireToDrainMaxMs=1.0 encodedToSubmitMaxMs=4.0 submitGapMaxMs=18.0",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "ios-lan-remote-rx sourceSamples=60 sourceGapMaxMs=18.0 sourceToReadMaxMs=42.0 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 completeFramesPerDrainMax=4",
        false,
        true,
    );

    let check = check_p2p_remote_timing_correlation(&evidence, 59.0);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("iosSourceSamples=60"));

    update_p2p_remote_evidence(
        &mut evidence,
        "ios-lan-remote-rx sourceSamples=60 sourceGapMaxMs=142.0 sourceToReadMaxMs=142.0 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 completeFramesPerDrainMax=4",
        false,
        true,
    );
    let check = check_p2p_remote_timing_correlation(&evidence, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("iosSourceToReadMaxMs=142.0"));

    let mut unsynced_clock_evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut unsynced_clock_evidence,
        "mac-remote-frame-tx source=encoded-direct-pump writerClock=dispatch-source-userinteractive sendScheduler=dispatch-clock-only sentFPS=60.0 scheduleGapMaxMs=18.0 scheduleJitterMaxMs=2.0 completionGapMaxMs=24.0 contentCallbackGapMaxMs=24.0 contentActorHopMaxMs=1.0 clockFireToDrainMaxMs=1.0 encodedToSubmitMaxMs=4.0 submitGapMaxMs=18.0",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut unsynced_clock_evidence,
        "ios-lan-remote-rx sourceSamples=60 sourceGapMaxMs=18.0 sourceToReadMaxMs=342.0 sourceToReadClock=remote-wall-clock-unsynced rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 completeFramesPerDrainMax=4",
        false,
        true,
    );
    let check = check_p2p_remote_timing_correlation(&unsynced_clock_evidence, 59.0);
    assert!(check.ok, "{}", check.detail);
    assert!(
        check
            .detail
            .contains("iosSourceToReadUnsyncedClockSamples=1")
    );
}
