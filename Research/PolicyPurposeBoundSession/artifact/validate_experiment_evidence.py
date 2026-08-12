#!/usr/bin/env python3
"""Validate a PolicyPurposeBoundSession experiment evidence package.

The JSON Schema defines the portable object shape. This validator additionally
enforces cross-field claim-eligibility rules and re-hashes every declared raw
artifact below one explicit evidence root. It does not attest that an endpoint
or operator reported an event honestly.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any


class ValidationError(ValueError):
    """The manifest violates the experiment evidence contract."""


SCHEMA_VERSION = 1
CONTRACT_ID = "policy-purpose-bound-session/experiment-evidence/v1"
SCHEMA_ID = "urn:skybridge:policy-purpose-bound-session:experiment-evidence:v1"
SCHEMA_PATH = Path(__file__).with_name("experiment-evidence-v1.schema.json")
PREREGISTRATION_DOCUMENT = (
    Path(__file__).parents[1]
    / "experiments"
    / "bidirectional-file-interop-preregistration.md"
)
PRODUCT_SCOPE = "bidirectional_file_transfer_v1"

ROOT_KEYS = {
    "schema_version",
    "contract_id",
    "evidence_id",
    "evidence_class",
    "product_scope",
    "claim_eligible",
    "bindings",
    "related_claim_ids",
    "claimed_claim_ids",
    "preregistration",
    "timing",
    "artifacts",
    "frozen_source",
    "endpoints",
    "transport",
    "cryptography",
    "file_transfers",
    "trust_state",
    "cleanup",
    "unsupported_product_claims",
    "limitations",
}
PREREGISTRATION_KEYS = {
    "run_binding_sha256",
    "registered_at",
    "protocol_document_sha256",
    "protocol_artifact_id",
}
TIMING_KEYS = {"run_started_at", "run_completed_at"}
ARTIFACT_KEYS = {"id", "kind", "path", "sha256", "size_bytes", "media_type"}
BINDINGS_KEYS = {"run_binding_sha256", "session_binding_sha256"}
FROZEN_SOURCE_KEYS = {"repository_id", "commit", "freeze_artifact_id"}
ENDPOINT_KEYS = {
    "id",
    "platform",
    "device_class",
    "execution_environment",
    "device_pseudonym_sha256",
    "device_record_artifact_id",
    "build",
}
BUILD_KEYS = {
    "frozen_commit",
    "product_revision",
    "source_tree_state",
    "binary_sha256",
    "binary_artifact_id",
    "build_record_artifact_id",
}
TRANSPORT_KEYS = BINDINGS_KEYS | {"protocol", "pair_correlation_sha256", "reports"}
ICE_REPORT_KEYS = {
    "run_binding_sha256",
    "session_binding_sha256",
    "endpoint_id",
    "selected",
    "state",
    "candidate_pair_id",
    "local_candidate_type",
    "remote_candidate_type",
    "network_protocol",
    "artifact_id",
}
CRYPTOGRAPHY_KEYS = {
    "run_binding_sha256",
    "session_binding_sha256",
    "protocol_id",
    "suite_id",
    "suite_name",
    "kem_combination",
    "hybrid_profile_id",
    "reports",
}
CRYPTO_REPORT_KEYS = {
    "run_binding_sha256",
    "endpoint_id",
    "authenticated",
    "suite_id",
    "session_binding_sha256",
    "artifact_id",
}
FILE_TRANSFER_KEYS = {
    "run_binding_sha256",
    "session_binding_sha256",
    "transfer_id_sha256",
    "sender_endpoint_id",
    "receiver_endpoint_id",
    "sender_observation",
    "receiver_observation",
    "durable_ack",
    "transfer_record_artifact_id",
}
FILE_OBSERVATION_KEYS = {"bytes", "sha256", "artifact_id"}
DURABLE_ACK_KEYS = {
    "run_binding_sha256",
    "session_binding_sha256",
    "status",
    "authenticated",
    "ack_protocol",
    "durable_commit_observed",
    "durability_primitive",
    "bytes",
    "sha256",
    "commit_artifact_id",
    "ack_artifact_id",
}
TRUST_STATE_KEYS = BINDINGS_KEYS | {"endpoint_id", "before", "after", "unchanged"}
TRUST_SNAPSHOT_KEYS = {
    "semantic_state_sha256",
    "record_count",
    "authority_epoch",
    "artifact_id",
}
CLEANUP_KEYS = {
    "run_binding_sha256",
    "session_binding_sha256",
    "ownership_verified",
    "session_terminated",
    "foreign_resources_touched",
    "records",
}
CLEANUP_RECORD_KEYS = {
    "run_binding_sha256",
    "session_binding_sha256",
    "endpoint_id",
    "owner_binding_sha256",
    "result",
    "artifact_id",
}
UNSUPPORTED_CLAIM_KEYS = {"feature", "status", "reason"}

EVIDENCE_CLASSES = {
    "diagnostic",
    "source_capability",
    "physical_product_interop",
}
ALLOWED_CLAIM_IDS = {
    "BS-APPLE-PHYSICAL-E2E",
    "BS-FILE-DURABLE-RECEIPT",
    "BS-NONAPPLE-INTEROP",
}
ARTIFACT_KINDS = {
    "preregistration",
    "source_freeze",
    "build_record",
    "binary",
    "device_record",
    "selected_ice",
    "pqc_session",
    "file_transfer_record",
    "file_source",
    "file_receiver",
    "durable_commit",
    "durable_ack",
    "trust_snapshot",
    "cleanup_record",
}
PLATFORMS = {"android", "ios", "macos", "windows", "linux"}
APPLE_PLATFORMS = {"ios", "macos"}
DEVICE_CLASSES = {"phone", "tablet", "computer"}
EXECUTION_ENVIRONMENTS = {
    "physical_device",
    "simulator",
    "emulator",
    "virtual_machine",
    "container",
}
ICE_STATES = {"unknown", "checking", "failed", "succeeded"}
CANDIDATE_TYPES = {"unknown", "host", "srflx", "prflx", "relay"}
NETWORK_PROTOCOLS = {"unknown", "udp", "tcp"}
ACK_STATUSES = {"missing", "rejected", "ambiguous", "committed_and_authenticated"}
DURABILITY_PRIMITIVES = {
    "file_and_parent_directory_sync",
    "platform_atomic_file_commit",
    "transactional_durable_store_commit",
}
CLEANUP_RESULTS = {"not_verified", "failed", "owner_verified_and_released"}
UNSUPPORTED_FEATURES = {"messages", "remote_desktop"}

ELIGIBLE_PROTOCOL_ID = "bound-session/1"
ELIGIBLE_SUITE_ID = 0x0012
ELIGIBLE_SUITE_NAME = "Q-Periapt-ABI2-PolicyBound"
ELIGIBLE_KEM_COMBINATION = "ML-KEM-768+X25519"
ELIGIBLE_HYBRID_PROFILE_ID = 2

IDENTIFIER_PATTERN = re.compile(r"^[a-z0-9]+(?:[-_][a-z0-9]+)*$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
REVISION_PATTERN = re.compile(r"^[0-9a-f]{40}$")
UTC_TIMESTAMP_PATTERN = re.compile(
    r"^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
)
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_STRING_CHARACTERS = 4096
MAX_PATH_CHARACTERS = 1024
MAX_LIST_ITEMS = 256
HASH_CHUNK_BYTES = 1024 * 1024
MAX_RAW_JSON_ARTIFACT_BYTES = 256 * 1024
MAX_BINARY_ARTIFACT_BYTES = 1024 * 1024 * 1024
MAX_TOTAL_ARTIFACT_BYTES = 4 * 1024 * 1024 * 1024

RAW_JSON_SCHEMA_BY_KIND = {
    "preregistration": "raw_preregistration",
    "source_freeze": "raw_source_freeze",
    "build_record": "raw_build_record",
    "device_record": "raw_device_record",
    "selected_ice": "raw_selected_ice",
    "pqc_session": "raw_pqc_session",
    "file_transfer_record": "raw_file_transfer_record",
    "durable_commit": "raw_durable_commit",
    "durable_ack": "raw_durable_ack",
    "trust_snapshot": "raw_trust_snapshot",
    "cleanup_record": "raw_cleanup_record",
}


@dataclass(frozen=True)
class ValidatedArtifact:
    """One byte-verified artifact and optional bounded raw JSON bytes."""

    artifact_id: str
    kind: str
    relative_path: str
    sha256: str
    size_bytes: int
    media_type: str
    raw_json_bytes: bytes | None


def contains_control_character(value: str) -> bool:
    return any(
        ord(character) < 0x20 or 0x7F <= ord(character) <= 0x9F
        for character in value
    )


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_nonfinite_json_constant(value: str) -> None:
    raise ValidationError(f"non-finite JSON number is forbidden: {value}")


def load_json_document(path: Path, *, label: str) -> dict[str, Any]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        document_fd = os.open(path, flags)
    except OSError as error:
        raise ValidationError(f"{label} cannot be opened safely: {path}") from error
    _, _, content = read_and_hash_artifact_fd(
        document_fd,
        maximum_bytes=MAX_JSON_BYTES,
        collect_bytes=True,
        context=label,
    )
    if content is None:
        raise ValidationError(f"{label} bytes were not retained for parsing")
    try:
        value = json.loads(
            content.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_nonfinite_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"{label} is not canonical UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise ValidationError(f"{label} root must be an object")
    return value


def json_values_equal(left: Any, right: Any) -> bool:
    """Compare JSON values without treating booleans as integers."""

    if type(left) is not type(right):
        return False
    if isinstance(left, list):
        return len(left) == len(right) and all(
            json_values_equal(left_item, right_item)
            for left_item, right_item in zip(left, right, strict=True)
        )
    if isinstance(left, dict):
        return set(left) == set(right) and all(
            json_values_equal(left[key], right[key]) for key in left
        )
    return left == right


def schema_type_matches(value: Any, expected_type: str) -> bool:
    type_checks = {
        "object": lambda item: isinstance(item, dict),
        "array": lambda item: isinstance(item, list),
        "string": lambda item: isinstance(item, str),
        "boolean": lambda item: type(item) is bool,
        "integer": lambda item: type(item) is int,
        "null": lambda item: item is None,
    }
    check = type_checks.get(expected_type)
    if check is None:
        raise ValidationError(f"JSON Schema uses unsupported type: {expected_type}")
    return check(value)


def resolve_local_schema_ref(schema_root: dict[str, Any], reference: Any) -> dict[str, Any]:
    reference_text = require_safe_text(reference, "JSON Schema $ref", maximum=256)
    prefix = "#/$defs/"
    if not reference_text.startswith(prefix):
        raise ValidationError(f"JSON Schema uses unsupported reference: {reference_text}")
    definition_name = reference_text.removeprefix(prefix)
    if not definition_name or "/" in definition_name or "~" in definition_name:
        raise ValidationError(f"JSON Schema uses non-canonical reference: {reference_text}")
    definitions = schema_root.get("$defs")
    if not isinstance(definitions, dict) or not isinstance(
        definitions.get(definition_name), dict
    ):
        raise ValidationError(f"JSON Schema reference is unresolved: {reference_text}")
    return definitions[definition_name]


def canonical_json_item(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def validate_json_schema_instance(
    value: Any,
    schema: dict[str, Any],
    *,
    schema_root: dict[str, Any] | None = None,
    context: str = "$",
) -> None:
    """Execute the closed JSON Schema Draft 2020-12 subset used by this contract."""

    root = schema if schema_root is None else schema_root
    if "$ref" in schema:
        validate_json_schema_instance(
            value,
            resolve_local_schema_ref(root, schema["$ref"]),
            schema_root=root,
            context=context,
        )
        return

    if "oneOf" in schema:
        matches = 0
        failures: list[str] = []
        for branch in schema["oneOf"]:
            try:
                validate_json_schema_instance(
                    value, branch, schema_root=root, context=context
                )
            except ValidationError as error:
                failures.append(str(error))
            else:
                matches += 1
        if matches != 1:
            detail = failures[0] if failures else "multiple branches matched"
            raise ValidationError(
                f"JSON Schema validation failed at {context}: oneOf matched "
                f"{matches} branches; {detail}"
            )
        return

    if "const" in schema and not json_values_equal(value, schema["const"]):
        raise ValidationError(
            f"JSON Schema validation failed at {context}: value differs from const"
        )
    if "enum" in schema and not any(
        json_values_equal(value, candidate) for candidate in schema["enum"]
    ):
        raise ValidationError(
            f"JSON Schema validation failed at {context}: value is outside enum"
        )
    expected_type = schema.get("type")
    if expected_type is not None and not schema_type_matches(value, expected_type):
        raise ValidationError(
            f"JSON Schema validation failed at {context}: expected {expected_type}"
        )

    if isinstance(value, dict):
        required = schema.get("required", [])
        missing = [key for key in required if key not in value]
        if missing:
            raise ValidationError(
                f"JSON Schema validation failed at {context}: missing required "
                f"properties {missing}"
            )
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            unknown = sorted(set(value) - set(properties))
            if unknown:
                raise ValidationError(
                    f"JSON Schema validation failed at {context}: additional "
                    f"properties are forbidden: {unknown}"
                )
        for key, child_schema in properties.items():
            if key in value:
                validate_json_schema_instance(
                    value[key],
                    child_schema,
                    schema_root=root,
                    context=f"{context}.{key}",
                )

    if isinstance(value, list):
        minimum_items = schema.get("minItems")
        maximum_items = schema.get("maxItems")
        if minimum_items is not None and len(value) < minimum_items:
            raise ValidationError(
                f"JSON Schema validation failed at {context}: too few items"
            )
        if maximum_items is not None and len(value) > maximum_items:
            raise ValidationError(
                f"JSON Schema validation failed at {context}: too many items"
            )
        if schema.get("uniqueItems") is True:
            canonical_items = [canonical_json_item(item) for item in value]
            if len(canonical_items) != len(set(canonical_items)):
                raise ValidationError(
                    f"JSON Schema validation failed at {context}: items are not unique"
                )
        if "items" in schema:
            for index, item in enumerate(value):
                validate_json_schema_instance(
                    item,
                    schema["items"],
                    schema_root=root,
                    context=f"{context}[{index}]",
                )

    if isinstance(value, str):
        minimum_length = schema.get("minLength")
        maximum_length = schema.get("maxLength")
        if minimum_length is not None and len(value) < minimum_length:
            raise ValidationError(
                f"JSON Schema validation failed at {context}: string is too short"
            )
        if maximum_length is not None and len(value) > maximum_length:
            raise ValidationError(
                f"JSON Schema validation failed at {context}: string is too long"
            )
        pattern = schema.get("pattern")
        if pattern is not None and re.search(pattern, value) is None:
            raise ValidationError(
                f"JSON Schema validation failed at {context}: pattern mismatch"
            )

    if type(value) is int:
        minimum = schema.get("minimum")
        maximum = schema.get("maximum")
        if minimum is not None and value < minimum:
            raise ValidationError(
                f"JSON Schema validation failed at {context}: below minimum"
            )
        if maximum is not None and value > maximum:
            raise ValidationError(
                f"JSON Schema validation failed at {context}: above maximum"
            )


SCHEMA_ANNOTATION_KEYS = {"$schema", "$id", "title", "description"}
SCHEMA_VALIDATION_KEYS = {
    "$ref",
    "oneOf",
    "const",
    "enum",
    "type",
    "additionalProperties",
    "required",
    "properties",
    "items",
    "minItems",
    "maxItems",
    "uniqueItems",
    "minLength",
    "maxLength",
    "pattern",
    "minimum",
    "maximum",
}
SCHEMA_STRING_KEYWORDS = {"$schema", "$id", "title", "description", "$ref", "type", "pattern"}
SCHEMA_BOOLEAN_KEYWORDS = {"additionalProperties", "uniqueItems"}
SCHEMA_NONNEGATIVE_INTEGER_KEYWORDS = {
    "minItems",
    "maxItems",
    "minLength",
    "maxLength",
    "minimum",
    "maximum",
}


def audit_schema_keyword_types(schema: dict[str, Any], context: str) -> None:
    for keyword in SCHEMA_STRING_KEYWORDS & set(schema):
        if not isinstance(schema[keyword], str):
            raise ValidationError(f"{context}.{keyword} must be a string")
    for keyword in SCHEMA_BOOLEAN_KEYWORDS & set(schema):
        if type(schema[keyword]) is not bool:
            raise ValidationError(f"{context}.{keyword} must be a boolean")
    for keyword in SCHEMA_NONNEGATIVE_INTEGER_KEYWORDS & set(schema):
        value = schema[keyword]
        if type(value) is not int or value < 0:
            raise ValidationError(
                f"{context}.{keyword} must be a non-negative integer"
            )
    for keyword in ("required", "enum", "oneOf"):
        if keyword in schema and not isinstance(schema[keyword], list):
            raise ValidationError(f"{context}.{keyword} must be an array")
    if "required" in schema:
        required = schema["required"]
        if any(not isinstance(item, str) for item in required):
            raise ValidationError(f"{context}.required must contain only strings")
        if len(required) != len(set(required)):
            raise ValidationError(f"{context}.required must not contain duplicates")
    if "enum" in schema:
        if not schema["enum"]:
            raise ValidationError(f"{context}.enum must be non-empty")
        encoded = [canonical_json_item(item) for item in schema["enum"]]
        if len(encoded) != len(set(encoded)):
            raise ValidationError(f"{context}.enum must not contain duplicates")
    if "oneOf" in schema and not schema["oneOf"]:
        raise ValidationError(f"{context}.oneOf must be non-empty")
    if "type" in schema and schema["type"] not in {
        "object",
        "array",
        "string",
        "boolean",
        "integer",
        "null",
    }:
        raise ValidationError(f"{context}.type is not supported")
    if "pattern" in schema:
        try:
            re.compile(schema["pattern"])
        except re.error as error:
            raise ValidationError(f"{context}.pattern is invalid") from error
    for minimum_key, maximum_key in (
        ("minItems", "maxItems"),
        ("minLength", "maxLength"),
        ("minimum", "maximum"),
    ):
        if (
            minimum_key in schema
            and maximum_key in schema
            and schema[minimum_key] > schema[maximum_key]
        ):
            raise ValidationError(
                f"{context}.{minimum_key} cannot exceed {maximum_key}"
            )


def audit_schema_keyword_applicability(schema: dict[str, Any], context: str) -> None:
    schema_type = schema.get("type")
    keyword_types = {
        "object": {"additionalProperties", "required", "properties"},
        "array": {"items", "minItems", "maxItems", "uniqueItems"},
        "string": {"minLength", "maxLength", "pattern"},
        "integer": {"minimum", "maximum"},
    }
    for required_type, keywords in keyword_types.items():
        present = keywords & set(schema)
        if present and schema_type != required_type:
            raise ValidationError(
                f"{context} uses {sorted(present)} without type={required_type}"
            )


def audit_supported_schema(schema: dict[str, Any], context: str = "schema") -> None:
    """Reject schema drift that the bundled executor would otherwise ignore."""

    allowed = SCHEMA_ANNOTATION_KEYS | SCHEMA_VALIDATION_KEYS | {"$defs"}
    unknown = sorted(set(schema) - allowed)
    if unknown:
        raise ValidationError(f"{context} uses unsupported keywords: {unknown}")
    audit_schema_keyword_types(schema, context)
    audit_schema_keyword_applicability(schema, context)
    if "$ref" in schema and set(schema) != {"$ref"}:
        raise ValidationError(f"{context} must not combine $ref with sibling keywords")
    if "oneOf" in schema and set(schema) != {"oneOf"}:
        raise ValidationError(f"{context} must not combine oneOf with sibling keywords")
    if schema.get("type") == "object":
        if schema.get("additionalProperties") is not False:
            raise ValidationError(f"{context} must set additionalProperties=false")
        properties = schema.get("properties")
        required = schema.get("required")
        if not isinstance(properties, dict) or not isinstance(required, list):
            raise ValidationError(f"{context} must declare properties and required")
        if len(required) != len(set(required)) or set(required) != set(properties):
            raise ValidationError(
                f"{context} must require every declared property exactly once"
            )
    for container_name in ("properties", "$defs"):
        container = schema.get(container_name, {})
        if not isinstance(container, dict):
            raise ValidationError(f"{context}.{container_name} must be an object")
        for name, child in container.items():
            if not isinstance(child, dict):
                raise ValidationError(f"{context}.{container_name}.{name} must be an object")
            audit_supported_schema(child, f"{context}.{container_name}.{name}")
    for index, child in enumerate(schema.get("oneOf", [])):
        if not isinstance(child, dict):
            raise ValidationError(f"{context}.oneOf[{index}] must be an object")
        audit_supported_schema(child, f"{context}.oneOf[{index}]")
    if "items" in schema:
        child = schema["items"]
        if not isinstance(child, dict):
            raise ValidationError(f"{context}.items must be an object")
        audit_supported_schema(child, f"{context}.items")


def require_exact_keys(value: Any, expected: set[str], context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValidationError(f"{context} must be an object")
    actual = set(value)
    if actual != expected:
        raise ValidationError(
            f"{context} keys mismatch: missing={sorted(expected - actual)}, "
            f"unknown={sorted(actual - expected)}"
        )
    return value


def require_safe_text(value: Any, context: str, *, maximum: int = MAX_STRING_CHARACTERS) -> str:
    if (
        not isinstance(value, str)
        or not value.strip()
        or value != value.strip()
        or len(value) > maximum
        or contains_control_character(value)
    ):
        raise ValidationError(f"{context} must be safe non-empty trimmed text")
    return value


def require_identifier(value: Any, context: str) -> str:
    identifier = require_safe_text(value, context, maximum=128)
    if not IDENTIFIER_PATTERN.fullmatch(identifier):
        raise ValidationError(f"{context} must be a canonical identifier")
    return identifier


def require_sha256(value: Any, context: str) -> str:
    digest = require_safe_text(value, context, maximum=64)
    if not SHA256_PATTERN.fullmatch(digest):
        raise ValidationError(f"{context} must be a lowercase SHA-256 digest")
    if digest == "0" * 64:
        raise ValidationError(f"{context} cannot be the all-zero sentinel")
    return digest


def require_optional_sha256(value: Any, context: str) -> str | None:
    if value is None:
        return None
    return require_sha256(value, context)


def require_revision(value: Any, context: str) -> str:
    revision = require_safe_text(value, context, maximum=40)
    if not REVISION_PATTERN.fullmatch(revision):
        raise ValidationError(f"{context} must be a 40-character lowercase Git revision")
    if revision == "0" * 40:
        raise ValidationError(f"{context} cannot be the all-zero sentinel")
    return revision


def require_bool(value: Any, context: str) -> bool:
    if type(value) is not bool:
        raise ValidationError(f"{context} must be a boolean")
    return value


def require_nonnegative_int(value: Any, context: str) -> int:
    if type(value) is not int or value < 0:
        raise ValidationError(f"{context} must be a non-negative integer")
    return value


def require_positive_u16(value: Any, context: str) -> int:
    integer = require_nonnegative_int(value, context)
    if integer == 0 or integer > 0xFFFF:
        raise ValidationError(f"{context} must be an integer in 1..65535")
    return integer


def require_list(value: Any, context: str, *, maximum: int = MAX_LIST_ITEMS) -> list[Any]:
    if not isinstance(value, list) or len(value) > maximum:
        raise ValidationError(f"{context} must be a list with at most {maximum} items")
    return value


def require_unique_strings(value: Any, context: str, *, maximum: int) -> list[str]:
    items = require_list(value, context, maximum=maximum)
    result = [require_safe_text(item, f"{context}[{index}]") for index, item in enumerate(items)]
    if len(result) != len(set(result)):
        raise ValidationError(f"{context} must not contain duplicates")
    return result


def parse_utc_timestamp(value: Any, context: str) -> datetime:
    timestamp = require_safe_text(value, context, maximum=20)
    if not UTC_TIMESTAMP_PATTERN.fullmatch(timestamp):
        raise ValidationError(f"{context} must use canonical UTC YYYY-MM-DDTHH:MM:SSZ")
    try:
        parsed = datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise ValidationError(f"{context} must be a real UTC timestamp") from error
    return parsed.replace(tzinfo=timezone.utc)


def validate_relative_path(value: Any, context: str) -> str:
    path_text = require_safe_text(value, context, maximum=MAX_PATH_CHARACTERS)
    if "\\" in path_text:
        raise ValidationError(f"{context} must use POSIX separators")
    path = PurePosixPath(path_text)
    if (
        path_text == "."
        or path.is_absolute()
        or ".." in path.parts
        or path.as_posix() != path_text
    ):
        raise ValidationError(f"{context} must be a canonical relative POSIX path")
    return path_text


def artifact_size_limit(kind: str) -> int:
    if kind in RAW_JSON_SCHEMA_BY_KIND:
        return MAX_RAW_JSON_ARTIFACT_BYTES
    return MAX_BINARY_ARTIFACT_BYTES


def open_artifact_fd(artifact_root: Path, relative_path: str, context: str) -> int:
    """Open one artifact through directory FDs without following symlinks."""

    required_flags = ("O_DIRECTORY", "O_NOFOLLOW", "O_NONBLOCK")
    if any(not hasattr(os, flag) for flag in required_flags):
        raise ValidationError("platform lacks required no-follow artifact-open support")
    try:
        root = artifact_root.resolve(strict=True)
    except (OSError, RuntimeError, ValueError) as error:
        raise ValidationError(f"artifact root cannot be resolved: {artifact_root}") from error
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    file_flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    if hasattr(os, "O_CLOEXEC"):
        directory_flags |= os.O_CLOEXEC
        file_flags |= os.O_CLOEXEC

    components = PurePosixPath(relative_path).parts
    directory_fd = -1
    try:
        directory_fd = os.open(root, directory_flags)
        for component in components[:-1]:
            next_fd = os.open(component, directory_flags, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd
        artifact_fd = os.open(components[-1], file_flags, dir_fd=directory_fd)
    except OSError as error:
        raise ValidationError(
            f"{context} cannot be opened safely below the evidence root: {relative_path}"
        ) from error
    finally:
        if directory_fd >= 0:
            os.close(directory_fd)
    return artifact_fd


def read_and_hash_artifact_fd(
    artifact_fd: int,
    *,
    maximum_bytes: int,
    collect_bytes: bool,
    context: str,
) -> tuple[str, os.stat_result, bytes | None]:
    digest = hashlib.sha256()
    collected = bytearray() if collect_bytes else None
    bytes_read = 0
    try:
        before = os.fstat(artifact_fd)
        if not stat.S_ISREG(before.st_mode):
            raise ValidationError(f"{context} is not a regular file")
        if before.st_nlink != 1:
            raise ValidationError(f"{context} must have exactly one hard link")
        if before.st_size > maximum_bytes:
            raise ValidationError(
                f"{context} exceeds its {maximum_bytes}-byte artifact limit"
            )
        while chunk := os.read(artifact_fd, HASH_CHUNK_BYTES):
            bytes_read += len(chunk)
            if bytes_read > maximum_bytes:
                raise ValidationError(
                    f"{context} exceeds its {maximum_bytes}-byte artifact limit"
                )
            digest.update(chunk)
            if collected is not None:
                collected.extend(chunk)
        after = os.fstat(artifact_fd)
    finally:
        os.close(artifact_fd)
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
        raise ValidationError(f"{context} changed while it was being hashed")
    return digest.hexdigest(), after, bytes(collected) if collected is not None else None


def preregistration_document_sha256() -> str:
    required_flags = ("O_NOFOLLOW", "O_NONBLOCK")
    if any(not hasattr(os, flag) for flag in required_flags):
        raise ValidationError("platform lacks required no-follow file-open support")
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        document_fd = os.open(PREREGISTRATION_DOCUMENT, flags)
    except OSError as error:
        raise ValidationError(
            f"canonical preregistration document cannot be opened: "
            f"{PREREGISTRATION_DOCUMENT}"
        ) from error
    digest, _, _ = read_and_hash_artifact_fd(
        document_fd,
        maximum_bytes=MAX_JSON_BYTES,
        collect_bytes=False,
        context="canonical preregistration document",
    )
    return digest


def validate_artifacts(
    value: Any, *, artifact_root: Path
) -> dict[str, ValidatedArtifact]:
    items = require_list(value, "artifacts")
    if not items:
        raise ValidationError("artifacts must be non-empty")
    declared_sizes = [
        require_nonnegative_int(item.get("size_bytes") if isinstance(item, dict) else None,
                                f"artifacts[{index}].size_bytes")
        for index, item in enumerate(items)
    ]
    if sum(declared_sizes) > MAX_TOTAL_ARTIFACT_BYTES:
        raise ValidationError(
            f"artifacts exceed the {MAX_TOTAL_ARTIFACT_BYTES}-byte package limit"
        )
    records: dict[str, ValidatedArtifact] = {}
    seen_paths: set[str] = set()
    seen_file_identities: set[tuple[int, int]] = set()
    for index, item in enumerate(items):
        context = f"artifacts[{index}]"
        artifact = require_exact_keys(item, ARTIFACT_KEYS, context)
        artifact_id = require_identifier(artifact["id"], f"{context}.id")
        if artifact_id in records:
            raise ValidationError(f"duplicate artifact id: {artifact_id}")
        kind = require_safe_text(artifact["kind"], f"{context}.kind")
        if kind not in ARTIFACT_KINDS:
            raise ValidationError(f"{context}.kind is not allowed")
        relative_path = validate_relative_path(artifact["path"], f"{context}.path")
        if relative_path in seen_paths:
            raise ValidationError(f"duplicate artifact path: {relative_path}")
        seen_paths.add(relative_path)
        expected_digest = require_sha256(artifact["sha256"], f"{context}.sha256")
        expected_size = require_nonnegative_int(
            artifact["size_bytes"], f"{context}.size_bytes"
        )
        maximum_bytes = artifact_size_limit(kind)
        if expected_size > maximum_bytes:
            raise ValidationError(
                f"{context} exceeds its {maximum_bytes}-byte artifact limit"
            )
        media_type = require_safe_text(
            artifact["media_type"], f"{context}.media_type", maximum=256
        )
        if kind in RAW_JSON_SCHEMA_BY_KIND and media_type != "application/json":
            raise ValidationError(f"{context} raw record must use application/json")

        artifact_fd = open_artifact_fd(artifact_root, relative_path, context)
        actual_digest, artifact_stat, raw_json_bytes = read_and_hash_artifact_fd(
            artifact_fd,
            maximum_bytes=maximum_bytes,
            collect_bytes=kind in RAW_JSON_SCHEMA_BY_KIND,
            context=context,
        )
        actual_size = artifact_stat.st_size
        if actual_size != expected_size:
            raise ValidationError(
                f"{context} size mismatch: manifest={expected_size}, actual={actual_size}"
            )
        if actual_digest != expected_digest:
            raise ValidationError(f"{context} SHA-256 mismatch for {relative_path}")
        file_identity = (artifact_stat.st_dev, artifact_stat.st_ino)
        if file_identity in seen_file_identities:
            raise ValidationError(
                f"{context} aliases another artifact file: {relative_path}"
            )
        seen_file_identities.add(file_identity)
        if expected_size == 0 and kind not in {"file_source", "file_receiver"}:
            raise ValidationError(f"{context} cannot use an empty {kind} artifact")
        records[artifact_id] = ValidatedArtifact(
            artifact_id=artifact_id,
            kind=kind,
            relative_path=relative_path,
            sha256=expected_digest,
            size_bytes=expected_size,
            media_type=media_type,
            raw_json_bytes=raw_json_bytes,
        )
    return records


def require_artifact_ref(
    value: Any,
    *,
    expected_kind: str,
    artifacts: dict[str, ValidatedArtifact],
    referenced: set[str],
    context: str,
) -> ValidatedArtifact:
    artifact_id = require_identifier(value, context)
    artifact = artifacts.get(artifact_id)
    if artifact is None:
        raise ValidationError(f"{context} references unknown artifact: {artifact_id}")
    if artifact.kind != expected_kind:
        raise ValidationError(
            f"{context} must reference {expected_kind}, got {artifact.kind}"
        )
    referenced.add(artifact_id)
    return artifact


def require_optional_artifact_ref(
    value: Any,
    *,
    expected_kind: str,
    artifacts: dict[str, ValidatedArtifact],
    referenced: set[str],
    context: str,
) -> ValidatedArtifact | None:
    if value is None:
        return None
    return require_artifact_ref(
        value,
        expected_kind=expected_kind,
        artifacts=artifacts,
        referenced=referenced,
        context=context,
    )


def validate_preregistration_and_timing(
    preregistration_value: Any,
    timing_value: Any,
    *,
    artifacts: dict[str, ValidatedArtifact],
    referenced: set[str],
) -> None:
    preregistration = require_exact_keys(
        preregistration_value, PREREGISTRATION_KEYS, "preregistration"
    )
    registered_at = parse_utc_timestamp(
        preregistration["registered_at"], "preregistration.registered_at"
    )
    require_sha256(
        preregistration["run_binding_sha256"],
        "preregistration.run_binding_sha256",
    )
    protocol_digest = require_sha256(
        preregistration["protocol_document_sha256"],
        "preregistration.protocol_document_sha256",
    )
    if protocol_digest != preregistration_document_sha256():
        raise ValidationError(
            "preregistration.protocol_document_sha256 does not bind the canonical "
            "experiment protocol"
        )
    require_artifact_ref(
        preregistration["protocol_artifact_id"],
        expected_kind="preregistration",
        artifacts=artifacts,
        referenced=referenced,
        context="preregistration.protocol_artifact_id",
    )

    timing = require_exact_keys(timing_value, TIMING_KEYS, "timing")
    started_at = parse_utc_timestamp(timing["run_started_at"], "timing.run_started_at")
    completed_at = parse_utc_timestamp(
        timing["run_completed_at"], "timing.run_completed_at"
    )
    if not registered_at < started_at:
        raise ValidationError("preregistration must precede the run start")
    if not started_at < completed_at:
        raise ValidationError("run completion must follow the run start")


def validate_bindings(value: Any) -> dict[str, str]:
    bindings = require_exact_keys(value, BINDINGS_KEYS, "bindings")
    run_binding = require_sha256(
        bindings["run_binding_sha256"], "bindings.run_binding_sha256"
    )
    session_binding = require_sha256(
        bindings["session_binding_sha256"], "bindings.session_binding_sha256"
    )
    if run_binding == session_binding:
        raise ValidationError("run and session bindings must be distinct")
    return bindings


def validate_binding_continuity(
    manifest: dict[str, Any], bindings: dict[str, str]
) -> None:
    if manifest["preregistration"]["run_binding_sha256"] != bindings[
        "run_binding_sha256"
    ]:
        raise ValidationError(
            "preregistration does not use the manifest run binding"
        )
    bound_records: list[tuple[str, dict[str, Any]]] = []
    transport = manifest["transport"]
    if transport is not None:
        bound_records.append(("transport", transport))
        bound_records.extend(
            (f"transport.reports[{index}]", report)
            for index, report in enumerate(transport["reports"])
        )
    cryptography = manifest["cryptography"]
    if cryptography is not None:
        bound_records.append(("cryptography", cryptography))
        bound_records.extend(
            (f"cryptography.reports[{index}]", report)
            for index, report in enumerate(cryptography["reports"])
        )
    for index, transfer in enumerate(manifest["file_transfers"]):
        bound_records.append((f"file_transfers[{index}]", transfer))
        bound_records.append(
            (f"file_transfers[{index}].durable_ack", transfer["durable_ack"])
        )
    bound_records.extend(
        (f"trust_state[{index}]", record)
        for index, record in enumerate(manifest["trust_state"])
    )
    cleanup = manifest["cleanup"]
    if cleanup is not None:
        bound_records.append(("cleanup", cleanup))
        bound_records.extend(
            (f"cleanup.records[{index}]", record)
            for index, record in enumerate(cleanup["records"])
        )

    for context, record in bound_records:
        actual = {
            "run_binding_sha256": record["run_binding_sha256"],
            "session_binding_sha256": record["session_binding_sha256"],
        }
        if actual != bindings:
            raise ValidationError(
                f"{context} does not use the manifest run/session bindings"
            )


def validate_frozen_source(
    value: Any,
    *,
    artifacts: dict[str, ValidatedArtifact],
    referenced: set[str],
) -> dict[str, Any] | None:
    if value is None:
        return None
    source = require_exact_keys(value, FROZEN_SOURCE_KEYS, "frozen_source")
    require_identifier(source["repository_id"], "frozen_source.repository_id")
    require_revision(source["commit"], "frozen_source.commit")
    require_artifact_ref(
        source["freeze_artifact_id"],
        expected_kind="source_freeze",
        artifacts=artifacts,
        referenced=referenced,
        context="frozen_source.freeze_artifact_id",
    )
    return source


def validate_build(
    value: Any,
    *,
    artifacts: dict[str, ValidatedArtifact],
    referenced: set[str],
    context: str,
) -> dict[str, Any] | None:
    if value is None:
        return None
    build = require_exact_keys(value, BUILD_KEYS, context)
    require_revision(build["frozen_commit"], f"{context}.frozen_commit")
    require_revision(build["product_revision"], f"{context}.product_revision")
    source_tree_state = require_safe_text(
        build["source_tree_state"], f"{context}.source_tree_state"
    )
    if source_tree_state not in {"clean", "dirty", "unknown"}:
        raise ValidationError(f"{context}.source_tree_state is not allowed")
    binary_digest = require_sha256(build["binary_sha256"], f"{context}.binary_sha256")
    binary_artifact = require_artifact_ref(
        build["binary_artifact_id"],
        expected_kind="binary",
        artifacts=artifacts,
        referenced=referenced,
        context=f"{context}.binary_artifact_id",
    )
    if binary_artifact.sha256 != binary_digest:
        raise ValidationError(f"{context}.binary_sha256 does not match the binary artifact")
    require_artifact_ref(
        build["build_record_artifact_id"],
        expected_kind="build_record",
        artifacts=artifacts,
        referenced=referenced,
        context=f"{context}.build_record_artifact_id",
    )
    return build


def validate_endpoints(
    value: Any,
    *,
    artifacts: dict[str, ValidatedArtifact],
    referenced: set[str],
) -> dict[str, dict[str, Any]]:
    items = require_list(value, "endpoints", maximum=2)
    endpoints: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(items):
        context = f"endpoints[{index}]"
        endpoint = require_exact_keys(item, ENDPOINT_KEYS, context)
        endpoint_id = require_identifier(endpoint["id"], f"{context}.id")
        if endpoint_id in endpoints:
            raise ValidationError(f"duplicate endpoint id: {endpoint_id}")
        platform = require_safe_text(endpoint["platform"], f"{context}.platform")
        if platform not in PLATFORMS:
            raise ValidationError(f"{context}.platform is not allowed")
        device_class = require_safe_text(
            endpoint["device_class"], f"{context}.device_class"
        )
        if device_class not in DEVICE_CLASSES:
            raise ValidationError(f"{context}.device_class is not allowed")
        environment = require_safe_text(
            endpoint["execution_environment"], f"{context}.execution_environment"
        )
        if environment not in EXECUTION_ENVIRONMENTS:
            raise ValidationError(f"{context}.execution_environment is not allowed")
        require_optional_sha256(
            endpoint["device_pseudonym_sha256"],
            f"{context}.device_pseudonym_sha256",
        )
        require_optional_artifact_ref(
            endpoint["device_record_artifact_id"],
            expected_kind="device_record",
            artifacts=artifacts,
            referenced=referenced,
            context=f"{context}.device_record_artifact_id",
        )
        build = validate_build(
            endpoint["build"],
            artifacts=artifacts,
            referenced=referenced,
            context=f"{context}.build",
        )
        endpoint["build"] = build
        endpoints[endpoint_id] = endpoint
    return endpoints


def validate_transport(
    value: Any,
    *,
    endpoint_ids: set[str],
    artifacts: dict[str, ValidatedArtifact],
    referenced: set[str],
) -> dict[str, Any] | None:
    if value is None:
        return None
    transport = require_exact_keys(value, TRANSPORT_KEYS, "transport")
    if transport["protocol"] != "webrtc_data_channel":
        raise ValidationError("transport.protocol must equal webrtc_data_channel")
    require_optional_sha256(
        transport["pair_correlation_sha256"], "transport.pair_correlation_sha256"
    )
    reports = require_list(transport["reports"], "transport.reports", maximum=2)
    seen_endpoints: set[str] = set()
    for index, item in enumerate(reports):
        context = f"transport.reports[{index}]"
        report = require_exact_keys(item, ICE_REPORT_KEYS, context)
        endpoint_id = require_identifier(report["endpoint_id"], f"{context}.endpoint_id")
        if endpoint_id not in endpoint_ids:
            raise ValidationError(f"{context}.endpoint_id is not a declared endpoint")
        if endpoint_id in seen_endpoints:
            raise ValidationError(f"transport.reports repeats endpoint: {endpoint_id}")
        seen_endpoints.add(endpoint_id)
        require_bool(report["selected"], f"{context}.selected")
        state = require_safe_text(report["state"], f"{context}.state")
        if state not in ICE_STATES:
            raise ValidationError(f"{context}.state is not allowed")
        if report["candidate_pair_id"] is not None:
            require_safe_text(
                report["candidate_pair_id"], f"{context}.candidate_pair_id", maximum=256
            )
        for field in ("local_candidate_type", "remote_candidate_type"):
            candidate_type = require_safe_text(report[field], f"{context}.{field}")
            if candidate_type not in CANDIDATE_TYPES:
                raise ValidationError(f"{context}.{field} is not allowed")
        network_protocol = require_safe_text(
            report["network_protocol"], f"{context}.network_protocol"
        )
        if network_protocol not in NETWORK_PROTOCOLS:
            raise ValidationError(f"{context}.network_protocol is not allowed")
        require_artifact_ref(
            report["artifact_id"],
            expected_kind="selected_ice",
            artifacts=artifacts,
            referenced=referenced,
            context=f"{context}.artifact_id",
        )
    return transport


def validate_cryptography(
    value: Any,
    *,
    endpoint_ids: set[str],
    artifacts: dict[str, ValidatedArtifact],
    referenced: set[str],
) -> dict[str, Any] | None:
    if value is None:
        return None
    cryptography = require_exact_keys(value, CRYPTOGRAPHY_KEYS, "cryptography")
    require_safe_text(cryptography["protocol_id"], "cryptography.protocol_id")
    require_positive_u16(cryptography["suite_id"], "cryptography.suite_id")
    require_safe_text(cryptography["suite_name"], "cryptography.suite_name")
    require_safe_text(cryptography["kem_combination"], "cryptography.kem_combination")
    require_positive_u16(
        cryptography["hybrid_profile_id"], "cryptography.hybrid_profile_id"
    )
    reports = require_list(cryptography["reports"], "cryptography.reports", maximum=2)
    seen_endpoints: set[str] = set()
    for index, item in enumerate(reports):
        context = f"cryptography.reports[{index}]"
        report = require_exact_keys(item, CRYPTO_REPORT_KEYS, context)
        endpoint_id = require_identifier(report["endpoint_id"], f"{context}.endpoint_id")
        if endpoint_id not in endpoint_ids:
            raise ValidationError(f"{context}.endpoint_id is not a declared endpoint")
        if endpoint_id in seen_endpoints:
            raise ValidationError(f"cryptography.reports repeats endpoint: {endpoint_id}")
        seen_endpoints.add(endpoint_id)
        require_bool(report["authenticated"], f"{context}.authenticated")
        require_positive_u16(report["suite_id"], f"{context}.suite_id")
        require_optional_sha256(
            report["session_binding_sha256"], f"{context}.session_binding_sha256"
        )
        require_artifact_ref(
            report["artifact_id"],
            expected_kind="pqc_session",
            artifacts=artifacts,
            referenced=referenced,
            context=f"{context}.artifact_id",
        )
    return cryptography


def validate_file_observation(
    value: Any,
    *,
    expected_kind: str,
    artifacts: dict[str, ValidatedArtifact],
    referenced: set[str],
    context: str,
) -> dict[str, Any]:
    observation = require_exact_keys(value, FILE_OBSERVATION_KEYS, context)
    byte_count = require_nonnegative_int(observation["bytes"], f"{context}.bytes")
    digest = require_sha256(observation["sha256"], f"{context}.sha256")
    artifact = require_artifact_ref(
        observation["artifact_id"],
        expected_kind=expected_kind,
        artifacts=artifacts,
        referenced=referenced,
        context=f"{context}.artifact_id",
    )
    if artifact.size_bytes != byte_count:
        raise ValidationError(f"{context}.bytes does not match its raw file artifact")
    if artifact.sha256 != digest:
        raise ValidationError(f"{context}.sha256 does not match its raw file artifact")
    return observation


def validate_durable_ack(
    value: Any,
    *,
    artifacts: dict[str, ValidatedArtifact],
    referenced: set[str],
    context: str,
) -> dict[str, Any]:
    ack = require_exact_keys(value, DURABLE_ACK_KEYS, context)
    status = require_safe_text(ack["status"], f"{context}.status")
    if status not in ACK_STATUSES:
        raise ValidationError(f"{context}.status is not allowed")
    authenticated = require_bool(ack["authenticated"], f"{context}.authenticated")
    if ack["ack_protocol"] is not None and (
        ack["ack_protocol"] != "bound_session_effect_receipt_v1"
    ):
        raise ValidationError(f"{context}.ack_protocol is not allowed")
    durable = require_bool(
        ack["durable_commit_observed"], f"{context}.durable_commit_observed"
    )
    durability_primitive = ack["durability_primitive"]
    if durability_primitive is not None:
        durability_primitive = require_safe_text(
            durability_primitive, f"{context}.durability_primitive"
        )
        if durability_primitive not in DURABILITY_PRIMITIVES:
            raise ValidationError(f"{context}.durability_primitive is not allowed")
    if ack["bytes"] is not None:
        require_nonnegative_int(ack["bytes"], f"{context}.bytes")
    require_optional_sha256(ack["sha256"], f"{context}.sha256")
    commit_artifact = require_optional_artifact_ref(
        ack["commit_artifact_id"],
        expected_kind="durable_commit",
        artifacts=artifacts,
        referenced=referenced,
        context=f"{context}.commit_artifact_id",
    )
    ack_artifact = require_optional_artifact_ref(
        ack["ack_artifact_id"],
        expected_kind="durable_ack",
        artifacts=artifacts,
        referenced=referenced,
        context=f"{context}.ack_artifact_id",
    )
    if status == "committed_and_authenticated" and (
        not authenticated
        or ack["ack_protocol"] != "bound_session_effect_receipt_v1"
        or not durable
        or durability_primitive is None
        or ack["bytes"] is None
        or ack["sha256"] is None
        or commit_artifact is None
        or ack_artifact is None
    ):
        raise ValidationError(
            f"{context} cannot claim committed_and_authenticated without complete "
            "durable authenticated evidence"
        )
    return ack


def validate_file_transfers(
    value: Any,
    *,
    endpoint_ids: set[str],
    artifacts: dict[str, ValidatedArtifact],
    referenced: set[str],
) -> list[dict[str, Any]]:
    items = require_list(value, "file_transfers", maximum=2)
    transfers: list[dict[str, Any]] = []
    seen_transfer_ids: set[str] = set()
    for index, item in enumerate(items):
        context = f"file_transfers[{index}]"
        transfer = require_exact_keys(item, FILE_TRANSFER_KEYS, context)
        transfer_id = require_sha256(
            transfer["transfer_id_sha256"], f"{context}.transfer_id_sha256"
        )
        if transfer_id in seen_transfer_ids:
            raise ValidationError(f"duplicate file transfer id: {transfer_id}")
        seen_transfer_ids.add(transfer_id)
        sender = require_identifier(
            transfer["sender_endpoint_id"], f"{context}.sender_endpoint_id"
        )
        receiver = require_identifier(
            transfer["receiver_endpoint_id"], f"{context}.receiver_endpoint_id"
        )
        if sender not in endpoint_ids or receiver not in endpoint_ids:
            raise ValidationError(f"{context} references an undeclared endpoint")
        if sender == receiver:
            raise ValidationError(f"{context} sender and receiver must differ")
        require_artifact_ref(
            transfer["transfer_record_artifact_id"],
            expected_kind="file_transfer_record",
            artifacts=artifacts,
            referenced=referenced,
            context=f"{context}.transfer_record_artifact_id",
        )

        sender_observation = validate_file_observation(
            transfer["sender_observation"],
            expected_kind="file_source",
            artifacts=artifacts,
            referenced=referenced,
            context=f"{context}.sender_observation",
        )
        receiver_observation = validate_file_observation(
            transfer["receiver_observation"],
            expected_kind="file_receiver",
            artifacts=artifacts,
            referenced=referenced,
            context=f"{context}.receiver_observation",
        )

        validate_durable_ack(
            transfer["durable_ack"],
            artifacts=artifacts,
            referenced=referenced,
            context=f"{context}.durable_ack",
        )
        transfer["sender_observation"] = sender_observation
        transfer["receiver_observation"] = receiver_observation
        transfers.append(transfer)
    return transfers


def validate_trust_snapshot(
    value: Any,
    *,
    artifacts: dict[str, ValidatedArtifact],
    referenced: set[str],
    context: str,
) -> dict[str, Any]:
    snapshot = require_exact_keys(value, TRUST_SNAPSHOT_KEYS, context)
    require_sha256(snapshot["semantic_state_sha256"], f"{context}.semantic_state_sha256")
    require_nonnegative_int(snapshot["record_count"], f"{context}.record_count")
    require_nonnegative_int(snapshot["authority_epoch"], f"{context}.authority_epoch")
    require_artifact_ref(
        snapshot["artifact_id"],
        expected_kind="trust_snapshot",
        artifacts=artifacts,
        referenced=referenced,
        context=f"{context}.artifact_id",
    )
    return snapshot


def validate_trust_state(
    value: Any,
    *,
    endpoint_ids: set[str],
    artifacts: dict[str, ValidatedArtifact],
    referenced: set[str],
) -> list[dict[str, Any]]:
    items = require_list(value, "trust_state", maximum=2)
    records: list[dict[str, Any]] = []
    seen_endpoints: set[str] = set()
    for index, item in enumerate(items):
        context = f"trust_state[{index}]"
        record = require_exact_keys(item, TRUST_STATE_KEYS, context)
        endpoint_id = require_identifier(record["endpoint_id"], f"{context}.endpoint_id")
        if endpoint_id not in endpoint_ids:
            raise ValidationError(f"{context}.endpoint_id is not a declared endpoint")
        if endpoint_id in seen_endpoints:
            raise ValidationError(f"trust_state repeats endpoint: {endpoint_id}")
        seen_endpoints.add(endpoint_id)
        before = validate_trust_snapshot(
            record["before"],
            artifacts=artifacts,
            referenced=referenced,
            context=f"{context}.before",
        )
        after = validate_trust_snapshot(
            record["after"],
            artifacts=artifacts,
            referenced=referenced,
            context=f"{context}.after",
        )
        unchanged = require_bool(record["unchanged"], f"{context}.unchanged")
        semantic_before = (
            before["semantic_state_sha256"],
            before["record_count"],
            before["authority_epoch"],
        )
        semantic_after = (
            after["semantic_state_sha256"],
            after["record_count"],
            after["authority_epoch"],
        )
        if unchanged and semantic_before != semantic_after:
            raise ValidationError(f"{context} marks changed trust state as unchanged")
        records.append(record)
    return records


def validate_cleanup(
    value: Any,
    *,
    endpoint_ids: set[str],
    artifacts: dict[str, ValidatedArtifact],
    referenced: set[str],
) -> dict[str, Any] | None:
    if value is None:
        return None
    cleanup = require_exact_keys(value, CLEANUP_KEYS, "cleanup")
    require_bool(cleanup["ownership_verified"], "cleanup.ownership_verified")
    require_bool(cleanup["session_terminated"], "cleanup.session_terminated")
    require_bool(
        cleanup["foreign_resources_touched"], "cleanup.foreign_resources_touched"
    )
    records = require_list(cleanup["records"], "cleanup.records", maximum=2)
    seen_endpoints: set[str] = set()
    for index, item in enumerate(records):
        context = f"cleanup.records[{index}]"
        record = require_exact_keys(item, CLEANUP_RECORD_KEYS, context)
        endpoint_id = require_identifier(record["endpoint_id"], f"{context}.endpoint_id")
        if endpoint_id not in endpoint_ids:
            raise ValidationError(f"{context}.endpoint_id is not a declared endpoint")
        if endpoint_id in seen_endpoints:
            raise ValidationError(f"cleanup.records repeats endpoint: {endpoint_id}")
        seen_endpoints.add(endpoint_id)
        require_sha256(record["owner_binding_sha256"], f"{context}.owner_binding_sha256")
        result = require_safe_text(record["result"], f"{context}.result")
        if result not in CLEANUP_RESULTS:
            raise ValidationError(f"{context}.result is not allowed")
        require_artifact_ref(
            record["artifact_id"],
            expected_kind="cleanup_record",
            artifacts=artifacts,
            referenced=referenced,
            context=f"{context}.artifact_id",
        )
    return cleanup


def validate_unsupported_claims(value: Any) -> None:
    items = require_list(value, "unsupported_product_claims", maximum=2)
    if len(items) != 2:
        raise ValidationError(
            "unsupported_product_claims must explicitly cover messages and remote_desktop"
        )
    seen_features: set[str] = set()
    for index, item in enumerate(items):
        context = f"unsupported_product_claims[{index}]"
        claim = require_exact_keys(item, UNSUPPORTED_CLAIM_KEYS, context)
        feature = require_safe_text(claim["feature"], f"{context}.feature")
        if feature not in UNSUPPORTED_FEATURES:
            raise ValidationError(f"{context}.feature is not allowed")
        if feature in seen_features:
            raise ValidationError(f"unsupported_product_claims repeats feature: {feature}")
        seen_features.add(feature)
        if claim["status"] != "not_claimed":
            raise ValidationError(f"{context}.status must equal not_claimed")
        require_safe_text(claim["reason"], f"{context}.reason")
    if seen_features != UNSUPPORTED_FEATURES:
        raise ValidationError(
            "unsupported_product_claims must explicitly cover messages and remote_desktop"
        )


def parse_raw_json_artifact(
    artifact: ValidatedArtifact,
    *,
    schema: dict[str, Any],
    definition_name: str,
    context: str,
) -> dict[str, Any]:
    if artifact.raw_json_bytes is None:
        raise ValidationError(f"{context} does not contain bounded raw JSON bytes")
    try:
        decoded = artifact.raw_json_bytes.decode("utf-8")
        value = json.loads(
            decoded,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_nonfinite_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"{context} is not canonical UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise ValidationError(f"{context} raw JSON root must be an object")
    definition = schema["$defs"].get(definition_name)
    if not isinstance(definition, dict):
        raise ValidationError(f"schema is missing raw evidence definition: {definition_name}")
    validate_json_schema_instance(
        value,
        definition,
        schema_root=schema,
        context=f"raw[{artifact.artifact_id}]",
    )
    return value


def require_raw_evidence_match(
    artifacts: dict[str, ValidatedArtifact],
    artifact_id: str,
    expected: dict[str, Any],
    *,
    schema: dict[str, Any],
    definition_name: str,
) -> None:
    artifact = artifacts[artifact_id]
    actual = parse_raw_json_artifact(
        artifact,
        schema=schema,
        definition_name=definition_name,
        context=f"artifact {artifact_id}",
    )
    if not json_values_equal(actual, expected):
        raise ValidationError(
            f"raw evidence content does not match manifest fields: {artifact_id}"
        )


def validate_raw_source_and_endpoint_evidence(
    manifest: dict[str, Any],
    artifacts: dict[str, ValidatedArtifact],
    schema: dict[str, Any],
) -> None:
    run_binding = manifest["bindings"]["run_binding_sha256"]
    preregistration = manifest["preregistration"]
    require_raw_evidence_match(
        artifacts,
        preregistration["protocol_artifact_id"],
        {
            "kind": "preregistration",
            "run_binding_sha256": run_binding,
            "contract_id": manifest["contract_id"],
            "product_scope": manifest["product_scope"],
            "registered_at": preregistration["registered_at"],
            "protocol_document_sha256": preregistration[
                "protocol_document_sha256"
            ],
        },
        schema=schema,
        definition_name="raw_preregistration",
    )
    source = manifest["frozen_source"]
    if source is not None:
        require_raw_evidence_match(
            artifacts,
            source["freeze_artifact_id"],
            {
                "kind": "source_freeze",
                "run_binding_sha256": run_binding,
                "repository_id": source["repository_id"],
                "commit": source["commit"],
            },
            schema=schema,
            definition_name="raw_source_freeze",
        )
    for endpoint in manifest["endpoints"]:
        endpoint_id = endpoint["id"]
        device_artifact_id = endpoint["device_record_artifact_id"]
        if device_artifact_id is not None:
            require_raw_evidence_match(
                artifacts,
                device_artifact_id,
                {
                    "kind": "device_record",
                    "run_binding_sha256": run_binding,
                    "endpoint_id": endpoint_id,
                    "platform": endpoint["platform"],
                    "device_class": endpoint["device_class"],
                    "execution_environment": endpoint["execution_environment"],
                    "device_pseudonym_sha256": endpoint["device_pseudonym_sha256"],
                },
                schema=schema,
                definition_name="raw_device_record",
            )
        build = endpoint["build"]
        if build is not None:
            require_raw_evidence_match(
                artifacts,
                build["build_record_artifact_id"],
                {
                    "kind": "build_record",
                    "run_binding_sha256": run_binding,
                    "endpoint_id": endpoint_id,
                    "frozen_commit": build["frozen_commit"],
                    "product_revision": build["product_revision"],
                    "source_tree_state": build["source_tree_state"],
                    "binary_sha256": build["binary_sha256"],
                },
                schema=schema,
                definition_name="raw_build_record",
            )


def validate_raw_transport_and_crypto_evidence(
    manifest: dict[str, Any],
    artifacts: dict[str, ValidatedArtifact],
    schema: dict[str, Any],
) -> None:
    transport = manifest["transport"]
    if transport is not None:
        for report in transport["reports"]:
            require_raw_evidence_match(
                artifacts,
                report["artifact_id"],
                {
                    "kind": "selected_ice",
                    "run_binding_sha256": report["run_binding_sha256"],
                    "session_binding_sha256": report["session_binding_sha256"],
                    "endpoint_id": report["endpoint_id"],
                    "protocol": transport["protocol"],
                    "pair_correlation_sha256": transport["pair_correlation_sha256"],
                    "selected": report["selected"],
                    "state": report["state"],
                    "candidate_pair_id": report["candidate_pair_id"],
                    "local_candidate_type": report["local_candidate_type"],
                    "remote_candidate_type": report["remote_candidate_type"],
                    "network_protocol": report["network_protocol"],
                },
                schema=schema,
                definition_name="raw_selected_ice",
            )
    cryptography = manifest["cryptography"]
    if cryptography is not None:
        for report in cryptography["reports"]:
            require_raw_evidence_match(
                artifacts,
                report["artifact_id"],
                {
                    "kind": "pqc_session",
                    "run_binding_sha256": report["run_binding_sha256"],
                    "session_binding_sha256": report["session_binding_sha256"],
                    "endpoint_id": report["endpoint_id"],
                    "authenticated": report["authenticated"],
                    "protocol_id": cryptography["protocol_id"],
                    "suite_id": report["suite_id"],
                    "suite_name": cryptography["suite_name"],
                    "kem_combination": cryptography["kem_combination"],
                    "hybrid_profile_id": cryptography["hybrid_profile_id"],
                },
                schema=schema,
                definition_name="raw_pqc_session",
            )


def validate_raw_transfer_evidence(
    manifest: dict[str, Any],
    artifacts: dict[str, ValidatedArtifact],
    schema: dict[str, Any],
) -> None:
    for transfer in manifest["file_transfers"]:
        file_value = {
            "bytes": transfer["sender_observation"]["bytes"],
            "sha256": transfer["sender_observation"]["sha256"],
        }
        identity = {
            "run_binding_sha256": transfer["run_binding_sha256"],
            "session_binding_sha256": transfer["session_binding_sha256"],
            "transfer_id_sha256": transfer["transfer_id_sha256"],
            "sender_endpoint_id": transfer["sender_endpoint_id"],
            "receiver_endpoint_id": transfer["receiver_endpoint_id"],
        }
        require_raw_evidence_match(
            artifacts,
            transfer["transfer_record_artifact_id"],
            {"kind": "file_transfer_record", **identity, **file_value},
            schema=schema,
            definition_name="raw_file_transfer_record",
        )
        ack = transfer["durable_ack"]
        if ack["commit_artifact_id"] is not None:
            require_raw_evidence_match(
                artifacts,
                ack["commit_artifact_id"],
                {
                    "kind": "durable_commit",
                    **identity,
                    **file_value,
                    "durability_primitive": ack["durability_primitive"],
                    "committed": ack["durable_commit_observed"],
                },
                schema=schema,
                definition_name="raw_durable_commit",
            )
        if ack["ack_artifact_id"] is not None:
            require_raw_evidence_match(
                artifacts,
                ack["ack_artifact_id"],
                {
                    "kind": "durable_ack",
                    **identity,
                    "bytes": ack["bytes"],
                    "sha256": ack["sha256"],
                    "status": ack["status"],
                    "authenticated": ack["authenticated"],
                    "ack_protocol": ack["ack_protocol"],
                    "durability_primitive": ack["durability_primitive"],
                },
                schema=schema,
                definition_name="raw_durable_ack",
            )


def validate_raw_trust_and_cleanup_evidence(
    manifest: dict[str, Any],
    artifacts: dict[str, ValidatedArtifact],
    schema: dict[str, Any],
) -> None:
    for trust_record in manifest["trust_state"]:
        identity = {
            "run_binding_sha256": trust_record["run_binding_sha256"],
            "session_binding_sha256": trust_record["session_binding_sha256"],
            "endpoint_id": trust_record["endpoint_id"],
        }
        for phase in ("before", "after"):
            snapshot = trust_record[phase]
            require_raw_evidence_match(
                artifacts,
                snapshot["artifact_id"],
                {
                    "kind": "trust_snapshot",
                    **identity,
                    "phase": phase,
                    "semantic_state_sha256": snapshot["semantic_state_sha256"],
                    "record_count": snapshot["record_count"],
                    "authority_epoch": snapshot["authority_epoch"],
                },
                schema=schema,
                definition_name="raw_trust_snapshot",
            )
    cleanup = manifest["cleanup"]
    if cleanup is not None:
        for record in cleanup["records"]:
            require_raw_evidence_match(
                artifacts,
                record["artifact_id"],
                {
                    "kind": "cleanup_record",
                    "run_binding_sha256": record["run_binding_sha256"],
                    "session_binding_sha256": record["session_binding_sha256"],
                    "endpoint_id": record["endpoint_id"],
                    "owner_binding_sha256": record["owner_binding_sha256"],
                    "result": record["result"],
                    "ownership_verified": cleanup["ownership_verified"],
                    "session_terminated": cleanup["session_terminated"],
                    "foreign_resources_touched": cleanup[
                        "foreign_resources_touched"
                    ],
                },
                schema=schema,
                definition_name="raw_cleanup_record",
            )


def validate_raw_evidence(
    manifest: dict[str, Any],
    artifacts: dict[str, ValidatedArtifact],
    schema: dict[str, Any],
) -> None:
    validate_raw_source_and_endpoint_evidence(manifest, artifacts, schema)
    validate_raw_transport_and_crypto_evidence(manifest, artifacts, schema)
    validate_raw_transfer_evidence(manifest, artifacts, schema)
    validate_raw_trust_and_cleanup_evidence(manifest, artifacts, schema)


def normalized_unknown(value: str) -> bool:
    normalized = re.sub(r"[\s_/-]+", "", value).casefold()
    return normalized in {"unknown", "none", "null", "na", "notavailable"}


def require_exact_endpoint_coverage(
    records: list[dict[str, Any]], endpoint_ids: set[str], context: str
) -> None:
    observed = {record["endpoint_id"] for record in records}
    if len(records) != len(observed) or observed != endpoint_ids:
        raise ValidationError(f"{context} must cover each endpoint exactly once")


def require_distinct_artifact_refs(values: list[str], context: str) -> None:
    if len(values) != len(set(values)):
        raise ValidationError(f"{context} must use distinct raw artifacts")


def validate_eligible_endpoints(
    frozen_source: dict[str, Any], endpoints: dict[str, dict[str, Any]]
) -> set[str]:
    endpoint_ids = set(endpoints)
    device_pseudonyms: list[str] = []
    endpoint_artifacts: list[str] = []
    for endpoint_id, endpoint in endpoints.items():
        context = f"endpoint {endpoint_id}"
        if endpoint["execution_environment"] != "physical_device":
            raise ValidationError(f"{context} must be a physical device")
        device_pseudonym = endpoint["device_pseudonym_sha256"]
        if device_pseudonym is None:
            raise ValidationError(f"{context} is missing its run-scoped device pseudonym")
        device_pseudonyms.append(device_pseudonym)
        if endpoint["device_record_artifact_id"] is None:
            raise ValidationError(f"{context} is missing its device record")
        build = endpoint["build"]
        if build is None:
            raise ValidationError(f"{context} is missing its build binding")
        if build["frozen_commit"] != frozen_source["commit"]:
            raise ValidationError(f"{context} does not use the same frozen commit")
        if build["source_tree_state"] != "clean":
            raise ValidationError(f"{context} was not built from a clean source tree")
        endpoint_artifacts.extend(
            [
                endpoint["device_record_artifact_id"],
                build["binary_artifact_id"],
                build["build_record_artifact_id"],
            ]
        )
    if len(device_pseudonyms) != len(set(device_pseudonyms)):
        raise ValidationError("physical endpoints must have distinct run pseudonyms")
    require_distinct_artifact_refs(endpoint_artifacts, "endpoint evidence")
    return endpoint_ids


def validate_eligible_transport(
    transport: dict[str, Any] | None, endpoint_ids: set[str]
) -> None:
    if transport is None:
        raise ValidationError("claim eligibility requires selected ICE evidence")
    if transport["pair_correlation_sha256"] is None:
        raise ValidationError("selected ICE pair correlation cannot be UNKNOWN")
    reports = transport["reports"]
    require_exact_endpoint_coverage(reports, endpoint_ids, "selected ICE reports")
    ice_artifacts: list[str] = []
    for report in reports:
        pair_id = report["candidate_pair_id"]
        if (
            not report["selected"]
            or report["state"] != "succeeded"
            or pair_id is None
            or normalized_unknown(pair_id)
            or report["local_candidate_type"] == "unknown"
            or report["remote_candidate_type"] == "unknown"
            or report["network_protocol"] == "unknown"
        ):
            raise ValidationError(
                "claim eligibility requires a selected, succeeded, non-UNKNOWN ICE pair "
                "from both endpoints"
            )
        ice_artifacts.append(report["artifact_id"])
    require_distinct_artifact_refs(ice_artifacts, "selected ICE reports")


def validate_eligible_cryptography(
    cryptography: dict[str, Any] | None, endpoint_ids: set[str]
) -> None:
    if cryptography is None:
        raise ValidationError("claim eligibility requires authenticated PQC session evidence")
    expected_crypto = (
        ELIGIBLE_PROTOCOL_ID,
        ELIGIBLE_SUITE_ID,
        ELIGIBLE_SUITE_NAME,
        ELIGIBLE_KEM_COMBINATION,
        ELIGIBLE_HYBRID_PROFILE_ID,
    )
    actual_crypto = (
        cryptography["protocol_id"],
        cryptography["suite_id"],
        cryptography["suite_name"],
        cryptography["kem_combination"],
        cryptography["hybrid_profile_id"],
    )
    if actual_crypto != expected_crypto:
        raise ValidationError(
            "claim eligibility requires the frozen Q-Periapt ABI2 PQC hybrid suite"
        )
    crypto_reports = cryptography["reports"]
    require_exact_endpoint_coverage(crypto_reports, endpoint_ids, "PQC session reports")
    session_bindings: set[str] = set()
    crypto_artifacts: list[str] = []
    for report in crypto_reports:
        if (
            not report["authenticated"]
            or report["suite_id"] != ELIGIBLE_SUITE_ID
            or report["session_binding_sha256"] is None
        ):
            raise ValidationError(
                "both endpoints must authenticate the eligible PQC suite and session binding"
            )
        session_bindings.add(report["session_binding_sha256"])
        crypto_artifacts.append(report["artifact_id"])
    if len(session_bindings) != 1:
        raise ValidationError("PQC endpoint reports do not bind the same session")
    require_distinct_artifact_refs(crypto_artifacts, "PQC session reports")


def validate_eligible_file_transfers(
    file_transfers: list[dict[str, Any]], endpoint_ids: set[str]
) -> None:
    if len(file_transfers) != 2:
        raise ValidationError("claim eligibility requires exactly two file transfers")
    expected_directions = {
        (sender, receiver)
        for sender in endpoint_ids
        for receiver in endpoint_ids
        if sender != receiver
    }
    actual_directions = {
        (transfer["sender_endpoint_id"], transfer["receiver_endpoint_id"])
        for transfer in file_transfers
    }
    if actual_directions != expected_directions:
        raise ValidationError("file transfers must cover both directions exactly once")
    transfer_artifacts: list[str] = []
    payload_digests: list[str] = []
    for index, transfer in enumerate(file_transfers):
        sender = transfer["sender_observation"]
        receiver = transfer["receiver_observation"]
        ack = transfer["durable_ack"]
        expected_file = (sender["bytes"], sender["sha256"])
        if sender["bytes"] <= 0:
            raise ValidationError(
                "claim-eligible file-transfer payloads must each contain at least one byte"
            )
        payload_digests.append(sender["sha256"])
        if (receiver["bytes"], receiver["sha256"]) != expected_file:
            raise ValidationError(f"file_transfers[{index}] receiver bytes or SHA-256 differ")
        if (
            ack["status"] != "committed_and_authenticated"
            or not ack["authenticated"]
            or ack["ack_protocol"] != "bound_session_effect_receipt_v1"
            or not ack["durable_commit_observed"]
            or ack["durability_primitive"] not in DURABILITY_PRIMITIVES
            or (ack["bytes"], ack["sha256"]) != expected_file
            or ack["commit_artifact_id"] is None
            or ack["ack_artifact_id"] is None
        ):
            raise ValidationError(
                f"file_transfers[{index}] lacks a matching durable authenticated ACK"
            )
        transfer_artifacts.extend(
            [
                transfer["transfer_record_artifact_id"],
                sender["artifact_id"],
                receiver["artifact_id"],
                ack["commit_artifact_id"],
                ack["ack_artifact_id"],
            ]
        )
    if len(set(payload_digests)) != 2:
        raise ValidationError(
            "claim-eligible transfer directions must use distinct payload digests"
        )
    require_distinct_artifact_refs(transfer_artifacts, "file-transfer evidence")


def validate_eligible_trust_state(
    trust_state: list[dict[str, Any]], endpoint_ids: set[str]
) -> None:
    require_exact_endpoint_coverage(trust_state, endpoint_ids, "trust-state records")
    trust_artifacts: list[str] = []
    for record in trust_state:
        before = record["before"]
        after = record["after"]
        if not record["unchanged"] or (
            before["semantic_state_sha256"],
            before["record_count"],
            before["authority_epoch"],
        ) != (
            after["semantic_state_sha256"],
            after["record_count"],
            after["authority_epoch"],
        ):
            raise ValidationError("trust state must remain unchanged on both endpoints")
        trust_artifacts.extend([before["artifact_id"], after["artifact_id"]])
    require_distinct_artifact_refs(trust_artifacts, "before/after trust snapshots")


def validate_eligible_cleanup(
    cleanup: dict[str, Any] | None, endpoint_ids: set[str]
) -> None:
    if cleanup is None:
        raise ValidationError("claim eligibility requires owner-verified cleanup")
    if (
        not cleanup["ownership_verified"]
        or not cleanup["session_terminated"]
        or cleanup["foreign_resources_touched"]
    ):
        raise ValidationError(
            "cleanup must verify ownership, terminate the session, and avoid foreign resources"
        )
    cleanup_records = cleanup["records"]
    require_exact_endpoint_coverage(cleanup_records, endpoint_ids, "cleanup records")
    owner_bindings: set[str] = set()
    cleanup_artifacts: list[str] = []
    for record in cleanup_records:
        if record["result"] != "owner_verified_and_released":
            raise ValidationError("cleanup ownership was not verified and released")
        owner_bindings.add(record["owner_binding_sha256"])
        cleanup_artifacts.append(record["artifact_id"])
    if len(owner_bindings) != 2:
        raise ValidationError("endpoint cleanup records must bind distinct local owners")
    require_distinct_artifact_refs(cleanup_artifacts, "cleanup records")


def validate_eligible_claim_scope(
    claimed_claim_ids: set[str], endpoints: dict[str, dict[str, Any]]
) -> None:
    if "BS-FILE-DURABLE-RECEIPT" not in claimed_claim_ids:
        raise ValidationError(
            "claim-eligible bidirectional file evidence must name BS-FILE-DURABLE-RECEIPT"
        )
    platforms = {endpoint["platform"] for endpoint in endpoints.values()}
    if "BS-APPLE-PHYSICAL-E2E" in claimed_claim_ids and not platforms <= APPLE_PLATFORMS:
        raise ValidationError("BS-APPLE-PHYSICAL-E2E requires two Apple endpoints")
    if "BS-NONAPPLE-INTEROP" in claimed_claim_ids:
        apple_count = sum(
            endpoint["platform"] in APPLE_PLATFORMS for endpoint in endpoints.values()
        )
        if apple_count != 1:
            raise ValidationError(
                "BS-NONAPPLE-INTEROP requires one Apple and one non-Apple endpoint"
            )


def validate_claim_eligibility(
    *,
    evidence_class: str,
    claimed_claim_ids: set[str],
    frozen_source: dict[str, Any] | None,
    endpoints: dict[str, dict[str, Any]],
    transport: dict[str, Any] | None,
    cryptography: dict[str, Any] | None,
    file_transfers: list[dict[str, Any]],
    trust_state: list[dict[str, Any]],
    cleanup: dict[str, Any] | None,
) -> None:
    if evidence_class != "physical_product_interop":
        raise ValidationError("only physical_product_interop can be claim eligible")
    if frozen_source is None:
        raise ValidationError("claim eligibility requires one frozen source commit")
    if len(endpoints) != 2:
        raise ValidationError("claim eligibility requires exactly two endpoints")

    endpoint_ids = validate_eligible_endpoints(frozen_source, endpoints)
    validate_eligible_transport(transport, endpoint_ids)
    validate_eligible_cryptography(cryptography, endpoint_ids)
    validate_eligible_file_transfers(file_transfers, endpoint_ids)
    validate_eligible_trust_state(trust_state, endpoint_ids)
    validate_eligible_cleanup(cleanup, endpoint_ids)
    validate_eligible_claim_scope(claimed_claim_ids, endpoints)


def validate_schema_contract(value: dict[str, Any]) -> None:
    expected_root_keys = {
        "$schema",
        "$id",
        "title",
        "description",
        "type",
        "additionalProperties",
        "required",
        "properties",
        "$defs",
    }
    require_exact_keys(value, expected_root_keys, "schema")
    audit_supported_schema(value)
    if value["$schema"] != "https://json-schema.org/draft/2020-12/schema":
        raise ValidationError("schema must use JSON Schema draft 2020-12")
    if value["$id"] != SCHEMA_ID:
        raise ValidationError("schema $id does not match the validator contract")
    if value["type"] != "object" or value["additionalProperties"] is not False:
        raise ValidationError("schema root must be a closed object")
    require_safe_text(value["title"], "schema.title")
    require_safe_text(value["description"], "schema.description")
    required = set(
        require_unique_strings(
            value["required"], "schema.required", maximum=len(ROOT_KEYS)
        )
    )
    properties = require_exact_keys(value["properties"], ROOT_KEYS, "schema.properties")
    if required != ROOT_KEYS:
        raise ValidationError("schema root keys drifted from the validator")
    evidence_class_schema = require_exact_keys(
        properties["evidence_class"], {"enum"}, "schema.properties.evidence_class"
    )
    evidence_classes = set(
        require_unique_strings(
            evidence_class_schema["enum"],
            "schema.properties.evidence_class.enum",
            maximum=len(EVIDENCE_CLASSES),
        )
    )
    if evidence_classes != EVIDENCE_CLASSES:
        raise ValidationError("schema evidence classes drifted from the validator")
    definitions = value["$defs"]
    if not isinstance(definitions, dict):
        raise ValidationError("schema.$defs must be an object")
    claim_definition = require_exact_keys(
        definitions.get("claim_id"), {"enum"}, "schema.$defs.claim_id"
    )
    claim_ids = set(
        require_unique_strings(
            claim_definition["enum"],
            "schema.$defs.claim_id.enum",
            maximum=len(ALLOWED_CLAIM_IDS),
        )
    )
    if claim_ids != ALLOWED_CLAIM_IDS:
        raise ValidationError("schema claim ids drifted from the validator")
    artifact_definition = definitions.get("artifact")
    if not isinstance(artifact_definition, dict):
        raise ValidationError("schema.$defs.artifact must be an object")
    artifact_properties = artifact_definition.get("properties")
    if not isinstance(artifact_properties, dict):
        raise ValidationError("schema.$defs.artifact.properties must be an object")
    kind_definition = require_exact_keys(
        artifact_properties.get("kind"), {"enum"}, "schema.$defs.artifact.properties.kind"
    )
    artifact_kinds = set(
        require_unique_strings(
            kind_definition["enum"],
            "schema.$defs.artifact.properties.kind.enum",
            maximum=len(ARTIFACT_KINDS),
        )
    )
    if artifact_kinds != ARTIFACT_KINDS:
        raise ValidationError("schema artifact kinds drifted from the validator")
    missing_raw_definitions = sorted(set(RAW_JSON_SCHEMA_BY_KIND.values()) - set(definitions))
    if missing_raw_definitions:
        raise ValidationError(
            f"schema is missing raw evidence definitions: {missing_raw_definitions}"
        )


def validate_manifest(
    value: dict[str, Any],
    *,
    artifact_root: Path,
    schema: dict[str, Any] | None = None,
) -> None:
    active_schema = (
        load_json_document(SCHEMA_PATH, label="schema") if schema is None else schema
    )
    validate_schema_contract(active_schema)
    validate_json_schema_instance(value, active_schema)
    manifest = require_exact_keys(value, ROOT_KEYS, "manifest")
    if type(manifest["schema_version"]) is not int or manifest["schema_version"] != SCHEMA_VERSION:
        raise ValidationError(f"schema_version must be the integer {SCHEMA_VERSION}")
    if manifest["contract_id"] != CONTRACT_ID:
        raise ValidationError(f"contract_id must equal {CONTRACT_ID}")
    require_identifier(manifest["evidence_id"], "evidence_id")
    evidence_class = require_safe_text(manifest["evidence_class"], "evidence_class")
    if evidence_class not in EVIDENCE_CLASSES:
        raise ValidationError("evidence_class is not allowed")
    if manifest["product_scope"] != PRODUCT_SCOPE:
        raise ValidationError(f"product_scope must equal {PRODUCT_SCOPE}")
    claim_eligible = require_bool(manifest["claim_eligible"], "claim_eligible")

    related_claim_ids = set(
        require_unique_strings(manifest["related_claim_ids"], "related_claim_ids", maximum=3)
    )
    claimed_claim_ids = set(
        require_unique_strings(manifest["claimed_claim_ids"], "claimed_claim_ids", maximum=3)
    )
    unknown_claims = (related_claim_ids | claimed_claim_ids) - ALLOWED_CLAIM_IDS
    if unknown_claims:
        raise ValidationError(f"manifest uses unsupported claim ids: {sorted(unknown_claims)}")
    if not claimed_claim_ids <= related_claim_ids:
        raise ValidationError("claimed_claim_ids must be a subset of related_claim_ids")
    if claim_eligible and not claimed_claim_ids:
        raise ValidationError("claim-eligible evidence must name at least one claim")
    if not claim_eligible and claimed_claim_ids:
        raise ValidationError("non-eligible evidence cannot name claimed_claim_ids")
    if evidence_class in {"diagnostic", "source_capability"} and claim_eligible:
        raise ValidationError(f"{evidence_class} evidence is never claim eligible")
    bindings = validate_bindings(manifest["bindings"])
    validate_binding_continuity(manifest, bindings)

    artifacts = validate_artifacts(manifest["artifacts"], artifact_root=artifact_root)
    referenced: set[str] = set()
    validate_preregistration_and_timing(
        manifest["preregistration"],
        manifest["timing"],
        artifacts=artifacts,
        referenced=referenced,
    )
    frozen_source = validate_frozen_source(
        manifest["frozen_source"], artifacts=artifacts, referenced=referenced
    )
    if evidence_class == "source_capability" and frozen_source is None:
        raise ValidationError("source_capability evidence requires a frozen source")

    endpoints = validate_endpoints(
        manifest["endpoints"], artifacts=artifacts, referenced=referenced
    )
    endpoint_ids = set(endpoints)
    if evidence_class == "physical_product_interop":
        if len(endpoint_ids) != 2:
            raise ValidationError(
                "physical_product_interop must preregister exactly two endpoints"
            )
        if any(
            endpoint["execution_environment"] != "physical_device"
            for endpoint in endpoints.values()
        ):
            raise ValidationError(
                "physical_product_interop cannot include a simulator, emulator, VM, or container"
            )

    transport = validate_transport(
        manifest["transport"],
        endpoint_ids=endpoint_ids,
        artifacts=artifacts,
        referenced=referenced,
    )
    cryptography = validate_cryptography(
        manifest["cryptography"],
        endpoint_ids=endpoint_ids,
        artifacts=artifacts,
        referenced=referenced,
    )
    file_transfers = validate_file_transfers(
        manifest["file_transfers"],
        endpoint_ids=endpoint_ids,
        artifacts=artifacts,
        referenced=referenced,
    )
    trust_state = validate_trust_state(
        manifest["trust_state"],
        endpoint_ids=endpoint_ids,
        artifacts=artifacts,
        referenced=referenced,
    )
    cleanup = validate_cleanup(
        manifest["cleanup"],
        endpoint_ids=endpoint_ids,
        artifacts=artifacts,
        referenced=referenced,
    )
    validate_unsupported_claims(manifest["unsupported_product_claims"])
    limitations = require_unique_strings(manifest["limitations"], "limitations", maximum=32)
    if not limitations:
        raise ValidationError("limitations must be non-empty")

    validate_raw_evidence(manifest, artifacts, active_schema)

    if claim_eligible:
        validate_claim_eligibility(
            evidence_class=evidence_class,
            claimed_claim_ids=claimed_claim_ids,
            frozen_source=frozen_source,
            endpoints=endpoints,
            transport=transport,
            cryptography=cryptography,
            file_transfers=file_transfers,
            trust_state=trust_state,
            cleanup=cleanup,
        )

    unused_artifacts = set(artifacts) - referenced
    if unused_artifacts:
        raise ValidationError(
            f"artifacts are declared but not used by the manifest: {sorted(unused_artifacts)}"
        )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="experiment evidence manifest JSON")
    parser.add_argument(
        "--artifact-root",
        type=Path,
        help="evidence root; defaults to the manifest's parent directory",
    )
    parser.add_argument(
        "--schema",
        type=Path,
        default=SCHEMA_PATH,
        help="canonical experiment evidence JSON Schema",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        schema_path = args.schema.resolve(strict=True)
        schema = load_json_document(schema_path, label="schema")
        validate_schema_contract(schema)
        manifest_path = args.manifest.resolve(strict=True)
        artifact_root = (
            args.artifact_root.resolve(strict=True)
            if args.artifact_root is not None
            else manifest_path.parent
        )
        manifest = load_json_document(manifest_path, label="manifest")
        validate_manifest(manifest, artifact_root=artifact_root, schema=schema)
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"experiment evidence validation failed: {error}", file=sys.stderr)
        return 1
    print(
        "experiment evidence valid: "
        f"{manifest['evidence_id']}; class={manifest['evidence_class']}; "
        f"claim_eligible={str(manifest['claim_eligible']).lower()}; "
        f"artifacts={len(manifest['artifacts'])}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
