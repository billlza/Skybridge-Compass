#!/usr/bin/env python3
"""Full-fidelity tests for the packaged FreeRDP runtime closure gate.

The tests exercise ``verify_packaged_freerdp_runtime.py`` against app bundles
assembled from the real vendored closure dylibs, re-signed with a different
ad-hoc identity exactly like release packaging re-signs them, so the
signature-invariant byte binding is proven end to end rather than mocked.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = ROOT_DIR / "Scripts"
VERIFIER = SCRIPTS_DIR / "verify_packaged_freerdp_runtime.py"
PROVENANCE = ROOT_DIR / "Sources/Vendor/FreeRDPRuntime.provenance.json"
LOCK = ROOT_DIR / "Config/native-dependencies.lock.json"
VENDOR_DYLIBS = ROOT_DIR / "Sources/Vendor/FreeRDPDylibs"


def run_verifier(app_path: Path, **overrides: Path) -> subprocess.CompletedProcess[str]:
    command = [sys.executable, str(VERIFIER), "--app-path", str(app_path)]
    for flag, value in overrides.items():
        command.extend([f"--{flag.replace('_', '-')}", str(value)])
    return subprocess.run(command, capture_output=True, text=True, check=False)


class PackagedFreeRDPRuntimeClosureTests(unittest.TestCase):
    template_dir: Path
    closure_names: list[str]

    @classmethod
    def setUpClass(cls) -> None:
        provenance = json.loads(PROVENANCE.read_text())
        cls.closure_names = sorted(
            Path(entry["path"]).name for entry in provenance["binaries"]
        )
        cls.template_dir = Path(
            tempfile.mkdtemp(prefix="freerdp-closure-gate-template-")
        )
        frameworks = cls.template_dir / "Template.app/Contents/Frameworks"
        frameworks.mkdir(parents=True)
        for name in cls.closure_names:
            packaged = frameworks / name
            shutil.copyfile(VENDOR_DYLIBS / name, packaged)
            # Release signing replaces the vendored ad-hoc signature; the gate
            # must treat that as identity-preserving.
            subprocess.run(
                [
                    "codesign",
                    "--force",
                    "--sign",
                    "-",
                    "--identifier",
                    f"test.release.{name}",
                    str(packaged),
                ],
                capture_output=True,
                text=True,
                check=True,
            )

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.template_dir, ignore_errors=True)

    def make_app(self) -> Path:
        scratch = Path(tempfile.mkdtemp(prefix="freerdp-closure-gate-case-"))
        self.addCleanup(shutil.rmtree, scratch, ignore_errors=True)
        app_path = scratch / "SkyBridge.app"
        shutil.copytree(self.template_dir / "Template.app", app_path)
        return app_path

    def test_passes_on_resigned_full_closure(self) -> None:
        result = run_verifier(self.make_app())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            f"{len(self.closure_names)} dylibs bound to provenance", result.stdout
        )
        for name in self.closure_names:
            self.assertIn(f"closure member verified: {name}", result.stdout)

    def test_fails_when_pinned_member_is_missing(self) -> None:
        app_path = self.make_app()
        (app_path / "Contents/Frameworks/libssl.4.dylib").unlink()
        result = run_verifier(app_path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing pinned closure dylibs", result.stderr)
        self.assertIn("libssl.4.dylib", result.stderr)

    def test_fails_on_stale_previous_generation_member(self) -> None:
        app_path = self.make_app()
        stale = app_path / "Contents/Frameworks/libssl.3.dylib"
        shutil.copyfile(VENDOR_DYLIBS / "libssl.4.dylib", stale)
        result = run_verifier(app_path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the pinned set", result.stderr)
        self.assertIn("libssl.3.dylib", result.stderr)

    def test_passes_when_signature_growth_left_linkedit_vmsize_residue(self) -> None:
        """Developer ID + timestamp signatures are larger than the vendored
        ad-hoc ones, so codesign rounds __LINKEDIT vmsize up and the residue
        survives --remove-signature. The gate must treat that as
        identity-preserving."""
        import struct

        app_path = self.make_app()
        target = app_path / "Contents/Frameworks/libcrypto.4.dylib"
        data = bytearray(target.read_bytes())
        self.assertEqual(struct.unpack_from("<I", data, 0)[0], 0xFEEDFACF)
        ncmds = struct.unpack_from("<I", data, 16)[0]
        offset = 32
        patched = False
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", data, offset)
            if cmd == 0x19 and bytes(data[offset + 8 : offset + 24]).rstrip(b"\0") == b"__LINKEDIT":
                vmsize = struct.unpack_from("<Q", data, offset + 32)[0]
                struct.pack_into("<Q", data, offset + 32, vmsize + 0x4000)
                patched = True
            offset += cmdsize
        self.assertTrue(patched)
        target.write_bytes(bytes(data))
        subprocess.run(
            [
                "codesign",
                "--force",
                "--sign",
                "-",
                "--identifier",
                "test.release.libcrypto.4.dylib",
                str(target),
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        result = run_verifier(app_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("closure member verified: libcrypto.4.dylib", result.stdout)

    def test_fails_when_packaged_bytes_are_tampered(self) -> None:
        app_path = self.make_app()
        target = app_path / "Contents/Frameworks/libjansson.4.dylib"
        tampered = bytearray(target.read_bytes())
        offset = len(tampered) // 2
        tampered[offset] ^= 0xFF
        target.write_bytes(bytes(tampered))
        result = run_verifier(app_path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the provenance-pinned", result.stderr)
        self.assertIn("libjansson.4.dylib", result.stderr)

    def test_fails_when_vendored_bytes_drift_from_provenance_pin(self) -> None:
        provenance = json.loads(PROVENANCE.read_text())
        provenance["binaries"][0]["sha256"] = "0" * 64
        drifted = Path(tempfile.mkdtemp(prefix="freerdp-closure-gate-prov-"))
        self.addCleanup(shutil.rmtree, drifted, ignore_errors=True)
        drifted_path = drifted / "provenance.json"
        drifted_path.write_text(json.dumps(provenance))
        result = run_verifier(self.make_app(), provenance=drifted_path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("drifted from provenance pin", result.stderr)

    def test_fails_when_lock_soname_is_not_pinned_by_provenance(self) -> None:
        lock = json.loads(LOCK.read_text())
        build_inputs = lock["families"]["freerdp-runtime"]["build_inputs"]
        build_inputs["openssl_sonames"] = (
            build_inputs["openssl_sonames"] + ";libssl.3.dylib"
        )
        scratch = Path(tempfile.mkdtemp(prefix="freerdp-closure-gate-lock-"))
        self.addCleanup(shutil.rmtree, scratch, ignore_errors=True)
        lock_path = scratch / "lock.json"
        lock_path.write_text(json.dumps(lock))
        result = run_verifier(self.make_app(), lock=lock_path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not pinned by provenance", result.stderr)
        self.assertIn("libssl.3.dylib", result.stderr)

    def test_fails_when_frameworks_directory_is_missing(self) -> None:
        scratch = Path(tempfile.mkdtemp(prefix="freerdp-closure-gate-empty-"))
        self.addCleanup(shutil.rmtree, scratch, ignore_errors=True)
        app_path = scratch / "Empty.app"
        (app_path / "Contents").mkdir(parents=True)
        result = run_verifier(app_path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing app Frameworks directory", result.stderr)


if __name__ == "__main__":
    unittest.main()
