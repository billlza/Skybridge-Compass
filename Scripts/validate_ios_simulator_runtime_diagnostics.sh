#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 <build-for-testing-log> <test-without-building-log>" >&2
  exit 2
fi

BUILD_LOG="$1"
TEST_LOG="$2"
ALLOWED_IOSURFACE_DIAGNOSTIC="IOSurfaceClientSetSurfaceNotify failed e00002c7"
DISALLOWED_COREAUDIO_PATTERN="AddInstanceForFactory: No factory registered|AggregateDevice.*couldn't get default output device"
# CoreSimulator 26.5 itself emits one WebCore/WebKit accessibility duplicate. It is the
# only duplicate-class diagnostic outside project ownership that this lane recognizes.
DUPLICATE_CLASS_PATTERN="Class .* is implemented in both"
ALLOWED_CORESIMULATOR_DUPLICATE_CLASS_PATTERN="Class UIAccessibilityLoaderWebShared is implemented in both .*WebCore\\.axbundle/WebCore .*WebKit\\.axbundle/WebKit"
DISALLOWED_PROJECT_DUPLICATE_CLASS_PATTERN="Class .* is implemented in both .*(Build/Products|PackageFrameworks|SkyBridgeCompass-iOS\\.app|SkyBridgeAppleRuntime\\.framework)"
TEST_SUITE_START="Test Suite 'All tests' started"

for log_file in "${BUILD_LOG}" "${TEST_LOG}"; do
  if [[ ! -f "${log_file}" ]]; then
    echo "[iOS simulator diagnostics] missing log: ${log_file}" >&2
    exit 2
  fi
done

for log_file in "${BUILD_LOG}" "${TEST_LOG}"; do
  if LC_ALL=C grep -En "${DISALLOWED_COREAUDIO_PATTERN}" "${log_file}" >&2; then
    echo "[iOS simulator diagnostics] project-triggered CoreAudio lifecycle diagnostic detected" >&2
    exit 1
  fi
  if LC_ALL=C grep -En "${DISALLOWED_PROJECT_DUPLICATE_CLASS_PATTERN}" "${log_file}" >&2; then
    echo "[iOS simulator diagnostics] duplicate runtime class implementation detected" >&2
    exit 1
  fi
done

duplicate_class_lines="$({ grep -Eh "${DUPLICATE_CLASS_PATTERN}" "${BUILD_LOG}" "${TEST_LOG}" || true; })"
if [[ -n "${duplicate_class_lines}" ]]; then
  unknown_duplicate_class_lines="$({
    printf '%s\n' "${duplicate_class_lines}" \
      | grep -Ev "${ALLOWED_CORESIMULATOR_DUPLICATE_CLASS_PATTERN}" || true
  })"
  if [[ -n "${unknown_duplicate_class_lines}" ]]; then
    printf '%s\n' "${unknown_duplicate_class_lines}" >&2
    echo "[iOS simulator diagnostics] unknown duplicate runtime class implementation detected" >&2
    exit 1
  fi

  allowed_duplicate_count="$({
    printf '%s\n' "${duplicate_class_lines}" \
      | grep -Ec "${ALLOWED_CORESIMULATOR_DUPLICATE_CLASS_PATTERN}" || true
  })"
  if [[ "${allowed_duplicate_count}" -ne 1 ]]; then
    printf '%s\n' "${duplicate_class_lines}" >&2
    echo "[iOS simulator diagnostics] allowed CoreSimulator duplicate-class diagnostic repeated ${allowed_duplicate_count} times" >&2
    exit 1
  fi
  echo "[iOS simulator diagnostics] classified one CoreSimulator-owned WebCore/WebKit accessibility duplicate"
else
  echo "[iOS simulator diagnostics] no duplicate runtime class diagnostics observed"
fi

if grep -Ein "IOSurface.*(warning|error|failed)" "${BUILD_LOG}" >&2; then
  echo "[iOS simulator diagnostics] IOSurface diagnostics are not allowed during build-for-testing" >&2
  exit 1
fi

iosurface_count="$(grep -Fc "IOSurface" "${TEST_LOG}" || true)"
allowed_count="$(grep -Fxc "${ALLOWED_IOSURFACE_DIAGNOSTIC}" "${TEST_LOG}" || true)"

if [[ "${iosurface_count}" -ne "${allowed_count}" ]]; then
  grep -Fn "IOSurface" "${TEST_LOG}" >&2 || true
  echo "[iOS simulator diagnostics] unknown IOSurface diagnostic detected" >&2
  exit 1
fi

if [[ "${allowed_count}" -gt 1 ]]; then
  grep -Fn "${ALLOWED_IOSURFACE_DIAGNOSTIC}" "${TEST_LOG}" >&2 || true
  echo "[iOS simulator diagnostics] allowed CoreSimulator diagnostic repeated ${allowed_count} times" >&2
  exit 1
fi

if [[ "${allowed_count}" -eq 1 ]]; then
  diagnostic_line="$(grep -Fn "${ALLOWED_IOSURFACE_DIAGNOSTIC}" "${TEST_LOG}" | head -n 1 | cut -d: -f1)"
  suite_line="$(grep -Fn "${TEST_SUITE_START}" "${TEST_LOG}" | head -n 1 | cut -d: -f1 || true)"
  if [[ -z "${suite_line}" || "${diagnostic_line}" -ge "${suite_line}" ]]; then
    echo "[iOS simulator diagnostics] IOSurface diagnostic was not confined to pre-test CoreSimulator startup" >&2
    exit 1
  fi
  echo "[iOS simulator diagnostics] classified one pre-test CoreSimulator-only diagnostic: ${ALLOWED_IOSURFACE_DIAGNOSTIC}"
else
  echo "[iOS simulator diagnostics] no IOSurface diagnostics observed"
fi
