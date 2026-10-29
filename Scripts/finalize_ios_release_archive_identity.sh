#!/usr/bin/env bash
# Seal one release-testing IPA and its source xcarchive as one reliability identity.
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_ROOT="${SKYBRIDGE_RC_OUTPUT_DIR:-${ROOT_DIR}/.sandbox-home/release-candidate}"
ARCHIVE=""
EXPORT_DIR=""
ACCEPTANCE=""
IDENTITY=""

while (( $# > 0 )); do
  case "$1" in
    --release-root) RELEASE_ROOT="${2:-}"; shift 2 ;;
    --archive) ARCHIVE="${2:-}"; shift 2 ;;
    --release-testing-export-dir) EXPORT_DIR="${2:-}"; shift 2 ;;
    --release-testing-acceptance) ACCEPTANCE="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --help|-h)
      echo "Usage: finalize_ios_release_archive_identity.sh [--release-root ABSOLUTE] [explicit path overrides]" >&2
      exit 0
      ;;
    *) echo "[ios-archive-identity] ERROR: unknown argument" >&2; exit 2 ;;
  esac
done

ARCHIVE="${ARCHIVE:-${RELEASE_ROOT}/SkyBridgeCompass-iOS.xcarchive}"
EXPORT_DIR="${EXPORT_DIR:-${RELEASE_ROOT}/export}"
ACCEPTANCE="${ACCEPTANCE:-${RELEASE_ROOT}/ios-release-acceptance-sha256.json}"
IDENTITY="${IDENTITY:-${RELEASE_ROOT}/ios-release-archive-identity.json}"

for path in "$RELEASE_ROOT" "$ARCHIVE" "$EXPORT_DIR" "$ACCEPTANCE" "$IDENTITY"; do
  if [[ "$path" != /* ]]; then
    echo "[ios-archive-identity] ERROR: every release path must be absolute." >&2
    exit 2
  fi
done
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "[ios-archive-identity] ERROR: archive identity requires the candidate's clean checkout." >&2
  exit 1
fi
SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"
SOURCE_REPOSITORY="${GITHUB_REPOSITORY:-${SKYBRIDGE_SOURCE_REPOSITORY:-billlza/Skybridge-Compass}}"
VERSION_RECORD="$(bash "${ROOT_DIR}/Scripts/check_ios_release_version.sh")"
IFS=$'\t' read -r RELEASE_VERSION RELEASE_BUILD RELEASE_EXTRA <<<"$VERSION_RECORD"
if [[ -n "${RELEASE_EXTRA:-}" || -z "$RELEASE_VERSION" || -z "$RELEASE_BUILD" ]]; then
  echo "[ios-archive-identity] ERROR: iOS release version transaction is malformed." >&2
  exit 1
fi

PYTHONPATH="${ROOT_DIR}/Scripts" python3 \
  "${ROOT_DIR}/Scripts/ios_release_archive_identity.py" create \
  --archive "$ARCHIVE" \
  --release-testing-export-dir "$EXPORT_DIR" \
  --release-testing-acceptance "$ACCEPTANCE" \
  --identity "$IDENTITY" \
  --expected-version "$RELEASE_VERSION" \
  --expected-build "$RELEASE_BUILD" \
  --expected-repository "$SOURCE_REPOSITORY" \
  --expected-commit "$SOURCE_COMMIT"
