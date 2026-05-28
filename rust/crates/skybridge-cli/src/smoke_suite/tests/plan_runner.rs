use super::*;

#[test]
fn smoke_suite_plan_runs_success_paths_and_reports_failures() -> Result<()> {
    let root = PathBuf::from("/tmp/skybridge-test-root");
    std::fs::create_dir_all(&root)?;
    run_smoke_suite_plan(
        &root,
        SmokeSuiteProfile::Quick,
        false,
        false,
        vec![shell_step(&root, "success-text", "exit 0")],
    )?;
    run_smoke_suite_plan(
        &root,
        SmokeSuiteProfile::Quick,
        false,
        true,
        vec![shell_step(&root, "success-json", "printf stdout-line")],
    )?;

    let failure = run_smoke_suite_plan(
        &root,
        SmokeSuiteProfile::Quick,
        false,
        true,
        vec![shell_step(
            &root,
            "failure-json",
            "printf stdout-line; printf stderr-line >&2; exit 7",
        )],
    )
    .unwrap_err();
    assert!(failure.to_string().contains("failure-json"));
    Ok(())
}

#[test]
fn smoke_suite_all_profile_can_skip_real_device_steps() -> Result<()> {
    let root = PathBuf::from("/tmp/skybridge-test-root");
    let steps = build_smoke_suite_steps(
        &root,
        SmokeSuiteProfile::All,
        true,
        None,
        None,
        30.0,
        None,
        0,
        &[VideoDimensions {
            width: 2056,
            height: 1329,
        }],
    )?;
    let names = steps.iter().map(|step| step.name).collect::<Vec<_>>();
    assert!(names.contains(&"rust_workspace_tests"));
    assert!(names.contains(&"swift_package_tests"));
    assert!(names.contains(&"signaling_server_tests"));
    assert!(names.contains(&"xcodebuild_helper_tests"));
    assert!(names.contains(&"ios_test_configuration_static_gate"));
    assert!(names.contains(&"local_p2p_smoke"));
    assert!(names.contains(&"local_webrtc_smoke"));
    assert!(names.contains(&"handshake_fault_injection"));
    assert!(names.contains(&"swift_handshake_benchmarks"));
    assert!(names.contains(&"macos_release_readiness"));
    assert!(!names.contains(&"real_device_webrtc_smoke"));
    assert!(!names.contains(&"real_device_file_transfer_smoke"));
    Ok(())
}

#[test]
fn smoke_suite_security_notice_profiles_include_artifact_check() -> Result<()> {
    let root = PathBuf::from("/tmp/skybridge-test-root");
    let local_steps = build_smoke_suite_steps(
        &root,
        SmokeSuiteProfile::LocalWebrtcSecurityNotice,
        false,
        None,
        None,
        30.0,
        None,
        0,
        &[],
    )?;
    let local_names = local_steps.iter().map(|step| step.name).collect::<Vec<_>>();
    assert!(local_names.contains(&"local_webrtc_security_notice_smoke"));
    assert!(local_names.contains(&"local_macos_security_notice_panel_probe"));
    assert!(local_names.contains(&"remote_control_security_notice_check"));
    assert!(
        local_steps
            .iter()
            .any(|step| step.args.iter().any(|arg| arg == "webrtc"))
    );
    assert!(
        local_steps
            .iter()
            .any(|step| step.args.iter().any(|arg| arg == "--require-panel"))
    );

    let real_steps = build_smoke_suite_steps(
        &root,
        SmokeSuiteProfile::RealDeviceP2pSecurityNotice,
        false,
        Some("ios-device"),
        None,
        30.0,
        Some(300),
        0,
        &[VideoDimensions {
            width: 2056,
            height: 1329,
        }],
    )?;
    let real_names = real_steps.iter().map(|step| step.name).collect::<Vec<_>>();
    assert!(real_names.contains(&"real_device_p2p_security_notice_smoke"));
    assert!(real_names.contains(&"remote_control_security_notice_check"));
    assert!(
        real_steps
            .iter()
            .any(|step| step.args.iter().any(|arg| arg == "p2p"))
    );
    let real_notice_check = real_steps
        .iter()
        .find(|step| step.name == "remote_control_security_notice_check")
        .expect("real device profile should include a P2P notice checker");
    let real_notice_smoke = real_steps
        .iter()
        .find(|step| step.name == "real_device_p2p_security_notice_smoke")
        .expect("real device profile should include a P2P security notice smoke step");
    assert!(
        real_notice_smoke
            .env
            .iter()
            .any(|(name, value)| { name == "SKYBRIDGE_SMOKE_RUN_MAC_ONLINE_IPAD" && value == "0" }),
        "security notice profile should not start a second full GUI app while the P2P remote-control session is active"
    );
    assert!(
        !real_notice_check
            .args
            .iter()
            .any(|arg| arg == "--require-panel"),
        "LocalLanInteropHost verifies real P2P notice lifecycle; production AppKit panel evidence is covered by local-macos-security-notice-panel"
    );
    Ok(())
}
