#!/usr/bin/env python3
"""Validate the one CoreDevice result that proves an app-container file is absent."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


class IOSCopyAbsenceError(ValueError):
    pass


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise IOSCopyAbsenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def validate_absence_result(path: Path, source: str) -> None:
    try:
        document = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise IOSCopyAbsenceError("CoreDevice result is unreadable") from error
    if not isinstance(document, dict) or set(document) != {"error", "info"}:
        raise IOSCopyAbsenceError("CoreDevice result has an unexpected top-level shape")
    error_value = document["error"]
    info = document["info"]
    if not isinstance(error_value, dict) or not isinstance(info, dict):
        raise IOSCopyAbsenceError("CoreDevice error metadata is malformed")
    description = (
        error_value.get("userInfo", {})
        .get("NSLocalizedDescription", {})
        .get("string")
    )
    expected_description = f"Failed to retrieve the file node for {source}"
    if (
        error_value.get("domain") != "com.apple.dt.CoreDeviceError"
        or type(error_value.get("code")) is not int
        or error_value.get("code") != 7000
        or description != expected_description
        or info.get("commandType") != "devicectl.device.copy.from"
        or info.get("outcome") != "failed"
    ):
        raise IOSCopyAbsenceError("CoreDevice failure does not prove file absence")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("result", type=Path)
    parser.add_argument("source")
    arguments = parser.parse_args()
    try:
        validate_absence_result(arguments.result, arguments.source)
    except IOSCopyAbsenceError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
