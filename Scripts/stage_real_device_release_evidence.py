#!/usr/bin/env python3
"""Stage and verify the exact public files allowed for release evidence.

The protected real-device workflow must never upload an operator supplied
directory wholesale.  This module defines the versioned, fail-closed contract
for each of the four canonical evidence artifacts and emits a canonical file-set
manifest that is verified again after archive extraction. Its digests detect
accidental file/run mismatch; they are not a security boundary.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from macos_release_candidate_identity import (
    CandidateIdentityError,
    canonical_bytes as canonical_candidate_bytes,
    validate_manifest as validate_candidate_manifest,
)
from ios_physical_release_acceptance import (
    PhysicalAcceptanceError,
    expected_binding,
    validate_archive_binding,
)
from ios_release_archive_identity import (
    ArchiveIdentityError,
    load_identity as load_ios_archive_identity,
    validate_release_testing_ipa,
)
from validate_product_release_evidence_log import (
    ProductEvidenceError,
    validate_artifact_log as validate_product_release_evidence_log,
)
from extract_ios_product_release_evidence import (
    IOSProductEvidenceError,
    validate_installation_capture,
)
from validate_real_device_release_acceptance_artifact import (
    validate_product_only_formal_evidence,
)


SCHEMA_VERSION = 1
FILE_SET_MANIFEST = "release-evidence-file-set.json"
MAX_FILE_COUNT = 128
MAX_FILE_BYTES = 128 * 1024 * 1024
MAX_TOTAL_BYTES = 512 * 1024 * 1024


@dataclass(frozen=True)
class Contract:
    exact: frozenset[str]
    patterns: tuple[re.Pattern[str], ...]
    required_exact: frozenset[str]
    required_patterns: tuple[re.Pattern[str], ...] = ()


FORMAL_PRODUCT_FILES = frozenset(
    {
        "ios-production-identity-proof.json",
        "ios-product-installation-capture.json",
        "ios-product-session-capture.json",
        "ios-product-session.log",
        "mac-product-session-capture.json",
        "mac-product-session.log",
        "macos-release-candidate.json",
        "release-acceptance.json",
    }
)


def _patterns(*values: str) -> tuple[re.Pattern[str], ...]:
    return tuple(re.compile(value, re.ASCII) for value in values)


CONTRACTS: dict[str, Contract] = {
    kind: Contract(
        exact=FORMAL_PRODUCT_FILES,
        patterns=(),
        required_exact=FORMAL_PRODUCT_FILES,
    )
    for kind in ("connectivity", "p2p-remote", "webrtc-remote", "file-transfer")
}


class ContractError(RuntimeError):
    pass


def _fail(message: str) -> None:
    raise ContractError(message)


def _matches(contract: Contract, relative_file: str) -> bool:
    return relative_file in contract.exact or any(
        pattern.fullmatch(relative_file) for pattern in contract.patterns
    )


def _validate_root(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
    except OSError as exc:
        _fail(f"unable to inspect {label}: {path}: {exc}")
    if not stat.S_ISDIR(metadata.st_mode) or path.is_symlink():
        _fail(f"{label} must be a real directory: {path}")
    return path.resolve(strict=True)


def _read_regular_file(path: Path, relative_file: str) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        _fail(f"unable to open evidence file without following links: {relative_file}: {exc}")
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            _fail(f"evidence entry must be a single-link regular file: {relative_file}")
        if before.st_size < 1 or before.st_size > MAX_FILE_BYTES:
            _fail(
                f"evidence file size must be between 1 and {MAX_FILE_BYTES} bytes: {relative_file}"
            )
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                _fail(f"evidence file was truncated while reading: {relative_file}")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            _fail(f"evidence file grew while reading: {relative_file}")
        after = os.fstat(descriptor)
        stable_fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns")
        if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
            _fail(f"evidence file changed while reading: {relative_file}")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _collect(root: Path, contract: Contract, *, include_manifest: bool) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    total_bytes = 0
    try:
        entries = sorted(root.iterdir(), key=lambda item: item.name)
    except OSError as exc:
        _fail(f"unable to list evidence directory: {root}: {exc}")
    for entry in entries:
        relative_file = entry.name
        if relative_file in {"", ".", ".."} or "/" in relative_file or "\\" in relative_file:
            _fail(f"invalid evidence file name: {relative_file!r}")
        if relative_file == FILE_SET_MANIFEST and include_manifest:
            continue
        try:
            metadata = entry.lstat()
        except OSError as exc:
            _fail(f"unable to inspect evidence entry {relative_file}: {exc}")
        if not stat.S_ISREG(metadata.st_mode) or entry.is_symlink():
            _fail(f"nested directories, links, and special files are forbidden: {relative_file}")
        if relative_file == FILE_SET_MANIFEST:
            _fail(f"source evidence must not supply the generated file-set manifest: {relative_file}")
        if not _matches(contract, relative_file):
            _fail(f"evidence file is not in the {SCHEMA_VERSION} allowlist: {relative_file}")
        content = _read_regular_file(entry, relative_file)
        if relative_file == "macos-release-candidate.json":
            try:
                candidate = validate_candidate_manifest(json.loads(content.decode("utf-8")))
            except (CandidateIdentityError, UnicodeError, json.JSONDecodeError) as exc:
                _fail(f"invalid macOS release candidate identity: {exc}")
            if canonical_candidate_bytes(candidate) != content:
                _fail("macOS release candidate identity is not canonical JSON")
        files[relative_file] = content
        total_bytes += len(content)
        if len(files) > MAX_FILE_COUNT:
            _fail(f"evidence file count exceeds {MAX_FILE_COUNT}")
        if total_bytes > MAX_TOTAL_BYTES:
            _fail(f"evidence byte count exceeds {MAX_TOTAL_BYTES}")
    missing = sorted(contract.required_exact - files.keys())
    if missing:
        _fail(f"required evidence files are missing: {','.join(missing)}")
    for pattern in contract.required_patterns:
        if not any(pattern.fullmatch(name) for name in files):
            _fail(f"required evidence file pattern is missing: {pattern.pattern}")
    return files


def _required_ios_archive_binding(identity_path: Path, ipa_path: Path) -> dict[str, object]:
    try:
        identity = load_ios_archive_identity(identity_path)
        validate_release_testing_ipa(identity, ipa_path)
    except ArchiveIdentityError as exc:
        _fail(f"invalid sealed iOS archive or release-testing IPA: {exc}")
    return expected_binding(identity)


def _validate_ios_archive_binding(
    files: dict[str, bytes], required_binding: dict[str, object] | None
) -> dict[str, object]:
    try:
        manifest = json.loads(files["release-acceptance.json"].decode("utf-8"))
    except (KeyError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(f"release acceptance manifest is not valid UTF-8 JSON: {exc}")
    if not isinstance(manifest, dict):
        _fail("release acceptance manifest must be a JSON object")
    if manifest.get("acceptanceEligible") is not True:
        _fail("only acceptance-eligible evidence may enter formal staging")
    recorded_binding = manifest.get("iosReleaseArchive")
    try:
        validate_archive_binding(recorded_binding)
    except PhysicalAcceptanceError as exc:
        _fail(f"release evidence contains an invalid iOS archive binding: {exc}")
    if required_binding is not None and recorded_binding != required_binding:
        _fail("release evidence does not bind the exact iOS archive and IPA")
    return manifest


def _formal_product_kind(kind: str) -> str:
    return {"p2p-remote": "p2p", "webrtc-remote": "webrtc"}.get(kind, kind)


def _validate_fixed_product_artifacts(
    kind: str,
    artifact_dir: Path,
    manifest: dict[str, object],
) -> None:
    repository = manifest.get("sourceRepository")
    commit = manifest.get("sourceCommit")
    if not isinstance(repository, str) or not isinstance(commit, str):
        _fail("release manifest is missing source provenance")
    try:
        validate_product_only_formal_evidence(
            artifact_dir,
            _formal_product_kind(kind),
            manifest,
            expected_repository=repository,
            expected_source_sha=commit,
        )
    except SystemExit as exc:
        _fail(str(exc))


def _manifest(kind: str, files: dict[str, bytes]) -> bytes:
    payload = {
        "schemaVersion": SCHEMA_VERSION,
        "artifactKind": kind,
        "files": [
            {
                "relativeFile": name,
                "byteCount": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
            }
            for name, content in sorted(files.items())
        ],
    }
    return (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")


def stage(
    kind: str,
    source: Path,
    destination: Path,
    *,
    ios_archive_identity: Path | None,
    release_testing_ipa: Path | None,
) -> None:
    if ios_archive_identity is None or release_testing_ipa is None:
        _fail("initial formal staging requires the sealed iOS identity and IPA")
    contract = CONTRACTS[kind]
    source_root = _validate_root(source, "source evidence directory")
    destination_parent = destination.parent.resolve(strict=True)
    destination_resolved = destination_parent / destination.name
    if source_root == destination_resolved or source_root in destination_resolved.parents:
        _fail("destination must not be the source directory or a child of it")
    if destination.exists() or destination.is_symlink():
        _fail(f"destination must not already exist: {destination}")
    files = _collect(source_root, contract, include_manifest=False)
    manifest = _validate_ios_archive_binding(
        files,
        _required_ios_archive_binding(ios_archive_identity, release_testing_ipa),
    )
    _validate_fixed_product_artifacts(kind, source_root, manifest)
    temporary = Path(
        tempfile.mkdtemp(prefix=f".{destination.name}.", dir=os.fspath(destination_parent))
    )
    os.chmod(temporary, 0o700)
    try:
        for name, content in sorted(files.items()):
            output = temporary / name
            descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                with os.fdopen(descriptor, "wb", closefd=False) as handle:
                    handle.write(content)
                    handle.flush()
                    os.fsync(handle.fileno())
            finally:
                os.close(descriptor)
        manifest_content = _manifest(kind, files)
        manifest_path = temporary / FILE_SET_MANIFEST
        descriptor = os.open(manifest_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "wb", closefd=False) as handle:
                handle.write(manifest_content)
                handle.flush()
                os.fsync(handle.fileno())
        finally:
            os.close(descriptor)
        os.replace(temporary, destination_resolved)
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def verify(
    kind: str,
    artifact_dir: Path,
    *,
    ios_archive_identity: Path | None,
    release_testing_ipa: Path | None,
) -> None:
    contract = CONTRACTS[kind]
    root = _validate_root(artifact_dir, "staged evidence directory")
    manifest_path = root / FILE_SET_MANIFEST
    manifest_content = _read_regular_file(manifest_path, FILE_SET_MANIFEST)
    try:
        payload = json.loads(manifest_content.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(f"file-set manifest is not valid UTF-8 JSON: {exc}")
    if not isinstance(payload, dict) or payload.get("schemaVersion") != SCHEMA_VERSION:
        _fail("file-set manifest has an unsupported schemaVersion")
    if payload.get("artifactKind") != kind:
        _fail("file-set manifest artifactKind does not match the requested contract")
    manifest_files = payload.get("files")
    if not isinstance(manifest_files, list):
        _fail("file-set manifest files must be an array")
    expected: dict[str, tuple[int, str]] = {}
    for entry in manifest_files:
        if not isinstance(entry, dict) or set(entry) != {"relativeFile", "byteCount", "sha256"}:
            _fail("file-set manifest contains an invalid file entry")
        name = entry.get("relativeFile")
        byte_count = entry.get("byteCount")
        digest = entry.get("sha256")
        if (
            not isinstance(name, str)
            or name in expected
            or not isinstance(byte_count, int)
            or isinstance(byte_count, bool)
            or byte_count < 1
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest, re.ASCII) is None
        ):
            _fail("file-set manifest contains an invalid or duplicate file entry")
        expected[name] = (byte_count, digest)
    files = _collect(root, contract, include_manifest=True)
    release_manifest = _validate_ios_archive_binding(
        files,
        (
            _required_ios_archive_binding(ios_archive_identity, release_testing_ipa)
            if ios_archive_identity is not None and release_testing_ipa is not None
            else None
        ),
    )
    if set(files) != set(expected):
        unexpected = sorted(set(files) - set(expected))
        missing = sorted(set(expected) - set(files))
        _fail(
            "staged evidence file set does not match its manifest: "
            f"unexpected={','.join(unexpected) or '-'} missing={','.join(missing) or '-'}"
        )
    for name, content in files.items():
        byte_count, digest = expected[name]
        if len(content) != byte_count or hashlib.sha256(content).hexdigest() != digest:
            _fail(f"staged evidence content does not match its manifest: {name}")
    if _manifest(kind, files) != manifest_content:
        _fail("file-set manifest is not in canonical form")
    _validate_fixed_product_artifacts(kind, root, release_manifest)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", required=True, choices=sorted(CONTRACTS))
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--source", type=Path)
    mode.add_argument("--verify", dest="verify_dir", type=Path)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--ios-archive-identity", type=Path)
    parser.add_argument("--release-testing-ipa", type=Path)
    args = parser.parse_args()
    try:
        if args.source is not None:
            if args.destination is None:
                _fail("--destination is required with --source")
            if args.ios_archive_identity is None or args.release_testing_ipa is None:
                _fail(
                    "initial formal staging requires --ios-archive-identity and "
                    "--release-testing-ipa"
                )
            stage(
                args.kind,
                args.source,
                args.destination,
                ios_archive_identity=args.ios_archive_identity,
                release_testing_ipa=args.release_testing_ipa,
            )
        else:
            if args.destination is not None:
                _fail("--destination is only valid with --source")
            if (args.ios_archive_identity is None) != (args.release_testing_ipa is None):
                _fail(
                    "--ios-archive-identity and --release-testing-ipa must be supplied together"
                )
            verify(
                args.kind,
                args.verify_dir,
                ios_archive_identity=args.ios_archive_identity,
                release_testing_ipa=args.release_testing_ipa,
            )
    except (ArchiveIdentityError, ContractError) as exc:
        print(f"release evidence file-set contract rejected: {exc}", file=sys.stderr)
        return 1
    print(f"release evidence file-set contract valid: kind={args.kind}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
