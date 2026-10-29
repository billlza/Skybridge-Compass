use crate::p2p_remote_performance_evidence::P2pRemotePerformanceEvidence;
use crate::performance_budgets::{
    P2P_REMOTE_DEFAULT_ACCEPTED_ALT_HEIGHT, P2P_REMOTE_DEFAULT_REQUIRED_HEIGHT,
    P2P_REMOTE_DEFAULT_REQUIRED_WIDTH, P2P_REMOTE_STRICT_HEVC_BURST_HEADROOM_MULTIPLIER,
    P2P_REMOTE_STRICT_HEVC_BURST_WINDOW_MS, P2P_REMOTE_STRICT_HEVC_MAX_FRAME_DELAY_COUNT,
    P2P_REMOTE_STRICT_HEVC_MAXIMUM_REAL_TIME_FRAME_RATE,
    P2P_REMOTE_STRICT_HEVC_MIN_BURST_LIMIT_BYTES, P2P_REMOTE_STRICT_HEVC_SINGLE_CHUNK_BUDGET_BYTES,
    P2P_REMOTE_STRICT_SCK_CADENCE_CATCH_UP_LIMIT, P2P_REMOTE_STRICT_SCK_SOURCE_FRAME_AGE_LIMIT_MS,
    P2P_REMOTE_STRICT_SCK_SOURCE_FRAME_REPEAT_LIMIT, P2P_REMOTE_STRICT_TARGET_FPS,
};
use crate::{DoctorCheck, PerformanceCheckArgs, simple_doctor_check};

pub(crate) fn check_p2p_remote_hevc_main_path(
    evidence: &P2pRemotePerformanceEvidence,
) -> DoctorCheck {
    let expected_burst_limit = expected_p2p_remote_hevc_burst_limit_bytes(evidence);
    let final_sck_window = evidence.mac_final_window_sck_samples > 0;
    let source_frame_age_max_ms = if final_sck_window {
        evidence.mac_final_window_sck_source_frame_age_max_ms
    } else {
        evidence.sck_source_frame_age_max_ms
    };
    let source_frame_repeat_max = if final_sck_window {
        evidence.mac_final_window_sck_source_frame_repeat_max
    } else {
        evidence.sck_source_frame_repeat_max
    };
    let source_capture_fps_min = if final_sck_window {
        evidence.mac_final_window_min_capture_fps
    } else {
        evidence.sck_capture_fps_min
    };
    let source_meaningful_fps_min = if final_sck_window {
        evidence.mac_final_window_min_meaningful_fps
    } else {
        evidence.sck_meaningful_fps_min
    };
    let min_source_fps = P2P_REMOTE_STRICT_TARGET_FPS as f64 - 1.0;
    let source_capture_fps_ok =
        final_sck_window || source_capture_fps_min.is_some_and(|fps| fps >= min_source_fps);
    let source_meaningful_fps_ok =
        final_sck_window || source_meaningful_fps_min.is_some_and(|fps| fps >= min_source_fps);
    let source_frame_age_budget_exceeded = source_frame_age_max_ms
        .is_some_and(|age| age > P2P_REMOTE_STRICT_SCK_SOURCE_FRAME_AGE_LIMIT_MS);
    let waiting_sync_cleared = !evidence.waiting_sync
        || (evidence.first_frame_sync && evidence.final_ios_remote_desktop_pass);
    let ok = evidence.hevc_configured
        && evidence.fail_fast_configured
        && evidence.first_frame_sync
        && !evidence.h264_video_path
        && waiting_sync_cleared
        && evidence.sck_cadence_catch_up_limit_samples > 0
        && evidence.sck_cadence_catch_up_limit_max
            == Some(P2P_REMOTE_STRICT_SCK_CADENCE_CATCH_UP_LIMIT)
        && evidence.sck_max_frame_delay_count_samples > 0
        && evidence.sck_max_frame_delay_count_max
            == Some(P2P_REMOTE_STRICT_HEVC_MAX_FRAME_DELAY_COUNT)
        && evidence.sck_maximum_real_time_frame_rate_max
            == Some(P2P_REMOTE_STRICT_HEVC_MAXIMUM_REAL_TIME_FRAME_RATE)
        && evidence.sck_low_latency_rate_control_samples > 0
        && evidence.sck_cadence_timer_fires_total > 0
        && evidence.sck_cadence_submitted_frames_total > 0
        && evidence.sck_cadence_batch_max.is_some_and(|batch| {
            (1..=P2P_REMOTE_STRICT_SCK_CADENCE_CATCH_UP_LIMIT).contains(&batch)
        })
        && evidence.sck_captured_frames_total > 0
        && evidence.sck_meaningful_frames_total > 0
        && source_capture_fps_ok
        && source_meaningful_fps_ok
        && source_frame_repeat_max
            .is_some_and(|repeat| repeat <= P2P_REMOTE_STRICT_SCK_SOURCE_FRAME_REPEAT_LIMIT)
        && evidence.sck_encode_failures_total == 0
        && evidence.sck_encode_failure_lines == 0
        && evidence.sck_single_chunk_budget_bytes_max
            == Some(P2P_REMOTE_STRICT_HEVC_SINGLE_CHUNK_BUDGET_BYTES)
        && evidence.sck_oversized_encoded_frames_total == 0
        && evidence.sck_oversized_sync_frames_total == 0
        && evidence.sck_data_rate_burst_samples > 0
        && expected_burst_limit.is_some()
        && evidence.sck_data_rate_burst_limit_bytes_max == expected_burst_limit
        && evidence.sck_data_rate_burst_window_ms_max
            == Some(P2P_REMOTE_STRICT_HEVC_BURST_WINDOW_MS)
        && evidence.sck_data_rate_limits_status_max == Some(0)
        && evidence.sck_data_rate_limits_readback_status_max == Some(0)
        && evidence.sck_data_rate_limits_applied_samples == evidence.sck_data_rate_burst_samples
        && evidence.sck_data_rate_readback_burst_limit_bytes_max == expected_burst_limit
        && evidence.sck_data_rate_readback_burst_window_ms_max
            == Some(P2P_REMOTE_STRICT_HEVC_BURST_WINDOW_MS);
    simple_doctor_check(
        "p2p_remote_hevc_main_path",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "hevcConfigured={} failFast={} firstFrameSync={} h264Video={} waitingSync={} waitingSyncCleared={} finalSCKWindow={} sckCadenceCatchUpLimit={:?} sckCadenceCatchUpSamples={} sckMaxFrameDelayCount={:?} sckMaxFrameDelaySamples={} sckMaximumRealTimeFrameRate={:?} sckLowLatencyRateControl={}/{} sckCadenceTimerFires={} sckCadenceSubmitted={} sckCadenceCatchUpFrames={} sckCadenceBatchMax={:?} sckCapturedFrames={} sckMeaningfulFrames={} sckCaptureFpsMin={:?} sckMeaningfulFpsMin={:?} minRequiredSourceFps={:.1} globalSCKCaptureFpsMin={:?} globalSCKMeaningfulFpsMin={:?} sckSourceFrameAgeMaxMs={:?} sckSourceFrameAgeBudgetExceeded={} sckSourceFrameRepeatMax={:?} globalSCKSourceFrameAgeMaxMs={:?} globalSCKSourceFrameRepeatMax={:?} sckEncodeFailures={} sckEncodeFailureLines={} sckEncodeFailureStatus={:?} sckSingleChunkBudgetBytes={:?} sckEncodedFrameBytesMax={:?} sckEncodedSyncFrameBytesMax={:?} sckOversizedEncodedFrames={} sckOversizedSyncFrames={} sckDataRateLimitBytesPerSecond={:?} sckExpectedBurstLimitBytes={:?} sckBurstLimitBytes={:?} sckBurstWindowMs={:?} sckBurstSamples={} dataRateLimitsStatus={:?} dataRateLimitsReadbackStatus={:?} dataRateLimitsAppliedSamples={} sckReadbackBurstLimitBytes={:?} sckReadbackBurstWindowMs={:?}",
            evidence.hevc_configured,
            evidence.fail_fast_configured,
            evidence.first_frame_sync,
            evidence.h264_video_path,
            evidence.waiting_sync,
            waiting_sync_cleared,
            final_sck_window,
            evidence.sck_cadence_catch_up_limit_max,
            evidence.sck_cadence_catch_up_limit_samples,
            evidence.sck_max_frame_delay_count_max,
            evidence.sck_max_frame_delay_count_samples,
            evidence.sck_maximum_real_time_frame_rate_max,
            evidence.sck_low_latency_rate_control_enabled_samples,
            evidence.sck_low_latency_rate_control_samples,
            evidence.sck_cadence_timer_fires_total,
            evidence.sck_cadence_submitted_frames_total,
            evidence.sck_cadence_catch_up_frames_total,
            evidence.sck_cadence_batch_max,
            evidence.sck_captured_frames_total,
            evidence.sck_meaningful_frames_total,
            source_capture_fps_min,
            source_meaningful_fps_min,
            min_source_fps,
            evidence.sck_capture_fps_min,
            evidence.sck_meaningful_fps_min,
            source_frame_age_max_ms,
            source_frame_age_budget_exceeded,
            source_frame_repeat_max,
            evidence.sck_source_frame_age_max_ms,
            evidence.sck_source_frame_repeat_max,
            evidence.sck_encode_failures_total,
            evidence.sck_encode_failure_lines,
            evidence.sck_encode_failure_status_max,
            evidence.sck_single_chunk_budget_bytes_max,
            evidence.sck_encoded_frame_bytes_max,
            evidence.sck_encoded_sync_frame_bytes_max,
            evidence.sck_oversized_encoded_frames_total,
            evidence.sck_oversized_sync_frames_total,
            evidence.sck_data_rate_limit_bytes_per_second_max,
            expected_burst_limit,
            evidence.sck_data_rate_burst_limit_bytes_max,
            evidence.sck_data_rate_burst_window_ms_max,
            evidence.sck_data_rate_burst_samples,
            evidence.sck_data_rate_limits_status_max,
            evidence.sck_data_rate_limits_readback_status_max,
            evidence.sck_data_rate_limits_applied_samples,
            evidence.sck_data_rate_readback_burst_limit_bytes_max,
            evidence.sck_data_rate_readback_burst_window_ms_max
        ),
    )
}

pub(crate) fn check_p2p_remote_resolution(
    evidence: &P2pRemotePerformanceEvidence,
    args: &PerformanceCheckArgs,
) -> DoctorCheck {
    let observed = evidence
        .frame_width
        .zip(evidence.frame_height)
        .or_else(|| evidence.visible_width.zip(evidence.visible_height));
    let uses_default_strict_2k = args.min_width == 0 && args.min_height == 0;
    let required_width = if uses_default_strict_2k {
        P2P_REMOTE_DEFAULT_REQUIRED_WIDTH
    } else {
        args.min_width
    };
    let required_height = if uses_default_strict_2k {
        P2P_REMOTE_DEFAULT_REQUIRED_HEIGHT
    } else {
        args.min_height
    };
    let exact_video_size = args.exact_video_size || uses_default_strict_2k;
    let default_strict_size_ok = |size: (u32, u32)| {
        size == (
            P2P_REMOTE_DEFAULT_REQUIRED_WIDTH,
            P2P_REMOTE_DEFAULT_REQUIRED_HEIGHT,
        ) || size
            == (
                P2P_REMOTE_DEFAULT_REQUIRED_WIDTH,
                P2P_REMOTE_DEFAULT_ACCEPTED_ALT_HEIGHT,
            )
    };
    let ok = if required_width == 0 && required_height == 0 {
        observed.is_some()
    } else if uses_default_strict_2k {
        observed.is_some_and(default_strict_size_ok)
            || evidence
                .visible_width
                .zip(evidence.visible_height)
                .is_some_and(default_strict_size_ok)
    } else if exact_video_size {
        observed == Some((required_width, required_height))
            || evidence.visible_width.zip(evidence.visible_height)
                == Some((required_width, required_height))
    } else {
        observed.is_some_and(|(width, height)| width >= required_width && height >= required_height)
    };
    simple_doctor_check(
        "p2p_remote_resolution",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "observed={:?} visible={:?} required={}x{} acceptedAltHeight={:?} exact={} defaultStrict2K60={}",
            observed,
            evidence.visible_width.zip(evidence.visible_height),
            required_width,
            required_height,
            if uses_default_strict_2k {
                Some(P2P_REMOTE_DEFAULT_ACCEPTED_ALT_HEIGHT)
            } else {
                None
            },
            exact_video_size,
            uses_default_strict_2k
        ),
    )
}

fn expected_p2p_remote_hevc_burst_limit_bytes(
    evidence: &P2pRemotePerformanceEvidence,
) -> Option<u64> {
    let hard_limit = evidence.sck_data_rate_limit_bytes_per_second_max?;
    let _window_ms = evidence.sck_data_rate_burst_window_ms_max?;
    let rate_window =
        hard_limit.saturating_add(P2P_REMOTE_STRICT_TARGET_FPS - 1) / P2P_REMOTE_STRICT_TARGET_FPS;
    let burst_with_headroom =
        rate_window.saturating_mul(P2P_REMOTE_STRICT_HEVC_BURST_HEADROOM_MULTIPLIER);
    Some(burst_with_headroom.clamp(
        P2P_REMOTE_STRICT_HEVC_MIN_BURST_LIMIT_BYTES,
        P2P_REMOTE_STRICT_HEVC_SINGLE_CHUNK_BUDGET_BYTES,
    ))
}
