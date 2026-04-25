#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Bootstrap local Apple notarization credentials for SkyBridge.

This script:
  1. Locates the local App Store Connect API key (.p8)
  2. Uses the current App Store Connect session to resolve the provider/issuer UUID
  3. Validates credentials with `xcrun notarytool history`
  4. Stores a reusable notarytool keychain profile
  5. Writes a local env file that existing release scripts can auto-load

Usage:
  ./Scripts/bootstrap_notarytool_credentials.sh [options]

Options:
  --apple-id <apple-id>         Apple ID used for App Store Connect session lookup
  --key <path>                  App Store Connect API key path (.p8)
  --key-id <id>                 App Store Connect API key ID
  --issuer <uuid>               Skip lookup and use the provided issuer UUID
  --profile-name <name>         notarytool keychain profile name
                                Default: skybridge-notary
  --env-file <path>             Output env file path
                                Default: ~/.config/skybridge/notarytool.env
  --keychain <path>             Keychain file for `notarytool store-credentials`
                                Default: ~/Library/Keychains/login.keychain-db
  --skip-store                  Do not write keychain profile
  --skip-env                    Do not write env file
  --no-validate                 Skip `notarytool history` preflight validation
  -h, --help                    Show help
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

APPLE_ID="${APPLE_ID:-}"
NOTARY_KEY_PATH="${NOTARYTOOL_KEY:-}"
NOTARY_KEY_ID="${NOTARYTOOL_KEY_ID:-}"
NOTARY_ISSUER="${NOTARYTOOL_ISSUER:-}"
PROFILE_NAME="${NOTARYTOOL_KEYCHAIN_PROFILE:-skybridge-notary}"
ENV_FILE="${SKYBRIDGE_NOTARYTOOL_ENV_FILE:-$HOME/.config/skybridge/notarytool.env}"
KEYCHAIN_PATH="${HOME}/Library/Keychains/login.keychain-db"
SKIP_STORE=0
SKIP_ENV=0
VALIDATE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apple-id)
      APPLE_ID="${2:-}"
      shift 2
      ;;
    --key)
      NOTARY_KEY_PATH="${2:-}"
      shift 2
      ;;
    --key-id)
      NOTARY_KEY_ID="${2:-}"
      shift 2
      ;;
    --issuer)
      NOTARY_ISSUER="${2:-}"
      shift 2
      ;;
    --profile-name)
      PROFILE_NAME="${2:-}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --keychain)
      KEYCHAIN_PATH="${2:-}"
      shift 2
      ;;
    --skip-store)
      SKIP_STORE=1
      shift
      ;;
    --skip-env)
      SKIP_ENV=1
      shift
      ;;
    --no-validate)
      VALIDATE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage
      exit 1
      ;;
  esac
done

log() {
  echo "[bootstrap-notary] $1"
}

fail() {
  echo "[bootstrap-notary] ERROR: $1" >&2
  exit 1
}

discover_apple_id() {
  if [[ -n "${APPLE_ID}" ]]; then
    printf '%s\n' "${APPLE_ID}"
    return 0
  fi

  local appfile="${PROJECT_ROOT}/fastlane/Appfile"
  local value=""
  if [[ -f "${appfile}" ]]; then
    value="$(sed -n "s/^apple_id(\"\\([^\"]*\\)\").*/\\1/p" "${appfile}" | head -n 1)"
    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
  fi

  local spaceship_dir="${HOME}/.fastlane/spaceship"
  if [[ -d "${spaceship_dir}" ]]; then
    value="$(find "${spaceship_dir}" -mindepth 1 -maxdepth 1 -type d -print | awk -F/ '/@/ {print $NF; exit}')"
    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
  fi

  fail "无法自动识别 Apple ID，请使用 --apple-id 显式指定。"
}

discover_api_key_path() {
  local path=""

  if [[ -n "${NOTARY_KEY_PATH}" ]]; then
    [[ -f "${NOTARY_KEY_PATH}" ]] || fail "指定的 API key 不存在: ${NOTARY_KEY_PATH}"
    printf '%s\n' "${NOTARY_KEY_PATH}"
    return 0
  fi

  if [[ -n "${NOTARY_KEY_ID}" ]]; then
    path="${HOME}/.appstoreconnect/private_keys/AuthKey_${NOTARY_KEY_ID}.p8"
    [[ -f "${path}" ]] || fail "未找到与 key id 匹配的 API key: ${path}"
    printf '%s\n' "${path}"
    return 0
  fi

  local matches=()
  while IFS= read -r file; do
    matches+=("${file}")
  done < <(find "${HOME}/.appstoreconnect/private_keys" -maxdepth 1 -type f -name 'AuthKey_*.p8' 2>/dev/null | sort)

  if [[ "${#matches[@]}" -eq 1 ]]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  if [[ "${#matches[@]}" -eq 0 ]]; then
    fail "未找到任何 App Store Connect API key（~/.appstoreconnect/private_keys/AuthKey_*.p8）。"
  fi

  fail "检测到多把 API key，请使用 --key 或 --key-id 明确指定。"
}

infer_key_id_from_path() {
  local path="$1"
  local base
  base="$(basename "${path}")"
  if [[ "${base}" =~ ^AuthKey_([A-Z0-9]+)\.p8$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  fail "无法从文件名推断 key id：${path}"
}

detect_fastlane_ruby() {
  local fastlane_bin real_bin ruby_bin libexec_dir wrapped_bin
  fastlane_bin="$(command -v fastlane || true)"
  [[ -n "${fastlane_bin}" ]] || fail "未找到 fastlane，请先安装 fastlane。"

  real_bin="$(python3 - <<'PY' "${fastlane_bin}"
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
)"
  if [[ -f "${real_bin}" ]]; then
    wrapped_bin="$(sed -n 's/.*exec "\(.*\/libexec\/bin\/fastlane\)".*/\1/p' "${real_bin}" | head -n 1)"
    if [[ -n "${wrapped_bin}" && -f "${wrapped_bin}" ]]; then
      real_bin="${wrapped_bin}"
    fi
  fi
  ruby_bin="$(sed -n '1s/^#!//p' "${real_bin}")"
  [[ -x "${ruby_bin}" ]] || fail "无法从 fastlane shebang 识别 Ruby 运行时：${ruby_bin}"
  libexec_dir="$(cd "$(dirname "${real_bin}")/.." && pwd)"
  if [[ ! -d "${libexec_dir}/gems" ]]; then
    libexec_dir="$(cd "$(dirname "${real_bin}")/../libexec" && pwd)"
  fi
  [[ -d "${libexec_dir}/gems" ]] || fail "fastlane libexec 目录异常：${libexec_dir}"

  printf '%s\n%s\n' "${ruby_bin}" "${libexec_dir}"
}

resolve_issuer_via_spaceship() {
  local apple_id="$1"
  local key_id="$2"
  local ruby_bin="$3"
  local libexec_dir="$4"

  (
    export GEM_HOME="${libexec_dir}"
    export GEM_PATH="${libexec_dir}"
    "${ruby_bin}" - "${apple_id}" "${key_id}" <<'RUBY'
require 'json'
require 'spaceship'

apple_id = ARGV[0]
key_id = ARGV[1]

Spaceship::ConnectAPI.login(apple_id, nil, use_portal: false, use_tunes: true, skip_select_team: true)
client = Spaceship::ConnectAPI.client
rc = client.tunes_request_client

api_keys = rc.get('v1/apiKeys').body.fetch('data')
key = api_keys.find { |item| item['id'] == key_id }
abort("未在 App Store Connect 中找到 API key: #{key_id}") if key.nil?

provider = rc.get("v1/apiKeys/#{key_id}/provider").body.fetch('data')
issuer = provider.fetch('id')

STDOUT.write(JSON.generate({
  issuer: issuer,
  provider_name: provider.dig('attributes', 'name'),
  organization_id: provider.dig('attributes', 'organizationId'),
  nickname: key.dig('attributes', 'nickname'),
  key_type: key.dig('attributes', 'keyType'),
  active: key.dig('attributes', 'isActive')
}))
RUBY
  )
}

APPLE_ID="$(discover_apple_id)"
NOTARY_KEY_PATH="$(discover_api_key_path)"
if [[ -z "${NOTARY_KEY_ID}" ]]; then
  NOTARY_KEY_ID="$(infer_key_id_from_path "${NOTARY_KEY_PATH}")"
fi

if [[ -z "${NOTARY_ISSUER}" ]]; then
  FASTLANE_RUNTIME="$(detect_fastlane_ruby)"
  RUBY_BIN="$(printf '%s\n' "${FASTLANE_RUNTIME}" | sed -n '1p')"
  FASTLANE_LIBEXEC="$(printf '%s\n' "${FASTLANE_RUNTIME}" | sed -n '2p')"
  issuer_json="$(resolve_issuer_via_spaceship "${APPLE_ID}" "${NOTARY_KEY_ID}" "${RUBY_BIN}" "${FASTLANE_LIBEXEC}")" || \
    fail "无法通过 App Store Connect 会话自动解析 issuer。请先确认 Xcode/fastlane 会话有效，或显式传入 --issuer。"

  NOTARY_ISSUER="$(python3 - <<'PY' "${issuer_json}"
import json
import sys
payload = json.loads(sys.argv[1])
print(payload["issuer"])
PY
)"

  provider_name="$(python3 - <<'PY' "${issuer_json}"
import json
import sys
payload = json.loads(sys.argv[1])
print(payload.get("provider_name", ""))
PY
)"
  org_id="$(python3 - <<'PY' "${issuer_json}"
import json
import sys
payload = json.loads(sys.argv[1])
print(payload.get("organization_id", ""))
PY
)"
  nickname="$(python3 - <<'PY' "${issuer_json}"
import json
import sys
payload = json.loads(sys.argv[1])
print(payload.get("nickname", ""))
PY
)"

  log "已通过 App Store Connect 会话解析 issuer: ${NOTARY_ISSUER}"
  [[ -n "${provider_name}" ]] && log "内容提供方: ${provider_name}"
  [[ -n "${org_id}" ]] && log "Team ID: ${org_id}"
  [[ -n "${nickname}" ]] && log "API Key 昵称: ${nickname}"
else
  log "使用显式提供的 issuer: ${NOTARY_ISSUER}"
fi

if [[ "${VALIDATE}" -eq 1 ]]; then
  log "验证 notarytool API key 凭据..."
  xcrun notarytool history \
    --key "${NOTARY_KEY_PATH}" \
    --key-id "${NOTARY_KEY_ID}" \
    --issuer "${NOTARY_ISSUER}" >/dev/null
  log "凭据验证通过"
fi

if [[ "${SKIP_STORE}" -eq 0 ]]; then
  log "写入 notarytool keychain profile: ${PROFILE_NAME}"
  xcrun notarytool store-credentials "${PROFILE_NAME}" \
    --key "${NOTARY_KEY_PATH}" \
    --key-id "${NOTARY_KEY_ID}" \
    --issuer "${NOTARY_ISSUER}" \
    --keychain "${KEYCHAIN_PATH}" \
    --validate
fi

if [[ "${SKIP_ENV}" -eq 0 ]]; then
  mkdir -p "$(dirname "${ENV_FILE}")"
  cat > "${ENV_FILE}" <<EOF
# Generated by Scripts/bootstrap_notarytool_credentials.sh
export NOTARYTOOL_KEYCHAIN_PROFILE="${PROFILE_NAME}"
export NOTARYTOOL_KEY="${NOTARY_KEY_PATH}"
export NOTARYTOOL_KEY_ID="${NOTARY_KEY_ID}"
export NOTARYTOOL_ISSUER="${NOTARY_ISSUER}"
export NOTARYTOOL_APPLE_ID="${APPLE_ID}"
EOF
  chmod 600 "${ENV_FILE}"
  log "已写入本地 env 文件: ${ENV_FILE}"
fi

cat <<EOF
NOTARYTOOL_KEYCHAIN_PROFILE=${PROFILE_NAME}
NOTARYTOOL_KEY=${NOTARY_KEY_PATH}
NOTARYTOOL_KEY_ID=${NOTARY_KEY_ID}
NOTARYTOOL_ISSUER=${NOTARY_ISSUER}
NOTARYTOOL_APPLE_ID=${APPLE_ID}
EOF
