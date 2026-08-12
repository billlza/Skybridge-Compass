#!/usr/bin/env bash

android_collect_source_provenance() {
  local root_dir="$1"
  local output_dir="$2"

  mkdir -p "$output_dir"
  python3 - "$root_dir" "$output_dir" <<'PY'
import hashlib
import os
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
output_dir = Path(sys.argv[2]).resolve()
manifest_path = output_dir / "android-source-manifest.sha256"

allowed_top_dirs = {
    "app",
    "baselineprofile",
    "core",
    "device-discovery",
    "docs",
    "file-transfer",
    "gradle",
    "libs",
    "remote-control",
    "scripts",
    "shared",
}
allowed_root_files = {
    "ANDROID_DEVELOPMENT_SPECIFICATION_2025.md",
    "Android_PQC_Implementation.md",
    "CrossPlatformDiscoveryDesign.md",
    "README.md",
    "build.gradle",
    "build.gradle.kts",
    "gradle.properties",
    "gradlew",
    "gradlew.bat",
    "settings.gradle",
    "settings.gradle.kts",
}
excluded_parts = {
    ".cxx",
    ".git",
    ".gradle",
    ".idea",
    ".kotlin",
    "__pycache__",
    "build",
}
excluded_names = {
    ".DS_Store",
    "local.properties",
}
excluded_suffixes = {
    ".jks",
    ".key",
    ".keystore",
    ".p12",
    ".pem",
}

def is_allowed(relative: Path) -> bool:
    if any(part in excluded_parts for part in relative.parts):
        return False
    if relative.name in excluded_names:
        return False
    if relative.suffix.lower() in excluded_suffixes:
        return False
    if len(relative.parts) == 1:
        return relative.name in allowed_root_files or relative.suffix.lower() == ".md"
    return relative.parts[0] in allowed_top_dirs

entries: list[tuple[str, int, str]] = []
for current_root, dirs, files in os.walk(root):
    current = Path(current_root)
    dirs[:] = sorted(
        dirname for dirname in dirs
        if dirname not in excluded_parts
    )
    for filename in sorted(files):
        path = current / filename
        relative = path.relative_to(root)
        if not is_allowed(relative):
            continue
        resolved = path.resolve()
        try:
            resolved.relative_to(root)
        except ValueError as exc:
            raise SystemExit(f"path escapes source root: {path}") from exc
        try:
            data = resolved.read_bytes()
        except OSError as exc:
            raise SystemExit(f"unable to read source input {relative}: {exc}") from exc
        digest = hashlib.sha256(data).hexdigest()
        entries.append((digest, len(data), relative.as_posix()))

if not entries:
    raise SystemExit("android source provenance manifest is empty")

manifest_body = "".join(
    f"{digest}  {size}  {relative}\n"
    for digest, size, relative in sorted(entries, key=lambda item: item[2])
)
output_dir.mkdir(parents=True, exist_ok=True)
manifest_path.write_text(manifest_body, encoding="utf-8")
manifest_digest = hashlib.sha256(manifest_body.encode("utf-8")).hexdigest()

print("android_source_provenance_mode=non_git_manifest")
print(f"android_source_manifest_path={manifest_path}")
print(f"android_source_manifest_sha256={manifest_digest}")
print(f"android_source_manifest_file_count={len(entries)}")
PY
}

android_collect_apk_provenance() {
  local apk_path="$1"
  local field_prefix="$2"

  python3 - "$apk_path" "$field_prefix" <<'PY'
import hashlib
from pathlib import Path
import sys

apk_path = Path(sys.argv[1]).resolve()
prefix = sys.argv[2].strip()
if not prefix:
    raise SystemExit("missing APK provenance field prefix")
if not apk_path.is_file():
    raise SystemExit(f"APK provenance input is missing: {apk_path}")

data = apk_path.read_bytes()
print(f"{prefix}_path={apk_path}")
print(f"{prefix}_sha256={hashlib.sha256(data).hexdigest()}")
print(f"{prefix}_bytes={len(data)}")
PY
}

android_require_apk_provenance_unchanged() {
  local apk_path="$1"
  local field_prefix="$2"
  local expected_snapshot="$3"
  local current_snapshot=""

  if [[ ! -f "$expected_snapshot" || -L "$expected_snapshot" ]]; then
    echo "Expected APK provenance snapshot is missing or unsafe: $expected_snapshot" >&2
    return 1
  fi
  current_snapshot="$(mktemp "${TMPDIR:-/tmp}/skybridge-apk-provenance.XXXXXX")" || return 1
  if ! android_collect_apk_provenance "$apk_path" "$field_prefix" >"$current_snapshot"; then
    rm -f -- "$current_snapshot"
    return 1
  fi
  if ! cmp -s -- "$expected_snapshot" "$current_snapshot"; then
    echo "APK provenance changed after the fixed build: $apk_path" >&2
    rm -f -- "$current_snapshot"
    return 1
  fi
  rm -f -- "$current_snapshot"
}

skybridge_collect_ios_app_provenance() {
  local app_path="$1"
  local field_prefix="$2"
  local expected_bundle_id="$3"

  python3 - "$app_path" "$field_prefix" "$expected_bundle_id" <<'PY'
import hashlib
import os
import plistlib
import re
import stat
import sys
from pathlib import Path

app_path = Path(sys.argv[1]).resolve()
prefix = sys.argv[2].strip()
expected_bundle_id = sys.argv[3].strip()
if re.fullmatch(r"[a-z][a-z0-9_]*", prefix) is None:
    raise SystemExit("invalid iOS app provenance field prefix")
if not expected_bundle_id:
    raise SystemExit("missing expected iOS bundle identifier")
metadata = os.lstat(app_path)
if not stat.S_ISDIR(metadata.st_mode):
    raise SystemExit(f"iOS app provenance input is not a real directory: {app_path}")

info_path = app_path / "Info.plist"
try:
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
except (OSError, plistlib.InvalidFileException) as exc:
    raise SystemExit(f"iOS app Info.plist is invalid: {exc}") from exc
if not isinstance(info, dict) or info.get("CFBundleIdentifier") != expected_bundle_id:
    raise SystemExit("iOS app bundle identifier does not match the requested product")
executable_name = info.get("CFBundleExecutable")
version = info.get("CFBundleShortVersionString")
build = info.get("CFBundleVersion")
if not all(isinstance(value, str) and value for value in (executable_name, version, build)):
    raise SystemExit("iOS app executable/version/build identity is incomplete")

entries: list[tuple[str, int, int, str]] = []
total_bytes = 0
for current_root, directories, files in os.walk(app_path, topdown=True, followlinks=False):
    current = Path(current_root)
    for name in sorted(directories):
        path = current / name
        item = os.lstat(path)
        if stat.S_ISLNK(item.st_mode) or not stat.S_ISDIR(item.st_mode):
            raise SystemExit(f"iOS app contains an unsafe directory entry: {path.relative_to(app_path)}")
    directories.sort()
    for name in sorted(files):
        path = current / name
        relative = path.relative_to(app_path).as_posix()
        if "\n" in relative or "\r" in relative:
            raise SystemExit("iOS app contains a non-canonical path")
        before = os.lstat(path)
        if not stat.S_ISREG(before.st_mode):
            raise SystemExit(f"iOS app contains a non-regular file: {relative}")
        digest = hashlib.sha256()
        with path.open("rb", buffering=0) as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
        after = os.lstat(path)
        stable_fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns")
        if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
            raise SystemExit(f"iOS app file changed while hashing: {relative}")
        total_bytes += before.st_size
        entries.append((relative, stat.S_IMODE(before.st_mode), before.st_size, digest.hexdigest()))
        if len(entries) > 100_000:
            raise SystemExit("iOS app contains too many files for bounded provenance")

if not entries:
    raise SystemExit("iOS app provenance manifest is empty")
manifest = "".join(
    f"{len(relative)}:{relative}\0{mode:o}\0{size}\0{digest}\n"
    for relative, mode, size, digest in entries
).encode("utf-8")
executable_path = app_path / executable_name
executable_entry = next((entry for entry in entries if entry[0] == executable_name), None)
if executable_entry is None or not os.access(executable_path, os.X_OK):
    raise SystemExit("iOS app executable is missing or not executable")

print(f"{prefix}_path={app_path}")
print(f"{prefix}_bundle_id={expected_bundle_id}")
print(f"{prefix}_version={version}")
print(f"{prefix}_build={build}")
print(f"{prefix}_executable={executable_name}")
print(f"{prefix}_executable_sha256={executable_entry[3]}")
print(f"{prefix}_tree_sha256={hashlib.sha256(manifest).hexdigest()}")
print(f"{prefix}_file_count={len(entries)}")
print(f"{prefix}_bytes={total_bytes}")
PY
}

skybridge_require_ios_app_provenance_unchanged() {
  local app_path="$1"
  local field_prefix="$2"
  local expected_bundle_id="$3"
  local expected_snapshot="$4"
  local current_snapshot=""

  if [[ ! -f "$expected_snapshot" || -L "$expected_snapshot" ]]; then
    echo "Expected iOS app provenance snapshot is missing or unsafe: $expected_snapshot" >&2
    return 1
  fi
  current_snapshot="$(mktemp "${TMPDIR:-/tmp}/skybridge-ios-app-provenance.XXXXXX")" || return 1
  if ! skybridge_collect_ios_app_provenance \
    "$app_path" "$field_prefix" "$expected_bundle_id" >"$current_snapshot"; then
    rm -f -- "$current_snapshot"
    return 1
  fi
  if ! cmp -s -- "$expected_snapshot" "$current_snapshot"; then
    echo "iOS app provenance changed after the fixed build: $app_path" >&2
    rm -f -- "$current_snapshot"
    return 1
  fi
  rm -f -- "$current_snapshot"
}
