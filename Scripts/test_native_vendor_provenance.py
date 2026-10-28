#!/usr/bin/env python3
"""Unit tests for the fail-closed native vendor provenance contract."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import plistlib
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

    def framework_fixture(self) -> tuple[pathlib.Path, dict[str, object]]:
        framework = self.artifact_root / "ios-arm64/Example.framework"
        framework.mkdir(parents=True)
        binary = framework / "Example"
        binary.write_bytes(b"framework metadata unit fixture; not a native SDK")
        (framework / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Example", "CFBundlePackageType": "FMWK"
        }))
        metadata = {
            "path": binary.relative_to(self.repository_root).as_posix(),
            "size": binary.stat().st_size, "sha256": PROVENANCE.sha256_file(binary),
            "architectures": ["arm64"], "platforms": ["ios"], "deployment_targets": ["17.0"],
            "install_name": "@rpath/Example.framework/Example",
            "dependencies": ["@rpath/Example.framework/Example", "/usr/lib/libSystem.B.dylib"],
        }
        return binary, metadata

    def test_flat_framework_receives_dylib_metadata_validation(self) -> None:
        binary, metadata = self.framework_fixture()
        record = self.record()
        record["binaries"].append(metadata)
        with mock.patch.object(PROVENANCE, "dylib_metadata", return_value=metadata) as native_metadata:
            self.verify(record)
        native_metadata.assert_called_once_with(binary.resolve(), self.repository_root.resolve())

    def test_omitted_framework_binary_is_rejected(self) -> None:
        self.framework_fixture()
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "records differ from artifact tree"):
            self.verify(self.record())

    def versioned_framework_fixture(self) -> tuple[pathlib.Path, dict[str, object]]:
        binary, metadata = self.framework_fixture()
        framework = binary.parent
        version = framework / "Versions/A"
        resources = version / "Resources"
        resources.mkdir(parents=True)
        binary.rename(version / binary.name)
        (framework / "Info.plist").unlink()
        (resources / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Example", "CFBundlePackageType": "FMWK",
            "CFBundleSupportedPlatforms": ["MacOSX"]
        }))
        (framework / "Versions/Current").symlink_to("A", target_is_directory=True)
        (framework / "Example").symlink_to("Versions/Current/Example")
        (framework / "Resources").symlink_to("Versions/Current/Resources", target_is_directory=True)
        binary = version / "Example"
        metadata["path"] = binary.relative_to(self.repository_root).as_posix()
        metadata["platforms"] = ["macos"]
        return binary, metadata

    def test_versioned_framework_real_binary_gets_native_metadata_checks(self) -> None:
        binary, metadata = self.versioned_framework_fixture()
        record = self.record()
        record["binaries"].append(metadata)
        with mock.patch.object(PROVENANCE, "dylib_metadata", return_value=metadata) as native_metadata:
            self.verify(record)
        native_metadata.assert_called_once_with(binary.resolve(), self.repository_root.resolve())

    def test_omitted_versioned_framework_real_binary_is_rejected(self) -> None:
        self.versioned_framework_fixture()
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "records differ from artifact tree"):
            self.verify(self.record())

    def test_framework_metadata_cannot_change_platform_or_dependencies(self) -> None:
        _, metadata = self.framework_fixture()
        record = self.record()
        record["binaries"].append(metadata)
        for changes in [{"platforms": ["ios-simulator"]}, {"dependencies": ["/tmp/host-library.dylib"]}]:
            with self.subTest(changes=changes), mock.patch.object(PROVENANCE, "dylib_metadata", return_value=metadata | changes):
                with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "binary differs"):
                    self.verify(record)

    def test_framework_missing_or_conflicting_info_is_rejected(self) -> None:
        binary, _ = self.framework_fixture()
        info = binary.parent / "Info.plist"
        info.unlink()
        with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "Info.plist"):
            self.verify(self.record())
        for payload in [b"not a plist", plistlib.dumps({"CFBundleExecutable": "Other", "CFBundlePackageType": "FMWK"})]:
            with self.subTest(payload=payload):
                info.write_bytes(payload)
                with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "Info.plist"):
                    self.verify(self.record())

    def test_universal_framework_metadata_is_checked_per_architecture(self) -> None:
        binary, _ = self.framework_fixture()
        identifier = "@rpath/Example.framework/Example"
        for conflict in [None, "identifier", "dependency"]:
            def native_output(*args):
                if args == ("lipo", "-archs", str(binary)):
                    return "arm64 x86_64"
                if args == ("otool", "-l", str(binary)):
                    return "cmd LC_BUILD_VERSION\n platform 7\n minos 17.0\n"
                if len(args) == 5 and args[0:2] == ("otool", "-arch") and args[2] in {"arm64", "x86_64"} and args[4] == str(binary):
                    name = identifier + ("-other" if conflict == "identifier" and args[2] == "x86_64" else "")
                    if args[3] == "-D":
                        return str(binary) + ":\n" + name + "\n"
                    if args[3] == "-L":
                        dependency = "/tmp/other.dylib" if conflict == "dependency" and args[2] == "x86_64" else "/usr/lib/libSystem.B.dylib"
                        return str(binary) + ":\n\t" + name + " (compatibility version 1.0.0)\n\t" + dependency + " (compatibility version 1.0.0)\n"
                raise AssertionError("unexpected native inspection command: " + repr(args))
            with self.subTest(conflict=conflict), mock.patch.object(PROVENANCE, "run", side_effect=native_output):
                if conflict:
                    with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "differ between architectures"):
                        PROVENANCE.dylib_metadata(binary, self.repository_root)
                else:
                    actual = PROVENANCE.dylib_metadata(binary, self.repository_root)
                    self.assertEqual(actual["architectures"], ["arm64", "x86_64"])
                    self.assertEqual(actual["install_name"], identifier)
                    self.assertEqual(actual["dependencies"], [identifier, "/usr/lib/libSystem.B.dylib"])

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


class VersionedFrameworkProvenanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = pathlib.Path(self.temporary_directory.name) / "sdk"
        self.framework = self.root / "macos-arm64/Example.framework"
        self.version = self.framework / "Versions/A"
        for name in ["Headers", "Modules", "Resources"]:
            (self.version / name).mkdir(parents=True)
        (self.version / "Example").write_bytes(b"qualified code bytes")
        (self.version / "Headers/Example.h").write_text("int example(void);\n")
        self.metadata = {"CFBundleSupportedPlatforms": ["MacOSX"],
                         "CFBundleExecutable": "Example", "CFBundlePackageType": "FMWK"}
        self.write_metadata(self.metadata)
        (self.framework / "Versions/Current").symlink_to("A", target_is_directory=True)
        for name in ["Example", "Headers", "Modules", "Resources"]:
            (self.framework / name).symlink_to("Versions/Current/" + name,
                                             target_is_directory=name != "Example")

    def write_metadata(self, value) -> None:
        (self.version / "Resources/Info.plist").write_bytes(plistlib.dumps(value))

    def test_standard_macos_framework_is_hashed_with_its_aliases(self) -> None:
        first = PROVENANCE.tree_digest(self.root)
        self.assertEqual(first, PROVENANCE.tree_digest(self.root))
        self.assertEqual(first[1], 8)  # Three real files and five canonical aliases.
        (self.framework / "Headers").unlink()
        without_alias = PROVENANCE.tree_digest(self.root)
        self.assertNotEqual(first[0], without_alias[0])
        self.assertEqual(without_alias[1], 7)

    def test_payload_and_header_changes_change_digest(self) -> None:
        before = PROVENANCE.tree_digest(self.root)[0]
        (self.version / "Example").write_bytes(b"different code")
        after_code = PROVENANCE.tree_digest(self.root)[0]
        self.assertNotEqual(before, after_code)
        (self.version / "Headers/Example.h").write_text("void example(void);\n")
        self.assertNotEqual(after_code, PROVENANCE.tree_digest(self.root)[0])

    def test_absolute_parent_and_noncanonical_targets_are_rejected(self) -> None:
        link = self.framework / "Example"
        for target in [str(self.version / "Example"), "../outside", "Versions/A/Example",
                       "Versions/Current/Headers/Example.h"]:
            with self.subTest(target=target):
                link.unlink()
                link.symlink_to(target)
                with self.assertRaises(PROVENANCE.ProvenanceError):
                    PROVENANCE.tree_digest(self.root)

    def test_current_cannot_point_to_another_version_or_itself(self) -> None:
        link = self.framework / "Versions/Current"
        for target in ["B", "Current", "../outside"]:
            with self.subTest(target=target):
                link.unlink()
                link.symlink_to(target)
                with self.assertRaises(PROVENANCE.ProvenanceError):
                    PROVENANCE.tree_digest(self.root)

    def test_real_payload_cannot_be_a_link_even_inside_framework(self) -> None:
        real = self.version / "Example"
        real.unlink()
        real.symlink_to("Headers/Example.h")
        with self.assertRaises(PROVENANCE.ProvenanceError):
            PROVENANCE.tree_digest(self.root)

    def test_unknown_internal_link_is_rejected(self) -> None:
        (self.version / "Headers/extra.h").symlink_to("Example.h")
        with self.assertRaises(PROVENANCE.ProvenanceError):
            PROVENANCE.tree_digest(self.root)

    def test_non_macos_or_wrong_executable_metadata_is_rejected(self) -> None:
        for replacement in [{"CFBundleSupportedPlatforms": ["iPhoneOS"]},
                            {"CFBundleExecutable": "Other"}, {"CFBundlePackageType": "APPL"}]:
            with self.subTest(replacement=replacement):
                self.write_metadata({**self.metadata, **replacement})
                with self.assertRaises(PROVENANCE.ProvenanceError):
                    PROVENANCE.tree_digest(self.root)

    def test_invalid_metadata_is_reported_as_provenance_failure(self) -> None:
        self.write_metadata(["not a framework dictionary"])
        with self.assertRaises(PROVENANCE.ProvenanceError):
            PROVENANCE.tree_digest(self.root)

    def test_oversized_metadata_is_rejected(self) -> None:
        self.write_metadata({**self.metadata, "excess": "x" * (1024 * 1024)})
        with self.assertRaises(PROVENANCE.ProvenanceError):
            PROVENANCE.tree_digest(self.root)

    def test_missing_payload_is_rejected(self) -> None:
        (self.version / "Example").unlink()
        with self.assertRaises(PROVENANCE.ProvenanceError):
            PROVENANCE.tree_digest(self.root)

    def test_linked_version_directory_is_rejected(self) -> None:
        other = self.framework / "Versions/B"
        self.version.rename(other)
        self.version.symlink_to("B", target_is_directory=True)
        with self.assertRaises(PROVENANCE.ProvenanceError):
            PROVENANCE.tree_digest(self.root)


if __name__ == "__main__":
    unittest.main()
