#!/usr/bin/env python3
"""Unit tests for the fail-closed native vendor provenance contract."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock


SCRIPT_PATH = pathlib.Path(__file__).with_name("native_vendor_provenance.py")
SPEC = importlib.util.spec_from_file_location("native_vendor_provenance", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT_PATH}")
PROVENANCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROVENANCE)


class NativeVendorProvenanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repository_root = pathlib.Path(self.temporary_directory.name) / "repository"
        self.repository_root.mkdir()
        self.lock_path = self.repository_root / "Config/native-dependencies.lock.json"
        self.recipe_path = self.repository_root / "Scripts/build_native.sh"
        self.artifact_root = self.repository_root / "Vendor/example.xcframework"
        self.binary_path = self.artifact_root / "macos-arm64/libexample.a"
        self.lock_path.parent.mkdir()
        self.recipe_path.parent.mkdir()
        self.binary_path.parent.mkdir(parents=True)
        self.recipe_path.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        self.binary_path.write_bytes(b"mach-o archive fixture")
        self.lock = {
            "schema_version": 2,
            "families": {
                "example": {
                    "sources": [
                        {
                            "name": "example",
                            "version": "1.2.3",
                            "ref": "1.2.3",
                            "commit": "1" * 40,
                            "repository": "https://example.invalid/example.git",
                            "git_tree": "2" * 40,
                            "source_archive_sha256": "3" * 64,
                        }
                    ],
                    "build_inputs": {
                        "build_type": "Release",
                        "deployment_target": "14.0",
                    },
                    "toolchain": {
                        "xcode": "fixture-xcode",
                        "macos_sdk": "fixture-sdk",
                        "clang": "fixture-clang",
                        "cmake": "fixture-cmake",
                        "ninja": "fixture-ninja",
                    },
                }
            },
        }
        self.write_lock()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_lock(self) -> None:
        self.lock_path.write_text(
            json.dumps(self.lock, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

    def source_record(self) -> dict[str, str]:
        return dict(self.lock["families"]["example"]["sources"][0])

    def binary_record(self) -> dict[str, object]:
        return {
            "path": "Vendor/example.xcframework/macos-arm64/libexample.a",
            "size": self.binary_path.stat().st_size,
            "sha256": PROVENANCE.sha256_file(self.binary_path),
            "architectures": ["arm64"],
            "platforms": ["macos"],
            "deployment_targets": ["14.0"],
        }

    def record(self) -> dict[str, object]:
        tree_sha256, file_count = PROVENANCE.tree_digest(self.artifact_root)
        return {
            "schema_version": 2,
            "family": "example",
            "native_dependency_lock": {
                "path": "Config/native-dependencies.lock.json",
                "schema_version": 2,
                "family": "example",
                "family_sha256": PROVENANCE.locked_family_sha256(
                    "example",
                    {
                        "sources": self.lock["families"]["example"]["sources"],
                        "build_inputs": self.lock["families"]["example"]["build_inputs"],
                        "toolchain": self.lock["families"]["example"]["toolchain"],
                    },
                ),
            },
            "sources": [self.source_record()],
            "build": {
                "inputs": self.lock["families"]["example"]["build_inputs"],
                "recipe": "Scripts/build_native.sh",
                "recipe_sha256": PROVENANCE.sha256_file(self.recipe_path),
                "toolchain": self.lock["families"]["example"]["toolchain"],
            },
            "artifact_roots": {
                "xcframework": {
                    "path": "Vendor/example.xcframework",
                    "tree_sha256": tree_sha256,
                    "file_count": file_count,
                }
            },
            "binaries": [self.binary_record()],
        }

    def write_record(self, record: dict[str, object]) -> pathlib.Path:
        path = self.repository_root / "Vendor/example.provenance.json"
        path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return path

    def verify(self, record: dict[str, object]) -> None:
        path = self.write_record(record)
        binary_record = self.binary_record()
        with mock.patch.object(PROVENANCE, "archive_metadata", return_value=binary_record):
            PROVENANCE.verify_record(path, self.repository_root, self.lock_path)

    def test_verify_accepts_record_bound_to_exact_lock_and_artifacts(self) -> None:
        self.verify(self.record())

    def test_source_override_that_differs_from_lock_is_rejected(self) -> None:
        record = self.record()
        record["sources"][0]["ref"] = "environment-override"
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "sources differ"):
            self.verify(record)

    def test_build_input_override_that_differs_from_lock_is_rejected(self) -> None:
        record = self.record()
        record["build"]["inputs"]["deployment_target"] = "15.0"
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "build inputs differ"):
            self.verify(record)

    def test_locked_family_tampering_is_rejected_by_recorded_hash(self) -> None:
        record = self.record()
        self.lock["families"]["example"]["build_inputs"]["extra"] = "tampered"
        self.write_lock()
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "family SHA-256"):
            self.verify(record)

    def test_unrelated_family_change_does_not_invalidate_record(self) -> None:
        record = self.record()
        self.lock["families"]["unrelated"] = {
            "sources": [
                {
                    "name": "unrelated",
                    "version": "9.9.9",
                    "ref": "9.9.9",
                    "commit": "9" * 40,
                    "repository": "https://example.invalid/unrelated.git",
                }
            ],
            "build_inputs": {"build_type": "Release"},
        }
        self.write_lock()

        self.verify(record)

    def test_unknown_lock_top_level_field_is_rejected(self) -> None:
        record = self.record()
        self.lock["unexpected"] = "ambiguous"
        self.write_lock()
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "lock fields differ"):
            self.verify(record)

    def test_unknown_target_family_field_is_rejected(self) -> None:
        record = self.record()
        self.lock["families"]["example"]["unexpected"] = "ambiguous"
        self.write_lock()
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "family fields differ"):
            self.verify(record)

    def test_unknown_provenance_top_level_field_is_rejected(self) -> None:
        record = self.record()
        record["unexpected"] = "ambiguous"
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "provenance fields differ"):
            self.verify(record)

    def test_unknown_build_field_is_rejected(self) -> None:
        record = self.record()
        record["build"]["unexpected"] = "ambiguous"
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "build fields differ"):
            self.verify(record)

    def test_missing_toolchain_field_is_rejected(self) -> None:
        record = self.record()
        del record["build"]["toolchain"]["ninja"]
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "toolchain fields differ"):
            self.verify(record)

    def test_empty_toolchain_value_is_rejected(self) -> None:
        record = self.record()
        record["build"]["toolchain"]["ninja"] = ""
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "toolchain field"):
            self.verify(record)

    def test_toolchain_tampering_is_rejected_by_lock(self) -> None:
        record = self.record()
        record["build"]["toolchain"]["xcode"] = "tampered"
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "toolchain differs"):
            self.verify(record)

    def test_source_tree_tampering_is_rejected_by_lock(self) -> None:
        record = self.record()
        record["sources"][0]["git_tree"] = "4" * 40
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "sources differ"):
            self.verify(record)

    def test_source_archive_tampering_is_rejected_by_lock(self) -> None:
        record = self.record()
        record["sources"][0]["source_archive_sha256"] = "4" * 64
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "sources differ"):
            self.verify(record)

    def test_unknown_artifact_root_field_is_rejected(self) -> None:
        record = self.record()
        record["artifact_roots"]["xcframework"]["unexpected"] = "ambiguous"
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "artifact root fields differ"):
            self.verify(record)

    def test_legacy_whole_lock_hash_schema_is_rejected(self) -> None:
        record = self.record()
        record["schema_version"] = 1
        record["native_dependency_lock"] = {
            "path": "Config/native-dependencies.lock.json",
            "sha256": PROVENANCE.sha256_file(self.lock_path),
        }
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "unsupported provenance schema"):
            self.verify(record)

    def test_artifact_tampering_is_rejected(self) -> None:
        record = self.record()
        self.binary_path.write_bytes(b"tampered archive fixture")
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "artifact tree differs"):
            self.verify(record)

    def test_recipe_tampering_is_rejected(self) -> None:
        record = self.record()
        self.recipe_path.write_text("#!/bin/false\n", encoding="utf-8")
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "recipe differs"):
            self.verify(record)

    def test_in_repository_recipe_symlink_is_rejected(self) -> None:
        record = self.record()
        real_recipe = self.recipe_path.with_name("real_build_native.sh")
        self.recipe_path.rename(real_recipe)
        self.recipe_path.symlink_to(real_recipe.name)

        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "symlinks are forbidden"):
            self.verify(record)

    def test_in_repository_artifact_root_symlink_is_rejected(self) -> None:
        real_artifact_root = self.artifact_root.with_name("real_example.xcframework")
        self.artifact_root.rename(real_artifact_root)
        self.artifact_root.symlink_to(real_artifact_root.name, target_is_directory=True)

        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "symlinks are forbidden"):
            PROVENANCE.safe_repository_path(
                "Vendor/example.xcframework", self.repository_root, "artifact"
            )

    def test_provenance_json_symlink_is_rejected(self) -> None:
        record = self.record()
        real_path = self.repository_root / "Vendor/real.provenance.json"
        real_path.write_text(
            json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        symlink_path = self.repository_root / "Vendor/example.provenance.json"
        symlink_path.symlink_to(real_path.name)

        with mock.patch.object(
            PROVENANCE, "archive_metadata", return_value=self.binary_record()
        ), self.assertRaisesRegex(PROVENANCE.ProvenanceError, "symlinks are forbidden"):
            PROVENANCE.verify_record(
                symlink_path, self.repository_root, self.lock_path
            )

    def test_artifact_parent_traversal_is_rejected(self) -> None:
        record = self.record()
        record["artifact_roots"]["xcframework"]["path"] = "../outside"
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "unsafe artifact path"):
            self.verify(record)

    def test_symlink_escape_is_rejected(self) -> None:
        outside = pathlib.Path(self.temporary_directory.name) / "outside"
        outside.mkdir()
        escape = self.repository_root / "Vendor/escape"
        escape.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "symlinks are forbidden"):
            PROVENANCE.safe_repository_path("Vendor/escape", self.repository_root, "artifact")

    def test_lock_outside_repository_is_rejected(self) -> None:
        outside_lock = pathlib.Path(self.temporary_directory.name) / "outside-lock.json"
        outside_lock.write_text(json.dumps(self.lock), encoding="utf-8")
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "outside repository root"):
            PROVENANCE.load_locked_family(outside_lock, self.repository_root, "example")

    def test_duplicate_json_keys_are_rejected(self) -> None:
        duplicate = self.repository_root / "Config/duplicate.json"
        duplicate.write_text('{"schema_version": 1, "schema_version": 1}\n', encoding="utf-8")
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "duplicate JSON key"):
            PROVENANCE.read_json_object(duplicate, "fixture")


if __name__ == "__main__":
    unittest.main()
