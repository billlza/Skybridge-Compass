use super::*;

#[test]
fn p2p_remote_raw_latency_rejects_batched_receive_drains() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 completeFramesPerDrainMax=4 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-8k-4frame-drain-budget",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&evidence, 59.0);
    assert!(check.ok, "{}", check.detail);

    let mut old_read_ahead = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut old_read_ahead,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 completeFramesPerDrainMax=2 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-8k-2frame-drain-budget",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&old_read_ahead, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("readAheadStrictSamples=0/1"));

    let partial_final_read_ahead = P2pRemotePerformanceEvidence {
        final_lan_rx_samples: 2,
        final_lan_rx_sample_ms: 2000,
        final_lan_rx_read_ahead_samples: 1,
        final_lan_rx_strict_read_ahead_samples: 1,
        final_lan_rx_screen_delivery_samples: 2,
        final_lan_rx_strict_screen_delivery_samples: 2,
        final_lan_rx_screen_delivery_delivered_total: 120,
        final_lan_rx_screen_delivery_queue_depth_max: Some(1),
        final_lan_rx_screen_delivery_delay_max_ms: Some(16.0),
        final_raw_chunk_gap_ms: Some(18.0),
        final_raw_chunk_main_hop_ms: Some(1.0),
        final_ios_complete_frames_per_drain_max: Some(4),
        ..Default::default()
    };
    let check = check_p2p_remote_ios_raw_latency(&partial_final_read_ahead, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("readAheadStrictSamples=1/1"));
    assert!(check.detail.contains("rxSamples=2"));

    update_p2p_remote_evidence(
        &mut evidence,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=181.0 rawChunkMainHopMaxMs=1.0 completeFramesPerDrainMax=12 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-8k-4frame-drain-budget",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&evidence, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("rawChunkGapMaxMs=181.0"));
    assert!(check.detail.contains("maxAllowedRawGapMs=203.4"));
    assert!(check.detail.contains("completeFramesPerDrainMax=12"));

    let mut raw_gap_only = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut raw_gap_only,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=121.0 rawChunkMainHopMaxMs=1.0 completeFramesPerDrainMax=1 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-8k-4frame-drain-budget",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&raw_gap_only, 59.0);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("rawChunkGapMaxMs=121.0"));

    let mut over_bounded_queue_budget = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut over_bounded_queue_budget,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=220.0 rawChunkMainHopMaxMs=1.0 completeFramesPerDrainMax=1 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-8k-4frame-drain-budget",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&over_bounded_queue_budget, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("rawChunkGapMaxMs=220.0"));

    let mut missing_screen_delivery = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut missing_screen_delivery,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 completeFramesPerDrainMax=1 readAhead=stream-parser-low-latency-8k-4frame-drain-budget",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&missing_screen_delivery, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("screenDeliveryStrictSamples=0/0"));
    assert!(
        check
            .detail
            .contains("expectedScreenDelivery=immediate-decode-metal-feed-direct")
    );

    let mut old_screen_delivery = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut old_screen_delivery,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 completeFramesPerDrainMax=1 screenDelivery=immediate-mainactor screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-8k-4frame-drain-budget",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&old_screen_delivery, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("screenDeliveryStrictSamples=0/1"));

    let mut delivery_backlog = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut delivery_backlog,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 completeFramesPerDrainMax=1 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=13 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-8k-4frame-drain-budget",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&delivery_backlog, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("screenDeliveryQueueDepthMax=13"));

    let mut delivery_delay = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut delivery_delay,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 completeFramesPerDrainMax=1 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=101.0 readAhead=stream-parser-low-latency-8k-4frame-drain-budget",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&delivery_delay, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("screenDeliveryDelayMaxMs=101.0"));
}
