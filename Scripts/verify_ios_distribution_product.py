#!/usr/bin/env python3
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from apple_provisioning_profile import load_verified_profile

EXPECTED_ARGUMENT_COUNT = 27

# A release Widget carries only its own keychain-access-group (a Debug lab
# Widget deliberately carries none) plus the App Group container with the host
# App. It must never independently carry the host
# App's sensitive capabilities. If any of these entitlements is signed into the
# Widget it indicates a provisioning/entitlement regression that would widen the
# nested target's authority beyond its contract, so the formal proof must fail
# fast instead of silently accepting it.
WIDGET_DISALLOWED_ENTITLEMENTS = (
    "com.apple.developer.applesignin",
    "aps-environment",
    "com.apple.developer.icloud-services",
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.icloud-container-environment",
    "com.apple.developer.icloud-container-development-container-identifiers",
    "com.apple.developer.ubiquity-container-identifiers",
    "com.apple.developer.ubiquity-kvstore-identifier",
)


def entitlement_value_is_present(value) -> bool:
    """Return True when an entitlement value is meaningfully set.

    Apple tooling occasionally emits empty arrays/strings for entitlements that
    were requested but not granted; those must not count as the target holding
    the capability.
    """
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, (list, tuple, set, dict, str)):
        return len(value) > 0
    return True


def widget_signed_entitlements_conform(signed_entitlements: dict) -> bool:
    """The nested Widget must not independently hold the host App's privileged
    entitlements. Returns False if any disallowed capability is present."""
    return not any(
        entitlement_value_is_present(signed_entitlements.get(key))
        for key in WIDGET_DISALLOWED_ENTITLEMENTS
    )


def load_profile(path: Path) -> dict:
    # The formal iOS release-evidence path must reject a bare (unsigned) plist
    # and only trust profiles whose CMS signer is the Apple Provisioning Profile
    # Signing authority with a valid trust chain.
    return load_verified_profile(path, verify_authenticity=True)


def expand_tokens(value, team_identifier: str, application_prefix: str):
    replacements = {
        "$(TeamIdentifierPrefix)": f"{team_identifier}.",
        "${TeamIdentifierPrefix}": f"{team_identifier}.",
        "$(AppIdentifierPrefix)": f"{application_prefix}.",
        "${AppIdentifierPrefix}": f"{application_prefix}.",
    }
    if isinstance(value, str):
        expanded = value
        for token, replacement in replacements.items():
            expanded = expanded.replace(token, replacement)
        return expanded
    if isinstance(value, list):
        return [expand_tokens(item, team_identifier, application_prefix) for item in value]
    if isinstance(value, dict):
        return {
            key: expand_tokens(item, team_identifier, application_prefix)
            for key, item in value.items()
        }
    return value


def values_equal(expected, actual) -> bool:
    if isinstance(expected, list) and isinstance(actual, list):
        return {str(item) for item in expected} == {str(item) for item in actual}
    return expected == actual


def scalar_identifier(value) -> str:
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list) and len(value) == 1 and isinstance(value[0], str):
        return value[0].strip()
    return ""


def profile_value_covers(profile_value: str, requested: str) -> bool:
    if profile_value in {requested, "*"}:
        return True
    return profile_value.endswith(".*") and requested.startswith(profile_value[:-1])


def required_keychain_groups(
    *,
    bundle_identifier: str,
    expected_team: str,
    is_app: bool,
    configuration: str,
    lab_run: bool,
) -> set[str]:
    application_group = f"{expected_team}.{bundle_identifier}"
    if is_app:
        return {
            application_group,
            f"{expected_team}.group.com.skybridge.compass",
        }
    if lab_run and configuration == "Debug":
        return set()
    return {application_group}


def analyze_target(
    profile_path: Path,
    signed_entitlements_path: Path,
    leaf_certificate_path: Path,
    bundle_identifier: str,
    authority_class: str,
    *,
    is_app: bool,
    selected_profile_arg: str,
    signed_team: str,
    expected_team: str,
    device_identifier: str,
    expected_entitlements: dict,
    configuration: str,
    lab_run: bool,
) -> dict:
    profile = load_profile(profile_path)
    with signed_entitlements_path.open("rb") as handle:
        signed_entitlements = plistlib.load(handle)
    profile_entitlements = profile.get("Entitlements") or {}
    profile_team = scalar_identifier(profile.get("TeamIdentifier"))
    application_prefix = scalar_identifier(profile.get("ApplicationIdentifierPrefix")) or profile_team
    expected_application_identifier = f"{expected_team}.{bundle_identifier}"
    signed_application_identifier = (
        signed_entitlements.get("application-identifier")
        or signed_entitlements.get("com.apple.application-identifier")
    )
    profile_application_identifier = (
        profile_entitlements.get("application-identifier")
        or profile_entitlements.get("com.apple.application-identifier")
    )
    team_match = all(
        (
            signed_team == expected_team,
            profile_team == expected_team,
            signed_entitlements.get("com.apple.developer.team-identifier") == expected_team,
            signed_application_identifier == expected_application_identifier,
            profile_application_identifier == expected_application_identifier,
        )
    )
    expected_keychain_group_set = required_keychain_groups(
        bundle_identifier=bundle_identifier,
        expected_team=expected_team,
        is_app=is_app,
        configuration=configuration,
        lab_run=lab_run,
    )
    signed_keychain_groups = {
        str(value).strip()
        for value in signed_entitlements.get("keychain-access-groups", [])
        if isinstance(value, str) and value.strip()
    }
    profile_keychain_groups = {
        str(value).strip()
        for value in profile_entitlements.get("keychain-access-groups", [])
        if isinstance(value, str) and value.strip()
    }
    keychain_groups_verified = (
        signed_keychain_groups == expected_keychain_group_set
        and all(
            any(
                profile_value_covers(profile_value, requested)
                for profile_value in profile_keychain_groups
            )
            for requested in expected_keychain_group_set
        )
    )
    get_task_allow = (
        signed_entitlements.get("get-task-allow") is True
        or signed_entitlements.get("com.apple.security.get-task-allow") is True
        or profile_entitlements.get("get-task-allow") is True
    )
    expires = profile.get("ExpirationDate")
    now = (
        dt.datetime.now(tz=expires.tzinfo)
        if isinstance(expires, dt.datetime) and expires.tzinfo
        else dt.datetime.now()
    )
    profile_not_expired = isinstance(expires, dt.datetime) and expires > now
    profile_device_bound = device_identifier in {
        str(value).strip()
        for value in profile.get("ProvisionedDevices", [])
        if isinstance(value, str) and value.strip()
    }
    leaf_certificate = leaf_certificate_path.read_bytes()
    certificate_match = hashlib.sha256(leaf_certificate).hexdigest() in {
        hashlib.sha256(bytes(value)).hexdigest()
        for value in profile.get("DeveloperCertificates", [])
        if isinstance(value, (bytes, bytearray))
    }
    certificate_not_expired = subprocess.run(
        [
            "/usr/bin/openssl",
            "x509",
            "-inform",
            "DER",
            "-checkend",
            "0",
            "-noout",
            "-in",
            str(leaf_certificate_path),
        ],
        check=False,
        capture_output=True,
    ).returncode == 0
    certificate_trusted = subprocess.run(
        ["/usr/bin/security", "verify-cert", "-c", str(leaf_certificate_path)],
        check=False,
        capture_output=True,
    ).returncode == 0
    selected_profile_match = True
    if selected_profile_arg:
        selected_profile_path = Path(selected_profile_arg)
        selected_profile = load_profile(selected_profile_path)
        selected_profile_match = (
            isinstance(profile.get("UUID"), str)
            and profile.get("UUID") == selected_profile.get("UUID")
            and profile_path.read_bytes() == selected_profile_path.read_bytes()
        )
    if is_app:
        expanded_expected = expand_tokens(expected_entitlements, expected_team, application_prefix)
        expected_match = all(
            key in signed_entitlements and values_equal(value, signed_entitlements[key])
            for key, value in expanded_expected.items()
        )
    else:
        # The nested Widget has no external expected-entitlements manifest; its
        # contract is that it must not independently hold the host App's
        # privileged capabilities. Previously this branch was hard-coded True,
        # which meant a Widget wrongly granted iCloud/APNs/Sign in with Apple
        # would still pass the formal proof.
        expected_match = widget_signed_entitlements_conform(signed_entitlements)
    return {
        "productBundle": signed_application_identifier == expected_application_identifier,
        "platformVerified": "iOS" in (profile.get("Platform") or []),
        "teamMatch": team_match,
        "keychainGroupsVerified": keychain_groups_verified,
        "getTaskAllow": get_task_allow,
        "profileNotExpired": profile_not_expired,
        "profileDeviceBound": profile_device_bound,
        "certificateMatch": certificate_match,
        "certificateNotExpired": certificate_not_expired,
        "certificateTrusted": certificate_trusted,
        "distributionSigning": authority_class == "apple-distribution",
        "expectedEntitlementsMatch": expected_match,
        "selectedProfileMatch": selected_profile_match,
    }


def main(argv: list[str]) -> None:
    if len(argv) != EXPECTED_ARGUMENT_COUNT + 1:
        raise SystemExit(
            f"verify_ios_distribution_product.py requires {EXPECTED_ARGUMENT_COUNT} arguments"
        )

    (
        app_profile_arg,
        widget_profile_arg,
        app_signed_entitlements_arg,
        widget_signed_entitlements_arg,
        expected_entitlements_arg,
        app_leaf_certificate_arg,
        widget_leaf_certificate_arg,
        output_arg,
        signed_team_arg,
        app_bundle_identifier,
        widget_bundle_identifier,
        expected_team,
        app_authority_class,
        widget_authority_class,
        configuration,
        lab_run_arg,
        source_revision,
        source_clean_arg,
        device_identifier,
        selected_app_profile_arg,
        selected_widget_profile_arg,
        signature_verified_arg,
        product_provenance_verified_arg,
        source_repository,
        product_surface,
        swift_active_compilation_conditions_arg,
        binary_test_surface_detected_arg,
    ) = argv[1:]
    signed_team = signed_team_arg
    app_profile_path = Path(app_profile_arg)
    widget_profile_path = Path(widget_profile_arg)
    app_signed_entitlements_path = Path(app_signed_entitlements_arg)
    widget_signed_entitlements_path = Path(widget_signed_entitlements_arg)
    expected_entitlements_path = Path(expected_entitlements_arg)
    app_leaf_certificate_path = Path(app_leaf_certificate_arg)
    widget_leaf_certificate_path = Path(widget_leaf_certificate_arg)
    output_path = Path(output_arg)
    lab_run = lab_run_arg == "1"
    source_clean = source_clean_arg == "1"
    signature_verified = signature_verified_arg == "1"
    product_provenance_verified = product_provenance_verified_arg == "1"

    if binary_test_surface_detected_arg not in {"0", "1"}:
        raise RuntimeError("iOS product binary test-surface flag must be 0 or 1")
    binary_test_surface_detected = binary_test_surface_detected_arg == "1"

    repository_component_pattern = re.compile(r"[A-Za-z0-9_.-]+")
    repository_components = source_repository.split("/")
    source_repository_verified = len(repository_components) == 2 and all(
        component not in {"", ".", ".."}
        and repository_component_pattern.fullmatch(component) is not None
        for component in repository_components
    )
    source_revision_verified = re.fullmatch(r"[0-9a-f]{40}", source_revision) is not None
    if product_surface not in {"production", "testing"}:
        raise RuntimeError("iOS product surface must be production or testing")

    condition_tokens = [
        token
        for token in re.split(r"[\s,]+", swift_active_compilation_conditions_arg.strip())
        if token
    ]
    if len(condition_tokens) != len(set(condition_tokens)) or any(
        re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token) is None
        for token in condition_tokens
    ):
        raise RuntimeError("iOS product compilation-condition metadata is malformed")
    condition_set = set(condition_tokens)
    testing_compilation_condition = bool({"DEBUG", "SKYBRIDGE_TESTING"} & condition_set)
    production_product = all(
        (
            product_surface == "production",
            "HAS_APPLE_PQC_SDK" in condition_set,
            not testing_compilation_condition,
            not binary_test_surface_detected,
        )
    )

    if not lab_run and not all(
        (
            source_repository_verified,
            source_revision_verified,
            production_product,
        )
    ):
        raise RuntimeError(
            "formal iOS release-product proof requires same-repository, full-SHA, "
            "production surface without DEBUG/SKYBRIDGE_TESTING or binary test hooks"
        )

    with expected_entitlements_path.open("rb") as handle:
        expected_entitlements = plistlib.load(handle)

    app = analyze_target(
        app_profile_path,
        app_signed_entitlements_path,
        app_leaf_certificate_path,
        app_bundle_identifier,
        app_authority_class,
        is_app=True,
        selected_profile_arg=selected_app_profile_arg,
        signed_team=signed_team,
        expected_team=expected_team,
        device_identifier=device_identifier,
        expected_entitlements=expected_entitlements,
        configuration=configuration,
        lab_run=lab_run,
    )
    widget = analyze_target(
        widget_profile_path,
        widget_signed_entitlements_path,
        widget_leaf_certificate_path,
        widget_bundle_identifier,
        widget_authority_class,
        is_app=False,
        selected_profile_arg=selected_widget_profile_arg,
        signed_team=signed_team,
        expected_team=expected_team,
        device_identifier=device_identifier,
        expected_entitlements=expected_entitlements,
        configuration=configuration,
        lab_run=lab_run,
    )

    release_configuration = configuration == "Release"
    distribution_signing = app["distributionSigning"] and widget["distributionSigning"]
    get_task_allow = app["getTaskAllow"] or widget["getTaskAllow"]
    required_target_fields = (
        "productBundle",
        "platformVerified",
        "teamMatch",
        "keychainGroupsVerified",
        "profileNotExpired",
        "profileDeviceBound",
        "certificateMatch",
        "certificateNotExpired",
        "certificateTrusted",
        "expectedEntitlementsMatch",
        "selectedProfileMatch",
    )
    app_profile_verified = all(app[key] is True for key in required_target_fields)
    nested_widget_verified = all(widget[key] is True for key in required_target_fields)
    profile_verified = all(
        (
            signature_verified,
            app_profile_verified,
            nested_widget_verified,
        )
    )
    if not profile_verified:
        failed_fields = []
        if not signature_verified:
            failed_fields.append("signatureVerified")
        failed_fields.extend(
            f"app.{key}" for key in required_target_fields if app[key] is not True
        )
        failed_fields.extend(
            f"widget.{key}" for key in required_target_fields if widget[key] is not True
        )
        raise RuntimeError(
            "iOS product profile/signature proof failed: " + ",".join(failed_fields)
        )
    if not lab_run and not all(
        (
            release_configuration,
            distribution_signing,
            source_clean,
            not get_task_allow,
            product_provenance_verified,
            source_repository_verified,
            source_revision_verified,
            production_product,
        )
    ):
        raise RuntimeError("formal iOS release-product acceptance proof failed")

    proof = {
        "schemaVersion": 1,
        "configuration": configuration,
        "releaseConfiguration": release_configuration,
        "sourceClean": source_clean,
        "sourceRepository": source_repository,
        "sourceCommit": source_revision,
        "sourceRevisionRef": hashlib.sha256(source_revision.encode("ascii")).hexdigest()[:24],
        "productSurface": product_surface,
        "swiftActiveCompilationConditions": sorted(condition_set),
        "testingCompilationCondition": testing_compilation_condition,
        "binaryTestSurfaceDetected": binary_test_surface_detected,
        "productionProduct": production_product,
        "releaseProvenanceVerified": product_provenance_verified,
        "productBundle": app["productBundle"] and widget["productBundle"],
        "signatureVerified": signature_verified,
        "profileVerified": profile_verified,
        "teamMatch": app["teamMatch"] and widget["teamMatch"],
        "certificateMatch": app["certificateMatch"] and widget["certificateMatch"],
        "certificateNotExpired": app["certificateNotExpired"] and widget["certificateNotExpired"],
        "certificateTrusted": app["certificateTrusted"] and widget["certificateTrusted"],
        "profileNotExpired": app["profileNotExpired"] and widget["profileNotExpired"],
        "profileDeviceBound": app["profileDeviceBound"] and widget["profileDeviceBound"],
        "distributionSigning": distribution_signing,
        "expectedEntitlementsMatch": app["expectedEntitlementsMatch"],
        "widgetEntitlementsConform": widget["expectedEntitlementsMatch"],
        "keychainGroupsVerified": app["keychainGroupsVerified"] and widget["keychainGroupsVerified"],
        "getTaskAllow": get_task_allow,
        "nestedWidgetVerified": nested_widget_verified,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output_path.name}.", dir=output_path.parent)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", closefd=True) as handle:
            json.dump(proof, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, output_path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


if __name__ == "__main__":
    main(sys.argv)
