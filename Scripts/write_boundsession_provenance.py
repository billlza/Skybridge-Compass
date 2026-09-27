#!/usr/bin/env python3
"""Write deterministic provenance for one staged BoundSession XCFramework."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


SLICE_IDENTIFIERS = (
    "macos-arm64",
    "ios-arm64",
    "ios-arm64-simulator",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def verified_source_snapshot(source_root: Path, expected: Path) -> dict:
    helper = source_root / "native_source_snapshot.py"
    if helper.is_symlink() or not helper.is_file():
        raise ValueError("canonical native snapshot helper is unavailable")
    spec = importlib.util.spec_from_file_location("boundsession_native_snapshot", helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.verify(source_root, expected)


def parse_bool(raw: str) -> bool:
    if raw == "true":
        return True
    if raw == "false":
        return False
    raise ValueError(f"invalid boolean: {raw}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--source-snapshot", type=Path, required=True)
    parser.add_argument("--candidate-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--header-sha256", required=True)
    parser.add_argument("--v1-surface-sha256", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--source-worktree-clean", required=True)
    parser.add_argument("--cargo-lock-sha256", required=True)
    parser.add_argument("--rustc", required=True)
    parser.add_argument("--cargo", required=True)
    parser.add_argument("--llvm", required=True)
    arguments = parser.parse_args()

    source_root = arguments.source_root.resolve(strict=True)
    candidate_root = arguments.candidate_root.resolve(strict=True)
    output = arguments.output.resolve()
    if output.parent != candidate_root:
        raise SystemExit("provenance output must be directly inside the candidate root")

    binary_hashes = {}
    for identifier in SLICE_IDENTIFIERS:
        payload = "Versions/A/" if identifier == "macos-arm64" else ""
        relative = f"{identifier}/BoundSessionFFI.framework/{payload}BoundSessionFFI"
        binary_hashes[relative] = sha256(candidate_root / relative)

    source_snapshot = verified_source_snapshot(source_root, arguments.source_snapshot)
    document = {
        "schema_version": 2,
        "component": "BoundSession FFI",
        "version": "0.1.0",
        "abi_major": 1,
        "additive_abi_version": 3,
        "abi_header_sha256": arguments.header_sha256,
        "v1_normalized_surface_sha256": arguments.v1_surface_sha256,
        "exported_bs_ffi_symbol_count": 41,
        "v1_exported_bs_ffi_symbol_count": 33,
        "v2_exported_bs_ffi_symbol_count": 6,
        "v3_exported_bs_ffi_symbol_count": 2,
        "capabilities_v3": "0x1",
        "capabilities_v2": "0x3f",
        "source_revision": arguments.source_revision,
        "source_worktree_clean": parse_bool(arguments.source_worktree_clean),
        "source_snapshot_sha256": source_snapshot["sha256"],
        "source_snapshot_method": source_snapshot["schema"],
        "source_snapshot": source_snapshot,
        "source_capture_contract": "before build and checked before local artifact installation; not ABA detection",

        "cargo_lock_sha256": arguments.cargo_lock_sha256,
        "rust_toolchain": {
            "rustc": arguments.rustc.removeprefix("rustc "),
            "cargo": arguments.cargo.removeprefix("cargo "),
            "llvm": arguments.llvm,
        },
        "build_contract": {
            "profile": "release",
            "locked": True,
            "warnings_as_errors": True,
            "target_directory_contract": "explicit source target directory",
            "path_remapping": {
                "build_home": "/__skybridge__/build-home",
                "cargo_home": "/__skybridge__/cargo-home",
                "rust_sysroot": "/__skybridge__/rust-sysroot",
                "implementation_root": "/__skybridge__/boundsession-source",
            },
            "fake_provider_enabled": False,
            "library_kind": "dynamic-framework",
            "framework_layouts": {"macos": "versioned-A", "ios": "flat"},
            "install_name": "@rpath/BoundSessionFFI.framework/BoundSessionFFI",
        },
        "framework_binaries_after_adhoc_signing": binary_hashes,
        "signing_contract": {
            "source_frameworks": "ad-hoc integration integrity only",
            "shipping_bundle": (
                "must be re-signed with the final Apple application identity and pass "
                "codesign --verify --deep --strict"
            ),
        },
        "classification": (
            "source-bound integration snapshot; not a signed or published release artifact"
        ),
    }
    output.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
