#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 <build-for-testing-log> <test-without-building-log>" >&2
  exit 2
fi

BUILD_LOG="$1"
TEST_LOG="$2"
ALLOWED_IOSURFACE_DIAGNOSTIC="IOSurfaceClientSetSurfaceNotify failed e00002c7"
TEST_SUITE_START="Test Suite 'All tests' started"

for log_file in "${BUILD_LOG}" "${TEST_LOG}"; do
  if [[ ! -f "${log_file}" ]]; then
    echo "[iOS simulator diagnostics] missing log: ${log_file}" >&2
    exit 2
  fi
done

if grep -Ein "IOSurface.*(warning|error|failed)" "${BUILD_LOG}" >&2; then
  echo "[iOS simulator diagnostics] IOSurface diagnostics are not allowed during build-for-testing" >&2
  exit 1
fi

iosurface_count="$(grep -Fc "IOSurface" "${TEST_LOG}" || true)"
allowed_count="$(grep -Fxc "${ALLOWED_IOSURFACE_DIAGNOSTIC}" "${TEST_LOG}" || true)"

if [[ "${iosurface_count}" -ne "${allowed_count}" ]]; then
  grep -Fn "IOSurface" "${TEST_LOG}" >&2 || true
  echo "[iOS simulator diagnostics] unknown IOSurface diagnostic detected" >&2
  exit 1
fi

if [[ "${allowed_count}" -gt 1 ]]; then
  grep -Fn "${ALLOWED_IOSURFACE_DIAGNOSTIC}" "${TEST_LOG}" >&2 || true
  echo "[iOS simulator diagnostics] allowed CoreSimulator diagnostic repeated ${allowed_count} times" >&2
  exit 1
fi

if [[ "${allowed_count}" -eq 1 ]]; then
  diagnostic_line="$(grep -Fn "${ALLOWED_IOSURFACE_DIAGNOSTIC}" "${TEST_LOG}" | head -n 1 | cut -d: -f1)"
  suite_line="$(grep -Fn "${TEST_SUITE_START}" "${TEST_LOG}" | head -n 1 | cut -d: -f1 || true)"
  if [[ -z "${suite_line}" || "${diagnostic_line}" -ge "${suite_line}" ]]; then
    echo "[iOS simulator diagnostics] IOSurface diagnostic was not confined to pre-test CoreSimulator startup" >&2
    exit 1
  fi
  echo "[iOS simulator diagnostics] classified one pre-test CoreSimulator-only diagnostic: ${ALLOWED_IOSURFACE_DIAGNOSTIC}"
else
  echo "[iOS simulator diagnostics] no IOSurface diagnostics observed"
fi
