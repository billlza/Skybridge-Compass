#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from finalize_cli_release_assets import FORMULA_NAME, PLATFORM_ASSETS, finalize, npm_package_name


ROOT = pathlib.Path(__file__).resolve().parents[2]
PUBLISHER = ROOT / "rust/scripts/publish_cli_github_release.sh"
VERSION = "1.2.3"
REPOSITORY = "billlza/Skybridge-Compass"
SOURCE_SHA = "a" * 40
TOOLCHAIN = "1.94.0"
SOURCE_DATE_EPOCH = 1_800_000_000


class PublishCLIGitHubReleaseTests(unittest.TestCase):
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
        self.remote_assets = self.root / "remote-assets"
        self.remote_assets.mkdir()
        self.state = self.root / "state.json"
        self.write_state(exists=False, draft=False, immutable=False, immutable_enabled=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.write_executable("git", self.fake_git_source())
        self.write_executable("gh", self.fake_gh_source())
        self.proof = self.root / "proof.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_state(
        self,
        *,
        exists: bool,
        draft: bool,
        immutable: bool,
        immutable_enabled: bool,
    ) -> None:
        self.state.write_text(
            json.dumps(
                {
                    "exists": exists,
                    "draft": draft,
                    "immutable": immutable,
                    "immutable_enabled": immutable_enabled,
                }
            ),
            encoding="utf-8",
        )

    def write_executable(self, name: str, source: str) -> None:
        path = self.bin / name
        path.write_text(source, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def fake_git_source(self) -> str:
        return f'''#!/usr/bin/env python3
import sys
args = sys.argv[1:]
if args[:1] == ["-C"]:
    args = args[2:]
if args == ["rev-parse", "--verify", "HEAD"]:
    print("{SOURCE_SHA}")
elif args[:2] == ["status", "--porcelain=v1"]:
    pass
elif args[:1] == ["rev-parse"] and args[1].startswith("refs/tags/"):
    print("{SOURCE_SHA}")
else:
    print(f"unexpected fake git invocation: {{args}}", file=sys.stderr)
    raise SystemExit(2)
'''

    def fake_gh_source(self) -> str:
        return r'''#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import shutil
import sys

root = pathlib.Path(os.environ["FAKE_GH_ROOT"])
state_path = root / "state.json"
remote = root / "remote-assets"
log_path = root / "gh.log"
args = sys.argv[1:]
with log_path.open("a", encoding="utf-8") as handle:
    handle.write(" ".join(args) + "\n")
state = json.loads(state_path.read_text(encoding="utf-8"))


def save():
    state_path.write_text(json.dumps(state), encoding="utf-8")


if args[:1] == ["api"]:
    endpoint = next((value for value in args[1:] if value.startswith("repos/")), "")
    if "/commits/" in endpoint:
        print(os.environ["FAKE_SOURCE_SHA"])
        raise SystemExit(0)
    if endpoint.endswith("/immutable-releases"):
        print("true" if state["immutable_enabled"] else "false")
        raise SystemExit(0)
if args[:2] == ["release", "view"]:
    if not state["exists"]:
        raise SystemExit(1)
    if "--json" in args:
        assets = [{"name": path.name} for path in sorted(remote.iterdir())]
        print(json.dumps({
            "tagName": f"skybridge-cli-v{os.environ['FAKE_VERSION']}",
            "isDraft": state["draft"],
            "isImmutable": state["immutable"],
            "assets": assets,
        }))
    raise SystemExit(0)
if args[:2] == ["release", "create"]:
    copied = 0
    for value in args[3:]:
        candidate = pathlib.Path(value)
        if candidate.is_file():
            shutil.copyfile(candidate, remote / candidate.name)
            copied += 1
            if os.environ.get("FAKE_FAIL_CREATE") == "1" and copied == 1:
                state.update(exists=True, draft=True, immutable=False)
                save()
                raise SystemExit(1)
    state.update(exists=True, draft=True, immutable=False)
    save()
    raise SystemExit(0)
if args[:2] == ["release", "download"]:
    destination = pathlib.Path(args[args.index("--dir") + 1])
    destination.mkdir(parents=True, exist_ok=True)
    for source in remote.iterdir():
        shutil.copyfile(source, destination / source.name)
    raise SystemExit(0)
if args[:2] == ["release", "edit"]:
    if os.environ.get("FAKE_FAIL_PUBLISH") == "1":
        raise SystemExit(1)
    state.update(draft=False, immutable=True)
    save()
    raise SystemExit(0)
if args[:2] == ["release", "verify"]:
    if not state["immutable"]:
        raise SystemExit(1)
    if "--format" in args:
        tag = f"skybridge-cli-v{os.environ['FAKE_VERSION']}"
        repository = "billlza/Skybridge-Compass"
        subjects = [{
            "uri": f"pkg:github/{repository}@{tag}",
            "digest": {"sha1": os.environ["FAKE_SOURCE_SHA"]},
        }]
        for asset in sorted(remote.iterdir()):
            subjects.append({
                "name": asset.name,
                "digest": {"sha256": hashlib.sha256(asset.read_bytes()).hexdigest()},
            })
        print(json.dumps({
            "verificationResult": {
                "statement": {
                    "predicateType": "https://in-toto.io/attestation/release/v0.2",
                    "predicate": {"repository": repository, "tag": tag},
                    "subject": subjects,
                }
            }
        }))
    raise SystemExit(0)
if args[:2] == ["release", "verify-asset"]:
    raise SystemExit(0 if state["immutable"] else 1)
print(f"unexpected fake gh invocation: {args}", file=sys.stderr)
raise SystemExit(2)
'''

    def environment(self, **overrides: str) -> dict[str, str]:
        environment = os.environ.copy()
        environment["PATH"] = f"{self.bin}{os.pathsep}{environment['PATH']}"
        environment["GH_TOKEN"] = "ephemeral-test-token"
        environment["FAKE_GH_ROOT"] = os.fspath(self.root)
        environment["FAKE_SOURCE_SHA"] = SOURCE_SHA
        environment["FAKE_VERSION"] = VERSION
        environment.update(overrides)
        return environment

    def command(self) -> list[str]:
        return [
            "/bin/bash",
            os.fspath(PUBLISHER),
            "--repository",
            REPOSITORY,
            "--tag",
            f"skybridge-cli-v{VERSION}",
            "--expected-source-sha",
            SOURCE_SHA,
            "--assets-dir",
            os.fspath(self.assets),
            "--version",
            VERSION,
            "--rust-toolchain",
            TOOLCHAIN,
            "--source-date-epoch",
            str(SOURCE_DATE_EPOCH),
            "--workflow-run-id",
            "12345",
            "--workflow-run-attempt",
            "2",
            "--handoff-artifact-id",
            "67890",
            "--handoff-artifact-digest",
            "b" * 64,
            "--proof-path",
            os.fspath(self.proof),
        ]

    def run_publisher(self, **environment: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            self.command(),
            check=False,
            capture_output=True,
            text=True,
            cwd=ROOT,
            env=self.environment(**environment),
        )

    def stage_remote(self, *, draft: bool, immutable: bool) -> None:
        for source in self.assets.iterdir():
            shutil.copyfile(source, self.remote_assets / source.name)
        self.write_state(
            exists=True,
            draft=draft,
            immutable=immutable,
            immutable_enabled=True,
        )

    def test_creates_complete_draft_then_publishes_and_verifies(self) -> None:
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.state.read_text(encoding="utf-8"))
        self.assertFalse(state["draft"])
        self.assertTrue(state["immutable"])
        self.assertEqual(len(list(self.remote_assets.iterdir())), 8)
        proof = json.loads(self.proof.read_text(encoding="utf-8"))
        self.assertEqual(len(proof["assets"]), 8)
        self.assertEqual(proof["handoff_artifact_id"], 67890)
        log = (self.root / "gh.log").read_text(encoding="utf-8")
        self.assertIn("release create", log)
        self.assertIn("release edit", log)
        self.assertIn("release verify-asset", log)

    def test_existing_exact_immutable_release_is_idempotent(self) -> None:
        self.stage_remote(draft=False, immutable=True)
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        log = (self.root / "gh.log").read_text(encoding="utf-8")
        self.assertNotIn("release create", log)
        self.assertNotIn("release edit", log)

    def test_existing_draft_with_different_bytes_never_publishes(self) -> None:
        self.stage_remote(draft=True, immutable=False)
        with (self.remote_assets / npm_package_name(VERSION)).open("ab") as handle:
            handle.write(b"tampered")
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        state = json.loads(self.state.read_text(encoding="utf-8"))
        self.assertTrue(state["draft"])
        self.assertFalse(state["immutable"])
        self.assertNotIn("release edit", (self.root / "gh.log").read_text(encoding="utf-8"))

    def test_partial_draft_creation_fails_closed_and_is_not_auto_repaired(self) -> None:
        first = self.run_publisher(FAKE_FAIL_CREATE="1")
        self.assertNotEqual(first.returncode, 0)
        second = self.run_publisher()
        self.assertNotEqual(second.returncode, 0)
        state = json.loads(self.state.read_text(encoding="utf-8"))
        self.assertTrue(state["draft"])
        self.assertFalse(state["immutable"])

    def test_immutable_release_policy_is_mandatory(self) -> None:
        self.write_state(exists=False, draft=False, immutable=False, immutable_enabled=False)
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(self.state.read_text(encoding="utf-8"))["exists"])


if __name__ == "__main__":
    unittest.main()
