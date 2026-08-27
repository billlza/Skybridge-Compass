#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_PATH="${ROOT_DIR}/Cargo.toml"
PACKAGE_NAME="skybridge"
TARGET=""
OUT_DIR=""
PYTHON_BIN="${PYTHON_BIN:-python3}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "${ROOT_DIR}/.." show -s --format=%ct HEAD)}"

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
case "${TARGET}" in
  aarch64-apple-darwin|aarch64-unknown-linux-gnu|x86_64-unknown-linux-gnu|x86_64-pc-windows-msvc) ;;
  *)
    echo "unsupported CLI release target: ${TARGET}" >&2
    exit 1
    ;;
esac

mkdir -p "${OUT_DIR}"
[[ -d "${OUT_DIR}" && ! -L "${OUT_DIR}" ]] || {
  echo "release output must be a real directory: ${OUT_DIR}" >&2
  exit 1
}
[[ "${SOURCE_DATE_EPOCH}" =~ ^[1-9][0-9]*$ ]] || {
  echo "SOURCE_DATE_EPOCH must be a positive integer" >&2
  exit 1
}
export CARGO_INCREMENTAL=0
export CARGO_PROFILE_RELEASE_DEBUG="${CARGO_PROFILE_RELEASE_DEBUG:-0}"

rustup target add "${TARGET}"
cargo build \
  --manifest-path "${MANIFEST_PATH}" \
  -p "${PACKAGE_NAME}" \
  --locked \
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
if [[ ! -f "${BUILT_BINARY}" || -L "${BUILT_BINARY}" ]]; then
  echo "expected built binary at ${BUILT_BINARY}" >&2
  exit 1
fi
CLI_VERSION="$("${PYTHON_BIN}" "${ROOT_DIR}/scripts/workspace_version.py")"
VERSION_OUTPUT="$("${BUILT_BINARY}" version)"
[[ "${VERSION_OUTPUT}" == *"${CLI_VERSION}"* ]] || {
  echo "built CLI version output does not contain ${CLI_VERSION}" >&2
  exit 1
}
[[ "${VERSION_OUTPUT}" == *"phase_5_signaling_plane"* ]] || {
  echo "built CLI version output does not identify the expected runtime phase" >&2
  exit 1
}

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGING_DIR}"' EXIT
cp "${BUILT_BINARY}" "${STAGING_DIR}/${BINARY_NAME}"

if [[ "${SKYBRIDGE_RELEASE_STRIP:-0}" == "1" ]] && [[ "${BINARY_NAME}" == "skybridge" ]]; then
  command -v strip >/dev/null 2>&1 || {
    echo "SKYBRIDGE_RELEASE_STRIP=1 requires a working strip executable" >&2
    exit 1
  }
  strip "${STAGING_DIR}/${BINARY_NAME}"
fi

if [[ -n "${SKYBRIDGE_DARWIN_SIGNING_IDENTITY:-}" ]]; then
  # The archive must contain the signed bytes, so signing happens on the
  # staged binary before packaging. The identity is only meaningful for the
  # darwin target; anything else indicates a misconfigured invocation.
  [[ "${TARGET}" == *apple-darwin* ]] || {
    echo "SKYBRIDGE_DARWIN_SIGNING_IDENTITY is set for a non-darwin target: ${TARGET}" >&2
    exit 1
  }
  /usr/bin/codesign --force \
    --options runtime \
    --timestamp \
    --sign "${SKYBRIDGE_DARWIN_SIGNING_IDENTITY}" \
    "${STAGING_DIR}/${BINARY_NAME}"
  /usr/bin/codesign --verify --strict --verbose=2 "${STAGING_DIR}/${BINARY_NAME}"
  SIGNED_AUTHORITY="$(/usr/bin/codesign --display --verbose=2 "${STAGING_DIR}/${BINARY_NAME}" 2>&1 | grep '^Authority=' | head -1)"
  [[ "${SIGNED_AUTHORITY}" == "Authority=Developer ID Application:"* ]] || {
    echo "signed CLI authority is not a Developer ID Application certificate: ${SIGNED_AUTHORITY}" >&2
    exit 1
  }
elif [[ "${TARGET}" == *apple-darwin* && "${SKYBRIDGE_REQUIRE_DARWIN_SIGNING:-0}" == "1" ]]; then
  echo "SKYBRIDGE_REQUIRE_DARWIN_SIGNING=1 but SKYBRIDGE_DARWIN_SIGNING_IDENTITY is not set" >&2
  exit 1
fi

ARCHIVE_NAME="skybridge-${TARGET}.${ARCHIVE_EXT}"
ARCHIVE_PATH="${OUT_DIR}/${ARCHIVE_NAME}"
[[ ! -e "${ARCHIVE_PATH}" && ! -L "${ARCHIVE_PATH}" ]] || {
  echo "refusing to replace an existing release archive: ${ARCHIVE_PATH}" >&2
  exit 1
}
"${PYTHON_BIN}" - \
  "${STAGING_DIR}" \
  "${BINARY_NAME}" \
  "${ARCHIVE_PATH}" \
  "${ARCHIVE_EXT}" \
  "${SOURCE_DATE_EPOCH}" <<'PY'
import gzip
import io
import pathlib
import sys
import tarfile
import time
import zipfile

stage_dir = pathlib.Path(sys.argv[1])
binary_name = sys.argv[2]
archive_path = pathlib.Path(sys.argv[3])
archive_ext = sys.argv[4]
source_date_epoch = int(sys.argv[5])
binary_path = stage_dir / binary_name
binary = binary_path.read_bytes()

if archive_ext == "zip":
    zip_epoch = max(source_date_epoch, 315532800)
    date_time = time.gmtime(zip_epoch)[:6]
    info = zipfile.ZipInfo(binary_name, date_time=date_time)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = 0o100755 << 16
    with zipfile.ZipFile(archive_path, "x", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(info, binary)
else:
    with archive_path.open("xb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=source_date_epoch) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as tf:
                info = tarfile.TarInfo(binary_name)
                info.size = len(binary)
                info.mode = 0o755
                info.uid = 0
                info.gid = 0
                info.uname = ""
                info.gname = ""
                info.mtime = source_date_epoch
                tf.addfile(info, io.BytesIO(binary))
PY

"${PYTHON_BIN}" "${ROOT_DIR}/scripts/validate_cli_native_archive.py" \
  --archive "${ARCHIVE_PATH}" \
  --target "${TARGET}"

echo "packaged ${ARCHIVE_NAME}"
