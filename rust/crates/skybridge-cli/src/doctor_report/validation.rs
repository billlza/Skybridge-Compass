use anyhow::{Result, bail};

use super::DoctorProbeReport;

pub(crate) fn ensure_probe_report_passed(report: &DoctorProbeReport, context: &str) -> Result<()> {
    let blocking = blocking_check_summaries(report);
    if report.fault_stage.is_none() && blocking.is_empty() {
        return Ok(());
    }
    let mut details = Vec::new();
    if let Some(fault) = report.fault_stage {
        details.push(format!("probable_fault_stage={fault}"));
    }
    details.extend(blocking);
    bail!("{context}: {}", details.join(", "))
}

pub(crate) fn ensure_webrtc_media_doctor_passed(report: &DoctorProbeReport) -> Result<()> {
    let blocking = blocking_check_summaries(report);
    if report.fault_stage.is_none() && blocking.is_empty() {
        return Ok(());
    }
    let fault = report
        .fault_stage
        .map(|stage| format!("probable_fault_stage={stage}"));
    let mut details = Vec::new();
    if let Some(fault) = fault {
        details.push(fault);
    }
    details.extend(blocking);
    bail!("WebRTC media doctor failed: {}", details.join(", "))
}

fn blocking_check_summaries(report: &DoctorProbeReport) -> Vec<String> {
    report
        .checks
        .iter()
        .filter(|check| {
            !check.ok
                || matches!(
                    check.severity.to_ascii_lowercase().as_str(),
                    "warn" | "warning" | "error"
                )
        })
        .map(|check| format!("{} ({})", check.name, check.severity))
        .collect()
}
