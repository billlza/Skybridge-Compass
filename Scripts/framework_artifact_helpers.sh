#!/usr/bin/env bash

# ${BASH_SOURCE[0]:-$0} keeps this sourceable from both bash and zsh
# (package_app.sh is zsh); zsh resolves $0 to the sourced file path.
_skybridge_framework_helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_skybridge_native_dependency_lock="${_skybridge_framework_helpers_dir}/../Config/native-dependencies.lock.json"
if ! SKYBRIDGE_WEBRTC_M150_MACOS_BINARY_SHA256="$(
  python3 - "${_skybridge_native_dependency_lock}" <<'PY'
import json
import pathlib
import sys

record = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
value = record["families"]["webrtc"]["binaries"]["macos-arm64-x86_64"]
if not isinstance(value, str) or len(value) != 64:
    raise SystemExit("invalid WebRTC macOS SHA-256 in native dependency lock")
print(value)
PY
)"; then
  echo "failed to load the approved WebRTC hash from ${_skybridge_native_dependency_lock}" >&2
  return 1 2>/dev/null || exit 1
fi

skybridge_framework_binary_path() {
  local framework_dir="${1:-}"
  local framework_name="${2:-}"

  [[ -n "${framework_dir}" && -n "${framework_name}" && -d "${framework_dir}" ]] || return 1

  if [[ -e "${framework_dir}/${framework_name}" ]]; then
    printf '%s\n' "${framework_dir}/${framework_name}"
    return 0
  fi
  if [[ -e "${framework_dir}/Versions/A/${framework_name}" ]]; then
    printf '%s\n' "${framework_dir}/Versions/A/${framework_name}"
    return 0
  fi
  if [[ -e "${framework_dir}/Versions/Current/${framework_name}" ]]; then
    printf '%s\n' "${framework_dir}/Versions/Current/${framework_name}"
    return 0
  fi

  return 1
}

skybridge_framework_binary_exists() {
  skybridge_framework_binary_path "$@" >/dev/null
}

skybridge_assert_webrtc_m150_framework() {
  local framework_dir="${1:-}"
  local binary_path=""
  local canonical_binary=""
  local actual_sha256=""

  binary_path="$(skybridge_framework_binary_path "${framework_dir}" "WebRTC")" || {
    echo "WebRTC M150 gate: framework binary is missing: ${framework_dir}" >&2
    return 1
  }
  canonical_binary="$(python3 - "${framework_dir}" "${binary_path}" <<'PY'
import pathlib
import sys

framework = pathlib.Path(sys.argv[1]).resolve(strict=True)
binary = pathlib.Path(sys.argv[2]).resolve(strict=True)
try:
    binary.relative_to(framework)
except ValueError:
    raise SystemExit(1)
if not binary.is_file():
    raise SystemExit(1)
print(binary)
PY
)" || {
    echo "WebRTC M150 gate: framework binary escapes its bundle or is not regular" >&2
    return 1
  }
  actual_sha256="$(shasum -a 256 "${canonical_binary}" | awk '{print $1}')" || return 1
  if [[ "${actual_sha256}" != "${SKYBRIDGE_WEBRTC_M150_MACOS_BINARY_SHA256}" ]]; then
    echo "WebRTC M150 gate: unapproved macOS binary SHA-256: ${actual_sha256}" >&2
    return 1
  fi
}

skybridge_normalize_versioned_framework_layout() {
  local framework_dir="${1:-}"

  [[ -n "${framework_dir}" && -d "${framework_dir}" ]] || return 1

  local current_dir="${framework_dir}/Versions/A"
  local nested_versions_dir="${current_dir}/Versions"
  [[ -d "${current_dir}" && -e "${nested_versions_dir}" ]] || return 0

  local nested_privacy="${nested_versions_dir}/A/Resources/PrivacyInfo.xcprivacy"
  if [[ -f "${nested_privacy}" ]]; then
    mkdir -p "${current_dir}/Resources"
    cp -f "${nested_privacy}" "${current_dir}/Resources/PrivacyInfo.xcprivacy"
  fi

  rm -rf "${nested_versions_dir}"
}

skybridge_assert_no_nested_framework_versions_payload() {
  local framework_dir="${1:-}"

  [[ -n "${framework_dir}" && -d "${framework_dir}" ]] || return 1
  [[ ! -e "${framework_dir}/Versions/A/Versions" ]]
}

skybridge_framework_supports_arch() {
  local framework_dir="${1:-}"
  local framework_name="${2:-}"
  local build_arch="${3:-}"
  local binary_path=""

  [[ -n "${build_arch}" ]] || return 1
  binary_path="$(skybridge_framework_binary_path "${framework_dir}" "${framework_name}")" || return 1

  lipo "${binary_path}" -verify_arch "${build_arch}" >/dev/null 2>&1
}

skybridge_resolve_framework_in_xcframework() {
  local xcframework_path="${1:-}"
  local framework_name="${2:-}"
  local build_arch="${3:-}"

  [[ -n "${xcframework_path}" && -n "${framework_name}" && -n "${build_arch}" ]] || return 1
  [[ -d "${xcframework_path}" && -f "${xcframework_path}/Info.plist" ]] || return 1

  python3 - "${xcframework_path}" "${framework_name}" "${build_arch}" <<'PY'
import plistlib
import sys
from pathlib import Path

xcframework_path = Path(sys.argv[1])
framework_name = sys.argv[2]
build_arch = sys.argv[3]
info_plist = xcframework_path / "Info.plist"

try:
    with info_plist.open("rb") as handle:
        plist = plistlib.load(handle)
except Exception:
    raise SystemExit(1)

for library in plist.get("AvailableLibraries", []):
    if library.get("SupportedPlatform") != "macos":
        continue
    if build_arch not in library.get("SupportedArchitectures", []):
        continue

    library_identifier = str(library.get("LibraryIdentifier", "")).strip()
    library_path = str(library.get("LibraryPath") or library.get("BinaryPath") or "").strip()
    if not library_identifier or not library_path:
        continue

    candidate = xcframework_path / library_identifier / library_path
    if candidate.name == f"{framework_name}.framework" and candidate.is_dir():
        print(candidate)
        raise SystemExit(0)

raise SystemExit(1)
PY
}

skybridge_resolve_framework_source_dir() {
  local framework_name="${1:-}"
  local build_arch="${2:-}"
  local build_dir="${3:-}"
  local xcode_derived_data_path="${4:-}"
  local project_root="${5:-}"
  local candidate=""
  local artifact_root=""
  local xcframework=""
  local resolved=""
  local -a direct_candidates
  local -a artifact_roots

  [[ -n "${framework_name}" && -n "${build_arch}" ]] || return 1

  direct_candidates=()
  if [[ -n "${build_dir}" ]]; then
    direct_candidates+=(
      "${build_dir}/${framework_name}.framework"
      "${build_dir}/PackageFrameworks/${framework_name}.framework"
    )
  fi
  if [[ -n "${project_root}" ]]; then
    direct_candidates+=(
      "${project_root}/.build/${build_arch}-apple-macosx/release/${framework_name}.framework"
      "${project_root}/Sources/Vendor/${framework_name}.framework"
      "${project_root}/Vendor/${framework_name}.framework"
    )
  fi

  for candidate in "${direct_candidates[@]}"; do
    if skybridge_framework_supports_arch "${candidate}" "${framework_name}" "${build_arch}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  artifact_roots=()
  if [[ -n "${xcode_derived_data_path}" ]]; then
    artifact_roots+=("${xcode_derived_data_path}/SourcePackages/artifacts")
  fi
  if [[ -n "${project_root}" ]]; then
    artifact_roots+=(
      "${project_root}/.build/artifacts"
      "${project_root}/Sources/Vendor"
      "${project_root}/Vendor"
    )
  fi

  for artifact_root in "${artifact_roots[@]}"; do
    [[ -d "${artifact_root}" ]] || continue
    while IFS= read -r -d '' xcframework; do
      resolved="$(skybridge_resolve_framework_in_xcframework "${xcframework}" "${framework_name}" "${build_arch}")" || true
      if skybridge_framework_supports_arch "${resolved}" "${framework_name}" "${build_arch}"; then
        printf '%s\n' "${resolved}"
        return 0
      fi
    done < <(find "${artifact_root}" -type d -name "${framework_name}.xcframework" -print0)
  done

  return 1
}
