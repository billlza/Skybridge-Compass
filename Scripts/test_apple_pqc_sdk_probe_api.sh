#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-pqc-probe-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

FAKE_BIN="${TMP_DIR}/bin"
FAKE_LOG="${TMP_DIR}/xcrun.log"
mkdir -p "${FAKE_BIN}"

cat > "${FAKE_BIN}/sw_vers" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-productVersion" ]]; then
  printf '27.0\n'
  exit 0
fi
exit 1
EOF

cat > "${FAKE_BIN}/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log="${SKYBRIDGE_FAKE_XCRUN_LOG:?}"

if [[ "${1:-}" != "--sdk" ]]; then
  echo "expected --sdk" >&2
  exit 2
fi

sdk="${2:-}"
action="${3:-}"

case "${action}" in
  --show-sdk-path)
    if [[ "${SKYBRIDGE_FAKE_XCRUN_NO_SDK:-}" == "${sdk}" ]]; then
      exit 1
    fi
    printf '/FakeSDKs/%s.sdk\n' "${sdk}"
    ;;
  --show-sdk-version)
    printf '%s\n' "${SKYBRIDGE_FAKE_SDK_VERSION:-27.0}"
    ;;
  swiftc)
    shift 3
    printf 'sdk=%s args=%s\n' "${sdk}" "$*" >> "${log}"
    if [[ "${SKYBRIDGE_FAKE_SWIFTC_FAIL:-}" == "1" || "${SKYBRIDGE_FAKE_SWIFTC_FAIL:-}" == "${sdk}" ]]; then
      echo "fake typecheck failure for ${sdk}" >&2
      exit 1
    fi
    ;;
  *)
    echo "unsupported fake xcrun action: ${action}" >&2
    exit 2
    ;;
esac
EOF

chmod +x "${FAKE_BIN}/sw_vers" "${FAKE_BIN}/xcrun"

export PATH="${FAKE_BIN}:${PATH}"
export SKYBRIDGE_FAKE_XCRUN_LOG="${FAKE_LOG}"

# shellcheck source=Scripts/apple_pqc_sdk_probe.sh
source "${ROOT_DIR}/Scripts/apple_pqc_sdk_probe.sh"

fail() {
  echo "[test-apple-pqc-sdk-probe] $1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${label}: expected '${expected}', got '${actual}'"
}

assert_log_contains() {
  local needle="$1"
  if ! grep -F -- "${needle}" "${FAKE_LOG}" >/dev/null; then
    sed -n '1,120p' "${FAKE_LOG}" >&2 || true
    fail "expected fake xcrun log to contain: ${needle}"
  fi
}

assert_log_not_contains() {
  local needle="$1"
  if grep -F -- "${needle}" "${FAKE_LOG}" >/dev/null; then
    sed -n '1,120p' "${FAKE_LOG}" >&2 || true
    fail "expected fake xcrun log not to contain: ${needle}"
  fi
}

host_arch="$(uname -m)"

sanitized_probe_error="$(skybridge_sanitize_pqc_probe_log_value "${TMP_DIR}/probe.swift:1:1: error: private path leaked")"
[[ "${sanitized_probe_error}" == "<tmp> error: private path leaked" ]] \
  || fail "PQC probe sanitizer should preserve the diagnostic while redacting the local path"
[[ "${sanitized_probe_error}" != *"${TMP_DIR}"* ]] \
  || fail "PQC probe sanitizer must not leak the raw temp directory"

: > "${FAKE_LOG}"
skybridge_detect_apple_pqc_sdk
assert_eq "${SKYBRIDGE_PQC_SDK_NAME}" "macosx" "default SDK"
assert_eq "${SKYBRIDGE_PQC_SDK_AVAILABLE}" "1" "default macOS availability"
assert_eq "${SKYBRIDGE_PQC_PROBE_MODE}" "symbol_probe" "default macOS mode"
skybridge_apple_pqc_sdk_probe_succeeded \
  || fail "successful default macOS probe should satisfy the strict success predicate"
skybridge_require_apple_pqc_sdk_symbol_probe macosx \
  || fail "strict macOS helper should accept the fake symbol probe success"
export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=stale
skybridge_configure_optional_apple_pqc_sdk_compile_gate macosx
assert_eq "${SKYBRIDGE_ENABLE_APPLE_PQC_SDK}" "1" "optional macOS compile gate"
assert_eq "${SKYBRIDGE_PQC_INCLUDED_SECURE_ENCLAVE}" "1" "macOS Secure Enclave probe flag"
assert_log_contains "sdk=macosx"
assert_log_contains "-target ${host_arch}-apple-macosx26.0"
assert_log_contains "-D SKYBRIDGE_PQC_PROBE_SECURE_ENCLAVE"

: > "${FAKE_LOG}"
skybridge_detect_apple_pqc_sdk iphoneos
assert_eq "${SKYBRIDGE_PQC_SDK_AVAILABLE}" "1" "iPhoneOS availability"
assert_eq "${SKYBRIDGE_PQC_SWIFT_TARGET}" "arm64-apple-ios26.0" "iPhoneOS target"
assert_eq "${SKYBRIDGE_PQC_INCLUDED_SECURE_ENCLAVE}" "1" "iPhoneOS Secure Enclave probe flag"
assert_log_contains "sdk=iphoneos"
assert_log_contains "-target arm64-apple-ios26.0"
assert_log_contains "-D SKYBRIDGE_PQC_PROBE_SECURE_ENCLAVE"

: > "${FAKE_LOG}"
skybridge_detect_apple_pqc_sdk iphonesimulator
assert_eq "${SKYBRIDGE_PQC_SDK_AVAILABLE}" "1" "iPhoneSimulator availability"
assert_eq "${SKYBRIDGE_PQC_SWIFT_TARGET}" "${host_arch}-apple-ios26.0-simulator" "iPhoneSimulator target"
assert_eq "${SKYBRIDGE_PQC_INCLUDED_SECURE_ENCLAVE}" "0" "iPhoneSimulator Secure Enclave probe flag"
assert_log_contains "sdk=iphonesimulator"
assert_log_contains "-target ${host_arch}-apple-ios26.0-simulator"
assert_log_not_contains "-D SKYBRIDGE_PQC_PROBE_SECURE_ENCLAVE"

export SKYBRIDGE_FAKE_SWIFTC_FAIL=iphoneos
skybridge_detect_apple_pqc_sdk iphoneos
assert_eq "${SKYBRIDGE_PQC_SDK_AVAILABLE}" "0" "failed iPhoneOS availability"
assert_eq "${SKYBRIDGE_PQC_PROBE_MODE}" "symbol_probe_failed" "failed iPhoneOS mode"
if skybridge_apple_pqc_sdk_probe_succeeded; then
  fail "failed iPhoneOS probe must not satisfy the strict success predicate"
fi
if skybridge_require_apple_pqc_sdk_symbol_probe iphoneos >/dev/null 2>&1; then
  fail "strict iPhoneOS helper must reject failed symbol probes"
fi
export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=stale
skybridge_configure_optional_apple_pqc_sdk_compile_gate iphoneos
assert_eq "${SKYBRIDGE_ENABLE_APPLE_PQC_SDK}" "0" "optional iPhoneOS compile gate after failed probe"
[[ "${SKYBRIDGE_PQC_PROBE_ERROR}" == *"sdk=iphoneos target=arm64-apple-ios26.0"* ]] \
  || fail "failed iPhoneOS probe error should include sdk and target"
[[ "${SKYBRIDGE_PQC_PROBE_ERROR}" == *"fake typecheck failure for iphoneos"* ]] \
  || fail "failed iPhoneOS probe error should include compiler stderr"
unset SKYBRIDGE_FAKE_SWIFTC_FAIL

export SKYBRIDGE_FAKE_XCRUN_NO_SDK=iphonesimulator
skybridge_detect_apple_pqc_sdk iphonesimulator
assert_eq "${SKYBRIDGE_PQC_SDK_AVAILABLE}" "0" "missing simulator SDK availability"
assert_eq "${SKYBRIDGE_PQC_PROBE_MODE}" "sdk_lookup_failed" "missing simulator SDK mode"
unset SKYBRIDGE_FAKE_XCRUN_NO_SDK

skybridge_detect_apple_pqc_sdk watchos
assert_eq "${SKYBRIDGE_PQC_SDK_AVAILABLE}" "0" "unsupported SDK availability"
assert_eq "${SKYBRIDGE_PQC_PROBE_MODE}" "unsupported_sdk" "unsupported SDK mode"
if skybridge_require_apple_pqc_sdk_symbol_probe watchos >/dev/null 2>&1; then
  fail "strict helper must reject unsupported SDK targets"
fi
export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=stale
skybridge_configure_optional_apple_pqc_sdk_compile_gate watchos
assert_eq "${SKYBRIDGE_ENABLE_APPLE_PQC_SDK}" "0" "optional unsupported SDK compile gate"
[[ "${SKYBRIDGE_PQC_PROBE_ERROR}" == *"unsupported Apple PQC SDK probe target: watchos"* ]] \
  || fail "unsupported SDK should include the invalid target"

probe_source="$(cat "${ROOT_DIR}/Scripts/apple_pqc_sdk_probe.sh")"
[[ "${probe_source}" == *"skybridge_detect_network_tls_pqc_sdk()"* ]] \
  || fail "Network TLS PQC probe helper should be defined separately from the CryptoKit PQC probe"
[[ "${probe_source}" == *"import Network"* ]] \
  || fail "Network TLS PQC probe should typecheck the public Network Swift surface"
[[ "${probe_source}" == *"SwiftTLSOptions()"* ]] \
  || fail "Network TLS PQC probe should require the public SwiftTLSOptions API"
[[ "${probe_source}" == *".x25519MLKEM768"* ]] \
  || fail "Network TLS PQC probe should require the hybrid X25519+ML-KEM-768 key exchange group"
[[ "${probe_source}" == *"SecureEnclave.MLKEM1024.PrivateKey.self"* ]] \
  || fail "CryptoKit PQC probe should require the physical-device Secure Enclave ML-KEM-1024 symbol"
[[ "${probe_source}" == *"SecureEnclave.MLDSA65.PrivateKey.self"* ]] \
  || fail "CryptoKit PQC probe should require the physical-device Secure Enclave ML-DSA-65 symbol"
[[ "${probe_source}" == *"SecureEnclave.MLDSA87.PrivateKey.self"* ]] \
  || fail "CryptoKit PQC probe should require the physical-device Secure Enclave ML-DSA-87 symbol"
[[ "${probe_source}" == *"func probeSecureEnclavePQCSymbols()"* ]] \
  || fail "Secure Enclave PQC symbol probe should be platform-neutral for macOS and iPhoneOS"

: > "${FAKE_LOG}"
export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=preserve
skybridge_detect_network_tls_pqc_sdk macosx
assert_eq "${SKYBRIDGE_NETWORK_TLS_PQC_SDK_AVAILABLE}" "1" "Network TLS PQC macOS fake availability"
assert_eq "${SKYBRIDGE_NETWORK_TLS_PQC_PROBE_MODE}" "symbol_probe" "Network TLS PQC macOS mode"
assert_eq "${SKYBRIDGE_NETWORK_TLS_PQC_SYMBOL_SET}" "network-tls-pqc-v1" "Network TLS PQC symbol set"
assert_eq "${SKYBRIDGE_ENABLE_APPLE_PQC_SDK}" "preserve" "Network TLS PQC probe must not touch CryptoKit compile gate"
skybridge_network_tls_pqc_sdk_probe_succeeded \
  || fail "successful Network TLS PQC fake probe should satisfy its own success predicate"
assert_log_contains "sdk=macosx"
assert_log_contains "-target ${host_arch}-apple-macosx27.0"

: > "${FAKE_LOG}"
skybridge_detect_network_tls_pqc_sdk iphoneos
assert_eq "${SKYBRIDGE_NETWORK_TLS_PQC_SDK_AVAILABLE}" "1" "Network TLS PQC iPhoneOS fake availability"
assert_eq "${SKYBRIDGE_NETWORK_TLS_PQC_SWIFT_TARGET}" "arm64-apple-ios27.0" "Network TLS PQC iPhoneOS target"
assert_log_contains "sdk=iphoneos"
assert_log_contains "-target arm64-apple-ios27.0"

export SKYBRIDGE_FAKE_SWIFTC_FAIL=iphonesimulator
skybridge_detect_network_tls_pqc_sdk iphonesimulator
assert_eq "${SKYBRIDGE_NETWORK_TLS_PQC_SDK_AVAILABLE}" "0" "failed Network TLS PQC simulator availability"
assert_eq "${SKYBRIDGE_NETWORK_TLS_PQC_PROBE_MODE}" "symbol_probe_failed" "failed Network TLS PQC simulator mode"
if skybridge_network_tls_pqc_sdk_probe_succeeded; then
  fail "failed Network TLS PQC probe must not satisfy the success predicate"
fi
[[ "${SKYBRIDGE_NETWORK_TLS_PQC_PROBE_ERROR}" == *"sdk=iphonesimulator target=${host_arch}-apple-ios27.0-simulator"* ]] \
  || fail "failed Network TLS PQC simulator probe should include sdk and target"
unset SKYBRIDGE_FAKE_SWIFTC_FAIL

skybridge_detect_network_tls_pqc_sdk watchos
assert_eq "${SKYBRIDGE_NETWORK_TLS_PQC_SDK_AVAILABLE}" "0" "unsupported Network TLS PQC SDK availability"
assert_eq "${SKYBRIDGE_NETWORK_TLS_PQC_PROBE_MODE}" "unsupported_sdk" "unsupported Network TLS PQC SDK mode"
assert_eq "${SKYBRIDGE_ENABLE_APPLE_PQC_SDK}" "preserve" "unsupported Network TLS PQC probe must not touch CryptoKit compile gate"
[[ "${SKYBRIDGE_NETWORK_TLS_PQC_PROBE_ERROR}" == *"unsupported Network TLS PQC SDK probe target: watchos"* ]] \
  || fail "unsupported Network TLS PQC SDK should include the invalid target"

echo "[test-apple-pqc-sdk-probe] passed"
