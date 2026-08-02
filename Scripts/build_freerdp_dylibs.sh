#!/usr/bin/env bash
#
# Build the exact FreeRDP version required by the bridge as MINIMAL DYNAMIC
# dylibs and assemble a self-contained, relocated set into
# Sources/Vendor/FreeRDPDylibs/, ready to be embedded in the app's
# Contents/Frameworks. This removes the runtime Homebrew dependency for RDP.
#
# Why dynamic (rather than a static FreeRDP XCFramework): the bridge
# (Sources/FreeRDPBridge/CBFreeRDPClient.m) loads FreeRDP at runtime via
# dlopen("libfreerdp3.dylib") + dlsym, checking Contents/Frameworks FIRST. So a
# bundled dynamic libfreerdp3.dylib is what makes RDP self-contained.
#
# Why not Homebrew's FreeRDP: a package-manager runtime is mutable and its
# default closure includes features this app does not use. This minimal build
# disables X11, FFmpeg, audio codecs, and USB redirection, and bundles only the
# reviewed WinPR, OpenSSL, Jansson, and uriparser closure.
#
# Output: Sources/Vendor/FreeRDPDylibs/*.dylib — all relocated to @loader_path
# so they resolve each other inside Frameworks. Final Developer-ID signing
# happens later in package_app.sh (resign_embedded_code).
#
# NOTE: macOS /bin/bash is 3.2 — keep this script free of associative arrays
# (declare -A) and ${var,,}; use plain indexed/string state only.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_DEPENDENCY_LOCK="$ROOT/Config/native-dependencies.lock.json"
REQUESTED_FREERDP_REF_SET="${SKYBRIDGE_FREERDP_REF+x}"
REQUESTED_FREERDP_REF="${SKYBRIDGE_FREERDP_REF-}"
REQUESTED_FREERDP_COMMIT_SET="${SKYBRIDGE_FREERDP_COMMIT+x}"
REQUESTED_FREERDP_COMMIT="${SKYBRIDGE_FREERDP_COMMIT-}"
REQUESTED_OPENSSL_REF_SET="${SKYBRIDGE_FREERDP_OPENSSL_REF+x}"
REQUESTED_OPENSSL_REF="${SKYBRIDGE_FREERDP_OPENSSL_REF-}"
REQUESTED_OPENSSL_COMMIT_SET="${SKYBRIDGE_FREERDP_OPENSSL_COMMIT+x}"
REQUESTED_OPENSSL_COMMIT="${SKYBRIDGE_FREERDP_OPENSSL_COMMIT-}"
REQUESTED_JANSSON_REF_SET="${SKYBRIDGE_FREERDP_JANSSON_REF+x}"
REQUESTED_JANSSON_REF="${SKYBRIDGE_FREERDP_JANSSON_REF-}"
REQUESTED_JANSSON_COMMIT_SET="${SKYBRIDGE_FREERDP_JANSSON_COMMIT+x}"
REQUESTED_JANSSON_COMMIT="${SKYBRIDGE_FREERDP_JANSSON_COMMIT-}"
REQUESTED_URIPARSER_REF_SET="${SKYBRIDGE_FREERDP_URIPARSER_REF+x}"
REQUESTED_URIPARSER_REF="${SKYBRIDGE_FREERDP_URIPARSER_REF-}"
REQUESTED_URIPARSER_COMMIT_SET="${SKYBRIDGE_FREERDP_URIPARSER_COMMIT+x}"
REQUESTED_URIPARSER_COMMIT="${SKYBRIDGE_FREERDP_URIPARSER_COMMIT-}"
REQUESTED_GOOGLETEST_REF_SET="${SKYBRIDGE_FREERDP_GOOGLETEST_REF+x}"
REQUESTED_GOOGLETEST_REF="${SKYBRIDGE_FREERDP_GOOGLETEST_REF-}"
REQUESTED_GOOGLETEST_COMMIT_SET="${SKYBRIDGE_FREERDP_GOOGLETEST_COMMIT+x}"
REQUESTED_GOOGLETEST_COMMIT="${SKYBRIDGE_FREERDP_GOOGLETEST_COMMIT-}"
REQUESTED_ARCH_SET="${ARCH+x}"
REQUESTED_ARCH="${ARCH-}"
REQUESTED_DEPLOYMENT_TARGET_SET="${DEPLOYMENT_TARGET+x}"
REQUESTED_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET-}"
REQUESTED_BUILD_PRIVATE_DEPS_SET="${SKYBRIDGE_FREERDP_BUILD_PRIVATE_DEPS+x}"
REQUESTED_BUILD_PRIVATE_DEPS="${SKYBRIDGE_FREERDP_BUILD_PRIVATE_DEPS-}"

command -v python3 >/dev/null 2>&1 || { echo "❌ need python3"; exit 1; }
LOCKED_CONFIGURATION="$(python3 - "$ROOT" "$NATIVE_DEPENDENCY_LOCK" <<'PY'
import importlib.util
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
lock_path = pathlib.Path(sys.argv[2])
module_path = root / "Scripts/native_vendor_provenance.py"
spec = importlib.util.spec_from_file_location("native_vendor_provenance", module_path)
if spec is None or spec.loader is None:
    raise SystemExit(f"could not load native provenance module: {module_path}")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
family, _ = module.load_locked_family(lock_path, root, "freerdp-runtime")

expected_source_names = ["freerdp", "openssl", "jansson", "uriparser", "googletest"]
if [source["name"] for source in family["sources"]] != expected_source_names:
    raise SystemExit("FreeRDP runtime lock source order or membership differs from the recipe")

expected_inputs = {
    "architecture": "arm64",
    "audio": "disabled",
    "audio_redirection": "disabled",
    "build_jobs": "8",
    "build_type": "Release",
    "cairo": "disabled",
    "channel_plugins": "not-built",
    "channel_registration": "none",
    "clang_format": "disabled",
    "client_common": "disabled",
    "dependency_resolution": "private-only",
    "deployment_target": "14.0",
    "device_redirection": "disabled",
    "dsp_ffmpeg": "disabled",
    "fdk_aac": "disabled",
    "feature_scope": "freerdp-core-winpr-software-gdi-bgra-classic-bitmap-nscodec-basic-input-no-client-common-no-channel-plugins",
    "freerdp_local_patch_sha256": "48f7bf519a230a01ab25f178ff00968e78066511b76fb9db6f1a35a8691262f3",
    "freerdp_3x_deprecated": "disabled",
    "freerdp_test_scope": "winpr-synch-all",
    "jansson_local_patch_sha256": "eb7c26d605d020c60c9f25b62b43b0e229e12f0953b0fd0ba9b995026415b2a8",
    "linkage": "dynamic",
    "openssl_abi": "4",
    "openssl_local_patch_sha256": "4e3c460e9b7f0619c80ae02bba2800ef172e4fdba07bf0b97144311774b7fb7b",
    "openssl_sonames": "libssl.4.dylib;libcrypto.4.dylib",
    "openssl_test_harness_jobs": "1",
    "pcsc": "disabled",
    "pkcs11": "disabled",
    "private_dependency_closure": "true",
    "runtime_gfx_h264": "disabled",
    "runtime_graphics_pipeline": "disabled",
    "runtime_remotefx": "disabled",
    "smartcard": "disabled",
    "source_revision": "embedded-and-verified",
    "uriparser_local_patch_sha256": "65f13fb1c134ae4b06f1022d080f04124f592bf47317c389b345d948b612dca9",
    "warning_suppressions": "forbidden",
    "winpr_3x_deprecated": "disabled",
}
locked_build_jobs = family["build_inputs"].get("build_jobs")
if (
    not isinstance(locked_build_jobs, str)
    or locked_build_jobs not in tuple(str(value) for value in range(1, 33))
):
    raise SystemExit("FreeRDP runtime build_jobs must be a canonical integer from 1 through 32")
if family["build_inputs"] != expected_inputs:
    raise SystemExit("FreeRDP runtime lock build inputs differ from the exact recipe contract")

values = []
for source in family["sources"]:
    values.extend(
        [source["version"], source["ref"], source["commit"], source["repository"]]
    )
values.extend(
    [
        expected_inputs["architecture"],
        expected_inputs["deployment_target"],
        locked_build_jobs,
    ]
)
if any("\t" in value or "\n" in value or "\r" in value for value in values):
    raise SystemExit("FreeRDP runtime lock contains a control character")
print("\t".join(values))
PY
)"
IFS=$'\t' read -r \
  FREERDP_VERSION FREERDP_REF FREERDP_COMMIT FREERDP_REPOSITORY \
  OPENSSL_VERSION OPENSSL_REF OPENSSL_COMMIT OPENSSL_REPOSITORY \
  JANSSON_VERSION JANSSON_REF JANSSON_COMMIT JANSSON_REPOSITORY \
  URIPARSER_VERSION URIPARSER_REF URIPARSER_COMMIT URIPARSER_REPOSITORY \
  GOOGLETEST_VERSION GOOGLETEST_REF GOOGLETEST_COMMIT GOOGLETEST_REPOSITORY \
  LOCKED_ARCH LOCKED_DEPLOYMENT_TARGET LOCKED_BUILD_JOBS <<<"$LOCKED_CONFIGURATION"

reject_divergent_override() {
  local variable_name="$1" was_set="$2" requested="$3" locked="$4"
  if [[ "$was_set" == "x" && "$requested" != "$locked" ]]; then
    echo "❌ ${variable_name} differs from Config/native-dependencies.lock.json" >&2
    exit 1
  fi
}

reject_divergent_override SKYBRIDGE_FREERDP_REF "$REQUESTED_FREERDP_REF_SET" "$REQUESTED_FREERDP_REF" "$FREERDP_REF"
reject_divergent_override SKYBRIDGE_FREERDP_COMMIT "$REQUESTED_FREERDP_COMMIT_SET" "$REQUESTED_FREERDP_COMMIT" "$FREERDP_COMMIT"
reject_divergent_override SKYBRIDGE_FREERDP_OPENSSL_REF "$REQUESTED_OPENSSL_REF_SET" "$REQUESTED_OPENSSL_REF" "$OPENSSL_REF"
reject_divergent_override SKYBRIDGE_FREERDP_OPENSSL_COMMIT "$REQUESTED_OPENSSL_COMMIT_SET" "$REQUESTED_OPENSSL_COMMIT" "$OPENSSL_COMMIT"
reject_divergent_override SKYBRIDGE_FREERDP_JANSSON_REF "$REQUESTED_JANSSON_REF_SET" "$REQUESTED_JANSSON_REF" "$JANSSON_REF"
reject_divergent_override SKYBRIDGE_FREERDP_JANSSON_COMMIT "$REQUESTED_JANSSON_COMMIT_SET" "$REQUESTED_JANSSON_COMMIT" "$JANSSON_COMMIT"
reject_divergent_override SKYBRIDGE_FREERDP_URIPARSER_REF "$REQUESTED_URIPARSER_REF_SET" "$REQUESTED_URIPARSER_REF" "$URIPARSER_REF"
reject_divergent_override SKYBRIDGE_FREERDP_URIPARSER_COMMIT "$REQUESTED_URIPARSER_COMMIT_SET" "$REQUESTED_URIPARSER_COMMIT" "$URIPARSER_COMMIT"
reject_divergent_override SKYBRIDGE_FREERDP_GOOGLETEST_REF "$REQUESTED_GOOGLETEST_REF_SET" "$REQUESTED_GOOGLETEST_REF" "$GOOGLETEST_REF"
reject_divergent_override SKYBRIDGE_FREERDP_GOOGLETEST_COMMIT "$REQUESTED_GOOGLETEST_COMMIT_SET" "$REQUESTED_GOOGLETEST_COMMIT" "$GOOGLETEST_COMMIT"
reject_divergent_override ARCH "$REQUESTED_ARCH_SET" "$REQUESTED_ARCH" "$LOCKED_ARCH"
reject_divergent_override DEPLOYMENT_TARGET "$REQUESTED_DEPLOYMENT_TARGET_SET" "$REQUESTED_DEPLOYMENT_TARGET" "$LOCKED_DEPLOYMENT_TARGET"
reject_divergent_override SKYBRIDGE_FREERDP_BUILD_PRIVATE_DEPS "$REQUESTED_BUILD_PRIVATE_DEPS_SET" "$REQUESTED_BUILD_PRIVATE_DEPS" "1"

ARCH="$LOCKED_ARCH"
DEPLOYMENT_TARGET="$LOCKED_DEPLOYMENT_TARGET"
BUILD_JOBS="$LOCKED_BUILD_JOBS"
BUILD_PRIVATE_DEPS=1

canonicalize_build_path() {
  python3 - "$1" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1]).expanduser()
if not path.is_absolute():
    raise SystemExit("native build paths must be absolute")
print(path.resolve(strict=False))
PY
}

TEMP_ROOT="${TMPDIR:-/tmp}"
WORK_DIR="$(canonicalize_build_path "${SKYBRIDGE_FREERDP_WORK_DIR:-${TEMP_ROOT%/}/skybridge-freerdp-dylibs-$$}")"
SRC_DIR="$WORK_DIR/FreeRDP"
FREERDP_BUILD_SOURCE_DIR="$WORK_DIR/freerdp-build-source-$ARCH"
BUILD_DIR="$WORK_DIR/build-$ARCH"
OUT_DIR="$ROOT/Sources/Vendor/FreeRDPDylibs"
HEADERS_OUT_DIR="$ROOT/Sources/Vendor/FreeRDPHeaders"
PROVENANCE_OUT="$ROOT/Sources/Vendor/FreeRDPRuntime.provenance.json"
LICENSES_OUT_DIR="$ROOT/Sources/Vendor/NativeLicenses/FreeRDP-runtime"
STAGE_DIR="$WORK_DIR/stage-$ARCH"
HEADERS_STAGE_DIR="$WORK_DIR/headers-stage-$ARCH"
LICENSES_STAGE_DIR="$WORK_DIR/licenses-stage-$ARCH"
DEPS_PREFIX="$(canonicalize_build_path "${SKYBRIDGE_FREERDP_DEPS_PREFIX:-$WORK_DIR/deps-$ARCH}")"
OPENSSL_PATCH_PATH="$ROOT/Scripts/Patches/openssl-4.0.1-mkinstallvars-defaults.patch"
OPENSSL_PATCH_SHA256="4e3c460e9b7f0619c80ae02bba2800ef172e4fdba07bf0b97144311774b7fb7b"
FREERDP_PATCH_PATH="$ROOT/Scripts/Patches/freerdp-3.30.0-appleclang-cmake4.patch"
FREERDP_PATCH_SHA256="48f7bf519a230a01ab25f178ff00968e78066511b76fb9db6f1a35a8691262f3"
JANSSON_PATCH_PATH="$ROOT/Scripts/Patches/jansson-2.15.1-cmake-package-version.patch"
JANSSON_PATCH_SHA256="eb7c26d605d020c60c9f25b62b43b0e229e12f0953b0fd0ba9b995026415b2a8"
URIPARSER_PATCH_PATH="$ROOT/Scripts/Patches/uriparser-1.0.2-appleclang-gtest.patch"
URIPARSER_PATCH_SHA256="65f13fb1c134ae4b06f1022d080f04124f592bf47317c389b345d948b612dca9"
PATCH_SNAPSHOT_DIR="$WORK_DIR/reviewed-patches"
OPENSSL_PATCH_INPUT="$PATCH_SNAPSHOT_DIR/$(basename "$OPENSSL_PATCH_PATH")"
FREERDP_PATCH_INPUT="$PATCH_SNAPSHOT_DIR/$(basename "$FREERDP_PATCH_PATH")"
JANSSON_PATCH_INPUT="$PATCH_SNAPSHOT_DIR/$(basename "$JANSSON_PATCH_PATH")"
URIPARSER_PATCH_INPUT="$PATCH_SNAPSHOT_DIR/$(basename "$URIPARSER_PATCH_PATH")"

command -v cmake >/dev/null 2>&1 || { echo "❌ need cmake (brew install cmake)"; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "❌ need ninja (brew install ninja)"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "❌ need git"; exit 1; }
command -v patch >/dev/null 2>&1 || { echo "❌ need patch"; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "❌ need shasum"; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "❌ need tar"; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "❌ need Xcode command-line tools"; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo "❌ need full Xcode"; exit 1; }
[[ "$ARCH" == "arm64" ]] || {
  echo "❌ the reviewed FreeRDP recipe currently supports arm64 only" >&2
  exit 1
}
source "$ROOT/Scripts/native_source_helpers.sh"
# shellcheck source=Scripts/freerdp_runtime_publish_transaction.sh
source "$ROOT/Scripts/freerdp_runtime_publish_transaction.sh"

XCODE_DEVELOPER_DIR="$(xcode-select -p)"
[[ -x "$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" ]] || {
  echo "❌ xcode-select must point at a full Xcode installation" >&2
  exit 1
}
MACOS_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MACOS_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
CLANG_PATH="$(xcrun --find clang)"
CLANGXX_PATH="$(xcrun --find clang++)"
XCODE_VERSION="$(xcodebuild -version | tr '\n' ';' | sed 's/;$//')"
CLANG_VERSION="$(xcrun clang --version | head -n 1)"
CMAKE_VERSION="$(cmake --version | head -n 1)"
NINJA_VERSION="$(ninja --version)"
[[ "$MACOS_SDK_PATH" == "$XCODE_DEVELOPER_DIR"/* ]] || {
  echo "❌ macOS SDK is outside the selected Xcode: $MACOS_SDK_PATH" >&2
  exit 1
}
[[ "$CLANG_PATH" == "$XCODE_DEVELOPER_DIR"/* && "$CLANGXX_PATH" == "$XCODE_DEVELOPER_DIR"/* ]] || {
  echo "❌ compiler is outside the selected Xcode toolchain" >&2
  exit 1
}
python3 - \
  "$ROOT" \
  "$NATIVE_DEPENDENCY_LOCK" \
  "$XCODE_VERSION" \
  "$MACOS_SDK_VERSION" \
  "$CLANG_VERSION" \
  "$CMAKE_VERSION" \
  "$NINJA_VERSION" <<'PY'
import importlib.util
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
lock_path = pathlib.Path(sys.argv[2])
module_path = root / "Scripts/native_vendor_provenance.py"
spec = importlib.util.spec_from_file_location("native_vendor_provenance", module_path)
if spec is None or spec.loader is None:
    raise SystemExit(f"could not load native provenance module: {module_path}")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
family, _ = module.load_locked_family(lock_path, root, "freerdp-runtime")
actual = {
    "xcode": sys.argv[3],
    "macos_sdk": sys.argv[4],
    "clang": sys.argv[5],
    "cmake": sys.argv[6],
    "ninja": sys.argv[7],
}
if actual != family["toolchain"]:
    raise SystemExit(
        "selected native toolchain differs from Config/native-dependencies.lock.json"
    )
PY

verify_reviewed_patch() {
  local name="$1" path="$2" expected_sha256="$3"
  [[ -f "$path" && ! -L "$path" ]] || {
    echo "❌ missing reviewed ${name} patch: $path" >&2
    exit 1
  }
  [[ "$(shasum -a 256 "$path" | awk '{print $1}')" == "$expected_sha256" ]] || {
    echo "❌ ${name} local patch differs from the reviewed SHA-256" >&2
    exit 1
  }
}

reject_warning_suppressions() {
  local build_file="$1" component="$2"
  local forbidden_warning_suppression="-Wno-"
  [[ -f "$build_file" ]] || {
    echo "❌ missing generated ${component} build contract: $build_file" >&2
    exit 1
  }
  if grep -Fq -- "$forbidden_warning_suppression" "$build_file"; then
    echo "❌ ${component} generated compile commands contain forbidden warning suppressions:" >&2
    grep -nF -- "$forbidden_warning_suppression" "$build_file" >&2
    exit 1
  fi
  if grep -Eq '(^|[[:space:]])-w([[:space:]]|$)' "$build_file"; then
    echo "❌ ${component} generated compile commands disable all warnings:" >&2
    grep -nE '(^|[[:space:]])-w([[:space:]]|$)' "$build_file" >&2
    exit 1
  fi
}

BUILD_RECIPE_SHA256="$(shasum -a 256 "$ROOT/Scripts/build_freerdp_dylibs.sh" | awk '{print $1}')"
verify_reviewed_patch "OpenSSL" "$OPENSSL_PATCH_PATH" "$OPENSSL_PATCH_SHA256"
verify_reviewed_patch "FreeRDP" "$FREERDP_PATCH_PATH" "$FREERDP_PATCH_SHA256"
verify_reviewed_patch "Jansson" "$JANSSON_PATCH_PATH" "$JANSSON_PATCH_SHA256"
verify_reviewed_patch "uriparser" "$URIPARSER_PATCH_PATH" "$URIPARSER_PATCH_SHA256"
rm -rf "$PATCH_SNAPSHOT_DIR"
mkdir -p "$PATCH_SNAPSHOT_DIR"
cp "$OPENSSL_PATCH_PATH" "$OPENSSL_PATCH_INPUT"
cp "$FREERDP_PATCH_PATH" "$FREERDP_PATCH_INPUT"
cp "$JANSSON_PATCH_PATH" "$JANSSON_PATCH_INPUT"
cp "$URIPARSER_PATCH_PATH" "$URIPARSER_PATCH_INPUT"
chmod 0444 "$PATCH_SNAPSHOT_DIR"/*
verify_reviewed_patch "OpenSSL snapshot" "$OPENSSL_PATCH_INPUT" "$OPENSSL_PATCH_SHA256"
verify_reviewed_patch "FreeRDP snapshot" "$FREERDP_PATCH_INPUT" "$FREERDP_PATCH_SHA256"
verify_reviewed_patch "Jansson snapshot" "$JANSSON_PATCH_INPUT" "$JANSSON_PATCH_SHA256"
verify_reviewed_patch "uriparser snapshot" "$URIPARSER_PATCH_INPUT" "$URIPARSER_PATCH_SHA256"
DEPS_INPUTS="$(cat <<EOF
arch=${ARCH}
deployment_target=${DEPLOYMENT_TARGET}
build_jobs=${BUILD_JOBS}
recipe_sha256=${BUILD_RECIPE_SHA256}
cmake=${CMAKE_VERSION}
ninja=${NINJA_VERSION}
clang=${CLANG_VERSION}
xcode=${XCODE_VERSION}
macos_sdk=${MACOS_SDK_VERSION}
macos_sdk_path=${MACOS_SDK_PATH}
openssl=${OPENSSL_REF}@${OPENSSL_COMMIT}
openssl_patch_sha256=${OPENSSL_PATCH_SHA256}
jansson=${JANSSON_REF}@${JANSSON_COMMIT}
jansson_patch_sha256=${JANSSON_PATCH_SHA256}
uriparser=${URIPARSER_REF}@${URIPARSER_COMMIT}
uriparser_patch_sha256=${URIPARSER_PATCH_SHA256}
googletest=${GOOGLETEST_REF}@${GOOGLETEST_COMMIT}
freerdp_patch_sha256=${FREERDP_PATCH_SHA256}
EOF
)"
DEPS_STAMP="$DEPS_PREFIX/.skybridge-native-inputs"
if [[ ! -f "$DEPS_STAMP" || "$(<"$DEPS_STAMP")" != "$DEPS_INPUTS" ]]; then
  rm -rf \
    "$DEPS_PREFIX" \
    "$WORK_DIR/openssl-build-source-$ARCH" \
    "$WORK_DIR/jansson-build-source-$ARCH" \
    "$WORK_DIR/jansson-build-$ARCH" \
    "$WORK_DIR/googletest-build-$ARCH" \
    "$WORK_DIR/uriparser-build-source-$ARCH" \
    "$WORK_DIR/uriparser-build-$ARCH"
fi

build_private_openssl() {
  local openssl_src="$WORK_DIR/openssl"
  local openssl_build_source="$WORK_DIR/openssl-build-source-$ARCH"

  skybridge_prepare_pinned_native_source \
    "$OPENSSL_REPOSITORY" "$OPENSSL_REF" "$OPENSSL_COMMIT" "$openssl_src"

  if [[ -f "$DEPS_PREFIX/lib/libssl.4.dylib" && -f "$DEPS_PREFIX/lib/libcrypto.4.dylib" ]]; then
    return 0
  fi

  echo "ℹ️ Building private OpenSSL ${OPENSSL_REF} for macOS ${DEPLOYMENT_TARGET}..."
  rm -rf "$openssl_build_source"
  mkdir -p "$openssl_build_source"
  git -C "$openssl_src" archive --format=tar HEAD | tar -xf - -C "$openssl_build_source"
  patch --batch --forward -F 0 -d "$openssl_build_source" -p1 <"$OPENSSL_PATCH_INPUT"
  (
    cd "$openssl_build_source"
    export CC="$CLANG_PATH"
    export CXX="$CLANGXX_PATH"
    export SDKROOT="$MACOS_SDK_PATH"
    export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    ./Configure darwin64-arm64-cc shared \
      --prefix="$DEPS_PREFIX" \
      --openssldir="$DEPS_PREFIX/ssl" \
      "-mmacosx-version-min=$DEPLOYMENT_TARGET" \
      -Werror
    reject_warning_suppressions "$openssl_build_source/Makefile" "OpenSSL"
    make -j"$BUILD_JOBS"
    make test HARNESS_JOBS=1
    make install_sw
  )
}

build_private_jansson() {
  local jansson_src="$WORK_DIR/jansson"
  local jansson_build_source="$WORK_DIR/jansson-build-source-$ARCH"
  local jansson_build="$WORK_DIR/jansson-build-$ARCH"

  skybridge_prepare_pinned_native_source \
    "$JANSSON_REPOSITORY" "$JANSSON_REF" "$JANSSON_COMMIT" "$jansson_src"

  if [[ -f "$DEPS_PREFIX/lib/libjansson.4.dylib" ]]; then
    return 0
  fi

  echo "ℹ️ Building private jansson ${JANSSON_REF} for macOS ${DEPLOYMENT_TARGET}..."
  rm -rf "$jansson_build_source"
  rm -rf "$jansson_build"
  mkdir -p "$jansson_build_source"
  git -C "$jansson_src" archive --format=tar HEAD | tar -xf - -C "$jansson_build_source"
  git -C "$jansson_build_source" apply --check "$JANSSON_PATCH_INPUT"
  git -C "$jansson_build_source" apply "$JANSSON_PATCH_INPUT"
  cmake -S "$jansson_build_source" -B "$jansson_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
    -DCMAKE_C_COMPILER="$CLANG_PATH" \
    -DCMAKE_OSX_SYSROOT="$MACOS_SDK_PATH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_C_FLAGS="-Werror" \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=ON \
    -DJANSSON_BUILD_SHARED_LIBS=ON \
    -DJANSSON_BUILD_DOCS=OFF \
    -DJANSSON_EXAMPLES=OFF \
    -DJANSSON_WITHOUT_TESTS=OFF
  reject_warning_suppressions "$jansson_build/build.ninja" "Jansson"
  cmake --build "$jansson_build" -j"$BUILD_JOBS"
  ctest --test-dir "$jansson_build" --output-on-failure
  cmake --install "$jansson_build"
  grep -Fq "set(PACKAGE_VERSION \"${JANSSON_VERSION}\")" \
    "$DEPS_PREFIX/lib/cmake/jansson/janssonConfigVersion.cmake" \
    || { echo "❌ installed Jansson CMake package has the wrong API version" >&2; exit 1; }
}

build_private_googletest() {
  local googletest_src="$WORK_DIR/googletest"
  local googletest_build="$WORK_DIR/googletest-build-$ARCH"

  skybridge_prepare_pinned_native_source \
    "$GOOGLETEST_REPOSITORY" "$GOOGLETEST_REF" "$GOOGLETEST_COMMIT" "$googletest_src"

  if [[ -f "$DEPS_PREFIX/lib/libgtest.a" && -f "$DEPS_PREFIX/lib/cmake/GTest/GTestConfig.cmake" ]]; then
    return 0
  fi

  echo "ℹ️ Building private GoogleTest ${GOOGLETEST_REF} for uriparser validation..."
  rm -rf "$googletest_build"
  cmake -S "$googletest_src" -B "$googletest_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
    -DCMAKE_CXX_COMPILER="$CLANGXX_PATH" \
    -DCMAKE_OSX_SYSROOT="$MACOS_SDK_PATH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_CXX_FLAGS="-Werror" \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
    -DBUILD_GMOCK=OFF \
    -DINSTALL_GTEST=ON \
    -Dgtest_build_tests=ON
  reject_warning_suppressions "$googletest_build/build.ninja" "GoogleTest"
  cmake --build "$googletest_build" -j"$BUILD_JOBS"
  ctest --test-dir "$googletest_build" --output-on-failure
  cmake --install "$googletest_build"
}

build_private_uriparser() {
  local uriparser_src="$WORK_DIR/uriparser"
  local uriparser_build_source="$WORK_DIR/uriparser-build-source-$ARCH"
  local uriparser_build="$WORK_DIR/uriparser-build-$ARCH"

  skybridge_prepare_pinned_native_source \
    "$URIPARSER_REPOSITORY" "$URIPARSER_REF" "$URIPARSER_COMMIT" "$uriparser_src"

  if [[ -f "$DEPS_PREFIX/lib/liburiparser.1.dylib" ]]; then
    return 0
  fi

  echo "ℹ️ Building private uriparser ${URIPARSER_REF} for macOS ${DEPLOYMENT_TARGET}..."
  rm -rf "$uriparser_build_source"
  rm -rf "$uriparser_build"
  mkdir -p "$uriparser_build_source"
  git -C "$uriparser_src" archive --format=tar HEAD | tar -xf - -C "$uriparser_build_source"
  git -C "$uriparser_build_source" apply --check "$URIPARSER_PATCH_INPUT"
  git -C "$uriparser_build_source" apply "$URIPARSER_PATCH_INPUT"
  cmake -S "$uriparser_build_source" -B "$uriparser_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" \
    -DCMAKE_C_COMPILER="$CLANG_PATH" \
    -DCMAKE_CXX_COMPILER="$CLANGXX_PATH" \
    -DCMAKE_OSX_SYSROOT="$MACOS_SDK_PATH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_C_FLAGS="-Werror" \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=ON \
    -DURIPARSER_BUILD_DOCS=OFF \
    -DURIPARSER_BUILD_TESTS=ON \
    -DURIPARSER_WARNINGS_AS_ERRORS=ON \
    -DURIPARSER_BUILD_TOOLS=OFF \
    -DGTest_DIR="$DEPS_PREFIX/lib/cmake/GTest"
  reject_warning_suppressions "$uriparser_build/build.ninja" "uriparser"
  cmake --build "$uriparser_build" -j"$BUILD_JOBS"
  ctest --test-dir "$uriparser_build" --output-on-failure
  cmake --install "$uriparser_build"
}

[[ "$BUILD_PRIVATE_DEPS" == "1" ]] || {
  echo "❌ vendored FreeRDP artifacts must use the pinned private dependency closure" >&2
  exit 1
}
mkdir -p "$DEPS_PREFIX"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$DEPS_PREFIX/lib/pkgconfig"
export CMAKE_PREFIX_PATH="$DEPS_PREFIX"
build_private_openssl
build_private_jansson
build_private_googletest
build_private_uriparser
printf '%s\n' "$DEPS_INPUTS" >"$DEPS_STAMP.tmp"
mv "$DEPS_STAMP.tmp" "$DEPS_STAMP"
OPENSSL_ROOT="$DEPS_PREFIX"

echo "ℹ️ FreeRDP ${FREERDP_REF} dynamic build (arch=$ARCH, openssl=$OPENSSL_ROOT)"
mkdir -p "$WORK_DIR"
skybridge_prepare_pinned_native_source "$FREERDP_REPOSITORY" "$FREERDP_REF" "$FREERDP_COMMIT" "$SRC_DIR"
rm -rf "$FREERDP_BUILD_SOURCE_DIR"
mkdir -p "$FREERDP_BUILD_SOURCE_DIR"
git -C "$SRC_DIR" archive --format=tar HEAD | tar -xf - -C "$FREERDP_BUILD_SOURCE_DIR"
printf '%s\n' "$FREERDP_COMMIT" >"$FREERDP_BUILD_SOURCE_DIR/.source_version"
git -C "$FREERDP_BUILD_SOURCE_DIR" apply --check "$FREERDP_PATCH_INPUT"
git -C "$FREERDP_BUILD_SOURCE_DIR" apply "$FREERDP_PATCH_INPUT"

rm -rf "$LICENSES_STAGE_DIR"
mkdir -p "$LICENSES_STAGE_DIR"
cp "$SRC_DIR/LICENSE" "$LICENSES_STAGE_DIR/FreeRDP-LICENSE"
cp "$WORK_DIR/openssl/LICENSE.txt" "$LICENSES_STAGE_DIR/OpenSSL-LICENSE.txt"
cp "$WORK_DIR/openssl/AUTHORS.md" "$LICENSES_STAGE_DIR/OpenSSL-AUTHORS.md"
cp "$WORK_DIR/jansson/LICENSE" "$LICENSES_STAGE_DIR/Jansson-LICENSE"
cp "$WORK_DIR/uriparser/AUTHORS" "$LICENSES_STAGE_DIR/uriparser-AUTHORS"
cp "$WORK_DIR/uriparser/COPYING.Apache-2.0" "$LICENSES_STAGE_DIR/uriparser-COPYING.Apache-2.0"
cp "$WORK_DIR/uriparser/COPYING.BSD-3-Clause" "$LICENSES_STAGE_DIR/uriparser-COPYING.BSD-3-Clause"
cp "$WORK_DIR/uriparser/COPYING.LGPL-2.1" "$LICENSES_STAGE_DIR/uriparser-COPYING.LGPL-2.1"
find "$LICENSES_STAGE_DIR" -type f -exec chmod 644 {} +
# Force a clean reconfigure so disabled-feature flags below fully take effect
# (cmake caches prior config; stale swscale/urbdrc objects must be dropped).
rm -rf "$BUILD_DIR"

cmake -S "$FREERDP_BUILD_SOURCE_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CLANG_PATH" \
  -DCMAKE_OSX_SYSROOT="$MACOS_SDK_PATH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
  -DCMAKE_C_FLAGS="-O3 -fno-lto -Wall -Wextra -Werror" \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTING=ON \
  -DWITH_CLANG_FORMAT=OFF \
  -DWITH_CHANNELS=OFF \
  -DWITH_CLIENT_CHANNELS=OFF \
  -DWITH_CLIENT_COMMON=OFF \
  -DWITH_CLIENT=OFF \
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
  -DWITH_MACAUDIO=OFF \
  -DWITH_FFMPEG=OFF \
  -DWITH_DSP_FFMPEG=OFF \
  -DWITH_SWSCALE=OFF \
  -DWITH_CAIRO=OFF \
  -DWITH_OPUS=OFF \
  -DWITH_FAAD2=OFF \
  -DWITH_FAAC=OFF \
  -DWITH_FDK_AAC=OFF \
  -DWITH_SOXR=OFF \
  -DWITH_PKCS11=OFF \
  -DWITH_PCSC=OFF \
  -DWITH_SMARTCARD_EMULATE=OFF \
  -DWITH_SMARTCARD_PCSC=OFF \
  -DWITH_URBDRC=OFF \
  -DWITHOUT_FREERDP_3x_DEPRECATED=ON \
  -DWITHOUT_WINPR_3x_DEPRECATED=ON \
  -DWITH_JANSSON_REQUIRED=ON \
  -DWITH_OPENSSL=ON \
  -DCMAKE_PREFIX_PATH="$DEPS_PREFIX" \
  -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT"

SELECTED_BUILD_COMMANDS="$WORK_DIR/freerdp-selected-build-commands-$ARCH.txt"
ninja -C "$BUILD_DIR" -t commands freerdp TestSynch >"$SELECTED_BUILD_COMMANDS"
reject_warning_suppressions "$SELECTED_BUILD_COMMANDS" "FreeRDP and TestSynch"

TARGET_GRAPH="$WORK_DIR/freerdp-target-graph-$ARCH.txt"
ninja -C "$BUILD_DIR" -t targets all >"$TARGET_GRAPH"
python3 - "$BUILD_DIR/CMakeCache.txt" "$SELECTED_BUILD_COMMANDS" "$TARGET_GRAPH" <<'PY'
import pathlib
import sys

cache_path, commands_path, targets_path = map(pathlib.Path, sys.argv[1:])
cache = {}
for line in cache_path.read_text(encoding="utf-8").splitlines():
    if not line or line.startswith(("#", "//")) or "=" not in line or ":" not in line:
        continue
    key_and_type, value = line.split("=", 1)
    key, _value_type = key_and_type.split(":", 1)
    cache[key] = value

required_disabled = (
    "WITH_CHANNELS",
    "WITH_CLIENT_CHANNELS",
    "WITH_CLIENT_COMMON",
    "WITH_CLIENT",
)
for key in required_disabled:
    if cache.get(key) != "OFF":
        raise SystemExit(f"FreeRDP core-only cache invariant failed: {key}={cache.get(key)!r}")

commands = commands_path.read_text(encoding="utf-8")
for forbidden_path in ("/client/common/", "/channels/"):
    if forbidden_path in commands:
        raise SystemExit(f"FreeRDP selected compile graph contains excluded source path: {forbidden_path}")

targets = targets_path.read_text(encoding="utf-8")
for forbidden_target in ("freerdp-client", "/channels/"):
    if forbidden_target in targets:
        raise SystemExit(f"FreeRDP target graph contains excluded target surface: {forbidden_target}")
PY

cmake --build "$BUILD_DIR" --target freerdp TestSynch -j"$BUILD_JOBS"
python3 - "$BUILD_DIR" <<'PY'
import json
import pathlib
import subprocess
import sys

build_dir = pathlib.Path(sys.argv[1])
result = subprocess.run(
    ["ctest", "--show-only=json-v1", "-R", "^TestSynch"],
    cwd=build_dir,
    check=True,
    stdout=subprocess.PIPE,
    text=True,
)
payload = json.loads(result.stdout)
actual = [test["name"] for test in payload.get("tests", [])]
expected = {
    "TestSynchAPC",
    "TestSynchBarrier",
    "TestSynchCritical",
    "TestSynchEvent",
    "TestSynchInit",
    "TestSynchMutex",
    "TestSynchSemaphore",
    "TestSynchThread",
    "TestSynchTimerQueue",
    "TestSynchWaitableTimer",
    "TestSynchWaitableTimerAPC",
}
if len(actual) != len(expected) or set(actual) != expected:
    raise SystemExit(
        f"unexpected WinPR synchronization test set: {sorted(actual)}"
    )
PY
ctest --test-dir "$BUILD_DIR" --output-on-failure --no-tests=error -R '^TestSynch'

# Build the compile-time header set from the same source commit and CMake output
# as the runtime dylibs. Header/runtime skew is an ABI error, so these artifacts
# are staged and published as one family.
rm -rf "$HEADERS_STAGE_DIR"
mkdir -p "$HEADERS_STAGE_DIR/include"
cp -R "$FREERDP_BUILD_SOURCE_DIR/include/freerdp" "$HEADERS_STAGE_DIR/include/freerdp"
cp -R "$FREERDP_BUILD_SOURCE_DIR/winpr/include/winpr" "$HEADERS_STAGE_DIR/include/winpr"

for header in config.h version.h buildflags.h build-config.h settings_keys.h; do
  source_header="$BUILD_DIR/include/freerdp/$header"
  [[ -f "$source_header" ]] || { echo "❌ missing generated FreeRDP header: $header" >&2; exit 1; }
  cp "$source_header" "$HEADERS_STAGE_DIR/include/freerdp/$header"
done
for header in config.h version.h buildflags.h build-config.h; do
  source_header="$BUILD_DIR/winpr/include/winpr/$header"
  [[ -f "$source_header" ]] || { echo "❌ missing generated WinPR header: $header" >&2; exit 1; }
  cp "$source_header" "$HEADERS_STAGE_DIR/include/winpr/$header"
done

python3 - "$HEADERS_STAGE_DIR/include/winpr/wtypes.h" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
needle = "typedef IID* REFIID;"
if source.count(needle) != 1:
    raise SystemExit("expected exactly one WinPR REFIID typedef")
replacement = """// SkyBridge local patch: CoreFoundation already exports REFIID on Apple targets.
// The RDP core paths consumed by FreeRDPBridge do not use WinPR's REFIID alias.
#ifndef __APPLE__
typedef IID* REFIID;
#endif"""
path.write_text(source.replace(needle, replacement), encoding="utf-8", newline="\n")
PY

find "$HEADERS_STAGE_DIR" -type d -exec chmod 755 {} +
find "$HEADERS_STAGE_DIR" -type f -exec chmod 644 {} +
grep -Fq '#define FREERDP_VERSION_FULL "3.30.0"' \
  "$HEADERS_STAGE_DIR/include/freerdp/version.h" \
  || { echo "❌ generated FreeRDP headers are not 3.30.0" >&2; exit 1; }

[[ -f "$HEADERS_OUT_DIR/README.md" ]] \
  || { echo "❌ missing maintained FreeRDP header README" >&2; exit 1; }
cp "$HEADERS_OUT_DIR/README.md" "$HEADERS_STAGE_DIR/README.md"
chmod 644 "$HEADERS_STAGE_DIR/README.md"

# --- Assemble a self-contained, relocated dylib set (bash 3.2 safe) ----------

# Normalize a dep/source dylib path -> the basename we bundle it under.
# FreeRDP/winpr/openssl get unversioned names (the bridge dlopens libfreerdp3.dylib);
# everything else keeps its real basename.
norm_name() {
  case "$(basename "$1")" in
    libfreerdp3.*) echo "libfreerdp3.dylib" ;;
    libwinpr3.*) echo "libwinpr3.dylib" ;;
    libssl.*) echo "libssl.4.dylib" ;;
    libcrypto.*) echo "libcrypto.4.dylib" ;;
    *) basename "$1" ;;
  esac
}

rm -rf "$STAGE_DIR"; mkdir -p "$STAGE_DIR"

# Seed with the two built FreeRDP/WinPR dylibs.
for pat in "libfreerdp3" "libwinpr3"; do
  f="$(find "$BUILD_DIR" -name "${pat}.*.dylib" -type f | head -1)"
  [[ -n "$f" ]] || { echo "❌ built dylib not found: ${pat}.*.dylib"; exit 1; }
  cp -f "$f" "$STAGE_DIR/$(norm_name "$f")"; chmod u+w "$STAGE_DIR/$(norm_name "$f")"
done

# Self-completing: iteratively pull in any remaining non-system dependency
# from the pinned build tree/private prefix until the closure is closed.
for _pass in 1 2 3 4 5 6; do
  added=0
  for dst in "$STAGE_DIR"/*.dylib; do
    while read -r dep; do
      case "$dep" in /usr/lib/*|/System/*|@loader_path/*|@executable_path/*) continue ;; esac
      n="$(norm_name "$dep")"
      [[ -f "$STAGE_DIR/$n" ]] && continue
      src=""
      case "$dep" in
        "$BUILD_DIR"/*|"$DEPS_PREFIX"/*)
          [[ -f "$dep" && ! -L "$dep" ]] && src="$dep"
          ;;
        /*)
          echo "❌ refusing non-system dependency outside the pinned build roots: $dep" >&2
          exit 1
          ;;
        @rpath/*)
          src="$(find "$BUILD_DIR" -name "${dep#@rpath/}" \( -type f -o -type l \) 2>/dev/null | head -1)"
          [[ -z "$src" ]] && src="$(find "$DEPS_PREFIX/lib" -name "${dep#@rpath/}" \( -type f -o -type l \) 2>/dev/null | head -1)"
          ;;
      esac
      [[ -z "$src" ]] && src="$(find "$DEPS_PREFIX/lib" -name "$(basename "$dep")" \( -type f -o -type l \) 2>/dev/null | head -1)"
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
  codesign --force --sign - "$dst" >/dev/null
done

# Strict closure check: every bundled dylib must reference ONLY @loader_path + system libs.
leak=0
for dst in "$STAGE_DIR"/*.dylib; do
  while read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*) ;;
      @loader_path/*)
        relative_dep="${dep#@loader_path/}"
        if [[ "$relative_dep" != "$(basename "$relative_dep")" \
          || ! -f "$STAGE_DIR/$relative_dep" \
          || -L "$STAGE_DIR/$relative_dep" ]]; then
          echo "❌ $(basename "$dst") has an unresolved or unsafe @loader_path dependency: $dep" >&2
          leak=1
        fi
        ;;
      *)
        echo "❌ $(basename "$dst") still references a non-bundled path: $dep" >&2
        leak=1
        ;;
    esac
  done < <(otool -L "$dst" | tail -n +2 | awk '{print $1}')
done
[[ "$leak" -eq 0 ]] || { echo "❌ closure NOT self-contained — add the missing lib to the bundle"; exit 1; }
echo "✅ closure self-contained (only @loader_path + system libs)"

if ! env -u SKYBRIDGE_FILE_TOOL -u SKYBRIDGE_OTOOL_TOOL \
  bash "$ROOT/Scripts/check_macos_deps.sh" --strict "$STAGE_DIR" "$DEPLOYMENT_TARGET"; then
  echo "❌ FreeRDP dylib closure exceeds macOS ${DEPLOYMENT_TARGET} deployment target." >&2
  echo "   Rebuild the pinned private closure with the same deployment target; do not rewrite Mach-O minos metadata as a compatibility substitute." >&2
  exit 1
fi

python3 - \
  "$STAGE_DIR" \
  "$FREERDP_COMMIT" \
  "$FREERDP_VERSION" \
  "$OPENSSL_VERSION" \
  "$JANSSON_VERSION" <<'PY'
import ctypes
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected_revision = sys.argv[2]
expected_freerdp_version = sys.argv[3]
expected_openssl_version = sys.argv[4]
expected_jansson_version = sys.argv[5]
expected_files = {
    "libcrypto.4.dylib",
    "libfreerdp3.dylib",
    "libjansson.4.dylib",
    "libssl.4.dylib",
    "liburiparser.1.dylib",
    "libwinpr3.dylib",
}
actual_files = {path.name for path in root.iterdir() if path.is_file()}
if actual_files != expected_files:
    raise SystemExit(
        f"unexpected FreeRDP closure file set: {sorted(actual_files)}"
    )

load_mode = os.RTLD_NOW | os.RTLD_LOCAL
freerdp = ctypes.CDLL(str(root / "libfreerdp3.dylib"), mode=load_mode)

class DlInfo(ctypes.Structure):
    _fields_ = [
        ("dli_fname", ctypes.c_char_p),
        ("dli_fbase", ctypes.c_void_p),
        ("dli_sname", ctypes.c_char_p),
        ("dli_saddr", ctypes.c_void_p),
    ]

dladdr = ctypes.CDLL(None).dladdr
dladdr.argtypes = [ctypes.c_void_p, ctypes.POINTER(DlInfo)]
dladdr.restype = ctypes.c_int

def require_symbol(image: ctypes.CDLL, name: str) -> None:
    try:
        symbol = getattr(image, name)
    except AttributeError as error:
        raise SystemExit(f"missing required FreeRDP symbol: {name}") from error
    info = DlInfo()
    address = ctypes.cast(symbol, ctypes.c_void_p)
    if dladdr(address, ctypes.byref(info)) == 0 or info.dli_fname is None:
        raise SystemExit(f"cannot resolve image origin for FreeRDP symbol: {name}")
    origin = pathlib.Path(info.dli_fname.decode("utf-8")).resolve()
    try:
        origin.relative_to(root.resolve())
    except ValueError as error:
        raise SystemExit(f"FreeRDP symbol escaped the staged closure: {name} -> {origin}") from error
    if not origin.is_file() or origin.is_symlink():
        raise SystemExit(f"FreeRDP symbol origin is not a regular staged file: {name}")

for required_symbol in (
    "freerdp_get_build_revision",
    "freerdp_get_version_string",
    "freerdp_new",
    "freerdp_free",
    "freerdp_context_new",
    "freerdp_context_free",
    "freerdp_connect",
    "freerdp_disconnect",
    "freerdp_settings_set_uint32",
    "freerdp_settings_set_string",
    "freerdp_settings_get_uint32",
    "freerdp_settings_get_string",
    "freerdp_settings_set_bool",
    "freerdp_input_send_mouse_event",
    "freerdp_input_send_keyboard_event",
    "gdi_init",
    "gdi_free",
    "freerdp_check_event_handles",
):
    require_symbol(freerdp, required_symbol)
freerdp.freerdp_get_version_string.restype = ctypes.c_char_p
freerdp_version = freerdp.freerdp_get_version_string().decode("ascii")
if freerdp_version != expected_freerdp_version:
    raise SystemExit(f"unexpected FreeRDP runtime version: {freerdp_version}")

freerdp.freerdp_get_build_revision.restype = ctypes.c_char_p
freerdp_revision = freerdp.freerdp_get_build_revision().decode("ascii")
if freerdp_revision != expected_revision:
    raise SystemExit(
        f"unexpected FreeRDP runtime source revision: {freerdp_revision}"
    )

crypto = ctypes.CDLL(str(root / "libcrypto.4.dylib"))
crypto.OpenSSL_version.argtypes = [ctypes.c_int]
crypto.OpenSSL_version.restype = ctypes.c_char_p
openssl_version = crypto.OpenSSL_version(0).decode("ascii")
if not openssl_version.startswith(f"OpenSSL {expected_openssl_version} "):
    raise SystemExit(f"unexpected OpenSSL runtime version: {openssl_version}")

jansson = ctypes.CDLL(str(root / "libjansson.4.dylib"))
jansson.jansson_version_str.restype = ctypes.c_char_p
jansson_version = jansson.jansson_version_str().decode("ascii")
if jansson_version != expected_jansson_version:
    raise SystemExit(f"unexpected Jansson runtime version: {jansson_version}")
PY

PUBLISH_STAGE="$ROOT/Sources/Vendor/.FreeRDPRuntime.next.$$"
BACKUP_STAGE="$ROOT/Sources/Vendor/.FreeRDPRuntime.previous.$$"
rm -rf "$PUBLISH_STAGE" "$BACKUP_STAGE"
mkdir -p "$PUBLISH_STAGE" "$BACKUP_STAGE"
cp -R "$STAGE_DIR" "$PUBLISH_STAGE/Dylibs"
cp -R "$HEADERS_STAGE_DIR" "$PUBLISH_STAGE/Headers"
cp -R "$LICENSES_STAGE_DIR" "$PUBLISH_STAGE/Licenses"

[[ "$(shasum -a 256 "$ROOT/Scripts/build_freerdp_dylibs.sh" | awk '{print $1}')" == "$BUILD_RECIPE_SHA256" ]] || {
  echo "❌ FreeRDP build recipe changed during execution; refusing provenance and publication" >&2
  exit 1
}
verify_reviewed_patch "OpenSSL" "$OPENSSL_PATCH_PATH" "$OPENSSL_PATCH_SHA256"
verify_reviewed_patch "FreeRDP" "$FREERDP_PATCH_PATH" "$FREERDP_PATCH_SHA256"
verify_reviewed_patch "Jansson" "$JANSSON_PATCH_PATH" "$JANSSON_PATCH_SHA256"
verify_reviewed_patch "uriparser" "$URIPARSER_PATCH_PATH" "$URIPARSER_PATCH_SHA256"
verify_reviewed_patch "OpenSSL snapshot" "$OPENSSL_PATCH_INPUT" "$OPENSSL_PATCH_SHA256"
verify_reviewed_patch "FreeRDP snapshot" "$FREERDP_PATCH_INPUT" "$FREERDP_PATCH_SHA256"
verify_reviewed_patch "Jansson snapshot" "$JANSSON_PATCH_INPUT" "$JANSSON_PATCH_SHA256"
verify_reviewed_patch "uriparser snapshot" "$URIPARSER_PATCH_INPUT" "$URIPARSER_PATCH_SHA256"

python3 "$ROOT/Scripts/native_vendor_provenance.py" create \
  --family freerdp-runtime \
  --lock "$ROOT/Config/native-dependencies.lock.json" \
  --repository-root "$ROOT" \
  --recipe "$ROOT/Scripts/build_freerdp_dylibs.sh" \
  --output "$PUBLISH_STAGE/provenance.json" \
  --artifact-root "dylibs|$PUBLISH_STAGE/Dylibs|Sources/Vendor/FreeRDPDylibs" \
  --artifact-root "headers|$PUBLISH_STAGE/Headers|Sources/Vendor/FreeRDPHeaders" \
  --artifact-root "licenses|$PUBLISH_STAGE/Licenses|Sources/Vendor/NativeLicenses/FreeRDP-runtime" \
  --source "freerdp|$FREERDP_VERSION|$FREERDP_REF|$FREERDP_COMMIT|$FREERDP_REPOSITORY|$SRC_DIR" \
  --source "openssl|$OPENSSL_VERSION|$OPENSSL_REF|$OPENSSL_COMMIT|$OPENSSL_REPOSITORY|$WORK_DIR/openssl" \
  --source "jansson|$JANSSON_VERSION|$JANSSON_REF|$JANSSON_COMMIT|$JANSSON_REPOSITORY|$WORK_DIR/jansson" \
  --source "uriparser|$URIPARSER_VERSION|$URIPARSER_REF|$URIPARSER_COMMIT|$URIPARSER_REPOSITORY|$WORK_DIR/uriparser" \
  --source "googletest|$GOOGLETEST_VERSION|$GOOGLETEST_REF|$GOOGLETEST_COMMIT|$GOOGLETEST_REPOSITORY|$WORK_DIR/googletest" \
  --build-input "architecture=$ARCH" \
  --build-input "audio=disabled" \
  --build-input "audio_redirection=disabled" \
  --build-input "build_jobs=$BUILD_JOBS" \
  --build-input "deployment_target=$DEPLOYMENT_TARGET" \
  --build-input "build_type=Release" \
  --build-input "cairo=disabled" \
  --build-input "channel_plugins=not-built" \
  --build-input "channel_registration=none" \
  --build-input "clang_format=disabled" \
  --build-input "client_common=disabled" \
  --build-input "dependency_resolution=private-only" \
  --build-input "dsp_ffmpeg=disabled" \
  --build-input "device_redirection=disabled" \
  --build-input "fdk_aac=disabled" \
  --build-input "feature_scope=freerdp-core-winpr-software-gdi-bgra-classic-bitmap-nscodec-basic-input-no-client-common-no-channel-plugins" \
  --build-input "freerdp_test_scope=winpr-synch-all" \
  --build-input "linkage=dynamic" \
  --build-input "freerdp_local_patch_sha256=$FREERDP_PATCH_SHA256" \
  --build-input "freerdp_3x_deprecated=disabled" \
  --build-input "jansson_local_patch_sha256=$JANSSON_PATCH_SHA256" \
  --build-input "openssl_abi=4" \
  --build-input "openssl_local_patch_sha256=$OPENSSL_PATCH_SHA256" \
  --build-input "openssl_sonames=libssl.4.dylib;libcrypto.4.dylib" \
  --build-input "openssl_test_harness_jobs=1" \
  --build-input "pcsc=disabled" \
  --build-input "pkcs11=disabled" \
  --build-input "runtime_gfx_h264=disabled" \
  --build-input "runtime_graphics_pipeline=disabled" \
  --build-input "runtime_remotefx=disabled" \
  --build-input "smartcard=disabled" \
  --build-input "uriparser_local_patch_sha256=$URIPARSER_PATCH_SHA256" \
  --build-input "private_dependency_closure=true" \
  --build-input "source_revision=embedded-and-verified" \
  --build-input "warning_suppressions=forbidden" \
  --build-input "winpr_3x_deprecated=disabled"

mkdir -p "$(dirname "$LICENSES_OUT_DIR")"
skybridge_publish_freerdp_runtime \
  "$PUBLISH_STAGE" \
  "$BACKUP_STAGE" \
  "$OUT_DIR" \
  "$HEADERS_OUT_DIR" \
  "$LICENSES_OUT_DIR" \
  "$PROVENANCE_OUT" \
  /bin/mv \
  _skybridge_freerdp_process_start_token \
  python3 "$ROOT/Scripts/native_vendor_provenance.py" verify \
    --repository-root "$ROOT" \
    --lock "$ROOT/Config/native-dependencies.lock.json" \
    --provenance "$PROVENANCE_OUT"

echo "✅ assembled relocated FreeRDP dylibs -> ${OUT_DIR#"$ROOT"/}"
ls -1 "$OUT_DIR"
