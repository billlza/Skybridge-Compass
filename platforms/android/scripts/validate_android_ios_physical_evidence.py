#!/usr/bin/env python3
"""Validate exact physical-iOS smoke transactions and emit typed evidence.

SHA-256 values in this evidence are Level-1 reliability bindings used to detect
accidental cross-build, cross-device, or cross-run mismatch. They are not
signatures and do not defend against a malicious host account.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import stat
import tempfile
import urllib.parse
import uuid
from pathlib import Path, PurePosixPath
from typing import Any, NoReturn


MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_TEXT_BYTES = 8 * 1024 * 1024
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z", re.ASCII)
SOURCE_COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}\Z", re.ASCII)
EXPECTED_BUNDLE_ID = "com.skybridge.compass.ios"
EXPECTED_ANDROID_APP_PACKAGE = "com.skybridge.compass.debug"
EXPECTED_ANDROID_TEST_PACKAGE = "com.skybridge.compass.debug.ioswebrtc.test"
SUITE_WIRE_ID_PATTERN = re.compile(r"0x[0-9a-f]{4}\Z", re.ASCII)
ANDROID_SUITE_NAMES = {
    "0x0001": "X_WING",
    "0x0011": "Q_PERIAPT_CONTEXT_BOUND",
    "0x0101": "MLKEM_768",
    "0x0102": "MLKEM_768_FS_COMPAT",
    "0x1001": "X25519",
    "0x1002": "P256",
}
IOS_SUITE_NAMES = {
    "0x0001": {"X-Wing"},
    "0x0011": {"Q-Periapt-ContextBound", "Q-Periapt-ContextBound+ML-DSA-65"},
    "0x0101": {"ML-KEM-768"},
    "0x0102": {"ML-KEM-768-FS"},
    "0x1001": {"X25519"},
    "0x1002": {"P-256"},
}
IOS_STATUS_TERMINAL_PATTERN = re.compile(
    r"^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+-]+Z?\] "
    r"(success session_ref=\S+(?: \S+=\S+)+)$",
    re.ASCII,
)


def _canonical_transfer_id(value: object, label: str) -> str:
    transfer_id = _nonempty_string(value, label)
    try:
        parsed = uuid.UUID(transfer_id)
    except ValueError:
        _fail(f"{label} is not a canonical UUID")
    if str(parsed) != transfer_id:
        _fail(f"{label} is not a canonical UUID")
    return transfer_id


def _formal_payload(
    direction: str, run_ref: str, session_ref: str, transfer_id: str
) -> bytes:
    if direction not in {"android-to-peer", "peer-to-android"}:
        _fail("formal file-transfer direction is invalid")
    _canonical_transfer_id(transfer_id, "formal transfer identifier")
    return (
        "skybridge-formal-p2p-file-v1\n"
        f"direction={direction}\n"
        f"runRef={run_ref}\n"
        f"sessionRef={session_ref}\n"
        f"transferId={transfer_id}\n"
    ).encode("ascii")


class PhysicalEvidenceError(RuntimeError):
    """A physical-device transaction is incomplete, ambiguous, or mismatched."""


def _fail(message: str) -> NoReturn:
    raise PhysicalEvidenceError(message)


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise PhysicalEvidenceError(f"JSON object contains duplicate key: {key}")
        value[key] = item
    return value


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


def _load_json_value(path: Path, label: str) -> object:
    try:
        payload = json.loads(
            _read_regular(path, label, MAX_JSON_BYTES).decode("utf-8"),
            object_pairs_hook=_unique_json_object,
            parse_constant=lambda value: _fail(f"{label} contains non-finite number: {value}"),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(f"{label} is invalid UTF-8 JSON: {exc}")
    return payload


def _load_json(path: Path, label: str) -> dict[str, Any]:
    payload = _load_json_value(path, label)
    if not isinstance(payload, dict):
        _fail(f"{label} must be a JSON object")
    return payload


def _load_text(path: Path, label: str) -> str:
    try:
        return _read_regular(path, label, MAX_TEXT_BYTES).decode("utf-8")
    except UnicodeDecodeError as exc:
        _fail(f"{label} is not UTF-8: {exc}")


def _mapping(value: object) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _nested(value: object, *keys: str) -> object:
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def _nonempty_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        _fail(f"{label} is missing")
    return value.strip()


def _exact_schema_version(value: object, expected: int, label: str) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or value != expected:
        _fail(f"{label} has an invalid schema version")


def _identifier_ref(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]


def _launch_services_identifier(value: object) -> str:
    identifier = _nonempty_string(value, "launch services identifier")
    if len(identifier) > 4096:
        _fail("launch services identifier exceeds the bounded size")
    try:
        decoded = base64.b64decode(identifier, validate=True)
    except ValueError as exc:
        _fail(f"launch services identifier is not canonical base64: {exc}")
    if not decoded:
        _fail("launch services identifier decodes to no data")
    if base64.b64encode(decoded).decode("ascii") != identifier:
        _fail("launch services identifier is not canonical base64")
    return identifier


def _strict_unquote_path(value: str, label: str) -> str:
    if re.search(r"%(?![0-9A-Fa-f]{2})", value):
        _fail(f"{label} contains an invalid percent escape")
    try:
        decoded = urllib.parse.unquote_to_bytes(value).decode("utf-8")
    except UnicodeDecodeError as exc:
        _fail(f"{label} is not canonical UTF-8: {exc}")
    if urllib.parse.quote(decoded, safe="/-._~") != value:
        _fail(f"{label} is not canonically percent-encoded")
    return decoded


def _devicectl_result(payload: dict[str, Any], command_type: str, label: str) -> dict[str, Any]:
    if set(payload) != {"info", "result"}:
        _fail(f"{label} has an unexpected top-level schema")
    info = payload.get("info")
    result = payload.get("result")
    if (
        not isinstance(info, dict)
        or info.get("commandType") != command_type
        or info.get("outcome") != "success"
        or isinstance(info.get("jsonVersion"), bool)
        or not isinstance(info.get("jsonVersion"), int)
        or info["jsonVersion"] < 1
        or not isinstance(result, dict)
    ):
        _fail(f"{label} is not one successful {command_type} result")
    return result


def _atomic_new(path: Path, payload: dict[str, Any]) -> None:
    if not path.is_absolute() or path.exists() or path.is_symlink():
        _fail("evidence output must be a new absolute path")
    parent = path.parent.resolve(strict=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", closefd=True) as handle:
            descriptor = -1
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary, path, follow_symlinks=False)
        except FileExistsError:
            _fail("evidence output appeared while publishing")
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


def validate_device(
    devicectl_path: Path,
    xcdevice_path: Path,
    expected_device_id: str,
    expected_udid: str,
) -> dict[str, Any]:
    devicectl = _load_json(devicectl_path, "devicectl device list")
    result = _devicectl_result(
        devicectl, "devicectl.list.devices", "devicectl device list"
    )
    devices = result.get("devices")
    if not isinstance(devices, list):
        _fail("devicectl device list omitted devices")
    matches = [
        device
        for device in devices
        if isinstance(device, dict) and device.get("identifier") == expected_device_id
    ]
    if len(matches) != 1:
        _fail("devicectl did not return exactly one requested device")
    device = matches[0]
    connection = _mapping(device.get("connectionProperties"))
    hardware = _mapping(device.get("hardwareProperties"))
    properties = _mapping(device.get("deviceProperties"))
    if (
        connection.get("pairingState") != "paired"
        or connection.get("tunnelState") != "connected"
        or properties.get("bootState") != "booted"
        or properties.get("developerModeStatus") != "enabled"
        or hardware.get("platform") != "iOS"
        or str(hardware.get("reality", "")).lower() != "physical"
    ):
        _fail("requested CoreDevice is not one paired, connected, booted physical iOS device")
    discovered_udids = [
        value
        for value in (hardware.get("udid"), properties.get("udid"))
        if value is not None
    ]
    if (
        not discovered_udids
        or any(
            not isinstance(value, str) or value != expected_udid
            for value in discovered_udids
        )
    ):
        _fail("devicectl physical UDID does not match the requested xcdevice UDID")

    xcdevices = _load_json_value(xcdevice_path, "xcdevice list")
    if not isinstance(xcdevices, list):
        _fail("xcdevice list must be a JSON array")
    xc_matches = [
        entry
        for entry in xcdevices
        if isinstance(entry, dict) and entry.get("identifier") == expected_udid
    ]
    if len(xc_matches) != 1:
        _fail("xcdevice did not return exactly one requested physical UDID")
    xcdevice = xc_matches[0]
    platform = xcdevice.get("platform")
    if (
        xcdevice.get("simulator") is not False
        or xcdevice.get("available") is not True
        or not isinstance(platform, str)
        or platform.lower()
        not in {"iphoneos", "com.apple.platform.iphoneos"}
    ):
        _fail("requested xcdevice target is not one available physical iOS device")

    return {
        "coreDeviceIdentifier": expected_device_id,
        "coreDeviceIdentifierRef": _identifier_ref(expected_device_id),
        "deviceType": hardware.get("deviceType"),
        "deviceUdid": expected_udid,
        "deviceUdidRef": _identifier_ref(expected_udid),
        "osVersion": properties.get("osVersionNumber"),
        "physical": True,
        "platform": "iOS",
        "schemaVersion": 1,
    }


def _load_properties(path: Path, label: str) -> dict[str, str]:
    text = _load_text(path, label)
    result: dict[str, str] = {}
    for line in text.splitlines():
        if not line or "=" not in line:
            _fail(f"{label} contains a malformed property")
        key, value = line.split("=", 1)
        if not key or key in result:
            _fail(f"{label} contains a duplicate or empty key")
        result[key] = value
    return result


def _remote_app_path(raw_url: object) -> str:
    if not isinstance(raw_url, str):
        _fail("installed iOS application URL is missing")
    parsed = urllib.parse.urlparse(raw_url)
    if (
        parsed.scheme != "file"
        or parsed.netloc not in {"", "localhost"}
        or parsed.params
        or parsed.query
        or parsed.fragment
    ):
        _fail("installed iOS application URL must be a local file URL")
    path = _strict_unquote_path(parsed.path, "installed iOS application URL path").rstrip("/")
    return _canonical_remote_app_path(path)


def _canonical_remote_app_path(path: str) -> str:
    normalized = str(PurePosixPath(path))
    if (
        normalized != path
        or not normalized.startswith("/private/var/containers/Bundle/Application/")
        or not normalized.endswith(".app")
        or any(part in {".", ".."} for part in PurePosixPath(normalized).parts)
    ):
        _fail("installed iOS application URL is outside the app bundle container")
    return normalized


def validate_installation(
    device_binding_path: Path,
    install_path: Path,
    apps_path: Path,
    app_provenance_path: Path,
) -> dict[str, Any]:
    device = _load_json(device_binding_path, "physical device binding")
    expected_device_fields = {
        "coreDeviceIdentifier",
        "coreDeviceIdentifierRef",
        "deviceType",
        "deviceUdid",
        "deviceUdidRef",
        "osVersion",
        "physical",
        "platform",
        "schemaVersion",
    }
    _exact_schema_version(device.get("schemaVersion"), 1, "physical device binding")
    if (
        set(device) != expected_device_fields
        or device.get("physical") is not True
        or device.get("platform") != "iOS"
    ):
        _fail("physical device binding is invalid")
    device_id = _nonempty_string(device.get("coreDeviceIdentifier"), "CoreDevice identifier")
    device_udid = _nonempty_string(device.get("deviceUdid"), "physical device UDID")
    if (
        device.get("coreDeviceIdentifierRef") != _identifier_ref(device_id)
        or device.get("deviceUdidRef") != _identifier_ref(device_udid)
        or not isinstance(device.get("deviceType"), str)
        or not device["deviceType"].strip()
        or not isinstance(device.get("osVersion"), str)
        or not device["osVersion"].strip()
    ):
        _fail("physical device binding identifiers or metadata are invalid")
    provenance = _load_properties(app_provenance_path, "iOS app provenance")
    prefix = "ios_physical_app"
    required = {
        f"{prefix}_bundle_id",
        f"{prefix}_version",
        f"{prefix}_build",
        f"{prefix}_executable",
        f"{prefix}_executable_sha256",
        f"{prefix}_tree_sha256",
        f"{prefix}_file_count",
        f"{prefix}_bytes",
        f"{prefix}_path",
    }
    if set(provenance) != required:
        _fail("iOS app provenance field set is invalid")
    if provenance[f"{prefix}_bundle_id"] != EXPECTED_BUNDLE_ID:
        _fail("iOS app provenance identifies a different bundle")
    for key in (f"{prefix}_executable_sha256", f"{prefix}_tree_sha256"):
        if SHA256_PATTERN.fullmatch(provenance[key]) is None:
            _fail("iOS app provenance digest is malformed")
    if not provenance[f"{prefix}_file_count"].isdigit() or int(
        provenance[f"{prefix}_file_count"]
    ) <= 0:
        _fail("iOS app provenance file count is invalid")
    if not provenance[f"{prefix}_bytes"].isdigit() or int(provenance[f"{prefix}_bytes"]) <= 0:
        _fail("iOS app provenance byte count is invalid")

    install = _devicectl_result(
        _load_json(install_path, "devicectl install result"),
        "devicectl.device.install.app",
        "devicectl install result",
    )
    if install.get("deviceIdentifier") != device_id:
        _fail("devicectl installation targeted a different device")
    installed = install.get("installedApplications")
    if not isinstance(installed, list) or len(installed) != 1 or not isinstance(installed[0], dict):
        _fail("devicectl installation must report exactly one application")
    if installed[0].get("bundleIdentifier") != EXPECTED_BUNDLE_ID:
        _fail("devicectl installed a different bundle")
    launch_identifier = _launch_services_identifier(
        installed[0].get("launchServicesIdentifier")
    )

    query = _devicectl_result(
        _load_json(apps_path, "devicectl installed-app query"),
        "devicectl.device.info.apps",
        "devicectl installed-app query",
    )
    if (
        query.get("deviceIdentifier") != device_id
        or query.get("matchingBundleIdentifier") != EXPECTED_BUNDLE_ID
    ):
        _fail("installed-app query is bound to a different device or bundle")
    apps = query.get("apps")
    if not isinstance(apps, list) or len(apps) != 1 or not isinstance(apps[0], dict):
        _fail("installed-app query must return exactly one application")
    app = apps[0]
    installed_version = _nonempty_string(app.get("version"), "installed iOS app version")
    installed_build = _nonempty_string(
        app.get("bundleVersion"), "installed iOS app build"
    )
    if (
        app.get("bundleIdentifier") != EXPECTED_BUNDLE_ID
        or installed_version != provenance[f"{prefix}_version"]
        or installed_build != provenance[f"{prefix}_build"]
        or app.get("builtByDeveloper") is not True
    ):
        _fail("installed iOS product version/build does not match the frozen app")

    return {
        "bundleIdentifier": EXPECTED_BUNDLE_ID,
        "coreDeviceIdentifier": device_id,
        "coreDeviceIdentifierRef": device["coreDeviceIdentifierRef"],
        "deviceUdid": device["deviceUdid"],
        "deviceUdidRef": device["deviceUdidRef"],
        "installationMode": "overlay-preserve-data",
        "installationVerified": True,
        "launchServicesIdentifier": launch_identifier,
        "remoteApplicationPath": _remote_app_path(app.get("url")),
        "schemaVersion": 1,
        "sourceApp": {
            "build": provenance[f"{prefix}_build"],
            "bytes": int(provenance[f"{prefix}_bytes"]),
            "executable": provenance[f"{prefix}_executable"],
            "executableSHA256": provenance[f"{prefix}_executable_sha256"],
            "fileCount": int(provenance[f"{prefix}_file_count"]),
            "treeSHA256": provenance[f"{prefix}_tree_sha256"],
            "version": provenance[f"{prefix}_version"],
        },
    }


def _artifact_properties(path: Path, prefix: str) -> dict[str, object]:
    properties = _load_properties(path, f"{prefix} provenance")
    expected = {f"{prefix}_path", f"{prefix}_sha256", f"{prefix}_bytes"}
    if set(properties) != expected:
        _fail(f"{prefix} provenance field set is invalid")
    digest = properties[f"{prefix}_sha256"]
    byte_count = properties[f"{prefix}_bytes"]
    if SHA256_PATTERN.fullmatch(digest) is None or not byte_count.isdigit() or int(byte_count) <= 0:
        _fail(f"{prefix} provenance is malformed")
    return {"bytes": int(byte_count), "sha256": digest}


def _process_executable_path(raw_url: object) -> str:
    if not isinstance(raw_url, str):
        _fail("launched iOS process executable URL is missing")
    parsed = urllib.parse.urlparse(raw_url)
    if (
        parsed.scheme != "file"
        or parsed.netloc not in {"", "localhost"}
        or parsed.params
        or parsed.query
        or parsed.fragment
    ):
        _fail("launched iOS process executable must be a local file URL")
    path = _strict_unquote_path(parsed.path, "launched iOS process executable path")
    normalized = str(PurePosixPath(path))
    if normalized != path or any(part in {".", ".."} for part in PurePosixPath(path).parts):
        _fail("launched iOS process executable path is not canonical")
    return normalized


def _validate_process_identity(
    identity_path: Path,
    process_identifier: int,
    audit_token: list[int],
    expected_executable: str,
) -> None:
    identity = _load_json(identity_path, "captured iOS process identity")
    required = {
        "auditToken",
        "bundleName",
        "executableName",
        "executablePath",
        "platform",
        "processIdentifier",
        "schemaVersion",
    }
    identity_pid = identity.get("processIdentifier")
    identity_token = identity.get("auditToken")
    schema_version = identity.get("schemaVersion")
    if (
        set(identity) != required
        or isinstance(schema_version, bool)
        or not isinstance(schema_version, int)
        or schema_version != 1
        or identity["platform"] != "ios"
        or isinstance(identity_pid, bool)
        or not isinstance(identity_pid, int)
        or identity_pid != process_identifier
        or not isinstance(identity_token, list)
        or len(identity_token) != 8
        or any(
            isinstance(value, bool)
            or not isinstance(value, int)
            or value < 0
            or value > 0xFFFFFFFF
            for value in identity_token
        )
        or identity_token != audit_token
        or identity["executablePath"] != expected_executable
        or identity["executableName"] != PurePosixPath(expected_executable).name
        or identity["bundleName"] != PurePosixPath(expected_executable).parent.name
    ):
        _fail("captured iOS process identity does not match the installed launch")


def _android_device_binding(path: Path, label: str) -> dict[str, str]:
    properties = _load_properties(path, label)
    expected = {
        "schema_version",
        "profile",
        "serial_ref",
        "model_ref",
        "manufacturer",
        "release",
        "sdk",
        "abi",
        "qemu",
        "page_size",
    }
    if set(properties) != expected or properties["schema_version"] != "1":
        _fail(f"{label} has an invalid field set")
    if (
        properties["profile"] != "samsung-physical-4k"
        or properties["manufacturer"] != "samsung"
        or properties["abi"] != "arm64-v8a"
        or properties["qemu"] != "0"
        or properties["page_size"] != "4096"
        or re.fullmatch(r"sha256:[0-9a-f]{16}", properties["serial_ref"]) is None
        or re.fullmatch(r"sha256:[0-9a-f]{16}", properties["model_ref"]) is None
        or not properties["sdk"].isdigit()
        or int(properties["sdk"]) < 36
    ):
        _fail(f"{label} is not the formal Samsung physical 4K profile")
    return properties


def _require_android_device_unchanged(before_path: Path, after_path: Path) -> dict[str, str]:
    before = _android_device_binding(before_path, "Android device before binding")
    after = _android_device_binding(after_path, "Android device after binding")
    if before != after:
        _fail("Android physical device binding changed during the run")
    return before


def _require_source_unchanged(
    before_path: Path, after_path: Path, expected_commit: str
) -> dict[str, str]:
    before = _load_properties(before_path, "source before binding")
    after = _load_properties(after_path, "source after binding")
    required = {"schema_version", "phase", "source_commit", "source_tree", "worktree_clean"}
    if set(before) != required or set(after) != required:
        _fail("source phase binding has an invalid field set")
    if (
        before["schema_version"] != "1"
        or after["schema_version"] != "1"
        or before["phase"] != "before"
        or after["phase"] != "after"
        or before["source_commit"] != expected_commit
        or after["source_commit"] != expected_commit
        or before["source_tree"] != after["source_tree"]
        or SOURCE_COMMIT_PATTERN.fullmatch(before["source_tree"]) is None
        or before["worktree_clean"] != "true"
        or after["worktree_clean"] != "true"
    ):
        _fail("source phase binding is incomplete or changed during the run")
    return before


def _require_installed_apks_unchanged(
    before_path: Path,
    after_path: Path,
    app_apk: dict[str, object],
    test_apk: dict[str, object],
    serial_ref: str,
) -> None:
    before = _load_properties(before_path, "installed Android APK before binding")
    after = _load_properties(after_path, "installed Android APK after binding")
    expected_keys = {
        f"{prefix}_{suffix}"
        for prefix in ("app", "test")
        for suffix in ("package", "sha256", "serial_ref", "remote_path_ref")
    }
    if set(before) != expected_keys or before != after:
        _fail("installed Android APK binding is invalid or changed during the run")
    expectations = (
        ("app", EXPECTED_ANDROID_APP_PACKAGE, app_apk["sha256"]),
        ("test", EXPECTED_ANDROID_TEST_PACKAGE, test_apk["sha256"]),
    )
    for prefix, package, digest in expectations:
        if (
            before[f"{prefix}_package"] != package
            or before[f"{prefix}_sha256"] != digest
            or before[f"{prefix}_serial_ref"] != serial_ref
            or re.fullmatch(
                r"sha256:[0-9a-f]{16}", before[f"{prefix}_remote_path_ref"]
            )
            is None
        ):
            _fail("installed Android APK binding does not match the frozen artifact/device")


def _terminal_fields(line: str, prefix: str) -> dict[str, str]:
    if not line.startswith(prefix):
        _fail("terminal evidence has the wrong prefix")
    fields: dict[str, str] = {}
    for token in line[len(prefix) :].strip().split():
        if "=" not in token:
            _fail("terminal evidence contains a token without an assignment")
        key, value = token.split("=", 1)
        if not key or not value or key in fields:
            _fail("terminal evidence contains an empty or duplicate field")
        fields[key] = value
    return fields


def _matching_phase_digest(text: str, marker: str, label: str) -> str:
    pattern = re.compile(
        rf"(?:^|\s){re.escape(marker)} phase=(before|after) digest=([0-9a-f]{{64}})\s*$"
    )
    by_phase: dict[str, list[str]] = {"before": [], "after": []}
    for line in text.splitlines():
        match = pattern.search(line)
        if match:
            by_phase[match.group(1)].append(match.group(2))
    if len(by_phase["before"]) != 1 or len(by_phase["after"]) != 1:
        _fail(f"{label} must contain one before and one after sensitive-state digest")
    if by_phase["before"][0] != by_phase["after"][0]:
        _fail(f"{label} sensitive-state digest changed during the run")
    return by_phase["before"][0]


def _ios_container_snapshot(path: Path, label: str) -> dict[str, str]:
    properties = _load_properties(path, label)
    expected_labels = (
        "user_defaults",
        "trusted_devices",
        "pairing_policy",
        "transfer_history",
    )
    expected = {"schema_version"}
    for item in expected_labels:
        expected.update({f"{item}_bytes", f"{item}_sha256"})
    if set(properties) != expected or properties["schema_version"] != "1":
        _fail(f"{label} has an invalid field set")
    for item in expected_labels:
        byte_count = properties[f"{item}_bytes"]
        digest = properties[f"{item}_sha256"]
        if not byte_count.isdigit() or int(byte_count) <= 0:
            _fail(f"{label} has an invalid {item} byte count")
        if SHA256_PATTERN.fullmatch(digest) is None:
            _fail(f"{label} has an invalid {item} digest")
    return properties


def _require_ios_container_unchanged(before_path: Path, after_path: Path) -> str:
    before = _ios_container_snapshot(before_path, "iOS sensitive-state before snapshot")
    after = _ios_container_snapshot(after_path, "iOS sensitive-state after snapshot")
    if before != after:
        _fail("iOS app-container identity/trust state changed during the run")
    canonical = "\n".join(f"{key}={before[key]}" for key in sorted(before))
    return hashlib.sha256(canonical.encode("ascii")).hexdigest()


def validate_receipt(arguments: argparse.Namespace) -> dict[str, Any]:
    if SOURCE_COMMIT_PATTERN.fullmatch(arguments.source_commit) is None:
        _fail("source commit must be a full lowercase Git revision")
    if SHA256_PATTERN.fullmatch(arguments.run_ref) is None:
        _fail("run reference must be a lowercase SHA-256 digest")
    source_binding = _require_source_unchanged(
        arguments.source_binding_before,
        arguments.source_binding_after,
        arguments.source_commit,
    )
    installation = _load_json(arguments.installation_binding, "installation binding")
    expected_installation_fields = {
        "bundleIdentifier",
        "coreDeviceIdentifier",
        "coreDeviceIdentifierRef",
        "deviceUdid",
        "deviceUdidRef",
        "installationMode",
        "installationVerified",
        "launchServicesIdentifier",
        "remoteApplicationPath",
        "schemaVersion",
        "sourceApp",
    }
    _exact_schema_version(
        installation.get("schemaVersion"), 1, "installation binding"
    )
    installation_device_id = _nonempty_string(
        installation.get("coreDeviceIdentifier"), "installed CoreDevice identifier"
    )
    installation_udid = _nonempty_string(
        installation.get("deviceUdid"), "installed physical device UDID"
    )
    if (
        set(installation) != expected_installation_fields
        or installation.get("installationMode") != "overlay-preserve-data"
        or installation.get("installationVerified") is not True
        or installation.get("bundleIdentifier") != EXPECTED_BUNDLE_ID
        or installation.get("coreDeviceIdentifierRef")
        != _identifier_ref(installation_device_id)
        or installation.get("deviceUdidRef") != _identifier_ref(installation_udid)
    ):
        _fail("installation binding is invalid")
    source_app = _mapping(installation.get("sourceApp"))
    if set(source_app) != {
        "build",
        "bytes",
        "executable",
        "executableSHA256",
        "fileCount",
        "treeSHA256",
        "version",
    }:
        _fail("installation binding source app is invalid")
    for field in ("bytes", "fileCount"):
        value = source_app.get(field)
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            _fail("installation binding source app is invalid")
    for field in ("executableSHA256", "treeSHA256"):
        value = source_app.get(field)
        if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
            _fail("installation binding source app is invalid")
    _nonempty_string(source_app.get("build"), "frozen iOS build")
    _nonempty_string(source_app.get("version"), "frozen iOS version")
    source_executable = _nonempty_string(
        source_app.get("executable"), "frozen iOS executable name"
    )
    if "/" in source_executable or source_executable in {".", ".."}:
        _fail("frozen iOS executable name is invalid")
    installed_app_path = _canonical_remote_app_path(
        _nonempty_string(
            installation.get("remoteApplicationPath"), "installed iOS app path"
        )
    )
    expected_remote_executable = installed_app_path + "/" + source_executable
    _launch_services_identifier(installation.get("launchServicesIdentifier"))

    launch = _devicectl_result(
        _load_json(arguments.launch_result, "devicectl launch result"),
        "devicectl.device.process.launch",
        "devicectl launch result",
    )
    process = launch.get("process")
    if not isinstance(process, dict):
        _fail("devicectl launch result omitted the process identity")
    process_identifier = process.get("processIdentifier")
    audit_token = process.get("auditToken")
    if (
        isinstance(process_identifier, bool)
        or not isinstance(process_identifier, int)
        or process_identifier <= 0
        or not isinstance(audit_token, list)
        or len(audit_token) != 8
        or any(
            isinstance(value, bool)
            or not isinstance(value, int)
            or value < 0
            or value > 0xFFFFFFFF
            for value in audit_token
        )
        or audit_token[5] != process_identifier
        or _process_executable_path(process.get("executable")) != expected_remote_executable
    ):
        _fail("devicectl launch process identity is malformed or bound to another app")
    _validate_process_identity(
        arguments.ios_process_identity,
        process_identifier,
        audit_token,
        expected_remote_executable,
    )

    status = _load_text(arguments.ios_status, "physical iOS status")
    stdout = _load_text(arguments.ios_stdout, "physical iOS console stdout")
    if "failed stage=" in status or "failed stage=" in stdout:
        _fail("physical iOS status or console contains a terminal failure")
    success_matches = [
        match
        for line in status.splitlines()
        if (match := IOS_STATUS_TERMINAL_PATTERN.fullmatch(line)) is not None
    ]
    if len(success_matches) != 1:
        _fail("physical iOS status must contain exactly one session success")
    success_line = success_matches[0].group(0)
    success_payload = success_matches[0].group(1)
    if stdout.splitlines().count(success_line) != 1:
        _fail("physical iOS console stdout must contain one exact bound terminal line")
    if arguments.console_cleanup_verified != "true" or arguments.app_exit_verified != "true":
        _fail("physical iOS exact-process cleanup is incomplete")
    if arguments.test_package_cleanup_verified != "true":
        _fail("dedicated Android test-package cleanup is incomplete")
    if arguments.android_context_cleanup_verified != "true":
        _fail("dedicated Android auth/code context cleanup is incomplete")
    if arguments.android_app_exit_verified != "true":
        _fail("Android target-process exit is not proven")
    if arguments.android_sensitive_state_unchanged != "true":
        _fail("Android persistent identity/trust state is not proven unchanged")
    if arguments.ios_required_identity_and_container_state_unchanged != "true":
        _fail(
            "iOS required identity material and protected container state "
            "are not proven unchanged"
        )
    android_device = _require_android_device_unchanged(
        arguments.android_device_before, arguments.android_device_after
    )
    _matching_phase_digest(status, "identity-material", "physical iOS status")
    _require_ios_container_unchanged(
        arguments.ios_container_before, arguments.ios_container_after
    )

    android_instrumentation = _load_text(
        arguments.android_instrumentation, "Android instrumentation output"
    )
    storage_marker = (
        "SB-ANDROID-APP-OFFER storage=dedicated-test-package "
        f"package={EXPECTED_ANDROID_TEST_PACKAGE}"
    )
    if android_instrumentation.splitlines().count(storage_marker) != 1:
        _fail("Android instrumentation did not prove one exact dedicated storage package")
    _matching_phase_digest(
        android_instrumentation,
        "SB-ANDROID-APP-OFFER sensitive-state",
        "Android instrumentation",
    )
    if android_instrumentation.splitlines().count("OK (1 test)") != 1:
        _fail("Android instrumentation did not contain one exact successful test terminal")
    if re.search(
        r"(?:INSTRUMENTATION_FAILED|FAILURES!!!|Process crashed|shortMsg=)",
        android_instrumentation,
    ):
        _fail("Android instrumentation contains a contradictory failure terminal")
    android_success_lines = [
        line
        for line in android_instrumentation.splitlines()
        if line.startswith("SB-ANDROID-APP-OFFER success ")
    ]
    if len(android_success_lines) != 1:
        _fail("Android instrumentation must contain exactly one app-offer success terminal")
    android_fields = _terminal_fields(
        android_success_lines[0], "SB-ANDROID-APP-OFFER success"
    )
    expected_android_fields = {
        "code",
        "runRef",
        "sessionRef",
        "bootstrapKem",
        "bootstrapQPeriapt",
        "qperiapt",
        "expectedSuite",
        "suite",
        "suiteWireId",
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
        "route",
    }
    if set(android_fields) != expected_android_fields:
        _fail("Android app-offer terminal has an unexpected field set")
    android_suite = android_fields.get("suite")
    android_suite_wire_id = android_fields.get("suiteWireId")
    android_route = android_fields.get("route")
    android_run_ref = android_fields.get("runRef")
    android_session_ref = android_fields.get("sessionRef")
    if android_run_ref != arguments.run_ref:
        _fail("Android app-offer terminal belongs to a different run")
    if not android_session_ref or SHA256_PATTERN.fullmatch(android_session_ref) is None:
        _fail("Android app-offer terminal omitted a canonical session reference")
    if not android_suite or re.fullmatch(r"[A-Za-z0-9_.+/-]{1,128}", android_suite) is None:
        _fail("Android app-offer terminal omitted a canonical suite")
    if android_route not in {"direct", "relay"}:
        _fail("Android app-offer terminal omitted a canonical selected route")
    if not android_suite_wire_id or SUITE_WIRE_ID_PATTERN.fullmatch(android_suite_wire_id) is None:
        _fail("Android app-offer terminal omitted a canonical suite wire id")
    if (
        android_fields.get("code") != "<redacted>"
        or android_fields.get("bootstrapKem") != "true"
        or android_fields.get("fileTransfer") != "true"
        or android_fields.get("bidirectionalFileTransfer") != "true"
        or android_fields.get("androidRunOwnedPayloadCleaned") != "true"
        or android_fields.get("bootstrapQPeriapt") not in {"true", "false"}
        or android_fields.get("qperiapt") not in {"true", "false"}
        or not android_fields.get("expectedSuite")
        or re.fullmatch(r"[A-Za-z0-9_.+/-]{1,128}", android_fields["expectedSuite"])
        is None
    ):
        _fail("Android app-offer terminal has invalid formal policy values")
    suite_match = re.fullmatch(r"([A-Za-z0-9_.+-]{1,96})/(0x[0-9a-f]{4})", android_suite)
    if suite_match is None or suite_match.group(2) != android_suite_wire_id:
        _fail("Android suite label and wire id contradict each other")
    android_suite_name = ANDROID_SUITE_NAMES.get(android_suite_wire_id)
    if android_suite_name is None or suite_match.group(1) != android_suite_name:
        _fail("Android suite label is not canonical for its wire id")
    expected_suite = android_fields["expectedSuite"]
    if expected_suite not in {android_suite_name, "any-pqc"}:
        _fail("Android expected suite does not match the negotiated suite")
    qperiapt_expected = android_suite_wire_id == "0x0011"
    if (android_fields["qperiapt"] == "true") != qperiapt_expected:
        _fail("Android Q-Periapt assertion contradicts the negotiated suite")
    if (
        android_suite_wire_id != "0x0101"
        or android_fields["qperiapt"] != "false"
        or expected_suite != "MLKEM_768"
    ):
        _fail("formal physical receipt requires exact ML-KEM-768 negotiation")

    ios_fields = _terminal_fields(success_payload, "success")
    expected_ios_fields = {
        "session_ref",
        "runRef",
        "suite",
        "suiteWireId",
        "selectedIceRoute",
        "selectedIceLocalType",
        "selectedIceRemoteType",
        "selectedIceProtocol",
        "handshakeOnly",
        "bidirectionalFileTransfer",
        "androidToPeerTransferId",
        "androidToPeerBytes",
        "androidToPeerSha256",
        "androidToPeerDurableStorage",
        "androidToPeerCompleteAck",
        "peerToAndroidTransferId",
        "peerToAndroidBytes",
        "peerToAndroidSha256",
        "peerToAndroidCompleteAck",
        "iosRunOwnedPayloadCleaned",
    }
    if set(ios_fields) != expected_ios_fields:
        _fail("physical iOS terminal has an unexpected field set")
    if ios_fields.get("handshakeOnly") not in {"0", "1"}:
        _fail("physical iOS terminal status omitted a canonical handshakeOnly field")
    ios_suite = ios_fields.get("suite")
    ios_suite_wire_id = ios_fields.get("suiteWireId")
    if ios_fields.get("runRef") != arguments.run_ref:
        _fail("physical iOS terminal belongs to a different run")
    if ios_fields.get("session_ref") != android_session_ref:
        _fail("Android and physical iOS terminals belong to different sessions")
    if not ios_suite or re.fullmatch(r"[A-Za-z0-9_.+/-]{1,128}", ios_suite) is None:
        _fail("physical iOS terminal status omitted a canonical suite")
    if not ios_suite_wire_id or SUITE_WIRE_ID_PATTERN.fullmatch(ios_suite_wire_id) is None:
        _fail("physical iOS terminal status omitted a canonical suite wire id")
    if android_suite_wire_id != ios_suite_wire_id:
        _fail("Android and physical iOS reported different negotiated suite wire ids")
    ios_labels = IOS_SUITE_NAMES.get(ios_suite_wire_id)
    if ios_labels is None or ios_suite not in ios_labels:
        _fail("physical iOS suite label is not canonical for its wire id")
    if (
        ios_fields["handshakeOnly"] != "0"
        or ios_fields["bidirectionalFileTransfer"] != "true"
        or ios_fields["androidToPeerDurableStorage"] != "caches"
        or ios_fields["androidToPeerCompleteAck"] != "true"
        or ios_fields["peerToAndroidCompleteAck"] != "true"
        or ios_fields["iosRunOwnedPayloadCleaned"] != "true"
    ):
        _fail("physical iOS terminal lacks exact bidirectional durable evidence")
    if (
        ios_fields["selectedIceRoute"] not in {"direct", "relay"}
        or ios_fields["selectedIceRoute"] != android_route
        or ios_fields["selectedIceLocalType"]
        not in {"host", "srflx", "prflx", "relay"}
        or ios_fields["selectedIceRemoteType"]
        not in {"host", "srflx", "prflx", "relay"}
        or ios_fields["selectedIceProtocol"] not in {"udp", "tcp"}
    ):
        _fail("physical iOS selected ICE evidence is invalid or mismatched")

    file_transfer_expected = arguments.expect_file_transfer == "true"
    if not file_transfer_expected:
        _fail("physical iOS formal receipt requires durable file-transfer evidence")
    file_transfer: dict[str, object] = {"expected": file_transfer_expected}
    if file_transfer_expected:
        directions = (
            (
                "android-to-peer",
                "androidToPeer",
                "androidToPeerTransferId",
                "androidToPeerBytes",
                "androidToPeerSha256",
            ),
            (
                "peer-to-android",
                "peerToAndroid",
                "peerToAndroidTransferId",
                "peerToAndroidBytes",
                "peerToAndroidSha256",
            ),
        )
        if android_fields.get("fileTransfer") != "true":
            _fail("Android app-offer terminal did not assert file transfer")
        transfer_records: list[dict[str, object]] = []
        seen_transfer_ids: set[str] = set()
        for direction, prefix, id_field, bytes_field, sha_field in directions:
            transfer_id = _canonical_transfer_id(android_fields[id_field], id_field)
            if transfer_id in seen_transfer_ids:
                _fail("formal bidirectional transfer identifiers must be distinct")
            seen_transfer_ids.add(transfer_id)
            if ios_fields[id_field] != transfer_id:
                _fail("Android and iOS reported different formal transfer identifiers")
            expected_payload = _formal_payload(
                direction, arguments.run_ref, android_session_ref, transfer_id
            )
            expected_bytes = len(expected_payload)
            expected_sha = hashlib.sha256(expected_payload).hexdigest()
            if (
                android_fields[bytes_field] != str(expected_bytes)
                or android_fields[sha_field] != expected_sha
                or ios_fields[bytes_field] != str(expected_bytes)
                or ios_fields[sha_field] != expected_sha
            ):
                _fail(f"{direction} payload bytes or SHA-256 do not match the canonical run payload")
            transfer_records.append(
                {
                    "direction": direction,
                    "transferIDRef": hashlib.sha256(transfer_id.encode("ascii")).hexdigest(),
                    "bytes": expected_bytes,
                    "payloadSHA256": expected_sha,
                    "durableCommit": True,
                    "completeAcknowledgement": True,
                }
            )
        if android_fields.get("androidToPeerOutboundOps") != "metadata,chunk,complete":
            _fail("Android app-offer terminal has an invalid outbound operation sequence")
        if android_fields.get("androidToPeerInboundAcks") != "metadataAck,chunkAck,completeAck":
            _fail("Android app-offer terminal has an invalid acknowledgement sequence")
        if android_fields.get("peerToAndroidInboundOps") != "metadata,chunk,complete":
            _fail("Android reverse lane has an invalid inbound operation sequence")
        if android_fields.get("peerToAndroidOutboundAcks") != "metadataAck,chunkAck,completeAck":
            _fail("Android reverse lane has an invalid outbound acknowledgement sequence")
        file_transfer.update(
            {
                "bidirectional": True,
                "asserted": True,
                "transfers": transfer_records,
            }
        )
    elif android_fields.get("fileTransfer") not in {None, "false"}:
        _fail("Android app-offer terminal contradicts the no-file-transfer request")

    app_apk = _artifact_properties(arguments.app_apk_provenance, "app_debug_apk")
    test_apk = _artifact_properties(arguments.test_apk_provenance, "android_test_apk")
    _require_installed_apks_unchanged(
        arguments.android_installed_before,
        arguments.android_installed_after,
        app_apk,
        test_apk,
        android_device["serial_ref"],
    )
    return {
        "android": {
            "device": {
                "abi": android_device["abi"],
                "modelRef": android_device["model_ref"],
                "pageSize": int(android_device["page_size"]),
                "physical": True,
                "profile": android_device["profile"],
                "release": android_device["release"],
                "sdk": int(android_device["sdk"]),
                "serialRef": android_device["serial_ref"],
            },
            "appPackage": EXPECTED_ANDROID_APP_PACKAGE,
            "appExitVerified": True,
            "installedAppDigestVerified": True,
            "installedTestDigestVerified": True,
            "persistentSensitiveStateUnchanged": True,
            "targetApk": app_apk,
            "testApk": test_apk,
            "testPackage": EXPECTED_ANDROID_TEST_PACKAGE,
            "testPackageCleanupVerified": True,
            "testStorageContextCleanupVerified": True,
            "testStorageContextVerified": True,
            "testStoragePackage": EXPECTED_ANDROID_TEST_PACKAGE,
            "terminal": {
                "fileTransfer": file_transfer,
                "route": android_route,
                "sessionRef": android_session_ref,
                "suite": android_suite,
                "suiteWireId": android_suite_wire_id,
                "success": True,
            },
        },
        "appleIdentityMode": "existing-persistent-read-only",
        "artifactBindingPurpose": "detect-accidental-source-artifact-device-or-run-mismatch",
        "ios": {
            "app": installation["sourceApp"],
            "appExitVerified": True,
            "bundleIdentifier": EXPECTED_BUNDLE_ID,
            "consoleCleanupVerified": True,
            "deviceRef": installation["coreDeviceIdentifierRef"],
            "installationMode": "overlay-preserve-data",
            "installationVerified": True,
            "launchAuditTokenVerified": True,
            "persistentIdentityWriteAuthorized": False,
            "requiredIdentityMaterialUnchanged": True,
            "protectedContainerStateUnchanged": True,
            "persistentTrustWriteAuthorized": False,
            "statusCopiedFromAppContainer": True,
            "stdoutTerminalStatusVerified": True,
            "udidRef": installation["deviceUdidRef"],
        },
        "lane": "android-offerer-physical-ios-bidirectional-file-transfer",
        "outcome": "success",
        "runRef": arguments.run_ref,
        "schemaVersion": 1,
        "sourceCommit": arguments.source_commit,
        "sourceTree": source_binding["source_tree"],
        "sourceFreezeVerified": True,
        "terminalStatus": {
            "handshakeOnly": ios_fields["handshakeOnly"] == "1",
            "selectedIceRoute": ios_fields["selectedIceRoute"],
            "bidirectionalFileTransfer": True,
            "suite": ios_suite,
            "suiteWireId": ios_suite_wire_id,
            "success": True,
        },
    }


def validate_state_freeze(arguments: argparse.Namespace) -> dict[str, Any]:
    android_instrumentation = _load_text(
        arguments.android_instrumentation, "Android instrumentation output"
    )
    ios_status = _load_text(arguments.ios_status, "physical iOS status")
    android_digest = _matching_phase_digest(
        android_instrumentation,
        "SB-ANDROID-APP-OFFER sensitive-state",
        "Android instrumentation",
    )
    ios_digest = _matching_phase_digest(
        ios_status,
        "identity-material",
        "physical iOS status",
    )
    container_digest = _require_ios_container_unchanged(
        arguments.ios_container_before, arguments.ios_container_after
    )
    return {
        "androidSensitiveStateDigestRef": _identifier_ref(android_digest),
        "androidSensitiveStateUnchanged": True,
        "iosRequiredIdentityMaterialDigestRef": _identifier_ref(ios_digest),
        "iosContainerStateDigestRef": _identifier_ref(container_digest),
        "iosRequiredIdentityMaterialUnchanged": True,
        "iosProtectedContainerStateUnchanged": True,
        "schemaVersion": 1,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    device = subparsers.add_parser("device")
    device.add_argument("--devicectl-json", type=Path, required=True)
    device.add_argument("--xcdevice-json", type=Path, required=True)
    device.add_argument("--device-id", required=True)
    device.add_argument("--device-udid", required=True)
    device.add_argument("--output", type=Path, required=True)

    install = subparsers.add_parser("installation")
    install.add_argument("--device-binding", type=Path, required=True)
    install.add_argument("--install-result", type=Path, required=True)
    install.add_argument("--apps-result", type=Path, required=True)
    install.add_argument("--app-provenance", type=Path, required=True)
    install.add_argument("--output", type=Path, required=True)

    receipt = subparsers.add_parser("receipt")
    receipt.add_argument("--source-commit", required=True)
    receipt.add_argument("--run-ref", required=True)
    receipt.add_argument("--installation-binding", type=Path, required=True)
    receipt.add_argument("--launch-result", type=Path, required=True)
    receipt.add_argument("--ios-status", type=Path, required=True)
    receipt.add_argument("--ios-stdout", type=Path, required=True)
    receipt.add_argument("--ios-process-identity", type=Path, required=True)
    receipt.add_argument("--app-apk-provenance", type=Path, required=True)
    receipt.add_argument("--test-apk-provenance", type=Path, required=True)
    receipt.add_argument("--android-instrumentation", type=Path, required=True)
    receipt.add_argument("--android-device-before", type=Path, required=True)
    receipt.add_argument("--android-device-after", type=Path, required=True)
    receipt.add_argument("--android-installed-before", type=Path, required=True)
    receipt.add_argument("--android-installed-after", type=Path, required=True)
    receipt.add_argument("--source-binding-before", type=Path, required=True)
    receipt.add_argument("--source-binding-after", type=Path, required=True)
    receipt.add_argument("--console-cleanup-verified", choices=("true", "false"), required=True)
    receipt.add_argument("--app-exit-verified", choices=("true", "false"), required=True)
    receipt.add_argument("--android-app-exit-verified", choices=("true", "false"), required=True)
    receipt.add_argument("--test-package-cleanup-verified", choices=("true", "false"), required=True)
    receipt.add_argument("--android-context-cleanup-verified", choices=("true", "false"), required=True)
    receipt.add_argument("--expect-file-transfer", choices=("true", "false"), required=True)
    receipt.add_argument("--android-sensitive-state-unchanged", choices=("true", "false"), required=True)
    receipt.add_argument(
        "--ios-required-identity-and-container-state-unchanged",
        choices=("true", "false"),
        required=True,
    )
    receipt.add_argument("--ios-container-before", type=Path, required=True)
    receipt.add_argument("--ios-container-after", type=Path, required=True)
    receipt.add_argument("--output", type=Path, required=True)

    state_freeze = subparsers.add_parser("state-freeze")
    state_freeze.add_argument("--android-instrumentation", type=Path, required=True)
    state_freeze.add_argument("--ios-status", type=Path, required=True)
    state_freeze.add_argument("--ios-container-before", type=Path, required=True)
    state_freeze.add_argument("--ios-container-after", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        if arguments.command == "device":
            payload = validate_device(
                arguments.devicectl_json,
                arguments.xcdevice_json,
                arguments.device_id,
                arguments.device_udid,
            )
        elif arguments.command == "installation":
            payload = validate_installation(
                arguments.device_binding,
                arguments.install_result,
                arguments.apps_result,
                arguments.app_provenance,
            )
        elif arguments.command == "receipt":
            payload = validate_receipt(arguments)
        else:
            validate_state_freeze(arguments)
            return 0
        _atomic_new(arguments.output, payload)
    except (PhysicalEvidenceError, OSError, plistlib.InvalidFileException) as exc:
        print(f"Android to physical iOS evidence rejected: {exc}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
