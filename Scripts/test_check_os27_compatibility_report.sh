#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="${ROOT_DIR}/Scripts/check_os27_compatibility_report.py"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-os27-report-check-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

write_fixture() {
  local path="$1"
  local variant="$2"
  python3 - "${path}" "${variant}" <<'PY'
import json
import sys

path = sys.argv[1]
variant = sys.argv[2]

required_test = (
    "SkyBridgeCompassiOSTests/ApplePQCProviderRuntimeSelfTestTests/"
    "testApplePQCAndXWingProbesGenerateKeysOnAvailableRuntime"
)
pqc_sdks = ("macosx", "iphoneos", "iphonesimulator")

report = {
    "schema_version": 2,
    "mode": "validate",
    "status": "passed",
    "compatibility": "validated",
    "release_eligible": False,
    "full_validation": True,
    "full_validation_attempted": True,
    "full_validation_passed": True,
    "coverage": "os27_full_lane",
    "toolchain": {
        "xcode27_ready": True,
        "sdk27_ready": True,
    },
    "xcode_beta_bundle": {
        "ready": True,
        "build_consistency": "matched",
    },
    "pqc_symbol_probes": {sdk: "passed" for sdk in pqc_sdks},
    "pqc_symbol_probe_details": {
        sdk: {
            "status": "passed",
            "mode": "symbol_probe",
            "symbol_set": "cryptokit-pqc-os27-v1",
            "proof_scope": "cryptokit_compile_time_symbol_surface_only",
            "affects_session_status": False,
            "affects_network_tls_pqc": False,
            "release_eligible": False,
        }
        for sdk in pqc_sdks
    },
    "network_tls_pqc_symbol_probe_details": {
        sdk: {
            "status": "unavailable",
            "mode": "symbol_probe_failed",
            "proof_scope": "transport_sdk_public_api_surface_only",
            "server_support_required": True,
            "session_negotiated": False,
            "affects_session_status": False,
            "affects_crypto_suite_selection": False,
            "release_eligible": False,
        }
        for sdk in pqc_sdks
    },
    "apple_quantum_secure_runtime_proof": {
        "required_device_test_identifier": required_test,
        "status": "passed",
        "proof_scope": "apple_cryptokit_runtime_self_test_only",
        "session_negotiated": False,
        "affects_network_tls_pqc": False,
        "release_eligible": False,
    },
    "gates": {
        "ios_static_configuration": "passed",
        "swiftpm_app_build": "passed",
        "swiftpm_app_apple_pqc_marker": "passed",
        "swiftpm_filtered_tests": "passed",
        "source_contracts": "passed",
        "generic_ios_build": "passed",
        "ios_simulator_build": "passed",
        "required_ios_device_test": "passed",
        "required_ios_device_test_identifier": required_test,
    },
}

if variant == "source":
    report.update(
        {
            "mode": "source-contracts",
            "status": "source_contracts_verified",
            "compatibility": "not_validated",
            "full_validation": False,
            "full_validation_attempted": False,
            "full_validation_passed": False,
            "coverage": "source_contracts_only",
        }
    )
    report["apple_quantum_secure_runtime_proof"]["status"] = "not_run"
    report["gates"].update(
        {
            "ios_static_configuration": "not_run",
            "swiftpm_app_build": "not_run",
            "swiftpm_app_apple_pqc_marker": "not_run",
            "generic_ios_build": "not_run",
            "ios_simulator_build": "not_run",
            "required_ios_device_test": "not_run",
        }
    )
elif variant == "partial":
    report.update(
        {
            "status": "partial",
            "compatibility": "partial_not_validated",
            "full_validation": False,
            "full_validation_passed": False,
        }
    )
    report["apple_quantum_secure_runtime_proof"]["status"] = "skipped"
    report["gates"]["required_ios_device_test"] = "skipped"
elif variant == "full-metadata-mismatch":
    report["xcode_beta_bundle"]["build_consistency"] = "metadata_mismatch"
elif variant == "stale-v1":
    report["schema_version"] = 1
elif variant == "wrong-symbol":
    report["pqc_symbol_probe_details"]["macosx"]["symbol_set"] = "cryptokit-pqc-v1"
elif variant == "release-eligible":
    report["release_eligible"] = True
elif variant == "network-affects-suite":
    report["network_tls_pqc_symbol_probe_details"]["macosx"]["affects_crypto_suite_selection"] = True
elif variant == "network-server-support-not-required":
    report["network_tls_pqc_symbol_probe_details"]["macosx"]["server_support_required"] = False
elif variant == "network-session-negotiated":
    report["network_tls_pqc_symbol_probe_details"]["macosx"]["session_negotiated"] = True
elif variant == "network-affects-session":
    report["network_tls_pqc_symbol_probe_details"]["macosx"]["affects_session_status"] = True
elif variant == "network-release-eligible":
    report["network_tls_pqc_symbol_probe_details"]["macosx"]["status"] = "passed"
    report["network_tls_pqc_symbol_probe_details"]["macosx"]["release_eligible"] = True
elif variant == "pqc-symbol-affects-session":
    report["pqc_symbol_probe_details"]["macosx"]["affects_session_status"] = True
elif variant == "runtime-session-negotiated":
    report["apple_quantum_secure_runtime_proof"]["session_negotiated"] = True
elif variant != "full":
    raise SystemExit(f"unknown fixture variant: {variant}")

with open(path, "w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

expect_success() {
  local label="$1"
  shift
  if ! "$@" >"${TMP_DIR}/${label}.out" 2>"${TMP_DIR}/${label}.err"; then
    echo "Expected success for ${label}" >&2
    cat "${TMP_DIR}/${label}.out" >&2 || true
    cat "${TMP_DIR}/${label}.err" >&2 || true
    exit 1
  fi
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >"${TMP_DIR}/${label}.out" 2>"${TMP_DIR}/${label}.err"; then
    echo "Expected failure for ${label}" >&2
    cat "${TMP_DIR}/${label}.out" >&2 || true
    exit 1
  fi
}

assert_contains() {
  local needle="$1"
  local haystack_file="$2"
  if ! grep -Fq -- "${needle}" "${haystack_file}"; then
    echo "Expected ${haystack_file} to contain: ${needle}" >&2
    cat "${haystack_file}" >&2
    exit 1
  fi
}

FULL_REPORT="${TMP_DIR}/full.json"
FULL_METADATA_MISMATCH_REPORT="${TMP_DIR}/full-metadata-mismatch.json"
SOURCE_REPORT="${TMP_DIR}/source.json"
PARTIAL_REPORT="${TMP_DIR}/partial.json"
STALE_V1_REPORT="${TMP_DIR}/stale-v1.json"
WRONG_SYMBOL_REPORT="${TMP_DIR}/wrong-symbol.json"
RELEASE_ELIGIBLE_REPORT="${TMP_DIR}/release-eligible.json"
NETWORK_AFFECTS_REPORT="${TMP_DIR}/network-affects.json"
NETWORK_SERVER_SUPPORT_REPORT="${TMP_DIR}/network-server-support.json"
NETWORK_SESSION_REPORT="${TMP_DIR}/network-session.json"
NETWORK_AFFECTS_SESSION_REPORT="${TMP_DIR}/network-affects-session.json"
NETWORK_RELEASE_ELIGIBLE_REPORT="${TMP_DIR}/network-release-eligible.json"
PQC_SYMBOL_AFFECTS_REPORT="${TMP_DIR}/pqc-symbol-affects.json"
RUNTIME_SESSION_REPORT="${TMP_DIR}/runtime-session.json"
MISSING_REPORT="${TMP_DIR}/missing.json"
INVALID_REPORT="${TMP_DIR}/invalid.json"

write_fixture "${FULL_REPORT}" full
write_fixture "${FULL_METADATA_MISMATCH_REPORT}" full-metadata-mismatch
write_fixture "${SOURCE_REPORT}" source
write_fixture "${PARTIAL_REPORT}" partial
write_fixture "${STALE_V1_REPORT}" stale-v1
write_fixture "${WRONG_SYMBOL_REPORT}" wrong-symbol
write_fixture "${RELEASE_ELIGIBLE_REPORT}" release-eligible
write_fixture "${NETWORK_AFFECTS_REPORT}" network-affects-suite
write_fixture "${NETWORK_SERVER_SUPPORT_REPORT}" network-server-support-not-required
write_fixture "${NETWORK_SESSION_REPORT}" network-session-negotiated
write_fixture "${NETWORK_AFFECTS_SESSION_REPORT}" network-affects-session
write_fixture "${NETWORK_RELEASE_ELIGIBLE_REPORT}" network-release-eligible
write_fixture "${PQC_SYMBOL_AFFECTS_REPORT}" pqc-symbol-affects-session
write_fixture "${RUNTIME_SESSION_REPORT}" runtime-session-negotiated
printf '{not valid json\n' >"${INVALID_REPORT}"

expect_success full-basic python3 "${CHECKER}" --allow-basic-report-shape "${FULL_REPORT}"
expect_success full-required python3 "${CHECKER}" --require-full-validation "${FULL_REPORT}"
expect_success full-metadata-mismatch-required python3 "${CHECKER}" --require-full-validation "${FULL_METADATA_MISMATCH_REPORT}"
expect_success source-required python3 "${CHECKER}" --require-source-contracts "${SOURCE_REPORT}"
expect_success partial-basic python3 "${CHECKER}" --allow-basic-report-shape "${PARTIAL_REPORT}"
expect_failure explicit-mode-required python3 "${CHECKER}" "${FULL_REPORT}"
expect_failure mutually-exclusive python3 "${CHECKER}" --require-full-validation --require-source-contracts "${FULL_REPORT}"
expect_failure missing-report python3 "${CHECKER}" --allow-basic-report-shape "${MISSING_REPORT}"
expect_failure invalid-json python3 "${CHECKER}" --allow-basic-report-shape "${INVALID_REPORT}"
assert_contains "[check-os27-compatibility-report] basic-report-shape-valid" "${TMP_DIR}/full-basic.out"
assert_contains "[check-os27-compatibility-report] full-validation-valid" "${TMP_DIR}/full-required.out"
assert_contains "[check-os27-compatibility-report] full-validation-valid" "${TMP_DIR}/full-metadata-mismatch-required.out"
assert_contains "[check-os27-compatibility-report] source-contracts-valid" "${TMP_DIR}/source-required.out"
assert_contains "[check-os27-compatibility-report] basic-report-shape-valid" "${TMP_DIR}/partial-basic.out"
assert_contains "choose exactly one" "${TMP_DIR}/explicit-mode-required.err"
assert_contains "choose exactly one" "${TMP_DIR}/mutually-exclusive.err"
assert_contains "report does not exist" "${TMP_DIR}/missing-report.err"
assert_contains "report is not valid JSON" "${TMP_DIR}/invalid-json.err"

expect_failure partial-not-full python3 "${CHECKER}" --require-full-validation "${PARTIAL_REPORT}"
expect_failure stale-v1 python3 "${CHECKER}" "${STALE_V1_REPORT}"
expect_failure wrong-symbol python3 "${CHECKER}" "${WRONG_SYMBOL_REPORT}"
expect_failure release-eligible python3 "${CHECKER}" "${RELEASE_ELIGIBLE_REPORT}"
expect_failure network-affects-suite python3 "${CHECKER}" "${NETWORK_AFFECTS_REPORT}"
expect_failure network-server-support-not-required python3 "${CHECKER}" "${NETWORK_SERVER_SUPPORT_REPORT}"
expect_failure network-session-negotiated python3 "${CHECKER}" "${NETWORK_SESSION_REPORT}"
expect_failure network-affects-session python3 "${CHECKER}" "${NETWORK_AFFECTS_SESSION_REPORT}"
expect_failure network-release-eligible python3 "${CHECKER}" "${NETWORK_RELEASE_ELIGIBLE_REPORT}"
expect_failure pqc-symbol-affects-session python3 "${CHECKER}" "${PQC_SYMBOL_AFFECTS_REPORT}"
expect_failure runtime-session-negotiated python3 "${CHECKER}" "${RUNTIME_SESSION_REPORT}"

echo "check_os27_compatibility_report tests passed"
