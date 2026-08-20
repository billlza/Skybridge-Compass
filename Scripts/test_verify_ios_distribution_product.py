#!/usr/bin/env python3

from __future__ import annotations

import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = ROOT_DIR / "Scripts"
VERIFIER = SCRIPTS_DIR / "verify_ios_distribution_product.py"

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import verify_ios_distribution_product as verifier  # noqa: E402


class IOSDistributionProductSurfaceTests(unittest.TestCase):
    def run_verifier(
        self,
        *,
        product_surface: str,
        compilation_conditions: str,
        binary_test_surface: str = "0",
        source_repository: str = "billlza/Skybridge-Compass",
        source_commit: str = "a" * 40,
        app_info_path: str = "/missing/app-info.plist",
        widget_info_path: str = "/missing/widget-info.plist",
    ) -> subprocess.CompletedProcess[str]:
        arguments = [
            "/missing/app-profile.mobileprovision",
            "/missing/widget-profile.mobileprovision",
            "/missing/app-entitlements.plist",
            "/missing/widget-entitlements.plist",
            "/missing/expected-entitlements.plist",
            "/missing/app-certificate.der",
            "/missing/widget-certificate.der",
            "/missing/output.json",
            "TEAM",
            "com.example.app",
            "com.example.app.widget",
            "TEAM",
            "apple-distribution",
            "apple-distribution",
            "Release",
            "0",
            source_commit,
            "1",
            "physical-device-id",
            "/missing/selected-app.mobileprovision",
            "/missing/selected-widget.mobileprovision",
            "1",
            "1",
            source_repository,
            product_surface,
            compilation_conditions,
            binary_test_surface,
            app_info_path,
            widget_info_path,
        ]
        return subprocess.run(
            ["python3", str(VERIFIER), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def assert_formal_surface_rejected(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("production surface without DEBUG/SKYBRIDGE_TESTING", result.stdout)

    def test_formal_proof_rejects_skybridge_testing_product(self) -> None:
        result = self.run_verifier(
            product_surface="testing",
            compilation_conditions="HAS_APPLE_PQC_SDK,SKYBRIDGE_TESTING",
            binary_test_surface="1",
        )
        self.assert_formal_surface_rejected(result)

    def test_formal_proof_rejects_debug_condition_even_if_surface_claims_production(self) -> None:
        result = self.run_verifier(
            product_surface="production",
            compilation_conditions="DEBUG,HAS_APPLE_PQC_SDK",
        )
        self.assert_formal_surface_rejected(result)

    def test_formal_proof_rejects_binary_test_hooks_even_if_metadata_claims_production(self) -> None:
        result = self.run_verifier(
            product_surface="production",
            compilation_conditions="HAS_APPLE_PQC_SDK",
            binary_test_surface="1",
        )
        self.assert_formal_surface_rejected(result)

    def test_formal_proof_rejects_unbound_repository_or_commit(self) -> None:
        for repository, commit in (
            ("", "a" * 40),
            ("../..", "a" * 40),
            ("billlza/Skybridge-Compass", "not-a-full-sha"),
        ):
            with self.subTest(repository=repository, commit=commit):
                result = self.run_verifier(
                    product_surface="production",
                    compilation_conditions="HAS_APPLE_PQC_SDK",
                    source_repository=repository,
                    source_commit=commit,
                )
                self.assert_formal_surface_rejected(result)

    def test_rejects_malformed_compilation_condition_metadata(self) -> None:
        result = self.run_verifier(
            product_surface="production",
            compilation_conditions="HAS_APPLE_PQC_SDK,HAS_APPLE_PQC_SDK",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("compilation-condition metadata is malformed", result.stdout)

    def test_formal_proof_rejects_mismatched_app_and_widget_release_version(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            app_info = root / "app.plist"
            widget_info = root / "widget.plist"
            app_info.write_bytes(
                plistlib.dumps(
                    {"CFBundleShortVersionString": "1.0.2", "CFBundleVersion": "2"}
                )
            )
            widget_info.write_bytes(
                plistlib.dumps(
                    {"CFBundleShortVersionString": "1.0.2", "CFBundleVersion": "3"}
                )
            )
            result = self.run_verifier(
                product_surface="production",
                compilation_conditions="HAS_APPLE_PQC_SDK",
                app_info_path=str(app_info),
                widget_info_path=str(widget_info),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release version/build do not match", result.stdout)

    def test_formal_proof_rejects_noncanonical_release_version_or_build(self) -> None:
        invalid_values = (("1.0", "2"), ("1.0.2", "0"))
        for version, build in invalid_values:
            with self.subTest(version=version, build=build), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                app_info = root / "app.plist"
                widget_info = root / "widget.plist"
                payload = {
                    "CFBundleShortVersionString": version,
                    "CFBundleVersion": build,
                }
                app_info.write_bytes(plistlib.dumps(payload))
                widget_info.write_bytes(plistlib.dumps(payload))
                result = self.run_verifier(
                    product_surface="production",
                    compilation_conditions="HAS_APPLE_PQC_SDK",
                    app_info_path=str(app_info),
                    widget_info_path=str(widget_info),
                )
            self.assertNotEqual(result.returncode, 0)
            self.assertRegex(result.stdout, r"strict semantic version|positive integer")


class WidgetEntitlementConformanceTests(unittest.TestCase):
    """The nested Widget must not independently carry the host App's privileged
    entitlements. This guards against the previous always-true branch that let a
    misconfigured Widget pass the formal proof."""

    # Ground truth extracted from the Xcode-signed archive: the Widget only
    # carries its own identity, team, keychain group, and (in dev builds)
    # get-task-allow.
    CONFORMING_WIDGET_ENTITLEMENTS = {
        "application-identifier": "YKUPL7Z869.com.skybridge.compass.ios.widgets",
        "com.apple.developer.team-identifier": "YKUPL7Z869",
        "keychain-access-groups": [
            "YKUPL7Z869.com.skybridge.compass.ios.widgets"
        ],
    }

    def test_conforming_widget_entitlements_pass(self) -> None:
        self.assertTrue(
            verifier.widget_signed_entitlements_conform(
                dict(self.CONFORMING_WIDGET_ENTITLEMENTS)
            )
        )

    def test_widget_with_shared_app_group_still_conforms(self) -> None:
        entitlements = dict(self.CONFORMING_WIDGET_ENTITLEMENTS)
        entitlements["com.apple.security.application-groups"] = [
            "YKUPL7Z869.group.com.skybridge.compass"
        ]
        self.assertTrue(verifier.widget_signed_entitlements_conform(entitlements))

    def test_widget_rejects_unexpected_meaningful_capability_or_group(self) -> None:
        for key, value in (
            ("com.apple.developer.associated-domains", ["applinks:example.invalid"]),
            ("com.example.unreviewed-widget-capability", True),
            ("com.apple.security.application-groups", ["group.example.invalid"]),
        ):
            with self.subTest(entitlement=key):
                entitlements = dict(self.CONFORMING_WIDGET_ENTITLEMENTS)
                entitlements[key] = value
                self.assertFalse(verifier.widget_signed_entitlements_conform(entitlements))

    def test_widget_rejects_each_disallowed_privileged_entitlement(self) -> None:
        privileged_samples = {
            "com.apple.developer.applesignin": ["Default"],
            "aps-environment": "production",
            "com.apple.developer.icloud-services": ["CloudKit", "CloudDocuments"],
            "com.apple.developer.icloud-container-identifiers": [
                "iCloud.com.skybridge.compass"
            ],
            "com.apple.developer.icloud-container-environment": [
                "Production"
            ],
            "com.apple.developer.icloud-container-development-container-identifiers": [
                "iCloud.com.skybridge.compass"
            ],
            "com.apple.developer.ubiquity-container-identifiers": [
                "iCloud.com.skybridge.compass"
            ],
            "com.apple.developer.ubiquity-kvstore-identifier": (
                "YKUPL7Z869.com.skybridge.compass"
            ),
        }
        # Every disallowed key must have a negative sample so the guard cannot
        # silently drop coverage of a capability.
        self.assertEqual(
            set(privileged_samples),
            set(verifier.WIDGET_DISALLOWED_ENTITLEMENTS),
        )
        for key, value in privileged_samples.items():
            with self.subTest(entitlement=key):
                entitlements = dict(self.CONFORMING_WIDGET_ENTITLEMENTS)
                entitlements[key] = value
                self.assertFalse(
                    verifier.widget_signed_entitlements_conform(entitlements)
                )

    def test_empty_privileged_entitlement_value_is_not_treated_as_present(self) -> None:
        for empty_value in ([], "", {}):
            with self.subTest(value=repr(empty_value)):
                entitlements = dict(self.CONFORMING_WIDGET_ENTITLEMENTS)
                entitlements["com.apple.developer.icloud-services"] = empty_value
                self.assertTrue(
                    verifier.widget_signed_entitlements_conform(entitlements)
                )

    def test_entitlement_value_presence_semantics(self) -> None:
        self.assertFalse(verifier.entitlement_value_is_present(None))
        self.assertFalse(verifier.entitlement_value_is_present(False))
        self.assertFalse(verifier.entitlement_value_is_present([]))
        self.assertFalse(verifier.entitlement_value_is_present(""))
        self.assertTrue(verifier.entitlement_value_is_present(True))
        self.assertTrue(verifier.entitlement_value_is_present(["CloudKit"]))
        self.assertTrue(verifier.entitlement_value_is_present("production"))

    def test_profile_entitlement_coverage_handles_lists_wildcards_and_scalars(self) -> None:
        self.assertTrue(
            verifier.profile_entitlement_covers(
                ["YKUPL7Z869.*", "com.apple.token"],
                ["YKUPL7Z869.com.skybridge.compass.ios"],
            )
        )
        self.assertTrue(verifier.profile_entitlement_covers(True, True))
        self.assertFalse(verifier.profile_entitlement_covers(None, True))
        self.assertFalse(
            verifier.profile_entitlement_covers(
                ["group.example.invalid"],
                ["group.com.skybridge.compass"],
            )
        )

    def test_app_rejects_unexpected_meaningful_capability_and_unsafe_system_flags(self) -> None:
        expected = {
            "aps-environment": "production",
            "keychain-access-groups": [
                "YKUPL7Z869.com.skybridge.compass.ios",
                "YKUPL7Z869.group.com.skybridge.compass",
            ],
        }
        base = {
            "application-identifier": "YKUPL7Z869.com.skybridge.compass.ios",
            "com.apple.developer.team-identifier": "YKUPL7Z869",
            **expected,
        }
        self.assertTrue(
            verifier.app_signed_entitlements_conform(
                base,
                expected_entitlements=expected,
                expected_team="YKUPL7Z869",
                lab_run=False,
            )
        )
        for key, value in (
            ("com.apple.developer.associated-domains", ["applinks:example.invalid"]),
            ("com.example.unreviewed-app-capability", True),
            ("get-task-allow", True),
            ("beta-reports-active", False),
            ("com.apple.security.application-groups", ["group.example.invalid"]),
        ):
            with self.subTest(entitlement=key):
                changed = dict(base)
                changed[key] = value
                self.assertFalse(
                    verifier.app_signed_entitlements_conform(
                        changed,
                        expected_entitlements=expected,
                        expected_team="YKUPL7Z869",
                        lab_run=False,
                    )
                )

        debug = dict(base)
        debug["get-task-allow"] = True
        self.assertTrue(
            verifier.app_signed_entitlements_conform(
                debug,
                expected_entitlements=expected,
                expected_team="YKUPL7Z869",
                lab_run=True,
            )
        )

    def test_debug_lab_widget_requires_no_keychain_group(self) -> None:
        self.assertEqual(
            verifier.required_keychain_groups(
                bundle_identifier="com.skybridge.compass.ios.widgets",
                expected_team="YKUPL7Z869",
                is_app=False,
                configuration="Debug",
                lab_run=True,
            ),
            set(),
        )

    def test_release_widget_still_requires_its_own_keychain_group(self) -> None:
        expected = {"YKUPL7Z869.com.skybridge.compass.ios.widgets"}
        for lab_run in (False, True):
            with self.subTest(lab_run=lab_run):
                self.assertEqual(
                    verifier.required_keychain_groups(
                        bundle_identifier="com.skybridge.compass.ios.widgets",
                        expected_team="YKUPL7Z869",
                        is_app=False,
                        configuration="Release",
                        lab_run=lab_run,
                    ),
                    expected,
                )

    def test_app_always_requires_product_and_shared_keychain_groups(self) -> None:
        expected = {
            "YKUPL7Z869.com.skybridge.compass.ios",
            "YKUPL7Z869.group.com.skybridge.compass",
        }
        for configuration, lab_run in (("Debug", True), ("Release", False)):
            with self.subTest(configuration=configuration, lab_run=lab_run):
                self.assertEqual(
                    verifier.required_keychain_groups(
                        bundle_identifier="com.skybridge.compass.ios",
                        expected_team="YKUPL7Z869",
                        is_app=True,
                        configuration=configuration,
                        lab_run=lab_run,
                    ),
                    expected,
                )


if __name__ == "__main__":
    unittest.main()
