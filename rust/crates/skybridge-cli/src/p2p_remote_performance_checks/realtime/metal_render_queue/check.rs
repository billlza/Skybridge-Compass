use crate::p2p_remote_performance_evidence::P2pRemotePerformanceEvidence;
use crate::{DoctorCheck, simple_doctor_check};

use super::selected::MetalRenderQueueSelectedEvidence;

pub(crate) fn check_p2p_remote_metal_render_queue(
    evidence: &P2pRemotePerformanceEvidence,
    min_fps: f64,
) -> DoctorCheck {
    let selected = MetalRenderQueueSelectedEvidence::from(evidence);
    let verdict = super::verdict::evaluate(&selected, min_fps);
    simple_doctor_check(
        "p2p_remote_metal_render_queue",
        verdict.ok,
        verdict.level(),
        super::detail::format_metal_render_queue_detail(&selected, &verdict),
    )
}
