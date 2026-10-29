#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/Scripts/build_liboqs_xcframework.sh"
LOCK_FILE="$ROOT_DIR/Config/native-dependencies.lock.json"

fail() {
  echo "[test-build-liboqs-xcframework-policy] $*" >&2
  exit 1
}

require_literal() {
  local literal="$1"
  grep -Fq -- "$literal" "$BUILD_SCRIPT" \
    || fail "build recipe is missing required contract: $literal"
}

bash -n "$BUILD_SCRIPT"
if grep -Fq 'OQS_PERMIT_UNSUPPORTED_ARCHITECTURE' "$BUILD_SCRIPT"; then
  fail "liboqs build must not override unsupported architecture detection"
fi

require_literal 'build_one macos-arm64'
require_literal 'build_one ios-arm64'
require_literal 'build_one ios-simulator-arm64'
require_literal 'build_one ios-simulator-x86_64'
require_literal '"$LIPO_PATH" -create'
require_literal 'merge_liboqs_simulator_headers.py'
require_literal 'git apply --check "$DOWNSTREAM_PATCH_PATH"'
require_literal 'CMAKE_COMPILE_WARNING_AS_ERROR=ON'
require_literal 'compiler or build-system warning detected for $name'
require_literal 'CLANG_PATH="$(canonical_path "$(xcrun --find clang)")"'
require_literal 'CLANGXX_PATH="$(canonical_path "$(xcrun --find clang++)")"'
require_literal 'MACOS_SDK_PATH="$(canonical_path "$(xcrun --sdk macosx --show-sdk-path)")"'
require_literal 'IPHONEOS_SDK_PATH="$(canonical_path "$(xcrun --sdk iphoneos --show-sdk-path)")"'
require_literal 'IPHONESIMULATOR_SDK_PATH="$(canonical_path "$(xcrun --sdk iphonesimulator --show-sdk-path)")"'
require_literal '[[ "$xcode_path" == "$XCODE_DEVELOPER_DIR"/* ]]'
require_literal 'export SDKROOT="$sdk_path"'
require_literal '-DCMAKE_OSX_SYSROOT="$sdk_path"'
require_literal '-DCMAKE_C_COMPILER="$CLANG_PATH"'
require_literal 'KEM_ml_kem_768;KEM_ml_kem_1024;SIG_ml_dsa_65;SIG_ml_dsa_87'
require_literal 'run_kat kem "$KAT_KEM_BINARY" ML-KEM-768'
require_literal 'run_kat kem "$KAT_KEM_BINARY" ML-KEM-1024'
require_literal 'run_kat sig "$KAT_SIG_BINARY" ML-DSA-65'
require_literal 'run_kat sig "$KAT_SIG_BINARY" ML-DSA-87'
require_literal 'liboqs_version_probe.c'
require_literal 'cp "$PATCHED_SOURCE_DIR/LICENSE.txt" "$STAGE_OUT/LICENSE.txt"'
require_literal '--lock "$NATIVE_DEPENDENCY_LOCK"'
require_literal '--build-input "downstream_patch=$LIBOQS_DOWNSTREAM_PATCH"'
[[ "$(grep -Fc -- '--lock "$NATIVE_DEPENDENCY_LOCK"' "$BUILD_SCRIPT")" == "2" ]] \
  || fail "both provenance create and verify must bind the canonical lock"

python3 - "$LOCK_FILE" <<'PY'
import json
import pathlib
import sys

lock = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
family = lock["families"]["liboqs"]
source = family["sources"]
if len(source) != 1 or source[0] != {
    "name": "liboqs",
    "version": "0.16.0",
    "ref": "0.16.0",
    "commit": "5a1a854b0dc9f2141bdc771c555ee60c37950183",
    "repository": "https://github.com/open-quantum-safe/liboqs.git",
    "git_tree": "8e0a3a68b247f821ed535a141aa896a7fda59d2d",
    "source_archive_sha256": "2a469ff48e73c9cd78c2f7752465ca7a066582fbaa9185f52b4725783218d39d",
}:
    raise SystemExit("liboqs source lock differs from the reviewed 0.16.0 commit")
expected_inputs = {
    "architectures": "macos-arm64;ios-arm64;ios-simulator-arm64;ios-simulator-x86_64",
    "build_type": "Release",
    "distribution_build": "true",
    "downstream_patch": "Scripts/Patches/liboqs-0.16.0-xkcp-appleclang.patch@6de373115afcf5cb01a2075ec49cb5609db2970cb582fbfb17e2b4c8653cf177",
    "enabled_algorithms": "KEM_ml_kem_768;KEM_ml_kem_1024;SIG_ml_dsa_65;SIG_ml_dsa_87",
    "ios_deployment_target": "17.0",
    "linkage": "static",
    "macos_deployment_target": "14.0",
    "openssl": "false",
}
if family["build_inputs"] != expected_inputs:
    raise SystemExit("liboqs build input lock differs from the exact recipe contract")
if set(family["toolchain"]) != {"xcode", "macos_sdk", "clang", "cmake", "ninja"}:
    raise SystemExit("liboqs toolchain lock differs from the exact recipe contract")
PY

override_log="$(mktemp -t skybridge-liboqs-override.XXXXXX)"
trap 'rm -f "$override_log"' EXIT
if SKYBRIDGE_LIBOQS_REF=unexpected-ref \
  LIBOQS_BUILD_ROOT="${TMPDIR:-/tmp}/skybridge-liboqs-policy-should-not-build" \
  bash "$BUILD_SCRIPT" >"$override_log" 2>&1; then
  fail "build recipe accepted a source ref that differs from the lock"
fi
grep -Fq 'SKYBRIDGE_LIBOQS_REF differs from Config/native-dependencies.lock.json' "$override_log" \
  || fail "divergent source override did not fail at the lock boundary"

echo "[test-build-liboqs-xcframework-policy] passed"
