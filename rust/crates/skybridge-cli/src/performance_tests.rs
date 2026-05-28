#![cfg(test)]

use anyhow::Result;
use time::{OffsetDateTime, UtcOffset};

use crate::cli_test_support::{
    doctor_check, doctor_check_optional, fixture_dir, make_test_dir, performance_artifact_args,
};
use crate::file_transfer_performance::{
    FileTransferPerformanceEvidence, build_file_transfer_performance_report,
    check_file_transfer_xwing, update_file_transfer_evidence,
};
use crate::p2p_remote_performance::*;
use crate::performance_budgets::{
    P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES, P2P_REMOTE_STRICT_IOS_DECODE_FEED_MODE,
    P2P_REMOTE_STRICT_IOS_READ_AHEAD_MODE, P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_MODE,
    P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS,
};
use crate::performance_check_names::required_webrtc_performance_check_names;
use crate::performance_commands::build_performance_check_report;
use crate::performance_evidence::{SignedKEMRefreshEvidence, update_signed_kem_refresh_evidence};
use crate::webrtc_media_parse::parse_webrtc_local_console_timestamp_with_offset;
use crate::{OutputOptions, PerformanceCheckArgs, PerformanceKindArg};

mod file_transfer;
mod p2p_remote;
mod realtime;
mod signed_kem;

#[test]
fn performance_check_surface_covers_required_metrics() -> Result<()> {
    let artifact_dir = make_test_dir("performance-check-surface")?;
    let args = PerformanceCheckArgs {
        kind: PerformanceKindArg::Webrtc,
        session_id: Some("SESSION-COVERAGE".to_owned()),
        latest: false,
        artifact_dir: Some(artifact_dir),
        log_file: None,
        since_seconds: 1,
        min_fps: 59.0,
        min_width: 0,
        min_height: 0,
        exact_video_size: false,
        require_audio: true,
        strict_fps_floor: true,
        min_pass_window_seconds: P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS,
        manual_artifact: false,
        output: OutputOptions { json: false },
    };
    let report = build_performance_check_report(&args, "SESSION-COVERAGE")?;
    let surface = doctor_check(&report, "performance_check_surface");

    assert!(surface.ok, "{}", surface.detail);
    for required in required_webrtc_performance_check_names() {
        assert!(
            doctor_check_optional(&report, required).is_some(),
            "{required} check missing"
        );
    }
    Ok(())
}
