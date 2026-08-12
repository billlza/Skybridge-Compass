#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
AUDIT_SCRIPT="$ROOT_DIR/scripts/check_android_release_aab.sh"
POLICY_LIBRARY="$ROOT_DIR/scripts/lib/android_packaging_policy.sh"
# shellcheck source=scripts/lib/android_packaging_policy.sh
source "$POLICY_LIBRARY"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-aab-gate.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
COMMIT='0000000000000000000000000000000000000000'

fail() {
  echo "Android AAB gate test failed: $*" >&2
  exit 1
}

expect_failure() {
  local description="$1"
  shift
  if "$@" >"$TMP_DIR/expected-failure.stdout" 2>"$TMP_DIR/expected-failure.stderr"; then
    fail "$description unexpectedly passed"
  fi
}

[[ -x "$AUDIT_SCRIPT" ]] || fail 'formal AAB gate must be executable'
rg -Fq 'EXPECTED_BUNDLETOOL_VERSION="1.18.3"' "$AUDIT_SCRIPT" || {
  fail 'formal AAB gate must pin the official bundletool version'
}
rg -Fq 'Play distribution identity remains a separate release gate' "$AUDIT_SCRIPT" || {
  fail 'formal AAB gate must keep Play distribution signing separate from upload signing'
}
rg -Fq 'skybridge-aab-audit-signing.XXXXXX' "$AUDIT_SCRIPT" || {
  fail 'audit-only APK signing material must use a private temporary directory'
}
if rg -q 'AUDIT_KEYSTORE_(PATH|PASSWORD_FILE)="\$RUN_DIR/' "$AUDIT_SCRIPT"; then
  fail 'audit-only APK signing material must not be retained in the evidence directory'
fi
if "$AUDIT_SCRIPT" >"$TMP_DIR/missing-arguments.txt" 2>&1; then
  fail 'formal AAB gate unexpectedly accepted missing arguments'
fi
rg -Fq -- '--aab is required' "$TMP_DIR/missing-arguments.txt" || {
  fail 'formal AAB gate missing-argument failure is not explicit'
}

python3 - "$TMP_DIR" "$COMMIT" <<'PY'
from pathlib import Path
import hashlib
import stat
import struct
import sys
import warnings
import zipfile

root = Path(sys.argv[1])
commit = sys.argv[2]
source_binding = f"repository=skybridge-compass\ncommit={commit}\n".encode()
required = {
    "BundleConfig.pb": b"bundle-config",
    "base/manifest/AndroidManifest.xml": b"manifest-protobuf",
    "base/assets/skybridge-release/source.properties": source_binding,
    "base/assets/third_party_licenses/webrtc-sdk.txt": b"license",
}

def write_zip(name, entries):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(root / name, "w", compression=zipfile.ZIP_STORED) as archive:
            for entry_name, payload in entries:
                archive.writestr(entry_name, payload)

write_zip("valid.aab", required.items())
write_zip("traversal.aab", [*required.items(), ("../escape", b"bad")])
write_zip("control-character.aab", [*required.items(), ("base/assets/bad\nname", b"bad")])
write_zip(
    "duplicate.aab",
    [*required.items(), ("base/manifest/AndroidManifest.xml", b"duplicate")],
)
write_zip(
    "extra-module.aab",
    [*required.items(), ("feature/manifest/AndroidManifest.xml", b"feature")],
)
with zipfile.ZipFile(root / "symlink.aab", "w", compression=zipfile.ZIP_STORED) as archive:
    for entry_name, payload in required.items():
        archive.writestr(entry_name, payload)
    link = zipfile.ZipInfo("base/assets/link")
    link.create_system = 3
    link.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(link, b"../../outside")

mapping = root / "mapping.txt"
mapping.write_text(
    "com.example.Forbidden -> a.b:\n"
    "com.example.Nested -> x.y:\n",
    encoding="utf-8",
)
aab = root / "valid.aab"
(root / "metadata.properties").write_text(
    "format=skybridge-release-aab-audit-v1\n"
    f"aab.sha256={hashlib.sha256(aab.read_bytes()).hexdigest()}\n"
    f"mapping.sha256={hashlib.sha256(mapping.read_bytes()).hexdigest()}\n"
    f"source.commit={commit}\n",
    encoding="utf-8",
)
(root / "bad-metadata.properties").write_text(
    (root / "metadata.properties").read_text(encoding="utf-8") + "unexpected=true\n",
    encoding="utf-8",
)
(root / "source.properties").write_bytes(source_binding)
(root / "bad-source.properties").write_text(
    source_binding.decode() + f"commit={commit}\n",
    encoding="utf-8",
)

dex = bytearray(0x78)
dex[:8] = b"dex\n035\0"
struct.pack_into("<I", dex, 0x38, 1)
struct.pack_into("<I", dex, 0x3C, 0x70)
struct.pack_into("<I", dex, 0x40, 1)
struct.pack_into("<I", dex, 0x44, 0x74)
struct.pack_into("<I", dex, 0x70, 0x78)
struct.pack_into("<I", dex, 0x74, 0)
dex.extend(b"\x08Lfoo/Bar;\x00")
struct.pack_into("<I", dex, 0x20, len(dex))
write_zip(
    "universal.apk",
    [("AndroidManifest.xml", b"binary-manifest"), ("classes10.dex", bytes(dex))],
)
write_zip("universal.apks", [("universal.apk", (root / "universal.apk").read_bytes())])
write_zip(
    "multiple.apks",
    [
        ("universal.apk", (root / "universal.apk").read_bytes()),
        ("standalone.apk", (root / "universal.apk").read_bytes()),
    ],
)

def elf64(*load_alignments):
    data = bytearray(0x400)
    data[:16] = bytes([
        0x7f, ord("E"), ord("L"), ord("F"), 2, 1, 1, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    ])
    struct.pack_into("<HHIQQQIHHHHHH", data, 16,
        3, 183, 1, 0, 64, 0, 0, 64, 56, len(load_alignments), 0, 0, 0,
    )
    for index, load_alignment in enumerate(load_alignments):
        struct.pack_into("<IIQQQQQQ", data, 64 + index * 56,
            1, 5, 0, 0, 0, len(data), len(data), load_alignment,
        )
    return bytes(data)

write_zip(
    "aligned-elf.apk",
    [
        ("AndroidManifest.xml", b"binary-manifest"),
        ("classes.dex", bytes(dex)),
        ("lib/arm64-v8a/libaligned.so", elf64(0x4000)),
        ("lib/x86_64/libaligned.so", elf64(0x4000)),
        ("lib/x86/libreported-only.so", elf64(0x1000)),
    ],
)
write_zip(
    "unaligned-elf.apk",
    [
        ("AndroidManifest.xml", b"binary-manifest"),
        ("classes.dex", bytes(dex)),
        ("lib/arm64-v8a/libunaligned.so", elf64(0x4000, 0x1000)),
        ("lib/x86_64/libaligned.so", elf64(0x4000)),
    ],
)
PY

android_inspect_aab_archive \
  "$TMP_DIR/valid.aab" "$TMP_DIR/modules.txt" "$TMP_DIR/aab-contents.txt"
[[ "$(<"$TMP_DIR/modules.txt")" == 'base' ]] || fail 'valid AAB module list is incorrect'
expect_failure 'traversal AAB entry' \
  android_inspect_aab_archive \
    "$TMP_DIR/traversal.aab" "$TMP_DIR/traversal-modules.txt" "$TMP_DIR/traversal-contents.txt"
expect_failure 'control-character AAB entry' \
  android_inspect_aab_archive \
    "$TMP_DIR/control-character.aab" \
    "$TMP_DIR/control-character-modules.txt" \
    "$TMP_DIR/control-character-contents.txt"
expect_failure 'duplicate AAB entry' \
  android_inspect_aab_archive \
    "$TMP_DIR/duplicate.aab" "$TMP_DIR/duplicate-modules.txt" "$TMP_DIR/duplicate-contents.txt"
expect_failure 'extra AAB module' \
  android_inspect_aab_archive \
    "$TMP_DIR/extra-module.aab" "$TMP_DIR/extra-modules.txt" "$TMP_DIR/extra-contents.txt"
expect_failure 'symbolic-link AAB entry' \
  android_inspect_aab_archive \
    "$TMP_DIR/symlink.aab" "$TMP_DIR/symlink-modules.txt" "$TMP_DIR/symlink-contents.txt"

android_extract_archive_entry \
  "$TMP_DIR/valid.aab" \
  'base/assets/skybridge-release/source.properties' \
  "$TMP_DIR/extracted-source.properties"
expect_failure 'archive output replacement' \
  android_extract_archive_entry \
    "$TMP_DIR/valid.aab" \
    'base/assets/skybridge-release/source.properties' \
    "$TMP_DIR/extracted-source.properties"

android_verify_release_source_binding_file "$TMP_DIR/source.properties" "$COMMIT"
expect_failure 'duplicate source-binding field' \
  android_verify_release_source_binding_file "$TMP_DIR/bad-source.properties" "$COMMIT"
android_verify_release_aab_audit_metadata \
  "$TMP_DIR/valid.aab" "$TMP_DIR/mapping.txt" "$TMP_DIR/metadata.properties" "$COMMIT"
expect_failure 'unexpected AAB metadata field' \
  android_verify_release_aab_audit_metadata \
    "$TMP_DIR/valid.aab" "$TMP_DIR/mapping.txt" "$TMP_DIR/bad-metadata.properties" "$COMMIT"
printf '%s\n' 'changed mapping' >"$TMP_DIR/changed-mapping.txt"
expect_failure 'mismatched AAB mapping' \
  android_verify_release_aab_audit_metadata \
    "$TMP_DIR/valid.aab" "$TMP_DIR/changed-mapping.txt" "$TMP_DIR/metadata.properties" "$COMMIT"

cp "$TMP_DIR/valid.aab" "$TMP_DIR/signed.aab"
keytool -genkeypair \
  -alias aab-gate-test \
  -keystore "$TMP_DIR/test.p12" \
  -storetype PKCS12 \
  -storepass 'aab-gate-test-password' \
  -keypass 'aab-gate-test-password' \
  -keyalg RSA \
  -keysize 2048 \
  -validity 1 \
  -dname 'CN=AAB Gate Test' \
  -noprompt >"$TMP_DIR/keytool.txt" 2>&1
jarsigner \
  -keystore "$TMP_DIR/test.p12" \
  -storetype PKCS12 \
  -storepass 'aab-gate-test-password' \
  -keypass 'aab-gate-test-password' \
  "$TMP_DIR/signed.aab" aab-gate-test >"$TMP_DIR/jarsigner.txt" 2>&1
android_verify_complete_jar_signature "$TMP_DIR/signed.aab"
printf '%s\n' 'unsigned' >"$TMP_DIR/unsigned.txt"
(cd "$TMP_DIR" && zip -q signed.aab unsigned.txt)
expect_failure 'unsigned AAB payload entry' \
  android_verify_complete_jar_signature "$TMP_DIR/signed.aab"

android_inspect_generated_apks_archive \
  "$TMP_DIR/universal.apks" "$TMP_DIR/apks-contents.txt"
expect_failure 'multiple APKs in universal APKS' \
  android_inspect_generated_apks_archive \
    "$TMP_DIR/multiple.apks" "$TMP_DIR/multiple-apks-contents.txt"
android_inspect_apk_archive "$TMP_DIR/universal.apk" "$TMP_DIR/apk-contents.txt"
android_list_apk_dex_classes "$TMP_DIR/universal.apk" "$TMP_DIR/classes.txt"
rg -Fqx 'foo/Bar' "$TMP_DIR/classes.txt" || fail 'bounded DEX parser missed class descriptor'
android_dex_class_or_nested_present "$TMP_DIR/classes.txt" 'foo/Bar' || {
  fail 'DEX class membership helper missed an exact class'
}

[[ "$(android_r8_mapped_class_name "$TMP_DIR/mapping.txt" 'com.example.Forbidden')" == 'a.b' ]] || {
  fail 'R8 mapped-name resolver returned the wrong class'
}
android_r8_original_class_prefix_present "$TMP_DIR/mapping.txt" 'com.example.' || {
  fail 'R8 original class-prefix detector missed a forbidden module mapping'
}
if android_r8_original_class_prefix_present "$TMP_DIR/mapping.txt" 'com.allowed.'; then
  fail 'R8 original class-prefix detector reported an unrelated mapping'
fi
printf '%s\n' \
  'com.example.Forbidden -> a.b:' \
  'com.example.Forbidden -> c.d:' >"$TMP_DIR/duplicate-mapping.txt"
expect_failure 'duplicate R8 class mapping' \
  android_r8_mapped_class_name "$TMP_DIR/duplicate-mapping.txt" 'com.example.Forbidden'

SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
case "$(uname -s)" in
  Darwin) NDK_HOST_PREBUILT="darwin-x86_64" ;;
  Linux) NDK_HOST_PREBUILT="linux-x86_64" ;;
  *) fail "unsupported NDK host operating system: $(uname -s)" ;;
esac
LLVM_OBJDUMP="$SDK_ROOT/ndk/30.0.14904198/toolchains/llvm/prebuilt/$NDK_HOST_PREBUILT/bin/llvm-objdump"
[[ -x "$LLVM_OBJDUMP" ]] || fail 'fixed NDK 30.0.14904198 llvm-objdump is unavailable'
ZIPALIGN="$SDK_ROOT/build-tools/37.0.0/zipalign"
[[ -x "$ZIPALIGN" ]] || fail 'fixed Build Tools 37.0.0 zipalign is unavailable'
android_audit_apk_elf_page_alignment \
  "$TMP_DIR/aligned-elf.apk" "$LLVM_OBJDUMP" "$TMP_DIR/aligned-elf-report.txt"
rg -Fq $'lib/x86/libreported-only.so\tabi=x86\tminimum_pt_load_align=0x1000\treported-only' \
  "$TMP_DIR/aligned-elf-report.txt" || {
  fail '32-bit ELF alignment was not recorded as non-blocking evidence'
}
expect_failure '4 KB arm64 PT_LOAD alignment' \
  android_audit_apk_elf_page_alignment \
    "$TMP_DIR/unaligned-elf.apk" "$LLVM_OBJDUMP" "$TMP_DIR/unaligned-elf-report.txt"
expect_failure 'unaligned native-library ZIP entry' \
  "$ZIPALIGN" -c -P 16 -v 4 "$TMP_DIR/aligned-elf.apk"
"$ZIPALIGN" -P 16 -f 4 \
  "$TMP_DIR/aligned-elf.apk" "$TMP_DIR/zipaligned-elf.apk" >/dev/null
"$ZIPALIGN" -c -P 16 -v 4 \
  "$TMP_DIR/zipaligned-elf.apk" >"$TMP_DIR/zipaligned-elf-report.txt"

echo 'Android formal AAB gate tests passed'
