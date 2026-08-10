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
LAUNCH_JSON_IN="$TMP_DIR/ios-launch.raw.json"
LAUNCH_JSON_OUT="$TMP_DIR/ios-launch.redacted.json"
RAW_ARTIFACT_DIR="$TMP_DIR/raw-artifacts"
PUBLIC_ARTIFACT_DIR="$TMP_DIR/public-artifacts"
SDP_ONLY_PUBLIC_DIR="$TMP_DIR/sdp-only-public"
LONG_BASE64="QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVpBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWkFCQ0RFRkdISUpLTE1OT1A="
LONG_BASE64URL="QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVpBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWkFCQ0RFRkdISUpLTE1OT1A_"
RAW_JWT="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJwdWJsaWMtYXJ0aWZhY3Qtc2VjcmV0In0.signatureSecretValue"
RAW_TARGET_UUID="068F43C8-5CAE-4C4B-BEF0-0BA4233ECB18"
RAW_TARGET_UUID_LOWER="$(printf '%s' "$RAW_TARGET_UUID" | tr '[:upper:]' '[:lower:]')"
RAW_TRANSFER_UUID="A5918D50-F124-448B-88A8-AB21BD8BE2C1"
RAW_SENDER_UUID="07CB9A6E-7492-4680-9DD7-F37DC8568891"
RAW_HANDSHAKE_SESSION_ID="hs-64a7aba386ff52fe3adf4b5ce7541334"
RAW_PRIVATE_ENDPOINT="192.168.0.102:8080"
RAW_ULA_IPV6="fd01:8350:5591::1"
RAW_LINK_LOCAL_IPV6="fe80::aede:48ff:fe00:1122%en0"
RAW_LOOPBACK_IPV6="::1"
RAW_BRACKETED_IPV6="[fd00:1234::99]:9527"
RAW_EXPANDED_IPV6="fd00:0000:0000:0000:0000:0000:0000:0042"
RAW_PROFILE_UUID="a3d2b9e0-2f60-41dd-9548-ffdfd1a6faeb"

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

cat >"$LAUNCH_JSON_IN" <<EOF
{
  "info": {
    "arguments": [
      "devicectl",
      "device",
      "process",
      "launch",
      "--json-output",
      "$TMP_DIR/ios-launch.json",
      "{\"SKYBRIDGE_SMOKE_TARGET_DEVICE_ID\":\"$DEVICE_ID\",\"SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64\":\"$LONG_BASE64\"}"
    ]
  },
  "result": {"processIdentifier": 4242}
}
EOF
skybridge_smoke_redact_stream "$DEVICE_LABEL" "$DEVICE_ID" <"$LAUNCH_JSON_IN" >"$LAUNCH_JSON_OUT"
python3 -m json.tool "$LAUNCH_JSON_OUT" >/dev/null

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

assert_not_contains "$TMP_DIR" "$LAUNCH_JSON_OUT"
assert_not_contains "$DEVICE_ID" "$LAUNCH_JSON_OUT"

for safe_run_id in \
  "20260710T181500" \
  "release-device_01.2" \
  "a$(printf 'b%.0s' {1..63})"
do
  if ! skybridge_smoke_require_safe_run_id "$safe_run_id" TEST_RUN_ID >/dev/null 2>&1; then
    echo "Expected safe smoke run ID to be accepted: $safe_run_id" >&2
    exit 1
  fi
done

for unsafe_run_id in \
  "" \
  "." \
  "-leading-option" \
  "../escape" \
  "nested/path" \
  "contains space" \
  $'contains\ttab' \
  $'contains\nnewline' \
  "unicode-设备" \
  "a$(printf 'b%.0s' {1..64})"
do
  if skybridge_smoke_require_safe_run_id "$unsafe_run_id" TEST_RUN_ID >/dev/null 2>&1; then
    echo "Expected unsafe smoke run ID to be rejected: $unsafe_run_id" >&2
    exit 1
  fi
done

assert_unsafe_run_id_fails_before_smoke_setup() {
  local script_path="$1"
  local variable_name="$2"
  local output
  local status

  set +e
  output="$(env "${variable_name}=../escape" bash "$script_path" 2>&1)"
  status=$?
  set -e

  if [[ "$status" -ne 2 ]]; then
    echo "Expected $script_path to reject an unsafe run ID with exit 2; got $status" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$variable_name must be 1-64 characters"* ]]; then
    echo "Expected $script_path to report the rejected run-ID variable" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

assert_unsafe_run_id_fails_before_smoke_setup \
  "$ROOT_DIR/Scripts/run_real_device_webrtc_smoke.sh" \
  SKYBRIDGE_SMOKE_WEBRTC_RUN_ID
assert_unsafe_run_id_fails_before_smoke_setup \
  "$ROOT_DIR/Scripts/run_real_device_file_transfer_smoke.sh" \
  SKYBRIDGE_SMOKE_FILE_TRANSFER_RUN_ID

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
release-session-binding sessionRef=abcdefabcdefabcdefabcdef release_session_ref=abcdefabcdefabcdefabcdef
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
remote-control-notice-identity account=Bill Public Artifact nebula=nebula-direct-secret device=device-direct-secret
noticeAccount=notice-account-secret noticeNebula=notice-nebula-secret remoteAccount=remote-account-secret remoteNebula=remote-nebula-secret localAccount=local-account-secret localNebula=local-nebula-secret
stable-identities device=Bill's Office iPad dedupeKey=dedupe-secret declaredDeviceId=declared-device-secret stablePeer=stable-peer-secret peer=peer-secret keyId=key-id-secret uniqueIdentifier=unique-id-secret requesterProtocolIdentity=requester-identity-secret pinnedProtocolIdentity=pinned-identity-secret remoteIP=203.0.113.42
peerPublicKey=short-peer-public-key-secret publicKey=short-public-key-secret kemPublicKey=short-kem-public-key-secret
signingFingerprint=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef signingIdentity=Developer-ID provisioningProfile=private-profile provisioningProfileUUID=private-profile-uuid teamIdentifier=PRIVATE-TEAM-ID
boot role=ios-p2p-client target=$RAW_TARGET_UUID name=Personal MacBook Pro
discovered count=1 peers=id:$RAW_TARGET_UUID_LOWER|Personal MacBook Pro
target id=id:$RAW_TARGET_UUID_LOWER name=Personal MacBook Pro
control-route evidence liveEndpointCount=2 eligibleEndpointCount=1 ignoredLiveEndpointCount=1 liveRoutes=service[Personal MacBook Pro|_skybridge._tcp|local.|awdl0] eligibleRoutes=service[Personal MacBook Pro (2)|_skybridge._tcp|local.|awdl0]
refresh candidates=$RAW_TARGET_UUID,$RAW_TARGET_UUID_LOWER,Personal MacBook Pro clearedKEM=1
file-transfer-route-ready requested=$RAW_PRIVATE_ENDPOINT resolved=$RAW_PRIVATE_ENDPOINT requestedAddressClass=lan-direct resolvedAddressClass=lan-direct resolvedPeerToPeer=false
handshake-state established(sessionKeys: SessionKeys(sessionId: "$RAW_HANDSHAKE_SESSION_ID", negotiatedSuite: X-Wing))
file-transfer metadata-received transfer=$RAW_TRANSFER_UUID sender=$RAW_SENDER_UUID name=ios-smoke.txt bytes=102
network-topology ula=$RAW_ULA_IPV6 linkLocal=$RAW_LINK_LOCAL_IPV6 loopback=$RAW_LOOPBACK_IPV6 bracketed=$RAW_BRACKETED_IPV6 expanded=$RAW_EXPANDED_IPV6
ProcessProductPackaging <home>/Library/Developer/Xcode/UserData/Provisioning\ Profiles/$RAW_PROFILE_UUID.mobileprovision <tmp>
safe-fields -fmodule-name=CQPeriapt --target=arm64 --requested=diagnostic --resolved=cached filename=diagnostic.log requestedAddressClass=lan-direct resolvedAddressClass=lan-direct resolvedPeerToPeer=false testNet=198.51.100.8:443
EOF
cat >"$RAW_ARTIFACT_DIR/nested/session/ios.assignment.jsonl" <<EOF
{"tenantId":"tenant-secret","userIdentifier":"user-secret","userId":"user-id-secret","sub":"subject-secret","nebulaId":"nebula-secret","displayName":"Bill Device","accountDisplayName":"Bill Account","routeIdentifier":"route-secret","bonjourServiceName":"_skybridge._tcp.local.","endpointHost":"10.20.30.40","controlEndpoint":"https://control.example.invalid/private?token=secret","relay":"turn.example.invalid","endpoint":"https://endpoint.example.invalid/path","host":"host.example.invalid","ip":"10.20.30.41","address":"192.168.40.41","sessionId":"nested-session-secret","trackId":"nested-track-secret","reason":"Bearer nested-reason-token privateKey=/Users/bill/private.key","xwingPublicKey":"$LONG_BASE64URL","mlkemPublicKey":"$LONG_BASE64URL","authorization":"Bearer nested-secret-token","token":"nested-json-token","url":"https://url.example.invalid/private"}
EOF
cat >"$RAW_ARTIFACT_DIR/nested/session/mac.trace.log" <<EOF
Authorization: Bearer nested-bearer-token tenantId=tenant-secret userIdentifier=user-secret nebulaId=nebula-secret routeIdentifier=route-secret bonjourServiceName=_skybridge._tcp.local. endpointHost=10.20.30.40 controlEndpoint=https://control.example.invalid/private relay=turn.example.invalid endpoint=https://endpoint.example.invalid/path host=host.example.invalid ip=10.20.30.41 address=192.168.40.41 session=trace-session-secret trackId=trace-track-secret connect ZXCVBN code 111222 reason=traceReasonSecret xwingPublicKey=$LONG_BASE64URL mlkemPublicKey=$LONG_BASE64URL
EOF
cat >"$RAW_ARTIFACT_DIR/nested/session/multi.assignment.jsonl" <<'EOF'
{"account":"jsonl-account-secret","device":"jsonl-device-secret","dedupeKey":"jsonl-dedupe-secret"}
{"nebula":"jsonl-nebula-secret","remoteAccount":"jsonl-remote-account-secret","localNebulaId":"jsonl-local-nebula-secret","uniqueIdentifier":"jsonl-unique-secret","peer":"jsonl-peer-secret"}
EOF
cat >"$RAW_ARTIFACT_DIR/device-info.json" <<EOF
{"identifier":"$DEVICE_ID","deviceName":"Bill's iPad","deviceId":"raw-device-id","p2pDeviceId":"raw-p2p-id","pubKeyFP":"raw-pubkey-fp","fingerprint":"8A6E7D5C4B3A29108A6E7D5C4B3A2910","accessToken":"public-artifact-access-token","access_token":"public-artifact-snake-access-token","apiKey":"public-artifact-api-key","publicKey":"short-json-public-key-secret","publicKeyBase64":"$LONG_BASE64URL","account":"json-account-secret","nebula":"json-nebula-secret","signingFingerprint":"json-signing-fingerprint-secret","provisioningProfile":"json-profile-secret","sdp":"v=0\na=ice-pwd:raw-json-ice-pwd\na=ice-ufrag:raw-json-ice-ufrag","icePwd":"raw-json-ice-pwd","ice_pwd":"raw-json-snake-ice-pwd","iceUfrag":"raw-json-ice-ufrag","iceCandidate":"candidate:1 1 UDP 2122252543 10.20.30.43 54322 typ host","local_endpoint":"10.20.30.45:7000","SelectedCandidatePair":"10.20.30.45:7000 -> 10.20.30.46:7001","tunnelIPAddress":"$RAW_ULA_IPV6","tunnelIPAddressString":"$RAW_ULA_IPV6","nested":{"addresses":["$RAW_LINK_LOCAL_IPV6","$RAW_BRACKETED_IPV6"]}}
EOF
cat >"$RAW_ARTIFACT_DIR/ios-launch.json" <<EOF
{"info":{"arguments":["devicectl","--json-output","$TMP_DIR/ios-launch.json","{\"SKYBRIDGE_DEVICE_ID\":\"raw-argument-device-id\",\"SKYBRIDGE_ACCESS_TOKEN\":\"raw-argument-access-token\"}"]},"result":{"process":{"processIdentifier":4242,"auditToken":[1,2,3,4,5,6,7,8]},"environmentVariables":{"SKYBRIDGE_ACCESS_TOKEN":"raw-prefixed-access-token","SKYBRIDGE_DEVICE_ID":"raw-prefixed-device-id","SKYBRIDGE_NEBULA_ID":"raw-prefixed-nebula-id"}}}
EOF
cat >"$RAW_ARTIFACT_DIR/host.auth-session.json" <<'EOF'
{"accessToken":"private-host-access-token","refreshToken":"private-host-refresh-token","userIdentifier":"private-host-user"}
EOF
printf 'raw binary should not be copied %s\n' "$DEVICE_ID" >"$RAW_ARTIFACT_DIR/frame.png"
printf 'unsupported artifact should fail %s\n' "$DEVICE_ID" >"$RAW_ARTIFACT_DIR/unsupported.blob"

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

GUARD_ROOT="$TMP_DIR/materializer-guard"
GUARD_RAW_DIR="$GUARD_ROOT/raw"
mkdir -p "$GUARD_RAW_DIR"
printf '%s\n' 'safe smoke evidence' >"$GUARD_RAW_DIR/evidence.log"

if skybridge_smoke_materialize_public_artifacts "$DEVICE_LABEL" "$GUARD_RAW_DIR" "$GUARD_ROOT" "$DEVICE_ID" >/dev/null 2>&1; then
  echo "Expected materializer to reject a public directory that is an ancestor of raw artifacts" >&2
  exit 1
fi
assert_contains 'safe smoke evidence' "$GUARD_RAW_DIR/evidence.log"

if skybridge_smoke_materialize_public_artifacts "$DEVICE_LABEL" "$GUARD_RAW_DIR" "$GUARD_RAW_DIR/public" "$DEVICE_ID" >/dev/null 2>&1; then
  echo "Expected materializer to reject a public directory nested under raw artifacts" >&2
  exit 1
fi

SYMLINK_TARGET="$TMP_DIR/materializer-symlink-target"
SYMLINK_PUBLIC="$TMP_DIR/materializer-public-symlink"
mkdir -p "$SYMLINK_TARGET"
printf '%s\n' 'symlink target sentinel' >"$SYMLINK_TARGET/sentinel.log"
ln -s "$SYMLINK_TARGET" "$SYMLINK_PUBLIC"
if skybridge_smoke_materialize_public_artifacts "$DEVICE_LABEL" "$GUARD_RAW_DIR" "$SYMLINK_PUBLIC" "$DEVICE_ID" >/dev/null 2>&1; then
  echo "Expected materializer to reject a symlink public directory" >&2
  exit 1
fi
assert_contains 'symlink target sentinel' "$SYMLINK_TARGET/sentinel.log"

UNOWNED_PUBLIC_DIR="$TMP_DIR/materializer-unowned-public"
mkdir -p "$UNOWNED_PUBLIC_DIR"
printf '%s\n' 'unowned sentinel' >"$UNOWNED_PUBLIC_DIR/sentinel.log"
if skybridge_smoke_materialize_public_artifacts "$DEVICE_LABEL" "$GUARD_RAW_DIR" "$UNOWNED_PUBLIC_DIR" "$DEVICE_ID" >/dev/null 2>&1; then
  echo "Expected materializer to reject replacing an unowned directory" >&2
  exit 1
fi
assert_contains 'unowned sentinel' "$UNOWNED_PUBLIC_DIR/sentinel.log"

OWNED_PUBLIC_DIR="$TMP_DIR/materializer-owned-public"
skybridge_smoke_materialize_public_artifacts "$DEVICE_LABEL" "$GUARD_RAW_DIR" "$OWNED_PUBLIC_DIR" "$DEVICE_ID"
assert_contains 'safe smoke evidence' "$OWNED_PUBLIC_DIR/evidence.log"
assert_contains 'skybridge-public-smoke-artifacts' "$OWNED_PUBLIC_DIR/skybridge-public-artifacts.json"
printf '%s\n' 'unsupported replacement input' >"$GUARD_RAW_DIR/unsupported.blob"
if skybridge_smoke_materialize_public_artifacts "$DEVICE_LABEL" "$GUARD_RAW_DIR" "$OWNED_PUBLIC_DIR" "$DEVICE_ID" >/dev/null 2>&1; then
  echo "Expected failed replacement to leave the prior public directory intact" >&2
  exit 1
fi
assert_contains 'safe smoke evidence' "$OWNED_PUBLIC_DIR/evidence.log"
rm -f "$GUARD_RAW_DIR/unsupported.blob"

if skybridge_smoke_check_public_artifacts "$RAW_ARTIFACT_DIR" "$DEVICE_ID" >/dev/null 2>&1; then
  echo "Expected raw artifact directory to fail public artifact scan" >&2
  exit 1
fi

PREFIXED_ENV_PUBLIC_DIR="$TMP_DIR/prefixed-env-public"
mkdir -p "$PREFIXED_ENV_PUBLIC_DIR"
cp "$RAW_ARTIFACT_DIR/ios-launch.json" "$PREFIXED_ENV_PUBLIC_DIR/ios-launch.json"
if skybridge_smoke_check_public_artifacts "$PREFIXED_ENV_PUBLIC_DIR" >/dev/null 2>&1; then
  echo "Expected public artifact scanner to reject prefixed secret and identity JSON keys" >&2
  exit 1
fi

MALFORMED_JSON_PUBLIC_DIR="$TMP_DIR/malformed-json-public"
mkdir -p "$MALFORMED_JSON_PUBLIC_DIR"
printf '%s\n' '{"result":"truncated"' >"$MALFORMED_JSON_PUBLIC_DIR/ios-launch.json"
if skybridge_smoke_check_public_artifacts "$MALFORMED_JSON_PUBLIC_DIR" >/dev/null 2>&1; then
  echo "Expected public artifact scanner to reject malformed structured JSON" >&2
  exit 1
fi

if skybridge_smoke_materialize_public_artifacts "$DEVICE_LABEL" "$RAW_ARTIFACT_DIR" "$TMP_DIR/public-artifacts-with-unsupported-file" "$DEVICE_ID" >/dev/null 2>&1; then
  echo "Expected public artifact materializer to fail on unsupported file extensions" >&2
  exit 1
fi
rm -f "$RAW_ARTIFACT_DIR/unsupported.blob"

FORBIDDEN_AUTH_PUBLIC_DIR="$TMP_DIR/forbidden-auth-public"
mkdir -p "$FORBIDDEN_AUTH_PUBLIC_DIR"
cat >"$FORBIDDEN_AUTH_PUBLIC_DIR/host.auth-session.json" <<'EOF'
{"accessToken":"<redacted-secret>"}
EOF
if skybridge_smoke_check_public_artifacts "$FORBIDDEN_AUTH_PUBLIC_DIR" >/dev/null 2>&1; then
  echo "Expected public artifact scanner to reject auth-session containers by filename" >&2
  exit 1
fi

RAW_IDENTITY_PUBLIC_DIR="$TMP_DIR/raw-identity-public"
mkdir -p "$RAW_IDENTITY_PUBLIC_DIR"
cat >"$RAW_IDENTITY_PUBLIC_DIR/identity.log" <<'EOF'
device=Personal iPad dedupeKey=raw-dedupe uniqueIdentifier=raw-unique remoteIP=203.0.113.99
EOF
if skybridge_smoke_check_public_artifacts "$RAW_IDENTITY_PUBLIC_DIR" >/dev/null 2>&1; then
  echo "Expected public artifact scanner to reject device labels and stable identifiers" >&2
  exit 1
fi

assert_public_scanner_rejects_fixture() {
  local label="$1"
  local leaked_line="$2"
  local fixture_dir="$TMP_DIR/scanner-reject-$label"
  mkdir -p "$fixture_dir"
  printf '%s\n' "$leaked_line" >"$fixture_dir/leak.log"
  if skybridge_smoke_check_public_artifacts "$fixture_dir" >/dev/null 2>&1; then
    echo "Expected public artifact scanner to reject leak fixture: $label" >&2
    exit 1
  fi
}

assert_public_scanner_rejects_fixture \
  "bare-name" \
  "boot role=ios-p2p-client name=Personal MacBook Pro"
assert_public_scanner_rejects_fixture \
  "requested-endpoint" \
  "route-ready requested=$RAW_PRIVATE_ENDPOINT"
assert_public_scanner_rejects_fixture \
  "resolved-endpoint" \
  "route-ready resolved=$RAW_PRIVATE_ENDPOINT"
assert_public_scanner_rejects_fixture \
  "sender-identity" \
  "metadata sender=$RAW_SENDER_UUID"
assert_public_scanner_rejects_fixture \
  "transfer-identity" \
  "metadata transfer=$RAW_TRANSFER_UUID"
assert_public_scanner_rejects_fixture \
  "swift-session-id" \
  "SessionKeys(sessionId: \"$RAW_HANDSHAKE_SESSION_ID\")"
assert_public_scanner_rejects_fixture \
  "unlabelled-private-endpoint" \
  "route-ready $RAW_PRIVATE_ENDPOINT"
assert_public_scanner_rejects_fixture \
  "ula-ipv6" \
  "tunnel $RAW_ULA_IPV6"
assert_public_scanner_rejects_fixture \
  "link-local-ipv6-zone" \
  "interface $RAW_LINK_LOCAL_IPV6"
assert_public_scanner_rejects_fixture \
  "loopback-ipv6" \
  "listener $RAW_LOOPBACK_IPV6"
assert_public_scanner_rejects_fixture \
  "bracketed-ipv6-port" \
  "endpoint $RAW_BRACKETED_IPV6"
assert_public_scanner_rejects_fixture \
  "expanded-ipv6" \
  "endpoint $RAW_EXPANDED_IPV6"
assert_public_scanner_rejects_fixture \
  "identity-list" \
  "discovered peers=id:$RAW_TARGET_UUID_LOWER|Personal MacBook Pro"
assert_public_scanner_rejects_fixture \
  "route-summary-service-name" \
  "control-route liveRoutes=service[Personal MacBook Pro|_skybridge._tcp|local.|awdl0]"
assert_public_scanner_rejects_fixture \
  "shorthand-identity" \
  "target id=id:$RAW_TARGET_UUID_LOWER"
assert_public_scanner_rejects_fixture \
  "provisioning-profile-path" \
  "Provisioning\\ Profiles/$RAW_PROFILE_UUID.mobileprovision"

SAFE_FIELDS_PUBLIC_DIR="$TMP_DIR/safe-fields-public"
mkdir -p "$SAFE_FIELDS_PUBLIC_DIR"
cat >"$SAFE_FIELDS_PUBLIC_DIR/safe.log" <<'EOF'
compiler -fmodule-name=CQPeriapt --target=arm64 --requested=diagnostic --resolved=cached filename=diagnostic.log
route requestedAddressClass=lan-direct resolvedAddressClass=lan-direct resolvedPeerToPeer=false
network testNet=198.51.100.8:443 transferCount=1 senderRole=responder
timestamp 2026-07-26T22:23:41.337Z sha256:c52ea764fc00 version=1.2.3 clock=22:23:41
EOF
skybridge_smoke_check_public_artifacts "$SAFE_FIELDS_PUBLIC_DIR"

skybridge_smoke_materialize_public_artifacts "$DEVICE_LABEL" "$RAW_ARTIFACT_DIR" "$PUBLIC_ARTIFACT_DIR" "$DEVICE_ID"
skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$DEVICE_ID"

PUBLIC_STATUS="$PUBLIC_ARTIFACT_DIR/mac.status.log"
PUBLIC_DEVICE_JSON="$PUBLIC_ARTIFACT_DIR/device-info.json"
PUBLIC_LAUNCH_JSON="$PUBLIC_ARTIFACT_DIR/ios-launch.json"
PUBLIC_NESTED_ASSIGNMENT="$PUBLIC_ARTIFACT_DIR/nested/session/ios.assignment.jsonl"
PUBLIC_NESTED_TRACE="$PUBLIC_ARTIFACT_DIR/nested/session/mac.trace.log"
PUBLIC_MULTI_ASSIGNMENT="$PUBLIC_ARTIFACT_DIR/nested/session/multi.assignment.jsonl"
assert_contains "identityKey=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "targetDeviceId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "peerId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "deviceId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "p2pDeviceId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "cloudDeviceId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "pubKeyFP=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "session=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "sessionId=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "sessionRef=abcdefabcdefabcdefabcdef" "$PUBLIC_STATUS"
assert_contains "release_session_ref=abcdefabcdefabcdefabcdef" "$PUBLIC_STATUS"
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
assert_contains "account=<redacted-public-artifact-value> nebula=<redacted-public-artifact-value> device=<redacted-identity>" "$PUBLIC_STATUS"
assert_contains "noticeAccount=<redacted-public-artifact-value>" "$PUBLIC_STATUS"
assert_contains "noticeNebula=<redacted-public-artifact-value>" "$PUBLIC_STATUS"
assert_contains "remoteAccount=<redacted-public-artifact-value>" "$PUBLIC_STATUS"
assert_contains "remoteNebula=<redacted-public-artifact-value>" "$PUBLIC_STATUS"
assert_contains "localAccount=<redacted-public-artifact-value>" "$PUBLIC_STATUS"
assert_contains "localNebula=<redacted-public-artifact-value>" "$PUBLIC_STATUS"
assert_contains "device=<redacted-identity> dedupeKey=<redacted-identity> declaredDeviceId=<redacted-identity> stablePeer=<redacted-identity> peer=<redacted-identity> keyId=<redacted-identity> uniqueIdentifier=<redacted-identity> requesterProtocolIdentity=<redacted-identity> pinnedProtocolIdentity=<redacted-identity> remoteIP=<redacted-public-artifact-value>" "$PUBLIC_STATUS"
assert_contains "peerPublicKey=<redacted-secret>" "$PUBLIC_STATUS"
assert_contains "publicKey=<redacted-secret>" "$PUBLIC_STATUS"
assert_contains "kemPublicKey=<redacted-secret>" "$PUBLIC_STATUS"
assert_contains "signingFingerprint=<redacted-signing-metadata>" "$PUBLIC_STATUS"
assert_contains "signingIdentity=<redacted-signing-metadata>" "$PUBLIC_STATUS"
assert_contains "provisioningProfile=<redacted-signing-metadata>" "$PUBLIC_STATUS"
assert_contains "provisioningProfileUUID=<redacted-signing-metadata>" "$PUBLIC_STATUS"
assert_contains "teamIdentifier=<redacted-signing-metadata>" "$PUBLIC_STATUS"
assert_contains "target=<redacted-identity> name=<redacted-public-artifact-value>" "$PUBLIC_STATUS"
assert_contains "peers=<redacted-public-artifact-value>" "$PUBLIC_STATUS"
assert_contains "id=<redacted-identity> name=<redacted-public-artifact-value>" "$PUBLIC_STATUS"
assert_contains "liveRoutes=<redacted-public-artifact-value> eligibleRoutes=<redacted-public-artifact-value>" "$PUBLIC_STATUS"
assert_contains "candidates=<redacted-public-artifact-value> clearedKEM=1" "$PUBLIC_STATUS"
assert_contains "requested=<redacted-public-artifact-value> resolved=<redacted-public-artifact-value>" "$PUBLIC_STATUS"
assert_contains 'sessionId: "<redacted-identity>"' "$PUBLIC_STATUS"
assert_contains "transfer=<redacted-identity> sender=<redacted-identity> name=<redacted-public-artifact-value> bytes=102" "$PUBLIC_STATUS"
assert_contains "network-topology ula=<redacted-ipv6-endpoint> linkLocal=<redacted-ipv6-endpoint> loopback=<redacted-ipv6-endpoint> bracketed=<redacted-ipv6-endpoint> expanded=<redacted-ipv6-endpoint>" "$PUBLIC_STATUS"
assert_contains "Provisioning\\ Profiles/<redacted-provisioning-profile>.mobileprovision" "$PUBLIC_STATUS"
assert_contains "safe-fields -fmodule-name=CQPeriapt --target=arm64 --requested=diagnostic --resolved=cached filename=diagnostic.log requestedAddressClass=lan-direct resolvedAddressClass=lan-direct resolvedPeerToPeer=false testNet=198.51.100.8:443" "$PUBLIC_STATUS"
assert_contains "<redacted-connect-link>" "$PUBLIC_STATUS"
assert_contains "SKYBRIDGE_API_TOKEN=<redacted>" "$PUBLIC_STATUS"
assert_contains "PRIVATE_KEY=<redacted>" "$PUBLIC_STATUS"
assert_contains '"fingerprint": "<redacted-fingerprint>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"accessToken": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"access_token": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"apiKey": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"publicKeyBase64": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"publicKey": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"account": "<redacted-public-artifact-value>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"nebula": "<redacted-public-artifact-value>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"signingFingerprint": "<redacted-signing-metadata>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"provisioningProfile": "<redacted-signing-metadata>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"auditToken": "<redacted-identity>"' "$PUBLIC_LAUNCH_JSON"
assert_contains '"sdp": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"icePwd": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"ice_pwd": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"iceUfrag": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"iceCandidate": "<redacted-secret>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"local_endpoint": "<redacted-public-artifact-value>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"SelectedCandidatePair": "<redacted-public-artifact-value>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"tunnelIPAddress": "<redacted-identity>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"tunnelIPAddressString": "<redacted-identity>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"<redacted-ipv6-endpoint>"' "$PUBLIC_DEVICE_JSON"
assert_contains '"tenantId":"<redacted-public-artifact-value>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"routeIdentifier":"<redacted-public-artifact-value>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"endpointHost":"<redacted-public-artifact-value>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"sessionId":"<redacted-identity>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"trackId":"<redacted-identity>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"reason":"<redacted-public-artifact-value>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"xwingPublicKey":"<redacted-secret>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"mlkemPublicKey":"<redacted-secret>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains '"authorization":"<redacted-secret>"' "$PUBLIC_NESTED_ASSIGNMENT"
assert_contains "Authorization: Bearer <redacted>" "$PUBLIC_NESTED_TRACE"
assert_contains "tenantId=<redacted-public-artifact-value>" "$PUBLIC_NESTED_TRACE"
assert_contains "routeIdentifier=<redacted-public-artifact-value>" "$PUBLIC_NESTED_TRACE"
assert_contains "controlEndpoint=<redacted-public-artifact-value>" "$PUBLIC_NESTED_TRACE"
assert_contains "session=<redacted-identity>" "$PUBLIC_NESTED_TRACE"
assert_contains "trackId=<redacted-identity>" "$PUBLIC_NESTED_TRACE"
assert_contains "connect <redacted-sas-code>" "$PUBLIC_NESTED_TRACE"
assert_contains "code <redacted-sas-code>" "$PUBLIC_NESTED_TRACE"
assert_contains "reason=<redacted-public-artifact-value>" "$PUBLIC_NESTED_TRACE"
assert_contains '"account":"<redacted-public-artifact-value>"' "$PUBLIC_MULTI_ASSIGNMENT"
assert_contains '"device":"<redacted-identity>"' "$PUBLIC_MULTI_ASSIGNMENT"
assert_contains '"dedupeKey":"<redacted-identity>"' "$PUBLIC_MULTI_ASSIGNMENT"
assert_contains '"nebula":"<redacted-public-artifact-value>"' "$PUBLIC_MULTI_ASSIGNMENT"
assert_contains '"remoteAccount":"<redacted-public-artifact-value>"' "$PUBLIC_MULTI_ASSIGNMENT"
assert_contains '"localNebulaId":"<redacted-public-artifact-value>"' "$PUBLIC_MULTI_ASSIGNMENT"
assert_contains '"uniqueIdentifier":"<redacted-identity>"' "$PUBLIC_MULTI_ASSIGNMENT"
assert_contains '"peer":"<redacted-identity>"' "$PUBLIC_MULTI_ASSIGNMENT"
if [[ "$(wc -l <"$PUBLIC_MULTI_ASSIGNMENT" | tr -d ' ')" -ne 2 ]]; then
  echo "Expected public JSONL redaction to preserve one JSON object per line" >&2
  exit 1
fi
[[ ! -f "$PUBLIC_ARTIFACT_DIR/frame.png" ]] || {
  echo "Expected public materializer output to exclude unsupported artifact" >&2
  exit 1
}
[[ ! -f "$PUBLIC_ARTIFACT_DIR/host.auth-session.json" ]] || {
  echo "Expected public materializer output to exclude private auth-session artifacts" >&2
  exit 1
}
[[ -f "$PUBLIC_NESTED_ASSIGNMENT" && -f "$PUBLIC_NESTED_TRACE" && -f "$PUBLIC_MULTI_ASSIGNMENT" ]] || {
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
  "traceReasonSecret" \
  "Bill Public Artifact" \
  "nebula-direct-secret" \
  "device-direct-secret" \
  "notice-account-secret" \
  "notice-nebula-secret" \
  "remote-account-secret" \
  "remote-nebula-secret" \
  "local-account-secret" \
  "local-nebula-secret" \
  "short-peer-public-key-secret" \
  "short-public-key-secret" \
  "short-kem-public-key-secret" \
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
  "Developer-ID" \
  "private-profile" \
  "private-profile-uuid" \
  "PRIVATE-TEAM-ID" \
  "$RAW_TARGET_UUID" \
  "$RAW_TARGET_UUID_LOWER" \
  "Personal MacBook Pro" \
  "$RAW_TRANSFER_UUID" \
  "$RAW_SENDER_UUID" \
  "$RAW_HANDSHAKE_SESSION_ID" \
  "$RAW_PRIVATE_ENDPOINT" \
  "$RAW_ULA_IPV6" \
  "$RAW_LINK_LOCAL_IPV6" \
  "$RAW_LOOPBACK_IPV6" \
  "$RAW_BRACKETED_IPV6" \
  "$RAW_EXPANDED_IPV6" \
  "$RAW_PROFILE_UUID" \
  "short-json-public-key-secret" \
  "json-account-secret" \
  "json-nebula-secret" \
  "json-signing-fingerprint-secret" \
  "json-profile-secret" \
  "private-host-access-token" \
  "private-host-refresh-token" \
  "private-host-user" \
  "Bill's Office iPad" \
  "dedupe-secret" \
  "declared-device-secret" \
  "stable-peer-secret" \
  "peer-secret" \
  "key-id-secret" \
  "unique-id-secret" \
  "requester-identity-secret" \
  "pinned-identity-secret" \
  "203.0.113.42" \
  "jsonl-account-secret" \
  "jsonl-device-secret" \
  "jsonl-dedupe-secret" \
  "jsonl-nebula-secret" \
  "jsonl-remote-account-secret" \
  "jsonl-local-nebula-secret" \
  "jsonl-unique-secret" \
  "jsonl-peer-secret"
do
  assert_not_contains "$secret" "$PUBLIC_STATUS"
  assert_not_contains "$secret" "$PUBLIC_DEVICE_JSON"
  assert_not_contains "$secret" "$PUBLIC_NESTED_ASSIGNMENT"
  assert_not_contains "$secret" "$PUBLIC_NESTED_TRACE"
  assert_not_contains "$secret" "$PUBLIC_MULTI_ASSIGNMENT"
done

echo "real-device smoke redaction fixture passed"
