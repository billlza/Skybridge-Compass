use super::super::super::CheckCoverageEntry;
use super::super::super::source::{SearchableCheckSource, source_has_all};
use crate::performance_check_names::required_file_transfer_performance_check_names;

pub(super) fn append_entries(
    source: &SearchableCheckSource,
    entries: &mut Vec<CheckCoverageEntry>,
) {
    let file_transfer_checks = required_file_transfer_performance_check_names().join(",");
    entries.push(CheckCoverageEntry {
        id: "performance_file_transfer_artifact_gate",
        domain: "performance",
        command: "skybridge check performance --kind file-transfer --artifact-dir <file-transfer-artifact>",
        covered: source_has_all(
            source,
            &[
                "build_file_transfer_performance_report",
                "check_file_transfer_protocol_identity_binding",
                "check_file_transfer_signed_kem_refresh",
                "check_file_transfer_bidirectional",
                "check_file_transfer_payload_integrity",
                "protocol_identity_binding_required_ok",
                "file_transfer_artifact_rejects_failed_stage_before_or_after_success",
                "file_transfer_artifact_requires_signed_kem_refresh",
            ],
        ),
        evidence: format!(
            "parses real-device file-transfer artifacts and requires PIB+signed KEM refresh checks instead of QR/preseed bootstrap: {file_transfer_checks}"
        ),
    });
}
