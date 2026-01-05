#!/bin/zsh
set -euo pipefail

root_dir="$SRCROOT/Sources"
violations=()

while IFS= read -r -d '' f; do
  awk '
    BEGIN{debug=0}
    /#if[[:space:]]+DEBUG/{debug=1}
    /#endif/{debug=0}
    /print\(/{ if (debug==0) { printf("%s:%d\n", FILENAME, NR) } }
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