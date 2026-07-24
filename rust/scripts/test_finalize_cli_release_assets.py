#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from finalize_cli_release_assets import (  # noqa: E402
    CHECKSUMS_NAME,
    FORMULA_NAME,
    MANIFEST_NAME,
    PLATFORM_ASSETS,
    ContractError,
    finalize,
    npm_package_name,
    validate_inputs,
    verify,
)


VERSION = "1.2.3"
REPOSITORY = "billlza/Skybridge-Compass"
SOURCE_SHA = "a" * 40
TOOLCHAIN = "1.94.0"
SOURCE_DATE_EPOCH = 1_800_000_000


class CLIReleaseAssetContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def stage_inputs(self) -> None:
        for index, (name, _, _) in enumerate(PLATFORM_ASSETS):
            (self.root / name).write_bytes(f"native-{index}\n".encode())
        (self.root / npm_package_name(VERSION)).write_bytes(b"npm-package\n")

    def finalize(self) -> None:
        self.stage_inputs()
        validate_inputs(self.root, VERSION)
        (self.root / FORMULA_NAME).write_text("class Skybridge < Formula\nend\n", encoding="utf-8")
        finalize(
            self.root,
            version=VERSION,
            source_repository=REPOSITORY,
            source_sha=SOURCE_SHA,
            rust_toolchain=TOOLCHAIN,
            source_date_epoch=SOURCE_DATE_EPOCH,
        )

    def verify(self) -> None:
        verify(
            self.root,
            version=VERSION,
            source_repository=REPOSITORY,
            source_sha=SOURCE_SHA,
            rust_toolchain=TOOLCHAIN,
            source_date_epoch=SOURCE_DATE_EPOCH,
        )

    def test_finalizes_exact_source_bound_asset_set(self) -> None:
        self.finalize()
        self.verify()
        manifest = json.loads((self.root / MANIFEST_NAME).read_text(encoding="utf-8"))
        self.assertEqual(manifest["source_sha"], SOURCE_SHA)
        self.assertEqual(manifest["source_repository"], REPOSITORY)
        self.assertEqual(manifest["rust_toolchain"], TOOLCHAIN)
        self.assertEqual(manifest["source_date_epoch"], SOURCE_DATE_EPOCH)
        self.assertNotIn("workflow_run_id", manifest)
        self.assertNotIn("workflow_run_attempt", manifest)
        self.assertEqual(len(manifest["assets"]), 6)
        names = {entry["name"] for entry in manifest["assets"]}
        self.assertIn(npm_package_name(VERSION), names)
        self.assertIn(FORMULA_NAME, names)
        checksum_names = {
            line.split("  ", 1)[1]
            for line in (self.root / CHECKSUMS_NAME).read_text(encoding="ascii").splitlines()
        }
        self.assertEqual(checksum_names, names | {MANIFEST_NAME})

    def test_rejects_unknown_input(self) -> None:
        self.stage_inputs()
        (self.root / "operator-secret.txt").write_text("must not publish", encoding="utf-8")
        with self.assertRaisesRegex(ContractError, "unexpected release asset"):
            validate_inputs(self.root, VERSION)

    def test_rejects_missing_input(self) -> None:
        self.stage_inputs()
        (self.root / PLATFORM_ASSETS[0][0]).unlink()
        with self.assertRaisesRegex(ContractError, "missing release assets"):
            validate_inputs(self.root, VERSION)

    def test_rejects_symbolic_link(self) -> None:
        self.stage_inputs()
        target = self.root / PLATFORM_ASSETS[0][0]
        target.unlink()
        target.symlink_to(self.root / PLATFORM_ASSETS[1][0])
        with self.assertRaisesRegex(ContractError, "symbolic link"):
            validate_inputs(self.root, VERSION)

    def test_rejects_hard_link(self) -> None:
        self.stage_inputs()
        target = self.root / PLATFORM_ASSETS[0][0]
        target.unlink()
        os.link(self.root / PLATFORM_ASSETS[1][0], target)
        with self.assertRaisesRegex(ContractError, "hard-linked"):
            validate_inputs(self.root, VERSION)

    def test_rejects_payload_tampering(self) -> None:
        self.finalize()
        with (self.root / npm_package_name(VERSION)).open("ab") as handle:
            handle.write(b"tampered")
        with self.assertRaisesRegex(ContractError, "manifest does not match"):
            self.verify()

    def test_rejects_manifest_source_substitution(self) -> None:
        self.finalize()
        manifest_path = self.root / MANIFEST_NAME
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["source_sha"] = "b" * 40
        manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ContractError, "manifest does not match"):
            self.verify()

    def test_rejects_checksum_omission(self) -> None:
        self.finalize()
        checksum_path = self.root / CHECKSUMS_NAME
        lines = checksum_path.read_text(encoding="ascii").splitlines()
        checksum_path.write_text("\n".join(lines[:-1]) + "\n", encoding="ascii")
        with self.assertRaisesRegex(ContractError, "exact release asset set"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
