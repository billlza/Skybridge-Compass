use crate::performance_evidence::{
    extract_text_i64, extract_text_u64, extract_text_value, update_max_i64, update_max_u64,
};

use super::P2pRemotePerformanceEvidence;

pub(super) fn update_mac_sck_encoder_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
) {
    if let Some(catch_up_limit) = extract_text_u64(line, "cadenceCatchUpLimit") {
        evidence.sck_cadence_catch_up_limit_samples += 1;
        update_max_u64(
            &mut evidence.sck_cadence_catch_up_limit_max,
            Some(catch_up_limit),
        );
    }
    if let Some(max_frame_delay_count) = extract_text_u64(line, "maxFrameDelayCount") {
        evidence.sck_max_frame_delay_count_samples += 1;
        update_max_u64(
            &mut evidence.sck_max_frame_delay_count_max,
            Some(max_frame_delay_count),
        );
    }
    update_max_u64(
        &mut evidence.sck_maximum_real_time_frame_rate_max,
        extract_text_u64(line, "maximumRealTimeFrameRate"),
    );
    update_max_u64(
        &mut evidence.sck_single_chunk_budget_bytes_max,
        extract_text_u64(line, "singleChunkHEVCBudgetBytes"),
    );
    if let Some(low_latency_rate_control) = extract_text_value(line, "lowLatencyRateControl") {
        evidence.sck_low_latency_rate_control_samples += 1;
        if low_latency_rate_control == "true" {
            evidence.sck_low_latency_rate_control_enabled_samples += 1;
        }
    }
    if let Some(burst_limit_bytes) = extract_text_u64(line, "dataRateBurstLimitBytes") {
        if burst_limit_bytes > 0 {
            evidence.sck_data_rate_burst_samples += 1;
        }
        update_max_u64(
            &mut evidence.sck_data_rate_burst_limit_bytes_max,
            Some(burst_limit_bytes),
        );
    }
    update_max_u64(
        &mut evidence.sck_data_rate_limit_bytes_per_second_max,
        extract_text_u64(line, "dataRateLimitBytesPerSecond"),
    );
    update_max_u64(
        &mut evidence.sck_data_rate_burst_window_ms_max,
        extract_text_u64(line, "dataRateBurstWindowMs"),
    );
    update_max_i64(
        &mut evidence.sck_data_rate_limits_status_max,
        extract_text_i64(line, "dataRateLimitsStatus"),
    );
    update_max_i64(
        &mut evidence.sck_data_rate_limits_readback_status_max,
        extract_text_i64(line, "dataRateLimitsReadbackStatus"),
    );
    if extract_text_u64(line, "dataRateLimitsApplied") == Some(1) {
        evidence.sck_data_rate_limits_applied_samples += 1;
    }
    update_max_u64(
        &mut evidence.sck_data_rate_readback_burst_limit_bytes_max,
        extract_text_u64(line, "dataRateReadbackBurstLimitBytes"),
    );
    update_max_u64(
        &mut evidence.sck_data_rate_readback_burst_window_ms_max,
        extract_text_u64(line, "dataRateReadbackBurstWindowMs"),
    );
}
