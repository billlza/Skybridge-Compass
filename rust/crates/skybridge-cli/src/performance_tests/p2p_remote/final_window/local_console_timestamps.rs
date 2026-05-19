use super::*;

#[test]
fn p2p_remote_local_console_timestamp_uses_pass_window_anchor() -> Result<()> {
    let anchor = OffsetDateTime::parse(
        "2026-05-15T22:23:25Z",
        &time::format_description::well_known::Rfc3339,
    )?;
    let offset = UtcOffset::from_hms(8, 0, 0)?;

    let parsed = parse_webrtc_local_console_timestamp_with_offset(
        "[06:23:25.697] Metal render telemetry: sampleMs=1000",
        anchor,
        offset,
    )
    .expect("local console timestamp should parse");

    assert_eq!(
        parsed,
        OffsetDateTime::parse(
            "2026-05-15T22:23:25.697Z",
            &time::format_description::well_known::Rfc3339,
        )?
    );
    Ok(())
}

#[test]
fn p2p_remote_final_window_accepts_ios_local_console_timestamps() -> Result<()> {
    let artifact_dir = make_test_dir("p2p-remote-local-console-window")?;
    let start = OffsetDateTime::parse(
        "2026-05-15T22:23:15Z",
        &time::format_description::well_known::Rfc3339,
    )?;
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let local_stamp = |timestamp: OffsetDateTime| {
        let time = timestamp.to_offset(local_offset).time();
        format!(
            "[{:02}:{:02}:{:02}.000]",
            time.hour(),
            time.minute(),
            time.second()
        )
    };

    let mut ios_log = format!(
        "{} Metal render telemetry: sampleMs=1000 input=1 submitted=1 displayed=1 submittedFPS=1.0 displayFPS=1.0 frameAgeMs=500 displayLink=mtkview-native displayLinkTargetFPS=60 displayLinkPumpFPS=60 displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=0 renderPath=directBGRA directBGRA=1 ciFallback=0 drawCallbacks=1 queueCapacity=3 queueDepthMax=3 queueDrop=1 queueBackpressure=0 coalescedBeforeDraw=0 realtimeReplacementBeforeDraw=0 realtimeReplacementReason=none drawableSkip=0 inflightSkip=0 failureSkip=0\n",
        local_stamp(start)
    );
    ios_log.push_str("[2026-05-15T22:23:15Z] remote-desktop pass-window-start windowSeconds=10 windowFPS=60.0 windowRxFps=60.0 frame=2056x1329\n");
    for second in 1..=P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES {
        let stamp = local_stamp(start + time::Duration::seconds(second as i64));
        ios_log.push_str(&format!(
            "{stamp} ios-lan-remote-rx sampleMs=1000 screenFrames=60 screenFPS=60.0 maxGapMs=16.7 sourceSamples=60 sourceGapMaxMs=16.7 sourceToReadMaxMs=20.0 rawChunks=60 rawChunkGapMaxMs=18.0 rawChunkMainHopMaxMs=1.0 completeFramesPerDrainMax=1 screenWire=sbc2-chunked-v1 readAhead={P2P_REMOTE_STRICT_IOS_READ_AHEAD_MODE} screenDelivery={P2P_REMOTE_STRICT_IOS_SCREEN_DELIVERY_MODE} screenDeliveryAttempted=60 screenDeliveryDelivered=60 screenDeliveryBackpressure=0 screenDeliveryQueueDepthMax=1 screenDeliveryDelayMaxMs=10.0 sbc2Frames=60 sbc2Chunks=60\n"
        ));
        ios_log.push_str(&format!(
            "{stamp} Metal render telemetry: sampleMs=1000 input=60 submitted=60 displayed=60 submittedFPS=60.0 displayFPS=60.0 frameAgeMs=28 displayLink=mtkview-native displayLinkTargetFPS=60 displayLinkPumpFPS=60 displayCadence=strict-60-native-pump-catch-up-vsync manualDraw=0 renderPath=directBGRA directBGRA=60 ciFallback=0 drawCallbacks=60 queueCapacity=3 queueDepthMax=2 queueDrop=0 queueBackpressure=0 coalescedBeforeDraw=0 realtimeReplacementBeforeDraw=0 realtimeReplacementReason=none drawableSkip=0 inflightSkip=0 failureSkip=0\n"
        ));
    }
    ios_log.push_str(
        "[2026-05-15T22:23:25Z] remote-desktop-pass seconds=10 requestedSeconds=10 windowSeconds=10 windowFPS=60.0 windowRxFps=60.0 windowDisplayedFrames=600 windowReceivedFrames=600 twoSecondRequiredFrames=118 min2sDisplayFrames=118 min2sRxFrames=118 rollingDisplayCadencePass=1 rollingRxCadencePass=1 rollingCadencePass=1 frame=2056x1329 audioRxRecv=600 audioRxDecoded=600 audioRxPlayed=600 audioRxJitterEvicted=0 audioRxPlaybackDrop=0 audioRxUnderflow=0 audioRxRebuffer=0\n",
    );
    std::fs::write(artifact_dir.join("ios-p2p-remote-TEST.status.log"), ios_log)?;

    let evidence = read_p2p_remote_performance_evidence(&artifact_dir)?;

    assert_eq!(
        evidence.final_metal_telemetry_samples,
        P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES
    );
    assert_eq!(
        evidence.final_lan_rx_samples,
        P2P_REMOTE_MIN_METAL_TELEMETRY_SAMPLES
    );
    assert_eq!(evidence.final_metal_queue_drop_total, 0);
    assert_eq!(evidence.final_ios_min_2s_rx_frames_min, Some(118));
    let metal_check = check_p2p_remote_metal_render_queue(&evidence, 59.0);
    assert!(metal_check.ok, "{}", metal_check.detail);
    let latency_check = check_p2p_remote_ios_raw_latency(&evidence, 59.0);
    assert!(latency_check.ok, "{}", latency_check.detail);
    let window_check = check_p2p_remote_ios_window_fps(&evidence, 59.0);
    assert!(window_check.ok, "{}", window_check.detail);
    Ok(())
}
