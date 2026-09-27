#!/usr/bin/env python3
import subprocess
import unittest
from unittest import mock
import release_keychain_state as state


class ReleaseKeychainStateTests(unittest.TestCase):
    def test_native_indentation_and_quoted_spaces_preserve_exact_paths(self) -> None:
        raw = '    "/Users/runner/Library/Keychains/login.keychain-db"\n    "/Users/runner/Library/Keychains/Release Keys.keychain-db"\n'
        self.assertEqual(state.parse_paths(raw, single=False), [
            "/Users/runner/Library/Keychains/login.keychain-db",
            "/Users/runner/Library/Keychains/Release Keys.keychain-db",
        ])
        self.assertEqual(state.parse_paths(raw.splitlines()[0], single=True), [
            "/Users/runner/Library/Keychains/login.keychain-db"
        ])

    def test_malformed_default_or_relative_paths_fail_before_restoring(self) -> None:
        for raw in ('', '"unterminated', '"relative.keychain-db"', '"/a" "/b"', '"/a\nb"'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                state.parse_paths(raw, single=True)

    def test_restore_attempts_both_boundaries_and_reports_any_failure(self) -> None:
        with mock.patch.object(state.subprocess, "run", side_effect=[
            subprocess.CompletedProcess([], 1, "", "list unavailable"),
            subprocess.CompletedProcess([], 0, "", ""),
        ]) as run:
            with self.assertRaisesRegex(RuntimeError, "list unavailable"):
                state.restore(["/a path", "/b"], "/a path")
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args_list[0].args[0], [
            "security", "list-keychains", "-d", "user", "-s", "/a path", "/b"
        ])
        self.assertEqual(run.call_args_list[1].args[0][-1], "/a path")

    def test_empty_search_list_is_restored_without_inventing_a_default_entry(self) -> None:
        with mock.patch.object(state.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            state.restore(state.parse_paths("", single=False), "/original-default")
        self.assertEqual(run.call_args_list[0].args[0], ["security", "list-keychains", "-d", "user", "-s"])

    def test_timeout_still_attempts_default_restoration_and_fails(self) -> None:
        with mock.patch.object(state.subprocess, "run", side_effect=[
            subprocess.TimeoutExpired("security", 30),
            subprocess.CompletedProcess([], 0, "", ""),
        ]) as run:
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                state.restore(["/original"], "/original")
        self.assertEqual(run.call_count, 2)


if __name__ == "__main__":
    unittest.main()
