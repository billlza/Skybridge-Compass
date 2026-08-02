#!/usr/bin/env python3
"""Cross-platform interop/trust consistency checker for TDSC artifacts.

This checker is intentionally static (source-based) so it can run in CI
without bootstrapping all external toolchains.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Sequence, Tuple


def norm_hex(value: str) -> str:
    return f"0x{int(value, 16):04x}"


def first_existing(*candidates: Path) -> Path:
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


def read_text(path: Path) -> str:
    if not path.exists():
        raise FileNotFoundError(str(path))
    return path.read_text(encoding="utf-8")


def is_regular_source_file(path: Path) -> bool:
    try:
        return not path.is_symlink() and stat.S_ISREG(path.stat().st_mode)
    except OSError:
        return False


def parse_swift_suites(text: str) -> Dict[str, str]:
    pattern = re.compile(
        r"public\s+static\s+let\s+([A-Za-z0-9_]+)\s*=\s*CryptoSuite\(\s*rawValue:\s*\"([^\"]+)\"\s*,\s*wireId:\s*(0x[0-9A-Fa-f]+)\s*\)"
    )
    out: Dict[str, str] = {}
    for var_name, raw_name, wire_hex in pattern.findall(text):
        out[norm_hex(wire_hex)] = f"{var_name}:{raw_name}"
    return dict(sorted(out.items()))


def parse_android_suites(text: str) -> Dict[str, str]:
    pattern = re.compile(
        r"^\s*([A-Z0-9_]+)\((0x[0-9A-Fa-f]+)u,\s*(?:true|false)\)",
        flags=re.MULTILINE,
    )
    out: Dict[str, str] = {}
    for enum_name, wire_hex in pattern.findall(text):
        out[norm_hex(wire_hex)] = enum_name
    return dict(sorted(out.items()))


def parse_ubuntu_suites(text: str) -> Dict[str, str]:
    pattern = re.compile(r"^\s*([A-Za-z0-9_]+)\s*=\s*(0x[0-9A-Fa-f]+),", re.MULTILINE)
    out: Dict[str, str] = {}
    for enum_name, wire_hex in pattern.findall(text):
        out[norm_hex(wire_hex)] = enum_name
    return dict(sorted(out.items()))


def set_diff(reference: Dict[str, str], target: Dict[str, str]) -> Tuple[List[str], List[str]]:
    ref_ids = set(reference)
    target_ids = set(target)
    missing = sorted(ref_ids - target_ids)
    extra = sorted(target_ids - ref_ids)
    return missing, extra


def swift_signature_selection_contract(text: str) -> bool:
    """Recognize both the legacy ML-DSA-65 selector and the current 65/87 policy."""
    legacy_rule = re.search(
        r"hasPQCOrHybrid\s*\?\s*\.mlDSA65\s*:\s*\.ed25519",
        text,
    )
    if legacy_rule:
        return True

    has_pqc_classification = re.search(
        r"let\s+hasPQCOrHybrid\s*=\s*offeredSuites\.contains\s*\{\s*\$0\.isPQCGroup\s*\}",
        text,
    )
    classic_branch = re.search(
        r"guard\s+hasPQCOrHybrid\s+else\s*\{\s*return\s+\.ed25519\s*\}",
        text,
    )
    pqc_branch = re.search(
        r"case\s+\.mlDSA65\s*,\s*\.mlDSA87\s*:\s*return\s+pqcAlgorithm\.wire",
        text,
    )
    explicit_ed25519_branch = re.search(
        r"case\s+\.ed25519\s*:\s*return\s+\.ed25519",
        text,
    )
    return all(
        (
            has_pqc_classification,
            classic_branch,
            pqc_branch,
            explicit_ed25519_branch,
        )
    )


def failed_contract_blockers(
    checks: Dict[str, dict],
    *,
    handled_checks: set[str] | None = None,
) -> List[str]:
    handled = handled_checks or set()
    return [
        f"{name}: {value.get('detail', '')}"
        for name, value in checks.items()
        if name not in handled and not bool(value.get("ok"))
    ]


def build_markdown(report: dict) -> str:
    lines: List[str] = []
    lines.append("# Cross-Platform Interop Consistency Report")
    lines.append("")
    lines.append(f"- Generated at: {report['generated_at_utc']}")
    lines.append(f"- Artifact date: {report['artifact_date']}")
    lines.append("")
    lines.append("## Suite Coverage")
    lines.append("")
    lines.append("| Platform | Suite IDs |")
    lines.append("|---|---|")
    lines.append(
        f"| iOS/mac | {', '.join(sorted(report['suite_ids']['ios_mac'].keys())) or '(none)'} |"
    )
    lines.append(
        f"| Android | {', '.join(sorted(report['suite_ids']['android'].keys())) or '(none)'} |"
    )
    lines.append(
        f"| Ubuntu | {', '.join(sorted(report['suite_ids']['ubuntu'].keys())) or '(none)'} |"
    )
    lines.append("")
    lines.append("## Checks")
    lines.append("")
    for check_name, check_value in report["checks"].items():
        status = "PASS" if check_value.get("ok") else "FAIL"
        lines.append(f"- `{check_name}`: {status} - {check_value.get('detail', '')}")
    lines.append("")
    if report["blockers"]:
        lines.append("## Blockers")
        lines.append("")
        for blocker in report["blockers"]:
            lines.append(f"- {blocker}")
        lines.append("")
    if report["warnings"]:
        lines.append("## Warnings")
        lines.append("")
        for warning in report["warnings"]:
            lines.append(f"- {warning}")
        lines.append("")
    lines.append(f"Overall status: **{report['status'].upper()}**")
    return "\n".join(lines) + "\n"


def write_report(report: dict, out_json: Path, out_md: Path) -> None:
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    out_md.write_text(build_markdown(report), encoding="utf-8")


def build_bonjour_markdown(report: dict) -> str:
    lines: List[str] = []
    lines.append("# Bonjour Interop Contract Report")
    lines.append("")
    lines.append(f"- Generated at: {report['generated_at_utc']}")
    lines.append(f"- Artifact date: {report['artifact_date']}")
    lines.append("")
    lines.append("## Checks")
    lines.append("")
    for check_name, check_value in report["checks"].items():
        status = "PASS" if check_value.get("ok") else "FAIL"
        lines.append(f"- `{check_name}`: {status} - {check_value.get('detail', '')}")
    lines.append("")
    if report["blockers"]:
        lines.append("## Blockers")
        lines.append("")
        for blocker in report["blockers"]:
            lines.append(f"- {blocker}")
        lines.append("")
    lines.append(f"Overall status: **{report['status'].upper()}**")
    return "\n".join(lines) + "\n"


def write_bonjour_report(report: dict, out_json: Path, out_md: Path) -> None:
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    out_md.write_text(build_bonjour_markdown(report), encoding="utf-8")


def require_dict(value: Any, name: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be a JSON object")
    return value


def require_string_list(value: Any, name: str) -> List[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"{name} must be a JSON string array")
    return value


def add_check(checks: Dict[str, dict], name: str, ok: bool, detail: str) -> None:
    checks[name] = {"ok": ok, "detail": detail}


def parse_csharp_string_array(text: str, field_name: str) -> List[str]:
    pattern = re.compile(
        rf"{re.escape(field_name)}\s*=\s*\{{(?P<body>.*?)\}}",
        flags=re.S,
    )
    match = pattern.search(text)
    if not match:
        return []
    return re.findall(r'"([^"]+)"', match.group("body"))


@dataclass(frozen=True)
class RustToken:
    kind: str
    value: str
    offset: int


def _decode_rust_string(raw: str, offset: int) -> str:
    decoded: List[str] = []
    cursor = 0
    simple_escapes = {
        "0": "\0",
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "\\": "\\",
        '"': '"',
        "'": "'",
    }
    while cursor < len(raw):
        if raw[cursor] != "\\":
            decoded.append(raw[cursor])
            cursor += 1
            continue
        if cursor + 1 >= len(raw):
            raise ValueError(f"truncated Rust string escape at byte {offset + cursor}")
        escape = raw[cursor + 1]
        if escape in simple_escapes:
            decoded.append(simple_escapes[escape])
            cursor += 2
            continue
        if escape == "x" and cursor + 3 < len(raw):
            digits = raw[cursor + 2 : cursor + 4]
            if re.fullmatch(r"[0-9A-Fa-f]{2}", digits):
                decoded.append(chr(int(digits, 16)))
                cursor += 4
                continue
        if escape == "u" and cursor + 2 < len(raw) and raw[cursor + 2] == "{":
            closing = raw.find("}", cursor + 3)
            digits = raw[cursor + 3 : closing] if closing >= 0 else ""
            if closing >= 0 and re.fullmatch(r"[0-9A-Fa-f]{1,6}", digits):
                scalar = int(digits, 16)
                if scalar <= 0x10FFFF:
                    decoded.append(chr(scalar))
                    cursor = closing + 1
                    continue
        if escape == "\n":
            cursor += 2
            while cursor < len(raw) and raw[cursor] in " \t\r\n":
                cursor += 1
            continue
        raise ValueError(f"unsupported Rust string escape at byte {offset + cursor}")
    return "".join(decoded)


def lex_rust(text: str) -> List[RustToken]:
    """Tokenize the constrained Rust source used by the Bonjour contract checker.

    Comments are removed, while literal strings remain typed tokens. Unclosed
    comments or literals fail closed instead of turning dead text into evidence.
    """
    tokens: List[RustToken] = []
    index = 0
    length = len(text)
    paired_punctuation = {"::", "=>", "==", "!=", "<=", ">=", "&&", "||", "->"}

    while index < length:
        character = text[index]
        if character.isspace():
            index += 1
            continue
        if text.startswith("//", index):
            newline = text.find("\n", index + 2)
            index = length if newline < 0 else newline + 1
            continue
        if text.startswith("/*", index):
            depth = 1
            cursor = index + 2
            while cursor < length and depth:
                if text.startswith("/*", cursor):
                    depth += 1
                    cursor += 2
                elif text.startswith("*/", cursor):
                    depth -= 1
                    cursor += 2
                else:
                    cursor += 1
            if depth:
                raise ValueError(f"unclosed Rust block comment at byte {index}")
            index = cursor
            continue

        raw_prefix_length = 0
        raw_marker_index = index
        if text.startswith("br", index):
            raw_prefix_length = 2
            raw_marker_index = index + 2
        elif character == "r":
            raw_prefix_length = 1
            raw_marker_index = index + 1
        if raw_prefix_length and raw_marker_index < length:
            hash_cursor = raw_marker_index
            while hash_cursor < length and text[hash_cursor] == "#":
                hash_cursor += 1
            if hash_cursor < length and text[hash_cursor] == '"':
                hash_count = hash_cursor - raw_marker_index
                terminator = '"' + ("#" * hash_count)
                content_start = hash_cursor + 1
                content_end = text.find(terminator, content_start)
                if content_end < 0:
                    raise ValueError(f"unclosed Rust raw string at byte {index}")
                tokens.append(RustToken("string", text[content_start:content_end], index))
                index = content_end + len(terminator)
                continue

        string_prefix_length = 1 if text.startswith('b"', index) else 0
        if character == '"' or string_prefix_length:
            quote_index = index + string_prefix_length
            cursor = quote_index + 1
            escaped = False
            while cursor < length:
                current = text[cursor]
                if escaped:
                    escaped = False
                elif current == "\\":
                    escaped = True
                elif current == '"':
                    break
                cursor += 1
            if cursor >= length:
                raise ValueError(f"unclosed Rust string at byte {index}")
            raw = text[quote_index + 1 : cursor]
            tokens.append(RustToken("string", _decode_rust_string(raw, index), index))
            index = cursor + 1
            continue

        if character == "'":
            if index + 1 < length and (text[index + 1].isalpha() or text[index + 1] == "_"):
                lifetime_end = index + 2
                while lifetime_end < length and (
                    text[lifetime_end].isalnum() or text[lifetime_end] == "_"
                ):
                    lifetime_end += 1
                if lifetime_end >= length or text[lifetime_end] != "'":
                    tokens.append(RustToken("punctuation", character, index))
                    index += 1
                    continue
            cursor = index + 1
            escaped = False
            while cursor < length and text[cursor] != "\n":
                current = text[cursor]
                if escaped:
                    escaped = False
                elif current == "\\":
                    escaped = True
                elif current == "'":
                    tokens.append(RustToken("char", text[index : cursor + 1], index))
                    index = cursor + 1
                    break
                cursor += 1
            else:
                tokens.append(RustToken("punctuation", character, index))
                index += 1
            continue

        if character.isalpha() or character == "_":
            cursor = index + 1
            while cursor < length and (text[cursor].isalnum() or text[cursor] == "_"):
                cursor += 1
            tokens.append(RustToken("identifier", text[index:cursor], index))
            index = cursor
            continue
        if character.isdigit():
            cursor = index + 1
            while cursor < length and (text[cursor].isalnum() or text[cursor] == "_"):
                cursor += 1
            tokens.append(RustToken("number", text[index:cursor], index))
            index = cursor
            continue

        pair = text[index : index + 2]
        if pair in paired_punctuation:
            tokens.append(RustToken("punctuation", pair, index))
            index += 2
        else:
            tokens.append(RustToken("punctuation", character, index))
            index += 1

    return tokens


def _find_matching_token(
    tokens: Sequence[RustToken],
    opening_index: int,
    opening: str,
    closing: str,
) -> int:
    depth = 0
    for index in range(opening_index, len(tokens)):
        value = tokens[index].value
        if value == opening:
            depth += 1
        elif value == closing:
            depth -= 1
            if depth == 0:
                return index
    raise ValueError(f"unclosed Rust delimiter {opening!r} at byte {tokens[opening_index].offset}")


def _without_cfg_test_items(tokens: Sequence[RustToken]) -> List[RustToken]:
    """Remove complete Rust items guarded by the exact `#[cfg(test)]` attribute.

    Test-only duplicate constants and functions are not production evidence and
    must neither satisfy nor invalidate the contract. Malformed attributed items
    fail closed instead of being partially retained.
    """
    attribute = ("#", "[", "cfg", "(", "test", ")", "]")
    filtered: List[RustToken] = []
    values = [token.value for token in tokens]
    cursor = 0
    while cursor < len(tokens):
        if tuple(values[cursor : cursor + len(attribute)]) != attribute:
            filtered.append(tokens[cursor])
            cursor += 1
            continue

        item_start = cursor + len(attribute)
        if item_start >= len(tokens):
            raise ValueError("#[cfg(test)] has no guarded Rust item")
        nesting: List[str] = []
        closing_for = {"(": ")", "[": "]"}
        item_cursor = item_start
        while item_cursor < len(tokens):
            value = tokens[item_cursor].value
            if value in closing_for:
                nesting.append(closing_for[value])
            elif value in closing_for.values():
                if not nesting or nesting.pop() != value:
                    raise ValueError("#[cfg(test)] item has unbalanced delimiters")
            elif not nesting and value == "{":
                cursor = _find_matching_token(tokens, item_cursor, "{", "}") + 1
                break
            elif not nesting and value == ";":
                cursor = item_cursor + 1
                break
            item_cursor += 1
        else:
            raise ValueError("#[cfg(test)] item has no terminator")
    return filtered


def _rust_const_expression(tokens: Sequence[RustToken], constant_name: str) -> List[RustToken]:
    matches: List[List[RustToken]] = []
    for index, token in enumerate(tokens[:-2]):
        if token.value != "const" or tokens[index + 1].value != constant_name:
            continue
        cursor = index + 2
        nesting = {"(": 0, "[": 0, "{": 0}
        while cursor < len(tokens):
            value = tokens[cursor].value
            if value in nesting:
                nesting[value] += 1
            elif value == ")":
                nesting["("] -= 1
            elif value == "]":
                nesting["["] -= 1
            elif value == "}":
                nesting["{"] -= 1
            elif value == "=" and all(depth == 0 for depth in nesting.values()):
                break
            cursor += 1
        if cursor >= len(tokens):
            raise ValueError(f"Rust const {constant_name} has no initializer")
        expression_start = cursor + 1
        cursor = expression_start
        while cursor < len(tokens):
            value = tokens[cursor].value
            if value in nesting:
                nesting[value] += 1
            elif value == ")":
                nesting["("] -= 1
            elif value == "]":
                nesting["["] -= 1
            elif value == "}":
                nesting["{"] -= 1
            elif value == ";" and all(depth == 0 for depth in nesting.values()):
                matches.append(list(tokens[expression_start:cursor]))
                break
            if any(depth < 0 for depth in nesting.values()):
                raise ValueError(f"Rust const {constant_name} has unbalanced delimiters")
            cursor += 1
        else:
            raise ValueError(f"Rust const {constant_name} has no terminating semicolon")
    if len(matches) != 1:
        raise ValueError(f"Rust const {constant_name} must have one definition, found {len(matches)}")
    return matches[0]


def _split_top_level_tokens(
    tokens: Sequence[RustToken], delimiter: str = ","
) -> List[List[RustToken]]:
    parts: List[List[RustToken]] = []
    start = 0
    stack: List[str] = []
    closing_for = {"(": ")", "[": "]", "{": "}"}
    for index, token in enumerate(tokens):
        value = token.value
        if value in closing_for:
            stack.append(closing_for[value])
        elif value in closing_for.values():
            if not stack or stack.pop() != value:
                raise ValueError("unbalanced Rust expression")
        elif value == delimiter and not stack:
            if index > start:
                parts.append(list(tokens[start:index]))
            start = index + 1
    if stack:
        raise ValueError("unbalanced Rust expression")
    if start < len(tokens):
        parts.append(list(tokens[start:]))
    return parts


def _identifier_path(tokens: Sequence[RustToken]) -> str:
    if not tokens or tokens[0].kind != "identifier":
        raise ValueError("Rust array item is not an identifier path")
    values = [tokens[0].value]
    cursor = 1
    while cursor < len(tokens):
        if cursor + 1 >= len(tokens) or tokens[cursor].value != "::":
            raise ValueError("Rust array item contains a non-path expression")
        if tokens[cursor + 1].kind != "identifier":
            raise ValueError("Rust path has a non-identifier segment")
        values.append(tokens[cursor + 1].value)
        cursor += 2
    return "::".join(values)


def parse_rust_string_constants(text: str) -> Dict[str, str]:
    tokens = _without_cfg_test_items(lex_rust(text))
    names = {
        tokens[index + 1].value
        for index, token in enumerate(tokens[:-1])
        if token.value == "const"
        and tokens[index + 1].kind == "identifier"
        and tokens[index + 1].value.isupper()
    }
    values: Dict[str, str] = {}
    for name in sorted(names):
        expression = _rust_const_expression(tokens, name)
        if len(expression) == 1 and expression[0].kind == "string":
            values[name] = expression[0].value
    return values


def parse_rust_identifier_array(text: str, constant_name: str) -> List[str]:
    expression = _rust_const_expression(
        _without_cfg_test_items(lex_rust(text)),
        constant_name,
    )
    if len(expression) < 2 or expression[0].value != "[" or expression[-1].value != "]":
        raise ValueError(f"Rust const {constant_name} is not an array expression")
    return [
        _identifier_path(part)
        for part in _split_top_level_tokens(expression[1:-1])
    ]


def _rust_function_body(tokens: Sequence[RustToken], function_name: str) -> List[RustToken]:
    bodies: List[List[RustToken]] = []
    for index, token in enumerate(tokens[:-1]):
        if token.value != "fn" or tokens[index + 1].value != function_name:
            continue
        cursor = index + 2
        while cursor < len(tokens) and tokens[cursor].value not in ("{", ";"):
            cursor += 1
        if cursor >= len(tokens) or tokens[cursor].value == ";":
            continue
        closing = _find_matching_token(tokens, cursor, "{", "}")
        bodies.append(list(tokens[cursor + 1 : closing]))
    if len(bodies) != 1:
        raise ValueError(f"Rust function {function_name} must have one body, found {len(bodies)}")
    return bodies[0]


def _token_sequence_index(
    tokens: Sequence[RustToken], sequence: Sequence[str], start: int = 0
) -> int:
    start = max(0, start)
    if not sequence:
        return start
    values = [token.value for token in tokens]
    limit = len(values) - len(sequence) + 1
    for index in range(start, max(start, limit)):
        if values[index : index + len(sequence)] == list(sequence):
            return index
    return -1


def source_tokens_are_ordered(text: str, snippets: Tuple[str, ...]) -> bool:
    tokens = lex_rust(text)
    cursor = 0
    for snippet in snippets:
        snippet_values = [token.value for token in lex_rust(snippet)]
        found = _token_sequence_index(tokens, snippet_values, cursor)
        if found < 0:
            return False
        cursor = found + len(snippet_values)
    return True


def _rust_integer_constant(tokens: Sequence[RustToken], constant_name: str) -> int:
    expression = _rust_const_expression(tokens, constant_name)
    if len(expression) != 1 or expression[0].kind != "number":
        raise ValueError(f"Rust const {constant_name} is not one integer literal")
    return int(expression[0].value.replace("_", ""), 0)


def _contains_token_sequence(tokens: Sequence[RustToken], sequence: Sequence[str]) -> bool:
    return _token_sequence_index(tokens, sequence) >= 0


def _qualified_references(tokens: Sequence[RustToken], prefix: str) -> List[str]:
    references: List[str] = []
    for index in range(len(tokens) - 2):
        if (
            tokens[index].value == prefix
            and tokens[index + 1].value == "::"
            and tokens[index + 2].kind == "identifier"
        ):
            references.append(f"{prefix}::{tokens[index + 2].value}")
    return references


def _call_arguments(
    tokens: Sequence[RustToken], path: Sequence[str]
) -> List[List[List[RustToken]]]:
    calls: List[List[List[RustToken]]] = []
    cursor = 0
    while cursor < len(tokens):
        found = _token_sequence_index(tokens, path, cursor)
        if found < 0:
            break
        opening = found + len(path)
        if opening >= len(tokens) or tokens[opening].value != "(":
            cursor = found + 1
            continue
        closing = _find_matching_token(tokens, opening, "(", ")")
        calls.append(_split_top_level_tokens(tokens[opening + 1 : closing]))
        cursor = closing + 1
    return calls


def _block_after_sequence(
    tokens: Sequence[RustToken], sequence: Sequence[str]
) -> List[RustToken]:
    condition = _token_sequence_index(tokens, sequence)
    if condition < 0:
        raise ValueError(f"Rust control-flow condition is missing: {' '.join(sequence)}")
    opening = condition + len(sequence)
    while opening < len(tokens) and tokens[opening].value != "{":
        opening += 1
    if opening >= len(tokens):
        raise ValueError("Rust control-flow condition has no block")
    closing = _find_matching_token(tokens, opening, "{", "}")
    return list(tokens[opening + 1 : closing])


def _path_with_optional_to_string(tokens: Sequence[RustToken]) -> str:
    values = [token.value for token in tokens]
    suffix = [".", "to_string", "(", ")"]
    if values[-len(suffix) :] == suffix:
        tokens = tokens[: -len(suffix)]
    return _identifier_path(tokens)


def _hash_map_literal_keys(
    function_body: Sequence[RustToken]
) -> List[str]:
    calls = _call_arguments(function_body, ("HashMap", "::", "from"))
    if len(calls) != 1 or len(calls[0]) != 1:
        raise ValueError("canonical properties must have one HashMap::from argument")
    array = calls[0][0]
    if len(array) < 2 or array[0].value != "[" or array[-1].value != "]":
        raise ValueError("canonical properties HashMap::from argument must be an array")
    keys: List[str] = []
    for entry in _split_top_level_tokens(array[1:-1]):
        if len(entry) < 2 or entry[0].value != "(" or entry[-1].value != ")":
            raise ValueError("canonical properties entry must be a tuple")
        tuple_parts = _split_top_level_tokens(entry[1:-1])
        if len(tuple_parts) != 2:
            raise ValueError("canonical properties tuple must contain key and value")
        keys.append(_path_with_optional_to_string(tuple_parts[0]))
    return keys


def _single_identifier_argument(arguments: Sequence[RustToken]) -> str:
    return _path_with_optional_to_string(arguments)


def _first_tuple_path_or_path(tokens: Sequence[RustToken]) -> str:
    if len(tokens) >= 2 and tokens[0].value == "(" and tokens[-1].value == ")":
        parts = _split_top_level_tokens(tokens[1:-1])
        if not parts:
            raise ValueError("Rust tuple argument is empty")
        return _path_with_optional_to_string(parts[0])
    return _path_with_optional_to_string(tokens)


def _macro_array_items(
    function_body: Sequence[RustToken], macro_name: str
) -> List[List[RustToken]]:
    macro_index = _token_sequence_index(function_body, (macro_name, "!", "["))
    if macro_index < 0:
        raise ValueError(f"Rust macro {macro_name}![] is missing")
    opening = macro_index + 2
    closing = _find_matching_token(function_body, opening, "[", "]")
    if _token_sequence_index(
        function_body, (macro_name, "!", "["), macro_index + 1
    ) >= 0:
        raise ValueError(f"Rust macro {macro_name}![] must have one invocation")
    return _split_top_level_tokens(function_body[opening + 1 : closing])


def _ubuntu_bonjour_checks(
    mdns_text: str,
    types_text: str,
    app_text: str,
    expected_compatibility_services: Sequence[str],
    canonical_txt_fields: Sequence[str],
    legacy_port_keys: Sequence[str],
    expected_device_id_minimum: int,
    expected_device_id_maximum: int,
    expected_fingerprint_pattern: Any,
) -> Dict[str, dict]:
    check_names = (
        "ubuntu_bonjour_service_topology",
        "ubuntu_bonjour_v2_parser_and_advertiser",
        "ubuntu_bonjour_route_identity_and_startup",
    )
    try:
        mdns_tokens = _without_cfg_test_items(lex_rust(mdns_text))
        app_tokens = _without_cfg_test_items(lex_rust(app_text))
        mdns_constants = parse_rust_string_constants(mdns_text)
        type_constants = parse_rust_string_constants(types_text)

        service_symbol_names = {
            "SERVICE_TYPE",
            "QUIC_SERVICE_TYPE",
            "REMOTE_SERVICE_TYPE",
            "TRANSFER_SERVICE_TYPE",
            "LEGACY_REMOTE_SERVICE_TYPE",
            "LEGACY_TRANSFER_SERVICE_TYPE",
        }
        expected_services = [f"{service}.local." for service in expected_compatibility_services]
        actual_services = {
            name: mdns_constants.get(name) for name in sorted(service_symbol_names)
        }
        browse_symbols = parse_rust_identifier_array(mdns_text, "BROWSE_SERVICE_TYPES")
        browse_values = [mdns_constants.get(symbol) for symbol in browse_symbols]
        service_plan_body = _rust_function_body(mdns_tokens, "service_plan")
        expected_writer_symbols = {
            "SERVICE_TYPE",
            "QUIC_SERVICE_TYPE",
            "REMOTE_SERVICE_TYPE",
            "TRANSFER_SERVICE_TYPE",
        }
        initial_service_items = _macro_array_items(service_plan_body, "vec")
        initial_writer_symbols = {
            token.value
            for item in initial_service_items
            for token in item
            if token.kind == "identifier" and token.value in service_symbol_names
        }
        service_pushes = _call_arguments(service_plan_body, ("services", ".", "push"))
        pushed_writer_symbols = [
            _first_tuple_path_or_path(arguments[0])
            for arguments in service_pushes
            if len(arguments) == 1
        ]
        writer_symbols = initial_writer_symbols | set(pushed_writer_symbols)
        all_service_references = {
            token.value
            for token in service_plan_body
            if token.kind == "identifier" and token.value in service_symbol_names
        }
        service_plan_is_active = all(
            (
                initial_writer_symbols == {"SERVICE_TYPE", "QUIC_SERVICE_TYPE"},
                pushed_writer_symbols == ["REMOTE_SERVICE_TYPE", "TRANSFER_SERVICE_TYPE"],
                all_service_references == expected_writer_symbols,
                bool(service_plan_body) and service_plan_body[-1].value == "services",
            )
        )
        start_browse_body = _rust_function_body(mdns_tokens, "start_browse")
        browse_is_consumed = all(
            (
                _contains_token_sequence(
                    start_browse_body,
                    ("for", "service_type", "in", "BROWSE_SERVICE_TYPES"),
                ),
                _contains_token_sequence(
                    start_browse_body,
                    ("self", ".", "daemon", ".", "browse", "(", "service_type", ")"),
                ),
            )
        )
        topology_ok = all(
            (
                list(actual_services.values()).count(None) == 0,
                set(actual_services.values()) == set(expected_services),
                len(browse_values) == len(set(browse_values)) == len(expected_services),
                set(browse_values) == set(expected_services),
                writer_symbols == expected_writer_symbols,
                service_plan_is_active,
                browse_is_consumed,
            )
        )

        expected_base_symbols = [
            "txt_fields::VERSION",
            "txt_fields::DEVICE_ID",
            "txt_fields::PUB_KEY_FP",
            "txt_fields::PLATFORM",
        ]
        expected_control_symbols = expected_base_symbols + [
            "STRONG_OWNER_AUTHENTICATION_TXT_KEY"
        ]
        base_symbols = parse_rust_identifier_array(mdns_text, "CANONICAL_BASE_TXT_KEYS")
        control_symbols = parse_rust_identifier_array(
            mdns_text, "CANONICAL_CONTROL_TXT_KEYS"
        )
        actual_txt_fields = [
            type_constants.get("VERSION"),
            type_constants.get("DEVICE_ID"),
            type_constants.get("PUB_KEY_FP"),
            type_constants.get("PLATFORM"),
            mdns_constants.get("STRONG_OWNER_AUTHENTICATION_TXT_KEY"),
        ]
        canonical_properties_body = _rust_function_body(
            mdns_tokens, "canonical_properties"
        )
        canonical_field_references = set(
            _qualified_references(canonical_properties_body, "txt_fields")
        )
        literal_map_keys = _hash_map_literal_keys(canonical_properties_body)
        insert_calls = _call_arguments(
            canonical_properties_body, ("properties", ".", "insert")
        )
        insert_keys = [
            _path_with_optional_to_string(arguments[0])
            for arguments in insert_calls
            if len(arguments) == 2
        ]
        insert_value_is_string_one = (
            len(insert_calls) == 1
            and len(insert_calls[0]) == 2
            and bool(insert_calls[0][1])
            and insert_calls[0][1][0].kind == "string"
            and insert_calls[0][1][0].value == "1"
            and [token.value for token in insert_calls[0][1][1:]]
            == [".", "to_string", "(", ")"]
        )
        properties_method_calls = [
            canonical_properties_body[index + 2].value
            for index in range(len(canonical_properties_body) - 3)
            if canonical_properties_body[index].value == "properties"
            and canonical_properties_body[index + 1].value == "."
            and canonical_properties_body[index + 2].kind == "identifier"
            and canonical_properties_body[index + 3].value == "("
        ]
        exact_writer_keys_ok = all(
            (
                literal_map_keys == expected_base_symbols,
                insert_keys == ["STRONG_OWNER_AUTHENTICATION_TXT_KEY"],
                insert_value_is_string_one,
                properties_method_calls == ["insert"],
                not _contains_token_sequence(canonical_properties_body, ("properties", "[")),
            )
        )
        build_service_body = _rust_function_body(mdns_tokens, "build_service_info")
        advertise_services_body = _rust_function_body(mdns_tokens, "advertise_services")
        canonical_call_index = _token_sequence_index(
            build_service_body, ("Self", "::", "canonical_properties")
        )
        service_info_call_index = _token_sequence_index(
            build_service_body, ("ServiceInfo", "::", "new")
        )
        address_auto_index = _token_sequence_index(
            build_service_body, ("ServiceInfo", "::", "enable_addr_auto")
        )
        canonical_property_calls = _call_arguments(
            build_service_body, ("Self", "::", "canonical_properties")
        )
        service_info_calls = _call_arguments(
            build_service_body, ("ServiceInfo", "::", "new")
        )
        properties_flow_to_service_info = all(
            (
                len(canonical_property_calls) == 1,
                _contains_token_sequence(
                    build_service_body,
                    ("let", "properties", "=", "Self", "::", "canonical_properties"),
                ),
                len(service_info_calls) == 1,
                bool(service_info_calls) and bool(service_info_calls[0]),
                bool(service_info_calls)
                and [token.value for token in service_info_calls[0][-1]] == ["properties"],
            )
        )
        writer_call_chain_ok = all(
            (
                _contains_token_sequence(
                    advertise_services_body, ("Self", "::", "build_service_info")
                ),
                0 <= canonical_call_index < service_info_call_index < address_auto_index,
                properties_flow_to_service_info,
            )
        )

        classify_body = _rust_function_body(mdns_tokens, "classify_advertisement")
        parse_common_body = _rust_function_body(mdns_tokens, "parse_common")
        parse_v2_body = _rust_function_body(mdns_tokens, "parse_version2")
        device_validator_body = _rust_function_body(mdns_tokens, "is_valid_device_id")
        fingerprint_validator_body = _rust_function_body(
            mdns_tokens, "is_valid_public_key_fingerprint"
        )
        device_validator_values = [token.value for token in device_validator_body]
        fingerprint_validator_values = [
            token.value for token in fingerprint_validator_body
        ]
        device_validator_ok = all(
            (
                not any(value in {";", "{", "}", "true", "false"} for value in device_validator_values),
                _contains_token_sequence(
                    device_validator_body,
                    ("value", "==", "value", ".", "trim", "(", ")"),
                ),
                _contains_token_sequence(
                    device_validator_body,
                    (
                        "BONJOUR_MINIMUM_DEVICE_ID_BYTES",
                        ".",
                        ".",
                        "=",
                        "BONJOUR_MAXIMUM_DEVICE_ID_BYTES",
                    ),
                ),
                _contains_token_sequence(
                    device_validator_body,
                    ("contains", "(", "&", "value", ".", "len", "(", ")", ")"),
                ),
                _contains_token_sequence(
                    device_validator_body,
                    ("value", ".", "bytes", "(", ")", ".", "all", "("),
                ),
                _contains_token_sequence(
                    device_validator_body,
                    ("byte", ".", "is_ascii_alphanumeric", "(", ")"),
                ),
                _contains_token_sequence(device_validator_body, ("matches", "!", "(")),
            )
        )
        fingerprint_validator_ok = all(
            (
                expected_fingerprint_pattern == "^[0-9a-f]{64}$",
                not any(
                    value in {";", "{", "}", "true", "false"}
                    for value in fingerprint_validator_values
                ),
                _contains_token_sequence(
                    fingerprint_validator_body,
                    ("value", ".", "len", "(", ")", "==", "64"),
                ),
                _contains_token_sequence(
                    fingerprint_validator_body,
                    ("value", ".", "bytes", "(", ")", ".", "all", "("),
                ),
                _contains_token_sequence(
                    fingerprint_validator_body,
                    ("byte", ".", "is_ascii_digit", "(", ")"),
                ),
                _contains_token_sequence(
                    fingerprint_validator_body,
                    ("b", "'a'", ".", ".", "=", "b", "'f'"),
                ),
                _contains_token_sequence(
                    fingerprint_validator_body,
                    ("contains", "(", "&", "byte", ")"),
                ),
            )
        )
        key_mismatch_block = _block_after_sequence(
            parse_v2_body, ("if", "actual_keys", "!=", "expected_keys")
        )
        wire_size_block = _block_after_sequence(
            parse_v2_body,
            ("if", "actual_wire_size", ">", "BONJOUR_MAXIMUM_TXT_WIRE_BYTES"),
        )
        strong_owner_block = _block_after_sequence(
            parse_v2_body,
            ("if", "service_kind", "==", "ServiceKind", "::", "Control"),
        )
        exact_failure_branches_ok = all(
            (
                _contains_token_sequence(
                    key_mismatch_block,
                    (
                        "return",
                        "Err",
                        "(",
                        "AdvertisementError",
                        "::",
                        "InvalidVersion2FieldSet",
                        ")",
                    ),
                ),
                _contains_token_sequence(
                    wire_size_block,
                    (
                        "return",
                        "Err",
                        "(",
                        "AdvertisementError",
                        "::",
                        "RecordTooLarge",
                    ),
                ),
                _contains_token_sequence(
                    strong_owner_block,
                    (
                        "return",
                        "Err",
                        "(",
                        "AdvertisementError",
                        "::",
                        "InvalidStrongOwnerAuthentication",
                        ")",
                    ),
                ),
            )
        )
        typed_string_one = any(
            len(arguments) == 1
            and len(arguments[0]) == 1
            and arguments[0][0].kind == "string"
            and arguments[0][0].value == "1"
            for arguments in _call_arguments(parse_v2_body, ("Some",))
        )
        validator_results_are_consumed = all(
            (
                _contains_token_sequence(
                    parse_v2_body,
                    (
                        "filter",
                        "(",
                        "|",
                        "value",
                        "|",
                        "is_valid_device_id",
                        "(",
                        "value",
                        ")",
                        ")",
                        ".",
                        "cloned",
                        "(",
                        ")",
                        ".",
                        "ok_or",
                        "(",
                        "AdvertisementError",
                        "::",
                        "InvalidDeviceId",
                        ")",
                        "?",
                    ),
                ),
                _contains_token_sequence(
                    parse_v2_body,
                    (
                        "filter",
                        "(",
                        "|",
                        "value",
                        "|",
                        "is_valid_public_key_fingerprint",
                        "(",
                        "value",
                        ")",
                        ")",
                        ".",
                        "cloned",
                        "(",
                        ")",
                        ".",
                        "ok_or",
                        "(",
                        "AdvertisementError",
                        "::",
                        "InvalidPublicKeyFingerprint",
                        ")",
                        "?",
                    ),
                ),
                _contains_token_sequence(
                    parse_v2_body,
                    (
                        "and_then",
                        "(",
                        "|",
                        "value",
                        "|",
                        "canonical_platform",
                        "(",
                        "value",
                        ")",
                        ")",
                        ".",
                        "ok_or",
                        "(",
                        "AdvertisementError",
                        "::",
                        "InvalidPlatform",
                        ")",
                        "?",
                    ),
                ),
            )
        )
        exact_v2_parser_ok = all(
            (
                _contains_token_sequence(
                    parse_v2_body,
                    ("if", "actual_keys", "!=", "expected_keys"),
                ),
                _contains_token_sequence(parse_v2_body, ("txt_wire_size", "(")),
                _contains_token_sequence(parse_v2_body, ("is_valid_device_id", "(")),
                _contains_token_sequence(
                    parse_v2_body, ("is_valid_public_key_fingerprint", "(")
                ),
                _contains_token_sequence(parse_v2_body, ("canonical_platform", "(")),
                typed_string_one,
                device_validator_ok,
                fingerprint_validator_ok,
                exact_failure_branches_ok,
                validator_results_are_consumed,
                _contains_token_sequence(
                    classify_body,
                    (
                        "version",
                        "=>",
                        "Err",
                        "(",
                        "AdvertisementError",
                        "::",
                        "UnsupportedVersion",
                    ),
                ),
                _contains_token_sequence(
                    parse_common_body, ("classify_advertisement", "(", "properties", ")")
                ),
                _contains_token_sequence(
                    parse_common_body, ("Self", "::", "parse_version2", "(")
                ),
            )
        )
        canonical_platform_ok = _contains_token_sequence(
            mdns_tokens,
            (
                "Platform",
                "::",
                "Linux",
                "|",
                "Platform",
                "::",
                "Ubuntu",
                "=>",
                "Some",
                "(",
                "linux",
                ")",
            ),
        )
        parser_advertiser_ok = all(
            (
                mdns_constants.get("BONJOUR_ADVERTISEMENT_VERSION") == "2",
                _rust_integer_constant(
                    mdns_tokens, "BONJOUR_MAXIMUM_TXT_WIRE_BYTES"
                )
                == 200,
                _rust_integer_constant(mdns_tokens, "BONJOUR_MINIMUM_DEVICE_ID_BYTES")
                == expected_device_id_minimum,
                _rust_integer_constant(mdns_tokens, "BONJOUR_MAXIMUM_DEVICE_ID_BYTES")
                == expected_device_id_maximum,
                actual_txt_fields == list(canonical_txt_fields),
                base_symbols == expected_base_symbols,
                control_symbols == expected_control_symbols,
                canonical_field_references == set(expected_base_symbols),
                exact_writer_keys_ok,
                canonical_platform_ok,
                writer_call_chain_ok,
                exact_v2_parser_ok,
            )
        )

        route_body = _rust_function_body(mdns_tokens, "parse_resolved_service")
        socket_calls = _call_arguments(route_body, ("SocketAddr", "::", "new"))
        expected_port_argument = ["info", ".", "get_port", "(", ")"]
        parse_common_calls = _call_arguments(route_body, ("Self", "::", "parse_common"))
        route_values = [token.value for token in route_body]
        addresses_binding_index = _token_sequence_index(route_body, ("let", "addresses"))
        get_addresses_index = _token_sequence_index(
            route_body, ("info", ".", "get_addresses", "(", ")"), addresses_binding_index
        )
        socket_index = _token_sequence_index(
            route_body, ("SocketAddr", "::", "new"), get_addresses_index
        )
        collect_index = _token_sequence_index(
            route_body, (".", "collect", "(", ")"), socket_index
        )
        route_uses_srv_only = all(
            (
                len(socket_calls) == 1,
                len(socket_calls) == 1 and len(socket_calls[0]) == 2,
                len(socket_calls) == 1
                and [token.value for token in socket_calls[0][1]]
                == expected_port_argument,
                len(parse_common_calls) == 1,
                len(parse_common_calls) == 1 and len(parse_common_calls[0]) == 3,
                len(parse_common_calls) == 1
                and [token.value for token in parse_common_calls[0][0]]
                == ["info", ".", "get_properties", "(", ")"],
                len(parse_common_calls) == 1
                and [token.value for token in parse_common_calls[0][1]] == ["addresses"],
                len(parse_common_calls) == 1
                and [token.value for token in parse_common_calls[0][2]] == ["service_kind"],
                0 <= addresses_binding_index < get_addresses_index < socket_index < collect_index,
                route_values.count("addresses") >= 1,
                _contains_token_sequence(route_body, ("Ok", "(", "device", ")")),
            )
        )
        route_strings = {token.value for token in route_body if token.kind == "string"}
        route_txt_references = set(_qualified_references(route_body, "txt_fields"))

        handle_event_body = _rust_function_body(mdns_tokens, "handle_event")
        conflict_detector_body = _rust_function_body(mdns_tokens, "has_identity_conflict")
        conflict_detector_values = [token.value for token in conflict_detector_body]
        conflict_detector_ok = all(
            (
                "false" not in conflict_detector_values,
                _contains_token_sequence(
                    conflict_detector_body,
                    ("index", ".", "values", "(", ")"),
                ),
                _contains_token_sequence(
                    conflict_detector_body,
                    ("entry", ".", "device_id", "==", "device_id"),
                ),
                _contains_token_sequence(
                    conflict_detector_body,
                    ("entry", ".", "public_key_fingerprint", ".", "as_str", "(", ")"),
                ),
                _contains_token_sequence(
                    conflict_detector_body,
                    ("fingerprint", "|", "!", "fingerprint", ".", "is_empty", "(", ")"),
                ),
                conflict_detector_values[-7:]
                == ["fingerprints", ".", "len", "(", ")", ">", "1"],
            )
        )
        conflict_index = _token_sequence_index(
            handle_event_body, ("if", "has_identity_conflict")
        )
        merge_index = _token_sequence_index(
            handle_event_body, ("Self", "::", "merge_device")
        )
        callback_index = _token_sequence_index(
            handle_event_body, ("callback", "(", "&", "merged_device", ")")
        )
        conflict_slice = (
            handle_event_body[conflict_index:merge_index]
            if 0 <= conflict_index < merge_index
            else []
        )
        conflict_values = [token.value for token in conflict_slice]
        conflict_is_quarantined = all(
            (
                0 <= conflict_index < merge_index < callback_index,
                "remove" in conflict_values,
                "return" in conflict_values,
                _contains_token_sequence(
                    handle_event_body,
                    ("public_key_fingerprint", ":", "device", ".", "public_key_fingerprint"),
                ),
            )
        )
        discovery_never_persists_trust = not any(
            token.kind == "identifier" and token.value in {"TrustStore", "trust_store"}
            for token in mdns_tokens
        )

        build_ui_body = _rust_function_body(app_tokens, "build_ui")
        init_services_body = _rust_function_body(app_tokens, "init_services")
        listener_index = _token_sequence_index(build_ui_body, ("listener_ready_rx",))
        init_services_call_index = _token_sequence_index(
            build_ui_body, ("init_services", "(")
        )
        init_services_calls = _call_arguments(build_ui_body, ("init_services",))
        passes_bound_control_port = (
            len(init_services_calls) == 1
            and any(
                [token.value for token in argument] == ["tcp_control_port"]
                for argument in init_services_calls[0]
            )
        )
        bound_port_is_observed = all(
            (
                _contains_token_sequence(
                    build_ui_body,
                    (
                        "let",
                        "port",
                        "=",
                        "listener",
                        ".",
                        "local_addr",
                        "(",
                        ")",
                        ".",
                        "port",
                        "(",
                        ")",
                    ),
                ),
                _contains_token_sequence(
                    build_ui_body,
                    (
                        "(",
                        "Some",
                        "(",
                        "port",
                        ")",
                        ",",
                        "Some",
                        "(",
                        "listener",
                        ")",
                        ")",
                    ),
                ),
                not _contains_token_sequence(
                    build_ui_body, ("Some", "(", "quic_port", ")")
                ),
            )
        )
        p2p_ready_index = _token_sequence_index(init_services_body, ("p2p_runtime_ready",))
        manager_index = _token_sequence_index(
            init_services_body, ("DeviceDiscoveryManager", "::", "with_config")
        )
        advertise_index = _token_sequence_index(
            init_services_body,
            ("discovery", ".", "start", "(", "control_port", ")"),
        )
        p2p_match_prefix = (
            "let",
            "p2p_runtime_ready",
            "=",
            "match",
            "p2p_manager",
            ".",
            "start",
            "(",
            ")",
        )
        p2p_match_index = _token_sequence_index(init_services_body, p2p_match_prefix)
        p2p_match_opening = p2p_match_index + len(p2p_match_prefix)
        if p2p_match_index < 0 or init_services_body[p2p_match_opening].value != "{":
            raise ValueError("P2P runtime readiness must come from p2p_manager.start() match")
        p2p_match_closing = _find_matching_token(
            init_services_body, p2p_match_opening, "{", "}"
        )
        p2p_match_body = init_services_body[p2p_match_opening + 1 : p2p_match_closing]
        p2p_readiness_is_observed = all(
            (
                p2p_match_index >= 0,
                _contains_token_sequence(
                    p2p_match_body,
                    ("Ok", "(", "(", ")", ")", "=>", "true"),
                ),
                _contains_token_sequence(
                    p2p_match_body,
                    ("Err", "(", "error", ")", "=>", "{"),
                ),
                _contains_token_sequence(p2p_match_body, ("false", "}")),
            )
        )
        listener_before_advertise = all(
            (
                0 <= listener_index < init_services_call_index,
                passes_bound_control_port,
                bound_port_is_observed,
                0 <= p2p_ready_index < manager_index < advertise_index,
                p2p_readiness_is_observed,
                _contains_token_sequence(
                    init_services_body,
                    (
                        "tcp_control_port",
                        ".",
                        "filter",
                        "(",
                        "|",
                        "_",
                        "|",
                        "p2p_runtime_ready",
                        ")",
                    ),
                ),
            )
        )
        route_identity_startup_ok = all(
            (
                route_uses_srv_only,
                not route_strings.intersection(legacy_port_keys),
                not route_txt_references,
                conflict_detector_ok,
                conflict_is_quarantined,
                discovery_never_persists_trust,
                listener_before_advertise,
            )
        )

        return {
            check_names[0]: {
                "ok": topology_ok,
                "detail": (
                    f"expected_services={expected_services}, actual_services={actual_services}, "
                    f"browse={browse_values}, writer_symbols={sorted(writer_symbols)}"
                ),
            },
            check_names[1]: {
                "ok": parser_advertiser_ok,
                "detail": (
                    f"txt_fields={actual_txt_fields}, base={base_symbols}, control={control_symbols}, "
                    f"writer_keys={exact_writer_keys_ok}, platform={canonical_platform_ok}, "
                    f"writer_chain={writer_call_chain_ok}, exact_parser={exact_v2_parser_ok}, "
                    f"field_refs={sorted(canonical_field_references)}"
                ),
            },
            check_names[2]: {
                "ok": route_identity_startup_ok,
                "detail": (
                    f"srv_only={route_uses_srv_only}, conflict_quarantine={conflict_is_quarantined}, "
                    f"no_trust_persistence={discovery_never_persists_trust}, "
                    f"listener_before_advertise={listener_before_advertise}"
                ),
            },
        }
    except (ValueError, TypeError) as exc:
        detail = f"Rust structure extraction failed closed: {exc}"
        return {name: {"ok": False, "detail": detail} for name in check_names}


def run_bonjour_contract_check(
    args: argparse.Namespace,
    repo_root: Path,
    artifact_date: str,
) -> int:
    ios_root = Path(args.ios_root)
    android_root = Path(args.android_root)
    ubuntu_root = Path(args.ubuntu_root)
    windows_root = Path(args.windows_root)
    contract_path = Path(args.contract_json or ios_root / "Docs/bonjour_interop_contract.json")
    out_json = Path(args.out_json or f"Artifacts/bonjour_interop_contract_{artifact_date}.json")
    out_md = Path(args.out_md or f"Artifacts/bonjour_interop_contract_{artifact_date}.md")

    required_inputs = {
        "contract_json": contract_path,
        "apple_protocol_contract": ios_root
        / "Sources/SkyBridgeProtocolCore/Discovery/BonjourInteropProtocolContract.swift",
        "android_bonjour_interop": android_root
        / "device-discovery/src/main/kotlin/com/skybridge/compass/discovery/data/interop/AppleBonjourInterop.kt",
        "android_bonjour_routes": android_root
        / "device-discovery/src/main/kotlin/com/skybridge/compass/discovery/data/interop/AppleBonjourPeerRoutes.kt",
        "android_action_projection": android_root
        / "app/src/main/kotlin/com/skybridge/compass/android/discovery/DiscoveryPeerActionProjection.kt",
        "ubuntu_bonjour_discovery": ubuntu_root
        / "skybridge-core/src/discovery/mdns.rs",
        "ubuntu_discovery_types": ubuntu_root
        / "skybridge-core/src/discovery/types.rs",
        "ubuntu_app_startup": ubuntu_root / "skybridge-app/src/main.rs",
        "windows_discovery_browser": windows_root
        / "windows/Skybridge.WinClient/Services/DiscoveryBrowserClient.cs",
        "windows_product_action_targets": windows_root
        / "windows/Skybridge.WinClient/Services/ProductSessionActionTargetProjection.cs",
        "windows_product_action_gate": windows_root
        / "windows/Skybridge.WinClient/Services/ProductSessionActionGateClient.cs",
        "windows_command_gate": windows_root
        / "windows/Skybridge.WinClient/ViewModels/WorkspaceCommandGateCoordinator.cs",
        "windows_remote_desktop_actions": windows_root
        / "windows/Skybridge.WinClient/ViewModels/RemoteDesktopWorkspaceActions.cs",
        "windows_file_transfer_runtime_proof": windows_root
        / "windows/Skybridge.WinClient/Services/WebRtcFileTransferRuntimeProof.cs",
        "windows_rust_discovery": windows_root / "core/skybridge-core/src/discovery.rs",
        "windows_core_bridge": windows_root
        / "windows/Skybridge.WinClient/Services/CoreBridge.cs",
    }
    missing_inputs = [
        f"{name}: {path}"
        for name, path in required_inputs.items()
        if not is_regular_source_file(path)
    ]
    checks: Dict[str, dict] = {}
    blockers: List[str] = []
    if missing_inputs:
        blockers.extend(["Missing required Bonjour interop source inputs.", *missing_inputs])

    try:
        contract = require_dict(json.loads(read_text(contract_path)), "contract")
        schema_version = contract.get("schemaVersion")
        if schema_version != 2:
            raise ValueError(f"schemaVersion must be 2, got {schema_version!r}")
        service_types = require_dict(contract.get("serviceTypes"), "serviceTypes")
        discovery = require_dict(contract.get("discovery"), "discovery")
        capabilities = require_dict(contract.get("capabilities"), "capabilities")
        txt = require_dict(contract.get("txt"), "txt")
        remote_video = require_dict(contract.get("remoteVideoFormats"), "remoteVideoFormats")
        route_provenance = require_dict(contract.get("routeProvenance"), "routeProvenance")
        device_id_length = require_dict(
            txt.get("deviceIdLength"), "txt.deviceIdLength"
        )
        expected_device_id_minimum = int(device_id_length.get("minimum"))
        expected_device_id_maximum = int(device_id_length.get("maximumProtocol"))
        expected_fingerprint_pattern = txt.get("pubKeyFingerprintPattern")
        expected_apple_services = require_string_list(
            discovery.get("appleDefaultServiceTypes"),
            "discovery.appleDefaultServiceTypes",
        )
        expected_windows_services = require_string_list(
            discovery.get("windowsCompatibilityQueryOrder"),
            "discovery.windowsCompatibilityQueryOrder",
        )
        expected_capability_tokens = (
            require_string_list(capabilities.get("base"), "capabilities.base")
            + require_string_list(capabilities.get("fileTransfer"), "capabilities.fileTransfer")
            + require_string_list(capabilities.get("remoteControl"), "capabilities.remoteControl")
        )
        canonical_txt_tokens = (
            require_string_list(txt.get("canonicalEmittedFields"), "txt.canonicalEmittedFields")
            + require_string_list(
                txt.get("controlAdditionalEmittedFields"),
                "txt.controlAdditionalEmittedFields",
            )
        )
        legacy_txt_tokens = (
            require_string_list(
                txt.get("acceptedLegacyDeviceIdentityKeys"),
                "txt.acceptedLegacyDeviceIdentityKeys",
            )
            + require_string_list(
                txt.get("acceptedLegacyPubKeyFingerprintKeys"),
                "txt.acceptedLegacyPubKeyFingerprintKeys",
            )
            + require_string_list(
                txt.get("acceptedLegacyFileTransferPortKeys"),
                "txt.acceptedLegacyFileTransferPortKeys",
            )
            + require_string_list(
                txt.get("acceptedLegacyRemoteControlPortKeys"),
                "txt.acceptedLegacyRemoteControlPortKeys",
            )
            + require_string_list(
                txt.get("acceptedLegacyRemoteVideoFormatKeys"),
                "txt.acceptedLegacyRemoteVideoFormatKeys",
            )
        )
        expected_remote_video_tokens = require_string_list(
            remote_video.get("allowedTokens"),
            "remoteVideoFormats.allowedTokens",
        )
        if txt.get("advertisementVersion") != "2":
            raise ValueError("txt.advertisementVersion must be '2'")
        if txt.get("maximumWireBytes") != 200:
            raise ValueError("txt.maximumWireBytes must be 200")
        if txt.get("portsSource") != "dns-sd-srv":
            raise ValueError("txt.portsSource must be dns-sd-srv")
    except (json.JSONDecodeError, OSError, ValueError) as exc:
        blockers.append(f"Invalid Bonjour contract JSON: {exc}")
        schema_version = None
        service_types = {}
        discovery = {}
        capabilities = {}
        txt = {}
        remote_video = {}
        route_provenance = {}
        expected_device_id_minimum = -1
        expected_device_id_maximum = -1
        expected_fingerprint_pattern = None
        expected_apple_services = []
        expected_windows_services = []
        expected_capability_tokens = []
        canonical_txt_tokens = []
        legacy_txt_tokens = []
        expected_remote_video_tokens = []

    expected_txt_tokens = canonical_txt_tokens + legacy_txt_tokens + expected_remote_video_tokens
    add_check(
        checks,
        "bonjour_contract_schema_v2",
        schema_version == 2 and not any("Invalid Bonjour contract JSON" in item for item in blockers),
        "version=2 maxWireBytes=200 portsSource=dns-sd-srv",
    )

    def read_source(name: str) -> str:
        path = required_inputs[name]
        if not is_regular_source_file(path):
            return ""
        try:
            return read_text(path)
        except (OSError, UnicodeError) as exc:
            blockers.append(f"Unreadable source input {name}: {path}: {type(exc).__name__}")
            return ""

    apple_text = read_source("apple_protocol_contract")
    android_interop_text = read_source("android_bonjour_interop")
    android_routes_text = read_source("android_bonjour_routes")
    android_action_projection_text = read_source("android_action_projection")
    ubuntu_discovery_text = read_source("ubuntu_bonjour_discovery")
    ubuntu_types_text = read_source("ubuntu_discovery_types")
    ubuntu_app_text = read_source("ubuntu_app_startup")
    windows_browser_text = read_source("windows_discovery_browser")
    windows_product_action_text = read_source("windows_product_action_targets")
    windows_product_action_gate_text = read_source("windows_product_action_gate")
    windows_command_gate_text = read_source("windows_command_gate")
    windows_remote_desktop_actions_text = read_source("windows_remote_desktop_actions")
    windows_file_transfer_text = read_source("windows_file_transfer_runtime_proof")
    windows_discovery_text = read_source("windows_rust_discovery")
    windows_bridge_text = read_source("windows_core_bridge")

    apple_missing = [
        token
        for token in expected_apple_services
        + expected_windows_services
        + expected_capability_tokens
        + expected_txt_tokens
        if token not in apple_text
    ]
    add_check(
        checks,
        "apple_protocol_contract_exports_json_tokens",
        not apple_missing,
        f"missing={apple_missing}",
    )

    android_missing = [
        token
        for token in expected_apple_services + expected_capability_tokens + expected_txt_tokens
        if token not in android_interop_text
    ]
    add_check(
        checks,
        "android_bonjour_contract_tokens",
        not android_missing,
        f"missing={android_missing}",
    )

    android_route_provenance_ok = (
        "resolvedPort > 0" in android_interop_text
        and "return 0" in android_interop_text
        and "resolveTxtPort" not in android_interop_text
        and "capability strings as proof of a dialable route" in android_routes_text
    )
    add_check(
        checks,
        "android_route_provenance_fail_closed",
        android_route_provenance_ok,
        "resolved DNS-SD port is required; TXT port fallback must stay absent",
    )

    android_product_action_authority_ok = all(
        token in android_action_projection_text
        for token in (
            "EstablishedDiscoveryProductSession",
            "DiscoveryProductSessionState.Established",
            "AuthenticatedProductSessionRequired",
            "ProductSessionNotEstablished",
            "ProductSessionExpired",
            "MissingPeerIdentity",
            "PeerDeviceIdMismatch",
            "PeerFingerprintMismatch",
            "MissingAuthenticatedRouteBinding",
            "AuthenticatedRouteBindingExpired",
            "AuthenticatedDiscoveryProductRouteBinding",
            "macRemotePeerIdentityHint",
        )
    ) and all(
        token not in android_action_projection_text
        for token in (
            "enabled = developerSettings.enableRemoteControl",
            "AuthenticatedClassicSessionRequired",
        )
    )
    add_check(
        checks,
        "android_product_action_authority_fail_closed",
        android_product_action_authority_ok,
        "file-transfer and remote-desktop actions must require a matching established product session, not only Bonjour TXT or feature flags",
    )

    legacy_port_keys = (
        require_string_list(
            txt.get("acceptedLegacyFileTransferPortKeys", []),
            "txt.acceptedLegacyFileTransferPortKeys",
        )
        + require_string_list(
            txt.get("acceptedLegacyRemoteControlPortKeys", []),
            "txt.acceptedLegacyRemoteControlPortKeys",
        )
        if txt
        else []
    )
    linux_checks = _ubuntu_bonjour_checks(
        ubuntu_discovery_text,
        ubuntu_types_text,
        ubuntu_app_text,
        expected_windows_services,
        canonical_txt_tokens,
        legacy_port_keys,
        expected_device_id_minimum,
        expected_device_id_maximum,
        expected_fingerprint_pattern,
    )
    checks.update(linux_checks)

    windows_order = parse_csharp_string_array(windows_browser_text, "DefaultQueryOrder")
    add_check(
        checks,
        "windows_discovery_query_order",
        windows_order == expected_windows_services,
        f"expected={expected_windows_services}, actual={windows_order}",
    )

    rust_missing = [
        service
        for service in expected_windows_services
        if service not in windows_discovery_text
    ]
    add_check(
        checks,
        "windows_rust_discovery_service_kinds",
        not rust_missing and "FileTransfer" in windows_discovery_text and "RemoteControl" in windows_discovery_text,
        f"missing_services={rust_missing}",
    )

    bridge_ok = "FileTransfer = 3" in windows_bridge_text and "RemoteControl = 4" in windows_bridge_text
    add_check(
        checks,
        "windows_corebridge_service_kind_names",
        bridge_ok,
        "CoreBridge must name dedicated file-transfer and remote-control service kinds",
    )

    windows_product_action_authority_ok = all(
        token in windows_product_action_text
        for token in (
            "EstablishedProductControlSessionSnapshot",
            "MissingEstablishedProductControlSession",
            "ProductControlSessionExpired",
            "PeerDeviceIdMismatch",
            "PeerFingerprintMismatch",
            "UnsupportedRouteProvenance",
            "MissingAuthenticatedRouteBinding",
            "AuthenticatedRouteBindingExpired",
            "AuthenticatedProductRouteBinding",
            "resolved-dns-sd-endpoint",
        )
    )
    add_check(
        checks,
        "windows_product_action_authority_fail_closed",
        windows_product_action_authority_ok,
        "resolved route must become actionable only through a matching established product-control session with an authenticated route binding",
    )

    windows_product_action_command_gate_ok = all(
        token in windows_product_action_gate_text
        for token in (
            "IProductControlSessionSnapshotClient",
            "UnavailableProductControlSessionSnapshotClient",
            "MissingValidatedDiscoveryCandidate",
            "EvaluateRemoteDesktop",
        )
    ) and all(
        token in windows_command_gate_text
        for token in (
            "BuildRemoteDesktopProductActionGate",
            "EvaluateRemoteDesktop",
            "CanRecommendedRemoteDesktopConnect",
            "CanAdvancedRemoteDesktopConnect",
        )
    ) and all(
        token in windows_remote_desktop_actions_text
        for token in (
            "RequireRemoteDesktopProductAction",
            "EvaluateRemoteDesktop",
            "Remote Desktop product action is blocked",
        )
    )
    add_check(
        checks,
        "windows_product_action_consumed_by_remote_desktop_gate",
        windows_product_action_command_gate_ok,
        "Remote Desktop connect commands must consume product action gate at CanExecute and execution time",
    )

    windows_file_transfer_wire_ok = all(
        token in windows_file_transfer_text
        for token in (
            'WriteHeader(writer, "metadata"',
            'WriteHeader(writer, "metadataAck"',
            'WriteHeader(writer, "chunk"',
            'WriteHeader(writer, "chunkAck"',
            'WriteHeader(writer, "complete"',
            'WriteHeader(writer, "completeAck"',
            '"chunkData"',
            '"chunkSha256"',
            '"receivedBytes"',
            'Guid.NewGuid().ToString("D").ToLowerInvariant()',
            'Guid.TryParseExact(transferId, "D"',
        )
    ) and all(
        token not in windows_file_transfer_text
        for token in (
            'WriteString("type", "manifest"',
            'WriteString("type", "manifestAck"',
            'WriteString("type", "completeAck"',
        )
    )
    add_check(
        checks,
        "windows_file_transfer_uses_cross_network_op_schema",
        windows_file_transfer_wire_ok,
        "Windows SBWC FileTransfer proof must use Apple/Android CrossNetworkFileTransferMessage op schema, UUID transferId, and base64 SHA fields",
    )

    provenance_ok = all(bool(route_provenance.get(key)) for key in (
        "txtPortsAreDiagnosticOnly",
        "actionableRoutesRequireResolvedDnsSdEndpoint",
        "capabilitiesDoNotCreateRoutes",
        "pubKeyFingerprintIsTrustHintOnly",
    ))
    add_check(
        checks,
        "contract_route_provenance",
        provenance_ok,
        "contract must keep DNS-SD TXT as untrusted metadata",
    )

    for name, check in checks.items():
        if not check.get("ok"):
            blockers.append(f"{name}: {check.get('detail', '')}")

    status = "pass" if not blockers else "fail"
    report = {
        "status": status,
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "artifact_date": artifact_date,
        "paths": {
            "ios_root": str(ios_root),
            "android_root": str(android_root),
            "ubuntu_root": str(ubuntu_root),
            "windows_root": str(windows_root),
            "contract_json": str(contract_path),
        },
        "service_types": service_types,
        "checks": checks,
        "blockers": blockers,
    }
    write_bonjour_report(report, out_json, out_md)

    print(f"[interop] bonjour-status={status}")
    print(f"[interop] wrote {out_json}")
    print(f"[interop] wrote {out_md}")
    return 0 if status == "pass" else 1


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-date", default=os.getenv("ARTIFACT_DATE", "2026-01-23"))
    parser.add_argument("--ios-root", default=str(repo_root))
    parser.add_argument(
        "--android-root", default="/Users/bill/Desktop/SkyBridge Compass - Android"
    )
    parser.add_argument("--ubuntu-root", default="/Users/bill/Desktop/SkyBridge Compass Ubuntu")
    parser.add_argument(
        "--windows-root",
        default="/Users/bill/Desktop/SkyBridge Compass-win64/Skybridge-Compass",
    )
    parser.add_argument(
        "--website-root", default="/Users/bill/Desktop/skybridge-sinan-website"
    )
    parser.add_argument("--bonjour-only", action="store_true")
    parser.add_argument("--contract-json")
    parser.add_argument("--out-json")
    parser.add_argument("--out-md")
    args = parser.parse_args()

    artifact_date = args.artifact_date
    if args.bonjour_only:
        return run_bonjour_contract_check(args, repo_root, artifact_date)

    out_json = Path(args.out_json or f"Artifacts/interop_consistency_{artifact_date}.json")
    out_md = Path(args.out_md or f"Artifacts/interop_consistency_{artifact_date}.md")

    ios_root = Path(args.ios_root)
    android_root = Path(args.android_root)
    ubuntu_root = Path(args.ubuntu_root)
    windows_root = Path(args.windows_root)
    website_root = Path(args.website_root)

    ios_suite_file = first_existing(
        ios_root / "Sources/SkyBridgeProtocolCore/P2P/CryptoSuite.swift",
        ios_root / "Sources/SkyBridgeCore/P2P/CryptoProviderProtocol.swift",
        ios_root / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/CryptoProviderProtocol.swift",
    )
    ios_wire_file = first_existing(
        ios_root / "Sources/SkyBridgeCore/P2P/HandshakeMessages.swift",
        ios_root / "Sources/SkyBridgeProtocolCore/P2P/HandshakeMessages.swift",
        ios_root / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakeMessages.swift",
    )
    ios_fallback_file = first_existing(
        ios_root / "Sources/SkyBridgeCore/P2P/TwoAttemptHandshakeManager.swift",
        ios_root / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/TwoAttemptHandshakeManager.swift",
    )
    ios_sig_file = first_existing(
        ios_root / "Sources/SkyBridgeCore/P2P/PreNegotiationSignatureSelector.swift",
    )
    ios_trust_file = first_existing(
        ios_root / "Sources/SkyBridgeCore/P2P/MultiAlgorithmSignatureVerifier.swift",
    )
    ios_app_message_file = ios_root / "Sources/SkyBridgeCore/P2P/AppMessage.swift"
    ios_webrtc_codec_file = (
        ios_root / "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCControlChannelCodec.swift"
    )
    ios_webrtc_policy_file = (
        ios_root / "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCBootstrapAppMessagePolicy.swift"
    )
    ios_app_message_copy_file = (
        ios_root / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Messaging/AppMessage.swift"
    )

    android_suite_file = (
        android_root
        / "shared/src/main/kotlin/com/skybridge/compass/shared/p2p/P2PCryptoSuite.kt"
    )
    android_wire_file = (
        android_root
        / "shared/src/main/kotlin/com/skybridge/compass/shared/p2p/P2PHandshakeWire.kt"
    )
    android_client_file = (
        android_root
        / "shared/src/main/kotlin/com/skybridge/compass/shared/p2p/P2PHandshakeClient.kt"
    )
    android_app_message_file = (
        android_root / "core/src/main/kotlin/com/skybridge/compass/core/p2p/AppMessage.kt"
    )
    android_webrtc_manager_file = (
        android_root
        / "core/src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt"
    )
    android_route_binding_consumer_file = (
        android_root
        / "core/src/main/kotlin/com/skybridge/compass/core/webrtc/AuthenticatedRouteBindingConsumer.kt"
    )
    android_product_session_store_file = (
        android_root
        / "shared/src/main/kotlin/com/skybridge/compass/shared/productsession/ProductSessionAuthorityStore.kt"
    )
    android_action_projection_file = (
        android_root
        / "app/src/main/kotlin/com/skybridge/compass/android/discovery/DiscoveryPeerActionProjection.kt"
    )
    android_app_module_file = android_root / "app/src/main/kotlin/com/skybridge/compass/android/di/AppModule.kt"
    android_transport_factory_file = (
        android_root / "app/src/main/kotlin/com/skybridge/compass/android/webrtc/AppWebRtcTransportFactory.kt"
    )
    android_discovery_screen_file = (
        android_root
        / "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/devicediscovery/DeviceDiscoveryScreen.kt"
    )
    windows_route_binding_codec_file = (
        windows_root
        / "windows/Skybridge.WinClient/Services/WebRtcAuthenticatedRouteBindingPayload.cs"
    )
    windows_route_binding_store_file = (
        windows_root
        / "windows/Skybridge.WinClient/Services/WebRtcAuthenticatedRouteBindingStore.cs"
    )

    ubuntu_suite_file = ubuntu_root / "skybridge-core/src/crypto/suite.rs"
    ubuntu_messages_file = ubuntu_root / "skybridge-core/src/p2p/messages.rs"
    ubuntu_driver_file = ubuntu_root / "skybridge-core/src/p2p/driver.rs"
    ubuntu_trust_file = ubuntu_root / "skybridge-core/src/p2p/trust.rs"

    website_supabase_file = first_existing(
        website_root / "frontend/src/lib/supabase.ts",
        website_root / "src/lib/supabase.ts",
        website_root / "yunqiao-sinan-source-code/src/lib/supabase.ts",
    )

    required_inputs = {
        "ios_suite_file": ios_suite_file,
        "ios_wire_file": ios_wire_file,
        "ios_fallback_file": ios_fallback_file,
        "ios_sig_file": ios_sig_file,
        "ios_trust_file": ios_trust_file,
        "ios_app_message_file": ios_app_message_file,
        "ios_webrtc_codec_file": ios_webrtc_codec_file,
        "ios_webrtc_policy_file": ios_webrtc_policy_file,
        "ios_app_message_copy_file": ios_app_message_copy_file,
        "android_suite_file": android_suite_file,
        "android_wire_file": android_wire_file,
        "android_client_file": android_client_file,
        "android_app_message_file": android_app_message_file,
        "android_webrtc_manager_file": android_webrtc_manager_file,
        "android_route_binding_consumer_file": android_route_binding_consumer_file,
        "android_product_session_store_file": android_product_session_store_file,
        "android_action_projection_file": android_action_projection_file,
        "android_app_module_file": android_app_module_file,
        "android_transport_factory_file": android_transport_factory_file,
        "android_discovery_screen_file": android_discovery_screen_file,
        "windows_route_binding_codec_file": windows_route_binding_codec_file,
        "windows_route_binding_store_file": windows_route_binding_store_file,
        "ubuntu_suite_file": ubuntu_suite_file,
        "ubuntu_messages_file": ubuntu_messages_file,
        "ubuntu_driver_file": ubuntu_driver_file,
        "ubuntu_trust_file": ubuntu_trust_file,
    }
    missing_inputs = [f"{name}: {path}" for name, path in required_inputs.items() if not path.exists()]
    if missing_inputs:
        report = {
            "status": "fail",
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "artifact_date": artifact_date,
            "paths": {
                "ios_root": str(ios_root),
                "android_root": str(android_root),
                "ubuntu_root": str(ubuntu_root),
                "windows_root": str(windows_root),
                "website_root": str(website_root),
            },
            "suite_ids": {
                "ios_mac": {},
                "android": {},
                "ubuntu": {},
            },
            "diffs": {
                "missing_in_android": [],
                "extra_in_android": [],
                "missing_in_ubuntu": [],
                "extra_in_ubuntu": [],
            },
            "checks": {},
            "blockers": [
                "Missing required cross-platform source inputs.",
                *missing_inputs,
            ],
            "warnings": [],
        }
        write_report(report, out_json, out_md)
        print("[interop] status=fail")
        print(f"[interop] wrote {out_json}")
        print(f"[interop] wrote {out_md}")
        return 1

    ios_suite_text = read_text(ios_suite_file)
    ios_wire_text = read_text(ios_wire_file)
    ios_fallback_text = read_text(ios_fallback_file)
    ios_sig_text = read_text(ios_sig_file)
    ios_trust_text = read_text(ios_trust_file)
    ios_app_message_text = read_text(ios_app_message_file)
    ios_webrtc_codec_text = read_text(ios_webrtc_codec_file)
    ios_webrtc_policy_text = read_text(ios_webrtc_policy_file)
    ios_app_message_copy_text = read_text(ios_app_message_copy_file)

    android_suite_text = read_text(android_suite_file)
    android_wire_text = read_text(android_wire_file)
    android_client_text = read_text(android_client_file)
    android_app_message_text = read_text(android_app_message_file)
    android_webrtc_manager_text = read_text(android_webrtc_manager_file)
    android_route_binding_consumer_text = read_text(android_route_binding_consumer_file)
    android_product_session_store_text = read_text(android_product_session_store_file)
    android_action_projection_text = read_text(android_action_projection_file)
    android_app_module_text = read_text(android_app_module_file)
    android_transport_factory_text = read_text(android_transport_factory_file)
    android_discovery_screen_text = read_text(android_discovery_screen_file)
    windows_route_binding_codec_text = read_text(windows_route_binding_codec_file)
    windows_route_binding_store_text = read_text(windows_route_binding_store_file)

    ubuntu_suite_text = read_text(ubuntu_suite_file)
    ubuntu_messages_text = read_text(ubuntu_messages_file)
    ubuntu_driver_text = read_text(ubuntu_driver_file)
    ubuntu_trust_text = read_text(ubuntu_trust_file)

    ios_suites = parse_swift_suites(ios_suite_text)
    android_suites = parse_android_suites(android_suite_text)
    ubuntu_suites = parse_ubuntu_suites(ubuntu_suite_text)

    missing_android, extra_android = set_diff(ios_suites, android_suites)
    missing_ubuntu, extra_ubuntu = set_diff(ios_suites, ubuntu_suites)

    blockers: List[str] = []
    warnings: List[str] = []

    website_supabase_text = ""
    if website_supabase_file.exists():
        website_supabase_text = read_text(website_supabase_file)
    else:
        warnings.append(
            f"Website Supabase source not found at {website_supabase_file}; "
            "backend/account alignment evidence is omitted from this P2P interop report"
        )

    if missing_android:
        blockers.append(f"Android missing iOS/mac suite IDs: {', '.join(missing_android)}")
    if missing_ubuntu:
        blockers.append(f"Ubuntu missing iOS/mac suite IDs: {', '.join(missing_ubuntu)}")

    android_strict_unknown_suite = bool(
        re.search(r"requireNotNull\(P2PCryptoSuite\.fromWireId\(wireId\)\)", android_wire_text)
    )
    if android_strict_unknown_suite:
        blockers.append("Android MessageA parser hard-fails on unknown suite IDs (not forward-compatible)")

    android_has_p2p_trust_store = bool(
        re.search(r"p2p.*trust|TrustStore|peer_signing_fingerprint", android_wire_text, re.IGNORECASE)
    )
    if not android_has_p2p_trust_store:
        blockers.append("Android shared P2P handshake module lacks explicit pinned-peer trust store path")

    android_classic_only_path = bool(
        re.search(r"supportedSuites\s*=\s*listOf\(P2PCryptoSuite\.X25519\)", android_client_text)
    )
    if android_classic_only_path:
        warnings.append("Android initiator currently starts with classic-only practical path (X25519)")

    swift_le = "appendUInt16LE" in ios_wire_text and "readUInt16LE" in ios_wire_text
    android_le = "ByteOrder.LITTLE_ENDIAN" in android_wire_text and "readU16LE" in android_wire_text
    ubuntu_le = (
        "to_le_bytes" in ubuntu_messages_text
        and "from_le_bytes" in ubuntu_messages_text
        and "to_le_bytes" in read_text(ubuntu_root / "skybridge-core/src/p2p/encoding.rs")
    )

    swift_timeout_blocked = bool(
        re.search(r"case\s+\.timeout[^:]*:\s*return\s+false", ios_fallback_text)
    )
    ubuntu_timeout_not_in_fallback = not bool(
        re.search(r"Timeout", re.search(r"let should_fallback = matches!\((.*?)\);", ubuntu_driver_text, re.S).group(1))
    ) if re.search(r"let should_fallback = matches!\((.*?)\);", ubuntu_driver_text, re.S) else False
    if not ubuntu_timeout_not_in_fallback:
        warnings.append("Ubuntu fallback branch could not confirm timeout exclusion")

    swift_cooldown_300 = bool(
        re.search(r"fallbackCooldownSeconds\s*:\s*Int\s*=\s*300", ios_fallback_text)
    )
    ubuntu_has_cooldown = "cooldown" in ubuntu_driver_text.lower()
    android_has_cooldown = "cooldown" in android_wire_text.lower()
    if not ubuntu_has_cooldown:
        warnings.append("Ubuntu handshake driver has no explicit per-peer fallback cooldown actor/path")
    if not android_has_cooldown:
        warnings.append("Android shared handshake module has no explicit fallback cooldown path")

    swift_sig_rule = swift_signature_selection_contract(ios_sig_text)
    ubuntu_sig_rule = bool(
        re.search(r"if\s+has_pqc\s*\{\s*SignatureAlgorithm::MlDsa65\s*\}\s*else\s*\{\s*SignatureAlgorithm::Ed25519\s*\}", ubuntu_driver_text, re.S)
    )
    android_sig_rule = bool(
        re.search(r"when\s*\(algorithm\)\s*\{.*ED25519.*ML_DSA_65", android_wire_text, re.S)
    )

    ubuntu_has_trust_pinning = "verify_peer_fingerprint" in ubuntu_driver_text and "peer_signing_fingerprint" in ubuntu_trust_text
    swift_has_trust_pinning = "identityMismatch" in ios_fallback_text and "allowsLegacyFallback" in ios_trust_text
    website_is_backend_evidence = "shared same Supabase project".lower() in website_supabase_text.lower() or "共享同一 Supabase 项目" in website_supabase_text
    if website_is_backend_evidence:
        warnings.append("Website repository is backend/account alignment evidence, not P2P handshake proof")

    route_binding_schema_tokens = [
        "authenticatedRouteBinding",
        "AuthenticatedRouteBindingPayload",
        "serviceType",
        "instanceName",
        "hostName",
        "endpointProvenance",
        "routeAuthorityProtocolPublicKeyFingerprint",
        "remoteProtocolPublicKeyFingerprint",
        "sessionHashHex",
        "transcriptPrefixHex",
        "expiresAt",
        "nonce",
    ]
    swift_route_binding_schema = all(token in ios_app_message_text for token in route_binding_schema_tokens)
    swift_ios_copy_route_binding_schema = all(token in ios_app_message_copy_text for token in route_binding_schema_tokens)
    swift_route_binding_codec = (
        "authenticatedRouteBinding" in ios_webrtc_codec_text
        and "dropUntilPQCRekey" in ios_webrtc_policy_text
        and "case .clipboard, .textMessage, .authenticatedRouteBinding" in ios_webrtc_policy_text
    )
    android_route_binding_schema = all(token in android_app_message_text for token in route_binding_schema_tokens)
    android_route_binding_consumer = all(
        token in android_route_binding_consumer_text
        for token in (
            "AuthenticatedRouteBindingConsumer",
            "AuthenticatedRouteBindingValidationContext",
            "ProductSessionAuthorityStore",
            "routeAuthorityProtocolPublicKeyFingerprint",
            "remoteProtocolPublicKeyFingerprint",
            "sessionHashHex",
            "transcriptPrefixHex",
            "SwiftDateSeconds.toUnixEpochMillis",
            "route-binding authority fingerprint mismatch",
            "route-binding receiver fingerprint mismatch",
            "route-binding session hash mismatch",
            "route-binding transcript prefix mismatch",
        )
    )
    android_product_session_store = all(
        token in android_product_session_store_text
        for token in (
            "ProductSessionAuthorityStore",
            "InMemoryProductSessionAuthorityStore",
            "StateFlow<List<ProductSessionAuthority>>",
            "upsertEstablishedRouteBinding",
            "clearExpired",
            "maxSessions",
            "maxBindingsPerSession",
            "resolved-dns-sd-endpoint",
        )
    )
    android_route_binding_manager_wired = all(
        token in android_webrtc_manager_text
        for token in (
            "ProductSessionAuthorityStore",
            "AuthenticatedRouteBindingConsumer",
            "handleAuthenticatedRouteBinding",
            "routeBindingConsumer",
            "unsignedLongHex16(openedEnvelope.sessionHash)",
            "unsignedLongHex16(openedEnvelope.transcriptPrefix)",
            "productSessionAuthorityStore?.clearSession",
            "routeBindingAccepted",
        )
    ) and "authenticated route-binding consumer is not wired" not in android_webrtc_manager_text
    android_route_binding_app_composition = all(
        token in android_app_module_text + android_transport_factory_text + android_discovery_screen_text + android_action_projection_text
        for token in (
            "provideProductSessionAuthorityStore",
            "InMemoryProductSessionAuthorityStore",
            "productSessionAuthorityStore",
            "productSessions",
            "productSessionFor",
            "DiscoveryPeerActionProjection.actionsFor(device, devSettings, productSession)",
            "ProductRouteBindingProtocol.ENDPOINT_PROVENANCE_RESOLVED_DNS_SD",
        )
    )
    windows_route_binding_codec = all(
        token in windows_route_binding_codec_text
        for token in (
            "WebRtcAuthenticatedRouteBindingPayload",
            "authenticatedRouteBinding",
            "resolved-dns-sd-endpoint",
            "routeAuthorityProtocolPublicKeyFingerprint",
            "remoteProtocolPublicKeyFingerprint",
            "sessionHashHex",
            "transcriptPrefixHex",
            "Nonce",
        )
    )
    windows_route_binding_store = all(
        token in windows_route_binding_store_text
        for token in (
            "IProductControlSessionSnapshotClient",
            "IWebRtcProductControlRuntimeConsumer",
            "WebRtcProductControlSecureSessionState.Established",
            "RouteAuthorityProtocolPublicKeyFingerprint",
            "SessionHashHex",
            "TranscriptPrefixHex",
            "FailClosedLocked",
        )
    )

    checks = {
        "wire_little_endian_alignment": {
            "ok": bool(swift_le and android_le and ubuntu_le),
            "detail": f"swift={swift_le}, android={android_le}, ubuntu={ubuntu_le}",
        },
        "signature_selection_contract": {
            "ok": bool(swift_sig_rule and ubuntu_sig_rule and android_sig_rule),
            "detail": f"swift={swift_sig_rule}, android={android_sig_rule}, ubuntu={ubuntu_sig_rule}",
        },
        "timeout_fallback_blocked": {
            "ok": bool(swift_timeout_blocked and ubuntu_timeout_not_in_fallback),
            "detail": f"swift={swift_timeout_blocked}, ubuntu={ubuntu_timeout_not_in_fallback}, android=not_implemented_in_shared_core",
        },
        "cooldown_guard": {
            "ok": bool(swift_cooldown_300 and ubuntu_has_cooldown and android_has_cooldown),
            "detail": f"swift={swift_cooldown_300}, android={android_has_cooldown}, ubuntu={ubuntu_has_cooldown}",
        },
        "trust_pinning_path": {
            "ok": bool(swift_has_trust_pinning and ubuntu_has_trust_pinning and android_has_p2p_trust_store),
            "detail": f"swift={swift_has_trust_pinning}, android={android_has_p2p_trust_store}, ubuntu={ubuntu_has_trust_pinning}",
        },
        "suite_catalog_parity": {
            "ok": not missing_android and not missing_ubuntu and not extra_android and not extra_ubuntu,
            "detail": (
                f"missing_android={missing_android}, missing_ubuntu={missing_ubuntu}, "
                f"extra_android={extra_android}, extra_ubuntu={extra_ubuntu}"
            ),
        },
        "authenticated_route_binding_appcontrol_schema": {
            "ok": bool(
                swift_route_binding_schema
                and swift_ios_copy_route_binding_schema
                and swift_route_binding_codec
                and android_route_binding_schema
                and android_route_binding_consumer
                and android_product_session_store
                and android_route_binding_manager_wired
                and android_route_binding_app_composition
                and windows_route_binding_codec
                and windows_route_binding_store
            ),
            "detail": (
                f"swift_core={swift_route_binding_schema}, swift_ios={swift_ios_copy_route_binding_schema}, "
                f"swift_codec_policy={swift_route_binding_codec}, android_schema={android_route_binding_schema}, "
                f"android_consumer={android_route_binding_consumer}, "
                f"android_store={android_product_session_store}, "
                f"android_manager_wired={android_route_binding_manager_wired}, "
                f"android_app_composition={android_route_binding_app_composition}, "
                f"windows_codec={windows_route_binding_codec}, windows_consumer_store={windows_route_binding_store}"
            ),
        },
    }

    route_binding_check = checks["authenticated_route_binding_appcontrol_schema"]
    if not route_binding_check["ok"]:
        blockers.append(
            "authenticated_route_binding_appcontrol_schema: "
            + route_binding_check["detail"]
        )

    blockers.extend(
        failed_contract_blockers(
            checks,
            handled_checks={
                "suite_catalog_parity",
                "authenticated_route_binding_appcontrol_schema",
            },
        )
    )

    status = "pass" if not blockers else "fail"
    report = {
        "status": status,
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "artifact_date": artifact_date,
        "paths": {
            "ios_root": str(ios_root),
            "android_root": str(android_root),
            "ubuntu_root": str(ubuntu_root),
            "windows_root": str(windows_root),
            "website_root": str(website_root),
        },
        "suite_ids": {
            "ios_mac": ios_suites,
            "android": android_suites,
            "ubuntu": ubuntu_suites,
        },
        "diffs": {
            "missing_in_android": missing_android,
            "extra_in_android": extra_android,
            "missing_in_ubuntu": missing_ubuntu,
            "extra_in_ubuntu": extra_ubuntu,
        },
        "checks": checks,
        "blockers": blockers,
        "warnings": warnings,
    }

    write_report(report, out_json, out_md)

    print(f"[interop] status={status}")
    print(f"[interop] wrote {out_json}")
    print(f"[interop] wrote {out_md}")
    return 0 if status == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
