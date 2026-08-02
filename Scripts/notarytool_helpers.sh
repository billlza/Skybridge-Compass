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

skybridge_notarytool_submission_id_from_output() {
  local output="$1"

  printf '%s\n' "${output}" \
    | awk '
        /^[[:space:]]*id:[[:space:]]*/ { print $2; exit }
        /^[[:space:]]*ID:[[:space:]]*/ { print $2; exit }
	      '
}

skybridge_notarytool_output_has_upload_transport_error() {
  local output="$1"

  [[ "${output}" == *"abortedUpload"* \
    || "${output}" == *"HTTPClientError.deadlineExceeded"* \
    || "${output}" == *"HTTPClientError.connectTimeout"* ]]
}

skybridge_notarytool_wait_for_submission_id() {
  local submission_id="$1"
  local poll_seconds="${SKYBRIDGE_NOTARYTOOL_POLL_SECONDS:-30}"
  local max_attempts="${SKYBRIDGE_NOTARYTOOL_MAX_POLL_ATTEMPTS:-40}"
  local attempt=1
  local output=""
  local status_text=""

  skybridge_notarytool_require_args || return 1

  while (( attempt <= max_attempts )); do
    if ! output="$(xcrun notarytool info "${submission_id}" "${SKYBRIDGE_NOTARYTOOL_ARGS[@]}" 2>&1)"; then
      printf '%s\n' "${output}" >&2
      return 1
    fi

    printf '%s\n' "${output}"
    status_text="$(printf '%s\n' "${output}" | awk -F': ' '/^[[:space:]]*status:/ { print $2; exit }')"

    case "${status_text}" in
      Accepted)
        return 0
        ;;
      Invalid|Rejected)
        echo "notarytool submission ${submission_id} finished with status ${status_text}" >&2
        return 1
        ;;
    esac

    if (( attempt == max_attempts )); then
      break
    fi

    echo "notarytool submission ${submission_id} still ${status_text:-unknown}; retrying in ${poll_seconds}s (${attempt}/${max_attempts})" >&2
    sleep "${poll_seconds}"
    attempt=$((attempt + 1))
  done

  echo "notarytool submission ${submission_id} did not finish after ${max_attempts} polls" >&2
  return 1
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

  local output=""
  local exit_code=0
  if output="$("${cmd[@]}" 2>&1)"; then
    printf '%s\n' "${output}"
    return 0
  fi
  exit_code=$?
  printf '%s\n' "${output}" >&2

  local submission_id=""
  submission_id="$(skybridge_notarytool_submission_id_from_output "${output}")"
  local had_upload_transport_error=0
  if skybridge_notarytool_output_has_upload_transport_error "${output}"; then
    had_upload_transport_error=1
  fi
  local wait_status=0
  if [[ -n "${submission_id}" ]]; then
    echo "notarytool submit returned ${exit_code} after creating submission ${submission_id}; polling final status" >&2
    if skybridge_notarytool_wait_for_submission_id "${submission_id}"; then
      return 0
    fi
    wait_status=$?
    if [[ "${had_upload_transport_error}" == "1" ]]; then
      echo "notarytool submission ${submission_id} did not finish after upload transport error; retrying once with --no-s3-acceleration" >&2
      cmd=(xcrun notarytool submit "${artifact}" "${SKYBRIDGE_NOTARYTOOL_ARGS[@]}" --wait --no-s3-acceleration)
      if ((${#extra_args[@]} > 0)); then
        cmd+=("${extra_args[@]}")
      fi
      if output="$("${cmd[@]}" 2>&1)"; then
        printf '%s\n' "${output}"
        return 0
      fi
      exit_code=$?
      printf '%s\n' "${output}" >&2
      submission_id="$(skybridge_notarytool_submission_id_from_output "${output}")"
      if [[ -n "${submission_id}" ]]; then
        echo "notarytool retry returned ${exit_code} after creating submission ${submission_id}; polling final status" >&2
        skybridge_notarytool_wait_for_submission_id "${submission_id}"
        return $?
      fi
      return "${exit_code}"
    fi
    return "${wait_status}"
  fi

  if [[ "${had_upload_transport_error}" == "1" ]]; then
    echo "notarytool upload timed out; retrying once with --no-s3-acceleration" >&2
    cmd=(xcrun notarytool submit "${artifact}" "${SKYBRIDGE_NOTARYTOOL_ARGS[@]}" --wait --no-s3-acceleration)
    if ((${#extra_args[@]} > 0)); then
      cmd+=("${extra_args[@]}")
    fi
    if output="$("${cmd[@]}" 2>&1)"; then
      printf '%s\n' "${output}"
      return 0
    fi
    exit_code=$?
    printf '%s\n' "${output}" >&2
    submission_id="$(skybridge_notarytool_submission_id_from_output "${output}")"
    if [[ -n "${submission_id}" ]]; then
      echo "notarytool retry returned ${exit_code} after creating submission ${submission_id}; polling final status" >&2
      skybridge_notarytool_wait_for_submission_id "${submission_id}"
      return $?
    fi
    return "${exit_code}"
  fi

  return "${exit_code}"
}

skybridge_staple_artifact() {
  local artifact="$1"
  local attempt=1
  local max_attempts="${SKYBRIDGE_STAPLER_MAX_ATTEMPTS:-5}"
  local delay_seconds="${SKYBRIDGE_STAPLER_RETRY_DELAY_SECONDS:-15}"

  if ! command -v xcrun >/dev/null 2>&1 || ! xcrun -f stapler >/dev/null 2>&1; then
    echo "未找到 xcrun stapler，无法执行 stapling。" >&2
    return 1
  fi

  while (( attempt <= max_attempts )); do
    if xcrun stapler staple "${artifact}"; then
      return 0
    fi

    if (( attempt == max_attempts )); then
      break
    fi

    echo "stapler staple failed for ${artifact}; retrying in ${delay_seconds}s (${attempt}/${max_attempts})" >&2
    sleep "${delay_seconds}"
    attempt=$((attempt + 1))
  done

  return 1
}

skybridge_assess_gatekeeper() {
  local target="$1"
  local target_type="${2:-execute}"
  local output
  local -a extra_arguments=()

  # Disk images need the primary-signature context; without it newer macOS
  # releases reject the assessment outright with "Insufficient Context".
  if [[ "${target_type}" == "open" ]]; then
    extra_arguments+=(--context context:primary-signature)
  fi

  if output=$(spctl --assess --type "${target_type}" "${extra_arguments[@]}" --verbose=4 "${target}" 2>&1); then
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
