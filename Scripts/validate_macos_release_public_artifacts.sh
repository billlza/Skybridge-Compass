#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="validate-macos-release-public-artifacts"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/Scripts/real_device_smoke_redaction.sh"

usage() {
  cat <<'EOF'
Usage:
  validate_macos_release_public_artifacts.sh \
    --artifact '<label>|<artifact-name>|<downloaded-dir>|<public-output-dir>' [...]

Validates and materializes the redacted public artifact directories that the
macOS release readiness gate is allowed to consume. Each artifact name must
declare the public-redaction contract, and each selected public directory must
pass the public artifact scanner before and after copying.
EOF
}

fail() {
  echo "::error::[${SCRIPT_NAME}] $1" >&2
  exit 1
}

public_artifacts=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --artifact)
      [[ "$#" -ge 2 ]] || fail "missing value for --artifact"
      public_artifacts+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "${#public_artifacts[@]}" -gt 0 ]] || fail "at least one --artifact is required"

resolve_existing_dir() {
  local path="$1"
  [[ -d "${path}" ]] || return 1
  (cd "${path}" && pwd -P)
}

resolve_output_dir() {
  local path="$1"
  local parent=""
  local name=""

  [[ -n "${path}" && "${path}" != "/" ]] || return 1
  parent="$(dirname "${path}")"
  name="$(basename "${path}")"
  [[ -n "${name}" && "${name}" != "." && "${name}" != ".." ]] || return 1
  mkdir -p "${parent}"
  printf '%s/%s\n' "$(cd "${parent}" && pwd -P)" "${name}"
}

path_is_same_or_under() {
  local child="$1"
  local parent="$2"
  [[ "${child}" == "${parent}" || "${child}" == "${parent}/"* ]]
}

copy_public_artifact() {
  local label="$1"
  local artifact_name="$2"
  local downloaded_dir="$3"
  local public_output_dir="$4"
  local downloaded_abs=""
  local public_source=""
  local public_source_abs=""
  local output_abs=""

  [[ -n "${label}" ]] || fail "artifact label must not be empty"
  [[ -n "${artifact_name}" ]] || fail "${label}: artifact name must not be empty"
  case "${artifact_name}" in
    *public-redacted*|*redacted-public*) ;;
    *) fail "${label}: artifact name must declare the public redaction contract: ${artifact_name}" ;;
  esac

  downloaded_abs="$(resolve_existing_dir "${downloaded_dir}")" \
    || fail "${label}: downloaded artifact directory does not exist: ${downloaded_dir}"

  if [[ -d "${downloaded_abs}/public-redacted" ]]; then
    public_source="${downloaded_abs}/public-redacted"
  else
    public_source="${downloaded_abs}"
  fi

  public_source_abs="$(resolve_existing_dir "${public_source}")" \
    || fail "${label}: public artifact directory does not exist: ${public_source}"
  output_abs="$(resolve_output_dir "${public_output_dir}")" \
    || fail "${label}: invalid public output directory: ${public_output_dir}"

  [[ "${public_source_abs}" != "/" ]] || fail "${label}: refusing to copy from filesystem root"
  [[ "${output_abs}" != "/" ]] || fail "${label}: refusing to write to filesystem root"
  path_is_same_or_under "${output_abs}" "${downloaded_abs}" \
    && fail "${label}: public output directory must not be inside downloaded raw artifact directory"
  path_is_same_or_under "${output_abs}" "${public_source_abs}" \
    && fail "${label}: public output directory must not be inside selected public artifact directory"

  skybridge_smoke_check_public_artifacts "${public_source_abs}" \
    || fail "${label}: public artifact scanner rejected ${public_source_abs}"

  rm -rf "${output_abs}"
  mkdir -p "${output_abs}"
  cp -R "${public_source_abs}/." "${output_abs}/"

  skybridge_smoke_check_public_artifacts "${output_abs}" \
    || fail "${label}: materialized public artifact scanner rejected ${output_abs}"

  echo "[${SCRIPT_NAME}] ${label}: materialized ${artifact_name} -> ${output_abs}"
}

for spec in "${public_artifacts[@]}"; do
  IFS='|' read -r label artifact_name downloaded_dir public_output_dir extra <<<"${spec}"
  [[ -z "${extra:-}" ]] || fail "invalid --artifact spec with too many fields: ${spec}"
  copy_public_artifact "${label:-}" "${artifact_name:-}" "${downloaded_dir:-}" "${public_output_dir:-}"
done

echo "[${SCRIPT_NAME}] ok"
