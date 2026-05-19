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
    assert!(check.detail.contains("defaultStrict2K60=true"));

    good.visible_height = Some(1328);
    let check = check_p2p_remote_resolution(&good, &args);
    assert!(!check.ok, "{}", check.detail);
}
