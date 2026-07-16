#!/usr/bin/env bash

# Transactional installer for the two canonical Q-Periapt vendor surfaces. This file is
# sourced by build_qperiapt_xcframework.sh and by its fault-injection tests.
#
# Each staged replacement and backup is a sibling of its destination, so the
# final moves are same-filesystem renames. A persistent journal makes an
# interrupted transaction recoverable on the next invocation. The journal uses
# fixed marker names and is never sourced as shell code.

QPERIAPT_TRANSACTION_ACTIVE=0
QPERIAPT_TRANSACTION_JOURNAL=""
QPERIAPT_TRANSACTION_MAC_DESTINATION=""
QPERIAPT_TRANSACTION_HEADER_DESTINATION=""

qperiapt_transaction_log() {
  printf '[qperiapt-install-transaction] %s\n' "$*"
}

qperiapt_transaction_path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

qperiapt_transaction_stage_path() {
  printf '%s.qperiapt-install.staged\n' "$1"
}

qperiapt_transaction_backup_path() {
  printf '%s.qperiapt-install.backup\n' "$1"
}

qperiapt_transaction_device_id() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.stat(sys.argv[1]).st_dev)
PY
}

qperiapt_transaction_remove_path() {
  local path="$1"
  if qperiapt_transaction_path_exists "$path" && ! rm -rf "$path"; then
    echo "Failed to remove Q-Periapt transaction path: $path" >&2
    return 1
  fi
}

qperiapt_transaction_cleanup_paths() {
  local journal="$1"
  local mac_destination="$2"
  local header_destination="$3"
  local failed=0
  local destination

  for destination in "$mac_destination" "$header_destination"; do
    qperiapt_transaction_remove_path "$(qperiapt_transaction_stage_path "$destination")" || failed=1
    qperiapt_transaction_remove_path "$(qperiapt_transaction_backup_path "$destination")" || failed=1
  done
  if [[ "$failed" -ne 0 ]]; then
    echo "Failed to clean Q-Periapt transaction backups; journal retained at $journal" >&2
    return 1
  fi
  if ! rm -rf "$journal"; then
    echo "Failed to remove committed Q-Periapt transaction journal: $journal" >&2
    return 1
  fi
}

qperiapt_transaction_restore_one() {
  local journal="$1"
  local label="$2"
  local destination="$3"
  local backup
  local staged
  backup="$(qperiapt_transaction_backup_path "$destination")"
  staged="$(qperiapt_transaction_stage_path "$destination")"

  if qperiapt_transaction_path_exists "$backup"; then
    if qperiapt_transaction_path_exists "$destination" \
      && ! qperiapt_transaction_remove_path "$destination"; then
      echo "Rollback could not remove the new Q-Periapt $label target: $destination" >&2
      return 1
    fi
    # Keep the backup intact until every target has been restored. If a later
    # target fails to restore, a subsequent recovery pass must still have all
    # original bytes available.
    if [[ -d "$backup" && ! -L "$backup" ]]; then
      if ! cp -R "$backup" "$destination"; then
        echo "Rollback could not restore the previous Q-Periapt $label directory: $backup -> $destination" >&2
        return 1
      fi
    elif ! cp -p "$backup" "$destination"; then
      echo "Rollback could not restore the previous Q-Periapt $label file: $backup -> $destination" >&2
      return 1
    fi
  elif [[ -f "$journal/$label.backed-up" ]]; then
    echo "Rollback is missing the recorded Q-Periapt $label backup: $backup" >&2
    return 1
  elif [[ -f "$journal/$label.existed" ]]; then
    if ! qperiapt_transaction_path_exists "$destination"; then
      echo "Rollback cannot find the original Q-Periapt $label target: $destination" >&2
      return 1
    fi
  elif qperiapt_transaction_path_exists "$destination"; then
    if ! qperiapt_transaction_remove_path "$destination"; then
      echo "Rollback could not remove newly created Q-Periapt $label target: $destination" >&2
      return 1
    fi
  fi

  if ! qperiapt_transaction_remove_path "$staged"; then
    echo "Rollback could not remove staged Q-Periapt $label target: $staged" >&2
    return 1
  fi
}

qperiapt_transaction_rollback_paths() {
  local journal="$1"
  local mac_destination="$2"
  local header_destination="$3"
  local failed=0

  qperiapt_transaction_restore_one "$journal" mac "$mac_destination" || failed=1
  qperiapt_transaction_restore_one "$journal" header "$header_destination" || failed=1

  if [[ "$failed" -ne 0 ]]; then
    echo "Q-Periapt rollback FAILED; backups and journal are retained for explicit recovery: $journal" >&2
    return 1
  fi
  if ! : >"$journal/rolled-back"; then
    echo "Q-Periapt targets were restored, but rollback state could not be journaled: $journal" >&2
    return 1
  fi
  if ! qperiapt_transaction_cleanup_paths \
    "$journal" "$mac_destination" "$header_destination"; then
    echo "Q-Periapt targets were restored, but rollback cleanup remains incomplete: $journal" >&2
    return 1
  fi
  qperiapt_transaction_log "Rolled back all Q-Periapt vendor targets."
}

qperiapt_transaction_recover_if_needed() {
  local journal="$1"
  local mac_destination="$2"
  local header_destination="$3"
  local owner_pid=""
  local journal_version=""
  local candidate=""
  local destination=""
  local transaction_artifacts_exist=0

  [[ -d "$journal" ]] || return 0

  if [[ ! -f "$journal/owner.pid" || ! -f "$journal/version" || ! -f "$journal/initialized" ]]; then
    for destination in "$mac_destination" "$header_destination"; do
      for candidate in \
        "$(qperiapt_transaction_stage_path "$destination")" \
        "$(qperiapt_transaction_backup_path "$destination")"; do
        if qperiapt_transaction_path_exists "$candidate"; then
          transaction_artifacts_exist=1
        fi
      done
    done
    if [[ "$transaction_artifacts_exist" -ne 0 ]]; then
      echo "Q-Periapt transaction journal is incomplete while staged or backup data exists; refusing unsafe automatic recovery: $journal" >&2
      return 1
    fi
    qperiapt_transaction_log "Removing an incomplete pre-install journal with no staged or backup data."
    if ! rm -rf "$journal"; then
      echo "Failed to remove incomplete Q-Periapt transaction journal: $journal" >&2
      return 1
    fi
    return 0
  fi
  owner_pid="$(tr -d '[:space:]' <"$journal/owner.pid")"
  journal_version="$(tr -d '[:space:]' <"$journal/version")"
  if [[ ! "$owner_pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "Q-Periapt transaction journal has an invalid owner pid: $journal/owner.pid" >&2
    return 1
  fi
  if [[ "$journal_version" != "2" ]]; then
    echo "Unsupported Q-Periapt transaction journal version: ${journal_version:-<missing>}" >&2
    return 1
  fi
  if kill -0 "$owner_pid" 2>/dev/null; then
    echo "Another Q-Periapt install transaction is still active (pid=$owner_pid, journal=$journal)." >&2
    return 1
  fi

  if [[ -f "$journal/committed" || -f "$journal/rolled-back" ]]; then
    qperiapt_transaction_log "Finishing cleanup for a previously completed transaction."
    qperiapt_transaction_cleanup_paths \
      "$journal" "$mac_destination" "$header_destination"
    return
  fi

  qperiapt_transaction_log "Recovering an interrupted transaction before starting a new install."
  qperiapt_transaction_rollback_paths \
    "$journal" "$mac_destination" "$header_destination"
}

qperiapt_transaction_assert_no_orphans() {
  local mac_destination="$1"
  local header_destination="$2"
  local destination
  local candidate

  for destination in "$mac_destination" "$header_destination"; do
    for candidate in \
      "$(qperiapt_transaction_stage_path "$destination")" \
      "$(qperiapt_transaction_backup_path "$destination")"; do
      if qperiapt_transaction_path_exists "$candidate"; then
        echo "Orphaned Q-Periapt transaction path exists without a journal: $candidate" >&2
        return 1
      fi
    done
  done
}

qperiapt_transaction_exit_trap() {
  local original_status=$?
  local recovery_status=0

  trap - EXIT INT TERM HUP
  if [[ "${QPERIAPT_TRANSACTION_ACTIVE:-0}" == "1" ]]; then
    if [[ -f "$QPERIAPT_TRANSACTION_JOURNAL/committed" ]]; then
      echo "Q-Periapt install committed but cleanup did not finish; retrying cleanup." >&2
      qperiapt_transaction_cleanup_paths \
        "$QPERIAPT_TRANSACTION_JOURNAL" \
        "$QPERIAPT_TRANSACTION_MAC_DESTINATION" \
        "$QPERIAPT_TRANSACTION_HEADER_DESTINATION" || recovery_status=1
    else
      echo "Q-Periapt install did not commit; restoring every previous vendor target." >&2
      qperiapt_transaction_rollback_paths \
        "$QPERIAPT_TRANSACTION_JOURNAL" \
        "$QPERIAPT_TRANSACTION_MAC_DESTINATION" \
        "$QPERIAPT_TRANSACTION_HEADER_DESTINATION" || recovery_status=1
    fi
  fi

  if [[ "$original_status" -eq 0 || "$recovery_status" -ne 0 ]]; then
    original_status=1
  fi
  exit "$original_status"
}

qperiapt_transaction_begin() {
  local journal="$1"
  local mac_destination="$2"
  local header_destination="$3"
  local journal_parent
  local expected_device
  local destination
  local destination_parent
  local destination_device

  case "${QPERIAPT_INSTALL_FAULT_STEP:-}" in
    ""|1|2) ;;
    *)
      echo "Invalid QPERIAPT_INSTALL_FAULT_STEP=${QPERIAPT_INSTALL_FAULT_STEP}" >&2
      return 1
      ;;
  esac
  journal_parent="$(dirname "$journal")"
  if ! mkdir -p "$journal_parent"; then
    echo "Failed to create Q-Periapt transaction journal parent: $journal_parent" >&2
    return 1
  fi
  for destination in "$mac_destination" "$header_destination"; do
    if ! mkdir -p "$(dirname "$destination")"; then
      echo "Failed to create Q-Periapt destination parent: $(dirname "$destination")" >&2
      return 1
    fi
  done
  if ! qperiapt_transaction_recover_if_needed \
    "$journal" "$mac_destination" "$header_destination"; then
    return 1
  fi
  if ! qperiapt_transaction_assert_no_orphans \
    "$mac_destination" "$header_destination"; then
    return 1
  fi

  if ! expected_device="$(qperiapt_transaction_device_id "$journal_parent")"; then
    echo "Failed to inspect Q-Periapt transaction journal filesystem: $journal_parent" >&2
    return 1
  fi
  for destination in "$mac_destination" "$header_destination"; do
    destination_parent="$(dirname "$destination")"
    if ! destination_device="$(qperiapt_transaction_device_id "$destination_parent")"; then
      echo "Failed to inspect Q-Periapt destination filesystem: $destination_parent" >&2
      return 1
    fi
    if [[ "$destination_device" != "$expected_device" ]]; then
      echo "Q-Periapt journal and destination must share one filesystem: $journal_parent vs $destination_parent" >&2
      return 1
    fi
  done
  if ! mkdir "$journal"; then
    echo "Failed to create Q-Periapt transaction journal: $journal" >&2
    return 1
  fi
  if ! printf '%s\n' "$$" >"$journal/owner.pid" \
    || ! printf '%s\n' "2" >"$journal/version"; then
    echo "Failed to initialize Q-Periapt transaction journal metadata: $journal" >&2
    return 1
  fi
  if qperiapt_transaction_path_exists "$mac_destination"; then
    if ! : >"$journal/mac.existed"; then
      echo "Failed to journal the existing Q-Periapt mac target." >&2
      return 1
    fi
  fi
  if qperiapt_transaction_path_exists "$header_destination"; then
    if ! : >"$journal/header.existed"; then
      echo "Failed to journal the existing Q-Periapt header target." >&2
      return 1
    fi
  fi
  if ! : >"$journal/initialized"; then
    echo "Failed to finalize Q-Periapt transaction journal initialization: $journal" >&2
    return 1
  fi

  QPERIAPT_TRANSACTION_ACTIVE=1
  QPERIAPT_TRANSACTION_JOURNAL="$journal"
  QPERIAPT_TRANSACTION_MAC_DESTINATION="$mac_destination"
  QPERIAPT_TRANSACTION_HEADER_DESTINATION="$header_destination"
  trap qperiapt_transaction_exit_trap EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

qperiapt_transaction_install_one() {
  local label="$1"
  local step="$2"
  local destination="$3"
  local journal="$QPERIAPT_TRANSACTION_JOURNAL"
  local staged
  local backup
  staged="$(qperiapt_transaction_stage_path "$destination")"
  backup="$(qperiapt_transaction_backup_path "$destination")"

  if [[ ! -f "$journal/version" || ! -f "$journal/initialized" ]]; then
    echo "Q-Periapt transaction journal is unavailable during $label install: $journal" >&2
    return 1
  fi
  if ! qperiapt_transaction_path_exists "$staged"; then
    echo "Validated staged Q-Periapt $label target is missing: $staged" >&2
    return 1
  fi
  if qperiapt_transaction_path_exists "$backup"; then
    echo "Q-Periapt $label backup already exists: $backup" >&2
    return 1
  fi

  if [[ -f "$journal/$label.existed" ]]; then
    if ! mv "$destination" "$backup"; then
      echo "Failed to create Q-Periapt $label backup: $destination -> $backup" >&2
      return 1
    fi
    if ! : >"$journal/$label.backed-up"; then
      echo "Failed to journal the Q-Periapt $label backup." >&2
      return 1
    fi
  elif qperiapt_transaction_path_exists "$destination"; then
    echo "Q-Periapt $label destination appeared after the transaction began: $destination" >&2
    return 1
  fi

  if ! mv "$staged" "$destination"; then
    echo "Failed to install staged Q-Periapt $label target: $staged -> $destination" >&2
    return 1
  fi
  if ! : >"$journal/$label.installed"; then
    echo "Failed to journal the installed Q-Periapt $label target." >&2
    return 1
  fi

  if [[ "${QPERIAPT_INSTALL_FAULT_STEP:-}" == "$step" ]]; then
    echo "Injected Q-Periapt install failure after step $step ($label)." >&2
    return 1
  fi
}

qperiapt_transaction_install_all() {
  if [[ "${QPERIAPT_TRANSACTION_ACTIVE:-0}" != "1" ]]; then
    echo "Q-Periapt transaction is not active." >&2
    return 1
  fi

  qperiapt_transaction_install_one mac 1 "$QPERIAPT_TRANSACTION_MAC_DESTINATION" || return 1
  qperiapt_transaction_install_one header 2 "$QPERIAPT_TRANSACTION_HEADER_DESTINATION" || return 1
}

qperiapt_transaction_commit() {
  local journal="$QPERIAPT_TRANSACTION_JOURNAL"

  if [[ "${QPERIAPT_TRANSACTION_ACTIVE:-0}" != "1" ]]; then
    echo "Q-Periapt transaction is not active." >&2
    return 1
  fi
  for marker in mac.installed header.installed; do
    if [[ ! -f "$journal/$marker" ]]; then
      echo "Q-Periapt transaction cannot commit without marker: $marker" >&2
      return 1
    fi
  done
  if ! : >"$journal/committed"; then
    echo "Failed to record the Q-Periapt transaction commit point: $journal" >&2
    return 1
  fi
  if ! qperiapt_transaction_cleanup_paths \
    "$journal" \
    "$QPERIAPT_TRANSACTION_MAC_DESTINATION" \
    "$QPERIAPT_TRANSACTION_HEADER_DESTINATION"; then
    echo "Q-Periapt targets committed, but transaction cleanup failed; success is not reported." >&2
    return 1
  fi

  QPERIAPT_TRANSACTION_ACTIVE=0
  trap - EXIT INT TERM HUP
  qperiapt_transaction_log "Committed all Q-Periapt vendor targets and removed every backup."
}
