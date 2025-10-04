#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

python3 - <<'PY'
import pathlib
import subprocess
import sys
import re

repo_root = pathlib.Path('.').resolve()
diff = subprocess.run(
    ["git", "diff", "HEAD", "--unified=0"],
    check=True,
    text=True,
    capture_output=True,
).stdout.splitlines()
file_lines = {}
current_path = None
current_line = 0
hunk_pattern = re.compile(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
for line in diff:
    if line.startswith('+++ b/'):
        path = line[6:]
        if path == '/dev/null':
            current_path = None
        else:
            current_path = repo_root / path
            file_lines.setdefault(current_path, set())
        current_line = 0
    elif line.startswith('@@'):
        if current_path is None:
            continue
        match = hunk_pattern.match(line)
        if not match:
            continue
        start = int(match.group(1))
        length = int(match.group(2) or '1')
        current_line = start
    elif current_path is not None:
        if line.startswith('+') and not line.startswith('+++'):
            file_lines[current_path].add(current_line)
            current_line += 1
        elif line.startswith('-') and not line.startswith('---'):
            continue
        else:
            current_line += 1

# remove entries with no tracked lines
file_lines = {path: lines for path, lines in file_lines.items() if lines}
if not file_lines:
    print('No Kotlin changes detected; skipping static analysis.')
    sys.exit(0)

violations = []
for path, lines in file_lines.items():
    if path.suffix not in {'.kt', '.kts'}:
        continue
    try:
        text = path.read_text(encoding='utf-8').splitlines()
    except Exception as exc:
        violations.append((path, f'read error: {exc}'))
        continue
    for line_no in lines:
        if line_no <= 0 or line_no > len(text):
            continue
        content = text[line_no - 1]
        if content.rstrip() != content:
            violations.append((path, f'trailing whitespace on line {line_no}'))
        if 'TODO' in content:
            violations.append((path, f'TODO marker on line {line_no}'))

if violations:
    for path, message in violations:
        print(f"{path.relative_to(repo_root)}: {message}")
    sys.exit(1)

print('Static analysis checks passed without issues.')
PY
