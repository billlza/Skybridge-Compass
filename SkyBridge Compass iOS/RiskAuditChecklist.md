# SkyBridge Compass iOS Risk Audit Checklist

Date baseline: 2026-02-28
Scope: Crypto / Handshake / Networking / UI

## Risk Scale

- R4 Critical: compromise breaks confidentiality/integrity, key lifecycle, trust, or protocol semantics.
- R3 High: compromise causes auth/session/network state errors or major business impact.
- R2 Medium: reliability/performance/business correctness impact without direct key compromise.
- R1 Low: presentation-level defects or non-security UX issues.

---

## Crypto Layer

### Crypto Checklist IDs

- C1 Key lifecycle: generation, storage, zeroization, no secret copies in logs.
- C2 Randomness: secure entropy source only (`SecRandomCopyBytes`) for key/nonce/seed material.
- C3 Determinism and parity: deterministic encode/decode matches cross-platform contract.
- C4 Policy semantics: strict/prefer fallback behavior aligns with TDSC contract.
- C5 Trust binding: key-to-device binding, rotation behavior, replay/rollback handling.
- C6 Failure handling: no silent downgrade, no force unwrap crash path in critical flows.

### Files

| File | Risk | Checklist | Status |
| --- | --- | --- | --- |
| `Packages/OQSRAIILocal/Sources/OQSRAII/include/OQSRAII.h` | R4 | C1,C2,C3,C6 | ✅ Done (evidence: `Packages/OQSRAIILocal/Sources/OQSRAII/include/OQSRAII.h:1`) |
| `Packages/OQSRAIILocal/Sources/OQSRAII/src/OQSRAII.cpp` | R4 | C1,C2,C3,C6 | ✅ Done (evidence: `Packages/OQSRAIILocal/Sources/OQSRAII/src/OQSRAII.cpp:1`) |
| `SkyBridgeCompassiOS/Sources/Core/CoreTypes.swift` | R4 | C1,C2,C3,C6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/CoreTypes.swift:88`) |
| `SkyBridgeCompassiOS/Sources/Core/CryptoProviderFactory.swift` | R3 | C3,C4,C6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/CryptoProviderFactory.swift:229`) |
| `SkyBridgeCompassiOS/Sources/Core/CryptoProviderProtocol.swift` | R3 | C3,C4,C6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/CryptoProviderProtocol.swift:126`) |
| `SkyBridgeCompassiOS/Sources/Core/Providers/ApplePQCProvider.swift` | R4 | C1,C2,C3,C6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/Providers/ApplePQCProvider.swift:89`) |
| `SkyBridgeCompassiOS/Sources/Core/Providers/ClassicProvider.swift` | R4 | C1,C2,C3,C6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/Providers/ClassicProvider.swift:55`) |
| `SkyBridgeCompassiOS/Sources/Core/Providers/OQSPQCProvider.swift` | R4 | C1,C2,C3,C6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/Providers/OQSPQCProvider.swift:34`) |
| `SkyBridgeCompassiOS/Sources/Core/Security/KeychainManager.swift` | R4 | C1,C5,C6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/Security/KeychainManager.swift:13`) |
| `SkyBridgeCompassiOS/Sources/Core/Trust/KEMPublicKeyInfo.swift` | R3 | C3,C5,C6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/Trust/KEMPublicKeyInfo.swift:1`) |
| `SkyBridgeCompassiOS/Sources/Core/Trust/KEMTrustStore.swift` | R4 | C1,C3,C5,C6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/Trust/KEMTrustStore.swift:28`) |
| `SkyBridgeCompassiOS/Sources/Core/Trust/P2PKEMIdentityKeyStore.swift` | R4 | C1,C2,C5,C6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/Trust/P2PKEMIdentityKeyStore.swift:57`) |
| `SkyBridgeCompassiOS/Sources/Core/PolicyDecisionSnapshot.swift` | R3 | C3,C4,C6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/PolicyDecisionSnapshot.swift:36`) |
| `SkyBridgeCompassiOS/Sources/Managers/PQCCryptoManager.swift` | R3 | C1,C4,C6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Managers/PQCCryptoManager.swift:92`) |
| `SkyBridgeCompassiOS/Sources/Auth/NebulaIDGenerator.swift` | R2 | C2,C5,C6 | Pending |

---

## Handshake Layer

### Handshake Checklist IDs

- H1 Transcript integrity: transcript hash is mandatory; no implicit empty fallback.
- H2 Signature domain separation and verification ordering.
- H3 Suite negotiation anti-downgrade and capability matching.
- H4 Nonce/key share validation and replay resistance.
- H5 State machine safety under concurrent/reordered message arrival.
- H6 Cross-platform wire compatibility (iOS/macOS parity).
- H7 No crash paths (`!`, unchecked index/pointer) in protocol parsing.

### Files

| File | Risk | Checklist | Status |
| --- | --- | --- | --- |
| `SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakeDriver.swift` | R4 | H1,H2,H3,H4,H5,H6,H7 | Reviewed 2026-02-28 |
| `SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakeMessages.swift` | R4 | H2,H3,H4,H6,H7 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakeMessages.swift:56`) |
| `SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakePadding.swift` | R3 | H4,H6,H7 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakePadding.swift:7`) |
| `SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakeTypes.swift` | R4 | H1,H3,H5,H6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakeTypes.swift:17`) |
| `SkyBridgeCompassiOS/Sources/Core/Handshake/SignatureProvider.swift` | R4 | H2,H6,H7 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/Handshake/SignatureProvider.swift:16`) |
| `SkyBridgeCompassiOS/Sources/Core/Handshake/TrafficPadding.swift` | R3 | H6,H7 | Reviewed 2026-02-28 |
| `SkyBridgeCompassiOS/Sources/Core/Handshake/TrafficPaddingStats.swift` | R2 | H5,H6 | Pending |
| `SkyBridgeCompassiOS/Sources/Core/Handshake/TwoAttemptHandshakeManager.swift` | R3 | H3,H5,H6,H7 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/Handshake/TwoAttemptHandshakeManager.swift:49`) |

---

## Networking Layer

### Networking Checklist IDs

- N1 Input validation for all remote payloads and envelopes.
- N2 Connection/auth/session lifecycle correctness and cleanup.
- N3 Backoff, retry, timeout, cancellation, and dedup behavior.
- N4 Resource control: memory growth, queue limits, timer/task leaks.
- N5 Trust and identity binding across reconnect/rekey paths.
- N6 Failure behavior is explicit and user-observable (no silent fail/no crash).

### Files

| File | Risk | Checklist | Status |
| --- | --- | --- | --- |
| `SkyBridgeCompassiOS/Sources/Auth/SupabaseService.swift` | R3 | N1,N2,N3,N6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Auth/SupabaseService.swift:27`) |
| `SkyBridgeCompassiOS/Sources/Core/Config/SkyBridgeServerConfig.swift` | R3 | N1,N5,N6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/Config/SkyBridgeServerConfig.swift:95`) |
| `SkyBridgeCompassiOS/Sources/Core/FileTransfer/FileTransferNetworkService.swift` | R3 | N1,N2,N3,N4,N6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/FileTransfer/FileTransferNetworkService.swift:27`) |
| `SkyBridgeCompassiOS/Sources/Core/FileTransfer/FileTransferRuntime.swift` | R3 | N2,N3,N4,N6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/FileTransfer/FileTransferRuntime.swift:6`) |
| `SkyBridgeCompassiOS/Sources/Core/Messaging/AppMessage.swift` | R2 | N1,N6 | Pending |
| `SkyBridgeCompassiOS/Sources/Core/Messaging/OfflineMessageQueue.swift` | R2 | N2,N3,N4,N6 | Reviewed 2026-02-28 |
| `SkyBridgeCompassiOS/Sources/Core/Network/STUNClient.swift` | R3 | N1,N2,N3,N6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/Network/STUNClient.swift:18`) |
| `SkyBridgeCompassiOS/Sources/Core/P2P/P2PConnectionService.swift` | R4 | N1,N2,N3,N5,N6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/P2P/P2PConnectionService.swift:2`) |
| `SkyBridgeCompassiOS/Sources/Core/P2P/P2PModels.swift` | R2 | N1,N6 | Pending |
| `SkyBridgeCompassiOS/Sources/Core/QRCode/QRCodeManager.swift` | R2 | N1,N5,N6 | Pending |
| `SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkFileTransferWire.swift` | R4 | N1,N2,N4,N5,N6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkFileTransferWire.swift:14`) |
| `SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession.swift` | R4 | N1,N2,N3,N4,N5,N6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession.swift:9`) |
| `SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSignalingEnvelope.swift` | R3 | N1,N6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSignalingEnvelope.swift:1`) |
| `SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebSocketSignalingClient.swift` | R3 | N1,N2,N3,N6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebSocketSignalingClient.swift:6`) |
| `SkyBridgeCompassiOS/Sources/Managers/AuthenticationManager.swift` | R3 | N2,N5,N6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Managers/AuthenticationManager.swift:18`) |
| `SkyBridgeCompassiOS/Sources/Managers/CloudKitSyncManager.swift` | R2 | N2,N3,N4,N6 | Pending |
| `SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift` | R4 | N1,N2,N3,N4,N5,N6 | Reviewed 2026-02-28 |
| `SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift` | R3 | N2,N3,N4,N6 | Reviewed 2026-02-28 |
| `SkyBridgeCompassiOS/Sources/Managers/FileTransferManager.swift` | R3 | N2,N3,N4,N6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Managers/FileTransferManager.swift:21`) |
| `SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift` | R3 | N2,N3,N5,N6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift:14`) |
| `SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift` | R3 | N2,N3,N4,N6 | ✅ Done (evidence: `SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift:40`) |
| `SkyBridgeCompassiOS/Sources/Core/Background/BackgroundTaskManager.swift` | R2 | N2,N4,N6 | Pending |

---

## UI Layer

### UI Checklist IDs

- U1 State source of truth: no stale/duplicated state causing security/business drift.
- U2 Error surfacing: actionable, localized, and non-silent.
- U3 Sensitive display/logging: never expose secrets/keys/tokens.
- U4 Main-thread correctness and task cancellation for view lifecycle.
- U5 Accessibility and resilience (loading/empty/offline/retry states).

### Files

| File | Risk | Checklist | Status |
| --- | --- | --- | --- |
| `SkyBridgeCompassiOS/Sources/App/ContentView.swift` | R2 | U1,U2,U4,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift` | R2 | U1,U2,U4 | Pending |
| `SkyBridgeCompassiOS/Sources/ViewModels/DashboardViewModel.swift` | R2 | U1,U2,U4,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Views/AuthenticationView.swift` | R2 | U1,U2,U3,U4,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Views/BetaBannerView.swift` | R1 | U2,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Views/DeviceDiscoveryView.swift` | R2 | U1,U2,U4,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Views/FileTransferView.swift` | R2 | U1,U2,U3,U4,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Views/PQCMicroBenchView.swift` | R2 | U1,U2,U3,U4,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Views/PQCVerificationView.swift` | R2 | U1,U2,U3,U4,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Views/RealNetworkE2EBenchView.swift` | R2 | U1,U2,U4,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Views/RemoteDesktopView.swift` | R2 | U1,U2,U3,U4,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Views/SettingsView.swift` | R2 | U1,U2,U3,U4,U5 | Reviewed 2026-02-28 |
| `SkyBridgeCompassiOS/Sources/Views/Dashboard/DashboardView.swift` | R2 | U1,U2,U4,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Views/Dashboard/Components/DeviceRowView.swift` | R1 | U1,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Views/Dashboard/Components/QuickActionButtonView.swift` | R1 | U1,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Views/Dashboard/Components/StatCardView.swift` | R1 | U1,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Views/Dashboard/Components/WeatherCardView.swift` | R1 | U1,U2,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Core/Weather/WeatherManager.swift` | R2 | U1,U2,U4,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Core/Weather/WeatherService.swift` | R2 | U1,U2,U4,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Managers/SettingsManager.swift` | R2 | U1,U2,U3,U4 | Pending |
| `SkyBridgeCompassiOS/Sources/Managers/LocalizationManager.swift` | R1 | U2,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Managers/ThemeConfiguration.swift` | R1 | U1,U5 | Pending |
| `SkyBridgeCompassiOS/Sources/Utilities/LiquidGlass.swift` | R1 | U5 | Pending |
| `SkyBridgeCompassiOS/Sources/LiveActivities/SkyBridgeActivityAttributes.swift` | R1 | U1,U5 | Pending |
| `Widgets/SkyBridgeWidget.swift` | R1 | U1,U2,U5 | Pending |
| `Widgets/SkyBridgeLiveActivity.swift` | R1 | U1,U2,U5 | Pending |

---

## Execution Notes

- Reviewed files in this round were selected from crash-prone and protocol-critical paths.
- Remaining rows are intentionally left as actionable checklist items for iterative audit passes.
- Recommended cadence: R4 weekly, R3 bi-weekly, R2 monthly, R1 per release candidate.
