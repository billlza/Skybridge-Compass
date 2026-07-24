#!/usr/bin/env python3
"""Behavior and source-contract tests for WebRTC smoke process ownership."""

from __future__ import annotations

import json
import os
import pathlib
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import webrtc_smoke_process_ownership as ownership


SMOKE_SCRIPT = SCRIPT_DIR / "run_real_device_webrtc_smoke.sh"


class PrivateWorkspaceTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.private_directory = pathlib.Path(self.temporary_directory.name)
        self.private_directory.chmod(0o700)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_json(self, name: str, payload: object, mode: int = 0o600) -> pathlib.Path:
        path = self.private_directory / name
        path.write_text(json.dumps(payload), encoding="utf-8")
        path.chmod(mode)
        return path


class MacProcessOwnershipTests(PrivateWorkspaceTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.process = subprocess.Popen(["/bin/sleep", "30"])

    def tearDown(self) -> None:
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGKILL)
        self.process.wait()
        super().tearDown()

    def test_exact_executable_and_microsecond_start_token_are_recorded(self) -> None:
        identity = self.private_directory / "mac.json"

        ownership.mac_capture(self.process.pid, pathlib.Path("/bin/sleep"), identity)

        payload = json.loads(identity.read_text(encoding="utf-8"))
        self.assertEqual(payload["processIdentifier"], self.process.pid)
        self.assertEqual(payload["executablePath"], os.path.realpath("/bin/sleep"))
        self.assertRegex(payload["startTimeToken"], r"^[0-9]+:[0-9]+$")
        self.assertEqual(len(payload["auditToken"]), 8)
        self.assertEqual(payload["auditToken"][5], self.process.pid)
        self.assertEqual(identity.stat().st_mode & 0o777, 0o600)
        self.assertEqual(ownership.mac_status(identity), ownership.MATCH)

    def test_start_token_mismatch_is_unverifiable_and_does_not_signal_process(self) -> None:
        identity = self.private_directory / "mac.json"
        ownership.mac_capture(self.process.pid, pathlib.Path("/bin/sleep"), identity)
        payload = json.loads(identity.read_text(encoding="utf-8"))
        payload["startTimeToken"] = "0:0"
        identity.write_text(json.dumps(payload), encoding="utf-8")

        self.assertEqual(ownership.mac_status(identity), ownership.UNVERIFIABLE)
        self.assertEqual(ownership.mac_signal(identity, signal.SIGTERM), ownership.UNVERIFIABLE)
        self.assertIsNone(self.process.poll())

    def test_executable_mismatch_is_rejected_at_capture(self) -> None:
        identity = self.private_directory / "mac.json"

        with self.assertRaisesRegex(ownership.OwnershipError, "expected binary"):
            ownership.mac_capture(self.process.pid, pathlib.Path("/bin/echo"), identity)

        self.assertFalse(identity.exists())
        self.assertIsNone(self.process.poll())

    def test_audit_token_mismatch_is_unverifiable_and_does_not_signal_process(self) -> None:
        identity = self.private_directory / "mac.json"
        ownership.mac_capture(self.process.pid, pathlib.Path("/bin/sleep"), identity)
        payload = json.loads(identity.read_text(encoding="utf-8"))
        payload["auditToken"][-1] += 1
        identity.write_text(json.dumps(payload), encoding="utf-8")

        self.assertEqual(ownership.mac_signal(identity, signal.SIGTERM), ownership.UNVERIFIABLE)
        self.assertIsNone(self.process.poll())

    def test_exited_process_is_distinct_from_unverifiable_ownership(self) -> None:
        identity = self.private_directory / "mac.json"
        ownership.mac_capture(self.process.pid, pathlib.Path("/bin/sleep"), identity)
        self.process.terminate()
        self.process.wait()

        self.assertEqual(ownership.mac_status(identity), ownership.ABSENT)

    def test_exact_identity_can_be_signaled(self) -> None:
        identity = self.private_directory / "mac.json"
        ownership.mac_capture(self.process.pid, pathlib.Path("/bin/sleep"), identity)

        self.assertEqual(ownership.mac_signal(identity, signal.SIGTERM), ownership.MATCH)
        self.process.wait(timeout=5)
        self.assertEqual(ownership.mac_status(identity), ownership.ABSENT)


class IOSProcessOwnershipTests(PrivateWorkspaceTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.app_path = self.private_directory / "SkyBridgeCompass-iOS.app"
        self.app_path.mkdir()
        with (self.app_path / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleExecutable": "SkyBridgeCompass-iOS"}, handle)
        self.local_executable = self.app_path / "SkyBridgeCompass-iOS"
        self.local_executable.write_bytes(b"test executable")
        self.local_executable.chmod(0o700)
        self.pid = 4321
        self.audit_token = [0xFFFFFFFF, 501, 501, 501, 501, self.pid, 0, 19732]
        self.runtime_url = (
            "file:///private/var/containers/Bundle/Application/"
            "11111111-2222-3333-4444-555555555555/"
            "SkyBridgeCompass-iOS.app/SkyBridgeCompass-iOS"
        )
        self.launch_json = self.write_json(
            "launch.json",
            {
                "result": {
                    "process": {
                        "auditToken": self.audit_token,
                        "executable": self.runtime_url,
                        "processIdentifier": self.pid,
                    }
                }
            },
        )
        self.identity = self.private_directory / "ios-identity.json"
        ownership.ios_capture(self.launch_json, self.app_path, self.identity)

    def status_for(self, entries: list[object]) -> int:
        processes = self.write_json("processes.json", {"result": {"runningProcesses": entries}})
        return ownership.ios_status(processes, self.identity)

    def exact_entry(self) -> dict[str, object]:
        return {
            "auditToken": self.audit_token,
            "executable": self.runtime_url,
            "processIdentifier": self.pid,
        }

    def test_pid_executable_and_audit_token_must_all_match(self) -> None:
        self.assertEqual(self.status_for([self.exact_entry()]), ownership.MATCH)

    def test_missing_pid_is_reported_as_absent(self) -> None:
        other = self.exact_entry()
        other["processIdentifier"] = self.pid + 1

        self.assertEqual(self.status_for([other]), ownership.ABSENT)

    def test_current_process_schema_without_audit_token_fails_closed(self) -> None:
        entry = self.exact_entry()
        del entry["auditToken"]

        self.assertEqual(self.status_for([entry]), ownership.UNVERIFIABLE)

    def test_same_pid_with_different_bundle_executable_fails_closed(self) -> None:
        entry = self.exact_entry()
        entry["executable"] = entry["executable"].replace(
            "SkyBridgeCompass-iOS.app/SkyBridgeCompass-iOS",
            "Impostor.app/Impostor",
        )

        self.assertEqual(self.status_for([entry]), ownership.UNVERIFIABLE)

    def test_same_pid_with_different_audit_token_fails_closed(self) -> None:
        entry = self.exact_entry()
        entry["auditToken"] = [*self.audit_token[:-1], self.audit_token[-1] + 1]

        self.assertEqual(self.status_for([entry]), ownership.UNVERIFIABLE)

    def test_duplicate_pid_entries_fail_closed(self) -> None:
        entry = self.exact_entry()

        self.assertEqual(self.status_for([entry, dict(entry)]), ownership.UNVERIFIABLE)

    def test_launch_must_match_built_bundle_executable(self) -> None:
        launch = json.loads(self.launch_json.read_text(encoding="utf-8"))
        launch["result"]["process"]["executable"] = (
            "file:///private/var/containers/Bundle/Application/"
            "11111111-2222-3333-4444-555555555555/Impostor.app/Impostor"
        )
        bad_launch = self.write_json("bad-launch.json", launch)

        with self.assertRaisesRegex(ownership.OwnershipError, "expected bundle executable"):
            ownership.ios_capture(bad_launch, self.app_path, self.private_directory / "bad-identity.json")

    def test_launch_executable_path_traversal_is_rejected(self) -> None:
        launch = json.loads(self.launch_json.read_text(encoding="utf-8"))
        launch["result"]["process"]["executable"] = (
            "file:///private/var/containers/Bundle/Application/../"
            "SkyBridgeCompass-iOS.app/SkyBridgeCompass-iOS"
        )
        bad_launch = self.write_json("traversal-launch.json", launch)

        with self.assertRaisesRegex(ownership.OwnershipError, "traversal components"):
            ownership.ios_capture(bad_launch, self.app_path, self.private_directory / "bad-identity.json")

    def test_launch_audit_token_must_be_bound_to_process_identifier(self) -> None:
        launch = json.loads(self.launch_json.read_text(encoding="utf-8"))
        launch["result"]["process"]["auditToken"][5] = self.pid + 1
        bad_launch = self.write_json("wrong-token-pid-launch.json", launch)

        with self.assertRaisesRegex(ownership.OwnershipError, "bound to its process identifier"):
            ownership.ios_capture(bad_launch, self.app_path, self.private_directory / "bad-identity.json")


class SmokeSourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SMOKE_SCRIPT.read_text(encoding="utf-8")

    @classmethod
    def function_body(cls, name: str) -> str:
        match = re.search(rf"(?ms)^{re.escape(name)}\(\) \{{\n(.*?)^\}}\n", cls.source)
        if match is None:
            raise AssertionError(f"missing shell function: {name}")
        return match.group(1)

    def test_mac_identity_is_captured_immediately_after_launch(self) -> None:
        launch_assignment = self.source.index('MAC_PID="$!"')
        capture = self.source.index('"$PROCESS_OWNERSHIP_HELPER" mac-capture', launch_assignment)
        first_business_wait = self.source.index('wait_for_file_nonempty "$MAC_CODE"', launch_assignment)

        self.assertLess(launch_assignment, capture)
        self.assertLess(capture, first_business_wait)

    def test_mac_term_and_kill_are_both_guarded_by_exact_status_checks(self) -> None:
        body = self.function_body("terminate_mac_host")
        term = body.index("--signal TERM")
        kill = body.index("--signal KILL")
        checks = [match.start() for match in re.finditer(r' mac-status --identity ', body)]

        self.assertTrue(any(check < term for check in checks))
        self.assertTrue(any(term < check < kill for check in checks))
        self.assertNotIn('kill -TERM "$target_pid"', body)
        self.assertNotIn('kill -KILL "$target_pid"', body)
        self.assertNotIn('kill -0 "$target_pid"', body)

    def test_ios_launch_identity_is_captured_before_pid_is_consumed(self) -> None:
        launch = self.source.index("device process launch \\")
        capture = self.source.index('"$PROCESS_OWNERSHIP_HELPER" ios-capture', launch)
        identity_pid = self.source.index('"$PROCESS_OWNERSHIP_HELPER" identity-pid', capture)

        self.assertLess(launch, capture)
        self.assertLess(capture, identity_pid)

    def test_ios_terminate_is_guarded_by_pid_executable_and_token_status(self) -> None:
        body = self.function_body("terminate_ios_app")
        ownership_check = body.index("ios_process_ownership_status")
        terminate = body.index("device process terminate")

        self.assertLess(ownership_check, terminate)
        self.assertIn("PID, bundle executable, and audit token", body)
        self.assertNotIn("ios_process_is_running", self.source)

    def test_process_ownership_has_an_independent_private_lifecycle(self) -> None:
        self.assertIn('mktemp -d "${TMPDIR:-/tmp}/skybridge-webrtc-process-ownership.', self.source)
        self.assertIn('MAC_PROCESS_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/', self.source)
        self.assertIn('IOS_PROCESS_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/', self.source)
        self.assertNotIn('MAC_PROCESS_IDENTITY="$AUTH_PRIVATE_DIR/', self.source)
        self.assertNotIn('IOS_PROCESS_IDENTITY="$AUTH_PRIVATE_DIR/', self.source)

    def test_mac_signals_use_audit_token_api_instead_of_pid_only_kill(self) -> None:
        helper_source = (SCRIPT_DIR / "webrtc_smoke_process_ownership.py").read_text(encoding="utf-8")

        self.assertIn("proc_signal_with_audittoken", helper_source)
        self.assertNotIn("os.kill(pid, signal_number)", helper_source)


class CLIFailClosedTests(unittest.TestCase):
    def test_unexpected_helper_failure_is_not_reported_as_process_absence(self) -> None:
        with mock.patch.object(ownership, "mac_status", side_effect=RuntimeError("fixture")):
            status = ownership.main(["mac-status", "--identity", "/tmp/unused.json"])

        self.assertEqual(status, ownership.UNVERIFIABLE)
        self.assertNotEqual(status, ownership.ABSENT)


if __name__ == "__main__":
    unittest.main(verbosity=2)
