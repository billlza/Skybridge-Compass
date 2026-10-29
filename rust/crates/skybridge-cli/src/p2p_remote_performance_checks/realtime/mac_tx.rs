use crate::p2p_remote_performance_evidence::P2pRemotePerformanceEvidence;
use crate::{DoctorCheck, simple_doctor_check};

mod detail;
mod selected;
mod verdict;

use selected::MacTxSelectedEvidence;

pub(crate) fn check_p2p_remote_mac_tx(
    evidence: &P2pRemotePerformanceEvidence,
    min_fps: f64,
) -> DoctorCheck {
    let selected = MacTxSelectedEvidence::from(evidence);
    let verdict = verdict::evaluate(&selected, min_fps);
    simple_doctor_check(
        "p2p_remote_mac_tx_backpressure",
        verdict.ok,
        verdict.level(),
        detail::format_mac_tx_detail(&selected, &verdict),
    )
}
