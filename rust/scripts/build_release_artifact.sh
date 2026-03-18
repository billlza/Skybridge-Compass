#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_PATH="${ROOT_DIR}/Cargo.toml"
PACKAGE_NAME="skybridge"
TARGET=""
OUT_DIR=""
PYTHON_BIN="${PYTHON_BIN:-python3}"

usage() {
  cat <<'EOF'
Usage: build_release_artifact.sh --target <triple> --out-dir <dir>

Builds the Rust `skybridge` CLI in release mode for the requested target and
packages it as a GitHub release asset.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
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

if [[ -z "${TARGET}" || -z "${OUT_DIR}" ]]; then
  usage >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
export CARGO_INCREMENTAL=0
export CARGO_PROFILE_RELEASE_DEBUG="${CARGO_PROFILE_RELEASE_DEBUG:-0}"

rustup target add "${TARGET}"
cargo build \
  --manifest-path "${MANIFEST_PATH}" \
  -p "${PACKAGE_NAME}" \
  --release \
  --target "${TARGET}"

TARGET_DIR="${CARGO_TARGET_DIR:-${ROOT_DIR}/target}"
if [[ "${TARGET}" == *windows* ]]; then
  BINARY_NAME="skybridge.exe"
  ARCHIVE_EXT="zip"
else
  BINARY_NAME="skybridge"
  ARCHIVE_EXT="tar.gz"
fi

BUILT_BINARY="${TARGET_DIR}/${TARGET}/release/${BINARY_NAME}"
if [[ ! -f "${BUILT_BINARY}" ]]; then
  echo "expected built binary at ${BUILT_BINARY}" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGING_DIR}"' EXIT
cp "${BUILT_BINARY}" "${STAGING_DIR}/${BINARY_NAME}"

if [[ "${SKYBRIDGE_RELEASE_STRIP:-0}" == "1" ]] && [[ "${BINARY_NAME}" == "skybridge" ]] && command -v strip >/dev/null 2>&1; then
  strip "${STAGING_DIR}/${BINARY_NAME}" || true
fi

ARCHIVE_NAME="skybridge-${TARGET}.${ARCHIVE_EXT}"
"${PYTHON_BIN}" - "${STAGING_DIR}" "${BINARY_NAME}" "${OUT_DIR}/${ARCHIVE_NAME}" "${ARCHIVE_EXT}" <<'PY'
import pathlib
import sys
import tarfile
import zipfile

stage_dir = pathlib.Path(sys.argv[1])
binary_name = sys.argv[2]
archive_path = pathlib.Path(sys.argv[3])
archive_ext = sys.argv[4]
binary_path = stage_dir / binary_name

if archive_ext == "zip":
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.write(binary_path, arcname=binary_name)
else:
    with tarfile.open(archive_path, "w:gz") as tf:
        tf.add(binary_path, arcname=binary_name)
PY

echo "packaged ${ARCHIVE_NAME}"
