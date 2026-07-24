#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import pathlib
import stat
import struct
import sys
import tarfile
import zipfile


MAX_BINARY_BYTES = 256 * 1024 * 1024
TARGETS = {
    "aarch64-apple-darwin": ("skybridge-aarch64-apple-darwin.tar.gz", "skybridge"),
    "aarch64-unknown-linux-gnu": ("skybridge-aarch64-unknown-linux-gnu.tar.gz", "skybridge"),
    "x86_64-unknown-linux-gnu": ("skybridge-x86_64-unknown-linux-gnu.tar.gz", "skybridge"),
    "x86_64-pc-windows-msvc": ("skybridge-x86_64-pc-windows-msvc.zip", "skybridge.exe"),
}


class ArchiveContractError(ValueError):
    pass


def regular_archive(path: pathlib.Path) -> None:
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ArchiveContractError("native archive must be a regular file, not a link")
    if metadata.st_nlink != 1 or metadata.st_size <= 0 or metadata.st_size > MAX_BINARY_BYTES:
        raise ArchiveContractError("native archive size or link count violates the release contract")


def read_tar_binary(path: pathlib.Path, expected_name: str) -> bytes:
    with tarfile.open(path, mode="r:gz") as archive:
        members = archive.getmembers()
        if len(members) != 1:
            raise ArchiveContractError("tar archive must contain exactly one member")
        member = members[0]
        if (
            member.name != expected_name
            or pathlib.PurePosixPath(member.name).name != member.name
            or not member.isreg()
            or member.issym()
            or member.islnk()
            or member.size <= 0
            or member.size > MAX_BINARY_BYTES
            or member.mode & 0o111 == 0
        ):
            raise ArchiveContractError("tar member is not the exact executable release binary")
        stream = archive.extractfile(member)
        if stream is None:
            raise ArchiveContractError("unable to read tar release binary")
        binary = stream.read(MAX_BINARY_BYTES + 1)
        if len(binary) != member.size:
            raise ArchiveContractError("tar release binary size is inconsistent")
        return binary


def read_zip_binary(path: pathlib.Path, expected_name: str) -> bytes:
    with zipfile.ZipFile(path, mode="r") as archive:
        entries = archive.infolist()
        if len(entries) != 1:
            raise ArchiveContractError("zip archive must contain exactly one member")
        entry = entries[0]
        unix_mode = (entry.external_attr >> 16) & 0xFFFF
        if (
            entry.filename != expected_name
            or pathlib.PurePosixPath(entry.filename).name != entry.filename
            or entry.is_dir()
            or entry.file_size <= 0
            or entry.file_size > MAX_BINARY_BYTES
            or (unix_mode and not stat.S_ISREG(unix_mode))
        ):
            raise ArchiveContractError("zip member is not the exact regular release binary")
        binary = archive.read(entry)
        if len(binary) != entry.file_size:
            raise ArchiveContractError("zip release binary size is inconsistent")
        return binary


def validate_machine(binary: bytes, target: str) -> None:
    if target == "aarch64-apple-darwin":
        if len(binary) < 8:
            raise ArchiveContractError("Mach-O binary is truncated")
        magic, cpu_type = struct.unpack_from("<II", binary)
        if magic != 0xFEEDFACF or cpu_type != 0x0100000C:
            raise ArchiveContractError("Mach-O binary is not thin arm64")
        return
    if target in {"aarch64-unknown-linux-gnu", "x86_64-unknown-linux-gnu"}:
        if len(binary) < 20 or binary[:4] != b"\x7fELF" or binary[4:6] != b"\x02\x01":
            raise ArchiveContractError("Linux binary is not little-endian ELF64")
        machine = struct.unpack_from("<H", binary, 18)[0]
        expected = 183 if target.startswith("aarch64") else 62
        if machine != expected:
            raise ArchiveContractError("ELF machine does not match the release target")
        return
    if len(binary) < 64 or binary[:2] != b"MZ":
        raise ArchiveContractError("Windows binary is not a PE image")
    pe_offset = struct.unpack_from("<I", binary, 0x3C)[0]
    if pe_offset > len(binary) - 6 or binary[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise ArchiveContractError("Windows PE header is invalid")
    if struct.unpack_from("<H", binary, pe_offset + 4)[0] != 0x8664:
        raise ArchiveContractError("Windows PE machine is not x86_64")


def validate(path: pathlib.Path, target: str) -> None:
    if target not in TARGETS:
        raise ArchiveContractError(f"unsupported CLI release target: {target}")
    expected_archive, expected_binary = TARGETS[target]
    if path.name != expected_archive:
        raise ArchiveContractError("native archive name does not match the target")
    regular_archive(path)
    try:
        if path.name.endswith(".zip"):
            binary = read_zip_binary(path, expected_binary)
        else:
            binary = read_tar_binary(path, expected_binary)
    except (tarfile.TarError, zipfile.BadZipFile, OSError) as error:
        raise ArchiveContractError("unable to inspect native release archive") from error
    validate_machine(binary, target)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate an exact SkyBridge CLI native archive.")
    parser.add_argument("--archive", required=True, type=pathlib.Path)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()
    try:
        validate(args.archive, args.target)
    except (ArchiveContractError, OSError) as error:
        print(f"CLI native archive contract failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
