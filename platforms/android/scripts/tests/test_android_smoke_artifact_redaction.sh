#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/scripts/lib/android_env.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-android-redaction-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

RAW_ARTIFACT_DIR="$TMP_DIR/raw-artifacts"
PUBLIC_ARTIFACT_DIR="$TMP_DIR/public-redacted"
DEVICE_SERIAL="emulator-5554"
LONG_BASE64="QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVpBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWkFCQ0RFRkdISUpLTE1OT1A="
RAW_JWT="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhbmRyb2lkLXNtb2tlLXNlY3JldCJ9.signatureSecretValue"

mkdir -p "$RAW_ARTIFACT_DIR/nested/session"

cat >"$RAW_ARTIFACT_DIR/android-status.log" <<EOF
session=raw-session-id-0123456789abcdef operation=raw-operation-id-abcdef0123456789 session=raw-session-id-0123456789abcdef session=123456 sessionId=raw-session-json-2468ace013579bdf trackId=raw-track-id-fedcba9876543210 peerId=raw-peer-id localDeviceId=raw-local-id cloudDeviceId=raw-cloud-id stablePeerId=raw-stable-id targetDeviceId=raw-target-id
Authorization: Bearer raw-bearer-token accessToken=raw-access refreshToken=raw-refresh apiKey=raw-api clientSecret=raw-client privateKey=raw-private
connect ABC123 code 123456 connectionCode=PAIR42 sasCode=654321 reason=privateReasonToken endpointHost=10.20.30.40 controlEndpoint=https://control.example.invalid/private?token=secret path=$TMP_DIR/private-cache file=/data/user/0/com.skybridge.compass.debug/files/private.txt
deviceName=Bill Android Phone accountLabel=Bill Personal Account ssid=SkyBridge Lab WiFi bssid=12:34:56:78:9A:BC
bare IPv4 endpoint 192.0.2.44:51820 bracketed IPv6 endpoint [2001:db8::44]:51820 scoped IPv6 endpoint fe80::44%wlan0
stun:stun.example.invalid:3478
candidate:1 1 UDP 2122260223 host-candidate.example.invalid 54321 typ host
a=ice-ufrag:rawUfragValue
a=ice-pwd:rawIcePassword
v=0
o=- 123456 2 IN IP4 192.0.2.45
c=IN IP6 2001:db8::45
m=application 9 UDP/DTLS/SCTP webrtc-datachannel
ssid_ref=ref:deadbeefcafe endpoint_ref=ref:feedfacecafe deviceId_ref=ref:cafebabefeed
peerPublicKey=$LONG_BASE64 jwt=$RAW_JWT
EOF

cat >"$RAW_ARTIFACT_DIR/nested/session/instrumentation.jsonl" <<EOF
{"accessToken":"raw-json-access","refreshToken":"raw-json-refresh","apiKey":"raw-json-api","privateKey":"raw-json-private","sessionId":"raw-json-session","trackId":"raw-json-track","tenantId":"tenant-secret","userIdentifier":"user-secret","displayName":"Bill Device","routeIdentifier":"route-secret","endpointHost":"10.20.30.41","controlEndpoint":"https://control-json.example.invalid/private","sas":123456,"xwingPublicKeyBase64":"$LONG_BASE64","mlkemPublicKeyBase64":"$LONG_BASE64","reason":"Bearer nested-reason-token /Users/bill/private.key","url":"https://url.example.invalid/private"}
EOF

printf 'binary should not be copied %s\n' "$DEVICE_SERIAL" >"$RAW_ARTIFACT_DIR/frame.png"

fail() {
  echo "[test-android-smoke-artifact-redaction] $1" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local output_file="$2"
  grep -Fq -- "$needle" "$output_file" || {
    echo "Expected output to contain: $needle" >&2
    cat "$output_file" >&2
    exit 1
  }
}

assert_not_contains() {
  local needle="$1"
  local output_file="$2"
  if grep -Fq -- "$needle" "$output_file"; then
    echo "Expected output not to contain: $needle" >&2
    cat "$output_file" >&2
    exit 1
  fi
}

assert_public_scan_rejects() {
  local label="$1"
  local payload="$2"
  local fixture_dir="$TMP_DIR/reject-$label"

  mkdir -p "$fixture_dir"
  printf '%s\n' "$payload" >"$fixture_dir/public.log"
  if android_smoke_check_public_artifacts "$fixture_dir" >/dev/null 2>&1; then
    fail "public scanner must reject $label"
  fi
}

assert_public_scan_rejects "ipv4" "selected endpoint 192.0.2.99:443"
assert_public_scan_rejects "bracketed-ipv6" "selected endpoint [2001:db8::99]:443"
assert_public_scan_rejects "bare-ipv6" "selected endpoint fe80::99%wlan0"
assert_public_scan_rejects "ice-candidate" "candidate:1 1 UDP 2122260223 host.example.invalid 50000 typ host"
assert_public_scan_rejects "ice-ufrag" "a=ice-ufrag:rawPublicUfrag"
assert_public_scan_rejects "ice-pwd" "a=ice-pwd:rawPublicPassword"
assert_public_scan_rejects "sdp" "m=application 9 UDP/DTLS/SCTP webrtc-datachannel"
assert_public_scan_rejects "ice-uri" "stun:stun.example.invalid:3478"
assert_public_scan_rejects "enumerable-label-ref" "ssid_ref=ref:deadbeefcafe"

if android_smoke_check_public_artifacts "$RAW_ARTIFACT_DIR" "$DEVICE_SERIAL" >/dev/null 2>&1; then
  fail "raw artifact directory must fail public scan"
fi

if android_smoke_materialize_public_artifacts "$RAW_ARTIFACT_DIR" "$RAW_ARTIFACT_DIR" >/dev/null 2>&1; then
  fail "materializer must reject artifact_dir as public_dir"
fi

android_smoke_materialize_public_artifacts "$RAW_ARTIFACT_DIR" "$PUBLIC_ARTIFACT_DIR"
android_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$DEVICE_SERIAL"

[[ "$(redact_smoke_artifact_url 'wss://signal.example.invalid/private')" == "<redacted-endpoint>" ]] || {
  fail "artifact URL redaction must use a non-correlatable endpoint constant"
}

PUBLIC_STATUS="$PUBLIC_ARTIFACT_DIR/android-status.log"
PUBLIC_JSON="$PUBLIC_ARTIFACT_DIR/nested/session/instrumentation.jsonl"

[[ -f "$PUBLIC_STATUS" && -f "$PUBLIC_JSON" ]] || fail "nested scan-eligible artifacts were not materialized"
[[ ! -f "$PUBLIC_ARTIFACT_DIR/frame.png" ]] || fail "non-text artifacts must not be copied"

assert_contains "session_ref=ref:" "$PUBLIC_STATUS"
assert_contains "session_ref=<redacted-correlation>" "$PUBLIC_STATUS"
assert_contains "operation_ref=ref:" "$PUBLIC_STATUS"
assert_contains "trackId_ref=ref:" "$PUBLIC_STATUS"
assert_contains "localDeviceId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "Authorization: Bearer <redacted>" "$PUBLIC_STATUS"
assert_contains "accessToken=<redacted>" "$PUBLIC_STATUS"
assert_contains "connect <redacted-code>" "$PUBLIC_STATUS"
assert_contains "code <redacted-code>" "$PUBLIC_STATUS"
assert_contains "connectionCode=<redacted-code>" "$PUBLIC_STATUS"
assert_contains "sasCode=<redacted-code>" "$PUBLIC_STATUS"
assert_contains "deviceName=<redacted-label>" "$PUBLIC_STATUS"
assert_contains "accountLabel=<redacted-label>" "$PUBLIC_STATUS"
assert_contains "ssid=<redacted-label>" "$PUBLIC_STATUS"
assert_contains "controlEndpoint=<redacted-endpoint>" "$PUBLIC_STATUS"
assert_contains "path=<redacted-path>" "$PUBLIC_STATUS"
assert_contains "file=<redacted-path>" "$PUBLIC_STATUS"
assert_contains "<redacted-ip-endpoint>" "$PUBLIC_STATUS"
assert_contains "candidate:<redacted>" "$PUBLIC_STATUS"
assert_contains "a=ice-secret:<redacted>" "$PUBLIC_STATUS"
assert_contains "<redacted-sdp>" "$PUBLIC_STATUS"
assert_contains '"accessToken":"<redacted>"' "$PUBLIC_JSON"
assert_contains '"sessionId":"<redacted>"' "$PUBLIC_JSON"
assert_contains '"tenantId":"<redacted>"' "$PUBLIC_JSON"
assert_contains '"sas":"<redacted>"' "$PUBLIC_JSON"
assert_contains '"xwingPublicKeyBase64":"<redacted>"' "$PUBLIC_JSON"
assert_contains '"reason":"<redacted>"' "$PUBLIC_JSON"

SESSION_REF="$(grep -o 'session_ref=ref:[0-9a-f]*' "$PUBLIC_STATUS" | head -n 1)"
[[ -n "$SESSION_REF" ]] || fail "session reference was not preserved"
SESSION_REF_COUNT="$(grep -Fo -- "$SESSION_REF" "$PUBLIC_STATUS" | wc -l | tr -d '[:space:]')"
[[ "$SESSION_REF_COUNT" -eq 2 ]] || {
  fail "equal high-entropy session values must retain one stable public reference"
}

assert_not_contains "ssid_ref=ref:" "$PUBLIC_STATUS"
assert_not_contains "endpoint_ref=ref:" "$PUBLIC_STATUS"
assert_not_contains "deviceId_ref=ref:" "$PUBLIC_STATUS"
assert_not_contains "<redacted-url:ref:" "$PUBLIC_STATUS"

for secret in \
  "$DEVICE_SERIAL" \
  "raw-session-id-0123456789abcdef" \
  "raw-operation-id-abcdef0123456789" \
  "raw-session-json-2468ace013579bdf" \
  "raw-track-id-fedcba9876543210" \
  "raw-peer-id" \
  "raw-local-id" \
  "raw-cloud-id" \
  "raw-stable-id" \
  "raw-target-id" \
  "raw-bearer-token" \
  "raw-access" \
  "raw-refresh" \
  "raw-api" \
  "raw-client" \
  "raw-private" \
  "ABC123" \
  "123456" \
  "PAIR42" \
  "654321" \
  "privateReasonToken" \
  "10.20.30.40" \
  "Bill Android Phone" \
  "Bill Personal Account" \
  "SkyBridge Lab WiFi" \
  "12:34:56:78:9A:BC" \
  "192.0.2.44" \
  "2001:db8::44" \
  "fe80::44" \
  "stun.example.invalid" \
  "host-candidate.example.invalid" \
  "rawUfragValue" \
  "rawIcePassword" \
  "control.example.invalid" \
  "$TMP_DIR" \
  "/data/user/0/com.skybridge.compass.debug" \
  "$LONG_BASE64" \
  "$RAW_JWT" \
  "raw-json-access" \
  "raw-json-refresh" \
  "raw-json-api" \
  "raw-json-private" \
  "raw-json-session" \
  "raw-json-track" \
  "tenant-secret" \
  "user-secret" \
  "Bill Device" \
  "route-secret" \
  "10.20.30.41" \
  "control-json.example.invalid" \
  "nested-reason-token" \
  "url.example.invalid"
do
  assert_not_contains "$secret" "$PUBLIC_STATUS"
  assert_not_contains "$secret" "$PUBLIC_JSON"
done

echo "android smoke artifact redaction fixture passed"
