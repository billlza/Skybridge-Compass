#!/usr/bin/env bash

skybridge_require_zero_warning_tool_log() {
  local log_path="$1"
  [[ -f "$log_path" ]] || {
    echo "strict tool-output scan is missing its log: $log_path" >&2
    return 2
  }

  local matches
  local scan_status
  if matches="$(LC_ALL=C rg -n -i \
      '(^|[[:space:]])warning:|^w: |deprecated gradle features were used|self-attach|dynamically loaded agent|dynamic loading of agents|slf4j:' \
      "$log_path" 2>&1)"; then
    scan_status=0
  else
    scan_status=$?
  fi
  case "$scan_status" in
    0)
      printf '%s\n' "$matches" >&2
      echo "tool output contains a warning: $log_path" >&2
      return 1
      ;;
    1)
      return 0
      ;;
    *)
      printf '%s\n' "$matches" >&2
      echo "strict tool-output scan failed: $log_path" >&2
      return 2
      ;;
  esac
}
