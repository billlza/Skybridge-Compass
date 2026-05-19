use super::*;

#[tokio::test]
async fn smoke_suite_dry_run_renders_quick_plan_text() -> Result<()> {
    smoke_suite(SmokeSuiteArgs {
        profile: SmokeSuiteProfile::Quick,
        common: smoke_common(true, false),
    })
    .await
}

#[tokio::test]
async fn smoke_suite_dry_run_renders_json_for_all_without_real_device() -> Result<()> {
    let mut common = smoke_common(true, true);
    common.skip_real_device = true;
    common.min_fps = 59.0;
    common.timeout_seconds = Some(300);
    common.soak_seconds = 30;
    smoke_suite(SmokeSuiteArgs {
        profile: SmokeSuiteProfile::All,
        common,
    })
    .await
}

#[tokio::test]
async fn smoke_faults_dry_run_renders_json_with_options() -> Result<()> {
    smoke_faults(SmokeFaultsArgs {
        dry_run: true,
        iterations: Some(4),
        timeout_ms: Some(250),
        delay_ms: Some(10),
        progress_interval: Some(1),
        output: OutputOptions { json: true },
    })
    .await
}

#[tokio::test]
async fn smoke_local_p2p_dry_run_renders_text_with_options() -> Result<()> {
    smoke_local_p2p(SmokeLocalP2pArgs {
        dry_run: true,
        scenario: LocalP2pSmokeScenario::XwingOnly,
        rounds: Some(2),
        timeout_seconds: Some(120),
        ios_device_id: Some("ios-device".to_owned()),
        target_name: Some("Mac Target".to_owned()),
        output: OutputOptions { json: false },
    })
    .await
}
