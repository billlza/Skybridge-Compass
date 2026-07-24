#!/usr/bin/env python3
"""Authenticated Apple provisioning-profile loader for the formal iOS release
evidence path.

A genuine ``.mobileprovision`` / ``.provisionprofile`` is a CMS (PKCS#7) signed
blob whose signer is Apple's *Provisioning Profile Signing* authority. The
formal acceptance-evidence path must never:

* accept a bare (unsigned) plist that merely *looks* like a decoded profile,
* accept a CMS blob whose signature does not verify (tampered payload), or
* skip signer trust (``openssl ... -verify -noverify`` / ``security cms -D``
  decode but do NOT prove Apple signed the profile — ``security cms -D`` even
  decodes a byte-tampered profile successfully on macOS).

Verification pipeline (order-independent, portable to the LibreSSL ``openssl``
shipped by macOS):

1. ``openssl cms -verify -no_signer_cert_verify -signer <out>`` cryptographically
   verifies the CMS signature against the embedded signer, writes the *actual*
   signer certificate, and writes the signature-verified payload. This rejects a
   bare plist and any tampered/forged-signature profile.
2. The emitted signer certificate subject must be an Apple *Provisioning Profile
   Signing* authority (covers both "Apple iPhone OS ..." and "Mac OS X ..."
   variants; ``O=Apple Inc.`` provides the "Apple" token).
3. ``security verify-cert`` must trust that exact signer certificate, i.e. it
   chains to an Apple root in the system keychain. An attacker-minted certificate
   with the same common name fails this step, and a profile signed with a
   non-Apple key fails step 1.

The signature-verified payload from step 1 is parsed as the profile plist, so the
returned dictionary is exactly the content Apple signed.

``ProfileAuthenticityError`` subclasses ``ValueError`` so existing candidate
scanners that already treat ``ValueError`` as "skip this candidate" fail closed
without crashing.
"""
from __future__ import annotations

import plistlib
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory

SECURITY_BIN = "/usr/bin/security"
OPENSSL_BIN = "/usr/bin/openssl"

_PROVISIONING_PROFILE_SIGNING_MARKER = "Provisioning Profile Signing"
_APPLE_ORGANIZATION_MARKER = "Apple"


class ProfileAuthenticityError(ValueError):
    """Raised when a provisioning profile is not an authentic Apple CMS blob."""


def _cms_verify_signature(path: Path, signer_out: Path, payload_out: Path) -> None:
    """Cryptographically verify the CMS signature, emitting the actual signer
    certificate and the signature-verified payload.

    ``-no_signer_cert_verify`` checks the signature against the embedded signer
    without requiring openssl's own (empty on macOS) CA store to trust it; trust
    is established separately against the system keychain.
    """
    completed = subprocess.run(
        [
            OPENSSL_BIN,
            "cms",
            "-verify",
            "-inform",
            "DER",
            "-in",
            str(path),
            "-no_signer_cert_verify",
            "-signer",
            str(signer_out),
            "-out",
            str(payload_out),
        ],
        check=False,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise ProfileAuthenticityError(
            f"provisioning profile CMS signature did not verify (or is not a CMS blob): {path}"
        )
    if not signer_out.exists() or signer_out.stat().st_size <= 0:
        raise ProfileAuthenticityError(
            f"provisioning profile CMS envelope exposed no signer certificate: {path}"
        )
    if not payload_out.exists() or payload_out.stat().st_size <= 0:
        raise ProfileAuthenticityError(
            f"provisioning profile CMS envelope exposed no signed payload: {path}"
        )


def _assert_apple_signer_trusted(signer_pem: Path, path: Path) -> None:
    subject = subprocess.run(
        [OPENSSL_BIN, "x509", "-in", str(signer_pem), "-noout", "-subject"],
        check=False,
        capture_output=True,
        text=True,
    )
    subject_text = (subject.stdout or "").strip()
    if (
        subject.returncode != 0
        or _PROVISIONING_PROFILE_SIGNING_MARKER not in subject_text
        or _APPLE_ORGANIZATION_MARKER not in subject_text
    ):
        raise ProfileAuthenticityError(
            f"provisioning profile CMS signer is not the Apple Provisioning Profile Signing authority: {path}"
        )
    trusted = subprocess.run(
        [SECURITY_BIN, "verify-cert", "-c", str(signer_pem)],
        check=False,
        capture_output=True,
    )
    if trusted.returncode != 0:
        raise ProfileAuthenticityError(
            f"provisioning profile CMS signer failed trust-chain verification: {path}"
        )


def load_verified_profile(path, *, verify_authenticity: bool = True) -> dict:
    """Return the decoded provisioning-profile dictionary.

    With ``verify_authenticity`` (the default, required on the formal path) the
    CMS signature, signer authority, and trust chain are all enforced. When set
    to ``False`` the CMS signature is still verified (a bare/unsigned plist is
    always rejected) but the Apple signer-authority/trust checks are skipped.
    """
    path = Path(path)
    with TemporaryDirectory() as work:
        signer_pem = Path(work) / "signer.pem"
        payload_bin = Path(work) / "payload.bin"
        _cms_verify_signature(path, signer_pem, payload_bin)
        if verify_authenticity:
            _assert_apple_signer_trusted(signer_pem, path)
        payload = payload_bin.read_bytes()
    try:
        profile = plistlib.loads(payload)
    except Exception as error:  # noqa: BLE001 - re-raised as domain error
        raise ProfileAuthenticityError(
            f"signature-verified provisioning payload is not a valid plist: {path}"
        ) from error
    if not isinstance(profile, dict):
        raise ProfileAuthenticityError(
            f"signature-verified provisioning profile is not a dictionary: {path}"
        )
    return profile
