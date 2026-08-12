#!/usr/bin/env python3
"""Regression tests for the launcher icon source/asset generation binding."""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "generate_android_launcher_icons.py"
SPEC = importlib.util.spec_from_file_location("launcher_icon_generation", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load launcher icon generator")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LauncherIconGenerationContractTests(unittest.TestCase):
    def test_committed_assets_match_the_generation_binding(self) -> None:
        source = MODULE.DEFAULT_CANONICAL_ICON.resolve(strict=True)
        MODULE.verify_resource_contract(MODULE.RES_DIR)
        MODULE.verify_outputs(
            MODULE.RES_DIR,
            MODULE.expected_output_paths(MODULE.RES_DIR),
        )
        MODULE.verify_generation_manifest(source, MODULE.RES_DIR)

    def test_each_binding_dimension_is_fail_closed(self) -> None:
        source = MODULE.DEFAULT_CANONICAL_ICON.resolve(strict=True)
        expected = MODULE.expected_generation_manifest(source, MODULE.RES_DIR)
        for field in ("sourceSha256", "generatorSha256", "assetSetSha256"):
            with self.subTest(field=field):
                changed = dict(expected)
                changed[field] = "0" * 64
                with self.assertRaisesRegex(RuntimeError, field):
                    MODULE.validate_generation_manifest_payload(changed, expected)

    def test_bound_text_inputs_are_checked_out_with_lf_endings(self) -> None:
        bound_text_paths = (
            "Sources/SkyBridgeCompassApp/Resources/AppIconMaster.svg",
            "platforms/android/scripts/generate_android_launcher_icons.py",
            "platforms/android/app/launcher-icon-generation.json",
            "platforms/android/app/src/main/res/drawable/ic_launcher_background.xml",
            "platforms/android/app/src/main/res/mipmap-anydpi/ic_launcher.xml",
            "platforms/android/app/src/main/res/mipmap-anydpi/ic_launcher_round.xml",
        )
        result = subprocess.run(
            ["git", "-C", str(MODULE.MAC_RELEASE_ROOT), "check-attr", "text", "eol", "--", *bound_text_paths],
            check=True,
            capture_output=True,
            text=True,
        )
        lines = result.stdout.splitlines()
        for path in bound_text_paths:
            self.assertIn(f"{path}: text: set", lines)
            self.assertIn(f"{path}: eol: lf", lines)

    def test_manifest_rejects_unknown_fields_and_non_objects(self) -> None:
        source = MODULE.DEFAULT_CANONICAL_ICON.resolve(strict=True)
        expected = MODULE.expected_generation_manifest(source, MODULE.RES_DIR)
        with self.assertRaisesRegex(RuntimeError, "unexpected field set"):
            MODULE.validate_generation_manifest_payload(
                {**expected, "fallback": True},
                expected,
            )
        for invalid in ([], None, "manifest"):
            with self.subTest(invalid=invalid):
                with self.assertRaisesRegex(RuntimeError, "JSON object"):
                    MODULE.validate_generation_manifest_payload(invalid, expected)

    def test_generation_rejects_leaf_symlink_without_any_partial_write(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            root = Path(temporary_root)
            staged_res = root / "staged" / "res"
            target_res = root / "target" / "res"
            for density in MODULE.DENSITIES:
                staged_density = staged_res / f"drawable-{density}"
                target_density = target_res / f"drawable-{density}"
                staged_density.mkdir(parents=True)
                target_density.mkdir(parents=True)
                for name in ("ic_launcher_foreground.png", "ic_launcher_monochrome.png"):
                    (staged_density / name).write_bytes(f"new-{density}-{name}".encode())
                    (target_density / name).write_bytes(f"old-{density}-{name}".encode())

            first_target = target_res / "drawable-mdpi" / "ic_launcher_foreground.png"
            first_original = first_target.read_bytes()
            outside = root / "outside-sentinel"
            outside.write_bytes(b"must-not-change")
            linked_target = target_res / "drawable-xxxhdpi" / "ic_launcher_monochrome.png"
            linked_target.unlink()
            linked_target.symlink_to(outside)

            with self.assertRaisesRegex(RuntimeError, "single-link regular file"):
                MODULE.copy_generated_outputs(staged_res, target_res)

            self.assertEqual(outside.read_bytes(), b"must-not-change")
            self.assertEqual(first_target.read_bytes(), first_original)

    def test_generation_rejects_symlinked_density_directory_without_external_write(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            root = Path(temporary_root)
            staged_res = root / "staged" / "res"
            target_res = root / "target" / "res"
            outside_density = root / "outside-density"
            outside_density.mkdir(parents=True)
            for density in MODULE.DENSITIES:
                staged_density = staged_res / f"drawable-{density}"
                target_density = target_res / f"drawable-{density}"
                staged_density.mkdir(parents=True)
                target_density.mkdir(parents=True)
                for name in ("ic_launcher_foreground.png", "ic_launcher_monochrome.png"):
                    (staged_density / name).write_bytes(f"new-{density}-{name}".encode())
                    (target_density / name).write_bytes(f"old-{density}-{name}".encode())

            linked_density = target_res / "drawable-xxxhdpi"
            shutil.rmtree(linked_density)
            linked_density.symlink_to(outside_density, target_is_directory=True)

            with self.assertRaisesRegex(RuntimeError, "real directory"):
                MODULE.copy_generated_outputs(staged_res, target_res)

            self.assertEqual(list(outside_density.iterdir()), [])

    def test_resource_binding_detects_background_byte_tamper(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            copied_res = Path(temporary_root) / "res"
            shutil.copytree(MODULE.RES_DIR, copied_res)
            source = MODULE.DEFAULT_CANONICAL_ICON.resolve(strict=True)
            stale = MODULE.expected_generation_manifest(source, copied_res)
            background = copied_res / "drawable" / "ic_launcher_background.xml"
            background.write_text(
                background.read_text(encoding="utf-8").replace("#F9FDFE", "#F9FDFD"),
                encoding="utf-8",
            )
            current = MODULE.expected_generation_manifest(source, copied_res)
            with self.assertRaisesRegex(RuntimeError, "assetSetSha256"):
                MODULE.validate_generation_manifest_payload(stale, current)

    def test_resource_contract_rejects_adaptive_xml_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            root = Path(temporary_root)
            copied_res = root / "res"
            shutil.copytree(MODULE.RES_DIR, copied_res)
            outside = root / "adaptive.xml"
            outside.write_bytes(
                (copied_res / "mipmap-anydpi" / "ic_launcher.xml").read_bytes()
            )
            adaptive = copied_res / "mipmap-anydpi" / "ic_launcher.xml"
            adaptive.unlink()
            adaptive.symlink_to(outside)
            with self.assertRaisesRegex(RuntimeError, "single-link regular file"):
                MODULE.verify_resource_contract(copied_res)

    def test_resource_binding_rejects_background_hardlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            root = Path(temporary_root)
            copied_res = root / "res"
            shutil.copytree(MODULE.RES_DIR, copied_res)
            background = copied_res / "drawable" / "ic_launcher_background.xml"
            linked_copy = root / "linked-background.xml"
            background.rename(linked_copy)
            background.hardlink_to(linked_copy)

            with self.assertRaisesRegex(RuntimeError, "single-link regular file"):
                MODULE.expected_generation_manifest(
                    MODULE.DEFAULT_CANONICAL_ICON.resolve(strict=True),
                    copied_res,
                )


if __name__ == "__main__":
    unittest.main()
