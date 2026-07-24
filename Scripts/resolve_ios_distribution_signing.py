#!/usr/bin/env python3
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

(
    output_arg,
    explicit_app_arg,
    explicit_widget_arg,
    expected_team,
    app_bundle_identifier,
    widget_bundle_identifier,
    device_identifier,
) = sys.argv[1:]
output_path = Path(output_arg)
profile_roots = tuple(
    path.resolve()
    for path in (
        Path.home() / "Library/MobileDevice/Provisioning Profiles",
        Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
    )
    if path.is_dir()
)


def load_profile(path: Path) -> dict:
    payload = path.read_bytes()
    try:
        value = plistlib.loads(payload)
    except Exception:
        value = None
    if isinstance(value, dict):
        return value
    for command in (
        ["/usr/bin/security", "cms", "-D", "-i", str(path)],
        ["/usr/bin/openssl", "smime", "-inform", "DER", "-verify", "-noverify", "-in", str(path)],
    ):
        completed = subprocess.run(command, check=False, capture_output=True)
        if completed.returncode == 0 and completed.stdout:
            decoded = plistlib.loads(completed.stdout)
            if isinstance(decoded, dict):
                return decoded
    raise ValueError("profile could not be decoded")


def scalar_identifier(value) -> str:
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list) and len(value) == 1 and isinstance(value[0], str):
        return value[0].strip()
    return ""


def profile_value_covers(profile_value: str, requested: str) -> bool:
    if profile_value in {requested, "*"}:
        return True
    return profile_value.endswith(".*") and requested.startswith(profile_value[:-1])


def distribution_certificate_hashes(profile: dict) -> set[str]:
    hashes: set[str] = set()
    for certificate in profile.get("DeveloperCertificates") or []:
        if not isinstance(certificate, (bytes, bytearray)):
            continue
        der = bytes(certificate)
        subject = subprocess.run(
            ["/usr/bin/openssl", "x509", "-inform", "DER", "-noout", "-subject"],
            input=der,
            check=False,
            capture_output=True,
            text=False,
        )
        not_expired = subprocess.run(
            ["/usr/bin/openssl", "x509", "-inform", "DER", "-checkend", "0", "-noout"],
            input=der,
            check=False,
            capture_output=True,
            text=False,
        )
        subject_text = subject.stdout.decode("utf-8", errors="replace")
        if (
            subject.returncode == 0
            and not_expired.returncode == 0
            and re.search(r"\b(?:Apple Distribution|iPhone Distribution):", subject_text)
        ):
            hashes.add(hashlib.sha1(der).hexdigest().upper())
    return hashes


def validate_profile(path: Path, bundle_identifier: str, *, is_app: bool) -> dict | None:
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or path.is_symlink() or metadata.st_size <= 0:
            return None
        if metadata.st_size > 2 * 1024 * 1024:
            return None
        profile = load_profile(path)
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None

    entitlements = profile.get("Entitlements") or {}
    team = scalar_identifier(profile.get("TeamIdentifier"))
    application_prefix = scalar_identifier(profile.get("ApplicationIdentifierPrefix")) or team
    application_identifier = (
        entitlements.get("application-identifier")
        or entitlements.get("com.apple.application-identifier")
    )
    expires = profile.get("ExpirationDate")
    now = (
        dt.datetime.now(tz=expires.tzinfo)
        if isinstance(expires, dt.datetime) and expires.tzinfo
        else dt.datetime.now()
    )
    provisioned_devices = {
        str(value).strip()
        for value in profile.get("ProvisionedDevices", [])
        if isinstance(value, str) and value.strip()
    }
    profile_keychain_groups = {
        str(value).strip()
        for value in entitlements.get("keychain-access-groups", [])
        if isinstance(value, str) and value.strip()
    }
    required_keychain_groups = {
        f"{team}.{bundle_identifier}",
    }
    if is_app:
        required_keychain_groups.add(f"{team}.group.com.skybridge.compass")
    profile_covers_keychain = all(
        any(
            profile_value_covers(profile_value, requested)
            for profile_value in profile_keychain_groups
        )
        for requested in required_keychain_groups
    )
    certificate_hashes = distribution_certificate_hashes(profile)
    specifier = str(profile.get("Name") or "").strip()
    safe_specifier = (
        0 < len(specifier) <= 256
        and not any(ord(character) < 32 or ord(character) == 127 for character in specifier)
    )
    valid = all(
        (
            "iOS" in (profile.get("Platform") or []),
            profile.get("ProvisionsAllDevices") is not True,
            team == expected_team,
            application_prefix == expected_team,
            entitlements.get("com.apple.developer.team-identifier") == expected_team,
            application_identifier == f"{expected_team}.{bundle_identifier}",
            entitlements.get("get-task-allow") is False,
            isinstance(expires, dt.datetime) and expires > now,
            device_identifier in provisioned_devices,
            profile_covers_keychain,
            bool(certificate_hashes),
            safe_specifier,
        )
    )
    if is_app:
        valid = valid and entitlements.get("aps-environment") == "production"
    elif "aps-environment" in entitlements:
        valid = valid and entitlements.get("aps-environment") == "production"
    if not valid:
        return None
    return {
        "path": str(path),
        "specifier": specifier,
        "certificateHashes": certificate_hashes,
    }


def installed_candidates(explicit: str) -> list[Path]:
    if explicit:
        requested = Path(explicit).expanduser()
        if not requested.is_absolute():
            raise SystemExit("Explicit iOS distribution profile paths must be absolute installed-profile paths")
        try:
            resolved = requested.resolve(strict=True)
        except OSError:
            raise SystemExit("An explicit iOS distribution profile path is not installed")
        if not any(resolved == root or root in resolved.parents for root in profile_roots):
            raise SystemExit("Explicit iOS distribution profiles must already be installed in an Xcode profile directory")
        return [resolved]

    candidates: list[Path] = []
    seen: set[Path] = set()
    for root in profile_roots:
        for candidate in root.iterdir():
            try:
                resolved = candidate.resolve(strict=True)
            except OSError:
                continue
            if resolved not in seen:
                seen.add(resolved)
                candidates.append(resolved)
    return candidates


def select_profile(explicit: str, bundle_identifier: str, *, is_app: bool, label: str) -> dict:
    matches = [
        validated
        for path in installed_candidates(explicit)
        if (validated := validate_profile(path, bundle_identifier, is_app=is_app)) is not None
    ]
    if len(matches) != 1:
        raise SystemExit(
            f"Formal physical iOS acceptance requires exactly one installed matching {label} "
            f"distribution profile (found {len(matches)})"
        )
    return matches[0]


app_profile = select_profile(
    explicit_app_arg,
    app_bundle_identifier,
    is_app=True,
    label="iOS app",
)
widget_profile = select_profile(
    explicit_widget_arg,
    widget_bundle_identifier,
    is_app=False,
    label="iOS Widget",
)

identities = subprocess.run(
    ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
    check=False,
    capture_output=True,
    text=True,
)
if identities.returncode != 0:
    raise SystemExit("Unable to enumerate local code-signing identities for iOS distribution proof")
local_identity_hashes = set(re.findall(r"\b[0-9A-Fa-f]{40}\b", identities.stdout.upper()))
matching_identity_hashes = (
    app_profile["certificateHashes"]
    & widget_profile["certificateHashes"]
    & local_identity_hashes
)
if len(matching_identity_hashes) != 1:
    raise SystemExit(
        "Formal physical iOS acceptance requires one unambiguous local Apple Distribution identity "
        "shared by the app and Widget profiles"
    )

proof = {
    "schemaVersion": 1,
    "appProfilePath": app_profile["path"],
    "appProfileSpecifier": app_profile["specifier"],
    "widgetProfilePath": widget_profile["path"],
    "widgetProfileSpecifier": widget_profile["specifier"],
    "identityHash": next(iter(matching_identity_hashes)),
}
output_path.parent.mkdir(parents=True, exist_ok=True)
descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output_path.name}.", dir=output_path.parent)
temporary_path = Path(temporary_name)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", closefd=True) as handle:
        json.dump(proof, handle, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary_path, output_path)
finally:
    if temporary_path.exists():
        temporary_path.unlink()
