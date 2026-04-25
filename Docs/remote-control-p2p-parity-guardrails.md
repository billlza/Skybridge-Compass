# Remote Control P2P Parity Guardrails

## Why This Exists

iOS -> macOS LAN remote control can fail in a particularly misleading way:

1. iOS logs a normal `Handshake attempt` and sends `MessageA`.
2. macOS closes the socket before the remote desktop secure channel becomes usable.
3. iOS only sees `transport=P2P / LAN reason=连接已断开`.

This class of regression is easy to reintroduce during handshake, identity, or crypto-provider upgrades because the codebase has both:

- shared macOS/core handshake code under [`Sources/SkyBridgeCore/P2P`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/Sources/SkyBridgeCore/P2P)
- iOS-local handshake code under [`SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/SkyBridge%20Compass%20iOS/SkyBridgeCompassiOS/Sources/Core/Handshake)

## Root Cause We Fixed

The regression was not a single broken socket call. It was a trust-lifecycle drift across the macOS P2P stack:

- `HandshakeContext` and `HandshakeDriver` could authenticate the remote protocol authority
- but that authenticated authority was not consistently persisted by both
  [`P2PModels.swift`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/Sources/SkyBridgeCore/P2P/P2PModels.swift)
  and
  [`P2PDiscoveryService.swift`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift)
- later, the macOS remote-control inbound gate in
  [`RemoteControlManager.swift`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift)
  resolved trust from `TrustSyncService`
- because the authenticated authority had never been bridged into `TrustSyncService`, the host rejected the iPhone as `untrustedPeer`

In short: handshake success and trust persistence had drifted apart.

## Non-Negotiable Invariants

Any future upgrade must preserve all of these:

1. Remote-control SOA binding must be derived from stable device identities only.
   Allowed: persistent `id:` identities or raw stable UUIDs that normalize to `id:...`.
   Forbidden: `bonjour:...`, `host:...`, `peer:...`, `recent:...`.

2. The same SOA binding helper must be used for both outbound and inbound remote-control handshakes on macOS.

3. Inbound remote-control `HandshakeDriver` construction must explicitly receive:
   `localSOAPeerId`
   `expectedRemoteSOAPeerId`

4. Any shared-handshake contract change must be reviewed against the iOS-local handshake implementation.
   Minimum files to diff:
   [`Sources/SkyBridgeCore/P2P/HandshakeDriver.swift`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/Sources/SkyBridgeCore/P2P/HandshakeDriver.swift)
   [`SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakeDriver.swift`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/SkyBridge%20Compass%20iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakeDriver.swift)
   [`Sources/SkyBridgeCore/P2P/TwoAttemptHandshakeManager.swift`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/Sources/SkyBridgeCore/P2P/TwoAttemptHandshakeManager.swift)
   [`SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/TwoAttemptHandshakeManager.swift`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/SkyBridge%20Compass%20iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/TwoAttemptHandshakeManager.swift)

5. Authenticated protocol authority must outlive the ephemeral handshake context on both macOS core and iOS.
   Required behavior:
   `HandshakeContext` generates the authority from the verified `IdentityPublicKeys`.
   `HandshakeDriver` snapshots that authority before `HandshakeContext.zeroize()`.
   The snapshot survives through `waitingFinished` and `established`.
   The snapshot is cleared on cancel, timeout, handshake failure, and supersession.

6. Remote-control trust bootstrap must persist authenticated protocol authority before any separate LAN remote-control secure-channel bootstrap.
   In practice this means:
   macOS `P2PConnection` and `P2PDiscoveryService` must bridge the authority from `HandshakeDriver` into `TrustSyncService`.
   the bridge must preserve `protocolSigningAlgorithm`, `protocolPublicKeyFingerprint`, `currentDeviceId`, and `knownDeviceIds`.
   iOS `TrustedDeviceStore` and macOS `TrustSyncService` must agree on the same canonical peer.
   `RemoteDesktopManager` / `RemoteControlManager` must resolve LAN trust from that persisted authority, never from a guessed alias-only record.

7. Default viewer presets from a brand-new iOS install must be treated as a first-class compatibility target.
   The current default is effectively:
   auto resolution
   60 FPS
   H.264 preferred when supported
   That path must be covered by regression tests, not just power-user presets or previously migrated settings.

8. Any encoded remote-desktop stream size handed to macOS capture / VideoToolbox must be normalized before session creation.
   Required behavior:
   H.264 / HEVC sizes are rounded down to encoder-safe even dimensions.
   JPEG fallback may keep odd dimensions.
   The same normalization helper must be reused by both policy selection and actual capture startup.

9. A first-frame VideoToolbox failure must not loop forever on the same codec branch.
   Required behavior:
   `kVTInvalidSessionErr`, `kVTVideoEncoderMalfunctionErr`, and `kVTVideoEncoderNotAvailableNowErr`
   must trigger a session-scoped codec downgrade path instead of a blind same-config restart.
   Minimum downgrade ladder:
   HEVC -> H.264
   H.264 -> JPEG

10. The first macOS screen push must be gated by viewer readiness.
    Required behavior:
    the host may wait briefly for the first viewer `streamConfiguration`, but must stay idle if that grace window expires
    the first `streamConfiguration` must be able to trigger the initial `ScreenCaptureKit` start
    any delayed compatibility fallback start must be cancelled when the peer closes, is superseded, or sends `streamConfiguration`
    every async capture start/restart path must be generation-guarded so a stale task cannot revive screen capture after teardown

11. Remote-control capability must never be treated as a concrete LAN endpoint.
    Required behavior:
    `remote_desktop` / `remote_control` capability may enable UI affordances, but only a real Bonjour remote service, an explicit `remoteControlPort`, or an authenticated active peer route with an explicit remote-control port may produce an `NWEndpoint`.
    A bootstrap `ready=true` log only proves identity/KEM metadata readiness; the later LAN endpoint connection must log candidate index/count, waiting, timeout, and failure reason.

12. LAN remote-control endpoint connection must be bounded and fail over.
    Required behavior:
    stale Bonjour service records or unusable host addresses must not leave the viewer stuck after bootstrap.
    multiple equivalent endpoint candidates must be tried in order with a per-candidate timeout, and the final failure must be visible to the caller/UI.

## Best Practice

Treat identity normalization and SOA binding as protocol infrastructure, not feature glue.

- Put normalization in one helper.
- Reuse that helper from both initiator and responder code paths.
- Refuse ephemeral aliases at helper boundaries instead of trying to “fix them up” later.
- Add regression tests for the helper so future refactors fail fast.
- Treat “fresh install defaults on a new device” as a regression fixture, because user-specific saved presets can mask protocol and capture bugs.
- Treat remote desktop startup as a protocol state machine instead of a side effect of socket acceptance.
- Make delayed compatibility fallback tasks explicit and cancellable.
- Guard async capture startup with a session generation token.

## Required Regression Tests

These tests are the minimum bar after any handshake / crypto / remote-control upgrade:

```bash
swift test --filter HandshakeDriverTests
swift test --filter P2PTrustSyncTests
swift test --filter P2PDiscoveryHandshakeCompatibilityTests
swift test --filter RemoteControlSOABindingTests
swift test --filter RemoteControlScreenSharingStartupPolicyTests
swift test --filter RemoteControlCaptureCompatibilityTests
swift test --filter RemoteControlStreamPolicyTests
swift test --filter RemoteControl
xcodebuild -project 'SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj' -scheme 'SkyBridgeCompassiOSTests' -destination 'platform=iOS Simulator,id=<simulator-id>' -only-testing:'SkyBridgeCompassiOSTests/RegressionHardeningTests/testHandshakeDriverRetainsAuthenticatedAuthorityAfterOutboundHandshakeEstablishes' test
xcodebuild -project 'SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj' -scheme 'SkyBridgeCompassiOSTests' -destination 'platform=iOS Simulator,id=<simulator-id>' -only-testing:'SkyBridgeCompassiOSTests/RegressionHardeningTests/testHandshakeDriverClearsAuthenticatedAuthorityAfterCancellation' test
xcodebuild -project 'SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj' -scheme 'SkyBridgeCompassiOSTests' -destination 'platform=iOS Simulator,id=<simulator-id>' -only-testing:'SkyBridgeCompassiOSTests/RegressionHardeningTests/testLANRemoteControlTrustResolverPrefersRecordWithAuthorityWhenDuplicatesAreEquivalent' test
xcodebuild -project 'SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj' -scheme 'SkyBridgeCompassiOSTests' -destination 'platform=iOS Simulator,id=<simulator-id>' -only-testing:'SkyBridgeCompassiOSTests/RegressionHardeningTests/testP2PPairingCapabilitiesDoNotSynthesizeLANServiceEndpointsWithoutPorts' test
bash "SkyBridge Compass iOS/Scripts/test_lane_ios.sh"
```

If the change touches handshake selection, also manually diff the shared and iOS-local handshake implementations before merging.

## Files That Enforce This Contract

- [`Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift)
- [`Tests/SkyBridgeCoreTests/RemoteControlSOABindingTests.swift`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/Tests/SkyBridgeCoreTests/RemoteControlSOABindingTests.swift)
