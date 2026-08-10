#!/usr/bin/python3
"""Adversarial tests for the descriptor-bound Core resource transaction."""

from __future__ import annotations

import contextlib
import errno
import fcntl
import importlib.util
import os
from pathlib import Path
import select
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock
from typing import Dict, Optional, Tuple


SCRIPT_DIR = Path(__file__).resolve().parent
MODULE_PATH = SCRIPT_DIR / "skybridge_core_resource_bundle.py"
HELPER_PATH = SCRIPT_DIR / "skybridge_core_resource_bundle_helpers.sh"

spec = importlib.util.spec_from_file_location("skybridge_core_resource_bundle", MODULE_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError("unable to load production resource transaction")
bundle = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = bundle
spec.loader.exec_module(bundle)


def run_signal_child(argv: list[str]) -> int:
    if len(argv) != 6:
        return 2
    phase_name, source, destination, ready_raw, continue_raw, signal_raw = argv
    try:
        phase = bundle.Phase(phase_name)
        ready_fd = int(ready_raw)
        continue_fd = int(continue_raw)
        expected_signal = int(signal_raw)
    except (ValueError, TypeError):
        return 2
    previous_handlers = bundle._install_signal_handlers()

    def observer(observed: bundle.Phase) -> None:
        if observed == phase:
            os.write(ready_fd, b"ready\n")
            os.read(continue_fd, 1)

    try:
        bundle._normalize_and_install(
            source,
            destination,
            platform=bundle.DarwinPlatform(),
            observer=observer,
        )
        return 0
    except bundle.SignalInterruption as interruption:
        return 128 + interruption.signum if interruption.signum == expected_signal else 1
    except bundle.BundleError as error:
        os.write(2, ("signal-child-reason=" + error.reason + "\n").encode("utf-8"))
        return 1
    finally:
        bundle._restore_signal_handlers(previous_handlers)
        os.close(ready_fd)
        os.close(continue_fd)


def write_info(path: Path, identifier: str) -> None:
    payload = (
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
        "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        "<plist version=\"1.0\"><dict>"
        "<key>CFBundleIdentifier</key><string>" + identifier + "</string>"
        "<key>CFBundleName</key><string>SkyBridgeCoreResources</string>"
        "<key>CFBundlePackageType</key><string>BNDL</string>"
        "<key>CFBundleVersion</key><string>1</string>"
        "</dict></plist>\n"
    )
    path.write_text(payload, encoding="utf-8")
    path.chmod(0o640)


def write_resources(root: Path, unusual_name: Optional[str] = None) -> None:
    for locale in ("en", "ja", "zh-Hans"):
        locale_dir = root / (locale + ".lproj")
        locale_dir.mkdir(parents=True)
        (locale_dir / "Localizable.strings").write_text(
            '"RemoteControlSecurityNotice.Title" = "verified";\n',
            encoding="utf-8",
        )
    (root / "payload.txt").write_bytes(b"resource-payload\n")
    (root / "payload.txt").chmod(0o640)
    if unusual_name is not None:
        (root / unusual_name).write_bytes(b"unusual-name\n")


def make_flat(path: Path, unusual_name: Optional[str] = None) -> None:
    path.mkdir()
    path.chmod(0o750)
    write_info(path / "Info.plist", "com.skybridge.tests.flat")
    write_resources(path, unusual_name)
    nested = path / "nested"
    nested.mkdir()
    (nested / "Info.plist").write_bytes(b"nested-info-is-a-resource\n")


def make_modern(path: Path) -> None:
    resources = path / "Contents" / "Resources"
    resources.mkdir(parents=True)
    write_info(path / "Contents" / "Info.plist", "com.skybridge.tests.modern")
    write_resources(resources)


def independent_inventory(root: Path) -> Dict[bytes, Tuple[str, int, bytes]]:
    import hashlib

    records: Dict[bytes, Tuple[str, int, bytes]] = {}
    root_stat = root.lstat()
    records[b""] = ("D", stat.S_IMODE(root_stat.st_mode), b"")
    for current, directories, files in os.walk(os.fsencode(root), topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        current_path = Path(os.fsdecode(current))
        for name in directories:
            child = current_path / os.fsdecode(name)
            metadata = child.lstat()
            if child.is_symlink():
                raise AssertionError("oracle encountered symlink")
            relative = os.fsencode(str(child.relative_to(root)))
            records[relative] = ("D", stat.S_IMODE(metadata.st_mode), b"")
        for name in files:
            child = current_path / os.fsdecode(name)
            metadata = child.lstat()
            if not stat.S_ISREG(metadata.st_mode):
                raise AssertionError("oracle encountered non-regular file")
            relative = os.fsencode(str(child.relative_to(root)))
            records[relative] = (
                "F",
                stat.S_IMODE(metadata.st_mode),
                hashlib.sha256(child.read_bytes()).digest(),
            )
    return records


class ResourceBundleTransactionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="skybridge-core-resource-test.")
        self.root = Path(self.temporary.name)
        self.destination_parent = self.root / "destinations"
        self.destination_parent.mkdir(mode=0o700)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def destination(self, name: str) -> Path:
        parent = self.destination_parent / name
        parent.mkdir(mode=0o700)
        return parent / "SkyBridgeCompassApp_SkyBridgeCore.bundle"

    def assert_no_transaction_residue(self, destination: Path) -> None:
        self.assertFalse(
            any(entry.name.startswith(".skybridge-core-resource.") for entry in destination.parent.iterdir())
        )

    def assert_normalized(self, source: Path, destination: Path, layout: bundle.Layout) -> None:
        self.assertTrue((destination / "Contents" / "Info.plist").is_file())
        self.assertTrue((destination / "Contents" / "Resources").is_dir())
        self.assertFalse(any(part == "_CodeSignature" for path in destination.rglob("*") for part in path.parts))
        if layout == bundle.Layout.FLAT:
            expected = independent_inventory(source)
            expected.pop(os.fsencode("Info.plist"))
            actual = independent_inventory(destination / "Contents" / "Resources")
            self.assertEqual(
                (destination / "Contents" / "Info.plist").read_bytes(),
                (source / "Info.plist").read_bytes(),
            )
        else:
            expected = independent_inventory(source / "Contents" / "Resources")
            actual = independent_inventory(destination / "Contents" / "Resources")
            self.assertEqual(
                (destination / "Contents" / "Info.plist").read_bytes(),
                (source / "Contents" / "Info.plist").read_bytes(),
            )
        self.assertEqual(actual, expected)
        self.assert_no_transaction_residue(destination)

    def test_flat_bundle_preserves_exact_resources_and_modes(self) -> None:
        source = self.root / "flat.bundle"
        make_flat(source, "odd \n\t-[]$()雪.txt")
        destination = self.destination("flat")
        before = independent_inventory(source)
        result = bundle.normalize_and_install(str(source), str(destination))
        self.assertEqual(result, bundle.Layout.FLAT)
        self.assert_normalized(source, destination, result)
        self.assertEqual(independent_inventory(source), before)

    def test_modern_unsigned_bundle_is_normalized(self) -> None:
        source = self.root / "modern.bundle"
        make_modern(source)
        destination = self.destination("modern")
        result = bundle.normalize_and_install(str(source), str(destination))
        self.assertEqual(result, bundle.Layout.MACOS_CONTENTS)
        self.assert_normalized(source, destination, result)

    def test_modern_signed_bundle_is_verified_and_signature_is_not_copied(self) -> None:
        source = self.root / "modern-signed.bundle"
        make_modern(source)
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", str(source)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        destination = self.destination("modern-signed")
        result = bundle.normalize_and_install(str(source), str(destination))
        self.assertEqual(result, bundle.Layout.MACOS_CONTENTS)
        self.assert_normalized(source, destination, result)

    def test_invalid_signed_bundle_fails_closed(self) -> None:
        source = self.root / "invalid-signature.bundle"
        make_modern(source)
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", str(source)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        with (source / "Contents" / "Resources" / "payload.txt").open("ab") as handle:
            handle.write(b"tampered\n")
        destination = self.destination("invalid-signature")
        with self.assertRaisesRegex(bundle.BundleError, "source-signature-invalid"):
            bundle.normalize_and_install(str(source), str(destination))
        self.assertFalse(os.path.lexists(destination))
        self.assert_no_transaction_residue(destination)

    def test_codesign_verifies_inherited_snapshot_fd_not_replaceable_path(self) -> None:
        valid_replacement = self.root / "valid-signature-replacement.bundle"
        make_modern(valid_replacement)
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", str(valid_replacement)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        invalid_source = self.root / "invalid-fd-bound-signature.bundle"
        shutil.copytree(valid_replacement, invalid_source, copy_function=shutil.copy2)
        with (invalid_source / "Contents" / "Resources" / "payload.txt").open("ab") as handle:
            handle.write(b"invalid-real-snapshot\n")
        destination = self.destination("fd-bound-codesign")
        real_run = subprocess.run
        replacement_was_installed = False

        def swapping_run(*args: object, **kwargs: object) -> subprocess.CompletedProcess:
            nonlocal replacement_was_installed
            inherited = kwargs.get("pass_fds")
            self.assertIsInstance(inherited, tuple)
            snapshot_fd = inherited[0]
            raw_path = fcntl.fcntl(snapshot_fd, 50, b"\0" * 1_024)
            snapshot_path = Path(os.fsdecode(raw_path.split(b"\0", 1)[0]))
            moved_path = snapshot_path.with_name("snapshot-moved-during-codesign.bundle")
            snapshot_path.rename(moved_path)
            shutil.copytree(valid_replacement, snapshot_path, copy_function=shutil.copy2)
            replacement_was_installed = True
            try:
                return real_run(*args, **kwargs)
            finally:
                shutil.rmtree(snapshot_path)
                moved_path.rename(snapshot_path)

        with mock.patch.object(bundle.subprocess, "run", side_effect=swapping_run):
            with self.assertRaisesRegex(bundle.BundleError, "source-signature-invalid"):
                bundle.normalize_and_install(str(invalid_source), str(destination))
        self.assertTrue(replacement_was_installed)
        self.assertFalse(os.path.lexists(destination))
        self.assert_no_transaction_residue(destination)

    def test_symlink_hardlink_fifo_and_payload_signature_are_rejected(self) -> None:
        fixtures = []
        symlink_source = self.root / "symlink.bundle"
        make_flat(symlink_source)
        (symlink_source / "link").symlink_to("payload.txt")
        fixtures.append(symlink_source)

        hardlink_source = self.root / "hardlink.bundle"
        make_flat(hardlink_source)
        os.link(hardlink_source / "payload.txt", hardlink_source / "payload-hardlink.txt")
        fixtures.append(hardlink_source)

        fifo_source = self.root / "fifo.bundle"
        make_flat(fifo_source)
        os.mkfifo(fifo_source / "untrusted.fifo")
        fixtures.append(fifo_source)

        signature_source = self.root / "payload-signature.bundle"
        make_flat(signature_source)
        nested_signature = signature_source / "nested" / "_CodeSignature"
        nested_signature.mkdir()
        (nested_signature / "CodeResources").write_bytes(b"untrusted\n")
        fixtures.append(signature_source)

        for index, source in enumerate(fixtures):
            with self.subTest(source=source.name):
                destination = self.destination("invalid-" + str(index))
                with self.assertRaises(bundle.BundleError):
                    bundle.normalize_and_install(str(source), str(destination))
                self.assertFalse(os.path.lexists(destination))
                self.assert_no_transaction_residue(destination)

    def test_source_root_replacement_is_rejected_without_reading_replacement(self) -> None:
        source = self.root / "source-swap.bundle"
        make_flat(source)
        replacement = self.root / "replacement.bundle"
        make_flat(replacement)
        original = self.root / "source-original.bundle"
        destination = self.destination("source-swap")

        def observer(phase: bundle.Phase) -> None:
            if phase == bundle.Phase.ENDPOINTS_OPEN:
                source.rename(original)
                replacement.rename(source)

        with self.assertRaisesRegex(bundle.BundleError, "source-identity-changed"):
            bundle._normalize_and_install(
                str(source),
                str(destination),
                platform=bundle.DarwinPlatform(),
                observer=observer,
            )
        self.assertFalse(os.path.lexists(destination))
        self.assert_no_transaction_residue(destination)

    def test_verified_snapshot_cannot_be_rewritten_before_normalization(self) -> None:
        source = self.root / "snapshot-mutation.bundle"
        make_flat(source)
        destination = self.destination("snapshot-mutation")

        def observer(phase: bundle.Phase) -> None:
            if phase == bundle.Phase.SNAPSHOT_VERIFIED:
                workspaces = [
                    entry
                    for entry in destination.parent.iterdir()
                    if entry.name.startswith(".skybridge-core-resource.")
                ]
                self.assertEqual(len(workspaces), 1)
                (workspaces[0] / "snapshot.bundle" / "payload.txt").write_bytes(
                    b"mutated-after-signature-proof\n"
                )

        with self.assertRaisesRegex(bundle.BundleError, "snapshot-changed-during-normalization"):
            bundle._normalize_and_install(
                str(source),
                str(destination),
                platform=bundle.DarwinPlatform(),
                observer=observer,
            )
        self.assertFalse(os.path.lexists(destination))
        self.assert_no_transaction_residue(destination)

    def test_source_child_mutation_after_snapshot_is_rejected_before_publish(self) -> None:
        source = self.root / "source-child-mutation.bundle"
        make_flat(source)
        destination = self.destination("source-child-mutation")

        def observer(phase: bundle.Phase) -> None:
            if phase == bundle.Phase.SNAPSHOT_READY:
                (source / "payload.txt").write_bytes(b"source-mutated-after-snapshot\n")

        with self.assertRaisesRegex(bundle.BundleError, "source-resources-changed-before-publish"):
            bundle._normalize_and_install(
                str(source),
                str(destination),
                platform=bundle.DarwinPlatform(),
                observer=observer,
            )
        self.assertFalse(os.path.lexists(destination))
        self.assert_no_transaction_residue(destination)

    def test_destination_race_preserves_unknown_sentinel(self) -> None:
        source = self.root / "destination-race.bundle"
        make_flat(source)
        destination = self.destination("destination-race")

        def observer(phase: bundle.Phase) -> None:
            if phase == bundle.Phase.PUBLISH_ATTEMPTED:
                destination.mkdir()
                (destination / "sentinel").write_bytes(b"preserve\n")

        with self.assertRaisesRegex(bundle.BundleError, "destination-raced") as context:
            bundle._normalize_and_install(
                str(source),
                str(destination),
                platform=bundle.DarwinPlatform(),
                observer=observer,
            )
        self.assertEqual(context.exception.status, 2)
        self.assertEqual((destination / "sentinel").read_bytes(), b"preserve\n")
        self.assertFalse((destination / "normalized.bundle").exists())
        self.assert_no_transaction_residue(destination)

    def test_final_verified_mutation_is_reproved_and_rolled_back(self) -> None:
        source = self.root / "final-mutation.bundle"
        make_flat(source)
        destination = self.destination("final-mutation")

        def observer(phase: bundle.Phase) -> None:
            if phase == bundle.Phase.FINAL_VERIFIED:
                (destination / "Contents" / "Resources" / "payload.txt").write_bytes(
                    b"mutated-after-final-proof\n"
                )

        with self.assertRaisesRegex(bundle.BundleError, "resource-copy-proof-failed"):
            bundle._normalize_and_install(
                str(source),
                str(destination),
                platform=bundle.DarwinPlatform(),
                observer=observer,
            )
        self.assertFalse(os.path.lexists(destination))
        self.assert_no_transaction_residue(destination)

    def test_one_shot_rollback_cleanup_error_is_typed_and_leaves_no_residue(self) -> None:
        source = self.root / "rollback-cleanup-fault.bundle"
        make_flat(source)
        destination = self.destination("rollback-cleanup-fault")

        def observer(phase: bundle.Phase) -> None:
            if phase == bundle.Phase.FINAL_VERIFIED:
                (destination / "Contents" / "Resources" / "payload.txt").write_bytes(b"force-rollback\n")

        real_rmdir = os.rmdir
        injected = False

        def one_shot_rmdir(path: object, *args: object, **kwargs: object) -> None:
            nonlocal injected
            if os.fsdecode(path) == os.fsdecode(bundle.BundleTransaction.ROLLBACK_NAME) and not injected:
                injected = True
                raise OSError(errno.EIO, "injected rollback cleanup failure")
            real_rmdir(path, *args, **kwargs)

        with mock.patch.object(bundle.os, "rmdir", side_effect=one_shot_rmdir):
            with self.assertRaisesRegex(bundle.BundleError, "cleanup-failed"):
                bundle._normalize_and_install(
                    str(source),
                    str(destination),
                    platform=bundle.DarwinPlatform(),
                    observer=observer,
                )
        self.assertTrue(injected)
        self.assertFalse(os.path.lexists(destination))
        self.assert_no_transaction_residue(destination)

    def test_unknown_replacement_after_publish_is_preserved_without_workspace_residue(self) -> None:
        source = self.root / "published-replacement.bundle"
        make_flat(source)
        destination = self.destination("published-replacement")
        moved_candidate = destination.parent / "moved-owned-candidate.bundle"

        def observer(phase: bundle.Phase) -> None:
            if phase == bundle.Phase.PUBLISHED:
                destination.rename(moved_candidate)
                destination.mkdir()
                (destination / "sentinel").write_bytes(b"unknown-replacement\n")

        with self.assertRaisesRegex(bundle.BundleError, "published-destination-identity-mismatch"):
            bundle._normalize_and_install(
                str(source),
                str(destination),
                platform=bundle.DarwinPlatform(),
                observer=observer,
            )
        self.assertEqual((destination / "sentinel").read_bytes(), b"unknown-replacement\n")
        self.assertTrue(moved_candidate.is_dir())
        self.assert_no_transaction_residue(destination)

    def test_case_variant_destination_parent_inside_source_is_rejected_by_inode(self) -> None:
        source = self.root / "CaseSensitiveSource.bundle"
        make_flat(source)
        nested = source / "nested-destination"
        nested.mkdir()
        case_variant = self.root / "casesensitivesource.bundle"
        if not case_variant.exists():
            self.skipTest("current filesystem is case-sensitive")
        destination = case_variant / "nested-destination" / "output.bundle"
        with self.assertRaisesRegex(bundle.BundleError, "source-destination-overlap") as context:
            bundle.normalize_and_install(str(source), str(destination))
        self.assertEqual(context.exception.status, 2)
        self.assertFalse(os.path.lexists(destination))

    def test_repeated_tree_scans_do_not_leak_directory_descriptors(self) -> None:
        source = self.root / "descriptor-scan.bundle"
        make_flat(source)
        source_fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY)
        try:
            before = len(os.listdir("/dev/fd"))
            for _ in range(100):
                bundle._scan_tree(source_fd)
            after = len(os.listdir("/dev/fd"))
        finally:
            os.close(source_fd)
        self.assertEqual(after, before)

    def test_source_depth_limit_fails_without_recursion_or_residue(self) -> None:
        source = self.root / "deep-source.bundle"
        make_flat(source)
        current = source
        for _ in range(bundle.MAXIMUM_SOURCE_DEPTH + 1):
            current = current / "d"
            current.mkdir()
        destination = self.destination("deep-source")
        with self.assertRaisesRegex(bundle.BundleError, "source-resource-limit-exceeded"):
            bundle.normalize_and_install(str(source), str(destination))
        self.assertFalse(os.path.lexists(destination))
        self.assert_no_transaction_residue(destination)

    def test_two_concurrent_publishers_have_exactly_one_winner(self) -> None:
        source = self.root / "concurrent.bundle"
        make_flat(source)
        destination = self.destination("concurrent")
        gate = threading.Barrier(2)
        results = []

        def worker() -> None:
            def observer(phase: bundle.Phase) -> None:
                if phase == bundle.Phase.PUBLISH_ATTEMPTED:
                    gate.wait(timeout=5)

            try:
                layout = bundle._normalize_and_install(
                    str(source),
                    str(destination),
                    platform=bundle.DarwinPlatform(),
                    observer=observer,
                )
                results.append((0, layout.value))
            except bundle.BundleError as error:
                results.append((error.status, error.reason))

        original_umask = os.umask(0o027)
        try:
            threads = [threading.Thread(target=worker) for _ in range(2)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=10)
                self.assertFalse(thread.is_alive())
            observed_umask = os.umask(0o027)
            self.assertEqual(observed_umask, 0o027)
        finally:
            os.umask(original_umask)
        self.assertEqual(sorted(status for status, _ in results), [0, 2])
        self.assertTrue(any(value == "swiftpm-flat" for status, value in results if status == 0))
        self.assertTrue(any(value == "destination-raced" for status, value in results if status == 2))
        self.assertFalse((destination / "normalized.bundle").exists())
        self.assert_no_transaction_residue(destination)

    def test_preexisting_destination_and_unsafe_parent_are_not_modified(self) -> None:
        source = self.root / "preexisting.bundle"
        make_flat(source)
        destination = self.destination("preexisting")
        destination.mkdir()
        (destination / "sentinel").write_bytes(b"preserve\n")
        with self.assertRaises(bundle.BundleError) as context:
            bundle.normalize_and_install(str(source), str(destination))
        self.assertEqual(context.exception.status, 2)
        self.assertEqual((destination / "sentinel").read_bytes(), b"preserve\n")

        unsafe_parent = self.root / "unsafe-parent"
        unsafe_parent.mkdir(mode=0o777)
        unsafe_parent.chmod(0o777)
        unsafe_destination = unsafe_parent / "output.bundle"
        with self.assertRaises(bundle.BundleError) as unsafe_context:
            bundle.normalize_and_install(str(source), str(unsafe_destination))
        self.assertEqual(unsafe_context.exception.status, 2)
        self.assertFalse(os.path.lexists(unsafe_destination))

    def test_production_cli_rejects_test_surface_and_preserves_output_contract(self) -> None:
        rejected = subprocess.run(
            [str(MODULE_PATH), "--test-pause", "published"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(rejected.returncode, 2)
        self.assertEqual(rejected.stdout, "")
        self.assertEqual(rejected.stderr, "skybridge-core-resource-bundle: reason=usage\n")

        source = self.root / "cli-flat.bundle"
        make_flat(source)
        destination = self.destination("cli")
        completed = subprocess.run(
            [
                str(MODULE_PATH),
                "--source-bundle",
                str(source),
                "--destination-bundle",
                str(destination),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env={**os.environ, "SKYBRIDGE_RESOURCE_FAULT": "ignored"},
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, "swiftpm-flat\n")
        self.assertEqual(completed.stderr, "")

    def test_production_cli_maps_trust_failure_and_destination_conflict_exactly(self) -> None:
        invalid_source = self.root / "cli-invalid.bundle"
        invalid_source.mkdir()
        destination = self.destination("cli-invalid")
        trust_failure = subprocess.run(
            [
                str(MODULE_PATH),
                "--source-bundle",
                str(invalid_source),
                "--destination-bundle",
                str(destination),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(trust_failure.returncode, 1)
        self.assertEqual(trust_failure.stdout, "")
        self.assertEqual(
            trust_failure.stderr,
            "skybridge-core-resource-bundle: reason=unsupported-or-ambiguous-layout\n",
        )

        valid_source = self.root / "cli-conflict.bundle"
        make_flat(valid_source)
        conflicting_destination = self.destination("cli-conflict")
        conflicting_destination.mkdir()
        (conflicting_destination / "sentinel").write_bytes(b"preserve\n")
        conflict = subprocess.run(
            [
                str(MODULE_PATH),
                "--source-bundle",
                str(valid_source),
                "--destination-bundle",
                str(conflicting_destination),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(conflict.returncode, 2)
        self.assertEqual(conflict.stdout, "")
        self.assertEqual(
            conflict.stderr,
            "skybridge-core-resource-bundle: reason=destination-already-exists\n",
        )
        self.assertEqual((conflicting_destination / "sentinel").read_bytes(), b"preserve\n")

    def test_rename_errno_mapping_and_required_flags(self) -> None:
        platform = bundle.DarwinPlatform()
        observed_flags = []

        def failing_rename(
            _source_fd: int,
            _source_name: object,
            _destination_fd: int,
            _destination_name: object,
            flags: int,
        ) -> int:
            observed_flags.append(flags)
            bundle.ctypes.set_errno(errno.EEXIST)
            return -1

        platform._renameatx = failing_rename
        with self.assertRaisesRegex(bundle.BundleError, "destination-raced") as conflict:
            platform.rename_exclusive(3, b"source", 4, b"destination")
        self.assertEqual(conflict.exception.status, 2)
        self.assertEqual(observed_flags, [bundle.RENAME_FLAGS])

        def io_failure(
            _source_fd: int,
            _source_name: object,
            _destination_fd: int,
            _destination_name: object,
            _flags: int,
        ) -> int:
            bundle.ctypes.set_errno(errno.EIO)
            return -1

        platform._renameatx = io_failure
        with self.assertRaisesRegex(bundle.BundleError, "atomic-install-failed") as failure:
            platform.rename_exclusive(3, b"source", 4, b"destination")
        self.assertEqual(failure.exception.status, 1)

    def test_term_before_and_after_publish_returns_143_and_leaves_no_artifact(self) -> None:
        for phase in (bundle.Phase.ENDPOINTS_OPEN, bundle.Phase.PUBLISHED, bundle.Phase.FINAL_VERIFIED):
            with self.subTest(phase=phase.value):
                source = self.root / ("signal-" + phase.value + ".bundle")
                make_flat(source)
                destination = self.destination("signal-" + phase.value)
                ready_read, ready_write = os.pipe()
                continue_read, continue_write = os.pipe()
                process = subprocess.Popen(
                    [
                        str(Path(__file__).resolve()),
                        "__signal_child__",
                        phase.value,
                        str(source),
                        str(destination),
                        str(ready_write),
                        str(continue_read),
                        str(int(signal.SIGTERM)),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    pass_fds=(ready_write, continue_read),
                    text=False,
                )
                os.close(ready_write)
                os.close(continue_read)
                try:
                    readable, _, _ = select.select([ready_read], [], [], 10)
                    self.assertEqual(readable, [ready_read])
                    ready_payload = os.read(ready_read, 6)
                    if ready_payload != b"ready\n":
                        stdout, stderr = process.communicate(timeout=10)
                        self.fail(
                            "signal child exited before phase barrier: "
                            + repr((process.returncode, ready_payload, stdout, stderr))
                        )
                    os.kill(process.pid, signal.SIGTERM)
                    with contextlib.suppress(BrokenPipeError):
                        os.write(continue_write, b"1")
                    stdout, stderr = process.communicate(timeout=10)
                finally:
                    os.close(ready_read)
                    os.close(continue_write)
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
                self.assertEqual(process.returncode, 143, (stdout, stderr))
                self.assertEqual(stdout, b"")
                self.assertEqual(stderr, b"")
                self.assertFalse(os.path.lexists(destination))
                self.assert_no_transaction_residue(destination)

    def test_shell_wrapper_delegates_without_rewriting_contract(self) -> None:
        source = self.root / "wrapper-flat.bundle"
        make_flat(source)
        destination = self.destination("wrapper")
        script = 'source "$1"; skybridge_copy_normalized_core_resource_bundle "$2" "$3"'
        completed = subprocess.run(
            ["/bin/bash", "-c", script, "skybridge-wrapper", str(HELPER_PATH), str(source), str(destination)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, "swiftpm-flat\n")
        self.assertEqual(completed.stderr, "")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "__signal_child__":
        raise SystemExit(run_signal_child(sys.argv[2:]))
    unittest.main(verbosity=2)
