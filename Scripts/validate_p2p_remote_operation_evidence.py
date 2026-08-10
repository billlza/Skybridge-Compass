#!/usr/bin/env python3
"""Validate one exact P2P remote-desktop configuration operation.

The references checked here are privacy-preserving correlations emitted only
after production owner checks. They are evidence joins, not authentication;
the P2P protocol remains responsible for authenticating the session.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Callable, Iterable, Sequence


REFERENCE = re.compile(r"^ev1:[0-9a-f]{32}$")


class EvidenceValidationError(ValueError):
    """The supplied artifacts do not prove one exact remote operation."""


def metric(line: str, key: str) -> str | None:
    match = re.search(rf"(?:^|\s){re.escape(key)}=([^\s,]+)", line)
    return match.group(1).strip() if match else None


def exact_refs(line: str, label: str) -> tuple[str, str]:
    session_ref = metric(line, "session_ref")
    stream_ref = metric(line, "stream_ref")
    if session_ref is None or REFERENCE.fullmatch(session_ref) is None:
        raise EvidenceValidationError(f"{label} has no valid session_ref")
    if stream_ref is None or REFERENCE.fullmatch(stream_ref) is None:
        raise EvidenceValidationError(f"{label} has no valid stream_ref")
    return session_ref, stream_ref


def _unique_line(
    lines: Sequence[str],
    predicate: Callable[[str], bool],
    label: str,
) -> tuple[int, str]:
    matches = [(index, line) for index, line in enumerate(lines) if predicate(line)]
    if len(matches) != 1:
        raise EvidenceValidationError(
            f"expected exactly one {label}, observed {len(matches)}"
        )
    return matches[0]


def _first_after(
    lines: Sequence[str],
    start: int,
    predicate: Callable[[str], bool],
    label: str,
) -> tuple[int, str]:
    for index in range(start, len(lines)):
        if predicate(lines[index]):
            return index, lines[index]
    raise EvidenceValidationError(f"missing {label}")


def _reject_other_references(
    lines: Iterable[str],
    markers: tuple[str, ...],
    expected: tuple[str, str],
    label: str,
) -> None:
    for line in lines:
        if any(marker in line for marker in markers):
            if exact_refs(line, label) != expected:
                raise EvidenceValidationError(
                    f"{label} contains a different operation reference"
                )


def _reference(line: str, key: str, label: str) -> str:
    value = metric(line, key)
    if value is None or REFERENCE.fullmatch(value) is None:
        raise EvidenceValidationError(f"{label} has no valid {key}")
    return value


def _require_marker_reference(
    lines: Sequence[str],
    marker: str,
    key: str,
    expected: str,
    label: str,
) -> None:
    matching = [line for line in lines if marker in line]
    if not matching:
        raise EvidenceValidationError(f"missing {label}")
    if any(_reference(line, key, label) != expected for line in matching):
        raise EvidenceValidationError(f"{label} reference mismatch")


def validate_remote_operation(
    host_lines: Sequence[str],
    ios_lines: Sequence[str],
    approval_proof: dict[str, object] | None = None,
    require_identity_link: bool = True,
) -> tuple[str, str]:
    ios_config_index, ios_config = _unique_line(
        ios_lines,
        lambda line: "event=streamConfigSent" in line
        and "perf=extreme" in line
        and "retryAttempt=" not in line,
        "initial iOS stream configuration",
    )
    expected_refs = exact_refs(ios_config, "iOS stream configuration")
    session_ref, stream_ref = expected_refs

    _, session_link = _unique_line(
        ios_lines,
        lambda line: "p2p-session-link " in line,
        "authenticated P2P session link",
    )
    if _reference(session_link, "session_ref", "P2P session link") != session_ref:
        raise EvidenceValidationError("P2P handshake and stream session references differ")

    if require_identity_link:
        _, identity_link = _unique_line(
            ios_lines,
            lambda line: "p2p-evidence-link " in line,
            "PIB/SKR authenticated-session link",
        )
        if _reference(identity_link, "session_ref", "PIB/SKR session link") != session_ref:
            raise EvidenceValidationError("PIB/SKR and handshake session references differ")
        pib_ref = _reference(identity_link, "pib_ref", "PIB/SKR session link")
        skr_ref = _reference(identity_link, "skr_ref", "PIB/SKR session link")
        payload_ref = _reference(identity_link, "payload_ref", "PIB/SKR session link")
        _require_marker_reference(
            ios_lines,
            "PIB-1 protocol identity binding request:",
            "pib_ref",
            pib_ref,
            "iOS PIB request",
        )
        _require_marker_reference(
            host_lines,
            "PIB-1 protocol identity binding served:",
            "pib_ref",
            pib_ref,
            "Mac PIB response",
        )
        _require_marker_reference(
            ios_lines,
            "SKR-1 signed LAN KEM refresh request:",
            "skr_ref",
            skr_ref,
            "iOS SKR request",
        )
        _require_marker_reference(
            host_lines,
            "SKR-1 signed LAN KEM refresh served:",
            "skr_ref",
            skr_ref,
            "Mac SKR response",
        )
        _require_marker_reference(
            ios_lines,
            "SKR-1 signed LAN KEM refresh verified and imported:",
            "payload_ref",
            payload_ref,
            "iOS SKR payload",
        )
        _require_marker_reference(
            host_lines,
            "SKR-1 signed LAN KEM refresh served:",
            "payload_ref",
            payload_ref,
            "Mac SKR payload",
        )

    if approval_proof is not None:
        if approval_proof.get("schemaVersion") != 2:
            raise EvidenceValidationError("approval proof schema is invalid")
        if approval_proof.get("sessionRef") != session_ref:
            raise EvidenceValidationError("human approval and stream session references differ")
        if approval_proof.get("humanApproval") is not True:
            raise EvidenceValidationError("human approval is missing")
        if approval_proof.get("runtimeAutoApproval") is not False:
            raise EvidenceValidationError("runtime auto-approval is not allowed")

    ios_ack_index, ios_ack = _first_after(
        ios_lines,
        ios_config_index + 1,
        lambda line: "event=streamConfigAck" in line
        and exact_refs(line, "iOS stream configuration ACK") == expected_refs,
        "exact iOS stream configuration ACK",
    )
    if any(
        "event=firstFrame" in line
        for line in ios_lines[ios_config_index + 1 : ios_ack_index]
    ):
        raise EvidenceValidationError(
            "iOS emitted a first-frame event before the exact configuration ACK"
        )
    ios_frame_index, ios_frame = _first_after(
        ios_lines,
        ios_ack_index + 1,
        lambda line: "event=firstFrame" in line
        and exact_refs(line, "iOS first frame") == expected_refs,
        "exact iOS first frame",
    )
    _ = ios_ack, ios_frame
    _reject_other_references(
        ios_lines[ios_config_index : ios_frame_index + 1],
        ("event=streamConfigSent", "event=streamConfigAck", "event=firstFrame"),
        expected_refs,
        "iOS remote operation evidence",
    )

    host_config_index, host_config = _unique_line(
        host_lines,
        lambda line: "mac-stream-config " in line
        and exact_refs(line, "Mac stream configuration") == expected_refs,
        "matching Mac stream configuration",
    )
    host_ack_index, host_ack = _first_after(
        host_lines,
        host_config_index + 1,
        lambda line: "mac-stream-config-ack " in line
        and exact_refs(line, "Mac stream configuration ACK") == expected_refs,
        "matching Mac stream configuration ACK",
    )

    for line in host_lines[host_config_index + 1 : host_ack_index]:
        if "mac-remote-frame-tx " not in line:
            continue
        try:
            if int(metric(line, "sent") or "0") > 0:
                raise EvidenceValidationError(
                    "Mac transmitted a frame before the exact configuration ACK"
                )
        except ValueError as error:
            raise EvidenceValidationError(
                "Mac pre-ACK frame sent count is not an integer"
            ) from error

    def is_sent_frame(line: str) -> bool:
        if "mac-remote-frame-tx " not in line:
            return False
        if exact_refs(line, "Mac transmitted frame") != expected_refs:
            return False
        try:
            return int(metric(line, "sent") or "0") > 0
        except ValueError as error:
            raise EvidenceValidationError("Mac frame sent count is not an integer") from error

    host_tx_index, host_tx = _first_after(
        host_lines,
        host_ack_index + 1,
        is_sent_frame,
        "matching Mac transmitted frame",
    )
    _ = host_config, host_ack, host_tx
    _reject_other_references(
        host_lines[host_config_index : host_tx_index + 1],
        ("mac-stream-config ", "mac-stream-config-ack ", "mac-remote-frame-tx "),
        expected_refs,
        "Mac remote operation evidence",
    )

    if not (ios_config_index < ios_ack_index < ios_frame_index):
        raise EvidenceValidationError(
            "iOS configuration, ACK, and first-frame order is invalid"
        )
    if not (host_config_index < host_ack_index < host_tx_index):
        raise EvidenceValidationError(
            "Mac configuration, ACK, and frame-transmit order is invalid"
        )
    return session_ref, stream_ref


def _read_lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-status", required=True, type=Path)
    parser.add_argument("--ios-status", required=True, type=Path)
    parser.add_argument("--approval-proof", required=True, type=Path)
    parser.add_argument(
        "--require-identity-link",
        required=True,
        choices=("true", "false"),
    )
    args = parser.parse_args()
    try:
        approval_proof = json.loads(
            args.approval_proof.read_text(encoding="utf-8", errors="strict")
        )
        if not isinstance(approval_proof, dict):
            raise EvidenceValidationError("approval proof is not an object")
        session_ref, stream_ref = validate_remote_operation(
            _read_lines(args.host_status),
            _read_lines(args.ios_status),
            approval_proof=approval_proof,
            require_identity_link=args.require_identity_link == "true",
        )
    except (EvidenceValidationError, json.JSONDecodeError, OSError) as error:
        parser.exit(1, f"remote operation validation failed: {error}\n")
    print(
        "remote operation validation passed: "
        f"sessionRef={session_ref} streamRef={stream_ref} "
        "configAck=exact firstFrame=exact macTx=exact"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
