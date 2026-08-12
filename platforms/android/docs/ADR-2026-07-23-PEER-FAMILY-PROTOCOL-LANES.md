# ADR 2026-07-23: Peer-family protocol lanes and Apple ownership

Status: accepted. This ADR governs Android discovery, connection, transfer, and remote-control interoperability.

## Context

SkyBridge already has mature iOS/macOS protocol behavior and an Apple-to-Apple optimized lane. Apple development is concurrent and owned outside this Android repository. Android must interoperate without changing Apple source or inventing a second cross-platform contract. Same-family peers may still use a faster native lane when both endpoints explicitly qualify.

## Decision

1. macOS/iOS source trees are read-only references for Android work. Android tasks must not edit, patch, format, generate into, or commit Apple files or project state.
2. For Android-to-iOS/macOS, current Apple-observed discovery fields, message encodings, state transitions, error behavior, identity binding, handshake, rekey, signaling, file-transfer, and remote-control semantics are canonical. Compatibility changes are implemented only in Android.
3. Android keeps compatibility fixtures and directional tests. Results must name initiator, responder, device class, OS/API, transport, negotiated suite, and whether TURN relayed the session.
4. Shared semantics remain stable across every lane: peer identity, trust, authorization, capability meaning, session lifecycle, integrity, cancellation, audit, and fail-closed security.
5. Transport and framing may be optimized by authenticated peer family:
   - Apple↔Apple: existing Apple-native lane; Android does not reimplement or modify it.
   - Android↔Android: Android Direct lane, selected only after both authenticated peers identify as Android and both opt in.
   - Android↔Apple: Apple-compatible cross-platform lane only.
   - Windows/Linux: start on the Apple-compatible cross-platform lane; a same-family fast lane requires its own accepted ADR and benchmarks.
6. Android Direct is a private extension inside an established authenticated session. It must not add mandatory TXT fields, public signaling fields, suite IDs, or pre-auth messages that Apple must understand. Unknown/missing private capability means use the cross-platform lane.
7. Fast-lane selection is explicit and authenticated; timeout, platform-name guessing, parsing failure, or network failure must never trigger a silent protocol downgrade or lane switch.
8. Android Direct may optimize discovery reuse, local transport, chunk sizing, parallelism, zero-copy I/O, resume checkpoints, and media capture. It must reuse shared identity/session security and produce equivalent user-visible state and audit events.
9. A proposed Android Direct transport is not accepted merely because it is Android-specific. WebRTC DataChannel, direct encrypted TCP, Wi-Fi Direct/Aware, and QUIC candidates must be measured for throughput, latency, power, OEM availability, reconnect behavior, and relay avoidance before one becomes normative.

## Implementation order

1. Close Android↔iOS/macOS DNS-SD discovery in both directions without Apple edits.
2. Close authenticated signaling, ICE, DataChannel, rekey, disconnect, and reconnect state parity.
3. Close WebRTC file transfer, approval, integrity, cancellation, resume, and SAF/Downloads persistence.
4. Add Android remote-host viewing with user-approved MediaProjection and a visible foreground service.
5. Add explicitly enabled AccessibilityService input with local stop, sensitive-surface restrictions, replay protection, and immediate disconnect cleanup.
6. Benchmark and specify Android Direct v1 for Android↔Android; keep the Apple-compatible path as mandatory fallback and conformance baseline.

## Consequences

Android follows Apple compatibility state without creating work in the Apple tree. Platform-native performance remains possible, but it cannot fracture identity, security, or product state semantics. `CrossPlatformDiscoveryDesign.md` is historical where it requires one universal framing/transport or contradicts this ADR and the 2026 P2P ADR.