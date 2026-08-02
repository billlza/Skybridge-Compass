#!/usr/bin/env python3
"""Check that one P2P notice session reaches Disconnected after Active.

Exit status is a shell contract: 0 means the bound session disconnected, 1
means the event is not present yet, and 2 means the lifecycle is ambiguous or
invalid. An unrelated or earlier session can never satisfy the check.
"""

from __future__ import annotations

import pathlib
import re
import sys
from collections.abc import Iterable


DISCONNECTED = 0
PENDING = 1
INVALID = 2
_EVENT = re.compile(
    r"\bremoteControlNotice(?P<event>Active|Disconnected|Rejected|TimedOut)\s+"
    r"session=(?P<session>[^\s]+)\s+transport=p2p\b"
)


class NoticeLifecycleError(ValueError):
    """The requested notice session has contradictory lifecycle evidence."""


def is_same_session_disconnected(lines: Iterable[str], session: str) -> bool:
    if not session or any(character.isspace() for character in session):
        raise NoticeLifecycleError("session identifier is empty or malformed")

    events: list[str] = []
    for line in lines:
        match = _EVENT.search(line)
        if match is not None and match.group("session") == session:
            events.append(match.group("event"))

    active_indexes = [index for index, event in enumerate(events) if event == "Active"]
    if len(active_indexes) != 1:
        raise NoticeLifecycleError("expected exactly one Active event for the approved session")

    events_after_active = events[active_indexes[0] + 1 :]
    disconnected_indexes = [
        index for index, event in enumerate(events_after_active) if event == "Disconnected"
    ]
    if not disconnected_indexes:
        if any(event in {"Rejected", "TimedOut"} for event in events_after_active):
            raise NoticeLifecycleError("approved active session terminated without Disconnected")
        return False
    if len(disconnected_indexes) != 1:
        raise NoticeLifecycleError("approved session contains duplicate Disconnected events")
    if any(
        event in {"Rejected", "TimedOut"}
        for event in events_after_active[: disconnected_indexes[0]]
    ):
        raise NoticeLifecycleError("approved session has a conflicting terminal event")
    return True


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: check_p2p_notice_disconnect.py STATUS_LOG SESSION", file=sys.stderr)
        return INVALID
    path = pathlib.Path(argv[1])
    try:
        with path.open("r", encoding="utf-8", errors="strict") as handle:
            disconnected = is_same_session_disconnected(handle, argv[2])
    except (OSError, UnicodeError, NoticeLifecycleError) as error:
        print(f"P2P notice disconnect evidence is invalid: {error}", file=sys.stderr)
        return INVALID
    return DISCONNECTED if disconnected else PENDING


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
