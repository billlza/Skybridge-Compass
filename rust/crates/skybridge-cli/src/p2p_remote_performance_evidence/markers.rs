use crate::performance_evidence::{
    extract_text_value, is_p2p_remote_fallback_failure_line, is_unknown_suite_rejection_line,
};

use super::P2pRemotePerformanceEvidence;

pub(super) fn update_p2p_remote_marker_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
    lower: &str,
    line_sequence: u64,
) {
    evidence.unknown_suite_rejected |= is_unknown_suite_rejection_line(line, lower);
    evidence.xwing_established |=
        line.contains("remote established") && line.contains("suite=X-Wing");
    let xwing_established_event =
        line.contains("remote established") && line.contains("suite=X-Wing");
    if xwing_established_event
        && evidence
            .signed_kem_refresh
            .verified_imported_sequence
            .is_some_and(|verified| line_sequence > verified)
    {
        evidence
            .signed_kem_refresh
            .strict_xwing_established_after_refresh = true;
        evidence
            .signed_kem_refresh
            .strict_xwing_established_sequence
            .get_or_insert(line_sequence);
    }
    evidence.hevc_configured |= line.contains("mac-stream-config")
        && line.contains("codec=hevc")
        && line.contains("fps=60");
    evidence.fail_fast_configured |= line.contains("fallback=fail-fast");
    evidence.first_frame_sync |= line.contains("mac-sck-first-frame")
        && line.contains("codec=hevc")
        && line.contains("verifiedSync=true");
    evidence.h264_video_path |= line.contains("codec=h264") && !line.contains("videoOutput=false");
    evidence.fallback_detected |= is_p2p_remote_fallback_failure_line(line, lower);
    evidence.waiting_sync |= line.contains("waitingSync=true")
        || lower.contains("waiting-for-sync")
        || line.contains("等待关键帧");
    evidence.decode_overflow |=
        lower.contains("decode-queue-overflow") || line.contains("解码队列拥塞");
    let direct_main_path_failure =
        lower.contains("render-main-path-failed") || lower.contains("strict-media-failed");
    if direct_main_path_failure {
        evidence.failed_stage_count += 1;
        if extract_text_value(line, "phase").is_none() {
            evidence.missing_failure_phase_count += 1;
        }
        if evidence.first_failure.is_none() {
            evidence.first_failure = Some(line.trim().to_owned());
        }
    }
    let remote_desktop_failure = lower.contains("远程桌面连接失败")
        || lower.contains("remote desktop connection failed")
        || lower.contains("remote-desktop connection failed")
        || (lower.contains("remote-desktop") && lower.contains("result=failure"));
    if remote_desktop_failure && !line.contains("failed stage=") {
        evidence.failed_stage_count += 1;
        if extract_text_value(line, "phase").is_none() {
            evidence.missing_failure_phase_count += 1;
        }
        if evidence.first_failure.is_none() {
            evidence.first_failure = Some(line.trim().to_owned());
        }
    }
    if line.contains("failed stage=") {
        evidence.failed_stage_count += 1;
        if extract_text_value(line, "phase").as_deref() == Some("unknown") {
            evidence.unknown_phase_count += 1;
        }
        if extract_text_value(line, "phase").is_none() {
            evidence.missing_failure_phase_count += 1;
        }
        if evidence.first_failure.is_none() {
            evidence.first_failure = Some(line.trim().to_owned());
        }
    }
    if lower.contains("already_connected") || lower.contains("rejectalreadyconnected") {
        evidence.already_connected_rejection_count += 1;
        if evidence.first_failure.is_none() {
            evidence.first_failure = Some(line.trim().to_owned());
        }
    }
    if line.contains("smoke-final") {
        evidence.smoke_final_success |=
            extract_text_value(line, "result").as_deref() == Some("success");
        evidence.smoke_final_validated |=
            extract_text_value(line, "validated").as_deref() == Some("1");
    }
    if line.contains("smoke-capture-source") {
        evidence.smoke_capture_source_verified |=
            extract_text_value(line, "captureVerified").as_deref() == Some("1");
    }
    evidence.host_process_exited |=
        line.contains("failed stage=mac-host") || line.contains("phase=process-exited");

    if let Some((width, height)) = find_dimension(line, "visible") {
        evidence.visible_width = Some(width);
        evidence.visible_height = Some(height);
    }
    if let Some((width, height)) = find_dimension(line, "frame") {
        evidence.frame_width = Some(width);
        evidence.frame_height = Some(height);
    }
}

fn find_dimension(line: &str, key: &str) -> Option<(u32, u32)> {
    let value = extract_text_value(line, key)?;
    let (width, height) = value.split_once('x')?;
    Some((width.parse().ok()?, height.parse().ok()?))
}
