from __future__ import annotations

import hashlib
import os
from pathlib import Path
import tempfile
import unittest

import verify_boundsession_xcframework as verifier


class BoundSessionXCFrameworkVerifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.root = Path(__file__).resolve().parent.parent

    def test_checked_in_artifact_passes_the_complete_gate(self) -> None:
        verifier.verify(self.root, require_publishable_source=False)

    @staticmethod
    def make_layout_fixture(root: Path, identifier: str) -> tuple[Path, Path]:
        framework = root / "BoundSessionFFI.framework"
        payload = framework / "Versions/A" if identifier == "macos-arm64" else framework
        (payload / "Headers").mkdir(parents=True)
        (payload / "_CodeSignature").mkdir()
        (payload / "BoundSessionFFI").write_bytes(b"binary fixture")
        (payload / "Headers/bound_session_ffi.h").write_text("header fixture")
        if identifier == "macos-arm64":
            (payload / "Resources").mkdir()
            (payload / "Resources/Info.plist").write_bytes(b"metadata fixture")
            (framework / "Versions/Current").symlink_to("A")
            for name in ("BoundSessionFFI", "Headers", "Resources"):
                (framework / name).symlink_to(f"Versions/Current/{name}")
        else:
            (payload / "Info.plist").write_bytes(b"metadata fixture")
        return framework, payload

    def test_canonical_platform_layouts_resolve_to_regular_payloads(self) -> None:
        for identifier in verifier.EXPECTED_SLICES:
            with self.subTest(identifier=identifier), tempfile.TemporaryDirectory() as temporary:
                framework, payload = self.make_layout_fixture(Path(temporary), identifier)
                self.assertEqual(verifier.framework_payload_directory(framework, identifier), payload)

    def test_macos_rejects_noncanonical_link_targets(self) -> None:
        cases = (
            ("Versions/Current", "../A"),
            ("Versions/Current", "/tmp/A"),
            ("Versions/Current", "./A"),
            ("Versions/Current", "A/"),
            ("Versions/Current", "Current"),
            ("Versions/Current", "Missing"),
            ("BoundSessionFFI", "Versions/A/BoundSessionFFI"),
            ("Headers", "../../Headers"),
            ("Resources", "/tmp/Resources"),
        )
        for relative, target in cases:
            with self.subTest(relative=relative, target=target), tempfile.TemporaryDirectory() as temporary:
                framework, _ = self.make_layout_fixture(Path(temporary), "macos-arm64")
                link = framework / relative
                link.unlink()
                os.symlink(target, link)
                with self.assertRaisesRegex(SystemExit, "noncanonical"):
                    verifier.framework_payload_directory(framework, "macos-arm64")

    def test_macos_rejects_extra_versions_and_nested_payload_links(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            framework, _ = self.make_layout_fixture(Path(temporary), "macos-arm64")
            (framework / "Versions/B").mkdir()
            with self.assertRaisesRegex(SystemExit, "only Versions/A"):
                verifier.framework_payload_directory(framework, "macos-arm64")
        with tempfile.TemporaryDirectory() as temporary:
            framework, payload = self.make_layout_fixture(Path(temporary), "macos-arm64")
            (payload / "Resources/escape").symlink_to("../../../../outside")
            with self.assertRaisesRegex(SystemExit, "symlink inside"):
                verifier.framework_payload_directory(framework, "macos-arm64")

    def test_rejects_symlinked_payload_directories(self) -> None:
        for identifier in verifier.EXPECTED_SLICES:
            with self.subTest(identifier=identifier), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                framework, payload = self.make_layout_fixture(root, identifier)
                (payload / "Headers").rename(root / "outside-headers")
                (payload / "Headers").symlink_to(root / "outside-headers")
                with self.assertRaisesRegex(SystemExit, "symlink"):
                    verifier.framework_payload_directory(framework, identifier)

    def test_ios_rejects_versioned_layout(self) -> None:
        for identifier in ("ios-arm64", "ios-arm64-simulator"):
            with self.subTest(identifier=identifier), tempfile.TemporaryDirectory() as temporary:
                framework, _ = self.make_layout_fixture(Path(temporary), identifier)
                (framework / "Versions").mkdir()
                with self.assertRaisesRegex(SystemExit, "flat framework entries"):
                    verifier.framework_payload_directory(framework, identifier)

    def test_normalized_v1_surface_remains_frozen(self) -> None:
        header = self.root / "Sources/CBoundSession/include/bound_session_ffi.h"
        digest = hashlib.sha256(verifier.normalized_v1_surface(header)).hexdigest()
        self.assertEqual(digest, verifier.EXPECTED_V1_NORMALIZED_SURFACE_SHA256)
        symbols = verifier.declared_symbols(header)
        self.assertEqual(len({symbol for symbol in symbols if symbol.endswith("_v1")}), 33)
        self.assertEqual(
            {symbol for symbol in symbols if symbol.endswith("_v2")},
            verifier.EXPECTED_V2_SYMBOLS,
        )

    def test_required_swift_path_rejects_a_legacy_grant_call(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "Sources/Example.swift"
            source.parent.mkdir(parents=True)
            source.write_text(
                "func invalid() { bs_ffi_grant_take_outbound_v1() }\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                SystemExit,
                "required Swift path calls legacy grant entry points",
            ):
                verifier.verify_no_required_path_v1_calls(root)


if __name__ == "__main__":
    unittest.main()
