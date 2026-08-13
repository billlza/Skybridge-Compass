#!/usr/bin/env python3
"""Validate one source-bound Android-to-macOS formal WebRTC transaction.

SHA-256 values in this evidence are Level-1 reliability bindings. They detect
accidental source, artifact, device, or run mismatch; they are not signatures
and do not protect against a malicious process running as the same host user.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
import re
import stat
import sys
import time
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, NoReturn


MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_TEXT_BYTES = 8 * 1024 * 1024
MAX_PRIVATE_BYTES = 64 * 1024
MAX_ARTIFACT_BYTES = 2 * 1024 * 1024 * 1024
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z", re.ASCII)
SOURCE_COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}\Z", re.ASCII)
EXPECTED_APP_PACKAGE = "com.skybridge.compass.debug"
EXPECTED_TEST_PACKAGE = "com.skybridge.compass.debug.macwebrtc.test"
EXPECTED_TEST_CLASS = (
    "com.skybridge.compass.android.webrtc."
    "AppleReleaseInteropOffererAppInstrumentationTest"
)
EXPECTED_TEST_METHOD = "hostsCodeForAppleResponderUsingAppProcess"
EXPECTED_SUITE = "ML-KEM-768"
EXPECTED_ANDROID_SUITE = "MLKEM_768/0x0101"
EXPECTED_SUITE_WIRE_ID = "0x0101"
AUTOMATIC_START_ACTIONS = {
    "android.intent.action.MY_PACKAGE_REPLACED",
    "android.intent.action.PACKAGE_ADDED",
    "android.intent.action.PACKAGE_CHANGED",
    "android.intent.action.PACKAGE_REPLACED",
}
ANDROID_XML_NAME = "{http://schemas.android.com/apk/res/android}name"


class FormalEvidenceError(RuntimeError):
    """The formal transaction is incomplete, ambiguous, or mismatched."""


def _fail(message: str) -> NoReturn:
    raise FormalEvidenceError(message)


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            _fail(f"JSON object contains duplicate key: {key}")
        value[key] = item
    return value


def _private_parent(path: Path) -> Path:
    path_text = str(path)
    if (
        not path.is_absolute()
        or path.name in {"", ".", ".."}
        or any(character in path_text for character in ("\x00", "\n", "\r"))
    ):
        _fail("private artifact path must be an absolute file path")
    try:
        parent = path.parent.resolve(strict=True)
        metadata = parent.lstat()
    except OSError as exc:
        _fail(f"private artifact parent is unavailable: {type(exc).__name__}")
    if (
        path.parent != parent
        or parent.is_symlink()
        or not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        _fail("private artifact parent must be a canonical current-user 0700 directory")
    return parent


def _read_descriptor_stably(
    descriptor: int,
    label: str,
    maximum_bytes: int,
    *,
    private: bool,
    allow_empty: bool = False,
) -> tuple[bytes, os.stat_result]:
    before = os.fstat(descriptor)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or (before.st_size < 1 and not allow_empty)
        or before.st_size > maximum_bytes
        or (private and (before.st_uid != os.geteuid() or stat.S_IMODE(before.st_mode) != 0o600))
    ):
        _fail(f"{label} must be a bounded single-link regular file")
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
    if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
        _fail(f"{label} changed while reading")
    return bytes(content), before


def _read_regular(
    path: Path,
    label: str,
    maximum_bytes: int,
    *,
    private: bool = False,
    allow_empty: bool = False,
) -> bytes:
    if private:
        _private_parent(path)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        _fail(f"unable to open {label} without following links: {type(exc).__name__}")
    try:
        content, _ = _read_descriptor_stably(
            descriptor,
            label,
            maximum_bytes,
            private=private,
            allow_empty=allow_empty,
        )
        return content
    finally:
        os.close(descriptor)


def _load_json(path: Path, label: str, *, private: bool = False) -> dict[str, Any]:
    raw = _read_regular(path, label, MAX_JSON_BYTES, private=private)
    if not raw.endswith(b"}\n") or raw[:-1].endswith((b"\n", b"\r", b" ", b"\t")):
        _fail(f"{label} must end immediately after one JSON object and one newline")
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_unique_json_object,
            parse_constant=lambda token: _fail(
                f"{label} contains non-finite number: {token}"
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(f"{label} is invalid UTF-8 JSON: {exc}")
    if not isinstance(value, dict):
        _fail(f"{label} must be one JSON object")
    return value


def _load_properties(path: Path, label: str) -> dict[str, str]:
    raw = _read_regular(path, label, MAX_TEXT_BYTES)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        _fail(f"{label} is not UTF-8: {exc}")
    if not text.endswith("\n") or "\r" in text:
        _fail(f"{label} must be newline-terminated canonical text")
    result: dict[str, str] = {}
    for line in text.splitlines():
        if not line or "=" not in line:
            _fail(f"{label} contains a malformed property")
        key, value = line.split("=", 1)
        if not key or not value or key in result:
            _fail(f"{label} contains a duplicate or empty property")
        result[key] = value
    return result


def _write_new(path: Path, payload: bytes, mode: int = 0o600) -> None:
    parent = _private_parent(path)
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        descriptor = os.open(path, flags, mode)
    except OSError as exc:
        _fail(f"unable to create private artifact exclusively: {type(exc).__name__}")
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            descriptor = -1
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    directory_descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    _write_new(
        path,
        (json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode(
            "ascii"
        ),
    )


def _canonical_jwt(content: bytes, label: str) -> str:
    try:
        token = content.decode("ascii")
    except UnicodeDecodeError:
        _fail(f"{label} must be ASCII")
    if token.endswith("\n"):
        token = token[:-1]
    if "\n" in token or "\r" in token or token != token.strip():
        _fail(f"{label} must contain one compact JWT")
    segments = token.split(".")
    if len(segments) != 3 or not all(segments):
        _fail(f"{label} must contain one compact JWT")
    try:
        payload = segments[1]
        decoded = base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4))
        claims = json.loads(
            decoded.decode("utf-8"),
            object_pairs_hook=_unique_json_object,
            parse_constant=lambda value: _fail(
                f"{label} contains a non-finite claim: {value}"
            ),
        )
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(f"{label} has invalid JWT claims: {type(exc).__name__}")
    if not isinstance(claims, dict):
        _fail(f"{label} JWT claims must be one object")
    issued_at = claims.get("iat")
    expires_at = claims.get("exp")
    if (
        isinstance(issued_at, bool)
        or isinstance(expires_at, bool)
        or not isinstance(issued_at, (int, float))
        or not isinstance(expires_at, (int, float))
        or not math.isfinite(float(issued_at))
        or not math.isfinite(float(expires_at))
    ):
        _fail(f"{label} JWT requires numeric iat and exp claims")
    now = time.time()
    if issued_at > now + 30 or expires_at <= now + 30:
        _fail(f"{label} JWT is not currently usable with a 30-second margin")
    if expires_at <= issued_at or expires_at - issued_at > 15 * 60:
        _fail(f"{label} JWT lifetime must be no more than 15 minutes")
    return token


def _canonical_uuid(value: object, label: str) -> str:
    if not isinstance(value, str):
        _fail(f"{label} must be a canonical UUID")
    try:
        parsed = uuid.UUID(value)
    except ValueError:
        _fail(f"{label} must be a canonical UUID")
    if str(parsed) != value:
        _fail(f"{label} must be a canonical lowercase UUID")
    return value


def _sha256(value: object, label: str) -> str:
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        _fail(f"{label} must be one lowercase SHA-256 value")
    return value


def _positive_int(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        _fail(f"{label} must be a positive integer")
    return value


def _exact_int(value: object, expected: int, label: str) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or value != expected:
        _fail(f"{label} must be the integer {expected}")


def _formal_payload(direction: str, run_ref: str, session_ref: str, transfer_id: str) -> bytes:
    if direction not in {"android-to-peer", "peer-to-android"}:
        _fail("formal payload direction is invalid")
    _sha256(run_ref, "run reference")
    _sha256(session_ref, "session reference")
    _canonical_uuid(transfer_id, "transfer identifier")
    return (
        "skybridge-formal-p2p-file-v1\n"
        f"direction={direction}\n"
        f"runRef={run_ref}\n"
        f"sessionRef={session_ref}\n"
        f"transferId={transfer_id}\n"
    ).encode("ascii")


def _terminal_fields(line: str, prefix: str) -> dict[str, str]:
    if not line.startswith(prefix):
        _fail("Android terminal has the wrong prefix")
    fields: dict[str, str] = {}
    for token in line[len(prefix) :].strip().split():
        if "=" not in token:
            _fail("Android terminal contains a token without an assignment")
        key, value = token.split("=", 1)
        if not key or not value or key in fields:
            _fail("Android terminal contains an empty or duplicate field")
        fields[key] = value
    return fields


def _android_terminal(path: Path, run_ref: str) -> dict[str, str]:
    raw = _read_regular(path, "Android instrumentation output", MAX_TEXT_BYTES)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        _fail(f"Android instrumentation output is not UTF-8: {exc}")
    lines = text.splitlines()
    status_events: list[tuple[dict[str, str], int, int]] = []
    pending_status: dict[str, str] = {}
    terminal_codes: list[tuple[int, int]] = []
    result_lines: list[tuple[str, int]] = []
    for line_index, line in enumerate(lines):
        if line.startswith("INSTRUMENTATION_STATUS: "):
            assignment = line.removeprefix("INSTRUMENTATION_STATUS: ")
            if "=" not in assignment:
                _fail("Android instrumentation status contains a bare field")
            key, value = assignment.split("=", 1)
            if not key or key in pending_status:
                _fail("Android instrumentation status contains an empty or duplicate field")
            pending_status[key] = value
        elif line.startswith("INSTRUMENTATION_STATUS_CODE: "):
            code_text = line.removeprefix("INSTRUMENTATION_STATUS_CODE: ")
            if re.fullmatch(r"-?[0-9]+", code_text) is None or not pending_status:
                _fail("Android instrumentation status terminal is malformed")
            status_events.append((pending_status, int(code_text), line_index))
            pending_status = {}
        elif line.startswith("INSTRUMENTATION_CODE: "):
            code_text = line.removeprefix("INSTRUMENTATION_CODE: ")
            if re.fullmatch(r"-?[0-9]+", code_text) is None:
                _fail("Android instrumentation terminal code is malformed")
            terminal_codes.append((int(code_text), line_index))
        elif line.startswith("INSTRUMENTATION_RESULT: "):
            result_lines.append(
                (line.removeprefix("INSTRUMENTATION_RESULT: "), line_index)
            )
    if pending_status:
        _fail("Android instrumentation status block is unterminated")
    expected_status_identity = {
        "class": EXPECTED_TEST_CLASS,
        "current": "1",
        "id": "AndroidJUnitRunner",
        "numtests": "1",
        "test": EXPECTED_TEST_METHOD,
    }
    expected_status_events = [
        ({**expected_status_identity, "stream": ""}, 1),
        ({**expected_status_identity, "stream": "."}, 0),
    ]
    status_values = [(fields, code) for fields, code, _ in status_events]
    success_line_indexes = [
        index
        for index, line in enumerate(lines)
        if line.startswith("SB-ANDROID-APP-OFFER success ")
    ]
    ok_indexes = [index for index, line in enumerate(lines) if line == "OK (1 test)"]
    if (
        status_values != expected_status_events
        or len(status_events) != 2
        or len(terminal_codes) != 1
        or terminal_codes[0][0] != -1
    ):
        _fail("Android instrumentation did not run one exact canonical test sequence")
    if len(result_lines) != 1 or result_lines[0][0] != "stream=":
        _fail("Android instrumentation result block is not canonical")
    if (
        len(success_line_indexes) != 1
        or len(ok_indexes) != 1
        or not (
            status_events[0][2]
            < success_line_indexes[0]
            < status_events[1][2]
            < result_lines[0][1]
            < ok_indexes[0]
            < terminal_codes[0][1]
        )
    ):
        _fail("Android instrumentation did not run one exact canonical test sequence")
    if text.splitlines().count("OK (1 test)") != 1 or re.search(
        r"(?:INSTRUMENTATION_FAILED|FAILURES!!!|Process crashed|shortMsg=)", text
    ):
        _fail("Android instrumentation does not prove exactly one successful test")
    storage = f"SB-ANDROID-APP-OFFER storage=dedicated-test-package package={EXPECTED_TEST_PACKAGE}"
    if text.splitlines().count(storage) != 1:
        _fail("Android instrumentation did not use the dedicated macOS test package")
    sensitive = re.findall(
        r"SB-ANDROID-APP-OFFER sensitive-state phase=(before|after) digest=([0-9a-f]{64})",
        text,
    )
    if (
        len(sensitive) != 2
        or sensitive[0][0] != "before"
        or sensitive[1][0] != "after"
        or sensitive[0][1] != sensitive[1][1]
    ):
        _fail("Android instrumentation identity/trust state is not frozen")
    terminals = [
        line
        for line in text.splitlines()
        if line.startswith("SB-ANDROID-APP-OFFER success ")
    ]
    if len(terminals) != 1:
        _fail("Android instrumentation must contain exactly one formal success terminal")
    fields = _terminal_fields(terminals[0], "SB-ANDROID-APP-OFFER success")
    expected_fields = {
        "code",
        "runRef",
        "sessionRef",
        "bootstrapKem",
        "bootstrapQPeriapt",
        "qperiapt",
        "expectedSuite",
        "suite",
        "suiteWireId",
        "route",
        "fileTransfer",
        "bidirectionalFileTransfer",
        "androidToPeerTransferId",
        "androidToPeerBytes",
        "androidToPeerSha256",
        "androidToPeerOutboundOps",
        "androidToPeerInboundAcks",
        "peerToAndroidTransferId",
        "peerToAndroidBytes",
        "peerToAndroidSha256",
        "peerToAndroidInboundOps",
        "peerToAndroidOutboundAcks",
        "androidRunOwnedPayloadCleaned",
    }
    if set(fields) != expected_fields:
        _fail("Android formal terminal has an unexpected field set")
    if (
        fields["code"] != "<redacted>"
        or fields["runRef"] != run_ref
        or SHA256_PATTERN.fullmatch(fields["sessionRef"]) is None
        or fields["bootstrapKem"] != "true"
        or fields["bootstrapQPeriapt"] != "false"
        or fields["qperiapt"] != "false"
        or fields["expectedSuite"] != "MLKEM_768"
        or fields["suite"] != EXPECTED_ANDROID_SUITE
        or fields["suiteWireId"] != EXPECTED_SUITE_WIRE_ID
        or fields["route"] not in {"direct", "relay"}
        or fields["fileTransfer"] != "true"
        or fields["bidirectionalFileTransfer"] != "true"
        or fields["androidRunOwnedPayloadCleaned"] != "true"
        or fields["androidToPeerOutboundOps"] != "metadata,chunk,complete"
        or fields["androidToPeerInboundAcks"] != "metadataAck,chunkAck,completeAck"
        or fields["peerToAndroidInboundOps"] != "metadata,chunk,complete"
        or fields["peerToAndroidOutboundAcks"] != "metadataAck,chunkAck,completeAck"
    ):
        _fail("Android formal terminal has invalid policy or ACK evidence")
    return fields


def _artifact(path: Path, prefix: str) -> dict[str, object]:
    props = _load_properties(path, f"{prefix} provenance")
    expected = {f"{prefix}_path", f"{prefix}_sha256", f"{prefix}_bytes"}
    if set(props) != expected:
        _fail(f"{prefix} provenance field set is invalid")
    artifact_path = props[f"{prefix}_path"]
    digest = props[f"{prefix}_sha256"]
    byte_count = props[f"{prefix}_bytes"]
    if (
        not artifact_path.startswith("/")
        or SHA256_PATTERN.fullmatch(digest) is None
        or not byte_count.isdigit()
        or int(byte_count) <= 0
    ):
        _fail(f"{prefix} provenance is malformed")
    return {"path": artifact_path, "sha256": digest, "bytes": int(byte_count)}


def _source_freeze(before_path: Path, after_path: Path, source_commit: str) -> str:
    before = _load_properties(before_path, "source before binding")
    after = _load_properties(after_path, "source after binding")
    expected = {"schema_version", "phase", "source_commit", "source_tree", "worktree_clean"}
    if set(before) != expected or set(after) != expected:
        _fail("source binding has an unexpected field set")
    if (
        before["schema_version"] != "1"
        or after["schema_version"] != "1"
        or before["phase"] != "before"
        or after["phase"] != "after"
        or before["source_commit"] != source_commit
        or after["source_commit"] != source_commit
        or SOURCE_COMMIT_PATTERN.fullmatch(before["source_tree"]) is None
        or before["source_tree"] != after["source_tree"]
        or before["worktree_clean"] != "true"
        or after["worktree_clean"] != "true"
    ):
        _fail("source binding changed during the formal run")
    return before["source_tree"]


def _device_freeze(before_path: Path, after_path: Path) -> dict[str, str]:
    before = _load_properties(before_path, "Android device before binding")
    after = _load_properties(after_path, "Android device after binding")
    expected = {
        "schema_version", "profile", "serial_ref", "model_ref", "manufacturer",
        "release", "sdk", "abi", "qemu", "page_size",
    }
    if set(before) != expected or before != after:
        _fail("Android device binding is invalid or changed")
    if (
        before["schema_version"] != "1"
        or before["profile"] != "samsung-physical-4k"
        or before["manufacturer"] != "samsung"
        or before["sdk"] != "36"
        or before["abi"] != "arm64-v8a"
        or before["qemu"] != "0"
        or before["page_size"] != "4096"
        or re.fullmatch(r"sha256:[0-9a-f]{16}", before["serial_ref"]) is None
        or re.fullmatch(r"sha256:[0-9a-f]{16}", before["model_ref"]) is None
    ):
        _fail("Android target is not the exact formal Samsung API36/4K profile")
    return before


def _installed_freeze(
    before_path: Path,
    after_path: Path,
    app: dict[str, object],
    test: dict[str, object],
    serial_ref: str,
) -> None:
    before = _load_properties(before_path, "installed APK before binding")
    after = _load_properties(after_path, "installed APK after binding")
    expected = {
        f"{prefix}_{suffix}"
        for prefix in ("app", "test")
        for suffix in ("package", "sha256", "serial_ref", "remote_path_ref")
    }
    if set(before) != expected or before != after:
        _fail("installed APK binding is invalid or changed")
    for prefix, package, artifact in (
        ("app", EXPECTED_APP_PACKAGE, app),
        ("test", EXPECTED_TEST_PACKAGE, test),
    ):
        if (
            before[f"{prefix}_package"] != package
            or before[f"{prefix}_sha256"] != artifact["sha256"]
            or before[f"{prefix}_serial_ref"] != serial_ref
            or re.fullmatch(r"sha256:[0-9a-f]{16}", before[f"{prefix}_remote_path_ref"])
            is None
        ):
            _fail("installed APK binding does not match the frozen artifact/device")


def _android_sensitive_freeze(before_path: Path, after_path: Path) -> int:
    before = _load_properties(before_path, "pre-overlay Android sensitive state")
    after = _load_properties(after_path, "post-run Android sensitive state")
    expected = {"schema_version", "package", "uid"}
    for prefix in ("p2p_identity", "pqc_keys", "peer_kem_keys"):
        expected.update({f"{prefix}_bytes", f"{prefix}_sha256"})
    if set(before) != expected or before != after:
        _fail("Android pre-overlay package UID or raw sensitive preferences changed")
    if before["schema_version"] != "1" or before["package"] != EXPECTED_APP_PACKAGE:
        _fail("Android sensitive-state snapshot belongs to another package")
    if not before["uid"].isdigit() or int(before["uid"]) <= 0:
        _fail("Android package UID is invalid")
    for prefix in ("p2p_identity", "pqc_keys", "peer_kem_keys"):
        if (
            not before[f"{prefix}_bytes"].isdigit()
            or int(before[f"{prefix}_bytes"]) <= 0
            or SHA256_PATTERN.fullmatch(before[f"{prefix}_sha256"]) is None
        ):
            _fail("Android raw sensitive preference evidence is malformed")
    return int(before["uid"])


def _mac_process_identity(path: Path, expected_executable: str) -> dict[str, Any]:
    identity = _load_json(path, "macOS process ownership", private=True)
    expected = {
        "auditToken", "executablePath", "platform", "processIdentifier",
        "schemaVersion", "startTimeToken",
    }
    pid = identity.get("processIdentifier")
    token = identity.get("auditToken")
    _exact_int(identity.get("schemaVersion"), 1, "macOS process ownership schemaVersion")
    if (
        set(identity) != expected
        or identity.get("platform") != "macos"
        or isinstance(pid, bool)
        or not isinstance(pid, int)
        or pid <= 0
        or not isinstance(token, list)
        or len(token) != 8
        or any(isinstance(word, bool) or not isinstance(word, int) or not 0 <= word <= 0xFFFFFFFF for word in token)
        or token[5] != pid
        or identity.get("executablePath") != expected_executable
        or not isinstance(identity.get("startTimeToken"), str)
        or re.fullmatch(r"[1-9][0-9]*:([0-9]+)", identity["startTimeToken"])
        is None
    ):
        _fail("macOS process ownership is malformed or bound to another executable")
    if int(identity["startTimeToken"].split(":", 1)[1]) >= 1_000_000:
        _fail("macOS process ownership start-time token is malformed")
    return identity


def _transfer(
    value: object,
    label: str,
    direction: str,
    run_ref: str,
    session_ref: str,
) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != {
        "transferId", "bytes", "sha256", "durableCommit", "completeAck"
    }:
        _fail(f"{label} transfer evidence has an unexpected schema")
    transfer_id = _canonical_uuid(value["transferId"], f"{label} transfer ID")
    byte_count = _positive_int(value["bytes"], f"{label} bytes")
    digest = _sha256(value["sha256"], f"{label} SHA-256")
    payload = _formal_payload(direction, run_ref, session_ref, transfer_id)
    expected_digest = hashlib.sha256(payload).hexdigest()
    if (
        byte_count != len(payload)
        or digest != expected_digest
        or value["durableCommit"] is not True
        or value["completeAck"] is not True
    ):
        _fail(f"{label} does not prove canonical bytes, durable commit, and completeAck")
    return {
        "bytes": byte_count,
        "completeAcknowledgement": True,
        "direction": label,
        "durableCommit": True,
        "payloadSHA256": digest,
        "transferIDRef": hashlib.sha256(transfer_id.encode("ascii")).hexdigest(),
    }


def _mac_result(path: Path, run_ref: str, android: dict[str, str]) -> tuple[dict[str, Any], list[dict[str, object]]]:
    result = _load_json(path, "macOS formal result", private=True)
    expected = {
        "schemaVersion", "outcome", "runRef", "sessionRef", "suite", "suiteWireId",
        "selectedIce", "transfers", "identityState", "runOwnedPayloadCleaned",
    }
    if set(result) != expected:
        _fail("macOS formal result has an unexpected field set")
    session_ref = result.get("sessionRef")
    _exact_int(result.get("schemaVersion"), 1, "macOS formal result schemaVersion")
    if (
        result.get("outcome") != "success"
        or result.get("runRef") != run_ref
        or not isinstance(session_ref, str)
        or SHA256_PATTERN.fullmatch(session_ref) is None
        or session_ref != android["sessionRef"]
        or result.get("suite") != EXPECTED_SUITE
        or result.get("suiteWireId") != EXPECTED_SUITE_WIRE_ID
        or result.get("runOwnedPayloadCleaned") is not True
    ):
        _fail("macOS formal result is not one exact successful ML-KEM-768 session")
    selected = result.get("selectedIce")
    if not isinstance(selected, dict) or set(selected) != {
        "route", "localCandidateType", "remoteCandidateType", "protocol"
    }:
        _fail("macOS selected ICE evidence has an unexpected schema")
    if any(
        not isinstance(selected[field], str)
        for field in ("route", "localCandidateType", "remoteCandidateType", "protocol")
    ):
        _fail("macOS selected ICE evidence has invalid field types")
    candidate_types = {"host", "srflx", "prflx", "relay"}
    if (
        selected["route"] not in {"direct", "relay"}
        or selected["route"] != android["route"]
        or selected["localCandidateType"] not in candidate_types
        or selected["remoteCandidateType"] not in candidate_types
        or selected["protocol"] not in {"udp", "tcp"}
    ):
        _fail("macOS selected ICE evidence is unknown or mismatched")
    candidate_uses_relay = "relay" in {
        selected["localCandidateType"],
        selected["remoteCandidateType"],
    }
    if (selected["route"] == "relay") != candidate_uses_relay:
        _fail("macOS selected ICE route contradicts its candidate types")
    identity = result.get("identityState")
    if not isinstance(identity, dict) or set(identity) != {
        "beforeDigest", "afterDigest", "unchanged"
    }:
        _fail("macOS identity/trust state has an unexpected schema")
    before_digest = _sha256(identity["beforeDigest"], "macOS identity before digest")
    if (
        _sha256(identity["afterDigest"], "macOS identity after digest") != before_digest
        or identity["unchanged"] is not True
    ):
        _fail("macOS identity/trust state changed during the formal run")
    transfers = result.get("transfers")
    if not isinstance(transfers, dict) or set(transfers) != {"androidToMac", "macToAndroid"}:
        _fail("macOS bidirectional transfer evidence has an unexpected schema")
    records = [
        _transfer(transfers["androidToMac"], "android-to-mac", "android-to-peer", run_ref, session_ref),
        _transfer(transfers["macToAndroid"], "mac-to-android", "peer-to-android", run_ref, session_ref),
    ]
    if transfers["androidToMac"]["transferId"] == transfers["macToAndroid"]["transferId"]:
        _fail("formal bidirectional transfer identifiers must be distinct")
    android_pairs = (
        ("androidToPeer", transfers["androidToMac"]),
        ("peerToAndroid", transfers["macToAndroid"]),
    )
    for prefix, host_transfer in android_pairs:
        if (
            android[f"{prefix}TransferId"] != host_transfer["transferId"]
            or android[f"{prefix}Bytes"] != str(host_transfer["bytes"])
            or android[f"{prefix}Sha256"] != host_transfer["sha256"]
        ):
            _fail("Android and macOS reported different transfer bytes or identity")
    return result, records


def validate_receipt(arguments: argparse.Namespace) -> dict[str, Any]:
    if SOURCE_COMMIT_PATTERN.fullmatch(arguments.source_commit) is None:
        _fail("source commit must be a full lowercase Git revision")
    _sha256(arguments.run_ref, "run reference")
    source_tree = _source_freeze(
        arguments.source_binding_before,
        arguments.source_binding_after,
        arguments.source_commit,
    )
    app = _artifact(arguments.app_apk_provenance, "app_debug_apk")
    test = _artifact(arguments.test_apk_provenance, "android_test_apk")
    host_before = _artifact(arguments.host_provenance_before, "mac_formal_host")
    host_after = _artifact(arguments.host_provenance_after, "mac_formal_host")
    if host_before != host_after:
        _fail("macOS formal host artifact changed during the run")
    device = _device_freeze(arguments.android_device_before, arguments.android_device_after)
    _installed_freeze(
        arguments.android_installed_before,
        arguments.android_installed_after,
        app,
        test,
        device["serial_ref"],
    )
    package_uid = _android_sensitive_freeze(
        arguments.android_sensitive_before,
        arguments.android_sensitive_after,
    )
    manifest = _load_properties(arguments.manifest_binding, "merged manifest binding")
    if set(manifest) != {"schema_version", "package", "sha256", "automatic_start_entries_absent"} or (
        manifest["schema_version"] != "1"
        or manifest["package"] != EXPECTED_APP_PACKAGE
        or SHA256_PATTERN.fullmatch(manifest["sha256"]) is None
        or manifest["automatic_start_entries_absent"] != "true"
    ):
        _fail("merged manifest automatic-start absence is not proven")
    android = _android_terminal(arguments.android_instrumentation, arguments.run_ref)
    mac, transfer_records = _mac_result(arguments.mac_result, arguments.run_ref, android)
    identity = _mac_process_identity(
        arguments.mac_process_identity, str(host_before["path"])
    )
    required_true = {
        "android_app_exit_verified": arguments.android_app_exit_verified,
        "test_package_cleanup_verified": arguments.test_package_cleanup_verified,
        "android_context_cleanup_verified": arguments.android_context_cleanup_verified,
        "private_file_cleanup_verified": arguments.private_file_cleanup_verified,
        "mac_process_cleanup_verified": arguments.mac_process_cleanup_verified,
        "mac_exit_verified": arguments.mac_exit_verified,
        "mac_payload_cleanup_verified": arguments.mac_payload_cleanup_verified,
    }
    missing = [name for name, value in required_true.items() if value != "true"]
    if missing:
        _fail("cleanup or exact process exit is incomplete: " + ",".join(sorted(missing)))
    return {
        "android": {
            "appPackage": EXPECTED_APP_PACKAGE,
            "appProcessAbsentBeforeAndAfter": True,
            "device": {
                "abi": device["abi"],
                "pageSize": int(device["page_size"]),
                "physical": True,
                "profile": device["profile"],
                "sdk": int(device["sdk"]),
                "serialRef": device["serial_ref"],
            },
            "mainPackageUIDRef": hashlib.sha256(
                str(package_uid).encode("ascii")
            ).hexdigest()[:16],
            "mergedManifestAutomaticStartEntriesAbsent": True,
            "persistentSensitiveStateUnchangedFromBeforeOverlay": True,
            "targetApk": {"bytes": app["bytes"], "sha256": app["sha256"]},
            "testApk": {"bytes": test["bytes"], "sha256": test["sha256"]},
            "testPackage": EXPECTED_TEST_PACKAGE,
            "testPackageCleanupVerified": True,
        },
        "artifactBindingPurpose": "detect-accidental-source-artifact-device-or-run-mismatch",
        "fileTransfer": {"bidirectional": True, "transfers": transfer_records},
        "lane": "android-offerer-physical-macos-bidirectional-file-transfer",
        "macOS": {
            "exactChildProcessVerified": True,
            "host": {"bytes": host_before["bytes"], "sha256": host_before["sha256"]},
            "identityAndTrustMode": "existing-persistent-read-only",
            "persistentIdentityWriteAuthorized": False,
            "persistentTrustWriteAuthorized": False,
            "processRef": hashlib.sha256(
                f"{identity['processIdentifier']}:{identity['startTimeToken']}".encode("ascii")
            ).hexdigest()[:16],
            "runOwnedPayloadCleaned": True,
        },
        "outcome": "success",
        "runRef": arguments.run_ref,
        "schemaVersion": 1,
        "sessionRef": android["sessionRef"],
        "sourceCommit": arguments.source_commit,
        "sourceFreezeVerified": True,
        "sourceTree": source_tree,
        "terminal": {
            "selectedIce": mac["selectedIce"],
            "suite": EXPECTED_SUITE,
            "suiteWireId": EXPECTED_SUITE_WIRE_ID,
            "success": True,
        },
    }


def create_private_file(arguments: argparse.Namespace) -> None:
    maximum = arguments.maximum_bytes
    if maximum < 1 or maximum > MAX_PRIVATE_BYTES:
        _fail("private input maximum is outside the permitted boundary")
    content = sys.stdin.buffer.read(maximum + 1)
    if not content or len(content) > maximum or b"\x00" in content:
        _fail("private input is empty, oversized, or contains NUL")
    if arguments.kind == "token":
        content = _canonical_jwt(content, "token").encode("ascii")
    elif arguments.kind == "code":
        try:
            code = content.decode("ascii")
        except UnicodeDecodeError:
            _fail("connection code must be ASCII")
        if (
            not code
            or code != code.strip()
            or any(character.isspace() for character in code)
        ):
            _fail("connection code must be one non-empty token")
        content = code.encode("ascii")
    _write_new(arguments.output, content)
    print(f"sha256={hashlib.sha256(content).hexdigest()}")
    print(f"bytes={len(content)}")


def copy_private_file(arguments: argparse.Namespace) -> None:
    content = _read_regular(
        arguments.input,
        f"private {arguments.kind} input",
        arguments.maximum_bytes,
        private=True,
    )
    if arguments.kind == "token":
        content = _canonical_jwt(content, "token").encode("ascii")
    elif arguments.kind == "code":
        try:
            code = content.decode("ascii")
        except UnicodeDecodeError:
            _fail("connection code must be ASCII")
        if not code or code != code.strip() or any(character.isspace() for character in code):
            _fail("connection code must be one non-empty token")
        content = code.encode("ascii")
    _write_new(arguments.output, content)
    print(f"sha256={hashlib.sha256(content).hexdigest()}")
    print(f"bytes={len(content)}")


def create_auth_context(arguments: argparse.Namespace) -> None:
    token = _canonical_jwt(
        _read_regular(
            arguments.token_file,
            "run-owned token",
            MAX_PRIVATE_BYTES,
            private=True,
        ),
        "run-owned token",
    )
    tenant_id = arguments.tenant_id
    if (
        not tenant_id
        or tenant_id != tenant_id.strip()
        or len(tenant_id.encode("utf-8")) > 512
        or any(character.isspace() or ord(character) < 0x20 for character in tenant_id)
    ):
        _fail("tenant identifier is malformed")
    _write_new(
        arguments.output,
        json.dumps(
            {"bearerToken": token, "tenantId": tenant_id},
            separators=(",", ":"),
            ensure_ascii=True,
        ).encode("ascii"),
    )


def scan_private_values(arguments: argparse.Namespace) -> None:
    token = _read_regular(
        arguments.token_file,
        "run-owned token",
        MAX_PRIVATE_BYTES,
        private=True,
    )
    code = _read_regular(
        arguments.code_file,
        "run-owned connection code",
        MAX_PRIVATE_BYTES,
        private=True,
    )
    for path in arguments.scan_file:
        content = _read_regular(path, "formal log", MAX_TEXT_BYTES, allow_empty=True)
        if token in content or code in content:
            _fail("formal log contains the token or connection code")
        try:
            text = content.decode("utf-8")
        except UnicodeDecodeError:
            _fail("formal log is not UTF-8")
        if re.search(
            r"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\."
            r"[A-Za-z0-9_-]+",
            text,
        ):
            _fail("formal log contains a JWT-shaped value")


def unlink_private_file(arguments: argparse.Namespace) -> None:
    path = arguments.path
    parent = _private_parent(path)
    expected_digest = _sha256(arguments.expected_sha256, "expected private file digest")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        _fail(f"unable to open private file for exact unlink: {type(exc).__name__}")
    try:
        content, opened = _read_descriptor_stably(
            descriptor,
            "private file",
            arguments.maximum_bytes,
            private=True,
        )
        if len(content) != arguments.expected_bytes or hashlib.sha256(content).hexdigest() != expected_digest:
            _fail("private file bytes changed before cleanup")
        path_metadata = path.lstat()
        if (path_metadata.st_dev, path_metadata.st_ino) != (opened.st_dev, opened.st_ino):
            _fail("private file path no longer names the opened inode")
        os.unlink(path)
        if os.fstat(descriptor).st_nlink != 0:
            _fail("exact opened private inode was not unlinked")
    finally:
        os.close(descriptor)
    directory_descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)


def emit_private_file(arguments: argparse.Namespace) -> None:
    content = _read_regular(
        arguments.path,
        "private file",
        arguments.maximum_bytes,
        private=True,
    )
    try:
        sys.stdout.buffer.write(content)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        _fail("private file consumer closed before the exact bytes were written")


def collect_artifact(arguments: argparse.Namespace) -> None:
    if not re.fullmatch(r"[a-z][a-z0-9_]{0,31}", arguments.prefix):
        _fail("artifact prefix is invalid")
    path = arguments.path.resolve(strict=True)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        _fail(f"unable to open artifact without following links: {type(exc).__name__}")
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size < 1
            or before.st_size > MAX_ARTIFACT_BYTES
        ):
            _fail("artifact must be a bounded single-link regular file")
        digest = hashlib.sha256()
        consumed = 0
        while consumed < before.st_size:
            chunk = os.read(descriptor, min(1024 * 1024, before.st_size - consumed))
            if not chunk:
                _fail("artifact was truncated while hashing")
            digest.update(chunk)
            consumed += len(chunk)
        if os.read(descriptor, 1):
            _fail("artifact grew while hashing")
        after = os.fstat(descriptor)
        stable_fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns")
        if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
            _fail("artifact changed while hashing")
    finally:
        os.close(descriptor)
    body = (
        f"{arguments.prefix}_path={path}\n"
        f"{arguments.prefix}_sha256={digest.hexdigest()}\n"
        f"{arguments.prefix}_bytes={before.st_size}\n"
    ).encode("utf-8")
    _write_new(arguments.output, body)


def collect_android_sensitive(arguments: argparse.Namespace) -> None:
    raw = sys.stdin.buffer.read(16 * 1024 + 1)
    if not raw or len(raw) > 16 * 1024:
        _fail("Android sensitive-state command output is empty or oversized")
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        _fail("Android sensitive-state command output is not ASCII")
    if not text.endswith("\n") or "\r" in text:
        _fail("Android sensitive-state command output is not canonical text")
    properties: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            _fail("Android sensitive-state command output contains a malformed property")
        key, value = line.split("=", 1)
        if not key or not value or key in properties:
            _fail("Android sensitive-state command output contains duplicate or empty data")
        properties[key] = value
    expected = {"uid"}
    for prefix in ("p2p_identity", "pqc_keys", "peer_kem_keys"):
        expected.update({f"{prefix}_bytes", f"{prefix}_sha256"})
    if set(properties) != expected or not properties["uid"].isdigit():
        _fail("Android sensitive-state command output has an unexpected schema")
    for prefix in ("p2p_identity", "pqc_keys", "peer_kem_keys"):
        if (
            not properties[f"{prefix}_bytes"].isdigit()
            or int(properties[f"{prefix}_bytes"]) <= 0
            or SHA256_PATTERN.fullmatch(properties[f"{prefix}_sha256"]) is None
        ):
            _fail("Android sensitive-state command output is malformed")
    body = (
        "schema_version=1\n"
        f"package={EXPECTED_APP_PACKAGE}\n"
        f"uid={properties['uid']}\n"
        + "".join(
            f"{prefix}_bytes={properties[f'{prefix}_bytes']}\n"
            f"{prefix}_sha256={properties[f'{prefix}_sha256']}\n"
            for prefix in ("p2p_identity", "pqc_keys", "peer_kem_keys")
        )
    ).encode("ascii")
    _write_new(arguments.output, body)


def validate_manifest(arguments: argparse.Namespace) -> None:
    raw = _read_regular(arguments.manifest, "merged debug manifest", MAX_TEXT_BYTES)
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as exc:
        _fail(f"merged debug manifest is invalid XML: {exc}")
    if root.tag != "manifest" or root.get("package") != EXPECTED_APP_PACKAGE:
        _fail("merged debug manifest belongs to another package")
    forbidden: list[str] = []
    for receiver in root.findall("./application/receiver"):
        observed_actions = {
            action.get(ANDROID_XML_NAME)
            for action in receiver.findall("./intent-filter/action")
        }
        forbidden.extend(sorted(AUTOMATIC_START_ACTIONS.intersection(observed_actions)))
    if forbidden:
        _fail("merged debug manifest contains automatic-start action: " + ",".join(forbidden))
    body = (
        "schema_version=1\n"
        f"package={EXPECTED_APP_PACKAGE}\n"
        f"sha256={hashlib.sha256(raw).hexdigest()}\n"
        "automatic_start_entries_absent=true\n"
    ).encode("ascii")
    _write_new(arguments.output, body)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    private_create = subparsers.add_parser("private-create")
    private_create.add_argument("--kind", choices=("token", "code"), required=True)
    private_create.add_argument("--maximum-bytes", type=int, default=MAX_PRIVATE_BYTES)
    private_create.add_argument("--output", type=Path, required=True)

    private_copy = subparsers.add_parser("private-copy")
    private_copy.add_argument("--kind", choices=("token", "code"), required=True)
    private_copy.add_argument("--input", type=Path, required=True)
    private_copy.add_argument("--maximum-bytes", type=int, default=MAX_PRIVATE_BYTES)
    private_copy.add_argument("--output", type=Path, required=True)

    private_unlink = subparsers.add_parser("private-unlink")
    private_unlink.add_argument("--path", type=Path, required=True)
    private_unlink.add_argument("--expected-sha256", required=True)
    private_unlink.add_argument("--expected-bytes", type=int, required=True)
    private_unlink.add_argument("--maximum-bytes", type=int, default=MAX_PRIVATE_BYTES)

    private_emit = subparsers.add_parser("private-emit")
    private_emit.add_argument("--path", type=Path, required=True)
    private_emit.add_argument("--maximum-bytes", type=int, default=MAX_PRIVATE_BYTES)

    auth_context = subparsers.add_parser("auth-context")
    auth_context.add_argument("--token-file", type=Path, required=True)
    auth_context.add_argument("--tenant-id", required=True)
    auth_context.add_argument("--output", type=Path, required=True)

    secret_scan = subparsers.add_parser("secret-scan")
    secret_scan.add_argument("--token-file", type=Path, required=True)
    secret_scan.add_argument("--code-file", type=Path, required=True)
    secret_scan.add_argument("--scan-file", type=Path, action="append", required=True)

    artifact = subparsers.add_parser("artifact")
    artifact.add_argument("--path", type=Path, required=True)
    artifact.add_argument("--prefix", required=True)
    artifact.add_argument("--output", type=Path, required=True)

    android_sensitive = subparsers.add_parser("android-sensitive")
    android_sensitive.add_argument("--output", type=Path, required=True)

    manifest = subparsers.add_parser("manifest")
    manifest.add_argument("--manifest", type=Path, required=True)
    manifest.add_argument("--output", type=Path, required=True)

    receipt = subparsers.add_parser("receipt")
    receipt.add_argument("--source-commit", required=True)
    receipt.add_argument("--run-ref", required=True)
    for name in (
        "source-binding-before", "source-binding-after", "app-apk-provenance",
        "test-apk-provenance", "host-provenance-before", "host-provenance-after",
        "android-device-before", "android-device-after", "android-installed-before",
        "android-installed-after", "android-sensitive-before", "android-sensitive-after",
        "manifest-binding", "android-instrumentation", "mac-result", "mac-process-identity",
    ):
        receipt.add_argument(f"--{name}", type=Path, required=True)
    for name in (
        "android-app-exit-verified", "test-package-cleanup-verified",
        "android-context-cleanup-verified", "private-file-cleanup-verified",
        "mac-process-cleanup-verified", "mac-exit-verified",
        "mac-payload-cleanup-verified",
    ):
        receipt.add_argument(f"--{name}", choices=("true", "false"), required=True)
    receipt.add_argument("--output", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_args(argv)
    try:
        if arguments.command == "private-create":
            create_private_file(arguments)
        elif arguments.command == "private-copy":
            copy_private_file(arguments)
        elif arguments.command == "private-unlink":
            unlink_private_file(arguments)
        elif arguments.command == "private-emit":
            emit_private_file(arguments)
        elif arguments.command == "auth-context":
            create_auth_context(arguments)
        elif arguments.command == "secret-scan":
            scan_private_values(arguments)
        elif arguments.command == "artifact":
            collect_artifact(arguments)
        elif arguments.command == "android-sensitive":
            collect_android_sensitive(arguments)
        elif arguments.command == "manifest":
            validate_manifest(arguments)
        else:
            payload = validate_receipt(arguments)
            _write_json(arguments.output, payload)
    except (FormalEvidenceError, OSError) as exc:
        print(f"Android to macOS formal evidence rejected: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
