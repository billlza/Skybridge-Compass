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
    "arguments",
    "apikey",
    "argv",
    "bundlepath",
    "clientsecret",
    "clouddeviceid",
    "code",
    "deviceidentifier",
    "deviceid",
    "devicename",
    "ecid",
    "environment",
    "environmentvariables",
    "executablepath",
    "fingerprint",
    "identifier",
    "identitykey",
    "localdeviceid",
    "localhostnames",
    "name",
    "path",
    "p2pdeviceid",
    "potentialhostnames",
    "privatekey",
    "publickeybase64",
    "pubkeyfp",
    "refreshtoken",
    "remotedeviceid",
    "serialnumber",
    "stablepeerid",
    "targetdeviceid",
    "udid",
}

def redact_text(value: str) -> str:
    value = re.sub(r"\bfingerprint=[0-9A-Fa-f]{16,}\b", "fingerprint=<redacted-fingerprint>", value)
    value = re.sub(r"\bcode=[0-9]{6}\b", "code=<redacted-sas-code>", value)
    value = re.sub(
        r"\b(identityKey|targetDeviceId|localDeviceId|peerId|remoteDeviceId|stablePeerId|deviceId|p2pDeviceId|cloudDeviceId|pubKeyFP)=\S+",
        r"\1=<redacted-identity>",
        value,
    )
    value = re.sub(r"skybridge://[^ \n\r\t\"'\'']+", "<redacted-connect-link>", value)
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
    normalized_key = key.lower()
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
            "stablepeerid",
            "targetdeviceid",
        }:
            return "<redacted-identity>"
        if normalized_key in {"accesstoken", "apikey", "clientsecret", "privatekey", "publickeybase64", "refreshtoken"}:
            return "<redacted-secret>"
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

  rm -rf "${public_dir}"
  mkdir -p "${public_dir}"

  local source_path
  local name
  while IFS= read -r -d "" source_path; do
    name="$(basename "${source_path}")"
    skybridge_smoke_public_artifact_file_name "${name}" || continue
    skybridge_smoke_public_redact_stream "${device_label}" "$@" <"${source_path}" >"${public_dir}/${name}"
  done < <(find "${artifact_dir}" -maxdepth 1 -type f -print0)
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
            r'"(?:accessToken|refreshToken|apiKey|clientSecret|privateKey|publicKeyBase64)"\s*:\s*'
            r'"(?!<redacted)[^"]+"',
            re.IGNORECASE,
        ),
    ),
    (
        "raw Apple device identifier field",
        re.compile(
            r'"(?:identifier|udid|serialNumber|deviceIdentifier|ecid|deviceId|p2pDeviceId|cloudDeviceId|pubKeyFP)"\s*:\s*'
            r'"(?!<redacted)[^"]+"',
            re.IGNORECASE,
        ),
    ),
    ("raw local path", re.compile(r"(^|[\s\"=])/(Users|Applications|Volumes|private/var/folders|var/folders|tmp)/[^\s\"']+")),
    ("raw fingerprint", re.compile(r'\bfingerprint[=:]\s*(?!<redacted)[0-9A-Fa-f]{16,}\b', re.IGNORECASE)),
    ("raw SAS code", re.compile(r"\bcode=[0-9]{6}\b")),
    ("raw long base64", re.compile(r"\b[A-Za-z0-9+/_-]{80,}={0,2}\b")),
]

findings = []
scanned_count = 0
for current_root, dirs, files in os.walk(public_dir):
    dirs[:] = [name for name in dirs if name not in {".build", "DerivedData-ios", "DerivedData-mac-online"}]
    for name in files:
        if not name.endswith(extensions):
            continue
        scanned_count += 1
        path = os.path.join(current_root, name)
        rel_path = os.path.relpath(path, public_dir)
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
