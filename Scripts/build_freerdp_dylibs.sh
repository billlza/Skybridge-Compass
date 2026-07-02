#!/usr/bin/env bash
#
# Build FreeRDP (>= 3.26, the version the bridge requires) as MINIMAL DYNAMIC
# dylibs and assemble a self-contained, relocated set into
# Sources/Vendor/FreeRDPDylibs/, ready to be embedded in the app's
# Contents/Frameworks. This removes the runtime Homebrew dependency for RDP.
#
# Why dynamic (not the existing static FreeRDP.xcframework): the bridge
# (Sources/FreeRDPBridge/CBFreeRDPClient.m) loads FreeRDP at runtime via
# dlopen("libfreerdp3.dylib") + dlsym, checking Contents/Frameworks FIRST. So a
# bundled dynamic libfreerdp3.dylib is what makes RDP self-contained.
#
# Why not Homebrew's freerdp: it is 3.20 (< the bridge's 3.26 gate) and its
# dynamic closure drags in ffmpeg + X11 (unbundleable). This minimal build
# (WITH_X11=OFF, WITH_FFMPEG=OFF, audio codecs OFF, OpenSSL-only) has a tiny
# closure (winpr + openssl + libusb), all of which we bundle + relocate.
#
# Output: Sources/Vendor/FreeRDPDylibs/*.dylib — all relocated to @loader_path
# so they resolve each other inside Frameworks. Final Developer-ID signing
# happens later in package_app.sh (resign_embedded_code).
#
# NOTE: macOS /bin/bash is 3.2 — keep this script free of associative arrays
# (declare -A) and ${var,,}; use plain indexed/string state only.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FREERDP_BRANCH="${FREERDP_BRANCH:-3.26.0}"
ARCH="${ARCH:-arm64}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-14.0}"
WORK_DIR="${SKYBRIDGE_FREERDP_WORK_DIR:-${TMPDIR:-/tmp}/skybridge-freerdp-dylibs}"
SRC_DIR="$WORK_DIR/FreeRDP"
BUILD_DIR="$WORK_DIR/build-$ARCH"
OUT_DIR="$ROOT/Sources/Vendor/FreeRDPDylibs"
STAGE_DIR="$WORK_DIR/stage-$ARCH"
DEPS_PREFIX="${SKYBRIDGE_FREERDP_DEPS_PREFIX:-$WORK_DIR/deps-$ARCH}"
OPENSSL_REF="${SKYBRIDGE_FREERDP_OPENSSL_REF:-openssl-3.6.2}"
CJSON_REF="${SKYBRIDGE_FREERDP_CJSON_REF:-v1.7.19}"
JANSSON_REF="${SKYBRIDGE_FREERDP_JANSSON_REF:-v2.15.0}"
URIPARSER_REF="${SKYBRIDGE_FREERDP_URIPARSER_REF:-uriparser-1.0.2}"
BUILD_PRIVATE_DEPS="${SKYBRIDGE_FREERDP_BUILD_PRIVATE_DEPS:-1}"

command -v cmake >/dev/null 2>&1 || { echo "❌ need cmake (brew install cmake)"; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "❌ need ninja (brew install ninja)"; exit 1; }
LIBUSB_ROOT="$(brew --prefix libusb 2>/dev/null || true)"

build_private_openssl() {
  local openssl_src="$WORK_DIR/openssl"

  if [[ -f "$DEPS_PREFIX/lib/libssl.3.dylib" && -f "$DEPS_PREFIX/lib/libcrypto.3.dylib" ]]; then
    return 0
  fi

  echo "ℹ️ Building private OpenSSL ${OPENSSL_REF} for macOS ${DEPLOYMENT_TARGET}..."
  rm -rf "$openssl_src"
  git clone --depth 1 --branch "$OPENSSL_REF" https://github.com/openssl/openssl.git "$openssl_src"
  (
    cd "$openssl_src"
    env MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
      ./Configure darwin64-arm64-cc shared no-tests \
      --prefix="$DEPS_PREFIX" \
      --openssldir="$DEPS_PREFIX/ssl" \
      "-mmacosx-version-min=$DEPLOYMENT_TARGET"
    make -j"$(sysctl -n hw.ncpu)"
    make install_sw
  )
}

build_private_cjson() {
  local cjson_src="$WORK_DIR/cJSON"
  local cjson_build="$WORK_DIR/cjson-build-$ARCH"

  if [[ -f "$DEPS_PREFIX/lib/libcjson.1.dylib" ]]; then
    return 0
  fi

  echo "ℹ️ Building private cJSON ${CJSON_REF} for macOS ${DEPLOYMENT_TARGET}..."
  rm -rf "$cjson_src" "$cjson_build"
  git clone --depth 1 --branch "$CJSON_REF" https://github.com/DaveGamble/cJSON.git "$cjson_src"
  cmake -S "$cjson_src" -B "$cjson_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=ON \
    -DENABLE_CJSON_TEST=OFF \
    -DENABLE_CJSON_UTILS=OFF \
    -DENABLE_CUSTOM_COMPILER_FLAGS=OFF
  cmake --build "$cjson_build" -j"$(sysctl -n hw.ncpu)"
  cmake --install "$cjson_build"
}

build_private_jansson() {
  local jansson_src="$WORK_DIR/jansson"
  local jansson_build="$WORK_DIR/jansson-build-$ARCH"

  if [[ -f "$DEPS_PREFIX/lib/libjansson.4.dylib" ]]; then
    return 0
  fi

  echo "ℹ️ Building private jansson ${JANSSON_REF} for macOS ${DEPLOYMENT_TARGET}..."
  rm -rf "$jansson_src" "$jansson_build"
  git clone --depth 1 --branch "$JANSSON_REF" https://github.com/akheron/jansson.git "$jansson_src"
  cmake -S "$jansson_src" -B "$jansson_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=ON \
    -DJANSSON_BUILD_SHARED_LIBS=ON \
    -DJANSSON_BUILD_DOCS=OFF \
    -DJANSSON_EXAMPLES=OFF \
    -DJANSSON_WITHOUT_TESTS=ON
  cmake --build "$jansson_build" -j"$(sysctl -n hw.ncpu)"
  cmake --install "$jansson_build"
}

build_private_uriparser() {
  local uriparser_src="$WORK_DIR/uriparser"
  local uriparser_build="$WORK_DIR/uriparser-build-$ARCH"

  if [[ -f "$DEPS_PREFIX/lib/liburiparser.1.dylib" ]]; then
    return 0
  fi

  echo "ℹ️ Building private uriparser ${URIPARSER_REF} for macOS ${DEPLOYMENT_TARGET}..."
  rm -rf "$uriparser_src" "$uriparser_build"
  git clone --depth 1 --branch "$URIPARSER_REF" https://github.com/uriparser/uriparser.git "$uriparser_src"
  cmake -S "$uriparser_src" -B "$uriparser_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=ON \
    -DURIPARSER_BUILD_DOCS=OFF \
    -DURIPARSER_BUILD_TESTS=OFF \
    -DURIPARSER_BUILD_TOOLS=OFF
  cmake --build "$uriparser_build" -j"$(sysctl -n hw.ncpu)"
  cmake --install "$uriparser_build"
}

if [[ "$BUILD_PRIVATE_DEPS" == "1" ]]; then
  mkdir -p "$DEPS_PREFIX"
  build_private_openssl
  build_private_cjson
  build_private_jansson
  build_private_uriparser
  OPENSSL_ROOT="$DEPS_PREFIX"
else
  OPENSSL_ROOT="${SKYBRIDGE_FREERDP_OPENSSL_ROOT:-$(brew --prefix openssl@3 2>/dev/null || true)}"
  [[ -n "$OPENSSL_ROOT" ]] || { echo "❌ need openssl@3 (brew install openssl@3)"; exit 1; }
fi

export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="$DEPS_PREFIX:${CMAKE_PREFIX_PATH:-}"

echo "ℹ️ FreeRDP ${FREERDP_BRANCH} dynamic build (arch=$ARCH, openssl=$OPENSSL_ROOT)"
mkdir -p "$WORK_DIR"
if [[ ! -d "$SRC_DIR/.git" ]]; then
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$FREERDP_BRANCH" https://github.com/FreeRDP/FreeRDP.git "$SRC_DIR"
fi
# Force a clean reconfigure so disabled-feature flags below fully take effect
# (cmake caches prior config; stale swscale/urbdrc objects must be dropped).
rm -rf "$BUILD_DIR"

cmake -S "$SRC_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
  -DCMAKE_C_FLAGS="-O3 -fno-lto" \
  -DCMAKE_CXX_FLAGS="-O3 -fno-lto" \
  -DBUILD_SHARED_LIBS=ON \
  -DWITH_CLIENT=ON \
  -DWITH_CLIENT_SDL=OFF \
  -DWITH_CLIENT_MAC=OFF \
  -DWITH_SAMPLE=OFF \
  -DWITH_SERVER=OFF \
  -DWITH_X11=OFF \
  -DWITH_SDL=OFF \
  -DWITH_SDL2=OFF \
  -DWITH_SDL2_TTF=OFF \
  -DWITH_SDL_IMAGE_DIALOGS=OFF \
  -DWITH_ALSA=OFF \
  -DWITH_PULSE=OFF \
  -DWITH_FFMPEG=OFF \
  -DWITH_SWSCALE=OFF \
  -DWITH_OPUS=OFF \
  -DWITH_FAAD2=OFF \
  -DWITH_FAAC=OFF \
  -DWITH_SOXR=OFF \
  -DWITH_URBDRC=OFF \
  -DCHANNEL_URBDRC=OFF \
  -DWITH_OPENSSL=ON \
  -DCMAKE_PREFIX_PATH="$DEPS_PREFIX" \
  -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT"

cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"

# --- Assemble a self-contained, relocated dylib set (bash 3.2 safe) ----------

# Normalize a dep/source dylib path -> the basename we bundle it under.
# FreeRDP/winpr/openssl get unversioned names (the bridge dlopens libfreerdp3.dylib);
# everything else keeps its real basename.
norm_name() {
  case "$(basename "$1")" in
    libfreerdp3.*) echo "libfreerdp3.dylib" ;;
    libfreerdp-client3.*) echo "libfreerdp-client3.dylib" ;;
    libwinpr3.*) echo "libwinpr3.dylib" ;;
    libssl.*) echo "libssl.3.dylib" ;;
    libcrypto.*) echo "libcrypto.3.dylib" ;;
    *) basename "$1" ;;
  esac
}

# Resolve an otool -L dependency string to an actual source file (empty = system lib).
resolve_dep() {
  local dep="$1" b f
  case "$dep" in
    /usr/lib/*|/System/*|@loader_path/*|@executable_path/*) echo ""; return ;;
    /*) [[ -f "$dep" ]] && echo "$dep" || echo ""; return ;;
    @rpath/*) b="${dep#@rpath/}" ;;
    *) b="$(basename "$dep")" ;;
  esac
  f="$(find "$BUILD_DIR" -name "$b" \( -type f -o -type l \) 2>/dev/null | head -1)"
  [[ -z "$f" && -n "$OPENSSL_ROOT" ]] && f="$(find "$OPENSSL_ROOT/lib" -name "$b" \( -type f -o -type l \) 2>/dev/null | head -1)"
  [[ -z "$f" && -n "$LIBUSB_ROOT" ]] && f="$(find "$LIBUSB_ROOT/lib" -name "$b" \( -type f -o -type l \) 2>/dev/null | head -1)"
  echo "$f"
}

rm -rf "$STAGE_DIR"; mkdir -p "$STAGE_DIR"

# Seed with the three built FreeRDP dylibs.
for pat in "libfreerdp3" "libfreerdp-client3" "libwinpr3"; do
  f="$(find "$BUILD_DIR" -name "${pat}.*.dylib" -type f | head -1)"
  [[ -n "$f" ]] || { echo "❌ built dylib not found: ${pat}.*.dylib"; exit 1; }
  cp -f "$f" "$STAGE_DIR/$(norm_name "$f")"; chmod u+w "$STAGE_DIR/$(norm_name "$f")"
done

# Self-completing: iteratively pull in any remaining non-system dependency
# (OpenSSL, cjson, …) from the build tree or Homebrew until the closure is closed.
for _pass in 1 2 3 4 5 6; do
  added=0
  for dst in "$STAGE_DIR"/*.dylib; do
    while read -r dep; do
      case "$dep" in /usr/lib/*|/System/*|@loader_path/*|@executable_path/*) continue ;; esac
      n="$(norm_name "$dep")"
      [[ -f "$STAGE_DIR/$n" ]] && continue
      src=""
      case "$dep" in
        /*) [[ -f "$dep" ]] && src="$dep" ;;
        @rpath/*)
          src="$(find "$BUILD_DIR" -name "${dep#@rpath/}" \( -type f -o -type l \) 2>/dev/null | head -1)"
          [[ -z "$src" ]] && src="$(find "$DEPS_PREFIX/lib" -name "${dep#@rpath/}" \( -type f -o -type l \) 2>/dev/null | head -1)"
          ;;
      esac
      [[ -z "$src" ]] && src="$(find "$DEPS_PREFIX/lib" -name "$(basename "$dep")" \( -type f -o -type l \) 2>/dev/null | head -1)"
      [[ -z "$src" ]] && src="$(find /opt/homebrew/opt/*/lib -name "$(basename "$dep")" \( -type f -o -type l \) 2>/dev/null | head -1)"
      if [[ -n "$src" && -f "$src" ]]; then
        cp -f "$src" "$STAGE_DIR/$n"; chmod u+w "$STAGE_DIR/$n"; added=1
      fi
    done < <(otool -L "$dst" | tail -n +2 | awk '{print $1}')
  done
  [[ "$added" -eq 0 ]] && break
done

# Rewrite ids + cross-dependency paths to @loader_path so the set is relocatable, then ad-hoc sign.
for dst in "$STAGE_DIR"/*.dylib; do
  install_name_tool -id "@loader_path/$(basename "$dst")" "$dst"
  while read -r dep; do
    case "$dep" in /usr/lib/*|/System/*|@loader_path/*) continue ;; esac
    n="$(norm_name "$dep")"
    [[ -f "$STAGE_DIR/$n" ]] && install_name_tool -change "$dep" "@loader_path/$n" "$dst"
  done < <(otool -L "$dst" | tail -n +2 | awk '{print $1}')
  codesign --force --sign - "$dst" >/dev/null 2>&1 || true
done

# Strict closure check: every bundled dylib must reference ONLY @loader_path + system libs.
leak=0
for dst in "$STAGE_DIR"/*.dylib; do
  bad="$(otool -L "$dst" | tail -n +2 | awk '{print $1}' | grep -vE "^@loader_path/|^/usr/lib/|^/System/" || true)"
  if [[ -n "$bad" ]]; then
    echo "❌ $(basename "$dst") still references non-bundled paths:"; echo "$bad" | sed 's/^/      /'
    leak=1
  fi
done
[[ "$leak" -eq 0 ]] || { echo "❌ closure NOT self-contained — add the missing lib to the bundle"; exit 1; }
echo "✅ closure self-contained (only @loader_path + system libs)"

if ! env -u SKYBRIDGE_FILE_TOOL -u SKYBRIDGE_OTOOL_TOOL \
  bash "$ROOT/Scripts/check_macos_deps.sh" --strict "$STAGE_DIR" "$DEPLOYMENT_TARGET"; then
  echo "❌ FreeRDP dylib closure exceeds macOS ${DEPLOYMENT_TARGET} deployment target." >&2
  echo "   Rebuild OpenSSL/cJSON with the same deployment target; do not rewrite Mach-O minos metadata as a compatibility substitute." >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$(dirname "$OUT_DIR")"
mv "$STAGE_DIR" "$OUT_DIR"

echo "✅ assembled relocated FreeRDP dylibs -> ${OUT_DIR#$ROOT/}"
ls -1 "$OUT_DIR"
