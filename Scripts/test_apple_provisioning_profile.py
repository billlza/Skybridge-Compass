#!/usr/bin/env python3
"""Tests for the authenticated Apple provisioning-profile loader.

Positive cases require a real Apple-signed profile and are skipped when one is
not available in the environment (e.g. CI without a signed archive). Negative
cases (bare plist, truncated CMS) run everywhere and are the security-critical
regression guards for the formal release-evidence path.
"""
from __future__ import annotations

import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import apple_provisioning_profile as app_profile  # noqa: E402


def _discover_real_profile() -> Path | None:
    override = os.environ.get("SKYBRIDGE_TEST_REAL_PROFILE")
    if override and Path(override).is_file():
        return Path(override)
    root = SCRIPTS_DIR.parent
    candidates = list(root.glob(
        ".sandbox-home/**/Products/Applications/*.app/embedded.mobileprovision"
    ))
    candidates += list(root.glob(
        ".sandbox-home/**/Products/Applications/*.app/PlugIns/*.appex/embedded.mobileprovision"
    ))
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    # Fall back to any installed Xcode profile.
    for directory in (
        Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
        Path.home() / "Library/MobileDevice/Provisioning Profiles",
    ):
        if directory.is_dir():
            for candidate in directory.iterdir():
                if candidate.suffix in {".mobileprovision", ".provisionprofile"}:
                    return candidate
    return None


REAL_PROFILE = _discover_real_profile()


class ProfileAuthenticityNegativeTests(unittest.TestCase):
    """These must reject regardless of environment."""

    def test_bare_plist_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            bare = Path(work) / "bare.mobileprovision"
            bare.write_bytes(
                plistlib.dumps({"Entitlements": {"application-identifier": "X.Y"}})
            )
            with self.assertRaises(app_profile.ProfileAuthenticityError):
                app_profile.load_verified_profile(bare)
            # Even without authenticity verification, a bare plist must fail the
            # strict CMS decode.
            with self.assertRaises(app_profile.ProfileAuthenticityError):
                app_profile.load_verified_profile(bare, verify_authenticity=False)

    def test_random_bytes_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            junk = Path(work) / "junk.mobileprovision"
            junk.write_bytes(os.urandom(2048))
            with self.assertRaises(app_profile.ProfileAuthenticityError):
                app_profile.load_verified_profile(junk)

    def test_authenticity_error_is_valueerror(self) -> None:
        # resolve_ios_distribution_signing.validate_profile relies on ValueError
        # to skip non-authentic candidates instead of crashing the scan.
        self.assertTrue(issubclass(app_profile.ProfileAuthenticityError, ValueError))


@unittest.skipUnless(REAL_PROFILE is not None, "no real Apple-signed profile available")
class ProfileAuthenticityPositiveTests(unittest.TestCase):
    def test_real_profile_loads_and_verifies(self) -> None:
        profile = app_profile.load_verified_profile(REAL_PROFILE)
        self.assertIsInstance(profile, dict)
        self.assertIn("Entitlements", profile)

    def test_tampered_cms_payload_is_rejected(self) -> None:
        # Flipping bytes in the middle of a genuine CMS blob must break either
        # the CMS decode or the signer verification.
        data = bytearray(REAL_PROFILE.read_bytes())
        midpoint = len(data) // 2
        for offset in range(midpoint, midpoint + 64):
            data[offset] ^= 0xFF
        with tempfile.TemporaryDirectory() as work:
            tampered = Path(work) / "tampered.mobileprovision"
            tampered.write_bytes(bytes(data))
            with self.assertRaises(app_profile.ProfileAuthenticityError):
                app_profile.load_verified_profile(tampered)

    def test_reencoded_plist_payload_without_cms_is_rejected(self) -> None:
        # Decode the real payload, re-serialise it as a bare plist, and confirm
        # the loader rejects the unsigned substitution.
        decoded = subprocess.run(
            ["/usr/bin/security", "cms", "-D", "-i", str(REAL_PROFILE)],
            check=True,
            capture_output=True,
        ).stdout
        payload = plistlib.loads(decoded)
        with tempfile.TemporaryDirectory() as work:
            forged = Path(work) / "forged.mobileprovision"
            forged.write_bytes(plistlib.dumps(payload))
            with self.assertRaises(app_profile.ProfileAuthenticityError):
                app_profile.load_verified_profile(forged)


if __name__ == "__main__":
    unittest.main()
