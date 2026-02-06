# Protocol Alignment Plan (IEEE Paper vs Code)

## Summary
The IEEE paper describes the binary handshake protocol (supportedSuites list, keyShares, clientNonce/serverNonce, transcript-bound signatures, and SigningKeyHandle support). The current codebase implements this binary handshake path (HandshakeDriver + HandshakeContext + HandshakeMessageA/B + Finished). Earlier drafts referenced a “legacy JSON handshake” path; that legacy JSON handshake is no longer present. The only remaining legacy compatibility is **identity-key decoding** for pre-migration key material.

## Current Reality (Code)
- Binary handshake path exists and is the only wire protocol:
  - HandshakeDriver + HandshakeContext + HandshakeMessageA/B binary format + Finished frames
  - Two-attempt strategy (PQC-only then Classic-only) is enforced via policy (HandshakePolicy)
- Legacy compatibility is limited to key-format decoding:
  - `IdentityPublicKeys.decodeWithLegacyFallback` accepts legacy P-256 uncompressed public keys only under strict validation (65 bytes, 0x04 prefix)
  - Legacy signature algorithm decoding (e.g., `.p256ECDSA`) exists as a compatibility layer for stored key material
- HPKE/KEM-DEM style envelope exists; signing uses SigningKeyHandle (raw/Keychain/Secure Enclave).

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
4. Remove stale documentation references to the legacy JSON handshake (if any remain).

### Phase 2 (Retire Key-Format Legacy Compatibility)
1. Keep legacy P-256 key decoding strict (already enforced) and scoped to the minimum necessary surface.
2. Once migration is complete (all peers have migrated identity material), remove legacy key-format decoding and any compatibility-only code paths.
3. Update any remaining documentation that implies multiple handshake wire protocols.

### Phase 3 (Full Secure Enclave Integration)
1. Ensure SigningKeyHandle is used end-to-end for all handshake signing flows.
2. Add validation tests for Secure Enclave key handles and transcript binding.

## Notes
- This is a breaking protocol change; roll out with versioning or upgrade coordination.
- Keep the default path on the new binary handshake protocol; “legacy” in this document refers to key-format compatibility only (not an alternate JSON handshake).
