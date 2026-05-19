use crate::p2p_remote_performance_evidence::P2pRemotePerformanceEvidence;
use crate::performance_budgets::{
    P2P_REMOTE_STRICT_IOS_COMPLETE_FRAMES_PER_DRAIN_LIMIT, P2P_REMOTE_STRICT_IOS_READ_AHEAD_MODE,
    P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_DELAY_LIMIT_MS,
    P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_MODE,
    P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_QUEUE_DEPTH_LIMIT,
    P2P_REMOTE_STRICT_RAW_RECEIVE_GAP_FRAME_BUDGET,
};
use crate::{DoctorCheck, simple_doctor_check};

use super::common::p2p_remote_has_final_window;

pub(crate) fn check_p2p_remote_ios_raw_latency(
    evidence: &P2pRemotePerformanceEvidence,
    min_fps: f64,
) -> DoctorCheck {
    let frame_budget_ms = 1_000.0 / min_fps.max(1.0);
    let uses_final_window =
        p2p_remote_has_final_window(evidence) || evidence.final_lan_rx_samples > 0;
    let raw_gap = if uses_final_window {
        evidence.final_raw_chunk_gap_ms.unwrap_or(0.0)
    } else {
        evidence.max_raw_chunk_gap_ms.unwrap_or(0.0)
    };
    let main_hop = if uses_final_window {
        evidence.final_raw_chunk_main_hop_ms.unwrap_or(0.0)
    } else {
        evidence.max_raw_chunk_main_hop_ms.unwrap_or(0.0)
    };
    let complete_frames_per_drain = if uses_final_window {
        evidence
            .final_ios_complete_frames_per_drain_max
            .unwrap_or(0)
    } else {
        evidence.ios_complete_frames_per_drain_max.unwrap_or(0)
    };
    let read_ahead_samples = if uses_final_window {
        evidence.final_lan_rx_read_ahead_samples
    } else {
        evidence.ios_lan_rx_samples
    };
    let rx_samples = if uses_final_window {
        evidence.final_lan_rx_samples
    } else {
        evidence.ios_lan_rx_samples
    };
    let strict_read_ahead_samples = if uses_final_window {
        evidence.final_lan_rx_strict_read_ahead_samples
    } else {
        evidence.ios_lan_rx_strict_read_ahead_samples
    };
    let sample_ms = if uses_final_window {
        evidence.final_lan_rx_sample_ms
    } else {
        evidence.ios_lan_rx_sample_ms
    };
    let screen_delivery_samples = if uses_final_window {
        evidence.final_lan_rx_screen_delivery_samples
    } else {
        evidence.ios_lan_rx_screen_delivery_samples
    };
    let strict_screen_delivery_samples = if uses_final_window {
        evidence.final_lan_rx_strict_screen_delivery_samples
    } else {
        evidence.ios_lan_rx_strict_screen_delivery_samples
    };
    let screen_delivery_delivered_total = if uses_final_window {
        evidence.final_lan_rx_screen_delivery_delivered_total
    } else {
        evidence.ios_lan_rx_screen_delivery_delivered_total
    };
    let screen_delivery_queue_depth_max = if uses_final_window {
        evidence
            .final_lan_rx_screen_delivery_queue_depth_max
            .unwrap_or(0)
    } else {
        evidence
            .ios_lan_rx_screen_delivery_queue_depth_max
            .unwrap_or(0)
    };
    let screen_delivery_delay_max_ms = if uses_final_window {
        evidence
            .final_lan_rx_screen_delivery_delay_max_ms
            .unwrap_or(0.0)
    } else {
        evidence
            .ios_lan_rx_screen_delivery_delay_max_ms
            .unwrap_or(0.0)
    };
    let screen_delivery_fps = if sample_ms > 0 {
        Some(screen_delivery_delivered_total as f64 * 1_000.0 / sample_ms as f64)
    } else {
        None
    };
    let screen_delivery_fps_ok = screen_delivery_fps.is_some_and(|fps| fps >= min_fps);
    let max_allowed_raw_gap_ms =
        frame_budget_ms * P2P_REMOTE_STRICT_RAW_RECEIVE_GAP_FRAME_BUDGET as f64;
    let ok = raw_gap <= max_allowed_raw_gap_ms
        && main_hop <= 100.0
        && complete_frames_per_drain <= P2P_REMOTE_STRICT_IOS_COMPLETE_FRAMES_PER_DRAIN_LIMIT
        && read_ahead_samples > 0
        && read_ahead_samples == rx_samples
        && strict_read_ahead_samples == read_ahead_samples
        && screen_delivery_samples > 0
        && screen_delivery_samples == rx_samples
        && strict_screen_delivery_samples == screen_delivery_samples
        && screen_delivery_delivered_total > 0
        && screen_delivery_fps_ok
        && screen_delivery_queue_depth_max
            <= P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_QUEUE_DEPTH_LIMIT
        && screen_delivery_delay_max_ms <= P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_DELAY_LIMIT_MS;
    simple_doctor_check(
        "p2p_remote_ios_raw_latency",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "finalWindow={} rawChunkGapMaxMs={:.1} maxAllowedRawGapMs={:.1} rawChunkMainHopMaxMs={:.1} completeFramesPerDrainMax={} readAheadStrictSamples={}/{} screenDeliveryStrictSamples={}/{} screenDeliveryDelivered={} screenDeliveryFPS={} screenDeliveryQueueDepthMax={} screenDeliveryDelayMaxMs={:.1} rxSamples={} expectedReadAhead={} expectedScreenDelivery={} frameBudgetMs={:.1}",
            uses_final_window,
            raw_gap,
            max_allowed_raw_gap_ms,
            main_hop,
            complete_frames_per_drain,
            strict_read_ahead_samples,
            read_ahead_samples,
            strict_screen_delivery_samples,
            screen_delivery_samples,
            screen_delivery_delivered_total,
            screen_delivery_fps
                .map(|fps| format!("{fps:.1}"))
                .unwrap_or_else(|| "missing".to_owned()),
            screen_delivery_queue_depth_max,
            screen_delivery_delay_max_ms,
            rx_samples,
            P2P_REMOTE_STRICT_IOS_READ_AHEAD_MODE,
            P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_MODE,
            frame_budget_ms
        ),
    )
}
