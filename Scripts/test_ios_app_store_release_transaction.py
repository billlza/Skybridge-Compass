#!/usr/bin/env python3

from __future__ import annotations

import datetime as dt
import hashlib
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

import ios_physical_release_acceptance as physical
import ios_release_archive_identity as archive_identity
import validate_real_device_release_acceptance_artifact as release_validator
import verify_ios_app_store_export as app_store_verifier


SOURCE_REPOSITORY = "billlza/Skybridge-Compass"
SOURCE_COMMIT = "1" * 40
SOURCE_INPUT_DIGEST = "2" * 64
VERSION = "1.0.2"
BUILD = "2"
APP_UUIDS = [
    {"architecture": "arm64", "uuid": "11111111-1111-1111-1111-111111111111"}
]
WIDGET_UUIDS = [
    {"architecture": "arm64", "uuid": "22222222-2222-2222-2222-222222222222"}
]


def write_plist(path: Path, payload: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(payload))


def app_info(bundle_identifier: str, executable: str) -> dict:
    payload = {
        "CFBundleIdentifier": bundle_identifier,
        "CFBundleShortVersionString": VERSION,
        "CFBundleVersion": BUILD,
        "CFBundleExecutable": executable,
    }
    if bundle_identifier == archive_identity.APP_BUNDLE_IDENTIFIER:
        payload.update(
            {
                "SkyBridgePackagingBuildConfiguration": "Release",
                "SkyBridgePackagingGitDirtyState": "clean",
                "SkyBridgePackagingGitCommit": SOURCE_COMMIT,
                "SkyBridgePackagingSourceInputDigest": SOURCE_INPUT_DIGEST,
                "SkyBridgePackagingSourceRepository": SOURCE_REPOSITORY,
                "SkyBridgePackagingProductSurface": "production",
                "SkyBridgePackagingSwiftActiveCompilationConditions": "HAS_APPLE_PQC_SDK",
            }
        )
    return payload


class ArchiveIdentityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive = self.root / "SkyBridgeCompass-iOS.xcarchive"
        self.app = self.archive / "Products/Applications/SkyBridgeCompass-iOS.app"
        self.widget = self.app / "PlugIns/SkyBridgeCompass-Widgets.appex"
        write_plist(
            self.app / "Info.plist",
            app_info(archive_identity.APP_BUNDLE_IDENTIFIER, "SkyBridgeCompass-iOS"),
        )
        write_plist(
            self.widget / "Info.plist",
            app_info(archive_identity.WIDGET_BUNDLE_IDENTIFIER, "SkyBridgeCompass-Widgets"),
        )
        (self.app / "SkyBridgeCompass-iOS").write_bytes(b"app-binary")
        (self.widget / "SkyBridgeCompass-Widgets").write_bytes(b"widget-binary")
        (self.app / "SkyBridgeCompass-iOS").chmod(0o755)
        (self.widget / "SkyBridgeCompass-Widgets").chmod(0o755)
        self.export = self.root / "export"
        self.export.mkdir(mode=0o700)
        self.ipa = self.export / "SkyBridgeCompass-iOS.ipa"
        self.ipa.write_bytes(b"release-testing-ipa")
        self.acceptance = self.root / "ios-release-acceptance-sha256.json"
        self.acceptance.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "acceptanceEligible": True,
                    "sourceCommit": SOURCE_COMMIT,
                    "sourceClean": True,
                    "sourceRepository": SOURCE_REPOSITORY,
                    "sourceInputDigest": SOURCE_INPUT_DIGEST,
                    "productSurface": "production",
                    "releaseConfiguration": True,
                    "distributionSigning": True,
                    "releaseVersion": VERSION,
                    "releaseBuild": BUILD,
                    "releaseVersionVerified": True,
                    "ipaSha256": hashlib.sha256(self.ipa.read_bytes()).hexdigest(),
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def build(
        self, release_app_uuids: list[dict[str, str]] | None = None
    ) -> dict:
        selected_release_app_uuids = (
            APP_UUIDS if release_app_uuids is None else release_app_uuids
        )
        def fake_uuids(executable: Path, _label: str) -> list[dict[str, str]]:
            if executable.name == "SkyBridgeCompass-iOS":
                return APP_UUIDS
            return WIDGET_UUIDS

        with (
            mock.patch.object(
                archive_identity,
                "release_testing_products",
                return_value=(
                    app_info(archive_identity.APP_BUNDLE_IDENTIFIER, "SkyBridgeCompass-iOS"),
                    app_info(archive_identity.WIDGET_BUNDLE_IDENTIFIER, "SkyBridgeCompass-Widgets"),
                    selected_release_app_uuids,
                    WIDGET_UUIDS,
                ),
            ),
            mock.patch.object(archive_identity, "executable_uuids", side_effect=fake_uuids),
            mock.patch.object(archive_identity, "archive_debug_symbols"),
        ):
            return archive_identity.build_identity(
                archive=self.archive,
                release_testing_export_directory=self.export,
                release_testing_acceptance_path=self.acceptance,
                expected_version=VERSION,
                expected_build=BUILD,
                expected_repository=SOURCE_REPOSITORY,
                expected_commit=SOURCE_COMMIT,
            )

    def test_build_write_load_and_recompute_exact_identity(self) -> None:
        payload = self.build()
        identity_path = self.root / "identity.json"
        archive_identity.write_identity(identity_path, payload)
        self.assertEqual(archive_identity.load_identity(identity_path), payload)
        self.assertEqual(self.build(), payload)
        self.assertEqual(payload["identityPurpose"], "detect-accidental-cross-run-mismatch")

    def test_archive_or_release_testing_ipa_change_is_rejected(self) -> None:
        before = self.build()
        (self.app / "SkyBridgeCompass-iOS").write_bytes(b"changed-app-binary")
        self.assertNotEqual(self.build()["archiveTreeSha256"], before["archiveTreeSha256"])
        (self.app / "SkyBridgeCompass-iOS").write_bytes(b"app-binary")
        self.ipa.write_bytes(b"changed-release-testing-ipa")
        with self.assertRaises(archive_identity.ArchiveIdentityError):
            self.build()

    def test_rejects_links_and_mismatched_product_provenance(self) -> None:
        linked = self.app / "linked"
        linked.symlink_to(self.app / "SkyBridgeCompass-iOS")
        with self.assertRaises(archive_identity.ArchiveIdentityError):
            self.build()
        linked.unlink()
        info = app_info(archive_identity.APP_BUNDLE_IDENTIFIER, "SkyBridgeCompass-iOS")
        info["SkyBridgePackagingProductSurface"] = "testing"
        write_plist(self.app / "Info.plist", info)
        with self.assertRaises(archive_identity.ArchiveIdentityError):
            self.build()

    def test_rejects_release_testing_ipa_from_another_archive_build(self) -> None:
        mismatched = [
            {
                "architecture": "arm64",
                "uuid": "33333333-3333-3333-3333-333333333333",
            }
        ]
        with self.assertRaises(archive_identity.ArchiveIdentityError):
            self.build(release_app_uuids=mismatched)

    def test_app_and_widget_dsym_uuids_must_match_executables(self) -> None:
        app_dwarf = (
            self.archive
            / "dSYMs/SkyBridgeCompass-iOS.app.dSYM/Contents/Resources/DWARF/SkyBridgeCompass-iOS"
        )
        widget_dwarf = (
            self.archive
            / "dSYMs/SkyBridgeCompass-Widgets.appex.dSYM/Contents/Resources/DWARF/SkyBridgeCompass-Widgets"
        )
        app_dwarf.parent.mkdir(mode=0o700, parents=True)
        widget_dwarf.parent.mkdir(mode=0o700, parents=True)
        app_dwarf.write_bytes(b"app-dwarf")
        widget_dwarf.write_bytes(b"widget-dwarf")

        def matching_uuids(executable: Path, _label: str) -> list[dict[str, str]]:
            return (
                APP_UUIDS
                if "SkyBridgeCompass-iOS.app.dSYM" in executable.parts
                else WIDGET_UUIDS
            )

        with mock.patch.object(
            archive_identity, "executable_uuids", side_effect=matching_uuids
        ):
            archive_identity.archive_debug_symbols(
                archive=self.archive,
                app=self.app,
                widget=self.widget,
                app_uuids=APP_UUIDS,
                widget_uuids=WIDGET_UUIDS,
            )

        with (
            mock.patch.object(archive_identity, "executable_uuids", return_value=APP_UUIDS),
            self.assertRaises(archive_identity.ArchiveIdentityError),
        ):
            archive_identity.archive_debug_symbols(
                archive=self.archive,
                app=self.app,
                widget=self.widget,
                app_uuids=APP_UUIDS,
                widget_uuids=WIDGET_UUIDS,
            )


class PhysicalAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.release_testing_ipa = self.root / "release-testing.ipa"
        self.release_testing_ipa.write_bytes(b"sealed-release-testing-ipa")
        self.identity_payload = archive_identity.validate_identity(
            {
                "schemaVersion": 1,
                "identityPurpose": archive_identity.IDENTITY_PURPOSE,
                "archiveTreeSha256": "3" * 64,
                "archiveFileCount": 12,
                "archiveTotalBytes": 8192,
                "appExecutableUUIDs": APP_UUIDS,
                "widgetExecutableUUIDs": WIDGET_UUIDS,
                "debugSymbolsVerified": True,
                "releaseTestingIpaSha256": hashlib.sha256(
                    self.release_testing_ipa.read_bytes()
                ).hexdigest(),
                "sourceRepository": SOURCE_REPOSITORY,
                "sourceCommit": SOURCE_COMMIT,
                "sourceInputDigest": SOURCE_INPUT_DIGEST,
                "releaseVersion": VERSION,
                "releaseBuild": BUILD,
                "appBundleIdentifier": archive_identity.APP_BUNDLE_IDENTIFIER,
                "widgetBundleIdentifier": archive_identity.WIDGET_BUNDLE_IDENTIFIER,
                "productSurface": "production",
                "buildConfiguration": "Release",
                "swiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
            }
        )
        self.identity_path = self.root / "identity.json"
        self.identity_path.write_bytes(archive_identity.canonical_bytes(self.identity_payload))
        self.evidence_root = self.root / "evidence"
        self.evidence_root.mkdir(mode=0o700)
        binding = physical.expected_binding(self.identity_payload)
        for kind, directory_name in physical.EVIDENCE_CONTRACT:
            directory = self.evidence_root / directory_name
            directory.mkdir(mode=0o700)
            (directory / "release-acceptance.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "acceptanceEligible": True,
                        "transport": kind,
                        "sourceRepository": SOURCE_REPOSITORY,
                        "sourceCommit": SOURCE_COMMIT,
                        "iosReleaseArchive": binding,
                    },
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
        self.validator = self.root / "validator.py"
        self.validator.write_text("raise SystemExit(0)\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def collect(self) -> list[dict[str, str]]:
        return physical.collect_evidence(
            identity=self.identity_payload,
            evidence_root=self.evidence_root,
            validator=self.validator,
        )

    def test_create_and_verify_exact_four_evidence_records(self) -> None:
        records = self.collect()
        payload = physical.validate_acceptance(
            physical.build_acceptance(identity=self.identity_payload, evidence_records=records),
            self.identity_payload,
        )
        output = self.root / "physical.json"
        physical._write_new(output, payload)
        self.assertEqual(physical.load_acceptance(output, self.identity_payload), payload)

    def test_missing_archive_binding_or_changed_manifest_is_rejected(self) -> None:
        records = self.collect()
        directory = self.evidence_root / physical.EVIDENCE_CONTRACT[0][1]
        manifest_path = directory / "release-acceptance.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest.pop("iosReleaseArchive")
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaises(physical.PhysicalAcceptanceError):
            self.collect()
        self.assertEqual(len(records), 4)

    def test_all_four_evidence_bindings_must_be_identical(self) -> None:
        for _, directory_name in physical.EVIDENCE_CONTRACT:
            with self.subTest(directory=directory_name):
                manifest_path = self.evidence_root / directory_name / "release-acceptance.json"
                original = manifest_path.read_bytes()
                manifest = json.loads(original)
                manifest["iosReleaseArchive"]["releaseBuild"] = "3"
                manifest_path.write_text(
                    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
                with self.assertRaises(physical.PhysicalAcceptanceError):
                    self.collect()
                manifest_path.write_bytes(original)

    def test_release_testing_ipa_replacement_is_rejected(self) -> None:
        self.assertEqual(
            archive_identity.validate_release_testing_ipa(
                self.identity_payload, self.release_testing_ipa
            ),
            self.release_testing_ipa.resolve(),
        )
        self.release_testing_ipa.write_bytes(b"substituted-release-testing-ipa")
        with self.assertRaises(archive_identity.ArchiveIdentityError):
            archive_identity.validate_release_testing_ipa(
                self.identity_payload, self.release_testing_ipa
            )

    def test_bind_manifest_rejects_wrong_identity_and_preserves_exact_binding(self) -> None:
        manifest_path = (
            self.evidence_root
            / physical.EVIDENCE_CONTRACT[0][1]
            / "pre-cleanup-release-acceptance.json"
        )
        manifest_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "acceptanceEligible": False,
                    "cleanupComplete": False,
                    "diagnosticOnly": True,
                    "preCleanupCandidate": True,
                }
            )
            + "\n",
            encoding="utf-8",
        )
        manifest_path.chmod(0o600)
        bound = physical.bind_release_manifest(
            identity=self.identity_payload,
            manifest_path=manifest_path,
        )
        self.assertEqual(
            bound["iosReleaseArchive"], physical.expected_binding(self.identity_payload)
        )
        different = dict(self.identity_payload)
        different["archiveTreeSha256"] = "9" * 64
        with self.assertRaises(physical.PhysicalAcceptanceError):
            physical.bind_release_manifest(
                identity=archive_identity.validate_identity(different),
                manifest_path=manifest_path,
            )

    def test_formal_validator_rejects_a_different_archive_binding(self) -> None:
        manifest = {"iosReleaseArchive": physical.expected_binding(self.identity_payload)}
        release_validator.validate_ios_release_archive_binding(
            manifest,
            self.identity_path,
            self.release_testing_ipa,
        )
        manifest["iosReleaseArchive"]["archiveTreeSha256"] = "9" * 64
        with self.assertRaises(SystemExit):
            release_validator.validate_ios_release_archive_binding(
                manifest,
                self.identity_path,
                self.release_testing_ipa,
            )

    def test_formal_validator_failure_is_not_ignored(self) -> None:
        self.validator.write_text("raise SystemExit(7)\n", encoding="utf-8")
        with self.assertRaises(physical.PhysicalAcceptanceError):
            self.collect()


class AppStoreProductPolicyTests(unittest.TestCase):
    def test_archive_and_exported_metadata_must_match(self) -> None:
        identity = {
            "releaseVersion": VERSION,
            "releaseBuild": BUILD,
            "sourceCommit": SOURCE_COMMIT,
            "sourceInputDigest": SOURCE_INPUT_DIGEST,
            "sourceRepository": SOURCE_REPOSITORY,
        }
        archive_app = app_info(archive_identity.APP_BUNDLE_IDENTIFIER, "App")
        archive_widget = app_info(archive_identity.WIDGET_BUNDLE_IDENTIFIER, "Widget")
        app_store_verifier._validate_archive_product_metadata(
            identity=identity,
            archive_app_info=archive_app,
            archive_widget_info=archive_widget,
            app_store_app_info=dict(archive_app),
            app_store_widget_info=dict(archive_widget),
        )
        changed = dict(archive_app)
        changed["CFBundleVersion"] = "3"
        with self.assertRaises(app_store_verifier.AppStoreVerificationError):
            app_store_verifier._validate_archive_product_metadata(
                identity=identity,
                archive_app_info=archive_app,
                archive_widget_info=archive_widget,
                app_store_app_info=changed,
                app_store_widget_info=dict(archive_widget),
            )

    def test_app_store_target_requires_production_profile_and_certificate_binding(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            bundle = Path(name) / "App.app"
            bundle.mkdir()
            write_plist(
                bundle / "Info.plist",
                app_info(archive_identity.APP_BUNDLE_IDENTIFIER, "App"),
            )
            entitlements = {
                "application-identifier": f"{app_store_verifier.EXPECTED_TEAM}.{archive_identity.APP_BUNDLE_IDENTIFIER}",
                "com.apple.developer.team-identifier": app_store_verifier.EXPECTED_TEAM,
                **app_store_verifier.PRODUCTION_ENTITLEMENT_VALUES,
            }
            profile_entitlements = dict(entitlements)
            profile = {
                "Entitlements": profile_entitlements,
                "TeamIdentifier": [app_store_verifier.EXPECTED_TEAM],
                "Platform": ["iOS"],
                "ExpirationDate": dt.datetime.now() + dt.timedelta(days=90),
                "DeveloperCertificates": [b"certificate"],
            }

            def fake_run(args: list[str], _label: str) -> bytes:
                if "--entitlements" in args:
                    return plistlib.dumps(entitlements)
                return b""

            metadata = {
                "Authority": "Apple Distribution: Example",
                "TeamIdentifier": app_store_verifier.EXPECTED_TEAM,
                "Identifier": archive_identity.APP_BUNDLE_IDENTIFIER,
            }
            with (
                mock.patch.object(app_store_verifier, "_run", side_effect=fake_run),
                mock.patch.object(app_store_verifier, "_profile", return_value=profile),
                mock.patch.object(app_store_verifier, "_codesign_metadata", return_value=metadata),
                mock.patch.object(app_store_verifier, "_certificate_matches_profile", return_value=True),
            ):
                app_store_verifier._validate_target(
                    label="App Store app",
                    bundle=bundle,
                    expected_bundle_identifier=archive_identity.APP_BUNDLE_IDENTIFIER,
                    expected_entitlements=app_store_verifier.PRODUCTION_ENTITLEMENT_VALUES,
                )
                for unexpected_key, unexpected_value in (
                    ("com.apple.developer.associated-domains", ["applinks:example.invalid"]),
                    ("com.example.unreviewed-capability", True),
                ):
                    entitlements[unexpected_key] = unexpected_value
                    profile_entitlements[unexpected_key] = unexpected_value
                    with self.assertRaises(app_store_verifier.AppStoreVerificationError):
                        app_store_verifier._validate_target(
                            label="App Store app",
                            bundle=bundle,
                            expected_bundle_identifier=archive_identity.APP_BUNDLE_IDENTIFIER,
                            expected_entitlements=app_store_verifier.PRODUCTION_ENTITLEMENT_VALUES,
                        )
                    entitlements.pop(unexpected_key)
                    profile_entitlements.pop(unexpected_key)
                for system_key, safe_value, unsafe_value in (
                    ("get-task-allow", False, True),
                    ("beta-reports-active", True, False),
                ):
                    entitlements[system_key] = safe_value
                    if system_key == "beta-reports-active":
                        profile_entitlements[system_key] = safe_value
                    app_store_verifier._validate_target(
                        label="App Store app",
                        bundle=bundle,
                        expected_bundle_identifier=archive_identity.APP_BUNDLE_IDENTIFIER,
                        expected_entitlements=app_store_verifier.PRODUCTION_ENTITLEMENT_VALUES,
                    )
                    entitlements[system_key] = unsafe_value
                    with self.assertRaises(app_store_verifier.AppStoreVerificationError):
                        app_store_verifier._validate_target(
                            label="App Store app",
                            bundle=bundle,
                            expected_bundle_identifier=archive_identity.APP_BUNDLE_IDENTIFIER,
                            expected_entitlements=app_store_verifier.PRODUCTION_ENTITLEMENT_VALUES,
                        )
                    entitlements.pop(system_key)
                    profile_entitlements.pop(system_key, None)
                device_bound = dict(profile)
                device_bound["ProvisionedDevices"] = ["device"]
                with (
                    mock.patch.object(app_store_verifier, "_profile", return_value=device_bound),
                    self.assertRaises(app_store_verifier.AppStoreVerificationError),
                ):
                    app_store_verifier._validate_target(
                        label="App Store app",
                        bundle=bundle,
                        expected_bundle_identifier=archive_identity.APP_BUNDLE_IDENTIFIER,
                        expected_entitlements=app_store_verifier.PRODUCTION_ENTITLEMENT_VALUES,
                    )

                widget_bundle = Path(name) / "Widget.appex"
                widget_bundle.mkdir()
                write_plist(
                    widget_bundle / "Info.plist",
                    app_info(archive_identity.WIDGET_BUNDLE_IDENTIFIER, "Widget"),
                )
                entitlements = {
                    "application-identifier": f"{app_store_verifier.EXPECTED_TEAM}.{archive_identity.WIDGET_BUNDLE_IDENTIFIER}",
                    "com.apple.developer.team-identifier": app_store_verifier.EXPECTED_TEAM,
                    **app_store_verifier.WIDGET_ENTITLEMENT_VALUES,
                }
                profile_entitlements = dict(entitlements)
                profile = {
                    "Entitlements": profile_entitlements,
                    "TeamIdentifier": [app_store_verifier.EXPECTED_TEAM],
                    "Platform": ["iOS"],
                    "ExpirationDate": dt.datetime.now() + dt.timedelta(days=90),
                    "DeveloperCertificates": [b"certificate"],
                }
                metadata["Identifier"] = archive_identity.WIDGET_BUNDLE_IDENTIFIER
                with mock.patch.object(
                    app_store_verifier,
                    "_profile",
                    return_value=profile,
                ):
                    app_store_verifier._validate_target(
                        label="App Store Widget",
                        bundle=widget_bundle,
                        expected_bundle_identifier=archive_identity.WIDGET_BUNDLE_IDENTIFIER,
                        expected_entitlements=app_store_verifier.WIDGET_ENTITLEMENT_VALUES,
                    )
                    for unexpected_key, unexpected_value in (
                        ("aps-environment", "production"),
                        ("com.apple.developer.associated-domains", ["applinks:example.invalid"]),
                        ("com.apple.developer.icloud-services", ["CloudKit"]),
                        ("com.example.unreviewed-widget-capability", True),
                    ):
                        entitlements[unexpected_key] = unexpected_value
                        profile_entitlements[unexpected_key] = unexpected_value
                        with self.assertRaises(app_store_verifier.AppStoreVerificationError):
                            app_store_verifier._validate_target(
                                label="App Store Widget",
                                bundle=widget_bundle,
                                expected_bundle_identifier=archive_identity.WIDGET_BUNDLE_IDENTIFIER,
                                expected_entitlements=app_store_verifier.WIDGET_ENTITLEMENT_VALUES,
                            )
                        entitlements.pop(unexpected_key)
                        profile_entitlements.pop(unexpected_key)


class BoundaryCommandTests(unittest.TestCase):
    def run_script(self, script: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPTS / script), *arguments],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_export_options_are_exact_and_tampering_fails(self) -> None:
        options = ROOT / "Scripts/ios_app_store_export_options.plist"
        result = self.run_script(
            "validate_ios_app_store_export_options.py", "--options", str(options)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        with tempfile.TemporaryDirectory() as name:
            changed = Path(name) / "options.plist"
            payload = plistlib.loads(options.read_bytes())
            payload["manageAppVersionAndBuildNumber"] = True
            write_plist(changed, payload)
            result = self.run_script(
                "validate_ios_app_store_export_options.py", "--options", str(changed)
            )
            self.assertNotEqual(result.returncode, 0)

    def test_physical_product_verifier_rejects_missing_or_wrong_identity(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            ipa = root / "release-testing.ipa"
            ipa.write_bytes(b"sealed-release-testing-ipa")
            missing = self.run_script(
                "ios_physical_release_acceptance.py",
                "verify-product",
                "--identity",
                str(root / "missing-identity.json"),
                "--release-testing-ipa",
                str(ipa),
            )
            self.assertNotEqual(missing.returncode, 0)

            identity = archive_identity.validate_identity(
                {
                    "schemaVersion": 1,
                    "identityPurpose": archive_identity.IDENTITY_PURPOSE,
                    "archiveTreeSha256": "3" * 64,
                    "archiveFileCount": 12,
                    "archiveTotalBytes": 8192,
                    "appExecutableUUIDs": APP_UUIDS,
                    "widgetExecutableUUIDs": WIDGET_UUIDS,
                    "debugSymbolsVerified": True,
                    "releaseTestingIpaSha256": "9" * 64,
                    "sourceRepository": SOURCE_REPOSITORY,
                    "sourceCommit": SOURCE_COMMIT,
                    "sourceInputDigest": SOURCE_INPUT_DIGEST,
                    "releaseVersion": VERSION,
                    "releaseBuild": BUILD,
                    "appBundleIdentifier": archive_identity.APP_BUNDLE_IDENTIFIER,
                    "widgetBundleIdentifier": archive_identity.WIDGET_BUNDLE_IDENTIFIER,
                    "productSurface": "production",
                    "buildConfiguration": "Release",
                    "swiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
                }
            )
            identity_path = root / "wrong-identity.json"
            identity_path.write_bytes(archive_identity.canonical_bytes(identity))
            wrong = self.run_script(
                "ios_physical_release_acceptance.py",
                "verify-product",
                "--identity",
                str(identity_path),
                "--release-testing-ipa",
                str(ipa),
            )
            self.assertNotEqual(wrong.returncode, 0)
            self.assertIn("does not match the sealed archive identity", wrong.stderr)

    def test_key_validator_requires_private_matching_external_key(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            key = Path(name) / "AuthKey_ABCDEFGHIJ.p8"
            generated = subprocess.run(
                [
                    "/usr/bin/openssl",
                    "genpkey",
                    "-algorithm",
                    "EC",
                    "-pkeyopt",
                    "ec_paramgen_curve:P-256",
                    "-out",
                    str(key),
                ],
                capture_output=True,
                check=False,
            )
            self.assertEqual(generated.returncode, 0, generated.stderr)
            key.chmod(0o600)
            arguments = (
                "--key-path",
                str(key),
                "--key-id",
                "ABCDEFGHIJ",
                "--issuer-id",
                "12345678-1234-1234-1234-123456789abc",
            )
            self.assertEqual(
                self.run_script("validate_app_store_connect_key.py", *arguments).returncode,
                0,
            )
            key.chmod(0o644)
            self.assertNotEqual(
                self.run_script("validate_app_store_connect_key.py", *arguments).returncode,
                0,
            )

    def test_log_redactor_removes_every_credential_reference(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            source = root / "raw.log"
            output = root / "redacted.log"
            source.write_text("path=/secret/key id=ABCDEFGHIJ issuer=issuer-value\n", encoding="utf-8")
            result = self.run_script(
                "redact_app_store_connect_log.py",
                "--input",
                str(source),
                "--output",
                str(output),
                "--secret-reference",
                "/secret/key",
                "--secret-reference",
                "ABCDEFGHIJ",
                "--secret-reference",
                "issuer-value",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            redacted = output.read_text(encoding="utf-8")
            self.assertNotIn("/secret/key", redacted)
            self.assertNotIn("ABCDEFGHIJ", redacted)
            self.assertNotIn("issuer-value", redacted)
            token_log = root / "token.log"
            token_output = root / "token-redacted.log"
            token_log.write_text(
                "Bearer aaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbb.cccccccccccccccccccc\n",
                encoding="utf-8",
            )
            result = self.run_script(
                "redact_app_store_connect_log.py",
                "--input",
                str(token_log),
                "--output",
                str(token_output),
                "--secret-reference",
                "credential-reference",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(token_output.exists())

    def test_upload_preflight_rejects_ipa_changed_after_verification(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            export = root / "export"
            export.mkdir()
            ipa = export / "App.ipa"
            ipa.write_bytes(b"verified")
            verification = root / "verification.json"
            payload = {
                "schemaVersion": 1,
                "appStoreExportVerified": True,
                "samePhysicallyAcceptedArchive": True,
                "distributionSigning": True,
                "appStoreProfilesNotDeviceBound": True,
                "productionEntitlementsVerified": True,
                "debugSymbolsVerified": True,
                "binaryTestSurfaceDetected": False,
                "productSurface": "production",
                "buildConfiguration": "Release",
                "swiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
                "sourceCommit": SOURCE_COMMIT,
                "archiveIdentityPurpose": archive_identity.IDENTITY_PURPOSE,
                "releaseVersion": VERSION,
                "releaseBuild": BUILD,
                "appBundleIdentifier": archive_identity.APP_BUNDLE_IDENTIFIER,
                "widgetBundleIdentifier": archive_identity.WIDGET_BUNDLE_IDENTIFIER,
                "teamIdentifier": app_store_verifier.EXPECTED_TEAM,
                "archiveTreeSha256": "3" * 64,
                "releaseTestingIpaSha256": "4" * 64,
                "appStoreIpaSha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
                "sourceInputDigest": SOURCE_INPUT_DIGEST,
                "appExecutableUUIDs": APP_UUIDS,
                "widgetExecutableUUIDs": WIDGET_UUIDS,
            }
            verification.write_text(json.dumps(payload), encoding="utf-8")
            self.assertEqual(
                self.run_script(
                    "ios_app_store_upload_preflight.py",
                    "--export-dir",
                    str(export),
                    "--verification",
                    str(verification),
                ).returncode,
                0,
            )
            ipa.write_bytes(b"changed")
            self.assertNotEqual(
                self.run_script(
                    "ios_app_store_upload_preflight.py",
                    "--export-dir",
                    str(export),
                    "--verification",
                    str(verification),
                ).returncode,
                0,
            )

    def test_source_and_workflow_contract_keep_upload_separate(self) -> None:
        exporter = (SCRIPTS / "export_ios_app_store_product.sh").read_text(encoding="utf-8")
        uploader = (SCRIPTS / "upload_ios_app_store_product.sh").read_text(encoding="utf-8")
        workflow = (ROOT / ".github/workflows/ios-app-store-export.yml").read_text(
            encoding="utf-8"
        )
        options = plistlib.loads((SCRIPTS / "ios_app_store_export_options.plist").read_bytes())
        self.assertIn("xcodebuild -exportArchive", exporter)
        self.assertIn("--release-testing-ipa", exporter)
        self.assertNotIn("--upload-package", exporter)
        self.assertNotIn("bash Scripts/upload_ios_app_store_product.sh", workflow)
        self.assertIn("release-ios-app-store-export", workflow)
        self.assertIn("actions: read", workflow)
        self.assertIn("Revalidate App Store Export Approval Environment", workflow)
        post_approval = workflow.index("Revalidate App Store Export Approval Environment")
        source_check = workflow.index("Require Exact Clean Source")
        export_step = workflow.index("Revalidate Physical Evidence and Export Accepted Archive")
        self.assertLess(post_approval, source_check)
        self.assertLess(post_approval, export_step)
        secret_path = "ASC_API_KEY_PATH: ${{ secrets.SKYBRIDGE_ASC_API_KEY_PATH }}"
        secret_id = "ASC_API_KEY_ID: ${{ secrets.SKYBRIDGE_ASC_API_KEY_ID }}"
        secret_issuer = "ASC_API_ISSUER_ID: ${{ secrets.SKYBRIDGE_ASC_API_ISSUER_ID }}"
        self.assertEqual(workflow.count(secret_path), 1)
        self.assertEqual(workflow.count(secret_id), 1)
        self.assertEqual(workflow.count(secret_issuer), 1)
        self.assertGreater(workflow.index(secret_path), export_step)
        self.assertGreater(workflow.index(secret_id), export_step)
        self.assertGreater(workflow.index(secret_issuer), export_step)
        self.assertIn("release_testing_ipa:", workflow)
        self.assertIn('--release-testing-ipa "$RELEASE_TESTING_IPA"', workflow)
        self.assertIn("--confirm-upload", uploader)
        self.assertIn('if [[ "$CONFIRM_UPLOAD" != "1" ]]', uploader)
        self.assertIn("--upload-package", uploader)
        self.assertEqual(options["method"], "app-store-connect")
        self.assertEqual(options["destination"], "export")
        self.assertIs(options["manageAppVersionAndBuildNumber"], False)


if __name__ == "__main__":
    unittest.main()
