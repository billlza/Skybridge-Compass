#!/usr/bin/env python3
"""Validate one run-scoped Android-to-Mac LAN smoke status transcript."""

from __future__ import annotations

import argparse
import os
import re
import stat
import sys
import unicodedata
from pathlib import Path


MAX_STATUS_BYTES = 4 * 1024 * 1024
MAX_STATUS_LINE_CHARS = 2_080
RUN_REF_PATTERN = re.compile(r"^[0-9a-f]{64}$")
STAMPED_LINE_PATTERN = re.compile(
    r"^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] (.+)$"
)
SECURE_LINE_PATTERN = re.compile(
    r"^security secure peer=\S+ suite=\S+ trust=(TRUSTED_NEW|TRUSTED_EXISTING)$"
)
FRAME_LINE_PATTERN = re.compile(
    r"^frame width=[1-9][0-9]* height=[1-9][0-9]* format=\S+ owner=current$"
)
IDENTITY_LINE = (
    "identity authority=authenticated_product_v1 "
    "handshake=verified frameOwner=current"
)
ROUTE_AUTHORITY_LINE = "routeAuthority=debug_run_scoped snapshot=current"


class StatusContractError(ValueError):
    """The status file cannot be attributed to one valid smoke attempt."""


def _parse_bool(raw: str, name: str) -> bool:
    if raw == "true":
        return True
    if raw == "false":
        return False
    raise StatusContractError(f"{name} must be true or false")


def _is_unsafe_character(character: str) -> bool:
    return unicodedata.category(character) in {"Cc", "Cf", "Zl", "Zp"}


def _read_payloads(path: Path, *, allow_incomplete_tail: bool) -> list[str]:
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return []
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise StatusContractError("status path is not a regular non-symlink file")
    if metadata.st_size > MAX_STATUS_BYTES:
        raise StatusContractError("status file exceeds the bounded size")
    try:
        text = path.read_text(encoding="utf-8", errors="strict")
    except UnicodeError as error:
        raise StatusContractError("status file is not valid UTF-8") from error
    if not text:
        return []

    raw_lines = text.split("\n")
    if raw_lines[-1] == "":
        raw_lines.pop()
    elif allow_incomplete_tail:
        raw_lines.pop()
    else:
        raise StatusContractError("status file is not newline terminated")
    payloads: list[str] = []
    for raw_line in raw_lines:
        if not raw_line:
            raise StatusContractError("status file contains an empty interior line")
        if len(raw_line) > MAX_STATUS_LINE_CHARS:
            raise StatusContractError("status line exceeds the bounded length")
        if any(_is_unsafe_character(character) for character in raw_line):
            raise StatusContractError("status line contains a control or format character")
        match = STAMPED_LINE_PATTERN.fullmatch(raw_line)
        if match is None:
            raise StatusContractError("status line does not match the canonical stamped format")
        payloads.append(match.group(1))
    return payloads


def inspect_status(
    path: Path,
    expected_run_ref: str,
    *,
    require_secure: bool,
    allow_plaintext_fallback: bool,
    require_existing_product_trust: bool,
    allow_incomplete_tail: bool = False,
) -> str:
    if RUN_REF_PATTERN.fullmatch(expected_run_ref) is None:
        raise StatusContractError("expected run ref is not canonical")
    payloads = _read_payloads(path, allow_incomplete_tail=allow_incomplete_tail)
    if not payloads:
        return "pending"

    expected_attempt = f"attempt ref={expected_run_ref}"
    if payloads[0] != expected_attempt:
        raise StatusContractError("status transcript is not bound to the expected attempt")
    if payloads.count(expected_attempt) != 1:
        raise StatusContractError("status transcript repeats its attempt marker")
    if any(payload.startswith("attempt ref=") for payload in payloads[1:]):
        raise StatusContractError("status transcript contains a conflicting attempt marker")

    failure_indexes = [
        index for index, payload in enumerate(payloads)
        if payload.startswith("failure reason=")
    ]
    success_indexes = [
        index for index, payload in enumerate(payloads)
        if payload.startswith("success reason=")
    ]
    if failure_indexes and success_indexes:
        raise StatusContractError("status transcript contains both failure and success")
    if len(failure_indexes) > 1 or len(success_indexes) > 1:
        raise StatusContractError("status transcript contains duplicate terminal events")

    if failure_indexes:
        failure_index = failure_indexes[0]
        if failure_index != len(payloads) - 1:
            raise StatusContractError("failure is not the final status event")
        reason = payloads[failure_index].removeprefix("failure reason=")
        if not reason:
            raise StatusContractError("failure status has an empty reason")
        if "missing peer KEM bootstrap" in reason or reason.startswith("security_untrusted="):
            return "failure:normal_product_pairing_required"
        return "failure:reported"

    if not success_indexes:
        return "pending"
    success_index = success_indexes[0]
    if success_index != len(payloads) - 1:
        raise StatusContractError("success is not the final status event")
    success = payloads[success_index]

    if success == "success reason=secure_frame_received":
        if not require_secure and allow_plaintext_fallback:
            # A secure result remains valid in an explicitly diagnostic mixed-mode run.
            pass
        if any(payload.startswith("security plaintext") for payload in payloads):
            raise StatusContractError("secure success also contains a plaintext security state")
        secure_indexes = [
            index for index, payload in enumerate(payloads)
            if SECURE_LINE_PATTERN.fullmatch(payload) is not None
        ]
        if not secure_indexes:
            raise StatusContractError("secure success lacks a canonical secure state")
        if any(
            payload.startswith("security secure")
            and SECURE_LINE_PATTERN.fullmatch(payload) is None
            for payload in payloads
        ):
            raise StatusContractError("secure state has a non-canonical shape")
        frame_indexes = [
            index for index, payload in enumerate(payloads)
            if FRAME_LINE_PATTERN.fullmatch(payload) is not None
        ]
        if len(frame_indexes) != 1:
            raise StatusContractError("secure success requires one current-owner frame event")
        frame_index = frame_indexes[0]
        if frame_index + 1 != success_index:
            raise StatusContractError("secure frame and success are not adjacent")

        if require_existing_product_trust:
            route_indexes = [
                index for index, payload in enumerate(payloads)
                if payload == ROUTE_AUTHORITY_LINE
            ]
            if len(route_indexes) != 1 or route_indexes[0] >= min(secure_indexes):
                raise StatusContractError(
                    "existing-product success requires one current debug route lease"
                )
            identity_indexes = [
                index for index, payload in enumerate(payloads)
                if payload == IDENTITY_LINE
            ]
            if len(identity_indexes) != 1:
                raise StatusContractError(
                    "existing-product success requires one authenticated authority event"
                )
            identity_index = identity_indexes[0]
            if identity_index + 1 != frame_index:
                raise StatusContractError(
                    "authenticated authority, frame, and success are not adjacent"
                )
            trusted_secure_indexes = [
                index for index in secure_indexes
                if payloads[index].endswith(" trust=TRUSTED_EXISTING")
                and index < identity_index
            ]
            if not trusted_secure_indexes:
                raise StatusContractError(
                    "authenticated authority lacks a preceding existing-trust secure state"
                )
            if any(
                payload.startswith("security secure")
                and not payload.endswith(" trust=TRUSTED_EXISTING")
                for payload in payloads
            ):
                raise StatusContractError(
                    "existing-product transcript contains a different secure trust state"
                )
        elif max(secure_indexes) >= frame_index:
            raise StatusContractError("secure state does not precede the current-owner frame")
        return "success:secure"

    if success == "success reason=plaintext_frame_received":
        if require_secure or not allow_plaintext_fallback:
            raise StatusContractError("plaintext success violates the requested transport policy")
        if not any(
            payload.startswith("security plaintext")
            for payload in payloads[:success_index]
        ):
            raise StatusContractError("plaintext success lacks a preceding plaintext state")
        if require_existing_product_trust:
            raise StatusContractError("plaintext success cannot prove existing product trust")
        return "success:plaintext"

    raise StatusContractError("status transcript has an unknown success reason")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("status_path", type=Path)
    parser.add_argument("expected_run_ref")
    parser.add_argument("require_secure")
    parser.add_argument("allow_plaintext_fallback")
    parser.add_argument("require_existing_product_trust")
    parser.add_argument("allow_incomplete_tail")
    args = parser.parse_args(argv)
    try:
        outcome = inspect_status(
            args.status_path,
            args.expected_run_ref,
            require_secure=_parse_bool(args.require_secure, "require_secure"),
            allow_plaintext_fallback=_parse_bool(
                args.allow_plaintext_fallback,
                "allow_plaintext_fallback",
            ),
            require_existing_product_trust=_parse_bool(
                args.require_existing_product_trust,
                "require_existing_product_trust",
            ),
            allow_incomplete_tail=_parse_bool(
                args.allow_incomplete_tail,
                "allow_incomplete_tail",
            ),
        )
    except (OSError, StatusContractError) as error:
        print(f"invalid Android LAN status: {error}", file=sys.stderr)
        return 2
    print(outcome)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
