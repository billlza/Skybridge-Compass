#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
ALLOWLIST_RE='(^|/)Tests/Fixtures/loopback_(cert\.pem|key\.pem|identity\.p12)$'

collect_candidate_files() {
  if git -C "$ROOT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$ROOT_DIR" ls-files -z
    return 0
  fi

  find "$ROOT_DIR" -type f \
    ! -path '*/.build/*' \
    ! -path '*/node_modules/*' \
    ! -path '*/SourcePackages/*' \
    -print0
}

matches=$(
  collect_candidate_files \
    | python3 - "$ROOT_DIR" "$ALLOWLIST_RE" <<'PY'
import os
import re
import sys

root_dir = os.path.abspath(sys.argv[1])
allowlist = re.compile(sys.argv[2])
sensitive_suffixes = (".p12", ".pfx", ".cer", ".crt", ".pem", ".key", ".mobileprovision")

raw = sys.stdin.buffer.read().split(b"\0")
matches = []
for item in raw:
    if not item:
        continue
    path = item.decode("utf-8")
    if not os.path.isabs(path):
        path = os.path.join(root_dir, path)
    rel_path = os.path.relpath(path, root_dir).replace(os.sep, "/")
    if not rel_path.endswith(sensitive_suffixes):
        continue
    if allowlist.search(rel_path):
        continue
    matches.append(rel_path)

if matches:
    print("\n".join(sorted(matches)))
PY
)

if [ -n "$matches" ]; then
  echo "Sensitive artifacts detected:"
  echo "$matches"
  exit 1
fi

echo "OK: no sensitive artifacts found."
