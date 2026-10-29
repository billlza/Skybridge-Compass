use crate::performance_budgets::P2P_REMOTE_STRICT_METAL_REPLACEMENT_REASON;
use crate::performance_evidence::{
    extract_text_f64, extract_text_u64, extract_text_value, update_max_f64, update_max_u64,
    update_min_f64, update_min_u64,
};

use super::P2pRemotePerformanceEvidence;

pub(super) fn update_p2p_remote_metal_render_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
    is_ios: bool,
) {
    if is_ios && line.contains("Metal render telemetry") {
        evidence.metal_telemetry_samples += 1;
        evidence.metal_queue_drop_total += extract_text_u64(line, "queueDrop").unwrap_or(0);
        evidence.metal_queue_backpressure_total +=
            extract_text_u64(line, "queueBackpressure").unwrap_or(0);
        update_max_u64(
            &mut evidence.metal_queue_capacity_max,
            extract_text_u64(line, "queueCapacity"),
        );
        evidence.metal_coalesced_total +=
            extract_text_u64(line, "coalescedBeforeDraw").unwrap_or(0);
        evidence.metal_realtime_replacement_total +=
            extract_text_u64(line, "realtimeReplacementBeforeDraw").unwrap_or(0);
        if let Some(reason) = extract_text_value(line, "realtimeReplacementReason") {
            evidence.metal_realtime_replacement_reason_samples += 1;
            if reason != P2P_REMOTE_STRICT_METAL_REPLACEMENT_REASON {
                evidence.metal_realtime_replacement_bad_reason_total += 1;
            }
        }
        evidence.metal_manual_draw_total += extract_text_u64(line, "manualDraw").unwrap_or(0);
        update_max_u64(
            &mut evidence.metal_queue_depth_max,
            extract_text_u64(line, "queueDepthMax"),
        );
        evidence.metal_drawable_skip_total += extract_text_u64(line, "drawableSkip").unwrap_or(0);
        evidence.metal_inflight_skip_total += extract_text_u64(line, "inflightSkip").unwrap_or(0);
        evidence.metal_failure_skip_total += extract_text_u64(line, "failureSkip").unwrap_or(0);
        update_max_f64(
            &mut evidence.metal_frame_age_max_ms,
            extract_text_f64(line, "frameAgeMs"),
        );
        if extract_text_f64(line, "frameAgeMs").is_some() {
            evidence.metal_frame_age_samples += 1;
        }
        if let (Some(input), Some(sample_ms)) = (
            extract_text_u64(line, "input"),
            extract_text_f64(line, "sampleMs"),
        ) && sample_ms > 0.0
        {
            let input_fps = input as f64 * 1000.0 / sample_ms;
            update_min_f64(&mut evidence.metal_input_fps_min, Some(input_fps));
            update_max_f64(&mut evidence.metal_input_fps_max, Some(input_fps));
        }
        update_min_f64(
            &mut evidence.metal_display_fps_min,
            extract_text_f64(line, "displayFPS"),
        );
        if let (Some(draw_callbacks), Some(sample_ms)) = (
            extract_text_u64(line, "drawCallbacks"),
            extract_text_f64(line, "sampleMs"),
        ) && sample_ms > 0.0
        {
            let draw_callback_fps = draw_callbacks as f64 * 1000.0 / sample_ms;
            update_min_f64(
                &mut evidence.metal_draw_callback_fps_min,
                Some(draw_callback_fps),
            );
            update_max_f64(
                &mut evidence.metal_draw_callback_fps_max,
                Some(draw_callback_fps),
            );
        }
        update_max_f64(
            &mut evidence.metal_display_fps_max,
            extract_text_f64(line, "displayFPS"),
        );
        update_max_f64(
            &mut evidence.metal_submitted_fps_max,
            extract_text_f64(line, "submittedFPS"),
        );
        update_min_u64(
            &mut evidence.metal_display_link_target_fps_min,
            extract_text_u64(line, "displayLinkTargetFPS"),
        );
        update_min_u64(
            &mut evidence.metal_display_link_pump_fps_min,
            extract_text_u64(line, "displayLinkPumpFPS"),
        );
        evidence.metal_strict_high_rate_cadence_seen |=
            extract_text_value(line, "displayLink").as_deref() == Some("mtkview-native")
                && extract_text_value(line, "displayCadence").as_deref()
                    == Some("strict-60-native-pump-catch-up-vsync");
        let submitted = extract_text_u64(line, "submitted").unwrap_or(0);
        let direct_bgra = extract_text_u64(line, "directBGRA").unwrap_or(0);
        let ci_fallback = extract_text_u64(line, "ciFallback").unwrap_or(0);
        evidence.metal_ci_fallback_total += ci_fallback;
        if submitted > 0 && direct_bgra != submitted {
            evidence.metal_direct_bgra_mismatch = true;
        }
    }
}
