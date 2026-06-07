# ADR-0001: SkyBridge Core Transport Matrix

**Status:** Proposed for implementation  
**Date:** 2026-06-07  
**Scope:** SkyBridge Core, macOS, iOS, Windows, cross-platform P2P/WebRTC interop  
**Related areas:** P2P discovery, transport selection, WebRTC, Windows native networking, Apple Network.framework, PQC, trust/pairing, traffic padding, session audit

---

## 1. Decision Summary

SkyBridge should not be architected as a WebRTC application with platform UIs around it. SkyBridge should be treated as a self-owned secure collaboration protocol stack.

The platform-specific best practices are:

| Peer Pair | Default Best Practice | Role of WebRTC |
|---|---|---|
| Apple ↔ Apple | Apple native path: Network.framework, Bonjour, peer-to-peer where available, QUIC/UDP primary, TCP fallback | Fallback only, not default |
| Windows ↔ Windows | Windows native path: Windows DNS-SD/mDNS discovery, MsQuic transport, Windows crypto/provider integration, ETW/EventSource diagnostics | Cross-NAT fallback and interop option |
| Apple ↔ Windows | SkyBridge interop path: WebRTC DataChannel + ICE/STUN/TURN, or future SkyBridge native QUIC interop | Primary practical interop path for MVP |

All paths must run above a shared SkyBridge Core overlay layer:

- device identity
- pairing ceremony
- trust pinning
- PQC/classic suite negotiation
- downgrade policy and audit
- session transcript
- logical channel semantics
- traffic padding
- path scoring
- transport selection
- relay policy
- telemetry and benchmarking

WebRTC, MsQuic, and Network.framework are transport adapters. They must not define SkyBridge security semantics.

---

## 2. Why This ADR Exists

The current macOS/iOS implementation is relatively mature and already contains several core concepts that should be preserved:

- `_skybridge._udp` as QUIC/UDP-oriented primary discovery target
- `_skybridge._tcp` as fallback discovery target
- Bonjour / Network.framework discovery
- peer-to-peer capability through Network.framework parameters
- `HandshakeDriver` as a transport-independent protocol engine
- `CryptoProvider` as a provider-neutral crypto abstraction
- `CryptoSuite` wire IDs for hybrid PQC, pure PQC, and classic modes
- `TrafficPadding` / SBP2 as traffic-analysis mitigation

The Windows implementation should not merely add WebRTC to reach Apple devices. Windows also requires its own native high-performance path. The architecture must therefore distinguish:

```text
Apple ↔ Apple       = Apple native best practice
Windows ↔ Windows   = Windows native best practice
Apple ↔ Windows     = SkyBridge interop best practice
All combinations    = SkyBridge Core protocol and security model
```

---

## 3. Architectural Principle

SkyBridge Core owns the protocol. Platforms own their native network primitives.

```text
┌──────────────────────────────────────────────┐
│ Platform UX                                  │
│ macOS/iOS: SwiftUI / AppKit / UIKit          │
│ Windows: WinUI 3 / .NET 10                   │
└──────────────────────────────────────────────┘
                    │
┌──────────────────────────────────────────────┐
│ SkyBridge Core Overlay                       │
│ identity / pairing / trust / handshake       │
│ suite negotiation / audit / traffic padding  │
│ logical channels / session migration         │
│ capability policy / routing                  │
└──────────────────────────────────────────────┘
                    │
┌──────────────────────────────────────────────┐
│ Transport Adapters                           │
│ AppleNativeTransport                         │
│ WindowsNativeMsQuicTransport                 │
│ WebRTCInteropTransport                       │
│ RelayTransport                               │
└──────────────────────────────────────────────┘
                    │
┌──────────────────────────────────────────────┐
│ Platform Network Primitives                  │
│ Apple: Network.framework / Bonjour / AWDL    │
│ Windows: DNS-SD / MsQuic / CNG / ETW         │
│ Interop: ICE / STUN / TURN / WSS signaling   │
└──────────────────────────────────────────────┘
```

The important rule is that the same SkyBridge handshake, identity model, channel model, traffic padding, and audit policy must run above every transport.

---

## 4. Transport Matrix

### 4.1 Apple ↔ Apple

Default path:

```text
Discovery:   Bonjour / Network.framework
Transport:   AppleNativeTransport
Primary:     _skybridge._udp
Fallback:    _skybridge._tcp
Crypto:      CryptoKit / Apple PQC where available; existing fallback policy otherwise
Identity:    SkyBridge trust record + Apple platform-specific key handling
```

Requirements:

- Do not replace Apple ↔ Apple with WebRTC by default.
- Preserve Network.framework peer-to-peer behavior where available.
- Preserve current macOS/iOS QR, pairing, trust, and P2P behavior unless explicitly refactored into shared Core abstractions.
- Keep Apple-specific optimizations behind `AppleNativeTransport`.

### 4.2 Windows ↔ Windows

Default path:

```text
Discovery:   Windows DNS-SD / mDNS
Transport:   WindowsNativeMsQuicTransport
Primary:     MsQuic connection using ALPN skybridge-sbq/1
Fallback:    WebRTCInteropTransport for cross-NAT MVP, RelayTransport when necessary
Crypto:      Windows native provider where available; Rust/OpenSSL/liboqs provider fallback
Identity:    SkyBridge trust record + Windows secure storage / TPM / Windows Hello where available
Diagnostics: ETW / EventSource / structured logs
```

Windows ↔ Windows must not default to WebRTC on local or controllable networks. WebRTC is useful for NAT traversal and interoperability, but it is not the Windows native high-performance path.

### 4.3 Apple ↔ Windows

Default MVP path:

```text
Discovery local:       DNS-SD / Bonjour-compatible records
Discovery remote:      QR / connection code / account device chain / signaling
Connectivity:          WebRTC ICE + STUN/TURN
Data transport:         WebRTC DataChannel
Security semantics:     SkyBridge handshake above DataChannel
Fallback:               RelayTransport
```

Future path:

```text
SkyBridge native QUIC interop
    candidate gathering
    path scoring
    selected UDP path
    QUIC transport
    relay fallback
```

WebRTC should remain an adapter, not the owner of session identity or encryption policy.

---

## 5. Transport Selection Policy

Transport selection must be capability/path/policy driven, not hardcoded only by platform.

Inputs:

- local platform
- peer platform
- local capabilities
- peer capabilities
- local network path
- remote candidate path
- user policy
- security policy
- historical metrics
- relay availability

Output:

- selected transport
- selected crypto suite
- selected relay policy
- selected channel profile
- audit reason

Recommended selector:

```swift
func selectTransport(local: PeerCaps, remote: PeerCaps, path: NetworkPath) -> TransportPlan {
    if local.isApple && remote.isApple && remote.supports("apple-native") {
        return .appleNative(priority: 100)
    }

    if local.isWindows && remote.isWindows && path.isLocal && remote.supports("msquic") {
        return .windowsNativeMsQuic(priority: 100)
    }

    if local.isWindows && remote.isWindows && remote.supports("skybridge-ice-msquic") {
        return .skyBridgeIceMsQuic(priority: 90)
    }

    if remote.supports("webrtc-dc") {
        return .webRTCDataChannel(priority: 70)
    }

    if remote.supports("tcp-fallback") && path.isLocal {
        return .tcpFallback(priority: 40)
    }

    return .unsupported(reason: "No compatible transport")
}
```

Priority table:

| Pair | Same LAN | Cross NAT | Default Priority |
|---|---:|---:|---|
| macOS ↔ iOS | Yes | Weak/no | AppleNativeTransport |
| macOS ↔ macOS | Yes | Weak/no | AppleNativeTransport |
| iOS ↔ iOS | Yes | Weak/no | AppleNativeTransport |
| Windows ↔ Windows | Yes | No | WindowsNativeMsQuicTransport |
| Windows ↔ Windows | No | Yes | MVP: WebRTCInteropTransport; future: SkyBridgeIceMsQuicTransport |
| Windows ↔ macOS/iOS | Yes | Optional | WebRTCInteropTransport or future native QUIC interop |
| Windows ↔ macOS/iOS | No | Yes | WebRTCInteropTransport + TURN fallback |

---

## 6. SkyBridgeTransport Interface

Every transport adapter must expose the same logical interface.

```swift
public enum SkyBridgeTransportKind: String, Sendable {
    case appleNative
    case windowsNativeMsQuic
    case webRTCDataChannel
    case relay
    case tcpFallback
}

public enum SkyBridgeReliability: Sendable {
    case reliableOrdered
    case reliableUnordered
    case partialReliable(maxRetransmits: UInt16)
    case unreliable
}

public protocol SkyBridgeTransport: Sendable {
    var kind: SkyBridgeTransportKind { get }
    var localPeerId: PeerIdentifier { get }
    var remotePeerId: PeerIdentifier { get }

    func send(channel: SkyBridgeChannelId,
              reliability: SkyBridgeReliability,
              frame: Data) async throws

    func receive() async throws -> SkyBridgeTransportFrame
    func close() async
    func metricsSnapshot() async -> SkyBridgeTransportMetrics
    func bindingMaterial() async throws -> SkyBridgeTransportBinding
}
```

The existing `DiscoveryTransport` abstraction used by `HandshakeDriver` should be retained conceptually, but it should be expanded or wrapped so that all transports can provide channel, metrics, and binding material.

---

## 7. Transport Binding

SkyBridge Core must bind the selected transport into the session transcript.

```text
transport_binding = hash(
    transport_kind,
    local_endpoint,
    remote_endpoint,
    selected_candidate_pair,
    dtls_fingerprint if WebRTC,
    quic_tls_exporter if MsQuic,
    relay_id if relay,
    timestamp_window,
    capability_digest
)
```

Purpose:

- prevent silent relay insertion
- prevent transport replacement
- prevent candidate downgrade ambiguity
- bind WebRTC DTLS context to SkyBridge identity
- bind MsQuic/TLS context to SkyBridge identity
- make transport downgrade auditable

This binding must enter the SkyBridge handshake transcript before session keys are finalized.

---

## 8. Logical Channel Model

SkyBridge channels are Core-level semantics. Transport adapters only map them to native primitives.

| SkyBridge Channel | Semantics | Apple Native Mapping | Windows Native Mapping | WebRTC Mapping |
|---|---|---|---|---|
| control | reliable, ordered, low latency | QUIC/TCP stream | MsQuic stream | reliable ordered DataChannel |
| file | reliable, chunked, backpressure-aware | QUIC/TCP stream | MsQuic stream | separate reliable DataChannel |
| clipboard | reliable, ordered, small payload | reliable stream | MsQuic stream | reliable DataChannel |
| telemetry | unordered or partial reliable | UDP/QUIC datagram | QUIC datagram | unordered DataChannel |
| realtime | unordered / partial reliable / datagram | QUIC datagram or platform media | QUIC datagram or future media path | unordered/partial reliable DataChannel or media track |

Do not put all traffic into a single reliable ordered stream. That causes head-of-line blocking and prevents channel-specific scheduling.

---

## 9. Crypto Provider Policy

SkyBridge wire protocol owns suite identity. Platform crypto providers are implementation details.

Existing suite IDs remain canonical:

| Suite ID | Meaning |
|---:|---|
| `0x0001` | X-Wing / hybrid PQC group |
| `0x0101` | ML-KEM-768 + ML-DSA-65 / pure PQC group |
| `0x1001` | X25519 + Ed25519 / classic group |
| `0x1002` | P-256 + ECDSA / legacy group |

Windows provider order:

```text
1. Windows native CNG / .NET 10 PQC where available
2. OpenSSL provider where available
3. liboqs provider for compatibility/prototype/research fallback
4. classic X25519/Ed25519 fallback with explicit audit
```

Apple provider order:

```text
1. CryptoKit / Apple native PQC where available
2. existing liboqs/OQSRAII fallback where configured
3. classic X25519/Ed25519 fallback with explicit audit
```

Rules:

- Timeout must never cause crypto downgrade.
- Classic fallback must be policy-gated.
- Any downgrade must emit a security event.
- Offered suites must be derived from actual provider support, not static wish lists.
- Unknown suite IDs must be rejected safely, not crash the session.

---

## 10. Traffic Padding / SBP2

SBP2 is a SkyBridge Core feature and must exist on Windows as well as Apple platforms.

Wire shape:

```text
magic       4B  "SBP2"
actual_len  u32be
payload     bytes
padding     random bytes
```

Modes:

- bucketed
- fixed

Requirements:

- Apply to selected control/framed payloads after handshake policy decides it is enabled.
- Unwrap before decode/decrypt where appropriate.
- Record padding statistics for benchmarking and audit.
- Keep format identical across Swift and Rust implementations.

---

## 11. Windows Architecture

Recommended layout:

```text
windows/
  SkyBridge.Compass.WinUI/
    // WinUI 3 / .NET 10 app shell

  native/
    skybridge-core-rs/
      crates/
        skybridge-protocol/
        skybridge-transport-msquic/
        skybridge-transport-webrtc/
        skybridge-discovery-windows/
        skybridge-crypto-windows/
        skybridge-routing/
        skybridge-ffi/
```

Boundary:

```text
C# / WinUI:
    UI
    settings
    notifications
    Windows shell integration
    account/login presentation
    diagnostics presentation

Rust core:
    protocol framing
    handshake
    transport adapters
    crypto provider glue
    DNS-SD discovery
    path scoring
    relay/WebRTC integration
    SBP2
    audit events
```

C# should call a narrow native API:

```csharp
SkyBridgeNative.StartDiscovery()
SkyBridgeNative.StopDiscovery()
SkyBridgeNative.ConnectPeer(peerId)
SkyBridgeNative.ConnectWithCode(code)
SkyBridgeNative.SendControl(...)
SkyBridgeNative.SendFile(...)
SkyBridgeNative.SubscribeEvents(...)
```

The Windows UI must not own P2P protocol state.

---

## 12. macOS/iOS Refactor Scope

The mature macOS/iOS path should be modified only to clarify boundaries and prepare for multi-transport selection.

Expected changes:

1. Introduce or formalize `SkyBridgeTransport`.
2. Wrap current Network.framework P2P path as `AppleNativeTransport`.
3. Keep existing Bonjour service names and TXT fields compatible.
4. Move transport selection out of UI/app manager classes.
5. Keep `HandshakeDriver` transport independent.
6. Add `TransportBinding` into handshake transcript.
7. Keep SBP2 behavior wire-compatible.
8. Add regression tests proving Apple ↔ Apple still selects Apple-native by default.

Avoid:

- replacing Apple ↔ Apple with WebRTC
- moving Apple-specific discovery behavior into generic WebRTC code
- weakening current trust/pairing behavior for cross-platform convenience
- changing suite IDs
- changing SBP2 framing

---

## 13. WebRTC Interop Scope

WebRTC is required, but only as an adapter.

MVP uses:

```text
WebRTC DataChannel + ICE + STUN/TURN
```

Recommended implementation:

- native Rust wrapper around libdatachannel or equivalent native WebRTC data-channel stack
- signaling via WSS
- short-lived TURN credentials
- trickle ICE
- relay fallback
- separate DataChannels per SkyBridge logical channel

DataChannel mapping:

| SkyBridge Channel | DataChannel Config |
|---|---|
| control | reliable + ordered |
| file | reliable, separate channel, chunked |
| clipboard | reliable + ordered |
| telemetry | unordered |
| realtime | unordered or partial reliable |

WebRTC DTLS is transport encryption only. SkyBridge handshake still defines device identity, session keys, downgrade rules, and audit semantics above the DataChannel.

---

## 14. TURN and Signaling

Production requirements:

- No hardcoded TURN username/password in client code.
- Use short-lived TURN credentials.
- Signaling server exchanges offer/answer/ICE only.
- Signaling server must not hold SkyBridge session keys.
- TURN relay usage must be visible in transport metrics and audit events.

Minimal signaling messages:

```json
{
  "type": "rtc.offer",
  "session_id": "...",
  "from": "...",
  "to": "...",
  "sdp": "...",
  "capabilities": {
    "platform": "windows",
    "transports": ["webrtc-dc", "msquic"],
    "suites": [1, 257, 4097]
  }
}
```

```json
{
  "type": "rtc.candidate",
  "session_id": "...",
  "candidate": "...",
  "sdp_mid": "...",
  "sdp_mline_index": 0
}
```

---

## 15. Implementation Phases

### Phase 0: Freeze Apple Regression Baseline

- Add tests proving macOS/iOS still use AppleNativeTransport by default.
- Add tests for existing Bonjour service names.
- Add tests for handshake suite selection.
- Add SBP2 cross-platform test vectors.

### Phase 1: Core Abstractions

- Add `SkyBridgeTransport`.
- Add `SkyBridgeChannel` and `SkyBridgeTransportFrame`.
- Add `TransportSelector`.
- Add `SkyBridgeTransportBinding`.
- Wrap current Apple implementation as `AppleNativeTransport`.

### Phase 2: Windows Native MVP

- Create Windows WinUI app shell.
- Create Rust native core workspace.
- Implement Windows DNS-SD discovery.
- Implement MsQuic local Windows ↔ Windows transport.
- Implement basic C# ↔ Rust FFI.
- Implement Windows provider discovery for crypto support.

### Phase 3: WebRTC Interop MVP

- Implement WSS signaling.
- Implement short-lived TURN credentials.
- Implement WebRTC DataChannel transport adapter.
- Validate Windows ↔ macOS.
- Validate Windows ↔ iOS.
- Validate Windows ↔ Windows cross-NAT fallback.

### Phase 4: Core Routing and Path Scoring

- Add path candidates.
- Add candidate race / happy-eyeballs style selection.
- Add path metrics.
- Add relay policy.
- Add transport downgrade audit.

### Phase 5: Advanced SkyBridge Native Interop

- Research SkyBridge ICE + MsQuic path for Windows ↔ Windows cross-NAT.
- Research native QUIC interop for Apple ↔ Windows beyond WebRTC.
- Keep WebRTC as fallback adapter.

---

## 16. Tests and Acceptance Criteria

Required tests:

| Area | Test |
|---|---|
| Apple regression | Apple ↔ Apple selects AppleNativeTransport |
| Windows native | Windows ↔ Windows same LAN selects WindowsNativeMsQuicTransport |
| Interop | Windows ↔ Apple selects WebRTCInteropTransport |
| Fallback | TURN relay use emits audit/metrics |
| Security | timeout does not trigger crypto downgrade |
| Suite negotiation | offered suites come from provider support |
| Forward compatibility | unknown suite ID is rejected safely |
| SBP2 | Swift and Rust SBP2 test vectors match |
| Channel mapping | control/file/telemetry map to distinct transport channels |
| Transport binding | transcript changes if selected transport changes |

Acceptance criteria:

- Mac/iOS behavior is not degraded by Windows changes.
- Windows has a native same-LAN path independent of WebRTC.
- WebRTC is present for interop and NAT traversal.
- All transports run the same SkyBridge handshake and policy model.
- Transport selection is explainable in logs and test assertions.
- No production credential is hardcoded in the client.

---

## 17. Non-Goals

This ADR does not decide:

- final Windows UI layout
- exact Rust crate versions
- final TURN hosting vendor
- final account/device-cloud model
- complete screen/video codec architecture
- replacement of current Apple discovery implementation

This ADR does decide:

- WebRTC is not the architectural center.
- Windows ↔ Windows needs a native path.
- Apple ↔ Apple keeps Apple native best practice.
- SkyBridge Core owns protocol/security/channel semantics.
- All transport adapters must be subordinate to SkyBridge Core.

---

## 18. Repository Impact

Likely files/directories to add:

```text
Docs/ADR-0001-SkyBridge-Core-Transport-Matrix.md
Sources/SkyBridgeCore/Transport/
Sources/SkyBridgeCore/CoreProtocol/
Sources/SkyBridgeCore/Routing/
windows/SkyBridge.Compass.WinUI/
windows/native/skybridge-core-rs/
```

Likely files/directories to refactor:

```text
Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift
Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift
Sources/SkyBridgeCore/P2P/P2PDeviceDiscovery.swift
Sources/SkyBridgeCore/P2P/HandshakeDriver.swift
Sources/SkyBridgeCore/P2P/CryptoProviderProtocol.swift
Sources/SkyBridgeCore/P2P/TrafficPadding.swift
Sources/SkyBridgeCore/Config/ServerConfig.swift
```

Special note:

`CrossNetworkConnectionManager` currently mixes QR, connection code, iCloud path, STUN probing, and NWConnection construction. It should be split into signaling, discovery, transport selection, and transport adapter responsibilities before Windows work grows further.

---

## 19. Final Decision Statement

SkyBridge should evolve into a self-owned secure collaboration overlay protocol.

Apple ↔ Apple should keep Apple-native best practices. Windows ↔ Windows should use Windows-native best practices. Apple ↔ Windows should use WebRTC/ICE as the practical interop path for MVP. All combinations must share SkyBridge Core identity, handshake, PQC/classic negotiation, channel semantics, padding, audit, and transport selection.

This is the architecture that prevents Windows support from weakening the mature macOS/iOS path while still allowing Windows to become a first-class, high-performance platform.
