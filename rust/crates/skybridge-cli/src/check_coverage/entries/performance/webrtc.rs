use super::super::super::CheckCoverageEntry;
use super::super::super::source::{SearchableCheckSource, source_has_all};
use crate::performance_check_names::required_webrtc_performance_check_names;

pub(super) fn append_entries(
    source: &SearchableCheckSource,
    entries: &mut Vec<CheckCoverageEntry>,
) {
    let performance_checks = required_webrtc_performance_check_names().join(",");
    entries.push(CheckCoverageEntry {
        id: "performance_webrtc_media_gate",
        domain: "performance",
        command: "skybridge check performance --session-id <id>",
        covered: source_has_all(
            source,
            &[
                "build_webrtc_media_doctor_report_for_gate",
                "required_webrtc_performance_check_names",
                "performance_check_surface",
            ],
        ),
        evidence: format!("reuses WebRTC media doctor checks: {performance_checks}"),
    });
}
