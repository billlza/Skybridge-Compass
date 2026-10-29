use anyhow::Result;

use super::DoctorProbeReport;

pub(crate) fn print_doctor_probe_report(report: &DoctorProbeReport, as_json: bool) -> Result<()> {
    if as_json {
        println!("{}", serde_json::to_string_pretty(report)?);
        return Ok(());
    }
    println!("Target: {}", report.target);
    if let Some(fault_stage) = report.fault_stage {
        println!("[ERROR] probable_fault_stage: {fault_stage}");
    }
    for check in &report.checks {
        let status = if check.ok {
            "OK".to_owned()
        } else {
            check.severity.to_ascii_uppercase()
        };
        println!("[{}] {}: {}", status, check.name, check.detail);
    }
    Ok(())
}
