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
STAMP="$(date +%Y%m%d%H%M%S)"

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
need_cmd xcodebuild
need_cmd lipo

if [[ ! -f "$QPERIAPT_MANIFEST" ]]; then
  echo "q-periapt Cargo manifest not found: $QPERIAPT_MANIFEST" >&2
  exit 1
fi

if [[ ! -f "$QPERIAPT_HEADER" ]]; then
  echo "q-periapt header not found: $QPERIAPT_HEADER" >&2
  exit 1
fi

mkdir -p "$BUILD_ROOT" "$HEADERS_DIR"

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

# Keep CQPeriapt's vendored header in sync (CQPeriapt.h does #include "q_periapt.h").
cp "$QPERIAPT_HEADER" "$CQPERIAPT_HEADER_OUT"
log "Synced CQPeriapt vendored header: $CQPERIAPT_HEADER_OUT"

build_one() {
  local triple="$1"
  log "Building q-periapt-ffi for $triple..."
  cargo build --release -p q-periapt-ffi \
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
done

log "macOS lib:        $(lipo -info "$DARWIN_LIB")"
log "iOS device lib:   $(lipo -info "$IOS_LIB")"
log "iOS simulator lib:$(lipo -info "$IOS_SIM_LIB")"

# Recreate the xcframework from scratch (xcodebuild refuses to overwrite).
if [[ -d "$FINAL_OUT" ]]; then
  mv "$FINAL_OUT" "$FINAL_OUT.$STAMP.bak"
  log "Backed up existing xcframework to $FINAL_OUT.$STAMP.bak"
fi

log "Creating xcframework..."
xcodebuild -create-xcframework \
  -library "$DARWIN_LIB" -headers "$HEADERS_DIR" \
  -library "$IOS_LIB" -headers "$HEADERS_DIR" \
  -library "$IOS_SIM_LIB" -headers "$HEADERS_DIR" \
  -output "$FINAL_OUT"
find "$FINAL_OUT" -name module.modulemap -type f -delete
if find "$FINAL_OUT" -name module.modulemap -type f -print -quit | grep -q .; then
  echo "qperiapt.xcframework must not contain module.modulemap; CQPeriapt owns the module boundary." >&2
  exit 1
fi

log "Created: $FINAL_OUT"

# Mirror to the iOS app's Vendor dir if that layout exists (parallels liboqs).
if [[ -d "$ROOT_DIR/SkyBridge Compass iOS/Vendor" ]]; then
  if [[ -d "$IOS_VENDOR_OUT" ]]; then
    mv "$IOS_VENDOR_OUT" "$IOS_VENDOR_OUT.$STAMP.bak"
  fi
  cp -R "$FINAL_OUT" "$IOS_VENDOR_OUT"
  find "$IOS_VENDOR_OUT" -name module.modulemap -type f -delete
  if find "$IOS_VENDOR_OUT" -name module.modulemap -type f -print -quit | grep -q .; then
    echo "iOS qperiapt.xcframework mirror must not contain module.modulemap; CQPeriapt owns the module boundary." >&2
    exit 1
  fi
  log "Mirrored to: $IOS_VENDOR_OUT"
fi

log "Done."
