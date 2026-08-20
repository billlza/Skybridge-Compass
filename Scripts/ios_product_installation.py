#!/usr/bin/env python3
"""Verify one sealed-iOS-product installation transaction for a physical device."""

from __future__ import annotations

import argparse
import base64
import json
import os
import plistlib
import re
import stat
import subprocess
import tempfile
import urllib.parse
from pathlib import Path, PurePosixPath
from typing import Any, NoReturn

from ios_physical_release_acceptance import expected_binding
from ios_release_archive_identity import (
    APP_BUNDLE_IDENTIFIER,
    ArchiveIdentityError,
    load_identity,
    validate_release_testing_ipa,
)


MAX_JSON_BYTES = 4 * 1024 * 1024
EXPECTED_EXECUTABLE = "SkyBridgeCompass-iOS"
UUID_LINE = re.compile(
    r"UUID: ([0-9A-Fa-f-]{36}) \(([A-Za-z0-9_]+)\) .+",
    re.ASCII,
)


class IOSInstallationError(RuntimeError):
    """The install/query transaction is not bound to the sealed product."""


def _fail(message: str) -> NoReturn:
    raise IOSInstallationError(message)


def _read_regular(path: Path, label: str, maximum_bytes: int = MAX_JSON_BYTES) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        _fail(f"unable to open {label} without following links: {exc}")
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_size < 1
            or metadata.st_size > maximum_bytes
        ):
            _fail(f"{label} must be a bounded single-link regular file")
        content = bytearray()
        while len(content) < metadata.st_size:
            chunk = os.read(descriptor, min(1024 * 1024, metadata.st_size - len(content)))
            if not chunk:
                _fail(f"{label} was truncated while reading")
            content.extend(chunk)
        if os.read(descriptor, 1):
            _fail(f"{label} grew while reading")
        return bytes(content)
    finally:
        os.close(descriptor)


def _load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(_read_regular(path, label).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(f"{label} is invalid UTF-8 JSON: {exc}")
    if not isinstance(payload, dict):
        _fail(f"{label} must be a JSON object")
    return payload


def _devicectl_result(path: Path, command_type: str, label: str) -> dict[str, Any]:
    payload = _load_json(path, label)
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
        _fail(f"{label} is not a successful {command_type} result")
    return result


def _validate_launch_services_identifier(value: str) -> str:
    if len(value) > 4096:
        _fail("launchServicesIdentifier exceeds the bounded size")
    try:
        decoded = base64.b64decode(value, validate=True)
    except ValueError as exc:
        _fail(f"launchServicesIdentifier is not canonical base64: {exc}")
    if not decoded:
        _fail("launchServicesIdentifier decodes to no data")
    return value


def _remote_app_path(raw_url: object) -> str:
    if not isinstance(raw_url, str):
        _fail("installed product URL is missing")
    parsed = urllib.parse.urlparse(raw_url)
    if parsed.scheme != "file" or parsed.netloc not in {"", "localhost"}:
        _fail("installed product URL must be a local file URL")
    path = urllib.parse.unquote(parsed.path)
    normalized = str(PurePosixPath(path.rstrip("/")))
    if (
        not normalized.startswith("/private/var/containers/Bundle/Application/")
        or not normalized.endswith(".app")
        or any(component in {".", ".."} for component in PurePosixPath(normalized).parts)
    ):
        _fail("installed product URL is outside the iOS application container")
    return normalized


def _load_product_info(app: Path) -> tuple[str, str, Path]:
    if not app.is_absolute() or app.is_symlink() or not app.is_dir():
        _fail("extracted release-testing app must be an absolute real directory")
    try:
        with (app / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        _fail(f"release-testing app Info.plist is invalid: {exc}")
    if not isinstance(info, dict):
        _fail("release-testing app Info.plist must be a dictionary")
    if (
        info.get("CFBundleIdentifier") != APP_BUNDLE_IDENTIFIER
        or info.get("CFBundleExecutable") != EXPECTED_EXECUTABLE
    ):
        _fail("release-testing app bundle/executable identity is invalid")
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    if not isinstance(version, str) or not isinstance(build, str):
        _fail("release-testing app version/build are missing")
    executable = app / EXPECTED_EXECUTABLE
    if executable.is_symlink() or not executable.is_file() or not os.access(executable, os.X_OK):
        _fail("release-testing app executable is missing")
    return version, build, executable


def _executable_uuids(executable: Path) -> list[dict[str, str]]:
    result = subprocess.run(
        ["/usr/bin/dwarfdump", "--uuid", os.fspath(executable)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        _fail("unable to inspect release-testing executable UUIDs")
    records: list[dict[str, str]] = []
    for line in result.stdout.splitlines():
        match = UUID_LINE.fullmatch(line.strip())
        if match:
            records.append(
                {
                    "architecture": match.group(2),
                    "uuid": match.group(1).lower(),
                }
            )
    records.sort(key=lambda record: (record["architecture"], record["uuid"]))
    if not records or len({(r["architecture"], r["uuid"]) for r in records}) != len(records):
        _fail("release-testing executable UUIDs are missing or duplicated")
    return records


def verify_installation(
    *,
    install_result: Path,
    apps_result: Path,
    extracted_app: Path,
    archive_identity_path: Path,
    release_testing_ipa: Path,
    expected_device_identifier: str,
) -> dict[str, Any]:
    try:
        identity = load_identity(archive_identity_path)
        validate_release_testing_ipa(identity, release_testing_ipa)
    except ArchiveIdentityError as exc:
        _fail(f"sealed archive/release-testing IPA is invalid: {exc}")
    version, build, executable = _load_product_info(extracted_app)
    if (
        version != identity["releaseVersion"]
        or build != identity["releaseBuild"]
        or _executable_uuids(executable) != identity["appExecutableUUIDs"]
    ):
        _fail("extracted product version/build/UUIDs do not match the sealed archive")

    install = _devicectl_result(
        install_result,
        "devicectl.device.install.app",
        "devicectl install result",
    )
    install_device = install.get("deviceIdentifier")
    if not isinstance(install_device, str) or not install_device:
        _fail("devicectl install result has no exact deviceIdentifier")
    if install_device != expected_device_identifier:
        _fail("devicectl install result targets a different device")
    installed_applications = install.get("installedApplications")
    if (
        not isinstance(installed_applications, list)
        or len(installed_applications) != 1
        or not isinstance(installed_applications[0], dict)
    ):
        _fail("devicectl install result must contain exactly one installed application")
    installed_application = installed_applications[0]
    if installed_application.get("bundleIdentifier") != APP_BUNDLE_IDENTIFIER:
        _fail("devicectl install result installed a different bundle")
    raw_launch_identifier = installed_application.get("launchServicesIdentifier")
    if not isinstance(raw_launch_identifier, str) or not raw_launch_identifier:
        _fail("installed application has no launchServicesIdentifier")
    launch_identifier = _validate_launch_services_identifier(
        raw_launch_identifier
    )

    query = _devicectl_result(
        apps_result,
        "devicectl.device.info.apps",
        "devicectl installed-app query",
    )
    if (
        query.get("deviceIdentifier") != expected_device_identifier
        or query.get("matchingBundleIdentifier") != APP_BUNDLE_IDENTIFIER
    ):
        _fail("installed-app query device/bundle filter does not match the transaction")
    apps = query.get("apps")
    if not isinstance(apps, list) or len(apps) != 1 or not isinstance(apps[0], dict):
        _fail("installed-app query must return exactly one product")
    app = apps[0]
    if (
        app.get("bundleIdentifier") != APP_BUNDLE_IDENTIFIER
        or app.get("version") != version
        or app.get("bundleVersion") != build
        or app.get("builtByDeveloper") is not True
    ):
        _fail("installed product bundle/version/build does not match the sealed product")
    remote_app_path = _remote_app_path(app.get("url"))
    return {
        "bundleIdentifier": APP_BUNDLE_IDENTIFIER,
        "deviceIdentifier": expected_device_identifier,
        "installationVerified": True,
        "iosReleaseArchive": expected_binding(identity),
        "launchServicesIdentifier": launch_identifier,
        "releaseBuild": build,
        "releaseVersion": version,
        "remoteApplicationPath": remote_app_path,
        "schemaVersion": 1,
    }


def _atomic_new(path: Path, payload: dict[str, Any]) -> None:
    if not path.is_absolute() or path.exists() or path.is_symlink():
        _fail("installation binding output must be a new absolute path")
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install-result", type=Path, required=True)
    parser.add_argument("--apps-result", type=Path, required=True)
    parser.add_argument("--extracted-app", type=Path, required=True)
    parser.add_argument("--archive-identity", type=Path, required=True)
    parser.add_argument("--release-testing-ipa", type=Path, required=True)
    parser.add_argument("--expected-device-identifier", required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        payload = verify_installation(
            install_result=arguments.install_result,
            apps_result=arguments.apps_result,
            extracted_app=arguments.extracted_app,
            archive_identity_path=arguments.archive_identity,
            release_testing_ipa=arguments.release_testing_ipa,
            expected_device_identifier=arguments.expected_device_identifier,
        )
        _atomic_new(arguments.output, payload)
    except (IOSInstallationError, OSError) as exc:
        print(f"iOS product installation rejected: {exc}", file=os.sys.stderr)
        return 1
    print(f"iOS product installation verified: {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
