#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRANSACTION_HELPER="$ROOT_DIR/Scripts/qperiapt_install_transaction.sh"
BUILD_SCRIPT="$ROOT_DIR/Scripts/build_qperiapt_xcframework.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qperiapt-install-transaction-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "[test-qperiapt-install-transaction] $*" >&2
  exit 1
}

assert_content() {
  local expected="$1"
  local path="$2"
  local actual
  [[ -f "$path" ]] || fail "missing file: $path"
  actual="$(cat "$path")"
  [[ "$actual" == "$expected" ]] || fail "unexpected content in $path: expected=$expected actual=$actual"
}

assert_absent() {
  local path="$1"
  [[ ! -e "$path" && ! -L "$path" ]] || fail "transaction path was not cleaned: $path"
}

initialize_case() {
  local case_root="$1"
  rm -rf "$case_root"
  mkdir -p "$case_root/mac.xcframework"
  printf '%s\n' old-mac >"$case_root/mac.xcframework/payload"
  printf '%s\n' old-header >"$case_root/q_periapt.h"
}

assert_old_targets() {
  local case_root="$1"
  assert_content old-mac "$case_root/mac.xcframework/payload"
  assert_content old-header "$case_root/q_periapt.h"
}

assert_new_targets() {
  local case_root="$1"
  assert_content new-mac "$case_root/mac.xcframework/payload"
  assert_content new-header "$case_root/q_periapt.h"
}

assert_transaction_artifacts_absent() {
  local case_root="$1"
  local destination
  assert_absent "$case_root/journal"
  for destination in \
    "$case_root/mac.xcframework" \
    "$case_root/q_periapt.h"; do
    assert_absent "${destination}.qperiapt-install.staged"
    assert_absent "${destination}.qperiapt-install.backup"
  done
}

run_transaction() {
  local case_root="$1"
  local fault_step="$2"
  QPERIAPT_INSTALL_FAULT_STEP="$fault_step" bash -c '
    set -euo pipefail
    source "$1"
    case_root="$2"
    qperiapt_transaction_begin \
      "$case_root/journal" \
      "$case_root/mac.xcframework" \
      "$case_root/q_periapt.h"
    mac_staged="$(qperiapt_transaction_stage_path "$case_root/mac.xcframework")"
    header_staged="$(qperiapt_transaction_stage_path "$case_root/q_periapt.h")"
    mkdir -p "$mac_staged"
    printf "%s\n" new-mac >"$mac_staged/payload"
    printf "%s\n" new-header >"$header_staged"
    qperiapt_transaction_install_all
    qperiapt_transaction_commit
  ' _ "$TRANSACTION_HELPER" "$case_root"
}

for step in 1 2; do
  case_root="$TMP_DIR/failure-step-$step"
  log_path="$TMP_DIR/failure-step-$step.log"
  initialize_case "$case_root"
  if run_transaction "$case_root" "$step" >"$log_path" 2>&1; then
    fail "fault injection step $step unexpectedly succeeded"
  fi
  assert_old_targets "$case_root"
  assert_transaction_artifacts_absent "$case_root"
  grep -Fq "Injected Q-Periapt install failure after step $step" "$log_path" \
    || fail "step $step failure was not explicit"
  grep -Fq "Rolled back all Q-Periapt vendor targets." "$log_path" \
    || fail "step $step did not report complete rollback"
  if grep -Fq "Committed all Q-Periapt vendor targets" "$log_path"; then
    fail "step $step reported transaction success after a fault"
  fi
done

success_root="$TMP_DIR/success"
success_log="$TMP_DIR/success.log"
initialize_case "$success_root"
run_transaction "$success_root" "" >"$success_log" 2>&1
assert_new_targets "$success_root"
assert_transaction_artifacts_absent "$success_root"
grep -Fq "Committed all Q-Periapt vendor targets and removed every backup." "$success_log" \
  || fail "successful transaction did not report committed cleanup"

# Simulate an untrappable process death after the first rename. A later
# invocation must use the persistent journal and adjacent backup to recover.
recovery_root="$TMP_DIR/recovery"
recovery_log="$TMP_DIR/recovery.log"
initialize_case "$recovery_root"
if bash -c '
  set -euo pipefail
  source "$1"
  case_root="$2"
  qperiapt_transaction_begin \
    "$case_root/journal" \
    "$case_root/mac.xcframework" \
    "$case_root/q_periapt.h"
  mac_staged="$(qperiapt_transaction_stage_path "$case_root/mac.xcframework")"
  mkdir -p "$mac_staged"
  printf "%s\n" interrupted-new-mac >"$mac_staged/payload"
  qperiapt_transaction_install_one mac 1 "$case_root/mac.xcframework"
  trap - EXIT INT TERM HUP
  exit 99
' _ "$TRANSACTION_HELPER" "$recovery_root" >"$recovery_log" 2>&1; then
  fail "interrupted transaction fixture unexpectedly succeeded"
fi

# The crashed owner is gone, so recovery is safe and must restore all old data.
# This calls the same recovery routine used by qperiapt_transaction_begin.
bash -c '
  set -euo pipefail
  source "$1"
  case_root="$2"
  qperiapt_transaction_recover_if_needed \
    "$case_root/journal" \
    "$case_root/mac.xcframework" \
    "$case_root/q_periapt.h"
' _ "$TRANSACTION_HELPER" "$recovery_root" >>"$recovery_log" 2>&1
assert_old_targets "$recovery_root"
assert_transaction_artifacts_absent "$recovery_root"
grep -Fq "Recovering an interrupted transaction" "$recovery_log" \
  || fail "persistent journal recovery was not reported"

# If an original backup is lost, rollback must stay red, retain the journal,
# and never print a commit-success message.
rollback_failure_root="$TMP_DIR/rollback-failure"
rollback_failure_log="$TMP_DIR/rollback-failure.log"
initialize_case "$rollback_failure_root"
if bash -c '
  set -euo pipefail
  source "$1"
  case_root="$2"
  qperiapt_transaction_begin \
    "$case_root/journal" \
    "$case_root/mac.xcframework" \
    "$case_root/q_periapt.h"
  mac_staged="$(qperiapt_transaction_stage_path "$case_root/mac.xcframework")"
  mkdir -p "$mac_staged"
  printf "%s\n" new-mac >"$mac_staged/payload"
  qperiapt_transaction_install_one mac 1 "$case_root/mac.xcframework"
  rm -rf "$(qperiapt_transaction_backup_path "$case_root/mac.xcframework")"
  false
' _ "$TRANSACTION_HELPER" "$rollback_failure_root" >"$rollback_failure_log" 2>&1; then
  fail "rollback-failure fixture unexpectedly succeeded"
fi
grep -Fq "Rollback is missing the recorded Q-Periapt mac backup" "$rollback_failure_log" \
  || fail "missing rollback backup was not explicit"
grep -Fq "Q-Periapt rollback FAILED" "$rollback_failure_log" \
  || fail "rollback failure did not retain a red transaction state"
[[ -d "$rollback_failure_root/journal" ]] \
  || fail "rollback failure removed the recovery journal"
if grep -Fq "Committed all Q-Periapt vendor targets" "$rollback_failure_log"; then
  fail "rollback failure incorrectly reported success"
fi

LITERAL_DOLLAR='$'

grep -Fq "source \"${LITERAL_DOLLAR}ROOT_DIR/Scripts/qperiapt_install_transaction.sh\"" "$BUILD_SCRIPT" \
  || fail "build script does not load the transaction helper"
grep -Fq 'qperiapt_transaction_install_all' "$BUILD_SCRIPT" \
  || fail "build script does not install through the transaction"
grep -Fq 'qperiapt_transaction_commit' "$BUILD_SCRIPT" \
  || fail "build script does not commit the transaction"
grep -Fq 'QPERIAPT_RELEASE_TAG="v0.1.0-alpha.2-r1"' "$BUILD_SCRIPT" \
  || fail "build script lost the immutable ABI2 release tag"
grep -Fq 'QPERIAPT_SOURCE_COMMIT="5664fd86a617f92b620ea37e7692d3417d0e307d"' "$BUILD_SCRIPT" \
  || fail "build script lost the pinned ABI2 source commit"
grep -Fq "require_sha256 \"${LITERAL_DOLLAR}DOWNLOAD_DIR/CQPeriapt.xcframework.zip\" \"${LITERAL_DOLLAR}QPERIAPT_ZIP_SHA256\"" "$BUILD_SCRIPT" \
  || fail "build script lost the release archive hash gate"
grep -Fq 'validate_release_metadata' "$BUILD_SCRIPT" \
  || fail "build script lost the signed release metadata gate"
grep -Fq 'validate_archive_shape' "$BUILD_SCRIPT" \
  || fail "build script lost the exact archive-shape gate"
grep -Fq "assert_original_release \"${LITERAL_DOLLAR}ORIGINAL_XCFRAMEWORK\"" "$BUILD_SCRIPT" \
  || fail "build script lost the upstream Developer ID verification gate"
grep -Fq 'assert_exact_symbols' "$BUILD_SCRIPT" \
  || fail "build script lost the ABI2 exact-nine symbol gate"
grep -Fq "assert_derivative \"${LITERAL_DOLLAR}STAGED_OUT\"" "$BUILD_SCRIPT" \
  || fail "build script lost the transformed derivative validation gate"

staged_validation_line="$(grep -nF "assert_derivative \"${LITERAL_DOLLAR}TRANSACTION_MAC_STAGED\"" "$BUILD_SCRIPT" | cut -d: -f1)"
install_line="$(grep -nF 'qperiapt_transaction_install_all' "$BUILD_SCRIPT" | cut -d: -f1)"
installed_validation_line="$(grep -nF "assert_derivative \"${LITERAL_DOLLAR}FINAL_OUT\"" "$BUILD_SCRIPT" | tail -1 | cut -d: -f1)"
[[ -n "$staged_validation_line" && -n "$install_line" && -n "$installed_validation_line" ]] \
  || fail "build script is missing staged/install/post-install transaction phases"
(( staged_validation_line < install_line )) \
  || fail "build script installs before validating every staged replacement"
(( install_line < installed_validation_line )) \
  || fail "build script does not revalidate installed targets before commit"

echo "[test-qperiapt-install-transaction] passed"
