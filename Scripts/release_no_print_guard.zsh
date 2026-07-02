#!/bin/zsh
set -euo pipefail

if [[ -z "${SRCROOT:-}" ]]; then
  echo "[FAIL] SRCROOT is required" >&2
  exit 2
fi

root_dir="${SRCROOT%/}/Sources"
if [[ ! -d "$root_dir" ]]; then
  echo "[FAIL] Sources directory not found: $root_dir" >&2
  exit 2
fi

violations=()
# These targets are executable diagnostics or benchmarks; stdout is their user-facing contract.
excluded_targets=(
  BaselineBenchRunner
  CurrentPathProbe
  HandshakeBenchRunner
  MacUIBaselineCapture
  MessageSizeBenchRunner
)

is_excluded_target_path() {
  local path="$1"
  local target=""
  for target in "${excluded_targets[@]}"; do
    if [[ "$path" == "$root_dir/$target/"* ]]; then
      return 0
    fi
  done
  return 1
}

while IFS= read -r -d '' f; do
  if is_excluded_target_path "$f"; then
    continue
  fi
  awk '
    function condition_is_debug(line, cond) {
      cond = line
      sub(/^[[:space:]]*#[[:space:]]*(if|elseif)[[:space:]]+/, "", cond)
      return cond ~ /(^|[^[:alnum:]_!])DEBUG([^[:alnum:]_]|$)/
    }
    function push_debug(enabled) {
      depth += 1
      debug_stack[depth] = enabled
    }
    function current_is_debug(i) {
      for (i = 1; i <= depth; i++) {
        if (debug_stack[i]) {
          return 1
        }
      }
      return 0
    }
    BEGIN{depth=0}
    /^[[:space:]]*#[[:space:]]*if[[:space:]]+/ {
      push_debug(condition_is_debug($0))
      next
    }
    /^[[:space:]]*#[[:space:]]*elseif[[:space:]]+/ {
      if (depth > 0) {
        debug_stack[depth] = condition_is_debug($0)
      }
      next
    }
    /^[[:space:]]*#[[:space:]]*else([[:space:]]|$)/ {
      if (depth > 0) {
        debug_stack[depth] = 0
      }
      next
    }
    /^[[:space:]]*#[[:space:]]*endif([[:space:]]|$)/ {
      if (depth > 0) {
        delete debug_stack[depth]
        depth -= 1
      }
      next
    }
    /(^|[^[:alnum:]_])print[[:space:]]*\(/ {
      if (!current_is_debug()) {
        printf("%s:%d\n", FILENAME, NR)
      }
    }
  ' "$f" | while read -r line; do
    violations+=("$line")
  done
done < <(find "$root_dir" -type f -name '*.swift' -not -path '*/Tests/*' -print0)

if [[ ${#violations[@]} -gt 0 ]]; then
  echo "[FAIL] 发现未包裹 #if DEBUG 的 print："
  printf '%s\n' "${violations[@]}"
  exit 1
fi

echo "[OK] Release 下 Sources 无违规 print"
