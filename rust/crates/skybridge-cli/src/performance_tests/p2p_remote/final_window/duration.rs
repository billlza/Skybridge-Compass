use super::*;

#[test]
fn p2p_remote_performance_rejects_short_final_pass_window() -> Result<()> {
    let evidence = P2pRemotePerformanceEvidence {
        pass_window_start_at: Some(OffsetDateTime::from_unix_timestamp(0)?),
        pass_window_end_at: Some(OffsetDateTime::from_unix_timestamp(3)?),
        pass_window_seconds: Some(3.0),
        pass_requested_seconds: Some(3.0),
        mac_final_window_sck_samples: 8,
        mac_final_window_sck_sample_ms: 8_000,
        mac_final_window_sck_encoded_frames: 480,
        mac_final_window_min_encoded_fps: Some(60.0),
        mac_final_window_tx_samples: 8,
        mac_final_window_tx_sample_ms: 8_000,
        mac_final_window_tx_sent_frames: 480,
        mac_final_window_min_sent_fps: Some(60.0),
        mac_final_window_sck_cadence_timer_fires_total: 960,
        mac_final_window_sck_cadence_submitted_frames_total: 480,
        mac_final_window_sck_cadence_catch_up_frames_total: 8,
        mac_final_window_sck_cadence_batch_max: Some(2),
        ..Default::default()
    };
    let check = check_p2p_remote_mac_final_window_fps(
        &evidence,
        59.0,
        P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS,
    );
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("observedWindowSeconds=Some(3.0)"));
    assert!(check.detail.contains("minPassWindowSeconds=10"));
    Ok(())
}
