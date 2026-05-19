use crate::performance_budgets::{
    P2P_REMOTE_STRICT_IOS_READ_AHEAD_MODE, P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_MODE,
};
use crate::performance_evidence::{
    extract_text_f64, extract_text_u64, extract_text_value, update_max_f64, update_max_u64,
    update_min_f64,
};

use super::P2pRemotePerformanceEvidence;

pub(super) fn update_p2p_remote_ios_lan_rx_evidence(
    evidence: &mut P2pRemotePerformanceEvidence,
    line: &str,
    is_ios: bool,
) {
    if is_ios && line.contains("ios-lan-remote-rx") {
        evidence.ios_lan_rx_samples += 1;
        evidence.ios_lan_rx_sample_ms += extract_text_u64(line, "sampleMs").unwrap_or(0);
        if extract_text_value(line, "readAhead").as_deref()
            == Some(P2P_REMOTE_STRICT_IOS_READ_AHEAD_MODE)
        {
            evidence.ios_lan_rx_strict_read_ahead_samples += 1;
        }
        if extract_text_value(line, "screenDelivery").is_some() {
            evidence.ios_lan_rx_screen_delivery_samples += 1;
        }
        if extract_text_value(line, "screenDelivery").as_deref()
            == Some(P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_MODE)
        {
            evidence.ios_lan_rx_strict_screen_delivery_samples += 1;
        }
        evidence.ios_lan_rx_screen_delivery_delivered_total +=
            extract_text_u64(line, "screenDeliveryDelivered").unwrap_or(0);
        update_max_u64(
            &mut evidence.ios_lan_rx_screen_delivery_queue_depth_max,
            extract_text_u64(line, "screenDeliveryQueueDepthMax"),
        );
        update_max_f64(
            &mut evidence.ios_lan_rx_screen_delivery_delay_max_ms,
            extract_text_f64(line, "screenDeliveryDelayMaxMs"),
        );
        update_min_f64(
            &mut evidence.min_ios_screen_fps,
            extract_text_f64(line, "screenFPS"),
        );
        update_max_f64(
            &mut evidence.max_raw_chunk_gap_ms,
            extract_text_f64(line, "rawChunkGapMaxMs"),
        );
        update_max_f64(
            &mut evidence.max_raw_chunk_main_hop_ms,
            extract_text_f64(line, "rawChunkMainHopMaxMs"),
        );
        update_max_u64(
            &mut evidence.ios_complete_frames_per_drain_max,
            extract_text_u64(line, "completeFramesPerDrainMax"),
        );
        evidence.ios_source_samples += extract_text_u64(line, "sourceSamples").unwrap_or(0);
        update_max_f64(
            &mut evidence.ios_source_gap_max_ms,
            extract_text_f64(line, "sourceGapMaxMs"),
        );
        update_max_f64(
            &mut evidence.ios_source_to_read_max_ms,
            extract_text_f64(line, "sourceToReadMaxMs"),
        );
        if extract_text_value(line, "sourceToReadClock").as_deref()
            == Some("remote-wall-clock-unsynced")
        {
            evidence.ios_source_to_read_unsynced_clock_samples += 1;
        }
    }
}
