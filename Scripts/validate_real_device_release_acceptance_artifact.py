#!/usr/bin/env python3
"""Validate that a public smoke artifact is eligible for release acceptance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
from datetime import datetime
from pathlib import Path
from typing import Any, NoReturn


MIN_WEBRTC_SOAK_SECONDS = 10
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_STATUS_LOG_BYTES = 64 * 1024 * 1024
MAX_MEDIA_LOG_BYTES = 256 * 1024 * 1024
FINALIZATION_ORDER = "private-then-public-v1"
RELEASE_MANIFEST_MODE = 0o600
SESSION_REF_PATTERN = re.compile(r"[0-9a-f]{24}")
SOURCE_REPOSITORY_COMPONENT_PATTERN = re.compile(r"[A-Za-z0-9_.-]+")
SOURCE_COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
PRODUCTION_IDENTITY_PROOF_FILE = "ios-production-identity-proof.json"
PRODUCTION_PRODUCT_SURFACE = "production"
REQUIRED_IDENTITY_ALGORITHM = "mldsa87"
REQUIRED_IDENTITY_PROTECTION = "secureEnclaveRequired"
FORBIDDEN_PRODUCTION_COMPILATION_CONDITIONS = {"DEBUG", "SKYBRIDGE_TESTING"}
REQUIRED_WEBRTC_CHECKS = {
    "diagnostic_sources",
    "diagnostic_samples",
    "video_fps",
    "video_resolution",
    "native_video_health",
    "native_video_rtc_stats",
    "sck_vt_encode_latency",
    "native_video_receiver",
    "visible_native_render",
    "visible_render_fps",
    "audio_activity_continuity",
    "audio_playback_continuity",
    "audio_relay_startup",
    "audio_tx_captured",
    "audio_tx_encoded",
    "audio_tx_sent",
    "audio_rx_recv",
    "audio_rx_decoded",
    "audio_rx_played",
    "audio_rendered_frames",
    "strict_media_failure",
    "stale_fallback",
    "backpressure",
    "probable_fault_stage",
}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"release acceptance artifact rejected: {message}")


def require_regular_file(path: Path, label: str, *, nonempty: bool = True) -> Path:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        fail(f"missing {label}: {path.name}")
    except OSError as exc:
        fail(f"unable to open {label} without following links: {exc}")
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"{label} must be a regular file, not a symlink or special file: {path.name}")
        if nonempty and metadata.st_size == 0:
            fail(f"{label} is empty: {path.name}")
    finally:
        os.close(descriptor)
    return path


def read_regular_file(
    path: Path,
    label: str,
    *,
    maximum_bytes: int,
    require_release_manifest_metadata: bool = False,
) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        fail(f"missing {label}: {path.name}")
    except OSError as exc:
        fail(f"unable to open {label} without following links: {exc}")
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"{label} must be a regular file, not a symlink or special file: {path.name}")
        if require_release_manifest_metadata:
            if metadata.st_uid != os.geteuid():
                fail(f"{label} must be owned by the current effective user")
            if metadata.st_nlink != 1:
                fail(f"{label} must have exactly one filesystem link")
            if stat.S_IMODE(metadata.st_mode) != RELEASE_MANIFEST_MODE:
                fail(f"{label} mode must be 0600")
        if metadata.st_size == 0:
            fail(f"{label} is empty: {path.name}")
        if metadata.st_size > maximum_bytes:
            fail(f"{label} exceeds the {maximum_bytes}-byte validation limit")
        chunks: list[bytes] = []
        remaining = maximum_bytes + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        content = b"".join(chunks)
        if len(content) > maximum_bytes:
            fail(f"{label} exceeds the {maximum_bytes}-byte validation limit")
        final_metadata = os.fstat(descriptor)
        try:
            path_metadata = os.stat(path, follow_symlinks=False)
        except OSError as exc:
            fail(f"unable to verify stable {label} path after reading: {exc}")
        if (
            final_metadata.st_dev != metadata.st_dev
            or final_metadata.st_ino != metadata.st_ino
            or final_metadata.st_size != metadata.st_size
            or path_metadata.st_dev != final_metadata.st_dev
            or path_metadata.st_ino != final_metadata.st_ino
            or len(content) != final_metadata.st_size
        ):
            fail(f"{label} changed while it was being validated")
        if require_release_manifest_metadata:
            if final_metadata.st_uid != os.geteuid():
                fail(f"{label} must be owned by the current effective user")
            if final_metadata.st_nlink != 1:
                fail(f"{label} must have exactly one filesystem link")
            if stat.S_IMODE(final_metadata.st_mode) != RELEASE_MANIFEST_MODE:
                fail(f"{label} mode must be 0600")
        return content
    finally:
        os.close(descriptor)


def load_json(
    path: Path,
    label: str,
    *,
    require_release_manifest_metadata: bool = False,
) -> dict[str, Any]:
    try:
        value = json.loads(
            read_regular_file(
                path,
                label,
                maximum_bytes=MAX_JSON_BYTES,
                require_release_manifest_metadata=require_release_manifest_metadata,
            ).decode("utf-8")
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"invalid {label} JSON: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def require_exact_bool(payload: dict[str, Any], key: str, expected: bool) -> None:
    if payload.get(key) is not expected:
        fail(f"{key} must be {str(expected).lower()}")


def require_session_ref(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or SESSION_REF_PATTERN.fullmatch(value) is None:
        fail(f"{key} must be a 24-character lowercase hexadecimal session reference")
    return value


def require_non_bool_int(payload: dict[str, Any], key: str) -> int:
    value = payload.get(key)
    if type(value) is not int:
        fail(f"{key} must be an integer")
    return value


def is_source_repository(value: str) -> bool:
    components = value.split("/")
    return len(components) == 2 and all(
        component not in {"", ".", ".."}
        and SOURCE_REPOSITORY_COMPONENT_PATTERN.fullmatch(component) is not None
        for component in components
    )


def require_source_repository(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not is_source_repository(value):
        fail(f"{key} must be an owner/repository identifier")
    return value


def require_source_commit(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or SOURCE_COMMIT_PATTERN.fullmatch(value) is None:
        fail(f"{key} must be a full lowercase 40-character Git revision")
    return value


def require_production_compilation_conditions(
    payload: dict[str, Any], key: str
) -> tuple[str, ...]:
    value = payload.get(key)
    if (
        not isinstance(value, list)
        or not value
        or any(
            not isinstance(condition, str)
            or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", condition) is None
            for condition in value
        )
        or len(value) != len(set(value))
    ):
        fail(f"{key} must be a non-empty unique compilation-condition array")
    conditions = tuple(sorted(value))
    forbidden = sorted(FORBIDDEN_PRODUCTION_COMPILATION_CONDITIONS.intersection(conditions))
    if forbidden:
        fail(f"{key} contains test-only conditions: {','.join(forbidden)}")
    if "HAS_APPLE_PQC_SDK" not in conditions:
        fail(f"{key} must contain HAS_APPLE_PQC_SDK")
    return conditions


def validate_production_identity_proof(
    artifact_dir: Path,
    *,
    expected_repository: str,
    expected_source_sha: str,
    manifest: dict[str, Any] | None = None,
) -> None:
    proof = load_json(
        artifact_dir / PRODUCTION_IDENTITY_PROOF_FILE,
        "iOS production identity proof",
    )
    if type(proof.get("schemaVersion")) is not int or proof.get("schemaVersion") != 1:
        fail("iOS production identity proof schemaVersion must be 1")

    source_repository = require_source_repository(proof, "sourceRepository")
    source_commit = require_source_commit(proof, "sourceCommit")
    if source_repository != expected_repository:
        fail("iOS production identity proof sourceRepository does not match the release repository")
    if source_commit != expected_source_sha:
        fail("iOS production identity proof sourceCommit does not match the release SHA")
    if proof.get("productSurface") != PRODUCTION_PRODUCT_SURFACE:
        fail("iOS production identity proof productSurface must be production")
    proof_conditions = require_production_compilation_conditions(
        proof, "swiftActiveCompilationConditions"
    )
    require_exact_bool(proof, "testingCompilationCondition", False)
    require_exact_bool(proof, "binaryTestSurfaceDetected", False)
    require_exact_bool(proof, "realDevice", True)
    require_exact_bool(proof, "secureEnclaveBacked", True)
    require_exact_bool(proof, "softwareFallbackUsed", False)
    require_exact_bool(proof, "privateKeyExported", False)
    for key in (
        "created",
        "persisted",
        "restoredAfterRelaunch",
        "signed",
        "verified",
        "handshakePersistenceVerified",
        "currentPathAuthorityVerified",
    ):
        require_exact_bool(proof, key, True)
    if proof.get("measurementSource") != "signed-production-app-runtime":
        fail(
            "iOS production identity proof measurementSource must be signed-production-app-runtime"
        )
    if proof.get("algorithm") != REQUIRED_IDENTITY_ALGORITHM:
        fail(f"iOS production identity proof algorithm must be {REQUIRED_IDENTITY_ALGORITHM}")
    if proof.get("protection") != REQUIRED_IDENTITY_PROTECTION:
        fail(
            "iOS production identity proof protection must be "
            f"{REQUIRED_IDENTITY_PROTECTION}"
        )
    require_session_ref(proof, "deviceRef")
    require_session_ref(proof, "evidenceSessionRef")

    if manifest is None:
        return
    manifest_repository = require_source_repository(manifest, "sourceRepository")
    manifest_commit = require_source_commit(manifest, "sourceCommit")
    manifest_conditions = require_production_compilation_conditions(
        manifest, "iosSwiftActiveCompilationConditions"
    )
    if manifest_repository != source_repository or manifest_commit != source_commit:
        fail("release manifest source provenance does not match production identity proof")
    if manifest_conditions != proof_conditions:
        fail("release manifest compilation conditions do not match production identity proof")
    if manifest.get("iosProductSurface") != PRODUCTION_PRODUCT_SURFACE:
        fail("release manifest iosProductSurface must be production")
    require_exact_bool(manifest, "iosTestingCompilationCondition", False)
    require_exact_bool(manifest, "iosBinaryTestSurfaceDetected", False)
    require_exact_bool(manifest, "iosProductionIdentityProof", True)
    require_exact_bool(manifest, "iosProductionIdentityLifecycleVerified", True)
    if manifest.get("iosProductionIdentityAlgorithm") != REQUIRED_IDENTITY_ALGORITHM:
        fail(
            "release manifest iosProductionIdentityAlgorithm must be "
            f"{REQUIRED_IDENTITY_ALGORITHM}"
        )
    if manifest.get("iosProductionIdentityProtection") != REQUIRED_IDENTITY_PROTECTION:
        fail(
            "release manifest iosProductionIdentityProtection must be "
            f"{REQUIRED_IDENTITY_PROTECTION}"
        )


def validate_common(payload: dict[str, Any], kind: str) -> None:
    if type(payload.get("schemaVersion")) is not int or payload.get("schemaVersion") != 1:
        fail("schemaVersion must be 1")
    if payload.get("transport") != kind:
        fail(f"transport must be {kind}")
    if payload.get("finalizationOrder") != FINALIZATION_ORDER:
        fail(f"finalizationOrder must be {FINALIZATION_ORDER}")
    require_exact_bool(payload, "realDevice", True)
    require_exact_bool(payload, "cleanupComplete", True)
    require_exact_bool(payload, "preCleanupCandidate", True)
    require_exact_bool(payload, "diagnosticOnly", False)
    require_exact_bool(payload, "acceptanceEligible", True)
    require_exact_bool(payload, "labRun", False)


def validate_p2p(payload: dict[str, Any], artifact_dir: Path) -> None:
    if payload.get("trustMode") not in {"user", "actual"}:
        fail("P2P trustMode must be user or actual; injected trust is diagnostic-only")
    if payload.get("keychainMode") != "system":
        fail("P2P keychainMode must be system; in-memory Keychain is diagnostic-only")
    require_exact_bool(payload, "injectedTrust", False)
    require_exact_bool(payload, "inMemoryKeychain", False)
    require_exact_bool(payload, "humanApproval", True)
    require_exact_bool(payload, "runtimeAutoApproval", False)
    require_exact_bool(payload, "iosToMacRemoteControl", True)
    require_exact_bool(payload, "macToIOSConnection", True)
    require_exact_bool(payload, "reverseCryptoHandshakeComplete", True)
    require_exact_bool(payload, "bidirectionalHandshake", True)
    if payload.get("macOnlineSource") != "packaged":
        fail("P2P macOnlineSource must be packaged; Debug product-identity signing is diagnostic-only")
    require_exact_bool(payload, "macOnlineSourceCurrent", True)
    if payload.get("macHostLaunchMode") != "packaged":
        fail("P2P macHostLaunchMode must be packaged; signed lab hosts are diagnostic-only")
    require_exact_bool(payload, "macHostDiagnosticOnly", False)
    require_exact_bool(payload, "identitySourceStaplerValid", True)
    require_exact_bool(payload, "identitySourceGatekeeperAccepted", True)
    if payload.get("approvalLifecycle") != [
        "Shown",
        "PanelPresented",
        "HumanApproved",
        "Approved",
        "Active",
    ]:
        fail("P2P approvalLifecycle must be strict human approval order")
    require_session_ref(payload, "approvalSessionRef")
    if payload.get("iosBuildConfiguration") != "Release":
        fail("P2P iosBuildConfiguration must be Release; Debug is lab diagnostic-only")
    require_exact_bool(payload, "iosReleaseConfiguration", True)
    require_exact_bool(payload, "iosSourceClean", True)
    require_session_ref(payload, "iosSourceRevisionRef")
    for key in (
        "iosProductBundle",
        "iosSignatureVerified",
        "iosProfileVerified",
        "iosTeamMatch",
        "iosCertificateMatch",
        "iosCertificateNotExpired",
        "iosProfileNotExpired",
        "iosProfileDeviceBound",
        "iosDistributionSigning",
        "iosExpectedEntitlementsMatch",
        "iosKeychainGroupsVerified",
        "iosNestedWidgetVerified",
        "iosProductProof",
    ):
        require_exact_bool(payload, key, True)
    require_exact_bool(payload, "iosGetTaskAllow", False)
    validate_p2p_approval_proof(payload, artifact_dir)
    validate_p2p_ios_product_proof(payload, artifact_dir)


def validate_p2p_approval_proof(payload: dict[str, Any], artifact_dir: Path) -> None:
    proof = load_json(artifact_dir / "p2p-approval-proof.json", "P2P approval proof")
    expected_lifecycle = ["Shown", "PanelPresented", "HumanApproved", "Approved", "Active"]
    if proof.get("schemaVersion") != 1:
        fail("P2P approval proof schemaVersion must be 1")
    if proof.get("lifecycle") != expected_lifecycle:
        fail("P2P approval proof lifecycle is not strict human approval order")
    require_exact_bool(proof, "humanApproval", True)
    require_exact_bool(proof, "runtimeAutoApproval", False)
    require_exact_bool(proof, "panelActionsVerified", True)
    proof_session_ref = require_session_ref(proof, "sessionRef")
    if proof_session_ref != payload.get("approvalSessionRef"):
        fail("P2P approval proof sessionRef does not match the manifest")
    if proof.get("humanApproval") is not payload.get("humanApproval"):
        fail("P2P humanApproval manifest field does not match measured approval proof")
    if proof.get("runtimeAutoApproval") is not payload.get("runtimeAutoApproval"):
        fail("P2P runtimeAutoApproval manifest field does not match measured approval proof")

    status = read_text_file(artifact_dir / "mac.status.log", "macOS P2P status log")
    event_pattern = re.compile(
        r"\bremoteControlNotice(?P<event>Shown|PanelPresented|HumanApproved|Approved|Active)\s+"
        r"session=(?P<session>[^\s]+)\s+transport=p2p\b(?P<tail>[^\n]*)"
    )
    events_by_session: dict[str, list[str]] = {}
    panel_contract: dict[str, bool] = {}
    active_sessions: set[str] = set()
    for match in event_pattern.finditer(status):
        event = match.group("event")
        session = match.group("session")
        tail = match.group("tail")
        if event == "PanelPresented":
            if re.search(r"\bphase=awaitingApproval\b", tail) is None:
                continue
            buttons_match = re.search(r"\bbuttons=([^\s]+)", tail)
            buttons = set(buttons_match.group(1).split(",")) if buttons_match else set()
            panel_contract[session] = {"approve", "reject"}.issubset(buttons)
        if event == "Active":
            active_sessions.add(session)
        events_by_session.setdefault(session, []).append(event)

    valid_sessions = [
        session
        for session, events in events_by_session.items()
        if events == expected_lifecycle and panel_contract.get(session) is True
    ]
    if len(valid_sessions) != 1:
        fail("P2P approval lifecycle is missing strict same-session HumanApproved evidence")
    raw_session = valid_sessions[0]
    if active_sessions != {raw_session}:
        fail("P2P approval lifecycle contains an unmatched active notice session")
    measured_session_ref = hashlib.sha256(raw_session.encode("utf-8")).hexdigest()[:24]
    if measured_session_ref != proof_session_ref:
        fail("P2P HumanApproved raw session does not match approval proof sessionRef")
    escaped_session = re.escape(raw_session)
    auto_patterns = (
        rf"\bremoteControlNoticeAutoApproved\s+session={escaped_session}\s+transport=p2p\b",
        rf"\bremoteControlNoticeApproved\s+session={escaped_session}\s+transport=p2p\b[^\n]*\bapprovalSource=(?:auto|runtime)\b",
        rf"(?m)^(?=[^\n]*\bsession={escaped_session}\b)(?=[^\n]*\b(?:runtimeAutoApproval|autoApprove)=true\b)[^\n]*$",
    )
    if any(re.search(pattern, status, re.IGNORECASE) for pattern in auto_patterns):
        fail("P2P approval lifecycle contains runtime auto-approval evidence")


def validate_p2p_ios_product_proof(payload: dict[str, Any], artifact_dir: Path) -> None:
    proof = load_json(artifact_dir / "ios-product-proof.json", "iOS P2P product proof")
    if proof.get("schemaVersion") != 1:
        fail("iOS P2P product proof schemaVersion must be 1")
    if proof.get("configuration") != "Release":
        fail("iOS P2P product proof configuration must be Release")
    proof_repository = require_source_repository(proof, "sourceRepository")
    proof_commit = require_source_commit(proof, "sourceCommit")
    if payload.get("sourceRepository") != proof_repository:
        fail("P2P manifest sourceRepository does not match measured iOS product proof")
    if payload.get("sourceCommit") != proof_commit:
        fail("P2P manifest sourceCommit does not match measured iOS product proof")
    if proof.get("productSurface") != PRODUCTION_PRODUCT_SURFACE:
        fail("iOS P2P product proof productSurface must be production")
    if payload.get("iosProductSurface") != proof.get("productSurface"):
        fail("P2P manifest iosProductSurface does not match measured iOS product proof")
    proof_conditions = require_production_compilation_conditions(
        proof, "swiftActiveCompilationConditions"
    )
    manifest_conditions = require_production_compilation_conditions(
        payload, "iosSwiftActiveCompilationConditions"
    )
    if proof_conditions != manifest_conditions:
        fail("P2P manifest compilation conditions do not match measured iOS product proof")
    require_exact_bool(proof, "testingCompilationCondition", False)
    require_exact_bool(proof, "binaryTestSurfaceDetected", False)
    require_exact_bool(proof, "productionProduct", True)
    if payload.get("iosTestingCompilationCondition") is not proof.get(
        "testingCompilationCondition"
    ):
        fail("P2P manifest testing-condition state does not match measured iOS product proof")
    if payload.get("iosBinaryTestSurfaceDetected") is not proof.get(
        "binaryTestSurfaceDetected"
    ):
        fail("P2P manifest binary test-surface state does not match measured iOS product proof")
    if payload.get("iosProductionProduct") is not proof.get("productionProduct"):
        fail("P2P manifest production-product state does not match measured iOS product proof")
    field_pairs = {
        "iosReleaseConfiguration": "releaseConfiguration",
        "iosSourceClean": "sourceClean",
        "iosProductBundle": "productBundle",
        "iosSignatureVerified": "signatureVerified",
        "iosProfileVerified": "profileVerified",
        "iosTeamMatch": "teamMatch",
        "iosCertificateMatch": "certificateMatch",
        "iosCertificateNotExpired": "certificateNotExpired",
        "iosProfileNotExpired": "profileNotExpired",
        "iosProfileDeviceBound": "profileDeviceBound",
        "iosDistributionSigning": "distributionSigning",
        "iosExpectedEntitlementsMatch": "expectedEntitlementsMatch",
        "iosKeychainGroupsVerified": "keychainGroupsVerified",
        "iosNestedWidgetVerified": "nestedWidgetVerified",
    }
    for manifest_key, proof_key in field_pairs.items():
        if proof.get(proof_key) is not True:
            fail(f"iOS P2P product proof requires {proof_key}=true")
        if payload.get(manifest_key) is not proof.get(proof_key):
            fail(f"P2P manifest {manifest_key} does not match measured iOS product proof")
    if proof.get("getTaskAllow") is not False:
        fail("iOS P2P product proof requires getTaskAllow=false")
    if payload.get("iosGetTaskAllow") is not proof.get("getTaskAllow"):
        fail("P2P manifest iosGetTaskAllow does not match measured iOS product proof")
    source_revision_ref = require_session_ref(proof, "sourceRevisionRef")
    expected_source_revision_ref = hashlib.sha256(proof_commit.encode("ascii")).hexdigest()[:24]
    if source_revision_ref != expected_source_revision_ref:
        fail("iOS P2P product proof sourceRevisionRef is not derived from sourceCommit")
    if source_revision_ref != payload.get("iosSourceRevisionRef"):
        fail("P2P iOS source revision proof does not match the manifest")


def read_text_file(path: Path, label: str) -> str:
    try:
        return read_regular_file(path, label, maximum_bytes=MAX_STATUS_LOG_BYTES).decode("utf-8", errors="strict")
    except (OSError, UnicodeError) as exc:
        fail(f"unable to read {label}: {exc}")


def validate_p2p_logs(artifact_dir: Path) -> None:
    mac_status = read_text_file(
        artifact_dir / "mac.status.log", "macOS P2P status log"
    )
    if re.search(r"\bfailed\s+stage=", mac_status):
        fail("macOS P2P status contains a failed stage")
    if re.search(
        r"\bidentity\s+legacyResidueInspectionComplete=1\s+conflicts=(?:0|1)\s+reason=none\b",
        mac_status,
    ) is None:
        fail("macOS P2P status is missing a complete legacy-residue inspection")
    if re.search(r"(?:\bsuccess\b.*\bsuite=X-Wing\b.*\bhandshakeOnly=1\b|\bmac remote established\b.*\bsuite=X-Wing\b)", mac_status) is None:
        fail("macOS P2P status does not prove the iOS-to-Mac X-Wing handshake")
    if re.search(r"\bsmoke-final\b.*\bresult=success\b.*\bvalidated=1\b", mac_status) is None:
        fail("macOS P2P status is missing the validated final success marker")

    ios_status_paths = sorted(artifact_dir.glob("ios-p2p-remote-*.status.log"))
    if len(ios_status_paths) != 1:
        fail("P2P artifact must contain exactly one real-device iOS status log")
    ios_status = read_text_file(ios_status_paths[0], "iOS P2P status log")
    if re.search(r"\bfailed\s+stage=", ios_status):
        fail("iOS P2P status contains a failed stage")
    if re.search(r"\bsuccess\b.*\bsuite=X-Wing\b.*\bhandshakeOnly=1\b.*\bremoteDesktop=1\b", ios_status) is None:
        fail("iOS P2P status does not prove the iOS-to-Mac X-Wing remote-control session")
    if re.search(r"\bremote-desktop-pass\b", ios_status) is None:
        fail("iOS P2P status is missing the real remote-desktop pass window")
    if re.search(r"\bsmoke-final\b.*\bresult=success\b.*\bvalidated=1\b", ios_status) is None:
        fail("iOS P2P status is missing the validated final success marker")

    reverse_status = read_text_file(
        artifact_dir / "mac-online-ipad.status.log",
        "Mac-to-iOS P2P status log",
    )
    if re.search(r"\bfailed\s+stage=mac-online-ipad\b", reverse_status):
        fail("Mac-to-iOS P2P status contains a failed mac-online-ipad stage")
    required_reverse_patterns = {
        "real Connect button click": r"\bmac-online-connect\b.*\baction=button\b.*\bclickSource=accessibility\b.*\btargetRowBound=1\b",
        "connection start": r"\bmac-online-connect-start\b.*\btargetFamily=ipad\b.*\bevidenceSource=external-ax\b",
        "app-authored connection success": r"\bmac-online-connect-app\b.*\baction=button\b.*\bresult=success\b.*\bsource=OnlineDeviceCard\b",
        "connected device row": r"\bmac-online-device-ui\b.*\btargetFamily=ipad\b.*\bstatus=connected\b",
        "product Wi-Fi/AWDL P2P path": r"\bp2p-connection-ready-path\b.*\bpathStatus=satisfied\b.*\brouteClass=(?:wifi|awdl)\b.*\battached=0\b.*\blinkLocal=0\b",
        "final reverse result": r"\bmac-online-connect-result\b.*\baction=button\b.*\bresult=success\b.*\bstatus=connected\b",
        "macOS authenticated X-Wing remote-control handshake": r"\bmac remote established\b.*\bsuite=X-Wing\b",
    }
    missing = [
        label
        for label, pattern in required_reverse_patterns.items()
        if re.search(pattern, reverse_status) is None
    ]
    if missing:
        fail(f"Mac-to-iOS P2P status is missing: {','.join(missing)}")
    if re.search(r"\bp2p-inbound handshake-established\b.*\bsuite=X-Wing\b", ios_status) is None:
        fail("iOS P2P status does not prove the reverse inbound X-Wing handshake")
    if re.search(r"\blan-remote handshake-established\b.*\bsuite=X-Wing\b", ios_status) is None:
        fail("iOS P2P status does not prove the reverse remote-control X-Wing handshake")


def validate_webrtc(payload: dict[str, Any], artifact_dir: Path) -> None:
    if payload.get("keychainMode") != "system":
        fail("WebRTC keychainMode must be system; in-memory identity is diagnostic-only")
    if payload.get("macKeychainMode") != "system" or payload.get("iosKeychainMode") != "system":
        fail("both WebRTC peers must prove system-Keychain identity")
    if payload.get("approvalSurface") != "shared-product-panel":
        fail("WebRTC approvalSurface must be the shared product panel")
    require_exact_bool(payload, "macProductPath", True)
    require_exact_bool(payload, "iosProductPath", True)
    require_exact_bool(payload, "humanApproval", True)
    require_exact_bool(payload, "runtimeAutoApproval", False)
    require_exact_bool(payload, "macSystemKeychainProof", True)
    require_exact_bool(payload, "macAuthBindingVerified", True)
    require_exact_bool(payload, "iosSystemKeychainProof", True)
    if payload.get("iosBuildConfiguration") != "Release":
        fail("WebRTC iosBuildConfiguration must be Release; Debug is lab diagnostic-only")
    if payload.get("iosSourceDirtyState") != "clean":
        fail("WebRTC iosSourceDirtyState must be clean")
    ios_source_repository = require_source_repository(payload, "sourceRepository")
    ios_source_commit = payload.get("iosSourceCommit")
    if not isinstance(ios_source_commit, str) or re.fullmatch(r"[0-9a-f]{40}", ios_source_commit) is None:
        fail("WebRTC iosSourceCommit must be a full lowercase Git revision")
    if payload.get("sourceCommit") != ios_source_commit:
        fail("WebRTC sourceCommit must match iosSourceCommit")
    if payload.get("iosProductSurface") != PRODUCTION_PRODUCT_SURFACE:
        fail("WebRTC iosProductSurface must be production")
    require_production_compilation_conditions(
        payload, "iosSwiftActiveCompilationConditions"
    )
    require_exact_bool(payload, "iosTestingCompilationCondition", False)
    require_exact_bool(payload, "iosBinaryTestSurfaceDetected", False)
    require_exact_bool(payload, "iosProductionProduct", True)
    for key in (
        "iosReleaseProvenanceVerified",
        "iosGetTaskAllowDisabled",
        "iosProfileNotExpired",
        "iosProfileDeviceBound",
        "iosProfileTeamMatchesSignature",
        "iosSigningCertificateTrusted",
        "iosSigningCertificateInProfile",
        "iosSigningCertificateNotExpired",
        "iosDistributionSigningVerified",
        "iosKeychainGroupsMatchProfile",
        "iosExpectedEntitlementsMatch",
        "iosNestedWidgetVerified",
    ):
        require_exact_bool(payload, key, True)
    require_exact_bool(payload, "forceRelayIce", True)
    require_exact_bool(payload, "requireAudio", True)
    require_exact_bool(payload, "relayPreflight", True)
    require_exact_bool(payload, "relayCandidateObserved", True)
    require_exact_bool(payload, "syntheticScreen", False)
    require_exact_bool(payload, "syntheticAudio", False)
    require_exact_bool(payload, "macHandshakeComplete", True)
    require_exact_bool(payload, "iosHandshakeComplete", True)
    require_exact_bool(payload, "macPQCRekeyComplete", True)
    require_exact_bool(payload, "iosPQCRekeyComplete", True)
    require_exact_bool(payload, "mutualHandshake", True)
    session_ref = require_session_ref(payload, "sessionRef")
    relay_session_ref = require_session_ref(payload, "relayCandidateSessionRef")
    if relay_session_ref != session_ref:
        fail("relayCandidateSessionRef does not match sessionRef")
    soak_seconds = require_non_bool_int(payload, "soakSeconds")
    if soak_seconds < MIN_WEBRTC_SOAK_SECONDS:
        fail(f"WebRTC soakSeconds must be at least {MIN_WEBRTC_SOAK_SECONDS}")
    observed_gate_window_ms = require_non_bool_int(payload, "observedGateWindowMillis")
    media_evidence_window_ms = require_non_bool_int(payload, "mediaEvidenceWindowMillis")
    required_window_ms = soak_seconds * 1_000
    if observed_gate_window_ms < required_window_ms:
        fail("observedGateWindowMillis is shorter than the required soak window")
    if media_evidence_window_ms < required_window_ms:
        fail("mediaEvidenceWindowMillis is shorter than the required soak window")

    report = load_json(artifact_dir / "webrtc_media_doctor.json", "WebRTC media doctor report")
    if report.get("faultStage") not in {None, ""}:
        fail(f"WebRTC media doctor reported faultStage={report.get('faultStage')}")
    if report.get("sessionRef") != session_ref:
        fail("WebRTC media doctor sessionRef does not match the release session")
    if report.get("gateSessionBound") is not True:
        fail("WebRTC media doctor is not bound to the release session")
    if report.get("observedGateWindowMillis") != observed_gate_window_ms:
        fail("WebRTC media doctor observed gate window does not match the manifest")
    if report.get("mediaEvidenceWindowMillis") != media_evidence_window_ms:
        fail("WebRTC media doctor media evidence window does not match the manifest")
    checks = report.get("checks")
    if not isinstance(checks, list):
        fail("WebRTC media doctor report is missing checks")
    by_name: dict[str, dict[str, Any]] = {}
    for check in checks:
        if not isinstance(check, dict) or not isinstance(check.get("name"), str):
            fail("WebRTC media doctor report contains a malformed check")
        name = check["name"]
        if name in by_name:
            fail(f"WebRTC media doctor report contains duplicate check: {name}")
        by_name[name] = check
    missing = sorted(REQUIRED_WEBRTC_CHECKS.difference(by_name))
    if missing:
        fail(f"WebRTC media doctor report is missing checks: {','.join(missing)}")
    failed = sorted(name for name in REQUIRED_WEBRTC_CHECKS if by_name[name].get("ok") is not True)
    if failed:
        fail(f"WebRTC media doctor report contains failed checks: {','.join(failed)}")
    blocking = sorted(
        name
        for name, check in by_name.items()
        if check.get("ok") is not True
        or str(check.get("severity", "")).lower() != "info"
    )
    if blocking:
        fail(f"WebRTC media doctor report contains blocking checks: {','.join(blocking)}")

    mac_status = read_text_file(
        artifact_dir / "mac.status.log", "macOS WebRTC status log"
    )
    if re.search(r"\bfailed\s+stage=", mac_status):
        fail("macOS WebRTC status contains a failed stage")
    relay_config = re.compile(
        r"\bwebrtc-config\b.*\brelayOnly=true\b.*\bturn=true\b.*\bturnUrls=[1-9][0-9]*\b"
    )
    if relay_config.search(mac_status) is None:
        fail("macOS WebRTC status does not prove relay-only ICE with usable TURN credentials")
    mac_success = re.search(r"\bsuccess\s+session=[^\s]+.*\bsuite=X-Wing\b.*\bstream=true\b", mac_status)
    if mac_success is None:
        fail("macOS WebRTC status does not prove an X-Wing streaming handshake")
    session_match = re.search(r"\bsuccess\s+session=([^\s]+).*\bsuite=X-Wing\b.*\bstream=true\b", mac_status)
    if session_match is None:
        fail("macOS WebRTC status is missing the successful raw session binding")
    raw_session = re.escape(session_match.group(1))
    required_product_patterns = {
        "macOS system-Keychain product session": r"\bkeychain-proof\s+platform=mac\s+mode=system\s+auth=existing-product-session\s+identity=system\s+authBinding=verified\s+productBundle=true\b",
        "presented product approval panel": rf"\bremoteControlNoticePanelPresented\s+session={raw_session}\s+transport=webrtc\s+phase=awaitingApproval\b.*\bbuttons=[^\n]*approve\b",
        "human panel approval": rf"\bremoteControlNoticeHumanApproved\s+session={raw_session}\s+transport=webrtc\b",
        "approved notice": rf"\bremoteControlNoticeApproved\s+session={raw_session}\s+transport=webrtc\b",
        "active notice": rf"\bremoteControlNoticeActive\s+session={raw_session}\s+transport=webrtc\b",
    }
    missing_product_evidence = [
        label for label, pattern in required_product_patterns.items()
        if re.search(pattern, mac_status) is None
    ]
    if missing_product_evidence:
        fail(f"macOS WebRTC product evidence is missing: {','.join(missing_product_evidence)}")
    if re.search(r"\brekey\s+session=[^\s]+\s+complete\s+suite=X-Wing\b", mac_status) is None:
        fail("macOS WebRTC status does not prove X-Wing rekey completion")
    if re.search(rf"\brelease-session-binding\s+role=mac\s+sessionRef={session_ref}\s+handshake=1\s+rekey=1\b", mac_status) is None:
        fail("macOS WebRTC status is not bound to the release session reference")
    preflight = read_text_file(
        artifact_dir / "media-relay-preflight.log", "media relay UDP preflight log"
    )
    if "udp_bind_probe=ok" not in preflight or "udp_bind_probe=failed" in preflight:
        fail("media relay UDP preflight log does not contain an unambiguous successful probe")
    ios_status = sorted(artifact_dir.glob("ios-real-webrtc-*.status.log"))
    if len(ios_status) != 1:
        fail("WebRTC artifact must contain exactly one real-device iOS status log")
    ios_status_text = read_text_file(ios_status[0], "iOS WebRTC status log")
    if re.search(r"\bfailed\s+stage=", ios_status_text):
        fail("iOS WebRTC status contains a failed stage")
    ios_handshake = re.search(r"\bhandshake\s+session=[^\s]+\s+suite=(?:X25519(?:-Ed25519)?|X-Wing)\b", ios_status_text)
    if ios_handshake is None:
        fail("iOS WebRTC status does not prove the matching bootstrap handshake")
    if re.search(r"\brekey\s+session=[^\s]+\s+complete\s+suite=X-Wing\b", ios_status_text) is None:
        fail("iOS WebRTC status does not prove X-Wing rekey completion")
    if re.search(r"\bkeychain-proof\s+platform=ios\s+mode=system\s+auth=existing-product-session\s+productBundle=true\b", ios_status_text) is None:
        fail("iOS WebRTC status does not prove an existing system-Keychain product session")
    if re.search(rf"\brelease-session-binding\s+role=ios\s+sessionRef={session_ref}\s+handshake=1\s+rekey=1\b", ios_status_text) is None:
        fail("iOS WebRTC status is not bound to the release session reference")
    trace_logs = sorted(artifact_dir.glob("ios-real-webrtc-*.status.log.trace.log"))
    if len(trace_logs) != 1:
        fail("WebRTC artifact must contain exactly one real-device iOS trace log")
    trace_text = read_text_file(trace_logs[0], "iOS WebRTC trace log")
    if re.search(r"\bfailed\s+stage=", trace_text):
        fail("iOS WebRTC trace contains a failed stage")
    if re.search(rf"\brelease-session-binding\s+role=relay-candidate\s+sessionRef={session_ref}\s+candidate=relay\b", trace_text) is None:
        fail("relay candidate evidence is not bound to the release session reference")
    media_logs = sorted(artifact_dir.glob("*.webrtc-media.jsonl"))
    if len(media_logs) != 1:
        fail("WebRTC artifact must contain exactly one real-device media diagnostics log")
    media_content = read_regular_file(
        media_logs[0], "WebRTC media diagnostics", maximum_bytes=MAX_MEDIA_LOG_BYTES
    ).decode("utf-8", errors="strict")
    session_timestamps: list[float] = []
    for line_number, line in enumerate(media_content.splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            fail(f"WebRTC media diagnostics line {line_number} is invalid JSON: {exc}")
        if not isinstance(row, dict):
            fail(f"WebRTC media diagnostics line {line_number} is not an object")
        if row.get("release_session_ref") != session_ref:
            continue
        timestamp = row.get("timestamp")
        if not isinstance(timestamp, str):
            fail(f"WebRTC media diagnostics line {line_number} has no timestamp")
        try:
            session_timestamps.append(
                datetime.fromisoformat(timestamp.replace("Z", "+00:00")).timestamp()
            )
        except ValueError as exc:
            fail(f"WebRTC media diagnostics line {line_number} has invalid timestamp: {exc}")
    if len(session_timestamps) < 2:
        fail("WebRTC media diagnostics contain fewer than two release-session samples")
    measured_media_window_ms = int(round((max(session_timestamps) - min(session_timestamps)) * 1_000))
    if measured_media_window_ms < required_window_ms:
        fail("WebRTC media diagnostics do not span the required soak window")
    if abs(measured_media_window_ms - media_evidence_window_ms) > 1_000:
        fail("WebRTC media diagnostics window does not match the release manifest")

    product_path = load_json(
        artifact_dir / "product-path-proof.json", "WebRTC product path proof"
    )
    if product_path.get("schemaVersion") != 1 or product_path.get("keychainMode") != "system":
        fail("WebRTC product path proof has an invalid schema or Keychain mode")
    for key in (
        "macProductBundle",
        "macProductSignatureVerified",
        "macProductProfileVerified",
        "iosProductBundle",
        "iosProductSignatureVerified",
        "iosProductProfileVerified",
        "iosProfileNotExpired",
        "iosProfileDeviceBound",
        "iosProfileTeamMatchesSignature",
        "iosSigningCertificateTrusted",
        "iosSigningCertificateInProfile",
        "iosSigningCertificateNotExpired",
        "iosDistributionSigningVerified",
        "iosKeychainGroupsMatchProfile",
        "iosExpectedEntitlementsMatch",
        "iosNestedWidgetVerified",
        "iosGetTaskAllowDisabled",
        "iosReleaseProvenanceVerified",
    ):
        if product_path.get(key) is not True:
            fail(f"WebRTC product path proof requires {key}=true")
    if product_path.get("iosBuildConfiguration") != "Release":
        fail("WebRTC product path proof requires an iOS Release build")
    if product_path.get("iosSourceDirtyState") != "clean":
        fail("WebRTC product path proof requires clean iOS source provenance")
    if product_path.get("iosSourceCommit") != ios_source_commit:
        fail("WebRTC product path proof source commit does not match the manifest")
    if product_path.get("sourceRepository") != ios_source_repository:
        fail("WebRTC product path proof source repository does not match the manifest")
    if product_path.get("sourceCommit") != ios_source_commit:
        fail("WebRTC product path proof sourceCommit does not match the manifest")
    if product_path.get("iosProductSurface") != PRODUCTION_PRODUCT_SURFACE:
        fail("WebRTC product path proof iosProductSurface must be production")
    product_conditions = require_production_compilation_conditions(
        product_path, "iosSwiftActiveCompilationConditions"
    )
    manifest_conditions = require_production_compilation_conditions(
        payload, "iosSwiftActiveCompilationConditions"
    )
    if product_conditions != manifest_conditions:
        fail("WebRTC product path proof compilation conditions do not match the manifest")
    require_exact_bool(product_path, "iosTestingCompilationCondition", False)
    require_exact_bool(product_path, "iosBinaryTestSurfaceDetected", False)
    require_exact_bool(product_path, "iosProductionProduct", True)
    proof_manifest_pairs = (
        ("iosReleaseProvenanceVerified", "iosReleaseProvenanceVerified"),
        ("iosGetTaskAllowDisabled", "iosGetTaskAllowDisabled"),
        ("iosProfileNotExpired", "iosProfileNotExpired"),
        ("iosProfileDeviceBound", "iosProfileDeviceBound"),
        ("iosProfileTeamMatchesSignature", "iosProfileTeamMatchesSignature"),
        ("iosSigningCertificateTrusted", "iosSigningCertificateTrusted"),
        ("iosSigningCertificateInProfile", "iosSigningCertificateInProfile"),
        ("iosSigningCertificateNotExpired", "iosSigningCertificateNotExpired"),
        ("iosDistributionSigningVerified", "iosDistributionSigningVerified"),
        ("iosKeychainGroupsMatchProfile", "iosKeychainGroupsMatchProfile"),
        ("iosExpectedEntitlementsMatch", "iosExpectedEntitlementsMatch"),
        ("iosNestedWidgetVerified", "iosNestedWidgetVerified"),
        ("iosTestingCompilationCondition", "iosTestingCompilationCondition"),
        ("iosBinaryTestSurfaceDetected", "iosBinaryTestSurfaceDetected"),
        ("iosProductionProduct", "iosProductionProduct"),
    )
    for proof_key, manifest_key in proof_manifest_pairs:
        if product_path.get(proof_key) is not payload.get(manifest_key):
            fail(f"WebRTC product path proof {proof_key} does not match the manifest")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--kind",
        choices=("p2p", "webrtc", "production-identity"),
        required=True,
    )
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument(
        "--expected-source-repository",
        default=os.environ.get("SKYBRIDGE_RELEASE_EVIDENCE_EXPECTED_REPOSITORY", ""),
    )
    parser.add_argument(
        "--expected-source-sha",
        default=os.environ.get("SKYBRIDGE_RELEASE_EVIDENCE_EXPECTED_SHA", ""),
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    artifact_dir: Path = args.artifact_dir
    try:
        directory_metadata = artifact_dir.lstat()
    except FileNotFoundError:
        fail(f"artifact directory does not exist: {artifact_dir}")
    if not stat.S_ISDIR(directory_metadata.st_mode):
        fail(f"artifact directory must be a real directory: {artifact_dir}")

    if not is_source_repository(args.expected_source_repository):
        fail("--expected-source-repository must be an owner/repository identifier")
    if SOURCE_COMMIT_PATTERN.fullmatch(args.expected_source_sha) is None:
        fail("--expected-source-sha must be a full lowercase 40-character Git revision")

    if args.kind == "production-identity":
        validate_production_identity_proof(
            artifact_dir,
            expected_repository=args.expected_source_repository,
            expected_source_sha=args.expected_source_sha,
        )
        print("release production identity artifact valid")
        return

    manifest = load_json(
        artifact_dir / "release-acceptance.json",
        "release acceptance manifest",
        require_release_manifest_metadata=True,
    )
    validate_common(manifest, args.kind)
    if args.kind == "p2p":
        validate_p2p(manifest, artifact_dir)
        validate_p2p_logs(artifact_dir)
    else:
        validate_webrtc(manifest, artifact_dir)
    validate_production_identity_proof(
        artifact_dir,
        expected_repository=args.expected_source_repository,
        expected_source_sha=args.expected_source_sha,
        manifest=manifest,
    )
    print(f"release acceptance artifact valid: kind={args.kind}")


if __name__ == "__main__":
    main()
