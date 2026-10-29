# RemoteControl LAN Handshake Contract

## Purpose

This document defines the upgrade contract for the iOS viewer and macOS host LAN remote-control path. The target failure mode is:

- Handshake logs appear healthy on the initiator.
- The TCP connection is closed immediately after `MessageA` or right after secure-channel establishment.
- The viewer only sees a generic `P2P / LAN` disconnect.

The contract below exists to stop that class of regressions from reappearing after handshake, trust-store, Bonjour, or provider-selection changes.

## Contract

### 0. Initiator/responder roles are symmetric; transport layers are not interchangeable

macOS and iOS are both full P2P protocol peers. Either platform may initiate or
respond to the primary `_skybridge._tcp` handshake, including when the remote
peer is Android, Windows, or Linux. UI roles such as "viewer" and "host" must
not become protocol-authority roles.

The primary authenticated control session and the dedicated
`_skybridge-rd._tcp` remote-media socket are separate layers:

- the primary P2P handshake may use an exact authority-bound live Apple route,
  including a peer-to-peer interface;
- the current remote-media policy is infrastructure-only and is owned by the
  shared `ApplePeerConnectivityPolicy` decision, not by an iOS-only adapter;
- a scoped infrastructure address such as `fe80::...%en0` is not peer-to-peer
  merely because it is IPv6 link-local;
- the remote-media dialer must bind the exact live service endpoint to its
  observed interface and verify the resolved IPv6 scope before application data;
- the macOS remote-media listener must consume the same shared peer-to-peer
  admission policy; changing that policy requires symmetric macOS/iOS tests;
- a non-Apple host/port route must come from one atomic authenticated or signed
  route claim. An active connection host must never be combined with a generic
  cached/TXT/default port.

Enabling peer-to-peer remote-media transport is a separate, versioned product
decision. It must not be inferred from the primary P2P handshake's transport
capabilities.

### 1. Trust resolution must be unique on both sides

The iOS viewer and macOS host must resolve the same remote-control identity from the same stable authority surface:

- persistent `id:<uuid>`
- current-path `currentDeviceId`
- `knownDeviceIds`

Bonjour instance names, display names, host names, IP addresses, interface
names, and ports are route locators only. They must never select a trust record,
protocol pin, or KEM key.

Rules:

- `first(where:)` is not acceptable for remote-control trust resolution.
- If the selected device and authenticated peer both carry strong IDs, the IDs
  must be equal; two different strong IDs are a hard conflict and must not be
  unioned.
- Multiple matching records are allowed only when they collapse to one effective identity:
  - exactly one canonical `currentDeviceId`
  - at most one `protocolPublicKeyFingerprint`
- Any wider match set is a hard ambiguity and must fail before remote-control traffic starts.

Code anchors:

- iOS viewer resolver:
  [`RemoteDesktopManager.swift`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/SkyBridge%20Compass%20iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift)
- iOS LAN bootstrap:
  [`RemoteDesktopManager.swift`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/SkyBridge%20Compass%20iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift)
- macOS host resolver:
  [`RemoteControlTrustResolution.swift`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/Sources/SkyBridgeCore/RemoteControl/RemoteControlTrustResolution.swift)
- macOS inbound host handshake:
  [`RemoteControlManager.swift`](/Users/bill/Desktop/SkyBridge%20Compass%20Pro%20release/Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift)

### 2. Verified protocol authority must be persisted before LAN remote control bootstraps

The iOS viewer must not treat alias resolution as a substitute for authenticated protocol identity.

Rules:

- `HandshakeContext` may derive authenticated remote authority from verified `IdentityPublicKeys`.
- `HandshakeDriver` must snapshot that authority before zeroizing the context.
- The snapshot must remain readable through `waitingFinished` and `established`.
- The snapshot must be cleared on cancel, timeout, failure, or supersession.
- macOS `P2PConnection` and `P2PDiscoveryService` must persist the authenticated authority into `TrustSyncService` as soon as `pairingIdentityExchange` arrives on an authenticated session.
- The persisted record must bind:
  `protocolSigningAlgorithm`
  `protocolPublicKeyFingerprint`
  `currentDeviceId`
  `knownDeviceIds`
- iOS `TrustedDeviceStore` and macOS `TrustSyncService` must converge on the same stable peer identity before any later LAN remote-control bootstrap.
- `RemoteDesktopManager` / `RemoteControlManager` must refuse to start LAN remote-control bootstrap if the resolved trusted record lacks `protocolPublicKeyFingerprint`.

### 3. SOA identity binding is the authority source for LAN remote control

The host must not trust the inbound Bonjour/device-id label alone. It must bind the peer through:

- `HandshakeSOAExtension.initiatorPeerId`
- canonical trust-record alias expansion
- pinned `protocolPublicKeyFingerprint`

If the SOA identity cannot be mapped to one authoritative trust record, the host must reject the handshake.

### 4. Handshake policy and suite admission must stay aligned

Do not let one side advertise suites that its selected runtime provider path cannot actually sustain.

Rules:

- Outbound selection must be driven by `TwoAttemptHandshakeManager` preparation output.
- Inbound responder selection must stay aligned with `CryptoProviderFactory` and `HandshakeCryptoPolicyResolver`.
- Any change to PQC provider defaults, X-Wing preference, or hybrid admission requires rerunning the remote-control LAN tests listed below.

### 5. No remote-control app payload before the secure channel exists

On LAN:

- `MessageA/MessageB/Finished` are the only valid pre-auth frames.
- Viewer stream configuration, input events, clipboard, and screen payloads are post-auth only.
- A disconnect during this phase must preserve the handshake error cause instead of being flattened into a generic transport message whenever possible.

### 6. Connection ownership must be single-reader and generation-safe

The active `NWConnection` for a remote-control session is owned by one live session generation at a time.

Rules:

- stale callbacks must be ignored
- a replaced session must not tear down the new one
- receive loops must validate that the callback still belongs to the active connection/session

### 7. Screen streaming startup must be ACK-committed and generation-safe

On LAN remote control, the macOS host must not start `ScreenCaptureKit`, publish stream state,
enable the outbound frame/audio pump, or admit input until it has successfully sent the exact
`streamConfigurationAck` for the viewer's current transaction.

Rules:

- the initial secure-channel wait is not permission to start video push immediately
- a short grace wait may be used to catch the common fast path, but missing that grace window must leave the host idle rather than starting push optimistically
- a missing or malformed transaction, conflicting duplicate, or ACK send failure is fail-closed
- an exact duplicate configuration may receive the same logical ACK again, but must not restart capture
- there is no timer-based legacy start fallback; compatibility is an explicit protocol identity, not a timeout decision
- screen-sharing start/restart attempts must carry a generation token so a stale async start cannot revive capture after the peer has already closed or been replaced

## Required Tests

The following tests are mandatory before merging any change touching remote-control LAN, trust aliasing, SOA, handshake policy, or provider selection:

- macOS core:
  `swift test --filter RemoteControlTrustResolutionTests`
- macOS core:
  `swift test --filter HandshakeDriverTests`
- macOS core:
  `swift test --filter P2PTrustSyncTests`
- macOS core:
  `swift test --filter P2PDiscoveryHandshakeCompatibilityTests`
- macOS core:
  `swift test --filter OQS`
- macOS core:
  `swift test --filter RemoteControlScreenSharingStartupPolicyTests`
- iOS trust-resolution regression:
  `xcodebuild -project 'SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj' -scheme 'SkyBridgeCompassiOSTests' -destination 'platform=iOS Simulator,id=<simulator-id>' -only-testing:'SkyBridgeCompassiOSTests/RegressionHardeningTests/testLANRemoteControlTrustResolverPrefersRecordWithAuthorityWhenDuplicatesAreEquivalent' test`
- iOS handshake authority lifetime regression:
  `xcodebuild -project 'SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj' -scheme 'SkyBridgeCompassiOSTests' -destination 'platform=iOS Simulator,id=<simulator-id>' -only-testing:'SkyBridgeCompassiOSTests/RegressionHardeningTests/testHandshakeDriverRetainsAuthenticatedAuthorityAfterOutboundHandshakeEstablishes' test`
- iOS handshake cleanup regression:
  `xcodebuild -project 'SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj' -scheme 'SkyBridgeCompassiOSTests' -destination 'platform=iOS Simulator,id=<simulator-id>' -only-testing:'SkyBridgeCompassiOSTests/RegressionHardeningTests/testHandshakeDriverClearsAuthenticatedAuthorityAfterCancellation' test`
- iOS handshake/contract lane:
  `bash 'SkyBridge Compass iOS/Scripts/test_lane_ios.sh'`

## Upgrade Checklist

Any time one of the following changes, rerun the required tests and inspect this contract:

- trust-store schema
- alias normalization rules
- `currentDeviceId` / `knownDeviceIds` merge logic
- SOA peer-id derivation
- `CryptoProviderFactory`
- X-Wing / hybrid provider defaults
- remote-control listener / LAN socket lifecycle
- Bonjour endpoint resolution

## Non-goals

This contract does not permit “best effort” fallback from ambiguous trust resolution to a guessed record. That behavior hides real identity drift and recreates the exact class of failures this document is meant to prevent.
