#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Check SkyBridge Supabase Auth production readiness.

Usage:
  check_supabase_auth_readiness.sh \
    [--project-ref <ref>] \
    [--expect-apple-client-ids <csv>] \
    [--warn-apple-secret-days <days>] \
    [--apple-rotation-metadata <path>] \
    [--turnstile-widget-metadata <path>] \
    [--require-captcha] \
    [--token <token>]

Options:
  --project-ref <ref>              Supabase project ref; defaults to local repo discovery
  --expect-apple-client-ids <csv>  Expected Apple client IDs (comma-separated)
  --warn-apple-secret-days <days>  Warn/fail when Apple client secret expires within N days (default: 30)
  --apple-rotation-metadata <path> Apple rotation metadata JSON written by configure_supabase_auth_apple.sh
  --turnstile-widget-metadata <path> Local Turnstile widget metadata JSON for hostname/site-key checks
  --require-captcha                Treat disabled CAPTCHA as an error
  --token <token>                  Supabase personal access token; otherwise read from Keychain
  -h, --help                       Show this help

Checks:
  - before_user_created auth hook
  - Apple provider enabled + client secret expiry
  - send_sms hook enabled
  - SMTP configured
  - local repo feature flags / entitlements / iOS project binding
  - optional Turnstile widget hostname/site-key metadata
  - optional CAPTCHA requirement
USAGE
}

PROJECT_REF=""
EXPECT_APPLE_CLIENT_IDS=""
WARN_APPLE_SECRET_DAYS="30"
REQUIRE_CAPTCHA="false"
SUPABASE_TOKEN=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APPLE_ROTATION_METADATA="${PROJECT_ROOT}/Docs/ops/.state/supabase_apple_secret_rotation.json"
TURNSTILE_WIDGET_METADATA="${PROJECT_ROOT}/Docs/ops/.state/turnstile_widget_metadata.json"

resolve_project_ref() {
  local project_ref_file="${PROJECT_ROOT}/supabase/.temp/project-ref"
  local derived_project_ref=""

  if [[ -f "${project_ref_file}" ]]; then
    derived_project_ref="$(tr -d '[:space:]' <"${project_ref_file}")"
    if [[ -n "${derived_project_ref}" ]]; then
      printf '%s\n' "${derived_project_ref}"
      return 0
    fi
  fi

  derived_project_ref="$(python3 - "${PROJECT_ROOT}" <<'PY'
import plistlib
import sys
from pathlib import Path
from urllib.parse import urlparse

project_root = Path(sys.argv[1])
candidate_paths = [
    project_root / "Sources/SkyBridgeCompassApp/Info.plist",
    project_root / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Resources/SupabaseConfig.plist",
]

for path in candidate_paths:
    if not path.exists():
        continue
    with path.open("rb") as fh:
        payload = plistlib.load(fh)
    for key in ("SUPABASE_URL", "SKYBRIDGE_AUTH_BASEURL"):
        value = str(payload.get(key, "")).strip()
        if not value:
            continue
        hostname = urlparse(value).hostname or ""
        if hostname.endswith(".supabase.co"):
            print(hostname.split(".", 1)[0])
            raise SystemExit(0)

raise SystemExit(1)
PY
  )" || true

  if [[ -n "${derived_project_ref}" ]]; then
    printf '%s\n' "${derived_project_ref}"
    return 0
  fi

  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-ref)
      PROJECT_REF="${2:-}"
      shift 2
      ;;
    --expect-apple-client-ids)
      EXPECT_APPLE_CLIENT_IDS="${2:-}"
      shift 2
      ;;
    --warn-apple-secret-days)
      WARN_APPLE_SECRET_DAYS="${2:-}"
      shift 2
      ;;
    --apple-rotation-metadata)
      APPLE_ROTATION_METADATA="${2:-}"
      shift 2
      ;;
    --turnstile-widget-metadata)
      TURNSTILE_WIDGET_METADATA="${2:-}"
      shift 2
      ;;
    --require-captcha)
      REQUIRE_CAPTCHA="true"
      shift
      ;;
    --token)
      SUPABASE_TOKEN="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$PROJECT_REF" ]]; then
  PROJECT_REF="$(resolve_project_ref || true)"
fi

if [[ -z "$PROJECT_REF" ]]; then
  echo "[supabase-auth-readiness] missing --project-ref and could not derive one from local repo config" >&2
  usage
  exit 1
fi

if ! [[ "$WARN_APPLE_SECRET_DAYS" =~ ^[0-9]+$ ]]; then
  echo "[supabase-auth-readiness] --warn-apple-secret-days must be numeric" >&2
  exit 1
fi

if [[ -z "$SUPABASE_TOKEN" ]]; then
  if ! command -v security >/dev/null 2>&1; then
    echo "[supabase-auth-readiness] macOS security CLI not available; pass --token explicitly" >&2
    exit 1
  fi
  KEYCHAIN_VALUE="$(security find-generic-password -s 'Supabase CLI' -a supabase -w 2>/dev/null || true)"
  if [[ -z "$KEYCHAIN_VALUE" ]]; then
    echo "[supabase-auth-readiness] could not read Supabase CLI token from Keychain; pass --token explicitly" >&2
    exit 1
  fi
  if [[ "$KEYCHAIN_VALUE" == go-keyring-base64:* ]]; then
    SUPABASE_TOKEN="$(python3 - "$KEYCHAIN_VALUE" <<'PY'
import base64, sys
raw = sys.argv[1]
print(base64.b64decode(raw.split(':', 1)[1]).decode())
PY
)"
  else
    SUPABASE_TOKEN="$KEYCHAIN_VALUE"
  fi
fi

TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT

curl -fsS "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
  -H "Authorization: Bearer $SUPABASE_TOKEN" \
  -H 'Content-Type: application/json' \
  > "$TMP_JSON"

export PROJECT_ROOT EXPECT_APPLE_CLIENT_IDS WARN_APPLE_SECRET_DAYS REQUIRE_CAPTCHA APPLE_ROTATION_METADATA TURNSTILE_WIDGET_METADATA

python3 - "$TMP_JSON" <<'PY'
import base64
import json
import os
import plistlib
import sys
import time
from datetime import datetime
from urllib.parse import urlparse
from pathlib import Path


def decode_jwt_exp(token: str):
    parts = token.split(".")
    if len(parts) < 2:
        return None
    payload = parts[1]
    payload += "=" * ((4 - len(payload) % 4) % 4)
    try:
        decoded = json.loads(base64.urlsafe_b64decode(payload.encode()).decode())
    except Exception:
        return None
    return decoded.get("exp")


def read_plist(path: Path):
    if not path.exists():
        return {}
    with path.open("rb") as fh:
        return plistlib.load(fh)


def normalize_csv(value: str):
    return [item.strip() for item in value.split(",") if item.strip()]


def parse_url_host(url_value):
    if not url_value:
        return None
    try:
        return urlparse(url_value).hostname
    except Exception:
        return None


cfg = json.load(open(sys.argv[1]))
project_root = Path(os.environ["PROJECT_ROOT"])
expect_apple_client_ids = normalize_csv(os.environ.get("EXPECT_APPLE_CLIENT_IDS", ""))
warn_days = int(os.environ.get("WARN_APPLE_SECRET_DAYS", "30"))
require_captcha = os.environ.get("REQUIRE_CAPTCHA", "false") == "true"
rotation_metadata_path = Path(os.environ.get("APPLE_ROTATION_METADATA", ""))
turnstile_widget_metadata_path = Path(os.environ.get("TURNSTILE_WIDGET_METADATA", ""))

errors = []
warnings = []

hook_enabled = cfg.get("hook_before_user_created_enabled") is True
hook_uri = cfg.get("hook_before_user_created_uri")
sms_hook_enabled = cfg.get("hook_send_sms_enabled") is True
smtp_host = cfg.get("smtp_host")
smtp_user = cfg.get("smtp_user")
smtp_ready = bool(smtp_host and smtp_user)
apple_enabled = cfg.get("external_apple_enabled") is True
apple_client_ids_raw = (cfg.get("external_apple_client_id") or "").strip()
apple_client_ids = normalize_csv(apple_client_ids_raw)
apple_secret = (cfg.get("external_apple_secret") or "").strip()
captcha_enabled = cfg.get("security_captcha_enabled") is True
captcha_provider = cfg.get("security_captcha_provider")
captcha_site_key = (cfg.get("security_captcha_site_key") or "").strip()

if not hook_enabled:
    errors.append("Supabase before_user_created hook 未开启")
if hook_enabled and not hook_uri:
    errors.append("Supabase before_user_created hook 已开启但 URI 缺失")
if not sms_hook_enabled:
    errors.append("Supabase send_sms hook 未开启")
if not smtp_ready:
    errors.append("Supabase 自定义 SMTP 未配置完整（smtp_host / smtp_user 缺失）")
if not apple_enabled:
    errors.append("Supabase Apple provider 未开启")
if not apple_client_ids:
    errors.append("Supabase Apple client IDs 为空")
if not apple_secret:
    errors.append("Supabase Apple client secret 缺失")

if expect_apple_client_ids:
    if sorted(apple_client_ids) != sorted(expect_apple_client_ids):
        errors.append(
            "Supabase Apple client IDs 与预期不一致: "
            f"expected={','.join(expect_apple_client_ids)} actual={','.join(apple_client_ids)}"
        )

apple_secret_exp = decode_jwt_exp(apple_secret) if apple_secret else None
apple_secret_days_remaining = None
if apple_secret_exp:
    apple_secret_days_remaining = int((apple_secret_exp - time.time()) // 86400)
    if apple_secret_days_remaining < 0:
        errors.append("Supabase Apple client secret 已过期")
    elif apple_secret_days_remaining < warn_days:
        warnings.append(
            f"Supabase Apple client secret 将在 {apple_secret_days_remaining} 天内过期，请尽快轮换"
        )
else:
    if apple_secret and rotation_metadata_path.exists():
        try:
            metadata = json.loads(rotation_metadata_path.read_text())
            expires_at = metadata.get("expires_at_utc")
            if expires_at:
                expires_ts = datetime.fromisoformat(expires_at.replace("Z", "+00:00")).timestamp()
                apple_secret_days_remaining = int((expires_ts - time.time()) // 86400)
                if apple_secret_days_remaining < 0:
                    errors.append("本地 Apple rotation metadata 显示 client secret 已过期")
                elif apple_secret_days_remaining < warn_days:
                    warnings.append(
                        f"本地 Apple rotation metadata 显示 client secret 将在 {apple_secret_days_remaining} 天内过期"
                    )
        except Exception:
            warnings.append("无法解析本地 Apple rotation metadata")
    elif apple_secret:
        warnings.append("无法解析 Supabase Apple client secret 的过期时间，且未找到本地轮换 metadata")

if require_captcha and not captcha_enabled:
    errors.append("当前要求 CAPTCHA，但 Supabase CAPTCHA 仍未开启")
elif not captcha_enabled:
    warnings.append("Supabase CAPTCHA 当前未开启；若要抵抗大规模注册攻击，仍建议补齐 Turnstile")

mac_info = read_plist(project_root / "Sources/SkyBridgeCompassApp/Info.plist")
ios_info = read_plist(project_root / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Supporting Files/Info.plist")
ios_supabase_config = read_plist(project_root / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Resources/SupabaseConfig.plist")
mac_packaging_entitlements = read_plist(project_root / "Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.packaging.entitlements")
mac_native_packaging_entitlements = read_plist(project_root / "Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.native.packaging.entitlements")
mac_dev_entitlements = read_plist(project_root / "Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.entitlements")
ios_debug_entitlements = read_plist(project_root / "SkyBridge Compass iOS/SkyBridgeCompass-iOSDebug.entitlements")
ios_release_entitlements = read_plist(project_root / "SkyBridge Compass iOS/SkyBridgeCompass-iOSRelease.entitlements")
pbxproj_path = project_root / "SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj/project.pbxproj"
pbxproj_text = pbxproj_path.read_text() if pbxproj_path.exists() else ""
turnstile_widget_metadata = {}
turnstile_widget_hostnames = []

if mac_info.get("SKYBRIDGE_ENABLE_APPLE_SIGN_IN") is not True:
    errors.append("macOS Info.plist 未开启 SKYBRIDGE_ENABLE_APPLE_SIGN_IN")
if ios_info.get("SKYBRIDGE_ENABLE_APPLE_SIGN_IN") is not True:
    errors.append("iOS Info.plist 未开启 SKYBRIDGE_ENABLE_APPLE_SIGN_IN")

mac_turnstile_site_key = (mac_info.get("TURNSTILE_SITE_KEY") or "").strip()
ios_turnstile_site_key = (ios_info.get("TURNSTILE_SITE_KEY") or "").strip()
ios_supabase_turnstile_site_key = (ios_supabase_config.get("TURNSTILE_SITE_KEY") or "").strip()

if ios_supabase_turnstile_site_key and ios_supabase_turnstile_site_key != ios_turnstile_site_key:
    errors.append("iOS SupabaseConfig.plist 的 TURNSTILE_SITE_KEY 与 Info.plist 不一致")

for label, entitlements in [
    ("macOS native packaging entitlements", mac_native_packaging_entitlements),
    ("macOS development entitlements", mac_dev_entitlements),
    ("iOS Debug entitlements", ios_debug_entitlements),
    ("iOS Release entitlements", ios_release_entitlements),
]:
    if "com.apple.developer.applesignin" not in entitlements:
        errors.append(f"{label} 缺少 com.apple.developer.applesignin")

if "com.apple.developer.applesignin" in mac_packaging_entitlements:
    errors.append("macOS Developer ID packaging entitlements 不应直接请求 com.apple.developer.applesignin；应改用 web_session 分发模式")

if 'CODE_SIGN_ENTITLEMENTS = "SkyBridgeCompass-iOSDebug.entitlements";' not in pbxproj_text:
    errors.append("iOS Xcode project 未绑定 Debug entitlements")
if 'CODE_SIGN_ENTITLEMENTS = "SkyBridgeCompass-iOSRelease.entitlements";' not in pbxproj_text:
    errors.append("iOS Xcode project 未绑定 Release entitlements")

expected_turnstile_hosts = {
    host
    for host in [
        parse_url_host(mac_info.get("SKYBRIDGE_AUTH_BASEURL")),
        parse_url_host(mac_info.get("SUPABASE_URL")),
        parse_url_host(ios_supabase_config.get("SUPABASE_URL")),
    ]
    if host
}

if captcha_enabled and captcha_provider == "turnstile":
    if not any([captcha_site_key, mac_turnstile_site_key, ios_turnstile_site_key, ios_supabase_turnstile_site_key]):
        errors.append("Turnstile 已启用，但仓库内未找到任何可用 TURNSTILE_SITE_KEY")

    if mac_turnstile_site_key and captcha_site_key and mac_turnstile_site_key != captcha_site_key:
        errors.append("macOS TURNSTILE_SITE_KEY 与 Supabase 当前 site key 不一致")
    if ios_turnstile_site_key and captcha_site_key and ios_turnstile_site_key != captcha_site_key:
        errors.append("iOS Info.plist TURNSTILE_SITE_KEY 与 Supabase 当前 site key 不一致")

    if turnstile_widget_metadata_path.exists():
        try:
            turnstile_widget_metadata = json.loads(turnstile_widget_metadata_path.read_text())
            turnstile_widget_hostnames = sorted(
                {item.strip().lower() for item in turnstile_widget_metadata.get("hostnames", []) if item.strip()}
            )
            metadata_site_key = (turnstile_widget_metadata.get("site_key") or "").strip()
            local_site_keys = {
                key
                for key in [
                    captcha_site_key,
                    mac_turnstile_site_key,
                    ios_turnstile_site_key,
                    ios_supabase_turnstile_site_key,
                ]
                if key
            }
            if metadata_site_key and local_site_keys and metadata_site_key not in local_site_keys:
                errors.append("Turnstile widget metadata 的 site key 与本地配置不一致")

            missing_hosts = sorted(expected_turnstile_hosts - set(turnstile_widget_hostnames))
            if missing_hosts:
                errors.append(
                    "Turnstile widget hostname allowlist 缺少运行时 host: " + ",".join(missing_hosts)
                )
        except Exception:
            warnings.append("无法解析本地 Turnstile widget metadata")
    else:
        warnings.append("未找到本地 Turnstile widget metadata，无法校验 Cloudflare hostname allowlist")

summary = {
    "hook_before_user_created_enabled": hook_enabled,
    "hook_before_user_created_uri": hook_uri,
    "hook_send_sms_enabled": sms_hook_enabled,
    "smtp_ready": smtp_ready,
    "smtp_host": smtp_host,
    "smtp_user": smtp_user,
    "external_apple_enabled": apple_enabled,
    "external_apple_client_ids": apple_client_ids,
    "external_apple_secret_present": bool(apple_secret),
    "external_apple_secret_days_remaining": apple_secret_days_remaining,
    "security_captcha_enabled": captcha_enabled,
    "security_captcha_provider": captcha_provider,
    "security_captcha_site_key_present": bool(captcha_site_key),
    "mac_flag_enabled": mac_info.get("SKYBRIDGE_ENABLE_APPLE_SIGN_IN") is True,
    "ios_flag_enabled": ios_info.get("SKYBRIDGE_ENABLE_APPLE_SIGN_IN") is True,
    "turnstile_widget_metadata_present": bool(turnstile_widget_metadata),
    "turnstile_widget_hostnames": turnstile_widget_hostnames,
}

print("[supabase-auth-readiness] summary:")
print(json.dumps(summary, ensure_ascii=False, indent=2))

if warnings:
    print("[supabase-auth-readiness] warnings:")
    for warning in warnings:
        print(f"  - {warning}")

if errors:
    print("[supabase-auth-readiness] errors:")
    for error in errors:
        print(f"  - {error}")
    sys.exit(1)

print("[supabase-auth-readiness] ready")
PY
