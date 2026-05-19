use std::path::Path;

use super::{SmokeFaultOptions, SmokeLocalP2pOptions, SmokeSuiteStepSpec, swift_test_cache_env};

pub(super) fn push_quick_smoke_steps(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>) {
    steps.push(SmokeSuiteStepSpec {
        name: "rust_webrtc_cli_tests",
        description: "Rust CLI WebRTC doctor and smoke gate tests",
        program: "cargo".to_owned(),
        args: vec![
            "test".to_owned(),
            "--manifest-path".to_owned(),
            "rust/Cargo.toml".to_owned(),
            "-p".to_owned(),
            "skybridge".to_owned(),
            "webrtc".to_owned(),
        ],
        env: vec![],
        cwd: root.to_path_buf(),
    });
    steps.push(SmokeSuiteStepSpec {
        name: "swift_webrtc_policy_tests",
        description: "Swift WebRTC realtime media and stream start policy tests",
        program: "swift".to_owned(),
        args: vec![
            "test".to_owned(),
            "--filter".to_owned(),
            "SkyBridgeRealtimeMediaTests|CrossNetworkWebRTCStreamStartPolicyTests".to_owned(),
        ],
        env: swift_test_cache_env(root),
        cwd: root.to_path_buf(),
    });
    push_signaling_server_step(root, steps);
}

pub(super) fn push_full_smoke_steps(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>) {
    steps.push(SmokeSuiteStepSpec {
        name: "rust_workspace_tests",
        description: "Rust workspace test suite",
        program: "cargo".to_owned(),
        args: vec![
            "test".to_owned(),
            "--manifest-path".to_owned(),
            "rust/Cargo.toml".to_owned(),
            "--workspace".to_owned(),
        ],
        env: vec![],
        cwd: root.to_path_buf(),
    });
    steps.push(SmokeSuiteStepSpec {
        name: "swift_package_tests",
        description: "Swift package test suite",
        program: "swift".to_owned(),
        args: vec!["test".to_owned()],
        env: swift_test_cache_env(root),
        cwd: root.to_path_buf(),
    });
    push_signaling_server_step(root, steps);
}

fn push_signaling_server_step(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>) {
    steps.push(SmokeSuiteStepSpec {
        name: "signaling_server_tests",
        description: "Node signaling and media relay tests",
        program: "npm".to_owned(),
        args: vec!["test".to_owned()],
        env: vec![],
        cwd: root.join("Server").join("skybridge-signaling"),
    });
}

pub(super) fn push_script_test_steps(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>) {
    for (name, description, script) in [
        (
            "xcodebuild_helper_tests",
            "macOS xcodebuild helper shell tests",
            "Scripts/test_xcodebuild_helpers.sh",
        ),
        (
            "package_build_policy_tests",
            "release package build-policy shell tests",
            "Scripts/test_package_build_policy.sh",
        ),
        (
            "signing_entitlements_helper_tests",
            "signing entitlement helper shell tests",
            "Scripts/test_signing_entitlements_helpers.sh",
        ),
        (
            "ios_test_configuration_script_tests",
            "iOS test configuration guard fixture tests",
            "Scripts/test_check_ios_test_configuration.sh",
        ),
    ] {
        steps.push(SmokeSuiteStepSpec {
            name,
            description,
            program: "bash".to_owned(),
            args: vec![script.to_owned()],
            env: vec![],
            cwd: root.to_path_buf(),
        });
    }
}

pub(super) fn push_ios_config_steps(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>) {
    steps.push(SmokeSuiteStepSpec {
        name: "ios_test_configuration_static_gate",
        description: "Static iOS Xcode test target and scheme configuration gate",
        program: "bash".to_owned(),
        args: vec![
            "Scripts/check_ios_test_configuration.sh".to_owned(),
            "--static-only".to_owned(),
        ],
        env: vec![],
        cwd: root.to_path_buf(),
    });
}

pub(super) fn push_local_webrtc_smoke_steps(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    min_fps: f64,
) {
    steps.push(SmokeSuiteStepSpec {
        name: "local_webrtc_smoke",
        description: "Local simulator WebRTC bootstrap smoke with Rust media doctor gate",
        program: "bash".to_owned(),
        args: vec!["Scripts/run_local_webrtc_smoke.sh".to_owned()],
        env: vec![(
            "SKYBRIDGE_SMOKE_MIN_FPS".to_owned(),
            format!("{min_fps:.2}"),
        )],
        cwd: root.to_path_buf(),
    });
}

pub(in crate::smoke_suite) fn push_local_p2p_smoke_steps(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    options: SmokeLocalP2pOptions,
) {
    let mut env = vec![(
        "SKYBRIDGE_SMOKE_SCENARIO".to_owned(),
        options.scenario.as_env_value().to_owned(),
    )];
    if let Some(rounds) = options.rounds {
        env.push(("SKYBRIDGE_SMOKE_ROUNDS".to_owned(), rounds.to_string()));
    }
    if let Some(timeout_seconds) = options.timeout_seconds {
        env.push((
            "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS".to_owned(),
            timeout_seconds.to_string(),
        ));
    }
    if let Some(ios_device_id) = options.ios_device_id {
        env.push(("SKYBRIDGE_SMOKE_IOS_DEVICE_ID".to_owned(), ios_device_id));
    }
    if let Some(target_name) = options.target_name {
        env.push(("SKYBRIDGE_SMOKE_MAC_TARGET_NAME".to_owned(), target_name));
    }
    steps.push(SmokeSuiteStepSpec {
        name: "local_p2p_smoke",
        description: "Local simulator P2P bootstrap and PQC rekey smoke",
        program: "bash".to_owned(),
        args: vec!["Scripts/run_local_p2p_smoke.sh".to_owned()],
        env,
        cwd: root.to_path_buf(),
    });
}

pub(in crate::smoke_suite) fn push_fault_injection_steps(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    options: SmokeFaultOptions,
) {
    let mut env = swift_test_cache_env(root);
    env.push(("SKYBRIDGE_RUN_FI".to_owned(), "1".to_owned()));
    if let Some(iterations) = options.iterations {
        env.push(("SKYBRIDGE_FI_ITERATIONS".to_owned(), iterations.to_string()));
    }
    if let Some(timeout_ms) = options.timeout_ms {
        env.push(("SKYBRIDGE_FI_TIMEOUT_MS".to_owned(), timeout_ms.to_string()));
    }
    if let Some(delay_ms) = options.delay_ms {
        env.push(("SKYBRIDGE_FI_DELAY_MS".to_owned(), delay_ms.to_string()));
    }
    if let Some(progress_interval) = options.progress_interval {
        env.push((
            "SKYBRIDGE_FI_PROGRESS_INTERVAL".to_owned(),
            progress_interval.to_string(),
        ));
    }
    steps.push(SmokeSuiteStepSpec {
        name: "handshake_fault_injection",
        description: "Swift handshake fault-injection suite",
        program: "swift".to_owned(),
        args: vec![
            "test".to_owned(),
            "--filter".to_owned(),
            "HandshakeFaultInjectionBenchTests".to_owned(),
        ],
        env,
        cwd: root.to_path_buf(),
    });
}

pub(super) fn push_release_smoke_steps(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>) {
    steps.push(SmokeSuiteStepSpec {
        name: "macos_release_readiness",
        description: "Signed and notarized macOS release readiness gate",
        program: "bash".to_owned(),
        args: vec![
            "Scripts/check_macos_release_readiness.sh".to_owned(),
            "--require-notarization".to_owned(),
        ],
        env: vec![],
        cwd: root.to_path_buf(),
    });
}
