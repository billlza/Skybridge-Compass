use super::*;

#[test]
fn p2p_remote_full_performance_golden_fixture_passes() -> Result<()> {
    let artifact_dir = fixture_dir(&["p2p-remote", "full-2k60-pass"]);
    let args = performance_artifact_args(PerformanceKindArg::P2pRemote, artifact_dir);
    let report = build_p2p_remote_performance_report(&args)?;

    for check_name in [
        "p2p_remote_sources",
        "p2p_remote_complete_artifact",
        "p2p_remote_no_hidden_failure",
        "p2p_remote_lan_route",
        "p2p_remote_xwing",
        "p2p_remote_protocol_identity_binding",
        "p2p_remote_signed_kem_refresh",
        "p2p_remote_mac_ipad_online_connect_button",
        "p2p_remote_hevc_main_path",
        "p2p_remote_resolution",
        "p2p_remote_ios_window_fps",
        "p2p_remote_mac_tx_backpressure",
        "p2p_remote_mac_final_window_fps",
        "p2p_remote_timing_correlation",
        "p2p_remote_ios_raw_latency",
        "p2p_remote_metal_render_queue",
        "p2p_remote_decode_queue",
        "p2p_remote_audio_continuity",
        "p2p_remote_no_fallback",
        "performance_check_surface",
    ] {
        let check = doctor_check(&report, check_name);
        assert!(check.ok, "{check_name}: {}", check.detail);
    }
    Ok(())
}

#[test]
fn p2p_remote_full_report_rejects_low_lan_rx_screen_fps_even_with_pass_window() -> Result<()> {
    let fixture = fixture_dir(&["p2p-remote", "full-2k60-pass"]);
    let artifact_dir = make_test_dir("p2p-remote-low-lan-rx-screen-fps")?;
    for entry in std::fs::read_dir(&fixture)? {
        let entry = entry?;
        if entry.file_type()?.is_file() {
            std::fs::copy(entry.path(), artifact_dir.join(entry.file_name()))?;
        }
    }

    let ios_log_path = artifact_dir.join("ios-p2p-remote-golden.status.log");
    let ios_log = std::fs::read_to_string(&ios_log_path)?;
    let low_lan_rx_log = ios_log.replacen(
        "ios-lan-remote-rx sampleMs=1000 screenFrames=60 screenFPS=60.0",
        "ios-lan-remote-rx sampleMs=1000 screenFrames=10 screenFPS=10.0",
        1,
    );
    assert_ne!(
        ios_log, low_lan_rx_log,
        "golden fixture must contain an ios-lan-remote-rx screenFPS sample"
    );
    std::fs::write(&ios_log_path, low_lan_rx_log)?;

    let args = performance_artifact_args(PerformanceKindArg::P2pRemote, artifact_dir);
    let report = build_p2p_remote_performance_report(&args)?;
    let window = doctor_check(&report, "p2p_remote_ios_window_fps");
    assert!(
        window.ok,
        "this fixture keeps the high-level pass window green: {}",
        window.detail
    );
    let raw_latency = doctor_check(&report, "p2p_remote_ios_raw_latency");
    assert!(!raw_latency.ok, "{}", raw_latency.detail);
    assert!(raw_latency.detail.contains("lanRxScreenFPS=10.0"));
    Ok(())
}

#[test]
fn p2p_remote_full_report_rejects_deferred_continuity_with_low_input_display_fps() -> Result<()> {
    let fixture = fixture_dir(&["p2p-remote", "full-2k60-pass"]);
    let artifact_dir = make_test_dir("p2p-remote-deferred-continuity-low-fps")?;
    for entry in std::fs::read_dir(&fixture)? {
        let entry = entry?;
        if entry.file_type()?.is_file() {
            std::fs::copy(entry.path(), artifact_dir.join(entry.file_name()))?;
        }
    }

    let ios_log_path = artifact_dir.join("ios-p2p-remote-golden.status.log");
    let ios_log = std::fs::read_to_string(&ios_log_path)?;
    let low_rx_log = ios_log.replacen(
        "ios-lan-remote-rx sampleMs=1000 screenFrames=60 screenFPS=60.0",
        "ios-lan-remote-rx sampleMs=1000 screenFrames=10 screenFPS=10.0",
        1,
    );
    let low_render_log = low_rx_log.replace(
        "Metal render telemetry: sampleMs=1000 input=60 submitted=60 displayed=60 submittedFPS=60.0 displayFPS=60.0",
        "Metal render telemetry: sampleMs=1000 input=10 submitted=10 displayed=10 inputFPS=10.0 submittedFPS=10.0 displayFPS=10.0",
    );
    assert_ne!(
        ios_log, low_render_log,
        "golden fixture must contain iOS LAN and Metal 60fps samples"
    );
    std::fs::write(
        &ios_log_path,
        format!(
            "{low_render_log}\n[2026-05-16T01:00:08.500Z] render-continuity-deferred session=s1 reason=frames-decoding-without-display classification=input-cadence-below-display-failure-threshold inputFPS=10.0 displayFPS=10.0 displayedWindow=10 displayedTotal=100 metalDisplayedWindow=10 metalDisplayedTotal=100 attemptedFallback=none fallbackResult=not-attempted\n[2026-05-16T01:00:08.501Z] render-continuity-deferred-action reason=frames-decoding-without-display classification=input-cadence-below-display-failure-threshold attemptedFallback=none fallbackResult=not-attempted streamRefresh=suppressed\n"
        ),
    )?;

    let args = performance_artifact_args(PerformanceKindArg::P2pRemote, artifact_dir);
    let report = build_p2p_remote_performance_report(&args)?;

    let fallback = doctor_check(&report, "p2p_remote_no_fallback");
    assert!(
        fallback.ok,
        "deferred continuity with attemptedFallback=none must not be parsed as fallback: {}",
        fallback.detail
    );

    let raw_latency = doctor_check(&report, "p2p_remote_ios_raw_latency");
    assert!(!raw_latency.ok, "{}", raw_latency.detail);
    assert!(raw_latency.detail.contains("lanRxScreenFPS=10.0"));

    let metal = doctor_check(&report, "p2p_remote_metal_render_queue");
    assert!(!metal.ok, "{}", metal.detail);
    assert!(metal.detail.contains("inputFPS"));
    assert!(metal.detail.contains("displayFPS"));
    Ok(())
}

#[test]
fn p2p_remote_performance_defaults_to_exact_2k60_resolution_gate() {
    let args = PerformanceCheckArgs {
        kind: PerformanceKindArg::P2pRemote,
        session_id: None,
        latest: false,
        artifact_dir: None,
        log_file: None,
        since_seconds: 1,
        min_fps: 59.0,
        min_width: 0,
        min_height: 0,
        exact_video_size: false,
        require_audio: true,
        strict_fps_floor: true,
        min_pass_window_seconds: P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS,
        manual_artifact: false,
        output: OutputOptions { json: false },
    };

    let mut good = P2pRemotePerformanceEvidence {
        frame_width: Some(2056),
        frame_height: Some(1330),
        visible_width: Some(2056),
        visible_height: Some(1329),
        ..Default::default()
    };
    let check = check_p2p_remote_resolution(&good, &args);
    assert!(check.ok, "{}", check.detail);
    assert!(check.detail.contains("required=2056x1329"));
    assert!(check.detail.contains("acceptedAltHeight=Some(1328)"));
    assert!(check.detail.contains("defaultStrict2K60=true"));

    good.visible_height = Some(1328);
    let check = check_p2p_remote_resolution(&good, &args);
    assert!(check.ok, "{}", check.detail);

    good.visible_height = Some(1327);
    let check = check_p2p_remote_resolution(&good, &args);
    assert!(!check.ok, "{}", check.detail);
}
