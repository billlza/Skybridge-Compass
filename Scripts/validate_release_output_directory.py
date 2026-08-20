#!/usr/bin/env python3
"""Validate a dedicated, disposable release-output directory.

This is a reliability boundary against an accidental or polluted output-path
environment variable. It does not claim to resist a malicious same-UID process
racing filesystem changes after validation.
"""

from __future__ import annotations

import argparse
import os
import re
import stat
from pathlib import Path


class OutputDirectoryError(ValueError):
    pass


def _fail(message: str) -> "None":
    raise OutputDirectoryError(message)


def _canonical_existing_directory(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        _fail(f"{label} is unavailable: {error}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        _fail(f"{label} must be a real directory, not a link or special file")
    try:
        return path.resolve(strict=True)
    except OSError as error:
        _fail(f"unable to resolve {label}: {error}")


def _is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def validate_output_directory(
    *, repository_root: Path, temporary_root: Path, output: Path
) -> Path:
    repository = _canonical_existing_directory(repository_root, "repository root")
    temporary = _canonical_existing_directory(temporary_root, "temporary root")
    home = Path.home().resolve(strict=True)

    sandbox = repository / ".sandbox-home"
    sandbox.mkdir(mode=0o700, parents=False, exist_ok=True)
    sandbox = _canonical_existing_directory(sandbox, "repository release sandbox")

    raw = os.path.expanduser(os.fspath(output))
    if not os.path.isabs(raw):
        _fail("release output path must be absolute")
    lexical = Path(os.path.normpath(raw))
    if any(part == ".." for part in Path(raw).parts):
        _fail("release output path must not contain parent traversal")
    if re.fullmatch(r"(?:release-candidate|skybridge-ios-release-[A-Za-z0-9._-]+)", lexical.name) is None:
        _fail(
            "release output basename must be release-candidate or begin "
            "skybridge-ios-release-"
        )

    parent = _canonical_existing_directory(lexical.parent, "release output parent")
    candidate = parent / lexical.name
    allowed_root = next(
        (root for root in (sandbox, temporary) if _is_relative_to(candidate, root)),
        None,
    )
    if allowed_root is None or candidate == allowed_root:
        _fail("release output must be a dedicated child of the repository sandbox or temporary root")
    if candidate in {Path("/"), home, repository, temporary, sandbox}:
        _fail("release output resolves to a protected directory")
    if _is_relative_to(repository, candidate) or _is_relative_to(home, candidate):
        _fail("release output must not contain the repository or home directory")

    relative = candidate.relative_to(allowed_root)
    cursor = allowed_root
    for component in relative.parts:
        cursor = cursor / component
        try:
            metadata = cursor.lstat()
        except FileNotFoundError:
            break
        except OSError as error:
            _fail(f"unable to inspect release output component: {error}")
        if stat.S_ISLNK(metadata.st_mode):
            _fail("release output path must not contain symbolic links")
        if cursor == candidate and not stat.S_ISDIR(metadata.st_mode):
            _fail("existing release output must be a directory")
        if cursor != candidate and not stat.S_ISDIR(metadata.st_mode):
            _fail("release output parent components must be directories")

    return candidate


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--temporary-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        validated = validate_output_directory(
            repository_root=args.repository_root,
            temporary_root=args.temporary_root,
            output=args.output,
        )
    except OutputDirectoryError as error:
        raise SystemExit(f"[release-output] ERROR: {error}") from error
    print(validated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
