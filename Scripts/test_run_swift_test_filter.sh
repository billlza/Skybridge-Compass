#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${ROOT_DIR}/Scripts/run_swift_test_filter.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-swift-filter-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

FAKE_BIN="${TMP_DIR}/bin"
mkdir -p "${FAKE_BIN}"

write_fake_swift() {
  local mode="$1"
  python3 - "${FAKE_BIN}/swift" "${mode}" <<'PY'
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
outputs = {
    "xctest-pass": ("Test Suite 'Selected tests' passed\nExecuted 2 tests, with 0 failures\n", 0),
    "swift-testing-pass": ("Test run with 1 test passed after 0.001 seconds.\n", 0),
    "xctest-skip": (
        "Test Case '-[ExampleTests testOptIn]' skipped (0.001 seconds).\n"
        "Executed 1 test, with 1 test skipped and 0 failures\n",
        0,
    ),
    "swift-testing-skip": (
        "➜ Test \"opt-in\" skipped: \"required environment is unavailable\"\n"
        "Test run with 1 test in 1 suite passed after 0.001 seconds.\n",
        0,
    ),
    "zero": ("Test run with 0 tests in 0 suites passed after 0.001 seconds.\n", 0),
    "failure": ("error: test process failed\n", 7),
}
output, status = outputs[mode]
path.write_text(
    "#!/usr/bin/env bash\n"
    + "printf '%b' " + repr(output) + "\n"
    + f"exit {status}\n",
    encoding="utf-8",
)
os.chmod(path, 0o755)
PY
}

expect_status() {
  local expected="$1"
  shift
  local actual=0
  set +e
  PATH="${FAKE_BIN}:${PATH}" "$@" >/dev/null 2>&1
  actual=$?
  set -e
  if [[ "${actual}" -ne "${expected}" ]]; then
    echo "expected status ${expected}, got ${actual}: $*" >&2
    exit 1
  fi
}

write_fake_swift xctest-pass
expect_status 0 bash "${TARGET}" ExampleTests

write_fake_swift swift-testing-pass
expect_status 0 bash "${TARGET}" ExampleTests
expect_status 0 bash "${TARGET}" --require-no-skips ExampleTests

# Default full-suite semantics remain skip-tolerant.
write_fake_swift xctest-skip
expect_status 0 bash "${TARGET}" ExampleTests
expect_status 4 bash "${TARGET}" --require-no-skips ExampleTests

write_fake_swift swift-testing-skip
expect_status 0 bash "${TARGET}" ExampleTests
expect_status 4 bash "${TARGET}" --require-no-skips ExampleTests

write_fake_swift zero
expect_status 3 bash "${TARGET}" StaleFilter
expect_status 3 bash "${TARGET}" --require-no-skips StaleFilter

write_fake_swift failure
expect_status 7 bash "${TARGET}" BrokenTests
expect_status 7 bash "${TARGET}" --require-no-skips BrokenTests

expect_status 2 bash "${TARGET}" --require-no-skips

echo "[test-run-swift-test-filter] passed"
