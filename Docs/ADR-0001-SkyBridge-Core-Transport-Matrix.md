# ADR-0001: SkyBridge Core Transport Matrix

**Status:** Proposed for implementation  
**ADR Version:** 1.0  
**Date:** 2026-06-07  
**Scope:** SkyBridge Core, macOS, iOS, Windows, Android, Linux, cross-platform P2P/WebRTC interop, branch hygiene, stale-paper boundary  
**Related areas:** P2P discovery, transport selection, WebRTC, Windows native networking, Android Kotlin stack, Android Wi-Fi Aware/NSD, Linux Rust core, Linux Avahi/DNS-SD, Apple Network.framework, QUIC, PQC, trust/pairing, traffic padding, session audit, signaling/TURN deployment

---

## 1. Decision Summary

SkyBridge should not be architected as a WebRTC application with platform UIs around it. SkyBridge should be treated as a self-owned secure collaboration protocol stack.

The platform-specific best practices are:

| Peer Pair | Default Best Practice | Role of WebRTC |
|---|---|---|
| Apple ↔ Apple | Apple native path: Network.framework, Bonjour, peer-to-peer where available, QUIC/UDP primary, TCP fallback | Fallback only, not default |
| Windows ↔ Windows | Windows native path: Windows DNS-SD/mDNS discovery, MsQuic transport, Rust core, Windows crypto/provider integration, ETW/EventSource diagnostics | Cross-NAT fallback and interop option |
| Android ↔ Android | Android native path: Kotlin app layer, Rust core, Wi-Fi Aware when available, Android NSD/DNS-SD on LAN, QUIC over selected Android `Network` | Cross-NAT fallback and interop option |
| Linux ↔ Linux | Linux native path: Rust core, Avahi DNS-SD/mDNS discovery, Rust-native QUIC or MsQuic provider, systemd/journal diagnostics | Cross-NAT fallback and interop option |
| Windows ↔ Linux | SkyBridge native QUIC interop over compatible ALPN/cipher policy | Fallback if native QUIC path fails |
| Android ↔ Windows/Linux | SkyBridge native QUIC interop when Android network binding succeeds | Fallback if native QUIC path fails |
| Apple ↔ Windows/Android/Linux | SkyBridge interop path: WebRTC DataChannel + ICE/STUN/TURN for MVP; future SkyBridge native QUIC interop where both sides support it | Primary practical MVP interop path |

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

WebRTC, MsQuic, Quinn, Android Wi-Fi Aware, Android NSD, Avahi, DNS-SD, and Network.framework are transport or discovery adapters. They must not define SkyBridge security semantics.

---

## 2. Authority Boundary: README, Code, and Stale Paper Materials

This ADR does **not** use the current paper draft as an architectural source of truth.

The paper material in this branch is known to be stale and may lag behind the current engineering direction. It should be treated as historical/reviewer-facing material awaiting a dedicated paper refresh pass, not as the technical authority for this ADR.

### 2.1 What This ADR May Rely On

This ADR may rely on:

- current source-code structure and implementation boundaries
- current README operational constraints
- current server deployment contract and signaling/TURN notes
- current build constraints for the implemented Apple path
- explicit architecture decisions made for Windows, Android, and Linux in this ADR

### 2.2 What This ADR Must Not Rely On

This ADR must not rely on:

- stale paper claims
- stale PDF contents
- stale supplementary text
- old artifact truth tags as architectural evidence
- generated paper tables or figures as proof that a new platform is implemented
- benchmark numbers from the paper to justify Windows/Android/Linux design choices

The paper can later be updated to reflect the architecture after implementation and validation. The paper should follow the architecture and verified artifacts; the architecture should not be constrained by stale paper text.

### 2.3 Current Implemented Build Scope

The current repository build entry is macOS. The core protocol layer contains iOS-specific code paths guarded by `#if os(iOS)` and `@available(iOS ...)`, but Windows, Android, and Linux are architectural targets rather than current implemented build targets.

Required wording discipline:

```text
Current implemented build entry: macOS
Current portable code paths: iOS/macOS inside SkyBridgeCore
Architecture targets in this ADR: Windows, Android, Linux
Do not present Windows/Android/Linux as already included in the current build or artifact until implemented, tested, and documented separately.
```

The current README lists the practical build environment as:

```text
macOS 14+
Apple Silicon arm64 Mac
Xcode 26.2+
Swift 6.2+
```

Because the vendored XCFrameworks are arm64-only, Intel x86_64 Macs are out of scope for the current Apple build.

### 2.4 Apple PQC Compile-Time Gate

Apple CryptoKit PQC paths for ML-KEM, ML-DSA, and X-Wing require compile-time enablement through `HAS_APPLE_PQC_SDK`. The repository uses `SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1` to enable that condition for Xcode/SDK 26+ release/distribution builds.

Architecture changes must preserve this rule:

```text
No automatic Apple PQC enablement under old SDKs.
No Windows/Android/Linux provider selection should change Apple compile-time gating.
Scripts/build_with_widgets.sh and run_app.sh remain responsible for SDK detection on Apple builds.
```

### 2.5 Paper Refresh Is A Separate Workstream

If the paper is later brought up to date, it must be handled as a separate documentation/artifact workstream.

A future paper refresh should:

- state which platforms are implemented and benchmarked
- keep macOS/iOS claims separate from future Windows/Android/Linux claims unless those platforms are implemented and measured
- keep CSVs date-locked and platform-labeled
- regenerate tables and figures only from verified CSVs
- avoid mixing direct, relay, overlay, IPv6, and CGNAT-blocked paths
- update README, paper, supplementary, checksums, and reproducibility commands together if a new artifact tag is created

This ADR should not silently edit or reinterpret the paper.

### 2.6 Reproducibility and Date-Lock Discipline

Even though this ADR does not rely on the stale paper, the branch still contains reproducibility infrastructure that must not be damaged by architecture work.

Rules:

- `ARTIFACT_DATE` should remain explicit when regenerating tables or supplementary artifacts.
- `SKYBRIDGE_BENCH_BATCHES` means independent process batches, not per-test iterations.
- Repeatability tables should only report cross-batch 95% CI when observed batch count `B >= 2`.
- `Scripts/make_tables.py` date locking must not be bypassed by new platform work.
- Windows/Android/Linux benchmarks must use separate labels and must not contaminate Apple/macOS CSVs unless the artifact scope is intentionally expanded.

### 2.7 Real-Network Micro-Study Guardrails

Real-network validation rules remain useful engineering guardrails even if the paper text is stale.

Required interpretation:

- STUN probe scripts record network path state, whether a path is expensive/constrained, local UDP port, STUN-mapped endpoint, RTT distribution, and timeout/loss behavior.
- IPv4 port forwarding only works when the router WAN address is a reachable public IPv4 address.
- WAN addresses in `192.168.x.x`, `10.x.x.x`, or `100.64.0.0/10` usually indicate double NAT, CGNAT, or DS-Lite and should not be described as direct-reachable IPv4.
- IPv6 direct tests must note router IPv6 firewall requirements.
- Overlay/relay paths must be labeled explicitly as `via overlay/relay`; do not report them as direct P2P.
- Future Windows/Android/Linux real-network studies must use platform-specific labels and must not be merged into Apple-only CSVs without explicit scope expansion.

### 2.8 Signaling/TURN Deployment Contract

The README defines WebRTC + TURN as the zero-configuration cross-network path for ordinary users.

Current server contract:

```text
WSS signaling: 8443/tcp
STUN:          3478/udp, optionally 3478/tcp
TURN TLS:      5349/tcp
TURN relay:    49152-65535/udp
```

The branch also includes deployment assets under:

```text
Server/skybridge-signaling/deploy/README.md
Server/skybridge-signaling/production.env.example
Server/skybridge-signaling/deploy/scripts/deploy_remote.sh
Server/skybridge-signaling/deploy/scripts/rollback_remote.sh
Server/skybridge-signaling/deploy/scripts/smoke_local.sh
```

Deployment must enforce `/api/turn/credentials` route semantics to avoid configuration drift. Production clients must use short-lived TURN credentials and must not hardcode TURN username/password.

### 2.9 Repository Hygiene

Architecture work must preserve:

- no committed TURN secrets
- no committed private keys or certificates
- no committed generated DMGs except explicitly documented release artifacts
- no accidental inclusion of local `.env` production files
- no accidental mutation of stale paper PDFs or generated paper artifacts as a side effect of platform architecture work

---

## 3. Hard Platform Decisions

These are architectural constraints, not implementation suggestions:

1. **Linux Core is Rust.** Linux UI is replaceable; Linux protocol, transport, routing, crypto-provider glue, SBP2, and audit logic are Rust.
2. **Android application stack is Kotlin.** Android UI/service orchestration is Kotlin, preferably with Jetpack Compose for UI. SkyBridge protocol core is Rust and is exposed to Kotlin through JNI or UniFFI.
3. **Windows UI shell is WinUI 3 / Windows App SDK.** .NET 10 is appropriate for the app shell, settings, diagnostics, and selected Windows crypto access. The SkyBridge protocol core remains Rust.
4. **Apple keeps Swift/Network.framework.** Apple-native behavior must not be weakened for cross-platform convenience.
5. **WebRTC is not the architecture.** It is an interop and NAT-traversal adapter.
6. **The current paper is stale.** Do not use it as the architecture's source of truth.

---

## 4. Current Technology Baseline

This ADR uses a stable-first baseline. Preview and experimental APIs are allowed only behind feature flags.

| Platform | UI / Shell | Core | Native Discovery | Native Transport | Crypto Provider Baseline | Diagnostics |
|---|---|---|---|---|---|---|
| Apple | SwiftUI / AppKit / UIKit | Swift `SkyBridgeCore` | Bonjour / Network.framework | Network.framework QUIC/UDP primary, TCP fallback | CryptoKit / Secure Enclave / liboqs fallback as configured | OSLog / Instruments |
| Windows | WinUI 3 on Windows App SDK; .NET 10 app shell | Rust core via C ABI / PInvoke / generated bindings | Windows DNS-SD/mDNS | MsQuic 2.5+; ALPN `skybridge-sbq/1` | .NET 10/CNG PQC when supported; OpenSSL/liboqs/Rust provider fallback | ETW / EventSource / structured logs |
| Android | Kotlin + Jetpack Compose app shell | Rust core via JNI or UniFFI | Wi-Fi Aware; Android NSD/DNS-SD; Wi-Fi Direct only as compatibility fallback | Wi-Fi Aware data path + SkyBridge QUIC; LAN QUIC over selected Android `Network`; WebRTC for NAT/interop | Android Keystore for identity protection; Rust/liboqs/BouncyCastle provider for PQC until platform PQC APIs are available | logcat / Perfetto / structured events |
| Linux | Qt 6/QML default; GTK4/libadwaita optional GNOME build | Rust core | Avahi DNS-SD/mDNS via D-Bus; mDNSResponder optional fallback | Quinn/rustls QUIC default; MsQuic provider optional for parity/perf; ALPN `skybridge-sbq/1` | OpenSSL provider where available; liboqs/oqs-provider/Rust provider fallback; TPM2/FIDO2 optional identity binding | systemd journal / tracing / perf/eBPF optional |

Rationale:

- Windows App SDK and WinUI 3 are the modern Windows desktop direction. WinUI is the app shell; the SkyBridge core remains Rust.
- .NET 10 has platform-facing PQC APIs, but SkyBridge must keep provider abstraction because algorithm availability is system-dependent.
- MsQuic remains the Windows-native high-performance QUIC choice and is also useful on Linux where parity or throughput matters.
- Android is Kotlin at the application layer. Compose is the default UI choice; Rust owns protocol-critical code through JNI/UniFFI.
- Android's native peer-to-peer path is tiered: Wi-Fi Aware for nearby direct connectivity, NSD/DNS-SD for LAN discovery, WebRTC for NAT traversal and mixed-platform fallback.
- Linux is Rust-first. UI toolkit is not protocol architecture. Qt 6/QML is the broad desktop default; GTK4/libadwaita can be a GNOME-targeted build.
- Linux should use Avahi for native DNS-SD/mDNS and Quinn/rustls for Rust-native QUIC by default. MsQuic can remain an optional provider.

---

## 5. Architectural Principle

SkyBridge Core owns the protocol. Platforms own their native network primitives.

```text
+--------------------------------------------------------+
| Platform UX                                            |
| Apple:   SwiftUI / AppKit / UIKit                      |
| Windows: WinUI 3 / Windows App SDK / .NET 10           |
| Android: Kotlin / Jetpack Compose                      |
| Linux:   Qt 6/QML default; GTK4/libadwaita optional    |
+--------------------------------------------------------+
                         |
+--------------------------------------------------------+
| SkyBridge Core Overlay                                 |
| identity / pairing / trust / handshake                 |
| suite negotiation / audit / traffic padding            |
| logical channels / session migration                   |
| capability policy / path scoring / routing             |
+--------------------------------------------------------+
                         |
+--------------------------------------------------------+
| Transport Adapters                                     |
| AppleNativeTransport                                   |
| WindowsNativeMsQuicTransport                           |
| AndroidNativeAwareTransport                            |
| AndroidLanQuicTransport                                |
| LinuxNativeQuicTransport                               |
| SkyBridgeNativeQuicInteropTransport                    |
| WebRTCInteropTransport                                 |
| RelayTransport                                         |
| TcpFallbackTransport                                   |
+--------------------------------------------------------+
                         |
+--------------------------------------------------------+
| Platform Network Primitives                            |
| Apple:   Network.framework / Bonjour / AWDL            |
| Windows: DNS-SD / MsQuic / CNG / ETW                   |
| Android: Wi-Fi Aware / NSD / selected Network / JNI    |
| Linux:   Avahi / D-Bus / Quinn / MsQuic / systemd      |
| Interop: ICE / STUN / TURN / WSS signaling             |
+--------------------------------------------------------+
```

The same SkyBridge handshake, identity model, channel model, traffic padding, and audit policy must run above every transport.

---

## 6. Transport Matrix

### 6.1 Apple ↔ Apple

Default path:

```text
Discovery:   Bonjour / Network.framework
Transport:   AppleNativeTransport
Primary:     _skybridge._udp
Fallback:    _skybridge._tcp
Crypto:      CryptoKit / Apple PQC where available; existing fallback policy otherwise
Identity:    SkyBridge trust record + Apple platform-specific key handling
Diagnostics: OSLog / Instruments
```

Requirements:

- Do not replace Apple ↔ Apple with WebRTC by default.
- Preserve Network.framework peer-to-peer behavior where available.
- Preserve current macOS/iOS QR, pairing, trust, and P2P behavior unless explicitly refactored into shared Core abstractions.
- Keep Apple-specific optimizations behind `AppleNativeTransport`.

### 6.2 Windows ↔ Windows

Default path:

```text
Discovery:   Windows DNS-SD / mDNS
Transport:   WindowsNativeMsQuicTransport
Primary:     MsQuic connection using ALPN skybridge-sbq/1
Fallback:    WebRTCInteropTransport for cross-NAT MVP, RelayTransport when necessary
Crypto:      Windows native CNG / .NET 10 PQC where available; Rust/OpenSSL/liboqs provider fallback
Identity:    SkyBridge trust record + Windows secure storage / TPM / Windows Hello where available
Diagnostics: ETW / EventSource / structured logs
```

Windows ↔ Windows must not default to WebRTC on local or controllable networks. WebRTC is useful for NAT traversal and interoperability, but it is not the Windows native high-performance path.

Updated Windows rule:

```text
WinUI 3 / Windows App SDK = app shell
.NET 10                   = app shell, settings, diagnostics, selected Windows crypto access
Rust core                 = protocol, transport, crypto provider glue, routing, WebRTC/MsQuic adapters
MsQuic                    = native same-LAN and managed-network transport
```

### 6.3 Android ↔ Android

Default path:

```text
Application:      Kotlin + Jetpack Compose
Core:             Rust via JNI or UniFFI
Discovery tier 1: Android Wi-Fi Aware publish/subscribe when supported and available
Discovery tier 2: Android NSD / DNS-SD on LAN
Discovery tier 3: Wi-Fi Direct service discovery only as compatibility fallback
Transport tier 1: AndroidNativeAwareTransport using Wi-Fi Aware data path + SkyBridge QUIC
Transport tier 2: AndroidLanQuicTransport using DNS-SD endpoint + QUIC over selected Android Network
Transport tier 3: WebRTCInteropTransport for cross-NAT or restricted networks
Crypto:          Android Keystore for identity protection where compatible; Rust/liboqs/BouncyCastle provider for PQC
Diagnostics:     logcat / Perfetto / structured SkyBridge events
```

Android ↔ Android must not be treated as generic WebRTC by default. Android has a native nearby-device model, but it is capability-sensitive:

- Wi-Fi Aware is preferred for nearby direct discovery and data path when runtime checks pass.
- NSD/DNS-SD is preferred for normal LAN discovery.
- Wi-Fi Direct is kept as an explicit fallback because user authorization, group formation, and multi-group behavior complicate autonomous SkyBridge routing.
- Nearby Connections / Google Play services may be used only as optional pairing/bootstrap UX, not as the SkyBridge default transport owner.
- Kotlin owns UI, lifecycle, permissions, foreground services, notifications, and Android integration.
- Rust owns protocol framing, handshake, crypto-provider glue, SBP2, transport adapters, routing, and audit events.

### 6.4 Linux ↔ Linux

Default path:

```text
Application: Qt 6/QML default UI; GTK4/libadwaita optional GNOME UI
Core:        Rust
Discovery:   Avahi DNS-SD/mDNS over D-Bus
Transport:   LinuxNativeQuicTransport
Primary:     Quinn/rustls QUIC using ALPN skybridge-sbq/1
Optional:    MsQuic provider for throughput parity with Windows or controlled deployments
Fallback:    WebRTCInteropTransport for cross-NAT MVP, RelayTransport when necessary
Crypto:      OpenSSL provider where available; liboqs/oqs-provider/Rust provider fallback
Identity:    SkyBridge trust record + libsecret / kernel keyring / TPM2/FIDO2 where available
Diagnostics: systemd journal / tracing / perf / eBPF where appropriate
```

Linux ↔ Linux should use native Linux service discovery and a Rust-first QUIC stack. WebRTC should not be default on a local Linux network. Linux must remain desktop-environment neutral:

- Rust core is mandatory.
- Qt 6/QML is the default UI choice for broad Linux desktop coverage.
- GTK4/libadwaita is an optional GNOME-focused build target.
- Flatpak is the preferred GUI distribution target; distro packages are appropriate for daemon/system integration.
- Linux daemon/service mode should be possible without any GUI toolkit dependency.

### 6.5 Windows ↔ Linux

Default same-LAN path:

```text
Discovery:   Windows DNS-SD ↔ Avahi DNS-SD/mDNS
Transport:   SkyBridgeNativeQuicInteropTransport
Primary:     ALPN skybridge-sbq/1 over MsQuic/Quinn-compatible QUIC
Fallback:    WebRTCInteropTransport if QUIC path fails or NAT blocks UDP
```

Windows ↔ Linux can be more native than Windows ↔ Apple/Android because both sides can run the same SkyBridge QUIC framing with fewer platform policy constraints.

### 6.6 Android ↔ Windows/Linux

Default same-LAN path:

```text
Discovery:   Android NSD ↔ Windows DNS-SD / Linux Avahi
Transport:   SkyBridgeNativeQuicInteropTransport where Android can bind UDP to selected Network
Fallback:    WebRTCInteropTransport
```

Default nearby Android path is still Android-native for Android ↔ Android. Mixed Android ↔ desktop can use native QUIC if capability and network binding checks pass; otherwise use WebRTC.

### 6.7 Apple ↔ Windows/Android/Linux

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

## 7. Transport Selection Policy

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
- battery/power state on mobile platforms
- permissions and runtime availability
- current artifact scope if running reviewer/bench scripts

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

    if local.isAndroid && remote.isAndroid &&
       path.isNearby &&
       local.supports("wifi-aware") &&
       remote.supports("wifi-aware") {
        return .androidNativeAware(priority: 100)
    }

    if local.isAndroid && remote.isAndroid && path.isLocal && remote.supports("android-lan-quic") {
        return .androidLanQuic(priority: 90)
    }

    if local.isLinux && remote.isLinux && path.isLocal && remote.supports("linux-native-quic") {
        return .linuxNativeQuic(priority: 100)
    }

    if local.supports("skybridge-native-quic") &&
       remote.supports("skybridge-native-quic") &&
       path.isLocalOrManaged {
        return .skyBridgeNativeQuicInterop(priority: 85)
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

| Pair | Same LAN | Nearby / P2P | Cross NAT | Default Priority |
|---|---:|---:|---:|---|
| macOS ↔ iOS | Yes | Yes | Weak/no | AppleNativeTransport |
| macOS ↔ macOS | Yes | Yes | Weak/no | AppleNativeTransport |
| iOS ↔ iOS | Yes | Yes | Weak/no | AppleNativeTransport |
| Windows ↔ Windows | Yes | No | No | WindowsNativeMsQuicTransport |
| Windows ↔ Windows | No | No | Yes | MVP: WebRTCInteropTransport; future: SkyBridgeIceMsQuicTransport |
| Android ↔ Android | Optional | Yes | No | AndroidNativeAwareTransport if available |
| Android ↔ Android | Yes | No/unknown | No | AndroidLanQuicTransport |
| Android ↔ Android | No | No | Yes | WebRTCInteropTransport |
| Linux ↔ Linux | Yes | No | No | LinuxNativeQuicTransport |
| Linux ↔ Linux | No | No | Yes | WebRTCInteropTransport / RelayTransport |
| Windows ↔ Linux | Yes | No | Optional | SkyBridgeNativeQuicInteropTransport |
| Android ↔ Windows/Linux | Yes | Optional | Optional | SkyBridgeNativeQuicInteropTransport if Network binding succeeds; otherwise WebRTC |
| Apple ↔ Windows/Android/Linux | Yes | Optional | Optional | MVP: WebRTCInteropTransport; future: native QUIC interop |
| Any ↔ Any | No | No | Yes | WebRTCInteropTransport + TURN fallback |

---

## 8. SkyBridgeTransport Interface

Every transport adapter must expose the same logical interface.

```swift
public enum SkyBridgeTransportKind: String, Sendable {
    case appleNative
    case windowsNativeMsQuic
    case androidNativeAware
    case androidLanQuic
    case linuxNativeQuic
    case skyBridgeNativeQuicInterop
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

## 9. Transport Binding

SkyBridge Core must bind the selected transport into the session transcript.

```text
transport_binding = hash(
    transport_kind,
    local_endpoint,
    remote_endpoint,
    selected_candidate_pair,
    platform_network_id,
    wifi_aware_peer_handle if Android Wi-Fi Aware,
    dtls_fingerprint if WebRTC,
    quic_tls_exporter if QUIC/MsQuic/Quinn/Network.framework,
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
- bind MsQuic/Quinn/Network.framework QUIC context to SkyBridge identity
- bind Android Wi-Fi Aware path identity to SkyBridge identity
- make transport downgrade auditable

This binding must enter the SkyBridge handshake transcript before session keys are finalized.

---

## 10. Logical Channel Model

SkyBridge channels are Core-level semantics. Transport adapters only map them to native primitives.

| SkyBridge Channel | Semantics | Apple Native | Windows Native | Android Native | Linux Native | WebRTC |
|---|---|---|---|---|---|---|
| control | reliable, ordered, low latency | QUIC/TCP stream | MsQuic stream | QUIC stream over selected Network/Aware path | Quinn/MsQuic stream | reliable ordered DataChannel |
| file | reliable, chunked, backpressure-aware | QUIC/TCP stream | MsQuic stream | QUIC stream | Quinn/MsQuic stream | separate reliable DataChannel |
| clipboard | reliable, ordered, small payload | reliable stream | MsQuic stream | QUIC stream | QUIC stream | reliable DataChannel |
| telemetry | unordered or partial reliable | UDP/QUIC datagram | QUIC datagram | QUIC datagram where available | QUIC datagram | unordered DataChannel |
| realtime | unordered / partial reliable / datagram | QUIC datagram or platform media | QUIC datagram or future media path | QUIC datagram or future media path | QUIC datagram or future media path | unordered/partial reliable DataChannel or media track |

Do not put all traffic into a single reliable ordered stream. That causes head-of-line blocking and prevents channel-specific scheduling.

---

## 11. Crypto Provider Policy

SkyBridge wire protocol owns suite identity. Platform crypto providers are implementation details.

Existing suite IDs remain canonical:

| Suite ID | Meaning |
|---:|---|
| `0x0001` | X-Wing / hybrid PQC group |
| `0x0101` | ML-KEM-768 + ML-DSA-65 / pure PQC group |
| `0x1001` | X25519 + Ed25519 / classic group |
| `0x1002` | P-256 + ECDSA / legacy group |

Provider order:

```text
Apple:
  1. CryptoKit / Apple native PQC where available
  2. existing liboqs/OQSRAII fallback where configured
  3. classic X25519/Ed25519 fallback with explicit audit

Windows:
  1. Windows native CNG / .NET 10 PQC where available
  2. OpenSSL provider where available
  3. liboqs or Rust provider fallback
  4. classic X25519/Ed25519 fallback with explicit audit

Android:
  1. Android Keystore for identity/private-key protection where compatible
  2. Rust/liboqs provider for ML-KEM/ML-DSA/X-Wing compatibility
  3. BouncyCastle provider where JVM-side compatibility is needed
  4. classic X25519/Ed25519 fallback with explicit audit

Linux:
  1. OpenSSL provider where distro support is sufficient
  2. oqs-provider/liboqs where required for PQC coverage
  3. Rust provider fallback for portable builds
  4. classic X25519/Ed25519 fallback with explicit audit
```

Rules:

- Timeout must never cause crypto downgrade.
- Classic fallback must be policy-gated.
- Any downgrade must emit a security event.
- Offered suites must be derived from actual provider support, not static wish lists.
- Unknown suite IDs must be rejected safely, not crash the session.
- Android and Linux must pass the same test vectors as Apple and Windows.
- Benchmark documentation must state the provider actually used and must not imply unmeasured provider parity.

---

## 12. Traffic Padding / SBP2

SBP2 is a SkyBridge Core feature and must exist on Apple, Windows, Android, and Linux.

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
- Keep format identical across Swift, Rust, and any Kotlin-facing wrapper.
- Preserve existing SBP2 sensitivity and date-locking logic when benchmark artifacts are regenerated.

---

## 13. Platform Architecture Layouts

### 13.1 Windows

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

### 13.2 Android

```text
android/
  app/
    // Kotlin + Jetpack Compose
    // lifecycle, permissions, foreground service, notifications, settings

  native/
    skybridge-core-rs/
      crates/
        skybridge-protocol/
        skybridge-transport-android-aware/
        skybridge-transport-android-quic/
        skybridge-transport-webrtc/
        skybridge-discovery-android/
        skybridge-crypto-android/
        skybridge-routing/
        skybridge-ffi-uniffi-or-jni/
```

Kotlin boundary:

```kotlin
SkyBridgeCore.startDiscovery()
SkyBridgeCore.stopDiscovery()
SkyBridgeCore.connectPeer(peerId)
SkyBridgeCore.connectWithCode(code)
SkyBridgeCore.observeEvents(): Flow<SkyBridgeEvent>
SkyBridgeCore.sendControl(...)
SkyBridgeCore.sendFile(...)
```

Kotlin owns Android UX and OS integration. Rust owns protocol correctness.

### 13.3 Linux

```text
linux/
  ui-qt/
    // Qt 6/QML default Linux desktop UI

  ui-gtk/
    // optional GTK4/libadwaita build target

  daemon/
    // optional headless service / background agent

  native/
    skybridge-core-rs/
      crates/
        skybridge-protocol/
        skybridge-transport-quinn/
        skybridge-transport-msquic/
        skybridge-transport-webrtc/
        skybridge-discovery-avahi/
        skybridge-crypto-linux/
        skybridge-routing/
        skybridge-daemon-api/
```

Linux packaging targets:

- Flatpak for GUI distribution.
- Native distro packages for daemon/system integration.
- Headless mode must not depend on Qt or GTK.

---

## 14. macOS/iOS Refactor Scope

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
9. Keep current macOS build commands working unless a deliberate artifact/build revision is made.

Avoid:

- replacing Apple ↔ Apple with WebRTC
- moving Apple-specific discovery behavior into generic WebRTC code
- weakening current trust/pairing behavior for cross-platform convenience
- changing suite IDs
- changing SBP2 framing
- changing paper artifacts as a side effect of platform architecture work

---

## 15. WebRTC Interop and Signaling Scope

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

Production signaling requirements:

- No hardcoded TURN username/password in client code.
- Use short-lived TURN credentials.
- Signaling server exchanges offer/answer/ICE only.
- Signaling server must not hold SkyBridge session keys.
- TURN relay usage must be visible in transport metrics and audit events.
- `/api/turn/credentials` must be smoke-tested during deployment.

Minimal signaling messages:

```json
{
  "type": "rtc.offer",
  "session_id": "...",
  "from": "...",
  "to": "...",
  "sdp": "...",
  "capabilities": {
    "platform": "android",
    "transports": ["webrtc-dc", "android-lan-quic", "skybridge-native-quic"],
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

## 16. Implementation Phases

### Phase 0: Freeze Apple/README Regression Baseline

- Add tests proving macOS/iOS still use AppleNativeTransport by default.
- Add tests for existing Bonjour service names.
- Add tests for handshake suite selection.
- Add SBP2 cross-platform test vectors.
- Confirm `swift test`, `compile_paper.sh`, and `Scripts/run_paper_eval.sh` still run on the documented macOS/Apple Silicon/Xcode environment when intentionally used.
- Confirm architecture-only changes do not mutate stale paper PDFs/CSVs/checksums unintentionally.

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
- Implement basic .NET ↔ Rust FFI.
- Implement Windows provider discovery for crypto support.

### Phase 3: Linux Native MVP

- Create Rust core crates shared with Windows where possible.
- Implement Avahi DNS-SD discovery.
- Implement Quinn/rustls QUIC transport.
- Add optional MsQuic provider.
- Add systemd journal/tracing diagnostics.
- Add Qt 6/QML UI shell after daemon/core are stable.

### Phase 4: Android Native MVP

- Create Kotlin + Jetpack Compose app shell.
- Expose Rust core through JNI or UniFFI.
- Implement Android NSD/DNS-SD LAN discovery.
- Implement QUIC over selected Android `Network`.
- Add Wi-Fi Aware publish/subscribe and data path where available.
- Integrate Android Keystore for identity storage where compatible.

### Phase 5: WebRTC Interop MVP

- Implement WSS signaling.
- Implement short-lived TURN credentials.
- Implement WebRTC DataChannel transport adapter.
- Validate Windows ↔ macOS/iOS.
- Validate Android ↔ Apple/Desktop fallback.
- Validate Linux ↔ non-Linux fallback.
- Validate Windows/Android/Linux cross-NAT fallback.
- Validate `/api/turn/credentials` deployment semantics.

### Phase 6: Core Routing and Path Scoring

- Add path candidates.
- Add candidate race / happy-eyeballs style selection.
- Add path metrics.
- Add relay policy.
- Add transport downgrade audit.
- Add explicit labels for direct, relayed, overlay, IPv6 direct, and CGNAT-blocked paths.

### Phase 7: Advanced SkyBridge Native Interop

- Research SkyBridge ICE + MsQuic/Quinn path for desktop cross-NAT.
- Research native QUIC interop for Apple ↔ Windows/Android/Linux beyond WebRTC.
- Keep WebRTC as fallback adapter.

---

## 17. Tests and Acceptance Criteria

Required tests:

| Area | Test |
|---|---|
| Apple regression | Apple ↔ Apple selects AppleNativeTransport |
| README/build consistency | macOS build commands remain valid and do not imply unimplemented platforms |
| Stale paper boundary | ADR does not cite stale paper as architectural authority |
| Apple PQC gating | old SDKs do not enable `HAS_APPLE_PQC_SDK`; SDK 26+ builds can enable it through the documented env path |
| Windows native | Windows ↔ Windows same LAN selects WindowsNativeMsQuicTransport |
| Android native | Android ↔ Android Wi-Fi Aware path wins when supported and nearby |
| Android LAN | Android ↔ Android same LAN selects AndroidLanQuicTransport when Wi-Fi Aware unavailable |
| Linux native | Linux ↔ Linux same LAN selects LinuxNativeQuicTransport |
| Desktop interop | Windows ↔ Linux same LAN selects SkyBridgeNativeQuicInteropTransport |
| Interop | Apple ↔ Windows/Android/Linux selects WebRTCInteropTransport for MVP |
| Signaling deploy | `/api/turn/credentials` smoke test passes in deploy scripts |
| Fallback | TURN relay use emits audit/metrics |
| Network labeling | CGNAT/DS-Lite, IPv6 direct, overlay, relay, and direct paths are labeled distinctly |
| Security | timeout does not trigger crypto downgrade |
| Suite negotiation | offered suites come from provider support |
| Forward compatibility | unknown suite ID is rejected safely |
| SBP2 | Swift, Rust, and Kotlin-facing wrapper test vectors match |
| Channel mapping | control/file/telemetry map to distinct transport channels |
| Transport binding | transcript changes if selected transport changes |

Acceptance criteria:

- Mac/iOS behavior is not degraded by Windows/Android/Linux changes.
- The ADR does not depend on stale paper claims.
- Windows has a native same-LAN path independent of WebRTC.
- Android has a Kotlin app stack and a Rust protocol core.
- Android has native nearby/LAN paths independent of WebRTC where available.
- Linux has a Rust core and native Avahi/QUIC path independent of WebRTC.
- WebRTC is present for interop and NAT traversal.
- All transports run the same SkyBridge handshake and policy model.
- Transport selection is explainable in logs and test assertions.
- No production credential is hardcoded in the client.

---

## 18. Non-Goals

This ADR does not decide:

- final UI layout for Windows, Android, or Linux
- exact Rust crate versions
- final TURN hosting vendor
- final account/device-cloud model
- complete screen/video codec architecture
- replacement of current Apple discovery implementation
- immediate expansion of the current paper/artifact to Windows/Android/Linux
- a new artifact tag or checksum set
- stale paper corrections

This ADR does decide:

- WebRTC is not the architectural center.
- Windows ↔ Windows needs a native MsQuic path.
- Android ↔ Android needs a Kotlin app stack and native nearby/LAN paths backed by Rust core.
- Linux ↔ Linux needs a Rust core and native Avahi/QUIC path.
- Apple ↔ Apple keeps Apple native best practice.
- SkyBridge Core owns protocol/security/channel semantics.
- All transport adapters must be subordinate to SkyBridge Core.
- Stale paper material must not be used as the architecture source of truth.

---

## 19. Repository Impact

Likely files/directories to add:

```text
Docs/ADR-0001-SkyBridge-Core-Transport-Matrix.md
Sources/SkyBridgeCore/Transport/
Sources/SkyBridgeCore/CoreProtocol/
Sources/SkyBridgeCore/Routing/
windows/SkyBridge.Compass.WinUI/
windows/native/skybridge-core-rs/
android/app/
android/native/skybridge-core-rs/
linux/ui-qt/
linux/ui-gtk/
linux/daemon/
linux/native/skybridge-core-rs/
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
Server/skybridge-signaling/
```

Do not casually refactor or rename these branch-sensitive paths:

```text
Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.tex
Docs/TDSC-2026-01-0318_supplementary.tex
compile_paper.sh
Scripts/run_paper_eval.sh
Scripts/make_tables.py
Scripts/generate_ieee_figures.py
Artifacts/*.csv
Docs/tables/
Docs/supp_tables/
figures/
```

Special note:

`CrossNetworkConnectionManager` currently mixes QR, connection code, iCloud path, STUN probing, and NWConnection construction. It should be split into signaling, discovery, transport selection, and transport adapter responsibilities before Windows/Android/Linux work grows further.

---

## 20. Final Decision Statement

SkyBridge should evolve into a self-owned secure collaboration overlay protocol.

Apple ↔ Apple should keep Apple-native best practices. Windows ↔ Windows should use Windows-native best practices. Android ↔ Android should use a Kotlin app stack with native Android discovery/connectivity and Rust protocol core. Linux ↔ Linux should use a Rust core with Avahi discovery and Rust-native QUIC by default. Mixed-platform sessions should use WebRTC/ICE as the practical interop path for MVP, with SkyBridge native QUIC interop as the longer-term target.

All combinations must share SkyBridge Core identity, handshake, PQC/classic negotiation, channel semantics, padding, audit, and transport selection.

The current paper is stale and must not be used as the source of truth for this ADR. Architecture should be driven by current code, README operational constraints, deployment requirements, and validated future implementation work.

This is the architecture that prevents new platform support from weakening the mature macOS/iOS path while still allowing Windows, Android, and Linux to become first-class, high-performance platforms.
