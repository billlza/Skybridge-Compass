#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import sys
from typing import Any

from finalize_cli_release_assets import expected_final_names, maximum_size, regular_file, sha256


class ProofError(ValueError):
    pass


def load_json_exact(path: pathlib.Path) -> dict[str, Any]:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ProofError(f"duplicate JSON key in {path.name}: {key}")
            result[key] = value
        return result

    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProofError(f"invalid JSON in {path.name}") from error
    if not isinstance(value, dict):
        raise ProofError(f"{path.name} must contain one JSON object")
    return value


def validate_identity(args: argparse.Namespace) -> None:
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository) is None:
        raise ProofError("invalid repository identity")
    if re.fullmatch(r"[0-9a-f]{40}", args.source_sha) is None:
        raise ProofError("invalid source SHA")
    if args.workflow_run_id <= 0 or args.workflow_run_attempt <= 0:
        raise ProofError("invalid producer workflow identity")
    if args.handoff_artifact_id <= 0 or re.fullmatch(
        r"[0-9a-f]{64}", args.handoff_artifact_digest
    ) is None:
        raise ProofError("invalid handoff artifact identity")


def github_asset_records(assets_dir: pathlib.Path, version: str) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for name in (
        "skybridge-aarch64-apple-darwin.tar.gz",
        "skybridge-aarch64-unknown-linux-gnu.tar.gz",
        "skybridge-x86_64-unknown-linux-gnu.tar.gz",
        "skybridge-x86_64-pc-windows-msvc.zip",
        f"skybridge-cli-{version}.tgz",
        "skybridge.rb",
        "release-manifest.json",
        "SHA256SUMS.txt",
    ):
        path = assets_dir / name
        metadata = regular_file(path, maximum_bytes=maximum_size(name))
        records.append({"name": name, "sha256": sha256(path), "size_bytes": metadata.st_size})
    if set(name for name in expected_final_names(version)) != {
        record["name"] for record in records
    }:
        raise ProofError("GitHub proof asset set diverged from the public asset contract")
    return records


def verify_github(args: argparse.Namespace) -> None:
    actual = load_json_exact(args.proof)
    expected = {
        "schema_version": 1,
        "profile": "skybridge-cli-github-release-proof",
        "status": "published-immutable-and-verified",
        "repository": args.repository,
        "tag": args.tag,
        "source_sha": args.source_sha,
        "workflow_run_id": args.workflow_run_id,
        "workflow_run_attempt": args.workflow_run_attempt,
        "handoff_artifact_id": args.handoff_artifact_id,
        "handoff_artifact_digest": args.handoff_artifact_digest,
        "immutable": True,
        "assets": github_asset_records(args.assets_dir, args.version),
    }
    if actual != expected:
        raise ProofError("GitHub proof does not match the exact immutable assets and producer identity")


def npm_digests(path: pathlib.Path) -> tuple[str, str]:
    regular_file(path, maximum_bytes=64 * 1024 * 1024)
    sha512 = hashlib.sha512()
    sha1 = hashlib.sha1(usedforsecurity=False)
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            sha512.update(chunk)
            sha1.update(chunk)
    return "sha512-" + base64.b64encode(sha512.digest()).decode("ascii"), sha1.hexdigest()


def verify_npm(args: argparse.Namespace) -> None:
    actual = load_json_exact(args.proof)
    expected_keys = {
        "schema_version",
        "profile",
        "status",
        "package",
        "version",
        "registry",
        "dist_tag",
        "source_repository",
        "source_sha",
        "workflow_run_id",
        "workflow_run_attempt",
        "handoff_artifact_id",
        "handoff_artifact_digest",
        "integrity",
        "shasum",
        "attestations",
    }
    if set(actual) != expected_keys:
        raise ProofError("npm proof has an unexpected field set")
    identity = {
        "schema_version": 1,
        "profile": "skybridge-cli-npm-release-proof",
        "package": "skybridge-cli",
        "version": args.version,
        "registry": "https://registry.npmjs.org",
        "dist_tag": "next" if "-" in args.version else "latest",
        "source_repository": args.repository,
        "source_sha": args.source_sha,
        "workflow_run_id": args.workflow_run_id,
        "workflow_run_attempt": args.workflow_run_attempt,
        "handoff_artifact_id": args.handoff_artifact_id,
        "handoff_artifact_digest": args.handoff_artifact_digest,
    }
    for key, expected in identity.items():
        if actual.get(key) != expected:
            raise ProofError(f"npm proof identity mismatch: {key}")
    if actual.get("status") not in {
        "already-published-exact",
        "published-concurrently-exact",
        "published-new",
    }:
        raise ProofError("npm proof has an invalid publication status")
    integrity, shasum = npm_digests(args.package_file)
    if actual.get("integrity") != integrity or actual.get("shasum") != shasum:
        raise ProofError("npm proof digest does not match the exact package tarball")
    attestations = actual.get("attestations")
    provenance = attestations.get("provenance") if isinstance(attestations, dict) else None
    if (
        not isinstance(attestations, dict)
        or not isinstance(attestations.get("url"), str)
        or not attestations["url"].startswith(
            "https://registry.npmjs.org/-/npm/v1/attestations/"
        )
        or not isinstance(provenance, dict)
        or provenance.get("predicateType") != "https://slsa.dev/provenance/v1"
    ):
        raise ProofError("npm proof lacks the required provenance attestation")


def add_identity_arguments(command: argparse.ArgumentParser) -> None:
    command.add_argument("--proof", required=True, type=pathlib.Path)
    command.add_argument("--repository", required=True)
    command.add_argument("--source-sha", required=True)
    command.add_argument("--version", required=True)
    command.add_argument("--workflow-run-id", required=True, type=int)
    command.add_argument("--workflow-run-attempt", required=True, type=int)
    command.add_argument("--handoff-artifact-id", required=True, type=int)
    command.add_argument("--handoff-artifact-digest", required=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify a SkyBridge CLI channel proof.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    github = subparsers.add_parser("github")
    add_identity_arguments(github)
    github.add_argument("--tag", required=True)
    github.add_argument("--assets-dir", required=True, type=pathlib.Path)
    npm = subparsers.add_parser("npm")
    add_identity_arguments(npm)
    npm.add_argument("--package-file", required=True, type=pathlib.Path)
    args = parser.parse_args()
    try:
        validate_identity(args)
        if args.command == "github":
            verify_github(args)
        else:
            verify_npm(args)
    except (ProofError, OSError) as error:
        print(f"CLI release proof verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
