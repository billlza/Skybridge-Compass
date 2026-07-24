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
import stat
import sys
import tempfile
from pathlib import Path
from typing import TypedDict

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
    ("Handshake signature wire codes",
     r'case\s+\.?(ed25519|mlDSA65|mlDSA87|p256ECDSA):\s*return\s*(0x[0-9A-Fa-f]+)',
     None),
    ("Handshake identity public-key lengths",
     r'private\s+static\s+let\s+(ed25519PublicKeyLength|mlDSA65PublicKeyLength|mlDSA87PublicKeyLength|p256PublicKeyLength)\s*=\s*([0-9_]+)',
     "HandshakeMessages.swift"),
    ("ML-DSA provider size contracts",
     r'^\s*(publicKeyLength|signatureLength|applePrivateKeyLength|oqsPrivateKeyLength):\s*([0-9_]+),',
     "SignatureProvider.swift"),
    ("Handshake message allocation limits",
     r'public\s+static\s+let\s+(maxMessageALength|maxMessageBLength)\s*=\s*([0-9_ *]+)',
     None),
    ("Handshake capability decoding limits",
     r'static\s+let\s+(maximumCapabilitiesPayloadLength|maximumPolicyPayloadLength|maximumCollectionCount|maximumStringByteLength|maximumTotalStringBytes)\s*=\s*([0-9_]+)',
     "HandshakeMessages.swift"),
    ("WebRTC control-frame chunk limits",
     r'public\s+func\s+(sendFramedPayload|sendScreenFramedPayload)\(_ payload:\s*Data,\s*maxChunkBytes:\s*Int\s*=\s*([0-9_ *]+)\)',
     "WebRTCSession.swift"),
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
    ("Identity rotation durable journal paths",
     r'path:\s*"(Security/device-identity-rotation(?:-request)?-v1\.json)"',
     "CurrentPathDeviceIdentityRotationCoordinator.swift"),
    ("Identity rotation recovery stages",
     r'private\s+func\s+(completePendingRequest|recoverCommitReadyRotation|requestIdentityRotationChallengePreservingOnlyRecoverableState|commitIdentityRotationPreservingOnlyRecoverableState)\b',
     "CurrentPathDeviceIdentityRotationCoordinator.swift"),
    ("Identity rotation idempotency binding",
     r'idempotencyKey:\s*(request\.requestID)',
     "CurrentPathDeviceIdentityRotationCoordinator.swift"),
    ("Identity rotation journal size limit",
     r'maximumPayloadBytes:\s*([0-9_]+\s*\*\s*[0-9_]+)',
     "CurrentPathDeviceIdentityRotationCoordinator.swift"),
    ("Identity rotation journal schema versions",
     r'(?s)struct\s+(?:IOS)?(PendingDeviceIdentityRotation(?:Request)?)\s*:[^{]+\{\s*static\s+let\s+currentVersion\s*=\s*([0-9]+)',
     "CurrentPathDeviceIdentityRotationCoordinator.swift"),
    ("Identity rotation journal field types",
     r'^\s*let\s+(version|requestID|expectedTenantID|expectedUserID|rotationID|nonce|issuedAtMilliseconds|expiresAtMilliseconds|tenantID|userID|deviceID|oldGeneration|oldAlgorithm|oldProtection|oldFingerprint|oldPublicKey|newAlgorithm|newProtection|newFingerprint|newPublicKey|transcriptHash|transcriptBase64|oldSignature|newSignature|clientVersion|protocolVersion)\s*:\s*([A-Za-z0-9_]+)\s*$',
     "CurrentPathDeviceIdentityRotationCoordinator.swift"),
    ("Q-Periapt ABI2 suite name",
     r'"(Q-Periapt-ABI2-PolicyBound)"',
     None),
    ("Q-Periapt ABI2 suite wire ID",
     r'qperiaptABI2PolicyBound[^\n]*(0x[0-9A-Fa-f]+)',
     None),
    ("Q-Periapt capability provider type",
     r'case\s+qPeriapt\s*=\s*"([^"]+)"',
     None),
    ("Q-Periapt application-context domain",
     r'private\s+static\s+let\s+domain\s*=\s*Data\("([^"]+)"\.utf8\)',
     "QPeriaptHandshakeApplicationContext.swift"),
    ("Q-Periapt offered-suite encoding order",
     r'(?s)for\s+(offeredSuite)\s+in\s+(offeredSuites)\s*\{\s*appendUInt16BE\((offeredSuite)\.wireId,\s*to:\s*&suites\)',
     "QPeriaptHandshakeApplicationContext.swift"),
    ("Q-Periapt application-context field order",
     r'(?s)var\s+context\s*=\s*Data\(\)\s*'
     r'appendField\((domain),\s*to:\s*&context\)\s*'
     r'context\.append\((version)\)\s*'
     r'appendUInt16BE\((suite\.wireId),\s*to:\s*&context\)\s*'
     r'appendField\((clientNonce),\s*to:\s*&context\)\s*'
     r'appendField\((policy)\.deterministicEncode\(\),\s*to:\s*&context\)\s*'
     r'appendField\((suites),\s*to:\s*&context\)\s*'
     r'appendField\(try\s+(capabilities)\.deterministicEncode\(\),\s*to:\s*&context\)\s*'
     r'appendField\((identityPublicKey),\s*to:\s*&context\)\s*'
     r'appendField\((extensionsRaw),\s*to:\s*&context\)\s*'
     r'appendField\((recipientPublicKey),\s*to:\s*&context\)',
     "QPeriaptHandshakeApplicationContext.swift"),
    ("Q-Periapt application-context field length prefix",
     r'var\s+length\s*=\s*UInt32\((field\.count)\)\.(bigEndian)',
     "QPeriaptHandshakeApplicationContext.swift"),
]


class ProtocolParityError(RuntimeError):
    """A fail-closed source, path, baseline, or persistence error."""


SourceIndex = dict[str, tuple[Path, ...]]
Anchor = tuple[str, str, str | None]
_LITERAL_TOKEN_RE = re.compile("\0([0-9]+)\0")


class PairEntry(TypedDict):
    ios: Path
    macos: Path


PairMap = dict[str, PairEntry]


class BaselineEntry(TypedDict):
    ios: str
    macos: str
    ios_hash: str
    macos_hash: str
    forked: bool


ParityState = dict[str, BaselineEntry]


def _comment_separator(out: list[str]) -> None:
    if out and not out[-1].isspace():
        out.append(" ")


def _skip_line_comment(text: str, start: int, out: list[str]) -> int:
    _comment_separator(out)
    newline = text.find("\n", start + 2)
    return len(text) if newline < 0 else newline


def _skip_block_comment(text: str, start: int, out: list[str]) -> int:
    """Skip a nested Swift block comment while retaining its line boundaries."""
    _comment_separator(out)
    depth = 1
    cursor = start + 2
    while cursor < len(text):
        if text.startswith("/*", cursor):
            depth += 1
            cursor += 2
        elif text.startswith("*/", cursor):
            depth -= 1
            cursor += 2
            if depth == 0:
                return cursor
        else:
            if text[cursor] == "\n":
                out.append("\n")
            cursor += 1
    raise ProtocolParityError(f"unterminated block comment at character offset {start}")


def _string_delimiter(text: str, start: int) -> tuple[int, int] | None:
    hash_count = 0
    while start + hash_count < len(text) and text[start + hash_count] == "#":
        hash_count += 1
    quote_start = start + hash_count
    if text.startswith('"""', quote_start):
        return hash_count, 3
    if quote_start < len(text) and text[quote_start] == '"':
        return hash_count, 1
    return None


def _copy_interpolation(text: str, start: int, out: list[str]) -> int:
    """Copy Swift interpolation code through its balanced closing parenthesis."""
    depth = 1
    cursor = start
    while cursor < len(text):
        if text.startswith("//", cursor):
            cursor = _skip_line_comment(text, cursor, out)
            continue
        if text.startswith("/*", cursor):
            cursor = _skip_block_comment(text, cursor, out)
            continue

        delimiter = _string_delimiter(text, cursor)
        if delimiter is not None:
            cursor = _copy_string(text, cursor, delimiter, out)
            continue

        char = text[cursor]
        out.append(char)
        cursor += 1
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return cursor
    raise ProtocolParityError(f"unterminated string interpolation at character offset {start - 1}")


def _copy_string(
    text: str,
    start: int,
    delimiter: tuple[int, int],
    out: list[str],
) -> int:
    """Copy one normal, raw, single-line, or multiline Swift string verbatim."""
    hash_count, quote_count = delimiter
    opening_length = hash_count + quote_count
    out.append(text[start:start + opening_length])
    cursor = start + opening_length
    closing = ('"' * quote_count) + ('#' * hash_count)
    interpolation = "\\" + ("#" * hash_count) + "("

    while cursor < len(text):
        if text.startswith(closing, cursor):
            out.append(closing)
            return cursor + len(closing)
        if text.startswith(interpolation, cursor):
            out.append(interpolation)
            cursor = _copy_interpolation(text, cursor + len(interpolation), out)
            continue

        char = text[cursor]
        if quote_count == 1 and char in "\r\n":
            raise ProtocolParityError(f"unterminated single-line string at character offset {start}")

        # In a non-raw string, an escape consumes the next source character so
        # an escaped quote cannot be mistaken for the closing delimiter.
        if hash_count == 0 and char == "\\":
            if cursor + 1 >= len(text):
                raise ProtocolParityError(f"unterminated escape sequence at character offset {cursor}")
            out.append(text[cursor:cursor + 2])
            cursor += 2
            continue

        out.append(char)
        cursor += 1
    kind = "multiline" if quote_count == 3 else "single-line"
    raise ProtocolParityError(f"unterminated {kind} string at character offset {start}")


def _strip_swift_comments(text: str) -> tuple[str, tuple[str, ...]]:
    if "\0" in text:
        raise ProtocolParityError("Swift source contains a NUL character")

    out: list[str] = []
    literals: list[str] = []
    cursor = 0
    while cursor < len(text):
        if text.startswith("//", cursor):
            cursor = _skip_line_comment(text, cursor, out)
            continue
        if text.startswith("/*", cursor):
            cursor = _skip_block_comment(text, cursor, out)
            continue

        delimiter = _string_delimiter(text, cursor)
        if delimiter is not None:
            literal: list[str] = []
            cursor = _copy_string(text, cursor, delimiter, literal)
            # Reserve a NUL-delimited token that cannot occur in valid Swift
            # source. Restoring after line cleanup preserves semantic spaces
            # and blank lines inside multiline/raw literals without changing
            # the normalized representation of ordinary string literals.
            out.append(f"\0{len(literals)}\0")
            literals.append("".join(literal))
            continue

        out.append(text[cursor])
        cursor += 1
    return "".join(out), tuple(literals)


def normalize(text: str) -> str:
    """Strip cosmetic noise without treating comment markers in strings as comments."""
    without_comments, literals = _strip_swift_comments(text)
    out: list[str] = []
    for raw in without_comments.splitlines():
        line = raw.strip()
        if not line or line.startswith("import "):
            continue
        out.append(line)
    normalized = "\n".join(out)
    return _LITERAL_TOKEN_RE.sub(lambda match: literals[int(match.group(1))], normalized)


def _read_utf8(path: Path, *, purpose: str) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="strict")
    except (OSError, UnicodeError) as exc:
        raise ProtocolParityError(f"cannot read {purpose} as UTF-8: {path}: {exc}") from exc


def norm_hash(path: Path) -> str:
    normalized = normalize(_read_utf8(path, purpose="Swift source"))
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def _source_index(root: Path, *, side: str) -> SourceIndex:
    try:
        resolved_root = root.resolve(strict=True)
    except OSError as exc:
        raise ProtocolParityError(f"{side} source root cannot be resolved: {root}: {exc}") from exc
    if not resolved_root.is_dir():
        raise ProtocolParityError(f"{side} source root is not a directory: {resolved_root}")

    grouped: dict[str, list[Path]] = {}
    try:
        candidates = sorted(resolved_root.rglob("*.swift"))
    except OSError as exc:
        raise ProtocolParityError(f"cannot enumerate {side} Swift sources beneath {resolved_root}: {exc}") from exc
    for candidate in candidates:
        if candidate.is_symlink():
            raise ProtocolParityError(f"{side} Swift source must not be a symlink: {candidate}")
        try:
            resolved = candidate.resolve(strict=True)
            resolved.relative_to(resolved_root)
        except (OSError, ValueError) as exc:
            raise ProtocolParityError(
                f"{side} Swift source escapes or cannot be resolved beneath {resolved_root}: {candidate}"
            ) from exc
        if not resolved.is_file():
            raise ProtocolParityError(f"{side} Swift source is not a regular file: {resolved}")
        grouped.setdefault(candidate.name, []).append(resolved)
    return {name: tuple(paths) for name, paths in grouped.items()}


def _unique_path(index: SourceIndex, name: str, *, side: str, purpose: str) -> Path:
    paths = index.get(name, ())
    if len(paths) != 1:
        rendered = ", ".join(str(path) for path in paths) if paths else "none"
        raise ProtocolParityError(
            f"{side} {purpose} '{name}' must resolve to exactly one path; found {len(paths)}: {rendered}"
        )
    return paths[0]


def _pairs_from_indexes(ios: SourceIndex, macos: SourceIndex) -> PairMap:
    pairs: PairMap = {}
    for name in sorted(set(ios) & set(macos)):
        if name in EXEMPT:
            continue
        pairs[name] = {
            "ios": _unique_path(ios, name, side="iOS", purpose="paired source"),
            "macos": _unique_path(macos, name, side="macOS", purpose="paired source"),
        }
    if not pairs:
        raise ProtocolParityError("discovered 0 tracked pairs — path layout changed?")
    return pairs


def _discover_sources(
    ios_root: Path,
    macos_root: Path,
) -> tuple[SourceIndex, SourceIndex, PairMap]:
    try:
        resolved_ios_root = ios_root.resolve(strict=True)
        resolved_macos_root = macos_root.resolve(strict=True)
    except OSError as exc:
        raise ProtocolParityError(f"source roots cannot be resolved: {exc}") from exc
    if (
        resolved_ios_root == resolved_macos_root
        or resolved_ios_root.is_relative_to(resolved_macos_root)
        or resolved_macos_root.is_relative_to(resolved_ios_root)
    ):
        raise ProtocolParityError(
            "iOS and macOS source roots must be disjoint: "
            f"ios={resolved_ios_root} macos={resolved_macos_root}"
        )

    ios = _source_index(ios_root, side="iOS")
    macos = _source_index(macos_root, side="macOS")
    return ios, macos, _pairs_from_indexes(ios, macos)


def discover_pairs(
    ios_root: Path = IOS_CORE,
    macos_root: Path = MACOS_SOURCES,
) -> PairMap:
    """Return uniquely resolved, non-exempt same-named source pairs."""
    _, _, pairs = _discover_sources(ios_root, macos_root)
    return pairs


# --- Wire-anchor cross-checks: constants that MUST match across platforms. ---

def _compile_anchor(pattern: str, *, label: str) -> re.Pattern[str]:
    try:
        return re.compile(pattern, re.MULTILINE)
    except re.error as exc:
        raise ProtocolParityError(f"invalid wire-anchor pattern '{label}': {exc}") from exc


def _extract(pattern: str, paths: tuple[Path, ...], *, label: str) -> set[str]:
    rx = _compile_anchor(pattern, label=label)
    vals: set[str] = set()
    for path in paths:
        for match in rx.finditer(_read_utf8(path, purpose=f"wire-anchor source for '{label}'")):
            vals.add("|".join(part.strip() for part in match.groups()))
    return vals


def check_wire_anchors(
    ios: SourceIndex,
    macos: SourceIndex,
    anchors: tuple[Anchor, ...] | list[Anchor] = WIRE_ANCHORS,
) -> list[str]:
    """Return semantic anchor mismatches after all named paths are proven unique."""
    named_paths: dict[tuple[str, str], Path] = {}
    for label, _, filename in anchors:
        if filename is None:
            continue
        named_paths[("ios", filename)] = _unique_path(
            ios, filename, side="iOS", purpose=f"wire-anchor source for '{label}'"
        )
        named_paths[("macos", filename)] = _unique_path(
            macos, filename, side="macOS", purpose=f"wire-anchor source for '{label}'"
        )

    all_ios = tuple(path for paths in ios.values() for path in paths)
    all_macos = tuple(path for paths in macos.values() for path in paths)
    errors: list[str] = []
    for label, pattern, filename in anchors:
        if filename is None:
            ios_paths = all_ios
            macos_paths = all_macos
        else:
            ios_paths = (named_paths[("ios", filename)],)
            macos_paths = (named_paths[("macos", filename)],)
        ios_vals = _extract(pattern, ios_paths, label=label)
        macos_vals = _extract(pattern, macos_paths, label=label)
        if not ios_vals or not macos_vals:
            errors.append(
                f"anchor '{label}': not found on both sides "
                f"(ios={sorted(ios_vals)} macos={sorted(macos_vals)})"
            )
        elif ios_vals != macos_vals:
            errors.append(f"anchor '{label}' MISMATCH: ios={sorted(ios_vals)} macos={sorted(macos_vals)}")
    return errors


def rel(path: Path, repo_root: Path = REPO_ROOT) -> str:
    try:
        return str(path.resolve(strict=False).relative_to(repo_root.resolve(strict=True)))
    except (OSError, ValueError) as exc:
        raise ProtocolParityError(f"path is outside the repository root: {path}") from exc


def build_state(
    pairs: PairMap,
    repo_root: Path = REPO_ROOT,
) -> ParityState:
    return {
        name: {
            "ios": rel(paths["ios"], repo_root),
            "macos": rel(paths["macos"], repo_root),
            "ios_hash": norm_hash(paths["ios"]),
            "macos_hash": norm_hash(paths["macos"]),
            "forked": name in KNOWN_FORKED,
        }
        for name, paths in pairs.items()
    }


def _atomic_write_text(path: Path, content: str) -> None:
    if path.is_symlink():
        raise ProtocolParityError(f"refusing to replace a symlink baseline: {path}")
    if not path.parent.is_dir():
        raise ProtocolParityError(f"baseline directory does not exist: {path.parent}")

    try:
        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
        fd, temporary_name = tempfile.mkstemp(
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
        )
    except OSError as exc:
        raise ProtocolParityError(f"cannot create atomic baseline update for {path}: {exc}") from exc

    temporary = Path(temporary_name)
    fd_open = True
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            fd_open = False
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except OSError as exc:
        cleanup_errors: list[str] = []
        if fd_open:
            try:
                os.close(fd)
            except OSError as close_error:
                cleanup_errors.append(f"descriptor close failed: {close_error}")
        try:
            temporary.unlink(missing_ok=True)
        except OSError as unlink_error:
            cleanup_errors.append(f"temporary cleanup failed: {unlink_error}")
        cleanup_context = f"; {'; '.join(cleanup_errors)}" if cleanup_errors else ""
        raise ProtocolParityError(
            f"atomic baseline update failed for {path}: {exc}{cleanup_context}"
        ) from exc


def _render_anchor_failures(errors: list[str], *, anchor_count: int) -> None:
    print("❌ protocol-parity wire-anchor validation FAILED:\n", file=sys.stderr)
    for error in errors:
        print(f"  - [wire-anchor] {error}", file=sys.stderr)
    print(f"\n  Anchors checked: {anchor_count}", file=sys.stderr)


def cmd_update(
    *,
    ios_root: Path = IOS_CORE,
    macos_root: Path = MACOS_SOURCES,
    baseline_path: Path = BASELINE_PATH,
    repo_root: Path = REPO_ROOT,
    anchors: tuple[Anchor, ...] | list[Anchor] = WIRE_ANCHORS,
) -> int:
    ios, macos, pairs = _discover_sources(ios_root, macos_root)
    anchor_errors = check_wire_anchors(ios, macos, anchors)
    if anchor_errors:
        _render_anchor_failures(anchor_errors, anchor_count=len(anchors))
        return 1

    # Hashing is deliberately completed before the temporary file is created.
    # A malformed source string, unreadable file, or path error cannot mutate
    # even the baseline directory, much less the accepted baseline itself.
    state = build_state(pairs, repo_root)
    content = json.dumps(state, indent=2, sort_keys=True) + "\n"
    baseline_relative_path = rel(baseline_path, repo_root)
    _atomic_write_text(baseline_path, content)
    print(f"✅ baseline updated: {len(state)} tracked pairs -> {baseline_relative_path}")
    return 0


def cmd_list(
    *,
    ios_root: Path = IOS_CORE,
    macos_root: Path = MACOS_SOURCES,
    repo_root: Path = REPO_ROOT,
) -> int:
    _, _, pairs = _discover_sources(ios_root, macos_root)
    state = build_state(pairs, repo_root)
    print(f"Tracked protocol-parity pairs ({len(state)}):")
    for name, pair_state in state.items():
        tag = " [KNOWN-FORKED]" if pair_state["forked"] else ""
        print(
            f"  {name}{tag}\n"
            f"      ios:   {pair_state['ios']}\n"
            f"      macos: {pair_state['macos']}"
        )
    print(f"\nExempt (platform-specific, untracked): {', '.join(sorted(EXEMPT))}")
    return 0


_BASELINE_ENTRY_KEYS = {"ios", "macos", "ios_hash", "macos_hash", "forked"}
_SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")


def _reject_duplicate_json_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    decoded: dict[str, object] = {}
    for key, value in pairs:
        if key in decoded:
            raise ProtocolParityError(f"duplicate JSON key in protocol-parity baseline: {key!r}")
        decoded[key] = value
    return decoded


def _load_baseline(path: Path) -> ParityState:
    if not path.is_file() or path.is_symlink():
        raise ProtocolParityError(f"baseline must be a regular, non-symlink file: {path}")
    try:
        decoded = json.loads(
            _read_utf8(path, purpose="protocol-parity baseline"),
            object_pairs_hook=_reject_duplicate_json_keys,
        )
    except json.JSONDecodeError as exc:
        raise ProtocolParityError(f"invalid JSON baseline {path}: {exc}") from exc
    if not isinstance(decoded, dict):
        raise ProtocolParityError(f"baseline root must be an object: {path}")

    validated: ParityState = {}
    for name, entry in decoded.items():
        if not isinstance(name, str) or not name.endswith(".swift"):
            raise ProtocolParityError(f"invalid baseline pair name: {name!r}")
        if not isinstance(entry, dict) or set(entry) != _BASELINE_ENTRY_KEYS:
            raise ProtocolParityError(
                f"baseline entry '{name}' must contain exactly {sorted(_BASELINE_ENTRY_KEYS)}"
            )
        for side in ("ios", "macos"):
            source_path = entry[side]
            if not isinstance(source_path, str):
                raise ProtocolParityError(f"baseline entry '{name}.{side}' must be a string")
            parsed = Path(source_path)
            if parsed.is_absolute() or ".." in parsed.parts or parsed.name != name:
                raise ProtocolParityError(f"unsafe or inconsistent baseline path '{name}.{side}': {source_path!r}")
            source_hash = entry[f"{side}_hash"]
            if not isinstance(source_hash, str) or _SHA256_RE.fullmatch(source_hash) is None:
                raise ProtocolParityError(f"baseline entry '{name}.{side}_hash' is not a lowercase SHA-256")
        if type(entry["forked"]) is not bool:
            raise ProtocolParityError(f"baseline entry '{name}.forked' must be a boolean")
        validated[name] = {
            "ios": entry["ios"],
            "macos": entry["macos"],
            "ios_hash": entry["ios_hash"],
            "macos_hash": entry["macos_hash"],
            "forked": entry["forked"],
        }
    return validated


def cmd_check(
    *,
    ios_root: Path = IOS_CORE,
    macos_root: Path = MACOS_SOURCES,
    baseline_path: Path = BASELINE_PATH,
    repo_root: Path = REPO_ROOT,
    anchors: tuple[Anchor, ...] | list[Anchor] = WIRE_ANCHORS,
) -> int:
    ios, macos, pairs = _discover_sources(ios_root, macos_root)
    failures = [f"[wire-anchor] {error}" for error in check_wire_anchors(ios, macos, anchors)]
    baseline = _load_baseline(baseline_path)
    current = build_state(pairs, repo_root)

    new_pairs = sorted(set(current) - set(baseline))
    removed = sorted(set(baseline) - set(current))
    for name in new_pairs:
        failures.append(
            f"[new] tracked pair '{name}' is not in the baseline — "
            "review wire-compat then --update-baseline"
        )
    for name in removed:
        failures.append(f"[removed] baselined pair '{name}' no longer found — --update-baseline if intentional")

    for name in sorted(set(current) & set(baseline)):
        current_entry, baseline_entry = current[name], baseline[name]
        for key in ("ios", "macos", "forked"):
            if current_entry[key] != baseline_entry[key]:
                failures.append(
                    f"[structure] {name} baseline {key}={baseline_entry[key]!r}, current={current_entry[key]!r}"
                )
        for side in ("ios", "macos"):
            if current_entry[f"{side}_hash"] != baseline_entry[f"{side}_hash"]:
                failures.append(
                    f"[drift] {name} ({side}) changed since baseline: {current_entry[side]}\n"
                    f"          → re-verify the {('macos' if side == 'ios' else 'ios')} counterpart "
                    "stays wire-compatible, then run --update-baseline"
                )

    if failures:
        print("❌ protocol-parity check FAILED:\n", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        print(f"\n  Tracked pairs: {len(current)} | anchors checked: {len(anchors)}", file=sys.stderr)
        return 1

    print(f"✅ protocol-parity OK — {len(current)} tracked pairs match baseline; wire anchors consistent.")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="iOS<->macOS protocol-parity drift checker")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument(
        "--update-baseline",
        action="store_true",
        help="record current normalized hashes as the accepted baseline",
    )
    mode.add_argument("--list", action="store_true", help="list tracked pairs and exemptions")
    args = ap.parse_args(argv)

    try:
        if args.update_baseline:
            return cmd_update()
        if args.list:
            return cmd_list()
        return cmd_check()
    except ProtocolParityError as exc:
        print(f"❌ protocol-parity structural error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
