use super::P2pRemotePerformanceEvidence;

mod remote_frame;
mod sck_encode_failure;
mod sck_encoder;
mod sck_tx;

pub(super) fn update_p2p_remote_mac_tx_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
    is_mac: bool,
) {
    if is_mac && line.contains("mac-remote-frame-tx") {
        remote_frame::update_mac_remote_frame_tx_evidence(evidence, line);
    }
    if is_mac && line.contains("mac-sck-tx") {
        sck_tx::update_mac_sck_tx_evidence(evidence, line);
    }
    if is_mac
        && line.contains("mac-sck-encode-failed")
        && line.contains("codec=hevc")
        && line.contains("capturesAudio=false")
    {
        sck_encode_failure::update_mac_sck_encode_failure_evidence(evidence, line);
    }
    if is_mac && line.contains("mac-sck-encoder") {
        sck_encoder::update_mac_sck_encoder_evidence(evidence, line);
    }
}
