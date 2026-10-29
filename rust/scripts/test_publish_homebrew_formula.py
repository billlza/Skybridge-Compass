#!/usr/bin/env python3

from __future__ import annotations

import json
import hashlib
import os
import pathlib
import stat
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
PUBLISHER = ROOT / "rust/scripts/publish_homebrew_formula.sh"
VERSION = "1.2.3"
REPOSITORY = "billlza/Skybridge-Compass"
SOURCE_SHA = "a" * 40
REMOTE_COMMIT = "c" * 40


def formula(version: str, *, digest: str = "d" * 64) -> str:
    return (
        "class Skybridge < Formula\n"
        '  desc "SkyBridge CLI headless operator surface"\n'
        '  homepage "https://github.com/billlza/Skybridge-Compass"\n'
        f'  version "{version}"\n'
        "\n"
        "  depends_on arch: :arm64\n"
        "\n"
        "  on_arm do\n"
        f'    url "https://github.com/{REPOSITORY}/releases/download/'
        f'skybridge-cli-v{version}/skybridge-aarch64-apple-darwin.tar.gz"\n'
        f'    sha256 "{digest}"\n'
        "  end\n"
        "\n"
        "  def install\n"
        '    bin.install "skybridge"\n'
        "  end\n"
        "\n"
        "  test do\n"
        '    output = shell_output("#{bin}/skybridge version")\n'
        "    assert_match version.to_s, output\n"
        '    assert_match "phase_5_signaling_plane", output\n'
        "  end\n"
        "end\n"
    )


class PublishHomebrewFormulaTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.remote = self.root / "remote-formula.rb"
        self.darwin_archive = self.root / "skybridge-aarch64-apple-darwin.tar.gz"
        self.darwin_archive.write_bytes(b"darwin-archive\n")
        self.darwin_digest = hashlib.sha256(self.darwin_archive.read_bytes()).hexdigest()
        self.candidate = self.root / "skybridge.rb"
        self.candidate.write_text(
            formula(VERSION, digest=self.darwin_digest),
            encoding="utf-8",
        )
        self.proof = self.root / "proof.json"
        self.log = self.root / "git.log"
        fake_git = self.bin / "git"
        fake_git.write_text(self.fake_git_source(), encoding="utf-8")
        fake_git.chmod(fake_git.stat().st_mode | stat.S_IXUSR)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def fake_git_source(self) -> str:
        return r'''#!/usr/bin/env python3
import os
import pathlib
import shutil
import sys

root = pathlib.Path(os.environ["FAKE_TAP_ROOT"])
remote_formula = root / "remote-formula.rb"
log = root / "git.log"
args = sys.argv[1:]
with log.open("a", encoding="utf-8") as handle:
    handle.write(" ".join(args) + "\n")

if args[:2] == ["check-ref-format", "--branch"]:
    raise SystemExit(0)
if args[:1] == ["clone"]:
    destination = pathlib.Path(args[-1])
    formula_path = destination / "Formula/skybridge.rb"
    formula_path.parent.mkdir(parents=True)
    (destination / ".baseline").mkdir()
    if remote_formula.exists():
        shutil.copyfile(remote_formula, formula_path)
        shutil.copyfile(remote_formula, destination / ".baseline/skybridge.rb")
    (destination / ".remote-url").write_text(args[-2], encoding="utf-8")
    raise SystemExit(0)
if args[:1] == ["-C"]:
    checkout = pathlib.Path(args[1])
    command = args[2:]
    working = checkout / "Formula/skybridge.rb"
    baseline = checkout / ".baseline/skybridge.rb"
    if command == ["remote", "get-url", "origin"]:
        print((checkout / ".remote-url").read_text(encoding="utf-8"))
        raise SystemExit(0)
    if command[:2] == ["diff", "--quiet"]:
        same = baseline.exists() and working.exists() and baseline.read_bytes() == working.read_bytes()
        raise SystemExit(0 if same else 1)
    if command[:2] == ["status", "--short"]:
        same = baseline.exists() and working.exists() and baseline.read_bytes() == working.read_bytes()
        if not same:
            print(" M Formula/skybridge.rb")
        raise SystemExit(0)
    if command[:1] == ["add"]:
        raise SystemExit(0)
    if command[:1] == ["-c"] and "commit" in command:
        raise SystemExit(0)
    if command[:1] == ["push"]:
        mode = os.environ.get("FAKE_PUSH_MODE", "success")
        if mode in {"success", "concurrent-exact"}:
            shutil.copyfile(working, remote_formula)
        raise SystemExit(0 if mode == "success" else 1)
    if command[:1] == ["fetch"]:
        raise SystemExit(0)
    if command[:1] == ["show"]:
        if not remote_formula.exists():
            raise SystemExit(1)
        sys.stdout.buffer.write(remote_formula.read_bytes())
        raise SystemExit(0)
    if command[:1] == ["rev-parse"]:
        print("''' + REMOTE_COMMIT + r'''")
        raise SystemExit(0)
print(f"unexpected fake git invocation: {args}", file=sys.stderr)
raise SystemExit(2)
'''

    def environment(self, *, push_mode: str = "success") -> dict[str, str]:
        environment = os.environ.copy()
        environment["PATH"] = f"{self.bin}{os.pathsep}{environment['PATH']}"
        environment["FAKE_TAP_ROOT"] = os.fspath(self.root)
        environment["FAKE_PUSH_MODE"] = push_mode
        environment["HOMEBREW_TAP_GITHUB_TOKEN"] = "sensitive-test-token"
        return environment

    def command(self) -> list[str]:
        return [
            "/bin/bash",
            os.fspath(PUBLISHER),
            "--tap-repo",
            "billlza/homebrew-skybridge",
            "--formula-file",
            os.fspath(self.candidate),
            "--darwin-archive",
            os.fspath(self.darwin_archive),
            "--formula-path",
            "Formula/skybridge.rb",
            "--branch",
            "main",
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
            "b" * 64,
            "--proof-path",
            os.fspath(self.proof),
        ]

    def run_publisher(self, *, push_mode: str = "success") -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            self.command(),
            check=False,
            capture_output=True,
            text=True,
            cwd=ROOT,
            env=self.environment(push_mode=push_mode),
        )

    def test_publishes_upgrade_without_persisting_token_in_git_arguments(self) -> None:
        self.remote.write_text(formula("1.2.2"), encoding="utf-8")
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.remote.read_bytes(), self.candidate.read_bytes())
        proof = json.loads(self.proof.read_text(encoding="utf-8"))
        self.assertEqual(proof["status"], "published-new")
        self.assertEqual(proof["remote_commit"], REMOTE_COMMIT)
        log = self.log.read_text(encoding="utf-8")
        self.assertNotIn("sensitive-test-token", log)
        self.assertIn("https://github.com/billlza/homebrew-skybridge.git", log)

    def test_exact_same_version_is_idempotent_without_push(self) -> None:
        self.remote.write_text(formula(VERSION, digest=self.darwin_digest), encoding="utf-8")
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(self.proof.read_text(encoding="utf-8"))["status"],
            "already-current",
        )
        self.assertNotIn(" push ", f" {self.log.read_text(encoding='utf-8')} ")

    def test_refuses_version_downgrade(self) -> None:
        self.remote.write_text(formula("2.0.0"), encoding="utf-8")
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to downgrade", result.stderr)
        self.assertFalse(self.proof.exists())

    def test_refuses_same_version_equivocation(self) -> None:
        self.remote.write_text(formula(VERSION, digest="e" * 64), encoding="utf-8")
        result = self.run_publisher()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing equivocation", result.stderr)
        self.assertFalse(self.proof.exists())

    def test_push_failure_recovers_only_when_remote_bytes_are_exact(self) -> None:
        self.remote.write_text(formula("1.2.2"), encoding="utf-8")
        failed = self.run_publisher(push_mode="failure")
        self.assertNotEqual(failed.returncode, 0)
        self.assertFalse(self.proof.exists())

        recovered = self.run_publisher(push_mode="concurrent-exact")
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(
            json.loads(self.proof.read_text(encoding="utf-8"))["status"],
            "published-concurrently-exact",
        )


if __name__ == "__main__":
    unittest.main()
