#!/usr/bin/env python3
"""Regression tests for release-candidate subprocess and entitlement boundaries."""
from __future__ import annotations

import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import verify_ios_release_candidate as verifier


class ReleaseCandidateVerifierDiagnosticsTests(unittest.TestCase):
    def test_failed_verifier_retains_all_fields_after_long_traceback_and_masks_root(self) -> None:
        fields = ",".join(
            f"{target}.{field}"
            for target in ("app", "widget")
            for field in (
                "productBundle", "platformVerified", "teamMatch", "keychainGroupsVerified",
                "profileNotExpired", "profileDeviceBound", "certificateMatch",
                "certificateNotExpired", "certificateTrusted", "expectedEntitlementsMatch",
                "selectedProfileMatch",
            )
        )
        failure = "RuntimeError: iOS product profile/signature proof failed: " + fields
        diagnostic = f"Traceback at {verifier.ROOT}\n" + ("frame\n" * 100) + failure
        command = [
            sys.executable, "-B", "-c",
            f"import sys; sys.stderr.write({diagnostic!r}); sys.exit(7)",
            "unit-test-device-argument",
        ]
        with self.assertRaises(SystemExit) as raised:
            verifier.run_product_verifier(command)
        message = str(raised.exception)
        self.assertIn(failure, message)
        self.assertIn("<repo>", message)
        self.assertNotIn(str(verifier.ROOT), message)
        self.assertNotIn("unit-test-device-argument", message)
        self.assertIn("formal product verifier rejected", message)

    def test_failed_verifier_without_stderr_retains_stdout_failure(self) -> None:
        command = [
            sys.executable, "-B", "-c",
            "import sys; print('product verifier failure on stdout'); sys.exit(9)",
        ]
        with self.assertRaisesRegex(SystemExit, "product verifier failure on stdout"):
            verifier.run_product_verifier(command)

    def test_successful_verifier_does_not_raise(self) -> None:
        self.assertIsNone(
            verifier.run_product_verifier([sys.executable, "-B", "-c", "pass"])
        )


class ReleaseCandidateCodesignArgumentsTests(unittest.TestCase):
    def test_app_and_widget_use_supported_entitlement_stdout_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            export = root / "export"
            export.mkdir()
            (export / "candidate.ipa").write_bytes(b"unit-test-ipa")
            app = root / "App.app"
            widget = app / "PlugIns" / "Widget.appex"
            widget.mkdir(parents=True)
            output_manifest = root / "evidence" / "acceptance.json"
            calls = []

            def codesign(args, **_kwargs):
                calls.append(args)
                if any(str(arg).startswith("--extract-certificates=") for arg in args):
                    return subprocess.CompletedProcess(args, 1, b"", b"certificate test boundary")
                if "--entitlements" in args:
                    return subprocess.CompletedProcess(args, 0, plistlib.dumps({}), b"")
                return subprocess.CompletedProcess(args, 0, b"", b"")

            with (
                mock.patch.object(verifier, "EXPORT_DIR", export),
                mock.patch.object(verifier, "OUTPUT_MANIFEST", output_manifest),
                mock.patch.object(verifier, "extract_single_ios_app", return_value=app),
                mock.patch.object(verifier.subprocess, "run", side_effect=codesign),
                self.assertRaisesRegex(SystemExit, "certificate test boundary"),
            ):
                verifier.main()

            entitlement_calls = [args for args in calls if "--entitlements" in args]
            self.assertEqual(
                entitlement_calls,
                [
                    ["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(app)],
                    ["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(widget)],
                ],
            )
            self.assertFalse(output_manifest.exists())
            self.assertFalse((output_manifest.parent / "ios-release-candidate-product-proof.json").exists())


if __name__ == "__main__":
    unittest.main()
