use crate::p2p_remote_performance_evidence::P2pRemotePerformanceEvidence;

pub(super) struct MacTxSelectedEvidence {
    pub(super) uses_final_window: bool,
    pub(super) tx_samples: u64,
    pub(super) latest_sent_fps: Option<f64>,
    pub(super) latest_encoded_fps: Option<f64>,
    pub(super) min_sent_fps: Option<f64>,
    pub(super) min_encoded_fps: Option<f64>,
    pub(super) max_send_ms: f64,
    pub(super) content_backlog_limit_max: Option<u64>,
    pub(super) content_backlog_byte_limit_max: Option<u64>,
    pub(super) max_frames_per_drain_limit_max: Option<u64>,
    pub(super) max_frames_per_drain_samples: u64,
    pub(super) schedule_budget_max: Option<u64>,
    pub(super) missed_cadence_slots_max: Option<u64>,
    pub(super) content_backlog_max: Option<u64>,
    pub(super) content_backlog_bytes_max: Option<u64>,
    pub(super) content_backlog_full_total: u64,
    pub(super) dropped_total: u64,
    pub(super) backpressure_total: u64,
    pub(super) raw_backpressure_total: u64,
    pub(super) waiting_for_sync_samples: u64,
    pub(super) sbc2_transport_samples: u64,
    pub(super) chunk_cap_bytes_max: Option<u64>,
    pub(super) max_chunks_per_frame_max: Option<u64>,
    pub(super) queued_frames_max: Option<u64>,
    pub(super) tx_sent_frames_total: u64,
    pub(super) wire_batch_single_frames: u64,
    pub(super) wire_batch_multi_frames: u64,
    pub(super) wire_single_unbatched_frames: u64,
    pub(super) wire_send_frames_total: u64,
    pub(super) stale_queue_catch_up_total: u64,
    pub(super) queue_backlog_max: Option<u64>,
    pub(super) queue_age_max_ms: Option<f64>,
    pub(super) schedule_gap_max_ms: Option<f64>,
    pub(super) schedule_jitter_max_ms: Option<f64>,
    pub(super) completion_gap_max_ms: Option<f64>,
    pub(super) content_callback_gap_max_ms: Option<f64>,
    pub(super) content_actor_hop_max_ms: Option<f64>,
    pub(super) encoded_to_submit_max_ms: Option<f64>,
    pub(super) submit_gap_max_ms: Option<f64>,
    pub(super) clock_fire_to_drain_max_ms: Option<f64>,
    pub(super) writer_clock_samples: u64,
    pub(super) send_scheduler_samples: u64,
}

impl MacTxSelectedEvidence {
    pub(super) fn from(evidence: &P2pRemotePerformanceEvidence) -> Self {
        let uses_final_window = evidence.mac_final_window_tx_samples > 0;
        let tx_samples = if uses_final_window {
            evidence.mac_final_window_tx_samples
        } else {
            evidence.mac_tx_samples
        };
        let latest_sent_fps = if uses_final_window {
            evidence.mac_final_window_latest_sent_fps
        } else {
            evidence.mac_latest_sent_fps
        };
        let latest_encoded_fps = if uses_final_window {
            evidence.mac_final_window_latest_encoded_fps
        } else {
            evidence.mac_latest_encoded_fps
        };
        let min_sent_fps = if uses_final_window {
            evidence.mac_final_window_min_sent_fps
        } else {
            evidence.mac_min_sent_fps
        };
        let min_encoded_fps = if uses_final_window {
            evidence.mac_final_window_min_encoded_fps
        } else {
            evidence.mac_min_encoded_fps
        };
        let max_send_ms = if uses_final_window {
            evidence.mac_final_window_max_send_ms.unwrap_or(0.0)
        } else {
            evidence.mac_max_send_ms.unwrap_or(0.0)
        };
        let content_backlog_limit_max = if uses_final_window {
            evidence.mac_final_window_content_backlog_limit_max
        } else {
            evidence.content_backlog_limit_max
        };
        let content_backlog_byte_limit_max = if uses_final_window {
            evidence.mac_final_window_content_backlog_byte_limit_max
        } else {
            evidence.content_backlog_byte_limit_max
        };
        let max_frames_per_drain_limit_max = if uses_final_window {
            evidence.mac_final_window_max_frames_per_drain_limit_max
        } else {
            evidence.max_frames_per_drain_limit_max
        };
        let max_frames_per_drain_samples = if uses_final_window {
            evidence.mac_final_window_max_frames_per_drain_samples
        } else {
            evidence.max_frames_per_drain_samples
        };
        let schedule_budget_max = if uses_final_window {
            evidence.mac_final_window_schedule_budget_max
        } else {
            evidence.schedule_budget_max
        };
        let missed_cadence_slots_max = if uses_final_window {
            evidence.mac_final_window_missed_cadence_slots_max
        } else {
            evidence.missed_cadence_slots_max
        };
        let content_backlog_max = if uses_final_window {
            evidence.mac_final_window_content_backlog_max
        } else {
            evidence.content_backlog_max
        };
        let content_backlog_bytes_max = if uses_final_window {
            evidence.mac_final_window_content_backlog_bytes_max
        } else {
            evidence.content_backlog_bytes_max
        };
        let content_backlog_full_total = if uses_final_window {
            evidence.mac_final_window_content_backlog_full_total
        } else {
            evidence.content_backlog_full_total
        };
        let dropped_total = if uses_final_window {
            evidence.mac_final_window_dropped_total
        } else {
            evidence.mac_dropped_total
        };
        let backpressure_total = if uses_final_window {
            evidence.mac_final_window_backpressure_total
        } else {
            evidence.mac_backpressure_total
        };
        let raw_backpressure_total = if uses_final_window {
            evidence.mac_final_window_raw_backpressure_total
        } else {
            evidence.mac_raw_backpressure_total
        };
        let waiting_for_sync_samples = if uses_final_window {
            evidence.mac_final_window_waiting_for_sync_samples
        } else {
            evidence.mac_waiting_for_sync_samples
        };
        let sbc2_transport_samples = if uses_final_window {
            evidence.mac_final_window_sbc2_transport_samples
        } else {
            evidence.mac_sbc2_transport_samples
        };
        let chunk_cap_bytes_max = if uses_final_window {
            evidence.mac_final_window_chunk_cap_bytes_max
        } else {
            evidence.mac_chunk_cap_bytes_max
        };
        let max_chunks_per_frame_max = if uses_final_window {
            evidence.mac_final_window_max_chunks_per_frame_max
        } else {
            evidence.mac_max_chunks_per_frame_max
        };
        let queued_frames_max = if uses_final_window {
            evidence.mac_final_window_queued_frames_max
        } else {
            evidence.mac_queued_frames_max
        };
        let tx_sent_frames_total = if uses_final_window {
            evidence.mac_final_window_tx_sent_frames
        } else {
            evidence.mac_tx_sent_frames_total
        };
        let wire_batch_single_frames = if uses_final_window {
            evidence.mac_final_window_wire_batch_single_frames_total
        } else {
            evidence.mac_wire_batch_single_frames_total
        };
        let wire_batch_multi_frames = if uses_final_window {
            evidence.mac_final_window_wire_batch_multi_frames_total
        } else {
            evidence.mac_wire_batch_multi_frames_total
        };
        let wire_single_unbatched_frames = if uses_final_window {
            evidence.mac_final_window_wire_single_unbatched_frames_total
        } else {
            evidence.mac_wire_single_unbatched_frames_total
        };
        let wire_send_frames_total =
            wire_batch_single_frames + wire_batch_multi_frames + wire_single_unbatched_frames;
        let stale_queue_catch_up_total = if uses_final_window {
            evidence.mac_final_window_stale_queue_catch_up_total
        } else {
            evidence.stale_queue_catch_up_total
        };
        let queue_backlog_max = if uses_final_window {
            evidence.mac_final_window_queue_backlog_max
        } else {
            evidence.queue_backlog_max
        };
        let queue_age_max_ms = if uses_final_window {
            evidence.mac_final_window_queue_age_max_ms
        } else {
            evidence.queue_age_max_ms
        };
        let schedule_gap_max_ms = if uses_final_window {
            evidence.mac_final_window_schedule_gap_max_ms
        } else {
            evidence.mac_schedule_gap_max_ms
        };
        let schedule_jitter_max_ms = if uses_final_window {
            evidence.mac_final_window_schedule_jitter_max_ms
        } else {
            evidence.mac_schedule_jitter_max_ms
        };
        let completion_gap_max_ms = if uses_final_window {
            evidence.mac_final_window_completion_gap_max_ms
        } else {
            evidence.mac_completion_gap_max_ms
        };
        let content_callback_gap_max_ms = if uses_final_window {
            evidence.mac_final_window_content_callback_gap_max_ms
        } else {
            evidence.mac_content_callback_gap_max_ms
        };
        let content_actor_hop_max_ms = if uses_final_window {
            evidence.mac_final_window_content_actor_hop_max_ms
        } else {
            evidence.mac_content_actor_hop_max_ms
        };
        let encoded_to_submit_max_ms = if uses_final_window {
            evidence.mac_final_window_encoded_to_submit_max_ms
        } else {
            evidence.mac_encoded_to_submit_max_ms
        };
        let submit_gap_max_ms = if uses_final_window {
            evidence.mac_final_window_submit_gap_max_ms
        } else {
            evidence.mac_submit_gap_max_ms
        };
        let clock_fire_to_drain_max_ms = if uses_final_window {
            evidence.mac_final_window_clock_fire_to_drain_max_ms
        } else {
            evidence.mac_clock_fire_to_drain_max_ms
        };
        let writer_clock_samples = if uses_final_window {
            evidence.mac_final_window_writer_clock_dispatch_samples
        } else {
            evidence.mac_writer_clock_dispatch_samples
        };
        let send_scheduler_samples = if uses_final_window {
            evidence.mac_final_window_send_scheduler_dispatch_samples
        } else {
            evidence.mac_send_scheduler_dispatch_samples
        };
        Self {
            uses_final_window,
            tx_samples,
            latest_sent_fps,
            latest_encoded_fps,
            min_sent_fps,
            min_encoded_fps,
            max_send_ms,
            content_backlog_limit_max,
            content_backlog_byte_limit_max,
            max_frames_per_drain_limit_max,
            max_frames_per_drain_samples,
            schedule_budget_max,
            missed_cadence_slots_max,
            content_backlog_max,
            content_backlog_bytes_max,
            content_backlog_full_total,
            dropped_total,
            backpressure_total,
            raw_backpressure_total,
            waiting_for_sync_samples,
            sbc2_transport_samples,
            chunk_cap_bytes_max,
            max_chunks_per_frame_max,
            queued_frames_max,
            tx_sent_frames_total,
            wire_batch_single_frames,
            wire_batch_multi_frames,
            wire_single_unbatched_frames,
            wire_send_frames_total,
            stale_queue_catch_up_total,
            queue_backlog_max,
            queue_age_max_ms,
            schedule_gap_max_ms,
            schedule_jitter_max_ms,
            completion_gap_max_ms,
            content_callback_gap_max_ms,
            content_actor_hop_max_ms,
            encoded_to_submit_max_ms,
            submit_gap_max_ms,
            clock_fire_to_drain_max_ms,
            writer_clock_samples,
            send_scheduler_samples,
        }
    }

    pub(super) fn writer_clock_all(&self) -> bool {
        self.tx_samples > 0 && self.writer_clock_samples == self.tx_samples
    }

    pub(super) fn send_scheduler_all(&self) -> bool {
        self.tx_samples > 0 && self.send_scheduler_samples == self.tx_samples
    }

    pub(super) fn wire_send_all(&self) -> bool {
        self.tx_sent_frames_total > 0 && self.wire_send_frames_total == self.tx_sent_frames_total
    }
}
