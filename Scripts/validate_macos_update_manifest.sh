#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Validate that a signed macOS update manifest advertises the exact local app and DMG.

Usage:
  validate_macos_update_manifest.sh --manifest-path <macos-stable.json> --app-path <app bundle> --dmg-path <dmg> [options]

Options:
  --require-apple-pqc-sdk-build  Require release-grade signed Apple PQC SDK build provenance
  --now <iso8601>                Override current time for deterministic tests
  -h, --help                     Show this help
USAGE
}

fail() {
  echo "[validate-macos-update-manifest] ERROR: $1" >&2
  exit 1
}

MANIFEST_PATH=""
APP_PATH=""
DMG_PATH=""
NOW=""
REQUIRE_APPLE_PQC_SDK_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest-path)
      MANIFEST_PATH="${2:-}"
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
    --require-apple-pqc-sdk-build)
      REQUIRE_APPLE_PQC_SDK_BUILD=1
      shift
      ;;
    --now)
      NOW="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[validate-macos-update-manifest] unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "${MANIFEST_PATH}" ]] || fail "--manifest-path is required"
[[ -n "${APP_PATH}" ]] || fail "--app-path is required"
[[ -n "${DMG_PATH}" ]] || fail "--dmg-path is required"
[[ -f "${MANIFEST_PATH}" ]] || fail "manifest does not exist: ${MANIFEST_PATH}"
[[ -d "${APP_PATH}" ]] || fail "app bundle does not exist: ${APP_PATH}"
[[ -f "${APP_PATH}/Contents/Info.plist" ]] || fail "app Info.plist does not exist: ${APP_PATH}/Contents/Info.plist"
[[ -f "${DMG_PATH}" ]] || fail "DMG does not exist: ${DMG_PATH}"

python3 - "${MANIFEST_PATH}" "${APP_PATH}/Contents/Info.plist" "${DMG_PATH}" "${REQUIRE_APPLE_PQC_SDK_BUILD}" "${NOW}" <<'PY'
import base64
import binascii
import datetime as dt
import hashlib
import json
import plistlib
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

manifest_path = Path(sys.argv[1])
app_info_path = Path(sys.argv[2])
dmg_path = Path(sys.argv[3])
require_apple_pqc_sdk_build = sys.argv[4] == "1"
now_arg = sys.argv[5]

errors = []


def error(message):
    errors.append(message)


def load_manifest(path):
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
    except json.JSONDecodeError as exc:
        error(f"manifest is not valid JSON: {exc}")
        return {}
    if not isinstance(value, dict):
        error("manifest root must be a JSON object")
        return {}
    return value


def load_plist(path):
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except Exception as exc:
        error(f"app Info.plist could not be read: {exc}")
        return {}
    if not isinstance(value, dict):
        error("app Info.plist root must be a dictionary")
        return {}
    return value


def string_value(mapping, key):
    value = mapping.get(key)
    if isinstance(value, str) and value.strip():
        return value.strip()
    error(f"{key} must be a non-empty string")
    return ""


def optional_string_value(mapping, key):
    value = mapping.get(key)
    if value is None:
        return None
    if isinstance(value, str) and value.strip():
        return value.strip()
    error(f"{key} must be a non-empty string when present")
    return ""


def int_value(mapping, key):
    value = mapping.get(key)
    if isinstance(value, bool):
        error(f"{key} must be an integer")
        return None
    if isinstance(value, int):
        return value
    error(f"{key} must be an integer")
    return None


def bool_value(mapping, key):
    value = mapping.get(key)
    if isinstance(value, bool):
        return value
    error(f"{key} must be a boolean")
    return None


def parse_timestamp(value, key):
    if not isinstance(value, str) or not value.strip():
        error(f"{key} must be a non-empty ISO-8601 UTC timestamp")
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        error(f"{key} is not a valid ISO-8601 timestamp: {value}")
        return None
    if parsed.tzinfo is None:
        error(f"{key} must include a timezone: {value}")
        return None
    return parsed.astimezone(dt.timezone.utc)


def parse_now(value):
    if not value:
        return dt.datetime.now(dt.timezone.utc)
    parsed = parse_timestamp(value, "--now")
    return parsed or dt.datetime.now(dt.timezone.utc)


def validate_https_url(value, key, require_github=False, expected_basename=None):
    if not value:
        return
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc:
        error(f"{key} must be an HTTPS URL")
        return
    if require_github and parsed.netloc.lower() != "github.com":
        error(f"{key} must be a github.com release asset URL")
    if expected_basename:
        actual_basename = Path(unquote(parsed.path)).name
        if actual_basename != expected_basename:
            error(f"{key} asset name {actual_basename!r} does not match DMG {expected_basename!r}")


def validate_signature(mapping, key, display_key=None):
    display_key = display_key or key
    value = mapping.get(key)
    if not isinstance(value, dict):
        error(f"{display_key} must be an object")
        return
    algorithm = string_value(value, "algorithm")
    key_id = string_value(value, "key_id")
    signature_value = string_value(value, "value")
    if algorithm.lower() != "ed25519":
        error(f"{display_key}.algorithm must be ed25519")
    if not key_id:
        error(f"{display_key}.key_id must not be empty")
    if signature_value:
        padded = signature_value + ("=" * ((4 - len(signature_value) % 4) % 4))
        try:
            decoded = base64.urlsafe_b64decode(padded.encode("ascii"))
        except (ValueError, binascii.Error):
            error(f"{display_key}.value must be base64 or base64url")
            return
        if len(decoded) != 64:
            error(f"{display_key}.value must decode to a 64-byte Ed25519 signature")


manifest = load_manifest(manifest_path)
app_info = load_plist(app_info_path)
now = parse_now(now_arg)

manifest_filename = manifest_path.name
if manifest_filename != "macos-stable.json":
    error(f"manifest file name must be macos-stable.json, got {manifest_filename}")

expected_sha = hashlib.sha256(dmg_path.read_bytes()).hexdigest()
expected_size = dmg_path.stat().st_size
expected_dmg_name = dmg_path.name

app_bundle_id = string_value(app_info, "CFBundleIdentifier")
app_version = string_value(app_info, "CFBundleShortVersionString")
app_build = string_value(app_info, "CFBundleVersion")
app_minimum_system_version = optional_string_value(app_info, "LSMinimumSystemVersion")

schema_version = int_value(manifest, "schema_version")
sequence = int_value(manifest, "sequence")
size_bytes = int_value(manifest, "size_bytes")
notarized = bool_value(manifest, "notarized")
bundle_id = string_value(manifest, "bundle_id")
platform = string_value(manifest, "platform")
channel = string_value(manifest, "channel")
version = string_value(manifest, "version")
build = string_value(manifest, "build")
minimum_system_version = string_value(manifest, "minimum_system_version")
download_url = string_value(manifest, "download_url")
release_notes_url = optional_string_value(manifest, "release_notes_url")
sha256 = string_value(manifest, "sha256")
package_format = string_value(manifest, "package_format")
distribution = string_value(manifest, "distribution")
published_at = parse_timestamp(manifest.get("published_at"), "published_at")
expires_at = parse_timestamp(manifest.get("expires_at"), "expires_at")

if schema_version != 1:
    error(f"schema_version must be 1, got {schema_version!r}")
if bundle_id != app_bundle_id:
    error(f"bundle_id {bundle_id!r} does not match app CFBundleIdentifier {app_bundle_id!r}")
if platform != "macos":
    error(f"platform must be macos, got {platform!r}")
if channel != "stable":
    error(f"channel must be stable, got {channel!r}")
if version != app_version:
    error(f"version {version!r} does not match app CFBundleShortVersionString {app_version!r}")
if build != app_build:
    error(f"build {build!r} does not match app CFBundleVersion {app_build!r}")
if app_minimum_system_version is not None and minimum_system_version != app_minimum_system_version:
    error(
        "minimum_system_version "
        f"{minimum_system_version!r} does not match app LSMinimumSystemVersion {app_minimum_system_version!r}"
    )
if sequence is not None:
    if sequence <= 0:
        error("sequence must be a positive integer")
    if app_build.isdigit() and sequence < int(app_build):
        error(f"sequence {sequence} must be at least the numeric app build {app_build}")
if published_at is not None and published_at > now:
    error(f"published_at {manifest.get('published_at')!r} is in the future relative to {now.isoformat()}")
if expires_at is not None and expires_at <= now:
    error(f"expires_at {manifest.get('expires_at')!r} is not later than {now.isoformat()}")
if published_at is not None and expires_at is not None and expires_at <= published_at:
    error("expires_at must be later than published_at")
validate_https_url(download_url, "download_url", require_github=True, expected_basename=expected_dmg_name)
validate_https_url(release_notes_url, "release_notes_url")
if not re.fullmatch(r"[0-9a-fA-F]{64}", sha256):
    error("sha256 must be a 64-character hex digest")
elif sha256.lower() != expected_sha:
    error(f"sha256 {sha256} does not match DMG sha256 {expected_sha}")
if package_format != "dmg":
    error(f"package_format must be dmg, got {package_format!r}")
if distribution != "developer-id":
    error(f"distribution must be developer-id, got {distribution!r}")
if notarized is not True:
    error("notarized must be true")
if size_bytes != expected_size:
    error(f"size_bytes {size_bytes!r} does not match DMG size {expected_size}")
validate_signature(manifest, "signature")

attestation = manifest.get("apple_pqc_sdk_build")
if require_apple_pqc_sdk_build and not isinstance(attestation, dict):
    error("apple_pqc_sdk_build must be present and signed")
elif isinstance(attestation, dict):
    expected_attestation = {
        "compiled_with_has_apple_pqc_sdk": True,
        "compile_marker": "skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk",
        "probe_mode": "symbol_probe",
        "sdk_name": "macosx",
        "sdk_version": "26.5",
        "swift_target": "arm64-apple-macosx26.0",
        "secure_enclave_symbols_included": True,
        "symbol_set": "cryptokit-pqc-v1",
    }
    for key, expected_value in expected_attestation.items():
        actual_value = attestation.get(key)
        if actual_value != expected_value:
            error(f"apple_pqc_sdk_build.{key} {actual_value!r} does not match expected {expected_value!r}")
    validate_signature(attestation, "signature", "apple_pqc_sdk_build.signature")

if errors:
    for item in errors:
        print(f"[validate-macos-update-manifest] {item}", file=sys.stderr)
    sys.exit(1)

print("[validate-macos-update-manifest] ok")
PY
