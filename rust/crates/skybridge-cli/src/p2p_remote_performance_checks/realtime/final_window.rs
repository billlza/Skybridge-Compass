use crate::p2p_remote_performance_evidence::P2pRemotePerformanceEvidence;
use crate::performance_budgets::{
    P2P_REMOTE_STRICT_SCK_CADENCE_CATCH_UP_LIMIT, P2P_REMOTE_STRICT_SCK_SOURCE_FRAME_AGE_LIMIT_MS,
    P2P_REMOTE_STRICT_SCK_SOURCE_FRAME_REPEAT_LIMIT,
};
use crate::{DoctorCheck, simple_doctor_check};

use super::common::aggregate_fps;

pub(crate) fn check_p2p_remote_ios_window_fps(
    evidence: &P2pRemotePerformanceEvidence,
    min_fps: f64,
) -> DoctorCheck {
    let uses_final_window = evidence.final_ios_remote_desktop_pass;
    let window_fps = if uses_final_window {
        evidence.final_ios_window_fps.unwrap_or(0.0)
    } else {
        evidence.min_window_fps.unwrap_or(0.0)
    };
    let window_rx_fps = if uses_final_window {
        evidence.final_ios_window_rx_fps.unwrap_or(0.0)
    } else {
        evidence.min_window_rx_fps.unwrap_or(0.0)
    };
    let cadence_samples = if uses_final_window {
        evidence.final_ios_cadence_samples
    } else {
        evidence.ios_cadence_samples
    };
    let cadence_failures = if uses_final_window {
        evidence.final_ios_cadence_failures
    } else {
        evidence.ios_cadence_failures
    };
    let min_2s_display_frames = if uses_final_window {
        evidence.final_ios_min_2s_display_frames_min
    } else {
        evidence.ios_min_2s_display_frames_min
    };
    let min_2s_rx_frames = if uses_final_window {
        evidence.final_ios_min_2s_rx_frames_min
    } else {
        evidence.ios_min_2s_rx_frames_min
    };
    let two_second_required_frames = if uses_final_window {
        evidence.final_ios_two_second_required_frames_max
    } else {
        evidence.ios_two_second_required_frames_max
    };
    let latest_ios_fps = if uses_final_window {
        evidence.final_ios_fps
    } else {
        evidence.latest_ios_fps
    };
    let latest_ios_rx_fps = if uses_final_window {
        evidence.final_ios_rx_fps
    } else {
        evidence.latest_ios_rx_fps
    };
    let cadence_ok = cadence_samples > 0
        && cadence_failures == 0
        && two_second_required_frames.is_some_and(|required| {
            min_2s_display_frames.is_some_and(|frames| frames >= required)
                && min_2s_rx_frames.is_some_and(|frames| frames >= required)
        });
    let ok = evidence.remote_desktop_pass
        && (!uses_final_window || evidence.final_ios_remote_desktop_pass)
        && window_fps >= min_fps
        && window_rx_fps >= min_fps
        && cadence_ok;
    simple_doctor_check(
        "p2p_remote_ios_window_fps",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "remoteDesktopPass={} finalWindow={} windowFPS={:.1} windowRxFPS={:.1} latestFPS={:?} latestRxFPS={:?} required={:.1} displayCadenceSamples={} displayCadenceFailures={} min2sDisplayFrames={:?} min2sRxFrames={:?} twoSecondRequiredFrames={:?}",
            evidence.remote_desktop_pass,
            uses_final_window,
            window_fps,
            window_rx_fps,
            latest_ios_fps,
            latest_ios_rx_fps,
            min_fps,
            cadence_samples,
            cadence_failures,
            min_2s_display_frames,
            min_2s_rx_frames,
            two_second_required_frames
        ),
    )
}

pub(crate) fn check_p2p_remote_mac_final_window_fps(
    evidence: &P2pRemotePerformanceEvidence,
    min_fps: f64,
    min_pass_window_seconds: u64,
) -> DoctorCheck {
    let required_samples =
        p2p_remote_required_final_window_samples(evidence, min_pass_window_seconds);
    let sck_aggregate_fps = aggregate_fps(
        evidence.mac_final_window_sck_encoded_frames,
        evidence.mac_final_window_sck_sample_ms,
    );
    let sck_capture_fps = aggregate_fps(
        evidence.mac_final_window_sck_captured_frames,
        evidence.mac_final_window_sck_sample_ms,
    );
    let sck_meaningful_fps = aggregate_fps(
        evidence.mac_final_window_sck_meaningful_frames,
        evidence.mac_final_window_sck_sample_ms,
    );
    let tx_aggregate_fps = aggregate_fps(
        evidence.mac_final_window_tx_sent_frames,
        evidence.mac_final_window_tx_sample_ms,
    );
    let has_window =
        evidence.pass_window_start_at.is_some() && evidence.pass_window_end_at.is_some();
    let min_window_seconds = min_pass_window_seconds as f64;
    let observed_window_seconds = p2p_remote_observed_pass_window_seconds(evidence);
    let has_required_soak_window = evidence
        .pass_requested_seconds
        .is_some_and(|seconds| seconds >= min_window_seconds)
        && evidence
            .pass_window_seconds
            .is_some_and(|seconds| seconds >= min_window_seconds)
        && observed_window_seconds.is_some_and(|seconds| seconds >= min_window_seconds);
    let source_frame_age_budget_exceeded = evidence
        .mac_final_window_sck_source_frame_age_max_ms
        .is_some_and(|age| age > P2P_REMOTE_STRICT_SCK_SOURCE_FRAME_AGE_LIMIT_MS);
    let ok = has_window
        && has_required_soak_window
        && evidence.mac_final_window_sck_samples >= required_samples
        && evidence.mac_final_window_tx_samples >= required_samples
        && evidence.mac_final_window_sck_sample_ms > 0
        && evidence.mac_final_window_tx_sample_ms > 0
        && sck_aggregate_fps >= min_fps
        && tx_aggregate_fps >= min_fps
        && evidence
            .mac_final_window_sck_source_frame_repeat_max
            .is_some_and(|repeat| repeat <= P2P_REMOTE_STRICT_SCK_SOURCE_FRAME_REPEAT_LIMIT)
        && evidence.mac_final_window_sck_cadence_timer_fires_total > 0
        && evidence.mac_final_window_sck_cadence_submitted_frames_total > 0
        && evidence
            .mac_final_window_sck_cadence_batch_max
            .is_some_and(|batch| {
                (1..=P2P_REMOTE_STRICT_SCK_CADENCE_CATCH_UP_LIMIT).contains(&batch)
            });
    simple_doctor_check(
        "p2p_remote_mac_final_window_fps",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "passWindowStart={:?} passWindowEnd={:?} observedWindowSeconds={:?} windowSeconds={:?} requestedSeconds={:?} minPassWindowSeconds={} requiredSamples={} sckSamples={} txSamples={} sckSampleMs={} txSampleMs={} finalWindowCaptureFPS={:.1} finalWindowMeaningfulFPS={:.1} finalWindowEncodedFPS={:.1} finalWindowSentFPS={:.1} finalWindowMinCaptureFPS={:?} finalWindowMinMeaningfulFPS={:?} finalWindowMinEncodedFPS={:?} finalWindowMinSentFPS={:?} sckSourceFrameAgeMaxMs={:?} sckSourceFrameAgeBudgetExceeded={} sckSourceFrameRepeatMax={:?} sckCadenceTimerFires={} sckCadenceSubmitted={} sckCadenceCatchUpFrames={} sckCadenceBatchMax={:?}",
            evidence.pass_window_start_at,
            evidence.pass_window_end_at,
            observed_window_seconds,
            evidence.pass_window_seconds,
            evidence.pass_requested_seconds,
            min_pass_window_seconds,
            required_samples,
            evidence.mac_final_window_sck_samples,
            evidence.mac_final_window_tx_samples,
            evidence.mac_final_window_sck_sample_ms,
            evidence.mac_final_window_tx_sample_ms,
            sck_capture_fps,
            sck_meaningful_fps,
            sck_aggregate_fps,
            tx_aggregate_fps,
            evidence.mac_final_window_min_capture_fps,
            evidence.mac_final_window_min_meaningful_fps,
            evidence.mac_final_window_min_encoded_fps,
            evidence.mac_final_window_min_sent_fps,
            evidence.mac_final_window_sck_source_frame_age_max_ms,
            source_frame_age_budget_exceeded,
            evidence.mac_final_window_sck_source_frame_repeat_max,
            evidence.mac_final_window_sck_cadence_timer_fires_total,
            evidence.mac_final_window_sck_cadence_submitted_frames_total,
            evidence.mac_final_window_sck_cadence_catch_up_frames_total,
            evidence.mac_final_window_sck_cadence_batch_max
        ),
    )
}

fn p2p_remote_required_final_window_samples(
    evidence: &P2pRemotePerformanceEvidence,
    min_pass_window_seconds: u64,
) -> u64 {
    let seconds = evidence
        .pass_requested_seconds
        .or(evidence.pass_window_seconds)
        .filter(|seconds| seconds.is_finite() && *seconds > 0.0)
        .unwrap_or(min_pass_window_seconds as f64)
        .max(min_pass_window_seconds as f64);
    (seconds.floor() as u64).saturating_sub(2).max(1)
}

fn p2p_remote_observed_pass_window_seconds(evidence: &P2pRemotePerformanceEvidence) -> Option<f64> {
    let start_at = evidence.pass_window_start_at?;
    let end_at = evidence.pass_window_end_at?;
    let delta_ns = end_at
        .unix_timestamp_nanos()
        .checked_sub(start_at.unix_timestamp_nanos())?;
    (delta_ns > 0).then_some(delta_ns as f64 / 1_000_000_000.0)
}
