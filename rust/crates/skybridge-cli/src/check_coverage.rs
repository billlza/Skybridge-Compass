use anyhow::{Result, bail};
use serde::Serialize;

use super::{CoverageCheckArgs, CoverageKindArg, check_source_catalog};

mod entries;
mod source;

use entries::quality_check_coverage_entries;
use source::source_without_check_coverage_catalog;

pub(crate) async fn check_coverage(args: CoverageCheckArgs) -> Result<()> {
    let report = build_check_coverage_report_for_kind(args.kind, args.min_percent)?;
    if args.output.json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        print_check_coverage_report(&report);
    }
    if report.ok {
        Ok(())
    } else {
        bail!(
            "CLI {} coverage failed: {:.1}% below required {:.1}%",
            report.coverage_kind,
            report.coverage_percent,
            report.min_percent
        )
    }
}

#[derive(Debug, Clone, Serialize)]
struct CheckCoverageEntry {
    id: &'static str,
    domain: &'static str,
    command: &'static str,
    covered: bool,
    evidence: String,
}

#[derive(Debug, Clone, Serialize)]
struct CheckCoverageReport {
    target: &'static str,
    #[serde(rename = "coverageKind")]
    coverage_kind: &'static str,
    #[serde(rename = "coverageDescription")]
    coverage_description: &'static str,
    required: usize,
    covered: usize,
    #[serde(rename = "coveragePercent")]
    coverage_percent: f64,
    #[serde(rename = "minPercent")]
    min_percent: f64,
    ok: bool,
    checks: Vec<CheckCoverageEntry>,
}

#[cfg(test)]
fn build_check_coverage_report(min_percent: f64) -> Result<CheckCoverageReport> {
    build_check_coverage_report_for_kind(CoverageKindArg::OperatorCheckSurface, min_percent)
}

fn build_check_coverage_report_for_kind(
    kind: CoverageKindArg,
    min_percent: f64,
) -> Result<CheckCoverageReport> {
    if !min_percent.is_finite() || !(0.0..=100.0).contains(&min_percent) {
        bail!("--min-percent must be a finite value between 0 and 100");
    }
    let source = check_source_catalog::cli_check_coverage_source();
    let searchable_source = source_without_check_coverage_catalog(&source)?;
    let checks = quality_check_coverage_entries(&searchable_source);
    let required = checks.len();
    let covered = checks.iter().filter(|entry| entry.covered).count();
    let coverage_percent = if required == 0 {
        0.0
    } else {
        covered as f64 * 100.0 / required as f64
    };
    Ok(CheckCoverageReport {
        target: "skybridge-cli",
        coverage_kind: kind.label(),
        coverage_description: kind.description(),
        required,
        covered,
        coverage_percent,
        min_percent,
        ok: coverage_percent >= min_percent,
        checks,
    })
}

fn print_check_coverage_report(report: &CheckCoverageReport) {
    println!(
        "Target: {} coverageKind={} covered={}/{} ({:.1}%) min={:.1}% note={}",
        report.target,
        report.coverage_kind,
        report.covered,
        report.required,
        report.coverage_percent,
        report.min_percent,
        report.coverage_description
    );
    for entry in &report.checks {
        let status = if entry.covered { "OK" } else { "ERROR" };
        println!(
            "[{}] {}: domain={} command=`{}` evidence={}",
            status, entry.id, entry.domain, entry.command, entry.evidence
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn check_coverage_gate_exceeds_required_88_percent() -> Result<()> {
        let report = build_check_coverage_report(88.0)?;

        assert!(report.ok);
        assert_eq!(report.coverage_kind, "operator-check-surface");
        assert!(
            report
                .coverage_description
                .contains("not Rust line or branch coverage"),
            "{}",
            report.coverage_description
        );
        assert!(report.coverage_percent >= 88.0);
        assert!(
            report
                .checks
                .iter()
                .any(|entry| entry.id == "memory_leak_pid_scan" && entry.covered)
        );
        assert!(
            report
                .checks
                .iter()
                .any(|entry| entry.id == "performance_webrtc_media_gate" && entry.covered)
        );
        assert!(report.checks.iter().any(|entry| {
            entry.id == "performance_p2p_remote_hidden_failure_gate" && entry.covered
        }));
        assert!(report.checks.iter().any(|entry| {
            entry.id == "performance_p2p_remote_signed_kem_refresh_gate" && entry.covered
        }));
        assert!(report.checks.iter().any(|entry| {
            entry.id == "performance_p2p_remote_sender_cadence_gate" && entry.covered
        }));
        assert!(report.checks.iter().any(|entry| {
            entry.id == "performance_p2p_remote_final_window_fps_gate" && entry.covered
        }));
        assert!(report.checks.iter().any(|entry| {
            entry.id == "performance_p2p_remote_ios_raw_latency_gate" && entry.covered
        }));
        assert!(
            report.checks.iter().any(|entry| {
                entry.id == "performance_metal_realtime_queue_gate" && entry.covered
            })
        );
        assert!(
            report
                .checks
                .iter()
                .any(|entry| entry.id == "connectivity_matrix_gate" && entry.covered)
        );
        assert!(
            report
                .checks
                .iter()
                .any(|entry| entry.id == "coverage_threshold_gate" && entry.covered)
        );
        Ok(())
    }

    #[test]
    fn check_coverage_rejects_invalid_thresholds() {
        assert!(build_check_coverage_report(101.0).is_err());
        assert!(build_check_coverage_report(f64::NAN).is_err());
    }
}
