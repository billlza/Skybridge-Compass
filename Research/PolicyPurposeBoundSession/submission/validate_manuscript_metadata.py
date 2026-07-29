#!/usr/bin/env python3
"""Validate and render the single-source manuscript identity metadata."""

from __future__ import annotations

import argparse
from collections.abc import Iterator
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
from datetime import date
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


class ValidationError(ValueError):
    """Manuscript metadata or a derived artifact violates the identity contract."""


ROOT_KEYS = {"schema_version", "title", "review_policy", "authors"}
REVIEW_POLICY_KEYS = {"model", "checked_at", "source"}
AUTHOR_KEYS = {
    "display_name",
    "academic_role",
    "degree",
    "institution",
    "city",
    "country",
    "email",
    "email_status",
    "corresponding",
}
ALLOWED_EMAIL_STATUSES = {
    "pending_confirmation",
    "confirmed_current",
}
OFFICIAL_POLICY_HOST = "signalprocessingsociety.org"
FORBIDDEN_IDENTITY_TEXT = (
    "Anonymous Author",
    "anonymous review artifact",
    "Peng Liu",
    "Independent Researcher",
    "double-blind",
)
EMAIL_PATTERN = re.compile(
    r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"
)
EMAIL_SEARCH_PATTERN = re.compile(
    r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@"
    r"[A-Za-z0-9.-]+\.[A-Za-z]{2,}"
)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_metadata(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle, object_pairs_hook=reject_duplicate_keys)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise ValidationError(f"invalid JSON in {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValidationError("metadata root must be an object")
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
    if value != value.strip():
        raise ValidationError(f"{context} must not have surrounding whitespace")
    if unicodedata.normalize("NFC", value) != value:
        raise ValidationError(f"{context} must use NFC-normalized Unicode")
    if any(unicodedata.category(character) in {"Cc", "Cf"} for character in value):
        raise ValidationError(f"{context} must not contain control or format characters")
    return value


def iter_strings(value: Any) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from iter_strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from iter_strings(child)


def reject_forbidden_identity_text(values: Any, context: str) -> None:
    for value in iter_strings(values):
        folded = value.casefold()
        for forbidden in FORBIDDEN_IDENTITY_TEXT:
            if forbidden.casefold() in folded:
                raise ValidationError(
                    f"{context} contains forbidden historical identity text: {forbidden}"
                )


def validate_metadata(
    value: dict[str, Any], *, require_confirmed_email: bool = False
) -> None:
    require_exact_keys(value, ROOT_KEYS, "metadata")
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise ValidationError("schema_version must be the integer 1")
    require_nonempty_string(value["title"], "title")

    review_policy = value["review_policy"]
    if not isinstance(review_policy, dict):
        raise ValidationError("review_policy must be an object")
    require_exact_keys(review_policy, REVIEW_POLICY_KEYS, "review_policy")
    if review_policy["model"] != "single-anonymized":
        raise ValidationError("review_policy.model must equal single-anonymized")
    checked_at = require_nonempty_string(
        review_policy["checked_at"], "review_policy.checked_at"
    )
    try:
        date.fromisoformat(checked_at)
    except ValueError as error:
        raise ValidationError(
            "review_policy.checked_at must be a real ISO 8601 calendar date"
        ) from error
    policy_source = require_nonempty_string(
        review_policy["source"], "review_policy.source"
    )
    try:
        parsed_source = urlparse(policy_source)
        policy_host = parsed_source.hostname
    except ValueError as error:
        raise ValidationError("review_policy.source is not a valid URL") from error
    if parsed_source.scheme != "https" or policy_host != OFFICIAL_POLICY_HOST:
        raise ValidationError(
            "review_policy.source must be an official HTTPS Signal Processing Society URL"
        )

    authors = value["authors"]
    if not isinstance(authors, list) or len(authors) != 1:
        raise ValidationError("authors must contain exactly one author")
    author = authors[0]
    if not isinstance(author, dict):
        raise ValidationError("authors[0] must be an object")
    require_exact_keys(author, AUTHOR_KEYS, "authors[0]")
    for key in AUTHOR_KEYS - {"corresponding", "email"}:
        require_nonempty_string(author[key], f"authors[0].{key}")
    if author["academic_role"] != "student":
        raise ValidationError("authors[0].academic_role must equal student")
    email_status = author["email_status"]
    if email_status not in ALLOWED_EMAIL_STATUSES:
        raise ValidationError(
            "authors[0].email_status must record whether the address is pending or confirmed"
        )
    if email_status == "pending_confirmation":
        if author["email"] is not None:
            raise ValidationError(
                "authors[0].email must be null while confirmation is pending"
            )
    else:
        email = require_nonempty_string(author["email"], "authors[0].email")
        if not EMAIL_PATTERN.fullmatch(email):
            raise ValidationError("authors[0].email is not a canonical email address")
    if require_confirmed_email and email_status != "confirmed_current":
        raise ValidationError(
            "submission validation requires a confirmed current correspondence address"
        )
    if type(author["corresponding"]) is not bool or not author["corresponding"]:
        raise ValidationError("the sole author must be the corresponding author")

    reject_forbidden_identity_text(value, "metadata")


def tex_escape(value: str) -> str:
    replacements = {
        "\\": r"\textbackslash{}",
        "{": r"\{",
        "}": r"\}",
        "$": r"\$",
        "&": r"\&",
        "#": r"\#",
        "%": r"\%",
        "_": r"\_",
        "~": r"\textasciitilde{}",
        "^": r"\textasciicircum{}",
    }
    return "".join(replacements.get(character, character) for character in value)


def render_generated_tex(value: dict[str, Any]) -> str:
    author = value["authors"][0]
    affiliation = ", ".join(
        (author["institution"], author["city"], author["country"])
    )
    email_definition = ""
    email_sentence = ""
    if author["email_status"] == "confirmed_current":
        email_definition = (
            f"\\newcommand{{\\PaperCorrespondingEmail}}"
            f"{{{tex_escape(author['email'])}}}\n"
        )
        email_sentence = " E-mail: \\PaperCorrespondingEmail."
    return "".join(
        [
            "% Generated from submission/manuscript-metadata.json.\n",
            "% Run `make metadata` after changing the canonical JSON.\n",
            "% Do not edit this file by hand.\n",
            f"\\newcommand{{\\PaperMainTitle}}{{{tex_escape(value['title'])}}}\n",
            "\\newcommand{\\PaperSupplementTitle}"
            "{Supplementary Material for ``\\PaperMainTitle''}\n",
            "\\newcommand{\\PaperSupplementPdfTitle}"
            "{Supplementary Material for \\PaperMainTitle}\n",
            f"\\newcommand{{\\PaperAuthorName}}{{{tex_escape(author['display_name'])}}}\n",
            f"\\newcommand{{\\PaperDegree}}{{{tex_escape(author['degree'])}}}\n",
            f"\\newcommand{{\\PaperAcademicRole}}"
            f"{{{tex_escape(author['academic_role'])}}}\n",
            f"\\newcommand{{\\PaperAffiliation}}{{{tex_escape(affiliation)}}}\n",
            email_definition,
            "\\newcommand{\\PaperAuthorDeclaration}{%\n",
            "  \\PaperAuthorName%\n",
            "  \\thanks{The author is an \\PaperDegree{} \\PaperAcademicRole{} at "
            f"\\PaperAffiliation{{}}.{email_sentence}}}%\n",
            "}\n",
            "\\newcommand{\\PaperConfigureMainDocument}{%\n",
            "  \\hypersetup{%\n",
            "    pdftitle={\\PaperMainTitle},%\n",
            "    pdfauthor={\\PaperAuthorName},%\n",
            "    pdfsubject={Independent IEEE TIFS manuscript on policy-bound "
            "post-quantum peer-to-peer sessions},%\n",
            "    pdfkeywords={post-quantum cryptography, hybrid key encapsulation, "
            "authenticated key exchange, peer-to-peer security}%\n",
            "  }%\n",
            "  \\title{\\PaperMainTitle}%\n",
            "  \\author{\\PaperAuthorDeclaration}%\n",
            "}\n",
            "\\newcommand{\\PaperConfigureSupplementDocument}{%\n",
            "  \\hypersetup{%\n",
            "    pdftitle={\\PaperSupplementPdfTitle},%\n",
            "    pdfauthor={\\PaperAuthorName},%\n",
            "    pdfsubject={Supplementary material for an independent IEEE TIFS "
            "manuscript},%\n",
            "    pdfkeywords={post-quantum cryptography, peer-to-peer security, "
            "supplementary material}%\n",
            "  }%\n",
            "  \\title{\\PaperSupplementTitle}%\n",
            "  \\author{\\PaperAuthorDeclaration}%\n",
            "}\n",
        ]
    )


def write_generated_tex(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValidationError(f"generated metadata path must not be a symlink: {path}")
    if path.exists() and path.read_text(encoding="utf-8") == content:
        path.chmod(0o644)
        return
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as handle:
            handle.write(content)
            handle.flush()
            os.fchmod(handle.fileno(), 0o644)
            os.fsync(handle.fileno())
            temporary_path = Path(handle.name)
        os.replace(temporary_path, path)
        temporary_path = None
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def validate_generated_tex(path: Path, expected: str) -> None:
    if path.is_symlink():
        raise ValidationError(f"generated metadata path must not be a symlink: {path}")
    try:
        actual = path.read_text(encoding="utf-8")
    except FileNotFoundError as error:
        raise ValidationError(
            f"generated metadata is missing: {path}; run `make metadata`"
        ) from error
    if actual != expected:
        raise ValidationError(
            f"generated metadata is stale: {path}; run `make metadata`"
        )
    reject_forbidden_identity_text(actual, str(path))


def strip_tex_comments(text: str) -> str:
    stripped_lines: list[str] = []
    for line in text.splitlines(keepends=True):
        comment_index: int | None = None
        for index, character in enumerate(line):
            if character != "%":
                continue
            backslashes = 0
            cursor = index - 1
            while cursor >= 0 and line[cursor] == "\\":
                backslashes += 1
                cursor -= 1
            if backslashes % 2 == 0:
                comment_index = index
                break
        if comment_index is None:
            stripped_lines.append(line)
        elif line.endswith("\n"):
            stripped_lines.append(line[:comment_index] + "\n")
        else:
            stripped_lines.append(line[:comment_index])
    return "".join(stripped_lines)


def validate_tex_source_text(
    text: str,
    *,
    path: Path,
    configuration_macro: str,
    forbidden_configuration_macro: str,
    literal_values: tuple[str, ...],
) -> None:
    active_text = strip_tex_comments(text)
    required_once = (
        r"\input{generated/manuscript-metadata}",
        configuration_macro,
    )
    for required in required_once:
        count = active_text.count(required)
        if count != 1:
            raise ValidationError(
                f"{path} must contain {required!r} exactly once, found {count}"
            )
    forbidden_active = (
        forbidden_configuration_macro,
        r"\title",
        r"\author",
        r"\hypersetup",
        "pdftitle",
        "pdfauthor",
    )
    for forbidden in forbidden_active:
        if forbidden in active_text:
            raise ValidationError(
                f"{path} contains forbidden local front-matter command {forbidden!r}"
            )
    for literal in literal_values:
        if literal in text:
            raise ValidationError(
                f"{path} duplicates canonical metadata literal {literal!r}"
            )
    reject_forbidden_identity_text(text, str(path))


def validate_sources(root: Path, value: dict[str, Any], expected_tex: str) -> None:
    generated_path = root / "paper" / "generated" / "manuscript-metadata.tex"
    validate_generated_tex(generated_path, expected_tex)
    author = value["authors"][0]
    literal_values = tuple(
        literal
        for literal in (
            value["title"],
            author["display_name"],
            author["degree"],
            author["institution"],
            author["email"],
        )
        if isinstance(literal, str)
    )
    for relative_path, configuration_macro, forbidden_configuration_macro in (
        (
            Path("paper/main.tex"),
            r"\PaperConfigureMainDocument",
            r"\PaperConfigureSupplementDocument",
        ),
        (
            Path("paper/supplement.tex"),
            r"\PaperConfigureSupplementDocument",
            r"\PaperConfigureMainDocument",
        ),
    ):
        path = root / relative_path
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError as error:
            raise ValidationError(f"required TeX source is missing: {path}") from error
        validate_tex_source_text(
            text,
            path=path,
            configuration_macro=configuration_macro,
            forbidden_configuration_macro=forbidden_configuration_macro,
            literal_values=literal_values,
        )


def resolve_repository_file(root: Path, relative_value: str, context: str) -> Path:
    relative_path = Path(relative_value)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise ValidationError(f"{context} must be a repository-relative path")
    candidate = root / relative_path
    current = root
    for part in relative_path.parts:
        current = current / part
        if current.is_symlink():
            raise ValidationError(f"{context} must not traverse a symlink: {relative_value}")
    try:
        resolved = candidate.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ValidationError(f"{context} is not an existing file: {relative_value}") from error
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise ValidationError(f"{context} escapes the repository root") from error
    if not resolved.is_file():
        raise ValidationError(f"{context} is not a regular file: {relative_value}")
    return resolved


def require_tool(command: str) -> str:
    resolved = shutil.which(command)
    if resolved is None:
        raise ValidationError(f"required PDF inspection tool is unavailable: {command}")
    return resolved


def run_checked(command: list[str], context: str) -> str:
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=30,
        )
    except subprocess.TimeoutExpired as error:
        raise ValidationError(f"{context} exceeded the 30-second timeout") from error
    except UnicodeDecodeError as error:
        raise ValidationError(f"{context} emitted invalid UTF-8") from error
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise ValidationError(
            f"{context} failed with status {completed.returncode}: {detail}"
        )
    return completed.stdout


def parse_pdfinfo(output: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in output.splitlines():
        key, separator, value = line.partition(":")
        if separator:
            fields[key.strip()] = value.strip()
    return fields


def normalize_pdf_text(value: str) -> str:
    typographic_equivalents = str.maketrans(
        {
            "\u2018": "'",
            "\u2019": "'",
            "\u201c": '"',
            "\u201d": '"',
        }
    )
    return " ".join(value.translate(typographic_equivalents).split())


def validate_pdfinfo_fields(
    fields: dict[str, str],
    *,
    path: Path,
    expected_author: str,
    expected_title: str,
) -> None:
    if fields.get("Author") != expected_author:
        raise ValidationError(
            f"{path} Author metadata must equal {expected_author!r}, "
            f"found {fields.get('Author')!r}"
        )
    if fields.get("Title") != expected_title:
        raise ValidationError(
            f"{path} Title metadata must equal {expected_title!r}, "
            f"found {fields.get('Title')!r}"
        )
    for field in ("Subject", "Keywords"):
        if not fields.get(field):
            raise ValidationError(f"{path} has an empty {field} metadata field")


def validate_visible_pdf_text(
    text: str,
    *,
    path: Path,
    value: dict[str, Any],
    expected_visible_title: str,
) -> None:
    author = value["authors"][0]
    normalized = normalize_pdf_text(text)
    affiliation = ", ".join(
        (author["institution"], author["city"], author["country"])
    )
    required_once = (
        expected_visible_title,
        author["display_name"],
        f"{author['degree']} {author['academic_role']}",
        affiliation,
    )
    for required in required_once:
        count = normalized.count(required)
        if count != 1:
            raise ValidationError(
                f"{path} must contain visible {required!r} exactly once, found {count}"
            )
    if author["email_status"] == "confirmed_current":
        email_count = normalized.count(author["email"])
        if email_count != 1:
            raise ValidationError(
                f"{path} must contain the confirmed correspondence address exactly once, "
                f"found {email_count}"
            )
    elif EMAIL_SEARCH_PATTERN.search(normalized):
        raise ValidationError(
            f"{path} exposes an email address while correspondence confirmation is pending"
        )


def validate_full_pdf_text(text: str, *, path: Path, value: dict[str, Any]) -> None:
    normalized = normalize_pdf_text(text)
    reject_forbidden_identity_text(normalized, str(path))
    author = value["authors"][0]
    addresses = EMAIL_SEARCH_PATTERN.findall(normalized)
    if author["email_status"] == "pending_confirmation":
        if addresses:
            raise ValidationError(
                f"{path} exposes an email address while correspondence confirmation is pending"
            )
    elif addresses != [author["email"]]:
        raise ValidationError(
            f"{path} must expose only the confirmed correspondence address exactly once"
        )


def validate_pdf(
    path: Path,
    *,
    value: dict[str, Any],
    expected_title: str,
    expected_visible_title: str,
    pdfinfo_command: str,
    pdftotext_command: str,
) -> None:
    author = value["authors"][0]
    pdfinfo_output = run_checked([pdfinfo_command, str(path)], f"pdfinfo for {path}")
    fields = parse_pdfinfo(pdfinfo_output)
    validate_pdfinfo_fields(
        fields,
        path=path,
        expected_author=author["display_name"],
        expected_title=expected_title,
    )

    extracted = run_checked(
        [pdftotext_command, str(path), "-"],
        f"pdftotext for {path}",
    )
    first_page = extracted.split("\f", maxsplit=1)[0]
    validate_visible_pdf_text(
        first_page,
        path=path,
        value=value,
        expected_visible_title=expected_visible_title,
    )
    validate_full_pdf_text(extracted, path=path, value=value)


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="repository root")
    parser.add_argument(
        "--write-generated",
        action="store_true",
        help="atomically regenerate paper/generated/manuscript-metadata.tex",
    )
    parser.add_argument("--main-pdf", action="append", default=[])
    parser.add_argument("--supplement-pdf", action="append", default=[])
    parser.add_argument("--pdfinfo", default="pdfinfo")
    parser.add_argument("--pdftotext", default="pdftotext")
    parser.add_argument(
        "--require-confirmed-email",
        action="store_true",
        help="fail unless the correspondence address is explicitly confirmed current",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_argument_parser().parse_args(argv)
    try:
        root = Path(args.root).resolve(strict=True)
        if not root.is_dir():
            raise ValidationError(f"repository root is not a directory: {root}")
        metadata_path = root / "submission" / "manuscript-metadata.json"
        metadata = load_metadata(metadata_path)
        validate_metadata(
            metadata, require_confirmed_email=args.require_confirmed_email
        )
        generated_tex = render_generated_tex(metadata)
        generated_path = root / "paper" / "generated" / "manuscript-metadata.tex"
        if args.write_generated:
            write_generated_tex(generated_path, generated_tex)
        validate_sources(root, metadata, generated_tex)

        main_paths = [
            resolve_repository_file(root, path, "--main-pdf")
            for path in args.main_pdf
        ]
        supplement_paths = [
            resolve_repository_file(root, path, "--supplement-pdf")
            for path in args.supplement_pdf
        ]
        if main_paths or supplement_paths:
            pdfinfo_command = require_tool(args.pdfinfo)
            pdftotext_command = require_tool(args.pdftotext)
            main_title = metadata["title"]
            supplement_title = f"Supplementary Material for {main_title}"
            for path in main_paths:
                validate_pdf(
                    path,
                    value=metadata,
                    expected_title=main_title,
                    expected_visible_title=main_title,
                    pdfinfo_command=pdfinfo_command,
                    pdftotext_command=pdftotext_command,
                )
            for path in supplement_paths:
                validate_pdf(
                    path,
                    value=metadata,
                    expected_title=supplement_title,
                    expected_visible_title=(
                        f'Supplementary Material for "{main_title}"'
                    ),
                    pdfinfo_command=pdfinfo_command,
                    pdftotext_command=pdftotext_command,
                )
    except (OSError, ValidationError) as error:
        print(f"manuscript metadata validation failed: {error}", file=sys.stderr)
        return 1

    print(
        "manuscript metadata valid: one author, synchronized TeX, "
        f"{len(main_paths) + len(supplement_paths)} PDF artifact(s) checked"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
