# Remote Control Dual-Algorithm Trust Fix - 2026-04-24

## Incident

At `2026-04-24 21:38:23.393 +0800`, the macOS host closed an inbound remote-control socket before sending `MessageB`.

Relevant unified log:

```text
RemoteControl inbound handshake init failed ...
remote control handshake initialization failed:
ambiguous trusted inbound remote-control identity:
deviceIds=id:07cb9a6e-7492-4680-9dd7-f37dc8568891
fingerprints=968d41cc...,cbae6ed...
```

Network.framework reported `bytes in/out: 8196/0`, confirming the host received the iOS `MessageA` frame and closed before replying. The failure was not caused by frame size, NECP logging, or Live Activities.

## Root Cause

`RemoteControlInboundTrustResolver` collapsed inbound SOA identity by requiring:

```swift
deviceIds.count == 1 && fingerprints.count <= 1
```

That was too strict for the current PQC migration model. A single stable device can legitimately have two protocol-signing identities at the same time:

- Ed25519 for classic fallback.
- ML-DSA-65 for PQC handshakes.

The resolver confused "one device with two protocol algorithms" with "two possible devices".

## Fix Boundary

The resolver now only maps the authenticated SOA peer id to a unique canonical device id. It does not choose a fingerprint when multiple algorithms are present.

The actual signed protocol identity is still checked later by `HandshakeDriver` after MessageA signature validation. Pinning now validates the actual authoritative fingerprint against the full trusted fingerprint set for the device.

The macOS remote-control inbound path creates `DefaultHandshakeTrustProvider` from an active trust-record snapshot at driver creation time. That keeps the resolver, admission check, and MessageA pinning on the same trust view for the lifetime of the short handshake.

Safety constraints:

- Different canonical device ids remain ambiguous.
- Multiple fingerprints for the same protocol signing algorithm remain ambiguous.
- A missing trusted pin set still rejects remote-control setup before creating the driver.
- Classic bootstrap identity bridge was removed. A known trusted pin and a cached KEM key are not enough to authenticate a different Ed25519 signer.
- Snapshot trust providers use the same trust-record snapshot for protocol fingerprints, KEM public keys, and Secure Enclave public keys.

## Regression Coverage

Added coverage in `RemoteControlTrustResolutionTests` for:

- One canonical device with Ed25519 and ML-DSA-65 pins resolves to the device instead of ambiguous.
- Same canonical device with conflicting fingerprints for the same algorithm remains ambiguous.
- `DefaultHandshakeTrustProvider` returns the full dual-algorithm pin set and the legacy single-pin API does not invent a winner.
- `DefaultHandshakeTrustProvider` returns no pin set for alias conflicts or same-algorithm fingerprint conflicts.
- Snapshot providers return KEM and Secure Enclave keys from the snapshot instead of rereading live trust records.
- `HandshakeDriver` fails identity pin mismatches even when classic bootstrap KEM material is available.

## Future Guardrails

Do not collapse protocol-signing fingerprints by sorting and choosing the first/last entry. Device identity resolution and protocol key acceptance are separate decisions.

Do not treat `trustedFingerprint(for:) == nil` as permission to skip pinning when a device has multiple trusted protocol identities. Use `trustedFingerprints(for:)` for multi-algorithm trust decisions.

If trust records later add lifecycle states such as quarantine or reverification-required to remote-control policy, update both the resolver and provider tests in the same change.
