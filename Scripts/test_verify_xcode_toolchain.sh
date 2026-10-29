#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_SCRIPT="${ROOT_DIR}/Scripts/verify_xcode_toolchain.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-xcode-toolchain-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

mkdir -p "${TMP_DIR}/bin" "${TMP_DIR}/Xcode.app/Contents/Developer" "${TMP_DIR}/Xcode-beta.app/Contents/Developer"

cat >"${TMP_DIR}/bin/xcode-select" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-p" ]]; then
  printf '%s\n' "${DEVELOPER_DIR:-${STUB_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}}"
  exit 0
fi
exit 64
SH

cat >"${TMP_DIR}/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-version" ]]; then
  printf 'Xcode %s\nBuild version %s\n' "${STUB_XCODE_VERSION:-26.6}" "${STUB_XCODE_BUILD:-17F113}"
  exit 0
fi
exit 64
SH

cat >"${TMP_DIR}/bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "swift" && "${2:-}" == "--version" ]]; then
  printf 'Apple Swift version %s (swiftlang-test clang-test)\n' "${STUB_SWIFT_VERSION:-6.3.3}"
  exit 0
fi
if [[ "${1:-}" == "--sdk" && "${2:-}" == "macosx" && "${3:-}" == "--show-sdk-version" ]]; then
  printf '%s\n' "${STUB_MACOS_SDK_VERSION:-26.5}"
  exit 0
fi
exit 64
SH

chmod +x "${TMP_DIR}/bin/xcode-select" "${TMP_DIR}/bin/xcodebuild" "${TMP_DIR}/bin/xcrun"

run_verify() {
  PATH="${TMP_DIR}/bin:${PATH}" "$@" bash "${VERIFY_SCRIPT}"
}

expect_failure_contains() {
  local description="$1"
  local expected_fragment="$2"
  shift 2

  local output=""
  local status=0
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    echo "${description}: expected failure but command succeeded" >&2
    exit 1
  fi
  if [[ "${output}" != *"${expected_fragment}"* ]]; then
    printf '%s\n' "${output}" >&2
    echo "${description}: expected output to contain '${expected_fragment}'" >&2
    exit 1
  fi
}

run_verify env DEVELOPER_DIR="${TMP_DIR}/Xcode.app/Contents/Developer" >/dev/null

expect_failure_contains \
  "stable release rejects Xcode 27" \
  "expected Xcode 26.6" \
  run_verify env \
    DEVELOPER_DIR="${TMP_DIR}/Xcode.app/Contents/Developer" \
    STUB_XCODE_VERSION=27.0 \
    STUB_XCODE_BUILD=18A123 \
    STUB_SWIFT_VERSION=7.0 \
    STUB_MACOS_SDK_VERSION=27.0

expect_failure_contains \
  "stable release rejects beta developer dir" \
  "stable release toolchain must not use beta Xcode developer directory" \
  run_verify env DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer"

run_verify env \
  SKYBRIDGE_XCODE_TOOLCHAIN_POLICY=custom-diagnostic \
  SKYBRIDGE_REQUIRED_XCODE_VERSION=27.0 \
  SKYBRIDGE_REQUIRED_XCODE_BUILD=18A123 \
  SKYBRIDGE_REQUIRED_APPLE_SWIFT_VERSION=7.0 \
  SKYBRIDGE_REQUIRED_MACOS_SDK_VERSION=27.0 \
  SKYBRIDGE_ALLOW_BETA_XCODE_TOOLCHAIN=1 \
  DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer" \
  STUB_XCODE_VERSION=27.0 \
  STUB_XCODE_BUILD=18A123 \
  STUB_SWIFT_VERSION=7.0 \
  STUB_MACOS_SDK_VERSION=27.0 >/dev/null

# OS 27 release line accepts Xcode 27.x against the 27 SDK from a beta dir.
run_verify env \
  SKYBRIDGE_XCODE_TOOLCHAIN_POLICY=os27-release \
  DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer" \
  STUB_XCODE_VERSION=27.0 \
  STUB_XCODE_BUILD=27A5194q \
  STUB_SWIFT_VERSION=6.4 \
  STUB_MACOS_SDK_VERSION=27.0 >/dev/null

# 27.x point release passes without re-pinning the build id / SDK point version.
run_verify env \
  SKYBRIDGE_XCODE_TOOLCHAIN_POLICY=os27-release \
  DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer" \
  STUB_XCODE_VERSION=27.3 \
  STUB_XCODE_BUILD=27C5031e \
  STUB_SWIFT_VERSION=6.5 \
  STUB_MACOS_SDK_VERSION=27.2 >/dev/null

# OS 27 line still rejects a 26.x toolchain (wrong major).
expect_failure_contains \
  "os27-release rejects Xcode 26" \
  "expected Xcode 27" \
  run_verify env \
    SKYBRIDGE_XCODE_TOOLCHAIN_POLICY=os27-release \
    DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer" \
    STUB_XCODE_VERSION=26.6 \
    STUB_XCODE_BUILD=17F113 \
    STUB_SWIFT_VERSION=6.3.3 \
    STUB_MACOS_SDK_VERSION=26.5

echo "[test-xcode-toolchain] passed"
