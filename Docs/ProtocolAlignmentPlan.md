# Protocol Alignment Plan (IEEE Paper vs Code)

## Summary
The IEEE paper describes the newer handshake protocol (supportedSuites list, keyShares, clientNonce/serverNonce, transcript-bound signatures, and SigningKeyHandle support). The codebase contains both the newer handshake path (HandshakeDriver + HandshakeContext) and a legacy JSON handshake path in iOSP2PSessionManager. This document consolidates what is live, what is legacy, and how we are aligning implementation to the paper.

## Current Reality (Code)
- New handshake path exists: HandshakeDriver + HandshakeContext + HandshakeMessageA/B binary format.
- Legacy JSON handshake still exists (P2PHandshakeMessage/P2PFinishedMessage) and is gated by a runtime flag.
- HPKE-based envelope exists; signing uses SigningKeyHandle (raw/Keychain/Secure Enclave).

## Target (Paper)
- supportedSuites list + keyShares[] negotiation in MessageA.
- clientNonce and serverNonce explicitly separated.
- Signature in MessageB binds transcriptA to prevent downgrade/strip.
- kemDemSeal/kedDemOpen API semantics (KEM -> HKDF -> AEAD envelope).
- SigningKeyHandle abstraction for Secure Enclave / Keychain-backed signing.

## Alignment Steps (Phased)
### Phase 1 (Protocol Surface + KEM-DEM API)
1. Rename handshake nonces to clientNonce/serverNonce and update encoding/decoding.
2. Enforce deterministic encoding for policy/capabilities and use the new fields in transcript binding.
3. Add KEM-DEM API to CryptoProvider and route handshake payload encryption through it.
4. Gate the legacy JSON handshake behind an explicit runtime switch (default off).

### Phase 2 (Remove Legacy Path)
1. Remove or fully deprecate the JSON handshake path.
2. Remove related legacy nonce cache and code paths if no longer referenced.
3. Update any documentation that points to JSON handshake messages.

### Phase 3 (Full Secure Enclave Integration)
1. Ensure SigningKeyHandle is used end-to-end for all handshake signing flows.
2. Add validation tests for Secure Enclave key handles and transcript binding.

## Notes
- This is a breaking protocol change; roll out with versioning or upgrade coordination.
- Keep the default path on the new binary handshake protocol; legacy remains opt-in only.
