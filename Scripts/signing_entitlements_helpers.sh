#!/usr/bin/env bash

skybridge_signing_policy_log() {
  local message="$1"
  if declare -F log >/dev/null 2>&1; then
    log "${message}"
  else
    echo "[signing-policy] ${message}"
  fi
}

skybridge_set_plist_bool() {
  local plist_path="$1"
  local key="$2"
  local value="$3"

  if [[ "${value}" == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Set :${key} true" "${plist_path}" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :${key} bool true" "${plist_path}" >/dev/null 2>&1
  else
    /usr/libexec/PlistBuddy -c "Set :${key} false" "${plist_path}" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c "Add :${key} bool false" "${plist_path}" >/dev/null 2>&1
  fi
}

skybridge_set_plist_string() {
  local plist_path="$1"
  local key="$2"
  local value="$3"

  /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${plist_path}" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "${plist_path}" >/dev/null 2>&1
}

skybridge_read_plist_bool() {
  local plist_path="$1"
  local key="$2"

  python3 - "${plist_path}" "${key}" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
key = sys.argv[2]

if not plist_path.exists():
    raise SystemExit(1)

with plist_path.open("rb") as fh:
    plist = plistlib.load(fh)

value = plist.get(key)
if isinstance(value, bool):
    print("1" if value else "0")
    raise SystemExit(0)

raise SystemExit(1)
PY
}

skybridge_read_plist_string() {
  local plist_path="$1"
  local key="$2"

  python3 - "${plist_path}" "${key}" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
key = sys.argv[2]

if not plist_path.exists():
    raise SystemExit(1)

with plist_path.open("rb") as fh:
    plist = plistlib.load(fh)

value = plist.get(key)
if isinstance(value, str) and value.strip():
    print(value.strip())
    raise SystemExit(0)

raise SystemExit(1)
PY
}

skybridge_normalize_apple_sign_in_mode() {
  local raw_value="${1:-}"
  local normalized="${raw_value//-/_}"
  normalized="${normalized// /_}"
  normalized="$(printf '%s' "${normalized}" | tr '[:upper:]' '[:lower:]')"

  case "${normalized}" in
    native)
      printf 'native\n'
      ;;
    web|browser|browser_session|web_session|aswebauthenticationsession|secure_web_session)
      printf 'web_session\n'
      ;;
    disabled|off|none)
      printf 'disabled\n'
      ;;
    auto|automatic|"")
      printf 'auto\n'
      ;;
    *)
      return 1
      ;;
  esac
}

skybridge_resolve_required_apple_sign_in_mode() {
  local raw_mode="${SKYBRIDGE_REQUIRE_APPLE_SIGN_IN_MODE:-}"
  local normalized_mode=""

  if [[ -z "${raw_mode}" && "${SKYBRIDGE_REQUIRE_APPLE_SIGN_IN:-0}" == "1" ]]; then
    raw_mode="native"
  fi

  normalized_mode="$(skybridge_normalize_apple_sign_in_mode "${raw_mode}")" || {
    echo "错误：未知的 SKYBRIDGE_REQUIRE_APPLE_SIGN_IN_MODE=${raw_mode}；允许值为 native、web_session、disabled、auto。" >&2
    return 1
  }

  printf '%s\n' "${normalized_mode}"
}

skybridge_default_app_packaging_entitlements_path() {
  local root_dir="$1"
  local requested_mode="${2:-auto}"
  local normalized_mode=""

  normalized_mode="$(skybridge_normalize_apple_sign_in_mode "${requested_mode}")" || return 1

  case "${normalized_mode}" in
    web_session|disabled)
      printf '%s\n' "${root_dir}/Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.packaging.entitlements"
      ;;
    *)
      printf '%s\n' "${root_dir}/Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.native.packaging.entitlements"
      ;;
  esac
}

skybridge_set_effective_apple_sign_in_mode() {
  local info_plist_path="$1"
  local mode="$2"

  skybridge_set_plist_string "${info_plist_path}" "SKYBRIDGE_APPLE_SIGN_IN_MODE" "${mode}"

  if [[ "${mode}" == "native" ]]; then
    export SKYBRIDGE_SIGNING_EFFECTIVE_NATIVE_APPLE_SIGN_IN=1
    export SKYBRIDGE_SIGNING_EFFECTIVE_APPLE_SIGN_IN=1
    skybridge_set_plist_bool "${info_plist_path}" "SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN" 1
  else
    export SKYBRIDGE_SIGNING_EFFECTIVE_NATIVE_APPLE_SIGN_IN=0
    if [[ "${mode}" == "disabled" ]]; then
      export SKYBRIDGE_SIGNING_EFFECTIVE_APPLE_SIGN_IN=0
    else
      export SKYBRIDGE_SIGNING_EFFECTIVE_APPLE_SIGN_IN=1
    fi
    skybridge_set_plist_bool "${info_plist_path}" "SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN" 0
  fi

  export SKYBRIDGE_SIGNING_EFFECTIVE_APPLE_SIGN_IN_MODE="${mode}"
}

skybridge_entitlements_request_applesignin() {
  local entitlements_path="$1"

  python3 - "${entitlements_path}" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)

with path.open("rb") as fh:
    entitlements = plistlib.load(fh)

value = entitlements.get("com.apple.developer.applesignin")
if isinstance(value, list) and any(str(item).strip() for item in value):
    raise SystemExit(0)

raise SystemExit(1)
PY
}

skybridge_entitlements_request_application_groups() {
  local entitlements_path="$1"

  python3 - "${entitlements_path}" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)

with path.open("rb") as fh:
    entitlements = plistlib.load(fh)

value = entitlements.get("com.apple.security.application-groups")
if isinstance(value, list) and any(str(item).strip() for item in value):
    raise SystemExit(0)

raise SystemExit(1)
PY
}

skybridge_provisionprofile_supports_applesignin() {
  local profile_path="$1"
  [[ -n "${profile_path}" && -f "${profile_path}" ]] || return 1

  python3 - "${profile_path}" <<'PY'
import plistlib
import subprocess
import sys
from pathlib import Path


def load_profile(path: Path):
    payload = path.read_bytes()
    try:
        return plistlib.loads(payload)
    except Exception:
        pass
    for command in (
        ["security", "cms", "-D", "-i", str(path)],
        ["openssl", "smime", "-inform", "DER", "-verify", "-noverify", "-in", str(path)],
    ):
        completed = subprocess.run(command, check=False, capture_output=True)
        if completed.returncode == 0 and completed.stdout:
            return plistlib.loads(completed.stdout)
    raise SystemExit(1)


profile_path = Path(sys.argv[1])
if not profile_path.exists():
    raise SystemExit(1)

profile = load_profile(profile_path)
entitlements = profile.get("Entitlements", {})
value = entitlements.get("com.apple.developer.applesignin")

if isinstance(value, list) and any(str(item).strip() for item in value):
    raise SystemExit(0)

raise SystemExit(1)
PY
}

skybridge_profile_supports_requested_profile_backed_entitlements() {
  local profile_path="${1:-}"
  local entitlements_path="$2"

  python3 - "${profile_path}" "${entitlements_path}" <<'PY'
import plistlib
import subprocess
import sys
from pathlib import Path


def load_profile(path: Path):
    payload = path.read_bytes()
    try:
        return plistlib.loads(payload)
    except Exception:
        pass
    for command in (
        ["security", "cms", "-D", "-i", str(path)],
        ["openssl", "smime", "-inform", "DER", "-verify", "-noverify", "-in", str(path)],
    ):
        completed = subprocess.run(command, check=False, capture_output=True)
        if completed.returncode == 0 and completed.stdout:
            return plistlib.loads(completed.stdout)
    raise SystemExit(1)


profile_arg = sys.argv[1].strip()
entitlements_path = Path(sys.argv[2])
if not entitlements_path.exists():
    raise SystemExit(1)

with entitlements_path.open("rb") as fh:
    requested = plistlib.load(fh)

array_entitlements = [
    "com.apple.developer.applesignin",
    "com.apple.security.application-groups",
    "keychain-access-groups",
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.icloud-services",
    "com.apple.developer.ubiquity-container-identifiers",
]
string_entitlements = [
    "com.apple.application-identifier",
    "aps-environment",
    "com.apple.developer.aps-environment",
    "com.apple.developer.ubiquity-kvstore-identifier",
    "com.apple.developer.icloud-container-environment",
]
boolean_entitlements = [
    "com.apple.developer.device-information.user-assigned-device-name",
]

def collect_requested_entitlements(entitlements):
    requested_arrays = {}
    for key in array_entitlements:
        value = entitlements.get(key) or []
        if isinstance(value, str):
            values = [value.strip()] if value.strip() else []
        else:
            values = [str(item).strip() for item in value if str(item).strip()]
        if values:
            requested_arrays[key] = set(values)

    requested_strings = {}
    for key in string_entitlements:
        value = entitlements.get(key)
        if isinstance(value, str) and value.strip():
            requested_strings[key] = value.strip()

    requested_booleans = {}
    for key in boolean_entitlements:
        if entitlements.get(key) is True:
            requested_booleans[key] = True

    return requested_arrays, requested_strings, requested_booleans


requested_arrays, requested_strings, requested_booleans = collect_requested_entitlements(requested)

if not requested_arrays and not requested_strings and not requested_booleans:
    raise SystemExit(0)

if not profile_arg:
    raise SystemExit(1)

profile_path = Path(profile_arg)
if not profile_path.exists():
    raise SystemExit(1)

profile = load_profile(profile_path)
profile_entitlements = profile.get("Entitlements", {})

def dotted(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    return value if value.endswith(".") else f"{value}."


def replace_tokens(value, replacements):
    if isinstance(value, str):
        expanded = value
        for token, replacement in replacements.items():
            if replacement:
                expanded = expanded.replace(token, replacement)
        return expanded
    if isinstance(value, list):
        return [replace_tokens(item, replacements) for item in value]
    if isinstance(value, dict):
        return {key: replace_tokens(item, replacements) for key, item in value.items()}
    return value


team_identifier = ""
profile_team = profile.get("TeamIdentifier") or []
if profile_team:
    team_identifier = str(profile_team[0]).strip()

application_prefix = ""
profile_application_prefix = profile.get("ApplicationIdentifierPrefix") or []
if profile_application_prefix:
    application_prefix = str(profile_application_prefix[0]).strip()
application_prefix = application_prefix or team_identifier

requested = replace_tokens(
    requested,
    {
        "$(TeamIdentifierPrefix)": dotted(team_identifier),
        "${TeamIdentifierPrefix}": dotted(team_identifier),
        "$(AppIdentifierPrefix)": dotted(application_prefix),
        "${AppIdentifierPrefix}": dotted(application_prefix),
    },
)
requested_arrays, requested_strings, requested_booleans = collect_requested_entitlements(requested)

def normalize_values(value):
    if isinstance(value, str):
        return {value.strip()} if value.strip() else set()
    if isinstance(value, (list, tuple, set)):
        return {str(item).strip() for item in value if str(item).strip()}
    return set()


def profile_value_covers_requested(profile_value: str, requested_value: str) -> bool:
    if profile_value == requested_value or profile_value == "*":
        return True
    if profile_value.endswith(".*"):
        return requested_value.startswith(profile_value[:-1])
    return False


def profile_values_cover_requested(profile_values, requested_values) -> bool:
    return all(
        any(profile_value_covers_requested(profile_value, requested_value) for profile_value in profile_values)
        for requested_value in requested_values
    )


for key, requested_values in requested_arrays.items():
    profile_values = normalize_values(profile_entitlements.get(key))
    if not profile_values_cover_requested(profile_values, requested_values):
        raise SystemExit(1)

for key, requested_value in requested_strings.items():
    profile_values = normalize_values(profile_entitlements.get(key))
    if not profile_values_cover_requested(profile_values, {requested_value}):
        raise SystemExit(1)

for key in requested_booleans:
    if profile_entitlements.get(key) is not True:
        raise SystemExit(1)

raise SystemExit(0)
PY
}

skybridge_profile_supports_requested_application_groups() {
  local profile_path="${1:-}"
  local entitlements_path="$2"

  python3 - "${profile_path}" "${entitlements_path}" <<'PY'
import plistlib
import subprocess
import sys
from pathlib import Path


def load_profile(path: Path):
    payload = path.read_bytes()
    try:
        return plistlib.loads(payload)
    except Exception:
        pass
    for command in (
        ["security", "cms", "-D", "-i", str(path)],
        ["openssl", "smime", "-inform", "DER", "-verify", "-noverify", "-in", str(path)],
    ):
        completed = subprocess.run(command, check=False, capture_output=True)
        if completed.returncode == 0 and completed.stdout:
            return plistlib.loads(completed.stdout)
    raise SystemExit(1)


profile_arg = sys.argv[1].strip()
entitlements_path = Path(sys.argv[2])
if not entitlements_path.exists():
    raise SystemExit(1)

with entitlements_path.open("rb") as fh:
    requested = plistlib.load(fh)

requested_app_groups = {
    str(item).strip()
    for item in (requested.get("com.apple.security.application-groups") or [])
    if str(item).strip()
}

if not requested_app_groups:
    raise SystemExit(0)

if not profile_arg:
    raise SystemExit(1)

profile_path = Path(profile_arg)
if not profile_path.exists():
    raise SystemExit(1)

profile = load_profile(profile_path)
profile_entitlements = profile.get("Entitlements", {})
profile_app_groups = {
    str(item).strip()
    for item in (profile_entitlements.get("com.apple.security.application-groups") or [])
    if str(item).strip()
}

if not requested_app_groups.issubset(profile_app_groups):
    raise SystemExit(1)

raise SystemExit(0)
PY
}

skybridge_profile_supports_requested_restricted_entitlements() {
  local profile_path="${1:-}"
  local entitlements_path="$2"
  skybridge_profile_supports_requested_profile_backed_entitlements "${profile_path}" "${entitlements_path}"
}

skybridge_write_signed_entitlements() {
  local target_path="$1"
  local output_path="$2"

  codesign -d --xml --entitlements - "${target_path}" 1>"${output_path}" 2>/dev/null
  [[ -s "${output_path}" ]]
}

skybridge_expand_build_setting_entitlements() {
  local entitlements_path="$1"
  local profile_path="${2:-}"

  python3 - "${entitlements_path}" "${profile_path}" <<'PY'
import os
import plistlib
import subprocess
import sys
from pathlib import Path


def load_profile(path: Path):
    payload = path.read_bytes()
    try:
        return plistlib.loads(payload)
    except Exception:
        pass
    for command in (
        ["security", "cms", "-D", "-i", str(path)],
        ["openssl", "smime", "-inform", "DER", "-verify", "-noverify", "-in", str(path)],
    ):
        completed = subprocess.run(command, check=False, capture_output=True)
        if completed.returncode == 0 and completed.stdout:
            return plistlib.loads(completed.stdout)
    raise SystemExit(1)


def dotted(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    return value if value.endswith(".") else f"{value}."


def replace_tokens(value, replacements):
    if isinstance(value, str):
        expanded = value
        for token, replacement in replacements.items():
            if replacement:
                expanded = expanded.replace(token, replacement)
        return expanded
    if isinstance(value, list):
        return [replace_tokens(item, replacements) for item in value]
    if isinstance(value, dict):
        return {key: replace_tokens(item, replacements) for key, item in value.items()}
    return value


entitlements_path = Path(sys.argv[1])
profile_arg = sys.argv[2].strip()
if not entitlements_path.exists():
    raise SystemExit(1)

with entitlements_path.open("rb") as fh:
    entitlements = plistlib.load(fh)

profile = {}
if profile_arg:
    profile_path = Path(profile_arg)
    if profile_path.exists():
        profile = load_profile(profile_path)

team_identifier = ""
profile_team = profile.get("TeamIdentifier") or []
if profile_team:
    team_identifier = str(profile_team[0]).strip()
team_identifier = (
    team_identifier
    or os.environ.get("DEVELOPMENT_TEAM", "").strip()
    or os.environ.get("SKYBRIDGE_TEAM_IDENTIFIER", "").strip()
)

application_prefix = ""
profile_application_prefix = profile.get("ApplicationIdentifierPrefix") or []
if profile_application_prefix:
    application_prefix = str(profile_application_prefix[0]).strip()
application_prefix = application_prefix or team_identifier

replacements = {
    "$(TeamIdentifierPrefix)": dotted(team_identifier),
    "${TeamIdentifierPrefix}": dotted(team_identifier),
    "$(AppIdentifierPrefix)": dotted(application_prefix),
    "${AppIdentifierPrefix}": dotted(application_prefix),
}

expanded = replace_tokens(entitlements, replacements)
serialized = plistlib.dumps(expanded, fmt=plistlib.FMT_XML, sort_keys=False)
entitlements_path.write_bytes(serialized)

if profile and b"$(TeamIdentifierPrefix)" in serialized:
    print("未能展开 TeamIdentifierPrefix entitlement 占位符", file=sys.stderr)
    raise SystemExit(1)
if profile and b"$(AppIdentifierPrefix)" in serialized:
    print("未能展开 AppIdentifierPrefix entitlement 占位符", file=sys.stderr)
    raise SystemExit(1)
PY
}

skybridge_validate_provisionprofile_app_identity() {
  local profile_path="$1"
  local bundle_identifier="$2"
  local team_identifier="$3"

  [[ -f "${profile_path}" ]] || {
    echo "错误：provisioning profile 不存在：${profile_path}" >&2
    return 1
  }

  python3 - "${profile_path}" "${bundle_identifier}" "${team_identifier}" <<'PY'
import plistlib
import subprocess
import sys
from pathlib import Path


def load_profile(path: Path):
    payload = path.read_bytes()
    try:
        return plistlib.loads(payload)
    except Exception:
        pass
    for command in (
        ["security", "cms", "-D", "-i", str(path)],
        ["openssl", "smime", "-inform", "DER", "-verify", "-noverify", "-in", str(path)],
    ):
        completed = subprocess.run(command, check=False, capture_output=True)
        if completed.returncode == 0 and completed.stdout:
            return plistlib.loads(completed.stdout)
    print(f"无法解码 provisioning profile: {path}", file=sys.stderr)
    raise SystemExit(1)


profile_path = Path(sys.argv[1])
bundle_identifier = sys.argv[2].strip()
team_identifier = sys.argv[3].strip()

profile = load_profile(profile_path)
platforms = profile.get("Platform", [])
entitlements = profile.get("Entitlements", {})
profile_team = (profile.get("TeamIdentifier") or [""])[0]
app_identifier = entitlements.get("com.apple.application-identifier", "")
expected_app_identifier = f"{team_identifier}.{bundle_identifier}"

if "OSX" not in platforms:
    print(f"provisioning profile 不是 macOS profile: {profile_path}", file=sys.stderr)
    raise SystemExit(1)
if profile_team != team_identifier:
    print(
        f"provisioning profile TeamIdentifier 不匹配: expected={team_identifier} actual={profile_team}",
        file=sys.stderr,
    )
    raise SystemExit(1)
if app_identifier != expected_app_identifier:
    print(
        "provisioning profile application identifier 不匹配: "
        f"expected={expected_app_identifier} actual={app_identifier}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

skybridge_developer_id_distribution_profile_certificate_hashes() {
  local profile_path="$1"

  [[ -f "${profile_path}" ]] || {
    echo "Developer ID provisioning profile does not exist: ${profile_path}" >&2
    return 1
  }

  python3 - "${profile_path}" <<'PY'
import datetime as dt
import hashlib
import plistlib
import subprocess
import sys
from pathlib import Path


def load_profile(path: Path):
    payload = path.read_bytes()
    try:
        return plistlib.loads(payload)
    except Exception:
        pass
    for command in (
        ["security", "cms", "-D", "-i", str(path)],
        ["openssl", "smime", "-inform", "DER", "-verify", "-noverify", "-in", str(path)],
    ):
        completed = subprocess.run(command, check=False, capture_output=True)
        if completed.returncode == 0 and completed.stdout:
            return plistlib.loads(completed.stdout)
    print(f"could not decode Developer ID provisioning profile: {path}", file=sys.stderr)
    raise SystemExit(1)


profile_path = Path(sys.argv[1])
profile = load_profile(profile_path)
entitlements = profile.get("Entitlements") or {}

if "OSX" not in (profile.get("Platform") or []):
    print(f"profile is not a macOS profile: {profile_path}", file=sys.stderr)
    raise SystemExit(1)
if profile.get("ProvisionsAllDevices") is not True:
    print(f"profile is not a Developer ID direct-distribution profile: {profile_path}", file=sys.stderr)
    raise SystemExit(1)
if "ProvisionedDevices" in profile:
    print(f"Developer ID profile unexpectedly contains a device allow-list: {profile_path}", file=sys.stderr)
    raise SystemExit(1)
if "get-task-allow" in entitlements:
    print(f"Developer ID profile unexpectedly contains get-task-allow: {profile_path}", file=sys.stderr)
    raise SystemExit(1)

expires = profile.get("ExpirationDate")
if not isinstance(expires, dt.datetime):
    print(f"Developer ID profile does not contain a valid expiration date: {profile_path}", file=sys.stderr)
    raise SystemExit(1)
now = dt.datetime.now(tz=expires.tzinfo) if expires.tzinfo else dt.datetime.now()
if expires <= now:
    print(f"Developer ID profile has expired: {profile_path}", file=sys.stderr)
    raise SystemExit(1)

certificates = profile.get("DeveloperCertificates") or []
certificate_hashes = {
    hashlib.sha1(bytes(certificate)).hexdigest().upper()
    for certificate in certificates
    if isinstance(certificate, (bytes, bytearray))
}
if not certificate_hashes:
    print(f"Developer ID profile does not contain a usable developer certificate: {profile_path}", file=sys.stderr)
    raise SystemExit(1)
for certificate_hash in sorted(certificate_hashes):
    print(certificate_hash)
PY
}

skybridge_validate_developer_id_distribution_profile_certificate() {
  local profile_path="$1"
  local expected_certificate_sha1="$2"
  local profile_certificate_hashes

  [[ "${expected_certificate_sha1}" =~ ^[0-9A-Fa-f]{40}$ ]] || {
    echo "Expected Developer ID certificate fingerprint is not a SHA-1 fingerprint." >&2
    return 1
  }
  profile_certificate_hashes="$(
    skybridge_developer_id_distribution_profile_certificate_hashes "${profile_path}"
  )" || return 1
  if ! printf '%s\n' "${profile_certificate_hashes}" \
    | grep -Fxiq "${expected_certificate_sha1}"; then
    echo "Developer ID profile does not include the selected signing certificate: ${profile_path}" >&2
    return 1
  fi
}

skybridge_select_unique_profile_bound_codesign_identity_hash() {
  local authority_hashes="$1"
  local profile_hashes="$2"
  local matching_hashes=""
  local match_count
  local candidate_hash
  local identity_hash

  while IFS= read -r candidate_hash; do
    [[ -n "${candidate_hash}" ]] || continue
    [[ "${candidate_hash}" =~ ^[0-9A-F]{40}$ ]] || {
      echo "Resolved code-signing identity does not have a valid SHA-1 fingerprint." >&2
      return 1
    }
    if printf '%s\n' "${profile_hashes}" | grep -Fxq "${candidate_hash}"; then
      matching_hashes+="${candidate_hash}"$'\n'
    fi
  done <<<"${authority_hashes}"

  match_count="$(printf '%s\n' "${matching_hashes}" | awk 'NF { count += 1 } END { print count + 0 }')"
  if [[ "${match_count}" != "1" ]]; then
    echo "Packaged-product authority/profile certificate intersection is not unique (matches=${match_count})." >&2
    return 1
  fi
  identity_hash="$(printf '%s\n' "${matching_hashes}" | sed -n '1p')"
  printf '%s\n' "${identity_hash}"
}

skybridge_resolve_profile_bound_codesign_identity_hash() {
  local profile_path="$1"
  local expected_authority="$2"
  local identities
  local authority_hashes
  local profile_hashes
  local identity_hash

  [[ "${expected_authority}" == Developer\ ID\ Application:* ]] || {
    echo "Expected signing authority is not a Developer ID Application identity." >&2
    return 1
  }
  if ! identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null)"; then
    echo "Unable to enumerate valid local code-signing identities." >&2
    return 1
  fi

  authority_hashes="$(printf '%s\n' "${identities}" | awk -F '"' -v identity="${expected_authority}" '
    $2 == identity {
      prefix = $1
      sub(/^.*\) /, "", prefix)
      gsub(/[[:space:]]/, "", prefix)
      print toupper(prefix)
    }
  ' | awk '!seen[$0]++')"
  profile_hashes="$(
    skybridge_developer_id_distribution_profile_certificate_hashes "${profile_path}"
  )" || return 1

  identity_hash="$(
    skybridge_select_unique_profile_bound_codesign_identity_hash \
      "${authority_hashes}" \
      "${profile_hashes}"
  )" || return 1
  printf '%s\n' "${identity_hash}"
}

skybridge_prepare_signing_entitlements() {
  local source_entitlements="$1"
  local output_entitlements="$2"
  local info_plist_path="$3"
  local profile_path="${4:-}"
  local apple_sign_in_feature_flag="0"
  local required_apple_sign_in_mode=""

  [[ -f "${source_entitlements}" ]] || {
    echo "错误：签名 entitlements 文件不存在：${source_entitlements}" >&2
    return 1
  }

  cp "${source_entitlements}" "${output_entitlements}"
  skybridge_expand_build_setting_entitlements "${output_entitlements}" "${profile_path}" || return 1
  export SKYBRIDGE_SIGNING_EFFECTIVE_NATIVE_APPLE_SIGN_IN=0
  export SKYBRIDGE_SIGNING_EFFECTIVE_APPLE_SIGN_IN=0
  export SKYBRIDGE_SIGNING_EFFECTIVE_APPLE_SIGN_IN_MODE="disabled"
  required_apple_sign_in_mode="$(skybridge_resolve_required_apple_sign_in_mode)" || return 1

  if [[ "$(skybridge_read_plist_bool "${info_plist_path}" "SKYBRIDGE_ENABLE_APPLE_SIGN_IN" 2>/dev/null || echo "0")" == "1" ]]; then
    apple_sign_in_feature_flag="1"
  fi

  if skybridge_entitlements_request_application_groups "${output_entitlements}" && \
     [[ "${SKYBRIDGE_REQUIRE_APP_GROUPS:-0}" == "1" ]] && \
     ! skybridge_profile_supports_requested_application_groups "${profile_path}" "${output_entitlements}"; then
    echo "错误：当前 provisioning profile 不覆盖请求的 App Groups entitlement，但 SKYBRIDGE_REQUIRE_APP_GROUPS=1。" >&2
    echo "请安装包含 com.apple.security.application-groups 的 macOS Developer ID provisioning profile。" >&2
    return 1
  fi

  if [[ "${apple_sign_in_feature_flag}" != "1" || "${required_apple_sign_in_mode}" == "disabled" ]]; then
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.applesignin' "${output_entitlements}" >/dev/null 2>&1 || true
    skybridge_set_effective_apple_sign_in_mode "${info_plist_path}" "disabled"
    skybridge_signing_policy_log "Apple 登录产品开关已关闭或签名策略要求禁用；已移除原生 entitlement，并将运行时模式标记为 disabled"
    return 0
  fi

  if ! skybridge_entitlements_request_applesignin "${source_entitlements}"; then
    if [[ "${required_apple_sign_in_mode}" == "native" ]]; then
      echo "错误：当前发布策略要求原生 Sign in with Apple，但源 entitlements 未请求 com.apple.developer.applesignin。" >&2
      return 1
    fi
    skybridge_set_effective_apple_sign_in_mode "${info_plist_path}" "web_session"
    skybridge_signing_policy_log "源 entitlements 未请求 Sign in with Apple；Apple 登录将以 web_session 模式交付，并保留 SKYBRIDGE_ENABLE_APPLE_SIGN_IN 产品开关"
    return 0
  fi

  if [[ "${required_apple_sign_in_mode}" == "web_session" ]]; then
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.applesignin' "${output_entitlements}" >/dev/null 2>&1 || true
    skybridge_set_effective_apple_sign_in_mode "${info_plist_path}" "web_session"
    skybridge_signing_policy_log "签名策略要求 Apple 登录走 web_session；已显式移除原生 entitlement，并将运行时模式标记为 web_session"
    return 0
  fi

  if skybridge_provisionprofile_supports_applesignin "${profile_path}"; then
    skybridge_set_effective_apple_sign_in_mode "${info_plist_path}" "native"
    skybridge_signing_policy_log "检测到支持 Sign in with Apple 的 provisioning profile；保留原生 entitlement，并将运行时模式标记为 native（不改写 SKYBRIDGE_ENABLE_APPLE_SIGN_IN）"
    return 0
  fi

  if [[ "${required_apple_sign_in_mode}" == "native" ]]; then
    echo "错误：当前签名上下文不支持原生 Sign in with Apple，但发布策略要求 SKYBRIDGE_REQUIRE_APPLE_SIGN_IN_MODE=native。" >&2
    echo "请改用支持原生 Sign in with Apple 的分发通道与 provisioning profile；Developer ID + DMG 应改用 SKYBRIDGE_REQUIRE_APPLE_SIGN_IN_MODE=web_session。" >&2
    return 1
  fi

  /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.applesignin' "${output_entitlements}" >/dev/null 2>&1 || true
  skybridge_set_effective_apple_sign_in_mode "${info_plist_path}" "web_session"
  skybridge_signing_policy_log "当前 provisioning profile 不支持原生 Sign in with Apple；已移除原生受限 entitlement，并将运行时模式切换为 web_session（保留 SKYBRIDGE_ENABLE_APPLE_SIGN_IN 产品开关）"
  return 0
}
