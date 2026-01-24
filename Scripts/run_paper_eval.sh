#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"

mkdir -p Artifacts

test_target="SkyBridgeCoreTests"

# Keep artifact date suffix consistent across all benches/tables.
# Prefer ARTIFACT_DATE, fall back to SKYBRIDGE_ARTIFACT_DATE for compatibility.
if [[ -z "${ARTIFACT_DATE:-}" ]] && [[ -n "${SKYBRIDGE_ARTIFACT_DATE:-}" ]]; then
  export ARTIFACT_DATE="${SKYBRIDGE_ARTIFACT_DATE}"
fi

swift_flags=()
if command -v xcrun >/dev/null 2>&1; then
  sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  if [[ -n "${sdk_path}" ]]; then
    # Detect CryptoKit PQC types in the active SDK.
    if command -v rg >/dev/null 2>&1; then
      has_pqc=$(rg -q "MLKEM768" "$sdk_path/System/Library/Frameworks/CryptoKit.framework/Versions/A/Modules/CryptoKit.swiftmodule" && echo "1" || echo "0")
    else
      has_pqc=$(grep -q "MLKEM768" "$sdk_path/System/Library/Frameworks/CryptoKit.framework/Versions/A/Modules/CryptoKit.swiftmodule"/* 2>/dev/null && echo "1" || echo "0")
    fi
    if [[ "${has_pqc}" == "1" ]]; then
      swift_flags=("-Xswiftc" "-DHAS_APPLE_PQC_SDK")
      export HAS_APPLE_PQC_SDK=1
    fi
  fi
fi

if [[ "${#swift_flags[@]}" -gt 0 ]]; then
  echo "=== Apple PQC SDK detected: enabling -DHAS_APPLE_PQC_SDK for SwiftPM runs ==="
else
  echo "=== Apple PQC SDK NOT detected: benches will run without -DHAS_APPLE_PQC_SDK ==="
fi

export SKYBRIDGE_RUN_BENCH=1
bench_batches="${SKYBRIDGE_BENCH_BATCHES:-1}"
if ! [[ "${bench_batches}" =~ ^[0-9]+$ ]] || [[ "${bench_batches}" -lt 1 ]]; then
  echo "Invalid SKYBRIDGE_BENCH_BATCHES='${bench_batches}', expected integer >= 1" >&2
  exit 2
fi
for ((i=1; i<=bench_batches; i++)); do
  echo "=== Handshake benchmarks (batch ${i}/${bench_batches}) ==="
  swift test --filter "${test_target}.HandshakeBenchmarkTests" "${swift_flags[@]}"
done

export SKYBRIDGE_RUN_FI=1
export SKYBRIDGE_FI_ITERATIONS=1000
swift test --filter "${test_target}.HandshakeFaultInjectionBenchTests" "${swift_flags[@]}"

export SKYBRIDGE_RUN_POLICY_BENCH=1
export SKYBRIDGE_POLICY_ITERATIONS=1000
swift test --filter "${test_target}.PolicyDowngradeBenchTests" "${swift_flags[@]}"

export SKYBRIDGE_RUN_MIGRATION_BENCH=1
export SKYBRIDGE_MIGRATION_ITERATIONS=1000
swift test --filter "${test_target}.MigrationCoverageBenchTests" "${swift_flags[@]}"

swift test --filter "${test_target}.MessageSizeSnapshotTests" "${swift_flags[@]}"

swift build --product MessageSizeBenchRunner "${swift_flags[@]}"
./.build/debug/MessageSizeBenchRunner

# Phase C3 (TDSC): TrafficPadding quantization + telemetry artifacts
export SKYBRIDGE_RUN_PADDING_BENCH=1
export SKYBRIDGE_PADDING_ITERATIONS="${SKYBRIDGE_PADDING_ITERATIONS:-2000}"
swift test --filter "${test_target}.TrafficPaddingBenchTests" "${swift_flags[@]}"

# Phase C3 (TDSC): SBP2 bucket-cap sensitivity study (64KiB/128KiB/256KiB)
export SKYBRIDGE_RUN_PADDING_SENS=1
export SKYBRIDGE_PADDING_SENS_ITERATIONS="${SKYBRIDGE_PADDING_SENS_ITERATIONS:-80}"
swift test --filter "${test_target}.TrafficPaddingSensitivityBenchTests" "${swift_flags[@]}"

python3 Scripts/make_tables.py
python3 Scripts/derive_audit_signal_fidelity.py
python3 Scripts/plot_handshake_latency.py
python3 Scripts/plot_policy_downgrade.py
python3 Scripts/plot_failure_histogram.py
python3 Scripts/generate_ieee_figures.py

printf "\nArtifacts written to %s/Artifacts\n" "$root_dir"
