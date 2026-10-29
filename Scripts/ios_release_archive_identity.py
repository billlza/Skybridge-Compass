#!/usr/bin/env python3
"""Create and verify the immutable identity of one iOS release archive.

The SHA-256 values in this document are Level-1 reliability checks. They detect
accidental archive/IPA substitution between the physical-device and App Store
transactions; they are not an authenticity or authorization boundary. Signing,
provisioning, protected-runner approval, and App Store Connect authentication
remain separate gates.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import tempfile
import unicodedata
from pathlib import Path
from typing import Any, Iterator

from extract_ios_ipa import IPAValidationError, extract_single_ios_app


SCHEMA_VERSION = 1
IDENTITY_PURPOSE = "detect-accidental-cross-run-mismatch"
APP_BUNDLE_IDENTIFIER = "com.skybridge.compass.ios"
WIDGET_BUNDLE_IDENTIFIER = "com.skybridge.compass.ios.widgets"
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_PLIST_BYTES = 4 * 1024 * 1024
MAX_ARCHIVE_FILES = 100_000
MAX_ARCHIVE_FILE_BYTES = 8 * 1024 * 1024 * 1024
MAX_ARCHIVE_TOTAL_BYTES = 24 * 1024 * 1024 * 1024
SOURCE_COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
DIGEST_PATTERN = re.compile(r"[0-9a-f]{64}")
REPOSITORY_PATTERN = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
VERSION_PATTERN = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
)
BUILD_PATTERN = re.compile(r"[1-9][0-9]*")
UUID_PATTERN = re.compile(
    r"UUID: ([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}) \(([A-Za-z0-9_]+)\) .+"
)


class ArchiveIdentityError(ValueError):
    pass


def _fail(message: str) -> "None":
    raise ArchiveIdentityError(message)


def _real_directory(path: Path, label: str) -> Path:
    if not path.is_absolute():
        _fail(f"{label} must be absolute")
    try:
        metadata = path.lstat()
    except OSError as error:
        _fail(f"unable to inspect {label}: {error}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        _fail(f"{label} must be a real directory")
    try:
        return path.resolve(strict=True)
    except OSError as error:
        _fail(f"unable to resolve {label}: {error}")


def _regular_file(path: Path, label: str, *, maximum_size: int) -> Path:
    if not path.is_absolute():
        _fail(f"{label} must be absolute")
    try:
        metadata = path.lstat()
    except OSError as error:
        _fail(f"unable to inspect {label}: {error}")
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
    ):
        _fail(f"{label} must be a single-link regular file")
    if metadata.st_size < 1 or metadata.st_size > maximum_size:
        _fail(f"{label} size is outside the accepted bound")
    return path.resolve(strict=True)


def _read_json(path: Path, label: str) -> dict[str, Any]:
    resolved = _regular_file(path, label, maximum_size=MAX_MANIFEST_BYTES)
    try:
        payload = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        _fail(f"{label} is not valid UTF-8 JSON: {error}")
    if not isinstance(payload, dict):
        _fail(f"{label} must be a JSON object")
    return payload


def _read_plist(path: Path, label: str) -> dict[str, Any]:
    resolved = _regular_file(path, label, maximum_size=MAX_PLIST_BYTES)
    try:
        with resolved.open("rb") as handle:
            payload = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        _fail(f"{label} is not a valid property list: {error}")
    if not isinstance(payload, dict):
        _fail(f"{label} must be a property-list dictionary")
    return payload


def _single_child(directory: Path, suffix: str, label: str) -> Path:
    candidates: list[Path] = []
    try:
        entries = list(directory.iterdir())
    except OSError as error:
        _fail(f"unable to inspect {label}: {error}")
    for entry in entries:
        try:
            metadata = entry.lstat()
        except OSError as error:
            _fail(f"unable to inspect {label} entry: {error}")
        if entry.name.endswith(suffix):
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                _fail(f"{label} contains a linked or non-directory {suffix} entry")
            candidates.append(entry)
    if len(candidates) != 1:
        _fail(f"{label} must contain exactly one {suffix} bundle")
    return candidates[0].resolve(strict=True)


def archive_products(archive: Path) -> tuple[Path, Path, dict[str, Any], dict[str, Any]]:
    archive = _real_directory(archive, "iOS archive")
    applications = _real_directory(
        archive / "Products" / "Applications", "archive Applications directory"
    )
    app = _single_child(applications, ".app", "archive Applications directory")
    plugins = _real_directory(app / "PlugIns", "archived app PlugIns directory")
    widget = _single_child(plugins, ".appex", "archived app PlugIns directory")
    app_info = _read_plist(app / "Info.plist", "archived app Info.plist")
    widget_info = _read_plist(widget / "Info.plist", "archived Widget Info.plist")
    return app, widget, app_info, widget_info


def bundle_executable(bundle: Path, info: dict[str, Any], label: str) -> Path:
    executable_name = info.get("CFBundleExecutable")
    if (
        not isinstance(executable_name, str)
        or executable_name in {"", ".", ".."}
        or "/" in executable_name
        or "\\" in executable_name
    ):
        _fail(f"{label} executable name is invalid")
    executable = _regular_file(
        bundle / executable_name, f"{label} executable", maximum_size=MAX_ARCHIVE_FILE_BYTES
    )
    if executable.stat().st_mode & 0o111 == 0:
        _fail(f"{label} executable is not executable")
    return executable


def executable_uuids(executable: Path, label: str) -> list[dict[str, str]]:
    result = subprocess.run(
        ["/usr/bin/xcrun", "dwarfdump", "--uuid", str(executable)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        _fail(f"unable to read {label} Mach-O UUIDs")
    records: list[dict[str, str]] = []
    for line in result.stdout.splitlines():
        match = UUID_PATTERN.fullmatch(line.strip())
        if match is None:
            _fail(f"{label} Mach-O UUID output is malformed")
        records.append(
            {
                "architecture": match.group(2),
                "uuid": match.group(1).lower(),
            }
        )
    records.sort(key=lambda value: (value["architecture"], value["uuid"]))
    if not records or len(records) != len(
        {(value["architecture"], value["uuid"]) for value in records}
    ):
        _fail(f"{label} Mach-O UUID set is empty or duplicated")
    if not any(value["architecture"] in {"arm64", "arm64e"} for value in records):
        _fail(f"{label} Mach-O UUID set does not contain a 64-bit ARM slice")
    return records


def archive_debug_symbols(
    *,
    archive: Path,
    app: Path,
    widget: Path,
    app_uuids: list[dict[str, str]],
    widget_uuids: list[dict[str, str]],
) -> None:
    debug_symbols = _real_directory(archive / "dSYMs", "archive dSYMs directory")
    for label, bundle, expected_uuids in (
        ("app", app, app_uuids),
        ("Widget", widget, widget_uuids),
    ):
        dwarf_directory = _real_directory(
            debug_symbols
            / f"{bundle.name}.dSYM"
            / "Contents"
            / "Resources"
            / "DWARF",
            f"archive {label} dSYM DWARF directory",
        )
        candidates: list[Path] = []
        try:
            entries = list(dwarf_directory.iterdir())
        except OSError as error:
            _fail(f"unable to inspect archive {label} dSYM: {error}")
        for entry in entries:
            try:
                metadata = entry.lstat()
            except OSError as error:
                _fail(f"unable to inspect archive {label} dSYM entry: {error}")
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                _fail(f"archive {label} dSYM contains a link or non-file entry")
            candidates.append(
                _regular_file(
                    entry,
                    f"archive {label} dSYM DWARF file",
                    maximum_size=MAX_ARCHIVE_FILE_BYTES,
                )
            )
        if len(candidates) != 1:
            _fail(f"archive {label} dSYM must contain exactly one DWARF file")
        actual_uuids = executable_uuids(candidates[0], f"archive {label} dSYM")
        if actual_uuids != expected_uuids:
            _fail(f"archive {label} dSYM does not match its executable UUIDs")


def release_testing_products(
    export_directory: Path,
) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, str]], list[dict[str, str]]]:
    export_directory = _real_directory(export_directory, "release-testing export directory")
    with tempfile.TemporaryDirectory(prefix="ios-release-identity-") as name:
        work = Path(name)
        os.chmod(work, 0o700)
        try:
            app = extract_single_ios_app(
                export_directory, work / "SkyBridgeCompass-iOS.app"
            )
        except IPAValidationError as error:
            _fail(f"release-testing IPA extraction failed: {error}")
        plugins = _real_directory(app / "PlugIns", "release-testing app PlugIns directory")
        widget = _single_child(plugins, ".appex", "release-testing app PlugIns directory")
        app_info = _read_plist(app / "Info.plist", "release-testing app Info.plist")
        widget_info = _read_plist(widget / "Info.plist", "release-testing Widget Info.plist")
        app_uuids = executable_uuids(
            bundle_executable(app, app_info, "release-testing app"), "release-testing app"
        )
        widget_uuids = executable_uuids(
            bundle_executable(widget, widget_info, "release-testing Widget"),
            "release-testing Widget",
        )
    return app_info, widget_info, app_uuids, widget_uuids


def _normalized_relative(path: Path, root: Path) -> str:
    relative = path.relative_to(root).as_posix()
    normalized = unicodedata.normalize("NFC", relative)
    if relative != normalized or relative in {"", "."}:
        _fail("archive contains a non-canonical path")
    return normalized


def _archive_entries(root: Path) -> Iterator[tuple[str, Path, os.stat_result]]:
    normalized_names: set[str] = set()
    stack = [root]
    while stack:
        directory = stack.pop()
        try:
            entries = sorted(directory.iterdir(), key=lambda item: item.name.encode("utf-8"))
        except (OSError, UnicodeEncodeError) as error:
            _fail(f"unable to enumerate iOS archive: {error}")
        child_directories: list[Path] = []
        for entry in entries:
            try:
                metadata = entry.lstat()
            except OSError as error:
                _fail(f"unable to inspect iOS archive entry: {error}")
            relative = _normalized_relative(entry, root)
            folded = relative.casefold()
            if folded in normalized_names:
                _fail("archive contains duplicate normalized paths")
            normalized_names.add(folded)
            if stat.S_ISDIR(metadata.st_mode):
                child_directories.append(entry)
                yield "directory", entry, metadata
            elif stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1:
                yield "file", entry, metadata
            else:
                _fail("archive contains a link, hard link, or special file")
        stack.extend(reversed(child_directories))


def archive_tree_identity(archive: Path) -> tuple[str, int, int]:
    root = _real_directory(archive, "iOS archive")
    digest = hashlib.sha256()
    file_count = 0
    total_bytes = 0
    for entry_type, path, metadata in _archive_entries(root):
        relative = _normalized_relative(path, root).encode("utf-8")
        digest.update(entry_type.encode("ascii") + b"\0")
        digest.update(len(relative).to_bytes(4, "big") + relative)
        digest.update(stat.S_IMODE(metadata.st_mode).to_bytes(4, "big"))
        if entry_type == "directory":
            continue
        file_count += 1
        total_bytes += metadata.st_size
        if file_count > MAX_ARCHIVE_FILES:
            _fail("archive file count exceeds the accepted bound")
        if metadata.st_size > MAX_ARCHIVE_FILE_BYTES:
            _fail("archive contains an oversized file")
        if total_bytes > MAX_ARCHIVE_TOTAL_BYTES:
            _fail("archive expanded size exceeds the accepted bound")
        digest.update(metadata.st_size.to_bytes(8, "big"))
        try:
            with path.open("rb") as handle:
                while True:
                    chunk = handle.read(1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
        except OSError as error:
            _fail(f"unable to read archive entry: {error}")
        try:
            after = path.stat()
        except OSError as error:
            _fail(f"unable to re-inspect archive entry: {error}")
        if (
            after.st_dev != metadata.st_dev
            or after.st_ino != metadata.st_ino
            or after.st_size != metadata.st_size
            or after.st_mtime_ns != metadata.st_mtime_ns
        ):
            _fail("archive changed while its identity was computed")
    if file_count < 1 or total_bytes < 1:
        _fail("archive does not contain any regular-file payload")
    return digest.hexdigest(), file_count, total_bytes


def file_sha256(path: Path, label: str) -> str:
    resolved = _regular_file(path, label, maximum_size=MAX_ARCHIVE_FILE_BYTES)
    before = resolved.stat()
    digest = hashlib.sha256()
    try:
        with resolved.open("rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError as error:
        _fail(f"unable to read {label}: {error}")
    try:
        after = resolved.stat()
    except OSError as error:
        _fail(f"unable to re-inspect {label}: {error}")
    if (
        after.st_dev != before.st_dev
        or after.st_ino != before.st_ino
        or after.st_size != before.st_size
        or after.st_mtime_ns != before.st_mtime_ns
    ):
        _fail(f"{label} changed while its reliability digest was computed")
    return digest.hexdigest()


def validate_release_testing_ipa(identity: dict[str, Any], ipa: Path) -> Path:
    validated_identity = validate_identity(identity)
    resolved = _regular_file(
        ipa, "release-testing IPA", maximum_size=MAX_ARCHIVE_FILE_BYTES
    )
    if file_sha256(resolved, "release-testing IPA") != validated_identity.get(
        "releaseTestingIpaSha256"
    ):
        _fail("release-testing IPA does not match the sealed archive identity")
    return resolved


def _single_ipa(export_directory: Path) -> Path:
    export_directory = _real_directory(export_directory, "release-testing export directory")
    candidates: list[Path] = []
    try:
        entries = list(export_directory.iterdir())
    except OSError as error:
        _fail(f"unable to inspect release-testing export directory: {error}")
    for entry in entries:
        if entry.suffix != ".ipa":
            continue
        candidates.append(
            _regular_file(entry, "release-testing IPA", maximum_size=MAX_ARCHIVE_FILE_BYTES)
        )
    if len(candidates) != 1:
        _fail("release-testing export directory must contain exactly one IPA")
    return candidates[0]


def _require_text(
    payload: dict[str, Any], key: str, pattern: re.Pattern[str], label: str
) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        _fail(f"{label} {key} is malformed")
    return value


def build_identity(
    *,
    archive: Path,
    release_testing_export_directory: Path,
    release_testing_acceptance_path: Path,
    expected_version: str,
    expected_build: str,
    expected_repository: str,
    expected_commit: str,
) -> dict[str, Any]:
    if VERSION_PATTERN.fullmatch(expected_version) is None:
        _fail("expected version is malformed")
    if BUILD_PATTERN.fullmatch(expected_build) is None:
        _fail("expected build is malformed")
    if REPOSITORY_PATTERN.fullmatch(expected_repository) is None:
        _fail("expected repository is malformed")
    if SOURCE_COMMIT_PATTERN.fullmatch(expected_commit) is None:
        _fail("expected source commit is malformed")

    app, widget, app_info, widget_info = archive_products(archive)
    acceptance = _read_json(
        release_testing_acceptance_path, "release-testing acceptance manifest"
    )
    ipa = _single_ipa(release_testing_export_directory)
    ipa_sha256 = file_sha256(ipa, "release-testing IPA")

    source_repository = _require_text(
        acceptance, "sourceRepository", REPOSITORY_PATTERN, "release-testing acceptance"
    )
    source_commit = _require_text(
        acceptance, "sourceCommit", SOURCE_COMMIT_PATTERN, "release-testing acceptance"
    )
    source_input_digest = _require_text(
        acceptance,
        "sourceInputDigest",
        DIGEST_PATTERN,
        "release-testing acceptance",
    )
    accepted_ipa_sha256 = _require_text(
        acceptance, "ipaSha256", DIGEST_PATTERN, "release-testing acceptance"
    )
    if acceptance.get("schemaVersion") != 1 or acceptance.get("acceptanceEligible") is not True:
        _fail("release-testing acceptance manifest is not acceptance eligible")
    if acceptance.get("sourceClean") is not True:
        _fail("release-testing acceptance manifest is not bound to clean source")
    if acceptance.get("productSurface") != "production":
        _fail("release-testing acceptance manifest is not a production product")
    if acceptance.get("releaseConfiguration") is not True:
        _fail("release-testing acceptance manifest is not a Release product")
    if acceptance.get("distributionSigning") is not True:
        _fail("release-testing acceptance manifest is not distribution signed")
    if accepted_ipa_sha256 != ipa_sha256:
        _fail("release-testing IPA does not match its acceptance manifest")
    if source_repository != expected_repository or source_commit != expected_commit:
        _fail("release-testing acceptance source does not match the requested release source")
    if (
        acceptance.get("releaseVersion") != expected_version
        or acceptance.get("releaseBuild") != expected_build
        or acceptance.get("releaseVersionVerified") is not True
    ):
        _fail("release-testing acceptance version/build does not match the requested release")

    expected_product_metadata = {
        "SkyBridgePackagingBuildConfiguration": "Release",
        "SkyBridgePackagingGitDirtyState": "clean",
        "SkyBridgePackagingGitCommit": expected_commit,
        "SkyBridgePackagingSourceInputDigest": source_input_digest,
        "SkyBridgePackagingSourceRepository": expected_repository,
        "SkyBridgePackagingProductSurface": "production",
        "SkyBridgePackagingSwiftActiveCompilationConditions": "HAS_APPLE_PQC_SDK",
    }
    release_app_info, release_widget_info, release_app_uuids, release_widget_uuids = (
        release_testing_products(release_testing_export_directory)
    )
    for label, product_info in (
        ("archived app", app_info),
        ("release-testing app", release_app_info),
    ):
        for key, expected in expected_product_metadata.items():
            if product_info.get(key) != expected:
                _fail(f"{label} provenance field {key} does not match release identity")
    archive_app_uuids = executable_uuids(
        bundle_executable(app, app_info, "archived app"), "archived app"
    )
    archive_widget_uuids = executable_uuids(
        bundle_executable(widget, widget_info, "archived Widget"), "archived Widget"
    )
    if release_app_uuids != archive_app_uuids or release_widget_uuids != archive_widget_uuids:
        _fail("release-testing IPA executables do not come from the sealed archive build")
    archive_debug_symbols(
        archive=archive,
        app=app,
        widget=widget,
        app_uuids=archive_app_uuids,
        widget_uuids=archive_widget_uuids,
    )

    for label, info, bundle_identifier in (
        ("archived app", app_info, APP_BUNDLE_IDENTIFIER),
        ("archived Widget", widget_info, WIDGET_BUNDLE_IDENTIFIER),
        ("release-testing app", release_app_info, APP_BUNDLE_IDENTIFIER),
        ("release-testing Widget", release_widget_info, WIDGET_BUNDLE_IDENTIFIER),
    ):
        if info.get("CFBundleIdentifier") != bundle_identifier:
            _fail(f"{label} bundle identifier does not match the release contract")
        if info.get("CFBundleShortVersionString") != expected_version:
            _fail(f"{label} version does not match the release contract")
        if info.get("CFBundleVersion") != expected_build:
            _fail(f"{label} build does not match the release contract")

    tree_sha256, file_count, total_bytes = archive_tree_identity(archive)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "identityPurpose": IDENTITY_PURPOSE,
        "archiveTreeSha256": tree_sha256,
        "archiveFileCount": file_count,
        "archiveTotalBytes": total_bytes,
        "appExecutableUUIDs": archive_app_uuids,
        "widgetExecutableUUIDs": archive_widget_uuids,
        "debugSymbolsVerified": True,
        "releaseTestingIpaSha256": ipa_sha256,
        "sourceRepository": source_repository,
        "sourceCommit": source_commit,
        "sourceInputDigest": source_input_digest,
        "releaseVersion": expected_version,
        "releaseBuild": expected_build,
        "appBundleIdentifier": APP_BUNDLE_IDENTIFIER,
        "widgetBundleIdentifier": WIDGET_BUNDLE_IDENTIFIER,
        "productSurface": "production",
        "buildConfiguration": "Release",
        "swiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
    }


def validate_identity(payload: dict[str, Any]) -> dict[str, Any]:
    if payload.get("schemaVersion") != SCHEMA_VERSION:
        _fail("archive identity schemaVersion is unsupported")
    if payload.get("identityPurpose") != IDENTITY_PURPOSE:
        _fail("archive identity purpose is invalid")
    for key in ("archiveTreeSha256", "releaseTestingIpaSha256", "sourceInputDigest"):
        _require_text(payload, key, DIGEST_PATTERN, "archive identity")
    _require_text(payload, "sourceCommit", SOURCE_COMMIT_PATTERN, "archive identity")
    _require_text(payload, "sourceRepository", REPOSITORY_PATTERN, "archive identity")
    _require_text(payload, "releaseVersion", VERSION_PATTERN, "archive identity")
    _require_text(payload, "releaseBuild", BUILD_PATTERN, "archive identity")
    if type(payload.get("archiveFileCount")) is not int or payload["archiveFileCount"] < 1:
        _fail("archive identity file count is invalid")
    if type(payload.get("archiveTotalBytes")) is not int or payload["archiveTotalBytes"] < 1:
        _fail("archive identity total size is invalid")
    for key in ("appExecutableUUIDs", "widgetExecutableUUIDs"):
        values = payload.get(key)
        if not isinstance(values, list) or not values:
            _fail(f"archive identity {key} is missing")
        normalized: list[dict[str, str]] = []
        for value in values:
            if not isinstance(value, dict) or set(value) != {"architecture", "uuid"}:
                _fail(f"archive identity {key} record is malformed")
            architecture = value.get("architecture")
            uuid = value.get("uuid")
            if (
                not isinstance(architecture, str)
                or re.fullmatch(r"[A-Za-z0-9_]+", architecture) is None
                or not isinstance(uuid, str)
                or re.fullmatch(
                    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                    uuid,
                )
                is None
            ):
                _fail(f"archive identity {key} record is invalid")
            normalized.append(value)
        if normalized != sorted(
            normalized, key=lambda value: (value["architecture"], value["uuid"])
        ) or len(normalized) != len(
            {(value["architecture"], value["uuid"]) for value in normalized}
        ):
            _fail(f"archive identity {key} must be sorted and unique")
        if not any(value["architecture"] in {"arm64", "arm64e"} for value in normalized):
            _fail(f"archive identity {key} must contain a 64-bit ARM slice")
    exact_values = {
        "appBundleIdentifier": APP_BUNDLE_IDENTIFIER,
        "widgetBundleIdentifier": WIDGET_BUNDLE_IDENTIFIER,
        "productSurface": "production",
        "buildConfiguration": "Release",
        "swiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
        "debugSymbolsVerified": True,
    }
    for key, expected in exact_values.items():
        if payload.get(key) != expected:
            _fail(f"archive identity {key} is invalid")
    return payload


def canonical_bytes(payload: dict[str, Any]) -> bytes:
    return (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")


def load_identity(path: Path) -> dict[str, Any]:
    payload = validate_identity(_read_json(path, "iOS archive identity"))
    if canonical_bytes(payload) != path.read_bytes():
        _fail("iOS archive identity is not canonical JSON")
    return payload


def write_identity(path: Path, payload: dict[str, Any]) -> None:
    if not path.is_absolute():
        _fail("archive identity output path must be absolute")
    parent = _real_directory(path.parent, "archive identity output parent")
    if os.path.lexists(path):
        _fail("archive identity output already exists")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(canonical_bytes(validate_identity(payload)))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_descriptor = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary.exists():
            temporary.unlink()


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("create", "verify"))
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--release-testing-export-dir", required=True, type=Path)
    parser.add_argument("--release-testing-acceptance", required=True, type=Path)
    parser.add_argument("--identity", required=True, type=Path)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--expected-build", required=True)
    parser.add_argument("--expected-repository", required=True)
    parser.add_argument("--expected-commit", required=True)
    return parser.parse_args()


def main() -> int:
    arguments = _parse_args()
    try:
        actual = build_identity(
            archive=arguments.archive,
            release_testing_export_directory=arguments.release_testing_export_dir,
            release_testing_acceptance_path=arguments.release_testing_acceptance,
            expected_version=arguments.expected_version,
            expected_build=arguments.expected_build,
            expected_repository=arguments.expected_repository,
            expected_commit=arguments.expected_commit,
        )
        if arguments.action == "create":
            write_identity(arguments.identity, actual)
            print(f"ios_archive_identity={arguments.identity}")
            return 0
        expected = load_identity(arguments.identity)
        if canonical_bytes(expected) != canonical_bytes(actual):
            _fail("iOS archive or release-testing IPA no longer matches its identity")
        print("ios_archive_identity=verified")
        return 0
    except ArchiveIdentityError as error:
        raise SystemExit(f"[ios-archive-identity] ERROR: {error}") from error


if __name__ == "__main__":
    raise SystemExit(main())
