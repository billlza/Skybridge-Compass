#!/usr/bin/env python3

from __future__ import annotations

import io
import pathlib
import struct
import sys
import tarfile
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from validate_cli_native_archive import ArchiveContractError, TARGETS, validate  # noqa: E402


def binary_for(target: str) -> bytes:
    if target == "aarch64-apple-darwin":
        return struct.pack("<II", 0xFEEDFACF, 0x0100000C) + bytes(120)
    if target.endswith("linux-gnu"):
        value = bytearray(128)
        value[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", value, 18, 183 if target.startswith("aarch64") else 62)
        return bytes(value)
    value = bytearray(256)
    value[:2] = b"MZ"
    struct.pack_into("<I", value, 0x3C, 0x80)
    value[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<H", value, 0x84, 0x8664)
    return bytes(value)


class ValidateCLINativeArchiveTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_archive(self, target: str, binary: bytes | None = None) -> pathlib.Path:
        archive_name, binary_name = TARGETS[target]
        archive_path = self.root / archive_name
        payload = binary if binary is not None else binary_for(target)
        if archive_path.suffix == ".zip":
            info = zipfile.ZipInfo(binary_name)
            info.create_system = 3
            info.external_attr = 0o100755 << 16
            with zipfile.ZipFile(archive_path, mode="w") as archive:
                archive.writestr(info, payload)
        else:
            member = tarfile.TarInfo(binary_name)
            member.mode = 0o755
            member.size = len(payload)
            with tarfile.open(archive_path, mode="w:gz") as archive:
                archive.addfile(member, io.BytesIO(payload))
        return archive_path

    def test_accepts_exact_archives_for_all_four_targets(self) -> None:
        for target in TARGETS:
            with self.subTest(target=target):
                validate(self.write_archive(target), target)

    def test_rejects_wrong_machine(self) -> None:
        path = self.write_archive("x86_64-unknown-linux-gnu", binary_for("aarch64-unknown-linux-gnu"))
        with self.assertRaisesRegex(ArchiveContractError, "machine"):
            validate(path, "x86_64-unknown-linux-gnu")

    def test_rejects_nested_member(self) -> None:
        target = "aarch64-apple-darwin"
        archive_name, _ = TARGETS[target]
        path = self.root / archive_name
        payload = binary_for(target)
        member = tarfile.TarInfo("nested/skybridge")
        member.mode = 0o755
        member.size = len(payload)
        with tarfile.open(path, mode="w:gz") as archive:
            archive.addfile(member, io.BytesIO(payload))
        with self.assertRaisesRegex(ArchiveContractError, "exact executable"):
            validate(path, target)

    def test_rejects_link_member(self) -> None:
        target = "aarch64-apple-darwin"
        archive_name, binary_name = TARGETS[target]
        path = self.root / archive_name
        member = tarfile.TarInfo(binary_name)
        member.type = tarfile.SYMTYPE
        member.linkname = "/etc/passwd"
        with tarfile.open(path, mode="w:gz") as archive:
            archive.addfile(member)
        with self.assertRaisesRegex(ArchiveContractError, "exact executable"):
            validate(path, target)

    def test_rejects_unknown_target(self) -> None:
        path = self.root / "unknown.tar.gz"
        path.write_bytes(b"not-an-archive")
        with self.assertRaisesRegex(ArchiveContractError, "unsupported"):
            validate(path, "riscv64-unknown-linux-gnu")


if __name__ == "__main__":
    unittest.main()
