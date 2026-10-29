use super::*;

#[test]
fn smoke_suite_real_device_can_expand_mainstream_resolution_matrix() -> Result<()> {
    let root = PathBuf::from("/tmp/skybridge-test-root");
    let steps = build_smoke_suite_steps(
        &root,
        SmokeSuiteProfile::RealDevice,
        false,
        None,
        None,
        30.0,
        Some(900),
        0,
        MAINSTREAM_WEBRTC_VIDEO_SIZES,
    )?;
    let webrtc_steps = steps
        .iter()
        .filter(|step| step.name == "real_device_webrtc_smoke")
        .collect::<Vec<_>>();
    assert_eq!(webrtc_steps.len(), MAINSTREAM_WEBRTC_VIDEO_SIZES.len());
    for size in MAINSTREAM_WEBRTC_VIDEO_SIZES {
        assert!(webrtc_steps.iter().any(|step| {
            step.env.iter().any(|(name, value)| {
                name == "SKYBRIDGE_SMOKE_VIDEO_WIDTH" && value == &size.width.to_string()
            }) && step.env.iter().any(|(name, value)| {
                name == "SKYBRIDGE_SMOKE_VIDEO_HEIGHT" && value == &size.height.to_string()
            })
        }));
    }
    assert_eq!(
        steps
            .iter()
            .filter(|step| step.name == "real_device_p2p_remote_smoke")
            .count(),
        MAINSTREAM_WEBRTC_VIDEO_SIZES.len()
    );
    assert_eq!(
        steps
            .iter()
            .filter(|step| step.name == "real_device_file_transfer_smoke")
            .count(),
        1
    );
    Ok(())
}
