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
    let ok = evidence.audio_status_samples > 0
        && evidence.audio_explicit_rx_samples > 0
        && evidence.final_audio_status_samples >= 2
        && final_audio_recv_progress
        && final_audio_decoded_progress
        && final_audio_played_progress
        && evidence.audio_jitter_evicted == 0
        && evidence.audio_playback_drop == 0
        && evidence.audio_underflow == 0
        && evidence.audio_rebuffer == 0;
    simple_doctor_check(
        "p2p_remote_audio_continuity",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "audioStatusSamples={} explicitAudioRxSamples={} finalAudioStatusSamples={} finalAudioRecv={:?}->{:?} finalAudioDecoded={:?}->{:?} finalAudioPlayed={:?}->{:?} finalAudioRecvProgress={} finalAudioDecodedProgress={} finalAudioPlayedProgress={} jitterEvicted={} playbackDrop={} underflow={} rebuffer={}",
            evidence.audio_status_samples,
            evidence.audio_explicit_rx_samples,
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
            evidence.audio_jitter_evicted,
            evidence.audio_playback_drop,
            evidence.audio_underflow,
            evidence.audio_rebuffer
        ),
    )
}
