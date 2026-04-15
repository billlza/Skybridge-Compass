#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Configure Supabase Auth phone sign-in and send_sms hook using the Management API.

Usage:
  configure_supabase_phone_sms_hook.sh --project-ref <ref> --hook-url <url> --hook-secret <secret> [options]

Options:
  --project-ref <ref>     Supabase project ref
  --hook-url <url>        HTTPS URL for send_sms hook
  --hook-secret <secret>  Shared secret used by Supabase and signaling
  --enable-phone          Enable phone sign-in (default: leave unchanged)
  --disable-phone         Disable phone sign-in
  --enable-hook           Enable send_sms hook (default: leave unchanged)
  --disable-hook          Disable send_sms hook
  --sms-template <text>   Override SMS template
  --otp-exp <seconds>     Override OTP expiry
  --otp-length <digits>   Override OTP length
  --token <token>         Supabase personal access token; otherwise read from Keychain
  -h, --help              Show this help

Notes:
  - This script reads the Supabase CLI access token from macOS Keychain if --token is omitted.
  - Do not commit hook secrets to git.
USAGE
}

PROJECT_REF=""
HOOK_URL=""
HOOK_SECRET=""
ENABLE_PHONE=""
ENABLE_HOOK=""
SMS_TEMPLATE=""
SMS_OTP_EXP=""
SMS_OTP_LENGTH=""
SUPABASE_TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-ref)
      PROJECT_REF="${2:-}"
      shift 2
      ;;
    --hook-url)
      HOOK_URL="${2:-}"
      shift 2
      ;;
    --hook-secret)
      HOOK_SECRET="${2:-}"
      shift 2
      ;;
    --enable-phone)
      ENABLE_PHONE="true"
      shift
      ;;
    --disable-phone)
      ENABLE_PHONE="false"
      shift
      ;;
    --enable-hook)
      ENABLE_HOOK="true"
      shift
      ;;
    --disable-hook)
      ENABLE_HOOK="false"
      shift
      ;;
    --sms-template)
      SMS_TEMPLATE="${2:-}"
      shift 2
      ;;
    --otp-exp)
      SMS_OTP_EXP="${2:-}"
      shift 2
      ;;
    --otp-length)
      SMS_OTP_LENGTH="${2:-}"
      shift 2
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

if [[ -z "$PROJECT_REF" || -z "$HOOK_URL" || -z "$HOOK_SECRET" ]]; then
  echo "[supabase-auth] missing required arguments" >&2
  usage
  exit 1
fi

if [[ ! "$HOOK_URL" =~ ^https:// ]]; then
  echo "[supabase-auth] hook URL must use https" >&2
  exit 1
fi

if [[ -z "$SUPABASE_TOKEN" ]]; then
  if ! command -v security >/dev/null 2>&1; then
    echo "[supabase-auth] macOS security CLI not available; pass --token explicitly" >&2
    exit 1
  fi
  KEYCHAIN_VALUE="$(security find-generic-password -s 'Supabase CLI' -a supabase -w 2>/dev/null || true)"
  if [[ -z "$KEYCHAIN_VALUE" ]]; then
    echo "[supabase-auth] could not read Supabase CLI token from Keychain; pass --token explicitly" >&2
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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CURRENT_JSON="$TMP_DIR/current.json"
PATCH_JSON="$TMP_DIR/patch.json"
UPDATED_JSON="$TMP_DIR/updated.json"

export HOOK_URL HOOK_SECRET ENABLE_PHONE ENABLE_HOOK SMS_TEMPLATE SMS_OTP_EXP SMS_OTP_LENGTH

curl -fsS "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
  -H "Authorization: Bearer $SUPABASE_TOKEN" \
  -H 'Content-Type: application/json' \
  > "$CURRENT_JSON"

python3 - "$CURRENT_JSON" "$PATCH_JSON" <<'PY'
import json
import os
import sys

current = json.load(open(sys.argv[1]))
patch = {
    "hook_send_sms_uri": os.environ["HOOK_URL"],
    "hook_send_sms_secrets": os.environ["HOOK_SECRET"],
}

enable_phone = os.environ.get("ENABLE_PHONE", "")
if enable_phone:
    patch["external_phone_enabled"] = enable_phone == "true"

enable_hook = os.environ.get("ENABLE_HOOK", "")
if enable_hook:
    patch["hook_send_sms_enabled"] = enable_hook == "true"

sms_template = os.environ.get("SMS_TEMPLATE", "")
if sms_template:
    patch["sms_template"] = sms_template

sms_otp_exp = os.environ.get("SMS_OTP_EXP", "")
if sms_otp_exp:
    patch["sms_otp_exp"] = int(sms_otp_exp)

sms_otp_length = os.environ.get("SMS_OTP_LENGTH", "")
if sms_otp_length:
    patch["sms_otp_length"] = int(sms_otp_length)

json.dump(patch, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)
print(json.dumps({
    "before": {
        "external_phone_enabled": current.get("external_phone_enabled"),
        "sms_provider": current.get("sms_provider"),
        "hook_send_sms_enabled": current.get("hook_send_sms_enabled"),
        "hook_send_sms_uri": current.get("hook_send_sms_uri"),
    },
    "patch": patch
}, ensure_ascii=False, indent=2))
PY

curl -fsS -X PATCH "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
  -H "Authorization: Bearer $SUPABASE_TOKEN" \
  -H 'Content-Type: application/json' \
  --data @"$PATCH_JSON" \
  > "$UPDATED_JSON"

python3 - "$UPDATED_JSON" <<'PY'
import json
import sys

updated = json.load(open(sys.argv[1]))
summary = {
    "external_phone_enabled": updated.get("external_phone_enabled"),
    "sms_provider": updated.get("sms_provider"),
    "hook_send_sms_enabled": updated.get("hook_send_sms_enabled"),
    "hook_send_sms_uri": updated.get("hook_send_sms_uri"),
    "sms_otp_exp": updated.get("sms_otp_exp"),
    "sms_otp_length": updated.get("sms_otp_length"),
}
print("[supabase-auth] updated auth config:")
print(json.dumps(summary, ensure_ascii=False, indent=2))
PY
