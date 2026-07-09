use super::*;

#[test]
fn p2p_remote_audio_zero_rx_after_playback_rejects_pre_final_terminal_close() {
    let mut pre_final_terminal_close = P2pRemotePerformanceEvidence::default();
    for (index, line) in [
        "audioRxRendererClose session=s1 reason=viewer-disconnect-stream datagramsSeen=0 recvTotal=120 decodeTotal=119 playTotal=118 probable=zero-rx-after-playback",
        "audioRxRendererClose session=s1 reason=session-authority-lost:stream-config datagramsSeen=0 recvTotal=120 decodeTotal=119 playTotal=118 probable=zero-rx-after-playback",
        "audioRxRendererClose session=s1 reason=transport-failure:fail-fast datagramsSeen=0 recvTotal=120 decodeTotal=119 playTotal=118 probable=zero-rx-after-playback",
        "audioRxStop session=s1 reason=session-authority-lost:stream-config datagramsSeen=0 recvTotal=120 decodeTotal=119 playTotal=118 probable=zero-rx-after-playback",
    ]
    .into_iter()
    .enumerate()
    {
        update_p2p_remote_evidence(&mut pre_final_terminal_close, line, false, true);
        assert_eq!(
            pre_final_terminal_close.audio_zero_rx_after_playback_samples,
            index as u64 + 1
        );
        assert_eq!(
            pre_final_terminal_close.audio_zero_datagram_after_playback_samples,
            index as u64 + 1
        );
    }

    let mut post_success_close = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut post_success_close,
        "smoke-final result=success validated=1 route=lan-main fps=59 frame=2056x1329",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut post_success_close,
        "audioRxRendererClose session=s2 reason=unspecified datagramsSeen=0 recvTotal=120 decodeTotal=119 playTotal=118 probable=zero-rx-after-playback",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut post_success_close,
        "audioRxStop session=s2 reason=viewer-stop datagramsSeen=0 recvTotal=120 decodeTotal=119 playTotal=118 probable=zero-rx-after-playback",
        false,
        true,
    );
    assert_eq!(post_success_close.audio_zero_rx_after_playback_samples, 2);
    assert_eq!(
        post_success_close.audio_zero_datagram_after_playback_samples,
        2
    );

    let mut post_verified_success_close = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut post_verified_success_close,
        "smoke-capture-source captureVerified=1 changedRatio=0.500 meanDelta=12.0",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut post_verified_success_close,
        "smoke-final result=success validated=1 route=lan-main fps=59 frame=2056x1329",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut post_verified_success_close,
        "audioRxRendererClose session=s2 reason=unspecified datagramsSeen=0 recvTotal=120 decodeTotal=119 playTotal=118 probable=zero-rx-after-playback",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut post_verified_success_close,
        "audioRxStop session=s2 reason=viewer-stop datagramsSeen=0 recvTotal=120 decodeTotal=119 playTotal=118 probable=zero-rx-after-playback",
        false,
        true,
    );
    assert_eq!(
        post_verified_success_close.audio_zero_rx_after_playback_samples,
        0
    );
    assert_eq!(
        post_verified_success_close.audio_zero_datagram_after_playback_samples,
        0
    );

    let mut post_success_non_close_zero_rx = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut post_success_non_close_zero_rx,
        "smoke-final result=success validated=1 route=lan-main fps=59 frame=2056x1329",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut post_success_non_close_zero_rx,
        "audio-rx session=s2 datagramsSeen=0 recvTotal=120 decodeTotal=119 playTotal=118 probable=zero-rx-after-playback",
        false,
        true,
    );
    assert_eq!(
        post_success_non_close_zero_rx.audio_zero_rx_after_playback_samples,
        1
    );
    assert_eq!(
        post_success_non_close_zero_rx.audio_zero_datagram_after_playback_samples,
        1
    );

    let mut in_stream_starvation = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut in_stream_starvation,
        "audio-rx session=s3 datagramsSeen=0 recvTotal=120 decodeTotal=119 playTotal=118 probable=zero-rx-after-playback",
        false,
        true,
    );
    assert_eq!(in_stream_starvation.audio_zero_rx_after_playback_samples, 1);
    assert_eq!(
        in_stream_starvation.audio_zero_datagram_after_playback_samples,
        1
    );
}

#[test]
fn p2p_remote_audio_rejects_render_fail_fast_receiver_close_zero_rx() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    seed_successful_audio_rx(&mut evidence);
    update_p2p_remote_evidence(
        &mut evidence,
        "render-main-path-failed session=s1 reason=frames-decoding-without-display attemptedFallback=sampleBufferDisplayLayer fallbackResult=forbidden transportAction=preserve audioAction=preserve",
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut evidence,
        "audioRxRendererClose session=s1 reason=render-main-path-fail-fast datagramsSeen=0 recvTotal=120 decodeTotal=119 playTotal=118 probable=zero-rx-after-playback jitterEvicted=0 playbackDrop=0 underflow=0 rebuffer=0",
        false,
        true,
    );

    let audio_check = check_p2p_remote_audio(&evidence);
    assert!(!audio_check.ok, "{}", audio_check.detail);
    assert!(audio_check.detail.contains("zeroRxAfterPlayback=1"));
    assert!(audio_check.detail.contains("zeroDatagramAfterPlayback=1"));

    let fallback_check = check_p2p_remote_no_fallback(&evidence);
    assert!(!fallback_check.ok, "{}", fallback_check.detail);
    assert!(fallback_check.detail.contains("fallbackDetected=true"));
}

#[test]
fn p2p_remote_audio_rejects_mac_shared_audio_tx_failures() {
    let mut healthy = P2pRemotePerformanceEvidence::default();
    seed_successful_audio_rx(&mut healthy);
    update_p2p_remote_evidence(
        &mut healthy,
        "mac-remote-audio-tx peer=ipad sampleMs=1000 submitted=50 sent=50 failed=0 queued=0 queuedMax=2 sentBytes=64000 backlogWarnings=0 scheduler=independent-interleaved",
        true,
        false,
    );
    let check = check_p2p_remote_audio(&healthy);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("macSharedAudioTxOk=true"));

    let mut sender_failed = P2pRemotePerformanceEvidence::default();
    seed_successful_audio_rx(&mut sender_failed);
    update_p2p_remote_evidence(
        &mut sender_failed,
        "mac-remote-audio-tx peer=ipad result=send-error queued=18 error=posix_closed",
        true,
        false,
    );
    update_p2p_remote_evidence(
        &mut sender_failed,
        "mac-remote-audio-tx peer=ipad sampleMs=1000 submitted=50 sent=0 failed=1 queued=18 queuedMax=18 sentBytes=0 backlogWarnings=1 scheduler=independent-interleaved",
        true,
        false,
    );
    let check = check_p2p_remote_audio(&sender_failed);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("macSharedAudioTxOk=false"));
    assert!(check.detail.contains("macSharedAudioTxSendErrors=1"));
    assert!(check.detail.contains("macSharedAudioTxBacklogWarnings=1"));

    let mut sender_cleared = P2pRemotePerformanceEvidence::default();
    seed_successful_audio_rx(&mut sender_cleared);
    update_p2p_remote_evidence(
        &mut sender_cleared,
        "mac-remote-audio-tx peer=ipad result=queue-cleared queued=12 reason=stream-stop",
        true,
        false,
    );
    let check = check_p2p_remote_audio(&sender_cleared);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("macSharedAudioTxQueueCleared=1"));

    let mut submit_after_close = P2pRemotePerformanceEvidence::default();
    seed_successful_audio_rx(&mut submit_after_close);
    update_p2p_remote_evidence(
        &mut submit_after_close,
        "audioTxSubmitDropped session=s1 reason=overflow started=1 closed=0 capturedTotal=20 encodedTotal=20 sentTotal=0 droppedTotal=1 endpoint=127.0.0.1:4444 mode=highFidelity",
        true,
        false,
    );
    let check = check_p2p_remote_audio(&submit_after_close);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("txSubmitDropped=1"));

    let mut terminal_submit_after_close = P2pRemotePerformanceEvidence::default();
    seed_successful_audio_rx(&mut terminal_submit_after_close);
    update_p2p_remote_evidence(
        &mut terminal_submit_after_close,
        "audioTxSubmitDropped session=s1 reason=closed started=1 closed=1 capturedTotal=20 encodedTotal=20 sentTotal=20 droppedTotal=0 endpoint=127.0.0.1:4444 mode=highFidelity",
        true,
        false,
    );
    let check = check_p2p_remote_audio(&terminal_submit_after_close);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("txSubmitDropped=0"));

    let mut lan_no_traffic_recovered = P2pRemotePerformanceEvidence::default();
    seed_successful_audio_rx(&mut lan_no_traffic_recovered);
    update_p2p_remote_evidence(
        &mut lan_no_traffic_recovered,
        "audio-rx lanNoTrafficRecovery session=s1 endpoint=127.0.0.1:4444 attempt=1 action=stream-config-republish probable=lan-endpoint-published-but-no-datagrams",
        false,
        true,
    );
    let check = check_p2p_remote_audio(&lan_no_traffic_recovered);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("noTrafficRecovery=1"));

    let mut lan_no_traffic_rebound = P2pRemotePerformanceEvidence::default();
    seed_successful_audio_rx(&mut lan_no_traffic_rebound);
    update_p2p_remote_evidence(
        &mut lan_no_traffic_rebound,
        "audio-rx lanNoTrafficRecovery session=s1 endpoint=127.0.0.1:4444 attempt=2 action=receiver-rebind probable=lan-endpoint-published-but-no-datagrams",
        false,
        true,
    );
    let check = check_p2p_remote_audio(&lan_no_traffic_rebound);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("noTrafficRecovery=1"));

    let mut recovery_without_audio_progress = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut recovery_without_audio_progress,
        "audio-rx lanNoTrafficRecovery session=s1 endpoint=127.0.0.1:4444 attempt=2 action=receiver-rebind probable=lan-endpoint-published-but-no-datagrams",
        false,
        true,
    );
    let check = check_p2p_remote_audio(&recovery_without_audio_progress);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("noTrafficRecovery=1"));
    assert!(check.detail.contains("finalAudioRecvProgress=false"));

    let mut lan_no_traffic_exhausted = P2pRemotePerformanceEvidence::default();
    seed_successful_audio_rx(&mut lan_no_traffic_exhausted);
    update_p2p_remote_evidence(
        &mut lan_no_traffic_exhausted,
        "audio-rx lanNoTrafficRecoveryExhausted session=s1 endpoint=127.0.0.1:4444 attempts=2 action=doctor-fail probable=lan-endpoint-published-but-no-datagrams",
        false,
        true,
    );
    let check = check_p2p_remote_audio(&lan_no_traffic_exhausted);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("noTrafficRecoveryExhausted=1"));
}

#[test]
fn p2p_remote_audio_counts_starved_played_total_aliases() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "audio-rx-starved session=s4 datagrams=0 receivedTotal=62 decodedTotal=62 playedTotal=61 probable=zero-rx-after-playback",
        false,
        true,
    );

    assert_eq!(evidence.audio_zero_rx_after_playback_samples, 1);
    assert_eq!(evidence.audio_zero_datagram_after_playback_samples, 1);
}

fn seed_successful_audio_rx(evidence: &mut P2pRemotePerformanceEvidence) {
    update_p2p_remote_evidence(
        evidence,
        "PQC media audio rx: datagrams=80 recv=80 decode=80 play=80 recvTotal=80 decodeTotal=80 playTotal=80 jitterEvicted=0 playbackDrop=0 underflow=0 rebuffer=0",
        false,
        true,
    );
    for line in [
        "remote-desktop status audioRxRecv=10 audioRxDecoded=10 audioRxPlayed=10 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
        "remote-desktop-pass audioRxRecv=80 audioRxDecoded=80 audioRxPlayed=80 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0",
    ] {
        update_p2p_remote_final_window_ios_evidence(evidence, line);
    }
}
