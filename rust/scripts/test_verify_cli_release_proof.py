#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from finalize_cli_release_assets import FORMULA_NAME, PLATFORM_ASSETS, finalize, npm_package_name  # noqa: E402
from verify_cli_release_proof import (  # noqa: E402
    ProofError,
    github_asset_records,
    verify_github,
    verify_npm,
)


VERSION = "1.2.3"
REPOSITORY = "billlza/Skybridge-Compass"
SOURCE_SHA = "a" * 40
TOOLCHAIN = "1.94.0"
SOURCE_DATE_EPOCH = 1_800_000_000


class VerifyCLIReleaseProofTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.assets = self.root / "assets"
        self.assets.mkdir()
        for index, (name, _, _) in enumerate(PLATFORM_ASSETS):
            (self.assets / name).write_bytes(f"native-{index}\n".encode())
        (self.assets / npm_package_name(VERSION)).write_bytes(b"npm-package\n")
        (self.assets / FORMULA_NAME).write_text("class Skybridge < Formula\nend\n", encoding="utf-8")
        finalize(
            self.assets,
            version=VERSION,
            source_repository=REPOSITORY,
            source_sha=SOURCE_SHA,
            rust_toolchain=TOOLCHAIN,
            source_date_epoch=SOURCE_DATE_EPOCH,
        )
        self.identity = {
            "repository": REPOSITORY,
            "source_sha": SOURCE_SHA,
            "version": VERSION,
            "workflow_run_id": 12345,
            "workflow_run_attempt": 2,
            "handoff_artifact_id": 67890,
            "handoff_artifact_digest": "b" * 64,
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_verifies_exact_github_proof_and_rejects_asset_tampering(self) -> None:
        proof = self.root / "github.json"
        proof.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "profile": "skybridge-cli-github-release-proof",
                    "status": "published-immutable-and-verified",
                    **{key: value for key, value in self.identity.items() if key != "version"},
                    "tag": f"skybridge-cli-v{VERSION}",
                    "immutable": True,
                    "assets": github_asset_records(self.assets, VERSION),
                }
            ),
            encoding="utf-8",
        )
        args = argparse.Namespace(
            proof=proof,
            assets_dir=self.assets,
            tag=f"skybridge-cli-v{VERSION}",
            **self.identity,
        )
        verify_github(args)
        with (self.assets / npm_package_name(VERSION)).open("ab") as handle:
            handle.write(b"tampered")
        with self.assertRaisesRegex(ProofError, "exact immutable assets"):
            verify_github(args)

    def test_verifies_exact_npm_proof_and_rejects_digest_substitution(self) -> None:
        package = self.assets / npm_package_name(VERSION)
        sha512 = hashlib.sha512(package.read_bytes()).digest()
        integrity = "sha512-" + base64.b64encode(sha512).decode("ascii")
        shasum = hashlib.sha1(package.read_bytes(), usedforsecurity=False).hexdigest()
        proof = self.root / "npm.json"
        value = {
            "schema_version": 1,
            "profile": "skybridge-cli-npm-release-proof",
            "status": "published-new",
            "package": "skybridge-cli",
            "version": VERSION,
            "registry": "https://registry.npmjs.org",
            "dist_tag": "latest",
            "source_repository": REPOSITORY,
            "source_sha": SOURCE_SHA,
            "workflow_run_id": 12345,
            "workflow_run_attempt": 2,
            "handoff_artifact_id": 67890,
            "handoff_artifact_digest": "b" * 64,
            "integrity": integrity,
            "shasum": shasum,
            "attestations": {
                "url": "https://registry.npmjs.org/-/npm/v1/attestations/skybridge-cli@1.2.3",
                "provenance": {"predicateType": "https://slsa.dev/provenance/v1"},
            },
        }
        proof.write_text(json.dumps(value), encoding="utf-8")
        args = argparse.Namespace(proof=proof, package_file=package, **self.identity)
        verify_npm(args)
        value["integrity"] = "sha512-invalid"
        proof.write_text(json.dumps(value), encoding="utf-8")
        with self.assertRaisesRegex(ProofError, "digest"):
            verify_npm(args)


if __name__ == "__main__":
    unittest.main()
