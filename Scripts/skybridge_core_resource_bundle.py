#!/usr/bin/python3
"""Normalize and atomically install the SkyBridgeCore SwiftPM resource bundle.

The source is copied into a private, descriptor-bound snapshot before layout
inspection.  The normalized bundle is fully proved before a no-replace Darwin
rename publishes it into the caller-owned destination directory.
"""

from __future__ import annotations

import contextlib
import ctypes
import ctypes.util
import dataclasses
import enum
import errno
import hashlib
import os
import secrets
import signal
import stat
import subprocess
import sys
from typing import Callable, Dict, Iterable, Iterator, List, Optional, Sequence, Set, Tuple


RENAME_EXCL = 0x00000004
RENAME_NOFOLLOW_ANY = 0x00000010
RENAME_RESOLVE_BENEATH = 0x00000020
RENAME_FLAGS = RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
ACL_TYPE_EXTENDED = 0x00000100
ACL_FIRST_ENTRY = 0
SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
OPEN_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
OPEN_FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
MAXIMUM_ENTRY_COUNT = 20_000
MAXIMUM_TOTAL_BYTES = 512 * 1024 * 1024
MAXIMUM_SOURCE_DEPTH = 128
MAXIMUM_CLEANUP_DEPTH = 256


class Layout(enum.Enum):
    FLAT = "swiftpm-flat"
    MACOS_CONTENTS = "swiftpm-macos-contents"


class Phase(enum.Enum):
    INIT = "init"
    ENDPOINTS_OPEN = "endpoints-open"
    WORKSPACE_CREATED = "workspace-created"
    SNAPSHOT_READY = "snapshot-ready"
    SNAPSHOT_VERIFIED = "snapshot-verified"
    NORMALIZED_READY = "normalized-ready"
    STAGED_VERIFIED = "staged-verified"
    PUBLISH_ATTEMPTED = "publish-attempted"
    PUBLISHED = "published"
    FINAL_VERIFIED = "final-verified"
    COMMITTED = "committed"


class BundleError(Exception):
    def __init__(self, reason: str, status: int = 1) -> None:
        super().__init__(reason)
        self.reason = reason
        self.status = status


class SignalInterruption(BaseException):
    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


@dataclasses.dataclass(frozen=True)
class Identity:
    device: int
    inode: int

    @classmethod
    def from_stat(cls, metadata: os.stat_result) -> "Identity":
        return cls(metadata.st_dev, metadata.st_ino)


@dataclasses.dataclass(frozen=True)
class ContentRecord:
    path: bytes
    kind: bytes
    mode: int
    digest: bytes


@dataclasses.dataclass(frozen=True)
class StableRecord:
    content: ContentRecord
    identity: Identity
    size: int
    modified_ns: int
    changed_ns: int


@dataclasses.dataclass(frozen=True)
class TreeInventory:
    content: Tuple[ContentRecord, ...]
    stable: Tuple[StableRecord, ...]
    total_bytes: int


Observer = Callable[[Phase], None]


@dataclasses.dataclass
class CopyBudget:
    entries: int = 0
    total_bytes: int = 0

    def consume_entry(self) -> None:
        self.entries += 1
        if self.entries > MAXIMUM_ENTRY_COUNT:
            _fail("source-resource-limit-exceeded")

    def consume_bytes(self, count: int) -> None:
        self.total_bytes += count
        if self.total_bytes > MAXIMUM_TOTAL_BYTES:
            _fail("source-resource-limit-exceeded")


def _fail(reason: str, status: int = 1) -> None:
    raise BundleError(reason, status)


def _identity(metadata: os.stat_result) -> Identity:
    return Identity.from_stat(metadata)


def _metadata_stable(lhs: os.stat_result, rhs: os.stat_result) -> bool:
    return (
        _identity(lhs) == _identity(rhs)
        and stat.S_IFMT(lhs.st_mode) == stat.S_IFMT(rhs.st_mode)
        and stat.S_IMODE(lhs.st_mode) == stat.S_IMODE(rhs.st_mode)
        and lhs.st_nlink == rhs.st_nlink
        and lhs.st_size == rhs.st_size
        and lhs.st_mtime_ns == rhs.st_mtime_ns
        and lhs.st_ctime_ns == rhs.st_ctime_ns
    )


def _validate_source_mode(mode: int) -> None:
    if mode & 0o7022:
        _fail("source-contains-unsafe-permissions")


def _open_absolute_dir_nofollow(path: bytes) -> int:
    if not path.startswith(b"/"):
        _fail("absolute-path-required", 2)
    components = path.split(b"/")[1:]
    if not components or any(component in (b"", b".", b"..") for component in components):
        _fail("noncanonical-absolute-path", 2)
    current = os.open(b"/", OPEN_DIRECTORY_FLAGS)
    try:
        for component in components:
            next_fd = os.open(component, OPEN_DIRECTORY_FLAGS, dir_fd=current)
            os.close(current)
            current = next_fd
        return current
    except BaseException:
        os.close(current)
        raise


def _canonical_existing_directory(path: str, reason: str, status: int) -> bytes:
    if not os.path.isabs(path):
        _fail("absolute-path-required", 2)
    try:
        leaf = os.lstat(path)
    except OSError:
        _fail(reason, status)
    if not stat.S_ISDIR(leaf.st_mode) or stat.S_ISLNK(leaf.st_mode):
        _fail(reason, status)
    canonical = os.fsencode(os.path.realpath(path))
    if not canonical.startswith(b"/"):
        _fail(reason, status)
    return canonical


def _list_names(directory_fd: int) -> List[bytes]:
    scan_fd = -1
    try:
        scan_fd = os.dup(directory_fd)
        with os.scandir(scan_fd) as iterator:
            names = [os.fsencode(entry.name) for entry in iterator]
    except OSError:
        _fail("directory-scan-failed")
    finally:
        if scan_fd >= 0:
            os.close(scan_fd)
    return sorted(names)


def _join_relative(prefix: bytes, name: bytes) -> bytes:
    return name if not prefix else prefix + b"/" + name


def _hash_open_file(file_fd: int) -> Tuple[bytes, int]:
    digest = hashlib.sha256()
    size = 0
    while True:
        block = os.read(file_fd, 1024 * 1024)
        if not block:
            break
        size += len(block)
        if size > MAXIMUM_TOTAL_BYTES:
            _fail("source-resource-limit-exceeded")
        digest.update(block)
    return digest.digest(), size


def _scan_tree(root_fd: int) -> TreeInventory:
    content: List[ContentRecord] = []
    stable: List[StableRecord] = []
    total_bytes = 0

    def append_record(
        relative_path: bytes,
        kind: bytes,
        metadata: os.stat_result,
        digest: bytes = b"",
    ) -> None:
        if len(content) >= MAXIMUM_ENTRY_COUNT:
            _fail("source-resource-limit-exceeded")
        mode = stat.S_IMODE(metadata.st_mode)
        _validate_source_mode(mode)
        record = ContentRecord(relative_path, kind, mode, digest)
        content.append(record)
        stable.append(
            StableRecord(
                record,
                _identity(metadata),
                metadata.st_size,
                metadata.st_mtime_ns,
                metadata.st_ctime_ns,
            )
        )

    def visit(directory_fd: int, relative_prefix: bytes, depth: int) -> None:
        nonlocal total_bytes
        if depth > MAXIMUM_SOURCE_DEPTH:
            _fail("source-resource-limit-exceeded")
        before = os.fstat(directory_fd)
        if not stat.S_ISDIR(before.st_mode):
            _fail("source-contains-special-file")
        append_record(relative_prefix, b"D", before)
        for name in _list_names(directory_fd):
            relative_path = _join_relative(relative_prefix, name)
            try:
                observed = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            except OSError:
                _fail("source-changed-during-scan")
            if stat.S_ISDIR(observed.st_mode):
                try:
                    child_fd = os.open(name, OPEN_DIRECTORY_FLAGS, dir_fd=directory_fd)
                except OSError:
                    _fail("source-contains-symlink")
                try:
                    if not _metadata_stable(observed, os.fstat(child_fd)):
                        _fail("source-changed-during-scan")
                    visit(child_fd, relative_path, depth + 1)
                finally:
                    os.close(child_fd)
            elif stat.S_ISREG(observed.st_mode):
                if observed.st_nlink != 1:
                    _fail("source-contains-hardlink")
                try:
                    file_fd = os.open(name, OPEN_FILE_FLAGS, dir_fd=directory_fd)
                except OSError:
                    _fail("source-contains-symlink")
                try:
                    opened = os.fstat(file_fd)
                    if not _metadata_stable(observed, opened):
                        _fail("source-changed-during-scan")
                    digest, byte_count = _hash_open_file(file_fd)
                    after = os.fstat(file_fd)
                    if not _metadata_stable(opened, after) or byte_count != opened.st_size:
                        _fail("source-changed-during-scan")
                    total_bytes += byte_count
                    if total_bytes > MAXIMUM_TOTAL_BYTES:
                        _fail("source-resource-limit-exceeded")
                    append_record(relative_path, b"F", opened, digest)
                finally:
                    os.close(file_fd)
            elif stat.S_ISLNK(observed.st_mode):
                _fail("source-contains-symlink")
            else:
                _fail("source-contains-special-file")
        after = os.fstat(directory_fd)
        if not _metadata_stable(before, after):
            _fail("source-changed-during-scan")

    visit(root_fd, b"", 0)
    return TreeInventory(tuple(content), tuple(stable), total_bytes)


def _copy_file_at(
    source_parent_fd: int,
    source_name: bytes,
    destination_parent_fd: int,
    destination_name: bytes,
    budget: Optional[CopyBudget] = None,
) -> None:
    active_budget = budget or CopyBudget()
    active_budget.consume_entry()
    try:
        observed = os.stat(source_name, dir_fd=source_parent_fd, follow_symlinks=False)
    except OSError:
        _fail("source-changed-during-copy")
    if not stat.S_ISREG(observed.st_mode) or observed.st_nlink != 1:
        _fail("source-changed-during-copy")
    _validate_source_mode(stat.S_IMODE(observed.st_mode))
    try:
        source_fd = os.open(source_name, OPEN_FILE_FLAGS, dir_fd=source_parent_fd)
    except OSError:
        _fail("resource-copy-failed")
    try:
        destination_fd = os.open(
            destination_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=destination_parent_fd,
        )
    except OSError:
        os.close(source_fd)
        _fail("resource-copy-failed")
    try:
        opened = os.fstat(source_fd)
        if not _metadata_stable(observed, opened):
            _fail("source-changed-during-copy")
        copied = 0
        while True:
            block = os.read(source_fd, 1024 * 1024)
            if not block:
                break
            active_budget.consume_bytes(len(block))
            view = memoryview(block)
            while view:
                written = os.write(destination_fd, view)
                if written <= 0:
                    _fail("resource-copy-failed")
                view = view[written:]
            copied += len(block)
        if copied != opened.st_size or not _metadata_stable(opened, os.fstat(source_fd)):
            _fail("source-changed-during-copy")
        os.fchmod(destination_fd, stat.S_IMODE(opened.st_mode))
        os.fsync(destination_fd)
    finally:
        os.close(source_fd)
        os.close(destination_fd)


def _copy_directory_contents(
    source_fd: int,
    destination_fd: int,
    excluded_root_names: Optional[Set[bytes]] = None,
    budget: Optional[CopyBudget] = None,
    depth: int = 0,
) -> None:
    if depth > MAXIMUM_SOURCE_DEPTH:
        _fail("source-resource-limit-exceeded")
    active_budget = budget or CopyBudget()
    active_budget.consume_entry()
    excluded = excluded_root_names or set()
    source_root = os.fstat(source_fd)
    _validate_source_mode(stat.S_IMODE(source_root.st_mode))
    for name in _list_names(source_fd):
        if name in excluded:
            continue
        observed = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
        if stat.S_ISDIR(observed.st_mode):
            os.mkdir(name, 0o700, dir_fd=destination_fd)
            os.chmod(name, 0o700, dir_fd=destination_fd, follow_symlinks=False)
            child_source_fd = os.open(name, OPEN_DIRECTORY_FLAGS, dir_fd=source_fd)
            child_destination_fd = os.open(name, OPEN_DIRECTORY_FLAGS, dir_fd=destination_fd)
            try:
                if not _metadata_stable(observed, os.fstat(child_source_fd)):
                    _fail("source-changed-during-copy")
                _copy_directory_contents(
                    child_source_fd,
                    child_destination_fd,
                    budget=active_budget,
                    depth=depth + 1,
                )
                if not _metadata_stable(observed, os.fstat(child_source_fd)):
                    _fail("source-changed-during-copy")
                os.fchmod(child_destination_fd, stat.S_IMODE(observed.st_mode))
                os.fsync(child_destination_fd)
            finally:
                os.close(child_source_fd)
                os.close(child_destination_fd)
        elif stat.S_ISREG(observed.st_mode):
            _copy_file_at(source_fd, name, destination_fd, name, active_budget)
        elif stat.S_ISLNK(observed.st_mode):
            _fail("source-contains-symlink")
        else:
            _fail("source-contains-special-file")
    os.fchmod(destination_fd, stat.S_IMODE(source_root.st_mode))
    os.fsync(destination_fd)


def _create_and_open_directory(parent_fd: int, name: bytes, mode: int) -> Tuple[int, Identity]:
    try:
        os.mkdir(name, mode, dir_fd=parent_fd)
        os.chmod(name, mode, dir_fd=parent_fd, follow_symlinks=False)
        directory_fd = os.open(name, OPEN_DIRECTORY_FLAGS, dir_fd=parent_fd)
    except OSError:
        _fail("staging-create-failed")
    metadata = os.fstat(directory_fd)
    return directory_fd, _identity(metadata)


def _entry_metadata(parent_fd: int, name: bytes) -> Optional[os.stat_result]:
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError:
        _fail("filesystem-entry-stat-failed")


def _open_relative_directory(parent_fd: int, path_components: Iterable[bytes]) -> int:
    current = os.dup(parent_fd)
    try:
        for component in path_components:
            next_fd = os.open(component, OPEN_DIRECTORY_FLAGS, dir_fd=current)
            os.close(current)
            current = next_fd
        return current
    except BaseException:
        os.close(current)
        raise


def _directory_has_ancestor_identity(directory_fd: int, ancestor: Identity) -> bool:
    current = os.dup(directory_fd)
    try:
        for _ in range(1_024):
            current_identity = _identity(os.fstat(current))
            if current_identity == ancestor:
                return True
            parent = os.open(b"..", OPEN_DIRECTORY_FLAGS, dir_fd=current)
            parent_identity = _identity(os.fstat(parent))
            if parent_identity == current_identity:
                os.close(parent)
                return False
            os.close(current)
            current = parent
    finally:
        os.close(current)
    _fail("filesystem-ancestor-walk-exceeded", 2)
    return False


def _file_record(parent_fd: int, name: bytes) -> ContentRecord:
    metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        _fail("required-info-plist-invalid")
    file_fd = os.open(name, OPEN_FILE_FLAGS, dir_fd=parent_fd)
    try:
        opened = os.fstat(file_fd)
        if not _metadata_stable(metadata, opened):
            _fail("source-changed-during-scan")
        digest, byte_count = _hash_open_file(file_fd)
        if byte_count != opened.st_size or not _metadata_stable(opened, os.fstat(file_fd)):
            _fail("source-changed-during-scan")
        return ContentRecord(b"Info.plist", b"F", stat.S_IMODE(opened.st_mode), digest)
    finally:
        os.close(file_fd)


def _contains_signature_component(path: bytes) -> bool:
    return b"_CodeSignature" in path.split(b"/")


@dataclasses.dataclass(frozen=True)
class SnapshotLayout:
    layout: Layout
    info_parent_components: Tuple[bytes, ...]
    resources_components: Tuple[bytes, ...]
    signed: bool


def _detect_layout(snapshot_fd: int, inventory: TreeInventory) -> SnapshotLayout:
    root_names = set(_list_names(snapshot_fd))
    flat = b"Info.plist" in root_names and b"en.lproj" in root_names and b"Contents" not in root_names
    if flat:
        if any(_contains_signature_component(record.path) for record in inventory.content if record.path):
            _fail("source-payload-contains-signature-material")
        _file_record(snapshot_fd, b"Info.plist")
        en_metadata = os.stat(b"en.lproj", dir_fd=snapshot_fd, follow_symlinks=False)
        if not stat.S_ISDIR(en_metadata.st_mode):
            _fail("unsupported-or-ambiguous-layout")
        return SnapshotLayout(Layout.FLAT, tuple(), tuple(), False)

    if root_names != {b"Contents"}:
        _fail("unsupported-or-ambiguous-layout")
    contents_fd = _open_relative_directory(snapshot_fd, (b"Contents",))
    try:
        contents_names = set(_list_names(contents_fd))
        unsigned_names = {b"Info.plist", b"Resources"}
        signed_names = unsigned_names | {b"_CodeSignature"}
        if contents_names not in (unsigned_names, signed_names):
            _fail("unsupported-or-ambiguous-layout")
        _file_record(contents_fd, b"Info.plist")
        resources_fd = _open_relative_directory(contents_fd, (b"Resources",))
        try:
            en_metadata = os.stat(b"en.lproj", dir_fd=resources_fd, follow_symlinks=False)
            if not stat.S_ISDIR(en_metadata.st_mode):
                _fail("unsupported-or-ambiguous-layout")
        finally:
            os.close(resources_fd)
        signed = b"_CodeSignature" in contents_names
        if signed:
            signature_metadata = os.stat(b"_CodeSignature", dir_fd=contents_fd, follow_symlinks=False)
            if not stat.S_ISDIR(signature_metadata.st_mode):
                _fail("source-signature-invalid")
        for record in inventory.content:
            if not record.path or not _contains_signature_component(record.path):
                continue
            components = record.path.split(b"/")
            if not signed or components[:2] != [b"Contents", b"_CodeSignature"] or components.count(b"_CodeSignature") != 1:
                _fail("source-payload-contains-signature-material")
        return SnapshotLayout(
            Layout.MACOS_CONTENTS,
            (b"Contents",),
            (b"Contents", b"Resources"),
            signed,
        )
    finally:
        os.close(contents_fd)


def _resource_manifest(snapshot_fd: int, layout: SnapshotLayout) -> TreeInventory:
    resources_fd = _open_relative_directory(snapshot_fd, layout.resources_components)
    try:
        inventory = _scan_tree(resources_fd)
    finally:
        os.close(resources_fd)
    if layout.layout == Layout.FLAT:
        content = tuple(record for record in inventory.content if record.path != b"Info.plist")
        stable = tuple(record for record in inventory.stable if record.content.path != b"Info.plist")
        return TreeInventory(content, stable, inventory.total_bytes)
    return inventory


class DarwinPlatform:
    def __init__(self) -> None:
        library_path = ctypes.util.find_library("System") or "/usr/lib/libSystem.B.dylib"
        try:
            self._libc = ctypes.CDLL(library_path, use_errno=True)
            self._renameatx = self._libc.renameatx_np
            self._renameatx.argtypes = [
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_uint,
            ]
            self._renameatx.restype = ctypes.c_int
            self._acl_get_fd = self._libc.acl_get_fd_np
            self._acl_get_fd.argtypes = [ctypes.c_int, ctypes.c_int]
            self._acl_get_fd.restype = ctypes.c_void_p
            self._acl_get_entry = self._libc.acl_get_entry
            self._acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
            self._acl_get_entry.restype = ctypes.c_int
            self._acl_free = self._libc.acl_free
            self._acl_free.argtypes = [ctypes.c_void_p]
            self._acl_free.restype = ctypes.c_int
        except (AttributeError, OSError):
            _fail("required-darwin-filesystem-api-unavailable")

    def require_no_extended_acl(self, directory_fd: int) -> None:
        ctypes.set_errno(0)
        acl = self._acl_get_fd(directory_fd, ACL_TYPE_EXTENDED)
        if not acl:
            error_number = ctypes.get_errno()
            if error_number not in (0, errno.ENOENT):
                _fail("destination-parent-acl-inspection-failed", 2)
            return
        try:
            entry = ctypes.c_void_p()
            result = self._acl_get_entry(acl, ACL_FIRST_ENTRY, ctypes.byref(entry))
            if result == 1:
                _fail("unsafe-destination-parent-acl", 2)
            if result < 0:
                _fail("destination-parent-acl-inspection-failed", 2)
        finally:
            self._acl_free(acl)

    def rename_exclusive(
        self,
        source_parent_fd: int,
        source_name: bytes,
        destination_parent_fd: int,
        destination_name: bytes,
    ) -> None:
        ctypes.set_errno(0)
        result = self._renameatx(
            source_parent_fd,
            ctypes.c_char_p(source_name),
            destination_parent_fd,
            ctypes.c_char_p(destination_name),
            RENAME_FLAGS,
        )
        if result == 0:
            return
        error_number = ctypes.get_errno()
        if error_number in (errno.EEXIST, errno.ENOTEMPTY):
            _fail("destination-raced", 2)
        _fail("atomic-install-failed")

    def verify_codesign(self, bundle_fd: int) -> None:
        expected_identity = _identity(os.fstat(bundle_fd))
        verifier_program = (
            "import os,sys; "
            "fd=int(sys.argv[1]); "
            "os.set_inheritable(fd,True); "
            "os.fchdir(fd); "
            "os.execve('/usr/bin/codesign',"
            "['codesign','--verify','--strict','--verbose=2','.'],"
            "{'PATH':'/usr/bin:/bin','LC_ALL':'C'})"
        )
        try:
            result = subprocess.run(
                ["/usr/bin/python3", "-I", "-c", verifier_program, str(bundle_fd)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                close_fds=True,
                pass_fds=(bundle_fd,),
            )
            if _identity(os.fstat(bundle_fd)) != expected_identity:
                _fail("snapshot-identity-changed")
        except OSError:
            _fail("source-signature-verification-failed")
        if result.returncode != 0:
            _fail("source-signature-invalid")


@contextlib.contextmanager
def _blocked_transaction_signals() -> Iterator[None]:
    if not hasattr(signal, "pthread_sigmask"):
        _fail("required-signal-api-unavailable")
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, SIGNALS)
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def _remove_owned_tree(
    parent_fd: int,
    name: bytes,
    expected: Identity,
    depth: int = 0,
) -> None:
    if depth > MAXIMUM_CLEANUP_DEPTH:
        _fail("cleanup-depth-limit-exceeded")
    observed = _entry_metadata(parent_fd, name)
    if observed is None:
        return
    if not stat.S_ISDIR(observed.st_mode) or stat.S_ISLNK(observed.st_mode) or _identity(observed) != expected:
        _fail("cleanup-identity-mismatch")
    directory_fd = os.open(name, OPEN_DIRECTORY_FLAGS, dir_fd=parent_fd)
    try:
        if _identity(os.fstat(directory_fd)) != expected:
            _fail("cleanup-identity-mismatch")
        for child_name in _list_names(directory_fd):
            child = os.stat(child_name, dir_fd=directory_fd, follow_symlinks=False)
            if stat.S_ISDIR(child.st_mode):
                _remove_owned_tree(directory_fd, child_name, _identity(child), depth + 1)
            else:
                os.unlink(child_name, dir_fd=directory_fd)
    finally:
        os.close(directory_fd)
    final = _entry_metadata(parent_fd, name)
    if final is None or _identity(final) != expected or not stat.S_ISDIR(final.st_mode):
        _fail("cleanup-identity-mismatch")
    os.rmdir(name, dir_fd=parent_fd)


class BundleTransaction:
    SNAPSHOT_NAME = b"snapshot.bundle"
    NORMALIZED_NAME = b"normalized.bundle"
    ROLLBACK_NAME = b"rollback.bundle"

    def __init__(
        self,
        source: str,
        destination: str,
        platform: DarwinPlatform,
        observer: Optional[Observer],
    ) -> None:
        self.source_argument = source
        self.destination_argument = destination
        self.platform = platform
        self.observer = observer
        self.phase = Phase.INIT
        self.source_fd = -1
        self.destination_parent_fd = -1
        self.transaction_fd = -1
        self.snapshot_fd = -1
        self.snapshot_identity: Optional[Identity] = None
        self.normalized_fd = -1
        self.final_fd = -1
        self.transaction_name = b""
        self.transaction_identity: Optional[Identity] = None
        self.candidate_identity: Optional[Identity] = None
        self.destination_name = b""
        self.source_canonical = b""
        self.source_identity: Optional[Identity] = None
        self.committed = False
        self.publish_attempted = False

    def _advance(self, phase: Phase) -> None:
        self.phase = phase
        if self.observer is not None:
            self.observer(phase)

    def _open_endpoints(self) -> None:
        if "\0" in self.source_argument or "\0" in self.destination_argument:
            _fail("invalid-path", 2)
        source_canonical = _canonical_existing_directory(
            self.source_argument,
            "source-missing-or-symlinked",
            1,
        )
        if not os.path.isabs(self.destination_argument):
            _fail("absolute-path-required", 2)
        destination_parent_argument = os.path.dirname(self.destination_argument)
        destination_name = os.fsencode(os.path.basename(self.destination_argument))
        if destination_name in (b"", b".", b"..") or b"/" in destination_name:
            _fail("unsafe-destination-name", 2)
        destination_parent_canonical = _canonical_existing_directory(
            destination_parent_argument,
            "unsafe-destination-parent",
            2,
        )
        destination_canonical = destination_parent_canonical + b"/" + destination_name
        if (
            destination_canonical == source_canonical
            or destination_canonical.startswith(source_canonical + b"/")
            or source_canonical.startswith(destination_canonical + b"/")
        ):
            _fail("source-destination-overlap", 2)

        try:
            self.source_fd = _open_absolute_dir_nofollow(source_canonical)
            self.destination_parent_fd = _open_absolute_dir_nofollow(destination_parent_canonical)
        except OSError:
            _fail("endpoint-open-failed", 2)
        self.source_canonical = source_canonical
        self.source_identity = _identity(os.fstat(self.source_fd))
        self.destination_name = destination_name
        parent_metadata = os.fstat(self.destination_parent_fd)
        parent_mode = stat.S_IMODE(parent_metadata.st_mode)
        if parent_metadata.st_uid != os.getuid():
            _fail("unsafe-destination-parent", 2)
        if parent_mode & 0o022:
            _fail("unsafe-destination-parent-permissions", 2)
        self.platform.require_no_extended_acl(self.destination_parent_fd)
        if _directory_has_ancestor_identity(self.destination_parent_fd, self.source_identity):
            _fail("source-destination-overlap", 2)
        if _entry_metadata(self.destination_parent_fd, destination_name) is not None:
            _fail("destination-already-exists", 2)
        self._advance(Phase.ENDPOINTS_OPEN)

    def _create_workspace(self) -> None:
        for _ in range(32):
            candidate = os.fsencode(".skybridge-core-resource." + secrets.token_hex(16))
            try:
                os.mkdir(candidate, 0o700, dir_fd=self.destination_parent_fd)
                os.chmod(
                    candidate,
                    0o700,
                    dir_fd=self.destination_parent_fd,
                    follow_symlinks=False,
                )
            except FileExistsError:
                continue
            except OSError:
                _fail("staging-create-failed")
            self.transaction_name = candidate
            self.transaction_fd = os.open(candidate, OPEN_DIRECTORY_FLAGS, dir_fd=self.destination_parent_fd)
            self.transaction_identity = _identity(os.fstat(self.transaction_fd))
            self._advance(Phase.WORKSPACE_CREATED)
            return
        _fail("staging-create-failed")

    def _verify_source_identity(self) -> None:
        try:
            reopened = _open_absolute_dir_nofollow(self.source_canonical)
        except OSError:
            _fail("source-identity-changed")
        try:
            if _identity(os.fstat(reopened)) != self.source_identity:
                _fail("source-identity-changed")
        finally:
            os.close(reopened)

    def _snapshot(self) -> Tuple[TreeInventory, TreeInventory]:
        before = _scan_tree(self.source_fd)
        self.snapshot_fd, self.snapshot_identity = _create_and_open_directory(
            self.transaction_fd,
            self.SNAPSHOT_NAME,
            0o700,
        )
        _copy_directory_contents(self.source_fd, self.snapshot_fd)
        after = _scan_tree(self.source_fd)
        self._verify_source_identity()
        if before.stable != after.stable:
            _fail("source-resources-changed-during-copy")
        snapshot = _scan_tree(self.snapshot_fd)
        if before.content != snapshot.content:
            _fail("snapshot-copy-proof-failed")
        self._advance(Phase.SNAPSHOT_READY)
        return before, snapshot

    def _build_normalized(
        self,
        layout: SnapshotLayout,
    ) -> Tuple[ContentRecord, TreeInventory]:
        info_parent_fd = _open_relative_directory(self.snapshot_fd, layout.info_parent_components)
        resources_fd = _open_relative_directory(self.snapshot_fd, layout.resources_components)
        try:
            expected_info = _file_record(info_parent_fd, b"Info.plist")
            expected_resources = _resource_manifest(self.snapshot_fd, layout)
            self.normalized_fd, self.candidate_identity = _create_and_open_directory(
                self.transaction_fd,
                self.NORMALIZED_NAME,
                0o755,
            )
            contents_fd, _ = _create_and_open_directory(self.normalized_fd, b"Contents", 0o755)
            try:
                normalized_resources_fd, _ = _create_and_open_directory(
                    contents_fd,
                    b"Resources",
                    0o755,
                )
                try:
                    excluded = {b"Info.plist"} if layout.layout == Layout.FLAT else set()
                    _copy_directory_contents(resources_fd, normalized_resources_fd, excluded)
                finally:
                    os.close(normalized_resources_fd)
                _copy_file_at(info_parent_fd, b"Info.plist", contents_fd, b"Info.plist")
                os.fsync(contents_fd)
            finally:
                os.close(contents_fd)
            os.fsync(self.normalized_fd)
        finally:
            os.close(info_parent_fd)
            os.close(resources_fd)
        self._advance(Phase.NORMALIZED_READY)
        return expected_info, expected_resources

    def _verify_canonical(
        self,
        bundle_fd: int,
        expected_info: ContentRecord,
        expected_resources: TreeInventory,
    ) -> None:
        if stat.S_IMODE(os.fstat(bundle_fd).st_mode) != 0o755:
            _fail("normalized-container-mode-proof-failed")
        if set(_list_names(bundle_fd)) != {b"Contents"}:
            _fail("normalized-shape-proof-failed")
        contents_fd = _open_relative_directory(bundle_fd, (b"Contents",))
        try:
            if stat.S_IMODE(os.fstat(contents_fd).st_mode) != 0o755:
                _fail("normalized-container-mode-proof-failed")
            if set(_list_names(contents_fd)) != {b"Info.plist", b"Resources"}:
                _fail("normalized-shape-proof-failed")
            actual_info = _file_record(contents_fd, b"Info.plist")
            if actual_info != expected_info:
                _fail("info-copy-proof-failed")
            resources_fd = _open_relative_directory(contents_fd, (b"Resources",))
            try:
                actual_resources = _scan_tree(resources_fd)
            finally:
                os.close(resources_fd)
        finally:
            os.close(contents_fd)
        if actual_resources.content != expected_resources.content:
            _fail("resource-copy-proof-failed")
        full_inventory = _scan_tree(bundle_fd)
        if any(
            _contains_signature_component(record.path)
            for record in full_inventory.content
            if record.path
        ):
            _fail("normalized-bundle-contains-signature-material")

    def _publish(
        self,
        expected_info: ContentRecord,
        expected_resources: TreeInventory,
    ) -> None:
        candidate_metadata = _entry_metadata(self.transaction_fd, self.NORMALIZED_NAME)
        if (
            candidate_metadata is None
            or self.candidate_identity is None
            or _identity(candidate_metadata) != self.candidate_identity
            or _identity(os.fstat(self.normalized_fd)) != self.candidate_identity
        ):
            _fail("staging-identity-changed")
        if _entry_metadata(self.destination_parent_fd, self.destination_name) is not None:
            _fail("destination-raced", 2)
        self._verify_source_identity()
        self.publish_attempted = True
        self._advance(Phase.PUBLISH_ATTEMPTED)
        with _blocked_transaction_signals():
            self.platform.rename_exclusive(
                self.transaction_fd,
                self.NORMALIZED_NAME,
                self.destination_parent_fd,
                self.destination_name,
            )
            try:
                self.final_fd = os.open(
                    self.destination_name,
                    OPEN_DIRECTORY_FLAGS,
                    dir_fd=self.destination_parent_fd,
                )
            except OSError:
                _fail("published-destination-open-failed")
            final_metadata = os.fstat(self.final_fd)
            final_entry = _entry_metadata(self.destination_parent_fd, self.destination_name)
            if (
                final_entry is None
                or self.candidate_identity is None
                or _identity(final_metadata) != self.candidate_identity
                or _identity(final_entry) != self.candidate_identity
            ):
                _fail("published-destination-identity-mismatch")
            self._advance(Phase.PUBLISHED)
        self._verify_published_identity()
        self._verify_canonical(self.final_fd, expected_info, expected_resources)
        self._verify_published_identity()
        os.fsync(self.final_fd)
        os.fsync(self.destination_parent_fd)
        self._advance(Phase.FINAL_VERIFIED)

    def _verify_published_identity(self) -> None:
        final_entry = _entry_metadata(self.destination_parent_fd, self.destination_name)
        if (
            final_entry is None
            or self.candidate_identity is None
            or self.final_fd < 0
            or _identity(final_entry) != self.candidate_identity
            or _identity(os.fstat(self.final_fd)) != self.candidate_identity
            or not stat.S_ISDIR(final_entry.st_mode)
        ):
            _fail("published-destination-identity-mismatch")

    def _rollback_if_needed(self) -> None:
        if self.committed or not self.publish_attempted or self.candidate_identity is None:
            return
        candidate = _entry_metadata(self.transaction_fd, self.NORMALIZED_NAME)
        if candidate is not None:
            if _identity(candidate) != self.candidate_identity:
                _fail("cleanup-identity-mismatch")
            return
        destination = _entry_metadata(self.destination_parent_fd, self.destination_name)
        if destination is None:
            _fail("published-destination-missing")
        if _identity(destination) != self.candidate_identity or not stat.S_ISDIR(destination.st_mode):
            _fail("published-destination-identity-mismatch")
        if _entry_metadata(self.transaction_fd, self.ROLLBACK_NAME) is not None:
            _fail("cleanup-identity-mismatch")
        self.platform.rename_exclusive(
            self.destination_parent_fd,
            self.destination_name,
            self.transaction_fd,
            self.ROLLBACK_NAME,
        )
        _remove_owned_tree(self.transaction_fd, self.ROLLBACK_NAME, self.candidate_identity)

    def _discard_snapshot_before_publish(self) -> None:
        if self.snapshot_fd < 0 or self.snapshot_identity is None:
            _fail("snapshot-identity-missing")
        os.close(self.snapshot_fd)
        self.snapshot_fd = -1
        _remove_owned_tree(
            self.transaction_fd,
            self.SNAPSHOT_NAME,
            self.snapshot_identity,
        )
        self.snapshot_identity = None

    def _close_descriptor(self, attribute: str) -> None:
        descriptor = getattr(self, attribute)
        if descriptor >= 0:
            os.close(descriptor)
            setattr(self, attribute, -1)

    def _commit(
        self,
        expected_info: ContentRecord,
        expected_resources: TreeInventory,
    ) -> None:
        # FINAL_VERIFIED is an observable test/evidence boundary. Re-prove both
        # the dentry identity and bytes after that boundary before committing.
        self._verify_published_identity()
        self._verify_canonical(self.final_fd, expected_info, expected_resources)
        self._verify_published_identity()
        # Close every descriptor not needed for the final unlink of the now-empty
        # transaction directory. Until that unlink succeeds, any failure can still
        # move the owned destination back through transaction_fd and remove it.
        for descriptor_name in ("final_fd", "normalized_fd", "snapshot_fd", "source_fd"):
            self._close_descriptor(descriptor_name)
        with _blocked_transaction_signals():
            if _list_names(self.transaction_fd):
                _fail("transaction-workspace-not-empty")
            observed = _entry_metadata(self.destination_parent_fd, self.transaction_name)
            if (
                observed is None
                or self.transaction_identity is None
                or _identity(observed) != self.transaction_identity
            ):
                _fail("cleanup-identity-mismatch")
            try:
                os.rmdir(self.transaction_name, dir_fd=self.destination_parent_fd)
            except OSError:
                _fail("transaction-workspace-remove-failed")
            self.transaction_name = b""
            self.transaction_identity = None
            self._close_descriptor("transaction_fd")
            self.committed = True
        self._advance(Phase.COMMITTED)
        self._close_descriptor("destination_parent_fd")

    def _cleanup(self) -> None:
        with _blocked_transaction_signals():
            cleanup_error: Optional[BundleError] = None
            try:
                self._rollback_if_needed()
            except BundleError as error:
                cleanup_error = error
            except OSError:
                cleanup_error = BundleError("cleanup-failed")
            for descriptor_name in ("final_fd", "normalized_fd", "snapshot_fd", "transaction_fd"):
                try:
                    self._close_descriptor(descriptor_name)
                except OSError:
                    if cleanup_error is None:
                        cleanup_error = BundleError("cleanup-close-failed")
            if (
                self.transaction_name
                and self.transaction_identity is not None
                and self.destination_parent_fd >= 0
            ):
                try:
                    _remove_owned_tree(
                        self.destination_parent_fd,
                        self.transaction_name,
                        self.transaction_identity,
                    )
                except BundleError as error:
                    if cleanup_error is None:
                        cleanup_error = error
                except OSError:
                    if cleanup_error is None:
                        cleanup_error = BundleError("cleanup-failed")
            for descriptor_name in ("source_fd", "destination_parent_fd"):
                try:
                    self._close_descriptor(descriptor_name)
                except OSError:
                    if cleanup_error is None:
                        cleanup_error = BundleError("cleanup-close-failed")
            if cleanup_error is not None:
                raise cleanup_error

    def run(self) -> Layout:
        result: Optional[Layout] = None
        try:
            self._open_endpoints()
            self._create_workspace()
            source_before, snapshot = self._snapshot()
            layout = _detect_layout(self.snapshot_fd, snapshot)
            if layout.signed:
                signature_before = _scan_tree(self.snapshot_fd)
                self.platform.verify_codesign(self.snapshot_fd)
                signature_after = _scan_tree(self.snapshot_fd)
                if signature_before.stable != signature_after.stable:
                    _fail("snapshot-changed-during-signature-verification")
            verified_snapshot = _scan_tree(self.snapshot_fd)
            if source_before.content != verified_snapshot.content:
                _fail("snapshot-changed-before-normalization")
            self._advance(Phase.SNAPSHOT_VERIFIED)
            expected_info, expected_resources = self._build_normalized(layout)
            if verified_snapshot.stable != _scan_tree(self.snapshot_fd).stable:
                _fail("snapshot-changed-during-normalization")
            self._verify_canonical(self.normalized_fd, expected_info, expected_resources)
            self._advance(Phase.STAGED_VERIFIED)
            final_source = _scan_tree(self.source_fd)
            if source_before.stable != final_source.stable:
                _fail("source-resources-changed-before-publish")
            self._discard_snapshot_before_publish()
            self._publish(expected_info, expected_resources)
            result = layout.layout
            self._commit(expected_info, expected_resources)
            return result
        finally:
            if not self.committed:
                self._cleanup()


def _normalize_and_install(
    source: str,
    destination: str,
    *,
    platform: DarwinPlatform,
    observer: Optional[Observer],
) -> Layout:
    return BundleTransaction(source, destination, platform, observer).run()


def normalize_and_install(source: str, destination: str) -> Layout:
    return _normalize_and_install(
        source,
        destination,
        platform=DarwinPlatform(),
        observer=None,
    )


def _parse_arguments(argv: Sequence[str]) -> Tuple[str, str]:
    if len(argv) != 4:
        _fail("usage", 2)
    values: Dict[str, str] = {}
    for index in (0, 2):
        option = argv[index]
        value = argv[index + 1]
        if option not in ("--source-bundle", "--destination-bundle") or option in values or not value:
            _fail("usage", 2)
        values[option] = value
    if set(values) != {"--source-bundle", "--destination-bundle"}:
        _fail("usage", 2)
    return values["--source-bundle"], values["--destination-bundle"]


def _install_signal_handlers() -> Dict[int, object]:
    previous: Dict[int, object] = {}

    def interrupt(signum: int, _frame: object) -> None:
        raise SignalInterruption(signum)

    for signum in SIGNALS:
        previous[signum] = signal.getsignal(signum)
        signal.signal(signum, interrupt)
    return previous


def _restore_signal_handlers(previous: Dict[int, object]) -> None:
    for signum, handler in previous.items():
        signal.signal(signum, handler)


def main(argv: Sequence[str]) -> int:
    previous_handlers = _install_signal_handlers()
    try:
        source, destination = _parse_arguments(argv)
        layout = normalize_and_install(source, destination)
        sys.stdout.write(layout.value + "\n")
        return 0
    except SignalInterruption as interruption:
        return 128 + interruption.signum
    except BundleError as error:
        sys.stderr.write("skybridge-core-resource-bundle: reason=" + error.reason + "\n")
        return error.status
    except (OSError, ValueError, UnicodeError):
        sys.stderr.write("skybridge-core-resource-bundle: reason=unexpected-io-failure\n")
        return 1
    finally:
        _restore_signal_handlers(previous_handlers)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
