#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import stat
import tempfile

from finalize_cli_release_assets import (
    PLATFORM_ASSETS,
    exact_directory_files,
    maximum_size,
    regular_file,
    sha256,
)


VERSION_RE = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)
MAX_SOURCE_FILES = 100
MAX_SOURCE_BYTES = 16 * 1024 * 1024


def load_json_exact(path: pathlib.Path) -> dict[str, object]:
    def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate package.json key: {key}")
            result[key] = value
        return result

    value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicates)
    if not isinstance(value, dict):
        raise ValueError("package.json must contain one object")
    return value


def validate_source_tree(source: pathlib.Path) -> None:
    metadata = source.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ValueError("npm package source must be a real directory")
    file_count = 0
    total_bytes = 0
    for root, directories, files in os.walk(source, followlinks=False):
        root_path = pathlib.Path(root)
        for name in directories:
            child = root_path / name
            child_metadata = child.lstat()
            if stat.S_ISLNK(child_metadata.st_mode) or not stat.S_ISDIR(child_metadata.st_mode):
                raise ValueError(f"npm package source contains an unsafe directory: {child}")
        for name in files:
            child = root_path / name
            child_metadata = child.lstat()
            if stat.S_ISLNK(child_metadata.st_mode) or not stat.S_ISREG(child_metadata.st_mode):
                raise ValueError(f"npm package source contains an unsafe file: {child}")
            if child_metadata.st_nlink != 1 or child_metadata.st_size <= 0:
                raise ValueError(f"npm package source file violates the release contract: {child}")
            file_count += 1
            total_bytes += child_metadata.st_size
            if file_count > MAX_SOURCE_FILES or total_bytes > MAX_SOURCE_BYTES:
                raise ValueError("npm package source exceeds the bounded release contract")


def atomic_json(path: pathlib.Path, value: dict[str, object]) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = pathlib.Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        temporary_path.unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description="Stage the npm wrapper package for publishing.")
    parser.add_argument("--source-dir", required=True, type=pathlib.Path)
    parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--assets-dir", required=True, type=pathlib.Path)
    args = parser.parse_args()

    if VERSION_RE.fullmatch(args.version) is None:
        raise SystemExit(f"invalid npm package version: {args.version!r}")
    if re.fullmatch(r"[0-9a-f]{40}", args.source_sha) is None:
        raise SystemExit("source SHA must be canonical lowercase 40-hex")
    validate_source_tree(args.source_dir)
    platform_names = tuple(name for name, _, _ in PLATFORM_ASSETS)
    exact_directory_files(args.assets_dir, platform_names)
    if args.output_dir.exists() or args.output_dir.is_symlink():
        raise SystemExit(f"refusing to replace an existing npm stage: {args.output_dir}")
    if not args.output_dir.parent.is_dir() or args.output_dir.parent.is_symlink():
        raise SystemExit("npm stage parent must be a real directory")
    shutil.copytree(args.source_dir, args.output_dir)

    package_json_path = args.output_dir / "package.json"
    package_json = load_json_exact(package_json_path)
    if package_json.get("name") != "skybridge-cli":
        raise SystemExit("npm package source has an unexpected package name")
    package_json["version"] = args.version
    package_json["gitHead"] = args.source_sha
    atomic_json(package_json_path, package_json)
    release_assets = {
        "schemaVersion": 1,
        "version": args.version,
        "sourceSha": args.source_sha,
        "assets": [
            {
                "name": name,
                "sha256": sha256(args.assets_dir / name),
                "sizeBytes": regular_file(
                    args.assets_dir / name,
                    maximum_bytes=maximum_size(name),
                ).st_size,
            }
            for name in platform_names
        ],
    }
    atomic_json(args.output_dir / "release-assets.json", release_assets)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
