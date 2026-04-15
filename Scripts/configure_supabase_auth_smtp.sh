#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Configure Supabase Auth custom SMTP using the Management API.

Usage:
  configure_supabase_auth_smtp.sh --project-ref <ref> --smtp-host <host> --smtp-user <user> --smtp-pass <pass> --sender-email <email> [options]

Options:
  --project-ref <ref>        Supabase project ref
  --smtp-host <host>         SMTP host
  --smtp-port <port>         SMTP port (default: 465)
  --smtp-user <user>         SMTP username
  --smtp-pass <pass>         SMTP password
  --sender-email <email>     Sender/admin email used by Supabase Auth
  --sender-name <name>       Sender display name (default: SkyBridge Compass Pro)
  --max-frequency <seconds>  SMTP max frequency override
  --enable-email             Explicitly enable email auth/sign-up (default: leave unchanged)
  --disable-email            Disable email auth/sign-up
  --token <token>            Supabase personal access token; otherwise read from Keychain
  -h, --help                 Show this help

Notes:
  - This script reads the Supabase CLI access token from macOS Keychain if --token is omitted.
  - It updates Supabase Auth SMTP settings only. It does not touch SMS hooks.
  - Keep SMTP passwords out of git and shell history where possible.
USAGE
}

PROJECT_REF=""
SMTP_HOST=""
SMTP_PORT="465"
SMTP_USER=""
SMTP_PASS=""
SENDER_EMAIL=""
SENDER_NAME="SkyBridge Compass Pro"
SMTP_MAX_FREQUENCY=""
ENABLE_EMAIL=""
SUPABASE_TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-ref)
      PROJECT_REF="${2:-}"
      shift 2
      ;;
    --smtp-host)
      SMTP_HOST="${2:-}"
      shift 2
      ;;
    --smtp-port)
      SMTP_PORT="${2:-}"
      shift 2
      ;;
    --smtp-user)
      SMTP_USER="${2:-}"
      shift 2
      ;;
    --smtp-pass)
      SMTP_PASS="${2:-}"
      shift 2
      ;;
    --sender-email)
      SENDER_EMAIL="${2:-}"
      shift 2
      ;;
    --sender-name)
      SENDER_NAME="${2:-}"
      shift 2
      ;;
    --max-frequency)
      SMTP_MAX_FREQUENCY="${2:-}"
      shift 2
      ;;
    --enable-email)
      ENABLE_EMAIL="true"
      shift
      ;;
    --disable-email)
      ENABLE_EMAIL="false"
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

if [[ -z "$PROJECT_REF" || -z "$SMTP_HOST" || -z "$SMTP_USER" || -z "$SMTP_PASS" || -z "$SENDER_EMAIL" ]]; then
  echo "[supabase-smtp] missing required arguments" >&2
  usage
  exit 1
fi

if ! [[ "$SMTP_PORT" =~ ^[0-9]+$ ]]; then
  echo "[supabase-smtp] smtp port must be numeric" >&2
  exit 1
fi

if [[ -z "$SUPABASE_TOKEN" ]]; then
  if ! command -v security >/dev/null 2>&1; then
    echo "[supabase-smtp] macOS security CLI not available; pass --token explicitly" >&2
    exit 1
  fi
  KEYCHAIN_VALUE="$(security find-generic-password -s 'Supabase CLI' -a supabase -w 2>/dev/null || true)"
  if [[ -z "$KEYCHAIN_VALUE" ]]; then
    echo "[supabase-smtp] could not read Supabase CLI token from Keychain; pass --token explicitly" >&2
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

export SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SENDER_EMAIL SENDER_NAME SMTP_MAX_FREQUENCY ENABLE_EMAIL

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
    "smtp_admin_email": os.environ["SENDER_EMAIL"],
    "smtp_host": os.environ["SMTP_HOST"],
    "smtp_port": os.environ["SMTP_PORT"],
    "smtp_user": os.environ["SMTP_USER"],
    "smtp_pass": os.environ["SMTP_PASS"],
    "smtp_sender_name": os.environ["SENDER_NAME"],
}

enable_email = os.environ.get("ENABLE_EMAIL", "")
if enable_email:
    patch["external_email_enabled"] = enable_email == "true"

smtp_max_frequency = os.environ.get("SMTP_MAX_FREQUENCY", "")
if smtp_max_frequency:
    patch["smtp_max_frequency"] = int(smtp_max_frequency)

json.dump(patch, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)
print(json.dumps({
    "before": {
        "external_email_enabled": current.get("external_email_enabled"),
        "smtp_admin_email": current.get("smtp_admin_email"),
        "smtp_host": current.get("smtp_host"),
        "smtp_port": current.get("smtp_port"),
        "smtp_user": current.get("smtp_user"),
        "smtp_sender_name": current.get("smtp_sender_name"),
        "smtp_max_frequency": current.get("smtp_max_frequency"),
    },
    "patch": {
        "external_email_enabled": patch.get("external_email_enabled", current.get("external_email_enabled")),
        "smtp_admin_email": patch["smtp_admin_email"],
        "smtp_host": patch["smtp_host"],
        "smtp_port": patch["smtp_port"],
        "smtp_user": patch["smtp_user"],
        "smtp_sender_name": patch["smtp_sender_name"],
        "smtp_max_frequency": patch.get("smtp_max_frequency", current.get("smtp_max_frequency")),
        "smtp_pass_present": bool(patch["smtp_pass"]),
    }
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
    "external_email_enabled": updated.get("external_email_enabled"),
    "smtp_admin_email": updated.get("smtp_admin_email"),
    "smtp_host": updated.get("smtp_host"),
    "smtp_port": updated.get("smtp_port"),
    "smtp_user": updated.get("smtp_user"),
    "smtp_sender_name": updated.get("smtp_sender_name"),
    "smtp_max_frequency": updated.get("smtp_max_frequency"),
    "smtp_pass_present": bool(updated.get("smtp_host") and updated.get("smtp_user")),
}
print("[supabase-smtp] updated auth config:")
print(json.dumps(summary, ensure_ascii=False, indent=2))
PY
