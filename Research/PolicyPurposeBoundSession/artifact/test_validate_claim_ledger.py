from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

from artifact.validate_claim_ledger import (
    ValidationError,
    load_ledger,
    validate_evidence_ref,
    validate_ledger,
)


ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / "artifact" / "claim-ledger.json"


class ClaimLedgerValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.valid = load_ledger(LEDGER)

    def validate(self, value: dict[str, object]) -> None:
        validate_ledger(value, evidence_root=ROOT)

    def test_repository_ledger_is_valid(self) -> None:
        self.validate(self.valid)

    def test_evidence_root_is_required_by_import_api(self) -> None:
        with self.assertRaises(TypeError):
            validate_ledger(self.valid)

    def test_none_evidence_root_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValidationError, "explicit pathlib.Path"):
            validate_ledger(self.valid, evidence_root=None)

    def test_duplicate_claim_id_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["claims"].append(copy.deepcopy(value["claims"][0]))
        with self.assertRaisesRegex(ValidationError, "duplicate claim id"):
            self.validate(value)

    def test_passed_status_is_disabled_even_with_apparent_evidence(self) -> None:
        value = copy.deepcopy(self.valid)
        claim = value["claims"][1]
        claim["status"] = "passed"
        claim["evidence_refs"] = ["protocol/BOUND_SESSION_V1.md"]
        claim["last_verified_at"] = "2026-07-29T00:00:00Z"
        with self.assertRaisesRegex(ValidationError, "passed, which is disabled"):
            self.validate(value)

    def test_schema_boolean_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["schema_version"] = True
        with self.assertRaisesRegex(ValidationError, "integer 1"):
            self.validate(value)

    def test_missing_required_claim_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["claims"].pop()
        with self.assertRaisesRegex(ValidationError, "claim set mismatch"):
            self.validate(value)

    def test_evidence_path_traversal_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["claims"][0]["evidence_refs"] = ["../../etc/passwd"]
        with self.assertRaisesRegex(ValidationError, "escapes the evidence root"):
            self.validate(value)

    def test_missing_evidence_file_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["claims"][0]["evidence_refs"] = ["protocol/does-not-exist.md"]
        with self.assertRaisesRegex(ValidationError, "cannot resolve"):
            self.validate(value)

    def test_nul_evidence_path_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["claims"][0]["evidence_refs"] = ["protocol/BOUND\x00SESSION.md"]
        with self.assertRaisesRegex(ValidationError, "NUL byte"):
            self.validate(value)

    def test_leaf_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target.md"
            target.write_text("evidence", encoding="utf-8")
            link = root / "link.md"
            link.symlink_to(target)
            with self.assertRaisesRegex(ValidationError, "traverses a symlink"):
                validate_evidence_ref("link.md", root, "test")

    def test_intermediate_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outside = root / "outside"
            outside.mkdir()
            (outside / "evidence.md").write_text("evidence", encoding="utf-8")
            link = root / "linked"
            link.symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(ValidationError, "traverses a symlink"):
                validate_evidence_ref("linked/evidence.md", root, "test")

    def test_duplicate_evidence_class_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        classes = value["claims"][0]["required_evidence_classes"]
        classes.append(classes[0])
        with self.assertRaisesRegex(ValidationError, "contains duplicates"):
            self.validate(value)

    def test_unknown_status_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["claims"][0]["status"] = "complete"
        with self.assertRaisesRegex(ValidationError, "status is not allowed"):
            self.validate(value)

    def test_unhashable_status_is_rejected_with_controlled_error(self) -> None:
        value = copy.deepcopy(self.valid)
        value["claims"][0]["status"] = []
        with self.assertRaisesRegex(ValidationError, "status is not allowed"):
            self.validate(value)

    def test_required_evidence_classes_cannot_be_weakened(self) -> None:
        value = copy.deepcopy(self.valid)
        value["claims"][1]["required_evidence_classes"].pop()
        with self.assertRaisesRegex(ValidationError, "must equal"):
            self.validate(value)

    def test_all_zero_source_revision_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["source_inputs"]["skybridge"]["revision"] = "0" * 40
        with self.assertRaisesRegex(ValidationError, "all-zero sentinel"):
            self.validate(value)

    def test_duplicate_json_key_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text(
                '{"schema_version":1,"schema_version":1}', encoding="utf-8"
            )
            with self.assertRaisesRegex(ValidationError, "duplicate JSON key"):
                load_ledger(path)

    def test_non_passed_claim_cannot_carry_verified_timestamp(self) -> None:
        value = copy.deepcopy(self.valid)
        value["claims"][0]["last_verified_at"] = "9999-99-99T99:99:99Z"
        with self.assertRaisesRegex(ValidationError, "carries last_verified_at"):
            self.validate(value)


if __name__ == "__main__":
    unittest.main()
