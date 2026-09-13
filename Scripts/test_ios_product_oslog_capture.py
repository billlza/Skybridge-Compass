#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import ios_product_oslog_capture as capture


class IOSProductOSLogCaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.output = Path(self.temporary.name) / "private.ndjson"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _capture(self, **changes: object) -> None:
        args = dict(device_udid="00000000-0000000000000000", process_id=123, start_epoch=456, raw_output=self.output)
        args.update(changes)
        capture.capture(**args)

    def test_scope_rejects_command_injection_before_authentication(self) -> None:
        for changes in (
            {"device_udid": 'valid-id;touch /tmp/unrelated'},
            {"device_udid": '$(id)-00000'},
            {"process_id": True}, {"process_id": 1},
            {"start_epoch": "1;id"}, {"start_epoch": 0},
        ):
            with self.subTest(changes=changes), mock.patch.object(capture.subprocess, "run") as run:
                with self.assertRaises(ValueError):
                    self._capture(**changes)
                run.assert_not_called()
                self.assertFalse(self.output.exists())

    def test_scoped_reader_is_valid_shell_and_does_not_accept_privileged_paths(self) -> None:
        script = capture.collection_command("00000000-0000000000000000", 123, 456)
        result = subprocess.run(["/bin/bash", "-n"], input=script, text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('processIdentifier == 123 AND subsystem == "com.skybridge.compass.release-evidence" AND category == "ProductSession"', script)
        self.assertIn("--start @456", script)
        self.assertIn("alarm 120", script)
        self.assertIn("/private/tmp/skybridge-ios-product-oslog.XXXXXX", script)

    def test_authenticated_capture_preserves_native_records_and_private_mode(self) -> None:
        native = b'{"eventType":"logEvent"}\r{"count":1,"finished":1}\r\n'
        def run(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess:
            self.assertEqual(argv[:2], ["/usr/bin/osascript", "-e"])
            self.assertTrue(argv[2].endswith(" with administrator privileges"))
            self.assertEqual(kwargs["timeout"], 300)
            kwargs["stdout"].write(native)
            return subprocess.CompletedProcess(argv, 0, b"", b"")
        with mock.patch.object(capture.os, "geteuid", return_value=501), mock.patch.object(capture.subprocess, "run", side_effect=run):
            self._capture()
        self.assertEqual(self.output.read_bytes(), native)
        self.assertEqual(os.stat(self.output).st_mode & 0o777, 0o600)

    def test_failed_cancelled_or_empty_capture_leaves_no_success_output(self) -> None:
        outcomes = (
            subprocess.CompletedProcess([], 1, b"", b"authentication cancelled"),
            subprocess.CompletedProcess([], 0, b"", b""),
            subprocess.TimeoutExpired([], 300),
        )
        for outcome in outcomes:
            def run(*args: object, **kwargs: object) -> subprocess.CompletedProcess:
                if isinstance(outcome, Exception):
                    raise outcome
                return outcome
            with self.subTest(outcome=outcome), mock.patch.object(capture.subprocess, "run", side_effect=run):
                with self.assertRaises((RuntimeError, subprocess.TimeoutExpired)):
                    self._capture()
                self.assertFalse(self.output.exists())

    def test_existing_output_or_symlink_is_never_overwritten(self) -> None:
        self.output.write_bytes(b"existing evidence")
        with mock.patch.object(capture.subprocess, "run") as run:
            with self.assertRaises(FileExistsError):
                self._capture()
            run.assert_not_called()
        self.assertEqual(self.output.read_bytes(), b"existing evidence")
        link = self.output.parent / "link.ndjson"
        link.symlink_to(self.output)
        with self.assertRaises(FileExistsError):
            self._capture(raw_output=link)
        self.assertEqual(self.output.read_bytes(), b"existing evidence")


if __name__ == "__main__":
    unittest.main()
