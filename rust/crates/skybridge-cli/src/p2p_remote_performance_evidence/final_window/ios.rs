use crate::performance_budgets::{
    P2P_REMOTE_STRICT_IOS_READ_AHEAD_MODE, P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_MODE,
    P2P_REMOTE_STRICT_METAL_REPLACEMENT_REASON,
};
use crate::performance_evidence::{
    extract_text_f64, extract_text_u64, extract_text_value, update_max_f64, update_max_u64,
    update_min_f64, update_min_u64,
};

use super::super::P2pRemotePerformanceEvidence;

pub(crate) fn update_p2p_remote_final_window_ios_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
) {
    if line.contains("remote-desktop") {
        let is_pass_line =
            line.contains("remote-desktop-pass") || extract_text_u64(line, "pass") == Some(1);
        if is_pass_line {
            evidence.final_ios_remote_desktop_pass = true;
        }
        if line.contains("remote-desktop status") || line.contains("remote-desktop-pass") {
            let audio_rx_recv = extract_text_u64(line, "audioRxRecv");
            let audio_rx_decoded = extract_text_u64(line, "audioRxDecoded");
            let audio_rx_played = extract_text_u64(line, "audioRxPlayed");
            if audio_rx_recv.is_some() || audio_rx_decoded.is_some() || audio_rx_played.is_some() {
                evidence.final_audio_status_samples += 1;
                update_min_u64(&mut evidence.final_audio_rx_recv_min, audio_rx_recv);
                update_max_u64(&mut evidence.final_audio_rx_recv_max, audio_rx_recv);
                update_min_u64(&mut evidence.final_audio_rx_decoded_min, audio_rx_decoded);
                update_max_u64(&mut evidence.final_audio_rx_decoded_max, audio_rx_decoded);
                update_min_u64(&mut evidence.final_audio_rx_played_min, audio_rx_played);
                update_max_u64(&mut evidence.final_audio_rx_played_max, audio_rx_played);
            }
            if let Some(fps) = extract_text_f64(line, "fps") {
                evidence.final_ios_fps = Some(fps);
            }
            if let Some(fps) = extract_text_f64(line, "rxFps") {
                evidence.final_ios_rx_fps = Some(fps);
            }
            if is_pass_line {
                if let Some(fps) = extract_text_f64(line, "windowFPS") {
                    evidence.final_ios_window_fps = Some(fps);
                }
                if let Some(fps) = extract_text_f64(line, "windowRxFps") {
                    evidence.final_ios_window_rx_fps = Some(fps);
                }
                let required = extract_text_u64(line, "twoSecondRequiredFrames");
                let display = extract_text_u64(line, "min2sDisplayFrames")
                    .or_else(|| extract_text_u64(line, "last2sDisplayFrames"));
                let rx = extract_text_u64(line, "min2sRxFrames")
                    .or_else(|| extract_text_u64(line, "last2sRxFrames"));
                let rolling_display = extract_text_u64(line, "rollingDisplayCadencePass")
                    .or_else(|| extract_text_u64(line, "rollingCadencePass"));
                let rolling_rx = extract_text_u64(line, "rollingRxCadencePass");
                let rolling = extract_text_u64(line, "rollingCombinedCadencePass").or_else(|| {
                    rolling_display
                        .zip(rolling_rx)
                        .map_or(rolling_display, |(display, rx)| {
                            Some(if display == 1 && rx == 1 { 1 } else { 0 })
                        })
                });
                if required.is_some() || display.is_some() || rx.is_some() || rolling.is_some() {
                    evidence.final_ios_cadence_samples += 1;
                    update_min_u64(&mut evidence.final_ios_min_2s_display_frames_min, display);
                    update_min_u64(&mut evidence.final_ios_min_2s_rx_frames_min, rx);
                    update_max_u64(
                        &mut evidence.final_ios_two_second_required_frames_max,
                        required,
                    );
                    let cadence_ok = rolling == Some(1)
                        && required.is_some()
                        && display
                            .zip(required)
                            .is_some_and(|(frames, required)| frames >= required)
                        && rx
                            .zip(required)
                            .is_some_and(|(frames, required)| frames >= required);
                    if !cadence_ok {
                        evidence.final_ios_cadence_failures += 1;
                    }
                }
            }
        }
    }

    if line.contains("ios-lan-remote-rx") {
        evidence.final_lan_rx_samples += 1;
        evidence.final_lan_rx_sample_ms += extract_text_u64(line, "sampleMs").unwrap_or(0);
        evidence.final_lan_rx_screen_frames += extract_text_u64(line, "screenFrames").unwrap_or(0);
        evidence.final_lan_rx_sbc2_frames += extract_text_u64(line, "sbc2Frames").unwrap_or(0);
        evidence.final_lan_rx_sbc2_chunks += extract_text_u64(line, "sbc2Chunks").unwrap_or(0);
        if extract_text_value(line, "readAhead").is_some() {
            evidence.final_lan_rx_read_ahead_samples += 1;
        }
        if extract_text_value(line, "readAhead").as_deref()
            == Some(P2P_REMOTE_STRICT_IOS_READ_AHEAD_MODE)
        {
            evidence.final_lan_rx_strict_read_ahead_samples += 1;
        }
        if extract_text_value(line, "screenDelivery").is_some() {
            evidence.final_lan_rx_screen_delivery_samples += 1;
        }
        if extract_text_value(line, "screenDelivery").as_deref()
            == Some(P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_MODE)
        {
            evidence.final_lan_rx_strict_screen_delivery_samples += 1;
        }
        evidence.final_lan_rx_screen_delivery_delivered_total +=
            extract_text_u64(line, "screenDeliveryDelivered").unwrap_or(0);
        update_max_u64(
            &mut evidence.final_lan_rx_screen_delivery_queue_depth_max,
            extract_text_u64(line, "screenDeliveryQueueDepthMax"),
        );
        update_max_f64(
            &mut evidence.final_lan_rx_screen_delivery_delay_max_ms,
            extract_text_f64(line, "screenDeliveryDelayMaxMs"),
        );
        update_max_f64(
            &mut evidence.final_lan_rx_max_screen_fps,
            extract_text_f64(line, "screenFPS"),
        );
        update_max_f64(
            &mut evidence.final_lan_rx_max_gap_ms,
            extract_text_f64(line, "maxGapMs"),
        );
        evidence.final_lan_rx_raw_chunks += extract_text_u64(line, "rawChunks").unwrap_or(0);
        update_max_f64(
            &mut evidence.final_raw_chunk_gap_ms,
            extract_text_f64(line, "rawChunkGapMaxMs"),
        );
        update_max_f64(
            &mut evidence.final_raw_chunk_main_hop_ms,
            extract_text_f64(line, "rawChunkMainHopMaxMs"),
        );
        update_max_u64(
            &mut evidence.final_ios_complete_frames_per_drain_max,
            extract_text_u64(line, "completeFramesPerDrainMax"),
        );
        evidence.final_ios_source_samples += extract_text_u64(line, "sourceSamples").unwrap_or(0);
        update_max_f64(
            &mut evidence.final_ios_source_gap_max_ms,
            extract_text_f64(line, "sourceGapMaxMs"),
        );
        update_max_f64(
            &mut evidence.final_ios_source_to_read_max_ms,
            extract_text_f64(line, "sourceToReadMaxMs"),
        );
        if extract_text_value(line, "sourceToReadClock").as_deref()
            == Some("remote-wall-clock-unsynced")
        {
            evidence.final_ios_source_to_read_unsynced_clock_samples += 1;
        }
    }

    if line.contains("Metal render telemetry") {
        evidence.final_metal_telemetry_samples += 1;
        evidence.final_metal_sample_ms += extract_text_u64(line, "sampleMs").unwrap_or(0);
        evidence.final_metal_draw_callbacks += extract_text_u64(line, "drawCallbacks").unwrap_or(0);
        evidence.final_metal_submitted += extract_text_u64(line, "submitted").unwrap_or(0);
        evidence.final_metal_displayed += extract_text_u64(line, "displayed").unwrap_or(0);
        evidence.final_metal_direct_bgra += extract_text_u64(line, "directBGRA").unwrap_or(0);
        evidence.final_metal_queue_drop_total += extract_text_u64(line, "queueDrop").unwrap_or(0);
        evidence.final_metal_queue_backpressure_total +=
            extract_text_u64(line, "queueBackpressure").unwrap_or(0);
        update_max_u64(
            &mut evidence.final_metal_queue_capacity_max,
            extract_text_u64(line, "queueCapacity"),
        );
        evidence.final_metal_coalesced_total +=
            extract_text_u64(line, "coalescedBeforeDraw").unwrap_or(0);
        evidence.final_metal_realtime_replacement_total +=
            extract_text_u64(line, "realtimeReplacementBeforeDraw").unwrap_or(0);
        if let Some(reason) = extract_text_value(line, "realtimeReplacementReason") {
            evidence.final_metal_realtime_replacement_reason_samples += 1;
            if reason != P2P_REMOTE_STRICT_METAL_REPLACEMENT_REASON {
                evidence.final_metal_realtime_replacement_bad_reason_total += 1;
            }
        }
        evidence.final_metal_manual_draw_total += extract_text_u64(line, "manualDraw").unwrap_or(0);
        evidence.final_metal_drawable_skip_total +=
            extract_text_u64(line, "drawableSkip").unwrap_or(0);
        evidence.final_metal_inflight_skip_total +=
            extract_text_u64(line, "inflightSkip").unwrap_or(0);
        evidence.final_metal_failure_skip_total +=
            extract_text_u64(line, "failureSkip").unwrap_or(0);
        evidence.final_metal_ci_fallback_total += extract_text_u64(line, "ciFallback").unwrap_or(0);
        update_max_u64(
            &mut evidence.final_metal_queue_depth_max,
            extract_text_u64(line, "queueDepthMax"),
        );
        update_max_f64(
            &mut evidence.final_metal_frame_age_max_ms,
            extract_text_f64(line, "frameAgeMs"),
        );
        if extract_text_f64(line, "frameAgeMs").is_some() {
            evidence.final_metal_frame_age_samples += 1;
        }
        if let (Some(draw_callbacks), Some(sample_ms)) = (
            extract_text_u64(line, "drawCallbacks"),
            extract_text_f64(line, "sampleMs"),
        ) && sample_ms > 0.0
        {
            let draw_callback_fps = draw_callbacks as f64 * 1000.0 / sample_ms;
            update_min_f64(
                &mut evidence.final_metal_draw_callback_fps_min,
                Some(draw_callback_fps),
            );
            update_max_f64(
                &mut evidence.final_metal_draw_callback_fps_max,
                Some(draw_callback_fps),
            );
        }
        update_min_f64(
            &mut evidence.final_metal_display_fps_min,
            extract_text_f64(line, "displayFPS"),
        );
        update_max_f64(
            &mut evidence.final_metal_display_fps_max,
            extract_text_f64(line, "displayFPS"),
        );
        update_max_f64(
            &mut evidence.final_metal_submitted_fps_max,
            extract_text_f64(line, "submittedFPS"),
        );
        update_min_u64(
            &mut evidence.final_metal_display_link_target_fps_min,
            extract_text_u64(line, "displayLinkTargetFPS"),
        );
        update_min_u64(
            &mut evidence.final_metal_display_link_pump_fps_min,
            extract_text_u64(line, "displayLinkPumpFPS"),
        );
        evidence.final_metal_strict_high_rate_cadence_seen |=
            extract_text_value(line, "displayLink").as_deref() == Some("mtkview-native")
                && extract_text_value(line, "displayCadence").as_deref()
                    == Some("strict-60-native-pump-catch-up-vsync");
        let submitted = extract_text_u64(line, "submitted").unwrap_or(0);
        let direct_bgra = extract_text_u64(line, "directBGRA").unwrap_or(0);
        if submitted > 0 && direct_bgra != submitted {
            evidence.final_metal_direct_bgra_mismatch = true;
        }
    }
}
