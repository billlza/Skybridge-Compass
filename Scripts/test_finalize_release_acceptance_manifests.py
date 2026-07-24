#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import finalize_release_acceptance_manifests as finalizer


class ReleaseAcceptanceManifestFinalizerTests(unittest.TestCase):
    def create_manifests(
        self,
        root: Path,
        *,
        candidate: bool = True,
    ) -> tuple[Path, Path, bytes]:
        private_directory = root / "private"
        public_directory = root / "public"
        private_directory.mkdir(mode=0o700)
        public_directory.mkdir(mode=0o700)
        payload = {
            "acceptanceEligible": False,
            "cleanupComplete": False,
            "diagnosticOnly": True,
            "preCleanupCandidate": candidate,
            "schemaVersion": 1,
            "transport": "webrtc",
            "iosProductSurface": "production",
            "iosSwiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
            "iosTestingCompilationCondition": False,
            "iosBinaryTestSurfaceDetected": False,
            "iosProductionProduct": True,
            "iosProductionIdentityAlgorithm": "mldsa87",
            "iosProductionIdentityProtection": "secureEnclaveRequired",
            "iosProductionIdentityLifecycleVerified": True,
            "iosProductionIdentityProof": True,
        }
        raw = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
        private_path = private_directory / finalizer.MANIFEST_FILE_NAME
        public_path = public_directory / finalizer.MANIFEST_FILE_NAME
        for path in (private_path, public_path):
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                self.write_all(descriptor, raw)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            directory_descriptor = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
        return private_path, public_path, raw

    @staticmethod
    def write_all(descriptor: int, content: bytes) -> None:
        offset = 0
        while offset < len(content):
            written = os.write(descriptor, content[offset:])
            if written <= 0:
                raise OSError("short test fixture write")
            offset += written

    @staticmethod
    def read_payload(path: Path) -> dict[str, object]:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise AssertionError("manifest fixture is not a JSON object")
        return payload

    def assert_pre_cleanup_red(self, path: Path, original: bytes) -> None:
        self.assertEqual(path.read_bytes(), original)
        payload = self.read_payload(path)
        self.assertIs(payload["acceptanceEligible"], False)
        self.assertIs(payload["cleanupComplete"], False)
        self.assertIs(payload["diagnosticOnly"], True)
        self.assertNotIn("finalizationOrder", payload)

    def assert_final_green(self, path: Path) -> None:
        payload = self.read_payload(path)
        self.assertIs(payload["acceptanceEligible"], True)
        self.assertIs(payload["cleanupComplete"], True)
        self.assertIs(payload["diagnosticOnly"], False)
        self.assertEqual(payload["finalizationOrder"], finalizer.FINALIZATION_ORDER)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.stat().st_uid, os.geteuid())
        self.assertEqual(path.stat().st_nlink, 1)

    def test_finalizes_private_then_public_and_records_order(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            private_path, public_path, _ = self.create_manifests(root)
            phases: list[str] = []

            def record_phase(phase: str, _: Path) -> None:
                phases.append(phase)

            finalizer.finalize_release_acceptance_manifests(
                private_path,
                public_path,
                fault_injector=record_phase,
            )

            self.assert_final_green(private_path)
            self.assert_final_green(public_path)
            self.assertEqual(private_path.read_bytes(), public_path.read_bytes())
            self.assertLess(
                phases.index("after-private-verify"),
                phases.index("before-public-final-replace"),
            )

    def test_private_write_failure_cannot_make_either_manifest_green(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            private_path, public_path, original = self.create_manifests(Path(raw_root))

            def fail_private_replace(phase: str, _: Path) -> None:
                if phase == "before-private-final-replace":
                    raise OSError("injected private replace failure")

            with self.assertRaisesRegex(finalizer.FinalizationError, "private-final"):
                finalizer.finalize_release_acceptance_manifests(
                    private_path,
                    public_path,
                    fault_injector=fail_private_replace,
                )

            self.assert_pre_cleanup_red(private_path, original)
            self.assert_pre_cleanup_red(public_path, original)
            self.assertEqual(list(private_path.parent.glob(".release-acceptance.json.*")), [])

    def test_testing_surface_cannot_be_finalized_as_acceptance_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            private_path, public_path, _ = self.create_manifests(Path(raw_root))
            for path in (private_path, public_path):
                payload = self.read_payload(path)
                payload["iosProductSurface"] = "testing"
                payload["iosSwiftActiveCompilationConditions"] = [
                    "HAS_APPLE_PQC_SDK",
                    "SKYBRIDGE_TESTING",
                ]
                payload["iosTestingCompilationCondition"] = True
                payload["iosBinaryTestSurfaceDetected"] = True
                content = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode(
                    "utf-8"
                )
                descriptor = os.open(path, os.O_WRONLY | os.O_TRUNC)
                try:
                    self.write_all(descriptor, content)
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)

            with self.assertRaisesRegex(
                finalizer.FinalizationError,
                "iosProductSurface must be production",
            ):
                finalizer.finalize_release_acceptance_manifests(
                    private_path,
                    public_path,
                )

            self.assertIs(self.read_payload(private_path)["acceptanceEligible"], False)
            self.assertIs(self.read_payload(public_path)["acceptanceEligible"], False)

    def test_private_readback_failure_stops_before_public_write(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            private_path, public_path, original = self.create_manifests(Path(raw_root))

            def corrupt_private_before_verify(phase: str, path: Path) -> None:
                if phase != "before-private-verify":
                    return
                payload = self.read_payload(path)
                payload["injectedReadbackCorruption"] = True
                content = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
                descriptor = os.open(path, os.O_WRONLY | os.O_TRUNC)
                try:
                    self.write_all(descriptor, content)
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)

            with self.assertRaisesRegex(finalizer.FinalizationError, "read-back verification"):
                finalizer.finalize_release_acceptance_manifests(
                    private_path,
                    public_path,
                    fault_injector=corrupt_private_before_verify,
                )

            private_payload = self.read_payload(private_path)
            self.assertIs(private_payload["acceptanceEligible"], True)
            self.assertTrue(private_payload["injectedReadbackCorruption"])
            self.assert_pre_cleanup_red(public_path, original)

    def test_public_write_failure_keeps_verified_private_and_public_red(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            private_path, public_path, original = self.create_manifests(Path(raw_root))
            private_verified = False

            def fail_public_replace(phase: str, _: Path) -> None:
                nonlocal private_verified
                if phase == "after-private-verify":
                    private_verified = True
                if phase == "before-public-final-replace":
                    self.assertTrue(private_verified)
                    raise OSError("injected public replace failure")

            with self.assertRaisesRegex(finalizer.FinalizationError, "public-final"):
                finalizer.finalize_release_acceptance_manifests(
                    private_path,
                    public_path,
                    fault_injector=fail_public_replace,
                )

            self.assertTrue(private_verified)
            self.assert_final_green(private_path)
            self.assert_pre_cleanup_red(public_path, original)
            self.assertEqual(list(public_path.parent.glob(".release-acceptance.json.*")), [])

    def test_rejects_unsafe_manifest_metadata_before_any_write(self) -> None:
        with self.subTest("regular-file"):
            with tempfile.TemporaryDirectory() as raw_root:
                private_path, public_path, original = self.create_manifests(Path(raw_root))
                private_path.unlink()
                private_path.mkdir(mode=0o700)
                with self.assertRaisesRegex(finalizer.FinalizationError, "regular file"):
                    finalizer.finalize_release_acceptance_manifests(private_path, public_path)
                self.assert_pre_cleanup_red(public_path, original)

        with self.subTest("mode"):
            with tempfile.TemporaryDirectory() as raw_root:
                private_path, public_path, original = self.create_manifests(Path(raw_root))
                private_path.chmod(0o640)
                with self.assertRaisesRegex(finalizer.FinalizationError, "mode must be 0600"):
                    finalizer.finalize_release_acceptance_manifests(private_path, public_path)
                self.assert_pre_cleanup_red(public_path, original)

        with self.subTest("hard-link"):
            with tempfile.TemporaryDirectory() as raw_root:
                private_path, public_path, original = self.create_manifests(Path(raw_root))
                os.link(private_path, private_path.parent / "extra-link.json")
                with self.assertRaisesRegex(
                    finalizer.FinalizationError,
                    "exactly one filesystem link",
                ):
                    finalizer.finalize_release_acceptance_manifests(private_path, public_path)
                self.assert_pre_cleanup_red(public_path, original)

        with self.subTest("symlink"):
            with tempfile.TemporaryDirectory() as raw_root:
                private_path, public_path, original = self.create_manifests(Path(raw_root))
                target = private_path.parent / "target.json"
                private_path.rename(target)
                private_path.symlink_to(target.name)
                with self.assertRaisesRegex(finalizer.FinalizationError, "without following links"):
                    finalizer.finalize_release_acceptance_manifests(private_path, public_path)
                self.assert_pre_cleanup_red(public_path, original)

        with self.subTest("size"):
            with tempfile.TemporaryDirectory() as raw_root:
                private_path, public_path, original = self.create_manifests(Path(raw_root))
                private_path.write_bytes(b"x" * (finalizer.MAX_MANIFEST_BYTES + 1))
                private_path.chmod(0o600)
                with self.assertRaisesRegex(finalizer.FinalizationError, "manifest size"):
                    finalizer.finalize_release_acceptance_manifests(private_path, public_path)
                self.assert_pre_cleanup_red(public_path, original)


if __name__ == "__main__":
    unittest.main()
