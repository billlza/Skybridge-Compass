#!/usr/bin/env python3
"""Create and verify the immutable identity of one macOS release candidate.

SHA-256 values in this document are reliability bindings used to detect an
accidental candidate/evidence mismatch.  Platform code signing, notarization,
and Gatekeeper remain the security boundaries.
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
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any


SCHEMA_VERSION = 1
MAX_MANIFEST_BYTES = 256 * 1024
HEX_40 = re.compile(r"[0-9a-f]{40}", re.ASCII)
HEX_64 = re.compile(r"[0-9a-f]{64}", re.ASCII)
SEMVER = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+", re.ASCII)
POSITIVE_INTEGER = re.compile(r"[1-9][0-9]*", re.ASCII)
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", re.ASCII)
BUNDLE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]+", re.ASCII)
TEAM_ID = re.compile(r"[A-Z0-9]{10}", re.ASCII)


class CandidateIdentityError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise CandidateIdentityError(message)


def run_checked(command: list[str], label: str) -> str:
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
        )
    except (OSError, UnicodeError) as exc:
        fail(f"unable to run {label}: {exc}")
    output = (completed.stdout + completed.stderr).strip()
    if completed.returncode != 0:
        fail(f"{label} failed: {output or 'no diagnostic output'}")
    return output


def require_regular_file(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
    except OSError as exc:
        fail(f"unable to inspect {label}: {exc}")
    if path.is_symlink() or not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        fail(f"{label} must be a single-link regular file: {path}")
    return path.resolve(strict=True)


def require_app_bundle(path: Path) -> Path:
    try:
        metadata = path.lstat()
    except OSError as exc:
        fail(f"unable to inspect app bundle: {exc}")
    if path.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
        fail(f"app bundle must be a real directory: {path}")
    resolved = path.resolve(strict=True)
    if resolved.name != "SkyBridge Compass Pro.app":
        fail("candidate app bundle must use the canonical product name")
    return resolved


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    except OSError as exc:
        fail(f"unable to hash candidate file {path}: {exc}")
    return digest.hexdigest()


def digest_app_bundle(root: Path) -> str:
    """Hash paths, types, modes, link targets, and regular-file bytes."""

    digest = hashlib.sha256()
    entries: list[Path] = []
    try:
        for directory, directory_names, file_names in os.walk(root, followlinks=False):
            directory_names.sort()
            file_names.sort()
            base = Path(directory)
            entries.extend(base / name for name in directory_names)
            entries.extend(base / name for name in file_names)
    except OSError as exc:
        fail(f"unable to enumerate candidate app bundle: {exc}")

    for entry in sorted(entries, key=lambda item: item.relative_to(root).as_posix()):
        relative = entry.relative_to(root).as_posix()
        if PurePosixPath(relative).is_absolute() or ".." in PurePosixPath(relative).parts:
            fail(f"invalid candidate app path: {relative}")
        try:
            metadata = entry.lstat()
        except OSError as exc:
            fail(f"unable to inspect candidate app entry {relative}: {exc}")
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISDIR(metadata.st_mode):
            kind = b"d"
            body = b""
        elif stat.S_ISLNK(metadata.st_mode):
            kind = b"l"
            try:
                body = os.readlink(entry).encode("utf-8", errors="strict")
            except (OSError, UnicodeError) as exc:
                fail(f"unable to read candidate app symlink {relative}: {exc}")
            target = PurePosixPath(relative).parent / PurePosixPath(body.decode("utf-8"))
            normalized: list[str] = []
            for component in target.parts:
                if component in {"", "."}:
                    continue
                if component == "..":
                    if not normalized:
                        fail(f"candidate app symlink escapes the bundle: {relative}")
                    normalized.pop()
                else:
                    normalized.append(component)
        elif stat.S_ISREG(metadata.st_mode):
            if metadata.st_nlink != 1:
                fail(f"candidate app regular file has multiple hard links: {relative}")
            kind = b"f"
            try:
                body = entry.read_bytes()
            except OSError as exc:
                fail(f"unable to read candidate app entry {relative}: {exc}")
        else:
            fail(f"candidate app contains a special file: {relative}")
        header = f"{relative}\0{mode:o}\0".encode("utf-8") + kind + b"\0"
        digest.update(header)
        digest.update(len(body).to_bytes(8, "big"))
        digest.update(body)
    return digest.hexdigest()


def parse_codesign_details(output: str) -> tuple[str, str, str]:
    values: dict[str, str] = {}
    for line in output.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in {"Identifier", "TeamIdentifier", "CDHash"}:
            values[key] = value.strip()
    identifier = values.get("Identifier", "")
    team_id = values.get("TeamIdentifier", "")
    cd_hash = values.get("CDHash", "").lower()
    if BUNDLE_ID.fullmatch(identifier) is None:
        fail("codesign did not report a valid bundle identifier")
    if TEAM_ID.fullmatch(team_id) is None:
        fail("codesign did not report a valid TeamIdentifier")
    if re.fullmatch(r"[0-9a-f]{40,64}", cd_hash, re.ASCII) is None:
        fail("codesign did not report a valid CDHash")
    return identifier, team_id, cd_hash


def canonical_requirement(output: str) -> str:
    marker = "designated =>"
    index = output.find(marker)
    if index < 0:
        fail("codesign did not report a designated requirement")
    requirement = " ".join(output[index + len(marker) :].split())
    if not requirement or len(requirement) > 8192:
        fail("codesign reported an invalid designated requirement")
    return requirement


def load_info_plist(app: Path) -> dict[str, Any]:
    path = require_regular_file(app / "Contents/Info.plist", "candidate app Info.plist")
    try:
        with path.open("rb") as handle:
            payload = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        fail(f"unable to read candidate app Info.plist: {exc}")
    if not isinstance(payload, dict):
        fail("candidate app Info.plist must contain a dictionary")
    return payload


def inspect_candidate(
    app_path: Path,
    dmg_path: Path,
    source_repository: str,
    source_commit: str,
    expected_version: str,
    expected_build: str,
) -> dict[str, Any]:
    if REPOSITORY.fullmatch(source_repository) is None:
        fail("source repository must use owner/name syntax")
    if HEX_40.fullmatch(source_commit) is None:
        fail("source commit must be a full lowercase 40-character Git commit")
    if SEMVER.fullmatch(expected_version) is None:
        fail("expected version must be strict three-component SemVer")
    if POSITIVE_INTEGER.fullmatch(expected_build) is None:
        fail("expected build must be a positive integer")

    app = require_app_bundle(app_path)
    dmg = require_regular_file(dmg_path, "candidate DMG")
    info = load_info_plist(app)
    bundle_id = info.get("CFBundleIdentifier")
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    if not all(isinstance(item, str) for item in (bundle_id, version, build)):
        fail("candidate app version and identity values must be strings")
    if bundle_id != "com.skybridge.compass.pro":
        fail("candidate app bundle identifier does not match the release product")
    if version != expected_version or build != expected_build:
        fail("candidate app version/build does not match the requested transaction")
    expected_dmg_name = f"SkyBridgeCompassPro-{version}.dmg"
    if dmg.name != expected_dmg_name:
        fail(f"candidate DMG must be named {expected_dmg_name}")

    run_checked(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", os.fspath(app)], "candidate codesign verification")
    identifier, team_id, cd_hash = parse_codesign_details(
        run_checked(["/usr/bin/codesign", "-d", "--verbose=4", os.fspath(app)], "candidate codesign inspection")
    )
    if identifier != bundle_id:
        fail("codesign identifier does not match Info.plist bundle identifier")
    requirement = canonical_requirement(
        run_checked(["/usr/bin/codesign", "-d", "-r-", os.fspath(app)], "candidate designated requirement inspection")
    )
    run_checked(["/usr/bin/xcrun", "stapler", "validate", os.fspath(app)], "candidate app staple validation")
    run_checked(["/usr/bin/xcrun", "stapler", "validate", os.fspath(dmg)], "candidate DMG staple validation")
    run_checked(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", os.fspath(app)], "candidate app Gatekeeper assessment")
    run_checked(
        [
            "/usr/sbin/spctl",
            "--assess",
            "--type",
            "open",
            "--context",
            "context:primary-signature",
            "--verbose=4",
            os.fspath(dmg),
        ],
        "candidate DMG Gatekeeper assessment",
    )

    return {
        "schemaVersion": SCHEMA_VERSION,
        "source": {"repository": source_repository, "commit": source_commit},
        "product": {
            "bundleIdentifier": bundle_id,
            "version": version,
            "build": build,
            "teamIdentifier": team_id,
            "cdHash": cd_hash,
            "designatedRequirement": requirement,
        },
        "platformValidation": {
            "codeSignatureValid": True,
            "notarizationAccepted": True,
            "appStaplerValid": True,
            "dmgStaplerValid": True,
            "appGatekeeperAccepted": True,
            "dmgGatekeeperAccepted": True,
        },
        "artifactBinding": {
            "algorithm": "sha256",
            "purpose": "detect accidental candidate/evidence mismatch",
            "appBundleDigest": digest_app_bundle(app),
            "dmgDigest": digest_file(dmg),
            "dmgFileName": dmg.name,
        },
    }


def validate_manifest(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict) or set(payload) != {
        "schemaVersion",
        "source",
        "product",
        "platformValidation",
        "artifactBinding",
    }:
        fail("candidate identity has an invalid top-level shape")
    if payload.get("schemaVersion") != SCHEMA_VERSION:
        fail("candidate identity has an unsupported schemaVersion")
    source = payload.get("source")
    product = payload.get("product")
    validation = payload.get("platformValidation")
    binding = payload.get("artifactBinding")
    if not isinstance(source, dict) or set(source) != {"repository", "commit"}:
        fail("candidate identity source section is invalid")
    if REPOSITORY.fullmatch(source.get("repository", "")) is None or HEX_40.fullmatch(source.get("commit", "")) is None:
        fail("candidate identity source values are invalid")
    required_product = {
        "bundleIdentifier",
        "version",
        "build",
        "teamIdentifier",
        "cdHash",
        "designatedRequirement",
    }
    if not isinstance(product, dict) or set(product) != required_product:
        fail("candidate identity product section is invalid")
    if product.get("bundleIdentifier") != "com.skybridge.compass.pro":
        fail("candidate identity bundle identifier is invalid")
    if SEMVER.fullmatch(product.get("version", "")) is None or POSITIVE_INTEGER.fullmatch(product.get("build", "")) is None:
        fail("candidate identity version/build is invalid")
    if TEAM_ID.fullmatch(product.get("teamIdentifier", "")) is None:
        fail("candidate identity TeamIdentifier is invalid")
    if re.fullmatch(r"[0-9a-f]{40,64}", product.get("cdHash", ""), re.ASCII) is None:
        fail("candidate identity CDHash is invalid")
    requirement = product.get("designatedRequirement")
    if not isinstance(requirement, str) or not requirement or len(requirement) > 8192:
        fail("candidate identity designated requirement is invalid")
    required_validation = {
        "codeSignatureValid",
        "notarizationAccepted",
        "appStaplerValid",
        "dmgStaplerValid",
        "appGatekeeperAccepted",
        "dmgGatekeeperAccepted",
    }
    if not isinstance(validation, dict) or set(validation) != required_validation:
        fail("candidate identity platform validation section is invalid")
    if any(validation.get(key) is not True for key in required_validation):
        fail("candidate identity platform validation must be fully accepted")
    required_binding = {
        "algorithm",
        "purpose",
        "appBundleDigest",
        "dmgDigest",
        "dmgFileName",
    }
    if not isinstance(binding, dict) or set(binding) != required_binding:
        fail("candidate identity artifact binding section is invalid")
    if binding.get("algorithm") != "sha256" or binding.get("purpose") != "detect accidental candidate/evidence mismatch":
        fail("candidate identity artifact binding purpose is invalid")
    if HEX_64.fullmatch(binding.get("appBundleDigest", "")) is None or HEX_64.fullmatch(binding.get("dmgDigest", "")) is None:
        fail("candidate identity artifact digest is invalid")
    if binding.get("dmgFileName") != f"SkyBridgeCompassPro-{product['version']}.dmg":
        fail("candidate identity DMG file name is invalid")
    return payload


def load_manifest(path: Path) -> dict[str, Any]:
    manifest = require_regular_file(path, "candidate identity manifest")
    try:
        if manifest.stat().st_size > MAX_MANIFEST_BYTES:
            fail("candidate identity manifest exceeds the size limit")
        payload = json.loads(manifest.read_text(encoding="utf-8", errors="strict"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"unable to read candidate identity manifest: {exc}")
    return validate_manifest(payload)


def canonical_bytes(payload: dict[str, Any]) -> bytes:
    return (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")


def write_atomic(path: Path, content: bytes) -> None:
    parent = path.parent.resolve(strict=True)
    output = parent / path.name
    if output.exists() or output.is_symlink():
        fail(f"candidate identity output must not already exist: {output}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()


def compare(expected_path: Path, actual_path: Path) -> None:
    expected = load_manifest(expected_path)
    actual = load_manifest(actual_path)
    if expected != actual:
        fail("candidate identity manifests do not describe the exact same candidate")
    if canonical_bytes(expected) != require_regular_file(expected_path, "expected candidate identity").read_bytes():
        fail("expected candidate identity manifest is not canonical JSON")
    if canonical_bytes(actual) != require_regular_file(actual_path, "actual candidate identity").read_bytes():
        fail("actual candidate identity manifest is not canonical JSON")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("--app", required=True, type=Path)
    create_parser.add_argument("--dmg", required=True, type=Path)
    create_parser.add_argument("--source-repository", required=True)
    create_parser.add_argument("--source-commit", required=True)
    create_parser.add_argument("--expected-version", required=True)
    create_parser.add_argument("--expected-build", required=True)
    create_parser.add_argument("--output", required=True, type=Path)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--identity", required=True, type=Path)
    verify_parser.add_argument("--app", required=True, type=Path)
    verify_parser.add_argument("--dmg", required=True, type=Path)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--identity", required=True, type=Path)

    compare_parser = subparsers.add_parser("compare")
    compare_parser.add_argument("--expected", required=True, type=Path)
    compare_parser.add_argument("--actual", required=True, type=Path)

    args = parser.parse_args()
    try:
        if args.command == "create":
            payload = inspect_candidate(
                args.app,
                args.dmg,
                args.source_repository,
                args.source_commit,
                args.expected_version,
                args.expected_build,
            )
            write_atomic(args.output, canonical_bytes(payload))
        elif args.command == "verify":
            expected = load_manifest(args.identity)
            source = expected["source"]
            product = expected["product"]
            observed = inspect_candidate(
                args.app,
                args.dmg,
                source["repository"],
                source["commit"],
                product["version"],
                product["build"],
            )
            if observed != expected:
                fail("candidate products do not match the immutable candidate identity")
        elif args.command == "validate":
            payload = load_manifest(args.identity)
            if canonical_bytes(payload) != require_regular_file(args.identity, "candidate identity").read_bytes():
                fail("candidate identity manifest is not canonical JSON")
        else:
            compare(args.expected, args.actual)
    except CandidateIdentityError as exc:
        print(f"macOS release candidate identity rejected: {exc}", file=sys.stderr)
        return 1
    print(f"macOS release candidate identity valid: command={args.command}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
