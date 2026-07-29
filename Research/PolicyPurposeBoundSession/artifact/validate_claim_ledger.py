#!/usr/bin/env python3
"""Fail-closed structural validation for the BoundSession claim ledger."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


class ValidationError(ValueError):
    """The claim ledger violates its structural or evidence-state contract."""


ROOT_KEYS = {"schema_version", "research_line", "source_inputs", "claims"}
SOURCE_KEYS = {"revision", "role", "boundary"}
REQUIRED_SOURCE_INPUTS = {"skybridge", "q_periapt"}
CLAIM_KEYS = {
    "id",
    "title",
    "status",
    "required_evidence_classes",
    "claim",
    "boundary",
    "evidence_refs",
    "negative_evidence",
    "last_verified_at",
}
REQUIRED_CLAIM_IDS = {
    "BS-CANONICAL-CONTEXT",
    "BS-POLICY-DECISION-ORIGIN",
    "BS-POLICY-MONOTONICITY",
    "BS-PURPOSE-AUTHORIZATION",
    "BS-LOCAL-PROVIDER-REFINEMENT",
    "BS-LOCAL-CALLER-ISOLATION",
    "BS-SERVICE-BOUND-AGREEMENT",
    "BS-HYBRID-SECRECY",
    "BS-NO-POLICY-BOUND-FALLBACK",
    "BS-NO-CROSS-PURPOSE-KEY-REUSE",
    "BS-CURRENT-OWNER-PUBLICATION",
    "BS-AUTHORIZATION-BEFORE-PUBLICATION",
    "BS-BILATERAL-GRANT-READINESS",
    "BS-TRUSTED-EFFECT-COMMITTER",
    "BS-RECEIPT-EFFECT-CORRESPONDENCE",
    "BS-CODE-CONFORMANCE",
    "BS-FINAL-BINARY-CT",
    "BS-APPLE-PHYSICAL-E2E",
    "BS-NONAPPLE-INTEROP",
    "BS-REMOTE-DESKTOP-RECEIPT",
    "BS-FILE-DURABLE-RECEIPT",
    "BS-PERFORMANCE-NONINFERIORITY",
    "BS-ARTIFACT-BINDING",
    "BS-PUBLICATION",
}
ALLOWED_STATUSES = {
    "design_only",
    "pending",
    "diagnostic",
    "passed",
    "blocked",
    "not_started",
}
ALLOWED_EVIDENCE_CLASSES = {
    "design",
    "formal",
    "implementation",
    "conformance",
    "runtime",
    "device",
    "performance",
    "artifact",
    "publication",
}
REQUIRED_CLAIM_EVIDENCE_CLASSES = {
    "BS-CANONICAL-CONTEXT": frozenset({"design", "conformance"}),
    "BS-POLICY-DECISION-ORIGIN": frozenset(
        {"formal", "implementation", "conformance", "runtime"}
    ),
    "BS-POLICY-MONOTONICITY": frozenset(
        {"formal", "implementation", "runtime"}
    ),
    "BS-PURPOSE-AUTHORIZATION": frozenset(
        {"formal", "implementation", "runtime"}
    ),
    "BS-LOCAL-PROVIDER-REFINEMENT": frozenset(
        {"formal", "implementation", "conformance", "runtime"}
    ),
    "BS-LOCAL-CALLER-ISOLATION": frozenset(
        {"implementation", "runtime", "artifact"}
    ),
    "BS-SERVICE-BOUND-AGREEMENT": frozenset({"formal", "conformance"}),
    "BS-HYBRID-SECRECY": frozenset({"formal", "conformance"}),
    "BS-NO-POLICY-BOUND-FALLBACK": frozenset(
        {"formal", "implementation", "runtime"}
    ),
    "BS-NO-CROSS-PURPOSE-KEY-REUSE": frozenset(
        {"formal", "implementation", "runtime"}
    ),
    "BS-CURRENT-OWNER-PUBLICATION": frozenset(
        {"formal", "implementation", "runtime"}
    ),
    "BS-AUTHORIZATION-BEFORE-PUBLICATION": frozenset(
        {"formal", "implementation", "runtime"}
    ),
    "BS-BILATERAL-GRANT-READINESS": frozenset(
        {"formal", "implementation", "conformance", "runtime"}
    ),
    "BS-TRUSTED-EFFECT-COMMITTER": frozenset(
        {"formal", "implementation", "runtime", "device"}
    ),
    "BS-RECEIPT-EFFECT-CORRESPONDENCE": frozenset(
        {"formal", "implementation", "runtime", "device"}
    ),
    "BS-CODE-CONFORMANCE": frozenset({"conformance"}),
    "BS-FINAL-BINARY-CT": frozenset({"artifact", "runtime"}),
    "BS-APPLE-PHYSICAL-E2E": frozenset({"runtime", "device", "artifact"}),
    "BS-NONAPPLE-INTEROP": frozenset({"runtime", "device", "artifact"}),
    "BS-REMOTE-DESKTOP-RECEIPT": frozenset(
        {"implementation", "runtime", "device", "artifact"}
    ),
    "BS-FILE-DURABLE-RECEIPT": frozenset(
        {"implementation", "runtime", "device", "artifact"}
    ),
    "BS-PERFORMANCE-NONINFERIORITY": frozenset({"performance", "artifact"}),
    "BS-ARTIFACT-BINDING": frozenset({"artifact", "conformance"}),
    "BS-PUBLICATION": frozenset({"publication"}),
}
CLAIM_ID_PATTERN = re.compile(r"^BS-[A-Z0-9]+(?:-[A-Z0-9]+)*$")
REVISION_PATTERN = re.compile(r"^[0-9a-f]{40}$")


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_ledger(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=reject_duplicate_keys)
    if not isinstance(value, dict):
        raise ValidationError("ledger root must be an object")
    return value


def require_exact_keys(value: dict[str, Any], expected: set[str], context: str) -> None:
    actual = set(value)
    missing = sorted(expected - actual)
    unknown = sorted(actual - expected)
    if missing or unknown:
        raise ValidationError(
            f"{context} keys mismatch: missing={missing}, unknown={unknown}"
        )


def require_nonempty_string(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"{context} must be a non-empty string")
    return value


def require_string_list(value: Any, context: str) -> list[str]:
    if not isinstance(value, list):
        raise ValidationError(f"{context} must be a list")
    for index, item in enumerate(value):
        require_nonempty_string(item, f"{context}[{index}]")
    return value


def validate_evidence_ref(reference: str, evidence_root: Path, context: str) -> None:
    if "\x00" in reference:
        raise ValidationError(f"{context} contains a NUL byte")
    reference_path = Path(reference)
    if reference_path.is_absolute() or ".." in reference_path.parts:
        raise ValidationError(f"{context} escapes the evidence root: {reference}")
    if reference_path.as_posix() != reference:
        raise ValidationError(f"{context} is not a canonical relative path: {reference}")

    try:
        root = evidence_root.resolve(strict=True)
    except (OSError, RuntimeError, ValueError) as error:
        raise ValidationError(f"evidence root cannot be resolved: {evidence_root}") from error
    current = root
    for part in reference_path.parts:
        current = current / part
        if current.is_symlink():
            raise ValidationError(f"{context} traverses a symlink: {reference}")
    try:
        candidate = current.resolve(strict=True)
    except (OSError, RuntimeError, ValueError) as error:
        raise ValidationError(
            f"{context} cannot resolve an existing evidence file: {reference}"
        ) from error
    try:
        candidate.relative_to(root)
    except ValueError as error:
        raise ValidationError(
            f"{context} resolves outside the evidence root: {reference}"
        ) from error
    if not candidate.is_file():
        raise ValidationError(f"{context} is not a regular file: {reference}")


def validate_ledger(value: dict[str, Any], *, evidence_root: Path) -> None:
    if not isinstance(evidence_root, Path):
        raise ValidationError("evidence_root must be an explicit pathlib.Path")
    if set(REQUIRED_CLAIM_EVIDENCE_CLASSES) != REQUIRED_CLAIM_IDS:
        raise ValidationError("validator claim and evidence policies are inconsistent")
    require_exact_keys(value, ROOT_KEYS, "ledger")
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise ValidationError("schema_version must be the integer 1")
    require_nonempty_string(value["research_line"], "research_line")

    source_inputs = value["source_inputs"]
    if not isinstance(source_inputs, dict):
        raise ValidationError("source_inputs must be an object")
    require_exact_keys(source_inputs, REQUIRED_SOURCE_INPUTS, "source_inputs")
    for source_name, source in source_inputs.items():
        if not isinstance(source, dict):
            raise ValidationError(f"source_inputs.{source_name} must be an object")
        require_exact_keys(source, SOURCE_KEYS, f"source_inputs.{source_name}")
        revision = require_nonempty_string(
            source["revision"], f"source_inputs.{source_name}.revision"
        )
        if not REVISION_PATTERN.fullmatch(revision):
            raise ValidationError(
                f"source_inputs.{source_name}.revision must be a 40-hex revision"
            )
        if revision == "0" * 40:
            raise ValidationError(
                f"source_inputs.{source_name}.revision cannot be the all-zero sentinel"
            )
        if source["role"] != "reference_only":
            raise ValidationError(
                f"source_inputs.{source_name}.role must equal reference_only"
            )
        require_nonempty_string(
            source["boundary"], f"source_inputs.{source_name}.boundary"
        )

    claims = value["claims"]
    if not isinstance(claims, list) or not claims:
        raise ValidationError("claims must be a non-empty list")
    seen_ids: set[str] = set()
    for index, claim in enumerate(claims):
        context = f"claims[{index}]"
        if not isinstance(claim, dict):
            raise ValidationError(f"{context} must be an object")
        require_exact_keys(claim, CLAIM_KEYS, context)

        claim_id = require_nonempty_string(claim["id"], f"{context}.id")
        if not CLAIM_ID_PATTERN.fullmatch(claim_id):
            raise ValidationError(f"{context}.id is not a canonical BS-* identifier")
        if claim_id in seen_ids:
            raise ValidationError(f"duplicate claim id: {claim_id}")
        seen_ids.add(claim_id)

        require_nonempty_string(claim["title"], f"{context}.title")
        require_nonempty_string(claim["claim"], f"{context}.claim")
        require_nonempty_string(claim["boundary"], f"{context}.boundary")

        status = claim["status"]
        if not isinstance(status, str) or status not in ALLOWED_STATUSES:
            raise ValidationError(f"{context}.status is not allowed: {status!r}")
        if status == "passed":
            raise ValidationError(
                f"{context} uses passed, which is disabled until a manifest-aware "
                "evidence verifier is implemented"
            )

        evidence_classes = require_string_list(
            claim["required_evidence_classes"],
            f"{context}.required_evidence_classes",
        )
        if not evidence_classes:
            raise ValidationError(f"{context}.required_evidence_classes is empty")
        if len(evidence_classes) != len(set(evidence_classes)):
            raise ValidationError(
                f"{context}.required_evidence_classes contains duplicates"
            )
        unknown_classes = sorted(set(evidence_classes) - ALLOWED_EVIDENCE_CLASSES)
        if unknown_classes:
            raise ValidationError(
                f"{context}.required_evidence_classes contains unknown values: "
                f"{unknown_classes}"
            )
        required_classes = REQUIRED_CLAIM_EVIDENCE_CLASSES.get(claim_id)
        if required_classes is None:
            raise ValidationError(f"{context}.id is not in the required claim policy")
        if set(evidence_classes) != required_classes:
            raise ValidationError(
                f"{context}.required_evidence_classes must equal "
                f"{sorted(required_classes)}"
            )
        if status == "design_only" and "design" not in evidence_classes:
            raise ValidationError(f"{context} is design_only without design evidence")

        evidence_refs = require_string_list(
            claim["evidence_refs"], f"{context}.evidence_refs"
        )
        negative_evidence = require_string_list(
            claim["negative_evidence"], f"{context}.negative_evidence"
        )
        if not negative_evidence:
            raise ValidationError(f"{context}.negative_evidence must be non-empty")
        if status == "design_only" and not evidence_refs:
            raise ValidationError(f"{context} is design_only without evidence_refs")
        for ref_index, reference in enumerate(evidence_refs):
            validate_evidence_ref(
                reference,
                evidence_root,
                f"{context}.evidence_refs[{ref_index}]",
            )

        if claim["last_verified_at"] is not None:
            raise ValidationError(
                f"{context} is {status} but carries last_verified_at; verified "
                "timestamps are disabled with passed status"
            )

    missing_claims = sorted(REQUIRED_CLAIM_IDS - seen_ids)
    unknown_claims = sorted(seen_ids - REQUIRED_CLAIM_IDS)
    if missing_claims or unknown_claims:
        raise ValidationError(
            f"claim set mismatch: missing={missing_claims}, unknown={unknown_claims}"
        )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ledger", type=Path, help="path to claim-ledger.json")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        ledger_path = args.ledger.resolve(strict=True)
        ledger = load_ledger(ledger_path)
        validate_ledger(ledger, evidence_root=ledger_path.parents[1])
    except (OSError, json.JSONDecodeError, ValidationError) as error:
        print(f"claim ledger validation failed: {error}", file=sys.stderr)
        return 1
    print(f"claim ledger valid: {len(ledger['claims'])} claims; passed disabled")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
