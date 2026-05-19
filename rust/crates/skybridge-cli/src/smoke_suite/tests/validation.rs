use super::*;

#[tokio::test]
async fn smoke_suite_rejects_invalid_common_arguments() {
    let mut invalid_min = smoke_common(true, true);
    invalid_min.min_fps = 0.0;
    assert!(
        smoke_suite(SmokeSuiteArgs {
            profile: SmokeSuiteProfile::Quick,
            common: invalid_min,
        })
        .await
        .is_err()
    );

    let mut zero_timeout = smoke_common(true, true);
    zero_timeout.timeout_seconds = Some(0);
    assert!(
        smoke_suite(SmokeSuiteArgs {
            profile: SmokeSuiteProfile::Quick,
            common: zero_timeout,
        })
        .await
        .is_err()
    );

    let mut invalid_soak = smoke_common(true, true);
    invalid_soak.timeout_seconds = Some(30);
    invalid_soak.soak_seconds = 30;
    assert!(
        smoke_suite(SmokeSuiteArgs {
            profile: SmokeSuiteProfile::Quick,
            common: invalid_soak,
        })
        .await
        .is_err()
    );

    let mut zero_size = smoke_common(true, true);
    zero_size.video_width = 0;
    assert!(
        smoke_suite(SmokeSuiteArgs {
            profile: SmokeSuiteProfile::Quick,
            common: zero_size,
        })
        .await
        .is_err()
    );

    let mut conflicting_sizes = smoke_common(true, true);
    conflicting_sizes.mainstream_resolutions = true;
    conflicting_sizes.video_sizes = vec!["2056x1329".to_owned()];
    assert!(
        smoke_suite(SmokeSuiteArgs {
            profile: SmokeSuiteProfile::Quick,
            common: conflicting_sizes,
        })
        .await
        .is_err()
    );
}

#[tokio::test]
async fn smoke_local_p2p_rejects_zero_rounds_and_timeout() {
    assert!(
        smoke_local_p2p(SmokeLocalP2pArgs {
            dry_run: true,
            scenario: LocalP2pSmokeScenario::BootstrapRekey,
            rounds: Some(0),
            timeout_seconds: Some(60),
            ios_device_id: None,
            target_name: None,
            output: OutputOptions { json: true },
        })
        .await
        .is_err()
    );
    assert!(
        smoke_local_p2p(SmokeLocalP2pArgs {
            dry_run: true,
            scenario: LocalP2pSmokeScenario::BootstrapRekey,
            rounds: Some(1),
            timeout_seconds: Some(0),
            ios_device_id: None,
            target_name: None,
            output: OutputOptions { json: true },
        })
        .await
        .is_err()
    );
}
