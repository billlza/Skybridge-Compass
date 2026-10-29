#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET="${REPO_ROOT}/Scripts/check_manual_p2p_remote_artifact.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

output_file="$(mktemp)"
trap 'rm -f "${output_file}"' EXIT

bash -n "${TARGET}"

"${TARGET}" --help >"${output_file}" 2>&1
grep -q "Usage:" "${output_file}" || fail "help output should include usage"

if "${TARGET}" >"${output_file}" 2>&1; then
  fail "missing artifact dir should fail"
fi
grep -q "Usage:" "${output_file}" || fail "missing artifact dir should print usage"

if "${TARGET}" "${REPO_ROOT}/Artifacts/__missing_manual_p2p_artifact__" >"${output_file}" 2>&1; then
  fail "missing artifact path should fail"
fi
grep -q "manual P2P artifact directory does not exist" "${output_file}" \
  || fail "missing artifact path should explain failure"

echo "check_manual_p2p_remote_artifact tests passed"
