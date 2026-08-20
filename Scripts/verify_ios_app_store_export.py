#!/usr/bin/env python3
"""Verify an App Store IPA exported from the physically accepted archive."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from apple_provisioning_profile import load_verified_profile
from extract_ios_ipa import IPAValidationError, extract_single_ios_app
import ios_physical_release_acceptance as physical_acceptance
from ios_release_archive_identity import (
    APP_BUNDLE_IDENTIFIER,
    WIDGET_BUNDLE_IDENTIFIER,
    ArchiveIdentityError,
    archive_products,
    archive_tree_identity,
    bundle_executable,
    executable_uuids,
    file_sha256,
    load_identity,
)


SCHEMA_VERSION = 1
EXPECTED_TEAM = "YKUPL7Z869"
MAX_MANIFEST_BYTES = 1024 * 1024
PRODUCTION_ENTITLEMENT_VALUES: dict[str, Any] = {
    "aps-environment": "production",
    "com.apple.developer.applesignin": ["Default"],
    "com.apple.developer.icloud-container-identifiers": ["iCloud.com.skybridge.compass"],
    "com.apple.developer.icloud-container-environment": "Production",
    "com.apple.developer.icloud-services": ["CloudKit", "CloudDocuments"],
    "com.apple.developer.ubiquity-container-identifiers": ["iCloud.com.skybridge.compass"],
    "com.apple.developer.ubiquity-kvstore-identifier": f"{EXPECTED_TEAM}.com.skybridge.compass",
    "keychain-access-groups": [
        f"{EXPECTED_TEAM}.{APP_BUNDLE_IDENTIFIER}",
        f"{EXPECTED_TEAM}.group.com.skybridge.compass",
    ],
}
WIDGET_ENTITLEMENT_VALUES: dict[str, Any] = {
    "keychain-access-groups": [f"{EXPECTED_TEAM}.{WIDGET_BUNDLE_IDENTIFIER}"],
}
FORBIDDEN_ENTITLEMENTS = (
    "get-task-allow",
    "com.apple.security.get-task-allow",
)
SIGNED_IDENTITY_ENTITLEMENTS = {
    "application-identifier",
    "com.apple.developer.team-identifier",
}
OPTIONAL_SIGNED_SYSTEM_ENTITLEMENT_VALUES: dict[str, Any] = {
    "get-task-allow": False,
    "beta-reports-active": True,
}
TEST_SURFACE_PATTERN = re.compile(
    r"SKYBRIDGE_TESTING|SKYBRIDGE_SMOKE_[A-Za-z0-9_]*|"
    r"[A-Za-z0-9_]*(SmokeHarness|SmokeStatusWriter|SmokeStatusReporter|"
    r"SmokeStreamOverrides|SmokeTraceWriter)"
)


class AppStoreVerificationError(ValueError):
    pass


def _fail(message: str) -> "None":
    raise AppStoreVerificationError(message)


def _real_directory(path: Path, label: str) -> Path:
    if not path.is_absolute():
        _fail(f"{label} must be absolute")
    try:
        metadata = path.lstat()
    except OSError as error:
        _fail(f"unable to inspect {label}: {error}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        _fail(f"{label} must be a real directory")
    return path.resolve(strict=True)


def _regular_file(path: Path, label: str) -> Path:
    if not path.is_absolute():
        _fail(f"{label} must be absolute")
    try:
        metadata = path.lstat()
    except OSError as error:
        _fail(f"unable to inspect {label}: {error}")
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
    ):
        _fail(f"{label} must be a single-link regular file")
    if metadata.st_size < 1 or metadata.st_size > MAX_MANIFEST_BYTES:
        _fail(f"{label} size is outside the accepted bound")
    return path.resolve(strict=True)


def _run(args: list[str], label: str) -> bytes:
    result = subprocess.run(args, capture_output=True, check=False)
    if result.returncode != 0:
        _fail(f"{label} failed")
    return result.stdout


def _single_widget(app: Path) -> Path:
    plugins = _real_directory(app / "PlugIns", "exported app PlugIns directory")
    widgets = []
    for entry in plugins.iterdir():
        if not entry.name.endswith(".appex"):
            continue
        try:
            metadata = entry.lstat()
        except OSError as error:
            _fail(f"unable to inspect exported Widget: {error}")
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            _fail("exported Widget must be a real directory")
        widgets.append(entry.resolve(strict=True))
    if len(widgets) != 1:
        _fail("App Store IPA must contain exactly one Widget")
    return widgets[0]


def _read_plist(path: Path, label: str) -> dict[str, Any]:
    path = _regular_file(path, label)
    try:
        with path.open("rb") as handle:
            payload = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        _fail(f"{label} is not a valid property list: {error}")
    if not isinstance(payload, dict):
        _fail(f"{label} must be a property-list dictionary")
    return payload


def _signed_entitlements(bundle: Path) -> dict[str, Any]:
    payload = _run(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", "--xml", str(bundle)],
        "codesign entitlement extraction",
    )
    try:
        entitlements = plistlib.loads(payload)
    except plistlib.InvalidFileException as error:
        _fail(f"codesign emitted invalid entitlements: {error}")
    if not isinstance(entitlements, dict):
        _fail("signed entitlements must be a property-list dictionary")
    return entitlements


def _codesign_metadata(bundle: Path) -> dict[str, str]:
    result = subprocess.run(
        ["/usr/bin/codesign", "-d", "--verbose=4", str(bundle)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        _fail("codesign metadata extraction failed")
    metadata: dict[str, str] = {}
    for line in result.stderr.splitlines():
        key, separator, value = line.partition("=")
        if separator and key in {"Authority", "TeamIdentifier", "Identifier"}:
            metadata.setdefault(key, value.strip())
    return metadata


def _profile(bundle: Path) -> dict[str, Any]:
    profile_path = _regular_file(
        bundle / "embedded.mobileprovision", "App Store embedded provisioning profile"
    )
    try:
        return load_verified_profile(profile_path, verify_authenticity=True)
    except (OSError, ValueError, RuntimeError) as error:
        _fail(f"App Store provisioning profile verification failed: {error}")


def _values_equal(expected: Any, actual: Any) -> bool:
    if isinstance(expected, list) and isinstance(actual, list):
        return {str(value) for value in expected} == {str(value) for value in actual}
    return expected == actual


def _profile_value_covers(granted: Any, requested: Any) -> bool:
    if isinstance(requested, list):
        if not isinstance(granted, list):
            return False
        return all(
            any(_profile_value_covers(granted_value, requested_value) for granted_value in granted)
            for requested_value in requested
        )
    if isinstance(requested, str) and isinstance(granted, str):
        return granted in {requested, "*"} or (
            granted.endswith(".*") and requested.startswith(granted[:-1])
        )
    return granted == requested


def _certificate_matches_profile(bundle: Path, profile: dict[str, Any]) -> bool:
    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list):
        return False
    with tempfile.TemporaryDirectory(prefix="ios-app-store-cert-") as name:
        prefix = str(Path(name) / "certificate-")
        _run(
            ["/usr/bin/codesign", "--display", f"--extract-certificates={prefix}", str(bundle)],
            "codesign certificate extraction",
        )
        leaf = Path(prefix + "0")
        try:
            leaf_bytes = leaf.read_bytes()
        except OSError:
            return False
        if not leaf_bytes or not any(
            isinstance(value, (bytes, bytearray)) and bytes(value) == leaf_bytes
            for value in certificates
        ):
            return False
        if subprocess.run(
            [
                "/usr/bin/openssl",
                "x509",
                "-inform",
                "DER",
                "-checkend",
                "0",
                "-noout",
                "-in",
                str(leaf),
            ],
            capture_output=True,
            check=False,
        ).returncode != 0:
            return False
        return subprocess.run(
            ["/usr/bin/security", "verify-cert", "-c", str(leaf)],
            capture_output=True,
            check=False,
        ).returncode == 0


def _validate_target(
    *,
    label: str,
    bundle: Path,
    expected_bundle_identifier: str,
    expected_entitlements: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    _run(
        ["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(bundle)],
        f"{label} signature verification",
    )
    info = _read_plist(bundle / "Info.plist", f"{label} Info.plist")
    entitlements = _signed_entitlements(bundle)
    profile = _profile(bundle)
    metadata = _codesign_metadata(bundle)
    profile_entitlements = profile.get("Entitlements")
    if not isinstance(profile_entitlements, dict):
        _fail(f"{label} provisioning profile has no entitlements")
    application_identifier = f"{EXPECTED_TEAM}.{expected_bundle_identifier}"
    if info.get("CFBundleIdentifier") != expected_bundle_identifier:
        _fail(f"{label} bundle identifier is incorrect")
    if metadata.get("TeamIdentifier") != EXPECTED_TEAM:
        _fail(f"{label} signed team identifier is incorrect")
    if metadata.get("Identifier") != expected_bundle_identifier:
        _fail(f"{label} signed identifier is incorrect")
    if not metadata.get("Authority", "").startswith("Apple Distribution:"):
        _fail(f"{label} is not signed by Apple Distribution")
    if entitlements.get("application-identifier") != application_identifier:
        _fail(f"{label} signed application identifier is incorrect")
    if entitlements.get("com.apple.developer.team-identifier") != EXPECTED_TEAM:
        _fail(f"{label} signed team entitlement is incorrect")
    allowed_signed_entitlements = (
        SIGNED_IDENTITY_ENTITLEMENTS
        | set(OPTIONAL_SIGNED_SYSTEM_ENTITLEMENT_VALUES)
        | set(expected_entitlements)
    )
    unexpected_signed_entitlements = sorted(
        set(entitlements) - allowed_signed_entitlements
    )
    if unexpected_signed_entitlements:
        _fail(
            f"{label} enables unexpected signed entitlements: "
            + ", ".join(unexpected_signed_entitlements)
        )
    for key, expected in OPTIONAL_SIGNED_SYSTEM_ENTITLEMENT_VALUES.items():
        if key in entitlements and not _values_equal(expected, entitlements[key]):
            _fail(f"{label} signed system entitlement {key} is not release-safe")
        if (
            key == "beta-reports-active"
            and key in entitlements
            and not _profile_value_covers(profile_entitlements.get(key), expected)
        ):
            _fail(f"{label} profile does not cover signed system entitlement {key}")
    for key in FORBIDDEN_ENTITLEMENTS:
        if entitlements.get(key) is True or profile_entitlements.get(key) is True:
            _fail(f"{label} enables forbidden debugging entitlement {key}")
    for key, expected in expected_entitlements.items():
        if not _values_equal(expected, entitlements.get(key)):
            _fail(f"{label} signed entitlement {key} does not match production policy")
    if profile.get("ProvisionsAllDevices") is True:
        _fail(f"{label} App Store profile unexpectedly provisions all devices")
    if profile.get("ProvisionedDevices") not in (None, []):
        _fail(f"{label} App Store profile is unexpectedly device bound")
    if profile_entitlements.get("application-identifier") != application_identifier:
        _fail(f"{label} profile application identifier is incorrect")
    profile_team = profile.get("TeamIdentifier")
    if not (
        profile_team == EXPECTED_TEAM
        or (
            isinstance(profile_team, list)
            and profile_team == [EXPECTED_TEAM]
        )
    ):
        _fail(f"{label} profile team identifier is incorrect")
    if "iOS" not in (profile.get("Platform") or []):
        _fail(f"{label} profile platform is not iOS")
    expiration = profile.get("ExpirationDate")
    now = (
        dt.datetime.now(tz=expiration.tzinfo)
        if isinstance(expiration, dt.datetime) and expiration.tzinfo is not None
        else dt.datetime.now()
    )
    if not isinstance(expiration, dt.datetime) or expiration <= now:
        _fail(f"{label} provisioning profile is expired")
    for key, requested in expected_entitlements.items():
        if not _profile_value_covers(profile_entitlements.get(key), requested):
            _fail(f"{label} provisioning profile does not cover entitlement {key}")
    if not _certificate_matches_profile(bundle, profile):
        _fail(f"{label} signing certificate does not match a current trusted profile certificate")
    return info, entitlements, profile


def _validate_archive_product_metadata(
    *,
    identity: dict[str, Any],
    archive_app_info: dict[str, Any],
    archive_widget_info: dict[str, Any],
    app_store_app_info: dict[str, Any],
    app_store_widget_info: dict[str, Any],
) -> None:
    for label, info, expected_bundle_identifier in (
        ("archive app", archive_app_info, APP_BUNDLE_IDENTIFIER),
        ("archive Widget", archive_widget_info, WIDGET_BUNDLE_IDENTIFIER),
        ("App Store app", app_store_app_info, APP_BUNDLE_IDENTIFIER),
        ("App Store Widget", app_store_widget_info, WIDGET_BUNDLE_IDENTIFIER),
    ):
        if info.get("CFBundleIdentifier") != expected_bundle_identifier:
            _fail(f"{label} bundle identifier does not match release policy")
        if info.get("CFBundleShortVersionString") != identity["releaseVersion"]:
            _fail(f"{label} version does not match the accepted archive")
        if info.get("CFBundleVersion") != identity["releaseBuild"]:
            _fail(f"{label} build does not match the accepted archive")

    provenance_keys = (
        "SkyBridgePackagingBuildConfiguration",
        "SkyBridgePackagingGitDirtyState",
        "SkyBridgePackagingGitCommit",
        "SkyBridgePackagingSourceInputDigest",
        "SkyBridgePackagingSourceRepository",
        "SkyBridgePackagingProductSurface",
        "SkyBridgePackagingSwiftActiveCompilationConditions",
    )
    for key in provenance_keys:
        if app_store_app_info.get(key) != archive_app_info.get(key):
            _fail(f"App Store product provenance field {key} changed during export")
    expected_provenance = {
        "SkyBridgePackagingBuildConfiguration": "Release",
        "SkyBridgePackagingGitDirtyState": "clean",
        "SkyBridgePackagingGitCommit": identity["sourceCommit"],
        "SkyBridgePackagingSourceInputDigest": identity["sourceInputDigest"],
        "SkyBridgePackagingSourceRepository": identity["sourceRepository"],
        "SkyBridgePackagingProductSurface": "production",
        "SkyBridgePackagingSwiftActiveCompilationConditions": "HAS_APPLE_PQC_SDK",
    }
    for key, expected in expected_provenance.items():
        if app_store_app_info.get(key) != expected:
            _fail(f"App Store product provenance field {key} is incorrect")


def verify(
    *,
    archive: Path,
    identity_path: Path,
    physical_acceptance_path: Path,
    evidence_root: Path,
    acceptance_validator: Path,
    app_store_export_directory: Path,
    output: Path,
) -> dict[str, Any]:
    if not output.is_absolute():
        _fail("App Store verification output path must be absolute")
    _real_directory(output.parent, "App Store verification output parent")
    if os.path.lexists(output):
        _fail("App Store verification output already exists")
    identity = load_identity(identity_path)
    accepted_physical_evidence = physical_acceptance.load_acceptance(
        physical_acceptance_path, identity
    )
    current_evidence_records = physical_acceptance.collect_evidence(
        identity=identity,
        evidence_root=evidence_root,
        validator=acceptance_validator,
    )
    current_physical_evidence = physical_acceptance.validate_acceptance(
        physical_acceptance.build_acceptance(
            identity=identity,
            evidence_records=current_evidence_records,
        ),
        identity,
    )
    if physical_acceptance.canonical_bytes(
        accepted_physical_evidence
    ) != physical_acceptance.canonical_bytes(current_physical_evidence):
        _fail("physical evidence changed after its acceptance was finalized")
    actual_archive_sha256, file_count, total_bytes = archive_tree_identity(archive)
    if (
        actual_archive_sha256 != identity["archiveTreeSha256"]
        or file_count != identity["archiveFileCount"]
        or total_bytes != identity["archiveTotalBytes"]
    ):
        _fail("archive changed after physical acceptance")
    archive_app, archive_widget, archive_app_info, archive_widget_info = archive_products(archive)
    del archive_app, archive_widget

    export_directory = _real_directory(app_store_export_directory, "App Store export directory")
    with tempfile.TemporaryDirectory(prefix="ios-app-store-verify-", dir=output.parent) as name:
        work = Path(name)
        os.chmod(work, 0o700)
        try:
            app = extract_single_ios_app(export_directory, work / "SkyBridgeCompass-iOS.app")
        except IPAValidationError as error:
            _fail(f"App Store IPA extraction failed: {error}")
        widget = _single_widget(app)
        app_info, app_entitlements, app_profile = _validate_target(
            label="App Store app",
            bundle=app,
            expected_bundle_identifier=APP_BUNDLE_IDENTIFIER,
            expected_entitlements=PRODUCTION_ENTITLEMENT_VALUES,
        )
        widget_info, widget_entitlements, widget_profile = _validate_target(
            label="App Store Widget",
            bundle=widget,
            expected_bundle_identifier=WIDGET_BUNDLE_IDENTIFIER,
            expected_entitlements=WIDGET_ENTITLEMENT_VALUES,
        )
        del app_entitlements, widget_entitlements, app_profile, widget_profile
        _validate_archive_product_metadata(
            identity=identity,
            archive_app_info=archive_app_info,
            archive_widget_info=archive_widget_info,
            app_store_app_info=app_info,
            app_store_widget_info=widget_info,
        )
        app_executable = bundle_executable(app, app_info, "App Store app")
        widget_executable = bundle_executable(widget, widget_info, "App Store Widget")
        if executable_uuids(app_executable, "App Store app") != identity["appExecutableUUIDs"]:
            _fail("App Store app does not come from the physically accepted archive build")
        if (
            executable_uuids(widget_executable, "App Store Widget")
            != identity["widgetExecutableUUIDs"]
        ):
            _fail("App Store Widget does not come from the physically accepted archive build")
        for label, executable in (
            ("App Store app", app_executable),
            ("App Store Widget", widget_executable),
        ):
            strings = _run(
                ["/usr/bin/strings", "-a", str(executable)],
                f"{label} binary surface scan",
            ).decode("utf-8", "replace")
            if TEST_SURFACE_PATTERN.search(strings) is not None:
                _fail(f"{label} contains a test or smoke surface")

    ipa_candidates = list(export_directory.glob("*.ipa"))
    if len(ipa_candidates) != 1:
        _fail("App Store export directory must contain exactly one IPA")
    ipa_sha256 = file_sha256(ipa_candidates[0], "App Store IPA")
    payload = {
        "schemaVersion": SCHEMA_VERSION,
        "appStoreExportVerified": True,
        "samePhysicallyAcceptedArchive": True,
        "archiveIdentityPurpose": identity["identityPurpose"],
        "archiveTreeSha256": identity["archiveTreeSha256"],
        "releaseTestingIpaSha256": identity["releaseTestingIpaSha256"],
        "appExecutableUUIDs": identity["appExecutableUUIDs"],
        "widgetExecutableUUIDs": identity["widgetExecutableUUIDs"],
        "appStoreIpaSha256": ipa_sha256,
        "sourceRepository": identity["sourceRepository"],
        "sourceCommit": identity["sourceCommit"],
        "sourceInputDigest": identity["sourceInputDigest"],
        "releaseVersion": identity["releaseVersion"],
        "releaseBuild": identity["releaseBuild"],
        "appBundleIdentifier": APP_BUNDLE_IDENTIFIER,
        "widgetBundleIdentifier": WIDGET_BUNDLE_IDENTIFIER,
        "teamIdentifier": EXPECTED_TEAM,
        "distributionSigning": True,
        "appStoreProfilesNotDeviceBound": True,
        "productionEntitlementsVerified": True,
        "debugSymbolsVerified": identity["debugSymbolsVerified"],
        "binaryTestSurfaceDetected": False,
        "productSurface": "production",
        "buildConfiguration": "Release",
        "swiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
    }
    return payload


def _write_new(path: Path, payload: dict[str, Any]) -> None:
    if not path.is_absolute():
        _fail("App Store verification output path must be absolute")
    parent = _real_directory(path.parent, "App Store verification output parent")
    if os.path.lexists(path):
        _fail("App Store verification output already exists")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", closefd=True) as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_descriptor = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary.exists():
            temporary.unlink()


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--identity", required=True, type=Path)
    parser.add_argument("--physical-acceptance", required=True, type=Path)
    parser.add_argument("--evidence-root", required=True, type=Path)
    parser.add_argument(
        "--acceptance-validator",
        type=Path,
        default=Path(__file__).resolve().parent
        / "validate_real_device_release_acceptance_artifact.py",
    )
    parser.add_argument("--app-store-export-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = _parse_args()
    try:
        payload = verify(
            archive=arguments.archive,
            identity_path=arguments.identity,
            physical_acceptance_path=arguments.physical_acceptance,
            evidence_root=arguments.evidence_root,
            acceptance_validator=arguments.acceptance_validator,
            app_store_export_directory=arguments.app_store_export_dir,
            output=arguments.output,
        )
        _write_new(arguments.output, payload)
        print("ios_app_store_export=verified")
        print(f"verification={arguments.output}")
        return 0
    except (
        ArchiveIdentityError,
        physical_acceptance.PhysicalAcceptanceError,
        AppStoreVerificationError,
    ) as error:
        raise SystemExit(f"[ios-app-store-verify] ERROR: {error}") from error


if __name__ == "__main__":
    raise SystemExit(main())
