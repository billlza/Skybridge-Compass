#!/usr/bin/env bash
set -euo pipefail

GATE_NAME="release_readiness"
GATE_DOMAIN="release-readiness"
source "$(cd "$(dirname "$0")" && pwd)/_gate_common.sh"

run_check_allow_warnings \
  "source-quality" \
  "code" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/gates/source_quality_gate.sh"

run_check_allow_warnings \
  "paper-integrity" \
  "paper" \
  "paper-integrity" \
  bash "${ROOT_DIR}/Scripts/gates/paper_integrity_gate.sh"

run_check_allow_warnings \
  "macos-release-readiness" \
  "release" \
  "release-readiness" \
  bash "${ROOT_DIR}/Scripts/check_macos_release_readiness.sh"

run_check_allow_warnings \
  "supabase-auth-readiness" \
  "auth" \
  "release-readiness" \
  bash "${ROOT_DIR}/Scripts/check_supabase_auth_readiness.sh" --require-captcha

finalize_gate_report
