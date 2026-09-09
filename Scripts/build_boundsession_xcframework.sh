#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
PRODUCT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
readonly PRODUCT_ROOT
readonly DEFAULT_SOURCE_ROOT="${PRODUCT_ROOT}/../SkyBridge Compass TIFS paper/Research/PolicyPurposeBoundSession/implementation"
readonly OUTPUT_ROOT="${PRODUCT_ROOT}/Sources/Vendor/boundsession.xcframework"
readonly C_TARGET_HEADER="${PRODUCT_ROOT}/Sources/CBoundSession/include/bound_session_ffi.h"
readonly EXPECTED_HEADER_SHA256="45deb5e3e05798d6120c866b1fbddc66b26c37b55547f6630e6e94311f5bf4a0"
readonly V1_NORMALIZED_SURFACE_SHA256="078403a789b95d3aa4b9803aacbbfb45945b696788acbff9e95c44119dc9ffd0"
readonly INSTALL_NAME="@rpath/BoundSessionFFI.framework/BoundSessionFFI"

SOURCE_ROOT="${DEFAULT_SOURCE_ROOT}"
if [[ $# -eq 2 && "$1" == "--source-root" ]]; then
  SOURCE_ROOT="$2"
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--source-root PATH]" >&2
  exit 64
fi
SOURCE_ROOT="$(cd "${SOURCE_ROOT}" && pwd -P)"

readonly AUTHORITATIVE_HEADER="${SOURCE_ROOT}/bound-session-ffi/include/bound_session_ffi.h"
readonly CARGO_LOCK="${SOURCE_ROOT}/Cargo.lock"

fail() {
  echo "BoundSession XCFramework build failed: $*" >&2
  exit 1
}

# Cargo gives encoded flags precedence over RUSTFLAGS. Accept only a controlled
# build configuration, then preserve each path (including spaces) as one token.
[[ -z "${RUSTFLAGS:-}" && -z "${CARGO_ENCODED_RUSTFLAGS:-}" ]] \
  || fail "external Rust compiler flags are not supported by this build contract"
BUILD_HOME="$(cd "${HOME:?HOME must be set}" && pwd -P)"
CARGO_BUILD_HOME="$(cd "${CARGO_HOME:-${HOME}/.cargo}" && pwd -P)"
RUST_SYSROOT="$(rustc --print sysroot)"
readonly BUILD_HOME CARGO_BUILD_HOME RUST_SYSROOT
readonly BUILD_TARGET_ROOT="${SOURCE_ROOT}/target"
for build_prefix in "${HOME}" "${BUILD_HOME}" "${CARGO_HOME:-${HOME}/.cargo}" \
  "${CARGO_BUILD_HOME}" "${RUST_SYSROOT}" "${SOURCE_ROOT}"; do
  [[ -n "${build_prefix}" && "${build_prefix}" != "/" \
    && "${build_prefix}" != *$'\037'* && "${build_prefix}" != *$'\n'* \
    && "${build_prefix}" != *$'\r'* && -d "${build_prefix}" ]] \
    || fail "build path is not a supported Rust path-remapping prefix"
done
ENCODED_BUILD_FLAGS="-Dwarnings"
for mapping in \
  "${HOME}=/__skybridge__/build-home" \
  "${BUILD_HOME}=/__skybridge__/build-home" \
  "${CARGO_HOME:-${HOME}/.cargo}=/__skybridge__/cargo-home" \
  "${CARGO_BUILD_HOME}=/__skybridge__/cargo-home" \
  "${RUST_SYSROOT}=/__skybridge__/rust-sysroot" \
  "${SOURCE_ROOT}=/__skybridge__/boundsession-source"; do
  ENCODED_BUILD_FLAGS+=$'\037'"--remap-path-prefix=${mapping}"
done
readonly ENCODED_BUILD_FLAGS

STAGING_ROOT=""
PREVIOUS_ROOT=""
readonly BUILD_LOCK="${PRODUCT_ROOT}/.boundsession-xcframework.build-lock"
BUILD_LOCK_OWNED=false
cleanup() {
  local exit_status=$?
  trap - EXIT HUP INT TERM
  if [[ -n "${PREVIOUS_ROOT}" && -d "${PREVIOUS_ROOT}" \
    && ! -e "${OUTPUT_ROOT}" && ! -L "${OUTPUT_ROOT}" ]]; then
    if ! /bin/mv "${PREVIOUS_ROOT}" "${OUTPUT_ROOT}"; then
      echo "BoundSession artifact restore failed; previous artifact retained: ${PREVIOUS_ROOT}" >&2
      exit 1
    fi
  fi
  if [[ -n "${STAGING_ROOT}" && -d "${STAGING_ROOT}" ]]; then
    if [[ "${exit_status}" -eq 0 ]]; then
      /usr/bin/find "${STAGING_ROOT}" -depth -delete
    else
      echo "Uninstalled BoundSession candidate retained: ${STAGING_ROOT}" >&2
    fi
  fi
  if [[ "${BUILD_LOCK_OWNED}" == true ]]; then
    /bin/rmdir "${BUILD_LOCK}"
  fi
  exit "${exit_status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

[[ -f "${AUTHORITATIVE_HEADER}" && ! -L "${AUTHORITATIVE_HEADER}" ]] \
  || fail "authoritative header is missing or symlinked"
[[ -f "${CARGO_LOCK}" && ! -L "${CARGO_LOCK}" ]] \
  || fail "Cargo.lock is missing or symlinked"
[[ -d "${OUTPUT_ROOT}" && ! -L "${OUTPUT_ROOT}" ]] \
  || fail "existing product XCFramework root is missing or symlinked"
/bin/mkdir "${BUILD_LOCK}" \
  || fail "another build or an interrupted build owns ${BUILD_LOCK}; inspect it before retrying"
BUILD_LOCK_OWNED=true

HEADER_SHA256="$(sha256_file "${AUTHORITATIVE_HEADER}")"
readonly HEADER_SHA256
[[ "${HEADER_SHA256}" == "${EXPECTED_HEADER_SHA256}" ]] \
  || fail "authoritative header SHA-256 drifted: ${HEADER_SHA256}"
[[ "$(sha256_file "${C_TARGET_HEADER}")" == "${EXPECTED_HEADER_SHA256}" ]] \
  || fail "CBoundSession header is not synchronized with the authority"

for target in aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target list --installed | /usr/bin/grep -Fx "${target}" >/dev/null \
    || fail "Rust target is not installed: ${target}"
  (
    cd "${SOURCE_ROOT}"
    CARGO_ENCODED_RUSTFLAGS="${ENCODED_BUILD_FLAGS}" cargo build \
      --release \
      --locked \
      --package bound-session-ffi \
      --target-dir "${BUILD_TARGET_ROOT}" \
      --target "${target}"
  )
done

STAGING_ROOT="$(/usr/bin/mktemp -d "${PRODUCT_ROOT}/.boundsession-xcframework.XXXXXX")"

make_framework() {
  local identifier="$1"
  local target="$2"
  local template="${OUTPUT_ROOT}/${identifier}/BoundSessionFFI.framework"
  local framework="${STAGING_ROOT}/${identifier}/BoundSessionFFI.framework"
  local dylib="${BUILD_TARGET_ROOT}/${target}/release/libbound_session_ffi.dylib"
  local payload="${framework}"
  local template_info="${template}/Info.plist"

  [[ -d "${template}" && ! -L "${template}" ]] \
    || fail "framework template is missing or symlinked: ${identifier}"
  [[ -d "${OUTPUT_ROOT}/${identifier}" && ! -L "${OUTPUT_ROOT}/${identifier}" ]] \
    || fail "framework template slice is missing or symlinked: ${identifier}"
  [[ -f "${dylib}" && ! -L "${dylib}" ]] \
    || fail "cross-built dylib is missing or symlinked: ${target}"

  if [[ "${identifier}" == "macos-arm64" ]]; then
    # Read the former flat template only for the one-way layout migration.
    # Every new macOS output has the standard versioned bundle structure.
    if [[ -d "${template}/Versions" ]]; then
      for directory in "${template}/Versions" "${template}/Versions/A" \
        "${template}/Versions/A/Resources"; do
        [[ -d "${directory}" && ! -L "${directory}" ]] \
          || fail "versioned metadata template parent is missing or symlinked"
      done
      template_info="${template}/Versions/A/Resources/Info.plist"
    fi
    payload="${framework}/Versions/A"
    /bin/mkdir -p "${payload}/Headers" "${payload}/Resources"
    /bin/ln -s A "${framework}/Versions/Current"
    /bin/ln -s Versions/Current/BoundSessionFFI "${framework}/BoundSessionFFI"
    /bin/ln -s Versions/Current/Headers "${framework}/Headers"
    /bin/ln -s Versions/Current/Resources "${framework}/Resources"
  else
    /bin/mkdir -p "${payload}/Headers"
  fi
  [[ -f "${template_info}" && ! -L "${template_info}" ]] \
    || fail "framework metadata template is missing or symlinked: ${identifier}"
  if [[ "${identifier}" == "macos-arm64" ]]; then
    /bin/cp "${template_info}" "${payload}/Resources/Info.plist"
  else
    /bin/cp "${template_info}" "${payload}/Info.plist"
  fi
  /bin/cp "${dylib}" "${payload}/BoundSessionFFI"
  /usr/bin/install_name_tool -id "${INSTALL_NAME}" "${payload}/BoundSessionFFI"
  /bin/cp "${AUTHORITATIVE_HEADER}" "${payload}/Headers/bound_session_ffi.h"
  /usr/bin/codesign --force --sign - --timestamp=none "${framework}"
}

make_framework "macos-arm64" "aarch64-apple-darwin"
make_framework "ios-arm64" "aarch64-apple-ios"
make_framework "ios-arm64-simulator" "aarch64-apple-ios-sim"

readonly CANDIDATE_ROOT="${STAGING_ROOT}/candidate/boundsession.xcframework"
/usr/bin/xcodebuild -create-xcframework \
  -framework "${STAGING_ROOT}/macos-arm64/BoundSessionFFI.framework" \
  -framework "${STAGING_ROOT}/ios-arm64/BoundSessionFFI.framework" \
  -framework "${STAGING_ROOT}/ios-arm64-simulator/BoundSessionFFI.framework" \
  -output "${CANDIDATE_ROOT}"

SOURCE_WORKTREE_CLEAN=false
SOURCE_STATUS="$(git -C "${SOURCE_ROOT}" status --porcelain -- .)"
if [[ -z "${SOURCE_STATUS}" ]]; then
  SOURCE_WORKTREE_CLEAN=true
fi
SOURCE_REVISION="$(git -C "${SOURCE_ROOT}" rev-parse HEAD)"
SOURCE_LOCK_SHA256="$(sha256_file "${CARGO_LOCK}")"
RUSTC_VERSION="$(rustc --version)"
CARGO_VERSION="$(cargo --version)"
LLVM_VERSION="$(rustc -vV | /usr/bin/awk -F': ' '$1 == "LLVM version" {print $2}')"
[[ "${SOURCE_REVISION}" =~ ^[0-9a-f]{40}$ \
  && "${SOURCE_LOCK_SHA256}" =~ ^[0-9a-f]{64}$ \
  && -n "${RUSTC_VERSION}" && -n "${CARGO_VERSION}" && -n "${LLVM_VERSION}" ]] \
  || fail "source or toolchain provenance metadata is missing or malformed"

PYTHONDONTWRITEBYTECODE=1 PYTHONWARNINGS=error /usr/bin/python3 \
  "${SCRIPT_DIR}/write_boundsession_provenance.py" \
  --source-root "${SOURCE_ROOT}" \
  --candidate-root "${CANDIDATE_ROOT}" \
  --output "${CANDIDATE_ROOT}/SkyBridgeBoundSessionProvenance.json" \
  --header-sha256 "${HEADER_SHA256}" \
  --v1-surface-sha256 "${V1_NORMALIZED_SURFACE_SHA256}" \
  --source-revision "${SOURCE_REVISION}" \
  --source-worktree-clean "${SOURCE_WORKTREE_CLEAN}" \
  --cargo-lock-sha256 "${SOURCE_LOCK_SHA256}" \
  --rustc "${RUSTC_VERSION}" \
  --cargo "${CARGO_VERSION}" \
  --llvm "${LLVM_VERSION}"

# Verify the complete staged artifact before touching the current vendor copy.
PYTHONDONTWRITEBYTECODE=1 PYTHONWARNINGS=error /usr/bin/python3 \
  "${SCRIPT_DIR}/verify_boundsession_xcframework.py" \
  --root "${PRODUCT_ROOT}" --xcframework "${CANDIDATE_ROOT}"

# Both moves stay on the product filesystem. Keep the previous complete artifact
# for rollback; the EXIT trap restores it if interruption leaves the target absent.
BACKUP_DIRECTORY="${PRODUCT_ROOT}/Artifacts"
[[ ! -L "${BACKUP_DIRECTORY}" ]] || fail "artifact backup directory must not be symlinked"
/bin/mkdir -p "${BACKUP_DIRECTORY}"
OUTPUT_DEVICE="$(/usr/bin/stat -f '%d' "${OUTPUT_ROOT}")"
[[ "$(/usr/bin/stat -f '%d' "${BACKUP_DIRECTORY}")" == "${OUTPUT_DEVICE}" \
  && "$(/usr/bin/stat -f '%d' "${CANDIDATE_ROOT}")" == "${OUTPUT_DEVICE}" ]] \
  || fail "candidate, previous artifact and backup directory must share a filesystem"
PREVIOUS_PARENT="$(/usr/bin/mktemp -d "${BACKUP_DIRECTORY}/boundsession-xcframework.previous.XXXXXX")"
PREVIOUS_ROOT="${PREVIOUS_PARENT}/boundsession.xcframework"
/bin/mv "${OUTPUT_ROOT}" "${PREVIOUS_ROOT}"
/bin/mv "${CANDIDATE_ROOT}" "${OUTPUT_ROOT}"
echo "Previous BoundSession artifact retained: ${PREVIOUS_ROOT}"

echo "Built BoundSession XCFramework: 3 arm64 slices, 38 symbols expected, ABI-v2 capabilities 0x0f"
