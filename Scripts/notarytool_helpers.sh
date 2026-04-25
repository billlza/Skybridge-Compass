#!/usr/bin/env bash

skybridge_notarytool_maybe_source_local_env() {
  local env_file="${SKYBRIDGE_NOTARYTOOL_ENV_FILE:-$HOME/.config/skybridge/notarytool.env}"

  if [[ -n "${SKYBRIDGE_NOTARYTOOL_ENV_LOADED:-}" ]]; then
    return 0
  fi

  export SKYBRIDGE_NOTARYTOOL_ENV_LOADED=1

  if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${env_file}"
  fi
}

skybridge_notarytool_prepare_args() {
  skybridge_notarytool_maybe_source_local_env
  SKYBRIDGE_NOTARYTOOL_ARGS=()

  if [[ -n "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]]; then
    SKYBRIDGE_NOTARYTOOL_ARGS=(--keychain-profile "${NOTARYTOOL_KEYCHAIN_PROFILE}")
    return 0
  fi

  if [[ -n "${NOTARYTOOL_KEY:-}" && -n "${NOTARYTOOL_KEY_ID:-}" ]]; then
    SKYBRIDGE_NOTARYTOOL_ARGS=(
      --key "${NOTARYTOOL_KEY}"
      --key-id "${NOTARYTOOL_KEY_ID}"
    )
    if [[ -n "${NOTARYTOOL_ISSUER:-}" ]]; then
      SKYBRIDGE_NOTARYTOOL_ARGS+=(--issuer "${NOTARYTOOL_ISSUER}")
    fi
    return 0
  fi

  if [[ -n "${NOTARYTOOL_APPLE_ID:-}" && -n "${NOTARYTOOL_PASSWORD:-}" && -n "${NOTARYTOOL_TEAM_ID:-}" ]]; then
    SKYBRIDGE_NOTARYTOOL_ARGS=(
      --apple-id "${NOTARYTOOL_APPLE_ID}"
      --password "${NOTARYTOOL_PASSWORD}"
      --team-id "${NOTARYTOOL_TEAM_ID}"
    )
    return 0
  fi

  return 1
}

skybridge_notarytool_require_args() {
  if skybridge_notarytool_prepare_args; then
    return 0
  fi

  cat >&2 <<'EOF'
缺少 notarization 凭据。请通过以下任一方式提供：
  1. NOTARYTOOL_KEYCHAIN_PROFILE=<profile>
  2. NOTARYTOOL_KEY=<p8-path> NOTARYTOOL_KEY_ID=<id> [NOTARYTOOL_ISSUER=<issuer>]
  3. NOTARYTOOL_APPLE_ID=<apple-id> NOTARYTOOL_PASSWORD=<app-specific-password> NOTARYTOOL_TEAM_ID=<team-id>
EOF
  return 1
}

skybridge_notarytool_history() {
  local -a cmd=()

  if ! command -v xcrun >/dev/null 2>&1 || ! xcrun -f notarytool >/dev/null 2>&1; then
    echo "未找到 xcrun notarytool，无法执行 notarization。" >&2
    return 1
  fi

  skybridge_notarytool_require_args || return 1
  cmd=(xcrun notarytool history "${SKYBRIDGE_NOTARYTOOL_ARGS[@]}")
  "${cmd[@]}"
}

skybridge_notarytool_validate_credentials() {
  skybridge_notarytool_history >/dev/null 2>&1
}

skybridge_notarytool_submit_and_wait() {
  local artifact="$1"
  shift || true
  local -a extra_args=("$@")
  local -a cmd=()

  if ! command -v xcrun >/dev/null 2>&1 || ! xcrun -f notarytool >/dev/null 2>&1; then
    echo "未找到 xcrun notarytool，无法执行 notarization。" >&2
    return 1
  fi

  skybridge_notarytool_require_args || return 1
  if [[ -d "${artifact}" && "${artifact}" == *.app ]]; then
    extra_args+=(--force)
  fi

  cmd=(xcrun notarytool submit "${artifact}" "${SKYBRIDGE_NOTARYTOOL_ARGS[@]}" --wait)
  if ((${#extra_args[@]} > 0)); then
    cmd+=("${extra_args[@]}")
  fi

  "${cmd[@]}"
}

skybridge_staple_artifact() {
  local artifact="$1"

  if ! command -v xcrun >/dev/null 2>&1 || ! xcrun -f stapler >/dev/null 2>&1; then
    echo "未找到 xcrun stapler，无法执行 stapling。" >&2
    return 1
  fi

  xcrun stapler staple "${artifact}"
}

skybridge_assess_gatekeeper() {
  local target="$1"
  local target_type="${2:-execute}"
  local output

  if output=$(spctl --assess --type "${target_type}" --verbose=4 "${target}" 2>&1); then
    printf '%s\n' "${output}"
    return 0
  fi

  printf '%s\n' "${output}"
  return 1
}

skybridge_gatekeeper_is_notarized() {
  local assessment="$1"
  [[ "${assessment}" == *"source=Notarized Developer ID"* || "${assessment}" == *"Notarized Developer ID"* ]]
}

skybridge_gatekeeper_is_unnotarized_developer_id() {
  local assessment="$1"
  [[ "${assessment}" == *"source=Unnotarized Developer ID"* || "${assessment}" == *"Unnotarized Developer ID"* ]]
}

skybridge_gatekeeper_is_accepted() {
  local assessment="$1"
  [[ "${assessment}" == *": accepted"* || "${assessment}" == *$'\naccepted'* ]]
}
