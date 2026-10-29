use std::path::Path;

use super::{SmokeSuiteStepSpec, swift_test_cache_env};

pub(super) fn push_benchmark_steps(root: &Path, steps: &mut Vec<SmokeSuiteStepSpec>) {
    push_swift_benchmark_step(
        root,
        steps,
        "swift_handshake_benchmarks",
        "Swift handshake and data-plane benchmark tests",
        &[("SKYBRIDGE_RUN_BENCH", "1")],
        "HandshakeBenchmarkTests|HandshakeDriverTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "policy_downgrade_benchmarks",
        "Swift policy downgrade benchmark tests",
        &[("SKYBRIDGE_RUN_POLICY_BENCH", "1")],
        "PolicyDowngradeBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "migration_coverage_benchmarks",
        "Swift migration coverage benchmark tests",
        &[("SKYBRIDGE_RUN_MIGRATION_BENCH", "1")],
        "MigrationCoverageBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "migration_harness_benchmarks",
        "Swift migration threat harness benchmark tests",
        &[("SKYBRIDGE_RUN_MIGRATION_HARNESS", "1")],
        "MigrationThreatHarnessBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "migration_provider_matrix_benchmarks",
        "Swift migration provider matrix benchmark tests",
        &[("SKYBRIDGE_RUN_MIGRATION_PROVIDER_MATRIX", "1")],
        "MigrationThreatProviderMatrixBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "migration_fleet_behavior_benchmarks",
        "Swift migration fleet behavior benchmark tests",
        &[("SKYBRIDGE_RUN_MIGRATION_FLEET_BENCH", "1")],
        "MigrationFleetBehaviorBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "soa_interoperability_benchmarks",
        "Swift SOA interoperability benchmark tests",
        &[("SKYBRIDGE_RUN_SOA_BENCH", "1")],
        "SOAInteroperabilityBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "network_condition_benchmarks",
        "Swift network condition benchmark tests",
        &[("SKYBRIDGE_RUN_NETWORK_BENCH", "1")],
        "NetworkConditionBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "boundary_stress_benchmarks",
        "Swift boundary stress benchmark tests",
        &[("SKYBRIDGE_RUN_BOUNDARY_STRESS", "1")],
        "BoundaryStressBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "traffic_padding_benchmarks",
        "Swift traffic padding benchmark tests",
        &[("SKYBRIDGE_RUN_PADDING_BENCH", "1")],
        "TrafficPaddingBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "traffic_padding_sensitivity_benchmarks",
        "Swift traffic padding sensitivity benchmark tests",
        &[("SKYBRIDGE_RUN_PADDING_SENS", "1")],
        "TrafficPaddingSensitivityBenchTests",
    );
    push_swift_benchmark_step(
        root,
        steps,
        "system_impact_benchmarks",
        "Swift system impact benchmark tests",
        &[("SKYBRIDGE_RUN_SYSTEM_IMPACT", "1")],
        "SystemImpactBenchTests",
    );
}

fn push_swift_benchmark_step(
    root: &Path,
    steps: &mut Vec<SmokeSuiteStepSpec>,
    name: &'static str,
    description: &'static str,
    benchmark_env: &[(&str, &str)],
    filter: &'static str,
) {
    let mut env = swift_test_cache_env(root);
    for (name, value) in benchmark_env {
        env.push(((*name).to_owned(), (*value).to_owned()));
    }
    steps.push(SmokeSuiteStepSpec {
        name,
        description,
        program: "swift".to_owned(),
        args: vec!["test".to_owned(), "--filter".to_owned(), filter.to_owned()],
        env,
        cwd: root.to_path_buf(),
    });
}
