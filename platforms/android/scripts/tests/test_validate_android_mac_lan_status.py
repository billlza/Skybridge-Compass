#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "validate_android_mac_lan_status.py"
SPEC = importlib.util.spec_from_file_location("validate_android_mac_lan_status", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


RUN_REF = "a" * 64
STAMP = "[2026-08-10 18:00:00] "


class AndroidMacLanStatusValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.status_path = Path(self.temporary_directory.name) / "status.log"

    def write_payloads(self, *payloads: str) -> None:
        self.status_path.write_text(
            "".join(f"{STAMP}{payload}\n" for payload in payloads),
            encoding="utf-8",
        )

    def inspect(
        self,
        *,
        require_secure: bool = True,
        allow_plaintext_fallback: bool = False,
        require_existing_product_trust: bool = True,
    ) -> str:
        return MODULE.inspect_status(
            self.status_path,
            RUN_REF,
            require_secure=require_secure,
            allow_plaintext_fallback=allow_plaintext_fallback,
            require_existing_product_trust=require_existing_product_trust,
        )

    def test_missing_or_attempt_only_status_is_pending(self) -> None:
        self.assertEqual("pending", self.inspect())
        self.write_payloads(f"attempt ref={RUN_REF}")
        self.assertEqual("pending", self.inspect())

    def test_existing_product_secure_frame_requires_one_ordered_current_owner_chain(self) -> None:
        self.write_payloads(
            f"attempt ref={RUN_REF}",
            "state connected host=<redacted>",
            MODULE.ROUTE_AUTHORITY_LINE,
            "security secure peer=present:length=8:sha256=0123456789ab "
            "suite=XWING trust=TRUSTED_EXISTING",
            MODULE.IDENTITY_LINE,
            "frame width=1280 height=720 format=h264 owner=current",
            "success reason=secure_frame_received",
        )

        self.assertEqual("success:secure", self.inspect())

    def test_old_frame_cannot_be_joined_to_a_new_secure_generation(self) -> None:
        self.write_payloads(
            f"attempt ref={RUN_REF}",
            MODULE.ROUTE_AUTHORITY_LINE,
            "security secure peer=present:length=8:sha256=0123456789ab "
            "suite=XWING trust=TRUSTED_EXISTING",
            "frame width=1280 height=720 format=h264 owner=current",
            "state connecting host=<redacted>",
            "security secure peer=present:length=8:sha256=0123456789ab "
            "suite=XWING trust=TRUSTED_EXISTING",
            MODULE.IDENTITY_LINE,
            "success reason=secure_frame_received",
        )

        with self.assertRaisesRegex(MODULE.StatusContractError, "frame and success"):
            self.inspect()

    def test_wrong_or_repeated_attempt_marker_is_rejected(self) -> None:
        self.write_payloads(f"attempt ref={'b' * 64}")
        with self.assertRaisesRegex(MODULE.StatusContractError, "expected attempt"):
            self.inspect()

        self.write_payloads(f"attempt ref={RUN_REF}", f"attempt ref={RUN_REF}")
        with self.assertRaisesRegex(MODULE.StatusContractError, "repeats"):
            self.inspect()

    def test_trusted_new_cannot_satisfy_existing_product_authority(self) -> None:
        self.write_payloads(
            f"attempt ref={RUN_REF}",
            MODULE.ROUTE_AUTHORITY_LINE,
            "security secure peer=present:length=8:sha256=0123456789ab "
            "suite=XWING trust=TRUSTED_NEW",
            MODULE.IDENTITY_LINE,
            "frame width=640 height=480 format=jpeg owner=current",
            "success reason=secure_frame_received",
        )

        with self.assertRaisesRegex(MODULE.StatusContractError, "existing-trust"):
            self.inspect()

    def test_existing_product_success_requires_one_route_marker_before_secure_state(self) -> None:
        secure_chain = (
            "security secure peer=present:length=8:sha256=0123456789ab "
            "suite=XWING trust=TRUSTED_EXISTING",
            MODULE.IDENTITY_LINE,
            "frame width=640 height=480 format=jpeg owner=current",
            "success reason=secure_frame_received",
        )
        self.write_payloads(f"attempt ref={RUN_REF}", *secure_chain)
        with self.assertRaisesRegex(MODULE.StatusContractError, "route lease"):
            self.inspect()

        self.write_payloads(
            f"attempt ref={RUN_REF}",
            secure_chain[0],
            MODULE.ROUTE_AUTHORITY_LINE,
            *secure_chain[1:],
        )
        with self.assertRaisesRegex(MODULE.StatusContractError, "route lease"):
            self.inspect()

        self.write_payloads(
            f"attempt ref={RUN_REF}",
            MODULE.ROUTE_AUTHORITY_LINE,
            MODULE.ROUTE_AUTHORITY_LINE,
            *secure_chain,
        )
        with self.assertRaisesRegex(MODULE.StatusContractError, "route lease"):
            self.inspect()

    def test_terminal_events_must_be_unique_final_and_ordered(self) -> None:
        self.write_payloads(
            f"attempt ref={RUN_REF}",
            "success reason=secure_frame_received",
            "state disconnected seenServices=0",
        )
        with self.assertRaisesRegex(MODULE.StatusContractError, "final"):
            self.inspect()

        self.write_payloads(
            f"attempt ref={RUN_REF}",
            "failure reason=timeout",
            "success reason=secure_frame_received",
        )
        with self.assertRaisesRegex(MODULE.StatusContractError, "both"):
            self.inspect()

    def test_control_format_and_newline_injection_are_rejected(self) -> None:
        self.status_path.write_text(
            f"{STAMP}attempt ref={RUN_REF}\n"
            "success reason=secure_frame_received\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(MODULE.StatusContractError, "stamped format"):
            self.inspect()

        self.status_path.write_text(
            f"{STAMP}attempt ref={RUN_REF}\n{STAMP}state connected\u202e spoofed\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(MODULE.StatusContractError, "control or format"):
            self.inspect()

    def test_polling_ignores_one_incomplete_append_but_final_validation_rejects_it(self) -> None:
        self.status_path.write_text(
            f"{STAMP}attempt ref={RUN_REF}\n"
            f"{STAMP}security secure peer=present:length=8:sha256=0123456789ab ",
            encoding="utf-8",
        )

        self.assertEqual(
            "pending",
            MODULE.inspect_status(
                self.status_path,
                RUN_REF,
                require_secure=True,
                allow_plaintext_fallback=False,
                require_existing_product_trust=True,
                allow_incomplete_tail=True,
            ),
        )
        with self.assertRaisesRegex(MODULE.StatusContractError, "newline terminated"):
            self.inspect()

    def test_known_pairing_blocker_is_typed_without_becoming_success(self) -> None:
        self.write_payloads(
            f"attempt ref={RUN_REF}",
            "failure reason=missing peer KEM bootstrap",
        )
        self.assertEqual("failure:normal_product_pairing_required", self.inspect())

    def test_plaintext_success_is_diagnostic_only(self) -> None:
        self.write_payloads(
            f"attempt ref={RUN_REF}",
            "security plaintext reason=explicit-debug-mode",
            "success reason=plaintext_frame_received",
        )
        self.assertEqual(
            "success:plaintext",
            self.inspect(
                require_secure=False,
                allow_plaintext_fallback=True,
                require_existing_product_trust=False,
            ),
        )
        with self.assertRaisesRegex(MODULE.StatusContractError, "transport policy"):
            self.inspect()

    def test_symlink_status_is_rejected(self) -> None:
        target = self.status_path.with_name("target.log")
        target.write_text("", encoding="utf-8")
        self.status_path.symlink_to(target)
        with self.assertRaisesRegex(MODULE.StatusContractError, "non-symlink"):
            self.inspect()


if __name__ == "__main__":
    unittest.main()
