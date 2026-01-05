#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"

matches=$(find "$ROOT_DIR" -type f \
  \( -name '*.p12' -o -name '*.pfx' -o -name '*.cer' -o -name '*.crt' -o -name '*.pem' -o -name '*.key' -o -name '*.mobileprovision' \) \
  -print)

if [ -n "$matches" ]; then
  echo "Sensitive artifacts detected:"
  echo "$matches"
  exit 1
fi

echo "OK: no sensitive artifacts found."
