#!/usr/bin/env python3
"""Cross-platform interop/trust consistency checker for TDSC artifacts.

This checker is intentionally static (source-based) so it can run in CI
without bootstrapping all external toolchains.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
from pathlib import Path
from typing import Any, Dict, List, Tuple


def norm_hex(value: str) -> str:
    return f"0x{int(value, 16):04x}"


def first_existing(*candidates: Path) -> Path:
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


def read_text(path: Path) -> str:
    if not path.exists():
        raise FileNotFoundError(str(path))
    return path.read_text(encoding="utf-8", errors="ignore")


def parse_swift_suites(text: str) -> Dict[str, str]:
    pattern = re.compile(
        r"public\s+static\s+let\s+([A-Za-z0-9_]+)\s*=\s*CryptoSuite\(\s*rawValue:\s*\"([^\"]+)\"\s*,\s*wireId:\s*(0x[0-9A-Fa-f]+)\s*\)"
    )
    out: Dict[str, str] = {}
    for var_name, raw_name, wire_hex in pattern.findall(text):
        out[norm_hex(wire_hex)] = f"{var_name}:{raw_name}"
    return dict(sorted(out.items()))


def parse_android_suites(text: str) -> Dict[str, str]:
    pattern = re.compile(
        r"^\s*([A-Z0-9_]+)\((0x[0-9A-Fa-f]+)u,\s*(?:true|false)\)",
        flags=re.MULTILINE,
    )
    out: Dict[str, str] = {}
    for enum_name, wire_hex in pattern.findall(text):
        out[norm_hex(wire_hex)] = enum_name
    return dict(sorted(out.items()))


def parse_ubuntu_suites(text: str) -> Dict[str, str]:
    pattern = re.compile(r"^\s*([A-Za-z0-9_]+)\s*=\s*(0x[0-9A-Fa-f]+),", re.MULTILINE)
    out: Dict[str, str] = {}
    for enum_name, wire_hex in pattern.findall(text):
        out[norm_hex(wire_hex)] = enum_name
    return dict(sorted(out.items()))


def set_diff(reference: Dict[str, str], target: Dict[str, str]) -> Tuple[List[str], List[str]]:
    ref_ids = set(reference)
    target_ids = set(target)
    missing = sorted(ref_ids - target_ids)
    extra = sorted(target_ids - ref_ids)
    return missing, extra


def build_markdown(report: dict) -> str:
    lines: List[str] = []
    lines.append("# Cross-Platform Interop Consistency Report")
    lines.append("")
    lines.append(f"- Generated at: {report['generated_at_utc']}")
    lines.append(f"- Artifact date: {report['artifact_date']}")
    lines.append("")
    lines.append("## Suite Coverage")
    lines.append("")
    lines.append("| Platform | Suite IDs |")
    lines.append("|---|---|")
    lines.append(
        f"| iOS/mac | {', '.join(sorted(report['suite_ids']['ios_mac'].keys())) or '(none)'} |"
    )
    lines.append(
        f"| Android | {', '.join(sorted(report['suite_ids']['android'].keys())) or '(none)'} |"
    )
    lines.append(
        f"| Ubuntu | {', '.join(sorted(report['suite_ids']['ubuntu'].keys())) or '(none)'} |"
    )
    lines.append("")
    lines.append("## Checks")
    lines.append("")
    for check_name, check_value in report["checks"].items():
        status = "PASS" if check_value.get("ok") else "FAIL"
        lines.append(f"- `{check_name}`: {status} - {check_value.get('detail', '')}")
    lines.append("")
    if report["blockers"]:
        lines.append("## Blockers")
        lines.append("")
        for blocker in report["blockers"]:
            lines.append(f"- {blocker}")
        lines.append("")
    if report["warnings"]:
        lines.append("## Warnings")
        lines.append("")
        for warning in report["warnings"]:
            lines.append(f"- {warning}")
        lines.append("")
    lines.append(f"Overall status: **{report['status'].upper()}**")
    return "\n".join(lines) + "\n"


def write_report(report: dict, out_json: Path, out_md: Path) -> None:
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    out_md.write_text(build_markdown(report), encoding="utf-8")


def build_bonjour_markdown(report: dict) -> str:
    lines: List[str] = []
    lines.append("# Bonjour Interop Contract Report")
    lines.append("")
    lines.append(f"- Generated at: {report['generated_at_utc']}")
    lines.append(f"- Artifact date: {report['artifact_date']}")
    lines.append("")
    lines.append("## Checks")
    lines.append("")
    for check_name, check_value in report["checks"].items():
        status = "PASS" if check_value.get("ok") else "FAIL"
        lines.append(f"- `{check_name}`: {status} - {check_value.get('detail', '')}")
    lines.append("")
    if report["blockers"]:
        lines.append("## Blockers")
        lines.append("")
        for blocker in report["blockers"]:
            lines.append(f"- {blocker}")
        lines.append("")
    lines.append(f"Overall status: **{report['status'].upper()}**")
    return "\n".join(lines) + "\n"


def write_bonjour_report(report: dict, out_json: Path, out_md: Path) -> None:
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    out_md.write_text(build_bonjour_markdown(report), encoding="utf-8")


def require_dict(value: Any, name: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be a JSON object")
    return value


def require_string_list(value: Any, name: str) -> List[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"{name} must be a JSON string array")
    return value


def add_check(checks: Dict[str, dict], name: str, ok: bool, detail: str) -> None:
    checks[name] = {"ok": ok, "detail": detail}


def parse_csharp_string_array(text: str, field_name: str) -> List[str]:
    pattern = re.compile(
        rf"{re.escape(field_name)}\s*=\s*\{{(?P<body>.*?)\}}",
        flags=re.S,
    )
    match = pattern.search(text)
    if not match:
        return []
    return re.findall(r'"([^"]+)"', match.group("body"))


def run_bonjour_contract_check(
    args: argparse.Namespace,
    repo_root: Path,
    artifact_date: str,
) -> int:
    ios_root = Path(args.ios_root)
    android_root = Path(args.android_root)
    windows_root = Path(args.windows_root)
    contract_path = Path(args.contract_json or ios_root / "Docs/bonjour_interop_contract.json")
    out_json = Path(args.out_json or f"Artifacts/bonjour_interop_contract_{artifact_date}.json")
    out_md = Path(args.out_md or f"Artifacts/bonjour_interop_contract_{artifact_date}.md")

    required_inputs = {
        "contract_json": contract_path,
        "apple_protocol_contract": ios_root
        / "Sources/SkyBridgeProtocolCore/Discovery/BonjourInteropProtocolContract.swift",
        "android_bonjour_interop": android_root
        / "device-discovery/src/main/kotlin/com/skybridge/compass/discovery/data/interop/AppleBonjourInterop.kt",
        "android_bonjour_routes": android_root
        / "device-discovery/src/main/kotlin/com/skybridge/compass/discovery/data/interop/AppleBonjourPeerRoutes.kt",
        "android_action_projection": android_root
        / "app/src/main/kotlin/com/skybridge/compass/android/discovery/DiscoveryPeerActionProjection.kt",
        "windows_discovery_browser": windows_root
        / "windows/Skybridge.WinClient/Services/DiscoveryBrowserClient.cs",
        "windows_product_action_targets": windows_root
        / "windows/Skybridge.WinClient/Services/ProductSessionActionTargetProjection.cs",
        "windows_product_action_gate": windows_root
        / "windows/Skybridge.WinClient/Services/ProductSessionActionGateClient.cs",
        "windows_command_gate": windows_root
        / "windows/Skybridge.WinClient/ViewModels/WorkspaceCommandGateCoordinator.cs",
        "windows_remote_desktop_actions": windows_root
        / "windows/Skybridge.WinClient/ViewModels/RemoteDesktopWorkspaceActions.cs",
        "windows_file_transfer_runtime_proof": windows_root
        / "windows/Skybridge.WinClient/Services/WebRtcFileTransferRuntimeProof.cs",
        "windows_rust_discovery": windows_root / "core/skybridge-core/src/discovery.rs",
        "windows_core_bridge": windows_root
        / "windows/Skybridge.WinClient/Services/CoreBridge.cs",
    }
    missing_inputs = [f"{name}: {path}" for name, path in required_inputs.items() if not path.exists()]
    checks: Dict[str, dict] = {}
    blockers: List[str] = []
    if missing_inputs:
        blockers.extend(["Missing required Bonjour interop source inputs.", *missing_inputs])
        report = {
            "status": "fail",
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "artifact_date": artifact_date,
            "paths": {
                "ios_root": str(ios_root),
                "android_root": str(android_root),
                "windows_root": str(windows_root),
                "contract_json": str(contract_path),
            },
            "checks": checks,
            "blockers": blockers,
        }
        write_bonjour_report(report, out_json, out_md)
        print("[interop] bonjour-status=fail")
        print(f"[interop] wrote {out_json}")
        print(f"[interop] wrote {out_md}")
        return 1

    try:
        contract = require_dict(json.loads(read_text(contract_path)), "contract")
        service_types = require_dict(contract.get("serviceTypes"), "serviceTypes")
        discovery = require_dict(contract.get("discovery"), "discovery")
        capabilities = require_dict(contract.get("capabilities"), "capabilities")
        txt = require_dict(contract.get("txt"), "txt")
        remote_video = require_dict(contract.get("remoteVideoFormats"), "remoteVideoFormats")
        route_provenance = require_dict(contract.get("routeProvenance"), "routeProvenance")
    except (json.JSONDecodeError, OSError, ValueError) as exc:
        blockers.append(f"Invalid Bonjour contract JSON: {exc}")
        service_types = {}
        discovery = {}
        capabilities = {}
        txt = {}
        remote_video = {}
        route_provenance = {}

    expected_apple_services = require_string_list(
        discovery.get("appleDefaultServiceTypes", []),
        "discovery.appleDefaultServiceTypes",
    )
    expected_windows_services = require_string_list(
        discovery.get("windowsCompatibilityQueryOrder", []),
        "discovery.windowsCompatibilityQueryOrder",
    )
    expected_capability_tokens = (
        require_string_list(capabilities.get("base", []), "capabilities.base")
        + require_string_list(capabilities.get("fileTransfer", []), "capabilities.fileTransfer")
        + require_string_list(capabilities.get("remoteControl", []), "capabilities.remoteControl")
    )
    expected_txt_tokens = (
        require_string_list(txt.get("deviceIdentityKeys", []), "txt.deviceIdentityKeys")
        + require_string_list(txt.get("pubKeyFingerprintKeys", []), "txt.pubKeyFingerprintKeys")
        + require_string_list(txt.get("fileTransferPortKeys", []), "txt.fileTransferPortKeys")
        + require_string_list(txt.get("remoteControlPortKeys", []), "txt.remoteControlPortKeys")
        + require_string_list(txt.get("remoteVideoFormatKeys", []), "txt.remoteVideoFormatKeys")
        + require_string_list(remote_video.get("allowedTokens", []), "remoteVideoFormats.allowedTokens")
    )

    apple_text = read_text(required_inputs["apple_protocol_contract"])
    android_interop_text = read_text(required_inputs["android_bonjour_interop"])
    android_routes_text = read_text(required_inputs["android_bonjour_routes"])
    android_action_projection_text = read_text(required_inputs["android_action_projection"])
    windows_browser_text = read_text(required_inputs["windows_discovery_browser"])
    windows_product_action_text = read_text(required_inputs["windows_product_action_targets"])
    windows_product_action_gate_text = read_text(required_inputs["windows_product_action_gate"])
    windows_command_gate_text = read_text(required_inputs["windows_command_gate"])
    windows_remote_desktop_actions_text = read_text(required_inputs["windows_remote_desktop_actions"])
    windows_file_transfer_text = read_text(required_inputs["windows_file_transfer_runtime_proof"])
    windows_discovery_text = read_text(required_inputs["windows_rust_discovery"])
    windows_bridge_text = read_text(required_inputs["windows_core_bridge"])

    apple_missing = [
        token
        for token in expected_apple_services
        + expected_windows_services
        + expected_capability_tokens
        + expected_txt_tokens
        if token not in apple_text
    ]
    add_check(
        checks,
        "apple_protocol_contract_exports_json_tokens",
        not apple_missing,
        f"missing={apple_missing}",
    )

    android_missing = [
        token
        for token in expected_apple_services + expected_capability_tokens + expected_txt_tokens
        if token not in android_interop_text
    ]
    add_check(
        checks,
        "android_bonjour_contract_tokens",
        not android_missing,
        f"missing={android_missing}",
    )

    android_route_provenance_ok = (
        "resolvedPort > 0" in android_interop_text
        and "return 0" in android_interop_text
        and "resolveTxtPort" not in android_interop_text
        and "capability strings as proof of a dialable route" in android_routes_text
    )
    add_check(
        checks,
        "android_route_provenance_fail_closed",
        android_route_provenance_ok,
        "resolved DNS-SD port is required; TXT port fallback must stay absent",
    )

    android_product_action_authority_ok = all(
        token in android_action_projection_text
        for token in (
            "EstablishedDiscoveryProductSession",
            "DiscoveryProductSessionState.Established",
            "AuthenticatedProductSessionRequired",
            "ProductSessionNotEstablished",
            "ProductSessionExpired",
            "MissingPeerIdentity",
            "PeerDeviceIdMismatch",
            "PeerFingerprintMismatch",
            "MissingAuthenticatedRouteBinding",
            "AuthenticatedRouteBindingExpired",
            "AuthenticatedDiscoveryProductRouteBinding",
            "macRemotePeerIdentityHint",
        )
    ) and all(
        token not in android_action_projection_text
        for token in (
            "enabled = developerSettings.enableRemoteControl",
            "AuthenticatedClassicSessionRequired",
        )
    )
    add_check(
        checks,
        "android_product_action_authority_fail_closed",
        android_product_action_authority_ok,
        "file-transfer and remote-desktop actions must require a matching established product session, not only Bonjour TXT or feature flags",
    )

    windows_order = parse_csharp_string_array(windows_browser_text, "DefaultQueryOrder")
    add_check(
        checks,
        "windows_discovery_query_order",
        windows_order == expected_windows_services,
        f"expected={expected_windows_services}, actual={windows_order}",
    )

    rust_missing = [
        service
        for service in expected_windows_services
        if service not in windows_discovery_text
    ]
    add_check(
        checks,
        "windows_rust_discovery_service_kinds",
        not rust_missing and "FileTransfer" in windows_discovery_text and "RemoteControl" in windows_discovery_text,
        f"missing_services={rust_missing}",
    )

    bridge_ok = "FileTransfer = 3" in windows_bridge_text and "RemoteControl = 4" in windows_bridge_text
    add_check(
        checks,
        "windows_corebridge_service_kind_names",
        bridge_ok,
        "CoreBridge must name dedicated file-transfer and remote-control service kinds",
    )

    windows_product_action_authority_ok = all(
        token in windows_product_action_text
        for token in (
            "EstablishedProductControlSessionSnapshot",
            "MissingEstablishedProductControlSession",
            "ProductControlSessionExpired",
            "PeerDeviceIdMismatch",
            "PeerFingerprintMismatch",
            "UnsupportedRouteProvenance",
            "MissingAuthenticatedRouteBinding",
            "AuthenticatedRouteBindingExpired",
            "AuthenticatedProductRouteBinding",
            "resolved-dns-sd-endpoint",
        )
    )
    add_check(
        checks,
        "windows_product_action_authority_fail_closed",
        windows_product_action_authority_ok,
        "resolved route must become actionable only through a matching established product-control session with an authenticated route binding",
    )

    windows_product_action_command_gate_ok = all(
        token in windows_product_action_gate_text
        for token in (
            "IProductControlSessionSnapshotClient",
            "UnavailableProductControlSessionSnapshotClient",
            "MissingValidatedDiscoveryCandidate",
            "EvaluateRemoteDesktop",
        )
    ) and all(
        token in windows_command_gate_text
        for token in (
            "BuildRemoteDesktopProductActionGate",
            "EvaluateRemoteDesktop",
            "CanRecommendedRemoteDesktopConnect",
            "CanAdvancedRemoteDesktopConnect",
        )
    ) and all(
        token in windows_remote_desktop_actions_text
        for token in (
            "RequireRemoteDesktopProductAction",
            "EvaluateRemoteDesktop",
            "Remote Desktop product action is blocked",
        )
    )
    add_check(
        checks,
        "windows_product_action_consumed_by_remote_desktop_gate",
        windows_product_action_command_gate_ok,
        "Remote Desktop connect commands must consume product action gate at CanExecute and execution time",
    )

    windows_file_transfer_wire_ok = all(
        token in windows_file_transfer_text
        for token in (
            'WriteHeader(writer, "metadata"',
            'WriteHeader(writer, "metadataAck"',
            'WriteHeader(writer, "chunk"',
            'WriteHeader(writer, "chunkAck"',
            'WriteHeader(writer, "complete"',
            'WriteHeader(writer, "completeAck"',
            '"chunkData"',
            '"chunkSha256"',
            '"receivedBytes"',
            'Guid.NewGuid().ToString("D").ToLowerInvariant()',
            'Guid.TryParseExact(transferId, "D"',
        )
    ) and all(
        token not in windows_file_transfer_text
        for token in (
            'WriteString("type", "manifest"',
            'WriteString("type", "manifestAck"',
            'WriteString("type", "completeAck"',
        )
    )
    add_check(
        checks,
        "windows_file_transfer_uses_cross_network_op_schema",
        windows_file_transfer_wire_ok,
        "Windows SBWC FileTransfer proof must use Apple/Android CrossNetworkFileTransferMessage op schema, UUID transferId, and base64 SHA fields",
    )

    provenance_ok = all(bool(route_provenance.get(key)) for key in (
        "txtPortsAreDiagnosticOnly",
        "actionableRoutesRequireResolvedDnsSdEndpoint",
        "capabilitiesDoNotCreateRoutes",
        "pubKeyFingerprintIsTrustHintOnly",
    ))
    add_check(
        checks,
        "contract_route_provenance",
        provenance_ok,
        "contract must keep DNS-SD TXT as untrusted metadata",
    )

    for name, check in checks.items():
        if not check.get("ok"):
            blockers.append(f"{name}: {check.get('detail', '')}")

    status = "pass" if not blockers else "fail"
    report = {
        "status": status,
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "artifact_date": artifact_date,
        "paths": {
            "ios_root": str(ios_root),
            "android_root": str(android_root),
            "windows_root": str(windows_root),
            "contract_json": str(contract_path),
        },
        "service_types": service_types,
        "checks": checks,
        "blockers": blockers,
    }
    write_bonjour_report(report, out_json, out_md)

    print(f"[interop] bonjour-status={status}")
    print(f"[interop] wrote {out_json}")
    print(f"[interop] wrote {out_md}")
    return 0 if status == "pass" else 1


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-date", default=os.getenv("ARTIFACT_DATE", "2026-01-23"))
    parser.add_argument("--ios-root", default=str(repo_root))
    parser.add_argument(
        "--android-root", default="/Users/bill/Desktop/SkyBridge Compass - Android"
    )
    parser.add_argument("--ubuntu-root", default="/Users/bill/Desktop/SkyBridge Compass Ubuntu")
    parser.add_argument(
        "--windows-root",
        default="/Users/bill/Desktop/SkyBridge Compass-win64/Skybridge-Compass",
    )
    parser.add_argument(
        "--website-root", default="/Users/bill/Desktop/skybridge-sinan-website"
    )
    parser.add_argument("--bonjour-only", action="store_true")
    parser.add_argument("--contract-json")
    parser.add_argument("--out-json")
    parser.add_argument("--out-md")
    args = parser.parse_args()

    artifact_date = args.artifact_date
    if args.bonjour_only:
        return run_bonjour_contract_check(args, repo_root, artifact_date)

    out_json = Path(args.out_json or f"Artifacts/interop_consistency_{artifact_date}.json")
    out_md = Path(args.out_md or f"Artifacts/interop_consistency_{artifact_date}.md")

    ios_root = Path(args.ios_root)
    android_root = Path(args.android_root)
    ubuntu_root = Path(args.ubuntu_root)
    windows_root = Path(args.windows_root)
    website_root = Path(args.website_root)

    ios_suite_file = first_existing(
        ios_root / "Sources/SkyBridgeProtocolCore/P2P/CryptoSuite.swift",
        ios_root / "Sources/SkyBridgeCore/P2P/CryptoProviderProtocol.swift",
        ios_root / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/CryptoProviderProtocol.swift",
    )
    ios_wire_file = first_existing(
        ios_root / "Sources/SkyBridgeCore/P2P/HandshakeMessages.swift",
        ios_root / "Sources/SkyBridgeProtocolCore/P2P/HandshakeMessages.swift",
        ios_root / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakeMessages.swift",
    )
    ios_fallback_file = first_existing(
        ios_root / "Sources/SkyBridgeCore/P2P/TwoAttemptHandshakeManager.swift",
        ios_root / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/TwoAttemptHandshakeManager.swift",
    )
    ios_sig_file = first_existing(
        ios_root / "Sources/SkyBridgeCore/P2P/PreNegotiationSignatureSelector.swift",
    )
    ios_trust_file = first_existing(
        ios_root / "Sources/SkyBridgeCore/P2P/MultiAlgorithmSignatureVerifier.swift",
    )
    ios_app_message_file = ios_root / "Sources/SkyBridgeCore/P2P/AppMessage.swift"
    ios_webrtc_codec_file = (
        ios_root / "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCControlChannelCodec.swift"
    )
    ios_webrtc_policy_file = (
        ios_root / "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCBootstrapAppMessagePolicy.swift"
    )
    ios_app_message_copy_file = (
        ios_root / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Messaging/AppMessage.swift"
    )

    android_suite_file = (
        android_root
        / "shared/src/main/kotlin/com/skybridge/compass/shared/p2p/P2PCryptoSuite.kt"
    )
    android_wire_file = (
        android_root
        / "shared/src/main/kotlin/com/skybridge/compass/shared/p2p/P2PHandshakeWire.kt"
    )
    android_client_file = (
        android_root
        / "shared/src/main/kotlin/com/skybridge/compass/shared/p2p/P2PHandshakeClient.kt"
    )
    android_app_message_file = (
        android_root / "core/src/main/kotlin/com/skybridge/compass/core/p2p/AppMessage.kt"
    )
    android_webrtc_manager_file = (
        android_root
        / "core/src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt"
    )
    android_route_binding_consumer_file = (
        android_root
        / "core/src/main/kotlin/com/skybridge/compass/core/webrtc/AuthenticatedRouteBindingConsumer.kt"
    )
    android_product_session_store_file = (
        android_root
        / "shared/src/main/kotlin/com/skybridge/compass/shared/productsession/ProductSessionAuthorityStore.kt"
    )
    android_action_projection_file = (
        android_root
        / "app/src/main/kotlin/com/skybridge/compass/android/discovery/DiscoveryPeerActionProjection.kt"
    )
    android_app_module_file = android_root / "app/src/main/kotlin/com/skybridge/compass/android/di/AppModule.kt"
    android_transport_factory_file = (
        android_root / "app/src/main/kotlin/com/skybridge/compass/android/webrtc/AppWebRtcTransportFactory.kt"
    )
    android_discovery_screen_file = (
        android_root
        / "app/src/main/kotlin/com/skybridge/compass/android/ui/screens/devicediscovery/DeviceDiscoveryScreen.kt"
    )
    windows_route_binding_codec_file = (
        windows_root
        / "windows/Skybridge.WinClient/Services/WebRtcAuthenticatedRouteBindingPayload.cs"
    )
    windows_route_binding_store_file = (
        windows_root
        / "windows/Skybridge.WinClient/Services/WebRtcAuthenticatedRouteBindingStore.cs"
    )

    ubuntu_suite_file = ubuntu_root / "skybridge-core/src/crypto/suite.rs"
    ubuntu_messages_file = ubuntu_root / "skybridge-core/src/p2p/messages.rs"
    ubuntu_driver_file = ubuntu_root / "skybridge-core/src/p2p/driver.rs"
    ubuntu_trust_file = ubuntu_root / "skybridge-core/src/p2p/trust.rs"

    website_supabase_file = first_existing(
        website_root / "frontend/src/lib/supabase.ts",
        website_root / "src/lib/supabase.ts",
        website_root / "yunqiao-sinan-source-code/src/lib/supabase.ts",
    )

    required_inputs = {
        "ios_suite_file": ios_suite_file,
        "ios_wire_file": ios_wire_file,
        "ios_fallback_file": ios_fallback_file,
        "ios_sig_file": ios_sig_file,
        "ios_trust_file": ios_trust_file,
        "ios_app_message_file": ios_app_message_file,
        "ios_webrtc_codec_file": ios_webrtc_codec_file,
        "ios_webrtc_policy_file": ios_webrtc_policy_file,
        "ios_app_message_copy_file": ios_app_message_copy_file,
        "android_suite_file": android_suite_file,
        "android_wire_file": android_wire_file,
        "android_client_file": android_client_file,
        "android_app_message_file": android_app_message_file,
        "android_webrtc_manager_file": android_webrtc_manager_file,
        "android_route_binding_consumer_file": android_route_binding_consumer_file,
        "android_product_session_store_file": android_product_session_store_file,
        "android_action_projection_file": android_action_projection_file,
        "android_app_module_file": android_app_module_file,
        "android_transport_factory_file": android_transport_factory_file,
        "android_discovery_screen_file": android_discovery_screen_file,
        "windows_route_binding_codec_file": windows_route_binding_codec_file,
        "windows_route_binding_store_file": windows_route_binding_store_file,
        "ubuntu_suite_file": ubuntu_suite_file,
        "ubuntu_messages_file": ubuntu_messages_file,
        "ubuntu_driver_file": ubuntu_driver_file,
        "ubuntu_trust_file": ubuntu_trust_file,
    }
    missing_inputs = [f"{name}: {path}" for name, path in required_inputs.items() if not path.exists()]
    if missing_inputs:
        report = {
            "status": "fail",
            "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "artifact_date": artifact_date,
            "paths": {
                "ios_root": str(ios_root),
                "android_root": str(android_root),
                "ubuntu_root": str(ubuntu_root),
                "windows_root": str(windows_root),
                "website_root": str(website_root),
            },
            "suite_ids": {
                "ios_mac": {},
                "android": {},
                "ubuntu": {},
            },
            "diffs": {
                "missing_in_android": [],
                "extra_in_android": [],
                "missing_in_ubuntu": [],
                "extra_in_ubuntu": [],
            },
            "checks": {},
            "blockers": [
                "Missing required cross-platform source inputs.",
                *missing_inputs,
            ],
            "warnings": [],
        }
        write_report(report, out_json, out_md)
        print("[interop] status=fail")
        print(f"[interop] wrote {out_json}")
        print(f"[interop] wrote {out_md}")
        return 1

    ios_suite_text = read_text(ios_suite_file)
    ios_wire_text = read_text(ios_wire_file)
    ios_fallback_text = read_text(ios_fallback_file)
    ios_sig_text = read_text(ios_sig_file)
    ios_trust_text = read_text(ios_trust_file)
    ios_app_message_text = read_text(ios_app_message_file)
    ios_webrtc_codec_text = read_text(ios_webrtc_codec_file)
    ios_webrtc_policy_text = read_text(ios_webrtc_policy_file)
    ios_app_message_copy_text = read_text(ios_app_message_copy_file)

    android_suite_text = read_text(android_suite_file)
    android_wire_text = read_text(android_wire_file)
    android_client_text = read_text(android_client_file)
    android_app_message_text = read_text(android_app_message_file)
    android_webrtc_manager_text = read_text(android_webrtc_manager_file)
    android_route_binding_consumer_text = read_text(android_route_binding_consumer_file)
    android_product_session_store_text = read_text(android_product_session_store_file)
    android_action_projection_text = read_text(android_action_projection_file)
    android_app_module_text = read_text(android_app_module_file)
    android_transport_factory_text = read_text(android_transport_factory_file)
    android_discovery_screen_text = read_text(android_discovery_screen_file)
    windows_route_binding_codec_text = read_text(windows_route_binding_codec_file)
    windows_route_binding_store_text = read_text(windows_route_binding_store_file)

    ubuntu_suite_text = read_text(ubuntu_suite_file)
    ubuntu_messages_text = read_text(ubuntu_messages_file)
    ubuntu_driver_text = read_text(ubuntu_driver_file)
    ubuntu_trust_text = read_text(ubuntu_trust_file)

    ios_suites = parse_swift_suites(ios_suite_text)
    android_suites = parse_android_suites(android_suite_text)
    ubuntu_suites = parse_ubuntu_suites(ubuntu_suite_text)

    missing_android, extra_android = set_diff(ios_suites, android_suites)
    missing_ubuntu, extra_ubuntu = set_diff(ios_suites, ubuntu_suites)

    blockers: List[str] = []
    warnings: List[str] = []

    website_supabase_text = ""
    if website_supabase_file.exists():
        website_supabase_text = read_text(website_supabase_file)
    else:
        warnings.append(
            f"Website Supabase source not found at {website_supabase_file}; "
            "backend/account alignment evidence is omitted from this P2P interop report"
        )

    if missing_android:
        blockers.append(f"Android missing iOS/mac suite IDs: {', '.join(missing_android)}")
    if missing_ubuntu:
        blockers.append(f"Ubuntu missing iOS/mac suite IDs: {', '.join(missing_ubuntu)}")

    android_strict_unknown_suite = bool(
        re.search(r"requireNotNull\(P2PCryptoSuite\.fromWireId\(wireId\)\)", android_wire_text)
    )
    if android_strict_unknown_suite:
        blockers.append("Android MessageA parser hard-fails on unknown suite IDs (not forward-compatible)")

    android_has_p2p_trust_store = bool(
        re.search(r"p2p.*trust|TrustStore|peer_signing_fingerprint", android_wire_text, re.IGNORECASE)
    )
    if not android_has_p2p_trust_store:
        blockers.append("Android shared P2P handshake module lacks explicit pinned-peer trust store path")

    android_classic_only_path = bool(
        re.search(r"supportedSuites\s*=\s*listOf\(P2PCryptoSuite\.X25519\)", android_client_text)
    )
    if android_classic_only_path:
        warnings.append("Android initiator currently starts with classic-only practical path (X25519)")

    swift_le = "appendUInt16LE" in ios_wire_text and "readUInt16LE" in ios_wire_text
    android_le = "ByteOrder.LITTLE_ENDIAN" in android_wire_text and "readU16LE" in android_wire_text
    ubuntu_le = (
        "to_le_bytes" in ubuntu_messages_text
        and "from_le_bytes" in ubuntu_messages_text
        and "to_le_bytes" in read_text(ubuntu_root / "skybridge-core/src/p2p/encoding.rs")
    )

    swift_timeout_blocked = bool(
        re.search(r"case\s+\.timeout[^:]*:\s*return\s+false", ios_fallback_text)
    )
    ubuntu_timeout_not_in_fallback = not bool(
        re.search(r"Timeout", re.search(r"let should_fallback = matches!\((.*?)\);", ubuntu_driver_text, re.S).group(1))
    ) if re.search(r"let should_fallback = matches!\((.*?)\);", ubuntu_driver_text, re.S) else False
    if not ubuntu_timeout_not_in_fallback:
        warnings.append("Ubuntu fallback branch could not confirm timeout exclusion")

    swift_cooldown_300 = bool(
        re.search(r"fallbackCooldownSeconds\s*:\s*Int\s*=\s*300", ios_fallback_text)
    )
    ubuntu_has_cooldown = "cooldown" in ubuntu_driver_text.lower()
    android_has_cooldown = "cooldown" in android_wire_text.lower()
    if not ubuntu_has_cooldown:
        warnings.append("Ubuntu handshake driver has no explicit per-peer fallback cooldown actor/path")
    if not android_has_cooldown:
        warnings.append("Android shared handshake module has no explicit fallback cooldown path")

    swift_sig_rule = bool(
        re.search(r"hasPQCOrHybrid\s*\?\s*\.mlDSA65\s*:\s*\.ed25519", ios_sig_text)
    )
    ubuntu_sig_rule = bool(
        re.search(r"if\s+has_pqc\s*\{\s*SignatureAlgorithm::MlDsa65\s*\}\s*else\s*\{\s*SignatureAlgorithm::Ed25519\s*\}", ubuntu_driver_text, re.S)
    )
    android_sig_rule = bool(
        re.search(r"when\s*\(algorithm\)\s*\{.*ED25519.*ML_DSA_65", android_wire_text, re.S)
    )

    ubuntu_has_trust_pinning = "verify_peer_fingerprint" in ubuntu_driver_text and "peer_signing_fingerprint" in ubuntu_trust_text
    swift_has_trust_pinning = "identityMismatch" in ios_fallback_text and "allowsLegacyFallback" in ios_trust_text
    website_is_backend_evidence = "shared same Supabase project".lower() in website_supabase_text.lower() or "共享同一 Supabase 项目" in website_supabase_text
    if website_is_backend_evidence:
        warnings.append("Website repository is backend/account alignment evidence, not P2P handshake proof")

    route_binding_schema_tokens = [
        "authenticatedRouteBinding",
        "AuthenticatedRouteBindingPayload",
        "serviceType",
        "instanceName",
        "hostName",
        "endpointProvenance",
        "routeAuthorityProtocolPublicKeyFingerprint",
        "remoteProtocolPublicKeyFingerprint",
        "sessionHashHex",
        "transcriptPrefixHex",
        "expiresAt",
        "nonce",
    ]
    swift_route_binding_schema = all(token in ios_app_message_text for token in route_binding_schema_tokens)
    swift_ios_copy_route_binding_schema = all(token in ios_app_message_copy_text for token in route_binding_schema_tokens)
    swift_route_binding_codec = (
        "authenticatedRouteBinding" in ios_webrtc_codec_text
        and "dropUntilPQCRekey" in ios_webrtc_policy_text
        and "case .clipboard, .textMessage, .authenticatedRouteBinding" in ios_webrtc_policy_text
    )
    android_route_binding_schema = all(token in android_app_message_text for token in route_binding_schema_tokens)
    android_route_binding_consumer = all(
        token in android_route_binding_consumer_text
        for token in (
            "AuthenticatedRouteBindingConsumer",
            "AuthenticatedRouteBindingValidationContext",
            "ProductSessionAuthorityStore",
            "routeAuthorityProtocolPublicKeyFingerprint",
            "remoteProtocolPublicKeyFingerprint",
            "sessionHashHex",
            "transcriptPrefixHex",
            "SwiftDateSeconds.toUnixEpochMillis",
            "route-binding authority fingerprint mismatch",
            "route-binding receiver fingerprint mismatch",
            "route-binding session hash mismatch",
            "route-binding transcript prefix mismatch",
        )
    )
    android_product_session_store = all(
        token in android_product_session_store_text
        for token in (
            "ProductSessionAuthorityStore",
            "InMemoryProductSessionAuthorityStore",
            "StateFlow<List<ProductSessionAuthority>>",
            "upsertEstablishedRouteBinding",
            "clearExpired",
            "maxSessions",
            "maxBindingsPerSession",
            "resolved-dns-sd-endpoint",
        )
    )
    android_route_binding_manager_wired = all(
        token in android_webrtc_manager_text
        for token in (
            "ProductSessionAuthorityStore",
            "AuthenticatedRouteBindingConsumer",
            "handleAuthenticatedRouteBinding",
            "routeBindingConsumer",
            "unsignedLongHex16(openedEnvelope.sessionHash)",
            "unsignedLongHex16(openedEnvelope.transcriptPrefix)",
            "productSessionAuthorityStore?.clearSession",
            "routeBindingAccepted",
        )
    ) and "authenticated route-binding consumer is not wired" not in android_webrtc_manager_text
    android_route_binding_app_composition = all(
        token in android_app_module_text + android_transport_factory_text + android_discovery_screen_text + android_action_projection_text
        for token in (
            "provideProductSessionAuthorityStore",
            "InMemoryProductSessionAuthorityStore",
            "productSessionAuthorityStore",
            "productSessions",
            "productSessionFor",
            "DiscoveryPeerActionProjection.actionsFor(device, devSettings, productSession)",
            "ProductRouteBindingProtocol.ENDPOINT_PROVENANCE_RESOLVED_DNS_SD",
        )
    )
    windows_route_binding_codec = all(
        token in windows_route_binding_codec_text
        for token in (
            "WebRtcAuthenticatedRouteBindingPayload",
            "authenticatedRouteBinding",
            "resolved-dns-sd-endpoint",
            "routeAuthorityProtocolPublicKeyFingerprint",
            "remoteProtocolPublicKeyFingerprint",
            "sessionHashHex",
            "transcriptPrefixHex",
            "Nonce",
        )
    )
    windows_route_binding_store = all(
        token in windows_route_binding_store_text
        for token in (
            "IProductControlSessionSnapshotClient",
            "IWebRtcProductControlRuntimeConsumer",
            "WebRtcProductControlSecureSessionState.Established",
            "RouteAuthorityProtocolPublicKeyFingerprint",
            "SessionHashHex",
            "TranscriptPrefixHex",
            "FailClosedLocked",
        )
    )

    checks = {
        "wire_little_endian_alignment": {
            "ok": bool(swift_le and android_le and ubuntu_le),
            "detail": f"swift={swift_le}, android={android_le}, ubuntu={ubuntu_le}",
        },
        "signature_selection_contract": {
            "ok": bool(swift_sig_rule and ubuntu_sig_rule and android_sig_rule),
            "detail": f"swift={swift_sig_rule}, android={android_sig_rule}, ubuntu={ubuntu_sig_rule}",
        },
        "timeout_fallback_blocked": {
            "ok": bool(swift_timeout_blocked and ubuntu_timeout_not_in_fallback),
            "detail": f"swift={swift_timeout_blocked}, ubuntu={ubuntu_timeout_not_in_fallback}, android=not_implemented_in_shared_core",
        },
        "cooldown_guard": {
            "ok": bool(swift_cooldown_300 and ubuntu_has_cooldown and android_has_cooldown),
            "detail": f"swift={swift_cooldown_300}, android={android_has_cooldown}, ubuntu={ubuntu_has_cooldown}",
        },
        "trust_pinning_path": {
            "ok": bool(swift_has_trust_pinning and ubuntu_has_trust_pinning and android_has_p2p_trust_store),
            "detail": f"swift={swift_has_trust_pinning}, android={android_has_p2p_trust_store}, ubuntu={ubuntu_has_trust_pinning}",
        },
        "suite_catalog_parity": {
            "ok": not missing_android and not missing_ubuntu and not extra_android and not extra_ubuntu,
            "detail": (
                f"missing_android={missing_android}, missing_ubuntu={missing_ubuntu}, "
                f"extra_android={extra_android}, extra_ubuntu={extra_ubuntu}"
            ),
        },
        "authenticated_route_binding_appcontrol_schema": {
            "ok": bool(
                swift_route_binding_schema
                and swift_ios_copy_route_binding_schema
                and swift_route_binding_codec
                and android_route_binding_schema
                and android_route_binding_consumer
                and android_product_session_store
                and android_route_binding_manager_wired
                and android_route_binding_app_composition
                and windows_route_binding_codec
                and windows_route_binding_store
            ),
            "detail": (
                f"swift_core={swift_route_binding_schema}, swift_ios={swift_ios_copy_route_binding_schema}, "
                f"swift_codec_policy={swift_route_binding_codec}, android_schema={android_route_binding_schema}, "
                f"android_consumer={android_route_binding_consumer}, "
                f"android_store={android_product_session_store}, "
                f"android_manager_wired={android_route_binding_manager_wired}, "
                f"android_app_composition={android_route_binding_app_composition}, "
                f"windows_codec={windows_route_binding_codec}, windows_consumer_store={windows_route_binding_store}"
            ),
        },
    }

    route_binding_check = checks["authenticated_route_binding_appcontrol_schema"]
    if not route_binding_check["ok"]:
        blockers.append(
            "authenticated_route_binding_appcontrol_schema: "
            + route_binding_check["detail"]
        )

    status = "pass" if not blockers else "fail"
    report = {
        "status": status,
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "artifact_date": artifact_date,
        "paths": {
            "ios_root": str(ios_root),
            "android_root": str(android_root),
            "ubuntu_root": str(ubuntu_root),
            "windows_root": str(windows_root),
            "website_root": str(website_root),
        },
        "suite_ids": {
            "ios_mac": ios_suites,
            "android": android_suites,
            "ubuntu": ubuntu_suites,
        },
        "diffs": {
            "missing_in_android": missing_android,
            "extra_in_android": extra_android,
            "missing_in_ubuntu": missing_ubuntu,
            "extra_in_ubuntu": extra_ubuntu,
        },
        "checks": checks,
        "blockers": blockers,
        "warnings": warnings,
    }

    write_report(report, out_json, out_md)

    print(f"[interop] status={status}")
    print(f"[interop] wrote {out_json}")
    print(f"[interop] wrote {out_md}")
    return 0 if status == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
