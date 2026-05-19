use crate::p2p_remote_performance_evidence::P2pRemotePerformanceEvidence;

use super::super::common::{aggregate_fps, p2p_remote_has_final_window};

pub(super) struct MetalRenderQueueSelectedEvidence {
    pub(super) uses_final_window: bool,
    pub(super) queue_capacity_max: Option<u64>,
    pub(super) queue_depth_max: Option<u64>,
    pub(super) max_queue_capacity: u64,
    pub(super) max_queue_depth: u64,
    pub(super) target_fps_min: Option<u64>,
    pub(super) pump_fps_min: Option<u64>,
    pub(super) target_fps: u64,
    pub(super) pump_fps: u64,
    pub(super) submitted_total: u64,
    pub(super) telemetry_samples: u64,
    pub(super) frame_age_samples: u64,
    pub(super) frame_age_max_ms: Option<f64>,
    pub(super) coalesced_total: u64,
    pub(super) realtime_replacement_total: u64,
    pub(super) realtime_replacement_reason_samples: u64,
    pub(super) realtime_replacement_bad_reason_total: u64,
    pub(super) manual_draw_total: u64,
    pub(super) display_fps_min: Option<f64>,
    pub(super) draw_callback_fps_min: Option<f64>,
    pub(super) draw_callback_fps_max: Option<f64>,
    pub(super) display_fps_max: Option<f64>,
    pub(super) submitted_fps_max: Option<f64>,
    pub(super) display_fps_gate: Option<f64>,
    pub(super) draw_callback_fps_gate: Option<f64>,
    pub(super) strict_high_rate_cadence_seen: bool,
    pub(super) queue_drop_total: u64,
    pub(super) queue_backpressure_total: u64,
    pub(super) drawable_skip_total: u64,
    pub(super) inflight_skip_total: u64,
    pub(super) failure_skip_total: u64,
    pub(super) ci_fallback_total: u64,
    pub(super) direct_bgra_mismatch: bool,
}

impl MetalRenderQueueSelectedEvidence {
    pub(super) fn from(evidence: &P2pRemotePerformanceEvidence) -> Self {
        let uses_final_window =
            p2p_remote_has_final_window(evidence) || evidence.final_metal_telemetry_samples > 0;
        let queue_capacity_max = if uses_final_window {
            evidence.final_metal_queue_capacity_max
        } else {
            evidence.metal_queue_capacity_max
        };
        let queue_depth_max = if uses_final_window {
            evidence.final_metal_queue_depth_max
        } else {
            evidence.metal_queue_depth_max
        };
        let target_fps_min = if uses_final_window {
            evidence.final_metal_display_link_target_fps_min
        } else {
            evidence.metal_display_link_target_fps_min
        };
        let pump_fps_min = if uses_final_window {
            evidence.final_metal_display_link_pump_fps_min
        } else {
            evidence.metal_display_link_pump_fps_min
        };
        let display_fps_min = if uses_final_window {
            evidence.final_metal_display_fps_min
        } else {
            evidence.metal_display_fps_min
        };
        let draw_callback_fps_min = if uses_final_window {
            evidence.final_metal_draw_callback_fps_min
        } else {
            evidence.metal_draw_callback_fps_min
        };
        let display_fps_gate = if uses_final_window && evidence.final_metal_sample_ms > 0 {
            Some(aggregate_fps(
                evidence.final_metal_displayed,
                evidence.final_metal_sample_ms,
            ))
        } else {
            display_fps_min
        };
        let draw_callback_fps_gate = if uses_final_window && evidence.final_metal_sample_ms > 0 {
            Some(aggregate_fps(
                evidence.final_metal_draw_callbacks,
                evidence.final_metal_sample_ms,
            ))
        } else {
            draw_callback_fps_min
        };

        Self {
            uses_final_window,
            queue_capacity_max,
            queue_depth_max,
            max_queue_capacity: queue_capacity_max.unwrap_or(u64::MAX),
            max_queue_depth: queue_depth_max.unwrap_or(u64::MAX),
            target_fps_min,
            pump_fps_min,
            target_fps: target_fps_min.unwrap_or(0),
            pump_fps: pump_fps_min.unwrap_or(0),
            submitted_total: if uses_final_window {
                evidence.final_metal_submitted
            } else {
                0
            },
            telemetry_samples: if uses_final_window {
                evidence.final_metal_telemetry_samples
            } else {
                evidence.metal_telemetry_samples
            },
            frame_age_samples: if uses_final_window {
                evidence.final_metal_frame_age_samples
            } else {
                evidence.metal_frame_age_samples
            },
            frame_age_max_ms: if uses_final_window {
                evidence.final_metal_frame_age_max_ms
            } else {
                evidence.metal_frame_age_max_ms
            },
            coalesced_total: if uses_final_window {
                evidence.final_metal_coalesced_total
            } else {
                evidence.metal_coalesced_total
            },
            realtime_replacement_total: if uses_final_window {
                evidence.final_metal_realtime_replacement_total
            } else {
                evidence.metal_realtime_replacement_total
            },
            realtime_replacement_reason_samples: if uses_final_window {
                evidence.final_metal_realtime_replacement_reason_samples
            } else {
                evidence.metal_realtime_replacement_reason_samples
            },
            realtime_replacement_bad_reason_total: if uses_final_window {
                evidence.final_metal_realtime_replacement_bad_reason_total
            } else {
                evidence.metal_realtime_replacement_bad_reason_total
            },
            manual_draw_total: if uses_final_window {
                evidence.final_metal_manual_draw_total
            } else {
                evidence.metal_manual_draw_total
            },
            display_fps_min,
            draw_callback_fps_min,
            draw_callback_fps_max: if uses_final_window {
                evidence.final_metal_draw_callback_fps_max
            } else {
                evidence.metal_draw_callback_fps_max
            },
            display_fps_max: if uses_final_window {
                evidence.final_metal_display_fps_max
            } else {
                evidence.metal_display_fps_max
            },
            submitted_fps_max: if uses_final_window {
                evidence.final_metal_submitted_fps_max
            } else {
                evidence.metal_submitted_fps_max
            },
            display_fps_gate,
            draw_callback_fps_gate,
            strict_high_rate_cadence_seen: if uses_final_window {
                evidence.final_metal_strict_high_rate_cadence_seen
            } else {
                evidence.metal_strict_high_rate_cadence_seen
            },
            queue_drop_total: if uses_final_window {
                evidence.final_metal_queue_drop_total
            } else {
                evidence.metal_queue_drop_total
            },
            queue_backpressure_total: if uses_final_window {
                evidence.final_metal_queue_backpressure_total
            } else {
                evidence.metal_queue_backpressure_total
            },
            drawable_skip_total: if uses_final_window {
                evidence.final_metal_drawable_skip_total
            } else {
                evidence.metal_drawable_skip_total
            },
            inflight_skip_total: if uses_final_window {
                evidence.final_metal_inflight_skip_total
            } else {
                evidence.metal_inflight_skip_total
            },
            failure_skip_total: if uses_final_window {
                evidence.final_metal_failure_skip_total
            } else {
                evidence.metal_failure_skip_total
            },
            ci_fallback_total: if uses_final_window {
                evidence.final_metal_ci_fallback_total
            } else {
                evidence.metal_ci_fallback_total
            },
            direct_bgra_mismatch: if uses_final_window {
                evidence.final_metal_direct_bgra_mismatch
            } else {
                evidence.metal_direct_bgra_mismatch
            },
        }
    }
}
