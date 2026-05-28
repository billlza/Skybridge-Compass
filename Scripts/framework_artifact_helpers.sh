#!/usr/bin/env bash

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
