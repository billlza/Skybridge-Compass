#!/usr/bin/env bash
set -euo pipefail

GATE_NAME="paper_integrity"
GATE_DOMAIN="paper-integrity"
source "$(cd "$(dirname "$0")" && pwd)/_gate_common.sh"

run_check_strict_no_warnings \
  "isolated-paper-compile" \
  "paper" \
  "paper-integrity" \
  bash "${ROOT_DIR}/Scripts/gates/_run_isolated_paper_compile.sh"

run_check_strict_no_warnings \
  "paper-consistency" \
  "paper" \
  "paper-integrity" \
  bash "${ROOT_DIR}/Scripts/check_paper_consistency.sh"

run_check_strict_no_warnings \
  "numeric-consistency" \
  "paper" \
  "paper-integrity" \
  python3 "${ROOT_DIR}/Scripts/check_numeric_consistency.py" --artifact-date "${ARTIFACT_DATE}"

run_check_strict_no_warnings \
  "claim-guardrails" \
  "paper" \
  "paper-integrity" \
  python3 "${ROOT_DIR}/Scripts/check_claim_guardrails.py" --artifact-date "${ARTIFACT_DATE}"

run_check_strict_no_warnings \
  "claim-traceability" \
  "paper" \
  "paper-integrity" \
  python3 "${ROOT_DIR}/Scripts/check_claim_traceability.py"

finalize_gate_report
