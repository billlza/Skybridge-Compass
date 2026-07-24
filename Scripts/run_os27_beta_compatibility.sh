#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS27_COMPATIBILITY_MODE="validate"
OS27_DIAG_XCODE27_READY=0
OS27_DIAG_SDK27_READY=0
OS27_DIAG_DEVICE_READY=0
OS27_DIAG_XCODE27_BUNDLE_READY=0
OS27_SWIFTPM_SCRATCH_PATH=""
OS27_CLEAN_LOG_FILES=()
OS27_LAST_CLEAN_LOG_FILE=""
OS27_IOS_XCODEBUILD_APPLE_PQC_SETTINGS=()

OS27_COMPAT_REPORT_SCHEMA_VERSION=2
OS27_COMPAT_REPORT_PATH="${SKYBRIDGE_OS27_COMPAT_REPORT_PATH:-${ROOT_DIR}/Artifacts/os27/compatibility-report.json}"
OS27_REPORT_MODE="${OS27_COMPATIBILITY_MODE}"
OS27_REPORT_STATUS="not_started"
OS27_REPORT_COMPATIBILITY="not_validated"
OS27_REPORT_RELEASE_ELIGIBLE="0"
OS27_REPORT_FULL_VALIDATION="0"
OS27_REPORT_FULL_VALIDATION_ATTEMPTED="0"
OS27_REPORT_FULL_VALIDATION_PASSED="0"
OS27_REPORT_COVERAGE="not_started"
OS27_REPORT_EXIT_CODE="0"
OS27_REPORT_XCODE_VERSION="unknown"
OS27_REPORT_XCODEBUILD_BUILD="unknown"
OS27_REPORT_SWIFT_VERSION="unknown"
OS27_REPORT_MACOS_SDK="unknown"
OS27_REPORT_IPHONEOS_SDK="unknown"
OS27_REPORT_IPHONESIMULATOR_SDK="unknown"
OS27_REPORT_XCODE_BUNDLE_IDENTIFIER="unknown"
OS27_REPORT_XCODE_BUNDLE_VERSION="unknown"
OS27_REPORT_XCODE_BUNDLE_BUILD="unknown"
OS27_REPORT_XCODE_BUNDLE_READY="0"
OS27_REPORT_XCODE_BUILD_CONSISTENCY="not_checked"
OS27_REPORT_CODESIGN_METADATA_STATUS="not_run"
OS27_REPORT_CODESIGN_VERIFY_STATUS="not_run"
OS27_REPORT_QUARANTINE_STATUS="not_run"
OS27_REPORT_PROVENANCE_STATUS="not_run"
OS27_REPORT_GATEKEEPER_ASSESSMENTS_STATUS="not_run"
OS27_REPORT_GATEKEEPER_BUNDLE_STATUS="not_run"
OS27_REPORT_XCODE_BUNDLE_EARLY_MTIME_FILE_COUNT="0"
OS27_REPORT_XCODE_BUNDLE_FUTURE_MTIME_FILE_COUNT="0"
OS27_REPORT_XCODE_BUNDLE_EARLIEST_MTIME_UTC="unknown"
OS27_REPORT_XCODE_BUNDLE_LATEST_MTIME_UTC="unknown"
OS27_REPORT_XCODE27_READY="0"
OS27_REPORT_SDK27_READY="0"
OS27_REPORT_DEVICE_READY="0"
OS27_REPORT_PQC_PROBE_MACOSX="not_run"
OS27_REPORT_PQC_PROBE_IPHONEOS="not_run"
OS27_REPORT_PQC_PROBE_IPHONESIMULATOR="not_run"
OS27_REPORT_PQC_PROBE_MACOSX_MODE="not_run"
OS27_REPORT_PQC_PROBE_IPHONEOS_MODE="not_run"
OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_MODE="not_run"
OS27_REPORT_PQC_PROBE_MACOSX_SDK_NAME="macosx"
OS27_REPORT_PQC_PROBE_IPHONEOS_SDK_NAME="iphoneos"
OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SDK_NAME="iphonesimulator"
OS27_REPORT_PQC_PROBE_MACOSX_SDK_VERSION="unknown"
OS27_REPORT_PQC_PROBE_IPHONEOS_SDK_VERSION="unknown"
OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SDK_VERSION="unknown"
OS27_REPORT_PQC_PROBE_MACOSX_SWIFT_TARGET="unknown"
OS27_REPORT_PQC_PROBE_IPHONEOS_SWIFT_TARGET="unknown"
OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SWIFT_TARGET="unknown"
OS27_REPORT_PQC_PROBE_MACOSX_SECURE_ENCLAVE="1"
OS27_REPORT_PQC_PROBE_IPHONEOS_SECURE_ENCLAVE="0"
OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SECURE_ENCLAVE="0"
OS27_APPLE_PQC_SYMBOL_SET="cryptokit-pqc-os27-v1"
OS27_REPORT_PQC_PROBE_MACOSX_SYMBOL_SET="${OS27_APPLE_PQC_SYMBOL_SET}"
OS27_REPORT_PQC_PROBE_IPHONEOS_SYMBOL_SET="${OS27_APPLE_PQC_SYMBOL_SET}"
OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SYMBOL_SET="${OS27_APPLE_PQC_SYMBOL_SET}"
OS27_REPORT_PQC_PROBE_MACOSX_ERROR_SUMMARY=""
OS27_REPORT_PQC_PROBE_IPHONEOS_ERROR_SUMMARY=""
OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_ERROR_SUMMARY=""
OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX="not_run"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS="not_run"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR="not_run"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_MODE="not_run"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_MODE="not_run"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_MODE="not_run"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SDK_NAME="macosx"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SDK_NAME="iphoneos"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SDK_NAME="iphonesimulator"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SDK_VERSION="unknown"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SDK_VERSION="unknown"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SDK_VERSION="unknown"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SWIFT_TARGET="unknown"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SWIFT_TARGET="unknown"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SWIFT_TARGET="unknown"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SYMBOL_SET="network-tls-pqc-v1"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SYMBOL_SET="network-tls-pqc-v1"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SYMBOL_SET="network-tls-pqc-v1"
OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_ERROR_SUMMARY=""
OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_ERROR_SUMMARY=""
OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_ERROR_SUMMARY=""
OS27_REPORT_IOS_STATIC_CONFIG_STATUS="not_run"
OS27_REPORT_SWIFTPM_APP_BUILD_STATUS="not_run"
OS27_REPORT_SWIFTPM_APP_MARKER_STATUS="not_run"
OS27_REPORT_SWIFTPM_FILTERED_TEST_STATUS="not_run"
OS27_REPORT_SWIFTPM_FILTERED_TEST_FILTER=""
OS27_REPORT_GENERIC_IOS_BUILD_STATUS="not_run"
OS27_REPORT_IOS_SIMULATOR_BUILD_STATUS="not_run"
OS27_REPORT_REQUIRED_IOS_DEVICE_TEST_STATUS="not_run"
OS27_REQUIRED_IOS_DEVICE_PQC_RUNTIME_TEST='SkyBridgeCompassiOSTests/ApplePQCProviderRuntimeSelfTestTests/testApplePQCAndXWingProbesGenerateKeysOnAvailableRuntime'
OS27_REPORT_REQUIRED_IOS_DEVICE_TEST="${OS27_REQUIRED_IOS_DEVICE_PQC_RUNTIME_TEST}"
OS27_REPORT_ADDITIONAL_IOS_DEVICE_TEST_STATUS="not_run"
OS27_REPORT_ADDITIONAL_IOS_DEVICE_TEST=""
OS27_REPORT_SOURCE_CONTRACTS_STATUS="not_run"
OS27_REPORT_SKIPPED_IOS_BUILD_GATES=""

export OS27_COMPAT_REPORT_SCHEMA_VERSION OS27_COMPAT_REPORT_PATH
export OS27_REPORT_MODE OS27_REPORT_STATUS OS27_REPORT_COMPATIBILITY
export OS27_REPORT_RELEASE_ELIGIBLE OS27_REPORT_FULL_VALIDATION
export OS27_REPORT_FULL_VALIDATION_ATTEMPTED OS27_REPORT_FULL_VALIDATION_PASSED
export OS27_REPORT_COVERAGE OS27_REPORT_EXIT_CODE
export OS27_REPORT_XCODE_VERSION OS27_REPORT_XCODEBUILD_BUILD OS27_REPORT_SWIFT_VERSION
export OS27_REPORT_MACOS_SDK OS27_REPORT_IPHONEOS_SDK OS27_REPORT_IPHONESIMULATOR_SDK
export OS27_REPORT_XCODE_BUNDLE_IDENTIFIER OS27_REPORT_XCODE_BUNDLE_VERSION OS27_REPORT_XCODE_BUNDLE_BUILD
export OS27_REPORT_XCODE_BUNDLE_READY OS27_REPORT_XCODE_BUILD_CONSISTENCY
export OS27_REPORT_CODESIGN_METADATA_STATUS OS27_REPORT_CODESIGN_VERIFY_STATUS
export OS27_REPORT_QUARANTINE_STATUS OS27_REPORT_PROVENANCE_STATUS
export OS27_REPORT_GATEKEEPER_ASSESSMENTS_STATUS OS27_REPORT_GATEKEEPER_BUNDLE_STATUS
export OS27_REPORT_XCODE_BUNDLE_EARLY_MTIME_FILE_COUNT OS27_REPORT_XCODE_BUNDLE_FUTURE_MTIME_FILE_COUNT
export OS27_REPORT_XCODE_BUNDLE_EARLIEST_MTIME_UTC OS27_REPORT_XCODE_BUNDLE_LATEST_MTIME_UTC
export OS27_REPORT_XCODE27_READY OS27_REPORT_SDK27_READY OS27_REPORT_DEVICE_READY
export OS27_REPORT_PQC_PROBE_MACOSX OS27_REPORT_PQC_PROBE_IPHONEOS OS27_REPORT_PQC_PROBE_IPHONESIMULATOR
export OS27_REPORT_PQC_PROBE_MACOSX_MODE OS27_REPORT_PQC_PROBE_IPHONEOS_MODE OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_MODE
export OS27_REPORT_PQC_PROBE_MACOSX_SDK_NAME OS27_REPORT_PQC_PROBE_IPHONEOS_SDK_NAME OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SDK_NAME
export OS27_REPORT_PQC_PROBE_MACOSX_SDK_VERSION OS27_REPORT_PQC_PROBE_IPHONEOS_SDK_VERSION OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SDK_VERSION
export OS27_REPORT_PQC_PROBE_MACOSX_SWIFT_TARGET OS27_REPORT_PQC_PROBE_IPHONEOS_SWIFT_TARGET OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SWIFT_TARGET
export OS27_REPORT_PQC_PROBE_MACOSX_SECURE_ENCLAVE OS27_REPORT_PQC_PROBE_IPHONEOS_SECURE_ENCLAVE OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SECURE_ENCLAVE
export OS27_REPORT_PQC_PROBE_MACOSX_SYMBOL_SET OS27_REPORT_PQC_PROBE_IPHONEOS_SYMBOL_SET OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SYMBOL_SET
export OS27_REPORT_PQC_PROBE_MACOSX_ERROR_SUMMARY OS27_REPORT_PQC_PROBE_IPHONEOS_ERROR_SUMMARY OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_ERROR_SUMMARY
export OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR
export OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_MODE OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_MODE OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_MODE
export OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SDK_NAME OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SDK_NAME OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SDK_NAME
export OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SDK_VERSION OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SDK_VERSION OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SDK_VERSION
export OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SWIFT_TARGET OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SWIFT_TARGET OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SWIFT_TARGET
export OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SYMBOL_SET OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SYMBOL_SET OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SYMBOL_SET
export OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_ERROR_SUMMARY OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_ERROR_SUMMARY OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_ERROR_SUMMARY
export OS27_REPORT_IOS_STATIC_CONFIG_STATUS OS27_REPORT_SWIFTPM_APP_BUILD_STATUS
export OS27_REPORT_SWIFTPM_APP_MARKER_STATUS OS27_REPORT_SWIFTPM_FILTERED_TEST_STATUS
export OS27_REPORT_SWIFTPM_FILTERED_TEST_FILTER OS27_REPORT_GENERIC_IOS_BUILD_STATUS
export OS27_REPORT_IOS_SIMULATOR_BUILD_STATUS OS27_REPORT_REQUIRED_IOS_DEVICE_TEST_STATUS
export OS27_REPORT_REQUIRED_IOS_DEVICE_TEST OS27_REPORT_ADDITIONAL_IOS_DEVICE_TEST_STATUS
export OS27_REPORT_ADDITIONAL_IOS_DEVICE_TEST OS27_REPORT_SOURCE_CONTRACTS_STATUS
export OS27_REPORT_SKIPPED_IOS_BUILD_GATES
export OS27_APPLE_PQC_SYMBOL_SET

OS27_XCODE27_DEVELOPER_DIR_CANDIDATES=(
  "/Applications/Xcode-beta.app/Contents/Developer"
  "/Applications/Xcode_27_beta.app/Contents/Developer"
  "/Applications/Xcode_27.app/Contents/Developer"
)

cleanup_os27_beta_compatibility() {
  if [[ -n "${OS27_SWIFTPM_SCRATCH_PATH}" && -d "${OS27_SWIFTPM_SCRATCH_PATH}" ]]; then
    rm -rf "${OS27_SWIFTPM_SCRATCH_PATH}"
  fi
  if [[ "${SKYBRIDGE_OS27_KEEP_RAW_LOGS:-0}" != "1" && "${#OS27_CLEAN_LOG_FILES[@]}" -gt 0 ]]; then
    rm -f "${OS27_CLEAN_LOG_FILES[@]}" 2>/dev/null || true
  fi
}

make_clean_log_file() {
  local prefix="$1"

  OS27_LAST_CLEAN_LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/${prefix}.XXXXXX")"
  OS27_CLEAN_LOG_FILES+=("${OS27_LAST_CLEAN_LOG_FILE}")
}

write_os27_compatibility_report() {
  local exit_code="$1"
  local report_path="${OS27_COMPAT_REPORT_PATH}"
  local report_dir
  local report_error_log

  [[ -n "${report_path}" ]] || return 0
  report_dir="$(dirname "${report_path}")"
  report_error_log="$(mktemp "${TMPDIR:-/tmp}/skybridge-os27-report-write.XXXXXX")" || return 1

  if ! mkdir -p "${report_dir}" 2>"${report_error_log}"; then
    echo "[os27-beta-compat] ERROR: compatibility report writer failed: $(sanitize_log_value "$(cat "${report_error_log}")")" >&2
    rm -f "${report_error_log}"
    return 1
  fi

  OS27_REPORT_EXIT_CODE="${exit_code}"
  export OS27_REPORT_EXIT_CODE

  if ! python3 - "${report_path}" 2>"${report_error_log}" <<'PY'
import datetime as dt
import json
import os
import sys

report_path = sys.argv[1]

def value(name, default="unknown"):
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw

def bool_value(name):
    return value(name, "0") in {"1", "true", "TRUE", "yes", "YES"}

def int_value(name):
    try:
        return int(value(name, "0"))
    except ValueError:
        return 0

def list_value(name):
    raw = value(name, "")
    if not raw:
        return []
    return [item for item in raw.split() if item]

payload = {
    "schema_version": int_value("OS27_COMPAT_REPORT_SCHEMA_VERSION"),
    "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    "mode": value("OS27_REPORT_MODE"),
    "status": value("OS27_REPORT_STATUS"),
    "compatibility": value("OS27_REPORT_COMPATIBILITY"),
    "release_eligible": bool_value("OS27_REPORT_RELEASE_ELIGIBLE"),
    "full_validation": bool_value("OS27_REPORT_FULL_VALIDATION"),
    "full_validation_attempted": bool_value("OS27_REPORT_FULL_VALIDATION_ATTEMPTED"),
    "full_validation_passed": bool_value("OS27_REPORT_FULL_VALIDATION_PASSED"),
    "coverage": value("OS27_REPORT_COVERAGE"),
    "exit_code": int_value("OS27_REPORT_EXIT_CODE"),
    "toolchain": {
        "xcode_version": value("OS27_REPORT_XCODE_VERSION"),
        "xcodebuild_build": value("OS27_REPORT_XCODEBUILD_BUILD"),
        "swift_version": value("OS27_REPORT_SWIFT_VERSION"),
        "sdk_versions": {
            "macosx": value("OS27_REPORT_MACOS_SDK"),
            "iphoneos": value("OS27_REPORT_IPHONEOS_SDK"),
            "iphonesimulator": value("OS27_REPORT_IPHONESIMULATOR_SDK"),
        },
        "xcode27_ready": bool_value("OS27_REPORT_XCODE27_READY"),
        "sdk27_ready": bool_value("OS27_REPORT_SDK27_READY"),
    },
    "xcode_beta_bundle": {
        "identifier": value("OS27_REPORT_XCODE_BUNDLE_IDENTIFIER"),
        "short_version": value("OS27_REPORT_XCODE_BUNDLE_VERSION"),
        "bundle_build": value("OS27_REPORT_XCODE_BUNDLE_BUILD"),
        "ready": bool_value("OS27_REPORT_XCODE_BUNDLE_READY"),
        "build_consistency": value("OS27_REPORT_XCODE_BUILD_CONSISTENCY"),
        "codesign_metadata": value("OS27_REPORT_CODESIGN_METADATA_STATUS"),
        "codesign_verify": value("OS27_REPORT_CODESIGN_VERIFY_STATUS"),
        "quarantine": value("OS27_REPORT_QUARANTINE_STATUS"),
        "provenance_xattr": value("OS27_REPORT_PROVENANCE_STATUS"),
        "gatekeeper_assessments": value("OS27_REPORT_GATEKEEPER_ASSESSMENTS_STATUS"),
        "gatekeeper_bundle": value("OS27_REPORT_GATEKEEPER_BUNDLE_STATUS"),
        "timestamp_anomalies": {
            "early_mtime_file_count": int_value("OS27_REPORT_XCODE_BUNDLE_EARLY_MTIME_FILE_COUNT"),
            "future_mtime_file_count": int_value("OS27_REPORT_XCODE_BUNDLE_FUTURE_MTIME_FILE_COUNT"),
            "earliest_mtime_utc": value("OS27_REPORT_XCODE_BUNDLE_EARLIEST_MTIME_UTC"),
            "latest_mtime_utc": value("OS27_REPORT_XCODE_BUNDLE_LATEST_MTIME_UTC"),
            "action": "record_only",
        },
    },
    "device_readiness": {
        "required_ipados27_device_ready": bool_value("OS27_REPORT_DEVICE_READY"),
    },
    "pqc_symbol_probes": {
        "macosx": value("OS27_REPORT_PQC_PROBE_MACOSX"),
        "iphoneos": value("OS27_REPORT_PQC_PROBE_IPHONEOS"),
        "iphonesimulator": value("OS27_REPORT_PQC_PROBE_IPHONESIMULATOR"),
    },
    "pqc_symbol_probe_details": {
        "macosx": {
            "status": value("OS27_REPORT_PQC_PROBE_MACOSX"),
            "mode": value("OS27_REPORT_PQC_PROBE_MACOSX_MODE"),
            "sdk_name": value("OS27_REPORT_PQC_PROBE_MACOSX_SDK_NAME"),
            "sdk_version": value("OS27_REPORT_PQC_PROBE_MACOSX_SDK_VERSION"),
            "swift_target": value("OS27_REPORT_PQC_PROBE_MACOSX_SWIFT_TARGET"),
            "secure_enclave_symbols_included": bool_value("OS27_REPORT_PQC_PROBE_MACOSX_SECURE_ENCLAVE"),
            "symbol_set": value("OS27_REPORT_PQC_PROBE_MACOSX_SYMBOL_SET"),
            "error_summary": value("OS27_REPORT_PQC_PROBE_MACOSX_ERROR_SUMMARY", ""),
            "proof_scope": "cryptokit_compile_time_symbol_surface_only",
            "affects_session_status": False,
            "affects_network_tls_pqc": False,
            "release_eligible": False,
        },
        "iphoneos": {
            "status": value("OS27_REPORT_PQC_PROBE_IPHONEOS"),
            "mode": value("OS27_REPORT_PQC_PROBE_IPHONEOS_MODE"),
            "sdk_name": value("OS27_REPORT_PQC_PROBE_IPHONEOS_SDK_NAME"),
            "sdk_version": value("OS27_REPORT_PQC_PROBE_IPHONEOS_SDK_VERSION"),
            "swift_target": value("OS27_REPORT_PQC_PROBE_IPHONEOS_SWIFT_TARGET"),
            "secure_enclave_symbols_included": bool_value("OS27_REPORT_PQC_PROBE_IPHONEOS_SECURE_ENCLAVE"),
            "symbol_set": value("OS27_REPORT_PQC_PROBE_IPHONEOS_SYMBOL_SET"),
            "error_summary": value("OS27_REPORT_PQC_PROBE_IPHONEOS_ERROR_SUMMARY", ""),
            "proof_scope": "cryptokit_compile_time_symbol_surface_only",
            "affects_session_status": False,
            "affects_network_tls_pqc": False,
            "release_eligible": False,
        },
        "iphonesimulator": {
            "status": value("OS27_REPORT_PQC_PROBE_IPHONESIMULATOR"),
            "mode": value("OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_MODE"),
            "sdk_name": value("OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SDK_NAME"),
            "sdk_version": value("OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SDK_VERSION"),
            "swift_target": value("OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SWIFT_TARGET"),
            "secure_enclave_symbols_included": bool_value("OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SECURE_ENCLAVE"),
            "symbol_set": value("OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SYMBOL_SET"),
            "error_summary": value("OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_ERROR_SUMMARY", ""),
            "proof_scope": "cryptokit_compile_time_symbol_surface_only",
            "affects_session_status": False,
            "affects_network_tls_pqc": False,
            "release_eligible": False,
        },
    },
    "network_tls_pqc_symbol_probes": {
        "macosx": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX"),
        "iphoneos": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS"),
        "iphonesimulator": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR"),
    },
    "network_tls_pqc_symbol_probe_details": {
        "macosx": {
            "status": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX"),
            "mode": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_MODE"),
            "sdk_name": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SDK_NAME"),
            "sdk_version": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SDK_VERSION"),
            "swift_target": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SWIFT_TARGET"),
            "symbol_set": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SYMBOL_SET"),
            "error_summary": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_ERROR_SUMMARY", ""),
            "proof_scope": "transport_sdk_public_api_surface_only",
            "server_support_required": True,
            "session_negotiated": False,
            "affects_session_status": False,
            "affects_crypto_suite_selection": False,
            "release_eligible": False,
        },
        "iphoneos": {
            "status": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS"),
            "mode": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_MODE"),
            "sdk_name": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SDK_NAME"),
            "sdk_version": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SDK_VERSION"),
            "swift_target": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SWIFT_TARGET"),
            "symbol_set": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SYMBOL_SET"),
            "error_summary": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_ERROR_SUMMARY", ""),
            "proof_scope": "transport_sdk_public_api_surface_only",
            "server_support_required": True,
            "session_negotiated": False,
            "affects_session_status": False,
            "affects_crypto_suite_selection": False,
            "release_eligible": False,
        },
        "iphonesimulator": {
            "status": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR"),
            "mode": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_MODE"),
            "sdk_name": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SDK_NAME"),
            "sdk_version": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SDK_VERSION"),
            "swift_target": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SWIFT_TARGET"),
            "symbol_set": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SYMBOL_SET"),
            "error_summary": value("OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_ERROR_SUMMARY", ""),
            "proof_scope": "transport_sdk_public_api_surface_only",
            "server_support_required": True,
            "session_negotiated": False,
            "affects_session_status": False,
            "affects_crypto_suite_selection": False,
            "release_eligible": False,
        },
    },
    "apple_quantum_secure_runtime_proof": {
        "required_device_test_identifier": value("OS27_REPORT_REQUIRED_IOS_DEVICE_TEST", ""),
        "status": value("OS27_REPORT_REQUIRED_IOS_DEVICE_TEST_STATUS"),
        "requires_ipados27_beta_device": True,
        "proves": [
            "ApplePQC ML-KEM/ML-DSA runtime",
            "AppleXWing HPKE runtime",
        ],
        "proof_scope": "apple_cryptokit_runtime_self_test_only",
        "session_negotiated": False,
        "affects_network_tls_pqc": False,
        "release_eligible": False,
    },
    "gates": {
        "source_contracts": value("OS27_REPORT_SOURCE_CONTRACTS_STATUS"),
        "ios_static_configuration": value("OS27_REPORT_IOS_STATIC_CONFIG_STATUS"),
        "swiftpm_app_build": value("OS27_REPORT_SWIFTPM_APP_BUILD_STATUS"),
        "swiftpm_app_apple_pqc_marker": value("OS27_REPORT_SWIFTPM_APP_MARKER_STATUS"),
        "swiftpm_filtered_tests": value("OS27_REPORT_SWIFTPM_FILTERED_TEST_STATUS"),
        "swiftpm_filtered_test_filter": value("OS27_REPORT_SWIFTPM_FILTERED_TEST_FILTER", ""),
        "generic_ios_build": value("OS27_REPORT_GENERIC_IOS_BUILD_STATUS"),
        "ios_simulator_build": value("OS27_REPORT_IOS_SIMULATOR_BUILD_STATUS"),
        "required_ios_device_test": value("OS27_REPORT_REQUIRED_IOS_DEVICE_TEST_STATUS"),
        "required_ios_device_test_identifier": value("OS27_REPORT_REQUIRED_IOS_DEVICE_TEST", ""),
        "additional_ios_device_test": value("OS27_REPORT_ADDITIONAL_IOS_DEVICE_TEST_STATUS"),
        "additional_ios_device_test_identifier": value("OS27_REPORT_ADDITIONAL_IOS_DEVICE_TEST", ""),
        "skipped_ios_build_gates": list_value("OS27_REPORT_SKIPPED_IOS_BUILD_GATES"),
    },
}

tmp_path = f"{report_path}.tmp.{os.getpid()}"
with open(tmp_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=True, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(tmp_path, report_path)
PY
  then
    echo "[os27-beta-compat] ERROR: compatibility report writer failed: $(sanitize_log_value "$(cat "${report_error_log}")")" >&2
    rm -f "${report_error_log}"
    return 1
  fi

  rm -f "${report_error_log}"
}

finalize_os27_beta_compatibility() {
  local status=$?
  local report_status=0

  set +e
  write_os27_compatibility_report "${status}"
  report_status=$?
  cleanup_os27_beta_compatibility
  set -e

  if [[ "${report_status}" -ne 0 ]]; then
    echo "[os27-beta-compat] ERROR: failed to write compatibility report: $(sanitize_log_value "${OS27_COMPAT_REPORT_PATH}")" >&2
    if [[ "${status}" -eq 0 ]]; then
      exit "${report_status}"
    fi
  fi

  exit "${status}"
}
trap finalize_os27_beta_compatibility EXIT

ensure_swiftpm_scratch_path() {
  if [[ -z "${OS27_SWIFTPM_SCRATCH_PATH}" ]]; then
    OS27_SWIFTPM_SCRATCH_PATH="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-os27-swiftpm-scratch.XXXXXX")"
  fi
}

swiftpm_scratch_path() {
  ensure_swiftpm_scratch_path
  printf '%s\n' "${OS27_SWIFTPM_SCRATCH_PATH}"
}

prime_swiftpm_scratch_path() {
  local scratch_path="$1"
  local cache_name
  local source_path
  local target_path

  for cache_name in repositories checkouts artifacts; do
    source_path="${ROOT_DIR}/.build/${cache_name}"
    target_path="${scratch_path}/${cache_name}"
    if [[ -d "${source_path}" && ! -e "${target_path}" ]]; then
      cp -R "${source_path}" "${target_path}"
      echo "[os27-beta-compat] SwiftPM scratch cache primed: ${cache_name}"
    fi
  done
}

configure_ios_xcodebuild_apple_pqc_gate_after_probe() {
  OS27_IOS_XCODEBUILD_APPLE_PQC_SETTINGS=(
    "SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK"
  )
}

clean_log_diagnostic_pattern() {
  printf '%s\n' '(^|[^[:alnum:]_])([Ww][Aa][Rr][Nn][Ii][Nn][Gg]|[Ee][Rr][Rr][Oo][Rr]):'
}

usage() {
  cat <<'EOF'
Usage:
  Scripts/run_os27_beta_compatibility.sh
  Scripts/run_os27_beta_compatibility.sh --diagnose-environment
  Scripts/run_os27_beta_compatibility.sh --verify-source-contracts

Default mode runs the full fail-closed OS 27 validation lane. Diagnostic mode is
read-only: it reports Xcode/SDK/device readiness and never runs builds, tests,
Apple PQC probes, or device runtime validation.
Source-contract mode runs repository guardrail tests that do not require Xcode 27
and still reports compatibility=not_validated.

All modes write a machine-readable compatibility report to
Artifacts/os27/compatibility-report.json by default. Override with
SKYBRIDGE_OS27_COMPAT_REPORT_PATH. The report is beta compatibility evidence only
and never changes release eligibility or macOS stable update manifests.
EOF
}

fail() {
  OS27_REPORT_STATUS="failed"
  echo "[os27-beta-compat] ERROR: $1" >&2
  exit 1
}

validate_os27_apple_pqc_symbol_set_override() {
  if [[ -n "${SKYBRIDGE_OS27_APPLE_PQC_SYMBOL_SET:-}" && "${SKYBRIDGE_OS27_APPLE_PQC_SYMBOL_SET}" != "${OS27_APPLE_PQC_SYMBOL_SET}" ]]; then
    fail "OS27 compatibility reports must use ${OS27_APPLE_PQC_SYMBOL_SET}; SKYBRIDGE_OS27_APPLE_PQC_SYMBOL_SET=${SKYBRIDGE_OS27_APPLE_PQC_SYMBOL_SET} is not valid for the beta lane."
  fi
}

usage_error() {
  echo "[os27-beta-compat] ERROR: $1" >&2
  usage >&2
  exit 64
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --diagnose-environment | --diagnose | --preflight)
        OS27_COMPATIBILITY_MODE="diagnose"
        ;;
      --verify-source-contracts)
        OS27_COMPATIBILITY_MODE="source-contracts"
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage_error "unknown argument: $1"
        ;;
    esac
    shift
  done
}

flatten_output() {
  local value="$1"
  value="${value//$'\n'/ }"
  printf '%s\n' "${value}"
}

sanitize_log_value() {
  local value="$1"
  value="$(flatten_output "${value}")"
  value="$(sed -E 's#/var/folders/[^[:space:]]+#<tmp>#g; s#/tmp/[^[:space:]]+#<tmp>#g; s#<tmp>/[^[:space:]]+#<tmp>#g' <<<"${value}")"
  value="$(sed -E 's#/Applications/([^/[:space:]]+\.app)/Contents/Developer#<applications>/\1/Contents/Developer#g; s#/Applications/([^/[:space:]]+\.app)#<applications>/\1#g' <<<"${value}")"
  value="${value//${ROOT_DIR}/<repo>}"
  if [[ -n "${HOME:-}" ]]; then
    value="${value//${HOME}/<home>}"
  fi
  if [[ -n "${TMPDIR:-}" ]]; then
    value="${value//${TMPDIR}/<tmp>}"
  fi
  value="$(sed -E 's#<tmp>/[^[:space:]]+#<tmp>#g' <<<"${value}")"
  value="$(sed -E 's/^ //; s/ $//' <<<"${value}")"
  printf '%s\n' "${value}"
}

sanitize_report_error_summary() {
  local value="$1"
  value="$(sanitize_log_value "${value}")"
  printf '%.240s\n' "${value}"
}

sanitize_log_stream() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    sanitize_log_value "${line}"
  done
}

record_pqc_symbol_probe_result() {
  local sdk_name="$1"
  local status="$2"
  local mode="${SKYBRIDGE_PQC_PROBE_MODE:-not_run}"
  local probed_sdk_name="${SKYBRIDGE_PQC_SDK_NAME:-${sdk_name}}"
  local sdk_version="${SKYBRIDGE_PQC_SDK_VER:-unknown}"
  local swift_target="${SKYBRIDGE_PQC_SWIFT_TARGET:-unknown}"
  local secure_enclave="${SKYBRIDGE_PQC_INCLUDED_SECURE_ENCLAVE:-0}"
  local symbol_set="${OS27_APPLE_PQC_SYMBOL_SET:-cryptokit-pqc-os27-v1}"
  local error_summary=""

  if [[ "${status}" == "running" || "${status}" == "not_run" ]]; then
    mode="not_run"
    sdk_version="unknown"
    swift_target="unknown"
    if [[ "${sdk_name}" == "macosx" || "${sdk_name}" == "iphoneos" ]]; then
      secure_enclave="1"
    else
      secure_enclave="0"
    fi
  elif [[ "${status}" == "failed" || "${status}" == "unavailable" ]]; then
    error_summary="$(sanitize_report_error_summary "${SKYBRIDGE_PQC_PROBE_ERROR:-unknown}")"
  fi

  case "${sdk_name}" in
    macosx)
      OS27_REPORT_PQC_PROBE_MACOSX="${status}"
      OS27_REPORT_PQC_PROBE_MACOSX_MODE="${mode}"
      OS27_REPORT_PQC_PROBE_MACOSX_SDK_NAME="${probed_sdk_name}"
      OS27_REPORT_PQC_PROBE_MACOSX_SDK_VERSION="${sdk_version}"
      OS27_REPORT_PQC_PROBE_MACOSX_SWIFT_TARGET="${swift_target}"
      OS27_REPORT_PQC_PROBE_MACOSX_SECURE_ENCLAVE="${secure_enclave}"
      OS27_REPORT_PQC_PROBE_MACOSX_SYMBOL_SET="${symbol_set}"
      OS27_REPORT_PQC_PROBE_MACOSX_ERROR_SUMMARY="${error_summary}"
      ;;
    iphoneos)
      OS27_REPORT_PQC_PROBE_IPHONEOS="${status}"
      OS27_REPORT_PQC_PROBE_IPHONEOS_MODE="${mode}"
      OS27_REPORT_PQC_PROBE_IPHONEOS_SDK_NAME="${probed_sdk_name}"
      OS27_REPORT_PQC_PROBE_IPHONEOS_SDK_VERSION="${sdk_version}"
      OS27_REPORT_PQC_PROBE_IPHONEOS_SWIFT_TARGET="${swift_target}"
      OS27_REPORT_PQC_PROBE_IPHONEOS_SECURE_ENCLAVE="${secure_enclave}"
      OS27_REPORT_PQC_PROBE_IPHONEOS_SYMBOL_SET="${symbol_set}"
      OS27_REPORT_PQC_PROBE_IPHONEOS_ERROR_SUMMARY="${error_summary}"
      ;;
    iphonesimulator)
      OS27_REPORT_PQC_PROBE_IPHONESIMULATOR="${status}"
      OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_MODE="${mode}"
      OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SDK_NAME="${probed_sdk_name}"
      OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SDK_VERSION="${sdk_version}"
      OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SWIFT_TARGET="${swift_target}"
      OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SECURE_ENCLAVE="${secure_enclave}"
      OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_SYMBOL_SET="${symbol_set}"
      OS27_REPORT_PQC_PROBE_IPHONESIMULATOR_ERROR_SUMMARY="${error_summary}"
      ;;
    *)
      fail "unknown Apple PQC probe SDK: ${sdk_name}"
      ;;
  esac
}

record_network_tls_pqc_symbol_probe_result() {
  local sdk_name="$1"
  local status="$2"
  local mode="${SKYBRIDGE_NETWORK_TLS_PQC_PROBE_MODE:-not_run}"
  local probed_sdk_name="${SKYBRIDGE_NETWORK_TLS_PQC_SDK_NAME:-${sdk_name}}"
  local sdk_version="${SKYBRIDGE_NETWORK_TLS_PQC_SDK_VER:-unknown}"
  local swift_target="${SKYBRIDGE_NETWORK_TLS_PQC_SWIFT_TARGET:-unknown}"
  local symbol_set="${SKYBRIDGE_NETWORK_TLS_PQC_SYMBOL_SET:-network-tls-pqc-v1}"
  local error_summary=""

  if [[ "${status}" == "running" || "${status}" == "not_run" ]]; then
    mode="not_run"
    sdk_version="unknown"
    swift_target="unknown"
  elif [[ "${status}" == "failed" || "${status}" == "unavailable" ]]; then
    error_summary="$(sanitize_report_error_summary "${SKYBRIDGE_NETWORK_TLS_PQC_PROBE_ERROR:-unknown}")"
  fi

  case "${sdk_name}" in
    macosx)
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX="${status}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_MODE="${mode}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SDK_NAME="${probed_sdk_name}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SDK_VERSION="${sdk_version}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SWIFT_TARGET="${swift_target}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_SYMBOL_SET="${symbol_set}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_MACOSX_ERROR_SUMMARY="${error_summary}"
      ;;
    iphoneos)
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS="${status}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_MODE="${mode}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SDK_NAME="${probed_sdk_name}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SDK_VERSION="${sdk_version}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SWIFT_TARGET="${swift_target}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_SYMBOL_SET="${symbol_set}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONEOS_ERROR_SUMMARY="${error_summary}"
      ;;
    iphonesimulator)
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR="${status}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_MODE="${mode}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SDK_NAME="${probed_sdk_name}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SDK_VERSION="${sdk_version}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SWIFT_TARGET="${swift_target}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_SYMBOL_SET="${symbol_set}"
      OS27_REPORT_NETWORK_TLS_PQC_PROBE_IPHONESIMULATOR_ERROR_SUMMARY="${error_summary}"
      ;;
    *)
      fail "unknown Network TLS PQC probe SDK: ${sdk_name}"
      ;;
  esac
}

run_reported_gate() {
  local status_var="$1"
  local failure_message="$2"
  shift 2

  printf -v "${status_var}" '%s' "running"
  if "$@"; then
    printf -v "${status_var}" '%s' "passed"
  else
    printf -v "${status_var}" '%s' "failed"
    fail "${failure_message}"
  fi
}

run_source_contract_guardrail_scripts() {
  bash Scripts/test_apple_pqc_sdk_probe_api.sh || return 1
  bash Scripts/test_run_os27_beta_compatibility_diagnose.sh || return 1
  bash Scripts/test_check_os27_compatibility_report.sh || return 1
  bash Scripts/test_rust_cli_remote_desktop_contract_gate.sh || return 1
  bash Scripts/test_lane_ios_device_privacy.sh || return 1
  bash Scripts/test_check_macos_deps.sh || return 1
  bash Scripts/test_build_freerdp_dylibs_policy.sh || return 1
  bash Scripts/test_vendor_artifact_policy.sh || return 1
  bash Scripts/test_qperiapt_install_transaction.sh || return 1
  bash Scripts/test_check_ios_test_configuration.sh || return 1
  bash Scripts/test_verify_xcode_toolchain.sh || return 1
  bash Scripts/test_package_build_policy.sh || return 1
  bash Scripts/test_validate_macos_release_artifact_run.sh || return 1
  bash Scripts/check_ios_test_configuration.sh --static-only || return 1
}

# shellcheck source=Scripts/package_build_policy.sh
source "${ROOT_DIR}/Scripts/package_build_policy.sh"

diagnostic_tool_timeout_seconds() {
  local value="${SKYBRIDGE_OS27_DIAGNOSTIC_TOOL_TIMEOUT_SECONDS:-8}"
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    fail "SKYBRIDGE_OS27_DIAGNOSTIC_TOOL_TIMEOUT_SECONDS must be a positive integer, got: ${value}"
  fi
  printf '%s\n' "${value}"
}

diagnostic_bundle_verify_timeout_seconds() {
  local value="${SKYBRIDGE_OS27_BUNDLE_VERIFY_TIMEOUT_SECONDS:-60}"
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    fail "SKYBRIDGE_OS27_BUNDLE_VERIFY_TIMEOUT_SECONDS must be a positive integer, got: ${value}"
  fi
  printf '%s\n' "${value}"
}

build_gate_timeout_seconds() {
  local value="${SKYBRIDGE_OS27_BUILD_GATE_TIMEOUT_SECONDS:-1800}"
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    fail "SKYBRIDGE_OS27_BUILD_GATE_TIMEOUT_SECONDS must be a positive integer, got: ${value}"
  fi
  printf '%s\n' "${value}"
}

run_command_with_timeout() {
  local timeout_seconds="$1"
  shift

  python3 - "${timeout_seconds}" "$@" <<'PY'
import os
import selectors
import signal
import subprocess
import sys
import time

timeout_seconds = int(sys.argv[1])
command = sys.argv[2:]
deadline = time.monotonic() + timeout_seconds

try:
    process = subprocess.Popen(
        command,
        env=os.environ.copy(),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
        start_new_session=True,
    )
except FileNotFoundError:
    raise SystemExit(127)

selector = selectors.DefaultSelector()
assert process.stdout is not None
stdout_fd = process.stdout.fileno()
os.set_blocking(stdout_fd, False)
selector.register(process.stdout, selectors.EVENT_READ)

def write_chunk(chunk):
    if chunk:
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()

def drain_available():
    while True:
        events = selector.select(timeout=0)
        if not events:
            return
        for key, _ in events:
            try:
                chunk = os.read(key.fileobj.fileno(), 8192)
            except BlockingIOError:
                continue
            if not chunk:
                return
            write_chunk(chunk)

while True:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        drain_available()
        sys.stderr.write(
            f"[os27-beta-compat] ERROR: command timed out after {timeout_seconds} seconds; command redacted\n"
        )
        raise SystemExit(124)

    events = selector.select(timeout=min(0.25, remaining))
    for key, _ in events:
        try:
            chunk = os.read(key.fileobj.fileno(), 8192)
        except BlockingIOError:
            continue
        write_chunk(chunk)

    return_code = process.poll()
    if return_code is not None:
        drain_available()
        raise SystemExit(return_code)
PY
}

capture_diagnostic_tool() {
  local result_var="$1"
  local developer_dir="$2"
  local timeout_seconds
  local output
  local status
  shift 2

  timeout_seconds="$(diagnostic_tool_timeout_seconds)"
  if [[ -n "${developer_dir}" ]]; then
    if output="$(
      DEVELOPER_DIR="${developer_dir}" python3 - "${timeout_seconds}" "$@" <<'PY'
import os
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
command = sys.argv[2:]
try:
    completed = subprocess.run(
        command,
        env=os.environ.copy(),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=timeout_seconds,
        check=False,
    )
except FileNotFoundError:
    raise SystemExit(127)
except subprocess.TimeoutExpired:
    raise SystemExit(124)

sys.stdout.write(completed.stdout)
raise SystemExit(completed.returncode)
PY
    )"; then
      status=0
    else
      status=$?
    fi
  else
    if output="$(
      python3 - "${timeout_seconds}" "$@" <<'PY'
import os
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
command = sys.argv[2:]
try:
    completed = subprocess.run(
        command,
        env=os.environ.copy(),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=timeout_seconds,
        check=False,
    )
except FileNotFoundError:
    raise SystemExit(127)
except subprocess.TimeoutExpired:
    raise SystemExit(124)

sys.stdout.write(completed.stdout)
raise SystemExit(completed.returncode)
PY
    )"; then
      status=0
    else
      status=$?
    fi
  fi

  printf -v "${result_var}" '%s' "${output}"
  return "${status}"
}

devicectl_devices_json_file_is_valid() {
  local payload_file="$1"
  [[ -s "${payload_file}" ]] || return 1
  python3 - "${payload_file}" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)

if not isinstance(payload.get("result", {}).get("devices"), list):
    raise SystemExit(1)
PY
}

extract_devicectl_devices_json_from_stdout() {
  local stdout_file="$1"
  local payload_file="$2"
  python3 - "${stdout_file}" "${payload_file}" <<'PY'
import json
import sys
from pathlib import Path

stdout_path = Path(sys.argv[1])
payload_path = Path(sys.argv[2])
content = stdout_path.read_text(encoding="utf-8", errors="replace")

for index, character in enumerate(content):
    if character != "{":
        continue
    candidate = content[index:].strip()
    try:
        payload = json.loads(candidate)
    except json.JSONDecodeError:
        continue
    if not isinstance(payload.get("result", {}).get("devices"), list):
        continue
    payload_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
    raise SystemExit(0)

raise SystemExit(1)
PY
}

capture_devicectl_devices_json() {
  local developer_dir="$1"
  local payload_file="$2"
  local stdout_file="${payload_file}.stdout"
  local devicectl_output
  local status

  rm -f "${payload_file}" "${stdout_file}"
  if capture_diagnostic_tool devicectl_output "${developer_dir}" xcrun devicectl list devices --json-output "${payload_file}"; then
    if devicectl_devices_json_file_is_valid "${payload_file}"; then
      rm -f "${stdout_file}"
      return 0
    fi
    if [[ -n "${devicectl_output}" ]]; then
      printf '%s\n' "${devicectl_output}" >"${stdout_file}"
      if extract_devicectl_devices_json_from_stdout "${stdout_file}" "${payload_file}"; then
        rm -f "${stdout_file}"
        return 0
      fi
    fi
  else
    status=$?
    rm -f "${stdout_file}"
    return "${status}"
  fi

  rm -f "${payload_file}" "${stdout_file}"
  if capture_diagnostic_tool devicectl_output "${developer_dir}" xcrun devicectl list devices --json-output -; then
    printf '%s\n' "${devicectl_output}" >"${stdout_file}"
    if extract_devicectl_devices_json_from_stdout "${stdout_file}" "${payload_file}"; then
      rm -f "${stdout_file}"
      return 0
    fi
    rm -f "${stdout_file}"
    return 70
  fi

  status=$?
  rm -f "${stdout_file}"
  return "${status}"
}

capture_diagnostic_tool_combined() {
  local result_var="$1"
  local developer_dir="$2"
  local timeout_seconds
  shift 2

  timeout_seconds="$(diagnostic_tool_timeout_seconds)"
  capture_diagnostic_tool_combined_with_timeout "${result_var}" "${developer_dir}" "${timeout_seconds}" "$@"
}

capture_diagnostic_tool_combined_with_timeout() {
  local result_var="$1"
  local developer_dir="$2"
  local timeout_seconds="$3"
  local output
  local status
  shift 3

  if [[ -n "${developer_dir}" ]]; then
    if output="$(
      DEVELOPER_DIR="${developer_dir}" python3 - "${timeout_seconds}" "$@" <<'PY'
import os
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
command = sys.argv[2:]
try:
    completed = subprocess.run(
        command,
        env=os.environ.copy(),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout_seconds,
        check=False,
    )
except FileNotFoundError:
    raise SystemExit(127)
except subprocess.TimeoutExpired:
    raise SystemExit(124)

sys.stdout.write(completed.stdout)
raise SystemExit(completed.returncode)
PY
    )"; then
      status=0
    else
      status=$?
    fi
  else
    if output="$(
      python3 - "${timeout_seconds}" "$@" <<'PY'
import os
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
command = sys.argv[2:]
try:
    completed = subprocess.run(
        command,
        env=os.environ.copy(),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout_seconds,
        check=False,
    )
except FileNotFoundError:
    raise SystemExit(127)
except subprocess.TimeoutExpired:
    raise SystemExit(124)

sys.stdout.write(completed.stdout)
raise SystemExit(completed.returncode)
PY
    )"; then
      status=0
    else
      status=$?
    fi
  fi

  printf -v "${result_var}" '%s' "${output}"
  return "${status}"
}

print_diagnostic_tool_status() {
  local label="$1"
  local status="$2"
  local timeout_seconds
  timeout_seconds="$(diagnostic_tool_timeout_seconds)"

  case "${status}" in
    0)
      echo "[os27-beta-compat] toolchain_probe=${label} status=ok"
      ;;
    124)
      echo "[os27-beta-compat] toolchain_probe=${label} status=toolchain_invocation_timeout seconds=${timeout_seconds}"
      ;;
    127)
      echo "[os27-beta-compat] toolchain_probe=${label} status=missing"
      ;;
    *)
      echo "[os27-beta-compat] toolchain_probe=${label} status=failed exit_code=${status}"
      ;;
  esac
}

xcode27_app_bundle_for_developer_dir() {
  local developer_dir="$1"
  local app_bundle

  case "${developer_dir}" in
    */Contents/Developer)
      app_bundle="${developer_dir%/Contents/Developer}"
      ;;
    *)
      return 1
      ;;
  esac

  [[ "${app_bundle}" == *.app ]] || return 1
  printf '%s\n' "${app_bundle}"
}

pick_xcode27_developer_dir() {
  local candidate

  if [[ -n "${SKYBRIDGE_OS27_XCODE27_DEVELOPER_DIR:-}" ]]; then
    printf '%s\n' "${SKYBRIDGE_OS27_XCODE27_DEVELOPER_DIR}"
    return
  fi

  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    printf '%s\n' "${DEVELOPER_DIR}"
    return
  fi

  for candidate in "${OS27_XCODE27_DEVELOPER_DIR_CANDIDATES[@]}"; do
    if [[ -d "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done

  return 1
}

print_xcode27_candidate_report() {
  local candidate
  local app_bundle
  local app_exists
  local developer_dir_exists
  local info_plist_exists
  local app_name
  local exists

  for candidate in "${OS27_XCODE27_DEVELOPER_DIR_CANDIDATES[@]}"; do
    exists=0
    if [[ -d "${candidate}" ]]; then
      exists=1
    fi
    echo "[os27-beta-compat] xcode27_candidate path=$(sanitize_log_value "${candidate}") exists=${exists}"

    app_bundle="$(xcode27_app_bundle_for_developer_dir "${candidate}" || true)"
    app_exists=0
    developer_dir_exists=0
    info_plist_exists=0
    app_name="unknown"
    if [[ -n "${app_bundle}" ]]; then
      app_name="$(basename "${app_bundle}")"
      [[ -d "${app_bundle}" ]] && app_exists=1
      [[ -d "${candidate}" ]] && developer_dir_exists=1
      [[ -f "${app_bundle}/Contents/Info.plist" ]] && info_plist_exists=1
    fi
    echo "[os27-beta-compat] xcode27_bundle_candidate name=${app_name} app_exists=${app_exists} developer_dir_exists=${developer_dir_exists} info_plist_exists=${info_plist_exists}"
  done
}

print_xcode27_bundle_structure_diagnostics() {
  local app_bundle="$1"
  local developer_dir="$2"
  local info_plist="${app_bundle}/Contents/Info.plist"
  local executable_path="${app_bundle}/Contents/MacOS/Xcode"

  python3 - "${app_bundle}" "${developer_dir}" "${info_plist}" "${executable_path}" <<'PY'
import datetime as dt
import os
import plistlib
import sys

PREFIX = "[os27-beta-compat]"
app_bundle, developer_dir, info_plist, executable_path = sys.argv[1:]
required = {
    "app": app_bundle,
    "developer_dir": developer_dir,
    "info_plist": info_plist,
    "executable": executable_path,
}
missing = [name for name, path in required.items() if not os.path.exists(path)]

def iso_timestamp(path, attr):
    try:
        stat = os.stat(path)
    except OSError:
        return "missing"
    value = getattr(stat, attr, None)
    if value is None:
        return "unavailable"
    return dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat().replace("+00:00", "Z")

identifier = "missing"
short_version = "missing"
build = "missing"
if os.path.exists(info_plist):
    try:
        with open(info_plist, "rb") as handle:
            payload = plistlib.load(handle)
        identifier = str(payload.get("CFBundleIdentifier") or "missing")
        short_version = str(payload.get("CFBundleShortVersionString") or "missing")
        build = str(
            payload.get("ProductBuildVersion")
            or payload.get("DTXcodeBuild")
            or payload.get("CFBundleVersion")
            or "missing"
        )
    except Exception:
        identifier = "parse_error"
        short_version = "parse_error"
        build = "parse_error"

early_cutoff = dt.datetime(2000, 1, 1, tzinfo=dt.timezone.utc).timestamp()
now = dt.datetime.now(dt.timezone.utc).timestamp()
early_mtime_file_count = 0
future_mtime_file_count = 0
earliest_mtime = None
latest_mtime = None
if os.path.exists(app_bundle):
    for root, _, files in os.walk(app_bundle):
        for filename in files:
            path = os.path.join(root, filename)
            try:
                mtime = os.stat(path).st_mtime
            except OSError:
                continue
            earliest_mtime = mtime if earliest_mtime is None else min(earliest_mtime, mtime)
            latest_mtime = mtime if latest_mtime is None else max(latest_mtime, mtime)
            if mtime < early_cutoff:
                early_mtime_file_count += 1
            elif mtime > now:
                future_mtime_file_count += 1

def format_epoch(value):
    if value is None:
        return "missing"
    return dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat().replace("+00:00", "Z")

complete = 0 if missing else 1
missing_value = ",".join(missing) if missing else "none"
print(f"{PREFIX} xcode27_bundle_complete={complete} required_paths={'present' if complete else 'missing'} missing_required_paths={missing_value}")
print(f"{PREFIX} xcode27_bundle_info identifier={identifier} short_version={short_version} build={build}")
print(
    f"{PREFIX} xcode27_bundle_timestamps "
    f"bundle_birth_utc={iso_timestamp(app_bundle, 'st_birthtime')} "
    f"bundle_mtime_utc={iso_timestamp(app_bundle, 'st_mtime')} "
    f"developer_dir_mtime_utc={iso_timestamp(developer_dir, 'st_mtime')} "
    f"info_plist_mtime_utc={iso_timestamp(info_plist, 'st_mtime')} "
    f"executable_mtime_utc={iso_timestamp(executable_path, 'st_mtime')}"
)
print(
    f"{PREFIX} xcode27_bundle_timestamp_anomalies "
    f"early_mtime_file_count={early_mtime_file_count} "
    f"future_mtime_file_count={future_mtime_file_count} "
    f"earliest_mtime_utc={format_epoch(earliest_mtime)} "
    f"latest_mtime_utc={format_epoch(latest_mtime)} "
    f"evidence=metadata_only action=record_only"
)
raise SystemExit(0 if complete else 2)
PY
}

combined_tool_status_label() {
  local status="$1"

  case "${status}" in
    0)
      printf 'ok\n'
      ;;
    124)
      printf 'toolchain_invocation_timeout\n'
      ;;
    127)
      printf 'missing\n'
      ;;
    *)
      printf 'failed\n'
      ;;
  esac
}

print_xcode27_selected_bundle_diagnostics() {
  local developer_dir="$1"
  local app_bundle
  local structure_output=""
  local structure_status=0
  local metadata_output=""
  local verify_output=""
  local quarantine_output=""
  local provenance_output=""
  local spctl_status_output=""
  local spctl_assess_output=""
  local metadata_status
  local verify_status
  local quarantine_status
  local provenance_status
  local spctl_status
  local spctl_assess_status
  local metadata_status_label
  local verify_status_label
  local identifier
  local signed_time
  local authority_class
  local team_identifier_state
  local cdhash_state
  local signed_time_state
  local metadata_ready=0
  local verify_ready=0
  local quarantine_ready=0
  local gatekeeper_ready=1
  local ready=0

  app_bundle="$(xcode27_app_bundle_for_developer_dir "${developer_dir}" || true)"
  if [[ -z "${app_bundle}" ]]; then
    OS27_REPORT_XCODE_BUNDLE_READY=0
    echo "[os27-beta-compat] xcode27_bundle_complete=0 required_paths=missing missing_required_paths=app_bundle_layout"
    echo "[os27-beta-compat] xcode27_bundle_diagnostic ready=0 compatibility=not_validated release_eligible=false evidence=environment_metadata_only"
    return 2
  fi

  if structure_output="$(print_xcode27_bundle_structure_diagnostics "${app_bundle}" "${developer_dir}")"; then
    structure_status=0
  else
    structure_status=$?
  fi
  printf '%s\n' "${structure_output}"
  OS27_REPORT_XCODE_BUNDLE_IDENTIFIER="$(sed -n 's/^.*xcode27_bundle_info identifier=\([^ ]*\).*$/\1/p' <<<"${structure_output}" | head -n 1)"
  OS27_REPORT_XCODE_BUNDLE_VERSION="$(sed -n 's/^.*xcode27_bundle_info .* short_version=\([^ ]*\).*$/\1/p' <<<"${structure_output}" | head -n 1)"
  OS27_REPORT_XCODE_BUNDLE_BUILD="$(sed -n 's/^.*xcode27_bundle_info .* build=\([^ ]*\).*$/\1/p' <<<"${structure_output}" | head -n 1)"
  OS27_REPORT_XCODE_BUNDLE_EARLY_MTIME_FILE_COUNT="$(sed -n 's/^.*xcode27_bundle_timestamp_anomalies .*early_mtime_file_count=\([^ ]*\).*$/\1/p' <<<"${structure_output}" | head -n 1)"
  OS27_REPORT_XCODE_BUNDLE_FUTURE_MTIME_FILE_COUNT="$(sed -n 's/^.*xcode27_bundle_timestamp_anomalies .*future_mtime_file_count=\([^ ]*\).*$/\1/p' <<<"${structure_output}" | head -n 1)"
  OS27_REPORT_XCODE_BUNDLE_EARLIEST_MTIME_UTC="$(sed -n 's/^.*xcode27_bundle_timestamp_anomalies .*earliest_mtime_utc=\([^ ]*\).*$/\1/p' <<<"${structure_output}" | head -n 1)"
  OS27_REPORT_XCODE_BUNDLE_LATEST_MTIME_UTC="$(sed -n 's/^.*xcode27_bundle_timestamp_anomalies .*latest_mtime_utc=\([^ ]*\).*$/\1/p' <<<"${structure_output}" | head -n 1)"
  OS27_REPORT_XCODE_BUNDLE_IDENTIFIER="${OS27_REPORT_XCODE_BUNDLE_IDENTIFIER:-unknown}"
  OS27_REPORT_XCODE_BUNDLE_VERSION="${OS27_REPORT_XCODE_BUNDLE_VERSION:-unknown}"
  OS27_REPORT_XCODE_BUNDLE_BUILD="${OS27_REPORT_XCODE_BUNDLE_BUILD:-unknown}"
  OS27_REPORT_XCODE_BUNDLE_EARLY_MTIME_FILE_COUNT="${OS27_REPORT_XCODE_BUNDLE_EARLY_MTIME_FILE_COUNT:-0}"
  OS27_REPORT_XCODE_BUNDLE_FUTURE_MTIME_FILE_COUNT="${OS27_REPORT_XCODE_BUNDLE_FUTURE_MTIME_FILE_COUNT:-0}"
  OS27_REPORT_XCODE_BUNDLE_EARLIEST_MTIME_UTC="${OS27_REPORT_XCODE_BUNDLE_EARLIEST_MTIME_UTC:-unknown}"
  OS27_REPORT_XCODE_BUNDLE_LATEST_MTIME_UTC="${OS27_REPORT_XCODE_BUNDLE_LATEST_MTIME_UTC:-unknown}"

  if capture_diagnostic_tool_combined metadata_output "${developer_dir}" codesign -dv --verbose=4 "${app_bundle}"; then
    metadata_status=0
  else
    metadata_status=$?
  fi
  metadata_status_label="$(combined_tool_status_label "${metadata_status}")"
  OS27_REPORT_CODESIGN_METADATA_STATUS="${metadata_status_label}"
  identifier="$(sed -n 's/^Identifier=//p' <<<"${metadata_output}" | head -n 1)"
  signed_time="$(sed -n 's/^Signed Time=//p' <<<"${metadata_output}" | head -n 1)"
  signed_time="${signed_time//$'\n'/ }"
  signed_time="${signed_time//\'/}"
  authority_class="other"
  if grep -Fq 'Authority=Software Signing' <<<"${metadata_output}" \
    && grep -Fq 'Authority=Apple Code Signing Certification Authority' <<<"${metadata_output}" \
    && grep -Fq 'Authority=Apple Root CA' <<<"${metadata_output}"; then
    authority_class="apple_software_signing"
  elif ! grep -Fq 'Authority=' <<<"${metadata_output}"; then
    authority_class="missing"
  fi
  team_identifier_state="absent"
  grep -q '^TeamIdentifier=' <<<"${metadata_output}" && team_identifier_state="present"
  cdhash_state="absent"
  grep -q '^CDHash=' <<<"${metadata_output}" && cdhash_state="present"
  signed_time_state="absent"
  [[ -n "${signed_time}" ]] && signed_time_state="present"

  if [[ "${metadata_status}" -eq 0 \
    && "${identifier}" == "com.apple.dt.Xcode" \
    && "${authority_class}" == "apple_software_signing" \
    && "${team_identifier_state}" == "present" \
    && "${cdhash_state}" == "present" \
    && "${signed_time_state}" == "present" ]]; then
    metadata_ready=1
  fi
  echo "[os27-beta-compat] xcode27_bundle_codesign_metadata status=${metadata_status_label} identifier=${identifier:-missing} authority=${authority_class} team_identifier=${team_identifier_state} cdhash=${cdhash_state} signed_time=${signed_time_state} signed_time_value='${signed_time:-missing}'"

  if capture_diagnostic_tool_combined_with_timeout verify_output "${developer_dir}" "$(diagnostic_bundle_verify_timeout_seconds)" codesign --verify --strict --verbose=2 "${app_bundle}"; then
    verify_status=0
  else
    verify_status=$?
  fi
  verify_status_label="$(combined_tool_status_label "${verify_status}")"
  OS27_REPORT_CODESIGN_VERIFY_STATUS="${verify_status_label}"
  [[ "${verify_status}" -eq 0 ]] && verify_ready=1
  echo "[os27-beta-compat] xcode27_bundle_codesign_verify status=${verify_status_label}"
  : "${verify_output}"

  if capture_diagnostic_tool_combined quarantine_output "${developer_dir}" xattr -p com.apple.quarantine "${app_bundle}"; then
    quarantine_status=0
  else
    quarantine_status=$?
  fi
  case "${quarantine_status}" in
    0)
      echo "[os27-beta-compat] xcode27_bundle_quarantine status=present"
      OS27_REPORT_QUARANTINE_STATUS="present"
      quarantine_ready=0
      ;;
    124 | 127)
      OS27_REPORT_QUARANTINE_STATUS="$(combined_tool_status_label "${quarantine_status}")"
      echo "[os27-beta-compat] xcode27_bundle_quarantine status=${OS27_REPORT_QUARANTINE_STATUS}"
      quarantine_ready=0
      ;;
    *)
      echo "[os27-beta-compat] xcode27_bundle_quarantine status=absent"
      OS27_REPORT_QUARANTINE_STATUS="absent"
      quarantine_ready=1
      ;;
  esac
  : "${quarantine_output}"

  if capture_diagnostic_tool_combined provenance_output "${developer_dir}" xattr -p com.apple.provenance "${app_bundle}"; then
    provenance_status=0
  else
    provenance_status=$?
  fi
  if [[ "${provenance_status}" -eq 0 ]]; then
    echo "[os27-beta-compat] xcode27_bundle_provenance_xattr status=present"
    OS27_REPORT_PROVENANCE_STATUS="present"
  elif [[ "${provenance_status}" -eq 124 || "${provenance_status}" -eq 127 ]]; then
    OS27_REPORT_PROVENANCE_STATUS="$(combined_tool_status_label "${provenance_status}")"
    echo "[os27-beta-compat] xcode27_bundle_provenance_xattr status=${OS27_REPORT_PROVENANCE_STATUS}"
  else
    echo "[os27-beta-compat] xcode27_bundle_provenance_xattr status=absent"
    OS27_REPORT_PROVENANCE_STATUS="absent"
  fi
  : "${provenance_output}"

  if capture_diagnostic_tool_combined spctl_status_output "${developer_dir}" spctl --status; then
    spctl_status=0
  else
    spctl_status=$?
  fi
  if [[ "${spctl_status_output}" == *"assessments disabled"* ]]; then
    echo "[os27-beta-compat] xcode27_gatekeeper_assessments status=disabled"
    echo "[os27-beta-compat] xcode27_bundle_gatekeeper status=not_run reason=assessments_disabled"
    OS27_REPORT_GATEKEEPER_ASSESSMENTS_STATUS="disabled"
    OS27_REPORT_GATEKEEPER_BUNDLE_STATUS="not_run_assessments_disabled"
  elif [[ "${spctl_status_output}" == *"assessments enabled"* ]]; then
    echo "[os27-beta-compat] xcode27_gatekeeper_assessments status=enabled"
    OS27_REPORT_GATEKEEPER_ASSESSMENTS_STATUS="enabled"
    if capture_diagnostic_tool_combined spctl_assess_output "${developer_dir}" spctl --assess --type execute --verbose=4 "${app_bundle}"; then
      spctl_assess_status=0
    else
      spctl_assess_status=$?
    fi
    if [[ "${spctl_assess_status}" -eq 0 ]]; then
      echo "[os27-beta-compat] xcode27_bundle_gatekeeper status=accepted"
      OS27_REPORT_GATEKEEPER_BUNDLE_STATUS="accepted"
    else
      gatekeeper_ready=0
      OS27_REPORT_GATEKEEPER_BUNDLE_STATUS="$(combined_tool_status_label "${spctl_assess_status}")"
      echo "[os27-beta-compat] xcode27_bundle_gatekeeper status=${OS27_REPORT_GATEKEEPER_BUNDLE_STATUS}"
    fi
    : "${spctl_assess_output}"
  elif [[ "${spctl_status}" -eq 124 || "${spctl_status}" -eq 127 ]]; then
    OS27_REPORT_GATEKEEPER_ASSESSMENTS_STATUS="$(combined_tool_status_label "${spctl_status}")"
    OS27_REPORT_GATEKEEPER_BUNDLE_STATUS="not_run_assessment_status_unavailable"
    echo "[os27-beta-compat] xcode27_gatekeeper_assessments status=${OS27_REPORT_GATEKEEPER_ASSESSMENTS_STATUS}"
    echo "[os27-beta-compat] xcode27_bundle_gatekeeper status=not_run reason=assessment_status_unavailable"
  else
    echo "[os27-beta-compat] xcode27_gatekeeper_assessments status=unavailable"
    echo "[os27-beta-compat] xcode27_bundle_gatekeeper status=not_run reason=assessment_status_unavailable"
    OS27_REPORT_GATEKEEPER_ASSESSMENTS_STATUS="unavailable"
    OS27_REPORT_GATEKEEPER_BUNDLE_STATUS="not_run_assessment_status_unavailable"
  fi

  if [[ "${structure_status}" -eq 0 \
    && "${metadata_ready}" == "1" \
    && "${verify_ready}" == "1" \
    && "${quarantine_ready}" == "1" \
    && "${gatekeeper_ready}" == "1" ]]; then
    ready=1
  fi
  OS27_REPORT_XCODE_BUNDLE_READY="${ready}"
  echo "[os27-beta-compat] xcode27_bundle_diagnostic ready=${ready} compatibility=not_validated release_eligible=false evidence=environment_metadata_only"
  if [[ "${ready}" == "1" ]]; then
    return 0
  fi
  return 2
}

diagnose_toolchain_readiness() {
  local developer_dir="$1"
  local xcode_output
  local swift_output
  local macos_sdk
  local iphoneos_sdk
  local iphonesim_sdk
  local sdk_version
  local sdk_major
  local sdk27_ok=1
  local xcode_status
  local swift_status
  local macos_sdk_status
  local iphoneos_sdk_status
  local iphonesim_sdk_status

  set +e
  capture_diagnostic_tool xcode_output "${developer_dir}" xcodebuild -version
  xcode_status=$?
  capture_diagnostic_tool swift_output "${developer_dir}" xcrun swift --version
  swift_status=$?
  capture_diagnostic_tool macos_sdk "${developer_dir}" xcrun --sdk macosx --show-sdk-version
  macos_sdk_status=$?
  capture_diagnostic_tool iphoneos_sdk "${developer_dir}" xcrun --sdk iphoneos --show-sdk-version
  iphoneos_sdk_status=$?
  capture_diagnostic_tool iphonesim_sdk "${developer_dir}" xcrun --sdk iphonesimulator --show-sdk-version
  iphonesim_sdk_status=$?
  set -e

  print_diagnostic_tool_status "xcodebuild" "${xcode_status}"
  print_diagnostic_tool_status "swift" "${swift_status}"
  print_diagnostic_tool_status "macosx-sdk" "${macos_sdk_status}"
  print_diagnostic_tool_status "iphoneos-sdk" "${iphoneos_sdk_status}"
  print_diagnostic_tool_status "iphonesimulator-sdk" "${iphonesim_sdk_status}"

  echo "[os27-beta-compat] xcode_version=$(flatten_output "${xcode_output:-unknown}")"
  echo "[os27-beta-compat] swift_version=$(head -n 1 <<<"${swift_output:-unknown}")"
  echo "[os27-beta-compat] SDKs: macOS=${macos_sdk:-unknown} iphoneOS=${iphoneos_sdk:-unknown} iPhoneSimulator=${iphonesim_sdk:-unknown}"

  OS27_REPORT_XCODE_VERSION="$(head -n 1 <<<"${xcode_output:-unknown}")"
  OS27_REPORT_XCODEBUILD_BUILD="$(sed -n 's/^Build version //p' <<<"${xcode_output:-unknown}" | head -n 1)"
  OS27_REPORT_XCODEBUILD_BUILD="${OS27_REPORT_XCODEBUILD_BUILD:-unknown}"
  OS27_REPORT_SWIFT_VERSION="$(head -n 1 <<<"${swift_output:-unknown}")"
  OS27_REPORT_MACOS_SDK="${macos_sdk:-unknown}"
  OS27_REPORT_IPHONEOS_SDK="${iphoneos_sdk:-unknown}"
  OS27_REPORT_IPHONESIMULATOR_SDK="${iphonesim_sdk:-unknown}"

  OS27_DIAG_XCODE27_READY=0
  if [[ "${xcode_status}" == "0" && "${xcode_output}" == Xcode\ 27* ]]; then
    OS27_DIAG_XCODE27_READY=1
  fi
  OS27_REPORT_XCODE27_READY="${OS27_DIAG_XCODE27_READY}"

  for sdk_version in "${macos_sdk}" "${iphoneos_sdk}" "${iphonesim_sdk}"; do
    sdk_major="${sdk_version%%.*}"
    if [[ "${sdk_major}" != "27" ]]; then
      sdk27_ok=0
    fi
  done
  OS27_DIAG_SDK27_READY="${sdk27_ok}"
  OS27_REPORT_SDK27_READY="${OS27_DIAG_SDK27_READY}"

  if [[ "${OS27_DIAG_XCODE27_READY}" == "1" ]]; then
    echo "[os27-beta-compat] requirement xcode27=present"
  else
    echo "[os27-beta-compat] requirement xcode27=missing"
  fi

  if [[ "${OS27_DIAG_SDK27_READY}" == "1" ]]; then
    echo "[os27-beta-compat] requirement sdk27=present"
  else
    echo "[os27-beta-compat] requirement sdk27=missing"
  fi
}

record_xcode27_build_consistency() {
  if [[ "${OS27_REPORT_XCODE_BUNDLE_BUILD}" == "unknown" || "${OS27_REPORT_XCODEBUILD_BUILD}" == "unknown" ]]; then
    OS27_REPORT_XCODE_BUILD_CONSISTENCY="not_available"
  elif [[ "${OS27_REPORT_XCODE_BUNDLE_BUILD}" == "${OS27_REPORT_XCODEBUILD_BUILD}" ]]; then
    OS27_REPORT_XCODE_BUILD_CONSISTENCY="matched"
  else
    OS27_REPORT_XCODE_BUILD_CONSISTENCY="metadata_mismatch"
  fi

  echo "[os27-beta-compat] xcode27_build_consistency status=${OS27_REPORT_XCODE_BUILD_CONSISTENCY} bundle_build=${OS27_REPORT_XCODE_BUNDLE_BUILD} xcodebuild_build=${OS27_REPORT_XCODEBUILD_BUILD} release_eligible=false"
}

print_devicectl_device_summary() {
  local developer_dir="$1"
  local payload_dir
  local payload_file
  local summary_file
  local status
  local ready

  payload_dir="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-os27-devices.XXXXXX")" || {
    echo "[os27-beta-compat] device_scan=internal_error"
    return 70
  }
  payload_file="${payload_dir}/devices.json"
  summary_file="${payload_dir}/summary.txt"

  if capture_devicectl_devices_json "${developer_dir}" "${payload_file}"; then
    print_diagnostic_tool_status "devicectl" 0
    if python3 - "${payload_file}" >"${summary_file}" <<'PY'
import json
import sys

PREFIX = "[os27-beta-compat]"

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)

devices = payload.get("result", {}).get("devices", [])
if not isinstance(devices, list):
    raise SystemExit(1)

def parse_major(value):
    try:
        return int(str(value).split(".", 1)[0])
    except (TypeError, ValueError):
        return None

def is_ipados27_ipad(device):
    props = device.get("deviceProperties", {})
    hardware = device.get("hardwareProperties", {})
    return (
        hardware.get("platform") == "iOS"
        and hardware.get("deviceType") == "iPad"
        and parse_major(props.get("osVersionNumber")) == 27
    )

matching_beta = []
candidate = []
ready_beta = []
ready_candidate = []
paired_count = 0
booted_count = 0
developer_mode_count = 0
developer_mode_unknown_count = 0
tunnel_available_count = 0
tunnel_connected_count = 0

for device in devices:
    if not isinstance(device, dict) or not is_ipados27_ipad(device):
        continue

    props = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    release_type = props.get("releaseType")
    is_beta = release_type == "Beta"
    is_candidate_release = release_type in (None, "", "Beta", "unknown")

    if is_beta:
        matching_beta.append(device)
    if is_candidate_release:
        candidate.append(device)

    paired = connection.get("pairingState") == "paired"
    booted = props.get("bootState") == "booted"
    developer_mode_status = props.get("developerModeStatus")
    developer_mode = developer_mode_status == "enabled"
    developer_mode_unknown = developer_mode_status in (None, "", "unknown")
    tunnel_state = connection.get("tunnelState")
    tunnel_available = tunnel_state != "unavailable"
    tunnel_connected = tunnel_state == "connected"

    paired_count += int(paired)
    booted_count += int(booted)
    developer_mode_count += int(developer_mode)
    developer_mode_unknown_count += int(developer_mode_unknown)
    tunnel_available_count += int(tunnel_available)
    tunnel_connected_count += int(tunnel_connected)

    ready_state = paired and booted and developer_mode and tunnel_connected
    if is_beta and ready_state:
        ready_beta.append(device)
    if is_candidate_release and ready_state:
        ready_candidate.append(device)

print(
    f"{PREFIX} device_scan=ok total_devices={len(devices)} "
    f"matching_ipados27_beta_ipad_count={len(matching_beta)} "
    f"ready_ipados27_beta_ipad_count={len(ready_beta)} "
    f"candidate_ipados27_ipad_count={len(candidate)} "
    f"ready_ipados27_ipad_candidate_count={len(ready_candidate)}"
)
print(
    f"{PREFIX} device_readiness paired={paired_count} booted={booted_count} "
    f"developer_mode_enabled={developer_mode_count} "
    f"developer_mode_unknown={developer_mode_unknown_count} "
    f"tunnel_available={tunnel_available_count} "
    f"tunnel_connected={tunnel_connected_count}"
)
print(f"{PREFIX} device_ready={1 if ready_beta else 0}")
PY
    then
      cat "${summary_file}"
      ready="$(sed -n 's/^.*device_ready=\([01]\).*$/\1/p' "${summary_file}" | tail -n 1)"
      OS27_DIAG_DEVICE_READY="${ready:-0}"
      OS27_REPORT_DEVICE_READY="${OS27_DIAG_DEVICE_READY}"
    else
      echo "[os27-beta-compat] device_scan=parse_error"
      echo "[os27-beta-compat] device_ready=0"
      OS27_DIAG_DEVICE_READY=0
      OS27_REPORT_DEVICE_READY=0
      rm -rf "${payload_dir}"
      return 70
    fi
  else
    status=$?
    print_diagnostic_tool_status "devicectl" "${status}"
    echo "[os27-beta-compat] device_scan=unavailable exit_code=${status}"
    echo "[os27-beta-compat] device_ready=0"
    OS27_DIAG_DEVICE_READY=0
    OS27_REPORT_DEVICE_READY=0
  fi

  rm -rf "${payload_dir}"
}

run_source_contracts() {
  local pqc_sdk
  local network_tls_pqc_status
  local source_contract_filter

  OS27_REPORT_MODE="source-contracts"
  OS27_REPORT_FULL_VALIDATION="0"
  OS27_REPORT_COMPATIBILITY="not_validated"
  OS27_REPORT_COVERAGE="source_contracts_only"
  OS27_REPORT_STATUS="source_contracts_running"
  OS27_REPORT_SOURCE_CONTRACTS_STATUS="running"
  echo "[os27-beta-compat] mode=source-contracts full_validation=false compatibility=not_validated release_eligible=false coverage=source_contracts_only"

  cd "${ROOT_DIR}"

  if ! run_source_contract_guardrail_scripts; then
    OS27_REPORT_SOURCE_CONTRACTS_STATUS="failed"
    fail "source-contract guardrail script gate failed"
  fi

  source "${ROOT_DIR}/Scripts/apple_pqc_sdk_probe.sh"
  for pqc_sdk in macosx iphoneos iphonesimulator; do
    record_pqc_symbol_probe_result "${pqc_sdk}" "running"
    if ! skybridge_require_apple_pqc_sdk_symbol_probe "${pqc_sdk}"; then
      record_pqc_symbol_probe_result "${pqc_sdk}" "failed"
      OS27_REPORT_SOURCE_CONTRACTS_STATUS="failed"
      fail "source-contract Apple PQC SDK symbol probe failed for ${pqc_sdk}: mode=${SKYBRIDGE_PQC_PROBE_MODE:-unknown}, $(sanitize_log_value "${SKYBRIDGE_PQC_PROBE_ERROR:-unknown}")"
    fi
    record_pqc_symbol_probe_result "${pqc_sdk}" "passed"
    echo "[os27-beta-compat] source_contract Apple PQC symbols verified: sdk=${SKYBRIDGE_PQC_SDK_NAME:-${pqc_sdk}} version=${SKYBRIDGE_PQC_SDK_VER:-unknown} target=${SKYBRIDGE_PQC_SWIFT_TARGET:-unknown}"
  done
  for pqc_sdk in macosx iphoneos iphonesimulator; do
    network_tls_pqc_status="unavailable"
    record_network_tls_pqc_symbol_probe_result "${pqc_sdk}" "running"
    skybridge_detect_network_tls_pqc_sdk "${pqc_sdk}"
    if skybridge_network_tls_pqc_sdk_probe_succeeded; then
      network_tls_pqc_status="passed"
      record_network_tls_pqc_symbol_probe_result "${pqc_sdk}" "passed"
    else
      record_network_tls_pqc_symbol_probe_result "${pqc_sdk}" "unavailable"
    fi
    echo "[os27-beta-compat] source_contract Network TLS PQC public API probe: sdk=${SKYBRIDGE_NETWORK_TLS_PQC_SDK_NAME:-${pqc_sdk}} status=${network_tls_pqc_status} mode=${SKYBRIDGE_NETWORK_TLS_PQC_PROBE_MODE:-unknown} proofScope=transport_sdk_public_api_surface_only releaseEligible=false affectsCryptoSuiteSelection=false"
  done

  export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1
  source_contract_filter='SkyBridgeCoreTests.(ApplePQCSDKGateSourceContractTests|AppleDesignAPISourceContractTests|AppleAIAdvisorySourceContractTests|AppleAppIntentAuthoritySourceContractTests|AIAdvisoryBoundaryTests|MetalShaderSourceCompileContractTests|AppUpdateManifestTests|QuantumCryptoManagerStrictPQCPolicyTests|P2PRedactionSourceContractTests)'
  OS27_REPORT_SWIFTPM_FILTERED_TEST_FILTER="${source_contract_filter}"
  OS27_REPORT_SWIFTPM_FILTERED_TEST_STATUS="running"
  if run_swiftpm_clean_log_test "${source_contract_filter}"; then
    OS27_REPORT_SWIFTPM_FILTERED_TEST_STATUS="passed"
  else
    OS27_REPORT_SWIFTPM_FILTERED_TEST_STATUS="failed"
    OS27_REPORT_SOURCE_CONTRACTS_STATUS="failed"
    fail "source-contract SwiftPM clean-log test failed"
  fi
  OS27_REPORT_SOURCE_CONTRACTS_STATUS="passed"
  OS27_REPORT_STATUS="source_contracts_verified"

  echo "[os27-beta-compat] source_contracts=verified full_validation=false compatibility=not_validated release_eligible=false"
}

run_swiftpm_clean_log() {
  local label="$1"
  local log_file
  local timeout_seconds
  local status
  shift

  timeout_seconds="$(build_gate_timeout_seconds)"
  make_clean_log_file "skybridge-os27-swiftpm-log"
  log_file="${OS27_LAST_CLEAN_LOG_FILE}"
  echo "[os27-beta-compat] clean_log_gate=${label} status=running timeout_seconds=${timeout_seconds}"
  set +e
  run_command_with_timeout "${timeout_seconds}" "$@" 2>&1 | tee "${log_file}" | sanitize_log_stream
  status=${PIPESTATUS[0]}
  set -e

  if [[ "${status}" -eq 124 ]]; then
    echo "[os27-beta-compat] ERROR: ${label} timed out under clean-log gate after ${timeout_seconds}s." >&2
    rm -f "${log_file}"
    return "${status}"
  fi
  if [[ "${status}" -ne 0 ]]; then
    rm -f "${log_file}"
    return "${status}"
  fi

  if grep -E "$(clean_log_diagnostic_pattern)" "${log_file}" >/dev/null; then
    echo "[os27-beta-compat] ERROR: ${label} emitted warnings/errors under clean-log gate." >&2
    grep -E "$(clean_log_diagnostic_pattern)" "${log_file}" | sanitize_log_stream >&2 || true
    rm -f "${log_file}"
    return 1
  fi

  rm -f "${log_file}"
}

prepare_swiftpm_webrtc_runtime_framework() {
  local scratch_path="$1"
  local source_framework
  local product_dir
  local package_framework_dir

  source_framework="$(
    find "${scratch_path}" \
      \( -path '*/out/Products/Debug/WebRTC.framework' -o -path '*/debug/WebRTC.framework' \) \
      ! -path '*/PackageFrameworks/*' \
      ! -path '*/ExecutableModules/*' \
      -type d \
      -print \
      -quit
  )"
  [[ -n "${source_framework}" ]] || fail "SwiftPM WebRTC.framework was not found under ${scratch_path}"
  [[ -e "${source_framework}/WebRTC" ]] || fail "SwiftPM WebRTC.framework runtime binary was not found: ${source_framework}/WebRTC"

  product_dir="${source_framework%/WebRTC.framework}"
  package_framework_dir="${product_dir}/PackageFrameworks"

  mkdir -p "${package_framework_dir}"
  rm -rf "${package_framework_dir}/WebRTC.framework"
  cp -R "${source_framework}" "${package_framework_dir}/WebRTC.framework"

  [[ -e "${package_framework_dir}/WebRTC.framework/WebRTC" ]] || fail "SwiftPM WebRTC.framework runtime copy failed: ${package_framework_dir}/WebRTC.framework/WebRTC"
  echo "[os27-beta-compat] SwiftPM WebRTC runtime framework prepared: $(sanitize_log_value "${package_framework_dir}/WebRTC.framework")"
}

assert_os27_swiftpm_app_has_apple_pqc_compile_marker() {
  local scratch_path="$1"
  local executable_path

  executable_path="$(
    find "${scratch_path}" \
      \( -path '*/out/Products/Debug/SkyBridgeCompassApp' -o -path '*/debug/SkyBridgeCompassApp' \) \
      -type f \
      -perm -111 \
      -print \
      -quit
  )"
  [[ -n "${executable_path}" ]] || fail "SwiftPM SkyBridgeCompassApp executable was not found under ${scratch_path}"

  skybridge_assert_binary_has_apple_pqc_compile_marker "${executable_path}" "OS27 SwiftPM SkyBridgeCompassApp" \
    || fail "OS27 SwiftPM app build did not prove HAS_APPLE_PQC_SDK in the built executable"
  echo "[os27-beta-compat] SwiftPM app Apple PQC compile marker verified"
}

run_swiftpm_clean_log_test() {
  local filter="$1"
  local scratch_path
  ensure_swiftpm_scratch_path
  scratch_path="${OS27_SWIFTPM_SCRATCH_PATH}"
  prime_swiftpm_scratch_path "${scratch_path}"
  run_swiftpm_clean_log "SwiftPM OS27 PQC test build" swift build --scratch-path "${scratch_path}" --disable-automatic-resolution --disable-prefetching --build-tests
  prepare_swiftpm_webrtc_runtime_framework "${scratch_path}"
  run_swiftpm_clean_log "SwiftPM OS27 PQC test" swift test --scratch-path "${scratch_path}" --disable-automatic-resolution --disable-prefetching --skip-build --filter "${filter}"
}

run_xcodebuild_clean_log() {
  local label="$1"
  local log_file
  local timeout_seconds
  local status
  shift

  timeout_seconds="$(build_gate_timeout_seconds)"
  make_clean_log_file "skybridge-os27-xcodebuild-log"
  log_file="${OS27_LAST_CLEAN_LOG_FILE}"
  echo "[os27-beta-compat] clean_log_gate=${label} status=running timeout_seconds=${timeout_seconds}"
  set +e
  run_command_with_timeout "${timeout_seconds}" "$@" 2>&1 | tee "${log_file}" | sanitize_log_stream
  status=${PIPESTATUS[0]}
  set -e

  if [[ "${status}" -eq 124 ]]; then
    echo "[os27-beta-compat] ERROR: ${label} timed out under clean-log gate after ${timeout_seconds}s." >&2
    rm -f "${log_file}"
    return "${status}"
  fi
  if [[ "${status}" -ne 0 ]]; then
    rm -f "${log_file}"
    return "${status}"
  fi

  if grep -E "$(clean_log_diagnostic_pattern)" "${log_file}" >/dev/null; then
    echo "[os27-beta-compat] ERROR: ${label} emitted warnings/errors under clean-log gate." >&2
    grep -E "$(clean_log_diagnostic_pattern)" "${log_file}" | sanitize_log_stream >&2 || true
    rm -f "${log_file}"
    return 1
  fi

  rm -f "${log_file}"
}

reject_conflicting_os27_device_gate_env() {
  local name="$1"
  local expected="$2"
  local actual="${!name:-}"

  if [[ -n "${actual}" && "${actual}" != "${expected}" ]]; then
    echo "[os27-beta-compat] ERROR: ${name} must be ${expected} for OS27 required iPadOS 27 Beta runtime validation, got: $(sanitize_log_value "${actual}")" >&2
    return 1
  fi
  return 0
}

run_ios27_device_pqc_runtime_test() {
  local ios_device_test="$1"
  local expected_os_major="27"
  local expected_release_type="Beta"
  local expected_ipad_required="1"

  reject_conflicting_os27_device_gate_env SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR "${expected_os_major}" || return 1
  reject_conflicting_os27_device_gate_env SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE "${expected_release_type}" || return 1
  reject_conflicting_os27_device_gate_env SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD "${expected_ipad_required}" || return 1

  echo "[os27-beta-compat] running iOS 27 beta device PQC runtime test: ${ios_device_test}"
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR="${expected_os_major}" \
    SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE="${expected_release_type}" \
	  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD="${expected_ipad_required}" \
	    SKYBRIDGE_IOS_DEVICE_ONLY_TESTING="${ios_device_test}" \
	    SKYBRIDGE_IOS_DEVICE_ENFORCE_CLEAN_XCODE_LOGS=1 \
	    SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK \
	    bash "SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh"
}

run_diagnose_environment() {
  local selected_developer_dir
  local current_developer_dir
  local developer_dir_for_tools
  local diagnostic_status=0
  local bundle_status=0

  OS27_REPORT_MODE="diagnose"
  OS27_REPORT_FULL_VALIDATION="0"
  OS27_REPORT_COMPATIBILITY="not_validated"
  OS27_REPORT_COVERAGE="toolchain_sdk_device_readiness_only"
  OS27_REPORT_STATUS="diagnose_running"
  echo "[os27-beta-compat] mode=diagnose full_validation=false compatibility=not_validated coverage=toolchain_sdk_device_readiness_only"
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    echo "[os27-beta-compat] developer_dir_override=present path=$(sanitize_log_value "${DEVELOPER_DIR}")"
  else
    echo "[os27-beta-compat] developer_dir_override=absent"
  fi

  print_xcode27_candidate_report

  selected_developer_dir="$(pick_xcode27_developer_dir || true)"
  if [[ -n "${selected_developer_dir}" && -d "${selected_developer_dir}" ]]; then
    echo "[os27-beta-compat] selected_developer_dir=present path=$(sanitize_log_value "${selected_developer_dir}")"
    developer_dir_for_tools="${selected_developer_dir}"
  else
    if [[ -n "${selected_developer_dir}" ]]; then
      echo "[os27-beta-compat] selected_developer_dir=missing path=$(sanitize_log_value "${selected_developer_dir}")"
    else
      echo "[os27-beta-compat] selected_developer_dir=missing"
    fi

    current_developer_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ -n "${current_developer_dir}" ]]; then
      echo "[os27-beta-compat] current_developer_dir=$(sanitize_log_value "${current_developer_dir}")"
    else
      echo "[os27-beta-compat] current_developer_dir=unavailable"
    fi
    developer_dir_for_tools="${current_developer_dir}"
  fi

  print_xcode27_selected_bundle_diagnostics "${developer_dir_for_tools}" || bundle_status=$?
  if [[ "${bundle_status}" -eq 0 ]]; then
    OS27_DIAG_XCODE27_BUNDLE_READY=1
  else
    OS27_DIAG_XCODE27_BUNDLE_READY=0
    diagnostic_status="${bundle_status}"
  fi

  diagnose_toolchain_readiness "${developer_dir_for_tools}"
  record_xcode27_build_consistency
  print_devicectl_device_summary "${developer_dir_for_tools}" || diagnostic_status=$?
  echo "[os27-beta-compat] full_validation=not_run compatibility=not_validated"

  if [[ "${diagnostic_status}" -ne 0 ]]; then
    OS27_REPORT_STATUS="diagnose_failed"
    return "${diagnostic_status}"
  fi

  if [[ "${OS27_DIAG_XCODE27_READY}" == "1" && "${OS27_DIAG_SDK27_READY}" == "1" && "${OS27_DIAG_DEVICE_READY}" == "1" && "${OS27_DIAG_XCODE27_BUNDLE_READY}" == "1" ]]; then
    OS27_REPORT_STATUS="diagnose_ready"
    return 0
  fi

  OS27_REPORT_STATUS="diagnose_incomplete"
  return 2
}

run_full_validation_lane() {
  local selected_developer_dir
  local xcode_output
  local swift_output
  local macos_sdk
  local iphoneos_sdk
  local iphonesim_sdk
  local sdk_name
  local sdk_version
  local sdk_major
  local pqc_sdk
  local network_tls_pqc_status
  local swiftpm_pqc_filter
  local required_ios_device_test
  local requested_ios_device_test
  local skipped_ios_build_gates=()

  OS27_REPORT_MODE="validate"
  OS27_REPORT_FULL_VALIDATION="0"
  OS27_REPORT_FULL_VALIDATION_ATTEMPTED="1"
  OS27_REPORT_FULL_VALIDATION_PASSED="0"
  OS27_REPORT_COMPATIBILITY="not_validated"
  OS27_REPORT_COVERAGE="os27_full_lane"
  OS27_REPORT_STATUS="full_validation_running"

  if [[ "${SKYBRIDGE_OS27_SKIP_IOS_GENERIC_BUILD:-0}" == "1" ]]; then
    skipped_ios_build_gates+=("generic-iOS")
  fi
  if [[ "${SKYBRIDGE_OS27_SKIP_IOS_SIMULATOR_BUILD:-0}" == "1" ]]; then
    skipped_ios_build_gates+=("iOS-Simulator")
  fi
  if [[ "${#skipped_ios_build_gates[@]}" -gt 0 ]]; then
    OS27_REPORT_STATUS="partial"
    OS27_REPORT_COMPATIBILITY="partial_not_validated"
    OS27_REPORT_SKIPPED_IOS_BUILD_GATES="${skipped_ios_build_gates[*]}"
    echo "[os27-beta-compat] partial: skipped_iOS_build_gates=${skipped_ios_build_gates[*]} compatibility=partial_not_validated"
    exit 2
  fi

  selected_developer_dir="$(pick_xcode27_developer_dir || true)"
  [[ -n "${selected_developer_dir}" ]] || fail "Xcode 27 beta is not installed. Install it side-by-side and rerun with DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer."
  [[ -d "${selected_developer_dir}" ]] || fail "DEVELOPER_DIR does not exist: $(sanitize_log_value "${selected_developer_dir}")"

  export DEVELOPER_DIR="${selected_developer_dir}"
  print_xcode27_selected_bundle_diagnostics "${selected_developer_dir}" \
    || fail "Xcode 27 beta bundle diagnostic failed"

  xcode_output="$(xcodebuild -version 2>/dev/null || true)"
  swift_output="$(xcrun swift --version 2>/dev/null || true)"
  macos_sdk="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
  iphoneos_sdk="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
  iphonesim_sdk="$(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null || true)"

  echo "[os27-beta-compat] $(flatten_output "${xcode_output}")"
  echo "[os27-beta-compat] $(head -n 1 <<<"${swift_output}")"
  echo "[os27-beta-compat] SDKs: macOS=${macos_sdk:-unknown} iphoneOS=${iphoneos_sdk:-unknown} iPhoneSimulator=${iphonesim_sdk:-unknown}"

  OS27_REPORT_XCODE_VERSION="$(head -n 1 <<<"${xcode_output:-unknown}")"
  OS27_REPORT_XCODEBUILD_BUILD="$(sed -n 's/^Build version //p' <<<"${xcode_output:-unknown}" | head -n 1)"
  OS27_REPORT_XCODEBUILD_BUILD="${OS27_REPORT_XCODEBUILD_BUILD:-unknown}"
  OS27_REPORT_SWIFT_VERSION="$(head -n 1 <<<"${swift_output:-unknown}")"
  OS27_REPORT_MACOS_SDK="${macos_sdk:-unknown}"
  OS27_REPORT_IPHONEOS_SDK="${iphoneos_sdk:-unknown}"
  OS27_REPORT_IPHONESIMULATOR_SDK="${iphonesim_sdk:-unknown}"
  record_xcode27_build_consistency
  case "${OS27_REPORT_XCODE_BUILD_CONSISTENCY}" in
    matched)
      ;;
    metadata_mismatch)
      echo "[os27-beta-compat] xcode27_build_consistency action=record_only status=metadata_mismatch compatibility=not_validated release_eligible=false"
      ;;
    *)
      fail "Xcode 27 beta bundle build consistency unavailable; status=${OS27_REPORT_XCODE_BUILD_CONSISTENCY}"
      ;;
  esac

  [[ "${xcode_output}" == Xcode\ 27* ]] || fail "expected Xcode 27 beta, got: $(flatten_output "${xcode_output}")"
  OS27_REPORT_XCODE27_READY="1"
  for sdk_name in macOS iphoneOS iPhoneSimulator; do
    case "${sdk_name}" in
      macOS) sdk_version="${macos_sdk}" ;;
      iphoneOS) sdk_version="${iphoneos_sdk}" ;;
      iPhoneSimulator) sdk_version="${iphonesim_sdk}" ;;
    esac
    sdk_major="${sdk_version%%.*}"
    [[ "${sdk_major}" == "27" ]] || fail "expected ${sdk_name} SDK 27.x, got ${sdk_version:-unknown}"
  done
  OS27_REPORT_SDK27_READY="1"

  source "${ROOT_DIR}/Scripts/apple_pqc_sdk_probe.sh"
  for pqc_sdk in macosx iphoneos iphonesimulator; do
    record_pqc_symbol_probe_result "${pqc_sdk}" "running"
    if ! skybridge_require_apple_pqc_sdk_symbol_probe "${pqc_sdk}"; then
      record_pqc_symbol_probe_result "${pqc_sdk}" "failed"
      fail "Apple PQC SDK symbol probe failed for ${pqc_sdk}: mode=${SKYBRIDGE_PQC_PROBE_MODE:-unknown}, $(sanitize_log_value "${SKYBRIDGE_PQC_PROBE_ERROR:-unknown}")"
    fi
    record_pqc_symbol_probe_result "${pqc_sdk}" "passed"
    echo "[os27-beta-compat] Apple PQC symbols verified: sdk=${SKYBRIDGE_PQC_SDK_NAME:-${pqc_sdk}} version=${SKYBRIDGE_PQC_SDK_VER:-unknown} target=${SKYBRIDGE_PQC_SWIFT_TARGET:-unknown} secureEnclave=${SKYBRIDGE_PQC_INCLUDED_SECURE_ENCLAVE:-0}"
  done
  for pqc_sdk in macosx iphoneos iphonesimulator; do
    network_tls_pqc_status="unavailable"
    record_network_tls_pqc_symbol_probe_result "${pqc_sdk}" "running"
    skybridge_detect_network_tls_pqc_sdk "${pqc_sdk}"
    if skybridge_network_tls_pqc_sdk_probe_succeeded; then
      network_tls_pqc_status="passed"
      record_network_tls_pqc_symbol_probe_result "${pqc_sdk}" "passed"
    else
      record_network_tls_pqc_symbol_probe_result "${pqc_sdk}" "unavailable"
    fi
    echo "[os27-beta-compat] Network TLS PQC public API probe: sdk=${SKYBRIDGE_NETWORK_TLS_PQC_SDK_NAME:-${pqc_sdk}} status=${network_tls_pqc_status} mode=${SKYBRIDGE_NETWORK_TLS_PQC_PROBE_MODE:-unknown} releaseEligible=false affectsCryptoSuiteSelection=false proofScope=transport_sdk_public_api_surface_only"
  done
  export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1
  configure_ios_xcodebuild_apple_pqc_gate_after_probe

  cd "${ROOT_DIR}"

  run_reported_gate OS27_REPORT_IOS_STATIC_CONFIG_STATUS "iOS static configuration gate failed" bash Scripts/check_ios_test_configuration.sh --static-only

  swiftpm_pqc_filter='SkyBridgeCoreTests.(PQCConditionalCompileTests|PQCProbeTests|ApplePQCCompatibilityTests|StrictPQCAdmissionGateTests|FallbackSemanticsParityTests|PQCSignatureProviderAutoFallbackSemanticsTests|QuantumCryptoManagerStrictPQCPolicyTests|P2PRedactionSourceContractTests|IOSRemoteDesktopMediaPathContractTests|ApplePQCSDKGateSourceContractTests|AppleDesignAPISourceContractTests|AppleAIAdvisorySourceContractTests|AppleAppIntentAuthoritySourceContractTests|AIAdvisoryBoundaryTests|MetalShaderSourceCompileContractTests)'
  ensure_swiftpm_scratch_path
  run_reported_gate OS27_REPORT_SWIFTPM_APP_BUILD_STATUS "SwiftPM OS27 app build failed clean-log gate" run_swiftpm_clean_log "SwiftPM OS27 app build" swift build --scratch-path "${OS27_SWIFTPM_SCRATCH_PATH}" --disable-automatic-resolution --disable-prefetching --product SkyBridgeCompassApp
  run_reported_gate OS27_REPORT_SWIFTPM_APP_MARKER_STATUS "SwiftPM OS27 app build did not prove HAS_APPLE_PQC_SDK" assert_os27_swiftpm_app_has_apple_pqc_compile_marker "${OS27_SWIFTPM_SCRATCH_PATH}"
  OS27_REPORT_SWIFTPM_FILTERED_TEST_FILTER="${swiftpm_pqc_filter}"
  OS27_REPORT_SWIFTPM_FILTERED_TEST_STATUS="running"
  OS27_REPORT_SOURCE_CONTRACTS_STATUS="running"
  if run_swiftpm_clean_log_test "${swiftpm_pqc_filter}"; then
    OS27_REPORT_SWIFTPM_FILTERED_TEST_STATUS="passed"
    OS27_REPORT_SOURCE_CONTRACTS_STATUS="passed"
  else
    OS27_REPORT_SWIFTPM_FILTERED_TEST_STATUS="failed"
    OS27_REPORT_SOURCE_CONTRACTS_STATUS="failed"
    fail "SwiftPM OS27 filtered test failed clean-log gate"
  fi

  if [[ "${SKYBRIDGE_OS27_SKIP_IOS_GENERIC_BUILD:-0}" != "1" ]]; then
    run_reported_gate OS27_REPORT_GENERIC_IOS_BUILD_STATUS "generic iOS build failed clean-log gate" run_xcodebuild_clean_log "generic iOS build" \
	      xcodebuild \
	      -project "SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj" \
	      -scheme "SkyBridgeCompass-iOS" \
	      -configuration Debug \
	      -destination generic/platform=iOS \
	      CODE_SIGNING_ALLOWED=NO \
	      "${OS27_IOS_XCODEBUILD_APPLE_PQC_SETTINGS[@]}" \
	      build
	  fi

  if [[ "${SKYBRIDGE_OS27_SKIP_IOS_SIMULATOR_BUILD:-0}" != "1" ]]; then
    run_reported_gate OS27_REPORT_IOS_SIMULATOR_BUILD_STATUS "iOS Simulator build failed clean-log gate" run_xcodebuild_clean_log "iOS Simulator build" \
	      xcodebuild \
	      -project "SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj" \
	      -scheme "SkyBridgeCompass-iOS" \
	      -configuration Debug \
	      -destination 'generic/platform=iOS Simulator' \
	      CODE_SIGNING_ALLOWED=NO \
	      "${OS27_IOS_XCODEBUILD_APPLE_PQC_SETTINGS[@]}" \
	      build
	  fi

  if [[ "${SKYBRIDGE_OS27_RUN_IOS_DEVICE_TESTS:-0}" == "1" ]]; then
    required_ios_device_test="${OS27_REQUIRED_IOS_DEVICE_PQC_RUNTIME_TEST}"
    requested_ios_device_test="${SKYBRIDGE_OS27_IOS_DEVICE_TEST:-}"
    OS27_REPORT_REQUIRED_IOS_DEVICE_TEST="${required_ios_device_test}"
    if [[ -n "${requested_ios_device_test}" && "${requested_ios_device_test}" != "${required_ios_device_test}" && "${SKYBRIDGE_OS27_ALLOW_ALTERNATE_DEVICE_TEST:-0}" != "1" ]]; then
      fail "iOS 27 beta runtime PQC validation must run ${required_ios_device_test}; alternate diagnostics require SKYBRIDGE_OS27_ALLOW_ALTERNATE_DEVICE_TEST=1 and run only after the required gate."
    fi
    run_reported_gate OS27_REPORT_REQUIRED_IOS_DEVICE_TEST_STATUS "iOS 27 beta device PQC runtime test failed" run_ios27_device_pqc_runtime_test "${required_ios_device_test}"
    OS27_REPORT_DEVICE_READY="1"
    if [[ -n "${requested_ios_device_test}" && "${requested_ios_device_test}" != "${required_ios_device_test}" ]]; then
      echo "[os27-beta-compat] running additional iOS 27 beta device diagnostic test: ${requested_ios_device_test}"
      OS27_REPORT_ADDITIONAL_IOS_DEVICE_TEST="${requested_ios_device_test}"
      run_reported_gate OS27_REPORT_ADDITIONAL_IOS_DEVICE_TEST_STATUS "additional iOS 27 beta device diagnostic test failed" run_ios27_device_pqc_runtime_test "${requested_ios_device_test}"
    fi
  else
    echo "[os27-beta-compat] iOS 27 beta physical-device PQC runtime tests were not run."
    if [[ "${SKYBRIDGE_OS27_ALLOW_PARTIAL_WITHOUT_DEVICE:-0}" == "1" ]]; then
      OS27_REPORT_STATUS="partial"
      OS27_REPORT_COMPATIBILITY="partial_not_validated"
      OS27_REPORT_REQUIRED_IOS_DEVICE_TEST_STATUS="skipped"
      echo "[os27-beta-compat] partial: SDK symbol probes and static/build gates passed; device runtime gate skipped by explicit diagnostic override; compatibility=partial_not_validated."
      exit 2
    fi
    fail "iOS 27 beta physical-device PQC runtime tests were not run. Set SKYBRIDGE_OS27_RUN_IOS_DEVICE_TESTS=1 for full validation or SKYBRIDGE_OS27_ALLOW_PARTIAL_WITHOUT_DEVICE=1 for non-runtime diagnostics."
  fi

  OS27_REPORT_STATUS="passed"
  OS27_REPORT_COMPATIBILITY="validated"
  OS27_REPORT_FULL_VALIDATION="1"
  OS27_REPORT_FULL_VALIDATION_PASSED="1"
  echo "[os27-beta-compat] passed"
}

parse_args "$@"
validate_os27_apple_pqc_symbol_set_override

if [[ "${OS27_COMPATIBILITY_MODE}" == "diagnose" ]]; then
  run_diagnose_environment
elif [[ "${OS27_COMPATIBILITY_MODE}" == "source-contracts" ]]; then
  run_source_contracts
else
  run_full_validation_lane
fi
