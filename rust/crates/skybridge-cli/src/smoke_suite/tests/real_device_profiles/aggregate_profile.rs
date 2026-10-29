use super::*;

#[test]
fn smoke_suite_real_device_steps_carry_device_auth_and_fps_env() -> Result<()> {
    let root = PathBuf::from("/tmp/skybridge-test-root");
    let auth_path = Path::new("/tmp/auth-session.json");
    let steps = build_smoke_suite_steps(
        &root,
        SmokeSuiteProfile::RealDevice,
        false,
        Some("00008132-0006452C1138801C"),
        Some(auth_path),
        30.0,
        Some(900),
        600,
        &[VideoDimensions {
            width: 2056,
            height: 1329,
        }],
    )?;
    let webrtc = steps
        .iter()
        .find(|step| step.name == "real_device_webrtc_smoke")
        .expect("real-device WebRTC step");
    assert!(webrtc.env.iter().any(|(name, value)| {
        name == "SKYBRIDGE_REAL_DEVICE_ID" && value == "00008132-0006452C1138801C"
    }));
    assert!(webrtc.env.iter().any(|(name, value)| {
        name == "SKYBRIDGE_SMOKE_AUTH_SESSION_FILE" && value == "/tmp/auth-session.json"
    }));
    assert!(
        webrtc
            .env
            .iter()
            .any(|(name, value)| name == "SKYBRIDGE_SMOKE_MIN_FPS" && value == "30.00")
    );
    assert!(
        webrtc
            .env
            .iter()
            .any(|(name, value)| name == "SKYBRIDGE_SMOKE_TARGET_FPS" && value == "32")
    );
    assert!(
        webrtc
            .env
            .iter()
            .any(|(name, value)| name == "SKYBRIDGE_SMOKE_REQUIRE_AUDIO" && value == "1")
    );
    assert!(
        webrtc
            .env
            .iter()
            .any(|(name, value)| { name == "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS" && value == "900" })
    );
    assert!(
        webrtc
            .env
            .iter()
            .any(|(name, value)| { name == "SKYBRIDGE_SMOKE_SOAK_SECONDS" && value == "600" })
    );
    assert!(
        webrtc
            .env
            .iter()
            .any(|(name, value)| name == "SKYBRIDGE_SMOKE_FORCE_RELAY_ICE" && value == "1")
    );
    assert!(
        webrtc
            .env
            .iter()
            .any(|(name, value)| name == "SKYBRIDGE_SMOKE_EXTREME_MEDIA" && value == "1")
    );
    assert!(
        webrtc
            .env
            .iter()
            .any(|(name, value)| { name == "SKYBRIDGE_SMOKE_VIDEO_WIDTH" && value == "2056" })
    );
    assert!(
        webrtc
            .env
            .iter()
            .any(|(name, value)| { name == "SKYBRIDGE_SMOKE_VIDEO_HEIGHT" && value == "1329" })
    );
    assert!(webrtc.env.iter().any(|(name, value)| {
        name == "SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK" && value == "1"
    }));
    assert!(
        webrtc.env.iter().any(|(name, value)| {
            name == "SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN" && value == "0"
        })
    );
    let p2p_remote = steps
        .iter()
        .find(|step| step.name == "real_device_p2p_remote_smoke")
        .expect("real-device P2P remote step");
    assert_eq!(
        p2p_remote.args,
        vec!["Scripts/run_real_device_p2p_remote_smoke.sh".to_owned()]
    );
    for (name, value) in [
        ("SKYBRIDGE_REAL_DEVICE_ID", "00008132-0006452C1138801C"),
        ("SKYBRIDGE_SMOKE_MIN_FPS", "30.00"),
        ("SKYBRIDGE_SMOKE_TARGET_FPS", "60"),
        ("SKYBRIDGE_SMOKE_REQUIRE_AUDIO", "1"),
        ("SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB", "1"),
        ("SKYBRIDGE_SMOKE_REQUIRE_VISIBLE_REMOTE_VIEW", "1"),
        ("SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY", "0"),
        ("SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE", "X-Wing"),
        ("SKYBRIDGE_SMOKE_TIMEOUT_SECONDS", "900"),
        ("SKYBRIDGE_SMOKE_SOAK_SECONDS", "600"),
        ("SKYBRIDGE_SMOKE_VIDEO_WIDTH", "2056"),
        ("SKYBRIDGE_SMOKE_VIDEO_HEIGHT", "1329"),
        ("SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION", "upright"),
        ("SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH", "1"),
        ("SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH", "1"),
    ] {
        assert!(
            p2p_remote
                .env
                .iter()
                .any(|(actual_name, actual_value)| actual_name == name && actual_value == value),
            "{name} should be passed to real-device P2P remote step"
        );
    }
    let file_transfer = steps
        .iter()
        .find(|step| step.name == "real_device_file_transfer_smoke")
        .expect("real-device file-transfer step");
    assert_eq!(
        file_transfer.args,
        vec!["Scripts/run_real_device_file_transfer_smoke.sh".to_owned()]
    );
    for (name, value) in [
        ("SKYBRIDGE_SMOKE_USER_REALISTIC", "1"),
        ("SKYBRIDGE_SMOKE_PRESERVE_INSTALL", "1"),
        ("SKYBRIDGE_SMOKE_MAC_HOST_MODE", "signed-app"),
        ("SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH", "1"),
        ("SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH", "1"),
        ("SKYBRIDGE_REAL_DEVICE_ID", "00008132-0006452C1138801C"),
        ("SKYBRIDGE_SMOKE_TIMEOUT_SECONDS", "900"),
    ] {
        assert!(
            file_transfer
                .env
                .iter()
                .any(|(actual_name, actual_value)| actual_name == name && actual_value == value),
            "{name} should be passed to real-device file-transfer step"
        );
    }
    Ok(())
}
