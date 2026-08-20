#!/usr/bin/env python3
"""Formal acceptance verification + SHA sealing for the iOS release candidate.

Consumes the IPA produced by Scripts/build_ios_release_candidate.sh and runs the
repository product verifier (Scripts/verify_ios_distribution_product.py) in
FORMAL mode (not lab): it requires a Release configuration, clean source,
production surface, Apple Distribution signing, a device-bound embedded profile
that is byte-identical to an installed profile, and matching build provenance.

On success it writes an acceptance manifest with acceptanceEligible=true and the
IPA + proof SHA-256 digests.

Never prints device UDIDs/serials/names or raw profile contents.
"""
from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from extract_ios_ipa import IPAValidationError, extract_single_ios_app
from devicectl_device_selection import installable_physical_ios_profile_identifiers

ROOT = Path(__file__).resolve().parent.parent
TEAM = "YKUPL7Z869"
APP_BUNDLE_ID = "com.skybridge.compass.ios"
WIDGET_BUNDLE_ID = "com.skybridge.compass.ios.widgets"
VERIFIER = ROOT / "Scripts" / "verify_ios_distribution_product.py"
EXPECTED_ENTITLEMENTS = ROOT / "SkyBridge Compass iOS" / "SkyBridgeCompass-iOSRelease.entitlements"
SOURCE_INPUT_PATHS = (
    "Package.swift",
    "Package.resolved",
    "project.yml",
    "Config",
    "Sources",
    "Scripts",
    "Packages",
    "SkyBridge Compass iOS",
)

EXPORT_DIR = Path(
    os.environ.get(
        "SKYBRIDGE_RC_EXPORT_DIR",
        ROOT / ".sandbox-home" / "release-candidate" / "export",
    )
)
OUTPUT_MANIFEST = Path(
    os.environ.get(
        "SKYBRIDGE_RC_ACCEPTANCE_MANIFEST",
        ROOT / ".sandbox-home" / "release-candidate" / "ios-release-acceptance-sha256.json",
    )
)


def fail(message: str) -> "None":
    raise SystemExit(f"[rc-verify] ERROR: {message}")


def run(args, **kwargs) -> bytes:
    result = subprocess.run(args, capture_output=True, check=False, **kwargs)
    if result.returncode != 0:
        detail = (result.stderr or b"").decode("utf-8", "replace")
        detail = detail.replace(str(ROOT), "<repo>").strip()[:400]
        fail(f"command failed: {Path(str(args[0])).name}: {detail}")
    return result.stdout


def connected_target_udids() -> set[str]:
    """UDIDs of currently connected/paired iPad devices, from devicectl JSON.

    The acceptance target is the physical iPad (matching the device test lane's
    SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 selection). Restricting to iPad avoids an
    ambiguous match when other registered devices (e.g. an iPhone) are also
    connected and present in the release-testing profile's device list.
    """
    target = os.environ.get("SKYBRIDGE_RC_TARGET_PRODUCT_PREFIX", "iPad")
    with tempfile.NamedTemporaryFile(suffix=".json") as handle:
        subprocess.run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", handle.name],
            check=False,
            capture_output=True,
        )
        try:
            data = json.loads(Path(handle.name).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return set()
    return installable_physical_ios_profile_identifiers(
        data,
        product_prefix=target,
    )


def installed_byte_identical(profile_bytes: bytes) -> Path:
    matches = []
    for root in (
        Path.home() / "Library/MobileDevice/Provisioning Profiles",
        Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
    ):
        if not root.is_dir():
            continue
        for candidate in root.iterdir():
            try:
                if (
                    candidate.is_file()
                    and not candidate.is_symlink()
                    and candidate.read_bytes() == profile_bytes
                ):
                    matches.append(candidate)
            except OSError:
                continue
    if len(matches) != 1:
        fail("embedded profile does not have exactly one installed byte-identical copy")
    return matches[0]


def codesign_metadata(bundle: Path) -> str:
    result = subprocess.run(
        ["/usr/bin/codesign", "-d", "--verbose=4", str(bundle)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        fail("codesign metadata unavailable")
    return result.stderr


def main() -> int:
    ipas = list(EXPORT_DIR.glob("*.ipa"))
    if len(ipas) != 1:
        fail(f"expected exactly one IPA in {EXPORT_DIR}")
    ipa_path = ipas[0]

    scratch_root = OUTPUT_MANIFEST.parent
    scratch_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rc-verify-", dir=scratch_root) as name:
        work = Path(name)
        os.chmod(work, 0o700)
        extracted_app = work / "SkyBridgeCompass-iOS.app"
        try:
            app = extract_single_ios_app(EXPORT_DIR, extracted_app)
        except IPAValidationError as error:
            fail(f"formal IPA extraction rejected the release candidate: {error}")
        widgets = list((app / "PlugIns").glob("*.appex"))
        if len(widgets) != 1:
            fail("invalid Widget count in IPA")
        widget = widgets[0]
        app_profile = app / "embedded.mobileprovision"
        widget_profile = widget / "embedded.mobileprovision"

        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
        run(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(widget)])

        app_ent = work / "app-entitlements.plist"
        widget_ent = work / "widget-entitlements.plist"
        app_ent.write_bytes(run(["/usr/bin/codesign", "-d", "--entitlements", ":-", "--xml", str(app)]))
        widget_ent.write_bytes(run(["/usr/bin/codesign", "-d", "--entitlements", ":-", "--xml", str(widget)]))

        app_prefix = str(work / "app-cert-")
        widget_prefix = str(work / "widget-cert-")
        run(["/usr/bin/codesign", "--display", f"--extract-certificates={app_prefix}", str(app)])
        run(["/usr/bin/codesign", "--display", f"--extract-certificates={widget_prefix}", str(widget)])

        app_info = plistlib.loads((app / "Info.plist").read_bytes())
        widget_info = plistlib.loads((widget / "Info.plist").read_bytes())
        source_app_info = plistlib.loads(
            (ROOT / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Supporting Files/Info.plist").read_bytes()
        )
        source_widget_info = plistlib.loads(
            (ROOT / "SkyBridge Compass iOS/Widgets/Info.plist").read_bytes()
        )
        expected_version = source_app_info.get("CFBundleShortVersionString")
        expected_build = source_app_info.get("CFBundleVersion")
        if not isinstance(expected_version, str) or re.fullmatch(
            r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)",
            expected_version,
        ) is None:
            fail("source iOS version is not strict semantic version text")
        if not isinstance(expected_build, str) or re.fullmatch(r"[1-9][0-9]*", expected_build) is None:
            fail("source iOS build is not a positive integer")
        for label, info in (
            ("source Widget", source_widget_info),
            ("exported app", app_info),
            ("exported Widget", widget_info),
        ):
            if info.get("CFBundleShortVersionString") != expected_version:
                fail(f"{label} version does not match the source release version")
            if info.get("CFBundleVersion") != expected_build:
                fail(f"{label} build does not match the source release build")
        executable = app / app_info["CFBundleExecutable"]
        strings_out = run(["/usr/bin/strings", "-a", str(executable)]).decode("utf-8", "replace")
        binary_test = bool(
            re.search(
                r"SKYBRIDGE_TESTING|SKYBRIDGE_SMOKE_[A-Za-z0-9_]*|"
                r"[A-Za-z0-9_]*(SmokeHarness|SmokeStatusWriter|SmokeStatusReporter|SmokeStreamOverrides|SmokeTraceWriter)",
                strings_out,
            )
        )
        if binary_test:
            fail("production IPA unexpectedly contains a test/smoke surface")

        app_meta = codesign_metadata(app)
        signed_team = re.search(r"^TeamIdentifier=(.+)$", app_meta, re.M).group(1)

        # Device binding: the embedded profile must bind the connected iPad.
        profile_payload = plistlib.loads(
            run(["/usr/bin/security", "cms", "-D", "-i", str(app_profile)])
        )
        provisioned = {
            str(v).strip()
            for v in (profile_payload.get("ProvisionedDevices") or [])
            if str(v).strip()
        }
        target_devices = provisioned & connected_target_udids()
        if len(target_devices) != 1:
            fail(
                "release-candidate profile does not uniquely bind the connected device "
                f"(intersection size {len(target_devices)})"
            )
        device_identifier = next(iter(target_devices))

        head = run(["git", "rev-parse", "HEAD"], cwd=ROOT).decode().strip()
        source_repository = app_info.get("SkyBridgePackagingSourceRepository", "")
        provenance_ok = all(
            (
                app_info.get("SkyBridgePackagingBuildConfiguration") == "Release",
                app_info.get("SkyBridgePackagingGitDirtyState") == "clean",
                app_info.get("SkyBridgePackagingGitCommit") == head,
                app_info.get("SkyBridgePackagingProductSurface") == "production",
                app_info.get("SkyBridgePackagingSwiftActiveCompilationConditions") == "HAS_APPLE_PQC_SDK",
                bool(source_repository),
            )
        )
        digest_result = subprocess.run(
            [
                "python3",
                str(ROOT / "Scripts/source_input_digest.py"),
                "--root",
                str(ROOT),
                *SOURCE_INPUT_PATHS,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        digest_parts = digest_result.stdout.strip().split()
        if (
            digest_result.returncode != 0
            or len(digest_parts) != 2
            or re.fullmatch(r"[0-9a-f]{64}", digest_parts[0]) is None
            or re.fullmatch(r"[1-9][0-9]*", digest_parts[1]) is None
        ):
            fail("unable to compute final iOS release source-input digest")
        source_input_digest = digest_parts[0]
        if app_info.get("SkyBridgePackagingSourceInputDigest") != source_input_digest:
            fail("release-candidate source-input digest does not match current clean source")
        if not provenance_ok:
            fail("release-candidate build provenance metadata does not match clean HEAD")

        proof_path = scratch_root / "ios-release-candidate-product-proof.json"
        verifier_args = [
            "python3", str(VERIFIER),
            str(app_profile), str(widget_profile), str(app_ent), str(widget_ent),
            str(EXPECTED_ENTITLEMENTS), app_prefix + "0", widget_prefix + "0",
            str(proof_path), signed_team, APP_BUNDLE_ID, WIDGET_BUNDLE_ID, TEAM,
            "apple-distribution", "apple-distribution", "Release",
            "0",                # lab_run = formal
            head,               # source_revision
            "1",                # source_clean
            device_identifier,
            str(installed_byte_identical(app_profile.read_bytes())),
            str(installed_byte_identical(widget_profile.read_bytes())),
            "1",                # signature_verified
            "1",                # product_provenance_verified
            source_repository, "production", "HAS_APPLE_PQC_SDK", "0",
            str(app / "Info.plist"), str(widget / "Info.plist"),
        ]
        result = subprocess.run(verifier_args, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "").replace(str(ROOT), "<repo>").strip()[:400]
            fail(f"formal product verifier rejected the release candidate: {detail}")

        proof = json.loads(proof_path.read_text())
        required_true = [
            "releaseConfiguration", "sourceClean", "productionProduct", "productBundle",
            "signatureVerified", "profileVerified", "teamMatch", "certificateMatch",
            "certificateNotExpired", "certificateTrusted", "profileNotExpired",
            "profileDeviceBound", "distributionSigning", "expectedEntitlementsMatch",
            "widgetEntitlementsConform", "keychainGroupsVerified", "nestedWidgetVerified",
            "releaseProvenanceVerified",
            "releaseVersionVerified",
        ]
        if not all(proof.get(k) is True for k in required_true):
            missing = [k for k in required_true if proof.get(k) is not True]
            fail(f"product proof missing required true fields: {missing}")
        if proof.get("getTaskAllow") is not False:
            fail("product proof getTaskAllow must be false")

        ipa_sha = hashlib.sha256(ipa_path.read_bytes()).hexdigest()
        proof_sha = hashlib.sha256(proof_path.read_bytes()).hexdigest()
        manifest = {
            "schemaVersion": 1,
            "acceptanceEligible": True,
            "sourceCommit": head,
            "sourceClean": True,
            "sourceRepository": source_repository,
            "productSurface": "production",
            "releaseConfiguration": True,
            "distributionSigning": True,
            "releaseVersion": proof["releaseVersion"],
            "releaseBuild": proof["releaseBuild"],
            "releaseVersionVerified": True,
            "sourceInputDigest": source_input_digest,
            "ipaSha256": ipa_sha,
            "productProofSha256": proof_sha,
            "productProofPath": proof_path.name,
        }
        descriptor, tmp_name = tempfile.mkstemp(prefix=f".{OUTPUT_MANIFEST.name}.", dir=OUTPUT_MANIFEST.parent)
        tmp_path = Path(tmp_name)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8", closefd=True) as fh:
                json.dump(manifest, fh, indent=2, sort_keys=True)
                fh.write("\n")
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp_path, OUTPUT_MANIFEST)
        finally:
            if tmp_path.exists():
                tmp_path.unlink()

    print("release_candidate_acceptance=pass")
    print(f"ipa_sha256={ipa_sha}")
    print(f"acceptance_manifest={OUTPUT_MANIFEST}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
