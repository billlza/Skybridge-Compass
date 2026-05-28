mod checks;
mod evidence;

pub(crate) use checks::check_file_transfer_xwing;
pub(crate) use evidence::file_transfer_performance_artifact_available;
#[cfg(test)]
pub(crate) use evidence::{FileTransferPerformanceEvidence, update_file_transfer_evidence};

use anyhow::{Result, anyhow};

use crate::{
    DoctorCheck, DoctorProbeReport, PerformanceCheckArgs,
    required_file_transfer_performance_check_names,
};

use checks::{
    check_file_transfer_bidirectional, check_file_transfer_no_hidden_failure,
    check_file_transfer_payload_integrity, check_file_transfer_protocol_identity_binding,
    check_file_transfer_route_evidence, check_file_transfer_signed_kem_refresh,
    check_file_transfer_skr_direct_route, check_file_transfer_sources, check_file_transfer_success,
    classify_file_transfer_probable_fault_stage,
};
use evidence::read_file_transfer_performance_evidence;

pub(crate) fn build_file_transfer_performance_report(
    args: &PerformanceCheckArgs,
) -> Result<DoctorProbeReport> {
    let artifact_dir = args
        .artifact_dir
        .as_deref()
        .ok_or_else(|| anyhow!("file-transfer performance check requires --artifact-dir"))?;
    let evidence = read_file_transfer_performance_evidence(artifact_dir)?;
    let mut checks = vec![
        check_file_transfer_sources(&evidence),
        check_file_transfer_no_hidden_failure(&evidence),
        check_file_transfer_xwing(&evidence),
        check_file_transfer_protocol_identity_binding(&evidence),
        check_file_transfer_signed_kem_refresh(&evidence),
        check_file_transfer_skr_direct_route(&evidence),
        check_file_transfer_bidirectional(&evidence),
        check_file_transfer_success(&evidence),
        check_file_transfer_payload_integrity(&evidence),
        check_file_transfer_route_evidence(&evidence),
    ];
    let required = required_file_transfer_performance_check_names();
    let missing = required
        .iter()
        .copied()
        .filter(|name| checks.iter().all(|check| check.name != *name))
        .collect::<Vec<_>>();
    checks.push(DoctorCheck {
        name: "performance_check_surface",
        ok: missing.is_empty(),
        severity: if missing.is_empty() { "info" } else { "error" },
        detail: if missing.is_empty() {
            format!(
                "file-transfer performance gate covers required checks: {}",
                required.join(",")
            )
        } else {
            format!(
                "file-transfer performance gate is missing checks: {}",
                missing.join(",")
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    });

    Ok(DoctorProbeReport {
        target: format!(
            "performance file-transfer artifact={}",
            artifact_dir.display()
        ),
        checks,
        fault_stage: classify_file_transfer_probable_fault_stage(&evidence),
        latest_diagnostic_at: None,
        latest_video_evidence_at: None,
        latest_receiver_evidence_at: None,
        latest_audio_tx_evidence_at: None,
        latest_audio_rx_evidence_at: None,
    })
}
