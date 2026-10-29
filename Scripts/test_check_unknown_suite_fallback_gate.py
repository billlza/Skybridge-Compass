#!/usr/bin/env python3
"""Regression tests for the unknown-suite runtime gate command contract."""

from __future__ import annotations

import importlib.util
import pathlib
import signal
import subprocess
import time
import unittest
from unittest import mock


SCRIPT_PATH = pathlib.Path(__file__).with_name("check_unknown_suite_fallback_gate.py")
SPEC = importlib.util.spec_from_file_location("check_unknown_suite_fallback_gate", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT_PATH}")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class UnknownSuiteFallbackGateTests(unittest.TestCase):
    def test_ios_runtime_gate_uses_hosted_test_scheme_and_strict_build_flags(self) -> None:
        build, test = GATE.ios_runtime_gate_commands(
            "SIMULATOR-ID", "/tmp/derived-data"
        )

        self.assertEqual(build[:2], ["xcodebuild", "build-for-testing"])
        self.assertEqual(test[:2], ["xcodebuild", "test-without-building"])
        for command in (build, test):
            scheme_index = command.index("-scheme")
            derived_data_index = command.index("-derivedDataPath")
            self.assertEqual(command[scheme_index + 1], "SkyBridgeCompassiOSTests")
            self.assertEqual(command[derived_data_index + 1], "/tmp/derived-data")
            self.assertIn("-skipPackageUpdates", command)
            self.assertIn("-disableAutomaticPackageResolution", command)
            self.assertIn("SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", command)
            self.assertIn("GCC_TREAT_WARNINGS_AS_ERRORS=YES", command)
            self.assertIn(
                "SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK",
                command,
            )
        self.assertIn(
            "-only-testing:SkyBridgeCompassiOSTests/HandshakeCryptoPolicyParityTests/testSuiteNotSupportedDoesNotFallbackOrRetry",
            test,
        )
        self.assertNotIn(
            "-only-testing:SkyBridgeCompassiOSTests/HandshakeCryptoPolicyParityTests/testSuiteNotSupportedDoesNotFallbackOrRetry",
            build,
        )

    def test_timeout_terminates_the_owned_process_group(self) -> None:
        process = mock.Mock(pid=12345, returncode=-15)
        process.communicate.side_effect = [
            subprocess.TimeoutExpired(["fixture"], 1),
            ("partial stdout", "partial stderr"),
        ]
        with mock.patch.object(GATE.subprocess, "Popen", return_value=process), mock.patch.object(
            GATE.os, "killpg"
        ) as killpg, mock.patch.object(
            GATE, "wait_for_process_group_exit", return_value=True
        ):
            code, output = GATE.run_command(["fixture"], timeout_seconds=1)

        self.assertEqual(code, 124)
        self.assertIn("partial stdout", output)
        self.assertIn("partial stderr", output)
        self.assertIn("command timed out after 1s; process-group cleanup=complete", output)
        killpg.assert_called_once_with(12345, signal.SIGTERM)

    def test_timeout_kills_descendant_that_ignores_termination(self) -> None:
        def process_exists(process_id: int) -> bool:
            try:
                GATE.os.kill(process_id, 0)
                return True
            except ProcessLookupError:
                return False

        command = [
            "bash",
            "-c",
            '(trap "" TERM; exec sleep 30) >/dev/null 2>&1 & child=$!; echo "$child"; wait "$child"',
        ]
        child_pid: int | None = None
        try:
            code, output = GATE.run_command(command, timeout_seconds=0.2)
            child_pid = int(output.splitlines()[0])
            self.assertEqual(code, 124)
            self.assertIn("process-group cleanup=complete", output)
            deadline = time.monotonic() + 2
            while process_exists(child_pid) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertFalse(process_exists(child_pid))
        finally:
            if child_pid is not None and process_exists(child_pid):
                try:
                    GATE.os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_runtime_gate_uses_idempotent_uninstall_before_and_after_testing(self) -> None:
        commands: list[list[str]] = []

        def fake_run(command: list[str], timeout_seconds: float = 1_200) -> tuple[int, str]:
            _ = timeout_seconds
            commands.append(command)
            return 0, ""

        with mock.patch.object(
            GATE,
            "pick_bootable_ios_simulator",
            return_value=(0, "SIMULATOR-ID", ""),
        ), mock.patch.object(GATE, "run_command", side_effect=fake_run), mock.patch.object(
            GATE.tempfile,
            "TemporaryDirectory",
            return_value=mock.MagicMock(
                __enter__=mock.Mock(return_value="/tmp/derived-data"),
                __exit__=mock.Mock(return_value=False),
            ),
        ):
            results = GATE.run_runtime_gate()

        uninstall = [
            "xcrun",
            "simctl",
            "uninstall",
            "SIMULATOR-ID",
            "com.skybridge.compass.ios",
        ]
        self.assertEqual(commands.count(uninstall), 2)
        self.assertTrue(all(code == 0 for _, code, _ in results))


if __name__ == "__main__":
    unittest.main()
