#!/usr/bin/env python3
"""Stage and verify the exact public files allowed for release evidence.

The protected real-device workflow must never upload an operator supplied
directory wholesale.  This module defines the versioned, fail-closed contract
for each of the seven evidence artifacts and emits a content-addressed file-set
manifest that is verified again after archive extraction.
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


COMMON_IDENTITY_FILES = frozenset(
    {
        "ios-production-identity-proof.json",
        "release-acceptance.json",
    }
)


def _patterns(*values: str) -> tuple[re.Pattern[str], ...]:
    return tuple(re.compile(value, re.ASCII) for value in values)


P2P_REMOTE_FILES = COMMON_IDENTITY_FILES | frozenset(
    {
        "device-info.txt",
        "ios-build.log",
        "ios-console.stderr.log",
        "ios-launch.json",
        "ios-processes.json",
        "ios-processes.log",
        "ios-processes.stderr.log",
        "ios-product-proof.json",
        "ios.pqc.json",
        "ipad-authenticated-forward-port-probe.stderr.log",
        "ipad-authenticated-forward-route.stderr.log",
        "ipad-control-port-probe.stderr.log",
        "mac-control-port-probe.stderr.log",
        "mac-online-ipad-build.log",
        "mac-online-ipad-open.stderr.log",
        "mac-online-ipad.app.stderr.log",
        "mac-online-ipad.app.stdout.log",
        "mac-online-ipad.status.log",
        "mac-online-ipad.stderr.log",
        "mac-online-ipad.stdout.log",
        "mac-remote-port-probe.stderr.log",
        "mac-smoke-source.stdout.log",
        "mac.pqc.json",
        "mac.status.log",
        "mac.stdout.log",
        "macos-build.log",
        "p2p-approval-proof.json",
    }
)

P2P_DYNAMIC_PATTERNS = _patterns(
    r"ios-p2p-remote-(?!.*\.(?:app-cache|console|listener)\.status\.log$)[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.status\.log",
    r"ios-p2p-remote-[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.(?:app-cache|console|listener)\.status\.log",
    r"ios-p2p-remote-[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.trace\.log",
    r"ios-copy-(?:listener-status|pqc-report|status|trace)\.(?:json|log|stderr\.log|stdout\.log)",
)

WEBRTC_REMOTE_FILES = COMMON_IDENTITY_FILES | frozenset(
    {
        "device-info.json",
        "ios-build.log",
        "ios-launch.json",
        "ios-product-verification.json",
        "mac.pqc.json",
        "mac.status.log",
        "mac.stdout.log",
        "macos-build.log",
        "media-relay-preflight.log",
        "product-path-proof.json",
        "webrtc_media_doctor.json",
        "webrtc_media_doctor.stderr.log",
    }
)

WEBRTC_DYNAMIC_PATTERNS = _patterns(
    r"ios-real-webrtc-[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.status\.log",
    r"ios-real-webrtc-[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.status\.log\.trace\.log",
    r"ios-real-webrtc-[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.status\.log\.webrtc-media\.jsonl",
    r"webrtc-media-[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.jsonl",
)

FILE_TRANSFER_FILES = COMMON_IDENTITY_FILES | frozenset(
    {
        "device-info.json",
        "device-info.txt",
        "ios-build.log",
        "ios-launch.json",
        "mac.pqc.json",
        "mac.status.log",
        "mac.stderr.log",
        "mac.stdout.log",
        "macos-build.log",
        "macos-host-codesign.log",
        "macos-release-readiness.log",
    }
)

FILE_TRANSFER_PATTERNS = _patterns(
    r"ios-real-device-[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.status\.log",
    r"mac-host-[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(?:sample\.txt|system\.log)",
)

LOCAL_WEBRTC_NOTICE_FILES = frozenset(
    {
        "ios-build.log",
        "macos-build.log",
        "signaling.log",
    }
)

LOCAL_WEBRTC_NOTICE_PATTERNS = _patterns(
    r"ios_round_[1-9][0-9]*\.(?:pqc\.json|preflight\.status\.log|preflight\.status\.log\.trace\.log|preflight\.stderr\.log|preflight\.stdout\.log|status\.log|status\.log\.trace\.log|status\.log\.webrtc-media\.jsonl|stderr\.log|stdout\.log)",
    r"mac_round_[1-9][0-9]*\.(?:code|pqc\.json|status\.log|stdout\.log)",
    r"webrtc-media-[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.jsonl",
    r"webrtc_media_doctor_round_[1-9][0-9]*\.(?:json|stderr\.log)",
)


CONTRACTS: dict[str, Contract] = {
    "connectivity": Contract(
        exact=COMMON_IDENTITY_FILES | frozenset({"ios.status.log", "mac.status.log"}),
        patterns=(),
        required_exact=COMMON_IDENTITY_FILES | frozenset({"ios.status.log", "mac.status.log"}),
    ),
    "p2p-remote": Contract(
        exact=P2P_REMOTE_FILES,
        patterns=P2P_DYNAMIC_PATTERNS,
        required_exact=COMMON_IDENTITY_FILES
        | frozenset(
            {
                "ios-product-proof.json",
                "mac-online-ipad.status.log",
                "mac.status.log",
                "p2p-approval-proof.json",
            }
        ),
        required_patterns=_patterns(
            r"ios-p2p-remote-(?!.*\.(?:app-cache|console|listener)\.status\.log$)[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.status\.log"
        ),
    ),
    "webrtc-remote": Contract(
        exact=WEBRTC_REMOTE_FILES,
        patterns=WEBRTC_DYNAMIC_PATTERNS,
        required_exact=COMMON_IDENTITY_FILES
        | frozenset(
            {
                "mac.status.log",
                "media-relay-preflight.log",
                "product-path-proof.json",
                "webrtc_media_doctor.json",
            }
        ),
        required_patterns=_patterns(
            r"ios-real-webrtc-[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.status\.log",
            r"ios-real-webrtc-[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.status\.log\.trace\.log",
        ),
    ),
    "file-transfer": Contract(
        exact=FILE_TRANSFER_FILES,
        patterns=FILE_TRANSFER_PATTERNS,
        required_exact=COMMON_IDENTITY_FILES | frozenset({"mac.status.log"}),
        required_patterns=_patterns(
            r"ios-real-device-[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.status\.log"
        ),
    ),
    "p2p-notice": Contract(
        exact=P2P_REMOTE_FILES,
        patterns=P2P_DYNAMIC_PATTERNS,
        required_exact=COMMON_IDENTITY_FILES
        | frozenset({"ios-product-proof.json", "mac.status.log", "p2p-approval-proof.json"}),
    ),
    "webrtc-notice": Contract(
        exact=LOCAL_WEBRTC_NOTICE_FILES,
        patterns=LOCAL_WEBRTC_NOTICE_PATTERNS,
        required_exact=frozenset({"signaling.log"}),
        required_patterns=_patterns(r"mac_round_[1-9][0-9]*\.status\.log"),
    ),
    "notice-panel": Contract(
        exact=frozenset(
            {
                "panel_probe.build.log",
                "panel_probe.status.log",
                "panel_probe.stdout.log",
            }
        ),
        patterns=(),
        required_exact=frozenset(
            {
                "panel_probe.build.log",
                "panel_probe.status.log",
                "panel_probe.stdout.log",
            }
        ),
    ),
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


def stage(kind: str, source: Path, destination: Path) -> None:
    contract = CONTRACTS[kind]
    source_root = _validate_root(source, "source evidence directory")
    destination_parent = destination.parent.resolve(strict=True)
    destination_resolved = destination_parent / destination.name
    if source_root == destination_resolved or source_root in destination_resolved.parents:
        _fail("destination must not be the source directory or a child of it")
    if destination.exists() or destination.is_symlink():
        _fail(f"destination must not already exist: {destination}")
    files = _collect(source_root, contract, include_manifest=False)
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


def verify(kind: str, artifact_dir: Path) -> None:
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", required=True, choices=sorted(CONTRACTS))
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--source", type=Path)
    mode.add_argument("--verify", dest="verify_dir", type=Path)
    parser.add_argument("--destination", type=Path)
    args = parser.parse_args()
    try:
        if args.source is not None:
            if args.destination is None:
                _fail("--destination is required with --source")
            stage(args.kind, args.source, args.destination)
        else:
            if args.destination is not None:
                _fail("--destination is only valid with --source")
            verify(args.kind, args.verify_dir)
    except ContractError as exc:
        print(f"release evidence file-set contract rejected: {exc}", file=sys.stderr)
        return 1
    print(f"release evidence file-set contract valid: kind={args.kind}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
