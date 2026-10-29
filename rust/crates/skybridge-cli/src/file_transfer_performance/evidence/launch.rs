use std::fs;
use std::path::Path;

use anyhow::{Context, Result};

use super::FileTransferPerformanceEvidence;

pub(super) fn update_file_transfer_launch_evidence(
    evidence: &mut FileTransferPerformanceEvidence,
    artifact_dir: &Path,
) -> Result<()> {
    let launch_path = artifact_dir.join("ios-launch.json");
    if !launch_path.is_file() {
        return Ok(());
    }
    let launch_text = fs::read_to_string(&launch_path)
        .with_context(|| format!("failed to read iOS launch result {}", launch_path.display()))?;
    let lower = launch_text.to_ascii_lowercase();
    let signing_rejected = lower.contains("invalid code signature")
        || lower.contains("inadequate entitlements")
        || lower.contains("profile has not been explicitly trusted")
        || (lower.contains("requestdenied") && lower.contains("security"));
    if signing_rejected {
        evidence.ios_launch_signing_rejected = true;
        evidence.ios_launch_failure_detail = Some(
            "invalid code signature, inadequate entitlements, or profile not trusted".to_owned(),
        );
    }
    Ok(())
}
