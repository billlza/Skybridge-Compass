use anyhow::Result;
use clap::Parser;
mod auth_commands;
mod auth_support;
mod check_coverage;
mod check_source_catalog;
mod cli_args;
mod cli_dispatch;
mod cli_metadata;
#[cfg(test)]
mod cli_test_support;
mod cli_text;
mod connection_code;
mod connection_code_snapshot;
mod connectivity_check;
mod control_plane_doctor;
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
mod operator_status;
mod p2p_remote_performance;
mod p2p_remote_performance_checks;
mod p2p_remote_performance_evidence;
mod performance_budgets;
mod performance_check_names;
mod performance_commands;
mod performance_evidence;
#[cfg(test)]
mod performance_tests;
mod remote_control_notice_check;
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
async fn main() -> Result<()> {
    let cli = Cli::parse();
    dispatch(cli).await
}
