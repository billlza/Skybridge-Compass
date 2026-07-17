#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUST_ROOT="${ROOT_DIR}/rust"
MARKER="Q_PERIAPT_ABI1_DISABLED:"
LOG_PATH="$(mktemp "${TMPDIR:-/tmp}/skybridge-qperiapt-rust-policy.XXXXXX")"
trap 'rm -f "${LOG_PATH}"' EXIT

(
  cd "${RUST_ROOT}"
  cargo check --locked -p skybridge-core
)

if (
  cd "${RUST_ROOT}"
  cargo check --locked -p skybridge-core --features q-periapt
) >"${LOG_PATH}" 2>&1; then
  echo "Rust q-periapt ABI1 feature unexpectedly compiled." >&2
  exit 1
fi

if ! grep -Fq "${MARKER}" "${LOG_PATH}"; then
  echo "Rust q-periapt feature failed without the required ABI1 release marker." >&2
  cat "${LOG_PATH}" >&2
  exit 1
fi

echo "[test-qperiapt-rust-feature-policy] passed"
