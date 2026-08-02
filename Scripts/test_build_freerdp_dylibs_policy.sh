#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_SCRIPT="${ROOT_DIR}/Scripts/build_freerdp_dylibs.sh"
TARGET_LOCK="${ROOT_DIR}/Config/native-dependencies.lock.json"

fail() {
  echo "[test-freerdp-dylibs-policy] $1" >&2
  exit 1
}

require_contains() {
  local needle="$1"
  grep -Fq -- "$needle" "$TARGET_SCRIPT" \
    || fail "missing required source contract: ${needle}"
}

require_lock_contains() {
  local needle="$1"
  grep -Fq -- "$needle" "$TARGET_LOCK" \
    || fail "missing required native lock contract: ${needle}"
}

require_absent() {
  local needle="$1"
  if grep -Fq -- "$needle" "$TARGET_SCRIPT"; then
    fail "forbidden direct vendor mutation remains: ${needle}"
  fi
}

require_count() {
  local needle="$1" expected_count="$2"
  local actual_count
  actual_count="$(grep -Fc -- "$needle" "$TARGET_SCRIPT" || true)"
  [[ "$actual_count" == "$expected_count" ]] \
    || fail "expected ${expected_count} occurrences of source contract '${needle}', found ${actual_count}"
}

line_number() {
  local needle="$1"
  grep -nF -- "$needle" "$TARGET_SCRIPT" | head -1 | cut -d: -f1
}

require_contains 'STAGE_DIR="$WORK_DIR/stage-$ARCH"'
require_contains 'rm -rf "$STAGE_DIR"; mkdir -p "$STAGE_DIR"'
require_contains 'module.load_locked_family(lock_path, root, "freerdp-runtime")'
require_contains 'expected_source_names = ["freerdp", "openssl", "jansson", "uriparser", "googletest"]'
require_contains 'FreeRDP runtime lock build inputs differ from the exact recipe contract'
require_contains 'selected native toolchain differs from Config/native-dependencies.lock.json'
require_contains '"build_jobs": "8"'
require_contains 'FreeRDP runtime build_jobs must be a canonical integer from 1 through 32'
require_contains 'LOCKED_ARCH LOCKED_DEPLOYMENT_TARGET LOCKED_BUILD_JOBS'
require_contains 'BUILD_JOBS="$LOCKED_BUILD_JOBS"'
require_contains 'build_jobs=${BUILD_JOBS}'
require_lock_contains '"build_jobs": "8"'
require_contains 'reject_divergent_override SKYBRIDGE_FREERDP_REF'
require_contains 'reject_divergent_override SKYBRIDGE_FREERDP_COMMIT'
require_contains 'reject_divergent_override SKYBRIDGE_FREERDP_OPENSSL_REF'
require_contains 'reject_divergent_override SKYBRIDGE_FREERDP_OPENSSL_COMMIT'
require_contains 'reject_divergent_override SKYBRIDGE_FREERDP_JANSSON_REF'
require_contains 'reject_divergent_override SKYBRIDGE_FREERDP_JANSSON_COMMIT'
require_contains 'reject_divergent_override SKYBRIDGE_FREERDP_URIPARSER_REF'
require_contains 'reject_divergent_override SKYBRIDGE_FREERDP_URIPARSER_COMMIT'
require_contains 'reject_divergent_override SKYBRIDGE_FREERDP_GOOGLETEST_REF'
require_contains 'reject_divergent_override SKYBRIDGE_FREERDP_GOOGLETEST_COMMIT'
require_contains 'reject_divergent_override ARCH'
require_contains 'reject_divergent_override DEPLOYMENT_TARGET'
require_contains 'reject_divergent_override SKYBRIDGE_FREERDP_BUILD_PRIVATE_DEPS'
require_contains 'canonicalize_build_path()'
require_contains 'path.resolve(strict=False)'
require_contains 'native build paths must be absolute'
require_contains 'TEMP_ROOT="${TMPDIR:-/tmp}"'
require_contains '${TEMP_ROOT%/}/skybridge-freerdp-dylibs'
require_contains 'skybridge-freerdp-dylibs-$$'
require_contains 'FREERDP_PATCH_PATH="$ROOT/Scripts/Patches/freerdp-3.30.0-appleclang-cmake4.patch"'
require_contains 'JANSSON_PATCH_PATH="$ROOT/Scripts/Patches/jansson-2.15.1-cmake-package-version.patch"'
require_contains 'OPENSSL_PATCH_PATH="$ROOT/Scripts/Patches/openssl-4.0.1-mkinstallvars-defaults.patch"'
require_contains 'URIPARSER_PATCH_PATH="$ROOT/Scripts/Patches/uriparser-1.0.2-appleclang-gtest.patch"'
require_contains 'FREERDP_PATCH_SHA256="48f7bf519a230a01ab25f178ff00968e78066511b76fb9db6f1a35a8691262f3"'
require_contains 'JANSSON_PATCH_SHA256="eb7c26d605d020c60c9f25b62b43b0e229e12f0953b0fd0ba9b995026415b2a8"'
require_contains 'OPENSSL_PATCH_SHA256="4e3c460e9b7f0619c80ae02bba2800ef172e4fdba07bf0b97144311774b7fb7b"'
require_contains 'URIPARSER_PATCH_SHA256="65f13fb1c134ae4b06f1022d080f04124f592bf47317c389b345d948b612dca9"'
require_contains 'verify_reviewed_patch "FreeRDP"'
require_contains 'verify_reviewed_patch "Jansson"'
require_contains 'verify_reviewed_patch "uriparser"'
require_contains 'patch --batch --forward -F 0'
require_contains 'git -C "$FREERDP_BUILD_SOURCE_DIR" apply --check "$FREERDP_PATCH_INPUT"'
require_contains 'git -C "$jansson_build_source" apply --check "$JANSSON_PATCH_INPUT"'
require_contains 'git -C "$uriparser_build_source" apply --check "$URIPARSER_PATCH_INPUT"'
require_contains 'patch --batch --forward -F 0 -d "$openssl_build_source" -p1 <"$OPENSSL_PATCH_INPUT"'
require_contains 'PATCH_SNAPSHOT_DIR="$WORK_DIR/reviewed-patches"'
require_contains 'chmod 0444 "$PATCH_SNAPSHOT_DIR"/*'
require_contains '[[ -f "$path" && ! -L "$path" ]]'
require_contains 'FreeRDP build recipe changed during execution; refusing provenance and publication'
require_count 'verify_reviewed_patch "OpenSSL"' 2
require_count 'verify_reviewed_patch "FreeRDP"' 2
require_count 'verify_reviewed_patch "Jansson"' 2
require_count 'verify_reviewed_patch "uriparser"' 2
require_count 'verify_reviewed_patch "OpenSSL snapshot"' 2
require_count 'verify_reviewed_patch "FreeRDP snapshot"' 2
require_count 'verify_reviewed_patch "Jansson snapshot"' 2
require_count 'verify_reviewed_patch "uriparser snapshot"' 2
require_contains 'source "$ROOT/Scripts/native_source_helpers.sh"'
require_contains 'source "$ROOT/Scripts/freerdp_runtime_publish_transaction.sh"'
require_contains 'skybridge_prepare_pinned_native_source'
require_contains 'recipe_sha256=${BUILD_RECIPE_SHA256}'
require_contains '[[ "$MACOS_SDK_PATH" == "$XCODE_DEVELOPER_DIR"/* ]]'
require_contains 'export SDKROOT="$MACOS_SDK_PATH"'
require_contains '-DCMAKE_C_COMPILER="$CLANG_PATH"'
require_contains '-DCMAKE_CXX_COMPILER="$CLANGXX_PATH"'
require_contains '-DCMAKE_OSX_SYSROOT="$MACOS_SDK_PATH"'
require_contains 'macos_sdk=${MACOS_SDK_VERSION}'
require_contains 'env -u SKYBRIDGE_FILE_TOOL -u SKYBRIDGE_OTOOL_TOOL'
require_contains 'bash "$ROOT/Scripts/check_macos_deps.sh" --strict "$STAGE_DIR" "$DEPLOYMENT_TARGET"'
require_contains 'freerdp_version != expected_freerdp_version'
require_contains 'openssl_version.startswith(f"OpenSSL {expected_openssl_version} ")'
require_contains 'make test HARNESS_JOBS=1'
require_contains 'jansson_version != expected_jansson_version'
require_contains '-Dgtest_build_tests=ON'
require_contains '-DURIPARSER_BUILD_TESTS=ON'
require_contains '-DURIPARSER_WARNINGS_AS_ERRORS=ON'
require_contains 'ctest --test-dir "$uriparser_build" --output-on-failure'
require_contains 'export PKG_CONFIG_LIBDIR="$DEPS_PREFIX/lib/pkgconfig"'
require_contains 'export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig"'
require_contains 'export CMAKE_PREFIX_PATH="$DEPS_PREFIX"'
require_count '-DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"' 4
require_contains '-DGTest_DIR="$DEPS_PREFIX/lib/cmake/GTest"'
require_contains 'printf '\''%s\n'\'' "$FREERDP_COMMIT" >"$FREERDP_BUILD_SOURCE_DIR/.source_version"'
require_contains '-DWITH_CAIRO=OFF'
require_contains '-DWITH_DSP_FFMPEG=OFF'
require_contains '-DWITH_FDK_AAC=OFF'
require_contains '-DWITH_MACAUDIO=OFF'
require_contains '-DWITH_CHANNELS=OFF'
require_contains '-DWITH_CLIENT_CHANNELS=OFF'
require_contains '-DWITH_CLIENT_COMMON=OFF'
require_contains '-DWITH_CLIENT=OFF'
require_contains '-DWITH_PKCS11=OFF'
require_contains '-DWITH_PCSC=OFF'
require_contains '-DWITH_SMARTCARD_EMULATE=OFF'
require_contains '-DWITH_SMARTCARD_PCSC=OFF'
require_contains 'forbidden_warning_suppression="-Wno-"'
require_contains 'grep -Fq -- "$forbidden_warning_suppression" "$build_file"'
require_contains 'generated compile commands disable all warnings'
require_count 'reject_warning_suppressions "' 5
require_contains '-DBUILD_TESTING=ON'
require_contains '-DWITH_CLANG_FORMAT=OFF'
require_contains 'ninja -C "$BUILD_DIR" -t commands freerdp TestSynch >"$SELECTED_BUILD_COMMANDS"'
require_contains 'ninja -C "$BUILD_DIR" -t targets all >"$TARGET_GRAPH"'
require_contains '"WITH_CLIENT_COMMON",'
require_contains '"WITH_CLIENT",'
require_contains 'forbidden_path in ("/client/common/", "/channels/")'
require_contains 'forbidden_target in ("freerdp-client", "/channels/")'
require_contains 'cmake --build "$BUILD_DIR" --target freerdp TestSynch'
require_contains '["ctest", "--show-only=json-v1", "-R", "^TestSynch"]'
require_contains 'if len(actual) != len(expected) or set(actual) != expected:'
require_contains '"TestSynchWaitableTimerAPC",'
require_contains 'ctest --test-dir "$BUILD_DIR" --output-on-failure --no-tests=error -R '\''^TestSynch'\'''
require_contains '--build-input "freerdp_test_scope=winpr-synch-all"'
require_contains '--build-input "freerdp_3x_deprecated=disabled"'
require_contains '"freerdp_get_build_revision"'
require_contains '"freerdp_context_free"'
require_contains 'freerdp_revision != expected_revision'
require_contains '--build-input "cairo=disabled"'
require_contains '--build-input "audio=disabled"'
require_contains '--build-input "clang_format=disabled"'
require_contains '--build-input "dsp_ffmpeg=disabled"'
require_contains '--build-input "fdk_aac=disabled"'
require_contains '--build-input "source_revision=embedded-and-verified"'
require_contains '--build-input "warning_suppressions=forbidden"'
require_contains '--build-input "openssl_test_harness_jobs=1"'
require_contains '--build-input "openssl_abi=4"'
require_contains '--build-input "openssl_sonames=libssl.4.dylib;libcrypto.4.dylib"'
require_contains '--build-input "build_jobs=$BUILD_JOBS"'
require_count '-j"$BUILD_JOBS"' 5
require_contains 'libssl.4.dylib'
require_contains 'libcrypto.4.dylib'
require_contains '--build-input "pcsc=disabled"'
require_contains '--build-input "pkcs11=disabled"'
require_contains '--build-input "smartcard=disabled"'
require_contains '--build-input "feature_scope=freerdp-core-winpr-software-gdi-bgra-classic-bitmap-nscodec-basic-input-no-client-common-no-channel-plugins"'
require_contains '--build-input "client_common=disabled"'
require_contains '--build-input "channel_plugins=not-built"'
require_contains '--build-input "channel_registration=none"'
require_contains '--build-input "runtime_graphics_pipeline=disabled"'
require_contains '--build-input "runtime_remotefx=disabled"'
require_contains '--build-input "runtime_gfx_h264=disabled"'
require_contains '--build-input "audio_redirection=disabled"'
require_contains '--build-input "device_redirection=disabled"'
require_contains '-DWITHOUT_WINPR_3x_DEPRECATED=ON'
require_contains '-DWITHOUT_FREERDP_3x_DEPRECATED=ON'
require_contains '-DWITH_JANSSON_REQUIRED=ON'
require_contains 'native_vendor_provenance.py" create'
require_contains 'native_vendor_provenance.py" verify'
require_contains 'skybridge_publish_freerdp_runtime \'
require_contains 'do not rewrite Mach-O minos metadata as a compatibility substitute'
require_contains '\( -type f -o -type l \)'

require_absent 'cp -f "$f" "$OUT_DIR/'
require_absent 'cp -f "$src" "$OUT_DIR/'
require_absent 'for dst in "$OUT_DIR"/*.dylib'
require_absent 'find /opt/homebrew/opt/'
require_absent 'codesign --force --sign - "$dst" >/dev/null 2>&1 || true'
require_absent 'FREERDP_BRANCH="${FREERDP_BRANCH:-3.26.0}"'
require_absent 'sysctl -n hw.ncpu'
require_count '-Wno-' 1
require_absent '$ROOT/Patches/'

exports_line="$(line_number 'export PKG_CONFIG_LIBDIR="$DEPS_PREFIX/lib/pkgconfig"')"
private_deps_line="$(grep -n '^build_private_openssl$' "$TARGET_SCRIPT" | head -1 | cut -d: -f1)"
[[ -n "$exports_line" && -n "$private_deps_line" && "$exports_line" -lt "$private_deps_line" ]] \
  || fail "private dependency resolution environment must be fixed before any private dependency build"

gate_line="$(line_number 'bash "$ROOT/Scripts/check_macos_deps.sh" --strict "$STAGE_DIR" "$DEPLOYMENT_TARGET"')"
provenance_line="$(line_number 'native_vendor_provenance.py" create')"
publish_move_line="$(line_number 'skybridge_publish_freerdp_runtime \')"
recipe_recheck_line="$(line_number 'FreeRDP build recipe changed during execution; refusing provenance and publication')"
patch_recheck_line="$(grep -nF 'verify_reviewed_patch "uriparser snapshot"' "$TARGET_SCRIPT" | tail -1 | cut -d: -f1)"

[[ -n "$gate_line" && -n "$provenance_line" && -n "$publish_move_line" ]] \
  || fail "could not resolve source contract line numbers"

[[ -n "$recipe_recheck_line" && -n "$patch_recheck_line" \
  && "$recipe_recheck_line" -lt "$provenance_line" \
  && "$patch_recheck_line" -lt "$provenance_line" ]] \
  || fail "recipe and snapshotted patch inputs must be reverified before provenance creation"

if (( gate_line >= provenance_line || provenance_line >= publish_move_line )); then
  fail "deployment-target and provenance gates must run before replacing vendored runtime bytes"
fi

override_log="$(mktemp "${TMPDIR:-/tmp}/skybridge-freerdp-override.XXXXXX")"
private_deps_log="$(mktemp "${TMPDIR:-/tmp}/skybridge-freerdp-private-deps.XXXXXX")"
relative_path_log="$(mktemp "${TMPDIR:-/tmp}/skybridge-freerdp-relative-path.XXXXXX")"
cleanup_logs() {
  rm -f "$override_log" "$private_deps_log" "$relative_path_log"
}
trap cleanup_logs EXIT

if SKYBRIDGE_FREERDP_REF=unreviewed-ref bash "$TARGET_SCRIPT" >"$override_log" 2>&1; then
  fail "FreeRDP build must reject a ref override that differs from the native lock"
fi
grep -Fq 'SKYBRIDGE_FREERDP_REF differs from Config/native-dependencies.lock.json' "$override_log" \
  || fail "FreeRDP divergent-ref rejection must identify the lock mismatch"

if SKYBRIDGE_FREERDP_BUILD_PRIVATE_DEPS=0 bash "$TARGET_SCRIPT" >"$private_deps_log" 2>&1; then
  fail "FreeRDP build must reject a non-private dependency closure"
fi
grep -Fq 'SKYBRIDGE_FREERDP_BUILD_PRIVATE_DEPS differs from Config/native-dependencies.lock.json' "$private_deps_log" \
  || fail "FreeRDP private-dependency rejection must identify the lock mismatch"

if SKYBRIDGE_FREERDP_WORK_DIR=relative-build-root bash "$TARGET_SCRIPT" >"$relative_path_log" 2>&1; then
  fail "FreeRDP build must reject relative native build roots"
fi
grep -Fq 'native build paths must be absolute' "$relative_path_log" \
  || fail "FreeRDP relative-path rejection must identify the path contract"

echo "[test-freerdp-dylibs-policy] passed"
