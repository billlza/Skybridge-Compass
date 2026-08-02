#!/usr/bin/env python3
"""Bind the packaged FreeRDP/OpenSSL runtime closure to its provenance.

The FreeRDP private dependency closure (FreeRDP, WinPR, OpenSSL, Jansson,
uriparser) ships as vendored dylibs whose bytes are pinned by
``Sources/Vendor/FreeRDPRuntime.provenance.json`` and whose build recipe is
pinned by ``Config/native-dependencies.lock.json``. Packaging copies those
dylibs into the app bundle and signing rewrites their code signature, so the
raw artifact hash is not stable across the release pipeline.

This gate proves three bindings for a built app bundle:

1. Every vendored closure dylib still matches the provenance byte pin.
2. Every packaged closure dylib is byte-identical to its vendored source once
   both code signatures are stripped (signature-invariant identity).
3. The packaged closure family contains exactly the pinned member set: the
   OpenSSL sonames recorded in the native dependency lock, no stale previous
   ABI generations (for example ``libssl.3.dylib``), and no unpinned extras.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path
from typing import NoReturn

CLOSURE_FAMILY_PREFIXES = (
    "libssl",
    "libcrypto",
    "libfreerdp",
    "libwinpr",
    "libjansson",
    "liburiparser",
)
LOCK_FAMILY = "freerdp-runtime"


def fail(message: str) -> NoReturn:
    raise SystemExit(f"freerdp runtime closure rejected: {message}")


def load_json(path: Path, label: str) -> dict:
    if not path.is_file():
        fail(f"missing {label}: {path}")
    try:
        with path.open("rb") as handle:
            loaded = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"unreadable {label} ({path}): {exc}")
    if not isinstance(loaded, dict):
        fail(f"{label} must be a JSON object: {path}")
    return loaded


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19


def normalize_linkedit_vmsize(macho: Path, source_label: str) -> None:
    """Zero the ``__LINKEDIT`` segment's ``vmsize`` in place.

    Signing grows ``__LINKEDIT`` to hold the signature blob and rounds
    ``vmsize`` up to a page boundary; ``codesign --remove-signature`` restores
    ``filesize`` but leaves the rounded ``vmsize`` behind. The residue depends
    on the size of whichever signature the file carried last (ad-hoc vs
    Developer ID + timestamp), so it is not part of the artifact's identity.
    Zeroing the field on both comparison sides keeps every other byte
    significant.
    """
    data = bytearray(macho.read_bytes())
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != MH_MAGIC_64:
        fail(
            f"{source_label} is not a thin 64-bit Mach-O; the closure gate "
            "only supports the vendored thin-arm64 layout"
        )
    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    patched = False
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmdsize < 8 or offset + cmdsize > len(data):
            fail(f"{source_label} has a corrupt Mach-O load command table")
        if cmd == LC_SEGMENT_64:
            segment_name = bytes(data[offset + 8 : offset + 24]).rstrip(b"\0")
            if segment_name == b"__LINKEDIT":
                struct.pack_into("<Q", data, offset + 32, 0)
                patched = True
        offset += cmdsize
    if not patched:
        fail(f"{source_label} has no __LINKEDIT segment to normalize")
    macho.write_bytes(bytes(data))


def signature_stripped_sha256(dylib: Path, scratch: Path) -> str:
    """Hash of the Mach-O with any code signature removed.

    ``codesign`` refuses to edit files in place safely for our purposes, so
    the file is copied into the scratch directory first. An unsigned input is
    a valid state (already stripped) and is hashed after the same
    normalization.
    """
    working_copy = scratch / f"stripped-{dylib.name}"
    shutil.copyfile(dylib, working_copy)

    probe = subprocess.run(
        ["codesign", "--display", str(working_copy)],
        capture_output=True,
        text=True,
        check=False,
    )
    if probe.returncode != 0:
        if "not signed at all" in (probe.stderr or ""):
            normalize_linkedit_vmsize(working_copy, str(dylib))
            return sha256_of(working_copy)
        fail(
            "unable to inspect code signature of "
            f"{dylib}: {probe.stderr.strip() or probe.returncode}"
        )

    removal = subprocess.run(
        ["codesign", "--remove-signature", str(working_copy)],
        capture_output=True,
        text=True,
        check=False,
    )
    if removal.returncode != 0:
        fail(
            "unable to strip code signature of "
            f"{dylib}: {removal.stderr.strip() or removal.returncode}"
        )
    normalize_linkedit_vmsize(working_copy, str(dylib))
    return sha256_of(working_copy)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--app-path",
        required=True,
        type=Path,
        help="Built .app bundle whose Frameworks directory is validated",
    )
    parser.add_argument(
        "--provenance",
        type=Path,
        default=None,
        help="FreeRDP runtime provenance JSON "
        "(default: <repo>/Sources/Vendor/FreeRDPRuntime.provenance.json)",
    )
    parser.add_argument(
        "--lock",
        type=Path,
        default=None,
        help="Native dependency lock JSON "
        "(default: <repo>/Config/native-dependencies.lock.json)",
    )
    parser.add_argument(
        "--vendor-root",
        type=Path,
        default=None,
        help="Repository root that provenance binary paths are relative to "
        "(default: the repository containing this script)",
    )
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    repo_root = Path(__file__).resolve().parent.parent
    vendor_root = (arguments.vendor_root or repo_root).resolve()
    provenance_path = arguments.provenance or (
        repo_root / "Sources/Vendor/FreeRDPRuntime.provenance.json"
    )
    lock_path = arguments.lock or (repo_root / "Config/native-dependencies.lock.json")

    app_path = arguments.app_path
    frameworks_dir = app_path / "Contents/Frameworks"
    if not frameworks_dir.is_dir():
        fail(f"missing app Frameworks directory: {frameworks_dir}")

    provenance = load_json(provenance_path, "FreeRDP runtime provenance")
    lock = load_json(lock_path, "native dependency lock")

    binaries = provenance.get("binaries")
    if not isinstance(binaries, list) or not binaries:
        fail(f"provenance declares no binaries: {provenance_path}")

    pinned: dict[str, tuple[Path, str]] = {}
    for entry in binaries:
        if not isinstance(entry, dict):
            fail("provenance binaries entries must be objects")
        raw_path = entry.get("path")
        expected_sha = entry.get("sha256")
        if not isinstance(raw_path, str) or not raw_path:
            fail("provenance binary entry is missing its path")
        if not isinstance(expected_sha, str) or len(expected_sha) != 64:
            fail(f"provenance binary entry has no byte pin: {raw_path}")
        vendored = vendor_root / raw_path
        basename = vendored.name
        if basename in pinned:
            fail(f"provenance pins duplicate closure member: {basename}")
        pinned[basename] = (vendored, expected_sha)

    family = lock.get("families", {}).get(LOCK_FAMILY)
    if not isinstance(family, dict):
        fail(f"native dependency lock has no {LOCK_FAMILY} family: {lock_path}")
    raw_sonames = family.get("build_inputs", {}).get("openssl_sonames")
    if not isinstance(raw_sonames, str) or not raw_sonames:
        fail(f"native dependency lock has no openssl_sonames pin: {lock_path}")
    openssl_sonames = {name for name in raw_sonames.split(";") if name}
    missing_sonames = sorted(openssl_sonames - set(pinned))
    if missing_sonames:
        fail(
            "lock openssl sonames are not pinned by provenance: "
            + ", ".join(missing_sonames)
        )

    packaged_family = {
        candidate.name
        for candidate in frameworks_dir.iterdir()
        if candidate.name.startswith(CLOSURE_FAMILY_PREFIXES)
        and candidate.name.endswith(".dylib")
    }
    unexpected = sorted(packaged_family - set(pinned))
    if unexpected:
        fail(
            "app bundle ships closure dylibs outside the pinned set "
            "(stale previous generation?): " + ", ".join(unexpected)
        )
    absent = sorted(set(pinned) - packaged_family)
    if absent:
        fail("app bundle is missing pinned closure dylibs: " + ", ".join(absent))

    with tempfile.TemporaryDirectory(prefix="freerdp-closure-gate-") as scratch_name:
        scratch = Path(scratch_name)
        for basename in sorted(pinned):
            vendored, expected_sha = pinned[basename]
            if not vendored.is_file():
                fail(f"missing vendored closure dylib: {vendored}")
            vendored_sha = sha256_of(vendored)
            if vendored_sha != expected_sha:
                fail(
                    f"vendored {basename} drifted from provenance pin "
                    f"(expected {expected_sha}, actual {vendored_sha})"
                )
            packaged = frameworks_dir / basename
            vendored_stripped = signature_stripped_sha256(vendored, scratch)
            packaged_stripped = signature_stripped_sha256(packaged, scratch)
            if vendored_stripped != packaged_stripped:
                fail(
                    f"packaged {basename} does not match the provenance-pinned "
                    "vendored bytes once signatures are stripped "
                    f"(vendored {vendored_stripped}, packaged {packaged_stripped})"
                )
            print(f"freerdp runtime closure member verified: {basename}")

    print(
        "freerdp runtime closure verified: "
        f"{len(pinned)} dylibs bound to provenance, openssl sonames "
        f"{sorted(openssl_sonames)} present, no unpinned family members"
    )


if __name__ == "__main__":
    main()
