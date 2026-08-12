#!/usr/bin/env python3
"""Regression tests for native-PQC physical runtime evidence parsing."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "validate_android_pqc_native_runtime_evidence.py"
SPEC = importlib.util.spec_from_file_location("native_pqc_runtime_evidence", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load native PQC runtime evidence validator")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def marker(profile: str, api: int, abi: str, page_size: int) -> str:
    return (
        "INSTRUMENTATION_STATUS: stream="
        "SB-PQC-NATIVE-RUNTIME schema=1 "
        f"profile={profile} provider=liboqs-android api={api} abi={abi} "
        f"page_size={page_size} native_load=true mlkem_keygen=true "
        "mlkem_encaps=true mlkem_decaps=true mlkem_secret_match=true "
        "mldsa_keygen=true mldsa_sign=true mldsa_verify=true "
        "mldsa_negative_message=true mldsa_negative_signature=true cleanup=true"
    )


class NativePqcRuntimeEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.samsung = self.root / "samsung.txt"
        self.api37 = self.root / "api37.txt"
        self._write_success(
            self.samsung,
            marker("samsung-api36-4k", 36, "arm64-v8a", 4_096),
        )
        self._write_success(
            self.api37,
            marker("api37-16k", 37, "arm64-v8a", 16_384),
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def _write_success(path: Path, result_marker: str) -> None:
        path.write_text(
            "INSTRUMENTATION_STATUS: class=test\n"
            f"{result_marker}\n"
            "Time: 0.125\n\n"
            "OK (1 test)\n"
            "INSTRUMENTATION_CODE: -1\n",
            encoding="utf-8",
        )

    def _build(self, api37_abi: str = "arm64-v8a") -> dict[str, object]:
        return MODULE.build_evidence(
            source_commit="1" * 40,
            app_apk_sha256="2" * 64,
            app_apk_bytes=1024,
            test_apk_sha256="3" * 64,
            test_apk_bytes=512,
            samsung_output=self.samsung,
            api37_output=self.api37,
            api37_abi=api37_abi,
        )

    def test_exact_two_profile_matrix_passes_without_device_identity(self) -> None:
        payload = self._build()

        self.assertIs(payload["matrixComplete"], True)
        self.assertEqual(payload["sourceCommit"], "1" * 40)
        self.assertEqual(
            [run["profile"] for run in payload["runs"]],
            ["samsung-api36-4k", "api37-16k"],
        )
        serialized = json.dumps(payload, sort_keys=True)
        self.assertNotIn("serial", serialized.lower())
        self.assertNotIn("deviceId", serialized)
        for forbidden_field in (
            "privateKey",
            "publicKey",
            "ciphertextBytes",
            "sharedSecret",
            "signatureBytes",
        ):
            self.assertNotIn(forbidden_field, serialized)

    def test_api_page_size_and_abi_are_independent_exact_fields(self) -> None:
        self._write_success(
            self.api37,
            marker("api37-16k", 37, "x86_64", 16_384),
        )
        payload = self._build(api37_abi="x86_64")
        self.assertEqual(payload["runs"][1]["apiLevel"], 37)
        self.assertEqual(payload["runs"][1]["pageSizeBytes"], 16_384)
        self.assertEqual(payload["runs"][1]["abi"], "x86_64")

        with self.assertRaisesRegex(MODULE.NativePqcEvidenceError, "runtime identity"):
            self._build(api37_abi="arm64-v8a")

    def test_failure_duplicate_or_noncanonical_marker_fails_closed(self) -> None:
        fixtures = (
            self.api37.read_text(encoding="utf-8") + "FAILURES!!!\n",
            self.api37.read_text(encoding="utf-8")
            + marker("api37-16k", 37, "arm64-v8a", 16_384)
            + "\n",
            self.api37.read_text(encoding="utf-8").replace(
                "mlkem_secret_match=true",
                "mlkem_secret_match=false",
            ),
            self.api37.read_text(encoding="utf-8").replace("OK (1 test)", "OK (2 tests)"),
        )
        for fixture in fixtures:
            with self.subTest(fixture=fixture[-80:]):
                self.api37.write_text(fixture, encoding="utf-8")
                with self.assertRaises(MODULE.NativePqcEvidenceError):
                    self._build()

    def test_duplicate_success_line_fails_closed(self) -> None:
        self.api37.write_text(
            self.api37.read_text(encoding="utf-8").replace(
                "INSTRUMENTATION_CODE: -1\n",
                "OK (1 test)\nINSTRUMENTATION_CODE: -1\n",
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(MODULE.NativePqcEvidenceError, "exactly one"):
            self._build()

    def test_extra_or_failed_terminal_code_fails_closed(self) -> None:
        fixtures = (
            self.api37.read_text(encoding="utf-8") + "INSTRUMENTATION_CODE: 0\n",
            self.api37.read_text(encoding="utf-8").replace(
                "INSTRUMENTATION_CODE: -1",
                "INSTRUMENTATION_CODE: 0",
            ),
        )
        for fixture in fixtures:
            with self.subTest(fixture=fixture[-80:]):
                self.api37.write_text(fixture, encoding="utf-8")
                with self.assertRaisesRegex(MODULE.NativePqcEvidenceError, "terminal code"):
                    self._build()

    def test_success_text_without_terminal_code_fails_closed(self) -> None:
        self.api37.write_text(
            self.api37.read_text(encoding="utf-8").replace(
                "INSTRUMENTATION_CODE: -1\n",
                "",
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(MODULE.NativePqcEvidenceError, "terminal code"):
            self._build()

    def test_digest_source_and_output_contracts_fail_closed(self) -> None:
        with self.assertRaisesRegex(MODULE.NativePqcEvidenceError, "source commit"):
            MODULE.build_evidence(
                source_commit="not-a-commit",
                app_apk_sha256="2" * 64,
                app_apk_bytes=1024,
                test_apk_sha256="3" * 64,
                test_apk_bytes=512,
                samsung_output=self.samsung,
                api37_output=self.api37,
                api37_abi="arm64-v8a",
            )

        payload = self._build()
        output = self.root / "evidence.json"
        MODULE._atomic_new(output, payload)
        self.assertEqual(json.loads(output.read_text(encoding="utf-8")), payload)
        with self.assertRaisesRegex(MODULE.NativePqcEvidenceError, "new absolute"):
            MODULE._atomic_new(output, payload)


if __name__ == "__main__":
    unittest.main()
