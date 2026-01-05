#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"

mkdir -p Artifacts

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

export SKYBRIDGE_RUN_BENCH=1
swift test --filter HandshakeBenchmarkTests "${swift_flags[@]}"

export SKYBRIDGE_RUN_FI=1
export SKYBRIDGE_FI_ITERATIONS=1000
swift test --filter HandshakeFaultInjectionBenchTests "${swift_flags[@]}"

export SKYBRIDGE_RUN_POLICY_BENCH=1
export SKYBRIDGE_POLICY_ITERATIONS=1000
swift test --filter PolicyDowngradeBenchTests "${swift_flags[@]}"

export SKYBRIDGE_RUN_MIGRATION_BENCH=1
export SKYBRIDGE_MIGRATION_ITERATIONS=1000
swift test --filter MigrationCoverageBenchTests "${swift_flags[@]}"

swift test --filter MessageSizeSnapshotTests "${swift_flags[@]}"

python3 Scripts/derive_audit_signal_fidelity.py
python3 Scripts/plot_handshake_latency.py
python3 Scripts/plot_policy_downgrade.py
python3 Scripts/plot_failure_histogram.py

printf "\nArtifacts written to %s/Artifacts\n" "$root_dir"
