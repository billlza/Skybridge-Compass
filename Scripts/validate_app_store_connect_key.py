#!/usr/bin/env python3
"""Validate an externally supplied App Store Connect API key reference."""

from __future__ import annotations

import argparse
import os
import re
import stat
import subprocess
from pathlib import Path


KEY_ID_PATTERN = re.compile(r"[A-Z0-9]{10}")
ISSUER_PATTERN = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)


def fail(message: str) -> "None":
    raise SystemExit(f"[app-store-connect-key] ERROR: {message}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-path", required=True, type=Path)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    arguments = parser.parse_args()

    if KEY_ID_PATTERN.fullmatch(arguments.key_id) is None:
        fail("API key identifier must be 10 uppercase alphanumeric characters")
    if ISSUER_PATTERN.fullmatch(arguments.issuer_id) is None:
        fail("API issuer identifier must be a UUID")
    if not arguments.key_path.is_absolute():
        fail("API key path must be absolute")
    try:
        metadata = arguments.key_path.lstat()
    except OSError:
        fail("API key file is unavailable")
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
    ):
        fail("API key must be a single-link regular file")
    if metadata.st_uid != os.getuid():
        fail("API key must be owned by the current user")
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        fail("API key must not be accessible by group or other users")
    if metadata.st_size < 100 or metadata.st_size > 64 * 1024:
        fail("API key size is outside the accepted bound")
    if arguments.key_path.name != f"AuthKey_{arguments.key_id}.p8":
        fail("API key filename does not match its key identifier")
    try:
        key_bytes = arguments.key_path.read_bytes()
    except OSError:
        fail("API key cannot be read")
    if not (
        key_bytes.startswith(b"-----BEGIN PRIVATE KEY-----\n")
        and key_bytes.rstrip().endswith(b"-----END PRIVATE KEY-----")
    ):
        fail("API key must be an unencrypted PKCS#8 private key")
    result = subprocess.run(
        [
            "/usr/bin/openssl",
            "pkey",
            "-in",
            str(arguments.key_path),
            "-text_pub",
            "-noout",
        ],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=False,
    )
    if (
        result.returncode != 0
        or b"Public-Key: (256 bit)" not in result.stdout
        or b"Field Type: prime-field" not in result.stdout
    ):
        fail("API key is not a readable EC private key")
    print("app_store_connect_key=valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
