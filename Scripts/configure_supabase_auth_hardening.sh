#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Configure Supabase Auth hardening for SkyBridge launch:
- enable the before_user_created Postgres hook
- optionally enable Turnstile CAPTCHA for Auth

Usage:
  configure_supabase_auth_hardening.sh \
    --project-ref <ref> \
    [--enable-before-user-created-hook] \
    [--turnstile-site-key <site-key> --turnstile-secret <secret> --enable-captcha]

Options:
  --project-ref <ref>                 Supabase project ref
  --hook-function <name>             Postgres hook function name
                                      default: hook_skybridge_before_user_created_v1
  --enable-before-user-created-hook  Enable the before_user_created hook
  --disable-before-user-created-hook Disable the before_user_created hook
  --enable-captcha                   Enable CAPTCHA protection
  --disable-captcha                  Disable CAPTCHA protection
  --turnstile-site-key <key>         Cloudflare Turnstile site key
  --turnstile-secret <secret>        Cloudflare Turnstile secret key
  --turnstile-secret-file <path>     Read Turnstile secret key from file
  --turnstile-secret-stdin           Read Turnstile secret key from stdin
  --token <token>                    Supabase personal access token; otherwise read from Keychain
  -h, --help                         Show this help

Notes:
  - This script uses the Supabase Management API.
  - If --token is omitted, it reads the Supabase CLI token from macOS Keychain.
  - The before-user-created hook function must already exist in your database migrations.
  - Prefer --turnstile-secret-file / --turnstile-secret-stdin over --turnstile-secret to avoid
    leaking secrets into shell history or process lists.
USAGE
}

PROJECT_REF=""
HOOK_FUNCTION="hook_skybridge_before_user_created_v1"
ENABLE_BEFORE_USER_CREATED=""
ENABLE_CAPTCHA=""
TURNSTILE_SITE_KEY_INPUT="${TURNSTILE_SITE_KEY:-}"
TURNSTILE_SECRET_INPUT="${TURNSTILE_SECRET:-}"
TURNSTILE_SECRET_FILE=""
TURNSTILE_SECRET_STDIN="false"
SUPABASE_TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-ref)
      PROJECT_REF="${2:-}"
      shift 2
      ;;
    --hook-function)
      HOOK_FUNCTION="${2:-}"
      shift 2
      ;;
    --enable-before-user-created-hook)
      ENABLE_BEFORE_USER_CREATED="true"
      shift
      ;;
    --disable-before-user-created-hook)
      ENABLE_BEFORE_USER_CREATED="false"
      shift
      ;;
    --enable-captcha)
      ENABLE_CAPTCHA="true"
      shift
      ;;
    --disable-captcha)
      ENABLE_CAPTCHA="false"
      shift
      ;;
    --turnstile-site-key)
      TURNSTILE_SITE_KEY_INPUT="${2:-}"
      shift 2
      ;;
    --turnstile-secret)
      TURNSTILE_SECRET_INPUT="${2:-}"
      shift 2
      ;;
    --turnstile-secret-file)
      TURNSTILE_SECRET_FILE="${2:-}"
      shift 2
      ;;
    --turnstile-secret-stdin)
      TURNSTILE_SECRET_STDIN="true"
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
  echo "[supabase-auth-hardening] missing --project-ref" >&2
  usage
  exit 1
fi

if [[ -z "$SUPABASE_TOKEN" ]]; then
  if ! command -v security >/dev/null 2>&1; then
    echo "[supabase-auth-hardening] macOS security CLI not available; pass --token explicitly" >&2
    exit 1
  fi
  KEYCHAIN_VALUE="$(security find-generic-password -s 'Supabase CLI' -a supabase -w 2>/dev/null || true)"
  if [[ -z "$KEYCHAIN_VALUE" ]]; then
    echo "[supabase-auth-hardening] could not read Supabase CLI token from Keychain; pass --token explicitly" >&2
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

SECRET_INPUT_SOURCES=0
if [[ -n "$TURNSTILE_SECRET_INPUT" ]]; then
  SECRET_INPUT_SOURCES=$((SECRET_INPUT_SOURCES + 1))
fi
if [[ -n "$TURNSTILE_SECRET_FILE" ]]; then
  SECRET_INPUT_SOURCES=$((SECRET_INPUT_SOURCES + 1))
fi
if [[ "$TURNSTILE_SECRET_STDIN" == "true" ]]; then
  SECRET_INPUT_SOURCES=$((SECRET_INPUT_SOURCES + 1))
fi

if (( SECRET_INPUT_SOURCES > 1 )); then
  echo "[supabase-auth-hardening] please provide Turnstile secret via only one of --turnstile-secret, --turnstile-secret-file, or --turnstile-secret-stdin" >&2
  exit 1
fi

if [[ -n "$TURNSTILE_SECRET_FILE" ]]; then
  if [[ ! -f "$TURNSTILE_SECRET_FILE" ]]; then
    echo "[supabase-auth-hardening] Turnstile secret file not found: $TURNSTILE_SECRET_FILE" >&2
    exit 1
  fi
  TURNSTILE_SECRET_INPUT="$(tr -d '\r\n' < "$TURNSTILE_SECRET_FILE")"
fi

if [[ "$TURNSTILE_SECRET_STDIN" == "true" ]]; then
  if ! IFS= read -r TURNSTILE_SECRET_INPUT; then
    echo "[supabase-auth-hardening] failed to read Turnstile secret from stdin" >&2
    exit 1
  fi
  TURNSTILE_SECRET_INPUT="$(printf '%s' "$TURNSTILE_SECRET_INPUT" | tr -d '\r\n')"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
CURRENT_JSON="$TMP_DIR/current.json"
PATCH_JSON="$TMP_DIR/patch.json"
UPDATED_JSON="$TMP_DIR/updated.json"

curl -fsS "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
  -H "Authorization: Bearer $SUPABASE_TOKEN" \
  -H 'Content-Type: application/json' \
  > "$CURRENT_JSON"

export HOOK_FUNCTION ENABLE_BEFORE_USER_CREATED ENABLE_CAPTCHA
export TURNSTILE_SITE_KEY="$TURNSTILE_SITE_KEY_INPUT"
export TURNSTILE_SECRET="$TURNSTILE_SECRET_INPUT"

python3 - "$CURRENT_JSON" "$PATCH_JSON" <<'PY'
import json
import os
import sys

current = json.load(open(sys.argv[1]))
patch = {}

hook_toggle = os.environ.get("ENABLE_BEFORE_USER_CREATED", "")
hook_function = os.environ.get("HOOK_FUNCTION", "").strip()
if hook_toggle:
    patch["hook_before_user_created_enabled"] = hook_toggle == "true"
    patch["hook_before_user_created_uri"] = f"pg-functions://postgres/public/{hook_function}"

captcha_toggle = os.environ.get("ENABLE_CAPTCHA", "")
site_key = os.environ.get("TURNSTILE_SITE_KEY", "").strip()
secret = os.environ.get("TURNSTILE_SECRET", "").strip()
current_provider = (current.get("security_captcha_provider") or "").strip()
current_turnstile_site_key = ""
current_turnstile_secret = ""
if current_provider == "turnstile":
    current_turnstile_site_key = (current.get("security_captcha_site_key") or "").strip()
    current_turnstile_secret = (current.get("security_captcha_secret") or "").strip()

effective_site_key = site_key or current_turnstile_site_key
effective_secret = secret or current_turnstile_secret

if captcha_toggle == "true" and (not effective_site_key or not effective_secret):
    print(
        "[supabase-auth-hardening] enabling Turnstile requires both site key and secret; "
        "provide them now or keep an existing turnstile config in Supabase",
        file=sys.stderr,
    )
    sys.exit(1)

if captcha_toggle:
    patch["security_captcha_enabled"] = captcha_toggle == "true"
if site_key:
    patch["security_captcha_site_key"] = site_key
if secret:
    patch["security_captcha_secret"] = secret
    patch["security_captcha_provider"] = "turnstile"
elif captcha_toggle == "true":
    patch["security_captcha_provider"] = "turnstile"

preview_patch = dict(patch)
if "security_captcha_secret" in preview_patch:
    preview_patch["security_captcha_secret_present"] = True
    del preview_patch["security_captcha_secret"]

print(json.dumps({
    "before": {
        "hook_before_user_created_enabled": current.get("hook_before_user_created_enabled"),
        "hook_before_user_created_uri": current.get("hook_before_user_created_uri"),
        "security_captcha_enabled": current.get("security_captcha_enabled"),
        "security_captcha_provider": current.get("security_captcha_provider"),
    },
    "patch": preview_patch
}, ensure_ascii=False, indent=2))

json.dump(patch, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)
PY

if [[ ! -s "$PATCH_JSON" ]] || [[ "$(cat "$PATCH_JSON")" == "{}" ]]; then
  echo "[supabase-auth-hardening] nothing to update"
  exit 0
fi

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
    "hook_before_user_created_enabled": updated.get("hook_before_user_created_enabled"),
    "hook_before_user_created_uri": updated.get("hook_before_user_created_uri"),
    "security_captcha_enabled": updated.get("security_captcha_enabled"),
    "security_captcha_provider": updated.get("security_captcha_provider"),
}
print("[supabase-auth-hardening] updated auth config:")
print(json.dumps(summary, ensure_ascii=False, indent=2))
PY
