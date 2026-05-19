use crate::performance_evidence::extract_text_u64;

use super::P2pRemotePerformanceEvidence;

pub(super) fn update_p2p_remote_audio_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
    is_ios: bool,
) {
    if is_ios && (line.contains("PQC media audio rx") || line.contains("remote-desktop status")) {
        evidence.audio_status_samples += 1;
        if line.contains("PQC media audio rx") {
            evidence.audio_explicit_rx_samples += 1;
        }
        evidence.audio_jitter_evicted += extract_text_u64(line, "jitterEvicted")
            .or_else(|| extract_text_u64(line, "audioRxJitterEvicted"))
            .unwrap_or(0);
        evidence.audio_playback_drop += extract_text_u64(line, "playbackDrop")
            .or_else(|| extract_text_u64(line, "audioRxPlaybackDrop"))
            .unwrap_or(0);
        evidence.audio_underflow += extract_text_u64(line, "underflow")
            .or_else(|| extract_text_u64(line, "audioRxUnderflow"))
            .unwrap_or(0);
        evidence.audio_rebuffer += extract_text_u64(line, "rebuffer")
            .or_else(|| extract_text_u64(line, "audioRxRebuffer"))
            .unwrap_or(0);
    }
}
