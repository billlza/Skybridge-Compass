#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${ROOT_DIR}/Scripts/validate_macos_release_public_artifacts.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-release-public-artifacts-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

RAW_ARTIFACT="${TMP_DIR}/raw-artifact"
PUBLIC_OUTPUT="${TMP_DIR}/release-gate-public/file-transfer"
DIRECT_PUBLIC="${TMP_DIR}/direct-public"
DIRECT_OUTPUT="${TMP_DIR}/release-gate-public/direct"
UNSAFE_OUTPUT="${RAW_ARTIFACT}/copied-public"
mkdir -p "${RAW_ARTIFACT}/public-redacted" "${DIRECT_PUBLIC}"

cat >"${RAW_ARTIFACT}/raw.log" <<'EOF'
session=raw-session-secret SKYBRIDGE_API_TOKEN=raw-token
EOF
cat >"${RAW_ARTIFACT}/public-redacted/status.log" <<'EOF'
session=<redacted-identity> SKYBRIDGE_API_TOKEN=<redacted>
EOF
cat >"${DIRECT_PUBLIC}/status.log" <<'EOF'
session=<redacted-identity> code <redacted-sas-code>
EOF

expect_failure_contains() {
  local description="$1"
  local expected_fragment="$2"
  shift 2

  local output=""
  local status=0
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    echo "${description}: expected failure but command succeeded" >&2
    exit 1
  fi
  if [[ "${output}" != *"${expected_fragment}"* ]]; then
    printf '%s\n' "${output}" >&2
    echo "${description}: expected output to contain '${expected_fragment}'" >&2
    exit 1
  fi
}

bash "${TARGET}" \
  --artifact "file-transfer|real-device-file-transfer-smoke-public-redacted|${RAW_ARTIFACT}|${PUBLIC_OUTPUT}" \
  --artifact "direct|real-device-connectivity-matrix-public-redacted|${DIRECT_PUBLIC}|${DIRECT_OUTPUT}" >/dev/null

[[ -f "${PUBLIC_OUTPUT}/status.log" ]] || {
  echo "expected nested public-redacted artifact to be materialized" >&2
  exit 1
}
[[ -f "${DIRECT_OUTPUT}/status.log" ]] || {
  echo "expected direct public artifact to be materialized" >&2
  exit 1
}
if grep -R "raw-session-secret\|raw-token" "${TMP_DIR}/release-gate-public" >/dev/null; then
  echo "raw artifact content leaked into release-gate-public output" >&2
  exit 1
fi

expect_failure_contains \
  "raw artifact name rejected" \
  "must declare the public redaction contract" \
  bash "${TARGET}" \
    --artifact "file-transfer|real-device-file-transfer-smoke|${RAW_ARTIFACT}|${TMP_DIR}/bad-name"

expect_failure_contains \
  "unsafe output rejected" \
  "must not be inside downloaded raw artifact directory" \
  bash "${TARGET}" \
    --artifact "file-transfer|real-device-file-transfer-smoke-public-redacted|${RAW_ARTIFACT}|${UNSAFE_OUTPUT}"

echo "[test-validate-release-public-artifacts] passed"
