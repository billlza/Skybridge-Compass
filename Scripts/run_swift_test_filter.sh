#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 || -z "${1:-}" ]]; then
  echo "Usage: run_swift_test_filter.sh <filter> [swift-test-options...]" >&2
  exit 2
fi

FILTER="$1"
shift
LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/skybridge-swift-test-filter.XXXXXX")"
SWIFT_EXECUTABLE="${SKYBRIDGE_SWIFT_EXECUTABLE:-swift}"
if [[ ! -x "${SWIFT_EXECUTABLE}" ]] && ! command -v "${SWIFT_EXECUTABLE}" >/dev/null 2>&1; then
  echo "Swift executable is unavailable: ${SWIFT_EXECUTABLE}" >&2
  exit 2
fi

cleanup() {
  rm -f "${LOG_FILE}"
}
trap cleanup EXIT

set +e
"${SWIFT_EXECUTABLE}" test --filter "${FILTER}" "$@" 2>&1 | tee "${LOG_FILE}"
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
