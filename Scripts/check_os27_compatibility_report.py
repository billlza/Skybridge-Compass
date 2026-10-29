#!/usr/bin/env python3
"""Validate OS27 beta compatibility report JSON.

The OS27 report is compatibility evidence only. It must never be accepted as
stable release eligibility, and full validation requires the physical-device
ApplePQC/X-Wing runtime proof in addition to SDK/source-contract gates.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


EXPECTED_SCHEMA_VERSION = 2
EXPECTED_OS27_SYMBOL_SET = "cryptokit-pqc-os27-v1"
EXPECTED_PQC_SYMBOL_PROOF_SCOPE = "cryptokit_compile_time_symbol_surface_only"
EXPECTED_NETWORK_PROOF_SCOPE = "transport_sdk_public_api_surface_only"
EXPECTED_APPLE_RUNTIME_PROOF_SCOPE = "apple_cryptokit_runtime_self_test_only"
REQUIRED_IOS_DEVICE_TEST = (
    "SkyBridgeCompassiOSTests/ApplePQCProviderRuntimeSelfTestTests/"
    "testApplePQCAndXWingProbesGenerateKeysOnAvailableRuntime"
)
PQC_SDKS = ("macosx", "iphoneos", "iphonesimulator")


class ReportError(Exception):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path, help="Path to OS27 compatibility report JSON")
    parser.add_argument(
        "--require-full-validation",
        action="store_true",
        help="Require current full OS27 validation, including iPadOS 27 device runtime proof.",
    )
    parser.add_argument(
        "--require-source-contracts",
        action="store_true",
        help="Require source-contract-only proof. This still is not runtime compatibility.",
    )
    parser.add_argument(
        "--allow-basic-report-shape",
        action="store_true",
        help="Only validate basic schema/proof-shape invariants. Not a compatibility gate.",
    )
    return parser.parse_args()


def load_report(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except FileNotFoundError as exc:
        raise ReportError(f"report does not exist: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ReportError(f"report is not valid JSON: {exc}") from exc

    if not isinstance(payload, dict):
        raise ReportError("report root must be a JSON object")
    return payload


def get_path(payload: dict[str, Any], dotted_path: str) -> Any:
    current: Any = payload
    for part in dotted_path.split("."):
        if not isinstance(current, dict) or part not in current:
            raise ReportError(f"missing required field: {dotted_path}")
        current = current[part]
    return current


def expect_equal(payload: dict[str, Any], dotted_path: str, expected: Any) -> None:
    actual = get_path(payload, dotted_path)
    if actual != expected:
        raise ReportError(f"{dotted_path}: expected {expected!r}, got {actual!r}")


def expect_in(payload: dict[str, Any], dotted_path: str, expected_values: set[Any]) -> None:
    actual = get_path(payload, dotted_path)
    if actual not in expected_values:
        expected = ", ".join(repr(value) for value in sorted(expected_values, key=repr))
        raise ReportError(f"{dotted_path}: expected one of {{{expected}}}, got {actual!r}")


def expect_bool_false(payload: dict[str, Any], dotted_path: str) -> None:
    actual = get_path(payload, dotted_path)
    if actual is not False:
        raise ReportError(f"{dotted_path}: expected false, got {actual!r}")


def expect_bool_true(payload: dict[str, Any], dotted_path: str) -> None:
    actual = get_path(payload, dotted_path)
    if actual is not True:
        raise ReportError(f"{dotted_path}: expected true, got {actual!r}")


def validate_basic_report(payload: dict[str, Any]) -> None:
    expect_equal(payload, "schema_version", EXPECTED_SCHEMA_VERSION)
    expect_bool_false(payload, "release_eligible")

    mode = get_path(payload, "mode")
    if mode not in {"diagnose", "source-contracts", "validate"}:
        raise ReportError(f"mode: unexpected OS27 report mode {mode!r}")

    compatibility = get_path(payload, "compatibility")
    if compatibility not in {"not_validated", "partial_not_validated", "validated"}:
        raise ReportError(f"compatibility: unexpected value {compatibility!r}")

    runtime_proof = get_path(payload, "apple_quantum_secure_runtime_proof")
    if not isinstance(runtime_proof, dict):
        raise ReportError("apple_quantum_secure_runtime_proof must be an object")
    if runtime_proof.get("proof_scope") != EXPECTED_APPLE_RUNTIME_PROOF_SCOPE:
        raise ReportError(
            "apple_quantum_secure_runtime_proof.proof_scope must remain "
            f"{EXPECTED_APPLE_RUNTIME_PROOF_SCOPE}"
        )
    if runtime_proof.get("session_negotiated") is not False:
        raise ReportError("apple_quantum_secure_runtime_proof.session_negotiated must be false")
    if runtime_proof.get("affects_network_tls_pqc") is not False:
        raise ReportError("apple_quantum_secure_runtime_proof.affects_network_tls_pqc must be false")
    if runtime_proof.get("release_eligible") is not False:
        raise ReportError("apple_quantum_secure_runtime_proof.release_eligible must be false")

    for sdk in PQC_SDKS:
        symbol_details = get_path(payload, f"pqc_symbol_probe_details.{sdk}")
        if not isinstance(symbol_details, dict):
            raise ReportError(f"pqc_symbol_probe_details.{sdk} must be an object")
        if symbol_details.get("proof_scope") != EXPECTED_PQC_SYMBOL_PROOF_SCOPE:
            raise ReportError(
                f"pqc_symbol_probe_details.{sdk}.proof_scope must remain "
                f"{EXPECTED_PQC_SYMBOL_PROOF_SCOPE}"
            )
        if symbol_details.get("affects_session_status") is not False:
            raise ReportError(f"pqc_symbol_probe_details.{sdk}.affects_session_status must be false")
        if symbol_details.get("affects_network_tls_pqc") is not False:
            raise ReportError(f"pqc_symbol_probe_details.{sdk}.affects_network_tls_pqc must be false")
        if symbol_details.get("release_eligible") is not False:
            raise ReportError(f"pqc_symbol_probe_details.{sdk}.release_eligible must be false")

        symbol_set = symbol_details.get("symbol_set")
        if symbol_set != EXPECTED_OS27_SYMBOL_SET:
            raise ReportError(
                f"pqc_symbol_probe_details.{sdk}.symbol_set: expected "
                f"{EXPECTED_OS27_SYMBOL_SET!r}, got {symbol_set!r}"
            )

        network_details = get_path(payload, f"network_tls_pqc_symbol_probe_details.{sdk}")
        if not isinstance(network_details, dict):
            raise ReportError(f"network_tls_pqc_symbol_probe_details.{sdk} must be an object")
        if network_details.get("proof_scope") != EXPECTED_NETWORK_PROOF_SCOPE:
            raise ReportError(
                f"network_tls_pqc_symbol_probe_details.{sdk}.proof_scope must remain "
                f"{EXPECTED_NETWORK_PROOF_SCOPE}"
            )
        if network_details.get("server_support_required") is not True:
            raise ReportError(
                f"network_tls_pqc_symbol_probe_details.{sdk}.server_support_required must be true"
            )
        if network_details.get("session_negotiated") is not False:
            raise ReportError(
                f"network_tls_pqc_symbol_probe_details.{sdk}.session_negotiated must be false"
            )
        if network_details.get("affects_session_status") is not False:
            raise ReportError(
                f"network_tls_pqc_symbol_probe_details.{sdk}.affects_session_status must be false"
            )
        if network_details.get("affects_crypto_suite_selection") is not False:
            raise ReportError(
                f"network_tls_pqc_symbol_probe_details.{sdk}.affects_crypto_suite_selection "
                "must be false"
            )
        if network_details.get("release_eligible") is not False:
            raise ReportError(f"network_tls_pqc_symbol_probe_details.{sdk}.release_eligible must be false")


def validate_full_report(payload: dict[str, Any]) -> None:
    validate_basic_report(payload)

    expected_scalars = {
        "mode": "validate",
        "status": "passed",
        "compatibility": "validated",
        "coverage": "os27_full_lane",
        "gates.ios_static_configuration": "passed",
        "gates.swiftpm_app_build": "passed",
        "gates.swiftpm_app_apple_pqc_marker": "passed",
        "gates.swiftpm_filtered_tests": "passed",
        "gates.source_contracts": "passed",
        "gates.generic_ios_build": "passed",
        "gates.ios_simulator_build": "passed",
        "gates.required_ios_device_test": "passed",
        "gates.required_ios_device_test_identifier": REQUIRED_IOS_DEVICE_TEST,
        "apple_quantum_secure_runtime_proof.required_device_test_identifier": REQUIRED_IOS_DEVICE_TEST,
        "apple_quantum_secure_runtime_proof.status": "passed",
        "xcode_beta_bundle.ready": True,
    }
    for path, expected in expected_scalars.items():
        expect_equal(payload, path, expected)

    expect_in(payload, "xcode_beta_bundle.build_consistency", {"matched", "metadata_mismatch"})
    expect_bool_true(payload, "full_validation")
    expect_bool_true(payload, "full_validation_attempted")
    expect_bool_true(payload, "full_validation_passed")
    expect_bool_true(payload, "toolchain.xcode27_ready")
    expect_bool_true(payload, "toolchain.sdk27_ready")
    expect_bool_false(payload, "release_eligible")

    for sdk in PQC_SDKS:
        expect_equal(payload, f"pqc_symbol_probes.{sdk}", "passed")
        expect_equal(payload, f"pqc_symbol_probe_details.{sdk}.status", "passed")
        expect_equal(payload, f"pqc_symbol_probe_details.{sdk}.mode", "symbol_probe")
        expect_equal(payload, f"pqc_symbol_probe_details.{sdk}.symbol_set", EXPECTED_OS27_SYMBOL_SET)


def validate_source_contract_report(payload: dict[str, Any]) -> None:
    validate_basic_report(payload)

    expected_scalars = {
        "mode": "source-contracts",
        "status": "source_contracts_verified",
        "compatibility": "not_validated",
        "coverage": "source_contracts_only",
        "gates.source_contracts": "passed",
        "gates.swiftpm_filtered_tests": "passed",
        "apple_quantum_secure_runtime_proof.status": "not_run",
    }
    for path, expected in expected_scalars.items():
        expect_equal(payload, path, expected)

    expect_bool_false(payload, "full_validation")
    expect_bool_false(payload, "release_eligible")


def main() -> int:
    args = parse_args()
    selected_modes = sum(
        [
            int(args.require_full_validation),
            int(args.require_source_contracts),
            int(args.allow_basic_report_shape),
        ]
    )
    if selected_modes != 1:
        print(
            "error: choose exactly one of --require-full-validation, "
            "--require-source-contracts, or --allow-basic-report-shape",
            file=sys.stderr,
        )
        return 64

    try:
        payload = load_report(args.report)
        if args.require_full_validation:
            validate_full_report(payload)
        elif args.require_source_contracts:
            validate_source_contract_report(payload)
        elif args.allow_basic_report_shape:
            validate_basic_report(payload)
    except ReportError as exc:
        print(f"[check-os27-compatibility-report] ERROR: {exc}", file=sys.stderr)
        return 1

    if args.require_full_validation:
        validation_label = "full-validation-valid"
    elif args.require_source_contracts:
        validation_label = "source-contracts-valid"
    else:
        validation_label = "basic-report-shape-valid"

    print(
        f"[check-os27-compatibility-report] {validation_label} "
        f"mode={payload.get('mode')} status={payload.get('status')} "
        f"compatibility={payload.get('compatibility')} release_eligible=false"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
