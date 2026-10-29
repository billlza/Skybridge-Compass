#!/usr/bin/env python3

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import stat
import tarfile
import tempfile
from collections.abc import Callable

from finalize_cli_release_assets import (
    ContractError,
    expected_final_names,
    load_json_exact,
    maximum_size,
    regular_file,
    validate_repository,
    validate_source_sha,
    validate_toolchain,
    validate_version,
    verify,
)


CHECKSUM_RE = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9_.+-]+)")
MAX_HANDOFF_BYTES = 2 * 1024 * 1024 * 1024
HANDOFF_METADATA_NAME = "handoff-metadata.json"
RELEASE_WORKFLOW_PATH = ".github/workflows/skybridge-cli-release.yml"


def validate_workflow_identity(workflow_run_id: int, workflow_run_attempt: int) -> None:
    if workflow_run_id <= 0:
        raise ContractError("workflow run ID must be positive")
    if workflow_run_attempt <= 0:
        raise ContractError("workflow run attempt must be positive")


def validate_workflow_source(
    source_repository: str,
    workflow_ref: str,
    workflow_sha: str,
) -> None:
    expected_prefix = f"{source_repository}/{RELEASE_WORKFLOW_PATH}@"
    if not workflow_ref.startswith(expected_prefix):
        raise ContractError("workflow ref does not name the canonical CLI release workflow")
    git_ref = workflow_ref[len(expected_prefix) :]
    if not (git_ref.startswith("refs/heads/") or git_ref.startswith("refs/tags/")):
        raise ContractError("workflow ref must use an explicit heads or tags ref")
    ref_suffix = git_ref.split("/", 2)[-1]
    if (
        not ref_suffix
        or len(workflow_ref) > 512
        or not re.fullmatch(r"[A-Za-z0-9._/+\-]+", ref_suffix)
        or ".." in ref_suffix
        or "//" in ref_suffix
        or ref_suffix.startswith("/")
        or ref_suffix.endswith("/")
        or ref_suffix.endswith(".lock")
    ):
        raise ContractError("workflow ref has a non-canonical Git ref")
    validate_source_sha(workflow_sha)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def handoff_metadata(
    assets_dir: pathlib.Path,
    *,
    version: str,
    source_repository: str,
    source_sha: str,
    rust_toolchain: str,
    source_date_epoch: int,
    workflow_run_id: int,
    workflow_run_attempt: int,
    workflow_ref: str,
    workflow_sha: str,
) -> dict[str, object]:
    assets: list[dict[str, object]] = []
    for name in expected_final_names(version):
        path = assets_dir / name
        metadata = regular_file(path, maximum_bytes=maximum_size(name))
        assets.append(
            {
                "name": name,
                "size_bytes": metadata.st_size,
                "sha256": sha256(path),
            }
        )
    return {
        "schema_version": 1,
        "profile": "skybridge-cli-release-handoff",
        "version": version,
        "release_tag": f"skybridge-cli-v{version}",
        "source_repository": source_repository,
        "source_sha": source_sha,
        "rust_toolchain": rust_toolchain,
        "source_date_epoch": source_date_epoch,
        "producer_workflow_run_id": workflow_run_id,
        "producer_workflow_run_attempt": workflow_run_attempt,
        "producer_workflow_ref": workflow_ref,
        "producer_workflow_sha": workflow_sha,
        "assets": assets,
    }


def atomic_replace(path: pathlib.Path, writer: Callable[[pathlib.Path], None]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    os.close(descriptor)
    temporary_path = pathlib.Path(temporary_name)
    try:
        writer(temporary_path)
        regular_file(temporary_path, maximum_bytes=MAX_HANDOFF_BYTES)
        os.chmod(temporary_path, 0o644)
        os.replace(temporary_path, path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise


def create(
    *,
    assets_dir: pathlib.Path,
    archive: pathlib.Path,
    checksum: pathlib.Path,
    version: str,
    source_repository: str,
    source_sha: str,
    rust_toolchain: str,
    source_date_epoch: int,
    workflow_run_id: int,
    workflow_run_attempt: int,
    workflow_ref: str,
    workflow_sha: str,
) -> None:
    verify(
        assets_dir,
        version=version,
        source_repository=source_repository,
        source_sha=source_sha,
        rust_toolchain=rust_toolchain,
        source_date_epoch=source_date_epoch,
    )
    validate_workflow_identity(workflow_run_id, workflow_run_attempt)
    validate_workflow_source(source_repository, workflow_ref, workflow_sha)
    if archive == checksum:
        raise ContractError("handoff archive and checksum paths must differ")
    if archive.parent.resolve() != checksum.parent.resolve():
        raise ContractError("handoff archive and checksum must share one directory")

    names = expected_final_names(version)
    metadata_bytes = (
        json.dumps(
            handoff_metadata(
                assets_dir,
                version=version,
                source_repository=source_repository,
                source_sha=source_sha,
                rust_toolchain=rust_toolchain,
                source_date_epoch=source_date_epoch,
                workflow_run_id=workflow_run_id,
                workflow_run_attempt=workflow_run_attempt,
                workflow_ref=workflow_ref,
                workflow_sha=workflow_sha,
            ),
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")

    def write_archive(temporary_path: pathlib.Path) -> None:
        with temporary_path.open("wb") as raw:
            with gzip.GzipFile(
                filename="",
                mode="wb",
                fileobj=raw,
                mtime=source_date_epoch,
            ) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as output:
                    for name in names:
                        source = assets_dir / name
                        metadata = regular_file(source, maximum_bytes=maximum_size(name))
                        info = tarfile.TarInfo(name=name)
                        info.size = metadata.st_size
                        info.mode = 0o644
                        info.uid = 0
                        info.gid = 0
                        info.uname = ""
                        info.gname = ""
                        info.mtime = source_date_epoch
                        with source.open("rb") as handle:
                            output.addfile(info, handle)
                    metadata_info = tarfile.TarInfo(name=HANDOFF_METADATA_NAME)
                    metadata_info.size = len(metadata_bytes)
                    metadata_info.mode = 0o600
                    metadata_info.uid = 0
                    metadata_info.gid = 0
                    metadata_info.uname = ""
                    metadata_info.gname = ""
                    metadata_info.mtime = source_date_epoch
                    output.addfile(metadata_info, io.BytesIO(metadata_bytes))

    atomic_replace(archive, write_archive)
    archive_digest = sha256(archive)
    checksum_line = f"{archive_digest}  {archive.name}\n".encode("ascii")

    def write_checksum(temporary_path: pathlib.Path) -> None:
        temporary_path.write_bytes(checksum_line)

    atomic_replace(checksum, write_checksum)


def validate_checksum(archive: pathlib.Path, checksum: pathlib.Path) -> None:
    archive_metadata = regular_file(archive, maximum_bytes=MAX_HANDOFF_BYTES)
    if archive_metadata.st_size <= 0:
        raise ContractError("CLI release handoff archive is empty")
    regular_file(checksum, maximum_bytes=4096)
    try:
        line = checksum.read_text(encoding="ascii").rstrip("\n")
    except UnicodeDecodeError as error:
        raise ContractError("handoff checksum must be ASCII") from error
    match = CHECKSUM_RE.fullmatch(line)
    if match is None:
        raise ContractError("handoff checksum has a non-canonical format")
    digest, name = match.groups()
    if name != archive.name:
        raise ContractError("handoff checksum names a different archive")
    if digest != sha256(archive):
        raise ContractError("handoff archive checksum mismatch")


def extract(
    *,
    archive: pathlib.Path,
    checksum: pathlib.Path,
    destination: pathlib.Path,
    version: str,
    source_repository: str,
    source_sha: str,
    rust_toolchain: str,
    source_date_epoch: int,
    workflow_run_id: int,
    workflow_run_attempt: int,
    workflow_ref: str,
    workflow_sha: str,
) -> None:
    validate_checksum(archive, checksum)
    validate_workflow_identity(workflow_run_id, workflow_run_attempt)
    validate_workflow_source(source_repository, workflow_ref, workflow_sha)
    if destination.exists() or destination.is_symlink():
        raise ContractError("handoff extraction destination must not already exist")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = pathlib.Path(
        tempfile.mkdtemp(prefix=f".{destination.name}.", dir=destination.parent)
    )
    os.chmod(temporary, 0o700)
    expected = set(expected_final_names(version)) | {HANDOFF_METADATA_NAME}
    seen: set[str] = set()
    total_size = 0
    try:
        with tarfile.open(archive, mode="r:gz") as source:
            for member in source:
                name = member.name
                if name not in expected:
                    raise ContractError(f"unexpected handoff member: {name}")
                if name in seen:
                    raise ContractError(f"duplicate handoff member: {name}")
                if pathlib.PurePosixPath(name).name != name:
                    raise ContractError(f"nested or traversing handoff member: {name}")
                if not member.isreg() or member.issym() or member.islnk():
                    raise ContractError(f"handoff member must be a regular file: {name}")
                if member.size <= 0 or member.size > maximum_size(name):
                    raise ContractError(f"handoff member has an invalid size: {name}")
                total_size += member.size
                if total_size > MAX_HANDOFF_BYTES:
                    raise ContractError("handoff archive exceeds the total extraction limit")
                input_file = source.extractfile(member)
                if input_file is None:
                    raise ContractError(f"unable to read handoff member: {name}")
                output_path = temporary / name
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                descriptor = os.open(output_path, flags, 0o600)
                try:
                    with os.fdopen(descriptor, "wb", closefd=True) as output:
                        shutil.copyfileobj(input_file, output, length=1024 * 1024)
                        output.flush()
                        os.fsync(output.fileno())
                finally:
                    input_file.close()
                regular_file(output_path, maximum_bytes=maximum_size(name))
                seen.add(name)
        if seen != expected:
            missing = ", ".join(sorted(expected - seen))
            raise ContractError(f"handoff archive is missing files: {missing}")
        actual_handoff_metadata = load_json_exact(temporary / HANDOFF_METADATA_NAME)
        expected_handoff_metadata = handoff_metadata(
            temporary,
            version=version,
            source_repository=source_repository,
            source_sha=source_sha,
            rust_toolchain=rust_toolchain,
            source_date_epoch=source_date_epoch,
            workflow_run_id=workflow_run_id,
            workflow_run_attempt=workflow_run_attempt,
            workflow_ref=workflow_ref,
            workflow_sha=workflow_sha,
        )
        if actual_handoff_metadata != expected_handoff_metadata:
            raise ContractError("handoff metadata does not match the producer run and exact assets")
        (temporary / HANDOFF_METADATA_NAME).unlink()
        verify(
            temporary,
            version=version,
            source_repository=source_repository,
            source_sha=source_sha,
            rust_toolchain=rust_toolchain,
            source_date_epoch=source_date_epoch,
        )
        os.replace(temporary, destination)
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def add_contract_arguments(command: argparse.ArgumentParser) -> None:
    command.add_argument("--version", required=True)
    command.add_argument("--source-repository", required=True)
    command.add_argument("--source-sha", required=True)
    command.add_argument("--rust-toolchain", required=True)
    command.add_argument("--source-date-epoch", required=True, type=int)
    command.add_argument("--workflow-run-id", required=True, type=int)
    command.add_argument("--workflow-run-attempt", required=True, type=int)
    command.add_argument("--workflow-ref", required=True)
    command.add_argument("--workflow-sha", required=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Create or extract a strict CLI release handoff.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("--assets-dir", required=True, type=pathlib.Path)
    create_parser.add_argument("--archive", required=True, type=pathlib.Path)
    create_parser.add_argument("--checksum", required=True, type=pathlib.Path)
    add_contract_arguments(create_parser)
    extract_parser = subparsers.add_parser("extract")
    extract_parser.add_argument("--archive", required=True, type=pathlib.Path)
    extract_parser.add_argument("--checksum", required=True, type=pathlib.Path)
    extract_parser.add_argument("--destination", required=True, type=pathlib.Path)
    add_contract_arguments(extract_parser)
    args = parser.parse_args()
    try:
        validate_version(args.version)
        validate_repository(args.source_repository)
        validate_source_sha(args.source_sha)
        validate_toolchain(args.rust_toolchain)
        validate_workflow_identity(args.workflow_run_id, args.workflow_run_attempt)
        validate_workflow_source(args.source_repository, args.workflow_ref, args.workflow_sha)
        if args.source_date_epoch <= 0:
            raise ContractError("source date epoch must be positive")
        common = {
            "archive": args.archive,
            "checksum": args.checksum,
            "version": args.version,
            "source_repository": args.source_repository,
            "source_sha": args.source_sha,
            "rust_toolchain": args.rust_toolchain,
            "source_date_epoch": args.source_date_epoch,
            "workflow_run_id": args.workflow_run_id,
            "workflow_run_attempt": args.workflow_run_attempt,
            "workflow_ref": args.workflow_ref,
            "workflow_sha": args.workflow_sha,
        }
        if args.command == "create":
            create(assets_dir=args.assets_dir, **common)
        else:
            extract(destination=args.destination, **common)
    except (ContractError, OSError, tarfile.TarError) as error:
        print(f"CLI release handoff failed: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
