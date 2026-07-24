#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_SCRIPT="${ROOT_DIR}/Scripts/check_macos_release_readiness.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-release-binary-surface-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

CLANG="$(xcrun --find clang 2>/dev/null || true)"
SWIFTC="$(xcrun --find swiftc 2>/dev/null || true)"
[[ -x "${CLANG}" ]] || {
  echo "release binary surface test requires xcrun clang" >&2
  exit 1
}
[[ -x "${SWIFTC}" ]] || {
  echo "release binary surface test requires xcrun swiftc" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    printf '%s\n' "${haystack}" >&2
    echo "expected output to contain: ${needle}" >&2
    exit 1
  fi
}

assert_failure_contains() {
  local description="$1"
  local expected_fragment="$2"
  shift 2

  local output=""
  local exit_status=0
  set +e
  output="$("$@" 2>&1)"
  exit_status=$?
  set -e

  if [[ "${exit_status}" -eq 0 ]]; then
    echo "${description}: expected failure but command succeeded" >&2
    exit 1
  fi
  assert_contains "${expected_fragment}" "${output}"
}

compile_clean_fixture() {
  local output_path="$1"
  local source_path="${TMP_DIR}/clean.c"

  cat >"${source_path}" <<'SOURCE'
int main(void) {
    return 0;
}
SOURCE
  xcrun clang -Os -Wall -Wextra -Werror "${source_path}" -o "${output_path}"
}

compile_marker_fixture() {
  local marker="$1"
  local output_path="$2"
  local source_path="${TMP_DIR}/marker.c"

  cat >"${source_path}" <<SOURCE
static const char releaseGateFixtureMarker[] __attribute__((used)) = "${marker}";

int main(void) {
    return releaseGateFixtureMarker[0] == '\0';
}
SOURCE
  xcrun clang -Os -Wall -Wextra -Werror "${source_path}" -o "${output_path}"
}

CLEAN_APP="${TMP_DIR}/Clean.app"
mkdir -p "${CLEAN_APP}/Contents/Resources/Embedded/Nested/Helpers"
compile_clean_fixture "${CLEAN_APP}/Contents/Resources/Embedded/Nested/Helpers/CleanHelper"
cat >"${CLEAN_APP}/Contents/Resources/test-surface-documentation.txt" <<'TEXT'
Documentation may name SKYBRIDGE_TESTING, UITEST_LOGIN, or LocalCameraSmokeHarness.
Only compiled Mach-O release surfaces are rejected by this gate.
TEXT

clean_output="$(
  bash "${TARGET_SCRIPT}" \
    --app-path "${CLEAN_APP}" \
    --scan-release-binaries-only
)"
assert_contains "scanned 1 Mach-O binaries" "${clean_output}"
assert_contains "all other release readiness checks were intentionally not run" "${clean_output}"
if [[ "${clean_output}" == *"WARNING:"* ]]; then
  printf '%s\n' "${clean_output}" >&2
  echo "clean release binary scan emitted a warning" >&2
  exit 1
fi

NEAR_MATCH_APP="${TMP_DIR}/NearMatch.app"
mkdir -p "${NEAR_MATCH_APP}/Contents/Resources/Embedded/Nested/Helpers"
cat >"${TMP_DIR}/near-match.c" <<'SOURCE'
static const char markerOne[] __attribute__((used)) = "NOT_SKYBRIDGE_TESTING";
static const char markerTwo[] __attribute__((used)) = "SUITEST_SCENARIO";
static const char markerThree[] __attribute__((used)) = "XCTestSessionIdentifierSuffix";
static const char markerFour[] __attribute__((used)) = "RemoteControlSmokeStatusWriterFactory";
static const char markerFive[] __attribute__((used)) = "LocalCameraSmokeHarnessFactory";
static const char markerSix[] __attribute__((used)) = "RemoteControlNoticePanelProbeHarnessFactory";

int main(void) {
    return markerOne[0] + markerTwo[0] + markerThree[0] + markerFour[0]
        + markerFive[0] + markerSix[0] == 0;
}
SOURCE
xcrun clang -Os -Wall -Wextra -Werror "${TMP_DIR}/near-match.c" \
  -o "${NEAR_MATCH_APP}/Contents/Resources/Embedded/Nested/Helpers/NearMatchHelper"
bash "${TARGET_SCRIPT}" \
  --app-path "${NEAR_MATCH_APP}" \
  --scan-release-binaries-only >/dev/null

NM_ONLY_APP="${TMP_DIR}/NMOnly.app"
mkdir -p "${NM_ONLY_APP}/Contents/Resources/Embedded/Nested/Helpers"
cat >"${TMP_DIR}/nm-only.c" <<'SOURCE'
__attribute__((noinline, visibility("default")))
int RemoteControlSmokeStatusWriter(void) {
    return 7;
}

int main(void) {
    return RemoteControlSmokeStatusWriter();
}
SOURCE
xcrun clang -Os -Wall -Wextra -Werror "${TMP_DIR}/nm-only.c" \
  -o "${NM_ONLY_APP}/Contents/Resources/Embedded/Nested/Helpers/NMOnlyHelper"
assert_failure_contains \
  "raw symbol-table marker" \
  "in its symbol table" \
  bash "${TARGET_SCRIPT}" \
    --app-path "${NM_ONLY_APP}" \
    --scan-release-binaries-only

DEMANGLE_ONLY_APP="${TMP_DIR}/DemangleOnly.app"
mkdir -p "${DEMANGLE_ONLY_APP}/Contents/Resources/Embedded/Nested/Helpers"
cat >"${TMP_DIR}/demangle-only.swift" <<'SOURCE'
@inline(never)
public func LocalCameraSmokeHarness() -> Int {
    7
}

@main
struct FixtureMain {
    static func main() {
        print(LocalCameraSmokeHarness())
    }
}
SOURCE
xcrun swiftc \
  -parse-as-library \
  -O \
  -gnone \
  -warnings-as-errors \
  -module-name ReleaseGateFixture \
  "${TMP_DIR}/demangle-only.swift" \
  -o "${DEMANGLE_ONLY_APP}/Contents/Resources/Embedded/Nested/Helpers/DemangleOnlyHelper"
assert_failure_contains \
  "Swift demangled marker" \
  "after Swift symbol demangling" \
  bash "${TARGET_SCRIPT}" \
    --app-path "${DEMANGLE_ONLY_APP}" \
    --scan-release-binaries-only

forbidden_markers=(
  SKYBRIDGE_TESTING
  SKYBRIDGE_SMOKE_
  SKYBRIDGE_SMOKE_ROLE
  SKYBRIDGE_KEYCHAIN_IN_MEMORY
  UITEST_
  UITEST_LOGIN
  XCTestSessionIdentifier
  XCTestConfigurationFilePath
  XCTestBundlePath
  XCInjectBundleInto
  XCInjectBundle
  RemoteControlSmokeStatusWriter
  LocalCameraSmokeHarness
  MacOnlineIPadSmokeHarness
  RemoteControlNoticePanelProbeHarness
  RemoteDesktopSmokeStreamOverrides
  MacSmokeStatusFailClosedWriter
  SignedKEMRefreshSmokeStatusWriter
  SmokeStatusReporter
  SkyBridgeSmokeTraceWriter
  SmokeStatusFileAppender
)

marker_index=0
for marker in "${forbidden_markers[@]}"; do
  marker_index=$((marker_index + 1))
  bad_app="${TMP_DIR}/Bad-${marker_index}.app"
  bad_helper="${bad_app}/Contents/Resources/Embedded/Nested/Helpers/BadHelper"
  mkdir -p "$(dirname "${bad_helper}")"
  compile_marker_fixture "${marker}" "${bad_helper}"
  assert_failure_contains \
    "forbidden marker ${marker}" \
    "${marker}" \
    bash "${TARGET_SCRIPT}" \
      --app-path "${bad_app}" \
      --scan-release-binaries-only
done

echo "[test-macos-release-binary-surface] passed"
