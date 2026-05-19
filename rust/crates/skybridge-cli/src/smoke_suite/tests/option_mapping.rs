use super::*;

#[test]
fn smoke_faults_options_are_mapped_to_swift_environment() {
    let root = PathBuf::from("/tmp/skybridge-test-root");
    let mut steps = Vec::new();
    push_fault_injection_steps(
        &root,
        &mut steps,
        SmokeFaultOptions {
            iterations: Some(200),
            timeout_ms: Some(2500),
            delay_ms: Some(100),
            progress_interval: Some(25),
        },
    );
    let fault_step = steps
        .iter()
        .find(|step| step.name == "handshake_fault_injection")
        .expect("fault injection step");
    for (name, value) in [
        ("SKYBRIDGE_RUN_FI", "1"),
        ("SKYBRIDGE_FI_ITERATIONS", "200"),
        ("SKYBRIDGE_FI_TIMEOUT_MS", "2500"),
        ("SKYBRIDGE_FI_DELAY_MS", "100"),
        ("SKYBRIDGE_FI_PROGRESS_INTERVAL", "25"),
    ] {
        assert!(
            fault_step
                .env
                .iter()
                .any(|(actual_name, actual_value)| actual_name == name && actual_value == value),
            "{name} should be passed to fault step"
        );
    }
}

#[test]
fn smoke_local_p2p_options_are_mapped_to_script_environment() {
    let root = PathBuf::from("/tmp/skybridge-test-root");
    let mut steps = Vec::new();
    push_local_p2p_smoke_steps(
        &root,
        &mut steps,
        SmokeLocalP2pOptions {
            scenario: LocalP2pSmokeScenario::CompatPurePqc,
            rounds: Some(3),
            timeout_seconds: Some(180),
            ios_device_id: Some("ios-smoke-device".to_owned()),
            target_name: Some("Mac Smoke Target".to_owned()),
        },
    );
    let p2p_step = steps
        .iter()
        .find(|step| step.name == "local_p2p_smoke")
        .expect("local P2P smoke step");
    assert_eq!(p2p_step.program, "bash");
    assert_eq!(
        p2p_step.args,
        vec!["Scripts/run_local_p2p_smoke.sh".to_owned()]
    );
    for (name, value) in [
        ("SKYBRIDGE_SMOKE_SCENARIO", "compat-pure-pqc"),
        ("SKYBRIDGE_SMOKE_ROUNDS", "3"),
        ("SKYBRIDGE_SMOKE_TIMEOUT_SECONDS", "180"),
        ("SKYBRIDGE_SMOKE_IOS_DEVICE_ID", "ios-smoke-device"),
        ("SKYBRIDGE_SMOKE_MAC_TARGET_NAME", "Mac Smoke Target"),
    ] {
        assert!(
            p2p_step
                .env
                .iter()
                .any(|(actual_name, actual_value)| actual_name == name && actual_value == value),
            "{name} should be passed to local P2P smoke step"
        );
    }
}
