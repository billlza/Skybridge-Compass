#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_DEPENDENCY_LOCK="$ROOT_DIR/Config/native-dependencies.lock.json"
REQUESTED_LIBOQS_REF_SET="${SKYBRIDGE_LIBOQS_REF+x}"
REQUESTED_LIBOQS_REF="${SKYBRIDGE_LIBOQS_REF-}"
REQUESTED_LIBOQS_COMMIT_SET="${SKYBRIDGE_LIBOQS_COMMIT+x}"
REQUESTED_LIBOQS_COMMIT="${SKYBRIDGE_LIBOQS_COMMIT-}"
REQUESTED_IOS_MIN_VERSION_SET="${IOS_MIN_VERSION+x}"
REQUESTED_IOS_MIN_VERSION="${IOS_MIN_VERSION-}"
REQUESTED_MACOS_MIN_VERSION_SET="${MACOS_MIN_VERSION+x}"
REQUESTED_MACOS_MIN_VERSION="${MACOS_MIN_VERSION-}"
FINAL_OUT="$ROOT_DIR/Sources/Vendor/liboqs.xcframework"
PROVENANCE_OUT="$ROOT_DIR/Sources/Vendor/liboqs.provenance.json"

log() { echo "[build_liboqs_xcframework] $*"; }
fail() { echo "[build_liboqs_xcframework] $*" >&2; exit 1; }

detect_jobs() {
  local jobs=""
  jobs="$(sysctl -n hw.logicalcpu 2>/dev/null || true)"
  if [[ "$jobs" =~ ^[0-9]+$ ]] && (( jobs > 0 )); then
    echo "$jobs"
    return
  fi
  echo "8"
}

for command_name in cmake git lipo ninja python3 shasum tar tee xcode-select xcodebuild xcrun; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "missing required command: $command_name"
done

canonical_path() {
  python3 - "$1" <<'PY'
import pathlib
import sys

try:
    print(pathlib.Path(sys.argv[1]).resolve(strict=True))
except OSError as error:
    raise SystemExit(f"could not resolve selected Xcode path: {error}") from error
PY
}

XCODE_DEVELOPER_DIR="$(canonical_path "$(xcode-select -p)")"
[[ -x "$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" ]] \
  || fail "xcode-select must point at a full Xcode installation"
CLANG_PATH="$(canonical_path "$(xcrun --find clang)")"
CLANGXX_PATH="$(canonical_path "$(xcrun --find clang++)")"
XCODEBUILD_PATH="$(canonical_path "$(xcrun --find xcodebuild)")"
LIPO_PATH="$(canonical_path "$(xcrun --find lipo)")"
NM_PATH="$(canonical_path "$(xcrun --find nm)")"
MACOS_SDK_PATH="$(canonical_path "$(xcrun --sdk macosx --show-sdk-path)")"
IPHONEOS_SDK_PATH="$(canonical_path "$(xcrun --sdk iphoneos --show-sdk-path)")"
IPHONESIMULATOR_SDK_PATH="$(canonical_path "$(xcrun --sdk iphonesimulator --show-sdk-path)")"
for xcode_path in \
  "$CLANG_PATH" \
  "$CLANGXX_PATH" \
  "$XCODEBUILD_PATH" \
  "$LIPO_PATH" \
  "$NM_PATH" \
  "$MACOS_SDK_PATH" \
  "$IPHONEOS_SDK_PATH" \
  "$IPHONESIMULATOR_SDK_PATH"
do
  [[ "$xcode_path" == "$XCODE_DEVELOPER_DIR"/* ]] \
    || fail "tool or SDK is outside the selected Xcode: $xcode_path"
done
for executable_path in "$CLANG_PATH" "$CLANGXX_PATH" "$XCODEBUILD_PATH" "$LIPO_PATH" "$NM_PATH"; do
  [[ -x "$executable_path" ]] || fail "selected Xcode tool is not executable: $executable_path"
done
for sdk_path in "$MACOS_SDK_PATH" "$IPHONEOS_SDK_PATH" "$IPHONESIMULATOR_SDK_PATH"; do
  [[ -d "$sdk_path" ]] \
    || fail "selected Xcode SDK is not a real directory: $sdk_path"
done

LOCKED_CONFIGURATION="$(python3 - "$ROOT_DIR" "$NATIVE_DEPENDENCY_LOCK" <<'PY'
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
family, _ = module.load_locked_family(lock_path, root, "liboqs")
if module.toolchain_record() != family["toolchain"]:
    raise SystemExit("selected native toolchain differs from Config/native-dependencies.lock.json")
if len(family["sources"]) != 1 or family["sources"][0]["name"] != "liboqs":
    raise SystemExit("liboqs lock must contain exactly one liboqs source")
required_inputs = {
    "architectures",
    "build_type",
    "distribution_build",
    "downstream_patch",
    "enabled_algorithms",
    "ios_deployment_target",
    "linkage",
    "macos_deployment_target",
    "openssl",
}
if set(family["build_inputs"]) != required_inputs:
    raise SystemExit("liboqs lock build inputs differ from the exact recipe contract")
source = family["sources"][0]
inputs = family["build_inputs"]
values = [
    source["version"],
    source["ref"],
    source["commit"],
    source["repository"],
    inputs["architectures"],
    inputs["build_type"],
    inputs["distribution_build"],
    inputs["downstream_patch"],
    inputs["enabled_algorithms"],
    inputs["ios_deployment_target"],
    inputs["linkage"],
    inputs["macos_deployment_target"],
    inputs["openssl"],
]
if any("\t" in value or "\n" in value or "\r" in value for value in values):
    raise SystemExit("liboqs lock contains a control character")
print("\t".join(values))
PY
)"
IFS=$'\t' read -r \
  LIBOQS_VERSION LIBOQS_REF LIBOQS_COMMIT LIBOQS_REPOSITORY \
  LIBOQS_ARCHITECTURES LIBOQS_BUILD_TYPE LIBOQS_DISTRIBUTION_BUILD \
  LIBOQS_DOWNSTREAM_PATCH LIBOQS_ENABLED_ALGORITHMS IOS_MIN_VERSION LIBOQS_LINKAGE \
  MACOS_MIN_VERSION LIBOQS_OPENSSL <<<"$LOCKED_CONFIGURATION"

[[ "$LIBOQS_BUILD_TYPE" == "Release" ]] || fail "liboqs lock requires unsupported build type: $LIBOQS_BUILD_TYPE"
[[ "$LIBOQS_DISTRIBUTION_BUILD" == "true" ]] || fail "liboqs distribution build must remain enabled"
[[ "$LIBOQS_LINKAGE" == "static" ]] || fail "liboqs recipe only supports static linkage"
[[ "$LIBOQS_OPENSSL" == "false" ]] || fail "liboqs recipe must not introduce an OpenSSL dependency"
[[ "$LIBOQS_ARCHITECTURES" == "macos-arm64;ios-arm64;ios-simulator-arm64;ios-simulator-x86_64" ]] \
  || fail "liboqs architecture lock differs from the four-target recipe"
[[ "$LIBOQS_ENABLED_ALGORITHMS" == "KEM_ml_kem_768;KEM_ml_kem_1024;SIG_ml_dsa_65;SIG_ml_dsa_87" ]] \
  || fail "liboqs algorithm lock differs from the required ML-KEM/ML-DSA surface"

DOWNSTREAM_PATCH_PATH="$(python3 - "$ROOT_DIR" "$LIBOQS_DOWNSTREAM_PATCH" <<'PY'
import hashlib
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
specification = sys.argv[2]
relative_raw, separator, expected_sha256 = specification.rpartition("@")
relative = pathlib.PurePosixPath(relative_raw)
if not separator or relative.is_absolute() or ".." in relative.parts:
    raise SystemExit("liboqs downstream patch path is unsafe")
if not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
    raise SystemExit("liboqs downstream patch SHA-256 is invalid")
path = (root / pathlib.Path(*relative.parts)).resolve()
try:
    path.relative_to(root)
except ValueError as error:
    raise SystemExit("liboqs downstream patch escapes the repository") from error
if not path.is_file() or path.is_symlink():
    raise SystemExit("liboqs downstream patch is not a regular repository file")
actual_sha256 = hashlib.sha256(path.read_bytes()).hexdigest()
if actual_sha256 != expected_sha256:
    raise SystemExit(
        f"liboqs downstream patch SHA-256 mismatch: expected {expected_sha256}, got {actual_sha256}"
    )
print(path)
PY
)"

reject_divergent_override() {
  local variable_name="$1" was_set="$2" requested="$3" locked="$4"
  if [[ "$was_set" == "x" && "$requested" != "$locked" ]]; then
    fail "$variable_name differs from Config/native-dependencies.lock.json"
  fi
}

reject_divergent_override SKYBRIDGE_LIBOQS_REF "$REQUESTED_LIBOQS_REF_SET" "$REQUESTED_LIBOQS_REF" "$LIBOQS_REF"
reject_divergent_override SKYBRIDGE_LIBOQS_COMMIT "$REQUESTED_LIBOQS_COMMIT_SET" "$REQUESTED_LIBOQS_COMMIT" "$LIBOQS_COMMIT"
reject_divergent_override IOS_MIN_VERSION "$REQUESTED_IOS_MIN_VERSION_SET" "$REQUESTED_IOS_MIN_VERSION" "$IOS_MIN_VERSION"
reject_divergent_override MACOS_MIN_VERSION "$REQUESTED_MACOS_MIN_VERSION_SET" "$REQUESTED_MACOS_MIN_VERSION" "$MACOS_MIN_VERSION"

BUILD_ROOT="${LIBOQS_BUILD_ROOT:-${TMPDIR:-/tmp}/skybridge-liboqs-$LIBOQS_VERSION}"
SOURCE_DIR="$BUILD_ROOT/source"
PATCHED_SOURCE_DIR="$BUILD_ROOT/patched-source"
STAGE_OUT="$BUILD_ROOT/liboqs.stage.xcframework"
PROBE_BINARY="$BUILD_ROOT/liboqs-runtime-probe"
KAT_KEM_BINARY="$BUILD_ROOT/liboqs-kat-kem"
KAT_SIG_BINARY="$BUILD_ROOT/liboqs-kat-sig"
KAT_OUTPUT_DIR="$BUILD_ROOT/kat-output"

source "$ROOT_DIR/Scripts/native_source_helpers.sh"
skybridge_prepare_pinned_native_source \
  "$LIBOQS_REPOSITORY" "$LIBOQS_REF" "$LIBOQS_COMMIT" "$SOURCE_DIR"

rm -rf "$PATCHED_SOURCE_DIR"
mkdir -p "$PATCHED_SOURCE_DIR"
git -C "$SOURCE_DIR" archive --format=tar HEAD | tar -xf - -C "$PATCHED_SOURCE_DIR"
(
  cd "$PATCHED_SOURCE_DIR"
  git apply --check "$DOWNSTREAM_PATCH_PATH"
  git apply "$DOWNSTREAM_PATCH_PATH"
)

BUILD_JOBS="${LIBOQS_BUILD_JOBS:-$(detect_jobs)}"
COMMON_CMAKE_FLAGS=(
  -G Ninja
  -DCMAKE_C_COMPILER="$CLANG_PATH"
  -DCMAKE_BUILD_TYPE="$LIBOQS_BUILD_TYPE"
  -DCMAKE_COMPILE_WARNING_AS_ERROR=ON
  -DBUILD_SHARED_LIBS=OFF
  -DOQS_BUILD_ONLY_LIB=ON
  -DOQS_DIST_BUILD=ON
  -DOQS_MINIMAL_BUILD="$LIBOQS_ENABLED_ALGORITHMS"
  -DOQS_USE_OPENSSL=OFF
)

build_one() {
  local name="$1"
  local sdk_path="$2"
  shift 2
  local build_dir="$BUILD_ROOT/build-$name"
  local install_dir="$BUILD_ROOT/install-$name"
  local build_log="$BUILD_ROOT/build-$name.log"
  rm -rf "$build_dir" "$install_dir"
  log "configuring $name from ${LIBOQS_REF}@${LIBOQS_COMMIT}"
  [[ "$sdk_path" == "$XCODE_DEVELOPER_DIR"/* && -d "$sdk_path" ]] \
    || fail "build SDK is outside the selected Xcode: $sdk_path"
  if ! (
    export SDKROOT="$sdk_path"
    export CC="$CLANG_PATH"
    export CXX="$CLANGXX_PATH"
    cmake -S "$PATCHED_SOURCE_DIR" -B "$build_dir" \
      "${COMMON_CMAKE_FLAGS[@]}" \
      -DCMAKE_OSX_SYSROOT="$sdk_path" \
      -DCMAKE_INSTALL_PREFIX="$install_dir" \
      "$@"
    cmake --build "$build_dir" -j"$BUILD_JOBS"
    cmake --install "$build_dir"
  ) 2>&1 | tee "$build_log"; then
    fail "configure, build, or install failed for $name"
  fi
  if grep -Eiq '(^CMake Warning|warning:|warnings? generated\.)' "$build_log"; then
    grep -Ei '(^CMake Warning|warning:|warnings? generated\.)' "$build_log" >&2
    fail "compiler or build-system warning detected for $name"
  fi
  [[ -f "$install_dir/lib/liboqs.a" ]] || fail "missing installed library for $name"
  [[ -f "$install_dir/include/oqs/oqs.h" ]] || fail "missing installed headers for $name"
  cp "$ROOT_DIR/Scripts/liboqs.module.modulemap" "$install_dir/include/module.modulemap"
  find "$install_dir/include" -type d -exec chmod 755 {} +
  find "$install_dir/include" -type f -exec chmod 644 {} +
}

build_one macos-arm64 "$MACOS_SDK_PATH" \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION"

build_one ios-arm64 "$IPHONEOS_SDK_PATH" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_VERSION"

build_one ios-simulator-arm64 "$IPHONESIMULATOR_SDK_PATH" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_VERSION"

build_one ios-simulator-x86_64 "$IPHONESIMULATOR_SDK_PATH" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_VERSION"

MACOS_INSTALL="$BUILD_ROOT/install-macos-arm64"
MACOS_BUILD="$BUILD_ROOT/build-macos-arm64"
IOS_INSTALL="$BUILD_ROOT/install-ios-arm64"
SIMULATOR_ARM64_INSTALL="$BUILD_ROOT/install-ios-simulator-arm64"
SIMULATOR_X86_64_INSTALL="$BUILD_ROOT/install-ios-simulator-x86_64"
SIMULATOR_INSTALL="$BUILD_ROOT/install-ios-simulator-universal"

rm -rf "$SIMULATOR_INSTALL"
mkdir -p "$SIMULATOR_INSTALL/lib"
python3 "$ROOT_DIR/Scripts/merge_liboqs_simulator_headers.py" \
  --arm64 "$SIMULATOR_ARM64_INSTALL/include" \
  --x86-64 "$SIMULATOR_X86_64_INSTALL/include" \
  --output "$SIMULATOR_INSTALL/include"
for simulator_architecture in arm64 x86_64; do
  SDKROOT="$IPHONESIMULATOR_SDK_PATH" "$CLANG_PATH" \
    -arch "$simulator_architecture" \
    -isysroot "$IPHONESIMULATOR_SDK_PATH" \
    -std=c17 \
    -Wall -Wextra -Wpedantic -Werror \
    -mios-simulator-version-min="$IOS_MIN_VERSION" \
    -I "$SIMULATOR_INSTALL/include" \
    -fsyntax-only \
    "$ROOT_DIR/Scripts/liboqs_version_probe.c"
done
"$LIPO_PATH" -create \
  "$SIMULATOR_ARM64_INSTALL/lib/liboqs.a" \
  "$SIMULATOR_X86_64_INSTALL/lib/liboqs.a" \
  -output "$SIMULATOR_INSTALL/lib/liboqs.a"
[[ "$("$LIPO_PATH" -archs "$SIMULATOR_INSTALL/lib/liboqs.a")" == "x86_64 arm64" || \
   "$("$LIPO_PATH" -archs "$SIMULATOR_INSTALL/lib/liboqs.a")" == "arm64 x86_64" ]] \
  || fail "simulator archive is not an arm64/x86_64 universal binary"

rm -rf "$STAGE_OUT"
"$XCODEBUILD_PATH" -create-xcframework \
  -library "$MACOS_INSTALL/lib/liboqs.a" -headers "$MACOS_INSTALL/include" \
  -library "$IOS_INSTALL/lib/liboqs.a" -headers "$IOS_INSTALL/include" \
  -library "$SIMULATOR_INSTALL/lib/liboqs.a" -headers "$SIMULATOR_INSTALL/include" \
  -output "$STAGE_OUT"
cp "$PATCHED_SOURCE_DIR/LICENSE.txt" "$STAGE_OUT/LICENSE.txt"
chmod 644 "$STAGE_OUT/LICENSE.txt"

python3 - "$STAGE_OUT/Info.plist" <<'PY'
import pathlib
import plistlib
import sys

with pathlib.Path(sys.argv[1]).open("rb") as stream:
    libraries = plistlib.load(stream).get("AvailableLibraries")
expected = {
    ("ios", None, ("arm64",)),
    ("ios", "simulator", ("arm64", "x86_64")),
    ("macos", None, ("arm64",)),
}
actual = {
    (
        entry.get("SupportedPlatform"),
        entry.get("SupportedPlatformVariant"),
        tuple(entry.get("SupportedArchitectures", [])),
    )
    for entry in libraries or []
}
if actual != expected or len(libraries or []) != 3:
    raise SystemExit(f"unexpected liboqs XCFramework slices: {sorted(map(str, actual))}")
PY

SDKROOT="$MACOS_SDK_PATH" "$CLANG_PATH" \
  -arch arm64 \
  -isysroot "$MACOS_SDK_PATH" \
  -std=c17 \
  -Wall -Wextra -Wpedantic -Werror \
  -mmacosx-version-min="$MACOS_MIN_VERSION" \
  -I "$MACOS_INSTALL/include" \
  "$ROOT_DIR/Scripts/liboqs_version_probe.c" \
  "$MACOS_INSTALL/lib/liboqs.a" \
  -framework Security \
  -o "$PROBE_BINARY"
"$PROBE_BINARY" "$LIBOQS_VERSION"

SDKROOT="$MACOS_SDK_PATH" "$CLANG_PATH" \
  -arch arm64 \
  -isysroot "$MACOS_SDK_PATH" \
  -std=c17 \
  -Wall -Wextra -Wpedantic -Werror \
  -mmacosx-version-min="$MACOS_MIN_VERSION" \
  -I "$MACOS_BUILD/include" \
  -I "$MACOS_INSTALL/include" \
  -I "$PATCHED_SOURCE_DIR/tests" \
  "$PATCHED_SOURCE_DIR/tests/kat_kem.c" \
  "$PATCHED_SOURCE_DIR/tests/test_helpers.c" \
  "$MACOS_INSTALL/lib/liboqs.a" \
  "$MACOS_BUILD/lib/liboqs-internal.a" \
  -framework Security \
  -o "$KAT_KEM_BINARY"

SDKROOT="$MACOS_SDK_PATH" "$CLANG_PATH" \
  -arch arm64 \
  -isysroot "$MACOS_SDK_PATH" \
  -std=c17 \
  -Wall -Wextra -Wpedantic -Werror \
  -mmacosx-version-min="$MACOS_MIN_VERSION" \
  -I "$MACOS_BUILD/include" \
  -I "$MACOS_INSTALL/include" \
  -I "$PATCHED_SOURCE_DIR/tests" \
  "$PATCHED_SOURCE_DIR/tests/kat_sig.c" \
  "$PATCHED_SOURCE_DIR/tests/test_helpers.c" \
  "$MACOS_INSTALL/lib/liboqs.a" \
  "$MACOS_BUILD/lib/liboqs-internal.a" \
  -framework Security \
  -o "$KAT_SIG_BINARY"

run_kat() {
  local kind="$1" binary="$2" algorithm="$3"
  local output="$KAT_OUTPUT_DIR/${kind}-${algorithm}.txt"
  local expected_hash actual_hash
  mkdir -p "$KAT_OUTPUT_DIR"
  "$binary" "$algorithm" >"$output"
  expected_hash="$(python3 - "$PATCHED_SOURCE_DIR/tests/KATs/$kind/kats.json" "$algorithm" <<'PY'
import json
import pathlib
import sys

record = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
algorithm = sys.argv[2]
try:
    expected = record[algorithm]["single"]
except (KeyError, TypeError) as error:
    raise SystemExit(f"missing pinned KAT digest for {algorithm}") from error
if not isinstance(expected, str) or len(expected) != 64:
    raise SystemExit(f"invalid pinned KAT digest for {algorithm}")
print(expected)
PY
)"
  actual_hash="$(shasum -a 256 "$output" | awk '{ print $1 }')"
  [[ "$actual_hash" == "$expected_hash" ]] \
    || fail "$algorithm KAT digest mismatch: expected $expected_hash, got $actual_hash"
}

run_kat kem "$KAT_KEM_BINARY" ML-KEM-768
run_kat kem "$KAT_KEM_BINARY" ML-KEM-1024
run_kat sig "$KAT_SIG_BINARY" ML-DSA-65
run_kat sig "$KAT_SIG_BINARY" ML-DSA-87

for archive in "$STAGE_OUT"/*/liboqs.a; do
  symbols="$("$NM_PATH" -gU "$archive")" || fail "failed to inspect symbols in $archive"
  for symbol in _OQS_version _OQS_KEM_new _OQS_KEM_encaps _OQS_KEM_decaps _OQS_SIG_new _OQS_SIG_sign _OQS_SIG_verify; do
    grep -Fq "$symbol" <<<"$symbols" || fail "missing required symbol $symbol in $archive"
  done
done

PUBLISH_STAGE="$ROOT_DIR/Sources/Vendor/.liboqs.next.$$"
BACKUP_STAGE="$ROOT_DIR/Sources/Vendor/.liboqs.previous.$$"
rm -rf "$PUBLISH_STAGE" "$BACKUP_STAGE"
mkdir -p "$PUBLISH_STAGE" "$BACKUP_STAGE"
cp -R "$STAGE_OUT" "$PUBLISH_STAGE/liboqs.xcframework"

python3 "$ROOT_DIR/Scripts/native_vendor_provenance.py" create \
  --family liboqs \
  --lock "$NATIVE_DEPENDENCY_LOCK" \
  --repository-root "$ROOT_DIR" \
  --recipe "$ROOT_DIR/Scripts/build_liboqs_xcframework.sh" \
  --output "$PUBLISH_STAGE/provenance.json" \
  --artifact-root "xcframework|$PUBLISH_STAGE/liboqs.xcframework|Sources/Vendor/liboqs.xcframework" \
  --source "liboqs|$LIBOQS_VERSION|$LIBOQS_REF|$LIBOQS_COMMIT|$LIBOQS_REPOSITORY|$SOURCE_DIR" \
  --build-input "architectures=$LIBOQS_ARCHITECTURES" \
  --build-input "macos_deployment_target=$MACOS_MIN_VERSION" \
  --build-input "ios_deployment_target=$IOS_MIN_VERSION" \
  --build-input "build_type=$LIBOQS_BUILD_TYPE" \
  --build-input "distribution_build=$LIBOQS_DISTRIBUTION_BUILD" \
  --build-input "downstream_patch=$LIBOQS_DOWNSTREAM_PATCH" \
  --build-input "enabled_algorithms=$LIBOQS_ENABLED_ALGORITHMS" \
  --build-input "linkage=$LIBOQS_LINKAGE" \
  --build-input "openssl=$LIBOQS_OPENSSL"

publish_committed=0
rollback_publish() {
  local status=$?
  if [[ "$publish_committed" -ne 1 ]]; then
    rm -rf "$FINAL_OUT" "$PROVENANCE_OUT"
    [[ ! -e "$BACKUP_STAGE/liboqs.xcframework" ]] \
      || mv "$BACKUP_STAGE/liboqs.xcframework" "$FINAL_OUT"
    [[ ! -e "$BACKUP_STAGE/provenance.json" ]] \
      || mv "$BACKUP_STAGE/provenance.json" "$PROVENANCE_OUT"
  fi
  rm -rf "$PUBLISH_STAGE" "$BACKUP_STAGE"
  exit "$status"
}
trap rollback_publish EXIT

[[ ! -e "$FINAL_OUT" ]] || mv "$FINAL_OUT" "$BACKUP_STAGE/liboqs.xcframework"
[[ ! -e "$PROVENANCE_OUT" ]] || mv "$PROVENANCE_OUT" "$BACKUP_STAGE/provenance.json"
mv "$PUBLISH_STAGE/liboqs.xcframework" "$FINAL_OUT"
mv "$PUBLISH_STAGE/provenance.json" "$PROVENANCE_OUT"
python3 "$ROOT_DIR/Scripts/native_vendor_provenance.py" verify \
  --lock "$NATIVE_DEPENDENCY_LOCK" \
  --repository-root "$ROOT_DIR" \
  --provenance "$PROVENANCE_OUT"

publish_committed=1
trap - EXIT
rm -rf "$PUBLISH_STAGE" "$BACKUP_STAGE"
log "updated $FINAL_OUT with liboqs $LIBOQS_VERSION"
