use super::*;

#[test]
fn p2p_remote_audio_requires_explicit_audio_rx_evidence() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "remote-desktop status audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
        false,
        true,
    );
    let check = check_p2p_remote_audio(&evidence);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("explicitAudioRxSamples=0"));

    update_p2p_remote_evidence(
        &mut evidence,
        "PQC media audio rx: jitterEvicted=0 playbackDrop=0 underflow=0 rebuffer=0",
        false,
        true,
    );
    let check = check_p2p_remote_audio(&evidence);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("finalAudioStatusSamples=0"));

    for line in [
        "remote-desktop status audioRxRecv=10 audioRxDecoded=8 audioRxPlayed=8 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
        "remote-desktop-pass audioRxRecv=30 audioRxDecoded=28 audioRxPlayed=28 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
    ] {
        update_p2p_remote_final_window_ios_evidence(&mut evidence, line);
    }
    let check = check_p2p_remote_audio(&evidence);
    assert!(check.ok, "{}", check.detail);
}

#[test]
fn p2p_remote_audio_rejects_early_rx_without_final_window_progress() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "PQC media audio rx: recv=40 decode=39 play=39 jitterEvicted=0 playbackDrop=0 underflow=0 rebuffer=0",
        false,
        true,
    );
    for line in [
        "remote-desktop status audioRxRecv=40 audioRxDecoded=39 audioRxPlayed=39 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
        "remote-desktop-pass audioRxRecv=40 audioRxDecoded=39 audioRxPlayed=39 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
    ] {
        update_p2p_remote_final_window_ios_evidence(&mut evidence, line);
    }

    let check = check_p2p_remote_audio(&evidence);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("finalAudioRecvProgress=false"));
    assert!(check.detail.contains("finalAudioDecodedProgress=false"));
    assert!(check.detail.contains("finalAudioPlayedProgress=false"));
}
