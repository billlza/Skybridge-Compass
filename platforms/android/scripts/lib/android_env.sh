#!/usr/bin/env bash

# Resolve Android SDK tools from the local machine without requiring callers
# to preconfigure PATH. Prefer an existing PATH adb, then local.properties,
# then common macOS SDK locations.

resolve_adb_bin() {
  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return 0
  fi

  local root_dir="${1:-}"
  local candidate=""
  local sdk_dir=""

  if [[ -n "$root_dir" && -f "$root_dir/local.properties" ]]; then
    sdk_dir="$(
      sed -n 's/^sdk\\.dir=//p' "$root_dir/local.properties" \
        | sed 's#\\\\:#:#g' \
        | head -n 1
    )"
    if [[ -n "$sdk_dir" && -x "$sdk_dir/platform-tools/adb" ]]; then
      printf '%s\n' "$sdk_dir/platform-tools/adb"
      return 0
    fi
  fi

  for candidate in \
    "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
    "${ANDROID_HOME:-}/platform-tools/adb" \
    "$HOME/Library/Android/sdk/platform-tools/adb" \
    "$HOME/Android/Sdk/platform-tools/adb"
  do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

android_device_prop() {
  local adb_bin="$1"
  local device_serial="$2"
  local prop_name="$3"
  local value=""

  if ! value="$("$adb_bin" -s "$device_serial" shell getprop "$prop_name" 2>/dev/null | tr -d '\r\n')"; then
    echo "Unable to query Android device property $prop_name from $device_serial" >&2
    return 1
  fi

  printf '%s\n' "$value"
}

android_current_user_id() {
  local adb_bin="$1"
  local device_serial="$2"
  local value=""

  if value="$("$adb_bin" -s "$device_serial" shell am get-current-user 2>/dev/null | tr -d '\r\n')"; then
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi

  if value="$("$adb_bin" -s "$device_serial" shell cmd activity get-current-user 2>/dev/null | tr -d '\r\n')"; then
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi

  echo "Unable to resolve Android current user id for $device_serial" >&2
  return 1
}

first_version_major() {
  local raw="$1"
  python3 - "$raw" <<'PY'
import re
import sys

match = re.search(r"\d{1,3}", sys.argv[1])
print(match.group(0) if match else "")
PY
}

require_android16_device() {
  local release="$1"
  local sdk="$2"
  local release_major=""

  if [[ ! "$sdk" =~ ^[0-9]+$ ]]; then
    echo "Android device SDK is not numeric: ${sdk:-<empty>}" >&2
    return 1
  fi
  if (( sdk < 36 )); then
    echo "SkyBridge Android smoke requires Android 16 / API 36+, device SDK=$sdk" >&2
    return 1
  fi

  release_major="$(first_version_major "$release")"
  if [[ ! "$release_major" =~ ^[0-9]+$ ]]; then
    echo "SkyBridge Android smoke requires Android 16+; device release is not explicit: ${release:-<empty>}" >&2
    return 1
  fi
  if (( release_major < 16 )); then
    echo "SkyBridge Android smoke requires Android 16+, device release=$release" >&2
    return 1
  fi
}

require_macos26_host() {
  local product_version=""
  local major=""

  if ! command -v sw_vers >/dev/null 2>&1; then
    echo "Q-Periapt smoke requires macOS 26+ host validation, but sw_vers is unavailable" >&2
    return 1
  fi

  product_version="$(sw_vers -productVersion 2>/dev/null | tr -d '\r\n')"
  major="$(first_version_major "$product_version")"
  if [[ ! "$major" =~ ^[0-9]+$ ]]; then
    echo "Q-Periapt smoke requires macOS 26+; host version is not explicit: ${product_version:-<empty>}" >&2
    return 1
  fi
  if (( major < 26 )); then
    echo "Q-Periapt smoke requires macOS 26+ host, actual=$product_version" >&2
    return 1
  fi
}

smoke_artifact_sensitive_value() {
  python3 - "$1" <<'PY'
import hashlib
import sys

value = (sys.argv[1] or "").strip()
if not value:
    print("missing")
else:
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]
    print(f"present:length={len(value)}:sha256={digest}")
PY
}

redact_smoke_artifact_url() {
  python3 - "$1" <<'PY'
import sys

value = (sys.argv[1] or "").strip()
if not value:
    print("missing")
else:
    print("<redacted-endpoint>")
PY
}

redact_smoke_artifact_stream() {
  python3 -c '
import hashlib
import ipaddress
import re
import sys

url_pattern = re.compile(r"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s\"<>]+")
ice_url_pattern = re.compile(r"(?i)\b(?:stun|stuns|turn|turns):[^\s\"<>]+")
jwt_pattern = re.compile(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]*)?")
token_assignment_pattern = re.compile(
    r"(?i)\b(access_token|accessToken|auth_token|authToken|bearer_token|bearerToken|refresh_token|refreshToken|id_token|idToken|apiKey|clientSecret|privateKey|token|authorization|candidate|iceCandidate|icePwd|iceUfrag|ice_candidate|ice_pwd|ice_ufrag|usernameFragment|ufrag|pwd|localDescription|remoteDescription|sdp)=([^\s&]+)"
)
authorization_header_pattern = re.compile(r"(?i)\bAuthorization:\s*Bearer\s+[A-Za-z0-9._~+/=-]+")
correlatable_assignment_pattern = re.compile(
    r"(?i)\b(session|sessionId|session_id|trackId|operation|operationId|operation_id|stream|streamId|stream_id|transaction|transactionId|transaction_id|recovery|recoveryId|recovery_id|attempt|attemptId|attempt_id)=([^\s&]+)"
)
human_label_assignment_pattern = re.compile(
    r"(?i)\b(deviceName|deviceLabel|device_label|remoteName|localName|displayName|accountDisplayName|accountName|accountLabel|account_label|account|ownerName|userName|ssid|bssid|wifiName|networkName|email|name)=.*?(?=\s+[A-Za-z][A-Za-z0-9_-]*=|$)"
)
code_assignment_pattern = re.compile(
    r"(?i)\b(connection[-_]?code|connectCode|pairingCode|sas|sasCode|verificationCode)=([^\s&]+)"
)
endpoint_assignment_pattern = re.compile(
    r"(?i)\b(shard|routeIdentifier|bonjourServiceName|endpoint|endpointHost|localEndpoint|remoteEndpoint|controlEndpoint|host|ip|ipAddress|ip_address|address|localAddress|remoteAddress|socketAddress|remoteIP|localIP|tunnelIPAddress|tunnelIPAddressString|localCandidate|remoteCandidate|selectedCandidate|candidatePair|selectedCandidatePair|url)=([^\s&]+)"
)
identity_assignment_pattern = re.compile(
    r"(?i)\b(from|to|peer|peerId|peerDeviceId|targetDeviceId|localDeviceId|p2pDeviceId|cloudDeviceId|stablePeerId|remoteId|device|deviceId|device_id|identityKey|fingerprint|pubKeyFP|peerPublicKey|publicKeyBase64|xwingPublicKey|xwingPublicKeyBase64|mlkemPublicKey|mlkemPublicKeyBase64|tenantId|userIdentifier|userId|sub|nebulaId)=([^\s&]+)"
)
path_assignment_pattern = re.compile(
    r"(?i)\b(status[-_]?file|path|file)=([^\s&]+)"
)
reason_assignment_pattern = re.compile(
    r"(?i)\breason=.*?(?=\s+[A-Za-z][A-Za-z0-9_-]*=|$)"
)
enumerable_ref_assignment_pattern = re.compile(
    r"(?i)\b(deviceName|deviceLabel|device_label|remoteName|localName|displayName|accountDisplayName|accountName|accountLabel|account_label|account|ownerName|userName|ssid|bssid|wifiName|networkName|email|name|connection[-_]?code|connectCode|pairingCode|sas|sasCode|verificationCode|shard|routeIdentifier|bonjourServiceName|endpoint|endpointHost|localEndpoint|remoteEndpoint|controlEndpoint|host|ip|ipAddress|ip_address|address|localAddress|remoteAddress|socketAddress|remoteIP|localIP|tunnelIPAddress|tunnelIPAddressString|localCandidate|remoteCandidate|selectedCandidate|candidatePair|selectedCandidatePair|url|from|to|peer|peerId|peerDeviceId|targetDeviceId|localDeviceId|p2pDeviceId|cloudDeviceId|stablePeerId|remoteId|device|deviceId|device_id|identityKey|fingerprint|pubKeyFP|tenantId|userIdentifier|userId|sub|nebulaId|status[-_]?file|path|file)(?:_ref)?=ref:[0-9a-f]{6,64}"
)
json_sensitive_field_pattern = re.compile(
    r"(?i)(\"(?:accessToken|refreshToken|apiKey|authorization|bearerToken|clientSecret|privateKey|token|candidate|iceCandidate|icePwd|iceUfrag|ice_candidate|ice_pwd|ice_ufrag|usernameFragment|ufrag|pwd|localDescription|remoteDescription|sdp|peerPublicKey|publicKeyBase64|xwingPublicKey|xwingPublicKeyBase64|mlkemPublicKey|mlkemPublicKeyBase64|session|sessionId|trackId|operation|operationId|stream|streamId|transaction|transactionId|recovery|recoveryId|attempt|attemptId|peerId|peerDeviceId|targetDeviceId|localDeviceId|p2pDeviceId|cloudDeviceId|stablePeerId|deviceId|identityKey|fingerprint|pubKeyFP|tenantId|userIdentifier|userId|sub|nebulaId|deviceName|deviceLabel|device_label|remoteName|localName|displayName|accountDisplayName|accountName|accountLabel|account_label|account|ownerName|userName|ssid|bssid|wifiName|networkName|email|name|reason|routeIdentifier|bonjourServiceName|endpoint|endpointHost|localEndpoint|remoteEndpoint|controlEndpoint|host|ip|ipAddress|ip_address|address|localAddress|remoteAddress|socketAddress|remoteIP|localIP|tunnelIPAddress|tunnelIPAddressString|localCandidate|remoteCandidate|selectedCandidate|candidatePair|selectedCandidatePair|url|path|file|connectionCode|pairingCode|sas|sasCode|verificationCode)\"\s*:\s*\")([^\"]*)(\")"
)
json_sensitive_scalar_pattern = re.compile(
    r"(?i)(\"(?:accessToken|refreshToken|apiKey|authorization|bearerToken|clientSecret|privateKey|token|candidate|iceCandidate|icePwd|iceUfrag|ice_candidate|ice_pwd|ice_ufrag|usernameFragment|ufrag|pwd|localDescription|remoteDescription|sdp|peerPublicKey|publicKeyBase64|xwingPublicKey|xwingPublicKeyBase64|mlkemPublicKey|mlkemPublicKeyBase64|session|sessionId|trackId|operation|operationId|stream|streamId|transaction|transactionId|recovery|recoveryId|attempt|attemptId|peerId|peerDeviceId|targetDeviceId|localDeviceId|p2pDeviceId|cloudDeviceId|stablePeerId|deviceId|identityKey|fingerprint|pubKeyFP|tenantId|userIdentifier|userId|sub|nebulaId|deviceName|deviceLabel|device_label|remoteName|localName|displayName|accountDisplayName|accountName|accountLabel|account_label|account|ownerName|userName|ssid|bssid|wifiName|networkName|email|name|reason|routeIdentifier|bonjourServiceName|endpoint|endpointHost|localEndpoint|remoteEndpoint|controlEndpoint|host|ip|ipAddress|ip_address|address|localAddress|remoteAddress|socketAddress|remoteIP|localIP|tunnelIPAddress|tunnelIPAddressString|localCandidate|remoteCandidate|selectedCandidate|candidatePair|selectedCandidatePair|url|path|file|connectionCode|pairingCode|sas|sasCode|verificationCode)\"\s*:\s*)(-?(?:[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null))(?=\s*[,}])"
)
ice_candidate_pattern = re.compile(r"(?i)(?:a=)?candidate:[^\r\n\"<>]+")
ice_attribute_pattern = re.compile(r"(?i)a=ice-(?:pwd|ufrag):[^\s\\\"<>]+")
sdp_payload_pattern = re.compile(
    r"(?i)(?:^|(?<=\s)|(?<=\"))(?:v=0|o=-\s+[^\r\n]+|c=IN\s+IP[46]\s+[^\r\n]+|m=(?:audio|video|application)\s+[^\r\n]+)"
)
bracketed_ipv6_endpoint_pattern = re.compile(
    r"\[(?P<address>[0-9A-Fa-f:.]+(?:%[A-Za-z0-9_.-]+)?)\](?::[0-9]{1,5})?"
)
ipv4_endpoint_pattern = re.compile(
    r"(?<![0-9A-Fa-f:.])(?P<address>(?:[0-9]{1,3}\.){3}[0-9]{1,3})(?::[0-9]{1,5})?(?![0-9A-Fa-f:.])"
)
bare_ipv6_pattern = re.compile(
    r"(?<![0-9A-Fa-f:])(?P<address>(?:[0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f:.]*(?:%[A-Za-z0-9_.-]+)?)(?![0-9A-Fa-f:])"
)
long_base64_pattern = re.compile(r"\b[A-Za-z0-9+/_-]{80,}={0,2}\b")
sk_pattern = re.compile(r"\bsk-[A-Za-z0-9._-]{8,}\b")
absolute_path_pattern = re.compile(
    r"(?<![A-Za-z0-9_])(/Users/[^\s\"<>]+|/private/var/[^\s\"<>]+|/var/folders/[^\s\"<>]+|/data/(?:user|data)/[^\s\"<>]+)"
)
windows_path_pattern = re.compile(r"\b[A-Za-z]:\\\\[^\s\"<>]+")

def stable_ref(raw: str) -> str:
    return "ref:" + hashlib.sha256(raw.encode("utf-8")).hexdigest()[:12]

def is_high_entropy_reference(raw: str) -> bool:
    return (
        len(raw) >= 16
        and len(set(raw)) >= 8
        and re.fullmatch(r"[A-Za-z0-9._:-]+", raw) is not None
    )

def redact_correlatable_assignment(match: re.Match[str]) -> str:
    key = match.group(1)
    value = match.group(2)
    public_value = stable_ref(value) if is_high_entropy_reference(value) else "<redacted-correlation>"
    return f"{key}_ref={public_value}"

def redact_fixed_assignment(match: re.Match[str], placeholder: str) -> str:
    return f"{match.group(1)}={placeholder}"

def redact_json_field(match: re.Match[str]) -> str:
    return f"{match.group(1)}<redacted>{match.group(3)}"

def redact_path(match: re.Match[str]) -> str:
    return "<redacted-path>"

def valid_ip(raw: str) -> bool:
    candidate = raw.split("%", 1)[0]
    try:
        ipaddress.ip_address(candidate)
        return True
    except ValueError:
        return False

def redact_bracketed_ipv6(match: re.Match[str]) -> str:
    return "<redacted-ip-endpoint>" if valid_ip(match.group("address")) else match.group(0)

def redact_ipv4_endpoint(match: re.Match[str]) -> str:
    return "<redacted-ip-endpoint>" if valid_ip(match.group("address")) else match.group(0)

def redact_bare_ipv6(match: re.Match[str]) -> str:
    return "<redacted-ip-endpoint>" if valid_ip(match.group("address")) else match.group(0)

for line in sys.stdin:
    line = enumerable_ref_assignment_pattern.sub(
        lambda match: redact_fixed_assignment(match, "<redacted-public-artifact-value>"),
        line,
    )
    line = url_pattern.sub("<redacted-url>", line)
    line = ice_url_pattern.sub("<redacted-endpoint>", line)
    line = jwt_pattern.sub("<redacted-jwt>", line)
    line = sk_pattern.sub("sk-<redacted>", line)
    line = authorization_header_pattern.sub("Authorization: Bearer <redacted>", line)
    line = token_assignment_pattern.sub(lambda m: f"{m.group(1)}=<redacted>", line)
    line = human_label_assignment_pattern.sub(
        lambda match: redact_fixed_assignment(match, "<redacted-label>"),
        line,
    )
    line = code_assignment_pattern.sub(
        lambda match: redact_fixed_assignment(match, "<redacted-code>"),
        line,
    )
    line = endpoint_assignment_pattern.sub(
        lambda match: redact_fixed_assignment(match, "<redacted-endpoint>"),
        line,
    )
    line = identity_assignment_pattern.sub(
        lambda match: redact_fixed_assignment(match, "<redacted-identity>"),
        line,
    )
    line = path_assignment_pattern.sub(
        lambda match: redact_fixed_assignment(match, "<redacted-path>"),
        line,
    )
    line = reason_assignment_pattern.sub("reason=<redacted>", line)
    line = correlatable_assignment_pattern.sub(redact_correlatable_assignment, line)
    line = json_sensitive_field_pattern.sub(redact_json_field, line)
    line = json_sensitive_scalar_pattern.sub(lambda match: f"{match.group(1)}\"<redacted>\"", line)
    line = ice_candidate_pattern.sub("candidate:<redacted>", line)
    line = ice_attribute_pattern.sub("a=ice-secret:<redacted>", line)
    line = sdp_payload_pattern.sub("<redacted-sdp>", line)
    line = bracketed_ipv6_endpoint_pattern.sub(redact_bracketed_ipv6, line)
    line = ipv4_endpoint_pattern.sub(redact_ipv4_endpoint, line)
    line = bare_ipv6_pattern.sub(redact_bare_ipv6, line)
    line = long_base64_pattern.sub("<redacted-long-base64>", line)
    line = re.sub(r"(?i)\bconnect\s+[A-Za-z0-9._:-]{4,}\b", "connect <redacted-code>", line)
    line = re.sub(r"(?i)\bcode\s+[0-9]{6}\b", "code <redacted-code>", line)
    line = absolute_path_pattern.sub(redact_path, line)
    line = windows_path_pattern.sub(redact_path, line)
    sys.stdout.write(line)
'
}

android_smoke_public_artifact_file_name() {
  local name="${1:?missing artifact file name}"
  case "${name}" in
    *.log|*.json|*.jsonl|*.txt|*.csv) return 0 ;;
    *) return 1 ;;
  esac
}

android_smoke_materialize_public_artifacts() {
  local artifact_dir="${1:?missing artifact dir}"
  local public_dir="${2:?missing public artifact dir}"

  if [[ ! -d "$artifact_dir" ]]; then
    echo "Android smoke artifact directory does not exist: $artifact_dir" >&2
    return 2
  fi
  if [[ -z "$public_dir" || "$public_dir" == "/" || "$public_dir" == "$artifact_dir" ]]; then
    echo "refusing unsafe Android public artifact directory: $public_dir" >&2
    return 2
  fi

  local artifact_abs
  local public_parent
  local public_abs
  artifact_abs="$(cd "$artifact_dir" && pwd -P)"
  public_parent="$(dirname "$public_dir")"
  mkdir -p "$public_parent"
  public_abs="$(cd "$public_parent" && pwd -P)/$(basename "$public_dir")"

  if [[ "$public_abs" == "/" || "$public_abs" == "$artifact_abs" ]]; then
    echo "refusing unsafe Android public artifact directory: $public_dir" >&2
    return 2
  fi

  rm -rf "$public_abs"
  mkdir -p "$public_abs"

  local source_path
  local name
  local rel_path
  local dest_path
  while IFS= read -r -d "" source_path; do
    name="$(basename "$source_path")"
    android_smoke_public_artifact_file_name "$name" || continue
    rel_path="${source_path#"${artifact_abs}"/}"
    if [[ "$rel_path" == "$source_path" || "$rel_path" == .* || "$rel_path" == */../* || "$rel_path" == ../* ]]; then
      echo "refusing unsafe Android smoke artifact path: $source_path" >&2
      return 2
    fi
    dest_path="$public_abs/$rel_path"
    mkdir -p "$(dirname "$dest_path")"
    redact_smoke_artifact_stream <"$source_path" >"$dest_path"
  done < <(
    find "$artifact_abs" \
      \( -path "$public_abs" -o -name .gradle -o -name .git -o -name build -o -name captures \) -prune \
      -o -type f -print0
  )
}

android_smoke_check_public_artifacts() {
  local public_dir="${1:?missing public artifact dir}"
  shift

  if [[ ! -d "$public_dir" ]]; then
    echo "Android public smoke artifact directory does not exist: $public_dir" >&2
    return 2
  fi

  python3 - "$public_dir" "$(pwd)" "$@" <<'PY'
import ipaddress
import os
import re
import sys

public_dir = os.path.abspath(sys.argv[1])
root_dir = os.path.abspath(sys.argv[2])
tokens = [token for token in sys.argv[3:] if token]
for key in [
    "ANDROID_SERIAL",
    "DEVICE_SERIAL",
    "SKYBRIDGE_DEVICE_ID",
    "SKYBRIDGE_TENANT_ID",
    "SKYBRIDGE_USER_ID",
    "SKYBRIDGE_BEARER_TOKEN",
]:
    value = os.environ.get(key)
    if value:
        tokens.append(value)

for token in [
    root_dir,
    os.getcwd(),
    os.environ.get("HOME", ""),
    os.environ.get("TMPDIR", "").rstrip("/"),
    os.environ.get("ANDROID_HOME", ""),
    os.environ.get("ANDROID_SDK_ROOT", ""),
]:
    if token:
        tokens.append(token)

extensions = (".log", ".json", ".jsonl", ".txt", ".csv")
correlatable_keys = (
    r"session|sessionId|session_id|trackId|operation|operationId|operation_id|"
    r"stream|streamId|stream_id|transaction|transactionId|transaction_id|"
    r"recovery|recoveryId|recovery_id|attempt|attemptId|attempt_id"
)
fixed_assignment_keys = (
    r"access_token|accessToken|auth_token|authToken|bearer_token|bearerToken|"
    r"refresh_token|refreshToken|id_token|idToken|apiKey|clientSecret|privateKey|"
    r"token|authorization|candidate|iceCandidate|icePwd|iceUfrag|ice_candidate|"
    r"ice_pwd|ice_ufrag|usernameFragment|ufrag|pwd|localDescription|"
    r"remoteDescription|sdp|deviceName|deviceLabel|device_label|remoteName|"
    r"localName|displayName|accountDisplayName|accountName|accountLabel|"
    r"account_label|account|ownerName|userName|ssid|bssid|wifiName|networkName|"
    r"email|name|connection[-_]?code|connectCode|pairingCode|sas|sasCode|"
    r"verificationCode|shard|routeIdentifier|bonjourServiceName|endpoint|"
    r"endpointHost|localEndpoint|remoteEndpoint|controlEndpoint|host|ip|ipAddress|"
    r"ip_address|address|localAddress|remoteAddress|socketAddress|remoteIP|localIP|"
    r"tunnelIPAddress|tunnelIPAddressString|localCandidate|remoteCandidate|"
    r"selectedCandidate|candidatePair|selectedCandidatePair|url|from|to|peer|"
    r"peerId|peerDeviceId|targetDeviceId|localDeviceId|p2pDeviceId|cloudDeviceId|"
    r"stablePeerId|remoteId|device|deviceId|device_id|identityKey|fingerprint|"
    r"pubKeyFP|peerPublicKey|publicKeyBase64|xwingPublicKey|xwingPublicKeyBase64|"
    r"mlkemPublicKey|mlkemPublicKeyBase64|tenantId|userIdentifier|userId|sub|"
    r"nebulaId|status[-_]?file|path|file|reason"
)
json_sensitive_keys = (
    r"accessToken|refreshToken|apiKey|authorization|bearerToken|clientSecret|"
    r"privateKey|token|candidate|iceCandidate|icePwd|iceUfrag|ice_candidate|"
    r"ice_pwd|ice_ufrag|usernameFragment|ufrag|pwd|localDescription|"
    r"remoteDescription|sdp|peerPublicKey|publicKeyBase64|xwingPublicKey|"
    r"xwingPublicKeyBase64|mlkemPublicKey|mlkemPublicKeyBase64|session|sessionId|"
    r"trackId|operation|operationId|stream|streamId|transaction|transactionId|"
    r"recovery|recoveryId|attempt|attemptId|peerId|peerDeviceId|targetDeviceId|"
    r"localDeviceId|p2pDeviceId|cloudDeviceId|stablePeerId|deviceId|identityKey|"
    r"fingerprint|pubKeyFP|tenantId|userIdentifier|userId|sub|nebulaId|deviceName|"
    r"deviceLabel|device_label|remoteName|localName|displayName|accountDisplayName|"
    r"accountName|accountLabel|account_label|account|ownerName|userName|ssid|bssid|"
    r"wifiName|networkName|email|name|reason|routeIdentifier|bonjourServiceName|"
    r"endpoint|endpointHost|localEndpoint|remoteEndpoint|controlEndpoint|host|ip|"
    r"ipAddress|ip_address|address|localAddress|remoteAddress|socketAddress|"
    r"remoteIP|localIP|tunnelIPAddress|tunnelIPAddressString|localCandidate|"
    r"remoteCandidate|selectedCandidate|candidatePair|selectedCandidatePair|url|"
    r"path|file|connectionCode|pairingCode|sas|sasCode|verificationCode"
)
redacted_value = r"<redacted(?:-[A-Za-z0-9-]+)?>"
patterns = [
    ("raw connect link", re.compile(r"skybridge://")),
    ("raw URL", re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s\"']+", re.IGNORECASE)),
    ("raw ICE server URI", re.compile(r"\b(?:stun|stuns|turn|turns):[^\s\"']+", re.IGNORECASE)),
    ("raw JWT", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]*)?\b")),
    ("raw bearer authorization", re.compile(r"\bAuthorization:\s*Bearer\s+(?!<redacted\b|<redacted>)[^\s]+", re.IGNORECASE)),
    (
        "raw correlatable assignment",
        re.compile(
            rf"\b(?:{correlatable_keys})(?:_ref)?="
            rf"(?!(?:ref:[0-9a-f]{{12}}|{redacted_value})(?:[\s&]|$))[^\s&]+",
            re.IGNORECASE,
        ),
    ),
    (
        "raw fixed-sensitive assignment",
        re.compile(
            rf"\b(?:{fixed_assignment_keys})(?:_ref)?="
            rf"(?!{redacted_value}(?:[\s&]|$))[^\s&]+",
            re.IGNORECASE,
        ),
    ),
    (
        "raw sensitive JSON field",
        re.compile(
            rf'"(?:{json_sensitive_keys})"\s*:\s*'
            rf'(?!"{redacted_value}"(?:\s*[,}}]|\s*$))(?:"[^"]*"|[^,}}\s]+)',
            re.IGNORECASE,
        ),
    ),
    (
        "raw ICE candidate",
        re.compile(r"(?:a=)?candidate:(?!<redacted>)[^\s\"<>]+", re.IGNORECASE),
    ),
    (
        "raw ICE credential",
        re.compile(r"a=ice-(?:ufrag|pwd):(?!<redacted>)[^\s\\\"<>]+", re.IGNORECASE),
    ),
    (
        "raw SDP payload",
        re.compile(
            r"(?:^|[\s\"])(?:v=0(?=$|[\s\\])|o=-\s+[^\r\n]+|c=IN\s+IP[46]\s+[^\r\n]+|m=(?:audio|video|application)\s+[^\r\n]+)",
            re.IGNORECASE | re.MULTILINE,
        ),
    ),
    ("legacy enumerable redaction", re.compile(r"<redacted-[a-z-]+:ref:[0-9a-f]{6,64}>", re.IGNORECASE)),
    ("raw connect code", re.compile(r"\bconnect\s+(?!<redacted\b|<redacted>)[A-Za-z0-9._:-]{4,}\b", re.IGNORECASE)),
    ("raw plain SAS code", re.compile(r"\bcode\s+(?!<redacted\b|<redacted>)[0-9]{6}\b", re.IGNORECASE)),
    ("raw local path", re.compile(r"(^|[\s\"=])(?:/Users|/private/var|/var/folders|/data/(?:user|data)|[A-Za-z]:\\\\)[^\s\"']+")),
    ("raw long base64", re.compile(r"\b[A-Za-z0-9+/_-]{80,}={0,2}\b")),
]

bracketed_ipv6_endpoint_pattern = re.compile(
    r"\[(?P<address>[0-9A-Fa-f:.]+(?:%[A-Za-z0-9_.-]+)?)\](?::[0-9]{1,5})?"
)
ipv4_endpoint_pattern = re.compile(
    r"(?<![0-9A-Fa-f:.])(?P<address>(?:[0-9]{1,3}\.){3}[0-9]{1,3})(?::[0-9]{1,5})?(?![0-9A-Fa-f:.])"
)
bare_ipv6_pattern = re.compile(
    r"(?<![0-9A-Fa-f:])(?P<address>(?:[0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f:.]*(?:%[A-Za-z0-9_.-]+)?)(?![0-9A-Fa-f:])"
)

def valid_ip(raw: str) -> bool:
    candidate = raw.split("%", 1)[0]
    try:
        ipaddress.ip_address(candidate)
        return True
    except ValueError:
        return False

def contains_valid_ip(text: str, pattern: re.Pattern[str]) -> bool:
    return any(valid_ip(match.group("address")) for match in pattern.finditer(text))

findings = []
scanned_count = 0
for current_root, dirs, files in os.walk(public_dir):
    dirs[:] = [
        name for name in dirs
        if name not in {".gradle", ".git", "build", "captures"} and not os.path.islink(os.path.join(current_root, name))
    ]
    for name in files:
        path = os.path.join(current_root, name)
        rel_path = os.path.relpath(path, public_dir)
        if os.path.islink(path):
            findings.append((rel_path, "symlink artifact"))
            continue
        if not name.endswith(extensions):
            continue
        scanned_count += 1
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError as exc:
            findings.append((rel_path, f"unreadable public artifact: {exc}"))
            continue
        for token in sorted(set(tokens), key=lambda value: (-len(value), value)):
            if token and token in text:
                findings.append((rel_path, "raw configured token"))
                break
        for label, pattern in patterns:
            if pattern.search(text):
                findings.append((rel_path, label))
        if contains_valid_ip(text, ipv4_endpoint_pattern):
            findings.append((rel_path, "raw IPv4 endpoint"))
        if contains_valid_ip(text, bracketed_ipv6_endpoint_pattern) or contains_valid_ip(text, bare_ipv6_pattern):
            findings.append((rel_path, "raw IPv6 endpoint"))

if scanned_count == 0:
    print("Android public smoke artifact directory has no scan-eligible files.", file=sys.stderr)
    raise SystemExit(1)

if findings:
    print("Android public smoke artifacts contain unredacted sensitive content:", file=sys.stderr)
    for rel_path, label in findings[:20]:
        print(f"- {rel_path}: {label}", file=sys.stderr)
    if len(findings) > 20:
        print(f"- ... {len(findings) - 20} more finding(s)", file=sys.stderr)
    raise SystemExit(1)
PY
}

android_capture_redacted_logcat() {
  local adb_bin="$1"
  local device_serial="$2"
  local logcat_file="$3"
  local handshake_file="${4:-}"
  local start_time="${5:-}"
  local tmp_file=""
  local failed=0
  local -a logcat_args=(-d -v threadtime)

  if [[ -z "$adb_bin" || -z "$device_serial" || -z "$logcat_file" ]]; then
    return 1
  fi

  if [[ -n "$start_time" ]]; then
    logcat_args+=(-T "$start_time")
  fi

  tmp_file="${logcat_file}.raw"
  if "$adb_bin" -s "$device_serial" logcat "${logcat_args[@]}" >"$tmp_file" 2>/dev/null; then
    if ! redact_smoke_artifact_stream <"$tmp_file" >"$logcat_file"; then
      printf '%s\n' "logcat_redaction_failed" >"$logcat_file"
      failed=1
    fi
  else
    printf '%s\n' "logcat_capture_failed" >"$logcat_file"
    failed=1
  fi
  rm -f "$tmp_file"

  if [[ -n "$handshake_file" ]]; then
    grep -E 'SB-HANDSHAKE|SB-WEBRTC|SB-ANDROID|SB-DEBUG-SMOKE|SB-SIGNAL-WS|WebRtcSession|SkyBridgeWebRtcConnectionManager|SkyBridgeSignaling|signaling' \
      "$logcat_file" >"$handshake_file" || true
  fi
  return "$failed"
}
