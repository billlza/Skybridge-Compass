#!/usr/bin/env python3
"""Tests for the normal-product OSLog release-evidence boundary."""

from __future__ import annotations

import importlib.util
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

from product_release_evidence_test_fixtures import (
    capture_manifest,
    connectivity_product_logs,
    golden_ios_archive_binding,
)


ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "Scripts/validate_product_release_evidence_log.py"
COLLECTOR = ROOT / "Scripts/collect_product_release_evidence_log.sh"
OWNERSHIP_HELPER = ROOT / "Scripts/webrtc_smoke_process_ownership.py"
SPEC = importlib.util.spec_from_file_location("validate_product_release_evidence_log", VALIDATOR)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to import product release evidence validator")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)
OWNERSHIP_SPEC = importlib.util.spec_from_file_location(
    "product_evidence_process_ownership", OWNERSHIP_HELPER
)
if OWNERSHIP_SPEC is None or OWNERSHIP_SPEC.loader is None:
    raise RuntimeError("unable to import process ownership helper")
OWNERSHIP_MODULE = importlib.util.module_from_spec(OWNERSHIP_SPEC)
sys.modules[OWNERSHIP_SPEC.name] = OWNERSHIP_MODULE
OWNERSHIP_SPEC.loader.exec_module(OWNERSHIP_MODULE)

SESSION_REF = "ev1:" + "ab" * 16
TRANSFER_REF = "ev1:" + "cd" * 16
SECOND_SESSION_REF = "ev1:" + "ef" * 16
SECOND_TRANSFER_REF = "ev1:" + "de" * 16


def owner_fields(
    transport: str,
    generation: int = 1,
    *,
    owner: str = "SkyBridgeCompassApp",
    session_ref: str = SESSION_REF,
) -> str:
    return (
        f"transport={transport} session_ref={session_ref} "
        f"owner={owner} generation={generation}"
    )


def p2p_remote_lines() -> list[str]:
    common = owner_fields("p2p")
    primary = [
        f"releaseSessionOwner {common} state=active routeClass=wifi",
        f"p2pSessionAuthenticated {common} role=responder suite=X-Wing result=authenticated",
        f"remoteControlNoticeShown {common} phase=awaitingApproval result=presented",
        f"remoteControlNoticePanelPresented {common} phase=awaitingApproval buttons=approve,reject result=visible",
        f"remoteControlNoticeHumanApproved {common} phase=awaitingApproval decisionSource=user result=approved",
        f"remoteControlNoticeApproved {common} phase=awaitingApproval decisionSource=user result=approved",
        f"remoteControlNoticeActive {common} phase=active result=active",
        f"secureFrameAccepted {common} frame_seq=1 effect=presented proof=p2p-renderer-ack bytes=4096 width=1280 height=720",
        f"remoteInputApplied {common} event_seq=2 effect=pointer applied=1",
        f"remoteControlNoticeDisconnected {common} phase=terminal result=disconnected",
        f"remoteControlNoticePanelHidden {common} phase=terminal result=hidden",
        f"releaseSessionDisconnected {common} noticeHidden=1 reason=user result=disconnected",
    ]
    reverse = owner_fields("p2p", generation=2, session_ref=SECOND_SESSION_REF)
    return primary + [
        f"releaseSessionOwner {reverse} state=active routeClass=awdl",
        f"p2pSessionAuthenticated {reverse} role=initiator suite=X-Wing result=authenticated",
        f"releaseSessionDisconnected {reverse} noticeHidden=not-applicable reason=user result=disconnected",
    ]


def p2p_ios_lines() -> list[str]:
    primary = owner_fields("p2p", generation=11, owner="SkyBridgeCompassiOS")
    reverse = owner_fields(
        "p2p",
        generation=12,
        owner="SkyBridgeCompassiOS",
        session_ref=SECOND_SESSION_REF,
    )
    return [
        f"releaseSessionOwner {primary} state=active routeClass=wifi",
        f"p2pSessionAuthenticated {primary} role=initiator suite=X-Wing result=authenticated",
        f"releaseSessionDisconnected {primary} noticeHidden=not-applicable reason=peer result=disconnected",
        f"releaseSessionOwner {reverse} state=active routeClass=awdl",
        f"p2pSessionAuthenticated {reverse} role=responder suite=X-Wing result=authenticated",
        f"releaseSessionDisconnected {reverse} noticeHidden=not-applicable reason=peer result=disconnected",
    ]


def webrtc_remote_lines() -> list[str]:
    common = owner_fields("webrtc")
    return [
        f"releaseSessionOwner {common} state=active selectedTransport=relay",
        f"webrtcPQCRekeyAuthenticated {common} suite=X-Wing result=authenticated",
        f"remoteControlNoticeShown {common} phase=awaitingApproval result=presented",
        f"remoteControlNoticePanelPresented {common} phase=awaitingApproval buttons=approve,reject result=visible",
        f"remoteControlNoticeHumanApproved {common} phase=awaitingApproval decisionSource=user result=approved",
        f"remoteControlNoticeApproved {common} phase=awaitingApproval decisionSource=user result=approved",
        f"remoteControlNoticeActive {common} phase=active result=active",
        f"secureFrameAccepted {common} frame_seq=1 effect=presented proof=webrtc-renderer-receipt bytes=4096 width=1280 height=720",
        f"remoteInputApplied {common} event_seq=2 effect=pointer applied=1",
        f"webrtcMediaSample {common} mediaRole=sender sample_seq=1 elapsed_ms=1000 video_frames=60 video_bytes=65536 audio_units=100 audio_bytes=8192 result=flowing",
        f"webrtcMediaSample {common} mediaRole=sender sample_seq=2 elapsed_ms=32000 video_frames=1920 video_bytes=2097152 audio_units=3200 audio_bytes=262144 result=flowing",
        f"remoteControlNoticeDisconnected {common} phase=terminal result=disconnected",
        f"remoteControlNoticePanelHidden {common} phase=terminal result=hidden",
        f"releaseSessionDisconnected {common} noticeHidden=1 reason=user result=disconnected",
    ]


def webrtc_ios_lines() -> list[str]:
    common = owner_fields("webrtc", generation=11, owner="SkyBridgeCompassiOS")
    return [
        f"releaseSessionOwner {common} state=active selectedTransport=relay",
        f"webrtcPQCRekeyAuthenticated {common} suite=X-Wing result=authenticated",
        f"webrtcMediaSample {common} mediaRole=receiver sample_seq=1 elapsed_ms=1200 video_frames=55 video_bytes=60000 audio_units=95 audio_bytes=7800 result=flowing",
        f"webrtcMediaSample {common} mediaRole=receiver sample_seq=2 elapsed_ms=32500 video_frames=1850 video_bytes=2000000 audio_units=3100 audio_bytes=250000 result=flowing",
        f"releaseSessionDisconnected {common} noticeHidden=not-applicable reason=peer result=disconnected",
    ]


def file_transfer_lines() -> list[str]:
    common = owner_fields("p2p")
    reverse = owner_fields("p2p", generation=2)
    return [
        f"releaseSessionOwner {common} state=active routeClass=awdl",
        f"p2pSessionAuthenticated {common} role=initiator suite=X-Wing result=authenticated",
        f"fileTransferStarted {common} transfer_ref={TRANSFER_REF} direction=send interaction=send-ui payload=nonempty result=started",
        f"fileTransferCompleted {common} transfer_ref={TRANSFER_REF} direction=send interaction=send-ui payload=nonempty integrity=verified receipt=authenticated result=success uiEffect=completed",
        f"releaseSessionDisconnected {common} noticeHidden=not-applicable reason=peer result=disconnected",
        f"releaseSessionOwner {reverse} state=active routeClass=awdl",
        f"p2pSessionAuthenticated {reverse} role=responder suite=X-Wing result=authenticated",
        f"fileTransferStarted {reverse} transfer_ref={SECOND_TRANSFER_REF} direction=receive interaction=accept-ui payload=nonempty result=started",
        f"fileTransferCompleted {reverse} transfer_ref={SECOND_TRANSFER_REF} direction=receive interaction=accept-ui payload=nonempty integrity=verified receipt=authenticated result=success uiEffect=completed",
        f"releaseSessionDisconnected {reverse} noticeHidden=not-applicable reason=peer result=disconnected",
    ]


def file_transfer_ios_lines() -> list[str]:
    common = owner_fields("p2p", generation=11, owner="SkyBridgeCompassiOS")
    reverse = owner_fields("p2p", generation=12, owner="SkyBridgeCompassiOS")
    return [
        f"releaseSessionOwner {common} state=active routeClass=awdl",
        f"p2pSessionAuthenticated {common} role=responder suite=X-Wing result=authenticated",
        f"fileTransferStarted {common} transfer_ref={TRANSFER_REF} direction=receive interaction=accept-ui payload=nonempty result=started",
        f"fileTransferCompleted {common} transfer_ref={TRANSFER_REF} direction=receive interaction=accept-ui payload=nonempty integrity=verified receipt=authenticated result=success uiEffect=completed",
        f"releaseSessionDisconnected {common} noticeHidden=not-applicable reason=user result=disconnected",
        f"releaseSessionOwner {reverse} state=active routeClass=awdl",
        f"p2pSessionAuthenticated {reverse} role=initiator suite=X-Wing result=authenticated",
        f"fileTransferStarted {reverse} transfer_ref={SECOND_TRANSFER_REF} direction=send interaction=send-ui payload=nonempty result=started",
        f"fileTransferCompleted {reverse} transfer_ref={SECOND_TRANSFER_REF} direction=send interaction=send-ui payload=nonempty integrity=verified receipt=authenticated result=success uiEffect=completed",
        f"releaseSessionDisconnected {reverse} noticeHidden=not-applicable reason=user result=disconnected",
    ]


def connectivity_lines() -> tuple[list[str], list[str]]:
    return connectivity_product_logs()


class ProductReleaseEvidenceLogTests(unittest.TestCase):
    def write_artifact(
        self,
        root: Path,
        lines: list[str],
        *,
        ios_lines: list[str] | None = None,
        process_id: int = 4321,
    ) -> Path:
        artifact = root / "artifact"
        artifact.mkdir(mode=0o700)
        log_path = artifact / MODULE.MAC_LOG_FILE
        log_path.write_text("\n".join(lines) + "\n", encoding="ascii")
        log_path.chmod(0o600)
        self.write_capture(
            artifact / MODULE.MAC_CAPTURE_FILE,
            owner=MODULE.MAC_PRODUCT,
            event_count=len(lines),
            process_id=process_id,
        )
        if ios_lines is not None:
            release_manifest = artifact / "release-acceptance.json"
            release_manifest.write_text(
                json.dumps(
                    {"iosReleaseArchive": golden_ios_archive_binding()},
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            release_manifest.chmod(0o600)
            ios_log_path = artifact / MODULE.IOS_LOG_FILE
            ios_log_path.write_text("\n".join(ios_lines) + "\n", encoding="ascii")
            ios_log_path.chmod(0o600)
            self.write_capture(
                artifact / MODULE.IOS_CAPTURE_FILE,
                owner=MODULE.IOS_PRODUCT,
                event_count=len(ios_lines),
                process_id=process_id + 1,
            )
        return artifact

    def write_capture(
        self,
        path: Path,
        *,
        owner: str,
        event_count: int,
        process_id: int,
    ) -> None:
        capture = capture_manifest(owner, event_count, process_id)
        path.write_text(
            json.dumps(capture, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        path.chmod(0o600)

    def write_ownership_record(
        self, root: Path, executable: Path, *, process_id: int = 4321
    ) -> Path:
        private = root / "private-ownership"
        private.mkdir(mode=0o700)
        record = private / "candidate-process-ownership.json"
        record.write_text(
            json.dumps(
                {
                    "auditToken": [0, 501, 501, 501, 501, process_id, 0, 19732],
                    "executablePath": os.path.realpath(executable),
                    "platform": "macos",
                    "processIdentifier": process_id,
                    "schemaVersion": 1,
                    "startTimeToken": "1700000000:123456",
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        record.chmod(0o600)
        return record

    def test_all_four_canonical_product_contracts_pass(self) -> None:
        mac_connectivity, ios_connectivity = connectivity_lines()
        fixtures = {
            "connectivity": (mac_connectivity, ios_connectivity),
            "p2p": (p2p_remote_lines(), p2p_ios_lines()),
            "webrtc": (webrtc_remote_lines(), webrtc_ios_lines()),
            "file-transfer": (file_transfer_lines(), file_transfer_ios_lines()),
        }
        for kind, (lines, ios_lines) in fixtures.items():
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                artifact = self.write_artifact(
                    Path(temporary), lines, ios_lines=ios_lines
                )
                MODULE.validate_artifact_log(artifact, kind)

    def test_extract_oslog_strips_machine_metadata_and_records_pid_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executable = root / "SkyBridgeCompassApp"
            executable.write_bytes(b"candidate executable")
            executable.chmod(0o700)
            raw = root / "raw.ndjson"
            rows = [
                {
                    "eventType": "logEvent",
                    "messageType": "Default",
                    "subsystem": MODULE.SUBSYSTEM,
                    "category": MODULE.CATEGORY,
                    "processID": 4321,
                    "processImagePath": os.fspath(executable),
                    "formatString": "%{public}s",
                    "eventMessage": line,
                    "bootUUID": "must-not-be-published",
                    "timestamp": "2026-08-12 12:00:00+0800",
                }
                for line in p2p_remote_lines()
            ]
            raw.write_text(
                "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows),
                encoding="utf-8",
            )
            output = root / MODULE.LOG_FILE
            capture = root / MODULE.CAPTURE_FILE
            ownership = self.write_ownership_record(root, executable)
            MODULE.extract_oslog(raw, 4321, executable, ownership, output, capture)
            self.assertEqual(output.read_text(encoding="ascii"), "\n".join(p2p_remote_lines()) + "\n")
            self.assertNotIn("bootUUID", output.read_text(encoding="ascii"))
            MODULE.validate_capture_manifest(capture, len(rows))

    def test_extract_oslog_rejects_wrong_pid_process_or_private_format(self) -> None:
        mutations = {
            "pid": {"processID": 9999},
            "path": {"processImagePath": "/bin/sh"},
            "privacy": {"formatString": "%{private}s"},
        }
        for label, mutation in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                executable = root / "SkyBridgeCompassApp"
                executable.write_bytes(b"candidate executable")
                executable.chmod(0o700)
                row = {
                    "eventType": "logEvent",
                    "messageType": "Default",
                    "subsystem": MODULE.SUBSYSTEM,
                    "category": MODULE.CATEGORY,
                    "processID": 4321,
                    "processImagePath": os.fspath(executable),
                    "formatString": "%{public}s",
                    "eventMessage": p2p_remote_lines()[0],
                    **mutation,
                }
                raw = root / "raw.ndjson"
                raw.write_text(json.dumps(row) + "\n", encoding="utf-8")
                ownership = self.write_ownership_record(root, executable)
                with self.assertRaises(MODULE.ProductEvidenceError):
                    MODULE.extract_oslog(
                        raw,
                        4321,
                        executable,
                        ownership,
                        root / MODULE.LOG_FILE,
                        root / MODULE.CAPTURE_FILE,
                    )

    def test_private_ownership_record_rejects_pid_or_path_mismatch(self) -> None:
        mutations = ("pid", "path", "start", "audit")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                executable = root / "SkyBridgeCompassApp"
                executable.write_bytes(b"candidate executable")
                executable.chmod(0o700)
                record = self.write_ownership_record(root, executable)
                payload = json.loads(record.read_text(encoding="utf-8"))
                if mutation == "pid":
                    payload["processIdentifier"] = 9999
                elif mutation == "path":
                    payload["executablePath"] = "/bin/sh"
                elif mutation == "start":
                    payload["startTimeToken"] = "0:0"
                else:
                    payload["auditToken"][5] = 9999
                record.write_text(
                    json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
                )
                with self.assertRaises(MODULE.ProductEvidenceError):
                    MODULE._read_private_ownership_record(record, 4321, executable)

    def test_same_path_pid_reuse_or_audit_replacement_is_unverifiable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executable = root / "SkyBridgeCompassApp"
            executable.write_bytes(b"candidate executable")
            executable.chmod(0o700)
            record = self.write_ownership_record(root, executable)
            expected_audit = (0, 501, 501, 501, 501, 4321, 0, 19732)
            replacements = (
                OWNERSHIP_MODULE.MacProcessSnapshot(
                    audit_token=expected_audit,
                    executable_path=os.path.realpath(executable),
                    start_time_token="1700000001:123456",
                ),
                OWNERSHIP_MODULE.MacProcessSnapshot(
                    audit_token=(*expected_audit[:-1], 19733),
                    executable_path=os.path.realpath(executable),
                    start_time_token="1700000000:123456",
                ),
            )
            original = OWNERSHIP_MODULE._read_stable_mac_snapshot
            try:
                for replacement in replacements:
                    OWNERSHIP_MODULE._read_stable_mac_snapshot = lambda _pid, value=replacement: value
                    with contextlib.redirect_stderr(io.StringIO()):
                        status = OWNERSHIP_MODULE.mac_status(record)
                    self.assertEqual(status, OWNERSHIP_MODULE.UNVERIFIABLE)
            finally:
                OWNERSHIP_MODULE._read_stable_mac_snapshot = original

    def test_collector_checks_audit_token_ownership_before_and_after_capture(self) -> None:
        source = COLLECTOR.read_text(encoding="utf-8")
        self.assertIn("webrtc_smoke_process_ownership.py", source)
        self.assertIn("mac-capture", source)
        self.assertGreaterEqual(source.count("mac-status --identity"), 2)
        self.assertIn("--ownership-record \"$OWNERSHIP_RECORD\"", source)
        self.assertNotIn("/bin/ps", source)

    def test_helper_owner_and_unknown_field_are_rejected(self) -> None:
        mutations = (
            p2p_remote_lines()[0].replace("SkyBridgeCompassApp", "LocalLanInteropHost"),
            p2p_remote_lines()[0] + " account=user@example.com",
        )
        for line in mutations:
            with self.subTest(line=line):
                with self.assertRaises(MODULE.ProductEvidenceError):
                    MODULE._parse_event_line(line, 1)

    def test_remote_contract_rejects_missing_human_decision(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            lines = [
                line
                for line in p2p_remote_lines()
                if not line.startswith("remoteControlNoticeHumanApproved ")
            ]
            artifact = self.write_artifact(Path(temporary), lines)
            with self.assertRaisesRegex(MODULE.ProductEvidenceError, "HumanApproved"):
                MODULE.validate_artifact_log(artifact, "p2p")

    def test_remote_contract_rejects_decoded_without_presented_effect(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            lines = [
                line.replace("effect=presented", "effect=decoded")
                for line in p2p_remote_lines()
            ]
            artifact = self.write_artifact(Path(temporary), lines)
            with self.assertRaisesRegex(MODULE.ProductEvidenceError, "must be presented"):
                MODULE.validate_artifact_log(artifact, "p2p")

    def test_remote_contract_requires_transport_matched_peer_renderer_proof(self) -> None:
        fixtures = {
            "p2p": (
                p2p_remote_lines(),
                "proof=p2p-renderer-ack",
                "proof=webrtc-renderer-receipt",
            ),
            "webrtc": (
                webrtc_remote_lines(),
                "proof=webrtc-renderer-receipt",
                "proof=p2p-renderer-ack",
            ),
        }
        for kind, (lines, old, wrong) in fixtures.items():
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                mismatched = [line.replace(old, wrong) for line in lines]
                artifact = self.write_artifact(Path(temporary), mismatched)
                with self.assertRaisesRegex(MODULE.ProductEvidenceError, "peer .* renderer"):
                    MODULE.validate_artifact_log(artifact, kind)

    def test_local_frame_presented_cannot_satisfy_formal_secure_frame_effect(self) -> None:
        for kind, lines in {
            "p2p": p2p_remote_lines(),
            "webrtc": webrtc_remote_lines(),
        }.items():
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                local_only = [
                    line.replace("secureFrameAccepted", "localFramePresented")
                    .replace("frame_seq=1", "local_frame_seq=1")
                    .replace("proof=p2p-renderer-ack", "proof=local-renderer")
                    .replace("proof=webrtc-renderer-receipt", "proof=local-renderer")
                    for line in lines
                ]
                artifact = self.write_artifact(Path(temporary), local_only)
                with self.assertRaisesRegex(MODULE.ProductEvidenceError, "secureFrameAccepted"):
                    MODULE.validate_artifact_log(artifact, kind)

    def test_local_frame_presented_is_accepted_only_as_non_formal_telemetry(self) -> None:
        for kind, lines in {
            "p2p": p2p_remote_lines(),
            "webrtc": webrtc_remote_lines(),
        }.items():
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                secure_index = next(
                    index
                    for index, line in enumerate(lines)
                    if line.startswith("secureFrameAccepted ")
                )
                fields = owner_fields(kind)
                local = (
                    f"localFramePresented {fields} local_frame_seq=1 effect=presented "
                    "proof=local-renderer bytes=2048 width=640 height=480"
                )
                lines.insert(secure_index, local)
                ios_lines = p2p_ios_lines() if kind == "p2p" else webrtc_ios_lines()
                artifact = self.write_artifact(
                    Path(temporary), lines, ios_lines=ios_lines
                )
                MODULE.validate_artifact_log(artifact, kind)

    def test_webrtc_contract_rejects_direct_transport(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            lines = [line.replace("selectedTransport=relay", "selectedTransport=direct") for line in webrtc_remote_lines()]
            artifact = self.write_artifact(Path(temporary), lines)
            with self.assertRaisesRegex(MODULE.ProductEvidenceError, "selected relay"):
                MODULE.validate_artifact_log(artifact, "webrtc")

    def test_effect_sequence_must_be_strictly_increasing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            lines = [line.replace("event_seq=2", "event_seq=1") for line in p2p_remote_lines()]
            artifact = self.write_artifact(Path(temporary), lines)
            with self.assertRaisesRegex(MODULE.ProductEvidenceError, "strictly increasing"):
                MODULE.validate_artifact_log(artifact, "p2p")

    def test_each_effect_must_occur_within_the_active_lifecycle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            lines = p2p_remote_lines()
            effect = next(
                line for line in lines if line.startswith("remoteInputApplied ")
            )
            lines.remove(effect)
            disconnected_index = next(
                index
                for index, line in enumerate(lines)
                if line.startswith("remoteControlNoticeDisconnected ")
            )
            lines.insert(disconnected_index + 1, effect)
            artifact = self.write_artifact(Path(temporary), lines)
            with self.assertRaisesRegex(MODULE.ProductEvidenceError, "notice is active"):
                MODULE.validate_artifact_log(artifact, "p2p")

    def test_optional_local_frame_and_input_effects_are_bounded(self) -> None:
        common = owner_fields("p2p")
        mutations = {
            "local frame": [
                f"localFramePresented {common} local_frame_seq=1 effect=presented "
                "proof=local-renderer bytes=2048 width=640 height=480",
                f"localFramePresented {common} local_frame_seq=2 effect=presented "
                "proof=local-renderer bytes=2048 width=640 height=480",
            ],
            "input effect": [
                f"remoteInputApplied {common} event_seq=3 effect=pointer applied=1",
            ],
        }
        expected_errors = {
            "local frame": "at most one localFramePresented",
            "input effect": "duplicates a bounded input effect",
        }
        for label, additions in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                lines = p2p_remote_lines()
                insertion = next(
                    index
                    for index, line in enumerate(lines)
                    if line.startswith("secureFrameAccepted ")
                )
                lines[insertion:insertion] = additions
                artifact = self.write_artifact(Path(temporary), lines)
                with self.assertRaisesRegex(
                    MODULE.ProductEvidenceError, expected_errors[label]
                ):
                    MODULE.validate_artifact_log(artifact, "p2p")

    def test_file_transfer_rejects_byte_or_reference_mismatch(self) -> None:
        mutations = (
            (
                f"transfer_ref={TRANSFER_REF} direction=send result=success",
                f"transfer_ref={SESSION_REF} direction=send result=success",
            ),
        )
        for old, new in mutations:
            with self.subTest(old=old), tempfile.TemporaryDirectory() as temporary:
                lines = [line.replace(old, new) for line in file_transfer_lines()]
                artifact = self.write_artifact(Path(temporary), lines)
                with self.assertRaises(MODULE.ProductEvidenceError):
                    MODULE.validate_artifact_log(artifact, "file-transfer")

    def test_ios_disconnect_cannot_claim_mac_notice_hidden(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            ios_lines = [
                line.replace("noticeHidden=not-applicable", "noticeHidden=1")
                for line in p2p_ios_lines()
            ]
            artifact = self.write_artifact(
                Path(temporary), p2p_remote_lines(), ios_lines=ios_lines
            )
            with self.assertRaisesRegex(
                MODULE.ProductEvidenceError, "invalid disconnect result"
            ):
                MODULE.validate_artifact_log(artifact, "p2p")

    def test_per_session_event_limit_matches_product_recorder(self) -> None:
        lines = p2p_remote_lines()
        insertion = next(
            index
            for index, line in enumerate(lines)
            if line.startswith("remoteControlNoticeDisconnected ")
        )
        common = owner_fields("p2p")
        lines[insertion:insertion] = [
            f"remoteInputApplied {common} event_seq=3 effect=keyboard applied=1",
            f"remoteInputApplied {common} event_seq=4 effect=scroll applied=1",
        ]
        events = [
            MODULE._parse_event_line(line, index)
            for index, line in enumerate(lines, 1)
        ]
        self.assertLessEqual(len(events), MODULE.MAX_EVENT_COUNT_PER_SESSION)
        sessions = MODULE._sessions(events)
        self.assertEqual(len(sessions), 2)
        primary_owner = events[0]
        repeatable = next(
            event for event in events if event.name == "remoteInputApplied"
        )
        primary_disconnect = next(
            event for event in events if event.name == "releaseSessionDisconnected"
        )
        oversized = [primary_owner] + [repeatable] * MODULE.MAX_EVENT_COUNT_PER_SESSION \
            + [primary_disconnect]
        with self.assertRaisesRegex(MODULE.ProductEvidenceError, "fixed 20-event"):
            MODULE._sessions(oversized)

    def test_connectivity_requires_exact_fixed_matrix(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            mac_lines, ios_lines = connectivity_lines()
            mac_lines = [line for line in mac_lines if "attempt_ref=at1:" + "3" * 32 not in line]
            ios_lines = [line for line in ios_lines if "attempt_ref=at1:" + "3" * 32 not in line]
            artifact = self.write_artifact(
                Path(temporary), mac_lines, ios_lines=ios_lines
            )
            with self.assertRaisesRegex(MODULE.ProductEvidenceError, "three success profile pairs"):
                MODULE.validate_artifact_log(artifact, "connectivity")

    def test_connectivity_rejects_legacy_case_and_external_helper_labels(self) -> None:
        legacy = (
            "connectivityCase transport=p2p session_ref="
            f"{SESSION_REF} owner=SkyBridgeCompassApp generation=1 "
            "case=xwing-xwing initiator=xwing responder=xwing suite=X-Wing "
            "direction=mac-to-ios result=success"
        )
        external = (
            "[2026-08-12T12:00:00Z] connectivity-case id=mac-ios-xwing-xwing "
            "result=success"
        )
        for line in (legacy, external):
            with self.subTest(line=line):
                with self.assertRaises(MODULE.ProductEvidenceError):
                    MODULE._parse_event_line(line, 1)

    def test_connectivity_rejects_cross_endpoint_join_drift(self) -> None:
        for label in ("session", "suite", "attempt-profile", "role"):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                mac_lines, ios_lines = connectivity_lines()
                target_attempt = "3" if label == "attempt-profile" else "2"
                target = "attempt_ref=at1:" + target_attempt * 32
                mutated: list[str] = []
                for line in ios_lines:
                    if target not in line:
                        mutated.append(line)
                        continue
                    if label == "session":
                        line = line.replace(
                            "session_ref=ev1:" + "2" * 32,
                            "session_ref=ev1:" + "a" * 32,
                        )
                    elif label == "suite":
                        line = line.replace(
                            "suite=ML-KEM-768", "suite=ML-KEM-768-FS"
                        )
                    elif label == "attempt-profile":
                        line = line.replace("attemptProfile=xwing", "attemptProfile=pqc")
                        line = line.replace("suite=X-Wing", "suite=ML-KEM-768")
                    else:
                        line = line.replace("role=responder", "role=initiator")
                    mutated.append(line)
                artifact = self.write_artifact(
                    Path(temporary), mac_lines, ios_lines=mutated
                )
                expected_error = (
                    "complementary roles"
                    if label == "role"
                    else "disagree on session, suite, or attempt profile"
                )
                with self.assertRaisesRegex(MODULE.ProductEvidenceError, expected_error):
                    MODULE.validate_artifact_log(artifact, "connectivity")

    def test_connectivity_rejects_local_generation_or_offer_drift(self) -> None:
        for label in (
            "generation",
            "generation-reuse",
            "offered-suite-family",
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                mac_lines, ios_lines = connectivity_lines()
                target_byte = "2" if label.startswith("generation") else "3"
                target = "attempt_ref=at1:" + target_byte * 32
                mutation_count = 0
                output: list[str] = []
                for line in mac_lines:
                    if target in line:
                        if label == "generation" and mutation_count == 0:
                            line = line.replace(
                                "generation=2 role=", "generation=9 role="
                            )
                            mutation_count += 1
                        elif label == "generation-reuse":
                            replacement = line.replace(
                                "generation=2 role=", "generation=1 role="
                            )
                            if replacement != line:
                                mutation_count += 1
                            line = replacement
                        elif label == "offered-suite-family":
                            replacement = line.replace(
                                "offeredProfiles=pqc+xwing",
                                "offeredProfiles=pqc",
                            )
                            if replacement != line:
                                mutation_count += 1
                            line = replacement
                    output.append(line)
                self.assertEqual(
                    mutation_count, 1 if label == "generation" else 3
                )
                artifact = self.write_artifact(
                    Path(temporary), output, ios_lines=ios_lines
                )
                expected_error = (
                    "changes local field generation"
                    if label == "generation"
                    else "reuses one local generation across attempts"
                    if label == "generation-reuse"
                    else "negotiated suite family was absent from its actual offer"
                )
                with self.assertRaisesRegex(MODULE.ProductEvidenceError, expected_error):
                    MODULE.validate_artifact_log(artifact, "connectivity")

    def test_connectivity_rejections_require_verified_shipping_responder_pairs(self) -> None:
        mutations = {
            "signature": ("peerOfferSignature=verified", "peerOfferSignature=claimed"),
            "role": ("role=responder", "role=initiator"),
            "terminal": ("connectivityPolicyRejected", "connectivityAttemptAuthenticated"),
        }
        for label, (old, new) in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                mac_lines, ios_lines = connectivity_lines()
                mac_lines = [
                    line.replace(old, new)
                    if "attempt_ref=at1:" + "4" * 32 in line
                    else line
                    for line in mac_lines
                ]
                artifact = self.write_artifact(
                    Path(temporary), mac_lines, ios_lines=ios_lines
                )
                with self.assertRaises(MODULE.ProductEvidenceError):
                    MODULE.validate_artifact_log(artifact, "connectivity")

    def test_connectivity_requires_ios_candidate_bound_product_capture(self) -> None:
        for mutation in (
            "missing-log",
            "missing-capture",
            "unbound-capture",
            "invalid-archive",
        ):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                mac_lines, ios_lines = connectivity_lines()
                artifact = self.write_artifact(
                    Path(temporary), mac_lines, ios_lines=ios_lines
                )
                if mutation == "missing-log":
                    (artifact / MODULE.IOS_LOG_FILE).unlink()
                elif mutation == "missing-capture":
                    (artifact / MODULE.IOS_CAPTURE_FILE).unlink()
                else:
                    capture_path = artifact / MODULE.IOS_CAPTURE_FILE
                    payload = json.loads(capture_path.read_text(encoding="utf-8"))
                    if mutation == "unbound-capture":
                        payload["releaseArchiveBindingVerified"] = False
                    else:
                        payload["iosReleaseArchive"]["releaseVersion"] = "not-a-version"
                    capture_path.write_text(
                        json.dumps(payload, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8",
                    )
                with self.assertRaises((OSError, MODULE.ProductEvidenceError)):
                    MODULE.validate_artifact_log(artifact, "connectivity")

    def test_python_consumer_accepts_the_rust_golden_fixture(self) -> None:
        fixture = (
            ROOT
            / "rust/crates/skybridge-cli/tests/fixtures/connectivity/mac-ios-matrix-pass"
        )
        MODULE.validate_artifact_log(fixture, "connectivity")

    def test_decode_only_qperiapt_suite_is_not_formal_connectivity_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            mac_lines, ios_lines = connectivity_lines()
            mac_lines = [
                line.replace("suite=ML-KEM-768", "suite=Q-Periapt-ContextBound")
                if "attempt_ref=at1:" + "2" * 32 in line
                else line
                for line in mac_lines
            ]
            ios_lines = [
                line.replace("suite=ML-KEM-768", "suite=Q-Periapt-ContextBound")
                if "attempt_ref=at1:" + "2" * 32 in line
                else line
                for line in ios_lines
            ]
            artifact = self.write_artifact(
                Path(temporary), mac_lines, ios_lines=ios_lines
            )
            with self.assertRaisesRegex(MODULE.ProductEvidenceError, "suite/result"):
                MODULE.validate_artifact_log(artifact, "connectivity")


if __name__ == "__main__":
    unittest.main()
