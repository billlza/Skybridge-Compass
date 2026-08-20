#!/usr/bin/env python3
"""Extract exact-process iOS product evidence from a private log archive.

The caller owns device launch and cleanup.  This module accepts only the private
launch identity captured from that exact ``devicectl --console`` invocation,
filters the exported unified-log rows to the launched shipping executable, and
publishes the same fixed connectivity schema consumed by the release gate.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import stat
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, NoReturn

import webrtc_smoke_process_ownership as process_ownership
from ios_physical_release_acceptance import (
    PhysicalAcceptanceError,
    expected_binding,
    validate_archive_binding,
)
from ios_release_archive_identity import ArchiveIdentityError, load_identity
from validate_product_release_evidence_log import (
    CATEGORY,
    CAPTURE_PROFILE,
    IOS_CAPTURE_MODE,
    IOS_PRODUCT,
    MAX_EVENT_COUNT,
    MAX_INPUT_BYTES,
    SUBSYSTEM,
    parse_canonical_log,
)


MAX_JSON_BYTES = 2 * 1024 * 1024
EXPECTED_BUNDLE_IDENTIFIER = "com.skybridge.compass.ios"
EXPECTED_EXECUTABLE = "SkyBridgeCompass-iOS"
START_TIME_PATTERN = re.compile(r"[1-9][0-9]*:[0-9]{1,6}\Z", re.ASCII)
INSTALLATION_CAPTURE_PROFILE = "skybridge-formal-ios-product-installation-capture"
IDENTITY_EVENT_NAMES = frozenset(
    {
        "productionIdentityCommitted",
        "productionIdentityRestored",
        "productionIdentityHandshakeBound",
    }
)


class IOSProductEvidenceError(RuntimeError):
    """The private iOS capture is not bound to one exact shipping process."""


def _fail(message: str) -> NoReturn:
    raise IOSProductEvidenceError(message)


def _read_regular(path: Path, label: str, maximum_bytes: int) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        _fail(f"unable to open {label} without following links: {exc}")
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size < 1
            or before.st_size > maximum_bytes
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
        stable = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns")
        if any(getattr(before, field) != getattr(after, field) for field in stable):
            _fail(f"{label} changed while reading")
        return bytes(content)
    finally:
        os.close(descriptor)


def _load_json(path: Path, label: str, maximum_bytes: int = MAX_JSON_BYTES) -> dict[str, Any]:
    try:
        payload = json.loads(_read_regular(path, label, maximum_bytes).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(f"{label} is invalid UTF-8 JSON: {exc}")
    if not isinstance(payload, dict):
        _fail(f"{label} must be a JSON object")
    return payload


def _validate_private_launch_identity(path: Path) -> dict[str, Any]:
    try:
        parent = path.parent.lstat()
    except OSError as exc:
        _fail(f"private launch identity parent is unavailable: {exc}")
    if (
        path.parent.is_symlink()
        or not stat.S_ISDIR(parent.st_mode)
        or parent.st_uid != os.geteuid()
        or stat.S_IMODE(parent.st_mode) != 0o700
    ):
        _fail("private launch identity parent must be current-user mode 0700")
    try:
        metadata = path.lstat()
    except OSError as exc:
        _fail(f"private launch identity is unavailable: {exc}")
    if (
        path.is_symlink()
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) != 0o600
    ):
        _fail("private launch identity must be current-user mode 0600 with one link")
    payload = _load_json(path, "private iOS launch identity", 32 * 1024)
    expected_keys = {
        "auditToken",
        "bundleIdentifier",
        "bundleName",
        "executableName",
        "executablePath",
        "installationBinding",
        "platform",
        "processIdentifier",
        "schemaVersion",
        "startTimeToken",
    }
    if set(payload) != expected_keys:
        _fail("private iOS launch identity has an unexpected field set")
    process_id = payload.get("processIdentifier")
    audit_token = payload.get("auditToken")
    start_time = payload.get("startTimeToken")
    if (
        payload.get("schemaVersion") != 1
        or payload.get("platform") != "ios"
        or payload.get("bundleIdentifier") != EXPECTED_BUNDLE_IDENTIFIER
        or payload.get("bundleName") != "SkyBridgeCompass-iOS.app"
        or payload.get("executableName") != EXPECTED_EXECUTABLE
        or isinstance(process_id, bool)
        or not isinstance(process_id, int)
        or process_id <= 1
        or not isinstance(audit_token, list)
        or len(audit_token) != 8
        or any(
            isinstance(word, bool)
            or not isinstance(word, int)
            or not 0 <= word <= 0xFFFFFFFF
            for word in audit_token
        )
        or audit_token[5] != process_id
        or not isinstance(start_time, str)
        or START_TIME_PATTERN.fullmatch(start_time) is None
        or int(start_time.split(":", 1)[1]) >= 1_000_000
    ):
        _fail("private iOS launch identity is malformed")
    executable_path = payload.get("executablePath")
    if not isinstance(executable_path, str) or not executable_path.startswith("/"):
        _fail("private iOS launch executable path must be absolute")
    executable = PurePosixPath(executable_path)
    if (
        str(executable) != executable_path
        or executable.name != EXPECTED_EXECUTABLE
        or executable.parent.name != "SkyBridgeCompass-iOS.app"
        or any(component in {".", ".."} for component in executable.parts)
    ):
        _fail("private iOS launch executable path is not canonical")
    installation = payload.get("installationBinding")
    expected_installation_keys = {
        "bundleIdentifier",
        "deviceIdentifier",
        "installationVerified",
        "iosReleaseArchive",
        "launchServicesIdentifier",
        "releaseBuild",
        "releaseVersion",
        "remoteApplicationPath",
        "schemaVersion",
    }
    if (
        not isinstance(installation, dict)
        or set(installation) != expected_installation_keys
        or installation.get("schemaVersion") != 1
        or installation.get("installationVerified") is not True
        or installation.get("bundleIdentifier") != EXPECTED_BUNDLE_IDENTIFIER
        or installation.get("remoteApplicationPath") != str(executable.parent)
    ):
        _fail("private iOS launch identity has an invalid installation binding")
    try:
        validate_archive_binding(installation.get("iosReleaseArchive"))
    except PhysicalAcceptanceError as exc:
        _fail(f"private iOS installation archive binding is invalid: {exc}")
    return payload


def _release_archive_binding(path: Path) -> dict[str, Any]:
    try:
        return expected_binding(load_identity(path))
    except ArchiveIdentityError as exc:
        _fail(f"sealed iOS archive identity is invalid: {exc}")


def _remote_image_path(value: object, line_number: int) -> str:
    if not isinstance(value, str):
        _fail(f"raw iOS OSLog line {line_number} has no processImagePath")
    if value.startswith("file://"):
        # Unified log currently emits a plain path for iOS processes.  Reject a
        # file URL instead of guessing percent-decoding or host authority rules.
        _fail(f"raw iOS OSLog line {line_number} uses an unsupported image URL")
    image = PurePosixPath(value)
    if not value.startswith("/") or str(image) != value:
        _fail(f"raw iOS OSLog line {line_number} has a non-canonical image path")
    return value


def _extract_messages(raw_path: Path, identity: dict[str, Any]) -> list[str]:
    content = _read_regular(raw_path, "private iOS OSLog NDJSON", MAX_INPUT_BYTES)
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as exc:
        _fail(f"private iOS OSLog NDJSON is not UTF-8: {exc}")
    messages: list[str] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line:
            _fail(f"raw iOS OSLog line {line_number} is empty")
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            _fail(f"raw iOS OSLog line {line_number} is invalid JSON: {exc}")
        if not isinstance(row, dict):
            _fail(f"raw iOS OSLog line {line_number} is not an object")
        if (
            row.get("eventType") != "logEvent"
            or row.get("messageType") != "Default"
            or row.get("subsystem") != SUBSYSTEM
            or row.get("category") != CATEGORY
            or row.get("processID") != identity["processIdentifier"]
            or _remote_image_path(row.get("processImagePath"), line_number)
            != identity["executablePath"]
        ):
            _fail(f"raw iOS OSLog line {line_number} is outside the exact capture boundary")
        format_string = row.get("formatString")
        message = row.get("eventMessage")
        if not isinstance(format_string, str) or "public" not in format_string:
            _fail(f"raw iOS OSLog line {line_number} was not emitted as public data")
        if not isinstance(message, str):
            _fail(f"raw iOS OSLog line {line_number} has no eventMessage")
        try:
            message.encode("ascii")
        except UnicodeEncodeError as exc:
            _fail(f"raw iOS OSLog line {line_number} is not ASCII: {exc}")
        event_name = message.split(" ", 1)[0]
        if event_name in IDENTITY_EVENT_NAMES:
            continue
        messages.append(message)
    if not messages or len(messages) > MAX_EVENT_COUNT:
        _fail(f"private iOS OSLog event count must be 1-{MAX_EVENT_COUNT}")
    return messages


def _atomic_new_file(path: Path, content: bytes) -> None:
    if path.exists() or path.is_symlink():
        _fail(f"output already exists: {path}")
    parent = path.parent.resolve(strict=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            descriptor = -1
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
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def bind_launch_identity(
    *,
    ownership_record: Path,
    installation_binding: Path,
    extracted_app: Path,
    start_time_token: str,
    output: Path,
) -> None:
    """Add the locally captured launch token to an exact devicectl identity."""

    if (
        START_TIME_PATTERN.fullmatch(start_time_token) is None
        or int(start_time_token.split(":", 1)[1]) >= 1_000_000
    ):
        _fail("launch start-time token is invalid")
    ownership = _load_json(ownership_record, "devicectl iOS ownership record", 32 * 1024)
    installation = _load_json(
        installation_binding,
        "verified iOS installation binding",
        64 * 1024,
    )
    expected_installation_keys = {
        "bundleIdentifier",
        "deviceIdentifier",
        "installationVerified",
        "iosReleaseArchive",
        "launchServicesIdentifier",
        "releaseBuild",
        "releaseVersion",
        "remoteApplicationPath",
        "schemaVersion",
    }
    if (
        set(installation) != expected_installation_keys
        or installation.get("schemaVersion") != 1
        or installation.get("installationVerified") is not True
        or installation.get("bundleIdentifier") != EXPECTED_BUNDLE_IDENTIFIER
    ):
        _fail("verified iOS installation binding has an invalid schema")
    try:
        validate_archive_binding(installation.get("iosReleaseArchive"))
    except PhysicalAcceptanceError as exc:
        _fail(f"verified iOS installation archive binding is invalid: {exc}")
    expected_ownership_keys = {
        "auditToken",
        "bundleName",
        "executableName",
        "executablePath",
        "platform",
        "processIdentifier",
        "schemaVersion",
    }
    if set(ownership) != expected_ownership_keys:
        _fail("devicectl iOS ownership record has an unexpected field set")
    if not extracted_app.is_absolute() or extracted_app.is_symlink() or not extracted_app.is_dir():
        _fail("extracted release-testing app must be an absolute real directory")
    info_path = extracted_app / "Info.plist"
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        _fail(f"extracted release-testing app Info.plist is invalid: {exc}")
    if not isinstance(info, dict):
        _fail("extracted release-testing app Info.plist must be a dictionary")
    bundle_identifier = info.get("CFBundleIdentifier")
    executable_name = info.get("CFBundleExecutable")
    if (
        bundle_identifier != EXPECTED_BUNDLE_IDENTIFIER
        or executable_name != EXPECTED_EXECUTABLE
        or not (extracted_app / EXPECTED_EXECUTABLE).is_file()
        or info.get("CFBundleShortVersionString") != installation.get("releaseVersion")
        or info.get("CFBundleVersion") != installation.get("releaseBuild")
    ):
        _fail("extracted release-testing app has an unexpected product identity")
    if (
        ownership.get("schemaVersion") != 1
        or ownership.get("platform") != "ios"
        or ownership.get("bundleName") != extracted_app.name
        or ownership.get("executableName") != EXPECTED_EXECUTABLE
    ):
        _fail("devicectl ownership record does not match the release-testing app")
    process_id = ownership.get("processIdentifier")
    audit_token = ownership.get("auditToken")
    if (
        isinstance(process_id, bool)
        or not isinstance(process_id, int)
        or process_id <= 1
        or not isinstance(audit_token, list)
        or len(audit_token) != 8
        or audit_token[5] != process_id
    ):
        _fail("devicectl ownership record has an invalid process/audit-token binding")
    ownership_executable = ownership.get("executablePath")
    if (
        not isinstance(ownership_executable, str)
        or str(PurePosixPath(ownership_executable).parent)
        != installation.get("remoteApplicationPath")
    ):
        _fail("launched executable does not belong to the verified installed product")
    payload = dict(ownership)
    payload["bundleIdentifier"] = bundle_identifier
    payload["installationBinding"] = installation
    payload["startTimeToken"] = start_time_token
    _atomic_new_file(
        output,
        (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8"),
    )
    _validate_private_launch_identity(output)


def validate_installation_capture(
    path: Path,
    *,
    expected_archive_binding: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Validate the public, privacy-safe install/fresh-launch binding."""

    payload = _load_json(path, "iOS product installation capture", 64 * 1024)
    expected_keys = {
        "bundleIdentifier",
        "candidateIdentityFile",
        "candidateIdentityVerified",
        "freshLaunchVerified",
        "installationReceiptVerified",
        "installedApplicationVerified",
        "iosReleaseArchive",
        "launchPersistentIdentifierVerified",
        "platform",
        "preLaunchAbsenceVerified",
        "processExecutable",
        "processID",
        "processOwnershipVerified",
        "profile",
        "releaseArchiveBindingVerified",
        "releaseBuild",
        "releaseVersion",
        "schemaVersion",
        "startTimeToken",
    }
    if set(payload) != expected_keys:
        _fail("iOS product installation capture has an unexpected field set")
    exact_values = {
        "bundleIdentifier": EXPECTED_BUNDLE_IDENTIFIER,
        "candidateIdentityFile": "release-acceptance.json",
        "candidateIdentityVerified": True,
        "freshLaunchVerified": True,
        "installationReceiptVerified": True,
        "installedApplicationVerified": True,
        "launchPersistentIdentifierVerified": True,
        "platform": "ios",
        "preLaunchAbsenceVerified": True,
        "processExecutable": EXPECTED_EXECUTABLE,
        "processOwnershipVerified": True,
        "profile": INSTALLATION_CAPTURE_PROFILE,
        "releaseArchiveBindingVerified": True,
        "schemaVersion": 1,
    }
    for key, expected in exact_values.items():
        if payload.get(key) != expected:
            _fail(f"iOS product installation capture {key} mismatch")
    process_id = payload.get("processID")
    if isinstance(process_id, bool) or not isinstance(process_id, int) or process_id <= 1:
        _fail("iOS product installation capture processID must be greater than one")
    start_time = payload.get("startTimeToken")
    if (
        not isinstance(start_time, str)
        or START_TIME_PATTERN.fullmatch(start_time) is None
        or int(start_time.split(":", 1)[1]) >= 1_000_000
    ):
        _fail("iOS product installation capture startTimeToken is invalid")
    version = payload.get("releaseVersion")
    build = payload.get("releaseBuild")
    if (
        not isinstance(version, str)
        or re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version)
        is None
        or not isinstance(build, str)
        or re.fullmatch(r"[1-9][0-9]*", build) is None
    ):
        _fail("iOS product installation capture release version/build is invalid")
    try:
        binding = validate_archive_binding(payload.get("iosReleaseArchive"))
    except PhysicalAcceptanceError as exc:
        _fail(f"iOS product installation capture archive binding is invalid: {exc}")
    if expected_archive_binding is not None and binding != expected_archive_binding:
        _fail("iOS product installation capture archive binding mismatch")
    return payload


def write_installation_capture(
    *,
    prelaunch_processes: Path,
    launch_identity: Path,
    extracted_app: Path,
    archive_identity: Path,
    output: Path,
) -> None:
    """Derive a public capture from private install, absence, and launch proofs."""

    identity = _validate_private_launch_identity(launch_identity)
    binding = _release_archive_binding(archive_identity)
    installation = identity["installationBinding"]
    if installation.get("iosReleaseArchive") != binding:
        _fail("launch installation and release manifest bind different archives")
    presence = process_ownership.ios_presence(prelaunch_processes, extracted_app)
    if presence != process_ownership.ABSENT:
        _fail("pre-launch process snapshot does not prove exact app absence")
    capture = {
        "bundleIdentifier": EXPECTED_BUNDLE_IDENTIFIER,
        "candidateIdentityFile": "release-acceptance.json",
        "candidateIdentityVerified": True,
        "freshLaunchVerified": True,
        "installationReceiptVerified": True,
        "installedApplicationVerified": True,
        "iosReleaseArchive": binding,
        "launchPersistentIdentifierVerified": True,
        "platform": "ios",
        "preLaunchAbsenceVerified": True,
        "processExecutable": EXPECTED_EXECUTABLE,
        "processID": identity["processIdentifier"],
        "processOwnershipVerified": True,
        "profile": INSTALLATION_CAPTURE_PROFILE,
        "releaseArchiveBindingVerified": True,
        "releaseBuild": installation["releaseBuild"],
        "releaseVersion": installation["releaseVersion"],
        "schemaVersion": 1,
        "startTimeToken": identity["startTimeToken"],
    }
    _atomic_new_file(
        output,
        (json.dumps(capture, indent=2, sort_keys=True) + "\n").encode("utf-8"),
    )
    validate_installation_capture(output, expected_archive_binding=binding)


def extract(
    *,
    raw_oslog: Path,
    launch_identity: Path,
    archive_identity: Path,
    output_log: Path,
    output_capture: Path,
) -> None:
    identity = _validate_private_launch_identity(launch_identity)
    binding = _release_archive_binding(archive_identity)
    if identity["installationBinding"].get("iosReleaseArchive") != binding:
        _fail("launch installation and release manifest bind different archives")
    messages = _extract_messages(raw_oslog, identity)
    canonical_log = ("\n".join(messages) + "\n").encode("ascii")
    capture = {
        "bundleIdentifier": EXPECTED_BUNDLE_IDENTIFIER,
        "candidateIdentityFile": "release-acceptance.json",
        "candidateIdentityVerified": True,
        "captureMode": IOS_CAPTURE_MODE,
        "category": CATEGORY,
        "eventCount": len(messages),
        "iosReleaseArchive": binding,
        "ownershipVerified": True,
        "platform": "ios",
        "processExecutable": EXPECTED_EXECUTABLE,
        "processID": identity["processIdentifier"],
        "profile": CAPTURE_PROFILE,
        "releaseArchiveBindingVerified": True,
        "schemaVersion": 1,
        "startTimeToken": identity["startTimeToken"],
        "subsystem": SUBSYSTEM,
    }
    _atomic_new_file(output_log, canonical_log)
    try:
        # Reuse the frozen parser before publishing the matching capture file.
        parse_canonical_log(output_log, expected_owner=IOS_PRODUCT)
        _atomic_new_file(
            output_capture,
            (json.dumps(capture, indent=2, sort_keys=True) + "\n").encode("utf-8"),
        )
    except BaseException:
        output_log.unlink(missing_ok=True)
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    bind = subparsers.add_parser("bind-launch")
    bind.add_argument("--ownership-record", type=Path, required=True)
    bind.add_argument("--installation-binding", type=Path, required=True)
    bind.add_argument("--extracted-app", type=Path, required=True)
    bind.add_argument("--start-time-token", required=True)
    bind.add_argument("--output", type=Path, required=True)
    extract_parser = subparsers.add_parser("extract")
    extract_parser.add_argument("--raw-oslog", type=Path, required=True)
    extract_parser.add_argument("--launch-identity", type=Path, required=True)
    extract_parser.add_argument("--archive-identity", type=Path, required=True)
    extract_parser.add_argument("--output-log", type=Path, required=True)
    extract_parser.add_argument("--output-capture", type=Path, required=True)
    installation_capture = subparsers.add_parser("installation-capture")
    installation_capture.add_argument("--prelaunch-processes", type=Path, required=True)
    installation_capture.add_argument("--launch-identity", type=Path, required=True)
    installation_capture.add_argument("--extracted-app", type=Path, required=True)
    installation_capture.add_argument("--archive-identity", type=Path, required=True)
    installation_capture.add_argument("--output", type=Path, required=True)
    validate_installation = subparsers.add_parser("validate-installation-capture")
    validate_installation.add_argument("--capture", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        if arguments.command == "bind-launch":
            bind_launch_identity(
                ownership_record=arguments.ownership_record,
                installation_binding=arguments.installation_binding,
                extracted_app=arguments.extracted_app,
                start_time_token=arguments.start_time_token,
                output=arguments.output,
            )
            print(f"iOS product launch identity bound: {arguments.output}")
            return 0
        if arguments.command == "installation-capture":
            write_installation_capture(
                prelaunch_processes=arguments.prelaunch_processes,
                launch_identity=arguments.launch_identity,
                extracted_app=arguments.extracted_app,
                archive_identity=arguments.archive_identity,
                output=arguments.output,
            )
            print(f"iOS product installation capture written: {arguments.output}")
            return 0
        if arguments.command == "validate-installation-capture":
            validate_installation_capture(arguments.capture)
            print(f"iOS product installation capture valid: {arguments.capture}")
            return 0
        extract(
            raw_oslog=arguments.raw_oslog,
            launch_identity=arguments.launch_identity,
            archive_identity=arguments.archive_identity,
            output_log=arguments.output_log,
            output_capture=arguments.output_capture,
        )
    except (IOSProductEvidenceError, OSError) as exc:
        print(f"iOS product evidence rejected: {exc}", file=os.sys.stderr)
        return 1
    print(f"iOS product release evidence extracted: {arguments.output_log}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
