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
cat >"$RAW_ARTIFACT_DIR/mac.status.log" <<EOF
2026-06-14T00:00:00Z identityKey=$DEVICE_ID targetDeviceId=raw-ipad-id peerId=raw-peer-id deviceId=raw-device-id p2pDeviceId=raw-p2p-id cloudDeviceId=raw-cloud-id pubKeyFP=raw-pubkey-fp fingerprint=8A6E7D5C4B3A29108A6E7D5C4B3A2910 code=123456
skybridge://connect?token=public-artifact-secret-token
SKYBRIDGE_API_TOKEN=public-artifact-api-token PRIVATE_KEY=public-artifact-private-key
path=$ROOT_DIR/Artifacts/private-smoke path2=$TMP_DIR/private-cache app=/Applications/Xcode-beta.app/Contents/Developer volume=/Volumes/PrivateBuilds
peerPublicKey=$LONG_BASE64
peerPublicKeyUrl=$LONG_BASE64URL
jwt=$RAW_JWT
EOF
cat >"$RAW_ARTIFACT_DIR/device-info.json" <<EOF
{"identifier":"$DEVICE_ID","deviceName":"Bill's iPad","deviceId":"raw-device-id","p2pDeviceId":"raw-p2p-id","pubKeyFP":"raw-pubkey-fp","fingerprint":"8A6E7D5C4B3A29108A6E7D5C4B3A2910","accessToken":"public-artifact-access-token","apiKey":"public-artifact-api-key","publicKeyBase64":"$LONG_BASE64URL"}
EOF
printf 'raw binary should not be copied %s\n' "$DEVICE_ID" >"$RAW_ARTIFACT_DIR/frame.png"

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

skybridge_smoke_materialize_public_artifacts "$DEVICE_LABEL" "$RAW_ARTIFACT_DIR" "$PUBLIC_ARTIFACT_DIR" "$DEVICE_ID"
skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$DEVICE_ID"

PUBLIC_STATUS="$PUBLIC_ARTIFACT_DIR/mac.status.log"
PUBLIC_DEVICE_JSON="$PUBLIC_ARTIFACT_DIR/device-info.json"
assert_contains "identityKey=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "targetDeviceId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "peerId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "deviceId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "p2pDeviceId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "cloudDeviceId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "pubKeyFP=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "fingerprint=<redacted-fingerprint>" "$PUBLIC_STATUS"
assert_contains "code=<redacted-sas-code>" "$PUBLIC_STATUS"
assert_contains "<redacted-connect-link>" "$PUBLIC_STATUS"
assert_contains "SKYBRIDGE_API_TOKEN=<redacted>" "$PUBLIC_STATUS"
assert_contains "PRIVATE_KEY=<redacted>" "$PUBLIC_STATUS"
assert_contains '"fingerprint": "<redacted-fingerprint>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"accessToken": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"apiKey": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"publicKeyBase64": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
[[ ! -f "$PUBLIC_ARTIFACT_DIR/frame.png" ]] || {
  echo "Expected public materializer to skip non-text artifact" >&2
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
  "8A6E7D5C4B3A29108A6E7D5C4B3A2910" \
  "123456" \
  "public-artifact-secret-token" \
  "public-artifact-api-token" \
  "public-artifact-private-key" \
  "public-artifact-access-token" \
  "public-artifact-api-key" \
  "$ROOT_DIR" \
  "$TMP_DIR" \
  "/Applications/Xcode-beta.app" \
  "/Volumes/PrivateBuilds" \
  "$LONG_BASE64" \
  "$LONG_BASE64URL" \
  "$RAW_JWT"
do
  assert_not_contains "$secret" "$PUBLIC_STATUS"
  assert_not_contains "$secret" "$PUBLIC_DEVICE_JSON"
done

echo "real-device smoke redaction fixture passed"
