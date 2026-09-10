#!/usr/bin/env python3
"""Prove one immutable iOS identity lifecycle, then bind normal product runs.

``extract-lifecycle`` consumes the selected real creation or existing-identity
lifecycle and a fresh restore/self-test launch. It writes a private binding inside the
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
from enum import Enum
from pathlib import Path
from typing import Any, NoReturn

import extract_ios_product_release_evidence as product_evidence
import validate_product_release_evidence_log as product_lifecycle
from ios_physical_release_acceptance import (
    PhysicalAcceptanceError,
    expected_binding,
    validate_archive_binding,
)
from ios_release_archive_identity import ArchiveIdentityError, load_identity
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


class IdentityEvidencePurpose(str, Enum):
    CREATED = "new-secure-enclave-identity"
    EXISTING = "existing-production-identity"


@dataclass(frozen=True)
class IdentityEvidencePolicy:
    purpose: IdentityEvidencePurpose = IdentityEvidencePurpose.CREATED
    expected_suite: str | None = None
    protection: str = "secureEnclaveRequired"

    def __post_init__(self) -> None:
        if self.purpose is IdentityEvidencePurpose.CREATED:
            if (
                self.expected_suite is not None
                or self.protection != "secureEnclaveRequired"
            ):
                _fail(
                    "the original creation purpose requires its unchanged ML-DSA-87 Secure Enclave contract"
                )
        elif self.purpose is IdentityEvidencePurpose.EXISTING:
            if self.expected_suite != "0x0012" or self.protection not in (
                "softwareKeychain",
                "secureEnclaveRequired",
            ):
                _fail(
                    "existing identity evidence requires explicit Q suite 0x0012 and the actual committed protection"
                )
        else:
            _fail("unsupported identity evidence purpose")

    @property
    def algorithm(self) -> str:
        return (
            "mldsa65" if self.purpose is IdentityEvidencePurpose.EXISTING else "mldsa87"
        )

    @property
    def version(self) -> int:
        return 2 if self.purpose is IdentityEvidencePurpose.EXISTING else 1


Q_AUTHENTICATED_SUITE = "Q-Periapt-ABI2-PolicyBound"
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

EXISTING_FIELDS = {
    "purpose",
    "expectedSuite",
    "identityDisposition",
    "continuity",
    "iosReleaseArchive",
    "baselineArchive",
}
EXISTING_LIFECYCLE_KEYS = (LIFECYCLE_PROOF_KEYS - {"created"}) | EXISTING_FIELDS
EXISTING_SESSION_KEYS = (
    (SESSION_PROOF_KEYS - {"created"})
    | EXISTING_FIELDS
    | {
        "evidenceSessionRefs",
        "localFinishedSent",
        "peerFinishedVerified",
    }
)


class ProductionIdentityEvidenceError(RuntimeError):
    """The two product launches do not prove the required identity lifecycle."""


def _fail(message: str) -> NoReturn:
    raise ProductionIdentityEvidenceError(message)


@dataclass(frozen=True)
class Event:
    name: str
    fields: dict[str, str]


def _read_regular(
    path: Path, label: str, maximum_bytes: int, *, private: bool = False
) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        _fail(f"unable to open {label} without following links: {exc}")
    try:
        before = os.fstat(descriptor)
        if private and (
            before.st_uid != os.geteuid() or stat.S_IMODE(before.st_mode) != 0o600
        ):
            _fail(f"{label} must be current-user mode 0600")
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
        text = _read_regular(
            raw_path, "private iOS identity OSLog NDJSON", MAX_INPUT_BYTES
        ).decode("utf-8")
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
            or product_evidence._remote_image_path(
                row.get("processImagePath"), line_number
            )
            != identity["executablePath"]
        ):
            _fail(
                f"raw identity OSLog line {line_number} is outside the exact process boundary"
            )
        if (
            not isinstance(row.get("formatString"), str)
            or "public" not in row["formatString"]
        ):
            _fail(
                f"raw identity OSLog line {line_number} was not emitted as public data"
            )
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


def _validate_selected_descriptor(event: Event, policy: IdentityEvidencePolicy) -> str:
    if policy.purpose is IdentityEvidencePurpose.CREATED:
        return _validate_descriptor(event)
    if (
        IDENTITY_REFERENCE.fullmatch(event.fields.get("identity_ref", "")) is None
        or event.fields.get("algorithm") != policy.algorithm
        or event.fields.get("protection") != policy.protection
        or event.fields.get("result") != "success"
    ):
        _fail(
            "existing identity event differs from the selected committed algorithm/protection"
        )
    return event.fields["identity_ref"]


def _validate_proof_provenance(
    proof: dict[str, Any], archive_identity: Path | None
) -> None:
    if (
        not isinstance(proof.get("sourceRepository"), str)
        or SOURCE_REPOSITORY.fullmatch(proof["sourceRepository"]) is None
        or not isinstance(proof.get("sourceCommit"), str)
        or SOURCE_COMMIT.fullmatch(proof["sourceCommit"]) is None
        or proof.get("swiftActiveCompilationConditions") != ["HAS_APPLE_PQC_SDK"]
    ):
        _fail("identity proof provenance is malformed")
    if archive_identity is not None:
        try:
            archive = load_identity(archive_identity)
        except ArchiveIdentityError as exc:
            _fail(f"sealed iOS archive identity is invalid: {exc}")
        for proof_key, archive_key in (
            ("sourceRepository", "sourceRepository"),
            ("sourceCommit", "sourceCommit"),
            ("swiftActiveCompilationConditions", "swiftActiveCompilationConditions"),
        ):
            if proof[proof_key] != archive[archive_key]:
                _fail("identity proof does not match the sealed archive provenance")
        if proof.get("schemaVersion") == 2 and proof[
            "iosReleaseArchive"
        ] != expected_binding(archive):
            _fail("existing identity proof does not match the exact sealed archive")


def _require_archive_binding(value: object) -> None:
    try:
        validate_archive_binding(value)
    except PhysicalAcceptanceError as exc:
        _fail(f"identity evidence archive binding is invalid: {exc}")


def _validate_existing_proof(
    proof: dict[str, Any], *, lifecycle: bool, archive_identity: Path | None = None
) -> None:
    expected_keys = EXISTING_LIFECYCLE_KEYS if lifecycle else EXISTING_SESSION_KEYS
    if set(proof) != expected_keys:
        _fail("existing identity proof does not use its exact versioned schema")
    policy = IdentityEvidencePolicy(
        IdentityEvidencePurpose.EXISTING,
        proof.get("expectedSuite"),
        proof.get("protection"),
    )
    exact: dict[str, object] = {
        "schemaVersion": 2,
        "purpose": IdentityEvidencePurpose.EXISTING.value,
        "algorithm": policy.algorithm,
        "deviceRef": "identity-1",
        "identityDisposition": "restored-committed-authority",
        "measurementSource": "signed-production-app-runtime",
        "privateKeyExported": False,
        "productSurface": "production",
        "realDevice": True,
        "restoredAfterRelaunch": True,
        "secureEnclaveBacked": policy.protection == "secureEnclaveRequired",
        "softwareFallbackUsed": False,
        "testingCompilationCondition": False,
    }
    if lifecycle:
        exact.update(
            firstLaunchFresh=True,
            persistence="keychain-authority",
            selfTestVerified=True,
        )
    else:
        exact.update(
            binaryTestSurfaceDetected=False,
            currentPathAuthorityVerified=True,
            handshakePersistenceVerified=True,
            persisted=True,
            signed=True,
            verified=True,
            localFinishedSent=True,
            peerFinishedVerified=True,
        )
        references = proof["evidenceSessionRefs"]
        if (
            not isinstance(references, list)
            or not 1 <= len(references) <= 4
            or any(
                not isinstance(value, str) or SESSION_REFERENCE.fullmatch(value) is None
                for value in references
            )
            or references != sorted(set(references))
            or proof["evidenceSessionRef"] not in references
        ):
            _fail("existing identity proof has invalid exact session references")
    for key, value in exact.items():
        if type(proof.get(key)) is not type(value) or proof[key] != value:
            _fail(f"existing identity proof {key} mismatch")
    _require_archive_binding(proof["iosReleaseArchive"])
    if proof["continuity"] == "cold-start-restoration":
        if proof["baselineArchive"] is not None:
            _fail("cold-start restoration cannot claim an upgrade baseline")
    elif proof["continuity"] == "upgrade-baseline-bound":
        _require_archive_binding(proof["baselineArchive"])
        if proof["baselineArchive"] == proof["iosReleaseArchive"]:
            _fail("an upgrade baseline must precede a different installed archive")
    else:
        _fail("existing identity proof has no explicit continuity scope")
    _validate_proof_provenance(proof, archive_identity)
    encoded = json.dumps(proof, sort_keys=True)
    if "id1:" in encoded or "identity_ref" in encoded or "identityRef" in encoded:
        _fail("public existing identity proof contains a private identity reference")


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


def validate_lifecycle_proof(
    proof_path: Path, *, archive_identity: Path | None = None
) -> dict[str, Any]:
    """Validate the redacted public identity lifecycle proof."""

    try:
        proof = json.loads(
            _read_regular(
                proof_path, "public iOS identity lifecycle proof", 64 * 1024
            ).decode("utf-8")
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(f"public iOS identity lifecycle proof is invalid UTF-8 JSON: {exc}")
    return _validate_lifecycle_payload(proof, archive_identity=archive_identity)


def _validate_lifecycle_payload(
    proof: object, *, archive_identity: Path | None = None
) -> dict[str, Any]:
    if isinstance(proof, dict) and proof.get("schemaVersion") == 2:
        _validate_existing_proof(
            proof, lifecycle=True, archive_identity=archive_identity
        )
        return proof
    if not isinstance(proof, dict) or set(proof) != LIFECYCLE_PROOF_KEYS:
        _fail("public lifecycle proof does not use the exact schema")
    if proof.get("deviceRef") != "identity-1":
        _fail(
            "public lifecycle proof deviceRef must be the artifact-local identity-1 alias"
        )
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
    _validate_proof_provenance(proof, archive_identity)
    return proof


def validate_public_proof(
    proof_path: Path,
    *,
    archive_identity: Path | None = None,
) -> dict[str, Any]:
    """Validate the redacted materialized proof independently of raw logs."""

    try:
        proof = json.loads(
            _read_regular(
                proof_path, "public iOS production identity proof", 64 * 1024
            ).decode("utf-8")
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(f"public iOS production identity proof is invalid UTF-8 JSON: {exc}")
    if isinstance(proof, dict) and proof.get("schemaVersion") == 2:
        _validate_existing_proof(
            proof, lifecycle=False, archive_identity=archive_identity
        )
        return proof
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
    first_identity = product_evidence._validate_private_launch_identity(
        first_launch_identity
    )
    second_identity = product_evidence._validate_private_launch_identity(
        second_launch_identity
    )
    if (
        first_identity["processIdentifier"] == second_identity["processIdentifier"]
        or first_identity["startTimeToken"] == second_identity["startTimeToken"]
    ):
        _fail("identity lifecycle requires two distinct fresh product launches")
    first_installation = first_identity["installationBinding"]
    second_installation = second_identity["installationBinding"]
    if first_installation != second_installation:
        _fail(
            "identity lifecycle launches do not use the same installed release product"
        )

    first_events = _identity_events(first_raw_oslog, first_identity)
    second_events = _identity_events(second_raw_oslog, second_identity)
    if [event.name for event in first_events] != ["productionIdentityCommitted"]:
        _fail("first product launch must contain only the committed identity terminal")
    if [event.name for event in second_events] != [
        "productionIdentityRestored",
        "productionIdentityHandshakeBound",
    ]:
        _fail(
            "second product launch must restore before the authenticated handshake terminal"
        )

    committed = _require_exact_event(
        first_events,
        "productionIdentityCommitted",
        ("identity_ref", "algorithm", "protection", "persistence", "created", "result"),
    )
    restored = _require_exact_event(
        second_events,
        "productionIdentityRestored",
        (
            "identity_ref",
            "algorithm",
            "protection",
            "persistence",
            "selfTest",
            "result",
        ),
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
        _fail(
            "identity lifecycle does not prove persistence and authenticated current-path use"
        )

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
        _fail(
            "public identity proof contains the private cross-launch identity reference"
        )
    _atomic_new_file(output, public_bytes)
    validate_public_proof(output, archive_identity=archive_identity)


def _policy_from_proof(proof: dict[str, Any]) -> IdentityEvidencePolicy:
    if proof["schemaVersion"] == 1:
        return IdentityEvidencePolicy()
    return IdentityEvidencePolicy(
        IdentityEvidencePurpose.EXISTING, proof["expectedSuite"], proof["protection"]
    )


def identity_manifest_fields(proof: dict[str, Any]) -> dict[str, object]:
    """Derive the manifest contract from a previously validated identity proof."""
    policy = _policy_from_proof(proof)
    fields: dict[str, object] = {
        "schemaVersion": policy.version,
        "iosProductionIdentityAlgorithm": policy.algorithm,
        "iosProductionIdentityProtection": policy.protection,
    }
    if policy.purpose is IdentityEvidencePurpose.EXISTING:
        fields.update(
            iosProductionIdentityPurpose=policy.purpose.value,
            expectedSuite=policy.expected_suite,
        )
    return fields


def validate_manifest_identity_policy(
    payload: dict[str, Any],
) -> IdentityEvidencePolicy:
    """Preserve v1 creation requirements; v2 explicitly selects existing Q identity."""
    version = payload.get("schemaVersion")
    if type(version) is not int or version not in (1, 2):
        _fail("unsupported release manifest identity policy version")
    if version == 1:
        if "iosProductionIdentityPurpose" in payload or "expectedSuite" in payload:
            _fail("the v1 creation manifest cannot change its identity purpose")
        policy = IdentityEvidencePolicy()
    else:
        if (
            payload.get("iosProductionIdentityPurpose")
            != IdentityEvidencePurpose.EXISTING.value
        ):
            _fail(
                "the v2 manifest must explicitly select the existing production identity"
            )
        policy = IdentityEvidencePolicy(
            IdentityEvidencePurpose.EXISTING,
            payload.get("expectedSuite"),
            payload.get("iosProductionIdentityProtection"),
        )
    if (
        payload.get("iosProductionIdentityAlgorithm") != policy.algorithm
        or payload.get("iosProductionIdentityProtection") != policy.protection
    ):
        _fail(
            "release manifest identity algorithm/protection differs from its selected purpose"
        )
    return policy


def _proof_provenance(archive: dict[str, Any]) -> dict[str, Any]:
    return {
        key: archive[key]
        for key in (
            "sourceCommit",
            "sourceRepository",
            "swiftActiveCompilationConditions",
        )
    }


def _read_private_binding(path: Path) -> dict[str, Any]:
    try:
        binding = json.loads(
            _read_regular(path, "private identity binding", 128 * 1024, private=True)
        )
    except (UnicodeDecodeError, json.JSONDecodeError):
        _fail("private identity binding is not valid UTF-8 JSON")
    keys = {
        "schemaVersion",
        "profile",
        "identityReference",
        "iosReleaseArchive",
        "lastLaunch",
        "lifecycleProof",
    }
    if not isinstance(binding, dict) or set(binding) != keys:
        _fail("private identity binding has an invalid field set")
    if (
        binding["profile"] != PRIVATE_BINDING_PROFILE
        or not isinstance(binding["identityReference"], str)
        or IDENTITY_REFERENCE.fullmatch(binding["identityReference"]) is None
    ):
        _fail("private identity binding has an invalid profile or reference")
    proof = binding["lifecycleProof"]
    if not isinstance(proof, dict):
        _fail("private identity binding has no validated lifecycle proof")
    if type(binding["schemaVersion"]) is not int or binding[
        "schemaVersion"
    ] != proof.get("schemaVersion"):
        _fail("private identity binding version differs from its lifecycle proof")
    if proof.get("schemaVersion") == 2:
        _validate_existing_proof(proof, lifecycle=True)
        if proof["iosReleaseArchive"] != binding["iosReleaseArchive"]:
            _fail("private identity binding contains mixed archive identities")
    elif proof.get("schemaVersion") == 1:
        _validate_lifecycle_payload(proof)
    else:
        _fail("unsupported private identity binding version")
    _require_archive_binding(binding["iosReleaseArchive"])
    launch = binding["lastLaunch"]
    if (
        not isinstance(launch, dict)
        or set(launch) != {"processIdentifier", "startTimeToken"}
        or type(launch["processIdentifier"]) is not int
        or launch["processIdentifier"] <= 0
        or not isinstance(launch["startTimeToken"], str)
        or re.fullmatch(r"[0-9]+:[0-9]{1,6}", launch["startTimeToken"], re.ASCII)
        is None
    ):
        _fail("private identity binding lacks its exact completed launch")
    return binding


def extract_lifecycle(
    *,
    first_raw_oslog: Path,
    first_launch_identity: Path,
    second_raw_oslog: Path,
    second_launch_identity: Path,
    archive_identity: Path,
    private_binding: Path,
    public_proof: Path,
    policy: IdentityEvidencePolicy | None = None,
    baseline_binding: Path | None = None,
) -> None:
    if policy is None:
        policy = IdentityEvidencePolicy()
    first = product_evidence._validate_private_launch_identity(first_launch_identity)
    second = product_evidence._validate_private_launch_identity(second_launch_identity)
    if (
        first["processIdentifier"] == second["processIdentifier"]
        or first["startTimeToken"] == second["startTimeToken"]
    ):
        _fail("identity lifecycle requires two distinct fresh product launches")
    if first["installationBinding"] != second["installationBinding"]:
        _fail("identity lifecycle launches use different installed products")
    try:
        archive = load_identity(archive_identity)
    except ArchiveIdentityError as exc:
        _fail(f"sealed iOS archive identity is invalid: {exc}")
    archive_binding = expected_binding(archive)
    if first["installationBinding"]["iosReleaseArchive"] != archive_binding:
        _fail("identity lifecycle does not match the sealed archive")
    first_events = _identity_events(first_raw_oslog, first)
    second_events = _identity_events(second_raw_oslog, second)
    restored_fields = (
        "identity_ref",
        "algorithm",
        "protection",
        "persistence",
        "selfTest",
        "result",
    )
    if policy.purpose is IdentityEvidencePurpose.CREATED:
        initial = _require_exact_event(
            first_events,
            "productionIdentityCommitted",
            (
                "identity_ref",
                "algorithm",
                "protection",
                "persistence",
                "created",
                "result",
            ),
        )
        if initial.fields["created"] != "1" or baseline_binding is not None:
            _fail(
                "the creation lifecycle requires actual new creation without an upgrade baseline"
            )
    else:
        initial = _require_exact_event(
            first_events, "productionIdentityRestored", restored_fields
        )
        if initial.fields["selfTest"] != "verified":
            _fail("the first existing-identity launch lacks its real signing self-test")
    restored = _require_exact_event(
        second_events, "productionIdentityRestored", restored_fields
    )
    if len(first_events) != 1 or len(second_events) != 1:
        _fail(
            "identity lifecycle requires exactly its two isolated identity observations"
        )
    references = {
        _validate_selected_descriptor(event, policy) for event in (initial, restored)
    }
    if len(references) != 1:
        _fail("identity lifecycle changes its immutable authority")
    if (
        any(
            event.fields["persistence"] != "keychain-authority"
            for event in (initial, restored)
        )
        or restored.fields["selfTest"] != "verified"
    ):
        _fail("identity lifecycle lacks committed persistence or restored self-test")
    reference = references.pop()
    baseline_archive = None
    if baseline_binding is not None:
        baseline = _read_private_binding(baseline_binding)
        if (
            baseline["identityReference"] != reference
            or _policy_from_proof(baseline["lifecycleProof"]) != policy
        ):
            _fail(
                "upgrade baseline changes the actual identity or selected algorithm/protection"
            )
        if (
            baseline["lifecycleProof"]["sourceRepository"]
            != archive["sourceRepository"]
        ):
            _fail("upgrade baseline belongs to a different source repository")
        baseline_archive = baseline["iosReleaseArchive"]
        if baseline_archive == archive_binding:
            _fail("an upgrade baseline must precede a different installed archive")
    proof = {
        "algorithm": policy.algorithm,
        "deviceRef": "identity-1",
        "firstLaunchFresh": True,
        "measurementSource": "signed-production-app-runtime",
        "persistence": "keychain-authority",
        "privateKeyExported": False,
        "productSurface": "production",
        "protection": policy.protection,
        "realDevice": True,
        "restoredAfterRelaunch": True,
        "schemaVersion": policy.version,
        "secureEnclaveBacked": policy.protection == "secureEnclaveRequired",
        "selfTestVerified": True,
        "softwareFallbackUsed": False,
        "testingCompilationCondition": False,
        **_proof_provenance(archive),
    }
    if policy.purpose is IdentityEvidencePurpose.CREATED:
        proof["created"] = True
    else:
        proof.update(
            purpose=policy.purpose.value,
            expectedSuite=policy.expected_suite,
            identityDisposition="restored-committed-authority",
            continuity="cold-start-restoration"
            if baseline_archive is None
            else "upgrade-baseline-bound",
            iosReleaseArchive=archive_binding,
            baselineArchive=baseline_archive,
        )
        _validate_existing_proof(
            proof, lifecycle=True, archive_identity=archive_identity
        )
    binding = {
        "schemaVersion": policy.version,
        "profile": PRIVATE_BINDING_PROFILE,
        "identityReference": reference,
        "iosReleaseArchive": archive_binding,
        "lastLaunch": {
            key: second[key] for key in ("processIdentifier", "startTimeToken")
        },
        "lifecycleProof": proof,
    }
    _atomic_new_file(
        private_binding, (json.dumps(binding, indent=2, sort_keys=True) + "\n").encode()
    )
    _atomic_new_file(
        public_proof, (json.dumps(proof, indent=2, sort_keys=True) + "\n").encode()
    )
    validate_lifecycle_proof(public_proof, archive_identity=archive_identity)


def extract_session_proof(
    *,
    lifecycle_binding: Path,
    lifecycle_proof: Path,
    current_raw_oslog: Path,
    current_launch_identity: Path,
    archive_identity: Path,
    product_artifact_dir: Path,
    kind: str,
    output: Path,
    policy: IdentityEvidencePolicy | None = None,
) -> None:
    if policy is None:
        policy = IdentityEvidencePolicy()
    if kind not in FORMAL_KINDS:
        _fail("unsupported product evidence kind")
    binding = _read_private_binding(lifecycle_binding)
    lifecycle = validate_lifecycle_proof(
        lifecycle_proof, archive_identity=archive_identity
    )
    if (
        binding["lifecycleProof"] != lifecycle
        or _policy_from_proof(lifecycle) != policy
    ):
        _fail("selected identity purpose/protection differs from the bound lifecycle")
    current = product_evidence._validate_private_launch_identity(
        current_launch_identity
    )
    if any(
        current[key] == binding["lastLaunch"][key]
        for key in ("processIdentifier", "startTimeToken")
    ):
        _fail("the current product session requires a new exact launch")
    if (
        current["installationBinding"]["iosReleaseArchive"]
        != binding["iosReleaseArchive"]
    ):
        _fail("the current product session has a different installed archive")
    events = _identity_events(current_raw_oslog, current)
    if not 2 <= len(events) <= 5 or events[0].name != "productionIdentityRestored":
        _fail(
            "current product identity must restore before its bounded session terminals"
        )
    restored = _require_exact_event(
        events,
        "productionIdentityRestored",
        (
            "identity_ref",
            "algorithm",
            "protection",
            "persistence",
            "selfTest",
            "result",
        ),
    )
    if (
        restored.fields["persistence"] != "keychain-authority"
        or restored.fields["selfTest"] != "verified"
    ):
        _fail("the current product identity lacks a committed restore and self-test")
    fields = (
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
    )
    if policy.purpose is IdentityEvidencePurpose.EXISTING:
        fields += ("suite", "suite_wire", "localFinished", "peerFinished")
    references: set[str] = set()
    expected_transport = "webrtc" if kind == "webrtc" else "p2p"
    for event in events:
        if _validate_selected_descriptor(event, policy) != binding["identityReference"]:
            _fail("the current session changed its bound production identity")
    for event in events[1:]:
        _require_exact_event([event], "productionIdentityHandshakeBound", fields)
        if (
            event.fields["transport"] != expected_transport
            or SESSION_REFERENCE.fullmatch(event.fields["session_ref"]) is None
            or event.fields["localSignature"] != "used"
            or event.fields["peerVerification"] != "authenticated-finished"
            or event.fields["currentPathAuthority"] != "verified"
        ):
            _fail("identity terminal is not a current authenticated product session")
        attempt = event.fields["attempt_ref"]
        if (
            expected_transport == "p2p" and ATTEMPT_REFERENCE.fullmatch(attempt) is None
        ) or (expected_transport == "webrtc" and attempt != "not-applicable"):
            _fail("identity terminal has an invalid exact attempt owner")
        if policy.purpose is IdentityEvidencePurpose.EXISTING and (
            event.fields["suite"] != Q_AUTHENTICATED_SUITE
            or event.fields["suite_wire"] != policy.expected_suite
            or event.fields["localFinished"] != "sent"
            or event.fields["peerFinished"] != "verified"
        ):
            _fail(
                "existing Q identity terminal lacks its actual suite and both Finished facts"
            )
        if event.fields["session_ref"] in references:
            _fail("identity terminal reuses an authenticated session")
        references.add(event.fields["session_ref"])
    try:
        product_lifecycle.validate_artifact_log(
            product_artifact_dir, kind, expected_suite=policy.expected_suite
        )
    except product_lifecycle.ProductEvidenceError as exc:
        _fail(f"current shipping-product lifecycle is invalid: {exc}")
    observed = product_lifecycle.product_session_references(
        product_artifact_dir, kind, expected_suite=policy.expected_suite
    )
    if not references or observed != references:
        _fail("identity terminals do not bind the same exact Mac/iOS product sessions")
    if kind == "connectivity":
        endpoints = {
            event.fields["session_ref"]: event.fields["attempt_ref"]
            for event in parse_canonical_log(
                product_artifact_dir / IOS_LOG_FILE, expected_owner=IOS_PRODUCT
            )
            if event.name == "connectivityEndpoint"
        }
        if any(
            endpoints[event.fields["session_ref"]] != event.fields["attempt_ref"]
            for event in events[1:]
        ):
            _fail(
                "identity terminal differs from the authenticated connectivity attempt owner"
            )
    proof = {
        key: value
        for key, value in lifecycle.items()
        if key not in {"firstLaunchFresh", "persistence", "selfTestVerified"}
    }
    proof.update(
        binaryTestSurfaceDetected=False,
        currentPathAuthorityVerified=True,
        evidenceSessionRef=min(references),
        handshakePersistenceVerified=True,
        persisted=True,
        signed=True,
        verified=True,
    )
    if policy.purpose is IdentityEvidencePurpose.EXISTING:
        proof.update(
            evidenceSessionRefs=sorted(references),
            localFinishedSent=True,
            peerFinishedVerified=True,
        )
        _validate_existing_proof(
            proof, lifecycle=False, archive_identity=archive_identity
        )
    _atomic_new_file(
        output, (json.dumps(proof, indent=2, sort_keys=True) + "\n").encode()
    )
    validate_public_proof(output, archive_identity=archive_identity)


def _add_policy_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--identity-purpose",
        choices=[purpose.value for purpose in IdentityEvidencePurpose],
        default=IdentityEvidencePurpose.CREATED.value,
    )
    parser.add_argument("--expected-suite", choices=["0x0012"])
    parser.add_argument(
        "--expected-identity-protection",
        choices=["softwareKeychain", "secureEnclaveRequired"],
    )


def _selected_policy(arguments: argparse.Namespace) -> IdentityEvidencePolicy:
    purpose = IdentityEvidencePurpose(arguments.identity_purpose)
    if (
        purpose is IdentityEvidencePurpose.EXISTING
        and arguments.expected_identity_protection is None
    ):
        _fail(
            "existing identity evidence must select its actual committed key protection"
        )
    return IdentityEvidencePolicy(
        purpose,
        arguments.expected_suite,
        arguments.expected_identity_protection or "secureEnclaveRequired",
    )


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
    lifecycle_parser.add_argument("--archive-identity", type=Path)
    _add_policy_arguments(lifecycle_parser)
    policy_parser = subparsers.add_parser(
        "validate-policy",
        description="Validate an explicit identity purpose before any device action.",
    )
    _add_policy_arguments(policy_parser)
    producer = subparsers.add_parser(
        "extract-lifecycle",
        description="Bind two real product identity launches without changing Keychain state.",
    )
    for name in (
        "first-raw-oslog",
        "first-launch-identity",
        "second-raw-oslog",
        "second-launch-identity",
        "archive-identity",
        "private-binding",
        "public-proof",
    ):
        producer.add_argument("--" + name, type=Path, required=True)
    producer.add_argument("--baseline-binding", type=Path)
    _add_policy_arguments(producer)
    session = subparsers.add_parser(
        "extract-session-proof",
        description="Bind the selected lifecycle to the actual current product session.",
    )
    for name in (
        "lifecycle-binding",
        "lifecycle-proof",
        "current-raw-oslog",
        "current-launch-identity",
        "archive-identity",
        "product-artifact-dir",
        "output",
    ):
        session.add_argument("--" + name, type=Path, required=True)
    session.add_argument("--kind", choices=FORMAL_KINDS, required=True)
    _add_policy_arguments(session)
    arguments = parser.parse_args()
    try:
        if arguments.command == "validate-policy":
            _selected_policy(arguments)
        elif arguments.command == "validate-lifecycle-proof":
            proof = validate_lifecycle_proof(
                arguments.proof, archive_identity=arguments.archive_identity
            )
            if _policy_from_proof(proof) != _selected_policy(arguments):
                _fail(
                    "selected identity purpose/protection differs from the lifecycle proof"
                )
        elif arguments.command == "extract-lifecycle":
            extract_lifecycle(
                first_raw_oslog=arguments.first_raw_oslog,
                first_launch_identity=arguments.first_launch_identity,
                second_raw_oslog=arguments.second_raw_oslog,
                second_launch_identity=arguments.second_launch_identity,
                archive_identity=arguments.archive_identity,
                private_binding=arguments.private_binding,
                public_proof=arguments.public_proof,
                policy=_selected_policy(arguments),
                baseline_binding=arguments.baseline_binding,
            )
        elif arguments.command == "extract-session-proof":
            extract_session_proof(
                lifecycle_binding=arguments.lifecycle_binding,
                lifecycle_proof=arguments.lifecycle_proof,
                current_raw_oslog=arguments.current_raw_oslog,
                current_launch_identity=arguments.current_launch_identity,
                archive_identity=arguments.archive_identity,
                product_artifact_dir=arguments.product_artifact_dir,
                kind=arguments.kind,
                output=arguments.output,
                policy=_selected_policy(arguments),
            )
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
