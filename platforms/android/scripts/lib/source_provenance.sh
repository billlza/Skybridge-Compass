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
