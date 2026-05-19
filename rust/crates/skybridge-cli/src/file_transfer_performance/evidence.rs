use std::path::Path;

use anyhow::{Result, bail};

use crate::performance_evidence::SignedKEMRefreshEvidence;

mod files;
mod launch;
mod line;

pub(crate) use line::update_file_transfer_evidence;

#[derive(Debug, Default)]
pub(crate) struct FileTransferPerformanceEvidence {
    pub(super) file_count: usize,
    pub(super) has_mac_log: bool,
    pub(super) has_ios_log: bool,
    pub(super) mac_boot: bool,
    pub(super) ios_boot: bool,
    pub(crate) xwing_suite_seen: bool,
    pub(crate) unknown_suite_rejected: bool,
    pub(super) fallback_detected: bool,
    pub(super) qr_connect_link_seen: bool,
    pub(super) pqc_preseed_seen: bool,
    pub(super) signed_kem_refresh: SignedKEMRefreshEvidence,
    pub(super) mac_success: bool,
    pub(super) ios_success: bool,
    pub(super) mac_inbound_complete: bool,
    pub(super) ios_outbound_complete: bool,
    pub(super) mac_outbound_complete: bool,
    pub(super) ios_inbound_complete: bool,
    pub(super) mac_reconnect_outbound_complete: bool,
    pub(super) ios_reconnect_inbound_complete: bool,
    pub(super) mac_reconnect_required: bool,
    pub(super) failed_stage_count: u64,
    pub(super) unknown_phase_count: u64,
    pub(super) missing_file_transfer_phase_count: u64,
    pub(super) first_failure: Option<String>,
    pub(super) ios_launch_signing_rejected: bool,
    pub(super) ios_launch_failure_detail: Option<String>,
    pub(super) route_evidence_samples: u64,
}

pub(crate) fn file_transfer_performance_artifact_available(artifact_dir: Option<&Path>) -> bool {
    let Some(artifact_dir) = artifact_dir else {
        return false;
    };
    files::file_transfer_performance_files(artifact_dir).is_ok_and(|paths| {
        paths
            .iter()
            .any(|path| files::is_file_transfer_ios_log(path))
    })
}

pub(super) fn read_file_transfer_performance_evidence(
    artifact_dir: &Path,
) -> Result<FileTransferPerformanceEvidence> {
    let files = files::file_transfer_performance_files(artifact_dir)?;
    if files.is_empty() {
        bail!(
            "no file-transfer performance logs found in {}",
            artifact_dir.display()
        );
    }

    let mut evidence = FileTransferPerformanceEvidence {
        file_count: files.len(),
        ..Default::default()
    };
    let log_read = files::read_file_transfer_logs(&files)?;
    evidence.has_ios_log = log_read.has_ios_log;
    evidence.has_mac_log = log_read.has_mac_log;
    for entry in log_read.entries {
        update_file_transfer_evidence(&mut evidence, &entry.line, entry.is_mac, entry.is_ios);
    }
    launch::update_file_transfer_launch_evidence(&mut evidence, artifact_dir)?;
    Ok(evidence)
}
