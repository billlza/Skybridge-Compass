#!/usr/bin/env python3

from __future__ import annotations

import gzip
import io
import pathlib
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from cli_release_handoff import create, extract, sha256  # noqa: E402
from finalize_cli_release_assets import (  # noqa: E402
    FORMULA_NAME,
    PLATFORM_ASSETS,
    ContractError,
    finalize,
    npm_package_name,
)


VERSION = "1.2.3"
REPOSITORY = "billlza/Skybridge-Compass"
SOURCE_SHA = "a" * 40
TOOLCHAIN = "1.94.0"
SOURCE_DATE_EPOCH = 1_800_000_000
WORKFLOW_RUN_ID = 12_345
WORKFLOW_RUN_ATTEMPT = 2
WORKFLOW_REF = (
    "billlza/Skybridge-Compass/.github/workflows/"
    "skybridge-cli-release.yml@refs/tags/skybridge-cli-v1.2.3"
)
WORKFLOW_SHA = "b" * 40


class CLIReleaseHandoffTests(unittest.TestCase):
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
        self.archive = self.root / "handoff.tar.gz"
        self.checksum = self.root / "handoff.tar.gz.sha256"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def common(self) -> dict[str, object]:
        return {
            "archive": self.archive,
            "checksum": self.checksum,
            "version": VERSION,
            "source_repository": REPOSITORY,
            "source_sha": SOURCE_SHA,
            "rust_toolchain": TOOLCHAIN,
            "source_date_epoch": SOURCE_DATE_EPOCH,
            "workflow_run_id": WORKFLOW_RUN_ID,
            "workflow_run_attempt": WORKFLOW_RUN_ATTEMPT,
            "workflow_ref": WORKFLOW_REF,
            "workflow_sha": WORKFLOW_SHA,
        }

    def create(self) -> None:
        create(assets_dir=self.assets, **self.common())

    def test_round_trip_preserves_and_revalidates_exact_assets(self) -> None:
        self.create()
        destination = self.root / "extracted"
        extract(destination=destination, **self.common())
        self.assertEqual(
            sorted(path.name for path in destination.iterdir()),
            sorted(path.name for path in self.assets.iterdir()),
        )

    def test_rejects_checksum_tampering(self) -> None:
        self.create()
        self.checksum.write_text(f"{'0' * 64}  {self.archive.name}\n", encoding="ascii")
        with self.assertRaisesRegex(ContractError, "checksum mismatch"):
            extract(destination=self.root / "extracted", **self.common())

    def write_malicious_archive(self, member: tarfile.TarInfo, payload: bytes = b"bad") -> None:
        with self.archive.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=SOURCE_DATE_EPOCH) as zipped:
                with tarfile.open(fileobj=zipped, mode="w") as output:
                    output.addfile(member, io.BytesIO(payload) if member.isreg() else None)
        self.checksum.write_text(f"{sha256(self.archive)}  {self.archive.name}\n", encoding="ascii")

    def test_rejects_path_traversal(self) -> None:
        member = tarfile.TarInfo("../release-manifest.json")
        member.size = 3
        self.write_malicious_archive(member)
        with self.assertRaisesRegex(ContractError, "unexpected handoff member"):
            extract(destination=self.root / "extracted", **self.common())

    def test_rejects_symbolic_link(self) -> None:
        member = tarfile.TarInfo("release-manifest.json")
        member.type = tarfile.SYMTYPE
        member.linkname = "/etc/passwd"
        self.write_malicious_archive(member)
        with self.assertRaisesRegex(ContractError, "regular file"):
            extract(destination=self.root / "extracted", **self.common())

    def test_rejects_extra_member(self) -> None:
        member = tarfile.TarInfo("operator-secret.txt")
        member.size = 3
        self.write_malicious_archive(member)
        with self.assertRaisesRegex(ContractError, "unexpected handoff member"):
            extract(destination=self.root / "extracted", **self.common())

    def test_rejects_wrong_expected_source(self) -> None:
        self.create()
        common = self.common()
        common["source_sha"] = "b" * 40
        with self.assertRaisesRegex(ContractError, "handoff metadata does not match"):
            extract(destination=self.root / "extracted", **common)

    def test_rejects_wrong_workflow_attempt(self) -> None:
        self.create()
        common = self.common()
        common["workflow_run_attempt"] = WORKFLOW_RUN_ATTEMPT + 1
        with self.assertRaisesRegex(ContractError, "handoff metadata does not match"):
            extract(destination=self.root / "extracted", **common)

    def test_rejects_wrong_workflow_ref(self) -> None:
        self.create()
        common = self.common()
        common["workflow_ref"] = (
            "billlza/Skybridge-Compass/.github/workflows/"
            "unreviewed.yml@refs/tags/skybridge-cli-v1.2.3"
        )
        with self.assertRaisesRegex(ContractError, "canonical CLI release workflow"):
            extract(destination=self.root / "extracted", **common)

    def test_rejects_wrong_workflow_sha(self) -> None:
        self.create()
        common = self.common()
        common["workflow_sha"] = "c" * 40
        with self.assertRaisesRegex(ContractError, "handoff metadata does not match"):
            extract(destination=self.root / "extracted", **common)


if __name__ == "__main__":
    unittest.main()
