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
        fixed_build = re.compile(
            r'"\$GRADLEW"\s+.*?--rerun-tasks\s+.*?--warning-mode all\s+'
            r':app:assembleDebug\s+:app:assembleDebugAndroidTest',
            re.DOTALL,
        )
        self.assertRegex(self.runner.replace("\\\n", " "), fixed_build)
        self.assertIn("skybridge_require_zero_warning_tool_log", self.runner)
        self.assertIn('"$GRADLEW" --stop', self.runner)
        self.assertIn('export ANDROID_HOME="$GRADLE_SDK_ROOT"', self.runner)
        self.assertIn('export ANDROID_SDK_ROOT="$GRADLE_SDK_ROOT"', self.runner)
        self.assertIn('install --no-streaming -r -t "$APP_APK"', self.runner)
        self.assertIn('install --no-streaming -r -t "$TEST_APK"', self.runner)
        self.assertIn('"$ADB_BIN" -s "$serial"', self.runner)
        adb_invocations = re.findall(r'(?m)^\s*"\$ADB_BIN"[^\n]*', self.runner)
        self.assertGreater(len(adb_invocations), 0)
        self.assertTrue(
            all(invocation.lstrip().startswith('"$ADB_BIN" -s "$serial"') for invocation in adb_invocations),
        )
        self.assertIn("the two runtime profiles require distinct serials", self.runner)

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
        self.assertIn("SAMSUNG_TEST_PACKAGE_TOUCHED=0", self.runner)
        self.assertIn("API37_TEST_PACKAGE_TOUCHED=0", self.runner)
        self.assertIn('if [[ "$SAMSUNG_TEST_PACKAGE_TOUCHED" == "1" ]]', self.runner)
        self.assertIn('if [[ "$API37_TEST_PACKAGE_TOUCHED" == "1" ]]', self.runner)

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
        ):
            self.assertIn(required, self.instrumentation)
        for forbidden in (
            "Base64",
            "deviceId",
            "ciphertext.contentToString",
            "signature.contentToString",
            "privateKey.bytes.contentToString",
        ):
            self.assertNotIn(forbidden, self.instrumentation)


if __name__ == "__main__":
    unittest.main()
