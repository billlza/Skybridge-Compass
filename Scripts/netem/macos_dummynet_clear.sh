#!/usr/bin/env bash
set -euo pipefail

PIPE_ID="${PIPE_ID:-1}"
ANCHOR="${ANCHOR:-skybridge_kernel_emu}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipe-id) PIPE_ID="$2"; shift 2 ;;
    --anchor) ANCHOR="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

sudo pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
sudo dnctl -q delete pipe "$PIPE_ID" >/dev/null 2>&1 || true

echo "Cleared dummynet settings pipe=$PIPE_ID anchor=$ANCHOR"
