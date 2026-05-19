#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

source "${PROJECT_ROOT}/Scripts/notarytool_helpers.sh"
source "${PROJECT_ROOT}/Scripts/signing_entitlements_helpers.sh"

APP_BUNDLE_ID=""
APP_ENTITLEMENTS="${PROJECT_ROOT}/Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.packaging.entitlements"
WIDGET_BUNDLE_ID="com.skybridge.compass.pro.widgets"
WIDGET_ENTITLEMENTS="${PROJECT_ROOT}/Sources/SkyBridgeCompassWidgets/SkyBridgeCompassWidgetsExtension.entitlements"
SIGNING_IDENTITY="${IDENTITY:-${SIGNING_IDENTITY:-}}"
CREATE_MISSING=0
ASSOCIATE_APP_GROUPS=0
DEVELOPER_APPLE_ID="${FASTLANE_USER:-${SKYBRIDGE_DEVELOPER_PORTAL_APPLE_ID:-}}"

usage() {
  cat <<'EOF'
Usage: Scripts/ensure_developer_id_profiles.sh [options]

Checks that the macOS app and Widget Extension have matching Developer ID
provisioning profiles. With --create, missing or stale profiles are recreated
from the local App Store Connect API key.

Options:
  --create                    Create/recreate missing or stale profiles.
  --associate-app-groups      If profile validation shows missing concrete App
                              Groups, use an interactive fastlane Portal session
                              to associate the groups before recreating profiles.
  --identity <name>           Developer ID Application signing identity.
  --app-bundle-id <id>        Main app bundle identifier.
  --app-entitlements <path>   Main app packaging entitlements.
  --widget-bundle-id <id>     Widget Extension bundle identifier.
  --widget-entitlements <p>   Widget Extension entitlements.
  --apple-id <email>          Apple Developer Portal login for app-group association.
  --help                      Show this help.

API key inputs:
  - APP_STORE_CONNECT_API_KEY_PATH pointing to a fastlane JSON key, or
  - ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID, or
  - NOTARYTOOL_KEY/NOTARYTOOL_KEY_ID/NOTARYTOOL_ISSUER from
    ~/.config/skybridge/notarytool.env.
EOF
}

log() {
  echo "[ensure-profiles] $*" >&2
}

die() {
  echo "[ensure-profiles] ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --create)
      CREATE_MISSING=1
      shift
      ;;
    --associate-app-groups)
      ASSOCIATE_APP_GROUPS=1
      shift
      ;;
    --identity)
      SIGNING_IDENTITY="${2:-}"
      shift 2
      ;;
    --app-bundle-id)
      APP_BUNDLE_ID="${2:-}"
      shift 2
      ;;
    --app-entitlements)
      APP_ENTITLEMENTS="${2:-}"
      shift 2
      ;;
    --widget-bundle-id)
      WIDGET_BUNDLE_ID="${2:-}"
      shift 2
      ;;
    --widget-entitlements)
      WIDGET_ENTITLEMENTS="${2:-}"
      shift 2
      ;;
    --apple-id)
      DEVELOPER_APPLE_ID="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

read_plist_string() {
  local plist_path="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :${key}" "${plist_path}" 2>/dev/null || true
}

if [[ -z "${APP_BUNDLE_ID}" ]]; then
  APP_BUNDLE_ID="$(read_plist_string "${PROJECT_ROOT}/XcodeSupport/SkyBridgeCompassMac/Info.plist" "CFBundleIdentifier")"
fi
if [[ -z "${APP_BUNDLE_ID}" ]]; then
  APP_BUNDLE_ID="com.skybridge.compass.pro"
fi

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/Developer ID Application/ {print $2; exit}')"
fi

[[ -n "${SIGNING_IDENTITY}" ]] || die "No Developer ID Application signing identity found."
[[ "${SIGNING_IDENTITY}" == Developer\ ID\ Application:* ]] \
  || die "Developer ID profile check requires Developer ID Application identity, got: ${SIGNING_IDENTITY}"

TEAM_ID="$(printf '%s' "${SIGNING_IDENTITY}" | sed -n 's/.*(\([^)]*\)).*/\1/p')"
[[ -n "${TEAM_ID}" ]] || die "Could not extract Team ID from signing identity: ${SIGNING_IDENTITY}"

DEVELOPER_ID_SHA1="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -v identity="${SIGNING_IDENTITY}" 'index($0, "\"" identity "\"") {print $2; exit}')"
DEVELOPER_ID_SHA1="${DEVELOPER_ID_SHA1//:/}"
DEVELOPER_ID_SHA1="$(printf '%s' "${DEVELOPER_ID_SHA1}" | tr '[:lower:]' '[:upper:]')"

profile_search_dirs() {
  local dir
  for dir in \
    "${HOME}/Library/MobileDevice/Provisioning Profiles" \
    "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
    [[ -d "${dir}" ]] && printf '%s\n' "${dir}"
  done
}

profile_is_developer_id_distribution() {
  local profile_path="$1"
  local expected_cert_sha1="${2:-}"

  python3 - "${profile_path}" "${expected_cert_sha1}" <<'PY'
import datetime as dt
import hashlib
import plistlib
import subprocess
import sys
from pathlib import Path


def load_profile(path: Path):
    payload = path.read_bytes()
    try:
        return plistlib.loads(payload)
    except Exception:
        pass
    for command in (
        ["security", "cms", "-D", "-i", str(path)],
        ["openssl", "smime", "-inform", "DER", "-verify", "-noverify", "-in", str(path)],
    ):
        completed = subprocess.run(command, check=False, capture_output=True)
        if completed.returncode == 0 and completed.stdout:
            return plistlib.loads(completed.stdout)
    print(f"could not decode provisioning profile: {path}", file=sys.stderr)
    raise SystemExit(1)


profile_path = Path(sys.argv[1])
expected_sha1 = sys.argv[2].strip().replace(":", "").upper()
profile = load_profile(profile_path)

if profile.get("ProvisionsAllDevices") is not True:
    print(f"profile is not a Developer ID direct distribution profile: {profile_path}", file=sys.stderr)
    raise SystemExit(1)

expires = profile.get("ExpirationDate")
if isinstance(expires, dt.datetime):
    now = dt.datetime.now(tz=expires.tzinfo) if expires.tzinfo else dt.datetime.now()
    if expires <= now:
        print(f"profile has expired: {profile_path}", file=sys.stderr)
        raise SystemExit(1)

if expected_sha1:
    certs = profile.get("DeveloperCertificates") or []
    cert_hashes = {
        hashlib.sha1(bytes(cert)).hexdigest().upper()
        for cert in certs
    }
    if expected_sha1 not in cert_hashes:
        print(
            f"profile does not include current Developer ID certificate: {profile_path}",
            file=sys.stderr,
        )
        raise SystemExit(1)
PY
}

profile_matches_target() {
  local profile_path="$1"
  local bundle_id="$2"
  local entitlements_path="$3"

  skybridge_validate_provisionprofile_app_identity "${profile_path}" "${bundle_id}" "${TEAM_ID}" >/dev/null 2>&1 \
    || return 1
  skybridge_profile_supports_requested_restricted_entitlements "${profile_path}" "${entitlements_path}" >/dev/null 2>&1 \
    || return 1
  profile_is_developer_id_distribution "${profile_path}" "${DEVELOPER_ID_SHA1}" >/dev/null 2>&1 \
    || return 1
}

find_matching_profile() {
  local bundle_id="$1"
  local entitlements_path="$2"
  local explicit_path="${3:-}"
  local dir
  local candidate

  if [[ -n "${explicit_path}" ]]; then
    if [[ -f "${explicit_path}" ]] && profile_matches_target "${explicit_path}" "${bundle_id}" "${entitlements_path}"; then
      printf '%s\n' "${explicit_path}"
      return 0
    fi
    return 1
  fi

  while IFS= read -r dir; do
    while IFS= read -r -d '' candidate; do
      if profile_matches_target "${candidate}" "${bundle_id}" "${entitlements_path}"; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    done < <(find "${dir}" -type f \( -name "*.provisionprofile" -o -name "*.mobileprovision" \) -print0)
  done < <(profile_search_dirs)

  return 1
}

requested_app_groups_csv() {
  local entitlements_path="$1"

  python3 - "${entitlements_path}" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(0)
with path.open("rb") as fh:
    entitlements = plistlib.load(fh)
groups = [
    str(item).strip()
    for item in (entitlements.get("com.apple.security.application-groups") or [])
    if str(item).strip()
]
print(",".join(groups))
PY
}

load_api_key_env() {
  skybridge_notarytool_maybe_source_local_env || true

  ASC_API_KEY_JSON="${ASC_API_KEY_JSON:-}"
  ASC_KEY_PATH="${ASC_KEY_PATH:-}"
  ASC_KEY_ID="${ASC_KEY_ID:-}"
  ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"

  if [[ -z "${ASC_API_KEY_JSON}" && -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]]; then
    case "${APP_STORE_CONNECT_API_KEY_PATH}" in
      *.json)
        ASC_API_KEY_JSON="${APP_STORE_CONNECT_API_KEY_PATH}"
        ;;
      *)
        ASC_KEY_PATH="${APP_STORE_CONNECT_API_KEY_PATH}"
        ;;
    esac
  fi

  if [[ -z "${ASC_KEY_PATH}" && -n "${NOTARYTOOL_KEY:-}" ]]; then
    ASC_KEY_PATH="${NOTARYTOOL_KEY}"
  fi
  if [[ -z "${ASC_KEY_ID}" && -n "${APP_STORE_CONNECT_API_KEY_ID:-}" ]]; then
    ASC_KEY_ID="${APP_STORE_CONNECT_API_KEY_ID}"
  fi
  if [[ -z "${ASC_KEY_ID}" && -n "${NOTARYTOOL_KEY_ID:-}" ]]; then
    ASC_KEY_ID="${NOTARYTOOL_KEY_ID}"
  fi
  if [[ -z "${ASC_ISSUER_ID}" && -n "${APP_STORE_CONNECT_API_ISSUER_ID:-}" ]]; then
    ASC_ISSUER_ID="${APP_STORE_CONNECT_API_ISSUER_ID}"
  fi
  if [[ -z "${ASC_ISSUER_ID}" && -n "${NOTARYTOOL_ISSUER:-}" ]]; then
    ASC_ISSUER_ID="${NOTARYTOOL_ISSUER}"
  fi

  if [[ -n "${ASC_API_KEY_JSON}" ]]; then
    [[ -f "${ASC_API_KEY_JSON}" ]] || die "APP_STORE_CONNECT_API_KEY_PATH JSON does not exist: ${ASC_API_KEY_JSON}"
    return 0
  fi

  [[ -n "${ASC_KEY_PATH}" && -f "${ASC_KEY_PATH}" ]] \
    || die "Missing App Store Connect API key file. Set ASC_KEY_PATH or NOTARYTOOL_KEY."
  [[ -n "${ASC_KEY_ID}" ]] \
    || die "Missing App Store Connect API key id. Set ASC_KEY_ID or NOTARYTOOL_KEY_ID."
  [[ -n "${ASC_ISSUER_ID}" ]] \
    || die "Missing App Store Connect API issuer id. Set ASC_ISSUER_ID or NOTARYTOOL_ISSUER."
}

create_or_refresh_profile() {
  local bundle_id="$1"
  local entitlements_path="$2"
  local profile_name="$3"
  local app_groups_csv="$4"

  load_api_key_env
  mkdir -p "${HOME}/Library/MobileDevice/Provisioning Profiles"

  GEM_HOME=/opt/homebrew/Cellar/fastlane/2.230.0_1/libexec \
  GEM_PATH=/opt/homebrew/Cellar/fastlane/2.230.0_1/libexec \
  ASC_API_KEY_JSON="${ASC_API_KEY_JSON}" \
  ASC_KEY_PATH="${ASC_KEY_PATH}" \
  ASC_KEY_ID="${ASC_KEY_ID}" \
  ASC_ISSUER_ID="${ASC_ISSUER_ID}" \
  TEAM_ID="${TEAM_ID}" \
  BUNDLE_ID="${bundle_id}" \
  PROFILE_NAME="${profile_name}" \
  CERT_SHA1="${DEVELOPER_ID_SHA1}" \
  OUTPUT_DIR="${HOME}/Library/MobileDevice/Provisioning Profiles" \
  ENABLE_APP_GROUPS="$([[ -n "${app_groups_csv}" ]] && echo 1 || echo 0)" \
  /opt/homebrew/opt/ruby/bin/ruby <<'RUBY'
require 'base64'
require 'digest'
require 'fileutils'
require 'spaceship'

api_json = ENV['ASC_API_KEY_JSON'].to_s
if !api_json.empty?
  Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.from_json_file(api_json)
else
  Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
    key_id: ENV.fetch('ASC_KEY_ID'),
    issuer_id: ENV.fetch('ASC_ISSUER_ID'),
    filepath: ENV.fetch('ASC_KEY_PATH'),
    duration: 1200,
    in_house: false
  )
end

team_id = ENV.fetch('TEAM_ID')
bundle_id = ENV.fetch('BUNDLE_ID')
profile_name = ENV.fetch('PROFILE_NAME')
cert_sha1 = ENV.fetch('CERT_SHA1', '').delete(':').upcase
output_dir = File.expand_path(ENV.fetch('OUTPUT_DIR'))
enable_app_groups = ENV.fetch('ENABLE_APP_GROUPS') == '1'

bundle = Spaceship::ConnectAPI::BundleId.find(bundle_id)
unless bundle
  bundle = Spaceship::ConnectAPI::BundleId.create(
    name: bundle_id,
    platform: Spaceship::ConnectAPI::BundleIdPlatform::MAC_OS,
    identifier: bundle_id,
    seed_id: team_id
  )
  puts "created bundle id #{bundle.identifier}"
end

if enable_app_groups
  type = Spaceship::ConnectAPI::BundleIdCapability::Type::APP_GROUPS
  cap = bundle.get_capabilities.find { |candidate| candidate.is_type?(type) }
  unless cap
    bundle.create_capability(type, settings: [])
    puts "enabled App Groups capability for #{bundle_id}"
  end
end

developer_id_types = [
  Spaceship::ConnectAPI::Certificate::CertificateType::DEVELOPER_ID_APPLICATION,
  Spaceship::ConnectAPI::Certificate::CertificateType::DEVELOPER_ID_APPLICATION_G2
]
certificates = Spaceship::ConnectAPI::Certificate.all.select do |candidate|
  developer_id_types.include?(candidate.certificate_type)
end
certificate = certificates.find do |candidate|
  der = Base64.decode64(candidate.certificate_content.to_s)
  Digest::SHA1.hexdigest(der).upcase == cert_sha1
end
certificate ||= certificates.first
raise 'No Developer ID Application certificate exists in Apple Developer account' unless certificate

Spaceship::ConnectAPI::Profile.all(filter: { name: profile_name }, includes: 'bundleId').each do |profile|
  next unless profile.name == profile_name
  next unless profile.profile_type == Spaceship::ConnectAPI::Profile::ProfileType::MAC_APP_DIRECT
  next unless profile.bundle_id.nil? || profile.bundle_id.identifier == bundle_id
  profile.delete!
  puts "deleted stale profile #{profile.uuid}"
end

profile = Spaceship::ConnectAPI::Profile.create(
  name: profile_name,
  profile_type: Spaceship::ConnectAPI::Profile::ProfileType::MAC_APP_DIRECT,
  bundle_id_id: bundle.id,
  certificate_ids: [certificate.id],
  device_ids: []
)

FileUtils.mkdir_p(output_dir)
path = File.join(output_dir, "#{bundle_id}.provisionprofile")
File.binwrite(path, Base64.decode64(profile.profile_content))
puts "wrote #{path}"
RUBY
}

associate_app_groups_for_bundle() {
  local bundle_id="$1"
  local app_groups_csv="$2"

  [[ -n "${app_groups_csv}" ]] || return 0

  if [[ -z "${DEVELOPER_APPLE_ID}" && -f "${PROJECT_ROOT}/fastlane/Appfile" ]]; then
    DEVELOPER_APPLE_ID="$(sed -n 's/^[[:space:]]*apple_id("\([^"]*\)").*/\1/p' "${PROJECT_ROOT}/fastlane/Appfile" | head -n 1)"
  fi
  [[ -n "${DEVELOPER_APPLE_ID}" ]] || die "Missing Apple ID for Portal App Group association. Pass --apple-id or set FASTLANE_USER."

  GEM_HOME=/opt/homebrew/Cellar/fastlane/2.230.0_1/libexec \
  GEM_PATH=/opt/homebrew/Cellar/fastlane/2.230.0_1/libexec \
  DEVELOPER_APPLE_ID="${DEVELOPER_APPLE_ID}" \
  TEAM_ID="${TEAM_ID}" \
  BUNDLE_ID="${bundle_id}" \
  APP_GROUPS_CSV="${app_groups_csv}" \
  /opt/homebrew/opt/ruby/bin/ruby <<'RUBY'
require 'spaceship'

apple_id = ENV.fetch('DEVELOPER_APPLE_ID')
team_id = ENV.fetch('TEAM_ID')
bundle_id = ENV.fetch('BUNDLE_ID')
required_group_ids = ENV.fetch('APP_GROUPS_CSV').split(',').map(&:strip).reject(&:empty?)

Spaceship::Portal.login(apple_id)
Spaceship::Portal.client.select_team(team_id: team_id)

app = Spaceship::Portal.app.find(bundle_id, mac: true) ||
      Spaceship::Portal.app.find(bundle_id, mac: false)
raise "Missing Developer Portal App ID #{bundle_id}" unless app
app = Spaceship::Portal::App.new(Spaceship::Portal.client.details_for_app(app))

available_groups = Spaceship::Portal.app_group.all
required_groups = required_group_ids.map do |group_id|
  available_groups.find { |candidate| candidate.group_id == group_id } ||
    Spaceship::Portal.app_group.create!(group_id, group_id)
end

existing_groups = app.associated_groups || []
groups_by_id = {}
(existing_groups + required_groups).each { |group| groups_by_id[group.group_id] = group }
Spaceship::Portal.client.associate_groups_with_app(app, groups_by_id.values)

updated = Spaceship::Portal::App.new(Spaceship::Portal.client.details_for_app(app))
final_ids = (updated.associated_groups || []).map(&:group_id)
missing = required_group_ids - final_ids
raise "App Groups not associated: #{missing.join(', ')}" unless missing.empty?

puts "associated App Groups for #{bundle_id}: #{required_group_ids.join(',')}"
RUBY
}

ensure_target_profile() {
  local label="$1"
  local bundle_id="$2"
  local entitlements_path="$3"
  local explicit_path="$4"
  local profile_name="${bundle_id} Direct"
  local found_profile=""
  local app_groups_csv=""

  [[ -f "${entitlements_path}" ]] || die "${label} entitlements file does not exist: ${entitlements_path}"

  if found_profile="$(find_matching_profile "${bundle_id}" "${entitlements_path}" "${explicit_path}")"; then
    log "${label} profile OK: ${found_profile}"
    return 0
  fi

  if [[ "${CREATE_MISSING}" != "1" ]]; then
    die "${label} Developer ID profile is missing or stale for ${bundle_id}. Re-run with --create."
  fi

  app_groups_csv="$(requested_app_groups_csv "${entitlements_path}")"
  log "${label} profile missing or stale; creating ${profile_name}"
  create_or_refresh_profile "${bundle_id}" "${entitlements_path}" "${profile_name}" "${app_groups_csv}"

  if found_profile="$(find_matching_profile "${bundle_id}" "${entitlements_path}" "")"; then
    log "${label} profile OK after create: ${found_profile}"
    return 0
  fi

  if [[ "${ASSOCIATE_APP_GROUPS}" == "1" && -n "${app_groups_csv}" ]]; then
    log "${label} profile still lacks requested App Groups; associating groups in Developer Portal"
    associate_app_groups_for_bundle "${bundle_id}" "${app_groups_csv}"
    create_or_refresh_profile "${bundle_id}" "${entitlements_path}" "${profile_name}" "${app_groups_csv}"
    if found_profile="$(find_matching_profile "${bundle_id}" "${entitlements_path}" "")"; then
      log "${label} profile OK after App Group association: ${found_profile}"
      return 0
    fi
  fi

  if [[ -n "${app_groups_csv}" ]]; then
    die "${label} profile was created but still does not cover App Groups (${app_groups_csv}). Run once with --associate-app-groups to bind the concrete group ids, then rerun DMG packaging."
  fi

  die "${label} profile was created but failed strict validation."
}

ensure_target_profile \
  "macOS app" \
  "${APP_BUNDLE_ID}" \
  "${APP_ENTITLEMENTS}" \
  "${SKYBRIDGE_MACOS_PROVISIONPROFILE_PATH:-}"

ensure_target_profile \
  "Widget Extension" \
  "${WIDGET_BUNDLE_ID}" \
  "${WIDGET_ENTITLEMENTS}" \
  "${SKYBRIDGE_WIDGET_PROVISIONPROFILE_PATH:-}"

log "Developer ID provisioning profiles are ready."
