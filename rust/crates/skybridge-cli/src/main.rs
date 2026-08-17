use clap::Parser;
use std::process::ExitCode;
mod agent_runtime_guard;
mod android_bridge;
mod android_commands;
mod auth_commands;
mod auth_support;
mod check_coverage;
mod check_source_catalog;
mod cli_args;
mod cli_dispatch;
mod cli_metadata;
mod cli_output;
#[cfg(test)]
mod cli_test_support;
mod cli_text;
mod connection_code;
mod connection_code_snapshot;
mod connectivity_check;
mod control_plane_doctor;
#[cfg(target_os = "macos")]
mod crossnet_commands;
mod device_commands;
mod doctor_commands;
mod doctor_report;
mod file_commands;
mod file_transfer_performance;
mod internal_commands;
#[cfg(test)]
mod main_dispatch_tests;
#[cfg(test)]
mod main_tests;
mod memory_check;
mod operator_capabilities;
mod operator_status;
mod p2p_remote_performance;
mod p2p_remote_performance_checks;
mod p2p_remote_performance_evidence;
mod performance_budgets;
mod performance_check_names;
mod performance_commands;
mod performance_evidence;
mod performance_report_target;
#[cfg(test)]
mod performance_tests;
mod remote_control_notice_check;
mod remote_desktop_commands;
mod repo_paths;
mod session_commands;
mod smoke_suite;
mod test_commands;
mod webrtc_media_artifacts;
mod webrtc_media_dimensions;
mod webrtc_media_doctor;
#[cfg(test)]
mod webrtc_media_doctor_tests;
mod webrtc_media_parse;
mod webrtc_media_summary;
mod webrtc_smoke_gate;

pub(crate) use cli_args::*;
use cli_dispatch::dispatch;
pub(crate) use doctor_report::{
    DoctorCheck, DoctorProbeReport, ensure_probe_report_passed, ensure_webrtc_media_doctor_passed,
    print_doctor_probe_report, simple_doctor_check,
};
pub(crate) use performance_check_names::*;
pub(crate) use performance_evidence::{
    protocol_identity_binding_check_detail, protocol_identity_binding_required_ok,
    signed_kem_refresh_check_detail, signed_kem_refresh_ok,
};

#[tokio::main]
async fn main() -> ExitCode {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error) => return render_parse_failure(error),
    };
    let json_output = cli.json_output_requested();

    match dispatch(cli).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            if json_output {
                if !cli_output::json_failure_was_written()
                    && let Err(render_error) = cli_output::write_unhandled_json_failure(
                        "command_failed",
                        "SkyBridge command failed",
                    )
                {
                    eprintln!("Error: {render_error:#}");
                }
            } else {
                eprintln!("Error: {error:#}");
            }
            ExitCode::FAILURE
        }
    }
}

fn render_parse_failure(error: clap::Error) -> ExitCode {
    let exit_code = error.exit_code();
    if exit_code == 0 {
        if let Err(render_error) = error.print() {
            eprintln!("Error: failed to render command-line help: {render_error}");
            return ExitCode::FAILURE;
        }
        return ExitCode::SUCCESS;
    }

    let json_requested = std::env::args_os().any(|argument| argument == "--json");
    if json_requested {
        if let Err(render_error) = cli_output::write_unhandled_json_failure(
            "invalid_arguments",
            "SkyBridge command arguments are invalid; check option prerequisites with --help",
        ) {
            eprintln!("Error: {render_error:#}");
        }
    } else if let Err(render_error) = error.print() {
        eprintln!("Error: failed to render command-line help: {render_error}");
    }
    ExitCode::FAILURE
}
