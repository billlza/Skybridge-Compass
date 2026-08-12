from __future__ import annotations

import copy
import hashlib
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

from artifact.validate_experiment_evidence import (
    MAX_JSON_BYTES,
    MAX_RAW_JSON_ARTIFACT_BYTES,
    MAX_TOTAL_ARTIFACT_BYTES,
    SCHEMA_PATH,
    ValidationError,
    load_json_document,
    main,
    preregistration_document_sha256,
    validate_manifest,
    validate_schema_contract,
)


def digest(value: bytes | str) -> str:
    encoded = value.encode("utf-8") if isinstance(value, str) else value
    return hashlib.sha256(encoded).hexdigest()


def add_artifact(
    root: Path,
    artifacts: list[dict],
    *,
    artifact_id: str,
    kind: str,
    relative_path: str,
    content: bytes | str,
    media_type: str = "application/json",
) -> dict:
    encoded = content.encode("utf-8") if isinstance(content, str) else content
    path = root / relative_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(encoded)
    record = {
        "id": artifact_id,
        "kind": kind,
        "path": relative_path,
        "sha256": digest(encoded),
        "size_bytes": len(encoded),
        "media_type": media_type,
    }
    artifacts.append(record)
    return record


def json_content(value: dict) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def add_json_artifact(
    root: Path,
    artifacts: list[dict],
    *,
    artifact_id: str,
    kind: str,
    relative_path: str,
    value: dict,
) -> dict:
    return add_artifact(
        root,
        artifacts,
        artifact_id=artifact_id,
        kind=kind,
        relative_path=relative_path,
        content=json_content(value),
    )


def artifact_record(manifest: dict, artifact_id: str) -> dict:
    return next(
        artifact for artifact in manifest["artifacts"] if artifact["id"] == artifact_id
    )


def rewrite_artifact(
    root: Path, manifest: dict, artifact_id: str, content: bytes | str
) -> None:
    encoded = content.encode("utf-8") if isinstance(content, str) else content
    artifact = artifact_record(manifest, artifact_id)
    (root / artifact["path"]).write_bytes(encoded)
    artifact["sha256"] = digest(encoded)
    artifact["size_bytes"] = len(encoded)


def read_raw_json(root: Path, manifest: dict, artifact_id: str) -> dict:
    artifact = artifact_record(manifest, artifact_id)
    return json.loads((root / artifact["path"]).read_text(encoding="utf-8"))


def update_raw_json(
    root: Path, manifest: dict, artifact_id: str, **updates: object
) -> None:
    value = read_raw_json(root, manifest, artifact_id)
    value.update(updates)
    rewrite_artifact(root, manifest, artifact_id, json_content(value))


def rewrite_transfer_payload(
    root: Path, manifest: dict, transfer_index: int, content: bytes
) -> None:
    transfer = manifest["file_transfers"][transfer_index]
    file_value = {"bytes": len(content), "sha256": digest(content)}
    rewrite_artifact(
        root,
        manifest,
        transfer["sender_observation"]["artifact_id"],
        content,
    )
    rewrite_artifact(
        root,
        manifest,
        transfer["receiver_observation"]["artifact_id"],
        content,
    )
    transfer["sender_observation"].update(file_value)
    transfer["receiver_observation"].update(file_value)
    transfer["durable_ack"].update(file_value)
    update_raw_json(
        root,
        manifest,
        transfer["transfer_record_artifact_id"],
        **file_value,
    )
    update_raw_json(
        root,
        manifest,
        transfer["durable_ack"]["commit_artifact_id"],
        **file_value,
    )
    update_raw_json(
        root,
        manifest,
        transfer["durable_ack"]["ack_artifact_id"],
        **file_value,
    )


def valid_claim_eligible_manifest(root: Path) -> dict:
    run_binding = digest("physical-file-interop-test-run")
    session_binding = digest("bound-session-test-session")
    bindings = {
        "run_binding_sha256": run_binding,
        "session_binding_sha256": session_binding,
    }
    artifacts: list[dict] = []
    protocol_digest = preregistration_document_sha256()
    registered_at = "2026-08-12T09:00:00Z"
    add_json_artifact(
        root,
        artifacts,
        artifact_id="preregistration-protocol",
        kind="preregistration",
        relative_path="raw/preregistration.json",
        value={
            "kind": "preregistration",
            "run_binding_sha256": run_binding,
            "contract_id": "policy-purpose-bound-session/experiment-evidence/v1",
            "product_scope": "bidirectional_file_transfer_v1",
            "registered_at": registered_at,
            "protocol_document_sha256": protocol_digest,
        },
    )
    add_json_artifact(
        root,
        artifacts,
        artifact_id="source-freeze",
        kind="source_freeze",
        relative_path="raw/source-freeze.json",
        value={
            "kind": "source_freeze",
            "run_binding_sha256": run_binding,
            "repository_id": "policy-purpose-bound-session",
            "commit": "a" * 40,
        },
    )

    endpoints: list[dict] = []
    for endpoint_id, platform, product_revision in (
        ("endpoint-a", "ios", "b" * 40),
        ("endpoint-b", "android", "c" * 40),
    ):
        binary = add_artifact(
            root,
            artifacts,
            artifact_id=f"{endpoint_id}-binary",
            kind="binary",
            relative_path=f"raw/{endpoint_id}/product.bin",
            content=f"binary-{endpoint_id}".encode(),
            media_type="application/octet-stream",
        )
        build = {
            "frozen_commit": "a" * 40,
            "product_revision": product_revision,
            "source_tree_state": "clean",
            "binary_sha256": binary["sha256"],
            "binary_artifact_id": f"{endpoint_id}-binary",
            "build_record_artifact_id": f"{endpoint_id}-build-record",
        }
        device_pseudonym = digest(f"run-pseudonym-{endpoint_id}")
        add_json_artifact(
            root,
            artifacts,
            artifact_id=f"{endpoint_id}-build-record",
            kind="build_record",
            relative_path=f"raw/{endpoint_id}/build.json",
            value={
                "kind": "build_record",
                "run_binding_sha256": run_binding,
                "endpoint_id": endpoint_id,
                "frozen_commit": build["frozen_commit"],
                "product_revision": product_revision,
                "source_tree_state": "clean",
                "binary_sha256": binary["sha256"],
            },
        )
        add_json_artifact(
            root,
            artifacts,
            artifact_id=f"{endpoint_id}-device-record",
            kind="device_record",
            relative_path=f"raw/{endpoint_id}/device.json",
            value={
                "kind": "device_record",
                "run_binding_sha256": run_binding,
                "endpoint_id": endpoint_id,
                "platform": platform,
                "device_class": "phone",
                "execution_environment": "physical_device",
                "device_pseudonym_sha256": device_pseudonym,
            },
        )
        endpoints.append(
            {
                "id": endpoint_id,
                "platform": platform,
                "device_class": "phone",
                "execution_environment": "physical_device",
                "device_pseudonym_sha256": device_pseudonym,
                "device_record_artifact_id": f"{endpoint_id}-device-record",
                "build": build,
            }
        )

    ice_reports: list[dict] = []
    crypto_reports: list[dict] = []
    for endpoint_id in ("endpoint-a", "endpoint-b"):
        ice_report = {
            **bindings,
            "endpoint_id": endpoint_id,
            "selected": True,
            "state": "succeeded",
            "candidate_pair_id": f"selected-pair-{endpoint_id}",
            "local_candidate_type": "srflx",
            "remote_candidate_type": "relay",
            "network_protocol": "udp",
            "artifact_id": f"{endpoint_id}-selected-ice",
        }
        add_json_artifact(
            root,
            artifacts,
            artifact_id=f"{endpoint_id}-selected-ice",
            kind="selected_ice",
            relative_path=f"raw/{endpoint_id}/selected-ice.json",
            value={
                "kind": "selected_ice",
                **bindings,
                "endpoint_id": endpoint_id,
                "protocol": "webrtc_data_channel",
                "pair_correlation_sha256": digest("selected-candidate-pair"),
                "selected": True,
                "state": "succeeded",
                "candidate_pair_id": f"selected-pair-{endpoint_id}",
                "local_candidate_type": "srflx",
                "remote_candidate_type": "relay",
                "network_protocol": "udp",
            },
        )
        ice_reports.append(ice_report)
        crypto_report = {
            **bindings,
            "endpoint_id": endpoint_id,
            "authenticated": True,
            "suite_id": 0x0012,
            "artifact_id": f"{endpoint_id}-pqc-session",
        }
        add_json_artifact(
            root,
            artifacts,
            artifact_id=f"{endpoint_id}-pqc-session",
            kind="pqc_session",
            relative_path=f"raw/{endpoint_id}/pqc-session.json",
            value={
                "kind": "pqc_session",
                **bindings,
                "endpoint_id": endpoint_id,
                "authenticated": True,
                "protocol_id": "bound-session/1",
                "suite_id": 0x0012,
                "suite_name": "Q-Periapt-ABI2-PolicyBound",
                "kem_combination": "ML-KEM-768+X25519",
                "hybrid_profile_id": 2,
            },
        )
        crypto_reports.append(crypto_report)

    transfers: list[dict] = []
    for label, sender, receiver, content in (
        ("a-to-b", "endpoint-a", "endpoint-b", b"payload from endpoint a"),
        ("b-to-a", "endpoint-b", "endpoint-a", b"a distinct payload from endpoint b"),
    ):
        sender_file = add_artifact(
            root,
            artifacts,
            artifact_id=f"{label}-source",
            kind="file_source",
            relative_path=f"raw/transfers/{label}-source.bin",
            content=content,
            media_type="application/octet-stream",
        )
        receiver_file = add_artifact(
            root,
            artifacts,
            artifact_id=f"{label}-receiver",
            kind="file_receiver",
            relative_path=f"raw/transfers/{label}-receiver.bin",
            content=content,
            media_type="application/octet-stream",
        )
        file_value = {
            "bytes": len(content),
            "sha256": digest(content),
        }
        transfer_identity = {
            **bindings,
            "transfer_id_sha256": digest(f"transfer-{label}"),
            "sender_endpoint_id": sender,
            "receiver_endpoint_id": receiver,
        }
        add_json_artifact(
            root,
            artifacts,
            artifact_id=f"{label}-record",
            kind="file_transfer_record",
            relative_path=f"raw/transfers/{label}-record.json",
            value={"kind": "file_transfer_record", **transfer_identity, **file_value},
        )
        add_json_artifact(
            root,
            artifacts,
            artifact_id=f"{label}-commit",
            kind="durable_commit",
            relative_path=f"raw/transfers/{label}-commit.json",
            value={
                "kind": "durable_commit",
                **transfer_identity,
                **file_value,
                "durability_primitive": "platform_atomic_file_commit",
                "committed": True,
            },
        )
        add_json_artifact(
            root,
            artifacts,
            artifact_id=f"{label}-ack",
            kind="durable_ack",
            relative_path=f"raw/transfers/{label}-ack.json",
            value={
                "kind": "durable_ack",
                **transfer_identity,
                **file_value,
                "status": "committed_and_authenticated",
                "authenticated": True,
                "ack_protocol": "bound_session_effect_receipt_v1",
                "durability_primitive": "platform_atomic_file_commit",
            },
        )
        transfers.append(
            {
                **transfer_identity,
                "sender_observation": {
                    **file_value,
                    "artifact_id": sender_file["id"],
                },
                "receiver_observation": {
                    **file_value,
                    "artifact_id": receiver_file["id"],
                },
                "durable_ack": {
                    **bindings,
                    "status": "committed_and_authenticated",
                    "authenticated": True,
                    "ack_protocol": "bound_session_effect_receipt_v1",
                    "durable_commit_observed": True,
                    "durability_primitive": "platform_atomic_file_commit",
                    **file_value,
                    "commit_artifact_id": f"{label}-commit",
                    "ack_artifact_id": f"{label}-ack",
                },
                "transfer_record_artifact_id": f"{label}-record",
            }
        )

    trust_state: list[dict] = []
    cleanup_records: list[dict] = []
    for index, endpoint_id in enumerate(("endpoint-a", "endpoint-b"), start=1):
        snapshot = {
            "semantic_state_sha256": digest(f"trust-state-{endpoint_id}"),
            "record_count": 1,
            "authority_epoch": 7,
        }
        for phase in ("before", "after"):
            add_json_artifact(
                root,
                artifacts,
                artifact_id=f"{endpoint_id}-trust-{phase}",
                kind="trust_snapshot",
                relative_path=f"raw/{endpoint_id}/trust-{phase}.json",
                value={
                    "kind": "trust_snapshot",
                    **bindings,
                    "endpoint_id": endpoint_id,
                    "phase": phase,
                    **snapshot,
                },
            )
        trust_state.append(
            {
                **bindings,
                "endpoint_id": endpoint_id,
                "before": {
                    **snapshot,
                    "artifact_id": f"{endpoint_id}-trust-before",
                },
                "after": {
                    **snapshot,
                    "artifact_id": f"{endpoint_id}-trust-after",
                },
                "unchanged": True,
            }
        )
        cleanup_record = {
            **bindings,
            "endpoint_id": endpoint_id,
            "owner_binding_sha256": digest(f"owner-{index}"),
            "result": "owner_verified_and_released",
            "artifact_id": f"{endpoint_id}-cleanup",
        }
        add_json_artifact(
            root,
            artifacts,
            artifact_id=f"{endpoint_id}-cleanup",
            kind="cleanup_record",
            relative_path=f"raw/{endpoint_id}/cleanup.json",
            value={
                "kind": "cleanup_record",
                **bindings,
                "endpoint_id": endpoint_id,
                "owner_binding_sha256": cleanup_record["owner_binding_sha256"],
                "result": "owner_verified_and_released",
                "ownership_verified": True,
                "session_terminated": True,
                "foreign_resources_touched": False,
            },
        )
        cleanup_records.append(cleanup_record)

    return {
        "schema_version": 1,
        "contract_id": "policy-purpose-bound-session/experiment-evidence/v1",
        "evidence_id": "physical-file-interop-test-run",
        "evidence_class": "physical_product_interop",
        "product_scope": "bidirectional_file_transfer_v1",
        "claim_eligible": True,
        "bindings": bindings,
        "related_claim_ids": [
            "BS-FILE-DURABLE-RECEIPT",
            "BS-NONAPPLE-INTEROP",
        ],
        "claimed_claim_ids": [
            "BS-FILE-DURABLE-RECEIPT",
            "BS-NONAPPLE-INTEROP",
        ],
        "preregistration": {
            "run_binding_sha256": run_binding,
            "registered_at": registered_at,
            "protocol_document_sha256": protocol_digest,
            "protocol_artifact_id": "preregistration-protocol",
        },
        "timing": {
            "run_started_at": "2026-08-12T09:05:00Z",
            "run_completed_at": "2026-08-12T09:15:00Z",
        },
        "artifacts": artifacts,
        "frozen_source": {
            "repository_id": "policy-purpose-bound-session",
            "commit": "a" * 40,
            "freeze_artifact_id": "source-freeze",
        },
        "endpoints": endpoints,
        "transport": {
            **bindings,
            "protocol": "webrtc_data_channel",
            "pair_correlation_sha256": digest("selected-candidate-pair"),
            "reports": ice_reports,
        },
        "cryptography": {
            **bindings,
            "protocol_id": "bound-session/1",
            "suite_id": 0x0012,
            "suite_name": "Q-Periapt-ABI2-PolicyBound",
            "kem_combination": "ML-KEM-768+X25519",
            "hybrid_profile_id": 2,
            "reports": crypto_reports,
        },
        "file_transfers": transfers,
        "trust_state": trust_state,
        "cleanup": {
            **bindings,
            "ownership_verified": True,
            "session_terminated": True,
            "foreign_resources_touched": False,
            "records": cleanup_records,
        },
        "unsupported_product_claims": [
            {
                "feature": "messages",
                "status": "not_claimed",
                "reason": "This contract measures file transfer only.",
            },
            {
                "feature": "remote_desktop",
                "status": "not_claimed",
                "reason": "No presentation or input effect is measured.",
            },
        ],
        "limitations": [
            "Artifact hashes do not attest an operator or endpoint.",
            "Remote desktop and messages are outside this contract.",
        ],
    }


class ExperimentEvidenceValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        self.manifest = valid_claim_eligible_manifest(self.root)

    def validate(self, manifest: dict | None = None) -> None:
        validate_manifest(
            self.manifest if manifest is None else manifest,
            artifact_root=self.root,
        )

    def test_canonical_schema_matches_validator_contract(self) -> None:
        schema = load_json_document(SCHEMA_PATH, label="schema")
        validate_schema_contract(schema)

    def test_malformed_schema_enum_fails_with_controlled_error(self) -> None:
        schema = load_json_document(SCHEMA_PATH, label="schema")
        schema["$defs"]["claim_id"]["enum"][0] = {}
        with self.assertRaisesRegex(ValidationError, "safe non-empty"):
            validate_schema_contract(schema)

    def test_json_schema_executor_rejects_additional_manifest_property(self) -> None:
        self.manifest["unexpected_evidence"] = True
        with self.assertRaisesRegex(
            ValidationError, "additional properties are forbidden"
        ):
            self.validate()

    def test_schema_additional_properties_weakening_is_rejected(self) -> None:
        schema = load_json_document(SCHEMA_PATH, label="schema")
        schema["$defs"]["trust_snapshot"]["additionalProperties"] = True
        with self.assertRaisesRegex(ValidationError, "additionalProperties=false"):
            validate_schema_contract(schema)

    def test_schema_unknown_keyword_is_rejected(self) -> None:
        schema = load_json_document(SCHEMA_PATH, label="schema")
        schema["$defs"]["trust_snapshot"]["ignoredWeakening"] = True
        with self.assertRaisesRegex(ValidationError, "unsupported keywords"):
            validate_schema_contract(schema)

    def test_schema_oneof_cannot_hide_sibling_constraints(self) -> None:
        schema = load_json_document(SCHEMA_PATH, label="schema")
        schema["$defs"]["trust_snapshot"]["oneOf"] = [{"type": "object"}]
        with self.assertRaisesRegex(ValidationError, "oneOf with sibling keywords"):
            validate_schema_contract(schema)

    def test_schema_keyword_types_are_strict(self) -> None:
        mutations = (
            ("uniqueItems", 1, "boolean"),
            ("maxItems", True, "non-negative integer"),
        )
        for keyword, value, error_pattern in mutations:
            with self.subTest(keyword=keyword):
                schema = load_json_document(SCHEMA_PATH, label="schema")
                schema["properties"]["related_claim_ids"][keyword] = value
                with self.assertRaisesRegex(ValidationError, error_pattern):
                    validate_schema_contract(schema)

    def test_valid_claim_eligible_physical_interop_is_accepted(self) -> None:
        self.validate()

    def test_preregistration_must_bind_canonical_protocol_document(self) -> None:
        stale_digest = digest("stale-preregistration-protocol")
        self.manifest["preregistration"]["protocol_document_sha256"] = stale_digest
        update_raw_json(
            self.root,
            self.manifest,
            "preregistration-protocol",
            protocol_document_sha256=stale_digest,
        )
        with self.assertRaisesRegex(ValidationError, "canonical experiment protocol"):
            self.validate()

    def test_preregistration_run_binding_cannot_be_spliced(self) -> None:
        self.manifest["preregistration"]["run_binding_sha256"] = digest(
            "another-run"
        )
        with self.assertRaisesRegex(ValidationError, "manifest run binding"):
            self.validate()

    def test_source_capability_can_retain_complete_observations_but_not_claim(self) -> None:
        self.manifest["evidence_class"] = "source_capability"
        self.manifest["claim_eligible"] = False
        self.manifest["claimed_claim_ids"] = []
        self.validate()

    def test_diagnostic_and_source_capability_are_never_claim_eligible(self) -> None:
        for evidence_class in ("diagnostic", "source_capability"):
            with self.subTest(evidence_class=evidence_class):
                manifest = copy.deepcopy(self.manifest)
                manifest["evidence_class"] = evidence_class
                with self.assertRaisesRegex(ValidationError, "never claim eligible"):
                    self.validate(manifest)

    def test_physical_interop_rejects_emulator_endpoint(self) -> None:
        self.manifest["endpoints"][1]["execution_environment"] = "emulator"
        with self.assertRaisesRegex(ValidationError, "cannot include"):
            self.validate()

    def test_both_builds_must_use_same_frozen_commit(self) -> None:
        self.manifest["endpoints"][1]["build"]["frozen_commit"] = "d" * 40
        update_raw_json(
            self.root,
            self.manifest,
            "endpoint-b-build-record",
            frozen_commit="d" * 40,
        )
        with self.assertRaisesRegex(ValidationError, "same frozen commit"):
            self.validate()

    def test_dirty_build_is_not_claim_eligible(self) -> None:
        self.manifest["endpoints"][0]["build"]["source_tree_state"] = "dirty"
        update_raw_json(
            self.root,
            self.manifest,
            "endpoint-a-build-record",
            source_tree_state="dirty",
        )
        with self.assertRaisesRegex(ValidationError, "clean source tree"):
            self.validate()

    def test_unknown_selected_ice_pair_is_rejected(self) -> None:
        self.manifest["transport"]["reports"][0]["candidate_pair_id"] = "UNKNOWN"
        update_raw_json(
            self.root,
            self.manifest,
            "endpoint-a-selected-ice",
            candidate_pair_id="UNKNOWN",
        )
        with self.assertRaisesRegex(ValidationError, "non-UNKNOWN ICE pair"):
            self.validate()

    def test_unselected_or_non_succeeded_ice_is_rejected(self) -> None:
        for field, value in (("selected", False), ("state", "checking")):
            with self.subTest(field=field):
                temporary_directory = tempfile.TemporaryDirectory()
                self.addCleanup(temporary_directory.cleanup)
                root = Path(temporary_directory.name)
                manifest = valid_claim_eligible_manifest(root)
                manifest["transport"]["reports"][0][field] = value
                update_raw_json(
                    root,
                    manifest,
                    "endpoint-a-selected-ice",
                    **{field: value},
                )
                with self.assertRaisesRegex(ValidationError, "selected, succeeded"):
                    validate_manifest(manifest, artifact_root=root)

    def test_classic_or_unspecified_suite_is_rejected(self) -> None:
        self.manifest["cryptography"]["suite_id"] = 0x1001
        self.manifest["cryptography"]["suite_name"] = "X25519"
        self.manifest["cryptography"]["kem_combination"] = "X25519"
        for endpoint_id in ("endpoint-a", "endpoint-b"):
            update_raw_json(
                self.root,
                self.manifest,
                f"{endpoint_id}-pqc-session",
                suite_name="X25519",
                kem_combination="X25519",
            )
        with self.assertRaisesRegex(ValidationError, "PQC hybrid suite"):
            self.validate()

    def test_endpoint_pqc_reports_must_bind_same_session(self) -> None:
        self.manifest["cryptography"]["reports"][1]["session_binding_sha256"] = digest(
            "different-session"
        )
        with self.assertRaisesRegex(ValidationError, "run/session bindings"):
            self.validate()

    def test_every_runtime_phase_must_use_one_run_and_session_binding(self) -> None:
        selectors = {
            "ice": lambda value: value["transport"]["reports"][0],
            "transport": lambda value: value["transport"],
            "pqc": lambda value: value["cryptography"]["reports"][0],
            "cryptography": lambda value: value["cryptography"],
            "transfer": lambda value: value["file_transfers"][0],
            "ack": lambda value: value["file_transfers"][0]["durable_ack"],
            "trust": lambda value: value["trust_state"][0],
            "cleanup": lambda value: value["cleanup"],
            "cleanup-record": lambda value: value["cleanup"]["records"][0],
        }
        for label, selector in selectors.items():
            with self.subTest(phase=label):
                temporary_directory = tempfile.TemporaryDirectory()
                self.addCleanup(temporary_directory.cleanup)
                root = Path(temporary_directory.name)
                manifest = valid_claim_eligible_manifest(root)
                selector(manifest)["session_binding_sha256"] = digest(
                    f"spliced-{label}"
                )
                with self.assertRaisesRegex(ValidationError, "run/session bindings"):
                    validate_manifest(manifest, artifact_root=root)

    def test_reverse_file_transfer_is_required(self) -> None:
        self.manifest["file_transfers"] = self.manifest["file_transfers"][:1]
        with self.assertRaisesRegex(ValidationError, "exactly two file transfers"):
            self.validate()

    def test_claim_eligible_file_payloads_must_be_nonempty(self) -> None:
        rewrite_transfer_payload(self.root, self.manifest, 0, b"")
        with self.assertRaisesRegex(ValidationError, "at least one byte"):
            self.validate()

    def test_bidirectional_file_payload_digests_must_differ(self) -> None:
        first = self.manifest["file_transfers"][0]["sender_observation"]
        first_artifact = artifact_record(self.manifest, first["artifact_id"])
        content = (self.root / first_artifact["path"]).read_bytes()
        rewrite_transfer_payload(self.root, self.manifest, 1, content)
        with self.assertRaisesRegex(ValidationError, "distinct payload digests"):
            self.validate()

    def test_receiver_byte_count_mismatch_is_rejected(self) -> None:
        self.manifest["file_transfers"][0]["receiver_observation"]["bytes"] += 1
        with self.assertRaisesRegex(ValidationError, "raw file artifact"):
            self.validate()

    def test_receiver_content_digest_mismatch_is_rejected(self) -> None:
        self.manifest["file_transfers"][0]["receiver_observation"]["sha256"] = digest(
            "different-content"
        )
        with self.assertRaisesRegex(ValidationError, "raw file artifact"):
            self.validate()

    def test_durable_ack_must_match_bytes_and_digest(self) -> None:
        self.manifest["file_transfers"][0]["durable_ack"]["bytes"] += 1
        update_raw_json(
            self.root,
            self.manifest,
            "a-to-b-ack",
            bytes=self.manifest["file_transfers"][0]["durable_ack"]["bytes"],
        )
        with self.assertRaisesRegex(ValidationError, "matching durable authenticated ACK"):
            self.validate()

    def test_durable_ack_cannot_claim_commit_without_durable_observation(self) -> None:
        self.manifest["file_transfers"][0]["durable_ack"][
            "durable_commit_observed"
        ] = False
        with self.assertRaisesRegex(ValidationError, "complete durable authenticated evidence"):
            self.validate()

    def test_durable_ack_requires_bound_receipt_and_named_primitive(self) -> None:
        for field, value in (
            ("ack_protocol", None),
            ("durability_primitive", None),
        ):
            with self.subTest(field=field):
                manifest = copy.deepcopy(self.manifest)
                manifest["file_transfers"][0]["durable_ack"][field] = value
                with self.assertRaisesRegex(
                    ValidationError, "complete durable authenticated evidence"
                ):
                    self.validate(manifest)

    def test_changed_trust_state_cannot_be_marked_unchanged(self) -> None:
        self.manifest["trust_state"][0]["after"]["authority_epoch"] += 1
        with self.assertRaisesRegex(ValidationError, "marks changed trust state"):
            self.validate()

    def test_claim_eligibility_requires_unchanged_trust_flag(self) -> None:
        self.manifest["trust_state"][0]["unchanged"] = False
        with self.assertRaisesRegex(ValidationError, "trust state must remain unchanged"):
            self.validate()

    def test_cleanup_ownership_must_be_verified(self) -> None:
        self.manifest["cleanup"]["ownership_verified"] = False
        for endpoint_id in ("endpoint-a", "endpoint-b"):
            update_raw_json(
                self.root,
                self.manifest,
                f"{endpoint_id}-cleanup",
                ownership_verified=False,
            )
        with self.assertRaisesRegex(ValidationError, "cleanup must verify ownership"):
            self.validate()

    def test_cleanup_cannot_touch_foreign_resources(self) -> None:
        self.manifest["cleanup"]["foreign_resources_touched"] = True
        for endpoint_id in ("endpoint-a", "endpoint-b"):
            update_raw_json(
                self.root,
                self.manifest,
                f"{endpoint_id}-cleanup",
                foreign_resources_touched=True,
            )
        with self.assertRaisesRegex(ValidationError, "avoid foreign resources"):
            self.validate()

    def test_hash_valid_but_semantically_stale_raw_records_are_rejected(self) -> None:
        scenarios = {
            "build": ("endpoint-a-build-record", {"product_revision": "d" * 40}),
            "ice": (
                "endpoint-a-selected-ice",
                {"candidate_pair_id": "stale-selected-pair"},
            ),
            "pqc": ("endpoint-a-pqc-session", {"suite_name": "stale-suite"}),
            "transfer": ("a-to-b-record", {"transfer_id_sha256": digest("stale")}),
            "durable-commit": ("a-to-b-commit", {"sha256": digest("stale")}),
            "durable-ack": ("a-to-b-ack", {"sha256": digest("stale")}),
            "trust": ("endpoint-a-trust-before", {"authority_epoch": 8}),
            "cleanup": (
                "endpoint-a-cleanup",
                {"owner_binding_sha256": digest("stale-owner")},
            ),
        }
        for label, (artifact_id, updates) in scenarios.items():
            with self.subTest(raw_kind=label):
                temporary_directory = tempfile.TemporaryDirectory()
                self.addCleanup(temporary_directory.cleanup)
                root = Path(temporary_directory.name)
                manifest = valid_claim_eligible_manifest(root)
                update_raw_json(root, manifest, artifact_id, **updates)
                with self.assertRaisesRegex(
                    ValidationError, "raw evidence content does not match manifest"
                ):
                    validate_manifest(manifest, artifact_root=root)

    def test_hash_valid_raw_record_cannot_splice_another_session(self) -> None:
        update_raw_json(
            self.root,
            self.manifest,
            "endpoint-a-selected-ice",
            session_binding_sha256=digest("stale-session"),
        )
        with self.assertRaisesRegex(
            ValidationError, "raw evidence content does not match manifest"
        ):
            self.validate()

    def test_raw_json_additional_property_is_rejected_by_schema(self) -> None:
        update_raw_json(
            self.root,
            self.manifest,
            "endpoint-a-build-record",
            unbound_note="must not be ignored",
        )
        with self.assertRaisesRegex(
            ValidationError, "additional properties are forbidden"
        ):
            self.validate()

    def test_remote_desktop_and_messages_must_remain_not_claimed(self) -> None:
        self.manifest["unsupported_product_claims"][1]["status"] = "passed"
        with self.assertRaisesRegex(ValidationError, "value differs from const"):
            self.validate()

    def test_android_ios_cannot_add_remote_desktop_claim(self) -> None:
        self.manifest["related_claim_ids"].append("BS-REMOTE-DESKTOP-RECEIPT")
        self.manifest["claimed_claim_ids"].append("BS-REMOTE-DESKTOP-RECEIPT")
        with self.assertRaisesRegex(ValidationError, "outside enum"):
            self.validate()

    def test_nonapple_claim_requires_one_apple_and_one_nonapple_endpoint(self) -> None:
        self.manifest["endpoints"][1]["platform"] = "macos"
        update_raw_json(
            self.root,
            self.manifest,
            "endpoint-b-device-record",
            platform="macos",
        )
        with self.assertRaisesRegex(ValidationError, "one Apple and one non-Apple"):
            self.validate()

    def test_artifact_digest_is_rehashed_from_disk(self) -> None:
        self.manifest["artifacts"][0]["sha256"] = "f" * 64
        with self.assertRaisesRegex(ValidationError, "SHA-256 mismatch"):
            self.validate()

    def test_per_artifact_size_limit_is_enforced_before_reading(self) -> None:
        artifact = artifact_record(self.manifest, "endpoint-a-build-record")
        artifact["size_bytes"] = MAX_RAW_JSON_ARTIFACT_BYTES + 1
        with self.assertRaisesRegex(ValidationError, "artifact limit"):
            self.validate()

    def test_total_artifact_size_limit_is_enforced_before_reading(self) -> None:
        large_records = [
            artifact
            for artifact in self.manifest["artifacts"]
            if artifact["kind"] in {"binary", "file_source", "file_receiver"}
        ][:5]
        per_artifact_size = MAX_TOTAL_ARTIFACT_BYTES // 4
        for artifact in large_records:
            artifact["size_bytes"] = per_artifact_size
        with self.assertRaisesRegex(ValidationError, "package limit"):
            self.validate()

    def test_fstat_detects_artifact_change_during_hashing(self) -> None:
        real_fstat = os.fstat
        calls = 0

        class ChangedStat:
            def __init__(self, original: os.stat_result) -> None:
                self.original = original

            def __getattr__(self, name: str) -> object:
                if name == "st_mtime_ns":
                    return self.original.st_mtime_ns + 1
                return getattr(self.original, name)

        def changing_fstat(file_descriptor: int) -> os.stat_result | ChangedStat:
            nonlocal calls
            calls += 1
            current = real_fstat(file_descriptor)
            return ChangedStat(current) if calls == 2 else current

        with patch(
            "artifact.validate_experiment_evidence.os.fstat",
            side_effect=changing_fstat,
        ):
            with self.assertRaisesRegex(ValidationError, "changed while"):
                self.validate()

    @unittest.skipUnless(hasattr(os, "mkfifo"), "POSIX FIFO support is required")
    def test_nonregular_artifact_is_rejected_without_blocking(self) -> None:
        artifact = artifact_record(self.manifest, "preregistration-protocol")
        path = self.root / artifact["path"]
        path.unlink()
        os.mkfifo(path)
        artifact["size_bytes"] = 0
        artifact["sha256"] = digest(b"")
        with self.assertRaisesRegex(ValidationError, "not a regular file"):
            self.validate()

    def test_artifact_path_traversal_is_rejected(self) -> None:
        self.manifest["artifacts"][0]["path"] = "../outside.md"
        with self.assertRaisesRegex(ValidationError, "canonical relative POSIX"):
            self.validate()

    def test_artifact_symlink_is_rejected(self) -> None:
        artifact = self.manifest["artifacts"][0]
        path = self.root / artifact["path"]
        target = self.root / "raw" / "real-preregistration.md"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        with self.assertRaisesRegex(ValidationError, "cannot be opened safely"):
            self.validate()

    def test_artifact_hardlink_alias_is_rejected(self) -> None:
        original = self.root / self.manifest["artifacts"][0]["path"]
        alias = self.root / "raw" / "hardlink-alias.md"
        alias.hardlink_to(original)
        self.manifest["artifacts"].append(
            {
                "id": "hardlink-alias",
                "kind": "preregistration",
                "path": "raw/hardlink-alias.md",
                "sha256": digest(original.read_bytes()),
                "size_bytes": original.stat().st_size,
                "media_type": "application/json",
            }
        )
        with self.assertRaisesRegex(ValidationError, "hard link|aliases another artifact"):
            self.validate()

    def test_unused_artifact_is_rejected(self) -> None:
        add_artifact(
            self.root,
            self.manifest["artifacts"],
            artifact_id="unused-record",
            kind="build_record",
            relative_path="raw/unused.json",
            content="{}\n",
        )
        with self.assertRaisesRegex(ValidationError, "declared but not used"):
            self.validate()

    def test_preregistration_must_precede_run(self) -> None:
        self.manifest["preregistration"]["registered_at"] = "2026-08-12T09:06:00Z"
        with self.assertRaisesRegex(ValidationError, "must precede"):
            self.validate()

    def test_duplicate_json_key_is_rejected(self) -> None:
        manifest_path = self.root / "duplicate.json"
        manifest_path.write_text(
            '{"schema_version":1,"schema_version":1}\n', encoding="utf-8"
        )
        with self.assertRaisesRegex(ValidationError, "duplicate JSON key"):
            load_json_document(manifest_path, label="manifest")

    def test_oversized_manifest_is_rejected_before_parsing(self) -> None:
        manifest_path = self.root / "oversized.json"
        manifest_path.write_bytes(b" " * (MAX_JSON_BYTES + 1))
        with self.assertRaisesRegex(ValidationError, "exceeds"):
            load_json_document(manifest_path, label="manifest")

    def test_cli_validates_manifest_and_schema(self) -> None:
        manifest_path = self.root / "manifest.json"
        manifest_path.write_text(
            json.dumps(self.manifest, indent=2) + "\n", encoding="utf-8"
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            result = main(
                [
                    str(manifest_path),
                    "--artifact-root",
                    str(self.root),
                ]
            )
        self.assertEqual(result, 0, stderr.getvalue())
        self.assertIn("claim_eligible=true", stdout.getvalue())
        self.assertEqual(stderr.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
