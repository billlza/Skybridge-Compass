#!/usr/bin/env python3
"""Prove one immutable iOS identity lifecycle, then bind normal product runs.

``extract-lifecycle`` consumes the one real create/commit launch and a fresh
restore/self-test launch. It writes a temporary private binding inside the
calling transaction's protected directory plus a public lifecycle proof.
``extract-session-proof`` later joins an ordinary fresh product launch to that
binding and to the exact kind-specific product session. The private ``id1:``
correlator never enters a public artifact and must be deleted by the top-level
transaction after all kinds complete.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn

import extract_ios_product_release_evidence as product_evidence
from ios_release_archive_identity import ArchiveIdentityError, load_identity
from ios_physical_release_acceptance import expected_binding
from validate_product_release_evidence_log import (
    IOS_LOG_FILE,
    IOS_PRODUCT,
    parse_canonical_log,
)


MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_EVENT_COUNT = 4_096
SUBSYSTEM = "com.skybridge.compass.release-evidence"
CATEGORY = "ProductSession"
IDENTITY_REFERENCE = re.compile(r"id1:[0-9a-f]{32}\Z", re.ASCII)
SESSION_REFERENCE = re.compile(r"ev1:[0-9a-f]{32}\Z", re.ASCII)
ATTEMPT_REFERENCE = re.compile(r"at1:[0-9a-f]{32}\Z", re.ASCII)
FIELD_KEY = re.compile(r"[A-Za-z][A-Za-z0-9_]*\Z", re.ASCII)
FIELD_VALUE = re.compile(r"[A-Za-z0-9:+.,-]+\Z", re.ASCII)
SOURCE_REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z", re.ASCII)
SOURCE_COMMIT = re.compile(r"[0-9a-f]{40}\Z", re.ASCII)
FORMAL_KINDS = ("connectivity", "p2p", "webrtc", "file-transfer")
PRIVATE_BINDING_PROFILE = "skybridge-ios-production-identity-private-binding"
LIFECYCLE_PROOF_KEYS = {
    "algorithm",
    "created",
    "deviceRef",
    "firstLaunchFresh",
    "measurementSource",
    "persistence",
    "privateKeyExported",
    "productSurface",
    "protection",
    "realDevice",
    "restoredAfterRelaunch",
    "schemaVersion",
    "secureEnclaveBacked",
    "selfTestVerified",
    "softwareFallbackUsed",
    "sourceCommit",
    "sourceRepository",
    "swiftActiveCompilationConditions",
    "testingCompilationCondition",
}
SESSION_PROOF_KEYS = {
    "algorithm",
    "binaryTestSurfaceDetected",
    "created",
    "currentPathAuthorityVerified",
    "deviceRef",
    "evidenceSessionRef",
    "handshakePersistenceVerified",
    "measurementSource",
    "persisted",
    "privateKeyExported",
    "productSurface",
    "protection",
    "realDevice",
    "restoredAfterRelaunch",
    "schemaVersion",
    "secureEnclaveBacked",
    "signed",
    "softwareFallbackUsed",
    "sourceCommit",
    "sourceRepository",
    "swiftActiveCompilationConditions",
    "testingCompilationCondition",
    "verified",
}

# Exact schema of the redacted public proof written by extract(): the 19
# fixed-value fields plus the four provenance/session fields validated
# individually below. validate_public_proof() rejects any deviation.
PUBLIC_PROOF_KEYS = {
    "algorithm",
    "binaryTestSurfaceDetected",
    "created",
    "currentPathAuthorityVerified",
    "deviceRef",
    "evidenceSessionRef",
    "handshakePersistenceVerified",
    "measurementSource",
    "persisted",
    "privateKeyExported",
    "productSurface",
    "protection",
    "realDevice",
    "restoredAfterRelaunch",
    "schemaVersion",
    "secureEnclaveBacked",
    "signed",
    "softwareFallbackUsed",
    "sourceCommit",
    "sourceRepository",
    "swiftActiveCompilationConditions",
    "testingCompilationCondition",
    "verified",
}


class ProductionIdentityEvidenceError(RuntimeError):
    """The two product launches do not prove the required identity lifecycle."""


def _fail(message: str) -> NoReturn:
    raise ProductionIdentityEvidenceError(message)


@dataclass(frozen=True)
class Event:
    name: str
    fields: dict[str, str]


def _read_regular(path: Path, label: str, maximum_bytes: int) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        _fail(f"unable to open {label} without following links: {exc}")
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size < 1
            or before.st_size > maximum_bytes
        ):
            _fail(f"{label} must be a bounded single-link regular file")
        content = bytearray()
        while len(content) < before.st_size:
            chunk = os.read(descriptor, min(1024 * 1024, before.st_size - len(content)))
            if not chunk:
                _fail(f"{label} was truncated while reading")
            content.extend(chunk)
        if os.read(descriptor, 1):
            _fail(f"{label} grew while reading")
        after = os.fstat(descriptor)
        stable = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns")
        if any(getattr(before, field) != getattr(after, field) for field in stable):
            _fail(f"{label} changed while reading")
        return bytes(content)
    finally:
        os.close(descriptor)


def _parse_message(message: str) -> Event:
    if not message.isascii() or message != " ".join(message.split(" ")):
        _fail("identity event must be canonical single-space ASCII")
    tokens = message.split(" ")
    fields: dict[str, str] = {}
    for token in tokens[1:]:
        if token.count("=") != 1:
            _fail("identity event contains a malformed field")
        key, value = token.split("=", 1)
        if (
            FIELD_KEY.fullmatch(key) is None
            or FIELD_VALUE.fullmatch(value) is None
            or key in fields
        ):
            _fail("identity event contains an invalid or duplicate field")
        fields[key] = value
    return Event(tokens[0], fields)


def _identity_events(raw_path: Path, identity: dict[str, Any]) -> list[Event]:
    try:
        text = _read_regular(raw_path, "private iOS identity OSLog NDJSON", MAX_INPUT_BYTES).decode(
            "utf-8"
        )
    except UnicodeDecodeError as exc:
        _fail(f"private iOS identity OSLog NDJSON is not UTF-8: {exc}")
    events: list[Event] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line:
            _fail(f"raw identity OSLog line {line_number} is empty")
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            _fail(f"raw identity OSLog line {line_number} is invalid JSON: {exc}")
        if not isinstance(row, dict):
            _fail(f"raw identity OSLog line {line_number} is not an object")
        if (
            row.get("eventType") != "logEvent"
            or row.get("messageType") != "Default"
            or row.get("subsystem") != SUBSYSTEM
            or row.get("category") != CATEGORY
            or row.get("processID") != identity["processIdentifier"]
            or product_evidence._remote_image_path(row.get("processImagePath"), line_number)
            != identity["executablePath"]
        ):
            _fail(f"raw identity OSLog line {line_number} is outside the exact process boundary")
        if not isinstance(row.get("formatString"), str) or "public" not in row["formatString"]:
            _fail(f"raw identity OSLog line {line_number} was not emitted as public data")
        message = row.get("eventMessage")
        if not isinstance(message, str):
            _fail(f"raw identity OSLog line {line_number} has no eventMessage")
        if message.startswith("productionIdentity"):
            events.append(_parse_message(message))
    if len(events) > MAX_EVENT_COUNT:
        _fail("identity event count exceeds the fixed bound")
    return events


def _require_exact_event(
    events: list[Event],
    name: str,
    expected_fields: tuple[str, ...],
) -> Event:
    matches = [event for event in events if event.name == name]
    if len(matches) != 1:
        _fail(f"product launch must contain exactly one {name}")
    event = matches[0]
    if tuple(event.fields) != expected_fields:
        _fail(f"{name} does not use the fixed field schema")
    return event


def _validate_descriptor(event: Event) -> str:
    reference = event.fields["identity_ref"]
    if (
        IDENTITY_REFERENCE.fullmatch(reference) is None
        or event.fields["algorithm"] != "mldsa87"
        or event.fields["protection"] != "secureEnclaveRequired"
        or event.fields["result"] != "success"
    ):
        _fail(f"{event.name} is not the required Secure Enclave ML-DSA-87 identity")
    return reference


def _atomic_new_file(path: Path, content: bytes) -> None:
    if path.exists() or path.is_symlink():
        _fail(f"output already exists: {path}")
    parent = path.parent.resolve(strict=True)
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
        directory_descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
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


def validate_lifecycle_proof(proof_path: Path) -> dict[str, Any]:
    """Validate the redacted public identity lifecycle proof."""

    try:
        proof = json.loads(
            _read_regular(proof_path, "public iOS identity lifecycle proof", 64 * 1024)
            .decode("utf-8")
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(f"public iOS identity lifecycle proof is invalid UTF-8 JSON: {exc}")
    if not isinstance(proof, dict) or set(proof) != LIFECYCLE_PROOF_KEYS:
        _fail("public lifecycle proof does not use the exact schema")
    if proof.get("deviceRef") != "identity-1":
        _fail("public lifecycle proof deviceRef must be the artifact-local identity-1 alias")
    exact_values: dict[str, object] = {
        "algorithm": "mldsa87",
        "created": True,
        "deviceRef": "identity-1",
        "firstLaunchFresh": True,
        "measurementSource": "signed-production-app-runtime",
        "persistence": "keychain-authority",
        "privateKeyExported": False,
        "productSurface": "production",
        "protection": "secureEnclaveRequired",
        "realDevice": True,
        "restoredAfterRelaunch": True,
        "schemaVersion": 1,
        "secureEnclaveBacked": True,
        "selfTestVerified": True,
        "softwareFallbackUsed": False,
        "testingCompilationCondition": False,
    }
    for key, expected in exact_values.items():
        if proof.get(key) != expected or type(proof.get(key)) is not type(expected):
            _fail(f"public lifecycle proof {key} mismatch")
    if (
        SOURCE_REPOSITORY.fullmatch(proof.get("sourceRepository", "")) is None
        or SOURCE_COMMIT.fullmatch(proof.get("sourceCommit", "")) is None
        or proof.get("swiftActiveCompilationConditions") != ["HAS_APPLE_PQC_SDK"]
    ):
        _fail("public lifecycle proof provenance is malformed")
    encoded = json.dumps(proof, sort_keys=True)
    if "id1:" in encoded or "identity_ref" in encoded or "identityRef" in encoded:
        _fail("public lifecycle proof contains a private cross-launch identity field")
    return proof


def validate_public_proof(
    proof_path: Path,
    *,
    archive_identity: Path | None = None,
) -> dict[str, Any]:
    """Validate the redacted materialized proof independently of raw logs."""

    try:
        proof = json.loads(
            _read_regular(proof_path, "public iOS production identity proof", 64 * 1024)
            .decode("utf-8")
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(f"public iOS production identity proof is invalid UTF-8 JSON: {exc}")
    if not isinstance(proof, dict) or set(proof) != PUBLIC_PROOF_KEYS:
        _fail("public identity proof does not use the exact schema")
    # The public proof must never carry a stable cross-launch identity
    # reference; the only accepted device reference is the artifact-local
    # identity-1 alias, checked separately so the violation is named.
    if proof.get("deviceRef") != "identity-1":
        _fail(
            "public identity proof deviceRef must be the artifact-local identity-1 alias"
        )
    exact_values: dict[str, object] = {
        "algorithm": "mldsa87",
        "binaryTestSurfaceDetected": False,
        "created": True,
        "currentPathAuthorityVerified": True,
        "deviceRef": "identity-1",
        "handshakePersistenceVerified": True,
        "measurementSource": "signed-production-app-runtime",
        "persisted": True,
        "privateKeyExported": False,
        "productSurface": "production",
        "protection": "secureEnclaveRequired",
        "realDevice": True,
        "restoredAfterRelaunch": True,
        "schemaVersion": 1,
        "secureEnclaveBacked": True,
        "signed": True,
        "softwareFallbackUsed": False,
        "testingCompilationCondition": False,
        "verified": True,
    }
    for key, expected in exact_values.items():
        if proof.get(key) != expected or type(proof.get(key)) is not type(expected):
            _fail(f"public identity proof {key} mismatch")
    if (
        SESSION_REFERENCE.fullmatch(proof.get("evidenceSessionRef", "")) is None
        or SOURCE_REPOSITORY.fullmatch(proof.get("sourceRepository", "")) is None
        or SOURCE_COMMIT.fullmatch(proof.get("sourceCommit", "")) is None
        or proof.get("swiftActiveCompilationConditions") != ["HAS_APPLE_PQC_SDK"]
    ):
        _fail("public identity proof provenance or session binding is malformed")
    encoded = json.dumps(proof, sort_keys=True)
    if "id1:" in encoded or "identity_ref" in encoded or "identityRef" in encoded:
        _fail("public identity proof contains a private cross-launch identity field")

    if archive_identity is not None:
        try:
            archive = load_identity(archive_identity)
        except ArchiveIdentityError as exc:
            _fail(f"sealed iOS archive identity is invalid: {exc}")
        if (
            proof["sourceRepository"] != archive["sourceRepository"]
            or proof["sourceCommit"] != archive["sourceCommit"]
            or proof["swiftActiveCompilationConditions"]
            != archive["swiftActiveCompilationConditions"]
        ):
            _fail("public identity proof does not match the sealed archive provenance")
    return proof


def extract(
    *,
    first_raw_oslog: Path,
    first_launch_identity: Path,
    second_raw_oslog: Path,
    second_launch_identity: Path,
    archive_identity: Path,
    output: Path,
) -> None:
    first_identity = product_evidence._validate_private_launch_identity(first_launch_identity)
    second_identity = product_evidence._validate_private_launch_identity(second_launch_identity)
    if (
        first_identity["processIdentifier"] == second_identity["processIdentifier"]
        or first_identity["startTimeToken"] == second_identity["startTimeToken"]
    ):
        _fail("identity lifecycle requires two distinct fresh product launches")
    first_installation = first_identity["installationBinding"]
    second_installation = second_identity["installationBinding"]
    if first_installation != second_installation:
        _fail("identity lifecycle launches do not use the same installed release product")

    first_events = _identity_events(first_raw_oslog, first_identity)
    second_events = _identity_events(second_raw_oslog, second_identity)
    if [event.name for event in first_events] != ["productionIdentityCommitted"]:
        _fail("first product launch must contain only the committed identity terminal")
    if [event.name for event in second_events] != [
        "productionIdentityRestored",
        "productionIdentityHandshakeBound",
    ]:
        _fail("second product launch must restore before the authenticated handshake terminal")

    committed = _require_exact_event(
        first_events,
        "productionIdentityCommitted",
        ("identity_ref", "algorithm", "protection", "persistence", "created", "result"),
    )
    restored = _require_exact_event(
        second_events,
        "productionIdentityRestored",
        ("identity_ref", "algorithm", "protection", "persistence", "selfTest", "result"),
    )
    bound = _require_exact_event(
        second_events,
        "productionIdentityHandshakeBound",
        (
            "transport",
            "session_ref",
            "attempt_ref",
            "identity_ref",
            "algorithm",
            "protection",
            "localSignature",
            "peerVerification",
            "currentPathAuthority",
            "result",
        ),
    )
    references = {_validate_descriptor(event) for event in (committed, restored, bound)}
    if len(references) != 1:
        _fail("created, restored, and handshake-bound identities do not match")
    if (
        committed.fields["persistence"] != "keychain-authority"
        or committed.fields["created"] != "1"
        or restored.fields["persistence"] != "keychain-authority"
        or restored.fields["selfTest"] != "verified"
        or bound.fields["transport"] != "p2p"
        or SESSION_REFERENCE.fullmatch(bound.fields["session_ref"]) is None
        or ATTEMPT_REFERENCE.fullmatch(bound.fields["attempt_ref"]) is None
        or bound.fields["localSignature"] != "used"
        or bound.fields["peerVerification"] != "authenticated-finished"
        or bound.fields["currentPathAuthority"] != "verified"
    ):
        _fail("identity lifecycle does not prove persistence and authenticated current-path use")

    try:
        archive = load_identity(archive_identity)
    except ArchiveIdentityError as exc:
        _fail(f"sealed iOS archive identity is invalid: {exc}")
    if first_installation["iosReleaseArchive"] != expected_binding(archive):
        _fail("installed product does not bind the supplied sealed archive identity")
    proof = {
        "algorithm": "mldsa87",
        "binaryTestSurfaceDetected": False,
        "created": True,
        "currentPathAuthorityVerified": True,
        "deviceRef": "identity-1",
        "evidenceSessionRef": bound.fields["session_ref"],
        "handshakePersistenceVerified": True,
        "measurementSource": "signed-production-app-runtime",
        "persisted": True,
        "privateKeyExported": False,
        "productSurface": "production",
        "protection": "secureEnclaveRequired",
        "realDevice": True,
        "restoredAfterRelaunch": True,
        "schemaVersion": 1,
        "secureEnclaveBacked": True,
        "signed": True,
        "softwareFallbackUsed": False,
        "sourceCommit": archive["sourceCommit"],
        "sourceRepository": archive["sourceRepository"],
        "swiftActiveCompilationConditions": archive["swiftActiveCompilationConditions"],
        "testingCompilationCondition": False,
        "verified": True,
    }
    public_bytes = (json.dumps(proof, indent=2, sort_keys=True) + "\n").encode()
    private_reference = next(iter(references)).encode()
    if private_reference in public_bytes or private_reference[4:] in public_bytes:
        _fail("public identity proof contains the private cross-launch identity reference")
    _atomic_new_file(output, public_bytes)
    validate_public_proof(output, archive_identity=archive_identity)
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    extract_parser = subparsers.add_parser(
        "extract", description="Materialize a proof from two private product launches."
    )
    extract_parser.add_argument("--first-raw-oslog", type=Path, required=True)
    extract_parser.add_argument("--first-launch-identity", type=Path, required=True)
    extract_parser.add_argument("--second-raw-oslog", type=Path, required=True)
    extract_parser.add_argument("--second-launch-identity", type=Path, required=True)
    extract_parser.add_argument("--archive-identity", type=Path, required=True)
    extract_parser.add_argument("--output", type=Path, required=True)
    validate_parser = subparsers.add_parser(
        "validate-proof", description="Validate one redacted public proof."
    )
    validate_parser.add_argument("--proof", type=Path, required=True)
    validate_parser.add_argument("--archive-identity", type=Path)
    lifecycle_parser = subparsers.add_parser(
        "validate-lifecycle-proof",
        description="Validate one redacted public identity lifecycle proof.",
    )
    lifecycle_parser.add_argument("--proof", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        if arguments.command == "validate-lifecycle-proof":
            validate_lifecycle_proof(arguments.proof)
        elif arguments.command == "extract":
            extract(
                first_raw_oslog=arguments.first_raw_oslog,
                first_launch_identity=arguments.first_launch_identity,
                second_raw_oslog=arguments.second_raw_oslog,
                second_launch_identity=arguments.second_launch_identity,
                archive_identity=arguments.archive_identity,
                output=arguments.output,
            )
        else:
            validate_public_proof(
                arguments.proof,
                archive_identity=arguments.archive_identity,
            )
    except ProductionIdentityEvidenceError as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
