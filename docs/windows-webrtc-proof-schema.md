# Windows WebRTC Proof Schema

This document is the Windows helper-proof contract for `SKYBRIDGE_WINDOWS_TRANSPORT_ADAPTER=webrtc-verified`. It defines the proof file consumed by `VerifiedWebRtcDataChannelTransportAdapterClient` and validated by `Scripts/verify-windows-webrtc-proof.ps1`. It is not a signaling protocol and it must not replace the AppleNative path used by macOS/iOS peers when both sides are Apple.

## Purpose

The proof file is written by a real WebRTC helper after a DataChannel is open and a SkyBridge frame round-trip has completed. Windows treats this file as adapter binding evidence only after Core has selected `WebRtcDataChannel` with `WebRtcInterop`, pairing has produced the expected peer device id and public-key fingerprint, and the proof is still fresh.

The helper may use libdatachannel, SIPSorcery, or another reviewed adapter implementation, but SkyBridge Core remains the authority for identity, pairing, channel mapping, frame encoding, traffic padding, suite selection, transport selection, and launch validation.

## JSON Fields

Required fields:

- `peerDeviceId`: exact device id from pairing material.
- `peerPublicKeyFingerprint`: exact 64-character lowercase hex public-key fingerprint from pairing material.
- `dataChannelOpen`: `true` only after WebRTC DTLS/SCTP DataChannel open.
- `sbf1EchoVerified`: `true` only after the helper sent a Core `SBF1` frame and received the expected echo.
- `sbf1FrameMagic`: literal `SBF1`.
- `adapterBinding`: non-empty helper/session binding description, for example `verified webrtc datachannel helper`.
- `localEndpoint`: non-empty local ICE/DTLS endpoint summary selected for the session.
- `remoteEndpoint`: non-empty remote ICE/DTLS endpoint summary selected for the session.
- `selectedCandidatePair`: non-empty nominated ICE candidate-pair summary. The checked helper records the runtime nominated pair as `webrtc/dtls/sctp/local=<type>:<endpoint>;remote=<type>:<endpoint>;path=<same-lan|cross-nat>`, for example `path=same-lan` for direct-LAN proof and `path=cross-nat` for cross-network STUN/TURN proof, so reviewers can distinguish direct-LAN and STUN/cross-NAT evidence without weakening either gate.
- `transportSecretFingerprintHex`: 64-character lowercase hex fingerprint of the helper's transport secret or exporter-equivalent binding material.
- `capabilityDigestHex`: 64-character lowercase hex digest of the capability transcript accepted for this adapter launch. The transcript must include the accepted `sameLan` and `crossNat` values.
- `timestampWindowMs`: positive timestamp window carried into Core launch binding material.
- `capturedAtUnixMs`: positive Unix epoch milliseconds when the helper captured the proof.

Optional fields:

- `helperName`: helper implementation name. Windows uses `webrtc-helper` when omitted.
- `relayId`: relay identifier when a relay participated in the selected candidate path.

## Validation Rules

Windows fails closed unless all of these are true:

- Core selected `WebRtcDataChannel` and `WebRtcInterop`.
- `peerDeviceId` and `peerPublicKeyFingerprint` exactly match pairing material.
- `dataChannelOpen` is `true`.
- `sbf1EchoVerified` is `true` and `sbf1FrameMagic` is `SBF1`.
- endpoint, candidate, adapter binding, transport secret fingerprint, capability digest, and timestamp window are present and valid.
- `capturedAtUnixMs` is not from the future and is no older than the configured max age.
- the adapter is not asked to produce `AppleNative` binding material.

## Helper Responsibilities

A compliant helper must:

- complete real WebRTC signaling, ICE, DTLS, SCTP, and DataChannel open before writing the proof.
- send a SkyBridge Core `SBF1` frame on the DataChannel and verify the expected echo.
- bind the nominated endpoint/candidate pair and secret/capability transcript to the paired peer identity.
- record the real network path in the proof transcript. Same-LAN helper runs use `--network-path same-lan` and require explicit bind-address evidence; cross-network helper runs use `--network-path cross-nat`, `--ice-servers <stun:...>` for unauthenticated STUN, `--ice-server-credentials <turn-credentials.json>` for authenticated TURN/STUN JSON, offer/answer signaling with server-reflexive or relay ICE candidates, and an actual nominated pair that includes an `srflx`, `relay`, or routable public host candidate side. Public IPv6 host candidates are valid cross-network evidence; private, link-local, loopback, ULA, CGNAT, benchmarking, or placeholder host candidates are not.
- keep TURN credentials out of argv, logs, and proof files. Credential JSON is local process input only; inline `turn:user:pass@...`, semicolon-delimited credentials, query strings, fragments, or other argv credential carriers are rejected.
- write the JSON proof atomically, using a temporary file followed by rename.
- avoid claiming AppleNative or Apple stream/datagram bindings.
- leave signaling transport replaceable; file, SSH, QR, relay, or manual signaling can be used during development, but the accepted data plane must be WebRTC DataChannel evidence.

## Example

```json
{
  "helperName": "skybridge-webrtc-helper",
  "peerDeviceId": "mac-1",
  "peerPublicKeyFingerprint": "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
  "dataChannelOpen": true,
  "sbf1EchoVerified": true,
  "sbf1FrameMagic": "SBF1",
  "adapterBinding": "verified webrtc datachannel helper",
  "localEndpoint": "windows.lan:5443",
  "remoteEndpoint": "mac.lan:5443",
  "selectedCandidatePair": "webrtc/dtls/sctp/local=host:windows.lan:5443;remote=host:mac.lan:5443;path=same-lan",
  "transportSecretFingerprintHex": "6666666666666666666666666666666666666666666666666666666666666666",
  "capabilityDigestHex": "7777777777777777777777777777777777777777777777777777777777777777",
  "relayId": "relay-helper",
  "timestampWindowMs": 15000,
  "capturedAtUnixMs": 1800000000000
}
```

## Acceptance Commands

Validate a helper proof locally:

```powershell
Scripts\verify-windows-webrtc-proof.ps1 `
    -ProofPath <proof.json> `
    -ExpectedDeviceId <device-id> `
    -ExpectedFingerprint <64-lowercase-hex>
```

Validate the same schema through the reusable Rust CLI:

```powershell
Scripts\verify-rust-webrtc-proof-cli.ps1 `
    -ProofPath <proof.json> `
    -ExpectedDeviceId <device-id> `
    -ExpectedFingerprint <64-lowercase-hex>
```

Run the default synthetic schema smoke:

```powershell
Scripts\verify-windows-webrtc-proof-smoke.ps1
```

Run the live helper proof on a cross-network path only when the Mac SSH host key is pinned and STUN/ICE signaling can be exchanged. This proves the helper WebRTC data plane; it does not replace Mac product AppControl or peer-trust persistence evidence:

```powershell
Scripts\verify-windows-mac-webrtc-helper-live.ps1 `
    -MacHostName <mac-host> `
    -MacExpectedHostKeyFingerprint <SHA256:...> `
    -ExpectedDeviceId <device-id> `
    -ExpectedFingerprint <64-lowercase-hex> `
    -AllowCrossNetworkIce `
    -IceServers 'stun:stun.l.google.com:19302' `
    -IceServerCredentialsPath <turn-credentials.json> `
    -ProofOutPath <proof.json>
```

Prepare the Mac SSH and reusable Rust CLI side before the real interop gate:

```powershell
Scripts\prepare-mac-rust-cli-codbg.ps1 `
    -MacExpectedHostKeyFingerprint <SHA256:...> `
    -MacDirectSourceAddress <windows-lan-source-ip> `
    -ProbeEvidencePath <mac-ssh-evidence.json> `
    -SummaryPath <mac-rust-cli-codbg-summary.json> `
    -RequireDirectLan `
    -RequireRustCliSmoke `
    -MacRemoteRepoRoot <mac-repo-root>
```

The probe evidence records `remediation.reasonCodes`, recommended direct-source candidates, and `nextProbeCommand`; a `proxy-tunnel-route` or `no-same-subnet-lan-candidate` reason must be fixed before treating Mac SSH, DNS-SD, WebRTC proof, or product connection failures as interop bugs.

Run the real Windows-to-mac interop gate only after direct LAN, Mac SSH, Mac Rust CLI, native DNS-SD, and helper proof generation are ready:

```powershell
Scripts\verify-windows-portability-smoke.ps1 `
    -RequireMacWebRtcInterop `
    -MacSshEvidencePath <mac-ssh-evidence.json> `
    -MacRemoteRepoRoot <path> `
    -MacWebRtcProofPath <proof.json> `
    -ExpectedDeviceId <device-id> `
    -ExpectedFingerprint <64-lowercase-hex>
```
