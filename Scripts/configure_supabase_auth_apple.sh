#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Configure Supabase Auth Apple provider using the Management API.

Usage:
  configure_supabase_auth_apple.sh \
    --project-ref <ref> \
    --team-id <apple-team-id> \
    --key-id <apple-key-id> \
    --client-id <services-id> \
    --private-key-file <AuthKey.p8> \
    [--additional-client-ids <csv>] \
    [--secret-ttl-days <days>] \
    [--metadata-file <path>] \
    [--enable-apple | --disable-apple] \
    [--token <token>]

Options:
  --project-ref <ref>              Supabase project ref
  --team-id <id>                   Apple Developer Team ID
  --key-id <id>                    Sign in with Apple key ID
  --client-id <id>                 Apple Services ID used as the primary client ID
  --additional-client-ids <csv>    Comma-separated native bundle IDs accepted by Supabase
  --private-key-file <path>        Downloaded Apple Sign in private key (.p8 / PEM)
  --secret-ttl-days <days>         Apple client secret lifetime in days (default: 170, max: 180)
  --metadata-file <path>           Where to store non-sensitive rotation metadata
  --enable-apple                   Enable Apple provider (default)
  --disable-apple                  Disable Apple provider
  --token <token>                  Supabase personal access token; otherwise read from Keychain
  -h, --help                       Show this help

Notes:
  - This script generates a fresh ES256 client secret JWT locally.
  - If --token is omitted, it reads the Supabase CLI token from macOS Keychain.
  - For native Apple sign-in, keep the Services ID as the primary client ID and pass bundle IDs via --additional-client-ids.
USAGE
}

PROJECT_REF=""
APPLE_TEAM_ID=""
APPLE_KEY_ID=""
APPLE_CLIENT_ID=""
APPLE_ADDITIONAL_CLIENT_IDS=""
APPLE_PRIVATE_KEY_FILE=""
APPLE_SECRET_TTL_DAYS="170"
ENABLE_APPLE="true"
SUPABASE_TOKEN=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APPLE_METADATA_FILE="${PROJECT_ROOT}/Docs/ops/.state/supabase_apple_secret_rotation.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-ref)
      PROJECT_REF="${2:-}"
      shift 2
      ;;
    --team-id)
      APPLE_TEAM_ID="${2:-}"
      shift 2
      ;;
    --key-id)
      APPLE_KEY_ID="${2:-}"
      shift 2
      ;;
    --client-id)
      APPLE_CLIENT_ID="${2:-}"
      shift 2
      ;;
    --additional-client-ids)
      APPLE_ADDITIONAL_CLIENT_IDS="${2:-}"
      shift 2
      ;;
    --private-key-file)
      APPLE_PRIVATE_KEY_FILE="${2:-}"
      shift 2
      ;;
    --secret-ttl-days)
      APPLE_SECRET_TTL_DAYS="${2:-}"
      shift 2
      ;;
    --metadata-file)
      APPLE_METADATA_FILE="${2:-}"
      shift 2
      ;;
    --enable-apple)
      ENABLE_APPLE="true"
      shift
      ;;
    --disable-apple)
      ENABLE_APPLE="false"
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
  echo "[supabase-apple] missing --project-ref" >&2
  usage
  exit 1
fi

if [[ "$ENABLE_APPLE" == "true" ]]; then
  if [[ -z "$APPLE_TEAM_ID" || -z "$APPLE_KEY_ID" || -z "$APPLE_CLIENT_ID" || -z "$APPLE_PRIVATE_KEY_FILE" ]]; then
    echo "[supabase-apple] missing required Apple arguments for enable flow" >&2
    usage
    exit 1
  fi
fi

if ! [[ "$APPLE_SECRET_TTL_DAYS" =~ ^[0-9]+$ ]]; then
  echo "[supabase-apple] --secret-ttl-days must be numeric" >&2
  exit 1
fi

if [[ "$APPLE_SECRET_TTL_DAYS" -lt 1 || "$APPLE_SECRET_TTL_DAYS" -gt 180 ]]; then
  echo "[supabase-apple] --secret-ttl-days must be between 1 and 180" >&2
  exit 1
fi

if [[ -n "$APPLE_PRIVATE_KEY_FILE" && ! -f "$APPLE_PRIVATE_KEY_FILE" ]]; then
  echo "[supabase-apple] private key file not found: $APPLE_PRIVATE_KEY_FILE" >&2
  exit 1
fi

if [[ -z "$SUPABASE_TOKEN" ]]; then
  if ! command -v security >/dev/null 2>&1; then
    echo "[supabase-apple] macOS security CLI not available; pass --token explicitly" >&2
    exit 1
  fi
  KEYCHAIN_VALUE="$(security find-generic-password -s 'Supabase CLI' -a supabase -w 2>/dev/null || true)"
  if [[ -z "$KEYCHAIN_VALUE" ]]; then
    echo "[supabase-apple] could not read Supabase CLI token from Keychain; pass --token explicitly" >&2
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
SUMMARY_JSON="$TMP_DIR/summary.json"
METADATA_JSON="$TMP_DIR/metadata.json"

curl -fsS "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
  -H "Authorization: Bearer $SUPABASE_TOKEN" \
  -H 'Content-Type: application/json' \
  > "$CURRENT_JSON"

export PROJECT_REF APPLE_TEAM_ID APPLE_KEY_ID APPLE_CLIENT_ID APPLE_ADDITIONAL_CLIENT_IDS APPLE_PRIVATE_KEY_FILE APPLE_SECRET_TTL_DAYS ENABLE_APPLE APPLE_METADATA_FILE

python3 - "$CURRENT_JSON" "$PATCH_JSON" "$SUMMARY_JSON" "$METADATA_JSON" <<'PY'
import base64
import json
import os
import sys
import time
from datetime import datetime, UTC
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def encode_json(value: dict) -> str:
    return b64url(json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


current = json.load(open(sys.argv[1]))
enable_apple = os.environ["ENABLE_APPLE"] == "true"
metadata_path = os.environ.get("APPLE_METADATA_FILE", "").strip()

patch = {
    "external_apple_enabled": enable_apple,
}

summary = {
    "before": {
        "external_apple_enabled": current.get("external_apple_enabled"),
        "external_apple_client_id": current.get("external_apple_client_id"),
        "external_apple_additional_client_ids": current.get("external_apple_additional_client_ids"),
        "external_apple_secret_present": bool(current.get("external_apple_secret")),
    },
    "patch": {
        "external_apple_enabled": enable_apple,
        "external_apple_client_id": None,
        "external_apple_additional_client_ids": None,
        "external_apple_secret_present": False,
        "generated_secret_expires_at_utc": None,
    },
}

if enable_apple:
    project_ref = os.environ["PROJECT_REF"].strip()
    team_id = os.environ["APPLE_TEAM_ID"].strip()
    key_id = os.environ["APPLE_KEY_ID"].strip()
    client_id = os.environ["APPLE_CLIENT_ID"].strip()
    additional_client_ids = os.environ.get("APPLE_ADDITIONAL_CLIENT_IDS", "").strip()
    private_key_file = os.environ["APPLE_PRIVATE_KEY_FILE"].strip()
    ttl_days = int(os.environ["APPLE_SECRET_TTL_DAYS"])

    with open(private_key_file, "rb") as fh:
        private_key = serialization.load_pem_private_key(fh.read(), password=None)

    now = int(time.time())
    exp = now + ttl_days * 86400

    header = {
        "alg": "ES256",
        "kid": key_id,
        "typ": "JWT",
    }
    payload = {
        "iss": team_id,
        "iat": now,
        "exp": exp,
        "aud": "https://appleid.apple.com",
        "sub": client_id,
    }

    signing_input = f"{encode_json(header)}.{encode_json(payload)}"
    signature_der = private_key.sign(signing_input.encode("utf-8"), ec.ECDSA(hashes.SHA256()))
    r_value, s_value = utils.decode_dss_signature(signature_der)
    signature_raw = r_value.to_bytes(32, "big") + s_value.to_bytes(32, "big")
    client_secret = f"{signing_input}.{b64url(signature_raw)}"

    normalized_client_ids = [client_id]
    if additional_client_ids:
        normalized_client_ids.extend(
            value.strip() for value in additional_client_ids.split(",") if value.strip()
        )
    joined_client_ids = ",".join(dict.fromkeys(normalized_client_ids))

    patch["external_apple_client_id"] = joined_client_ids
    patch["external_apple_secret"] = client_secret

    summary["patch"]["external_apple_client_id"] = joined_client_ids
    summary["patch"]["external_apple_additional_client_ids"] = additional_client_ids or None
    summary["patch"]["external_apple_secret_present"] = True
    summary["patch"]["generated_secret_expires_at_utc"] = datetime.fromtimestamp(exp, UTC).isoformat()

    if metadata_path:
        metadata = {
            "project_ref": project_ref,
            "team_id": team_id,
            "key_id": key_id,
            "client_ids": normalized_client_ids,
            "generated_at_utc": datetime.fromtimestamp(now, UTC).isoformat(),
            "expires_at_utc": datetime.fromtimestamp(exp, UTC).isoformat(),
        }
        metadata_file = Path(metadata_path)
        metadata_file.parent.mkdir(parents=True, exist_ok=True)
        metadata_file.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")

json.dump(patch, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)
json.dump(summary, open(sys.argv[3], "w"), ensure_ascii=False, indent=2)
print(json.dumps(summary, ensure_ascii=False, indent=2))
PY

curl -fsS -X PATCH "https://api.supabase.com/v1/projects/$PROJECT_REF/config/auth" \
  -H "Authorization: Bearer $SUPABASE_TOKEN" \
  -H 'Content-Type: application/json' \
  --data @"$PATCH_JSON" \
  > "$UPDATED_JSON"

python3 - "$UPDATED_JSON" "$SUMMARY_JSON" <<'PY'
import json
import os
import sys

updated = json.load(open(sys.argv[1]))
summary = json.load(open(sys.argv[2]))
summary["updated"] = {
    "external_apple_enabled": updated.get("external_apple_enabled"),
    "external_apple_client_id": updated.get("external_apple_client_id"),
    "external_apple_additional_client_ids": updated.get("external_apple_additional_client_ids"),
    "external_apple_secret_present": bool(updated.get("external_apple_secret")),
}
print("[supabase-apple] updated auth config:")
print(json.dumps(summary["updated"], ensure_ascii=False, indent=2))
if summary["patch"].get("generated_secret_expires_at_utc"):
    print("[supabase-apple] generated client secret expires at:")
    print(summary["patch"]["generated_secret_expires_at_utc"])
metadata_file = os.environ.get("APPLE_METADATA_FILE", "").strip()
if metadata_file:
    print("[supabase-apple] rotation metadata written to:")
    print(metadata_file)
PY
