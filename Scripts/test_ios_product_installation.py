#!/usr/bin/env python3

from __future__ import annotations

import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import ios_product_installation as installation
from product_release_evidence_test_fixtures import golden_ios_archive_binding


class IOSProductInstallationTests(unittest.TestCase):
    device_identifier = "9DDF920E-D7C4-51F2-9C94-67FF629BDF04"
    launch_identifier = "c2t5YnJpZGdlLWluc3RhbGwtcGVyc2lzdGVudA=="

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.app = self.root / "SkyBridgeCompass-iOS.app"
        self.app.mkdir(mode=0o700)
        with (self.app / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleExecutable": "SkyBridgeCompass-iOS",
                    "CFBundleIdentifier": "com.skybridge.compass.ios",
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42",
                },
                handle,
            )
        executable = self.app / "SkyBridgeCompass-iOS"
        executable.write_bytes(b"sealed-release-product")
        executable.chmod(0o700)
        self.identity_path = self.root / "identity.json"
        self.identity_path.write_text("{}\n", encoding="utf-8")
        self.ipa = self.root / "release-testing.ipa"
        self.ipa.write_bytes(b"sealed-ipa")
        self.install_result = self.root / "install.json"
        self.apps_result = self.root / "apps.json"
        self._write_install_result()
        self._write_apps_result()
        binding = golden_ios_archive_binding()
        self.identity = {
            "appExecutableUUIDs": binding["appExecutableUUIDs"],
            "archiveTreeSha256": binding["archiveTreeSha256"],
            "debugSymbolsVerified": True,
            "identityPurpose": binding["identityPurpose"],
            "releaseBuild": binding["releaseBuild"],
            "releaseTestingIpaSha256": binding["releaseTestingIpaSha256"],
            "releaseVersion": binding["releaseVersion"],
            "sourceInputDigest": binding["sourceInputDigest"],
            "widgetExecutableUUIDs": binding["widgetExecutableUUIDs"],
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def _write_json(path: Path, payload: object) -> None:
        path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        path.chmod(0o600)

    def _info(self, command_type: str) -> dict[str, object]:
        return {
            "arguments": ["devicectl"],
            "commandType": command_type,
            "environment": {"TERM": "dumb"},
            "jsonVersion": 5,
            "outcome": "success",
            "version": "642.4",
        }

    def _write_install_result(self, **mutations: object) -> None:
        installed = {
            "bundleIdentifier": "com.skybridge.compass.ios",
            "launchServicesIdentifier": self.launch_identifier,
        }
        installed.update(mutations)
        self._write_json(
            self.install_result,
            {
                "info": self._info("devicectl.device.install.app"),
                "result": {
                    "deviceIdentifier": self.device_identifier,
                    "installedApplications": [installed],
                },
            },
        )

    def _write_apps_result(self, **mutations: object) -> None:
        app = {
            "appClip": False,
            "builtByDeveloper": True,
            "bundleIdentifier": "com.skybridge.compass.ios",
            "bundleVersion": "42",
            "containerAccessible": True,
            "defaultApp": False,
            "hidden": False,
            "internalApp": False,
            "name": "SkyBridgeCompass-iOS",
            "removable": True,
            "url": (
                "file:///private/var/containers/Bundle/Application/"
                "11111111-2222-3333-4444-555555555555/"
                "SkyBridgeCompass-iOS.app/"
            ),
            "version": "1.2.3",
        }
        app.update(mutations)
        self._write_json(
            self.apps_result,
            {
                "info": self._info("devicectl.device.info.apps"),
                "result": {
                    "apps": [app],
                    "defaultAppsIncluded": False,
                    "deviceIdentifier": self.device_identifier,
                    "matchingBundleIdentifier": "com.skybridge.compass.ios",
                    "removableAppsIncluded": True,
                },
            },
        )

    def _verify(self) -> dict[str, object]:
        with (
            mock.patch.object(installation, "load_identity", return_value=self.identity),
            mock.patch.object(installation, "validate_release_testing_ipa"),
            mock.patch.object(
                installation,
                "_executable_uuids",
                return_value=self.identity["appExecutableUUIDs"],
            ),
        ):
            return installation.verify_installation(
                install_result=self.install_result,
                apps_result=self.apps_result,
                extracted_app=self.app,
                archive_identity_path=self.identity_path,
                release_testing_ipa=self.ipa,
                expected_device_identifier=self.device_identifier,
            )

    def test_install_launch_identifier_and_remote_product_are_same_archive_bound(self) -> None:
        payload = self._verify()

        self.assertIs(payload["installationVerified"], True)
        self.assertEqual(payload["launchServicesIdentifier"], self.launch_identifier)
        self.assertEqual(payload["releaseVersion"], "1.2.3")
        self.assertEqual(payload["releaseBuild"], "42")
        self.assertEqual(payload["iosReleaseArchive"], golden_ios_archive_binding())
        self.assertEqual(
            payload["remoteApplicationPath"],
            "/private/var/containers/Bundle/Application/"
            "11111111-2222-3333-4444-555555555555/"
            "SkyBridgeCompass-iOS.app",
        )

    def test_wrong_device_or_remote_version_fails_closed(self) -> None:
        self._write_install_result()
        payload = json.loads(self.install_result.read_text(encoding="utf-8"))
        payload["result"]["deviceIdentifier"] = "different-device"
        self._write_json(self.install_result, payload)
        with self.assertRaisesRegex(installation.IOSInstallationError, "different device"):
            self._verify()

        self._write_install_result()
        self._write_apps_result(bundleVersion="43")
        with self.assertRaisesRegex(installation.IOSInstallationError, "version/build"):
            self._verify()

    def test_install_receipt_requires_one_expected_bundle_record(self) -> None:
        payload = json.loads(self.install_result.read_text(encoding="utf-8"))
        payload["result"]["installedApplications"].append(
            dict(payload["result"]["installedApplications"][0])
        )
        self._write_json(self.install_result, payload)
        with self.assertRaisesRegex(
            installation.IOSInstallationError,
            "exactly one installed application",
        ):
            self._verify()

        self._write_install_result(bundleIdentifier="com.example.unrelated")
        with self.assertRaisesRegex(installation.IOSInstallationError, "different bundle"):
            self._verify()

    def test_malformed_persistent_identifier_fails_closed(self) -> None:
        self._write_install_result(launchServicesIdentifier="not base64")
        with self.assertRaisesRegex(installation.IOSInstallationError, "base64"):
            self._verify()


if __name__ == "__main__":
    unittest.main()
