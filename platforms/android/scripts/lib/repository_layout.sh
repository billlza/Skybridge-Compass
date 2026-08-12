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
