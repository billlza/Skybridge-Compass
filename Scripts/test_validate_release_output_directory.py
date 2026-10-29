#!/usr/bin/env python3

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from validate_release_output_directory import (
    OutputDirectoryError,
    validate_output_directory,
)


class ReleaseOutputDirectoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.repository = self.root / "repository"
        self.temporary = self.root / "temporary"
        self.repository.mkdir(mode=0o700)
        self.temporary.mkdir(mode=0o700)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_accepts_dedicated_repository_and_temporary_children(self) -> None:
        repository_output = self.repository / ".sandbox-home" / "release-candidate"
        temporary_output = self.temporary / "skybridge-ios-release-test"
        self.assertEqual(
            validate_output_directory(
                repository_root=self.repository,
                temporary_root=self.temporary,
                output=repository_output,
            ),
            repository_output.resolve(strict=False),
        )
        self.assertEqual(
            validate_output_directory(
                repository_root=self.repository,
                temporary_root=self.temporary,
                output=temporary_output,
            ),
            temporary_output.resolve(strict=False),
        )

    def test_rejects_broad_or_unrelated_targets(self) -> None:
        for output in (
            Path("/"),
            Path.home(),
            self.repository,
            self.temporary,
            self.root / "release-candidate",
        ):
            with self.subTest(output=output), self.assertRaises(OutputDirectoryError):
                validate_output_directory(
                    repository_root=self.repository,
                    temporary_root=self.temporary,
                    output=output,
                )

    def test_rejects_unapproved_name_and_relative_path(self) -> None:
        for output in (
            self.temporary / "output",
            Path("release-candidate"),
        ):
            with self.subTest(output=output), self.assertRaises(OutputDirectoryError):
                validate_output_directory(
                    repository_root=self.repository,
                    temporary_root=self.temporary,
                    output=output,
                )

    def test_rejects_symlinked_target_or_component(self) -> None:
        real = self.temporary / "real"
        real.mkdir()
        linked_component = self.temporary / "linked"
        linked_component.symlink_to(real, target_is_directory=True)
        target_link = self.temporary / "release-candidate"
        target_link.symlink_to(real, target_is_directory=True)
        for output in (
            linked_component / "skybridge-ios-release-test",
            target_link,
        ):
            with self.subTest(output=output), self.assertRaises(OutputDirectoryError):
                validate_output_directory(
                    repository_root=self.repository,
                    temporary_root=self.temporary,
                    output=output,
                )


if __name__ == "__main__":
    unittest.main()
