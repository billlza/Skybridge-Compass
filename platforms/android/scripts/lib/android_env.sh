#!/usr/bin/env bash

# Resolve Android SDK tools from the local machine without requiring callers
# to preconfigure PATH. Prefer an existing PATH adb, then local.properties,
# then common macOS SDK locations.

resolve_adb_bin() {
  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return 0
  fi

  local root_dir="${1:-}"
  local candidate=""
  local sdk_dir=""

  if [[ -n "$root_dir" && -f "$root_dir/local.properties" ]]; then
    sdk_dir="$(
      sed -n 's/^sdk\\.dir=//p' "$root_dir/local.properties" \
        | sed 's#\\\\:#:#g' \
        | head -n 1
    )"
    if [[ -n "$sdk_dir" && -x "$sdk_dir/platform-tools/adb" ]]; then
      printf '%s\n' "$sdk_dir/platform-tools/adb"
      return 0
    fi
  fi

  for candidate in \
    "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
    "${ANDROID_HOME:-}/platform-tools/adb" \
    "$HOME/Library/Android/sdk/platform-tools/adb" \
    "$HOME/Android/Sdk/platform-tools/adb"
  do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}
