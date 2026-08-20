#!/usr/bin/env python3
"""Unit tests for the immutable macOS release candidate identity contract."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / "Scripts/macos_release_candidate_identity.py"


def valid_payload() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "source": {"repository": "example/skybridge", "commit": "a" * 40},
        "product": {
            "bundleIdentifier": "com.skybridge.compass.pro",
            "version": "1.2.3",
            "build": "42",
            "teamIdentifier": "ABCDEFGHIJ",
            "cdHash": "b" * 40,
            "designatedRequirement": 'identifier "com.skybridge.compass.pro" and anchor apple generic',
        },
        "platformValidation": {
            "codeSignatureValid": True,
            "notarizationAccepted": True,
            "appStaplerValid": True,
            "dmgStaplerValid": True,
            "appGatekeeperAccepted": True,
            "dmgGatekeeperAccepted": True,
        },
        "artifactBinding": {
            "algorithm": "sha256",
            "purpose": "detect accidental candidate/evidence mismatch",
            "appBundleDigest": "c" * 64,
            "dmgDigest": "d" * 64,
            "dmgFileName": "SkyBridgeCompassPro-1.2.3.dmg",
        },
    }


class CandidateIdentityTests(unittest.TestCase):
    def write_manifest(self, path: Path, payload: dict[str, object], *, canonical: bool = True) -> None:
        if canonical:
            content = json.dumps(payload, indent=2, sort_keys=True) + "\n"
        else:
            content = json.dumps(payload) + "\n"
        path.write_text(content, encoding="utf-8")

    def run_target(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(TARGET), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_validate_accepts_canonical_complete_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "candidate.json"
            self.write_manifest(manifest, valid_payload())
            result = self.run_target("validate", "--identity", str(manifest))
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_validate_rejects_noncanonical_or_incomplete_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            noncanonical = root / "noncanonical.json"
            self.write_manifest(noncanonical, valid_payload(), canonical=False)
            result = self.run_target("validate", "--identity", str(noncanonical))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not canonical JSON", result.stderr)

            incomplete = root / "incomplete.json"
            payload = valid_payload()
            del payload["platformValidation"]
            self.write_manifest(incomplete, payload)
            result = self.run_target("validate", "--identity", str(incomplete))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid top-level shape", result.stderr)

    def test_compare_rejects_candidate_byte_or_identity_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            expected = root / "expected.json"
            actual = root / "actual.json"
            self.write_manifest(expected, valid_payload())
            changed = valid_payload()
            changed["artifactBinding"]["dmgDigest"] = "e" * 64  # type: ignore[index]
            self.write_manifest(actual, changed)
            result = self.run_target(
                "compare", "--expected", str(expected), "--actual", str(actual)
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exact same candidate", result.stderr)

    def test_validate_rejects_digest_claimed_as_security_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "candidate.json"
            payload = valid_payload()
            payload["artifactBinding"]["purpose"] = "prevent malicious modification"  # type: ignore[index]
            self.write_manifest(manifest, payload)
            result = self.run_target("validate", "--identity", str(manifest))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("binding purpose is invalid", result.stderr)


if __name__ == "__main__":
    unittest.main()
