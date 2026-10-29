use crate::p2p_remote_performance_evidence::P2pRemotePerformanceEvidence;
use crate::{DoctorCheck, simple_doctor_check};

pub(crate) fn check_p2p_remote_decode_queue(
    evidence: &P2pRemotePerformanceEvidence,
) -> DoctorCheck {
    simple_doctor_check(
        "p2p_remote_decode_queue",
        !evidence.decode_overflow,
        if evidence.decode_overflow {
            "error"
        } else {
            "info"
        },
        format!("decodeOverflow={}", evidence.decode_overflow),
    )
}

pub(crate) fn check_p2p_remote_audio(evidence: &P2pRemotePerformanceEvidence) -> DoctorCheck {
    let final_audio_recv_progress = evidence
        .final_audio_rx_recv_min
        .zip(evidence.final_audio_rx_recv_max)
        .is_some_and(|(min, max)| max > min);
    let final_audio_decoded_progress = evidence
        .final_audio_rx_decoded_min
        .zip(evidence.final_audio_rx_decoded_max)
        .is_some_and(|(min, max)| max > min);
    let final_audio_played_progress = evidence
        .final_audio_rx_played_min
        .zip(evidence.final_audio_rx_played_max)
        .is_some_and(|(min, max)| max > min);
    let final_audio_counters_ok = evidence.final_audio_jitter_evicted == 0
        && evidence.final_audio_playback_drop == 0
        && evidence.final_audio_underflow == 0
        && evidence.final_audio_rebuffer == 0;
    let mac_shared_audio_tx_ok = evidence.mac_remote_audio_tx_samples == 0
        || (evidence.mac_remote_audio_tx_sent_payloads > 0
            && evidence.mac_remote_audio_tx_failed_payloads == 0
            && evidence.mac_remote_audio_tx_backlog_warnings == 0
            && evidence.mac_remote_audio_tx_send_error_samples == 0
            && evidence.mac_remote_audio_tx_queue_cleared_samples == 0
            && evidence.mac_remote_audio_tx_rejected_samples == 0);
    let ok = evidence.audio_status_samples > 0
        && evidence.audio_explicit_rx_samples > 0
        && evidence.final_audio_status_samples >= 2
        && final_audio_recv_progress
        && final_audio_decoded_progress
        && final_audio_played_progress
        && mac_shared_audio_tx_ok
        && evidence.audio_tx_sender_unexpected_close_samples == 0
        && evidence.audio_tx_submit_dropped_samples == 0
        && evidence.audio_no_traffic_recovery_exhausted_samples == 0
        && evidence.audio_zero_rx_after_playback_samples == 0
        && evidence.audio_zero_datagram_after_playback_samples == 0
        && final_audio_counters_ok;
    simple_doctor_check(
        "p2p_remote_audio_continuity",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "audioStatusSamples={} explicitAudioRxSamples={} macSharedAudioTxSamples={} macSharedAudioTxSubmitted={} macSharedAudioTxSent={} macSharedAudioTxFailed={} macSharedAudioTxBacklogWarnings={} macSharedAudioTxSendErrors={} macSharedAudioTxQueueCleared={} macSharedAudioTxRejected={} macSharedAudioTxOk={} txSenderClose={} txSenderUnexpectedClose={} txSubmitDropped={} noTrafficRecovery={} noTrafficRecoveryExhausted={} finalAudioStatusSamples={} finalAudioRecv={:?}->{:?} finalAudioDecoded={:?}->{:?} finalAudioPlayed={:?}->{:?} finalAudioRecvProgress={} finalAudioDecodedProgress={} finalAudioPlayedProgress={} zeroRxAfterPlayback={} zeroDatagramAfterPlayback={} finalJitterEvicted={} finalPlaybackDrop={} finalUnderflow={} finalRebuffer={} jitterEvicted={} playbackDrop={} underflow={} rebuffer={}",
            evidence.audio_status_samples,
            evidence.audio_explicit_rx_samples,
            evidence.mac_remote_audio_tx_samples,
            evidence.mac_remote_audio_tx_submitted_payloads,
            evidence.mac_remote_audio_tx_sent_payloads,
            evidence.mac_remote_audio_tx_failed_payloads,
            evidence.mac_remote_audio_tx_backlog_warnings,
            evidence.mac_remote_audio_tx_send_error_samples,
            evidence.mac_remote_audio_tx_queue_cleared_samples,
            evidence.mac_remote_audio_tx_rejected_samples,
            mac_shared_audio_tx_ok,
            evidence.audio_tx_sender_close_samples,
            evidence.audio_tx_sender_unexpected_close_samples,
            evidence.audio_tx_submit_dropped_samples,
            evidence.audio_no_traffic_recovery_samples,
            evidence.audio_no_traffic_recovery_exhausted_samples,
            evidence.final_audio_status_samples,
            evidence.final_audio_rx_recv_min,
            evidence.final_audio_rx_recv_max,
            evidence.final_audio_rx_decoded_min,
            evidence.final_audio_rx_decoded_max,
            evidence.final_audio_rx_played_min,
            evidence.final_audio_rx_played_max,
            final_audio_recv_progress,
            final_audio_decoded_progress,
            final_audio_played_progress,
            evidence.audio_zero_rx_after_playback_samples,
            evidence.audio_zero_datagram_after_playback_samples,
            evidence.final_audio_jitter_evicted,
            evidence.final_audio_playback_drop,
            evidence.final_audio_underflow,
            evidence.final_audio_rebuffer,
            evidence.audio_jitter_evicted,
            evidence.audio_playback_drop,
            evidence.audio_underflow,
            evidence.audio_rebuffer
        ),
    )
}
