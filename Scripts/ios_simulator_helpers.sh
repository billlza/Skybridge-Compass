#!/usr/bin/env bash

_skybridge_run_command_with_timeout() {
  local timeout_seconds="$1"
  local log_file="$2"
  shift 2

  python3 - "$timeout_seconds" "$log_file" "$@" <<'PY'
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
log_path = sys.argv[2]
command = sys.argv[3:]

with open(log_path, "a", encoding="utf-8") as log:
    try:
        result = subprocess.run(
            command,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired:
        log.write(f"command timed out after {timeout_seconds}s: {command!r}\n")
        raise SystemExit(124)

raise SystemExit(result.returncode)
PY
}

skybridge_pick_bootable_ios_simulator_id() {
  local requested_id="${1:-}"
  local log_prefix="${2:-[iOS simulator]}"
  local xcrun_bin="${SKYBRIDGE_XCRUN_BIN:-xcrun}"
  local list_attempts="${SKYBRIDGE_SIMCTL_LIST_ATTEMPTS:-2}"
  local boot_timeout_seconds="${SKYBRIDGE_SIMCTL_BOOT_TIMEOUT_SECONDS:-90}"
  local payload_file error_file candidates_file boot_log_file
  payload_file="$(mktemp)"
  error_file="$(mktemp)"
  candidates_file="$(mktemp)"
  boot_log_file="$(mktemp)"

  cleanup_ios_simulator_selection() {
    rm -f "$payload_file" "$error_file" "$candidates_file" "$boot_log_file"
  }

  if ! [[ "$list_attempts" =~ ^[1-9][0-9]*$ ]]; then
    echo "$log_prefix SKYBRIDGE_SIMCTL_LIST_ATTEMPTS must be a positive integer." >&2
    cleanup_ios_simulator_selection
    return 2
  fi
  if ! [[ "$boot_timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "$log_prefix SKYBRIDGE_SIMCTL_BOOT_TIMEOUT_SECONDS must be a positive integer." >&2
    cleanup_ios_simulator_selection
    return 2
  fi

  if [[ -n "$requested_id" ]]; then
    printf '%s\n' "$requested_id" >"$candidates_file"
  else
    local attempt
    for ((attempt = 1; attempt <= list_attempts; attempt += 1)); do
      if "$xcrun_bin" simctl list devices available -j >"$payload_file" 2>"$error_file" \
        && [[ -s "$payload_file" ]]; then
        break
      fi
      if ((attempt < list_attempts)); then
        sleep 2
      fi
    done

    if [[ ! -s "$payload_file" ]]; then
      echo "$log_prefix simctl did not return a non-empty simulator device list." >&2
      if [[ -s "$error_file" ]]; then
        cat "$error_file" >&2
      fi
      cleanup_ios_simulator_selection
      return 1
    fi

    if ! python3 - "$payload_file" >"$candidates_file" <<'PY'
import json
import pathlib
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

candidates = []
for runtime, devices in payload.get("devices", {}).items():
    match = re.search(r"iOS[- ](\d+)(?:[.-](\d+))?", runtime)
    if match is None:
        continue
    runtime_rank = (int(match.group(1)), int(match.group(2) or 0))
    for device in devices:
        if not device.get("isAvailable") or not device.get("udid"):
            continue
        device_type = device.get("deviceTypeIdentifier", "")
        name = device.get("name", "")
        if ".iPhone-" not in device_type and "iPhone" not in name:
            continue
        data_path = device.get("dataPath", "")
        rank = (
            int(device.get("state") == "Booted"),
            int(bool(data_path) and pathlib.Path(data_path).is_dir()),
            runtime_rank[0],
            runtime_rank[1],
            device.get("lastUsedAt", ""),
            name,
        )
        candidates.append((rank, device["udid"]))

if not candidates:
    raise SystemExit("No available iPhone simulator candidates found.")

for _, device_id in sorted(candidates, reverse=True):
    print(device_id)
PY
    then
      echo "$log_prefix failed to parse bootable iPhone simulator candidates." >&2
      cleanup_ios_simulator_selection
      return 1
    fi
  fi

  local candidate_id
  while IFS= read -r candidate_id; do
    [[ -n "$candidate_id" ]] || continue
    : >"$boot_log_file"
    _skybridge_run_command_with_timeout \
      "$boot_timeout_seconds" "$boot_log_file" \
      "$xcrun_bin" simctl boot "$candidate_id" || true
    if _skybridge_run_command_with_timeout \
      "$boot_timeout_seconds" "$boot_log_file" \
      "$xcrun_bin" simctl bootstatus "$candidate_id" -b; then
      printf '%s\n' "$candidate_id"
      cleanup_ios_simulator_selection
      return 0
    fi
    echo "$log_prefix rejected simulator that failed to boot: $candidate_id" >&2
    # A half-booted candidate keeps its processes alive and shrinks the
    # process budget for every later candidate — release it before moving on.
    _skybridge_run_command_with_timeout \
      "$boot_timeout_seconds" /dev/null \
      "$xcrun_bin" simctl shutdown "$candidate_id" || true
    if grep -q "insufficient system resources" "$boot_log_file"; then
      # The host refuses to boot ANY simulator (per-user process limit
      # exhausted). That verdict is host-wide, not per-device: scanning the
      # remaining candidates would burn the boot timeout on each one and
      # cannot succeed. Fail fast with the host diagnostics instead.
      echo "$log_prefix aborting simulator scan: the host cannot boot any simulator (user process limit exhausted); raise the process limits (launchctl limit maxproc / kern.maxprocperuid) or free user processes, then retry." >&2
      cat "$boot_log_file" >&2
      cleanup_ios_simulator_selection
      return 1
    fi
  done <"$candidates_file"

  if [[ -s "$boot_log_file" ]]; then
    cat "$boot_log_file" >&2
  fi
  if [[ -n "$requested_id" ]]; then
    echo "$log_prefix explicitly requested simulator is not bootable: $requested_id" >&2
  else
    echo "$log_prefix no listed iPhone simulator completed boot readiness." >&2
  fi
  cleanup_ios_simulator_selection
  return 1
}
