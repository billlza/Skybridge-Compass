use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use anyhow::{Result, bail};

use crate::performance_evidence::SignedKEMRefreshEvidence;

mod files;
mod launch;
mod line;

pub(crate) use line::update_file_transfer_evidence;

#[derive(Debug, Default)]
pub(super) struct FileTransferPayloadDigestEvidence {
    pub(super) sender_sha256_by_name: BTreeMap<String, String>,
    pub(super) receiver_sha256_by_name: BTreeMap<String, String>,
    conflicting_sender_names: BTreeSet<String>,
    conflicting_receiver_names: BTreeSet<String>,
}

impl FileTransferPayloadDigestEvidence {
    pub(super) fn record_sender(&mut self, name: String, sha256: String) {
        Self::record_digest(
            &mut self.sender_sha256_by_name,
            &mut self.conflicting_sender_names,
            name,
            sha256,
        );
    }

    pub(super) fn record_receiver(&mut self, name: String, sha256: String) {
        Self::record_digest(
            &mut self.receiver_sha256_by_name,
            &mut self.conflicting_receiver_names,
            name,
            sha256,
        );
    }

    pub(super) fn sender_count(&self) -> usize {
        self.sender_sha256_by_name.len()
    }

    pub(super) fn receiver_count(&self) -> usize {
        self.receiver_sha256_by_name.len()
    }

    pub(super) fn matched_names(&self) -> Vec<String> {
        self.sender_sha256_by_name
            .iter()
            .filter_map(|(name, sender_hash)| {
                self.receiver_sha256_by_name
                    .get(name)
                    .filter(|receiver_hash| *receiver_hash == sender_hash)
                    .map(|_| name.clone())
            })
            .collect()
    }

    pub(super) fn mismatched_names(&self) -> Vec<String> {
        self.sender_sha256_by_name
            .iter()
            .filter_map(|(name, sender_hash)| {
                self.receiver_sha256_by_name
                    .get(name)
                    .filter(|receiver_hash| *receiver_hash != sender_hash)
                    .map(|_| name.clone())
            })
            .collect()
    }

    pub(super) fn missing_receiver_names(&self) -> Vec<String> {
        self.sender_sha256_by_name
            .keys()
            .filter(|name| !self.receiver_sha256_by_name.contains_key(*name))
            .cloned()
            .collect()
    }

    pub(super) fn missing_sender_names(&self) -> Vec<String> {
        self.receiver_sha256_by_name
            .keys()
            .filter(|name| !self.sender_sha256_by_name.contains_key(*name))
            .cloned()
            .collect()
    }

    pub(super) fn conflicting_names(&self) -> Vec<String> {
        self.conflicting_sender_names
            .union(&self.conflicting_receiver_names)
            .cloned()
            .collect()
    }

    fn record_digest(
        digests: &mut BTreeMap<String, String>,
        conflicts: &mut BTreeSet<String>,
        name: String,
        sha256: String,
    ) {
        if let Some(existing) = digests.get(&name) {
            if existing != &sha256 {
                conflicts.insert(name);
            }
            return;
        }
        digests.insert(name, sha256);
    }
}

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
    pub(super) payload_digests: FileTransferPayloadDigestEvidence,
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
