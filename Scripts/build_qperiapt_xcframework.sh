#!/usr/bin/env bash
set -euo pipefail

# Build the Q-Periapt FFI static libraries for each Apple triple and assemble an
# xcframework that SwiftPM can consume as a .binaryTarget.
#
# This mirrors Scripts/build_liboqs_xcframework.sh: it produces
# Sources/Vendor/qperiapt.xcframework with macOS arm64, iOS arm64 (device), and
# iOS arm64 simulator slices, all built from the same vendored headers.
#
# The q-periapt-ffi crate lives in a separate repo and is NOT modified here.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

QPERIAPT_REPO="${QPERIAPT_REPO:-$ROOT_DIR/External/pqt_hybrid_suite}"
QPERIAPT_MANIFEST="${QPERIAPT_MANIFEST:-$QPERIAPT_REPO/Cargo.toml}"
QPERIAPT_HEADER="${QPERIAPT_HEADER:-$QPERIAPT_REPO/crates/q-periapt-ffi/include/q_periapt.h}"

BUILD_ROOT="${QPERIAPT_BUILD_ROOT:-$ROOT_DIR/.build/qperiapt-xcframework}"
HEADERS_DIR="$BUILD_ROOT/headers"
FINAL_OUT="$ROOT_DIR/Sources/Vendor/qperiapt.xcframework"
IOS_VENDOR_OUT="$ROOT_DIR/SkyBridge Compass iOS/Vendor/qperiapt.xcframework"
# The C wrapper target CQPeriapt vendors its own copy of q_periapt.h (mirror OQSRAII's self-owned
# header). Keep it in sync on every rebuild so the umbrella header CQPeriapt.h stays valid.
CQPERIAPT_HEADER_OUT="$ROOT_DIR/Sources/CQPeriapt/include/q_periapt.h"
STAGED_OUT="$BUILD_ROOT/qperiapt.xcframework"
STAGED_IOS_OUT="$BUILD_ROOT/qperiapt-ios.xcframework"

# Apple triples — all three already build clean (verified upstream).
DARWIN_TRIPLE="aarch64-apple-darwin"
IOS_TRIPLE="aarch64-apple-ios"
IOS_SIM_TRIPLE="aarch64-apple-ios-sim"

LIB_NAME="libq_periapt_ffi.a"

log() { echo "[build_qperiapt_xcframework] $*"; }

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need_cmd cargo
need_cmd rustc
need_cmd xcodebuild
need_cmd lipo
need_cmd grep
need_cmd cmp
need_cmd awk
need_cmd python3

RUST_HOST="$(rustc -vV | awk '/^host:/ { print $2 }')"
RUST_SYSROOT="$(rustc --print sysroot)"
LLVM_NM="$RUST_SYSROOT/lib/rustlib/$RUST_HOST/bin/llvm-nm"
if [[ ! -x "$LLVM_NM" ]]; then
  echo "Rust llvm-nm not found: $LLVM_NM" >&2
  exit 1
fi

assert_header_contract() {
  local header="$1"
  local token
  for token in \
    "#define Q_PERIAPT_ABI_VERSION 1" \
    "uint32_t q_periapt_abi_version(void);" \
    "const char *q_periapt_version(void);" \
    "const char *q_periapt_fixed_suite_id(void);" \
    "uintptr_t q_periapt_fixed_suite_id_len(void);" \
    "const char *q_periapt_status_name(int32_t code);"
  do
    grep -Fq "$token" "$header" || {
      echo "Q-Periapt header is missing required ABI contract: $token" >&2
      exit 1
    }
  done
}

assert_required_symbols() {
  local library="$1"
  local symbols
  if ! symbols="$($LLVM_NM --defined-only "$library" 2>/dev/null)"; then
    echo "Failed to inspect Q-Periapt symbols in $library" >&2
    exit 1
  fi
  local symbol
  for symbol in \
    q_periapt_abi_version \
    q_periapt_version \
    q_periapt_fixed_suite_id \
    q_periapt_fixed_suite_id_len \
    q_periapt_status_name \
    q_periapt_mlkem768_keypair \
    q_periapt_x25519_keypair \
    q_periapt_hybrid_encapsulate \
    q_periapt_hybrid_decapsulate
  do
    grep -Eq "[[:space:]]_?${symbol}$" <<<"$symbols" || {
      echo "Missing required Q-Periapt symbol in $library: $symbol" >&2
      exit 1
    }
  done
}

assert_xcframework_contract() {
  local xcframework="$1"
  if find "$xcframework" -name module.modulemap -type f -print -quit | grep -q .; then
    echo "$xcframework must not contain module.modulemap; CQPeriapt owns the module boundary." >&2
    exit 1
  fi

  local slice
  for slice in macos-arm64 ios-arm64 ios-arm64-simulator; do
    local header="$xcframework/$slice/Headers/q_periapt.h"
    local library="$xcframework/$slice/$LIB_NAME"
    [[ -f "$header" ]] || { echo "Missing Q-Periapt slice header: $header" >&2; exit 1; }
    [[ -f "$library" ]] || { echo "Missing Q-Periapt slice library: $library" >&2; exit 1; }
    cmp -s "$QPERIAPT_HEADER" "$header" || {
      echo "Q-Periapt slice header differs from source header: $header" >&2
      exit 1
    }
    assert_required_symbols "$library"
  done
}

normalize_xcframework_info() {
  local xcframework="$1"
  python3 - "$xcframework/Info.plist" <<'PY'
import pathlib
import plistlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("rb") as handle:
    info = plistlib.load(handle)
libraries = info.get("AvailableLibraries")
if not isinstance(libraries, list) or not libraries:
    raise SystemExit(f"Invalid XCFramework AvailableLibraries: {path}")
if not all(isinstance(item, dict) and isinstance(item.get("LibraryIdentifier"), str) for item in libraries):
    raise SystemExit(f"Invalid XCFramework library entry: {path}")
info["AvailableLibraries"] = sorted(libraries, key=lambda item: item["LibraryIdentifier"])
with path.open("wb") as handle:
    plistlib.dump(info, handle, fmt=plistlib.FMT_XML, sort_keys=False)
PY
}

replace_directory() {
  local staged="$1"
  local destination="$2"
  local previous="${destination}.previous"
  rm -rf "$previous"
  if [[ -d "$destination" ]]; then
    mv "$destination" "$previous"
  fi
  if mv "$staged" "$destination"; then
    rm -rf "$previous"
    return
  fi
  if [[ -d "$previous" ]]; then
    mv "$previous" "$destination"
  fi
  echo "Failed to install validated xcframework at $destination" >&2
  exit 1
}

if [[ ! -f "$QPERIAPT_MANIFEST" ]]; then
  echo "q-periapt Cargo manifest not found: $QPERIAPT_MANIFEST" >&2
  exit 1
fi

if [[ ! -f "$QPERIAPT_HEADER" ]]; then
  echo "q-periapt header not found: $QPERIAPT_HEADER" >&2
  exit 1
fi

assert_header_contract "$QPERIAPT_HEADER"

mkdir -p "$BUILD_ROOT" "$HEADERS_DIR"

QPERIAPT_CARGO_ENCODED_RUSTFLAGS="${CARGO_ENCODED_RUSTFLAGS:-}"

append_qperiapt_rustflag() {
  local flag="$1"
  if [[ -n "$QPERIAPT_CARGO_ENCODED_RUSTFLAGS" ]]; then
    QPERIAPT_CARGO_ENCODED_RUSTFLAGS+=$'\x1f'
  fi
  QPERIAPT_CARGO_ENCODED_RUSTFLAGS+="$flag"
}

append_qperiapt_rustflag "--remap-path-prefix=${QPERIAPT_REPO}=qperiapt-src"
append_qperiapt_rustflag "--remap-path-prefix=${ROOT_DIR}=skybridge-src"
if [[ -n "${HOME:-}" ]]; then
  append_qperiapt_rustflag "--remap-path-prefix=${HOME}/.cargo/registry/src=cargo-registry"
  append_qperiapt_rustflag "--remap-path-prefix=${HOME}/.rustup/toolchains=rust-toolchain"
fi

# Stage ONLY the C ABI header. Deliberately do NOT stage a module.modulemap.
#
# Why (mirror liboqs/OQSRAII): liboqs.xcframework already ships a module.modulemap into the
# shared Release/include/ dir. If qperiapt.xcframework also ships one, the two .binaryTargets
# both produce '.../Release/include/module.modulemap' and Xcode fails with
# "Multiple commands produce ... module.modulemap". So qperiapt is consumed exactly like liboqs:
# the xcframework contributes only the static lib + q_periapt.h, and the C wrapper target
# CQPeriapt (Sources/CQPeriapt, which vendors its own copy of q_periapt.h and re-exports it via
# CQPeriapt.h) is what Swift imports (`import CQPeriapt`). SwiftPM auto-generates CQPeriapt's
# module map in that target's own module dir — no collision in the shared include dir.
cp "$QPERIAPT_HEADER" "$HEADERS_DIR/q_periapt.h"

build_one() {
  local triple="$1"
  log "Building q-periapt-ffi for $triple..."
  CARGO_ENCODED_RUSTFLAGS="$QPERIAPT_CARGO_ENCODED_RUSTFLAGS" cargo build --locked --release -p q-periapt-ffi \
    --manifest-path "$QPERIAPT_MANIFEST" \
    --target "$triple"
}

build_one "$DARWIN_TRIPLE"
build_one "$IOS_TRIPLE"
build_one "$IOS_SIM_TRIPLE"

DARWIN_LIB="$QPERIAPT_REPO/target/$DARWIN_TRIPLE/release/$LIB_NAME"
IOS_LIB="$QPERIAPT_REPO/target/$IOS_TRIPLE/release/$LIB_NAME"
IOS_SIM_LIB="$QPERIAPT_REPO/target/$IOS_SIM_TRIPLE/release/$LIB_NAME"

for lib in "$DARWIN_LIB" "$IOS_LIB" "$IOS_SIM_LIB"; do
  if [[ ! -f "$lib" ]]; then
    echo "Missing build output: $lib" >&2
    exit 1
  fi
  assert_required_symbols "$lib"
done

log "macOS lib:        $(lipo -info "$DARWIN_LIB")"
log "iOS device lib:   $(lipo -info "$IOS_LIB")"
log "iOS simulator lib:$(lipo -info "$IOS_SIM_LIB")"

rm -rf "$STAGED_OUT"
log "Creating staged xcframework..."
xcodebuild -create-xcframework \
  -library "$DARWIN_LIB" -headers "$HEADERS_DIR" \
  -library "$IOS_LIB" -headers "$HEADERS_DIR" \
  -library "$IOS_SIM_LIB" -headers "$HEADERS_DIR" \
  -output "$STAGED_OUT"
normalize_xcframework_info "$STAGED_OUT"
find "$STAGED_OUT" -name module.modulemap -type f -delete
assert_xcframework_contract "$STAGED_OUT"
replace_directory "$STAGED_OUT" "$FINAL_OUT"

log "Created: $FINAL_OUT"

# Update the C wrapper only after every binary slice has passed the ABI checks.
cp "$QPERIAPT_HEADER" "$CQPERIAPT_HEADER_OUT"
cmp -s "$QPERIAPT_HEADER" "$CQPERIAPT_HEADER_OUT" || {
  echo "Failed to synchronize CQPeriapt header" >&2
  exit 1
}
log "Synced CQPeriapt vendored header: $CQPERIAPT_HEADER_OUT"

# Mirror to the iOS app's Vendor dir if that layout exists (parallels liboqs).
if [[ -d "$ROOT_DIR/SkyBridge Compass iOS/Vendor" ]]; then
  rm -rf "$STAGED_IOS_OUT"
  cp -R "$FINAL_OUT" "$STAGED_IOS_OUT"
  assert_xcframework_contract "$STAGED_IOS_OUT"
  replace_directory "$STAGED_IOS_OUT" "$IOS_VENDOR_OUT"
  log "Mirrored to: $IOS_VENDOR_OUT"
fi

log "Done."
