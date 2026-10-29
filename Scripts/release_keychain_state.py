#!/usr/bin/env python3
"""Validate and restore the exact user keychain state captured before signing."""
from __future__ import annotations
import argparse
from pathlib import Path
import shlex
import subprocess


def parse_paths(text: str, *, single: bool) -> list[str]:
    paths = shlex.split(text, posix=True)
    if single and len(paths) != 1:
        raise ValueError("default keychain snapshot must contain exactly one path")
    for path in paths:
        if not Path(path).is_absolute() or any(ord(c) < 32 for c in path):
            raise ValueError("keychain snapshot contains a non-absolute or control-character path")
    return paths


def restore(keychains: list[str], default: str) -> None:
    failed = []
    for label, argv in (
        ("user search list", ["security", "list-keychains", "-d", "user", "-s", *keychains]),
        ("default keychain", ["security", "default-keychain", "-d", "user", "-s", default]),
    ):
        try:
            result = subprocess.run(argv, capture_output=True, text=True, check=False, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as error:
            failed.append(f"{label}: {error}")
            continue
        if result.returncode != 0:
            failed.append(f"{label}: {result.stderr.strip()}")
    if failed:
        raise RuntimeError("keychain restoration failed: " + "; ".join(failed))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list-snapshot", required=True, type=Path)
    parser.add_argument("--default-snapshot", required=True, type=Path)
    parser.add_argument("--restore", action="store_true")
    args = parser.parse_args()
    keychains = parse_paths(args.list_snapshot.read_text(), single=False)
    default = parse_paths(args.default_snapshot.read_text(), single=True)[0]
    if args.restore:
        restore(keychains, default)


if __name__ == "__main__":
    main()
