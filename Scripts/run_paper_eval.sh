#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"

mkdir -p Artifacts

test_target="SkyBridgeCoreTests"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_anchor() {
  printf '[PAPER-EVAL][%s] %s\n' "$(timestamp)" "$*"
}

list_swiftpm_conflicts() {
  python3 - <<'PY'
import re
import subprocess

pattern = re.compile(
    r'(^|/)(swift-test|swift-build|swift-package)(\s|$)|\bswift\s+(test|build|package)\b',
    re.IGNORECASE,
)

output = subprocess.check_output(
    ["ps", "-ax", "-o", "pid=", "-o", "command="],
    text=True,
)

for raw in output.splitlines():
    line = raw.strip()
    if not line:
        continue
    parts = line.split(None, 1)
    if len(parts) < 2:
        continue
    pid, command = parts
    if pattern.search(command):
        print(f"{pid} {command}")
PY
}

wait_for_swiftpm_idle() {
  local timeout="${SKYBRIDGE_SWIFTPM_WAIT_SECONDS:-900}"
  local poll_seconds=5
  local start_epoch
  start_epoch="$(date +%s)"

  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [[ "$timeout" -lt 1 ]]; then
    echo "Invalid SKYBRIDGE_SWIFTPM_WAIT_SECONDS='${timeout}', expected integer >= 1" >&2
    exit 2
  fi

  while true; do
    local conflicts
    conflicts="$(list_swiftpm_conflicts || true)"
    if [[ -z "${conflicts}" ]]; then
      return 0
    fi

    local now_epoch elapsed
    now_epoch="$(date +%s)"
    elapsed=$(( now_epoch - start_epoch ))
    if (( elapsed >= timeout )); then
      echo "Timed out waiting for SwiftPM lock holders after ${elapsed}s (limit ${timeout}s)." >&2
      echo "Conflicting SwiftPM processes:" >&2
      echo "${conflicts}" >&2
      return 1
    fi

    log_anchor "SwiftPM busy (elapsed=${elapsed}s/${timeout}s); waiting..."
    echo "${conflicts}"
    sleep "${poll_seconds}"
  done
}

run_stage() {
  local stage_name="$1"
  local stage_mode="$2"
  shift 2

  local start_epoch
  start_epoch="$(date +%s)"
  log_anchor "STAGE_START ${stage_name}"

  if [[ "${stage_mode}" == "swift" ]] && [[ "${SKYBRIDGE_WAIT_FOR_SWIFTPM_IDLE:-1}" == "1" ]]; then
    wait_for_swiftpm_idle
  fi

  "$@"

  local end_epoch elapsed
  end_epoch="$(date +%s)"
  elapsed=$(( end_epoch - start_epoch ))
  log_anchor "STAGE_END ${stage_name} elapsed=${elapsed}s"
}

float_gt() {
  python3 - "$1" "$2" <<'PY'
import sys
left = float(sys.argv[1])
right = float(sys.argv[2])
print("1" if left > right else "0")
PY
}

current_load_ratio() {
  python3 - <<'PY'
import os

load_1m = os.getloadavg()[0]
cpus = os.cpu_count() or 1
ratio = load_1m / cpus
print(f"{ratio:.6f}")
PY
}

wait_for_bench_load_budget() {
  local max_ratio="$1"
  local timeout="$2"
  local poll_seconds=2
  local start_epoch
  start_epoch="$(date +%s)"

  while true; do
    local ratio
    ratio="$(current_load_ratio)"
    if [[ "$(float_gt "$ratio" "$max_ratio")" == "0" ]]; then
      log_anchor "Load guard passed: ratio=${ratio} <= ${max_ratio}"
      return 0
    fi

    local now_epoch elapsed
    now_epoch="$(date +%s)"
    elapsed=$(( now_epoch - start_epoch ))
    if (( elapsed >= timeout )); then
      echo "Load guard timeout after ${elapsed}s: ratio=${ratio} > ${max_ratio}" >&2
      return 1
    fi

    log_anchor "Load guard waiting: ratio=${ratio} > ${max_ratio} (${elapsed}s/${timeout}s)"
    sleep "${poll_seconds}"
  done
}

cooldown_between_batches() {
  local cooldown_seconds="$1"
  local reason="$2"
  if [[ "${cooldown_seconds}" -gt 0 ]]; then
    log_anchor "Batch cooldown ${cooldown_seconds}s (${reason})"
    sleep "${cooldown_seconds}"
  fi
}

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
  log_anchor "Apple PQC SDK detected: enabling -DHAS_APPLE_PQC_SDK for SwiftPM runs"
else
  log_anchor "Apple PQC SDK NOT detected: benches will run without -DHAS_APPLE_PQC_SDK"
fi

export SKYBRIDGE_RUN_BENCH=1
# Paper evaluation should avoid touching the system Keychain to prevent
# macOS interactive unlock prompts and reduce benchmark variance.
# Tests already default to in-memory mode; release-mode runners need this.
export SKYBRIDGE_KEYCHAIN_IN_MEMORY="${SKYBRIDGE_KEYCHAIN_IN_MEMORY:-1}"
bench_batches="${SKYBRIDGE_BENCH_BATCHES:-3}"
bench_max_batches="${SKYBRIDGE_BENCH_MAX_BATCHES:-5}"
bench_stability_threshold="${SKYBRIDGE_BENCH_STABILITY_THRESHOLD:-0.07}"
bench_stability_require_apple="${SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE:-0}"
bench_scope="${SKYBRIDGE_BENCH_SCOPE:-core}"
bench_apple_iterations="${SKYBRIDGE_BENCH_APPLE_ITERATIONS:-5000}"
bench_cooldown_seconds="${SKYBRIDGE_BENCH_COOLDOWN_SECONDS:-5}"
bench_max_load_ratio="${SKYBRIDGE_BENCH_MAX_LOAD_RATIO:-0.70}"
bench_load_wait_seconds="${SKYBRIDGE_BENCH_LOAD_WAIT_SECONDS:-120}"
export SKYBRIDGE_BENCH_DETERMINISTIC_TRANSPORT="${SKYBRIDGE_BENCH_DETERMINISTIC_TRANSPORT:-1}"
export SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING="${SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING:-1}"
export SKYBRIDGE_BENCH_DETERMINISTIC_NONCE="${SKYBRIDGE_BENCH_DETERMINISTIC_NONCE:-1}"
artifact_date_for_checks="${ARTIFACT_DATE:-$(date +%Y-%m-%d)}"

if ! [[ "${bench_batches}" =~ ^[0-9]+$ ]] || [[ "${bench_batches}" -lt 1 ]]; then
  echo "Invalid SKYBRIDGE_BENCH_BATCHES='${bench_batches}', expected integer >= 1" >&2
  exit 2
fi
if ! [[ "${bench_max_batches}" =~ ^[0-9]+$ ]] || [[ "${bench_max_batches}" -lt "${bench_batches}" ]]; then
  echo "Invalid SKYBRIDGE_BENCH_MAX_BATCHES='${bench_max_batches}', expected integer >= SKYBRIDGE_BENCH_BATCHES (${bench_batches})" >&2
  exit 2
fi
if ! [[ "${bench_stability_threshold}" =~ ^0\.[0-9]+$|^1(\.0+)?$ ]]; then
  echo "Invalid SKYBRIDGE_BENCH_STABILITY_THRESHOLD='${bench_stability_threshold}', expected float in (0, 1]" >&2
  exit 2
fi
if [[ "${bench_stability_require_apple}" != "0" && "${bench_stability_require_apple}" != "1" ]]; then
  echo "Invalid SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE='${bench_stability_require_apple}', expected 0 or 1" >&2
  exit 2
fi
if ! [[ "${bench_apple_iterations}" =~ ^[0-9]+$ ]] || [[ "${bench_apple_iterations}" -lt 1 ]]; then
  echo "Invalid SKYBRIDGE_BENCH_APPLE_ITERATIONS='${bench_apple_iterations}', expected integer >= 1" >&2
  exit 2
fi
if [[ "${bench_scope}" != "core" && "${bench_scope}" != "full" ]]; then
  echo "Invalid SKYBRIDGE_BENCH_SCOPE='${bench_scope}', expected 'core' or 'full'" >&2
  exit 2
fi
if ! [[ "${bench_cooldown_seconds}" =~ ^[0-9]+$ ]]; then
  echo "Invalid SKYBRIDGE_BENCH_COOLDOWN_SECONDS='${bench_cooldown_seconds}', expected integer >= 0" >&2
  exit 2
fi
if ! [[ "${bench_load_wait_seconds}" =~ ^[0-9]+$ ]] || [[ "${bench_load_wait_seconds}" -lt 1 ]]; then
  echo "Invalid SKYBRIDGE_BENCH_LOAD_WAIT_SECONDS='${bench_load_wait_seconds}', expected integer >= 1" >&2
  exit 2
fi
if [[ "${SKYBRIDGE_BENCH_DETERMINISTIC_TRANSPORT}" != "0" && "${SKYBRIDGE_BENCH_DETERMINISTIC_TRANSPORT}" != "1" ]]; then
  echo "Invalid SKYBRIDGE_BENCH_DETERMINISTIC_TRANSPORT='${SKYBRIDGE_BENCH_DETERMINISTIC_TRANSPORT}', expected 0 or 1" >&2
  exit 2
fi
if [[ "${SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING}" != "0" && "${SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING}" != "1" ]]; then
  echo "Invalid SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING='${SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING}', expected 0 or 1" >&2
  exit 2
fi
if [[ "${SKYBRIDGE_BENCH_DETERMINISTIC_NONCE}" != "0" && "${SKYBRIDGE_BENCH_DETERMINISTIC_NONCE}" != "1" ]]; then
  echo "Invalid SKYBRIDGE_BENCH_DETERMINISTIC_NONCE='${SKYBRIDGE_BENCH_DETERMINISTIC_NONCE}', expected 0 or 1" >&2
  exit 2
fi
if ! python3 - "${bench_max_load_ratio}" <<'PY'
import sys
value = float(sys.argv[1])
if value <= 0:
    raise SystemExit(1)
PY
then
  echo "Invalid SKYBRIDGE_BENCH_MAX_LOAD_RATIO='${bench_max_load_ratio}', expected float > 0" >&2
  exit 2
fi

core_bench_regex="${test_target}\\.HandshakeBenchmarkTests/(testHandshakeLatency_Classic|testHandshakeRTT_Classic|testHandshakeLatency_LiboqsPQC|testHandshakeRTT_LiboqsPQC|testHandshakeLatency_LiboqsPQCv2FS|testHandshakeRTT_LiboqsPQCv2FS|testHandshakeLatency_ApplePQC|testHandshakeRTT_ApplePQC)$"
run_bench_filter="${test_target}.HandshakeBenchmarkTests"
if [[ "${bench_scope}" == "core" ]]; then
  run_bench_filter="${core_bench_regex}"
fi

export SKYBRIDGE_BENCH_APPLE_ITERATIONS="${bench_apple_iterations}"
log_anchor "Run configuration: ARTIFACT_DATE=${ARTIFACT_DATE:-unset}, SKYBRIDGE_BENCH_SCOPE=${bench_scope}, SKYBRIDGE_BENCH_BATCHES=${bench_batches}, SKYBRIDGE_BENCH_MAX_BATCHES=${bench_max_batches}, SKYBRIDGE_BENCH_STABILITY_THRESHOLD=${bench_stability_threshold}, SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE=${bench_stability_require_apple}, SKYBRIDGE_BENCH_APPLE_ITERATIONS=${bench_apple_iterations}, SKYBRIDGE_BENCH_COOLDOWN_SECONDS=${bench_cooldown_seconds}, SKYBRIDGE_BENCH_MAX_LOAD_RATIO=${bench_max_load_ratio}, SKYBRIDGE_BENCH_LOAD_WAIT_SECONDS=${bench_load_wait_seconds}, SKYBRIDGE_BENCH_DETERMINISTIC_TRANSPORT=${SKYBRIDGE_BENCH_DETERMINISTIC_TRANSPORT}, SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING=${SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING}, SKYBRIDGE_BENCH_DETERMINISTIC_NONCE=${SKYBRIDGE_BENCH_DETERMINISTIC_NONCE}, SKYBRIDGE_FI_ITERATIONS=${SKYBRIDGE_FI_ITERATIONS:-1000}, SKYBRIDGE_POLICY_ITERATIONS=${SKYBRIDGE_POLICY_ITERATIONS:-1000}, SKYBRIDGE_MIGRATION_ITERATIONS=${SKYBRIDGE_MIGRATION_ITERATIONS:-1000}, SKYBRIDGE_SOA_ITERATIONS=${SKYBRIDGE_SOA_ITERATIONS:-100}"

# Handshake benchmark stability is very sensitive to debug/test harness jitter on macOS.
# For paper evaluation we prefer a dedicated release-mode runner binary.
run_stage "handshake-bench-runner-build" swift \
  swift build -c release --product HandshakeBenchRunner "${swift_flags[@]}"
handshake_bench_bin_dir="$(swift build -c release --show-bin-path "${swift_flags[@]}")"
handshake_bench_runner="${handshake_bench_bin_dir}/HandshakeBenchRunner"
if [[ ! -x "${handshake_bench_runner}" ]]; then
  echo "HandshakeBenchRunner not found after build: ${handshake_bench_runner}" >&2
  exit 1
fi

run_handshake_bench_batch() {
  local batch_index="$1"
  local batch_total="$2"
  local stage_label_scope
  stage_label_scope="${bench_scope}"

  wait_for_bench_load_budget "${bench_max_load_ratio}" "${bench_load_wait_seconds}"
  run_stage "handshake-bench-${stage_label_scope}-batch-${batch_index}-of-${batch_total}" none \
    "${handshake_bench_runner}"
  cooldown_between_batches "${bench_cooldown_seconds}" "after handshake bench batch ${batch_index}"
}

executed_bench_batches=0
for ((i=1; i<=bench_batches; i++)); do
  run_handshake_bench_batch "${i}" "${bench_batches}"
  executed_bench_batches="${i}"
done

if [[ -f "Scripts/check_bench_stability_window.py" ]]; then
  stability_report="Artifacts/bench_stability_window_${artifact_date_for_checks}.json"
  while true; do
    run_stage "handshake-bench-stability-check-after-${executed_bench_batches}" none \
      bash -c '
        set +e
        python3 "$1" \
          --artifact-date "$2" \
          --threshold "$3" \
          --min-batches "$4" \
          --require-apple "$5" \
          --output "$6"
        rc=$?
        set -e
        if [[ "$rc" -eq 10 ]]; then
          exit 0
        fi
        exit "$rc"
      ' _ \
      "Scripts/check_bench_stability_window.py" \
      "${artifact_date_for_checks}" \
      "${bench_stability_threshold}" \
      "${bench_batches}" \
      "${bench_stability_require_apple}" \
      "${stability_report}"

    stability_top_metric="$(
      python3 - "$stability_report" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print("")
    raise SystemExit(0)
data = json.loads(path.read_text(encoding="utf-8"))
items = data.get("top_unstable_metrics", [])
if not items:
    print("")
    raise SystemExit(0)
top = items[0]
pct = top.get("max_relative_deviation_pct")
if pct is None:
    print(f"{top.get('metric')} {top.get('configuration')} deviation=unknown")
else:
    print(f"{top.get('metric')} {top.get('configuration')} deviation={float(pct):.2f}%")
PY
    )"
    if [[ -n "${stability_top_metric}" ]]; then
      log_anchor "Stability diagnostic: ${stability_top_metric}"
    fi

    stable_state="$(
      python3 - "$stability_report" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print("false")
    raise SystemExit(0)
data = json.loads(path.read_text(encoding="utf-8"))
print("true" if data.get("overall_stable") else "false")
PY
    )"

    if [[ "${stable_state}" == "true" ]]; then
      break
    fi

    if (( executed_bench_batches >= bench_max_batches )); then
      echo "Benchmark stability window did not converge after ${executed_bench_batches} batches (max ${bench_max_batches})." >&2
      echo "See ${stability_report} for per-metric deviation details." >&2
      exit 1
    fi

    next_batch=$(( executed_bench_batches + 1 ))
    run_handshake_bench_batch "${next_batch}" "${bench_max_batches}"
    executed_bench_batches="${next_batch}"
  done
fi

export SKYBRIDGE_RUN_FI=1
export SKYBRIDGE_FI_ITERATIONS=1000
export SKYBRIDGE_FI_PROGRESS_INTERVAL="${SKYBRIDGE_FI_PROGRESS_INTERVAL:-100}"
run_stage "fault-injection-bench" swift \
  swift test --filter "${test_target}.HandshakeFaultInjectionBenchTests" "${swift_flags[@]}"

export SKYBRIDGE_RUN_POLICY_BENCH=1
export SKYBRIDGE_POLICY_ITERATIONS=1000
run_stage "policy-downgrade-bench" swift \
  swift test --filter "${test_target}.PolicyDowngradeBenchTests" "${swift_flags[@]}"

export SKYBRIDGE_RUN_MIGRATION_BENCH=1
export SKYBRIDGE_MIGRATION_ITERATIONS=1000
run_stage "migration-coverage-bench" swift \
  swift test --filter "${test_target}.MigrationCoverageBenchTests" "${swift_flags[@]}"

export SKYBRIDGE_RUN_SOA_BENCH=1
export SKYBRIDGE_SOA_ITERATIONS="${SKYBRIDGE_SOA_ITERATIONS:-100}"
run_stage "soa-interop-bench" swift \
  swift test --filter "${test_target}.SOAInteroperabilityBenchTests" "${swift_flags[@]}"

run_stage "message-size-snapshot-tests" swift \
  swift test --filter "${test_target}.MessageSizeSnapshotTests" "${swift_flags[@]}"

run_stage "message-size-bench-build" swift \
  swift build --product MessageSizeBenchRunner "${swift_flags[@]}"
run_stage "message-size-bench-run" none \
  ./.build/debug/MessageSizeBenchRunner

# Phase C3 (TDSC): TrafficPadding quantization + telemetry artifacts
export SKYBRIDGE_RUN_PADDING_BENCH=1
export SKYBRIDGE_PADDING_ITERATIONS="${SKYBRIDGE_PADDING_ITERATIONS:-2000}"
run_stage "traffic-padding-bench" swift \
  swift test --filter "${test_target}.TrafficPaddingBenchTests" "${swift_flags[@]}"

# Phase C3 (TDSC): SBP2 bucket-cap sensitivity study (64KiB/128KiB/256KiB)
export SKYBRIDGE_RUN_PADDING_SENS=1
export SKYBRIDGE_PADDING_SENS_ITERATIONS="${SKYBRIDGE_PADDING_SENS_ITERATIONS:-80}"
run_stage "traffic-padding-sensitivity-bench" swift \
  swift test --filter "${test_target}.TrafficPaddingSensitivityBenchTests" "${swift_flags[@]}"

if [[ "${RUN_IOS_MICROBENCH_IMPORT:-0}" == "1" ]]; then
  run_stage "ios-microbench-import" none \
    python3 Scripts/aggregate_ios_microbench.py
fi

if [[ "${RUN_KERNEL_EMULATION:-0}" == "1" ]]; then
  run_stage "kernel-emulation-run" none \
    bash Scripts/run_network_emulation_kernel.sh
  run_stage "kernel-emulation-aggregate" none \
    python3 Scripts/aggregate_kernel_emulation.py
fi

if [[ "${SKYBRIDGE_SKIP_POSTPROCESS:-0}" != "1" ]]; then
  if [[ -x Scripts/collect_claims.py ]]; then
    run_stage "collect-claims" none python3 Scripts/collect_claims.py
  fi
  run_stage "tables-generate" none python3 Scripts/make_tables.py
  run_stage "audit-fidelity-derive" none python3 Scripts/derive_audit_signal_fidelity.py
  run_stage "plot-handshake-latency" none python3 Scripts/plot_handshake_latency.py
  run_stage "plot-policy-downgrade" none python3 Scripts/plot_policy_downgrade.py
  run_stage "plot-failure-histogram" none python3 Scripts/plot_failure_histogram.py
  run_stage "ieee-figures-generate" none python3 Scripts/generate_ieee_figures.py

  if [[ -x Scripts/check_paper_consistency.sh ]]; then
    run_stage "paper-consistency-check" none bash Scripts/check_paper_consistency.sh
  fi
  if [[ -x Scripts/check_numeric_consistency.py ]]; then
    run_stage "numeric-consistency-check" none python3 Scripts/check_numeric_consistency.py
  fi
fi

log_anchor "Artifacts written to ${root_dir}/Artifacts"
