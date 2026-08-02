#!/usr/bin/env python3
"""Compute a deterministic SHA-256 digest for explicit build-input trees."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import stat
import sys


FORMAT_VERSION = b"skybridge-source-input-digest-v1\0"
EXCLUDED_DIRECTORY_NAMES = {
    ".build",
    ".git",
    ".swiftpm",
    "Artifacts",
    "DerivedData",
    "__pycache__",
    "node_modules",
    "xcuserdata",
}
EXCLUDED_FILE_NAMES = {".DS_Store"}


class DigestError(ValueError):
    pass


def _length_prefixed(value: bytes) -> bytes:
    return len(value).to_bytes(8, "big") + value


def _relative_path(root: Path, candidate: Path) -> str:
    try:
        relative = candidate.relative_to(root)
    except ValueError as exc:
        raise DigestError(f"input path escapes repository root: {candidate}") from exc
    return relative.as_posix()


def _iter_entries(root: Path, requested_paths: list[Path]) -> list[Path]:
    entries: list[Path] = []
    for requested in requested_paths:
        candidate = requested if requested.is_absolute() else root / requested
        candidate = candidate.absolute()
        _relative_path(root, candidate)
        if not candidate.exists() and not candidate.is_symlink():
            raise DigestError(f"required source input is missing: {candidate}")
        if candidate.is_symlink() or candidate.is_file():
            entries.append(candidate)
            continue
        if not candidate.is_dir():
            raise DigestError(f"unsupported source input type: {candidate}")
        for directory, directory_names, file_names in os.walk(
            candidate,
            topdown=True,
            followlinks=False,
        ):
            directory_names[:] = sorted(
                name for name in directory_names if name not in EXCLUDED_DIRECTORY_NAMES
            )
            directory_path = Path(directory)
            for name in sorted(file_names):
                if name in EXCLUDED_FILE_NAMES:
                    continue
                entries.append(directory_path / name)
            for name in directory_names:
                child = directory_path / name
                if child.is_symlink():
                    entries.append(child)
    deduplicated = {_relative_path(root, entry): entry for entry in entries}
    return [deduplicated[key] for key in sorted(deduplicated)]


def compute_digest(root: Path, requested_paths: list[Path]) -> tuple[str, int]:
    canonical_root = root.resolve(strict=True)
    if not canonical_root.is_dir():
        raise DigestError(f"repository root is not a directory: {canonical_root}")
    entries = _iter_entries(canonical_root, requested_paths)
    if not entries:
        raise DigestError("source input set is empty")

    digest = hashlib.sha256(FORMAT_VERSION)
    for entry in entries:
        relative = _relative_path(canonical_root, entry).encode("utf-8")
        metadata = entry.lstat()
        executable = b"1" if metadata.st_mode & stat.S_IXUSR else b"0"
        if stat.S_ISLNK(metadata.st_mode):
            kind = b"symlink"
            payload = os.readlink(entry).encode("utf-8")
        elif stat.S_ISREG(metadata.st_mode):
            kind = b"file"
            payload = entry.read_bytes()
        else:
            raise DigestError(f"unsupported source input type: {entry}")
        digest.update(_length_prefixed(relative))
        digest.update(_length_prefixed(kind))
        digest.update(_length_prefixed(executable))
        digest.update(_length_prefixed(payload))
    return digest.hexdigest(), len(entries)


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("paths", nargs="+", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        digest, file_count = compute_digest(args.root, args.paths)
    except (DigestError, OSError) as exc:
        print(f"source input digest failed: {exc}", file=sys.stderr)
        return 1
    print(f"{digest} {file_count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
