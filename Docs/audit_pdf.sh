#!/usr/bin/env bash
set -euo pipefail

DOCS_DIR="${1:-/Users/bill/Desktop/SkyBridge Compass Pro release/Docs}"
MAIN="IEEE_Paper_SkyBridge_Compass_patched.tex"
SUPP="TDSC-2026-01-0318_supplementary.tex"
SUPP_LOG="TDSC-2026-01-0318_supplementary.log"

cd "$DOCS_DIR"

echo "== build main (creates/updates main .aux) =="
latexmk -pdf -interaction=nonstopmode -halt-on-error "$MAIN" >/tmp/skybridge_main.out 2>&1

echo "== build supplementary (imports main labels if main .aux exists) =="
latexmk -pdf -interaction=nonstopmode -halt-on-error "$SUPP" >/tmp/skybridge_supp.out 2>&1

echo "== force rebuild main (imports supplementary labels if TDSC-2026-01-0318_supplementary.aux exists) =="
latexmk -g -pdf -interaction=nonstopmode -halt-on-error "$MAIN" >/tmp/skybridge_main2.out 2>&1

echo "== scan logs for desk-reject risks (errors/undefined refs/overfull) =="
fail=0
for log in "IEEE_Paper_SkyBridge_Compass_patched.log" "$SUPP_LOG"; do
  echo "-- $log --"
  if rg -n "! LaTeX Error|Undefined control sequence|There were undefined references|LaTeX Warning: Reference" "$log"; then
    fail=1
  fi
  if rg -n "Overfull" "$log"; then
    fail=1
  fi
  echo
done

echo "== outputs =="
ls -lh IEEE_Paper_SkyBridge_Compass_patched.pdf TDSC-2026-01-0318_supplementary.pdf

if [[ "$fail" -ne 0 ]]; then
  echo "AUDIT_FAIL"
  exit 2
fi

echo "AUDIT_OK"


