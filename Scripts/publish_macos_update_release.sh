#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Generate and upload the macOS update manifest to GitHub Releases.

Usage:
  publish_macos_update_release.sh [options]

Options:
  --repository <owner/repo>      GitHub repository (default: GITHUB_REPOSITORY or billlza/Skybridge-Compass)
  --tag <tag>                    Release tag that owns update assets (default: stable)
  --app-path <path>              App bundle used to read bundle id/version/build
  --dmg-path <path>              Notarized DMG to upload
  --manifest-path <path>         Output manifest path (default: dist/macos-stable.json)
  --key-id <id>                  Ed25519 manifest signing key id
  --private-key-file <path>      Base64 raw Ed25519 private seed; alternatively use SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64
  --sequence <int64>             Monotonic manifest sequence (default: app CFBundleVersion)
  --published-at <iso8601>       Publication timestamp (default: current UTC)
  --expires-at <iso8601>         Expiration timestamp (default: published_at + 30 days)
  --release-notes-url <url>      Release notes URL (default: GitHub release URL)
  --skip-upload                  Generate and verify the manifest but do not call gh release upload
  -h, --help                     Show this help

The generated manifest is uploaded as macos-stable.json. The manifest private key
is never accepted as a command-line value.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_ROOT}/Scripts/package_build_policy.sh"

REPOSITORY="${GITHUB_REPOSITORY:-billlza/Skybridge-Compass}"
TAG_NAME="stable"
APP_PATH="${PROJECT_ROOT}/dist/SkyBridge Compass Pro.app"
DMG_PATH=""
MANIFEST_PATH="${PROJECT_ROOT}/dist/macos-stable.json"
KEY_ID=""
PRIVATE_KEY_FILE=""
SEQUENCE=""
PUBLISHED_AT=""
EXPIRES_AT=""
RELEASE_NOTES_URL=""
SKIP_UPLOAD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository)
      REPOSITORY="${2:-}"
      shift 2
      ;;
    --tag)
      TAG_NAME="${2:-}"
      shift 2
      ;;
    --app-path)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --dmg-path)
      DMG_PATH="${2:-}"
      shift 2
      ;;
    --manifest-path)
      MANIFEST_PATH="${2:-}"
      shift 2
      ;;
    --key-id)
      KEY_ID="${2:-}"
      shift 2
      ;;
    --private-key-file)
      PRIVATE_KEY_FILE="${2:-}"
      shift 2
      ;;
    --sequence)
      SEQUENCE="${2:-}"
      shift 2
      ;;
    --published-at)
      PUBLISHED_AT="${2:-}"
      shift 2
      ;;
    --expires-at)
      EXPIRES_AT="${2:-}"
      shift 2
      ;;
    --release-notes-url)
      RELEASE_NOTES_URL="${2:-}"
      shift 2
      ;;
    --skip-upload)
      SKIP_UPLOAD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[publish-update] unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

fail() {
  echo "[publish-update] ERROR: $1" >&2
  exit 1
}

plist_read_value() {
  local plist_path="$1"
  local key_path="$2"

  python3 - "${plist_path}" "${key_path}" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
key_path = sys.argv[2].split(".")

if not plist_path.exists():
    raise SystemExit(1)

with plist_path.open("rb") as handle:
    value = plistlib.load(handle)

for key in key_path:
    if isinstance(value, dict) and key in value:
        value = value[key]
    else:
        raise SystemExit(1)

if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    raise SystemExit(1)
else:
    print(value)
PY
}

sha256_file() {
  shasum -a 256 "$1" | awk '{ print $1 }'
}

resolve_default_sequence() {
  local app_info_plist="$1"
  local build=""

  build="$(plist_read_value "$app_info_plist" "CFBundleVersion" 2>/dev/null || true)"
  if [[ "$build" =~ ^[0-9]+$ && "$build" -gt 0 ]]; then
    printf '%s\n' "$build"
    return 0
  fi

  date -u '+%Y%m%d%H%M%S'
}

resolve_default_dmg_path() {
  local app_info_plist="$1"
  local version=""
  local candidate=""

  version="$(plist_read_value "${app_info_plist}" "CFBundleShortVersionString" 2>/dev/null || true)"
  [[ -n "${version}" ]] || fail "app Info.plist is missing CFBundleShortVersionString"

  candidate="${PROJECT_ROOT}/dist/SkyBridgeCompassPro-${version}.dmg"
  [[ -f "${candidate}" ]] || fail "default DMG does not exist for app version ${version}: ${candidate}"
  printf '%s\n' "${candidate}"
}

validate_notarized_dmg_before_publish() {
  local dmg_path="$1"

  command -v xcrun >/dev/null 2>&1 || fail "xcrun is required for notarization verification"
  command -v spctl >/dev/null 2>&1 || fail "spctl is required for Gatekeeper verification"
  xcrun stapler validate "$dmg_path" \
    || fail "DMG does not have a valid stapled notarization ticket: $dmg_path"
  spctl --assess --type open --verbose=4 "$dmg_path" >/dev/null \
    || fail "Gatekeeper rejects the notarized DMG: $dmg_path"
}

verify_uploaded_release_assets() {
  local verify_dir="$1"
  local dmg_asset_name="$2"
  local expected_dmg_sha="$3"
  local manifest_path="$4"
  local downloaded_dmg="${verify_dir}/${dmg_asset_name}"
  local downloaded_manifest="${verify_dir}/macos-stable.json"
  local manifest_sha=""

  gh release download "$TAG_NAME" \
    --repo "$REPOSITORY" \
    --pattern "$dmg_asset_name" \
    --pattern "macos-stable.json" \
    --dir "$verify_dir" \
    --clobber

  [[ -f "$downloaded_dmg" ]] || fail "uploaded DMG asset could not be downloaded back: $dmg_asset_name"
  [[ -f "$downloaded_manifest" ]] || fail "uploaded stable manifest could not be downloaded back"
  [[ "$(sha256_file "$downloaded_dmg")" == "$expected_dmg_sha" ]] \
    || fail "downloaded DMG sha256 does not match the uploaded local DMG"
  cmp -s "$manifest_path" "$downloaded_manifest" \
    || fail "downloaded macos-stable.json does not match the generated manifest"

  manifest_sha="$(
    python3 - "$downloaded_manifest" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(manifest.get("sha256", ""))
PY
  )"
  [[ "$manifest_sha" == "$expected_dmg_sha" ]] \
    || fail "manifest sha256 (${manifest_sha:-missing}) does not match uploaded DMG sha256"

  if ! python3 - "$downloaded_manifest" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
attestation = manifest.get("apple_pqc_sdk_build")
if not isinstance(attestation, dict):
    raise SystemExit(1)
expected = {
    "compiled_with_has_apple_pqc_sdk": True,
    "compile_marker": "skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk",
    "probe_mode": "symbol_probe",
    "sdk_name": "macosx",
    "sdk_version": "26.5",
    "swift_target": "arm64-apple-macosx26.0",
    "secure_enclave_symbols_included": True,
    "symbol_set": "cryptokit-pqc-v1",
}
for key, value in expected.items():
    if attestation.get(key) != value:
        print(f"unexpected apple_pqc_sdk_build.{key}: {attestation.get(key)!r}", file=sys.stderr)
        raise SystemExit(1)
if not isinstance(attestation.get("signature"), dict):
    raise SystemExit(1)
PY
  then
    fail "uploaded manifest is missing release-grade signed Apple PQC SDK build provenance"
  fi
}

[[ -d "$APP_PATH" ]] || fail "app bundle does not exist: $APP_PATH"
APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$APP_INFO_PLIST" ]] || fail "app Info.plist does not exist: $APP_INFO_PLIST"
skybridge_assert_bundle_has_apple_pqc_compile_marker "$APP_PATH" "update manifest source app bundle" \
  || fail "app bundle is missing the Apple PQC SDK compile marker"
if [[ -z "$DMG_PATH" ]]; then
  DMG_PATH="$(resolve_default_dmg_path "$APP_INFO_PLIST")"
fi
[[ -f "$DMG_PATH" ]] || fail "DMG does not exist: $DMG_PATH"
[[ -n "$REPOSITORY" && "$REPOSITORY" == */* ]] || fail "repository must be owner/repo"
[[ -n "$TAG_NAME" ]] || fail "release tag is required"
[[ -n "$KEY_ID" ]] || fail "--key-id is required"
if [[ -n "$PRIVATE_KEY_FILE" && ! -f "$PRIVATE_KEY_FILE" ]]; then
  fail "private key file does not exist: $PRIVATE_KEY_FILE"
fi
if [[ -z "$PRIVATE_KEY_FILE" && -z "${SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64:-}" ]]; then
  fail "provide --private-key-file or SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64"
fi

if [[ -z "$SEQUENCE" ]]; then
  SEQUENCE="$(resolve_default_sequence "$APP_INFO_PLIST")"
fi
[[ "$SEQUENCE" =~ ^[0-9]+$ && "$SEQUENCE" -gt 0 ]] || fail "manifest sequence must be a positive integer"

DMG_DIR="$(cd "$(dirname "$DMG_PATH")" && pwd)"
DMG_PATH="${DMG_DIR}/$(basename "$DMG_PATH")"

if [[ -z "$PUBLISHED_AT" ]]; then
  PUBLISHED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi
if [[ -z "$EXPIRES_AT" ]]; then
  EXPIRES_AT="$(date -u -v+30d '+%Y-%m-%dT%H:%M:%SZ')"
fi
if [[ -z "$RELEASE_NOTES_URL" ]]; then
  RELEASE_NOTES_URL="https://github.com/${REPOSITORY}/releases/tag/${TAG_NAME}"
fi

DMG_ASSET_NAME="$(basename "$DMG_PATH")"
MANIFEST_ASSET_PATH="$(dirname "$MANIFEST_PATH")/macos-stable.json"
if [[ "$MANIFEST_PATH" != "$MANIFEST_ASSET_PATH" ]]; then
  MANIFEST_PATH="$MANIFEST_ASSET_PATH"
fi
DOWNLOAD_URL="https://github.com/${REPOSITORY}/releases/download/${TAG_NAME}/${DMG_ASSET_NAME}"
EXPECTED_DMG_SHA="$(sha256_file "$DMG_PATH")"
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-update-publish.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT

skybridge_assert_release_stable_toolchain "release_dmg" "${PROJECT_ROOT}/Scripts/verify_xcode_toolchain.sh" "macOS update publishing" || exit 1
validate_notarized_dmg_before_publish "$DMG_PATH"

GENERATOR_ARGS=(
  "$PROJECT_ROOT/Scripts/generate_macos_update_manifest.swift"
  --app-path "$APP_PATH"
  --package-path "$DMG_PATH"
  --download-url "$DOWNLOAD_URL"
  --release-notes-url "$RELEASE_NOTES_URL"
  --key-id "$KEY_ID"
  --sequence "$SEQUENCE"
  --published-at "$PUBLISHED_AT"
  --expires-at "$EXPIRES_AT"
  --output "$MANIFEST_PATH"
  --notarized
)
if [[ -n "$PRIVATE_KEY_FILE" ]]; then
  GENERATOR_ARGS+=(--private-key-file "$PRIVATE_KEY_FILE")
fi

swift "${GENERATOR_ARGS[@]}"

if [[ "$SKIP_UPLOAD" == "1" ]]; then
  echo "[publish-update] generated manifest without upload: $MANIFEST_PATH"
  exit 0
fi

command -v gh >/dev/null 2>&1 || fail "gh CLI is required for upload"
gh auth status >/dev/null || fail "gh CLI is not authenticated"

if ! gh release view "$TAG_NAME" --repo "$REPOSITORY" >/dev/null 2>&1; then
  gh release create "$TAG_NAME" \
    --repo "$REPOSITORY" \
    --title "SkyBridge Compass stable macOS updates" \
    --notes "Stable macOS update channel assets for SkyBridge Compass." \
    --latest=false
fi

gh release upload "$TAG_NAME" \
  "$DMG_PATH" \
  "$MANIFEST_PATH" \
  --repo "$REPOSITORY" \
  --clobber

verify_uploaded_release_assets "$VERIFY_DIR" "$DMG_ASSET_NAME" "$EXPECTED_DMG_SHA" "$MANIFEST_PATH"

echo "[publish-update] uploaded $DMG_ASSET_NAME and macos-stable.json to ${REPOSITORY}@${TAG_NAME}"
