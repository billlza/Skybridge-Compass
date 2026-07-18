#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GATE_NAME="gate_common_selftest"
export GATE_DOMAIN="source-quality"

cd "${ROOT_DIR}"
source Scripts/gates/_gate_common.sh

FIXTURE_PATH="$(mktemp "${TMPDIR:-/tmp}/skybridge-gate-patterns.XXXXXX")"
MISSING_PATH="${FIXTURE_PATH}.missing"

cleanup_test_files() {
  rm -f "${FIXTURE_PATH}"
  cleanup_gate_tmp
}
trap cleanup_test_files EXIT

cat >"${FIXTURE_PATH}" <<'EOF'
lower warning: probe
upper WARNING: probe
lower error: probe
upper ERROR: probe
prewarning: must not match
preERROR: must not match
EOF

warning_hits="$(count_pattern_hits '(^|[^[:alpha:]])(warning:|WARNING:)' "${FIXTURE_PATH}")"
error_hits="$(count_pattern_hits '(^|[^[:alpha:]])(error:|ERROR:)' "${FIXTURE_PATH}")"
[[ "${warning_hits}" == "2" ]] || {
  echo "expected two case-complete warning markers, got ${warning_hits}" >&2
  exit 1
}
[[ "${error_hits}" == "2" ]] || {
  echo "expected two case-complete error markers, got ${error_hits}" >&2
  exit 1
}

no_hits="$(count_pattern_hits 'marker-that-is-not-present' "${FIXTURE_PATH}")"
[[ "${no_hits}" == "0" ]] || {
  echo "expected zero pattern hits, got ${no_hits}" >&2
  exit 1
}

scan_output=""
scan_status=0
if scan_output="$(count_pattern_hits 'warning:' "${MISSING_PATH}" 2>&1)"; then
  scan_status=0
else
  scan_status=$?
fi
[[ "${scan_status}" -gt 1 ]] || {
  echo "missing gate log must fail the scanner, status=${scan_status}" >&2
  exit 1
}
[[ "${scan_output}" == *"gate log scan failed"* ]] || {
  echo "gate scan failure did not retain diagnostic context" >&2
  exit 1
}

run_check_strict_no_warnings \
  "uppercase-probe" \
  "test" \
  "source-quality" \
  bash -c 'printf "WARNING: synthetic gate marker\n"'

IFS=$'\t' read -r \
  check_id check_domain owner_hint status exit_code warning_count error_count \
  log_path started_at ended_at message \
  <"${CHECK_ROWS_FILE}"
[[ "${check_id}" == "uppercase-probe" && "${status}" == "fail" ]] || {
  echo "strict gate did not reject the uppercase marker" >&2
  exit 1
}
[[ "${warning_count}" == "1" && "${error_count}" == "0" && "${exit_code}" == "0" ]] || {
  echo "strict gate recorded unexpected marker counts" >&2
  exit 1
}

echo "[test-gate-common] passed"
