use super::*;

const STRICT_IOS_RX_QUEUE_TAIL: &str = " parser=secure-off-main-actor parseQueueDelayMaxMs=1.0 parserActorHopMaxMs=1.0 parserStageMaxMs=1.0 applyQueueDelayMaxMs=1.0 screenApplyMaxMs=1.0 rxFrameClock=socket-arrival screenDeliveryAttempted=60 screenDeliveryBackpressure=0 decodeFeed=ordered-vt-decode-metal-direct socketMetricClock=local-socket-arrival socketToDecodeFeedSamples=60 socketToDecodeFeedMaxMs=2.0 socketToApplyEndSamples=60 socketToApplyEndMaxMs=3.0 decodeAttempted=60 decodeAccepted=60 decodeDropped=0 decodePendingMax=1 decodeInFlightMax=1 decodeWaitingSyncSamples=0 decodeResets=0";
const STRICT_IOS_RX_SBC2_TAIL: &str = " screenWire=sbc2-chunked-v1 sbc2Frames=60 sbc2Chunks=60";

fn strict_ios_rx_line(base: &str) -> String {
    let screen_fps_tail = if base.contains("screenFPS=") {
        ""
    } else {
        " screenFrames=60 screenFPS=60.0"
    };
    format!("{base}{screen_fps_tail}{STRICT_IOS_RX_QUEUE_TAIL}{STRICT_IOS_RX_SBC2_TAIL}")
}

fn strict_ios_rx_line_with_wire(base: &str, wire: &str) -> String {
    let screen_fps_tail = if base.contains("screenFPS=") {
        ""
    } else {
        " screenFrames=60 screenFPS=60.0"
    };
    format!("{base}{screen_fps_tail}{STRICT_IOS_RX_QUEUE_TAIL} {wire}")
}

#[test]
fn p2p_remote_raw_latency_rejects_batched_receive_drains() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        &strict_ios_rx_line(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=4 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&evidence, 59.0);
    assert!(check.ok, "{}", check.detail);

    let mut missing_screen_fps = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut missing_screen_fps,
        &format!(
            "{}{}{}",
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
            STRICT_IOS_RX_QUEUE_TAIL,
            STRICT_IOS_RX_SBC2_TAIL
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&missing_screen_fps, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("lanRxScreenFPS=missing"));

    let mut low_screen_fps = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut low_screen_fps,
        &strict_ios_rx_line(
            "ios-lan-remote-rx sampleMs=1000 screenFrames=10 screenFPS=10.0 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&low_screen_fps, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("lanRxScreenFPS=10.0"));

    let mut final_low_screen_fps = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_final_window_ios_evidence(
        &mut final_low_screen_fps,
        &strict_ios_rx_line(
            "ios-lan-remote-rx sampleMs=1000 screenFrames=10 screenFPS=10.0 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        ),
    );
    let check = check_p2p_remote_ios_raw_latency(&final_low_screen_fps, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("finalWindow=true"));
    assert!(check.detail.contains("lanRxScreenFPS=10.0"));

    let mut old_read_ahead = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut old_read_ahead,
        &strict_ios_rx_line(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=2 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-2frame-drain-budget rxFrameClock=socket-arrival",
        ),
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
        final_lan_rx_parser_samples: 2,
        final_lan_rx_strict_parser_samples: 2,
        final_lan_rx_screen_delivery_samples: 2,
        final_lan_rx_strict_screen_delivery_samples: 2,
        final_lan_rx_screen_delivery_attempted_total: 120,
        final_lan_rx_screen_delivery_delivered_total: 120,
        final_lan_rx_screen_delivery_backpressure_total: 0,
        final_lan_rx_screen_delivery_queue_depth_max: Some(1),
        final_lan_rx_screen_delivery_delay_max_ms: Some(16.0),
        final_raw_chunk_gap_ms: Some(18.0),
        final_lan_rx_main_hop_max_ms: Some(1.0),
        final_raw_chunk_main_hop_ms: Some(1.0),
        final_ios_complete_frames_per_drain_max: Some(4),
        final_ios_parser_drain_samples: 2,
        final_ios_parser_drain_max_ms: Some(1.0),
        final_ios_parser_budget_samples: 2,
        final_ios_parser_budget_max_ms: Some(6.0),
        final_ios_parse_queue_delay_max_ms: Some(1.0),
        final_ios_parser_actor_hop_max_ms: Some(1.0),
        final_ios_parser_stage_max_ms: Some(1.0),
        final_ios_apply_queue_delay_max_ms: Some(1.0),
        final_ios_screen_apply_max_ms: Some(1.0),
        final_lan_rx_screen_wire_samples: 2,
        final_lan_rx_strict_screen_wire_samples: 2,
        final_lan_rx_sbc2_frames: 120,
        final_lan_rx_sbc2_chunks: 120,
        final_lan_rx_sbc2_frame_samples: 2,
        final_lan_rx_sbc2_chunk_samples: 2,
        final_lan_rx_strict_sbc2_samples: 2,
        final_lan_rx_min_screen_fps: Some(60.0),
        ..Default::default()
    };
    let check = check_p2p_remote_ios_raw_latency(&partial_final_read_ahead, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("readAheadStrictSamples=1/1"));
    assert!(check.detail.contains("rxSamples=2"));

    update_p2p_remote_evidence(
        &mut evidence,
        &strict_ios_rx_line(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=181.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=12 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        ),
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
        &strict_ios_rx_line(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=121.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&raw_gap_only, 59.0);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("rawChunkGapMaxMs=121.0"));

    let mut over_bounded_queue_budget = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut over_bounded_queue_budget,
        &strict_ios_rx_line(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=220.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&over_bounded_queue_budget, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("rawChunkGapMaxMs=220.0"));

    let mut main_hop_budget = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut main_hop_budget,
        &strict_ios_rx_line(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=120.0 completeFramesPerDrainMax=1 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&main_hop_budget, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("maxMainHopMs=120.0"));

    let mut missing_screen_delivery = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut missing_screen_delivery,
        &strict_ios_rx_line(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        ),
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
        &strict_ios_rx_line(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-mainactor screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&old_screen_delivery, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("screenDeliveryStrictSamples=0/1"));

    let mut missing_rx_clock = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut missing_rx_clock,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parser=secure-off-main-actor parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 parseQueueDelayMaxMs=1.0 parserActorHopMaxMs=1.0 parserStageMaxMs=1.0 applyQueueDelayMaxMs=1.0 screenApplyMaxMs=1.0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryAttempted=60 screenDeliveryDelivered=60 screenDeliveryBackpressure=0 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 decodeFeed=ordered-vt-decode-metal-direct socketMetricClock=local-socket-arrival socketToDecodeFeedSamples=60 socketToDecodeFeedMaxMs=2.0 socketToApplyEndSamples=60 socketToApplyEndMaxMs=3.0 decodeAttempted=60 decodeAccepted=60 decodeDropped=0 decodePendingMax=1 decodeInFlightMax=1 decodeWaitingSyncSamples=0 decodeResets=0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget screenWire=sbc2-chunked-v1 sbc2Frames=60 sbc2Chunks=60",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&missing_rx_clock, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("rxFrameClockSamples=0/1"));

    let mut missing_socket_metrics = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut missing_socket_metrics,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parser=secure-off-main-actor parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 parseQueueDelayMaxMs=1.0 parserActorHopMaxMs=1.0 parserStageMaxMs=1.0 applyQueueDelayMaxMs=1.0 screenApplyMaxMs=1.0 rxFrameClock=socket-arrival screenDelivery=immediate-decode-metal-feed-direct screenDeliveryAttempted=60 screenDeliveryDelivered=60 screenDeliveryBackpressure=0 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 decodeFeed=ordered-vt-decode-metal-direct decodeAttempted=60 decodeAccepted=60 decodeDropped=0 decodePendingMax=1 decodeInFlightMax=1 decodeWaitingSyncSamples=0 decodeResets=0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget screenWire=sbc2-chunked-v1 sbc2Frames=60 sbc2Chunks=60",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&missing_socket_metrics, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("socketMetricClockSamples=0/1"));

    let mut slow_socket_to_decode_feed = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut slow_socket_to_decode_feed,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parser=secure-off-main-actor parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 parseQueueDelayMaxMs=1.0 parserActorHopMaxMs=1.0 parserStageMaxMs=1.0 applyQueueDelayMaxMs=1.0 screenApplyMaxMs=1.0 rxFrameClock=socket-arrival socketMetricClock=local-socket-arrival screenDelivery=immediate-decode-metal-feed-direct screenDeliveryAttempted=60 screenDeliveryDelivered=60 screenDeliveryBackpressure=0 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 decodeFeed=ordered-vt-decode-metal-direct socketToDecodeFeedSamples=60 socketToDecodeFeedMaxMs=120.0 socketToApplyEndSamples=60 socketToApplyEndMaxMs=3.0 decodeAttempted=60 decodeAccepted=60 decodeDropped=0 decodePendingMax=1 decodeInFlightMax=1 decodeWaitingSyncSamples=0 decodeResets=0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget screenWire=sbc2-chunked-v1 sbc2Frames=60 sbc2Chunks=60",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&slow_socket_to_decode_feed, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("socketToDecodeFeedMaxMs=120.0"));

    let mut old_parser_mode = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut old_parser_mode,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parser=bootstrap-mainactor parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 parseQueueDelayMaxMs=1.0 parserActorHopMaxMs=1.0 parserStageMaxMs=1.0 applyQueueDelayMaxMs=1.0 screenApplyMaxMs=1.0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryAttempted=60 screenDeliveryDelivered=60 screenDeliveryBackpressure=0 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&old_parser_mode, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("parserStrictSamples=0/1"));
    assert!(
        check
            .detail
            .contains("expectedParser=secure-off-main-actor")
    );

    let mut delivery_backlog = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut delivery_backlog,
        &strict_ios_rx_line(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=13 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&delivery_backlog, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("screenDeliveryQueueDepthMax=13"));

    let mut delivery_mismatch = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut delivery_mismatch,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parser=secure-off-main-actor parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 parseQueueDelayMaxMs=1.0 parserActorHopMaxMs=1.0 parserStageMaxMs=1.0 applyQueueDelayMaxMs=1.0 screenApplyMaxMs=1.0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryAttempted=60 screenDeliveryDelivered=59 screenDeliveryBackpressure=0 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&delivery_mismatch, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("screenDeliveryAttempted=60"));
    assert!(check.detail.contains("screenDeliveryDelivered=59"));

    let mut delivery_backpressure = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut delivery_backpressure,
        &format!(
            "ios-lan-remote-rx sampleMs=1000 screenFrames=60 screenFPS=60.0 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parser=secure-off-main-actor parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 parseQueueDelayMaxMs=1.0 parserActorHopMaxMs=1.0 parserStageMaxMs=1.0 applyQueueDelayMaxMs=1.0 screenApplyMaxMs=1.0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryAttempted=60 screenDeliveryDelivered=60 screenDeliveryBackpressure=1 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 decodeFeed=ordered-vt-decode-metal-direct socketMetricClock=local-socket-arrival socketToDecodeFeedSamples=60 socketToDecodeFeedMaxMs=2.0 socketToApplyEndSamples=60 socketToApplyEndMaxMs=3.0 decodeAttempted=60 decodeAccepted=60 decodeDropped=0 decodePendingMax=1 decodeInFlightMax=1 decodeWaitingSyncSamples=0 decodeResets=0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget{STRICT_IOS_RX_SBC2_TAIL} rxFrameClock=socket-arrival"
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&delivery_backpressure, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("screenDeliveryBackpressure=1"));

    let mut final_delivery_backpressure = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_final_window_ios_evidence(
        &mut final_delivery_backpressure,
        &format!(
            "ios-lan-remote-rx sampleMs=1000 screenFrames=60 screenFPS=60.0 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parser=secure-off-main-actor parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 parseQueueDelayMaxMs=1.0 parserActorHopMaxMs=1.0 parserStageMaxMs=1.0 applyQueueDelayMaxMs=1.0 screenApplyMaxMs=1.0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryAttempted=60 screenDeliveryDelivered=60 screenDeliveryBackpressure=1 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 decodeFeed=ordered-vt-decode-metal-direct socketMetricClock=local-socket-arrival socketToDecodeFeedSamples=60 socketToDecodeFeedMaxMs=2.0 socketToApplyEndSamples=60 socketToApplyEndMaxMs=3.0 decodeAttempted=60 decodeAccepted=60 decodeDropped=0 decodePendingMax=1 decodeInFlightMax=1 decodeWaitingSyncSamples=0 decodeResets=0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget{STRICT_IOS_RX_SBC2_TAIL} rxFrameClock=socket-arrival"
        ),
    );
    let check = check_p2p_remote_ios_raw_latency(&final_delivery_backpressure, 59.0);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("finalWindow=true"));
    assert!(check.detail.contains("screenDeliveryBackpressure=1"));

    let mut missing_screen_wire = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut missing_screen_wire,
        &strict_ios_rx_line_with_wire(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
            "sbc2Frames=60 sbc2Chunks=60",
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&missing_screen_wire, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("screenWireStrictSamples=0/0"));
    assert!(check.detail.contains("sbc2StrictSamples=1/1"));

    let mut legacy_screen_wire = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut legacy_screen_wire,
        &strict_ios_rx_line_with_wire(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
            "screenWire=length-framed sbc2Frames=0 sbc2Chunks=0",
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&legacy_screen_wire, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("screenWireStrictSamples=0/1"));
    assert!(check.detail.contains("sbc2StrictSamples=0/1"));
    assert!(check.detail.contains("expectedScreenWire=sbc2-chunked-v1"));
    assert!(check.detail.contains("sbc2Frames=0"));
    assert!(check.detail.contains("sbc2Chunks=0"));

    let mut incomplete_sbc2_chunks = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut incomplete_sbc2_chunks,
        &strict_ios_rx_line_with_wire(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
            "screenWire=sbc2-chunked-v1 sbc2Frames=60 sbc2Chunks=59",
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&incomplete_sbc2_chunks, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("screenWireStrictSamples=1/1"));
    assert!(check.detail.contains("sbc2StrictSamples=0/1"));
    assert!(check.detail.contains("sbc2FrameSamples=1"));
    assert!(check.detail.contains("sbc2ChunkSamples=1"));
    assert!(check.detail.contains("sbc2Frames=60"));
    assert!(check.detail.contains("sbc2Chunks=59"));

    let mut decode_drop = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut decode_drop,
        &format!(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parser=secure-off-main-actor parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 parseQueueDelayMaxMs=1.0 parserActorHopMaxMs=1.0 parserStageMaxMs=1.0 applyQueueDelayMaxMs=1.0 screenApplyMaxMs=1.0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryAttempted=60 screenDeliveryDelivered=60 screenDeliveryBackpressure=0 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 decodeFeed=ordered-vt-decode-metal-direct socketMetricClock=local-socket-arrival socketToDecodeFeedSamples=60 socketToDecodeFeedMaxMs=2.0 socketToApplyEndSamples=60 socketToApplyEndMaxMs=3.0 decodeAttempted=60 decodeAccepted=59 decodeDropped=1 decodePendingMax=1 decodeInFlightMax=1 decodeWaitingSyncSamples=0 decodeResets=0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget{STRICT_IOS_RX_SBC2_TAIL} rxFrameClock=socket-arrival"
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&decode_drop, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("decodeAttempted=60"));
    assert!(check.detail.contains("decodeAccepted=59"));
    assert!(check.detail.contains("decodeDropped=1"));

    let mut parser_budget = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut parser_budget,
        &strict_ios_rx_line(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parserDrainMaxMs=8.0 parserBudgetMs=6.0 parserBudgetHits=1 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&parser_budget, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("parserDrainMaxMs=8.0"));
    assert!(check.detail.contains("parserBudgetHits=1"));

    let mut slow_parser_event = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut slow_parser_event,
        &strict_ios_rx_line(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        ),
        false,
        true,
    );
    update_p2p_remote_evidence(
        &mut slow_parser_event,
        "ios-lan-parser-slow session=lan transport=lan drainMs=9458.47 budgetMs=6.0 budgetHit=1 pending=1 payloads=1 completeFrames=0 sbc2Chunks=1 sbc2Frames=0 rawChunkBytes=262144 receiveBufferBytesAfterDrain=1048576 rawChunkMainHopMs=1.0 parseQueueDelayMs=1.0 parserActorHopMs=1.0 applyQueueDelayMs=1.0 parserStageMax=length-frame-pop parserStageMaxMs=9458.0 parserStagePayloadBytes=262140 parserStageBufferBytes=2097152",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&slow_parser_event, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("parserSlowEvents=1"));
    assert!(check.detail.contains("parserSlowDrainMaxMs=9458.5"));
    assert!(check.detail.contains("parserSlowStageMaxMs=9458.0"));

    let mut parse_queue_delay = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut parse_queue_delay,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parser=secure-off-main-actor parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 parseQueueDelayMaxMs=120.0 parserActorHopMaxMs=1.0 parserStageMaxMs=1.0 applyQueueDelayMaxMs=1.0 screenApplyMaxMs=1.0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryAttempted=60 screenDeliveryDelivered=60 screenDeliveryBackpressure=0 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&parse_queue_delay, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("parseQueueDelayMaxMs=120.0"));
    assert!(check.detail.contains("queueHopLimitMs=100.0"));

    let mut parser_actor_hop = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut parser_actor_hop,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parser=secure-off-main-actor parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 parseQueueDelayMaxMs=1.0 parserActorHopMaxMs=120.0 parserStageMaxMs=1.0 applyQueueDelayMaxMs=1.0 screenApplyMaxMs=1.0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryAttempted=60 screenDeliveryDelivered=60 screenDeliveryBackpressure=0 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&parser_actor_hop, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("parserActorHopMaxMs=120.0"));

    let mut parser_stage = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut parser_stage,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parser=secure-off-main-actor parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 parseQueueDelayMaxMs=1.0 parserActorHopMaxMs=1.0 parserStageMaxMs=8.0 applyQueueDelayMaxMs=1.0 screenApplyMaxMs=1.0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryAttempted=60 screenDeliveryDelivered=60 screenDeliveryBackpressure=0 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&parser_stage, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("parserStageMaxMs=8.0"));
    assert!(check.detail.contains("parserStageBudgetMs=6.0"));

    let mut apply_queue_delay = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut apply_queue_delay,
        "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parser=secure-off-main-actor parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 parseQueueDelayMaxMs=1.0 parserActorHopMaxMs=1.0 parserStageMaxMs=1.0 applyQueueDelayMaxMs=120.0 screenApplyMaxMs=120.0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryAttempted=60 screenDeliveryDelivered=60 screenDeliveryBackpressure=0 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=16.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&apply_queue_delay, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("applyQueueDelayMaxMs=120.0"));
    assert!(check.detail.contains("screenApplyMaxMs=120.0"));

    let mut delivery_delay = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut delivery_delay,
        &strict_ios_rx_line(
            "ios-lan-remote-rx sampleMs=1000 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 maxMainHopMs=1.0 completeFramesPerDrainMax=1 parserDrainMaxMs=1.0 parserBudgetMs=6.0 parserBudgetHits=0 screenDelivery=immediate-decode-metal-feed-direct screenDeliveryDelivered=60 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=101.0 readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival",
        ),
        false,
        true,
    );
    let check = check_p2p_remote_ios_raw_latency(&delivery_delay, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("screenDeliveryDelayMaxMs=101.0"));
}
