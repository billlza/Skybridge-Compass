#!/usr/bin/env bash
set -euo pipefail

# Install the immutable, signed Q-Periapt ABI2 Apple release as the SkyBridge
# binaryTarget input. The upstream XCFramework carries a CQPeriapt module map;
# SkyBridge deliberately removes that map because CQPeriapt is already owned by
# the local C wrapper target and liboqs otherwise produces the same SwiftPM
# include/module.modulemap output. Removing a signed resource invalidates the
# upstream container signature, so this script verifies the original first,
# creates an explicitly documented derivative, removes the stale signature, and
# proves that every linked static-library byte is unchanged.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/qperiapt_install_transaction.sh"

QPERIAPT_RELEASE_TAG="v0.1.0-alpha.2"
QPERIAPT_RELEASE_BASE_URL="https://github.com/billlza/q-periapt/releases/download/${QPERIAPT_RELEASE_TAG}"
QPERIAPT_RELEASE_DIR="${QPERIAPT_RELEASE_DIR:-}"
QPERIAPT_BUILD_ROOT="${QPERIAPT_BUILD_ROOT:-$ROOT_DIR/.build/qperiapt-abi2-release}"

QPERIAPT_ZIP_SHA256="22dd93c69fae763eeb341157542f7a4acf19c4ecadb31f88bdf2af09098c1f06"
QPERIAPT_MANIFEST_SHA256="29d0e971520178c8e636ea3e52a817a27062aeceb4cfc744c371835381b6cee4"
QPERIAPT_DISTRIBUTION_SHA256="697aa87da548ef60fa3e8333d827c9ccf6215bacf73d0afadb55583546f78ec3"
QPERIAPT_SUMS_SHA256="cb9e22571450ac8d6df274484959f263d4e71219c4c5ed6c72a44a57dcbdd3a3"
QPERIAPT_HEADER_SHA256="6e5be78c9b43fa245777eabd84dea4a137ecd6ebdb0266fa018a8aa4e3f1771f"
QPERIAPT_ABI_CONTRACT_SHA256="a8b49d6df4f0fc3b80eeb5ae3e200cbab94842128926e47e0aace036f90651f9"
QPERIAPT_SOURCE_COMMIT="f15917ee7daa7b07976ee147eb102d2afb468b76"
QPERIAPT_TEAM_ID="YKUPL7Z869"
QPERIAPT_AUTHORITY="Developer ID Application: Zi ang Li (YKUPL7Z869)"
QPERIAPT_CDHASH="5f58bb35e1547e197315d21c588179fe9d1b250a"

MAC_LIBRARY_SHA256="a2051d393c49a1960509c0304c28b9eac516803b0268ca856aad55dd06415865"
IOS_LIBRARY_SHA256="a8fc015ff871611810a484b566ce5179a375c3753d60b7f9b0faf80140fee616"
IOS_SIM_LIBRARY_SHA256="d92e9dfafddf46756edc416168f4efe47b5636b800d92797a7a5443f708fd3bb"
LIB_NAME="libq_periapt_ffi_abi2.a"

FINAL_OUT="$ROOT_DIR/Sources/Vendor/qperiapt.xcframework"
CQPERIAPT_HEADER_OUT="$ROOT_DIR/Sources/CQPeriapt/include/q_periapt.h"
PROVENANCE_SOURCE="$ROOT_DIR/VendorProvenance/QPeriapt/abi2-v0.1.0-alpha.2.json"
TRANSACTION_JOURNAL="$ROOT_DIR/.build/qperiapt-vendor-install-transaction"

DOWNLOAD_DIR="$QPERIAPT_BUILD_ROOT/release"
EXTRACT_DIR="$QPERIAPT_BUILD_ROOT/extracted"
STAGED_OUT="$QPERIAPT_BUILD_ROOT/qperiapt.xcframework"

log() { printf '[build_qperiapt_xcframework] %s\n' "$*"; }

fail() {
  printf '[build_qperiapt_xcframework] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

for command in curl shasum unzip codesign lipo cmp find grep awk paste tr python3 rustc; do
  need_cmd "$command"
done

RUST_HOST="$(rustc -vV | awk '/^host:/ { print $2 }')"
RUST_SYSROOT="$(rustc --print sysroot)"
LLVM_NM="$RUST_SYSROOT/lib/rustlib/$RUST_HOST/bin/llvm-nm"
[[ -x "$LLVM_NM" ]] || fail "Rust llvm-nm not found: $LLVM_NM"
[[ -f "$PROVENANCE_SOURCE" ]] || fail "Missing checked-in Q-Periapt provenance: $PROVENANCE_SOURCE"

sha256_of() {
  shasum -a 256 "$1" | awk '{ print $1 }'
}

require_sha256() {
  local path="$1"
  local expected="$2"
  local actual
  [[ -f "$path" ]] || fail "Missing release asset: $path"
  actual="$(sha256_of "$path")"
  [[ "$actual" == "$expected" ]] \
    || fail "SHA-256 mismatch for $path: expected $expected, got $actual"
}

download_release_asset() {
  local name="$1"
  local destination="$DOWNLOAD_DIR/$name"
  local partial="$destination.partial"
  [[ -f "$destination" ]] && return
  rm -f "$partial"
  log "Downloading immutable release asset: $name"
  curl --fail --location --silent --show-error \
    --proto '=https' --tlsv1.2 --retry 3 \
    --output "$partial" "$QPERIAPT_RELEASE_BASE_URL/$name"
  mv "$partial" "$destination"
}

prepare_release_dir() {
  if [[ -n "$QPERIAPT_RELEASE_DIR" ]]; then
    [[ -d "$QPERIAPT_RELEASE_DIR" ]] \
      || fail "QPERIAPT_RELEASE_DIR is not a directory: $QPERIAPT_RELEASE_DIR"
    DOWNLOAD_DIR="$(cd "$QPERIAPT_RELEASE_DIR" && pwd -P)"
    return
  fi

  mkdir -p "$DOWNLOAD_DIR"
  download_release_asset CQPeriapt.xcframework.zip
  download_release_asset MANIFEST.json
  download_release_asset APPLE_DISTRIBUTION.json
  download_release_asset SHA256SUMS
}

validate_release_metadata() {
  require_sha256 "$DOWNLOAD_DIR/CQPeriapt.xcframework.zip" "$QPERIAPT_ZIP_SHA256"
  require_sha256 "$DOWNLOAD_DIR/MANIFEST.json" "$QPERIAPT_MANIFEST_SHA256"
  require_sha256 "$DOWNLOAD_DIR/APPLE_DISTRIBUTION.json" "$QPERIAPT_DISTRIBUTION_SHA256"
  require_sha256 "$DOWNLOAD_DIR/SHA256SUMS" "$QPERIAPT_SUMS_SHA256"

  (
    cd "$DOWNLOAD_DIR"
    shasum -a 256 -c SHA256SUMS
  )

  python3 - \
    "$DOWNLOAD_DIR/MANIFEST.json" \
    "$DOWNLOAD_DIR/APPLE_DISTRIBUTION.json" \
    "$QPERIAPT_ZIP_SHA256" \
    "$QPERIAPT_ABI_CONTRACT_SHA256" \
    "$QPERIAPT_SOURCE_COMMIT" \
    "$QPERIAPT_TEAM_ID" <<'PY'
import json
import pathlib
import sys

manifest_path, distribution_path, zip_sha, abi_sha, source_commit, team_id = sys.argv[1:]
manifest = json.loads(pathlib.Path(manifest_path).read_text(encoding="utf-8"))
distribution = json.loads(pathlib.Path(distribution_path).read_text(encoding="utf-8"))

expected_manifest = {
    "schema_version": 4,
    "version": "0.1.0-alpha.2",
    "git_commit": source_commit,
}
for key, expected in expected_manifest.items():
    if manifest.get(key) != expected:
        raise SystemExit(f"MANIFEST.json {key} mismatch")
if manifest.get("abi", {}).get("major") != 2:
    raise SystemExit("MANIFEST.json ABI major is not 2")
if manifest.get("abi", {}).get("export_count") != 9:
    raise SystemExit("MANIFEST.json export count is not 9")
if manifest.get("abi", {}).get("contract_sha256") != abi_sha:
    raise SystemExit("MANIFEST.json ABI contract hash mismatch")
if manifest.get("artifacts", {}).get("xcframework_zip", {}).get("sha256") != zip_sha:
    raise SystemExit("MANIFEST.json XCFramework hash mismatch")

if distribution.get("schema_version") != 2:
    raise SystemExit("APPLE_DISTRIBUTION.json schema mismatch")
if distribution.get("source_commit") != source_commit:
    raise SystemExit("APPLE_DISTRIBUTION.json source commit mismatch")
if distribution.get("artifact", {}).get("sha256") != zip_sha:
    raise SystemExit("APPLE_DISTRIBUTION.json artifact hash mismatch")
signature = distribution.get("origin_signature", {}).get("signature", {})
if signature.get("team_id") != team_id or signature.get("strict_verification") is not True:
    raise SystemExit("APPLE_DISTRIBUTION.json signature identity mismatch")
PY
}

validate_archive_shape() {
  python3 - "$DOWNLOAD_DIR/CQPeriapt.xcframework.zip" <<'PY'
import pathlib
import stat
import sys
import zipfile

archive = pathlib.Path(sys.argv[1])
expected = {
    "CQPeriapt.xcframework/",
    "CQPeriapt.xcframework/Info.plist",
    "CQPeriapt.xcframework/_CodeSignature/",
    "CQPeriapt.xcframework/_CodeSignature/CodeDirectory",
    "CQPeriapt.xcframework/_CodeSignature/CodeRequirements",
    "CQPeriapt.xcframework/_CodeSignature/CodeResources",
    "CQPeriapt.xcframework/_CodeSignature/CodeSignature",
    "CQPeriapt.xcframework/ios-arm64/",
    "CQPeriapt.xcframework/ios-arm64/Headers/",
    "CQPeriapt.xcframework/ios-arm64/Headers/module.modulemap",
    "CQPeriapt.xcframework/ios-arm64/Headers/q_periapt.h",
    "CQPeriapt.xcframework/ios-arm64/libq_periapt_ffi_abi2.a",
    "CQPeriapt.xcframework/ios-arm64_x86_64-simulator/",
    "CQPeriapt.xcframework/ios-arm64_x86_64-simulator/Headers/",
    "CQPeriapt.xcframework/ios-arm64_x86_64-simulator/Headers/module.modulemap",
    "CQPeriapt.xcframework/ios-arm64_x86_64-simulator/Headers/q_periapt.h",
    "CQPeriapt.xcframework/ios-arm64_x86_64-simulator/libq_periapt_ffi_abi2.a",
    "CQPeriapt.xcframework/macos-arm64_x86_64/",
    "CQPeriapt.xcframework/macos-arm64_x86_64/Headers/",
    "CQPeriapt.xcframework/macos-arm64_x86_64/Headers/module.modulemap",
    "CQPeriapt.xcframework/macos-arm64_x86_64/Headers/q_periapt.h",
    "CQPeriapt.xcframework/macos-arm64_x86_64/libq_periapt_ffi_abi2.a",
}

with zipfile.ZipFile(archive) as bundle:
    entries = bundle.infolist()
    names = [entry.filename for entry in entries]
    if len(names) != len(set(names)) or set(names) != expected:
        missing = sorted(expected.difference(names))
        extra = sorted(set(names).difference(expected))
        raise SystemExit(f"unexpected XCFramework archive shape; missing={missing}, extra={extra}")
    if sum(entry.file_size for entry in entries) != 90_064_330:
        raise SystemExit("unexpected XCFramework uncompressed size")
    for entry in entries:
        path = pathlib.PurePosixPath(entry.filename)
        if path.is_absolute() or ".." in path.parts or "\\" in entry.filename:
            raise SystemExit(f"unsafe archive path: {entry.filename}")
        if entry.flag_bits & 0x1:
            raise SystemExit(f"encrypted archive entry is forbidden: {entry.filename}")
        mode = (entry.external_attr >> 16) & 0xFFFF
        if entry.is_dir():
            if mode and not stat.S_ISDIR(mode):
                raise SystemExit(f"directory entry has unsafe mode: {entry.filename}")
        elif mode and not stat.S_ISREG(mode):
            raise SystemExit(f"non-regular archive entry is forbidden: {entry.filename}")
PY
}

declared_qperiapt_symbols() {
  python3 - "$1" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="strict")
symbols = set(re.findall(
    r"\b(?:const\s+char\s*\*|u?int(?:32|64)_t|uintptr_t)\s*"
    r"(q_periapt_[A-Za-z0-9_]+)\s*\(",
    source,
))
print("\n".join(sorted(symbols)))
PY
}

expected_qperiapt_symbols() {
  printf '%s\n' \
    q_periapt_abi_version \
    q_periapt_decapsulate \
    q_periapt_decision_from_signed_policy \
    q_periapt_encapsulate \
    q_periapt_fixed_suite_id \
    q_periapt_fixed_suite_id_len \
    q_periapt_generate_keypair \
    q_periapt_status_name \
    q_periapt_version
}

exported_qperiapt_symbols() {
  "$LLVM_NM" --defined-only "$1" 2>/dev/null \
    | awk '{ symbol = $NF; sub(/^_/, "", symbol); if (symbol ~ /^q_periapt_[A-Za-z0-9_]+$/) print symbol }' \
    | LC_ALL=C sort -u
}

assert_exact_symbols() {
  local header="$1"
  local library="$2"
  local expected declared exported
  expected="$(expected_qperiapt_symbols)"
  declared="$(declared_qperiapt_symbols "$header")"
  exported="$(exported_qperiapt_symbols "$library")" \
    || fail "Failed to inspect Q-Periapt symbols: $library"
  [[ "$declared" == "$expected" ]] \
    || fail "Q-Periapt header does not declare the frozen ABI2 exact-nine symbol set"
  [[ "$exported" == "$expected" ]] \
    || fail "Q-Periapt library does not export the frozen ABI2 exact-nine symbol set: $library"
}

assert_header_contract() {
  local header="$1"
  require_sha256 "$header" "$QPERIAPT_HEADER_SHA256"
  local token
  for token in \
    "#define Q_PERIAPT_ABI_VERSION 2" \
    "#define Q_PERIAPT_MAX_SIGNED_POLICY_BYTES 65536" \
    "#define Q_PERIAPT_MAX_APPLICATION_CONTEXT_BYTES 65536" \
    "#define Q_PERIAPT_TRUSTED_POLICY_STATE_LEN 36" \
    "#define Q_PERIAPT_POLICY_DECISION_LEN 40" \
    "#define Q_PERIAPT_MLKEM768_SK_LEN 2400" \
    "#define Q_PERIAPT_MLKEM768_PK_LEN 1184" \
    "#define Q_PERIAPT_MLKEM768_CT_LEN 1088" \
    "#define Q_PERIAPT_X25519_LEN 32" \
    "#define Q_PERIAPT_SECRET_LEN 32" \
    "int32_t q_periapt_decision_from_signed_policy(" \
    "int32_t q_periapt_generate_keypair(" \
    "int32_t q_periapt_encapsulate(" \
    "int32_t q_periapt_decapsulate("
  do
    grep -Fq "$token" "$header" \
      || fail "ABI2 header is missing required contract token: $token"
  done

  for forbidden in \
    q_periapt_mlkem768_keypair \
    q_periapt_x25519_keypair \
    q_periapt_hybrid_encapsulate \
    q_periapt_hybrid_decapsulate \
    q_periapt_combine \
    q_periapt_hybrid_encapsulate_with_decision \
    q_periapt_hybrid_decapsulate_with_decision
  do
    ! grep -Fq "$forbidden" "$header" \
      || fail "ABI2 header exposes forbidden ABI1/speculative symbol: $forbidden"
  done
}

assert_info_plist() {
  python3 - "$1" <<'PY'
import plistlib
import pathlib
import sys

with pathlib.Path(sys.argv[1]).open("rb") as stream:
    info = plistlib.load(stream)
expected = {
    "ios-arm64": ("ios", None, ["arm64"]),
    "ios-arm64_x86_64-simulator": ("ios", "simulator", ["arm64", "x86_64"]),
    "macos-arm64_x86_64": ("macos", None, ["arm64", "x86_64"]),
}
libraries = info.get("AvailableLibraries")
if not isinstance(libraries, list) or len(libraries) != 3:
    raise SystemExit("XCFramework must contain exactly three libraries")
seen = set()
for library in libraries:
    identifier = library.get("LibraryIdentifier")
    if identifier not in expected or identifier in seen:
        raise SystemExit(f"unexpected XCFramework slice: {identifier}")
    seen.add(identifier)
    platform, variant, architectures = expected[identifier]
    if library.get("LibraryPath") != "libq_periapt_ffi_abi2.a":
        raise SystemExit(f"unexpected library path for {identifier}")
    if library.get("HeadersPath") != "Headers":
        raise SystemExit(f"unexpected headers path for {identifier}")
    if library.get("SupportedPlatform") != platform:
        raise SystemExit(f"unexpected platform for {identifier}")
    if library.get("SupportedPlatformVariant") != variant:
        raise SystemExit(f"unexpected platform variant for {identifier}")
    if library.get("SupportedArchitectures") != architectures:
        raise SystemExit(f"unexpected architectures for {identifier}")
PY
}

assert_slice_contract() {
  local xcframework="$1"
  local slice="$2"
  local expected_hash="$3"
  local expected_archs="$4"
  local header="$xcframework/$slice/Headers/q_periapt.h"
  local library="$xcframework/$slice/$LIB_NAME"
  local actual_archs_normalized
  local expected_archs_normalized
  assert_header_contract "$header"
  require_sha256 "$library" "$expected_hash"
  actual_archs_normalized="$(lipo -archs "$library" | tr ' ' '\n' | LC_ALL=C sort | paste -sd ' ' -)"
  expected_archs_normalized="$(printf '%s\n' "$expected_archs" | tr ' ' '\n' | LC_ALL=C sort | paste -sd ' ' -)"
  [[ "$actual_archs_normalized" == "$expected_archs_normalized" ]] \
    || fail "Unexpected architectures in $library: $(lipo -archs "$library")"
  assert_exact_symbols "$header" "$library"
}

assert_original_release() {
  local xcframework="$1"
  codesign --verify --deep --strict --verbose=4 "$xcframework"
  local details
  details="$(codesign --display --verbose=4 "$xcframework" 2>&1)"
  grep -Fq "Authority=$QPERIAPT_AUTHORITY" <<<"$details" \
    || fail "Q-Periapt Developer ID authority mismatch"
  grep -Fq "TeamIdentifier=$QPERIAPT_TEAM_ID" <<<"$details" \
    || fail "Q-Periapt Developer ID team mismatch"
  grep -Fq "CDHash=$QPERIAPT_CDHASH" <<<"$details" \
    || fail "Q-Periapt CodeDirectory hash mismatch"
  grep -Fq "Timestamp=" <<<"$details" \
    || fail "Q-Periapt signature has no secure timestamp"
  assert_info_plist "$xcframework/Info.plist"
  assert_slice_contract "$xcframework" macos-arm64_x86_64 "$MAC_LIBRARY_SHA256" "arm64 x86_64"
  assert_slice_contract "$xcframework" ios-arm64 "$IOS_LIBRARY_SHA256" "arm64"
  assert_slice_contract "$xcframework" ios-arm64_x86_64-simulator "$IOS_SIM_LIBRARY_SHA256" "arm64 x86_64"
}

assert_derivative() {
  local xcframework="$1"
  assert_info_plist "$xcframework/Info.plist"
  [[ ! -e "$xcframework/_CodeSignature" ]] \
    || fail "SkyBridge derivative must not retain the invalidated upstream signature"
  ! find "$xcframework" -name module.modulemap -type f -print -quit | grep -q . \
    || fail "SkyBridge derivative must not contain module.modulemap"
  cmp -s "$PROVENANCE_SOURCE" "$xcframework/SkyBridgeQPeriaptProvenance.json" \
    || fail "SkyBridge derivative provenance is missing or changed"
  assert_slice_contract "$xcframework" macos-arm64_x86_64 "$MAC_LIBRARY_SHA256" "arm64 x86_64"
  assert_slice_contract "$xcframework" ios-arm64 "$IOS_LIBRARY_SHA256" "arm64"
  assert_slice_contract "$xcframework" ios-arm64_x86_64-simulator "$IOS_SIM_LIBRARY_SHA256" "arm64 x86_64"
}

prepare_release_dir
validate_release_metadata
validate_archive_shape

rm -rf "$EXTRACT_DIR" "$STAGED_OUT"
mkdir -p "$EXTRACT_DIR"
unzip -q "$DOWNLOAD_DIR/CQPeriapt.xcframework.zip" -d "$EXTRACT_DIR"
ORIGINAL_XCFRAMEWORK="$EXTRACT_DIR/CQPeriapt.xcframework"
[[ -d "$ORIGINAL_XCFRAMEWORK" ]] || fail "Release archive did not produce CQPeriapt.xcframework"
assert_original_release "$ORIGINAL_XCFRAMEWORK"

cp -R "$ORIGINAL_XCFRAMEWORK" "$STAGED_OUT"
find "$STAGED_OUT" -name module.modulemap -type f -delete
rm -rf "$STAGED_OUT/_CodeSignature"
cp "$PROVENANCE_SOURCE" "$STAGED_OUT/SkyBridgeQPeriaptProvenance.json"
assert_derivative "$STAGED_OUT"

CANONICAL_HEADER="$STAGED_OUT/macos-arm64_x86_64/Headers/q_periapt.h"

qperiapt_transaction_begin \
  "$TRANSACTION_JOURNAL" \
  "$FINAL_OUT" \
  "$CQPERIAPT_HEADER_OUT"

TRANSACTION_MAC_STAGED="$(qperiapt_transaction_stage_path "$FINAL_OUT")"
TRANSACTION_HEADER_STAGED="$(qperiapt_transaction_stage_path "$CQPERIAPT_HEADER_OUT")"

cp -R "$STAGED_OUT" "$TRANSACTION_MAC_STAGED"
cp "$CANONICAL_HEADER" "$TRANSACTION_HEADER_STAGED"

assert_derivative "$TRANSACTION_MAC_STAGED"
cmp -s "$CANONICAL_HEADER" "$TRANSACTION_HEADER_STAGED" \
  || fail "Staged CQPeriapt header differs from the verified ABI2 header"

qperiapt_transaction_install_all

assert_derivative "$FINAL_OUT"
cmp -s "$CANONICAL_HEADER" "$CQPERIAPT_HEADER_OUT" \
  || fail "Installed CQPeriapt header differs from the verified ABI2 header"
qperiapt_transaction_commit

log "Installed verified Q-Periapt ABI2 derivative: $FINAL_OUT"
log "Synchronized ABI2 C header: $CQPERIAPT_HEADER_OUT"
log "Upstream signature was verified before transformation; linked .a bytes remain exact."
