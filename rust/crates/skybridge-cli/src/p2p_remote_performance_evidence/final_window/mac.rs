use super::super::P2pRemotePerformanceEvidence;

mod remote_frame;
mod sck_tx;

pub(in crate::p2p_remote_performance_evidence) fn update_p2p_remote_final_window_mac_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
) {
    if line.contains("mac-remote-frame-tx ") {
        remote_frame::update_final_window_mac_remote_frame_tx_evidence(evidence, line);
    }
    if line.contains("mac-sck-tx ")
        && line.contains("codec=hevc")
        && line.contains("capturesAudio=false")
    {
        sck_tx::update_final_window_mac_sck_tx_evidence(evidence, line);
    }
}
