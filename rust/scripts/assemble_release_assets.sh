#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS_DIR=""
VERSION=""
SOURCE_REPOSITORY=""
SOURCE_SHA=""
RUST_TOOLCHAIN=""
SOURCE_DATE_EPOCH=""
WORKFLOW_RUN_ID=""
WORKFLOW_RUN_ATTEMPT=""
PYTHON_BIN="${PYTHON_BIN:-python3}"

usage() {
  cat <<'EOF'
Usage: assemble_release_assets.sh --assets-dir <dir> --version <version> \
  --source-repository <owner/repo> --source-sha <40-hex> \
  --rust-toolchain <version> --source-date-epoch <epoch> \
  --workflow-run-id <id> --workflow-run-attempt <attempt>

Validates the exact native/npm input set, renders the Homebrew formula, then
writes and re-verifies a source-bound manifest and SHA256SUMS.txt.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --assets-dir)
      ASSETS_DIR="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --source-repository)
      SOURCE_REPOSITORY="${2:-}"
      shift 2
      ;;
    --source-sha)
      SOURCE_SHA="${2:-}"
      shift 2
      ;;
    --rust-toolchain)
      RUST_TOOLCHAIN="${2:-}"
      shift 2
      ;;
    --source-date-epoch)
      SOURCE_DATE_EPOCH="${2:-}"
      shift 2
      ;;
    --workflow-run-id)
      WORKFLOW_RUN_ID="${2:-}"
      shift 2
      ;;
    --workflow-run-attempt)
      WORKFLOW_RUN_ATTEMPT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${ASSETS_DIR}" || -z "${VERSION}" || -z "${SOURCE_REPOSITORY}" || \
      -z "${SOURCE_SHA}" || -z "${RUST_TOOLCHAIN}" || -z "${SOURCE_DATE_EPOCH}" || \
      -z "${WORKFLOW_RUN_ID}" || -z "${WORKFLOW_RUN_ATTEMPT}" ]]; then
  usage >&2
  exit 1
fi

[[ -d "${ASSETS_DIR}" && ! -L "${ASSETS_DIR}" ]] || {
  echo "assets directory must be a real directory: ${ASSETS_DIR}" >&2
  exit 1
}

"${PYTHON_BIN}" "${ROOT_DIR}/scripts/finalize_cli_release_assets.py" preflight \
  --assets-dir "${ASSETS_DIR}" \
  --version "${VERSION}"
"${PYTHON_BIN}" "${ROOT_DIR}/scripts/finalize_cli_release_assets.py" validate-metadata \
  --version "${VERSION}" \
  --source-repository "${SOURCE_REPOSITORY}" \
  --source-sha "${SOURCE_SHA}" \
  --rust-toolchain "${RUST_TOOLCHAIN}" \
  --source-date-epoch "${SOURCE_DATE_EPOCH}"

SKYBRIDGE_DARWIN_ARM64_SHA256="$(
  "${PYTHON_BIN}" - "${ASSETS_DIR}/skybridge-aarch64-apple-darwin.tar.gz" <<'PY'
import hashlib
import pathlib
import sys

digest = hashlib.sha256()
with pathlib.Path(sys.argv[1]).open("rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
)"

SKYBRIDGE_VERSION="${VERSION}" \
SKYBRIDGE_DARWIN_ARM64_SHA256="${SKYBRIDGE_DARWIN_ARM64_SHA256}" \
SKYBRIDGE_RELEASE_BASE_URL="https://github.com/${SOURCE_REPOSITORY}/releases/download/skybridge-cli-v${VERSION}" \
"${ROOT_DIR}/scripts/render_homebrew_formula.sh" "${ASSETS_DIR}/skybridge.rb"

"${PYTHON_BIN}" "${ROOT_DIR}/scripts/finalize_cli_release_assets.py" finalize \
  --assets-dir "${ASSETS_DIR}" \
  --version "${VERSION}" \
  --source-repository "${SOURCE_REPOSITORY}" \
  --source-sha "${SOURCE_SHA}" \
  --rust-toolchain "${RUST_TOOLCHAIN}" \
  --source-date-epoch "${SOURCE_DATE_EPOCH}"

echo "assembled release assets in ${ASSETS_DIR}"
