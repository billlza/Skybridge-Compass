#!/usr/bin/env python3
"""Create and verify deterministic provenance for checked-in native artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile
from typing import Any


SCHEMA_VERSION = 3
LOCK_SCHEMA_VERSION = 3
PROVENANCE_FIELDS = {
    "schema_version",
    "family",
    "native_dependency_lock",
    "sources",
    "build",
    "artifact_roots",
    "binaries",
}
BUILD_FIELDS = {
    "inputs",
    "recipe",
    "recipe_sha256",
    "recipe_inputs",
    "toolchain",
}
ARTIFACT_ROOT_FIELDS = {"path", "tree_sha256", "file_count"}
TOOLCHAIN_FIELDS = {"xcode", "macos_sdk", "clang", "cmake", "ninja"}
SOURCE_FIELDS = {
    "name",
    "version",
    "ref",
    "commit",
    "repository",
    "git_tree",
    "source_archive_sha256",
}


class ProvenanceError(RuntimeError):
    pass


def reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProvenanceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json_object(path: pathlib.Path, kind: str) -> dict[str, Any]:
    try:
        payload = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_json_keys,
        )
    except json.JSONDecodeError as error:
        raise ProvenanceError(f"invalid {kind} JSON: {error}") from error
    if not isinstance(payload, dict):
        raise ProvenanceError(f"{kind} root must be an object")
    return payload


def run(*args: str, cwd: pathlib.Path | None = None) -> str:
    completed = subprocess.run(
        args,
        cwd=cwd,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise ProvenanceError(f"command failed ({' '.join(args)}): {detail}")
    return completed.stdout.strip()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def locked_family_sha256(family: str, locked_family: dict[str, Any]) -> str:
    """Hash only the named family's canonical, security-relevant lock fields."""
    payload = {
        "lock_schema_version": LOCK_SCHEMA_VERSION,
        "family": family,
        "sources": locked_family["sources"],
        "build_inputs": locked_family["build_inputs"],
        "recipe_inputs": locked_family["recipe_inputs"],
        "toolchain": locked_family["toolchain"],
    }
    canonical = json.dumps(
        payload,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def tree_digest(path: pathlib.Path) -> tuple[str, int]:
    if not path.is_dir() or path.is_symlink():
        raise ProvenanceError(f"artifact root must be a real directory: {path}")
    digest = hashlib.sha256()
    count = 0
    for candidate in sorted(path.rglob("*"), key=lambda item: item.as_posix()):
        if candidate.is_symlink():
            raise ProvenanceError(f"symlinks are forbidden in native artifacts: {candidate}")
        if not candidate.is_file():
            continue
        relative = candidate.relative_to(path).as_posix()
        file_digest = sha256_file(candidate)
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(candidate.stat().st_mode & 0o777).encode("ascii"))
        digest.update(b"\0")
        digest.update(str(candidate.stat().st_size).encode("ascii"))
        digest.update(b"\0")
        digest.update(file_digest.encode("ascii"))
        digest.update(b"\n")
        count += 1
    if count == 0:
        raise ProvenanceError(f"artifact root contains no files: {path}")
    return digest.hexdigest(), count


def parse_key_value(raw: str, kind: str) -> tuple[str, str]:
    key, separator, value = raw.partition("=")
    if not separator or not key or not value:
        raise ProvenanceError(f"invalid {kind}, expected key=value: {raw}")
    return key, value


def parse_source(raw: str) -> dict[str, str]:
    fields = raw.split("|", 5)
    if len(fields) != 6 or any(not field for field in fields):
        raise ProvenanceError(
            "invalid source spec; expected name|version|ref|commit|repository|checkout"
        )
    name, version, ref, expected_commit, repository, checkout_raw = fields
    checkout = pathlib.Path(checkout_raw).resolve()
    if not (checkout / ".git").is_dir():
        raise ProvenanceError(f"source checkout is not a Git repository: {checkout}")
    actual_commit = run("git", "rev-parse", "HEAD", cwd=checkout)
    if actual_commit != expected_commit:
        raise ProvenanceError(
            f"{name} source commit mismatch: expected {expected_commit}, got {actual_commit}"
        )
    if run("git", "status", "--porcelain=v1", "--untracked-files=all", cwd=checkout):
        raise ProvenanceError(f"{name} source checkout is dirty: {checkout}")
    remote = run("git", "remote", "get-url", "origin", cwd=checkout)
    if remote.rstrip("/") != repository.rstrip("/"):
        raise ProvenanceError(
            f"{name} source remote mismatch: expected {repository}, got {remote}"
        )
    archive = subprocess.run(
        ["git", "archive", "--format=tar", "HEAD"],
        cwd=checkout,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if archive.returncode != 0:
        raise ProvenanceError(
            f"failed to archive {name} source: {archive.stderr.decode('utf-8', 'replace').strip()}"
        )
    return {
        "name": name,
        "version": version,
        "ref": ref,
        "commit": actual_commit,
        "repository": repository,
        "git_tree": run("git", "rev-parse", "HEAD^{tree}", cwd=checkout),
        "source_archive_sha256": hashlib.sha256(archive.stdout).hexdigest(),
    }


def source_lock_fields(source: Any, kind: str) -> dict[str, str]:
    if not isinstance(source, dict):
        raise ProvenanceError(f"invalid {kind} source record")
    if set(source) != SOURCE_FIELDS:
        raise ProvenanceError(f"{kind} source fields differ from the exact schema")
    result: dict[str, str] = {}
    for field in SOURCE_FIELDS:
        value = source.get(field)
        if not isinstance(value, str) or not value:
            raise ProvenanceError(f"invalid {kind} source field: {field}")
        result[field] = value
    if not re.fullmatch(r"[0-9a-f]{40}", result["commit"]):
        raise ProvenanceError(f"invalid {kind} source commit: {result['name']}")
    if not re.fullmatch(r"[0-9a-f]{40}", result["git_tree"]):
        raise ProvenanceError(f"invalid {kind} source Git tree: {result['name']}")
    if not re.fullmatch(r"[0-9a-f]{64}", result["source_archive_sha256"]):
        raise ProvenanceError(f"invalid {kind} source archive SHA-256: {result['name']}")
    return result


def validate_provenance_source_details(sources: list[Any]) -> None:
    for source in sources:
        if not isinstance(source, dict) or set(source) != SOURCE_FIELDS:
            raise ProvenanceError("provenance source fields differ from the exact schema")
        git_tree = source["git_tree"]
        archive_sha256 = source["source_archive_sha256"]
        if not isinstance(git_tree, str) or not re.fullmatch(r"[0-9a-f]{40}", git_tree):
            raise ProvenanceError(f"invalid source Git tree: {source.get('name')}")
        if not isinstance(archive_sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", archive_sha256
        ):
            raise ProvenanceError(f"invalid source archive SHA-256: {source.get('name')}")


def validated_toolchain(value: Any, kind: str) -> dict[str, str]:
    if not isinstance(value, dict) or set(value) != TOOLCHAIN_FIELDS:
        raise ProvenanceError(f"{kind} toolchain fields differ from the exact schema")
    normalized: dict[str, str] = {}
    for key in sorted(TOOLCHAIN_FIELDS):
        item = value.get(key)
        if not isinstance(item, str) or not item.strip():
            raise ProvenanceError(f"invalid {kind} toolchain field: {key}")
        normalized[key] = item
    return normalized


def load_locked_family(
    lock_path: pathlib.Path, repository_root: pathlib.Path, family: str
) -> tuple[dict[str, Any], dict[str, str]]:
    unresolved_repository_root = pathlib.Path(os.path.abspath(repository_root))
    repository_root = unresolved_repository_root.resolve()
    unresolved_lock = pathlib.Path(os.path.abspath(lock_path))
    lock_relative_path: pathlib.Path | None = None
    for candidate_root in (unresolved_repository_root, repository_root):
        try:
            lock_relative_path = unresolved_lock.relative_to(candidate_root)
            break
        except ValueError:
            continue
    if lock_relative_path is None:
        raise ProvenanceError(
            "native dependency lock is outside repository root"
        )
    resolved_lock = safe_repository_path(
        lock_relative_path.as_posix(), repository_root, "native dependency lock"
    )
    if not resolved_lock.is_file():
        raise ProvenanceError("native dependency lock is not a regular repository file")
    lock_relative = lock_relative_path.as_posix()
    lock = read_json_object(resolved_lock, "native dependency lock")
    if set(lock) != {"schema_version", "families"}:
        raise ProvenanceError("native dependency lock fields differ from the exact schema")
    if lock.get("schema_version") != LOCK_SCHEMA_VERSION:
        raise ProvenanceError(
            f"unsupported native dependency lock schema: {lock.get('schema_version')}"
        )
    families = lock.get("families")
    if not isinstance(families, dict) or family not in families:
        raise ProvenanceError(f"native dependency family is not locked: {family}")
    locked_family = families[family]
    if not isinstance(locked_family, dict):
        raise ProvenanceError(f"invalid native dependency family lock: {family}")
    if set(locked_family) != {
        "sources",
        "build_inputs",
        "recipe_inputs",
        "toolchain",
    }:
        raise ProvenanceError(
            f"native dependency family fields differ from the exact schema: {family}"
        )
    sources = locked_family.get("sources")
    if not isinstance(sources, list) or not sources:
        raise ProvenanceError(f"native dependency family has no locked sources: {family}")
    normalized_sources = [
        source_lock_fields(source, "locked") for source in sources
    ]
    if len({source["name"] for source in normalized_sources}) != len(normalized_sources):
        raise ProvenanceError(f"native dependency family has duplicate source names: {family}")
    build_inputs = locked_family.get("build_inputs")
    if not isinstance(build_inputs, dict):
        raise ProvenanceError(f"native dependency family has no locked build inputs: {family}")
    normalized_inputs: dict[str, str] = {}
    for key, value in build_inputs.items():
        if not isinstance(key, str) or not key or not isinstance(value, str) or not value:
            raise ProvenanceError(f"invalid locked build input for {family}: {key}")
        normalized_inputs[key] = value
    recipe_inputs = locked_family.get("recipe_inputs")
    if not isinstance(recipe_inputs, dict) or not recipe_inputs:
        raise ProvenanceError(
            f"native dependency family has no locked recipe inputs: {family}"
        )
    normalized_recipe_inputs: dict[str, str] = {}
    for raw_path, expected_sha256 in recipe_inputs.items():
        if not isinstance(raw_path, str) or not raw_path:
            raise ProvenanceError(f"invalid locked recipe input path for {family}")
        if not isinstance(expected_sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", expected_sha256
        ):
            raise ProvenanceError(
                f"invalid locked recipe input SHA-256 for {family}: {raw_path}"
            )
        input_path = safe_repository_path(
            raw_path, repository_root, "native build recipe input"
        )
        if not input_path.is_file() or input_path.is_symlink():
            raise ProvenanceError(
                f"native build recipe input is not a regular repository file: {raw_path}"
            )
        if sha256_file(input_path) != expected_sha256:
            raise ProvenanceError(
                f"native build recipe input differs from lock: {raw_path}"
            )
        normalized_recipe_inputs[raw_path] = expected_sha256
    normalized_family = {
        "sources": normalized_sources,
        "build_inputs": dict(sorted(normalized_inputs.items())),
        "recipe_inputs": dict(sorted(normalized_recipe_inputs.items())),
        "toolchain": validated_toolchain(locked_family.get("toolchain"), "locked"),
    }
    return (
        normalized_family,
        {
            "path": lock_relative,
            "schema_version": LOCK_SCHEMA_VERSION,
            "family": family,
            "family_sha256": locked_family_sha256(family, normalized_family),
        },
    )


def assert_matches_locked_family(
    family: str,
    sources: Any,
    build_inputs: Any,
    recipe_inputs: Any,
    toolchain: Any,
    locked_family: dict[str, Any],
) -> None:
    if not isinstance(family, str) or not family:
        raise ProvenanceError("native provenance family must be a non-empty string")
    if not isinstance(sources, list):
        raise ProvenanceError("native provenance sources must be an array")
    actual_sources = [source_lock_fields(source, "provenance") for source in sources]
    if actual_sources != locked_family["sources"]:
        raise ProvenanceError(
            f"{family} sources differ from the native dependency lock"
        )
    if not isinstance(build_inputs, dict):
        raise ProvenanceError("native provenance build inputs must be an object")
    actual_inputs: dict[str, str] = {}
    for key, value in build_inputs.items():
        if not isinstance(key, str) or not key or not isinstance(value, str) or not value:
            raise ProvenanceError(f"invalid provenance build input: {key}")
        actual_inputs[key] = value
    if dict(sorted(actual_inputs.items())) != locked_family["build_inputs"]:
        raise ProvenanceError(
            f"{family} build inputs differ from the native dependency lock"
        )
    if recipe_inputs != locked_family["recipe_inputs"]:
        raise ProvenanceError(
            f"{family} recipe inputs differ from the native dependency lock"
        )
    actual_toolchain = validated_toolchain(toolchain, "provenance")
    if actual_toolchain != locked_family["toolchain"]:
        raise ProvenanceError(
            f"{family} toolchain differs from the native dependency lock"
        )


def relative_to_repository(path: pathlib.Path, repository_root: pathlib.Path) -> str:
    repository_root = repository_root.resolve()
    try:
        return path.resolve().relative_to(repository_root).as_posix()
    except ValueError as error:
        raise ProvenanceError(f"path is outside repository root: {path}") from error


def safe_repository_path(raw: Any, repository_root: pathlib.Path, kind: str) -> pathlib.Path:
    repository_root = repository_root.resolve()
    if not isinstance(raw, str) or not raw:
        raise ProvenanceError(f"invalid {kind} path in provenance")
    relative = pathlib.PurePosixPath(raw)
    if relative.is_absolute() or ".." in relative.parts:
        raise ProvenanceError(f"unsafe {kind} path in provenance: {raw}")
    unresolved_candidate = repository_root / pathlib.Path(*relative.parts)
    current = repository_root
    for component in relative.parts:
        current /= component
        if current.is_symlink():
            raise ProvenanceError(
                f"symlinks are forbidden in native provenance paths: {raw}"
            )
    candidate = unresolved_candidate.resolve()
    try:
        candidate.relative_to(repository_root)
    except ValueError as error:
        raise ProvenanceError(f"{kind} path escapes repository root: {raw}") from error
    return candidate


def mach_o_minos(path: pathlib.Path) -> list[str]:
    output = run("otool", "-l", str(path))
    values: list[str] = []
    lines = output.splitlines()
    for index, line in enumerate(lines):
        if line.strip() not in {"cmd LC_BUILD_VERSION", "cmd LC_VERSION_MIN_MACOSX"}:
            continue
        for candidate in lines[index + 1 : index + 10]:
            match = re.match(r"\s*(?:minos|version)\s+([^\s]+)", candidate)
            if match:
                if match.group(1) not in values:
                    values.append(match.group(1))
                break
    if not values:
        raise ProvenanceError(f"could not read deployment target from Mach-O: {path}")
    return values


def mach_o_platforms(path: pathlib.Path) -> list[str]:
    platform_names = {
        "1": "macos",
        "2": "ios",
        "3": "tvos",
        "4": "watchos",
        "5": "bridgeos",
        "6": "maccatalyst",
        "7": "ios-simulator",
        "8": "tvos-simulator",
        "9": "watchos-simulator",
        "10": "driverkit",
        "11": "visionos",
        "12": "visionos-simulator",
    }
    output = run("otool", "-l", str(path))
    values: list[str] = []
    lines = output.splitlines()
    for index, line in enumerate(lines):
        if line.strip() != "cmd LC_BUILD_VERSION":
            continue
        for candidate in lines[index + 1 : index + 10]:
            match = re.match(r"\s*platform\s+([^\s]+)", candidate)
            if match:
                value = platform_names.get(match.group(1), match.group(1))
                if value not in values:
                    values.append(value)
                break
    if not values:
        raise ProvenanceError(f"could not read platform from Mach-O: {path}")
    return values


def dylib_metadata(
    path: pathlib.Path, repository_root: pathlib.Path, recorded_path: str | None = None
) -> dict[str, Any]:
    load_lines = run("otool", "-L", str(path)).splitlines()[1:]
    dependencies = [line.strip().split(" ", 1)[0] for line in load_lines if line.strip()]
    identifier_lines = run("otool", "-D", str(path)).splitlines()[1:]
    identifiers = [line.strip() for line in identifier_lines if line.strip()]
    if len(identifiers) != 1:
        raise ProvenanceError(f"expected exactly one dylib install name: {path}")
    return {
        "path": recorded_path or relative_to_repository(path, repository_root),
        "size": path.stat().st_size,
        "sha256": sha256_file(path),
        "architectures": run("lipo", "-archs", str(path)).split(),
        "platforms": mach_o_platforms(path),
        "deployment_targets": mach_o_minos(path),
        "install_name": identifiers[0],
        "dependencies": dependencies,
    }


def archive_metadata(
    path: pathlib.Path, repository_root: pathlib.Path, recorded_path: str | None = None
) -> dict[str, Any]:
    return {
        "path": recorded_path or relative_to_repository(path, repository_root),
        "size": path.stat().st_size,
        "sha256": sha256_file(path),
        "architectures": run("lipo", "-archs", str(path)).split(),
        "platforms": mach_o_platforms(path),
        "deployment_targets": mach_o_minos(path),
    }


def toolchain_record() -> dict[str, str]:
    return {
        "xcode": run("xcodebuild", "-version").replace("\n", "; "),
        "macos_sdk": run("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "clang": run("xcrun", "clang", "--version").splitlines()[0],
        "cmake": run("cmake", "--version").splitlines()[0],
        "ninja": run("ninja", "--version"),
    }


def create_record(args: argparse.Namespace) -> dict[str, Any]:
    repository_root = pathlib.Path(args.repository_root).resolve()
    sources = [parse_source(item) for item in args.source]
    build_inputs = dict(parse_key_value(item, "build input") for item in args.build_input)
    if len(build_inputs) != len(args.build_input):
        raise ProvenanceError("duplicate build input")
    locked_family, lock_record = load_locked_family(
        pathlib.Path(args.lock), repository_root, args.family
    )
    toolchain = toolchain_record()
    assert_matches_locked_family(
        args.family,
        sources,
        build_inputs,
        locked_family["recipe_inputs"],
        toolchain,
        locked_family,
    )
    roots: dict[str, Any] = {}
    binaries: list[dict[str, Any]] = []
    for raw in args.artifact_root:
        fields = raw.split("|", 2)
        if len(fields) not in {2, 3} or any(not field for field in fields):
            raise ProvenanceError(
                "invalid artifact root; expected label|physical-path[|repository-relative-path]"
            )
        label, path_raw = fields[:2]
        if label in roots:
            raise ProvenanceError(f"duplicate artifact root label: {label}")
        path = pathlib.Path(path_raw).resolve()
        relative = (
            fields[2]
            if len(fields) == 3
            else relative_to_repository(path, repository_root)
        )
        if pathlib.PurePosixPath(relative).is_absolute() or ".." in pathlib.PurePosixPath(relative).parts:
            raise ProvenanceError(f"invalid repository-relative artifact path: {relative}")
        digest, file_count = tree_digest(path)
        roots[label] = {
            "path": relative,
            "tree_sha256": digest,
            "file_count": file_count,
        }
        for candidate in sorted(path.rglob("*"), key=lambda item: item.as_posix()):
            if not candidate.is_file():
                continue
            recorded_path = (
                pathlib.PurePosixPath(relative) / candidate.relative_to(path).as_posix()
            ).as_posix()
            if candidate.suffix == ".dylib":
                binaries.append(dylib_metadata(candidate, repository_root, recorded_path))
            elif candidate.suffix == ".a":
                binaries.append(archive_metadata(candidate, repository_root, recorded_path))
    recipe_path = pathlib.Path(args.recipe).resolve()
    return {
        "schema_version": SCHEMA_VERSION,
        "family": args.family,
        "native_dependency_lock": lock_record,
        "sources": sources,
        "build": {
            "inputs": dict(sorted(build_inputs.items())),
            "recipe": relative_to_repository(recipe_path, repository_root),
            "recipe_sha256": sha256_file(recipe_path),
            "recipe_inputs": locked_family["recipe_inputs"],
            "toolchain": toolchain,
        },
        "artifact_roots": dict(sorted(roots.items())),
        "binaries": sorted(binaries, key=lambda item: item["path"]),
    }


def write_atomic_json(path: pathlib.Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(record, indent=2, sort_keys=True, ensure_ascii=True) + "\n"
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def verify_record(
    path: pathlib.Path, repository_root: pathlib.Path, lock_path: pathlib.Path
) -> None:
    unresolved_repository_root = pathlib.Path(os.path.abspath(repository_root))
    repository_root = unresolved_repository_root.resolve()
    unresolved_provenance_path = pathlib.Path(os.path.abspath(path))
    provenance_relative: pathlib.Path | None = None
    for candidate_root in (unresolved_repository_root, repository_root):
        try:
            provenance_relative = unresolved_provenance_path.relative_to(candidate_root)
            break
        except ValueError:
            continue
    if provenance_relative is None:
        raise ProvenanceError(
            "native provenance path is outside repository root"
        )
    provenance_path = safe_repository_path(
        provenance_relative.as_posix(), repository_root, "native provenance"
    )
    if not provenance_path.is_file():
        raise ProvenanceError("native provenance is not a regular repository file")
    record = read_json_object(provenance_path, "native provenance")
    if record.get("schema_version") != SCHEMA_VERSION:
        raise ProvenanceError(f"unsupported provenance schema: {record.get('schema_version')}")
    if set(record) != PROVENANCE_FIELDS:
        raise ProvenanceError("native provenance fields differ from the exact schema")
    family = record.get("family")
    if not isinstance(family, str) or not family:
        raise ProvenanceError("native provenance has no family")
    locked_family, expected_lock_record = load_locked_family(
        lock_path, unresolved_repository_root, family
    )
    if record.get("native_dependency_lock") != expected_lock_record:
        raise ProvenanceError(
            "native dependency lock path, schema, family, or family SHA-256 differs "
            "from provenance"
        )
    build = record.get("build")
    if not isinstance(build, dict) or set(build) != BUILD_FIELDS:
        if isinstance(build, dict):
            raise ProvenanceError("native provenance build fields differ from the exact schema")
        raise ProvenanceError("native provenance has no build record")
    assert_matches_locked_family(
        family,
        record.get("sources"),
        build.get("inputs"),
        build.get("recipe_inputs"),
        build.get("toolchain"),
        locked_family,
    )
    validate_provenance_source_details(record["sources"])
    artifact_roots = record.get("artifact_roots")
    if not isinstance(artifact_roots, dict) or not artifact_roots:
        raise ProvenanceError("native provenance has no artifact roots")
    expected_binary_paths: set[str] = set()
    for label, root in artifact_roots.items():
        if not isinstance(label, str) or not label or not isinstance(root, dict):
            raise ProvenanceError("invalid artifact root record")
        if set(root) != ARTIFACT_ROOT_FIELDS:
            raise ProvenanceError("artifact root fields differ from the exact schema")
        if not isinstance(root.get("tree_sha256"), str) or not re.fullmatch(
            r"[0-9a-f]{64}", root["tree_sha256"]
        ):
            raise ProvenanceError(f"invalid artifact tree SHA-256: {label}")
        if (
            not isinstance(root.get("file_count"), int)
            or isinstance(root.get("file_count"), bool)
            or root["file_count"] <= 0
        ):
            raise ProvenanceError(f"invalid artifact file count: {label}")
        artifact_path = safe_repository_path(root.get("path"), repository_root, "artifact")
        digest, file_count = tree_digest(artifact_path)
        if digest != root.get("tree_sha256") or file_count != root.get("file_count"):
            raise ProvenanceError(f"artifact tree differs from provenance: {label}")
        for candidate in artifact_path.rglob("*"):
            if candidate.is_file() and candidate.suffix in {".a", ".dylib"}:
                expected_binary_paths.add(
                    (
                        pathlib.PurePosixPath(root["path"])
                        / candidate.relative_to(artifact_path).as_posix()
                    ).as_posix()
                )
    binaries = record.get("binaries")
    if not isinstance(binaries, list) or not binaries:
        raise ProvenanceError("native provenance has no binaries")
    seen_binary_paths: set[str] = set()
    for binary in binaries:
        if not isinstance(binary, dict) or not isinstance(binary.get("path"), str):
            raise ProvenanceError("invalid native binary record")
        if binary["path"] in seen_binary_paths:
            raise ProvenanceError(f"duplicate native binary record: {binary['path']}")
        seen_binary_paths.add(binary["path"])
        binary_path = safe_repository_path(binary["path"], repository_root, "binary")
        if not binary_path.is_file() or binary_path.is_symlink():
            raise ProvenanceError(f"missing native binary: {binary['path']}")
        if binary_path.suffix not in {".a", ".dylib"}:
            raise ProvenanceError(f"unsupported native binary type: {binary['path']}")
        actual = (
            dylib_metadata(binary_path, repository_root)
            if binary_path.suffix == ".dylib"
            else archive_metadata(binary_path, repository_root)
        )
        if actual != binary:
            raise ProvenanceError(f"native binary differs from provenance: {binary['path']}")
    if seen_binary_paths != expected_binary_paths:
        raise ProvenanceError("native binary records differ from artifact tree binaries")
    recipe = safe_repository_path(build.get("recipe"), repository_root, "recipe")
    if not recipe.is_file() or recipe.is_symlink():
        raise ProvenanceError("native build recipe is not a regular repository file")
    recipe_sha256 = build.get("recipe_sha256")
    if not isinstance(recipe_sha256, str) or not re.fullmatch(
        r"[0-9a-f]{64}", recipe_sha256
    ):
        raise ProvenanceError("invalid native build recipe SHA-256")
    if sha256_file(recipe) != recipe_sha256:
        raise ProvenanceError("native build recipe differs from provenance")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create")
    create.add_argument("--family", required=True)
    create.add_argument("--lock", required=True)
    create.add_argument("--repository-root", required=True)
    create.add_argument("--recipe", required=True)
    create.add_argument("--output", required=True)
    create.add_argument("--artifact-root", action="append", default=[], required=True)
    create.add_argument("--source", action="append", default=[], required=True)
    create.add_argument("--build-input", action="append", default=[])

    verify = subparsers.add_parser("verify")
    verify.add_argument("--lock", required=True)
    verify.add_argument("--repository-root", required=True)
    verify.add_argument("--provenance", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "create":
            record = create_record(args)
            write_atomic_json(pathlib.Path(args.output), record)
        else:
            verify_record(
                pathlib.Path(args.provenance),
                pathlib.Path(args.repository_root).resolve(),
                pathlib.Path(args.lock),
            )
    except (OSError, ValueError, KeyError, json.JSONDecodeError, ProvenanceError) as error:
        print(f"native vendor provenance error: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
