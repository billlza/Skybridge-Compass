#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_PATH="$ROOT_DIR/packaging/homebrew/skybridge.rb.template"
OUTPUT_PATH="${1:-$ROOT_DIR/packaging/homebrew/skybridge.rb}"

: "${SKYBRIDGE_VERSION:?set SKYBRIDGE_VERSION}"
: "${SKYBRIDGE_DARWIN_ARM64_SHA256:?set SKYBRIDGE_DARWIN_ARM64_SHA256}"

RELEASE_BASE_URL="${SKYBRIDGE_RELEASE_BASE_URL:-https://github.com/billlza/Skybridge-Compass/releases/download/skybridge-cli-v${SKYBRIDGE_VERSION}}"

sed \
  -e "s|__VERSION__|${SKYBRIDGE_VERSION}|g" \
  -e "s|__BASE_URL__|${RELEASE_BASE_URL}|g" \
  -e "s|__DARWIN_ARM64_SHA256__|${SKYBRIDGE_DARWIN_ARM64_SHA256}|g" \
  "$TEMPLATE_PATH" > "$OUTPUT_PATH"

echo "rendered Homebrew formula to $OUTPUT_PATH"
