#!/usr/bin/env python3
"""Finalize or verify physical evidence bound to one iOS release archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from extract_ios_ipa import IPAValidationError, extract_ios_app_from_ipa
from ios_release_archive_identity import (
    ArchiveIdentityError,
    IDENTITY_PURPOSE,
    load_identity,
    validate_release_testing_ipa,
)


SCHEMA_VERSION = 1
MAX_MANIFEST_BYTES = 1024 * 1024
DIGEST_PATTERN = re.compile(r"[0-9a-f]{64}")
EVIDENCE_CONTRACT: tuple[tuple[str, str], ...] = (
    ("connectivity", "real-device-connectivity-matrix-public-redacted"),
    ("p2p", "real-device-p2p-remote-smoke-public-redacted"),
    ("webrtc", "real-device-webrtc-smoke-public-redacted"),
    ("file-transfer", "real-device-file-transfer-smoke-public-redacted"),
)


class PhysicalAcceptanceError(ValueError):
    pass


def _fail(message: str) -> "None":
    raise PhysicalAcceptanceError(message)


def _real_directory(path: Path, label: str) -> Path:
    if not path.is_absolute():
        _fail(f"{label} must be absolute")
    try:
        metadata = path.lstat()
    except OSError as error:
        _fail(f"unable to inspect {label}: {error}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        _fail(f"{label} must be a real directory")
    return path.resolve(strict=True)


def _regular_file(path: Path, label: str) -> Path:
    if not path.is_absolute():
        _fail(f"{label} must be absolute")
    try:
        metadata = path.lstat()
    except OSError as error:
        _fail(f"unable to inspect {label}: {error}")
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
    ):
        _fail(f"{label} must be a single-link regular file")
    if metadata.st_size < 1 or metadata.st_size > MAX_MANIFEST_BYTES:
        _fail(f"{label} size is outside the accepted bound")
    return path.resolve(strict=True)


def _read_json(path: Path, label: str) -> dict[str, Any]:
    path = _regular_file(path, label)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        _fail(f"{label} is not valid UTF-8 JSON: {error}")
    if not isinstance(payload, dict):
        _fail(f"{label} must be a JSON object")
    return payload


def _manifest_sha256(path: Path) -> str:
    path = _regular_file(path, "physical evidence release manifest")
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError as error:
        _fail(f"unable to read physical evidence release manifest: {error}")
    return digest.hexdigest()


def expected_binding(identity: dict[str, Any]) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "identityPurpose": identity["identityPurpose"],
        "archiveTreeSha256": identity["archiveTreeSha256"],
        "releaseTestingIpaSha256": identity["releaseTestingIpaSha256"],
        "appExecutableUUIDs": identity["appExecutableUUIDs"],
        "widgetExecutableUUIDs": identity["widgetExecutableUUIDs"],
        "debugSymbolsVerified": identity["debugSymbolsVerified"],
        "sourceInputDigest": identity["sourceInputDigest"],
        "releaseVersion": identity["releaseVersion"],
        "releaseBuild": identity["releaseBuild"],
    }


def validate_archive_binding(binding: Any) -> dict[str, Any]:
    required_keys = {
        "schemaVersion",
        "identityPurpose",
        "archiveTreeSha256",
        "releaseTestingIpaSha256",
        "appExecutableUUIDs",
        "widgetExecutableUUIDs",
        "debugSymbolsVerified",
        "sourceInputDigest",
        "releaseVersion",
        "releaseBuild",
    }
    if not isinstance(binding, dict) or set(binding) != required_keys:
        _fail("iOS archive binding has an invalid field set")
    if binding.get("schemaVersion") != 1:
        _fail("iOS archive binding schemaVersion is unsupported")
    if binding.get("identityPurpose") != IDENTITY_PURPOSE:
        _fail("iOS archive binding purpose is invalid")
    for key in ("archiveTreeSha256", "releaseTestingIpaSha256", "sourceInputDigest"):
        value = binding.get(key)
        if not isinstance(value, str) or DIGEST_PATTERN.fullmatch(value) is None:
            _fail(f"iOS archive binding {key} is malformed")
    if binding.get("debugSymbolsVerified") is not True:
        _fail("iOS archive binding must include verified debug symbols")
    for key in ("appExecutableUUIDs", "widgetExecutableUUIDs"):
        records = binding.get(key)
        if not isinstance(records, list) or not records:
            _fail(f"iOS archive binding {key} is missing")
        normalized: list[tuple[str, str]] = []
        for record in records:
            if not isinstance(record, dict) or set(record) != {"architecture", "uuid"}:
                _fail(f"iOS archive binding {key} record is malformed")
            architecture = record.get("architecture")
            uuid = record.get("uuid")
            if (
                not isinstance(architecture, str)
                or re.fullmatch(r"[A-Za-z0-9_]+", architecture) is None
                or not isinstance(uuid, str)
                or re.fullmatch(
                    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                    uuid,
                )
                is None
            ):
                _fail(f"iOS archive binding {key} record is invalid")
            normalized.append((architecture, uuid))
        if normalized != sorted(normalized) or len(normalized) != len(set(normalized)):
            _fail(f"iOS archive binding {key} must be sorted and unique")
        if not any(architecture in {"arm64", "arm64e"} for architecture, _ in normalized):
            _fail(f"iOS archive binding {key} lacks a 64-bit ARM slice")
    if (
        not isinstance(binding.get("releaseVersion"), str)
        or re.fullmatch(
            r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)",
            binding["releaseVersion"],
        )
        is None
        or not isinstance(binding.get("releaseBuild"), str)
        or re.fullmatch(r"[1-9][0-9]*", binding["releaseBuild"]) is None
    ):
        _fail("iOS archive binding release version/build is malformed")
    return binding


def prepare_release_testing_product(
    *, identity: dict[str, Any], ipa: Path, destination_app: Path
) -> Path:
    resolved_ipa = validate_release_testing_ipa(identity, ipa)
    try:
        app = extract_ios_app_from_ipa(resolved_ipa, destination_app)
        validate_release_testing_ipa(identity, resolved_ipa)
    except (ArchiveIdentityError, IPAValidationError):
        if os.path.lexists(destination_app):
            if destination_app.is_symlink() or not destination_app.is_dir():
                _fail("failed release-testing IPA preparation published an unsafe destination")
            shutil.rmtree(destination_app)
        raise
    return app


def bind_release_manifest(
    *, identity: dict[str, Any], manifest_path: Path
) -> dict[str, Any]:
    manifest = _read_json(manifest_path, "physical evidence pre-cleanup manifest")
    if manifest.get("cleanupComplete") is not False:
        _fail("archive binding requires a pre-cleanup physical evidence manifest")
    if manifest.get("acceptanceEligible") is not False:
        _fail("archive binding cannot modify an acceptance-eligible manifest")
    if manifest.get("diagnosticOnly") is not True:
        _fail("pre-cleanup physical evidence manifest must remain diagnostic-only")
    if type(manifest.get("preCleanupCandidate")) is not bool:
        _fail("pre-cleanup physical evidence candidate flag must be a boolean")
    binding = expected_binding(identity)
    existing = manifest.get("iosReleaseArchive")
    if "iosReleaseArchive" in manifest and existing != binding:
        _fail("physical evidence manifest is already bound to another archive or IPA")
    manifest["iosReleaseArchive"] = binding
    content = canonical_bytes(manifest)
    parent = _real_directory(manifest_path.parent, "physical evidence manifest parent")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{manifest_path.name}.archive-binding.", dir=parent
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, manifest_path)
        directory_descriptor = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary.exists():
            temporary.unlink()
    if _read_json(manifest_path, "bound physical evidence manifest") != manifest:
        _fail("physical evidence archive binding failed read-back verification")
    return manifest


def run_acceptance_validator(
    *,
    validator: Path,
    kind: str,
    evidence_directory: Path,
    expected_repository: str,
    expected_commit: str,
) -> None:
    if not validator.is_absolute():
        _fail("release acceptance validator path must be absolute")
    try:
        metadata = validator.lstat()
    except OSError as error:
        _fail(f"unable to inspect release acceptance validator: {error}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        _fail("release acceptance validator must be a real regular file")
    validator = validator.resolve(strict=True)
    result = subprocess.run(
        [
            "python3",
            str(validator),
            "--kind",
            kind,
            "--artifact-dir",
            str(evidence_directory),
            "--expected-source-repository",
            expected_repository,
            "--expected-source-sha",
            expected_commit,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()[:500]
        _fail(f"{kind} physical evidence failed the formal validator: {detail}")


def collect_evidence(
    *,
    identity: dict[str, Any],
    evidence_root: Path,
    validator: Path,
) -> list[dict[str, str]]:
    evidence_root = _real_directory(evidence_root, "physical evidence root")
    expected_repository = identity["sourceRepository"]
    expected_commit = identity["sourceCommit"]
    required_binding = expected_binding(identity)
    records: list[dict[str, str]] = []
    for kind, directory_name in EVIDENCE_CONTRACT:
        evidence_directory = _real_directory(
            evidence_root / directory_name, f"{kind} physical evidence directory"
        )
        manifest_path = _regular_file(
            evidence_directory / "release-acceptance.json",
            f"{kind} physical evidence release manifest",
        )
        manifest = _read_json(manifest_path, f"{kind} physical evidence release manifest")
        if manifest.get("acceptanceEligible") is not True:
            _fail(f"{kind} physical evidence is not acceptance eligible")
        if manifest.get("sourceRepository") != expected_repository:
            _fail(f"{kind} physical evidence repository does not match the archive")
        if manifest.get("sourceCommit") != expected_commit:
            _fail(f"{kind} physical evidence commit does not match the archive")
        if manifest.get("iosReleaseArchive") != required_binding:
            _fail(
                f"{kind} physical evidence is not bound to the exact release archive and IPA"
            )
        run_acceptance_validator(
            validator=validator,
            kind=kind,
            evidence_directory=evidence_directory,
            expected_repository=expected_repository,
            expected_commit=expected_commit,
        )
        records.append(
            {
                "kind": kind,
                "directoryName": directory_name,
                "releaseManifestSha256": _manifest_sha256(manifest_path),
            }
        )
    return records


def build_acceptance(
    *, identity: dict[str, Any], evidence_records: list[dict[str, str]]
) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "physicalAcceptanceEligible": True,
        "archiveIdentity": expected_binding(identity),
        "sourceRepository": identity["sourceRepository"],
        "sourceCommit": identity["sourceCommit"],
        "productSurface": "production",
        "buildConfiguration": "Release",
        "swiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
        "releaseVersion": identity["releaseVersion"],
        "releaseBuild": identity["releaseBuild"],
        "evidence": evidence_records,
    }


def validate_acceptance(payload: dict[str, Any], identity: dict[str, Any]) -> dict[str, Any]:
    if payload.get("schemaVersion") != SCHEMA_VERSION:
        _fail("physical acceptance schemaVersion is unsupported")
    if payload.get("physicalAcceptanceEligible") is not True:
        _fail("physical acceptance is not eligible")
    if payload.get("archiveIdentity") != expected_binding(identity):
        _fail("physical acceptance does not bind the exact release archive and IPA")
    exact_values = {
        "sourceRepository": identity["sourceRepository"],
        "sourceCommit": identity["sourceCommit"],
        "productSurface": "production",
        "buildConfiguration": "Release",
        "swiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
        "releaseVersion": identity["releaseVersion"],
        "releaseBuild": identity["releaseBuild"],
    }
    for key, expected in exact_values.items():
        if payload.get(key) != expected:
            _fail(f"physical acceptance {key} does not match the release archive")
    evidence = payload.get("evidence")
    if not isinstance(evidence, list) or len(evidence) != len(EVIDENCE_CONTRACT):
        _fail("physical acceptance evidence list is incomplete")
    for record, (expected_kind, expected_directory) in zip(evidence, EVIDENCE_CONTRACT):
        if not isinstance(record, dict):
            _fail("physical acceptance evidence record is malformed")
        if record.get("kind") != expected_kind or record.get("directoryName") != expected_directory:
            _fail("physical acceptance evidence order or directory contract is invalid")
        digest = record.get("releaseManifestSha256")
        if not isinstance(digest, str) or DIGEST_PATTERN.fullmatch(digest) is None:
            _fail("physical acceptance evidence manifest digest is malformed")
    return payload


def canonical_bytes(payload: dict[str, Any]) -> bytes:
    return (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")


def load_acceptance(path: Path, identity: dict[str, Any]) -> dict[str, Any]:
    payload = validate_acceptance(_read_json(path, "iOS physical acceptance"), identity)
    if canonical_bytes(payload) != path.read_bytes():
        _fail("iOS physical acceptance is not canonical JSON")
    return payload


def _write_new(path: Path, payload: dict[str, Any]) -> None:
    if not path.is_absolute():
        _fail("physical acceptance output path must be absolute")
    parent = _real_directory(path.parent, "physical acceptance output parent")
    if os.path.lexists(path):
        _fail("physical acceptance output already exists")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(canonical_bytes(payload))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_descriptor = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary.exists():
            temporary.unlink()


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "action",
        choices=("create", "verify", "verify-product", "prepare-product", "bind-manifest"),
    )
    parser.add_argument("--identity", required=True, type=Path)
    parser.add_argument("--evidence-root", type=Path)
    parser.add_argument("--acceptance", type=Path)
    parser.add_argument("--release-testing-ipa", type=Path)
    parser.add_argument("--destination-app", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument(
        "--validator",
        type=Path,
        default=Path(__file__).resolve().parent
        / "validate_real_device_release_acceptance_artifact.py",
    )
    return parser.parse_args()


def main() -> int:
    arguments = _parse_args()
    try:
        identity = load_identity(arguments.identity)
        if arguments.action == "verify-product":
            if arguments.release_testing_ipa is None:
                _fail("--release-testing-ipa is required for verify-product")
            validate_release_testing_ipa(identity, arguments.release_testing_ipa)
            print("ios_release_testing_product=verified")
            return 0
        if arguments.action == "prepare-product":
            if arguments.release_testing_ipa is None or arguments.destination_app is None:
                _fail(
                    "--release-testing-ipa and --destination-app are required for prepare-product"
                )
            app = prepare_release_testing_product(
                identity=identity,
                ipa=arguments.release_testing_ipa,
                destination_app=arguments.destination_app,
            )
            print(app)
            return 0
        if arguments.action == "bind-manifest":
            if arguments.manifest is None:
                _fail("--manifest is required for bind-manifest")
            bind_release_manifest(identity=identity, manifest_path=arguments.manifest)
            print("ios_release_archive_binding=written")
            return 0
        if (
            arguments.evidence_root is None
            or arguments.acceptance is None
            or arguments.release_testing_ipa is None
        ):
            _fail(
                "--evidence-root, --acceptance, and --release-testing-ipa are required "
                "for create and verify"
            )
        validate_release_testing_ipa(identity, arguments.release_testing_ipa)
        evidence_records = collect_evidence(
            identity=identity,
            evidence_root=arguments.evidence_root,
            validator=arguments.validator,
        )
        actual = validate_acceptance(
            build_acceptance(identity=identity, evidence_records=evidence_records), identity
        )
        if arguments.action == "create":
            _write_new(arguments.acceptance, actual)
            print(f"ios_physical_acceptance={arguments.acceptance}")
            return 0
        expected = load_acceptance(arguments.acceptance, identity)
        if canonical_bytes(expected) != canonical_bytes(actual):
            _fail("physical evidence changed after its acceptance was finalized")
        print("ios_physical_acceptance=verified")
        return 0
    except (ArchiveIdentityError, IPAValidationError, PhysicalAcceptanceError) as error:
        raise SystemExit(f"[ios-physical-acceptance] ERROR: {error}") from error


if __name__ == "__main__":
    raise SystemExit(main())
