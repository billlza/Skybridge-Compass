#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/real_device_smoke_redaction.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-real-device-redaction-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

DEVICE_ID="00008110-001C35C80E91801E"
DEVICE_LABEL="$(skybridge_smoke_hash_label "$DEVICE_ID")"
INPUT_FILE="$TMP_DIR/input.log"
OUTPUT_FILE="$TMP_DIR/output.log"
DEVICE_JSON_IN="$TMP_DIR/device-info.raw.json"
DEVICE_JSON_OUT="$TMP_DIR/device-info.redacted.json"
RAW_ARTIFACT_DIR="$TMP_DIR/raw-artifacts"
PUBLIC_ARTIFACT_DIR="$TMP_DIR/public-artifacts"
SDP_ONLY_PUBLIC_DIR="$TMP_DIR/sdp-only-public"
LONG_BASE64="QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVpBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWkFCQ0RFRkdISUpLTE1OT1A="
LONG_BASE64URL="QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVpBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWkFCQ0RFRkdISUpLTE1OT1A_"
RAW_JWT="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJwdWJsaWMtYXJ0aWZhY3Qtc2VjcmV0In0.signatureSecretValue"

cat >"$INPUT_FILE" <<EOF
==> Real device: $DEVICE_ID
{"identifier":"$DEVICE_ID","deviceProperties":{"name":"Bill's iPad"},"hardwareProperties":{"udid":"SECRET-HW-UDID","serialNumber":"SECRET-SERIAL"},"connectionProperties":{"localHostnames":["secret-ipad.local"],"potentialHostnames":["secret-alt.local"]}}
Command line invocation: /Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -project $ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj
Signing Identity:     "Apple Development: Zi ang Li (8PKXBGACNV)"
Provisioning Profile: "iOS Team Provisioning Profile: com.skybridge.compass.ios"
                      (558f8b50-2a96-4fe8-a8e2-6767dffefd40)
/usr/bin/codesign --force --sign F05D629A68B79DA893855BE83F5B782F05D873B2 --timestamp=none $TMP_DIR/Product.app
SKYBRIDGE_DEVICE_ID=$DEVICE_ID SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64=secret-key
SKYBRIDGE_SMOKE_CONNECT_LINK=skybridge://connect?token=secret-connect-link SKYBRIDGE_API_TOKEN=secret-api-token OTHER_SECRET=secret-env-value
skybridge://connect?peer=raw-connect-link&token=secret-link-token
peerPublicKey=$LONG_BASE64
EOF

skybridge_smoke_redact_stream "$DEVICE_LABEL" "$DEVICE_ID" <"$INPUT_FILE" >"$OUTPUT_FILE"

cat >"$DEVICE_JSON_IN" <<EOF
{
  "result": {
    "devices": [
      {
        "identifier": "$DEVICE_ID",
        "deviceProperties": {
          "name": "Bill's iPad"
        },
        "hardwareProperties": {
          "udid": "SECRET-HW-UDID",
          "serialNumber": "SECRET-SERIAL"
        },
        "connectionProperties": {
          "localHostnames": ["secret-ipad.local"],
          "potentialHostnames": ["secret-alt.local"]
        }
      }
    ]
  }
}
EOF
skybridge_smoke_redact_stream "$DEVICE_LABEL" "$DEVICE_ID" <"$DEVICE_JSON_IN" >"$DEVICE_JSON_OUT"
python3 -m json.tool "$DEVICE_JSON_OUT" >/dev/null

assert_contains() {
  local needle="$1"
  local output_file="${2:-$OUTPUT_FILE}"
  if ! grep -Fq -- "$needle" "$output_file"; then
    echo "Expected redacted output to contain: $needle" >&2
    cat "$output_file" >&2
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1"
  local output_file="${2:-$OUTPUT_FILE}"
  if grep -Fq -- "$needle" "$output_file"; then
    echo "Expected redacted output not to contain: $needle" >&2
    cat "$output_file" >&2
    exit 1
  fi
}

assert_contains "<ios-device-$DEVICE_LABEL>"
assert_contains "<repo>"
assert_contains "<applications>/Xcode-beta.app/Contents/Developer"
assert_contains 'Signing Identity: "<redacted-signing-identity>"'
assert_contains 'Provisioning Profile: "<redacted-provisioning-profile>"'
assert_contains "codesign --force --sign <redacted-signing-certificate>"
assert_contains "SKYBRIDGE_DEVICE_ID=<redacted>"
assert_contains "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64=<redacted>"
assert_contains "SKYBRIDGE_SMOKE_CONNECT_LINK=<redacted>"
assert_contains "SKYBRIDGE_API_TOKEN=<redacted>"
assert_contains "OTHER_SECRET=<redacted>"
assert_contains "<redacted-connect-link>"
assert_contains "peerPublicKey=<redacted-long-base64>"

for secret in \
  "$DEVICE_ID" \
  "SECRET-HW-UDID" \
  "SECRET-SERIAL" \
  "Bill's iPad" \
  "secret-ipad.local" \
  "secret-alt.local" \
  "$ROOT_DIR" \
  "$TMP_DIR" \
  "Apple Development: Zi ang Li" \
  "iOS Team Provisioning Profile: com.skybridge.compass.ios" \
  "558f8b50-2a96-4fe8-a8e2-6767dffefd40" \
  "F05D629A68B79DA893855BE83F5B782F05D873B2" \
  "secret-key" \
  "secret-connect-link" \
  "secret-api-token" \
  "secret-env-value" \
  "raw-connect-link" \
  "secret-link-token" \
  "$LONG_BASE64"
do
  assert_not_contains "$secret"
  assert_not_contains "$secret" "$DEVICE_JSON_OUT"
done

mkdir -p "$RAW_ARTIFACT_DIR"
mkdir -p "$RAW_ARTIFACT_DIR/nested/session"
cat >"$RAW_ARTIFACT_DIR/mac.status.log" <<EOF
2026-06-14T00:00:00Z identityKey=$DEVICE_ID targetDeviceId=raw-ipad-id peerId=raw-peer-id deviceId=raw-device-id p2pDeviceId=raw-p2p-id cloudDeviceId=raw-cloud-id pubKeyFP=raw-pubkey-fp fingerprint=8A6E7D5C4B3A29108A6E7D5C4B3A2910 code=123456
session=raw-session-id sessionId=raw-json-session-id trackId=raw-track-id connect ABC123 code 654321 reason=privateReasonToken
skybridge://connect?token=public-artifact-secret-token
SKYBRIDGE_API_TOKEN=public-artifact-api-token PRIVATE_KEY=public-artifact-private-key
path=$ROOT_DIR/Artifacts/private-smoke path2=$TMP_DIR/private-cache app=/Applications/Xcode-beta.app/Contents/Developer volume=/Volumes/PrivateBuilds
peerPublicKey=$LONG_BASE64
peerPublicKeyUrl=$LONG_BASE64URL
jwt=$RAW_JWT
sdp=v=0 icePwd=raw-ice-pwd-assignment iceUfrag=raw-ice-ufrag-assignment iceCandidate=raw-ice-candidate-assignment
v=0
a=ice-ufrag:raw-ice-ufrag-line
a=ice-pwd:raw-ice-pwd-line
a=candidate:1 1 UDP 2122252543 10.20.30.42 54321 typ host
EOF
cat >"$RAW_ARTIFACT_DIR/nested/session/ios.assignment.jsonl" <<EOF
{"tenantId":"tenant-secret","userIdentifier":"user-secret","userId":"user-id-secret","sub":"subject-secret","nebulaId":"nebula-secret","displayName":"Bill Device","accountDisplayName":"Bill Account","routeIdentifier":"route-secret","bonjourServiceName":"_skybridge._tcp.local.","endpointHost":"10.20.30.40","controlEndpoint":"https://control.example.invalid/private?token=secret","relay":"turn.example.invalid","endpoint":"https://endpoint.example.invalid/path","host":"host.example.invalid","ip":"10.20.30.41","address":"192.168.40.41","sessionId":"nested-session-secret","trackId":"nested-track-secret","reason":"Bearer nested-reason-token privateKey=/Users/bill/private.key","xwingPublicKey":"$LONG_BASE64URL","mlkemPublicKey":"$LONG_BASE64URL","authorization":"Bearer nested-secret-token","token":"nested-json-token","url":"https://url.example.invalid/private"}
EOF
cat >"$RAW_ARTIFACT_DIR/nested/session/mac.trace.log" <<EOF
Authorization: Bearer nested-bearer-token tenantId=tenant-secret userIdentifier=user-secret nebulaId=nebula-secret routeIdentifier=route-secret bonjourServiceName=_skybridge._tcp.local. endpointHost=10.20.30.40 controlEndpoint=https://control.example.invalid/private relay=turn.example.invalid endpoint=https://endpoint.example.invalid/path host=host.example.invalid ip=10.20.30.41 address=192.168.40.41 session=trace-session-secret trackId=trace-track-secret connect ZXCVBN code 111222 reason=traceReasonSecret xwingPublicKey=$LONG_BASE64URL mlkemPublicKey=$LONG_BASE64URL
EOF
cat >"$RAW_ARTIFACT_DIR/device-info.json" <<EOF
{"identifier":"$DEVICE_ID","deviceName":"Bill's iPad","deviceId":"raw-device-id","p2pDeviceId":"raw-p2p-id","pubKeyFP":"raw-pubkey-fp","fingerprint":"8A6E7D5C4B3A29108A6E7D5C4B3A2910","accessToken":"public-artifact-access-token","access_token":"public-artifact-snake-access-token","apiKey":"public-artifact-api-key","publicKeyBase64":"$LONG_BASE64URL","sdp":"v=0\na=ice-pwd:raw-json-ice-pwd\na=ice-ufrag:raw-json-ice-ufrag","icePwd":"raw-json-ice-pwd","ice_pwd":"raw-json-snake-ice-pwd","iceUfrag":"raw-json-ice-ufrag","iceCandidate":"candidate:1 1 UDP 2122252543 10.20.30.43 54322 typ host","local_endpoint":"10.20.30.45:7000","SelectedCandidatePair":"10.20.30.45:7000 -> 10.20.30.46:7001"}
EOF
printf 'raw binary should not be copied %s\n' "$DEVICE_ID" >"$RAW_ARTIFACT_DIR/frame.png"

mkdir -p "$SDP_ONLY_PUBLIC_DIR"
cat >"$SDP_ONLY_PUBLIC_DIR/webrtc-public.log" <<'EOF'
v=0
a=ice-ufrag:raw-public-ufrag
a=ice-pwd:raw-public-pwd
a=candidate:1 1 UDP 2122252543 10.20.30.44 54323 typ host
EOF
if skybridge_smoke_check_public_artifacts "$SDP_ONLY_PUBLIC_DIR" >/dev/null 2>&1; then
  echo "Expected raw SDP/ICE-only public artifact directory to fail public artifact scan" >&2
  exit 1
fi

EMPTY_PUBLIC_DIR="$TMP_DIR/empty-public"
mkdir -p "$EMPTY_PUBLIC_DIR"
if skybridge_smoke_check_public_artifacts "$EMPTY_PUBLIC_DIR" "$DEVICE_ID" >/dev/null 2>&1; then
  echo "Expected empty public artifact directory to fail public artifact scan" >&2
  exit 1
fi

if skybridge_smoke_materialize_public_artifacts "$DEVICE_LABEL" "$RAW_ARTIFACT_DIR" "$RAW_ARTIFACT_DIR" "$DEVICE_ID" >/dev/null 2>&1; then
  echo "Expected materializer to reject artifact_dir as public_dir" >&2
  exit 1
fi

if skybridge_smoke_check_public_artifacts "$RAW_ARTIFACT_DIR" "$DEVICE_ID" >/dev/null 2>&1; then
  echo "Expected raw artifact directory to fail public artifact scan" >&2
  exit 1
fi

if skybridge_smoke_materialize_public_artifacts "$DEVICE_LABEL" "$RAW_ARTIFACT_DIR" "$TMP_DIR/public-artifacts-with-unsupported-file" "$DEVICE_ID" >/dev/null 2>&1; then
  echo "Expected public artifact materializer to fail on unsupported file extensions" >&2
  exit 1
fi
rm -f "$RAW_ARTIFACT_DIR/frame.png"

skybridge_smoke_materialize_public_artifacts "$DEVICE_LABEL" "$RAW_ARTIFACT_DIR" "$PUBLIC_ARTIFACT_DIR" "$DEVICE_ID"
skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$DEVICE_ID"

PUBLIC_STATUS="$PUBLIC_ARTIFACT_DIR/mac.status.log"
PUBLIC_DEVICE_JSON="$PUBLIC_ARTIFACT_DIR/device-info.json"
PUBLIC_NESTED_ASSIGNMENT="$PUBLIC_ARTIFACT_DIR/nested/session/ios.assignment.jsonl"
PUBLIC_NESTED_TRACE="$PUBLIC_ARTIFACT_DIR/nested/session/mac.trace.log"
assert_contains "identityKey=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "targetDeviceId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "peerId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "deviceId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "p2pDeviceId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "cloudDeviceId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "pubKeyFP=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "session=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "sessionId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "trackId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "connect <redacted-sas-code>" "$PUBLIC_STATUS"
assert_contains "code <redacted-sas-code>" "$PUBLIC_STATUS"
assert_contains "reason=<redacted-public-artifact-value>" "$PUBLIC_STATUS"
assert_contains "fingerprint=<redacted-fingerprint>" "$PUBLIC_STATUS"
assert_contains "code=<redacted-sas-code>" "$PUBLIC_STATUS"
assert_contains "sdp=<redacted-secret>" "$PUBLIC_STATUS"
assert_contains "icePwd=<redacted-secret>" "$PUBLIC_STATUS"
assert_contains "iceUfrag=<redacted-secret>" "$PUBLIC_STATUS"
assert_contains "iceCandidate=<redacted-secret>" "$PUBLIC_STATUS"
assert_contains "<redacted-sdp>" "$PUBLIC_STATUS"
assert_contains "a=ice-pwd:<redacted>" "$PUBLIC_STATUS"
assert_contains "a=ice-ufrag:<redacted>" "$PUBLIC_STATUS"
assert_contains "a=candidate:<redacted>" "$PUBLIC_STATUS"
assert_contains "<redacted-connect-link>" "$PUBLIC_STATUS"
assert_contains "SKYBRIDGE_API_TOKEN=<redacted>" "$PUBLIC_STATUS"
assert_contains "PRIVATE_KEY=<redacted>" "$PUBLIC_STATUS"
assert_contains '"fingerprint": "<redacted-fingerprint>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"accessToken": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"access_token": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"apiKey": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"publicKeyBase64": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"sdp": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"icePwd": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"ice_pwd": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"iceUfrag": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"iceCandidate": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"local_endpoint": "<redacted-public-artifact-value>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"SelectedCandidatePair": "<redacted-public-artifact-value>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"tenantId": "<redacted-public-artifact-value>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"routeIdentifier": "<redacted-public-artifact-value>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"endpointHost": "<redacted-public-artifact-value>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"sessionId": "<redacted-identity>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"trackId": "<redacted-identity>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"reason": "<redacted-public-artifact-value>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"xwingPublicKey": "<redacted-secret>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"mlkemPublicKey": "<redacted-secret>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"authorization": "<redacted-secret>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains "Authorization: Bearer <redacted>" "$PUBLIC_NESTED_TRACE"
assert_contains "tenantId=<redacted-public-artifact-value>" "$PUBLIC_NESTED_TRACE"
assert_contains "routeIdentifier=<redacted-public-artifact-value>" "$PUBLIC_NESTED_TRACE"
assert_contains "controlEndpoint=<redacted-public-artifact-value>" "$PUBLIC_NESTED_TRACE"
assert_contains "session=<redacted-identity>" "$PUBLIC_NESTED_TRACE"
assert_contains "trackId=<redacted-identity>" "$PUBLIC_NESTED_TRACE"
assert_contains "connect <redacted-sas-code>" "$PUBLIC_NESTED_TRACE"
assert_contains "code <redacted-sas-code>" "$PUBLIC_NESTED_TRACE"
assert_contains "reason=<redacted-public-artifact-value>" "$PUBLIC_NESTED_TRACE"
[[ ! -f "$PUBLIC_ARTIFACT_DIR/frame.png" ]] || {
  echo "Expected public materializer output to exclude unsupported artifact" >&2
  exit 1
}
[[ -f "$PUBLIC_NESTED_ASSIGNMENT" && -f "$PUBLIC_NESTED_TRACE" ]] || {
  echo "Expected public materializer to preserve nested scan-eligible artifacts" >&2
  exit 1
}

for secret in \
  "$DEVICE_ID" \
  "raw-ipad-id" \
  "raw-peer-id" \
  "raw-device-id" \
  "raw-p2p-id" \
  "raw-cloud-id" \
  "raw-pubkey-fp" \
  "raw-session-id" \
  "raw-json-session-id" \
  "raw-track-id" \
  "ABC123" \
  "654321" \
  "privateReasonToken" \
  "8A6E7D5C4B3A29108A6E7D5C4B3A2910" \
  "123456" \
  "public-artifact-secret-token" \
  "public-artifact-api-token" \
  "public-artifact-private-key" \
  "public-artifact-access-token" \
  "public-artifact-snake-access-token" \
  "public-artifact-api-key" \
  "$ROOT_DIR" \
  "$TMP_DIR" \
  "/Applications/Xcode-beta.app" \
  "/Volumes/PrivateBuilds" \
  "$LONG_BASE64" \
  "$LONG_BASE64URL" \
  "$RAW_JWT" \
  "raw-ice-pwd-assignment" \
  "raw-ice-ufrag-assignment" \
  "raw-ice-candidate-assignment" \
  "raw-ice-pwd-line" \
  "raw-ice-ufrag-line" \
  "10.20.30.42" \
  "54321" \
  "raw-json-ice-pwd" \
  "raw-json-snake-ice-pwd" \
  "raw-json-ice-ufrag" \
  "10.20.30.43" \
  "10.20.30.45" \
  "10.20.30.46" \
  "54322" \
  "tenant-secret" \
  "user-secret" \
  "user-id-secret" \
  "subject-secret" \
  "nebula-secret" \
  "Bill Device" \
  "Bill Account" \
  "route-secret" \
  "_skybridge._tcp.local." \
  "10.20.30.40" \
  "10.20.30.41" \
  "192.168.40.41" \
  "control.example.invalid" \
  "endpoint.example.invalid" \
  "turn.example.invalid" \
  "host.example.invalid" \
  "nested-secret-token" \
  "nested-json-token" \
  "nested-bearer-token" \
  "nested-session-secret" \
  "nested-track-secret" \
  "nested-reason-token" \
  "trace-session-secret" \
  "trace-track-secret" \
  "ZXCVBN" \
  "111222" \
  "traceReasonSecret"
do
  assert_not_contains "$secret" "$PUBLIC_STATUS"
  assert_not_contains "$secret" "$PUBLIC_DEVICE_JSON"
  assert_not_contains "$secret" "$PUBLIC_NESTED_ASSIGNMENT"
  assert_not_contains "$secret" "$PUBLIC_NESTED_TRACE"
done

echo "real-device smoke redaction fixture passed"
