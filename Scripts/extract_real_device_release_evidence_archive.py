#!/usr/bin/env python3
"""Safely extract a mode-preserving real-device release evidence archive."""

from __future__ import annotations

import argparse
import os
import pathlib
import stat
import tarfile
from typing import NoReturn


MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
MAX_MEMBER_BYTES = 512 * 1024 * 1024
MAX_EXTRACTED_BYTES = 1024 * 1024 * 1024
MAX_ENTRIES = 10_000
MAX_MEMBER_NAME_BYTES = 4096


def fail(message: str) -> NoReturn:
    raise SystemExit(f"release evidence archive rejected: {message}")


def normalized_member_parts(member: tarfile.TarInfo) -> tuple[str, ...] | None:
    member_path = pathlib.PurePosixPath(member.name)
    parts = tuple(part for part in member_path.parts if part not in ("", "."))
    if not parts and member.isdir():
        return None
    try:
        encoded_name = member.name.encode("utf-8", errors="strict")
    except UnicodeError:
        fail("member name is not valid UTF-8")
    if (
        member_path.is_absolute()
        or not parts
        or ".." in parts
        or len(encoded_name) > MAX_MEMBER_NAME_BYTES
    ):
        fail("archive contains an unsafe member path")
    return parts


def validated_members(archive: tarfile.TarFile) -> list[tuple[tarfile.TarInfo, tuple[str, ...], int]]:
    entries: list[tuple[tarfile.TarInfo, tuple[str, ...], int]] = []
    seen_paths: set[tuple[str, ...]] = set()
    total_bytes = 0
    for member in archive.getmembers():
        parts = normalized_member_parts(member)
        if parts is None:
            continue
        if parts in seen_paths:
            fail("archive contains a duplicate member path")
        seen_paths.add(parts)
        if not (member.isdir() or member.isfile()):
            fail("archive contains a link or special file")

        member_mode = stat.S_IMODE(member.mode)
        if member_mode & 0o7000:
            fail("archive contains a member with special permission bits")
        if member_mode & 0o022:
            fail("archive contains a group/world-writable member")
        if member.isdir() and member_mode & 0o500 != 0o500:
            fail("archive contains an inaccessible directory")
        if member.isfile() and member_mode & 0o400 != 0o400:
            fail("archive contains an unreadable file")
        if member.size < 0 or member.size > MAX_MEMBER_BYTES:
            fail("archive member exceeds the size limit")
        total_bytes += member.size
        if total_bytes > MAX_EXTRACTED_BYTES or len(entries) >= MAX_ENTRIES:
            fail("archive exceeds extraction limits")
        entries.append((member, parts, member_mode))
    if not entries:
        fail("archive is empty")
    return entries


def write_member(
    archive: tarfile.TarFile,
    member: tarfile.TarInfo,
    output_path: pathlib.Path,
    member_mode: int,
) -> None:
    source = archive.extractfile(member)
    if source is None:
        fail("unable to read archive member")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(output_path, flags, 0o600)
    try:
        remaining = member.size
        while remaining:
            chunk = source.read(min(1024 * 1024, remaining))
            if not chunk:
                fail("archive member ended before its declared size")
            unwritten = memoryview(chunk)
            while unwritten:
                written = os.write(descriptor, unwritten)
                if written <= 0:
                    fail("unable to write archive member")
                unwritten = unwritten[written:]
            remaining -= len(chunk)
        if source.read(1):
            fail("archive member exceeds its declared size")
        os.fchmod(descriptor, member_mode)
        os.fsync(descriptor)
    finally:
        source.close()
        os.close(descriptor)


def extract_archive(archive_path: pathlib.Path, destination_root: pathlib.Path) -> None:
    try:
        archive_metadata = archive_path.lstat()
    except FileNotFoundError:
        fail(f"archive does not exist: {archive_path}")
    if not stat.S_ISREG(archive_metadata.st_mode):
        fail("archive must be a regular file, not a link or special file")
    if archive_metadata.st_size <= 0 or archive_metadata.st_size > MAX_ARCHIVE_BYTES:
        fail("archive compressed size is outside the accepted range")
    try:
        destination_parent_metadata = destination_root.parent.lstat()
    except FileNotFoundError:
        fail("destination parent does not exist")
    if not stat.S_ISDIR(destination_parent_metadata.st_mode):
        fail("destination parent must be a real directory")
    try:
        destination_root.lstat()
    except FileNotFoundError:
        pass
    else:
        fail("destination already exists")

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(archive_path, flags)
    with os.fdopen(descriptor, "rb", closefd=True) as archive_file:
        opened_metadata = os.fstat(archive_file.fileno())
        if (
            not stat.S_ISREG(opened_metadata.st_mode)
            or opened_metadata.st_dev != archive_metadata.st_dev
            or opened_metadata.st_ino != archive_metadata.st_ino
            or opened_metadata.st_size != archive_metadata.st_size
        ):
            fail("archive changed before it could be opened")
        try:
            archive = tarfile.open(fileobj=archive_file, mode="r:gz")
        except (OSError, tarfile.TarError) as exc:
            fail(f"archive is not a valid gzip-compressed tar file: {exc}")
        with archive:
            entries = validated_members(archive)
            destination_root.mkdir(mode=0o700)
            for member, parts, _ in sorted(entries, key=lambda entry: len(entry[1])):
                if member.isdir():
                    destination_root.joinpath(*parts).mkdir(
                        mode=0o700, parents=True, exist_ok=True
                    )
            for member, parts, member_mode in entries:
                if not member.isfile():
                    continue
                output_path = destination_root.joinpath(*parts)
                output_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                write_member(archive, member, output_path, member_mode)
            for member, parts, member_mode in sorted(
                entries, key=lambda entry: len(entry[1]), reverse=True
            ):
                if member.isdir():
                    os.chmod(destination_root.joinpath(*parts), member_mode)

        final_metadata = os.fstat(archive_file.fileno())
        try:
            final_path_metadata = archive_path.lstat()
        except FileNotFoundError:
            fail("archive path disappeared during extraction")
        if (
            final_metadata.st_dev != opened_metadata.st_dev
            or final_metadata.st_ino != opened_metadata.st_ino
            or final_metadata.st_size != opened_metadata.st_size
            or final_path_metadata.st_dev != final_metadata.st_dev
            or final_path_metadata.st_ino != final_metadata.st_ino
        ):
            fail("archive changed during extraction")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--destination", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    extract_archive(args.archive, args.destination)
    print(f"release evidence archive extracted: {args.destination}")


if __name__ == "__main__":
    main()
