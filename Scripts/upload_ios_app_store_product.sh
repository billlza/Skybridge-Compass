#!/usr/bin/env bash
# Explicit external App Store upload transaction. Never called by the exporter.
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPORT_DIR=""
VERIFICATION=""
API_KEY_PATH=""
API_KEY_ID=""
API_ISSUER_ID=""
CONFIRM_UPLOAD=0

usage() {
  cat >&2 <<'USAGE'
Usage: upload_ios_app_store_product.sh --confirm-upload \
  --export-dir /absolute/app-store-export \
  --verification /absolute/ios-app-store-export-verification.json \
  --api-key-path /absolute/AuthKey_KEYID.p8 \
  --api-key-id KEYID --api-issuer-id UUID

This command performs an external upload. Omitting --confirm-upload fails before
credentials or the network are used.
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    --confirm-upload) CONFIRM_UPLOAD=1; shift ;;
    --export-dir) EXPORT_DIR="${2:-}"; shift 2 ;;
    --verification) VERIFICATION="${2:-}"; shift 2 ;;
    --api-key-path) API_KEY_PATH="${2:-}"; shift 2 ;;
    --api-key-id) API_KEY_ID="${2:-}"; shift 2 ;;
    --api-issuer-id) API_ISSUER_ID="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "[ios-app-store-upload] ERROR: unknown argument" >&2; usage; exit 2 ;;
  esac
done

if [[ "$CONFIRM_UPLOAD" != "1" ]]; then
  echo "[ios-app-store-upload] ERROR: --confirm-upload is required for this external action." >&2
  exit 2
fi
for value in "$EXPORT_DIR" "$VERIFICATION" "$API_KEY_PATH" "$API_KEY_ID" "$API_ISSUER_ID"; do
  if [[ -z "$value" ]]; then
    echo "[ios-app-store-upload] ERROR: every documented argument is required." >&2
    exit 2
  fi
done
for path in "$EXPORT_DIR" "$VERIFICATION" "$API_KEY_PATH"; do
  if [[ "$path" != /* ]]; then
    echo "[ios-app-store-upload] ERROR: all filesystem inputs must be absolute." >&2
    exit 2
  fi
done

python3 "${ROOT_DIR}/Scripts/validate_app_store_connect_key.py" \
  --key-path "$API_KEY_PATH" --key-id "$API_KEY_ID" --issuer-id "$API_ISSUER_ID" >/dev/null
IPA_PATH="$(
  PYTHONPATH="${ROOT_DIR}/Scripts" python3 \
    "${ROOT_DIR}/Scripts/ios_app_store_upload_preflight.py" \
    --export-dir "$EXPORT_DIR" \
    --verification "$VERIFICATION"
)"
RESULT_PATH="$(dirname "$VERIFICATION")/ios-app-store-upload-result.log"
if [[ -e "$RESULT_PATH" || -L "$RESULT_PATH" ]]; then
  echo "[ios-app-store-upload] ERROR: upload result already exists; refusing a duplicate transaction." >&2
  exit 1
fi
TEMPORARY_ROOT="$(cd "${TMPDIR:-/private/tmp}" && pwd -P)"
PRIVATE_RESULT_ROOT="$(mktemp -d "${TEMPORARY_ROOT%/}/skybridge-ios-upload-result.XXXXXX")"
chmod 0700 "$PRIVATE_RESULT_ROOT"
RAW_RESULT="$PRIVATE_RESULT_ROOT/altool-result.json"
cleanup() {
  if [[ -d "$PRIVATE_RESULT_ROOT" && ! -L "$PRIVATE_RESULT_ROOT" ]]; then
    rm -rf -- "$PRIVATE_RESULT_ROOT"
  fi
}
trap cleanup EXIT

echo "[ios-app-store-upload] starting explicitly confirmed external upload"
set +e
xcrun altool --upload-package "$IPA_PATH" \
  --api-key "$API_KEY_ID" \
  --api-issuer "$API_ISSUER_ID" \
  --p8-file-path "$API_KEY_PATH" \
  --output-format json \
  >"$RAW_RESULT" 2>&1
UPLOAD_STATUS=$?
set -e
python3 "${ROOT_DIR}/Scripts/redact_app_store_connect_log.py" \
  --input "$RAW_RESULT" \
  --output "$RESULT_PATH" \
  --secret-reference "$API_KEY_PATH" \
  --secret-reference "$API_KEY_ID" \
  --secret-reference "$API_ISSUER_ID" >/dev/null
if (( UPLOAD_STATUS != 0 )); then
  echo "[ios-app-store-upload] ERROR: App Store upload failed; retained redacted result." >&2
  exit 1
fi
echo "[ios-app-store-upload] upload accepted; processing remains a separate App Store Connect gate"
echo "[ios-app-store-upload] result: $RESULT_PATH"
