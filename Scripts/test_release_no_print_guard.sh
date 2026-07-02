#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${ROOT_DIR}/Scripts/release_no_print_guard.zsh"
TMP_DIR="$(mktemp -d)"
LAST_OUTPUT="${TMP_DIR}/last-output.txt"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

new_fixture() {
  local name="$1"
  local fixture="${TMP_DIR}/${name}"
  mkdir -p "${fixture}/Sources/SkyBridgeCore"
  printf '%s\n' "${fixture}"
}

write_swift() {
  local fixture="$1"
  local relative_path="$2"
  shift 2
  mkdir -p "$(dirname "${fixture}/${relative_path}")"
  printf '%s\n' "$@" >"${fixture}/${relative_path}"
}

run_guard() {
  local fixture="$1"
  SRCROOT="${fixture}" zsh "${GUARD}" >"${LAST_OUTPUT}" 2>&1
}

expect_pass() {
  local label="$1"
  local fixture="$2"

  if ! run_guard "${fixture}"; then
    echo "FAIL ${label}: expected pass" >&2
    cat "${LAST_OUTPUT}" >&2
    exit 1
  fi
}

expect_fail() {
  local label="$1"
  local fixture="$2"
  local expected_status="$3"
  local expected_text="$4"
  local status=0

  set +e
  run_guard "${fixture}"
  status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    echo "FAIL ${label}: expected failure" >&2
    cat "${LAST_OUTPUT}" >&2
    exit 1
  fi

  if [[ "${status}" -ne "${expected_status}" ]]; then
    echo "FAIL ${label}: expected exit ${expected_status}, got ${status}" >&2
    cat "${LAST_OUTPUT}" >&2
    exit 1
  fi

  if ! grep -Fq "${expected_text}" "${LAST_OUTPUT}"; then
    echo "FAIL ${label}: missing expected output ${expected_text}" >&2
    cat "${LAST_OUTPUT}" >&2
    exit 1
  fi
}

expect_unset_srcroot_fails() {
  local status=0

  set +e
  env -u SRCROOT zsh "${GUARD}" >"${LAST_OUTPUT}" 2>&1
  status=$?
  set -e

  if [[ "${status}" -ne 2 ]]; then
    echo "FAIL unset SRCROOT: expected exit 2, got ${status}" >&2
    cat "${LAST_OUTPUT}" >&2
    exit 1
  fi

  if ! grep -Fq "SRCROOT is required" "${LAST_OUTPUT}"; then
    echo "FAIL unset SRCROOT: missing failure message" >&2
    cat "${LAST_OUTPUT}" >&2
    exit 1
  fi
}

expect_unset_srcroot_fails

missing_sources="${TMP_DIR}/missing-sources"
mkdir -p "${missing_sources}"
expect_fail "missing Sources" "${missing_sources}" 2 "Sources directory not found"

false_positive="$(new_fixture false-positive)"
write_swift "${false_positive}" "Sources/SkyBridgeCore/Fingerprints.swift" \
  "struct DeviceFingerprint {}" \
  "let footprint = DeviceFingerprint()"
expect_pass "symbol names containing print" "${false_positive}"

runtime_print="$(new_fixture runtime-print)"
write_swift "${runtime_print}" "Sources/SkyBridgeCore/Runtime.swift" \
  "func emitRuntimeLog() {" \
  "  print(\"runtime\")" \
  "}"
expect_fail "runtime print" "${runtime_print}" 1 "Runtime.swift:2"

debug_print="$(new_fixture debug-print)"
write_swift "${debug_print}" "Sources/SkyBridgeCore/DebugOnly.swift" \
  "#if DEBUG" \
  "print(\"debug\")" \
  "#endif"
expect_pass "DEBUG print" "${debug_print}"

release_else_print="$(new_fixture release-else-print)"
write_swift "${release_else_print}" "Sources/SkyBridgeCore/ReleaseElse.swift" \
  "#if DEBUG" \
  "let debugOnly = true" \
  "#else" \
  "print(\"release\")" \
  "#endif"
expect_fail "release else print" "${release_else_print}" 1 "ReleaseElse.swift:4"

not_debug_print="$(new_fixture not-debug-print)"
write_swift "${not_debug_print}" "Sources/SkyBridgeCore/NotDebug.swift" \
  "#if !DEBUG" \
  "print(\"release\")" \
  "#endif"
expect_fail "not DEBUG print" "${not_debug_print}" 1 "NotDebug.swift:2"

nested_debug_print="$(new_fixture nested-debug-print)"
write_swift "${nested_debug_print}" "Sources/SkyBridgeCore/NestedDebug.swift" \
  "#if os(macOS)" \
  "#if DEBUG || INTERNAL_DIAGNOSTICS" \
  "print(\"debug\")" \
  "#endif" \
  "#endif"
expect_pass "nested DEBUG print" "${nested_debug_print}"

excluded_target="$(new_fixture excluded-target)"
write_swift "${excluded_target}" "Sources/BaselineBenchRunner/main.swift" \
  "print(\"bench\")"
expect_pass "excluded executable target" "${excluded_target}"

excluded_prefix="$(new_fixture excluded-prefix)"
write_swift "${excluded_prefix}" "Sources/BaselineBenchRunnerExtra/main.swift" \
  "print(\"not excluded\")"
expect_fail "excluded prefix is not enough" "${excluded_prefix}" 1 "BaselineBenchRunnerExtra/main.swift:1"

echo "[OK] release_no_print_guard self-test passed"
