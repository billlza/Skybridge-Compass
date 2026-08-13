#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import tempfile
import unittest
import hashlib
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "validate_android_ios_physical_evidence.py"
SPEC = importlib.util.spec_from_file_location("physical_evidence", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
physical_evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(physical_evidence)


class PhysicalEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.device_id = "00008140-COREDEVICE"
        self.udid = "00008140-UDID"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def json_file(self, name: str, payload: object) -> Path:
        path = self.root / name
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def text_file(self, name: str, payload: str) -> Path:
        path = self.root / name
        path.write_text(payload, encoding="utf-8")
        return path

    @staticmethod
    def devicectl(command_type: str, result: object) -> dict[str, object]:
        return {
            "info": {"commandType": command_type, "jsonVersion": 2, "outcome": "success"},
            "result": result,
        }

    def device_binding(self) -> dict[str, object]:
        devicectl = self.json_file(
            "devices.json",
            self.devicectl(
                "devicectl.list.devices",
                {
                    "devices": [
                        {
                            "identifier": self.device_id,
                            "connectionProperties": {
                                "pairingState": "paired",
                                "tunnelState": "connected",
                            },
                            "deviceProperties": {
                                "bootState": "booted",
                                "developerModeStatus": "enabled",
                                "osVersionNumber": "27.0",
                            },
                            "hardwareProperties": {
                                "deviceType": "iPhone",
                                "platform": "iOS",
                                "reality": "physical",
                                "udid": self.udid,
                            },
                        }
                    ]
                },
            ),
        )
        xcdevice = self.json_file(
            "xcdevice.json",
            [
                {
                    "available": True,
                    "identifier": self.udid,
                    "platform": "com.apple.platform.iphoneos",
                    "simulator": False,
                }
            ],
        )
        return physical_evidence.validate_device(
            devicectl, xcdevice, self.device_id, self.udid
        )

    def installation_binding(self) -> dict[str, object]:
        device = self.device_binding()
        device_path = self.json_file("device-binding.json", device)
        app_properties = self.text_file(
            "app.properties",
            "\n".join(
                [
                    "ios_physical_app_bundle_id=com.skybridge.compass.ios",
                    "ios_physical_app_version=1.0",
                    "ios_physical_app_build=10",
                    "ios_physical_app_executable=SkyBridgeCompass-iOS",
                    f"ios_physical_app_executable_sha256={'a' * 64}",
                    f"ios_physical_app_tree_sha256={'b' * 64}",
                    "ios_physical_app_file_count=12",
                    "ios_physical_app_bytes=2048",
                    "ios_physical_app_path=/private/build/SkyBridgeCompass-iOS.app",
                ]
            )
            + "\n",
        )
        install = self.json_file(
            "install.json",
            self.devicectl(
                "devicectl.device.install.app",
                {
                    "deviceIdentifier": self.device_id,
                    "installedApplications": [
                        {
                            "bundleIdentifier": "com.skybridge.compass.ios",
                            "launchServicesIdentifier": "bGF1bmNoLXNlcnZpY2VzLWlk",
                        }
                    ],
                },
            ),
        )
        apps = self.json_file(
            "apps.json",
            self.devicectl(
                "devicectl.device.info.apps",
                {
                    "deviceIdentifier": self.device_id,
                    "matchingBundleIdentifier": "com.skybridge.compass.ios",
                    "apps": [
                        {
                            "bundleIdentifier": "com.skybridge.compass.ios",
                            "bundleVersion": "10",
                            "builtByDeveloper": True,
                            "url": (
                                "file:///private/var/containers/Bundle/Application/"
                                "ABC/SkyBridgeCompass-iOS.app"
                            ),
                            "version": "1.0",
                        }
                    ],
                },
            ),
        )
        return physical_evidence.validate_installation(
            device_path, install, apps, app_properties
        )

    def receipt_arguments(self, test_cleanup: str = "true") -> argparse.Namespace:
        installation = self.json_file("installation.json", self.installation_binding())
        run_ref = "e" * 64
        session_ref = "7" * 64
        android_to_peer_id = "11111111-1111-4111-8111-111111111111"
        peer_to_android_id = "22222222-2222-4222-8222-222222222222"
        android_payload = physical_evidence._formal_payload(
            "android-to-peer", run_ref, session_ref, android_to_peer_id
        )
        peer_payload = physical_evidence._formal_payload(
            "peer-to-android", run_ref, session_ref, peer_to_android_id
        )
        launch = self.json_file(
            "launch.json",
            self.devicectl(
                "devicectl.device.process.launch",
                {
                    "process": {
                        "auditToken": [0, 1, 2, 3, 4, 1234, 6, 7],
                        "executable": (
                            "file:///private/var/containers/Bundle/Application/ABC/"
                            "SkyBridgeCompass-iOS.app/SkyBridgeCompass-iOS"
                        ),
                        "processIdentifier": 1234,
                    }
                },
            ),
        )
        process_identity = self.json_file(
            "process-identity.json",
            {
                "auditToken": [0, 1, 2, 3, 4, 1234, 6, 7],
                "bundleName": "SkyBridgeCompass-iOS.app",
                "executableName": "SkyBridgeCompass-iOS",
                "executablePath": (
                    "/private/var/containers/Bundle/Application/ABC/"
                    "SkyBridgeCompass-iOS.app/SkyBridgeCompass-iOS"
                ),
                "platform": "ios",
                "processIdentifier": 1234,
                "schemaVersion": 1,
            },
        )
        success_payload = (
            f"success session_ref={session_ref} runRef={run_ref} "
            "suite=ML-KEM-768 suiteWireId=0x0101 "
            "selectedIceRoute=direct selectedIceLocalType=host "
            "selectedIceRemoteType=srflx selectedIceProtocol=udp "
            "handshakeOnly=0 bidirectionalFileTransfer=true "
            f"androidToPeerTransferId={android_to_peer_id} "
            f"androidToPeerBytes={len(android_payload)} "
            f"androidToPeerSha256={hashlib.sha256(android_payload).hexdigest()} "
            "androidToPeerDurableStorage=caches androidToPeerCompleteAck=true "
            f"peerToAndroidTransferId={peer_to_android_id} "
            f"peerToAndroidBytes={len(peer_payload)} "
            f"peerToAndroidSha256={hashlib.sha256(peer_payload).hexdigest()} "
            "peerToAndroidCompleteAck=true iosRunOwnedPayloadCleaned=true"
        )
        success = f"[2026-08-12T14:00:00Z] {success_payload}"
        identity_digest = "9" * 64
        status = self.text_file(
            "status.log",
            f"identity-material phase=before digest={identity_digest}\n"
            f"identity-material phase=after digest={identity_digest}\n"
            + success
            + "\n",
        )
        stdout = self.text_file("stdout.log", "prefix\n" + success + "\n")
        instrumentation_status = (
            "INSTRUMENTATION_STATUS: class="
            "com.skybridge.compass.android.webrtc."
            "AppleReleaseInteropOffererAppInstrumentationTest\n"
            "INSTRUMENTATION_STATUS: current=1\n"
            "INSTRUMENTATION_STATUS: id=AndroidJUnitRunner\n"
            "INSTRUMENTATION_STATUS: numtests=1\n"
            "INSTRUMENTATION_STATUS: test=hostsCodeForAppleResponderUsingAppProcess\n"
        )
        instrumentation = self.text_file(
            "instrumentation.log",
            instrumentation_status
            + "INSTRUMENTATION_STATUS: stream=\n"
            "INSTRUMENTATION_STATUS_CODE: 1\n"
            "SB-ANDROID-APP-OFFER storage=dedicated-test-package "
            "package=com.skybridge.compass.debug.ioswebrtc.test\n"
            f"SB-ANDROID-APP-OFFER sensitive-state phase=before digest={identity_digest}\n"
            "SB-ANDROID-APP-OFFER success code=<redacted> "
            f"runRef={run_ref} sessionRef={session_ref} "
            "bootstrapKem=true bootstrapQPeriapt=false qperiapt=false "
            "expectedSuite=MLKEM_768 "
            "suite=MLKEM_768/0x0101 suiteWireId=0x0101 route=direct "
            "fileTransfer=true bidirectionalFileTransfer=true "
            f"androidToPeerTransferId={android_to_peer_id} "
            f"androidToPeerBytes={len(android_payload)} "
            f"androidToPeerSha256={hashlib.sha256(android_payload).hexdigest()} "
            "androidToPeerOutboundOps=metadata,chunk,complete "
            "androidToPeerInboundAcks=metadataAck,chunkAck,completeAck "
            f"peerToAndroidTransferId={peer_to_android_id} "
            f"peerToAndroidBytes={len(peer_payload)} "
            f"peerToAndroidSha256={hashlib.sha256(peer_payload).hexdigest()} "
            "peerToAndroidInboundOps=metadata,chunk,complete "
            "peerToAndroidOutboundAcks=metadataAck,chunkAck,completeAck "
            "androidRunOwnedPayloadCleaned=true\n"
            f"SB-ANDROID-APP-OFFER sensitive-state phase=after digest={identity_digest}\n"
            + instrumentation_status
            + "INSTRUMENTATION_STATUS: stream=.\n"
            "INSTRUMENTATION_STATUS_CODE: 0\n"
            "INSTRUMENTATION_RESULT: stream=\n"
            "Time: 0.125\n\n"
            "OK (1 test)\n"
            "INSTRUMENTATION_CODE: -1\n",
        )
        app_apk = self.text_file(
            "app-apk.properties",
            f"app_debug_apk_path=/private/app.apk\napp_debug_apk_sha256={'c' * 64}\n"
            "app_debug_apk_bytes=1024\n",
        )
        test_apk = self.text_file(
            "test-apk.properties",
            f"android_test_apk_path=/private/test.apk\nandroid_test_apk_sha256={'d' * 64}\n"
            "android_test_apk_bytes=2048\n",
        )
        container_snapshot = self.text_file(
            "ios-container.properties",
            "schema_version=1\n"
            "user_defaults_bytes=10\n"
            f"user_defaults_sha256={'1' * 64}\n"
            "trusted_devices_bytes=20\n"
            f"trusted_devices_sha256={'2' * 64}\n"
            "pairing_policy_bytes=30\n"
            f"pairing_policy_sha256={'3' * 64}\n"
            "transfer_history_bytes=6\n"
            f"transfer_history_sha256={hashlib.sha256(b'absent').hexdigest()}\n",
        )
        container_after = self.text_file(
            "ios-container-after.properties",
            container_snapshot.read_text(encoding="utf-8"),
        )
        android_device = self.text_file(
            "android-device.properties",
            "schema_version=1\n"
            "profile=samsung-physical-4k\n"
            f"serial_ref=sha256:{'a' * 16}\n"
            f"model_ref=sha256:{'b' * 16}\n"
            "manufacturer=samsung\n"
            "release=16\n"
            "sdk=36\n"
            "abi=arm64-v8a\n"
            "qemu=0\n"
            "page_size=4096\n",
        )
        android_device_after = self.text_file(
            "android-device-after.properties",
            android_device.read_text(encoding="utf-8"),
        )
        source_before = self.text_file(
            "source-before.properties",
            "schema_version=1\n"
            "phase=before\n"
            f"source_commit={'f' * 40}\n"
            f"source_tree={'8' * 40}\n"
            "worktree_clean=true\n",
        )
        source_after = self.text_file(
            "source-after.properties",
            source_before.read_text(encoding="utf-8").replace(
                "phase=before", "phase=after"
            ),
        )
        installed_apks = self.text_file(
            "installed-apks.properties",
            "app_package=com.skybridge.compass.debug\n"
            f"app_sha256={'c' * 64}\n"
            f"app_serial_ref=sha256:{'a' * 16}\n"
            f"app_remote_path_ref=sha256:{'c' * 16}\n"
            "test_package=com.skybridge.compass.debug.ioswebrtc.test\n"
            f"test_sha256={'d' * 64}\n"
            f"test_serial_ref=sha256:{'a' * 16}\n"
            f"test_remote_path_ref=sha256:{'d' * 16}\n",
        )
        installed_apks_after = self.text_file(
            "installed-apks-after.properties",
            installed_apks.read_text(encoding="utf-8"),
        )
        return argparse.Namespace(
            android_context_cleanup_verified="true",
            android_sensitive_state_unchanged="true",
            android_instrumentation=instrumentation,
            android_device_before=android_device,
            android_device_after=android_device_after,
            android_installed_before=installed_apks,
            android_installed_after=installed_apks_after,
            app_apk_provenance=app_apk,
            android_app_exit_verified="true",
            app_exit_verified="true",
            console_cleanup_verified="true",
            expect_file_transfer="true",
            installation_binding=installation,
            ios_status=status,
            ios_stdout=stdout,
            ios_process_identity=process_identity,
            ios_required_identity_and_container_state_unchanged="true",
            ios_container_before=container_snapshot,
            ios_container_after=container_after,
            launch_result=launch,
            run_ref=run_ref,
            source_commit="f" * 40,
            source_binding_before=source_before,
            source_binding_after=source_after,
            test_apk_provenance=test_apk,
            test_package_cleanup_verified=test_cleanup,
        )

    def test_exact_physical_device_and_overlay_installation_are_bound(self) -> None:
        installation = self.installation_binding()
        self.assertEqual(installation["installationMode"], "overlay-preserve-data")
        self.assertTrue(installation["installationVerified"])

    def test_device_binding_rejects_conflicting_udids_and_non_string_platform(self) -> None:
        self.device_binding()
        devicectl_path = self.root / "devices.json"
        xcdevice_path = self.root / "xcdevice.json"
        devicectl = json.loads(devicectl_path.read_text(encoding="utf-8"))
        devicectl["result"]["devices"][0]["deviceProperties"]["udid"] = "DIFFERENT-UDID"
        devicectl_path.write_text(json.dumps(devicectl), encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "physical UDID does not match",
        ):
            physical_evidence.validate_device(
                devicectl_path, xcdevice_path, self.device_id, self.udid
            )

        self.device_binding()
        xcdevice = json.loads(xcdevice_path.read_text(encoding="utf-8"))
        xcdevice[0]["platform"] = ["com.apple.platform.iphoneos"]
        xcdevice_path.write_text(json.dumps(xcdevice), encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "not one available physical iOS device",
        ):
            physical_evidence.validate_device(
                devicectl_path, xcdevice_path, self.device_id, self.udid
            )

    def test_installation_rejects_bool_schema_or_forged_device_refs(self) -> None:
        self.installation_binding()
        binding_path = self.root / "device-binding.json"
        install_path = self.root / "install.json"
        apps_path = self.root / "apps.json"
        provenance_path = self.root / "app.properties"

        binding = json.loads(binding_path.read_text(encoding="utf-8"))
        binding["schemaVersion"] = True
        binding_path.write_text(json.dumps(binding), encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "invalid schema version",
        ):
            physical_evidence.validate_installation(
                binding_path, install_path, apps_path, provenance_path
            )

        binding["schemaVersion"] = 1
        binding["coreDeviceIdentifierRef"] = "sha256:" + "0" * 16
        binding_path.write_text(json.dumps(binding), encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "identifiers or metadata are invalid",
        ):
            physical_evidence.validate_installation(
                binding_path, install_path, apps_path, provenance_path
            )

    def test_installation_rejects_non_string_version_or_build(self) -> None:
        for field, value in (("version", True), ("bundleVersion", 10)):
            with self.subTest(field=field):
                self.installation_binding()
                apps_path = self.root / "apps.json"
                apps = json.loads(apps_path.read_text(encoding="utf-8"))
                apps["result"]["apps"][0][field] = value
                apps_path.write_text(json.dumps(apps), encoding="utf-8")
                with self.assertRaisesRegex(
                    physical_evidence.PhysicalEvidenceError,
                    "installed iOS app (version|build) is missing",
                ):
                    physical_evidence.validate_installation(
                        self.root / "device-binding.json",
                        self.root / "install.json",
                        apps_path,
                        self.root / "app.properties",
                    )

    def test_receipt_rejects_forged_installation_device_refs(self) -> None:
        arguments = self.receipt_arguments()
        installation = json.loads(
            arguments.installation_binding.read_text(encoding="utf-8")
        )
        installation["deviceUdidRef"] = "sha256:" + "0" * 16
        arguments.installation_binding.write_text(
            json.dumps(installation), encoding="utf-8"
        )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "installation binding is invalid",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_revalidates_installed_app_container_path(self) -> None:
        arguments = self.receipt_arguments()
        installation = json.loads(
            arguments.installation_binding.read_text(encoding="utf-8")
        )
        installation["remoteApplicationPath"] = "/tmp/SkyBridgeCompass-iOS.app"
        arguments.installation_binding.write_text(
            json.dumps(installation), encoding="utf-8"
        )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "outside the app bundle container",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_file_urls_reject_query_or_fragment_ambiguity(self) -> None:
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "must be a local file URL",
        ):
            physical_evidence._remote_app_path(
                "file:///private/var/containers/Bundle/Application/ABC/App.app?other=1"
            )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "must be a local file URL",
        ):
            physical_evidence._process_executable_path(
                "file:///private/var/containers/Bundle/Application/ABC/App.app/App#other"
            )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "invalid percent escape",
        ):
            physical_evidence._remote_app_path(
                "file:///private/var/containers/Bundle/Application/%ZZ/App.app"
            )

    def test_launch_identifier_rejects_noncanonical_base64_pad_bits(self) -> None:
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "not canonical base64",
        ):
            physical_evidence._launch_services_identifier("AB==")

    def test_receipt_is_typed_and_omits_raw_session_and_process_id(self) -> None:
        receipt = physical_evidence.validate_receipt(self.receipt_arguments())
        self.assertEqual(receipt["appleIdentityMode"], "existing-persistent-read-only")
        self.assertEqual(receipt["terminalStatus"]["suite"], "ML-KEM-768")
        self.assertEqual(receipt["terminalStatus"]["suiteWireId"], "0x0101")
        self.assertTrue(receipt["android"]["testStorageContextVerified"])
        serialized = json.dumps(receipt)
        self.assertNotIn("1234", serialized)
        self.assertEqual(receipt["android"]["terminal"]["sessionRef"], "7" * 64)
        self.assertEqual(receipt["android"]["device"]["pageSize"], 4096)
        self.assertTrue(receipt["terminalStatus"]["bidirectionalFileTransfer"])
        self.assertEqual(receipt["terminalStatus"]["selectedIceRoute"], "direct")
        self.assertTrue(receipt["ios"]["requiredIdentityMaterialUnchanged"])
        self.assertTrue(receipt["ios"]["protectedContainerStateUnchanged"])
        self.assertNotIn("persistentSensitiveStateUnchanged", receipt["ios"])
        transfers = receipt["android"]["terminal"]["fileTransfer"]["transfers"]
        self.assertEqual(
            [item["direction"] for item in transfers],
            ["android-to-peer", "peer-to-android"],
        )

    def test_receipt_rejects_noncanonical_bidirectional_payload_evidence(self) -> None:
        arguments = self.receipt_arguments()
        text = arguments.android_instrumentation.read_text(encoding="utf-8").replace(
            "androidToPeerBytes=251", "androidToPeerBytes=252"
        )
        arguments.android_instrumentation.write_text(text, encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "payload bytes or SHA-256",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_selected_ice_route_mismatch(self) -> None:
        arguments = self.receipt_arguments()
        status = arguments.ios_status.read_text(encoding="utf-8").replace(
            "selectedIceRoute=direct", "selectedIceRoute=relay"
        )
        arguments.ios_status.write_text(status, encoding="utf-8")
        arguments.ios_stdout.write_text(
            arguments.ios_stdout.read_text(encoding="utf-8").replace(
                "selectedIceRoute=direct", "selectedIceRoute=relay"
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "selected ICE evidence is invalid or mismatched",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_unverified_test_package_cleanup(self) -> None:
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "test-package cleanup is incomplete",
        ):
            physical_evidence.validate_receipt(self.receipt_arguments(test_cleanup="false"))

    def test_receipt_rejects_missing_sensitive_state_freeze(self) -> None:
        arguments = self.receipt_arguments()
        arguments.ios_required_identity_and_container_state_unchanged = "false"
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "iOS required identity material and protected container state",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_unverified_android_target_exit(self) -> None:
        arguments = self.receipt_arguments()
        arguments.android_app_exit_verified = "false"
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "Android target-process exit is not proven",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_changed_ios_container_state(self) -> None:
        arguments = self.receipt_arguments()
        changed = arguments.ios_container_after.read_text(encoding="utf-8").replace(
            "pairing_policy_sha256=" + "3" * 64,
            "pairing_policy_sha256=" + "4" * 64,
        )
        arguments.ios_container_after.write_text(changed, encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "app-container identity/trust state changed",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_duplicate_android_success_terminal(self) -> None:
        arguments = self.receipt_arguments()
        duplicate = arguments.android_instrumentation.read_text(encoding="utf-8")
        duplicate += "SB-ANDROID-APP-OFFER success code=<redacted> suite=MLKEM_768/0x0101 route=direct\n"
        arguments.android_instrumentation.write_text(duplicate, encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "canonical test sequence",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_spliced_android_instrumentation_sequence(self) -> None:
        arguments = self.receipt_arguments()
        spliced = (
            "INSTRUMENTATION_STATUS: class=com.example.UnrelatedTest\n"
            "INSTRUMENTATION_STATUS: current=1\n"
            "INSTRUMENTATION_STATUS: id=AndroidJUnitRunner\n"
            "INSTRUMENTATION_STATUS: numtests=1\n"
            "INSTRUMENTATION_STATUS: test=otherTest\n"
            "INSTRUMENTATION_STATUS_CODE: 0\n"
            "INSTRUMENTATION_CODE: 0\n"
            + arguments.android_instrumentation.read_text(encoding="utf-8")
        )
        arguments.android_instrumentation.write_text(spliced, encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "canonical test sequence",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_cross_platform_suite_wire_id_mismatch(self) -> None:
        arguments = self.receipt_arguments()
        status = arguments.ios_status.read_text(encoding="utf-8").replace(
            "suiteWireId=0x0101", "suiteWireId=0x0001"
        )
        arguments.ios_status.write_text(status, encoding="utf-8")
        arguments.ios_stdout.write_text(
            arguments.ios_stdout.read_text(encoding="utf-8").replace(
                "suiteWireId=0x0101", "suiteWireId=0x0001"
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "different negotiated suite wire ids",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_cross_run_or_cross_session_terminals(self) -> None:
        arguments = self.receipt_arguments()
        arguments.ios_status.write_text(
            arguments.ios_status.read_text(encoding="utf-8").replace(
                f"runRef={'e' * 64}", f"runRef={'d' * 64}"
            ),
            encoding="utf-8",
        )
        arguments.ios_stdout.write_text(
            arguments.ios_stdout.read_text(encoding="utf-8").replace(
                f"runRef={'e' * 64}", f"runRef={'d' * 64}"
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "terminal belongs to a different run",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_launch_identity_from_another_process(self) -> None:
        arguments = self.receipt_arguments()
        identity = json.loads(arguments.ios_process_identity.read_text(encoding="utf-8"))
        identity["auditToken"][5] = 4321
        arguments.ios_process_identity.write_text(json.dumps(identity), encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "does not match the installed launch",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_bool_typed_captured_process_identity(self) -> None:
        arguments = self.receipt_arguments()
        identity = json.loads(arguments.ios_process_identity.read_text(encoding="utf-8"))
        identity["schemaVersion"] = True
        identity["auditToken"][0:2] = [False, True]
        arguments.ios_process_identity.write_text(json.dumps(identity), encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "does not match the installed launch",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_stdout_substring_or_duplicate_terminal(self) -> None:
        arguments = self.receipt_arguments()
        terminal = arguments.ios_status.read_text(encoding="utf-8").splitlines()[-1]
        arguments.ios_stdout.write_text(f"prefix-{terminal}-suffix\n", encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "one exact bound terminal line",
        ):
            physical_evidence.validate_receipt(arguments)

        arguments = self.receipt_arguments()
        terminal = arguments.ios_status.read_text(encoding="utf-8").splitlines()[-1]
        arguments.ios_stdout.write_text(f"{terminal}\n{terminal}\n", encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "one exact bound terminal line",
        ):
            physical_evidence.validate_receipt(arguments)

        arguments = self.receipt_arguments()
        arguments.android_instrumentation.write_text(
            arguments.android_instrumentation.read_text(encoding="utf-8").replace(
                f"sessionRef={'7' * 64}", f"sessionRef={'6' * 64}"
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "different sessions",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_nonphysical_or_changed_android_binding(self) -> None:
        arguments = self.receipt_arguments()
        arguments.android_device_before.write_text(
            arguments.android_device_before.read_text(encoding="utf-8").replace(
                "qemu=0", "qemu=1"
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "not the formal Samsung physical 4K profile",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_changed_source_or_installed_artifact_binding(self) -> None:
        arguments = self.receipt_arguments()
        arguments.source_binding_after.write_text(
            arguments.source_binding_after.read_text(encoding="utf-8").replace(
                f"source_tree={'8' * 40}", f"source_tree={'9' * 40}"
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "source phase binding is incomplete or changed",
        ):
            physical_evidence.validate_receipt(arguments)

        arguments = self.receipt_arguments()
        arguments.android_installed_after.write_text(
            arguments.android_installed_after.read_text(encoding="utf-8").replace(
                f"test_sha256={'d' * 64}", f"test_sha256={'e' * 64}"
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "installed Android APK binding is invalid or changed",
        ):
            physical_evidence.validate_receipt(arguments)

        arguments = self.receipt_arguments()
        arguments.android_device_after.write_text(
            arguments.android_device_after.read_text(encoding="utf-8").replace(
                "sdk=36", "sdk=37"
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "device binding changed",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_contradictory_android_failure_terminal(self) -> None:
        arguments = self.receipt_arguments()
        contradictory = arguments.android_instrumentation.read_text(encoding="utf-8")
        contradictory += "INSTRUMENTATION_FAILED: process crashed\n"
        arguments.android_instrumentation.write_text(contradictory, encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "contradictory failure terminal",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_unknown_or_unassigned_terminal_fields(self) -> None:
        arguments = self.receipt_arguments()
        text = arguments.android_instrumentation.read_text(encoding="utf-8").replace(
            " route=direct", " stray route=direct"
        )
        arguments.android_instrumentation.write_text(text, encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "token without an assignment",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_contradictory_android_policy_values(self) -> None:
        replacements = (
            ("code=<redacted>", "code=123456"),
            ("bootstrapKem=true", "bootstrapKem=maybe"),
            ("suite=MLKEM_768/0x0101", "suite=MLKEM_768/0xffff"),
        )
        for old, new in replacements:
            with self.subTest(replacement=new):
                arguments = self.receipt_arguments()
                text = arguments.android_instrumentation.read_text(encoding="utf-8").replace(
                    old, new
                )
                arguments.android_instrumentation.write_text(text, encoding="utf-8")
                with self.assertRaises(physical_evidence.PhysicalEvidenceError):
                    physical_evidence.validate_receipt(arguments)

        arguments = self.receipt_arguments()
        text = arguments.android_instrumentation.read_text(encoding="utf-8").replace(
            " route=direct", " unknown=value route=direct"
        )
        arguments.android_instrumentation.write_text(text, encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "unexpected field set",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_non_mlkem_formal_session(self) -> None:
        arguments = self.receipt_arguments()
        replacements = {
            "bootstrapQPeriapt=false": "bootstrapQPeriapt=true",
            "qperiapt=false": "qperiapt=true",
            "expectedSuite=MLKEM_768": "expectedSuite=Q_PERIAPT_CONTEXT_BOUND",
            "suite=MLKEM_768/0x0101": "suite=Q_PERIAPT_CONTEXT_BOUND/0x0011",
            "suiteWireId=0x0101": "suiteWireId=0x0011",
        }
        instrumentation = arguments.android_instrumentation.read_text(encoding="utf-8")
        status = arguments.ios_status.read_text(encoding="utf-8")
        stdout = arguments.ios_stdout.read_text(encoding="utf-8")
        for old, new in replacements.items():
            instrumentation = instrumentation.replace(old, new)
            status = status.replace(old, new)
            stdout = stdout.replace(old, new)
        status = status.replace("suite=ML-KEM-768", "suite=Q-Periapt-ContextBound")
        stdout = stdout.replace("suite=ML-KEM-768", "suite=Q-Periapt-ContextBound")
        arguments.android_instrumentation.write_text(instrumentation, encoding="utf-8")
        arguments.ios_status.write_text(status, encoding="utf-8")
        arguments.ios_stdout.write_text(stdout, encoding="utf-8")
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "requires exact ML-KEM-768 negotiation",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_ios_terminal_with_an_unbound_prefix(self) -> None:
        arguments = self.receipt_arguments()
        status = arguments.ios_status.read_text(encoding="utf-8").replace(
            "] success session_ref=", "] garbage success session_ref="
        )
        arguments.ios_status.write_text(status, encoding="utf-8")
        arguments.ios_stdout.write_text(
            arguments.ios_stdout.read_text(encoding="utf-8").replace(
                "] success session_ref=", "] garbage success session_ref="
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "exactly one session success",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_receipt_rejects_failure_visible_only_on_ios_console(self) -> None:
        arguments = self.receipt_arguments()
        arguments.ios_stdout.write_text(
            "failed stage=identity-freeze error=write_failed\n"
            + arguments.ios_stdout.read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "status or console contains a terminal failure",
        ):
            physical_evidence.validate_receipt(arguments)

    def test_json_loader_rejects_duplicate_keys_at_any_depth(self) -> None:
        duplicate = self.text_file(
            "duplicate.json",
            '{"result":{"processIdentifier":1,"processIdentifier":2}}',
        )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "duplicate key: processIdentifier",
        ):
            physical_evidence._load_json(duplicate, "duplicate fixture")

    def test_xcdevice_array_loader_rejects_duplicate_nested_keys(self) -> None:
        devicectl = self.json_file(
            "devices-duplicate-test.json",
            self.devicectl(
                "devicectl.list.devices",
                {
                    "devices": [
                        {
                            "identifier": self.device_id,
                            "connectionProperties": {
                                "pairingState": "paired",
                                "tunnelState": "connected",
                            },
                            "deviceProperties": {
                                "bootState": "booted",
                                "developerModeStatus": "enabled",
                                "osVersionNumber": "27.0",
                            },
                            "hardwareProperties": {
                                "platform": "iOS",
                                "reality": "physical",
                                "udid": self.udid,
                            },
                        }
                    ]
                },
            ),
        )
        xcdevice = self.text_file(
            "xcdevice-duplicate.json",
            "[{\"available\":false,\"available\":true,"
            f"\"identifier\":\"{self.udid}\","
            "\"platform\":\"com.apple.platform.iphoneos\",\"simulator\":false}]",
        )
        with self.assertRaisesRegex(
            physical_evidence.PhysicalEvidenceError,
            "duplicate key: available",
        ):
            physical_evidence.validate_device(
                devicectl, xcdevice, self.device_id, self.udid
            )


if __name__ == "__main__":
    unittest.main()
