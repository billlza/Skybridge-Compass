#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_SCRIPT="${ROOT_DIR}/Scripts/check_macos_deps.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-macos-deps-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

mkdir -p "${TMP_DIR}/app/Contents/MacOS" "${TMP_DIR}/bin"
touch \
  "${TMP_DIR}/app/Contents/MacOS/good" \
  "${TMP_DIR}/app/Contents/MacOS/bad" \
  "${TMP_DIR}/app/Contents/MacOS/fatbad" \
  "${TMP_DIR}/app/Contents/MacOS/legacy" \
  "${TMP_DIR}/app/Contents/MacOS/unknown" \
  "${TMP_DIR}/app/Contents/MacOS/readme.txt"

cat >"${TMP_DIR}/bin/file" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

path="${@: -1}"
if [[ "${STUB_FILE_MODE:-ok}" == "fail" ]]; then
  exit 70
fi
case "$(basename "${path}")" in
  good | bad | fatbad | legacy | unknown)
    echo "Mach-O 64-bit executable arm64"
    ;;
  *)
    echo "ASCII text"
    ;;
esac
SH

cat >"${TMP_DIR}/bin/otool" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

path="${@: -1}"
case "$(basename "${path}")" in
  good)
    cat <<'OUT'
Load command 0
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 14.0
      sdk 26.5
OUT
    ;;
  legacy)
    cat <<'OUT'
Load command 0
      cmd LC_VERSION_MIN_MACOSX
  cmdsize 16
  version 14.0
      sdk 26.5
OUT
    ;;
  bad)
    cat <<'OUT'
Load command 0
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 15.0
      sdk 26.5
OUT
    ;;
  fatbad)
    cat <<'OUT'
Mach header
Load command 0
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 14.0
      sdk 26.5
Mach header
Load command 0
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 15.0
      sdk 26.5
OUT
    ;;
  unknown)
    cat <<'OUT'
Load command 0
      cmd LC_ID_DYLIB
  cmdsize 48
OUT
    ;;
  *)
    exit 66
    ;;
esac
SH

chmod +x "${TMP_DIR}/bin/file" "${TMP_DIR}/bin/otool"

run_deps() {
  SKYBRIDGE_FILE_TOOL="${TMP_DIR}/bin/file" \
    SKYBRIDGE_OTOOL_TOOL="${TMP_DIR}/bin/otool" \
    bash "${TARGET_SCRIPT}" "$@"
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    printf '%s\n' "${haystack}" >&2
    echo "Expected output to contain: ${needle}" >&2
    exit 1
  fi
}

assert_failure_contains() {
  local description="$1"
  local expected_status="$2"
  local expected_fragment="$3"
  shift 3

  local output=""
  local status=0
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [[ "${status}" -ne "${expected_status}" ]]; then
    printf '%s\n' "${output}" >&2
    echo "${description}: expected exit ${expected_status}, got ${status}" >&2
    exit 1
  fi
  assert_contains "${expected_fragment}" "${output}"
}

GOOD_ONLY="${TMP_DIR}/good-only.app"
mkdir -p "${GOOD_ONLY}/Contents/MacOS"
cp "${TMP_DIR}/app/Contents/MacOS/good" "${GOOD_ONLY}/Contents/MacOS/good"
cp "${TMP_DIR}/app/Contents/MacOS/legacy" "${GOOD_ONLY}/Contents/MacOS/legacy"
good_output="$(run_deps --strict "${GOOD_ONLY}" "14.0")"
assert_contains "通过：未发现最小版本高于目标上限的二进制" "${good_output}"

BAD_APP="${TMP_DIR}/bad.app"
mkdir -p "${BAD_APP}/Contents/MacOS"
cp "${TMP_DIR}/app/Contents/MacOS/good" "${BAD_APP}/Contents/MacOS/good"
cp "${TMP_DIR}/app/Contents/MacOS/bad" "${BAD_APP}/Contents/MacOS/bad"
assert_failure_contains \
  "bad minos" \
  2 \
  "minos 15.0" \
  run_deps --strict "${BAD_APP}" "14.0"

FAT_BAD_APP="${TMP_DIR}/fat-bad.app"
mkdir -p "${FAT_BAD_APP}/Contents/MacOS"
cp "${TMP_DIR}/app/Contents/MacOS/fatbad" "${FAT_BAD_APP}/Contents/MacOS/fatbad"
assert_failure_contains \
  "fat binary bad minos" \
  2 \
  "minos 15.0" \
  run_deps --strict "${FAT_BAD_APP}" "14.0"

UNKNOWN_APP="${TMP_DIR}/unknown.app"
mkdir -p "${UNKNOWN_APP}/Contents/MacOS"
cp "${TMP_DIR}/app/Contents/MacOS/unknown" "${UNKNOWN_APP}/Contents/MacOS/unknown"
unknown_output="$(run_deps "${UNKNOWN_APP}" "14.0")"
assert_contains "未能解析最小版本的文件" "${unknown_output}"

assert_failure_contains \
  "unknown strict minos" \
  3 \
  "strict 模式要求所有 Mach-O 文件都能解析最低系统版本" \
  run_deps --strict "${UNKNOWN_APP}" "14.0"

assert_failure_contains \
  "missing root" \
  1 \
  "检查路径不存在" \
  run_deps --strict "${TMP_DIR}/missing.app" "14.0"

FILE_FAIL_APP="${TMP_DIR}/file-fail.app"
mkdir -p "${FILE_FAIL_APP}/Contents/MacOS"
cp "${TMP_DIR}/app/Contents/MacOS/good" "${FILE_FAIL_APP}/Contents/MacOS/good"
assert_failure_contains \
  "file tool failure" \
  4 \
  "strict 模式要求 file/otool 工具成功检查所有候选文件" \
  env STUB_FILE_MODE=fail SKYBRIDGE_FILE_TOOL="${TMP_DIR}/bin/file" SKYBRIDGE_OTOOL_TOOL="${TMP_DIR}/bin/otool" \
  bash "${TARGET_SCRIPT}" --strict "${FILE_FAIL_APP}" "14.0"

echo "[test-macos-deps] passed"
