#!/usr/bin/env python3
"""Validate the exact verified App Store IPA before the external upload call."""

from __future__ import annotations

import argparse
import json
import re
import stat
from pathlib import Path

from ios_release_archive_identity import ArchiveIdentityError, file_sha256


DIGEST_PATTERN = re.compile(r"[0-9a-f]{64}")
SOURCE_COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
EXPECTED_TRUE_FIELDS = (
    "appStoreExportVerified",
    "samePhysicallyAcceptedArchive",
    "distributionSigning",
    "appStoreProfilesNotDeviceBound",
    "productionEntitlementsVerified",
    "debugSymbolsVerified",
)


def fail(message: str) -> "None":
    raise SystemExit(f"[ios-app-store-upload-preflight] ERROR: {message}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--export-dir", required=True, type=Path)
    parser.add_argument("--verification", required=True, type=Path)
    arguments = parser.parse_args()
    for path, label, directory in (
        (arguments.export_dir, "App Store export directory", True),
        (arguments.verification, "App Store verification", False),
    ):
        if not path.is_absolute():
            fail(f"{label} path must be absolute")
        try:
            metadata = path.lstat()
        except OSError:
            fail(f"{label} is unavailable")
        expected_type = stat.S_ISDIR if directory else stat.S_ISREG
        if stat.S_ISLNK(metadata.st_mode) or not expected_type(metadata.st_mode):
            fail(f"{label} must be a real {'directory' if directory else 'file'}")
    try:
        payload = json.loads(arguments.verification.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        fail("App Store verification is not valid UTF-8 JSON")
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        fail("App Store verification schema is unsupported")
    if not all(payload.get(key) is True for key in EXPECTED_TRUE_FIELDS):
        fail("App Store verification is missing a required successful gate")
    if payload.get("binaryTestSurfaceDetected") is not False:
        fail("App Store verification detected a test surface")
    if payload.get("productSurface") != "production" or payload.get("buildConfiguration") != "Release":
        fail("App Store verification is not a production Release product")
    if payload.get("swiftActiveCompilationConditions") != ["HAS_APPLE_PQC_SDK"]:
        fail("App Store verification compilation conditions are not production-safe")
    if SOURCE_COMMIT_PATTERN.fullmatch(str(payload.get("sourceCommit", ""))) is None:
        fail("App Store verification source commit is malformed")
    exact_values = {
        "archiveIdentityPurpose": "detect-accidental-cross-run-mismatch",
        "releaseVersion": "1.0.2",
        "releaseBuild": "2",
        "appBundleIdentifier": "com.skybridge.compass.ios",
        "widgetBundleIdentifier": "com.skybridge.compass.ios.widgets",
        "teamIdentifier": "YKUPL7Z869",
    }
    for key, expected in exact_values.items():
        if payload.get(key) != expected:
            fail(f"App Store verification {key} does not match this release")
    for key in (
        "archiveTreeSha256",
        "releaseTestingIpaSha256",
        "appStoreIpaSha256",
        "sourceInputDigest",
    ):
        if DIGEST_PATTERN.fullmatch(str(payload.get(key, ""))) is None:
            fail(f"App Store verification {key} is malformed")
    for key in ("appExecutableUUIDs", "widgetExecutableUUIDs"):
        records = payload.get(key)
        if not isinstance(records, list) or not records:
            fail(f"App Store verification {key} is missing")
        if any(
            not isinstance(record, dict)
            or set(record) != {"architecture", "uuid"}
            or not isinstance(record.get("architecture"), str)
            or re.fullmatch(r"[A-Za-z0-9_]+", record["architecture"]) is None
            or re.fullmatch(
                r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                str(record.get("uuid", "")),
            )
            is None
            for record in records
        ):
            fail(f"App Store verification {key} is malformed")
    ipas = list(arguments.export_dir.glob("*.ipa"))
    if len(ipas) != 1:
        fail("App Store export directory must contain exactly one IPA")
    try:
        ipa_sha256 = file_sha256(ipas[0], "App Store IPA")
    except ArchiveIdentityError:
        fail("App Store IPA is not an accepted regular file")
    if ipa_sha256 != payload["appStoreIpaSha256"]:
        fail("App Store IPA changed after formal verification")
    print(ipas[0].resolve(strict=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
