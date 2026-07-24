#!/usr/bin/env python3
"""Strict process-ownership records for the real-device WebRTC smoke.

Exit status for the ``*-status`` commands is part of the shell contract:

* 0: the exact launched process is still running;
* 1: the recorded process identifier is no longer present;
* 2: ownership is malformed, mismatched, or cannot be proven.

Status 2 must never be treated as absence.  In particular, an iOS process-list
entry without the launch audit token is deliberately unverifiable even when its
PID and executable happen to match.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import json
import os
import pathlib
import plistlib
import re
import signal
import stat
import sys
import tempfile
import urllib.parse
from dataclasses import dataclass
from typing import NoReturn, Optional


MATCH = 0
ABSENT = 1
UNVERIFIABLE = 2
IDENTITY_SCHEMA_VERSION = 1
MAX_IDENTITY_BYTES = 16 * 1024
MAXCOMLEN = 16
PROC_PIDTBSDINFO = 3
PROC_PIDPATHINFO_MAXSIZE = 4 * 1024
TASK_AUDIT_TOKEN = 15


class OwnershipError(Exception):
    """The target exists or may exist, but exact ownership is not proven."""


class ProcessAbsent(Exception):
    """The recorded process identifier is no longer present."""


class ProcBSDInfo(ctypes.Structure):
    """Public ``struct proc_bsdinfo`` from ``<sys/proc_info.h>``."""

    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * MAXCOMLEN),
        ("pbi_name", ctypes.c_char * (2 * MAXCOMLEN)),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


class AuditToken(ctypes.Structure):
    """Public ``audit_token_t`` from ``<mach/message.h>``."""

    _fields_ = [("val", ctypes.c_uint32 * 8)]


@dataclass(frozen=True)
class MacProcessSnapshot:
    audit_token: tuple[int, ...]
    executable_path: str
    start_time_token: str


def _fail(message: str, status: int = UNVERIFIABLE) -> NoReturn:
    print(f"process-ownership error: {message}", file=sys.stderr)
    raise SystemExit(status)


def _strict_positive_pid(value: object, field: str = "processIdentifier") -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise OwnershipError(f"{field} must be a positive integer")
    return value


def _strict_audit_token(value: object) -> list[int]:
    if not isinstance(value, list) or len(value) != 8:
        raise OwnershipError("auditToken must contain exactly eight words")
    result: list[int] = []
    for word in value:
        if isinstance(word, bool) or not isinstance(word, int) or not 0 <= word <= 0xFFFFFFFF:
            raise OwnershipError("auditToken words must be unsigned 32-bit integers")
        result.append(word)
    return result


def _validate_private_parent(output_path: pathlib.Path) -> None:
    parent = output_path.parent
    try:
        metadata = parent.lstat()
    except OSError as error:
        raise OwnershipError(f"ownership directory is unavailable ({type(error).__name__})") from error
    if parent.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
        raise OwnershipError("ownership directory must be a real directory")
    if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise OwnershipError("ownership directory must be owned by the current user with mode 0700")


def _atomic_private_json(output_path: pathlib.Path, payload: dict[str, object]) -> None:
    if not output_path.is_absolute():
        raise OwnershipError("ownership record path must be absolute")
    _validate_private_parent(output_path)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output_path.name}.", dir=output_path.parent)
    temporary_path = pathlib.Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        serialized = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            descriptor = -1
            handle.write(serialized)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, output_path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def _read_private_json(path: pathlib.Path) -> dict[str, object]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise OwnershipError(f"ownership record is unavailable ({type(error).__name__})") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != 0o600
        ):
            raise OwnershipError("ownership record must be a private regular file with one link")
        if metadata.st_size <= 0 or metadata.st_size > MAX_IDENTITY_BYTES:
            raise OwnershipError("ownership record size is outside the permitted boundary")
        with os.fdopen(descriptor, "r", encoding="utf-8", closefd=True) as handle:
            descriptor = -1
            payload = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise OwnershipError(f"ownership record is malformed ({type(error).__name__})") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if not isinstance(payload, dict):
        raise OwnershipError("ownership record root must be an object")
    return payload


def _pid_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _load_libproc() -> ctypes.CDLL:
    try:
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        proc_pidinfo = library.proc_pidinfo
        proc_pidpath = library.proc_pidpath
        proc_signal_with_audittoken = library.proc_signal_with_audittoken
    except (AttributeError, OSError) as error:
        raise OwnershipError("macOS libproc is unavailable") from error
    proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    proc_pidinfo.restype = ctypes.c_int
    proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    proc_pidpath.restype = ctypes.c_int
    proc_signal_with_audittoken.argtypes = [ctypes.POINTER(AuditToken), ctypes.c_int]
    proc_signal_with_audittoken.restype = ctypes.c_int
    return library


def _read_mac_audit_token(pid: int) -> tuple[int, ...]:
    try:
        library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        current_task = ctypes.c_uint32.in_dll(library, "mach_task_self_").value
        task_name_for_pid = library.task_name_for_pid
        task_info = library.task_info
        mach_port_deallocate = library.mach_port_deallocate
    except (AttributeError, OSError, ValueError) as error:
        raise OwnershipError("macOS task audit-token API is unavailable") from error
    task_name_for_pid.argtypes = [
        ctypes.c_uint32,
        ctypes.c_int,
        ctypes.POINTER(ctypes.c_uint32),
    ]
    task_name_for_pid.restype = ctypes.c_int
    task_info.argtypes = [
        ctypes.c_uint32,
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint32),
    ]
    task_info.restype = ctypes.c_int
    mach_port_deallocate.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    mach_port_deallocate.restype = ctypes.c_int

    task_name = ctypes.c_uint32()
    result = task_name_for_pid(current_task, pid, ctypes.byref(task_name))
    if result != 0:
        if not _pid_exists(pid):
            raise ProcessAbsent
        raise OwnershipError(f"cannot acquire macOS process identity port (kern_return={result})")
    try:
        audit_token = AuditToken()
        count = ctypes.c_uint32(8)
        result = task_info(
            task_name.value,
            TASK_AUDIT_TOKEN,
            ctypes.byref(audit_token),
            ctypes.byref(count),
        )
        if result != 0 or count.value != 8:
            if not _pid_exists(pid):
                raise ProcessAbsent
            raise OwnershipError(f"cannot read macOS process audit token (kern_return={result})")
        words = tuple(int(word) for word in audit_token.val)
        if words[5] != pid:
            raise OwnershipError("macOS process audit token is not bound to its process identifier")
        return words
    finally:
        mach_port_deallocate(current_task, task_name.value)


def _read_mac_snapshot_once(pid: int) -> MacProcessSnapshot:
    library = _load_libproc()
    bsd_info = ProcBSDInfo()
    ctypes.set_errno(0)
    info_size = library.proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        ctypes.byref(bsd_info),
        ctypes.sizeof(bsd_info),
    )
    if info_size != ctypes.sizeof(bsd_info):
        saved_errno = ctypes.get_errno()
        if saved_errno == errno.ESRCH or not _pid_exists(pid):
            raise ProcessAbsent
        raise OwnershipError(f"cannot read macOS process start time (errno={saved_errno})")
    if bsd_info.pbi_pid != pid:
        raise OwnershipError("macOS process metadata returned a different PID")

    path_buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    ctypes.set_errno(0)
    path_size = library.proc_pidpath(pid, path_buffer, len(path_buffer))
    if path_size <= 0:
        saved_errno = ctypes.get_errno()
        if saved_errno == errno.ESRCH or not _pid_exists(pid):
            raise ProcessAbsent
        raise OwnershipError(f"cannot read macOS process executable path (errno={saved_errno})")
    try:
        executable_path = os.path.realpath(os.fsdecode(path_buffer.value))
    except UnicodeError as error:
        raise OwnershipError("macOS process executable path is not valid text") from error
    if not executable_path.startswith("/"):
        raise OwnershipError("macOS process executable path is not absolute")
    return MacProcessSnapshot(
        audit_token=_read_mac_audit_token(pid),
        executable_path=executable_path,
        start_time_token=f"{bsd_info.pbi_start_tvsec}:{bsd_info.pbi_start_tvusec}",
    )


def _read_stable_mac_snapshot(pid: int) -> MacProcessSnapshot:
    first = _read_mac_snapshot_once(pid)
    second = _read_mac_snapshot_once(pid)
    if first != second:
        raise OwnershipError("macOS process identity changed while it was being inspected")
    return first


def _parse_mac_identity(path: pathlib.Path) -> tuple[int, MacProcessSnapshot]:
    payload = _read_private_json(path)
    expected_keys = {
        "auditToken",
        "executablePath",
        "platform",
        "processIdentifier",
        "schemaVersion",
        "startTimeToken",
    }
    if set(payload) != expected_keys:
        raise OwnershipError("macOS ownership record fields are not canonical")
    schema_version = payload["schemaVersion"]
    if (
        isinstance(schema_version, bool)
        or not isinstance(schema_version, int)
        or schema_version != IDENTITY_SCHEMA_VERSION
        or payload["platform"] != "macos"
    ):
        raise OwnershipError("macOS ownership record schema is unsupported")
    pid = _strict_positive_pid(payload["processIdentifier"])
    executable_path = payload["executablePath"]
    start_time_token = payload["startTimeToken"]
    if not isinstance(executable_path, str) or not executable_path.startswith("/"):
        raise OwnershipError("macOS ownership executable path is invalid")
    token_match = (
        re.fullmatch(r"([1-9][0-9]*):([0-9]+)", start_time_token)
        if isinstance(start_time_token, str)
        else None
    )
    if token_match is None or int(token_match.group(2)) >= 1_000_000:
        raise OwnershipError("macOS ownership start-time token is invalid")
    audit_token = _strict_audit_token(payload["auditToken"])
    if audit_token[5] != pid:
        raise OwnershipError("macOS ownership audit token is not bound to its process identifier")
    return pid, MacProcessSnapshot(tuple(audit_token), executable_path, start_time_token)


def mac_capture(pid: int, expected_executable: pathlib.Path, output: pathlib.Path) -> None:
    if not expected_executable.is_absolute():
        raise OwnershipError("expected macOS executable path must be absolute")
    canonical_expected = os.path.realpath(expected_executable)
    if not os.path.isfile(canonical_expected) or not os.access(canonical_expected, os.X_OK):
        raise OwnershipError("expected macOS executable is not an executable file")
    snapshot = _read_stable_mac_snapshot(pid)
    if snapshot.executable_path != canonical_expected:
        raise OwnershipError("launched macOS PID does not execute the expected binary")
    _atomic_private_json(
        output,
        {
            "auditToken": list(snapshot.audit_token),
            "executablePath": canonical_expected,
            "platform": "macos",
            "processIdentifier": pid,
            "schemaVersion": IDENTITY_SCHEMA_VERSION,
            "startTimeToken": snapshot.start_time_token,
        },
    )


def mac_status(identity_path: pathlib.Path) -> int:
    try:
        pid, expected = _parse_mac_identity(identity_path)
        actual = _read_stable_mac_snapshot(pid)
    except ProcessAbsent:
        return ABSENT
    except OwnershipError as error:
        print(f"process-ownership error: {error}", file=sys.stderr)
        return UNVERIFIABLE
    if actual != expected:
        print("process-ownership error: macOS PID identity no longer matches the launch record", file=sys.stderr)
        return UNVERIFIABLE
    return MATCH


def mac_signal(identity_path: pathlib.Path, signal_number: int) -> int:
    """Validate ownership and signal the exact audit-token process instance."""

    try:
        pid, expected = _parse_mac_identity(identity_path)
        actual = _read_stable_mac_snapshot(pid)
    except ProcessAbsent:
        return ABSENT
    except OwnershipError as error:
        print(f"process-ownership error: {error}", file=sys.stderr)
        return UNVERIFIABLE
    if actual != expected:
        print("process-ownership error: refusing to signal a macOS PID with mismatched identity", file=sys.stderr)
        return UNVERIFIABLE
    audit_token = AuditToken()
    audit_token.val[:] = expected.audit_token
    try:
        library = _load_libproc()
        ctypes.set_errno(0)
        result = library.proc_signal_with_audittoken(ctypes.byref(audit_token), signal_number)
    except OwnershipError as error:
        print(f"process-ownership error: {error}", file=sys.stderr)
        return UNVERIFIABLE
    if result != 0:
        saved_errno = ctypes.get_errno()
        status = mac_status(identity_path)
        if status == ABSENT:
            return ABSENT
        print(
            f"process-ownership error: audit-token macOS signal failed (errno={saved_errno})",
            file=sys.stderr,
        )
        return UNVERIFIABLE
    return MATCH


def _normalized_file_url_path(value: object, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise OwnershipError(f"{field} must be a non-empty file URL")
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme != "file" or parsed.netloc or parsed.query or parsed.fragment:
        raise OwnershipError(f"{field} must be a local file URL without query or fragment")
    try:
        decoded = urllib.parse.unquote(parsed.path, errors="strict")
    except UnicodeError as error:
        raise OwnershipError(f"{field} contains invalid URL encoding") from error
    if not decoded.startswith("/") or "\x00" in decoded:
        raise OwnershipError(f"{field} path must be absolute")
    if any(component in {".", ".."} for component in decoded.split("/")):
        raise OwnershipError(f"{field} path must not contain traversal components")
    normalized = str(pathlib.PurePosixPath(decoded))
    if normalized != decoded:
        raise OwnershipError(f"{field} path is not canonical")
    return normalized


def _parse_ios_identity(
    path: pathlib.Path,
) -> tuple[int, str, str, str, list[int]]:
    payload = _read_private_json(path)
    expected_keys = {
        "auditToken",
        "bundleName",
        "executableName",
        "executablePath",
        "platform",
        "processIdentifier",
        "schemaVersion",
    }
    if set(payload) != expected_keys:
        raise OwnershipError("iOS ownership record fields are not canonical")
    schema_version = payload["schemaVersion"]
    if (
        isinstance(schema_version, bool)
        or not isinstance(schema_version, int)
        or schema_version != IDENTITY_SCHEMA_VERSION
        or payload["platform"] != "ios"
    ):
        raise OwnershipError("iOS ownership record schema is unsupported")
    pid = _strict_positive_pid(payload["processIdentifier"])
    bundle_name = payload["bundleName"]
    executable_name = payload["executableName"]
    executable_path = payload["executablePath"]
    if not isinstance(bundle_name, str) or not bundle_name.endswith(".app") or "/" in bundle_name:
        raise OwnershipError("iOS ownership bundle name is invalid")
    if not isinstance(executable_name, str) or not executable_name or "/" in executable_name:
        raise OwnershipError("iOS ownership executable name is invalid")
    if not isinstance(executable_path, str) or not executable_path.startswith("/"):
        raise OwnershipError("iOS ownership executable path is invalid")
    executable = pathlib.PurePosixPath(executable_path)
    if executable.name != executable_name or executable.parent.name != bundle_name:
        raise OwnershipError("iOS ownership executable does not match its expected app bundle")
    audit_token = _strict_audit_token(payload["auditToken"])
    if audit_token[5] != pid:
        raise OwnershipError("iOS ownership audit token is not bound to its process identifier")
    return pid, bundle_name, executable_name, executable_path, audit_token


def ios_capture(launch_json: pathlib.Path, app_path: pathlib.Path, output: pathlib.Path) -> None:
    if not app_path.is_absolute() or not app_path.is_dir() or app_path.is_symlink():
        raise OwnershipError("expected iOS app must be an absolute, real app directory")
    info_plist = app_path / "Info.plist"
    try:
        with info_plist.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise OwnershipError("expected iOS app Info.plist is unavailable or malformed") from error
    executable_name = info.get("CFBundleExecutable") if isinstance(info, dict) else None
    if not isinstance(executable_name, str) or not executable_name or "/" in executable_name:
        raise OwnershipError("expected iOS app CFBundleExecutable is invalid")
    expected_local_executable = app_path / executable_name
    if not expected_local_executable.is_file() or not os.access(expected_local_executable, os.X_OK):
        raise OwnershipError("expected iOS bundle executable is missing or not executable")

    try:
        payload = _read_private_json(launch_json)
        process = payload["result"]["process"]
    except OwnershipError:
        raise
    except (KeyError, TypeError) as error:
        raise OwnershipError("devicectl launch result is unavailable or malformed") from error
    if not isinstance(process, dict):
        raise OwnershipError("devicectl launch process must be an object")
    pid = _strict_positive_pid(process.get("processIdentifier"))
    audit_token = _strict_audit_token(process.get("auditToken"))
    if audit_token[5] != pid:
        raise OwnershipError("launch audit token is not bound to its process identifier")
    executable_path = _normalized_file_url_path(process.get("executable"), "launch executable")
    executable = pathlib.PurePosixPath(executable_path)
    if executable.name != executable_name or executable.parent.name != app_path.name:
        raise OwnershipError("launched iOS process does not match the expected bundle executable")

    _atomic_private_json(
        output,
        {
            "auditToken": audit_token,
            "bundleName": app_path.name,
            "executableName": executable_name,
            "executablePath": executable_path,
            "platform": "ios",
            "processIdentifier": pid,
            "schemaVersion": IDENTITY_SCHEMA_VERSION,
        },
    )


def ios_status(processes_json: pathlib.Path, identity_path: pathlib.Path) -> int:
    try:
        pid, bundle_name, executable_name, executable_path, audit_token = _parse_ios_identity(identity_path)
        with processes_json.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
        processes = payload["result"]["runningProcesses"]
        if not isinstance(processes, list):
            raise OwnershipError("devicectl runningProcesses must be an array")
        matches: list[dict[str, object]] = []
        for entry in processes:
            if not isinstance(entry, dict):
                raise OwnershipError("devicectl process entry must be an object")
            entry_pid = entry.get("processIdentifier")
            if isinstance(entry_pid, bool) or not isinstance(entry_pid, int):
                raise OwnershipError("devicectl processIdentifier must be an integer")
            if entry_pid == pid:
                matches.append(entry)
        if not matches:
            return ABSENT
        if len(matches) != 1:
            raise OwnershipError("devicectl returned duplicate entries for the launched PID")
        process = matches[0]
        actual_executable = _normalized_file_url_path(process.get("executable"), "running executable")
        actual_path = pathlib.PurePosixPath(actual_executable)
        if (
            actual_executable != executable_path
            or actual_path.name != executable_name
            or actual_path.parent.name != bundle_name
        ):
            raise OwnershipError("iOS PID executable does not match the launch record")
        if "auditToken" not in process:
            raise OwnershipError(
                "devicectl process schema lacks auditToken; ownership is unverifiable and termination is forbidden"
            )
        actual_audit_token = _strict_audit_token(process["auditToken"])
        if actual_audit_token != audit_token:
            raise OwnershipError("iOS PID audit token does not match the launch record")
    except (KeyError, TypeError, OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"process-ownership error: iOS process list is malformed ({type(error).__name__})", file=sys.stderr)
        return UNVERIFIABLE
    except OwnershipError as error:
        print(f"process-ownership error: {error}", file=sys.stderr)
        return UNVERIFIABLE
    return MATCH


def identity_pid(identity_path: pathlib.Path, platform: str) -> int:
    if platform == "macos":
        pid, _ = _parse_mac_identity(identity_path)
        return pid
    pid, _, _, _, _ = _parse_ios_identity(identity_path)
    return pid


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    mac_capture_parser = subparsers.add_parser("mac-capture")
    mac_capture_parser.add_argument("--pid", required=True, type=int)
    mac_capture_parser.add_argument("--expected-executable", required=True, type=pathlib.Path)
    mac_capture_parser.add_argument("--output", required=True, type=pathlib.Path)

    mac_status_parser = subparsers.add_parser("mac-status")
    mac_status_parser.add_argument("--identity", required=True, type=pathlib.Path)

    mac_signal_parser = subparsers.add_parser("mac-signal")
    mac_signal_parser.add_argument("--identity", required=True, type=pathlib.Path)
    mac_signal_parser.add_argument("--signal", choices=("TERM", "KILL"), required=True)

    ios_capture_parser = subparsers.add_parser("ios-capture")
    ios_capture_parser.add_argument("--launch-json", required=True, type=pathlib.Path)
    ios_capture_parser.add_argument("--app-path", required=True, type=pathlib.Path)
    ios_capture_parser.add_argument("--output", required=True, type=pathlib.Path)

    ios_status_parser = subparsers.add_parser("ios-status")
    ios_status_parser.add_argument("--processes-json", required=True, type=pathlib.Path)
    ios_status_parser.add_argument("--identity", required=True, type=pathlib.Path)

    identity_pid_parser = subparsers.add_parser("identity-pid")
    identity_pid_parser.add_argument("--identity", required=True, type=pathlib.Path)
    identity_pid_parser.add_argument("--platform", choices=("macos", "ios"), required=True)
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "mac-capture":
            pid = _strict_positive_pid(args.pid, "pid")
            mac_capture(pid, args.expected_executable, args.output)
            return MATCH
        if args.command == "mac-status":
            return mac_status(args.identity)
        if args.command == "mac-signal":
            signal_number = signal.SIGTERM if args.signal == "TERM" else signal.SIGKILL
            return mac_signal(args.identity, signal_number)
        if args.command == "ios-capture":
            ios_capture(args.launch_json, args.app_path, args.output)
            return MATCH
        if args.command == "ios-status":
            return ios_status(args.processes_json, args.identity)
        if args.command == "identity-pid":
            print(identity_pid(args.identity, args.platform))
            return MATCH
    except OwnershipError as error:
        _fail(str(error))
    except Exception as error:
        print(
            f"process-ownership internal failure: {type(error).__name__}; ownership is unverifiable",
            file=sys.stderr,
        )
        return UNVERIFIABLE
    raise AssertionError(f"unhandled command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
