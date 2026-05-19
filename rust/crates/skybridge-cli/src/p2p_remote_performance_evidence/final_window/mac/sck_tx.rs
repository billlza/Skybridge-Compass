use crate::performance_evidence::{
    extract_text_f64, extract_text_u64, update_max_f64, update_max_u64, update_min_f64,
};

use super::super::super::P2pRemotePerformanceEvidence;

pub(super) fn update_final_window_mac_sck_tx_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
) {
    evidence.mac_final_window_sck_samples += 1;
    evidence.mac_final_window_sck_sample_ms += extract_text_u64(line, "sampleMs").unwrap_or(0);
    evidence.mac_final_window_sck_captured_frames +=
        extract_text_u64(line, "captured").unwrap_or(0);
    evidence.mac_final_window_sck_meaningful_frames +=
        extract_text_u64(line, "meaningful").unwrap_or(0);
    evidence.mac_final_window_sck_encoded_frames += extract_text_u64(line, "encoded").unwrap_or(0);
    update_min_f64(
        &mut evidence.mac_final_window_min_capture_fps,
        extract_text_f64(line, "captureFPS"),
    );
    update_min_f64(
        &mut evidence.mac_final_window_min_meaningful_fps,
        extract_text_f64(line, "meaningfulFPS"),
    );
    if let Some(fps) = extract_text_f64(line, "encodedFPS") {
        evidence.mac_final_window_latest_encoded_fps = Some(fps);
    }
    update_min_f64(
        &mut evidence.mac_final_window_min_encoded_fps,
        extract_text_f64(line, "encodedFPS"),
    );
    update_max_f64(
        &mut evidence.mac_final_window_sck_source_frame_age_max_ms,
        extract_text_f64(line, "sourceFrameAgeMaxMs"),
    );
    update_max_u64(
        &mut evidence.mac_final_window_sck_source_frame_repeat_max,
        extract_text_u64(line, "sourceFrameRepeatMax"),
    );
    evidence.mac_final_window_sck_cadence_timer_fires_total +=
        extract_text_u64(line, "cadenceTimerFires").unwrap_or(0);
    evidence.mac_final_window_sck_cadence_submitted_frames_total +=
        extract_text_u64(line, "cadenceSubmitted").unwrap_or(0);
    evidence.mac_final_window_sck_cadence_catch_up_frames_total +=
        extract_text_u64(line, "cadenceCatchUpFrames").unwrap_or(0);
    update_max_u64(
        &mut evidence.mac_final_window_sck_cadence_batch_max,
        extract_text_u64(line, "cadenceBatchMax"),
    );
}
