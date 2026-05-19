use crate::performance_evidence::{extract_text_i64, update_max_i64};

use super::P2pRemotePerformanceEvidence;

pub(super) fn update_mac_sck_encode_failure_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
) {
    evidence.sck_encode_failure_lines += 1;
    update_max_i64(
        &mut evidence.sck_encode_failure_status_max,
        extract_text_i64(line, "status"),
    );
}
