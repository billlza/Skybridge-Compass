#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import stat
import tempfile
from typing import Any, Iterable


SCHEMA_VERSION = 1
MANIFEST_NAME = "release-manifest.json"
CHECKSUMS_NAME = "SHA256SUMS.txt"
FORMULA_NAME = "skybridge.rb"
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_NPM_PACKAGE_BYTES = 64 * 1024 * 1024
MAX_METADATA_BYTES = 1024 * 1024

PLATFORM_ASSETS: tuple[tuple[str, str, str], ...] = (
    ("skybridge-aarch64-apple-darwin.tar.gz", "darwin", "arm64"),
    ("skybridge-aarch64-unknown-linux-gnu.tar.gz", "linux", "arm64"),
    ("skybridge-x86_64-unknown-linux-gnu.tar.gz", "linux", "x64"),
    ("skybridge-x86_64-pc-windows-msvc.zip", "windows", "x64"),
)

VERSION_RE = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)
REPOSITORY_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
SHA_RE = re.compile(r"[0-9a-f]{40}")
TOOLCHAIN_RE = re.compile(r"1\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")
CHECKSUM_LINE_RE = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9_.+-]+)")


class ContractError(ValueError):
    pass


def npm_package_name(version: str) -> str:
    validate_version(version)
    return f"skybridge-cli-{version}.tgz"


def validate_version(version: str) -> None:
    if VERSION_RE.fullmatch(version) is None:
        raise ContractError(f"invalid CLI semantic version: {version!r}")


def validate_repository(repository: str) -> None:
    if REPOSITORY_RE.fullmatch(repository) is None or ".." in repository:
        raise ContractError(f"invalid source repository: {repository!r}")


def validate_source_sha(source_sha: str) -> None:
    if SHA_RE.fullmatch(source_sha) is None:
        raise ContractError("source SHA must be canonical lowercase 40-byte hex")


def validate_toolchain(toolchain: str) -> None:
    if TOOLCHAIN_RE.fullmatch(toolchain) is None:
        raise ContractError(f"invalid pinned Rust toolchain: {toolchain!r}")


def expected_input_names(version: str) -> tuple[str, ...]:
    return tuple(name for name, _, _ in PLATFORM_ASSETS) + (npm_package_name(version),)


def expected_payload_names(version: str) -> tuple[str, ...]:
    return expected_input_names(version) + (FORMULA_NAME,)


def expected_final_names(version: str) -> tuple[str, ...]:
    return expected_payload_names(version) + (MANIFEST_NAME, CHECKSUMS_NAME)


def maximum_size(name: str) -> int:
    if name.endswith((".tar.gz", ".zip")) and not name.startswith("skybridge-cli-"):
        return MAX_ARCHIVE_BYTES
    if name.startswith("skybridge-cli-") and name.endswith(".tgz"):
        return MAX_NPM_PACKAGE_BYTES
    return MAX_METADATA_BYTES


def regular_file(path: pathlib.Path, *, maximum_bytes: int) -> os.stat_result:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise ContractError(f"missing release asset: {path.name}") from error
    if stat.S_ISLNK(metadata.st_mode):
        raise ContractError(f"release asset must not be a symbolic link: {path.name}")
    if not stat.S_ISREG(metadata.st_mode):
        raise ContractError(f"release asset must be a regular file: {path.name}")
    if metadata.st_nlink != 1:
        raise ContractError(f"release asset must not be hard-linked: {path.name}")
    if metadata.st_size <= 0:
        raise ContractError(f"release asset must not be empty: {path.name}")
    if metadata.st_size > maximum_bytes:
        raise ContractError(
            f"release asset exceeds size limit: {path.name} "
            f"({metadata.st_size} > {maximum_bytes})"
        )
    return metadata


def exact_directory_files(directory: pathlib.Path, expected: Iterable[str]) -> None:
    if directory.is_symlink() or not directory.is_dir():
        raise ContractError("release assets path must be a real directory")
    expected_set = set(expected)
    actual: set[str] = set()
    for entry in directory.iterdir():
        if entry.name in {".", ".."}:
            raise ContractError("invalid release asset entry")
        if entry.name not in expected_set:
            raise ContractError(f"unexpected release asset: {entry.name}")
        if entry.name in actual:
            raise ContractError(f"duplicate release asset: {entry.name}")
        regular_file(entry, maximum_bytes=maximum_size(entry.name))
        actual.add(entry.name)
    missing = expected_set - actual
    if missing:
        raise ContractError(f"missing release assets: {', '.join(sorted(missing))}")


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def asset_record(path: pathlib.Path, role: str, os_name: str | None, arch: str | None) -> dict[str, Any]:
    metadata = regular_file(path, maximum_bytes=maximum_size(path.name))
    record: dict[str, Any] = {
        "name": path.name,
        "role": role,
        "size_bytes": metadata.st_size,
        "sha256": sha256(path),
    }
    if os_name is not None:
        record["os"] = os_name
    if arch is not None:
        record["arch"] = arch
    return record


def payload_records(directory: pathlib.Path, version: str) -> list[dict[str, Any]]:
    records = [
        asset_record(directory / name, "native-archive", os_name, arch)
        for name, os_name, arch in PLATFORM_ASSETS
    ]
    records.append(
        asset_record(
            directory / npm_package_name(version),
            "npm-package",
            None,
            None,
        )
    )
    records.append(asset_record(directory / FORMULA_NAME, "homebrew-formula", None, None))
    return records


def atomic_write(path: pathlib.Path, data: bytes) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = pathlib.Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(data)
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


def load_json_exact(path: pathlib.Path) -> dict[str, Any]:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ContractError(f"duplicate JSON key in {path.name}: {key}")
            result[key] = value
        return result

    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractError(f"invalid JSON in {path.name}") from error
    if not isinstance(value, dict):
        raise ContractError(f"{path.name} must contain one JSON object")
    return value


def expected_manifest(
    directory: pathlib.Path,
    *,
    version: str,
    source_repository: str,
    source_sha: str,
    rust_toolchain: str,
    source_date_epoch: int,
) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "component": "skybridge-cli",
        "version": version,
        "release_tag": f"skybridge-cli-v{version}",
        "source_repository": source_repository,
        "source_sha": source_sha,
        "rust_toolchain": rust_toolchain,
        "source_date_epoch": source_date_epoch,
        "assets": payload_records(directory, version),
    }


def finalize(
    directory: pathlib.Path,
    *,
    version: str,
    source_repository: str,
    source_sha: str,
    rust_toolchain: str,
    source_date_epoch: int,
) -> None:
    validate_metadata(
        version=version,
        source_repository=source_repository,
        source_sha=source_sha,
        rust_toolchain=rust_toolchain,
        source_date_epoch=source_date_epoch,
    )
    regular_file(directory / FORMULA_NAME, maximum_bytes=MAX_METADATA_BYTES)
    exact_directory_files(directory, expected_payload_names(version))

    manifest = expected_manifest(
        directory,
        version=version,
        source_repository=source_repository,
        source_sha=source_sha,
        rust_toolchain=rust_toolchain,
        source_date_epoch=source_date_epoch,
    )
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    atomic_write(directory / MANIFEST_NAME, manifest_bytes)

    checksum_names = sorted(expected_payload_names(version) + (MANIFEST_NAME,))
    checksum_text = "".join(
        f"{sha256(directory / name)}  {name}\n" for name in checksum_names
    )
    atomic_write(directory / CHECKSUMS_NAME, checksum_text.encode("utf-8"))
    verify(
        directory,
        version=version,
        source_repository=source_repository,
        source_sha=source_sha,
        rust_toolchain=rust_toolchain,
        source_date_epoch=source_date_epoch,
    )


def validate_inputs(directory: pathlib.Path, version: str) -> None:
    validate_version(version)
    exact_directory_files(directory, expected_input_names(version))


def validate_metadata(
    *,
    version: str,
    source_repository: str,
    source_sha: str,
    rust_toolchain: str,
    source_date_epoch: int,
) -> None:
    validate_version(version)
    validate_repository(source_repository)
    validate_source_sha(source_sha)
    validate_toolchain(rust_toolchain)
    if source_date_epoch <= 0:
        raise ContractError("source date epoch must be positive")


def verify(
    directory: pathlib.Path,
    *,
    version: str,
    source_repository: str,
    source_sha: str,
    rust_toolchain: str,
    source_date_epoch: int,
) -> None:
    validate_metadata(
        version=version,
        source_repository=source_repository,
        source_sha=source_sha,
        rust_toolchain=rust_toolchain,
        source_date_epoch=source_date_epoch,
    )
    exact_directory_files(directory, expected_final_names(version))

    actual_manifest = load_json_exact(directory / MANIFEST_NAME)
    expected = expected_manifest(
        directory,
        version=version,
        source_repository=source_repository,
        source_sha=source_sha,
        rust_toolchain=rust_toolchain,
        source_date_epoch=source_date_epoch,
    )
    if actual_manifest != expected:
        raise ContractError("release manifest does not match the exact payload bytes and source")

    checksum_path = directory / CHECKSUMS_NAME
    regular_file(checksum_path, maximum_bytes=MAX_METADATA_BYTES)
    expected_checksum_names = set(expected_payload_names(version) + (MANIFEST_NAME,))
    actual_checksums: dict[str, str] = {}
    try:
        checksum_lines = checksum_path.read_text(encoding="ascii").splitlines()
    except UnicodeDecodeError as error:
        raise ContractError("checksum manifest must be ASCII") from error
    for line in checksum_lines:
        match = CHECKSUM_LINE_RE.fullmatch(line)
        if match is None:
            raise ContractError(f"invalid checksum line: {line!r}")
        digest, name = match.groups()
        if name in actual_checksums:
            raise ContractError(f"duplicate checksum entry: {name}")
        actual_checksums[name] = digest
    if set(actual_checksums) != expected_checksum_names:
        raise ContractError("checksum manifest does not cover the exact release asset set")
    for name, digest in actual_checksums.items():
        if sha256(directory / name) != digest:
            raise ContractError(f"release asset checksum mismatch: {name}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Finalize and verify SkyBridge CLI release assets.")
    subparsers = result.add_subparsers(dest="command", required=True)

    preflight = subparsers.add_parser("preflight")
    preflight.add_argument("--assets-dir", required=True, type=pathlib.Path)
    preflight.add_argument("--version", required=True)

    for command in ("validate-metadata", "finalize", "verify"):
        child = subparsers.add_parser(command)
        if command != "validate-metadata":
            child.add_argument("--assets-dir", required=True, type=pathlib.Path)
        child.add_argument("--version", required=True)
        child.add_argument("--source-repository", required=True)
        child.add_argument("--source-sha", required=True)
        child.add_argument("--rust-toolchain", required=True)
        child.add_argument("--source-date-epoch", required=True, type=int)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "preflight":
            validate_inputs(args.assets_dir, args.version)
        elif args.command == "validate-metadata":
            validate_metadata(
                version=args.version,
                source_repository=args.source_repository,
                source_sha=args.source_sha,
                rust_toolchain=args.rust_toolchain,
                source_date_epoch=args.source_date_epoch,
            )
        elif args.command == "finalize":
            finalize(
                args.assets_dir,
                version=args.version,
                source_repository=args.source_repository,
                source_sha=args.source_sha,
                rust_toolchain=args.rust_toolchain,
                source_date_epoch=args.source_date_epoch,
            )
        else:
            verify(
                args.assets_dir,
                version=args.version,
                source_repository=args.source_repository,
                source_sha=args.source_sha,
                rust_toolchain=args.rust_toolchain,
                source_date_epoch=args.source_date_epoch,
            )
    except (ContractError, OSError) as error:
        print(f"cli release asset contract failed: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
