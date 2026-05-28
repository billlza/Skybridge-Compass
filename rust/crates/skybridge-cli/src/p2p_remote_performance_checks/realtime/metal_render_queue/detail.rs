use super::selected::MetalRenderQueueSelectedEvidence;
use super::verdict::MetalRenderQueueVerdict;

pub(super) fn format_metal_render_queue_detail(
    selected: &MetalRenderQueueSelectedEvidence,
    verdict: &MetalRenderQueueVerdict,
) -> String {
    format!(
        "finalWindow={} queueDrop={} queueBackpressure={} queueCapacityMax={:?} queueDepthMax={:?} maxAllowedQueueDepth={} coalescedBeforeDraw={} maxAllowedCoalesced={} realtimeReplacementBeforeDraw={} replacementReasonSamples={} replacementBadReasons={} replacementStructured={} manualDraw={} telemetrySamples={} minTelemetrySamples={} frameAgeSamples={} frameAgeMaxMs={:?} inputFPSGate={:?} inputFPSMin={:?} inputFPSMax={:?} drawCallbackFPSGate={:?} drawCallbackFPSMin={:?} drawCallbackFPSMax={:?} maxAllowedDrawCallbackFPS={:.1} displayFPSGate={:?} displayFPSMin={:?} displayFPSMax={:?} submittedFPSMax={:?} maxAllowedVideoFPS={:.1} minAllowedSampleFPS={:.1} displayLinkTargetFPSMin={:?} displayLinkPumpFPSMin={:?} strictHighRateCadence={} drawableSkip={} inflightSkip={} failureSkip={} ciFallback={} directBGRAMismatch={}",
        selected.uses_final_window,
        selected.queue_drop_total,
        selected.queue_backpressure_total,
        selected.queue_capacity_max,
        selected.queue_depth_max,
        verdict.max_allowed_queue_depth,
        selected.coalesced_total,
        verdict.max_allowed_coalesced,
        selected.realtime_replacement_total,
        selected.realtime_replacement_reason_samples,
        selected.realtime_replacement_bad_reason_total,
        verdict.realtime_replacement_is_structured,
        selected.manual_draw_total,
        selected.telemetry_samples,
        verdict.min_telemetry_samples,
        selected.frame_age_samples,
        selected.frame_age_max_ms,
        selected.input_fps_gate,
        selected.input_fps_min,
        selected.input_fps_max,
        selected.draw_callback_fps_gate,
        selected.draw_callback_fps_min,
        selected.draw_callback_fps_max,
        verdict.max_allowed_draw_callback_fps,
        selected.display_fps_gate,
        selected.display_fps_min,
        selected.display_fps_max,
        selected.submitted_fps_max,
        verdict.max_allowed_video_fps,
        verdict.min_allowed_sample_fps,
        selected.target_fps_min,
        selected.pump_fps_min,
        selected.strict_high_rate_cadence_seen,
        selected.drawable_skip_total,
        selected.inflight_skip_total,
        selected.failure_skip_total,
        selected.ci_fallback_total,
        selected.direct_bgra_mismatch
    )
}
