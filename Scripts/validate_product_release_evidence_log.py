#!/usr/bin/env python3
"""Extract and validate privacy-safe normal-product release evidence.

The shipping app writes a fixed OSLog schema.  Raw unified-log rows contain
machine metadata and are never release artifacts.  ``extract-oslog`` accepts
only rows from one exact candidate process and emits the public message lines
plus a small process-binding capture manifest.  ``validate`` then enforces the
ordered product-session contract for one of the four canonical evidence kinds.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, NoReturn

from ios_physical_release_acceptance import (
    PhysicalAcceptanceError,
    validate_archive_binding,
)


SUBSYSTEM = "com.skybridge.compass.release-evidence"
CATEGORY = "ProductSession"
MAC_LOG_FILE = "mac-product-session.log"
MAC_CAPTURE_FILE = "mac-product-session-capture.json"
IOS_LOG_FILE = "ios-product-session.log"
IOS_CAPTURE_FILE = "ios-product-session-capture.json"
# Backwards-compatible names for the Mac-only remote-control/file-transfer API.
LOG_FILE = MAC_LOG_FILE
CAPTURE_FILE = MAC_CAPTURE_FILE
CAPTURE_PROFILE = "skybridge-product-release-evidence-capture"
CAPTURE_MODE = "unified-log-process-bound"
IOS_CAPTURE_MODE = "devicectl-unified-log-process-bound"
MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_LINE_BYTES = 4096
MAX_EVENT_COUNT = 4096
MAX_EVENT_COUNT_PER_SESSION = 20
REFERENCE_PATTERN = re.compile(r"ev1:[0-9a-f]{32}\Z", re.ASCII)
ATTEMPT_REFERENCE_PATTERN = re.compile(r"at1:[0-9a-f]{32}\Z", re.ASCII)
FIELD_KEY_PATTERN = re.compile(r"[A-Za-z][A-Za-z0-9_]*\Z", re.ASCII)
FIELD_VALUE_PATTERN = re.compile(r"[A-Za-z0-9:+.,-]+\Z", re.ASCII)
UINT64_MAX = (1 << 64) - 1

COMMON_FIELDS = ("transport", "session_ref", "owner", "generation")
CONNECTIVITY_OWNER_FIELDS = (
    "transport",
    "attempt_ref",
    "owner",
    "generation",
    "role",
    "localProfile",
    "offeredProfiles",
    "requirePQC",
    "allowClassicFallback",
)
EVENT_FIELDS: dict[str, tuple[str, ...]] = {
    "remoteControlNoticeShown": COMMON_FIELDS + ("phase", "result"),
    "remoteControlNoticePanelPresented": COMMON_FIELDS
    + ("phase", "buttons", "result"),
    "remoteControlNoticeHumanApproved": COMMON_FIELDS
    + ("phase", "decisionSource", "result"),
    "remoteControlNoticeApproved": COMMON_FIELDS
    + ("phase", "decisionSource", "result"),
    "remoteControlNoticeActive": COMMON_FIELDS + ("phase", "result"),
    "remoteControlNoticeRejected": COMMON_FIELDS + ("phase", "result"),
    "remoteControlNoticeTimedOut": COMMON_FIELDS + ("phase", "result"),
    "remoteControlNoticeDisconnected": COMMON_FIELDS + ("phase", "result"),
    "remoteControlNoticePanelHidden": COMMON_FIELDS + ("phase", "result"),
    "secureFrameAccepted": COMMON_FIELDS
    + ("frame_seq", "effect", "proof", "bytes", "width", "height"),
    "localFramePresented": COMMON_FIELDS
    + ("local_frame_seq", "effect", "proof", "bytes", "width", "height"),
    "remoteInputApplied": COMMON_FIELDS + ("event_seq", "effect", "applied"),
    "p2pSessionAuthenticated": COMMON_FIELDS + ("role", "suite", "result"),
    "webrtcPQCRekeyAuthenticated": COMMON_FIELDS + ("suite", "result"),
    "webrtcMediaSample": COMMON_FIELDS
    + (
        "mediaRole",
        "sample_seq",
        "elapsed_ms",
        "video_frames",
        "video_bytes",
        "audio_units",
        "audio_bytes",
        "result",
    ),
    "connectivityAttemptStarted": CONNECTIVITY_OWNER_FIELDS + ("result",),
    "connectivityAttemptAuthenticated": CONNECTIVITY_OWNER_FIELDS
    + ("session_ref", "attemptProfile", "result"),
    "connectivityEndpoint": (
        "transport",
        "session_ref",
        "attempt_ref",
        "owner",
        "generation",
        "role",
        "localProfile",
        "offeredProfiles",
        "attemptProfile",
        "suite",
        "requirePQC",
        "allowClassicFallback",
        "result",
    ),
    "connectivityPolicyRejected": CONNECTIVITY_OWNER_FIELDS
    + ("peerOfferedProfiles", "peerOfferSignature", "reason", "result"),
    "connectivityAttemptFailed": CONNECTIVITY_OWNER_FIELDS + ("reason", "result"),
    "fileTransferStarted": COMMON_FIELDS
    + ("transfer_ref", "direction", "interaction", "payload", "result"),
    "fileTransferCompleted": COMMON_FIELDS
    + (
        "transfer_ref",
        "direction",
        "interaction",
        "payload",
        "integrity",
        "receipt",
        "result",
        "uiEffect",
    ),
    "releaseSessionDisconnected": COMMON_FIELDS
    + ("noticeHidden", "reason", "result"),
}

MAC_PRODUCT = "SkyBridgeCompassApp"
IOS_PRODUCT = "SkyBridgeCompassiOS"
PRODUCTS = (MAC_PRODUCT, IOS_PRODUCT)
PRODUCT_EXECUTABLES = {
    MAC_PRODUCT: "SkyBridgeCompassApp",
    IOS_PRODUCT: "SkyBridgeCompass-iOS",
}
PRODUCT_LOG_CONTRACTS: dict[str, tuple[str, str, str]] = {
    MAC_PRODUCT: (MAC_LOG_FILE, MAC_CAPTURE_FILE, "macos-release-candidate.json"),
    IOS_PRODUCT: (IOS_LOG_FILE, IOS_CAPTURE_FILE, "release-acceptance.json"),
}
CONNECTIVITY_SUCCESS_PROFILES = {
    ("xwing", "xwing"),
    ("xwing", "pqc"),
    ("pqc", "xwing"),
}
PQC_SUITES = {
    "X-Wing",
    "Q-Periapt-ABI2-PolicyBound",
    "ML-KEM-768",
    "ML-KEM-768-FS",
}
CLASSIC_SUITES = {"X25519", "P-256"}
OFFERED_PROFILE_FAMILIES = {
    "xwing": frozenset({"xwing"}),
    "pqc": frozenset({"pqc"}),
    "pqc+xwing": frozenset({"pqc", "xwing"}),
    "classic": frozenset({"classic"}),
}


class ProductEvidenceError(RuntimeError):
    """A product-evidence artifact violates the fixed release contract."""


def _fail(message: str) -> NoReturn:
    raise ProductEvidenceError(message)


def _read_regular_file(path: Path, label: str, maximum_bytes: int) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        _fail(f"unable to open {label} without following links: {exc}")
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            _fail(f"{label} must be a single-link regular file")
        if before.st_size < 1 or before.st_size > maximum_bytes:
            _fail(f"{label} size must be between 1 and {maximum_bytes} bytes")
        content = bytearray()
        while len(content) < before.st_size:
            chunk = os.read(descriptor, min(1024 * 1024, before.st_size - len(content)))
            if not chunk:
                _fail(f"{label} was truncated while reading")
            content.extend(chunk)
        if os.read(descriptor, 1):
            _fail(f"{label} grew while reading")
        after = os.fstat(descriptor)
        stable_fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns")
        if any(getattr(before, name) != getattr(after, name) for name in stable_fields):
            _fail(f"{label} changed while reading")
        return bytes(content)
    finally:
        os.close(descriptor)


def _positive_integer(value: str, label: str) -> int:
    if re.fullmatch(r"[1-9][0-9]*", value, re.ASCII) is None:
        _fail(f"{label} must be a positive decimal integer")
    parsed = int(value)
    if parsed > UINT64_MAX:
        _fail(f"{label} exceeds UInt64")
    return parsed


@dataclass(frozen=True)
class Event:
    name: str
    fields: dict[str, str]
    line_number: int

    @property
    def key(self) -> tuple[str, str, str, int]:
        if "session_ref" not in self.fields:
            _fail(f"line {self.line_number} has no product session reference")
        return (
            self.fields["transport"],
            self.fields["session_ref"],
            self.fields["owner"],
            int(self.fields["generation"]),
        )


@dataclass
class Session:
    owner: Event
    events: list[Event] = field(default_factory=list)
    disconnected: bool = False


@dataclass(frozen=True)
class ConnectivityAttempt:
    owner: str
    attempt_reference: str
    generation: int
    events: tuple[Event, ...]

    @property
    def names(self) -> tuple[str, ...]:
        return tuple(event.name for event in self.events)

    @property
    def fields(self) -> dict[str, str]:
        return self.events[0].fields

    @property
    def is_success(self) -> bool:
        return self.names == (
            "connectivityAttemptStarted",
            "connectivityAttemptAuthenticated",
            "connectivityEndpoint",
        )

    @property
    def is_expected_rejection(self) -> bool:
        return self.names == (
            "connectivityAttemptStarted",
            "connectivityPolicyRejected",
        )


def _parse_event_line(
    line: str,
    line_number: int,
    *,
    expected_owner: str = MAC_PRODUCT,
) -> Event:
    if not line or len(line.encode("utf-8")) > MAX_LINE_BYTES:
        _fail(f"line {line_number} is empty or exceeds {MAX_LINE_BYTES} bytes")
    if not line.isascii() or line != " ".join(line.split(" ")):
        _fail(f"line {line_number} must be canonical single-space ASCII")
    tokens = line.split(" ")
    name = tokens[0]
    fields: dict[str, str] = {}
    keys: list[str] = []
    for token in tokens[1:]:
        if token.count("=") != 1:
            _fail(f"line {line_number} has a malformed field")
        key, value = token.split("=", 1)
        if (
            FIELD_KEY_PATTERN.fullmatch(key) is None
            or FIELD_VALUE_PATTERN.fullmatch(value) is None
            or key in fields
        ):
            _fail(f"line {line_number} has an invalid or duplicate field")
        keys.append(key)
        fields[key] = value

    expected_fields: tuple[str, ...]
    if name == "releaseSessionOwner":
        transport = fields.get("transport")
        if transport == "p2p":
            expected_fields = COMMON_FIELDS + ("state", "routeClass")
        elif transport == "webrtc":
            expected_fields = COMMON_FIELDS + ("state", "selectedTransport")
        else:
            _fail(f"line {line_number} has an unsupported transport")
    else:
        expected_fields = EVENT_FIELDS.get(name, ())
        if not expected_fields:
            _fail(f"line {line_number} has an unsupported event: {name}")
    if tuple(keys) != expected_fields:
        _fail(f"line {line_number} fields are not the fixed {name} schema")

    if fields["transport"] not in {"p2p", "webrtc"}:
        _fail(f"line {line_number} has an unsupported transport")
    if "session_ref" in fields and REFERENCE_PATTERN.fullmatch(fields["session_ref"]) is None:
        _fail(f"line {line_number} has an invalid session_ref")
    if "attempt_ref" in fields and ATTEMPT_REFERENCE_PATTERN.fullmatch(
        fields["attempt_ref"]
    ) is None:
        _fail(f"line {line_number} has an invalid attempt_ref")
    if expected_owner not in PRODUCTS or fields["owner"] != expected_owner:
        _fail(f"line {line_number} is not owned by the expected shipping product")
    _positive_integer(fields["generation"], f"line {line_number} generation")
    return Event(name=name, fields=fields, line_number=line_number)


def parse_canonical_log(path: Path, *, expected_owner: str = MAC_PRODUCT) -> list[Event]:
    content = _read_regular_file(path, "product release evidence log", MAX_INPUT_BYTES)
    try:
        text = content.decode("ascii")
    except UnicodeDecodeError as exc:
        _fail(f"product release evidence log is not ASCII: {exc}")
    if not text.endswith("\n") or "\r" in text:
        _fail("product release evidence log must use LF termination")
    lines = text[:-1].split("\n")
    if not lines or len(lines) > MAX_EVENT_COUNT:
        _fail(f"product release evidence event count must be 1-{MAX_EVENT_COUNT}")
    return [
        _parse_event_line(line, index, expected_owner=expected_owner)
        for index, line in enumerate(lines, 1)
    ]


def _validate_event_values(event: Event) -> None:
    fields = event.fields
    line = event.line_number
    name = event.name
    if name == "releaseSessionOwner":
        if fields["state"] != "active":
            _fail(f"line {line} owner state must be active")
        if fields["transport"] == "p2p" and fields["routeClass"] not in {"wifi", "awdl"}:
            _fail(f"line {line} has an invalid P2P routeClass")
        if fields["transport"] == "webrtc" and fields["selectedTransport"] not in {
            "direct",
            "relay",
        }:
            _fail(f"line {line} has an invalid WebRTC selectedTransport")
        return
    expected_fixed: dict[str, dict[str, str]] = {
        "remoteControlNoticeShown": {"phase": "awaitingApproval", "result": "presented"},
        "remoteControlNoticePanelPresented": {
            "phase": "awaitingApproval",
            "buttons": "approve,reject",
            "result": "visible",
        },
        "remoteControlNoticeHumanApproved": {
            "phase": "awaitingApproval",
            "decisionSource": "user",
            "result": "approved",
        },
        "remoteControlNoticeApproved": {
            "phase": "awaitingApproval",
            "decisionSource": "user",
            "result": "approved",
        },
        "remoteControlNoticeActive": {"phase": "active", "result": "active"},
        "remoteControlNoticeRejected": {"phase": "terminal", "result": "rejected"},
        "remoteControlNoticeTimedOut": {"phase": "terminal", "result": "timed-out"},
        "remoteControlNoticeDisconnected": {
            "phase": "terminal",
            "result": "disconnected",
        },
        "remoteControlNoticePanelHidden": {"phase": "terminal", "result": "hidden"},
    }
    for key, expected in expected_fixed.get(name, {}).items():
        if fields[key] != expected:
            _fail(f"line {line} {name}.{key} must be {expected}")
    if name in {"secureFrameAccepted", "localFramePresented"}:
        sequence_field = (
            "frame_seq" if name == "secureFrameAccepted" else "local_frame_seq"
        )
        _positive_integer(fields[sequence_field], f"line {line} {sequence_field}")
        for key in ("bytes", "width", "height"):
            _positive_integer(fields[key], f"line {line} {key}")
        if fields["effect"] != "presented":
            _fail(f"line {line} secure frame effect must be presented")
        if name == "secureFrameAccepted":
            expected_proof = {
                "p2p": "p2p-renderer-ack",
                "webrtc": "webrtc-renderer-receipt",
            }[fields["transport"]]
            if fields["proof"] != expected_proof:
                _fail(
                    f"line {line} secure frame proof must match the peer {fields['transport']} renderer"
                )
        elif fields["proof"] != "local-renderer":
            _fail(f"line {line} local frame proof must be local-renderer")
    elif name == "remoteInputApplied":
        _positive_integer(fields["event_seq"], f"line {line} event_seq")
        if fields["effect"] not in {"pointer", "keyboard", "scroll"} or fields["applied"] != "1":
            _fail(f"line {line} has an invalid applied input effect")
    elif name == "p2pSessionAuthenticated":
        if (
            fields["transport"] != "p2p"
            or fields["role"] not in {"initiator", "responder"}
            or fields["suite"] != "X-Wing"
            or fields["result"] != "authenticated"
        ):
            _fail(f"line {line} P2P peer session is not authenticated with X-Wing")
    elif name == "webrtcPQCRekeyAuthenticated":
        if fields["transport"] != "webrtc" or fields["suite"] != "X-Wing" \
                or fields["result"] != "authenticated":
            _fail(f"line {line} WebRTC session has no authenticated X-Wing rekey")
    elif name == "webrtcMediaSample":
        if fields["transport"] != "webrtc" or fields["result"] != "flowing" \
                or fields["mediaRole"] not in {"sender", "receiver"}:
            _fail(f"line {line} WebRTC media sample is not a flowing product sample")
        _positive_integer(fields["sample_seq"], f"line {line} sample_seq")
        for key in ("video_frames", "video_bytes", "audio_units", "audio_bytes"):
            _positive_integer(fields[key], f"line {line} {key}")
        if re.fullmatch(r"(?:0|[1-9][0-9]*)", fields["elapsed_ms"], re.ASCII) is None \
                or int(fields["elapsed_ms"]) > UINT64_MAX:
            _fail(f"line {line} elapsed_ms must be a UInt64 decimal integer")
    elif name.startswith("connectivity"):
        _validate_connectivity_event_values(event)
    elif name in {"fileTransferStarted", "fileTransferCompleted"}:
        if REFERENCE_PATTERN.fullmatch(fields["transfer_ref"]) is None:
            _fail(f"line {line} has an invalid transfer_ref")
        if name == "fileTransferStarted":
            expected_interaction = {
                "send": "send-ui",
                "receive": "accept-ui",
            }.get(fields["direction"])
            if expected_interaction is None \
                    or fields["interaction"] != expected_interaction \
                    or fields["result"] != "started":
                _fail(f"line {line} has an invalid file-transfer start")
            if fields["payload"] != "nonempty":
                _fail(f"line {line} file-transfer payload must be nonempty")
        else:
            if (
                fields["direction"] not in {"send", "receive"}
                or fields["interaction"]
                != {"send": "send-ui", "receive": "accept-ui"}[fields["direction"]]
                or fields["payload"] != "nonempty"
                or fields["integrity"] != "verified"
                or fields["receipt"] != "authenticated"
                or fields["result"] != "success"
                or fields["uiEffect"] != "completed"
            ):
                _fail(f"line {line} file transfer did not complete in the product UI")
    elif name == "releaseSessionDisconnected":
        expected_notice_hidden = (
            {"not-applicable"}
            if fields["owner"] == IOS_PRODUCT
            else {"1", "not-applicable"}
        )
        if (
            fields["noticeHidden"] not in expected_notice_hidden
            or fields["reason"]
            not in {"user", "peer", "trust-invalidated", "session-replaced", "protocol-failure"}
            or fields["result"] != "disconnected"
        ):
            _fail(f"line {line} has an invalid disconnect result")


def _suite_family(suite: str) -> str | None:
    if suite == "X-Wing":
        return "xwing"
    if suite in PQC_SUITES:
        return "pqc"
    if suite in CLASSIC_SUITES:
        return "classic"
    return None


def _validate_connectivity_event_values(event: Event) -> None:
    fields = event.fields
    line = event.line_number
    if fields["transport"] != "p2p":
        _fail(f"line {line} connectivity evidence must use p2p")
    if fields["role"] not in {"initiator", "responder"}:
        _fail(f"line {line} connectivity role is invalid")
    local_profile = fields["localProfile"]
    offered_families = OFFERED_PROFILE_FAMILIES.get(fields["offeredProfiles"])
    if (
        local_profile not in {"xwing", "pqc"}
        or offered_families is None
        or local_profile not in offered_families
        or fields["requirePQC"] != "1"
        or fields["allowClassicFallback"] != "0"
    ):
        _fail(f"line {line} connectivity local offer/policy is not strict and consistent")

    if event.name == "connectivityAttemptStarted":
        if fields["result"] != "started":
            _fail(f"line {line} connectivity attempt did not start")
    elif event.name == "connectivityAttemptAuthenticated":
        if (
            fields["attemptProfile"] not in {"xwing", "pqc"}
            or fields["result"] != "authenticated"
        ):
            _fail(f"line {line} connectivity authentication terminal is invalid")
    elif event.name == "connectivityEndpoint":
        suite_family = _suite_family(fields["suite"])
        if (
            suite_family not in {"xwing", "pqc"}
            or fields["attemptProfile"] != suite_family
            or fields["result"] != "success"
        ):
            _fail(f"line {line} connectivity endpoint suite/result is invalid")
    elif event.name == "connectivityPolicyRejected":
        if (
            fields["role"] != "responder"
            or fields["peerOfferedProfiles"] != "classic"
            or fields["peerOfferSignature"] != "verified"
            or fields["reason"] != "strict-pqc-rejects-classic"
            or fields["result"] != "rejected"
        ):
            _fail(f"line {line} connectivity policy rejection is not the signed classic case")
    elif event.name == "connectivityAttemptFailed":
        if fields["reason"] not in {
            "handshake-failed",
            "transport-closed",
            "cancelled",
            "superseded",
            "publication-failed",
        } or fields["result"] != "failed":
            _fail(f"line {line} connectivity failure terminal is invalid")


def _sessions(events: list[Event]) -> dict[tuple[str, str, str, int], Session]:
    sessions: dict[tuple[str, str, str, int], Session] = {}
    owner_generations: set[int] = set()
    for event in events:
        _validate_event_values(event)
        if event.name == "releaseSessionOwner":
            if event.key in sessions or event.key[3] in owner_generations:
                _fail(f"line {event.line_number} duplicates a session owner generation")
            sessions[event.key] = Session(owner=event, events=[event])
            owner_generations.add(event.key[3])
            continue
        session = sessions.get(event.key)
        if session is None:
            _fail(f"line {event.line_number} has no exact active session owner")
        if session.disconnected:
            _fail(f"line {event.line_number} occurs after session disconnect")
        session.events.append(event)
        if len(session.events) > MAX_EVENT_COUNT_PER_SESSION:
            _fail(
                f"session exceeds the fixed {MAX_EVENT_COUNT_PER_SESSION}-event product limit"
            )
        if event.name == "releaseSessionDisconnected":
            session.disconnected = True
    if any(not session.disconnected for session in sessions.values()):
        _fail("every product evidence session must have a terminal disconnect")
    return sessions


def _event_names(session: Session) -> list[str]:
    return [event.name for event in session.events]


def _validate_remote_session(session: Session, transport: str) -> Session:
    if session.owner.fields["transport"] != transport:
        _fail(f"remote-control evidence must be owned by {transport}")
    if transport == "webrtc" and session.owner.fields["selectedTransport"] != "relay":
        _fail("formal WebRTC evidence must use the selected relay transport")
    names = _event_names(session)
    required_once = (
        "releaseSessionOwner",
        *(('p2pSessionAuthenticated',) if transport == "p2p" else ()),
        "remoteControlNoticeShown",
        "remoteControlNoticePanelPresented",
        "remoteControlNoticeHumanApproved",
        "remoteControlNoticeApproved",
        "remoteControlNoticeActive",
        "secureFrameAccepted",
        "remoteControlNoticeDisconnected",
        "remoteControlNoticePanelHidden",
        "releaseSessionDisconnected",
    )
    for name in required_once:
        if names.count(name) != 1:
            _fail(f"remote-control evidence requires exactly one {name}")
    if not any(name == "remoteInputApplied" for name in names):
        _fail("remote-control evidence requires an applied product input effect")
    ordered = [names.index(name) for name in required_once]
    if ordered != sorted(ordered):
        _fail("remote-control product events are not in the required lifecycle order")
    active_index = names.index("remoteControlNoticeActive")
    terminal_index = names.index("remoteControlNoticeDisconnected")
    indexed_effect_events = [
        (index, event)
        for index, event in enumerate(session.events)
        if event.name in {"secureFrameAccepted", "localFramePresented", "remoteInputApplied"}
    ]
    if any(
        not (active_index < index < terminal_index)
        for index, _ in indexed_effect_events
    ):
        _fail("remote-control effects must occur while the approved notice is active")
    effect_events = [event for _, event in indexed_effect_events]
    if names.count("localFramePresented") > 1:
        _fail("remote-control evidence permits at most one localFramePresented event")
    input_effects = [
        event.fields["effect"]
        for event in effect_events
        if event.name == "remoteInputApplied"
    ]
    if len(input_effects) != len(set(input_effects)):
        _fail("remote-control evidence duplicates a bounded input effect")
    formal_sequences = [
        int(
            event.fields["frame_seq"]
            if event.name == "secureFrameAccepted"
            else event.fields["event_seq"]
        )
        for event in effect_events
        if event.name != "localFramePresented"
    ]
    if formal_sequences != sorted(set(formal_sequences)):
        _fail("frame_seq/event_seq must be unique and strictly increasing")
    local_sequences = [
        int(event.fields["local_frame_seq"])
        for event in effect_events
        if event.name == "localFramePresented"
    ]
    if local_sequences != sorted(set(local_sequences)):
        _fail("local_frame_seq must be unique and strictly increasing")
    disconnected = session.events[-1]
    if disconnected.name != "releaseSessionDisconnected" or disconnected.fields["noticeHidden"] != "1":
        _fail("remote-control disconnect must be final and prove the notice is hidden")
    forbidden = {
        "remoteControlNoticeRejected",
        "remoteControlNoticeTimedOut",
        "connectivityAttemptStarted",
        "connectivityAttemptAuthenticated",
        "connectivityEndpoint",
        "connectivityPolicyRejected",
        "connectivityAttemptFailed",
        "fileTransferStarted",
        "fileTransferCompleted",
    }
    if transport == "p2p":
        forbidden.update({"webrtcPQCRekeyAuthenticated", "webrtcMediaSample"})
    if forbidden.intersection(names):
        _fail("remote-control success evidence contains an incompatible event")
    return session


def _validate_peer_session(session: Session, *, transport: str) -> Session:
    if session.owner.fields["transport"] != transport:
        _fail(f"paired iOS evidence must use {transport}")
    if transport == "webrtc" and session.owner.fields["selectedTransport"] != "relay":
        _fail("paired iOS WebRTC evidence must use the selected relay transport")
    return session


def _require_matching_session_reference(mac: Session, ios: Session, label: str) -> None:
    if mac.owner.fields["session_ref"] != ios.owner.fields["session_ref"]:
        _fail(f"paired Mac/iOS {label} evidence uses different authenticated sessions")


def _validate_simple_p2p_session(session: Session) -> None:
    _validate_peer_session(session, transport="p2p")
    if _event_names(session) != [
        "releaseSessionOwner",
        "p2pSessionAuthenticated",
        "releaseSessionDisconnected",
    ]:
        _fail("P2P evidence has an invalid authenticated peer lifecycle")
    if session.events[-1].fields["noticeHidden"] != "not-applicable":
        _fail("P2P peer-only disconnect cannot claim a hidden notice")


def _sessions_by_reference(sessions: dict[tuple[str, str, str, int], Session]) \
        -> dict[str, Session]:
    by_reference: dict[str, Session] = {}
    for session in sessions.values():
        reference = session.owner.fields["session_ref"]
        if reference in by_reference:
            _fail("one endpoint duplicates a product session reference")
        by_reference[reference] = session
    return by_reference


def _validate_p2p_pair(
    mac_sessions: dict[tuple[str, str, str, int], Session],
    ios_events: list[Event],
) -> None:
    ios_sessions = _sessions(ios_events)
    if len(mac_sessions) != 2 or len(ios_sessions) != 2:
        _fail("P2P evidence requires exactly two bidirectional product sessions")
    mac_by_reference = _sessions_by_reference(mac_sessions)
    ios_by_reference = _sessions_by_reference(ios_sessions)
    if set(mac_by_reference) != set(ios_by_reference):
        _fail("paired P2P endpoints do not contain the same two authenticated sessions")

    observed_roles: set[tuple[str, str]] = set()
    full_remote_count = 0
    for reference in sorted(mac_by_reference):
        mac_session = mac_by_reference[reference]
        ios_session = ios_by_reference[reference]
        _validate_peer_session(mac_session, transport="p2p")
        _validate_peer_session(ios_session, transport="p2p")
        mac_auth = [
            event for event in mac_session.events if event.name == "p2pSessionAuthenticated"
        ]
        ios_auth = [
            event for event in ios_session.events if event.name == "p2pSessionAuthenticated"
        ]
        if len(mac_auth) != 1 or len(ios_auth) != 1:
            _fail("each P2P endpoint session requires one authenticated lifecycle event")
        roles = (mac_auth[0].fields["role"], ios_auth[0].fields["role"])
        if set(roles) != {"initiator", "responder"}:
            _fail("paired P2P endpoint roles must be complementary")
        observed_roles.add(roles)
        mac_names = _event_names(mac_session)
        if "remoteControlNoticeShown" in mac_names:
            if roles != ("responder", "initiator"):
                _fail("the full Mac-host P2P lifecycle must be iOS initiated")
            _validate_remote_session(mac_session, "p2p")
            _validate_simple_p2p_session(ios_session)
            full_remote_count += 1
        else:
            _validate_simple_p2p_session(mac_session)
            _validate_simple_p2p_session(ios_session)
    if observed_roles != {("responder", "initiator"), ("initiator", "responder")} \
            or full_remote_count != 1:
        _fail("P2P evidence does not prove both directional authenticated lifecycles")


def _webrtc_media_window(session: Session, expected_role: str) -> None:
    samples = [event for event in session.events if event.name == "webrtcMediaSample"]
    if len(samples) < 2 or len(samples) > 4:
        _fail("WebRTC product evidence requires two to four bounded media samples")
    if any(event.fields["mediaRole"] != expected_role for event in samples):
        _fail(f"WebRTC product evidence requires {expected_role} media samples")
    sequence = [int(event.fields["sample_seq"]) for event in samples]
    elapsed = [int(event.fields["elapsed_ms"]) for event in samples]
    if sequence != list(range(1, len(samples) + 1)):
        _fail("WebRTC media sample_seq must be contiguous from one")
    if (
        elapsed != sorted(set(elapsed))
        or elapsed[0] > 5_000
        or elapsed[-1] > 120_000
        or elapsed[-1] - elapsed[0] < 30_000
    ):
        _fail("WebRTC media evidence does not span the required 30-second soak")
    for key in ("video_frames", "video_bytes", "audio_units", "audio_bytes"):
        counters = [int(event.fields[key]) for event in samples]
        if any(later <= earlier for earlier, later in zip(counters, counters[1:])):
            _fail(f"WebRTC media evidence {key} did not increase through the soak")


def _validate_webrtc_pair(mac_session: Session, ios_events: list[Event]) -> None:
    ios_sessions = _sessions(ios_events)
    if len(ios_sessions) != 1:
        _fail("paired iOS WebRTC evidence must contain one isolated product session")
    ios_session = next(iter(ios_sessions.values()))
    _validate_peer_session(ios_session, transport="webrtc")
    _require_matching_session_reference(mac_session, ios_session, "WebRTC")
    for session, role in ((mac_session, "sender"), (ios_session, "receiver")):
        names = _event_names(session)
        if names.count("webrtcPQCRekeyAuthenticated") != 1:
            _fail("WebRTC product evidence requires one authenticated X-Wing rekey per endpoint")
        rekey_index = names.index("webrtcPQCRekeyAuthenticated")
        sample_indices = [
            index for index, name in enumerate(names) if name == "webrtcMediaSample"
        ]
        if not sample_indices or rekey_index >= sample_indices[0] \
                or sample_indices[-1] >= names.index("releaseSessionDisconnected"):
            _fail("WebRTC media soak must follow rekey and precede disconnect")
        _webrtc_media_window(session, role)


def _file_transfer_observation(session: Session) -> tuple[Event, Event]:
    names = _event_names(session)
    if names != [
        "releaseSessionOwner",
        "p2pSessionAuthenticated",
        "fileTransferStarted",
        "fileTransferCompleted",
        "releaseSessionDisconnected",
    ]:
        _fail("file-transfer product evidence has an invalid ordered lifecycle")
    if session.events[-1].fields["noticeHidden"] != "not-applicable":
        _fail("file-transfer disconnect cannot claim a hidden remote-control notice")
    started = session.events[2]
    completed = session.events[3]
    for key in ("transfer_ref", "direction", "interaction", "payload"):
        if completed.fields[key] != started.fields[key]:
            _fail(f"file-transfer completion does not match its start field {key}")
    return started, completed


def _connectivity_attempts(
    events: list[Event], expected_owner: str
) -> dict[str, ConnectivityAttempt]:
    grouped: dict[str, list[Event]] = {}
    generation_to_attempt: dict[int, str] = {}
    for event in events:
        if not event.name.startswith("connectivity"):
            _fail(
                f"line {event.line_number} is not a canonical connectivity product event"
            )
        _validate_event_values(event)
        attempt_reference = event.fields["attempt_ref"]
        generation = int(event.fields["generation"])
        previous_attempt = generation_to_attempt.setdefault(generation, attempt_reference)
        if previous_attempt != attempt_reference:
            _fail(f"{expected_owner} reuses one local generation across attempts")
        grouped.setdefault(attempt_reference, []).append(event)

    attempts: dict[str, ConnectivityAttempt] = {}
    for attempt_reference, attempt_events in grouped.items():
        if len(attempt_events) > MAX_EVENT_COUNT_PER_SESSION:
            _fail(
                f"connectivity attempt exceeds the fixed {MAX_EVENT_COUNT_PER_SESSION}-event product limit"
            )
        first = attempt_events[0]
        generation = int(first.fields["generation"])
        for event in attempt_events[1:]:
            for key in CONNECTIVITY_OWNER_FIELDS:
                if event.fields[key] != first.fields[key]:
                    _fail(
                        f"{expected_owner} connectivity attempt changes local field {key}"
                    )
        attempt = ConnectivityAttempt(
            owner=expected_owner,
            attempt_reference=attempt_reference,
            generation=generation,
            events=tuple(attempt_events),
        )
        if not attempt.is_success and not attempt.is_expected_rejection:
            _fail(
                f"{expected_owner} connectivity attempt has an invalid or failed lifecycle"
            )
        if attempt.is_success:
            authenticated = attempt.events[1]
            endpoint = attempt.events[2]
            if (
                authenticated.fields["session_ref"] != endpoint.fields["session_ref"]
                or authenticated.fields["attemptProfile"]
                != endpoint.fields["attemptProfile"]
            ):
                _fail(
                    f"{expected_owner} connectivity endpoint does not match its authenticated terminal"
                )
            suite_family = _suite_family(endpoint.fields["suite"])
            offered_families = OFFERED_PROFILE_FAMILIES[
                endpoint.fields["offeredProfiles"]
            ]
            if suite_family not in offered_families:
                _fail(
                    f"{expected_owner} negotiated suite family was absent from its actual offer"
                )
        attempts[attempt_reference] = attempt
    return attempts


def _validate_connectivity(
    mac_events: list[Event], ios_events: list[Event]
) -> None:
    mac_attempts = _connectivity_attempts(mac_events, MAC_PRODUCT)
    ios_attempts = _connectivity_attempts(ios_events, IOS_PRODUCT)
    all_references = set(mac_attempts) | set(ios_attempts)
    success_profiles: set[tuple[str, str]] = set()
    success_sessions: set[str] = set()
    rejection_owners: list[str] = []

    for attempt_reference in all_references:
        mac_attempt = mac_attempts.get(attempt_reference)
        ios_attempt = ios_attempts.get(attempt_reference)
        has_success = any(
            attempt is not None and attempt.is_success
            for attempt in (mac_attempt, ios_attempt)
        )
        if has_success:
            if (
                mac_attempt is None
                or ios_attempt is None
                or not mac_attempt.is_success
                or not ios_attempt.is_success
            ):
                _fail("successful connectivity attempts require exact Mac and iOS product endpoints")
            mac_authenticated, mac_endpoint = mac_attempt.events[1:]
            ios_authenticated, ios_endpoint = ios_attempt.events[1:]
            if mac_endpoint.fields["role"] == ios_endpoint.fields["role"]:
                _fail("successful connectivity endpoints must have complementary roles")
            joined_values = (
                (mac_authenticated.fields["session_ref"], ios_authenticated.fields["session_ref"]),
                (mac_endpoint.fields["session_ref"], ios_endpoint.fields["session_ref"]),
                (mac_endpoint.fields["suite"], ios_endpoint.fields["suite"]),
                (mac_endpoint.fields["attemptProfile"], ios_endpoint.fields["attemptProfile"]),
            )
            if any(left != right for left, right in joined_values):
                _fail(
                    "successful connectivity endpoints disagree on session, suite, or attempt profile"
                )
            session_reference = mac_endpoint.fields["session_ref"]
            if session_reference in success_sessions:
                _fail("successful connectivity pairs must use distinct authenticated sessions")
            success_sessions.add(session_reference)
            profile_pair = (
                mac_endpoint.fields["localProfile"],
                ios_endpoint.fields["localProfile"],
            )
            if profile_pair in success_profiles:
                _fail("connectivity evidence duplicates a successful Mac/iOS profile pair")
            success_profiles.add(profile_pair)
            continue

        rejection_attempts = [
            attempt
            for attempt in (mac_attempt, ios_attempt)
            if attempt is not None
        ]
        if len(rejection_attempts) != 1 or not rejection_attempts[0].is_expected_rejection:
            _fail(
                "expected classic rejection must be one shipping responder started/rejected pair"
            )
        rejection_owners.append(rejection_attempts[0].owner)

    if success_profiles != CONNECTIVITY_SUCCESS_PROFILES:
        _fail("connectivity evidence does not cover the exact three success profile pairs")
    if sorted(rejection_owners) != sorted(PRODUCTS):
        _fail("connectivity evidence requires one signed classic rejection per shipping responder")


def _validate_file_transfer(
    sessions: dict[tuple[str, str, str, int], Session]
) -> dict[str, tuple[Session, Event, Event]]:
    if len(sessions) != 2:
        _fail("file-transfer evidence must contain exactly two transfer owners")
    observations: dict[str, tuple[Session, Event, Event]] = {}
    session_references: set[str] = set()
    for session in sessions.values():
        _validate_peer_session(session, transport="p2p")
        started, completed = _file_transfer_observation(session)
        reference = started.fields["transfer_ref"]
        if reference in observations:
            _fail("file-transfer evidence reuses one transfer reference")
        observations[reference] = (session, started, completed)
        session_references.add(session.owner.fields["session_ref"])
    if len(session_references) != 1:
        _fail("two file transfers must share one authenticated P2P session reference")
    if {started.fields["direction"] for _, started, _ in observations.values()} \
            != {"send", "receive"}:
        _fail("each product must complete one send and one receive UI transfer")
    return observations


def validate_events(
    events: list[Event], kind: str, *, ios_events: list[Event] | None = None
) -> None:
    if kind == "connectivity":
        if ios_events is None:
            _fail("connectivity evidence requires paired Mac and iOS product logs")
        _validate_connectivity(events, ios_events)
        return

    sessions = _sessions(events)
    if not sessions:
        _fail("product release evidence contains no session owner")
    if ios_events is None:
        _fail(f"{kind} evidence requires paired Mac and iOS product logs")
    if kind == "p2p":
        _validate_p2p_pair(sessions, ios_events)
    elif kind == "webrtc":
        if len(sessions) != 1:
            _fail("WebRTC evidence must contain one isolated product session")
        mac_session = _validate_remote_session(next(iter(sessions.values())), "webrtc")
        _validate_webrtc_pair(mac_session, ios_events)
    elif kind == "file-transfer":
        mac_observations = _validate_file_transfer(sessions)
        ios_observations = _validate_file_transfer(_sessions(ios_events))
        if set(mac_observations) != set(ios_observations):
            _fail("paired file-transfer endpoints do not contain the same transfers")
        for reference in mac_observations:
            mac_session, mac_started, _ = mac_observations[reference]
            ios_session, ios_started, _ = ios_observations[reference]
            if (
                mac_session.owner.fields["session_ref"]
                != ios_session.owner.fields["session_ref"]
                or {mac_started.fields["direction"], ios_started.fields["direction"]}
                != {"send", "receive"}
            ):
                _fail("paired file-transfer directions are not complementary")
    else:
        _fail(f"unsupported evidence kind: {kind}")


def validate_capture_manifest(
    path: Path, event_count: int, *, expected_owner: str = MAC_PRODUCT
) -> dict[str, Any]:
    content = _read_regular_file(path, "product evidence capture manifest", 64 * 1024)
    try:
        payload = json.loads(content.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(f"product evidence capture manifest is invalid JSON: {exc}")
    expected_keys = {
        "schemaVersion",
        "profile",
        "captureMode",
        "processID",
        "processExecutable",
        "startTimeToken",
        "ownershipVerified",
        "candidateIdentityVerified",
        "candidateIdentityFile",
        "subsystem",
        "category",
        "eventCount",
    }
    if expected_owner == IOS_PRODUCT:
        expected_keys |= {
            "bundleIdentifier",
            "iosReleaseArchive",
            "platform",
            "releaseArchiveBindingVerified",
        }
    if not isinstance(payload, dict) or set(payload) != expected_keys:
        _fail("product evidence capture manifest has an unexpected schema")
    expected_values = {
        "schemaVersion": 1,
        "profile": CAPTURE_PROFILE,
        "captureMode": CAPTURE_MODE if expected_owner == MAC_PRODUCT else IOS_CAPTURE_MODE,
        "processExecutable": PRODUCT_EXECUTABLES[expected_owner],
        "ownershipVerified": True,
        "candidateIdentityVerified": True,
        "candidateIdentityFile": PRODUCT_LOG_CONTRACTS[expected_owner][2],
        "subsystem": SUBSYSTEM,
        "category": CATEGORY,
        "eventCount": event_count,
    }
    if expected_owner == IOS_PRODUCT:
        expected_values |= {
            "bundleIdentifier": "com.skybridge.compass.ios",
            "platform": "ios",
            "releaseArchiveBindingVerified": True,
        }
    for key, expected in expected_values.items():
        if payload.get(key) != expected:
            _fail(f"product evidence capture manifest {key} mismatch")
    if expected_owner == IOS_PRODUCT:
        try:
            validate_archive_binding(payload.get("iosReleaseArchive"))
        except PhysicalAcceptanceError as exc:
            _fail(f"iOS product capture archive binding is invalid: {exc}")
    process_id = payload.get("processID")
    if isinstance(process_id, bool) or not isinstance(process_id, int) or process_id <= 1:
        _fail("product evidence capture manifest processID must be greater than one")
    start_time_token = payload.get("startTimeToken")
    match = (
        re.fullmatch(r"[1-9][0-9]*:[0-9]+", start_time_token, re.ASCII)
        if isinstance(start_time_token, str)
        else None
    )
    if match is None or int(start_time_token.split(":", 1)[1]) >= 1_000_000:
        _fail("product evidence capture manifest startTimeToken is invalid")
    canonical = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    if content != canonical:
        _fail("product evidence capture manifest must be canonical JSON")
    return payload


def validate_artifact_log(artifact_dir: Path, kind: str) -> None:
    mac_events = parse_canonical_log(
        artifact_dir / MAC_LOG_FILE, expected_owner=MAC_PRODUCT
    )
    validate_capture_manifest(
        artifact_dir / MAC_CAPTURE_FILE,
        len(mac_events),
        expected_owner=MAC_PRODUCT,
    )
    if kind != "connectivity":
        mac_sessions = _sessions(mac_events)
        if kind == "p2p":
            if len(mac_sessions) != 2:
                _fail("P2P evidence requires exactly two bidirectional product sessions")
            full = [
                session
                for session in mac_sessions.values()
                if "remoteControlNoticeShown" in _event_names(session)
            ]
            simple = [session for session in mac_sessions.values() if session not in full]
            if len(full) != 1 or len(simple) != 1:
                _fail("P2P Mac evidence requires one full and one reverse lifecycle")
            _validate_remote_session(full[0], "p2p")
            _validate_simple_p2p_session(simple[0])
        elif kind == "webrtc":
            if len(mac_sessions) != 1:
                _fail("WebRTC evidence must contain one isolated product session")
            mac_session = _validate_remote_session(
                next(iter(mac_sessions.values())), "webrtc"
            )
            if _event_names(mac_session).count("webrtcPQCRekeyAuthenticated") != 1:
                _fail("WebRTC Mac evidence requires one authenticated X-Wing rekey")
            _webrtc_media_window(mac_session, "sender")
        elif kind == "file-transfer":
            _validate_file_transfer(mac_sessions)
        else:
            _fail(f"unsupported evidence kind: {kind}")
    ios_events = parse_canonical_log(
        artifact_dir / IOS_LOG_FILE, expected_owner=IOS_PRODUCT
    )
    validate_capture_manifest(
        artifact_dir / IOS_CAPTURE_FILE,
        len(ios_events),
        expected_owner=IOS_PRODUCT,
    )
    validate_events(mac_events, kind, ios_events=ios_events)


def validate_capture(artifact_dir: Path) -> None:
    """Validate the public schema and exact owner lifecycle before redaction bypass."""

    events = parse_canonical_log(
        artifact_dir / MAC_LOG_FILE, expected_owner=MAC_PRODUCT
    )
    validate_capture_manifest(
        artifact_dir / MAC_CAPTURE_FILE,
        len(events),
        expected_owner=MAC_PRODUCT,
    )
    if events and all(event.name.startswith("connectivity") for event in events):
        kind = "connectivity"
    elif any(event.name == "fileTransferStarted" for event in events):
        kind = "file-transfer"
    elif any(event.fields.get("transport") == "webrtc" for event in events):
        kind = "webrtc"
    else:
        kind = "p2p"
    validate_artifact_log(artifact_dir, kind)


def _write_new_file(path: Path, content: bytes) -> None:
    if path.exists() or path.is_symlink():
        _fail(f"output already exists: {path}")
    parent = path.parent.resolve(strict=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary.exists():
            temporary.unlink()


def _read_private_ownership_record(
    path: Path, expected_pid: int, expected_process_image_path: Path
) -> str:
    try:
        parent_metadata = path.parent.lstat()
    except OSError as exc:
        _fail(f"private ownership directory is unavailable: {exc}")
    if (
        path.parent.is_symlink()
        or not stat.S_ISDIR(parent_metadata.st_mode)
        or parent_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(parent_metadata.st_mode) != 0o700
    ):
        _fail("private ownership directory must be current-user mode 0700")
    try:
        record_metadata = path.lstat()
    except OSError as exc:
        _fail(f"private ownership record is unavailable: {exc}")
    if (
        path.is_symlink()
        or not stat.S_ISREG(record_metadata.st_mode)
        or record_metadata.st_uid != os.geteuid()
        or record_metadata.st_nlink != 1
        or stat.S_IMODE(record_metadata.st_mode) != 0o600
    ):
        _fail("private ownership record must be current-user mode 0600 with one link")
    content = _read_regular_file(path, "private ownership record", 16 * 1024)
    try:
        payload = json.loads(content.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(f"private ownership record is invalid JSON: {exc}")
    expected_keys = {
        "auditToken",
        "executablePath",
        "platform",
        "processIdentifier",
        "schemaVersion",
        "startTimeToken",
    }
    if not isinstance(payload, dict) or set(payload) != expected_keys:
        _fail("private ownership record has an unexpected schema")
    expected_image = os.path.realpath(expected_process_image_path)
    if (
        payload.get("schemaVersion") != 1
        or payload.get("platform") != "macos"
        or payload.get("processIdentifier") != expected_pid
        or payload.get("executablePath") != expected_image
    ):
        _fail("private ownership record does not bind the expected candidate process")
    audit_token = payload.get("auditToken")
    if (
        not isinstance(audit_token, list)
        or len(audit_token) != 8
        or any(
            isinstance(word, bool)
            or not isinstance(word, int)
            or word < 0
            or word > 0xFFFFFFFF
            for word in audit_token
        )
        or audit_token[5] != expected_pid
    ):
        _fail("private ownership record has an invalid audit token")
    start_time_token = payload.get("startTimeToken")
    match = (
        re.fullmatch(r"[1-9][0-9]*:[0-9]+", start_time_token, re.ASCII)
        if isinstance(start_time_token, str)
        else None
    )
    if match is None or int(start_time_token.split(":", 1)[1]) >= 1_000_000:
        _fail("private ownership record has an invalid start-time token")
    return start_time_token


def extract_oslog(
    input_path: Path,
    expected_pid: int,
    expected_process_image_path: Path,
    ownership_record_path: Path,
    output_path: Path,
    capture_output_path: Path,
) -> None:
    if expected_pid <= 1:
        _fail("expected PID must be greater than one")
    expected_image = expected_process_image_path.resolve(strict=True)
    if not expected_image.is_file() or expected_image.is_symlink():
        _fail("expected process image path must be a real file")
    start_time_token = _read_private_ownership_record(
        ownership_record_path, expected_pid, expected_image
    )
    content = _read_regular_file(input_path, "raw OSLog NDJSON", MAX_INPUT_BYTES)
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as exc:
        _fail(f"raw OSLog NDJSON is not UTF-8: {exc}")
    messages: list[str] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line:
            _fail(f"raw OSLog line {line_number} is empty")
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            _fail(f"raw OSLog line {line_number} is invalid JSON: {exc}")
        if not isinstance(row, dict):
            _fail(f"raw OSLog line {line_number} is not an object")
        if (
            row.get("eventType") != "logEvent"
            or row.get("messageType") != "Default"
            or row.get("subsystem") != SUBSYSTEM
            or row.get("category") != CATEGORY
            or row.get("processID") != expected_pid
        ):
            _fail(f"raw OSLog line {line_number} is outside the exact capture boundary")
        image_path = row.get("processImagePath")
        if not isinstance(image_path, str) or Path(image_path).resolve(strict=True) != expected_image:
            _fail(f"raw OSLog line {line_number} is from a different process image")
        format_string = row.get("formatString")
        if not isinstance(format_string, str) or "public" not in format_string:
            _fail(f"raw OSLog line {line_number} was not emitted as public data")
        message = row.get("eventMessage")
        if not isinstance(message, str):
            _fail(f"raw OSLog line {line_number} has no eventMessage")
        _parse_event_line(message, line_number)
        messages.append(message)
    if not messages or len(messages) > MAX_EVENT_COUNT:
        _fail(f"raw OSLog event count must be 1-{MAX_EVENT_COUNT}")
    canonical_log = ("\n".join(messages) + "\n").encode("ascii")
    capture = {
        "schemaVersion": 1,
        "profile": CAPTURE_PROFILE,
        "captureMode": CAPTURE_MODE,
        "processID": expected_pid,
        "processExecutable": expected_image.name,
        "startTimeToken": start_time_token,
        "ownershipVerified": True,
        "candidateIdentityVerified": True,
        "candidateIdentityFile": "macos-release-candidate.json",
        "subsystem": SUBSYSTEM,
        "category": CATEGORY,
        "eventCount": len(messages),
    }
    capture_bytes = (json.dumps(capture, indent=2, sort_keys=True) + "\n").encode("utf-8")
    _write_new_file(output_path, canonical_log)
    try:
        _write_new_file(capture_output_path, capture_bytes)
    except BaseException:
        output_path.unlink(missing_ok=True)
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    extract = subparsers.add_parser("extract-oslog")
    extract.add_argument("--input", type=Path, required=True)
    extract.add_argument("--expected-pid", type=int, required=True)
    extract.add_argument("--expected-process-image-path", type=Path, required=True)
    extract.add_argument("--ownership-record", type=Path, required=True)
    extract.add_argument("--output", type=Path, required=True)
    extract.add_argument("--capture-output", type=Path, required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument(
        "--kind", choices=("connectivity", "p2p", "webrtc", "file-transfer"), required=True
    )
    validate.add_argument("--artifact-dir", type=Path, required=True)
    validate_capture_parser = subparsers.add_parser("validate-capture")
    validate_capture_parser.add_argument("--artifact-dir", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "extract-oslog":
            extract_oslog(
                args.input,
                args.expected_pid,
                args.expected_process_image_path,
                args.ownership_record,
                args.output,
                args.capture_output,
            )
            print(f"product release OSLog extracted: {args.output}")
        elif args.command == "validate":
            validate_artifact_log(args.artifact_dir, args.kind)
            print(f"product release evidence log valid: kind={args.kind}")
        else:
            validate_capture(args.artifact_dir)
            print("product release evidence capture valid")
    except (OSError, ProductEvidenceError) as exc:
        print(f"product release evidence rejected: {exc}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
