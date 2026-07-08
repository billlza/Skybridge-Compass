#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_READINESS_WORKFLOW="${ROOT_DIR}/.github/workflows/macos-release-readiness.yml"

fail() {
  echo "[test-vendor-artifact-policy] $1" >&2
  exit 1
}

require_file_not_ignored() {
  local path="$1"
  [[ -f "${ROOT_DIR}/${path}" ]] || fail "missing required vendor artifact: ${path}"
  if git -C "${ROOT_DIR}" check-ignore -q -- "${path}"; then
    fail "required vendor artifact is ignored by git: ${path}"
  fi
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
      "${ROOT_DIR}/SkyBridge Compass iOS/Vendor/qperiapt.xcframework" \
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

if grep -Fq "/Users/" "${ROOT_DIR}/Scripts/build_qperiapt_xcframework.sh"; then
  fail "build_qperiapt_xcframework.sh must not hard-code a local user path; use QPERIAPT_REPO or External/pqt_hybrid_suite"
fi

grep -Fq "repository: billlza/q-periapt" "${RELEASE_READINESS_WORKFLOW}" \
  || fail "macos-release-readiness must checkout q-periapt explicitly for clean CI source contracts"
grep -Fq "ref: d0475a94276bc5ff65deb1c5367d1f56ca436f5b" "${RELEASE_READINESS_WORKFLOW}" \
  || fail "macos-release-readiness q-periapt checkout must be pinned to a full commit SHA"
grep -Fq "path: External/pqt_hybrid_suite" "${RELEASE_READINESS_WORKFLOW}" \
  || fail "macos-release-readiness q-periapt checkout must land in External/pqt_hybrid_suite"
grep -Fq "../pqt_hybrid_suite/crates/q-periapt-backends/Cargo.toml" "${RELEASE_READINESS_WORKFLOW}" \
  || fail "macos-release-readiness must prove the q-periapt sibling path dependency is reachable"

assert_no_modulemaps "Sources/Vendor/qperiapt.xcframework"
assert_no_modulemaps "SkyBridge Compass iOS/Vendor/qperiapt.xcframework"

for dylib in \
  libcrypto.3.dylib \
  libfreerdp-client3.dylib \
  libfreerdp3.dylib \
  libjansson.4.dylib \
  libssl.3.dylib \
  liburiparser.1.dylib \
  libwinpr3.dylib
do
  require_file_not_ignored "Sources/Vendor/FreeRDPDylibs/${dylib}"
done

for slice in macos-arm64 ios-arm64 ios-arm64-simulator; do
  require_file_not_ignored "Sources/Vendor/qperiapt.xcframework/${slice}/libq_periapt_ffi.a"
  require_file_not_ignored "SkyBridge Compass iOS/Vendor/qperiapt.xcframework/${slice}/libq_periapt_ffi.a"
  assert_no_user_home_paths_in_static_library "Sources/Vendor/qperiapt.xcframework/${slice}/libq_periapt_ffi.a"
  assert_no_user_home_paths_in_static_library "SkyBridge Compass iOS/Vendor/qperiapt.xcframework/${slice}/libq_periapt_ffi.a"
done

assert_no_large_vendor_files

echo "[test-vendor-artifact-policy] passed"
