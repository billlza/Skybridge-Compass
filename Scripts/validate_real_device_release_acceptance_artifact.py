#!/usr/bin/env python3
"""Validate fixed product-only Apple physical release evidence."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
from pathlib import Path
from typing import Any, NoReturn

from extract_ios_product_release_evidence import (
    IOSProductEvidenceError,
    validate_installation_capture,
)
from extract_ios_production_identity_evidence import (
    ProductionIdentityEvidenceError,
    validate_public_proof,
)
from ios_physical_release_acceptance import expected_binding
from ios_release_archive_identity import (
    ArchiveIdentityError,
    load_identity as load_ios_archive_identity,
    validate_release_testing_ipa,
)
from macos_release_candidate_identity import CandidateIdentityError, load_manifest
from validate_product_release_evidence_log import (
    IOS_LOG_FILE,
    IOS_PRODUCT,
    MAC_LOG_FILE,
    MAC_PRODUCT,
    ProductEvidenceError,
    parse_canonical_log,
    validate_artifact_log,
)


MAX_JSON_BYTES = 2 * 1024 * 1024
FINALIZATION_ORDER = "private-then-public-v1"
RELEASE_MANIFEST_MODE = 0o600
SOURCE_REPOSITORY_PATTERN = re.compile(
    r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z", re.ASCII
)
SOURCE_COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}\Z", re.ASCII)
FORMAL_KINDS = ("connectivity", "file-transfer", "p2p", "webrtc")
BASE_MANIFEST_KEYS = {
    "acceptanceEligible",
    "cleanupComplete",
    "diagnosticOnly",
    "finalizationOrder",
    "iosBinaryTestSurfaceDetected",
    "iosProductSurface",
    "iosProductionIdentityAlgorithm",
    "iosProductionIdentityLifecycleVerified",
    "iosProductionIdentityProof",
    "iosProductionIdentityProtection",
    "iosProductionProduct",
    "iosReleaseArchive",
    "iosSwiftActiveCompilationConditions",
    "identitySourceGatekeeperAccepted",
    "identitySourceStaplerValid",
    "iosTestingCompilationCondition",
    "labRun",
    "macCandidateIdentityVerified",
    "macDebugBuild",
    "macHostLaunchMode",
    "macProductSurface",
    "macRuntimeExecutable",
    "macTestingCompilationCondition",
    "preCleanupCandidate",
    "realDevice",
    "schemaVersion",
    "sourceCommit",
    "sourceRepository",
    "transport",
}
REMOTE_NOTICE_KEYS = {
    "noticeEvidenceSource",
    "remoteControlNoticeHumanApproval",
    "remoteControlNoticePanelPresented",
    "remoteControlNoticeProductPath",
}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"release acceptance artifact rejected: {message}")


def _read_regular_json(
    path: Path,
    label: str,
    *,
    require_manifest_metadata: bool = False,
) -> dict[str, Any]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        fail(f"unable to open {label} without following links: {exc}")
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size < 1
            or before.st_size > MAX_JSON_BYTES
        ):
            fail(f"{label} must be a bounded single-link regular file")
        if require_manifest_metadata and (
            before.st_uid != os.geteuid()
            or stat.S_IMODE(before.st_mode) != RELEASE_MANIFEST_MODE
        ):
            fail(f"{label} must be current-user mode 0600")
        content = bytearray()
        while len(content) < before.st_size:
            chunk = os.read(descriptor, before.st_size - len(content))
            if not chunk:
                fail(f"{label} was truncated while reading")
            content.extend(chunk)
        after = os.fstat(descriptor)
        stable = (
            "st_dev", "st_ino", "st_mode", "st_uid", "st_nlink", "st_size", "st_mtime_ns"
        )
        if os.read(descriptor, 1) or any(
            getattr(before, field) != getattr(after, field) for field in stable
        ):
            fail(f"{label} changed while reading")
    finally:
        os.close(descriptor)
    try:
        payload = json.loads(bytes(content).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"{label} is invalid UTF-8 JSON: {exc}")
    if not isinstance(payload, dict):
        fail(f"{label} must be a JSON object")
    return payload


def _require_source_repository(value: object, label: str) -> str:
    if (
        not isinstance(value, str)
        or SOURCE_REPOSITORY_PATTERN.fullmatch(value) is None
        or any(part in {"", ".", ".."} for part in value.split("/"))
    ):
        fail(f"{label} must be an owner/repository identifier")
    return value


def _require_source_commit(value: object, label: str) -> str:
    if not isinstance(value, str) or SOURCE_COMMIT_PATTERN.fullmatch(value) is None:
        fail(f"{label} must be a full lowercase Git revision")
    return value


def _validate_manifest(payload: dict[str, Any], kind: str) -> tuple[str, str]:
    expected_keys = BASE_MANIFEST_KEYS | (
        REMOTE_NOTICE_KEYS if kind in {"p2p", "webrtc"} else set()
    )
    if set(payload) != expected_keys:
        fail("release manifest does not use the exact product-only schema")
    # Checked by name so a missing or unknown finalization order is reported as
    # exactly that, not as a generic value mismatch.
    if payload.get("finalizationOrder") != FINALIZATION_ORDER:
        fail("release manifest finalization order is missing or unknown")
    if payload.get("macHostLaunchMode") != "packaged":
        fail("release manifest requires the formal packaged Mac host launch mode")
    if payload.get("identitySourceStaplerValid") is not True:
        fail("release manifest requires stapler proof for the host identity source")
    if payload.get("identitySourceGatekeeperAccepted") is not True:
        fail("release manifest requires Gatekeeper acceptance for the host identity source")
    exact_values: dict[str, object] = {
        "acceptanceEligible": True,
        "cleanupComplete": True,
        "diagnosticOnly": False,
        "finalizationOrder": FINALIZATION_ORDER,
        "iosBinaryTestSurfaceDetected": False,
        "iosProductSurface": "production",
        "iosProductionIdentityAlgorithm": "mldsa87",
        "iosProductionIdentityLifecycleVerified": True,
        "iosProductionIdentityProof": True,
        "iosProductionIdentityProtection": "secureEnclaveRequired",
        "iosProductionProduct": True,
        "identitySourceGatekeeperAccepted": True,
        "identitySourceStaplerValid": True,
        "iosTestingCompilationCondition": False,
        "labRun": False,
        "macCandidateIdentityVerified": True,
        "macDebugBuild": False,
        "macProductSurface": "production",
        "macRuntimeExecutable": "SkyBridgeCompassApp",
        "macTestingCompilationCondition": False,
        "preCleanupCandidate": True,
        "realDevice": True,
        "schemaVersion": 1,
        "transport": kind,
    }
    if kind in {"p2p", "webrtc"}:
        exact_values.update(
            {
                "noticeEvidenceSource": "normal-product-session",
                "remoteControlNoticeHumanApproval": True,
                "remoteControlNoticePanelPresented": True,
                "remoteControlNoticeProductPath": True,
            }
        )
    for key, expected in exact_values.items():
        if payload.get(key) != expected or type(payload.get(key)) is not type(expected):
            fail(f"release manifest {key} mismatch")
    conditions = payload.get("iosSwiftActiveCompilationConditions")
    if (
        not isinstance(conditions, list)
        or conditions != sorted(set(conditions))
        or "HAS_APPLE_PQC_SDK" not in conditions
        or any(
            not isinstance(value, str)
            or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", value, re.ASCII) is None
            for value in conditions
        )
        or {"DEBUG", "SKYBRIDGE_TESTING"}.intersection(conditions)
    ):
        fail("release manifest compilation conditions are not production-safe")
    repository = _require_source_repository(
        payload.get("sourceRepository"), "release manifest sourceRepository"
    )
    commit = _require_source_commit(
        payload.get("sourceCommit"), "release manifest sourceCommit"
    )
    return repository, commit


def validate_macos_candidate_binding(
    artifact_dir: Path,
    expected_repository: str,
    expected_source_sha: str,
    manifest: dict[str, Any] | None = None,
    *,
    require_remote_control_notice: bool = False,
) -> None:
    try:
        candidate = load_manifest(artifact_dir / "macos-release-candidate.json")
    except CandidateIdentityError as exc:
        fail(f"invalid macOS release candidate identity: {exc}")
    source = candidate["source"]
    if (
        source.get("repository") != expected_repository
        or source.get("commit") != expected_source_sha
    ):
        fail("macOS candidate does not match the expected release source")
    if manifest is not None and (
        manifest.get("sourceRepository") != expected_repository
        or manifest.get("sourceCommit") != expected_source_sha
    ):
        fail("release manifest source does not match the macOS candidate")
    if require_remote_control_notice and manifest is not None:
        if any(manifest.get(key) is not True for key in (
            "remoteControlNoticeProductPath",
            "remoteControlNoticeHumanApproval",
            "remoteControlNoticePanelPresented",
        )):
            fail("remote-control evidence lacks the validated normal product notice")


# The only identity algorithm and key-protection class a release-acceptance
# proof may claim. Asserted here in the validator (in addition to the exact
# schema check in the extractor) so the release lane's own audit can grep the
# requirement at its enforcement site.
REQUIRED_IDENTITY_ALGORITHM = "mldsa87"
REQUIRED_IDENTITY_PROTECTION = "secureEnclaveRequired"


def validate_production_identity_proof(
    artifact_dir: Path,
    *,
    expected_repository: str,
    expected_source_sha: str,
    manifest: dict[str, Any] | None = None,
) -> dict[str, Any]:
    try:
        proof = validate_public_proof(
            artifact_dir / "ios-production-identity-proof.json"
        )
    except ProductionIdentityEvidenceError as exc:
        fail(f"invalid iOS production identity proof: {exc}")
    if proof.get("algorithm") != REQUIRED_IDENTITY_ALGORITHM:
        fail("iOS production identity proof does not use the required identity algorithm")
    if proof.get("protection") != REQUIRED_IDENTITY_PROTECTION:
        fail("iOS production identity proof does not use the required key protection")
    if proof.get("handshakePersistenceVerified") is not True:
        fail("iOS production identity proof lacks verified handshake persistence")
    if proof.get("currentPathAuthorityVerified") is not True:
        fail("iOS production identity proof lacks verified current-path authority")
    if (
        proof.get("sourceRepository") != expected_repository
        or proof.get("sourceCommit") != expected_source_sha
    ):
        fail("iOS production identity proof source does not match the release source")
    if manifest is not None and (
        proof.get("swiftActiveCompilationConditions")
        != manifest.get("iosSwiftActiveCompilationConditions")
    ):
        fail("identity proof compilation conditions do not match the release manifest")
    return proof


def _product_session_references(artifact_dir: Path, kind: str) -> set[str]:
    references: list[set[str]] = []
    event_name = "connectivityEndpoint" if kind == "connectivity" else "releaseSessionOwner"
    for file_name, owner in ((MAC_LOG_FILE, MAC_PRODUCT), (IOS_LOG_FILE, IOS_PRODUCT)):
        events = parse_canonical_log(artifact_dir / file_name, expected_owner=owner)
        references.append(
            {event.fields["session_ref"] for event in events if event.name == event_name}
        )
    if not references[0] or references[0] != references[1]:
        fail("Mac and iOS product session references do not match")
    return references[0]


def validate_product_only_formal_evidence(
    artifact_dir: Path,
    kind: str,
    manifest: dict[str, Any],
    *,
    expected_repository: str,
    expected_source_sha: str,
) -> None:
    validate_macos_candidate_binding(
        artifact_dir,
        expected_repository,
        expected_source_sha,
        manifest,
        require_remote_control_notice=kind in {"p2p", "webrtc"},
    )
    proof = validate_production_identity_proof(
        artifact_dir,
        expected_repository=expected_repository,
        expected_source_sha=expected_source_sha,
        manifest=manifest,
    )
    try:
        validate_installation_capture(
            artifact_dir / "ios-product-installation-capture.json",
            expected_archive_binding=manifest.get("iosReleaseArchive"),
        )
        validate_artifact_log(artifact_dir, kind)
        sessions = _product_session_references(artifact_dir, kind)
    except (IOSProductEvidenceError, ProductEvidenceError, OSError) as exc:
        fail(f"invalid fixed shipping-product evidence: {exc}")
    if proof.get("evidenceSessionRef") not in sessions:
        fail("production identity proof is not bound to this exact product session")


def validate_ios_release_archive_binding(
    manifest: dict[str, Any],
    archive_identity: Path,
    release_testing_ipa: Path,
) -> None:
    """Require the release manifest to bind the exact sealed archive and IPA.

    Public entry point for the same-archive release transaction: the manifest's
    `iosReleaseArchive` block must equal the binding derived from the sealed
    archive identity, and the release-testing IPA must match that identity.
    Fails closed via SystemExit on any deviation.
    """
    _validate_archive_inputs(manifest, archive_identity, release_testing_ipa)


def _validate_archive_inputs(
    manifest: dict[str, Any],
    archive_identity: Path,
    release_testing_ipa: Path,
) -> None:
    try:
        identity = load_ios_archive_identity(archive_identity)
        validate_release_testing_ipa(identity, release_testing_ipa)
    except ArchiveIdentityError as exc:
        fail(f"invalid sealed iOS archive or release-testing IPA: {exc}")
    if manifest.get("iosReleaseArchive") != expected_binding(identity):
        fail("release manifest does not bind the exact iOS archive and IPA")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--kind",
        choices=("connectivity", "file-transfer", "p2p", "webrtc", "production-identity"),
        required=True,
    )
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--expected-source-repository", required=True)
    parser.add_argument("--expected-source-sha", required=True)
    parser.add_argument("--ios-archive-identity", type=Path)
    parser.add_argument("--release-testing-ipa", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    artifact_dir: Path = args.artifact_dir
    try:
        metadata = artifact_dir.lstat()
    except OSError as exc:
        fail(f"artifact directory is unavailable: {exc}")
    if artifact_dir.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
        fail("artifact directory must be a real directory")
    repository = _require_source_repository(
        args.expected_source_repository, "--expected-source-repository"
    )
    commit = _require_source_commit(args.expected_source_sha, "--expected-source-sha")

    if args.kind == "production-identity":
        validate_macos_candidate_binding(artifact_dir, repository, commit)
        validate_production_identity_proof(
            artifact_dir,
            expected_repository=repository,
            expected_source_sha=commit,
        )
        print("release production identity artifact valid")
        return

    manifest = _read_regular_json(
        artifact_dir / "release-acceptance.json",
        "release acceptance manifest",
        require_manifest_metadata=True,
    )
    manifest_repository, manifest_commit = _validate_manifest(manifest, args.kind)
    if manifest_repository != repository or manifest_commit != commit:
        fail("release manifest does not match the expected release source")
    if (args.ios_archive_identity is None) != (args.release_testing_ipa is None):
        fail("--ios-archive-identity and --release-testing-ipa must be supplied together")
    if args.ios_archive_identity is not None and args.release_testing_ipa is not None:
        _validate_archive_inputs(
            manifest, args.ios_archive_identity, args.release_testing_ipa
        )
    validate_product_only_formal_evidence(
        artifact_dir,
        args.kind,
        manifest,
        expected_repository=repository,
        expected_source_sha=commit,
    )
    print(f"release acceptance artifact valid: kind={args.kind}")


if __name__ == "__main__":
    main()
