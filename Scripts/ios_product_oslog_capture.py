#!/usr/bin/env python3
"""Read one physical iOS product process log with scoped system authentication."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
from pathlib import Path

MAX_BYTES = 8 * 1024 * 1024


def collection_command(device_udid: str, process_id: int, start_epoch: int) -> str:
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{7,63}", device_udid, re.ASCII) is None:
        raise ValueError("physical device UDID is invalid")
    if type(process_id) is not int or process_id <= 1:
        raise ValueError("exact product process ID is invalid")
    if type(start_epoch) is not int or start_epoch <= 0:
        raise ValueError("launch start epoch is invalid")
    predicate = (
        f'processIdentifier == {process_id} AND '
        'subsystem == "com.skybridge.compass.release-evidence" AND '
        'category == "ProductSession"'
    )
    # SIGALRM survives exec, bounding the privileged commands even if the
    # unprivileged caller is cancelled while the system dialog is open.
    deadline = ["/usr/bin/perl", "-e", 'alarm 120; exec @ARGV; die "log reader exec failed: $!";', "--"]
    collect = shlex.join(deadline + [
        "/usr/bin/log", "collect", "--device-udid", device_udid,
        "--start", f"@{start_epoch}", "--size", "8m", "--predicate", predicate,
    ])
    show = shlex.join(deadline + ["/usr/bin/log", "show", "--style", "ndjson", "--predicate", predicate])
    return "\n".join((
        "set -eu",
        "umask 077",
        'log_capture_dir="$(/usr/bin/mktemp -d /private/tmp/skybridge-ios-product-oslog.XXXXXX)"',
        """trap '/bin/rm -rf "$log_capture_dir"' EXIT""",
        collect + ' --output "$log_capture_dir/product.logarchive" >/dev/null',
        show + ' --archive "$log_capture_dir/product.logarchive"',
    ))


def capture(*, device_udid: str, process_id: int, start_epoch: int, raw_output: Path) -> None:
    command = collection_command(device_udid, process_id, start_epoch)
    if not raw_output.is_absolute() or raw_output.parent.is_symlink():
        raise ValueError("private log output must have an absolute real parent")
    # No user-controlled file is executed with privilege or used as a root
    # output path. The fixed reader returns its filtered result over stdout.
    argv = (
        ["/bin/bash", "-c", command] if os.geteuid() == 0 else
        ["/usr/bin/osascript", "-e", "do shell script " + json.dumps(command) + " with administrator privileges"]
    )
    descriptor = os.open(
        raw_output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600
    )
    complete = False
    try:
        with os.fdopen(descriptor, "wb") as output:
            try:
                result = subprocess.run(
                    argv, stdout=output, stderr=subprocess.PIPE, check=False, timeout=300
                )
            except subprocess.TimeoutExpired:
                raise RuntimeError(
                    "scoped iOS log capture timed out waiting for system authentication or the log reader"
                ) from None
            if result.returncode != 0:
                detail = result.stderr.decode("utf-8", errors="replace").strip()
                raise RuntimeError(f"scoped iOS log collection failed ({result.returncode}): {detail}")
            output.flush()
            size = os.fstat(output.fileno()).st_size
            if not 0 < size <= MAX_BYTES:
                raise RuntimeError("private iOS OSLog is empty or exceeds the fixed bound")
            os.fsync(output.fileno())
        complete = True
    finally:
        if not complete:
            raw_output.unlink()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device-udid", required=True)
    parser.add_argument("--process-id", required=True, type=int)
    parser.add_argument("--start-epoch", required=True, type=int)
    parser.add_argument("--raw-output", required=True, type=Path)
    args = parser.parse_args()
    capture(
        device_udid=args.device_udid, process_id=args.process_id,
        start_epoch=args.start_epoch, raw_output=args.raw_output,
    )


if __name__ == "__main__":
    main()
