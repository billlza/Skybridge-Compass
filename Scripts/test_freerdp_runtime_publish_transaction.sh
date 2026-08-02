#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/freerdp_runtime_publish_transaction.sh
source "$ROOT_DIR/Scripts/freerdp_runtime_publish_transaction.sh"

fail() {
  echo "[test-freerdp-publish-transaction] $1" >&2
  exit 1
}

fixture_mv_count=0
fixture_mv_fail_at=0
fixture_mv_additional_failure=0
fixture_mv() {
  fixture_mv_count=$((fixture_mv_count + 1))
  if [[ "$fixture_mv_count" -eq "$fixture_mv_fail_at" \
    || "$fixture_mv_count" -eq "$fixture_mv_additional_failure" ]]; then
    return 91
  fi
  /bin/mv "$@"
}

fixture_verify_failure() {
  return 92
}

fixture_process_start_token() {
  local pid="$1"
  if [[ "${fixture_absent_process_pid:-0}" -eq "$pid" ]]; then
    return 1
  fi
  printf '%064x\n' "$pid"
}

write_component_set() {
  local root="$1"
  local version="$2"
  mkdir -p "$root/Dylibs" "$root/Headers" "$root/Licenses"
  printf '%s\n' "$version" >"$root/Dylibs/version.txt"
  printf '%s\n' "$version" >"$root/Headers/version.txt"
  printf '%s\n' "$version" >"$root/Licenses/version.txt"
  printf '%s\n' "$version" >"$root/provenance.json"
}

make_fixture() {
  local root="$1"
  mkdir -p "$root/live" "$root/transaction/publish" "$root/transaction/backup"
  write_component_set "$root/live" old
  write_component_set "$root/transaction/publish" new
  printf '%s\n' sentinel >"$root/sentinel.txt"
}

assert_component_set() {
  local root="$1"
  local expected="$2"
  local label
  for label in Dylibs Headers Licenses; do
    [[ "$(<"$root/$label/version.txt")" == "$expected" ]] \
      || fail "${label} expected ${expected} bytes"
  done
  [[ "$(<"$root/provenance.json")" == "$expected" ]] \
    || fail "provenance expected ${expected} bytes"
}

assert_transaction_stages_removed() {
  local root="$1"
  [[ ! -e "$root/transaction/publish" ]] || fail "publish stage was not removed"
  [[ ! -e "$root/transaction/backup" ]] || fail "backup stage was not removed"
  [[ "$(<"$root/sentinel.txt")" == "sentinel" ]] || fail "unrelated sentinel changed"
}

run_move_failure_case() {
  local failure_index="$1"
  local label="$2"
  local root
  root="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-freerdp-publish-${label}.XXXXXX")"
  make_fixture "$root"
  fixture_mv_count=0
  fixture_mv_fail_at="$failure_index"
  fixture_mv_additional_failure=0

  if skybridge_publish_freerdp_runtime \
    "$root/transaction/publish" \
    "$root/transaction/backup" \
    "$root/live/Dylibs" \
    "$root/live/Headers" \
    "$root/live/Licenses" \
    "$root/live/provenance.json" \
    fixture_mv \
    fixture_process_start_token \
    /usr/bin/true; then
    fail "${label} unexpectedly succeeded"
  fi

  assert_component_set "$root/live" old
  assert_transaction_stages_removed "$root"
  rm -rf "$root"
}

for backup_index in 1 2 3 4; do
  run_move_failure_case "$backup_index" "backup-${backup_index}"
done
for publish_index in 1 2 3 4; do
  run_move_failure_case "$((4 + publish_index))" "publish-${publish_index}"
done

verify_failure_root="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-freerdp-publish-verify.XXXXXX")"
make_fixture "$verify_failure_root"
fixture_mv_count=0
fixture_mv_fail_at=0
fixture_mv_additional_failure=0
if skybridge_publish_freerdp_runtime \
  "$verify_failure_root/transaction/publish" \
  "$verify_failure_root/transaction/backup" \
  "$verify_failure_root/live/Dylibs" \
  "$verify_failure_root/live/Headers" \
  "$verify_failure_root/live/Licenses" \
  "$verify_failure_root/live/provenance.json" \
  fixture_mv \
  fixture_process_start_token \
  fixture_verify_failure; then
  fail "post-publication verifier failure unexpectedly succeeded"
fi
assert_component_set "$verify_failure_root/live" old
assert_transaction_stages_removed "$verify_failure_root"
rm -rf "$verify_failure_root"

rollback_failure_root="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-freerdp-publish-rollback-failure.XXXXXX")"
make_fixture "$rollback_failure_root"
fixture_mv_count=0
fixture_mv_fail_at=6
fixture_mv_additional_failure=9
if skybridge_publish_freerdp_runtime \
  "$rollback_failure_root/transaction/publish" \
  "$rollback_failure_root/transaction/backup" \
  "$rollback_failure_root/live/Dylibs" \
  "$rollback_failure_root/live/Headers" \
  "$rollback_failure_root/live/Licenses" \
  "$rollback_failure_root/live/provenance.json" \
  fixture_mv \
  fixture_process_start_token \
  /usr/bin/true; then
  fail "rollback-move failure unexpectedly succeeded"
fi
[[ ! -e "$rollback_failure_root/live/Headers" ]] \
  || fail "failed header rollback must not fabricate a restored live component"
[[ "$(<"$rollback_failure_root/transaction/backup/Headers/version.txt")" == "old" ]] \
  || fail "failed header rollback must preserve its exact old backup"
for restored_component in Dylibs Licenses; do
  [[ "$(<"$rollback_failure_root/live/$restored_component/version.txt")" == "old" ]] \
    || fail "${restored_component} should still restore when another rollback move fails"
done
[[ "$(<"$rollback_failure_root/live/provenance.json")" == "old" ]] \
  || fail "provenance should still restore when another rollback move fails"
[[ ! -e "$rollback_failure_root/transaction/publish" ]] \
  || fail "failed publish bytes should be removed after a rollback failure"
rollback_lock="$rollback_failure_root/live/.FreeRDPRuntime.publish.lock"
[[ "$(<"$rollback_lock/recovery-required")" == "$rollback_failure_root/transaction/backup" ]] \
  || fail "rollback failure must preserve an exact recovery pointer"
[[ "$(<"$rollback_failure_root/sentinel.txt")" == "sentinel" ]] \
  || fail "rollback failure changed an unrelated sentinel"
rm -rf "$rollback_failure_root"

success_root="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-freerdp-publish-success.XXXXXX")"
make_fixture "$success_root"
fixture_mv_count=0
fixture_mv_fail_at=0
fixture_mv_additional_failure=0
skybridge_publish_freerdp_runtime \
  "$success_root/transaction/publish" \
  "$success_root/transaction/backup" \
  "$success_root/live/Dylibs" \
  "$success_root/live/Headers" \
  "$success_root/live/Licenses" \
  "$success_root/live/provenance.json" \
  fixture_mv \
  fixture_process_start_token \
  /usr/bin/true
assert_component_set "$success_root/live" new
assert_transaction_stages_removed "$success_root"
rm -rf "$success_root"

stale_root="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-freerdp-publish-stale.XXXXXX")"
make_fixture "$stale_root"
stale_lock="$stale_root/live/.FreeRDPRuntime.publish.lock"
stale_pid=999999
stale_token="$(printf '%064x' "$stale_pid")"
stale_publish="$stale_root/stale-publish"
stale_backup="$stale_root/stale-backup"
mkdir -p "$stale_lock" "$stale_publish" "$stale_backup"
printf '%s\t%s\t%s\t%s\n' \
  "$stale_pid" "$stale_token" "$stale_publish" "$stale_backup" >"$stale_lock/owner"
fixture_absent_process_pid="$stale_pid"
fixture_mv_count=0
fixture_mv_fail_at=0
fixture_mv_additional_failure=0
skybridge_publish_freerdp_runtime \
  "$stale_root/transaction/publish" \
  "$stale_root/transaction/backup" \
  "$stale_root/live/Dylibs" \
  "$stale_root/live/Headers" \
  "$stale_root/live/Licenses" \
  "$stale_root/live/provenance.json" \
  fixture_mv \
  fixture_process_start_token \
  /usr/bin/true
fixture_absent_process_pid=0
assert_component_set "$stale_root/live" new
[[ ! -e "$stale_lock" ]] || fail "verified stale publisher lock was not recovered and released"
rm -rf "$stale_root"

fixture_blocking_verify() {
  local attempt
  : >"$fixture_block_ready"
  for attempt in {1..200}; do
    if [[ -f "$fixture_block_release" ]]; then
      return 0
    fi
    sleep 0.01
  done
  return 93
}

concurrent_root="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-freerdp-publish-concurrent.XXXXXX")"
make_fixture "$concurrent_root"
mkdir -p "$concurrent_root/transaction-second/publish" "$concurrent_root/transaction-second/backup"
write_component_set "$concurrent_root/transaction-second/publish" second
fixture_block_ready="$concurrent_root/first-publisher-ready"
fixture_block_release="$concurrent_root/release-first-publisher"
fixture_mv_count=0
fixture_mv_fail_at=0
fixture_mv_additional_failure=0
skybridge_publish_freerdp_runtime \
  "$concurrent_root/transaction/publish" \
  "$concurrent_root/transaction/backup" \
  "$concurrent_root/live/Dylibs" \
  "$concurrent_root/live/Headers" \
  "$concurrent_root/live/Licenses" \
  "$concurrent_root/live/provenance.json" \
  fixture_mv \
  fixture_process_start_token \
  fixture_blocking_verify &
first_publisher_pid=$!

publisher_ready=0
for readiness_attempt in {1..200}; do
  if [[ -f "$fixture_block_ready" ]]; then
    publisher_ready=1
    break
  fi
  sleep 0.01
done
[[ "$publisher_ready" -eq 1 ]] || fail "first publisher did not reach its bounded verification gate"

if skybridge_publish_freerdp_runtime \
  "$concurrent_root/transaction-second/publish" \
  "$concurrent_root/transaction-second/backup" \
  "$concurrent_root/live/Dylibs" \
  "$concurrent_root/live/Headers" \
  "$concurrent_root/live/Licenses" \
  "$concurrent_root/live/provenance.json" \
  fixture_mv \
  fixture_process_start_token \
  /usr/bin/true; then
  fail "a concurrent second publisher unexpectedly acquired the live transaction"
fi
assert_component_set "$concurrent_root/live" new
assert_component_set "$concurrent_root/transaction/backup" old
[[ -z "$(find "$concurrent_root/transaction-second/backup" -mindepth 1 -print -quit)" ]] \
  || fail "rejected second publisher touched its backup stage"

: >"$fixture_block_release"
if ! wait "$first_publisher_pid"; then
  fail "first publisher failed after the second publisher was rejected"
fi
assert_component_set "$concurrent_root/live" new
[[ ! -e "$concurrent_root/live/.FreeRDPRuntime.publish.lock" ]] \
  || fail "successful first publisher did not release its exact lock"
rm -rf "$concurrent_root"

echo "[test-freerdp-publish-transaction] passed"
