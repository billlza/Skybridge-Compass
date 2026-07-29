from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

from submission.validate_manuscript_metadata import (
    ValidationError,
    load_metadata,
    normalize_pdf_text,
    parse_pdfinfo,
    require_tool,
    render_generated_tex,
    run_checked,
    strip_tex_comments,
    validate_full_pdf_text,
    validate_generated_tex,
    validate_metadata,
    validate_pdfinfo_fields,
    validate_sources,
    validate_tex_source_text,
    validate_visible_pdf_text,
    write_generated_tex,
)


ROOT = Path(__file__).resolve().parents[1]
METADATA = ROOT / "submission" / "manuscript-metadata.json"


class ManuscriptMetadataValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.valid = load_metadata(METADATA)

    def test_repository_metadata_and_sources_are_valid(self) -> None:
        validate_metadata(self.valid)
        validate_sources(ROOT, self.valid, render_generated_tex(self.valid))

    def test_schema_boolean_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["schema_version"] = True
        with self.assertRaisesRegex(ValidationError, "integer 1"):
            validate_metadata(value)

    def test_second_author_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["authors"].append(copy.deepcopy(value["authors"][0]))
        with self.assertRaisesRegex(ValidationError, "exactly one author"):
            validate_metadata(value)

    def test_non_single_anonymized_policy_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["review_policy"]["model"] = "double-blind"
        with self.assertRaisesRegex(ValidationError, "single-anonymized"):
            validate_metadata(value)

    def test_false_corresponding_flag_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["authors"][0]["corresponding"] = False
        with self.assertRaisesRegex(ValidationError, "corresponding author"):
            validate_metadata(value)

    def test_historical_coauthor_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["authors"][0]["display_name"] = "Peng Liu"
        with self.assertRaisesRegex(ValidationError, "forbidden historical identity"):
            validate_metadata(value)

    def test_invalid_email_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["authors"][0]["email_status"] = "confirmed_current"
        value["authors"][0]["email"] = "not-an-email"
        with self.assertRaisesRegex(ValidationError, "canonical email"):
            validate_metadata(value)

    def test_pending_email_must_be_null(self) -> None:
        value = copy.deepcopy(self.valid)
        value["authors"][0]["email_status"] = "pending_confirmation"
        value["authors"][0]["email"] = "author@example.com"
        with self.assertRaisesRegex(ValidationError, "must be null"):
            validate_metadata(value)

    def test_submission_validation_requires_confirmed_email(self) -> None:
        value = copy.deepcopy(self.valid)
        value["authors"][0]["email_status"] = "pending_confirmation"
        value["authors"][0]["email"] = None
        with self.assertRaisesRegex(ValidationError, "confirmed current"):
            validate_metadata(value, require_confirmed_email=True)

    def test_confirmed_email_is_valid(self) -> None:
        value = copy.deepcopy(self.valid)
        value["authors"][0]["email_status"] = "confirmed_current"
        value["authors"][0]["email"] = "author@example.com"
        validate_metadata(value, require_confirmed_email=True)

    def test_unknown_metadata_key_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["unexpected"] = "value"
        with self.assertRaisesRegex(ValidationError, r"unknown=\['unexpected'\]"):
            validate_metadata(value)

    def test_malformed_policy_url_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["review_policy"]["source"] = "https://["
        with self.assertRaisesRegex(ValidationError, "not a valid URL"):
            validate_metadata(value)

    def test_control_character_is_rejected(self) -> None:
        value = copy.deepcopy(self.valid)
        value["authors"][0]["institution"] = "Durham\tUniversity"
        with self.assertRaisesRegex(ValidationError, "control or format"):
            validate_metadata(value)

    def test_duplicate_json_key_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text(
                '{"schema_version":1,"schema_version":1}', encoding="utf-8"
            )
            with self.assertRaisesRegex(ValidationError, "duplicate JSON key"):
                load_metadata(path)

    def test_tex_renderer_escapes_metadata(self) -> None:
        value = copy.deepcopy(self.valid)
        value["authors"][0]["institution"] = "Research & Development"
        value["authors"][0]["email_status"] = "pending_confirmation"
        value["authors"][0]["email"] = None
        rendered = render_generated_tex(value)
        self.assertIn(r"Research \& Development", rendered)
        self.assertNotIn("@", rendered)

    def test_stale_generated_tex_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manuscript-metadata.tex"
            path.write_text("stale\n", encoding="utf-8")
            with self.assertRaisesRegex(ValidationError, "generated metadata is stale"):
                validate_generated_tex(path, "expected\n")

    def test_generated_tex_write_is_idempotent_and_world_readable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manuscript-metadata.tex"
            write_generated_tex(path, "generated\n")
            first = path.stat()
            write_generated_tex(path, "generated\n")
            second = path.stat()
            self.assertEqual(first.st_ino, second.st_ino)
            self.assertEqual(first.st_mtime_ns, second.st_mtime_ns)
            self.assertEqual(second.st_mode & 0o777, 0o644)

    def test_source_without_shared_configuration_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValidationError, "PaperConfigureMainDocument"):
            validate_tex_source_text(
                "\\input{generated/manuscript-metadata}\n",
                path=Path("paper/main.tex"),
                configuration_macro=r"\PaperConfigureMainDocument",
                forbidden_configuration_macro=r"\PaperConfigureSupplementDocument",
                literal_values=(),
            )

    def test_commented_configuration_does_not_count(self) -> None:
        with self.assertRaisesRegex(ValidationError, "found 0"):
            validate_tex_source_text(
                "\\input{generated/manuscript-metadata}\n"
                "% \\PaperConfigureMainDocument\n",
                path=Path("paper/main.tex"),
                configuration_macro=r"\PaperConfigureMainDocument",
                forbidden_configuration_macro=r"\PaperConfigureSupplementDocument",
                literal_values=(),
            )

    def test_extra_active_author_or_title_is_rejected(self) -> None:
        source = (
            "\\input{generated/manuscript-metadata}\n"
            "\\PaperConfigureMainDocument\n"
            "\\author{Wrong Author}\n"
        )
        with self.assertRaisesRegex(ValidationError, "front-matter command"):
            validate_tex_source_text(
                source,
                path=Path("paper/main.tex"),
                configuration_macro=r"\PaperConfigureMainDocument",
                forbidden_configuration_macro=r"\PaperConfigureSupplementDocument",
                literal_values=(),
            )

    def test_commented_extra_title_is_ignored(self) -> None:
        source = (
            "\\input{generated/manuscript-metadata}\n"
            "\\PaperConfigureMainDocument\n"
            "% \\title{Comment only}\n"
        )
        validate_tex_source_text(
            source,
            path=Path("paper/main.tex"),
            configuration_macro=r"\PaperConfigureMainDocument",
            forbidden_configuration_macro=r"\PaperConfigureSupplementDocument",
            literal_values=(),
        )

    def test_tex_comment_stripper_preserves_escaped_percent(self) -> None:
        self.assertEqual(strip_tex_comments("value \\% kept % removed\n"), "value \\% kept \n")

    def test_pdfinfo_parser_preserves_apostrophe(self) -> None:
        fields = parse_pdfinfo("Title: Draft\nAuthor: Zi'ang Li\nPages: 5\n")
        self.assertEqual(fields["Author"], "Zi'ang Li")

    def test_pdf_text_normalizes_typeset_apostrophe(self) -> None:
        self.assertEqual(normalize_pdf_text("Zi\u2019ang  Li"), "Zi'ang Li")

    def test_missing_external_tool_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValidationError, "tool is unavailable"):
            require_tool("bound-session-tool-that-does-not-exist")

    def test_external_tool_nonzero_exit_is_rejected(self) -> None:
        false_command = require_tool("false")
        with self.assertRaisesRegex(ValidationError, "failed with status"):
            run_checked([false_command], "negative-control tool")

    def test_pdfinfo_author_mismatch_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValidationError, "Author metadata"):
            validate_pdfinfo_fields(
                {
                    "Author": "Anonymous",
                    "Title": self.valid["title"],
                    "Subject": "subject",
                    "Keywords": "keywords",
                },
                path=Path("paper/main.pdf"),
                expected_author=self.valid["authors"][0]["display_name"],
                expected_title=self.valid["title"],
            )

    def test_pdfinfo_empty_subject_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValidationError, "empty Subject"):
            validate_pdfinfo_fields(
                {
                    "Author": self.valid["authors"][0]["display_name"],
                    "Title": self.valid["title"],
                    "Subject": "",
                    "Keywords": "keywords",
                },
                path=Path("paper/main.pdf"),
                expected_author=self.valid["authors"][0]["display_name"],
                expected_title=self.valid["title"],
            )

    def test_visible_pdf_text_requires_all_identity_fields(self) -> None:
        author = self.valid["authors"][0]
        incomplete = (
            f"{self.valid['title']} "
            f"{author['display_name']} "
            f"{author['institution']}, {author['city']}, {author['country']} "
        )
        with self.assertRaisesRegex(ValidationError, "MSc by Research"):
            validate_visible_pdf_text(
                incomplete,
                path=Path("paper/main.pdf"),
                value=self.valid,
                expected_visible_title=self.valid["title"],
            )

    def test_visible_pdf_text_requires_expected_title(self) -> None:
        author = self.valid["authors"][0]
        complete = (
            f"Wrong Title {author['display_name']} "
            f"{author['degree']} {author['academic_role']} "
            f"{author['institution']}, {author['city']}, {author['country']} "
        )
        with self.assertRaisesRegex(ValidationError, "Policy-to-Purpose"):
            validate_visible_pdf_text(
                complete,
                path=Path("paper/main.pdf"),
                value=self.valid,
                expected_visible_title=self.valid["title"],
            )

    def test_full_pdf_text_rejects_anonymous_marker(self) -> None:
        with self.assertRaisesRegex(ValidationError, "forbidden historical identity"):
            validate_full_pdf_text(
                "Anonymous Author",
                path=Path("paper/main.pdf"),
                value=self.valid,
            )

    def test_pending_email_is_rejected_from_pdf_text(self) -> None:
        value = copy.deepcopy(self.valid)
        value["authors"][0]["email_status"] = "pending_confirmation"
        value["authors"][0]["email"] = None
        with self.assertRaisesRegex(ValidationError, "confirmation is pending"):
            validate_full_pdf_text(
                "author@example.com",
                path=Path("paper/main.pdf"),
                value=value,
            )


if __name__ == "__main__":
    unittest.main()
