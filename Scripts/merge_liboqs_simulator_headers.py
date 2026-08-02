#!/usr/bin/env python3
"""Create one architecture-correct header tree for a universal iOS simulator slice."""

from __future__ import annotations

import argparse
import pathlib
import shutil
import sys


class HeaderMergeError(RuntimeError):
    pass


ARCHITECTURE_LINE_PREFIXES = (
    '#define OQS_COMPILE_BUILD_TARGET "',
    "#define OQS_DIST_X86_64_BUILD 1",
    "/* #undef OQS_DIST_X86_64_BUILD */",
    "#define OQS_DIST_ARM64_V8_BUILD 1",
    "/* #undef OQS_DIST_ARM64_V8_BUILD */",
    "#define ARCH_X86_64 1",
    "/* #undef ARCH_X86_64 */",
    "#define ARCH_ARM64v8 1",
    "/* #undef ARCH_ARM64v8 */",
)


def relative_files(root: pathlib.Path) -> dict[str, pathlib.Path]:
    if not root.is_dir() or root.is_symlink():
        raise HeaderMergeError(f"header root must be a real directory: {root}")
    result: dict[str, pathlib.Path] = {}
    for path in root.rglob("*"):
        if path.is_symlink():
            raise HeaderMergeError(f"header trees must not contain symlinks: {path}")
        if path.is_file():
            result[path.relative_to(root).as_posix()] = path
    return result


def is_architecture_line(line: str) -> bool:
    return line.startswith(ARCHITECTURE_LINE_PREFIXES)


def validate_architecture_lines(arm64_lines: list[str], x86_64_lines: list[str]) -> None:
    arm64_architecture_lines = [line for line in arm64_lines if is_architecture_line(line)]
    x86_64_architecture_lines = [line for line in x86_64_lines if is_architecture_line(line)]
    expected_arm64 = {
        "#define OQS_DIST_ARM64_V8_BUILD 1",
        "/* #undef OQS_DIST_X86_64_BUILD */",
        "#define ARCH_ARM64v8 1",
        "/* #undef ARCH_X86_64 */",
    }
    expected_x86_64 = {
        "#define OQS_DIST_X86_64_BUILD 1",
        "/* #undef OQS_DIST_ARM64_V8_BUILD */",
        "#define ARCH_X86_64 1",
        "/* #undef ARCH_ARM64v8 */",
    }
    if not any(line.startswith('#define OQS_COMPILE_BUILD_TARGET "arm64-') for line in arm64_architecture_lines):
        raise HeaderMergeError("arm64 oqsconfig.h has an unexpected build target")
    if not any(line.startswith('#define OQS_COMPILE_BUILD_TARGET "x86_64-') for line in x86_64_architecture_lines):
        raise HeaderMergeError("x86_64 oqsconfig.h has an unexpected build target")
    if expected_arm64 != set(arm64_architecture_lines[1:]):
        raise HeaderMergeError("arm64 oqsconfig.h has unexpected architecture macros")
    if expected_x86_64 != set(x86_64_architecture_lines[1:]):
        raise HeaderMergeError("x86_64 oqsconfig.h has unexpected architecture macros")


def merge_config(arm64_config: pathlib.Path, x86_64_config: pathlib.Path) -> str:
    arm64_lines = arm64_config.read_text(encoding="utf-8").splitlines()
    x86_64_lines = x86_64_config.read_text(encoding="utf-8").splitlines()
    if len(arm64_lines) != len(x86_64_lines):
        raise HeaderMergeError("simulator oqsconfig.h files have different line counts")
    validate_architecture_lines(arm64_lines, x86_64_lines)
    merged: list[str] = []
    for arm64_line, x86_64_line in zip(arm64_lines, x86_64_lines, strict=True):
        if arm64_line == x86_64_line:
            merged.append(arm64_line)
            continue
        if not is_architecture_line(arm64_line) or not is_architecture_line(x86_64_line):
            raise HeaderMergeError(
                "simulator oqsconfig.h differs outside architecture macros: "
                f"arm64={arm64_line!r}, x86_64={x86_64_line!r}"
            )
        merged.extend(
            (
                "#if defined(__arm64__)",
                arm64_line,
                "#elif defined(__x86_64__)",
                x86_64_line,
                "#else",
                '#error "liboqs simulator headers require arm64 or x86_64"',
                "#endif",
            )
        )
    return "\n".join(merged) + "\n"


def merge_headers(
    arm64_root: pathlib.Path, x86_64_root: pathlib.Path, output_root: pathlib.Path
) -> None:
    arm64_files = relative_files(arm64_root)
    x86_64_files = relative_files(x86_64_root)
    if set(arm64_files) != set(x86_64_files):
        raise HeaderMergeError("simulator header file sets differ between architectures")
    config_path = "oqs/oqsconfig.h"
    if config_path not in arm64_files:
        raise HeaderMergeError("simulator headers do not contain oqs/oqsconfig.h")
    for relative_path in sorted(arm64_files):
        if relative_path == config_path:
            continue
        if arm64_files[relative_path].read_bytes() != x86_64_files[relative_path].read_bytes():
            raise HeaderMergeError(
                f"simulator header differs outside oqsconfig.h: {relative_path}"
            )
    if output_root.exists() or output_root.is_symlink():
        raise HeaderMergeError(f"output header root already exists: {output_root}")
    shutil.copytree(arm64_root, output_root, copy_function=shutil.copy2)
    merged_config = merge_config(arm64_files[config_path], x86_64_files[config_path])
    (output_root / config_path).write_text(merged_config, encoding="utf-8", newline="\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--arm64", required=True)
    parser.add_argument("--x86-64", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        merge_headers(
            pathlib.Path(args.arm64),
            pathlib.Path(args.x86_64),
            pathlib.Path(args.output),
        )
    except (OSError, UnicodeError, HeaderMergeError) as error:
        print(f"liboqs simulator header merge error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
