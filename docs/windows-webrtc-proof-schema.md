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
- `selectedCandidatePair`: non-empty selected ICE candidate pair summary.
- `transportSecretFingerprintHex`: 64-character lowercase hex fingerprint of the helper's transport secret or exporter-equivalent binding material.
- `capabilityDigestHex`: 64-character lowercase hex digest of the capability transcript accepted for this adapter launch.
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
- bind the selected endpoint/candidate and secret/capability transcript to the paired peer identity.
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
  "selectedCandidatePair": "webrtc/dtls/sctp/helper-selected",
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

Prepare the Mac SSH and reusable Rust CLI side before the real interop gate:

```powershell
Scripts\prepare-mac-rust-cli-codbg.ps1 `
    -MacExpectedHostKeyFingerprint <SHA256:...> `
    -ProbeEvidencePath <mac-ssh-evidence.json> `
    -SummaryPath <mac-rust-cli-codbg-summary.json> `
    -RequireDirectLan `
    -RequireRustCliSmoke `
    -MacRemoteRepoRoot <mac-repo-root>
```

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
