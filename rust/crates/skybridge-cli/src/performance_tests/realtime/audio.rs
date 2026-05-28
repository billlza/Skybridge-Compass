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

#[test]
fn p2p_remote_audio_rejects_zero_rx_after_playback_evidence() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "PQC media audio rx: datagrams=60 recv=60 decode=60 play=60 recvTotal=60 decodeTotal=60 playTotal=60 jitterEvicted=0 playbackDrop=0 underflow=0 rebuffer=0",
        false,
        true,
    );
    for line in [
        "remote-desktop status audioRxRecv=10 audioRxDecoded=10 audioRxPlayed=10 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
        "remote-desktop-pass audioRxRecv=70 audioRxDecoded=70 audioRxPlayed=70 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
    ] {
        update_p2p_remote_final_window_ios_evidence(&mut evidence, line);
    }
    update_p2p_remote_evidence(
        &mut evidence,
        "audio-rx session=abc audioRxDatagrams=0 audioRxRecv=0 audioRxDecoded=0 audioRxPlayed=0 recvTotal=70 decodeTotal=70 playTotal=70 probable=zero-rx-after-playback jitterEvicted=0 playbackDrop=0 underflow=0 rebuffer=0",
        false,
        true,
    );

    let check = check_p2p_remote_audio(&evidence);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("zeroRxAfterPlayback=1"));
    assert!(check.detail.contains("zeroDatagramAfterPlayback=1"));
}

#[test]
fn p2p_remote_audio_rejects_pre_final_receiver_close_zero_rx() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "audioRxRendererClose session=abc reason=viewer-disconnect-stream datagramsSeen=0 recvTotal=70 decodeTotal=70 playTotal=70 probable=zero-rx-after-playback jitterEvicted=0 playbackDrop=0 underflow=0 rebuffer=0",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "audioRxStop session=abc reason=session-authority-lost:stream-config datagramsSeen=0 recvTotal=70 decodeTotal=70 playTotal=70 probable=zero-rx-after-playback jitterEvicted=0 playbackDrop=0 underflow=0 rebuffer=0",
        false,
        true,
    );
    for line in [
        "remote-desktop status audioRxRecv=10 audioRxDecoded=10 audioRxPlayed=10 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
        "remote-desktop-pass audioRxRecv=70 audioRxDecoded=70 audioRxPlayed=70 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
    ] {
        update_p2p_remote_final_window_ios_evidence(&mut evidence, line);
    }

    let check = check_p2p_remote_audio(&evidence);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("zeroRxAfterPlayback=2"));
    assert!(check.detail.contains("zeroDatagramAfterPlayback=2"));
}

#[test]
fn p2p_remote_audio_rejects_sender_close_before_final_success() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "audioTxSenderClose session=abc reason=screen-sharing-start-failed capturedTotal=80 encodedTotal=80 sentTotal=80 droppedTotal=0 sendFail=0 mode=highFidelity",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "PQC media audio rx: datagrams=60 recv=60 decode=60 play=60 recvTotal=60 decodeTotal=60 playTotal=60 jitterEvicted=0 playbackDrop=0 underflow=0 rebuffer=0",
        false,
        true,
    );
    for line in [
        "remote-desktop status audioRxRecv=10 audioRxDecoded=10 audioRxPlayed=10 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
        "remote-desktop-pass audioRxRecv=70 audioRxDecoded=70 audioRxPlayed=70 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
    ] {
        update_p2p_remote_final_window_ios_evidence(&mut evidence, line);
    }

    let check = check_p2p_remote_audio(&evidence);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("txSenderClose=1"));
    assert!(check.detail.contains("txSenderUnexpectedClose=1"));
}

#[test]
fn p2p_remote_audio_accepts_sender_close_after_validated_final_success() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "PQC media audio rx: datagrams=60 recv=60 decode=60 play=60 recvTotal=60 decodeTotal=60 playTotal=60 jitterEvicted=0 playbackDrop=0 underflow=0 rebuffer=0",
        false,
        true,
    );
    for line in [
        "remote-desktop status audioRxRecv=10 audioRxDecoded=10 audioRxPlayed=10 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
        "remote-desktop-pass audioRxRecv=70 audioRxDecoded=70 audioRxPlayed=70 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
    ] {
        update_p2p_remote_final_window_ios_evidence(&mut evidence, line);
    }
    update_p2p_remote_evidence(
        &mut evidence,
        "smoke-capture-source captureVerified=1 changedRatio=0.500 meanDelta=12.0",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "smoke-final result=success validated=1 route=lan-main fps=60 frame=2056x1329",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "audioTxSenderClose session=abc reason=peer-connection-closed capturedTotal=80 encodedTotal=80 sentTotal=80 droppedTotal=0 sendFail=0 mode=highFidelity",
        true,
        false,
    );

    let check = check_p2p_remote_audio(&evidence);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("txSenderClose=1"));
    assert!(check.detail.contains("txSenderUnexpectedClose=0"));
}

#[test]
fn p2p_remote_audio_accepts_receiver_close_after_validated_final_success() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "PQC media audio rx: datagrams=60 recv=60 decode=60 play=60 recvTotal=60 decodeTotal=60 playTotal=60 jitterEvicted=0 playbackDrop=0 underflow=0 rebuffer=0",
        false,
        true,
    );
    for line in [
        "remote-desktop status audioRxRecv=10 audioRxDecoded=10 audioRxPlayed=10 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
        "remote-desktop-pass audioRxRecv=70 audioRxDecoded=70 audioRxPlayed=70 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
    ] {
        update_p2p_remote_final_window_ios_evidence(&mut evidence, line);
    }
    update_p2p_remote_evidence(
        &mut evidence,
        "smoke-capture-source captureVerified=1 changedRatio=0.500 meanDelta=12.0",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "smoke-final result=success validated=1 route=lan-main fps=60 frame=2056x1329",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "audioRxRendererClose session=abc reason=viewer-disconnect-stream datagramsSeen=0 recvTotal=70 decodeTotal=70 playTotal=70 probable=zero-rx-after-playback jitterEvicted=0 playbackDrop=0 underflow=0 rebuffer=0",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "audioRxStop session=abc reason=session-authority-lost:stream-config datagramsSeen=0 recvTotal=70 decodeTotal=70 playTotal=70 probable=zero-rx-after-playback jitterEvicted=0 playbackDrop=0 underflow=0 rebuffer=0",
        false,
        true,
    );

    let check = check_p2p_remote_audio(&evidence);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("zeroRxAfterPlayback=0"));
    assert!(check.detail.contains("zeroDatagramAfterPlayback=0"));
}

#[test]
fn p2p_remote_audio_accepts_startup_underflow_when_final_window_is_clean() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "PQC media audio rx: recv=40 decode=39 play=39 jitterEvicted=0 playbackDrop=0 underflow=12 rebuffer=0",
        false,
        true,
    );
    for line in [
        "remote-desktop status audioRxRecv=10 audioRxDecoded=10 audioRxPlayed=10 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
        "remote-desktop-pass audioRxRecv=70 audioRxDecoded=70 audioRxPlayed=70 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
    ] {
        update_p2p_remote_final_window_ios_evidence(&mut evidence, line);
    }

    let check = check_p2p_remote_audio(&evidence);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("finalUnderflow=0"));
    assert!(check.detail.contains("underflow=12"));
}

#[test]
fn p2p_remote_audio_rejects_final_window_underflow() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "PQC media audio rx: recv=40 decode=39 play=39 jitterEvicted=0 playbackDrop=0 underflow=0 rebuffer=0",
        false,
        true,
    );
    for line in [
        "remote-desktop status audioRxRecv=10 audioRxDecoded=10 audioRxPlayed=10 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
        "remote-desktop-pass audioRxRecv=70 audioRxDecoded=70 audioRxPlayed=70 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=1 audioRxRebuffer=0",
    ] {
        update_p2p_remote_final_window_ios_evidence(&mut evidence, line);
    }

    let check = check_p2p_remote_audio(&evidence);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("finalUnderflow=1"));
}

#[test]
fn p2p_remote_audio_accepts_ios_renderer_close_counters() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "audioRxRendererClose session=abc reason=stop datagramsSeen=0 recv=0 decoded=0 played=0 rejected=0 mode=realDevice source=192.168.1.10:9443 probable=zero-rx-after-playback",
        false,
        true,
    );

    assert_eq!(evidence.audio_explicit_rx_samples, 1);
    assert_eq!(evidence.audio_zero_rx_after_playback_samples, 1);
}
