use super::*;

#[test]
fn smoke_suite_real_device_file_transfer_profile_is_direct() -> Result<()> {
    let root = PathBuf::from("/tmp/skybridge-test-root");
    let steps = build_smoke_suite_steps(
        &root,
        SmokeSuiteProfile::RealDeviceFileTransfer,
        false,
        Some("ios-file-device"),
        None,
        59.0,
        Some(240),
        0,
        &[],
    )?;
    assert_eq!(steps.len(), 1);
    let step = &steps[0];
    assert_eq!(step.name, "real_device_file_transfer_smoke");
    assert_eq!(
        step.args,
        vec!["Scripts/run_real_device_file_transfer_smoke.sh".to_owned()]
    );
    for (name, value) in [
        ("SKYBRIDGE_SMOKE_USER_REALISTIC", "1"),
        ("SKYBRIDGE_SMOKE_PRESERVE_INSTALL", "1"),
        ("SKYBRIDGE_SMOKE_MAC_HOST_MODE", "signed-app"),
        ("SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH", "1"),
        ("SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH", "1"),
        ("SKYBRIDGE_REAL_DEVICE_ID", "ios-file-device"),
        ("SKYBRIDGE_SMOKE_TIMEOUT_SECONDS", "240"),
    ] {
        assert!(
            step.env
                .iter()
                .any(|(actual_name, actual_value)| actual_name == name && actual_value == value),
            "{name} should be passed to direct real-device file-transfer smoke"
        );
    }
    Ok(())
}

#[test]
fn smoke_suite_real_device_file_transfer_profile_rejects_skip_flag() {
    assert!(is_real_device_smoke_profile(
        SmokeSuiteProfile::RealDeviceFileTransfer
    ));
}
