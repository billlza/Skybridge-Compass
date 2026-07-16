#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_READINESS_WORKFLOW="${ROOT_DIR}/.github/workflows/macos-release-readiness.yml"
QPERIAPT_SOURCE_COMMIT="f15917ee7daa7b07976ee147eb102d2afb468b76"
QPERIAPT_HEADER_SHA256="6e5be78c9b43fa245777eabd84dea4a137ecd6ebdb0266fa018a8aa4e3f1771f"
QPERIAPT_PROVENANCE="VendorProvenance/QPeriapt/abi2-v0.1.0-alpha.2.json"
QPERIAPT_LIBRARY_NAME="libq_periapt_ffi_abi2.a"

fail() {
  echo "[test-vendor-artifact-policy] $1" >&2
  exit 1
}

command -v rustc >/dev/null 2>&1 || fail "rustc is required to inspect vendored Rust symbols"
command -v lipo >/dev/null 2>&1 || fail "lipo is required to inspect vendored Apple architectures"
command -v shasum >/dev/null 2>&1 || fail "shasum is required to verify vendored artifacts"
RUST_HOST="$(rustc -vV | awk '/^host:/ { print $2 }')"
RUST_SYSROOT="$(rustc --print sysroot)"
LLVM_NM="$RUST_SYSROOT/lib/rustlib/$RUST_HOST/bin/llvm-nm"
[[ -x "$LLVM_NM" ]] || fail "Rust llvm-nm not found: $LLVM_NM"

require_release_file_bound_to_head() {
  local path="$1"
  local index_record
  local index_oid
  local head_oid
  local worktree_oid

  [[ -f "${ROOT_DIR}/${path}" && ! -L "${ROOT_DIR}/${path}" ]] \
    || fail "required vendor artifact must be a regular non-symlink file: ${path}"
  if git -C "${ROOT_DIR}" check-ignore -q -- "${path}"; then
    fail "required vendor artifact is ignored by git: ${path}"
  fi
  git -C "${ROOT_DIR}" ls-files --error-unmatch -- "${path}" >/dev/null 2>&1 \
    || fail "required vendor artifact is not tracked by git: ${path}"
  git -C "${ROOT_DIR}" cat-file -e "HEAD:${path}" 2>/dev/null \
    || fail "required vendor artifact is not present in HEAD: ${path}"

  index_record="$(git -C "${ROOT_DIR}" ls-files --stage -- "${path}")"
  [[ "$(printf '%s\n' "${index_record}" | wc -l | tr -d ' ')" == "1" ]] \
    || fail "required vendor artifact has an ambiguous index entry: ${path}"
  [[ "$(awk '{ print $3 }' <<<"${index_record}")" == "0" ]] \
    || fail "required vendor artifact has an unresolved index stage: ${path}"
  index_oid="$(awk '{ print $2 }' <<<"${index_record}")"
  head_oid="$(git -C "${ROOT_DIR}" rev-parse "HEAD:${path}")"
  worktree_oid="$(git -C "${ROOT_DIR}" hash-object -- "${ROOT_DIR}/${path}")"
  [[ "${index_oid}" == "${head_oid}" && "${worktree_oid}" == "${head_oid}" ]] \
    || fail "required vendor artifact differs across HEAD, index, and worktree: ${path}"
}

assert_exact_head_bound_qperiapt_tree() {
  local expected_paths
  local actual_paths
  local path
  expected_paths="$(printf '%s\n' \
    Sources/Vendor/qperiapt.xcframework/Info.plist \
    Sources/Vendor/qperiapt.xcframework/SkyBridgeQPeriaptProvenance.json \
    Sources/Vendor/qperiapt.xcframework/ios-arm64/Headers/q_periapt.h \
    Sources/Vendor/qperiapt.xcframework/ios-arm64/libq_periapt_ffi_abi2.a \
    Sources/Vendor/qperiapt.xcframework/ios-arm64_x86_64-simulator/Headers/q_periapt.h \
    Sources/Vendor/qperiapt.xcframework/ios-arm64_x86_64-simulator/libq_periapt_ffi_abi2.a \
    Sources/Vendor/qperiapt.xcframework/macos-arm64_x86_64/Headers/q_periapt.h \
    Sources/Vendor/qperiapt.xcframework/macos-arm64_x86_64/libq_periapt_ffi_abi2.a)"
  actual_paths="$(
    cd "${ROOT_DIR}"
    find Sources/Vendor/qperiapt.xcframework \( -type f -o -type l \) -print | LC_ALL=C sort
  )"
  [[ "${actual_paths}" == "${expected_paths}" ]] \
    || fail "Q-Periapt canonical XCFramework tree differs from the exact eight-file release contract"
  while IFS= read -r path; do
    require_release_file_bound_to_head "${path}"
  done <<<"${expected_paths}"
}

assert_no_modulemaps() {
  local path="$1"
  [[ -d "${ROOT_DIR}/${path}" ]] || fail "missing required vendor xcframework: ${path}"
  local first_modulemap
  first_modulemap="$(find "${ROOT_DIR}/${path}" -name module.modulemap -type f -print -quit)"
  [[ -z "${first_modulemap}" ]] \
    || fail "${path} must not contain module.modulemap; CQPeriapt owns the module boundary"
}

assert_no_large_vendor_files() {
  local first_large_file
  first_large_file="$(
    find \
      "${ROOT_DIR}/Sources/Vendor/FreeRDPDylibs" \
      "${ROOT_DIR}/Sources/Vendor/qperiapt.xcframework" \
      -type f -size +95000000c -print -quit
  )"
  [[ -z "${first_large_file}" ]] \
    || fail "vendor artifact is too large for ordinary GitHub push safety: ${first_large_file}"
}

assert_no_user_home_paths_in_static_library() {
  local path="$1"
  local first_match
  first_match="$(
    strings -a "${ROOT_DIR}/${path}" \
      | grep -E '/Users/[^[:space:]]+' \
      | grep -Ev '^/Users/runner/work/rust/rust/' \
      | head -n 1 \
      || true
  )"
  [[ -z "${first_match}" ]] \
    || fail "${path} leaks a non-toolchain local user path into the vendored binary: ${first_match}"
}

assert_qperiapt_symbols() {
  local path="$1"
  local symbols
  if ! symbols="$($LLVM_NM --defined-only "${ROOT_DIR}/${path}" 2>/dev/null)"; then
    fail "failed to inspect Q-Periapt symbols in ${path}"
  fi
  local declared_symbols
  declared_symbols="$(python3 - "${ROOT_DIR}/Sources/CQPeriapt/include/q_periapt.h" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="strict")
symbols = set(
    re.findall(
        r"\b(?:const\s+char\s*\*|u?int(?:32|64)_t|uintptr_t)\s*"
        r"(q_periapt_[A-Za-z0-9_]+)\s*\(",
        source,
    )
)
if not symbols:
    raise SystemExit("Q-Periapt header declares no C ABI symbols")
print("\n".join(sorted(symbols)))
PY
)"
  local exported_symbols
  exported_symbols="$({
    awk '{
      symbol = $NF
      sub(/^_/, "", symbol)
      if (symbol ~ /^q_periapt_[A-Za-z0-9_]+$/) {
        print symbol
      }
    }' <<<"${symbols}"
  } | LC_ALL=C sort -u)"
  local expected_symbols
  expected_symbols="$(printf '%s\n' \
    q_periapt_abi_version \
    q_periapt_decapsulate \
    q_periapt_decision_from_signed_policy \
    q_periapt_encapsulate \
    q_periapt_fixed_suite_id \
    q_periapt_fixed_suite_id_len \
    q_periapt_generate_keypair \
    q_periapt_status_name \
    q_periapt_version)"
  [[ "$declared_symbols" == "$expected_symbols" ]] \
    || fail "CQPeriapt header differs from the frozen ABI2 exact-nine symbol contract"
  [[ "$exported_symbols" == "$expected_symbols" ]] \
    || fail "${path} differs from the frozen ABI2 exact-nine exported symbol contract"
}

assert_qperiapt_header_matches() {
  local path="$1"
  local canonical="${ROOT_DIR}/Sources/CQPeriapt/include/q_periapt.h"
  [[ -f "${ROOT_DIR}/${path}" ]] || fail "missing Q-Periapt header: ${path}"
  cmp -s "$canonical" "${ROOT_DIR}/${path}" \
    || fail "${path} differs from the CQPeriapt compile-time header"
}

assert_sha256() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "${ROOT_DIR}/${path}" | awk '{ print $1 }')"
  [[ "$actual" == "$expected" ]] \
    || fail "${path} SHA-256 mismatch: expected ${expected}, got ${actual}"
}

assert_architectures() {
  local path="$1"
  local expected="$2"
  local actual_normalized expected_normalized
  actual_normalized="$(lipo -archs "${ROOT_DIR}/${path}" | tr ' ' '\n' | LC_ALL=C sort | paste -sd ' ' -)"
  expected_normalized="$(printf '%s\n' "$expected" | tr ' ' '\n' | LC_ALL=C sort | paste -sd ' ' -)"
  [[ "$actual_normalized" == "$expected_normalized" ]] \
    || fail "${path} architecture mismatch: $(lipo -archs "${ROOT_DIR}/${path}")"
}

assert_qperiapt_derivative_shape() {
  local root="$1"
  [[ ! -e "${ROOT_DIR}/${root}/_CodeSignature" ]] \
    || fail "${root} retains an invalidated upstream signature"
  cmp -s \
    "${ROOT_DIR}/${QPERIAPT_PROVENANCE}" \
    "${ROOT_DIR}/${root}/SkyBridgeQPeriaptProvenance.json" \
    || fail "${root} provenance differs from the checked-in canonical record"
  python3 - "${ROOT_DIR}/${root}/Info.plist" <<'PY'
import pathlib
import plistlib
import sys

with pathlib.Path(sys.argv[1]).open("rb") as stream:
    info = plistlib.load(stream)
expected = {
    "ios-arm64": ("ios", None, ["arm64"]),
    "ios-arm64_x86_64-simulator": ("ios", "simulator", ["arm64", "x86_64"]),
    "macos-arm64_x86_64": ("macos", None, ["arm64", "x86_64"]),
}
libraries = info.get("AvailableLibraries")
if not isinstance(libraries, list) or len(libraries) != len(expected):
    raise SystemExit("Q-Periapt derivative must contain exactly three ABI2 slices")
seen = set()
for library in libraries:
    identifier = library.get("LibraryIdentifier")
    if identifier not in expected or identifier in seen:
        raise SystemExit(f"unexpected Q-Periapt slice: {identifier}")
    seen.add(identifier)
    platform, variant, architectures = expected[identifier]
    if library.get("LibraryPath") != "libq_periapt_ffi_abi2.a":
        raise SystemExit(f"unexpected ABI2 library path: {identifier}")
    if library.get("HeadersPath") != "Headers":
        raise SystemExit(f"unexpected ABI2 headers path: {identifier}")
    if library.get("SupportedPlatform") != platform:
        raise SystemExit(f"unexpected ABI2 platform: {identifier}")
    if library.get("SupportedPlatformVariant") != variant:
        raise SystemExit(f"unexpected ABI2 platform variant: {identifier}")
    if library.get("SupportedArchitectures") != architectures:
        raise SystemExit(f"unexpected ABI2 architectures: {identifier}")
PY
}

if grep -Fq "/Users/" "${ROOT_DIR}/Scripts/build_qperiapt_xcframework.sh"; then
  fail "build_qperiapt_xcframework.sh must not hard-code a local user path"
fi

grep -Fq "repository: billlza/q-periapt" "${RELEASE_READINESS_WORKFLOW}" \
  || fail "macos-release-readiness must checkout q-periapt explicitly for clean CI source contracts"
grep -Fq "ref: ${QPERIAPT_SOURCE_COMMIT}" "${RELEASE_READINESS_WORKFLOW}" \
  || fail "macos-release-readiness q-periapt checkout must be pinned to a full commit SHA"
grep -Fq "path: External/pqt_hybrid_suite" "${RELEASE_READINESS_WORKFLOW}" \
  || fail "macos-release-readiness q-periapt checkout must land in External/pqt_hybrid_suite"
grep -Fq "../pqt_hybrid_suite/crates/q-periapt-backends/Cargo.toml" "${RELEASE_READINESS_WORKFLOW}" \
  || fail "macos-release-readiness must prove the q-periapt sibling path dependency is reachable"

assert_no_modulemaps "Sources/Vendor/qperiapt.xcframework"
assert_qperiapt_derivative_shape "Sources/Vendor/qperiapt.xcframework"
assert_exact_head_bound_qperiapt_tree
require_release_file_bound_to_head "$QPERIAPT_PROVENANCE"
require_release_file_bound_to_head "Sources/CQPeriapt/include/q_periapt.h"
assert_sha256 "Sources/CQPeriapt/include/q_periapt.h" "$QPERIAPT_HEADER_SHA256"

python3 - "${ROOT_DIR}/${QPERIAPT_PROVENANCE}" "$QPERIAPT_SOURCE_COMMIT" <<'PY'
import json
import pathlib
import sys

record = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
source_commit = sys.argv[2]
if record.get("schema_version") != 1:
    raise SystemExit("unexpected Q-Periapt provenance schema")
if record.get("version") != "0.1.0-alpha.2" or record.get("abi_major") != 2:
    raise SystemExit("Q-Periapt provenance version/ABI mismatch")
if record.get("source_commit") != source_commit:
    raise SystemExit("Q-Periapt provenance source commit mismatch")
if record.get("release_tag") != "v0.1.0-alpha.2":
    raise SystemExit("Q-Periapt provenance release tag mismatch")
derivation = record.get("skybridge_derivation", {})
if derivation.get("linked_static_library_bytes_changed") is not False:
    raise SystemExit("Q-Periapt provenance must prove unchanged static-library bytes")
if derivation.get("retains_upstream_container_signature") is not False:
    raise SystemExit("Q-Periapt derivative must not claim to retain the invalidated signature")
PY

for dylib in \
  libcrypto.3.dylib \
  libfreerdp-client3.dylib \
  libfreerdp3.dylib \
  libjansson.4.dylib \
  libssl.3.dylib \
  liburiparser.1.dylib \
  libwinpr3.dylib
do
  require_release_file_bound_to_head "Sources/Vendor/FreeRDPDylibs/${dylib}"
done

while IFS='|' read -r slice expected_hash expected_architectures; do
  mac_path="Sources/Vendor/qperiapt.xcframework/${slice}/${QPERIAPT_LIBRARY_NAME}"
  assert_sha256 "$mac_path" "$expected_hash"
  assert_architectures "$mac_path" "$expected_architectures"
  assert_no_user_home_paths_in_static_library "$mac_path"
  assert_qperiapt_symbols "$mac_path"
  assert_qperiapt_header_matches "Sources/Vendor/qperiapt.xcframework/${slice}/Headers/q_periapt.h"
done <<'SLICES'
macos-arm64_x86_64|a2051d393c49a1960509c0304c28b9eac516803b0268ca856aad55dd06415865|arm64 x86_64
ios-arm64|a8fc015ff871611810a484b566ce5179a375c3753d60b7f9b0faf80140fee616|arm64
ios-arm64_x86_64-simulator|d92e9dfafddf46756edc416168f4efe47b5636b800d92797a7a5443f708fd3bb|arm64 x86_64
SLICES

assert_no_large_vendor_files

echo "[test-vendor-artifact-policy] passed"
