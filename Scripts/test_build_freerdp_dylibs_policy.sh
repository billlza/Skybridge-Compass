#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_SCRIPT="${ROOT_DIR}/Scripts/build_freerdp_dylibs.sh"

fail() {
  echo "[test-freerdp-dylibs-policy] $1" >&2
  exit 1
}

require_contains() {
  local needle="$1"
  grep -Fq "$needle" "$TARGET_SCRIPT" \
    || fail "missing required source contract: ${needle}"
}

require_absent() {
  local needle="$1"
  if grep -Fq "$needle" "$TARGET_SCRIPT"; then
    fail "forbidden direct vendor mutation remains: ${needle}"
  fi
}

line_number() {
  local needle="$1"
  grep -nF "$needle" "$TARGET_SCRIPT" | head -1 | cut -d: -f1
}

require_contains 'STAGE_DIR="$WORK_DIR/stage-$ARCH"'
require_contains 'rm -rf "$STAGE_DIR"; mkdir -p "$STAGE_DIR"'
require_contains 'env -u SKYBRIDGE_FILE_TOOL -u SKYBRIDGE_OTOOL_TOOL'
require_contains 'bash "$ROOT/Scripts/check_macos_deps.sh" --strict "$STAGE_DIR" "$DEPLOYMENT_TARGET"'
require_contains 'mv "$STAGE_DIR" "$OUT_DIR"'
require_contains 'do not rewrite Mach-O minos metadata as a compatibility substitute'
require_contains '\( -type f -o -type l \)'

require_absent 'cp -f "$f" "$OUT_DIR/'
require_absent 'cp -f "$src" "$OUT_DIR/'
require_absent 'for dst in "$OUT_DIR"/*.dylib'

gate_line="$(line_number 'bash "$ROOT/Scripts/check_macos_deps.sh" --strict "$STAGE_DIR" "$DEPLOYMENT_TARGET"')"
publish_delete_line="$(line_number 'rm -rf "$OUT_DIR"')"
publish_move_line="$(line_number 'mv "$STAGE_DIR" "$OUT_DIR"')"

[[ -n "$gate_line" && -n "$publish_delete_line" && -n "$publish_move_line" ]] \
  || fail "could not resolve source contract line numbers"

if (( gate_line >= publish_delete_line || gate_line >= publish_move_line )); then
  fail "deployment-target gate must run before replacing Sources/Vendor/FreeRDPDylibs"
fi

echo "[test-freerdp-dylibs-policy] passed"
