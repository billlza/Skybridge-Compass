#!/usr/bin/env bash
set -euo pipefail

REQUIRE_NO_SKIPS=0
if [[ "${1:-}" == "--require-no-skips" ]]; then
  REQUIRE_NO_SKIPS=1
  shift
fi

if [[ "$#" -lt 1 || -z "${1:-}" ]]; then
  echo "Usage: run_swift_test_filter.sh [--require-no-skips] <filter> [swift-test-options...]" >&2
  exit 2
fi

FILTER="$1"
shift
LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/skybridge-swift-test-filter.XXXXXX")"

cleanup() {
  rm -f "${LOG_FILE}"
}
trap cleanup EXIT

set +e
swift test --filter "${FILTER}" "$@" 2>&1 | tee "${LOG_FILE}"
SWIFT_TEST_STATUS="${PIPESTATUS[0]}"
set -e

if [[ "${SWIFT_TEST_STATUS}" -ne 0 ]]; then
  exit "${SWIFT_TEST_STATUS}"
fi

# SwiftPM can exit successfully when a stale filter selects no tests. Accept
# either XCTest or Swift Testing output, but require a strictly positive count.
if ! grep -Eq 'Executed[[:space:]]+[1-9][0-9]*[[:space:]]+tests?|Test run with[[:space:]]+[1-9][0-9]*[[:space:]]+tests?' "${LOG_FILE}"; then
  echo "swift test filter '${FILTER}' completed without positive test-execution evidence" >&2
  exit 3
fi

# Opt-in lanes that promise runtime execution must also reject an all-skipped
# result. The default remains skip-tolerant because the full cross-platform
# suite contains legitimate availability- and environment-gated tests.
if [[ "${REQUIRE_NO_SKIPS}" == "1" ]] && grep -Eq \
  'Test Case .* skipped|Test skipped -|[➜↳][[:space:]]+Test .* skipped:|with[[:space:]]+[1-9][0-9]*[[:space:]]+tests?[[:space:]]+skipped' \
  "${LOG_FILE}"; then
  echo "swift test filter '${FILTER}' contained skipped tests in a no-skips lane" >&2
  exit 4
fi
