#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)"
android_root="$repo_root/platforms/android"
cmake_file="$android_root/shared/src/main/cpp/CMakeLists.txt"
liboqs_source="$android_root/shared/scripts/build_liboqs/liboqs"
quality_workflow="$repo_root/.github/workflows/android-release-quality.yml"

[[ -f "$cmake_file" ]]
[[ -f "$liboqs_source/CMakeLists.txt" ]]
[[ -f "$quality_workflow" ]]
git -C "$repo_root" ls-files --error-unmatch \
  "platforms/android/shared/scripts/build_liboqs/liboqs/CMakeLists.txt" \
  >/dev/null

rg -F --quiet -- ':shared:assembleRelease \' "$quality_workflow"

required_markers=(
  'add_subdirectory("${LIBOQS_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/liboqs")'
  'OQS_BUILD_ONLY_LIB ON'
  'OQS_USE_OPENSSL OFF'
  'OQS_DIST_BUILD OFF'
  'KEM_ml_kem_768;SIG_ml_dsa_65'
  'LIBOQS_AVAILABLE=1'
  '-Werror=implicit-int-conversion'
)
for marker in "${required_markers[@]}"; do
  rg -F --quiet -- "$marker" "$cmake_file"
done

keccak_source="$liboqs_source/src/common/sha3/xkcp_low/KeccakP-1600/plain-64bits/KeccakP-1600-opt64.c"
[[ -f "$keccak_source" ]]
if rg --quiet -- '= ~(?:data|output)\[' "$keccak_source"; then
  printf 'tracked liboqs Keccak byte complement must use an explicit byte conversion\n' >&2
  exit 1
fi
[[ "$(rg -c --fixed-strings '(unsigned char)~' "$keccak_source")" == "3" ]]

for forbidden in 'STATIC IMPORTED' 'IMPORTED_LOCATION' 'liboqs.a' 'LIBOQS_AVAILABLE=0'; do
  if rg -F --quiet -- "$forbidden" "$cmake_file"; then
    printf 'tracked liboqs build contract rejected forbidden marker: %s\n' "$forbidden" >&2
    exit 1
  fi
done

printf 'Tracked liboqs source build contract passed.\n'
