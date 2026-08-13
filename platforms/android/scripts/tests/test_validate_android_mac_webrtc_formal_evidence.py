#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "validate_android_mac_webrtc_formal_evidence.py"
SPEC = importlib.util.spec_from_file_location("mac_formal_evidence", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)


RUN_REF = "1" * 64
SESSION_REF = "2" * 64
SOURCE_COMMIT = "3" * 40
SOURCE_TREE = "4" * 40
APP_SHA = "5" * 64
TEST_SHA = "6" * 64
HOST_SHA = "7" * 64
SERIAL_REF = "sha256:" + "8" * 16
TRANSFER_ANDROID_TO_MAC = "11111111-1111-4111-8111-111111111111"
TRANSFER_MAC_TO_ANDROID = "22222222-2222-4222-8222-222222222222"


def formal_payload(direction: str, transfer_id: str) -> bytes:
    return (
        "skybridge-formal-p2p-file-v1\n"
        f"direction={direction}\n"
        f"runRef={RUN_REF}\n"
        f"sessionRef={SESSION_REF}\n"
        f"transferId={transfer_id}\n"
    ).encode("ascii")


def short_jwt() -> bytes:
    now = int(time.time())
    header = base64.urlsafe_b64encode(b'{"alg":"RS256","typ":"JWT"}').rstrip(b"=")
    claims = base64.urlsafe_b64encode(
        json.dumps({"iat": now - 5, "exp": now + 300}, separators=(",", ":")).encode()
    ).rstrip(b"=")
    return header + b"." + claims + b".signature"


class FormalEvidenceFixture:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.paths: dict[str, Path] = {}
        self._build()

    def close(self) -> None:
        self.temporary.cleanup()

    def write_text(self, name: str, text: str, *, private: bool = False) -> Path:
        path = self.root / name
        path.write_text(text, encoding="utf-8")
        path.chmod(0o600 if private else 0o644)
        self.paths[name] = path
        return path

    def write_json(self, name: str, value: object, *, private: bool = True) -> Path:
        return self.write_text(
            name,
            json.dumps(value, indent=2, sort_keys=True) + "\n",
            private=private,
        )

    def properties(self, name: str, values: dict[str, object]) -> Path:
        return self.write_text(
            name,
            "".join(f"{key}={value}\n" for key, value in values.items()),
        )

    def artifact(self, name: str, prefix: str, path: str, digest: str, size: int) -> Path:
        return self.properties(
            name,
            {
                f"{prefix}_path": path,
                f"{prefix}_sha256": digest,
                f"{prefix}_bytes": size,
            },
        )

    def source(self, name: str, phase: str) -> Path:
        return self.properties(
            name,
            {
                "schema_version": 1,
                "phase": phase,
                "source_commit": SOURCE_COMMIT,
                "source_tree": SOURCE_TREE,
                "worktree_clean": "true",
            },
        )

    def device(self, name: str) -> Path:
        return self.properties(
            name,
            {
                "schema_version": 1,
                "profile": "samsung-physical-4k",
                "serial_ref": SERIAL_REF,
                "model_ref": "sha256:" + "9" * 16,
                "manufacturer": "samsung",
                "release": 16,
                "sdk": 36,
                "abi": "arm64-v8a",
                "qemu": 0,
                "page_size": 4096,
            },
        )

    def installed(self, name: str) -> Path:
        values: dict[str, object] = {}
        for prefix, package, digest, suffix in (
            ("app", evidence.EXPECTED_APP_PACKAGE, APP_SHA, "a"),
            ("test", evidence.EXPECTED_TEST_PACKAGE, TEST_SHA, "b"),
        ):
            values.update(
                {
                    f"{prefix}_package": package,
                    f"{prefix}_sha256": digest,
                    f"{prefix}_serial_ref": SERIAL_REF,
                    f"{prefix}_remote_path_ref": "sha256:" + suffix * 16,
                }
            )
        return self.properties(name, values)

    def sensitive(self, name: str) -> Path:
        values: dict[str, object] = {
            "schema_version": 1,
            "package": evidence.EXPECTED_APP_PACKAGE,
            "uid": 10234,
        }
        for index, prefix in enumerate(("p2p_identity", "pqc_keys", "peer_kem_keys"), 10):
            values[f"{prefix}_bytes"] = index
            values[f"{prefix}_sha256"] = f"{index:x}"[-1] * 64
        return self.properties(name, values)

    def instrumentation(self) -> str:
        outbound = formal_payload("android-to-peer", TRANSFER_ANDROID_TO_MAC)
        inbound = formal_payload("peer-to-android", TRANSFER_MAC_TO_ANDROID)
        identity_digest = "d" * 64
        terminal = " ".join(
            (
                "SB-ANDROID-APP-OFFER success",
                "code=<redacted>",
                f"runRef={RUN_REF}",
                f"sessionRef={SESSION_REF}",
                "bootstrapKem=true",
                "bootstrapQPeriapt=false",
                "qperiapt=false",
                "expectedSuite=MLKEM_768",
                "suite=MLKEM_768/0x0101",
                "suiteWireId=0x0101",
                "route=direct",
                "fileTransfer=true",
                "bidirectionalFileTransfer=true",
                f"androidToPeerTransferId={TRANSFER_ANDROID_TO_MAC}",
                f"androidToPeerBytes={len(outbound)}",
                f"androidToPeerSha256={hashlib.sha256(outbound).hexdigest()}",
                "androidToPeerOutboundOps=metadata,chunk,complete",
                "androidToPeerInboundAcks=metadataAck,chunkAck,completeAck",
                f"peerToAndroidTransferId={TRANSFER_MAC_TO_ANDROID}",
                f"peerToAndroidBytes={len(inbound)}",
                f"peerToAndroidSha256={hashlib.sha256(inbound).hexdigest()}",
                "peerToAndroidInboundOps=metadata,chunk,complete",
                "peerToAndroidOutboundAcks=metadataAck,chunkAck,completeAck",
                "androidRunOwnedPayloadCleaned=true",
            )
        )
        status_prefix = (
            "INSTRUMENTATION_STATUS: class="
            "com.skybridge.compass.android.webrtc."
            "AppleReleaseInteropOffererAppInstrumentationTest\n"
            "INSTRUMENTATION_STATUS: current=1\n"
            "INSTRUMENTATION_STATUS: id=AndroidJUnitRunner\n"
            "INSTRUMENTATION_STATUS: numtests=1\n"
            "INSTRUMENTATION_STATUS: test=hostsCodeForAppleResponderUsingAppProcess\n"
        )
        return (
            status_prefix
            + "INSTRUMENTATION_STATUS: stream=\n"
            + "INSTRUMENTATION_STATUS_CODE: 1\n"
            f"SB-ANDROID-APP-OFFER storage=dedicated-test-package package={evidence.EXPECTED_TEST_PACKAGE}\n"
            f"SB-ANDROID-APP-OFFER sensitive-state phase=before digest={identity_digest}\n"
            f"{terminal}\n"
            f"SB-ANDROID-APP-OFFER sensitive-state phase=after digest={identity_digest}\n"
            + status_prefix
            + "INSTRUMENTATION_STATUS: stream=.\n"
            "INSTRUMENTATION_STATUS_CODE: 0\n"
            "INSTRUMENTATION_RESULT: stream=\n"
            "Time: 0.125\n\n"
            "OK (1 test)\n"
            "INSTRUMENTATION_CODE: -1\n"
        )

    def mac_result(self) -> dict[str, object]:
        outbound = formal_payload("android-to-peer", TRANSFER_ANDROID_TO_MAC)
        inbound = formal_payload("peer-to-android", TRANSFER_MAC_TO_ANDROID)
        return {
            "schemaVersion": 1,
            "outcome": "success",
            "runRef": RUN_REF,
            "sessionRef": SESSION_REF,
            "suite": "ML-KEM-768",
            "suiteWireId": "0x0101",
            "selectedIce": {
                "route": "direct",
                "localCandidateType": "host",
                "remoteCandidateType": "srflx",
                "protocol": "udp",
            },
            "transfers": {
                "androidToMac": {
                    "transferId": TRANSFER_ANDROID_TO_MAC,
                    "bytes": len(outbound),
                    "sha256": hashlib.sha256(outbound).hexdigest(),
                    "durableCommit": True,
                    "completeAck": True,
                },
                "macToAndroid": {
                    "transferId": TRANSFER_MAC_TO_ANDROID,
                    "bytes": len(inbound),
                    "sha256": hashlib.sha256(inbound).hexdigest(),
                    "durableCommit": True,
                    "completeAck": True,
                },
            },
            "identityState": {
                "beforeDigest": "e" * 64,
                "afterDigest": "e" * 64,
                "unchanged": True,
            },
            "runOwnedPayloadCleaned": True,
        }

    def _build(self) -> None:
        self.source_before = self.source("source-before.properties", "before")
        self.source_after = self.source("source-after.properties", "after")
        self.app = self.artifact("app.properties", "app_debug_apk", "/tmp/app.apk", APP_SHA, 100)
        self.test = self.artifact("test.properties", "android_test_apk", "/tmp/test.apk", TEST_SHA, 50)
        self.host_before = self.artifact(
            "host-before.properties", "mac_formal_host", "/tmp/FormalMacWebRTCHost", HOST_SHA, 500
        )
        self.host_after = self.artifact(
            "host-after.properties", "mac_formal_host", "/tmp/FormalMacWebRTCHost", HOST_SHA, 500
        )
        self.device_before = self.device("device-before.properties")
        self.device_after = self.device("device-after.properties")
        self.installed_before = self.installed("installed-before.properties")
        self.installed_after = self.installed("installed-after.properties")
        self.sensitive_before = self.sensitive("sensitive-before.properties")
        self.sensitive_after = self.sensitive("sensitive-after.properties")
        self.manifest = self.properties(
            "manifest.properties",
            {
                "schema_version": 1,
                "package": evidence.EXPECTED_APP_PACKAGE,
                "sha256": "c" * 64,
                "automatic_start_entries_absent": "true",
            },
        )
        self.android = self.write_text("android.log", self.instrumentation())
        self.mac = self.write_json("mac-result.json", self.mac_result())
        self.process = self.write_json(
            "mac-process.json",
            {
                "auditToken": [0, 0, 0, 0, 0, 4321, 0, 0],
                "executablePath": "/tmp/FormalMacWebRTCHost",
                "platform": "macos",
                "processIdentifier": 4321,
                "schemaVersion": 1,
                "startTimeToken": "100:200",
            },
        )

    def arguments(self, **updates: object) -> argparse.Namespace:
        values: dict[str, object] = {
            "source_commit": SOURCE_COMMIT,
            "run_ref": RUN_REF,
            "source_binding_before": self.source_before,
            "source_binding_after": self.source_after,
            "app_apk_provenance": self.app,
            "test_apk_provenance": self.test,
            "host_provenance_before": self.host_before,
            "host_provenance_after": self.host_after,
            "android_device_before": self.device_before,
            "android_device_after": self.device_after,
            "android_installed_before": self.installed_before,
            "android_installed_after": self.installed_after,
            "android_sensitive_before": self.sensitive_before,
            "android_sensitive_after": self.sensitive_after,
            "manifest_binding": self.manifest,
            "android_instrumentation": self.android,
            "mac_result": self.mac,
            "mac_process_identity": self.process,
            "android_app_exit_verified": "true",
            "test_package_cleanup_verified": "true",
            "android_context_cleanup_verified": "true",
            "private_file_cleanup_verified": "true",
            "mac_process_cleanup_verified": "true",
            "mac_exit_verified": "true",
            "mac_payload_cleanup_verified": "true",
        }
        values.update(updates)
        return argparse.Namespace(**values)


class FormalEvidenceValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = FormalEvidenceFixture()

    def tearDown(self) -> None:
        self.fixture.close()

    def test_accepts_exact_bidirectional_transaction(self) -> None:
        receipt = evidence.validate_receipt(self.fixture.arguments())
        self.assertEqual(receipt["outcome"], "success")
        self.assertEqual(receipt["terminal"]["suiteWireId"], "0x0101")
        self.assertEqual(len(receipt["fileTransfer"]["transfers"]), 2)
        self.assertTrue(receipt["android"]["persistentSensitiveStateUnchangedFromBeforeOverlay"])

    def test_rejects_unknown_nested_json_field(self) -> None:
        value = self.fixture.mac_result()
        value["selectedIce"]["pairId"] = "unbound"
        self.fixture.write_json("mac-result-unknown.json", value)
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "selected ICE evidence"):
            evidence.validate_receipt(
                self.fixture.arguments(mac_result=self.fixture.paths["mac-result-unknown.json"])
            )

    def test_rejects_duplicate_json_key_and_trailing_content(self) -> None:
        duplicate = self.fixture.write_text(
            "duplicate.json", '{"schemaVersion":1,"schemaVersion":1}\n', private=True
        )
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "duplicate key"):
            evidence._load_json(duplicate, "duplicate", private=True)
        trailing = self.fixture.write_text(
            "trailing.json", json.dumps(self.fixture.mac_result()) + "\n\n", private=True
        )
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "end immediately"):
            evidence._load_json(trailing, "trailing", private=True)

    def test_rejects_wrong_boolean_type_and_failure_result(self) -> None:
        for field, value in (
            ("runOwnedPayloadCleaned", 1),
            ("outcome", "failed"),
            ("schemaVersion", True),
            ("schemaVersion", 1.0),
        ):
            result = self.fixture.mac_result()
            result[field] = value
            path = self.fixture.write_json(f"wrong-{field}-{type(value).__name__}.json", result)
            with self.assertRaises(evidence.FormalEvidenceError):
                evidence.validate_receipt(self.fixture.arguments(mac_result=path))

        result = self.fixture.mac_result()
        result["selectedIce"]["protocol"] = ["udp"]
        path = self.fixture.write_json("wrong-selected-type.json", result)
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "field types"):
            evidence.validate_receipt(self.fixture.arguments(mac_result=path))

    def test_rejects_cross_run_or_session_result(self) -> None:
        for field in ("runRef", "sessionRef"):
            result = self.fixture.mac_result()
            result[field] = "f" * 64
            path = self.fixture.write_json(f"cross-{field}.json", result)
            with self.assertRaises(evidence.FormalEvidenceError):
                evidence.validate_receipt(self.fixture.arguments(mac_result=path))

    def test_rejects_non_mlkem_suite_or_unknown_ice(self) -> None:
        result = self.fixture.mac_result()
        result["suiteWireId"] = "0x0011"
        path = self.fixture.write_json("wrong-suite.json", result)
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "ML-KEM-768"):
            evidence.validate_receipt(self.fixture.arguments(mac_result=path))
        result = self.fixture.mac_result()
        result["selectedIce"]["localCandidateType"] = "unknown"
        path = self.fixture.write_json("unknown-ice.json", result)
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "unknown or mismatched"):
            evidence.validate_receipt(self.fixture.arguments(mac_result=path))
        result = self.fixture.mac_result()
        result["selectedIce"]["remoteCandidateType"] = "relay"
        path = self.fixture.write_json("contradictory-ice.json", result)
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "contradicts"):
            evidence.validate_receipt(self.fixture.arguments(mac_result=path))

    def test_rejects_duplicate_transfer_id_or_non_durable_ack(self) -> None:
        result = self.fixture.mac_result()
        result["transfers"]["macToAndroid"]["transferId"] = TRANSFER_ANDROID_TO_MAC
        path = self.fixture.write_json("same-transfer.json", result)
        with self.assertRaises(evidence.FormalEvidenceError):
            evidence.validate_receipt(self.fixture.arguments(mac_result=path))
        result = self.fixture.mac_result()
        result["transfers"]["androidToMac"]["completeAck"] = False
        path = self.fixture.write_json("missing-ack.json", result)
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "durable commit"):
            evidence.validate_receipt(self.fixture.arguments(mac_result=path))

    def test_rejects_noncanonical_payload_bytes(self) -> None:
        result = self.fixture.mac_result()
        result["transfers"]["macToAndroid"]["sha256"] = "0" * 64
        path = self.fixture.write_json("wrong-payload.json", result)
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "canonical bytes"):
            evidence.validate_receipt(self.fixture.arguments(mac_result=path))

    def test_rejects_changed_mac_identity_or_android_preoverlay_state(self) -> None:
        result = self.fixture.mac_result()
        result["identityState"]["afterDigest"] = "f" * 64
        path = self.fixture.write_json("changed-mac-state.json", result)
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "identity/trust state changed"):
            evidence.validate_receipt(self.fixture.arguments(mac_result=path))
        changed = self.fixture.sensitive("changed-sensitive.properties")
        text = changed.read_text().replace("uid=10234", "uid=10235")
        changed.write_text(text)
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "raw sensitive preferences changed"):
            evidence.validate_receipt(self.fixture.arguments(android_sensitive_after=changed))

    def test_rejects_changed_artifact_or_process_executable(self) -> None:
        changed = self.fixture.artifact(
            "changed-host.properties", "mac_formal_host", "/tmp/FormalMacWebRTCHost", "0" * 64, 500
        )
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "host artifact changed"):
            evidence.validate_receipt(self.fixture.arguments(host_provenance_after=changed))
        process = json.loads(self.fixture.process.read_text())
        process["executablePath"] = "/tmp/other"
        changed_process = self.fixture.write_json("changed-process.json", process)
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "another executable"):
            evidence.validate_receipt(self.fixture.arguments(mac_process_identity=changed_process))

    def test_rejects_incomplete_cleanup_or_android_failure_terminal(self) -> None:
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "cleanup"):
            evidence.validate_receipt(
                self.fixture.arguments(private_file_cleanup_verified="false")
            )
        failed = self.fixture.write_text(
            "android-failed.log", self.fixture.instrumentation() + "INSTRUMENTATION_FAILED\n"
        )
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "successful test"):
            evidence.validate_receipt(self.fixture.arguments(android_instrumentation=failed))

    def test_rejects_spliced_or_wrong_instrumentation_identity(self) -> None:
        valid = self.fixture.instrumentation()
        fixtures = (
            (
                "INSTRUMENTATION_STATUS: class=com.example.UnrelatedTest\n"
                "INSTRUMENTATION_STATUS: current=1\n"
                "INSTRUMENTATION_STATUS: id=AndroidJUnitRunner\n"
                "INSTRUMENTATION_STATUS: numtests=1\n"
                "INSTRUMENTATION_STATUS: test=otherTest\n"
                "INSTRUMENTATION_STATUS_CODE: 0\n"
                "INSTRUMENTATION_CODE: 0\n"
                + valid
            ),
            valid.replace(
                "hostsCodeForAppleResponderUsingAppProcess",
                "otherTest",
                1,
            ),
        )
        for index, fixture in enumerate(fixtures):
            with self.subTest(index=index):
                path = self.fixture.write_text(f"spliced-{index}.log", fixture)
                with self.assertRaisesRegex(evidence.FormalEvidenceError, "canonical test sequence"):
                    evidence.validate_receipt(
                        self.fixture.arguments(android_instrumentation=path)
                    )

    def test_rejects_missing_duplicate_or_failed_instrumentation_terminal(self) -> None:
        valid = self.fixture.instrumentation()
        fixtures = (
            valid.replace("INSTRUMENTATION_CODE: -1\n", ""),
            valid + "INSTRUMENTATION_CODE: -1\n",
            valid.replace("INSTRUMENTATION_CODE: -1", "INSTRUMENTATION_CODE: 0"),
            valid.replace("INSTRUMENTATION_STATUS_CODE: 1", "INSTRUMENTATION_STATUS_CODE: 0"),
        )
        for index, fixture in enumerate(fixtures):
            with self.subTest(index=index):
                path = self.fixture.write_text(f"terminal-{index}.log", fixture)
                with self.assertRaisesRegex(evidence.FormalEvidenceError, "canonical test sequence"):
                    evidence.validate_receipt(
                        self.fixture.arguments(android_instrumentation=path)
                    )


class PrivateFileAndManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def create(self, kind: str, content: bytes, name: str = "private") -> tuple[Path, str, int]:
        output = self.root / name
        arguments = argparse.Namespace(
            kind=kind,
            maximum_bytes=1024,
            output=output,
        )
        stdin = io.TextIOWrapper(io.BytesIO(content), encoding="ascii")
        original_stdin = sys.stdin
        try:
            sys.stdin = stdin
            with contextlib.redirect_stdout(io.StringIO()):
                evidence.create_private_file(arguments)
        finally:
            sys.stdin = original_stdin
        return output, hashlib.sha256(output.read_bytes()).hexdigest(), len(output.read_bytes())

    def test_private_create_is_exclusive_single_link_and_0600(self) -> None:
        path, _, _ = self.create("token", short_jwt())
        metadata = path.stat()
        self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)
        self.assertEqual(metadata.st_nlink, 1)
        with self.assertRaises(evidence.FormalEvidenceError):
            self.create("token", short_jwt())

    def test_private_create_rejects_symlink_parent_or_multiline_code(self) -> None:
        target = self.root / "target"
        target.mkdir(mode=0o700)
        link = self.root / "link"
        link.symlink_to(target, target_is_directory=True)
        with self.assertRaises(evidence.FormalEvidenceError):
            evidence.create_private_file(
                argparse.Namespace(
                    kind="code",
                    maximum_bytes=100,
                    output=link / "code",
                )
            )
        with self.assertRaises(evidence.FormalEvidenceError):
            self.create("code", b"one\ntwo", "bad-code")

    def test_private_unlink_requires_exact_digest_and_fsyncs_parent(self) -> None:
        path, digest, size = self.create("code", b"ABC-123", "code")
        arguments = argparse.Namespace(
            path=path,
            expected_sha256="0" * 64,
            expected_bytes=size,
            maximum_bytes=1024,
        )
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "bytes changed"):
            evidence.unlink_private_file(arguments)
        self.assertTrue(path.exists())
        arguments.expected_sha256 = digest
        evidence.unlink_private_file(arguments)
        self.assertFalse(path.exists())

    def test_private_read_and_unlink_reject_hardlinks_and_unsafe_modes(self) -> None:
        path, digest, size = self.create("code", b"CODE-456", "linked-code")
        sibling = self.root / "linked-code-sibling"
        os.link(path, sibling)
        arguments = argparse.Namespace(
            path=path,
            expected_sha256=digest,
            expected_bytes=size,
            maximum_bytes=1024,
        )
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "single-link"):
            evidence.unlink_private_file(arguments)
        self.assertTrue(path.exists())
        self.assertTrue(sibling.exists())

        source = self.root / "unsafe-token"
        source.write_bytes(short_jwt())
        source.chmod(0o640)
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "single-link regular file"):
            evidence.copy_private_file(
                argparse.Namespace(
                    kind="token",
                    input=source,
                    maximum_bytes=1024,
                    output=self.root / "copied-token",
                )
            )

    def test_manifest_accepts_normal_launch_and_rejects_automatic_start(self) -> None:
        valid = self.root / "AndroidManifest.xml"
        valid.write_text(
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
            'package="com.skybridge.compass.debug"><application><activity android:name=".Main">'
            '<intent-filter><action android:name="android.intent.action.MAIN"/></intent-filter>'
            '</activity><receiver android:name=".Disabled" android:enabled="false">'
            '<intent-filter><action android:name="android.intent.action.BOOT_COMPLETED"/>'
            '</intent-filter></receiver></application></manifest>',
            encoding="utf-8",
        )
        output = self.root / "manifest.properties"
        evidence.validate_manifest(argparse.Namespace(manifest=valid, output=output))
        self.assertIn("automatic_start_entries_absent=true", output.read_text())

        invalid = self.root / "automatic.xml"
        invalid.write_text(
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
            'package="com.skybridge.compass.debug"><application><receiver android:name=".R">'
            '<intent-filter><action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>'
            '</intent-filter></receiver></application></manifest>',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "automatic-start action"):
            evidence.validate_manifest(
                argparse.Namespace(manifest=invalid, output=self.root / "invalid.properties")
            )

    def test_json_writer_refuses_existing_output(self) -> None:
        output = self.root / "receipt.json"
        output.write_text("existing")
        with self.assertRaises(evidence.FormalEvidenceError):
            evidence._write_json(output, {"schemaVersion": 1})

    def test_android_sensitive_snapshot_requires_exact_raw_schema(self) -> None:
        output = self.root / "sensitive.properties"
        raw = (
            "uid=10234\n"
            f"p2p_identity_bytes=11\np2p_identity_sha256={'a' * 64}\n"
            f"pqc_keys_bytes=12\npqc_keys_sha256={'b' * 64}\n"
            f"peer_kem_keys_bytes=13\npeer_kem_keys_sha256={'c' * 64}\n"
        ).encode("ascii")
        stdin = io.TextIOWrapper(io.BytesIO(raw), encoding="ascii")
        original_stdin = sys.stdin
        try:
            sys.stdin = stdin
            evidence.collect_android_sensitive(argparse.Namespace(output=output))
        finally:
            sys.stdin = original_stdin
        self.assertIn("package=com.skybridge.compass.debug", output.read_text())
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)

        duplicate = io.TextIOWrapper(io.BytesIO(raw + b"uid=10234\n"), encoding="ascii")
        original_stdin = sys.stdin
        try:
            sys.stdin = duplicate
            with self.assertRaises(evidence.FormalEvidenceError):
                evidence.collect_android_sensitive(
                    argparse.Namespace(output=self.root / "duplicate-sensitive.properties")
                )
        finally:
            sys.stdin = original_stdin

    def test_artifact_capture_streams_exact_single_link_file(self) -> None:
        artifact = self.root / "host"
        artifact.write_bytes(b"host-binary")
        output = self.root / "host.properties"
        evidence.collect_artifact(
            argparse.Namespace(path=artifact, prefix="mac_formal_host", output=output)
        )
        text = output.read_text()
        self.assertIn(
            f"mac_formal_host_sha256={hashlib.sha256(b'host-binary').hexdigest()}",
            text,
        )
        linked = self.root / "host-link"
        os.link(artifact, linked)
        with self.assertRaisesRegex(evidence.FormalEvidenceError, "single-link"):
            evidence.collect_artifact(
                argparse.Namespace(
                    path=artifact,
                    prefix="mac_formal_host",
                    output=self.root / "linked.properties",
                )
            )

    def test_token_copy_auth_context_and_secret_scan_are_private(self) -> None:
        source = self.root / "source-token"
        source.write_bytes(short_jwt())
        source.chmod(0o600)
        token = self.root / "token"
        with contextlib.redirect_stdout(io.StringIO()):
            evidence.copy_private_file(
                argparse.Namespace(
                    kind="token", input=source, maximum_bytes=1024, output=token
                )
            )
        auth = self.root / "auth.json"
        evidence.create_auth_context(
            argparse.Namespace(token_file=token, tenant_id="tenant-1", output=auth)
        )
        self.assertEqual(stat.S_IMODE(auth.stat().st_mode), 0o600)
        self.assertEqual(json.loads(auth.read_text())["tenantId"], "tenant-1")

        code = self.root / "code"
        code.write_text("CODE-123", encoding="ascii")
        code.chmod(0o600)
        safe_log = self.root / "safe.log"
        safe_log.write_text("formal host completed\n", encoding="utf-8")
        evidence.scan_private_values(
            argparse.Namespace(
                token_file=token, code_file=code, scan_file=[safe_log]
            )
        )
        leaked_log = self.root / "leaked.log"
        leaked_log.write_bytes(b"prefix " + short_jwt() + b"\n")
        with self.assertRaises(evidence.FormalEvidenceError):
            evidence.scan_private_values(
                argparse.Namespace(
                    token_file=token, code_file=code, scan_file=[leaked_log]
                )
            )

    def test_rejects_expired_or_long_lived_token(self) -> None:
        now = int(time.time())
        for issued_at, expires_at in ((now - 100, now - 1), (now, now + 901)):
            claims = base64.urlsafe_b64encode(
                json.dumps({"iat": issued_at, "exp": expires_at}).encode()
            ).rstrip(b"=")
            token = b"header." + claims + b".signature"
            with self.assertRaises(evidence.FormalEvidenceError):
                self.create("token", token, f"token-{issued_at}-{expires_at}")


if __name__ == "__main__":
    unittest.main()
