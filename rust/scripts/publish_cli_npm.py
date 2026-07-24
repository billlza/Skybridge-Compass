#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from typing import Any

from finalize_cli_release_assets import PLATFORM_ASSETS, maximum_size, regular_file, sha256


PACKAGE_NAME = "skybridge-cli"
REGISTRY = "https://registry.npmjs.org"
REQUIRED_NODE_VERSION = (24, 18, 0)
REQUIRED_NPM_VERSION = (11, 16, 0)
MAX_PACKAGE_BYTES = 64 * 1024 * 1024
MAX_MEMBER_BYTES = 32 * 1024 * 1024
MAX_MEMBER_COUNT = 1_000
EXPECTED_PACKAGE_MEMBERS = {
    "package/README.md",
    "package/bin/skybridge.js",
    "package/lib/install.js",
    "package/lib/platform.js",
    "package/package.json",
    "package/release-assets.json",
}
VERSION_RE = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)
REPOSITORY_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
_NPM_WORK_DIRECTORY: pathlib.Path | None = None
_NPM_ENVIRONMENT: dict[str, str] | None = None


class PublicationError(RuntimeError):
    pass


def run_process(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        cwd=_NPM_WORK_DIRECTORY,
        env=_NPM_ENVIRONMENT,
    )


@contextlib.contextmanager
def isolated_npm_runtime() -> Any:
    global _NPM_ENVIRONMENT, _NPM_WORK_DIRECTORY
    previous_directory = _NPM_WORK_DIRECTORY
    previous_environment = _NPM_ENVIRONMENT
    with tempfile.TemporaryDirectory(prefix="skybridge-cli-npm-publisher.") as temporary:
        root = pathlib.Path(temporary)
        user_config = root / "user.npmrc"
        global_config = root / "global.npmrc"
        user_config.write_text(f"registry={REGISTRY}\nignore-scripts=true\n", encoding="utf-8")
        global_config.write_text("", encoding="utf-8")
        os.chmod(user_config, 0o600)
        os.chmod(global_config, 0o600)
        environment = os.environ.copy()
        environment["NPM_CONFIG_USERCONFIG"] = os.fspath(user_config)
        environment["NPM_CONFIG_GLOBALCONFIG"] = os.fspath(global_config)
        environment["NPM_CONFIG_CACHE"] = os.fspath(root / "cache")
        environment["NPM_CONFIG_IGNORE_SCRIPTS"] = "true"
        environment["NPM_CONFIG_PROVENANCE"] = "true"
        _NPM_WORK_DIRECTORY = root
        _NPM_ENVIRONMENT = environment
        try:
            yield
        finally:
            _NPM_WORK_DIRECTORY = previous_directory
            _NPM_ENVIRONMENT = previous_environment


def load_json_exact(raw: str, *, description: str) -> Any:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise PublicationError(f"duplicate JSON key in {description}: {key}")
            result[key] = value
        return result

    try:
        return json.loads(raw, object_pairs_hook=reject_duplicates)
    except json.JSONDecodeError as error:
        raise PublicationError(f"invalid JSON in {description}") from error


def regular_package(path: pathlib.Path) -> os.stat_result:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise PublicationError(f"npm package does not exist: {path}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise PublicationError("npm package must be a regular file, not a link or special file")
    if metadata.st_nlink != 1:
        raise PublicationError("npm package must not be hard-linked")
    if metadata.st_size <= 0 or metadata.st_size > MAX_PACKAGE_BYTES:
        raise PublicationError("npm package size is outside the release contract")
    return metadata


def validate_version(version: str) -> None:
    if VERSION_RE.fullmatch(version) is None:
        raise PublicationError(f"invalid npm package version: {version!r}")


def validate_repository(repository: str) -> None:
    if REPOSITORY_RE.fullmatch(repository) is None or ".." in repository:
        raise PublicationError(f"invalid source repository: {repository!r}")


def validate_package(
    package_path: pathlib.Path,
    *,
    version: str,
    source_repository: str,
    source_sha: str,
    native_assets_dir: pathlib.Path,
) -> dict[str, Any]:
    regular_package(package_path)
    expected_name = f"{PACKAGE_NAME}-{version}.tgz"
    if package_path.name != expected_name:
        raise PublicationError(f"npm package must use the canonical name {expected_name}")

    seen: set[str] = set()
    package_json_bytes: bytes | None = None
    release_assets_bytes: bytes | None = None
    total_size = 0
    try:
        with tarfile.open(package_path, mode="r:gz") as archive:
            for member in archive:
                name = member.name
                normalized = pathlib.PurePosixPath(name)
                if (
                    normalized.is_absolute()
                    or ".." in normalized.parts
                    or not name.startswith("package/")
                    or normalized.as_posix() != name
                ):
                    raise PublicationError(f"unsafe npm tarball member: {name}")
                if name in seen:
                    raise PublicationError(f"duplicate npm tarball member: {name}")
                if not member.isreg() or member.issym() or member.islnk():
                    raise PublicationError(f"npm tarball member must be a regular file: {name}")
                if member.size <= 0 or member.size > MAX_MEMBER_BYTES:
                    raise PublicationError(f"npm tarball member has an invalid size: {name}")
                total_size += member.size
                if total_size > MAX_PACKAGE_BYTES:
                    raise PublicationError("npm tarball expands beyond the release size limit")
                seen.add(name)
                if len(seen) > MAX_MEMBER_COUNT:
                    raise PublicationError("npm tarball contains too many files")
                if name == "package/package.json":
                    stream = archive.extractfile(member)
                    if stream is None:
                        raise PublicationError("unable to read package/package.json")
                    package_json_bytes = stream.read(MAX_MEMBER_BYTES + 1)
                elif name == "package/release-assets.json":
                    stream = archive.extractfile(member)
                    if stream is None:
                        raise PublicationError("unable to read package/release-assets.json")
                    release_assets_bytes = stream.read(MAX_MEMBER_BYTES + 1)
    except (tarfile.TarError, OSError) as error:
        raise PublicationError("unable to read npm package tarball") from error

    if package_json_bytes is None:
        raise PublicationError("npm package is missing package/package.json")
    if release_assets_bytes is None:
        raise PublicationError("npm package is missing package/release-assets.json")
    if seen != EXPECTED_PACKAGE_MEMBERS:
        missing = ", ".join(sorted(EXPECTED_PACKAGE_MEMBERS - seen))
        extra = ", ".join(sorted(seen - EXPECTED_PACKAGE_MEMBERS))
        raise PublicationError(
            f"npm package file set differs from the reviewed contract; missing=[{missing}] extra=[{extra}]"
        )
    try:
        package_json_text = package_json_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PublicationError("package/package.json must be UTF-8") from error
    package_json = load_json_exact(package_json_text, description="package/package.json")
    if not isinstance(package_json, dict):
        raise PublicationError("package/package.json must contain one object")
    if package_json.get("name") != PACKAGE_NAME or package_json.get("version") != version:
        raise PublicationError("npm package identity does not match the requested name and version")
    if package_json.get("gitHead") != source_sha:
        raise PublicationError("npm package gitHead does not match the approved source SHA")
    expected_repository = f"https://github.com/{source_repository}.git"
    repository = package_json.get("repository")
    if not isinstance(repository, dict) or repository.get("url") != expected_repository:
        raise PublicationError("npm package repository URL does not match the source repository")
    scripts = package_json.get("scripts")
    expected_scripts = {"postinstall": "node ./lib/install.js"}
    if scripts != expected_scripts:
        raise PublicationError("npm package lifecycle scripts differ from the reviewed contract")
    if "publishConfig" in package_json:
        raise PublicationError("npm package must not override the reviewed registry or publish settings")
    if package_json.get("private") is True:
        raise PublicationError("npm package must not be marked private")
    expected_fields = {
        "description": "SkyBridge CLI npm wrapper for immutable Rust release binaries",
        "license": "MIT",
        "homepage": f"https://github.com/{source_repository}",
        "bin": {"skybridge": "bin/skybridge.js"},
        "files": ["bin", "dist", "lib", "README.md", "release-assets.json"],
        "engines": {"node": ">=22.14.0"},
        "os": ["darwin", "linux", "win32"],
        "cpu": ["arm64", "x64"],
    }
    for field, expected in expected_fields.items():
        if package_json.get(field) != expected:
            raise PublicationError(f"npm package field differs from the reviewed contract: {field}")
    try:
        release_assets_text = release_assets_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PublicationError("package/release-assets.json must be UTF-8") from error
    release_assets = load_json_exact(
        release_assets_text,
        description="package/release-assets.json",
    )
    expected_assets: list[dict[str, object]] = []
    for name, _, _ in PLATFORM_ASSETS:
        path = native_assets_dir / name
        metadata = regular_file(path, maximum_bytes=maximum_size(name))
        expected_assets.append(
            {
                "name": name,
                "sha256": sha256(path),
                "sizeBytes": metadata.st_size,
            }
        )
    expected_release_assets = {
        "schemaVersion": 1,
        "version": version,
        "sourceSha": source_sha,
        "assets": expected_assets,
    }
    if release_assets != expected_release_assets:
        raise PublicationError("embedded npm release asset hashes do not match the native archives")
    return package_json


def version_tuple(command: str) -> tuple[int, int, int]:
    completed = run_process([command, "--version"])
    if completed.returncode != 0:
        raise PublicationError(f"unable to execute {command} --version: {completed.stderr.strip()}")
    raw = completed.stdout.strip().removeprefix("v")
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:[-+].*)?", raw)
    if match is None:
        raise PublicationError(f"unable to parse {command} version: {raw!r}")
    return tuple(int(part) for part in match.groups())


def package_digests(path: pathlib.Path) -> tuple[str, str]:
    sha512 = hashlib.sha512()
    sha1 = hashlib.sha1(usedforsecurity=False)
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            sha512.update(chunk)
            sha1.update(chunk)
    integrity = "sha512-" + base64.b64encode(sha512.digest()).decode("ascii")
    return integrity, sha1.hexdigest()


def npm_view(version: str) -> dict[str, Any] | None:
    completed = run_process(
        [
            "npm",
            "view",
            f"{PACKAGE_NAME}@{version}",
            "dist",
            "--json",
            "--registry",
            REGISTRY,
        ]
    )
    if completed.returncode == 0:
        value = load_json_exact(completed.stdout, description="npm registry metadata")
        if not isinstance(value, dict):
            raise PublicationError("npm registry returned a non-object dist record")
        return value
    combined = f"{completed.stdout}\n{completed.stderr}"
    if "E404" in combined and "Not Found" in combined:
        return None
    raise PublicationError(f"npm registry query failed:\n{combined.strip()}")


def npm_dist_tags() -> dict[str, str] | None:
    completed = run_process(
        ["npm", "view", PACKAGE_NAME, "dist-tags", "--json", "--registry", REGISTRY]
    )
    if completed.returncode == 0:
        value = load_json_exact(completed.stdout, description="npm dist-tags metadata")
        if not isinstance(value, dict) or not all(
            isinstance(key, str) and isinstance(item, str) for key, item in value.items()
        ):
            raise PublicationError("npm registry returned an invalid dist-tags record")
        return value
    combined = f"{completed.stdout}\n{completed.stderr}"
    if "E404" in combined and "Not Found" in combined:
        return None
    raise PublicationError(f"npm dist-tags query failed:\n{combined.strip()}")


def parse_semver(version: str) -> tuple[tuple[int, int, int], tuple[str, ...] | None]:
    validate_version(version)
    core_and_pre = version.split("-", 1)
    core = tuple(int(part) for part in core_and_pre[0].split("."))
    prerelease = tuple(core_and_pre[1].split(".")) if len(core_and_pre) == 2 else None
    return (core[0], core[1], core[2]), prerelease


def compare_semver(left: str, right: str) -> int:
    left_core, left_pre = parse_semver(left)
    right_core, right_pre = parse_semver(right)
    if left_core != right_core:
        return (left_core > right_core) - (left_core < right_core)
    if left_pre is None or right_pre is None:
        if left_pre is None and right_pre is None:
            return 0
        return 1 if left_pre is None else -1
    for left_item, right_item in zip(left_pre, right_pre):
        if left_item == right_item:
            continue
        left_numeric = left_item.isdigit()
        right_numeric = right_item.isdigit()
        if left_numeric and right_numeric:
            return (int(left_item) > int(right_item)) - (int(left_item) < int(right_item))
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return (left_item > right_item) - (left_item < right_item)
    return (len(left_pre) > len(right_pre)) - (len(left_pre) < len(right_pre))


def verify_remote(
    metadata: dict[str, Any] | None,
    *,
    expected_integrity: str,
    expected_shasum: str,
) -> dict[str, Any]:
    if metadata is None:
        raise PublicationError("npm version is not visible in the registry")
    if metadata.get("integrity") != expected_integrity or metadata.get("shasum") != expected_shasum:
        raise PublicationError("published npm bytes do not match the approved tarball")
    attestations = metadata.get("attestations")
    provenance = attestations.get("provenance") if isinstance(attestations, dict) else None
    if (
        not isinstance(attestations, dict)
        or not isinstance(attestations.get("url"), str)
        or not attestations["url"].startswith(f"{REGISTRY}/-/npm/v1/attestations/")
        or not isinstance(provenance, dict)
        or provenance.get("predicateType") != "https://slsa.dev/provenance/v1"
    ):
        raise PublicationError("published npm version is missing provenance attestation metadata")
    return metadata


def publish(package_path: pathlib.Path, *, dist_tag: str) -> subprocess.CompletedProcess[str]:
    return run_process(
        [
            "npm",
            "publish",
            str(package_path),
            "--access",
            "public",
            "--ignore-scripts",
            "--provenance",
            "--tag",
            dist_tag,
            "--registry",
            REGISTRY,
        ]
    )


def atomic_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        temporary.unlink(missing_ok=True)
        raise


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Publish one exact CLI npm tarball through OIDC.")
    result.add_argument("--package-file", required=True, type=pathlib.Path)
    result.add_argument("--version", required=True)
    result.add_argument("--source-repository", required=True)
    result.add_argument("--source-sha", required=True)
    result.add_argument("--workflow-run-id", required=True, type=int)
    result.add_argument("--workflow-run-attempt", required=True, type=int)
    result.add_argument("--handoff-artifact-id", required=True, type=int)
    result.add_argument("--handoff-artifact-digest", required=True)
    result.add_argument("--proof-path", required=True, type=pathlib.Path)
    return result


def execute_publication(args: argparse.Namespace) -> None:
    if version_tuple("node") != REQUIRED_NODE_VERSION:
        raise PublicationError("npm publisher requires the exact pinned Node 24.18.0 runtime")
    if version_tuple("npm") != REQUIRED_NPM_VERSION:
        raise PublicationError("npm publisher requires the exact pinned npm 11.16.0 CLI")

    integrity, shasum = package_digests(args.package_file)
    dist_tag = "next" if "-" in args.version else "latest"
    remote = npm_view(args.version)
    status = "already-published-exact"
    if remote is None:
        tags = npm_dist_tags() or {}
        current_tag_version = tags.get(dist_tag)
        if current_tag_version is not None and compare_semver(
            current_tag_version, args.version
        ) >= 0:
            raise PublicationError(
                f"refusing to move npm dist-tag {dist_tag} from {current_tag_version} "
                f"to {args.version}"
            )
        dry_run = run_process(
            [
                "npm",
                "publish",
                str(args.package_file),
                "--access",
                "public",
                "--ignore-scripts",
                "--provenance",
                "--dry-run",
                "--tag",
                dist_tag,
                "--registry",
                REGISTRY,
            ]
        )
        if dry_run.returncode != 0:
            raise PublicationError(f"npm publish dry-run failed:\n{dry_run.stderr.strip()}")
        publication = publish(args.package_file, dist_tag=dist_tag)
        if publication.returncode != 0:
            recovered = npm_view(args.version)
            try:
                remote = verify_remote(
                    recovered,
                    expected_integrity=integrity,
                    expected_shasum=shasum,
                )
            except PublicationError as recovery_error:
                raise PublicationError(
                    f"npm publish failed and exact recovery was not possible:\n"
                    f"{publication.stderr.strip()}"
                ) from recovery_error
            status = "published-concurrently-exact"
        else:
            status = "published-new"

    last_error: PublicationError | None = None
    for attempt in range(1, 7):
        try:
            remote = verify_remote(
                npm_view(args.version),
                expected_integrity=integrity,
                expected_shasum=shasum,
            )
            last_error = None
            break
        except PublicationError as error:
            last_error = error
            if attempt != 6:
                time.sleep(5)
    if last_error is not None:
        raise last_error
    if status != "already-published-exact":
        final_tags = npm_dist_tags()
        if final_tags is None or final_tags.get(dist_tag) != args.version:
            raise PublicationError(f"npm dist-tag {dist_tag} does not point to the published version")

    proof = {
        "schema_version": 1,
        "profile": "skybridge-cli-npm-release-proof",
        "status": status,
        "package": PACKAGE_NAME,
        "version": args.version,
        "registry": REGISTRY,
        "dist_tag": dist_tag,
        "source_repository": args.source_repository,
        "source_sha": args.source_sha,
        "workflow_run_id": args.workflow_run_id,
        "workflow_run_attempt": args.workflow_run_attempt,
        "handoff_artifact_id": args.handoff_artifact_id,
        "handoff_artifact_digest": args.handoff_artifact_digest,
        "integrity": integrity,
        "shasum": shasum,
        "attestations": remote["attestations"],
    }
    atomic_json(args.proof_path, proof)
    print(f"[cli-npm-release] {status}: {PACKAGE_NAME}@{args.version}")


def main() -> int:
    args = parser().parse_args()
    try:
        args.package_file = args.package_file.resolve(strict=True)
        args.proof_path = args.proof_path.resolve(strict=False)
        validate_version(args.version)
        validate_repository(args.source_repository)
        if re.fullmatch(r"[0-9a-f]{40}", args.source_sha) is None:
            raise PublicationError("source SHA must be lowercase 40-hex")
        if args.workflow_run_id <= 0 or args.workflow_run_attempt <= 0:
            raise PublicationError("workflow identity must contain positive integers")
        if args.handoff_artifact_id <= 0 or re.fullmatch(
            r"[0-9a-f]{64}", args.handoff_artifact_digest
        ) is None:
            raise PublicationError("handoff artifact identity is invalid")
        validate_package(
            args.package_file,
            version=args.version,
            source_repository=args.source_repository,
            source_sha=args.source_sha,
            native_assets_dir=args.package_file.parent,
        )
        if os.environ.get("NODE_AUTH_TOKEN") or os.environ.get("NPM_TOKEN"):
            raise PublicationError("long-lived npm tokens are forbidden in the OIDC publisher")
        if not os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL") or not os.environ.get(
            "ACTIONS_ID_TOKEN_REQUEST_TOKEN"
        ):
            raise PublicationError("GitHub Actions OIDC environment is unavailable")
        with isolated_npm_runtime():
            execute_publication(args)
    except (PublicationError, OSError, subprocess.SubprocessError) as error:
        print(f"[cli-npm-release] ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
