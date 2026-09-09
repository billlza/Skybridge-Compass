#!/usr/bin/env python3
"""Fail-closed integrity and ABI gate for the vendored BoundSession XCFramework."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path


EXPECTED_INSTALL_NAME = "@rpath/BoundSessionFFI.framework/BoundSessionFFI"
EXPECTED_HEADER_SHA256 = "45deb5e3e05798d6120c866b1fbddc66b26c37b55547f6630e6e94311f5bf4a0"
EXPECTED_V1_NORMALIZED_SURFACE_SHA256 = (
    "078403a789b95d3aa4b9803aacbbfb45945b696788acbff9e95c44119dc9ffd0"
)
EXPECTED_SYMBOL_COUNT = 38
EXPECTED_V1_SYMBOL_COUNT = 33
EXPECTED_V2_SYMBOLS = {
    "bs_ffi_capabilities_v2",
    "bs_ffi_session_install_file_grant_v2",
    "bs_ffi_grant_evidence_projection_v2",
    "bs_ffi_grant_outbound_peek_v2",
    "bs_ffi_grant_confirm_outbound_delivery_v2",
}
EXPECTED_SLICES = {
    "macos-arm64": ("macos", None, "macosx", "-mmacosx-version-min=14.0"),
    "ios-arm64": ("ios", None, "iphoneos", "-miphoneos-version-min=17.0"),
    "ios-arm64-simulator": (
        "ios",
        "simulator",
        "iphonesimulator",
        "-mios-simulator-version-min=17.0",
    ),
}


def fail(message: str) -> None:
    raise SystemExit(f"BoundSession XCFramework verification failed: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def run(*arguments: str) -> str:
    result = subprocess.run(
        arguments,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        fail(
            f"command exited {result.returncode}: {' '.join(arguments)}: "
            f"{result.stderr.strip()}"
        )
    return result.stdout


def declared_symbols(header: Path) -> set[str]:
    source = header.read_text(encoding="utf-8")
    return set(re.findall(r"\b(bs_ffi_[a-z0-9_]+_v[12])\s*\(", source))


def exported_symbols(binary: Path) -> set[str]:
    output = run("nm", "-gU", str(binary))
    return {
        match.group(1)
        for line in output.splitlines()
        if (match := re.search(r"\b_(bs_ffi_[a-z0-9_]+_v[12])$", line))
    }


def normalized_v1_surface(header: Path) -> bytes:
    source = header.read_bytes()
    constants = re.findall(
        rb"(?m)^#define\s+(BS_FFI_[A-Z0-9_]+_V1)\s+([^\r\n]+)$",
        source,
    )
    structures = []
    for body, name in re.findall(
        rb"typedef\s+struct\s*\{([^}]*)\}\s*(BsFfi[A-Za-z0-9_]*V1)\s*;",
        source,
    ):
        body_without_comments = re.sub(rb"/\*.*?\*/", b"", body, flags=re.DOTALL)
        declarations = tuple(
            b" ".join(declaration.split())
            for declaration in body_without_comments.split(b";")
            if declaration.strip()
        )
        structures.append(name + b"{" + b";".join(declarations) + b"}")
    prototypes = []
    for return_type, name, parameters in re.findall(
        rb"(?ms)^(const\s+char\s*\*|uint32_t|uint64_t|int32_t)\s*"
        rb"(bs_ffi_[a-z0-9_]+_v1)\s*\((.*?)\);",
        source,
    ):
        prototypes.append(
            b" ".join(return_type.split())
            + b" "
            + name
            + b"("
            + b" ".join(parameters.split())
            + b")"
        )
    return b"\n".join(
        [name + b"=" + value.strip() for name, value in constants]
        + structures
        + prototypes
    ) + b"\n"


def verify_no_required_path_v1_calls(root: Path) -> None:
    forbidden = re.compile(
        r"\b(?:bs_ffi_session_install_file_grant_v1|"
        r"bs_ffi_grant_take_outbound_v1)\s*\("
    )
    offenders = []
    for path in sorted((root / "Sources").rglob("*.swift")):
        if forbidden.search(path.read_text(encoding="utf-8")):
            offenders.append(str(path.relative_to(root)))
    if offenders:
        fail(f"required Swift path calls legacy grant entry points: {offenders}")


def verify_slice_layout(
    layout_source: Path,
    header_directory: Path,
    sdk: str,
    deployment_flag: str,
) -> None:
    run(
        "xcrun",
        "--sdk",
        sdk,
        "clang",
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-pedantic",
        "-arch",
        "arm64",
        deployment_flag,
        "-I",
        str(header_directory),
        "-fsyntax-only",
        str(layout_source),
    )


def framework_payload_directory(framework: Path, identifier: str) -> Path:
    if identifier not in EXPECTED_SLICES:
        fail("unrecognized framework slice identifier")
    if framework.is_symlink() or not framework.is_dir():
        fail(f"{identifier} framework root is not a regular directory")
    if identifier == "macos-arm64":
        if {entry.name for entry in framework.iterdir()} != {
            "Versions", "BoundSessionFFI", "Headers", "Resources"
        }:
            fail("macos-arm64 requires exactly the versioned framework root entries")
        versions = framework / "Versions"
        payload = versions / "A"
        if versions.is_symlink() or not versions.is_dir():
            fail("macos-arm64 Versions must be a regular directory")
        if {entry.name for entry in versions.iterdir()} != {"A", "Current"}:
            fail("macos-arm64 permits only Versions/A and Versions/Current")
        links = {
            "Versions/Current": "A",
            "BoundSessionFFI": "Versions/Current/BoundSessionFFI",
            "Headers": "Versions/Current/Headers",
            "Resources": "Versions/Current/Resources",
        }
        for relative, target in links.items():
            link = framework / relative
            if not link.is_symlink() or os.readlink(link) != target:
                fail(f"macos-arm64 has a noncanonical {relative} link")
        if payload.is_symlink() or not payload.is_dir():
            fail("macos-arm64 Versions/A must be a regular directory")
        if {entry.name for entry in payload.iterdir()} != {
            "BoundSessionFFI", "Headers", "Resources", "_CodeSignature"
        }:
            fail("macos-arm64 version payload entries drifted")
        resources = payload / "Resources"
        if resources.is_symlink() or not resources.is_dir():
            fail("macos-arm64 Resources must be a regular directory")
        info_path = resources / "Info.plist"
    else:
        payload = framework
        if {entry.name for entry in framework.iterdir()} != {
            "BoundSessionFFI", "Headers", "Info.plist", "_CodeSignature"
        }:
            fail(f"{identifier} requires exactly the flat framework entries")
        info_path = payload / "Info.plist"
    for entry in payload.rglob("*"):
        if entry.is_symlink():
            fail(f"{identifier} contains a symlink inside its real payload")
    for directory in (payload / "Headers", payload / "_CodeSignature"):
        if directory.is_symlink() or not directory.is_dir():
            fail(f"{identifier} payload directory is missing or symlinked")
    for file_path in (
        payload / "BoundSessionFFI",
        payload / "Headers/bound_session_ffi.h",
        info_path,
    ):
        if file_path.is_symlink() or not file_path.is_file():
            fail(f"{identifier} payload file is missing or symlinked")
    return payload


def verify(
    root: Path,
    require_publishable_source: bool,
    xcframework_override: Path | None = None,
) -> None:
    xcframework = (
        xcframework_override
        if xcframework_override is not None
        else root / "Sources/Vendor/boundsession.xcframework"
    )
    c_header = root / "Sources/CBoundSession/include/bound_session_ffi.h"
    layout_source = root / "Scripts/boundsession_abi_v2_layout.c"
    provenance_path = xcframework / "SkyBridgeBoundSessionProvenance.json"
    if not xcframework.is_dir() or xcframework.is_symlink():
        fail("artifact root is missing or is a symlink")
    if not c_header.is_file() or c_header.is_symlink():
        fail("C target header is missing or is a symlink")
    if not layout_source.is_file() or layout_source.is_symlink():
        fail("ABI-v2 layout gate is missing or is a symlink")
    if provenance_path.is_symlink() or not provenance_path.is_file():
        fail("provenance must be a regular file")
    if (xcframework / "Info.plist").is_symlink() or not (xcframework / "Info.plist").is_file():
        fail("XCFramework Info.plist must be a regular file")
    if sha256(c_header) != EXPECTED_HEADER_SHA256:
        fail("C target header hash drifted")
    v1_surface_sha256 = hashlib.sha256(normalized_v1_surface(c_header)).hexdigest()
    if v1_surface_sha256 != EXPECTED_V1_NORMALIZED_SURFACE_SHA256:
        fail("normalized ABI-v1 surface drifted")
    verify_no_required_path_v1_calls(root)

    try:
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"provenance is unreadable: {error}")
    if provenance.get("schema_version") != 2:
        fail("provenance schema is not version 2")
    if provenance.get("abi_header_sha256") != EXPECTED_HEADER_SHA256:
        fail("provenance header hash drifted")
    if provenance.get("v1_normalized_surface_sha256") != EXPECTED_V1_NORMALIZED_SURFACE_SHA256:
        fail("provenance normalized ABI-v1 surface hash drifted")
    if provenance.get("exported_bs_ffi_symbol_count") != EXPECTED_SYMBOL_COUNT:
        fail("provenance symbol count is not 38")
    if provenance.get("v1_exported_bs_ffi_symbol_count") != EXPECTED_V1_SYMBOL_COUNT:
        fail("provenance ABI-v1 symbol count is not 33")
    if provenance.get("v2_exported_bs_ffi_symbol_count") != len(EXPECTED_V2_SYMBOLS):
        fail("provenance ABI-v2 symbol count is not 5")
    if provenance.get("capabilities_v2") != "0x0f":
        fail("provenance ABI-v2 capability set is not 0x0f")
    if require_publishable_source and not provenance.get("source_worktree_clean"):
        fail("publication requires a clean, committed BoundSession source snapshot")

    with (xcframework / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    libraries = {
        item["LibraryIdentifier"]: item
        for item in info.get("AvailableLibraries", [])
    }
    if set(libraries) != set(EXPECTED_SLICES):
        fail(f"slice set drifted: {sorted(libraries)}")

    expected_hashes = provenance.get("framework_binaries_after_adhoc_signing")
    if not isinstance(expected_hashes, dict):
        fail("provenance binary hash map is missing")
    expected_symbols = declared_symbols(c_header)
    v1_symbols = {symbol for symbol in expected_symbols if symbol.endswith("_v1")}
    v2_symbols = {symbol for symbol in expected_symbols if symbol.endswith("_v2")}
    if len(expected_symbols) != EXPECTED_SYMBOL_COUNT:
        fail(f"header declares {len(expected_symbols)} ABI symbols instead of 38")
    if len(v1_symbols) != EXPECTED_V1_SYMBOL_COUNT:
        fail(f"header declares {len(v1_symbols)} ABI-v1 symbols instead of 33")
    if v2_symbols != EXPECTED_V2_SYMBOLS:
        fail(f"header ABI-v2 symbol set drifted: {sorted(v2_symbols)}")

    for identifier, (platform, variant, sdk, deployment_flag) in EXPECTED_SLICES.items():
        library = libraries[identifier]
        slice_directory = xcframework / identifier
        if slice_directory.is_symlink() or not slice_directory.is_dir():
            fail(f"{identifier} slice must be a regular directory")
        if library.get("LibraryPath") != "BoundSessionFFI.framework":
            fail(f"{identifier} library path drifted")
        if library.get("SupportedArchitectures") != ["arm64"]:
            fail(f"{identifier} is not exactly arm64")
        if library.get("SupportedPlatform") != platform:
            fail(f"{identifier} platform drifted")
        if library.get("SupportedPlatformVariant") != variant:
            fail(f"{identifier} platform variant drifted")

        framework = xcframework / identifier / "BoundSessionFFI.framework"
        payload = framework_payload_directory(framework, identifier)
        binary = payload / "BoundSessionFFI"
        header = payload / "Headers/bound_session_ffi.h"
        if sha256(header) != EXPECTED_HEADER_SHA256:
            fail(f"{identifier} header hash drifted")
        relative_binary = binary.relative_to(xcframework).as_posix()
        if sha256(binary) != expected_hashes.get(relative_binary):
            fail(f"{identifier} signed binary hash drifted")
        if run("lipo", "-archs", str(binary)).strip() != "arm64":
            fail(f"{identifier} Mach-O architecture drifted")
        load_commands = run("otool", "-l", str(binary))
        if identifier == "macos-arm64" and not re.search(
            r"LC_BUILD_VERSION\s+cmdsize\s+\d+\s+platform\s+1\b",
            load_commands,
        ):
            fail("macos-arm64 Mach-O platform is not macOS")
        if identifier == "ios-arm64-simulator" and not re.search(
            r"LC_BUILD_VERSION\s+cmdsize\s+\d+\s+platform\s+7\b",
            load_commands,
        ):
            fail("ios-arm64-simulator Mach-O platform is not iOS Simulator")
        if identifier == "ios-arm64" and "LC_VERSION_MIN_IPHONEOS" not in load_commands:
            fail("ios-arm64 Mach-O platform is not iPhoneOS")
        install_names = [line.strip() for line in run("otool", "-D", str(binary)).splitlines()[1:]]
        if install_names != [EXPECTED_INSTALL_NAME]:
            fail(f"{identifier} install name drifted: {install_names}")
        dependencies = [
            line.strip().split(" (", 1)[0]
            for line in run("otool", "-L", str(binary)).splitlines()[1:]
        ]
        if not dependencies or dependencies[0] != EXPECTED_INSTALL_NAME:
            fail(f"{identifier} dependency identity drifted")
        if any("/Users/" in dependency for dependency in dependencies):
            fail(f"{identifier} leaks a local absolute dependency")
        if re.search(r"/Users/[^\s]+", run("/usr/bin/strings", "-a", str(binary))):
            fail(f"{identifier} leaks a local user build path")
        if exported_symbols(binary) != expected_symbols:
            fail(f"{identifier} exported ABI symbol set disagrees with the header")
        verify_slice_layout(
            layout_source,
            header.parent,
            sdk,
            deployment_flag,
        )
        run("codesign", "--verify", "--strict", "--verbose=2", str(framework))

    print(
        "BoundSession XCFramework verification passed: "
        "3 dynamic arm64 slices, exact 33 ABI-v1 + 5 ABI-v2 symbols, "
        "normalized ABI-v1 compatibility, per-slice C11 layouts, exact headers/hashes/"
        "install-name, strict ad-hoc signatures"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--require-publishable-source", action="store_true")
    parser.add_argument("--xcframework", type=Path)
    arguments = parser.parse_args()
    verify(
        arguments.root.resolve(),
        arguments.require_publishable_source,
        arguments.xcframework,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
