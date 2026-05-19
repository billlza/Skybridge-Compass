use crate::performance_evidence::{
    extract_text_f64, extract_text_u64, update_max_f64, update_max_u64, update_min_f64,
};

use super::P2pRemotePerformanceEvidence;

pub(super) fn update_mac_sck_tx_evidence(evidence: &mut P2pRemotePerformanceEvidence, line: &str) {
    evidence.sck_captured_frames_total += extract_text_u64(line, "captured").unwrap_or(0);
    evidence.sck_meaningful_frames_total += extract_text_u64(line, "meaningful").unwrap_or(0);
    update_min_f64(
        &mut evidence.sck_capture_fps_min,
        extract_text_f64(line, "captureFPS"),
    );
    update_min_f64(
        &mut evidence.sck_meaningful_fps_min,
        extract_text_f64(line, "meaningfulFPS"),
    );
    update_max_f64(
        &mut evidence.sck_source_frame_age_max_ms,
        extract_text_f64(line, "sourceFrameAgeMaxMs"),
    );
    update_max_u64(
        &mut evidence.sck_source_frame_repeat_max,
        extract_text_u64(line, "sourceFrameRepeatMax"),
    );
    if let Some(fps) = extract_text_f64(line, "encodedFPS") {
        evidence.mac_latest_encoded_fps = Some(fps);
    }
    update_min_f64(
        &mut evidence.mac_min_encoded_fps,
        extract_text_f64(line, "encodedFPS"),
    );
    evidence.sck_cadence_timer_fires_total +=
        extract_text_u64(line, "cadenceTimerFires").unwrap_or(0);
    evidence.sck_cadence_submitted_frames_total +=
        extract_text_u64(line, "cadenceSubmitted").unwrap_or(0);
    evidence.sck_cadence_catch_up_frames_total +=
        extract_text_u64(line, "cadenceCatchUpFrames").unwrap_or(0);
    update_max_u64(
        &mut evidence.sck_cadence_batch_max,
        extract_text_u64(line, "cadenceBatchMax"),
    );
    if line.contains("codec=hevc") && line.contains("capturesAudio=false") {
        evidence.sck_encode_failures_total += extract_text_u64(line, "encodeFailures").unwrap_or(0);
        evidence.sck_oversized_encoded_frames_total +=
            extract_text_u64(line, "oversizedEncodedFrames").unwrap_or(0);
        evidence.sck_oversized_sync_frames_total +=
            extract_text_u64(line, "oversizedSyncFrames").unwrap_or(0);
        update_max_u64(
            &mut evidence.sck_encoded_frame_bytes_max,
            extract_text_u64(line, "encodedFrameBytesMax"),
        );
        update_max_u64(
            &mut evidence.sck_encoded_sync_frame_bytes_max,
            extract_text_u64(line, "encodedSyncFrameBytesMax"),
        );
        update_max_u64(
            &mut evidence.sck_single_chunk_budget_bytes_max,
            extract_text_u64(line, "singleChunkHEVCBudgetBytes"),
        );
    }
}
