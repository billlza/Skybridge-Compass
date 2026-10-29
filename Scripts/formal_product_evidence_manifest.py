#!/usr/bin/env python3
"""Build a red pre-cleanup manifest from fixed shipping-product evidence only.

No caller-supplied measurement manifest is accepted.  Every affirmative field
is emitted only after the corresponding sealed-product identity, exact-process
log, installation/launch capture, and production identity lifecycle validator
has completed.  Cleanup finalization and public acceptance stay separate.
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import tempfile
from pathlib import Path
from typing import Any, NoReturn

from extract_ios_product_release_evidence import (
    IOSProductEvidenceError,
    validate_installation_capture,
)
from extract_ios_production_identity_evidence import identity_manifest_fields
from ios_physical_release_acceptance import expected_binding
from ios_release_archive_identity import ArchiveIdentityError, load_identity
from macos_release_candidate_identity import CandidateIdentityError, load_manifest
from validate_product_release_evidence_log import (
    ProductEvidenceError,
    product_session_references,
    validate_artifact_log,
)
from validate_real_device_release_acceptance_artifact import (
    validate_production_identity_proof,
)

FORMAL_KINDS = ("connectivity", "p2p", "webrtc", "file-transfer")


class FormalManifestError(RuntimeError):
    """The fixed product evidence cannot produce a pre-cleanup candidate."""


def _fail(message: str) -> NoReturn:
    raise FormalManifestError(message)


def _validate_identity_session_binding(
    artifact_dir: Path, kind: str, identity: dict[str, Any]
) -> None:
    sessions = product_session_references(
        artifact_dir, kind, expected_suite=identity.get("expectedSuite")
    )
    if identity.get("evidenceSessionRef") not in sessions:
        _fail("production identity proof is not bound to this product session")
    if (
        identity["schemaVersion"] == 2
        and set(identity["evidenceSessionRefs"]) != sessions
    ):
        _fail("existing identity proof does not bind every exact Q product session")


def build_manifest(
    *,
    kind: str,
    artifact_dir: Path,
    archive_identity: Path,
) -> dict[str, Any]:
    if kind not in FORMAL_KINDS:
        _fail(f"unsupported formal evidence kind: {kind}")
    try:
        directory = artifact_dir.lstat()
    except OSError as exc:
        _fail(f"artifact directory is unavailable: {exc}")
    if artifact_dir.is_symlink() or not stat.S_ISDIR(directory.st_mode):
        _fail("artifact directory must be a real directory")
    try:
        archive = load_identity(archive_identity)
        archive_binding = expected_binding(archive)
        candidate = load_manifest(artifact_dir / "macos-release-candidate.json")
        validate_installation_capture(
            artifact_dir / "ios-product-installation-capture.json",
            expected_archive_binding=archive_binding,
        )
    except (
        ArchiveIdentityError,
        CandidateIdentityError,
        IOSProductEvidenceError,
        ProductEvidenceError,
    ) as exc:
        _fail(f"shipping product evidence is invalid: {exc}")

    candidate_source = candidate["source"]
    if (
        candidate_source.get("repository") != archive["sourceRepository"]
        or candidate_source.get("commit") != archive["sourceCommit"]
    ):
        _fail("Mac candidate and sealed iOS archive source identities differ")
    try:
        identity = validate_production_identity_proof(
            artifact_dir,
            expected_repository=archive["sourceRepository"],
            expected_source_sha=archive["sourceCommit"],
        )
    except SystemExit as exc:
        _fail(str(exc))
    if (
        identity["schemaVersion"] == 2
        and identity["iosReleaseArchive"] != archive_binding
    ):
        _fail("existing identity proof belongs to a different sealed iOS archive")
    try:
        validate_artifact_log(
            artifact_dir, kind, expected_suite=identity.get("expectedSuite")
        )
        _validate_identity_session_binding(artifact_dir, kind, identity)
    except ProductEvidenceError as exc:
        _fail(f"shipping product lifecycle is invalid: {exc}")

    # These fixed values are not caller assertions.  They are emitted only
    # after the validators above have established each corresponding fact.
    result: dict[str, Any] = {
        "acceptanceEligible": False,
        "cleanupComplete": False,
        "diagnosticOnly": True,
        "iosBinaryTestSurfaceDetected": False,
        "iosProductSurface": "production",
        **identity_manifest_fields(identity),
        "iosProductionIdentityLifecycleVerified": True,
        "iosProductionIdentityProof": True,
        "iosProductionProduct": True,
        "iosReleaseArchive": archive_binding,
        "iosSwiftActiveCompilationConditions": archive[
            "swiftActiveCompilationConditions"
        ],
        "identitySourceGatekeeperAccepted": True,
        "identitySourceStaplerValid": True,
        "iosTestingCompilationCondition": False,
        "labRun": False,
        "macCandidateIdentityVerified": True,
        "macDebugBuild": False,
        "macHostLaunchMode": "packaged",
        "macProductSurface": "production",
        "macRuntimeExecutable": "SkyBridgeCompassApp",
        "macTestingCompilationCondition": False,
        "preCleanupCandidate": True,
        "realDevice": True,
        "sourceCommit": archive["sourceCommit"],
        "sourceRepository": archive["sourceRepository"],
        "transport": kind,
    }
    if kind in {"p2p", "webrtc"}:
        result.update(
            {
                "noticeEvidenceSource": "normal-product-session",
                "remoteControlNoticeHumanApproval": True,
                "remoteControlNoticePanelPresented": True,
                "remoteControlNoticeProductPath": True,
            }
        )
    return result


def _atomic_new(path: Path, payload: dict[str, Any]) -> None:
    if not path.is_absolute():
        _fail("formal manifest output must be absolute")
    if path.exists() or path.is_symlink():
        _fail("formal manifest output already exists")
    parent = path.parent.resolve(strict=True)
    content = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            descriptor = -1
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_descriptor = os.open(
            parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        )
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=FORMAL_KINDS, required=True)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--archive-identity", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        payload = build_manifest(
            kind=arguments.kind,
            artifact_dir=arguments.artifact_dir,
            archive_identity=arguments.archive_identity,
        )
        _atomic_new(arguments.output, payload)
    except (FormalManifestError, OSError) as exc:
        print(f"formal product manifest rejected: {exc}", file=os.sys.stderr)
        return 1
    print(f"formal product pre-cleanup manifest written: {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
