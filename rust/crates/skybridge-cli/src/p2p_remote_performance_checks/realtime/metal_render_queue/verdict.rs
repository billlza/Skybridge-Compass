use crate::performance_budgets::{
    P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES, P2P_REMOTE_STRICT_METAL_QUEUE_DEPTH_MAX,
    P2P_REMOTE_STRICT_METAL_REPLACEMENT_RATIO_MAX,
};

use super::selected::MetalRenderQueueSelectedEvidence;

pub(super) struct MetalRenderQueueVerdict {
    pub(super) ok: bool,
    pub(super) max_allowed_video_fps: f64,
    pub(super) max_allowed_draw_callback_fps: f64,
    pub(super) max_allowed_queue_depth: u64,
    pub(super) max_allowed_coalesced: u64,
    pub(super) min_allowed_sample_fps: f64,
    pub(super) realtime_replacement_is_structured: bool,
    pub(super) min_telemetry_samples: u64,
}

impl MetalRenderQueueVerdict {
    pub(super) fn level(&self) -> &'static str {
        if self.ok { "info" } else { "error" }
    }
}

pub(super) fn evaluate(
    selected: &MetalRenderQueueSelectedEvidence,
    min_fps: f64,
) -> MetalRenderQueueVerdict {
    let max_allowed_video_fps = selected.target_fps.max(1) as f64 + 3.0;
    let max_allowed_draw_callback_fps =
        selected.pump_fps.max(selected.target_fps).max(1) as f64 + 3.0;
    let max_allowed_queue_depth = P2P_REMOTE_STRICT_METAL_QUEUE_DEPTH_MAX;
    let min_allowed_sample_fps = min_fps;
    let max_allowed_coalesced = if selected.uses_final_window {
        ((selected.submitted_total as f64) * P2P_REMOTE_STRICT_METAL_REPLACEMENT_RATIO_MAX).ceil()
            as u64
    } else {
        0
    };
    let realtime_replacement_is_structured = selected.realtime_replacement_total
        == selected.coalesced_total
        && selected.realtime_replacement_bad_reason_total == 0
        && (selected.coalesced_total == 0 || selected.realtime_replacement_reason_samples > 0);
    let min_telemetry_samples = P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES;
    let ok = selected.telemetry_samples >= min_telemetry_samples
        && selected.max_queue_capacity <= max_allowed_queue_depth
        && selected.max_queue_depth <= max_allowed_queue_depth
        && selected
            .frame_age_max_ms
            .is_some_and(|frame_age_ms| frame_age_ms <= 100.0)
        && selected.frame_age_samples > 0
        && selected.coalesced_total <= max_allowed_coalesced
        && realtime_replacement_is_structured
        && selected.manual_draw_total == 0
        && selected.input_fps_gate.is_some_and(|fps| fps >= min_fps)
        && selected
            .input_fps_min
            .is_some_and(|fps| fps >= min_allowed_sample_fps)
        && selected.display_fps_gate.is_some_and(|fps| fps >= min_fps)
        && selected
            .display_fps_min
            .is_some_and(|fps| fps >= min_allowed_sample_fps)
        && selected
            .draw_callback_fps_gate
            .is_some_and(|fps| fps >= min_fps)
        && selected
            .draw_callback_fps_max
            .is_some_and(|fps| fps <= max_allowed_draw_callback_fps)
        && selected
            .display_fps_max
            .is_some_and(|fps| fps <= max_allowed_video_fps)
        && selected
            .submitted_fps_max
            .is_some_and(|fps| fps <= max_allowed_video_fps)
        && selected.target_fps >= 59
        && selected.pump_fps >= selected.target_fps
        && selected.strict_high_rate_cadence_seen
        && selected.queue_drop_total == 0
        && selected.drawable_skip_total == 0
        && selected.inflight_skip_total == 0
        && selected.failure_skip_total == 0
        && selected.ci_fallback_total == 0
        && !selected.direct_bgra_mismatch;

    MetalRenderQueueVerdict {
        ok,
        max_allowed_video_fps,
        max_allowed_draw_callback_fps,
        max_allowed_queue_depth,
        max_allowed_coalesced,
        min_allowed_sample_fps,
        realtime_replacement_is_structured,
        min_telemetry_samples,
    }
}
