#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

MAIN_TEX="Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.tex"
TARGETS=(
  "Docs/tdsc_submission/paper.tex"
  "Docs/tdsc_submission/TDSC-2026-01-0318_paper.tex"
)

if [[ ! -f "$MAIN_TEX" ]]; then
  echo "missing source-of-truth tex: $MAIN_TEX" >&2
  exit 1
fi

for target in "${TARGETS[@]}"; do
  if [[ ! -f "$target" ]]; then
    echo "missing submission tex target: $target" >&2
    exit 1
  fi

  if cmp -s "$MAIN_TEX" "$target"; then
    echo "unchanged: $target"
    continue
  fi

  cp "$MAIN_TEX" "$target"
  echo "synced: $target"
done

echo "source-of-truth: $MAIN_TEX"
