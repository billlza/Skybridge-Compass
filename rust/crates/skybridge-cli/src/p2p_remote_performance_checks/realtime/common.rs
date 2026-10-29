use crate::p2p_remote_performance_evidence::P2pRemotePerformanceEvidence;

pub(super) fn p2p_remote_has_final_window(evidence: &P2pRemotePerformanceEvidence) -> bool {
    evidence.pass_window_start_at.is_some() && evidence.pass_window_end_at.is_some()
}

pub(super) fn aggregate_fps(frames: u64, sample_ms: u64) -> f64 {
    if sample_ms == 0 {
        0.0
    } else {
        frames as f64 * 1000.0 / sample_ms as f64
    }
}
