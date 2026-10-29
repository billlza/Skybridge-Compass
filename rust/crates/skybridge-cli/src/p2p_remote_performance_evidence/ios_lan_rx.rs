use crate::performance_budgets::{
    P2P_REMOTE_STRICT_IOS_DECODE_FEED_MODE, P2P_REMOTE_STRICT_IOS_PARSER_MODE,
    P2P_REMOTE_STRICT_IOS_READ_AHEAD_MODE, P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_MODE,
    P2P_REMOTE_STRICT_IOS_SCREEN_WIRE_FORMAT,
};
use crate::performance_evidence::{
    extract_text_f64, extract_text_u64, extract_text_value, update_max_f64, update_max_u64,
    update_min_f64,
};

use super::P2pRemotePerformanceEvidence;

pub(super) fn update_p2p_remote_ios_lan_rx_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
    is_ios: bool,
) {
    if is_ios && line.contains("ios-lan-parser-slow") {
        evidence.ios_lan_parser_slow_events += 1;
        update_max_f64(
            &mut evidence.ios_lan_parser_slow_drain_max_ms,
            extract_text_f64(line, "drainMs"),
        );
        update_max_f64(
            &mut evidence.ios_lan_parser_slow_stage_max_ms,
            extract_text_f64(line, "parserStageMaxMs"),
        );
    }

    if is_ios && line.contains("ios-lan-remote-rx") {
        evidence.ios_lan_rx_samples += 1;
        evidence.ios_lan_rx_sample_ms += extract_text_u64(line, "sampleMs").unwrap_or(0);
        if extract_text_value(line, "readAhead").as_deref()
            == Some(P2P_REMOTE_STRICT_IOS_READ_AHEAD_MODE)
        {
            evidence.ios_lan_rx_strict_read_ahead_samples += 1;
        }
        if extract_text_value(line, "rxFrameClock").is_some() {
            evidence.ios_lan_rx_frame_clock_samples += 1;
        }
        if extract_text_value(line, "rxFrameClock").as_deref() == Some("socket-arrival") {
            evidence.ios_lan_rx_socket_arrival_frame_clock_samples += 1;
        }
        if extract_text_value(line, "socketMetricClock").is_some() {
            evidence.ios_lan_rx_socket_metric_clock_samples += 1;
        }
        if extract_text_value(line, "socketMetricClock").as_deref() == Some("local-socket-arrival")
        {
            evidence.ios_lan_rx_local_socket_metric_clock_samples += 1;
        }
        if extract_text_value(line, "parser").is_some() {
            evidence.ios_lan_rx_parser_samples += 1;
        }
        if extract_text_value(line, "parser").as_deref() == Some(P2P_REMOTE_STRICT_IOS_PARSER_MODE)
        {
            evidence.ios_lan_rx_strict_parser_samples += 1;
        }
        if extract_text_value(line, "screenDelivery").is_some() {
            evidence.ios_lan_rx_screen_delivery_samples += 1;
        }
        if extract_text_value(line, "screenDelivery").as_deref()
            == Some(P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_MODE)
        {
            evidence.ios_lan_rx_strict_screen_delivery_samples += 1;
        }
        evidence.ios_lan_rx_screen_delivery_attempted_total +=
            extract_text_u64(line, "screenDeliveryAttempted").unwrap_or(0);
        evidence.ios_lan_rx_screen_delivery_delivered_total +=
            extract_text_u64(line, "screenDeliveryDelivered").unwrap_or(0);
        evidence.ios_lan_rx_screen_delivery_backpressure_total +=
            extract_text_u64(line, "screenDeliveryBackpressure").unwrap_or(0);
        update_max_u64(
            &mut evidence.ios_lan_rx_screen_delivery_queue_depth_max,
            extract_text_u64(line, "screenDeliveryQueueDepthMax"),
        );
        update_max_f64(
            &mut evidence.ios_lan_rx_screen_delivery_delay_max_ms,
            extract_text_f64(line, "screenDeliveryDelayMaxMs"),
        );
        if extract_text_value(line, "decodeFeed").is_some() {
            evidence.ios_lan_rx_decode_feed_samples += 1;
        }
        if extract_text_value(line, "decodeFeed").as_deref()
            == Some(P2P_REMOTE_STRICT_IOS_DECODE_FEED_MODE)
        {
            evidence.ios_lan_rx_strict_decode_feed_samples += 1;
        }
        evidence.ios_lan_rx_socket_to_decode_feed_samples +=
            extract_text_u64(line, "socketToDecodeFeedSamples").unwrap_or(0);
        update_max_f64(
            &mut evidence.ios_lan_rx_socket_to_decode_feed_max_ms,
            extract_text_f64(line, "socketToDecodeFeedMaxMs"),
        );
        evidence.ios_lan_rx_socket_to_apply_end_samples +=
            extract_text_u64(line, "socketToApplyEndSamples").unwrap_or(0);
        update_max_f64(
            &mut evidence.ios_lan_rx_socket_to_apply_end_max_ms,
            extract_text_f64(line, "socketToApplyEndMaxMs"),
        );
        evidence.ios_lan_rx_decode_attempted_total +=
            extract_text_u64(line, "decodeAttempted").unwrap_or(0);
        evidence.ios_lan_rx_decode_accepted_total +=
            extract_text_u64(line, "decodeAccepted").unwrap_or(0);
        evidence.ios_lan_rx_decode_dropped_total +=
            extract_text_u64(line, "decodeDropped").unwrap_or(0);
        update_max_u64(
            &mut evidence.ios_lan_rx_decode_pending_max,
            extract_text_u64(line, "decodePendingMax"),
        );
        update_max_u64(
            &mut evidence.ios_lan_rx_decode_in_flight_max,
            extract_text_u64(line, "decodeInFlightMax"),
        );
        evidence.ios_lan_rx_decode_waiting_sync_total +=
            extract_text_u64(line, "decodeWaitingSyncSamples").unwrap_or(0);
        evidence.ios_lan_rx_decode_resets_total +=
            extract_text_u64(line, "decodeResets").unwrap_or(0);
        if extract_text_value(line, "screenWire").is_some() {
            evidence.ios_lan_rx_screen_wire_samples += 1;
        }
        if extract_text_value(line, "screenWire").as_deref()
            == Some(P2P_REMOTE_STRICT_IOS_SCREEN_WIRE_FORMAT)
        {
            evidence.ios_lan_rx_strict_screen_wire_samples += 1;
        }
        let sbc2_frames = extract_text_u64(line, "sbc2Frames");
        let sbc2_chunks = extract_text_u64(line, "sbc2Chunks");
        if sbc2_frames.is_some() {
            evidence.ios_lan_rx_sbc2_frame_samples += 1;
        }
        if sbc2_chunks.is_some() {
            evidence.ios_lan_rx_sbc2_chunk_samples += 1;
        }
        if sbc2_frames
            .zip(sbc2_chunks)
            .is_some_and(|(frames, chunks)| frames > 0 && chunks >= frames)
        {
            evidence.ios_lan_rx_strict_sbc2_samples += 1;
        }
        evidence.ios_lan_rx_sbc2_frames += sbc2_frames.unwrap_or(0);
        evidence.ios_lan_rx_sbc2_chunks += sbc2_chunks.unwrap_or(0);
        update_min_f64(
            &mut evidence.min_ios_screen_fps,
            extract_text_f64(line, "screenFPS"),
        );
        update_max_f64(
            &mut evidence.max_raw_chunk_gap_ms,
            extract_text_f64(line, "rawChunkGapMaxMs"),
        );
        update_max_f64(
            &mut evidence.lan_rx_main_hop_max_ms,
            extract_text_f64(line, "maxMainHopMs"),
        );
        update_max_f64(
            &mut evidence.max_raw_chunk_main_hop_ms,
            extract_text_f64(line, "rawChunkMainHopMaxMs"),
        );
        update_max_u64(
            &mut evidence.ios_complete_frames_per_drain_max,
            extract_text_u64(line, "completeFramesPerDrainMax"),
        );
        if extract_text_f64(line, "parserDrainMaxMs").is_some() {
            evidence.ios_parser_drain_samples += 1;
            update_max_f64(
                &mut evidence.ios_parser_drain_max_ms,
                extract_text_f64(line, "parserDrainMaxMs"),
            );
        }
        if extract_text_f64(line, "parserBudgetMs").is_some() {
            evidence.ios_parser_budget_samples += 1;
            update_max_f64(
                &mut evidence.ios_parser_budget_max_ms,
                extract_text_f64(line, "parserBudgetMs"),
            );
        }
        evidence.ios_parser_budget_hits_total +=
            extract_text_u64(line, "parserBudgetHits").unwrap_or(0);
        update_max_f64(
            &mut evidence.ios_parse_queue_delay_max_ms,
            extract_text_f64(line, "parseQueueDelayMaxMs"),
        );
        update_max_f64(
            &mut evidence.ios_parser_actor_hop_max_ms,
            extract_text_f64(line, "parserActorHopMaxMs"),
        );
        update_max_f64(
            &mut evidence.ios_parser_stage_max_ms,
            extract_text_f64(line, "parserStageMaxMs"),
        );
        update_max_f64(
            &mut evidence.ios_apply_queue_delay_max_ms,
            extract_text_f64(line, "applyQueueDelayMaxMs"),
        );
        update_max_f64(
            &mut evidence.ios_screen_apply_max_ms,
            extract_text_f64(line, "screenApplyMaxMs"),
        );
        evidence.ios_source_samples += extract_text_u64(line, "sourceSamples").unwrap_or(0);
        update_max_f64(
            &mut evidence.ios_source_gap_max_ms,
            extract_text_f64(line, "sourceGapMaxMs"),
        );
        update_max_f64(
            &mut evidence.ios_source_to_read_max_ms,
            extract_text_f64(line, "sourceToReadMaxMs"),
        );
        match extract_text_value(line, "sourceToReadClock").as_deref() {
            Some("remote-wall-clock-unsynced") => {
                evidence.ios_source_to_read_unsynced_clock_samples += 1;
            }
            Some("local-socket-arrival") | Some("clock-synchronized-wall-clock") => {
                evidence.ios_source_to_read_trusted_clock_samples += 1;
            }
            _ => {}
        }
    }
}
