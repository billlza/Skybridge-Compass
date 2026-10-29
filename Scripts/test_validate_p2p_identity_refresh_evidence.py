#!/usr/bin/env python3
"""Regression tests for forced PIB-1 -> SKR-1 evidence validation."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import validate_p2p_identity_refresh_evidence as validator


SCRIPT_PATH = Path(__file__).with_name(
    "validate_p2p_identity_refresh_evidence.py"
).resolve()
PIB_REF = "ev1:" + ("a" * 32)
SKR_REF = "ev1:" + ("b" * 32)
PAYLOAD_REF = "ev1:" + ("c" * 32)


def _host_status() -> str:
    return "\n".join(
        [
            f"PIB-1 protocol identity binding served: peer=redacted pib_ref={PIB_REF} lifecycle=identity-oob>served",
            f"PIB-1 v3 confirmation committed and acknowledged pib_ref={PIB_REF} lifecycle=identity-oob>confirmed",
            f"SKR-1 signed LAN KEM refresh served: peer=redacted skr_ref={SKR_REF} payload_ref={PAYLOAD_REF} lifecycle=request>served",
        ]
    )


def _ios_status() -> str:
    return "\n".join(
        [
            "SKR-1 signed LAN KEM refresh forced: peer=redacted clearedKEM=1 preserveProtocolIdentity=1 lifecycle=force-missing-kem",
            f"PIB-1 protocol identity binding request: peer=redacted pib_ref={PIB_REF} lifecycle=identity-oob>request",
            f"PIB-1 protocol identity binding signature verified: peer=redacted pib_ref={PIB_REF} lifecycle=identity-oob>verified",
            f"PIB-1 protocol identity binding confirm sent: peer=redacted pib_ref={PIB_REF} lifecycle=identity-oob>confirm",
            f"PIB-1 protocol identity binding pinned: peer=redacted pib_ref={PIB_REF} lifecycle=identity-oob>pinned",
            f"PIB-1 v3 protocol identity binding final acknowledgement verified and pinned: peer=redacted pib_ref={PIB_REF} lifecycle=identity-oob>final-ack>pinned",
            f"SKR-1 signed LAN KEM refresh request: peer=redacted skr_ref={SKR_REF} recovery_ref={PIB_REF} pinnedProtocolIdentity=1 lifecycle=missing-kem>request",
            f"SKR-1 signed LAN KEM refresh verified and imported: peer=redacted skr_ref={SKR_REF} payload_ref={PAYLOAD_REF} recovery_ref={PIB_REF} suites=X-Wing pinnedProtocolIdentity=1 signature=verified requestHash=bound lifecycle=served>verified",
            f"SKR-1 signed LAN KEM refresh smoke-evidence: peer=redacted source=signed_lan_kem_refresh payload_ref={PAYLOAD_REF} pinnedProtocolIdentity=1 signature=verified requestHash=bound strictXWingEstablished=1 lifecycle=verified>smoke-proof",
        ]
    )


class P2PIdentityRefreshEvidenceTests(unittest.TestCase):
    def test_accepts_complete_forced_pib_then_skr_chain(self) -> None:
        self.assertEqual(
            validator.validate_forced_refresh_evidence(
                _host_status(),
                _ios_status(),
                "X-Wing",
            ),
            "forced-pib-skr",
        )

    def test_rejects_cross_source_console_and_app_cache_splicing(self) -> None:
        console_snapshot = "\n".join(
            [
                _ios_status().splitlines()[0],
                _ios_status().splitlines()[-1],
            ]
        )
        merged = f"{console_snapshot}\n{_ios_status()}"

        with self.assertRaisesRegex(
            validator.EvidenceValidationError,
            "duplicate:forced-refresh",
        ):
            validator.validate_forced_refresh_evidence(
                _host_status(), merged, "X-Wing"
            )

    def test_rejects_existing_pin_and_skr_without_fresh_pib(self) -> None:
        direct_skr = "\n".join(
            line
            for line in _ios_status().splitlines()
            if "PIB-1" not in line
        )

        with self.assertRaisesRegex(
            validator.EvidenceValidationError,
            "missing:pib-request",
        ):
            validator.validate_forced_refresh_evidence(
                _host_status(), direct_skr, "X-Wing"
            )

    def test_rejects_partial_or_out_of_order_pib_chain(self) -> None:
        partial = _ios_status().replace(
            f"PIB-1 protocol identity binding confirm sent: peer=redacted pib_ref={PIB_REF} lifecycle=identity-oob>confirm\n",
            "",
        )

        with self.assertRaisesRegex(
            validator.EvidenceValidationError,
            "missing:pib-confirm",
        ):
            validator.validate_forced_refresh_evidence(
                _host_status(), partial, "X-Wing"
            )

        out_of_order = _ios_status().replace(
            f"PIB-1 protocol identity binding pinned: peer=redacted pib_ref={PIB_REF} lifecycle=identity-oob>pinned\n"
            f"PIB-1 v3 protocol identity binding final acknowledgement verified and pinned: peer=redacted pib_ref={PIB_REF} lifecycle=identity-oob>final-ack>pinned",
            f"PIB-1 v3 protocol identity binding final acknowledgement verified and pinned: peer=redacted pib_ref={PIB_REF} lifecycle=identity-oob>final-ack>pinned\n"
            f"PIB-1 protocol identity binding pinned: peer=redacted pib_ref={PIB_REF} lifecycle=identity-oob>pinned",
        )
        with self.assertRaisesRegex(
            validator.EvidenceValidationError,
            "out-of-order",
        ):
            validator.validate_forced_refresh_evidence(
                _host_status(), out_of_order, "X-Wing"
            )

    def test_rejects_wrong_suite_and_incomplete_host_chain(self) -> None:
        with self.assertRaisesRegex(
            validator.EvidenceValidationError,
            "missing:skr-import",
        ):
            validator.validate_forced_refresh_evidence(
                _host_status(), _ios_status(), "ML-KEM-768"
            )

        missing_confirmation = _host_status().replace(
            f"PIB-1 v3 confirmation committed and acknowledged pib_ref={PIB_REF} lifecycle=identity-oob>confirmed\n",
            "",
        )
        with self.assertRaisesRegex(
            validator.EvidenceValidationError,
            "missing:host-pib-confirmed",
        ):
            validator.validate_forced_refresh_evidence(
                missing_confirmation, _ios_status(), "X-Wing"
            )

    def test_rejects_cross_attempt_operation_splicing(self) -> None:
        other_pib_ref = "ev1:" + ("d" * 32)
        mixed_ios = _ios_status().replace(
            f"recovery_ref={PIB_REF}",
            f"recovery_ref={other_pib_ref}",
        )
        with self.assertRaisesRegex(
            validator.EvidenceValidationError,
            "reference-mismatch:pib-to-skr-recovery",
        ):
            validator.validate_forced_refresh_evidence(
                _host_status(), mixed_ios, "X-Wing"
            )

        mixed_host = _host_status().replace(
            f"skr_ref={SKR_REF}",
            f"skr_ref={'ev1:' + ('e' * 32)}",
        )
        with self.assertRaisesRegex(
            validator.EvidenceValidationError,
            "reference-mismatch:peer-skr",
        ):
            validator.validate_forced_refresh_evidence(
                mixed_host, _ios_status(), "X-Wing"
            )

    def test_rejects_payload_proof_from_another_refresh(self) -> None:
        mixed_proof = _ios_status().replace(
            f"payload_ref={PAYLOAD_REF} pinnedProtocolIdentity=1 signature=verified",
            f"payload_ref={'ev1:' + ('f' * 32)} pinnedProtocolIdentity=1 signature=verified",
            1,
        )
        with self.assertRaisesRegex(
            validator.EvidenceValidationError,
            "reference-mismatch:ios-skr-payload",
        ):
            validator.validate_forced_refresh_evidence(
                _host_status(), mixed_proof, "X-Wing"
            )

    def test_cli_has_stable_success_and_failure_contract(self) -> None:
        with tempfile.TemporaryDirectory(prefix="skybridge-pib-skr-evidence-") as root:
            root_path = Path(root).resolve()
            host_path = root_path / "host.status.log"
            ios_path = root_path / "ios.status.log"
            host_path.write_text(_host_status(), encoding="utf-8")
            ios_path.write_text(_ios_status(), encoding="utf-8")

            success = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--host-status",
                    str(host_path),
                    "--ios-status",
                    str(ios_path),
                    "--expected-suite",
                    "X-Wing",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(success.returncode, 0, success.stderr)
            self.assertEqual(success.stdout, "forced-pib-skr\n")
            self.assertEqual(success.stderr, "")

            ios_path.write_text("direct SKR only\n", encoding="utf-8")
            failure = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--host-status",
                    str(host_path),
                    "--ios-status",
                    str(ios_path),
                    "--expected-suite",
                    "X-Wing",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(failure.returncode, 1)
            self.assertEqual(failure.stdout, "")
            self.assertIn(
                "identity-refresh-evidence-invalid:missing:forced-refresh",
                failure.stderr,
            )

            relative_path = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--host-status",
                    host_path.name,
                    "--ios-status",
                    str(ios_path),
                    "--expected-suite",
                    "X-Wing",
                ],
                check=False,
                capture_output=True,
                text=True,
                cwd=root_path,
            )
            self.assertEqual(relative_path.returncode, 2)
            self.assertEqual(relative_path.stdout, "")
            self.assertIn("host-status-path-not-absolute", relative_path.stderr)

            host_symlink = root_path / "host-link.status.log"
            host_symlink.symlink_to(host_path)
            symlink = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--host-status",
                    str(host_symlink),
                    "--ios-status",
                    str(ios_path),
                    "--expected-suite",
                    "X-Wing",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(symlink.returncode, 2)
            self.assertEqual(symlink.stdout, "")
            self.assertIn("host-status-not-regular-file", symlink.stderr)


if __name__ == "__main__":
    unittest.main()
