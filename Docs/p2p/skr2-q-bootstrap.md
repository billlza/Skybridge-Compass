# Signed Q LAN bootstrap (SKR-2)

Q-Periapt ABI2 connections use an explicit version 2 signed LAN KEM refresh before MessageA when a trusted peer key is unavailable. This application protocol does not change the q-periapt 0.1.5 SDK ABI or its immutable release artifacts.

## Versioned contract

- Version 1 retains its existing canonical bytes for the X-Wing / ML-KEM profile. It cannot import Q keys or unsigned platform metadata.
- Version 2 requests exactly suite `0x0012`. Both policy bits remain strict: `policyRequirePQC=true` and `policyAllowClassicFallback=false`. The acronym case in the JSON field name is part of the wire contract.
- Version 2 uses `SkyBridge-SKR-2-Policy`, `SkyBridge-SKR-2-Request`, and `SkyBridge-SKR-2-SignedKEMRefresh` as the respective canonical domains. All version 1 fields keep their ordering. The response appends `platform` and `osVersion` after `bonjourEndpointDigest`; both values are included in the signature preimage.
- The public-key-set hash retains the `SkyBridge-SKR-1-KEMPublicKeys` domain and little-endian wire-id / length encoding. Suite `0x0012` has the canonical name `Q-Periapt-ABI2-PolicyBound` and a 1,216-byte public key.
- A Q response requires the previously pinned ML-DSA-65 identity and a platform admitted by the shared Q platform policy. Responder metadata comes from the local OS. Discovery metadata alone cannot authorize Q key import.
- The response version, nonce, request hash, target identity, endpoint digest and returned suite are checked against the exact request. Q responses permit at most five minutes of validity and thirty seconds of future clock skew. Existing generation checks continue to reject rollback.
- Verification never creates trust. Android requires the completed PIB authority, limits imports to its existing aliases and commits every alias in one transaction. Stored Q refreshes retain their version and signed platform provenance; a missing version means the legacy profile and cannot admit a Q refresh on restart.
- Cancelling the exchange or failing to persist the validated response must not return a ready authorization. A Q request has no automatic retry under version 1 and no classic or X-Wing downgrade. Peers lacking SKR-2 support need an application upgrade before a Q connection can proceed.

## Compatibility evidence

`Tests/SkyBridgeCoreTests/Fixtures/QPeriaptABI2/skr2-golden.json` contains a test-only ML-DSA-65 signature produced independently by the Android JVM test implementation. Android, macOS, iOS and Ubuntu validate the same request and response hashes and the signature. Tests also reject a modified, still-supported OS version, unsigned metadata, mixed suites, protocol downgrade, malformed keys and lost persistence writes. The vector uses a fixed historical clock solely for deterministic validation; it is never a production trust record.

Packaging and these tests are separate from ordinary application pairing, authenticated Finished, delivered remote frames, input ownership and file-transfer acceptance.
