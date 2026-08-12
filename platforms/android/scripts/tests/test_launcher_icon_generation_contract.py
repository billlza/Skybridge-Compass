#!/usr/bin/env python3
"""Regression tests for the launcher icon source/asset generation binding."""

from __future__ import annotations

import importlib.util
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


if __name__ == "__main__":
    unittest.main()
