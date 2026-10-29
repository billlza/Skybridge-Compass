use crate::performance_budgets::{
    P2P_REMOTE_STRICT_CONTENT_BACKLOG_BYTE_LIMIT, P2P_REMOTE_STRICT_CONTENT_BACKLOG_FRAME_LIMIT,
    P2P_REMOTE_STRICT_MAC_CLOCK_FIRE_TO_DRAIN_LIMIT_MS,
    P2P_REMOTE_STRICT_MAC_COMPLETION_GAP_LIMIT_MS,
    P2P_REMOTE_STRICT_MAC_CONTENT_ACTOR_HOP_LIMIT_MS,
    P2P_REMOTE_STRICT_MAC_CONTENT_CALLBACK_GAP_LIMIT_MS,
    P2P_REMOTE_STRICT_MAC_ENCODED_TO_SUBMIT_LIMIT_MS, P2P_REMOTE_STRICT_MAC_QUEUED_FRAME_LIMIT,
    P2P_REMOTE_STRICT_MAC_SCHEDULE_GAP_LIMIT_MS, P2P_REMOTE_STRICT_MAC_SCHEDULE_JITTER_LIMIT_MS,
    P2P_REMOTE_STRICT_MAC_SUBMIT_GAP_FRAME_BUDGET, P2P_REMOTE_STRICT_MAX_FRAMES_PER_DRAIN,
    P2P_REMOTE_STRICT_MAX_MISSED_CADENCE_SLOTS,
};

use super::selected::MacTxSelectedEvidence;

pub(super) struct MacTxVerdict {
    pub(super) ok: bool,
    pub(super) max_allowed_send_ms: f64,
    pub(super) strict_queued_frame_limit: u64,
    pub(super) wire_send_all: bool,
}

impl MacTxVerdict {
    pub(super) fn level(&self) -> &'static str {
        if self.ok { "info" } else { "error" }
    }
}

pub(super) fn evaluate(selected: &MacTxSelectedEvidence, min_fps: f64) -> MacTxVerdict {
    let max_allowed_send_ms = 200.0;
    let strict_queued_frame_limit = P2P_REMOTE_STRICT_MAC_QUEUED_FRAME_LIMIT;
    let strict_content_backlog_limit = P2P_REMOTE_STRICT_CONTENT_BACKLOG_FRAME_LIMIT;
    let strict_content_backlog_byte_limit = P2P_REMOTE_STRICT_CONTENT_BACKLOG_BYTE_LIMIT;
    let writer_clock_all = selected.writer_clock_all();
    let send_scheduler_all = selected.send_scheduler_all();
    let wire_send_all = selected.wire_send_all();
    let frame_budget_ms = 1_000.0 / min_fps.max(1.0);
    let timing_ok = !selected.uses_final_window
        || (selected
            .schedule_gap_max_ms
            .is_some_and(|ms| ms <= P2P_REMOTE_STRICT_MAC_SCHEDULE_GAP_LIMIT_MS)
            && selected
                .schedule_jitter_max_ms
                .is_some_and(|ms| ms <= P2P_REMOTE_STRICT_MAC_SCHEDULE_JITTER_LIMIT_MS)
            && selected
                .completion_gap_max_ms
                .is_some_and(|ms| ms <= P2P_REMOTE_STRICT_MAC_COMPLETION_GAP_LIMIT_MS)
            && selected
                .content_callback_gap_max_ms
                .is_some_and(|ms| ms <= P2P_REMOTE_STRICT_MAC_CONTENT_CALLBACK_GAP_LIMIT_MS)
            && selected
                .content_actor_hop_max_ms
                .is_some_and(|ms| ms <= P2P_REMOTE_STRICT_MAC_CONTENT_ACTOR_HOP_LIMIT_MS)
            && selected
                .encoded_to_submit_max_ms
                .is_some_and(|ms| ms <= P2P_REMOTE_STRICT_MAC_ENCODED_TO_SUBMIT_LIMIT_MS)
            && selected.submit_gap_max_ms.is_some_and(|ms| {
                ms <= frame_budget_ms * P2P_REMOTE_STRICT_MAC_SUBMIT_GAP_FRAME_BUDGET
            })
            && selected
                .clock_fire_to_drain_max_ms
                .is_some_and(|ms| ms <= P2P_REMOTE_STRICT_MAC_CLOCK_FIRE_TO_DRAIN_LIMIT_MS));
    let ok = selected.latest_sent_fps.is_some_and(|fps| fps >= min_fps)
        && selected
            .latest_encoded_fps
            .is_some_and(|fps| fps >= min_fps)
        && selected.content_backlog_limit_max == Some(strict_content_backlog_limit)
        && selected.content_backlog_byte_limit_max == Some(strict_content_backlog_byte_limit)
        && selected
            .max_frames_per_drain_limit_max
            .is_some_and(|limit| limit <= P2P_REMOTE_STRICT_MAX_FRAMES_PER_DRAIN)
        && selected.max_frames_per_drain_samples == selected.tx_samples
        && selected
            .schedule_budget_max
            .is_some_and(|budget| budget <= P2P_REMOTE_STRICT_MAX_FRAMES_PER_DRAIN)
        && selected
            .missed_cadence_slots_max
            .is_some_and(|slots| slots == P2P_REMOTE_STRICT_MAX_MISSED_CADENCE_SLOTS)
        && selected
            .content_backlog_max
            .is_some_and(|max| max < strict_content_backlog_limit)
        && selected
            .content_backlog_bytes_max
            .is_some_and(|max| max < strict_content_backlog_byte_limit)
        && selected.content_backlog_full_total == 0
        && selected.dropped_total == 0
        && selected.backpressure_total == 0
        && selected.waiting_for_sync_samples == 0
        && selected.sbc2_transport_samples == selected.tx_samples
        && selected.chunk_cap_bytes_max == Some(256 * 1024)
        && selected.max_chunks_per_frame_max == Some(1)
        && wire_send_all
        && selected
            .queued_frames_max
            .is_some_and(|max| max <= strict_queued_frame_limit)
        && selected.stale_queue_catch_up_total == 0
        && selected.max_send_ms <= max_allowed_send_ms
        && writer_clock_all
        && send_scheduler_all
        && selected.queue_backlog_max.unwrap_or(0) == 0
        && selected.queue_age_max_ms.unwrap_or(0.0) <= 100.0
        && timing_ok;
    MacTxVerdict {
        ok,
        max_allowed_send_ms,
        strict_queued_frame_limit,
        wire_send_all,
    }
}
