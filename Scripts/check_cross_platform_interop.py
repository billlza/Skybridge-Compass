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
from typing import Dict, List, Tuple


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
        "--website-root", default="/Users/bill/Desktop/SkyBridge-official website"
    )
    parser.add_argument("--out-json")
    parser.add_argument("--out-md")
    args = parser.parse_args()

    artifact_date = args.artifact_date
    out_json = Path(args.out_json or f"Artifacts/interop_consistency_{artifact_date}.json")
    out_md = Path(args.out_md or f"Artifacts/interop_consistency_{artifact_date}.md")

    ios_root = Path(args.ios_root)
    android_root = Path(args.android_root)
    ubuntu_root = Path(args.ubuntu_root)
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

    ubuntu_suite_file = ubuntu_root / "skybridge-core/src/crypto/suite.rs"
    ubuntu_messages_file = ubuntu_root / "skybridge-core/src/p2p/messages.rs"
    ubuntu_driver_file = ubuntu_root / "skybridge-core/src/p2p/driver.rs"
    ubuntu_trust_file = ubuntu_root / "skybridge-core/src/p2p/trust.rs"

    website_supabase_file = website_root / "frontend/src/lib/supabase.ts"

    required_inputs = {
        "ios_suite_file": ios_suite_file,
        "ios_wire_file": ios_wire_file,
        "ios_fallback_file": ios_fallback_file,
        "ios_sig_file": ios_sig_file,
        "ios_trust_file": ios_trust_file,
        "android_suite_file": android_suite_file,
        "android_wire_file": android_wire_file,
        "android_client_file": android_client_file,
        "ubuntu_suite_file": ubuntu_suite_file,
        "ubuntu_messages_file": ubuntu_messages_file,
        "ubuntu_driver_file": ubuntu_driver_file,
        "ubuntu_trust_file": ubuntu_trust_file,
        "website_supabase_file": website_supabase_file,
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

    android_suite_text = read_text(android_suite_file)
    android_wire_text = read_text(android_wire_file)
    android_client_text = read_text(android_client_file)

    ubuntu_suite_text = read_text(ubuntu_suite_file)
    ubuntu_messages_text = read_text(ubuntu_messages_file)
    ubuntu_driver_text = read_text(ubuntu_driver_file)
    ubuntu_trust_text = read_text(ubuntu_trust_file)

    website_supabase_text = read_text(website_supabase_file)

    ios_suites = parse_swift_suites(ios_suite_text)
    android_suites = parse_android_suites(android_suite_text)
    ubuntu_suites = parse_ubuntu_suites(ubuntu_suite_text)

    missing_android, extra_android = set_diff(ios_suites, android_suites)
    missing_ubuntu, extra_ubuntu = set_diff(ios_suites, ubuntu_suites)

    blockers: List[str] = []
    warnings: List[str] = []

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
    }

    status = "pass" if not blockers else "fail"
    report = {
        "status": status,
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "artifact_date": artifact_date,
        "paths": {
            "ios_root": str(ios_root),
            "android_root": str(android_root),
            "ubuntu_root": str(ubuntu_root),
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
