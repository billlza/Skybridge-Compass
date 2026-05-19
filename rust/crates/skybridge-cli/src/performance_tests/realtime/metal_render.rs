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
