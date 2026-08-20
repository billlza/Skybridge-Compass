#!/usr/bin/env bash

skybridge_smoke_require_safe_run_id() {
  local run_id="${1:-}"
  local variable_name="${2:-smoke run ID}"

  if [[ ! "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    printf '%s must be 1-64 characters, start with an ASCII letter or digit, and contain only ASCII letters, digits, dot, underscore, or hyphen.\n' \
      "$variable_name" >&2
    return 2
  fi
}

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
text = re.sub(r"/var/folders/[^ \n\r\t\"']+", "<tmp>", text)
text = re.sub(r"/tmp/[^ \n\r\t\"']+", "<tmp>", text)
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
  skybridge_smoke_redact_stream "${device_label}" "$@" | python3 /dev/fd/3 3<<'PY'
import ipaddress
import json
import os
import re
import sys

text = sys.stdin.read()
jsonl_mode = os.environ.get("SKYBRIDGE_SMOKE_REDACTION_FORMAT") == "jsonl"

ipv4_octet = r"(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
private_ipv4_endpoint_pattern = re.compile(
    rf"(?<![0-9.])(?:"
    rf"10\.{ipv4_octet}\.{ipv4_octet}\.{ipv4_octet}|"
    rf"127\.{ipv4_octet}\.{ipv4_octet}\.{ipv4_octet}|"
    rf"169\.254\.{ipv4_octet}\.{ipv4_octet}|"
    rf"172\.(?:1[6-9]|2[0-9]|3[01])\.{ipv4_octet}\.{ipv4_octet}|"
    rf"192\.168\.{ipv4_octet}\.{ipv4_octet}"
    rf")(?::[0-9]{{1,5}})?(?![0-9.])"
)
ipv6_candidate_pattern = re.compile(
    r"(?<![0-9A-Fa-f:.%])(?:"
    r"\[(?P<bracketed>[0-9A-Fa-f:.]+(?:%[A-Za-z0-9_.-]+)?)\](?::[0-9]{1,5})?"
    r"|(?P<bare>[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*(?:%[A-Za-z0-9_.-]+)?)"
    r")(?![0-9A-Fa-f:.%])"
)

def parsed_ipv6_literal(match):
    candidate = match.group("bracketed") or match.group("bare")
    address_without_scope = candidate.split("%", 1)[0]
    try:
        address = ipaddress.ip_address(address_without_scope)
    except ValueError:
        return None
    return address if address.version == 6 else None

def redact_ipv6_literals(value: str) -> str:
    return ipv6_candidate_pattern.sub(
        lambda match: (
            "<redacted-ipv6-endpoint>"
            if parsed_ipv6_literal(match) is not None
            else match.group(0)
        ),
        value,
    )

sensitive_key_values = {
    "accesstoken",
    "account",
    "accountdisplayname",
    "address",
    "arguments",
    "apikey",
    "argv",
    "authsession",
    "audittoken",
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
    "declareddeviceid",
    "dedupekey",
    "device",
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
    "keyid",
    "localdescription",
    "localaccount",
    "localaccountdisplayname",
    "localdeviceid",
    "localendpoint",
    "localip",
    "localhostnames",
    "localnebula",
    "localnebulaid",
    "mlkempublickey",
    "name",
    "nebula",
    "nebulaid",
    "noticeaccount",
    "noticeaccountdisplayname",
    "noticenebula",
    "noticenebulaid",
    "path",
    "p2pdeviceid",
    "peer",
    "pinnedprotocolidentity",
    "potentialhostnames",
    "privatekey",
    "provisioningprofile",
    "provisioningprofileuuid",
    "publickey",
    "publickeybase64",
    "pubkeyfp",
    "relay",
    "refreshtoken",
    "remotedescription",
    "remoteaccount",
    "remoteaccountdisplayname",
    "remotedeviceid",
    "remoteendpoint",
    "remoteip",
    "remotenebula",
    "remotenebulaid",
    "requesterprotocolidentity",
    "reason",
    "routeidentifier",
    "serialnumber",
    "selectedcandidate",
    "selectedcandidatepair",
    "session",
    "sessionid",
    "sdp",
    "stablepeerid",
    "stablepeer",
    "signingfingerprint",
    "signingidentity",
    "sub",
    "targetdeviceid",
    "teamidentifier",
    "tenantid",
    "token",
    "trackid",
    "tunnelipaddress",
    "tunnelipaddressstring",
    "udid",
    "uniqueidentifier",
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
    # Human-facing account and device labels may contain spaces. Consume the
    # complete value through the next structured key instead of leaving a
    # suffix behind after redacting only the first whitespace-delimited token.
    value = re.sub(
        r"\b(account|device(?:[_-]?name)?|nebula)=.*?(?=\s+[A-Za-z][A-Za-z0-9_-]*=|$)",
        r"\1=<redacted-public-artifact-value>",
        value,
        flags=re.IGNORECASE | re.MULTILINE,
    )
    # Bare smoke-log labels are not schema keys, so handle only assignments that
    # begin at a line boundary or after whitespace. This deliberately avoids
    # compiler flags such as `-fmodule-name=CQPeriapt`.
    value = re.sub(
        r"(^|[ \t])(name|candidates|peers|liveRoutes|eligibleRoutes)=.*?(?=\s+[A-Za-z][A-Za-z0-9_-]*=|$)",
        r"\1\2=<redacted-public-artifact-value>",
        value,
        flags=re.IGNORECASE | re.MULTILINE,
    )
    value = re.sub(
        r"\b(identity[_-]?key|declared[_-]?device[_-]?id|target[_-]?device[_-]?id|local[_-]?device[_-]?id|peer(?:[_-]?id)?|remote[_-]?device[_-]?id|stable[_-]?peer(?:[_-]?id)?|device(?:[_-]?id)?|p2p[_-]?device[_-]?id|cloud[_-]?device[_-]?id|pub[_-]?key[_-]?fp|dedupe[_-]?key|key[_-]?id|requester[_-]?protocol[_-]?identity|pinned[_-]?protocol[_-]?identity|unique[_-]?identifier|session|session[_-]?id|track[_-]?id)=\S+",
        r"\1=<redacted-identity>",
        value,
        flags=re.IGNORECASE,
    )
    value = re.sub(
        r"(^|[ \t])(sender|target|transfer)=\S+",
        r"\1\2=<redacted-identity>",
        value,
        flags=re.IGNORECASE | re.MULTILINE,
    )
    value = re.sub(
        r"(^|[ \t])id=id:\S+",
        r"\1id=<redacted-identity>",
        value,
        flags=re.IGNORECASE | re.MULTILINE,
    )
    value = re.sub(
        r"\b(session|sessionId|trackId)\s*:\s*\"(?!<redacted\b)[^\"]+\"",
        "\\1: \"<redacted-identity>\"",
        value,
        flags=re.IGNORECASE,
    )
    value = re.sub(
        r"\b(tenant[_-]?id|user[_-]?identifier|user[_-]?id|sub|(?:notice|remote|local)?[_-]?nebula(?:[_-]?id)?|display[_-]?name|(?:notice|remote|local)?[_-]?account(?:[_-]?display[_-]?name)?|route[_-]?identifier|bonjour[_-]?service[_-]?name|endpoint[_-]?host|control[_-]?endpoint|relay|endpoint|host|(?:remote[_-]?)?ip|address|reason|local[_-]?endpoint|remote[_-]?endpoint|selected[_-]?candidate|selected[_-]?candidate[_-]?pair)=\S+",
        r"\1=<redacted-public-artifact-value>",
        value,
        flags=re.IGNORECASE,
    )
    value = re.sub(
        r"(^|[ \t])(requested|resolved)=\S+",
        r"\1\2=<redacted-public-artifact-value>",
        value,
        flags=re.IGNORECASE | re.MULTILINE,
    )
    value = re.sub(
        r"\b(access[_-]?token|api[_-]?key|authorization|bearer[_-]?token|client[_-]?secret|private[_-]?key|(?:(?:peer|kem|pqc|xwing|mlkem|ed25519|x25519)[_-]?)?public[_-]?key(?:[_-]?base64)?|refresh[_-]?token|token)="
        r"(?!<redacted\b|<redacted>)[^\s&]+",
        r"\1=<redacted-secret>",
        value,
        flags=re.IGNORECASE,
    )
    value = re.sub(
        r"\b(signing[_-]?(?:fingerprint|identity)|provisioning[_-]?profile(?:[_-]?uuid)?|team[_-]?identifier)="
        r"(?!<redacted\b|<redacted>)[^\s&]+",
        r"\1=<redacted-signing-metadata>",
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
    value = re.sub(
        r"(Provisioning(?:\\ | )Profiles/)[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.mobileprovision",
        r"\1<redacted-provisioning-profile>.mobileprovision",
        value,
    )
    value = private_ipv4_endpoint_pattern.sub("<redacted-private-endpoint>", value)
    value = redact_ipv6_literals(value)
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
            "audittoken",
            "declareddeviceid",
            "dedupekey",
            "device",
            "deviceid",
            "identitykey",
            "keyid",
            "localdeviceid",
            "p2pdeviceid",
            "peer",
            "pinnedprotocolidentity",
            "pubkeyfp",
            "remotedeviceid",
            "requesterprotocolidentity",
            "session",
            "sessionid",
            "stablepeer",
            "stablepeerid",
            "targetdeviceid",
            "trackid",
            "tunnelipaddress",
            "tunnelipaddressstring",
            "uniqueidentifier",
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
            "publickey",
            "publickeybase64",
            "refreshtoken",
            "remotedescription",
            "sdp",
            "token",
            "xwingpublickey",
        }:
            return "<redacted-secret>"
        if normalized_key in {
            "account",
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
            "localaccount",
            "localaccountdisplayname",
            "localip",
            "localnebula",
            "localnebulaid",
            "nebula",
            "nebulaid",
            "noticeaccount",
            "noticeaccountdisplayname",
            "noticenebula",
            "noticenebulaid",
            "reason",
            "relay",
            "remoteendpoint",
            "remoteaccount",
            "remoteaccountdisplayname",
            "remoteip",
            "remotenebula",
            "remotenebulaid",
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
        if normalized_key in {
            "provisioningprofile",
            "provisioningprofileuuid",
            "signingfingerprint",
            "signingidentity",
            "teamidentifier",
        }:
            return "<redacted-signing-metadata>"
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
    # Preserve newline-delimited JSON as JSONL. Falling back to text redaction
    # for mixed-format logs remains fail-closed because the public scanner
    # independently rejects any sensitive field that was not transformed.
    raw_lines = [line for line in text.splitlines() if line.strip()]
    redacted_lines = []
    try:
        for line in raw_lines:
            redacted_lines.append(
                json.dumps(redact_json(json.loads(line)), sort_keys=True, separators=(",", ":"))
            )
    except json.JSONDecodeError:
        sys.stdout.write(redact_text(text))
    else:
        if redacted_lines:
            sys.stdout.write("\n".join(redacted_lines) + "\n")
        else:
            sys.stdout.write(redact_text(text))
else:
    if jsonl_mode:
        sys.stdout.write(json.dumps(redact_json(payload), sort_keys=True, separators=(",", ":")))
    else:
        sys.stdout.write(json.dumps(redact_json(payload), indent=2, sort_keys=True))
    sys.stdout.write("\n")
PY
}

skybridge_smoke_public_artifact_file_name() {
  local name="${1:?missing artifact file name}"
  case "${name}" in
    *.log|*.json|*.jsonl|*.txt|*.csv) return 0 ;;
    *) return 1 ;;
  esac
}

skybridge_smoke_private_capture_artifact_file_name() {
  local name="${1:?missing artifact file name}"
  case "${name}" in
    *.[pP][nN][gG]|*.[jJ][pP][gG]|*.[jJ][pP][eE][gG]|*.[hH][eE][iI][cC]|*.[hH][eE][iI][fF]|*.[mM][oO][vV]|*.[mM][pP]4|*.[mM]4[vV]) return 0 ;;
    *) return 1 ;;
  esac
}

skybridge_smoke_private_secret_artifact_file_name() {
  local name="${1:?missing artifact file name}"
  case "${name}" in
    *auth-session*.json|*auth_session*.json) return 0 ;;
    *) return 1 ;;
  esac
}

skybridge_smoke_schema_validated_public_artifact_file_name() {
  local name="${1:?missing artifact file name}"
  case "${name}" in
    macos-release-candidate.json|\
    mac-product-session.log|mac-product-session-capture.json|\
    ios-product-session.log|ios-product-session-capture.json|\
    ios-product-installation-capture.json) return 0 ;;
    *) return 1 ;;
  esac
}

skybridge_smoke_materialize_public_artifacts() {
  local device_label="${1:?missing device label}"
  local artifact_dir="${2:?missing artifact dir}"
  local public_dir="${3:?missing public artifact dir}"
  shift 3
  local formal_product_mode="${SKYBRIDGE_FORMAL_PRODUCT_ARTIFACTS:-0}"
  case "${formal_product_mode}" in
    0|1) ;;
    *) echo "SKYBRIDGE_FORMAL_PRODUCT_ARTIFACTS must be 0 or 1" >&2; return 2 ;;
  esac

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
  local public_parent_abs
  local public_name
  local public_abs
  artifact_abs="$(cd "${artifact_dir}" && pwd -P)"
  public_parent="$(dirname "${public_dir}")"
  mkdir -p "${public_parent}"
  public_parent_abs="$(cd "${public_parent}" && pwd -P)"
  public_name="$(basename "${public_dir}")"
  if [[ -z "${public_name}" || "${public_name}" == "." || "${public_name}" == ".." ]]; then
    echo "refusing unsafe public artifact directory: ${public_dir}" >&2
    return 2
  fi
  public_abs="${public_parent_abs}/${public_name}"

  if [[ "${public_abs}" == "/" ||
        "${public_abs}" == "${artifact_abs}" ||
        "${public_abs}" == "${artifact_abs}/"* ||
        "${artifact_abs}" == "${public_abs}/"* ]]; then
    echo "refusing unsafe public artifact directory: ${public_dir}" >&2
    return 2
  fi
  if [[ -L "${public_abs}" || ( -e "${public_abs}" && ! -d "${public_abs}" ) ]]; then
    echo "refusing unsafe public artifact directory: ${public_dir}" >&2
    return 2
  fi
  if [[ "${formal_product_mode}" == "1" && -e "${public_abs}" ]]; then
    echo "formal public artifact destination must be new: ${public_dir}" >&2
    return 2
  fi
  if [[ "${formal_product_mode}" == "0" \
     && -d "${public_abs}" \
     && ! -f "${public_abs}/skybridge-public-artifacts.json" ]]; then
    echo "refusing to replace unowned public artifact directory: ${public_dir}" >&2
    return 2
  fi

  local staging_abs
  staging_abs="$(mktemp -d "${public_parent_abs}/.${public_name}.tmp.XXXXXX")"
  if (
    set -euo pipefail
    trap 'if [[ -n "${staging_abs:-}" && -d "${staging_abs}" ]]; then rm -rf -- "${staging_abs}"; fi' EXIT

    if [[ "${formal_product_mode}" == "1" ]]; then
      expected_formal_files="$(cat <<'EOF'
ios-product-installation-capture.json
ios-product-session-capture.json
ios-product-session.log
ios-production-identity-proof.json
mac-product-session-capture.json
mac-product-session.log
macos-release-candidate.json
release-acceptance.json
EOF
)"
      actual_formal_files="$(find "${artifact_abs}" -mindepth 1 -maxdepth 1 -type f -print \
        | sed 's#^.*/##' | LC_ALL=C sort)"
      [[ "${actual_formal_files}" == "${expected_formal_files}" ]] || {
        echo "formal product artifact directory does not match the fixed eight-file contract" >&2
        exit 1
      }
    fi

    if [[ -e "${artifact_abs}/ios-product-session.log" \
       || -L "${artifact_abs}/ios-product-session.log" \
       || -e "${artifact_abs}/ios-product-session-capture.json" \
       || -L "${artifact_abs}/ios-product-session-capture.json" ]]; then
      for product_file in \
        mac-product-session.log mac-product-session-capture.json \
        ios-product-session.log ios-product-session-capture.json; do
        [[ -f "${artifact_abs}/${product_file}" && ! -L "${artifact_abs}/${product_file}" ]] || {
          echo "paired connectivity product evidence is incomplete: ${product_file}" >&2
          exit 1
        }
      done
      python3 "${ROOT_DIR}/Scripts/validate_product_release_evidence_log.py" \
        validate-capture --artifact-dir "${artifact_abs}" >/dev/null
    elif [[ -e "${artifact_abs}/mac-product-session.log" \
         || -L "${artifact_abs}/mac-product-session.log" \
         || -e "${artifact_abs}/mac-product-session-capture.json" \
         || -L "${artifact_abs}/mac-product-session-capture.json" ]]; then
      python3 "${ROOT_DIR}/Scripts/validate_product_release_evidence_log.py" \
        validate-capture --artifact-dir "${artifact_abs}" >/dev/null
    fi
    if [[ -e "${artifact_abs}/ios-product-installation-capture.json" \
       || -L "${artifact_abs}/ios-product-installation-capture.json" ]]; then
      python3 "${ROOT_DIR}/Scripts/extract_ios_product_release_evidence.py" \
        validate-installation-capture \
        --capture "${artifact_abs}/ios-product-installation-capture.json" >/dev/null
    fi
    if [[ -f "${artifact_abs}/ios-product-installation-capture.json" \
       && -f "${artifact_abs}/ios-production-identity-proof.json" ]]; then
      python3 "${ROOT_DIR}/Scripts/extract_ios_production_identity_evidence.py" \
        validate-proof \
        --proof "${artifact_abs}/ios-production-identity-proof.json" >/dev/null
    fi

    local source_path
    local name
    local rel_path
    local dest_path
    while IFS= read -r -d "" source_path; do
      name="$(basename "${source_path}")"
      rel_path="${source_path#"${artifact_abs}"/}"
      if [[ "${rel_path}" == "${source_path}" || "${rel_path}" == .* || "${rel_path}" == */../* || "${rel_path}" == ../* ]]; then
        echo "refusing unsafe smoke artifact path: ${source_path}" >&2
        exit 2
      fi
      if skybridge_smoke_schema_validated_public_artifact_file_name "${name}" \
         && [[ "${rel_path}" != "${name}" ]]; then
        echo "schema-validated public artifact name must be top-level: ${rel_path}" >&2
        exit 2
      fi
      if skybridge_smoke_private_secret_artifact_file_name "${name}"; then
        continue
      fi
      if ! skybridge_smoke_public_artifact_file_name "${name}"; then
        if skybridge_smoke_private_capture_artifact_file_name "${name}"; then
          continue
        fi
        echo "unsupported smoke artifact file extension in public materializer input: ${rel_path}" >&2
        exit 2
      fi
      dest_path="${staging_abs}/${rel_path}"
      mkdir -p "$(dirname "${dest_path}")"
      if [[ "${name}" == "macos-release-candidate.json" ]]; then
        python3 "${ROOT_DIR}/Scripts/macos_release_candidate_identity.py" validate \
          --identity "${source_path}" >/dev/null
        /bin/cp -p "${source_path}" "${dest_path}"
      elif [[ "${name}" == "mac-product-session.log" \
           || "${name}" == "mac-product-session-capture.json" \
           || "${name}" == "ios-product-session.log" \
           || "${name}" == "ios-product-session-capture.json" \
           || "${name}" == "ios-product-installation-capture.json" \
           || ( "${name}" == "ios-production-identity-proof.json" \
             && -f "${artifact_abs}/ios-product-installation-capture.json" ) ]]; then
        /bin/cp -p "${source_path}" "${dest_path}"
      elif [[ "${name}" == *.jsonl ]]; then
        SKYBRIDGE_SMOKE_REDACTION_FORMAT=jsonl \
          skybridge_smoke_public_redact_stream "${device_label}" "$@" <"${source_path}" >"${dest_path}"
      else
        skybridge_smoke_public_redact_stream "${device_label}" "$@" <"${source_path}" >"${dest_path}"
      fi
    done < <(
      find "${artifact_abs}" \
        \( -name .build -o -name .git -o -name DerivedData-ios -o -name DerivedData-mac-online \) -prune \
        -o -type f -print0
    )

    if [[ "${formal_product_mode}" == "0" ]]; then
      printf '%s\n' '{"kind":"skybridge-public-smoke-artifacts","schemaVersion":1}' \
        >"${staging_abs}/skybridge-public-artifacts.json"
    fi
    skybridge_smoke_check_public_artifacts "${staging_abs}" "$@"

    local backup_abs=""
    if [[ -d "${public_abs}" ]]; then
      backup_abs="$(mktemp -d "${public_parent_abs}/.${public_name}.backup.XXXXXX")"
      rmdir "${backup_abs}"
      mv "${public_abs}" "${backup_abs}"
    fi
    if ! mv "${staging_abs}" "${public_abs}"; then
      if [[ -n "${backup_abs}" && -d "${backup_abs}" ]]; then
        mv "${backup_abs}" "${public_abs}" || true
      fi
      exit 1
    fi
    staging_abs=""
    if [[ -n "${backup_abs}" && -d "${backup_abs}" ]]; then
      rm -rf -- "${backup_abs}"
    fi
    trap - EXIT
  ); then
    return 0
  else
    local materialize_status=$?
    return "${materialize_status}"
  fi
}

skybridge_smoke_check_public_artifacts() {
  local public_dir="${1:?missing public artifact dir}"
  shift

  if [[ ! -d "${public_dir}" ]]; then
    echo "public smoke artifact directory does not exist: ${public_dir}" >&2
    return 2
  fi

  if [[ -f "${public_dir}/macos-release-candidate.json" ]]; then
    python3 "${ROOT_DIR:-$(pwd)}/Scripts/macos_release_candidate_identity.py" validate \
      --identity "${public_dir}/macos-release-candidate.json" >/dev/null || return 1
  fi
  if [[ -e "${public_dir}/ios-product-session.log" \
     || -L "${public_dir}/ios-product-session.log" \
     || -e "${public_dir}/ios-product-session-capture.json" \
     || -L "${public_dir}/ios-product-session-capture.json" ]]; then
    for product_file in \
      mac-product-session.log mac-product-session-capture.json \
      ios-product-session.log ios-product-session-capture.json; do
      [[ -f "${public_dir}/${product_file}" && ! -L "${public_dir}/${product_file}" ]] || {
        echo "paired connectivity product evidence is incomplete: ${product_file}" >&2
        return 1
      }
    done
    python3 "${ROOT_DIR:-$(pwd)}/Scripts/validate_product_release_evidence_log.py" \
      validate-capture \
      --artifact-dir "${public_dir}" >/dev/null || return 1
  elif [[ -e "${public_dir}/mac-product-session.log" \
     || -L "${public_dir}/mac-product-session.log" \
     || -e "${public_dir}/mac-product-session-capture.json" \
     || -L "${public_dir}/mac-product-session-capture.json" ]]; then
    python3 "${ROOT_DIR:-$(pwd)}/Scripts/validate_product_release_evidence_log.py" \
      validate-capture \
      --artifact-dir "${public_dir}" >/dev/null || return 1
  fi
  if [[ -e "${public_dir}/ios-product-installation-capture.json" \
     || -L "${public_dir}/ios-product-installation-capture.json" ]]; then
    python3 "${ROOT_DIR:-$(pwd)}/Scripts/extract_ios_product_release_evidence.py" \
      validate-installation-capture \
      --capture "${public_dir}/ios-product-installation-capture.json" >/dev/null || return 1
  fi

  python3 - "${public_dir}" "${ROOT_DIR:-$(pwd)}" "$@" <<'PY'
import ipaddress
import json
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
    "account",
    "accountdisplayname",
    "address",
    "apikey",
    "authsession",
    "audittoken",
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
    "declareddeviceid",
    "dedupekey",
    "device",
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
    "keyid",
    "localdescription",
    "localaccount",
    "localaccountdisplayname",
    "localdeviceid",
    "localendpoint",
    "localip",
    "localhostnames",
    "localnebula",
    "localnebulaid",
    "mlkempublickey",
    "name",
    "nebula",
    "nebulaid",
    "noticeaccount",
    "noticeaccountdisplayname",
    "noticenebula",
    "noticenebulaid",
    "path",
    "p2pdeviceid",
    "peer",
    "pinnedprotocolidentity",
    "potentialhostnames",
    "privatekey",
    "provisioningprofile",
    "provisioningprofileuuid",
    "publickey",
    "publickeybase64",
    "pubkeyfp",
    "relay",
    "refreshtoken",
    "remotedescription",
    "remoteaccount",
    "remoteaccountdisplayname",
    "remotedeviceid",
    "remoteendpoint",
    "remoteip",
    "remotenebula",
    "remotenebulaid",
    "requesterprotocolidentity",
    "reason",
    "routeidentifier",
    "serialnumber",
    "selectedcandidate",
    "selectedcandidatepair",
    "session",
    "sessionid",
    "sdp",
    "stablepeerid",
    "stablepeer",
    "signingfingerprint",
    "signingidentity",
    "sub",
    "targetdeviceid",
    "teamidentifier",
    "tenantid",
    "token",
    "trackid",
    "tunnelipaddress",
    "tunnelipaddressstring",
    "udid",
    "uniqueidentifier",
    "url",
    "userid",
    "useridentifier",
    "xwingpublickey",
}
prefixed_sensitive_key_suffixes = {
    "accesstoken",
    "apikey",
    "authorization",
    "bearertoken",
    "clientsecret",
    "connectioncode",
    "connectlink",
    "declareddeviceid",
    "deviceid",
    "identitykey",
    "ipaddress",
    "ipaddressstring",
    "localdeviceid",
    "nebulaid",
    "p2pdeviceid",
    "privatekey",
    "publickey",
    "refreshtoken",
    "remotedeviceid",
    "sessionid",
    "targetdeviceid",
    "tenantid",
    "token",
    "userid",
    "useridentifier",
}
ipv4_octet = r"(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
private_ipv4_endpoint_pattern = re.compile(
    rf"(?<![0-9.])(?:"
    rf"10\.{ipv4_octet}\.{ipv4_octet}\.{ipv4_octet}|"
    rf"127\.{ipv4_octet}\.{ipv4_octet}\.{ipv4_octet}|"
    rf"169\.254\.{ipv4_octet}\.{ipv4_octet}|"
    rf"172\.(?:1[6-9]|2[0-9]|3[01])\.{ipv4_octet}\.{ipv4_octet}|"
    rf"192\.168\.{ipv4_octet}\.{ipv4_octet}"
    rf")(?::[0-9]{{1,5}})?(?![0-9.])"
)
ipv6_candidate_pattern = re.compile(
    r"(?<![0-9A-Fa-f:.%])(?:"
    r"\[(?P<bracketed>[0-9A-Fa-f:.]+(?:%[A-Za-z0-9_.-]+)?)\](?::[0-9]{1,5})?"
    r"|(?P<bare>[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*(?:%[A-Za-z0-9_.-]+)?)"
    r")(?![0-9A-Fa-f:.%])"
)

def contains_raw_ipv6_literal(value: str) -> bool:
    for match in ipv6_candidate_pattern.finditer(value):
        candidate = match.group("bracketed") or match.group("bare")
        address_without_scope = candidate.split("%", 1)[0]
        try:
            address = ipaddress.ip_address(address_without_scope)
        except ValueError:
            continue
        if address.version == 6:
            return True
    return False
patterns = [
    ("raw connect link", re.compile(r"skybridge://")),
    ("raw stable production identity reference", re.compile(r"\bid1:[0-9a-f]{32}\b")),
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
            r'"(?:accessToken|refreshToken|apiKey|authorization|bearerToken|clientSecret|iceCandidate|icePwd|iceUfrag|localDescription|mlkemPublicKey|privateKey|publicKey|publicKeyBase64|remoteDescription|sdp|token|xwingPublicKey)"\s*:\s*'
            r'"(?!<redacted)[^"]+"',
            re.IGNORECASE,
        ),
    ),
    (
        "raw Apple device identifier field",
        re.compile(
            r'"(?:identifier|udid|serialNumber|device|deviceName|deviceIdentifier|ecid|identityKey|deviceId|declaredDeviceId|localDeviceId|remoteDeviceId|targetDeviceId|p2pDeviceId|cloudDeviceId|dedupeKey|keyId|peer|peerId|pinnedProtocolIdentity|pubKeyFP|requesterProtocolIdentity|stablePeer|stablePeerId|uniqueIdentifier|session|sessionId|trackId)"\s*:\s*'
            r'"(?!<redacted)[^"]+"',
            re.IGNORECASE,
        ),
    ),
    (
        "raw public identity or route field",
        re.compile(
            r'"(?:(?:notice|remote|local)?Account(?:DisplayName)?|address|bonjourServiceName|controlEndpoint|displayName|endpoint|endpointHost|host|(?:remote|local)?IP|(?:notice|remote|local)?Nebula(?:Id)?|reason|relay|routeIdentifier|sub|tenantId|url|userId|userIdentifier)"\s*:\s*'
            r'"(?!<redacted)[^"]+"',
            re.IGNORECASE,
        ),
    ),
    (
        "raw public identity or route assignment",
        re.compile(
            r"\b(?:(?:notice|remote|local)?Account(?:DisplayName)?|address|bonjourServiceName|controlEndpoint|displayName|endpoint|endpointHost|host|(?:remote|local)?IP|(?:notice|remote|local)?Nebula(?:Id)?|reason|relay|routeIdentifier|sub|tenantId|userId|userIdentifier)="
            r"(?!<redacted\b|<redacted>)[^\s]+",
            re.IGNORECASE,
        ),
    ),
    (
        "raw device or stable identity assignment",
        re.compile(
            r"\b(?:identityKey|declaredDeviceId|targetDeviceId|localDeviceId|peer(?:Id)?|remoteDeviceId|stablePeer(?:Id)?|device(?:Id|Name)?|p2pDeviceId|cloudDeviceId|pubKeyFP|dedupeKey|keyId|requesterProtocolIdentity|pinnedProtocolIdentity|uniqueIdentifier)="
            r"(?!<redacted\b|<redacted>)[^\s]+",
            re.IGNORECASE,
        ),
    ),
    (
        "raw bare device identity assignment",
        re.compile(
            r"(^|[ \t])(?:sender|target|transfer)=(?!<redacted\b|<redacted>)[^\s]+",
            re.IGNORECASE | re.MULTILINE,
        ),
    ),
    (
        "raw bare route endpoint assignment",
        re.compile(
            r"(^|[ \t])(?:requested|resolved)=(?!<redacted\b|<redacted>)[^\s]+",
            re.IGNORECASE | re.MULTILINE,
        ),
    ),
    (
        "raw human name or identity-list assignment",
        re.compile(
            r"(^|[ \t])(?:name|candidates|peers|liveRoutes|eligibleRoutes)=(?!<redacted\b|<redacted>).*?(?=\s+[A-Za-z][A-Za-z0-9_-]*=|$)",
            re.IGNORECASE | re.MULTILINE,
        ),
    ),
    (
        "raw shorthand device identity assignment",
        re.compile(
            r"(^|[ \t])id=id:(?!<redacted\b|<redacted>)[^\s]+",
            re.IGNORECASE | re.MULTILINE,
        ),
    ),
    (
        "raw public key assignment",
        re.compile(
            r"\b(?:(?:peer|kem|pqc|xwing|mlkem|ed25519|x25519)[_-]?)?public[_-]?key(?:[_-]?base64)?="
            r"(?!<redacted\b|<redacted>)[^\s&]+",
            re.IGNORECASE,
        ),
    ),
    (
        "raw signing metadata assignment",
        re.compile(
            r"\b(?:signing[_-]?(?:fingerprint|identity)|provisioning[_-]?profile(?:[_-]?uuid)?|team[_-]?identifier)="
            r"(?!<redacted\b|<redacted>)[^\s&]+",
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
    ("raw Swift debug session id", re.compile(r'\b(?:session|sessionId|trackId)\s*:\s*"(?!<redacted\b)[^"]+"', re.IGNORECASE)),
    (
        "raw provisioning profile UUID path",
        re.compile(
            r"Provisioning(?:\\ | )Profiles/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.mobileprovision"
        ),
    ),
    ("raw private IPv4 endpoint", private_ipv4_endpoint_pattern),
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

def is_sensitive_key(value: str) -> bool:
    normalized = normalize_key(value)
    return normalized in sensitive_key_values or any(
        normalized.endswith(suffix) for suffix in prefixed_sensitive_key_suffixes
    )

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
            if is_sensitive_key(str(key)) and contains_unredacted_sensitive_value(item):
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
        except json.JSONDecodeError:
            findings.append((rel_path, "invalid structured JSON"))
            continue
        inspect_json_fields(payload, rel_path, findings)

findings = []
scanned_count = 0
schema_validated_names = {
    "macos-release-candidate.json",
    "mac-product-session.log",
    "mac-product-session-capture.json",
    "ios-product-session.log",
    "ios-product-session-capture.json",
    "ios-product-installation-capture.json",
}
if os.path.isfile(os.path.join(public_dir, "ios-product-installation-capture.json")):
    schema_validated_names.add("ios-production-identity-proof.json")
for current_root, dirs, files in os.walk(public_dir):
    dirs[:] = [name for name in dirs if name not in {".build", "DerivedData-ios", "DerivedData-mac-online"}]
    for name in files:
        path = os.path.join(current_root, name)
        rel_path = os.path.relpath(path, public_dir)
        normalized_name = name.lower()
        if normalized_name.endswith(".json") and (
            "auth-session" in normalized_name or "auth_session" in normalized_name
        ):
            findings.append((rel_path, "private auth-session artifact is forbidden in public output"))
            continue
        if not name.endswith(extensions):
            findings.append((rel_path, "unsupported public artifact file extension"))
            continue
        scanned_count += 1
        if name in schema_validated_names and rel_path != name:
            findings.append(
                (rel_path, "schema-validated public artifact name must be top-level")
            )
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError as exc:
            findings.append((rel_path, f"unreadable public artifact: {exc}"))
            continue
        if re.search(r"\bid1:[0-9a-f]{32}\b", text):
            findings.append((rel_path, "raw stable production identity reference"))
        if name in schema_validated_names:
            # The preceding schema validator establishes this intentionally public
            # fixed schema. It contains no account, device, address, or input detail.
            continue
        inspect_structured_json(text, rel_path, findings)
        for token in sorted(set(tokens), key=lambda value: (-len(value), value)):
            if token and token in text:
                findings.append((rel_path, "raw configured token"))
                break
        for label, pattern in patterns:
            if pattern.search(text):
                findings.append((rel_path, label))
        if contains_raw_ipv6_literal(text):
            findings.append((rel_path, "raw IPv6 endpoint"))

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
