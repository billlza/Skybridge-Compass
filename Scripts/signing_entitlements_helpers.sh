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

skybridge_provisionprofile_supports_applesignin() {
  local profile_path="$1"
  [[ -n "${profile_path}" && -f "${profile_path}" ]] || return 1

  python3 - "${profile_path}" <<'PY'
import plistlib
import subprocess
import sys
from pathlib import Path

profile_path = Path(sys.argv[1])
if not profile_path.exists():
    raise SystemExit(1)

completed = subprocess.run(
    ["security", "cms", "-D", "-i", str(profile_path)],
    check=False,
    capture_output=True,
)
if completed.returncode != 0 or not completed.stdout:
    raise SystemExit(1)

profile = plistlib.loads(completed.stdout)
entitlements = profile.get("Entitlements", {})
value = entitlements.get("com.apple.developer.applesignin")

if isinstance(value, list) and any(str(item).strip() for item in value):
    raise SystemExit(0)

raise SystemExit(1)
PY
}

skybridge_profile_supports_requested_restricted_entitlements() {
  local profile_path="${1:-}"
  local entitlements_path="$2"

  if skybridge_entitlements_request_applesignin "${entitlements_path}"; then
    skybridge_provisionprofile_supports_applesignin "${profile_path}"
    return $?
  fi

  return 0
}

skybridge_write_signed_entitlements() {
  local target_path="$1"
  local output_path="$2"

  codesign -d --entitlements :- "${target_path}" >"${output_path}" 2>/dev/null
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

profile_path = Path(sys.argv[1])
bundle_identifier = sys.argv[2].strip()
team_identifier = sys.argv[3].strip()

completed = subprocess.run(
    ["security", "cms", "-D", "-i", str(profile_path)],
    check=False,
    capture_output=True,
)
if completed.returncode != 0 or not completed.stdout:
    print(f"无法解码 provisioning profile: {profile_path}", file=sys.stderr)
    raise SystemExit(1)

profile = plistlib.loads(completed.stdout)
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

skybridge_prepare_signing_entitlements() {
  local source_entitlements="$1"
  local output_entitlements="$2"
  local info_plist_path="$3"
  local profile_path="${4:-}"

  [[ -f "${source_entitlements}" ]] || {
    echo "错误：签名 entitlements 文件不存在：${source_entitlements}" >&2
    return 1
  }

  cp "${source_entitlements}" "${output_entitlements}"
  SKYBRIDGE_SIGNING_EFFECTIVE_NATIVE_APPLE_SIGN_IN=0
  SKYBRIDGE_SIGNING_EFFECTIVE_APPLE_SIGN_IN=0

  if ! skybridge_entitlements_request_applesignin "${source_entitlements}"; then
    skybridge_set_plist_bool "${info_plist_path}" "SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN" 0
    skybridge_signing_policy_log "源 entitlements 未请求 Sign in with Apple；产物仅标记原生 Apple 登录不可用，并保留 SKYBRIDGE_ENABLE_APPLE_SIGN_IN 产品开关"
    return 0
  fi

  if skybridge_provisionprofile_supports_applesignin "${profile_path}"; then
    SKYBRIDGE_SIGNING_EFFECTIVE_NATIVE_APPLE_SIGN_IN=1
    SKYBRIDGE_SIGNING_EFFECTIVE_APPLE_SIGN_IN=1
    skybridge_set_plist_bool "${info_plist_path}" "SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN" 1
    skybridge_signing_policy_log "检测到支持 Sign in with Apple 的 provisioning profile；保留原生 entitlement，并将 SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN 标记为 true（不改写 SKYBRIDGE_ENABLE_APPLE_SIGN_IN）"
    return 0
  fi

  if [[ "${SKYBRIDGE_REQUIRE_APPLE_SIGN_IN:-0}" == "1" ]]; then
    echo "错误：当前 provisioning profile 不支持 Sign in with Apple，但 SKYBRIDGE_REQUIRE_APPLE_SIGN_IN=1。" >&2
    echo "请安装包含 com.apple.developer.applesignin 的 macOS Developer ID provisioning profile。" >&2
    return 1
  fi

  /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.applesignin' "${output_entitlements}" >/dev/null 2>&1 || true
  skybridge_set_plist_bool "${info_plist_path}" "SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN" 0
  skybridge_signing_policy_log "当前 provisioning profile 不支持 Sign in with Apple；已移除原生受限 entitlement，并将 SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN 标记为 false（保留 SKYBRIDGE_ENABLE_APPLE_SIGN_IN 产品开关）"
  return 0
}
