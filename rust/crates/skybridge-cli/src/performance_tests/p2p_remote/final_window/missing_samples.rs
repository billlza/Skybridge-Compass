use super::*;

#[test]
fn p2p_remote_performance_rejects_missing_final_window_lan_rx() -> Result<()> {
    let evidence = P2pRemotePerformanceEvidence {
        pass_window_start_at: Some(OffsetDateTime::from_unix_timestamp(0)?),
        pass_window_end_at: Some(OffsetDateTime::from_unix_timestamp(10)?),
        pass_window_seconds: Some(10.0),
        ios_lan_rx_samples: 1,
        ios_lan_rx_sample_ms: 1_000,
        ios_lan_rx_strict_read_ahead_samples: 1,
        ios_lan_rx_screen_delivery_samples: 1,
        ios_lan_rx_strict_screen_delivery_samples: 1,
        ios_lan_rx_screen_delivery_delivered_total: 60,
        ios_lan_rx_screen_delivery_queue_depth_max: Some(1),
        ios_lan_rx_screen_delivery_delay_max_ms: Some(10.0),
        max_raw_chunk_gap_ms: Some(5.0),
        max_raw_chunk_main_hop_ms: Some(1.0),
        ios_complete_frames_per_drain_max: Some(1),
        ..Default::default()
    };

    let check = check_p2p_remote_ios_raw_latency(&evidence, 59.0);

    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("finalWindow=true"));
    assert!(check.detail.contains("rxSamples=0"));
    Ok(())
}

#[test]
fn p2p_remote_performance_rejects_missing_final_window_metal_telemetry() -> Result<()> {
    let evidence = P2pRemotePerformanceEvidence {
        pass_window_start_at: Some(OffsetDateTime::from_unix_timestamp(0)?),
        pass_window_end_at: Some(OffsetDateTime::from_unix_timestamp(10)?),
        pass_window_seconds: Some(10.0),
        metal_telemetry_samples: 8,
        metal_queue_capacity_max: Some(6),
        metal_queue_depth_max: Some(1),
        metal_frame_age_samples: 8,
        metal_frame_age_max_ms: Some(10.0),
        metal_draw_callback_fps_min: Some(120.0),
        metal_draw_callback_fps_max: Some(120.0),
        metal_display_fps_min: Some(60.0),
        metal_display_fps_max: Some(60.0),
        metal_submitted_fps_max: Some(60.0),
        metal_display_link_target_fps_min: Some(60),
        metal_display_link_pump_fps_min: Some(120),
        metal_strict_high_rate_cadence_seen: true,
        ..Default::default()
    };

    let check = check_p2p_remote_metal_render_queue(&evidence, 59.0);

    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("finalWindow=true"));
    assert!(check.detail.contains("telemetrySamples=0"));
    Ok(())
}
