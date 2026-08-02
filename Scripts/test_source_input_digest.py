#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).with_name("source_input_digest.py")
SPEC = importlib.util.spec_from_file_location("source_input_digest", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
SOURCE_DIGEST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOURCE_DIGEST)


class SourceInputDigestTests(unittest.TestCase):
    def test_digest_changes_with_source_content_but_not_excluded_build_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources"
            source.mkdir()
            (source / "A.swift").write_text("let value = 1\n", encoding="utf-8")
            first, first_count = SOURCE_DIGEST.compute_digest(root, [Path("Sources")])

            build = source / ".build"
            build.mkdir()
            (build / "generated.bin").write_bytes(b"ignored")
            excluded, excluded_count = SOURCE_DIGEST.compute_digest(root, [Path("Sources")])
            self.assertEqual((first, first_count), (excluded, excluded_count))

            (source / "A.swift").write_text("let value = 2\n", encoding="utf-8")
            changed, changed_count = SOURCE_DIGEST.compute_digest(root, [Path("Sources")])
            self.assertNotEqual(first, changed)
            self.assertEqual(first_count, changed_count)

    def test_digest_is_independent_of_requested_path_order(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "A").mkdir()
            (root / "B").mkdir()
            (root / "A" / "one").write_bytes(b"1")
            (root / "B" / "two").write_bytes(b"2")
            first = SOURCE_DIGEST.compute_digest(root, [Path("A"), Path("B")])
            second = SOURCE_DIGEST.compute_digest(root, [Path("B"), Path("A")])
            self.assertEqual(first, second)

    def test_symlink_target_is_bound_without_following_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources"
            source.mkdir()
            link = source / "dependency"
            link.symlink_to("first")
            first, _ = SOURCE_DIGEST.compute_digest(root, [Path("Sources")])
            link.unlink()
            link.symlink_to("second")
            second, _ = SOURCE_DIGEST.compute_digest(root, [Path("Sources")])
            self.assertNotEqual(first, second)

    def test_missing_required_input_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(SOURCE_DIGEST.DigestError):
                SOURCE_DIGEST.compute_digest(Path(directory), [Path("missing")])


if __name__ == "__main__":
    unittest.main()
