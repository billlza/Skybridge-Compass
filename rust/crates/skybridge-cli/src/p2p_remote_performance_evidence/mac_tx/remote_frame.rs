use crate::performance_evidence::{
    extract_text_f64, extract_text_u64, extract_text_value, update_max_f64, update_max_u64,
    update_min_f64,
};

use super::P2pRemotePerformanceEvidence;

pub(super) fn update_mac_remote_frame_tx_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
) {
    evidence.mac_tx_samples += 1;
    evidence.mac_tx_sent_frames_total += extract_text_u64(line, "sent").unwrap_or(0);
    evidence.mac_wire_batch_single_frames_total +=
        extract_text_u64(line, "wireBatchSingleFrames").unwrap_or(0);
    evidence.mac_wire_batch_multi_frames_total +=
        extract_text_u64(line, "wireBatchMultiFrames").unwrap_or(0);
    evidence.mac_wire_single_unbatched_frames_total +=
        extract_text_u64(line, "wireSingleUnbatchedFrames").unwrap_or(0);
    if let Some(fps) = extract_text_f64(line, "sentFPS") {
        evidence.mac_latest_sent_fps = Some(fps);
    }
    update_min_f64(
        &mut evidence.mac_min_sent_fps,
        extract_text_f64(line, "sentFPS"),
    );
    update_max_f64(
        &mut evidence.mac_max_send_ms,
        extract_text_f64(line, "maxSendMs"),
    );
    evidence.content_backlog_full_total +=
        extract_text_u64(line, "contentBacklogFull").unwrap_or(0);
    evidence.mac_dropped_total += extract_text_u64(line, "dropped").unwrap_or(0);
    evidence.mac_backpressure_total += extract_text_u64(line, "backpressure").unwrap_or(0);
    evidence.mac_raw_backpressure_total += extract_text_u64(line, "rawBackpressure").unwrap_or(0);
    update_max_u64(
        &mut evidence.content_backlog_max,
        extract_text_u64(line, "contentBacklogMax"),
    );
    update_max_u64(
        &mut evidence.content_backlog_limit_max,
        extract_text_u64(line, "contentBacklogLimit"),
    );
    update_max_u64(
        &mut evidence.content_backlog_bytes_max,
        extract_text_u64(line, "contentBacklogBytesMax"),
    );
    update_max_u64(
        &mut evidence.content_backlog_byte_limit_max,
        extract_text_u64(line, "contentBacklogByteLimit"),
    );
    if let Some(max_frames_per_drain) = extract_text_u64(line, "maxFramesPerDrain") {
        evidence.max_frames_per_drain_samples += 1;
        update_max_u64(
            &mut evidence.max_frames_per_drain_limit_max,
            Some(max_frames_per_drain),
        );
    }
    update_max_u64(
        &mut evidence.schedule_budget_max,
        extract_text_u64(line, "scheduleBudgetMax"),
    );
    update_max_u64(
        &mut evidence.missed_cadence_slots_max,
        extract_text_u64(line, "missedCadenceSlotsMax"),
    );
    update_max_u64(
        &mut evidence.mac_chunk_cap_bytes_max,
        extract_text_u64(line, "chunkCapBytes"),
    );
    update_max_u64(
        &mut evidence.mac_queued_frames_max,
        extract_text_u64(line, "queuedMax"),
    );
    update_max_u64(
        &mut evidence.mac_max_chunks_per_frame_max,
        extract_text_u64(line, "maxChunksPerFrame"),
    );
    if extract_text_value(line, "transport").as_deref() == Some("sbc2-chunked-v1") {
        evidence.mac_sbc2_transport_samples += 1;
    }
    if extract_text_value(line, "waitingForSync").as_deref() == Some("true") {
        evidence.mac_waiting_for_sync_samples += 1;
    }
    evidence.stale_queue_catch_up_total += extract_text_u64(line, "staleQueueCatchUp").unwrap_or(0);
    update_max_u64(
        &mut evidence.queue_backlog_max,
        extract_text_u64(line, "queueBacklog"),
    );
    update_max_f64(
        &mut evidence.queue_age_max_ms,
        extract_text_f64(line, "queueAgeMaxMs"),
    );
    update_max_f64(
        &mut evidence.mac_schedule_gap_max_ms,
        extract_text_f64(line, "scheduleGapMaxMs"),
    );
    update_max_f64(
        &mut evidence.mac_schedule_jitter_max_ms,
        extract_text_f64(line, "scheduleJitterMaxMs"),
    );
    update_max_f64(
        &mut evidence.mac_completion_gap_max_ms,
        extract_text_f64(line, "completionGapMaxMs"),
    );
    update_max_f64(
        &mut evidence.mac_content_callback_gap_max_ms,
        extract_text_f64(line, "contentCallbackGapMaxMs"),
    );
    update_max_f64(
        &mut evidence.mac_content_actor_hop_max_ms,
        extract_text_f64(line, "contentActorHopMaxMs"),
    );
    update_max_f64(
        &mut evidence.mac_encoded_to_submit_max_ms,
        extract_text_f64(line, "encodedToSubmitMaxMs"),
    );
    update_max_f64(
        &mut evidence.mac_submit_gap_max_ms,
        extract_text_f64(line, "submitGapMaxMs"),
    );
    update_max_f64(
        &mut evidence.mac_clock_fire_to_drain_max_ms,
        extract_text_f64(line, "clockFireToDrainMaxMs"),
    );
    if extract_text_value(line, "writerClock").as_deref() == Some("dispatch-source-userinteractive")
    {
        evidence.mac_writer_clock_dispatch = true;
        evidence.mac_writer_clock_dispatch_samples += 1;
    }
    if extract_text_value(line, "source").as_deref() == Some("encoded-direct-pump") {
        evidence.mac_direct_pump_handoff = true;
        evidence.mac_direct_pump_handoff_samples += 1;
    }
    if extract_text_value(line, "sendScheduler").as_deref() == Some("dispatch-clock-only") {
        evidence.mac_send_scheduler_dispatch_samples += 1;
    }
}
