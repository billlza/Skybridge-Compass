#!/usr/bin/env bash

android_packaging_forbidden_permission_present() {
  local permissions_file="$1"
  local permission_name="$2"
  rg -q "uses-permission: name='$permission_name'( |$)" "$permissions_file"
}

android_packaging_forbidden_manifest_surface_present() {
  local manifest_tree="$1"
  if rg -q \
    'android\.accessibilityservice\.AccessibilityService|android\.permission\.BIND_ACCESSIBILITY_SERVICE|android:foregroundServiceType.*mediaProjection' \
    "$manifest_tree"; then
    return 0
  fi
  python3 - "$manifest_tree" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="strict")
for line in text.splitlines():
    if "android:foregroundServiceType" not in line:
        continue
    match = re.search(r"\(type 0x11\)0x([0-9a-fA-F]+)", line)
    if match and int(match.group(1), 16) & 0x20:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

android_verify_release_audit_metadata() {
  local apk_path="$1"
  local mapping_path="$2"
  local metadata_path="$3"
  local expected_commit="$4"
  python3 - "$apk_path" "$mapping_path" "$metadata_path" "$expected_commit" <<'PY'
from pathlib import Path
import hashlib
import sys

apk_path, mapping_path, metadata_path = map(Path, sys.argv[1:4])
expected_commit = sys.argv[4]
metadata_lines = metadata_path.read_text(encoding="utf-8", errors="strict").splitlines()
metadata = {}
for line in metadata_lines:
    key, separator, value = line.partition("=")
    if not separator or not key or key in metadata:
        raise SystemExit("invalid release audit metadata")
    metadata[key] = value
if metadata.get("format") != "skybridge-release-apk-audit-v1":
    raise SystemExit("unsupported release audit metadata format")
if metadata.get("source.commit", "").lower() != expected_commit.lower():
    raise SystemExit("release audit metadata source commit mismatch")

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

if metadata.get("apk.sha256") != sha256(apk_path):
    raise SystemExit("release APK does not match its audit metadata")
if metadata.get("mapping.sha256") != sha256(mapping_path):
    raise SystemExit("R8 mapping does not match the release APK audit metadata")
PY
}

android_inspect_aab_archive() {
  local aab_path="$1"
  local modules_output="$2"
  local contents_output="$3"
  python3 - "$aab_path" "$modules_output" "$contents_output" <<'PY'
from pathlib import Path, PurePosixPath
import os
import stat
import sys
import zipfile

aab_path, modules_output, contents_output = map(Path, sys.argv[1:])
archive_stat = os.lstat(aab_path)
if not stat.S_ISREG(archive_stat.st_mode):
    raise SystemExit("AAB must be a non-symbolic-link regular file")
if archive_stat.st_size <= 0 or archive_stat.st_size > 4 * 1024**3:
    raise SystemExit("AAB compressed size is outside the supported audit bound")

with zipfile.ZipFile(aab_path) as archive:
    infos = archive.infolist()
    if not infos or len(infos) > 200_000:
        raise SystemExit("AAB entry count is outside the supported audit bound")
    names = [info.filename for info in infos]
    if len(names) != len(set(names)):
        raise SystemExit("AAB contains duplicate ZIP entry names")
    total_size = 0
    for info in infos:
        name = info.filename
        candidate = name[:-1] if name.endswith("/") else name
        parts = PurePosixPath(candidate).parts
        if (
            not candidate
            or name.startswith("/")
            or "\\" in name
            or any(ord(character) < 32 or ord(character) == 127 for character in name)
            or any(part in {"", ".", ".."} for part in parts)
            or (parts and ":" in parts[0])
        ):
            raise SystemExit(f"AAB contains an unsafe ZIP entry name: {name!r}")
        mode = (info.external_attr >> 16) & 0xFFFF
        if stat.S_ISLNK(mode):
            raise SystemExit(f"AAB contains a symbolic-link ZIP entry: {name!r}")
        if info.flag_bits & 0x1:
            raise SystemExit(f"AAB contains an encrypted ZIP entry: {name!r}")
        if info.file_size < 0 or info.file_size > 2 * 1024**3:
            raise SystemExit(f"AAB entry exceeds the supported audit bound: {name!r}")
        total_size += info.file_size
        if total_size > 8 * 1024**3:
            raise SystemExit("AAB expanded size exceeds the supported audit bound")
        if info.file_size and (
            info.compress_size == 0 or info.file_size / info.compress_size > 1000
        ):
            raise SystemExit(f"AAB entry exceeds the supported compression ratio: {name!r}")

    regular_names = {info.filename for info in infos if not info.is_dir()}
    required = {
        "BundleConfig.pb",
        "base/manifest/AndroidManifest.xml",
        "base/assets/skybridge-release/source.properties",
        "base/assets/third_party_licenses/webrtc-sdk.txt",
    }
    missing = sorted(required - regular_names)
    if missing:
        raise SystemExit(f"AAB is missing required entries: {missing}")
    modules = sorted(
        name.split("/", 1)[0]
        for name in regular_names
        if name.count("/") == 2 and name.endswith("/manifest/AndroidManifest.xml")
    )
    if modules != ["base"]:
        raise SystemExit(f"viewer-only AAB must contain exactly the base module, found {modules}")

modules_output.write_text("\n".join(modules) + "\n", encoding="utf-8")
contents_output.write_text("\n".join(sorted(names)) + "\n", encoding="utf-8")
PY
}

android_extract_archive_entry() {
  local archive_path="$1"
  local entry_name="$2"
  local output_path="$3"
  local maximum_bytes="${4:-2147483648}"
  python3 - "$archive_path" "$entry_name" "$output_path" "$maximum_bytes" <<'PY'
from pathlib import Path
import os
import shutil
import sys
import zipfile

archive_path = Path(sys.argv[1])
entry_name = sys.argv[2]
output_path = Path(sys.argv[3])
try:
    maximum_bytes = int(sys.argv[4], 10)
except ValueError as error:
    raise SystemExit("archive extraction bound must be an integer") from error
if maximum_bytes <= 0 or maximum_bytes > 2 * 1024**3:
    raise SystemExit("archive extraction bound is outside the supported range")
if output_path.exists() or output_path.is_symlink():
    raise SystemExit(f"refusing to replace archive extraction output: {output_path}")
if not output_path.parent.is_dir():
    raise SystemExit(f"archive extraction parent is missing: {output_path.parent}")

with zipfile.ZipFile(archive_path) as archive:
    matches = [info for info in archive.infolist() if info.filename == entry_name]
    if len(matches) != 1 or matches[0].is_dir():
        raise SystemExit(f"archive must contain exactly one regular {entry_name!r} entry")
    info = matches[0]
    if info.file_size > maximum_bytes:
        raise SystemExit(f"archive entry exceeds extraction bound: {entry_name!r}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(output_path, flags, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as output, archive.open(info) as source:
            shutil.copyfileobj(source, output, length=1024 * 1024)
            output.flush()
            os.fsync(output.fileno())
    except BaseException:
        output_path.unlink(missing_ok=True)
        raise
PY
}

android_inspect_generated_apks_archive() {
  local apks_path="$1"
  local contents_output="$2"
  python3 - "$apks_path" "$contents_output" <<'PY'
from pathlib import Path, PurePosixPath
import os
import stat
import sys
import zipfile

apks_path, contents_output = map(Path, sys.argv[1:])
archive_stat = os.lstat(apks_path)
if not stat.S_ISREG(archive_stat.st_mode):
    raise SystemExit("generated APKS must be a non-symbolic-link regular file")
if archive_stat.st_size <= 0 or archive_stat.st_size > 4 * 1024**3:
    raise SystemExit("generated APKS compressed size is outside the supported audit bound")
with zipfile.ZipFile(apks_path) as archive:
    infos = archive.infolist()
    names = [info.filename for info in infos]
    if not infos or len(infos) > 200_000 or len(names) != len(set(names)):
        raise SystemExit("generated APKS has an invalid or duplicate entry set")
    total_size = 0
    for info in infos:
        name = info.filename
        candidate = name[:-1] if name.endswith("/") else name
        parts = PurePosixPath(candidate).parts
        mode = (info.external_attr >> 16) & 0xFFFF
        if (
            not candidate
            or name.startswith("/")
            or "\\" in name
            or any(ord(character) < 32 or ord(character) == 127 for character in name)
            or any(part in {"", ".", ".."} for part in parts)
            or (parts and ":" in parts[0])
            or stat.S_ISLNK(mode)
            or info.flag_bits & 0x1
        ):
            raise SystemExit(f"generated APKS contains an unsafe entry: {name!r}")
        total_size += info.file_size
        if info.file_size > 2 * 1024**3 or total_size > 8 * 1024**3:
            raise SystemExit("generated APKS expanded size exceeds the supported audit bound")
        if info.file_size and (
            info.compress_size == 0 or info.file_size / info.compress_size > 1000
        ):
            raise SystemExit(f"generated APKS entry exceeds compression ratio: {name!r}")
    apk_names = [info.filename for info in infos if not info.is_dir() and info.filename.endswith(".apk")]
    if apk_names != ["universal.apk"]:
        raise SystemExit(f"universal APKS must contain exactly universal.apk, found {apk_names}")
contents_output.write_text("\n".join(sorted(names)) + "\n", encoding="utf-8")
PY
}

android_inspect_apk_archive() {
  local apk_path="$1"
  local contents_output="$2"
  python3 - "$apk_path" "$contents_output" <<'PY'
from pathlib import Path, PurePosixPath
import os
import re
import stat
import sys
import zipfile

apk_path, contents_output = map(Path, sys.argv[1:])
archive_stat = os.lstat(apk_path)
if not stat.S_ISREG(archive_stat.st_mode):
    raise SystemExit("universal APK must be a non-symbolic-link regular file")
if archive_stat.st_size <= 0 or archive_stat.st_size > 4 * 1024**3:
    raise SystemExit("universal APK compressed size is outside the supported audit bound")
with zipfile.ZipFile(apk_path) as archive:
    infos = archive.infolist()
    names = [info.filename for info in infos]
    if not infos or len(infos) > 200_000 or len(names) != len(set(names)):
        raise SystemExit("universal APK has an invalid or duplicate entry set")
    total_size = 0
    for info in infos:
        name = info.filename
        candidate = name[:-1] if name.endswith("/") else name
        parts = PurePosixPath(candidate).parts
        mode = (info.external_attr >> 16) & 0xFFFF
        if (
            not candidate
            or name.startswith("/")
            or "\\" in name
            or any(ord(character) < 32 or ord(character) == 127 for character in name)
            or any(part in {"", ".", ".."} for part in parts)
            or (parts and ":" in parts[0])
            or stat.S_ISLNK(mode)
            or info.flag_bits & 0x1
        ):
            raise SystemExit(f"universal APK contains an unsafe entry: {name!r}")
        total_size += info.file_size
        if info.file_size > 2 * 1024**3 or total_size > 8 * 1024**3:
            raise SystemExit("universal APK expanded size exceeds the supported audit bound")
        if info.file_size and (
            info.compress_size == 0 or info.file_size / info.compress_size > 1000
        ):
            raise SystemExit(f"universal APK entry exceeds compression ratio: {name!r}")
    regular_names = {info.filename for info in infos if not info.is_dir()}
    if "AndroidManifest.xml" not in regular_names:
        raise SystemExit("universal APK is missing AndroidManifest.xml")
    if not any(re.fullmatch(r"classes(?:[2-9]|[1-9][0-9]+)?\.dex", name) for name in regular_names):
        raise SystemExit("universal APK is missing classes*.dex")
contents_output.write_text("\n".join(sorted(names)) + "\n", encoding="utf-8")
PY
}

android_verify_release_aab_audit_metadata() {
  local aab_path="$1"
  local mapping_path="$2"
  local metadata_path="$3"
  local expected_commit="$4"
  python3 - "$aab_path" "$mapping_path" "$metadata_path" "$expected_commit" <<'PY'
from pathlib import Path
import hashlib
import os
import re
import stat
import sys

aab_path, mapping_path, metadata_path = map(Path, sys.argv[1:4])
expected_commit = sys.argv[4].lower()
for label, path in (
    ("AAB", aab_path),
    ("R8 mapping", mapping_path),
    ("AAB audit metadata", metadata_path),
):
    mode = os.lstat(path).st_mode
    if not stat.S_ISREG(mode):
        raise SystemExit(f"{label} must be a non-symbolic-link regular file")
if mapping_path.stat().st_size == 0:
    raise SystemExit("R8 mapping must not be empty")
if metadata_path.stat().st_size > 4096:
    raise SystemExit("AAB audit metadata exceeds the supported size")

metadata = {}
for line in metadata_path.read_text(encoding="utf-8", errors="strict").splitlines():
    key, separator, value = line.partition("=")
    if not separator or not key or not value or key in metadata:
        raise SystemExit("invalid AAB audit metadata")
    metadata[key] = value
expected_keys = {"format", "aab.sha256", "mapping.sha256", "source.commit"}
if set(metadata) != expected_keys:
    raise SystemExit("AAB audit metadata fields are incomplete or unexpected")
if metadata["format"] != "skybridge-release-aab-audit-v1":
    raise SystemExit("unsupported AAB audit metadata format")
if not re.fullmatch(r"[0-9a-f]{64}", metadata["aab.sha256"]):
    raise SystemExit("invalid AAB digest in audit metadata")
if not re.fullmatch(r"[0-9a-f]{64}", metadata["mapping.sha256"]):
    raise SystemExit("invalid mapping digest in AAB audit metadata")
if not re.fullmatch(r"[0-9a-fA-F]{40}", metadata["source.commit"]):
    raise SystemExit("invalid source commit in AAB audit metadata")
if metadata["source.commit"].lower() != expected_commit:
    raise SystemExit("AAB audit metadata source commit mismatch")

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

if metadata["aab.sha256"] != sha256(aab_path):
    raise SystemExit("release AAB does not match its audit metadata")
if metadata["mapping.sha256"] != sha256(mapping_path):
    raise SystemExit("R8 mapping does not match the release AAB audit metadata")
PY
}

android_verify_release_source_binding_file() {
  local binding_path="$1"
  local expected_commit="$2"
  python3 - "$binding_path" "$expected_commit" <<'PY'
from pathlib import Path
import re
import sys

binding_path = Path(sys.argv[1])
expected_commit = sys.argv[2].lower()
if binding_path.stat().st_size > 4096:
    raise SystemExit("release source binding exceeds the supported size")
fields = {}
for line in binding_path.read_text(encoding="utf-8", errors="strict").splitlines():
    key, separator, value = line.partition("=")
    if not separator or not key or not value or key in fields:
        raise SystemExit("invalid release source binding")
    fields[key] = value
if set(fields) != {"repository", "commit"}:
    raise SystemExit("release source binding fields are incomplete or unexpected")
if fields["repository"] != "skybridge-compass":
    raise SystemExit("release source binding repository mismatch")
if not re.fullmatch(r"[0-9a-fA-F]{40}", fields["commit"]):
    raise SystemExit("release source binding commit is invalid")
if fields["commit"].lower() != expected_commit:
    raise SystemExit("release source binding commit mismatch")
PY
}

android_verify_complete_jar_signature() {
  local archive_path="$1"
  python3 - "$archive_path" <<'PY'
from pathlib import PurePosixPath
import sys
import zipfile

archive_path = sys.argv[1]
with zipfile.ZipFile(archive_path) as archive:
    names = [info.filename for info in archive.infolist() if not info.is_dir()]
    manifest_matches = [name for name in names if name.upper() == "META-INF/MANIFEST.MF"]
    if len(manifest_matches) != 1:
        raise SystemExit("signed AAB must contain exactly one JAR manifest")
    upper_names = {name.upper() for name in names}
    signature_files = {
        name.rsplit(".", 1)[0].upper()
        for name in names
        if name.upper().startswith("META-INF/") and name.upper().endswith(".SF")
    }
    signature_blocks = {
        name.rsplit(".", 1)[0].upper()
        for name in names
        if name.upper().startswith("META-INF/")
        and name.upper().rsplit(".", 1)[-1] in {"RSA", "DSA", "EC"}
    }
    if not signature_files or not signature_files.intersection(signature_blocks):
        raise SystemExit("signed AAB is missing a matching JAR signature file and block")

    raw_manifest = archive.read(manifest_matches[0])
    if b"\x00" in raw_manifest:
        raise SystemExit("signed AAB JAR manifest contains a NUL byte")
    physical_lines = raw_manifest.replace(b"\r\n", b"\n").split(b"\n")
    logical_lines = []
    for line in physical_lines:
        if line.startswith(b" "):
            if not logical_lines or logical_lines[-1] == b"":
                raise SystemExit("signed AAB JAR manifest has an invalid continuation")
            logical_lines[-1] += line[1:]
        else:
            logical_lines.append(line)
    sections = []
    current = []
    for line in logical_lines:
        if line == b"":
            if current:
                sections.append(current)
                current = []
        else:
            current.append(line)
    if current:
        sections.append(current)

    signed_entries = set()
    for section in sections[1:]:
        attributes = {}
        for line in section:
            key, separator, value = line.partition(b": ")
            if not separator or key in attributes:
                raise SystemExit("signed AAB JAR manifest section is malformed")
            attributes[key] = value
        name = attributes.get(b"Name")
        if name is None or not any(key.endswith(b"-Digest") for key in attributes):
            raise SystemExit("signed AAB JAR manifest section lacks a name or digest")
        try:
            decoded_name = name.decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise SystemExit("signed AAB JAR manifest entry name is not UTF-8") from error
        if decoded_name in signed_entries:
            raise SystemExit("signed AAB JAR manifest contains duplicate entry sections")
        signed_entries.add(decoded_name)

    payload_entries = {
        name for name in names if not PurePosixPath(name).parts[0].upper() == "META-INF"
    }
    missing = sorted(payload_entries - signed_entries)
    if missing:
        raise SystemExit(f"signed AAB contains unsigned payload entries: {missing[:10]}")
PY
}

android_certificate_sha256_from_pem() {
  local certificate_path="$1"
  python3 - "$certificate_path" <<'PY'
from pathlib import Path
import base64
import hashlib
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="ascii", errors="strict")
matches = re.findall(
    r"-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----",
    text,
    flags=re.DOTALL,
)
if not matches:
    raise SystemExit("keytool did not return an AAB signer certificate")
der = base64.b64decode("".join(matches[0].split()), validate=True)
digest = hashlib.sha256(der).hexdigest().upper()
print(":".join(digest[index:index + 2] for index in range(0, len(digest), 2)))
PY
}

android_list_apk_dex_classes() {
  local apk_path="$1"
  local output_path="$2"
  python3 - "$apk_path" "$output_path" <<'PY'
from pathlib import Path
import re
import struct
import sys
import zipfile

apk_path, output_path = map(Path, sys.argv[1:])

def read_u32(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 4 > len(data):
        raise ValueError("DEX table offset is out of bounds")
    return struct.unpack_from("<I", data, offset)[0]

def skip_uleb128(data: bytes, offset: int) -> int:
    for _ in range(5):
        if offset >= len(data):
            raise ValueError("truncated DEX string length")
        value = data[offset]
        offset += 1
        if value & 0x80 == 0:
            return offset
    raise ValueError("invalid DEX string length")

def descriptors(data: bytes):
    if len(data) < 0x70 or data[:4] != b"dex\n" or data[7] != 0:
        raise ValueError("invalid DEX header")
    declared_size = read_u32(data, 0x20)
    if declared_size != len(data):
        raise ValueError("DEX file size does not match its header")
    string_count = read_u32(data, 0x38)
    string_offset = read_u32(data, 0x3C)
    type_count = read_u32(data, 0x40)
    type_offset = read_u32(data, 0x44)
    if string_count > 10_000_000 or type_count > 10_000_000:
        raise ValueError("DEX table count exceeds audit bounds")
    if string_offset + string_count * 4 > len(data):
        raise ValueError("DEX string table exceeds file bounds")
    if type_offset + type_count * 4 > len(data):
        raise ValueError("DEX type table exceeds file bounds")
    strings = []
    for index in range(string_count):
        cursor = skip_uleb128(data, read_u32(data, string_offset + index * 4))
        end = data.find(b"\x00", cursor)
        if end < 0:
            raise ValueError("unterminated DEX string")
        strings.append(data[cursor:end])
    for index in range(type_count):
        descriptor_index = read_u32(data, type_offset + index * 4)
        if descriptor_index >= len(strings):
            raise ValueError("DEX type references an invalid string index")
        raw = strings[descriptor_index]
        if raw.startswith(b"L") and raw.endswith(b";"):
            yield raw[1:-1].decode("ascii", errors="strict")

with zipfile.ZipFile(apk_path) as apk:
    dex_infos = sorted(
        (
            info for info in apk.infolist()
            if not info.is_dir()
            and re.fullmatch(r"classes(?:[2-9]|[1-9][0-9]+)?\.dex", info.filename)
        ),
        key=lambda info: info.filename,
    )
    if not dex_infos:
        raise SystemExit("universal APK contains no classes*.dex")
    if len(dex_infos) > 100:
        raise SystemExit("universal APK DEX entry count exceeds the audit bound")
    total_dex_size = sum(info.file_size for info in dex_infos)
    if total_dex_size > 1024**3:
        raise SystemExit("universal APK DEX payload exceeds the audit bound")
    classes = set()
    for info in dex_infos:
        if info.file_size > 512 * 1024**2:
            raise SystemExit(f"DEX entry exceeds audit bound: {info.filename}")
        classes.update(descriptors(apk.read(info)))

output_path.write_text("\n".join(sorted(classes)) + "\n", encoding="utf-8")
PY
}

android_r8_mapped_class_name() {
  local mapping_path="$1"
  local original_name="$2"
  python3 - "$mapping_path" "$original_name" <<'PY'
from pathlib import Path
import sys

mapping_path = Path(sys.argv[1])
original = sys.argv[2]
prefix = original + " -> "
matches = []
with mapping_path.open("r", encoding="utf-8", errors="strict") as mapping:
    for raw_line in mapping:
        line = raw_line.rstrip("\r\n")
        if line.startswith(prefix) and line.endswith(":"):
            matches.append(line[len(prefix):-1])
if len(matches) > 1:
    raise SystemExit(f"R8 mapping contains duplicate class entries for {original}")
if matches:
    print(matches[0])
PY
}

android_r8_original_class_prefix_present() {
  local mapping_path="$1"
  local original_prefix="$2"
  python3 - "$mapping_path" "$original_prefix" <<'PY'
from pathlib import Path
import sys

mapping_path = Path(sys.argv[1])
original_prefix = sys.argv[2]
with mapping_path.open("r", encoding="utf-8", errors="strict") as mapping:
    for raw_line in mapping:
        line = raw_line.rstrip("\r\n")
        if line.startswith(original_prefix) and " -> " in line and line.endswith(":"):
            raise SystemExit(0)
raise SystemExit(1)
PY
}

android_dex_class_or_nested_present() {
  local classes_path="$1"
  local descriptor="$2"
  python3 - "$classes_path" "$descriptor" <<'PY'
from pathlib import Path
import sys

classes_path = Path(sys.argv[1])
descriptor = sys.argv[2]
with classes_path.open("r", encoding="utf-8", errors="strict") as classes:
    for raw_line in classes:
        line = raw_line.rstrip("\r\n")
        if line == descriptor or line.startswith(descriptor + "$"):
            raise SystemExit(0)
raise SystemExit(1)
PY
}

android_audit_apk_elf_page_alignment() {
  local apk_path="$1"
  local llvm_objdump="$2"
  local report_path="$3"
  python3 - "$apk_path" "$llvm_objdump" "$report_path" <<'PY'
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import zipfile

apk_path = Path(sys.argv[1])
llvm_objdump = Path(sys.argv[2])
report_path = Path(sys.argv[3])
if not os.access(llvm_objdump, os.X_OK):
    raise SystemExit(f"NDK llvm-objdump is not executable: {llvm_objdump}")

required_16k_abis = {"arm64-v8a", "x86_64"}
observed_64_bit_abis = set()
report = []
failures = []
pattern = re.compile(r"^lib/([^/]+)/([^/]+\.so)$")
with zipfile.ZipFile(apk_path) as apk:
    libraries = []
    for info in apk.infolist():
        match = pattern.fullmatch(info.filename)
        if not info.is_dir() and match:
            libraries.append((info, match.group(1)))
    if not libraries:
        raise SystemExit("universal APK contains no native shared libraries")
    if len(libraries) > 512:
        raise SystemExit("native shared-library count exceeds the audit bound")
    if sum(info.file_size for info, _ in libraries) > 4 * 1024**3:
        raise SystemExit("native shared-library payload exceeds the audit bound")
    for info, abi in sorted(libraries, key=lambda item: item[0].filename):
        if info.file_size > 1024**3:
            raise SystemExit(f"native library exceeds extraction bound: {info.filename}")
        with tempfile.NamedTemporaryFile(prefix="skybridge-elf-", suffix=".so") as extracted:
            with apk.open(info) as source:
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk:
                        break
                    extracted.write(chunk)
            extracted.flush()
            output = subprocess.run(
                [str(llvm_objdump), "-p", extracted.name],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="strict",
                timeout=60,
            )
        if output.returncode != 0:
            raise SystemExit(
                f"llvm-objdump rejected {info.filename}: {output.stderr.strip()}"
            )
        alignments = []
        for line in output.stdout.splitlines():
            fields = line.split()
            if fields and fields[0] == "LOAD":
                try:
                    base, separator, exponent = fields[-1].partition("**")
                    if base != "2" or separator != "**":
                        raise ValueError("unexpected alignment expression")
                    alignment = 1 << int(exponent, 10)
                    alignments.append(alignment)
                except (ValueError, OverflowError) as error:
                    raise SystemExit(
                        f"could not parse PT_LOAD alignment for {info.filename}: {line}"
                    ) from error
        if not alignments:
            raise SystemExit(f"ELF contains no PT_LOAD segment: {info.filename}")
        minimum = min(alignments)
        requirement = "required" if abi in required_16k_abis else "reported-only"
        report.append(
            f"{info.filename}\tabi={abi}\tminimum_pt_load_align=0x{minimum:x}\t{requirement}"
        )
        if abi in required_16k_abis:
            observed_64_bit_abis.add(abi)
            if minimum < 0x4000:
                failures.append(
                    f"{info.filename} has PT_LOAD p_align 0x{minimum:x}, below 0x4000"
                )

missing_64_bit_abis = sorted(required_16k_abis - observed_64_bit_abis)
if missing_64_bit_abis:
    failures.append(
        f"universal APK is missing required 64-bit native ABI libraries: {missing_64_bit_abis}"
    )
report_path.write_text("\n".join(report) + "\n", encoding="utf-8")
if failures:
    raise SystemExit("; ".join(failures))
PY
}
