#!/usr/bin/env python3
"""
Protocol-parity drift checker for the iOS <-> macOS hand-copied protocol layer.

WHY THIS EXISTS
---------------
`Docs/CoreLayering.md` documents that the iOS app (`SkyBridge Compass iOS/`)
does NOT consume `SkyBridgeProtocolCore`; instead it carries ~60 same-named
protocol/wire/handshake files that were hand-copied from the macOS tree and
have since evolved independently. Wire compatibility between the two clients
therefore relies on manual discipline, not the type system — the single
largest cross-platform regression risk in the repo.

WHAT THIS DOES (and does NOT do)
--------------------------------
A naive byte-identity check is useless here: as of this writing 35/36
same-named files already differ (platform imports, `#if os(...)`, iOS-only
paths, formatting). So this tool does two honest things instead:

  1. DRIFT BASELINE (acknowledgement gate): for every tracked same-named pair
     it computes a *normalized* hash of each side (comments / imports / blank
     lines / whitespace stripped) and compares to a committed baseline
     (`Scripts/protocol_parity_baseline.json`). If either side's normalized
     content changed without the baseline being updated in the same commit,
     the check FAILS — forcing a human to (a) re-verify the counterpart stays
     wire-compatible and (b) run `--update-baseline` to acknowledge.
     This catches *one-sided silent edits* to wire-critical files.

  2. WIRE-ANCHOR CROSS-CHECK (must-match invariants): a small set of constants
     that MUST be byte-identical across platforms for interop (e.g. the WebRTC
     DataChannel labels) are extracted from both trees and asserted equal,
     regardless of file-level divergence.

Files that are legitimately platform-specific (not wire formats) are listed in
EXEMPT and excluded from tracking.

USAGE
-----
  python3 Scripts/check_protocol_parity.py              # verify (CI mode)
  python3 Scripts/check_protocol_parity.py --update-baseline   # accept current state
  python3 Scripts/check_protocol_parity.py --list      # show tracked pairs + status

Exit code 0 = parity OK; non-zero = drift / missing baseline / anchor mismatch.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
IOS_CORE = REPO_ROOT / "SkyBridge Compass iOS" / "SkyBridgeCompassiOS" / "Sources" / "Core"
MACOS_SOURCES = REPO_ROOT / "Sources"
BASELINE_PATH = REPO_ROOT / "Scripts" / "protocol_parity_baseline.json"

# Same-named files that are legitimately platform-specific (NOT wire/protocol
# formats) and are expected to diverge freely. They are excluded from tracking.
# Keep this list small and justified — it is the "explicit exemption list".
EXEMPT = {
    "WeatherService.swift",      # weather feature, not protocol
    "WeatherManager.swift",      # weather feature, not protocol
    "KeychainManager.swift",     # platform keychain wrapper, not a wire format
    "PlatformAdapter.swift",     # platform-capability abstraction, impl differs by design
    "STUNClient.swift",          # transport client impl (the STUN *wire* is RFC-fixed, not ours)
    "CoreTypes.swift",           # iOS-local convenience types
    "BackgroundTaskManager.swift",
}

# Pairs that have intentionally forked (documented in CoreLayering.md). They are
# still tracked for drift, but the report labels them so reviewers know a diff is
# expected and the question is only "did the WIRE behaviour change".
KNOWN_FORKED = {
    "CrossNetworkWebRTCLocalAppMessageFactory.swift",
    "TwoAttemptHandshakeManager.swift",
}

WIRE_ANCHORS = [
    ("DataChannel control label",
     r'controlChannelLabel\s*=\s*"([^"]+)"',
     None),
    ("DataChannel screen label",
     r'screenChannelLabel\s*=\s*"([^"]+)"',
     None),
    ("AppMessage payload cases",
     r'^\s*case\s+([a-z][A-Za-z0-9_]*)\(([A-Za-z0-9_]+Payload)\)',
     "AppMessage.swift"),
    ("Cross-network file-transfer operations",
     r'^\s*case\s+(metadata|metadataAck|chunk|chunkAck|complete|completeAck|cancel|error)\b',
     "CrossNetworkFileTransferWire.swift"),
    ("Cross-network file-transfer fields",
     r'public\s+let\s+([A-Za-z0-9_]+)\s*:\s*([A-Za-z0-9_<>\[\]\?: ]+)',
     "CrossNetworkFileTransferWire.swift"),
    ("Remote-control secure packet types",
     r'case\s+(control|screen|audio)\s*=\s*([0-9]+)',
     "RemoteControlSecureEnvelope.swift"),
    ("Remote-control secure envelope constants",
     r'private\s+static\s+let\s+(magic|version|headerLength|tagLength|epoch|directionInitiatorToResponder|directionResponderToInitiator)\s*(?::\s*[A-Za-z0-9_]+)?\s*=\s*([0-9xA-Fa-f_]+)',
     "RemoteControlSecureEnvelope.swift"),
    ("Handshake signature domains",
     r'static\s+let\s+(protocolA|protocolB|secureEnclaveA|secureEnclaveB)\s*=\s*"([^"]+)"',
     "HandshakeMessages.swift"),
    ("Handshake identity public-key fields",
     r'public\s+let\s+(protocolPublicKey|protocolAlgorithm|secureEnclavePublicKey)\s*:\s*([A-Za-z0-9_<>\[\]\?: ]+)',
     "HandshakeMessages.swift"),
    ("Handshake identity algorithm bytes",
     r'case\s+\.([A-Za-z0-9_]+):\s*algorithmByte\s*=\s*(0x[0-9A-Fa-f]+)',
     "HandshakeMessages.swift"),
    ("WebRTC signaling message types",
     r'case\s+(join|offer|answer|iceCandidate|leave)\b',
     "WebRTCSignalingEnvelope.swift"),
    ("WebRTC signaling payload fields",
     r'public\s+var\s+([A-Za-z0-9_]+)\s*:\s*([A-Za-z0-9_<>\[\]\?: ]+)',
     "WebRTCSignalingEnvelope.swift"),
    ("WebRTC signaling immutable envelope fields",
     r'public\s+let\s+([A-Za-z0-9_]+)\s*:\s*([A-Za-z0-9_<>\[\]\?: ]+)',
     "WebRTCSignalingEnvelope.swift"),
    ("Remote SDP/ICE validator limits",
     r'private\s+static\s+let\s+(maxRemote(?:SDP|ICE)[A-Za-z0-9]+)\s*=\s*([0-9_ *]+)',
     "WebRTCSession+SDP.swift"),
    ("Remote SDP/ICE fail-closed reasons",
     r'"((?:remote (?:offer|answer|ICE candidate)|[^"]*(?:DTLS fingerprint|ICE credentials|session-level ICE candidate|missing sdpMLineIndex|contains control characters|exceeds 256 ICE candidates))[^"]*)"',
     "WebRTCSession+SDP.swift"),
]


def normalize(text: str) -> str:
    """Strip cosmetic noise so only semantically meaningful changes alarm."""
    # Remove block comments.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    out: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("//"):
            continue
        if line.startswith("import "):
            continue
        # Drop trailing line comments (best-effort; ignores // inside strings,
        # which is acceptable for a drift signal).
        if "//" in line:
            line = line.split("//", 1)[0].strip()
            if not line:
                continue
        out.append(line)
    return "\n".join(out)


def norm_hash(path: Path) -> str:
    return hashlib.sha256(normalize(path.read_text(encoding="utf-8", errors="replace")).encode()).hexdigest()


def basenames(root: Path) -> dict[str, Path]:
    found: dict[str, Path] = {}
    for p in root.rglob("*.swift"):
        # Keep the first occurrence; protocol files are unique by basename here.
        found.setdefault(p.name, p)
    return found


def discover_pairs() -> dict[str, dict]:
    """Return {basename: {ios, macos}} for tracked (non-exempt) same-named files."""
    ios = basenames(IOS_CORE)
    mac = basenames(MACOS_SOURCES)
    pairs: dict[str, dict] = {}
    for name, ios_path in sorted(ios.items()):
        if name in EXEMPT:
            continue
        mac_path = mac.get(name)
        if mac_path is None:
            continue
        pairs[name] = {"ios": ios_path, "macos": mac_path}
    return pairs


# --- Wire-anchor cross-checks: constants that MUST match across platforms. ---

def _extract(pattern: str, root: Path) -> set[str]:
    rx = re.compile(pattern, re.MULTILINE)
    vals: set[str] = set()
    for p in root.rglob("*.swift"):
        try:
            for m in rx.finditer(p.read_text(encoding="utf-8", errors="replace")):
                vals.add("|".join(part.strip() for part in m.groups()))
        except OSError:
            continue
    return vals


def _extract_from_named_file(pattern: str, root: Path, filename: str) -> set[str]:
    rx = re.compile(pattern, re.MULTILINE)
    vals: set[str] = set()
    for p in root.rglob(filename):
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for m in rx.finditer(text):
            vals.add("|".join(part.strip() for part in m.groups()))
    return vals


def check_wire_anchors() -> list[str]:
    """Return a list of human-readable mismatch errors (empty = OK)."""
    errors: list[str] = []
    for label, pat, filename in WIRE_ANCHORS:
        if filename is None:
            ios_vals = _extract(pat, IOS_CORE)
            mac_vals = _extract(pat, MACOS_SOURCES)
        else:
            ios_vals = _extract_from_named_file(pat, IOS_CORE, filename)
            mac_vals = _extract_from_named_file(pat, MACOS_SOURCES, filename)
        if not ios_vals or not mac_vals:
            errors.append(f"anchor '{label}': not found on both sides (ios={sorted(ios_vals)} macos={sorted(mac_vals)})")
        elif ios_vals != mac_vals:
            errors.append(f"anchor '{label}' MISMATCH: ios={sorted(ios_vals)} macos={sorted(mac_vals)}")
    return errors


def rel(path: Path) -> str:
    return str(path.relative_to(REPO_ROOT))


def build_state(pairs: dict[str, dict]) -> dict[str, dict]:
    return {
        name: {
            "ios": rel(pp["ios"]),
            "macos": rel(pp["macos"]),
            "ios_hash": norm_hash(pp["ios"]),
            "macos_hash": norm_hash(pp["macos"]),
            "forked": name in KNOWN_FORKED,
        }
        for name, pp in pairs.items()
    }


def cmd_update(pairs):
    state = build_state(pairs)
    BASELINE_PATH.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"✅ baseline updated: {len(state)} tracked pairs -> {rel(BASELINE_PATH)}")
    return 0


def cmd_list(pairs):
    state = build_state(pairs)
    print(f"Tracked protocol-parity pairs ({len(state)}):")
    for name, s in state.items():
        tag = " [KNOWN-FORKED]" if s["forked"] else ""
        print(f"  {name}{tag}\n      ios:   {s['ios']}\n      macos: {s['macos']}")
    print(f"\nExempt (platform-specific, untracked): {', '.join(sorted(EXEMPT))}")
    return 0


def cmd_check(pairs):
    failures: list[str] = []

    # 1) Wire-anchor invariants.
    anchor_errors = check_wire_anchors()
    for e in anchor_errors:
        failures.append(f"[wire-anchor] {e}")

    # 2) Drift baseline.
    if not BASELINE_PATH.exists():
        print(f"❌ no baseline at {rel(BASELINE_PATH)} — run --update-baseline once to record the accepted state.", file=sys.stderr)
        return 2
    baseline = json.loads(BASELINE_PATH.read_text(encoding="utf-8"))
    current = build_state(pairs)

    new_pairs = sorted(set(current) - set(baseline))
    removed = sorted(set(baseline) - set(current))
    for n in new_pairs:
        failures.append(f"[new] tracked pair '{n}' is not in the baseline — review wire-compat then --update-baseline")
    for n in removed:
        failures.append(f"[removed] baselined pair '{n}' no longer found — --update-baseline if intentional")

    for name in sorted(set(current) & set(baseline)):
        cur, base = current[name], baseline[name]
        for side in ("ios", "macos"):
            if cur[f"{side}_hash"] != base.get(f"{side}_hash"):
                failures.append(
                    f"[drift] {name} ({side}) changed since baseline: {cur[side]}\n"
                    f"          → re-verify the {('macos' if side=='ios' else 'ios')} counterpart stays wire-compatible, then run --update-baseline"
                )

    if failures:
        print("❌ protocol-parity check FAILED:\n", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        print(f"\n  Tracked pairs: {len(current)} | anchors checked: {len(WIRE_ANCHORS)}", file=sys.stderr)
        return 1

    print(f"✅ protocol-parity OK — {len(current)} tracked pairs match baseline; wire anchors consistent.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="iOS<->macOS protocol-parity drift checker")
    ap.add_argument("--update-baseline", action="store_true", help="record current normalized hashes as the accepted baseline")
    ap.add_argument("--list", action="store_true", help="list tracked pairs and exemptions")
    args = ap.parse_args()

    if not IOS_CORE.is_dir():
        print(f"❌ iOS core tree not found: {IOS_CORE}", file=sys.stderr)
        return 2

    pairs = discover_pairs()
    if not pairs:
        print("❌ discovered 0 tracked pairs — path layout changed?", file=sys.stderr)
        return 2

    if args.update_baseline:
        return cmd_update(pairs)
    if args.list:
        return cmd_list(pairs)
    return cmd_check(pairs)


if __name__ == "__main__":
    raise SystemExit(main())
