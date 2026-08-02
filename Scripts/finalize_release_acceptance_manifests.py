#!/usr/bin/env python3
"""Monotonically finalize matching private/public release-acceptance manifests.

The two manifests live in different directories, so they cannot be committed as one
filesystem transaction.  Finalization therefore has one valid order: durably write
and verify the private manifest before the public manifest can become eligible.
Failures never attempt to restore older manifest bytes.
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import tempfile
from pathlib import Path
from typing import Any, Callable, NoReturn, Optional


FINALIZATION_ORDER = "private-then-public-v1"
MANIFEST_FILE_NAME = "release-acceptance.json"
MANIFEST_MODE = 0o600
DIRECTORY_MODE = 0o700
MAX_MANIFEST_BYTES = 1024 * 1024

FaultInjector = Callable[[str, Path], None]


class FinalizationError(RuntimeError):
    """The manifests could not be finalized without weakening the proof state."""


def _fail(message: str) -> NoReturn:
    raise FinalizationError(message)


def _normalized_manifest_path(path: Path) -> Path:
    normalized = path.absolute()
    if normalized.name != MANIFEST_FILE_NAME:
        _fail(f"manifest path must end with {MANIFEST_FILE_NAME}")
    return normalized


def _validate_directory_metadata(metadata: os.stat_result, path: Path) -> None:
    if not stat.S_ISDIR(metadata.st_mode):
        _fail(f"manifest parent must be a real directory: {path}")
    if metadata.st_uid != os.geteuid():
        _fail(f"manifest directory must be owned by the current effective user: {path}")
    if stat.S_IMODE(metadata.st_mode) != DIRECTORY_MODE:
        _fail(f"manifest directory mode must be 0700: {path}")


def _open_trusted_directory(path: Path) -> tuple[int, os.stat_result]:
    try:
        path_metadata = path.lstat()
    except OSError as exc:
        _fail(f"unable to inspect manifest directory {path}: {exc}")
    _validate_directory_metadata(path_metadata, path)

    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        _fail(f"unable to open manifest directory without following links: {path}: {exc}")
    try:
        opened_metadata = os.fstat(descriptor)
    except OSError as exc:
        os.close(descriptor)
        _fail(f"unable to inspect opened manifest directory {path}: {exc}")
    try:
        _validate_directory_metadata(opened_metadata, path)
    except FinalizationError:
        os.close(descriptor)
        raise
    if (
        opened_metadata.st_dev != path_metadata.st_dev
        or opened_metadata.st_ino != path_metadata.st_ino
    ):
        os.close(descriptor)
        _fail(f"manifest directory changed while it was being opened: {path}")
    return descriptor, opened_metadata


def _validate_manifest_metadata(metadata: os.stat_result, path: Path) -> None:
    if not stat.S_ISREG(metadata.st_mode):
        _fail(f"manifest must be a regular file: {path}")
    if metadata.st_uid != os.geteuid():
        _fail(f"manifest must be owned by the current effective user: {path}")
    if metadata.st_nlink != 1:
        _fail(f"manifest must have exactly one filesystem link: {path}")
    if stat.S_IMODE(metadata.st_mode) != MANIFEST_MODE:
        _fail(f"manifest mode must be 0600: {path}")
    if metadata.st_size <= 0 or metadata.st_size > MAX_MANIFEST_BYTES:
        _fail(
            f"manifest size must be between 1 and {MAX_MANIFEST_BYTES} bytes: {path}"
        )


def _read_manifest(path: Path) -> tuple[bytes, dict[str, Any]]:
    directory_descriptor, _ = _open_trusted_directory(path.parent)
    descriptor: Optional[int] = None
    try:
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path.name, flags, dir_fd=directory_descriptor)
        except OSError as exc:
            _fail(f"unable to open manifest without following links: {path}: {exc}")

        initial_metadata = os.fstat(descriptor)
        _validate_manifest_metadata(initial_metadata, path)
        chunks: list[bytes] = []
        remaining = MAX_MANIFEST_BYTES + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        final_metadata = os.fstat(descriptor)
        path_metadata = os.stat(path.name, dir_fd=directory_descriptor, follow_symlinks=False)
        if (
            final_metadata.st_dev != initial_metadata.st_dev
            or final_metadata.st_ino != initial_metadata.st_ino
            or final_metadata.st_size != initial_metadata.st_size
            or path_metadata.st_dev != final_metadata.st_dev
            or path_metadata.st_ino != final_metadata.st_ino
        ):
            _fail(f"manifest changed while it was being read: {path}")
        _validate_manifest_metadata(final_metadata, path)
        if len(raw) != final_metadata.st_size or len(raw) > MAX_MANIFEST_BYTES:
            _fail(f"manifest read did not match its bounded file size: {path}")
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(directory_descriptor)

    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        _fail(f"manifest is not valid UTF-8 JSON: {path}: {exc}")
    if not isinstance(payload, dict):
        _fail(f"manifest must contain a JSON object: {path}")
    return raw, payload


def _serialized(payload: dict[str, Any]) -> bytes:
    content = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    if len(content) > MAX_MANIFEST_BYTES:
        _fail("final release acceptance manifest exceeds the size limit")
    return content


def _inject(
    fault_injector: Optional[FaultInjector],
    phase: str,
    path: Path,
) -> None:
    if fault_injector is not None:
        try:
            fault_injector(phase, path)
        except FinalizationError:
            raise
        except OSError as exc:
            _fail(f"fault at {phase} prevented manifest finalization: {path}: {exc}")


def _atomic_replace(
    path: Path,
    content: bytes,
    *,
    phase_prefix: str,
    fault_injector: Optional[FaultInjector],
) -> None:
    directory_descriptor, _ = _open_trusted_directory(path.parent)
    temporary_path: Optional[Path] = None
    descriptor: Optional[int] = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.{phase_prefix}.",
            dir=path.parent,
        )
        temporary_path = Path(temporary_name)
        os.fchmod(descriptor, MANIFEST_MODE)
        temporary_metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(temporary_metadata.st_mode)
            or temporary_metadata.st_uid != os.geteuid()
            or temporary_metadata.st_nlink != 1
            or stat.S_IMODE(temporary_metadata.st_mode) != MANIFEST_MODE
        ):
            _fail(f"temporary manifest metadata is unsafe: {path}")

        written = 0
        while written < len(content):
            count = os.write(descriptor, content[written:])
            if count <= 0:
                _fail(f"unable to write complete temporary manifest: {path}")
            written += count
        if os.fstat(descriptor).st_size != len(content):
            _fail(f"temporary manifest size does not match serialized payload: {path}")
        os.fsync(descriptor)
        _inject(fault_injector, f"before-{phase_prefix}-replace", path)
        os.replace(
            temporary_path.name,
            path.name,
            src_dir_fd=directory_descriptor,
            dst_dir_fd=directory_descriptor,
        )
        temporary_path = None
        os.fsync(directory_descriptor)
    except OSError as exc:
        _fail(f"atomic {phase_prefix} manifest write failed: {path}: {exc}")
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass
        os.close(directory_descriptor)


def _validate_pre_cleanup_payload(payload: dict[str, Any]) -> bool:
    candidate = payload.get("preCleanupCandidate")
    if type(candidate) is not bool:
        _fail("preCleanupCandidate must be a boolean")
    if payload.get("cleanupComplete") is not False:
        _fail("pre-cleanup manifest must have cleanupComplete=false")
    if payload.get("acceptanceEligible") is not False:
        _fail("pre-cleanup manifest must not be acceptance eligible")
    if payload.get("diagnosticOnly") is not True:
        _fail("pre-cleanup manifest must be diagnostic-only")
    if "finalizationOrder" in payload:
        _fail("pre-cleanup manifest must not claim a finalization order")
    if candidate:
        if payload.get("transport") == "p2p":
            if payload.get("macHostLaunchMode") != "packaged":
                _fail("P2P acceptance candidate macHostLaunchMode must be packaged")
            if payload.get("macHostDiagnosticOnly") is not False:
                _fail("P2P acceptance candidate mac host must not be diagnostic-only")
            if payload.get("identitySourceStaplerValid") is not True:
                _fail("P2P acceptance candidate must prove a stapled macOS host identity source")
            if payload.get("identitySourceGatekeeperAccepted") is not True:
                _fail("P2P acceptance candidate must prove Gatekeeper acceptance for the macOS host identity source")
        if payload.get("iosProductSurface") != "production":
            _fail("acceptance candidate iosProductSurface must be production")
        if payload.get("iosTestingCompilationCondition") is not False:
            _fail("acceptance candidate must not use a testing compilation condition")
        if payload.get("iosBinaryTestSurfaceDetected") is not False:
            _fail("acceptance candidate must not contain a binary test surface")
        if payload.get("iosProductionProduct") is not True:
            _fail("acceptance candidate must prove a production iOS product")
        if payload.get("iosProductionIdentityAlgorithm") != "mldsa87":
            _fail("acceptance candidate must prove ML-DSA-87 identity")
        if payload.get("iosProductionIdentityProtection") != "secureEnclaveRequired":
            _fail("acceptance candidate must require Secure Enclave identity protection")
        if payload.get("iosProductionIdentityLifecycleVerified") is not True:
            _fail("acceptance candidate must prove the production identity lifecycle")
        if payload.get("iosProductionIdentityProof") is not True:
            _fail("acceptance candidate must include production identity proof")
        conditions = payload.get("iosSwiftActiveCompilationConditions")
        if (
            not isinstance(conditions, list)
            or "HAS_APPLE_PQC_SDK" not in conditions
            or "SKYBRIDGE_TESTING" in conditions
            or "DEBUG" in conditions
        ):
            _fail("acceptance candidate compilation conditions are not production-safe")
    return candidate


def _verify_final_manifest(
    path: Path,
    expected_content: bytes,
    expected_payload: dict[str, Any],
) -> None:
    actual_content, actual_payload = _read_manifest(path)
    if actual_content != expected_content or actual_payload != expected_payload:
        _fail(f"finalized manifest read-back verification failed: {path}")


def finalize_release_acceptance_manifests(
    private_manifest: Path,
    public_manifest: Path,
    *,
    fault_injector: Optional[FaultInjector] = None,
) -> None:
    """Finalize two manifests in a monotonic, private-first sequence.

    ``fault_injector`` is an internal deterministic test seam.  Production CLI calls
    never provide it; injected faults can only turn finalization red.
    """

    private_path = _normalized_manifest_path(private_manifest)
    public_path = _normalized_manifest_path(public_manifest)
    if private_path == public_path:
        _fail("private and public manifests must be different files")

    private_directory_descriptor, private_directory_metadata = _open_trusted_directory(
        private_path.parent
    )
    os.close(private_directory_descriptor)
    public_directory_descriptor, public_directory_metadata = _open_trusted_directory(
        public_path.parent
    )
    os.close(public_directory_descriptor)
    if (
        private_directory_metadata.st_dev == public_directory_metadata.st_dev
        and private_directory_metadata.st_ino == public_directory_metadata.st_ino
    ):
        _fail("private and public manifests must be in different directories")

    _, private_payload = _read_manifest(private_path)
    _, public_payload = _read_manifest(public_path)
    if private_payload != public_payload:
        _fail("private/public pre-cleanup acceptance manifests differ")
    candidate = _validate_pre_cleanup_payload(private_payload)
    _validate_pre_cleanup_payload(public_payload)

    final_payload = dict(private_payload)
    final_payload["cleanupComplete"] = True
    final_payload["acceptanceEligible"] = candidate
    final_payload["diagnosticOnly"] = not candidate
    final_payload["finalizationOrder"] = FINALIZATION_ORDER
    final_content = _serialized(final_payload)

    _atomic_replace(
        private_path,
        final_content,
        phase_prefix="private-final",
        fault_injector=fault_injector,
    )
    _inject(fault_injector, "before-private-verify", private_path)
    _verify_final_manifest(private_path, final_content, final_payload)
    _inject(fault_injector, "after-private-verify", private_path)

    _atomic_replace(
        public_path,
        final_content,
        phase_prefix="public-final",
        fault_injector=fault_injector,
    )
    _inject(fault_injector, "before-public-verify", public_path)
    _verify_final_manifest(public_path, final_content, final_payload)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--private-manifest", required=True, type=Path)
    parser.add_argument("--public-manifest", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    try:
        finalize_release_acceptance_manifests(
            args.private_manifest,
            args.public_manifest,
        )
    except (FinalizationError, OSError) as exc:
        raise SystemExit(f"release acceptance manifest finalization failed: {exc}") from exc


if __name__ == "__main__":
    main()
