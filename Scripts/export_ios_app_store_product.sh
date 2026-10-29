#!/usr/bin/env bash
# Export, but never upload, the physically accepted iOS archive for App Store Connect.
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPORT_OPTIONS="${ROOT_DIR}/Scripts/ios_app_store_export_options.plist"
ARCHIVE=""
ARCHIVE_IDENTITY=""
RELEASE_TESTING_IPA=""
PHYSICAL_ACCEPTANCE=""
EVIDENCE_ROOT=""
OUTPUT_DIR=""
API_KEY_PATH=""
API_KEY_ID=""
API_ISSUER_ID=""

usage() {
  cat >&2 <<'USAGE'
Usage: export_ios_app_store_product.sh \
  --archive /absolute/SkyBridgeCompass-iOS.xcarchive \
  --archive-identity /absolute/ios-release-archive-identity.json \
  --release-testing-ipa /absolute/release-candidate/export/SkyBridgeCompass-iOS.ipa \
  --physical-acceptance /absolute/ios-physical-release-acceptance.json \
  --evidence-root /absolute/physical-evidence-root \
  --output-dir /private/tmp/skybridge-ios-release-app-store \
  --api-key-path /absolute/AuthKey_KEYID.p8 \
  --api-key-id KEYID --api-issuer-id UUID

This command exports and verifies the exact physically accepted archive. It has
no upload mode. Use upload_ios_app_store_product.sh as a separate, explicitly
confirmed external transaction after reviewing the verification result.
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    --archive) ARCHIVE="${2:-}"; shift 2 ;;
    --archive-identity) ARCHIVE_IDENTITY="${2:-}"; shift 2 ;;
    --release-testing-ipa) RELEASE_TESTING_IPA="${2:-}"; shift 2 ;;
    --physical-acceptance) PHYSICAL_ACCEPTANCE="${2:-}"; shift 2 ;;
    --evidence-root) EVIDENCE_ROOT="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --api-key-path) API_KEY_PATH="${2:-}"; shift 2 ;;
    --api-key-id) API_KEY_ID="${2:-}"; shift 2 ;;
    --api-issuer-id) API_ISSUER_ID="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "[ios-app-store-export] ERROR: unknown argument" >&2; usage; exit 2 ;;
  esac
done

for value in \
  "$ARCHIVE" "$ARCHIVE_IDENTITY" "$RELEASE_TESTING_IPA" "$PHYSICAL_ACCEPTANCE" "$EVIDENCE_ROOT" \
  "$OUTPUT_DIR" "$API_KEY_PATH" "$API_KEY_ID" "$API_ISSUER_ID"; do
  if [[ -z "$value" ]]; then
    echo "[ios-app-store-export] ERROR: every documented argument is required." >&2
    usage
    exit 2
  fi
done

for path in "$ARCHIVE" "$ARCHIVE_IDENTITY" "$RELEASE_TESTING_IPA" "$PHYSICAL_ACCEPTANCE" "$EVIDENCE_ROOT" "$OUTPUT_DIR" "$API_KEY_PATH"; do
  if [[ "$path" != /* ]]; then
    echo "[ios-app-store-export] ERROR: all filesystem inputs must be absolute." >&2
    exit 2
  fi
done

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "[ios-app-store-export] ERROR: App Store export requires a clean repository." >&2
  exit 1
fi
SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"
if [[ ! "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "[ios-app-store-export] ERROR: current source commit is malformed." >&2
  exit 1
fi

IDENTITY_RECORD="$(
  PYTHONPATH="${ROOT_DIR}/Scripts" python3 - "$ARCHIVE_IDENTITY" <<'PY'
import sys
from pathlib import Path
from ios_release_archive_identity import load_identity

identity = load_identity(Path(sys.argv[1]))
print("\t".join((
    identity["sourceRepository"],
    identity["sourceCommit"],
    identity["sourceInputDigest"],
    identity["releaseVersion"],
    identity["releaseBuild"],
)))
PY
)"
IFS=$'\t' read -r SOURCE_REPOSITORY IDENTITY_COMMIT SOURCE_INPUT_DIGEST RELEASE_VERSION RELEASE_BUILD <<<"$IDENTITY_RECORD"
if [[ "$IDENTITY_COMMIT" != "$SOURCE_COMMIT" ]]; then
  echo "[ios-app-store-export] ERROR: checkout does not match the physically accepted archive source." >&2
  exit 1
fi
CURRENT_SOURCE_RECORD="$(
  python3 "${ROOT_DIR}/Scripts/source_input_digest.py" \
    --root "$ROOT_DIR" \
    Package.swift Package.resolved project.yml Config Sources Scripts Packages \
    "SkyBridge Compass iOS"
)"
read -r CURRENT_SOURCE_DIGEST CURRENT_SOURCE_COUNT CURRENT_SOURCE_EXTRA <<<"$CURRENT_SOURCE_RECORD"
if [[ "$CURRENT_SOURCE_DIGEST" != "$SOURCE_INPUT_DIGEST" || \
      ! "$CURRENT_SOURCE_COUNT" =~ ^[1-9][0-9]*$ || \
      -n "${CURRENT_SOURCE_EXTRA:-}" ]]; then
  echo "[ios-app-store-export] ERROR: checkout source inputs do not match the accepted archive." >&2
  exit 1
fi

python3 "${ROOT_DIR}/Scripts/validate_app_store_connect_key.py" \
  --key-path "$API_KEY_PATH" \
  --key-id "$API_KEY_ID" \
  --issuer-id "$API_ISSUER_ID" >/dev/null
python3 "${ROOT_DIR}/Scripts/validate_ios_app_store_export_options.py" \
  --options "$EXPORT_OPTIONS" >/dev/null
PYTHONPATH="${ROOT_DIR}/Scripts" python3 \
  "${ROOT_DIR}/Scripts/ios_physical_release_acceptance.py" verify \
  --identity "$ARCHIVE_IDENTITY" \
  --release-testing-ipa "$RELEASE_TESTING_IPA" \
  --evidence-root "$EVIDENCE_ROOT" \
  --acceptance "$PHYSICAL_ACCEPTANCE" >/dev/null

TEMPORARY_ROOT="$(cd "${TMPDIR:-/private/tmp}" && pwd -P)"
OUTPUT_DIR="$(
  python3 "${ROOT_DIR}/Scripts/validate_release_output_directory.py" \
    --repository-root "$ROOT_DIR" \
    --temporary-root "$TEMPORARY_ROOT" \
    --output "$OUTPUT_DIR"
)"
if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
  echo "[ios-app-store-export] ERROR: output directory must be fresh." >&2
  exit 1
fi
mkdir -m 0700 "$OUTPUT_DIR"
EXPORT_DIR="$OUTPUT_DIR/export"
VERIFICATION="$OUTPUT_DIR/ios-app-store-export-verification.json"
EXPORT_LOG="$OUTPUT_DIR/export.log"
PRIVATE_LOG_ROOT="$(mktemp -d "${TEMPORARY_ROOT%/}/skybridge-ios-app-store-log.XXXXXX")"
chmod 0700 "$PRIVATE_LOG_ROOT"
RAW_LOG="$PRIVATE_LOG_ROOT/xcodebuild-export.log"
cleanup() {
  if [[ -d "$PRIVATE_LOG_ROOT" && ! -L "$PRIVATE_LOG_ROOT" ]]; then
    rm -rf -- "$PRIVATE_LOG_ROOT"
  fi
}
trap cleanup EXIT

echo "[ios-app-store-export] exporting accepted iOS ${RELEASE_VERSION} (${RELEASE_BUILD}) archive"
set +e
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$API_KEY_PATH" \
  -authenticationKeyID "$API_KEY_ID" \
  -authenticationKeyIssuerID "$API_ISSUER_ID" \
  >"$RAW_LOG" 2>&1
EXPORT_STATUS=$?
set -e
python3 "${ROOT_DIR}/Scripts/redact_app_store_connect_log.py" \
  --input "$RAW_LOG" \
  --output "$EXPORT_LOG" \
  --secret-reference "$API_KEY_PATH" \
  --secret-reference "$API_KEY_ID" \
  --secret-reference "$API_ISSUER_ID" >/dev/null
if (( EXPORT_STATUS != 0 )); then
  echo "[ios-app-store-export] ERROR: xcodebuild App Store export failed; retained redacted log." >&2
  exit 1
fi
if LC_ALL=C grep -Eiq \
  '(^|[^[:alpha:]])(warning|error):|EXPORT FAILED|BUILD FAILED' \
  "$EXPORT_LOG"; then
  echo "[ios-app-store-export] ERROR: App Store export log contains a warning or error." >&2
  exit 1
fi

PYTHONPATH="${ROOT_DIR}/Scripts" python3 \
  "${ROOT_DIR}/Scripts/verify_ios_app_store_export.py" \
  --archive "$ARCHIVE" \
  --identity "$ARCHIVE_IDENTITY" \
  --physical-acceptance "$PHYSICAL_ACCEPTANCE" \
  --evidence-root "$EVIDENCE_ROOT" \
  --app-store-export-dir "$EXPORT_DIR" \
  --output "$VERIFICATION"

if [[ "$(git -C "$ROOT_DIR" rev-parse --verify HEAD)" != "$SOURCE_COMMIT" || \
      -n "$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "[ios-app-store-export] ERROR: source changed during App Store export." >&2
  exit 1
fi

echo "[ios-app-store-export] complete; upload was not performed"
echo "[ios-app-store-export] verification: $VERIFICATION"
echo "[ios-app-store-export] source: $SOURCE_REPOSITORY@$SOURCE_COMMIT"
