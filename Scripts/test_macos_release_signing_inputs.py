#!/usr/bin/env python3
"""Exercise certificate selection with isolated public-certificate fixtures."""
import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

from select_macos_release_signing_identity import select_identity

ROOT = Path(__file__).resolve().parents[1]
CHECK_SCRIPT = ROOT / "Scripts/check_macos_release_signing_inputs.sh"
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


class SigningInputsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory(prefix="skybridge-signing-input-test-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.certificates = []
        cls.der = []
        for index in range(8):
            certificate = cls.root / f"certificate-{index}.pem"
            key = cls.root / f"key-{index}.pem"
            name = "Apple Development: Fixture" if index == 0 else f"Developer ID Application: Fixture {index}"
            subprocess.run([
                "/usr/bin/openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                "ec_paramgen_curve:prime256v1", "-nodes", "-days", "1",
                "-subj", f"/OU=TESTTEAM01/CN={name}", "-keyout", str(key), "-out", str(certificate),
            ], check=True, capture_output=True, timeout=20)
            cls.certificates.append(certificate.read_bytes())
            cls.der.append(subprocess.run([
                "/usr/bin/openssl", "x509", "-in", str(certificate), "-outform", "DER",
            ], check=True, capture_output=True, timeout=10).stdout)
            key.unlink()

    def setUp(self) -> None:
        self.run_root = self.root / self.id().rsplit(".", 1)[-1]
        self.run_root.mkdir()
        self.bundle = self.run_root / "certificates.pem"
        self.bundle.write_bytes(b"Bag Attributes\n" + b"\n".join(self.certificates))
        self.app = self.profile("app", [1, 5])
        self.widget = self.profile("widget", [3, 5])

    def profile(self, kind: str, indexes: list[int], *, expired: bool = False) -> Path:
        relative = (
            "Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.packaging.entitlements"
            if kind == "app" else
            "Sources/SkyBridgeCompassWidgets/SkyBridgeCompassWidgetsExtension.entitlements"
        )
        entitlements = plistlib.loads((ROOT / relative).read_bytes())

        def expand(value):
            if isinstance(value, str):
                return value.replace("$(AppIdentifierPrefix)", "TESTTEAM01.").replace("$(TeamIdentifierPrefix)", "TESTTEAM01.")
            if isinstance(value, list):
                return [expand(item) for item in value]
            return value

        entitlements = {key: expand(value) for key, value in entitlements.items()}
        suffix = "" if kind == "app" else ".widgets"
        entitlements["com.apple.application-identifier"] = "TESTTEAM01.com.skybridge.compass.pro" + suffix
        payload = {
            "Platform": ["OSX"], "TeamIdentifier": ["TESTTEAM01"],
            "ApplicationIdentifierPrefix": ["TESTTEAM01"], "ProvisionsAllDevices": True,
            "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=-1 if expired else 1),
            "DeveloperCertificates": [self.der[index] for index in indexes], "Entitlements": entitlements,
        }
        path = self.run_root / (kind + ".provisionprofile")
        path.write_bytes(plistlib.dumps(payload))
        return path

    def check(self, *, swapped: bool = False) -> subprocess.CompletedProcess:
        app, widget = (self.widget, self.app) if swapped else (self.app, self.widget)
        return subprocess.run([
            "/bin/bash", str(CHECK_SCRIPT), str(self.bundle), str(app), str(widget),
        ], capture_output=True, text=True, timeout=30, env={**os.environ, "PATH": SYSTEM_PATH})

    def test_eight_certificate_bundle_selects_the_unique_common_profile_certificate(self) -> None:
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        fingerprint = hashlib.sha1(self.der[5]).hexdigest().upper()
        self.assertIn("Developer ID certificate fingerprint: " + fingerprint, result.stdout)
        self.assertIn("Developer ID signing inputs verified", result.stdout)

    def test_ambiguous_common_certificates_fail(self) -> None:
        self.widget = self.profile("widget", [1, 5])
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("intersection is not unique (matches=2)", result.stderr)

    def test_no_common_certificate_fails(self) -> None:
        self.widget = self.profile("widget", [3])
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("intersection is not unique (matches=0)", result.stderr)

    def test_swapped_product_profiles_fail(self) -> None:
        result = self.check(swapped=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("application identifier", result.stderr)

    def test_expired_profile_fails(self) -> None:
        self.widget = self.profile("widget", [5], expired=True)
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has expired", result.stderr)

    def test_non_developer_id_certificate_fails(self) -> None:
        self.app = self.profile("app", [0])
        self.widget = self.profile("widget", [0])
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a Developer ID Application", result.stderr)

    def test_private_key_and_malformed_bundle_are_rejected(self) -> None:
        for payload in (b"-----BEGIN PRIVATE KEY-----\n", b"-----BEGIN CERTIFICATE-----\ntruncated"):
            with self.subTest(payload=payload):
                self.bundle.write_bytes(payload)
                self.assertNotEqual(self.check().returncode, 0)


class ImportedIdentityTests(unittest.TestCase):
    def test_exact_profile_fingerprint_wins_over_first_identity(self) -> None:
        text = '  1) ' + 'A' * 40 + ' "Developer ID Application: Other"\n'
        text += '  2) ' + 'B' * 40 + ' "Developer ID Application: Selected"\n     2 valid identities found\n'
        self.assertEqual(select_identity(text, 'B' * 40), "Developer ID Application: Selected")

    def test_missing_duplicate_invalid_or_ambiguous_identity_fails(self) -> None:
        row = '  1) ' + 'B' * 40 + ' "Developer ID Application: Selected"\n'
        other = '  2) ' + 'A' * 40 + ' "Developer ID Application: Selected"\n'
        for text, fingerprint in (("", 'B' * 40), (row + row, 'B' * 40), (row + other, 'B' * 40), (row, "")):
            with self.subTest(text=text, fingerprint=fingerprint), self.assertRaises(ValueError):
                select_identity(text, fingerprint)


if __name__ == "__main__":
    unittest.main()
