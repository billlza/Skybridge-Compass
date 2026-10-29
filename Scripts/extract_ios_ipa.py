#!/usr/bin/env python3
"""Safely extract the single iOS application from one Xcode-exported IPA.

The extractor is intentionally narrower than a general ZIP utility.  It accepts
one private export directory containing one IPA, validates the complete archive,
then atomically publishes exactly one App + Widget product at the requested
destination.  Success writes only the absolute application path to stdout.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import stat
import sys
import tempfile
import unicodedata
import zipfile
from pathlib import Path, PurePosixPath


MAX_IPA_BYTES = 1024 * 1024 * 1024
MAX_ENTRY_COUNT = 100_000
MAX_ENTRY_BYTES = 1024 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 4 * 1024 * 1024 * 1024


class IPAValidationError(ValueError):
    """Raised when an export or archive violates the extraction contract."""


def _require_private_directory(path: Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise IPAValidationError(f"{label} is unavailable") from error
    if path.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
        raise IPAValidationError(f"{label} must be a non-symlink directory")
    if metadata.st_uid != os.getuid():
        raise IPAValidationError(f"{label} must be owned by the current user")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise IPAValidationError(f"{label} must not be group- or world-writable")


def _require_regular_file(path: Path, label: str, *, maximum_size: int) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise IPAValidationError(f"{label} is unavailable") from error
    if path.is_symlink() or not stat.S_ISREG(metadata.st_mode):
        raise IPAValidationError(f"{label} must be a regular non-symlink file")
    if metadata.st_uid != os.getuid():
        raise IPAValidationError(f"{label} must be owned by the current user")
    if metadata.st_size <= 0 or metadata.st_size > maximum_size:
        raise IPAValidationError(f"{label} size is outside the accepted bound")


def _validated_parts(entry: zipfile.ZipInfo) -> tuple[str, ...]:
    name = entry.filename
    if not name or "\x00" in name or "\\" in name or name.startswith("/"):
        raise IPAValidationError("IPA contains an unsafe entry name")
    raw_parts = name.split("/")
    if entry.is_dir() or name.endswith("/"):
        raw_parts = raw_parts[:-1]
    if not raw_parts or any(part in {"", ".", ".."} for part in raw_parts):
        raise IPAValidationError("IPA contains an unsafe path component")
    path = PurePosixPath(*raw_parts)
    if path.is_absolute() or ".." in path.parts:
        raise IPAValidationError("IPA contains an unsafe path")
    return tuple(path.parts)


def _validate_entry_type(entry: zipfile.ZipInfo) -> None:
    if entry.flag_bits & 0x1:
        raise IPAValidationError("IPA contains an encrypted entry")
    unix_mode = (entry.external_attr >> 16) & 0xFFFF
    file_type = stat.S_IFMT(unix_mode)
    is_directory = entry.is_dir() or entry.filename.endswith("/")
    allowed_types = {0, stat.S_IFDIR} if is_directory else {0, stat.S_IFREG}
    if file_type not in allowed_types:
        raise IPAValidationError("IPA contains a link or special file")
    if entry.file_size < 0 or entry.file_size > MAX_ENTRY_BYTES:
        raise IPAValidationError("IPA entry size is outside the accepted bound")


def _safe_mode(entry: zipfile.ZipInfo, *, directory: bool) -> int:
    archived_mode = (entry.external_attr >> 16) & 0o777
    if archived_mode == 0:
        return 0o755 if directory else 0o644
    return archived_mode & 0o777


def _validate_bundle(bundle: Path, *, widget: bool) -> None:
    info_path = bundle / "Info.plist"
    profile_path = bundle / "embedded.mobileprovision"
    _require_regular_file(info_path, "bundle Info.plist", maximum_size=4 * 1024 * 1024)
    _require_regular_file(
        profile_path,
        "bundle provisioning profile",
        maximum_size=4 * 1024 * 1024,
    )
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise IPAValidationError("bundle Info.plist is invalid") from error
    executable_name = info.get("CFBundleExecutable")
    if (
        not isinstance(executable_name, str)
        or executable_name in {"", ".", ".."}
        or "/" in executable_name
        or "\\" in executable_name
    ):
        raise IPAValidationError("bundle executable name is invalid")
    executable_path = bundle / executable_name
    _require_regular_file(
        executable_path,
        "bundle executable",
        maximum_size=MAX_ENTRY_BYTES,
    )
    if executable_path.stat().st_mode & 0o111 == 0:
        raise IPAValidationError("bundle executable is not executable")
    expected_suffix = ".appex" if widget else ".app"
    if bundle.suffix != expected_suffix:
        raise IPAValidationError("bundle suffix is invalid")


def _archive_inventory(
    archive: zipfile.ZipFile,
) -> tuple[list[tuple[zipfile.ZipInfo, tuple[str, ...]]], tuple[str, str], tuple[str, ...]]:
    entries = archive.infolist()
    if not entries or len(entries) > MAX_ENTRY_COUNT:
        raise IPAValidationError("IPA entry count is outside the accepted bound")
    if sum(entry.file_size for entry in entries) > MAX_UNCOMPRESSED_BYTES:
        raise IPAValidationError("IPA expanded size is outside the accepted bound")

    inventory: list[tuple[zipfile.ZipInfo, tuple[str, ...]]] = []
    normalized_names: set[str] = set()
    app_names: set[str] = set()
    widget_names: set[tuple[str, ...]] = set()
    for entry in entries:
        _validate_entry_type(entry)
        parts = _validated_parts(entry)
        normalized = unicodedata.normalize("NFC", "/".join(parts)).casefold()
        if normalized in normalized_names:
            raise IPAValidationError("IPA contains duplicate normalized paths")
        normalized_names.add(normalized)
        inventory.append((entry, parts))
        if len(parts) >= 2 and parts[0] == "Payload" and parts[1].endswith(".app"):
            app_names.add(parts[1])
        if (
            len(parts) >= 4
            and parts[0] == "Payload"
            and parts[1].endswith(".app")
            and parts[2] == "PlugIns"
            and parts[3].endswith(".appex")
        ):
            widget_names.add(parts[:4])

    if len(app_names) != 1:
        raise IPAValidationError("IPA must contain exactly one Payload application")
    app_prefix = ("Payload", next(iter(app_names)))
    matching_widgets = {parts for parts in widget_names if parts[:2] == app_prefix}
    if len(matching_widgets) != 1:
        raise IPAValidationError("IPA application must contain exactly one Widget")
    return inventory, app_prefix, next(iter(matching_widgets))


def extract_ios_app_from_ipa(ipa_path: Path, destination_app: Path) -> Path:
    if not ipa_path.is_absolute() or not destination_app.is_absolute():
        raise IPAValidationError("IPA and destination paths must be absolute")
    if destination_app.suffix != ".app":
        raise IPAValidationError("destination must use an .app suffix")
    _require_regular_file(ipa_path, "exported IPA", maximum_size=MAX_IPA_BYTES)
    _require_private_directory(destination_app.parent, "destination parent directory")
    if os.path.lexists(destination_app):
        raise IPAValidationError("destination application already exists")

    staging_root = Path(
        tempfile.mkdtemp(prefix=".ios-ipa-stage-", dir=destination_app.parent)
    )
    os.chmod(staging_root, 0o700)
    staging_app = staging_root / destination_app.name
    published = False
    try:
        with zipfile.ZipFile(ipa_path) as archive:
            inventory, app_prefix, widget_prefix = _archive_inventory(archive)
            staging_app.mkdir(mode=0o700)
            explicit_directories: list[tuple[Path, int]] = []
            for entry, parts in inventory:
                if parts[:2] != app_prefix:
                    continue
                relative_parts = parts[2:]
                if not relative_parts:
                    if not entry.is_dir() and not entry.filename.endswith("/"):
                        raise IPAValidationError("Payload application root is not a directory")
                    explicit_directories.append(
                        (staging_app, _safe_mode(entry, directory=True))
                    )
                    continue
                target = staging_app.joinpath(*relative_parts)
                if entry.is_dir() or entry.filename.endswith("/"):
                    target.mkdir(mode=0o700, parents=True, exist_ok=True)
                    explicit_directories.append(
                        (target, _safe_mode(entry, directory=True))
                    )
                    continue
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                try:
                    with archive.open(entry, "r") as source, target.open("xb") as output:
                        shutil.copyfileobj(source, output, length=1024 * 1024)
                except FileExistsError as error:
                    raise IPAValidationError("IPA extraction target is duplicated") from error
                if target.stat().st_size != entry.file_size:
                    raise IPAValidationError("IPA entry size changed during extraction")
                os.chmod(target, _safe_mode(entry, directory=False))
            for directory, mode in reversed(explicit_directories):
                os.chmod(directory, mode)

        widget_relative = widget_prefix[2:]
        widget_path = staging_app.joinpath(*widget_relative)
        _validate_bundle(staging_app, widget=False)
        _validate_bundle(widget_path, widget=True)
        os.replace(staging_app, destination_app)
        published = True
        directory_descriptor = os.open(destination_app.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        if isinstance(error, IPAValidationError):
            raise
        raise IPAValidationError("unable to extract and validate the exported IPA") from error
    finally:
        if staging_root.exists():
            shutil.rmtree(staging_root)
        if not published and os.path.lexists(destination_app):
            raise IPAValidationError("failed extraction unexpectedly published a destination")

    return destination_app.resolve(strict=True)


def extract_single_ios_app(export_dir: Path, destination_app: Path) -> Path:
    if not export_dir.is_absolute() or not destination_app.is_absolute():
        raise IPAValidationError("export and destination paths must be absolute")
    _require_private_directory(export_dir, "iOS export directory")
    ipa_candidates = list(export_dir.glob("*.ipa"))
    if len(ipa_candidates) != 1:
        raise IPAValidationError("iOS export must contain exactly one IPA")
    return extract_ios_app_from_ipa(ipa_candidates[0], destination_app)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--export-dir", required=True, type=Path)
    parser.add_argument("--destination-app", required=True, type=Path)
    arguments = parser.parse_args(argv)
    try:
        app_path = extract_single_ios_app(
            arguments.export_dir,
            arguments.destination_app,
        )
    except IPAValidationError as error:
        print(f"iOS IPA extraction failed: {error}", file=sys.stderr)
        return 1
    print(app_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
