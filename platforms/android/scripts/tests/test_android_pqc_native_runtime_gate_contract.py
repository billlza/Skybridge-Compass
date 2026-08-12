#!/usr/bin/env python3
"""Static contract tests for the exact-device native-PQC gate runner."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts/run_android_pqc_native_runtime_gate.sh"
INSTRUMENTATION = (
    ROOT
    / "app/src/androidTest/kotlin/com/skybridge/compass/android/crypto/"
    "NativePqcRuntimeInstrumentationTest.kt"
)


class NativePqcRuntimeGateContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.runner = RUNNER.read_text(encoding="utf-8")
        cls.instrumentation = INSTRUMENTATION.read_text(encoding="utf-8")

    def test_runner_builds_one_canonical_pair_and_only_uses_exact_serials(self) -> None:
        self.assertNotRegex(self.runner, re.compile(r"(?m)^\s*--app-apk(?:\)|\s)"))
        self.assertNotRegex(self.runner, re.compile(r"(?m)^\s*--test-apk(?:\)|\s)"))
        self.assertIn("app/build/outputs/apk/debug/app-debug.apk", self.runner)
        self.assertIn(
            "app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk",
            self.runner,
        )
        self.assertIn(
            'TEST_PACKAGE="com.skybridge.compass.debug.nativepqc.test"',
            self.runner,
        )
        self.assertIn(
            '-PskybridgeNativePqcGateTestApplicationId="$TEST_PACKAGE"',
            self.runner,
        )
        fixed_build = re.compile(
            r'"\$GRADLEW"\s+.*?--rerun-tasks\s+.*?--warning-mode all\s+'
            r'.*?-PskybridgeNativePqcGateTestApplicationId="\$TEST_PACKAGE"\s+'
            r':app:assembleDebug\s+:app:assembleDebugAndroidTest',
            re.DOTALL,
        )
        self.assertRegex(self.runner.replace("\\\n", " "), fixed_build)
        self.assertIn("skybridge_require_zero_warning_tool_log", self.runner)
        self.assertIn('"$GRADLEW" --stop', self.runner)
        self.assertIn("acquire_lane_lock", self.runner)
        self.assertIn("--git-common-dir", self.runner)
        self.assertIn("skybridge-native-pqc-runtime.lock", self.runner)
        self.assertIn('rmdir "$LANE_LOCK_DIR"', self.runner)
        lock_release = self.runner.index(
            'release_lane_lock || fail "native-PQC repository lane lock release failed"',
        )
        session_complete = self.runner.index("SESSION_COMPLETE=1", lock_release)
        success_message = self.runner.index(
            "Android native PQC runtime matrix passed",
            session_complete,
        )
        self.assertLess(lock_release, session_complete)
        self.assertLess(session_complete, success_message)
        self.assertIn('export ANDROID_HOME="$GRADLE_SDK_ROOT"', self.runner)
        self.assertIn('export ANDROID_SDK_ROOT="$GRADLE_SDK_ROOT"', self.runner)
        self.assertIn('install --no-streaming -r -t "$APP_APK"', self.runner)
        self.assertIn('install --no-streaming -r -t "$TEST_APK"', self.runner)
        self.assertIn('"$ADB_BIN" -s "$serial"', self.runner)
        adb_invocations = re.findall(
            r'(?m)^\s*(?:if ! )?"\$ADB_BIN"[^\n]*',
            self.runner,
        )
        self.assertGreater(len(adb_invocations), 0)
        self.assertTrue(
            all('"$ADB_BIN" -s "$serial"' in invocation for invocation in adb_invocations),
        )
        self.assertIn("the two runtime profiles require distinct serials", self.runner)
        self.assertNotIn("${manufacturer,,}", self.runner)
        self.assertIn("manufacturer normalization failed", self.runner)

    def test_runner_rechecks_clean_commit_after_the_fixed_build(self) -> None:
        pre_build = self.runner.index('require_frozen_source "pre-build verification"')
        build = self.runner.index(":app:assembleDebugAndroidTest")
        post_build = self.runner.index('require_frozen_source "post-build verification"')
        self.assertLess(pre_build, build)
        self.assertLess(build, post_build)
        self.assertIn("canonical APK output path", self.runner)

        device_matrix = self.runner.index(
            'run_profile "api37-16k" "$API37_SERIAL" 37 16384 "$API37_ABI" 0',
        )
        post_device = self.runner.index('require_frozen_source "post-device verification"')
        provenance_recheck = self.runner.index("require_apk_provenance_unchanged", post_device)
        evidence = self.runner.index('python3 "$VALIDATOR"', provenance_recheck)
        self.assertLess(device_matrix, post_device)
        self.assertLess(post_device, provenance_recheck)
        self.assertLess(provenance_recheck, evidence)

    def test_runner_preserves_target_app_data_and_bounds_test_cleanup(self) -> None:
        destructive_target_patterns = (
            r'uninstall[^\n]*"\$APP_PACKAGE"',
            r'pm clear[^\n]*"\$APP_PACKAGE"',
            r'for\s+package_name\s+in[^\n]*"\$APP_PACKAGE"',
        )
        for pattern in destructive_target_patterns:
            self.assertNotRegex(self.runner, pattern)
        self.assertIn('install --no-streaming -r -t "$APP_APK"', self.runner)
        self.assertIn('uninstall "$TEST_PACKAGE"', self.runner)
        self.assertNotIn("TEST_PACKAGE_TOUCHED", self.runner)
        self.assertNotIn("best_effort_remove_test_package", self.runner)
        self.assertIn('SAMSUNG_TEST_PACKAGE_STATE="untouched"', self.runner)
        self.assertIn('API37_TEST_PACKAGE_STATE="untouched"', self.runner)
        self.assertIn("test package existed before this run", self.runner)
        self.assertIn('"$query_status" == "1" && ! -s "$output"', self.runner)
        self.assertIn('"$query_status" == "1" && ! -s "$path_output"', self.runner)
        self.assertIn('"$query_status" == "1" && ! -s "$verify_output"', self.runner)
        self.assertIn("ownership_ambiguous", self.runner)
        self.assertIn("refusing uninstall", self.runner)

        profile_start = self.runner.index("run_profile() {")
        profile_end = self.runner.index(
            'require_test_package_absent "samsung-api36-4k"',
            profile_start,
        )
        profile = self.runner[profile_start:profile_end]
        app_install = profile.index('install --no-streaming -r -t "$APP_APK"')
        install_boundary = profile.index(
            'require_test_package_absent "$profile" "$serial" "test install boundary"',
        )
        attempted = profile.index('set_test_package_state "$serial" install_attempted')
        test_install = profile.index('install --no-streaming -r -t "$TEST_APK"')
        test_digest = profile.index(
            'require_installed_apk_digest "$profile" "$serial" "$TEST_PACKAGE"',
        )
        owned = profile.index('set_test_package_state "$serial" owned_installed')
        normal_cleanup = profile.index(
            'reconcile_and_remove_run_test_package "$profile" "$serial" "normal completion"',
        )
        self.assertLess(app_install, install_boundary)
        self.assertLess(install_boundary, attempted)
        self.assertLess(attempted, test_install)
        self.assertLess(test_install, test_digest)
        self.assertLess(test_digest, owned)
        self.assertLess(owned, normal_cleanup)

        samsung_preflight = self.runner.index(
            'require_test_package_absent "samsung-api36-4k" "$SAMSUNG_SERIAL" "matrix preflight"',
        )
        api37_preflight = self.runner.index(
            'require_test_package_absent "api37-16k" "$API37_SERIAL" "matrix preflight"',
        )
        samsung_run = self.runner.index(
            'run_profile "samsung-api36-4k" "$SAMSUNG_SERIAL"',
        )
        self.assertLess(samsung_preflight, api37_preflight)
        self.assertLess(api37_preflight, samsung_run)

    def test_runner_checks_device_and_installed_apk_identity(self) -> None:
        for required in (
            "get-serialno",
            "ro.build.version.sdk",
            "getconf PAGE_SIZE",
            "ro.product.cpu.abi",
            "ro.product.manufacturer",
            "ro.kernel.qemu",
            "shell sha256sum",
            "shell pm list instrumentation",
            "source revision changed or does not match",
            "clean frozen source tree",
            "app APK does not contain the exact required native PQC ABI set",
        ):
            self.assertIn(required, self.runner)
        self.assertNotIn("QPeriapt_16K_API_35", self.runner)
        self.assertNotIn("SkyBridge_16K_API_37", self.runner)

    def test_instrumentation_reuses_provider_and_clears_retained_material(self) -> None:
        for required in (
            "AndroidPQCCryptoProvider",
            "provider.generateKeyPair(KeyUsage.KEY_EXCHANGE)",
            "provider.encapsulate",
            "provider.decapsulate",
            "provider.generateKeyPair(KeyUsage.SIGNING)",
            "provider.sign",
            "provider.verify",
            "kemKeyPair?.clear()",
            "signingKeyPair?.clear()",
            "mldsa_negative_message=",
            "mldsa_negative_signature=",
            "sendStatus(",
            "RESULT_STATUS_STREAM_KEY",
        ):
            self.assertIn(required, self.instrumentation)
        for forbidden in (
            "Base64",
            "deviceId",
            "ciphertext.contentToString",
            "signature.contentToString",
            "privateKey.bytes.contentToString",
            "println(",
        ):
            self.assertNotIn(forbidden, self.instrumentation)


if __name__ == "__main__":
    unittest.main()
