#!/usr/bin/env bash

skybridge_canonical_release_root() {
  local android_root="$1"
  local physical_android_root
  local git_root
  physical_android_root="$(cd "$android_root" && pwd -P)" || return 1
  git_root="$(git -C "$physical_android_root" rev-parse --show-toplevel)" || {
    echo "Android source is not inside a Git worktree: $physical_android_root" >&2
    return 1
  }
  git_root="$(cd "$git_root" && pwd -P)" || return 1
  if [[ "$physical_android_root" != "$git_root/platforms/android" ]]; then
    echo "Android source is not bound to <release-repo>/platforms/android: $physical_android_root" >&2
    return 1
  fi
  if [[ ! -f "$git_root/Package.swift" || ! -f "$git_root/project.yml" ]]; then
    echo "Release worktree is missing Apple source markers: $git_root" >&2
    return 1
  fi
  git -C "$git_root" rev-parse --verify HEAD >/dev/null || return 1
  printf '%s\n' "$git_root"
}

skybridge_require_release_repo_root() {
  local candidate="$1"
  local physical_candidate
  local git_root
  physical_candidate="$(cd "$candidate" && pwd -P)" || {
    echo "Release repo path not found: $candidate" >&2
    return 1
  }
  git_root="$(git -C "$physical_candidate" rev-parse --show-toplevel)" || {
    echo "Release repo path is not a Git worktree: $physical_candidate" >&2
    return 1
  }
  git_root="$(cd "$git_root" && pwd -P)" || return 1
  if [[ "$physical_candidate" != "$git_root" ]]; then
    echo "Release repo path must be the Git worktree root: $physical_candidate" >&2
    return 1
  fi
  if [[ ! -f "$git_root/Package.swift" || ! -f "$git_root/project.yml" ]]; then
    echo "Release repo is missing Package.swift or project.yml: $git_root" >&2
    return 1
  fi
  git -C "$git_root" rev-parse --verify HEAD >/dev/null || return 1
  printf '%s\n' "$git_root"
}

skybridge_require_ios_project_dir() {
  local candidate="$1"
  local physical_candidate
  local git_root
  physical_candidate="$(cd "$candidate" && pwd -P)" || {
    echo "iOS project directory not found: $candidate" >&2
    return 1
  }
  git_root="$(git -C "$physical_candidate" rev-parse --show-toplevel)" || {
    echo "iOS project directory is not inside a Git worktree: $physical_candidate" >&2
    return 1
  }
  git_root="$(cd "$git_root" && pwd -P)" || return 1
  if [[ "$physical_candidate" != "$git_root/SkyBridge Compass iOS" ]]; then
    echo "iOS project must be bound to <release-repo>/SkyBridge Compass iOS" >&2
    return 1
  fi
  if [[ ! -d "$physical_candidate/SkyBridgeCompass-iOS.xcodeproj" ]]; then
    echo "iOS Xcode project is missing from $physical_candidate" >&2
    return 1
  fi
  git -C "$git_root" rev-parse --verify HEAD >/dev/null || return 1
  printf '%s\n' "$physical_candidate"
}

skybridge_append_git_source_binding() {
  local output_file="$1"
  local field_prefix="$2"
  local source_path="$3"
  local git_root
  local git_branch
  local git_clean="true"
  if [[ ! "$field_prefix" =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo "Invalid source-binding field prefix: $field_prefix" >&2
    return 1
  fi
  git_root="$(git -C "$source_path" rev-parse --show-toplevel)" || return 1
  git_root="$(cd "$git_root" && pwd -P)" || return 1
  git_branch="$(git -C "$git_root" rev-parse --abbrev-ref HEAD)" || return 1
  if [[ -n "$(git -C "$git_root" status --porcelain --untracked-files=all)" ]]; then
    git_clean="false"
  fi
  {
    echo "${field_prefix}_git_root=$git_root"
    echo "${field_prefix}_git_head=$(git -C "$git_root" rev-parse --verify HEAD)"
    echo "${field_prefix}_git_branch=$git_branch"
    echo "${field_prefix}_git_clean=$git_clean"
  } >>"$output_file"
}

skybridge_require_frozen_git_source() {
  local source_path="$1"
  local expected_commit="$2"
  local phase="$3"
  local git_root=""
  local actual_commit=""
  local worktree_status=""

  if [[ ! "$expected_commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Expected source commit must be a full lowercase Git revision during $phase" >&2
    return 1
  fi
  git_root="$(git -C "$source_path" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Unable to resolve the Git worktree during $phase" >&2
    return 1
  }
  actual_commit="$(git -C "$git_root" rev-parse --verify HEAD 2>/dev/null)" || {
    echo "Unable to resolve the source revision during $phase" >&2
    return 1
  }
  if [[ "$actual_commit" != "$expected_commit" ]]; then
    echo "Source revision changed or does not match during $phase" >&2
    return 1
  fi
  worktree_status="$(git -C "$git_root" status --porcelain=v1 --untracked-files=all)" || {
    echo "Unable to inspect the source tree during $phase" >&2
    return 1
  }
  if [[ -n "$worktree_status" ]]; then
    echo "Physical interop evidence requires a clean frozen source tree during $phase" >&2
    return 1
  fi
}

skybridge_collect_frozen_git_binding() {
  local source_path="$1"
  local expected_commit="$2"
  local phase="$3"
  local git_root=""
  local tree_oid=""

  case "$phase" in
    before|after) ;;
    *) echo "Frozen source phase must be before or after" >&2; return 1 ;;
  esac
  skybridge_require_frozen_git_source \
    "$source_path" "$expected_commit" "source binding $phase" || return 1
  git_root="$(git -C "$source_path" rev-parse --show-toplevel)" || return 1
  tree_oid="$(git -C "$git_root" rev-parse "${expected_commit}^{tree}")" || return 1
  if [[ ! "$tree_oid" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Frozen source tree identity is malformed" >&2
    return 1
  fi
  printf '%s\n' \
    "schema_version=1" \
    "phase=$phase" \
    "source_commit=$expected_commit" \
    "source_tree=$tree_oid" \
    "worktree_clean=true"
}

skybridge_acquire_device_lock() {
  local source_path="$1"
  local device_kind="$2"
  local device_identifier="$3"
  local common_git_dir=""
  local identifier_digest=""
  local lock_dir=""

  if [[ ! "$device_kind" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || [[ -z "$device_identifier" ]]; then
    echo "Invalid device lock identity" >&2
    return 1
  fi
  common_git_dir="$(git -C "$source_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
    echo "Unable to resolve the common Git directory for the device lock" >&2
    return 1
  }
  if [[ "$common_git_dir" != /* || ! -d "$common_git_dir" || -L "$common_git_dir" ]]; then
    echo "The common Git directory is not a trusted absolute directory" >&2
    return 1
  fi
  identifier_digest="$(python3 - "$device_identifier" <<'PY'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())
PY
)" || return 1
  lock_dir="$common_git_dir/skybridge-${device_kind}-${identifier_digest}.lock"
  if ! mkdir -m 0700 -- "$lock_dir" 2>/dev/null; then
    echo "Another smoke run owns the $device_kind device lock" >&2
    return 1
  fi
  printf '%s\n' "$lock_dir"
}

skybridge_release_device_lock() {
  local lock_dir="$1"
  if [[ -z "$lock_dir" ]]; then
    return 0
  fi
  if [[ "$lock_dir" != /* || "$lock_dir" != *.lock || ! -d "$lock_dir" || -L "$lock_dir" ]]; then
    echo "Refusing to release an invalid device lock" >&2
    return 1
  fi
  rmdir -- "$lock_dir"
}
