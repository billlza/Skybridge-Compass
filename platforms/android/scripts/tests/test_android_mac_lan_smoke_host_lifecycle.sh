#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE_SCRIPT="$ROOT_DIR/scripts/run_android_mac_lan_remote_smoke.sh"
DEBUG_ACTIVITY="$ROOT_DIR/app/src/debug/kotlin/com/skybridge/compass/android/debug/DebugLanInteropSmokeActivity.kt"
STATUS_VALIDATOR_TEST="$ROOT_DIR/scripts/tests/test_validate_android_mac_lan_status.py"
STATUS_VALIDATOR="$ROOT_DIR/scripts/validate_android_mac_lan_status.py"

fail() {
  echo "[test-android-mac-lan-smoke-host-lifecycle] $1" >&2
  exit 1
}

bash -n "$SMOKE_SCRIPT"
/usr/bin/python3 "$STATUS_VALIDATOR_TEST"
grep -Fq 'MacRemoteControlTrustContextFactory.persistentReadOnly(' "$DEBUG_ACTIVITY" \
  || fail "the debug LAN client must consume only existing product trust"
if grep -Fq 'MacRemoteControlTrustContextFactory.persistentReadWrite(' "$DEBUG_ACTIVITY"; then
  fail "normal product pairing authorization must not grant persistent writes to the debug LAN client"
fi
if grep -Fq 'normalProductPairingWriteAuthorized' "$DEBUG_ACTIVITY"; then
  fail "normal product pairing authorization belongs to the separate product PIB UI, not a debug Activity extra"
fi

required_literals=(
  'MAC_HOST_RUNNER="$MAC_PACKAGE_PATH/Scripts/run_real_device_p2p_remote_smoke.sh"'
  'SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN=1'
  'SKYBRIDGE_SMOKE_MAC_HOST_ONLY=1'
  'SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE=packaged-lab'
  'SKYBRIDGE_SMOKE_KEYCHAIN_MODE=system'
  'SKYBRIDGE_SMOKE_PQC_TRUST_MODE=actual'
  'SKYBRIDGE_SMOKE_ALLOW_PERSISTENT_TRUST_MUTATION=0'
  'SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH=0'
  'SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH=0'
  'SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=0'
  'SKYBRIDGE_REMOTE_CONTROL_NOTICE_AUTO_APPROVE=0'
  '"mode": "current-source-signed-packaged-host"'
  '"identityAccessPolicy": "existing-only"'
  '"hostPersistentIdentityMutationDenied": True'
  '"forcedPersistentTrustMutationAllowed": False'
  '"acceptanceEligible": False'
  '"diagnosticOnly": True'
  'stat.S_IMODE(metadata.st_mode) != 0o600'
  'identity-policy mode=existing-only mutation=denied source=explicit-smoke-environment'
  'NORMAL_PRODUCT_PAIRING_WRITE_AUTHORIZED'
  'normalProductPairingWriteAuthorized='
  'currentSourceHelper='
  'hostPersistentIdentityMutationDenied='
  'forcedPersistentTrustMutationAllowed=0'
  '"$START_MAC_HOST" == "true"'
  'kill -TERM "$HOST_RUNNER_PID"'
  'wait "$HOST_RUNNER_PID"'
  'trap - EXIT INT TERM'
  'Authenticated product trust is incomplete, including the product-origin peer KEM bootstrap.'
  'write_failure_summary "android_lan_smoke" "normal_product_pairing_required"'
  '--ez skybridgeRequireExistingProductTrust "$REQUIRE_EXISTING_PRODUCT_TRUST"'
  'identity_verified_after_android_product_trust=1'
  'host_identity_used_as_android_trust_lookup_candidate=1'
  'print(f"debug-lan-interop-smoke-status-{run_ref}.log")'
  'copy_remote_smoke_status'
  'inspect_android_smoke_status'
  'android_status_contract_invalid'
  'rm -f files/$SMOKE_NONCE_FILE_NAME files/$SMOKE_STATUS_FILE_NAME && test ! -e files/$SMOKE_NONCE_FILE_NAME && test ! -e files/$SMOKE_STATUS_FILE_NAME'
)
for literal in "${required_literals[@]}"; do
  grep -Fq -- "$literal" "$SMOKE_SCRIPT" \
    || fail "missing signed-host lifecycle contract: $literal"
done
grep -Fq 'identity authority=authenticated_product_v1' "$STATUS_VALIDATOR" \
  || fail "the validator must require the authenticated-product authority marker"
grep -Fq 'routeAuthority=debug_run_scoped snapshot=current' "$STATUS_VALIDATOR" \
  || fail "the validator must require the debug run-scoped current route marker"
grep -Fq 'handshake=verified frameOwner=current' "$STATUS_VALIDATOR" \
  || fail "the validator must bind the authority marker to current-frame ownership"
grep -Fq 'trust=TRUSTED_EXISTING' "$STATUS_VALIDATOR" \
  || fail "the validator must require existing authenticated product trust"

if grep -Fq 'swift build' "$SMOKE_SCRIPT"; then
  fail "Android orchestration must not duplicate the Apple signed-host build/signing lifecycle"
fi
if grep -Fq '"$HOST_EXECUTABLE"' "$SMOKE_SCRIPT"; then
  fail "Android orchestration must not launch a bare SwiftPM host executable"
fi
if grep -Fq '"persistentTrustMutationAllowed":' "$SMOKE_SCRIPT"; then
  fail "normal product pairing writes are authorized, so the evidence must not claim run-wide trust immutability"
fi
if grep -Fq 'files/debug-lan-interop-smoke-status.log' "$SMOKE_SCRIPT"; then
  fail "the runner must never read or delete the legacy shared status filename"
fi
for stale_authority in \
  'SkyBridge.SelfIdentity' \
  'Application Support/com.SkyBridge.Compass/settings.json' \
  'com.skybridge.p2p.identity.mldsa65'; do
  if grep -Fq -- "$stale_authority" "$SMOKE_SCRIPT"; then
    fail "strict LAN identity must not use stale Mac authority: $stale_authority"
  fi
done
grep -Fq 'The DebugLanInteropSmokeActivity and its scripted path consume existing trust read-only.' "$SMOKE_SCRIPT" \
  || fail "the usage contract must scope read-only trust access to the debug Activity and scripted path"
grep -Fq 'The separate normal-product PIB-1/SAS flow may persist peer trust after manual approval.' "$SMOKE_SCRIPT" \
  || fail "the usage contract must distinguish manually approved product pairing writes"
if grep -Fq 'This debug smoke always consumes persistent trust read-only and cannot create or update pairing state.' "$SMOKE_SCRIPT"; then
  fail "the usage contract must not make a run-wide read-only trust claim"
fi
if grep -Eq 'svc[[:space:]]+wifi|settings[[:space:]]+(put|delete)[[:space:]].*(http_proxy|proxy)|ip[[:space:]]+route[[:space:]]+(add|delete|replace)|networksetup|adb[^[:space:]]*[[:space:]]+(forward|reverse)' "$SMOKE_SCRIPT"; then
  fail "the LAN smoke must not mutate Wi-Fi, HTTP proxy, routes, or ADB forwarding"
fi

build_reference_line="$(grep -n -m 1 'HOST_BUILD_LOG="$MAC_HOST_ARTIFACT_DIR/macos-build.log"' "$SMOKE_SCRIPT" | cut -d: -f1)"
runner_launch_line="$(grep -n -m 1 'bash "$MAC_HOST_RUNNER" >"$HOST_LOG" 2>&1 &' "$SMOKE_SCRIPT" | cut -d: -f1)"
ready_validation_line="$(grep -n -m 1 'HOST_READY_DATA="$(validate_mac_host_ready_file)"' "$SMOKE_SCRIPT" | cut -d: -f1)"
[[ -n "$build_reference_line" && -n "$runner_launch_line" && -n "$ready_validation_line" ]] \
  || fail "signed-host build, launch, and readiness phases must all be explicit"
(( build_reference_line < runner_launch_line && runner_launch_line < ready_validation_line )) \
  || fail "Android must bind the Apple build artifact before launch and validate readiness afterward"

run_rejection() {
  local expected_message="$1"
  shift
  local output
  local status
  set +e
  output="$("$SMOKE_SCRIPT" "$@" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "unsafe invocation unexpectedly succeeded: $expected_message"
  grep -Fq -- "$expected_message" <<<"$output" \
    || fail "unsafe invocation did not explain its exact rejection: $expected_message"
}

run_rejection \
  'use the product PIB flow' \
  --device unused --prepair true
run_rejection \
  'so the pin stays ephemeral' \
  --device unused --allow-tofu true
run_rejection \
  'requires explicit authorization for normal product pairing trust writes' \
  --device unused
run_rejection \
  'requires secure transport with plaintext fallback disabled' \
  --device unused \
  --normal-product-pairing-write-authorized true \
  --allow-plaintext-fallback true
set +e
auto_approval_output="$(
  SKYBRIDGE_ANDROID_MAC_LAN_REMOTE_NOTICE_AUTO_APPROVE=1 \
    "$SMOKE_SCRIPT" \
      --device unused \
      --normal-product-pairing-write-authorized true 2>&1
)"
auto_approval_status=$?
set -e
[[ "$auto_approval_status" -ne 0 ]] \
  || fail "signed host unexpectedly accepted automatic remote-control approval"
grep -Fq 'requires manual pairing and remote-control approval' <<<"$auto_approval_output" \
  || fail "automatic approval rejection did not explain the manual product boundary"

set +e
in_memory_output="$(
  SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
    "$SMOKE_SCRIPT" \
      --device unused \
      --normal-product-pairing-write-authorized true 2>&1
)"
in_memory_status=$?
set -e
[[ "$in_memory_status" -ne 0 ]] \
  || fail "signed host unexpectedly accepted the in-memory Keychain"
grep -Fq 'requires the persistent system Keychain view' <<<"$in_memory_output" \
  || fail "in-memory Keychain rejection did not explain the system-Keychain boundary"

test_root="$(mktemp -d)"
cleanup_test_root() {
  /bin/rm -rf -- "$test_root"
}
trap cleanup_test_root EXIT
fake_bin="$test_root/bin"
fake_mac="$test_root/mac"
fake_run="$test_root/run"
mkdir -p "$fake_bin" "$fake_mac/Scripts"

apply_fixture() {
  local path="$1"
  python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.stdin.read(), encoding="utf-8")' "$path"
}

apply_fixture "$fake_bin/adb" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"getprop ro.build.version.release"*) printf '16\n' ;;
  *"getprop ro.build.version.sdk"*) printf '36\n' ;;
  *"getprop ro.product.model"*) printf 'Fixture Android\n' ;;
  *) exit 0 ;;
esac
SH
chmod 0755 "$fake_bin/adb"

apply_fixture "$fake_mac/Scripts/run_real_device_p2p_remote_smoke.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
umask 077
artifact="${SKYBRIDGE_SMOKE_ARTIFACT_DIR:?}"
mkdir -p "$artifact"
chmod 0700 "$artifact"
status="$artifact/fixture.status.log"
pqc="$artifact/fixture.pqc.json"
ready="$artifact/mac-host-ready.json"
printf '%s\n' \
  'identity-policy mode=existing-only mutation=denied source=explicit-smoke-environment' \
  'ready remote=_skybridge-rd._tcp port=5901' \
  'ready discovery=_skybridge._tcp port=5902' >"$status"
if [[ "${SKYBRIDGE_FIXTURE_MISSING_XWING:-0}" == "1" ]]; then
  printf '%s\n' '{"deviceId":"host-lookup-candidate","keys":[]}' >"$pqc"
else
  printf '%s\n' '{"deviceId":"different-existing-device","keys":[{"suiteWireId":1,"publicKeyBase64":"AQ=="}]}' >"$pqc"
fi
chmod 0600 "$status" "$pqc"
python3 - "$ready" "$artifact" "$status" "$pqc" "$$" <<'PY'
import json
import os
import pathlib
import sys

ready, artifact, status, pqc, pid = sys.argv[1:]
payload = {
    "acceptanceEligible": False,
    "artifactDirectory": artifact,
    "autoApprovePairing": False,
    "controlPort": 5902,
    "diagnosticOnly": True,
    "forcedPersistentTrustMutationAllowed": False,
    "hostExecutableSHA256": "0" * 64,
    "hostPID": int(pid),
    "hostPersistentIdentityMutationDenied": True,
    "identityAccessPolicy": "existing-only",
    "keychainMode": "system",
    "launchMode": "packaged-lab",
    "mode": "current-source-signed-packaged-host",
    "pqcReportFile": pqc,
    "remoteControlNoticeAutoApprove": False,
    "remotePort": 5901,
    "runnerPID": int(pid),
    "schemaVersion": 1,
    "sourceInputDigest": "1" * 64,
    "statusFile": status,
}
path = pathlib.Path(ready)
temporary = path.with_name(".ready.tmp")
temporary.write_text(json.dumps(payload), encoding="utf-8")
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY
trap 'exit 143' TERM
while true; do sleep 1; done
SH
chmod 0755 "$fake_mac/Scripts/run_real_device_p2p_remote_smoke.sh"

set +e
external_missing_output="$(
  PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SMOKE_SCRIPT" \
      --device fixture-device \
      --start-mac-host false \
      --run-dir "$test_root/external-missing" 2>&1
)"
external_missing_status=$?
set -e
[[ "$external_missing_status" -ne 0 ]] \
  || fail "strict external host unexpectedly accepted a missing product-trust lookup candidate"
grep -Fq 'requires an explicit device id lookup candidate for existing Android product trust' \
  <<<"$external_missing_output" \
  || fail "strict external-host failure did not explain the lookup-candidate boundary"
grep -Fq 'failure_reason=lookup_candidate_missing' "$test_root/external-missing/summary.txt" \
  || fail "missing external lookup candidate did not produce structured failure evidence"

set +e
host_candidate_output="$(
  SKYBRIDGE_FIXTURE_MISSING_XWING=1 \
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SMOKE_SCRIPT" \
      --device fixture-device \
      --mac-package-path "$fake_mac" \
      --normal-product-pairing-write-authorized true \
      --run-dir "$test_root/host-candidate" 2>&1
)"
host_candidate_status=$?
set -e
[[ "$host_candidate_status" -ne 0 ]] \
  || fail "signed-host fixture without existing X-Wing identity unexpectedly succeeded"
grep -Fq 'did not expose its existing X-Wing identity' <<<"$host_candidate_output" \
  || fail "signed-host lookup candidate did not advance to existing-identity validation"
grep -Fq 'failure_reason=signed_host_existing_identity_missing' \
  "$test_root/host-candidate/summary.txt" \
  || fail "signed-host missing-X-Wing fixture did not produce structured failure evidence"

set +e
fixture_output="$(
  PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SMOKE_SCRIPT" \
      --device fixture-device \
      --mac-package-path "$fake_mac" \
      --expected-device-id expected-existing-device \
      --expected-fingerprint aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
      --normal-product-pairing-write-authorized true \
      --run-dir "$fake_run" 2>&1
)"
fixture_status=$?
set -e
[[ "$fixture_status" -ne 0 ]] \
  || fail "fixture with a substituted existing device identity unexpectedly succeeded"
grep -Fq 'identity differs from the explicitly configured lookup candidate' <<<"$fixture_output" \
  || fail "validated signed-host readiness did not fail closed on identity substitution"
grep -Fq 'failure_reason=signed_host_identity_mismatch' "$fake_run/summary.txt" \
  || fail "identity substitution did not produce structured failure evidence"
grep -Fq 'hostPersistentIdentityMutationDenied=1' "$fake_run/summary.txt" \
  || fail "validated readiness did not bind the existing-only core marker"
grep -Fq 'normalProductPairingWriteAuthorized=1' "$fake_run/command.txt" \
  || fail "the private command evidence did not preserve the explicit normal-pairing authorization"

echo "android mac LAN signed-host lifecycle contract passed"
