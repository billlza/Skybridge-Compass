#!/usr/bin/env bash

# Shared fail-closed ownership boundary for physical-iOS smoke processes.
#
# iPadOS 27 exposes PID + executable, but not auditToken, through
# `devicectl device info processes`. A reusable remote PID is therefore never
# signal authority. The only signal authority is the local `devicectl
# --console` process captured with its audit token, executable and start time;
# CoreDevice forwards catchable signals sent to that exact handle to the app it
# launched. Remote process data is used only for fresh-launch and exit proof.

SKYBRIDGE_DEVICETCL_RUNTIME_EXECUTABLE="/Library/Developer/PrivateFrameworks/CoreDevice.framework/Resources/bin/devicectl"

skybridge_ios_process_snapshot() {
  local device_id="${1:?missing iOS device id}"
  local output_path="${2:?missing process snapshot path}"
  local timeout_seconds="${3:?missing devicectl timeout}"

  if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "iOS process snapshot timeout must be a positive integer." >&2
    return 2
  fi
  if ! xcrun devicectl --timeout "$timeout_seconds" device info processes \
    --device "$device_id" \
    --json-output "$output_path" \
    --columns '*' >/dev/null 2>&1; then
    return 2
  fi
  chmod 0600 "$output_path"
}

skybridge_ios_app_presence_status() {
  local ownership_helper="${1:?missing process ownership helper}"
  local device_id="${2:?missing iOS device id}"
  local app_path="${3:?missing iOS app path}"
  local private_dir="${4:?missing private ownership directory}"
  local timeout_seconds="${5:?missing devicectl timeout}"
  local process_snapshot
  local presence_status

  process_snapshot="$(mktemp "$private_dir/ios-processes.XXXXXX")"
  if ! skybridge_ios_process_snapshot \
    "$device_id" "$process_snapshot" "$timeout_seconds"; then
    rm -f -- "$process_snapshot"
    return 2
  fi
  if python3 "$ownership_helper" ios-presence \
    --processes-json "$process_snapshot" \
    --app-path "$app_path"; then
    presence_status=0
  else
    presence_status=$?
  fi
  rm -f -- "$process_snapshot"
  return "$presence_status"
}

skybridge_ios_require_fresh_app_launch() {
  local ownership_helper="${1:?missing process ownership helper}"
  local device_id="${2:?missing iOS device id}"
  local app_path="${3:?missing iOS app path}"
  local private_dir="${4:?missing private ownership directory}"
  local timeout_seconds="${5:?missing devicectl timeout}"
  local presence_status

  if skybridge_ios_app_presence_status \
    "$ownership_helper" "$device_id" "$app_path" "$private_dir" "$timeout_seconds"; then
    presence_status=0
  else
    presence_status=$?
  fi
  case "$presence_status" in
    1)
      return 0
      ;;
    0)
      echo "Refusing iOS smoke launch because the app is already running; close it normally before retrying." >&2
      return 1
      ;;
    *)
      echo "Refusing iOS smoke launch because pre-launch app absence could not be proven." >&2
      return 1
      ;;
  esac
}

skybridge_ios_start_console_launch() {
  local device_id="${1:?missing iOS device id}"
  local bundle_id="${2:?missing iOS bundle id}"
  local environment_json="${3:?missing iOS launch environment}"
  local timeout_seconds="${4:?missing iOS console timeout}"
  local result_json="${5:?missing console result path}"
  local stdout_path="${6:?missing console stdout path}"
  local stderr_path="${7:?missing console stderr path}"
  local pid_output_name="${8:?missing console pid output variable}"
  local terminate_existing="${9:-0}"

  if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "iOS console ownership timeout must be a positive integer." >&2
    return 2
  fi
  if ! [[ "$pid_output_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "iOS console PID output variable name is invalid." >&2
    return 2
  fi
  if [[ "$terminate_existing" != "0" && "$terminate_existing" != "1" ]]; then
    echo "iOS console terminate-existing flag must be 0 or 1." >&2
    return 2
  fi
  : >"$stdout_path"
  : >"$stderr_path"
  chmod 0600 "$stdout_path" "$stderr_path"
  rm -f -- "$result_json"

  local -a launch_options=(
    --device "$device_id"
    --console
    --environment-variables "$environment_json"
    --json-output "$result_json"
  )
  if [[ "$terminate_existing" == "1" ]]; then
    launch_options+=(--terminate-existing)
  fi
  xcrun devicectl --timeout "$timeout_seconds" device process launch \
    "${launch_options[@]}" \
    "$bundle_id" >"$stdout_path" 2>"$stderr_path" &
  printf -v "$pid_output_name" '%s' "$!"
}

skybridge_ios_capture_console_handle() {
  local ownership_helper="${1:?missing process ownership helper}"
  local console_pid="${2:?missing console pid}"
  local identity_path="${3:?missing console identity path}"
  local diagnostic_path="${4:?missing console capture diagnostic path}"
  local timeout_seconds="${5:?missing console capture timeout}"
  local started_at
  local recorded_pid

  if ! [[ "$console_pid" =~ ^[1-9][0-9]*$ ]] \
    || ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid iOS console handle capture parameters." >&2
    return 2
  fi
  : >"$diagnostic_path"
  chmod 0600 "$diagnostic_path"
  started_at="$(date +%s)"
  while true; do
    if ! kill -0 "$console_pid" >/dev/null 2>&1; then
      echo "iOS console launch handle exited before exact ownership was captured." >&2
      return 1
    fi
    if python3 "$ownership_helper" mac-capture \
      --pid "$console_pid" \
      --expected-executable "$SKYBRIDGE_DEVICETCL_RUNTIME_EXECUTABLE" \
      --output "$identity_path" >>"$diagnostic_path" 2>&1; then
      if ! recorded_pid="$(python3 "$ownership_helper" identity-pid \
        --platform macos \
        --identity "$identity_path")" \
        || [[ "$recorded_pid" != "$console_pid" ]]; then
        echo "iOS console launch state and captured handle identity disagree." >&2
        return 1
      fi
      return 0
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out capturing exact iOS console launch ownership." >&2
      return 1
    fi
    sleep 0.1
  done
}

skybridge_ios_console_handle_status() {
  local ownership_helper="${1:?missing process ownership helper}"
  local console_pid="${2:?missing console pid}"
  local identity_path="${3:?missing console identity path}"
  local recorded_pid

  if ! recorded_pid="$(python3 "$ownership_helper" identity-pid \
    --platform macos \
    --identity "$identity_path")"; then
    return 2
  fi
  if [[ "$recorded_pid" != "$console_pid" ]]; then
    echo "iOS console launch state and ownership record disagree." >&2
    return 2
  fi
  python3 "$ownership_helper" mac-status --identity "$identity_path"
}

skybridge_ios_signal_console_handle() {
  local ownership_helper="${1:?missing process ownership helper}"
  local console_pid="${2:?missing console pid}"
  local identity_path="${3:?missing console identity path}"
  local handle_status

  if skybridge_ios_console_handle_status \
    "$ownership_helper" "$console_pid" "$identity_path"; then
    handle_status=0
  else
    handle_status=$?
  fi
  if (( handle_status != 0 )); then
    echo "Refusing to signal an absent or unverifiable iOS console launch handle." >&2
    return "$handle_status"
  fi
  python3 "$ownership_helper" mac-signal \
    --identity "$identity_path" \
    --signal TERM
}

skybridge_ios_wait_console_handle_exit() {
  local ownership_helper="${1:?missing process ownership helper}"
  local console_pid="${2:?missing console pid}"
  local identity_path="${3:?missing console identity path}"
  local timeout_seconds="${4:?missing console exit timeout}"
  local started_at
  local handle_status

  if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "iOS console exit timeout must be a positive integer." >&2
    return 2
  fi
  started_at="$(date +%s)"
  while true; do
    if skybridge_ios_console_handle_status \
      "$ownership_helper" "$console_pid" "$identity_path"; then
      handle_status=0
    else
      handle_status=$?
    fi
    case "$handle_status" in
      0)
        ;;
      1)
        wait "$console_pid" >/dev/null 2>&1 || true
        return 0
        ;;
      *)
        echo "iOS console launch handle became unverifiable while waiting for exit." >&2
        return 1
        ;;
    esac
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for the exact iOS console launch handle to exit." >&2
      return 1
    fi
    sleep 0.25
  done
}

skybridge_ios_capture_exited_console_identity() {
  local ownership_helper="${1:?missing process ownership helper}"
  local result_json="${2:?missing console result path}"
  local app_path="${3:?missing iOS app path}"
  local identity_path="${4:?missing iOS identity path}"

  if [[ ! -s "$result_json" ]]; then
    echo "iOS console launch result is unavailable after handle exit." >&2
    return 1
  fi
  chmod 0600 "$result_json"
  python3 "$ownership_helper" ios-capture \
    --launch-json "$result_json" \
    --app-path "$app_path" \
    --output "$identity_path"
}

skybridge_ios_require_app_absent_after_handle_exit() {
  local ownership_helper="${1:?missing process ownership helper}"
  local device_id="${2:?missing iOS device id}"
  local app_path="${3:?missing iOS app path}"
  local private_dir="${4:?missing private ownership directory}"
  local timeout_seconds="${5:?missing devicectl timeout}"
  local presence_status

  if skybridge_ios_app_presence_status \
    "$ownership_helper" "$device_id" "$app_path" "$private_dir" "$timeout_seconds"; then
    presence_status=0
  else
    presence_status=$?
  fi
  if (( presence_status == 1 )); then
    return 0
  fi
  if (( presence_status == 0 )); then
    echo "iOS app remains present after the exact console launch handle exited." >&2
  else
    echo "Unable to prove iOS app absence after the exact console launch handle exited." >&2
  fi
  return 1
}
