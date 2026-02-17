#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBOQS_SRC_DIR="${LIBOQS_SRC_DIR:-$ROOT_DIR/External/liboqs}"
BUILD_ROOT="${LIBOQS_BUILD_ROOT:-$ROOT_DIR/.build/liboqs-universal}"
IOS_MIN_VERSION="${IOS_MIN_VERSION:-17.0}"
MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-14.0}"

HEADERS_DIR="$LIBOQS_SRC_DIR/xcframework-headers"
TMP_OUT="$BUILD_ROOT/liboqs.tmp.xcframework"
FINAL_OUT="$ROOT_DIR/Sources/Vendor/liboqs.xcframework"
IOS_VENDOR_OUT="$ROOT_DIR/SkyBridge Compass iOS/Vendor/liboqs.xcframework"
STAMP="$(date +%Y%m%d%H%M%S)"

log() { echo "[build_liboqs_xcframework] $*"; }

detect_jobs() {
  local jobs=""
  jobs="$(sysctl -n hw.logicalcpu 2>/dev/null || true)"
  if [[ "$jobs" =~ ^[0-9]+$ ]] && (( jobs > 0 )); then
    echo "$jobs"
    return
  fi

  if command -v getconf >/dev/null 2>&1; then
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    if [[ "$jobs" =~ ^[0-9]+$ ]] && (( jobs > 0 )); then
      echo "$jobs"
      return
    fi
  fi

  echo "8"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need_cmd cmake
need_cmd xcodebuild
need_cmd lipo

if [[ ! -d "$LIBOQS_SRC_DIR" ]]; then
  echo "liboqs source directory not found: $LIBOQS_SRC_DIR" >&2
  exit 1
fi

if [[ ! -d "$HEADERS_DIR" ]]; then
  echo "xcframework headers directory not found: $HEADERS_DIR" >&2
  echo "Expected module.modulemap and oqs headers under: $HEADERS_DIR" >&2
  exit 1
fi

mkdir -p "$BUILD_ROOT"
BUILD_JOBS="${LIBOQS_BUILD_JOBS:-$(detect_jobs)}"

common_cmake_flags=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF
  -DOQS_BUILD_ONLY_LIB=ON
  -DOQS_DIST_BUILD=ON
  -DOQS_USE_OPENSSL=OFF
  -DOQS_PERMIT_UNSUPPORTED_ARCHITECTURE=ON
)

build_one() {
  local name="$1"
  shift
  local build_dir="$BUILD_ROOT/$name"
  log "Configuring $name..."
  cmake -S "$LIBOQS_SRC_DIR" -B "$build_dir" "${common_cmake_flags[@]}" "$@"
  log "Building $name..."
  cmake --build "$build_dir" -j"$BUILD_JOBS"
}

build_one "macos-arm64" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION"

build_one "ios-arm64" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_VERSION"

build_one "ios-sim-arm64_x86_64" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_VERSION"

MACOS_LIB="$BUILD_ROOT/macos-arm64/lib/liboqs.a"
IOS_LIB="$BUILD_ROOT/ios-arm64/lib/liboqs.a"
SIM_LIB="$BUILD_ROOT/ios-sim-arm64_x86_64/lib/liboqs.a"

for lib in "$MACOS_LIB" "$IOS_LIB" "$SIM_LIB"; do
  if [[ ! -f "$lib" ]]; then
    echo "Missing build output: $lib" >&2
    exit 1
  fi
done

if [[ -d "$TMP_OUT" ]]; then
  mv "$TMP_OUT" "$TMP_OUT.$STAMP.bak"
fi

log "Creating xcframework..."
xcodebuild -create-xcframework \
  -library "$MACOS_LIB" -headers "$HEADERS_DIR" \
  -library "$IOS_LIB" -headers "$HEADERS_DIR" \
  -library "$SIM_LIB" -headers "$HEADERS_DIR" \
  -output "$TMP_OUT"

log "Created: $TMP_OUT"
log "Simulator lib architectures: $(lipo -info "$SIM_LIB")"

if [[ -d "$FINAL_OUT" ]]; then
  mv "$FINAL_OUT" "$FINAL_OUT.$STAMP.bak"
fi
mv "$TMP_OUT" "$FINAL_OUT"
log "Updated: $FINAL_OUT"

if [[ -d "$ROOT_DIR/SkyBridge Compass iOS/Vendor" ]]; then
  if [[ -d "$IOS_VENDOR_OUT" ]]; then
    mv "$IOS_VENDOR_OUT" "$IOS_VENDOR_OUT.$STAMP.bak"
  fi
  cp -R "$FINAL_OUT" "$IOS_VENDOR_OUT"
  log "Mirrored to: $IOS_VENDOR_OUT"
fi

log "Done."
