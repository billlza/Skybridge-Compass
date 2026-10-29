#!/usr/bin/env python3
"""Validate the forced PIB-1 -> SKR-1 evidence chain for P2P remote smoke."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


class EvidenceValidationError(Exception):
    """The captured status does not prove the required identity refresh chain."""


class EvidenceInputError(EvidenceValidationError):
    """The validator input or configuration is unsafe or unreadable."""


FORCED_REFRESH_PATTERN = re.compile(
    r"SKR-1 signed LAN KEM refresh forced: .*"
    r"clearedKEM=1 .*preserveProtocolIdentity=1 .*"
    r"lifecycle=force-missing-kem"
)
EVIDENCE_REFERENCE = r"ev1:[0-9a-f]{32}"


def _ordered_match_indices(
    text: str,
    labeled_patterns: list[tuple[str, re.Pattern[str]]],
) -> list[int]:
    """Require exactly one unambiguous, ordered lifecycle chain."""

    indices: list[int] = []
    for label, pattern in labeled_patterns:
        matches = list(pattern.finditer(text))
        if not matches:
            raise EvidenceValidationError(f"missing:{label}")
        if len(matches) != 1:
            raise EvidenceValidationError(f"duplicate:{label}")
        indices.append(matches[0].start())
    if indices != sorted(indices):
        raise EvidenceValidationError("out-of-order")
    return indices


def _require_reference(
    label: str,
    match: re.Match[str],
    group: str,
) -> str:
    value = match.groupdict().get(group)
    if value is None or re.fullmatch(EVIDENCE_REFERENCE, value) is None:
        raise EvidenceValidationError(f"invalid-reference:{label}:{group}")
    return value


def _require_same_reference(label: str, values: list[str]) -> str:
    if not values or len(set(values)) != 1:
        raise EvidenceValidationError(f"reference-mismatch:{label}")
    return values[0]


def validate_forced_refresh_evidence(
    host_status: str,
    ios_status: str,
    expected_suite: str,
) -> str:
    if not expected_suite or any(character.isspace() for character in expected_suite):
        raise EvidenceInputError("invalid-expected-suite")

    escaped_suite = re.escape(expected_suite)
    strict_target_fragment = (
        r"strictXWingEstablished=1 .*" if expected_suite == "X-Wing" else ""
    )
    ios_chain = [
        ("forced-refresh", FORCED_REFRESH_PATTERN),
        (
            "pib-request",
            re.compile(
                r"PIB-1 protocol identity binding request: .*"
                rf"pib_ref=(?P<pib_ref>{EVIDENCE_REFERENCE}) .*"
                r"lifecycle=identity-oob>request"
            ),
        ),
        (
            "pib-signature-verified",
            re.compile(
                r"PIB-1 protocol identity binding signature verified: .*"
                rf"pib_ref=(?P<pib_ref>{EVIDENCE_REFERENCE}) .*"
                r"lifecycle=identity-oob>verified"
            ),
        ),
        (
            "pib-confirm",
            re.compile(
                r"PIB-1 protocol identity binding confirm sent: .*"
                rf"pib_ref=(?P<pib_ref>{EVIDENCE_REFERENCE}) .*"
                r"lifecycle=identity-oob>confirm"
            ),
        ),
        (
            "pib-pinned",
            re.compile(
                r"PIB-1 protocol identity binding pinned: .*"
                rf"pib_ref=(?P<pib_ref>{EVIDENCE_REFERENCE}) .*"
                r"lifecycle=identity-oob>pinned"
            ),
        ),
        (
            "pib-final-ack",
            re.compile(
                r"PIB-1 v3 protocol identity binding final acknowledgement "
                rf"verified and pinned: .*pib_ref=(?P<pib_ref>{EVIDENCE_REFERENCE}) .*"
                r"lifecycle=identity-oob>final-ack>pinned"
            ),
        ),
        (
            "skr-request",
            re.compile(
                r"SKR-1 signed LAN KEM refresh request: .*"
                rf"skr_ref=(?P<skr_ref>{EVIDENCE_REFERENCE}) "
                rf"recovery_ref=(?P<recovery_ref>{EVIDENCE_REFERENCE}) .*"
                r"pinnedProtocolIdentity=1 .*lifecycle=missing-kem>request"
            ),
        ),
        (
            "skr-import",
            re.compile(
                rf"SKR-1 signed LAN KEM refresh verified and imported: .*"
                rf"skr_ref=(?P<skr_ref>{EVIDENCE_REFERENCE}) "
                rf"payload_ref=(?P<payload_ref>{EVIDENCE_REFERENCE}) "
                rf"recovery_ref=(?P<recovery_ref>{EVIDENCE_REFERENCE}) .*"
                rf"suites=.*{escaped_suite}.*pinnedProtocolIdentity=1 .*"
                r"signature=verified .*requestHash=bound .*"
                r"lifecycle=served>verified"
            ),
        ),
        (
            "skr-smoke-proof",
            re.compile(
                r"SKR-1 signed LAN KEM refresh smoke-evidence: .*"
                r"source=signed_lan_kem_refresh .*"
                rf"payload_ref=(?P<payload_ref>{EVIDENCE_REFERENCE}) .*"
                r"pinnedProtocolIdentity=1 .*signature=verified .*"
                r"requestHash=bound .*"
                + strict_target_fragment
                + r"lifecycle=verified>smoke-proof"
            ),
        ),
    ]
    _ordered_match_indices(ios_status, ios_chain)
    ios_matches = {
        label: pattern.search(ios_status)
        for label, pattern in ios_chain
    }
    if any(match is None for match in ios_matches.values()):
        raise EvidenceValidationError("internal-missing-ios-match")

    pib_reference = _require_same_reference(
        "ios-pib",
        [
            _require_reference(label, ios_matches[label], "pib_ref")  # type: ignore[arg-type]
            for label in (
                "pib-request",
                "pib-signature-verified",
                "pib-confirm",
                "pib-pinned",
                "pib-final-ack",
            )
        ],
    )
    skr_reference = _require_same_reference(
        "ios-skr",
        [
            _require_reference(label, ios_matches[label], "skr_ref")  # type: ignore[arg-type]
            for label in ("skr-request", "skr-import")
        ],
    )
    recovery_reference = _require_same_reference(
        "ios-recovery",
        [
            _require_reference(label, ios_matches[label], "recovery_ref")  # type: ignore[arg-type]
            for label in ("skr-request", "skr-import")
        ],
    )
    if recovery_reference != pib_reference:
        raise EvidenceValidationError("reference-mismatch:pib-to-skr-recovery")
    payload_reference = _require_same_reference(
        "ios-skr-payload",
        [
            _require_reference(label, ios_matches[label], "payload_ref")  # type: ignore[arg-type]
            for label in ("skr-import", "skr-smoke-proof")
        ],
    )

    host_chain = [
        (
            "host-pib-served",
            re.compile(
                r"PIB-1 protocol identity binding served: .*"
                rf"pib_ref=(?P<pib_ref>{EVIDENCE_REFERENCE}) .*"
                r"lifecycle=identity-oob>served"
            ),
        ),
        (
            "host-pib-confirmed",
            re.compile(
                r"PIB-1 v3 confirmation committed and acknowledged .*"
                rf"pib_ref=(?P<pib_ref>{EVIDENCE_REFERENCE}) .*"
                r"lifecycle=identity-oob>confirmed"
            ),
        ),
        (
            "host-skr-served",
            re.compile(
                r"SKR-1 signed LAN KEM refresh served: .*"
                rf"skr_ref=(?P<skr_ref>{EVIDENCE_REFERENCE}) "
                rf"payload_ref=(?P<payload_ref>{EVIDENCE_REFERENCE}) .*"
                r"lifecycle=request>served"
            ),
        ),
    ]
    _ordered_match_indices(host_status, host_chain)
    host_matches = {
        label: pattern.search(host_status)
        for label, pattern in host_chain
    }
    if any(match is None for match in host_matches.values()):
        raise EvidenceValidationError("internal-missing-host-match")

    host_pib_reference = _require_same_reference(
        "host-pib",
        [
            _require_reference(label, host_matches[label], "pib_ref")  # type: ignore[arg-type]
            for label in ("host-pib-served", "host-pib-confirmed")
        ],
    )
    host_skr_reference = _require_reference(
        "host-skr-served",
        host_matches["host-skr-served"],  # type: ignore[arg-type]
        "skr_ref",
    )
    host_payload_reference = _require_reference(
        "host-skr-served",
        host_matches["host-skr-served"],  # type: ignore[arg-type]
        "payload_ref",
    )
    if host_pib_reference != pib_reference:
        raise EvidenceValidationError("reference-mismatch:peer-pib")
    if host_skr_reference != skr_reference:
        raise EvidenceValidationError("reference-mismatch:peer-skr")
    if host_payload_reference != payload_reference:
        raise EvidenceValidationError("reference-mismatch:peer-skr-payload")
    return "forced-pib-skr"


def _read_regular_file(path: Path, label: str) -> str:
    if not path.is_absolute():
        raise EvidenceInputError(f"{label}-path-not-absolute")
    if path.is_symlink() or not path.is_file():
        raise EvidenceInputError(f"{label}-not-regular-file")
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        raise EvidenceInputError(f"{label}-read-failed") from error


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate a forced PIB-1 then SKR-1 P2P refresh chain."
    )
    parser.add_argument("--host-status", required=True, type=Path)
    parser.add_argument("--ios-status", required=True, type=Path)
    parser.add_argument("--expected-suite", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        mode = validate_forced_refresh_evidence(
            _read_regular_file(args.host_status, "host-status"),
            _read_regular_file(args.ios_status, "ios-status"),
            args.expected_suite,
        )
    except EvidenceInputError as error:
        print(f"identity-refresh-evidence-input-invalid:{error}", file=sys.stderr)
        return 2
    except EvidenceValidationError as error:
        print(f"identity-refresh-evidence-invalid:{error}", file=sys.stderr)
        return 1
    print(mode)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
