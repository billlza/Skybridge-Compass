use super::*;

#[test]
fn p2p_remote_metal_render_queue_rejects_drop_depth_and_fallback_rendering() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    for _ in 0..P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES {
        update_p2p_remote_evidence(
            &mut evidence,
            "Metal render telemetry: sampleMs=1000 input=60 submitted=60 displayed=60 submittedFPS=60.0 displayFPS=60.0 frameAgeMs=28 displayLink=mtkview-native displayLinkTargetFPS=60 displayLinkPumpFPS=60 displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=0 renderPath=directBGRA directBGRA=60 ciFallback=0 drawCallbacks=60 queueCapacity=3 queueDepthMax=2 queueDrop=0 coalescedBeforeDraw=0 realtimeReplacementBeforeDraw=0 realtimeReplacementReason=none drawableSkip=0 inflightSkip=0 failureSkip=0",
            false,
            true,
        );
    }

    let check = check_p2p_remote_metal_render_queue(&evidence, 59.0);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("frameAgeSamples=8"));
    assert!(check.detail.contains("maxAllowedDrawCallbackFPS=63.0"));

    let mut legacy_displaylink = P2pRemotePerformanceEvidence::default();
    for _ in 0..P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES {
        update_p2p_remote_evidence(
            &mut legacy_displaylink,
            "Metal render telemetry: sampleMs=1000 input=60 submitted=60 displayed=60 submittedFPS=60.0 displayFPS=60.0 frameAgeMs=28 displayLink=cadisplaylink displayLinkTargetFPS=60 displayLinkPumpFPS=60 displayCadence=strict-60-cadisplaylink-pumped manualDraw=0 renderPath=directBGRA directBGRA=60 ciFallback=0 drawCallbacks=60 queueCapacity=3 queueDepthMax=2 queueDrop=0 coalescedBeforeDraw=0 realtimeReplacementBeforeDraw=0 realtimeReplacementReason=none drawableSkip=0 inflightSkip=0 failureSkip=0",
            false,
            true,
        );
    }
    let check = check_p2p_remote_metal_render_queue(&legacy_displaylink, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("strictHighRateCadence=false"));

    let mut low_input = P2pRemotePerformanceEvidence::default();
    for _ in 0..P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES {
        update_p2p_remote_evidence(
            &mut low_input,
            "Metal render telemetry: sampleMs=1000 input=30 submitted=60 displayed=60 submittedFPS=60.0 displayFPS=60.0 frameAgeMs=28 displayLink=mtkview-native displayLinkTargetFPS=60 displayLinkPumpFPS=60 displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=0 renderPath=directBGRA directBGRA=60 ciFallback=0 drawCallbacks=60 queueCapacity=3 queueDepthMax=2 queueDrop=0 coalescedBeforeDraw=0 realtimeReplacementBeforeDraw=0 realtimeReplacementReason=none drawableSkip=0 inflightSkip=0 failureSkip=0",
            false,
            true,
        );
    }
    let check = check_p2p_remote_metal_render_queue(&low_input, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("inputFPSGate=Some(30.0)"));

    let mut low_input_with_fast_renderer = P2pRemotePerformanceEvidence::default();
    for _ in 0..P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES {
        update_p2p_remote_evidence(
            &mut low_input_with_fast_renderer,
            "Metal render telemetry: sampleMs=1247 input=13 submitted=12 displayed=12 inputFPS=10.5 submittedFPS=9.8 displayFPS=9.8 renderMs=2.24 frameAgeMs=32 displayLink=mtkview-native displayLinkTargetFPS=60 displayLinkPumpFPS=60 screenMaxFPS=60 displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=0 frameDriven=mtkview-native-vsync renderPath=directBGRA directBGRA=12 ciFallback=0 drawCallbacks=12 queueCapacity=3 queueDepthMax=2 queueDrop=0 queueBackpressure=0 coalescedBeforeDraw=0 realtimeReplacementBeforeDraw=0 realtimeReplacementReason=none drawableSkip=0 inflightSkip=0 failureSkip=0",
            false,
            true,
        );
    }
    let check = check_p2p_remote_metal_render_queue(&low_input_with_fast_renderer, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(
        check.detail.contains("inputFPSGate=Some(10.425"),
        "{}",
        check.detail
    );
    assert!(
        check.detail.contains("displayFPSGate=Some(9.8"),
        "{}",
        check.detail
    );
    assert!(
        check.detail.contains("displayFPSMin=Some(9.8"),
        "{}",
        check.detail
    );

    update_p2p_remote_evidence(
        &mut evidence,
        "Metal render telemetry: sampleMs=1000 input=61 submitted=60 displayed=60 submittedFPS=60.0 displayFPS=58.0 frameAgeMs=213 displayLink=mtkview-native displayLinkTargetFPS=60 displayLinkPumpFPS=60 displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=3 renderPath=mixed directBGRA=59 ciFallback=1 drawCallbacks=46 queueCapacity=17 queueDepthMax=17 queueDrop=1 coalescedBeforeDraw=7 realtimeReplacementBeforeDraw=7 realtimeReplacementReason=none drawableSkip=0 inflightSkip=0 failureSkip=0",
        false,
        true,
    );
    let check = check_p2p_remote_metal_render_queue(&evidence, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("queueDrop=1"));
    assert!(check.detail.contains("queueCapacityMax=Some(17)"));
    assert!(check.detail.contains("queueDepthMax=Some(17)"));
    assert!(check.detail.contains("maxAllowedQueueDepth=3"));
    assert!(check.detail.contains("coalescedBeforeDraw=7"));
    assert!(check.detail.contains("manualDraw=3"));
    assert!(check.detail.contains("drawCallbackFPSMin=Some(46.0)"));
    assert!(check.detail.contains("frameAgeMaxMs=Some(213.0)"));
    assert!(check.detail.contains("displayFPSMin=Some(58.0)"));
    assert!(check.detail.contains("ciFallback=1"));
    assert!(check.detail.contains("directBGRAMismatch=true"));

    let mut missing_frame_age = P2pRemotePerformanceEvidence::default();
    for _ in 0..P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES {
        update_p2p_remote_evidence(
            &mut missing_frame_age,
            "Metal render telemetry: sampleMs=1000 input=60 submitted=60 displayed=60 submittedFPS=60.0 displayFPS=60.0 frameAgeMs=- displayLink=mtkview-native displayLinkTargetFPS=60 displayLinkPumpFPS=60 displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=0 renderPath=directBGRA directBGRA=60 ciFallback=0 drawCallbacks=60 queueCapacity=3 queueDepthMax=2 queueDrop=0 coalescedBeforeDraw=0 realtimeReplacementBeforeDraw=0 realtimeReplacementReason=none drawableSkip=0 inflightSkip=0 failureSkip=0",
            false,
            true,
        );
    }
    let check = check_p2p_remote_metal_render_queue(&missing_frame_age, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("frameAgeSamples=0"));

    let mut retry_backpressured = P2pRemotePerformanceEvidence::default();
    for _ in 0..P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES {
        update_p2p_remote_evidence(
            &mut retry_backpressured,
            "Metal render telemetry: sampleMs=1000 input=60 inputFPS=60.0 submitted=60 displayed=60 submittedFPS=60.0 displayFPS=60.0 frameAgeMs=28 displayLink=mtkview-native displayLinkTargetFPS=60 displayLinkPumpFPS=60 displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=0 renderPath=directBGRA directBGRA=60 ciFallback=0 drawCallbacks=60 queueCapacity=3 queueDepthMax=2 queueDrop=0 queueBackpressure=1 coalescedBeforeDraw=0 realtimeReplacementBeforeDraw=0 realtimeReplacementReason=none drawableSkip=0 inflightSkip=0 failureSkip=0",
            false,
            true,
        );
    }
    let check = check_p2p_remote_metal_render_queue(&retry_backpressured, 59.0);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("queueBackpressure=8"));
}

#[test]
fn p2p_remote_metal_render_queue_rejects_final_window_realtime_replacement() {
    let mut replaced = P2pRemotePerformanceEvidence::default();
    for _ in 0..P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES {
        update_p2p_remote_final_window_ios_evidence(
            &mut replaced,
            "Metal render telemetry: sampleMs=1000 input=63 submitted=60 displayed=60 submittedFPS=60.0 displayFPS=60.0 frameAgeMs=44 displayLink=mtkview-native displayLinkTargetFPS=60 displayLinkPumpFPS=60 displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=0 renderPath=directBGRA directBGRA=60 ciFallback=0 drawCallbacks=60 queueCapacity=3 queueDepthMax=3 queueDrop=0 coalescedBeforeDraw=3 realtimeReplacementBeforeDraw=3 realtimeReplacementReason=none drawableSkip=0 inflightSkip=0 failureSkip=0",
        );
    }
    let check = check_p2p_remote_metal_render_queue(&replaced, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("coalescedBeforeDraw=24"));
    assert!(check.detail.contains("maxAllowedCoalesced=0"));

    let mut excessive = P2pRemotePerformanceEvidence::default();
    for _ in 0..P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES {
        update_p2p_remote_final_window_ios_evidence(
            &mut excessive,
            "Metal render telemetry: sampleMs=1000 input=64 submitted=60 displayed=60 submittedFPS=60.0 displayFPS=60.0 frameAgeMs=44 displayLink=mtkview-native displayLinkTargetFPS=60 displayLinkPumpFPS=60 displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=0 renderPath=directBGRA directBGRA=60 ciFallback=0 drawCallbacks=60 queueCapacity=3 queueDepthMax=3 queueDrop=0 coalescedBeforeDraw=4 realtimeReplacementBeforeDraw=4 realtimeReplacementReason=none drawableSkip=0 inflightSkip=0 failureSkip=0",
        );
    }
    let check = check_p2p_remote_metal_render_queue(&excessive, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("coalescedBeforeDraw=32"));
    assert!(check.detail.contains("maxAllowedCoalesced=0"));

    let mut unstructured = P2pRemotePerformanceEvidence::default();
    for _ in 0..P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES {
        update_p2p_remote_final_window_ios_evidence(
            &mut unstructured,
            "Metal render telemetry: sampleMs=1000 input=61 submitted=60 displayed=60 submittedFPS=60.0 displayFPS=60.0 frameAgeMs=44 displayLink=mtkview-native displayLinkTargetFPS=60 displayLinkPumpFPS=60 displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=0 renderPath=directBGRA directBGRA=60 ciFallback=0 drawCallbacks=60 queueCapacity=3 queueDepthMax=3 queueDrop=0 coalescedBeforeDraw=1 realtimeReplacementBeforeDraw=0 drawableSkip=0 inflightSkip=0 failureSkip=0",
        );
    }
    let check = check_p2p_remote_metal_render_queue(&unstructured, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("replacementStructured=false"));
}

#[test]
fn p2p_remote_metal_render_queue_uses_final_window_aggregate_fps() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    for _ in 0..10 {
        update_p2p_remote_final_window_ios_evidence(
            &mut evidence,
            "Metal render telemetry: sampleMs=1000 input=62 submitted=62 displayed=62 submittedFPS=62.0 displayFPS=62.0 frameAgeMs=44 displayLink=mtkview-native displayLinkTargetFPS=60 displayLinkPumpFPS=60 displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=0 renderPath=directBGRA directBGRA=62 ciFallback=0 drawCallbacks=62 queueCapacity=3 queueDepthMax=3 queueDrop=0 queueBackpressure=0 coalescedBeforeDraw=0 realtimeReplacementBeforeDraw=0 realtimeReplacementReason=none drawableSkip=0 inflightSkip=0 failureSkip=0",
        );
    }
    update_p2p_remote_final_window_ios_evidence(
        &mut evidence,
        "Metal render telemetry: sampleMs=1000 input=30 submitted=30 displayed=30 submittedFPS=30.0 displayFPS=30.0 frameAgeMs=44 displayLink=mtkview-native displayLinkTargetFPS=60 displayLinkPumpFPS=60 displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=0 renderPath=directBGRA directBGRA=30 ciFallback=0 drawCallbacks=30 queueCapacity=3 queueDepthMax=3 queueDrop=0 queueBackpressure=0 coalescedBeforeDraw=0 realtimeReplacementBeforeDraw=0 realtimeReplacementReason=none drawableSkip=0 inflightSkip=0 failureSkip=0",
    );

    let check = check_p2p_remote_metal_render_queue(&evidence, 59.0);
    assert!(check.ok, "{}", check.detail);
    assert!(
        check
            .detail
            .contains("inputFPSGate=Some(59.09090909090909)")
    );
    assert!(check.detail.contains("inputFPSMin=Some(30.0)"));
    assert!(check.detail.contains("displayFPSMin=Some(30.0)"));

    let mut aggregate_low = P2pRemotePerformanceEvidence::default();
    for _ in 0..8 {
        update_p2p_remote_final_window_ios_evidence(
            &mut aggregate_low,
            "Metal render telemetry: sampleMs=1000 input=30 submitted=30 displayed=30 submittedFPS=30.0 displayFPS=30.0 frameAgeMs=44 displayLink=mtkview-native displayLinkTargetFPS=60 displayLinkPumpFPS=60 displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=0 renderPath=directBGRA directBGRA=30 ciFallback=0 drawCallbacks=30 queueCapacity=3 queueDepthMax=3 queueDrop=0 queueBackpressure=0 coalescedBeforeDraw=0 realtimeReplacementBeforeDraw=0 realtimeReplacementReason=none drawableSkip=0 inflightSkip=0 failureSkip=0",
        );
    }
    let check = check_p2p_remote_metal_render_queue(&aggregate_low, 59.0);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("inputFPSGate=Some(30.0)"));
    assert!(check.detail.contains("displayFPSGate=Some(30.0)"));
}
