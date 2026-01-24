#!/usr/bin/env bash
set -euo pipefail

theory="skybridge_minimal.spthy"

if ! command -v tamarin-prover >/dev/null 2>&1; then
  echo "ERROR: tamarin-prover not found on PATH." >&2
  echo "Install Tamarin and rerun. See: https://tamarin-prover.github.io/" >&2
  exit 2
fi

mkdir -p tamarin-report

echo "== Running Tamarin: ${theory} =="
tamarin-prover "${theory}" \
  --prove \
  --output-dir tamarin-report

echo
echo "== Done =="
echo "Report: formal/tamarin-report/"


