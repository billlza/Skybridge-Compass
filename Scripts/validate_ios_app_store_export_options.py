#!/usr/bin/env python3
"""Validate the fail-closed App Store export-options contract."""

from __future__ import annotations

import argparse
import plistlib
import stat
from pathlib import Path


EXPECTED_OPTIONS = {
    "destination": "export",
    "manageAppVersionAndBuildNumber": False,
    "method": "app-store-connect",
    "signingStyle": "automatic",
    "stripSwiftSymbols": True,
    "teamID": "YKUPL7Z869",
    "testFlightInternalTestingOnly": False,
    "uploadSymbols": True,
}


def fail(message: str) -> "None":
    raise SystemExit(f"[ios-app-store-options] ERROR: {message}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--options", required=True, type=Path)
    arguments = parser.parse_args()
    if not arguments.options.is_absolute():
        fail("export options path must be absolute")
    try:
        metadata = arguments.options.lstat()
    except OSError:
        fail("export options file is unavailable")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail("export options must be a real regular file")
    try:
        with arguments.options.open("rb") as handle:
            payload = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        fail("export options are not a valid property list")
    if payload != EXPECTED_OPTIONS:
        fail("export options do not exactly match the App Store release contract")
    print("ios_app_store_export_options=valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
