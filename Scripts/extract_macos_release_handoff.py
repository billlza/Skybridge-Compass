#!/usr/bin/env python3
"""Safely extract the exact signed macOS release handoff archive."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import stat
import sys
import tarfile
from pathlib import Path, PurePosixPath


MAX_MEMBERS = 50_000
MAX_FILE_BYTES = 4 * 1024 * 1024 * 1024
MAX_TOTAL_BYTES = 8 * 1024 * 1024 * 1024
APP_ROOT = "SkyBridge Compass Pro.app"
REQUIRED_FILES = {
    "macos-release-evidence.tar.gz",
    "release-artifact-run-provenance.json",
}
DMG_PATTERN = re.compile(r"SkyBridgeCompassPro-[0-9]+\.[0-9]+\.[0-9]+\.dmg", re.ASCII)


class HandoffError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise HandoffError(message)


def normalize_member_name(name: str) -> str:
    if "\\" in name or name.startswith("/"):
        fail(f"archive member path is not relative POSIX syntax: {name!r}")
    parts = [part for part in PurePosixPath(name).parts if part not in {"", "."}]
    if not parts:
        return ""
    if ".." in parts:
        fail(f"archive member path traverses its destination: {name!r}")
    normalized = "/".join(parts)
    top_level = parts[0]
    if (
        top_level != APP_ROOT
        and normalized not in REQUIRED_FILES
        and DMG_PATTERN.fullmatch(normalized) is None
    ):
        fail(f"archive member is outside the release handoff contract: {normalized}")
    if top_level != APP_ROOT and len(parts) != 1:
        fail(f"non-app release handoff member must be top-level: {normalized}")
    return normalized


def resolved_link_target(member_name: str, link_name: str) -> str:
    if not link_name or "\\" in link_name or link_name.startswith("/"):
        fail(f"archive link target is not a non-empty relative POSIX path: {link_name!r}")
    combined = PurePosixPath(member_name).parent / PurePosixPath(link_name)
    output: list[str] = []
    for part in combined.parts:
        if part in {"", "."}:
            continue
        if part == "..":
            if not output:
                fail(f"archive link target escapes its destination: {member_name} -> {link_name}")
            output.pop()
        else:
            output.append(part)
    if not output or output[0] != APP_ROOT:
        fail(f"archive link target escapes the app bundle: {member_name} -> {link_name}")
    return "/".join(output)


def validate_members(archive: tarfile.TarFile) -> tuple[list[tuple[tarfile.TarInfo, str]], str]:
    validated: list[tuple[tarfile.TarInfo, str]] = []
    seen: set[str] = set()
    total_bytes = 0
    dmg_names: set[str] = set()
    for index, member in enumerate(archive):
        if index >= MAX_MEMBERS:
            fail(f"archive member count exceeds {MAX_MEMBERS}")
        normalized = normalize_member_name(member.name)
        if not normalized:
            if not member.isdir():
                fail("the archive root entry must be a directory")
            continue
        if normalized in seen:
            fail(f"archive contains a duplicate normalized member: {normalized}")
        seen.add(normalized)
        if member.islnk():
            fail(f"archive hard links are forbidden: {normalized}")
        if member.issym():
            if not normalized.startswith(f"{APP_ROOT}/"):
                fail(f"archive symlink is outside the app bundle: {normalized}")
            resolved_link_target(normalized, member.linkname)
        elif member.isfile():
            if member.size < 1 or member.size > MAX_FILE_BYTES:
                fail(f"archive file has an invalid size: {normalized}")
            total_bytes += member.size
            if total_bytes > MAX_TOTAL_BYTES:
                fail(f"archive expanded byte count exceeds {MAX_TOTAL_BYTES}")
        elif not member.isdir():
            fail(f"archive special member is forbidden: {normalized}")
        if DMG_PATTERN.fullmatch(normalized):
            dmg_names.add(normalized)
        validated.append((member, normalized))
    if len(dmg_names) != 1:
        fail("release handoff must contain exactly one versioned DMG")
    missing = sorted(REQUIRED_FILES - seen)
    if missing:
        fail(f"release handoff is missing required files: {','.join(missing)}")
    if APP_ROOT not in seen or not any(name.startswith(f"{APP_ROOT}/") for name in seen):
        fail("release handoff is missing the app bundle")
    info_plist = f"{APP_ROOT}/Contents/Info.plist"
    if info_plist not in seen:
        fail("release handoff app bundle is missing Contents/Info.plist")
    return validated, next(iter(dmg_names))


def safe_destination(path: Path) -> Path:
    if path.exists() or path.is_symlink():
        fail(f"destination must not already exist: {path}")
    parent = path.parent.resolve(strict=True)
    return parent / path.name


def extract(archive_path: Path, destination: Path) -> str:
    try:
        metadata = archive_path.lstat()
    except OSError as exc:
        fail(f"unable to inspect release handoff archive: {exc}")
    if not stat.S_ISREG(metadata.st_mode) or archive_path.is_symlink() or metadata.st_nlink != 1:
        fail("release handoff archive must be a single-link regular file")
    output_root = safe_destination(destination)
    try:
        with tarfile.open(archive_path, mode="r:gz") as archive:
            members, dmg_name = validate_members(archive)
            output_root.mkdir(mode=0o700)
            try:
                directories = sorted(
                    ((member, name) for member, name in members if member.isdir()),
                    key=lambda item: (item[1].count("/"), item[1]),
                )
                files = sorted(
                    ((member, name) for member, name in members if member.isfile()),
                    key=lambda item: item[1],
                )
                links = sorted(
                    ((member, name) for member, name in members if member.issym()),
                    key=lambda item: item[1],
                )
                for member, name in directories:
                    target = output_root / name
                    target.mkdir(mode=member.mode & 0o777, parents=True, exist_ok=False)
                for member, name in files:
                    target = output_root / name
                    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    source = archive.extractfile(member)
                    if source is None:
                        fail(f"unable to read archive member: {name}")
                    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
                    if hasattr(os, "O_NOFOLLOW"):
                        flags |= os.O_NOFOLLOW
                    descriptor = os.open(target, flags, member.mode & 0o777)
                    try:
                        remaining = member.size
                        while remaining:
                            chunk = source.read(min(1024 * 1024, remaining))
                            if not chunk:
                                fail(f"archive member was truncated: {name}")
                            view = memoryview(chunk)
                            while view:
                                written = os.write(descriptor, view)
                                view = view[written:]
                            remaining -= len(chunk)
                        if source.read(1):
                            fail(f"archive member exceeds its declared size: {name}")
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
                        source.close()
                for member, name in links:
                    target = output_root / name
                    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    os.symlink(member.linkname, target)
                for member, name in sorted(
                    directories, key=lambda item: (-item[1].count("/"), item[1])
                ):
                    os.chmod(output_root / name, member.mode & 0o777, follow_symlinks=False)
            except BaseException:
                shutil.rmtree(output_root, ignore_errors=True)
                raise
    except (OSError, tarfile.TarError) as exc:
        fail(f"unable to extract release handoff archive: {exc}")
    return dmg_name


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args()
    try:
        dmg_name = extract(args.archive, args.destination)
    except HandoffError as exc:
        print(f"macOS release handoff rejected: {exc}", file=sys.stderr)
        return 1
    print(f"macOS release handoff extracted: dmg={dmg_name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
