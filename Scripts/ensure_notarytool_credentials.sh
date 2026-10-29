#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
source "${PROJECT_ROOT}/Scripts/notarytool_helpers.sh"

PROFILE_NAME="${NOTARYTOOL_KEYCHAIN_PROFILE:-skybridge-notary}"
AUTO_BOOTSTRAP="${SKYBRIDGE_AUTO_BOOTSTRAP_NOTARYTOOL:-1}"

log() {
  echo "[ensure-notary] $1"
}

fail() {
  echo "[ensure-notary] ERROR: $1" >&2
  exit 1
}

bootstrap_args=()
if [[ -n "${PROFILE_NAME}" ]]; then
  bootstrap_args+=(--profile-name "${PROFILE_NAME}")
fi
if [[ -n "${SKYBRIDGE_NOTARYTOOL_ENV_FILE:-}" ]]; then
  bootstrap_args+=(--env-file "${SKYBRIDGE_NOTARYTOOL_ENV_FILE}")
fi
if [[ -n "${APPLE_ID:-}" ]]; then
  bootstrap_args+=(--apple-id "${APPLE_ID}")
fi
if [[ -n "${NOTARYTOOL_KEY:-}" ]]; then
  bootstrap_args+=(--key "${NOTARYTOOL_KEY}")
fi
if [[ -n "${NOTARYTOOL_KEY_ID:-}" ]]; then
  bootstrap_args+=(--key-id "${NOTARYTOOL_KEY_ID}")
fi
if [[ -n "${NOTARYTOOL_ISSUER:-}" ]]; then
  bootstrap_args+=(--issuer "${NOTARYTOOL_ISSUER}")
fi

if skybridge_notarytool_validate_credentials; then
  log "检测到可用的 notarization 凭据，继续发布。"
  exit 0
fi

if [[ "${AUTO_BOOTSTRAP}" != "1" ]]; then
  fail "notarization 凭据不可用，且 SKYBRIDGE_AUTO_BOOTSTRAP_NOTARYTOOL=${AUTO_BOOTSTRAP}。"
fi

log "当前 notarization 凭据缺失或不可用，开始自动 bootstrap..."
"${PROJECT_ROOT}/Scripts/bootstrap_notarytool_credentials.sh" "${bootstrap_args[@]}"

unset SKYBRIDGE_NOTARYTOOL_ENV_LOADED || true

if skybridge_notarytool_validate_credentials; then
  log "bootstrap 成功，notarization 凭据已就绪。"
  exit 0
fi

fail "bootstrap 后 notarization 凭据仍不可用。"
