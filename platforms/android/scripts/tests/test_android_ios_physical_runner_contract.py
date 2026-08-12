#!/usr/bin/env python3
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNNER = (ROOT / "scripts/run_android_ios_webrtc_offer_smoke.sh").read_text(encoding="utf-8")
OFFERER = (
    ROOT
    / "app/src/androidTest/kotlin/com/skybridge/compass/android/webrtc/AppleReleaseInteropOffererAppInstrumentationTest.kt"
).read_text(encoding="utf-8")
MANAGER = (
    ROOT
    / "core/src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt"
).read_text(encoding="utf-8")
IOS_APP = (
    ROOT.parent.parent
    / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift"
).read_text(encoding="utf-8")
IOS_MANAGER = (
    ROOT.parent.parent
    / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
).read_text(encoding="utf-8")


class PhysicalRunnerContractTests(unittest.TestCase):
    def test_physical_target_is_explicit_and_has_no_external_helper_root(self) -> None:
        self.assertIn("--ios-target simulator|physical", RUNNER)
        self.assertIn("Physical iOS smoke requires both --ios-device-id and --ios-device-udid", RUNNER)
        self.assertNotIn("--apple-tools-root", RUNNER)
        self.assertIn('PROCESS_OWNERSHIP_HELPER="$ROOT_DIR/scripts/lib/', RUNNER)

    def test_physical_install_is_overlay_and_never_uninstalls_ios_app(self) -> None:
        self.assertIn("device install app", RUNNER)
        self.assertIn("overlay-preserve-data", RUNNER)
        self.assertNotIn("device uninstall app", RUNNER)
        self.assertNotIn("device process terminate", RUNNER)
        self.assertIn("android_require_package_process_absent", RUNNER)
        self.assertIn("Run directory must be a new, non-symbolic path", RUNNER)
        self.assertIn("mktemp -d", RUNNER)
        execution = RUNNER.index(
            'android_require_package_process_absent \\\n'
            '    "$ADB_BIN" "$DEVICE_SERIAL" "com.skybridge.compass.debug" \\\n'
            '    || fail_summary "android_process" '
            '"preexisting_android_app_process_before_install"'
        )
        main_install = RUNNER.index(
            '"$ADB_BIN" -s "$DEVICE_SERIAL" install --no-streaming -r -t "$APP_APK"'
        )
        self.assertLess(execution, main_install)
        test_install = RUNNER.index(
            '"$ADB_BIN" -s "$DEVICE_SERIAL" install --no-streaming -t "$TEST_APK"'
        )
        self.assertNotIn(
            'install --no-streaming -r -t "$TEST_APK"',
            RUNNER[main_install : test_install + 120],
        )
        owned = RUNNER.index('ANDROID_TEST_PACKAGE_STATE="owned_installed"', test_install)
        success_check = RUNNER.index(
            "android_require_exact_install_success_output", test_install
        )
        self.assertLess(success_check, owned)
        self.assertIn('"$TEST_INSTALL_OUTPUT"', RUNNER[success_check:owned])
        self.assertIn('"$TEST_APK_BYTES"', RUNNER[success_check:owned])
        self.assertNotIn("TEST_INSTALL_SUCCESS_COUNT", RUNNER)
        ambiguous_cleanup = RUNNER.index(
            "Test package appeared after an ambiguous install attempt; refusing uninstall"
        )
        self.assertLess(ambiguous_cleanup, test_install)

    def test_physical_signaling_and_child_environment_fail_closed(self) -> None:
        self.assertIn("Physical iOS smoke requires wss signaling", RUNNER)
        self.assertIn("DEVICECTL_CHILD_SKYBRIDGE_SMOKE_EXISTING_TRUST_ONLY=1", RUNNER)
        self.assertIn('DEVICECTL_CHILD_SKYBRIDGE_SMOKE_REQUIRE_PQC="$(if [[ "$PQC_ENABLED" == "true" ]]', RUNNER)
        self.assertNotIn("--environment-variables", RUNNER)
        physical_body = RUNNER.split('if [[ "$IOS_TARGET" == "physical" ]]; then', 1)[1]
        self.assertNotIn("logcat -c", physical_body.split("else", 1)[0])
        self.assertIn("unset SKYBRIDGE_BEARER_TOKEN SKYBRIDGE_ACCESS_TOKEN", RUNNER)
        self.assertIn("math.isfinite(float(issued_at))", RUNNER)
        self.assertIn("math.isfinite(float(expires_at))", RUNNER)

    def test_physical_lane_fixes_the_instrumentation_and_launch_identity(self) -> None:
        self.assertIn('if [[ "$CLASS_NAME" != "$DEFAULT_APP_CLASS" ]]; then', RUNNER)
        self.assertIn("Physical iOS formal smoke requires --expect-file-transfer true", RUNNER)
        self.assertIn("Physical iOS formal smoke requires exact ML-KEM-768 PQC policy", RUNNER)
        self.assertIn('[[ "$PQC_MINIMUM_TIER" != "nativePQC" ]]', RUNNER)
        self.assertIn('[[ "$EXPECTED_NEGOTIATED_SUITE" != "MLKEM_768" ]]', RUNNER)
        self.assertIn('DEVICECTL_CHILD_SB_PQC_PREFERRED_SUITE="mlkem"', RUNNER)
        self.assertIn('DEVICECTL_CHILD_SKYBRIDGE_SMOKE_EXPECTED_SUITE_WIRE_ID="0x0101"', RUNNER)
        self.assertIn("skybridgeExpectBidirectionalFileTransfer true", RUNNER)
        self.assertIn("skybridgeAndroidToPeerTransferId", RUNNER)
        self.assertIn("skybridgePeerToAndroidTransferId", RUNNER)
        self.assertIn("DEVICECTL_CHILD_SKYBRIDGE_SMOKE_EXPECT_BIDIRECTIONAL_FILE_TRANSFER=1", RUNNER)
        self.assertIn("DEVICECTL_CHILD_SKYBRIDGE_SMOKE_EXPECT_HANDSHAKE_ONLY=0", RUNNER)
        self.assertIn("SIMCTL_CHILD_SKYBRIDGE_SMOKE_EXPECT_HANDSHAKE_ONLY=1", RUNNER)
        self.assertTrue('IOS_LAUNCH_PERSISTENT_IDENTIFIER="$(' in RUNNER)
        launch = RUNNER.split("skybridge_ios_start_console_launch \\\n", 1)[1]
        self.assertTrue(
            launch.startswith(
                '    "$IOS_DEVICE_ID" "$IOS_BUNDLE_ID" "$IOS_LAUNCH_PERSISTENT_IDENTIFIER" \\\n'
            )
        )

    def test_android_formal_identity_is_target_read_only_and_runtime_is_test_scoped(self) -> None:
        self.assertIn("instrumentation.context.applicationContext", OFFERER)
        self.assertIn("instrumentation.targetContext.applicationContext", OFFERER)
        self.assertIn("StorageMode.ENCRYPTED_EXISTING_ONLY", OFFERER)
        self.assertIn("PeerKemKeyStore.existingReadOnly(identityContext)", OFFERER)
        self.assertIn("existingTrustOnly = useDedicatedTestStorage", OFFERER)
        self.assertIn("formal diagnostic requires exact existing peer trust", MANAGER)
        self.assertIn("loadVerifiedReadOnly(peerId)", MANAGER)
        baseline = OFFERER.index("val sensitiveStateBefore = if (useDedicatedTestStorage)")
        first_identity_access = OFFERER.index("val localIdentity = LocalP2PIdentity(")
        self.assertLess(baseline, first_identity_access)
        self.assertEqual(OFFERER.count('updateField("xwing-public"'), 0)
        symlink_check = OFFERER.index("Files.isSymbolicLink(file.toPath())")
        canonicalize = OFFERER.index("val canonicalFile = file.canonicalFile")
        self.assertLess(symlink_check, canonicalize)
        self.assertIn("InboundFileDestinationPolicy.APP_PRIVATE_DURABLE", OFFERER)
        self.assertIn("CoroutineStart.UNDISPATCHED", OFFERER)
        self.assertIn("androidRunOwnedPayloadCleaned", OFFERER)

    def test_ios_history_and_run_payloads_are_part_of_the_freeze_contract(self) -> None:
        self.assertIn("transfer_history", RUNNER)
        self.assertIn("SkyBridgeState/FileTransfer/history.json", RUNNER)
        self.assertIn('IOS_COPY_ABSENCE_VALIDATOR="$ROOT_DIR/scripts/validate_ios_copy_absence.py"', RUNNER)
        self.assertIn('"$copy_json" "${sources[$index]}"', RUNNER)
        self.assertNotIn('if [[ "${labels[$index]}" == "transfer_history" ]]; then', RUNNER)
        self.assertNotIn("device uninstall app", RUNNER)
        physical_launch = RUNNER.index(
            "DEVICECTL_CHILD_SKYBRIDGE_SMOKE_EXPECT_BIDIRECTIONAL_FILE_TRANSFER=1"
        )
        self.assertGreater(physical_launch, RUNNER.index("skybridge_ios_require_fresh_app_launch"))

    def test_terminal_is_revalidated_after_the_success_hold_and_secrets_are_not_reported(self) -> None:
        hold = OFFERER.index("delay(postSuccessHoldMillis)")
        terminal_route = OFFERER.index(
            "routeExpectation.requireAdmittedAtCompletion(\n                    manager = manager,",
            hold,
        )
        terminal = OFFERER.index('"SB-ANDROID-APP-OFFER success code=<redacted>', terminal_route)
        self.assertLess(hold, terminal_route)
        self.assertLess(terminal_route, terminal)
        self.assertIn('reporter.append("connect <redacted>")', IOS_APP)
        self.assertNotIn('reporter.append("connect \\(connectCode)")', IOS_APP)
        ios_hold = IOS_APP.index("try await Task.sleep(for: .seconds(holdSeconds))")
        ios_revalidate = IOS_APP.index(
            "try manager.validateFileTransferOutboundContext(outboundContext)",
            ios_hold,
        )
        ios_cleanup = IOS_APP.index("await cleanupFormalInteropRun(", ios_revalidate)
        self.assertLess(ios_hold, ios_revalidate)
        self.assertLess(ios_revalidate, ios_cleanup)
        self.assertIn("authority: cleanupAuthority", IOS_APP[ios_cleanup:])
        cleanup_helper = IOS_APP.index("private func cleanupFormalInteropRun(")
        quiesce = IOS_APP.index("quiesce: { authority in", cleanup_helper)
        remove = IOS_APP.index("removeOwnedArtifacts: { authority in", quiesce)
        self.assertLess(quiesce, remove)
        self.assertIn("disconnectFormalInteropSession", IOS_APP[quiesce:remove])

    def test_ios_disconnect_detaches_current_resources_before_its_first_await(self) -> None:
        disconnect = IOS_MANAGER.index(
            "private func disconnectAndRequireNoReplacement(clearSnapshot: Bool) async -> Bool"
        )
        end = IOS_MANAGER.index(
            "\n#if canImport(WebRTC)\n    private func installRemoteVideoTrack", disconnect
        )
        body = IOS_MANAGER[disconnect:end]
        first_await = body.index("await detachedSignaling.close()")
        for fragment in (
            "signaling = nil",
            "session = nil",
            "currentSessionId = nil",
            "inboundQueue = nil",
            "screenInboundQueue = nil",
            "state = .idle",
            "readiness = .idle",
        ):
            self.assertLess(body.index(fragment), first_await)
        self.assertNotIn("await signaling.close()", body)
        self.assertIn(
            "return CrossNetworkDisconnectPostcondition.hasNoReplacement(",
            body[first_await:],
        )
        exact_disconnect = IOS_MANAGER.index("func disconnectFormalInteropSession(")
        self.assertIn(
            "guard await disconnectAndRequireNoReplacement(clearSnapshot: true)",
            IOS_MANAGER[exact_disconnect:],
        )
        exact_body = IOS_MANAGER[exact_disconnect:]
        self.assertLess(
            exact_body.index("formalInteropSessionRetired = true"),
            exact_body.index(
                "guard await disconnectAndRequireNoReplacement(clearSnapshot: true)"
            ),
        )
        connect_body = IOS_MANAGER[
            IOS_MANAGER.index("private func connect(\n        sessionId: String") :
        ]
        self.assertGreaterEqual(
            connect_body.count("try requireFormalInteropSessionNotRetired()"),
            6,
        )

    def test_receipt_is_not_eligible_until_both_sensitive_state_freezes_are_proven(self) -> None:
        self.assertIn('ANDROID_SENSITIVE_STATE_UNCHANGED="false"', RUNNER)
        self.assertIn(
            'IOS_REQUIRED_IDENTITY_AND_CONTAINER_STATE_UNCHANGED="false"',
            RUNNER,
        )
        self.assertIn('--android-sensitive-state-unchanged "$ANDROID_SENSITIVE_STATE_UNCHANGED"', RUNNER)
        self.assertIn(
            '--ios-required-identity-and-container-state-unchanged \\\n'
            '      "$IOS_REQUIRED_IDENTITY_AND_CONTAINER_STATE_UNCHANGED"',
            RUNNER,
        )
        self.assertIn('--android-app-exit-verified "$ANDROID_APP_EXIT_VERIFIED"', RUNNER)

    def test_android_target_exits_before_context_or_test_package_cleanup(self) -> None:
        cleanup = RUNNER[RUNNER.index("cleanup() {") : RUNNER.index("trap cleanup EXIT")]
        android_exit = cleanup.index("finish_physical_android_instrumentation")
        context_cleanup = cleanup.index("remove_android_context_files")
        package_cleanup = cleanup.index("remove_owned_android_test_package")
        self.assertLess(android_exit, context_cleanup)
        self.assertLess(android_exit, package_cleanup)
        quiescent_guard = cleanup.index('if [[ "$android_quiescent" == "true" ]]')
        preserved_else = cleanup.index("Android context and test package were preserved")
        self.assertLess(quiescent_guard, context_cleanup)
        self.assertLess(package_cleanup, preserved_else)
        self.assertIn("refusing force-stop and concurrent cleanup", RUNNER)
        self.assertIn(
            "Android context and test package were preserved because target-process quiescence is unproven",
            RUNNER,
        )
        physical_cleanup = cleanup.split('if [[ "$IOS_TARGET" != "physical"', 1)[0]
        self.assertNotIn('kill "$ANDROID_PID"', physical_cleanup)
        wait = RUNNER.index('wait "$ANDROID_PID"', RUNNER.index("Starting Android offerer"))
        remote_absence = RUNNER.index(
            "android_app_process_remained_after_instrumentation", wait
        )
        self.assertLess(wait, remote_absence)
        exit_verified = RUNNER.index('ANDROID_APP_EXIT_VERIFIED="true"', remote_absence)
        receipt = RUNNER.index('python3 "$PHYSICAL_EVIDENCE_VALIDATOR" receipt', exit_verified)
        self.assertLess(exit_verified, receipt)

    def test_device_source_and_install_bindings_bracket_the_transaction(self) -> None:
        android_before = RUNNER.index(
            'android_collect_samsung_4k_device_binding "$ADB_BIN" "$DEVICE_SERIAL" \\\n'
            '    >"$ANDROID_DEVICE_BINDING_BEFORE"'
        )
        main_install = RUNNER.index(
            '"$ADB_BIN" -s "$DEVICE_SERIAL" install --no-streaming -r -t "$APP_APK"'
        )
        ios_launch = RUNNER.index("skybridge_ios_start_console_launch \\\n")
        android_after = RUNNER.index(
            'android_collect_samsung_4k_device_binding "$ADB_BIN" "$DEVICE_SERIAL" \\\n'
            '    >"$ANDROID_DEVICE_BINDING_AFTER"'
        )
        self.assertLess(android_before, main_install)
        self.assertLess(main_install, ios_launch)
        self.assertLess(ios_launch, android_after)

        receipt = RUNNER.index('python3 "$PHYSICAL_EVIDENCE_VALIDATOR" receipt \\\n')
        for fragment in (
            '--android-device-before "$ANDROID_DEVICE_BINDING_BEFORE"',
            '--android-device-after "$ANDROID_DEVICE_BINDING_AFTER"',
            '--android-installed-before "$ANDROID_INSTALLED_APPS_BEFORE"',
            '--android-installed-after "$ANDROID_INSTALLED_APPS_AFTER"',
            '--source-binding-before "$SOURCE_BINDING_BEFORE"',
            '--source-binding-after "$SOURCE_BINDING_AFTER"',
        ):
            self.assertGreater(RUNNER.index(fragment, receipt), receipt)


if __name__ == "__main__":
    unittest.main()
