# Apple production-codec compatibility vectors

This directory is a read-only Level-1 compatibility corpus captured from Apple shipping codec
entry points. It detects accidental corruption and misattribution; it is not a signature,
attestation, or proof that the capture host was uncompromised.

## Pinned capture

- fixture set: `apple-production-codec-v1`
- Apple source commit: `6d6f601ea0ac23ba5c62d46b98c3efd03acc4898`
- source-set SHA-256: `7ea5e3760a2f27818700bdad3f047f26d9670365eb79ea73e70a72ea69364cfb`
- semantic-input SHA-256: `d3ff9759f75fb6dd4651b0b41e156005809ce3db6cc80524ca56533e17058cb0`
- manifest SHA-256: `8baaf1e824a65d74a35e25d27ba57771e488cf6bdd63611b0c45273d47c09869`
- collected at: `2026-08-10T22:59:36.000Z`
- capture tool: `Tests/SkyBridgeCoreTests/AppleCompatibilityVectorCaptureTests.swift`

The loader validates the manifest before exposing any vector, requires the exact allowlisted file
set, rejects symbolic links, invalid UTF-8, duplicate or unknown JSON keys, path traversal, malformed
lower-case hex, and any manifest/document provenance or digest mismatch. Android has no update or
capture-writing entry point.

## Coverage

| Surface | Shipping codec evidence | Vectors | Status |
| --- | --- | ---: | --- |
| F1 file transfer | canonical `CrossNetworkFileTransferWireEncoder` JSON | 8 | captured |
| F2 P2P handshake | capabilities, policy, MessageA, MessageB, Finished | 5 | captured |
| F3 HPKE sealed box | handshake/application v1/v2 encodings | 5 | captured |
| F4 Bonjour TXT | canonical advertisement TXT bytes | 5 | captured |
| Total |  | 23 | 4/4 surfaces captured |

The former WP-05 through WP-08 capture blockers are resolved by this corpus. The reviewed manifest
and the 23 captured documents are the maintained in-repository record; the pre-capture planning
notes are intentionally not shipped as part of this read-only test resource.

## Scope boundary

F1 evidence proves canonical wire compatibility only: Apple bytes decode through the Android
shipping codec, project to the captured typed fields, and re-encode byte-for-byte. It does **not**
claim strict admission parity. Android still accepts unknown JSON fields and does not yet expose a
single production admission abstraction equivalent to Apple's per-operation retained-byte and
inbound-response validation; that is tracked as a separate production gap rather than simulated by
the audit adapter.

F2, F3, and F4 checks likewise call their production Android codecs directly. Arrays and protocol
suite order are preserved. F4 expected field values are lower-case hex of raw TXT value bytes; the
raw record is decoded and canonically re-encoded by `BonjourTxtRecordCodec` rather than rebuilt by
iterating `expectedFields`.

## Repository layout

`manifest.json` lists every captured document. The only non-capture file allowed beside those 24
JSON files is this README, whose reviewed SHA-256 is pinned in the read-only loader.
