#!/usr/bin/env python3
"""Validate two exact Android native-PQC instrumentation runs and emit public evidence.

The APK digests and source revision are Level-1 reliability bindings: they
detect accidental cross-build or cross-run mismatch. They are not signatures
and do not defend against a malicious host account.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import NoReturn


MAXIMUM_INSTRUMENTATION_BYTES = 2 * 1024 * 1024
SOURCE_COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}\Z", re.ASCII)
APK_DIGEST_PATTERN = re.compile(r"[0-9a-f]{64}\Z", re.ASCII)
MARKER_PREFIX = "SB-PQC-NATIVE-RUNTIME"
EXPECTED_PROVIDER = "liboqs-android"
EXPECTED_TEST_CLASS = (
    "com.skybridge.compass.android.crypto."
    "NativePqcRuntimeInstrumentationTest"
)
EXPECTED_APP_PACKAGE = "com.skybridge.compass.debug"
EXPECTED_TEST_PACKAGE = "com.skybridge.compass.debug.nativepqc.test"
EXPECTED_RUNNER = "com.skybridge.compass.android.HiltTestRunner"

MARKER_PATTERN = re.compile(
    rf"{MARKER_PREFIX} "
    r"schema=1 "
    r"profile=(?P<profile>samsung-api36-4k|api37-16k) "
    rf"provider=(?P<provider>{re.escape(EXPECTED_PROVIDER)}) "
    r"api=(?P<api>36|37) "
    r"abi=(?P<abi>arm64-v8a|x86_64) "
    r"page_size=(?P<page_size>4096|16384) "
    r"native_load=true "
    r"mlkem_keygen=true "
    r"mlkem_encaps=true "
    r"mlkem_decaps=true "
    r"mlkem_secret_match=true "
    r"mldsa_keygen=true "
    r"mldsa_sign=true "
    r"mldsa_verify=true "
    r"mldsa_negative_message=true "
    r"mldsa_negative_signature=true "
    r"cleanup=true\Z",
    re.ASCII,
)

FAILURE_MARKERS = (
    "FAILURES!!!",
    "INSTRUMENTATION_FAILED",
    "Process crashed",
    "shortMsg=",
    "INSTRUMENTATION_ABORTED",
)


class NativePqcEvidenceError(RuntimeError):
    """The instrumentation output cannot prove the required runtime matrix."""


def _fail(message: str) -> NoReturn:
    raise NativePqcEvidenceError(message)


def _read_regular(path: Path, label: str) -> str:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        _fail(f"unable to open {label} without following links: {exc}")
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_size > MAXIMUM_INSTRUMENTATION_BYTES
        ):
            _fail(f"{label} must be a bounded single-link regular file")
        content = bytearray()
        while len(content) < before.st_size:
            chunk = os.read(descriptor, before.st_size - len(content))
            if not chunk:
                _fail(f"{label} was truncated while reading")
            content.extend(chunk)
        if os.read(descriptor, 1):
            _fail(f"{label} grew while reading")
        after = os.fstat(descriptor)
        stable_fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns")
        if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
            _fail(f"{label} changed while reading")
    finally:
        os.close(descriptor)
    try:
        return bytes(content).decode("utf-8")
    except UnicodeDecodeError as exc:
        _fail(f"{label} is not UTF-8: {exc}")


@dataclass(frozen=True)
class RuntimeResult:
    abi: str
    apiLevel: int
    cleanupComplete: bool
    mlDsaNegativeMessageVerified: bool
    mlDsaNegativeSignatureVerified: bool
    mlDsaSignVerified: bool
    mlKemSecretEqualityVerified: bool
    nativeLoadVerified: bool
    pageSizeBytes: int
    profile: str
    provider: str


def parse_instrumentation_output(path: Path, expected_profile: str, expected_abi: str) -> RuntimeResult:
    text = _read_regular(path, f"{expected_profile} instrumentation output")
    if any(marker in text for marker in FAILURE_MARKERS):
        _fail(f"{expected_profile} instrumentation reported failure")
    success_lines = re.findall(r"(?m)^OK \(1 test\)\s*$", text)
    if len(success_lines) != 1:
        _fail(f"{expected_profile} instrumentation did not finish exactly one successful test")
    terminal_lines = [
        line.strip()
        for line in text.splitlines()
        if line.strip().startswith("INSTRUMENTATION_CODE:")
    ]
    if terminal_lines != ["INSTRUMENTATION_CODE: -1"]:
        _fail(f"{expected_profile} instrumentation did not report one successful terminal code")

    marker_lines = [line.strip() for line in text.splitlines() if MARKER_PREFIX in line]
    if len(marker_lines) != 1:
        _fail(f"{expected_profile} instrumentation must contain exactly one result marker")
    marker = marker_lines[0]
    marker_offset = marker.find(MARKER_PREFIX)
    marker = marker[marker_offset:]
    match = MARKER_PATTERN.fullmatch(marker)
    if match is None:
        _fail(f"{expected_profile} instrumentation result marker is not canonical")

    profile = match.group("profile")
    api_level = int(match.group("api"))
    page_size = int(match.group("page_size"))
    abi = match.group("abi")
    expected_runtime = {
        "samsung-api36-4k": (36, 4_096, "arm64-v8a"),
        "api37-16k": (37, 16_384, expected_abi),
    }.get(expected_profile)
    if expected_runtime is None:
        _fail("unsupported expected runtime profile")
    if profile != expected_profile or (api_level, page_size, abi) != expected_runtime:
        _fail(f"{expected_profile} instrumentation runtime identity mismatch")

    return RuntimeResult(
        abi=abi,
        apiLevel=api_level,
        cleanupComplete=True,
        mlDsaNegativeMessageVerified=True,
        mlDsaNegativeSignatureVerified=True,
        mlDsaSignVerified=True,
        mlKemSecretEqualityVerified=True,
        nativeLoadVerified=True,
        pageSizeBytes=page_size,
        profile=profile,
        provider=match.group("provider"),
    )


def build_evidence(
    *,
    source_commit: str,
    app_apk_sha256: str,
    app_apk_bytes: int,
    test_apk_sha256: str,
    test_apk_bytes: int,
    samsung_output: Path,
    api37_output: Path,
    api37_abi: str,
) -> dict[str, object]:
    if SOURCE_COMMIT_PATTERN.fullmatch(source_commit) is None:
        _fail("source commit must be a full lowercase Git revision")
    for label, digest in (
        ("app APK", app_apk_sha256),
        ("test APK", test_apk_sha256),
    ):
        if APK_DIGEST_PATTERN.fullmatch(digest) is None:
            _fail(f"{label} digest must be lowercase SHA-256 text")
    if type(app_apk_bytes) is not int or app_apk_bytes <= 0:
        _fail("app APK byte count must be positive")
    if type(test_apk_bytes) is not int or test_apk_bytes <= 0:
        _fail("test APK byte count must be positive")
    if api37_abi not in {"arm64-v8a", "x86_64"}:
        _fail("API 37 / 16K expected ABI is unsupported")

    samsung = parse_instrumentation_output(
        samsung_output,
        expected_profile="samsung-api36-4k",
        expected_abi="arm64-v8a",
    )
    api37 = parse_instrumentation_output(
        api37_output,
        expected_profile="api37-16k",
        expected_abi=api37_abi,
    )
    return {
        "appPackage": EXPECTED_APP_PACKAGE,
        "artifactBindingPurpose": "detect-accidental-apk-or-source-mismatch",
        "matrixComplete": True,
        "provider": EXPECTED_PROVIDER,
        "runs": [asdict(samsung), asdict(api37)],
        "schemaVersion": 1,
        "sourceCommit": source_commit,
        "testApk": {
            "bytes": test_apk_bytes,
            "sha256": test_apk_sha256,
        },
        "testClass": EXPECTED_TEST_CLASS,
        "testPackage": EXPECTED_TEST_PACKAGE,
        "testRunner": EXPECTED_RUNNER,
        "targetApk": {
            "bytes": app_apk_bytes,
            "sha256": app_apk_sha256,
        },
    }


def _atomic_new(path: Path, payload: dict[str, object]) -> None:
    if not path.is_absolute() or path.exists() or path.is_symlink():
        _fail("evidence output must be a new absolute path")
    parent = path.parent.resolve(strict=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", closefd=True) as handle:
            descriptor = -1
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary, path, follow_symlinks=False)
        except FileExistsError:
            _fail("evidence output appeared while publishing")
        directory_descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--app-apk-sha256", required=True)
    parser.add_argument("--app-apk-bytes", type=int, required=True)
    parser.add_argument("--test-apk-sha256", required=True)
    parser.add_argument("--test-apk-bytes", type=int, required=True)
    parser.add_argument("--samsung-output", type=Path, required=True)
    parser.add_argument("--api37-output", type=Path, required=True)
    parser.add_argument("--api37-abi", choices=("arm64-v8a", "x86_64"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        payload = build_evidence(
            source_commit=arguments.source_commit,
            app_apk_sha256=arguments.app_apk_sha256,
            app_apk_bytes=arguments.app_apk_bytes,
            test_apk_sha256=arguments.test_apk_sha256,
            test_apk_bytes=arguments.test_apk_bytes,
            samsung_output=arguments.samsung_output,
            api37_output=arguments.api37_output,
            api37_abi=arguments.api37_abi,
        )
        _atomic_new(arguments.output, payload)
    except (NativePqcEvidenceError, OSError) as exc:
        print(f"Android native PQC runtime evidence rejected: {exc}", file=os.sys.stderr)
        return 1
    print(f"Android native PQC runtime evidence valid: {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
