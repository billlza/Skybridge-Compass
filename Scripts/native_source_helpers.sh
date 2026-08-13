#!/usr/bin/env bash

# Prepare a clean detached checkout at an immutable, reviewed commit. The human
# readable ref is recorded for provenance only; the full commit is authoritative.
skybridge_prepare_pinned_native_source() {
  local repository="$1" ref="$2" expected_commit="$3" destination="$4"
  local actual_commit="" actual_remote="" dirty=""

  if [[ -d "$destination/.git" ]]; then
    actual_commit="$(git -C "$destination" rev-parse HEAD 2>/dev/null || true)"
    actual_remote="$(git -C "$destination" remote get-url origin 2>/dev/null || true)"
    dirty="$(git -C "$destination" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
  fi
  if [[ "$actual_commit" == "$expected_commit" && "$actual_remote" == "$repository" && -z "$dirty" ]]; then
    return 0
  fi

  rm -rf "$destination"
  mkdir -p "$(dirname "$destination")"
  git init -q "$destination"
  git -C "$destination" remote add origin "$repository"
  git -C "$destination" fetch -q --depth 1 origin "$expected_commit"
  git -C "$destination" checkout -q --detach FETCH_HEAD

  actual_commit="$(git -C "$destination" rev-parse HEAD)"
  [[ "$actual_commit" == "$expected_commit" ]] || {
    echo "native source ${ref} resolved to unexpected commit: ${actual_commit}" >&2
    return 1
  }
  [[ -z "$(git -C "$destination" status --porcelain=v1 --untracked-files=all)" ]] || {
    echo "prepared native source checkout is dirty: ${destination}" >&2
    return 1
  }
}
