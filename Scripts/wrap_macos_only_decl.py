#!/usr/bin/env python3
"""Wrap the declaration that contains a given line in `#if os(macOS)`.

Used by the iOS/SkyBridgeCore unification to sink macOS remote-desktop *hosting* helpers out of
otherwise shared files, without splitting a statement across a conditional-compilation boundary
(Swift rejects `#if` inside an if/else chain or an argument list).

Finds the innermost enclosing `func`/`var`/`init` declaration at or above the line, brace-matches
its body, and wraps the whole declaration. Idempotent: a declaration already directly preceded by
`#if os(macOS)` is left alone.

Usage: wrap_macos_only_decl.py <file> <line> [<line> ...]
"""
import re
import sys

DECL = re.compile(
    r"^(\s*)(?:@[\w:().]+\s+)*"
    r"(?:public |private |internal |fileprivate |nonisolated |static |final |mutating )*"
    r"(func|var|init|subscript)\b"
)
NOTE = "// macOS-exclusive: 远程桌面宿主能力（屏幕捕获 / 视频策略 / 输入注入 / 剪贴板重定向）。"


def enclosing_decl(lines, line_number):
    """Innermost declaration at or above `line_number`.

    The opening brace is located by scanning forward without a fixed window: a declaration with a
    multi-line parameter list can put `{` many lines below its keyword. An earlier fixed 4-line
    window silently skipped such declarations and wrapped the *previous* one instead, which sank
    unrelated shared code into the macOS branch.
    """
    index = line_number - 1
    while index >= 0:
        match = DECL.match(lines[index])
        if match:
            body_start = opening_brace_line(lines, index)
            if body_start is not None and body_start <= line_number - 1:
                return index, match.group(1)
        index -= 1
    raise SystemExit(f"no enclosing declaration for line {line_number}")


def opening_brace_line(lines, decl_index, max_scan=40):
    """Line index of the declaration's opening brace, or None when it is not a braced body."""
    depth = 0
    for index in range(decl_index, min(len(lines), decl_index + max_scan)):
        for character in lines[index]:
            if character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
            elif character == "{" and depth <= 0:
                return index
        if lines[index].rstrip().endswith(";"):
            return None
    return None


def body_end(lines, start):
    depth = 0
    for index in range(start, len(lines)):
        depth += lines[index].count("{") - lines[index].count("}")
        if depth == 0 and "{" in "".join(lines[start:index + 1]):
            return index
    raise SystemExit(f"unbalanced braces from line {start + 1}")


def main() -> None:
    path = sys.argv[1]
    requested = sorted({int(argument) for argument in sys.argv[2:]}, reverse=True)
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")

    wrapped = 0
    for line_number in requested:
        start, indent = enclosing_decl(lines, line_number)
        # Skip attribute lines directly above the declaration so they stay inside the guard.
        head = start
        while head - 1 >= 0 and (
            lines[head - 1].strip().startswith("@")
            or lines[head - 1].strip().startswith("///")
        ):
            head -= 1
        if head - 1 >= 0 and lines[head - 1].strip() == "#if os(macOS)":
            continue
        end = body_end(lines, opening_brace_line(lines, start) or start)
        lines[head:head] = [f"{indent}#if os(macOS)", f"{indent}{NOTE}"]
        lines.insert(end + 3, f"{indent}#endif")
        wrapped += 1
        print(f"  wrapped {lines[head + 2].strip()[:80]}")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))
    print(f"{path}: wrapped {wrapped} declaration(s)")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        raise SystemExit(2)
    main()
