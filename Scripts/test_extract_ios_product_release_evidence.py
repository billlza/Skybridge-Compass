#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import plistlib
import tempfile
import unittest
from pathlib import Path

import extract_ios_product_release_evidence as extractor
from product_release_evidence_test_fixtures import (
    IOS_PRODUCT,
    connectivity_product_logs,
    golden_ios_archive_binding,
)
from validate_product_release_evidence_log import validate_capture_manifest


class IOSProductEvidenceExtractionTests(unittest.TestCase):
    process_id = 8123
    executable_path = (
        "/private/var/containers/Bundle/Application/"
        "11111111-2222-3333-4444-555555555555/"
        "SkyBridgeCompass-iOS.app/SkyBridgeCompass-iOS"
    )

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.private = self.root / "private"
        self.output = self.root / "output"
        self.private.mkdir(mode=0o700)
        self.output.mkdir(mode=0o700)
        self.binding = golden_ios_archive_binding()
        self.archive_identity = self.private / "ios-release-archive-identity.json"
        self.installation_payload = {
            "bundleIdentifier": "com.skybridge.compass.ios",
            "deviceIdentifier": "device-identifier",
            "installationVerified": True,
            "iosReleaseArchive": self.binding,
            "launchServicesIdentifier": "aW5zdGFsbC1iaW5kaW5n",
            "releaseBuild": "42",
            "releaseVersion": "1.2.3",
            "remoteApplicationPath": str(Path(self.executable_path).parent),
            "schemaVersion": 1,
        }
        self.installation = self.private / "installation-binding.json"
        self._write_json(self.installation, self.installation_payload)
        self.archive_payload = {
                "appBundleIdentifier": "com.skybridge.compass.ios",
                "appExecutableUUIDs": self.binding["appExecutableUUIDs"],
                "archiveFileCount": 12,
                "archiveTotalBytes": 8192,
                "archiveTreeSha256": self.binding["archiveTreeSha256"],
                "buildConfiguration": "Release",
                "debugSymbolsVerified": True,
                "identityPurpose": self.binding["identityPurpose"],
                "productSurface": "production",
                "releaseBuild": self.binding["releaseBuild"],
                "releaseTestingIpaSha256": self.binding["releaseTestingIpaSha256"],
                "releaseVersion": self.binding["releaseVersion"],
                "schemaVersion": 1,
                "sourceCommit": "1" * 40,
                "sourceInputDigest": self.binding["sourceInputDigest"],
                "sourceRepository": "example/skybridge",
                "swiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
                "widgetBundleIdentifier": "com.skybridge.compass.ios.widgets",
                "widgetExecutableUUIDs": self.binding["widgetExecutableUUIDs"],
        }
        self._write_json(self.archive_identity, self.archive_payload)
        self.identity = self.private / "launch-identity.json"
        self.manifest = self.output / "release-acceptance.json"
        self.raw = self.private / "ios-product.ndjson"
        self.output_log = self.output / "ios-product-session.log"
        self.output_capture = self.output / "ios-product-session-capture.json"
        self._write_json(
            self.identity,
            {
                "auditToken": [501, 501, 20, 501, 20, self.process_id, 100, 0],
                "bundleIdentifier": "com.skybridge.compass.ios",
                "bundleName": "SkyBridgeCompass-iOS.app",
                "executableName": "SkyBridgeCompass-iOS",
                "executablePath": self.executable_path,
                "installationBinding": self.installation_payload,
                "platform": "ios",
                "processIdentifier": self.process_id,
                "schemaVersion": 1,
                "startTimeToken": "1700000000:223456",
            },
        )
        self._write_json(
            self.manifest,
            {
                "acceptanceEligible": False,
                "cleanupComplete": False,
                "diagnosticOnly": True,
                "iosReleaseArchive": self.binding,
                "preCleanupCandidate": True,
            },
        )
        _, ios_lines = connectivity_product_logs()
        self.ios_lines = ios_lines
        self._write_raw(self.raw, ios_lines)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def _write_json(path: Path, payload: object) -> None:
        path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        path.chmod(0o600)

    def _write_raw(
        self,
        path: Path,
        messages: list[str],
        *,
        process_id: int | None = None,
        process_image_path: str | None = None,
        format_string: str = "%{public}s",
    ) -> None:
        rows = [
            {
                "category": "ProductSession",
                "eventMessage": message,
                "eventType": "logEvent",
                "formatString": format_string,
                "messageType": "Default",
                "processID": self.process_id if process_id is None else process_id,
                "processImagePath": process_image_path or self.executable_path,
                "subsystem": "com.skybridge.compass.release-evidence",
            }
            for message in messages
        ]
        path.write_text(
            "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows),
            encoding="utf-8",
        )
        path.chmod(0o600)

    def _extract(self) -> None:
        extractor.extract(
            raw_oslog=self.raw,
            launch_identity=self.identity,
            archive_identity=self.archive_identity,
            output_log=self.output_log,
            output_capture=self.output_capture,
        )

    def test_extracts_exact_shipping_process_and_archive_binding(self) -> None:
        self._extract()

        self.assertEqual(
            self.output_log.read_text(encoding="ascii"),
            "\n".join(self.ios_lines) + "\n",
        )
        capture = validate_capture_manifest(
            self.output_capture,
            len(self.ios_lines),
            expected_owner=IOS_PRODUCT,
        )
        self.assertEqual(capture["iosReleaseArchive"], self.binding)
        self.assertEqual(capture["processID"], self.process_id)
        self.assertEqual(self.output_log.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.output_capture.stat().st_mode & 0o777, 0o600)

    def test_rejects_different_process_without_publishing_outputs(self) -> None:
        self._write_raw(self.raw, self.ios_lines, process_id=self.process_id + 1)
        with self.assertRaisesRegex(
            extractor.IOSProductEvidenceError,
            "outside the exact capture boundary",
        ):
            self._extract()
        self.assertFalse(self.output_log.exists())
        self.assertFalse(self.output_capture.exists())

    def test_rejects_different_remote_executable(self) -> None:
        self._write_raw(
            self.raw,
            self.ios_lines,
            process_image_path=self.executable_path + "-replacement",
        )
        with self.assertRaisesRegex(
            extractor.IOSProductEvidenceError,
            "outside the exact capture boundary",
        ):
            self._extract()

    def test_rejects_private_format_or_wrong_owner(self) -> None:
        for messages, format_string in (
            (self.ios_lines, "%{private}s"),
            ([self.ios_lines[0].replace(IOS_PRODUCT, "SkyBridgeCompassApp")], "%{public}s"),
        ):
            with self.subTest(format_string=format_string, message=messages[0][:32]):
                self._write_raw(self.raw, messages, format_string=format_string)
                with self.assertRaises(Exception):
                    self._extract()
                self.output_log.unlink(missing_ok=True)
                self.output_capture.unlink(missing_ok=True)

    def test_rejects_changed_or_malformed_archive_identity(self) -> None:
        for mutation in ("changed-binding", "malformed"):
            with self.subTest(mutation=mutation):
                payload = json.loads(self.archive_identity.read_text(encoding="utf-8"))
                if mutation == "changed-binding":
                    payload["archiveTreeSha256"] = "9" * 64
                else:
                    payload.pop("sourceCommit")
                self._write_json(self.archive_identity, payload)
                with self.assertRaises(extractor.IOSProductEvidenceError):
                    self._extract()
                self.output_log.unlink(missing_ok=True)
                self.output_capture.unlink(missing_ok=True)
                self._write_json(self.archive_identity, self.archive_payload)

    def test_rejects_linked_private_identity(self) -> None:
        linked = self.private / "linked.json"
        os.link(self.identity, linked)
        with self.assertRaisesRegex(
            extractor.IOSProductEvidenceError,
            "one link",
        ):
            self._extract()

    def test_binds_devicectl_launch_to_exact_release_testing_app(self) -> None:
        app = self.root / "SkyBridgeCompass-iOS.app"
        app.mkdir(mode=0o700)
        with (app / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleExecutable": "SkyBridgeCompass-iOS",
                    "CFBundleIdentifier": "com.skybridge.compass.ios",
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42",
                },
                handle,
            )
        (app / "SkyBridgeCompass-iOS").write_bytes(b"release-product")
        ownership = self.private / "devicectl-ownership.json"
        self._write_json(
            ownership,
            {
                "auditToken": [501, 501, 20, 501, 20, self.process_id, 100, 0],
                "bundleName": app.name,
                "executableName": "SkyBridgeCompass-iOS",
                "executablePath": self.executable_path,
                "platform": "ios",
                "processIdentifier": self.process_id,
                "schemaVersion": 1,
            },
        )
        output = self.private / "bound-launch.json"

        extractor.bind_launch_identity(
            ownership_record=ownership,
            installation_binding=self.installation,
            extracted_app=app,
            start_time_token="1700000000:654321",
            output=output,
        )

        payload = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(payload["bundleIdentifier"], "com.skybridge.compass.ios")
        self.assertEqual(payload["startTimeToken"], "1700000000:654321")
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_installation_capture_is_standalone_and_archive_bound(self) -> None:
        app = self.root / "SkyBridgeCompass-iOS.app"
        app.mkdir(mode=0o700)
        with (app / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleExecutable": "SkyBridgeCompass-iOS",
                    "CFBundleIdentifier": "com.skybridge.compass.ios",
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42",
                },
                handle,
            )
        executable = app / "SkyBridgeCompass-iOS"
        executable.write_bytes(b"release-product")
        executable.chmod(0o700)
        prelaunch = self.private / "prelaunch-processes.json"
        self._write_json(
            prelaunch,
            {"result": {"runningProcesses": []}},
        )
        output = self.output / "ios-product-installation-capture.json"

        extractor.write_installation_capture(
            prelaunch_processes=prelaunch,
            launch_identity=self.identity,
            extracted_app=app,
            archive_identity=self.archive_identity,
            output=output,
        )

        payload = extractor.validate_installation_capture(
            output,
            expected_archive_binding=self.binding,
        )
        self.assertIs(payload["freshLaunchVerified"], True)
        self.assertIs(payload["launchPersistentIdentifierVerified"], True)
        self.assertNotIn("deviceIdentifier", payload)
        self.assertNotIn("launchServicesIdentifier", payload)


if __name__ == "__main__":
    unittest.main()
