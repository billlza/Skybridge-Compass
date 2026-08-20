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
FILE_TRANSFER_SMOKE_SCRIPT = SCRIPT_DIR / "run_real_device_file_transfer_smoke.sh"
P2P_REMOTE_SMOKE_SCRIPT = SCRIPT_DIR / "run_real_device_p2p_remote_smoke.sh"
MACOS_RELEASE_READINESS_SCRIPT = SCRIPT_DIR / "check_macos_release_readiness.sh"
SHARED_PROCESS_OWNERSHIP_SCRIPT = SCRIPT_DIR / "real_device_ios_process_ownership.sh"


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

    def test_exact_executable_discovery_uses_canonical_binary_path(self) -> None:
        matching_pids = ownership.mac_exact_executable_pids(pathlib.Path("/bin/sleep"))
        unrelated_pids = ownership.mac_exact_executable_pids(pathlib.Path("/bin/echo"))

        self.assertIn(self.process.pid, matching_pids)
        self.assertNotIn(self.process.pid, unrelated_pids)

    def test_current_user_process_inspection_failure_does_not_prove_absence(self) -> None:
        bsd_info = ownership.ProcBSDInfo()
        bsd_info.pbi_uid = os.geteuid()
        with mock.patch.object(
            ownership, "_all_mac_process_identifiers", return_value=[4321]
        ):
            with mock.patch.object(
                ownership, "_read_mac_bsd_info_once", return_value=bsd_info
            ):
                with mock.patch.object(
                    ownership,
                    "_read_mac_executable_path_once",
                    side_effect=ownership.OwnershipError("fixture"),
                ):
                    with self.assertRaisesRegex(
                        ownership.OwnershipError,
                        "cannot prove executable absence for current-user PID 4321",
                    ):
                        ownership.mac_exact_executable_pids(pathlib.Path("/bin/sleep"))

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

    def presence_for(self, entries: list[object]) -> int:
        processes = self.write_json(
            "presence-processes.json",
            {"result": {"runningProcesses": entries}},
        )
        return ownership.ios_presence(processes, self.app_path)

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

    def test_current_process_schema_can_prove_app_presence_without_signal_authority(self) -> None:
        entry = self.exact_entry()
        del entry["auditToken"]

        self.assertEqual(self.presence_for([entry]), ownership.MATCH)

    def test_current_process_schema_can_prove_app_absence(self) -> None:
        self.assertEqual(self.presence_for([]), ownership.ABSENT)

    def test_presence_check_rejects_malformed_process_entries(self) -> None:
        entry = self.exact_entry()
        del entry["auditToken"]
        entry["processIdentifier"] = True

        self.assertEqual(self.presence_for([entry]), ownership.UNVERIFIABLE)

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
        capture = self.source.index("skybridge_mac_capture_owned_process", launch_assignment)
        first_business_wait = self.source.index('wait_for_file_nonempty "$MAC_CODE"', launch_assignment)

        self.assertLess(launch_assignment, capture)
        self.assertLess(capture, first_business_wait)

    def test_mac_term_and_kill_are_both_guarded_by_exact_status_checks(self) -> None:
        body = self.function_body("terminate_mac_host")
        shared_source = SHARED_PROCESS_OWNERSHIP_SCRIPT.read_text(encoding="utf-8")
        shared_match = re.search(
            r"(?ms)^skybridge_mac_terminate_owned_process\(\) \{\n(.*?)^\}\n",
            shared_source,
        )
        self.assertIsNotNone(shared_match)
        shared_body = shared_match.group(1)
        term = shared_body.index("--signal TERM")
        kill = shared_body.index("--signal KILL")
        checks = [
            match.start()
            for match in re.finditer("skybridge_mac_owned_process_status", shared_body)
        ]

        self.assertIn("skybridge_mac_terminate_owned_process", body)
        self.assertTrue(any(check < term for check in checks))
        self.assertTrue(any(term < check < kill for check in checks))
        self.assertNotIn("kill -TERM", shared_body)
        self.assertNotIn("kill -KILL", shared_body)
        self.assertNotIn("kill -0", shared_body)

    def test_product_launch_fails_on_external_exact_executable_and_avoids_new_instance(self) -> None:
        product_launch = self.source.index('if [[ "$MAC_HOST_MODE" == "product" ]]')
        absence = self.source.index("skybridge_mac_require_executable_absent", product_launch)
        launch = self.source.index('/usr/bin/open "${open_args[@]}"', absence)
        discovery = self.source.index("skybridge_mac_wait_for_single_exact_process", launch)
        capture = self.source.index("skybridge_mac_capture_owned_process", discovery)

        self.assertLess(absence, launch)
        self.assertLess(launch, discovery)
        self.assertLess(discovery, capture)
        self.assertNotIn("open_args=(\n    -n", self.source)

    def test_ios_console_handle_is_captured_before_launch_returns_success(self) -> None:
        body = self.function_body("launch_ios_app_with_console_handle")
        launch = body.index("skybridge_ios_start_console_launch")
        started = body.index("IOS_CONSOLE_HANDLE_STARTED=1", launch)
        capture = body.index("skybridge_ios_capture_console_handle", started)
        captured = body.index("IOS_CONSOLE_HANDLE_CAPTURED=1", capture)
        running_check = body.index("ios_console_handle_is_exact_and_running", captured)

        self.assertLess(launch, started)
        self.assertLess(started, capture)
        self.assertLess(capture, captured)
        self.assertLess(captured, running_check)

    def test_ios_cleanup_signals_only_the_exact_local_console_handle(self) -> None:
        body = self.function_body("terminate_ios_app")
        status = body.index("skybridge_ios_console_handle_status")
        signal_handle = body.index("skybridge_ios_signal_console_handle", status)
        wait_for_exit = body.index("skybridge_ios_wait_console_handle_exit", signal_handle)
        capture_result = body.index("skybridge_ios_capture_exited_console_identity", wait_for_exit)
        prove_absence = body.index("skybridge_ios_require_app_absent_after_handle_exit", capture_result)

        self.assertLess(status, signal_handle)
        self.assertLess(signal_handle, wait_for_exit)
        self.assertLess(wait_for_exit, capture_result)
        self.assertLess(capture_result, prove_absence)
        self.assertNotIn("device process terminate", body)
        self.assertNotIn("--pid", body)

    def test_process_ownership_has_an_independent_private_lifecycle(self) -> None:
        self.assertIn('mktemp -d "${TMPDIR:-/tmp}/skybridge-webrtc-process-ownership.', self.source)
        self.assertIn('MAC_PROCESS_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/', self.source)
        self.assertIn('IOS_PROCESS_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/', self.source)
        self.assertIn('IOS_CONSOLE_HANDLE_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/', self.source)
        self.assertIn(
            'IOS_LAUNCH_JSON="$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-launch.raw.json"',
            self.source,
        )
        self.assertNotIn('MAC_PROCESS_IDENTITY="$AUTH_PRIVATE_DIR/', self.source)
        self.assertNotIn('IOS_PROCESS_IDENTITY="$AUTH_PRIVATE_DIR/', self.source)
        self.assertNotIn('IOS_LAUNCH_JSON="$AUTH_PRIVATE_DIR/', self.source)

        cleanup = self.function_body("destroy_process_ownership_session")
        self.assertIn('"$IOS_LAUNCH_JSON"', cleanup)
        self.assertIn('"$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-launch.raw.json"', cleanup)

        helper_source = (SCRIPT_DIR / "real_device_ios_process_ownership.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('chmod 0600 "$result_json"', helper_source)

    def test_mac_signals_use_audit_token_api_instead_of_pid_only_kill(self) -> None:
        helper_source = (SCRIPT_DIR / "webrtc_smoke_process_ownership.py").read_text(encoding="utf-8")

        self.assertIn("proc_signal_with_audittoken", helper_source)
        self.assertNotIn("os.kill(pid, signal_number)", helper_source)


class FileTransferSmokeSourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = FILE_TRANSFER_SMOKE_SCRIPT.read_text(encoding="utf-8")

    @classmethod
    def function_body(cls, name: str) -> str:
        match = re.search(rf"(?ms)^{re.escape(name)}\(\) \{{\n(.*?)^\}}\n", cls.source)
        if match is None:
            raise AssertionError(f"missing shell function: {name}")
        return match.group(1)

    def test_ios_launch_captures_exact_console_handle_before_returning_success(self) -> None:
        body = self.function_body("launch_ios_smoke_app")
        launch = body.index("skybridge_ios_start_console_launch")
        started = body.index("IOS_CONSOLE_HANDLE_STARTED=1", launch)
        capture = body.index("skybridge_ios_capture_console_handle", started)
        captured = body.index("IOS_CONSOLE_HANDLE_CAPTURED=1", capture)
        status = body.index("skybridge_ios_console_handle_status", captured)
        success = body.index("return 0", status)

        self.assertLess(launch, started)
        self.assertLess(started, capture)
        self.assertLess(capture, captured)
        self.assertLess(captured, status)
        self.assertLess(status, success)

    def test_cleanup_terminates_only_the_exact_launched_ios_process(self) -> None:
        cleanup = self.function_body("cleanup")
        terminate = self.function_body("terminate_ios_smoke_app")
        ownership_status = terminate.index("skybridge_ios_console_handle_status")
        signal_handle = terminate.index("skybridge_ios_signal_console_handle", ownership_status)
        wait_for_exit = terminate.index("skybridge_ios_wait_console_handle_exit", signal_handle)
        capture_result = terminate.index("skybridge_ios_capture_exited_console_identity", wait_for_exit)
        prove_absence = terminate.index("skybridge_ios_require_app_absent_after_handle_exit", capture_result)

        self.assertIn('[[ "$IOS_CONSOLE_HANDLE_STARTED" == "1" ]] && ! terminate_ios_smoke_app', cleanup)
        self.assertIn("exact-process-exit-unverified", cleanup)
        self.assertLess(ownership_status, signal_handle)
        self.assertLess(signal_handle, wait_for_exit)
        self.assertLess(wait_for_exit, capture_result)
        self.assertLess(capture_result, prove_absence)
        self.assertNotIn("device process terminate", terminate)
        self.assertNotIn("--pid", terminate)

    def test_ios_identity_has_an_independent_private_lifecycle(self) -> None:
        self.assertIn(
            'mktemp -d "${TMPDIR:-/tmp}/skybridge-file-transfer-process-ownership.',
            self.source,
        )
        self.assertIn(
            'IOS_PROCESS_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-process-identity.json"',
            self.source,
        )
        self.assertIn(
            'IOS_CONSOLE_HANDLE_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-console-handle-identity.json"',
            self.source,
        )
        self.assertIn("destroy_process_ownership_session", self.function_body("cleanup"))
        self.assertNotIn('IOS_PROCESS_IDENTITY="$ARTIFACT_DIR/', self.source)

    def test_macos_host_uses_shared_exact_ownership_for_launch_and_cleanup(self) -> None:
        cleanup = self.function_body("cleanup")
        self.assertIn(
            'MAC_PROCESS_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/mac-process-identity.json"',
            self.source,
        )
        self.assertIn("skybridge_mac_require_executable_absent", self.source)
        self.assertIn("skybridge_mac_wait_for_single_exact_process", self.source)
        self.assertIn("skybridge_mac_capture_owned_process", self.source)
        self.assertIn("skybridge_mac_terminate_owned_process", cleanup)
        self.assertNotIn('kill "$HOST_PID"', cleanup)
        self.assertNotIn("OPEN_ARGS=(-n", self.source)


class P2PRemoteSmokeSourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = P2P_REMOTE_SMOKE_SCRIPT.read_text(encoding="utf-8")

    @classmethod
    def function_body(cls, name: str) -> str:
        match = re.search(rf"(?ms)^{re.escape(name)}\(\) \{{\n(.*?)^\}}\n", cls.source)
        if match is None:
            raise AssertionError(f"missing shell function: {name}")
        return match.group(1)

    def test_launch_requires_preinstall_absence_and_captures_exact_console_handle(self) -> None:
        body = self.function_body("launch_ios_remote_smoke_app")
        absence = body.index("IOS_PREINSTALL_ABSENCE_PROVEN")
        launch = body.index("skybridge_ios_start_console_launch", absence)
        capture = body.index("skybridge_ios_capture_console_handle", launch)
        captured = body.index("IOS_CONSOLE_HANDLE_CAPTURED=1", capture)

        self.assertLess(absence, launch)
        self.assertLess(launch, capture)
        self.assertLess(capture, captured)
        self.assertIn("else\n      handle_status=$?", body)

    def test_disconnect_cleanup_proves_exact_exit_before_receipt(self) -> None:
        body = self.function_body("terminate_ios_remote_smoke_app_exact")
        status = body.index("skybridge_ios_console_handle_status")
        signal_handle = body.index("skybridge_ios_signal_console_handle", status)
        wait_for_exit = body.index("skybridge_ios_wait_console_handle_exit", signal_handle)
        capture_result = body.index("skybridge_ios_capture_exited_console_identity", wait_for_exit)
        prove_absence = body.index("skybridge_ios_require_app_absent_after_handle_exit", capture_result)
        receipt = body.index("write_ios_process_cleanup_receipt", prove_absence)

        self.assertLess(status, signal_handle)
        self.assertLess(signal_handle, wait_for_exit)
        self.assertLess(wait_for_exit, capture_result)
        self.assertLess(capture_result, prove_absence)
        self.assertLess(prove_absence, receipt)

    def test_rejected_launch_can_retry_only_after_handle_and_remote_absence_proof(self) -> None:
        launch = self.function_body("launch_ios_remote_smoke_app")
        finish = self.function_body("finish_failed_ios_console_launch_without_process")

        explicit_failure = launch.index("launch_result_indicates_explicit_failure")
        no_process_cleanup = launch.index(
            "finish_failed_ios_console_launch_without_process",
            explicit_failure,
        )
        exact_cleanup = launch.index(
            'terminate_ios_remote_smoke_app_exact "startup-exit"',
            no_process_cleanup,
        )
        self.assertLess(explicit_failure, no_process_cleanup)
        self.assertLess(no_process_cleanup, exact_cleanup)
        self.assertIn("handle_status != 1", finish)
        self.assertIn("skybridge_ios_wait_console_handle_exit", finish)
        self.assertIn("skybridge_ios_require_app_absent_after_handle_exit", finish)
        self.assertNotIn("write_ios_process_cleanup_receipt", finish)

    def test_no_remote_pid_or_unowned_console_signal_can_terminate_ios(self) -> None:
        self.assertNotIn("--terminate-existing", self.source)
        self.assertNotIn("device process terminate", self.source)
        self.assertNotIn('kill "$IOS_CONSOLE_PID"', self.source)
        self.assertNotIn("IOS_APP_PID", self.source)

    def test_notice_disconnect_is_bound_to_the_strict_approved_session(self) -> None:
        wait = self.function_body("wait_for_same_session_notice_disconnected")
        disconnect = self.function_body("wait_for_remote_control_notice_disconnected")

        self.assertIn('P2P_NOTICE_SESSION="$approved_session"', self.source)
        self.assertIn("check_p2p_notice_disconnect.py", wait)
        self.assertIn('"$P2P_NOTICE_SESSION"', wait)
        self.assertIn("wait_for_same_session_notice_disconnected", disconnect)
        self.assertNotIn("wait_for_file_pattern", disconnect)

    def test_all_macos_product_roles_use_private_exact_ownership(self) -> None:
        cleanup = self.function_body("cleanup")
        for identity_name in (
            "MAC_HOST_PROCESS_IDENTITY",
            "MAC_SOURCE_PROCESS_IDENTITY",
            "MAC_ONLINE_PROCESS_IDENTITY",
        ):
            self.assertIn(f'{identity_name}="$PROCESS_OWNERSHIP_PRIVATE_DIR/', self.source)
            self.assertIn(f'"${identity_name}"', cleanup)
        self.assertGreaterEqual(self.source.count("skybridge_mac_capture_owned_process"), 3)
        self.assertGreaterEqual(cleanup.count("skybridge_mac_terminate_owned_process"), 3)
        self.assertNotIn("terminate_stale_macos_smoke_hosts", self.source)
        self.assertNotIn("terminate_stale_macos_online_ipad_clients", self.source)
        self.assertNotRegex(self.source, r"(?m)^\s+-n\s*\\?$")

    def test_reverse_product_launch_stops_same_bundle_identity_host_first(self) -> None:
        transition = self.function_body("transition_to_mac_online_ipad_client")
        reverse_smoke = self.function_body("run_mac_online_ipad_button_smoke")

        source_stop = transition.index('"$MAC_SOURCE_PROCESS_IDENTITY"')
        host_stop = transition.index('"$MAC_HOST_PROCESS_IDENTITY"', source_stop)
        unregister = transition.index(
            "cleanup_macos_smoke_host_launch_services_registration", host_stop
        )
        restore = transition.index(
            "restore_canonical_macos_launch_services_registration_last", unregister
        )
        transition_call = reverse_smoke.index("transition_to_mac_online_ipad_client")
        product_build = reverse_smoke.index("build_macos_online_ipad_app", transition_call)

        self.assertLess(source_stop, host_stop)
        self.assertLess(host_stop, unregister)
        self.assertLess(unregister, restore)
        self.assertLess(transition_call, product_build)

    def test_launch_services_restore_obligation_survives_partial_cleanup(self) -> None:
        cleanup = self.function_body("cleanup")
        register_host = self.function_body("register_macos_smoke_host_app_bundle")
        register_online = self.function_body("register_macos_online_ipad_app_bundle")
        restore = self.function_body(
            "restore_canonical_macos_launch_services_registration_last"
        )

        self.assertIn("MAC_LAUNCH_SERVICES_RESTORE_REQUIRED=0", self.source)
        self.assertIn("MAC_LAUNCH_SERVICES_RESTORE_REQUIRED=1", register_host)
        self.assertIn("MAC_LAUNCH_SERVICES_RESTORE_REQUIRED=1", register_online)
        self.assertIn("MAC_LAUNCH_SERVICES_RESTORE_REQUIRED=0", restore)
        self.assertIn('"${MAC_LAUNCH_SERVICES_RESTORE_REQUIRED:-0}" == "1"', cleanup)


class MacOSReleaseReadinessSourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = MACOS_RELEASE_READINESS_SCRIPT.read_text(encoding="utf-8")

    def test_launch_smoke_is_single_instance_and_audit_token_owned(self) -> None:
        self.assertIn("skybridge_mac_require_executable_absent", self.source)
        self.assertIn("skybridge_mac_wait_for_single_exact_process", self.source)
        self.assertIn("skybridge_mac_capture_owned_process", self.source)
        self.assertIn("skybridge_mac_terminate_owned_process", self.source)
        self.assertIn('open -F -g "${app_path}"', self.source)
        self.assertNotIn('open -Fn -g "${app_path}"', self.source)
        self.assertNotIn('kill -TERM "${new_pid}"', self.source)
        self.assertNotIn('kill -KILL "${new_pid}"', self.source)


class CLIFailClosedTests(unittest.TestCase):
    def test_unexpected_helper_failure_is_not_reported_as_process_absence(self) -> None:
        with mock.patch.object(ownership, "mac_status", side_effect=RuntimeError("fixture")):
            status = ownership.main(["mac-status", "--identity", "/tmp/unused.json"])

        self.assertEqual(status, ownership.UNVERIFIABLE)
        self.assertNotEqual(status, ownership.ABSENT)

    def test_exact_executable_enumeration_failure_is_unverifiable(self) -> None:
        with mock.patch.object(
            ownership,
            "mac_exact_executable_pids",
            side_effect=RuntimeError("fixture"),
        ):
            status = ownership.main(
                ["mac-list-exact", "--expected-executable", "/bin/sleep"]
            )

        self.assertEqual(status, ownership.UNVERIFIABLE)


if __name__ == "__main__":
    unittest.main(verbosity=2)
