#!/usr/bin/env bash

# Transactionally replace the four checked-in FreeRDP runtime components.
#
# This helper is sourced by build_freerdp_dylibs.sh so the transaction can be
# exercised independently with filesystem fixtures. The caller supplies the
# move command; production always passes /bin/mv, while tests use a mover that
# fails at an exact operation boundary.

_skybridge_freerdp_process_start_token() {
  local pid="$1"
  local process_start

  if process_start="$(LC_ALL=C /bin/ps -p "$pid" -o lstart= 2>/dev/null)"; then
    :
  elif /bin/kill -0 "$pid" 2>/dev/null; then
    return 2
  else
    return 1
  fi
  process_start="$(printf '%s' "$process_start" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$process_start" ]] || return 1
  printf '%s' "${pid}:${process_start}" | shasum -a 256 | awk '{print $1}'
}

_skybridge_freerdp_read_lock_record() {
  local owner_file="$1"
  local record

  [[ -f "$owner_file" && ! -L "$owner_file" ]] || return 1
  record="$(<"$owner_file")"
  [[ "$record" != *$'\n'* && "$record" != *$'\r'* ]] || return 1
  printf '%s\n' "$record"
}

_skybridge_freerdp_lock_record_is_valid() {
  local record="$1"
  local owner_pid owner_token publish_stage backup_stage extra

  IFS=$'\t' read -r owner_pid owner_token publish_stage backup_stage extra <<<"$record"
  [[ "$owner_pid" =~ ^[0-9]+$ \
    && "$owner_token" =~ ^[0-9a-f]{64}$ \
    && -n "$publish_stage" \
    && -n "$backup_stage" \
    && -z "${extra:-}" ]]
}

_skybridge_freerdp_write_lock_record() {
  local lock_path="$1"
  local record="$2"
  local temporary_owner="$lock_path/owner.tmp.$$"

  (umask 077; printf '%s\n' "$record" >"$temporary_owner")
  /bin/mv "$temporary_owner" "$lock_path/owner"
}

_skybridge_freerdp_acquire_publish_lock() {
  local lock_path="$1"
  local publish_stage="$2"
  local backup_stage="$3"
  local process_token_command="$4"
  local current_pid="$$"
  local current_token current_record observed_record
  local owner_pid owner_token owner_publish_stage owner_backup_stage extra
  local observed_token quarantine_path quarantine_record process_probe_status

  current_token="$("$process_token_command" "$current_pid")" || {
    echo "❌ cannot establish the current FreeRDP publisher process identity" >&2
    return 1
  }
  [[ "$current_token" =~ ^[0-9a-f]{64}$ ]] || {
    echo "❌ invalid current FreeRDP publisher start token" >&2
    return 1
  }
  current_record="${current_pid}"$'\t'"${current_token}"$'\t'"${publish_stage}"$'\t'"${backup_stage}"

  if /bin/mkdir "$lock_path" 2>/dev/null; then
    if _skybridge_freerdp_write_lock_record "$lock_path" "$current_record"; then
      printf '%s\n' "$current_record"
      return 0
    fi
    rm -rf -- "$lock_path"
    echo "❌ could not persist FreeRDP publish lock ownership" >&2
    return 1
  fi

  observed_record="$(_skybridge_freerdp_read_lock_record "$lock_path/owner")" || {
    echo "❌ FreeRDP publish lock has no valid owner record; refusing unsafe recovery: ${lock_path}" >&2
    return 1
  }
  _skybridge_freerdp_lock_record_is_valid "$observed_record" || {
    echo "❌ FreeRDP publish lock owner record is malformed; refusing unsafe recovery: ${lock_path}" >&2
    return 1
  }
  IFS=$'\t' read -r owner_pid owner_token owner_publish_stage owner_backup_stage extra <<<"$observed_record"
  [[ -n "$owner_publish_stage" ]] || {
    echo "❌ FreeRDP publish lock is missing its staged-byte ownership path" >&2
    return 1
  }

  if observed_token="$("$process_token_command" "$owner_pid")"; then
    if [[ "$observed_token" == "$owner_token" ]]; then
      echo "❌ another FreeRDP publisher owns ${lock_path} (pid=${owner_pid})" >&2
      return 75
    fi
  else
    process_probe_status=$?
    if [[ "$process_probe_status" -ne 1 ]]; then
      echo "❌ cannot prove whether FreeRDP publisher pid=${owner_pid} is absent; refusing lock recovery" >&2
      return 75
    fi
  fi

  if [[ -d "$owner_backup_stage" \
    && -n "$(find "$owner_backup_stage" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    echo "❌ stale FreeRDP publisher left recovery data; refusing automatic lock recovery: ${owner_backup_stage}" >&2
    return 76
  fi

  quarantine_path="${lock_path}.stale.${current_pid}.${RANDOM}"
  if ! /bin/mv "$lock_path" "$quarantine_path" 2>/dev/null; then
    echo "❌ FreeRDP publish lock changed during stale-owner recovery: ${lock_path}" >&2
    return 75
  fi
  if quarantine_record="$(_skybridge_freerdp_read_lock_record "$quarantine_path/owner" 2>/dev/null)"; then
    :
  else
    quarantine_record=""
  fi
  if [[ "$quarantine_record" != "$observed_record" ]]; then
    if [[ ! -e "$lock_path" ]]; then
      if ! /bin/mv "$quarantine_path" "$lock_path" 2>/dev/null; then
        echo "❌ could not restore a changed FreeRDP publish lock: ${quarantine_path}" >&2
      fi
    fi
    echo "❌ FreeRDP publish lock owner changed during recovery; refusing publication" >&2
    return 75
  fi
  rm -rf -- "$quarantine_path"

  if ! /bin/mkdir "$lock_path" 2>/dev/null; then
    echo "❌ another FreeRDP publisher acquired the recovered lock" >&2
    return 75
  fi
  if ! _skybridge_freerdp_write_lock_record "$lock_path" "$current_record"; then
    rm -rf -- "$lock_path"
    echo "❌ could not persist recovered FreeRDP publish lock ownership" >&2
    return 1
  fi
  printf '%s\n' "$current_record"
}

_skybridge_freerdp_release_publish_lock() {
  local lock_path="$1"
  local expected_record="$2"
  local actual_record

  actual_record="$(_skybridge_freerdp_read_lock_record "$lock_path/owner")" || {
    echo "❌ FreeRDP publish lock disappeared before owner release: ${lock_path}" >&2
    return 1
  }
  if [[ "$actual_record" != "$expected_record" ]]; then
    echo "❌ refusing to remove a FreeRDP publish lock owned by another process" >&2
    return 1
  fi
  rm -rf -- "$lock_path"
}

_skybridge_freerdp_publish_path_is_safe() {
  local path="$1"
  [[ -n "$path" && "$path" != "/" && "$path" != "." && "$path" != ".." ]]
}

_skybridge_freerdp_publish_remove_installed_component() {
  local label="$1"
  local live_path="$2"

  if [[ ! -e "$live_path" && ! -L "$live_path" ]]; then
    echo "❌ FreeRDP rollback cannot find the newly installed ${label}: ${live_path}" >&2
    return 1
  fi
  if [[ -d "$live_path" && ! -L "$live_path" ]]; then
    rm -rf -- "$live_path"
  else
    rm -f -- "$live_path"
  fi
}

_skybridge_freerdp_publish_rollback_component() {
  local label="$1"
  local live_path="$2"
  local saved_path="$3"
  local installed="$4"
  local backed_up="$5"
  local move_command="$6"
  local failed=0

  if [[ "$installed" -eq 1 ]]; then
    if ! _skybridge_freerdp_publish_remove_installed_component "$label" "$live_path"; then
      failed=1
    fi
  fi

  if [[ "$backed_up" -eq 1 ]]; then
    if [[ -e "$live_path" || -L "$live_path" ]]; then
      echo "❌ FreeRDP rollback refuses to overwrite an unexpected ${label}: ${live_path}" >&2
      failed=1
    elif [[ ! -e "$saved_path" && ! -L "$saved_path" ]]; then
      echo "❌ FreeRDP rollback is missing the saved ${label}: ${saved_path}" >&2
      failed=1
    elif ! "$move_command" "$saved_path" "$live_path"; then
      echo "❌ FreeRDP rollback could not restore ${label}: ${live_path}" >&2
      failed=1
    fi
  fi

  return "$failed"
}

_skybridge_freerdp_publish_cleanup_stages() {
  local publish_stage="$1"
  local backup_stage="$2"
  local failed=0

  if ! rm -rf -- "$publish_stage"; then
    echo "❌ could not remove FreeRDP publish stage: ${publish_stage}" >&2
    failed=1
  fi
  if ! rm -rf -- "$backup_stage"; then
    echo "❌ could not remove FreeRDP backup stage: ${backup_stage}" >&2
    failed=1
  fi
  return "$failed"
}

_skybridge_freerdp_publish_cleanup_publish_stage() {
  local publish_stage="$1"

  if ! rm -rf -- "$publish_stage"; then
    echo "❌ could not remove failed FreeRDP publish stage: ${publish_stage}" >&2
    return 1
  fi
}

_skybridge_freerdp_publish_abort() {
  local failure_status="$1"
  local publish_stage="$2"
  local backup_stage="$3"
  local move_command="$4"
  local dylibs_out="$5"
  local headers_out="$6"
  local licenses_out="$7"
  local provenance_out="$8"
  local dylibs_backed_up="$9"
  local headers_backed_up="${10}"
  local licenses_backed_up="${11}"
  local provenance_backed_up="${12}"
  local dylibs_installed="${13}"
  local headers_installed="${14}"
  local licenses_installed="${15}"
  local provenance_installed="${16}"
  local publish_lock="${17}"
  local publish_lock_record="${18}"
  local rollback_failed=0

  set +e
  # Reverse publication order. A component is removed only when this
  # transaction installed it, and restored only when its backup move
  # completed successfully.
  _skybridge_freerdp_publish_rollback_component \
    "provenance" "$provenance_out" "$backup_stage/provenance.json" \
    "$provenance_installed" "$provenance_backed_up" "$move_command" || rollback_failed=1
  _skybridge_freerdp_publish_rollback_component \
    "licenses" "$licenses_out" "$backup_stage/Licenses" \
    "$licenses_installed" "$licenses_backed_up" "$move_command" || rollback_failed=1
  _skybridge_freerdp_publish_rollback_component \
    "headers" "$headers_out" "$backup_stage/Headers" \
    "$headers_installed" "$headers_backed_up" "$move_command" || rollback_failed=1
  _skybridge_freerdp_publish_rollback_component \
    "dylibs" "$dylibs_out" "$backup_stage/Dylibs" \
    "$dylibs_installed" "$dylibs_backed_up" "$move_command" || rollback_failed=1
  if [[ "$rollback_failed" -ne 0 ]]; then
    if ! _skybridge_freerdp_publish_cleanup_publish_stage "$publish_stage"; then
      echo "❌ failed FreeRDP publish stage also requires manual cleanup: ${publish_stage}" >&2
    fi
    if [[ -d "$publish_lock" && ! -L "$publish_lock" ]]; then
      printf '%s\n' "$backup_stage" >"$publish_lock/recovery-required"
      chmod 0600 "$publish_lock/recovery-required"
    fi
    echo "❌ FreeRDP recovery data was preserved at: ${backup_stage}" >&2
    echo "❌ FreeRDP publish lock was preserved at: ${publish_lock}" >&2
    echo "❌ FreeRDP publish rollback did not restore every component" >&2
    return 70
  fi

  _skybridge_freerdp_publish_cleanup_stages \
    "$publish_stage" "$backup_stage" || rollback_failed=1
  _skybridge_freerdp_release_publish_lock \
    "$publish_lock" "$publish_lock_record" || rollback_failed=1
  if [[ "$rollback_failed" -ne 0 ]]; then
    echo "❌ FreeRDP publish cleanup or lock release failed after rollback" >&2
    return 70
  fi
  if [[ "$failure_status" -eq 0 ]]; then
    return 1
  fi
  return "$failure_status"
}

skybridge_publish_freerdp_runtime() (
  set -euo pipefail

  if (( $# < 9 )); then
    echo "❌ FreeRDP publish transaction requires stage, destination, mover, and verifier arguments" >&2
    exit 64
  fi

  local publish_stage="$1"
  local backup_stage="$2"
  local dylibs_out="$3"
  local headers_out="$4"
  local licenses_out="$5"
  local provenance_out="$6"
  local move_command="$7"
  local process_token_command="$8"
  shift 8
  local verify_command=("$@")
  local operation_status=0
  local publish_lock
  local publish_lock_record=""
  publish_lock="$(dirname "$dylibs_out")/.FreeRDPRuntime.publish.lock"

  local dylibs_backed_up=0
  local headers_backed_up=0
  local licenses_backed_up=0
  local provenance_backed_up=0
  local dylibs_installed=0
  local headers_installed=0
  local licenses_installed=0
  local provenance_installed=0

  for path in \
    "$publish_stage" "$backup_stage" \
    "$dylibs_out" "$headers_out" "$licenses_out" "$provenance_out"; do
    if ! _skybridge_freerdp_publish_path_is_safe "$path"; then
      echo "❌ unsafe empty or root FreeRDP publish path: ${path}" >&2
      exit 64
    fi
  done
  command -v "$move_command" >/dev/null 2>&1 || {
    echo "❌ FreeRDP publish mover is unavailable: ${move_command}" >&2
    exit 64
  }
  command -v "$process_token_command" >/dev/null 2>&1 || {
    echo "❌ FreeRDP process identity probe is unavailable: ${process_token_command}" >&2
    exit 64
  }
  (( ${#verify_command[@]} > 0 )) || {
    echo "❌ FreeRDP publish transaction requires a verification command" >&2
    exit 64
  }

  [[ -d "$publish_stage" && ! -L "$publish_stage" ]] || {
    echo "❌ invalid FreeRDP publish stage: ${publish_stage}" >&2
    exit 1
  }
  [[ -d "$backup_stage" && ! -L "$backup_stage" ]] || {
    echo "❌ invalid FreeRDP backup stage: ${backup_stage}" >&2
    exit 1
  }
  [[ -z "$(find "$backup_stage" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
    echo "❌ FreeRDP backup stage must start empty: ${backup_stage}" >&2
    exit 1
  }
  for stage_directory in Dylibs Headers Licenses; do
    [[ -d "$publish_stage/$stage_directory" && ! -L "$publish_stage/$stage_directory" ]] || {
      echo "❌ invalid staged FreeRDP component: ${publish_stage}/${stage_directory}" >&2
      exit 1
    }
  done
  [[ -f "$publish_stage/provenance.json" && ! -L "$publish_stage/provenance.json" ]] || {
    echo "❌ invalid staged FreeRDP provenance: ${publish_stage}/provenance.json" >&2
    exit 1
  }

  for live_directory in "$dylibs_out" "$headers_out" "$licenses_out"; do
    if [[ -L "$live_directory" || ( -e "$live_directory" && ! -d "$live_directory" ) ]]; then
      echo "❌ existing FreeRDP component is not a real directory: ${live_directory}" >&2
      exit 1
    fi
    [[ -d "$(dirname "$live_directory")" && ! -L "$(dirname "$live_directory")" ]] || {
      echo "❌ FreeRDP component parent is not a real directory: $(dirname "$live_directory")" >&2
      exit 1
    }
  done
  if [[ -L "$provenance_out" || ( -e "$provenance_out" && ! -f "$provenance_out" ) ]]; then
    echo "❌ existing FreeRDP provenance is not a regular file: ${provenance_out}" >&2
    exit 1
  fi
  [[ -d "$(dirname "$provenance_out")" && ! -L "$(dirname "$provenance_out")" ]] || {
    echo "❌ FreeRDP provenance parent is not a real directory: $(dirname "$provenance_out")" >&2
    exit 1
  }

  if publish_lock_record="$(_skybridge_freerdp_acquire_publish_lock \
    "$publish_lock" "$publish_stage" "$backup_stage" "$process_token_command")"; then
    :
  else
    exit $?
  fi

  trap '_skybridge_freerdp_publish_abort 129 "$publish_stage" "$backup_stage" "$move_command" "$dylibs_out" "$headers_out" "$licenses_out" "$provenance_out" "$dylibs_backed_up" "$headers_backed_up" "$licenses_backed_up" "$provenance_backed_up" "$dylibs_installed" "$headers_installed" "$licenses_installed" "$provenance_installed" "$publish_lock" "$publish_lock_record"; exit $?' HUP
  trap '_skybridge_freerdp_publish_abort 130 "$publish_stage" "$backup_stage" "$move_command" "$dylibs_out" "$headers_out" "$licenses_out" "$provenance_out" "$dylibs_backed_up" "$headers_backed_up" "$licenses_backed_up" "$provenance_backed_up" "$dylibs_installed" "$headers_installed" "$licenses_installed" "$provenance_installed" "$publish_lock" "$publish_lock_record"; exit $?' INT
  trap '_skybridge_freerdp_publish_abort 143 "$publish_stage" "$backup_stage" "$move_command" "$dylibs_out" "$headers_out" "$licenses_out" "$provenance_out" "$dylibs_backed_up" "$headers_backed_up" "$licenses_backed_up" "$provenance_backed_up" "$dylibs_installed" "$headers_installed" "$licenses_installed" "$provenance_installed" "$publish_lock" "$publish_lock_record"; exit $?' TERM

  if [[ -e "$dylibs_out" ]]; then
    if "$move_command" "$dylibs_out" "$backup_stage/Dylibs"; then
      dylibs_backed_up=1
    else
      operation_status=$?
      _skybridge_freerdp_publish_abort "$operation_status" "$publish_stage" "$backup_stage" "$move_command" "$dylibs_out" "$headers_out" "$licenses_out" "$provenance_out" "$dylibs_backed_up" "$headers_backed_up" "$licenses_backed_up" "$provenance_backed_up" "$dylibs_installed" "$headers_installed" "$licenses_installed" "$provenance_installed" "$publish_lock" "$publish_lock_record"
      exit $?
    fi
  fi
  if [[ -e "$headers_out" ]]; then
    if "$move_command" "$headers_out" "$backup_stage/Headers"; then
      headers_backed_up=1
    else
      operation_status=$?
      _skybridge_freerdp_publish_abort "$operation_status" "$publish_stage" "$backup_stage" "$move_command" "$dylibs_out" "$headers_out" "$licenses_out" "$provenance_out" "$dylibs_backed_up" "$headers_backed_up" "$licenses_backed_up" "$provenance_backed_up" "$dylibs_installed" "$headers_installed" "$licenses_installed" "$provenance_installed" "$publish_lock" "$publish_lock_record"
      exit $?
    fi
  fi
  if [[ -e "$licenses_out" ]]; then
    if "$move_command" "$licenses_out" "$backup_stage/Licenses"; then
      licenses_backed_up=1
    else
      operation_status=$?
      _skybridge_freerdp_publish_abort "$operation_status" "$publish_stage" "$backup_stage" "$move_command" "$dylibs_out" "$headers_out" "$licenses_out" "$provenance_out" "$dylibs_backed_up" "$headers_backed_up" "$licenses_backed_up" "$provenance_backed_up" "$dylibs_installed" "$headers_installed" "$licenses_installed" "$provenance_installed" "$publish_lock" "$publish_lock_record"
      exit $?
    fi
  fi
  if [[ -e "$provenance_out" ]]; then
    if "$move_command" "$provenance_out" "$backup_stage/provenance.json"; then
      provenance_backed_up=1
    else
      operation_status=$?
      _skybridge_freerdp_publish_abort "$operation_status" "$publish_stage" "$backup_stage" "$move_command" "$dylibs_out" "$headers_out" "$licenses_out" "$provenance_out" "$dylibs_backed_up" "$headers_backed_up" "$licenses_backed_up" "$provenance_backed_up" "$dylibs_installed" "$headers_installed" "$licenses_installed" "$provenance_installed" "$publish_lock" "$publish_lock_record"
      exit $?
    fi
  fi

  if "$move_command" "$publish_stage/Dylibs" "$dylibs_out"; then
    dylibs_installed=1
  else
    operation_status=$?
    _skybridge_freerdp_publish_abort "$operation_status" "$publish_stage" "$backup_stage" "$move_command" "$dylibs_out" "$headers_out" "$licenses_out" "$provenance_out" "$dylibs_backed_up" "$headers_backed_up" "$licenses_backed_up" "$provenance_backed_up" "$dylibs_installed" "$headers_installed" "$licenses_installed" "$provenance_installed" "$publish_lock" "$publish_lock_record"
    exit $?
  fi
  if "$move_command" "$publish_stage/Headers" "$headers_out"; then
    headers_installed=1
  else
    operation_status=$?
    _skybridge_freerdp_publish_abort "$operation_status" "$publish_stage" "$backup_stage" "$move_command" "$dylibs_out" "$headers_out" "$licenses_out" "$provenance_out" "$dylibs_backed_up" "$headers_backed_up" "$licenses_backed_up" "$provenance_backed_up" "$dylibs_installed" "$headers_installed" "$licenses_installed" "$provenance_installed" "$publish_lock" "$publish_lock_record"
    exit $?
  fi
  if "$move_command" "$publish_stage/Licenses" "$licenses_out"; then
    licenses_installed=1
  else
    operation_status=$?
    _skybridge_freerdp_publish_abort "$operation_status" "$publish_stage" "$backup_stage" "$move_command" "$dylibs_out" "$headers_out" "$licenses_out" "$provenance_out" "$dylibs_backed_up" "$headers_backed_up" "$licenses_backed_up" "$provenance_backed_up" "$dylibs_installed" "$headers_installed" "$licenses_installed" "$provenance_installed" "$publish_lock" "$publish_lock_record"
    exit $?
  fi
  if "$move_command" "$publish_stage/provenance.json" "$provenance_out"; then
    provenance_installed=1
  else
    operation_status=$?
    _skybridge_freerdp_publish_abort "$operation_status" "$publish_stage" "$backup_stage" "$move_command" "$dylibs_out" "$headers_out" "$licenses_out" "$provenance_out" "$dylibs_backed_up" "$headers_backed_up" "$licenses_backed_up" "$provenance_backed_up" "$dylibs_installed" "$headers_installed" "$licenses_installed" "$provenance_installed" "$publish_lock" "$publish_lock_record"
    exit $?
  fi

  if "${verify_command[@]}"; then
    :
  else
    operation_status=$?
    _skybridge_freerdp_publish_abort "$operation_status" "$publish_stage" "$backup_stage" "$move_command" "$dylibs_out" "$headers_out" "$licenses_out" "$provenance_out" "$dylibs_backed_up" "$headers_backed_up" "$licenses_backed_up" "$provenance_backed_up" "$dylibs_installed" "$headers_installed" "$licenses_installed" "$provenance_installed" "$publish_lock" "$publish_lock_record"
    exit $?
  fi

  trap - HUP INT TERM
  if ! _skybridge_freerdp_publish_cleanup_stages "$publish_stage" "$backup_stage"; then
    echo "❌ FreeRDP publish succeeded but transaction stage cleanup failed; lock preserved: ${publish_lock}" >&2
    exit 70
  fi
  _skybridge_freerdp_release_publish_lock "$publish_lock" "$publish_lock_record"
)
