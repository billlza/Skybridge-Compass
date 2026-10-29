use std::process::Command;
use std::time::Duration;

use anyhow::{Result, bail};

use crate::cli_text::tail_lossy;

use super::{
    DoctorCheck, DoctorProbeReport, MemoryCheckArgs, ensure_probe_report_passed,
    print_doctor_probe_report,
};

mod runner;
use runner::{format_memory_leaks_command, run_command_with_timeout, summarize_inline};

pub(crate) async fn check_memory(args: MemoryCheckArgs) -> Result<()> {
    let as_json = args.output.json;
    let report = build_memory_check_report(&args)?;
    print_doctor_probe_report(&report, as_json)?;
    ensure_probe_report_passed(&report, "memory leak check failed")
}

pub(crate) fn build_memory_check_report(args: &MemoryCheckArgs) -> Result<DoctorProbeReport> {
    if args.pid.is_none() == args.executable.is_none() {
        bail!("pass exactly one memory check target: --pid <pid> or --executable <path>");
    }
    if args.timeout_seconds == 0 {
        bail!("--timeout-seconds must be greater than zero");
    }

    let target = if let Some(pid) = args.pid {
        format!("memory-leaks pid={pid}")
    } else {
        let executable = args.executable.as_ref().expect("checked above");
        format!(
            "memory-leaks executable={} args={}",
            executable.display(),
            args.executable_args.len()
        )
    };

    let mut command = Command::new(&args.leaks_tool);
    if args.quiet {
        command.arg("--quiet");
    }
    if let Some(pid) = args.pid {
        command.arg(pid.to_string());
    } else {
        command.arg("--atExit").arg("--");
        command.arg(args.executable.as_ref().expect("checked above"));
        command.args(&args.executable_args);
    }

    let leaks_command = format_memory_leaks_command(args);
    let output = run_command_with_timeout(&mut command, Duration::from_secs(args.timeout_seconds));
    let mut checks = Vec::new();
    match output {
        Ok(output) => {
            let stdout_tail = tail_lossy(&output.stdout, 2_000);
            let stderr_tail = tail_lossy(&output.stderr, 2_000);
            let exit = output
                .status
                .and_then(|status| status.code())
                .map_or_else(|| "signal".to_owned(), |code| code.to_string());
            let completed = !output.timed_out && output.status.is_some();
            let success = output.status.is_some_and(|status| status.success()) && !output.timed_out;
            checks.push(DoctorCheck {
                name: "memory_leaks_tool",
                ok: true,
                severity: "info",
                detail: format!(
                    "executed `{leaks_command}` timeoutSeconds={}",
                    args.timeout_seconds
                ),
                server_build_fingerprint: None,
                state_backend: None,
                reject_reason: None,
            });
            checks.push(DoctorCheck {
                name: "memory_leak_scan_completed",
                ok: completed && success,
                severity: if completed && success {
                    "info"
                } else {
                    "error"
                },
                detail: format!(
                    "leaks exit={exit}; timedOut={}; stdoutTail={}; stderrTail={}",
                    output.timed_out,
                    summarize_inline(&stdout_tail),
                    summarize_inline(&stderr_tail)
                ),
                server_build_fingerprint: None,
                state_backend: None,
                reject_reason: None,
            });
            checks.push(DoctorCheck {
                name: "memory_no_leaks",
                ok: success,
                severity: if success { "info" } else { "error" },
                detail: if success {
                    "leaks reported no process leaks for the scanned target".to_owned()
                } else if output.timed_out {
                    "leaks did not complete before timeout; no leak verdict is available".to_owned()
                } else {
                    "leaks returned failure; inspect stdoutTail/stderrTail from memory_leak_scan_completed".to_owned()
                },
                server_build_fingerprint: None,
                state_backend: None,
                reject_reason: None,
            });
        }
        Err(error) => {
            checks.push(DoctorCheck {
                name: "memory_leaks_tool",
                ok: false,
                severity: "error",
                detail: format!("failed to execute `{}`: {error}", args.leaks_tool.display()),
                server_build_fingerprint: None,
                state_backend: None,
                reject_reason: None,
            });
            checks.push(DoctorCheck {
                name: "memory_leak_scan_completed",
                ok: false,
                severity: "error",
                detail: "scan did not run because leaks tool execution failed".to_owned(),
                server_build_fingerprint: None,
                state_backend: None,
                reject_reason: None,
            });
            checks.push(DoctorCheck {
                name: "memory_no_leaks",
                ok: false,
                severity: "error",
                detail: "no leak verdict is available without a completed leaks scan".to_owned(),
                server_build_fingerprint: None,
                state_backend: None,
                reject_reason: None,
            });
        }
    }

    Ok(DoctorProbeReport {
        target,
        checks,
        fault_stage: None,
        latest_diagnostic_at: None,
        latest_video_evidence_at: None,
        latest_receiver_evidence_at: None,
        latest_audio_tx_evidence_at: None,
        latest_audio_rx_evidence_at: None,
    })
}

#[cfg(test)]
mod tests;
