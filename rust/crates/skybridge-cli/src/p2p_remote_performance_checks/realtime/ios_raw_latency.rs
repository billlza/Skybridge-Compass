use crate::p2p_remote_performance_evidence::P2pRemotePerformanceEvidence;
use crate::performance_budgets::{
    P2P_REMOTE_STRICT_IOS_COMPLETE_FRAMES_PER_DRAIN_LIMIT, P2P_REMOTE_STRICT_IOS_DECODE_FEED_MODE,
    P2P_REMOTE_STRICT_IOS_DECODE_IN_FLIGHT_LIMIT, P2P_REMOTE_STRICT_IOS_DECODE_PENDING_LIMIT,
    P2P_REMOTE_STRICT_IOS_PARSER_DRAIN_BUDGET_MS, P2P_REMOTE_STRICT_IOS_PARSER_MODE,
    P2P_REMOTE_STRICT_IOS_PARSER_STAGE_BUDGET_MS, P2P_REMOTE_STRICT_IOS_QUEUE_HOP_LIMIT_MS,
    P2P_REMOTE_STRICT_IOS_READ_AHEAD_MODE, P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_DELAY_LIMIT_MS,
    P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_MODE,
    P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_QUEUE_DEPTH_LIMIT,
    P2P_REMOTE_STRICT_IOS_SCREEN_WIRE_FORMAT, P2P_REMOTE_STRICT_RAW_RECEIVE_GAP_FRAME_BUDGET,
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
    let raw_main_hop = if uses_final_window {
        evidence.final_raw_chunk_main_hop_ms.unwrap_or(0.0)
    } else {
        evidence.max_raw_chunk_main_hop_ms.unwrap_or(0.0)
    };
    let main_hop = if uses_final_window {
        evidence.final_lan_rx_main_hop_max_ms.unwrap_or(0.0)
    } else {
        evidence.lan_rx_main_hop_max_ms.unwrap_or(0.0)
    };
    let complete_frames_per_drain = if uses_final_window {
        evidence
            .final_ios_complete_frames_per_drain_max
            .unwrap_or(0)
    } else {
        evidence.ios_complete_frames_per_drain_max.unwrap_or(0)
    };
    let parser_drain_samples = if uses_final_window {
        evidence.final_ios_parser_drain_samples
    } else {
        evidence.ios_parser_drain_samples
    };
    let parser_drain_max_ms = if uses_final_window {
        evidence.final_ios_parser_drain_max_ms.unwrap_or(0.0)
    } else {
        evidence.ios_parser_drain_max_ms.unwrap_or(0.0)
    };
    let parser_budget_samples = if uses_final_window {
        evidence.final_ios_parser_budget_samples
    } else {
        evidence.ios_parser_budget_samples
    };
    let parser_budget_max_ms = if uses_final_window {
        evidence.final_ios_parser_budget_max_ms.unwrap_or(0.0)
    } else {
        evidence.ios_parser_budget_max_ms.unwrap_or(0.0)
    };
    let parser_budget_hits_total = if uses_final_window {
        evidence.final_ios_parser_budget_hits_total
    } else {
        evidence.ios_parser_budget_hits_total
    };
    let parse_queue_delay_max_ms = if uses_final_window {
        evidence.final_ios_parse_queue_delay_max_ms
    } else {
        evidence.ios_parse_queue_delay_max_ms
    };
    let parser_actor_hop_max_ms = if uses_final_window {
        evidence.final_ios_parser_actor_hop_max_ms
    } else {
        evidence.ios_parser_actor_hop_max_ms
    };
    let parser_stage_max_ms = if uses_final_window {
        evidence.final_ios_parser_stage_max_ms
    } else {
        evidence.ios_parser_stage_max_ms
    };
    let apply_queue_delay_max_ms = if uses_final_window {
        evidence.final_ios_apply_queue_delay_max_ms
    } else {
        evidence.ios_apply_queue_delay_max_ms
    };
    let screen_apply_max_ms = if uses_final_window {
        evidence.final_ios_screen_apply_max_ms
    } else {
        evidence.ios_screen_apply_max_ms
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
    let frame_clock_samples = if uses_final_window {
        evidence.final_lan_rx_frame_clock_samples
    } else {
        evidence.ios_lan_rx_frame_clock_samples
    };
    let socket_arrival_frame_clock_samples = if uses_final_window {
        evidence.final_lan_rx_socket_arrival_frame_clock_samples
    } else {
        evidence.ios_lan_rx_socket_arrival_frame_clock_samples
    };
    let socket_metric_clock_samples = if uses_final_window {
        evidence.final_lan_rx_socket_metric_clock_samples
    } else {
        evidence.ios_lan_rx_socket_metric_clock_samples
    };
    let local_socket_metric_clock_samples = if uses_final_window {
        evidence.final_lan_rx_local_socket_metric_clock_samples
    } else {
        evidence.ios_lan_rx_local_socket_metric_clock_samples
    };
    let parser_mode_samples = if uses_final_window {
        evidence.final_lan_rx_parser_samples
    } else {
        evidence.ios_lan_rx_parser_samples
    };
    let strict_parser_mode_samples = if uses_final_window {
        evidence.final_lan_rx_strict_parser_samples
    } else {
        evidence.ios_lan_rx_strict_parser_samples
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
    let screen_delivery_attempted_total = if uses_final_window {
        evidence.final_lan_rx_screen_delivery_attempted_total
    } else {
        evidence.ios_lan_rx_screen_delivery_attempted_total
    };
    let screen_delivery_backpressure_total = if uses_final_window {
        evidence.final_lan_rx_screen_delivery_backpressure_total
    } else {
        evidence.ios_lan_rx_screen_delivery_backpressure_total
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
    let decode_feed_samples = if uses_final_window {
        evidence.final_lan_rx_decode_feed_samples
    } else {
        evidence.ios_lan_rx_decode_feed_samples
    };
    let strict_decode_feed_samples = if uses_final_window {
        evidence.final_lan_rx_strict_decode_feed_samples
    } else {
        evidence.ios_lan_rx_strict_decode_feed_samples
    };
    let socket_to_decode_feed_samples = if uses_final_window {
        evidence.final_lan_rx_socket_to_decode_feed_samples
    } else {
        evidence.ios_lan_rx_socket_to_decode_feed_samples
    };
    let socket_to_decode_feed_max_ms = if uses_final_window {
        evidence.final_lan_rx_socket_to_decode_feed_max_ms
    } else {
        evidence.ios_lan_rx_socket_to_decode_feed_max_ms
    };
    let socket_to_apply_end_samples = if uses_final_window {
        evidence.final_lan_rx_socket_to_apply_end_samples
    } else {
        evidence.ios_lan_rx_socket_to_apply_end_samples
    };
    let socket_to_apply_end_max_ms = if uses_final_window {
        evidence.final_lan_rx_socket_to_apply_end_max_ms
    } else {
        evidence.ios_lan_rx_socket_to_apply_end_max_ms
    };
    let decode_attempted_total = if uses_final_window {
        evidence.final_lan_rx_decode_attempted_total
    } else {
        evidence.ios_lan_rx_decode_attempted_total
    };
    let decode_accepted_total = if uses_final_window {
        evidence.final_lan_rx_decode_accepted_total
    } else {
        evidence.ios_lan_rx_decode_accepted_total
    };
    let decode_dropped_total = if uses_final_window {
        evidence.final_lan_rx_decode_dropped_total
    } else {
        evidence.ios_lan_rx_decode_dropped_total
    };
    let decode_pending_max = if uses_final_window {
        evidence.final_lan_rx_decode_pending_max.unwrap_or(0)
    } else {
        evidence.ios_lan_rx_decode_pending_max.unwrap_or(0)
    };
    let decode_in_flight_max = if uses_final_window {
        evidence.final_lan_rx_decode_in_flight_max.unwrap_or(0)
    } else {
        evidence.ios_lan_rx_decode_in_flight_max.unwrap_or(0)
    };
    let decode_waiting_sync_total = if uses_final_window {
        evidence.final_lan_rx_decode_waiting_sync_total
    } else {
        evidence.ios_lan_rx_decode_waiting_sync_total
    };
    let decode_resets_total = if uses_final_window {
        evidence.final_lan_rx_decode_resets_total
    } else {
        evidence.ios_lan_rx_decode_resets_total
    };
    let screen_wire_samples = if uses_final_window {
        evidence.final_lan_rx_screen_wire_samples
    } else {
        evidence.ios_lan_rx_screen_wire_samples
    };
    let strict_screen_wire_samples = if uses_final_window {
        evidence.final_lan_rx_strict_screen_wire_samples
    } else {
        evidence.ios_lan_rx_strict_screen_wire_samples
    };
    let sbc2_frames = if uses_final_window {
        evidence.final_lan_rx_sbc2_frames
    } else {
        evidence.ios_lan_rx_sbc2_frames
    };
    let sbc2_chunks = if uses_final_window {
        evidence.final_lan_rx_sbc2_chunks
    } else {
        evidence.ios_lan_rx_sbc2_chunks
    };
    let sbc2_frame_samples = if uses_final_window {
        evidence.final_lan_rx_sbc2_frame_samples
    } else {
        evidence.ios_lan_rx_sbc2_frame_samples
    };
    let sbc2_chunk_samples = if uses_final_window {
        evidence.final_lan_rx_sbc2_chunk_samples
    } else {
        evidence.ios_lan_rx_sbc2_chunk_samples
    };
    let strict_sbc2_samples = if uses_final_window {
        evidence.final_lan_rx_strict_sbc2_samples
    } else {
        evidence.ios_lan_rx_strict_sbc2_samples
    };
    let lan_rx_screen_fps = if uses_final_window {
        evidence.final_lan_rx_min_screen_fps
    } else {
        evidence.min_ios_screen_fps
    };
    let lan_rx_screen_fps_ok = lan_rx_screen_fps.is_some_and(|fps| fps >= min_fps);
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
        && raw_main_hop <= 100.0
        && complete_frames_per_drain <= P2P_REMOTE_STRICT_IOS_COMPLETE_FRAMES_PER_DRAIN_LIMIT
        && parser_drain_samples > 0
        && parser_drain_samples == rx_samples
        && parser_drain_max_ms <= parser_budget_max_ms
        && parser_budget_samples > 0
        && parser_budget_samples == rx_samples
        && parser_budget_max_ms <= P2P_REMOTE_STRICT_IOS_PARSER_DRAIN_BUDGET_MS
        && parser_budget_hits_total == 0
        && parse_queue_delay_max_ms
            .is_some_and(|ms| ms <= P2P_REMOTE_STRICT_IOS_QUEUE_HOP_LIMIT_MS)
        && parser_actor_hop_max_ms.is_some_and(|ms| ms <= P2P_REMOTE_STRICT_IOS_QUEUE_HOP_LIMIT_MS)
        && parser_stage_max_ms.is_some_and(|ms| ms <= P2P_REMOTE_STRICT_IOS_PARSER_STAGE_BUDGET_MS)
        && apply_queue_delay_max_ms
            .is_some_and(|ms| ms <= P2P_REMOTE_STRICT_IOS_QUEUE_HOP_LIMIT_MS)
        && screen_apply_max_ms.is_some_and(|ms| ms <= P2P_REMOTE_STRICT_IOS_QUEUE_HOP_LIMIT_MS)
        && evidence.ios_lan_parser_slow_events == 0
        && read_ahead_samples > 0
        && read_ahead_samples == rx_samples
        && strict_read_ahead_samples == read_ahead_samples
        && frame_clock_samples == rx_samples
        && socket_arrival_frame_clock_samples == rx_samples
        && socket_metric_clock_samples == rx_samples
        && local_socket_metric_clock_samples == rx_samples
        && parser_mode_samples > 0
        && parser_mode_samples == rx_samples
        && strict_parser_mode_samples == parser_mode_samples
        && screen_delivery_samples > 0
        && screen_delivery_samples == rx_samples
        && strict_screen_delivery_samples == screen_delivery_samples
        && screen_delivery_attempted_total > 0
        && screen_delivery_attempted_total == screen_delivery_delivered_total
        && screen_delivery_delivered_total > 0
        && screen_delivery_backpressure_total == 0
        && screen_delivery_fps_ok
        && screen_delivery_queue_depth_max
            <= P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_QUEUE_DEPTH_LIMIT
        && screen_delivery_delay_max_ms <= P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_DELAY_LIMIT_MS
        && decode_feed_samples > 0
        && decode_feed_samples == rx_samples
        && strict_decode_feed_samples == decode_feed_samples
        && socket_to_decode_feed_samples > 0
        && socket_to_decode_feed_samples == decode_attempted_total
        && socket_to_decode_feed_max_ms
            .is_some_and(|ms| ms <= P2P_REMOTE_STRICT_IOS_QUEUE_HOP_LIMIT_MS)
        && socket_to_apply_end_samples > 0
        && socket_to_apply_end_samples == socket_to_decode_feed_samples
        && socket_to_apply_end_max_ms
            .is_some_and(|ms| ms <= P2P_REMOTE_STRICT_IOS_QUEUE_HOP_LIMIT_MS)
        && decode_attempted_total > 0
        && decode_attempted_total == decode_accepted_total
        && decode_dropped_total == 0
        && decode_pending_max <= P2P_REMOTE_STRICT_IOS_DECODE_PENDING_LIMIT
        && decode_in_flight_max <= P2P_REMOTE_STRICT_IOS_DECODE_IN_FLIGHT_LIMIT
        && decode_waiting_sync_total == 0
        && decode_resets_total == 0
        && screen_wire_samples > 0
        && screen_wire_samples == rx_samples
        && strict_screen_wire_samples == screen_wire_samples
        && sbc2_frame_samples == rx_samples
        && sbc2_chunk_samples == rx_samples
        && strict_sbc2_samples == rx_samples
        && sbc2_frames > 0
        && sbc2_chunks >= sbc2_frames
        && lan_rx_screen_fps_ok;
    simple_doctor_check(
        "p2p_remote_ios_raw_latency",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "finalWindow={} rawChunkGapMaxMs={:.1} maxAllowedRawGapMs={:.1} maxMainHopMs={:.1} rawChunkMainHopMaxMs={:.1} completeFramesPerDrainMax={} parserDrainSamples={}/{} parserDrainMaxMs={:.1} parserBudgetSamples={}/{} parserBudgetMsMax={:.1} parserBudgetHits={} expectedParserBudgetMs={:.1} parserStrictSamples={}/{} expectedParser={} parseQueueDelayMaxMs={} parserActorHopMaxMs={} parserStageMaxMs={} applyQueueDelayMaxMs={} screenApplyMaxMs={} parserSlowEvents={} parserSlowDrainMaxMs={} parserSlowStageMaxMs={} queueHopLimitMs={:.1} parserStageBudgetMs={:.1} readAheadStrictSamples={}/{} rxFrameClockSamples={}/{} socketArrivalFrameClockSamples={}/{} socketMetricClockSamples={}/{} localSocketMetricClockSamples={}/{} screenDeliveryStrictSamples={}/{} screenDeliveryAttempted={} screenDeliveryDelivered={} screenDeliveryBackpressure={} lanRxScreenFPS={} screenDeliveryFPS={} screenDeliveryQueueDepthMax={} screenDeliveryDelayMaxMs={:.1} decodeFeedStrictSamples={}/{} expectedDecodeFeed={} socketToDecodeFeedSamples={}/{} socketToDecodeFeedMaxMs={} socketToApplyEndSamples={}/{} socketToApplyEndMaxMs={} decodeAttempted={} decodeAccepted={} decodeDropped={} decodePendingMax={} decodePendingLimit={} decodeInFlightMax={} decodeInFlightLimit={} decodeWaitingSyncSamples={} decodeResets={} screenWireStrictSamples={}/{} expectedScreenWire={} sbc2StrictSamples={}/{} sbc2FrameSamples={} sbc2ChunkSamples={} sbc2Frames={} sbc2Chunks={} rxSamples={} expectedReadAhead={} expectedScreenDelivery={} frameBudgetMs={:.1}",
            uses_final_window,
            raw_gap,
            max_allowed_raw_gap_ms,
            main_hop,
            raw_main_hop,
            complete_frames_per_drain,
            parser_drain_samples,
            rx_samples,
            parser_drain_max_ms,
            parser_budget_samples,
            rx_samples,
            parser_budget_max_ms,
            parser_budget_hits_total,
            P2P_REMOTE_STRICT_IOS_PARSER_DRAIN_BUDGET_MS,
            strict_parser_mode_samples,
            parser_mode_samples,
            P2P_REMOTE_STRICT_IOS_PARSER_MODE,
            parse_queue_delay_max_ms
                .map(|ms| format!("{ms:.1}"))
                .unwrap_or_else(|| "missing".to_owned()),
            parser_actor_hop_max_ms
                .map(|ms| format!("{ms:.1}"))
                .unwrap_or_else(|| "missing".to_owned()),
            parser_stage_max_ms
                .map(|ms| format!("{ms:.1}"))
                .unwrap_or_else(|| "missing".to_owned()),
            apply_queue_delay_max_ms
                .map(|ms| format!("{ms:.1}"))
                .unwrap_or_else(|| "missing".to_owned()),
            screen_apply_max_ms
                .map(|ms| format!("{ms:.1}"))
                .unwrap_or_else(|| "missing".to_owned()),
            evidence.ios_lan_parser_slow_events,
            evidence
                .ios_lan_parser_slow_drain_max_ms
                .map(|ms| format!("{ms:.1}"))
                .unwrap_or_else(|| "missing".to_owned()),
            evidence
                .ios_lan_parser_slow_stage_max_ms
                .map(|ms| format!("{ms:.1}"))
                .unwrap_or_else(|| "missing".to_owned()),
            P2P_REMOTE_STRICT_IOS_QUEUE_HOP_LIMIT_MS,
            P2P_REMOTE_STRICT_IOS_PARSER_STAGE_BUDGET_MS,
            strict_read_ahead_samples,
            read_ahead_samples,
            frame_clock_samples,
            rx_samples,
            socket_arrival_frame_clock_samples,
            rx_samples,
            socket_metric_clock_samples,
            rx_samples,
            local_socket_metric_clock_samples,
            rx_samples,
            strict_screen_delivery_samples,
            screen_delivery_samples,
            screen_delivery_attempted_total,
            screen_delivery_delivered_total,
            screen_delivery_backpressure_total,
            lan_rx_screen_fps
                .map(|fps| format!("{fps:.1}"))
                .unwrap_or_else(|| "missing".to_owned()),
            screen_delivery_fps
                .map(|fps| format!("{fps:.1}"))
                .unwrap_or_else(|| "missing".to_owned()),
            screen_delivery_queue_depth_max,
            screen_delivery_delay_max_ms,
            strict_decode_feed_samples,
            decode_feed_samples,
            P2P_REMOTE_STRICT_IOS_DECODE_FEED_MODE,
            socket_to_decode_feed_samples,
            decode_attempted_total,
            socket_to_decode_feed_max_ms
                .map(|ms| format!("{ms:.1}"))
                .unwrap_or_else(|| "missing".to_owned()),
            socket_to_apply_end_samples,
            socket_to_decode_feed_samples,
            socket_to_apply_end_max_ms
                .map(|ms| format!("{ms:.1}"))
                .unwrap_or_else(|| "missing".to_owned()),
            decode_attempted_total,
            decode_accepted_total,
            decode_dropped_total,
            decode_pending_max,
            P2P_REMOTE_STRICT_IOS_DECODE_PENDING_LIMIT,
            decode_in_flight_max,
            P2P_REMOTE_STRICT_IOS_DECODE_IN_FLIGHT_LIMIT,
            decode_waiting_sync_total,
            decode_resets_total,
            strict_screen_wire_samples,
            screen_wire_samples,
            P2P_REMOTE_STRICT_IOS_SCREEN_WIRE_FORMAT,
            strict_sbc2_samples,
            rx_samples,
            sbc2_frame_samples,
            sbc2_chunk_samples,
            sbc2_frames,
            sbc2_chunks,
            rx_samples,
            P2P_REMOTE_STRICT_IOS_READ_AHEAD_MODE,
            P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_MODE,
            frame_budget_ms
        ),
    )
}
