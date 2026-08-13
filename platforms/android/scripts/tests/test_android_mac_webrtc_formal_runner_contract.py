#!/usr/bin/env python3

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ANDROID_ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = ANDROID_ROOT.parents[1]
RUNNER_PATH = ANDROID_ROOT / "scripts/run_android_mac_webrtc_formal_smoke.sh"
VALIDATOR_PATH = ANDROID_ROOT / "scripts/validate_android_mac_webrtc_formal_evidence.py"
GRADLE_PATH = ANDROID_ROOT / "app/build.gradle.kts"
WORKFLOW_PATH = REPOSITORY_ROOT / ".github/workflows/android-release-quality.yml"
OFFERER_PATH = (
    ANDROID_ROOT
    / "app/src/androidTest/kotlin/com/skybridge/compass/android/webrtc/AppleReleaseInteropOffererAppInstrumentationTest.kt"
)
RUNNER = RUNNER_PATH.read_text(encoding="utf-8")
VALIDATOR = VALIDATOR_PATH.read_text(encoding="utf-8")
GRADLE = GRADLE_PATH.read_text(encoding="utf-8")
WORKFLOW = WORKFLOW_PATH.read_text(encoding="utf-8")


def bash_function(name: str) -> str:
    start = RUNNER.index(f"{name}() {{")
    end = RUNNER.index("\n}\n", start) + len("\n}\n")
    return RUNNER[start:end]


class MacFormalRunnerContractTests(unittest.TestCase):
    def test_apple_toolchain_probe_captures_complete_version_output(self) -> None:
        self.assertIn('xcode_version="$(xcodebuild -version)"', WORKFLOW)
        self.assertIn('swift_version="$(swift --version)"', WORKFLOW)
        self.assertIn('grep -Eq \'^Xcode 26\\.\' <<<"$xcode_version"', WORKFLOW)
        self.assertIn(
            'grep -Eq \'Swift version 6\\.3([ .]|$)\' <<<"$swift_version"',
            WORKFLOW,
        )
        self.assertNotIn("xcodebuild -version |", WORKFLOW)
        self.assertNotIn("swift --version |", WORKFLOW)

    def test_help_is_side_effect_free_and_documents_formal_boundary(self) -> None:
        result = subprocess.run(
            ["bash", str(RUNNER_PATH), "--help"],
            cwd=ANDROID_ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("overlay-installs the main APK", result.stdout)
        self.assertIn("not accepted as this formal evidence", result.stdout)

    def test_uses_dedicated_mac_test_package_and_existing_offerer_class(self) -> None:
        self.assertIn(
            'TEST_PACKAGE="com.skybridge.compass.debug.macwebrtc.test"', RUNNER
        )
        self.assertIn(
            'TEST_CLASS="com.skybridge.compass.android.webrtc.AppleReleaseInteropOffererAppInstrumentationTest"',
            RUNNER,
        )
        self.assertIn(
            '-PskybridgeMacWebRtcFormalTestApplicationId="$TEST_PACKAGE"', RUNNER
        )
        self.assertTrue(OFFERER_PATH.is_file())
        self.assertFalse(
            any(
                path.name == "MacReleaseInteropOffererAppInstrumentationTest.kt"
                for path in (ANDROID_ROOT / "app/src/androidTest").rglob("*.kt")
            )
        )

    def test_gradle_property_is_exact_and_mutually_exclusive(self) -> None:
        self.assertIn(
            'gradleProperty("skybridgeMacWebRtcFormalTestApplicationId")', GRADLE
        )
        self.assertIn(
            'configuredApplicationId == "com.skybridge.compass.debug.macwebrtc.test"',
            GRADLE,
        )
        self.assertRegex(
            GRADLE,
            r"listOfNotNull\(\s*nativePqcGateTestApplicationId,\s*"
            r"iosWebRtcSmokeTestApplicationId,\s*macWebRtcFormalTestApplicationId,\s*\)\.size <= 1",
        )

    def test_main_app_is_overlay_only_and_never_targeted_by_destructive_cleanup(self) -> None:
        self.assertIn(
            'install --no-streaming -r -t "$APP_APK"', RUNNER
        )
        self.assertNotRegex(
            RUNNER,
            r'"\$ADB_BIN"[^\n]*(?:uninstall|pm\s+clear|force-stop)[^\n]*"\$APP_PACKAGE"',
        )
        self.assertRegex(
            RUNNER,
            r'android_remove_owned_package\s+\\\s*\n\s*'
            r'"\$ADB_BIN" "\$DEVICE_SERIAL" "\$TEST_PACKAGE" "\$TEST_APK_SHA256"',
        )
        self.assertNotIn('android_remove_owned_package "$ADB_BIN" "$DEVICE_SERIAL" "$APP_PACKAGE"', RUNNER)

    def test_preoverlay_snapshot_precedes_overlay_and_postflight_repeats_it(self) -> None:
        preflight = RUNNER.index('collect_android_sensitive_snapshot "$SENSITIVE_BEFORE"')
        overlay = RUNNER.index('install --no-streaming -r -t "$APP_APK"')
        postflight = RUNNER.index('collect_android_sensitive_snapshot "$SENSITIVE_AFTER"')
        self.assertLess(preflight, overlay)
        self.assertLess(overlay, postflight)
        self.assertIn('cmp -s -- "$SENSITIVE_BEFORE" "$SENSITIVE_AFTER"', RUNNER)
        for preference in (
            "skybridge_p2p_identity.xml",
            "skybridge_pqc_keys.xml",
            "skybridge_peer_kem_keys.xml",
        ):
            self.assertIn(preference, RUNNER)
        self.assertIn('uid="$(id -u)"', RUNNER)
        self.assertIn("stat -c '%d:%i:%h:%s:%Y'", RUNNER)

    def test_manifest_is_validated_before_overlay_for_automatic_start(self) -> None:
        manifest_gate = RUNNER.index('python3 "$VALIDATOR" manifest')
        overlay = RUNNER.index('install --no-streaming -r -t "$APP_APK"')
        self.assertLess(manifest_gate, overlay)
        for action in (
            "MY_PACKAGE_REPLACED",
            "PACKAGE_REPLACED",
            "PACKAGE_CHANGED",
        ):
            self.assertIn(action, VALIDATOR)

    def test_requires_exact_samsung_api36_4k_binding(self) -> None:
        self.assertIn(
            'android_collect_samsung_4k_device_binding "$ADB_BIN" "$DEVICE_SERIAL"',
            RUNNER,
        )
        self.assertIn('"$(property_value "$DEVICE_BEFORE" sdk)" != "36"', RUNNER)
        self.assertIn('before["page_size"] != "4096"', VALIDATOR)
        self.assertIn('before["abi"] != "arm64-v8a"', VALIDATOR)

    def test_every_direct_adb_operation_is_bound_to_the_explicit_serial(self) -> None:
        invocations = re.findall(
            r'^\s*"\$ADB_BIN"\s+-s\s+"\$DEVICE_SERIAL"[^\n]*',
            RUNNER,
            re.MULTILINE,
        )
        self.assertGreaterEqual(len(invocations), 7)
        self.assertNotRegex(
            RUNNER,
            r'"\$ADB_BIN"\s+(?:shell|exec-out|install|uninstall|wait-for-device|get-state|get-serialno)\b',
        )
        self.assertNotIn("adb devices", RUNNER)
        self.assertNotIn("ANDROID_SERIAL", RUNNER)

    def test_instrumentation_arguments_are_encoded_for_the_remote_shell(self) -> None:
        self.assertIn(
            'shell "$(remote_shell_join "${ANDROID_ARGS[@]}")"',
            RUNNER,
        )
        self.assertNotIn('shell "${ANDROID_ARGS[@]}"', RUNNER)

    def test_test_install_has_no_replace_and_cleanup_requires_exact_digest(self) -> None:
        self.assertIn(
            'install --no-streaming -t "$TEST_APK"', RUNNER
        )
        self.assertNotIn(
            'install --no-streaming -r -t "$TEST_APK"', RUNNER
        )
        self.assertIn('TEST_PACKAGE_STATE="install_attempted"', RUNNER)
        self.assertIn('TEST_PACKAGE_STATE="owned"', RUNNER)
        self.assertRegex(
            RUNNER,
            r'android_require_exact_install_success_output\s+\\\s*\n\s*'
            r'"\$TEST_INSTALL_OUTPUT" "\$TEST_APK" "\$TEST_APK_BYTES"',
        )
        self.assertIn(
            '"$ADB_BIN" "$DEVICE_SERIAL" "$TEST_PACKAGE" "$TEST_APK_SHA256"',
            RUNNER,
        )
        self.assertIn("refusing uninstall", RUNNER)

    def test_token_and_code_are_files_not_secret_arguments_or_environment(self) -> None:
        self.assertIn('--token-file "$TOKEN_FILE"', RUNNER)
        self.assertIn('--connect-code-file "$CODE_FILE"', RUNNER)
        self.assertNotIn("SKYBRIDGE_BEARER_TOKEN", RUNNER)
        self.assertNotIn("SKYBRIDGE_ACCESS_TOKEN", RUNNER)
        self.assertNotIn("export TOKEN", RUNNER)
        self.assertRegex(
            RUNNER,
            r'private-copy\s+\\\s*\n\s*--kind token\s+\\\s*\n\s*'
            r'--maximum-bytes 16384',
        )
        self.assertRegex(RUNNER, r'private-create\s+\\\s*\n\s*--kind code')
        self.assertIn("O_EXCL", VALIDATOR)
        self.assertIn("O_NOFOLLOW", VALIDATOR)
        self.assertIn("st_nlink != 1", VALIDATOR)
        self.assertIn("os.fsync(directory_descriptor)", VALIDATOR)

    def test_host_contract_is_exact_responder_interface(self) -> None:
        self.assertIn('HOST_PRODUCT="FormalMacWebRTCHost"', RUNNER)
        for option in (
            "--signaling-wss-url",
            "--token-file",
            "--tenant-id",
            "--run-ref",
            "--android-to-mac-transfer-id",
            "--mac-to-android-transfer-id",
            "--connect-code-file",
            "--result-output",
        ):
            self.assertIn(option, RUNNER)
        self.assertNotIn("--code-output", RUNNER)
        self.assertIn("--disable-automatic-resolution", RUNNER)
        self.assertIn("git ls-files --error-unmatch Package.resolved", RUNNER)
        self.assertIn('--product "$HOST_PRODUCT"', RUNNER)

    def test_mac_child_uses_exact_pid_executable_and_audit_token_ownership(self) -> None:
        self.assertIn("mac-list-exact", RUNNER)
        self.assertIn("mac-capture", RUNNER)
        self.assertIn("mac-status", RUNNER)
        self.assertIn("mac-signal", RUNNER)
        self.assertIn('--expected-executable "$HOST_EXECUTABLE"', RUNNER)
        self.assertIn('HOST_OWNERSHIP_CAPTURED="true"', RUNNER)
        self.assertNotRegex(RUNNER, r"(?:pkill|killall)\s")

    def test_uncaptured_child_is_observed_without_any_signal(self) -> None:
        body = bash_function("wait_for_uncaptured_mac_child_exit")
        self.assertIn('kill -0 "$HOST_PID"', body)
        self.assertNotIn("mac-signal", body)
        self.assertNotRegex(body, r"kill\s+(?!--0\b|-0\b)")
        self.assertIn("refusing signals and preserving private files", body)
        self.assertLess(
            body.index('HOST_QUIESCENT="true"'),
            body.index("ownership cleanup remains failed"),
        )
        self.assertRegex(body, r'ownership cleanup remains failed" >&2\n\s*return 1')
        wait = bash_function("wait_for_mac_exit")
        self.assertIn(
            '$(((HOST_TIMEOUT_SECONDS + HOST_HOLD_SECONDS + 60) * 4))', wait
        )

    def test_source_apk_and_host_binary_are_frozen_pre_and_post(self) -> None:
        self.assertGreaterEqual(RUNNER.count("skybridge_require_frozen_git_source"), 3)
        self.assertIn("android_require_apk_provenance_unchanged", RUNNER)
        self.assertIn('cmp -s -- "$HOST_PROVENANCE_BEFORE" "$HOST_PROVENANCE_AFTER"', RUNNER)
        self.assertIn('cmp -s -- "$INSTALLED_BEFORE" "$INSTALLED_AFTER"', RUNNER)

    def test_receipt_is_from_typed_json_and_not_append_status(self) -> None:
        self.assertIn('--mac-result "$MAC_RESULT"', RUNNER)
        self.assertIn('payload = validate_receipt(arguments)', VALIDATOR)
        self.assertNotIn("mac-status.log", RUNNER)
        self.assertNotRegex(RUNNER, r"grep[^\n]*mac-formal-result")
        self.assertIn('set(result) != expected', VALIDATOR)
        self.assertIn('object_pairs_hook=_unique_json_object', VALIDATOR)
        self.assertIn('result.get("outcome") != "success"', VALIDATOR)

    def test_receipt_requires_same_run_session_suite_ice_and_canonical_payloads(self) -> None:
        self.assertIn('session_ref != android["sessionRef"]', VALIDATOR)
        self.assertIn('result.get("suiteWireId") != EXPECTED_SUITE_WIRE_ID', VALIDATOR)
        self.assertIn('selected["localCandidateType"] not in candidate_types', VALIDATOR)
        self.assertIn('selected["remoteCandidateType"] not in candidate_types', VALIDATOR)
        self.assertIn('selected["protocol"] not in {"udp", "tcp"}', VALIDATOR)
        self.assertIn('value["durableCommit"] is not True', VALIDATOR)
        self.assertIn('value["completeAck"] is not True', VALIDATOR)
        self.assertIn('formal bidirectional transfer identifiers must be distinct', VALIDATOR)

    def test_cleanup_is_quiescence_gated_and_only_removes_owned_artifacts(self) -> None:
        self.assertIn('ANDROID_QUIESCENT="false"', RUNNER)
        self.assertIn('HOST_QUIESCENT="false"', RUNNER)
        self.assertIn('if [[ "$ANDROID_QUIESCENT" == "true"', RUNNER)
        self.assertIn('if [[ "$HOST_QUIESCENT" == "true"', RUNNER)
        self.assertIn("exact opened private inode was not unlinked", VALIDATOR)
        self.assertIn('MAC_RUN_PAYLOAD_DIR="${HOME:?}/Library/Caches/com.skybridge.formal-interop/$RUN_REF"', RUNNER)
        self.assertIn('MAC_PAYLOAD_CLEANUP_VERIFIED="true"', RUNNER)
        self.assertIn('--mac-payload-cleanup-verified "$MAC_PAYLOAD_CLEANUP_VERIFIED"', RUNNER)
        cleanup = RUNNER.index("remove_android_context \\")
        sensitive_after = RUNNER.index('collect_android_sensitive_snapshot "$SENSITIVE_AFTER"')
        receipt = RUNNER.index('python3 "$VALIDATOR" receipt')
        self.assertLess(cleanup, sensitive_after)
        self.assertLess(sensitive_after, receipt)

    def test_acceptance_receipt_is_published_only_after_all_required_cleanup(self) -> None:
        self.assertIn('--output "$RECEIPT_CANDIDATE"', RUNNER)
        self.assertNotIn('--output "$RECEIPT" \\', RUNNER)
        receipt_validation = RUNNER.index('python3 "$VALIDATOR" receipt')
        lock_release = RUNNER.index("release_device_lock_after_quiescence", receipt_validation)
        publish = RUNNER.index(
            'mv -f -- "$RECEIPT_CANDIDATE" "$RECEIPT"',
            lock_release,
        )
        summary = RUNNER.index('echo "status=success"', publish)
        self.assertLess(receipt_validation, lock_release)
        self.assertLess(lock_release, publish)
        self.assertLess(publish, summary)

    def test_no_global_gradle_daemon_cleanup_is_attempted(self) -> None:
        self.assertNotIn("--stop", RUNNER)

    def test_capture_failure_wait_precedes_every_secret_cleanup(self) -> None:
        cleanup = RUNNER[
            RUNNER.index("cleanup() {") : RUNNER.index("\nfail_run() {")
        ]
        wait = cleanup.index('wait_for_mac_exit || cleanup_failed="true"')
        private_cleanup = cleanup.index(
            'cleanup_host_private_files || cleanup_failed="true"'
        )
        self.assertLess(wait, private_cleanup)
        self.assertIn(
            '"$ANDROID_QUIESCENT" == "true" && "$HOST_QUIESCENT" == "true"',
            cleanup,
        )
        self.assertIn(
            'release_device_lock_after_quiescence || cleanup_failed="true"', cleanup
        )
        self.assertIn(
            '"$ANDROID_QUIESCENT" != "true" || "$HOST_QUIESCENT" != "true"',
            bash_function("release_device_lock_after_quiescence"),
        )
        private_body = bash_function("cleanup_host_private_files")
        self.assertLess(
            private_body.index('"$HOST_QUIESCENT" != "true"'),
            private_body.index('unlink_private "$CODE_FILE"'),
        )

    def test_device_lock_remains_held_until_both_sides_are_quiescent(self) -> None:
        function = bash_function("release_device_lock_after_quiescence")
        result = subprocess.run(
            [
                "bash",
                "-c",
                f"""
set -euo pipefail
{function}
release_count=0
skybridge_release_device_lock() {{ release_count=$((release_count + 1)); }}
DEVICE_LOCK=/tmp/formal-device-lock
ANDROID_QUIESCENT=false
HOST_QUIESCENT=true
set +e
release_device_lock_after_quiescence
status=$?
set -e
test "$status" -eq 1
test "$release_count" -eq 0
test "$DEVICE_LOCK" = /tmp/formal-device-lock
ANDROID_QUIESCENT=true
release_device_lock_after_quiescence
test "$release_count" -eq 1
test -z "$DEVICE_LOCK"
""",
            ],
            cwd=ANDROID_ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Android/macOS quiescence is unproven", result.stderr)

    def test_invalid_wss_fails_before_run_directory_or_token_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            nonexistent_run = Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    "bash",
                    str(RUNNER_PATH),
                    "--device",
                    "fake-serial",
                    "--signaling-wss-url",
                    "ws://127.0.0.1/ws",
                    "--token-file",
                    str(Path(temporary) / "missing-token"),
                    "--tenant-id",
                    "tenant",
                    "--expected-source-commit",
                    "a" * 40,
                    "--run-dir",
                    str(nonexistent_run),
                ],
                cwd=ANDROID_ROOT,
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("wss URL", result.stderr)
            self.assertFalse(nonexistent_run.exists())

    def test_inherited_smoke_diagnostics_fail_before_run_directory_creation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            nonexistent_run = Path(temporary) / "must-not-exist"
            environment = os.environ.copy()
            environment["SKYBRIDGE_SMOKE_ROLE"] = "host"
            result = subprocess.run(
                [
                    "bash",
                    str(RUNNER_PATH),
                    "--device",
                    "fake-serial",
                    "--signaling-wss-url",
                    "wss://signal.example.invalid/ws",
                    "--token-file",
                    str(Path(temporary) / "missing-token"),
                    "--tenant-id",
                    "tenant",
                    "--expected-source-commit",
                    "a" * 40,
                    "--run-dir",
                    str(nonexistent_run),
                ],
                cwd=ANDROID_ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refuses inherited SKYBRIDGE_SMOKE_*", result.stderr)
            self.assertFalse(nonexistent_run.exists())


class UncapturedMacChildCleanupTests(unittest.TestCase):
    def run_harness(
        self,
        body: str,
        *,
        timeout: float = 5,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        process_environment = os.environ.copy()
        if environment is not None:
            process_environment.update(environment)
        return subprocess.run(
            ["bash", "-c", body],
            cwd=ANDROID_ROOT,
            env=process_environment,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def test_capture_failure_waits_for_natural_direct_child_exit(self) -> None:
        function = bash_function("wait_for_uncaptured_mac_child_exit")
        result = self.run_harness(
            f"""
set -euo pipefail
{function}
HOST_STARTED=true
HOST_OWNERSHIP_CAPTURED=false
HOST_QUIESCENT=false
(sleep 0.1; exit 7) &
HOST_PID=$!
set +e
wait_for_uncaptured_mac_child_exit 20
status=$?
set -e
printf 'status=%s pid=%s quiescent=%s\n' "$status" "$HOST_PID" "$HOST_QUIESCENT"
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "status=1 pid= quiescent=true\n")
        self.assertIn("exited naturally with status 7", result.stderr)
        self.assertIn("cleanup remains failed", result.stderr)

    def test_capture_failure_timeout_leaves_live_child_and_private_state(self) -> None:
        function = bash_function("wait_for_uncaptured_mac_child_exit")
        result = self.run_harness(
            f"""
set -euo pipefail
{function}
HOST_STARTED=true
HOST_OWNERSHIP_CAPTURED=false
HOST_QUIESCENT=false
(sleep 0.8) &
HOST_PID=$!
child_pid="$HOST_PID"
set +e
wait_for_uncaptured_mac_child_exit 1
status=$?
set -e
kill -0 "$child_pid"
test "$HOST_PID" = "$child_pid"
test "$HOST_QUIESCENT" = false
printf 'status=%s live=true quiescent=%s\n' "$status" "$HOST_QUIESCENT"
wait "$child_pid"
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "status=2 live=true quiescent=false\n")
        self.assertIn("refusing signals", result.stderr)
        self.assertIn("preserving private files", result.stderr)

    def test_private_cleanup_runs_only_after_child_quiescence(self) -> None:
        function = bash_function("cleanup_host_private_files")
        with tempfile.TemporaryDirectory() as temporary:
            result = self.run_harness(
                f"""
set -euo pipefail
{function}
CODE_FILE="$FAKE_PRIVATE_ROOT/code"
CODE_PROPERTIES="$FAKE_PRIVATE_ROOT/code.properties"
AUTH_CONTEXT="$FAKE_PRIVATE_ROOT/auth"
AUTH_CONTEXT_PROVENANCE="$FAKE_PRIVATE_ROOT/auth.properties"
TOKEN_FILE="$FAKE_PRIVATE_ROOT/token"
TOKEN_PROPERTIES="$FAKE_PRIVATE_ROOT/token.properties"
TRACE="$FAKE_PRIVATE_ROOT/trace"
touch "$CODE_FILE" "$CODE_PROPERTIES" "$AUTH_CONTEXT" \
  "$AUTH_CONTEXT_PROVENANCE" "$TOKEN_FILE" "$TOKEN_PROPERTIES"
unlink_private() {{
  printf '%s\n' "$1" >>"$TRACE"
  unlink "$1"
}}
PRIVATE_FILE_CLEANUP_VERIFIED=false
HOST_QUIESCENT=false
set +e
cleanup_host_private_files
blocked_status=$?
set -e
test "$blocked_status" = 1
test ! -e "$TRACE"
test -e "$CODE_FILE"
test -e "$AUTH_CONTEXT"
test -e "$TOKEN_FILE"
HOST_QUIESCENT=true
cleanup_host_private_files
test "$PRIVATE_FILE_CLEANUP_VERIFIED" = true
test "$(wc -l <"$TRACE" | tr -d ' ')" = 3
printf 'blocked=%s cleaned=true\n' "$blocked_status"
""",
                environment={"FAKE_PRIVATE_ROOT": temporary},
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "blocked=1 cleaned=true\n")
        self.assertIn("quiescence is unproven", result.stderr)


class FakeAdbBindingTests(unittest.TestCase):
    def test_device_binding_uses_only_the_explicit_fake_serial(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = root / "adb.log"
            adb = root / "adb"
            adb.write_text(
                """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_ADB_LOG"
test "$1" = -s
test "$2" = exact-samsung
shift 2
case "$1:${2-}" in
  get-state:) echo device ;;
  get-serialno:) echo exact-samsung ;;
  shell:getprop)
    case "$3" in
      ro.product.manufacturer) echo Samsung ;;
      ro.product.model) echo SM-S948U ;;
      ro.build.version.release) echo 16 ;;
      ro.build.version.sdk) echo 36 ;;
      ro.product.cpu.abi) echo arm64-v8a ;;
      ro.kernel.qemu) echo 0 ;;
      *) exit 2 ;;
    esac
    ;;
  shell:getconf) test "$3" = PAGESIZE; echo 4096 ;;
  *) exit 2 ;;
esac
""",
                encoding="utf-8",
            )
            adb.chmod(0o700)
            command = f"""
set -euo pipefail
source {str(ANDROID_ROOT / 'scripts/lib/android_env.sh')!r}
android_collect_samsung_4k_device_binding {str(adb)!r} exact-samsung
"""
            environment = os.environ.copy()
            environment["FAKE_ADB_LOG"] = str(log)
            result = subprocess.run(
                ["bash", "-c", command],
                cwd=ANDROID_ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("profile=samsung-physical-4k", result.stdout)
            self.assertIn("sdk=36", result.stdout)
            commands = log.read_text().splitlines()
            self.assertGreaterEqual(len(commands), 9)
            self.assertTrue(all(command.startswith("-s exact-samsung ") for command in commands))


if __name__ == "__main__":
    unittest.main()
