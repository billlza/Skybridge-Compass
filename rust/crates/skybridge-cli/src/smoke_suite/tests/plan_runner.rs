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
