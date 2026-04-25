#!/usr/bin/env bash
set -euo pipefail

GATE_NAME="release_readiness"
GATE_DOMAIN="release-readiness"
source "$(cd "$(dirname "$0")" && pwd)/_gate_common.sh"

run_check_strict_no_warnings \
  "source-quality" \
  "code" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/gates/source_quality_gate.sh"

run_check_strict_no_warnings \
  "macos-release-readiness" \
  "release" \
  "release-readiness" \
  env SKYBRIDGE_RELEASE_GATE_REQUIRE_NOTARIZATION=1 \
    bash "${ROOT_DIR}/Scripts/check_macos_release_readiness.sh" --require-notarization

run_check_strict_no_warnings \
  "supabase-auth-readiness" \
  "auth" \
  "release-readiness" \
  bash "${ROOT_DIR}/Scripts/check_supabase_auth_readiness.sh" --require-captcha

finalize_gate_report
