#!/usr/bin/env bash

skybridge_smoke_hash_label() {
  local value="${1:-}"
  python3 - "${value}" <<'PY'
import hashlib
import sys

value = sys.argv[1].encode("utf-8")
print("sha256:" + hashlib.sha256(value).hexdigest()[:12])
PY
}

skybridge_smoke_redact_stream() {
  local device_label="${1:?missing device label}"
  shift
  local root_dir="${ROOT_DIR:-$(pwd)}"
  python3 - "${device_label}" "${root_dir}" "$@" 3<&0 <<'PY'
import os
import json
import re
import sys

device_label = sys.argv[1]
root_dir = sys.argv[2]
tokens = [token for token in sys.argv[3:] if token]
for key in [
    "SKYBRIDGE_REAL_DEVICE_ID",
    "SKYBRIDGE_IOS_DEVICE_ID",
    "SKYBRIDGE_SMOKE_IOS_DEVICE_ID",
    "SKYBRIDGE_DEVICE_ID",
]:
    value = os.environ.get(key)
    if value:
        tokens.append(value)

with os.fdopen(3, "r", encoding="utf-8", errors="replace") as input_stream:
    text = input_stream.read()
replacement = f"<ios-device-{device_label}>"
for token in sorted(set(tokens), key=lambda value: (-len(value), value)):
    text = text.replace(token, replacement)

path_replacements = []
for raw_path, redacted_path in [
    (root_dir, "<repo>"),
    (os.getcwd(), "<cwd>"),
    (os.environ.get("TMPDIR", "").rstrip("/"), "<tmp>"),
    (os.environ.get("HOME", ""), "<home>"),
]:
    if raw_path:
        path_replacements.append((raw_path, redacted_path))
        path_replacements.append((os.path.normpath(raw_path), redacted_path))
for raw_path, redacted_path in sorted(
    ((raw, redacted) for raw, redacted in path_replacements if raw),
    key=lambda item: (-len(item[0]), item[0]),
):
    text = text.replace(raw_path, redacted_path)

text = re.sub(
    r"/Applications/([^/\s]+\.app)/Contents/Developer",
    r"<applications>/\1/Contents/Developer",
    text,
)
text = re.sub(r"/Applications/([^/\s]+\.app)", r"<applications>/\1", text)
text = re.sub(r"/var/folders/[^ \n\r\t]+", "<tmp>", text)
text = re.sub(r"/tmp/[^ \n\r\t]+", "<tmp>", text)
text = re.sub(
    r'("?(?:identifier|udid|serialNumber|deviceIdentifier|ecid)"?\s*:\s*)"[^"]+"',
    r'\1"<redacted-ios-device>"',
    text,
    flags=re.IGNORECASE,
)
text = re.sub(
    r'("?(?:name|deviceName)"?\s*:\s*)"[^"]+"',
    r'\1"<redacted-device-name>"',
    text,
    flags=re.IGNORECASE,
)
text = re.sub(
    r'("?(?:localHostnames|potentialHostnames)"?\s*:\s*)\[[^\]]*\]',
    r'\1["<redacted-hostname>"]',
    text,
    flags=re.IGNORECASE,
)
text = re.sub(
    r'Signing Identity:\s+"[^"]+"',
    'Signing Identity: "<redacted-signing-identity>"',
    text,
)
text = re.sub(
    r'Provisioning Profile:\s+"[^"]+"',
    'Provisioning Profile: "<redacted-provisioning-profile>"',
    text,
)
text = re.sub(
    r"\([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\)",
    "(<redacted-profile-uuid>)",
    text,
)
text = re.sub(
    r"codesign --force --sign [0-9A-Fa-f]{40}",
    "codesign --force --sign <redacted-signing-certificate>",
    text,
)
text = re.sub(
    r"(SKYBRIDGE_(?:DEVICE_ID|SMOKE_IOS_DEVICE_ID|SMOKE_TARGET[A-Z0-9_]*|[A-Z0-9_]*(?:CONNECT_LINK|KEY|TOKEN|SECRET)[A-Z0-9_]*)=)[^ \n\r\t]+",
    r"\1<redacted>",
    text,
)
text = re.sub(
    r"([A-Z0-9_]*(?:TOKEN|SECRET|PRIVATE_KEY)[A-Z0-9_]*=)[^ \n\r\t]+",
    r"\1<redacted>",
    text,
)
text = re.sub(
    r"skybridge://[^ \n\r\t\"']+",
    "<redacted-connect-link>",
    text,
)
text = re.sub(
    r"\b[A-Za-z0-9+/]{80,}={0,2}\b",
    "<redacted-long-base64>",
    text,
)
sys.stdout.write(text)
PY
}

skybridge_smoke_cat_redacted() {
  local device_label="${1:?missing device label}"
  local path="${2:?missing path}"
  shift 2
  [[ -f "${path}" ]] || return 0
  skybridge_smoke_redact_stream "${device_label}" "$@" <"${path}"
}

skybridge_smoke_tail_redacted() {
  local device_label="${1:?missing device label}"
  local lines="${2:?missing line count}"
  local path="${3:?missing path}"
  shift 3
  [[ -f "${path}" ]] || return 0
  tail -n "${lines}" "${path}" 2>/dev/null | skybridge_smoke_redact_stream "${device_label}" "$@"
}

skybridge_smoke_public_redact_stream() {
  local device_label="${1:?missing device label}"
  shift
  skybridge_smoke_redact_stream "${device_label}" "$@" | python3 -c '
import json
import re
import sys

text = sys.stdin.read()

sensitive_key_values = {
    "accesstoken",
    "accountdisplayname",
    "address",
    "arguments",
    "apikey",
    "argv",
    "authsession",
    "authorization",
    "bearertoken",
    "bonjourservicename",
    "bundlepath",
    "candidate",
    "clientsecret",
    "clouddeviceid",
    "code",
    "connectioncode",
    "controlendpoint",
    "deviceidentifier",
    "deviceid",
    "devicename",
    "displayname",
    "ecid",
    "endpoint",
    "endpointhost",
    "environment",
    "environmentvariables",
    "executablepath",
    "fingerprint",
    "host",
    "identifier",
    "identitykey",
    "ice",
    "icecandidate",
    "icepwd",
    "iceufrag",
    "ip",
    "localdescription",
    "localdeviceid",
    "localendpoint",
    "localhostnames",
    "mlkempublickey",
    "name",
    "nebulaid",
    "path",
    "p2pdeviceid",
    "potentialhostnames",
    "privatekey",
    "publickeybase64",
    "pubkeyfp",
    "relay",
    "refreshtoken",
    "remotedescription",
    "remotedeviceid",
    "remoteendpoint",
    "reason",
    "routeidentifier",
    "serialnumber",
    "selectedcandidate",
    "selectedcandidatepair",
    "session",
    "sessionid",
    "sdp",
    "stablepeerid",
    "sub",
    "targetdeviceid",
    "tenantid",
    "token",
    "trackid",
    "udid",
    "url",
    "userid",
    "useridentifier",
    "xwingpublickey",
}

def normalize_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower())

def redact_text(value: str) -> str:
    value = re.sub(r"(?m)^v=0\r?$", "<redacted-sdp>", value)
    value = re.sub(r"(?m)^a=ice-pwd:[^\r\n]+", "a=ice-pwd:<redacted>", value)
    value = re.sub(r"(?m)^a=ice-ufrag:[^\r\n]+", "a=ice-ufrag:<redacted>", value)
    value = re.sub(r"(?m)^a=candidate:[^\r\n]+", "a=candidate:<redacted>", value)
    value = re.sub(r"\bAuthorization:\s*Bearer\s+\S+", "Authorization: Bearer <redacted>", value, flags=re.IGNORECASE)
    value = re.sub(r"\bconnect\s+[A-Za-z0-9._:-]{4,}\b", "connect <redacted-sas-code>", value, flags=re.IGNORECASE)
    value = re.sub(r"\bfingerprint=[0-9A-Fa-f]{16,}\b", "fingerprint=<redacted-fingerprint>", value)
    value = re.sub(r"\bcode=[0-9]{6}\b", "code=<redacted-sas-code>", value)
    value = re.sub(r"\bcode\s+[0-9]{6}\b", "code <redacted-sas-code>", value, flags=re.IGNORECASE)
    value = re.sub(
        r"\b(ice[_-]?candidate|ice[_-]?pwd|ice[_-]?ufrag|local[_-]?description|remote[_-]?description|sdp)="
        r"(?!<redacted\b|<redacted>)[^\s&]+",
        r"\1=<redacted-secret>",
        value,
        flags=re.IGNORECASE,
    )
    value = re.sub(
        r"\b(identity[_-]?key|target[_-]?device[_-]?id|local[_-]?device[_-]?id|peer[_-]?id|remote[_-]?device[_-]?id|stable[_-]?peer[_-]?id|device[_-]?id|p2p[_-]?device[_-]?id|cloud[_-]?device[_-]?id|pub[_-]?key[_-]?fp|session|session[_-]?id|track[_-]?id)=\S+",
        r"\1=<redacted-identity>",
        value,
        flags=re.IGNORECASE,
    )
    value = re.sub(
        r"\b(tenant[_-]?id|user[_-]?identifier|user[_-]?id|sub|nebula[_-]?id|display[_-]?name|account[_-]?display[_-]?name|route[_-]?identifier|bonjour[_-]?service[_-]?name|endpoint[_-]?host|control[_-]?endpoint|relay|endpoint|host|ip|address|reason|local[_-]?endpoint|remote[_-]?endpoint|selected[_-]?candidate|selected[_-]?candidate[_-]?pair|xwing[_-]?public[_-]?key|mlkem[_-]?public[_-]?key)=\S+",
        r"\1=<redacted-public-artifact-value>",
        value,
        flags=re.IGNORECASE,
    )
    value = re.sub(
        r"\b(access[_-]?token|api[_-]?key|authorization|bearer[_-]?token|client[_-]?secret|private[_-]?key|public[_-]?key[_-]?base64|refresh[_-]?token|token)="
        r"(?!<redacted\b|<redacted>)[^\s&]+",
        r"\1=<redacted-secret>",
        value,
        flags=re.IGNORECASE,
    )
    value = re.sub(r"skybridge://[^ \n\r\t\"'\'']+", "<redacted-connect-link>", value)
    value = re.sub(r"https?://[^ \n\r\t\"'\'']+", "<redacted-url>", value)
    value = re.sub(r"/Users/[^ \n\r\t\"'\'']+", "<home>", value)
    value = re.sub(r"/Applications/[^ \n\r\t\"'\'']+", "<applications>", value)
    value = re.sub(r"/Volumes/[^ \n\r\t\"'\'']+", "<volumes>", value)
    value = re.sub(r"/private/var/folders/[^ \n\r\t\"'\'']+", "<tmp>", value)
    value = re.sub(r"/var/folders/[^ \n\r\t\"'\'']+", "<tmp>", value)
    value = re.sub(r"/tmp/[^ \n\r\t\"'\'']+", "<tmp>", value)
    value = re.sub(r"\b[A-Za-z0-9+/_-]{80,}={0,2}\b", "<redacted-long-base64>", value)
    value = re.sub(
        r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b",
        "<redacted-jwt>",
        value,
    )
    return value

def redact_json(value, key: str = ""):
    normalized_key = normalize_key(key)
    if normalized_key in sensitive_key_values:
        if normalized_key == "fingerprint":
            return "<redacted-fingerprint>"
        if normalized_key in {
            "clouddeviceid",
            "deviceid",
            "identitykey",
            "localdeviceid",
            "p2pdeviceid",
            "pubkeyfp",
            "remotedeviceid",
            "session",
            "sessionid",
            "stablepeerid",
            "targetdeviceid",
            "trackid",
        }:
            return "<redacted-identity>"
        if normalized_key in {
            "accesstoken",
            "apikey",
            "authorization",
            "bearertoken",
            "clientsecret",
            "connectioncode",
            "icecandidate",
            "icepwd",
            "iceufrag",
            "localdescription",
            "mlkempublickey",
            "privatekey",
            "publickeybase64",
            "refreshtoken",
            "remotedescription",
            "sdp",
            "token",
            "xwingpublickey",
        }:
            return "<redacted-secret>"
        if normalized_key in {
            "accountdisplayname",
            "address",
            "bonjourservicename",
            "controlendpoint",
            "displayname",
            "endpoint",
            "endpointhost",
            "host",
            "ip",
            "localendpoint",
            "nebulaid",
            "reason",
            "relay",
            "remoteendpoint",
            "routeidentifier",
            "selectedcandidate",
            "selectedcandidatepair",
            "sub",
            "tenantid",
            "url",
            "userid",
            "useridentifier",
        }:
            return "<redacted-public-artifact-value>"
        if normalized_key == "code":
            return "<redacted-sas-code>"
        if normalized_key in {"arguments", "argv", "environment", "environmentvariables"}:
            return "<redacted-runtime-launch-context>"
        if normalized_key in {"bundlepath", "executablepath", "path"}:
            return "<redacted-path>"
        return "<redacted>"
    if normalized_key == "code" and isinstance(value, str) and re.fullmatch(r"[0-9]{6}", value):
        return "<redacted-sas-code>"
    if isinstance(value, dict):
        return {item_key: redact_json(item_value, item_key) for item_key, item_value in value.items()}
    if isinstance(value, list):
        return [redact_json(item, key) for item in value]
    if isinstance(value, str):
        return redact_text(value)
    return value

try:
    payload = json.loads(text)
except json.JSONDecodeError:
    sys.stdout.write(redact_text(text))
else:
    sys.stdout.write(json.dumps(redact_json(payload), indent=2, sort_keys=True))
    sys.stdout.write("\n")
'
}

skybridge_smoke_public_artifact_file_name() {
  local name="${1:?missing artifact file name}"
  case "${name}" in
    *.log|*.json|*.jsonl|*.txt|*.csv) return 0 ;;
    *) return 1 ;;
  esac
}

skybridge_smoke_materialize_public_artifacts() {
  local device_label="${1:?missing device label}"
  local artifact_dir="${2:?missing artifact dir}"
  local public_dir="${3:?missing public artifact dir}"
  shift 3

  if [[ ! -d "${artifact_dir}" ]]; then
    echo "real-device smoke artifact directory does not exist: ${artifact_dir}" >&2
    return 2
  fi
  if [[ -z "${public_dir}" || "${public_dir}" == "/" || "${public_dir}" == "${artifact_dir}" ]]; then
    echo "refusing unsafe public artifact directory: ${public_dir}" >&2
    return 2
  fi

  local artifact_abs
  local public_parent
  local public_abs
  artifact_abs="$(cd "${artifact_dir}" && pwd -P)"
  public_parent="$(dirname "${public_dir}")"
  mkdir -p "${public_parent}"
  public_abs="$(cd "${public_parent}" && pwd -P)/$(basename "${public_dir}")"

  if [[ "${public_abs}" == "/" || "${public_abs}" == "${artifact_abs}" || "${public_abs}" == "${artifact_abs}/"* ]]; then
    echo "refusing unsafe public artifact directory: ${public_dir}" >&2
    return 2
  fi

  rm -rf "${public_abs}"
  mkdir -p "${public_abs}"

  local source_path
  local name
  local rel_path
  local dest_path
  while IFS= read -r -d "" source_path; do
    name="$(basename "${source_path}")"
    rel_path="${source_path#${artifact_abs}/}"
    if ! skybridge_smoke_public_artifact_file_name "${name}"; then
      echo "unsupported smoke artifact file extension in public materializer input: ${rel_path}" >&2
      return 2
    fi
    if [[ "${rel_path}" == "${source_path}" || "${rel_path}" == .* || "${rel_path}" == */../* || "${rel_path}" == ../* ]]; then
      echo "refusing unsafe smoke artifact path: ${source_path}" >&2
      return 2
    fi
    dest_path="${public_abs}/${rel_path}"
    mkdir -p "$(dirname "${dest_path}")"
    skybridge_smoke_public_redact_stream "${device_label}" "$@" <"${source_path}" >"${dest_path}"
  done < <(
    find "${artifact_abs}" \
      \( -path "${public_abs}" -o -name .build -o -name .git -o -name DerivedData-ios -o -name DerivedData-mac-online \) -prune \
      -o -type f -print0
  )
}

skybridge_smoke_check_public_artifacts() {
  local public_dir="${1:?missing public artifact dir}"
  shift

  if [[ ! -d "${public_dir}" ]]; then
    echo "public smoke artifact directory does not exist: ${public_dir}" >&2
    return 2
  fi

  python3 - "${public_dir}" "${ROOT_DIR:-$(pwd)}" "$@" <<'PY'
import os
import re
import sys

public_dir = os.path.abspath(sys.argv[1])
root_dir = os.path.abspath(sys.argv[2])
tokens = [token for token in sys.argv[3:] if token]
for key in [
    "SKYBRIDGE_REAL_DEVICE_ID",
    "SKYBRIDGE_IOS_DEVICE_ID",
    "SKYBRIDGE_SMOKE_IOS_DEVICE_ID",
    "SKYBRIDGE_DEVICE_ID",
]:
    value = os.environ.get(key)
    if value:
        tokens.append(value)

path_tokens = [
    root_dir,
    os.getcwd(),
    os.environ.get("HOME", ""),
    os.environ.get("TMPDIR", "").rstrip("/"),
]
for token in path_tokens:
    if token:
        tokens.append(token)

extensions = (".log", ".json", ".jsonl", ".txt", ".csv")
sensitive_key_values = {
    "accesstoken",
    "accountdisplayname",
    "address",
    "apikey",
    "authsession",
    "authorization",
    "bearertoken",
    "bonjourservicename",
    "bundlepath",
    "candidate",
    "clientsecret",
    "clouddeviceid",
    "code",
    "connectioncode",
    "controlendpoint",
    "deviceidentifier",
    "deviceid",
    "devicename",
    "displayname",
    "ecid",
    "endpoint",
    "endpointhost",
    "executablepath",
    "fingerprint",
    "host",
    "identifier",
    "identitykey",
    "ice",
    "icecandidate",
    "icepwd",
    "iceufrag",
    "ip",
    "localdescription",
    "localdeviceid",
    "localendpoint",
    "localhostnames",
    "mlkempublickey",
    "name",
    "nebulaid",
    "path",
    "p2pdeviceid",
    "potentialhostnames",
    "privatekey",
    "publickeybase64",
    "pubkeyfp",
    "relay",
    "refreshtoken",
    "remotedescription",
    "remotedeviceid",
    "remoteendpoint",
    "reason",
    "routeidentifier",
    "serialnumber",
    "selectedcandidate",
    "selectedcandidatepair",
    "session",
    "sessionid",
    "sdp",
    "stablepeerid",
    "sub",
    "targetdeviceid",
    "tenantid",
    "token",
    "trackid",
    "udid",
    "url",
    "userid",
    "useridentifier",
    "xwingpublickey",
}
patterns = [
    ("raw connect link", re.compile(r"skybridge://")),
    (
        "raw JWT",
        re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"),
    ),
    (
        "raw secret environment assignment",
        re.compile(
            r"\b[A-Z0-9_]*(?:CONNECT_LINK|KEY|TOKEN|SECRET|PRIVATE_KEY)[A-Z0-9_]*="
            r"(?!<redacted\b|<redacted>)[^\s]+"
        ),
    ),
    (
        "raw secret JSON field",
        re.compile(
            r'"(?:accessToken|refreshToken|apiKey|authorization|bearerToken|clientSecret|iceCandidate|icePwd|iceUfrag|localDescription|mlkemPublicKey|privateKey|publicKeyBase64|remoteDescription|sdp|token|xwingPublicKey)"\s*:\s*'
            r'"(?!<redacted)[^"]+"',
            re.IGNORECASE,
        ),
    ),
    (
        "raw Apple device identifier field",
        re.compile(
            r'"(?:identifier|udid|serialNumber|deviceIdentifier|ecid|deviceId|p2pDeviceId|cloudDeviceId|pubKeyFP|session|sessionId|trackId)"\s*:\s*'
            r'"(?!<redacted)[^"]+"',
            re.IGNORECASE,
        ),
    ),
    (
        "raw public identity or route field",
        re.compile(
            r'"(?:accountDisplayName|address|bonjourServiceName|controlEndpoint|displayName|endpoint|endpointHost|host|ip|nebulaId|reason|relay|routeIdentifier|sub|tenantId|url|userId|userIdentifier)"\s*:\s*'
            r'"(?!<redacted)[^"]+"',
            re.IGNORECASE,
        ),
    ),
    (
        "raw public identity or route assignment",
        re.compile(
            r"\b(?:accountDisplayName|address|bonjourServiceName|controlEndpoint|displayName|endpoint|endpointHost|host|ip|nebulaId|reason|relay|routeIdentifier|sub|tenantId|userId|userIdentifier|xwingPublicKey|mlkemPublicKey)="
            r"(?!<redacted\b|<redacted>)[^\s]+",
            re.IGNORECASE,
        ),
    ),
    ("raw bearer authorization", re.compile(r"\bAuthorization:\s*Bearer\s+(?!<redacted\b|<redacted>)[^\s]+", re.IGNORECASE)),
    ("raw SDP", re.compile(r"(^|\n)v=0(\r?\n|$)")),
    ("raw ICE password", re.compile(r"(^|\n)a=ice-pwd:(?!<redacted\b|<redacted>)[^\s]+", re.IGNORECASE)),
    ("raw ICE ufrag", re.compile(r"(^|\n)a=ice-ufrag:(?!<redacted\b|<redacted>)[^\s]+", re.IGNORECASE)),
    ("raw ICE candidate", re.compile(r"(^|\n)a=candidate:(?!<redacted\b|<redacted>)[^\r\n]+", re.IGNORECASE)),
    ("raw SDP assignment", re.compile(r"\b(?:iceCandidate|icePwd|iceUfrag|localDescription|remoteDescription|sdp)=(?!<redacted\b|<redacted>)[^\s&]+", re.IGNORECASE)),
    ("raw session or track assignment", re.compile(r"\b(?:session|sessionId|trackId)=(?!<redacted\b|<redacted>)[^\s]+", re.IGNORECASE)),
    ("raw connect code", re.compile(r"\bconnect\s+(?!<redacted\b|<redacted>)[A-Za-z0-9._:-]{4,}\b", re.IGNORECASE)),
    ("raw plain SAS code", re.compile(r"\bcode\s+(?!<redacted\b|<redacted>)[0-9]{6}\b", re.IGNORECASE)),
    ("raw local path", re.compile(r"(^|[\s\"=])/(Users|Applications|Volumes|private/var/folders|var/folders|tmp)/[^\s\"']+")),
    ("raw URL", re.compile(r"https?://[^\s\"']+", re.IGNORECASE)),
    ("raw fingerprint", re.compile(r'\bfingerprint[=:]\s*(?!<redacted)[0-9A-Fa-f]{16,}\b', re.IGNORECASE)),
    ("raw SAS code", re.compile(r"\bcode=[0-9]{6}\b")),
    ("raw long base64", re.compile(r"\b[A-Za-z0-9+/_-]{80,}={0,2}\b")),
]

def normalize_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower())

def contains_unredacted_sensitive_value(value) -> bool:
    if value is None:
        return False
    if isinstance(value, str):
        stripped = value.strip()
        return bool(stripped) and "<redacted" not in stripped.lower()
    if isinstance(value, list):
        return any(contains_unredacted_sensitive_value(item) for item in value)
    if isinstance(value, dict):
        return any(contains_unredacted_sensitive_value(item) for item in value.values())
    return True

def inspect_json_fields(value, rel_path: str, findings):
    if isinstance(value, dict):
        for key, item in value.items():
            if normalize_key(str(key)) in sensitive_key_values and contains_unredacted_sensitive_value(item):
                findings.append((rel_path, f"raw sensitive JSON field {key}"))
            inspect_json_fields(item, rel_path, findings)
    elif isinstance(value, list):
        for item in value:
            inspect_json_fields(item, rel_path, findings)

def inspect_structured_json(text: str, rel_path: str, findings):
    candidates = []
    if rel_path.endswith(".jsonl"):
        candidates = [line for line in text.splitlines() if line.strip()]
    elif rel_path.endswith(".json"):
        candidates = [text]
    for candidate in candidates:
        try:
            payload = json.loads(candidate)
        except Exception:
            continue
        inspect_json_fields(payload, rel_path, findings)

findings = []
scanned_count = 0
for current_root, dirs, files in os.walk(public_dir):
    dirs[:] = [name for name in dirs if name not in {".build", "DerivedData-ios", "DerivedData-mac-online"}]
    for name in files:
        path = os.path.join(current_root, name)
        rel_path = os.path.relpath(path, public_dir)
        if not name.endswith(extensions):
            findings.append((rel_path, "unsupported public artifact file extension"))
            continue
        scanned_count += 1
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError as exc:
            findings.append((rel_path, f"unreadable public artifact: {exc}"))
            continue
        inspect_structured_json(text, rel_path, findings)
        for token in sorted(set(tokens), key=lambda value: (-len(value), value)):
            if token and token in text:
                findings.append((rel_path, "raw configured token"))
                break
        for label, pattern in patterns:
            if pattern.search(text):
                findings.append((rel_path, label))

if scanned_count == 0:
    print("Public smoke artifact directory has no scan-eligible files.", file=sys.stderr)
    raise SystemExit(1)

if findings:
    print("Public smoke artifacts contain unredacted sensitive content:", file=sys.stderr)
    for rel_path, label in findings[:20]:
        print(f"- {rel_path}: {label}", file=sys.stderr)
    if len(findings) > 20:
        print(f"- ... {len(findings) - 20} more finding(s)", file=sys.stderr)
    raise SystemExit(1)
PY
}

skybridge_smoke_write_redacted_devicectl_devices() {
  local device_label="${1:?missing device label}"
  local output_path="${2:?missing output path}"
  shift 2
  local raw_path
  raw_path="$(mktemp "${TMPDIR:-/tmp}/skybridge-devicectl-devices.XXXXXX")"
  if xcrun devicectl list devices --json-output "${raw_path}" >/dev/null; then
    skybridge_smoke_redact_stream "${device_label}" "$@" <"${raw_path}" >"${output_path}"
    rm -f "${raw_path}"
    return 0
  fi
  local status=$?
  rm -f "${raw_path}"
  return "${status}"
}
