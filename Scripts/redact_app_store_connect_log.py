#!/usr/bin/env python3
"""Remove App Store Connect credential identifiers from a retained tool log."""

from __future__ import annotations

import argparse
import os
import re
import stat
import tempfile
from pathlib import Path


MAX_LOG_BYTES = 64 * 1024 * 1024


def fail(message: str) -> "None":
    raise SystemExit(f"[app-store-log-redaction] ERROR: {message}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--secret-reference", action="append", required=True)
    arguments = parser.parse_args()
    if not arguments.input.is_absolute() or not arguments.output.is_absolute():
        fail("log paths must be absolute")
    try:
        metadata = arguments.input.lstat()
    except OSError:
        fail("input log is unavailable")
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size > MAX_LOG_BYTES
    ):
        fail("input log is not an accepted regular file")
    if os.path.lexists(arguments.output):
        fail("output log already exists")
    if any(not reference for reference in arguments.secret_reference):
        fail("secret references must be non-empty")
    try:
        text = arguments.input.read_text(encoding="utf-8", errors="replace")
    except OSError:
        fail("unable to read input log")
    if "-----BEGIN PRIVATE KEY-----" in text or "-----BEGIN EC PRIVATE KEY-----" in text:
        fail("tool log unexpectedly contains private-key material")
    if re.search(
        r"(?i)\bBearer\s+[A-Za-z0-9._~-]{20,}|"
        r"\b[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\b",
        text,
    ):
        fail("tool log unexpectedly contains authentication-token material")
    for reference in arguments.secret_reference:
        text = text.replace(reference, "<redacted-credential-reference>")
    parent = arguments.output.parent
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{arguments.output.name}.", dir=parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", closefd=True) as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, arguments.output)
    finally:
        if temporary.exists():
            temporary.unlink()
    print("app_store_connect_log=redacted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
