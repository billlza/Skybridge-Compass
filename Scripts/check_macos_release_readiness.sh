#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Check minimum macOS release readiness for SkyBridge Compass Pro.

Usage:
  check_macos_release_readiness.sh [options]

Options:
  --app-path <path>             App bundle to validate
  --dmg-path <path>             DMG to validate; defaults to dist/SkyBridgeCompassPro-<app-version>.dmg
  --source-info-plist <path>    App source Info.plist to compare product feature flags against
  --source-entitlements <path>  Source packaging entitlements plist
  --widget-path <path>          Widget appex to validate; defaults to <app>/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex
  --widget-source-entitlements <path>
                                Source widget entitlements plist
  --manifest-path <path>        Signed stable update manifest to validate against the app and DMG.
                                Explicit paths are required to exist. Without this option,
                                dist/macos-stable.json is validated only after it has been generated.
  --package-integrity-only      Validate package identity, signing, stapling, and Gatekeeper only
  --skip-launch-smoke           Skip open/launch smoke test
  --skip-cli-quality-gates      Skip Rust CLI coverage, performance, and memory gates
  --skip-performance-gates      Skip real-device performance artifact gates
  --skip-memory-check           Skip leaks scan during launch smoke
  --p2p-remote-artifact-dir <path>
                                Real-device P2P remote smoke artifact for `skybridge check performance`
  --file-transfer-artifact-dir <path>
                                Real-device file-transfer smoke artifact for `skybridge check performance`
  --connectivity-artifact-dir <path>
                                Real-device Mac/iOS connectivity matrix artifact for `skybridge check connectivity`
  --p2p-notice-artifact-dir <path>
                                P2P remote-control security notice artifact for `skybridge check remote-control-notice`
  --webrtc-notice-artifact-dir <path>
                                WebRTC remote-control security notice artifact for `skybridge check remote-control-notice`
  --notice-panel-artifact-dir <path>
                                Production macOS AppKit security notice panel artifact for `skybridge check remote-control-notice --require-panel`
  --coverage-min-percent <n>    Minimum CLI operator check-surface coverage (default: 88)
  --memory-timeout <seconds>    Timeout for `skybridge check memory` leaks scan (default: 60)
  --launch-timeout <seconds>    Seconds to wait for a fresh process to appear (default: 20)
  --steady-state <seconds>      Seconds the launched process must stay alive (default: 5)
  --require-notarization        Fail unless notarization can be confirmed
  -h, --help                    Show this help

Checks:
  - package_app/build_dmg artifacts exist and look structurally valid
  - app bundle executable launches through LaunchServices and stays alive briefly
  - Apple 登录产品开关保持与源 Info.plist 一致，且签名产物的 Apple 登录模式与发布策略一致
  - Widget appex 已嵌入、签名、带 profile，并与主应用共享一致的 App Groups
  - codesign identity, signed entitlements, embedded profiles, and source entitlements stay consistent
  - Gatekeeper/notarization status is surfaced with warnings or failures
  - Mac/iOS connectivity matrix artifacts cover PQC-XWing, PQC, and Classic interop paths
  - Rust CLI operator check-surface coverage is at least 88%
  - P2P and WebRTC remote-control security notice artifacts pass lifecycle and metadata gates
  - Production macOS AppKit security notice panel artifacts prove top-center placement and approval/disconnect actions
  - real-device P2P remote and file-transfer artifacts pass CLI performance gates
  - launched app process passes a CLI memory leak scan
  - release readiness fails if smoke-only trust auto-approval is enabled
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_ROOT}/Scripts/notarytool_helpers.sh"
source "${PROJECT_ROOT}/Scripts/signing_entitlements_helpers.sh"
source "${PROJECT_ROOT}/Scripts/package_build_policy.sh"

validate_core_metal_shader_sources() {
  local core_module_resources_dir="$1"
  local shader_file=""
  local -a shader_files=(
    RemoteDesktopShaders.metal
    RemoteDesktopPassthrough.metal
    RemoteDesktopHDR.metal
    Metal4Shaders.metal
    AuroraShaders.metal
    WeatherParticleShaders.metal
    WeatherShaders.metal
    RainShaders.metal
    HazeShaders.metal
    HazeParticleShaders.metal
  )

  [[ -d "${core_module_resources_dir}" ]] \
    || fail "missing SkyBridgeCore resource directory: ${core_module_resources_dir}"

  for shader_file in "${shader_files[@]}"; do
    [[ -f "${core_module_resources_dir}/${shader_file}" ]] \
      || fail "missing SkyBridgeCore Metal shader source: ${core_module_resources_dir}/${shader_file}"
  done
}

APP_PATH="${PROJECT_ROOT}/dist/SkyBridge Compass Pro.app"
DMG_PATH=""
SOURCE_INFO_PLIST="${PROJECT_ROOT}/Sources/SkyBridgeCompassApp/Info.plist"
SOURCE_ENTITLEMENTS="${PROJECT_ROOT}/Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.packaging.entitlements"
WIDGET_PATH=""
SOURCE_WIDGET_ENTITLEMENTS="${PROJECT_ROOT}/Sources/SkyBridgeCompassWidgets/SkyBridgeCompassWidgetsExtension.entitlements"
MANIFEST_PATH="${PROJECT_ROOT}/dist/macos-stable.json"
MANIFEST_PATH_EXPLICIT=0
REQUIRE_NOTARIZATION="${SKYBRIDGE_RELEASE_GATE_REQUIRE_NOTARIZATION:-0}"
SKIP_LAUNCH_SMOKE=0
SKIP_CLI_QUALITY_GATES=0
SKIP_PERFORMANCE_GATES=0
SKIP_MEMORY_CHECK=0
PACKAGE_INTEGRITY_ONLY=0
P2P_REMOTE_ARTIFACT_DIR="${SKYBRIDGE_RELEASE_GATE_P2P_REMOTE_ARTIFACT_DIR:-}"
FILE_TRANSFER_ARTIFACT_DIR="${SKYBRIDGE_RELEASE_GATE_FILE_TRANSFER_ARTIFACT_DIR:-}"
CONNECTIVITY_ARTIFACT_DIR="${SKYBRIDGE_RELEASE_GATE_CONNECTIVITY_ARTIFACT_DIR:-}"
P2P_NOTICE_ARTIFACT_DIR="${SKYBRIDGE_RELEASE_GATE_P2P_NOTICE_ARTIFACT_DIR:-}"
WEBRTC_NOTICE_ARTIFACT_DIR="${SKYBRIDGE_RELEASE_GATE_WEBRTC_NOTICE_ARTIFACT_DIR:-}"
NOTICE_PANEL_ARTIFACT_DIR="${SKYBRIDGE_RELEASE_GATE_NOTICE_PANEL_ARTIFACT_DIR:-}"
CLI_COVERAGE_MIN_PERCENT="${SKYBRIDGE_RELEASE_GATE_COVERAGE_MIN_PERCENT:-88}"
MEMORY_TIMEOUT_SECONDS="${SKYBRIDGE_RELEASE_GATE_MEMORY_TIMEOUT_SECONDS:-60}"
LAUNCH_TIMEOUT_SECONDS="${SKYBRIDGE_RELEASE_GATE_LAUNCH_TIMEOUT_SECONDS:-20}"
STEADY_STATE_SECONDS="${SKYBRIDGE_RELEASE_GATE_STEADY_STATE_SECONDS:-5}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --dmg-path)
      DMG_PATH="${2:-}"
      shift 2
      ;;
    --source-info-plist)
      SOURCE_INFO_PLIST="${2:-}"
      shift 2
      ;;
    --source-entitlements)
      SOURCE_ENTITLEMENTS="${2:-}"
      shift 2
      ;;
    --widget-path)
      WIDGET_PATH="${2:-}"
      shift 2
      ;;
    --widget-source-entitlements)
      SOURCE_WIDGET_ENTITLEMENTS="${2:-}"
      shift 2
      ;;
    --manifest-path)
      MANIFEST_PATH="${2:-}"
      MANIFEST_PATH_EXPLICIT=1
      shift 2
      ;;
    --package-integrity-only)
      PACKAGE_INTEGRITY_ONLY=1
      shift
      ;;
    --skip-launch-smoke)
      SKIP_LAUNCH_SMOKE=1
      shift
      ;;
    --skip-cli-quality-gates)
      SKIP_CLI_QUALITY_GATES=1
      SKIP_PERFORMANCE_GATES=1
      SKIP_MEMORY_CHECK=1
      shift
      ;;
    --skip-performance-gates)
      SKIP_PERFORMANCE_GATES=1
      shift
      ;;
    --skip-memory-check)
      SKIP_MEMORY_CHECK=1
      shift
      ;;
    --p2p-remote-artifact-dir)
      P2P_REMOTE_ARTIFACT_DIR="${2:-}"
      shift 2
      ;;
    --file-transfer-artifact-dir)
      FILE_TRANSFER_ARTIFACT_DIR="${2:-}"
      shift 2
      ;;
    --connectivity-artifact-dir)
      CONNECTIVITY_ARTIFACT_DIR="${2:-}"
      shift 2
      ;;
    --p2p-notice-artifact-dir)
      P2P_NOTICE_ARTIFACT_DIR="${2:-}"
      shift 2
      ;;
    --webrtc-notice-artifact-dir)
      WEBRTC_NOTICE_ARTIFACT_DIR="${2:-}"
      shift 2
      ;;
    --notice-panel-artifact-dir)
      NOTICE_PANEL_ARTIFACT_DIR="${2:-}"
      shift 2
      ;;
    --coverage-min-percent)
      CLI_COVERAGE_MIN_PERCENT="${2:-}"
      shift 2
      ;;
    --memory-timeout)
      MEMORY_TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --launch-timeout)
      LAUNCH_TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --steady-state)
      STEADY_STATE_SECONDS="${2:-}"
      shift 2
      ;;
    --require-notarization)
      REQUIRE_NOTARIZATION=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[macos-release-readiness] unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! [[ "${LAUNCH_TIMEOUT_SECONDS}" =~ ^[0-9]+$ && "${STEADY_STATE_SECONDS}" =~ ^[0-9]+$ && "${MEMORY_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "[macos-release-readiness] launch timeout, steady-state, and memory timeout must be numeric" >&2
  exit 1
fi

if ! [[ "${CLI_COVERAGE_MIN_PERCENT}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "[macos-release-readiness] coverage minimum must be numeric" >&2
  exit 1
fi

skybridge_assert_no_smoke_auto_approval_for_release_context "macOS release readiness" || exit 1

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-release-readiness.XXXXXX")"
MOUNTED_DMG_DIRS=()

cleanup_tmp() {
  local mounted_dir=""
  for mounted_dir in "${MOUNTED_DMG_DIRS[@]:-}"; do
    [[ -n "${mounted_dir}" ]] || continue
    diskutil eject "${mounted_dir}" >/dev/null 2>&1 || true
  done
  rm -rf "${TMP_DIR}"
}

trap cleanup_tmp EXIT

log_info() {
  echo "[macos-release-readiness] $1"
}

log_warn() {
  echo "[macos-release-readiness] WARNING: $1"
}

log_error() {
  echo "[macos-release-readiness] ERROR: $1" >&2
}

eject_mounted_volume() {
  local mount_dir="$1"
  diskutil eject "${mount_dir}" >/dev/null
}

fail() {
  log_error "$1"
  exit 1
}

validate_release_git_provenance() {
  local git_commit="$1"
  local git_branch="$2"
  local git_dirty_state="$3"
  local artifact_label="$4"

  [[ -n "${git_commit}" && "${git_commit}" != "unknown" ]] \
    || fail "${artifact_label} is missing explicit Git commit provenance; rebuild with Scripts/package_app.sh"
  [[ -n "${git_branch}" && "${git_branch}" != "unknown" ]] \
    || fail "${artifact_label} is missing explicit Git branch provenance; rebuild with Scripts/package_app.sh"
  [[ "${git_dirty_state}" == "clean" ]] \
    || fail "${artifact_label} Git dirty state must be clean for release readiness (actual: ${git_dirty_state:-missing})"
}

run_skybridge_cli() {
  if [[ -n "${SKYBRIDGE_CLI_BIN:-}" ]]; then
    [[ -x "${SKYBRIDGE_CLI_BIN}" ]] || fail "SKYBRIDGE_CLI_BIN is not executable: ${SKYBRIDGE_CLI_BIN}"
    "${SKYBRIDGE_CLI_BIN}" "$@"
    return
  fi

  command -v cargo >/dev/null 2>&1 || fail "cargo is required to run Rust CLI release gates"
  cargo run --quiet --manifest-path "${PROJECT_ROOT}/rust/Cargo.toml" -p skybridge -- "$@"
}

run_cli_coverage_gate() {
  if [[ "${SKIP_CLI_QUALITY_GATES}" == "1" ]]; then
    log_warn "Rust CLI coverage gate was skipped by request"
    return
  fi

  log_info "Running Rust CLI operator check-surface coverage gate (min ${CLI_COVERAGE_MIN_PERCENT}%)"
  run_skybridge_cli check coverage \
    --kind operator-check-surface \
    --min-percent "${CLI_COVERAGE_MIN_PERCENT}"
}

validate_swift_toolchain_baseline() {
  local root_manifest="${PROJECT_ROOT}/Package.swift"
  local ios_manifest="${PROJECT_ROOT}/SkyBridge Compass iOS/Package.swift"
  local verifier="${PROJECT_ROOT}/Scripts/verify_xcode_toolchain.sh"

  [[ -f "${root_manifest}" ]] || fail "missing root SwiftPM manifest: ${root_manifest}"
  [[ -f "${ios_manifest}" ]] || fail "missing iOS SwiftPM manifest: ${ios_manifest}"
  grep -q '^// swift-tools-version: 6\.3$' "${root_manifest}" \
    || fail "root Package.swift must stay on swift-tools-version 6.3"
  grep -q '^// swift-tools-version: 6\.3$' "${ios_manifest}" \
    || fail "iOS Package.swift must stay on swift-tools-version 6.3"

  skybridge_assert_release_stable_toolchain "release_dmg" "${verifier}" "macOS release readiness" \
    || fail "macOS release readiness requires the stable release Xcode toolchain"
}

validate_update_check_configuration() {
  local info_plist="$1"
  local manifest_source="${PROJECT_ROOT}/Sources/SkyBridgeCore/Updates/AppUpdateManifest.swift"
  local checker_source="${PROJECT_ROOT}/Sources/SkyBridgeCompassApp/Services/AppUpdateChecker.swift"
  local manifest_generator="${PROJECT_ROOT}/Scripts/generate_macos_update_manifest.swift"
  local github_publisher="${PROJECT_ROOT}/Scripts/publish_macos_update_release.sh"
  local manifest_validator="${PROJECT_ROOT}/Scripts/validate_macos_update_manifest.sh"
  local manifest_url=""
  local signing_keys=""

  manifest_url="$(plist_read_value "${info_plist}" "SKYBRIDGE_UPDATE_MANIFEST_URL" 2>/dev/null || true)"
  signing_keys="$(plist_read_value "${info_plist}" "SKYBRIDGE_UPDATE_MANIFEST_ED25519_PUBLIC_KEYS" 2>/dev/null || true)"

  [[ -n "${manifest_url}" ]] || fail "app Info.plist is missing SKYBRIDGE_UPDATE_MANIFEST_URL"
  [[ "${manifest_url}" == https://github.com/billlza/Skybridge-Compass/releases/download/* ]] \
    || fail "release update manifest must be a GitHub Releases HTTPS asset, actual: ${manifest_url}"
  [[ -n "${signing_keys}" ]] || fail "app Info.plist is missing trusted update manifest Ed25519 public keys"
  [[ "${signing_keys}" == *":"* ]] \
    || fail "SKYBRIDGE_UPDATE_MANIFEST_ED25519_PUBLIC_KEYS must use key-id:base64-public-key entries"
  if [[ "${signing_keys}" =~ (PRIVATE|private|BEGIN|END) ]]; then
    fail "update manifest signing configuration must contain public keys only"
  fi
  grep -q '"published_at"' "${manifest_source}" \
    || fail "update manifest must bind published_at into the signed anti-replay payload"
  grep -q '"expires_at"' "${manifest_source}" \
    || fail "update manifest must bind expires_at into the signed anti-replay payload"
  grep -q '"sequence"' "${manifest_source}" \
    || fail "update manifest must bind sequence into the signed anti-replay payload"
  grep -q 'manifestSequenceRollback' "${manifest_source}" \
    || fail "update manifest evaluator must reject signed manifest sequence rollback"
  grep -q 'recordAcceptedSequence(decision.manifest.sequence)' "${checker_source}" \
    || fail "update checker must persist the highest accepted signed manifest sequence"
  [[ -f "${manifest_generator}" ]] \
    || fail "missing signed macOS update manifest generator: ${manifest_generator}"
  grep -q 'SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64' "${manifest_generator}" \
    || fail "manifest generator must read the Ed25519 private key from file or secret environment only"
  grep -q 'appendSignedField("published_at"' "${manifest_generator}" \
    || fail "manifest generator must sign published_at with the same canonical payload as the app evaluator"
  grep -q 'appendSignedField("expires_at"' "${manifest_generator}" \
    || fail "manifest generator must sign expires_at with the same canonical payload as the app evaluator"
  grep -q 'appendSignedField("sequence"' "${manifest_generator}" \
    || fail "manifest generator must sign sequence with the same canonical payload as the app evaluator"
  grep -q 'manifest generation requires --notarized' "${manifest_generator}" \
    || fail "manifest generator must refuse to advertise unnotarized packages"
  [[ -f "${github_publisher}" ]] \
    || fail "missing GitHub release update publisher: ${github_publisher}"
  [[ -f "${manifest_validator}" ]] \
    || fail "missing macOS update manifest validator: ${manifest_validator}"
  grep -q 'macos-stable.json' "${github_publisher}" \
    || fail "GitHub update publisher must upload the stable manifest asset name expected by the app"
  grep -q 'validate_macos_update_manifest.sh' "${github_publisher}" \
    || fail "GitHub update publisher must validate generated and downloaded stable manifests against the exact app and DMG"
  grep -q 'gh release upload' "${github_publisher}" \
    || fail "GitHub update publisher must upload DMG and manifest assets through GitHub Releases"
  grep -q 'gh release download' "${github_publisher}" \
    || fail "GitHub update publisher must download uploaded release assets for post-upload verification"
  grep -q 'xcrun stapler validate' "${github_publisher}" \
    || fail "GitHub update publisher must verify notarization/stapling before advertising a DMG update"
  grep -Fq "https://github.com/\${REPOSITORY}/releases/download/\${TAG_NAME}" "${github_publisher}" \
    || fail "GitHub update publisher must build a download URL matching GitHub Releases asset URLs"
}

validate_local_update_manifest() {
  local manifest_path="$1"
  local app_path="$2"
  local dmg_path="$3"
  local manifest_validator="${PROJECT_ROOT}/Scripts/validate_macos_update_manifest.sh"

  [[ -n "${manifest_path}" ]] || fail "missing --manifest-path for stable update manifest validation"
  [[ -f "${manifest_path}" ]] || fail "missing stable update manifest: ${manifest_path}"
  [[ -x "${manifest_validator}" || -f "${manifest_validator}" ]] \
    || fail "missing macOS update manifest validator: ${manifest_validator}"

  log_info "Validating signed stable update manifest against app and DMG"
  bash "${manifest_validator}" \
    --manifest-path "${manifest_path}" \
    --app-path "${app_path}" \
    --dmg-path "${dmg_path}" \
    --require-apple-pqc-sdk-build \
    || fail "stable update manifest does not advertise the exact release app and DMG"
}

run_cli_connectivity_gate() {
  if [[ "${SKIP_CLI_QUALITY_GATES}" == "1" ]]; then
    log_warn "Rust CLI connectivity gate was skipped by request"
    return
  fi

  [[ -n "${CONNECTIVITY_ARTIFACT_DIR}" ]] \
    || fail "missing --connectivity-artifact-dir for release connectivity gate"
  [[ -d "${CONNECTIVITY_ARTIFACT_DIR}" ]] \
    || fail "connectivity artifact dir does not exist: ${CONNECTIVITY_ARTIFACT_DIR}"

  log_info "Running Rust CLI Mac/iOS connectivity matrix gate"
  run_skybridge_cli check connectivity \
    --artifact-dir "${CONNECTIVITY_ARTIFACT_DIR}"
}

run_cli_performance_gates() {
  if [[ "${SKIP_CLI_QUALITY_GATES}" == "1" || "${SKIP_PERFORMANCE_GATES}" == "1" ]]; then
    log_warn "Rust CLI performance gates were skipped by request"
    return
  fi

  [[ -n "${P2P_REMOTE_ARTIFACT_DIR}" ]] \
    || fail "missing --p2p-remote-artifact-dir for release performance gate"
  [[ -d "${P2P_REMOTE_ARTIFACT_DIR}" ]] \
    || fail "P2P remote artifact dir does not exist: ${P2P_REMOTE_ARTIFACT_DIR}"
  [[ -n "${FILE_TRANSFER_ARTIFACT_DIR}" ]] \
    || fail "missing --file-transfer-artifact-dir for release performance gate"
  [[ -d "${FILE_TRANSFER_ARTIFACT_DIR}" ]] \
    || fail "file-transfer artifact dir does not exist: ${FILE_TRANSFER_ARTIFACT_DIR}"

  log_info "Running Rust CLI P2P remote performance gate"
  run_skybridge_cli check performance \
    --kind p2p-remote \
    --artifact-dir "${P2P_REMOTE_ARTIFACT_DIR}" \
    --min-fps 59 \
    --require-audio true \
    --strict-fps-floor true

  log_info "Running Rust CLI file-transfer performance gate"
  run_skybridge_cli check performance \
    --kind file-transfer \
    --artifact-dir "${FILE_TRANSFER_ARTIFACT_DIR}"
}

run_cli_remote_control_notice_gates() {
  if [[ "${SKIP_CLI_QUALITY_GATES}" == "1" ]]; then
    log_warn "Rust CLI remote-control security notice gates were skipped by request"
    return
  fi

  [[ -n "${P2P_NOTICE_ARTIFACT_DIR}" ]] \
    || fail "missing --p2p-notice-artifact-dir for remote-control security notice gate"
  [[ -d "${P2P_NOTICE_ARTIFACT_DIR}" ]] \
    || fail "P2P remote-control notice artifact dir does not exist: ${P2P_NOTICE_ARTIFACT_DIR}"
  [[ -n "${WEBRTC_NOTICE_ARTIFACT_DIR}" ]] \
    || fail "missing --webrtc-notice-artifact-dir for remote-control security notice gate"
  [[ -d "${WEBRTC_NOTICE_ARTIFACT_DIR}" ]] \
    || fail "WebRTC remote-control notice artifact dir does not exist: ${WEBRTC_NOTICE_ARTIFACT_DIR}"
  [[ -n "${NOTICE_PANEL_ARTIFACT_DIR}" ]] \
    || fail "missing --notice-panel-artifact-dir for remote-control security notice panel gate"
  [[ -d "${NOTICE_PANEL_ARTIFACT_DIR}" ]] \
    || fail "remote-control notice panel artifact dir does not exist: ${NOTICE_PANEL_ARTIFACT_DIR}"

  log_info "Running Rust CLI P2P remote-control security notice gate"
  run_skybridge_cli check remote-control-notice \
    --artifact-dir "${P2P_NOTICE_ARTIFACT_DIR}" \
    --transport p2p

  log_info "Running Rust CLI WebRTC remote-control security notice gate"
  run_skybridge_cli check remote-control-notice \
    --artifact-dir "${WEBRTC_NOTICE_ARTIFACT_DIR}" \
    --transport webrtc

  log_info "Running Rust CLI production AppKit remote-control security notice panel gate"
  run_skybridge_cli check remote-control-notice \
    --artifact-dir "${NOTICE_PANEL_ARTIFACT_DIR}" \
    --transport webrtc \
    --require-panel
}

run_cli_memory_check_for_pid() {
  local pid="$1"

  if [[ "${SKIP_CLI_QUALITY_GATES}" == "1" || "${SKIP_MEMORY_CHECK}" == "1" ]]; then
    log_warn "Rust CLI memory leak scan was skipped by request"
    return
  fi

  log_info "Running Rust CLI memory leak scan for pid=${pid}"
  run_skybridge_cli check memory \
    --pid "${pid}" \
    --timeout-seconds "${MEMORY_TIMEOUT_SECONDS}"
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

with plist_path.open("rb") as fh:
    value = plistlib.load(fh)

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

executable_rpaths() {
  local executable_path="$1"
  otool -l "${executable_path}" 2>/dev/null | awk '
    /cmd LC_RPATH/ { in_rpath = 1; next }
    in_rpath && /path / { print $2; in_rpath = 0 }
  '
}

is_external_toolchain_rpath() {
  local rpath="$1"
  case "${rpath}" in
    /Applications/Xcode*.app/Contents/Developer/Toolchains/*/usr/lib/swift*|\
    /var/run/com.apple.security.cryptexd/*)
      return 0
      ;;
  esac
  return 1
}

validate_release_rpaths() {
  local executable_path="$1"
  local rpath=""
  local forbidden=()

  while IFS= read -r rpath; do
    [[ -n "${rpath}" ]] || continue
    if is_external_toolchain_rpath "${rpath}"; then
      forbidden+=("${rpath}")
    fi
  done < <(executable_rpaths "${executable_path}")

  if (( ${#forbidden[@]} > 0 )); then
    fail "release app executable must not retain external Xcode beta/cryptex toolchain rpaths: ${forbidden[*]}"
  fi
}

validate_release_binary_provenance_strings() {
  local executable_path="$1"
  local context="${2:-release executable}"
  local leaked_user_path=""

  leaked_user_path="$(
    strings -a "${executable_path}" \
      | grep -E '/Users/[^[:space:]]+' \
      | grep -Ev '^/Users/runner/work/rust/rust/' \
      | head -n 1 \
      || true
  )"

  if [[ -n "${leaked_user_path}" ]]; then
    fail "${context} leaks a non-toolchain local user path: $(skybridge_sanitize_log_value "${leaked_user_path}")"
  fi
}

is_macho_binary_file() {
  local file_path="$1"
  [[ -f "${file_path}" ]] || return 1
  file -b "${file_path}" 2>/dev/null | grep -Eq 'Mach-O'
}

release_app_binary_candidates() {
  local app_path="$1"
  local root=""
  local roots=(
    "${app_path}/Contents/MacOS"
    "${app_path}/Contents/Frameworks"
    "${app_path}/Contents/PlugIns"
    "${app_path}/Contents/Library"
    "${app_path}/Contents/XPCServices"
  )

  for root in "${roots[@]}"; do
    [[ -d "${root}" ]] || continue
    find "${root}" -type f -print 2>/dev/null
  done
}

validate_release_app_binary_provenance_strings() {
  local app_path="$1"
  local binary_path=""
  local relative_path=""
  local scanned_count=0

  while IFS= read -r binary_path; do
    [[ -n "${binary_path}" ]] || continue
    if ! is_macho_binary_file "${binary_path}"; then
      continue
    fi
    scanned_count=$((scanned_count + 1))
    relative_path="${binary_path#"${app_path}/"}"
    validate_release_binary_provenance_strings "${binary_path}" "release app binary ${relative_path}"
  done < <(release_app_binary_candidates "${app_path}" | sort -u)

  if (( scanned_count == 0 )); then
    fail "release app bundle contains no Mach-O binaries to scan for local path provenance"
  fi

  log_info "Release binary provenance string gate scanned ${scanned_count} Mach-O binaries"
}

extract_helper_version() {
  local bin_path="$1"
  if [[ -x "${bin_path}" ]]; then
    strings "${bin_path}" 2>/dev/null | grep -m1 'SKYBRIDGE_HELPER_VERSION=' | cut -d= -f2 || true
  fi
}

extract_source_helper_version() {
  local source_path="${PROJECT_ROOT}/Sources/PowerMetricsHelper/main.swift"
  if [[ -f "${source_path}" ]]; then
    awk -F '"' '/private static let helperVersion =/ { print $2; exit }' "${source_path}" 2>/dev/null || true
  fi
}

resolve_default_dmg_path() {
  local app_info_plist="$1"
  local version=""
  local candidate=""

  version="$(plist_read_value "${app_info_plist}" "CFBundleShortVersionString" 2>/dev/null || true)"
  if [[ -n "${version}" ]]; then
    candidate="${PROJECT_ROOT}/dist/SkyBridgeCompassPro-${version}.dmg"
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi

  candidate="$(find "${PROJECT_ROOT}/dist" -maxdepth 1 -type f -name 'SkyBridgeCompassPro-*.dmg' -print | sort | tail -n 1 || true)"
  printf '%s\n' "${candidate}"
}

attach_dmg_readonly() {
  local dmg_path="$1"
  local attach_plist="${TMP_DIR}/dmg-attach.plist"

  diskutil image attach --readOnly --mountOptions nobrowse --plist "${dmg_path}" >"${attach_plist}" \
    || fail "could not mount DMG for content validation: ${dmg_path}"

  python3 - "${attach_plist}" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)

for entity in info.get("system-entities", []):
    mount_point = entity.get("mount-point")
    if mount_point:
        print(mount_point)
        raise SystemExit(0)

raise SystemExit(1)
PY
}

codesign_cdhash() {
  local target_path="$1"
  codesign --display --verbose=4 "${target_path}" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1
}

validate_dmg_embedded_app() {
  local dmg_path="$1"
  local expected_app_path="$2"
  local expected_bundle_id="$3"
  local expected_version="$4"
  local expected_build="$5"
  local expected_team_id="$6"
  local expected_cdhash="$7"
  local mount_dir=""
  local dmg_app_path=""
  local dmg_info_plist=""
  local dmg_metadata=""
  local dmg_team_id=""
  local dmg_bundle_id=""
  local dmg_version=""
  local dmg_build=""
  local dmg_build_source=""
  local dmg_build_scheme=""
  local dmg_build_configuration=""
  local dmg_git_commit=""
  local dmg_git_branch=""
  local dmg_git_dirty_state=""
  local expected_git_commit=""
  local expected_git_branch=""
  local expected_git_dirty_state=""
  local dmg_cdhash=""

  log_info "Mounting DMG and validating embedded app bundle"
  mount_dir="$(attach_dmg_readonly "${dmg_path}")"
  [[ -n "${mount_dir}" && -d "${mount_dir}" ]] || fail "DMG mounted without a readable mount point"
  MOUNTED_DMG_DIRS+=("${mount_dir}")

  dmg_app_path="$(find "${mount_dir}" -maxdepth 1 -type d -name '*.app' -print | sort | head -n 1)"
  [[ -n "${dmg_app_path}" ]] || fail "DMG does not contain a top-level .app bundle"
  [[ "$(basename "${dmg_app_path}")" == "$(basename "${expected_app_path}")" ]] \
    || fail "DMG app bundle name does not match dist app: $(basename "${dmg_app_path}")"

  dmg_info_plist="${dmg_app_path}/Contents/Info.plist"
  [[ -f "${dmg_info_plist}" ]] || fail "DMG app is missing Info.plist: ${dmg_info_plist}"

  dmg_bundle_id="$(plist_read_value "${dmg_info_plist}" "CFBundleIdentifier" 2>/dev/null || true)"
  dmg_version="$(plist_read_value "${dmg_info_plist}" "CFBundleShortVersionString" 2>/dev/null || true)"
  dmg_build="$(plist_read_value "${dmg_info_plist}" "CFBundleVersion" 2>/dev/null || true)"
  dmg_build_source="$(plist_read_value "${dmg_info_plist}" "SkyBridgePackagingBuildSource" 2>/dev/null || true)"
  dmg_build_scheme="$(plist_read_value "${dmg_info_plist}" "SkyBridgePackagingBuildScheme" 2>/dev/null || true)"
  dmg_build_configuration="$(plist_read_value "${dmg_info_plist}" "SkyBridgePackagingBuildConfiguration" 2>/dev/null || true)"
  dmg_git_commit="$(plist_read_value "${dmg_info_plist}" "SkyBridgePackagingGitCommit" 2>/dev/null || true)"
  dmg_git_branch="$(plist_read_value "${dmg_info_plist}" "SkyBridgePackagingGitBranch" 2>/dev/null || true)"
  dmg_git_dirty_state="$(plist_read_value "${dmg_info_plist}" "SkyBridgePackagingGitDirtyState" 2>/dev/null || true)"
  expected_git_commit="$(plist_read_value "${expected_app_path}/Contents/Info.plist" "SkyBridgePackagingGitCommit" 2>/dev/null || true)"
  expected_git_branch="$(plist_read_value "${expected_app_path}/Contents/Info.plist" "SkyBridgePackagingGitBranch" 2>/dev/null || true)"
  expected_git_dirty_state="$(plist_read_value "${expected_app_path}/Contents/Info.plist" "SkyBridgePackagingGitDirtyState" 2>/dev/null || true)"

  [[ "${dmg_bundle_id}" == "${expected_bundle_id}" ]] \
    || fail "DMG app bundle identifier (${dmg_bundle_id}) does not match dist app (${expected_bundle_id})"
  [[ "${dmg_version}" == "${expected_version}" ]] \
    || fail "DMG app version (${dmg_version}) does not match dist app (${expected_version})"
  [[ "${dmg_build}" == "${expected_build}" ]] \
    || fail "DMG app build (${dmg_build}) does not match dist app (${expected_build})"
  case "${dmg_build_source}" in
    xcode_release|swiftpm_release)
      ;;
    *)
      fail "DMG app was not packaged from an explicit Release product (actual: ${dmg_build_source:-missing})"
      ;;
  esac
  [[ "${dmg_build_scheme}" == "SkyBridgeCompassApp" ]] \
    || fail "DMG app build scheme drifted (actual: ${dmg_build_scheme:-missing})"
  [[ "${dmg_build_configuration}" == "Release" ]] \
    || fail "DMG app build configuration drifted (actual: ${dmg_build_configuration:-missing})"
  [[ -n "${dmg_git_commit}" && "${dmg_git_commit}" == "${expected_git_commit}" ]] \
    || fail "DMG app Git commit (${dmg_git_commit:-missing}) does not match dist app (${expected_git_commit:-missing})"
  [[ -n "${dmg_git_branch}" && "${dmg_git_branch}" == "${expected_git_branch}" ]] \
    || fail "DMG app Git branch (${dmg_git_branch:-missing}) does not match dist app (${expected_git_branch:-missing})"
  [[ -n "${dmg_git_dirty_state}" && "${dmg_git_dirty_state}" == "${expected_git_dirty_state}" ]] \
    || fail "DMG app Git dirty state (${dmg_git_dirty_state:-missing}) does not match dist app (${expected_git_dirty_state:-missing})"
  validate_release_git_provenance "${dmg_git_commit}" "${dmg_git_branch}" "${dmg_git_dirty_state}" "DMG app"
  skybridge_assert_bundle_has_apple_pqc_compile_marker "${dmg_app_path}" "DMG embedded app bundle" \
    || fail "DMG embedded app is missing the Apple PQC SDK compile marker"

  dmg_metadata="$(codesign --display --verbose=4 "${dmg_app_path}" 2>&1)" \
    || fail "could not read DMG app codesign metadata"
  dmg_team_id="$(printf '%s\n' "${dmg_metadata}" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  [[ "${dmg_team_id}" == "${expected_team_id}" ]] \
    || fail "DMG app TeamIdentifier (${dmg_team_id}) does not match dist app (${expected_team_id})"
  [[ "${dmg_metadata}" == *"Authority=Developer ID Application:"* ]] \
    || fail "DMG app is not signed with a Developer ID Application identity"

  dmg_cdhash="$(printf '%s\n' "${dmg_metadata}" | sed -n 's/^CDHash=//p' | head -n 1)"
  [[ -n "${dmg_cdhash}" && "${dmg_cdhash}" == "${expected_cdhash}" ]] \
    || fail "DMG app CDHash (${dmg_cdhash:-missing}) does not match dist app (${expected_cdhash:-missing})"

  codesign --verify --deep --strict --verbose=2 "${dmg_app_path}" >/dev/null
  validate_macho_minimum_macos_version_floor "${dmg_app_path}" \
    || fail "DMG embedded app contains Mach-O binaries that cannot prove macOS 14.0 compatibility"
  [[ -f "${dmg_app_path}/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex/Contents/embedded.provisionprofile" ]] \
    || fail "DMG app widget appex is missing embedded.provisionprofile"

  compare_required_privacy_usage_descriptions "${expected_app_path}/Contents/Info.plist" "${dmg_info_plist}" "DMG app Info.plist" \
    || fail "DMG app Info.plist privacy usage descriptions drifted from dist app"

  eject_mounted_volume "${mount_dir}"
}

pid_in_list() {
  local target_pid="$1"
  local pid_list="$2"
  local existing_pid=""

  for existing_pid in ${pid_list}; do
    if [[ "${existing_pid}" == "${target_pid}" ]]; then
      return 0
    fi
  done

  return 1
}

collect_named_pids() {
  local executable_name="$1"
  pgrep -x "${executable_name}" 2>/dev/null || true
}

redact_release_log_excerpt() {
  python3 - <<'PY'
import os
import re
import sys

text = sys.stdin.read()
home = os.environ.get("HOME")
if home:
    text = text.replace(home, "<home>")
patterns = [
    (r"\bAuthorization:\s*Bearer\s+\S+", "Authorization: Bearer <redacted>"),
    (r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]*)?\b", "<redacted-jwt>"),
    (
        r"\b(?:access[-_]?token|refresh[-_]?token|bearer[-_]?token|api[-_]?key|anon[-_]?key|connection[-_]?code|code|tenant[-_]?id|user[-_]?id|device[-_]?id)="
        r"(?!<redacted\b|<redacted>)[^\s&]+",
        lambda match: match.group(0).split("=", 1)[0] + "=<redacted>",
    ),
    (r"\b(?:ws|wss|https?)://[^\s\"']+", "<redacted-url>"),
    (r"(?<![A-Za-z0-9])(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?", "<redacted-ip>"),
    (r"(^|[\s\"=])/(?:Users|private/var|var/folders|tmp)/[^\s\"']+", r"\1<redacted-path>"),
]
for pattern, replacement in patterns:
    text = re.sub(pattern, replacement, text, flags=re.IGNORECASE)
print(text, end="")
PY
}

capture_recent_logs() {
  local process_name="$1"
  if ! command -v log >/dev/null 2>&1; then
    return 0
  fi

  log show --style compact --last 2m --predicate "process == \"${process_name}\"" 2>/dev/null \
    | tail -n 20 \
    | redact_release_log_excerpt \
    || true
}

compare_plists() {
  local expected_path="$1"
  local actual_path="$2"
  local label="$3"

  python3 - "${expected_path}" "${actual_path}" "${label}" <<'PY'
import plistlib
import sys

expected_path, actual_path, label = sys.argv[1:]

with open(expected_path, "rb") as fh:
    expected = plistlib.load(fh)
with open(actual_path, "rb") as fh:
    actual = plistlib.load(fh)

if expected != actual:
    print(f"{label} mismatch", file=sys.stderr)
    print(f"expected={expected}", file=sys.stderr)
    print(f"actual={actual}", file=sys.stderr)
    raise SystemExit(1)
PY
}

compare_product_feature_flag_preservation() {
  local source_info_plist="$1"
  local actual_info_plist="$2"

  python3 - "${source_info_plist}" "${actual_info_plist}" <<'PY'
import plistlib
import sys

source_path, actual_path = sys.argv[1:]

with open(source_path, "rb") as fh:
    source = plistlib.load(fh)
with open(actual_path, "rb") as fh:
    actual = plistlib.load(fh)

expected_value = source.get("SKYBRIDGE_ENABLE_APPLE_SIGN_IN")
actual_value = actual.get("SKYBRIDGE_ENABLE_APPLE_SIGN_IN")

if expected_value != actual_value:
    print(
        "SKYBRIDGE_ENABLE_APPLE_SIGN_IN product flag mismatch: "
        f"expected={expected_value} actual={actual_value}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

compare_native_flag_alignment() {
  local expected_info_plist="$1"
  local actual_info_plist="$2"

  python3 - "${expected_info_plist}" "${actual_info_plist}" <<'PY'
import plistlib
import sys

expected_path, actual_path = sys.argv[1:]

with open(expected_path, "rb") as fh:
    expected = plistlib.load(fh)
with open(actual_path, "rb") as fh:
    actual = plistlib.load(fh)

expected_value = expected.get("SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN")
actual_value = actual.get("SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN")

if expected_value != actual_value:
    print(
        "SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN mismatch: "
        f"expected={expected_value} actual={actual_value}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

compare_apple_sign_in_mode_alignment() {
  local expected_info_plist="$1"
  local actual_info_plist="$2"

  python3 - "${expected_info_plist}" "${actual_info_plist}" <<'PY'
import plistlib
import sys

expected_path, actual_path = sys.argv[1:]

with open(expected_path, "rb") as fh:
    expected = plistlib.load(fh)
with open(actual_path, "rb") as fh:
    actual = plistlib.load(fh)

expected_value = expected.get("SKYBRIDGE_APPLE_SIGN_IN_MODE")
actual_value = actual.get("SKYBRIDGE_APPLE_SIGN_IN_MODE")

if expected_value != actual_value:
    print(
        "SKYBRIDGE_APPLE_SIGN_IN_MODE mismatch: "
        f"expected={expected_value} actual={actual_value}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

extract_embedded_info_plist() {
  local executable_path="$1"
  local output_path="$2"

  python3 - "${executable_path}" "${output_path}" <<'PY'
import plistlib
import re
import subprocess
import sys
from pathlib import Path

executable_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])

proc = subprocess.run(
    ["otool", "-X", "-s", "__TEXT", "__info_plist", str(executable_path)],
    check=False,
    capture_output=True,
    text=True,
)
if proc.returncode != 0:
    raise SystemExit(2)

hex_bytes = bytearray()
for line in proc.stdout.splitlines():
    parts = line.split()
    if len(parts) < 2:
        continue
    for word in parts[1:]:
        if not re.fullmatch(r"[0-9a-fA-F]{2,8}", word) or len(word) % 2 != 0:
            continue
        raw = bytes.fromhex(word)
        if len(raw) == 4:
            # otool prints full 32-bit words in target byte order; reverse each
            # word to reconstruct the section bytes.
            hex_bytes.extend(raw[::-1])
        else:
            # The final partial word is printed as byte-sized chunks on newer
            # Xcode toolchains; keep those bytes in display order.
            hex_bytes.extend(raw)

payload = bytes(hex_bytes).rstrip(b"\x00")
if not payload:
    raise SystemExit(2)

start = payload.find(b"<?xml")
if start == -1:
    start = payload.find(b"<plist")
if start > 0:
    payload = payload[start:]

try:
    plistlib.loads(payload)
except Exception as exc:
    print(f"embedded __TEXT,__info_plist is not a valid plist: {exc}", file=sys.stderr)
    raise SystemExit(1)

output_path.write_bytes(payload)
PY
}

compare_required_privacy_usage_descriptions() {
  local expected_info_plist="$1"
  local actual_info_plist="$2"
  local label="$3"

  python3 - "${expected_info_plist}" "${actual_info_plist}" "${label}" <<'PY'
import plistlib
import sys

expected_path, actual_path, label = sys.argv[1:]

required_keys = [
    "NSBluetoothAlwaysUsageDescription",
    "NSLocalNetworkUsageDescription",
    "NSCameraUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSAudioCaptureUsageDescription",
    "NSLocationUsageDescription",
    "NSLocationWhenInUseUsageDescription",
    "NSUSBUsageDescription",
]

with open(expected_path, "rb") as fh:
    expected = plistlib.load(fh)
with open(actual_path, "rb") as fh:
    actual = plistlib.load(fh)

for key in required_keys:
    expected_value = expected.get(key)
    actual_value = actual.get(key)
    if not isinstance(actual_value, str) or not actual_value.strip():
        print(f"{label} missing required privacy usage description: {key}", file=sys.stderr)
        raise SystemExit(1)
    if expected_value != actual_value:
        print(
            f"{label} privacy usage description mismatch for {key}: "
            f"expected={expected_value!r} actual={actual_value!r}",
            file=sys.stderr,
        )
        raise SystemExit(1)
PY
}

validate_icns_contains_full_size_reps() {
  local icns_path="$1"
  local label="$2"
  local tmp_dir
  local iconset_dir

  if ! command -v iconutil >/dev/null 2>&1; then
    echo "iconutil is required to validate ${label} icon representations" >&2
    return 1
  fi

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-icns-check.XXXXXX")"
  iconset_dir="${tmp_dir}/${label}.iconset"
  if ! iconutil -c iconset "${icns_path}" -o "${iconset_dir}" >/dev/null 2>&1; then
    rm -rf "${tmp_dir}"
    echo "${label} is not a valid icns file: ${icns_path}" >&2
    return 1
  fi

  if [[ ! -f "${iconset_dir}/icon_512x512.png" || ! -f "${iconset_dir}/icon_512x512@2x.png" ]]; then
    rm -rf "${tmp_dir}"
    echo "${label} must include full-size 512x512 and 1024x1024 icon representations" >&2
    return 1
  fi

  rm -rf "${tmp_dir}"
}

validate_packaged_app_does_not_override_system_icon() {
  local app_source="${PROJECT_ROOT}/Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift"
  local icon_loader_source="${PROJECT_ROOT}/Sources/SkyBridgeCompassApp/SVGEmbeddedImageView.swift"
  local icon_function
  local brand_loader

  [[ -f "${app_source}" ]] || {
    echo "missing app source for runtime icon ownership validation: ${app_source}" >&2
    return 1
  }
  [[ -f "${icon_loader_source}" ]] || {
    echo "missing brand icon source for runtime icon ownership validation: ${icon_loader_source}" >&2
    return 1
  }

  icon_function="$(
    python3 - "${app_source}" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start_marker = "private static func applyAppIconIfAvailable() -> Bool"
end_marker = "func resolveDevelopmentIconURL() -> URL?"
start = source.find(start_marker)
end = source.find(end_marker, start)
if start == -1 or end == -1:
    raise SystemExit(2)
print(source[start:end])
PY
  )" || {
    echo "could not locate applyAppIconIfAvailable packaged icon path" >&2
    return 1
  }

  if [[ "${icon_function}" != *"if isRunningFromPackagedApp"* ]]; then
    echo "packaged app icon must return before debug raw-icon fallback; Info.plist + LaunchServices must own it" >&2
    return 1
  fi
  if [[ "${icon_function}" == *"NSApplication.shared.applicationIconImage ="* ]]; then
    echo "packaged app startup must not overwrite applicationIconImage from raw PNG/ICNS resources" >&2
    return 1
  fi
  if grep -q "resolvePackagedIconURL" "${app_source}"; then
    echo "packaged app must not resolve raw AppIcon PNG/ICNS for the Dock icon" >&2
    return 1
  fi

  brand_loader="$(
    python3 - "${icon_loader_source}" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start_marker = "private enum BrandIconAssetLoader"
end_marker = "private extension View"
start = source.find(start_marker)
end = source.find(end_marker, start)
if start == -1 or end == -1:
    raise SystemExit(2)
print(source[start:end])
PY
  )" || {
    echo "could not locate BrandIconAssetLoader" >&2
    return 1
  }

  if [[ "${brand_loader}" != *"loadImageResource(named: preferredResourceName, withExtension: \"png\", bundle: .main)"* ]]; then
    echo "packaged brand icon must first read the requested main-bundle resource so the sidebar can use SidebarBrandIcon.png" >&2
    return 1
  fi
  if [[ "${brand_loader}" != *"loadImageResource(named: \"BrandIcon\", withExtension: \"png\", bundle: .main)"* ]]; then
    echo "packaged brand icon must read bundled BrandIcon.png so in-app branding does not drift through AppIcon.icns representation selection" >&2
    return 1
  fi
  if [[ "${brand_loader}" == *"packagedResourceIconURLs"* || "${brand_loader}" == *"NSApplication.shared.applicationIconImage"* ]]; then
    echo "packaged brand icon must not use legacy resource lists or cached system icons; BrandIcon.png is the runtime brand truth" >&2
    return 1
  fi
}

validate_modern_app_icon_contract() {
  local info_plist="$1"
  local resources_dir="$2"
  local source_resources_dir="${PROJECT_ROOT}/Sources/SkyBridgeCompassApp/Resources"

  local icon_file
  local icon_name
  local canonical_png_hash
  local iconcomposer_png_hash
  local source_icns_hash
  local packaged_icns_hash
  local packaged_brand_hash
  local source_sidebar_brand_hash
  local packaged_sidebar_brand_hash
  icon_file="$(plist_read_value "${info_plist}" "CFBundleIconFile" 2>/dev/null || true)"
  icon_name="$(plist_read_value "${info_plist}" "CFBundleIconName" 2>/dev/null || true)"

  if [[ "${icon_file}" != "AppIcon.icns" ]]; then
    echo "app Info.plist CFBundleIconFile must point to precomposed AppIcon.icns (actual: ${icon_file:-missing})" >&2
    return 1
  fi

  if [[ -n "${icon_name}" ]]; then
    echo "app Info.plist CFBundleIconName must be absent so Icon Composer iconstack cannot wrap the precomposed icon (actual: ${icon_name})" >&2
    return 1
  fi

  if [[ ! -f "${resources_dir}/AppIcon.icns" || ! -f "${resources_dir}/BrandIcon.png" || ! -f "${resources_dir}/SidebarBrandIcon.png" ]]; then
    echo "app bundle is missing precomposed AppIcon.icns, runtime BrandIcon.png, or runtime SidebarBrandIcon.png resources" >&2
    return 1
  fi

  validate_icns_contains_full_size_reps "${resources_dir}/AppIcon.icns" "AppIcon.icns" || return 1
  validate_packaged_app_does_not_override_system_icon || return 1

  if [[ ! -f "${source_resources_dir}/AppIcon.png" || ! -f "${source_resources_dir}/AppIcon.icon/Assets/Image.png" || ! -f "${source_resources_dir}/AppIcon.icns" || ! -f "${source_resources_dir}/SidebarBrandIcon.png" ]]; then
    echo "source resources are missing AppIcon.png, AppIcon.icon/Assets/Image.png, AppIcon.icns, or SidebarBrandIcon.png; icon sources cannot be proven canonical" >&2
    return 1
  fi
  canonical_png_hash="$(shasum -a 256 "${source_resources_dir}/AppIcon.png" | awk '{print $1}')"
  iconcomposer_png_hash="$(shasum -a 256 "${source_resources_dir}/AppIcon.icon/Assets/Image.png" | awk '{print $1}')"
  source_icns_hash="$(shasum -a 256 "${source_resources_dir}/AppIcon.icns" | awk '{print $1}')"
  packaged_icns_hash="$(shasum -a 256 "${resources_dir}/AppIcon.icns" | awk '{print $1}')"
  packaged_brand_hash="$(shasum -a 256 "${resources_dir}/BrandIcon.png" | awk '{print $1}')"
  source_sidebar_brand_hash="$(shasum -a 256 "${source_resources_dir}/SidebarBrandIcon.png" | awk '{print $1}')"
  packaged_sidebar_brand_hash="$(shasum -a 256 "${resources_dir}/SidebarBrandIcon.png" | awk '{print $1}')"
  if [[ "${canonical_png_hash}" != "${iconcomposer_png_hash}" ]]; then
    echo "Icon Composer AppIcon.icon/Assets/Image.png must match canonical AppIcon.png; otherwise development assets can drift" >&2
    echo "AppIcon.png=${canonical_png_hash} IconComposerImage=${iconcomposer_png_hash}" >&2
    return 1
  fi
  if [[ "${source_icns_hash}" != "${packaged_icns_hash}" ]]; then
    echo "packaged AppIcon.icns must match the source AppIcon.icns derived from canonical AppIcon.png" >&2
    echo "source=${source_icns_hash} packaged=${packaged_icns_hash}" >&2
    return 1
  fi
  if [[ "${canonical_png_hash}" != "${packaged_brand_hash}" ]]; then
    echo "packaged BrandIcon.png must match canonical AppIcon.png for in-app branding" >&2
    echo "AppIcon.png=${canonical_png_hash} BrandIcon=${packaged_brand_hash}" >&2
    return 1
  fi
  if [[ "${source_sidebar_brand_hash}" != "${packaged_sidebar_brand_hash}" ]]; then
    echo "packaged SidebarBrandIcon.png must match the source small-size brand icon resource" >&2
    echo "source=${source_sidebar_brand_hash} packaged=${packaged_sidebar_brand_hash}" >&2
    return 1
  fi
  if [[ "${canonical_png_hash}" == "${source_sidebar_brand_hash}" ]]; then
    echo "SidebarBrandIcon.png must be a small-size optimized derivative, not a duplicate of canonical AppIcon.png" >&2
    return 1
  fi

  if [[ -e "${resources_dir}/icon.json" || -e "${resources_dir}/Image.png" || -e "${resources_dir}/AppIcon.icon" || -e "${resources_dir}/Assets.xcassets" || -e "${resources_dir}/AppIcon.png" || -e "${resources_dir}/AppIconDock.icns" || -e "${resources_dir}/AppIconDock.png" || -e "${resources_dir}/app_icon.png" || -e "${resources_dir}/AppIconMaster.png" || -e "${resources_dir}/AppIconMaster.svg" || -e "${resources_dir}/app-icon.svg" || -e "${resources_dir}/Icons" ]]; then
    echo "app bundle still contains Icon Composer inputs or legacy icon aliases; release icon source is ambiguous" >&2
    return 1
  fi
}

validate_macos_platform_metadata() {
  local info_plist="$1"
  local executable_path="$2"

  skybridge_assert_release_app_stable_platform_metadata "${info_plist}" "release readiness app" || return 1

  local platform=""
  platform="$(otool -l "${executable_path}" 2>/dev/null | awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_build = 1; next }
    in_build && $1 == "platform" { print $2; exit }
  ')"
  [[ "${platform}" == "1" ]] || {
    echo "main executable LC_BUILD_VERSION platform must be 1 (macOS), got ${platform:-missing}" >&2
    return 1
  }
}

validate_macho_minimum_macos_version_floor() {
  local app_path="$1"
  local output=""

  if ! output="$(env -u SKYBRIDGE_FILE_TOOL -u SKYBRIDGE_OTOOL_TOOL bash "${PROJECT_ROOT}/Scripts/check_macos_deps.sh" --strict "${app_path}" "14.0" 2>&1)"; then
    printf '%s\n' "${output}" >&2
    return 1
  fi

  log_info "Mach-O minimum macOS version gate passed for ${app_path}"
}

compare_app_group_alignment() {
  local app_entitlements_path="$1"
  local widget_entitlements_path="$2"

  python3 - "${app_entitlements_path}" "${widget_entitlements_path}" <<'PY'
import plistlib
import sys

app_path, widget_path = sys.argv[1:]

with open(app_path, "rb") as fh:
    app_entitlements = plistlib.load(fh)
with open(widget_path, "rb") as fh:
    widget_entitlements = plistlib.load(fh)

app_groups = {
    str(item).strip()
    for item in (app_entitlements.get("com.apple.security.application-groups") or [])
    if str(item).strip()
}
widget_groups = {
    str(item).strip()
    for item in (widget_entitlements.get("com.apple.security.application-groups") or [])
    if str(item).strip()
}

if not widget_groups:
    print("widget extension is missing com.apple.security.application-groups", file=sys.stderr)
    raise SystemExit(1)

if not widget_groups.issubset(app_groups):
    print(
        "widget extension requested App Groups that are absent from the signed host app: "
        f"widget={sorted(widget_groups)} app={sorted(app_groups)}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

assess_gatekeeper_target() {
  local target_path="$1"
  local target_type="$2"
  local label="$3"
  local output=""

  output="$(skybridge_assess_gatekeeper "${target_path}" "${target_type}" 2>&1 || true)"

  if skybridge_gatekeeper_is_notarized "${output}"; then
    log_info "${label} Gatekeeper assessment: notarized"
    return 0
  fi

  if skybridge_gatekeeper_is_unnotarized_developer_id "${output}"; then
    if [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
      fail "${label} is signed but still unnotarized: ${output//$'\n'/ | }"
    fi
    log_warn "${label} is signed but not notarized yet: ${output//$'\n'/ | }"
    return 0
  fi

  if skybridge_gatekeeper_is_accepted "${output}"; then
    if stapled_notarization_ticket_is_valid "${target_path}"; then
      log_info "${label} Gatekeeper assessment lacked notarization context, but stapler validation confirmed a stapled ticket"
      return 0
    fi

    if [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
      fail "${label} was accepted by Gatekeeper but notarization could not be confirmed: ${output//$'\n'/ | }"
    fi
    log_warn "${label} was accepted by Gatekeeper but notarization could not be confirmed: ${output//$'\n'/ | }"
    return 0
  fi

  if [[ -n "${output}" ]]; then
    fail "${label} Gatekeeper assessment failed: ${output//$'\n'/ | }"
  fi

  fail "${label} Gatekeeper assessment returned no output"
}

stapled_notarization_ticket_is_valid() {
  local target_path="$1"
  xcrun stapler validate "${target_path}" >/dev/null 2>&1
}

smoke_launch_app() {
  local app_path="$1"
  local executable_name="$2"
  local before_pids=""
  local new_pid=""
  local open_output=""
  local pid=""
  local logs=""
  local deadline=0
  local quit_deadline=0

  before_pids="$(collect_named_pids "${executable_name}" | tr '\n' ' ')"

  if ! open_output="$(open -Fn -g "${app_path}" 2>&1)"; then
    fail "failed to open app bundle: ${open_output}"
  fi

  deadline=$((SECONDS + LAUNCH_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] || continue
      if ! pid_in_list "${pid}" "${before_pids}"; then
        new_pid="${pid}"
        break 2
      fi
    done < <(collect_named_pids "${executable_name}")
    sleep 1
  done

  if [[ -z "${new_pid}" ]]; then
    fail "app launch smoke did not observe a fresh ${executable_name} process within ${LAUNCH_TIMEOUT_SECONDS}s"
  fi

  log_info "App launch smoke observed pid=${new_pid}; waiting ${STEADY_STATE_SECONDS}s for crash-free startup"
  sleep "${STEADY_STATE_SECONDS}"

  if ! kill -0 "${new_pid}" 2>/dev/null; then
    logs="$(capture_recent_logs "${executable_name}")"
    fail "app process exited during smoke window.${logs:+ Recent logs: ${logs//$'\n'/ | }}"
  fi

  run_cli_memory_check_for_pid "${new_pid}"

  if ! kill -0 "${new_pid}" 2>/dev/null; then
    logs="$(capture_recent_logs "${executable_name}")"
    fail "app process exited during memory leak scan.${logs:+ Recent logs: ${logs//$'\n'/ | }}"
  fi

  kill -TERM "${new_pid}" >/dev/null 2>&1 || true
  quit_deadline=$((SECONDS + 10))
  while kill -0 "${new_pid}" 2>/dev/null; do
    if (( SECONDS >= quit_deadline )); then
      kill -KILL "${new_pid}" >/dev/null 2>&1 || true
      break
    fi
    sleep 1
  done

  log_info "App launch smoke passed"
}

if [[ ! -d "${APP_PATH}" ]]; then
  fail "missing app bundle: ${APP_PATH}. Run Scripts/package_app.sh or Scripts/build_dmg.sh first."
fi

APP_INFO_PLIST="${APP_PATH}/Contents/Info.plist"
APP_PROFILE_PATH="${APP_PATH}/Contents/embedded.provisionprofile"
APP_RESOURCES_DIR="${APP_PATH}/Contents/Resources"
APP_FRAMEWORKS_DIR="${APP_PATH}/Contents/Frameworks"

[[ -f "${APP_INFO_PLIST}" ]] || fail "missing app Info.plist: ${APP_INFO_PLIST}"
[[ -f "${SOURCE_INFO_PLIST}" ]] || fail "missing source Info.plist: ${SOURCE_INFO_PLIST}"
[[ -f "${SOURCE_ENTITLEMENTS}" ]] || fail "missing source entitlements: ${SOURCE_ENTITLEMENTS}"

APP_EXECUTABLE_NAME="$(plist_read_value "${APP_INFO_PLIST}" "CFBundleExecutable" 2>/dev/null || true)"
APP_BUNDLE_IDENTIFIER="$(plist_read_value "${APP_INFO_PLIST}" "CFBundleIdentifier" 2>/dev/null || true)"
APP_VERSION="$(plist_read_value "${APP_INFO_PLIST}" "CFBundleShortVersionString" 2>/dev/null || true)"
APP_BUILD="$(plist_read_value "${APP_INFO_PLIST}" "CFBundleVersion" 2>/dev/null || true)"
APP_BUILD_SOURCE="$(plist_read_value "${APP_INFO_PLIST}" "SkyBridgePackagingBuildSource" 2>/dev/null || true)"
APP_BUILD_SCHEME="$(plist_read_value "${APP_INFO_PLIST}" "SkyBridgePackagingBuildScheme" 2>/dev/null || true)"
APP_BUILD_CONFIGURATION="$(plist_read_value "${APP_INFO_PLIST}" "SkyBridgePackagingBuildConfiguration" 2>/dev/null || true)"
APP_GIT_COMMIT="$(plist_read_value "${APP_INFO_PLIST}" "SkyBridgePackagingGitCommit" 2>/dev/null || true)"
APP_GIT_BRANCH="$(plist_read_value "${APP_INFO_PLIST}" "SkyBridgePackagingGitBranch" 2>/dev/null || true)"
APP_GIT_DIRTY_STATE="$(plist_read_value "${APP_INFO_PLIST}" "SkyBridgePackagingGitDirtyState" 2>/dev/null || true)"
APP_EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${APP_EXECUTABLE_NAME}"
APP_HELPER_PLIST_PATH="${APP_PATH}/Contents/Library/LaunchDaemons/com.skybridge.PowerMetricsHelper.plist"
APP_HELPER_BIN_PATH="${APP_PATH}/Contents/Library/LaunchDaemons/com.skybridge.PowerMetricsHelper/com.skybridge.PowerMetricsHelper"
if [[ -z "${WIDGET_PATH}" ]]; then
  WIDGET_PATH="${APP_PATH}/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex"
fi

[[ -n "${APP_EXECUTABLE_NAME}" ]] || fail "app Info.plist is missing CFBundleExecutable"
[[ -n "${APP_BUNDLE_IDENTIFIER}" ]] || fail "app Info.plist is missing CFBundleIdentifier"
[[ -x "${APP_EXECUTABLE_PATH}" ]] || fail "main executable is missing or not executable: ${APP_EXECUTABLE_PATH}"
validate_release_rpaths "${APP_EXECUTABLE_PATH}"
validate_release_app_binary_provenance_strings "${APP_PATH}"
if otool -L "${APP_EXECUTABLE_PATH}" 2>/dev/null | grep -q "@rpath/WebRTC.framework/WebRTC"; then
  [[ -e "${APP_FRAMEWORKS_DIR}/WebRTC.framework/WebRTC" ]] || fail "main executable links WebRTC.framework, but the app bundle is missing WebRTC.framework"
  if ! otool -l "${APP_EXECUTABLE_PATH}" 2>/dev/null | grep -q "@executable_path/../Frameworks"; then
    fail "main executable links WebRTC.framework but is missing @executable_path/../Frameworks rpath"
  fi
fi
[[ -d "${APP_RESOURCES_DIR}/SkyBridgeCompassApp_SkyBridgeCompassApp.bundle" ]] \
  || fail "missing SkyBridgeCompassApp_SkyBridgeCompassApp.bundle; Bundle.module app resources were not packaged"
APP_MODULE_RESOURCES_DIR="${APP_RESOURCES_DIR}/SkyBridgeCompassApp_SkyBridgeCompassApp.bundle/Contents/Resources"
CORE_MODULE_RESOURCES_DIR="${APP_RESOURCES_DIR}/SkyBridgeCompassApp_SkyBridgeCore.bundle/Contents/Resources"
[[ -f "${APP_MODULE_RESOURCES_DIR}/Assets.car" ]] \
  || fail "missing compiled App Assets.car inside SkyBridgeCompassApp_SkyBridgeCompassApp.bundle; asset catalogs were not packaged as a release resource bundle"
[[ -f "${APP_MODULE_RESOURCES_DIR}/default.metallib" ]] \
  || fail "missing compiled App default.metallib inside SkyBridgeCompassApp_SkyBridgeCompassApp.bundle; Metal shaders were not packaged as a release resource bundle"
validate_core_metal_shader_sources "${CORE_MODULE_RESOURCES_DIR}"
[[ -f "${APP_HELPER_PLIST_PATH}" ]] || fail "missing PowerMetricsHelper launchd plist: ${APP_HELPER_PLIST_PATH}"
[[ -x "${APP_HELPER_BIN_PATH}" ]] || fail "PowerMetricsHelper binary is missing or not executable: ${APP_HELPER_BIN_PATH}"
APP_HELPER_VERSION="$(extract_helper_version "${APP_HELPER_BIN_PATH}")"
[[ -n "${APP_HELPER_VERSION}" ]] || fail "PowerMetricsHelper version marker is missing; refusing version unknown helper"
SOURCE_HELPER_VERSION="$(extract_source_helper_version)"
if [[ -n "${SOURCE_HELPER_VERSION}" && "${APP_HELPER_VERSION}" != "${SOURCE_HELPER_VERSION}" ]]; then
  fail "PowerMetricsHelper version drift: app bundle has ${APP_HELPER_VERSION}, source declares ${SOURCE_HELPER_VERSION}"
fi
[[ -f "${SOURCE_WIDGET_ENTITLEMENTS}" ]] || fail "missing widget source entitlements: ${SOURCE_WIDGET_ENTITLEMENTS}"

case "${APP_BUILD_SOURCE}" in
  xcode_release|swiftpm_release)
    ;;
  *)
    fail "app bundle was not packaged from an explicit Release product (actual: ${APP_BUILD_SOURCE:-missing})"
    ;;
esac
[[ "${APP_BUILD_SCHEME}" == "SkyBridgeCompassApp" ]] \
  || fail "app bundle build scheme drifted from release packaging policy (actual: ${APP_BUILD_SCHEME:-missing})"
[[ "${APP_BUILD_CONFIGURATION}" == "Release" ]] \
  || fail "app bundle build configuration is not Release (actual: ${APP_BUILD_CONFIGURATION:-missing})"
[[ -n "${APP_GIT_COMMIT}" ]] \
  || fail "app bundle is missing SkyBridgePackagingGitCommit; rebuild with Scripts/package_app.sh"
[[ -n "${APP_GIT_BRANCH}" ]] \
  || fail "app bundle is missing SkyBridgePackagingGitBranch; rebuild with Scripts/package_app.sh"
validate_release_git_provenance "${APP_GIT_COMMIT}" "${APP_GIT_BRANCH}" "${APP_GIT_DIRTY_STATE}" "app bundle"

if [[ -z "${DMG_PATH}" ]]; then
  DMG_PATH="$(resolve_default_dmg_path "${APP_INFO_PLIST}")"
fi

[[ -n "${DMG_PATH}" ]] || fail "could not resolve DMG path under dist/"
[[ -f "${DMG_PATH}" ]] || fail "missing DMG artifact: ${DMG_PATH}. Run Scripts/build_dmg.sh first."

if ! hdiutil imageinfo "${DMG_PATH}" >/dev/null 2>&1; then
  fail "DMG is present but hdiutil could not read it: ${DMG_PATH}"
fi

if [[ -n "${APP_VERSION}" && "$(basename "${DMG_PATH}")" != *"${APP_VERSION}.dmg" ]]; then
  fail "DMG filename does not include app version ${APP_VERSION}: $(basename "${DMG_PATH}")"
fi

DMG_SIGNED_METADATA="$(codesign --display --verbose=2 "${DMG_PATH}" 2>&1)" \
  || fail "DMG is not codesigned with a Developer ID Application identity: ${DMG_PATH}"

if [[ "${DMG_SIGNED_METADATA}" != *"Authority=Developer ID Application:"* ]]; then
  fail "DMG is not signed with a Developer ID Application identity"
fi

SIGNED_METADATA="$(codesign --display --verbose=2 "${APP_PATH}" 2>&1)"
SIGNED_TEAM_IDENTIFIER="$(printf '%s\n' "${SIGNED_METADATA}" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
[[ -n "${SIGNED_TEAM_IDENTIFIER}" ]] || fail "could not read TeamIdentifier from codesign metadata"

if [[ "${SIGNED_METADATA}" != *"Authority=Developer ID Application:"* ]]; then
  fail "release bundle is not signed with a Developer ID Application identity"
fi

DMG_TEAM_IDENTIFIER="$(printf '%s\n' "${DMG_SIGNED_METADATA}" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
if [[ -n "${DMG_TEAM_IDENTIFIER}" && "${DMG_TEAM_IDENTIFIER}" != "${SIGNED_TEAM_IDENTIFIER}" ]]; then
  fail "DMG TeamIdentifier (${DMG_TEAM_IDENTIFIER}) does not match app TeamIdentifier (${SIGNED_TEAM_IDENTIFIER})"
fi

log_info "Verifying codesign integrity"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >/dev/null
codesign --verify --verbose=2 "${DMG_PATH}" >/dev/null
log_info "Verifying PowerMetricsHelper codesign integrity (version ${APP_HELPER_VERSION})"
codesign --verify --strict --verbose=2 "${APP_HELPER_BIN_PATH}" >/dev/null
skybridge_assert_bundle_has_apple_pqc_compile_marker "${APP_PATH}" "release app bundle" \
  || fail "release app bundle is missing the Apple PQC SDK compile marker"

APP_CDHASH="$(codesign_cdhash "${APP_PATH}")"
[[ -n "${APP_CDHASH}" ]] || fail "could not read app CDHash from codesign metadata"
validate_dmg_embedded_app \
  "${DMG_PATH}" \
  "${APP_PATH}" \
  "${APP_BUNDLE_IDENTIFIER}" \
  "${APP_VERSION}" \
  "${APP_BUILD}" \
  "${SIGNED_TEAM_IDENTIFIER}" \
  "${APP_CDHASH}"

SIGNED_ENTITLEMENTS_PATH="${TMP_DIR}/signed-entitlements.plist"
EXPECTED_ENTITLEMENTS_PATH="${TMP_DIR}/expected-entitlements.plist"
EXPECTED_INFO_PLIST="${TMP_DIR}/expected-info.plist"
EMBEDDED_APP_INFO_PLIST="${TMP_DIR}/embedded-app-info.plist"
WIDGET_INFO_PLIST="${WIDGET_PATH}/Contents/Info.plist"
WIDGET_PROFILE_PATH="${WIDGET_PATH}/Contents/embedded.provisionprofile"
SIGNED_WIDGET_ENTITLEMENTS_PATH="${TMP_DIR}/signed-widget-entitlements.plist"
EXPECTED_WIDGET_ENTITLEMENTS_PATH="${TMP_DIR}/expected-widget-entitlements.plist"

skybridge_write_signed_entitlements "${APP_PATH}" "${SIGNED_ENTITLEMENTS_PATH}" \
  || fail "could not extract signed entitlements from ${APP_PATH}"

if [[ -f "${APP_PROFILE_PATH}" ]]; then
  log_info "Validating embedded provisioning profile against bundle identity"
  skybridge_validate_provisionprofile_app_identity \
    "${APP_PROFILE_PATH}" \
    "${APP_BUNDLE_IDENTIFIER}" \
    "${SIGNED_TEAM_IDENTIFIER}" \
    || fail "embedded provisioning profile does not match the signed app identity"

  if ! skybridge_profile_supports_requested_restricted_entitlements "${APP_PROFILE_PATH}" "${SIGNED_ENTITLEMENTS_PATH}"; then
    fail "embedded provisioning profile does not cover the signed App Groups entitlements"
  fi
else
  if skybridge_entitlements_request_application_groups "${SIGNED_ENTITLEMENTS_PATH}"; then
    fail "signed app still requests profile-backed entitlements but no embedded provisioning profile is present"
  fi
fi

cp "${SOURCE_INFO_PLIST}" "${EXPECTED_INFO_PLIST}"
skybridge_prepare_signing_entitlements \
  "${SOURCE_ENTITLEMENTS}" \
  "${EXPECTED_ENTITLEMENTS_PATH}" \
  "${EXPECTED_INFO_PLIST}" \
  "${APP_PROFILE_PATH:-}" \
  >/dev/null

compare_plists "${EXPECTED_ENTITLEMENTS_PATH}" "${SIGNED_ENTITLEMENTS_PATH}" "signed entitlements" \
  || fail "signed entitlements drifted from the expected packaging entitlements"

compare_product_feature_flag_preservation "${SOURCE_INFO_PLIST}" "${APP_INFO_PLIST}" \
  || fail "app Info.plist changed SKYBRIDGE_ENABLE_APPLE_SIGN_IN instead of preserving the product feature flag"

compare_native_flag_alignment "${EXPECTED_INFO_PLIST}" "${APP_INFO_PLIST}" \
  || fail "app Info.plist SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN drifted from the effective signed entitlements"

compare_apple_sign_in_mode_alignment "${EXPECTED_INFO_PLIST}" "${APP_INFO_PLIST}" \
  || fail "app Info.plist SKYBRIDGE_APPLE_SIGN_IN_MODE drifted from the effective signed entitlements"

compare_required_privacy_usage_descriptions "${SOURCE_INFO_PLIST}" "${APP_INFO_PLIST}" "app Info.plist" \
  || fail "app Info.plist privacy usage descriptions drifted from the source Info.plist"

validate_swift_toolchain_baseline
validate_update_check_configuration "${APP_INFO_PLIST}"
if [[ "${MANIFEST_PATH_EXPLICIT}" == "1" ]]; then
  validate_local_update_manifest "${MANIFEST_PATH}" "${APP_PATH}" "${DMG_PATH}"
elif [[ -f "${MANIFEST_PATH}" ]]; then
  validate_local_update_manifest "${MANIFEST_PATH}" "${APP_PATH}" "${DMG_PATH}"
else
  log_info "Stable update manifest not present at ${MANIFEST_PATH}; deferring exact manifest validation to Scripts/publish_macos_update_release.sh"
fi

validate_modern_app_icon_contract "${APP_INFO_PLIST}" "${APP_RESOURCES_DIR}" \
  || fail "app icon contract drifted from the precomposed AppIcon.icns release path"

validate_macos_platform_metadata "${APP_INFO_PLIST}" "${APP_EXECUTABLE_PATH}" \
  || fail "app bundle macOS platform metadata is invalid"
validate_macho_minimum_macos_version_floor "${APP_PATH}" \
  || fail "app bundle contains Mach-O binaries that cannot prove macOS 14.0 compatibility"

if extract_embedded_info_plist "${APP_EXECUTABLE_PATH}" "${EMBEDDED_APP_INFO_PLIST}"; then
  compare_required_privacy_usage_descriptions "${APP_INFO_PLIST}" "${EMBEDDED_APP_INFO_PLIST}" "main executable embedded Info.plist" \
    || fail "main executable embedded Info.plist privacy usage descriptions drifted from the app bundle Info.plist"
else
  embedded_info_status=$?
  if [[ "${embedded_info_status}" -eq 2 ]]; then
    log_info "main executable has no __TEXT,__info_plist section; using App Bundle Info.plist for native Xcode app target privacy validation"
  else
    fail "main executable embedded __TEXT,__info_plist section is invalid"
  fi
fi

APP_FEATURE_APPLE_SIGN_IN="$(plist_read_value "${APP_INFO_PLIST}" "SKYBRIDGE_ENABLE_APPLE_SIGN_IN" 2>/dev/null || true)"
APP_NATIVE_APPLE_SIGN_IN="$(plist_read_value "${APP_INFO_PLIST}" "SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN" 2>/dev/null || true)"
APP_APPLE_SIGN_IN_MODE="$(plist_read_value "${APP_INFO_PLIST}" "SKYBRIDGE_APPLE_SIGN_IN_MODE" 2>/dev/null || true)"

if [[ "${SKYBRIDGE_REQUIRE_APPLE_SIGN_IN:-0}" == "1" && "${APP_FEATURE_APPLE_SIGN_IN}" == "true" && "${APP_NATIVE_APPLE_SIGN_IN}" != "true" ]]; then
  fail "Apple 登录产品功能已开启，但签名产物未启用原生 Apple Sign In"
fi

if [[ "${APP_FEATURE_APPLE_SIGN_IN}" == "true" && "${APP_APPLE_SIGN_IN_MODE}" != "web_session" ]]; then
  fail "Developer ID DMG 发布要求 Apple 登录采用 web_session，当前模式为：${APP_APPLE_SIGN_IN_MODE:-missing}"
fi

[[ -d "${WIDGET_PATH}" ]] || fail "missing widget appex: ${WIDGET_PATH}"
[[ -f "${WIDGET_INFO_PLIST}" ]] || fail "missing widget Info.plist: ${WIDGET_INFO_PLIST}"

WIDGET_BUNDLE_IDENTIFIER="$(plist_read_value "${WIDGET_INFO_PLIST}" "CFBundleIdentifier" 2>/dev/null || true)"
[[ -n "${WIDGET_BUNDLE_IDENTIFIER}" ]] || fail "widget Info.plist is missing CFBundleIdentifier"

WIDGET_SIGNED_METADATA="$(codesign --display --verbose=2 "${WIDGET_PATH}" 2>&1)"
if [[ "${WIDGET_SIGNED_METADATA}" != *"Authority=Developer ID Application:"* ]]; then
  fail "widget appex is not signed with a Developer ID Application identity"
fi

log_info "Verifying widget appex codesign integrity"
codesign --verify --strict --verbose=2 "${WIDGET_PATH}" >/dev/null

skybridge_write_signed_entitlements "${WIDGET_PATH}" "${SIGNED_WIDGET_ENTITLEMENTS_PATH}" \
  || fail "could not extract signed entitlements from ${WIDGET_PATH}"

cp "${SOURCE_WIDGET_ENTITLEMENTS}" "${EXPECTED_WIDGET_ENTITLEMENTS_PATH}"
compare_plists "${EXPECTED_WIDGET_ENTITLEMENTS_PATH}" "${SIGNED_WIDGET_ENTITLEMENTS_PATH}" "widget signed entitlements" \
  || fail "widget signed entitlements drifted from the expected widget entitlements"

compare_app_group_alignment "${SIGNED_ENTITLEMENTS_PATH}" "${SIGNED_WIDGET_ENTITLEMENTS_PATH}" \
  || fail "widget App Groups are not aligned with the signed host app entitlements"

[[ -f "${WIDGET_PROFILE_PATH}" ]] || fail "widget appex is missing embedded.provisionprofile"
skybridge_validate_provisionprofile_app_identity \
  "${WIDGET_PROFILE_PATH}" \
  "${WIDGET_BUNDLE_IDENTIFIER}" \
  "${SIGNED_TEAM_IDENTIFIER}" \
  || fail "widget embedded provisioning profile does not match the signed appex identity"

if ! skybridge_profile_supports_requested_profile_backed_entitlements \
  "${WIDGET_PROFILE_PATH}" \
  "${SIGNED_WIDGET_ENTITLEMENTS_PATH}"; then
  fail "widget embedded provisioning profile does not cover the signed App Groups entitlement"
fi

assess_gatekeeper_target "${APP_PATH}" "execute" "App Bundle"
assess_gatekeeper_target "${DMG_PATH}" "open" "DMG"

if [[ "${PACKAGE_INTEGRITY_ONLY}" == "1" ]]; then
  log_warn "Package integrity-only validation complete; full_release_readiness=false release_proof=false skipped_gates=cli,connectivity,remote-control-notice,performance,launch,memory"
  exit 0
fi

run_cli_coverage_gate
run_cli_connectivity_gate
run_cli_remote_control_notice_gates
run_cli_performance_gates

if [[ "${SKIP_LAUNCH_SMOKE}" == "1" ]]; then
  if [[ "${SKIP_CLI_QUALITY_GATES}" != "1" && "${SKIP_MEMORY_CHECK}" != "1" ]]; then
    fail "launch smoke cannot be skipped while the memory leak scan gate is enabled"
  fi
  log_warn "launch smoke was skipped by request; full_release_readiness=false until a non-skipped launch/memory lane passes"
else
  smoke_launch_app "${APP_PATH}" "${APP_EXECUTABLE_NAME}"
fi

log_info "PowerMetricsHelper app bundle version: ${APP_HELPER_VERSION}"
INSTALLED_HELPER_BIN="/Library/PrivilegedHelperTools/com.skybridge.PowerMetricsHelper"
if [[ -x "${INSTALLED_HELPER_BIN}" ]]; then
  INSTALLED_HELPER_VERSION="$(extract_helper_version "${INSTALLED_HELPER_BIN}")"
  log_info "PowerMetricsHelper installed version: ${INSTALLED_HELPER_VERSION:-unknown}"
fi
RUNNING_INFO="$(launchctl print system/com.skybridge.PowerMetricsHelper 2>/dev/null || true)"
RUNNING_PATH="$(echo "${RUNNING_INFO}" | awk -F'= ' '/path =/{print $2; exit}')"
if [[ -n "${RUNNING_PATH}" ]]; then
  RUNNING_VERSION="$(extract_helper_version "${RUNNING_PATH}")"
  log_info "PowerMetricsHelper running version: ${RUNNING_VERSION:-unknown}"
fi

if [[ "${SKIP_CLI_QUALITY_GATES}" == "1" || "${SKIP_PERFORMANCE_GATES}" == "1" || "${SKIP_MEMORY_CHECK}" == "1" || "${SKIP_LAUNCH_SMOKE}" == "1" ]]; then
  log_warn "macOS release readiness completed with explicit skips; full_release_readiness=false release_proof=false"
else
  log_info "full macOS release readiness checks passed"
fi
